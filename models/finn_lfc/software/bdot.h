#ifndef WIDE_BDOT_H
#define WIDE_BDOT_H

#include <stdint.h>

// custom-1 opcode 0x2b, funct7=0, funct3=000
static inline void bcfg_length(uint32_t bit_length)
{
    __asm__ volatile(
        ".insn r 0x2b, 0, 0, x0, %0, x0"
        :
        : "r"(bit_length)
    );
}

// custom-1 opcode 0x2b, funct7=0, funct3=001
static inline uint32_t bdot128(uint32_t activation_base, uint32_t weight_base)
{
    uint32_t result;
    __asm__ volatile(
        ".insn r 0x2b, 1, 0, %0, %1, %2"
        : "=r"(result)
        : "r"(activation_base), "r"(weight_base)
        : "memory"
    );
    return result;
}

#endif

