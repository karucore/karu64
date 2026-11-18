//	getnoise.S
//	=== Raw noise capture through the GetNoise test interface (mnoise).
//
//	An M-mode routine that takes raw 4-bit symbols from the entropy source
//	(rtl/karu_entropy.v) at a chosen decimation k and stores them in memory,
//	one byte per symbol. Nothing is combined: a stored byte is one symbol as
//	the source delivered it, lane i in bit i.
//
//	The code is position independent. The host loads it anywhere in RAM,
//	writes the parameter block, starts the hart at the first byte and waits
//	for the ebreak (getnoise_capture.py does this through the debugger).
//	Symbol values in the linked file are offsets from the load address.
//
//	Parameter block (getnoise_params, 64-bit words, written by the host):
//	  0  interval   k-1, the low 16 bits of mentropycfg during the capture
//	  1  count      symbols wanted
//	  2  buffer     address of the buffer
//	  3  size       size of the buffer in bytes; count must fit
//	  4  idle       polls allowed without storing a symbol before giving up
//	                (must not be zero: every wait is bounded)
//
//	Result block (getnoise_result, 64-bit words, written by this routine):
//	  0  status     see below; written last
//	  1  stored     symbols in the buffer
//	  2  runs       runs that have at least one symbol
//	  3  losses     polls that returned the loss flag
//	  4  polls      CSRRW instructions issued in test mode
//	  5  cfg_before mentropycfg at entry
//	  6  cfg_used   mentropycfg read back during the capture
//	  7  cfg_after  mentropycfg read back after the restore
//	  8  noise_after  mnoise read back after leaving test mode (1 expected)
//	  9  mcause     of an unexpected trap (status TRAP)
//	  10 mepc       of that trap
//
//	Buffer: one byte per symbol. Bits [3:0] are the symbol. Bit 7 marks the
//	first symbol of a run. Bits [6:4] are zero. Within a run the symbols are
//	consecutive kept samples: the source reported no loss between them. When
//	the source reports a loss, the symbol of that poll and whatever the
//	clearing write returns are discarded, and the next symbol starts a new
//	run. Runs are never joined.
//
//	Status:
//	  0  OK        count symbols stored
//	  1  RUNNING   entered and not finished (the host sees this only if the
//	               routine did not reach its end)
//	  2  LOCKED    mentropycfg has its lock bit set; nothing was changed
//	  3  BUSY      mnoise did not read 1 at entry (already in test mode, or
//	               not the expected CSR); nothing was changed
//	  4  PARAM     count is zero or larger than the buffer, or idle is zero
//	  5  NOTEST    the write to mnoise did not enter test mode
//	  6  TIMEOUT   idle polls passed without a stored symbol; the symbols
//	               stored so far are valid
//	  7  TRAP      unexpected trap, for example an illegal instruction at the
//	               first CSR access when the image has no entropy source
//	  -1 the value in the file: never run
//
//	On every path that changed the source, test mode is left and mentropycfg
//	is written back before the routine stops. Both writes restart the source,
//	so seed goes through its start-up test again. mstatus and mtvec are
//	restored. All other registers used are clobbered.
//
//	-DGETNOISE_SIM       no debugger: report (status << 1) | 1 through the
//	                     HTIF tohost word at 0x80001000 instead of ebreak
//	-DGETNOISE_SLOW=n    test only: spin n iterations after every 64th stored
//	                     symbol, so that symbols are lost and runs end
//	SPDX-License-Identifier: BSD-2-Clause

	.equ	CSR_MNOISE,		0x7C8
	.equ	CSR_MENTROPYCFG, 0x7C9
	.equ	TOHOST,			0x80001000

	.equ	P_INTERVAL,		0
	.equ	P_COUNT,		8
	.equ	P_BUF,			16
	.equ	P_SIZE,			24
	.equ	P_IDLE,			32
	.equ	R_STATUS,		40
	.equ	R_STORED,		48
	.equ	R_RUNS,			56
	.equ	R_LOSSES,		64
	.equ	R_POLLS,		72
	.equ	R_CFG_BEFORE,	80
	.equ	R_CFG_USED,		88
	.equ	R_CFG_AFTER,	96
	.equ	R_NOISE_AFTER,	104
	.equ	R_MCAUSE,		112
	.equ	R_MEPC,			120

	.equ	ST_OK,			0
	.equ	ST_RUNNING,		1
	.equ	ST_LOCKED,		2
	.equ	ST_BUSY,		3
	.equ	ST_PARAM,		4
	.equ	ST_NOTEST,		5
	.equ	ST_TIMEOUT,		6
	.equ	ST_TRAP,		7

	.option	norvc
	.option	norelax
	.section .text
	.globl	getnoise, getnoise_params, getnoise_result, getnoise_stop
getnoise:
	j		start
	.balign	8
getnoise_params:
	.dword	0, 0, 0, 0, 0
getnoise_result:
	.dword	-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

	//	s0 block, s1 symbols still wanted, s2 next byte of the buffer,
	//	s3 mentropycfg at entry, s4 the poll value, s5 idle limit,
	//	s6 the clearing poll value, s8 status, s9 "the source was changed",
	//	s10 mstatus, s11 mtvec; a2 polls, a3 runs, a4 losses,
	//	t4 idle polls left, t5 the run flag for the next stored symbol
start:
	lla		s0, getnoise_params
	csrr	s10, mstatus
	csrci	mstatus, 8					//	no interrupts during the capture
	csrr	s11, mtvec
	lla		t0, trap
	csrw	mtvec, t0
	li		s9, 0
	li		a2, 0
	li		a3, 0
	li		a4, 0
	li		t0, ST_RUNNING
	sd		t0, R_STATUS(s0)
	sd		zero, R_CFG_BEFORE(s0)
	sd		zero, R_CFG_USED(s0)
	sd		zero, R_CFG_AFTER(s0)
	sd		zero, R_NOISE_AFTER(s0)
	sd		zero, R_MCAUSE(s0)
	sd		zero, R_MEPC(s0)

	li		s8, ST_PARAM
	ld		s1, P_COUNT(s0)
	ld		s2, P_BUF(s0)
	ld		s5, P_IDLE(s0)
	ld		t0, P_SIZE(s0)
	beqz	s5, finish
	beqz	s1, finish
	bgtu	s1, t0, finish

	csrr	s3, CSR_MENTROPYCFG			//	traps if the image has no entropy source
	sd		s3, R_CFG_BEFORE(s0)
	li		s8, ST_LOCKED
	bltz	s3, report					//	bit 63
	li		s8, ST_BUSY
	csrr	t0, CSR_MNOISE
	li		t1, 1
	bne		t0, t1, report

	//	the requested interval, with the two cutoffs as they are
	srli	t0, s3, 16
	slli	t0, t0, 16
	ld		t1, P_INTERVAL(s0)
	slli	t1, t1, 48
	srli	t1, t1, 48
	or		t0, t0, t1
	li		s9, 1
	csrw	CSR_MENTROPYCFG, t0			//	restarts the source
	csrr	t0, CSR_MENTROPYCFG
	sd		t0, R_CFG_USED(s0)			//	what the source accepted

	li		s4, 1
	slli	s4, s4, 31					//	noise_test
	li		s6, 5
	slli	s6, s6, 29					//	noise_test and "clear the loss flag"
	csrw	CSR_MNOISE, s4				//	enter test mode
	li		s8, ST_NOTEST
	csrr	t0, CSR_MNOISE
	and		t0, t0, s4
	beqz	t0, done

	//	---- capture ----
	li		s8, ST_TIMEOUT
	mv		t4, s5
	li		t5, 0x80					//	the first symbol starts the first run
poll:
	csrrw	a0, CSR_MNOISE, s4			//	status and symbol of this cycle; takes the symbol
	addi	a2, a2, 1
	slli	t0, a0, 34					//	bit 29, loss
	bltz	t0, lost
	slli	t0, a0, 33					//	bit 30, symbol valid
	bgez	t0, idle
	andi	a0, a0, 15
	or		a0, a0, t5
	sb		a0, 0(s2)
	addi	s2, s2, 1
	srli	t0, t5, 7
	add		a3, a3, t0					//	a flagged symbol is a new run
	li		t5, 0
	mv		t4, s5
	addi	s1, s1, -1
#ifdef GETNOISE_SLOW
	andi	t0, s1, 63
	bnez	t0, 2f
	li		t0, GETNOISE_SLOW
1:	addi	t0, t0, -1
	bnez	t0, 1b
2:
#endif
	bnez	s1, poll
	li		s8, ST_OK
	j		done
lost:
	//	The run has ended. This poll's symbol does not follow the previous
	//	one; drop it, clear the flag, drop what the clearing write returns.
	addi	a4, a4, 1
	csrrw	a0, CSR_MNOISE, s6
	addi	a2, a2, 1
	li		t5, 0x80
idle:
	addi	t4, t4, -1
	bnez	t4, poll

	//	---- leave test mode, put the configuration back ----
done:
	beqz	s9, report
	li		s9, 0						//	a trap from here on ends at finish
	csrw	CSR_MNOISE, zero
	csrw	CSR_MENTROPYCFG, s3
report:
	csrr	t0, CSR_MNOISE
	sd		t0, R_NOISE_AFTER(s0)
	csrr	t0, CSR_MENTROPYCFG
	sd		t0, R_CFG_AFTER(s0)
finish:
	ld		t0, P_COUNT(s0)
	sub		t0, t0, s1
	sd		t0, R_STORED(s0)
	sd		a3, R_RUNS(s0)
	sd		a4, R_LOSSES(s0)
	sd		a2, R_POLLS(s0)
	csrw	mtvec, s11
	csrw	mstatus, s10
	sd		s8, R_STATUS(s0)
#ifdef GETNOISE_SIM
	slli	t0, s8, 1
	ori		t0, t0, 1
	li		t1, TOHOST
	sd		t0, 0(t1)
#endif
getnoise_stop:
#ifndef GETNOISE_SIM
	ebreak								//	the debugger takes over here
#endif
	j		getnoise_stop

	//	Any trap ends the capture. If the source was changed it is put back
	//	first; a second trap, during that, goes straight to finish.
	.balign	4
trap:
	csrr	t0, mcause
	sd		t0, R_MCAUSE(s0)
	csrr	t0, mepc
	sd		t0, R_MEPC(s0)
	li		s8, ST_TRAP
	bnez	s9, done
	j		finish
