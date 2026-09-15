// RV64 H monitor shared by HTIF and Spike. The default variant keeps guest
// roots Bare; optional VM coverage checks Sv39/Sv39x4. Not an H/Sha claim.
// Build: riscv64-unknown-elf-gcc -march=rv64gcvh_zvl256b_zicntr_svinval_smstateen_svade
//   -mabi=lp64d -mcmodel=medany -nostdlib -static -T test/karu_h_test.ld
//   -o _build/karu_h_test.elf test/karu_h_test.S
// Oracle: spike --isa=rv64gcvh_zvl256b_zicntr_svinval_smstateen_svade <ELF>
// HTIF exit 0 = PASS; nonzero exit is the numbered CASE at the first failure.
// Cases: 1..6 entry/banking; 10..19 CSR priority/retirement; 20..29 SYSTEM;
// 40..49 counters/stateen; 60..65 dual FS/VS; 80 nested VU/VS/HS/M traps;
// 100..105 virtual IRQ routing; 120..123 MPRV+MPV and fault GVA.
// -DH_TEST_HFENCE=1 adds 64 HFENCE/HINVAL cases at 200..215,220..235,
// 240..255,260..275. Keep its ELF separate from the initial Bare-H monitor.
// -DH_TEST_HMEM=1 adds Bare HLV/HLVX/HSV cases; build a separate ELF and add
// _smnpm_ssnpm to -march / --isa. Cases 300..429: each load/store variant in
// M/HS/U/VS/VU with HU=0/1; 440..448: positive loads; 460..477: reserved
// encodings; 480..483: store byte-lane/neighbor preservation; 490..493:
// forced guest context ignores MPRV/host satp; 500..502: rd=x0 still faults;
// 600..649: PM selection, disabled-control canaries, MXR and HLVX suppression,
// full fault addresses.
// -DH_TEST_VM=1 adds 88 two-stage cases (141 including the default monitor).
// Build this separately as karu_hvm_test.elf with ISA suffix
// _smnpm_ssnpm_zimop_zicclsm. Guest VA 0x40020000 -> GPA 0xa0020000 ->
// HPA 0x80060000; guest PTE GPAs 0x9001[012]000 -> HPAs 0x8004[012]000.
// 800..811: four VS/G mode pairs x HLV/HSV/HLVX; 820..838: permission/Svade;
// 840..854: implicit-PTE/final GPA metadata in M/HS; 860..863: X/MXR/SUM;
// 870..872: wide GPA/canonicality; 900..907: VS/VU fetch+scalar all mode pairs;
// 910..931: scalar/fetch faults and split accesses; 940..945: vector FF trims,
// masked-first-element behavior and element-zero faults. G-stage faults
// check exact htval/mtval2 and 0x3000 for implicit RV64 VS-PTE reads.
// 950..957: directly delegated VS instruction-page faults from VS/VU,
// including a fault on the second halfword, invalid/X-denied leaves,
// Direct/Vectored synchronous entry, leaf repair and exact-PC retry.
// -DH_TEST_PBMT=1 requires H_TEST_VM=1 and adds 159 cases at 1800..1808,
// 1820..1823, 1830..1831 and 1900..2043. Add _svpbmt to the ISA and give Spike the same
// RAM map as HTIF: -m0x80000000:0x400000. Nine VS/G type combinations cover
// scalar widths, masked/unaligned vector traffic and instruction fetch;
// out-of-RAM physical errors check guest metadata and vector FF prefixes.
// +pbmt_guest_check additionally checks PTE-derived types/PA and external
// byte footprints with the maintained HTIF PBMT observer. It is not a
// complete guest device/ordering claim. Cases 1900+pair*16+form*4+gate cover
// all nine VS/G pairs, zero/clean/flush/inval (form 0..3), and allowed /
// machine / HS / VU-supervisor denial (gate 0..3). Management operations
// retain bytes; zero changes exactly one block; rejected operations do neither.
// -DH_TEST_TIMER=1 adds 134 cases (187 with the default monitor), using
// _smnpm_ssnpm_zimop_sstc. 1000..1009 bracket host/guest time offsets;
// 1010..1135 cover all six timer CSR forms, aliasing and denial priorities;
// 1140..1152 cover pending-source composition, independent comparators,
// unsigned time-offset wrap and STCE transitions; 1160..1169 cover time gates;
// 1200..1210 cover actual VS/VU/HS delivery, masking and vector offsets;
// 1300..1311 cover delegated VS illegal/access/breakpoint tval and direct /
// vectored synchronous traps. Guest roots remain Bare in this variant.
// H_TEST_TIMER_SPIKE_DIAGNOSTIC=1 excludes ONLY normative transition cases
// 1142/1143 to diagnose references retaining stale VSTIP after STCE clears.
// Its 185 cases are partial oracle coverage, not a full timer-suite pass.
// -DH_TEST_CONTEXT=1 adds 35 A/B/A/B/A context, delegated-page-fault and
// shared-control cases at 1400..1406,1410..1411,1420..1445 (88 with baseline).
// The shared controls have guest-visible counter/CBO/pointer-mask effects;
// all four state-enable banks are checked with machine/HS denial priority. Use
// the VM ISA suffix plus _sstc_zicbom_zicboz and VLEN=256. All FPRs/VRs and their controls
// are software saved/restored, along with VS banks and virtual timer state.
// -DH_TEST_CONTEXT_KECCAK=1 adds 1600..1602, a resident-state chained Keccak
// context KAT. This Karu-specific variant has no Spike oracle.
// -DH_TEST_PREEMPT=1 with H_TEST_CONTEXT adds eight cases at 1700..1707:
// real guest-timer preemption to HS, A/B/A/B/A switching, complete GPR and
// FP/vector save/restore, and exact resume. +hcontext_preemptcheck separately
// requires pending-during-operation, retirement and next-PC delivery on RTL;
// a timer deadline alone is not evidence of that microarchitectural overlap.
// Normative reference: RISC-V H 1.0, virtual instructions/traps/returns.
// https://docs.riscv.org/reference/isa/v20260120/priv/hypervisor.html

#ifndef H_TEST_HFENCE
#define H_TEST_HFENCE 0
#endif
#ifndef H_TEST_HMEM
#define H_TEST_HMEM 0
#endif
#ifndef H_TEST_VM
#define H_TEST_VM 0
#endif
#ifndef H_TEST_TIMER
#define H_TEST_TIMER 0
#endif
#ifndef H_TEST_PBMT
#define H_TEST_PBMT 0
#endif
#if H_TEST_PBMT && !H_TEST_VM
#error "H_TEST_PBMT requires H_TEST_VM"
#endif
#ifndef H_TEST_TIMER_SPIKE_DIAGNOSTIC
#define H_TEST_TIMER_SPIKE_DIAGNOSTIC 0
#endif
#ifndef H_TEST_CONTEXT
#define H_TEST_CONTEXT 0
#endif
#ifndef H_TEST_CONTEXT_KECCAK
#define H_TEST_CONTEXT_KECCAK 0
#endif
#ifndef H_TEST_PREEMPT
#define H_TEST_PREEMPT 0
#endif
#if H_TEST_PREEMPT && !H_TEST_CONTEXT
#error "H_TEST_PREEMPT requires H_TEST_CONTEXT"
#endif
// Timer increments are tunable stimulus, not overlap assertions. These
// defaults cover both maintained core configurations, including DDR stalls;
// every RTL run must still pass the passive pending/retire/IRQ observer.
#ifndef H_PREEMPT_FP_TICKS
#define H_PREEMPT_FP_TICKS 256
#endif
#ifndef H_PREEMPT_VEC_TICKS
#define H_PREEMPT_VEC_TICKS 64
#endif
#if H_PREEMPT_FP_TICKS < 1 || H_PREEMPT_FP_TICKS > 2047 || H_PREEMPT_VEC_TICKS < 1 || H_PREEMPT_VEC_TICKS > 2047
#error "Preemption timer increments must fit positive ADDI immediates"
#endif
#if H_TEST_CONTEXT_KECCAK && !H_TEST_CONTEXT
#error "H_TEST_CONTEXT_KECCAK requires H_TEST_CONTEXT"
#endif
    .globl h_test_cases
    .equ h_test_cases,53+64*H_TEST_HFENCE+218*H_TEST_HMEM+88*H_TEST_VM+159*H_TEST_PBMT+H_TEST_TIMER*(134-2*H_TEST_TIMER_SPIKE_DIAGNOSTIC)+35*H_TEST_CONTEXT+3*H_TEST_CONTEXT_KECCAK+8*H_TEST_PREEMPT

    .equ VSSTATUS,0x200
    .equ VSIE,0x204
    .equ VSTVEC,0x205
    .equ VSSCRATCH,0x240
    .equ VSEPC,0x241
    .equ VSCAUSE,0x242
    .equ VSTVAL,0x243
    .equ VSATP,0x280
    .equ HSTATUS,0x600
    .equ HEDELEG,0x602
    .equ HIDELEG,0x603
    .equ HIE,0x604
    .equ HCOUNTEREN,0x606
    .equ HENVCFG,0x60a
    .equ HSTATEEN0,0x60c
    .equ HVIP,0x645
    .equ HGATP,0x680
    .equ MPV,(1<<39)
    .equ MPRV,(1<<17)
    .equ CTX,((1<<13)|(1<<9))
    .equ IRQ,(1<<63)
    .equ TOHOST,0x80001000
    .equ HMEM_SRC,0x80020200
    .equ HMEM_DST,0x80020218
    .equ HMEM_DATA,0x88776655fedcba98
    .equ HMEM_OLD,0x0123456789abcdef
    .equ HMEM_GUARD,0x13579bdf2468ace0
    .equ HVM_VA,0x40020030
    .equ HVM_GPA,0xa0020030
    .equ HVM_HPA,0x80060030
    .equ HVM_VROOT,0x80040000
    .equ HVM_VL1,0x80041000
    .equ HVM_VL0,0x80042000
    .equ HVM_GROOT,0x80050000
    .equ HVM_GL1,0x80054000
    .equ HVM_GPT,0x80055000
    .equ HVM_GDATA,0x80056000
    .equ HVM_META,0x48564d
    .equ HVM_VSFETCH,0x485646
    .equ HVM_VALUE,0x1122334488776655
    .equ HTIMER_IRQ,0x485449
    .equ HTIMER_FETCH,0x485446
    .equ HTIMER_VSFAULT,0x485456
    .equ HCTX_A,0x80078000
    .equ HCTX_B,0x8007a000
    .equ HCTX_VB,0x80048000
    .equ HCTX_GB,0x80070000
    .equ HCTX_DB,0x8007c000
    .equ HCTX_SAVEVA,0x40030000
    .equ HCTX_USERVA,0x40021030
    .equ HCTX_SENV_A,((2<<32)|0xf0)
#if H_TEST_PREEMPT
    // Reuse free space in each existing two-page context record.
    .equ HCP_GPR,1536
    .equ HCP_PC,1792
    .equ HCP_STATUS,1800
    .equ HCP_COUNT,1808
    .equ HCP_INDEX,1816
    .equ HCP_MARK,0x800011c0
#endif

    // s0 case; s1 expected handler (M=3,HS=1,VS=2); s2 cause; s3 tval;
    // s4 fault PC; s5 M continuation; s6 origin U=0/HS=1/M=3/VU=4/VS=5;
    // s7 seen; s8 nested test; s9 expected GVA; s10 IRQ interval end.
    // s11 enables the exact denied-instruction minstret check.
    // Every ordinary case starts with disabled interrupts and fresh controls.
    .macro CASE id
    li s0,\id
    jal ra,reset_case
    .endm
    .macro EXPECT handler,cause,word=1
    li s1,\handler
    li s2,\cause
    li s3,\word
    .endm
    .macro ENTER mode,target,via_hs=0
    li s6,\mode
    la s5,.Ldone\@
    la a3,\target
    li a2,\mode
    .if \via_hs
    la t0,hs_enter
    li t1,(1<<11)
    .else
    mv t0,a3
    li t1,((\mode&3)<<11)|((\mode>>2)<<39)
    .endif
    csrw mepc,t0
    csrr t0,mstatus
    li t2,MPV|MPRV|(3<<11)
    not t2,t2
    and t0,t0,t2
    or t0,t0,t1
    csrw mstatus,t0
    mret
.Ldone\@:
    .endm
    .macro CHECK_CSR csr,value,mask=-1
    csrr t0,\csr
    li t1,\mask
    and t0,t0,t1
    li t1,\value
    bne t0,t1,fail
    .endm
#if H_TEST_VM || H_TEST_CONTEXT
    .macro H_VM_SET addr,target,flags
    li t0,\addr
    li t1,((\target)>>2)|\flags
    sd t1,0(t0)
    .endm
#endif
    // s3=1 means check the exact faulting instruction word. Other values
    // are explicit tval expectations (zero for ECALL, address for faults).
    .macro PROBE insn:vararg
    la s4,.Lprobe\@
    li t0,1
    bne s3,t0,.Lprepared\@
    lwu s3,0(s4)
.Lprepared\@:
    li a0,0x555
    beqz s11,.Lprobe\@
    csrr a4,instret
.Lprobe\@:
    \insn
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    j guest_done
    .endm

    .section .text.boot,"ax"
    .globl _start
    .option norvc
_start: j main
    .section .text,"ax"
main:
#if H_TEST_VM || H_TEST_TIMER || H_TEST_CONTEXT
    li tp,0
#endif
    li s0,1
    la t0,m_trap
    csrw mtvec,t0
    li t0,-1
    csrw pmpaddr0,t0
    li t0,0x1f
    csrw pmpcfg0,t0
    // Permit the implemented supervisor/hypervisor state hierarchy.
    li t0,-1
    csrw 0x30c,t0
    csrw 0x30d,t0
    csrw 0x30e,t0
    csrw 0x30f,t0

    CASE 1
    ENTER 5,bank_guest
    CHECK_CSR sscratch,0x1111
    CHECK_CSR VSSCRATCH,0x3333
    CASE 2
    ENTER 4,guest_done
    CASE 3
    ENTER 5,bank_guest,1
    CHECK_CSR sscratch,0x1111
    CHECK_CSR VSSCRATCH,0x3333
    CASE 4
    ENTER 4,guest_done,1
    CASE 5
    ENTER 5,vs_to_vu
    CASE 6
    // Host TSR must not prohibit a VS SRET.
    li t0,1<<22
    csrs mstatus,t0
    ENTER 5,vs_to_vu

    CASE 10
    EXPECT 1,22
    li t0,1<<22
    csrw medeleg,t0
    ENTER 5,probe_hstatus
    CASE 11
    EXPECT 3,22
    ENTER 5,probe_vsstatus
    CASE 12
    EXPECT 3,2
    ENTER 5,probe_mstatus
    CASE 13
    EXPECT 3,2
    ENTER 5,probe_absent
    CASE 14
    EXPECT 3,2
    csrw HCOUNTEREN,zero
    ENTER 5,probe_ro_counter
    CASE 15
    EXPECT 3,22
    ENTER 4,probe_sstatus
    CASE 16
    EXPECT 3,2
    ENTER 0,probe_sstatus
    CASE 17
    EXPECT 3,22
    li t0,1<<20
    csrw HSTATUS,t0
    ENTER 5,probe_satp
    CASE 18
    // VS banking updates only the guest EPC/cause/tval bank.
    ENTER 5,bank_trap_csrs
    CHECK_CSR sepc,0x81234000
    CHECK_CSR scause,13
    CHECK_CSR stval,0x4444
    CHECK_CSR VSEPC,0x81236000
    CHECK_CSR VSCAUSE,15
    CHECK_CSR VSTVAL,0x6666
    CASE 19
    EXPECT 3,22
    li s11,1
    ENTER 5,probe_vsscratch_write
    CHECK_CSR VSSCRATCH,0x2222

    CASE 20
    EXPECT 3,22
    ENTER 4,probe_wfi
    CASE 21
    EXPECT 3,2
    li t0,1<<21
    csrs mstatus,t0
    ENTER 4,probe_wfi
    CASE 22
    EXPECT 3,2
    ENTER 0,probe_wfi
    CASE 23
    EXPECT 3,22
    ENTER 4,probe_sret
    CASE 24
    EXPECT 3,22
    ENTER 4,probe_sfence
    CASE 25
    EXPECT 3,22
    li t0,1<<22
    csrw HSTATUS,t0
    ENTER 5,probe_sret
    CASE 26
    EXPECT 3,22
    li t0,1<<20
    csrw HSTATUS,t0
    ENTER 5,probe_sfence
    CASE 27
    li t0,1<<20
    csrs mstatus,t0
    ENTER 5,vs_host_tvm
    CASE 28
    li t0,1<<20
    csrw HSTATUS,t0
    ENTER 5,vs_order_fences
    CASE 29
    EXPECT 3,22
    ENTER 4,probe_order_fence

    CASE 40
    EXPECT 3,2
    csrw mcounteren,zero
    csrw HCOUNTEREN,zero
    ENTER 5,probe_cycle
    CASE 41
    EXPECT 3,22
    csrw HCOUNTEREN,zero
    ENTER 5,probe_cycle
    CASE 42
    csrw scounteren,zero
    ENTER 5,read_cycle
    CASE 43
    EXPECT 3,22
    csrw scounteren,zero
    ENTER 4,probe_cycle
    CASE 44
    ENTER 4,read_cycle
    CASE 45
    EXPECT 3,2
    csrw mcounteren,zero
    ENTER 4,probe_cycle
    CASE 46
    EXPECT 3,2
    li t0,1<<62
    csrc 0x30c,t0
    ENTER 5,probe_senvcfg
    CASE 47
    EXPECT 3,22
    li t0,1<<62
    csrc HSTATEEN0,t0
    ENTER 5,probe_senvcfg
    CASE 48
    EXPECT 3,22
    li t0,1<<63
    csrc HSTATEEN0,t0
    ENTER 5,probe_sstateen
    CASE 49
    EXPECT 3,2
    li t0,1<<63
    csrc 0x30c,t0
    ENTER 5,probe_sstateen

    CASE 60
    EXPECT 3,2
    li t0,3<<13
    csrc mstatus,t0
    ENTER 5,probe_fp
    CHECK_CSR mstatus,0,3<<13
    CHECK_CSR VSSTATUS,1<<13,3<<13
    CASE 61
    EXPECT 3,2
    li t0,1<<9
    csrw VSSTATUS,t0
    ENTER 5,probe_fp
    CHECK_CSR mstatus,1<<13,3<<13
    CHECK_CSR VSSTATUS,0,3<<13
    CASE 62
    ENTER 5,write_fp
    CHECK_CSR mstatus,3<<13,3<<13
    CHECK_CSR VSSTATUS,3<<13,3<<13
    CASE 63
    EXPECT 3,2
    li t0,3<<9
    csrc mstatus,t0
    ENTER 5,probe_vector
    CHECK_CSR mstatus,0,3<<9
    CHECK_CSR VSSTATUS,1<<9,3<<9
    CASE 64
    EXPECT 3,2
    li t0,1<<13
    csrw VSSTATUS,t0
    ENTER 5,probe_vector
    CHECK_CSR mstatus,1<<9,3<<9
    CHECK_CSR VSSTATUS,0,3<<9
    CASE 65
    ENTER 5,write_vector
    CHECK_CSR mstatus,3<<9,3<<9
    CHECK_CSR VSSTATUS,3<<9,3<<9

    CASE 80
    EXPECT 2,8,0
    li t0,(1<<8)|(1<<10)
    csrw medeleg,t0
    li t0,1<<8
    csrw HEDELEG,t0
    li s8,1
    ENTER 4,probe_ecall

    // Guest causes are 1/5/9, while HS sees physical virtual-IRQ IDs 2/6/10.
    .macro IRQ_CASE id,bit,handler,visible
    CASE \id
    EXPECT \handler,IRQ|\visible,0
    la s4,irq_wait
    la s10,irq_wait_end
    li t0,1<<\bit
    csrw HIE,t0
    .if \handler == 2
    csrw HIDELEG,t0
    li t1,CTX|2
    csrw VSSTATUS,t1
    .endif
    csrw HVIP,t0
    ENTER 5,irq_wait
    .endm
    IRQ_CASE 100,2,2,1
    IRQ_CASE 101,6,2,5
    IRQ_CASE 102,10,2,9
    IRQ_CASE 103,2,1,2
    IRQ_CASE 104,6,1,6
    IRQ_CASE 105,10,1,10

    CASE 120
    li t0,0x8000000000080010
    csrw satp,t0
    sfence.vma
    li t0,MPV|MPRV|(1<<11)
    csrs mstatus,t0
    li t1,0x80020100
    ld t2,0(t1)
    li t0,MPRV
    csrc mstatus,t0
    li t0,0x1111
    bne t2,t0,fail
    CASE 121
    li t0,0x8000000000080010
    csrw satp,t0
    sfence.vma
    li t0,MPRV|(1<<11)
    csrs mstatus,t0
    li t1,0x80020100
    ld t2,0(t1)
    li t0,MPRV
    csrc mstatus,t0
    li t0,0x2222
    bne t2,t0,fail
    CASE 122
    // Effective guest data privilege must not gate nominal M FP/vector use.
    csrw VSSTATUS,zero
    li t0,MPV|MPRV|(1<<11)
    csrs mstatus,t0
    fmv.w.x f0,zero
    vsetivli zero,1,e8,m1,tu,mu
    li t0,MPRV
    csrc mstatus,t0
    CHECK_CSR VSSTATUS,0,(3<<13)|(3<<9)
    CASE 123
    EXPECT 3,5,0
    li s6,3
    li s9,1
    la s4,mprv_fault
    li t0,MPV|MPRV|(1<<11)
    csrs mstatus,t0
mprv_fault:
    ld a0,0(zero)
    li t0,MPRV
    csrc mstatus,t0
    li t0,1
    bne s7,t0,fail

#if H_TEST_HFENCE
    // Every family uses nonzero VA/ASID operands. Entries are M, HS, host U,
    // then the full TVM x VTVM matrix in VS and VU, plus reserved-rd cases.
    // GVMA obeys host TVM; VVMA does not. Both controls leave M unaffected.
    // All guest H fences are virtual, even with host TVM=1; malformed words
    // remain illegal (not HS-qualified). The flush granularity is not tested.
    .macro H_FENCE_CASE id,word,mode,tvm,vtvm,cause
    CASE \id
    EXPECT 3,\cause
    li t0,(\tvm<<20)
    csrs mstatus,t0
    li t0,(\vtvm<<20)
    csrw HSTATUS,t0
    ENTER \mode,.Lhf_body\@
    li t0,0x12345000
    bne a1,t0,fail
    li t0,0x4321
    bne a2,t0,fail
    li t0,0x9999
    bne ra,t0,fail
    .if \cause == 0
    bnez s7,fail
    .endif
    j .Lhf_after\@
.Lhf_body\@:
    li a1,0x12345000
    li a2,0x4321
    li ra,0x9999
    .if \cause
    PROBE .word (\word|0x00c58000)
    .else
    .word (\word|0x00c58000)
    j guest_done
    .endif
.Lhf_after\@:
    .endm
    .macro H_FENCE_FAMILY base,word,gvma
    H_FENCE_CASE (\base+0),\word,3,0,0,0
    H_FENCE_CASE (\base+1),\word,3,1,1,0
    H_FENCE_CASE (\base+2),\word,1,0,1,0
    H_FENCE_CASE (\base+3),\word,1,1,1,(2*\gvma)
    H_FENCE_CASE (\base+4),\word,0,0,0,2
    H_FENCE_CASE (\base+5),\word,0,1,1,2
    H_FENCE_CASE (\base+6),\word,5,0,0,22
    H_FENCE_CASE (\base+7),\word,5,0,1,22
    H_FENCE_CASE (\base+8),\word,5,1,0,22
    H_FENCE_CASE (\base+9),\word,5,1,1,22
    H_FENCE_CASE (\base+10),\word,4,0,0,22
    H_FENCE_CASE (\base+11),\word,4,0,1,22
    H_FENCE_CASE (\base+12),\word,4,1,0,22
    H_FENCE_CASE (\base+13),\word,4,1,1,22
    H_FENCE_CASE (\base+14),(\word|0x80),3,0,0,2
    H_FENCE_CASE (\base+15),(\word|0x80),5,0,0,2
    .endm
    H_FENCE_FAMILY 200,0x22000073,0
    H_FENCE_FAMILY 220,0x62000073,1
    H_FENCE_FAMILY 240,0x26000073,0
    H_FENCE_FAMILY 260,0x66000073,1
#endif

#if H_TEST_HMEM
    // One shared runner exercises each static instruction in all ten
    // nominal-privilege/HU combinations. Fixed selector bits are not rs2:
    // a2 remains a canary for every load and is the data operand for stores.
    .macro H_MEM_FAMILY base,word,result,store=0,merged=HMEM_OLD
    li s0,\base
    la a3,.Lhm_insn\@
    li a4,\result
    li a6,\merged
    li a7,\store
    jal gp,hmem_matrix
    j .Lhm_after\@
.Lhm_insn\@:
    .if \store
    .word (\word|0x00c58000) // HSV a2,(a1), rd must remain zero.
    .else
    .word (\word|0x00058500) // HLV a0,(a1), selector is fixed by word.
    .endif
    j guest_done
.Lhm_after\@:
    .endm
    H_MEM_FAMILY 300,0x60004073,0xffffffffffffff98
    H_MEM_FAMILY 310,0x60104073,0x98
    H_MEM_FAMILY 320,0x64004073,0xffffffffffffba98
    H_MEM_FAMILY 330,0x64104073,0xba98
    H_MEM_FAMILY 340,0x68004073,0xfffffffffedcba98
    H_MEM_FAMILY 350,0x68104073,0xfedcba98
    H_MEM_FAMILY 360,0x6c004073,HMEM_DATA
    H_MEM_FAMILY 370,0x64304073,0xba98
    H_MEM_FAMILY 380,0x68304073,0xfedcba98
    H_MEM_FAMILY 390,0x62004073,0x555,1,0x0123456789abcd98
    H_MEM_FAMILY 400,0x66004073,0x555,1,0x0123456789abba98
    H_MEM_FAMILY 410,0x6a004073,0x555,1,0x01234567fedcba98
    H_MEM_FAMILY 420,0x6e004073,0x555,1,HMEM_DATA

    .macro H_MEM_POS id,word,result
    CASE \id
    jal ra,hmem_init
    li t0,HMEM_SRC
    li t1,0x1122334476543210
    sd t1,0(t0)
    li a1,HMEM_SRC
    li a2,HMEM_DATA
    li ra,0x9999
    .word (\word|0x00058500)
    li t0,\result
    bne a0,t0,fail
    li t0,HMEM_DATA
    bne a2,t0,fail
    li t0,0x9999
    bne ra,t0,fail
    .endm
    H_MEM_POS 440,0x60004073,0x10
    H_MEM_POS 441,0x60104073,0x10
    H_MEM_POS 442,0x64004073,0x3210
    H_MEM_POS 443,0x64104073,0x3210
    H_MEM_POS 444,0x68004073,0x76543210
    H_MEM_POS 445,0x68104073,0x76543210
    H_MEM_POS 446,0x6c004073,0x1122334476543210
    H_MEM_POS 447,0x64304073,0x3210
    H_MEM_POS 448,0x68304073,0x76543210

    .macro H_MEM_BAD id,word,mode
    CASE \id
    jal ra,hmem_init
    EXPECT 3,2
    ENTER \mode,.Lhmb_body\@
    li t0,HMEM_DST
    bne a1,t0,fail
    li t0,HMEM_DATA
    bne a2,t0,fail
    li t0,0x9999
    bne ra,t0,fail
    jal ra,hmem_check_unchanged
    j .Lhmb_after\@
.Lhmb_body\@:
    li a1,HMEM_DST
    li a2,HMEM_DATA
    li ra,0x9999
    PROBE .word \word
.Lhmb_after\@:
    .endm
    // Reserved load selectors, including nonexistent HLVX byte/doubleword,
    // and nonzero HSV rd. The malformed instruction is illegal in guests,
    // rather than a virtual instruction qualified for HS execution.
    H_MEM_BAD 460,0x6025c573,3
    H_MEM_BAD 461,0x6025c573,5
    H_MEM_BAD 462,0x6035c573,3
    H_MEM_BAD 463,0x6035c573,5
    H_MEM_BAD 464,0x6425c573,3
    H_MEM_BAD 465,0x6425c573,5
    H_MEM_BAD 466,0x6825c573,3
    H_MEM_BAD 467,0x6825c573,5
    H_MEM_BAD 468,0x6c15c573,3
    H_MEM_BAD 469,0x6c15c573,5
    H_MEM_BAD 470,0x6c35c573,3
    H_MEM_BAD 471,0x6c35c573,5
    H_MEM_BAD 472,0x62c5c0f3,3
    H_MEM_BAD 473,0x62c5c0f3,5
    H_MEM_BAD 474,0x66c5c0f3,3
    H_MEM_BAD 475,0x6ac5c0f3,3
    H_MEM_BAD 476,0x6ec5c0f3,3
    H_MEM_BAD 477,0x6ec5c0f3,5

    .macro H_MEM_LANE id,word,offset,merged
    CASE \id
    jal ra,hmem_init
    li a0,0x555
    li a1,HMEM_DST+\offset
    li a2,HMEM_DATA
    .word (\word|0x00c58000)
    li t0,HMEM_DST
    ld t1,0(t0)
    li t2,\merged
    bne t1,t2,fail
    ld t1,-8(t0)
    li t2,HMEM_GUARD
    bne t1,t2,fail
    ld t1,8(t0)
    bne t1,t2,fail
    li t0,0x555
    bne a0,t0,fail
    li t0,HMEM_DATA
    bne a2,t0,fail
    .endm
    H_MEM_LANE 480,0x62004073,7,0x9823456789abcdef
    H_MEM_LANE 481,0x66004073,6,0xba98456789abcdef
    H_MEM_LANE 482,0x6a004073,4,0xfedcba9889abcdef
    H_MEM_LANE 483,0x6e004073,0,HMEM_DATA

    .macro H_MEM_MPRV id,spvp,word,store=0
    CASE \id
    li t0,0x80020100
    li t1,0x1111
    sd t1,0(t0)
    li t0,0x80021100
    li t1,0x2222
    sd t1,0(t0)
    li t0,0x8000000000080010
    csrw satp,t0
    sfence.vma
    li t0,\spvp<<8
    csrw HSTATUS,t0
    li a0,0x555
    li a1,0x80020100
    li a2,0x3333
    // The host MPRV context would use nonidentity Sv39; HLV/HSV must instead
    // force the Bare guest context, for either value of hstatus.SPVP.
    li t0,MPRV|(1<<11)
    csrs mstatus,t0
    .if \store
    .word (\word|0x00c58000)
    .else
    .word (\word|0x00058500)
    .endif
    li t0,MPRV
    csrc mstatus,t0
    .if \store
    li t0,0x555
    bne a0,t0,fail
    ld t0,0(a1)
    bne t0,a2,fail
    .else
    li t0,0x1111
    bne a0,t0,fail
    .endif
    li t0,0x80021100
    ld t1,0(t0)
    li t0,0x2222
    bne t1,t0,fail
    .endm
    H_MEM_MPRV 490,0,0x6c004073
    H_MEM_MPRV 491,1,0x6c004073
    H_MEM_MPRV 492,0,0x6e004073,1
    H_MEM_MPRV 493,1,0x6e004073,1

    .macro H_MEM_ZERO id,word
    CASE \id
    EXPECT 3,5,0
    li s6,3
    li s9,1
    li a0,0x555
    li a1,0
    la s4,.Lhmz_insn\@
.Lhmz_insn\@:
    .word (\word|0x00058000)
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    bnez zero,fail
    .endm
    H_MEM_ZERO 500,0x6c004073
    H_MEM_ZERO 501,0x64304073
    H_MEM_ZERO 502,0x68304073

    // A PM case activates only the selected CSR. 'wrong' instead activates
    // the other two controls, leaving the selected control disabled. This
    // distinguishes SPVP and the U-only HUPMM path in Bare translation.
    .macro H_MEM_PM id,mode,spvp,pmm,raw,cause=0,store=0,hmxr=0,vmxr=0,hlvx=0,wrong=0,tval=-1
    CASE \id
    jal ra,hmem_init
    .set hpm_h,0
    .set hpm_s,0
    .set hpm_u,0
    .if \spvp
    .set hpm_h,\pmm
    .elseif \mode == 0
    .set hpm_u,\pmm
    .else
    .set hpm_s,\pmm
    .endif
    .if \wrong
    .set hpm_h,\pmm-hpm_h
    .set hpm_s,\pmm-hpm_s
    .set hpm_u,\pmm-hpm_u
    .endif
    li t0,hpm_h<<32
    csrw HENVCFG,t0
    li t0,hpm_s<<32
    csrw senvcfg,t0
    li t0,(hpm_u<<48)|(\spvp<<8)|(1<<9)
    csrw HSTATUS,t0
    li t0,\hmxr<<19
    csrs mstatus,t0
    li t0,\vmxr<<19
    csrs VSSTATUS,t0
    EXPECT 3,\cause,\raw
    .if \tval != -1
    li s3,\tval
    .endif
    .if \cause
    li s9,1
    .endif
    ENTER \mode,.Lhpm_body\@
    li t0,\raw
    bne a1,t0,fail
    li t0,HMEM_DATA
    bne a2,t0,fail
    li t0,0x9999
    bne ra,t0,fail
    .if \cause
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    jal ra,hmem_check_unchanged
    .elseif \store
    li t0,HMEM_DST
    ld t1,0(t0)
    li t0,HMEM_DATA
    bne t1,t0,fail
    li t0,0x555
    bne a0,t0,fail
    jal ra,hmem_check_guards
    .else
    li t0,HMEM_DATA
    bne a0,t0,fail
    jal ra,hmem_check_unchanged
    .endif
    j .Lhpm_after\@
.Lhpm_body\@:
    li a0,0x555
    li a1,\raw
    li a2,HMEM_DATA
    li ra,0x9999
    la s4,.Lhpm_insn\@
.Lhpm_insn\@:
    .if \hlvx
    hlvx.wu a0,(a1)
    .elseif \store
    hsv.d a2,(a1)
    .else
    hlv.d a0,(a1)
    .endif
    j guest_done
.Lhpm_after\@:
    .endm
    .set hpm_id,600
    .irp mode,3,1,0
    .irp spvp,0,1
    .irp pmm,2,3
    .if \pmm == 2
    .set hpm_tag,0xa800000000000000
    .else
    .set hpm_tag,0xabcd000000000000
    .endif
    H_MEM_PM hpm_id,\mode,\spvp,\pmm,(hpm_tag|HMEM_SRC)
    H_MEM_PM (hpm_id+1),\mode,\spvp,\pmm,(hpm_tag|HMEM_DST),0,1
    .set hpm_id,hpm_id+2
    .endr
    .endr
    .endr
    // Selected control disabled while the unrelated controls mask 16 bits.
    .irp mode,3,1,0
    .irp spvp,0,1
    H_MEM_PM hpm_id,\mode,\spvp,3,(0xabcd000000000000|HMEM_SRC),5,0,0,0,0,1
    .set hpm_id,hpm_id+1
    .endr
    .endr
    // Either HS MXR or VS MXR suppresses PM, including HSV in Bare mode.
    .irp mode,3,1,0
    .irp spvp,0,1
    H_MEM_PM hpm_id,\mode,\spvp,3,(0xabcd000000000000|HMEM_SRC),5,0,1
    H_MEM_PM (hpm_id+1),\mode,\spvp,3,(0xabcd000000000000|HMEM_DST),7,1,0,1
    .set hpm_id,hpm_id+2
    .endr
    .endr
    // HLVX is exempt from PM even when the selected PMM is enabled.
    .irp mode,3,1,0
    .irp spvp,0,1
    H_MEM_PM hpm_id,\mode,\spvp,3,(0xabcd000000000000|HMEM_SRC),5,0,0,0,1
    .set hpm_id,hpm_id+1
    .endr
    .endr
    // Bare PM zero-extends, rather than sign-extending bit 47 or 56. The
    // remaining high physical address must fault without 32-bit truncation.
    H_MEM_PM hpm_id,3,1,3,0xabcd800080020200,5,0,0,0,0,0,0x0000800080020200
    H_MEM_PM (hpm_id+1),3,0,2,0xa900000080020218,7,1,0,0,0,0,0x0100000080020218
    .set hpm_id,hpm_id+2
#endif

#if H_TEST_VM
    // The VS and G stages never share page-table addresses. Init returns the
    // data address in a1 and code base in a3 for the selected mode pair.
    .macro H_VM_INIT id,vs=1,g=1
    CASE \id
    li a0,\vs
    li a1,\g
    jal ra,hvm_init
    .endm
    .macro H_VM_FLUSH
    hfence.vvma
    hfence.gvma
    .endm
    .macro H_VM_PTE addr,flags
    li t0,\addr
    ld t1,0(t0)
    li t2,-1024
    and t1,t1,t2
    ori t1,t1,\flags
    sd t1,0(t0)
    .endm
    .macro H_VM_ACCESS id,vs,g,kind
    H_VM_INIT \id,\vs,\g
    li a0,0x555
    li a2,HMEM_DATA
    .if \kind == 0
    hlv.d a0,(a1)
    li t0,HVM_VALUE
    bne a0,t0,fail
    .elseif \kind == 1
    hsv.d a2,(a1)
    li t0,HVM_HPA
    ld t0,0(t0)
    bne t0,a2,fail
    li t0,0x555
    bne a0,t0,fail
    .else
    hlvx.wu a0,(a1)
    li t0,0x88776655
    bne a0,t0,fail
    .endif
    .endm
    H_VM_ACCESS 800,0,0,0
    H_VM_ACCESS 801,0,1,0
    H_VM_ACCESS 802,1,0,0
    H_VM_ACCESS 803,1,1,0
    H_VM_ACCESS 804,0,0,1
    H_VM_ACCESS 805,0,1,1
    H_VM_ACCESS 806,1,0,1
    H_VM_ACCESS 807,1,1,1
    H_VM_ACCESS 808,0,0,2
    H_VM_ACCESS 809,0,1,2
    H_VM_ACCESS 810,1,0,2
    H_VM_ACCESS 811,1,1,2

    // Each fault checks original VA, the precise explicit/implicit GPA,
    // tinst, nominal privilege/V and GVA before another trap can overwrite
    // them. PTE canaries also prove that Svade did not silently set A/D.
    .macro H_VM_FAULT id,pte,flags,cause,gpa,tinst=0,store=0,mode=3,hlvx=0,warm=0,vmxr=0
    H_VM_INIT \id
    H_VM_PTE \pte,\flags
    li t0,\vmxr<<19
    csrs VSSTATUS,t0
    H_VM_FLUSH
    .if \warm
    hlv.d a0,(a1)
    .endif
    li s10,\pte
    ld s8,0(s10)
    li tp,HVM_META
    li gp,(\gpa)>>2
    li a6,\tinst
    li a7,0
    .if \mode == 1
    EXPECT 1,\cause,HVM_VA
    .else
    EXPECT 3,\cause,HVM_VA
    .endif
    li s9,1
    .if \mode == 1
    li t0,1<<\cause
    csrw medeleg,t0
    .endif
    .if \warm
    // Keep the read-then-write probe in M: no xRET, CSR control change or
    // invalidation may discard the read's translation before the D=0 store.
    .if \mode != 3
    .error "warm VM probe requires nominal M"
    .endif
    li s6,3
    la s5,.Lhvmf_return\@
    j .Lhvmf_body\@
.Lhvmf_return\@:
    .else
    ENTER \mode,.Lhvmf_body\@
    .endif
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    ld t0,0(s10)
    bne t0,s8,fail
    li t0,HVM_HPA
    ld t1,0(t0)
    li t0,HVM_VALUE
    bne t1,t0,fail
    j .Lhvmf_after\@
.Lhvmf_body\@:
    li a0,0x555
    li a1,HVM_VA
    li a2,HMEM_DATA
    la s4,.Lhvmf_insn\@
.Lhvmf_insn\@:
    .if \store
    hsv.d a2,(a1)
    .elseif \hlvx
    hlvx.wu a0,(a1)
    .else
    hlv.d a0,(a1)
    .endif
    j guest_done
.Lhvmf_after\@:
    .endm
    // VS leaf: invalid, permission, A=0 and D=0 (including read-then-store).
    H_VM_FAULT 820,(HVM_VL0+32*8),0,13,0
    H_VM_FAULT 821,(HVM_VL0+32*8),0xc9,13,0
    H_VM_FAULT 822,(HVM_VL0+32*8),0x8f,13,0
    H_VM_FAULT 823,(HVM_VL0+32*8),0x4f,15,0,0,1
    H_VM_FAULT 824,(HVM_VL0+32*8),0xc3,15,0,0,1
    H_VM_FAULT 825,(HVM_VL0+32*8),0xc3,13,0,0,0,3,1
    H_VM_FAULT 826,(HVM_VL0+32*8),0x4f,15,0,0,1,3,0,1
    H_VM_FAULT 827,(HVM_VL0+32*8),0xdf,13,0
    // G leaf: invalid, no U, permission, A=0 and D=0.
    H_VM_FAULT 830,(HVM_GDATA+32*8),0,21,HVM_GPA
    H_VM_FAULT 831,(HVM_GDATA+32*8),0xcf,21,HVM_GPA
    H_VM_FAULT 832,(HVM_GDATA+32*8),0xd9,21,HVM_GPA
    H_VM_FAULT 833,(HVM_GDATA+32*8),0x9f,21,HVM_GPA
    H_VM_FAULT 834,(HVM_GDATA+32*8),0x5f,23,HVM_GPA,0,1
    H_VM_FAULT 835,(HVM_GDATA+32*8),0xd3,23,HVM_GPA,0,1
    H_VM_FAULT 836,(HVM_GDATA+32*8),0xd3,21,HVM_GPA,0,0,3,1
    H_VM_FAULT 837,(HVM_GDATA+32*8),0x5f,23,HVM_GPA,0,1,3,0,1
    H_VM_FAULT 838,(HVM_GDATA+32*8),0xd9,21,HVM_GPA,0,0,3,0,0,1
    // Every VS table level undergoes G translation. Preserve the original
    // load/store fault class even though the failing PTE operation is a read.
    H_VM_FAULT 840,(HVM_GPT+16*8),0,21,0x90010008,0x3000
    H_VM_FAULT 841,(HVM_GPT+17*8),0,21,0x90011000,0x3000
    H_VM_FAULT 842,(HVM_GPT+18*8),0,21,0x90012100,0x3000
    H_VM_FAULT 843,(HVM_GPT+16*8),0,23,0x90010008,0x3000,1
    H_VM_FAULT 844,(HVM_GPT+17*8),0,23,0x90011000,0x3000,1
    H_VM_FAULT 845,(HVM_GPT+18*8),0,23,0x90012100,0x3000,1
    H_VM_FAULT 846,(HVM_GPT+16*8),0,21,0x90010008,0x3000,0,1
    H_VM_FAULT 847,(HVM_GPT+17*8),0,21,0x90011000,0x3000,0,1
    H_VM_FAULT 848,(HVM_GPT+18*8),0,21,0x90012100,0x3000,0,1
    H_VM_FAULT 849,(HVM_GPT+16*8),0,23,0x90010008,0x3000,1,1
    H_VM_FAULT 850,(HVM_GPT+17*8),0,23,0x90011000,0x3000,1,1
    H_VM_FAULT 851,(HVM_GPT+18*8),0,23,0x90012100,0x3000,1,1
    H_VM_FAULT 852,(HVM_GPT+18*8),0x9f,21,0x90012100,0x3000
    H_VM_FAULT 853,(HVM_GDATA+32*8),0,21,HVM_GPA,0,0,1
    H_VM_FAULT 854,(HVM_GDATA+32*8),0,23,HVM_GPA,0,1,1

    // Execute-only at BOTH page stages is legal for HLVX, but not HLV.
    H_VM_INIT 860
    H_VM_PTE (HVM_VL0+32*8),0xc9
    H_VM_PTE (HVM_GDATA+32*8),0xd9
    H_VM_FLUSH
    hlvx.wu a0,(a1)
    li t0,0x88776655
    bne a0,t0,fail
    // HS MXR affects both stages; VS MXR only relaxes the VS stage.
    H_VM_INIT 861
    H_VM_PTE (HVM_VL0+32*8),0xc9
    H_VM_PTE (HVM_GDATA+32*8),0xd9
    li t0,1<<19
    csrs mstatus,t0
    H_VM_FLUSH
    hlv.d a0,(a1)
    li t0,HVM_VALUE
    bne a0,t0,fail
    H_VM_INIT 863
    H_VM_PTE (HVM_VL0+32*8),0xdf
    li t0,1<<18
    csrs VSSTATUS,t0
    H_VM_FLUSH
    hlv.d a0,(a1)
    li t0,HVM_VALUE
    bne a0,t0,fail
    H_VM_INIT 862
    H_VM_PTE (HVM_VL0+32*8),0xc9
    li t0,1<<19
    csrs VSSTATUS,t0
    H_VM_FLUSH
    hlv.d a0,(a1)
    li t0,HVM_VALUE
    bne a0,t0,fail

    // Sv39x4 top-level index includes GPA bits 40:39, not just Sv39's VPN2.
    H_VM_INIT 870,0,1
    li a1,(1<<40)|HVM_GPA
    hlv.d a0,(a1)
    li t0,HVM_VALUE
    bne a0,t0,fail

    .macro H_VM_ADDRFAULT id,vs,addr,cause,gpa
    H_VM_INIT \id,\vs,1
    li tp,HVM_META
    li gp,(\gpa)>>2
    li a6,0
    li a7,0
    EXPECT 3,\cause,\addr
    li s6,3
    li s9,1
    li a0,0x555
    li a1,\addr
    la s4,.Lhvma_insn\@
.Lhvma_insn\@:
    hlv.d a0,(a1)
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    .endm
    H_VM_ADDRFAULT 871,0,((1<<41)|HVM_GPA),21,((1<<41)|HVM_GPA)
    H_VM_ADDRFAULT 872,1,((1<<39)|HVM_VA),13,0

    // Execute the same physical guest code through each VS/G combination,
    // in both VS and VU. Data load and store use the selected guest address.
    .macro H_VM_GUEST id,vs,g,mode=5
    H_VM_INIT \id,\vs,\g
    .if \mode == 4
    H_VM_PTE (HVM_VL0+32*8),0xdf
    H_VM_PTE (HVM_VL0+100*8),0xdf
    H_VM_FLUSH
    .endif
    li a2,HMEM_DATA
    li a4,\mode
    jal ra,hvm_guest_enter
    li t0,HVM_VALUE
    bne a0,t0,fail
    li t0,HVM_HPA
    ld t0,0(t0)
    li t1,HMEM_DATA
    bne t0,t1,fail
    bnez s7,fail
    .endm
    H_VM_GUEST 900,0,0
    H_VM_GUEST 901,0,1
    H_VM_GUEST 902,1,0
    H_VM_GUEST 903,1,1
    H_VM_GUEST 904,0,0,4
    H_VM_GUEST 905,0,1,4
    H_VM_GUEST 906,1,0,4
    H_VM_GUEST 907,1,1,4

    .macro H_VM_GFAULT id,pte,cause,tval,gpa,code,insnoff=0,tinst=0,escape=0,addr=HVM_VA
    H_VM_INIT \id
    H_VM_PTE \pte,0
    H_VM_FLUSH
    li tp,HVM_META
    li gp,(\gpa)>>2
    li a6,\tinst
    li a7,\escape
    EXPECT 3,\cause,\tval
    li s9,1
    la t0,\code
    la t1,hvm_guest_scalar
    sub t0,t0,t1
    add a3,a3,t0
    addi s4,a3,\insnoff
    li a0,0x555
    li a1,\addr
    li a2,HMEM_DATA
    li a4,5
    jal ra,hvm_guest_enter
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    .endm
    H_VM_GFAULT 910,(HVM_VL0+32*8),13,HVM_VA,0,hvm_guest_load
    H_VM_GFAULT 911,(HVM_GDATA+32*8),21,HVM_VA,HVM_GPA,hvm_guest_load
    H_VM_GFAULT 912,(HVM_VL0+32*8),15,HVM_VA,0,hvm_guest_store
    H_VM_GFAULT 913,(HVM_GDATA+32*8),23,HVM_VA,HVM_GPA,hvm_guest_store
    // The second part of a split scalar load reports the second-page byte.
    H_VM_GFAULT 914,(HVM_VL0+33*8),13,0x40021000,0,hvm_guest_load,0,0,0,0x40020ffc
    H_VM_GFAULT 915,(HVM_GDATA+33*8),21,0x40021000,0xa0021000,hvm_guest_load,0,0,0,0x40020ffc
    // Fetch failures exit directly to M, without retrying an unmapped page.
    H_VM_GFAULT 920,(HVM_VL0+100*8),12,0x40064000,0,hvm_guest_scalar,0,0,1
    H_VM_GFAULT 921,(HVM_GDATA+100*8),20,0x40064000,0xa0064000,hvm_guest_scalar,0,0,1
    H_VM_GFAULT 922,(HVM_GPT+16*8),20,0x40064000,0x90010008,hvm_guest_scalar,0,0x3000,1
    H_VM_GFAULT 923,(HVM_GPT+18*8),20,0x40064000,0x90012320,hvm_guest_scalar,0,0x3000,1
    H_VM_GFAULT 924,(HVM_VL0+101*8),12,0x40065000,0,hvm_guest_xpage,0,0,1
    H_VM_GFAULT 925,(HVM_GDATA+101*8),20,0x40065000,0xa0065000,hvm_guest_xpage,0,0,1
    H_VM_INIT 926
    li t0,4094
    add a3,a3,t0
    li a4,5
    jal ra,hvm_guest_enter
    li t0,7
    bne a0,t0,fail
    bnez s7,fail
    H_VM_GFAULT 930,(HVM_VL0+33*8),15,0x40021000,0,hvm_guest_store,0,0,0,0x40020ffc
    H_VM_GFAULT 931,(HVM_GDATA+33*8),23,0x40021000,0xa0021000,hvm_guest_store,0,0,0,0x40020ffc

    .macro H_VM_FF id,pte,masked=0
    H_VM_INIT \id
    H_VM_PTE \pte,0
    H_VM_FLUSH
    .if \masked
    la t0,hvm_guest_ffmask
    li a1,0x40020ff8
    .else
    la t0,hvm_guest_ff
    li a1,0x40020ff0
    .endif
    la t1,hvm_guest_scalar
    sub t0,t0,t1
    add a3,a3,t0
    li a4,5
    jal ra,hvm_guest_enter
    bnez s7,fail
    bnez a4,fail
    .if \masked
    li t0,1
    bne a0,t0,fail
    li t0,-1
    .else
    li t0,2
    bne a0,t0,fail
    li t0,HMEM_OLD
    .endif
    bne a2,t0,fail
    .endm
    H_VM_FF 940,(HVM_VL0+33*8)
    H_VM_FF 941,(HVM_GDATA+33*8)
    H_VM_FF 942,(HVM_VL0+33*8),1
    H_VM_FF 943,(HVM_GDATA+33*8),1
    .macro H_VM_FF_FIRST id,pte,cause,gpa
    H_VM_INIT \id
    H_VM_PTE \pte,0
    H_VM_FLUSH
    li tp,HVM_META
    li gp,(\gpa)>>2
    li a6,0
    li a7,0
    EXPECT 3,\cause,0x40021000
    li s9,1
    la t0,hvm_guest_ff
    la t1,hvm_guest_scalar
    sub t0,t0,t1
    add a3,a3,t0
    addi s4,a3,8
    li a1,0x40021000
    li a4,5
    jal ra,hvm_guest_enter
    li t0,1
    bne s7,t0,fail
    li t0,4
    bne a0,t0,fail
    li t0,-1
    bne a2,t0,fail
    bnez a4,fail
    .endm
    H_VM_FF_FIRST 944,(HVM_VL0+33*8),13,0
    H_VM_FF_FIRST 945,(HVM_GDATA+33*8),21,0xa0021000

    // The faulting guest code retains its distinct VA/GPA/HPA mapping.
    // A separate supervisor-only identity alias maps the maintained VS
    // handler and its software PTE-repair access; no HS trap is involved.
    .macro H_VM_VSFETCH id,mode,split=0,xdeny=0
    H_VM_INIT \id
    H_VM_SET (HVM_VROOT+2*8),0x80000000,0xcf
    H_VM_SET (HVM_GL1+0*8),0x80000000,0xdf
    .if \mode == 4
    H_VM_PTE (HVM_VL0+100*8),0xdf
    H_VM_PTE (HVM_VL0+101*8),0xdf
    .endif
    li s10,HVM_VL0+(100+\split)*8
    ld a7,0(s10)
    .if \xdeny
    andi t0,a7,-9           // valid, accessed leaf without execute permission
    .else
    andi t0,a7,-2           // invalid leaf, preserving all other PTE bits
    .endif
    sd t0,0(s10)
    H_VM_FLUSH
    li tp,HVM_VSFETCH
    EXPECT 2,12,0
    li t0,1<<12
    csrw medeleg,t0
    csrw HEDELEG,t0
    // No guest external interrupt source is selected. Zero is legal for
    // HGEIE/VGEIN even when GEILEN=0; no nonzero WARL readback is assumed.
    csrw 0x607,zero
    CHECK_CSR 0xe12,0
    csrr gp,HSTATUS
    li t0,0x3f<<12
    and t0,gp,t0
    bnez t0,fail
    la t0,vs_trap
    ori t0,t0,\xdeny        // both Direct and Vectored synchronous entry
    csrw VSTVEC,t0
    .if \split
    li a3,0x40064ffe
    li s3,0x40065000        // failed second portion, not the instruction start
    .else
    la t0,hvm_guest_fetch_probe
    la t1,hvm_guest_scalar
    sub t0,t0,t1
    add a3,a3,t0
    mv s3,a3
    .endif
    mv s4,a3
    li a0,0x555             // neither instruction portion may retire on fault
    li a2,0x777
    li a6,0
    li a4,\mode
    jal ra,hvm_guest_enter
    li t0,1
    bne s7,t0,fail
    bne a6,t0,fail          // exactly one delegated trap, then successful retry
    li t0,7
    bne a0,t0,fail
    li t0,0x778
    bne a2,t0,fail          // the post-instruction continuation ran exactly once
    ld t0,0(s10)
    bne t0,a7,fail          // handler repaired only the selected VS leaf
    csrr t0,VSEPC
    bne t0,s4,fail          // SRET retried the exact original instruction PC
    csrr t0,VSTVAL
    bne t0,s3,fail
    CHECK_CSR VSCAUSE,12
    csrr t0,HSTATUS
    bne t0,gp,fail          // direct VS delivery must not change H trap state
    CHECK_CSR sepc,0x81234000
    CHECK_CSR scause,13
    CHECK_CSR stval,0x4444
    CHECK_CSR sscratch,0x1111
    CHECK_CSR 0x643,0x12345
    CHECK_CSR 0x64a,0x54321
    la t1,hs_trap
    csrr t0,stvec
    bne t0,t1,fail
    la t1,vs_trap
    ori t1,t1,\xdeny
    csrr t0,VSTVEC
    bne t0,t1,fail
    .endm
    H_VM_VSFETCH 950,5,0,0
    H_VM_VSFETCH 951,4,0,0
    H_VM_VSFETCH 952,5,1,0
    H_VM_VSFETCH 953,4,1,0
    H_VM_VSFETCH 954,5,0,1
    H_VM_VSFETCH 955,4,0,1
    H_VM_VSFETCH 956,5,1,1
    H_VM_VSFETCH 957,4,1,1
#if H_TEST_PBMT
    // PBMT is applied G first, then a nonzero VS value overrides it. These
    // cases deliberately include NC-over-IO, not just a numeric maximum.
    .macro H_PB_PTE pte,type
    li t0,\pte
    ld t1,0(t0)
    li t2,~(3<<61)
    and t1,t1,t2
    li t2,\type<<61
    or t1,t1,t2
    sd t1,0(t0)
    .endm
    .macro H_PB_SETUP id,vs,g,mode=5
    H_VM_INIT \id
    li t0,(1<<62)|0xf0
    csrw menvcfg,t0
    csrw HENVCFG,t0
    csrw senvcfg,t0
    .if \mode == 4
    H_VM_PTE (HVM_VL0+32*8),0xdf
    H_VM_PTE (HVM_VL0+33*8),0xdf
    H_VM_PTE (HVM_VL0+100*8),0xdf
    .endif
    H_PB_PTE (HVM_VL0+32*8),\vs
    H_PB_PTE (HVM_VL0+33*8),\vs
    H_PB_PTE (HVM_GDATA+32*8),\g
    H_PB_PTE (HVM_GDATA+33*8),\g
    H_PB_PTE (HVM_VL0+100*8),\vs
    H_PB_PTE (HVM_GDATA+100*8),\g
    H_VM_FLUSH
    .endm
    .macro H_PB_ENTER target,mode=5
    la t0,\target
    la t1,hvm_guest_scalar
    sub t0,t0,t1
    li a3,0x40064000
    add a3,a3,t0
    li a4,\mode
    jal ra,hvm_guest_enter
    .endm
    .macro H_PB_PAIR id,vs,g,mode=5
    H_PB_SETUP \id,\vs,\g,\mode
    jal ra,hpb_prepare
    jal ra,hpb_sync
    li a1,0x40020000
    H_PB_ENTER hpb_guest_traffic,\mode
    bnez s7,fail
    jal ra,hpb_sync
    jal ra,hpb_verify
    .endm
    H_PB_PAIR 1800,0,0
    H_PB_PAIR 1801,0,1,4
    H_PB_PAIR 1802,0,2
    H_PB_PAIR 1803,1,0,4
    H_PB_PAIR 1804,1,1
    H_PB_PAIR 1805,1,2,4
    H_PB_PAIR 1806,2,0
    H_PB_PAIR 1807,2,1,4
    H_PB_PAIR 1808,2,2

    // The physical page is valid by PMA but outside the 4 MiB test RAM.
    // The resulting bus access fault is not a guest-page fault: tval is
    // the original guest VA, GVA=1, GPA/tinst metadata is zero.
    .macro H_PB_BUSFAULT id,type,store=0,vector=0
    H_PB_SETUP \id,\type,0
    H_VM_SET (HVM_GDATA+32*8),0x88000000,0xdf
    H_VM_FLUSH
    li tp,HVM_META
    li gp,0
    li a6,0
    li a7,0
    EXPECT 3,(5+2*\store),HVM_VA
    li s9,1
    li a0,0x555
    li a1,HVM_VA
    li a2,HMEM_DATA
    .if \vector
    vsetivli zero,4,e16,m1,tu,mu
    vmv.v.i v8,-1
    la t0,hpb_guest_vfault
    .elseif \store
    la t0,hvm_guest_store
    .else
    la t0,hvm_guest_load
    .endif
    la t1,hvm_guest_scalar
    sub t0,t0,t1
    li s4,0x40064000
    add s4,s4,t0
    .if \vector
    H_PB_ENTER hpb_guest_vfault
    .elseif \store
    H_PB_ENTER hvm_guest_store
    .else
    H_PB_ENTER hvm_guest_load
    .endif
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    .if \vector
    csrr t0,vstart
    bnez t0,fail
    vmv.x.s t0,v8
    li t1,-1
    bne t0,t1,fail
    .endif
    .endm
    H_PB_BUSFAULT 1820,1
    H_PB_BUSFAULT 1821,2,1
    H_PB_BUSFAULT 1822,1,0,1
    H_PB_BUSFAULT 1823,2,0,1

    .macro H_PB_FF id,type
    H_PB_SETUP \id,0,\type
    H_VM_SET (HVM_GDATA+33*8),0x88000000,((\type<<61)|0xdf)
    H_VM_FLUSH
    li t0,0x80060ff0
    fence iorw,iorw
    cbo.flush (t0)
    fence iorw,iorw
    li a1,0x40020ff0
    H_PB_ENTER hvm_guest_ff
    bnez s7,fail
    li t0,2
    bne a0,t0,fail
    li t0,HMEM_OLD
    bne a2,t0,fail
    bnez a4,fail
    // Both completed elements survive; the first element beyond trimmed
    // vl remains undisturbed. Inspect without accessing the failed page.
    vsetivli zero,4,e64,m1,tu,mu
    vslidedown.vi v2,v1,1
    vmv.x.s t0,v2
    li t1,HVM_VALUE
    bne t0,t1,fail
    vslidedown.vi v2,v1,2
    vmv.x.s t0,v2
    li t1,-1
    bne t0,t1,fail
    .endm
    H_PB_FF 1830,1
    H_PB_FF 1831,2
    jal ra,hpb_cbo_matrix
#endif
#endif

#if H_TEST_TIMER
    .macro H_T_CASE id
    CASE \id
    li tp,0
    csrw 0x605,zero
    li t0,-1
    csrw 0x24d,t0
    csrw 0x14d,t0
    .endm
    .macro H_T_TIME id,mode,delta
    H_T_CASE \id
    li t0,\delta
    csrw 0x605,t0
    csrr a4,time
    ENTER \mode,h_timer_rdtime
    csrr a5,time
    .if \mode & 4
    li t0,\delta
    sub t1,a0,t0
    .else
    mv t1,a0
    .endif
    // Remove the offset modulo 2^64, then bracket by host reads. This tests
    // the architectural clock view without comparing platform tick rates.
    bltu t1,a4,fail
    bltu a5,t1,fail
    .endm
    H_T_TIME 1000,3,0x1234567800000000
    H_T_TIME 1001,1,0x1234567800000000
    H_T_TIME 1002,0,0x1234567800000000
    H_T_TIME 1003,5,0x1234567800000000
    H_T_TIME 1004,4,0x1234567800000000
    H_T_TIME 1005,3,-1
    H_T_TIME 1006,1,-1
    H_T_TIME 1007,0,-1
    H_T_TIME 1008,5,-1
    H_T_TIME 1009,4,-1

    // Each permission row expands to all six CSR forms. Legal operations
    // return the old guest comparator and update only its guest bank; denied
    // operations retain rd and both comparators. M denial has class-2 priority.
    .macro H_T_CSR id,mode,csr,form,men,mct,hen,hct,sct,cause
    H_T_CASE \id
    li t0,0x1234
    csrw 0x24d,t0
    li t0,0x5678
    csrw 0x14d,t0
    li t0,\men<<63
    csrw menvcfg,t0
    li t0,\hen<<63
    csrw HENVCFG,t0
    li t0,(\mct<<1)|5
    csrw mcounteren,t0
    li t0,(\hct<<1)|5
    csrw HCOUNTEREN,t0
    li t0,(\sct<<1)|5
    csrw scounteren,t0
    EXPECT 3,\cause
    ENTER \mode,.Lhtc_body\@
    .if \cause
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    CHECK_CSR 0x24d,0x1234
    .else
    bnez s7,fail
    li t0,0x1234
    bne a0,t0,fail
    .if \form == 0
    CHECK_CSR 0x24d,0x5a
    .elseif \form == 1
    CHECK_CSR 0x24d,0x127e
    .elseif \form == 2
    CHECK_CSR 0x24d,0x1224
    .elseif \form == 3
    CHECK_CSR 0x24d,5
    .elseif \form == 4
    CHECK_CSR 0x24d,0x1235
    .else
    CHECK_CSR 0x24d,0x1230
    .endif
    .endif
    CHECK_CSR 0x14d,0x5678
    li t0,0x5a
    bne a2,t0,fail
    j .Lhtc_after\@
.Lhtc_body\@:
    li a0,0x555
    li a2,0x5a
    .if \form < 3
    .set htc_word,(\csr<<20)|((\form+1)<<12)|(12<<15)|0x573
    .else
    .set htc_word,(\csr<<20)|((\form+2)<<12)|(5<<15)|0x573
    .endif
    .if \cause
    PROBE .word htc_word
    .else
    .word htc_word
    j guest_done
    .endif
.Lhtc_after\@:
    .endm
    .macro H_T_ROW base,mode,csr,men,mct,hen,hct,sct,cause
    .irp form,0,1,2,3,4,5
    H_T_CSR (\base+\form),\mode,\csr,\form,\men,\mct,\hen,\hct,\sct,\cause
    .endr
    .endm
    H_T_ROW 1010,3,0x24d,0,0,0,0,0,0
    H_T_ROW 1020,1,0x24d,1,1,0,0,0,0
    H_T_ROW 1030,5,0x14d,1,1,1,1,0,0
    H_T_ROW 1040,5,0x14d,0,1,1,1,1,2
    H_T_ROW 1050,5,0x14d,1,0,1,1,1,2
    H_T_ROW 1060,5,0x14d,1,1,0,1,1,22
    H_T_ROW 1070,5,0x14d,1,1,1,0,1,22
    H_T_ROW 1080,5,0x14d,0,0,0,0,0,2
    H_T_ROW 1090,4,0x14d,1,1,1,1,1,22
    H_T_ROW 1100,0,0x14d,1,1,1,1,1,2
    H_T_ROW 1110,1,0x24d,0,1,1,1,1,2
    H_T_ROW 1120,1,0x24d,1,0,1,1,1,2
    H_T_ROW 1130,5,0x24d,1,1,1,1,1,22

    .macro H_T_ENABLE
    li t0,1<<63
    csrw menvcfg,t0
    csrw HENVCFG,t0
    .endm
    .macro H_T_PENDING expected
    li t2,10000
.Lhtp_wait\@:
    csrr t0,0x644
    andi t0,t0,64
    li t1,\expected<<6
    beq t0,t1,.Lhtp_done\@
    addi t2,t2,-1
    bnez t2,.Lhtp_wait\@
    j fail
.Lhtp_done\@:
    .endm
    H_T_CASE 1140
    H_T_ENABLE
    H_T_PENDING 0
    csrw 0x24d,zero
    H_T_PENDING 1
    CHECK_CSR HVIP,0,64
    CHECK_CSR mip,64,64
    li t0,64
    csrw HIDELEG,t0
    CHECK_CSR 0x244,32,32
    li t0,-1
    csrw 0x24d,t0
    H_T_PENDING 0
    CHECK_CSR HVIP,0,64
    H_T_CASE 1141
    H_T_ENABLE
    csrw 0x24d,zero
    H_T_PENDING 1
    li t0,64
    csrw HVIP,t0
    li t0,-1
    csrw 0x24d,t0
    H_T_PENDING 1
    csrw HVIP,zero
    H_T_PENDING 0
#if !H_TEST_TIMER_SPIKE_DIAGNOSTIC
    // Normative STCE-source transition; diagnostic oracle runs explicitly
    // omit this case while investigating stale timer pending in a reference.
    H_T_CASE 1142
    H_T_ENABLE
    csrw 0x24d,zero
    H_T_PENDING 1
    csrw HENVCFG,zero
    H_T_PENDING 0
    li t0,64
    csrw HVIP,t0
    H_T_PENDING 1
    H_T_ENABLE
    csrw HVIP,zero
    H_T_PENDING 1
    li t0,-1
    csrw 0x24d,t0
    H_T_PENDING 0
    H_T_CASE 1143
    H_T_ENABLE
    csrw 0x24d,zero
    H_T_PENDING 1
    csrw menvcfg,zero
    CHECK_CSR HENVCFG,0,(1<<63)
    H_T_PENDING 0
    li t0,64
    csrw HVIP,t0
    H_T_PENDING 1
    li t0,1<<63
    csrw menvcfg,t0
    csrw HVIP,zero
    H_T_PENDING 1
    CHECK_CSR 0x14d,-1
    li t0,-1
    csrw 0x24d,t0
    H_T_PENDING 0
#endif
    .macro H_T_RMW id,csr
    H_T_CASE \id
    H_T_ENABLE
    csrw 0x24d,zero
    H_T_PENDING 1
    // A read-modify-write must not turn hardware VSTIP into a software bit.
    csrsi \csr,4
    li t0,-1
    csrw 0x24d,t0
    H_T_PENDING 0
    CHECK_CSR HVIP,4,68
    csrci \csr,4
    CHECK_CSR HVIP,0,68
    .endm
    H_T_RMW 1144,0x344
    H_T_RMW 1145,0x644
    H_T_CASE 1146
    H_T_ENABLE
    csrw 0x24d,zero
    li t0,64
    csrw HIDELEG,t0
    H_T_PENDING 1
    ENTER 5,h_timer_sip_rmw
    andi t0,a0,32
    li t1,32
    bne t0,t1,fail
    H_T_PENDING 1
    CHECK_CSR HVIP,0,64
    li t0,-1
    csrw 0x24d,t0
    H_T_PENDING 0

    .macro H_T_BOTH expected
    li t2,10000
.Lhtb_wait\@:
    csrr t0,mip
    andi t0,t0,96
    li t1,\expected
    beq t0,t1,.Lhtb_done\@
    addi t2,t2,-1
    bnez t2,.Lhtb_wait\@
    j fail
.Lhtb_done\@:
    .endm
    H_T_CASE 1147
    H_T_ENABLE
    csrw 0x14d,zero
    H_T_BOTH 32
    li t0,-1
    csrw 0x24d,t0
    // A comparator write must not disturb the other, already-pending source.
    CHECK_CSR mip,32,32
    csrw 0x24d,zero
    H_T_BOTH 96
    li t0,-1
    csrw 0x14d,t0
    CHECK_CSR mip,64,64
    H_T_BOTH 64
    csrw 0x14d,zero
    H_T_BOTH 96
    li t0,-1
    csrw 0x24d,t0
    CHECK_CSR mip,32,32
    H_T_BOTH 32
    li t0,-1
    csrw 0x14d,t0
    H_T_BOTH 0

    H_T_CASE 1148
    H_T_ENABLE
    li t0,0x4000000000000000
    csrw 0x605,t0
    csrw 0x14d,zero
    H_T_BOTH 32
    li a4,0x4000000000000000
    ENTER 5,h_timer_alias_write
    li t0,-1
    bne a0,t0,fail
    H_T_BOTH 96
    li a4,-1
    ENTER 5,h_timer_alias_write
    li t0,0x4000000000000000
    bne a0,t0,fail
    H_T_BOTH 32
    CHECK_CSR HVIP,0,64
    li t0,-1
    csrw 0x14d,t0
    H_T_BOTH 0

    H_T_CASE 1149
    // With STCE disabled the comparators cannot replace software injection.
    li t0,32
    csrs mip,t0
    li t0,64
    csrw HVIP,t0
    H_T_BOTH 96
    csrw 0x14d,zero
    CHECK_CSR mip,96,96
    csrw 0x24d,zero
    CHECK_CSR mip,96,96
    li t0,-1
    csrw 0x14d,t0
    csrw 0x24d,t0
    csrw 0x605,t0
    li t3,64
.Lht_sw_stable:
    CHECK_CSR mip,96,96
    addi t3,t3,-1
    bnez t3,.Lht_sw_stable
    li t0,32
    csrc mip,t0
    csrw HVIP,zero
    H_T_BOTH 0

    H_T_CASE 1150
    H_T_ENABLE
    csrw HENVCFG,zero
    li t0,64
    csrw HVIP,t0
    csrw 0x14d,zero
    H_T_BOTH 96
    csrw 0x24d,zero
    CHECK_CSR mip,96,96
    li t0,-1
    csrw 0x24d,t0
    CHECK_CSR mip,96,96
    csrw HVIP,zero
    H_T_BOTH 32
    li t0,-1
    csrw 0x14d,t0
    H_T_BOTH 0

    H_T_CASE 1151
    H_T_ENABLE
    csrw 0x14d,zero
    li t0,1<<63
    csrw 0x24d,t0
    // Position virtual time far below 2^64, then wrap it to a small value.
    // The 2^32 margin avoids a dependency on a particular timer tick rate.
    csrr t0,time
    neg t0,t0
    li t1,-(1<<32)
    add t0,t0,t1
    csrw 0x605,t0
    H_T_BOTH 96
    csrr t0,time
    neg t0,t0
    li t1,1<<32
    add t0,t0,t1
    csrw 0x605,t0
    H_T_BOTH 32
    CHECK_CSR HVIP,0,64
    li t0,-1
    csrw 0x14d,t0
    H_T_BOTH 0

    H_T_CASE 1152
    H_T_ENABLE
    csrw 0x14d,zero
    csrw 0x24d,zero
    H_T_BOTH 96
    csrw mcounteren,zero
    csrw HCOUNTEREN,zero
    csrw scounteren,zero
    // Counter access gates restrict instructions, not timer generation.
    li t3,64
.Lht_gates_stable:
    CHECK_CSR mip,96,96
    addi t3,t3,-1
    bnez t3,.Lht_gates_stable
    li t0,-1
    csrw 0x14d,t0
    csrw 0x24d,t0
    H_T_BOTH 0

    .macro H_T_TIME_GATE id,mode,mct,hct,sct,cause
    H_T_CASE \id
    li t0,0x1234567800000000
    csrw 0x605,t0
    li t0,(\mct<<1)|5
    csrw mcounteren,t0
    li t0,(\hct<<1)|5
    csrw HCOUNTEREN,t0
    li t0,(\sct<<1)|5
    csrw scounteren,t0
    EXPECT 3,\cause
    .if \cause
    ENTER \mode,h_timer_probe_time
    li t0,1
    bne s7,t0,fail
    .else
    csrr a4,time
    ENTER \mode,h_timer_rdtime
    csrr a5,time
    bnez s7,fail
    .if \mode & 4
    li t0,0x1234567800000000
    sub a0,a0,t0
    .endif
    bltu a0,a4,fail
    bltu a5,a0,fail
    .endif
    .endm
    H_T_TIME_GATE 1160,1,0,1,1,2
    H_T_TIME_GATE 1161,1,1,0,0,0
    H_T_TIME_GATE 1162,0,1,1,0,2
    H_T_TIME_GATE 1163,5,0,0,0,2
    H_T_TIME_GATE 1164,5,1,0,1,22
    H_T_TIME_GATE 1165,5,1,1,0,0
    H_T_TIME_GATE 1166,4,0,0,0,2
    H_T_TIME_GATE 1167,4,1,0,1,22
    H_T_TIME_GATE 1168,4,1,1,0,22
    H_T_TIME_GATE 1169,4,1,1,1,0

    .macro H_T_IRQ id,mode,handler=2,vect=0,bit=6,mask=0,future=0
    H_T_CASE \id
    H_T_ENABLE
    li tp,HTIMER_IRQ
    .if \handler == 2
    EXPECT 2,IRQ|(\bit-1),0
    .else
    EXPECT 1,IRQ|\bit,0
    .endif
    li a7,-1
    .if \vect
    la t0,h_timer_vectors
    ori t0,t0,1
    .else
    la t0,h_timer_relocated
    .endif
    csrw VSTVEC,t0
    li t0,1<<\bit
    .if \mask != 2
    csrw HIE,t0
    .endif
    .if \handler == 2
    csrw HIDELEG,t0
    .endif
    .if \mode == 5 && \mask != 1
    li t0,CTX|2
    csrw VSSTATUS,t0
    .endif
    .if \bit == 6
    .if \future
    csrr t0,time
    addi t0,t0,1
    csrw 0x24d,t0
    .else
    csrw 0x24d,zero
    .endif
    .else
    li t0,1<<\bit
    csrw HVIP,t0
    .endif
    .if \mask == 1
    la s4,h_timer_mask_global
    la s10,irq_wait_end
    ENTER \mode,h_timer_mask_global
    .elseif \mask == 2
    la s4,h_timer_mask_local
    la s10,irq_wait_end
    ENTER \mode,h_timer_mask_local
    .else
    la s4,irq_wait
    la s10,irq_wait_end
    ENTER \mode,irq_wait
    .endif
    li t0,1
    bne s7,t0,fail
    .if \handler == 1
    li t0,-1
    .elseif \vect
    li t0,\bit-1
    .else
    li t0,0
    .endif
    bne a7,t0,fail
    CHECK_CSR HVIP,0,0x444
    H_T_PENDING 0
    .endm
    H_T_IRQ 1200,5
    H_T_IRQ 1201,4
    H_T_IRQ 1202,5,1
    H_T_IRQ 1203,4,1
    H_T_IRQ 1204,5,2,1
    H_T_IRQ 1205,4,2,1
    H_T_IRQ 1206,5,2,1,2
    H_T_IRQ 1207,5,2,1,10
    H_T_IRQ 1208,5,2,0,6,1
    H_T_IRQ 1209,5,2,0,6,2
    H_T_IRQ 1210,5,2,1,6,0,1

    // Shvstvala reaches the VS bank through actual delegated traps, not a
    // fabricated CSR input. Direct BASE+4 and MODE=Vectored both send
    // synchronous exceptions to BASE. Breakpoints additionally pin Karu's
    // informative EBREAK policy (the profile itself exempts software EBREAK).
    .macro H_T_VSFAULT id,mode,kind,vect=0
    H_T_CASE \id
    li tp,HTIMER_VSFAULT
    .if \kind == 0 || \kind == 1
    EXPECT 2,2,0
    .elseif \kind == 2
    EXPECT 2,5,0x01000000
    .elseif \kind == 3
    EXPECT 2,7,0x01000000
    .elseif \kind == 4
    EXPECT 2,1,0x01000000
    li tp,HTIMER_FETCH
    .else
    EXPECT 2,3,0
    .endif
    li a6,4
    .if \kind == 1 || \kind == 6
    li a6,2
    .endif
    li t0,1
    sll t0,t0,s2
    csrw medeleg,t0
    csrw HEDELEG,t0
    .if \vect
    la t0,h_timer_vectors
    ori t0,t0,1
    .else
    la t0,h_timer_relocated
    .endif
    csrw VSTVEC,t0
    li a7,-1
    ENTER \mode,.Lhtv_body\@
    li t0,1
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    bnez a7,fail
    csrr t0,VSTVAL
    bne t0,s3,fail
    csrr t0,VSCAUSE
    bne t0,s2,fail
    CHECK_CSR sepc,0x81234000
    CHECK_CSR scause,13
    CHECK_CSR stval,0x4444
    j .Lhtv_after\@
.Lhtv_body\@:
    li a0,0x555
    li a1,0x01000000
    la s4,.Lhtv_insn\@
    .if \kind == 0
    li s3,0xffffffff
    .elseif \kind == 4
    li s4,0x01000000
    jr a1
    .elseif \kind == 5 || \kind == 6
    mv s3,s4
    .endif
.Lhtv_insn\@:
    .if \kind == 0
    .word 0xffffffff
    .elseif \kind == 1
    .2byte 0
    .elseif \kind == 2
    ld a0,0(a1)
    .elseif \kind == 3
    sd a0,0(a1)
    .elseif \kind == 5
    ebreak
    .elseif \kind == 6
    .2byte 0x9002
    .endif
    j guest_done
    .balign 4
.Lhtv_after\@:
    .endm
    H_T_VSFAULT 1300,5,0
    H_T_VSFAULT 1301,4,0,1
    H_T_VSFAULT 1302,5,1
    H_T_VSFAULT 1303,4,1,1
    H_T_VSFAULT 1304,5,2
    H_T_VSFAULT 1305,4,2
    H_T_VSFAULT 1306,5,3
    H_T_VSFAULT 1307,4,3,1
    H_T_VSFAULT 1308,5,4
    H_T_VSFAULT 1309,4,4,1
    H_T_VSFAULT 1310,5,5
    H_T_VSFAULT 1311,4,6,1
#endif

#if H_TEST_CONTEXT
    .macro H_C_RUN id,index,phase
    li s0,\id
    li a1,\index
    li a2,\phase
    la a3,hctx_guest
    li t0,0x40000000
    sub a3,a3,t0
    li a4,5
    csrr a6,time
    jal ra,hvm_guest_enter
    csrr a7,time
    csrr t0,0x605
    sub t0,a0,t0
    bltu t0,a6,fail
    bltu a7,t0,fail
    li t2,10000
.Lhcp_wait\@:
    csrr t0,0x644
    andi t0,t0,64
    li t1,(1-\index)*64
    beq t0,t1,.Lhcp_done\@
    addi t2,t2,-1
    bnez t2,.Lhcp_wait\@
    j fail
.Lhcp_done\@:
    CHECK_CSR sepc,0x81234000
    CHECK_CSR scause,13
    CHECK_CSR stval,0x4444
    .endm
    .macro H_C_SAVE id,index
    li s0,\id
    li a0,HCTX_A+\index*0x2000
    jal ra,hctx_save
    ld t0,128(a0)
    li t1,0x5d+\index*0x19
    bne t0,t1,fail
    ld t0,136(a0)
    li t1,9+\index*7
    bne t0,t1,fail
    ld t0,144(a0)
    li t1,13-\index*6
    bne t0,t1,fail
    ld t0,152(a0)
    li t1,3-\index*2
    bne t0,t1,fail
    .endm
    .macro H_C_RESTORE index
    li a0,HCTX_A+\index*0x2000
    jal ra,hctx_restore
    .endm
    CASE 1400
    CHECK_CSR vlenb,32
    li t0,(1<<63)|0xf0
    csrw menvcfg,t0
    csrw HENVCFG,t0
    li t0,0x444
    csrw HIDELEG,t0
    li a0,0
    jal ra,hctx_install
    H_C_RUN 1400,0,0
    H_C_SAVE 1401,0
    li a0,1
    jal ra,hctx_install
    H_C_RUN 1402,1,0
    H_C_SAVE 1403,1
    H_C_RESTORE 0
    H_C_RUN 1404,0,1
    H_C_RESTORE 1
    H_C_RUN 1405,1,1
    H_C_RESTORE 0
    H_C_RUN 1406,0,1

    .macro H_C_FAULT id,index,cause
    H_C_RESTORE \index
    li t0,(HVM_VL0+32*8)+\index*(HCTX_VB-HVM_VROOT)
    sd zero,0(t0)
    hfence.vvma
    li t0,1<<\cause
    csrw medeleg,t0
    csrw HEDELEG,t0
    H_C_RUN \id,\index,2
    CHECK_CSR VSCAUSE,\cause
    CHECK_CSR VSTVAL,HVM_VA
    li t0,(HVM_VL0+32*8)+\index*(HCTX_VB-HVM_VROOT)
    li t1,(0xa0020000>>2)|0xcf
    sd t1,0(t0)
    hfence.vvma
    csrw medeleg,zero
    csrw HEDELEG,zero
    .endm
    H_C_FAULT 1410,0,13
    H_C_FAULT 1411,1,15

    // Restore before every probe: access must follow the saved guest, not
    // whichever settings the previous guest left behind. VU executes an
    // executable U-page alias of the same small probe bodies; its data alias
    // has U=1 while the existing VS data mapping remains supervisor-only.
    .macro H_C_PROBE id,index,mode,target,cause,result=-1,address=0,machine_off=-1,mxr=0
    H_C_RESTORE \index
    li s0,\id
    li s1,3
    li s2,\cause
    li s7,0
    li s9,0
    .if \cause==13
    li s9,1
    .endif
    li s11,0
    la s4,\target
    lwu s3,0(s4)
    li t0,0x40000000
    sub s4,s4,t0
    .if \mode==4
    li t0,0x2000
    add s4,s4,t0
    // VS interrupts are enabled while executing lower-privilege VU even
    // with vsstatus.SIE=0. These permission probes do not service them.
    csrw VSIE,zero
    .endif
    .if \cause==13
    li s3,\address
    .endif
    .if \machine_off>=0
    csrw (0x30c+\machine_off),zero
    .endif
    .if \mxr
    li t0,1<<19
    csrs VSSTATUS,t0
    .endif
    li a0,0x555
    li a1,\address
    li a2,-1
    mv a3,s4
    li a4,\mode
    jal ra,hvm_guest_enter
    .if \machine_off>=0
    li t0,-1
    csrw (0x30c+\machine_off),t0
    .endif
    li t0,0
    .if \cause!=0
    li t0,1
    .endif
    bne s7,t0,fail
    .if \cause!=0
    li t0,0x555
    bne a0,t0,fail
    .elseif \result!=-1
    li t0,\result
    bne a0,t0,fail
    .else
    beqz a0,fail
    .endif
    CHECK_CSR sepc,0x81234000
    CHECK_CSR scause,13
    CHECK_CSR stval,0x4444
    .endm

    H_C_PROBE 1420,0,5,hctx_probe_scounteren,0,7
    H_C_PROBE 1421,1,5,hctx_probe_scounteren,0,2
    H_C_PROBE 1422,0,5,hctx_probe_senvcfg,0,HCTX_SENV_A
    H_C_PROBE 1423,1,5,hctx_probe_senvcfg,0,0
    H_C_PROBE 1424,0,4,hctx_probe_cycle,0
    H_C_PROBE 1425,1,4,hctx_probe_cycle,22
    H_C_PROBE 1426,0,5,hctx_probe_sstateen0,0,0
    H_C_PROBE 1427,1,5,hctx_probe_sstateen0,22
    H_C_PROBE 1428,0,5,hctx_probe_sstateen1,0,0
    H_C_PROBE 1429,1,5,hctx_probe_sstateen1,22
    H_C_PROBE 1430,0,5,hctx_probe_sstateen2,22
    H_C_PROBE 1431,1,5,hctx_probe_sstateen2,0,0
    H_C_PROBE 1432,0,5,hctx_probe_sstateen3,0,0
    H_C_PROBE 1433,1,5,hctx_probe_sstateen3,22
    H_C_PROBE 1434,0,5,hctx_probe_sstateen0,2,-1,0,0
    H_C_PROBE 1435,0,5,hctx_probe_sstateen1,2,-1,0,1
    H_C_PROBE 1436,0,5,hctx_probe_sstateen2,2,-1,0,2
    H_C_PROBE 1437,0,5,hctx_probe_sstateen3,2,-1,0,3

    .macro H_C_CBO id,index,target,cause,zeroes=0
    li t0,0x80060080+\index*(HCTX_DB-0x80060000)
    li t1,HMEM_GUARD
    .irp offset,-8,0,8,16,24,32,40,48,56,64
    sd t1,\offset(t0)
    .endr
    H_C_PROBE \id,\index,4,\target,\cause,0x555,0x40021080
    li t0,0x80060080+\index*(HCTX_DB-0x80060000)
    li t1,HMEM_GUARD
    ld t2,-8(t0)
    bne t2,t1,fail
    ld t2,64(t0)
    bne t2,t1,fail
    .if \zeroes
    li t1,0
    .endif
    .irp offset,0,8,16,24,32,40,48,56
    ld t2,\offset(t0)
    bne t2,t1,fail
    .endr
    .endm
    H_C_CBO 1438,0,hctx_probe_zero,0,1
    H_C_CBO 1439,1,hctx_probe_zero,22
    H_C_CBO 1440,0,hctx_probe_clean,0
    H_C_CBO 1441,1,hctx_probe_clean,22
    H_C_PROBE 1442,0,4,hctx_probe_load,0,0x1122334455667700,((1<<63)|HCTX_USERVA)
    H_C_PROBE 1443,1,4,hctx_probe_load,13,-1,((1<<63)|HCTX_USERVA)
    H_C_PROBE 1444,1,4,hctx_probe_load,0,0x1122334455667701,HCTX_USERVA
    H_C_PROBE 1445,0,4,hctx_probe_load,13,-1,((1<<63)|HCTX_USERVA),-1,1
#if H_TEST_CONTEXT_KECCAK
    H_C_RESTORE 0
    H_C_RUN 1600,0,3
    li a0,HCTX_A
    jal ra,hctx_save
    H_C_RESTORE 1
    H_C_RUN 1601,1,4
    li a0,HCTX_B
    jal ra,hctx_save
    H_C_RESTORE 0
    H_C_RUN 1602,0,5
#endif
#if H_TEST_PREEMPT
    CASE 1700
    li t0,1<<63
    csrw menvcfg,t0
    li a0,0
    jal ra,hctx_install
    H_C_RUN 1700,0,0
    li a0,HCTX_A
    jal ra,hctx_save
    li a0,1
    jal ra,hctx_install
    H_C_RUN 1701,1,0
    li a0,HCTX_B
    jal ra,hctx_save

    // Initially both guests have a disabled timer and a fresh guest entry.
    // The same record later receives the asynchronous GPR/PC trap frame.
    li a0,HCTX_A
    li a1,0
    la a2,.Lhcp_a_done
    jal ra,hpreempt_prepare
    li a0,HCTX_B
    li a1,1
    la a2,.Lhcp_b_done
    jal ra,hpreempt_prepare
    li t0,HCP_MARK
    la t1,hpreempt_fp_start
    li t2,0x40000000
    sub t1,t1,t2
    sd t1,8(t0)
    la t1,hpreempt_fp_end
    sub t1,t1,t2
    sd t1,16(t0)
    la t1,hpreempt_vec_start
    sub t1,t1,t2
    sd t1,24(t0)
    la t1,hpreempt_vec_end
    sub t1,t1,t2
    sd t1,32(t0)
    sd zero,40(t0)
    li t1,1
    sd t1,0(t0)
    la t0,hpreempt_trap
    csrw stvec,t0
    csrw HIDELEG,zero       // VSTIP is taken by HS, not the guest's VS handler.
    li t0,64
    csrw HIE,t0
    li a0,HCTX_A
    jal ra,hpreempt_enter
.Lhcp_a_done:
    li s0,1706
    li t0,HCTX_A
    ld t1,HCP_COUNT(t0)
    li t2,2
    bne t1,t2,fail
    // A completed after the fourth switch. B is still suspended at its
    // exact post-vector PC; enter HS to restore that final saved context.
    li a0,HCTX_B
    jal ra,hpreempt_enter
.Lhcp_b_done:
    li s0,1707
    li t0,HCTX_B
    ld t1,HCP_COUNT(t0)
    li t2,2
    bne t1,t2,fail
    li t0,HCP_MARK
    ld t1,40(t0)
    li t2,4
    bne t1,t2,fail
    csrw HIE,zero
#endif
#endif

    li t0,1
    li t1,TOHOST
    sd t0,0(t1)
1:  j 1b

#if H_TEST_HMEM
hmem_init:
    li t0,HMEM_SRC
    li t1,HMEM_DATA
    sd t1,0(t0)
    li t0,HMEM_DST
    li t1,HMEM_OLD
    sd t1,0(t0)
    li t1,HMEM_GUARD
    sd t1,-8(t0)
    sd t1,8(t0)
    ret
hmem_check_unchanged:
    li t0,HMEM_DST
    ld t1,0(t0)
    li t2,HMEM_OLD
    bne t1,t2,fail
hmem_check_guards:
    li t0,HMEM_DST
    ld t1,-8(t0)
    li t2,HMEM_GUARD
    bne t1,t2,fail
    ld t1,8(t0)
    bne t1,t2,fail
    li t0,HMEM_SRC
    ld t1,0(t0)
    li t2,HMEM_DATA
    bne t1,t2,fail
    ret
hmem_matrix:
    li tp,0
.Lhmm_next:
    jal ra,reset_case
    jal ra,hmem_init
    li s1,3
    li s2,0
    li s6,3
    li t0,2
    bltu tp,t0,.Lhmm_mode
    li s6,1
    li t0,4
    bltu tp,t0,.Lhmm_mode
    li s6,0
    li t0,6
    bltu tp,t0,.Lhmm_user
    li s6,5
    li s2,22
    li t0,8
    bltu tp,t0,.Lhmm_mode
    li s6,4
    j .Lhmm_mode
.Lhmm_user:
    andi t0,tp,1
    bnez t0,.Lhmm_mode
    li s2,2
.Lhmm_mode:
    andi t0,tp,1
    slli t0,t0,9
    csrw HSTATUS,t0
    mv s4,a3
    lwu s3,0(s4)
    li a0,0x555
    li a1,HMEM_SRC
    beqz a7,.Lhmm_load
    li a1,HMEM_DST
.Lhmm_load:
    li a2,HMEM_DATA
    li ra,0x9999
    la s5,.Lhmm_return
    csrw mepc,a3
    andi t0,s6,3
    slli t0,t0,11
    srli t1,s6,2
    slli t1,t1,39
    or t0,t0,t1
    li t1,CTX
    or t0,t0,t1
    csrw mstatus,t0
    mret
.Lhmm_return:
    snez t0,s2
    bne s7,t0,fail
    mv t0,a4
    beqz s2,.Lhmm_result
    li t0,0x555
.Lhmm_result:
    bne a0,t0,fail
    li t0,HMEM_SRC
    beqz a7,.Lhmm_addr
    li t0,HMEM_DST
.Lhmm_addr:
    bne a1,t0,fail
    li t0,HMEM_DATA
    bne a2,t0,fail
    li t0,0x9999
    bne ra,t0,fail
    li t0,HMEM_OLD
    bnez s2,.Lhmm_memory
    beqz a7,.Lhmm_memory
    mv t0,a6
.Lhmm_memory:
    li t1,HMEM_DST
    ld t2,0(t1)
    bne t0,t2,fail
    jal ra,hmem_check_guards
    addi s0,s0,1
    addi tp,tp,1
    li t0,10
    bltu tp,t0,.Lhmm_next
    jr gp
#endif

#if H_TEST_VM || H_TEST_CONTEXT
hvm_init:
    li tp,0
    // Poison both trap-information banks. The selected bank must receive
    // fresh metadata (including zero where appropriate). M handlers also
    // verify the accessible, unselected HS bank remains undisturbed.
    li t0,0x12345
    csrw 0x34b,t0
    csrw 0x643,t0
    li t0,0x54321
    csrw 0x34a,t0
    csrw 0x64a,t0
    // Reinitialize precisely the entries used by this fixture; all unused
    // entries are statically zero. No clearing loop dominates test runtime.
    H_VM_SET (HVM_GROOT+2*8),HVM_GL1,1
    H_VM_SET (HVM_GROOT+1026*8),HVM_GL1,1
    H_VM_SET (HVM_GL1+128*8),HVM_GPT,1
    H_VM_SET (HVM_GL1+256*8),HVM_GDATA,1
    H_VM_SET (HVM_GPT+16*8),HVM_VROOT,0xdf
    H_VM_SET (HVM_GPT+17*8),HVM_VL1,0xdf
    H_VM_SET (HVM_GPT+18*8),HVM_VL0,0xdf
    H_VM_SET (HVM_GDATA+32*8),0x80060000,0xdf
    H_VM_SET (HVM_GDATA+33*8),0x80061000,0xdf
    H_VM_SET (HVM_GDATA+100*8),0x80064000,0xdf
    H_VM_SET (HVM_GDATA+101*8),0x80065000,0xdf
    li t3,HVM_VROOT
    li t4,0x80060000
    li t5,0x80064000
    beqz a1,.Lhvmi_vtables
    li t3,0x90010000
    li t4,0xa0020000
    li t5,0xa0064000
.Lhvmi_vtables:
    li t0,HVM_VROOT+8
    li t1,0x1000
    add t1,t3,t1
    srli t1,t1,2
    ori t1,t1,1
    sd t1,0(t0)
    li t0,HVM_VL1
    li t1,0x2000
    add t1,t3,t1
    srli t1,t1,2
    ori t1,t1,1
    sd t1,0(t0)
    li t0,HVM_VL0+32*8
    srli t1,t4,2
    ori t1,t1,0xcf
    sd t1,0(t0)
    addi t1,t1,1024
    sd t1,8(t0)
    li t0,HVM_VL0+100*8
    srli t1,t5,2
    ori t1,t1,0xcf
    sd t1,0(t0)
    addi t1,t1,1024
    sd t1,8(t0)
    li t0,0x80060030
    li t1,HVM_VALUE
    sd t1,0(t0)
    li t0,0x80060ff0
    li t1,HMEM_OLD
    sd t1,0(t0)
    li t1,HVM_VALUE
    sd t1,8(t0)
    li t0,0x80061000
    li t1,HMEM_DATA
    sd t1,0(t0)
    li t0,(1<<8)|(1<<9)
    csrw HSTATUS,t0
    li t0,0
    beqz a0,.Lhvmi_vsatp
    srli t0,t3,12
    li t1,(8<<60)|(17<<44)
    or t0,t0,t1
.Lhvmi_vsatp:
    csrw VSATP,t0
    li t0,0
    beqz a1,.Lhvmi_hgatp
    li t0,(8<<60)|(3<<44)|(HVM_GROOT>>12)
.Lhvmi_hgatp:
    csrw HGATP,t0
    hfence.vvma
    hfence.gvma
    addi a1,t4,0x30
    mv a3,t5
    beqz a0,.Lhvmi_done
    li a1,HVM_VA
    li a3,0x40064000
.Lhvmi_done:
    ret
hvm_guest_enter:
    mv s5,ra
    mv s6,a4
    csrw mepc,a3
    andi t0,a4,3
    slli t0,t0,11
    li t1,CTX|MPV
    or t0,t0,t1
    csrw mstatus,t0
    mret
#endif

#if H_TEST_PBMT
// All cacheability transitions use the normative fence/flush/fence sequence
// for every touched line. Different source bytes expose duplicated NC beats.
hpb_sync:
    fence iorw,iorw
    li t0,0x80060100
    li t1,0x80060300
1:  cbo.flush (t0)
    addi t0,t0,64
    bltu t0,t1,1b
    fence iorw,iorw
    ret
hpb_prepare:
    li t0,0x80060100
    li t1,0x80060300
    li t2,0xa5a5a5a5a5a5a5a5
1:  sd t2,0(t0)
    addi t0,t0,8
    bltu t0,t1,1b
    li t0,0x80060100
    li t1,0x8877665544332211
    sd t1,0(t0)
    li t1,HMEM_DATA
    sd t1,8(t0)
    li t0,0x80060200
    li t1,0x80060220
    li t2,0
2:  sb t2,0(t0)
    addi t0,t0,1
    addi t2,t2,1
    bltu t0,t1,2b
    li t0,0x80060280
    li t1,0x800602a0
    li t2,0x40
3:  sb t2,0(t0)
    addi t0,t0,1
    addi t2,t2,1
    bltu t0,t1,3b
    // Real loads warm each cache line before hpb_sync changes aliases.
    li t0,0x80060100
    li t1,0x80060300
4:  ld t2,0(t0)
    addi t0,t0,64
    bltu t0,t1,4b
    ret
hpb_verify:
    li t0,0x80060180
    ld t1,0(t0)
    li t2,0x887766554433a511
    bne t1,t2,fail
    ld t1,8(t0)
    li t2,HMEM_DATA
    bne t1,t2,fail
    ld t1,-8(t0)
    li t2,0xa5a5a5a5a5a5a5a5
    bne t1,t2,fail
    ld t1,16(t0)
    bne t1,t2,fail
    li t0,0x80060240
    li t1,0
1:  lbu t2,0(t0)
    li t3,0xa5
    li t4,22
    bgeu t1,t4,2f
    andi t4,t1,2       // e16 mask 0x555: active byte pairs 0,4,...,20
    bnez t4,2f
    mv t3,t1
2:  bne t2,t3,fail
    addi t0,t0,1
    addi t1,t1,1
    li t2,32
    bltu t1,t2,1b
    li t0,0x800602c0
    li t1,0
3:  lbu t2,0(t0)
    li t3,0xa5
    li t4,3
    bltu t1,t4,4f
    li t4,22
    bgeu t1,t4,4f
    addi t3,t1,0x3e   // destination 3..21 receives source bytes 0x41..0x53
4:  bne t2,t3,fail
    addi t0,t0,1
    addi t1,t1,1
    li t2,32
    bltu t1,t2,3b
    ret

// Runtime matrix keeps all 144 combinations in the existing host-text budget.
// sp holds this leaf driver's return PC; s10 is its index. The common trap
// handlers and called setup routines deliberately leave these registers alone.
hpb_cbo_matrix:
    mv sp,ra
    li s10,0
.Lhpc_next:
    addi s0,s10,1900
    jal ra,reset_case
    li a0,1
    li a1,1
    jal ra,hvm_init
    srli t3,s10,4            // pair = VS*3 + G
    li t4,0
.Lhpc_vs:
    li t0,3
    bltu t3,t0,.Lhpc_types
    addi t3,t3,-3
    addi t4,t4,1
    j .Lhpc_vs
.Lhpc_types:
    slli t3,t3,61
    slli t4,t4,61
    li t0,HVM_VL0+32*8
    ld t1,0(t0)
    or t1,t1,t4
    sd t1,0(t0)
    li t0,HVM_GDATA+32*8
    ld t1,0(t0)
    or t1,t1,t3
    sd t1,0(t0)

    // Alternate VS and VU for the first three scenarios; senvcfg denial
    // only constrains VU. VS and VU keep distinct U-bit permissions.
    srli t0,s10,4
    andi t0,t0,1
    li a4,5
    sub a4,a4,t0
    andi t0,s10,3
    li t1,3
    bne t0,t1,.Lhpc_mode
    li a4,4
.Lhpc_mode:
    li t0,4
    bne a4,t0,.Lhpc_env
    li t0,HVM_VL0+32*8
    ld t1,0(t0)
    ori t1,t1,16
    sd t1,0(t0)
    H_VM_PTE (HVM_VL0+100*8),0xdf
.Lhpc_env:
    li t4,(1<<62)|0xf0
    srli t0,s10,4
    andi t0,t0,1
    beqz t0,.Lhpc_cbie
    xori t4,t4,0x20         // exercise CBIE=01 (flush) and 11 (invalidate)
.Lhpc_cbie:
    mv t5,t4
    mv t6,t4
    srli s8,s10,2
    andi s8,s8,3            // zero, clean, flush, inval
    li t3,0x80
    beqz s8,.Lhpc_gate
    li t3,0x40
    li t0,3
    bne s8,t0,.Lhpc_gate
    li t3,0x30
.Lhpc_gate:
    not t3,t3
    li s1,3
    li s2,0
    andi t0,s10,3
    beqz t0,.Lhpc_controls
    li s2,22
    li s1,1
    li t1,3
    beq t0,t1,.Lhpc_sdeny
    and t5,t5,t3
    li t1,2
    beq t0,t1,.Lhpc_controls
    and t4,t4,t3            // machine denial wins even when HS/S deny too
    li s2,2
    li s1,3
.Lhpc_sdeny:
    and t6,t6,t3
.Lhpc_controls:
    csrw menvcfg,t4
    csrw HENVCFG,t5
    csrw senvcfg,t6
    li t0,1<<22
    csrw medeleg,t0
    H_VM_FLUSH

    // Initialize the entire block and both adjacent words. The unaligned
    // operand names its final byte, not its aligned beginning.
    li t0,0x80060078
    li t1,0x800600c8
    li t2,HMEM_GUARD
.Lhpc_fill:
    sd t2,0(t0)
    addi t0,t0,8
    bltu t0,t1,.Lhpc_fill
    li tp,HVM_META
    li gp,0
    li a6,0
    li a7,0
    la t0,hpb_guest_cbo
    slli t1,s8,3
    add t0,t0,t1
    lwu s3,0(t0)
    la t1,hvm_guest_scalar
    sub t0,t0,t1
    li s4,0x40064000
    add s4,s4,t0
    mv a3,s4
    li a0,0x555
    li a1,0x400200bf
    li a2,HMEM_DATA
    // Management ignores NC/IO attributes. After the normative alias
    // transition, warm the physical cache alias immediately before the
    // guest operation; the passive observer checks this core's write-through
    // flush policy without treating optional clean eviction as an ISA rule.
    fence iorw,iorw
    li t0,0x80060080
    cbo.flush (t0)
    fence iorw,iorw
    ld t1,0(t0)
    jal ra,hvm_guest_enter
    snez t0,s2
    bne s7,t0,fail
    li t0,0x555
    bne a0,t0,fail
    li t0,0x400200bf
    bne a1,t0,fail
    li t0,HMEM_DATA
    bne a2,t0,fail
    li t0,2
    bne s2,t0,.Lhpc_verify
    CHECK_CSR sepc,0x81234000
    CHECK_CSR scause,13
    CHECK_CSR stval,0x4444
.Lhpc_verify:
    fence iorw,iorw
    li t0,0x80060080
    cbo.flush (t0)
    fence iorw,iorw
    li t1,HMEM_GUARD
    ld t2,-8(t0)
    bne t2,t1,fail
    ld t2,64(t0)
    bne t2,t1,fail
    or t2,s8,s2
    bnez t2,.Lhpc_words
    li t1,0
.Lhpc_words:
    li t3,8
.Lhpc_word:
    ld t2,0(t0)
    bne t2,t1,fail
    addi t0,t0,8
    addi t3,t3,-1
    bnez t3,.Lhpc_word
    addi s10,s10,1
    li t0,144
    bltu s10,t0,.Lhpc_next
    jr sp
#endif

#if H_TEST_CONTEXT
    // a0 is the guest index. Every guest uses the same VAs and GPAs but has
    // distinct VS and G roots, VMID/ASID, data HPA and save-area HPA.
hctx_install:
    // Portable world switch: do not expose a previous VS root under the
    // incoming VMID while building/installing its G root and environment.
    csrw VSATP,zero
    li t3,HVM_VROOT
    li t4,HVM_GROOT
    li t5,0x80060000
    li t6,HCTX_A
    beqz a0,.Lhci_roots
    li t3,HCTX_VB
    li t4,HCTX_GB
    li t5,HCTX_DB
    li t6,HCTX_B
.Lhci_roots:
    li t0,0x4000
    add t1,t4,t0
    srli t1,t1,2
    ori t1,t1,1
    sd t1,16(t4)
    add t0,t4,t0
    addi t1,t1,1024
    sd t1,1024(t0)
    addi t1,t1,1024
    li t2,2048
    add t2,t0,t2
    sd t1,0(t2)
    li t0,0x5000
    add t0,t4,t0
    srli t1,t3,2
    ori t1,t1,0xdf
    sd t1,128(t0)
    addi t1,t1,1024
    sd t1,136(t0)
    addi t1,t1,1024
    sd t1,144(t0)
    li t0,0x6000
    add t0,t4,t0
    srli t1,t5,2
    ori t1,t1,0xdf
    sd t1,256(t0)
    srli t1,t6,2
    ori t1,t1,0xdf
    sd t1,384(t0)
    addi t1,t1,1024
    sd t1,392(t0)
    li t1,(0x80064000>>2)|0xdf
    sd t1,800(t0)
    addi t1,t1,1024
    sd t1,808(t0)
    li t1,(0x90011000>>2)|1
    sd t1,8(t3)
    li t0,0x1000
    add t0,t3,t0
    li t1,(0x90012000>>2)|1
    sd t1,0(t0)
    li t0,0x2000
    add t0,t3,t0
    li t1,(0xa0020000>>2)|0xcf
    sd t1,256(t0)
    ori t1,t1,0x10
    sd t1,264(t0)
    li t1,(0xa0030000>>2)|0xcf
    sd t1,384(t0)
    addi t1,t1,1024
    sd t1,392(t0)
    li t1,(0xa0064000>>2)|0x4b
    sd t1,800(t0)
    addi t1,t1,1024
    sd t1,808(t0)
    ori t1,t1,0x10
    sd t1,824(t0)
    li t1,0x1122334455667700
    add t1,t1,a0
    sd t1,48(t5)
    addi t0,a0,3
    slli t0,t0,44
    srli t1,t4,12
    or t0,t0,t1
    li t1,8<<60
    or t0,t0,t1
    csrw HGATP,t0
    li t0,(1<<63)|0xf0
    csrw HENVCFG,t0
    li t0,7
    li t1,HCTX_SENV_A
    li t2,0xc000000000000000
    li t3,1<<63
    li t4,0
    beqz a0,.Lhci_shared
    li t0,2
    li t1,0
    li t2,1<<62
    li t3,0
    li t4,1<<63
.Lhci_shared:
    csrw scounteren,t0
    csrw senvcfg,t1
    csrw HSTATEEN0,t2
    csrw 0x60d,t3
    csrw 0x60e,t4
    csrw 0x60f,t3
    addi t0,a0,17
    slli t0,t0,44
    li t1,(8<<60)|(0x90010000>>12)
    or t0,t0,t1
    csrw VSATP,t0
    hfence.vvma
    hfence.gvma
    li t0,CTX
    csrw VSSTATUS,t0
    li t0,2
    li t1,4
    beqz a0,.Lhci_interrupt
    li t0,32
    li t1,1024
.Lhci_interrupt:
    csrw VSIE,t0
    csrw HVIP,t1
    li t0,256
    csrw HSTATUS,t0
    li t0,0x1234567800000000
    li t1,0
    beqz a0,.Lhci_timer
    li t0,-1
    li t1,-1
.Lhci_timer:
    csrw 0x605,t0
    csrw 0x24d,t1
    ret

    // Record: VS/hypervisor CSRs [0,120], scalar/vector control [128,160],
    // shared supervisor/state-enable controls [168,200],
    // all32 FPRs [256,512), and all32 256-bit VRs [512,1536).
    .macro H_C_SAVE_CSR csr,offset
    csrr t0,\csr
    sd t0,\offset(a0)
    .endm
    .macro H_C_LOAD_CSR csr,offset
    ld t0,\offset(a0)
    csrw \csr,t0
    .endm
hctx_save:
    H_C_SAVE_CSR VSSTATUS,0
    H_C_SAVE_CSR VSIE,8
    H_C_SAVE_CSR VSTVEC,16
    H_C_SAVE_CSR VSSCRATCH,24
    H_C_SAVE_CSR VSEPC,32
    H_C_SAVE_CSR VSCAUSE,40
    H_C_SAVE_CSR VSTVAL,48
    H_C_SAVE_CSR VSATP,56
    H_C_SAVE_CSR HGATP,64
    H_C_SAVE_CSR 0x605,72
    H_C_SAVE_CSR 0x24d,80
    H_C_SAVE_CSR HVIP,88
    H_C_SAVE_CSR HCOUNTEREN,96
    H_C_SAVE_CSR HENVCFG,104
    H_C_SAVE_CSR HSTATEEN0,112
    H_C_SAVE_CSR HSTATUS,120
    H_C_SAVE_CSR fcsr,128
    H_C_SAVE_CSR vtype,136
    H_C_SAVE_CSR vl,144
    H_C_SAVE_CSR vstart,152
    H_C_SAVE_CSR vcsr,160
    H_C_SAVE_CSR scounteren,168
    H_C_SAVE_CSR senvcfg,176
    H_C_SAVE_CSR 0x60d,184
    H_C_SAVE_CSR 0x60e,192
    H_C_SAVE_CSR 0x60f,200
    csrw vstart,zero
    .irp reg,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fsd f\reg,(256+8*\reg)(a0)
    .endr
    addi t0,a0,512
    vs8r.v v0,(t0)
    addi t0,t0,256
    vs8r.v v8,(t0)
    addi t0,t0,256
    vs8r.v v16,(t0)
    addi t0,t0,256
    vs8r.v v24,(t0)
    ret
hctx_restore:
    csrw VSATP,zero
    csrw vstart,zero
    .irp reg,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fld f\reg,(256+8*\reg)(a0)
    .endr
    addi t0,a0,512
    vl8re8.v v0,(t0)
    addi t0,t0,256
    vl8re8.v v8,(t0)
    addi t0,t0,256
    vl8re8.v v16,(t0)
    addi t0,t0,256
    vl8re8.v v24,(t0)
    H_C_LOAD_CSR fcsr,128
    ld t0,136(a0)
    ld t1,144(a0)
    vsetvl zero,t1,t0
    H_C_LOAD_CSR vcsr,160
    H_C_LOAD_CSR vstart,152
    H_C_LOAD_CSR VSSTATUS,0
    H_C_LOAD_CSR VSIE,8
    H_C_LOAD_CSR VSTVEC,16
    H_C_LOAD_CSR VSSCRATCH,24
    H_C_LOAD_CSR VSEPC,32
    H_C_LOAD_CSR VSCAUSE,40
    H_C_LOAD_CSR VSTVAL,48
    H_C_LOAD_CSR HGATP,64
    H_C_LOAD_CSR 0x605,72
    H_C_LOAD_CSR 0x24d,80
    H_C_LOAD_CSR HVIP,88
    H_C_LOAD_CSR HCOUNTEREN,96
    H_C_LOAD_CSR HENVCFG,104
    H_C_LOAD_CSR HSTATEEN0,112
    H_C_LOAD_CSR HSTATUS,120
    H_C_LOAD_CSR scounteren,168
    H_C_LOAD_CSR senvcfg,176
    H_C_LOAD_CSR 0x60d,184
    H_C_LOAD_CSR 0x60e,192
    H_C_LOAD_CSR 0x60f,200
    H_C_LOAD_CSR VSATP,56
    hfence.vvma
    hfence.gvma
    ret
#if H_TEST_PREEMPT
hpreempt_prepare:
    // a0 record, a1 index, a2 M-mode terminal continuation. Existing FP/VR
    // and VS-bank canaries remain intact; only interrupt delivery changes.
    .irp reg,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    sd zero,(HCP_GPR+8*\reg)(a0)
    .endr
    sd a1,(HCP_GPR+8*11)(a0)
    sd a2,(HCP_GPR+8*21)(a0)
    li t0,5
    sd t0,(HCP_GPR+8*22)(a0)
    la t0,hpreempt_guest
    li t1,0x40000000
    sub t0,t0,t1
    sd t0,HCP_PC(a0)
    li t0,(3<<13)|(3<<9)|256|32
    sd t0,HCP_STATUS(a0)
    sd zero,HCP_COUNT(a0)
    sd a1,HCP_INDEX(a0)
    sd zero,8(a0)            // VSIE: HS owns the preemption timer.
    sd zero,88(a0)           // no injected virtual software/external IRQs
    li t0,-1
    sd t0,80(a0)             // timer disarmed until guest work begins
    li t0,384
    sd t0,120(a0)            // HSTATUS.SPVP=SPV=1 for the first HS SRET
    ret

hpreempt_enter:
    // Enter the same HS restore path used by real interrupt switches.
    la t0,hpreempt_resume
    csrw mepc,t0
    li t0,CTX|(1<<11)
    csrw mstatus,t0
    mret

    .balign 4
hpreempt_trap:
    // sscratch is the host's context pointer, not guest vsscratch. Preserve
    // t0 with the swap before touching any other interrupted register.
    csrrw t0,sscratch,t0
    .irp reg,1,2,3,4,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    sd x\reg,(HCP_GPR+8*\reg)(t0)
    .endr
    csrr t1,sscratch
    sd t1,(HCP_GPR+8*5)(t0)
    csrw sscratch,t0
    csrr t1,scause
    li t2,IRQ|6
    bne t1,t2,fail
    csrr t1,stval
    bnez t1,fail
    csrr t1,HSTATUS
    andi t1,t1,384
    li t2,384
    bne t1,t2,fail
    csrr t1,sepc
    sd t1,HCP_PC(t0)
    csrr t1,sstatus
    sd t1,HCP_STATUS(t0)
    // Acknowledge the outgoing guest before saving the timer context. The
    // incoming guest's comparator stays disarmed until it programs a phase.
    li t1,-1
    csrw 0x24d,t1
    li t2,10000
.Lhcp_clear:
    csrr t1,0x644
    andi t1,t1,64
    beqz t1,.Lhcp_cleared
    addi t2,t2,-1
    bnez t2,.Lhcp_clear
    j fail
.Lhcp_cleared:
    mv a0,t0
    jal ra,hctx_save
    ld t0,HCP_COUNT(a0)
    addi t0,t0,1
    sd t0,HCP_COUNT(a0)
    li t1,2
    bltu t1,t0,fail
    beq t0,t1,.Lhcp_vector_image
    ld t1,256(a0)            // FP result must already be in the saved FPR.
    li t2,0x3ff0000000000000
    bne t1,t2,fail
    j .Lhcp_switch
.Lhcp_vector_image:
    ld t1,152(a0)            // retired vector instruction clears vstart
    bnez t1,fail
    ld t1,144(a0)
    li t2,32
    bne t1,t2,fail
    addi t1,a0,768           // saved v8..v15: 32 u64 quotients, all one
    li t2,32
    li t3,1
.Lhcp_vector_word:
    ld t4,0(t1)
    bne t4,t3,fail
    addi t1,t1,8
    addi t2,t2,-1
    bnez t2,.Lhcp_vector_word
.Lhcp_switch:
    li t0,HCP_MARK
    ld t1,40(t0)
    addi t1,t1,1
    sd t1,40(t0)
    li t2,4
    bltu t2,t1,fail
    li t0,0x2000
    xor a0,a0,t0            // A <-> B; no voluntary guest ECALL here.
hpreempt_resume:
    jal ra,hctx_restore
    ld t0,HCP_PC(a0)
    csrw sepc,t0
    ld t0,HCP_STATUS(a0)
    csrw sstatus,t0
    csrw sscratch,a0
    mv t0,a0
    .irp reg,1,2,3,4,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    ld x\reg,(HCP_GPR+8*\reg)(t0)
    .endr
    ld t0,(HCP_GPR+8*5)(t0)
    sret
#endif
#endif

reset_case:
    li t0,CTX
    csrw mstatus,t0
    csrw mie,zero
    csrw medeleg,zero
    csrw HVIP,zero
    csrw HEDELEG,zero
    csrw HIDELEG,zero
    csrw HSTATUS,zero
    csrw satp,zero
    csrw VSATP,zero
    csrw HGATP,zero
    sfence.vma
    csrw VSSTATUS,t0
    li t0,7
    csrw mcounteren,t0
    csrw HCOUNTEREN,t0
    csrw scounteren,t0
    li t0,-1
    csrw 0x30c,t0
    csrw 0x30d,t0
    csrw 0x30e,t0
    csrw 0x30f,t0
    csrw HSTATEEN0,t0
    csrw 0x60d,t0
    csrw 0x60e,t0
    csrw 0x60f,t0
    csrw menvcfg,zero
    csrw HENVCFG,zero
#if H_TEST_HMEM
    csrw senvcfg,zero
#endif
    la t0,hs_trap
    csrw stvec,t0
    la t0,vs_trap
    csrw VSTVEC,t0
    li t0,0x1111
    csrw sscratch,t0
    li t0,0x2222
    csrw VSSCRATCH,t0
    li t0,0x81234000
    csrw sepc,t0
    li t0,13
    csrw scause,t0
    li t0,0x4444
    csrw stval,t0
    li s1,0
    li s7,0
    li s8,0
    li s9,0
    li s11,0
    ret

hs_enter:
    // Deliberately disagree SPVP with SPP: SRET must use SPP for privilege.
    andi t0,a2,1
    xori t1,t0,1
    slli t1,t1,8
    ori t1,t1,128
    csrw HSTATUS,t1
    slli t0,t0,8
    csrr t1,sstatus
    li t2,~256
    and t1,t1,t2
    or t1,t1,t0
    csrw sstatus,t1
    csrw sepc,a3
    sret
bank_guest:
    CHECK_CSR sscratch,0x2222
    li t0,0x3333
    csrw sscratch,t0
    j guest_done
bank_trap_csrs:
    li t0,0x81236000
    csrw sepc,t0
    li t0,15
    csrw scause,t0
    li t0,0x6666
    csrw stval,t0
    j guest_done
vs_to_vu:
    la t0,guest_done
    csrw sepc,t0
    li t0,256
    csrc sstatus,t0
    li s6,4
    sret
probe_hstatus: PROBE csrr a0,HSTATUS
probe_vsstatus: PROBE csrr a0,VSSTATUS
probe_mstatus: PROBE csrr a0,mstatus
probe_absent: PROBE csrr a0,0x777
probe_ro_counter: PROBE csrrw a0,cycle,zero
probe_sstatus: PROBE csrr a0,sstatus
probe_satp: PROBE csrr a0,satp
probe_vsscratch_write:
    li t2,0x9999
    PROBE csrrw a0,VSSCRATCH,t2
probe_senvcfg: PROBE csrr a0,senvcfg
probe_sstateen: PROBE csrr a0,0x10c
probe_wfi: PROBE wfi
probe_sret: PROBE sret
probe_sfence: PROBE sfence.vma
probe_order_fence: PROBE .word 0x18000073
probe_cycle: PROBE csrr a0,cycle
probe_fp: PROBE fmv.w.x f0,zero
probe_vector: PROBE vsetivli a0,1,e8,m1,tu,mu
probe_ecall: PROBE ecall
read_cycle:
    csrr a0,cycle
    j guest_done
#if H_TEST_TIMER
h_timer_rdtime:
    csrr a0,time
    j guest_done
h_timer_probe_time: PROBE csrr a0,time
h_timer_alias_write:
    csrrw a0,0x14d,a4
    j guest_done
h_timer_sip_rmw:
    li t0,32
    csrrc a0,sip,t0
    j guest_done
#endif
write_fp:
    fmv.w.x f0,zero
    j guest_done
write_vector:
    vsetivli zero,1,e8,m1,tu,mu
    vmv.v.i v1,7
    j guest_done
vs_host_tvm:
    csrr t0,satp
    bnez t0,fail
    sfence.vma
    j guest_done
vs_order_fences:
    .word 0x18000073
    .word 0x18100073
    j guest_done
#if H_TEST_TIMER
h_timer_mask_global:
    li t0,64
1:  addi t0,t0,-1
    bnez t0,1b
    bnez s7,fail
    csrsi sstatus,2
    j irq_wait
h_timer_mask_local:
    li t0,64
1:  addi t0,t0,-1
    bnez t0,1b
    bnez s7,fail
    li t0,32
    csrs sie,t0
#endif
irq_wait:
    li t0,10000
1:  bnez s7,guest_done
    addi t0,t0,-1
    bnez t0,1b
    j fail
irq_wait_end:
guest_done:
    li s1,-1
    ecall
    j fail

    .align 2
m_trap:
    csrr a5,minstret
    csrr t6,mcause
    csrr t5,mepc
    csrr t4,mtval
    csrr t3,mstatus
    li t0,-1
    beq s1,t0,m_service
    li t0,-2
    beq s1,t0,m_nested
    li t0,-5
    beq s1,t0,m_irq_ack
    li t0,3
    bne s1,t0,m_fail
    bne t6,s2,m_fail
    bne t5,s4,m_fail
    bne t4,s3,m_fail
#if H_TEST_VM
    li t0,HVM_META
    bne tp,t0,.Lhvm_mmeta_done
    csrr t0,0x34b
    bne t0,gp,m_fail
    csrr t0,0x34a
    bne t0,a6,m_fail
    csrr t0,0x643
    li t1,0x12345
    bne t0,t1,m_fail
    csrr t0,0x64a
    li t1,0x54321
    bne t0,t1,m_fail
.Lhvm_mmeta_done:
#endif
    beqz s11,1f
    sub t0,a5,a4
    li t1,1
    bne t0,t1,m_fail
1:
    srli t0,t3,11
    andi t0,t0,3
    andi t1,s6,3
    bne t0,t1,m_fail
    srli t0,t3,39
    andi t0,t0,1
    srli t1,s6,2
    bne t0,t1,m_fail
    srli t0,t3,38
    andi t0,t0,1
    bne t0,s9,m_fail
    li s7,1
#if H_TEST_VM
    li t0,HVM_META
    bne tp,t0,.Lhvm_mresume
    beqz a7,.Lhvm_mresume
    csrw mepc,s5
    li t0,CTX|(3<<11)
    csrw mstatus,t0
    mret
.Lhvm_mresume:
#endif
    addi t5,t5,4
    csrw mepc,t5
    mret
m_service:
    andi t0,s6,3
    srli t2,s6,2
    and t1,t0,t2
    add t1,t1,t0
    addi t1,t1,8
    bne t6,t1,m_fail
    srli t1,t3,11
    andi t1,t1,3
    bne t1,t0,m_fail
    srli t1,t3,39
    andi t1,t1,1
    bne t1,t2,m_fail
    csrw mepc,s5
    li t0,CTX|(3<<11)
    // Retain FS/VS for the post-return dirty checks.
    li t1,(3<<13)|(3<<9)
    and t0,t3,t1
    li t1,3<<11
    or t0,t0,t1
    csrw mstatus,t0
    mret
m_nested:
    li t0,9
    bne t6,t0,m_fail
    la t0,hs_nested_ecall
    bne t5,t0,m_fail
    CHECK_CSR scause,10
    CHECK_CSR VSCAUSE,8
    csrr t0,VSEPC
    bne t0,s4,m_fail
    addi t5,t5,4
    csrw mepc,t5
    mret
m_irq_ack:
    li t0,10
    bne t6,t0,m_fail
    csrw HVIP,zero
#if H_TEST_TIMER
    li t0,HTIMER_IRQ
    bne tp,t0,.Lhti_mack_done
    H_T_PENDING 0
.Lhti_mack_done:
#endif
    li s1,2
    addi t5,t5,4
    csrw mepc,t5
    mret
m_fail:
    li t0,MPRV
    csrc mstatus,t0
    j fail

    .align 2
hs_trap:
    li t0,-1
    beq s1,t0,hs_service
    li t0,-3
    beq s1,t0,hs_nested
    li t0,1
    bne s1,t0,fail
    csrr t6,scause
    bne t6,s2,fail
    csrr t5,sepc
    csrr t4,stval
    bne t4,s3,fail
    csrr t3,HSTATUS
    srli t0,t3,7
    andi t0,t0,1
    srli t1,s6,2
    bne t0,t1,fail
    srli t0,t3,8
    andi t0,t0,1
    andi t1,s6,1
    bne t0,t1,fail
#if H_TEST_VM
    li t0,HVM_META
    bne tp,t0,.Lhvm_hmeta_done
    csrr t0,0x643
    bne t0,gp,fail
    csrr t0,0x64a
    bne t0,a6,fail
    srli t0,t3,6
    andi t0,t0,1
    bne t0,s9,fail
.Lhvm_hmeta_done:
#endif
    bltz t6,hs_irq
    bne t5,s4,fail
    li s7,1
    addi t5,t5,4
    csrw sepc,t5
    sret
hs_irq:
    bltu t5,s4,fail
    bgeu t5,s10,fail
    csrw HVIP,zero
#if H_TEST_TIMER
    li t0,HTIMER_IRQ
    bne tp,t0,.Lhti_hack_done
    li t0,-1
    csrw 0x24d,t0
    H_T_PENDING 0
.Lhti_hack_done:
#endif
    li s7,1
    sret
hs_service:
    li s6,1
    ecall
    j fail
hs_nested:
    CHECK_CSR scause,10
    CHECK_CSR HSTATUS,(1<<7)|(1<<8),(1<<7)|(1<<8)
    la t0,vs_nested_ecall
    csrr t1,sepc
    bne t0,t1,fail
    li s1,-2
hs_nested_ecall:
    ecall
    li s1,-3
    csrr t0,sepc
    addi t0,t0,4
    csrw sepc,t0
    sret

    .align 2
vs_trap:
    li t0,-1
    beq s1,t0,vs_service
    li t0,2
    bne s1,t0,fail
    csrr t6,scause
    bne t6,s2,fail
    csrr t5,sepc
    csrr t4,stval
    bne t4,s3,fail
    bltz t6,vs_irq
    bne t5,s4,fail
    csrr t0,sstatus
    srli t0,t0,8
    andi t0,t0,1
    andi t1,s6,1
    bne t0,t1,fail
    beqz s8,vs_return
    li s1,-3
vs_nested_ecall:
    ecall
    li s1,2
    CHECK_CSR scause,8
    csrr t5,sepc
    bne t5,s4,fail
vs_return:
#if H_TEST_VM
    li t0,HVM_VSFETCH
    bne tp,t0,.Lhvm_vsf_other
    bnez s7,fail
    bnez a6,fail
    li t0,0x555
    bne a0,t0,fail
    li t0,0x777
    bne a2,t0,fail
    sd a7,0(s10)
    ld t0,0(s10)
    bne t0,a7,fail
    sfence.vma
    li s7,1
    addi a6,a6,1
    csrw sepc,t5
    sret
.Lhvm_vsf_other:
#endif
    li s7,1
#if H_TEST_TIMER
    li t0,HTIMER_FETCH
    bne tp,t0,.Lhtv_not_fetch
    la t5,guest_done
    j .Lhtv_resume
.Lhtv_not_fetch:
    li t0,HTIMER_VSFAULT
    bne tp,t0,.Lhtv_default
    add t5,t5,a6
    j .Lhtv_resume
.Lhtv_default:
#endif
    addi t5,t5,4
#if H_TEST_TIMER
.Lhtv_resume:
#endif
    csrw sepc,t5
    sret
vs_irq:
    bltu t5,s4,fail
    bgeu t5,s10,fail
#if H_TEST_TIMER
    li t0,HTIMER_IRQ
    bne tp,t0,.Lhti_vack_done
    li t0,-1
    csrw 0x14d,t0
.Lhti_vack_done:
#endif
    li s1,-5
    ecall
    li s7,1
    sret
#if H_TEST_TIMER
    // Direct base deliberately has low BASE bits set; only four-byte
    // alignment is required. Vectored offsets use the VS-visible IRQ ID.
    .balign 64
    nop
h_timer_relocated:
    li a7,0
    j vs_trap
    .balign 64
h_timer_vectors:
    j h_timer_vector_0
    j h_timer_vector_1
    j fail
    j fail
    j fail
    j h_timer_vector_5
    j fail
    j fail
    j fail
    j h_timer_vector_9
h_timer_vector_0:
    li a7,0
    j vs_trap
h_timer_vector_1:
    li a7,1
    j vs_trap
h_timer_vector_5:
    li a7,5
    j vs_trap
h_timer_vector_9:
    li a7,9
    j vs_trap
#endif
vs_service:
    li s6,5
    ecall
    j fail
fail:
    slli t0,s0,1
    ori t0,t0,1
    li t1,TOHOST
    sd t0,0(t1)
1:  j 1b

    .section .htif,"aw",@progbits
    .globl tohost
    .align 3
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
    .section .root,"aw",@progbits
    .space 16
    .dword (0x80011<<10)|1
    .section .l1,"aw",@progbits
    .dword (0x80012<<10)|1
    .section .l0,"aw",@progbits
    .space 32*8
    .dword (0x80021<<10)|0xc7
    .section .identity,"aw",@progbits
    .space 0x100
    .dword 0x1111
#if H_TEST_HMEM
    .space 0xf8
    .dword HMEM_DATA
    .dword 0
    .dword HMEM_GUARD
    .dword HMEM_OLD
    .dword HMEM_GUARD
#endif
    .section .translated,"aw",@progbits
    .space 0x100
    .dword 0x2222
#if H_TEST_VM || H_TEST_CONTEXT
    .section .hvm_vs,"aw",@progbits
    .space 3*4096
    .section .hvm_g,"aw",@progbits
    .space 7*4096
    .section .hvm_data,"aw",@progbits
    .space 2*4096
    .section .hvm_code,"ax",@progbits
hvm_guest_scalar:
    ld a0,0(a1)
    sd a2,0(a1)
    j hvm_guest_done
hvm_guest_load:
    ld a0,0(a1)
    j hvm_guest_done
hvm_guest_store:
    sd a2,0(a1)
    j hvm_guest_done
hvm_guest_ff:
    vsetivli t0,4,e64,m1,tu,mu
    vmv.v.i v1,-1
    vle64ff.v v1,(a1)
    csrr a0,vl
    vmv.x.s a2,v1
    csrr a4,vstart
    j hvm_guest_done
hvm_guest_ffmask:
    vsetivli t0,4,e64,m1,tu,mu
    vmv.v.i v1,-1
    vmv.v.i v0,0
    li t0,2
    vmv.s.x v0,t0
    vle64ff.v v1,(a1),v0.t
    csrr a0,vl
    vmv.x.s a2,v1
    csrr a4,vstart
hvm_guest_done:
    li s1,-1
    ecall
1:  j 1b
#if H_TEST_VM
hvm_guest_fetch_probe:
    addi a0,zero,7
    addi a2,a2,1
    j hvm_guest_done
#endif
#if H_TEST_PBMT
hpb_guest_traffic:
    lbu t0,0x100(a1)
    sb t0,0x180(a1)
    lhu t0,0x102(a1)
    sh t0,0x182(a1)
    lwu t0,0x104(a1)
    sw t0,0x184(a1)
    ld t0,0x108(a1)
    sd t0,0x188(a1)
    ld t0,0x108(a1)   // repeated same-page accesses also exercise guest TLB hits
    sd t0,0x188(a1)
    vsetivli zero,11,e16,m1,tu,mu
    vmv.v.i v0,0
    li t0,0x555
    vmv.s.x v0,t0
    vmv.v.i v8,-1
    addi t0,a1,0x200
    vle16.v v8,(t0),v0.t
    addi t0,a1,0x240
    vse16.v v8,(t0),v0.t
    vsetivli zero,19,e8,m1,tu,mu
    addi t0,a1,0x281
    vle8.v v8,(t0)
    addi t0,a1,0x2c3
    vse8.v v8,(t0)
    j hvm_guest_done
hpb_guest_vfault:
    vle16.v v8,(a1)
    j hvm_guest_done
hpb_guest_cbo:
    cbo.zero (a1)
    j hvm_guest_done
    cbo.clean (a1)
    j hvm_guest_done
    cbo.flush (a1)
    j hvm_guest_done
    cbo.inval (a1)
    j hvm_guest_done
#endif
    .org 4094
hvm_guest_xpage:
    .2byte 0x0513 // addi a0,zero,7 split across two instruction pages.
    .2byte 0x0070
#if H_TEST_VM
    addi a2,a2,1
#endif
    j hvm_guest_done
#if H_TEST_CONTEXT
    .balign 4
    // One-instruction probes let the common precise-trap handler check
    // denied CSR destination canaries and exact cause/tval/PC. The U alias
    // shifts every PC by the same 8 KiB, including these relative branches.
hctx_probe_scounteren: csrr a0,scounteren
    j hctx_probe_done
hctx_probe_senvcfg: csrr a0,senvcfg
    j hctx_probe_done
hctx_probe_cycle: csrr a0,cycle
    j hctx_probe_done
hctx_probe_sstateen0: csrrw a0,0x10c,a2
    j hctx_probe_done
hctx_probe_sstateen1: csrrw a0,0x10d,a2
    j hctx_probe_done
hctx_probe_sstateen2: csrrw a0,0x10e,a2
    j hctx_probe_done
hctx_probe_sstateen3: csrrw a0,0x10f,a2
    j hctx_probe_done
hctx_probe_zero: .insn i 0x0f,2,x0,a1,4
    j hctx_probe_done
hctx_probe_clean: .insn i 0x0f,2,x0,a1,1
    j hctx_probe_done
hctx_probe_load: ld a0,0(a1)
hctx_probe_done:
    li s1,-1
    ecall
    j hctx_guest_fail
#if H_TEST_PREEMPT
    .macro H_P_GPRS initialize
    .set .Lhpg_value,0x5100
    .irp reg,ra,sp,gp,tp,s2,s3,s4,s8,s9,s10,s11,a3,a4,a5,a6,a7
    .if \initialize
    li \reg,.Lhpg_value
    add \reg,\reg,a1
    .else
    li t0,.Lhpg_value
    add t0,t0,a1
    bne \reg,t0,hctx_guest_fail
    .endif
    .set .Lhpg_value,.Lhpg_value+0x100
    .endr
    .endm
hpreempt_guest:
    addi s0,a1,1702
    H_P_GPRS 1
    fmv.d.x f0,zero
    li t2,HCTX_SAVEVA
    li t3,10000
    csrr t0,time
    addi t0,t0,H_PREEMPT_FP_TICKS
    csrw 0x14d,t0
    .globl hpreempt_fp_start,hpreempt_fp_end
hpreempt_fp_start:
    // A bounded dense loop works with instruction-count and real-time
    // reference clocks. Only the passive RTL observer proves overlap.
    .rept 16
    fdiv.d f0,f1,f1
    .endr
hpreempt_fp_end:
    ld t0,HCP_COUNT(t2)
    bnez t0,.Lhpg_fp_return
    addi t3,t3,-1
    bnez t3,hpreempt_fp_start
    j hctx_guest_fail
.Lhpg_fp_return:
    li t1,1
    bne t0,t1,hctx_guest_fail
    H_P_GPRS 0
    fmv.x.d t0,f0
    li t1,0x3ff0000000000000
    bne t0,t1,hctx_guest_fail
    slli t0,a1,52
    add t0,t0,t1
    fmv.d.x f0,t0             // restore the original all-FPR canary image
    // An FP-only preemption must preserve a nonzero vector restart index
    // and every scalar/vector control, before the next phase changes them.
    li t1,0x5d
    li t4,9
    li t5,13
    li t6,3
    li a0,5
    beqz a1,.Lhpg_controls
    li t1,0x76
    li t4,16
    li t5,7
    li t6,1
    li a0,2
.Lhpg_controls:
    csrr t0,fcsr
    bne t0,t1,hctx_guest_fail
    csrr t0,vtype
    bne t0,t4,hctx_guest_fail
    csrr t0,vl
    bne t0,t5,hctx_guest_fail
    csrr t0,vstart
    bne t0,t6,hctx_guest_fail
    csrr t0,vcsr
    bne t0,a0,hctx_guest_fail

    addi s0,a1,1704
    csrw vstart,zero
    vsetvli t0,zero,e64,m8,tu,mu
    li t1,32
    bne t0,t1,hctx_guest_fail
    li t3,10000
    csrr t0,time
    addi t0,t0,H_PREEMPT_VEC_TICKS
    csrw 0x14d,t0
    .globl hpreempt_vec_start,hpreempt_vec_end
hpreempt_vec_start:
    vdivu.vv v8,v16,v16
hpreempt_vec_end:
    ld t0,HCP_COUNT(t2)
    li t1,2
    beq t0,t1,.Lhpg_vec_return
    addi t3,t3,-1
    bnez t3,hpreempt_vec_start
    j hctx_guest_fail
.Lhpg_vec_return:
    H_P_GPRS 0
    csrr t0,vstart
    bnez t0,hctx_guest_fail
    csrr t0,vl
    li t1,32
    bne t0,t1,hctx_guest_fail
    li t0,0x40020200
    vse64.v v8,(t0)
    li t1,32
    li t4,1
.Lhpg_vec_word:
    ld t5,0(t0)
    bne t5,t4,hctx_guest_fail
    addi t0,t0,8
    addi t1,t1,-1
    bnez t1,.Lhpg_vec_word
    vsetvli zero,zero,e8,m1,tu,mu
    slli t1,a1,6
    addi t1,t1,0x39
    .irp reg,8,9,10,11,12,13,14,15
    vmv.v.x v\reg,t1
    addi t1,t1,1
    .endr
    jal ra,hctx_guest_controls
    addi s0,a1,1706
    li a2,6
    // Reuse the original all-FPR/all-VR/CSR canary verifier. The only
    // intentional differences are the acknowledged timer and IRQ enables.
    j hctx_guest_verify
#endif
hctx_guest:
    li t0,2
    beq a2,t0,hctx_guest_fault
#if H_TEST_CONTEXT_KECCAK
    li t0,3
    beq a2,t0,hctx_keccak_init
    li t0,4
    beq a2,t0,hctx_keccak_other
    li t0,5
    beq a2,t0,hctx_keccak_chain
#endif
    bnez a2,hctx_guest_verify
    li t0,HVM_VA
    ld t1,0(t0)
    li t2,0x1122334455667700
    add t2,t2,a1
    bne t1,t2,hctx_guest_fail
    li t0,0x11110000
    add t0,t0,a1
    csrw sscratch,t0
    slli t0,a1,2
    li t1,0x40065000
    add t0,t0,t1
    csrw sepc,t0
    slli t0,a1,1
    addi t0,t0,13
    csrw scause,t0
    li t0,0x12340000
    add t0,t0,a1
    csrw stval,t0
    la t0,hctx_vs_trap
    or t0,t0,a1
    csrw stvec,t0
    li t4,0x3ff0000000000000
    slli t0,a1,52
    add t4,t4,t0
    .irp reg,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fmv.d.x f\reg,t4
    addi t4,t4,1
    .endr
    csrw vstart,zero
    vsetvli t0,zero,e8,m1,tu,mu
    slli t4,a1,6
    addi t4,t4,0x31
    .irp reg,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    vmv.v.x v\reg,t4
    addi t4,t4,1
    .endr
    jal ra,hctx_guest_controls
    j hctx_guest_done

hctx_guest_verify:
    li t0,HVM_VA
    ld t1,0(t0)
    li t2,0x1122334455667700
    add t2,t2,a1
    bne t1,t2,hctx_guest_fail
    li t1,0x11110000
    add t1,t1,a1
    csrr t0,sscratch
    bne t0,t1,hctx_guest_fail
    slli t1,a1,2
    li t2,0x40065000
    add t1,t1,t2
    csrr t0,sepc
    bne t0,t1,hctx_guest_fail
    slli t1,a1,1
    addi t1,t1,13
    csrr t0,scause
    bne t0,t1,hctx_guest_fail
    li t1,0x12340000
    add t1,t1,a1
    csrr t0,stval
    bne t0,t1,hctx_guest_fail
    la t1,hctx_vs_trap
    or t1,t1,a1
    csrr t0,stvec
    bne t0,t1,hctx_guest_fail
#if H_TEST_PREEMPT
    li t0,6
    beq a2,t0,.Lhcv_preempt_irq
#endif
    csrr t0,0x14d
    neg t1,a1
    bne t0,t1,hctx_guest_fail
    li t1,2
    li t2,34
    beqz a1,.Lhcv_interrupt
    li t1,32
    li t2,512
.Lhcv_interrupt:
    csrr t0,sie
    bne t0,t1,hctx_guest_fail
    csrr t0,sip
    andi t0,t0,0x222
    bne t0,t2,hctx_guest_fail
#if H_TEST_PREEMPT
    j .Lhcv_irq_done
.Lhcv_preempt_irq:
    csrr t0,0x14d
    li t1,-1
    bne t0,t1,hctx_guest_fail
    csrr t0,sie
    bnez t0,hctx_guest_fail
    csrr t0,sip
    andi t0,t0,0x222
    bnez t0,hctx_guest_fail
.Lhcv_irq_done:
#endif
    addi t1,a1,17
    slli t1,t1,44
    li t2,(8<<60)|(0x90010000>>12)
    or t1,t1,t2
    csrr t0,satp
    bne t0,t1,hctx_guest_fail
    csrr t0,sstatus
    li t1,(3<<13)|(3<<9)
    and t0,t0,t1
    bne t0,t1,hctx_guest_fail
    li t4,0x5d
    li t5,9
    li t6,13
    li t3,3
    li t2,5
    beqz a1,.Lhcv_controls
    li t4,0x76
    li t5,16
    li t6,7
    li t3,1
    li t2,2
.Lhcv_controls:
    csrr t0,fcsr
    bne t0,t4,hctx_guest_fail
    csrr t0,vtype
    bne t0,t5,hctx_guest_fail
    csrr t0,vl
    bne t0,t6,hctx_guest_fail
    csrr t0,vstart
    bne t0,t3,hctx_guest_fail
    csrr t0,vcsr
    bne t0,t2,hctx_guest_fail
    li t4,0x3ff0000000000000
    slli t0,a1,52
    add t4,t4,t0
    .irp reg,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fmv.x.d t0,f\reg
    bne t0,t4,hctx_guest_fail
    addi t4,t4,1
    .endr
    csrw vstart,zero
    li t0,0x40020200
    vs8r.v v0,(t0)
    addi t0,t0,256
    vs8r.v v8,(t0)
    addi t0,t0,256
    vs8r.v v16,(t0)
    addi t0,t0,256
    vs8r.v v24,(t0)
    li t2,0x40020200
    li t6,32
    slli t4,a1,6
    addi t4,t4,0x31
.Lhcv_register:
    li t5,32
.Lhcv_byte:
    lbu t0,0(t2)
    bne t0,t4,hctx_guest_fail
    addi t2,t2,1
    addi t5,t5,-1
    bnez t5,.Lhcv_byte
    addi t4,t4,1
    addi t6,t6,-1
    bnez t6,.Lhcv_register
    jal ra,hctx_guest_controls
    j hctx_guest_done

hctx_guest_controls:
    li t4,0x5d
    li t5,9
    li t6,13
    li t3,3
    li t2,5
    beqz a1,.Lhcc_controls
    li t4,0x76
    li t5,16
    li t6,7
    li t3,1
    li t2,2
.Lhcc_controls:
    csrw fcsr,t4
    vsetvl zero,t6,t5
    csrw vcsr,t2
    csrw vstart,t3
    ret

hctx_guest_fault:
    li a0,0x555
    li t0,HVM_VA
    li s7,0
    bnez a1,.Lhcf_store
    la s4,.Lhcf_load_insn
.Lhcf_load_insn:
    ld a0,0(t0)
    j .Lhcf_done
.Lhcf_store:
    la s4,.Lhcf_store_insn
.Lhcf_store_insn:
    sd a0,0(t0)
.Lhcf_done:
    li t0,1
    bne s7,t0,hctx_guest_fail
    li t0,0x555
    bne a0,t0,hctx_guest_fail
    j hctx_guest_done
    .balign 4
hctx_vs_trap:
    csrr t0,scause
    slli t1,a1,1
    addi t1,t1,13
    bne t0,t1,hctx_guest_fail
    csrr t0,stval
    li t1,HVM_VA
    bne t0,t1,hctx_guest_fail
    csrr t0,sepc
    bne t0,s4,hctx_guest_fail
    addi t0,t0,4
    csrw sepc,t0
    li s7,1
    sret
hctx_guest_done:
    csrr a0,time
    li s1,-1
    ecall
    j hctx_guest_fail
hctx_guest_fail:
    // An unexpected ECALL reaches the common M-mode failure path, so fault
    // reporting does not depend on a guest mapping for the HTIF page.
    li s1,0
    ecall
1:  j 1b
#if H_TEST_CONTEXT_KECCAK
hctx_keccak_init:
    csrw vstart,zero
    vsetvli t0,zero,e64,m8,tu,mu
    vmv.v.i v0,0
    li t0,0x40020800
    li t1,0
1:  sd t1,0(t0)
    addi t0,t0,8
    addi t1,t1,1
    li t2,25
    bltu t1,t2,1b
    li t0,0x40020800
    vsetivli zero,25,e64,m8,tu,mu
    vle64.v v0,(t0)
    .word 0xa6092077 // vkeccak.vi v0,0: 24 rounds; keep result resident.
    j hctx_guest_done
hctx_keccak_other:
    csrw vstart,zero
    vsetvli t0,zero,e64,m8,tu,mu
    vmv.v.i v0,0
    .word 0xa6092077
    j hctx_guest_done
hctx_keccak_chain:
    .word 0xa6192077 // vkeccak.vi v0,1: final12 rounds after guestA restore.
    li t0,0x40020800
    vse64.v v0,(t0)
    la t1,hctx_keccak_expected
    li t2,25
1:  ld t3,0(t0)
    ld t4,0(t1)
    bne t3,t4,hctx_guest_fail
    addi t0,t0,8
    addi t1,t1,8
    addi t2,t2,-1
    bnez t2,1b
    j hctx_guest_done
    .balign 8
hctx_keccak_expected:
    // Same independent chained KAT as test/fw/keccak_subj.c: p12(p24(i)).
    .dword 0x80b4dac4d70b343c,0xe14fc37e8a15842d,0x8e1cdf99cfbeab02,0x7c27eeb4384901af
    .dword 0xca9182c92e35908c,0xb9bef1b3ea147c3a,0x4eb81bb3816a7a24,0xd613bee01496a772
    .dword 0xe545de321fcb5f6f,0x395d2bcbf5698b8e,0xde94add7e45e1c47,0x7be52c790c954988
    .dword 0xabcd674581cdff3e,0x56ba75236461793e,0x9b7313f24ec4d996,0xa415d984f122547c
    .dword 0xec9ddf3c17e3dc6b,0x349fb73bdde2713d,0x6673fc9eda55f234,0x83ae7bfbd51defe8
    .dword 0xde10fe926d226013,0xe3847f1d52aecda3,0x18b77b23dd945886,0x41484600a1301e74
    .dword 0x1f536079ba540e2c
#endif
    .section .hctx_vb,"aw",@progbits
    .space 3*4096
    .section .hctx_gb,"aw",@progbits
    .space 7*4096
    .section .hctx_a,"aw",@progbits
    .space 2*4096
    .section .hctx_b,"aw",@progbits
    .space 2*4096
    .section .hctx_db,"aw",@progbits
    .space 2*4096
#endif
#endif
