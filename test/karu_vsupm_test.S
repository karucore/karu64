//	karu_vsupm_test.S
//	Directed test for Supm pointer masking of VECTOR memory accesses (Smnpm in
//	S-mode). A vector load/store through a tagged base pointer must access the
//	untagged buffer (the VLSU base is pointer-masked). Runs on htif_tb AND spike.
//	exit 0 = pass.

	.equ	TOHOST,	0x80001000
	.equ	BUF,	0x80003000	//	source sentinels
	.equ	OUT,	0x80003100	//	dest for the tagged-load test
	.equ	OUT2,	0x80003200	//	dest for the tagged-store test

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	//	enable mstatus.FS(13)|VS(9) = Dirty so vector ops don't trap
	csrr	t0, mstatus
	li	t1, (3 << 13) | (3 << 9)
	or	t0, t0, t1
	//	menvcfg.PMM = 11 (PMLEN16, Smnpm -> S-mode)
	li	t1, (3 << 32)
	csrw	0x30a, t1
	//	MPP = S
	li	t1, (3 << 11)
	not	t1, t1
	and	t0, t0, t1
	li	t1, (1 << 11)
	or	t0, t0, t1
	csrw	mstatus, t0

	//	fill BUF with 4 sentinel doublewords (M-mode, unmasked)
	li	t0, BUF
	li	t1, 0x1111111100000001
	sd	t1, 0(t0)
	li	t1, 0x2222222200000002
	sd	t1, 8(t0)
	li	t1, 0x3333333300000003
	sd	t1, 16(t0)
	li	t1, 0x4444444400000004
	sd	t1, 24(t0)

	la	t0, s_test
	csrw	mepc, t0
	mret

s_test:
	li	s10, 0				//	error accumulator
	vsetivli t0, 4, e64, m1, ta, ma

	//	---- tagged LOAD: vle64 from (BUF | tag<<48) must read BUF ----
	li	a0, BUF
	li	t1, 0xABCD
	slli	t1, t1, 48
	or	a1, a0, t1			//	tagged base
	vle64.v	v8, (a1)			//	masks to BUF
	li	a2, OUT
	vse64.v	v8, (a2)			//	untagged store
	//	compare BUF vs OUT (4 dwords)
	li	t2, 4
	li	a3, BUF
	li	a4, OUT
1:	ld	t3, 0(a3)
	ld	t4, 0(a4)
	bne	t3, t4, fail
	addi	a3, a3, 8
	addi	a4, a4, 8
	addi	t2, t2, -1
	bnez	t2, 1b

	//	---- tagged STORE: vse64 to (OUT2 | tag<<48) must write OUT2 ----
	vle64.v	v8, (a0)			//	untagged load of BUF
	li	a5, OUT2
	li	t1, 0x5555
	slli	t1, t1, 48
	or	a6, a5, t1			//	tagged dest
	vse64.v	v8, (a6)			//	masks to OUT2
	li	t2, 4
	li	a3, BUF
	li	a4, OUT2
2:	ld	t3, 0(a3)
	ld	t4, 0(a4)
	bne	t3, t4, fail
	addi	a3, a3, 8
	addi	a4, a4, 8
	addi	t2, t2, -1
	bnez	t2, 2b

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
	li	t0, (9 << 1) | 1		//	any trap here is unexpected
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	.section .htif,"aw",@progbits
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
