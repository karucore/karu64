//	karu_axi_mem.v
//	=== Synthesizable AXI4 memory subsystem for FPGA targets.
//
//	Serves the karu64 imem (read-only) and dmem (read/write) AXI master
//	ports out of one on-chip BRAM, and routes accesses to the NS16550
//	UART page (0x10000000) to karu_ns16550 instead. This is the FPGA
//	analogue of the slave models in rtl/htif_tb.v -- same handshakes:
//	  - imem: single-beat reads (instruction fetch).
//	  - dmem: INCR-burst reads (L1 64-byte line refill = 8x64-bit) and
//	          single-beat write-through; uncached UART reads are one beat.
//
//	The BRAM is initialised from firmware.hex (one 64-bit word per line,
//	hexdump -e '1/8 "%016x\n"') loaded at DRAM_BASE = 0x80000000.

`include "karu_ext.vh"
`include "karu_axi_defs.vh"

module karu_axi_mem #(
	parameter		RAM_XADR = 20,				//	BRAM = 1<<RAM_XADR bytes
	parameter		CPU_CLK_HZ = 100000000,		//	core clock in Hz (100 MHz; sim default)
	parameter		HEXFILE	 = "firmware.hex"
) (
	input  wire			clk,
	input  wire			rst,

	//	== imem AXI4 slave (read only) ==
	input  wire [`AXI_ID_W-1:0]		imem_arid,
	input  wire [`AXI_ADDR_W-1:0]	imem_araddr,
	input  wire [`AXI_LEN_W-1:0]	imem_arlen,
	input  wire [`AXI_SIZE_W-1:0]	imem_arsize,
	input  wire [`AXI_BURST_W-1:0]	imem_arburst,
	input  wire [`AXI_PROT_W-1:0]	imem_arprot,
	input  wire						imem_arvalid,
	output reg						imem_arready,
	output reg  [`AXI_ID_W-1:0]		imem_rid,
	output reg  [`AXI_DATA_W-1:0]	imem_rdata,
	output reg  [`AXI_RESP_W-1:0]	imem_rresp,
	output reg						imem_rlast,
	output reg						imem_rvalid,
	input  wire						imem_rready,

	//	== dmem AXI4 slave (read/write) ==
	input  wire [`AXI_ID_W-1:0]		dmem_arid,
	input  wire [`AXI_ADDR_W-1:0]	dmem_araddr,
	input  wire [`AXI_LEN_W-1:0]	dmem_arlen,
	input  wire [`AXI_SIZE_W-1:0]	dmem_arsize,
	input  wire [`AXI_BURST_W-1:0]	dmem_arburst,
	input  wire [`AXI_PROT_W-1:0]	dmem_arprot,
	input  wire						dmem_arvalid,
	output reg						dmem_arready,
	output reg  [`AXI_ID_W-1:0]		dmem_rid,
	output reg  [`AXI_DATA_W-1:0]	dmem_rdata,
	output reg  [`AXI_RESP_W-1:0]	dmem_rresp,
	output reg						dmem_rlast,
	output reg						dmem_rvalid,
	input  wire						dmem_rready,
	input  wire [`AXI_ID_W-1:0]		dmem_awid,
	input  wire [`AXI_ADDR_W-1:0]	dmem_awaddr,
	input  wire [`AXI_LEN_W-1:0]	dmem_awlen,
	input  wire [`AXI_SIZE_W-1:0]	dmem_awsize,
	input  wire [`AXI_BURST_W-1:0]	dmem_awburst,
	input  wire [`AXI_PROT_W-1:0]	dmem_awprot,
	input  wire						dmem_awvalid,
	output reg						dmem_awready,
	input  wire [`AXI_DATA_W-1:0]	dmem_wdata,
	input  wire [`AXI_STRB_W-1:0]	dmem_wstrb,
	input  wire						dmem_wlast,
	input  wire						dmem_wvalid,
	output reg						dmem_wready,
	output reg  [`AXI_ID_W-1:0]		dmem_bid,
	output reg  [`AXI_RESP_W-1:0]	dmem_bresp,
	output reg						dmem_bvalid,
	input  wire						dmem_bready,

	//	== external serial interface ==
	output wire			uart_txd,
	input  wire			uart_rxd,
	output wire			uart_rts,
	input  wire			uart_cts,

	//	== interrupt lines to the core (from on-chip CLINT/PLIC) ==
	output wire			irq_timer,		//	CLINT mtip   -> core irq  (MTIP)
	output wire			irq_ext_m,		//	PLIC M-claim -> irq_external_m (MEIP)
	output wire			irq_ext_s		//	PLIC S-claim -> irq_external_s (SEIP)
);
	localparam	RAM_WORDS  = (1 << RAM_XADR) / 8;
	localparam	RAM_IDX_HI = RAM_XADR - 1;

	//	MMIO device map (all uncacheable: karu_mem treats anything outside the
	//	0x8xxx_xxxx DRAM window as bypass):
	//	  UART  @ 0x1000_0000 (one 4 KiB page, matches uncache_page)
	//	  CLINT @ 0x0200_0000 (64 KiB window: msip/mtimecmp/mtime)
	//	  PLIC  @ 0x0c00_0000 (16 MiB window)
	function automatic is_uart(input [`AXI_ADDR_W-1:0] a);
		is_uart = (a[31:12] == 20'h10000);
	endfunction
	function automatic is_clint(input [`AXI_ADDR_W-1:0] a);
		is_clint = (a[31:16] == 16'h0200);
	endfunction
	function automatic is_plic(input [`AXI_ADDR_W-1:0] a);
		is_plic = (a[31:24] == 8'h0c);
	endfunction

	//	on-chip memory. Reads MUST be synchronous (registered output) for
	//	Vivado to infer Block RAM; an async/combinational read drops the
	//	whole 1 MiB into distributed LUTRAM (RAM256X1D x 65536). ram_style
	//	makes the intent explicit. (Verilator/iverilog ignore the attribute.)
	(* ram_style = "block" *)
	reg [63:0]	ram [0:RAM_WORDS-1];
`ifdef SIM_TB
	reg [8*256-1:0] hexarg;
	initial begin
		if (!$value$plusargs("hex=%s", hexarg))
			hexarg = HEXFILE;
		$readmemh(hexarg, ram);
	end
`else
	initial $readmemh(HEXFILE, ram);
`endif

	//	================= NS16550 =================
	wire			ns_re;
	wire [2:0]		ns_raddr;
	wire			ns_we;
	wire [63:0]		ns_rdata;
	wire			uart_intr;		//	NS16550 -> PLIC source 1
	wire			ns_thr_ready;

	karu_ns16550 #(
		.CPU_CLK_HZ	(CPU_CLK_HZ)
	) u_uart (
		.clk		(clk		),
		.rst		(rst		),
		.re			(ns_re		),
		.raddr		(ns_raddr	),
		.we			(ns_we		),
		.wstrb		(dmem_wstrb	),
		.wdata		(dmem_wdata	),
		.rdata		(ns_rdata	),
		.uart_txd	(uart_txd	),
		.uart_rxd	(uart_rxd	),
		.uart_rts	(uart_rts	),
		.uart_cts	(uart_cts	),
		.intr		(uart_intr	),
		.thr_ready	(ns_thr_ready)
	);

	//	================= CLINT (0x0200_0000) =================
	wire [63:0]		clint_rdata;
	wire			clint_we;
	wire			clint_mtip;
	wire			clint_msip;

	karu_clint #(.CPU_CLK_HZ(CPU_CLK_HZ)) u_clint (
		.clk		(clk		),
		.rst		(rst		),
		.raddr		(dmem_r_addr),
		.rdata		(clint_rdata),
		.we			(clint_we	),
		.waddr		(dmem_awaddr),
		.wstrb		(dmem_wstrb	),
		.wdata		(dmem_wdata	),
		.mtip		(clint_mtip	),
		.msip		(clint_msip	),
		.mtime_o	(			)	//	unused in the BRAM sim path (DDR xbar wires it)
	);

	//	================= PLIC (0x0c00_0000) =================
	wire [63:0]		plic_rdata;
	wire			plic_we;
	wire			plic_irq_m;
	wire			plic_irq_s;

	karu_plic u_plic (
		.clk		(clk		),
		.rst		(rst		),
		.raddr		(dmem_r_addr),
		.rdata		(plic_rdata	),
		.we			(plic_we	),
		.waddr		(dmem_awaddr),
		.wstrb		(dmem_wstrb	),
		.wdata		(dmem_wdata	),
		.uart_irq	(uart_intr	),
		.eth_irq	(1'b0		),	//	no eth device in the BRAM build
		.irq_m		(plic_irq_m	),
		.irq_s		(plic_irq_s	)
	);

	//	interrupt lines out to the core
	assign irq_timer = clint_mtip;
	assign irq_ext_m = plic_irq_m;
	assign irq_ext_s = plic_irq_s;

	//	Both read ports use a 3-state FSM (IDLE accept AR -> RD launch the
	//	registered BRAM read -> VLD present the beat). The registered read
	//	`*_q <= ram[*_idx]` is what makes Vivado infer Block RAM. This costs
	//	one extra beat-cycle vs the old combinational model (2 cyc/beat);
	//	correct under any rready backpressure. A 1-beat/cycle pipelined
	//	reader (with a skid buffer) is a later throughput optimisation.
	localparam R_IDLE = 2'd0, R_RD = 2'd1, R_VLD = 2'd2;

	//	================= imem read slave (RAM only) =================
	reg [1:0]			imem_r_st;
	reg [`AXI_ID_W-1:0]	imem_r_id;
	reg [RAM_IDX_HI-3:0] imem_r_idx;
	reg [`AXI_LEN_W-1:0] imem_r_cnt;
	reg [63:0]			imem_r_q;		//	registered BRAM read -> Block RAM

	always @(posedge clk) imem_r_q <= ram[imem_r_idx];

	always @(*) begin
		imem_arready = (imem_r_st == R_IDLE);
		imem_rvalid	 = (imem_r_st == R_VLD);
		imem_rdata	 = imem_r_q;
		imem_rid	 = imem_r_id;
		imem_rresp	 = `AXI_RESP_OKAY;
		imem_rlast	 = (imem_r_st == R_VLD) && (imem_r_cnt == 0);
	end

	always @(posedge clk) begin
		if (rst) begin
			imem_r_st <= R_IDLE;
		end else case (imem_r_st)
			R_IDLE: if (imem_arvalid) begin
				imem_r_idx <= imem_araddr[RAM_IDX_HI:3];
				imem_r_id  <= imem_arid;
				imem_r_cnt <= imem_arlen;
				imem_r_st  <= R_RD;
			end
			R_RD: imem_r_st <= R_VLD;		//	imem_r_q now holds ram[idx]
			R_VLD: if (imem_rready) begin
				if (imem_r_cnt == 0) begin
					imem_r_st <= R_IDLE;
				end else begin
					imem_r_idx <= imem_r_idx + 1'b1;
					imem_r_cnt <= imem_r_cnt - 1'b1;
					imem_r_st  <= R_RD;
				end
			end
			default: imem_r_st <= R_IDLE;
		endcase
	end

	//	================= dmem read slave (INCR burst + MMIO) =============
	reg [1:0]			dmem_r_st;
	reg					dmem_r_uart;
	reg					dmem_r_clint;
	reg					dmem_r_plic;
	reg [2:0]			dmem_r_off;		//	byte offset (NS16550 register index)
	reg [31:0]			dmem_r_addr;	//	full latched read address (CLINT/PLIC)
	reg [`AXI_ID_W-1:0]	dmem_r_id;
	reg [RAM_IDX_HI-3:0] dmem_r_idx;
	reg [`AXI_LEN_W-1:0] dmem_r_cnt;
	reg [63:0]			dmem_r_q;		//	registered BRAM read -> Block RAM

	always @(posedge clk) dmem_r_q <= ram[dmem_r_idx];

	//	UART (small register file) reads stay combinational; only the BRAM
	//	read is registered. RBR pop fires once, when the beat is accepted.
	assign ns_raddr = dmem_r_off;
	assign ns_re	= (dmem_r_st == R_VLD) && dmem_r_uart && dmem_rready;

	always @(*) begin
		dmem_arready = (dmem_r_st == R_IDLE);
		dmem_rvalid	 = (dmem_r_st == R_VLD);
		dmem_rdata	 = dmem_r_uart  ? ns_rdata    :
					   dmem_r_clint ? clint_rdata :
					   dmem_r_plic  ? plic_rdata  : dmem_r_q;
		dmem_rid	 = dmem_r_id;
		dmem_rresp	 = `AXI_RESP_OKAY;
		dmem_rlast	 = (dmem_r_st == R_VLD) && (dmem_r_cnt == 0);
	end

	always @(posedge clk) begin
		if (rst) begin
			dmem_r_st <= R_IDLE;
		end else case (dmem_r_st)
			R_IDLE: if (dmem_arvalid) begin
				dmem_r_idx	 <= dmem_araddr[RAM_IDX_HI:3];
				dmem_r_off	 <= dmem_araddr[2:0];
				dmem_r_addr	 <= dmem_araddr[31:0];
				dmem_r_uart	 <= is_uart(dmem_araddr);
				dmem_r_clint <= is_clint(dmem_araddr);
				dmem_r_plic	 <= is_plic(dmem_araddr);
				dmem_r_id	 <= dmem_arid;
				dmem_r_cnt	 <= dmem_arlen;
				dmem_r_st	 <= R_RD;
			end
			R_RD: dmem_r_st <= R_VLD;		//	dmem_r_q now holds ram[idx]
			R_VLD: if (dmem_rready) begin
				if (dmem_r_cnt == 0) begin
					dmem_r_st <= R_IDLE;
				end else begin
					dmem_r_idx <= dmem_r_idx + 1'b1;
					dmem_r_cnt <= dmem_r_cnt - 1'b1;
					dmem_r_st  <= R_RD;
				end
			end
			default: dmem_r_st <= R_IDLE;
		endcase
	end

	//	================= dmem write slave (single beat + UART) ===========
	reg					dmem_b_pending;
	reg [`AXI_ID_W-1:0]	dmem_b_id;

	wire				wr_fire = dmem_awvalid && dmem_awready &&
								  dmem_wvalid  && dmem_wready;
	wire				wr_uart = wr_fire && is_uart(dmem_awaddr);
	wire				wr_uart_thr_wait = is_uart(dmem_awaddr) &&
										   dmem_wstrb[0] &&
										   !ns_thr_ready;

	assign ns_we   = wr_uart;
	assign clint_we = wr_fire && is_clint(dmem_awaddr);
	assign plic_we  = wr_fire && is_plic(dmem_awaddr);

	always @(*) begin
		dmem_awready = !dmem_b_pending && !wr_uart_thr_wait;
		dmem_wready	 = !dmem_b_pending && !wr_uart_thr_wait;
		dmem_bvalid	 = dmem_b_pending;
		dmem_bid	 = dmem_b_id;
		dmem_bresp	 = `AXI_RESP_OKAY;
	end

	integer b;
	always @(posedge clk) begin
		if (rst) begin
			dmem_b_pending <= 1'b0;
		end else begin
			if (dmem_b_pending && dmem_bready)
				dmem_b_pending <= 1'b0;
			if (wr_fire) begin
				//	BRAM write only for true memory; MMIO (UART/CLINT/PLIC)
				//	is handled by the device write ports above.
				if (!is_uart(dmem_awaddr) && !is_clint(dmem_awaddr) &&
					!is_plic(dmem_awaddr)) begin
					for (b = 0; b < 8; b = b + 1) begin
						if (dmem_wstrb[b])
							ram[dmem_awaddr[RAM_IDX_HI:3]][b*8 +: 8]
								<= dmem_wdata[b*8 +: 8];
					end
				end
				dmem_b_pending <= 1'b1;
				dmem_b_id	   <= dmem_awid;
			end
		end
	end

	//	unused AXI inputs (single-port BRAM ignores size/burst/prot/wlast)
	//	clint_msip has no core input today (no hardware MSIP line); the
	//	software-interrupt register is still implemented for SW/DTB use.
	wire _unused = &{ imem_arlen, imem_arsize, imem_arburst, imem_arprot,
					  dmem_arsize, dmem_arburst, dmem_arprot,
					  dmem_awlen, dmem_awsize, dmem_awburst, dmem_awprot,
					  dmem_wlast, clint_msip, 1'b0 };
endmodule
