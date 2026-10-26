#import <Cocoa/Cocoa.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <ptrauth.h>

extern const char tegi_stub_start[], tegi_stub_end[], tegi_stub_path[];
extern const char tegi_stub_pthread[], tegi_stub_dlopen[], tegi_stub_dlsym[], tegi_stub_dlclose[];

static void patch(char *code, const char *slot, const char *name) {
    void *pointer = ptrauth_strip(dlsym(RTLD_DEFAULT, name), ptrauth_key_function_pointer);
    memcpy(code + (slot - tegi_stub_start), &pointer, sizeof(pointer));
}

#ifndef TEGI_GRANT_SHA256
#error "build with scripts/app.sh, which pins the grant library's hash"
#endif

// sudo can let this run without a password, so it must not inject anything but tegi's own grant library. The bytes
// it checked go into a folder only root can write, so nothing can swap the library before Dock loads it.
static BOOL copy_tegi_grant(const char *from, char *directory, size_t size, char *to, size_t to_size) {
    NSData *data = [NSData dataWithContentsOfFile:@(from)];
    if (!data) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (strcmp(hex, TEGI_GRANT_SHA256) != 0) return NO;
    strlcpy(directory, "/private/var/tmp/tegi.XXXXXX", size);
    if (!mkdtemp(directory) || chmod(directory, 0755)) return NO;
    snprintf(to, to_size, "%s/grant.dylib", directory);
    return [data writeToFile:@(to) atomically:NO] && chmod(to, 0644) == 0;
}

// The ARM thread-state conversion follows yabai's loader, by Åsmund Vikane,
// based on Jeremy Legendre's arm64e injection work. See LICENSE.yabai.
int main(int argc, char **argv) {
    // Turning direct motion off takes the passwordless rule back without asking again. Only these fixed paths, so
    // whoever runs it can do no more than that.
    if (argc == 2 && !strcmp(argv[1], "forget") && geteuid() == 0) {
        const char *files[] = { "/etc/sudoers.d/tegi", "/Library/PrivilegedHelperTools/tegi-dock-loader" };
        int result = 0;
        for (int i = 0; i < 2; ++i) if (unlink(files[i]) && errno != ENOENT) result = 1;
        return result;
    }
    if (argc != 3 || geteuid() != 0) {
        fprintf(stderr, "usage: sudo tegi-dock-loader <grant.dylib> <connection-id>\n");
        return 1;
    }
    int result = 1, listener = -1, peer = -1, events = -1;
    mach_port_t task = MACH_PORT_NULL, bootstrap = MACH_PORT_NULL, worker = MACH_PORT_NULL, notice = MACH_PORT_NULL;
    mach_vm_address_t code_address = 0, stack_address = 0;
    const mach_vm_size_t stack_size = 16 * 1024;
    size_t code_size = tegi_stub_end - tegi_stub_start;
    char *code = NULL;
    BOOL worker_finished = NO;
    BOOL running = NO;
    BOOL bound = NO;
    char path[1024], folder[1024];
    if (!copy_tegi_grant(argv[1], folder, sizeof(folder), path, sizeof(path))) {
        fprintf(stderr, "not tegi's grant library\n");
        return 1;
    }
    NSRunningApplication *dock = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
    struct proc_bsdinfo info;
    if (!dock || proc_pidinfo(dock.processIdentifier, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
        fprintf(stderr, "Dock isn't running\n");
        unlink(path);
        rmdir(folder);
        return 1;
    }
    char *end;
    long connection = strtol(argv[2], &end, 10);
    if (*end || connection <= 0 || connection > INT32_MAX) { unlink(path); rmdir(folder); return 1; }
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    char directory[1024];
    strlcpy(directory, path, sizeof(directory));
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s/grant.sock", dirname(directory)) >= sizeof(address.sun_path)) {
        unlink(path); rmdir(folder); return 1;
    }
    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address))) {
        perror("grant socket"); goto cleanup;
    }
    bound = YES;
    if (listen(listener, 1)) { perror("grant socket listen"); goto cleanup; }
    chmod(address.sun_path, 0600);
    chown(address.sun_path, info.pbi_uid, info.pbi_gid);
    if (task_for_pid(mach_task_self(), dock.processIdentifier, &task) != KERN_SUCCESS) {
        fprintf(stderr, "macOS refused access to Dock; the configured system protections do not permit injection\n");
        goto cleanup;
    }
    code = malloc(code_size);
    memcpy(code, tegi_stub_start, code_size);
    memcpy(code + (tegi_stub_path - tegi_stub_start), path, strlen(path) + 1);
    patch(code, tegi_stub_pthread, "pthread_create_from_mach_thread");
    patch(code, tegi_stub_dlopen, "dlopen");
    patch(code, tegi_stub_dlsym, "dlsym");
    patch(code, tegi_stub_dlclose, "dlclose");
    if (mach_vm_allocate(task, &stack_address, stack_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS
        || mach_vm_allocate(task, &code_address, code_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS
        || mach_vm_write(task, code_address, (vm_offset_t)code, (mach_msg_type_number_t)code_size) != KERN_SUCCESS
        || mach_vm_protect(task, code_address, code_size, NO, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
        fprintf(stderr, "could not prepare Dock helper memory\n"); goto cleanup;
    }
    typedef kern_return_t (*Convert)(thread_act_t, int, thread_state_flavor_t, thread_state_t, mach_msg_type_number_t,
                                     thread_state_t, mach_msg_type_number_t *);
    Convert convert = (Convert)dlsym(RTLD_DEFAULT, "thread_convert_thread_state");
    arm_thread_state64_t state = {}, converted = {};
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    __darwin_arm_thread_state64_set_pc_fptr(state, ptrauth_sign_unauthenticated((void *)code_address, ptrauth_key_asia, 0));
    __darwin_arm_thread_state64_set_sp(state, stack_address + stack_size / 2);
    if (!convert || thread_create(task, &bootstrap) != KERN_SUCCESS
        || convert(bootstrap, 2, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT,
                   (thread_state_t)&converted, &count) != KERN_SUCCESS) {
        fprintf(stderr, "could not prepare Dock thread state\n"); goto cleanup;
    }
    thread_terminate(bootstrap);
    bootstrap = MACH_PORT_NULL;
    if (thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&converted, count, &bootstrap) != KERN_SUCCESS) {
        fprintf(stderr, "could not start Dock helper\n"); goto cleanup;
    }
    running = YES;
    events = kqueue();
    struct kevent change, event;
    EV_SET(&change, listener, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, NULL);
    struct timespec timeout = { .tv_sec = 5 };
    if (events < 0 || kevent(events, &change, 1, &event, 1, &timeout) != 1) {
        fprintf(stderr, "Dock helper did not connect\n"); goto cleanup;
    }
    peer = accept(listener, NULL, NULL);
    pid_t peer_pid = 0;
    socklen_t peer_size = sizeof(peer_pid);
    if (peer < 0 || getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &peer_size) || peer_pid != dock.processIdentifier) {
        fprintf(stderr, "unexpected grant peer\n"); goto cleanup;
    }
    struct timeval read_timeout = { .tv_sec = 5 };
    setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &read_timeout, sizeof(read_timeout));
    int32_t requested = (int32_t)connection;
    struct { int32_t result; mach_port_t thread; } reply;
    if (send(peer, &requested, sizeof(requested), 0) != sizeof(requested)
        || recv(peer, &reply, sizeof(reply), MSG_WAITALL) != sizeof(reply)) {
        fprintf(stderr, "Dock helper handshake failed\n"); goto cleanup;
    }
    mach_msg_type_name_t right;
    mach_port_t previous;
    if (mach_port_extract_right(task, reply.thread, MACH_MSG_TYPE_COPY_SEND, &worker, &right) != KERN_SUCCESS
        || mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &notice) != KERN_SUCCESS
        || mach_port_request_notification(mach_task_self(), worker, MACH_NOTIFY_DEAD_NAME, 0, notice,
                                           MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous) != KERN_SUCCESS) {
        fprintf(stderr, "could not observe Dock helper completion\n"); goto cleanup;
    }
    char acknowledged = 1;
    if (send(peer, &acknowledged, 1, 0) != 1) goto cleanup;
    mach_dead_name_notification_t message;
    if (mach_msg(&message.not_header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(message), notice, 5000, MACH_PORT_NULL) != KERN_SUCCESS) {
        fprintf(stderr, "Dock helper did not finish\n"); goto cleanup;
    }
    worker_finished = YES;
    result = reply.result == 0 ? 0 : 1;
cleanup:
    if (peer >= 0) close(peer);
    if (listener >= 0) close(listener);
    if (bound) unlink(address.sun_path);
    // Dock keeps what it loaded mapped; the file itself can go.
    unlink(path);
    rmdir(folder);
    if (events >= 0) close(events);
    if (bootstrap) thread_terminate(bootstrap);
    // A timed-out worker may still be using the stub. Leave that memory alone rather than
    // unmapping executable instructions under Dock; successful runs free both allocations.
    if (!running || worker_finished) {
        if (code_address) mach_vm_deallocate(task, code_address, code_size);
        if (stack_address) mach_vm_deallocate(task, stack_address, stack_size);
    }
    if (worker) mach_port_deallocate(mach_task_self(), worker);
    if (notice) mach_port_mod_refs(mach_task_self(), notice, MACH_PORT_RIGHT_RECEIVE, -1);
    if (task) mach_port_deallocate(mach_task_self(), task);
    free(code);
    return result;
}
