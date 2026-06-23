//	karu_ddr_xbar.v
//	=== SoC interconnect for the DDR4 (MIG) memory path.
//
//	Sits between the karu64 imem (RO) + dmem (RW) masters and a single AXI4
//	master toward main memory (the MIG user-AXI slave in hardware; the
//	behavioral karu_axi4_ram in sim). It:
//
//	  1. Peels MMIO off the dmem path on-chip: CLINT (0x0200_0000), PLIC
//	     (0x0c00_0000), NS16550 UART (0x1000_0000), and config flash SPI
//	     (0x1200_0000), and LiteEth (0x1100_0000) -- local devices, with
//	     multi-cycle handshakes where the peripheral needs them. imem never
//	     targets MMIO (code lives in DRAM).
//	  2. Merges imem reads + dmem DRAM reads + dmem DRAM writes onto the one
//	     DRAM master. Reads are SINGLE-OUTSTANDING with a latched owner
//	     (priority dmem > imem), mirroring karu64.v's dmem arbiter: the owner
//	     is captured at AR-accept and held to RLAST, so the master's R beats
//	     route back to the right requester. Writes are dmem-only.
//
//	Address split: is_dram = (pa[31:28] == 4'h8)  -> 0x8000_0000..0x8FFF_FFFF
//	matches the core's cacheable window (karu_mem). Everything else is MMIO.
//
//	Single outstanding per master per channel (which the IFU/LSU + the behavioral
//	slave both honour) keeps the routing a latched select rather than a tag FIFO.

`include "karu_ext.vh"
`include "karu_axi_defs.vh"

module karu_ddr_xbar #(
	parameter		CPU_CLK_HZ = 100000000,		//	core clock in Hz (100 MHz default; DDR top overrides via MIG/div)
	parameter		ROM_HEX = "vcu118_fuboot.hex"
) (
	input  wire			clk,
	input  wire			rst,

	//	== imem AXI4 slave (from core, read only) ==
	input  wire [`AXI_ID_W-1:0]		imem_arid,
	input  wire [`AXI_ADDR_W-1:0]	imem_araddr,
	input  wire [`AXI_LEN_W-1:0]	imem_arlen,
	input  wire [`AXI_SIZE_W-1:0]	imem_arsize,
	input  wire [`AXI_BURST_W-1:0]	imem_arburst,
	input  wire [`AXI_PROT_W-1:0]	imem_arprot,
	input  wire						imem_arvalid,
	output wire						imem_arready,
	output wire [`AXI_ID_W-1:0]		imem_rid,
	output wire [`AXI_DATA_W-1:0]	imem_rdata,
	output wire [`AXI_RESP_W-1:0]	imem_rresp,
	output wire						imem_rlast,
	output wire						imem_rvalid,
	input  wire						imem_rready,

	//	== dmem AXI4 slave (from core, read/write) ==
	input  wire [`AXI_ID_W-1:0]		dmem_arid,
	input  wire [`AXI_ADDR_W-1:0]	dmem_araddr,
	input  wire [`AXI_LEN_W-1:0]	dmem_arlen,
	input  wire [`AXI_SIZE_W-1:0]	dmem_arsize,
	input  wire [`AXI_BURST_W-1:0]	dmem_arburst,
	input  wire [`AXI_PROT_W-1:0]	dmem_arprot,
	input  wire						dmem_arvalid,
	output wire						dmem_arready,
	output wire [`AXI_ID_W-1:0]		dmem_rid,
	output wire [`AXI_DATA_W-1:0]	dmem_rdata,
	output wire [`AXI_RESP_W-1:0]	dmem_rresp,
	output wire						dmem_rlast,
	output wire						dmem_rvalid,
	input  wire						dmem_rready,
	input  wire [`AXI_ID_W-1:0]		dmem_awid,
	input  wire [`AXI_ADDR_W-1:0]	dmem_awaddr,
	input  wire [`AXI_LEN_W-1:0]	dmem_awlen,
	input  wire [`AXI_SIZE_W-1:0]	dmem_awsize,
	input  wire [`AXI_BURST_W-1:0]	dmem_awburst,
	input  wire [`AXI_PROT_W-1:0]	dmem_awprot,
	input  wire						dmem_awvalid,
	output wire						dmem_awready,
	input  wire [`AXI_DATA_W-1:0]	dmem_wdata,
	input  wire [`AXI_STRB_W-1:0]	dmem_wstrb,
	input  wire						dmem_wlast,
	input  wire						dmem_wvalid,
	output wire						dmem_wready,
	output wire [`AXI_ID_W-1:0]		dmem_bid,
	output wire [`AXI_RESP_W-1:0]	dmem_bresp,
	output wire						dmem_bvalid,
	input  wire						dmem_bready,

	//	== DRAM AXI4 master (to MIG / behavioral RAM) ==
	output wire [`AXI_ID_W-1:0]		m_arid,
	output wire [`AXI_ADDR_W-1:0]	m_araddr,
	output wire [`AXI_LEN_W-1:0]	m_arlen,
	output wire [`AXI_SIZE_W-1:0]	m_arsize,
	output wire [`AXI_BURST_W-1:0]	m_arburst,
	output wire						m_arvalid,
	input  wire						m_arready,
	input  wire [`AXI_ID_W-1:0]		m_rid,
	input  wire [`AXI_DATA_W-1:0]	m_rdata,
	input  wire [`AXI_RESP_W-1:0]	m_rresp,
	input  wire						m_rlast,
	input  wire						m_rvalid,
	output wire						m_rready,
	output wire [`AXI_ID_W-1:0]		m_awid,
	output wire [`AXI_ADDR_W-1:0]	m_awaddr,
	output wire [`AXI_LEN_W-1:0]	m_awlen,
	output wire [`AXI_SIZE_W-1:0]	m_awsize,
	output wire [`AXI_BURST_W-1:0]	m_awburst,
	output wire						m_awvalid,
	input  wire						m_awready,
	output wire [`AXI_DATA_W-1:0]	m_wdata,
	output wire [`AXI_STRB_W-1:0]	m_wstrb,
	output wire						m_wlast,
	output wire						m_wvalid,
	input  wire						m_wready,
	input  wire [`AXI_ID_W-1:0]		m_bid,
	input  wire [`AXI_RESP_W-1:0]	m_bresp,
	input  wire						m_bvalid,
	output wire						m_bready,

	//	== external serial interface ==
	output wire			uart_txd,
	input  wire			uart_rxd,
	output wire			uart_rts,
	input  wire			uart_cts,

	//	== interrupt lines to the core ==
	output wire			irq_timer,
	output wire			irq_ext_m,
	output wire			irq_ext_s,
	//	CLINT mtime -> core CSR `time` (rdtime), so rdtime + mtimecmp share one domain
	output wire [63:0]	clint_mtime
`ifdef KARU_ETH_SGMII
	//	== GMII to the board-top 1G PCS/PMA (SGMII datapath) ==
	//	The MAC (karu_eth) stays here; only its GMII + 125 MHz clock thread up to
	//	vcu118_ddr_top, where the PCS/PMA + LVDS pins live (xbar MMIO/IRQ path unchanged).
	,input  wire		eth_clk125,
	 output wire [7:0]	gmii_tx_data,
	 output wire		gmii_tx_en,
	 output wire		gmii_tx_er,
	 input  wire [7:0]	gmii_rx_data,
	 input  wire		gmii_rx_dv,
	 input  wire		gmii_rx_er
`endif
);
	//	DRAM = the whole 2 GiB above 0x8000_0000 (0x8000_0000..0xFFFF_FFFF). All MMIO
	//	(CLINT/PLIC/UART/eth/flash) + boot ROM live below 0x8000_0000, so a[31]==1 is
	//	unambiguously DRAM. The MIG/converter AXI is 31-bit, so bit 31 is dropped on the
	//	way out -> core 0x8000_0000..0xFFFF_FFFF maps to MIG offset 0..0x7FFF_FFFF (2 GiB).
	function automatic is_dram (input [`AXI_ADDR_W-1:0] a); is_dram = (a[31] == 1'b1); endfunction
	//	Boot mem = 0x0000_1000..0x001F_FFFF (below the first MMIO at 0x0200_0000):
	//	a 1 MiB ROM (0x1000..0x100FFF) + 64 KiB scratch SRAM (0x101000..0x110FFF),
	//	with the gap above reading 0. karu_boot_mem does the precise ROM/SRAM split.
	function automatic is_boot (input [`AXI_ADDR_W-1:0] a);
		is_boot = (a[31:21] == 11'b0) && (a[20:12] != 9'b0);
	endfunction
	function automatic is_uart (input [`AXI_ADDR_W-1:0] a); is_uart = (a[31:12] == 20'h10000); endfunction
	function automatic is_eth  (input [`AXI_ADDR_W-1:0] a); is_eth   = (a[31:20] == 12'h110); endfunction
	function automatic is_flash(input [`AXI_ADDR_W-1:0] a); is_flash = (a[31:12] == 20'h12000); endfunction
	function automatic is_clint(input [`AXI_ADDR_W-1:0] a); is_clint = (a[31:16] == 16'h0200); endfunction
	function automatic is_plic (input [`AXI_ADDR_W-1:0] a); is_plic = (a[31:24] == 8'h0c); endfunction

	//	================= local boot memory + MMIO devices =================
	wire			uart_intr;
	wire			clint_mtip, clint_msip;
	wire			plic_irq_m, plic_irq_s;
	wire [63:0]		ns_rdata, clint_rdata, plic_rdata, flash_rdata, eth_rdata;
	wire [63:0]		boot_imem_rdata, boot_dmem_rdata;
	wire			ns_thr_ready;
	wire			flash_busy;
	wire			eth_irq, eth_busy, eth_rd_done, eth_wr_done;

	//	device write strobe (one dmem write at a time; latched address below)
	wire			ns_we, clint_we, plic_we, flash_we;
	wire			eth_rd_req, eth_wr_req;
	//	device read address: the latched MMIO read address (32-bit) + ns reg idx
	reg  [31:0]		mr_addr;

	reg  [31:0]		boot_imem_addr, boot_dmem_addr;
	reg  [31:0]		boot_waddr;
	reg  [7:0]		boot_wstrb;
	reg  [63:0]		boot_wdata;
	reg				boot_we;

	karu_boot_mem #(.ROM_HEX(ROM_HEX)) u_boot_mem (
		.clk(clk),
		.imem_raddr(boot_imem_addr), .imem_rdata(boot_imem_rdata),
		.dmem_raddr(boot_dmem_addr), .dmem_rdata(boot_dmem_rdata),
		.dmem_we(boot_we), .dmem_waddr(boot_waddr),
		.dmem_wstrb(boot_wstrb), .dmem_wdata(boot_wdata)
	);

	karu_ns16550 #(.CPU_CLK_HZ(CPU_CLK_HZ)) u_uart (
		.clk(clk), .rst(rst),
		.re(mmio_r_fire && mr_uart), .raddr(mr_addr[2:0]),
		.we(ns_we), .wstrb(dmem_wstrb), .wdata(dmem_wdata), .rdata(ns_rdata),
		.uart_txd(uart_txd), .uart_rxd(uart_rxd),
		.uart_rts(uart_rts), .uart_cts(uart_cts),
		.intr(uart_intr), .thr_ready(ns_thr_ready)
	);
	karu_clint #(.CPU_CLK_HZ(CPU_CLK_HZ)) u_clint (
		.clk(clk), .rst(rst),
		.raddr(mr_addr), .rdata(clint_rdata),
		.we(clint_we), .waddr(dmem_awaddr), .wstrb(dmem_wstrb), .wdata(dmem_wdata),
		.mtip(clint_mtip), .msip(clint_msip), .mtime_o(clint_mtime)
	);
	//	LiteEth MMIO window @0x1100_0000. This wires the MAC/register path into the
	//	DDR hardware SoC and feeds PLIC source 2. Without KARU_ETH_SGMII the MAC uses
	//	the internal MII loopback; with it, the GMII threads up to the board-top PCS/PMA
	//	(SGMII to the external DP83867).
	karu_eth u_eth (
		.clk(clk), .rst(rst),
		.rd_req(eth_rd_req), .rd_addr(dmem_araddr[31:0]),
		.rd_done(eth_rd_done), .rd_data(eth_rdata),
		.wr_req(eth_wr_req), .wr_addr(dmem_awaddr[31:0]),
		.wr_strb(dmem_wstrb), .wr_data(dmem_wdata),
		.wr_done(eth_wr_done), .busy(eth_busy),
		.eth_irq(eth_irq)
`ifdef KARU_ETH_SGMII
		,.eth_clk125(eth_clk125),
		.gmii_tx_data(gmii_tx_data), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
		.gmii_rx_data(gmii_rx_data), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er)
`endif
	);

	karu_plic u_plic (
		.clk(clk), .rst(rst),
		.raddr(mr_addr), .rdata(plic_rdata),
		.we(plic_we), .waddr(dmem_awaddr), .wstrb(dmem_wstrb), .wdata(dmem_wdata),
		.uart_irq(uart_intr), .eth_irq(eth_irq), .irq_m(plic_irq_m), .irq_s(plic_irq_s)
	);
	karu_qspi_mmio u_flash (
		.clk(clk), .rst(rst),
		.re(mmio_r_fire && mr_flash), .raddr(mr_addr[4:0]), .rdata(flash_rdata),
		.we(flash_we), .waddr(dmem_awaddr[4:0]), .wstrb(dmem_wstrb),
		.wdata(dmem_wdata), .busy(flash_busy)
	);
	assign irq_timer = clint_mtip;
	assign irq_ext_m = plic_irq_m;
	assign irq_ext_s = plic_irq_s;

	//	================= local boot-memory read engine =================
	localparam OWN_NONE = 2'd0, OWN_IMEM = 2'd1, OWN_DMEM = 2'd2;
	localparam LR_IDLE = 2'd0, LR_WAIT = 2'd1, LR_VLD = 2'd2;
	reg [1:0]	lr_st;
	reg [1:0]	lr_own;
	reg [`AXI_ID_W-1:0]	lr_id;
	wire imem_boot_req = imem_arvalid && is_boot(imem_araddr);
	wire dmem_boot_req = dmem_arvalid && is_boot(dmem_araddr);
	wire lr_grant_dmem = (lr_st == LR_IDLE) && dmem_boot_req;
	wire lr_grant_imem = (lr_st == LR_IDLE) && !dmem_boot_req && imem_boot_req;
	wire lr_to_imem = (lr_st == LR_VLD) && (lr_own == OWN_IMEM);
	wire lr_to_dmem = (lr_st == LR_VLD) && (lr_own == OWN_DMEM);
	wire lr_ready = lr_to_imem ? imem_rready : lr_to_dmem ? dmem_rready : 1'b0;

	always @(posedge clk) begin
		if (rst) begin
			lr_st <= LR_IDLE;
			lr_own <= OWN_NONE;
		end else case (lr_st)
			LR_IDLE: begin
				if (lr_grant_dmem) begin
					lr_own <= OWN_DMEM;
					lr_id <= dmem_arid;
					boot_dmem_addr <= dmem_araddr;
					lr_st <= LR_WAIT;
				end else if (lr_grant_imem) begin
					lr_own <= OWN_IMEM;
					lr_id <= imem_arid;
					boot_imem_addr <= imem_araddr;
					lr_st <= LR_WAIT;
				end
			end
			LR_WAIT: lr_st <= LR_VLD;
			LR_VLD: if (lr_ready) begin
				lr_st <= LR_IDLE;
				lr_own <= OWN_NONE;
			end
			default: lr_st <= LR_IDLE;
		endcase
	end

	//	================= shared DRAM read engine (imem + dmem) =================
	//	single outstanding; latched owner held AR-accept -> RLAST. dmem > imem.
	localparam DR_IDLE = 2'd0, DR_AR = 2'd1, DR_DATA = 2'd2;
	reg [1:0]	dr_st;
	reg [1:0]	dr_own;
	reg [`AXI_ID_W-1:0]		dr_arid;
	reg [`AXI_ADDR_W-1:0]	dr_araddr;
	reg [`AXI_LEN_W-1:0]	dr_arlen;
	reg [`AXI_SIZE_W-1:0]	dr_arsize;
	wire					dmem_rd_arready;	//	DRAM-engine AR grant for dmem

	wire imem_rd_req = imem_arvalid && !imem_boot_req;
	wire dmem_rd_req = dmem_arvalid && is_dram(dmem_araddr);

	//	grant (combinational) only meaningful in DR_IDLE
	wire grant_dmem = dmem_rd_req;
	wire grant_imem = imem_rd_req && !dmem_rd_req;

	always @(posedge clk) begin
		if (rst) begin
			dr_st  <= DR_IDLE;
			dr_own <= OWN_NONE;
		end else case (dr_st)
			DR_IDLE: begin
				if (grant_dmem) begin
					dr_own <= OWN_DMEM;
					dr_arid <= dmem_arid; dr_araddr <= dmem_araddr;
					dr_arlen <= dmem_arlen; dr_arsize <= dmem_arsize;
					dr_st <= DR_AR;
				end else if (grant_imem) begin
					dr_own <= OWN_IMEM;
					dr_arid <= imem_arid; dr_araddr <= imem_araddr;
					dr_arlen <= imem_arlen; dr_arsize <= imem_arsize;
					dr_st <= DR_AR;
				end
			end
			DR_AR:   if (m_arready) dr_st <= DR_DATA;	//	AR accepted by slave
			DR_DATA: if (m_rvalid && m_rready && m_rlast) begin
				dr_st  <= DR_IDLE;
				dr_own <= OWN_NONE;
			end
			default: dr_st <= DR_IDLE;
		endcase
	end

	//	AR accept back-pressure to the requester: consumed the cycle we leave
	//	DR_IDLE with that owner granted.
	assign imem_arready = imem_boot_req ? lr_grant_imem :
						  ((dr_st == DR_IDLE) && grant_imem);
	assign dmem_rd_arready = (dr_st == DR_IDLE) && grant_dmem;

	//	master AR (driven from the latched request while in DR_AR)
	assign m_arid    = dr_arid;
	assign m_araddr  = dr_araddr;
	assign m_arlen   = dr_arlen;
	assign m_arsize  = dr_arsize;
	assign m_arburst = `AXI_BURST_INCR;
	assign m_arvalid = (dr_st == DR_AR);

	//	master R routed to the owner; rready from the owner
	wire dr_to_imem = (dr_st == DR_DATA) && (dr_own == OWN_IMEM);
	wire dr_to_dmem = (dr_st == DR_DATA) && (dr_own == OWN_DMEM);
	assign m_rready  = dr_to_imem ? imem_rready :
					   dr_to_dmem ? dmem_rready : 1'b0;

	assign imem_rvalid = (lr_to_imem && (lr_st == LR_VLD)) || (dr_to_imem && m_rvalid);
	assign imem_rdata  = lr_to_imem ? boot_imem_rdata : m_rdata;
	assign imem_rid    = lr_to_imem ? lr_id : m_rid;
	assign imem_rresp  = `AXI_RESP_OKAY;
	assign imem_rlast  = lr_to_imem ? 1'b1 : m_rlast;

	//	================= dmem READ front-end (DRAM vs MMIO) =================
	//	A dmem read is either a DRAM read (served by the engine above) or an
	//	MMIO read (combinational device rdata). Latch which at AR-accept.
	localparam MR_IDLE = 1'b0, MR_VLD = 1'b1;
	reg				mr_st;
	reg [`AXI_ID_W-1:0]	mr_id;
	reg				mr_uart, mr_clint, mr_plic, mr_flash, mr_eth;
	reg				eth_rd_ready;

	wire dmem_ar_dram = is_dram(dmem_araddr);
	wire dmem_ar_boot = is_boot(dmem_araddr);
	wire dmem_ar_eth  = is_eth(dmem_araddr);
	wire mmio_ar_base = (mr_st == MR_IDLE) && dmem_arvalid &&
						!dmem_ar_dram && !dmem_ar_boot;
	wire eth_rd_candidate = mmio_ar_base && dmem_ar_eth && !eth_busy;
	wire mmio_ar_accept = mmio_ar_base && (!dmem_ar_eth || !eth_busy);
	assign eth_rd_req = mmio_ar_accept && dmem_ar_eth;
	wire mmio_rvalid = (mr_st == MR_VLD) && (!mr_eth || eth_rd_ready);

	always @(posedge clk) begin
		if (rst) begin
			mr_st <= MR_IDLE;
			eth_rd_ready <= 1'b0;
		end else case (mr_st)
			MR_IDLE: if (mmio_ar_accept) begin
				mr_addr  <= dmem_araddr;
				mr_id    <= dmem_arid;
				mr_uart  <= is_uart(dmem_araddr);
				mr_clint <= is_clint(dmem_araddr);
				mr_plic  <= is_plic(dmem_araddr);
				mr_flash <= is_flash(dmem_araddr);
				mr_eth   <= dmem_ar_eth;
				mr_st    <= MR_VLD;
			end
			MR_VLD: if (mmio_rvalid && dmem_rready) begin
				mr_st <= MR_IDLE;
				if (mr_eth) eth_rd_ready <= 1'b0;
			end
		endcase
		if (!rst && eth_rd_done) eth_rd_ready <= 1'b1;
	end

	wire [63:0] mmio_rdata = mr_uart  ? ns_rdata    :
							  mr_clint ? clint_rdata :
							  mr_plic  ? plic_rdata  :
							  mr_eth   ? eth_rdata    :
							  mr_flash ? flash_rdata : 64'b0;
	wire mmio_r_fire = mmio_rvalid && dmem_rready;

	//	dmem AR ready: DRAM path or MMIO path depending on the address
	assign dmem_arready = dmem_ar_dram ? dmem_rd_arready :
						  dmem_ar_boot ? lr_grant_dmem :
						  ((mr_st == MR_IDLE) && (!dmem_ar_eth || !eth_busy));

	//	dmem R mux: MMIO (single beat) or DRAM engine
	assign dmem_rvalid = (lr_to_dmem && (lr_st == LR_VLD)) ||
						 mmio_rvalid || (dr_to_dmem && m_rvalid);
	assign dmem_rdata  = lr_to_dmem ? boot_dmem_rdata :
						 mmio_rvalid ? mmio_rdata : m_rdata;
	assign dmem_rid    = lr_to_dmem ? lr_id :
						 mmio_rvalid ? mr_id : m_rid;
	assign dmem_rresp  = `AXI_RESP_OKAY;
	assign dmem_rlast  = (lr_to_dmem || mmio_rvalid) ? 1'b1 : m_rlast;

	//	================= dmem WRITE front-end (DRAM vs MMIO) =================
	//	Single outstanding write. Route AW/W/B to DRAM master or MMIO devices
	//	by the AW address; latch the route at AW-accept for the W/B phases.
	localparam W_IDLE = 2'd0, W_DRAM = 2'd1, W_MMIO_B = 2'd2, W_ETH = 2'd3;
	reg [1:0]			w_st;
	reg [`AXI_ID_W-1:0]	w_bid;

	wire dmem_aw_dram = is_dram(dmem_awaddr);
	wire dmem_aw_boot = is_boot(dmem_awaddr);
	wire dmem_aw_eth  = is_eth(dmem_awaddr);
	wire uart_thr_wait = is_uart(dmem_awaddr) && dmem_wstrb[0] && !ns_thr_ready;
	wire flash_tx_wait = is_flash(dmem_awaddr) && (dmem_awaddr[4:3] == 2'd1) &&
						 dmem_wstrb[0] && flash_busy;
	wire eth_wr_wait = dmem_aw_eth && (eth_busy || eth_rd_candidate);
	wire mmio_wr_wait = uart_thr_wait || flash_tx_wait || eth_wr_wait;

	//	MMIO writes complete in one step (AW+W present together, device write),
	//	then a B. DRAM writes pass AW/W straight to the master and relay B.
	wire mmio_aw_fire = (w_st == W_IDLE) && dmem_awvalid && dmem_wvalid &&
						 !dmem_aw_dram && !dmem_aw_boot && !dmem_aw_eth && !mmio_wr_wait;
	wire eth_wr_fire = (w_st == W_IDLE) && dmem_awvalid && dmem_wvalid &&
					   dmem_aw_eth && !eth_busy && !eth_rd_candidate;
	assign eth_wr_req = eth_wr_fire;
	wire boot_wr_fire = (w_st == W_IDLE) && dmem_awvalid && dmem_wvalid &&
						dmem_aw_boot;

	always @(posedge clk) begin
		boot_we <= 1'b0;
		if (boot_wr_fire) begin
			boot_we <= 1'b1;
			boot_waddr <= dmem_awaddr;
			boot_wstrb <= dmem_wstrb;
			boot_wdata <= dmem_wdata;
		end
	end

	assign ns_we    = mmio_aw_fire && is_uart(dmem_awaddr);
	assign clint_we = mmio_aw_fire && is_clint(dmem_awaddr);
	assign plic_we  = mmio_aw_fire && is_plic(dmem_awaddr);
	assign flash_we = mmio_aw_fire && is_flash(dmem_awaddr);

	always @(posedge clk) begin
		if (rst) begin
			w_st <= W_IDLE;
		end else case (w_st)
			W_IDLE: begin
				if (boot_wr_fire) begin
					w_bid <= dmem_awid;
					w_st  <= W_MMIO_B;
				end else if (mmio_aw_fire) begin
					w_bid <= dmem_awid;
					w_st  <= W_MMIO_B;
				end else if (eth_wr_fire) begin
					w_bid <= dmem_awid;
					w_st  <= W_ETH;
				end else if (dmem_awvalid && dmem_aw_dram && m_awready) begin
					w_bid <= dmem_awid;
					w_st  <= W_DRAM;		//	AW accepted by master; stream W + B
				end
			end
			W_DRAM:   if (m_bvalid && m_bready) w_st <= W_IDLE;
			W_MMIO_B: if (dmem_bready)          w_st <= W_IDLE;
			W_ETH:    if (eth_wr_done)          w_st <= W_MMIO_B;
			default: w_st <= W_IDLE;
		endcase
	end

	//	dmem AW/W ready
	assign dmem_awready = dmem_aw_dram ? ((w_st == W_IDLE) && m_awready)
									   : ((w_st == W_IDLE) && dmem_wvalid &&
										  (dmem_aw_boot || !mmio_wr_wait));
	//	W: for MMIO the beat is consumed with the AW (mmio_aw_fire); for DRAM the
	//	beats stream to the master while in W_DRAM (single-beat write-through).
	assign dmem_wready  = dmem_aw_dram ? ((w_st == W_DRAM) && m_wready)
									   : ((w_st == W_IDLE) && dmem_awvalid &&
										  (dmem_aw_boot || !mmio_wr_wait));

	//	master AW/W (DRAM writes only)
	assign m_awid    = dmem_awid;
	assign m_awaddr  = dmem_awaddr;
	assign m_awlen   = dmem_awlen;
	assign m_awsize  = dmem_awsize;
	assign m_awburst = `AXI_BURST_INCR;
	assign m_awvalid = (w_st == W_IDLE) && dmem_awvalid && dmem_aw_dram;
	assign m_wdata   = dmem_wdata;
	assign m_wstrb   = dmem_wstrb;
	assign m_wlast   = dmem_wlast;
	assign m_wvalid  = (w_st == W_DRAM) && dmem_wvalid;
	assign m_bready  = (w_st == W_DRAM) && dmem_bready;

	//	dmem B mux
	assign dmem_bvalid = (w_st == W_DRAM)   ? m_bvalid :
						 (w_st == W_MMIO_B) ? 1'b1     : 1'b0;
	assign dmem_bid    = (w_st == W_DRAM)   ? m_bid    : w_bid;
	assign dmem_bresp  = `AXI_RESP_OKAY;

`ifdef SIM_TB
	karu_ddr_xbar_assert u_xbar_assert (
		.clk(clk), .rst(rst),
		.imem_arid(imem_arid), .imem_araddr(imem_araddr),
		.imem_arlen(imem_arlen), .imem_arsize(imem_arsize),
		.imem_arburst(imem_arburst), .imem_arvalid(imem_arvalid),
		.imem_arready(imem_arready), .imem_rid(imem_rid),
		.imem_rdata(imem_rdata), .imem_rlast(imem_rlast),
		.imem_rvalid(imem_rvalid), .imem_rready(imem_rready),
		.dmem_arid(dmem_arid), .dmem_araddr(dmem_araddr),
		.dmem_arlen(dmem_arlen), .dmem_arsize(dmem_arsize),
		.dmem_arburst(dmem_arburst), .dmem_arvalid(dmem_arvalid),
		.dmem_arready(dmem_arready), .dmem_rid(dmem_rid),
		.dmem_rdata(dmem_rdata), .dmem_rlast(dmem_rlast),
		.dmem_rvalid(dmem_rvalid), .dmem_rready(dmem_rready),
		.dmem_awid(dmem_awid), .dmem_awaddr(dmem_awaddr),
		.dmem_awlen(dmem_awlen), .dmem_awsize(dmem_awsize),
		.dmem_awburst(dmem_awburst), .dmem_awvalid(dmem_awvalid),
		.dmem_awready(dmem_awready), .dmem_wdata(dmem_wdata),
		.dmem_wstrb(dmem_wstrb), .dmem_wlast(dmem_wlast),
		.dmem_wvalid(dmem_wvalid), .dmem_wready(dmem_wready),
		.dmem_bid(dmem_bid), .dmem_bvalid(dmem_bvalid),
		.dmem_bready(dmem_bready),
		.m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
		.m_arsize(m_arsize), .m_arburst(m_arburst),
		.m_arvalid(m_arvalid), .m_arready(m_arready),
		.m_rid(m_rid), .m_rdata(m_rdata), .m_rlast(m_rlast),
		.m_rvalid(m_rvalid), .m_rready(m_rready),
		.m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
		.m_awsize(m_awsize), .m_awburst(m_awburst),
		.m_awvalid(m_awvalid), .m_awready(m_awready),
		.m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
		.m_wvalid(m_wvalid), .m_wready(m_wready),
		.m_bid(m_bid), .m_bvalid(m_bvalid), .m_bready(m_bready),
		.lr_st(lr_st), .lr_own(lr_own), .lr_id(lr_id),
		.lr_to_imem(lr_to_imem), .lr_to_dmem(lr_to_dmem),
		.dr_st(dr_st), .dr_own(dr_own), .dr_arid(dr_arid),
		.dr_araddr(dr_araddr), .dr_arlen(dr_arlen), .dr_arsize(dr_arsize),
		.dr_to_imem(dr_to_imem), .dr_to_dmem(dr_to_dmem),
		.mr_st(mr_st), .mr_id(mr_id), .mr_uart(mr_uart),
		.mr_clint(mr_clint), .mr_plic(mr_plic), .mr_flash(mr_flash),
		.mr_eth(mr_eth), .eth_rd_ready(eth_rd_ready),
		.mmio_rvalid(mmio_rvalid), .w_st(w_st), .w_bid(w_bid),
		.eth_busy(eth_busy), .eth_rd_req(eth_rd_req),
		.eth_rd_done(eth_rd_done), .eth_wr_req(eth_wr_req),
		.eth_wr_done(eth_wr_done)
	);
`endif

	//	clint_msip has no core input today; sink it (see karu_axi_mem note).
	wire _unused = &{ imem_arsize, imem_arburst, imem_arprot,
					  dmem_arsize, dmem_arburst, dmem_arprot,
					  dmem_awlen, dmem_awsize, dmem_awburst, dmem_awprot,
					  dmem_wlast, clint_msip, m_bresp, 1'b0 };
endmodule
