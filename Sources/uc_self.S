.text
.globl _uc_ptr
.globl _uc_arr
.globl _uc_rect
.globl _uc_bool
.globl _uc_wait
.p2align 2
_uc_ptr:
_uc_arr:
_uc_rect:
_uc_bool:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    blr x1
    ldp x20, x30, [sp], #16
    ret
_uc_wait:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x2
    blr x1
    ldp x20, x30, [sp], #16
    ret
.globl _uc_arm
.globl _uc_assert_dev
.globl _uc_set_true
_uc_arm:
    adrp x9, hold_mgr@PAGE
    add x9, x9, hold_mgr@PAGEOFF
    str x0, [x9]
    adrp x9, hold_fn@PAGE
    add x9, x9, hold_fn@PAGEOFF
    str x1, [x9]
    ret
_uc_assert_dev:
    stp x20, x30, [sp, #-16]!
    adrp x9, hold_mgr@PAGE
    add x9, x9, hold_mgr@PAGEOFF
    ldr x20, [x9]
    adrp x9, hold_fn@PAGE
    add x9, x9, hold_fn@PAGEOFF
    ldr x9, [x9]
    blr x9
    ldp x20, x30, [sp], #16
    ret
_uc_set_true:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov w0, #1
    blr x1
    ldp x20, x30, [sp], #16
    ret
.bss
.p2align 3
hold_mgr: .quad 0
hold_fn: .quad 0
