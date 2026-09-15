// SPDX-License-Identifier: BSD-3-Clause
// Focused Sail-reference regression. No MIDELEG write precedes a reset probe
// or injected-interrupt test. PROBE/GEILEN/H_PRESENT are build-time constants.
    .section .text
    .globl _start
_start:
    la t0, failed
    csrw mtvec, t0
#if PROBE == 0 || PROBE == 1
    li t0, 0x1000
#if PROBE == 0
    csrw mie, t0
#else
    csrw 0x604, t0                 // hie
#endif
    csrr t1, mie
    and t1, t1, t0
    bne t1, t0, failed
    csrr t1, 0x604
    and t1, t1, t0
    bne t1, t0, failed
    // The opposite CSR alias must clear SGEIE, without losing VS enables.
    li t0, 0x444
#if PROBE == 0
    csrw 0x604, t0
#else
    csrw mie, t0
#endif
    csrr t1, mie
    li t2, 0x1444
    and t1, t1, t2
    bne t1, t0, failed
    csrr t1, 0x604
    bne t1, t0, failed
    li t0, -1
    csrw 0x607, t0                 // hgeie
    csrr t1, 0x607
#if GEILEN == 0
    bnez t1, failed
#else
    li t0, 2
    and t1, t1, t0
    bne t1, t0, failed
#endif
#elif PROBE == 2
    csrr t0, mideleg               // First MIDELEG access: read, not write.
    li t1, 0x1444
    and t0, t0, t1
#if !H_PRESENT
    li t1, 0
#endif
    bne t0, t1, failed
    csrw mideleg, zero
    csrr t0, mideleg
    li t2, 0x1444
    and t0, t0, t2
    bne t0, t1, failed
#elif PROBE == 3
    li t0, 0x1444
    csrw mie, t0
    csrr t1, mie
    and t1, t1, t0
    bnez t1, failed
#elif PROBE == 4 || PROBE == 5
    // Permit this small bare-mode monitor in S/VS. This is fixture setup,
    // not a claim that PMP is implemented by the processor under test.
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 0x1f
    csrw pmpcfg0, t0
    la t0, irq_handler
#if PROBE == 4
    csrw stvec, t0
    csrw 0x603, zero               // hideleg: VSSIP goes to HS.
    li t0, 0x802                   // MPP=S, host SIE=1.
#else
    csrw 0x205, t0                 // vstvec
    li t0, 4
    csrw 0x603, t0                 // hideleg: VSSIP goes to VS as SSI.
    li t0, 2
    csrw 0x200, t0                 // vsstatus.SIE
    li t0, 0x8000000800            // MPV=1, MPP=S.
#endif
    csrw mstatus, t0
    la t0, no_interrupt
    csrw mepc, t0
    li t0, 4
    csrw 0x604, t0                 // hie.VSSIE
    csrw 0x645, t0                 // hvip.VSSIP
    mret
no_interrupt:
    j failed
    .balign 4
irq_handler:
    csrr t0, scause
#if PROBE == 4
    li t1, 0x8000000000000002
#else
    li t1, 0x8000000000000001
#endif
    bne t0, t1, failed
#endif
passed:
    li t0, 1
    j finish
failed:
    li t0, 3
finish:
    la t1, tohost
    sd t0, 0(t1)
1:  j 1b
    .section .tohost,"aw",@progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
