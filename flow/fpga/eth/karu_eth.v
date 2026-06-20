//	karu_eth.v
//	karu64 <-> LiteEth bridge: wraps the generated liteeth_core (a 32-bit
//	wishbone MAC) + the sim MII loopback, and presents karu64's simple strobed
//	MMIO-slave convention to the SoC interconnect.
//
//	karu64's LSU issues only 8-byte-aligned MMIO reads (it extracts the wanted
//	32-bit lane itself), so a read returns BOTH 32-bit halves of the addressed
//	64-bit unit -> two wishbone read beats. A write drives whichever 32-bit
//	lane(s) wstrb selects -> one or two wishbone write beats. CSR accesses are
//	always full 32-bit words (sel = 1111); only slot-SRAM writes use sub-word
//	sel, which the core honours (full_memory_we).
//
//	Multi-cycle: a read/write takes several cycles (wishbone ack latency x beats).
//	`busy` is high for the duration; rd_done/wr_done pulse for one cycle when the
//	transaction retires. The caller must not assert a new *_req while busy.
//
//	The eth window is a flat 1 MiB region (pa[31:20] == 0x110): CSRs at
//	0x1100_xxxx, slot SRAM at 0x1101_xxxx. The wishbone slave decodes the full
//	absolute address, so wb adr = byte_addr >> 2.

module karu_eth (
	input  wire			clk,
	input  wire			rst,

	//	== simple MMIO slave (karu64 strobed convention) ==
	input  wire			rd_req,		//	pulse: start a 64-bit read @rd_addr
	input  wire [31:0]	rd_addr,
	output reg			rd_done,	//	1-cyc pulse: rd_data valid
	output reg  [63:0]	rd_data,

	input  wire			wr_req,		//	pulse: start a write
	input  wire [31:0]	wr_addr,
	input  wire [7:0]	wr_strb,
	input  wire [63:0]	wr_data,
	output reg			wr_done,	//	1-cyc pulse: write committed

	output wire			busy,

	//	== interrupt to the PLIC (source 2) ==
	output wire			eth_irq
`ifdef KARU_ETH_SGMII
	//	== GMII to the on-chip 1G PCS/PMA (SGMII datapath; threaded up via the xbar) ==
	,input  wire		eth_clk125,		//	125 MHz GMII clock from the PCS (clk125_out)
	 output wire [7:0]	gmii_tx_data,
	 output wire		gmii_tx_en,
	 output wire		gmii_tx_er,
	 input  wire [7:0]	gmii_rx_data,
	 input  wire		gmii_rx_dv,
	 input  wire		gmii_rx_er
`endif
);
	//	---- wishbone master <-> liteeth_core ----
	wire			wb_cyc, wb_stb, wb_we;
	reg				wb_cyc_r, wb_stb_r, wb_we_r;
	reg  [29:0]		wb_adr;
	reg  [3:0]		wb_sel;
	reg  [31:0]		wb_dat_w;
	wire [31:0]		wb_dat_r;
	wire			wb_ack;
	assign wb_cyc = wb_cyc_r;
	assign wb_stb = wb_stb_r;
	assign wb_we  = wb_we_r;

`ifdef KARU_ETH_SGMII
	//	---- GMII MAC core (SGMII datapath): GMII <-> on-chip 1G PCS/PMA, no loopback.
	//	clk125 from the PCS drives both GMII directions; the external PHY is managed by
	//	karu_dp83867_mdio, so LiteEth's own MDIO is dropped (KARU_ETH_NO_MDIO_IOBUF).
	liteeth_core u_core (
		.sys_clock		(clk),
		.sys_reset		(rst),

		.interrupt		(eth_irq),

		//	wishbone slave
		.wishbone_adr	(wb_adr),
		.wishbone_dat_w	(wb_dat_w),
		.wishbone_dat_r	(wb_dat_r),
		.wishbone_sel	(wb_sel),
		.wishbone_cyc	(wb_cyc),
		.wishbone_stb	(wb_stb),
		.wishbone_we	(wb_we),
		.wishbone_ack	(wb_ack),
		.wishbone_err	(/* unused */),
		.wishbone_cti	(3'b000),
		.wishbone_bte	(2'b00),

		//	GMII <-> on-chip PCS/PMA
		.gmii_clocks_gtx	(/* unused: no external PHY clock forward */),
		.gmii_clocks_rx		(eth_clk125),
		.gmii_clocks_tx		(eth_clk125),
		.gmii_col			(1'b0),
		.gmii_crs			(1'b0),
		.gmii_int_n			(1'b1),
		.gmii_mdc			(/* unused: PHY managed by karu_dp83867_mdio */),
		.gmii_mdio			(/* unused: KARU_ETH_NO_MDIO_IOBUF drops the IOBUF */),
		.gmii_rst_n			(/* unused */),
		.gmii_rx_data		(gmii_rx_data),
		.gmii_rx_dv			(gmii_rx_dv),
		.gmii_rx_er			(gmii_rx_er),
		.gmii_tx_data		(gmii_tx_data),
		.gmii_tx_en			(gmii_tx_en),
		.gmii_tx_er			(gmii_tx_er)
	);
`else
	//	---- MII loopback nets ----
	wire		mii_clocks_tx, mii_clocks_rx;
	wire [3:0]	mii_tx_data;
	wire		mii_tx_en;
	wire [3:0]	mii_rx_data;
	wire		mii_rx_dv, mii_rx_er, mii_col, mii_crs;
	wire		mii_mdio;	//	left dangling (driver uses no MDIO in sim)

	liteeth_core u_core (
		.sys_clock		(clk),
		.sys_reset		(rst),

		.interrupt		(eth_irq),

		//	wishbone slave
		.wishbone_adr	(wb_adr),
		.wishbone_dat_w	(wb_dat_w),
		.wishbone_dat_r	(wb_dat_r),
		.wishbone_sel	(wb_sel),
		.wishbone_cyc	(wb_cyc),
		.wishbone_stb	(wb_stb),
		.wishbone_we	(wb_we),
		.wishbone_ack	(wb_ack),
		.wishbone_err	(/* unused */),
		.wishbone_cti	(3'b000),
		.wishbone_bte	(2'b00),

		//	MII pads <-> loopback
		.mii_clocks_tx	(mii_clocks_tx),
		.mii_clocks_rx	(mii_clocks_rx),
		.mii_tx_data	(mii_tx_data),
		.mii_tx_en		(mii_tx_en),
		.mii_rx_data	(mii_rx_data),
		.mii_rx_dv		(mii_rx_dv),
		.mii_rx_er		(mii_rx_er),
		.mii_col		(mii_col),
		.mii_crs		(mii_crs),
		.mii_mdc		(/* unused */),
		.mii_mdio		(mii_mdio),
		.mii_rst_n		(/* unused */)
	);

	//	Sim MII back-end: KARU_ETH_DPI selects the host packet backend (DPI ->
	//	flow/eth_backend.c, for U-Boot arp/ping/tftp); otherwise a plain TX->RX
	//	loopback (eth-sim / Linux GE1).
`ifdef KARU_ETH_DPI
	eth_mii_dpi u_lb (
`else
	eth_mii_loopback u_lb (
`endif
		.eth_clk		(clk),
		.mii_clocks_tx	(mii_clocks_tx),
		.mii_clocks_rx	(mii_clocks_rx),
		.mii_tx_data	(mii_tx_data),
		.mii_tx_en		(mii_tx_en),
		.mii_rx_data	(mii_rx_data),
		.mii_rx_dv		(mii_rx_dv),
		.mii_rx_er		(mii_rx_er),
		.mii_col		(mii_col),
		.mii_crs		(mii_crs)
	);
`endif

	//	---- bridge FSM ----
	//	Each beat asserts stb for one transfer, then a GAP state drops stb (cyc
	//	stays high) for a cycle before the next beat. This is required because
	//	LiteX's wishbone CSR/SRAM slaves register their ack: holding stb high
	//	across beats would re-sample the previous beat's stale ack+data (which
	//	corrupted high-word CSRs like READER_READY / WRITER_LENGTH).
	localparam [2:0] S_IDLE = 3'd0,
					 S_R0   = 3'd1,	//	read low word
					 S_R0G  = 3'd2,	//	gap (stb low) between read beats
					 S_R1   = 3'd3,	//	read high word
					 S_W0   = 3'd4,	//	write low lane
					 S_W0G  = 3'd5,	//	gap (stb low) between write beats
					 S_W1   = 3'd6;	//	write high lane
	reg [2:0]	st;

	reg [29:0]	adr_lo, adr_hi;
	reg [3:0]	sel_lo, sel_hi;
	reg [31:0]	dat_lo, dat_hi;
	reg [31:0]	rd_lo;

	assign busy = (st != S_IDLE);

	//	8-byte-aligned byte base of the access, and the two 32-bit word addrs.
	wire [31:0] base8_r = {rd_addr[31:3], 3'b000};
	wire [31:0] base8_w = {wr_addr[31:3], 3'b000};

	always @(*) begin
		wb_cyc_r = 1'b0; wb_stb_r = 1'b0; wb_we_r = 1'b0;
		wb_adr = 30'b0; wb_sel = 4'b0; wb_dat_w = 32'b0;
		case (st)
			S_R0:  begin wb_cyc_r=1; wb_stb_r=1; wb_we_r=0; wb_adr=adr_lo; wb_sel=4'hf; end
			S_R0G: begin wb_cyc_r=1; wb_stb_r=0; end	//	gap: cyc held, stb low
			S_R1:  begin wb_cyc_r=1; wb_stb_r=1; wb_we_r=0; wb_adr=adr_hi; wb_sel=4'hf; end
			S_W0:  begin wb_cyc_r=1; wb_stb_r=1; wb_we_r=1; wb_adr=adr_lo; wb_sel=sel_lo; wb_dat_w=dat_lo; end
			S_W0G: begin wb_cyc_r=1; wb_stb_r=0; end	//	gap: cyc held, stb low
			S_W1:  begin wb_cyc_r=1; wb_stb_r=1; wb_we_r=1; wb_adr=adr_hi; wb_sel=sel_hi; wb_dat_w=dat_hi; end
			default: ;
		endcase
	end

	always @(posedge clk) begin
		if (rst) begin
			st <= S_IDLE;
			rd_done <= 1'b0;
			wr_done <= 1'b0;
		end else begin
			rd_done <= 1'b0;
			wr_done <= 1'b0;
			case (st)
				S_IDLE: begin
					if (rd_req) begin
						adr_lo <= base8_r[31:2];
						adr_hi <= (base8_r + 32'd4) >> 2;
						st     <= S_R0;
					end else if (wr_req) begin
						adr_lo <= base8_w[31:2];
						adr_hi <= (base8_w + 32'd4) >> 2;
						sel_lo <= wr_strb[3:0];
						sel_hi <= wr_strb[7:4];
						dat_lo <= wr_data[31:0];
						dat_hi <= wr_data[63:32];
						if (wr_strb[3:0] != 4'b0)      st <= S_W0;
						else if (wr_strb[7:4] != 4'b0) st <= S_W1;
						else                           wr_done <= 1'b1;	//	empty write
					end
				end
				S_R0:  if (wb_ack) begin rd_lo <= wb_dat_r; st <= S_R0G; end
				S_R0G: if (!wb_ack) st <= S_R1;	//	wait for stale ack to clear
				S_R1:  if (wb_ack) begin
						rd_data <= {wb_dat_r, rd_lo};
						rd_done <= 1'b1;
						st      <= S_IDLE;
					end
				S_W0:  if (wb_ack) begin
						if (sel_hi != 4'b0) st <= S_W0G;
						else begin wr_done <= 1'b1; st <= S_IDLE; end
					end
				S_W0G: if (!wb_ack) st <= S_W1;	//	wait for stale ack to clear
				S_W1:  if (wb_ack) begin wr_done <= 1'b1; st <= S_IDLE; end
				default: st <= S_IDLE;
			endcase
		end
	end
endmodule
