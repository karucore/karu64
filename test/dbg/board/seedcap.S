//	seedcap.S
//	=== Operational restart capture: seed words from the first ES16 on.
//
//	An M-mode routine that reads the Zkr seed CSR from reset on, as a first
//	consumer would, and stores the first words the source delivers. It is
//	the data collection of SP 800-90B section 3.1.4 on the operational
//	output path: the source runs in its reset configuration (nothing here
//	writes mentropycfg or mnoise), the samples come out of seed, and the
//	first stored word is the first word the source delivered after its
//	start-up test, provided that the routine was already polling while the
//	start-up test ran (bist > 0; otherwise the status is LATE).
//
//	seed_restart.py resets the SoC through the debugger and starts the hart
//	here a few milliseconds later; the start-up test takes about 57 ms on the
//	VCU118. The routine polls without a pause, so the source's buffer of
//	eight words never fills and no sample is dropped between two stored
//	words: max_gap, the longest time between two polls, shows it (one word
//	takes 16,384 clocks at the reset spacing).
//
//	The code is position independent and linked at 0, like getnoise.S.
//
//	Parameter block (seedcap_params, 64-bit words, written by the host):
//	  0  count      words wanted (four samples each)
//	  1  buffer     address of the buffer, two bytes per word
//	  2  idle       polls allowed without a word before giving up (not zero)
//
//	Result block (seedcap_result, 64-bit words, written by this routine):
//	  0  status     see below; written last
//	  1  stored     words in the buffer
//	  2  bist       polls that returned BIST before the first ES16
//	  3  wait       polls that returned WAIT
//	  4  cyc_entry  mcycle at entry
//	  5  cyc_first  mcycle at the poll that returned the first ES16
//	  6  cyc_end    mcycle at the poll that returned the last word
//	  7  max_gap    largest mcycle difference between consecutive polls
//	  8  stat_end   mentropystat at the end
//	  9  cfg_end    mentropycfg at the end
//	  10 mcause     of an unexpected trap (status TRAP)
//	  11 mepc       of that trap
//
//	Buffer: one 16-bit word per stored seed word, in the order read. Each
//	word holds four consecutive samples, the first in bits [15:12] and the
//	last in bits [3:0] (rtl/karu_entropy.v packs them so).
//
//	Status:
//	  0  OK        count words stored, BIST seen before the first
//	  1  RUNNING   entered and not finished
//	  2  LATE      count words stored, but the first poll already returned
//	               ES16: words may have been delivered before the routine ran
//	  3  DEAD      seed returned DEAD
//	  4  ALARM     seed returned BIST after an ES16: a running health failure
//	               (the words stored so far are valid; the source wiped the rest)
//	  5  TIMEOUT   idle polls passed without a word
//	  6  TRAP      unexpected trap
//	  7  PARAM     count or idle is zero
//	  -1 the value in the file: never run
//
//	mtvec and mstatus are restored before the ebreak.
//
//	-DSEEDCAP_SPIN=n     test only: spin n iterations before the first poll
//	SPDX-License-Identifier: BSD-2-Clause

	.equ	CSR_SEED,		0x015
	.equ	CSR_MENTROPYCFG, 0x7C9
	.equ	CSR_MENTROPYSTAT, 0x7CA

	.equ	P_COUNT,		0
	.equ	P_BUF,			8
	.equ	P_IDLE,			16
	.equ	R_STATUS,		24
	.equ	R_STORED,		32
	.equ	R_BIST,			40
	.equ	R_WAIT,			48
	.equ	R_CYC_ENTRY,	56
	.equ	R_CYC_FIRST,	64
	.equ	R_CYC_END,		72
	.equ	R_MAX_GAP,		80
	.equ	R_STAT_END,		88
	.equ	R_CFG_END,		96
	.equ	R_MCAUSE,		104
	.equ	R_MEPC,			112

	.equ	ST_OK,			0
	.equ	ST_RUNNING,		1
	.equ	ST_LATE,		2
	.equ	ST_DEAD,		3
	.equ	ST_ALARM,		4
	.equ	ST_TIMEOUT,		5
	.equ	ST_TRAP,		6
	.equ	ST_PARAM,		7

	.option	norvc
	.option	norelax
	.section .text
	.globl	seedcap, seedcap_params, seedcap_result, seedcap_stop
seedcap:
	j		start
	.balign	8
seedcap_params:
	.dword	0, 0, 0
seedcap_result:
	.dword	-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

	//	s0 block, s1 words wanted, s2 next buffer address, s3 BIST polls,
	//	s4 WAIT polls, s5 idle limit, s6 "an ES16 has been seen", s7 max gap,
	//	s8 status, s9 words stored, s10 mstatus, s11 mtvec;
	//	t4 idle polls left, t6 mcycle of the previous poll
start:
	csrr	t6, mcycle
	lla		s0, seedcap_params
	csrr	s10, mstatus
	csrci	mstatus, 8					//	no interrupts
	csrr	s11, mtvec
	lla		t0, trap
	csrw	mtvec, t0
	sd		t6, R_CYC_ENTRY(s0)
	li		t0, ST_RUNNING
	sd		t0, R_STATUS(s0)
	sd		zero, R_CYC_FIRST(s0)
	sd		zero, R_CYC_END(s0)
	sd		zero, R_MCAUSE(s0)
	sd		zero, R_MEPC(s0)
	li		s3, 0
	li		s4, 0
	li		s6, 0
	li		s7, 0
	li		s9, 0
	li		s8, ST_PARAM
	ld		s1, P_COUNT(s0)
	ld		s2, P_BUF(s0)
	ld		s5, P_IDLE(s0)
	beqz	s1, report
	beqz	s5, report
	mv		t4, s5
#ifdef SEEDCAP_SPIN
	li		t0, SEEDCAP_SPIN
1:	addi	t0, t0, -1
	bnez	t0, 1b
#endif
	csrr	t6, mcycle
poll:
	csrrw	a0, CSR_SEED, zero			//	OPST and entropy; takes the word
	csrr	t0, mcycle
	sub		t1, t0, t6
	mv		t6, t0
	bleu	t1, s7, 1f
	mv		s7, t1
1:	srli	t2, a0, 30
	andi	t2, t2, 3
	li		t3, 2
	beq		t2, t3, es16
	li		t3, 3
	beq		t2, t3, dead
	bnez	t2, wait					//	1: WAIT
	bnez	s6, alarm					//	0: BIST, after an ES16 a latched alarm
	addi	s3, s3, 1
	j		idle
wait:
	addi	s4, s4, 1
idle:
	addi	t4, t4, -1
	bnez	t4, poll
	li		s8, ST_TIMEOUT
	j		report
es16:
	bnez	s6, 2f
	li		s6, 1
	sd		t0, R_CYC_FIRST(s0)
2:	sh		a0, 0(s2)
	addi	s2, s2, 2
	addi	s9, s9, 1
	mv		t4, s5
	bne		s9, s1, poll
	sd		t0, R_CYC_END(s0)
	li		s8, ST_OK
	bnez	s3, report
	li		s8, ST_LATE
	j		report
dead:
	li		s8, ST_DEAD
	j		report
alarm:
	li		s8, ST_ALARM
report:
	sd		s9, R_STORED(s0)
	sd		s3, R_BIST(s0)
	sd		s4, R_WAIT(s0)
	sd		s7, R_MAX_GAP(s0)
	csrr	t0, CSR_MENTROPYSTAT
	sd		t0, R_STAT_END(s0)
	csrr	t0, CSR_MENTROPYCFG
	sd		t0, R_CFG_END(s0)
	csrw	mtvec, s11
	csrw	mstatus, s10
	sd		s8, R_STATUS(s0)
seedcap_stop:
	ebreak
	j		seedcap_stop

	.balign	4
trap:
	csrr	t0, mcause
	sd		t0, R_MCAUSE(s0)
	csrr	t0, mepc
	sd		t0, R_MEPC(s0)
	li		s8, ST_TRAP
	j		report
