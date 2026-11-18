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
//	Vivado: the ring nets carry DONT_TOUCH, so every inverter stays a LUT,
//	and ALLOW_COMBINATORIAL_LOOPS, which turns the loop check LUTLP-1 (an
//	error at bitstream generation) into the warning LUTLP-2. The timing
//	report then lists one loop per ring. Placement of the rings is set in
//	the constraints (flow/fpga/vcu118_rosc.xdc).
//
//	Simulation: the loops cannot be simulated. With SIM = 1 each lane is a
//	fixed-point model of the same sampling process, x <- x + F + noise
//	(mod 1), bit = (x < 1/2), driven by a deterministic generator. It is a
//	stand-in for tests and carries no entropy. Plusargs for fault injection:
//	+rosc_stuck=<mask> holds the lanes in the mask at 1, and +rosc_slow=<n>
//	divides the jitter by 2^n. With SIM = 2 the generator is not reset and
//	runs whether or not the source is enabled, as physical noise does, so
//	that two resets do not give the same symbols.
//	SPDX-License-Identifier: BSD-2-Clause

module karu_rosc_rng #(
	parameter integer STREAMS    = 4,		//	OpenTitan EntropyStreams / RngBusWidth
	parameter integer STAGES     = 3,		//	inverters in ring 0 (odd); ring s has 2*s more
	parameter integer SAMPLE_DIV = 256,		//	clk cycles per raw symbol
	parameter integer SIM        = 0		//	1: behavioural model, no rings; 2: the same, free-running
) (
	input  wire					clk,		//	OpenTitan: clk_ast_rng_i
	input  wire					rst,
	input  wire					rng_en_i,
	input  wire					rng_fips_i,
	output reg					rng_val_o,	//	one-cycle pulse per symbol
	output reg  [STREAMS-1:0]	rng_b_o		//	raw sampled ring outputs
);
	wire [STREAMS-1:0] osc;
	wire sample;							//	this cycle ends a sampling period
	genvar s, i;

	//	The enable is registered here, so that the gate of every ring is a
	//	two-input function of one local flop whatever drives rng_en_i.
	//	Otherwise synthesis folds upstream logic into the ring's first stage.
	(* DONT_TOUCH = "true" *) reg en_q;
	always @(posedge clk)
		en_q <= rng_en_i && !rst;

	generate if (SIM == 0) begin : g_rings
		for (s = 0; s < STREAMS; s = s + 1) begin : g_ring
			localparam integer N = STAGES + 2 * s;
			(* DONT_TOUCH = "true", ALLOW_COMBINATORIAL_LOOPS = "true" *) wire [N-1:0] inv;
			assign inv[0] = ~(inv[N-1] & en_q);				//	enable gate
			for (i = 1; i < N; i = i + 1) begin : g_inv
				assign inv[i] = ~inv[i-1];
			end
			assign osc[s] = inv[N-1];
		end
	end else begin : g_model
		//	Each lane: 32-bit phase in units of 2^-32 ring periods per sample
		//	step. The steps below are per clk cycle; noise is a sum of four
		//	uniform 16-bit values, centred, so roughly Gaussian.
		reg [63:0] prng;
		reg [31:0] phase [0:STREAMS-1];
		reg [31:0] stuck, slow;
		integer m;
		initial begin
			stuck = 32'd0; slow = 32'd0;
			if (!$value$plusargs("rosc_stuck=%d", stuck)) stuck = 32'd0;
			if (!$value$plusargs("rosc_slow=%d", slow)) slow = 32'd0;
		end
		wire [63:0] p1 = prng ^ (prng << 13);
		wire [63:0] p2 = p1 ^ (p1 >> 7);
		wire [63:0] p3 = p2 ^ (p2 << 17);
		wire signed [18:0] noise = $signed({3'b0, prng[15:0]}) + $signed({3'b0, prng[31:16]})
								 + $signed({3'b0, prng[47:32]}) + $signed({3'b0, prng[63:48]})
								 - 19'sd131070;
		initial prng = 64'h9e37_79b9_7f4a_7c15;
		always @(posedge clk) begin
			if (SIM == 2) prng <= p3;
			if (rst) begin
				if (SIM != 2) prng <= 64'h9e37_79b9_7f4a_7c15;
				for (m = 0; m < STREAMS; m = m + 1) phase[m] <= 32'h1357_9bdf * (m + 1);
			end else if (en_q) begin
				if (SIM != 2) prng <= p3;
				//	a different mean step per lane, and the same noise sample
				//	rotated so that the lanes do not move together
				for (m = 0; m < STREAMS; m = m + 1)
					phase[m] <= phase[m] + 32'h0a3d_70a3 * (2 * m + 3)
							  + ({{13{noise[18]}}, noise} <<< (14 - slow[3:0])) * (m + 1)
							  + {prng[8*m +: 8], 24'b0};
			end
		end
		for (s = 0; s < STREAMS; s = s + 1) begin : g_lane
			assign osc[s] = stuck[s] ? 1'b1 : ~phase[s][31];
		end
	end endgenerate

	//	the sampling flip-flop of the model, and one more against metastability
	(* ASYNC_REG = "TRUE" *) reg [STREAMS-1:0] samp_q, meta_q;
	always @(posedge clk)
		if (rst)	begin samp_q <= {STREAMS{1'b0}}; meta_q <= {STREAMS{1'b0}}; end
		else		begin samp_q <= osc;             meta_q <= samp_q;          end

	//	one symbol every SAMPLE_DIV cycles: the sampling period of the model
	reg [15:0] div_q;
	assign sample = (div_q == SAMPLE_DIV - 1);
	always @(posedge clk)
		if (rst) begin
			div_q <= 16'd0; rng_val_o <= 1'b0; rng_b_o <= {STREAMS{1'b0}};
		end else begin
			rng_val_o <= 1'b0;
			if (!rng_en_i)
				div_q <= 16'd0;
			else if (sample) begin
				div_q <= 16'd0;
				rng_val_o <= 1'b1;
				rng_b_o <= meta_q;
			end else
				div_q <= div_q + 16'd1;
		end

	wire unused = rng_fips_i;

`ifndef KARU_NO_ASSERT
	// synthesis translate_off
	reg val_q;
	always @(posedge clk) begin
		val_q <= !rst && rng_val_o;
		if (!rst && rng_val_o && val_q) begin
			$display("ASSERT: karu_rosc_rng: valid longer than one cycle"); $fatal;
		end
	end
	// synthesis translate_on
`endif
endmodule
