//	fpga_ddr_top.v
//	=== karu64 SoC with main memory behind the DDR4/MIG bridge.
//
//	Same role as fpga_top.v, but main memory is reached through karu_ddr_xbar
//	(imem+dmem -> one AXI4 master) instead of the unified BRAM karu_axi_mem.
//	In sim the master drives the behavioral karu_axi4_ram (the MIG stand-in);
//	on hardware vcu118_ddr_top swaps that for the MIG user-AXI slave. CLINT,
//	PLIC and the NS16550 live inside the xbar as on-chip MMIO siblings.

`include "config.vh"
`include "karu_axi_defs.vh"

module fpga_ddr_top #(
	parameter		RAM_XADR = 20,				//	behavioral DRAM size (sim)
	parameter [31:0] RESET_PC = 32'h8000_0000,
	parameter		RLAT	 = 0,				//	sim DRAM read-latency beats
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
	wire	irq_timer, irq_ext_m, irq_ext_s;

	//	== imem / dmem AXI4 (core <-> xbar) ==
	wire [`AXI_ID_W-1:0]	imem_arid;   wire [`AXI_ADDR_W-1:0] imem_araddr;
	wire [`AXI_LEN_W-1:0]	imem_arlen;  wire [`AXI_SIZE_W-1:0] imem_arsize;
	wire [`AXI_BURST_W-1:0]	imem_arburst; wire [`AXI_PROT_W-1:0] imem_arprot;
	wire					imem_arvalid, imem_arready;
	wire [`AXI_ID_W-1:0]	imem_rid;    wire [`AXI_DATA_W-1:0] imem_rdata;
	wire [`AXI_RESP_W-1:0]	imem_rresp;  wire imem_rlast, imem_rvalid, imem_rready;

	wire [`AXI_ID_W-1:0]	dmem_arid;   wire [`AXI_ADDR_W-1:0] dmem_araddr;
	wire [`AXI_LEN_W-1:0]	dmem_arlen;  wire [`AXI_SIZE_W-1:0] dmem_arsize;
	wire [`AXI_BURST_W-1:0]	dmem_arburst; wire [`AXI_PROT_W-1:0] dmem_arprot;
	wire					dmem_arvalid, dmem_arready;
	wire [`AXI_ID_W-1:0]	dmem_rid;    wire [`AXI_DATA_W-1:0] dmem_rdata;
	wire [`AXI_RESP_W-1:0]	dmem_rresp;  wire dmem_rlast, dmem_rvalid, dmem_rready;
	wire [`AXI_ID_W-1:0]	dmem_awid;   wire [`AXI_ADDR_W-1:0] dmem_awaddr;
	wire [`AXI_LEN_W-1:0]	dmem_awlen;  wire [`AXI_SIZE_W-1:0] dmem_awsize;
	wire [`AXI_BURST_W-1:0]	dmem_awburst; wire [`AXI_PROT_W-1:0] dmem_awprot;
	wire					dmem_awvalid, dmem_awready;
	wire [`AXI_DATA_W-1:0]	dmem_wdata;  wire [`AXI_STRB_W-1:0] dmem_wstrb;
	wire					dmem_wlast, dmem_wvalid, dmem_wready;
	wire [`AXI_ID_W-1:0]	dmem_bid;    wire [`AXI_RESP_W-1:0] dmem_bresp;
	wire					dmem_bvalid, dmem_bready;

	//	== DRAM AXI4 (xbar <-> behavioral RAM / MIG) ==
	wire [`AXI_ID_W-1:0]	m_arid;   wire [`AXI_ADDR_W-1:0] m_araddr;
	wire [`AXI_LEN_W-1:0]	m_arlen;  wire [`AXI_SIZE_W-1:0] m_arsize;
	wire [`AXI_BURST_W-1:0]	m_arburst; wire m_arvalid, m_arready;
	wire [`AXI_ID_W-1:0]	m_rid;    wire [`AXI_DATA_W-1:0] m_rdata;
	wire [`AXI_RESP_W-1:0]	m_rresp;  wire m_rlast, m_rvalid, m_rready;
	wire [`AXI_ID_W-1:0]	m_awid;   wire [`AXI_ADDR_W-1:0] m_awaddr;
	wire [`AXI_LEN_W-1:0]	m_awlen;  wire [`AXI_SIZE_W-1:0] m_awsize;
	wire [`AXI_BURST_W-1:0]	m_awburst; wire m_awvalid, m_awready;
	wire [`AXI_DATA_W-1:0]	m_wdata;  wire [`AXI_STRB_W-1:0] m_wstrb;
	wire					m_wlast, m_wvalid, m_wready;
	wire [`AXI_ID_W-1:0]	m_bid;    wire [`AXI_RESP_W-1:0] m_bresp;
	wire					m_bvalid, m_bready;

	wire [63:0]	clint_mtime;		//	CLINT mtime -> CSR rdtime (shared timer domain)
	karu64 #(.RESET_PC(RESET_PC), .EXT_TIME(1)) cpu (
		.clk(clk), .rst(rst), .trap(trap),
		.irq(irq_timer), .irq_external_m(irq_ext_m), .irq_external_s(irq_ext_s),
		.time_in(clint_mtime),
		.hpm_events(32'b0),
		.cache_flush_req(), .cache_flush_invalidate(), .cache_flush_done(1'b1),
		.uncache_page(32'h1000_0000),
		.imem_arid(imem_arid), .imem_araddr(imem_araddr),
		.imem_arlen(imem_arlen), .imem_arsize(imem_arsize),
		.imem_arburst(imem_arburst), .imem_arprot(imem_arprot),
		.imem_arvalid(imem_arvalid), .imem_arready(imem_arready),
		.imem_rid(imem_rid), .imem_rdata(imem_rdata),
		.imem_rresp(imem_rresp), .imem_rlast(imem_rlast),
		.imem_rvalid(imem_rvalid), .imem_rready(imem_rready),
		.dmem_arid(dmem_arid), .dmem_araddr(dmem_araddr),
		.dmem_arlen(dmem_arlen), .dmem_arsize(dmem_arsize),
		.dmem_arburst(dmem_arburst), .dmem_arprot(dmem_arprot),
		.dmem_arvalid(dmem_arvalid), .dmem_arready(dmem_arready),
		.dmem_rid(dmem_rid), .dmem_rdata(dmem_rdata),
		.dmem_rresp(dmem_rresp), .dmem_rlast(dmem_rlast),
		.dmem_rvalid(dmem_rvalid), .dmem_rready(dmem_rready),
		.dmem_awid(dmem_awid), .dmem_awaddr(dmem_awaddr),
		.dmem_awlen(dmem_awlen), .dmem_awsize(dmem_awsize),
		.dmem_awburst(dmem_awburst), .dmem_awprot(dmem_awprot),
		.dmem_awvalid(dmem_awvalid), .dmem_awready(dmem_awready),
		.dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
		.dmem_wlast(dmem_wlast), .dmem_wvalid(dmem_wvalid), .dmem_wready(dmem_wready),
		.dmem_bid(dmem_bid), .dmem_bresp(dmem_bresp),
		.dmem_bvalid(dmem_bvalid), .dmem_bready(dmem_bready)
	);

	karu_ddr_xbar xbar (
		.clk(clk), .rst(rst),
		.imem_arid(imem_arid), .imem_araddr(imem_araddr),
		.imem_arlen(imem_arlen), .imem_arsize(imem_arsize),
		.imem_arburst(imem_arburst), .imem_arprot(imem_arprot),
		.imem_arvalid(imem_arvalid), .imem_arready(imem_arready),
		.imem_rid(imem_rid), .imem_rdata(imem_rdata),
		.imem_rresp(imem_rresp), .imem_rlast(imem_rlast),
		.imem_rvalid(imem_rvalid), .imem_rready(imem_rready),
		.dmem_arid(dmem_arid), .dmem_araddr(dmem_araddr),
		.dmem_arlen(dmem_arlen), .dmem_arsize(dmem_arsize),
		.dmem_arburst(dmem_arburst), .dmem_arprot(dmem_arprot),
		.dmem_arvalid(dmem_arvalid), .dmem_arready(dmem_arready),
		.dmem_rid(dmem_rid), .dmem_rdata(dmem_rdata),
		.dmem_rresp(dmem_rresp), .dmem_rlast(dmem_rlast),
		.dmem_rvalid(dmem_rvalid), .dmem_rready(dmem_rready),
		.dmem_awid(dmem_awid), .dmem_awaddr(dmem_awaddr),
		.dmem_awlen(dmem_awlen), .dmem_awsize(dmem_awsize),
		.dmem_awburst(dmem_awburst), .dmem_awprot(dmem_awprot),
		.dmem_awvalid(dmem_awvalid), .dmem_awready(dmem_awready),
		.dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
		.dmem_wlast(dmem_wlast), .dmem_wvalid(dmem_wvalid), .dmem_wready(dmem_wready),
		.dmem_bid(dmem_bid), .dmem_bresp(dmem_bresp),
		.dmem_bvalid(dmem_bvalid), .dmem_bready(dmem_bready),
		.m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
		.m_arsize(m_arsize), .m_arburst(m_arburst),
		.m_arvalid(m_arvalid), .m_arready(m_arready),
		.m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp),
		.m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
		.m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
		.m_awsize(m_awsize), .m_awburst(m_awburst),
		.m_awvalid(m_awvalid), .m_awready(m_awready),
		.m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
		.m_wvalid(m_wvalid), .m_wready(m_wready),
		.m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
		.uart_txd(uart_txd), .uart_rxd(uart_rxd),
		.uart_rts(uart_rts), .uart_cts(uart_cts),
		.irq_timer(irq_timer), .irq_ext_m(irq_ext_m), .irq_ext_s(irq_ext_s),
		.clint_mtime(clint_mtime)
	);

	karu_axi4_ram #(
		.RAM_XADR(RAM_XADR), .MEM_BASE(32'h8000_0000),
		.RLAT(RLAT), .HEXFILE(HEXFILE)
	) dram (
		.clk(clk), .rst(rst),
		.s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen),
		.s_arsize(m_arsize), .s_arburst(m_arburst),
		.s_arvalid(m_arvalid), .s_arready(m_arready),
		.s_rid(m_rid), .s_rdata(m_rdata), .s_rresp(m_rresp),
		.s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
		.s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen),
		.s_awsize(m_awsize), .s_awburst(m_awburst),
		.s_awvalid(m_awvalid), .s_awready(m_awready),
		.s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
		.s_wvalid(m_wvalid), .s_wready(m_wready),
		.s_bid(m_bid), .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready)
	);

endmodule
