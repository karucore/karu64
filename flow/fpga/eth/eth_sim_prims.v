//	eth_sim_prims.v
//	Behavioral models of the two Xilinx unisim primitives that LiteEth's
//	`vendor: xilinx` generation bakes into liteeth_core.v:
//	  - FDPE : D-FF with clock-enable + async preset (the eth_tx/eth_rx reset
//	           synchronisers, INIT=1, PRE -> Q=1).
//	  - IOBUF: the MDIO bidirectional pad (I drive, T tristate, O sense).
//
//	These are for the *simulation* builds (verilator / iverilog) only. The
//	Vivado flow reads the real unisims, so this file is excluded there (it is
//	listed only in the sim source lists, never in the synth read list).

`ifndef KARU_ETH_SIM_PRIMS_V
`define KARU_ETH_SIM_PRIMS_V

module FDPE #(
	parameter INIT = 1'b0
) (
	input  wire C,
	input  wire CE,
	input  wire D,
	input  wire PRE,
	output reg  Q
);
	initial Q = INIT;
	always @(posedge C or posedge PRE) begin
		if (PRE)      Q <= 1'b1;
		else if (CE)  Q <= D;
	end
endmodule

module IOBUF (
	input  wire I,
	input  wire T,
	output wire O,
	inout  wire IO
);
	assign IO = T ? 1'bz : I;
	assign O  = IO;
endmodule

`endif
