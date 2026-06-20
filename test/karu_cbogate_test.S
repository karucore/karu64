//	karu_cbogate_test.S
//	Directed test for Zicbom/Zicboz privilege+envcfg gating: a CBO whose class
//	is not enabled (menvcfg in S; menvcfg AND senvcfg in U) raises an
//	illegal-instruction exception. Runs on htif_tb AND spike (same ELF).
//	exit 0 = pass; non-zero = first mismatch step.

	.equ	TOHOST,	0x80001000
	.equ	BUF,	0x80002000	//	64-byte-aligned scratch for cbo.zero

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	//	menvcfg: CBZE=1(b7), CBCFE=0(b6), CBIE=01(b5:4)  -> S: zero ok, clean trap, inval ok
	li	t0, (1 << 7) | (1 << 4)
	csrw	0x30a, t0
	//	senvcfg: CBZE=0, CBCFE=1(b6), CBIE=01(b5:4)      -> U adds: zero trap, inval ok
	li	t0, (1 << 6) | (1 << 4)
	csrw	0x10a, t0
	li	s10, 0				//	error accumulator
	li	a0, BUF

	//	enter S
	la	t0, s_part
	csrw	mepc, t0
	csrr	t0, mstatus
	li	t1, (3 << 11)
	not	t1, t1
	and	t0, t0, t1
	li	t1, (1 << 11)
	or	t0, t0, t1
	csrw	mstatus, t0
	mret

	//	per-test: clear s11, run cbo, accumulate (s11 != expected) into s10
s_part:
	//	S-mode: gated by menvcfg only (CBZE=1, CBCFE=0, CBIE=01)
	li	s11, 0
	cbo.zero (a0)			//	expect NO trap
	or	s10, s10, s11
	li	s11, 0
	cbo.clean (a0)			//	expect trap
	xori	t0, s11, 1
	or	s10, s10, t0
	li	s11, 0
	cbo.inval (a0)			//	expect NO trap
	or	s10, s10, s11
	//	drop to U
	la	t0, u_part
	csrw	sepc, t0
	csrr	t0, sstatus
	li	t1, (1 << 8)
	not	t1, t1
	and	t0, t0, t1
	csrw	sstatus, t0
	sret

u_part:
	//	U-mode: gated by menvcfg AND senvcfg
	li	s11, 0
	cbo.zero (a0)			//	expect trap (senvcfg.CBZE=0)
	xori	t0, s11, 1
	or	s10, s10, t0
	li	s11, 0
	cbo.clean (a0)			//	expect trap (menvcfg.CBCFE=0)
	xori	t0, s11, 1
	or	s10, s10, t0
	li	s11, 0
	cbo.inval (a0)			//	expect NO trap (both CBIE!=0)
	or	s10, s10, s11
	//	report
	bne	s10, x0, fail
	li	t0, 1				//	pass -> exit 0
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
fail:
	li	t0, (1 << 1) | 1
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	.align 2
m_handler:
	csrr	t6, mcause
	li	t5, 2
	bne	t6, t5, m_unexpected
	li	s11, 1				//	record illegal-instruction trap
	csrr	t4, mepc
	addi	t4, t4, 4
	csrw	mepc, t4
	mret
m_unexpected:
	li	t0, (9 << 1) | 1		//	exit 9 = unexpected cause
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	.section .htif,"aw",@progbits
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
