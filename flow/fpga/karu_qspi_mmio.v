//	karu_qspi_mmio.v
//	=== Minimal STARTUPE3-backed SPI flash byte-transfer engine.
//
//	This is intentionally a small bring-up block, not a high-throughput QSPI
//	controller. Firmware controls chip-select, writes one TX byte to start an
//	8-bit SPI transfer, polls BUSY/DONE, and reads the received byte. That is
//	enough for a bootloader to send 0x03 + 24-bit flash offset and stream a
//	compressed firmware image out of configuration flash into DDR.
//
//	Register map, 0x1200_0000 page, 64-bit AXI-MMIO lane 0:
//	  +0x00 CTRL/STATUS read:
//	        bit 0  busy
//	        bit 1  done/rx_valid (sticky until next TX or clear)
//	        bit 2  STARTUPE3 EOS (1 after configuration startup)
//	        bit 15 cs_n
//	        bit 31:16 SPI half-period divider
//	  +0x00 CTRL write:
//	        bit 0  cs_n (1 deassert, 0 assert)
//	        bit 1  clear done
//	  +0x08 DATA read:  rx byte in bits 7:0
//	  +0x08 DATA write: tx byte in bits 7:0; starts transfer when !busy
//	  +0x10 DIV write:  half-period divider, minimum 1

module karu_qspi_mmio #(
	parameter integer DIV_RESET = 8
) (
	input  wire			clk,
	input  wire			rst,

	input  wire			re,
	input  wire [4:0]	raddr,
	output reg  [63:0]	rdata,

	input  wire			we,
	input  wire [4:0]	waddr,
	input  wire [7:0]	wstrb,
	input  wire [63:0]	wdata,
	output wire			busy
);
	reg			cs_n;
	reg			done;
	reg [15:0]	div;
	reg [15:0]	divcnt;
	reg [3:0]	bitcnt;
	reg [7:0]	sh_tx;
	reg [7:0]	sh_rx;
	reg [7:0]	rx_byte;
	reg			sck;
	reg			active;

	wire [1:0]	regsel = raddr[4:3];
	wire		tx_write = we && (waddr[4:3] == 2'd1) && wstrb[0];
	assign		busy = active;

`ifdef SIM_TB
	wire [3:0]	su_di = 4'b0010;
	wire		su_eos = 1'b1;
`else
	wire		su_cfgclk, su_cfgmclk, su_preq;
	wire [3:0]	su_di;
	wire		su_eos;
	wire [3:0]	su_do = {2'b11, 1'b0, sh_tx[7]};
	wire [3:0]	su_dts = cs_n ? 4'b1111 : 4'b0010;	// DQ3/DQ2 high, DQ1 input, DQ0 out

	STARTUPE3 #(
		.PROG_USR("FALSE"),
		.SIM_CCLK_FREQ(0.0)
	) u_startupe3 (
		.CFGCLK(su_cfgclk),
		.CFGMCLK(su_cfgmclk),
		.DI(su_di),
		.EOS(su_eos),
		.PREQ(su_preq),
		.DO(su_do),
		.DTS(su_dts),
		.FCSBO(cs_n),
		.FCSBTS(1'b0),
		.GSR(1'b0),
		.GTS(1'b0),
		.KEYCLEARB(1'b1),
		.PACK(1'b0),
		.USRCCLKO(sck),
		.USRCCLKTS(cs_n),
		.USRDONEO(1'b1),
		.USRDONETS(1'b1)
	);

	wire _unused_su = &{su_cfgclk, su_cfgmclk, su_preq, 1'b0};
`endif

	always @(*) begin
		case (regsel)
		2'd0: rdata = {32'b0, div, 1'b0, cs_n, 12'b0, su_eos, done, active};
		2'd1: rdata = {56'b0, rx_byte};
		2'd2: rdata = {48'b0, div};
		default: rdata = 64'b0;
		endcase
	end

	always @(posedge clk) begin
		if (rst) begin
			cs_n <= 1'b1;
			done <= 1'b0;
			div <= DIV_RESET[15:0];
			divcnt <= 16'd0;
			bitcnt <= 4'd0;
			sh_tx <= 8'd0;
			sh_rx <= 8'd0;
			rx_byte <= 8'd0;
			sck <= 1'b0;
			active <= 1'b0;
		end else begin
			if (we && (waddr[4:3] == 2'd0) && wstrb[0]) begin
				cs_n <= wdata[0];
				if (wdata[1])
					done <= 1'b0;
				if (wdata[0])
					sck <= 1'b0;
			end

			if (we && (waddr[4:3] == 2'd2)) begin
				if (|wdata[15:0])
					div <= wdata[15:0];
				else
					div <= 16'd1;
			end

			if (tx_write && !active) begin
				sh_tx <= wdata[7:0];
				sh_rx <= 8'd0;
				bitcnt <= 4'd8;
				divcnt <= div;
				sck <= 1'b0;
				active <= 1'b1;
				done <= 1'b0;
			end else if (active) begin
				if (divcnt != 16'd0) begin
					divcnt <= divcnt - 16'd1;
				end else begin
					divcnt <= div;
					sck <= ~sck;
					if (!sck) begin
						// Rising edge: flash samples MOSI, fabric samples MISO.
						sh_rx <= {sh_rx[6:0], su_di[1]};
					end else begin
						// Falling edge: advance MOSI for the next bit.
						sh_tx <= {sh_tx[6:0], 1'b0};
						bitcnt <= bitcnt - 4'd1;
						if (bitcnt == 4'd1) begin
							active <= 1'b0;
							done <= 1'b1;
							//	sh_rx already holds the 8 bits sampled on the
							//	8 rising edges (b1..b8). Latch it directly.
							//	The previous {sh_rx[6:0], su_di[1]} dropped the
							//	MSB and re-sampled MISO on this falling edge --
							//	where the flash still holds the prior bit -- so
							//	every byte came out shifted left by one bit
							//	(HW: JEDEC 20 BB 21 read back as 40 77 43).
							rx_byte <= sh_rx;
							sck <= 1'b0;
						end
					end
				end
			end
		end
	end

	wire _unused = &{re, wstrb[7:1], wdata[63:16], 1'b0};
endmodule
