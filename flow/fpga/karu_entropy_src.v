//	karu_entropy_src.v
//	=== The entropy source of an SoC: ring-oscillator noise source plus the
//	entropy block, ready to connect to the zkr_* ports of karu64.
//
//	    karu_rosc_rng --raw 4-bit symbols--> karu_entropy --> seed, mnoise,
//	          ^   |                                           mentropycfg
//	   period |   +--> karu_noise_burst --> registers (reg_*)
//	          +------------+
//
//	The two halves talk through OpenTitan's raw noise-source interface, so
//	another noise source (an ASIC's analog one) replaces karu_rosc_rng
//	without touching rtl/karu_entropy.v.
//
//	karu_noise_burst is a measurement aid for characterising the rings: in
//	the entropy block's test mode, and only then, it sets the sampling
//	period (1 to 256 clocks) and records bursts of consecutive raw symbols.
//	Outside test mode the period is SAMPLE_DIV and the block holds nothing.
//	Its registers are reached through reg_*; a platform without them ties
//	the inputs low.
//
//	en_i is a platform strap. Low holds the noise source off and seed in
//	BIST, which OpenSBI and Linux both handle by falling back; it is the
//	way to take the source out of the boot if it misbehaves.
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
	//	3 bits per 4-bit symbol, 0.75 bit per lane bit, false alarms at 2^-40
	//	per test.
	parameter [15:0]  INTERVAL_RESET = 16'd15,	//	k-1: raw symbols per kept symbol, less one
	parameter [15:0]  INTERVAL_MIN   = INTERVAL_RESET,
	parameter [6:0]   SRCT_RESET     = 7'd15,
	parameter [6:0]   SRCT_MAX       = SRCT_RESET,
	parameter [9:0]   SAPT_RESET     = 10'd124,
	parameter [9:0]   SAPT_MAX       = SAPT_RESET,
	parameter [9:0]   RCT_RESET      = 10'd55,
	parameter [9:0]   RCT_MAX        = RCT_RESET,
	parameter [10:0]  APT_RESET      = 11'd719,
	parameter [10:0]  APT_MAX        = APT_RESET,
	parameter [2:0]   STRIKE_RESET   = 3'd3,
	parameter [2:0]   STRIKE_MAX     = STRIKE_RESET,
	parameter [4:0]   CALM_RESET     = 5'd24,
	parameter [4:0]   CALM_MIN       = CALM_RESET
) (
	input  wire			clk,
	input  wire			rst,
	input  wire			en_i,

	input  wire			csr_fire_i,
	input  wire [1:0]	csr_sel_i,
	input  wire			csr_we_i,
	input  wire [63:0]	csr_wdata_i,
	output wire [63:0]	csr_rdata_o,

	//	registers of the burst capture (karu_noise_burst.v)
	input  wire			reg_re_i,
	input  wire [2:0]	reg_raddr_i,
	output wire [63:0]	reg_rdata_o,
	input  wire			reg_we_i,
	input  wire [2:0]	reg_waddr_i,
	input  wire [63:0]	reg_wdata_i
);
	wire		rng_en, rng_fips, rng_val;
	wire [3:0]	rng_b;
	wire [7:0]	rng_div;
	wire		noise_test, cfg_lock, respace;
	localparam integer DIV_LESS_ONE = SAMPLE_DIV - 1;
	localparam [7:0] DIV_RESET = DIV_LESS_ONE[7:0];

	karu_rosc_rng #(.STREAMS(4), .SIM(SIM)) noise (
		.clk(clk), .rst(rst), .rng_en_i(rng_en), .rng_fips_i(rng_fips), .rng_div_i(rng_div),
		.rng_val_o(rng_val), .rng_b_o(rng_b));

	karu_noise_burst #(.LOG2_WORDS(BURST_LOG2_WORDS), .DIV_RESET(DIV_RESET)) burst (
		.clk(clk), .rst(rst), .test_i(noise_test), .lock_i(cfg_lock),
		.rng_en_i(rng_en), .rng_val_i(rng_val), .rng_b_i(rng_b), .div_o(rng_div), .respace_o(respace),
		.reg_re_i(reg_re_i), .reg_raddr_i(reg_raddr_i), .reg_rdata_o(reg_rdata_o),
		.reg_we_i(reg_we_i), .reg_waddr_i(reg_waddr_i), .reg_wdata_i(reg_wdata_i));

	karu_entropy #(
		.INTERVAL_RESET(INTERVAL_RESET), .INTERVAL_MIN(INTERVAL_MIN),
		.SRCT_RESET(SRCT_RESET), .SRCT_MAX(SRCT_MAX), .SAPT_RESET(SAPT_RESET), .SAPT_MAX(SAPT_MAX),
		.RCT_RESET(RCT_RESET), .RCT_MAX(RCT_MAX), .APT_RESET(APT_RESET), .APT_MAX(APT_MAX),
		.STRIKE_RESET(STRIKE_RESET), .STRIKE_MAX(STRIKE_MAX), .CALM_RESET(CALM_RESET), .CALM_MIN(CALM_MIN)
	) entropy (
		.clk(clk), .rst(rst), .en_i(en_i),
		.rng_en_o(rng_en), .rng_fips_o(rng_fips), .rng_val_i(rng_val), .rng_b_i(rng_b),
		.csr_fire_i(csr_fire_i), .csr_sel_i(csr_sel_i), .csr_we_i(csr_we_i),
		.csr_wdata_i(csr_wdata_i), .csr_rdata_o(csr_rdata_o),
		.respace_i(respace), .test_o(noise_test), .lock_o(cfg_lock));

`ifndef KARU_NO_ASSERT
	// synthesis translate_off
	initial if (SAMPLE_DIV < 1 || SAMPLE_DIV > 256) begin
		$display("ASSERT: karu_entropy_src: SAMPLE_DIV must be 1..256"); $fatal;
	end
	// synthesis translate_on
`endif
endmodule
