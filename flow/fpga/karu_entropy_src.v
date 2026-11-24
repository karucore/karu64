//	karu_entropy_src.v
//	=== The entropy source of an SoC: ring-oscillator noise source plus the
//	entropy block, ready to connect to the zkr_* ports of karu64.
//
//	    karu_rosc_rng --raw 4-bit symbols--> karu_entropy --> seed, mnoise,
//	      ^  ^   |  |                             ^           mentropycfg
//	      |  |   |  +--> karu_noise_burst --+     | lane, spacing floor
//	      |  |   +-----> karu_rosc_meter ---+--> registers (reg_*)
//	      |  +--period-----+       |
//	      +--rings that run--------+<-- straps
//
//	The two halves talk through OpenTitan's raw noise-source interface, so
//	another noise source (an ASIC's analog one) replaces karu_rosc_rng
//	without touching rtl/karu_entropy.v.
//
//	seed delivers the bits of one ring, the lane the strap names (lane 0,
//	the 3-stage ring, by default). The other rings are there to characterise
//	that one: lanes 1 to 3 on the raw bus, and two reference rings built like
//	lane 0, counted and sampled like it, that only the meter sees. None of
//	them has entropy credit.
//
//	Two measurement aids work in the entropy block's test mode, and only
//	then. karu_noise_burst sets the sampling period (1 to 256 clocks) and
//	records bursts of consecutive raw symbols. karu_rosc_meter reads the
//	period counter that every ring carries, records all six counts with the
//	lane bits at chosen samples, and says which rings run. A counter counts
//	its ring through a divider by two, so that no flip-flop is clocked
//	faster than the part allows; the meter can switch the counters to the
//	ring itself as a diagnostic, in test mode only. Outside test mode
//	the period is SAMPLE_DIV, the rings that run are those of the strap, and
//	both blocks hold nothing. Their registers are reached through reg_*:
//	addresses 0 to 3 the burst capture, 5 to 7 the meter (4 is not here: the
//	platform puts its temperature readout there). A platform without the
//	registers ties the inputs low.
//
//	Straps. Three settings are constants held in look-up tables
//	(karu_softstrap.v), so that an image with another setting can be made
//	from the routed design without placing or routing again, the rings
//	untouched (strap_variant.tcl): the lane (LANE), the spacing floor
//	(KSHIFT: k at least 16, 32, 64 or 128 with the default interval) and the
//	rings that run outside test mode (RING_MASK: bit r is ring r; rings 0 to
//	3 are the lanes, 4 and 5 the references). The parameters are the values
//	an image is built with. They are static: software cannot change them,
//	and mentropystat shows the lane and the floor.
//
//	en_i is a platform strap on a pin. Low holds the noise source off and
//	seed in BIST, which OpenSBI and Linux both handle by falling back; it is
//	the way to take the source out of the boot if it misbehaves.
//
//	SPDX-License-Identifier: BSD-2-Clause

module karu_entropy_src #(
	parameter integer SIM            = 0,		//	1: behavioural noise model (no entropy)
	parameter integer SAMPLE_DIV     = 256,		//	clk cycles per raw symbol (1..256), outside test mode
	parameter integer BURST_LOG2_WORDS = 11,	//	burst capture: 2^n words of 16 symbols
	//	The entropy block's configuration after reset, and the weakest that
	//	software can set (rtl/karu_entropy.v). A limit follows its reset value
	//	unless the build says otherwise. The values are for the VCU118 rings at
	//	75 MHz and SAMPLE_DIV = 256 (doc/sp800-90b-assessment.md): a target of
	//	0.75 bit per sample, which is one bit of the selected ring, and false
	//	alarms at 2^-40 per test.
	parameter [15:0]  INTERVAL_RESET = 16'd15,	//	k-1: raw symbols per sample, less one
	parameter [15:0]  INTERVAL_MIN   = INTERVAL_RESET,
	parameter [9:0]   RCT_RESET      = 10'd55,
	parameter [9:0]   RCT_MAX        = RCT_RESET,
	parameter [10:0]  APT_RESET      = 11'd719,
	parameter [10:0]  APT_MAX        = APT_RESET,
	parameter [2:0]   STRIKE_RESET   = 3'd3,
	parameter [2:0]   STRIKE_MAX     = STRIKE_RESET,
	parameter [4:0]   CALM_RESET     = 5'd24,
	parameter [4:0]   CALM_MIN       = CALM_RESET,
	//	The straps as built (see the header): the lane of the raw bus whose
	//	bits seed delivers; the spacing floor, INTERVAL_MIN + 1 shifted left
	//	by KSHIFT (k at least 16, 32, 64 or 128 with the default); and the
	//	rings that run outside test mode, the four lanes by default.
	parameter [1:0]   LANE           = 2'd0,
	parameter [1:0]   KSHIFT         = 2'd0,
	parameter [5:0]   RING_MASK      = 6'b001111
) (
	input  wire			clk,
	input  wire			rst,
	input  wire			en_i,

	input  wire			csr_fire_i,
	input  wire [1:0]	csr_sel_i,
	input  wire			csr_we_i,
	input  wire [63:0]	csr_wdata_i,
	output wire [63:0]	csr_rdata_o,

	//	registers of the burst capture (karu_noise_burst.v), addresses 0 to
	//	3, and of the meter (karu_rosc_meter.v), addresses 5 to 7
	input  wire			reg_re_i,
	input  wire [2:0]	reg_raddr_i,
	output wire [63:0]	reg_rdata_o,
	input  wire			reg_we_i,
	input  wire [2:0]	reg_waddr_i,
	input  wire [63:0]	reg_wdata_i
);
	localparam integer RINGS = 6;				//	four lanes and two reference rings
	wire		rng_en, rng_fips, rng_val;
	wire [3:0]	rng_b, burst_sym;
	wire [RINGS-5:0]	ref_b;					//	the reference rings' sampled bits: for the meter only
	wire [7:0]	rng_div;
	wire		noise_test, cfg_lock, respace_burst, respace_meter;
	wire		cnt_direct;					//	the counters count ring periods directly: a diagnostic of test mode
	wire [RINGS-1:0]	ring_en, cnt_bad;
	wire [6*RINGS-1:0]	cnt;
	localparam integer DIV_LESS_ONE = SAMPLE_DIV - 1;
	localparam [7:0] DIV_RESET = DIV_LESS_ONE[7:0];
	localparam integer STRAP_SIM = (SIM != 0) ? 1 : 0;

	//	the straps: one look-up table per bit, found by these names in
	//	strap_variant.tcl
	wire [1:0]			strap_lane, strap_k;
	wire [RINGS-1:0]	strap_ring;
	genvar i;
	generate
		for (i = 0; i < 2; i = i + 1) begin : g_strap_lane
			karu_softstrap #(.SIM(STRAP_SIM), .VALUE(LANE[i])) s (.o(strap_lane[i]));
		end
		for (i = 0; i < 2; i = i + 1) begin : g_strap_k
			karu_softstrap #(.SIM(STRAP_SIM), .VALUE(KSHIFT[i])) s (.o(strap_k[i]));
		end
		for (i = 0; i < RINGS; i = i + 1) begin : g_strap_ring
			karu_softstrap #(.SIM(STRAP_SIM), .VALUE(RING_MASK[i])) s (.o(strap_ring[i]));
		end
	endgenerate

	//	registers: 0 to 3 the burst capture, 5 to 7 the meter's 0 to 2
	wire		rsel_meter = reg_raddr_i[2] && (reg_raddr_i[1:0] != 2'd0);
	wire		wsel_meter = reg_waddr_i[2] && (reg_waddr_i[1:0] != 2'd0);
	wire [1:0]	raddr_meter = reg_raddr_i[1:0] - 2'd1;
	wire [1:0]	waddr_meter = reg_waddr_i[1:0] - 2'd1;
	wire [63:0]	rdata_burst, rdata_meter;
	assign reg_rdata_o = rsel_meter ? rdata_meter : reg_raddr_i[2] ? 64'b0 : rdata_burst;

	karu_rosc_rng #(.STREAMS(4), .REFS(RINGS - 4), .SIM(SIM)) noise (
		.clk(clk), .rst(rst), .rng_en_i(rng_en), .rng_fips_i(rng_fips), .rng_div_i(rng_div),
		.ring_en_i(ring_en), .cnt_direct_i(cnt_direct),
		.rng_val_o(rng_val), .rng_b_o(rng_b), .ref_b_o(ref_b), .cnt_o(cnt), .cnt_bad_o(cnt_bad));

	//	The burst capture records what the meter gives it: the lane bits,
	//	or in test mode, if asked, one ring's count, or the two reference
	//	rings' bits beside those of lanes 0 and 1.
	karu_noise_burst #(.LOG2_WORDS(BURST_LOG2_WORDS), .DIV_RESET(DIV_RESET)) burst (
		.clk(clk), .rst(rst), .test_i(noise_test), .lock_i(cfg_lock),
		.rng_en_i(rng_en), .rng_val_i(rng_val), .rng_b_i(burst_sym), .div_o(rng_div), .respace_o(respace_burst),
		.reg_re_i(reg_re_i && !reg_raddr_i[2]), .reg_raddr_i(reg_raddr_i), .reg_rdata_o(rdata_burst),
		.reg_we_i(reg_we_i && !reg_waddr_i[2]), .reg_waddr_i(reg_waddr_i), .reg_wdata_i(reg_wdata_i));

	karu_rosc_meter #(.RINGS(RINGS), .LANES(4)) meter (
		.clk(clk), .rst(rst), .test_i(noise_test), .lock_i(cfg_lock),
		.rng_val_i(rng_val), .rng_b_i(rng_b), .ref_b_i(ref_b), .cnt_i(cnt), .cnt_bad_i(cnt_bad), .op_mask_i(strap_ring),
		.ring_en_o(ring_en), .cnt_direct_o(cnt_direct), .burst_sym_o(burst_sym), .respace_o(respace_meter),
		.reg_re_i(reg_re_i && rsel_meter), .reg_raddr_i(raddr_meter), .reg_rdata_o(rdata_meter),
		.reg_we_i(reg_we_i && wsel_meter), .reg_waddr_i(waddr_meter), .reg_wdata_i(reg_wdata_i));

	//	A GetNoise run ends when the spacing of the raw symbols changes or
	//	when the set of running rings does.
	karu_entropy #(
		.INTERVAL_RESET(INTERVAL_RESET), .INTERVAL_MIN(INTERVAL_MIN),
		.RCT_RESET(RCT_RESET), .RCT_MAX(RCT_MAX), .APT_RESET(APT_RESET), .APT_MAX(APT_MAX),
		.STRIKE_RESET(STRIKE_RESET), .STRIKE_MAX(STRIKE_MAX), .CALM_RESET(CALM_RESET), .CALM_MIN(CALM_MIN)
	) entropy (
		.clk(clk), .rst(rst), .en_i(en_i), .lane_i(strap_lane), .kshift_i(strap_k),
		.rng_en_o(rng_en), .rng_fips_o(rng_fips), .rng_val_i(rng_val), .rng_b_i(rng_b),
		.csr_fire_i(csr_fire_i), .csr_sel_i(csr_sel_i), .csr_we_i(csr_we_i),
		.csr_wdata_i(csr_wdata_i), .csr_rdata_o(csr_rdata_o),
		.respace_i(respace_burst || respace_meter), .test_o(noise_test), .lock_o(cfg_lock));

`ifndef KARU_NO_ASSERT
	// synthesis translate_off
	initial if (SAMPLE_DIV < 1 || SAMPLE_DIV > 256) begin
		$display("ASSERT: karu_entropy_src: SAMPLE_DIV must be 1..256"); $fatal;
	end
	//	The lane that seed delivers must be a ring that runs, or the source
	//	would only ever fail its start-up test.
	initial if (!RING_MASK[LANE]) begin
		$display("ASSERT: karu_entropy_src: the lane of the strap is not in RING_MASK"); $fatal;
	end
	// synthesis translate_on
`endif
endmodule
