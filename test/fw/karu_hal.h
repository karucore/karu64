//  karu_hal.h
//  2025-05-08  Markku-Juhani O. Saarinen <mjos@iki.fi>
//  === A minimal hardware abstraction layer

#ifndef _KARU_HAL_H_
#define _KARU_HAL_H_


#include <stdint.h>
#include <stddef.h>

#include "sio_generic.h"

//  host / sim build: no memory-mapped peripherals
#define get_clk_ticks() 0

//  fixed-length word-wise block copy macros are faster than memcpy

static inline void block_copy_16(volatile void *dst, const volatile void *src)
{
    volatile uint32_t *d32 = (volatile uint32_t *) dst;
    volatile uint32_t *s32 = (volatile uint32_t *) src;

    d32[0] = s32[0];
    d32[1] = s32[1];
    d32[2] = s32[2];
    d32[3] = s32[3];
}

static inline void block_copy_24(volatile void *dst, const volatile void *src)
{
    volatile uint32_t *d32 = (volatile uint32_t *) dst;
    volatile uint32_t *s32 = (volatile uint32_t *) src;

    d32[0] = s32[0];
    d32[1] = s32[1];
    d32[2] = s32[2];
    d32[3] = s32[3];
    d32[4] = s32[4];
    d32[5] = s32[5];
}

static inline void block_copy_32(volatile void *dst, const volatile void *src)
{
    volatile uint32_t *d32 = (volatile uint32_t *) dst;
    volatile uint32_t *s32 = (volatile uint32_t *) src;

    d32[0] = s32[0];
    d32[1] = s32[1];
    d32[2] = s32[2];
    d32[3] = s32[3];
    d32[4] = s32[4];
    d32[5] = s32[5];
    d32[6] = s32[6];
    d32[7] = s32[7];
}

static inline void block_copy_n(volatile void *dst, const volatile void *src,
                                uint32_t n)
{
    volatile uint32_t *d32 = (volatile uint32_t *) dst;
    volatile uint32_t *s32 = (volatile uint32_t *) src;

    d32[0] = s32[0];
    d32[1] = s32[1];
    d32[2] = s32[2];
    d32[3] = s32[3];
    if (n == 16)
        return;
    d32[4] = s32[4];
    d32[5] = s32[5];
    if (n == 24)
        return;
    d32[6] = s32[6];
    d32[7] = s32[7];
}

static inline void block_copy_64(volatile void *dst, const volatile void *src)
{
    volatile uint32_t *d32 = (volatile uint32_t *) dst;
    volatile uint32_t *s32 = (volatile uint32_t *) src;

    block_copy_32( d32,     s32 );
    block_copy_32( d32 + 8, s32 + 8 );
}
//  _KARU_HAL_H_
#endif
