#ifndef EBNN_VALIDATION_STDINT_H
#define EBNN_VALIDATION_STDINT_H

/*
 * Minimal freestanding fixed-width types for the RV32I validation firmware.
 * The installed bare-metal GCC provides libgcc multilibs but no newlib headers.
 */
typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef signed short int16_t;
typedef unsigned short uint16_t;
typedef signed int int32_t;
typedef unsigned int uint32_t;
typedef signed long long int64_t;
typedef unsigned long long uint64_t;

#endif
