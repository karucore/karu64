//	reset_ctrl.v
//	=== Reset conditioning for the karu64 SoC: power-on reset (POR) stretch
//	+ a 2-flop synchronizer on the asynchronous push-button input.
//
//	The board's reset request (`arst_in`) is a raw, asynchronous, bouncy
//	push-button level. Feeding it straight into the core risks
//	metastability (the button edge is unrelated to `clk`) and a too-short
//	reset pulse. This module produces a clean, synchronous, active-high
//	`rst_out` that:
//	  1. is held asserted for POR_CYCLES cycles after configuration /
//	     power-up (the POR stretch -- gives the BRAM init + core a clean
//	     start before the first instruction fetch), and
//	  2. tracks `arst_in` through a 2-FF synchronizer thereafter (async
//	     assertion is captured cleanly; release is synchronized to `clk`).
//
//	The POR is realized with initial values: in simulation the regs start
//	in the POR state; on the FPGA the same initial values are loaded by the
//	global set/reset (GSR) at the end of configuration. Synthesizes on
//	Vivado (the ASYNC_REG attribute keeps the two synchronizer flops
//	together and tells the tool to relax timing on the async capture).

module reset_ctrl #(
	parameter	POR_CYCLES = 1024	//	cycles to hold reset after power-up
) (
	input  wire	clk,
	input  wire	arst_in,			//	async active-high reset request (button)
	output wire	rst_out				//	clean sync active-high reset to the SoC
);
	//	---- 2-FF synchronizer for the async button level ----
	(* ASYNC_REG = "TRUE" *) reg sync0 = 1'b1;
	(* ASYNC_REG = "TRUE" *) reg sync1 = 1'b1;

	always @(posedge clk) begin
		sync0 <= arst_in;
		sync1 <= sync0;
	end

	//	---- power-on reset stretch ----
	//	count from 0 up to POR_CYCLES, then drop `por`. The init state
	//	(por=1, cnt=0) is the post-configuration / power-up state.
	localparam CW = (POR_CYCLES < 2) ? 1 : $clog2(POR_CYCLES + 1);

	reg [CW-1:0]	por_cnt = {CW{1'b0}};
	reg				por     = 1'b1;

	always @(posedge clk) begin
		if (por) begin
			if (por_cnt == POR_CYCLES[CW-1:0])
				por <= 1'b0;
			else
				por_cnt <= por_cnt + 1'b1;
		end
	end

	//	assert reset while the POR is stretching OR the button is held.
	assign rst_out = por | sync1;

endmodule
