//	karu_smcntrpmf_test.S
//	Directed test for Smcntrpmf (built with KARU_SMCNTRPMF).
//	  minstretcfg/mcyclecfg[62]=MINH inhibit counting in M
//	                       [61]=SINH inhibit in S
//	                       [60]=UINH inhibit in U
//	Each phase sets the cfg in M, drops to a target privilege, and a measure routine
//	reads the counter, runs a fixed instruction block, reads again, and ecalls back
//	with the delta in s2. M then checks the delta against the expectation s3
//	(0 = expect frozen / delta==0, 1 = expect advancing / delta>0).
//
//	instret is architectural, so the instret phases (0..5) cross-check on spike
//	(which supports smcntrpmf). The mcycle phases and the exact WARL-mask check are
//	microarchitecture/implementation-specific -> built only with -DSMCNTRPMF_FULL
//	and validated on karu64 alone. Phase 5 is the user-only case: M+S inhibited,
//	UINH clear, so U-mode instret still advances. exit 0 = pass.

	.equ	TOHOST,			0x80001000
	.equ	CSR_MCYCLECFG,	0x321
	.equ	CSR_MINSTRETCFG,0x322

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	li	s1, 0				//	error accumulator
	li	s0, 0				//	phase index
	li	t0, 4				//	IR (counter idx 2) readable from S and U
	csrw	mcounteren, t0
#ifndef SMCNTRPMF_NOS
	csrw	scounteren, t0		//	S-mode CSR -- absent (and unused) in the NO_S check
#endif

#ifdef SMCNTRPMF_NOS
	//	KARU_NO_S build: SINH(61) gates an unimplemented mode -> read-only 0, so the
	//	writable mask is MINH(62)|UINH(60) = 0x5000.... (M-only check; no S/U phases.)
	li	t2, 5
	slli	t2, t2, 60			//	0x5000_0000_0000_0000
	li	t0, -1
	csrw	CSR_MINSTRETCFG, t0
	csrr	t1, CSR_MINSTRETCFG
	bne	t1, t2, nos_fail
	li	t0, -1
	csrw	CSR_MCYCLECFG, t0
	csrr	t1, CSR_MCYCLECFG
	bne	t1, t2, nos_fail
	li	t0, 1				//	pass (exit 0)
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
nos_fail:
	li	t0, (3 << 1) | 1
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
#endif

#ifdef SMCNTRPMF_FULL
	//	karu64-only WARL: only MINH(62)|SINH(61)|UINH(60) are writable here.
	li	t2, 7
	slli	t2, t2, 60			//	0x7000_0000_0000_0000
	li	t0, -1
	csrw	CSR_MINSTRETCFG, t0
	csrr	t1, CSR_MINSTRETCFG
	beq	t1, t2, warl_ir_ok
	ori	s1, s1, 2
warl_ir_ok:
	li	t0, -1
	csrw	CSR_MCYCLECFG, t0
	csrr	t1, CSR_MCYCLECFG
	beq	t1, t2, warl_cy_ok
	ori	s1, s1, 4
warl_cy_ok:
	csrw	CSR_MINSTRETCFG, x0
	csrw	CSR_MCYCLECFG, x0
#endif

m_phase:
	beqz	s0, ph0
	li	t3, 1
	beq	s0, t3, ph1
	li	t3, 2
	beq	s0, t3, ph2
	li	t3, 3
	beq	s0, t3, ph3
	li	t3, 4
	beq	s0, t3, ph4
	li	t3, 5
	beq	s0, t3, ph5
#ifdef SMCNTRPMF_FULL
	li	t3, 6
	beq	s0, t3, ph6
	li	t3, 7
	beq	s0, t3, ph7
#endif
	j	done

	//	s3 = expected (0 = frozen/delta==0, 1 = advancing/delta>0)
	//	t1 = target privilege for MPP (0=U, 1=S, 3=M); t0 = measure routine
ph0:	//	M, MINH -> instret frozen
	li	t2, 1
	slli	t2, t2, 62
	csrw	CSR_MINSTRETCFG, t2
	li	s3, 0
	li	t1, 3
	la	t0, s_meas_ir
	j	enter
ph1:	//	M, no inhibit -> instret advances
	csrw	CSR_MINSTRETCFG, x0
	li	s3, 1
	li	t1, 3
	la	t0, s_meas_ir
	j	enter
ph2:	//	S, SINH -> instret frozen
	li	t2, 1
	slli	t2, t2, 61
	csrw	CSR_MINSTRETCFG, t2
	li	s3, 0
	li	t1, 1
	la	t0, s_meas_ir
	j	enter
ph3:	//	S, no inhibit -> instret advances
	csrw	CSR_MINSTRETCFG, x0
	li	s3, 1
	li	t1, 1
	la	t0, s_meas_ir
	j	enter
ph4:	//	U, UINH -> instret frozen
	li	t2, 1
	slli	t2, t2, 60
	csrw	CSR_MINSTRETCFG, t2
	li	s3, 0
	li	t1, 0
	la	t0, s_meas_ir
	j	enter
ph5:	//	U, MINH|SINH set but UINH clear -> U instret still advances (user-only)
	li	t2, 3
	slli	t2, t2, 61			//	MINH(62)|SINH(61)
	csrw	CSR_MINSTRETCFG, t2
	li	s3, 1
	li	t1, 0
	la	t0, s_meas_ir
	j	enter
#ifdef SMCNTRPMF_FULL
ph6:	//	M, mcyclecfg MINH -> mcycle frozen
	li	t2, 1
	slli	t2, t2, 62
	csrw	CSR_MCYCLECFG, t2
	li	s3, 0
	li	t1, 3
	la	t0, s_meas_cy
	j	enter
ph7:	//	M, mcyclecfg clear -> mcycle advances
	csrw	CSR_MCYCLECFG, x0
	li	s3, 1
	li	t1, 3
	la	t0, s_meas_cy
	j	enter
#endif

enter:	//	t0 = entry PC, t1 = target privilege (0/1/3) for MPP
	csrw	mepc, t0
	csrr	t2, mstatus
	li	t3, (3 << 11)
	not	t3, t3
	and	t2, t2, t3			//	clear MPP
	slli	t1, t1, 11
	or	t2, t2, t1			//	MPP = target
	csrw	mstatus, t2
	mret

	//	measure routines: read counter, fixed 8-insn block, read again, delta -> s2.
s_meas_ir:
	rdinstret t0
	.rept 8
	nop
	.endr
	rdinstret t1
	sub	s2, t1, t0
	ecall
s_meas_cy:
	rdcycle	t0
	.rept 8
	nop
	.endr
	rdcycle	t1
	sub	s2, t1, t0
	ecall

	.align 2
m_handler:
	csrr	t6, mcause
	li	t5, 11				//	ecall from M
	beq	t6, t5, h_ecall
	li	t5, 9				//	ecall from S
	beq	t6, t5, h_ecall
	li	t5, 8				//	ecall from U
	beq	t6, t5, h_ecall
	li	t0, (9 << 1) | 1	//	unexpected cause (e.g. counteren trap) -> exit 9
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
h_ecall:
	bnez	s3, exp_nonzero
	beqz	s2, ph_ok			//	expected frozen: delta must be 0
	ori	s1, s1, 1
	j	ph_ok
exp_nonzero:
	bnez	s2, ph_ok			//	expected advancing: delta must be > 0
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
