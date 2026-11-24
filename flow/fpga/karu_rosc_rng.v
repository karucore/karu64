//	karu_rosc_rng.v
//	=== Ring-oscillator noise source for FPGA, one sampled ring per raw bit.
//
//	This is Fig. 1 of arXiv:2102.02196: an odd number of inverters in a
//	free-running loop with an enable gate, sampled by one D flip-flop on the
//	system clock. Nothing else touches a bit: rings are not combined, and
//	there is no de-biasing and no whitening, so each output lane is one
//	(F, D, sigma^2) source of that paper's model. Whether the lanes are
//	independent of each other is not a property of this file; it has to be
//	measured on the routed design.
//
//	The ports are those of OpenTitan's raw noise source (the "rng" block of
//	its analog sensor top): an enable, a one-cycle valid pulse per symbol and
//	a RNG_BUS_WIDTH = 4 symbol. There is no back-pressure. rng_fips_i is
//	accepted and has no effect, as in OpenTitan's open model.
//
//	Six ports are not OpenTitan's.
//
//	rng_div_i is the sampling period in clock cycles, less one (0 to 255: a
//	symbol every 1 to 256 cycles). The rings run on regardless of it; it only
//	says which of the sampling flop's values become symbols. At a period of
//	one cycle rng_val_o stays high. A change takes effect at once: the next
//	symbol comes no later than the new period after it. The entropy source
//	ties this to a constant, except in its test mode (flow/fpga/
//	karu_entropy_src.v, karu_noise_burst.v).
//
//	ring_en_i says which rings run: ring r oscillates only while rng_en_i is
//	set, rst is clear and ring_en_i[r] is set. There are R = STREAMS + REFS
//	rings. Ring r < STREAMS is lane r, with STAGES + 2*r inverters. Ring
//	STREAMS + t is reference ring t: built exactly like ring 0, never on the
//	symbol bus, there only to be measured against (doc/zkr-followup-plan.md,
//	Z7). A ring that is off reads as a constant on its lane.
//
//	ref_b_o is the sampled bit of every reference ring. A reference has a
//	sampling flop like a lane's, so that it is loaded exactly as lane 0 is
//	(its next stage, the sampling flop, the clock of its counter), and its
//	bit is registered with the same strobe as rng_b_o: in the cycle of
//	rng_val_o, ref_b_o[t] is reference t as sampled at the clock edge at
//	which the lanes were. The bits give a measurement of lane 0 against its
//	own kind that does not depend on the counters. They are no part of a
//	symbol and never reach seed.
//
//	cnt_o and cnt_bad_o are the measurement of the rings themselves: for
//	every ring a counter, modulo 64, read into the clock domain in every
//	cycle (karu_rosc_cnt below; ring r in cnt_o[6*r +: 6]). THE UNIT OF A
//	COUNT IS TWO RING PERIODS: a ring is too fast to clock a flip-flop, so
//	a counter counts the ring divided by two. With cnt_direct_i set the unit
//	is one ring period: the counter is then clocked by the ring itself,
//	which is outside what the part guarantees for a flip-flop when the ring
//	is fast; that mode is a diagnostic and a cross-check of the divider on
//	the board (the two modes must give counts in the ratio 2), never the
//	measurement a bound rests on. Whoever reads the counts multiplies by the
//	unit. The
//	counters are always there and always connected, so that a ring is
//	loaded the same whether or not anything reads them. Nothing of a counter
//	reaches rng_b_o. A count must advance by fewer than 64 per clock cycle
//	for a consumer to unwrap it (flow/fpga/karu_rosc_meter.v); the 3-stage
//	rings make 16 to 36 periods per clock in the timing model.
//
//	cnt_direct_i may change at any time. The mode that the counters see is
//	a register of this module, and it changes only while every ring is off
//	and every counter in clear, because a change while a ring runs could
//	make a runt clock pulse. When the input differs from the register, all
//	rings are switched off by the sequence below, the register changes one
//	clock later, and the rings come back: the gates are closed for three
//	clocks and the counters in clear for two, and every count starts from
//	zero in the new unit. The lanes read constants meanwhile, as when a ring
//	is switched off by ring_en_i. Outside the entropy block's test mode the
//	input is constant 0.
//
//	Alignment of the counts with the symbols. In the clock cycle in which
//	rng_val_o is 1, cnt_o of every ring is the count as captured at the same
//	clock edge at which the first sampling flop (samp_q) captured the bits
//	now on rng_b_o and ref_b_o. Both paths have three register stages after
//	that edge: samp_q, meta_q, rng_b_o or ref_b_o for a bit and gm_q, gs_q,
//	cnt_o for a count.
//	cnt_o is updated in every clock cycle, not only with a symbol. In direct
//	mode the count steps on the rising edge of the ring's output, and the
//	bit is that output: a ring that has just been counted reads 1. Divided
//	by two, it steps on every second rising edge.
//
//	Switching a ring. Each ring has two flops of its own: clr_q holds the
//	ring's counter in clear while the ring is off, and en_q is the ring's
//	gate. The gate is thus a two-input function of one local flop whatever
//	drives rng_en_i and ring_en_i (otherwise synthesis folds upstream logic
//	into the ring's first stage). Switching on, the clear is released first
//	and the gate opens one clock later, so that the ring's first edge finds
//	the counter out of clear. Switching off, the gate closes and the clear
//	is applied together, and the clear lasts at least a clock, so that the
//	ring has stopped before it is released; the gate stays closed for at
//	least two clocks. Every run of a ring is therefore counted from zero,
//	every count sampled while the gate is open is a count of that run, and
//	a ring that is off has a count of zero.
//
//	Vivado: the ring nets carry DONT_TOUCH, so every inverter stays a LUT,
//	and ALLOW_COMBINATORIAL_LOOPS, which turns the loop check LUTLP-1 (an
//	error at bitstream generation) into the warning LUTLP-2. The timing
//	report then lists the rings' loops, and those of the dividers' latches
//	(flow/fpga/rosc_constraints.tcl marks them as allowed). Placement of the rings is set in
//	the constraints (flow/fpga/rosc_constraints.tcl). The nets are
//	g_rings.g_ring[s].inv[*] for lane s and g_rings.g_ref[t].inv[*] for
//	reference t; the counters are the instances g_rings.g_cnt[r].cnt.
//
//	Simulation: the loops cannot be simulated. With SIM = 1 each ring is a
//	fixed-point model of the same sampling process, x <- x + F + noise
//	(mod 1), bit = (x < 1/2), driven by a deterministic generator. It is a
//	stand-in for tests and carries no entropy. Plusargs for fault injection:
//	+rosc_stuck=<mask> holds the lanes in the mask at 1, and +rosc_slow=<n>
//	divides the jitter by 2^n. With SIM = 2 the generator is not reset and
//	runs whether or not the source is enabled, as physical noise does, so
//	that two resets do not give the same symbols.
//
//	The default model gives every lane a full-cycle random kick per clock, so
//	its bits have no memory at any sampling period. For tests of the
//	characterisation (burst capture and its analysis) there is a second
//	model with known parameters, selected by +rosc_jitter=<n>: lane m
//	advances by its mean step F plus a zero-mean, roughly Gaussian value of
//	standard deviation (m + 1) * 2^n * 37837 / 2^32 cycles per clock, drawn
//	separately for each lane. +rosc_duty=<hex> sets the duty cycle D as a
//	32-bit fraction (default 80000000, one half). test/dbg/board/
//	noise_model.py is the Python copy of both models.
//
//	The model of the counts and of the reference rings. Ring r has a 32-bit
//	phase x_r, the fraction of a period, and a count of whole periods n_r.
//	In a clock in which the ring runs, {n_r, x_r} <- {n_r, x_r} + A_r, with
//	the advance A_r in units of 2^-32 periods; the lane bit is (x_r < D) and
//	the count is floor(n_r / 2) mod 64, or n_r mod 64 in direct mode, zero
//	while the ring is off. A reference's bit is
//	(x_r < D) as well; +rosc_stuck does not reach it. A ring that is off
//	keeps its phase, so its bit stays as it was (on the FPGA: 1), and n_r
//	starts from zero when it is switched on again. With
//
//	  F_r   the mean step: 0a3d70a3 * (2r + 3) for lane r (0.12, 0.20, 0.28,
//	        0.36 periods), and for reference t lane 0's step F_0 changed by
//	        +3 (t even) or -2 (t odd) times (1 + t/2) * floor(F_0 / 1000):
//	        +0.3 % and -0.2 % for the two references
//	  c_r   r + 1 for lane r, 1 for a reference: the scale of its own noise
//	  W_r   floor(3 * turns / stages_r) whole periods, stages_r the ring's
//	        inverters (3, 5, 7, 9, 3, 3), turns from +rosc_turns=<n> (0)
//	  g_r, h  sums of four 16-bit fields of prng * (an odd constant), less
//	        131070: zero mean, standard deviation 37837; g_r has a constant
//	        of its own for each ring and h is common to all rings
//
//	the default model has A_r = W_r * 2^32 + ((F_r + c_r * noise + (byte r
//	of prng) * 2^24) mod 2^32), and the model of +rosc_jitter=<j> has
//
//	  S_r = W_r * 2^32 + F_r + c_r * g_r * 2^j
//	        + floor((W_r * 2^32 + F_r) * h * 2^n / 2^32)     [+rosc_shared=<n>]
//	  A_r = S_r if S_r >= 0, else S_r mod 2^32
//
//	(a ring does not run backwards). x_r is the same sequence as without the
//	new plusargs in every case: they add whole periods only, except for the
//	shared term. +rosc_turns makes the counts advance at the rate of real
//	rings: ring 0 by about n periods per clock, the longer rings in
//	proportion to their length. +rosc_shared is a fractional frequency
//	modulation common to all rings, as supply or clock noise is: in each
//	clock every ring's advance changes by the same fraction h * 2^n / 2^32 of
//	its nominal advance, a fraction of standard deviation 2^n * 8.81e-6
//	(n = 7: 0.113 %); it is drawn anew in every clock and moves bits and
//	counts together. It needs +rosc_jitter. The model stops with an
//	assertion if a ring advances 64 or more periods in a clock.
//
//	Bench hook. With KARU_ROSC_BENCH defined and SIM = 0, a bench supplies
//	each ring as a module (karu_rosc_bench_ring, a clock in place of the
//	loop) and the delays between a counter's ring-domain flops and what they
//	drive (karu_rosc_bench_route), so that the logic that is synthesised
//	runs in simulation against rings of known timing: test/tb_rosc_meter.sv.
//	The bench also supplies the LUT3 that the counters' dividers are made
//	of, with delays; in the FPGA flow LUT3 is the vendor's primitive.
//	SPDX-License-Identifier: BSD-2-Clause

module karu_rosc_rng #(
	parameter integer STREAMS    = 4,		//	OpenTitan EntropyStreams / RngBusWidth
	parameter integer STAGES     = 3,		//	inverters in ring 0 (odd); ring s has 2*s more
	parameter integer REFS       = 2,		//	reference rings (at least 1): like ring 0, not on the bus
	parameter integer SIM        = 0		//	1: behavioural model, no rings; 2: the same, free-running
) (
	input  wire					clk,		//	OpenTitan: clk_ast_rng_i
	input  wire					rst,
	input  wire					rng_en_i,
	input  wire					rng_fips_i,
	input  wire [7:0]			rng_div_i,	//	clk cycles per raw symbol, less one
	input  wire [STREAMS+REFS-1:0]		ring_en_i,	//	the rings that run while the source is enabled
	input  wire					cnt_direct_i,	//	the unit of the counts: 0 two ring periods, 1 one (diagnostic)
	output reg					rng_val_o,	//	one-cycle pulse per symbol
	output reg  [STREAMS-1:0]	rng_b_o,	//	raw sampled ring outputs
	output reg  [REFS-1:0]		ref_b_o,	//	the reference rings, sampled and registered with them
	output wire [6*(STREAMS+REFS)-1:0]	cnt_o,		//	per ring: pairs of periods counted (direct mode: periods), modulo 64
	output wire [STREAMS+REFS-1:0]		cnt_bad_o	//	per ring: the count was not readable in this cycle
);
	localparam integer R = STREAMS + REFS;
	wire [STREAMS-1:0] osc;
	wire [REFS-1:0] ref_osc;				//	the reference rings, as the lanes are in osc
	wire [R-1:0] tick;						//	SIM = 0: the output net of every ring, the clock of its counter
	wire sample;							//	this cycle ends a sampling period
	genvar s, i;

	//	Per ring: the clear of its counter, and its gate, which opens one clock
	//	after the clear is released and closes with it. Both are flops of this
	//	module with nothing behind them: see "Switching a ring" above.
	//	The counting mode, dir_q, follows cnt_direct_i only in a clock in which
	//	every counter is in clear and every gate closed; while the two differ
	//	no ring may run, so that clock comes one clock after the difference.
	reg  dir_q = 1'b0;
	wire dir_chg = (cnt_direct_i != dir_q);
	wire [R-1:0] run = {R{rng_en_i && !rst && !dir_chg}} & ring_en_i;
	(* DONT_TOUCH = "true" *) reg [R-1:0] clr_q = {R{1'b1}};
	(* DONT_TOUCH = "true" *) reg [R-1:0] en_q;
	always @(posedge clk) begin
		clr_q <= ~run;
		en_q  <= run & ~clr_q;
		if (dir_chg && (&clr_q) && !(|en_q))
			dir_q <= cnt_direct_i;
	end

	generate if (SIM == 0) begin : g_rings
		for (s = 0; s < STREAMS; s = s + 1) begin : g_ring
			localparam integer N = STAGES + 2 * s;
			(* DONT_TOUCH = "true", ALLOW_COMBINATORIAL_LOOPS = "true" *) wire [N-1:0] inv;
`ifdef KARU_ROSC_BENCH
			karu_rosc_bench_ring #(.RING(s), .N(N)) ring (.en_i(en_q[s]), .inv_o(inv));
`else
			assign inv[0] = ~(inv[N-1] & en_q[s]);				//	enable gate
			for (i = 1; i < N; i = i + 1) begin : g_inv
				assign inv[i] = ~inv[i-1];
			end
`endif
			assign osc[s] = inv[N-1];
			assign tick[s] = inv[N-1];
		end
		for (s = 0; s < REFS; s = s + 1) begin : g_ref
			(* DONT_TOUCH = "true", ALLOW_COMBINATORIAL_LOOPS = "true" *) wire [STAGES-1:0] inv;
`ifdef KARU_ROSC_BENCH
			karu_rosc_bench_ring #(.RING(STREAMS + s), .N(STAGES)) ring (.en_i(en_q[STREAMS + s]), .inv_o(inv));
`else
			assign inv[0] = ~(inv[STAGES-1] & en_q[STREAMS + s]);	//	enable gate
			for (i = 1; i < STAGES; i = i + 1) begin : g_inv
				assign inv[i] = ~inv[i-1];
			end
`endif
			assign ref_osc[s] = inv[STAGES-1];
			assign tick[STREAMS + s] = inv[STAGES-1];
		end
		//	the period counters, on the ring's output net
		for (s = 0; s < R; s = s + 1) begin : g_cnt
			karu_rosc_cnt cnt (.ring_i(tick[s]), .clr_i(clr_q[s]), .direct_i(dir_q), .clk(clk),
				.cnt_o(cnt_o[6*s +: 6]), .bad_o(cnt_bad_o[s]));
		end
	end else begin : g_model
		//	Each ring: 32-bit phase in units of 2^-32 ring periods per sample
		//	step, and the whole periods above it. The steps below are per clk
		//	cycle; noise is a sum of four uniform 16-bit values, centred, so
		//	roughly Gaussian.
		reg [63:0] prng;
		reg [31:0] phase [0:R-1];
		reg [31:0] turn  [0:R-1];				//	whole periods since the ring was switched on
		reg [31:0] stuck, slow, jitter, duty, turns, shared;
		reg        characterise, modulate;
		reg        go_q;						//	the source is enabled: the generator runs
		integer m;
		initial begin
			stuck = 32'd0; slow = 32'd0; jitter = 32'd0; duty = 32'h8000_0000; turns = 32'd0; shared = 32'd0;
			if (!$value$plusargs("rosc_stuck=%d", stuck)) stuck = 32'd0;
			if (!$value$plusargs("rosc_slow=%d", slow)) slow = 32'd0;
			characterise = $value$plusargs("rosc_jitter=%d", jitter) != 0;
			if (!$value$plusargs("rosc_duty=%h", duty)) duty = 32'h8000_0000;
			if (!$value$plusargs("rosc_turns=%d", turns)) turns = 32'd0;
			modulate = $value$plusargs("rosc_shared=%d", shared) != 0;
		end
		//	what differs between the rings: see the header for the values
		function automatic [31:0] ring_step(input integer r);
			integer t;
			begin
				t = r - STREAMS;
				if (r < STREAMS)		ring_step = 32'h0a3d_70a3 * (2 * r + 3);
				else if (t % 2 == 0)	ring_step = 32'h1eb8_51e9 + 32'd1546188 * (1 + t / 2);
				else					ring_step = 32'h1eb8_51e9 - 32'd1030792 * (1 + t / 2);
			end
		endfunction
		function automatic integer ring_scale(input integer r);
			ring_scale = (r < STREAMS) ? r + 1 : 1;
		endfunction
		function automatic integer ring_stages(input integer r);
			ring_stages = (r < STREAMS) ? STAGES + 2 * r : STAGES;
		endfunction
		//	a roughly Gaussian value: four 16-bit fields of the generator
		//	state times an odd constant, summed and centred
		function automatic signed [31:0] gauss(input [63:0] state, input [63:0] mul);
			reg [63:0] u;
			begin
				u = state * mul;
				gauss = $signed({16'b0, u[15:0]}) + $signed({16'b0, u[31:16]})
					  + $signed({16'b0, u[47:32]}) + $signed({16'b0, u[63:48]}) - 32'sd131070;
			end
		endfunction
		//	the characterisation model's noise of one ring
		function automatic signed [31:0] lane_noise(input [63:0] state, input integer lane);
			begin
				if (lane < STREAMS)
					lane_noise = gauss(state, lane == 0 ? 64'hd6e8_feb8_6659_fd93 : lane == 1 ? 64'hca5a_8263_9512_1157 :
											  lane == 2 ? 64'h9fb2_1c65_1e98_df25 : 64'hc2b2_ae3d_27d4_eb4f);
				else
					lane_noise = gauss(state, lane == STREAMS ? 64'hbf58_476d_1ce4_e5b9 : 64'h94d0_49bb_1331_11eb);
			end
		endfunction
		wire [63:0] p1 = prng ^ (prng << 13);
		wire [63:0] p2 = p1 ^ (p1 >> 7);
		wire [63:0] p3 = p2 ^ (p2 << 17);
		wire signed [18:0] noise = $signed({3'b0, prng[15:0]}) + $signed({3'b0, prng[31:16]})
								 + $signed({3'b0, prng[47:32]}) + $signed({3'b0, prng[63:48]})
								 - 19'sd131070;
		//	The advance of ring r in this clock, 2^-32 periods: A_r of the
		//	header. Its low 32 bits are the step of the phase.
		function automatic [63:0] advance(input integer r);
			reg [31:0] inc, whole;
			reg signed [63:0] nom, own, com, sum;
			begin
				whole = (32'd3 * turns) / ring_stages(r);
				nom   = $signed({whole, ring_step(r)});
				if (characterise) begin
					own = lane_noise(prng, r) * ring_scale(r);
					own = own <<< jitter[4:0];
					com = 64'sd0;
					if (modulate) begin
						com = nom * gauss(prng, 64'hff51_afd7_ed55_8ccd);
						com = com >>> (6'd32 - {1'b0, shared[4:0]});
					end
					sum = nom + own + com;
					advance = sum[63] ? {32'b0, sum[31:0]} : sum;
				end else begin
					inc = ring_step(r) + ({{13{noise[18]}}, noise} <<< (14 - slow[3:0])) * ring_scale(r)
						+ {prng[8*(r % 8) +: 8], 24'b0};
					advance = {whole, inc};
				end
			end
		endfunction
		initial prng = 64'h9e37_79b9_7f4a_7c15;
		always @(posedge clk) begin
			go_q <= rng_en_i && !rst;
			if (SIM == 2) prng <= p3;
			if (rst) begin
				if (SIM != 2) prng <= 64'h9e37_79b9_7f4a_7c15;
				for (m = 0; m < R; m = m + 1) phase[m] <= 32'h1357_9bdf * (m + 1);
			end else begin
				if (SIM != 2 && go_q) prng <= p3;
				//	a different mean step per ring, and the noise drawn so
				//	that the rings do not move together
				for (m = 0; m < R; m = m + 1)
					if (!clr_q[m]) {turn[m], phase[m]} <= {turn[m], phase[m]} + advance(m);
			end
			//	a ring that is off is counted from zero when it starts
			for (m = 0; m < R; m = m + 1)
				if (rst || clr_q[m]) turn[m] <= 32'd0;
		end
		for (s = 0; s < STREAMS; s = s + 1) begin : g_lane
			assign osc[s] = stuck[s] ? 1'b1 : (phase[s] < duty);
		end
		for (s = 0; s < REFS; s = s + 1) begin : g_refb
			assign ref_osc[s] = phase[STREAMS + s] < duty;
		end
		assign tick = {R{1'b0}};
		//	the counts, through the three stages of karu_rosc_cnt
		for (s = 0; s < R; s = s + 1) begin : g_cnt
			wire [5:0] now = clr_q[s] ? 6'd0 : dir_q ? turn[s][5:0] : turn[s][6:1];
			reg  [5:0] gm_q, gs_q, cnt_q;
			always @(posedge clk) begin
				gm_q <= now; gs_q <= gm_q; cnt_q <= gs_q;
			end
			assign cnt_o[6*s +: 6] = cnt_q;
			assign cnt_bad_o[s] = 1'b0;
		end

`ifndef KARU_NO_ASSERT
		// synthesis translate_off
		//	The alignment of the header, against a history of the model that
		//	is kept here: a count is the model's count of three clock edges
		//	earlier, and so is a symbol. And no ring outruns its counter.
		reg [6*R-1:0]		a_cnt [0:2];
		reg [R-1:0]			a_osc [0:2];
		reg [2:0]			a_ok;
		integer				k;
		always @(posedge clk) begin
			for (k = 0; k < R; k = k + 1) a_cnt[0][6*k +: 6] <= clr_q[k] ? 6'd0 : dir_q ? turn[k][5:0] : turn[k][6:1];
			a_osc[0] <= {ref_osc, osc};
			a_cnt[1] <= a_cnt[0]; a_cnt[2] <= a_cnt[1];
			a_osc[1] <= a_osc[0]; a_osc[2] <= a_osc[1];
			a_ok <= rst ? 3'b000 : {a_ok[1:0], 1'b1};
			if (!rst && a_ok[2]) begin
				if (cnt_o !== a_cnt[2]) begin
					$display("ASSERT: karu_rosc_rng: a count is not the model's of three clock edges earlier"); $fatal;
				end
				if (rng_val_o && {ref_b_o, rng_b_o} !== a_osc[2]) begin
					$display("ASSERT: karu_rosc_rng: a symbol or a reference bit is not the ring output of the edge its counts are from"); $fatal;
				end
			end
			for (k = 0; k < R; k = k + 1)
				if (!rst && !clr_q[k] && advance(k) >= 64'h0000_0040_0000_0000) begin
					$display("ASSERT: karu_rosc_rng: model ring %0d advances 64 or more periods in a clock", k); $fatal;
				end
		end
		// synthesis translate_on
`endif
	end endgenerate

	//	the sampling flip-flop of the model, and one more against metastability:
	//	bits [STREAMS-1:0] the lanes, the bits above them the reference rings
	(* ASYNC_REG = "TRUE" *) reg [R-1:0] samp_q, meta_q;
	always @(posedge clk)
		if (rst)	begin samp_q <= {R{1'b0}};       meta_q <= {R{1'b0}}; end
		else		begin samp_q <= {ref_osc, osc};  meta_q <= samp_q;    end

	//	one symbol every rng_div_i + 1 cycles: the sampling period of the
	//	model. The comparison is >=, so that a period shortened below the
	//	count takes effect in this cycle instead of after a wrap.
	reg [7:0] div_q;
	assign sample = (div_q >= rng_div_i);
	always @(posedge clk)
		if (rst) begin
			div_q <= 8'd0; rng_val_o <= 1'b0; rng_b_o <= {STREAMS{1'b0}}; ref_b_o <= {REFS{1'b0}};
		end else begin
			rng_val_o <= 1'b0;
			if (!rng_en_i)
				div_q <= 8'd0;
			else if (sample) begin
				div_q <= 8'd0;
				rng_val_o <= 1'b1;
				rng_b_o <= meta_q[STREAMS-1:0];
				ref_b_o <= meta_q[R-1:STREAMS];
			end else
				div_q <= div_q + 8'd1;
		end

	wire unused = rng_fips_i;

`ifndef KARU_NO_ASSERT
	// synthesis translate_off
	//	Symbols in consecutive cycles only at a period of one cycle. A ring's
	//	gate is never open while its counter is in clear, and it opens only
	//	when the counter has been out of clear for a clock. The counting mode
	//	changes only in a clock before which every counter was in clear and
	//	every gate closed, and no clear is released in that clock.
	initial if (REFS < 1) begin
		$display("ASSERT: karu_rosc_rng: REFS must be at least 1"); $fatal;
	end
	reg       val_q;
	reg [7:0] div_d;
	reg [R-1:0] clr_d, en_d;
	reg       dir_d;
	reg [1:0] seq_ok;
	always @(posedge clk) begin
		val_q <= !rst && rng_val_o;
		div_d <= rng_div_i;
		clr_d <= clr_q;
		en_d  <= en_q;
		dir_d <= dir_q;
		seq_ok <= rst ? 2'b00 : {seq_ok[0], 1'b1};
		if (!rst && rng_val_o && val_q && div_d != 8'd0) begin
			$display("ASSERT: karu_rosc_rng: symbols in consecutive cycles at a period above one"); $fatal;
		end
		if (seq_ok[1] === 1'b1 && ((en_q & clr_q) !== {R{1'b0}} || (en_q & ~en_d & clr_d) !== {R{1'b0}})) begin
			$display("ASSERT: karu_rosc_rng: a ring's gate is open with its counter in clear, or opened in the clock it left clear"); $fatal;
		end
		if (seq_ok[1] === 1'b1 && dir_q !== dir_d && (clr_d !== {R{1'b1}} || en_d !== {R{1'b0}} || clr_q !== {R{1'b1}})) begin
			$display("ASSERT: karu_rosc_rng: the counting mode changed with a ring running or a counter out of clear"); $fatal;
		end
	end
	// synthesis translate_on
`endif
endmodule

//	karu_rosc_cnt
//	=== Counter of one ring's periods, read into the clock domain.
//
//	THE UNIT OF cnt_o IS TWO RING PERIODS (one, with direct_i set).
//
//	The 3-stage rings have a period of 0.830 ns in the slow corner and
//	0.376 ns in the fast one, in the timing model of a small routed design
//	with the present constraints: 16 to 36 periods per 75 MHz clock. A slice
//	flip-flop needs a clock period of 0.550 ns and high and low pulses of
//	0.275 ns; the fast ring's pulses are 0.188 ns. So no flip-flop is
//	clocked by a ring, except in the diagnostic mode of direct_i.
//
//	The divider. Between the ring and the counter is a divide-by-two made of
//	two latches, each one look-up table, so of the same elements as the ring
//	and a fixed fraction of its period at every corner. With C the ring's
//	output:
//
//	  div_m   M = C ? M : ~S     the master, transparent while C is low
//	  div_s   S = C ? M : S      the slave, transparent while C is high
//	  div_x   jclk = direct_i ? C : S
//
//	S toggles at every rising edge of C, so jclk has a period of two ring
//	periods and levels of one ring period each (0.376 ns in the fast
//	corner), inside both limits of the flip-flop. There is no reset: from
//	either state of M and S the pair toggles from the first ring period on,
//	and the counter is cleared separately. The three tables are explicit
//	LUT3 primitives; O = INIT[{I2, I1, I0}], and with the pins as connected
//	below (I0 always the ring):
//
//	  div_m  INIT 8D   I2 = S, I1 = M     {S,M,C}: 000>1 001>0 010>1 011>1
//	                                               100>0 101>0 110>0 111>1
//	  div_s  INIT E4   I2 = M, I1 = S     {M,S,C}: 000>0 001>0 010>1 011>0
//	                                               100>0 101>1 110>1 111>1
//	  div_x  INIT AC   I2 = direct_i,     {D,S,C}: 000>0 001>0 010>1 011>1
//	                   I1 = S                      100>0 101>1 110>0 111>1
//
//	A latch made of a look-up table relies on the table not glitching when
//	one input changes and the output is the same for both of its values
//	(the ring changing while the latch holds). Given that, what has to hold
//	in the routed design, with d_m and d_s the
//	delays through the two tables, c_m and c_s the arrival of C at them,
//	r_xy the route from the output of x to the input of y (r_mm and r_ss
//	the two latches' own loops), and H and L the high and low times of C:
//
//	  c_m - c_s < d_s + r_sm      at C rising the master is closed before
//	                              the slave's new value comes round to it
//	  c_s - c_m < d_m + r_ms      at C falling the slave is closed before
//	                              the master's new value reaches it
//	  d_s + r_sm - (c_m - c_s) < H    the slave's value is at the master
//	                              before the master opens
//	  d_m + r_ms + (c_m - c_s) < L    the master's value is at the slave
//	                              before the slave opens
//	  d_s + r_ss < H              the slave's own loop closes while it is
//	                              transparent
//	  d_m + r_mm < L              the same for the master
//
//	In words: the way from one latch to the other is longer than the skew
//	of C between them and shorter than a half period, and each latch's own
//	loop is shorter than a half period. The bench finds the divider right
//	wherever these hold, and shows the two ways it fails beyond them
//	(test/tb_rosc_meter.sv): S toggles twice per ring period when one of
//	the first two is missed by a table's delay and the way round both
//	tables is shorter than a half period; toggles are lost when a table is
//	slower than a half period.
//
//	direct_i selects the ring itself as the counter's clock. It is static
//	while the ring runs: karu_rosc_rng changes it only with the ring off
//	and this counter in clear.
//
//	The counter. Its value has to be readable from another clock domain
//	while it moves, and nothing may sit between its flops. So the count is
//	kept in three small counters in which exactly one flop changes at a
//	time, with a wire or one inverter between flops:
//
//	  j   an 8-flop Johnson counter on the rising edge of jclk: sixteen
//	      states, the position f within sixteen periods of jclk. f = 0 is
//	      00000000, then j[0] is set first (f = 1 is 00000001) up to f = 8,
//	      11111111, then j[0] is cleared first (f = 9 is 11111110) down to
//	      f = 15, 10000000.
//	  a   a 2-bit Gray counter on the rising edge of j[0]: it steps once per
//	      sixteen periods, when f goes from 0 to 1.
//	  b   the same on the rising edge of j[7]: it steps when f goes from 7
//	      to 8, half a cycle of sixteen away from a.
//
//	From all flops clear, during the c-th run of sixteen periods (c = 0, 1,
//	...) the count is 16c + f, a becomes c + 1 when f goes to 1 and b
//	becomes c + 1 when f goes to 8. A sample of the twelve flops does not
//	see them at one instant: each reaches the sampling flops by its own
//	route, and a and b are clocked by a Johnson flop. A sample may therefore
//	show a or b one step ahead of the Johnson state or one behind it. The
//	decoder takes each of them only in the part of the cycle that is well
//	away from its own step, on both sides:
//
//	  f = 0..3     n = b        b stepped 8 states before f = 0, and steps
//	                            next 4 states after f = 3
//	  f = 4..11    n = a - 1    a stepped 3 states before f = 4, and steps
//	                            next 5 states after f = 11
//	  f = 12..15   n = b - 1    b stepped 4 states before f = 12
//
//	and cnt_o = 16 * (n mod 4) + f: the periods of jclk counted, modulo 64.
//	The margins, in Johnson states (periods of jclk): b may reach the
//	sampling flops up to 4 states later than the Johnson bits or up to 4
//	states earlier, a up to 3 states later or up to 5 earlier, before a
//	count can be wrong. Beyond that a count is wrong by sixteen with bad_o
//	clear. (An earlier rule used b for f = 0..7: it had no margin at all for
//	b arriving early, and returned 23 for a sample between 7 and 8.)
//
//	All twelve flops are sampled by clk through two stages (gm_q, gs_q), and
//	the decoded count is registered: cnt_o is the count as it was sampled
//	three clock stages earlier. Because one Johnson flop changes per period
//	of jclk, a sample taken during a change is the old or the new state,
//	provided the eight Johnson bits reach gm_q with less skew between them
//	than one period of jclk; that is a matter of placement. A sample that is
//	not one of the sixteen Johnson codes sets bad_o for that cycle, and
//	cnt_o repeats its previous value. A counter that has left the sixteen
//	codes does not return to them by itself: it is cleared when the ring is
//	next switched off. (Outside the codes several flops change per period,
//	so a sample may now and then look like a code and pass; the count it
//	gives fits no other.)
//
//	clr_i clears the ring-domain flops asynchronously. It comes straight
//	from a flop of the clock domain, is high while the ring is off, and is
//	released a clock before the ring starts and no sooner than a clock
//	after it has stopped: a clear released next to a clock edge of the
//	counter could let a or b miss a step that the Johnson counter took, and
//	the count would then be wrong by sixteen for part of every cycle. The
//	latches of the divider are not cleared.

module karu_rosc_cnt (
	input  wire			ring_i,			//	the ring's output net: asynchronous, 0.5 to 2.7 GHz (3-stage rings 1.2 to 2.7)
	input  wire			clr_i,			//	clk domain: clears the ring-domain flops; high while the ring is off
	input  wire			direct_i,		//	clk domain, static while the ring runs: count the ring itself
	input  wire			clk,
	output reg  [5:0]	cnt_o,			//	periods of jclk counted, modulo 64, as sampled three clk stages earlier
	output reg			bad_o			//	that sample was not a valid code; cnt_o repeats its previous value
);
	//	---- the divider: see the header for the tables ----
	(* ALLOW_COMBINATORIAL_LOOPS = "true" *) wire div_mq;	//	M
	(* ALLOW_COMBINATORIAL_LOOPS = "true" *) wire div_sq;	//	S: toggles at every rising edge of the ring
	wire jclk;												//	the counter's clock
	(* DONT_TOUCH = "true" *) LUT3 #(.INIT(8'h8D)) div_m (.O(div_mq), .I0(ring_i), .I1(div_mq), .I2(div_sq));
	(* DONT_TOUCH = "true" *) LUT3 #(.INIT(8'hE4)) div_s (.O(div_sq), .I0(ring_i), .I1(div_sq), .I2(div_mq));
	(* DONT_TOUCH = "true" *) LUT3 #(.INIT(8'hAC)) div_x (.O(jclk),   .I0(ring_i), .I1(div_sq), .I2(direct_i));

	//	---- ring domain ----
	//	SHREG_EXTRACT = "no" keeps these flops flops: without it the Johnson
	//	counter may become a shift-register look-up table. DONT_TOUCH and KEEP
	//	must not be used on them. With either, Vivado puts a LUT1 buffer
	//	behind every one of these flops (15 LUT1 in a counter instead of the
	//	three inverters): each Johnson shift then goes from a flop through a
	//	LUT in another slice to the next flop, and the coarse counters are
	//	clocked through such a LUT instead of by j_q[0] and j_q[7] themselves.
	(* SHREG_EXTRACT = "no" *) reg [7:0] j_q = 8'd0;
	(* SHREG_EXTRACT = "no" *) reg [1:0] a_q = 2'd0;
	(* SHREG_EXTRACT = "no" *) reg [1:0] b_q = 2'd0;
	wire		clr_j, clr_a, clr_b;	//	the clear at each counter
	wire [11:0]	ring_s;					//	the twelve flops as the sampling stage sees them
`ifdef KARU_ROSC_BENCH
	karu_rosc_bench_route route (.q_i({b_q, a_q, j_q}), .q_o(ring_s), .clr_i(clr_i), .clr_o({clr_b, clr_a, clr_j}));
`else
	assign ring_s = {b_q, a_q, j_q};
	assign {clr_b, clr_a, clr_j} = {3{clr_i}};
`endif
	always @(posedge jclk or posedge clr_j)
		if (clr_j)	j_q <= 8'd0;
		else		j_q <= {j_q[6:0], ~j_q[7]};
	always @(posedge j_q[0] or posedge clr_a)
		if (clr_a)	a_q <= 2'd0;
		else		a_q <= {a_q[0], ~a_q[1]};
	always @(posedge j_q[7] or posedge clr_b)
		if (clr_b)	b_q <= 2'd0;
		else		b_q <= {b_q[0], ~b_q[1]};

	//	---- clock domain ----
	(* ASYNC_REG = "TRUE" *) reg [11:0] gm_q, gs_q;
	always @(posedge clk) begin
		gm_q <= ring_s;
		gs_q <= gm_q;
	end

	wire [7:0] j = gs_q[7:0];
	//	one of the sixteen codes: at most one place where neighbours differ
	wire [6:0] step = j[7:1] ^ j[6:0];
	wire       code = (step & (step - 7'd1)) == 7'd0;
	wire [3:0] ones = {3'b0, j[0]} + {3'b0, j[1]} + {3'b0, j[2]} + {3'b0, j[3]}
					+ {3'b0, j[4]} + {3'b0, j[5]} + {3'b0, j[6]} + {3'b0, j[7]};
	wire [3:0] f = j[0] ? ones : j[7] ? 4'd0 - ones : 4'd0;
	//	Gray to binary
	wire [1:0] a = {gs_q[9],  gs_q[9]  ^ gs_q[8]};
	wire [1:0] b = {gs_q[11], gs_q[11] ^ gs_q[10]};
	//	each coarse counter where it is at rest: see the header for the margins
	wire [1:0] n = (f <= 4'd3) ? b : (f <= 4'd11) ? a - 2'd1 : b - 2'd1;
	always @(posedge clk) begin
		bad_o <= !code;
		if (code)
			cnt_o <= {n, f};
	end
endmodule
