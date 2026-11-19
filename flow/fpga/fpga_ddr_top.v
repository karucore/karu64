//	fpga_ddr_top.v
//	=== karu64 SoC with main memory behind the DDR4/MIG bridge.
//
//	Same role as fpga_top.v, but main memory is reached through karu_ddr_xbar
//	(imem+dmem -> one AXI4 master) instead of the unified BRAM karu_axi_mem.
//	In sim the master drives the behavioral karu_axi4_ram (the MIG stand-in);
//	on hardware vcu118_ddr_top swaps that for the MIG user-AXI slave. CLINT,
//	PLIC and the NS16550 live inside the xbar as on-chip MMIO siblings.

`include "karu_ext.vh"
`include "karu_axi_defs.vh"

module fpga_ddr_top #(
	parameter		RAM_XADR = 20,				//	behavioral DRAM size (sim)
	parameter [31:0] RESET_PC = 32'h8000_0000,
	parameter		RLAT	 = 0,				//	sim DRAM read-latency beats
	parameter		HEXFILE	 = "firmware.hex",
	parameter		CPU_CLK_HZ = 100000000,		//	as in karu_ddr_xbar
	parameter integer SOFT_RESET_CYCLES = 256,	//	software reset pulse length
	//	Zkr (KARU_ZKR): the entropy source with its behavioural noise model
	parameter integer ZKR_SAMPLE_DIV = 256,		//	clk cycles per raw symbol
	parameter [15:0]  ZKR_INTERVAL = 16'd15,	//	reset decimation k, less one
	parameter integer ZKR_BURST_LOG2 = 11,		//	burst capture: 2^n words of 16 symbols
	parameter		ZKR_EN = 1,					//	the platform strap (board: DIP switch 4, inverted)
	//	Debug authentication (KARU_DBG with KARU_DBG_AUTH): the board's straps
	parameter [1:0]	AUTH_LC = 2'd0,				//	0 OPEN, 1 AUTH, 2/3 DISABLED
	parameter		AUTH_HOLD = 0,				//	boot-hold strap
	parameter		AUTH_ROM_HEX = ""			//	island ROM image
) (
	input  wire			clk,
	input  wire			rst,
	output wire			uart_txd,
	input  wire			uart_rxd,
	output wire			uart_rts,
	input  wire			uart_cts,
	output wire			trap
);
	wire	irq_timer, irq_software, irq_ext_m, irq_ext_s;

	//	Software reset (system-control register in the xbar): the stretched
	//	request resets the core, the xbar and the DRAM port logic. The DRAM
	//	contents survive, as on the board. rst is the board reset.
	wire	soft_reset_req, soft_reset;
	karu_soft_reset #(.HOLD_CYCLES(SOFT_RESET_CYCLES)) u_soft_reset (
		.clk(clk), .por_i(rst), .req_i(soft_reset_req), .reset_o(soft_reset)
	);
	//	With the Debug Module (KARU_DBG) the core is karudbg_core with an idle
	//	debugger, as on the board without its JTAG transport: rst is then the
	//	power-on reset of the Debug Module and the authentication block, and
	//	ndmreset and the authentication reset join the system reset.
	wire	dbg_ndmreset, auth_reset;
	wire	soc_rst = rst | soft_reset | dbg_ndmreset | auth_reset;

	//	The board's straps. The parameters give their values; a simulation
	//	may override them with +zkr_en=, +auth_lc= and +auth_hold=.
	reg [1:0]	strap_lc = AUTH_LC;
	reg			strap_hold = (AUTH_HOLD != 0);
	reg			strap_zkr_en = (ZKR_EN != 0);
	// synthesis translate_off
	integer		strap_arg;
	initial begin
		if ($value$plusargs("auth_lc=%d", strap_arg)) strap_lc = strap_arg[1:0];
		if ($value$plusargs("auth_hold=%d", strap_arg)) strap_hold = strap_arg[0];
		if ($value$plusargs("zkr_en=%d", strap_arg)) strap_zkr_en = strap_arg[0];
	end
	//	Say once, after power-on reset, what the straps are and what the
	//	authentication block took from them.
	reg			strap_shown = 1'b0;
	always @(posedge clk) if (!rst && !strap_shown) begin
		strap_shown <= 1'b1;
`ifdef KARU_DBG_AUTH
		$display("[straps] lifecycle %0d (sampled %0d), hold %0d, entropy %0d",
				 strap_lc, cpu.auth.lc_q, strap_hold, strap_zkr_en);
`else
		$display("[straps] entropy %0d", strap_zkr_en);
`endif
	end
	// synthesis translate_on

	//	Zkr: the entropy source behind seed, mnoise and mentropycfg.
	wire [1:0]	trng_opst;
	wire [15:0]	trng_data;
	wire		trng_ack;
	//	The registers of its burst capture, in the xbar's system-control
	//	block, and at register 4 the temperature readout (a model of it
	//	here: fixed codes, an update every 1024 clocks). +zkr_burst=0 takes
	//	them all away: the range then reads zero, as in an image built
	//	before they existed.
	wire		sysreg_re, sysreg_we;
	wire [2:0]	sysreg_raddr, sysreg_waddr;
	wire [63:0]	sysreg_rdata, sysreg_wdata, burst_rdata, sysmon_value;
	reg			strap_burst = 1'b1;
	// synthesis translate_off
	initial if ($value$plusargs("zkr_burst=%d", strap_arg)) strap_burst = strap_arg[0];
	// synthesis translate_on
	karu_sysmon #(.SIM(1), .PERIOD_LOG2(10)) u_sysmon (.clk(clk), .rst(rst), .value_o(sysmon_value));
	assign sysreg_rdata = !strap_burst ? 64'b0 : (sysreg_raddr == 3'd4) ? sysmon_value : burst_rdata;
`ifdef KARU_EN_ZKR
	wire [63:0]	zkr_rdata, zkr_wdata;
	wire		zkr_fire, zkr_we;
	wire [1:0]	zkr_sel;
	karu_entropy_src #(.SIM(1), .SAMPLE_DIV(ZKR_SAMPLE_DIV), .INTERVAL_RESET(ZKR_INTERVAL),
					   .BURST_LOG2_WORDS(ZKR_BURST_LOG2)) u_entropy (
		.clk(clk), .rst(soc_rst), .en_i(strap_zkr_en),
		.csr_fire_i(zkr_fire), .csr_sel_i(zkr_sel), .csr_we_i(zkr_we),
		.csr_wdata_i(zkr_wdata), .csr_rdata_o(zkr_rdata),
		.trng_opst_o(trng_opst), .trng_data_o(trng_data), .trng_ack_i(trng_ack),
		.reg_re_i(sysreg_re && strap_burst), .reg_raddr_i(sysreg_raddr), .reg_rdata_o(burst_rdata),
		.reg_we_i(sysreg_we && strap_burst), .reg_waddr_i(sysreg_waddr), .reg_wdata_i(sysreg_wdata)
	);
`else
	assign trng_opst = 2'd3;
	assign trng_data = 16'b0;
	assign burst_rdata = 64'b0;
	wire		_unused_sysreg = &{sysreg_re, sysreg_we, sysreg_waddr, sysreg_wdata, 1'b0};
`endif
`ifndef KARU_DBG
	assign dbg_ndmreset = 1'b0;
`endif
`ifndef KARU_DBG_AUTH
	assign auth_reset = 1'b0;
	assign trng_ack = 1'b0;
`endif

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
	wire [`AXI_PROT_W-1:0]	m_arprot, m_awprot;
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
`ifdef KARU_DBG
	karudbg_core #(.RESET_PC({32'b0, RESET_PC}), .EXT_TIME(1)
`ifdef KARU_DBG_AUTH
		, .ISLAND_ROM_HEX(AUTH_ROM_HEX)
`endif
	) cpu (
		.clk(clk), .rst(rst), .hart_reset_i(soc_rst), .ndmreset_o(dbg_ndmreset),
		.debug_mode_o(), .debug_resume_ack_o(),
		.dmi_reset_i(1'b0), .dmi_req_valid_i(1'b0), .dmi_req_ready_o(),
		.dmi_req_addr_i(7'b0), .dmi_req_op_i(2'b0), .dmi_req_data_i(32'b0),
		.dmi_resp_valid_o(), .dmi_resp_ready_i(1'b1), .dmi_resp_data_o(), .dmi_resp_op_o(),
`ifdef KARU_DBG_AUTH
		.lc_i(strap_lc), .hold_strap_i(strap_hold), .revoke_i(1'b0),
		.trng_opst_i(trng_opst), .trng_data_i(trng_data), .trng_ack_o(trng_ack),
		.auth_reset_o(auth_reset),
`endif
		.trap(trap),
`else
	karu64 #(.RESET_PC(RESET_PC), .EXT_TIME(1)) cpu (
		.clk(clk), .rst(soc_rst), .trap(trap),
`endif
`ifdef KARU_EN_ZKR
		.zkr_rdata_i(zkr_rdata), .zkr_fire_o(zkr_fire), .zkr_sel_o(zkr_sel),
		.zkr_we_o(zkr_we), .zkr_wdata_o(zkr_wdata),
`endif
		.irq(irq_timer), .irq_external_m(irq_ext_m), .irq_external_s(irq_ext_s),
		.irq_software(irq_software),
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

	karu_ddr_xbar #(.CPU_CLK_HZ(CPU_CLK_HZ)) xbar (
		.clk(clk), .rst(soc_rst),
		.sys_reset_req_o(soft_reset_req),
		.sysreg_re_o(sysreg_re), .sysreg_raddr_o(sysreg_raddr), .sysreg_rdata_i(sysreg_rdata),
		.sysreg_we_o(sysreg_we), .sysreg_waddr_o(sysreg_waddr), .sysreg_wdata_o(sysreg_wdata),
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
		.m_arsize(m_arsize), .m_arburst(m_arburst), .m_arprot(m_arprot),
		.m_arvalid(m_arvalid), .m_arready(m_arready),
		.m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp),
		.m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
		.m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
		.m_awsize(m_awsize), .m_awburst(m_awburst), .m_awprot(m_awprot),
		.m_awvalid(m_awvalid), .m_awready(m_awready),
		.m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
		.m_wvalid(m_wvalid), .m_wready(m_wready),
		.m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
		.uart_txd(uart_txd), .uart_rxd(uart_rxd),
		.uart_rts(uart_rts), .uart_cts(uart_cts),
		.irq_timer(irq_timer), .irq_ext_m(irq_ext_m), .irq_ext_s(irq_ext_s),
		.irq_software(irq_software),
		.clint_mtime(clint_mtime)
	);

	karu_axi4_ram #(
		.RAM_XADR(RAM_XADR), .MEM_BASE(32'h8000_0000),
		.RLAT(RLAT), .HEXFILE(HEXFILE)
	) dram (
		.clk(clk), .rst(soc_rst),
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

	wire _unused_prot = &{m_arprot, m_awprot, 1'b0};
endmodule
