// Simulation island ROM: the authentication window of
// doc/debug-auth-contract.md sections 3-5, with the simulation-only TEST
// algorithm (0x80). TEST is NOT cryptographic: its "signature" is a keyed
// XOR fold of the challenge with a public test key. A production ROM accepts
// only the algorithm chosen under D3 and rejects 0x80.
//
// Built with -DAUTH_ALG_SHA3 it verifies algorithm 0x04 instead, the
// SHA3-256 shared-secret MAC chosen for FPGA validation on 2026-11-18
// (contract 5.1), and rejects 0x80; the default build rejects 0x04. The
// 32-byte key comes from -DAUTH_KEY_HEADER="file" (static const uint8_t
// auth_key[32]); start.S clears island SRAM before leaving (contract D1).
// SPDX-License-Identifier: BSD-2-Clause
#include <stdint.h>
#ifdef AUTH_ALG_SHA3
#include "sha3.h"
#ifndef AUTH_KEY_HEADER
#error "AUTH_ALG_SHA3 needs -DAUTH_KEY_HEADER=\"file\" with the 32-byte auth_key"
#endif
#include AUTH_KEY_HEADER
#endif

#define CSR_AUTH 0x7c0
#define CSR_RX   0x7c1
#define CSR_TX   0x7c2
/* The nonce source: the Zkr seed CSR, sixteen ES16 words, each taken by a
   read-write access. An image whose core has no seed CSR has no nonce
   source; its ROM is built with -DAUTH_NO_SEED, makes no challenge and so
   never unlocks. (Reading seed there would trap, with no trap vector set.) */
#define CSR_SEED 0x015
/* Polls allowed per nonce word while the source reports BIST or WAIT. It
   must cover the source's start-up test after reset. */
#ifndef TRNG_TRIES
#define TRNG_TRIES 10000
#endif
#define CSR_MBST 0xfc0

#define AUTH_UNLOCK   (1u << 0)
#define AUTH_BOOTDONE (1u << 1)
#define AUTH_REQ      (1u << 7)
#define AUTH_SESS_ACK (1u << 25)
#define MBST_SESS     (1u << 24)
#define MBST_STARTED  (1u << 25)

#define ALG_TEST      0x80u
#define ALG_SHA3      0x04u
#define TEST_SIG_WORDS 8u
#define SIG_WORDS     8u            /* both algorithms: 32 bytes */
#define CHALLENGE_WORDS 20u
#ifdef AUTH_ALG_SHA3
#define ROM_ALG ALG_SHA3
#else
#define ROM_ALG ALG_TEST
#endif
#ifndef WINDOW_CYCLES
#define WINDOW_CYCLES 400000ull     /* simulation bound; production 2^30 */
#endif

#ifdef AUTH_ROM_HOST
/* Host model build (test/dbg/auth_rom/host_test.c): CSR accesses go to a
   mailbox model, so the window logic itself is what is tested. */
uint64_t mock_read(unsigned csr);
uint64_t mock_rw(unsigned csr, uint64_t w);
void mock_set(unsigned csr, uint64_t w);
void mock_write(unsigned csr, uint64_t w);
uint64_t mock_cycles(void);
#define csr_read(c) mock_read(c)
#define csr_rw(c, w) mock_rw(c, w)
#define csr_set(c, w) mock_set(c, w)
#define csr_write(c, w) mock_write(c, w)
#define read_cycles() mock_cycles()
#else
#define STR(x) #x
#define XSTR(x) STR(x)
#define csr_read(c) ({ uint64_t v_; __asm__ volatile("csrr %0, " XSTR(c) : "=r"(v_)); v_; })
#define csr_rw(c, w) ({ uint64_t v_; __asm__ volatile("csrrw %0, " XSTR(c) ", %1" : "=r"(v_) : "r"((uint64_t)(w))); v_; })
#define csr_set(c, w) __asm__ volatile("csrs " XSTR(c) ", %0" :: "r"((uint64_t)(w)))
#define csr_write(c, w) __asm__ volatile("csrw " XSTR(c) ", %0" :: "r"((uint64_t)(w)))
#define read_cycles() csr_read(mcycle)
#endif

#ifndef AUTH_ALG_SHA3
static const uint32_t test_key[TEST_SIG_WORDS] = {
    0x6b617275u, 0x64626761u, 0x75746821u, 0x54455354u,
    0x2d6f6e6cu, 0x792d6e6fu, 0x742d6372u, 0x7970746fu };
#endif
static const uint32_t device_digest[8] = {
    0x11111111u, 0x22222222u, 0x33333333u, 0x44444444u,
    0x55555555u, 0x66666666u, 0x77777777u, 0x88888888u };

static uint32_t challenge[CHALLENGE_WORDS];

/* The window ends WINDOW_CYCLES after it opens (contract 5.3). Expiry is
   checked before every step that waits on, or takes input from, the host or
   the TRNG, and once more immediately before the grant. This is a software
   cutoff: the guarded CSR access commits a few instructions after its
   check, so a pop or the grant can land that much after the deadline. A
   hard cutoff needs a worst-case margin subtracted here or a hardware
   timer. */
static uint64_t deadline;
static int expired(void) { return read_cycles() >= deadline; }

#ifndef AUTH_ALG_SHA3
/* TEST: sig[i] = key[i] ^ XOR of challenge words j with j % 8 == i,
   each rotated left by i, then mixed with the granted-mask byte. */
static uint32_t rotl(uint32_t x, unsigned r) { return r ? (x << r) | (x >> (32 - r)) : x; }
static void test_signature(uint32_t granted, uint32_t out[TEST_SIG_WORDS]) {
    for (unsigned i = 0; i < TEST_SIG_WORDS; i++) {
        uint32_t a = test_key[i] ^ (granted * 0x01010101u);
        for (unsigned j = i; j < CHALLENGE_WORDS; j += TEST_SIG_WORDS) a ^= rotl(challenge[j], i);
        out[i] = a;
    }
}
#define expected_signature test_signature
#else
/* 0x04: digest = SHA3-256(key[32] || "karudbg-auth-v1" || challenge words
   0-19 as 80 bytes little-endian || granted-mask byte), 128 bytes, one
   Keccak block. Signature word i is digest bytes 4i..4i+3, little-endian.
   The message holds the key, so it is wiped here; the caller wipes out[]. */
static const char mac_label[] = "karudbg-auth-v1";         /* 15 bytes; the NUL is not hashed */
#define MAC_LABEL_BYTES (sizeof mac_label - 1)
static void sha3_mac_signature(uint32_t granted, uint32_t out[SIG_WORDS]) {
    uint8_t msg[32 + MAC_LABEL_BYTES + 4 * CHALLENGE_WORDS + 1], digest[32];
    unsigned n = 0;
    for (unsigned i = 0; i < 32; i++) msg[n++] = auth_key[i];
    for (unsigned i = 0; i < MAC_LABEL_BYTES; i++) msg[n++] = (uint8_t)mac_label[i];
    for (unsigned i = 0; i < CHALLENGE_WORDS; i++)
        for (unsigned k = 0; k < 4; k++) msg[n++] = (uint8_t)(challenge[i] >> (8 * k));
    msg[n++] = (uint8_t)granted;
    sha3_256(digest, msg, n);
    for (unsigned i = 0; i < SIG_WORDS; i++)
        out[i] = (uint32_t)digest[4 * i] | (uint32_t)digest[4 * i + 1] << 8 |
                 (uint32_t)digest[4 * i + 2] << 16 | (uint32_t)digest[4 * i + 3] << 24;
    sha3_wipe(msg, sizeof msg);
    sha3_wipe(digest, sizeof digest);
}
#define expected_signature sha3_mac_signature
#endif

/* One RX word within the window; 0 on expiry or once hardware has closed
   the window. Before the first RESPONSE word (first != 0) a session reset
   makes the ROM re-push the unchanged challenge; afterwards hardware closes
   the window on a session reset. */
static int push_challenge(void);
static int rx_word(uint32_t *w, int first) {
    for (;;) {
        if (expired()) return 0;
        if (csr_read(CSR_AUTH) & AUTH_BOOTDONE) return 0;
        if (first) {
            uint64_t m = csr_read(CSR_MBST);
            if ((m & MBST_SESS) && !(m & MBST_STARTED)) {
                if (!push_challenge()) return 0;
                continue;                          /* re-check expiry first */
            }
        }
        uint64_t v = csr_rw(CSR_RX, 0);            /* read-write form pops */
        if (v >> 32) { *w = (uint32_t)v; return 1; }
    }
}

static int make_nonce(uint32_t *dst) {
#ifdef AUTH_NO_SEED
    (void)dst;
    return 0;
#else
    for (unsigned i = 0; i < 16; i++) {
        unsigned tries = 0;
        for (;;) {
            if (expired()) return 0;
            uint64_t v = csr_rw(CSR_SEED, 0);
            unsigned opst = (v >> 30) & 3;
            if (opst == 2) {                       /* ES16 */
                if (i & 1) dst[i >> 1] |= (uint32_t)(v & 0xffff) << 16;
                else dst[i >> 1] = (uint32_t)(v & 0xffff);
                break;
            }
            if (opst == 3 || ++tries > TRNG_TRIES) return 0;   /* DEAD or stalled */
        }
    }
    return 1;
#endif
}

/* Push the whole challenge, restarting from word 0 whenever a session reset
   (deactivation or ABORT) clears the FIFOs mid-push. 0 on expiry: every
   iteration, including each restart, checks the deadline first, so repeated
   ABORTs cannot keep the window open. */
static int push_challenge(void) {
    unsigned i = 0;
    csr_set(CSR_AUTH, AUTH_SESS_ACK);
    while (i < CHALLENGE_WORDS) {
        if (expired()) return 0;
        uint64_t m = csr_read(CSR_MBST);
        if (m & MBST_SESS) { csr_set(CSR_AUTH, AUTH_SESS_ACK); i = 0; continue; }
        if ((m >> 5) & 0x1f) csr_write(CSR_TX, challenge[i++]);   /* TX free */
    }
    return 1;
}

void auth_window(void) {
    uint64_t a = csr_read(CSR_AUTH);
    if ((a & AUTH_BOOTDONE) || !(a & AUTH_REQ)) return;  /* no window */
    uint32_t perm_req = (uint32_t)(a >> 16) & 0xff;
    uint32_t lc = (uint32_t)(a >> 4) & 3;
    deadline = read_cycles() + WINDOW_CYCLES;

#ifdef AUTH_ALG_SHA3
    challenge[0] = (0x01u << 24) | (1u << 16) | (ALG_SHA3 << 8);
#else
    challenge[0] = (0x01u << 24) | (1u << 16) | (ALG_TEST << 8);
#endif
    challenge[1] = 72u | (perm_req << 16) | (lc << 24);
    for (unsigned i = 0; i < 8; i++) challenge[2 + i] = device_digest[i];
    if (!make_nonce(&challenge[10])) return;
    challenge[18] = 0; challenge[19] = 0;           /* no POR counter */

    if (!push_challenge()) return;
    uint32_t hdr, lenw, sig[SIG_WORDS], want[SIG_WORDS];
    if (!rx_word(&hdr, 1)) return;
    if (!rx_word(&lenw, 0)) return;
    for (unsigned i = 0; i < SIG_WORDS; i++)
        if (!rx_word(&sig[i], 0)) return;
    /* Rejection rules (contract 5.3). Only this build's algorithm. */
    if ((hdr >> 24) != 0x02u || ((hdr >> 16) & 0xff) != 1u || (hdr & 0xff) != 0) return;
    if (((hdr >> 8) & 0xff) != ROM_ALG) return;
    if ((lenw & 0xffff) != SIG_WORDS * 4u) return;
    uint32_t granted = (lenw >> 16) & 0xff;
    if (granted == 0 || (granted & ~perm_req) || (lenw >> 24)) return;
    if (csr_read(CSR_MBST) & MBST_SESS) return;     /* session reset while parsing */
    expected_signature(granted, want);
    uint32_t diff = 0;                              /* constant time: no early exit */
    for (unsigned i = 0; i < SIG_WORDS; i++) diff |= sig[i] ^ want[i];
#ifdef AUTH_ALG_SHA3
    sha3_wipe(want, sizeof want);                   /* key-derived; wiped before either outcome */
#endif
    if (diff) return;
    if (expired()) return;                          /* decision is inside the window */
    csr_set(CSR_AUTH, AUTH_UNLOCK);                 /* commit predicate: ROM PC, M, window */
}
