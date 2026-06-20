//	karu_sscofpmf_test.S
//	Directed test for Sscofpmf 3a -- the software-visible CSR + interrupt machinery
//	(built with KARU_SSCOFPMF). This matches spike's Sscofpmf model (OF and mip.LCOFIP
//	are SW-writable; no hardware overflow), so it cross-checks against spike:
//	  A. scountovf(0xDA0) bit N reflects mhpmeventN.OF (software-set here)
//	  B. LCOFI (mip/mie bit 13) delivers to M  -> mcause = 13 | (1<<63)
//	  C. LCOFI, delegated via mideleg[13], delivers to S -> scause = 13 | (1<<63)
//	  D. STIP + LCOFI both pending in S -> STIP (cause 5) wins; LCOFI is the lowest
//	     priority standard interrupt (catches a too-high LCOFI in the cause mux)
//	The mhpmevent WARL exact mask is karu64-specific (spike masks the event field
//	differently), so it is built only with -DSSCOFPMF_FULL. The hardware counter
//	overflow path is Slice 3b (karu64-only, needs a counting event). exit 0 = pass.
//
//	Regs: s1=error accumulator, s3=cause recorded by the trap handler, s4=M return
//	address for the S-mode phases.

	.equ TOHOST,         0x80001000
	.equ CSR_MHPMEVENT3, 0x323
	.equ CSR_MHPMEVENT4, 0x324
	.equ CSR_SCOUNTOVF,  0xDA0
	.equ CSR_MIE,        0x304
	.equ CSR_MIP,        0x344
	.equ CSR_MIDELEG,    0x303
	.equ CSR_SIP,        0x144
	.equ CSR_SIE,        0x104
	.equ CSR_STVEC,      0x105

	.section .text.boot,"ax"
	.globl _start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	li	s1, 0			//	error accumulator

#ifdef SSCOFPMF_NOS
	//	KARU_NO_S build: SINH(61) gates an unimplemented mode -> read-only 0, so the
	//	mhpmevent writable mask is OF|MINH|UINH|evt = 0xD000_0000_0000_001F. M-only.
	li	t0, -1
	csrw	CSR_MHPMEVENT3, t0
	csrr	t1, CSR_MHPMEVENT3
	li	t2, 0xD000000000000000
	ori	t2, t2, 0x1F
	bne	t1, t2, nos_fail
	li	t0, 1			//	pass (exit 0)
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
nos_fail:
	li	t0, (3 << 1) | 1
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
#endif

	//	=== A: scountovf reflects software-set OF bits ===
	li	t0, 1
	slli	t0, t0, 63		//	OF (bit 63)
	csrw	CSR_MHPMEVENT3, t0
	csrr	t1, CSR_SCOUNTOVF	//	read from M -> all OF bits visible
	srli	t2, t1, 3
	andi	t2, t2, 1
	bnez	t2, a1_ok
	ori	s1, s1, 1
a1_ok:
	li	t0, 1
	slli	t0, t0, 63
	csrw	CSR_MHPMEVENT4, t0
	csrr	t1, CSR_SCOUNTOVF
	li	t2, (1 << 3) | (1 << 4)
	and	t3, t1, t2
	beq	t3, t2, a2_ok
	ori	s1, s1, 1
a2_ok:
	csrw	CSR_MHPMEVENT3, x0	//	clear OF
	csrw	CSR_MHPMEVENT4, x0
	csrr	t1, CSR_SCOUNTOVF
	beqz	t1, a3_ok
	ori	s1, s1, 1
a3_ok:

#ifdef SSCOFPMF_FULL
	//	karu64-only WARL: mhpmevent writable bits = OF|MINH|SINH|UINH|evt[4:0].
	li	t0, -1
	csrw	CSR_MHPMEVENT3, t0
	csrr	t1, CSR_MHPMEVENT3
	li	t2, 0xF000000000000000
	ori	t2, t2, 0x1F		//	0xF000_0000_0000_001F
	beq	t1, t2, warl_ok
	ori	s1, s1, 8
warl_ok:
	csrw	CSR_MHPMEVENT3, x0
#endif

	//	=== B: LCOFI delivered to M ===
	csrw	CSR_MIDELEG, x0		//	not delegated -> M
	li	t0, 1
	slli	t0, t0, 13		//	bit 13 (LCOFIE)
	csrw	CSR_MIE, t0
	csrr	t0, mstatus
	ori	t0, t0, (1 << 3)	//	MIE
	csrw	mstatus, t0
	li	s3, 0
	li	t0, 1
	slli	t0, t0, 13
	csrw	CSR_MIP, t0		//	set LCOFIP -> interrupt taken at the next insn
	nop
	li	t4, 13
	beq	s3, t4, test_c
	ori	s1, s1, 2

test_c:
	//	=== C: LCOFI delegated to S -> scause 13 ===
	li	t0, 1
	slli	t0, t0, 13
	csrw	CSR_MIDELEG, t0		//	delegate bit 13 -> S
	csrw	CSR_MIE, t0
	la	t0, s_handler
	csrw	CSR_STVEC, t0
	li	s3, 0
	la	s4, c_check		//	M return address
	li	t0, 1
	slli	t0, t0, 13
	csrw	CSR_MIP, t0		//	mip[13]=1 (delegated; pending for S)
	j	enter_s
c_check:
	li	t4, 13
	beq	s3, t4, test_d
	ori	s1, s1, 4

test_d:
	//	=== D: STIP + LCOFI both pending in S -> STIP (5) wins (LCOFI lowest) ===
	li	t0, (1 << 5) | (1 << 13)
	csrw	CSR_MIDELEG, t0		//	delegate STIP + LCOFI -> S
	csrw	CSR_MIE, t0		//	enable both
	li	s3, 0
	la	s4, d_check
	li	t0, (1 << 5) | (1 << 13)
	csrw	CSR_MIP, t0		//	both pending
	j	enter_s
d_check:
	li	t4, 5			//	STIP must be taken first, not LCOFI(13)
	beq	s3, t4, test_e
	ori	s1, s1, 16

test_e:
	//	=== E: M-destined LCOFI + S-destined STIP pending in S -> M wins (cause 13) ===
	//	delegate STIP to S but leave LCOFI(13) NON-delegated (M-destined). In S both
	//	are takeable; M delivery outranks S, so the trap goes to M with cause 13.
	li	t0, (1 << 5)
	csrw	CSR_MIDELEG, t0		//	STIP -> S; LCOFI stays M-destined
	li	t0, (1 << 5) | (1 << 13)
	csrw	CSR_MIE, t0		//	enable STIP + LCOFI
	li	s3, 0
	la	s4, e_check
	li	t0, (1 << 5) | (1 << 13)
	csrw	CSR_MIP, t0		//	both pending
	j	enter_s			//	drop to S; M-destined LCOFI preempts -> trap to M
e_check:
	li	t4, 13			//	M-destined LCOFI (13) taken to M, not S-destined STIP(5)
	beq	s3, t4, done
	ori	s1, s1, 32
	j	done

	//	enter S at s_entry with SIE=1; s4 holds where M should resume afterward.
enter_s:
	csrr	t0, mstatus
	li	t1, (3 << 11)
	not	t1, t1
	and	t0, t0, t1		//	clear MPP
	li	t1, (1 << 11)
	or	t0, t0, t1		//	MPP = S
	ori	t0, t0, (1 << 1)	//	SIE = 1
	csrw	mstatus, t0
	la	t0, s_entry
	csrw	mepc, t0
	mret

s_entry:
	//	the delegated interrupt fires on entry; after it is handled, ecall back to M.
	ecall

	.align 2
m_handler:
	csrr	t6, mcause
	bltz	t6, m_int		//	bit 63 set -> interrupt
	li	t5, 9			//	ecall from S (S-phase return)
	beq	t6, t5, m_ecall_s
	li	t0, (9 << 1) | 1	//	unexpected exception
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
m_int:
	andi	s3, t6, 63		//	record taken interrupt cause
	csrw	CSR_MIP, x0		//	clear SW-pending M interrupts
	mret
m_ecall_s:
	csrw	CSR_MIP, x0		//	clear the (still-pending) SW interrupts from M
	csrw	mepc, s4		//	resume M where the phase asked
	csrr	t1, mstatus
	li	t2, (3 << 11)
	or	t1, t1, t2		//	MPP = M (return to M, not S)
	csrw	mstatus, t1
	mret

	.align 2
s_handler:
	csrr	t6, scause
	bltz	t6, s_int
	li	t0, (6 << 1) | 1	//	unexpected S exception
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
s_int:
	andi	s3, t6, 63		//	record taken interrupt cause
	//	The source is still pending (STIP is not S-clearable via sip, and sret would
	//	restore SIE from SPIE), so disable the delegated S enables; M clears mip at the
	//	ecall boundary and the next phase re-enables via mie.
	csrw	CSR_SIE, x0		//	clear delegated mie bits (5,13)
	sret

done:
	bnez	s1, fail
	li	t0, 1			//	(0<<1)|1 -> exit 0 (pass)
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
fail:
	slli	t0, s1, 1
	ori	t0, t0, 1
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	.section .htif,"aw",@progbits
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
