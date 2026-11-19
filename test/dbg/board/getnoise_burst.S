//	getnoise_burst.S
//	=== Bursts of consecutive raw noise symbols at a chosen sampling period.
//
//	An M-mode routine for the burst capture of the FPGA entropy source
//	(flow/fpga/karu_noise_burst.v). It puts the entropy source in test mode,
//	sets the sampling period of the rings, 1 to 256 clock cycles, and has the
//	hardware record bursts of consecutive raw symbols, which it copies to
//	memory. Nothing is combined: a stored symbol is the four ring outputs of
//	one clock edge, lane i in bit i.
//
//	The code is position independent. The host loads it anywhere in RAM,
//	writes the parameter block, starts the hart at the first byte and waits
//	for the ebreak (getnoise_burst.py does this through the debugger).
//	Symbol values in the linked file are offsets from the load address.
//
//	Parameter block (getburst_params, 64-bit words, written by the host):
//	  0  period     clock cycles per raw symbol, 1..256
//	  1  bursts     bursts wanted
//	  2  buffer     address of the buffer
//	  3  size       size of the buffer in bytes; all bursts must fit
//	  4  idle       status polls allowed for one burst before giving up
//	                (must not be zero: every wait is bounded)
//
//	Result block (getburst_result, 64-bit words, written by this routine):
//	  0  status     see below; written last
//	  1  stored     complete bursts in the buffer
//	  2  words      64-bit words of symbols per burst, as the hardware says
//	  3  polls      status polls issued
//	  4  ctrl       the capture block's status register at entry
//	  5  period_used  its period register read back in test mode
//	  6  cfg        mentropycfg (read, never written)
//	  7  noise_after  mnoise read back after leaving test mode (1 expected)
//	  8  ctrl_after   the status register after leaving test mode
//	  9  mcause     of an unexpected trap (status TRAP)
//	  10 mepc       of that trap
//
//	Buffer: one record per burst, 16 + 8 * words bytes:
//	  0   mcycle just before the start bit was written
//	  8   mcycle just after the status showed the burst complete
//	  16  the burst: sixteen symbols per 64-bit word in the order they were
//	      sampled, the first in bits [3:0]
//	Within a burst the symbols are consecutive samples, `period` clock cycles
//	apart. Bursts are separate: nothing is known about the samples between
//	two of them, and they must never be joined.
//
//	Status:
//	  0  OK        all bursts stored
//	  1  RUNNING   entered and not finished (the host sees this only if the
//	               routine did not reach its end)
//	  2  LOCKED    mentropycfg has its lock bit set; nothing was changed
//	  3  BUSY      mnoise did not read 1 at entry (already in test mode, or
//	               not the expected CSR); nothing was changed
//	  4  PARAM     period, bursts, buffer size or idle limit rejected
//	  5  NOTEST    test mode was not entered, or the capture block did not
//	               allow capturing in it
//	  6  TIMEOUT   a burst did not complete within the idle limit; the bursts
//	               stored so far are valid
//	  7  TRAP      unexpected trap, for example an illegal instruction at the
//	               first CSR access when the image has no entropy source
//	  8  NOBLOCK   the status register does not identify the capture block:
//	               an image without it; nothing was changed
//	  9  PERIOD    the period register did not take the value
//	  10 ABORTED   the capture block aborted a burst: the noise source was
//	               off while it ran (DIP switch 4, or a dead source); the
//	               bursts stored before it are valid
//	  -1 the value in the file: never run
//
//	Test mode is left on every path that entered it, which also puts the
//	sampling period back and restarts the start-up test of seed. mentropycfg
//	is not written. mstatus and mtvec are restored. All other registers used
//	are clobbered.
//
//	-DGETBURST_SIM       no debugger: report (status << 1) | 1 through the
//	                     HTIF tohost word at 0x80001000 instead of ebreak
//	SPDX-License-Identifier: BSD-2-Clause

	.equ	CSR_MNOISE,		0x7C8
	.equ	CSR_MENTROPYCFG, 0x7C9
	.equ	TOHOST,			0x80001000
	.equ	NBURST,			0x10000840		//	the capture block: system-control block + 0x40
	.equ	NB_CTRL,		0
	.equ	NB_PERIOD,		8
	.equ	NB_INDEX,		16
	.equ	NB_DATA,		24
	.equ	NB_MAGIC,		0x4b4e4231

	.equ	P_PERIOD,		0
	.equ	P_BURSTS,		8
	.equ	P_BUF,			16
	.equ	P_SIZE,			24
	.equ	P_IDLE,			32
	.equ	R_STATUS,		40
	.equ	R_STORED,		48
	.equ	R_WORDS,		56
	.equ	R_POLLS,		64
	.equ	R_CTRL,			72
	.equ	R_PERIOD_USED,	80
	.equ	R_CFG,			88
	.equ	R_NOISE_AFTER,	96
	.equ	R_CTRL_AFTER,	104
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
	.equ	ST_NOBLOCK,		8
	.equ	ST_PERIOD,		9
	.equ	ST_ABORTED,		10

	.option	norvc
	.option	norelax
	.section .text
	.globl	getburst, getburst_params, getburst_result, getburst_stop
getburst:
	j		start
	.balign	8
getburst_params:
	.dword	0, 0, 0, 0, 0
getburst_result:
	.dword	-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

	//	s0 block, s1 bursts still wanted, s2 next byte of the buffer,
	//	s3 the capture block, s4 words per burst, s5 idle limit, s6 period,
	//	s7 polls, s8 status, s9 "test mode was entered", s10 mstatus,
	//	s11 mtvec; a2 bursts stored
start:
	lla		s0, getburst_params
	csrr	s10, mstatus
	csrci	mstatus, 8					//	no interrupts during the capture
	csrr	s11, mtvec
	lla		t0, trap
	csrw	mtvec, t0
	li		s9, 0
	li		s7, 0
	li		a2, 0
	li		s4, 0
	li		t0, ST_RUNNING
	sd		t0, R_STATUS(s0)
	sd		zero, R_CTRL(s0)
	sd		zero, R_PERIOD_USED(s0)
	sd		zero, R_CFG(s0)
	sd		zero, R_NOISE_AFTER(s0)
	sd		zero, R_CTRL_AFTER(s0)
	sd		zero, R_MCAUSE(s0)
	sd		zero, R_MEPC(s0)
	li		s3, NBURST
	ld		s1, P_BURSTS(s0)
	ld		s2, P_BUF(s0)
	ld		s5, P_IDLE(s0)
	ld		s6, P_PERIOD(s0)

	csrr	t0, CSR_MENTROPYCFG			//	traps if the image has no entropy source
	sd		t0, R_CFG(s0)
	li		s8, ST_LOCKED
	bltz	t0, report					//	bit 63
	li		s8, ST_BUSY
	csrr	t0, CSR_MNOISE
	li		t1, 1
	bne		t0, t1, report

	//	the capture block and the size of its bursts
	li		s8, ST_NOBLOCK
	ld		t0, NB_CTRL(s3)
	sd		t0, R_CTRL(s0)
	srli	t1, t0, 32
	li		t2, NB_MAGIC
	bne		t1, t2, report
	srli	t1, t0, 8
	andi	t1, t1, 0xff				//	log2 of the symbols per burst
	addi	t1, t1, -4
	bltz	t1, report
	li		s4, 1
	sll		s4, s4, t1					//	words per burst

	//	parameters: period 1..256, bursts and idle not zero, all bursts fit
	li		s8, ST_PARAM
	beqz	s5, report
	beqz	s1, report
	beqz	s6, report
	li		t0, 256
	bgtu	s6, t0, report
	slli	t0, s4, 3
	addi	t0, t0, 16					//	bytes per record
	ld		t1, P_SIZE(s0)
	divu	t1, t1, t0					//	records that fit
	bgtu	s1, t1, report

	//	enter test mode; the capture block must now allow capturing
	li		t0, 5
	slli	t0, t0, 29					//	noise_test, and clear the loss flag
	li		s9, 1
	csrw	CSR_MNOISE, t0
	li		s8, ST_NOTEST
	csrr	t0, CSR_MNOISE
	srli	t0, t0, 31
	andi	t0, t0, 1
	beqz	t0, done
	ld		t0, NB_CTRL(s3)
	andi	t0, t0, 4
	beqz	t0, done

	li		s8, ST_PERIOD
	addi	t0, s6, -1
	sd		t0, NB_PERIOD(s3)
	ld		t1, NB_PERIOD(s3)
	addi	t1, t1, 1
	sd		t1, R_PERIOD_USED(s0)
	bne		t1, s6, done

	//	---- bursts ----
burst:
	li		s8, ST_TIMEOUT
	csrr	t3, mcycle
	li		t0, 1
	sd		t0, NB_CTRL(s3)				//	start; the burst begins with the next symbol
	mv		t4, s5
wait:
	ld		t0, NB_CTRL(s3)
	addi	s7, s7, 1
	andi	t1, t0, 2					//	done
	bnez	t1, copy
	andi	t1, t0, 64					//	aborted
	li		s8, ST_ABORTED
	bnez	t1, done
	li		s8, ST_TIMEOUT
	addi	t4, t4, -1
	bnez	t4, wait
	j		done
copy:
	csrr	t0, mcycle
	sd		t3, 0(s2)
	sd		t0, 8(s2)
	addi	s2, s2, 16
	sd		zero, NB_INDEX(s3)
	mv		t1, s4
1:	ld		t0, NB_DATA(s3)				//	the word at the index; the index moves on
	sd		t0, 0(s2)
	addi	s2, s2, 8
	addi	t1, t1, -1
	bnez	t1, 1b
	addi	a2, a2, 1
	addi	s1, s1, -1
	bnez	s1, burst
	li		s8, ST_OK

	//	---- leave test mode: the period and the capture block are reset with it ----
done:
	beqz	s9, report
	li		s9, 0						//	a trap from here on ends at finish
	csrw	CSR_MNOISE, zero
report:
	csrr	t0, CSR_MNOISE
	sd		t0, R_NOISE_AFTER(s0)
	ld		t0, NB_CTRL(s3)
	sd		t0, R_CTRL_AFTER(s0)
finish:
	sd		a2, R_STORED(s0)
	sd		s4, R_WORDS(s0)
	sd		s7, R_POLLS(s0)
	csrw	mtvec, s11
	csrw	mstatus, s10
	sd		s8, R_STATUS(s0)
#ifdef GETBURST_SIM
	slli	t0, s8, 1
	ori		t0, t0, 1
	li		t1, TOHOST
	sd		t0, 0(t1)
#endif
getburst_stop:
#ifndef GETBURST_SIM
	ebreak								//	the debugger takes over here
#endif
	j		getburst_stop

	//	Any trap ends the capture. If test mode was entered it is left first;
	//	a second trap, during that, goes straight to finish.
	.balign	4
trap:
	csrr	t0, mcause
	sd		t0, R_MCAUSE(s0)
	csrr	t0, mepc
	sd		t0, R_MEPC(s0)
	li		s8, ST_TRAP
	bnez	s9, done
	j		finish
