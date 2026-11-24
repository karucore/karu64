//	karu_rosc_meter.v
//	=== Phase meter of the ring oscillators, for the measurement of each
//	ring's own jitter.
//
//	The noise source (karu_rosc_rng.v) counts the periods of every ring,
//	modulo 64, and shows the counts in every clock cycle. THE UNIT OF A
//	COUNT, AND SO OF EVERY TOTAL HERE, IS TWO RING PERIODS: the source's
//	counters count each ring divided by two. With CTRL[28] set (direct
//	counting, a diagnostic mode of the source) the unit is one ring period.
//	A host multiplies by the unit. This block turns
//	the counts into running totals and, at every n-th raw sample, records the
//	totals of all rings together with the lane bits of that sample. From a
//	series of such records the host has each ring against the clock and
//	every pair of rings against each other, and the difference of two rings
//	cancels what they share (doc/zkr-followup-plan.md, Z7). The block also
//	says which rings run, and can put one ring's count, or the bits of the
//	reference rings, in place of the symbol that the burst capture records
//	(karu_noise_burst.v), one value per clock: the count as a check of the
//	counter itself, the reference bits as a measurement of lane 0 against
//	rings of its own kind that does not use the counters. It is an FPGA
//	measurement aid next to rtl/karu_entropy.v, like the burst capture, not
//	part of the entropy source.
//
//	Everything here belongs to the test mode of the entropy block. "Active"
//	below means test_i set and lock_i clear: noise_test (mnoise) is set and
//	mentropycfg is not locked.
//
//	  * While not active, every register reads zero, writes are ignored,
//	    ring_en_o is op_mask_i, burst_sym_o is rng_b_i, and all state of
//	    this block (configuration, divider, totals, record, flags) is held
//	    at its reset value. So seed, the health tests and the burst capture
//	    see the noise source exactly as without this block, and nothing is
//	    carried from normal operation into test mode or back.
//	  * In test mode seed is in BIST and delivers nothing, so nothing that
//	    is recorded here is also delivered as entropy.
//
//	Test mode can only be entered from M-mode (or Debug Mode), through
//	mnoise. The registers themselves have no such protection.
//
//	Totals. In every clock cycle, for each ring r, the difference of its
//	count to the count of the cycle before, d = (cnt_i[r] - previous) mod
//	64, is added to a 20-bit total that runs freely, modulo 2^20. The first
//	clock after becoming active only loads `previous`: the totals start at
//	zero there. This is right as long as the count advances by fewer than 64
//	per clock. A count that the noise source marks as not readable
//	(cnt_bad_i) repeats its previous value, so nothing is added in that
//	cycle and the next good count carries the difference. A ring that is
//	switched off has a count of zero from then on: its total takes that one
//	step, modulo 64, and then stands still.
//
//	Records. The block counts rng_val_i strobes, and at every `every`-th
//	one it takes a record: the six totals, including the counts of that
//	cycle, and rng_b_i of that cycle. By the alignment of the noise source,
//	in the cycle of a symbol every count is the one captured at the clock
//	edge at which the symbol's bits were sampled, so the totals and the bits
//	of a record belong to the same clock edge. One record is held. It is
//	held until it is taken by a read of DATA1 and is never overwritten: the
//	host reads it with two bus reads, DATA0 and then DATA1, and the two
//	words must belong together. A record that falls due while one is held
//	is dropped, and the loss flag is set and stays set. A record that falls
//	due in the very cycle of the read that takes the held one is stored, as
//	mnoise does for symbols. A 2-bit sequence number counts the records
//	that fell due, dropped or not, and is stored with a record: consecutive
//	stored records with numbers that do not follow each other have a gap
//	between them. The totals run on through a dropped record, so the next
//	stored one is a correct snapshot again.
//
//	Consistency. So that a wrong count cannot pass silently, every count is
//	checked against the one before: the increment of a ring in this clock,
//	d, must not differ from its increment in the clock before by more than
//	2, modulo 64. A count is the whole part of the ring's phase, read with
//	an uncertainty of less than one count that depends on which flop of the
//	counter was changing. If the Johnson bits of the counter reach the
//	sampling flops with a skew of s periods of the counter's clock, and the
//	ring's rate changes by e counts per clock from one clock to the next,
//	the two increments differ by less than 2 + 2s + e: by at most 2 as long
//	as 2s + e is not above 1. A count that is wrong by sixteen, the one
//	error the counter's decoding can make, differs by 16. (One period lost
//	or gained by the divider differs by 1 and is not seen here. Nor is a
//	divider that runs steadily at a wrong ratio: its increments are steady
//	too. Only a miscount that changes by more than 2 from one clock to the
//	next is seen; the ratio itself is for the board's checks, rosc_own.py
//	--pair and --bits.) The check applies to a
//	ring of the mask from its third readable sample in a row, and not in
//	the HOLD = 12 clocks after the ring was switched on by a mask write,
//	after the counting mode was written or after becoming active (a ring
//	that restarts shows its first count eight clocks after the write, and
//	its first whole increment a clock later); the start bit restarts the
//	three samples. A clock in which a ring of the mask is not readable
//	(cnt_bad_i) or not consistent is counted in CTRL[63:48], one per clock
//	however many rings, and sets the ring's bit in CTRL[47:42], which stays
//	set until the start bit.
//
//	For the host: totals are modulo 2^20, so the counts of a ring between
//	two records are (total2 - total1) mod 2^20, and its count per clock is
//	that divided by the clocks between the records, `every` times the
//	sampling period times the difference of the sequence numbers; times the
//	unit, that is ring periods. It is unambiguous while fewer than 2^20
//	counts lie between the records (at 36 periods per clock: 58,254 clocks,
//	in direct mode 29,127) and fewer than four records fell due.
//
//	Registers (reg_*addr_i, 64 bits each; address 3 reads zero):
//
//	  0  CTRL
//	       write, only when active:
//	         [15:0]   every - 1: a record at every (this + 1)-th strobe
//	         [21:16]  ring mask while active: bit r set lets ring r run
//	         [22]     source of burst_sym_o: 1 a ring's count
//	         [25:23]  the ring whose count that is (6 and 7: zero)
//	         [26]     source of burst_sym_o, if [22] is clear: 1 the
//	                  reference bits with lanes 0 and 1; both clear, the
//	                  lane bits
//	         [27]     with [22]: 1 the upper four bits of the count,
//	                  cnt[5:2], in which an error of sixteen shows; 0 the
//	                  lower four, cnt[3:0]
//	         [28]     direct counting: cnt_direct_o to the noise source.
//	                  The unit of the counts is then one ring period
//	         [31]     start: clears loss, valid, the held record, the
//	                  sequence number, the count and the flags of [63:42];
//	                  restarts the divider and the consistency check
//	       On becoming active: every - 1 = 0, mask = op_mask_i, [28:22] 0.
//	       A write that changes the ring mask or [28] pulses respace_o and
//	       sets loss, also when it has the start bit: a ring that is switched
//	       off has its counter cleared and one that is switched on starts
//	       from zero, and a change of the counting mode switches every ring
//	       off for three clocks, so totals on either side of the change do
//	       not belong together. Start a run with a second write, twelve or
//	       more clocks after it.
//	       read:
//	         [28:0]   as written
//	         [37:32]  op_mask_i
//	         [40]     valid: a record is held
//	         [41]     loss
//	         [47:42]  bit r: since the last start, ring r had a count that
//	                  was not readable or not consistent
//	         [63:48]  the clock cycles, since the last start, in which a
//	                  ring of the mask had such a count; stops at 65535
//	  1  DATA0, read: [63] valid, [62] loss, [61:60] the record's sequence
//	     number, [59:40] total of ring 2, [39:20] ring 1, [19:0] ring 0.
//	     Reading it changes nothing.
//	  2  DATA1, read: [63:60] the record's lane bits, [59:40] total of ring
//	     5, [39:20] ring 4, [19:0] ring 3. A read while valid takes the
//	     record: valid is cleared, the contents stay until the next record.
//
//	burst_sym_o is what the burst capture records in place of rng_b_i. With
//	CTRL[22] set it is four bits of the chosen ring's cnt_i: the low four,
//	which is the position of the ring's Johnson counter, or with CTRL[27]
//	the upper four. With CTRL[26] set and
//	[22] clear it is {ref_b_i[1], ref_b_i[0], rng_b_i[1], rng_b_i[0]}: lanes
//	0 and 1 with the two reference rings above them, all four sampled at one
//	clock edge. Nothing is registered again here: cnt_i and ref_b_i come
//	from registers of the noise source just as rng_b_i does, and in the
//	cycle of rng_val_i each is of the edge at which the symbol was sampled,
//	so the capture takes them alike.
//
//	respace_o is a one-cycle pulse when rings are switched: with a write
//	that changes the mask or the counting mode, and in the first cycle after
//	the active state has ended if the mask was not op_mask_i or the mode was
//	direct. It ends a run of mnoise symbols, as a change of the sampling
//	period does.
//
//	reg_re_i marks the cycle in which a read of reg_raddr_i is taken;
//	reg_rdata_o is combinational from reg_raddr_i and registers only.
//	SPDX-License-Identifier: BSD-2-Clause

module karu_rosc_meter #(
	parameter integer RINGS = 6,				//	rings of the noise source (at most 6)
	parameter integer LANES = 4					//	of them on the symbol bus (at most 4); one or two references
) (
	input  wire					clk,
	input  wire					rst,

	//	entropy block and noise source
	input  wire					test_i,			//	noise_test is set: seed is in BIST
	input  wire					lock_i,			//	mentropycfg is locked
	input  wire					rng_val_i,		//	raw sample strobe
	input  wire [LANES-1:0]		rng_b_i,		//	lane bits of that sample
	input  wire [RINGS-LANES-1:0]	ref_b_i,	//	the reference rings' bits of that sample
	input  wire [6*RINGS-1:0]	cnt_i,			//	the noise source's cnt_o
	input  wire [RINGS-1:0]		cnt_bad_i,		//	the noise source's cnt_bad_o
	input  wire [RINGS-1:0]		op_mask_i,		//	static strap: the rings that run outside test mode
	output wire [RINGS-1:0]		ring_en_o,		//	to the noise source's ring_en_i
	output wire					cnt_direct_o,	//	to the noise source's cnt_direct_i
	output wire [3:0]			burst_sym_o,	//	to the burst capture, in place of rng_b_i
	output wire					respace_o,		//	to the entropy block: the set of running rings changes

	//	register port
	input  wire					reg_re_i,
	input  wire [1:0]			reg_raddr_i,
	output wire [63:0]			reg_rdata_o,
	input  wire					reg_we_i,
	input  wire [1:0]			reg_waddr_i,
	input  wire [63:0]			reg_wdata_i
);
	localparam [1:0] R_CTRL = 2'd0, R_DATA0 = 2'd1, R_DATA1 = 2'd2;
	localparam integer TW = 20;					//	bits of a total
	localparam [3:0] HOLD = 4'd12;				//	clocks without the consistency check after a ring restarts

	wire active = test_i && !lock_i;

	reg [15:0]			every_q;				//	strobes per record, less one
	reg [RINGS-1:0]		mask_q;
	reg					src_q, ref_q;			//	the burst symbol is a count; else the reference bits
	reg					hi_q, dir_q;			//	the count's upper bits; direct counting
	reg [2:0]			sel_q;
	reg [15:0]			div_q;					//	strobes since the last record
	reg					seen_q;					//	prev_q holds the counts of the cycle before
	reg [6*RINGS-1:0]	prev_q;
	reg [TW*RINGS-1:0]	tot_q;
	reg [TW*RINGS-1:0]	rec_tot_q;				//	the held record
	reg [LANES-1:0]		rec_b_q;
	reg [1:0]			rec_seq_q;
	reg [1:0]			seq_q;					//	records that fell due, modulo 4
	reg					valid_q, loss_q;
	reg [15:0]			bad_q;					//	clocks with a count that is not readable or not consistent
	reg [RINGS-1:0]		flag_q;					//	the rings that had one
	reg [6*RINGS-1:0]	dprev_q;				//	the increments of the clock before
	reg [2*RINGS-1:0]	run_q;					//	readable samples in a row before this one, up to 2
	reg [4*RINGS-1:0]	warm_q;					//	clocks still to wait after a restart

	wire				ctrl_we = active && reg_we_i && reg_waddr_i == R_CTRL;
	wire				start   = ctrl_we && reg_wdata_i[31];
	wire [RINGS-1:0]	mask_w  = reg_wdata_i[16 +: RINGS];
	wire				remask  = ctrl_we && (mask_w != mask_q);
	wire				redir   = ctrl_we && (reg_wdata_i[28] != dir_q);
	wire				strobe  = active && rng_val_i;
	wire				rec     = strobe && (div_q >= every_q);		//	a record falls due
	wire				take    = active && valid_q && reg_re_i && reg_raddr_i == R_DATA1;
	wire				store   = rec && (!valid_q || take);

	//	the totals with the counts of this cycle, and the check of each count
	wire [TW*RINGS-1:0]	tot_n;
	wire [6*RINGS-1:0]	d_all;					//	the increments of this clock
	wire [RINGS-1:0]	odd;					//	ring r: not readable or not consistent in this clock
	genvar r;
	generate for (r = 0; r < RINGS; r = r + 1) begin : g_tot
		wire [5:0]		d    = cnt_i[6*r +: 6] - prev_q[6*r +: 6];		//	modulo 64
		wire [TW-1:0]	step = {{(TW-6){1'b0}}, d};
		assign tot_n[TW*r +: TW] = tot_q[TW*r +: TW] + (seen_q ? step : {TW{1'b0}});
		assign d_all[6*r +: 6] = d;
		//	this increment against the one before: more than 2 apart, modulo 64
		wire [5:0]		dd   = d - dprev_q[6*r +: 6];
		wire			far  = (dd > 6'd2) && (dd < 6'd62);
		//	at least the third readable sample in a row, and no restart pending
		wire			ripe = (run_q[2*r +: 2] == 2'd2) && (warm_q[4*r +: 4] == 4'd0);
		assign odd[r] = mask_q[r] && (cnt_bad_i[r] || (ripe && far));
	end endgenerate
	wire				bad     = |odd;

	integer k;
	always @(posedge clk)
		if (rst || !active) begin
			every_q <= 16'd0; mask_q <= op_mask_i; src_q <= 1'b0; sel_q <= 3'd0; div_q <= 16'd0;
			ref_q <= 1'b0;
			hi_q <= 1'b0;
			dir_q <= 1'b0;
			flag_q <= {RINGS{1'b0}}; dprev_q <= {(6*RINGS){1'b0}}; run_q <= {(2*RINGS){1'b0}}; warm_q <= {RINGS{HOLD}};
			seen_q <= 1'b0; prev_q <= {(6*RINGS){1'b0}}; tot_q <= {(TW*RINGS){1'b0}};
			rec_tot_q <= {(TW*RINGS){1'b0}}; rec_b_q <= {LANES{1'b0}}; rec_seq_q <= 2'd0;
			seq_q <= 2'd0; valid_q <= 1'b0; loss_q <= 1'b0; bad_q <= 16'd0;
		end else begin
			seen_q <= 1'b1;
			prev_q <= cnt_i;
			tot_q  <= tot_n;
			if (strobe)
				div_q <= rec ? 16'd0 : div_q + 16'd1;
			if (rec)
				seq_q <= seq_q + 2'd1;
			if (take)
				valid_q <= 1'b0;
			if (store) begin
				rec_tot_q <= tot_n; rec_b_q <= rng_b_i; rec_seq_q <= seq_q; valid_q <= 1'b1;
			end
			if (rec && !store)					//	one is held: this one is dropped
				loss_q <= 1'b1;
			if (bad && bad_q != 16'hffff)
				bad_q <= bad_q + 16'd1;
			flag_q  <= flag_q | odd;
			dprev_q <= d_all;
			for (k = 0; k < RINGS; k = k + 1) begin
				if (warm_q[4*k +: 4] != 4'd0)
					warm_q[4*k +: 4] <= warm_q[4*k +: 4] - 4'd1;
				if (!mask_q[k] || cnt_bad_i[k] || warm_q[4*k +: 4] != 4'd0)
					run_q[2*k +: 2] <= 2'd0;
				else if (run_q[2*k +: 2] != 2'd2)
					run_q[2*k +: 2] <= run_q[2*k +: 2] + 2'd1;
			end
			if (ctrl_we) begin
				every_q <= reg_wdata_i[15:0];
				mask_q  <= mask_w;
				src_q   <= reg_wdata_i[22];
				sel_q   <= reg_wdata_i[25:23];
				ref_q   <= reg_wdata_i[26];
				hi_q    <= reg_wdata_i[27];
				dir_q   <= reg_wdata_i[28];
				for (k = 0; k < RINGS; k = k + 1)	//	a ring that is switched on, or all with the mode
					if ((mask_w[k] && !mask_q[k]) || redir)
						warm_q[4*k +: 4] <= HOLD;
			end
			if (start) begin					//	wins over a record of the same cycle
				div_q <= 16'd0; seq_q <= 2'd0; valid_q <= 1'b0; loss_q <= 1'b0; bad_q <= 16'd0;
				rec_tot_q <= {(TW*RINGS){1'b0}}; rec_b_q <= {LANES{1'b0}}; rec_seq_q <= 2'd0;
				flag_q <= {RINGS{1'b0}}; run_q <= {(2*RINGS){1'b0}};
			end
			if (remask || redir)				//	wins over the start of the same write
				loss_q <= 1'b1;
		end

	assign ring_en_o = active ? mask_q : op_mask_i;
	assign cnt_direct_o = active && dir_q;
	assign respace_o = remask || redir || (!active && (mask_q != op_mask_i || dir_q));

	//	the burst capture's symbol
	wire [47:0]	cnt_pad = {{(48-6*RINGS){1'b0}}, cnt_i};
	wire [5:0]	cnt_ring = cnt_pad[6*sel_q +: 6];
	wire [3:0]	cnt_sel = hi_q ? cnt_ring[5:2] : cnt_ring[3:0];
	wire [4:0]	sym_pad = {{(5-LANES){1'b0}}, rng_b_i};
	wire [2:0]	ref_pad = {{(3-(RINGS-LANES)){1'b0}}, ref_b_i};
	wire [3:0]	sym_ref = {ref_pad[1:0], sym_pad[1:0]};
	assign burst_sym_o = !active ? sym_pad[3:0] : src_q ? cnt_sel : ref_q ? sym_ref : sym_pad[3:0];

	//	registers; fields of rings and lanes that do not exist read zero
	wire [6:0]		mask_pad = {{(7-RINGS){1'b0}}, mask_q};
	wire [6:0]		opm_pad  = {{(7-RINGS){1'b0}}, op_mask_i};
	wire [139:0]	tot_pad  = {{(140-TW*RINGS){1'b0}}, rec_tot_q};
	wire [4:0]		b_pad    = {{(5-LANES){1'b0}}, rec_b_q};
	wire [6:0]		flag_pad = {{(7-RINGS){1'b0}}, flag_q};
	wire [63:0] ctrl  = {bad_q, flag_pad[5:0], loss_q, valid_q, 2'b0, opm_pad[5:0], 3'b0, dir_q, hi_q, ref_q, sel_q, src_q, mask_pad[5:0], every_q};
	wire [63:0] data0 = {valid_q, loss_q, rec_seq_q, tot_pad[59:0]};
	wire [63:0] data1 = {b_pad[3:0], tot_pad[119:60]};
	assign reg_rdata_o = !active                ? 64'b0 :
						 (reg_raddr_i == R_CTRL)  ? ctrl  :
						 (reg_raddr_i == R_DATA0) ? data0 :
						 (reg_raddr_i == R_DATA1) ? data1 : 64'b0;

	//	Only some bits of a written value are used.
	wire unused = &{reg_wdata_i[63:32], reg_wdata_i[30:29], tot_pad[139:120], mask_pad[6], opm_pad[6], b_pad[4], sym_pad[4], ref_pad[2],
					flag_pad[6], 1'b0};

`ifndef KARU_NO_ASSERT
	// synthesis translate_off
	initial if (RINGS > 6 || LANES < 1 || LANES > 4 || RINGS - LANES < 1 || RINGS - LANES > 2) begin
		$display("ASSERT: karu_rosc_meter: LANES must be 1..4 and RINGS one or two more, at most 6"); $fatal;
	end
	reg						active_d, chk_q, held_d;
	reg [RINGS-1:0]			opm_d;
	reg [TW*RINGS+LANES+1:0] rec_d;
	always @(posedge clk) begin
		active_d <= active;
		chk_q    <= !rst;
		opm_d    <= op_mask_i;
		held_d   <= active && valid_q && !take && !start;	//	a record that must still be there in the next cycle
		rec_d    <= {rec_seq_q, rec_b_q, rec_tot_q};
		if (chk_q && !rst) begin
			if (!active_d && (every_q != 16'd0 || mask_q != opm_d || src_q || ref_q || hi_q || dir_q || sel_q != 3'd0 || div_q != 16'd0 || seen_q
					|| flag_q != {RINGS{1'b0}} || run_q != {(2*RINGS){1'b0}} || warm_q != {RINGS{HOLD}}
					|| tot_q != {(TW*RINGS){1'b0}} || rec_tot_q != {(TW*RINGS){1'b0}} || rec_b_q != {LANES{1'b0}}
					|| seq_q != 2'd0 || rec_seq_q != 2'd0 || valid_q || loss_q || bad_q != 16'd0)) begin
				$display("ASSERT: karu_rosc_meter: state kept outside test mode"); $fatal;
			end
			if (!active && (ring_en_o != op_mask_i || cnt_direct_o || burst_sym_o != sym_pad[3:0] || reg_rdata_o != 64'b0)) begin
				$display("ASSERT: karu_rosc_meter: the rings, the counting mode, the burst symbol or a register differ outside test mode"); $fatal;
			end
			if (held_d && active_d && active && (!valid_q || rec_d != {rec_seq_q, rec_b_q, rec_tot_q})) begin
				$display("ASSERT: karu_rosc_meter: a held record changed before it was taken"); $fatal;
			end
		end
	end
	// synthesis translate_on
`endif
endmodule
