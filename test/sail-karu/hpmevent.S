// SPDX-License-Identifier: BSD-3-Clause
// Event-selector WARL probe, independent of event-counting semantics.
// EVENT_MASK/HIGH_MASK describe the selected implementation configuration.
    .section .text
    .globl _start
_start:
    la t0,failed
    csrw mtvec,t0
    csrw mie,zero
    li s0,(HIGH_MASK|EVENT_MASK)

    // Every implemented counter selector uses the same platform mask.
    .irp csr,0x323,0x324,0x325,0x326,0x327,0x328,0x329,0x32a,0x32b,0x32c,0x32d,0x32e,0x32f,0x330,0x331,0x332,0x333,0x334,0x335,0x336,0x337,0x338,0x339,0x33a,0x33b,0x33c,0x33d,0x33e,0x33f
    li t0,-1
    csrw \csr,t0
    csrr t1,\csr
    bne t1,s0,failed
    .endr

    // All six CSR forms and every bit, including the Sscofpmf controls.
    .irp csr,0x323,0x331,0x33f
    csrw \csr,zero
    li t0,-1
    csrrw t1,\csr,t0
    bnez t1,failed
    csrrc t1,\csr,t0
    bne t1,s0,failed
    csrrs t1,\csr,t0
    bnez t1,failed
    csrrw t1,\csr,zero
    bne t1,s0,failed
    csrrwi t1,\csr,31
    bnez t1,failed
    andi t2,s0,31
    csrrci t1,\csr,1
    bne t1,t2,failed
    andi t2,t2,-2
    csrrsi t1,\csr,1
    bne t1,t2,failed
    csrr t1,\csr
    andi t2,s0,31
    bne t1,t2,failed
    li t3,1
1:  csrw \csr,t3
    csrr t4,\csr
    and t5,t3,s0
    bne t4,t5,failed
    slli t3,t3,1
    bnez t3,1b
    // Selector zero is supported independently of inhibit/overflow flags.
    csrw \csr,zero
    csrr t1,\csr
    bnez t1,failed
    .endr
passed:
    li t0,1
    j finish
failed:
    li t0,3
finish:
    la t1,tohost
    sd t0,0(t1)
1:  j 1b
    .section .tohost,"aw",@progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
