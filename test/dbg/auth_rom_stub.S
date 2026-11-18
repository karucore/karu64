// Simulation-only island ROM stub for the A1 real-core authentication test
// (doc/debug-auth-contract.md). NOT a verifier: it accepts one fixed test
// word instead of a signature. The A2 ROM replaces it.
// SPDX-License-Identifier: BSD-2-Clause
    .section .text
    .globl _start
_start:                         // RESET_PC = 0x0001_0000 (island ROM)
    li      t0, 0x80000100      // RAM trap handler for the application
    csrw    mtvec, t0
    csrr    t0, 0x7c0           // mdbgauth
    andi    t1, t0, 0x2         // boot_done: window already closed
    bnez    t1, leave
    andi    t1, t0, 0x80        // auth_req: no REQUEST, boot normally
    beqz    t1, leave
    li      t2, 0xc0de0001      // one-word "challenge"
    csrw    0x7c2, t2           // mdbgtx push (CSRRW)
wait_rx:
    csrrw   t3, 0x7c1, zero     // mdbgrx pop: {valid[32], data[31:0]}
    srli    t4, t3, 32
    beqz    t4, wait_rx
    slli    t3, t3, 32
    srli    t3, t3, 32
    li      t6, 0x20000         // round trip through island SRAM, so a forged
    sd      t3, 0(t6)           // load response would decide the outcome
    ld      t3, 0(t6)
    li      t5, 0x600df00d      // TEST response word
    bne     t3, t5, leave
    csrsi   0x7c0, 1            // auth_unlock: ROM PC, M-mode, window open
leave:
    csrsi   0x7c0, 2            // boot_done
    li      t0, 0x80000000
    jr      t0
