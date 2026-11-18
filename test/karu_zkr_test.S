//	karu_zkr_test.S
//	Directed test of the Zkr entropy source extension (built with KARU_ZKR).
//
//	1. Access rules of seed (0x015), from the "Entropy Source Access Control"
//	   table of the ISA manual (Volume II, mseccfg). A row of the table below
//	   sets mseccfg, enters a mode, executes one CSR instruction and records
//	   whether it trapped:
//	     - a form that does not write is an illegal instruction in every mode;
//	     - M-mode always may; S/HS-mode needs SSEED; U-mode needs USEED;
//	     - VS/VU-mode: virtual instruction (22) when SSEED is set, so that a
//	       hypervisor can emulate the access, and illegal (2) otherwise.
//	   A trapping access must report the instruction in mtval and leave rd.
//	2. The value: OPST in [31:30], entropy in [15:0] only with ES16, every
//	   other bit zero, including the custom bits [23:16].
//	3. Words arrive: M-mode polls until it has eight; S-mode then collects
//	   four within the 100 polls that Linux allows itself.
//	4. The custom M-mode CSRs mnoise (0x7C8, GetNoise) and mentropycfg
//	   (0x7C9), with -DZKR_TEST_CUSTOM: reset value, restart on a write,
//	   test mode, raw symbols with the loss flag, and the lock.
//
//	-DZKR_TEST_H adds the VS/VU rows (core built with KARU_H).
//	-DZKR_TEST_SPIKE keeps what Spike also implements, for a cross-check of
//	the access rules: no custom CSRs and no timing expectation.
//	-DZKR_TEST_STRAP_OFF is for a run with the platform strap low (+zkr_en=0):
//	seed must then stay in BIST, with the same access rules.
//
//	exit 0 = pass; otherwise the exit code is the number of the failing case
//	(table rows count from 1, the later sections from 100).
//	SPDX-License-Identifier: BSD-2-Clause

	.equ	TOHOST,			0x80001000
	.equ	CSR_SEED,		0x015
	.equ	CSR_MSECCFG,	0x747
	.equ	CSR_MNOISE,		0x7C8
	.equ	CSR_MENTROPYCFG, 0x7C9
	.equ	SSEED,			0x200
	.equ	USEED,			0x100
	.equ	M_M,			3
	.equ	M_S,			1
	.equ	M_U,			0
	.equ	M_VS,			5
	.equ	M_VU,			4
	//	reset value of mentropycfg in the test bench: apt 821, rct 41, k = 2
	.equ	CFG_RESET,		(821 << 26) | (41 << 16) | 1

#ifndef ZKR_TEST_H
#define ZKR_TEST_H 0
#endif

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la		t0, m_handler
	csrw	mtvec, t0
	li		t0, -1						//	one PMP entry over everything, for S and U
	csrw	pmpaddr0, t0
	li		t0, 0x1f
	csrw	pmpcfg0, t0
	csrw	medeleg, zero				//	every trap comes to M
	csrw	mideleg, zero
	li		s0, 0
	li		s9, 1
	slli	s9, s9, 31					//	noise_test, for the probes and section 4

	//	mseccfg resets to 0, and of its bits only SSEED and USEED exist here
	li		s0, 90
	csrr	t0, CSR_MSECCFG
	andi	t0, t0, SSEED | USEED
	bnez	t0, fail
#ifdef ZKR_TEST_SPIKE
	li		t0, SSEED | USEED			//	Spike has the Smepmp fields too; all-ones would lock M-mode out
#else
	li		t0, -1
#endif
	csrw	CSR_MSECCFG, t0
	csrr	t1, CSR_MSECCFG
	li		t2, SSEED | USEED
	bne		t1, t2, fail
	csrw	CSR_MSECCFG, zero
	csrr	t1, CSR_MSECCFG
	bnez	t1, fail

	//	---- 1 and 2: the access table ----
	li		s0, 0
	la		s2, table
row:
	ld		a1, 0(s2)					//	mode
	bltz	a1, rows_done
	ld		a2, 8(s2)					//	mseccfg
	ld		s4, 16(s2)					//	the probed instruction
	ld		s3, 24(s2)					//	expected cause, 0 = no trap
	ld		s6, 32(s2)					//	1 = check the seed value format
	addi	s0, s0, 1
	csrw	CSR_MSECCFG, a2
	li		s7, 0
	li		s8, 0
	la		s5, row_back
	li		a0, 0x555
	li		t0, M_M
	beq		a1, t0, row_m
	csrw	mepc, s4
	li		t0, 3 << 11
	csrc	mstatus, t0
	li		t0, 1 << 39					//	MPV; a zero field without H
	csrc	mstatus, t0
	andi	t0, a1, 3
	slli	t0, t0, 11
	csrs	mstatus, t0
	srli	t0, a1, 2
	slli	t0, t0, 39
	csrs	mstatus, t0
	mret
row_m:
	jr		s4
row_back:
	bne		s7, s3, fail				//	trapped or not, and the cause
	beqz	s3, row_value
	lwu		t0, 0(s4)
	bne		s8, t0, fail				//	mtval is the instruction
	li		t0, 0x555
	bne		a0, t0, fail				//	rd is not written by a trapping access
	j		row_next
row_value:
	beqz	s6, row_next
	srli	t0, a0, 32
	bnez	t0, fail					//	[63:32] zero
	slli	t0, a0, 34
	srli	t0, t0, 50
	bnez	t0, fail					//	[29:16] zero: reserved and custom
	srli	t0, a0, 30
	li		t1, 2
	beq		t0, t1, row_next
	slli	t0, a0, 48
	bnez	t0, fail					//	entropy only with ES16
row_next:
	addi	s2, s2, 40
	j		row
rows_done:
	csrw	CSR_MSECCFG, zero

#ifdef ZKR_TEST_STRAP_OFF
	//	---- strap low: seed stays in BIST ----
	li		s0, 100
	li		t4, 5000
1:	csrrw	a0, CSR_SEED, zero
	bnez	a0, fail					//	OPST = BIST and nothing else
	addi	t4, t4, -1
	bnez	t4, 1b
	j		pass
#else
	//	---- 3: M-mode collects eight words ----
	li		s0, 100
	jal		ra, m_collect8
	beqz	a0, fail

#ifndef ZKR_TEST_SPIKE
	//	---- 3: S-mode gets four words within 100 polls, as Linux does ----
	li		s0, 101
	li		t4, 4000					//	let the buffer fill
1:	addi	t4, t4, -1
	bnez	t4, 1b
	li		t0, SSEED
	csrw	CSR_MSECCFG, t0
	li		s7, 0
	la		s5, 2f
	la		t0, s_seed_long
	csrw	mepc, t0
	li		t0, 3 << 11
	csrc	mstatus, t0
	li		t0, 1 << 39
	csrc	mstatus, t0
	li		t0, M_S << 11
	csrs	mstatus, t0
	mret
2:	bnez	s7, fail
	li		t0, 1
	bne		a0, t0, fail
	csrw	CSR_MSECCFG, zero
#endif

#ifdef ZKR_TEST_CUSTOM
	//	---- 4: mentropycfg ----
	li		s0, 110
	csrr	t0, CSR_MENTROPYCFG
	li		t1, CFG_RESET
	bne		t0, t1, fail
	li		s0, 111						//	a write restarts: BIST at once, then words again
	jal		ra, m_collect8				//	make sure a burst is open
	beqz	a0, fail
	li		t4, 4000
1:	addi	t4, t4, -1
	bnez	t4, 1b
	csrr	t0, CSR_MENTROPYCFG			//	a read restarts nothing:
	csrrw	a0, CSR_SEED, zero
	srli	t0, a0, 30
	li		t1, 2
	bne		t0, t1, fail				//	the buffered word is still there
	li		s0, 112
	li		t1, (821 << 26) | (41 << 16) | 0
	csrw	CSR_MENTROPYCFG, t1
	csrrw	a0, CSR_SEED, zero
	bnez	a0, fail					//	BIST, no entropy
	csrr	t0, CSR_MENTROPYCFG
	bne		t0, t1, fail
	jal		ra, m_collect8
	beqz	a0, fail

	//	---- 4: mnoise, the GetNoise interface ----
	li		s0, 120
	csrr	t0, CSR_MNOISE
	li		t1, 1
	bne		t0, t1, fail				//	present, not in test mode
	li		t1, (821 << 26) | (41 << 16) | 255
	csrw	CSR_MENTROPYCFG, t1			//	k = 256: slow enough to read every symbol
	csrrw	a0, CSR_MNOISE, s9			//	enter test mode
	li		t1, 1
	bne		a0, t1, fail				//	the value before the write
	li		s0, 121						//	seed gives nothing in test mode
	li		t4, 8
1:	csrrw	a0, CSR_SEED, zero
	bnez	a0, fail
	addi	t4, t4, -1
	bnez	t4, 1b
	li		s0, 122						//	sixteen consecutive symbols, none lost
	li		t3, 16
	li		t4, 400000
2:	csrrw	a0, CSR_MNOISE, s9			//	status and symbol, taken by this instruction
	srli	t0, a0, 31
	li		t1, 1
	bne		t0, t1, fail				//	[63:32] zero, [31] set
	slli	t0, a0, 35
	srli	t0, t0, 39
	bnez	t0, fail					//	[28:4] zero
	srli	t0, a0, 29
	andi	t0, t0, 1
	bnez	t0, fail					//	loss flag clear
	srli	t0, a0, 30
	andi	t0, t0, 1
	beqz	t0, 3f
	addi	t3, t3, -1
	beqz	t3, 4f
	j		2b
3:	addi	t4, t4, -1
	beqz	t4, fail
	j		2b
4:	li		s0, 126						//	a plain read observes a symbol and leaves it
	li		t4, 400000
6:	csrr	a0, CSR_MNOISE
	srli	t0, a0, 30
	andi	t0, t0, 1
	bnez	t0, 7f
	addi	t4, t4, -1
	bnez	t4, 6b
	j		fail
7:	csrr	a1, CSR_MNOISE
	bne		a0, a1, fail				//	still there, unchanged
	csrrw	a1, CSR_MNOISE, s9
	bne		a0, a1, fail				//	and this takes it
	csrr	a1, CSR_MNOISE
	srli	t0, a1, 30
	andi	t0, t0, 1
	bnez	t0, fail
	li		s0, 123						//	not reading for several intervals loses symbols
	li		t4, 6000
5:	addi	t4, t4, -1
	bnez	t4, 5b
	csrrw	a0, CSR_MNOISE, s9
	srli	t0, a0, 29
	andi	t0, t0, 3
	li		t1, 3
	bne		t0, t1, fail				//	valid, and the loss flag
	csrr	a0, CSR_MNOISE
	srli	t0, a0, 29
	andi	t0, t0, 1
	beqz	t0, fail					//	the flag stays
	li		s0, 124						//	a clearing write starts a new run
	li		t1, 5
	slli	t1, t1, 29					//	noise_test and the clear bit
	csrrw	a0, CSR_MNOISE, t1
	csrr	a0, CSR_MNOISE
	srli	t0, a0, 29
	andi	t0, t0, 1
	bnez	t0, fail
	li		s0, 125						//	leaving test mode: seed works again
	csrrw	a0, CSR_MNOISE, zero
	csrr	t0, CSR_MNOISE
	li		t1, 1
	bne		t0, t1, fail
	li		t1, (821 << 26) | (41 << 16) | 0
	csrw	CSR_MENTROPYCFG, t1
	jal		ra, m_collect8
	beqz	a0, fail

	//	---- 4: the lock ----
	li		s0, 130
	li		t1, (821 << 26) | (41 << 16) | 1
	li		t2, 1
	slli	t2, t2, 63
	or		t1, t1, t2
	csrw	CSR_MENTROPYCFG, t1
	csrr	t0, CSR_MENTROPYCFG
	bne		t0, t1, fail
	li		t2, (600 << 26) | (16 << 16) | 7
	csrw	CSR_MENTROPYCFG, t2
	csrr	t0, CSR_MENTROPYCFG
	bne		t0, t1, fail				//	locked: unchanged
	csrrw	a0, CSR_MNOISE, s9
	csrr	t0, CSR_MNOISE
	li		t2, 1
	bne		t0, t2, fail				//	locked: no test mode
	jal		ra, m_collect8
	beqz	a0, fail
#endif
	j		pass
#endif

	//	Poll seed until eight ES16 words were read. a0 = 1 on success; 0 if the
	//	source is dead, too slow, or delivered eight identical words.
m_collect8:
	li		t3, 8
	li		t4, 400000
	li		t5, 0						//	differences seen
	li		t6, -1						//	first word
1:	csrrw	a0, CSR_SEED, zero
	srli	t0, a0, 30
	li		t1, 3
	beq		t0, t1, 3f
	li		t1, 2
	bne		t0, t1, 2f
	slli	t2, a0, 48
	srli	t2, t2, 48
	bgez	t6, 4f
	mv		t6, t2
4:	xor		t0, t2, t6
	or		t5, t5, t0
	addi	t3, t3, -1
	bnez	t3, 1b
	snez	a0, t5
	ret
2:	addi	t4, t4, -1
	bnez	t4, 1b
3:	li		a0, 0
	ret

	//	S-mode: four words within 100 polls (arch/riscv/include/asm/archrandom.h)
s_seed_long:
	li		t3, 4
	li		t4, 100
1:	csrrw	a0, CSR_SEED, zero
	srli	t0, a0, 30
	li		t1, 2
	bne		t0, t1, 2f
	addi	t3, t3, -1
	beqz	t3, 3f
2:	addi	t4, t4, -1
	bnez	t4, 1b
	li		a0, 0
	ecall
3:	li		a0, 1
	ecall

	//	---- probes: one CSR instruction, then back to M ----
p_w:	csrrw	a0, CSR_SEED, zero
	ecall
p_r:	csrrs	a0, CSR_SEED, zero			//	does not write
	ecall
p_wi:	csrrwi	a0, CSR_SEED, 0
	ecall
p_s1:	csrrs	a0, CSR_SEED, ra			//	rs1 != x0: a writing form
	ecall
p_ci0:	csrrci	a0, CSR_SEED, 0				//	uimm = 0: does not write
	ecall
p_si1:	csrrsi	a0, CSR_SEED, 1
	ecall
p_sec:	csrr	a0, CSR_MSECCFG
	ecall
p_cfg:	csrr	a0, CSR_MENTROPYCFG
	ecall
p_noise: csrr	a0, CSR_MNOISE
	ecall
p_cfg_w: csrrw	a0, CSR_MENTROPYCFG, zero	//	would zero the cutoffs and the interval
	ecall
p_noise_w: csrrw a0, CSR_MNOISE, s9			//	would enter test mode
	ecall

	.macro ROW mode, sec, probe, cause, value=0
	.dword	\mode, \sec, \probe, \cause, \value
	.endm
	.align	3
table:
	ROW	M_M, 0,				p_w,	0, 1		//	 1
	ROW	M_M, 0,				p_wi,	0, 1
	ROW	M_M, 0,				p_s1,	0, 1
	ROW	M_M, 0,				p_si1,	0, 1
	ROW	M_M, 0,				p_r,	2
	ROW	M_M, SSEED|USEED,	p_r,	2
	ROW	M_M, 0,				p_ci0,	2
	ROW	M_S, 0,				p_w,	2			//	 8
	ROW	M_S, USEED,			p_w,	2
	ROW	M_S, SSEED,			p_w,	0, 1
	ROW	M_S, SSEED,			p_r,	2
	ROW	M_S, SSEED,			p_ci0,	2
	ROW	M_U, 0,				p_w,	2			//	13
	ROW	M_U, SSEED,			p_w,	2
	ROW	M_U, USEED,			p_w,	0, 1
	ROW	M_U, USEED,			p_r,	2
	ROW	M_S, SSEED,			p_sec,	2			//	17: mseccfg is M-only
	ROW	M_U, USEED,			p_sec,	2
#if ZKR_TEST_H
	ROW	M_VS, 0,			p_w,	2			//	19
	ROW	M_VS, USEED,		p_w,	2
	ROW	M_VS, SSEED,		p_w,	22
	ROW	M_VS, SSEED,		p_wi,	22
	ROW	M_VS, SSEED,		p_r,	2
	ROW	M_VU, 0,			p_w,	2			//	24
	ROW	M_VU, USEED,		p_w,	2
	ROW	M_VU, SSEED,		p_w,	22
	ROW	M_VU, SSEED|USEED,	p_w,	22
	ROW	M_VU, SSEED|USEED,	p_r,	2
	ROW	M_VS, SSEED,		p_sec,	2			//	29: an M-level CSR from a guest
#endif
#ifdef ZKR_TEST_CUSTOM
	ROW	M_M, 0,				p_cfg,	0
	ROW	M_M, 0,				p_noise, 0
	ROW	M_S, SSEED,			p_cfg,	2
	ROW	M_S, SSEED,			p_noise, 2
	ROW	M_U, USEED,			p_cfg,	2
	//	writes from below M trap and change nothing: sections 110 and 120
	//	find the reset configuration and no test mode
	ROW	M_S, SSEED,			p_cfg_w, 2
	ROW	M_U, USEED,			p_noise_w, 2
#if ZKR_TEST_H
	ROW	M_VS, SSEED,		p_cfg,	2
	ROW	M_VU, SSEED,		p_noise, 2
	ROW	M_VS, SSEED,		p_noise_w, 2
	ROW	M_VU, SSEED|USEED,	p_cfg_w, 2
#endif
#endif
	.dword	-1

	//	Every trap comes here. An ecall is the normal way back; anything else
	//	is recorded. Either way M-mode continues at s5.
m_handler:
	csrr	t5, mcause
	li		t6, 8
	blt		t5, t6, 1f
	li		t6, 11
	ble		t5, t6, 2f
1:	mv		s7, t5
	csrr	s8, mtval
2:	csrw	mepc, s5
	li		t5, 3 << 11
	csrs	mstatus, t5
	li		t5, 1 << 39
	csrc	mstatus, t5
	mret

pass:
	li		t0, 1
	li		t1, TOHOST
	sd		t0, 0(t1)
1:	j		1b
fail:
	slli	t0, s0, 1
	ori		t0, t0, 1
	li		t1, TOHOST
	sd		t0, 0(t1)
1:	j		1b

	.section .htif,"aw"
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
