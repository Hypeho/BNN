.section .text.init, "ax"
.global _start
.align 2

_start:
    la sp, _stack_top

    la t0, __bss_start
    la t1, __bss_end
    beq t0, t1, bss_clear_done

bss_clear_loop:
    sw zero, 0(t0)
    addi t0, t0, 4
    bltu t0, t1, bss_clear_loop

bss_clear_done:
    call main

halt_loop:
    j halt_loop
