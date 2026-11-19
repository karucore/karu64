// SHA3-256 (FIPS 202): Keccak-f[1600] written for reading, not speed. No
// tables other than the round constants and the rotation offsets. Lanes are
// loaded and stored byte by byte, so the code does not depend on the host's
// byte order. Used by the island ROM (algorithm 0x04, window.c) and by its
// host test, which checks it against known answers.
// SPDX-License-Identifier: BSD-2-Clause
#include "sha3.h"

#define SHA3_256_RATE 136u          /* bytes: 1600 - 2 * 256 bits */

static const uint64_t round_constant[24] = {
    0x0000000000000001ull, 0x0000000000008082ull, 0x800000000000808aull, 0x8000000080008000ull,
    0x000000000000808bull, 0x0000000080000001ull, 0x8000000080008081ull, 0x8000000000008009ull,
    0x000000000000008aull, 0x0000000000000088ull, 0x0000000080008009ull, 0x000000008000000aull,
    0x000000008000808bull, 0x800000000000008bull, 0x8000000000008089ull, 0x8000000000008003ull,
    0x8000000000008002ull, 0x8000000000000080ull, 0x000000000000800aull, 0x800000008000000aull,
    0x8000000080008081ull, 0x8000000000008080ull, 0x0000000080000001ull, 0x8000000080008008ull };

/* rho rotation of lane (x, y), indexed x + 5 * y. */
static const uint8_t rho_offset[25] = {
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14 };

static uint64_t rotl64(uint64_t v, unsigned n) { return n ? (v << n) | (v >> (64 - n)) : v; }

void sha3_wipe(void *p, size_t n) {
    volatile uint8_t *v = (volatile uint8_t *)p;
    while (n--) *v++ = 0;
}

void keccak_f1600(uint64_t a[25]) {
    uint64_t c[5], b[25];
    for (unsigned round = 0; round < 24; round++) {
        /* theta: each lane takes the parity of two neighbouring columns */
        for (unsigned x = 0; x < 5; x++)
            c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
        for (unsigned x = 0; x < 5; x++) {
            uint64_t d = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
            for (unsigned y = 0; y < 5; y++) a[x + 5 * y] ^= d;
        }
        /* rho and pi: lane (x, y) rotated, moved to (y, 2x + 3y) */
        for (unsigned x = 0; x < 5; x++)
            for (unsigned y = 0; y < 5; y++)
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(a[x + 5 * y], rho_offset[x + 5 * y]);
        /* chi: the only non-linear step, along each row */
        for (unsigned x = 0; x < 5; x++)
            for (unsigned y = 0; y < 5; y++)
                a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y]);
        /* iota */
        a[0] ^= round_constant[round];
    }
    sha3_wipe(c, sizeof c);
    sha3_wipe(b, sizeof b);
}

void sha3_256(uint8_t out[32], const uint8_t *in, size_t len) {
    uint64_t s[25];
    sha3_wipe(s, sizeof s);
    size_t i = 0;                                   /* byte position in the current block */
    for (; len; len--, in++) {                      /* absorb */
        s[i / 8] ^= (uint64_t)*in << (8 * (i % 8));
        if (++i == SHA3_256_RATE) { keccak_f1600(s); i = 0; }
    }
    s[i / 8] ^= (uint64_t)0x06 << (8 * (i % 8));    /* SHA-3 domain bits 01, first pad bit */
    s[(SHA3_256_RATE - 1) / 8] ^= (uint64_t)0x80 << (8 * ((SHA3_256_RATE - 1) % 8));   /* last pad bit */
    keccak_f1600(s);
    for (unsigned k = 0; k < 32; k++) out[k] = (uint8_t)(s[k / 8] >> (8 * (k % 8)));   /* squeeze */
    sha3_wipe(s, sizeof s);
}
