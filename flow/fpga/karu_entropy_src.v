//	karu_entropy_src.v
//	=== The entropy source of an SoC: ring-oscillator noise source plus the
//	entropy block, ready to connect to the zkr_* ports of karu64.
//
//	    karu_rosc_rng --raw 4-bit symbols--> karu_entropy --> seed, mnoise,
//	                                                          mentropycfg
//
//	The two halves talk through OpenTitan's raw noise-source interface, so
//	another noise source (an ASIC's analog one) replaces karu_rosc_rng
//	without touching rtl/karu_entropy.v.
//
//	en_i is a platform strap. Low holds the noise source off and seed in
//	BIST, which OpenSBI and Linux both handle by falling back; it is the
//	way to take the source out of the boot if it misbehaves.
//
//	The trng_* signals carry the same words in the format of the
//	karudbg_auth TRNG port, for an integration that still uses mdbgrng.
//	SPDX-License-Identifier: BSD-2-Clause

module karu_entropy_src #(
	parameter integer SIM            = 0,		//	1: behavioural noise model (no entropy)
	parameter integer SAMPLE_DIV     = 256,		//	clk cycles per raw symbol
	parameter [15:0]  INTERVAL_RESET = 16'd15,	//	k-1: raw symbols per kept symbol, less one
	parameter [15:0]  INTERVAL_MIN   = 16'd0,
	parameter [9:0]   RCT_RESET      = 10'd41,
	parameter [9:0]   RCT_MAX        = 10'd1023,
	parameter [10:0]  APT_RESET      = 11'd821,
	parameter [10:0]  APT_MAX        = 11'd1024
) (
	input  wire			clk,
	input  wire			rst,
	input  wire			en_i,

	input  wire			csr_fire_i,
	input  wire [1:0]	csr_sel_i,
	input  wire			csr_we_i,
	input  wire [63:0]	csr_wdata_i,
	output wire [63:0]	csr_rdata_o,

	output wire [1:0]	trng_opst_o,
	output wire [15:0]	trng_data_o,
	input  wire			trng_ack_i
);
	wire		rng_en, rng_fips, rng_val;
	wire [3:0]	rng_b;

	karu_rosc_rng #(.STREAMS(4), .SAMPLE_DIV(SAMPLE_DIV), .SIM(SIM)) noise (
		.clk(clk), .rst(rst), .rng_en_i(rng_en), .rng_fips_i(rng_fips),
		.rng_val_o(rng_val), .rng_b_o(rng_b));

	karu_entropy #(
		.INTERVAL_RESET(INTERVAL_RESET), .INTERVAL_MIN(INTERVAL_MIN),
		.RCT_RESET(RCT_RESET), .RCT_MAX(RCT_MAX), .APT_RESET(APT_RESET), .APT_MAX(APT_MAX)
	) entropy (
		.clk(clk), .rst(rst), .en_i(en_i),
		.rng_en_o(rng_en), .rng_fips_o(rng_fips), .rng_val_i(rng_val), .rng_b_i(rng_b),
		.csr_fire_i(csr_fire_i), .csr_sel_i(csr_sel_i), .csr_we_i(csr_we_i),
		.csr_wdata_i(csr_wdata_i), .csr_rdata_o(csr_rdata_o),
		.opst_o(trng_opst_o), .data_o(trng_data_o), .trng_ack_i(trng_ack_i));
endmodule
