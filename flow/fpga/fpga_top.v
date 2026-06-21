//	fpga_top.v
//	=== board-agnostic karu64 SoC for FPGA targets.
//
//	karu64 + on-chip BRAM + NS16550 UART. The whole thing is driven by a
//	single clock and an active-high reset; the board wrapper (e.g.
//	vcu118_top.v) supplies the clock/reset and the serial pins.

`include "karu_ext.vh"
`include "karu_axi_defs.vh"

module fpga_top #(
	parameter		RAM_XADR = 20,				//	1 MiB on-chip RAM
	parameter [31:0] RESET_PC = 32'h8000_0000,
	parameter		HEXFILE	 = "firmware.hex"
) (
	input  wire			clk,
	input  wire			rst,
	output wire			uart_txd,
	input  wire			uart_rxd,
	output wire			uart_rts,
	input  wire			uart_cts,
	output wire			trap
);
	//	Interrupt sources, driven by the on-chip CLINT (machine timer) and PLIC
	//	(external) inside karu_axi_mem and routed to the core below.
	wire	irq_timer;
	wire	irq_ext_m;
	wire	irq_ext_s;

	//	== imem AXI4 ==
	wire [`AXI_ID_W-1:0]	imem_arid;
	wire [`AXI_ADDR_W-1:0]	imem_araddr;
	wire [`AXI_LEN_W-1:0]	imem_arlen;
	wire [`AXI_SIZE_W-1:0]	imem_arsize;
	wire [`AXI_BURST_W-1:0]	imem_arburst;
	wire [`AXI_PROT_W-1:0]	imem_arprot;
	wire					imem_arvalid;
	wire					imem_arready;
	wire [`AXI_ID_W-1:0]	imem_rid;
	wire [`AXI_DATA_W-1:0]	imem_rdata;
	wire [`AXI_RESP_W-1:0]	imem_rresp;
	wire					imem_rlast;
	wire					imem_rvalid;
	wire					imem_rready;

	//	== dmem AXI4 ==
	wire [`AXI_ID_W-1:0]	dmem_arid;
	wire [`AXI_ADDR_W-1:0]	dmem_araddr;
	wire [`AXI_LEN_W-1:0]	dmem_arlen;
	wire [`AXI_SIZE_W-1:0]	dmem_arsize;
	wire [`AXI_BURST_W-1:0]	dmem_arburst;
	wire [`AXI_PROT_W-1:0]	dmem_arprot;
	wire					dmem_arvalid;
	wire					dmem_arready;
	wire [`AXI_ID_W-1:0]	dmem_rid;
	wire [`AXI_DATA_W-1:0]	dmem_rdata;
	wire [`AXI_RESP_W-1:0]	dmem_rresp;
	wire					dmem_rlast;
	wire					dmem_rvalid;
	wire					dmem_rready;
	wire [`AXI_ID_W-1:0]	dmem_awid;
	wire [`AXI_ADDR_W-1:0]	dmem_awaddr;
	wire [`AXI_LEN_W-1:0]	dmem_awlen;
	wire [`AXI_SIZE_W-1:0]	dmem_awsize;
	wire [`AXI_BURST_W-1:0]	dmem_awburst;
	wire [`AXI_PROT_W-1:0]	dmem_awprot;
	wire					dmem_awvalid;
	wire					dmem_awready;
	wire [`AXI_DATA_W-1:0]	dmem_wdata;
	wire [`AXI_STRB_W-1:0]	dmem_wstrb;
	wire					dmem_wlast;
	wire					dmem_wvalid;
	wire					dmem_wready;
	wire [`AXI_ID_W-1:0]	dmem_bid;
	wire [`AXI_RESP_W-1:0]	dmem_bresp;
	wire					dmem_bvalid;
	wire					dmem_bready;

	karu64 #(
		.RESET_PC	(RESET_PC)
	) cpu (
		.clk		(clk),
		.rst		(rst),
		.trap		(trap),
		.irq		(irq_timer),			//	CLINT machine timer (driven below)
		.irq_external_m	(irq_ext_m),		//	PLIC -> M-mode external
		.irq_external_s	(irq_ext_s),		//	PLIC -> S-mode external
		.time_in	(64'b0),				//	EXT_TIME=0: rdtime uses the cycle counter
		.hpm_events	(32'b0),				//	no HPM event sources wired yet
		//	No D-cache outside the core in this SoC, so FENCE/FENCE.I complete
		//	immediately: hold cache_flush_done high, leave req/invalidate open.
		.cache_flush_req		(),
		.cache_flush_invalidate	(),
		.cache_flush_done		(1'b1),
		//	NS16550 page is uncacheable (MMIO, RVWMO non-cacheable I/O).
		.uncache_page (32'h1000_0000),
		.imem_arid		(imem_arid),	.imem_araddr	(imem_araddr),
		.imem_arlen		(imem_arlen),	.imem_arsize	(imem_arsize),
		.imem_arburst	(imem_arburst),	.imem_arprot	(imem_arprot),
		.imem_arvalid	(imem_arvalid),	.imem_arready	(imem_arready),
		.imem_rid		(imem_rid),		.imem_rdata		(imem_rdata),
		.imem_rresp		(imem_rresp),	.imem_rlast		(imem_rlast),
		.imem_rvalid	(imem_rvalid),	.imem_rready	(imem_rready),
		.dmem_arid		(dmem_arid),	.dmem_araddr	(dmem_araddr),
		.dmem_arlen		(dmem_arlen),	.dmem_arsize	(dmem_arsize),
		.dmem_arburst	(dmem_arburst),	.dmem_arprot	(dmem_arprot),
		.dmem_arvalid	(dmem_arvalid),	.dmem_arready	(dmem_arready),
		.dmem_rid		(dmem_rid),		.dmem_rdata		(dmem_rdata),
		.dmem_rresp		(dmem_rresp),	.dmem_rlast		(dmem_rlast),
		.dmem_rvalid	(dmem_rvalid),	.dmem_rready	(dmem_rready),
		.dmem_awid		(dmem_awid),	.dmem_awaddr	(dmem_awaddr),
		.dmem_awlen		(dmem_awlen),	.dmem_awsize	(dmem_awsize),
		.dmem_awburst	(dmem_awburst),	.dmem_awprot	(dmem_awprot),
		.dmem_awvalid	(dmem_awvalid),	.dmem_awready	(dmem_awready),
		.dmem_wdata		(dmem_wdata),	.dmem_wstrb		(dmem_wstrb),
		.dmem_wlast		(dmem_wlast),	.dmem_wvalid	(dmem_wvalid),
		.dmem_wready	(dmem_wready),
		.dmem_bid		(dmem_bid),		.dmem_bresp		(dmem_bresp),
		.dmem_bvalid	(dmem_bvalid),	.dmem_bready	(dmem_bready)
	);

	karu_axi_mem #(
		.RAM_XADR	(RAM_XADR),
		.HEXFILE	(HEXFILE)
	) sys (
		.clk		(clk),
		.rst		(rst),
		.imem_arid		(imem_arid),	.imem_araddr	(imem_araddr),
		.imem_arlen		(imem_arlen),	.imem_arsize	(imem_arsize),
		.imem_arburst	(imem_arburst),	.imem_arprot	(imem_arprot),
		.imem_arvalid	(imem_arvalid),	.imem_arready	(imem_arready),
		.imem_rid		(imem_rid),		.imem_rdata		(imem_rdata),
		.imem_rresp		(imem_rresp),	.imem_rlast		(imem_rlast),
		.imem_rvalid	(imem_rvalid),	.imem_rready	(imem_rready),
		.dmem_arid		(dmem_arid),	.dmem_araddr	(dmem_araddr),
		.dmem_arlen		(dmem_arlen),	.dmem_arsize	(dmem_arsize),
		.dmem_arburst	(dmem_arburst),	.dmem_arprot	(dmem_arprot),
		.dmem_arvalid	(dmem_arvalid),	.dmem_arready	(dmem_arready),
		.dmem_rid		(dmem_rid),		.dmem_rdata		(dmem_rdata),
		.dmem_rresp		(dmem_rresp),	.dmem_rlast		(dmem_rlast),
		.dmem_rvalid	(dmem_rvalid),	.dmem_rready	(dmem_rready),
		.dmem_awid		(dmem_awid),	.dmem_awaddr	(dmem_awaddr),
		.dmem_awlen		(dmem_awlen),	.dmem_awsize	(dmem_awsize),
		.dmem_awburst	(dmem_awburst),	.dmem_awprot	(dmem_awprot),
		.dmem_awvalid	(dmem_awvalid),	.dmem_awready	(dmem_awready),
		.dmem_wdata		(dmem_wdata),	.dmem_wstrb		(dmem_wstrb),
		.dmem_wlast		(dmem_wlast),	.dmem_wvalid	(dmem_wvalid),
		.dmem_wready	(dmem_wready),
		.dmem_bid		(dmem_bid),		.dmem_bresp		(dmem_bresp),
		.dmem_bvalid	(dmem_bvalid),	.dmem_bready	(dmem_bready),
		.uart_txd	(uart_txd),
		.uart_rxd	(uart_rxd),
		.uart_rts	(uart_rts),
		.uart_cts	(uart_cts),
		.irq_timer	(irq_timer),
		.irq_ext_m	(irq_ext_m),
		.irq_ext_s	(irq_ext_s)
	);

endmodule
