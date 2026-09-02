#include <stdint.h>

__attribute__((noinline))
int32_t bdot_u8(const uint8_t *a, const uint8_t *b, uint32_t bit_count)
{
    uint32_t byte_count = (bit_count + 7u) >> 3;
    uint32_t matches = 0;
    for (uint32_t i = 0; i < byte_count; ++i) {
        uint32_t x = (uint8_t)~(a[i] ^ b[i]);
        x = x - ((x >> 1) & 0x55u);
        x = (x & 0x33u) + ((x >> 2) & 0x33u);
        x = (x + (x >> 4)) & 0x0fu;
        matches += x;
    }
    return (int32_t)(2u * matches) - (int32_t)bit_count;
}

__attribute__((noinline))
int32_t bdot_u32(const uint32_t *a, const uint32_t *b, uint32_t bit_count)
{
    uint32_t word_count = (bit_count + 31u) >> 5;
    uint32_t matches = 0;
    for (uint32_t i = 0; i < word_count; ++i) {
        uint32_t x = ~(a[i] ^ b[i]);
        x = x - ((x >> 1) & 0x55555555u);
        x = (x & 0x33333333u) + ((x >> 2) & 0x33333333u);
        x = (x + (x >> 4)) & 0x0f0f0f0fu;
        x = x + (x >> 8);
        x = x + (x >> 16);
        matches += x & 0x3fu;
    }
    return (int32_t)(2u * matches) - (int32_t)bit_count;
}

__attribute__((noinline))
uint32_t pack_sign_i16(const int16_t *input)
{
    uint32_t packed = 0;
    for (uint32_t i = 0; i < 32u; ++i) {
        packed = (packed << 1) | (uint32_t)(input[i] >= 0);
    }
    return packed;
}

