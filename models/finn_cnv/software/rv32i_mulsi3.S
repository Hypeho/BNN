    .section .text.__mulsi3,"ax",@progbits
    .option push
    .option norvc
    .align 2
    .globl __mulsi3
    .type __mulsi3, @function
__mulsi3:
    addi a2, a0, 0
    addi a0, zero, 0
.Lmul_loop:
    andi a3, a1, 1
    beq a3, zero, .Lmul_skip_add
    add a0, a0, a2
.Lmul_skip_add:
    srli a1, a1, 1
    slli a2, a2, 1
    bne a1, zero, .Lmul_loop
    jalr zero, 0(ra)
    .size __mulsi3, .-__mulsi3
    .option pop
