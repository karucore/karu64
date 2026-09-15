// Architectural access-fault regression. The HTIF responder injects an R
// error at 0x800f0008 and a B error at 0x800f0088. No reference-model changes.
// Checks software-breakpoint PCs, cause, full-width tval, vstart, ff trimming, and that
// a posted store fault cancels the following granule before it reaches RAM.
// TEST_ATOMIC_ONLY selects Karu's atomic alignment/device/canary checks.
// TEST_ATOMIC_ALIGN_ONLY selects the portable RAM alignment subset for Spike
// with Zicclsm enabled. Physical-device atomic capabilities are platform-specific.
#ifndef TEST_ATOMIC_ONLY
#define TEST_ATOMIC_ONLY 0
#endif
#ifndef TEST_ATOMIC_ALIGN_ONLY
#define TEST_ATOMIC_ALIGN_ONLY 0
#endif
    .option norvc
    .section .text.boot,"ax"
    .globl _start
    .macro ARM cause, addr, start=0
    addi s0,s0,1
    li s1,0
    li s3,\cause
    mv s4,\addr
    li s5,\start
    la s6,991f
    .endm
    .macro CHECK
991:
    beqz s1,fail
    csrw vstart,zero
    .endm
_start:
    li s0,0
    la t0,handler
    csrw mtvec,t0
    li t0,0x6600
    csrs mstatus,t0
    // Every LR/SC/AMO word/doubleword form at every misaligned byte offset.
    // Canary beats straddle a cache line, then a page; rd must not be written.
    li s2,0x80003038
atomic_alignment_start:
    li s7,0x1122334455667788
    sd s7,0(s2)
    sd s7,8(s2)
    li s8,0
    li s10,1                    // handler also checks the exact atomic EPC
atomic_next_op:
    li s9,1
atomic_next_offset:
    li t3,11
    bgeu s8,t3,atomic_try
    li t3,4
    beq s9,t3,atomic_skip        // word offset 4 is naturally aligned
atomic_try:
    add t0,s2,s9
    li t1,0x5a5a5a5a
    li t2,0x8877665544332211
    la s11,atomic_instructions
    slli t3,s8,3
    add s11,s11,t3
    ARM 7,t0
    beqz s8,atomic_lr
    li t3,11
    bne s8,t3,atomic_issue
atomic_lr:
    li s3,5
atomic_issue:
    jalr ra,s11,0
    j fail                      // an unsupported atomic must never complete
    CHECK
    li t3,0x5a5a5a5a
    bne t1,t3,fail
    li t3,2
    beq s10,t3,atomic_device_next
    ld t3,0(s2)
    bne t3,s7,fail
    ld t3,8(s2)
    bne t3,s7,fail
atomic_skip:
    addi s9,s9,1
    li t3,8
    bne s9,t3,atomic_next_offset
    addi s8,s8,1
    li t3,22
    bne s8,t3,atomic_next_op
    li t3,0x80003ff8
    beq s2,t3,atomic_alignment_done
    mv s2,t3
    j atomic_alignment_start
atomic_alignment_done:
#if TEST_ATOMIC_ALIGN_ONLY
    li a0,0
    j exit
#endif
    // Physical devices have no atomic/reservation capability, even aligned.
    li s10,2
    li s9,0
    li a2,5
    la a3,atomic_devices
atomic_device_begin:
    ld s2,0(a3)
    li s8,0
    j atomic_try
atomic_device_next:
    addi s8,s8,1
    li t3,22
    bne s8,t3,atomic_try
    addi a3,a3,8
    addi a2,a2,-1
    bnez a2,atomic_device_begin
    li s10,0
#if TEST_ATOMIC_ONLY
    li a0,0
    j exit
#endif
    // Both software-breakpoint encodings report the faulting PC in EPC/tval.
    la t0,break32
    ARM 3,t0
break32:
    ebreak
    CHECK
    la t0,break16
    ARM 3,t0
break16:
    .2byte 0x9002                 // C.EBREAK, followed by an unaligned 32-bit op
    CHECK
    .2byte 0x0001                 // C.NOP restores word alignment for norvc padding
    li t0,0
    ARM 5,t0
    ld t1,0(t0)
    CHECK
    ARM 7,t0
    sd t1,0(t0)
    CHECK
    ARM 5,t0
    lr.d t1,(t0)
    CHECK
    ARM 7,t0
    amoadd.d t1,t1,(t0)
    CHECK
    ARM 7,t0
    sc.d t1,t1,(t0)
    CHECK
    li t0,0x180000000
    ARM 5,t0
    ld t1,0(t0)
    CHECK
    li t0,0x1000
    ARM 7,t0
    sd t1,0(t0)
    CHECK
    li t0,0xfffffffc
    li t2,0x100000000
    ARM 7,t2
    sd t1,0(t0)
    CHECK
    li t0,0x200000
    ARM 5,t0
    ld t1,0(t0)
    CHECK
    // A mapped PMA outside the simulator's RAM must produce DECERR.
    li t0,0x90000000
    ARM 5,t0
    ld t1,0(t0)
    CHECK
    // Refill error, then the same read again: never cache an errored line.
    li t0,0x800f0000
    ARM 5,t0
    ld t1,0(t0)
    CHECK
    ARM 5,t0
    ld t1,0(t0)
    CHECK
    ARM 7,t0
    amoadd.d t1,t1,(t0)
    CHECK
    li t0,0x800efffc
    li t2,0x800f0000
    ARM 5,t2
    ld t1,0(t0)
    CHECK
    li t0,0x800f0088
    ARM 7,t0
    sd t1,0(t0)
    CHECK
    li t0,0x800f0084
    li t2,0x800f0088
    ARM 7,t2
    sd t1,0(t0)
    CHECK
    li t0,0x800f0080
    ARM 7,t0
    .insn i 0x0f, 2, x0, t0, 4  // cbo.zero
    CHECK
    // Load prefix is committed before reporting the failing element.
    vsetivli zero,8,e64,m2,tu,mu
    vmv.v.i v8,11
    li t0,0x800effe0
    li t2,0x800f0000
    ARM 5,t2,4
    vle64.v v8,(t0)
    CHECK
    vmv.x.s t1,v9
    li t2,11
    bne t1,t2,fail
    // The same failure is suppressed by ff, retaining only the prefix.
    li s3,0
    vle64ff.v v8,(t0)
    csrr t1,vl
    li t2,4
    bne t1,t2,fail
    csrr t1,vstart
    bnez t1,fail
    // A masked element zero does not turn an element-one fault into a trap.
    vsetivli zero,4,e64,m1,tu,mu
    vmv.v.i v0,2
    li t0,0
    vle64ff.v v8,(t0),v0.t
    csrr t1,vl
    li t2,1
    bne t1,t2,fail
    // Segment ff and strided non-ff use the per-element engine.
    vsetivli zero,4,e64,m1,tu,mu
    li t0,0x800effe0
    vlseg2e64ff.v v8,(t0)
    csrr t1,vl
    li t2,2
    bne t1,t2,fail
    vsetivli zero,4,e64,m1,tu,mu
    li t0,0x800efff0
    li t1,8
    li t2,0x800f0000
    ARM 5,t2,2
    vlse64.v v8,(t0),t1
    CHECK
    // Error in the middle of a posted stream; queued suffix stays untouched.
    li t0,0x800f0090
    li t1,0x777
    sd t1,0(t0)
    vsetivli zero,8,e64,m2,tu,mu
    vmv.v.i v8,9
    li t0,0x800f0070
    li t2,0x800f0080
    ARM 7,t2,2
    vse64.v v8,(t0)
    CHECK
    li t0,0x800f0090
    ld t1,0(t0)
    li t2,0x777
    bne t1,t2,fail
    // Per-element stores wait for B and report their element, not the next.
    vsetivli zero,4,e64,m1,tu,mu
    li t0,0x800f0080
    li t1,8
    li t2,0x800f0088
    ARM 7,t2,1
    vsse64.v v8,(t0),t1
    CHECK
    // Repeat the boundary/error contracts with S-mode PMLEN16 tags. The
    // bad read is in the second granule of a misaligned element and on the
    // next page: this covers final-VA masking, the FF prefix and bus tval.
    li t0,0x800effeb
    li t1,1
    li t2,22
1:  sb t1,0(t0)
    addi t0,t0,1
    addi t1,t1,1
    bne t1,t2,1b
    li t0,(3 << 32)
    csrw 0x30a,t0
    li s7,0xa5a5000000000000
    la t0,tagged_handler
    csrw mtvec,t0
    la t0,tagged_access
    csrw mepc,t0
    li t0,0x1800
    csrc mstatus,t0
    li t0,0x800
    csrs mstatus,t0
    mret
tagged_access:
    vsetivli zero,4,e64,m1,tu,mu
    vmv.v.i v8,11
    li t0,0x800effeb
    or t0,t0,s7
    li t2,0x800f0000
    ARM 5,t2,2
    vle64.v v8,(t0)
    CHECK
    csrr t1,vl
    li t2,4
    bne t1,t2,fail
    jal ra,tagged_check_prefix
    // Contiguous FF must trim to two complete elements, not count tag bits.
    addi s0,s0,1
    li s3,0
    vmv.v.i v8,11
    vle64ff.v v8,(t0)
    csrr t1,vl
    li t2,2
    bne t1,t2,fail
    csrr t1,vstart
    bnez t1,fail
    vsetivli zero,4,e64,m1,tu,mu
    jal ra,tagged_check_prefix
    // A masked element zero followed by an AXI fault trims without a trap.
    addi s0,s0,1
    vmv.v.i v8,11
    vmv.v.i v0,2
    li t0,0x800f0000
    or t0,t0,s7
    vle64ff.v v8,(t0),v0.t
    csrr t1,vl
    li t2,1
    bne t1,t2,fail
    csrr t1,vstart
    bnez t1,fail
    vsetivli zero,4,e64,m1,tu,mu
    li t2,0x80003400
    vse64.v v8,(t2)
    li t4,11
    ld t3,0(t2)
    bne t3,t4,fail
    ld t3,8(t2)
    bne t3,t4,fail
    ld t3,16(t2)
    bne t3,t4,fail
    ld t3,24(t2)
    bne t3,t4,fail
    // Strided split read: high stride bits are masked before the second
    // granule is translated; the fault still identifies element two.
    li t0,0x800effeb
    or t0,t0,s7
    li t1,(1 << 48) + 8
    li t2,0x800f0000
    ARM 5,t2,2
    vlse64.v v8,(t0),t1
    CHECK
    jal ra,tagged_check_prefix
    // Segment FF uses the same g1va split and retains only segment zero.
    addi s0,s0,1
    li s3,0
    vsetivli zero,2,e64,m1,tu,mu
    vmv.v.i v8,11
    vmv.v.i v9,12
    vlseg2e64ff.v v8,(t0)
    csrr t1,vl
    li t2,1
    bne t1,t2,fail
    csrr t1,vstart
    bnez t1,fail
    vsetivli zero,2,e64,m1,tu,mu
    li t2,0x80003400
    vse64.v v8,(t2)
    addi t2,t2,16
    vse64.v v9,(t2)
    ld t3,-16(t2)
    li t4,0x0807060504030201
    bne t3,t4,fail
    ld t3,-8(t2)
    li t4,11
    bne t3,t4,fail
    ld t3,0(t2)
    li t4,0x100f0e0d0c0b0a09
    bne t3,t4,fail
    ld t3,8(t2)
    li t4,12
    bne t3,t4,fail
    // Posted B error: preserve the queued suffix and the preceding canary.
    li t0,0x800f0090
    li t1,0x777
    sd t1,0(t0)
    li t0,0x800f0068
    li t1,0x555
    sd t1,0(t0)
    vsetivli zero,8,e64,m2,tu,mu
    vmv.v.i v8,9
    li t0,0x800f0070
    or t0,t0,s7
    li t2,0x800f0080
    ARM 7,t2,2
    vse64.v v8,(t0)
    CHECK
    li t0,0x800f0090
    ld t1,0(t0)
    li t2,0x777
    bne t1,t2,fail
    li t0,0x800f0068
    ld t1,0(t0)
    li t2,0x555
    bne t1,t2,fail
    ld t1,8(t0)
    li t2,9
    bne t1,t2,fail
    ld t1,16(t0)
    bne t1,t2,fail
    // An unaligned store fault within the first granule reports the exact
    // masked element address, not that granule's aligned base.
    li t0,0x800f0082
    li t1,0x5a
    sb t1,0(t0)
    vsetivli zero,1,e64,m1,tu,mu
    li t0,0x800f0083
    li t2,0x800f0083
    or t0,t0,s7
    ARM 7,t2,0
    vsse64.v v8,(t0),zero
    CHECK
    li t0,0x800f0082
    lbu t1,0(t0)
    li t2,0x5a
    bne t1,t2,fail
    li t0,0x800f0090
    ld t1,0(t0)
    li t2,0x777
    bne t1,t2,fail
    ecall
    j fail
tagged_done:
    // A posted fault through an Sv39 alias must report the VA, not its PA.
    li t0,0x80002000
    li t1,0x200000cf              // 1 GiB RWXAD leaf at physical 0x80000000
    sd t1,0(t0)                  // VA 0..0x3fffffff aliases RAM
    sd t1,16(t0)                 // identity mapping for S-mode code
    vsetivli zero,8,e64,m2,tu,mu
    li t2,0xf0080
    ARM 7,t2,2
    li t1,0x8000000000080002
    csrw satp,t1
    sfence.vma
    la t1,store_alias
    csrw mepc,t1
    li t1,0x1800
    csrc mstatus,t1
    li t1,0x800
    csrs mstatus,t1
    li t0,0xf0070
    mret
store_alias:
    vse64.v v8,(t0)
    CHECK
    // PTW refill errors become access faults, not page faults or stale PTEs.
    la t0,fetch_target
    ARM 1,t0
    li t1,0x80000000000800f0
    csrw satp,t1
    sfence.vma
    csrw mepc,t0
    li t1,0x1800
    csrc mstatus,t1
    li t1,0x800
    csrs mstatus,t1
    mret
    .balign 8
fetch_target:
    j fail
    CHECK
    li a0,0
    j exit
    // Prefix/destination-canary checker; preserves tagged base t0 and ra.
tagged_check_prefix:
    li t2,0x80003400
    vse64.v v8,(t2)
    ld t3,0(t2)
    li t4,0x0807060504030201
    bne t3,t4,fail
    ld t3,8(t2)
    li t4,0x100f0e0d0c0b0a09
    bne t3,t4,fail
    ld t3,16(t2)
    li t4,11
    bne t3,t4,fail
    ld t3,24(t2)
    bne t3,t4,fail
    ret
    .balign 4
tagged_handler:
    csrr t3,mcause
    li t4,9
    beq t3,t4,tagged_return_m
    bne t3,s3,fail
    csrr t3,mtval
    bne t3,s4,fail
    csrr t3,vstart
    bne t3,s5,fail
    li s1,1
    csrw mepc,s6
    mret
tagged_return_m:
    la t0,handler
    csrw mtvec,t0
    li t0,0x1800
    csrs mstatus,t0
    la t0,tagged_done
    csrw mepc,t0
    mret
    .balign 4
handler:
    csrr t3,mcause
    bne t3,s3,fail
    beqz s10,atomic_epc_checked
    csrr t4,mepc
    bne t4,s11,fail
atomic_epc_checked:
    li t4,3
    bne t3,t4,1f
    csrr t4,mepc
    bne t4,s4,fail
1:
    csrr t3,mtval
    bne t3,s4,fail
    csrr t3,vstart
    bne t3,s5,fail
    li s1,1
    csrw satp,zero
    li t3,0x1800
    csrs mstatus,t3
    csrw mepc,s6
    mret
fail:
    addi a0,s0,1
exit:
    slli a0,a0,1
    ori a0,a0,1
    la t0,tohost
    sd a0,0(t0)
1:  j 1b
    // Each entry is one operation followed by RET. Fixed register fields:
    // rd=t1, rs1=t0, rs2=t2 (zero for LR); .W then .D, aq=rl=0.
    .balign 4
atomic_instructions:
    .irp width,2,3
      .irp f5,2,3,1,0,4,12,8,16,20,24,28
        .if \f5 == 2
          .word (\f5 << 27) | (5 << 15) | (\width << 12) | (6 << 7) | 0x2f
        .else
          .word (\f5 << 27) | (7 << 20) | (5 << 15) | (\width << 12) | (6 << 7) | 0x2f
        .endif
        ret
      .endr
    .endr
    .balign 8
atomic_devices:
    .dword 0x02000000,0x0c000000,0x10000000,0x11000000,0x12000000
    .section .htif,"aw",@progbits
    .globl tohost,fromhost
tohost: .dword 0
fromhost: .dword 0
