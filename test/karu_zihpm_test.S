//	karu_zihpm_test.S
//	Directed test for Zihpm/Zicntr counter-enable gating. The user counter
//	shadows (cycle/time/instret/hpmcounter*) must trap an illegal-instruction
//	exception in S unless mcounteren[idx], and in U unless BOTH mcounteren[idx]
//	and scounteren[idx]. Runs on htif_tb AND spike (same ELF, spike golden).
//	exit 0 = pass; a non-zero code localises the first wrong behaviour.

	.equ	TOHOST,	0x80001000

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0			//	no delegation -> all traps to M

	//	mcounteren = CY|IR (bits 0,2): cycle/instret allowed below M;
	//	             time(1)/hpmcounter3(3) blocked.
	li	t0, (1 << 0) | (1 << 2)
	csrw	mcounteren, t0
	//	scounteren = CY only (bit 0): U may read cycle, but not instret.
	li	t0, (1 << 0)
	csrw	scounteren, t0

	//	enter S-mode
	la	t0, s_test
	csrw	mepc, t0
	csrr	t0, mstatus
	li	t1, (3 << 11)
	not	t1, t1
	and	t0, t0, t1
	li	t1, (1 << 11)			//	MPP = S
	or	t0, t0, t1
	csrw	mstatus, t0
	mret

s_test:
	//	mcounteren = 0b0101 -> in S: cycle ok, time traps, instret ok, hpm3 traps.
	li	s11, 0
	csrr	t0, cycle
	bne	s11, x0, fail_a			//	exit 1: cycle wrongly trapped
	li	s11, 0
	csrr	t0, time
	li	t1, 1
	bne	s11, t1, fail_b			//	exit 2: time should have trapped
	li	s11, 0
	csrr	t0, instret
	bne	s11, x0, fail_c			//	exit 3: instret wrongly trapped
	li	s11, 0
	csrr	t0, hpmcounter3
	li	t1, 1
	bne	s11, t1, fail_d			//	exit 4: hpm3 should have trapped

	//	enter U-mode
	la	t0, u_test
	csrw	sepc, t0
	csrr	t0, sstatus
	li	t1, (1 << 8)
	not	t1, t1
	and	t0, t0, t1			//	SPP = 0 -> U
	csrw	sstatus, t0
	sret

u_test:
	//	U: cycle ok (m&s set); instret traps (m set, s clear); time traps (m clear).
	li	s11, 0
	csrr	t0, cycle
	bne	s11, x0, fail_e			//	exit 5
	li	s11, 0
	csrr	t0, instret
	li	t1, 1
	bne	s11, t1, fail_f			//	exit 6: U instret should trap (scounteren.IR=0)
	li	s11, 0
	csrr	t0, time
	li	t1, 1
	bne	s11, t1, fail_g			//	exit 7

	li	t0, 1				//	pass -> exit 0
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

fail_a: li t0, (1<<1)|1; j write_tohost
fail_b: li t0, (2<<1)|1; j write_tohost
fail_c: li t0, (3<<1)|1; j write_tohost
fail_d: li t0, (4<<1)|1; j write_tohost
fail_e: li t0, (5<<1)|1; j write_tohost
fail_f: li t0, (6<<1)|1; j write_tohost
fail_g: li t0, (7<<1)|1
write_tohost:
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	.align 2
m_handler:
	csrr	t6, mcause
	li	t5, 2				//	illegal-instruction
	bne	t6, t5, m_unexpected
	li	s11, 1				//	record the (expected) counter trap
	csrr	t4, mepc
	addi	t4, t4, 4			//	skip the 4-byte csrr (.option norvc)
	csrw	mepc, t4
	mret
m_unexpected:
	li	t0, (8 << 1) | 1		//	exit 8 = unexpected cause
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	.section .htif,"aw",@progbits
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
