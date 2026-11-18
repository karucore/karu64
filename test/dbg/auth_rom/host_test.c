// Host model test of the simulation island ROM's window logic (window.c).
// The ROM routine runs natively against a mailbox model in which every CSR
// access takes one cycle, so response words, session resets and the
// deadline can be placed on exact cycles. Checked in every schedule:
//
//   I1  a grant is written only before the deadline, and only from response
//       words that were popped before the deadline;
//   I2  the routine returns within SLACK accesses of the deadline, whatever
//       the host does (silence, repeated ABORTs, a stalled TRNG);
//   I3  a valid response delivered in time, also after ABORTs, unlocks.
//
// This models the software only. The hardware commit predicate and the
// real core are covered by tb_auth.sv and tb_auth_window.sv.
// SPDX-License-Identifier: BSD-2-Clause
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AUTH_ROM_HOST
#include "window.c"

#define W ((uint64_t)WINDOW_CYCLES)
#define SLACK 16u
#define T0 1000u                       /* the routine's first mcycle read */
#define NEVER (~0ull)
#define MAX_ABORTS 8

static struct {
    uint64_t t;                        /* cycle of the current access */
    uint64_t resp_at[10];              /* cycle each response word reaches RX */
    uint64_t abort_at[MAX_ABORTS];     /* single ABORTs */
    uint64_t storm_from, storm_to, storm_period;   /* periodic ABORTs */
    unsigned rng_opst;
    int corrupt;
    /* mailbox state */
    unsigned tx_count, tx_since_reset, rx_rd;
    uint64_t last_reset;
    int sess, started, bootdone, unlocked;
    uint64_t unlock_t, last_pop_t;
    unsigned next_abort;
    uint64_t next_storm;
} m;

static const char *scenario = "";

static void fail(const char *what) {
    printf("FAIL auth ROM host model [%s]: %s (cycle %llu, deadline %llu)\n", scenario, what,
           (unsigned long long)(m.t - T0), (unsigned long long)W);
    exit(1);
}

static uint32_t rotl32(uint32_t x, unsigned r) { return r ? (x << r) | (x >> (32 - r)) : x; }
static const uint32_t host_key[8] = {
    0x6b617275u, 0x64626761u, 0x75746821u, 0x54455354u,
    0x2d6f6e6cu, 0x792d6e6fu, 0x742d6372u, 0x7970746fu };
static uint32_t response_word(unsigned i) {
    if (i == 0) return 0x02018000u;
    if (i == 1) return 0x00010020u;
    uint32_t a = host_key[i - 2] ^ 0x01010101u;
    for (unsigned j = i - 2; j < 20; j += 8) a ^= rotl32(challenge[j], i - 2);
    return (m.corrupt && i == 5) ? a ^ 1u : a;
}

static void session_reset(void) {
    if (m.started) m.bootdone = 1;     /* hardware closes the window */
    m.sess = 1; m.tx_count = 0; m.tx_since_reset = 0; m.last_reset = m.t;
}

/* One access = one cycle; host events due at or before it take effect. */
static void tick(void) {
    m.t++;
    if (m.t > T0 + W + SLACK) fail("I2: routine still running after the deadline");
    while (m.next_abort < MAX_ABORTS && m.abort_at[m.next_abort] != NEVER &&
           T0 + m.abort_at[m.next_abort] <= m.t) { session_reset(); m.next_abort++; }
    while (m.storm_period && m.next_storm <= m.t && m.next_storm < T0 + m.storm_to) {
        session_reset(); m.next_storm += m.storm_period;
    }
    if (m.tx_count) m.tx_count--;      /* the host drains TX */
}

static int rx_ready(void);
uint64_t mock_cycles(void) { tick(); return m.t; }
/* The routine reads AUTH once before its first mcycle read, which is T0. */

uint64_t mock_read(unsigned csr) {
    tick();
    if (csr == CSR_AUTH) return AUTH_REQ | (1u << 4) | (1u << 16) | (m.bootdone ? AUTH_BOOTDONE : 0);
    if (csr == CSR_MBST)
        return (m.sess ? MBST_SESS : 0) | (m.started ? MBST_STARTED : 0) | ((16u - m.tx_count) << 5);
    if (csr == CSR_RX) return rx_ready() ? (1ull << 32) | response_word(m.rx_rd) : 0;   /* no pop */
    fail("unexpected CSR read");
    return 0;
}

/* A word is in RX once the host has the whole challenge of this session
   and its delivery cycle has come; a session reset drops earlier ones. */
static int rx_ready(void) {
    return m.rx_rd < 10 && m.tx_since_reset >= 20 && m.resp_at[m.rx_rd] != NEVER &&
           T0 + m.resp_at[m.rx_rd] <= m.t && T0 + m.resp_at[m.rx_rd] > m.last_reset;
}

uint64_t mock_rw(unsigned csr, uint64_t w) {
    (void)w;
    tick();
    if (csr == CSR_RNG) return ((uint64_t)m.rng_opst << 30) | ((m.t * 0x9e37u) & 0xffffu);
    if (csr != CSR_RX) fail("unexpected CSR read-write");
    if (rx_ready()) {
        m.started = 1; m.last_pop_t = m.t;
        return (1ull << 32) | response_word(m.rx_rd++);
    }
    return 0;
}

void mock_set(unsigned csr, uint64_t w) {
    tick();
    if (csr != CSR_AUTH) fail("unexpected CSR set");
    if (w & AUTH_SESS_ACK) m.sess = 0;
    if ((w & AUTH_UNLOCK) && !m.bootdone && !m.unlocked) { m.unlocked = 1; m.unlock_t = m.t; }
}

void mock_write(unsigned csr, uint64_t w) {
    (void)w;
    tick();
    if (csr != CSR_TX) fail("unexpected CSR write");
    if (m.tx_count < 16) { m.tx_count++; m.tx_since_reset++; }
}

static void reset_model(const char *name) {
    scenario = name;
    memset(&m, 0, sizeof m);
    m.t = T0 - 2; m.rng_opst = 2;
    for (unsigned i = 0; i < 10; i++) m.resp_at[i] = NEVER;
    for (unsigned i = 0; i < MAX_ABORTS; i++) m.abort_at[i] = NEVER;
}
static void respond_at(uint64_t first, uint64_t step) {
    for (unsigned i = 0; i < 10; i++) m.resp_at[i] = first + i * step;
}
static void storm(uint64_t from, uint64_t to, uint64_t period) {
    m.storm_from = from; m.storm_to = to; m.storm_period = period; m.next_storm = T0 + from;
}

/* Run the routine and check I1; want: 1 must unlock, 0 must not, -1 either. */
static void run(int want) {
    auth_window();
    if (m.unlocked) {
        if (m.unlock_t > T0 + W) fail("I1: grant written after the deadline");
        if (m.last_pop_t >= T0 + W) fail("I1: grant uses a response word popped at or after the deadline");
        if (m.corrupt) fail("grant for a wrong signature");
    }
    if (want == 1 && !m.unlocked) fail("I3: valid response in time did not unlock");
    if (want == 0 && m.unlocked) fail("unlocked where the schedule requires locked");
}

static uint64_t rnd_state = 0x243f6a8885a308d3ull;
static uint64_t rnd(uint64_t n) {
    rnd_state ^= rnd_state << 13; rnd_state ^= rnd_state >> 7; rnd_state ^= rnd_state << 17;
    return rnd_state % n;
}

int main(void) {
    unsigned cases = 0, unlocked = 0;

    reset_model("response well inside the window"); respond_at(W / 2, 3); run(1); cases++;
    reset_model("wrong signature"); respond_at(W / 2, 3); m.corrupt = 1; run(0); cases++;
    reset_model("silence"); run(0); cases++;
    /* The reviewed defect: a complete response first available one cycle
       after the deadline. */
    reset_model("response available at deadline+1"); respond_at(W + 1, 0); run(0); cases++;
    reset_model("response available at the deadline"); respond_at(W, 0); run(0); cases++;
    reset_model("last word after the deadline");
    respond_at(W - 200, 1); m.resp_at[9] = W + 1; run(0); cases++;
    reset_model("first word before, rest after"); respond_at(W + 1, 0); m.resp_at[0] = W - 50; run(0); cases++;
    /* Queued data whose parsing or decision crosses the deadline. */
    for (uint64_t back = 1; back <= 120; back++) {
        reset_model("queued response just before the deadline"); respond_at(W - back, 0); run(-1);
        cases++; unlocked += m.unlocked;
    }
    reset_model("repeated ABORTs forever"); storm(0, NEVER - T0, 7); run(0); cases++;
    reset_model("repeated ABORTs forever, dense"); storm(0, NEVER - T0, 2); run(0); cases++;
    reset_model("ABORTs past the deadline, then a response");
    storm(0, W + 10, 7); respond_at(W + 12, 0); run(0); cases++;
    reset_model("ABORTs until just before the deadline, then a response");
    storm(0, W - 40, 7); respond_at(W - 30, 0); run(-1); cases++;
    reset_model("three early ABORTs, then a response in time");
    m.abort_at[0] = 30; m.abort_at[1] = 400; m.abort_at[2] = 1500; respond_at(5000, 2); run(1); cases++;
    reset_model("ABORT after the first response word");
    respond_at(2000, 50); m.abort_at[0] = 2100; run(0); cases++;
    reset_model("stalled TRNG"); m.rng_opst = 1; run(0); cases++;
    reset_model("dead TRNG"); m.rng_opst = 3; run(0); cases++;

    /* Random schedules around the deadline. */
    for (unsigned n = 0; n < 400; n++) {
        reset_model("random schedule");
        uint64_t first = W - 400 + rnd(500), at = first;
        for (unsigned i = 0; i < 10; i++) { m.resp_at[i] = at; at += rnd(4) ? rnd(12) : rnd(200); }
        unsigned aborts = (unsigned)rnd(4);
        uint64_t a = 0;
        for (unsigned i = 0; i < aborts; i++) { a += 1 + rnd(W / 2); m.abort_at[i] = a; }
        if (rnd(4) == 0) storm(rnd(W), W - 600 + rnd(700), 3 + rnd(40));
        run(-1); cases++; unlocked += m.unlocked;
    }
    printf("auth ROM host model: PASS (%u schedules, %u of the boundary/random ones unlocked, "
           "window %llu cycles)\n", cases, unlocked, (unsigned long long)W);
    if (unlocked == 0) { printf("FAIL: no boundary schedule unlocked; the sweep is vacuous\n"); return 1; }
    return 0;
}
