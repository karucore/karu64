// Non-virtual RV64 Sstc directed regression, using karu_priv_test.ld.
// Run on HTIF and Spike (--isa=rv64gcv_zvl256b_sstc, without H).
// Checks access gates, timer delivery/clear/rearm, delegation, legacy
// software-STIP injection and vector state across a timer interrupt.
// Polls are bounded; outcomes do not depend on the reference's timer rate.
// Marker 0x80001100 is one only during the vector-timer overlap test, for
// the optional HTIF overlap observer. No virtual timer support is claimed.
// TEST_CLINT selects a separate 27-case M-mode platform path in this same
// harness: real MMIO time/compare/MSIP, native byte lanes, interrupt delivery,
// and the shared MMIO/CSR/Sstc time domain. It also runs with H enabled.
// TEST_EXTIRQ adds cases 28..48 for the opt-in HTIF external-input registers.
// This platform-specific variant needs HTIF_TB_EXTIRQ as well as HTIF_TB_CLINT;
// Spike does not implement these two HTIF-page devices.
#if defined(TEST_EXTIRQ) && !defined(TEST_CLINT)
#error "TEST_EXTIRQ requires TEST_CLINT"
#endif

    .equ STIMECMP, 0x14d
    .equ STCE, (1 << 63)
    .equ STIP, (1 << 5)
    .equ TM, (1 << 1)
    .equ TOHOST, 0x80001000
    .equ MARK, 0x80001100
    .equ OUT, 0x80003000
    .equ POLL_LIMIT, 200000

    // An illegal CSR instruction preserves rd and reports its exact PC/word.
    .macro ILLEGAL word
    addi s0,s0,1
    li s1,0
    li s2,\word
    la s3,.Lprobe\@
    li a0,0x555
.Lprobe\@:
    .word \word
    li t0,1
    bne s1,t0,fail
    li t0,0x555
    bne a0,t0,fail
    li s2,0
    .endm
    .macro SERVICE command
    li s5,\command
    ecall
    .endm
    .macro WAIT_S count
    li t0,POLL_LIMIT
    li t1,\count
.Lwait_s\@:
    beq s6,t1,.Lwait_s_done\@
    addi t0,t0,-1
    bnez t0,.Lwait_s\@
    j fail
.Lwait_s_done\@:
    .endm
    .macro WAIT_STIP csr, value
    li t0,POLL_LIMIT
.Lpending\@:
    csrr t1,\csr
    andi t1,t1,STIP
    li t2,\value
    beq t1,t2,.Lpending_done\@
    addi t0,t0,-1
    bnez t0,.Lpending\@
    j fail
.Lpending_done\@:
    .endm

    .section .text.boot,"ax"
    .globl _start
    .option norvc
#ifdef TEST_CLINT
    .equ CLINT_MSIP, 0x02000000
    .equ CLINT_CMP, 0x02004000
    .equ CLINT_TIME, 0x0200bff8
_start:
    li s0,1
    li s6,0                     // software IRQ deliveries
    li s7,0                     // machine timer IRQ deliveries
    li s8,0                     // expected interrupt cause, without high bit
    la t0,clint_handler
    csrw mtvec,t0
    csrw mie,zero
    csrci mstatus,8
    csrw medeleg,zero
    csrw mideleg,zero
    // Timer compare reset values are platform-specific. Establish the
    // inactive state explicitly so the same checks also run on Spike.
    li t0,CLINT_CMP
    li t1,-1
    sd t1,0(t0)
    li t0,CLINT_MSIP
    sw zero,0(t0)
    csrr t0,mip
    andi t0,t0,0x88
    bnez t0,fail
    li t0,CLINT_CMP
    ld t1,0(t0)
    li t2,-1
    bne t1,t2,fail
    li t0,CLINT_MSIP
    lwu t1,0(t0)
    bnez t1,fail
    // CLINT must never alias the low-indexed HTIF RAM locations.
    li t0,0x80000000
    ld s11,0(t0)
    li t1,0x6a09e667bb67ae85
    li t0,0x80004000
    sd t1,0(t0)
    li t0,0x8000bff8
    sd t1,0(t0)

    li s0,2
    li t0,CLINT_TIME
    rdtime t1
    ld t2,0(t0)
    rdtime a0
    bltu t2,t1,fail
    bltu a0,t2,fail
    li s0,3
    li t1,0x1234567800000000
    sd t1,0(t0)
    lwu t2,4(t0)
    li a0,0x12345678
    bne t2,a0,fail
    rdtime t2
    srli t2,t2,32
    bne t2,a0,fail              // CSR time cannot remain the core cycle count
    li s0,4
    li t0,CLINT_CMP
    li s10,-1
    sd s10,0(t0)
    ld t1,0(t0)
    bne t1,s10,fail

    // Cases 5..19: all 8 byte, 4 halfword, 2 word and 1 doubleword lanes.
    // Each native store updates only its byte lanes in the 64-bit compare.
    li s4,0                     // log2 transfer size
clint_size:
    li s5,0                     // lane offset
    li a3,1
    sll a3,a3,s4
clint_lane:
    addi s0,s0,1
    li t0,CLINT_CMP
    add t0,t0,s5
    li t1,0x8786858483828180
    slli t2,s5,3
    srl t3,t1,t2
    beqz s4,clint_sb
    li t4,1
    beq s4,t4,clint_sh
    li t4,2
    beq s4,t4,clint_sw
    sd t3,0(t0)
    j clint_lane_check
clint_sb:
    sb t3,0(t0)
    j clint_lane_check
clint_sh:
    sh t3,0(t0)
    j clint_lane_check
clint_sw:
    sw t3,0(t0)
clint_lane_check:
    li t4,-1
    li t5,8
    sub t5,t5,a3
    slli t5,t5,3
    srl t4,t4,t5
    sll t4,t4,t2
    not t5,t4
    and s10,s10,t5
    and t1,t1,t4
    or s10,s10,t1
    li t0,CLINT_CMP
    ld t3,0(t0)
    bne t3,s10,fail
    add s5,s5,a3
    li t0,8
    bltu s5,t0,clint_lane
    addi s4,s4,1
    li t0,4
    bltu s4,t0,clint_size

    li s0,20
    li t0,CLINT_MSIP
    li t1,1
    sb t1,0(t0)
    li t1,0xaa
    sb t1,1(t0)                 // upper byte cannot clear the pending bit
    lwu t1,0(t0)
    andi t1,t1,0xff             // only bit0 is architectural in MSIP
    li t2,1
    bne t1,t2,fail
    csrr t1,mip
    andi t1,t1,8
    beqz t1,fail
    csrci mip,8                 // MSIP remains the external pin's RO value
    csrr t1,mip
    andi t1,t1,8
    beqz t1,fail
    bnez s6,fail                // globally disabled: pending, not delivered
    li s0,21
    li s8,3
    li t0,8
    csrw mie,t0
    csrsi mstatus,8
    li t0,POLL_LIMIT
1:  bnez s6,2f
    addi t0,t0,-1
    bnez t0,1b
    j fail
2:  li t0,1
    bne s6,t0,fail
    li s0,22
    li s8,3
    li t0,CLINT_MSIP
    li t1,1
    sb t1,0(t0)
    li t0,POLL_LIMIT
    li t1,2
1:  beq s6,t1,2f
    addi t0,t0,-1
    bnez t0,1b
    j fail
2:
    li s0,23
    csrci mstatus,8
    li t0,0x80
    csrw mie,t0
    li t0,CLINT_CMP
    sd zero,0(t0)
    csrr t1,mip
    andi t1,t1,0x80
    beqz t1,fail
    bnez s7,fail
    li s0,24
    li s8,7
    csrsi mstatus,8
    li t0,POLL_LIMIT
1:  bnez s7,2f
    addi t0,t0,-1
    bnez t0,1b
    j fail
2:  li t0,1
    bne s7,t0,fail
    li s0,25
    li s8,7
    rdtime a5
    addi a5,a5,1024
    li t0,CLINT_CMP
    sd a5,0(t0)
    li t0,POLL_LIMIT
    li t1,2
1:  beq s7,t1,2f
    addi t0,t0,-1
    bnez t0,1b
    j fail
2:  rdtime t0
    bltu t0,a5,fail
    li s0,26
    li t0,STCE
    csrs 0x30a,t0
    rdtime a5
    addi a5,a5,64
    csrw STIMECMP,a5
    WAIT_STIP mip,STIP
    rdtime t0
    bltu t0,a5,fail
    li t0,-1
    csrw STIMECMP,t0
    WAIT_STIP mip,0
    li s0,27
    li t0,0x80000000
    ld t1,0(t0)
    bne t1,s11,fail
    li t2,0x6a09e667bb67ae85
    li t0,0x80004000
    ld t1,0(t0)
    bne t1,t2,fail
    li t0,0x8000bff8
    ld t1,0(t0)
    bne t1,t2,fail
    csrw mie,zero
    csrci mstatus,8
#ifdef TEST_EXTIRQ
    j extirq_cases
#endif
    li a0,0
    j exit

    // Main reserves t3..t6 after interrupts become enabled.
    .balign 4
clint_handler:
    csrr t3,mcause
    li t4,0x8000000000000000
    or t4,t4,s8
    bne t3,t4,fail
    beqz s8,fail
    csrr t3,mstatus
    li t4,0x1888               // MPP=M, MPIE=1, MIE=0
    and t3,t3,t4
    li t4,0x1880
    bne t3,t4,fail
    li t4,3
    bne s8,t4,clint_timer_irq
    li t3,CLINT_MSIP
    sw zero,0(t3)
    li t4,8
    addi s6,s6,1
    j clint_irq_clear
clint_timer_irq:
    li t3,CLINT_CMP
    li t4,-1
    sd t4,0(t3)
    li t4,0x80
    addi s7,s7,1
clint_irq_clear:
    li t6,POLL_LIMIT
1:  csrr t3,mip
    and t3,t3,t4
    beqz t3,2f
    addi t6,t6,-1
    bnez t6,1b
    j fail
2:  li s8,0
    mret
#ifdef TEST_EXTIRQ
    .equ EXT_MEIP, (TOHOST + 0x18)
    .equ EXT_SEIP, (TOHOST + 0x20)
    .equ EXT_MASK, 0xa00
    .macro EXT_PENDING value
    li t0,POLL_LIMIT
.Lext_pending\@:
    csrr t1,mip
    li t2,EXT_MASK
    and t1,t1,t2
    li t2,\value
    beq t1,t2,.Lext_pending_done\@
    addi t0,t0,-1
    bnez t0,.Lext_pending\@
    j fail
.Lext_pending_done\@:
    .endm
    .macro EXT_VALUE address, value
    li t0,\address
    ld t1,0(t0)
    li t2,\value
    bne t1,t2,fail
    .endm
    .macro EXT_DELIVER counter, value
    li t0,POLL_LIMIT
    li t1,\value
.Lext_deliver\@:
    beq \counter,t1,.Lext_deliver_done\@
    addi t0,t0,-1
    bnez t0,.Lext_deliver\@
    j fail
.Lext_deliver_done\@:
    .endm
extirq_cases:
    li s0,28
    la t0,extirq_handler
    csrw mtvec,t0
    li s6,0                    // MEIP deliveries
    li s7,0                    // SEIP deliveries to M (mideleg.SEI=0)
    li s8,0                    // expected interrupt cause
    // Backing RAM contains executable, nonzero canaries at these addresses.
    // Device reset must be independent of that RAM, not initialized by it.
    EXT_VALUE EXT_MEIP,0
    EXT_VALUE EXT_SEIP,0
    EXT_PENDING 0

    li s0,29
    li t0,EXT_MEIP
    li t1,1
    sb t1,0(t0)
    EXT_PENDING 0x800
    EXT_VALUE EXT_MEIP,1
    EXT_VALUE EXT_SEIP,0
    li t0,0x800
    csrc mip,t0                // MEIP is the read-only external input
    EXT_PENDING 0x800

    li s0,30
    li s4,1
1:  li t0,EXT_MEIP
    add t0,t0,s4
    li t1,-1
    sb t1,0(t0)                // neither value on any upper lane changes bit0
    sb zero,0(t0)
    EXT_VALUE EXT_MEIP,1
    addi s4,s4,1
    li t0,8
    bltu s4,t0,1b
    EXT_PENDING 0x800

    li s0,31
    li t0,EXT_MEIP
    li t1,2
    sb t1,0(t0)                // bits other than bit0 are ignored
    EXT_VALUE EXT_MEIP,0
    EXT_PENDING 0

    li s0,32
    li t0,EXT_SEIP
    li t1,-1
    sh t1,0(t0)
    EXT_PENDING 0x200
    EXT_VALUE EXT_MEIP,0
    EXT_VALUE EXT_SEIP,1
    li s0,33
    li t0,EXT_SEIP
    sb zero,0(t0)
    EXT_PENDING 0

    li s0,34
    li t1,1
    li t0,EXT_MEIP
    sw t1,0(t0)
    li t0,EXT_SEIP
    sd t1,0(t0)
    EXT_PENDING EXT_MASK
    li s0,35
    li t0,EXT_MEIP
    sd zero,0(t0)
    EXT_PENDING 0x200
    EXT_VALUE EXT_SEIP,1
    li s0,36
    li t0,EXT_SEIP
    sw zero,0(t0)
    EXT_PENDING 0

    // The external SEIP latch and the CSR software-SEIP bit are independent.
    // Clearing either cannot clear the other; reads of mip see their OR.
    li s0,37
    li t0,0x200
    csrs mip,t0
    EXT_VALUE EXT_SEIP,0
    EXT_PENDING 0x200
    li s0,38
    li t0,EXT_SEIP
    li t1,1
    sw t1,0(t0)
    li t0,0x200
    csrc mip,t0
    EXT_VALUE EXT_SEIP,1
    EXT_PENDING 0x200
    li s0,39
    li t0,0x200
    csrs mip,t0
    li t0,EXT_SEIP
    sw zero,0(t0)
    EXT_VALUE EXT_SEIP,0
    EXT_PENDING 0x200
    li s0,40
    li t0,0x200
    csrc mip,t0
    EXT_PENDING 0

    li s0,41
    li s8,11
    li t0,0x800
    csrw mie,t0
    li t0,EXT_MEIP
    li t1,1
    sw t1,0(t0)
    EXT_PENDING 0x800
    bnez s6,fail                // locally enabled, globally disabled
    li s0,42
    csrsi mstatus,8
    EXT_DELIVER s6,1
    EXT_PENDING 0
    li s0,43
    li s8,11
    li t0,EXT_MEIP
    li t1,1
    sd t1,0(t0)
    EXT_DELIVER s6,2
    EXT_PENDING 0

    li s0,44
    csrci mstatus,8
    li s8,9
    li t0,0x200
    csrw mie,t0
    li t0,EXT_SEIP
    li t1,1
    sw t1,0(t0)
    EXT_PENDING 0x200
    bnez s7,fail
    li s0,45
    csrsi mstatus,8
    EXT_DELIVER s7,1
    EXT_PENDING 0
    li s0,46
    li s8,9
    li t0,EXT_SEIP
    li t1,1
    sb t1,0(t0)
    EXT_DELIVER s7,2
    EXT_PENDING 0

    li s0,47
    csrw mie,zero
    csrci mstatus,8
    // These are deliberately instruction-side reads of the backing RAM.
    // They occur only after writes and FENCE.I, so a stale I-cache line cannot
    // hide an erroneous data-side device write leaking into that RAM.
    fence.i
    li a4,0
    li t0,EXT_MEIP
    jalr ra,0(t0)
    li t0,42
    bne a4,t0,fail
    li a4,0
    li t0,EXT_SEIP
    jalr ra,0(t0)
    li t0,43
    bne a4,t0,fail
    li s0,48
    EXT_VALUE EXT_MEIP,0
    EXT_VALUE EXT_SEIP,0
    EXT_PENDING 0
    li t0,2
    bne s6,t0,fail
    bne s7,t0,fail
    li a0,0
    j exit

    .balign 4
extirq_handler:
    csrr t3,mcause
    li t4,0x8000000000000000
    or t4,t4,s8
    bne t3,t4,fail
    csrr t3,mstatus
    li t4,0x1888               // MPP=M, MPIE=1, MIE=0
    and t3,t3,t4
    li t4,0x1880
    bne t3,t4,fail
    li t4,11
    beq s8,t4,extirq_m_clear
    li t4,9
    bne s8,t4,fail
    li t3,EXT_SEIP
    li t4,0x200
    addi s7,s7,1
    j extirq_clear
extirq_m_clear:
    li t3,EXT_MEIP
    li t4,0x800
    addi s6,s6,1
extirq_clear:
    sb zero,0(t3)              // clear the actual external level, not mip
    li t6,POLL_LIMIT
1:  csrr t3,mip
    and t3,t3,t4
    beqz t3,2f
    addi t6,t6,-1
    bnez t6,1b
    j fail
2:  li s8,0
    mret
#endif
#else
_start:
    li s0,1                     // failing case, encoded in HTIF exit status
    li s2,0                     // nonzero only around an illegal-CSR probe
    li s6,0                     // S timer deliveries
    li s7,0                     // M deliveries of nondelegated STIP
    li s8,1                     // 1=direct timer; 0=legacy software STIP
    li s9,0                     // M timer delivery expected
    li s10,0                    // disabled-access matrix row
    la t0,m_handler
    csrw mtvec,t0
    la t0,s_handler
    csrw stvec,t0
    li t0,-1
    csrw pmpaddr0,t0
    li t0,0x1f
    csrw pmpcfg0,t0
    csrw mie,zero
    csrw medeleg,zero
    li t0,STIP
    csrw mideleg,t0
    csrw mcounteren,zero
    csrw scounteren,zero
    csrw 0x30a,zero
    li t0,0x6600
    csrs mstatus,t0

    // M may read/write all 64 compare bits with STCE=0 and TM=0.
    li t0,0xfedcba9876543210
    csrw STIMECMP,t0
    csrr t1,STIMECMP
    bne t0,t1,fail
    csrw STIMECMP,zero
    li t0,STIP
    csrc mip,t0
    WAIT_STIP mip,0              // disabled compare must not drive STIP
    li t0,STIP
    csrs mip,t0
    WAIT_STIP mip,STIP
    li t0,STIP
    csrc mip,t0
    WAIT_STIP mip,0
    li t0,-1
    csrw STIMECMP,t0
    ILLEGAL 0x15d02573           // stimecmph: RV32-only
    ILLEGAL 0x24d02573           // vstimecmp: absent without H
    ILLEGAL 0x25d02573           // vstimecmph: absent
    ILLEGAL 0x60602573           // henvcfg: absent without H
    la t0,s_gates
enter_s:
    csrw mepc,t0
    li t0,0x1800
    csrc mstatus,t0
    li t0,0x800
    csrs mstatus,t0
    mret

s_gates:
    // Three disallowed combinations: STCE/TM = 0/0, 0/1, 1/0.
    li a1,0x1357
    ILLEGAL 0x14d02573           // csrr a0,stimecmp
    ILLEGAL 0x14d59573           // csrrw a0,stimecmp,a1
    SERVICE 1
    j fail

s_enabled:
    // scounteren.TM=0 does not restrict S's stimecmp or time access.
    addi s0,s0,1
    csrr t0,scounteren
    andi t0,t0,TM
    bnez t0,fail
    li t0,0x123456789abcdef0
    csrw STIMECMP,t0
    csrr t1,STIMECMP
    bne t0,t1,fail
    rdtime t0
    csrw STIMECMP,zero
    WAIT_STIP sip,STIP
    li t0,STIP
    csrc sip,t0                  // STIP is read-only through sip
    WAIT_STIP sip,STIP
    li t0,-1
    csrw STIMECMP,t0
    WAIT_STIP sip,0
    addi s0,s0,1
    rdtime t0
    addi t0,t0,16
    csrw STIMECMP,t0
    WAIT_STIP sip,STIP           // timer progresses without more CSR writes
    li t0,-1
    csrw STIMECMP,t0
    WAIT_STIP sip,0
    // U cannot access stimecmp even when both counter-enable TM bits are set.
    li t0,TM
    csrw scounteren,t0
    la t0,u_probes
    csrw sepc,t0
    li t0,0x100
    csrc sstatus,t0
    sret
u_probes:
    li a1,0x1357
    ILLEGAL 0x14d02573
    ILLEGAL 0x14d59573
    ILLEGAL 0x15d02573
    SERVICE 2
    j fail

s_direct:
    addi s0,s0,1
    li t0,STIP
    csrw sie,t0
    csrsi sstatus,2
    csrw STIMECMP,zero
    WAIT_S 1
    WAIT_STIP sip,0
    addi s0,s0,1
    rdtime t0
    addi t0,t0,32
    csrw STIMECMP,t0
    WAIT_S 2
    WAIT_STIP sip,0
    // With STIP undelegated, the same S-triggered timer must trap to M.
    addi s0,s0,1
    SERVICE 3
    csrw STIMECMP,zero
    li t0,POLL_LIMIT
1:  bnez s7,2f
    addi t0,t0,-1
    bnez t0,1b
    j fail
2:  li t0,1
    bne s7,t0,fail
    li t0,2
    bne s6,t0,fail
    // STCE=0 restores the SBI-style M software-STIP injection path.
    SERVICE 4
    li s8,0
    li s6,0
    addi s0,s0,1
    WAIT_STIP sip,0              // compare=0 is inactive while STCE=0
    SERVICE 5                   // firmware sets mip.STIP
    WAIT_S 1
    WAIT_STIP sip,0              // S handler asks M firmware to clear it
    addi s0,s0,1
    SERVICE 5
    WAIT_S 2
    WAIT_STIP sip,0

    // Re-enable direct Sstc, then arm while a long vector instruction runs.
    SERVICE 7
    addi s0,s0,1
    li s8,1
    li s6,0
    li t0,32
    vsetvli t1,t0,e64,m8,tu,mu
    bne t0,t1,fail
    li t0,0x4010000000000000     // double 4.0, exactly representable
    fmv.d.x ft0,t0
    vfmv.v.f v8,ft0
    li t0,MARK
    li t1,1
    sd t1,0(t0)
    rdtime t0
    addi t0,t0,128
    csrw STIMECMP,t0
    .globl sstc_vector_start,sstc_vector_after
sstc_vector_start:
    vfsqrt.v v8,v8
sstc_vector_after:
    li t0,OUT
    vse64.v v8,(t0)
    WAIT_S 1
    WAIT_STIP sip,0
    csrr t0,vstart
    bnez t0,fail
    csrr t0,vl
    li t1,32
    bne t0,t1,fail
    li t0,OUT
    li t1,32
    li t2,0x4000000000000000     // double 2.0
1:  ld a0,0(t0)
    bne a0,t2,fail
    addi t0,t0,8
    addi t1,t1,-1
    bnez t1,1b
    li t0,MARK
    sd zero,0(t0)
    li a0,0
    j exit

    // t3..t6 are reserved for asynchronous handlers, never live in main.
    .balign 4
s_handler:
    csrr t3,scause
    li t4,0x8000000000000005
    bne t3,t4,fail
    csrr t3,sstatus
    andi t4,t3,2
    bnez t4,fail                 // SIE is stacked, not left enabled
    andi t4,t3,0x120             // SPP=S and SPIE=1
    li t5,0x120
    bne t4,t5,fail
    beqz s8,s_legacy_irq
    li t3,-1
    csrw STIMECMP,t3
    j s_irq_cleared
s_legacy_irq:
    li t3,STIP
    csrc sip,t3                  // cannot clear software STIP from S directly
    csrr t3,sip
    andi t3,t3,STIP
    beqz t3,fail
    SERVICE 6
s_irq_cleared:
    li t6,POLL_LIMIT
1:  csrr t3,sip
    andi t3,t3,STIP
    beqz t3,2f
    addi t6,t6,-1
    bnez t6,1b
    j fail
2:  addi s6,s6,1
    sret

    .balign 4
m_handler:
    csrr t3,mcause
    bltz t3,m_timer_irq
    li t4,2
    beq t3,t4,m_illegal
    li t4,8
    beq t3,t4,m_service
    li t4,9
    bne t3,t4,fail
m_service:
    li t3,6
    beq s5,t3,m_legacy_clear     // nested service must preserve t0..t2
    li t0,1
    beq s5,t0,m_next_gate
    li t0,2
    beq s5,t0,m_from_u
    li t0,3
    beq s5,t0,m_undelegate
    li t0,4
    beq s5,t0,m_legacy_mode
    li t0,5
    beq s5,t0,m_legacy_post
    li t0,7
    beq s5,t0,m_direct_mode
    j fail
m_next_gate:
    csrr t0,STIMECMP             // disallowed S write had no side effect
    li t1,-1
    bne t0,t1,fail
    addi s10,s10,1
    li t0,1
    beq s10,t0,1f
    li t0,STCE
    csrw 0x30a,t0
    csrw mcounteren,zero
    li t0,2
    beq s10,t0,2f
    li t0,TM
    csrw mcounteren,t0
    la t0,s_enabled
    j enter_s
1:  li t0,TM
    csrw mcounteren,t0
2:  la t0,s_gates
    j enter_s
m_from_u:
    csrr t0,STIMECMP
    li t1,-1
    bne t0,t1,fail
    csrw scounteren,zero
    la t0,s_direct
    j enter_s
m_undelegate:
    li t0,STIP
    csrc mideleg,t0
    li s9,1
    j m_service_return
m_legacy_mode:
    csrw 0x30a,zero
    li t0,STIP
    csrc mip,t0                  // explicit after STCE modulation
    csrs mideleg,t0
    csrw STIMECMP,zero
    j m_service_return
m_legacy_post:
    li t0,STIP
    csrs mip,t0
    j m_service_return
m_legacy_clear:
    li t3,STIP
    csrc mip,t3
    csrr t3,mepc
    addi t3,t3,4
    csrw mepc,t3
    mret
m_direct_mode:
    li t0,-1
    csrw STIMECMP,t0
    li t0,STIP
    csrc mip,t0
    li t0,STCE
    csrw 0x30a,t0
m_service_return:
    csrr t0,mepc
    addi t0,t0,4
    csrw mepc,t0
    mret
m_illegal:
    beqz s2,fail
    csrr t3,mtval
    bne t3,s2,fail
    csrr t3,mepc
    bne t3,s3,fail
    addi t3,t3,4
    csrw mepc,t3
    addi s1,s1,1
    mret
m_timer_irq:
    li t4,0x8000000000000005
    bne t3,t4,fail
    beqz s9,fail
    csrr t3,mstatus
    li t4,0x1800
    and t3,t3,t4
    li t4,0x800
    bne t3,t4,fail               // nondelegated event interrupted S
    li t3,-1
    csrw STIMECMP,t3
    li t6,POLL_LIMIT
1:  csrr t3,mip
    andi t3,t3,STIP
    beqz t3,2f
    addi t6,t6,-1
    bnez t6,1b
    j fail
2:  addi s7,s7,1
    li s9,0
    mret
#endif
fail:
    mv a0,s0
exit:
    slli a0,a0,1
    ori a0,a0,1
    li t0,TOHOST
    sd a0,0(t0)
1:  j 1b

    .section .htif,"aw",@progbits
    .globl tohost,fromhost
    .align 3
tohost: .dword 0
fromhost: .dword 0
#ifdef TEST_EXTIRQ
    .dword 0                   // +0x10: not an interrupt-control register
    // +0x18/+0x20: nonzero RAM canaries, invisible to data-side device reads.
    // Instruction fetch remains ordinary RAM and proves device writes did
    // not modify these instructions: addi a4,zero,{42,43}; ret.
    .word 0x02a00713, 0x00008067
    .word 0x02b00713, 0x00008067
#endif
