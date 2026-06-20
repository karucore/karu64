//  ddr_memtest.c
//  === VCU118 DDR4 bare-metal smoke test.

#include <stdint.h>
#include "sio_generic.h"

#ifndef MEMTEST_BASE
#define MEMTEST_BASE 0x80200000u
#endif

#ifndef MEMTEST_WORDS
#define MEMTEST_WORDS (128u * 1024u)    // 1 MiB
#endif

#ifndef DOT_STEP
#define DOT_STEP (16u * 1024u)
#endif

static volatile uint64_t *const ram = (volatile uint64_t *)(uintptr_t)MEMTEST_BASE;

static void put_hex32(uint32_t x, int n)
{
    int i;

    for (i = 4 * (n - 1); i >= 0; i -= 4) {
        unsigned d = (x >> i) & 0xf;
        sio_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

static void put_hex64(uint64_t x)
{
    put_hex32((uint32_t)(x >> 32), 8);
    put_hex32((uint32_t)x, 8);
}

static uint64_t step_pat(uint64_t x)
{
    x ^= x << 7;
    x ^= x >> 9;
    x ^= x << 8;
    return x + 0x9e3779b97f4a7c15ULL;
}

static uint64_t pat(uint32_t i, uint64_t x)
{
    uint64_t a = (uint64_t)MEMTEST_BASE + ((uint64_t)i << 3);
    return x ^ a ^ ((uint64_t)i << 32);
}

static int fail(const char *phase, uintptr_t addr, uint64_t got, uint64_t exp)
{
    sio_puts("\n[DDRTEST] FAIL ");
    sio_puts(phase);
    sio_puts(" addr=0x");
    put_hex32((uint32_t)addr, 8);
    sio_puts(" got=0x");
    put_hex64(got);
    sio_puts(" exp=0x");
    put_hex64(exp);
    sio_puts("\n");
    return 1;
}

static void fill_range(uint64_t seed, int invert)
{
    uint32_t i;
    uint64_t x = seed;

    for (i = 0; i < MEMTEST_WORDS; i++) {
        uint64_t v = pat(i, x);
        ram[i] = invert ? ~v : v;
        x = step_pat(x);
        if ((i & (DOT_STEP - 1u)) == 0)
            sio_putc('.');
    }
}

static int verify_range(uint64_t seed, int invert)
{
    uint32_t i;
    uint64_t x = seed;

    for (i = 0; i < MEMTEST_WORDS; i++) {
        uint64_t exp = pat(i, x);
        if (invert)
            exp = ~exp;
        if (ram[i] != exp)
            return fail(invert ? "verify1" : "verify0",
                        (uintptr_t)MEMTEST_BASE + ((uintptr_t)i << 3),
                        ram[i], exp);
        x = step_pat(x);
        if ((i & (DOT_STEP - 1u)) == 0)
            sio_putc('.');
    }
    return 0;
}

static int test_alias(void)
{
    uint32_t off;
    const uint64_t base = 0x1122334455667788ULL;

    ram[0] = base;
    for (off = 1; off < MEMTEST_WORDS; off <<= 1)
        ram[off] = 0xa500000000000000ULL ^ (uint64_t)off;
    if (ram[0] != base)
        return fail("alias0", MEMTEST_BASE, ram[0], base);
    for (off = 1; off < MEMTEST_WORDS; off <<= 1) {
        uint64_t exp = 0xa500000000000000ULL ^ (uint64_t)off;
        if (ram[off] != exp)
            return fail("alias",
                        (uintptr_t)MEMTEST_BASE + ((uintptr_t)off << 3),
                        ram[off], exp);
    }
    return 0;
}

static int test_strobes(void)
{
    volatile uint8_t  *b8;
    volatile uint16_t *b16;
    volatile uint32_t *b32;
    uint64_t got, exp;

    ram[16] = 0;
    b8 = (volatile uint8_t *)(uintptr_t)(MEMTEST_BASE + (16u << 3));
    b8[0] = 0x12;
    b8[3] = 0x34;
    b8[7] = 0x56;
    exp = 0x5600000034000012ULL;
    got = ram[16];
    if (got != exp)
        return fail("stb8", MEMTEST_BASE + (16u << 3), got, exp);

    ram[17] = 0xffffffffffffffffULL;
    b16 = (volatile uint16_t *)(uintptr_t)(MEMTEST_BASE + (17u << 3));
    b16[2] = 0;
    exp = 0xffff0000ffffffffULL;
    got = ram[17];
    if (got != exp)
        return fail("stb16", MEMTEST_BASE + (17u << 3), got, exp);

    ram[18] = 0;
    b32 = (volatile uint32_t *)(uintptr_t)(MEMTEST_BASE + (18u << 3));
    b32[1] = 0x89abcdefu;
    exp = 0x89abcdef00000000ULL;
    got = ram[18];
    if (got != exp)
        return fail("stb32", MEMTEST_BASE + (18u << 3), got, exp);

    return 0;
}

int main(void)
{
    sio_puts("\n[DDRTEST] base=0x");
    put_hex32(MEMTEST_BASE, 8);
    sio_puts(" words=0x");
    put_hex32(MEMTEST_WORDS, 8);

    sio_puts("\n[DDRTEST] fill0 ");
    fill_range(0x0123456789abcdefULL, 0);
    sio_puts(" verify0 ");
    if (verify_range(0x0123456789abcdefULL, 0))
        goto done;

    sio_puts("\n[DDRTEST] fill1 ");
    fill_range(0xfedcba9876543210ULL, 1);
    sio_puts(" verify1 ");
    if (verify_range(0xfedcba9876543210ULL, 1))
        goto done;

    sio_puts("\n[DDRTEST] alias ");
    if (test_alias())
        goto done;
    sio_puts("ok");

    sio_puts("\n[DDRTEST] strobes ");
    if (test_strobes())
        goto done;
    sio_puts("ok");

    sio_puts("\n[DDRTEST] PASS\n");

done:
    for (;;)
        asm volatile("wfi");
}
