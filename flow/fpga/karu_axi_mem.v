//	karu_axi_mem.v
//	=== Synthesizable AXI4 memory subsystem for FPGA targets.
//
//	Serves the karu64 imem (read-only) and dmem (read/write) AXI master
//	ports out of one on-chip BRAM, and routes accesses to the NS16550
//	UART page (0x10000000) to karu_ns16550 instead. This is the FPGA
//	analogue of the slave models in rtl/htif_tb.v -- same handshakes:
//	  - imem: single-beat reads (instruction fetch).
//	  - dmem: INCR-burst reads (L1 64-byte line refill = 8x64-bit) and
//	          INCR-burst write-through; uncached MMIO uses single beats.
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
	output wire			irq_software,	//	CLINT msip   -> core irq_software (MSIP)
	output wire			irq_ext_m,		//	PLIC M-claim -> irq_external_m (MEIP)
	output wire			irq_ext_s		//	PLIC S-claim -> irq_external_s (SEIP)
);
	localparam	RAM_WORDS  = (1 << RAM_XADR) / 8;
	localparam	RAM_IDX_HI = RAM_XADR - 1;
	function automatic is_ram(input [31:0] a);
		is_ram = (a[31:RAM_XADR] == (32'h80000000 >> RAM_XADR));
	endfunction

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
		if (hexarg != 0) $readmemh(hexarg, ram);
	end
`else
	initial if (HEXFILE != "") $readmemh(HEXFILE, ram);
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
	reg [63:0]		clint_rdata_q;
	wire			clint_we;
	wire			clint_mtip;
	wire			clint_msip;

	//	dmem_r_addr is latched in the dmem-read FSM far below, but the CLINT
	//	read port consumes it here -- hoist the decl so a single-pass front-end
	//	(Genus + default_nettype none) does not treat the port as an implicit net.
	reg [31:0]		dmem_r_addr;	//	full latched read address (CLINT/PLIC)
	localparam R_IDLE = 2'd0, R_RD = 2'd1, R_VLD = 2'd2;
	reg [1:0] dmem_r_st;
	reg dmem_r_plic;
	reg dmem_w_active;
	reg [31:0] dmem_w_addr;
	wire [31:0] wr_addr = dmem_w_active ? dmem_w_addr : dmem_awaddr;

	karu_clint #(.CPU_CLK_HZ(CPU_CLK_HZ)) u_clint (
		.clk		(clk		),
		.rst		(rst		),
		.raddr		(dmem_r_addr),
		.rdata		(clint_rdata),
		.we			(clint_we	),
		.waddr		(wr_addr),
		.wstrb		(dmem_wstrb	),
		.wdata		(dmem_wdata	),
		.mtip		(clint_mtip	),
		.msip		(clint_msip	),
		.mtime_o	(			)	//	unused in the BRAM sim path (DDR xbar wires it)
	);

	//	================= PLIC (0x0c00_0000) =================
	wire [63:0]		plic_rdata;
	reg [63:0]		plic_rdata_q;
	wire			plic_we;
	wire			plic_irq_m;
	wire			plic_irq_s;

	karu_plic u_plic (
		.clk		(clk		),
		.rst		(rst		),
		.re         (dmem_r_st == R_RD && dmem_r_plic),
		.raddr		(dmem_r_addr),
		.rdata		(plic_rdata	),
		.we			(plic_we	),
		.waddr		(wr_addr),
		.wstrb		(dmem_wstrb	),
		.wdata		(dmem_wdata	),
		.uart_irq	(uart_intr	),
		.eth_irq	(1'b0		),	//	no eth device in the BRAM build
		.irq_m		(plic_irq_m	),
		.irq_s		(plic_irq_s	)
	);

	//	interrupt lines out to the core
	assign irq_timer = clint_mtip;
	assign irq_software = clint_msip;
	assign irq_ext_m = plic_irq_m;
	assign irq_ext_s = plic_irq_s;

	//	Both read ports use a 3-state FSM (IDLE accept AR -> RD launch the
	//	registered BRAM read -> VLD present the beat). The registered read
	//	`*_q <= ram[*_idx]` is what makes Vivado infer Block RAM. The
	//	three-state reader is correct under any rready backpressure. A
	//	1-beat/cycle pipelined
	//	reader (with a skid buffer) is a later throughput optimisation.

	//	================= imem read slave (RAM only) =================
	reg [1:0]			imem_r_st;
	reg [`AXI_ID_W-1:0]	imem_r_id;
	reg [RAM_IDX_HI-3:0] imem_r_idx;
	reg [31:0] imem_r_addr;
	reg [`AXI_LEN_W-1:0] imem_r_cnt;
	reg [63:0]			imem_r_q;		//	registered BRAM read -> Block RAM

	always @(posedge clk) imem_r_q <= ram[imem_r_idx];

	always @(*) begin
		imem_arready = (imem_r_st == R_IDLE);
		imem_rvalid	 = (imem_r_st == R_VLD);
		imem_rdata	 = imem_r_q;
		imem_rid	 = imem_r_id;
		imem_rresp	 = is_ram(imem_r_addr) ? `AXI_RESP_OKAY : `AXI_RESP_DECERR;
		imem_rlast	 = (imem_r_st == R_VLD) && (imem_r_cnt == 0);
	end

	always @(posedge clk) begin
		if (rst) begin
			imem_r_st <= R_IDLE;
		end else case (imem_r_st)
			R_IDLE: if (imem_arvalid) begin
				imem_r_idx <= imem_araddr[RAM_IDX_HI:3];
				imem_r_addr <= imem_araddr;
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
					imem_r_addr <= imem_r_addr + 8;
					imem_r_cnt <= imem_r_cnt - 1'b1;
					imem_r_st  <= R_RD;
				end
			end
			default: imem_r_st <= R_IDLE;
		endcase
	end

	//	================= dmem read slave (INCR burst + MMIO) =============
	reg					dmem_r_uart;
	reg					dmem_r_clint;
	reg [2:0]			dmem_r_off;		//	byte offset (NS16550 register index)
	//	dmem_r_addr hoisted up to the CLINT read port (declared above)
	reg [`AXI_ID_W-1:0]	dmem_r_id;
	reg [RAM_IDX_HI-3:0] dmem_r_idx;
	reg [`AXI_LEN_W-1:0] dmem_r_cnt;
	reg [63:0]			dmem_r_q;		//	registered BRAM read -> Block RAM

	always @(posedge clk) dmem_r_q <= ram[dmem_r_idx];

	// Snapshot UART data and request its RBR pop at the same edge. A byte
	// arriving after that snapshot belongs to the next read, even if this
	// AXI response remains stalled for an arbitrarily long time.
	reg [63:0] ns_rdata_q;
	assign ns_raddr = dmem_r_off;
	assign ns_re	= (dmem_r_st == R_RD) && dmem_r_uart;

	always @(*) begin
		dmem_arready = (dmem_r_st == R_IDLE);
		dmem_rvalid	 = (dmem_r_st == R_VLD);
		dmem_rdata	 = dmem_r_uart  ? ns_rdata_q  :
					   dmem_r_clint ? clint_rdata_q :
					   dmem_r_plic  ? plic_rdata_q : dmem_r_q;
		dmem_rid	 = dmem_r_id;
		dmem_rresp	 = (is_ram(dmem_r_addr) || dmem_r_uart || dmem_r_clint || dmem_r_plic)
			? `AXI_RESP_OKAY : `AXI_RESP_DECERR;
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
			R_RD: begin
				if (dmem_r_uart) ns_rdata_q <= ns_rdata;
				// The timer can tick while RREADY is low. Sample before
				// asserting RVALID and retain that complete response.
				if (dmem_r_clint) clint_rdata_q <= clint_rdata;
				// Snapshot and claim at the same edge; backpressure must not
				// change the returned ID or repeat the device read.
				if (dmem_r_plic) plic_rdata_q <= plic_rdata;
				dmem_r_st <= R_VLD;
			end
			R_VLD: if (dmem_rready) begin
				if (dmem_r_cnt == 0) begin
					dmem_r_st <= R_IDLE;
				end else begin
					dmem_r_idx <= dmem_r_idx + 1'b1;
					dmem_r_addr <= dmem_r_addr + 8;
					dmem_r_cnt <= dmem_r_cnt - 1'b1;
					dmem_r_st  <= R_RD;
				end
			end
			default: dmem_r_st <= R_IDLE;
		endcase
	end

	//	================= dmem write slave (RAM INCR burst + MMIO) ========
	reg					dmem_b_pending;
	reg [`AXI_ID_W-1:0]	dmem_b_id;
	reg dmem_write_error;

	wire wr_fire = dmem_wvalid && dmem_wready;
	wire				wr_uart = wr_fire && is_uart(wr_addr);
	wire				wr_uart_thr_wait = is_uart(wr_addr) &&
										   dmem_wstrb[0] &&
										   !ns_thr_ready;

	assign ns_we   = wr_uart;
	assign clint_we = wr_fire && is_clint(wr_addr);
	assign plic_we  = wr_fire && is_plic(wr_addr);

	always @(*) begin
		dmem_awready = !dmem_w_active && !dmem_b_pending && !wr_uart_thr_wait;
		dmem_wready = !dmem_b_pending && !wr_uart_thr_wait && (dmem_w_active || dmem_awvalid);
		dmem_bvalid	 = dmem_b_pending;
		dmem_bid	 = dmem_b_id;
		dmem_bresp	 = dmem_write_error ? `AXI_RESP_DECERR : `AXI_RESP_OKAY;
	end

	integer b;
	always @(posedge clk) begin
		if (rst) begin
			dmem_b_pending <= 1'b0;
			dmem_w_active <= 1'b0;
			dmem_write_error <= 0;
		end else begin
			if (dmem_b_pending && dmem_bready) begin
				dmem_b_pending <= 1'b0;
				dmem_write_error <= 0;
			end
			if (dmem_awvalid && dmem_awready) begin
				dmem_w_active <= 1'b1; dmem_w_addr <= dmem_awaddr;
				dmem_b_id <= dmem_awid;
			end
			if (wr_fire) begin
				if (!(is_ram(wr_addr) || is_uart(wr_addr) || is_clint(wr_addr) || is_plic(wr_addr)))
					dmem_write_error <= 1;
				//	BRAM write only for true memory; MMIO (UART/CLINT/PLIC)
				//	is handled by the device write ports above.
				if (is_ram(wr_addr)) begin
					for (b = 0; b < 8; b = b + 1) begin
						if (dmem_wstrb[b])
							ram[wr_addr[RAM_IDX_HI:3]][b*8 +: 8]
								<= dmem_wdata[b*8 +: 8];
					end
				end
				dmem_w_addr <= wr_addr + 32'd8;
				dmem_w_active <= !dmem_wlast;
				dmem_b_pending <= dmem_wlast;
			end
		end
	end

	//	Unused AXI attributes; WLAST terminates the supported write bursts.
	wire _unused = &{ imem_arlen, imem_arsize, imem_arburst, imem_arprot,
					  dmem_arsize, dmem_arburst, dmem_arprot,
					  dmem_awlen, dmem_awsize, dmem_awburst, dmem_awprot,
					  1'b0 };
endmodule
