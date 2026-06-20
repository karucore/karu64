//	karu_stateen_test.S
//	Directed test for Smstateen / Ssstateen (built with KARU_EN_SSTATEEN).
//	  mstateen0[62] = ENVCFG  gates S-mode access to senvcfg (0x10A)
//	  mstateen0[63] = SE0     gates S-mode access to sstateen0 (0x10C)
//	With the gate bit set the S-mode access succeeds; cleared, it raises an
//	illegal-instruction trap (cause 2). Each phase sets up the gate in M, drops to
//	S, performs the access, and ecalls back to M, which checks trap-vs-no-trap.
//	Each phase sets s3 = expected result: 0 = expect access OK, 1 = expect cause-2 trap.
//
//	The default build covers only the senvcfg / Smstateen path (phases 0,1), so it
//	cross-checks against spike (which supports smstateen but NOT ssstateen). The
//	sstateen0 / Ssstateen phases (2,3) and the exact mstateen0 WARL-mask check are
//	built only with -DSTATEEN_FULL and validated on karu64 alone (the WARL mask is
//	implementation-specific; spike implements more mstateen0 bits). exit 0 = pass.

	.equ	TOHOST,			0x80001000
	.equ	CSR_SENVCFG,	0x10A
	.equ	CSR_SSTATEEN0,	0x10C
	.equ	CSR_MSTATEEN0,	0x30C

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	li	s1, 0				//	error accumulator
	li	s0, 0				//	phase index

	//	Reset value (cross-checked): mstateen0 must read 0 -- the Smstateen spec
	//	requires writable bits to reset to 0 (deny). spike resets it to 0 too.
	csrr	t0, CSR_MSTATEEN0
	beqz	t0, rst_ok
	ori	s1, s1, 2			//	mstateen0 reset != 0
rst_ok:

#ifdef STATEEN_FULL
	//	karu64-only (bundled spike lacks ssstateen and implements a different
	//	mstateen0 writable-bit set):
	//	(a) mstateen0 WARL -- only SE0(63)+ENVCFG(62) are writable here.
	li	t0, -1
	csrw	CSR_MSTATEEN0, t0
	csrr	t1, CSR_MSTATEEN0
	li	t2, 3
	slli	t2, t2, 62			//	0xC000_0000_0000_0000
	beq	t1, t2, warl_ok
	ori	s1, s1, 4			//	WARL mask wrong
warl_ok:
	//	(b) sstateen0 exists but reads 0 and ignores writes (no implemented bits).
	li	t0, -1
	csrw	CSR_SSTATEEN0, t0
	csrr	t1, CSR_SSTATEEN0
	beqz	t1, sst0_ok
	ori	s1, s1, 8			//	sstateen0 not read-0
sst0_ok:
	//	(c) mstateen1..3 / sstateen1..3 exist (no trap) and read 0.
	csrr	t1, 0x30D
	csrr	t2, 0x30E
	or	t1, t1, t2
	csrr	t2, 0x30F
	or	t1, t1, t2
	csrr	t2, 0x10D
	or	t1, t1, t2
	csrr	t2, 0x10E
	or	t1, t1, t2
	csrr	t2, 0x10F
	or	t1, t1, t2
	beqz	t1, ext_ok
	ori	s1, s1, 16			//	mstateen1..3/sstateen1..3 not read-0
ext_ok:
#endif

m_phase:
	li	s2, 0				//	trapped-flag for this phase
	beqz	s0, ph0
	li	t3, 1
	beq	s0, t3, ph1
#ifdef STATEEN_FULL
	li	t3, 2
	beq	s0, t3, ph2
	li	t3, 3
	beq	s0, t3, ph3
	li	t3, 4
	beq	s0, t3, ph4
	li	t3, 5
	beq	s0, t3, ph5
	li	t3, 6
	beq	s0, t3, ph6
#endif
	j	done

	//	s3 = expected trap (0 = access OK, 1 = expect cause-2 trap) for the phase.
ph0:	//	ENVCFG set -> senvcfg OK
	li	t0, 3
	slli	t0, t0, 62
	csrw	CSR_MSTATEEN0, t0
	li	s3, 0
	la	t0, s_senvcfg
	j	enter_s
ph1:	//	ENVCFG clear -> senvcfg traps
	li	t0, 1
	slli	t0, t0, 63
	csrw	CSR_MSTATEEN0, t0
	li	s3, 1
	la	t0, s_senvcfg
	j	enter_s
#ifdef STATEEN_FULL
ph2:	//	SE0 set -> sstateen0 OK
	li	t0, 3
	slli	t0, t0, 62
	csrw	CSR_MSTATEEN0, t0
	li	s3, 0
	la	t0, s_sstateen0
	j	enter_s
ph3:	//	SE0 clear -> sstateen0 traps
	li	t0, 1
	slli	t0, t0, 62
	csrw	CSR_MSTATEEN0, t0
	li	s3, 1
	la	t0, s_sstateen0
	j	enter_s
	//	sstateen1..3 gate on mstateen1..3[63] (hardwired 0 here), so they trap from S
	//	even with mstateen0[63]=SE0 SET -- this catches a wrong whole-range gate.
ph4:	//	SE0 set, sstateen1 still traps
	li	t0, 3
	slli	t0, t0, 62
	csrw	CSR_MSTATEEN0, t0
	li	s3, 1
	la	t0, s_sstateen1
	j	enter_s
ph5:	//	SE0 set, sstateen2 still traps
	li	t0, 3
	slli	t0, t0, 62
	csrw	CSR_MSTATEEN0, t0
	li	s3, 1
	la	t0, s_sstateen2
	j	enter_s
ph6:	//	SE0 set, sstateen3 still traps
	li	t0, 3
	slli	t0, t0, 62
	csrw	CSR_MSTATEEN0, t0
	li	s3, 1
	la	t0, s_sstateen3
	j	enter_s
#endif

enter_s:
	csrw	mepc, t0
	csrr	t1, mstatus			//	MPP = S (mstatus[12:11] = 01)
	li	t2, (3 << 11)
	not	t2, t2
	and	t1, t1, t2
	li	t2, (1 << 11)
	or	t1, t1, t2
	csrw	mstatus, t1
	mret

	//	S-mode access routines: perform the gated read, then ecall back to M.
s_senvcfg:
	csrr	t0, CSR_SENVCFG
	ecall
s_sstateen0:
	csrr	t0, CSR_SSTATEEN0
	ecall
#ifdef STATEEN_FULL
s_sstateen1:
	csrr	t0, 0x10D
	ecall
s_sstateen2:
	csrr	t0, 0x10E
	ecall
s_sstateen3:
	csrr	t0, 0x10F
	ecall
#endif

	.align 2
m_handler:
	csrr	t6, mcause
	li	t5, 2
	beq	t6, t5, h_ill
	li	t5, 9				//	ecall from S = phase boundary
	beq	t6, t5, h_ecall
	li	t0, (9 << 1) | 1	//	unexpected cause -> exit 9
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
h_ill:
	li	s2, 1				//	the gated access trapped
	csrr	t4, mepc
	addi	t4, t4, 4
	csrw	mepc, t4
	mret					//	resume S, fall through to the ecall
h_ecall:
	beq	s2, s3, ph_ok		//	compare to this phase's expected trap (s3)
	ori	s1, s1, 1
ph_ok:
	addi	s0, s0, 1
	j	m_phase				//	still in M: set up + mret to next phase

done:
	bnez	s1, fail
	li	t0, 1				//	(0<<1)|1 -> exit 0 (pass)
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
fail:
	slli	t0, s1, 1			//	exit code = error accumulator (nonzero)
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
