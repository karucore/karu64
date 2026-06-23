//	eth_mii_dpi.sv
//	Simulation-only MII <-> host packet backend for the generated liteeth_core
//	(Ethernet phase E2c). Drop-in replacement for eth_mii_loopback: same ports,
//	but instead of echoing TX->RX it hands each transmitted MII frame to a C
//	backend (flow/eth_backend.c) over DPI and clocks the backend's replies back
//	in on RX. That gives U-Boot something to talk to for arp / ping / tftp.
//
//	Wire bytes (preamble 0x55.. + SFD 0xD5 + frame + FCS) cross the DPI verbatim;
//	the backend strips/builds the preamble+SFD+FCS, so this module is "dumb": it
//	just (de)serialises nibbles. MII sends the low nibble first.
//
//	Selected over the loopback by `KARU_ETH_DPI` in karu_eth.v.

module eth_mii_dpi (
	input  wire			eth_clk,

	output wire			mii_clocks_tx,
	output wire			mii_clocks_rx,

	input  wire [3:0]	mii_tx_data,
	input  wire			mii_tx_en,

	output reg  [3:0]	mii_rx_data,
	output reg			mii_rx_dv,
	output wire			mii_rx_er,
	output wire			mii_col,
	output wire			mii_crs
);
`ifdef VERILATOR
	import "DPI-C" function void eth_dpi_tx_byte(input byte unsigned b);
	import "DPI-C" function void eth_dpi_tx_eof();
	import "DPI-C" function int  eth_dpi_rx_byte();	//	next RX wire byte, or -1
`endif

	assign mii_clocks_tx = eth_clk;
	assign mii_clocks_rx = eth_clk;
	assign mii_rx_er     = 1'b0;
	assign mii_col       = 1'b0;
	assign mii_crs       = mii_rx_dv || mii_tx_en;

	//	---- TX: MII nibbles -> bytes -> backend ----
	reg [3:0]	tx_lo;
	reg			tx_phase;	//	0 = capturing low nibble, 1 = high nibble
	reg			tx_en_q;
	always @(posedge eth_clk) begin
		tx_en_q <= mii_tx_en;
		if (mii_tx_en) begin
			if (!tx_phase) begin
				tx_lo    <= mii_tx_data;	//	low nibble first
				tx_phase <= 1'b1;
			end else begin
`ifdef VERILATOR
				eth_dpi_tx_byte({mii_tx_data, tx_lo});
`endif
				tx_phase <= 1'b0;
			end
		end else begin
			tx_phase <= 1'b0;
`ifdef VERILATOR
			if (tx_en_q) eth_dpi_tx_eof();	//	end of a transmitted frame
`endif
		end
	end

	//	---- RX: backend bytes -> MII nibbles ----
	reg [7:0]	rx_cur;
	reg			rx_phase;	//	0 = fetch byte + emit low nibble, 1 = emit high
	integer		rx_b;
	initial begin
		mii_rx_data = 4'b0;
		mii_rx_dv   = 1'b0;
		rx_phase    = 1'b0;
	end
	always @(posedge eth_clk) begin
		if (rx_phase == 1'b0) begin
			rx_b = -1;
`ifdef VERILATOR
			rx_b = eth_dpi_rx_byte();
`endif
			if (rx_b >= 0) begin
				rx_cur      <= rx_b[7:0];
				mii_rx_data <= rx_b[3:0];	//	low nibble
				mii_rx_dv   <= 1'b1;
				rx_phase    <= 1'b1;
			end else begin
				mii_rx_dv   <= 1'b0;		//	inter-frame idle
			end
		end else begin
			mii_rx_data <= rx_cur[7:4];		//	high nibble
			mii_rx_dv   <= 1'b1;
			rx_phase    <= 1'b0;
		end
	end
endmodule
