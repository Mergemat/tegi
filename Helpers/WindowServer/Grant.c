#include <dlfcn.h>
#include <libgen.h>
#include <mach/mach.h>
#include <mach/ndr.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ptrauth.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

extern int SLSMainConnectionID(void);
extern int SLSGetWindowBounds(int, uint32_t, CGRect *);

static void notify_client(int32_t connection) {
    char temporary[1024];
    if (!confstr(_CS_DARWIN_USER_TEMP_DIR, temporary, sizeof(temporary))) return;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%stegi.sock", temporary) >= sizeof(address.sun_path)) return;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    int no_sigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    struct timeval timeout = { .tv_sec = 5 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        char message[80];
        int size = snprintf(message, sizeof(message), "window-server-authorized %d\n", connection);
        send(fd, message, size, 0);
        recv(fd, message, sizeof(message), 0);
    }
    close(fd);
}

// SkyLight keeps this symbol local. Resolve its Mach-O symbol table, as yabai does,
// instead of depending on instruction offsets that change between macOS builds.
static void *local_symbol(const char *name) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        if (!strstr(_dyld_get_image_name(i), "/SkyLight.framework/")) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        const struct load_command *command = (const void *)(header + 1);
        for (uint32_t j = 0; j < header->ncmds; ++j) {
            if (command->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT)) linkedit = (const void *)command;
            if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
            command = (const void *)((const char *)command + command->cmdsize);
        }
        if (!linkedit || !symtab) return NULL;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uintptr_t base = linkedit->vmaddr - linkedit->fileoff + slide;
        const char *strings = (const void *)(base + symtab->stroff);
        const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
        for (uint32_t j = 0; j < symtab->nsyms; ++j) {
            if (symbols[j].n_un.n_strx < symtab->strsize && !strcmp(strings + symbols[j].n_un.n_strx, name)) {
                void *pointer = (void *)(symbols[j].n_value + slide);
                pointer = ptrauth_sign_unauthenticated(pointer, ptrauth_key_function_pointer, 0);
                return pointer;
            }
        }
    }
    return NULL;
}

// No hooks or background threads remain in Dock. The loader unloads this library
// after granting the requesting process's connection; that grant dies with tegi.
__attribute__((visibility("default"))) void tegi_grant(void) {
    Dl_info info;
    if (!dladdr(tegi_grant, &info)) return;
    char path[1024];
    strlcpy(path, info.dli_fname, sizeof(path));
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s/grant.sock", dirname(path)) >= sizeof(address.sun_path)) return;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    int no_sigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    struct timeval timeout = { .tv_sec = 5 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        int32_t connection;
        if (recv(fd, &connection, sizeof(connection), MSG_WAITALL) == sizeof(connection)) {
            mach_port_t (*port_for_connection)(int) = local_symbol("_CGSGetConnectionPortById");
            if (!port_for_connection) { close(fd); return; }
            // SLSSetOtherUniversalConnection dereferences both connections in the caller's
            // address space. Its server message also accepts a foreign process's connection.
            struct {
                mach_msg_header_t header;
                NDR_record_t ndr;
                int32_t connection;
            } request = {
                .header = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0),
                            .msgh_size = 36, .msgh_remote_port = port_for_connection(SLSMainConnectionID()),
                            .msgh_id = 30002 },
                .ndr = NDR_record,
                .connection = connection
            };
            kern_return_t result = mach_msg(&request.header, MACH_SEND_MSG, sizeof(request), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
            if (result == KERN_SUCCESS) {
                // The synchronous query orders the grant before the app starts using live layers.
                CGRect ignored;
                SLSGetWindowBounds(SLSMainConnectionID(), 0, &ignored);
                notify_client(connection);
            }
            struct { int32_t result; mach_port_t thread; } reply = { result, mach_thread_self() };
            if (send(fd, &reply, sizeof(reply), 0) == sizeof(reply)) {
                char acknowledged;
                recv(fd, &acknowledged, 1, MSG_WAITALL);
            }
            mach_port_deallocate(mach_task_self(), reply.thread);
        }
    }
    close(fd);
}
