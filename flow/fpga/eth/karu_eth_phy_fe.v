//	karu_eth_phy_fe.v
//	=== DP83867 MDIO management front-end (E3 slice 1).
//	Encapsulates the sim-validated karu_dp83867_mdio init FSM (make mdio-test) with a
//	post-reset auto-start one-shot and the open-drain MDIO IOBUF, presenting the three
//	board pads (eth_mdc / eth_mdio / eth_phy_reset_n) plus status. Instantiated in
//	vcu118_ddr_top under `ifdef KARU_ETH_PHY; also the top for `make elab-eth` (so the
//	front-end elaborates in Vivado without the SoC's generated IP black boxes).
//
//	This is the PHY MANAGEMENT/reset path only. The SGMII datapath (the SelectIO/LVDS
//	1G Ethernet PCS/PMA -- B1 settled 2026-06-15, see doc/fpga.md) is a
//	later slice.

`timescale 1ns/1ps
`default_nettype none

module karu_eth_phy_fe #(
	parameter integer MDC_DIV = 25	//	MDC = clk/(2*MDC_DIV); 75MHz/50 = 1.5MHz (<=25MHz)
) (
	input  wire			clk,
	input  wire			rst,

	//	---- DP83867 management pads (LVCMOS18; pins in dp83867_mdio_pins.xdc) ----
	output wire			eth_mdc,
	inout  wire			eth_mdio,			//	open-drain, bidirectional
	output wire			eth_phy_reset_n,	//	active-low PHY hardware reset

	//	---- status ----
	output wire			id_ok,				//	PHYIDR1 == 0x2000 (PHY answered)
	output wire [15:0]	phy_id,
	output wire			mdio_done,
	output wire			mdio_error,
	output wire			mdio_busy
);
	wire		mdio_o, mdio_oe, mdio_i;

	//	one-shot: pulse `start` a few cycles after reset deasserts.
	reg  [3:0]	start_cnt = 4'd0;
	reg			started   = 1'b0;
	reg			start_pulse = 1'b0;
	always @(posedge clk) begin
		start_pulse <= 1'b0;
		if (rst) begin start_cnt <= 4'd0; started <= 1'b0; end
		else if (!started) begin
			if (start_cnt == 4'hf) begin start_pulse <= 1'b1; started <= 1'b1; end
			else start_cnt <= start_cnt + 1'b1;
		end
	end

	karu_dp83867_mdio #(.MDC_DIV(MDC_DIV)) u_mdio (
		.clk(clk), .rst(rst), .start(start_pulse),
		.busy(mdio_busy), .done(mdio_done), .error(mdio_error),
		.phy_id(phy_id), .id_ok(id_ok),
		.phy_reset_n(eth_phy_reset_n),
		.mdc(eth_mdc), .mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdio_i(mdio_i)
	);

	//	open-drain MDIO line (IEEE 802.3 Clause 22): actively drive LOW only (.I tied
	//	0); release to the board pull-up for a '1' or when not driving. So enable the
	//	output buffer (T low) only when the FSM wants to drive a 0 -- mdio_oe & ~mdio_o.
	IOBUF u_mdio_iobuf (
		.IO(eth_mdio), .I(1'b0), .O(mdio_i), .T(~(mdio_oe & ~mdio_o))
	);
endmodule

`default_nettype wire
