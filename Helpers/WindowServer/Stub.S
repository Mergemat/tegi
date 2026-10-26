.text
.p2align 3
.globl _tegi_stub_start, _tegi_stub_end, _tegi_stub_pthread, _tegi_stub_dlopen, _tegi_stub_dlsym, _tegi_stub_dlclose, _tegi_stub_path
_tegi_stub_start:
    sub sp, sp, #32
    add x0, sp, #8
    mov x1, #0
    adr x2, worker
    paciza x2
    mov x3, #0
    ldr x8, _tegi_stub_pthread
    blr x8
1:  b 1b
worker:
    pacibsp
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x29, sp
    adr x0, _tegi_stub_path
    mov x1, #2
    ldr x8, _tegi_stub_dlopen
    blr x8
    cbz x0, 2f
    mov x19, x0
    adr x1, grant_name
    ldr x8, _tegi_stub_dlsym
    blr x8
    cbz x0, 3f
    xpaci x0
    blr x0
3:  mov x0, x19
    ldr x8, _tegi_stub_dlclose
    blr x8
2:  ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    mov x0, #0
    retab
grant_name: .asciz "tegi_grant"
.p2align 3
_tegi_stub_pthread: .quad 0
_tegi_stub_dlopen: .quad 0
_tegi_stub_dlsym: .quad 0
_tegi_stub_dlclose: .quad 0
_tegi_stub_path: .space 1024
_tegi_stub_end:
