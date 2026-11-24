//	rosc_count.S
//	=== Records of the ring-oscillator meter, and bursts of one ring's count.
//
//	An M-mode routine for the meter of the FPGA entropy source
//	(flow/fpga/karu_rosc_meter.v, registers at 0x1000_0868). It puts the
//	entropy source in test mode, sets the sampling period of the rings and
//	which of the six rings run, and then does one of three things:
//
//	  mode 0  has the meter take a record at every `every`-th raw sample and
//	          copies the records to memory: the totals of the six rings and
//	          the four lane bits, all of one clock edge
//	  mode 1  has the burst capture block (flow/fpga/karu_noise_burst.v)
//	          record four bits of one ring's count in place of the lane bits,
//	          the lower or the upper four of its six, and copies the bursts to
//	          memory as getnoise_burst.S does: at a period of one clock, the
//	          ring's count clock by clock
//	  mode 2  the same with the bits of the two reference rings and of lanes
//	          0 and 1 in place of the four lane bits: lane 0 and two rings of
//	          its kind, sampled at one clock edge
//
//	Nothing is combined or interpreted: what is stored is what the registers
//	returned. THE UNIT OF A COUNT, AND OF EVERY TOTAL, IS TWO RING PERIODS:
//	the source's counters count each ring divided by two. With the parameter
//	`direct` the counters are clocked by the rings themselves and the unit is
//	one period: a diagnostic mode, outside what the part guarantees for the
//	fastest rings. Nothing here multiplies by the unit.
//
//	The code is position independent. The host loads it anywhere in RAM,
//	writes the parameter block, starts the hart at the first byte and waits
//	for the ebreak (rosc_count.py does this through the debugger). Symbol
//	values in the linked file are offsets from the load address.
//
//	Parameter block (rosc_params, 64-bit words, written by the host):
//	  0  period     clock cycles per raw sample, less one: 0..255
//	  1  every      raw samples per record, less one: 0..65535 (mode 0; the
//	                clocks between two records are (period + 1) * (every + 1))
//	  2  mask       the rings that run, ring r in bit r: 0..0x3f. Rings 0..3
//	                are the four lanes, rings 4 and 5 the reference rings
//	  3  count      records wanted (mode 0), bursts wanted (modes 1 and 2)
//	  4  buffer     address of the buffer
//	  5  size       size of the buffer in bytes; everything wanted must fit
//	  6  idle       polls allowed while waiting for one record or one burst
//	                before giving up (must not be zero: every wait is bounded)
//	  7  losses     mode 0: losses after which a new run is still started,
//	                0..RUNS_MAX-1; one more ends the capture
//	  8  mode       0, 1 or 2
//	  9  ring       mode 1: the ring whose count is recorded, 0..5; it must
//	                be in the mask
//	  10 slow       mode 0, tests only: iterations to spin after every 64th
//	                record, so that records are lost. 0 on the board
//	  11 direct     0: counts of two ring periods. 1: direct counting, counts
//	                of one period (CTRL[28]); the write stops and restarts
//	                every ring
//	  12 upper      mode 1: 0 the lower four bits of the count, 1 the upper
//	                four (CTRL[27]), in which the step of a count that
//	                advances by more than 16 a clock can be seen
//
//	Result block (rosc_result, 64-bit words, written by this routine):
//	  0  status     see below; written last
//	  1  stored     records in the buffer (mode 0), complete bursts (modes 1
//	                and 2)
//	  2  runs       entries of the run table (mode 0)
//	  3  losses     runs that ended with the meter's loss flag (mode 0)
//	  4  polls      polls that found no record (mode 0), status polls (modes
//	                1 and 2)
//	  5  words      64-bit words per burst, as the capture block says
//	  6  nbctrl     the capture block's status register at entry
//	  7  period_used  its period register read back in test mode, plus one
//	  8  mctrl      the meter's control register read back in test mode,
//	                after it was written: [28:0] as written, [37:32] the
//	                rings that run outside test mode
//	  9  cfg        mentropycfg at entry (read, never written)
//	  10 stat       mentropystat at entry
//	  11 cfg_after  mentropycfg after leaving test mode
//	  12 stat_after mentropystat after leaving test mode
//	  13 noise_after  mnoise read back after leaving test mode (1 expected)
//	  14 nbctrl_after the capture block's status register after test mode
//	  15 mctrl_after  the meter's control register after test mode (0 expected)
//	  16 mcause     of an unexpected trap (status TRAP)
//	  17 mepc       of that trap
//	  18 mctrl_end  the meter's control register just before test mode was
//	                left: [47:42] the rings that had a count that could not
//	                be read or did not fit the one before, [63:48] the clock
//	                cycles with such a count; in mode 0 since the start of
//	                the last run, in modes 1 and 2 since the register was
//	                written
//
//	Mode 0, the buffer: 16 bytes per record, the two data registers as read,
//	  0   DATA0  [63] valid, [62] loss, [61:60] sequence number,
//	             [59:40] total of ring 2, [39:20] ring 1, [19:0] ring 0
//	  8   DATA1  [63:60] the lane bits at the record's clock edge (bit 60 is
//	             lane 0), [59:40] total of ring 5, [39:20] ring 4, [19:0] ring 3
//	A total is a free-running count modulo 2^20, in units of two ring
//	periods (of one with `direct`).
//
//	Mode 0, the run table (rosc_runs, RUNS_MAX entries of five 64-bit words):
//	  0   start      index of the run's first record in the buffer
//	  1   records    records of the run
//	  2   mcycle just before the start bit was written
//	  3   mcycle just after the run's last record was stored or, for a run
//	      that a loss ended, after the read that showed the loss flag
//	  4   the meter's control register at that time: [40] a record is held,
//	      [41] loss, [63:48] the clock cycles of the run in which a ring of
//	      the mask had a count that could not be read (it is made up with the
//	      next count that can) or whose increment was more than 2 from the
//	      increment of the clock before (a count wrong by sixteen, the one
//	      error the counter's decoding can make, is that), [47:42] the rings
//	      that had one
//	A run is a stretch of records that the meter delivered without its loss
//	flag: consecutive records, (period + 1) * (every + 1) clocks apart, with
//	sequence numbers 0, 1, 2, 3, 0 and so on. The meter never overwrites a
//	record that was not read. It drops the new one and sets the flag, so a
//	record read with the flag clear follows the one before it. A record read
//	with the flag set is not stored: the run ends with the record before it,
//	the start bit is written again, and the next record starts a new run.
//	Nothing is known about the time between two runs but their stamps, and
//	they must never be joined. A run without a record has no entry.
//
//	Modes 1 and 2, the buffer: one record per burst, 16 + 8 * words bytes, as
//	in getnoise_burst.S: mcycle before the start, mcycle after the status
//	showed the burst complete, then the burst, sixteen values per 64-bit word
//	in the order they were sampled, the first in bits [3:0]. In mode 1 a
//	value is four bits of the ring's count at that sample, a count modulo
//	64: bits [3:0] of it, or with `upper` bits [5:2]. In mode 2 it is
//	{reference 1, reference 0, lane 1, lane 0}: bit 0 lane 0, bit 1 lane 1,
//	bit 2 the first reference ring (ring 4), bit 3 the second (ring 5). A
//	ring that is not in the mask reads as a constant.
//
//	Status:
//	  0  OK        everything wanted is stored
//	  1  RUNNING   entered and not finished (the host sees this only if the
//	               routine did not reach its end)
//	  2  LOCKED    mentropycfg has its lock bit set; nothing was changed
//	  3  BUSY      mnoise did not read 1 at entry (already in test mode, or
//	               not the expected CSR); nothing was changed
//	  4  PARAM     a parameter was rejected; nothing was changed
//	  5  NOTEST    test mode was not entered, or the capture block did not
//	               allow capturing in it
//	  6  TIMEOUT   no record, or no complete burst, within the idle limit:
//	               the noise source is off; what was stored before is valid
//	  7  TRAP      unexpected trap, for example an illegal instruction at the
//	               first CSR access when the image has no entropy source
//	  8  NOBLOCK   the status register at 0x1000_0840 does not identify the
//	               capture block; nothing was changed
//	  9  PERIOD    the period register did not take the value
//	  10 ABORTED   modes 1 and 2: the capture block aborted a burst, the noise
//	               source was off while it ran; the bursts stored before are
//	               valid
//	  11 NOMETER   the meter's control register did not read back as
//	               written: an image without the meter or, in mode 2, with a
//	               meter that cannot give the reference bits
//	  12 LOSSES    mode 0: more losses than allowed; the runs in the table
//	               are valid
//	  -1 the value in the file: never run
//
//	Test mode is left on every path that entered it, which puts the sampling
//	period, the ring mask and the burst source back and restarts the
//	start-up test of seed. mentropycfg is not written. mstatus and mtvec are
//	restored. All other registers used are clobbered.
//
//	Cost of a record. When records come faster than the routine takes them,
//	one record is the eight instructions from `poll` to the branch back to
//	it: two register reads (DATA0, DATA1), two stores to the buffer, and
//	srli, bne, addi, bne. In the SoC simulation that takes 56 clocks
//	(measured 2026-11-21 with records 52 clocks apart, which it cannot keep
//	up with). The other limit is the wait: a record that falls due just
//	after a poll found none is seen by the next poll and taken by the read
//	of DATA1 two instructions after it. Measured in the simulation:
//	    no loss in 400 or 600 records at every spacing tried from 58 to 256
//	    clocks (58 to 66 clock by clock), losses at 57 clocks and below.
//	On the board a store to DDR takes about 10 clocks longer than in the
//	simulation (the copy loop of getnoise_burst.S, a register read and a
//	store per word: 43.4 clocks on the board on 2026-11-19, 33.2 in the
//	simulation), and nothing else in the loop differs: about 76 clocks for
//	a record, so that about 78 is the smallest (period + 1) * (every + 1)
//	that the board keeps up with. That is an estimate, and a mean: a store
//	that has to wait for the memory controller delays one record. Below
//	about 128 clocks expect losses on the board.
//	A capture shows the cost: a poll that finds no record takes 33 clocks,
//	and at spacings of 128 and 256 clocks in the simulation the clocks
//	between two records, less 33 times the polls per record (result word
//	4), were 66: the 56 of the loop and 10 for going by way of the wait.
//	The two loops are sensitive to where they lie: see `poll` and `wait`.
//
//	Warm-up. The first pass through the record loop is fetched from memory
//	a cache line at a time, and the first poll comes about 230 clocks after
//	the start instead of 30 (simulation): at 128 clocks between records the
//	second record is lost before the first is read. So the capture is
//	preceded by a run of two records that are not kept. See `heat`.
//
//	-DROSC_SIM           no debugger: report (status << 1) | 1 through the
//	                     HTIF tohost word at 0x80001000 instead of ebreak
//	SPDX-License-Identifier: BSD-2-Clause

	.equ	CSR_MNOISE,		0x7C8
	.equ	CSR_MENTROPYCFG, 0x7C9
	.equ	CSR_MENTROPYSTAT, 0x7CA
	.equ	TOHOST,			0x80001000
	.equ	NBURST,			0x10000840		//	the capture block: system-control block + 0x40
	.equ	NB_CTRL,		0
	.equ	NB_PERIOD,		8
	.equ	NB_INDEX,		16
	.equ	NB_DATA,		24
	.equ	NB_MAGIC,		0x4b4e4231
	.equ	M_CTRL,			40				//	the meter: 0x1000_0868
	.equ	M_DATA0,		48
	.equ	M_DATA1,		56
	.equ	RUNS_MAX,		48
	.equ	WARM_TRIES,		4

	.equ	P_PERIOD,		0
	.equ	P_EVERY,		8
	.equ	P_MASK,			16
	.equ	P_COUNT,		24
	.equ	P_BUF,			32
	.equ	P_SIZE,			40
	.equ	P_IDLE,			48
	.equ	P_LOSSES,		56
	.equ	P_MODE,			64
	.equ	P_RING,			72
	.equ	P_SLOW,			80
	.equ	P_DIRECT,		88
	.equ	P_UPPER,		96
	.equ	R_STATUS,		104
	.equ	R_STORED,		112
	.equ	R_RUNS,			120
	.equ	R_LOSSES,		128
	.equ	R_POLLS,		136
	.equ	R_WORDS,		144
	.equ	R_NBCTRL,		152
	.equ	R_PERIOD_USED,	160
	.equ	R_MCTRL,		168
	.equ	R_CFG,			176
	.equ	R_STAT,			184
	.equ	R_CFG_AFTER,	192
	.equ	R_STAT_AFTER,	200
	.equ	R_NOISE_AFTER,	208
	.equ	R_NBCTRL_AFTER,	216
	.equ	R_MCTRL_AFTER,	224
	.equ	R_MCAUSE,		232
	.equ	R_MEPC,			240
	.equ	R_MCTRL_END,	248
	.equ	R_END,			256

	.equ	RUN_START,		0
	.equ	RUN_RECORDS,	8
	.equ	RUN_CYCLE0,		16
	.equ	RUN_CYCLE1,		24
	.equ	RUN_CTRL,		32
	.equ	RUN_SIZE,		40

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
	.equ	ST_NOMETER,		11
	.equ	ST_LOSSES,		12

	.option	norvc
	.option	norelax
	.section .text
	.globl	rosc_count, rosc_params, rosc_result, rosc_runs, rosc_runs_end, rosc_stop
rosc_count:
	j		start
	.balign	8
rosc_params:
	.dword	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
rosc_result:
	.dword	-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

	//	s0 block, s1 end of the records wanted (mode 0) or bursts still wanted
	//	(modes 1, 2), s2 next byte of the buffer, s3 the registers, s4 words per
	//	burst, s5 idle limit, s6 the constant 2 ("valid, no loss"), s7 where
	//	the record loop stops, s8 status, s9 "test mode was entered",
	//	s10 mstatus, s11 mtvec; a0 warm-up tries left (0: the capture itself),
	//	a1 slow, a2 bursts stored, a3 losses, a4 polls, a5 the run's entry in
	//	the table, a6 the control word, a7 runs, t3 stamp, t4 polls left,
	//	t5 return address, t6 first record of the run
start:
	lla		s0, rosc_params
	csrr	s10, mstatus
	csrci	mstatus, 8					//	no interrupts during the capture
	csrr	s11, mtvec
	lla		t0, trap
	csrw	mtvec, t0
	li		s9, 0
	li		a2, 0
	li		a3, 0
	li		a4, 0
	li		a7, 0
	li		s4, 0
	li		t0, ST_RUNNING
	sd		t0, R_STATUS(s0)
	addi	t0, s0, R_STORED
	addi	t1, s0, R_END
1:	sd		zero, 0(t0)
	addi	t0, t0, 8
	bne		t0, t1, 1b
	li		s3, NBURST
	ld		s2, P_BUF(s0)
	ld		s5, P_IDLE(s0)
	lla		a5, rosc_runs

	csrr	t0, CSR_MENTROPYCFG			//	traps if the image has no entropy source
	sd		t0, R_CFG(s0)
	csrr	t1, CSR_MENTROPYSTAT
	sd		t1, R_STAT(s0)
	li		s8, ST_LOCKED
	bltz	t0, report					//	bit 63
	li		s8, ST_BUSY
	csrr	t0, CSR_MNOISE
	li		t1, 1
	bne		t0, t1, report

	//	the capture block, which sets the period, and the size of its bursts
	li		s8, ST_NOBLOCK
	ld		t0, NB_CTRL(s3)
	sd		t0, R_NBCTRL(s0)
	srli	t1, t0, 32
	li		t2, NB_MAGIC
	bne		t1, t2, report
	srli	t1, t0, 8
	andi	t1, t1, 0xff				//	log2 of the values per burst
	addi	t1, t1, -4
	bltz	t1, report
	li		s4, 1
	sll		s4, s4, t1					//	words per burst

	//	parameters
	li		s8, ST_PARAM
	beqz	s5, report
	ld		t0, P_PERIOD(s0)
	li		t1, 255
	bgtu	t0, t1, report
	ld		t0, P_MASK(s0)
	li		t1, 0x3f
	bgtu	t0, t1, report
	ld		t0, P_EVERY(s0)
	srli	t0, t0, 16
	bnez	t0, report
	ld		t0, P_DIRECT(s0)
	ld		t1, P_UPPER(s0)
	or		t0, t0, t1
	srli	t0, t0, 1
	bnez	t0, report					//	each is 0 or 1
	ld		a0, P_COUNT(s0)
	beqz	a0, report
	ld		t2, P_SIZE(s0)
	ld		t0, P_MODE(s0)
	bnez	t0, 1f
	srli	t2, t2, 4					//	mode 0: records that fit
	bgtu	a0, t2, report
	ld		t0, P_LOSSES(s0)
	li		t1, RUNS_MAX
	bgeu	t0, t1, report
	j		2f
1:	li		t1, 2
	bgtu	t0, t1, report
	slli	t1, s4, 3
	addi	t1, t1, 16					//	modes 1 and 2: bytes per burst
	divu	t2, t2, t1
	bgtu	a0, t2, report
	li		t1, 2
	beq		t0, t1, 2f					//	mode 2 has no ring to choose
	ld		t0, P_RING(s0)
	li		t1, 5
	bgtu	t0, t1, report
	ld		t1, P_MASK(s0)
	srl		t1, t1, t0
	andi	t1, t1, 1
	beqz	t1, report					//	the ring would not run
2:

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
	ld		t0, P_PERIOD(s0)
	sd		t0, NB_PERIOD(s3)
	ld		t1, NB_PERIOD(s3)
	addi	t2, t1, 1
	sd		t2, R_PERIOD_USED(s0)
	bne		t1, t0, done

	//	the meter: every, the rings that run, the unit of the counts and what
	//	the capture block records: in mode 1 four bits of the count of a
	//	ring, in mode 2 the reference bits with lanes 0 and 1. A write that
	//	changes the rings or the unit sets the meter's loss flag: rings are
	//	switched, a ring that is switched on counts from zero, and for twelve
	//	clocks its counts are not checked. Totals from before and after such
	//	a write do not belong together, so a run is started with a second
	//	write, below, which has to come twelve clocks or more after this one.
	//	The instructions between the two take far longer, and so do those up
	//	to the start of the first burst. In modes 1 and 2, which start no
	//	run, this write has the start bit, so that the flags of the meter
	//	count from here.
	li		s8, ST_NOMETER
	ld		a6, P_EVERY(s0)
	ld		t0, P_MASK(s0)
	slli	t0, t0, 16
	or		a6, a6, t0
	ld		t0, P_DIRECT(s0)
	slli	t0, t0, 28
	or		a6, a6, t0
	mv		t2, a6
	ld		t0, P_MODE(s0)
	beqz	t0, 1f
	li		t1, 1
	slli	t1, t1, 26					//	mode 2: the reference bits
	addi	t0, t0, -1
	bnez	t0, 3f
	ld		t0, P_RING(s0)				//	mode 1: the count of this ring,
	slli	t0, t0, 23
	or		a6, a6, t0
	ld		t0, P_UPPER(s0)				//	its lower or its upper four bits
	slli	t0, t0, 27
	or		a6, a6, t0
	li		t1, 1
	slli	t1, t1, 22
3:	or		a6, a6, t1
	li		t0, 1
	slli	t0, t0, 31
	or		t2, a6, t0
1:	sd		t2, M_CTRL(s3)
	ld		t0, M_CTRL(s3)
	sd		t0, R_MCTRL(s0)
	slli	t0, t0, 35
	srli	t0, t0, 35					//	[28:0]: as written
	bne		t0, a6, done
	ld		t0, P_MODE(s0)
	bnez	t0, bursts

	//	---- mode 0: records ----
	li		t0, 1
	slli	t0, t0, 31
	or		a6, a6, t0					//	the control word with the start bit
	ld		a1, P_SLOW(s0)
	li		s6, 2
	ld		t0, P_COUNT(s0)
	slli	t0, t0, 4
	add		s1, s2, t0
	li		a0, WARM_TRIES				//	first the warm-up: see `heat`
run:
	mv		t6, s2
	ld		t0, P_BUF(s0)
	sub		t0, s2, t0
	srli	t0, t0, 4
	sd		t0, RUN_START(a5)
	csrr	t3, mcycle
	sd		a6, M_CTRL(s3)				//	start: no loss, nothing held, the record divider from zero
	sd		t3, RUN_CYCLE0(a5)
chunk:
	mv		s7, s1						//	the record loop runs to the last record wanted,
	bnez	a0, heat
	beqz	a1, poll
	addi	t0, s2, 1024				//	or, slowed down, for 64 records
	bgeu	t0, s1, poll
	mv		s7, t0
	//	The record loop. See "Cost of a record" above before adding to it. It
	//	starts at a multiple of eight bytes, as the load address is, so that
	//	its eight instructions are four fetches whatever is above it.
	.balign	8
poll:
	ld		t0, M_DATA0(s3)				//	valid, loss, sequence number, rings 2..0
	srli	t2, t0, 62
	bne		t2, s6, wait				//	anything but a record without the loss flag
take:
	ld		t1, M_DATA1(s3)				//	lane bits, rings 5..3; this read takes the record
store:
	sd		t0, 0(s2)
	sd		t1, 8(s2)
	addi	s2, s2, 16
	bne		s2, s7, poll
	bnez	a0, warm
	beq		s2, s1, full
	mv		t0, a1						//	slowed down: let records go by
1:	addi	t0, t0, -1
	bnez	t0, 1b
	j		chunk
	//	No record yet, or the loss flag. A wait for one record is bounded.
	//	The loop below starts four bytes after a multiple of eight. Measured
	//	in the SoC simulation: with it four bytes further on, records 58 to
	//	60 clocks apart are lost, and the smallest spacing without losses is
	//	62 clocks instead of 58.
	.balign	8
wait:
	mv		t4, s5
1:	bnez	t2, lost					//	t2 is not 2 here: 1 and 3 have the loss flag
	addi	a4, a4, 1
	addi	t4, t4, -1
	beqz	t4, expired
	ld		t0, M_DATA0(s3)
	srli	t2, t0, 62
	bne		t2, s6, 1b
	ld		t1, M_DATA1(s3)				//	taken here, not after a jump: the meter is free two instructions after the poll
	j		store
lost:
	//	The run has ended with the last record stored. The record that is
	//	held now, if there is one, may not follow it: it is not read.
	bnez	a0, cold
	addi	a3, a3, 1
	jal		t5, close
	li		s8, ST_LOSSES
	ld		t0, P_LOSSES(s0)
	bgtu	a3, t0, done
	j		run
expired:
	jal		t5, close
	li		s8, ST_TIMEOUT
	j		done
full:
	jal		t5, close
	li		s8, ST_OK
	j		done
	//	The warm-up. The first pass through the code above is fetched from
	//	memory a cache line at a time, which takes longer than a record may
	//	have to wait: in the SoC simulation the first poll comes about 230
	//	clocks after the start. So the capture begins with a run of two
	//	records that are not kept, the first found by way of the wait, so that
	//	both ways to a record have been taken once. A loss in it is not one of
	//	the capture's: it is tried again, WARM_TRIES times in all, and then
	//	the capture begins whatever happened.
heat:
	addi	s7, s2, 32
	bleu	s7, s1, 1f
	mv		s7, s1						//	one record is wanted: one is enough
1:	li		t2, 0
	j		wait
cold:
	addi	a0, a0, -1
	ld		s2, P_BUF(s0)
	j		run
warm:
	li		a0, 0
	li		a4, 0
	ld		s2, P_BUF(s0)				//	the records of the warm-up are overwritten
	j		run
	//	The end of a run: the stamp, the control register with its flags, the
	//	number of records. A run without a record leaves no entry.
close:
	csrr	t0, mcycle
	sd		t0, RUN_CYCLE1(a5)
	ld		t0, M_CTRL(s3)
	sd		t0, RUN_CTRL(a5)
	sub		t0, s2, t6
	srli	t0, t0, 4
	sd		t0, RUN_RECORDS(a5)
	beqz	t0, 1f
	addi	a5, a5, RUN_SIZE
	addi	a7, a7, 1
1:	jr		t5

	//	---- modes 1 and 2: bursts of what the meter gives the capture block, as in getnoise_burst.S ----
bursts:
	ld		s1, P_COUNT(s0)
burst:
	li		s8, ST_TIMEOUT
	csrr	t3, mcycle
	li		t0, 1
	sd		t0, NB_CTRL(s3)				//	start; the burst begins with the next sample
	mv		t4, s5
1:	ld		t0, NB_CTRL(s3)
	addi	a4, a4, 1
	andi	t1, t0, 2					//	done
	bnez	t1, copy
	andi	t1, t0, 64					//	aborted
	li		s8, ST_ABORTED
	bnez	t1, done
	li		s8, ST_TIMEOUT
	addi	t4, t4, -1
	bnez	t4, 1b
	j		done
copy:
	csrr	t0, mcycle
	sd		t3, 0(s2)
	sd		t0, 8(s2)
	addi	s2, s2, 16
	sd		zero, NB_INDEX(s3)
	mv		t1, s4
2:	ld		t0, NB_DATA(s3)				//	the word at the index; the index moves on
	sd		t0, 0(s2)
	addi	s2, s2, 8
	addi	t1, t1, -1
	bnez	t1, 2b
	addi	a2, a2, 1
	addi	s1, s1, -1
	bnez	s1, burst
	li		s8, ST_OK

	//	---- leave test mode: the period, the meter and the capture block are reset with it ----
done:
	beqz	s9, report
	li		s9, 0						//	a trap from here on ends at finish
	ld		t0, M_CTRL(s3)
	sd		t0, R_MCTRL_END(s0)
	csrw	CSR_MNOISE, zero
report:
	csrr	t0, CSR_MNOISE
	sd		t0, R_NOISE_AFTER(s0)
	csrr	t0, CSR_MENTROPYCFG
	sd		t0, R_CFG_AFTER(s0)
	csrr	t0, CSR_MENTROPYSTAT
	sd		t0, R_STAT_AFTER(s0)
	ld		t0, NB_CTRL(s3)
	sd		t0, R_NBCTRL_AFTER(s0)
	ld		t0, M_CTRL(s3)
	sd		t0, R_MCTRL_AFTER(s0)
finish:
	ld		t0, P_MODE(s0)
	bnez	t0, 1f
	ld		t0, P_BUF(s0)				//	mode 0: the records are what the buffer pointer passed
	sub		a2, s2, t0
	srli	a2, a2, 4
1:	sd		a2, R_STORED(s0)
	sd		a7, R_RUNS(s0)
	sd		a3, R_LOSSES(s0)
	sd		a4, R_POLLS(s0)
	sd		s4, R_WORDS(s0)
	csrw	mtvec, s11
	csrw	mstatus, s10
	sd		s8, R_STATUS(s0)
#ifdef ROSC_SIM
	slli	t0, s8, 1
	ori		t0, t0, 1
	li		t1, TOHOST
	sd		t0, 0(t1)
#endif
rosc_stop:
#ifndef ROSC_SIM
	ebreak								//	the debugger takes over here
#endif
	j		rosc_stop

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

	.balign	8
rosc_runs:
	.fill	RUNS_MAX * RUN_SIZE, 1, 0
rosc_runs_end:
