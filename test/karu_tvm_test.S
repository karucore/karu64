//	karu_tvm_test.S
//	Directed Svinval and mstatus trap-virtualization test:
//	  TVM -> sfence.vma and satp access trap
//	  TW  -> S-mode WFI traps; U-mode WFI traps with either TW value
//	  TSR -> sret traps
//	SINVAL.VMA follows the SFENCE.VMA privilege rules. The ordering-only
//	SFENCE.W.INVAL / SFENCE.INVAL.IR are legal in S even with TVM=1. Check M,
//	S (both TVM values), U, reserved operand fields, absent-H HINVAL encodings,
//	illegal-instruction mtval/mepc, and unchanged operand/destination canaries.
//	A pending, locally enabled STIP makes the legal S-mode WFI deterministic
//	without enabling interrupt delivery or relying on a simulator treating it
//	as a NOP.
//	PTE-store ordering and actual SINVAL invalidation are in karu_mmu_test.
//	Runs on htif_tb AND Spike with Svinval enabled and H disabled.
//	exit 0 = pass.

	.equ	TOHOST,	0x80001000

	//	Raw words keep reserved fields explicit. s8 says whether cause 2 is
	//	expected; s9/s6 identify the exact faulting word/PC for the handler.
	.macro	probe word, illegal
	li	s8, \illegal
	li	s9, \word
	la	s6, .Lprobe\@
	li	s11, 0
.Lprobe\@:
	.word	\word
	xori	t0, s11, \illegal
	or	s10, s10, t0
	.endm

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	li	s10, 0				//	error accumulator
	li	a0, 0x12345000			//	VA operand canary (not dereferenced)
	li	a1, 0x1234			//	ASID operand canary
	li	t2, 0x5678			//	illegal-rd canary
	li	t0, -1
	csrw	pmpaddr0, t0
	li	t0, 0x1f			//	all-memory RWX NAPOT for the reference
	csrw	pmpcfg0, t0
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

	//	M is unaffected by TVM. Full flushes may ignore both operand values.
	probe	0x18000073, 0			//	sfence.w.inval
	probe	0x16000073, 0			//	sinval.vma x0,x0
	probe	0x16b50073, 0			//	sinval.vma a0,a1
	probe	0x16050073, 0			//	sinval.vma a0,x0
	probe	0x16b00073, 0			//	sinval.vma x0,a1
	probe	0x18100073, 0			//	sfence.inval.ir
	probe	0x12b50073, 0			//	sfence.vma a0,a1

	//	Only SINVAL's rs1/rs2 vary. The ordering fences have fixed fields.
	probe	0x160003f3, 1			//	sinval: reserved rd=t2
	probe	0x120003f3, 1			//	sfence.vma: reserved rd=t2
	probe	0x180003f3, 1			//	w.inval: reserved rd=t2
	probe	0x181003f3, 1			//	inval.ir: reserved rd=t2
	probe	0x18008073, 1			//	w.inval: reserved rs1=x1
	probe	0x18108073, 1			//	inval.ir: reserved rs1=x1
	probe	0x18200073, 1			//	reserved ordering selector
	probe	0x26000073, 1			//	hinval.vvma requires H
	probe	0x66000073, 1			//	hinval.gvma requires H

	//	Each M-mode trap/return clears MPP, so select S again after the probes.
	csrr	t0, mstatus
	li	t1, (3 << 11)
	not	t1, t1
	and	t0, t0, t1
	li	t1, (1 << 11)
	or	t0, t0, t1
	csrw	mstatus, t0
	la	t0, s_test
	csrw	mepc, t0
	mret

s_test:
	probe	0x12000073, 1			//	TVM -> sfence.vma trap
	probe	0x180022f3, 1			//	TVM -> csrr t0,satp trap
	probe	0x10500073, 1			//	TW -> wfi trap
	probe	0x10200073, 1			//	TSR -> sret trap
	probe	0x16000073, 1			//	TVM -> sinval.vma trap
	probe	0x16b50073, 1			//	TVM -> targeted sinval.vma trap
	probe	0x18000073, 0			//	ordering fences ignore TVM
	probe	0x18100073, 0
	li	s7, 1
	ecall					//	M handler clears TVM/TW/TSR

s_clear:
	probe	0x10500073, 0			//	TW=0: S-mode WFI is legal
	probe	0x18000073, 0
	probe	0x16000073, 0
	probe	0x16b50073, 0
	probe	0x16050073, 0
	probe	0x16b00073, 0
	probe	0x18100073, 0
	probe	0x12b50073, 0
	li	s7, 2
	ecall					//	M handler enters U in Bare mode

u_test:
	probe	0x10500073, 1			//	U-mode WFI is illegal even with TW=0
	probe	0x12000073, 1
	probe	0x16000073, 1
	probe	0x16b50073, 1
	probe	0x18000073, 1
	probe	0x18100073, 1
	li	s7, 3
	ecall					//	M handler sets TW and re-enters U

u_tw_set:
	probe	0x10500073, 1			//	U-mode WFI is also illegal with TW=1
	li	s7, 4
	ecall					//	M handler finishes the test

finish:
	li	t0, 0x12345000
	xor	t0, t0, a0
	or	s10, s10, t0
	li	t0, 0x1234
	xor	t0, t0, a1
	or	s10, s10, t0
	li	t0, 0x5678
	xor	t0, t0, t2
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
	li	t5, 9
	beq	t6, t5, m_s_ecall
	li	t5, 8
	beq	t6, t5, m_u_ecall
	li	t5, 2
	bne	t6, t5, m_unexpected
	xori	t5, s8, 1			//	no unexpected trap at a legal probe
	or	s10, s10, t5
	csrr	t4, mtval
	xor	t4, t4, s9
	or	s10, s10, t4
	csrr	t4, mepc
	xor	t5, t4, s6
	or	s10, s10, t5
	li	s11, 1
	addi	t4, t4, 4
	csrw	mepc, t4
	mret
m_s_ecall:
	// Remove the pending wakeup before entering U, where a delegated S
	// interrupt would otherwise become globally enabled by privilege alone.
	li	t5, (1 << 5)
	csrc	mie, t5
	csrc	mip, t5
	csrc	mideleg, t5
	csrr	t4, mstatus
	li	t5, (1 << 20) | (1 << 21) | (1 << 22) | (3 << 11) | (1 << 1)
	not	t5, t5
	and	t4, t4, t5
	li	t5, 1
	beq	s7, t5, m_enter_s_clear
	li	t5, 2
	bne	s7, t5, m_unexpected
	la	t5, u_test
	j	m_enter
m_enter_s_clear:
	// WFI must resume for a locally enabled pending interrupt even with
	// global SIE clear. Delegation prevents an M interrupt pre-empting S.
	li	t5, (1 << 5)
	csrs	mideleg, t5
	csrs	mie, t5
	csrs	mip, t5
	li	t5, (1 << 11)
	or	t4, t4, t5
	la	t5, s_clear
m_enter:
	csrw	mstatus, t4
	csrw	mepc, t5
	mret
m_u_ecall:
	li	t5, 4
	beq	s7, t5, finish
	li	t5, 3
	bne	s7, t5, m_unexpected
	csrr	t4, mstatus
	li	t5, (3 << 11)
	not	t5, t5
	and	t4, t4, t5			//	return to U, not the trap handler's M
	li	t5, (1 << 21)
	or	t4, t4, t5
	la	t5, u_tw_set
	j	m_enter
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
