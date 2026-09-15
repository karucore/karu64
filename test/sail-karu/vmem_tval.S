// SPDX-License-Identifier: BSD-3-Clause
// One exact access-fault probe per ELF. The checker selects OP, TEST_VA,
// TRANSLATED, SPLIT and DELEGATE. All page tables and code are in valid RAM;
// a valid leaf maps the tested address to a physical PMA hole, not a bad PTE.
// SPLIT=1 maps the first page to RAM and the second to that hole.
// SPLIT=2 uses RAM and an NA4 PMP denial for the second 4-byte constituent.
    .option norvc
    .section .text
    .globl _start
_start:
    la t0, failed
    csrw mtvec, t0
    csrw mie, zero
    csrw medeleg, zero
    csrw satp, zero
    // Reference-fixture bootstrap only; not a processor PMP claim.
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 0x1f
    csrw pmpcfg0, t0

#if TRANSLATED
    // Root/L1/L0 occupy three otherwise-unused physical RAM pages.
    li t0, 0x80002000
    li t1, 0x80005000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, 1b
    // Identity-map the RAM superpage so HS code, handlers and HTIF work.
    li t0, 0x80002010
    li t1, 0x200000cf
    sd t1, 0(t0)
    li t0, 0x80002000 + (((TEST_VA >> 30) & 511) * 8)
    li t1, 0x20000c01             // Root -> physical 0x80003000.
    sd t1, 0(t0)
    li t0, 0x80003000 + (((TEST_VA >> 21) & 511) * 8)
    li t1, 0x20001001             // L1 -> physical 0x80004000.
    sd t1, 0(t0)
    li t0, 0x80004000 + (((TEST_VA >> 12) & 511) * 8)
#if SPLIT == 1
    li t1, 0x200020cf             // First leaf: physical RAM 0x80008000.
    sd t1, 0(t0)
    li t1, 0x100004cf             // Next leaf: physical hole 0x40001000.
    sd t1, 8(t0)
    li t0, 0x80008ff8
    li t1, 0x0123456789abcdef
    sd t1, 0(t0)
#elif SPLIT == 2
    li t1, 0x200020cf             // Both constituents are in RAM 0x80008000.
    sd t1, 0(t0)
    li t0, 0x80008100
    li t1, 0x0123456789abcdef
    sd t1, 0(t0)
    sd t1, 8(t0)
#else
    li t1, 0x100000cf             // Leaf: physical hole 0x40000000.
    sd t1, 0(t0)
#endif
    li t0, 0x8000000000080002     // Sv39, root physical 0x80002000.
    csrw satp, t0
#if OP == 5 || OP == 6 || OP == 7
    csrw 0x280, t0               // HLV/HSV use VS translation, G is Bare.
    csrw 0x680, zero
    li t0, 0x100                 // hstatus.SPVP=S; H access is to VS.
    csrw 0x600, t0
    hfence.vvma zero, zero
#endif
    sfence.vma zero, zero
#endif

#if SPLIT == 2
    // Entry0 denies physical 0x80008108..10b; entry1 permits everything
    // else. The misaligned 8-byte access at +0x104 decomposes to two
    // aligned 4-byte accesses, so its physical fault offset is exactly 4.
    csrw pmpcfg0, zero
    li t0, 0x20002042
    csrw pmpaddr0, t0
    li t0, -1
    csrw pmpaddr1, t0
    li t0, 0x1f10
    csrw pmpcfg0, t0
#endif
    li a0, TEST_VA
#if SPLIT == 1
    li s1, (TEST_VA & ~4095) + 4096
#elif SPLIT == 2
    li s1, TEST_VA + 4
#else
    li s1, TEST_VA
#endif
#if OP == 1 || OP == 3 || OP == 4 || OP == 5 || OP == 9
    li s0, 7                     // Store/AMO access fault.
#else
    li s0, 5                     // Load access fault (including LR).
#endif
    li s2, 0x7654321012345678     // Faulting destination must not commit.
    li s3, 0x1122334455667788     // Store/AMO data must not be clobbered.
    la s4, faulting_instruction
    la t0, expected_trap
#if DELEGATE
    csrw stvec, t0
    li t0, 0xa0                  // Delegate load/store access faults only.
    csrw medeleg, t0
#else
    csrw mtvec, t0
#endif
    li t0, 0x800                 // Enter host S/HS, V=0, interrupts disabled.
    csrw mstatus, t0
    la t0, faulting_instruction
    csrw mepc, t0
    mret

faulting_instruction:
#if OP == 0
    ld s2, 0(a0)
#elif OP == 1
    sd s3, 0(a0)
#elif OP == 2
    lr.d s2, (a0)
#elif OP == 3
    amoadd.d s2, s3, (a0)
#elif OP == 4
    sc.d s2, s3, (a0)            // No reservation: independent PMA-fault path.
#elif OP == 5
    hsv.d s3, (a0)
#elif OP == 6
    hlv.d s2, (a0)
#elif OP == 7
    hlvx.wu s2, (a0)
#elif OP == 8
    lr.w s2, (a0)
#elif OP == 9
    amoadd.w s2, s3, (a0)
#else
#error Unknown access-fault probe operation
#endif
    j failed                     // A returned value is never a valid verdict.

    .balign 4
expected_trap:
#if DELEGATE
    csrr t0, scause
    csrr t1, stval
    csrr t2, sepc
#else
    csrr t0, mcause
    csrr t1, mtval
    csrr t2, mepc
#endif
    bne t0, s0, failed
    bne t2, s4, failed
    li t0, 0x7654321012345678
    bne s2, t0, failed
    li t0, 0x1122334455667788
    bne s3, t0, failed
    li t0, TEST_VA
    bne a0, t0, failed
    bne t1, s1, wrong_tval
passed:
    li t0, 1
    j finish
    .balign 4
failed:
    li t0, 5                     // Failure 2: not the targeted tval mismatch.
    j finish
wrong_tval:
    li t0, 3
finish:
    la t1, tohost
    sd t0, 0(t1)
    j .

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost, fromhost
tohost:   .dword 0
fromhost: .dword 0
