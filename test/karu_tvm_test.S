//	karu_tvm_test.S
//	Directed test for the mstatus trap-virtualization bits in S-mode:
//	  TVM -> sfence.vma and satp access trap
//	  TW  -> wfi traps (below M)
//	  TSR -> sret traps
//	Each must raise illegal-instruction (cause 2). The negative case (bits clear
//	-> no trap) is already exercised by karu_mmu_test. Runs on htif_tb AND spike.
//	exit 0 = pass.

	.equ	TOHOST,	0x80001000

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	li	s10, 0				//	error accumulator
	//	set mstatus.TVM(20) | TW(21) | TSR(22), MPP=S
	csrr	t0, mstatus
	li	t1, (1 << 20) | (1 << 21) | (1 << 22)
	or	t0, t0, t1
	li	t1, (3 << 11)
	not	t1, t1
	and	t0, t0, t1
	li	t1, (1 << 11)			//	MPP = S
	or	t0, t0, t1
	csrw	mstatus, t0
	la	t0, s_test
	csrw	mepc, t0
	mret

s_test:
	//	each: clear s11, run the privileged op, expect a trap (s11 -> 1)
	li	s11, 0
	sfence.vma				//	TVM -> trap
	xori	t0, s11, 1
	or	s10, s10, t0
	li	s11, 0
	csrr	t0, satp			//	TVM -> trap (satp access)
	xori	t0, s11, 1
	or	s10, s10, t0
	li	s11, 0
	wfi					//	TW -> trap
	xori	t0, s11, 1
	or	s10, s10, t0
	li	s11, 0
	sret					//	TSR -> trap (handler skips it, stays in S)
	xori	t0, s11, 1
	or	s10, s10, t0

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
	li	s11, 1
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
