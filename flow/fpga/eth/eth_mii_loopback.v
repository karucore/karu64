//	eth_mii_loopback.v
//	Simulation-only MII PHY loopback for the generated liteeth_core (E1).
//
//	The liteeth core is generated with LiteEthPHYMII, whose MII pads are normally
//	wired to an external 10/100 PHY. In simulation, this shim drives the eth
//	tx/rx clocks and feeds the MAC's transmitted
//	nibble stream straight back into its receiver, so a frame the driver sends is
//	delivered back to an RX slot (MAC-to-MAC loopback). The MAC still inserts the
//	preamble/SFD/FCS on TX and strips/checks them on RX, so this is a faithful
//	loopback of the whole MAC datapath.
//
//	eth_clk is the eth tx/rx clock. In sim we drive it from the core clock, so
//	the eth domain and the LiteEth sys (CSR) domain share a frequency; the LiteEth
//	internal CDC FIFOs are gray-coded and behave correctly with a synchronous
//	clock. (On real hardware the eth clocks come from the PCS/PHY instead.)

module eth_mii_loopback (
	input  wire			eth_clk,

	//	MII clock pads (inputs of liteeth_core) — driven here.
	output wire			mii_clocks_tx,
	output wire			mii_clocks_rx,

	//	MAC -> PHY (outputs of liteeth_core).
	input  wire [3:0]	mii_tx_data,
	input  wire			mii_tx_en,

	//	PHY -> MAC (inputs of liteeth_core) — looped back from TX.
	output reg  [3:0]	mii_rx_data,
	output reg			mii_rx_dv,
	output wire			mii_rx_er,
	output wire			mii_col,
	output wire			mii_crs
);
	assign mii_clocks_tx = eth_clk;
	assign mii_clocks_rx = eth_clk;
	assign mii_rx_er     = 1'b0;
	assign mii_col       = 1'b0;		//	full-duplex, never collide
	assign mii_crs       = mii_tx_en;	//	carrier sense follows TX

	initial begin
		mii_rx_data = 4'b0;
		mii_rx_dv   = 1'b0;
	end

	//	One-cycle registered nibble loopback (tx_clk == rx_clk == eth_clk).
	always @(posedge eth_clk) begin
		mii_rx_data <= mii_tx_data;
		mii_rx_dv   <= mii_tx_en;
	end
endmodule
