//	linux_tb.v
//	Direct karu64 simulation harness for the karudeb flat Linux bundle.
//
//	Memory map:
//	  0x0000_1000  boot ROM stub: a0=0, a1=FDT_ADDR, jump 0x8000_0000
//	  0x0001_0000  64 KiB scratch SRAM
//	  0x0200_0000  CLINT-compatible msip/mtimecmp/mtime
//	  0x0c00_0000  PLIC-compatible UART interrupt controller
//	  0x1000_0000  NS16550-compatible UART console
//	  0x8000_0000  32 MiB RAM, loaded from +img=<flat.img>

`include "config.vh"
`include "karu_axi_defs.vh"

module linux_tb (
	input  wire			clk,
	//	Pass/fail exit channel: firmware writes a 32-bit code to SIM_EXIT_ADDR
	//	(0 = pass, non-zero = fail); the bench latches it + $finishes, and
	//	linux_tb.cpp returns it as the process exit code (so `make eth-sim` is a
	//	real pass/fail rather than always-0).
	output reg  [31:0]	sim_exit_code,
	output reg			sim_exit_valid
);
`ifdef VERILATOR
	import "DPI-C" function int linux_uart_getchar();
`endif
	localparam [63:0] RESET_PC	= 64'h0000_0000_0000_1000;
	localparam [63:0] RAM_BASE	= 64'h0000_0000_8000_0000;
	localparam integer RAM_BYTES	= 32 * 1024 * 1024;
	localparam integer SRAM_BYTES = 64 * 1024;
	localparam [31:0] SRAM_BASE	= 32'h0001_0000;
	localparam [31:0] UART_BASE	= 32'h1000_0000;
	localparam [31:0] CLINT_BASE = 32'h0200_0000;
	localparam [31:0] PLIC_BASE	= 32'h0c00_0000;

	reg [7:0] ram [0:RAM_BYTES-1];
	reg [7:0] sram [0:SRAM_BYTES-1];

	reg [8*256-1:0] img_file;
	reg [8*256-1:0] dtb_file;
	reg [31:0] fdt_addr = 32'h81c0_0000;
	reg [63:0] max_cycles = 64'd50_000_000;
	integer fd;
	integer nread;
	integer plus_ok;
	integer i;

	initial begin
		for (i = 0; i < RAM_BYTES; i = i + 1)
			ram[i] = 8'b0;
		for (i = 0; i < SRAM_BYTES; i = i + 1)
			sram[i] = 8'b0;

		if (!$value$plusargs("img=%s", img_file))
			img_file = "../karudeb/build/karu64-rv64imac-image/flat.img";
		if (!$value$plusargs("dtb=%s", dtb_file))
			dtb_file = "../karudeb/build/karu64-rv64imac-image/board.dtb";
		plus_ok = $value$plusargs("fdt_addr=%h", fdt_addr);
		plus_ok = $value$plusargs("max_cycles=%d", max_cycles);

		fd = $fopen(img_file, "rb");
		if (fd == 0) begin
			$display("[LINUX-TB] cannot open image: %0s", img_file);
			$finish;
		end
		nread = $fread(ram, fd);
		$fclose(fd);
		$display("[LINUX-TB] loaded %0d bytes at 0x80000000 from %0s", nread, img_file);

		fd = $fopen(dtb_file, "rb");
		if (fd == 0) begin
			$display("[LINUX-TB] cannot open DTB: %0s", dtb_file);
			$finish;
		end
		nread = $fread(ram, fd, fdt_addr - RAM_BASE[31:0]);
		$fclose(fd);
		$display("[LINUX-TB] loaded %0d-byte DTB at 0x%08h from %0s",
			nread, fdt_addr, dtb_file);
	end

	reg [63:0] cyc = 0;
	wire rst = cyc < 8;
	wire trap;
	wire timer_irq;
	wire external_irq_m;
	wire external_irq_s;

	//	== imem AXI4 slave ==
	wire [`AXI_ID_W-1:0]		imem_arid;
	wire [`AXI_ADDR_W-1:0]	imem_araddr;
	wire [`AXI_LEN_W-1:0]	imem_arlen;
	wire [`AXI_SIZE_W-1:0]	imem_arsize;
	wire [`AXI_BURST_W-1:0]	imem_arburst;
	wire [`AXI_PROT_W-1:0]	imem_arprot;
	wire					imem_arvalid;
	reg						imem_arready;
	reg [`AXI_ID_W-1:0]		imem_rid;
	reg [`AXI_DATA_W-1:0]	imem_rdata;
	reg [`AXI_RESP_W-1:0]	imem_rresp;
	reg						imem_rlast;
	reg						imem_rvalid;
	wire					imem_rready;

	//	== dmem AXI4 slave ==
	wire [`AXI_ID_W-1:0]		dmem_arid;
	wire [`AXI_ADDR_W-1:0]	dmem_araddr;
	wire [`AXI_LEN_W-1:0]	dmem_arlen;
	wire [`AXI_SIZE_W-1:0]	dmem_arsize;
	wire [`AXI_BURST_W-1:0]	dmem_arburst;
	wire [`AXI_PROT_W-1:0]	dmem_arprot;
	wire					dmem_arvalid;
	reg						dmem_arready;
	reg [`AXI_ID_W-1:0]		dmem_rid;
	reg [`AXI_DATA_W-1:0]	dmem_rdata;
	reg [`AXI_RESP_W-1:0]	dmem_rresp;
	reg						dmem_rlast;
	reg						dmem_rvalid;
	wire					dmem_rready;
	wire [`AXI_ID_W-1:0]		dmem_awid;
	wire [`AXI_ADDR_W-1:0]	dmem_awaddr;
	wire [`AXI_LEN_W-1:0]	dmem_awlen;
	wire [`AXI_SIZE_W-1:0]	dmem_awsize;
	wire [`AXI_BURST_W-1:0]	dmem_awburst;
	wire [`AXI_PROT_W-1:0]	dmem_awprot;
	wire					dmem_awvalid;
	reg						dmem_awready;
	wire [`AXI_DATA_W-1:0]	dmem_wdata;
	wire [`AXI_STRB_W-1:0]	dmem_wstrb;
	wire					dmem_wlast;
	wire					dmem_wvalid;
	reg						dmem_wready;
	reg [`AXI_ID_W-1:0]		dmem_bid;
	reg [`AXI_RESP_W-1:0]	dmem_bresp;
	reg						dmem_bvalid;
	wire					dmem_bready;
	reg						dmem_r_pending;
	reg [`AXI_ID_W-1:0]		dmem_r_id;
	reg [31:0]				dmem_r_addr;
	reg [`AXI_LEN_W-1:0]	dmem_r_cnt;

	function automatic is_ram(input [31:0] a);
		is_ram = (a >= RAM_BASE[31:0]) && (a < RAM_BASE[31:0] + RAM_BYTES);
	endfunction

	function automatic is_sram(input [31:0] a);
		is_sram = (a >= SRAM_BASE) && (a < SRAM_BASE + SRAM_BYTES);
	endfunction

	function automatic is_uart(input [31:0] a);
		is_uart = (a[31:12] == UART_BASE[31:12]);
	endfunction

	function automatic is_clint(input [31:0] a);
		is_clint = (a >= CLINT_BASE) && (a < CLINT_BASE + 32'h0001_0000);
	endfunction

	function automatic is_plic(input [31:0] a);
		is_plic = (a >= PLIC_BASE) && (a < PLIC_BASE + 32'h0400_0000);
	endfunction

	//	LiteEth MMIO window: 1 MiB at 0x1100_0000 (CSRs 0x1100_xxxx, slot SRAM
	//	0x1101_xxxx) -- clear of UART (0x1000_xxxx) and the rest of the map.
	function automatic is_eth(input [31:0] a);
		is_eth = (a[31:20] == 12'h110);
	endfunction

	//	Sim pass/fail exit register: a write here ends the sim with that code.
	localparam [31:0] SIM_EXIT_ADDR = 32'h0000_2000;	//	between boot ROM + SRAM

	//	Clean-low boot trampoline (matches spike / fu-boot). Sets a0=hartid(0),
	//	a1=0x0000000081c00000 (DTB) and t0=0x0000000080000000 (OpenSBI entry) with
	//	the lui SIGN-EXTENSION CLEARED (slli/srli), then jumps. The ecp5 stub used
	//	a bare `lui t0,0x80000` whose target is 0xffffffff80000000; that ran OpenSBI
	//	at the high-half base, so the kernel computed high-half PAs and wrote a
	//	garbage satp PPN (0xfffff8....), instruction-page-faulting forever once
	//	paging turned on. Running clean-low keeps every computed PA in range.
	function automatic [63:0] boot_word(input [31:0] a);
		begin
			case (a[4:3])
				2'd0: boot_word = {32'h81c0_05b7, 32'h0000_0513}; // li a0,0     ; lui  a1,0x81c00
				2'd1: boot_word = {32'h0205_d593, 32'h0205_9593}; // slli a1,a1,32; srli a1,a1,32
				2'd2: boot_word = {32'h01f2_9293, 32'h0010_0293}; // li t0,1     ; slli t0,t0,31
				2'd3: boot_word = {32'h0000_0013, 32'h0002_8067}; // jr t0       ; nop
			endcase
		end
	endfunction

	function automatic [63:0] ram_word(input [31:0] a);
		integer off;
		begin
			off = {a[31:3], 3'b000} - RAM_BASE[31:0];
			ram_word = {ram[off+7], ram[off+6], ram[off+5], ram[off+4],
						ram[off+3], ram[off+2], ram[off+1], ram[off+0]};
		end
	endfunction

	function automatic [63:0] sram_word(input [31:0] a);
		integer off;
		begin
			off = {a[31:3], 3'b000} - SRAM_BASE;
			sram_word = {sram[off+7], sram[off+6], sram[off+5], sram[off+4],
						 sram[off+3], sram[off+2], sram[off+1], sram[off+0]};
		end
	endfunction

	reg [63:0] mtimecmp = 64'hffff_ffff_ffff_ffff;
	wire [63:0] mtime = cyc;
	assign timer_irq = (mtime >= mtimecmp);

	function automatic [63:0] clint_word(input [31:0] a);
		begin
			if (a[15:3] == 13'h800)
				clint_word = mtimecmp;
			else if (a[15:3] == 13'h17ff)
				clint_word = mtime;
			else
				clint_word = 64'b0;
		end
	endfunction

	reg uart_dlab = 1'b0;
	reg [7:0] uart_lcr = 8'b0;
	reg [7:0] uart_ier = 8'b0;
	reg [7:0] uart_fcr = 8'b0;
	reg [7:0] uart_dll = 8'b0;
	reg [7:0] uart_dlm = 8'b0;
	reg [7:0] uart_rx_byte = 8'b0;
	reg uart_rx_valid = 1'b0;
	integer uart_ch;

	wire uart_irq_rx = uart_ier[0] && uart_rx_valid;
	wire uart_irq_tx = uart_ier[1];
	wire uart_irq = uart_irq_rx || uart_irq_tx;
	wire [7:0] uart_iir = (uart_fcr[0] ? 8'hC0 : 8'h00) |
						  (uart_irq_rx ? 8'h04 :
						   uart_irq_tx ? 8'h02 : 8'h01);

	wire		plic_we = dmem_awvalid && dmem_awready &&
						  dmem_wvalid && dmem_wready && is_plic(dmem_awaddr);
	wire [63:0]	plic_rdata;
	karu_plic u_plic (
		.clk	(clk),
		.rst	(rst),
		.raddr	(dmem_r_addr),
		.rdata	(plic_rdata),
		.we		(plic_we),
		.waddr	(dmem_awaddr[31:0]),
		.wstrb	(dmem_wstrb),
		.wdata	(dmem_wdata),
		.uart_irq	(uart_irq),
		.eth_irq	(eth_irq),
		.irq_m		(external_irq_m),
		.irq_s		(external_irq_s)
	);

	//	== Ethernet (LiteEth) MMIO @0x1100_0000 -- sim MII loopback (Phase E1) ==
	//	karu_eth wraps the generated liteeth_core + an MII TX->RX loopback and a
	//	wishbone bridge presenting karu64's strobed-MMIO slave convention. Reads
	//	and writes are multi-cycle; the dmem read/write FSMs below gate rvalid /
	//	the B response on the bridge's *_done pulses.
	wire			eth_irq, eth_busy, eth_rd_done, eth_wr_done;
	wire [63:0]		eth_rd_data;
	//	one-cycle req pulses, asserted exactly at AR/AW accept for an eth address
	wire			eth_rd_req = dmem_arvalid && dmem_arready && is_eth(dmem_araddr);
	wire			eth_wr_req = dmem_awvalid && dmem_awready &&
							     dmem_wvalid  && dmem_wready  && is_eth(dmem_awaddr);
	reg				eth_rd_ready;		//	bridge read data available, awaiting CPU
	reg				eth_wr_inflight;	//	bridge write running, B deferred

	karu_eth u_eth (
		.clk	(clk),			.rst	(rst),
		.rd_req	(eth_rd_req),	.rd_addr(dmem_araddr),
		.rd_done(eth_rd_done),	.rd_data(eth_rd_data),
		.wr_req	(eth_wr_req),	.wr_addr(dmem_awaddr[31:0]),
		.wr_strb(dmem_wstrb),	.wr_data(dmem_wdata),
		.wr_done(eth_wr_done),	.busy	(eth_busy),
		.eth_irq(eth_irq)
	);

	always @(posedge clk) begin
		if (rst) eth_rd_ready <= 1'b0;
		else if (eth_rd_done) eth_rd_ready <= 1'b1;
		else if (dmem_rvalid && dmem_rready && is_eth(dmem_r_addr)) eth_rd_ready <= 1'b0;
	end

	//	Passive checker for the karu_eth bridge FSM + wishbone/req-busy signalling
	//	(flow/fpga/eth/karu_eth_assert.v). Hierarchical refs reach the bridge internals
	//	(iverilog 14 has no `bind`). Disable with +no_assert / +no_assert_stop.
	karu_eth_assert u_eth_assert (
		.clk(clk), .rst(rst),
		.st(u_eth.st),
		.rd_req(eth_rd_req), .rd_done(eth_rd_done),
		.wr_req(eth_wr_req), .wr_done(eth_wr_done),
		.busy(eth_busy),
		.wb_cyc(u_eth.wb_cyc), .wb_stb(u_eth.wb_stb),
		.wb_we(u_eth.wb_we),   .wb_ack(u_eth.wb_ack),
		.wb_sel(u_eth.wb_sel), .sel_lo(u_eth.sel_lo), .sel_hi(u_eth.sel_hi)
	);

	//	Caller-side checker: the dmem front-end obeys the bridge single-in-flight
	//	contract (AR/AW !eth_busy gate) + tracks completion correctly.
	karu_eth_caller_assert u_eth_caller_assert (
		.clk(clk), .rst(rst),
		.eth_busy(eth_busy),
		.eth_rd_req(eth_rd_req), .eth_wr_req(eth_wr_req),
		.eth_rd_done(eth_rd_done), .eth_wr_done(eth_wr_done),
		.eth_rd_ready(eth_rd_ready), .eth_wr_inflight(eth_wr_inflight)
	);

	//	PLIC two-source (UART=1, eth=2) arbitration / claim / irq checker.
	karu_plic_assert u_plic_assert (
		.clk(clk), .rst(rst),
		.irq_m(u_plic.irq_m), .irq_s(u_plic.irq_s),
		.claim_m(u_plic.claim_m), .claim_s(u_plic.claim_s),
		.pending_1(u_plic.pending_1), .pending_2(u_plic.pending_2),
		.enable_m(u_plic.enable_m), .enable_s(u_plic.enable_s),
		.prio_1(u_plic.priority_1), .prio_2(u_plic.priority_2),
		.thr_m(u_plic.threshold_m), .thr_s(u_plic.threshold_s)
	);

	function automatic [63:0] uart_word(input [31:0] a);
		reg [63:0] w;
		begin
			w = 64'b0;
			w[ 7: 0] = uart_dlab ? uart_dll : uart_rx_byte;	//	RBR
			w[15: 8] = uart_dlab ? uart_dlm : uart_ier;
			w[23:16] = uart_iir;
			w[31:24] = uart_lcr;
			w[47:40] = 8'h60 | {7'b0, uart_rx_valid};	//	LSR: THR/TX empty + DR
			uart_word = w;
		end
	endfunction

	function automatic [63:0] read_word(input [31:0] a);
		begin
			if (a >= 32'h0000_1000 && a < 32'h0000_2000)
				read_word = boot_word(a);
			else if (is_sram(a))
				read_word = sram_word(a);
			else if (is_ram(a))
				read_word = ram_word(a);
			else if (is_uart(a))
				read_word = uart_word(a);
			else if (is_clint(a))
				read_word = clint_word(a);
			else if (is_plic(a))
				read_word = plic_rdata;
			else
				read_word = 64'b0;
		end
	endfunction

	task automatic write_byte(input [31:0] a, input [7:0] v);
		begin
			if (is_ram(a))
				ram[a - RAM_BASE[31:0]] = v;
			else if (is_sram(a))
				sram[a - SRAM_BASE] = v;
			else if (is_uart(a)) begin
				case (a[2:0])
					3'd0: begin
						if (uart_dlab)
							uart_dll = v;
						else begin
							$write("%c", v);
							$fflush;
						end
					end
				3'd1: begin
					if (uart_dlab) uart_dlm = v;
					else uart_ier = v;
				end
				3'd2: uart_fcr = v;
				3'd3: begin
					uart_lcr = v;
					uart_dlab = v[7];
					end
					default: ;
				endcase
			end else if (is_clint(a) && a[15:3] == 13'h800) begin
				mtimecmp[(a[2:0] * 8) +: 8] = v;
			end
		end
	endtask

	//	AXI read model shared shape for imem/dmem.
	reg						imem_r_pending;
	reg [`AXI_ID_W-1:0]		imem_r_id;
	reg [31:0]				imem_r_addr;
	reg [`AXI_LEN_W-1:0]	imem_r_cnt;

	always @(*) begin
		imem_arready = !imem_r_pending;
		imem_rvalid	 = imem_r_pending;
		imem_rdata	 = read_word(imem_r_addr);
		imem_rid	 = imem_r_id;
		imem_rresp	 = `AXI_RESP_OKAY;
		imem_rlast	 = imem_r_pending && (imem_r_cnt == 0);
	end

	always @(posedge clk) begin
		if (rst) begin
			imem_r_pending <= 1'b0;
		end else if (!imem_r_pending) begin
			if (imem_arvalid && imem_arready) begin
				imem_r_addr <= imem_araddr;
				imem_r_id <= imem_arid;
				imem_r_cnt <= imem_arlen;
				imem_r_pending <= 1'b1;
			end
		end else if (imem_rvalid && imem_rready) begin
			if (imem_r_cnt == 0) begin
				imem_r_pending <= 1'b0;
			end else begin
				imem_r_addr <= imem_r_addr + 32'd8;
				imem_r_cnt <= imem_r_cnt - 1'b1;
			end
		end
	end

	wire uart_rx_pop = dmem_rvalid && dmem_rready &&
					   is_uart(dmem_r_addr) &&
					   (dmem_r_addr[2:0] == 3'd0) && !uart_dlab;
	always @(posedge clk) begin
		if (rst) begin
			uart_rx_valid <= 1'b0;
		end else if (uart_rx_pop) begin
			uart_rx_valid <= 1'b0;
		end else begin
`ifdef VERILATOR
			if (!uart_rx_valid) begin
				uart_ch = linux_uart_getchar();
				if (uart_ch >= 0) begin
					uart_rx_byte <= uart_ch[7:0];
					uart_rx_valid <= 1'b1;
				end
			end
`endif
		end
	end

	wire dmem_r_is_eth = is_eth(dmem_r_addr);
	always @(*) begin
		//	The karu_eth bridge services one transaction at a time and ignores a
		//	*_req asserted while busy, so don't accept an eth AR while it is busy
		//	(covers a read arriving while an eth write is in flight; a second eth
		//	read is already blocked by dmem_r_pending).
		dmem_arready = !dmem_r_pending && (!is_eth(dmem_araddr) || !eth_busy);
		//	eth reads are multi-cycle: only present data once the bridge is ready.
		dmem_rvalid	 = dmem_r_pending && (!dmem_r_is_eth || eth_rd_ready);
		dmem_rdata	 = dmem_r_is_eth ? eth_rd_data : read_word(dmem_r_addr);
		dmem_rid	 = dmem_r_id;
		dmem_rresp	 = `AXI_RESP_OKAY;
		dmem_rlast	 = dmem_rvalid && (dmem_r_cnt == 0);
	end

	always @(posedge clk) begin
		if (rst) begin
			dmem_r_pending <= 1'b0;
		end else if (!dmem_r_pending) begin
			if (dmem_arvalid && dmem_arready) begin
				dmem_r_addr <= dmem_araddr;
				dmem_r_id <= dmem_arid;
				dmem_r_cnt <= dmem_arlen;
				dmem_r_pending <= 1'b1;
			end
		end else if (dmem_rvalid && dmem_rready) begin
			if (dmem_r_cnt == 0) begin
				dmem_r_pending <= 1'b0;
			end else begin
				dmem_r_addr <= dmem_r_addr + 32'd8;
				dmem_r_cnt <= dmem_r_cnt - 1'b1;
			end
		end
	end

	reg						dmem_b_pending;
	reg [`AXI_ID_W-1:0]		dmem_b_id;
	wire [31:0]				hpm_events;

	//	+contention_stats: characterize whether the core ever presents multiple
	//	internal masters to the shared AXI arbiters in the real Linux workload.
	//	This is off by default and only observes hierarchical debug wires.
	reg						contention_stats = 1'b0;
	reg [63:0]				cont_dmem_aw_cyc = 64'd0;
	reg [63:0]				n_immu_aw = 64'd0;
	reg [63:0]				n_dmmu_aw = 64'd0;
	reg [63:0]				n_km_aw = 64'd0;
	reg [63:0]				cont_dmem_ar_cyc = 64'd0;
	reg [63:0]				n_dmmu_ar = 64'd0;
	reg [63:0]				n_km_ar = 64'd0;
	reg [63:0]				cont_imem_ar_cyc = 64'd0;
	reg [63:0]				n_immu_ar = 64'd0;
	reg [63:0]				n_ifm_ar = 64'd0;
	initial contention_stats = $test$plusargs("contention_stats") ||
							   $test$plusargs("arb_stats");

	always @(posedge clk) if (!rst && contention_stats) begin
		if ((cpu.dmmu_awvalid + cpu.immu_awvalid + cpu.km_awvalid) > 1)
			cont_dmem_aw_cyc <= cont_dmem_aw_cyc + 1'b1;
		if (cpu.immu_awvalid)
			n_immu_aw <= n_immu_aw + 1'b1;
		if (cpu.dmmu_awvalid)
			n_dmmu_aw <= n_dmmu_aw + 1'b1;
		if (cpu.km_awvalid)
			n_km_aw <= n_km_aw + 1'b1;

		if (cpu.dmmu_arvalid && cpu.km_arvalid)
			cont_dmem_ar_cyc <= cont_dmem_ar_cyc + 1'b1;
		if (cpu.dmmu_arvalid)
			n_dmmu_ar <= n_dmmu_ar + 1'b1;
		if (cpu.km_arvalid)
			n_km_ar <= n_km_ar + 1'b1;

		if (cpu.immu_arvalid && cpu.ifm_arvalid)
			cont_imem_ar_cyc <= cont_imem_ar_cyc + 1'b1;
		if (cpu.immu_arvalid)
			n_immu_ar <= n_immu_ar + 1'b1;
		if (cpu.ifm_arvalid)
			n_ifm_ar <= n_ifm_ar + 1'b1;
	end

	task print_contention_stats;
		begin
			if (contention_stats) begin
				$display("[dmem_aw_contention] cont_aw_cyc=%0d immu_aw=%0d dmmu_aw=%0d km_aw=%0d",
					cont_dmem_aw_cyc, n_immu_aw, n_dmmu_aw, n_km_aw);
				$display("[dmem_ar_contention] cont_ar_cyc=%0d dmmu_ar=%0d km_ar=%0d",
					cont_dmem_ar_cyc, n_dmmu_ar, n_km_ar);
				$display("[imem_ar_contention] cont_imem_ar=%0d immu_ar=%0d ifm_ar=%0d",
					cont_imem_ar_cyc, n_immu_ar, n_ifm_ar);
				$fflush;
			end
		end
	endtask

	//	+xpage_stats: count translated (S/U-mode, Sv39) misaligned SCALAR accesses
	//	that straddle a 4 KiB page -- the exact path the misaligned-cross-page fix
	//	corrects (doc/fpga.md "second candidate"). Counted
	//	at LSU ISSUE (cleanest ex_* context), broken down by load/store and S/U
	//	privilege; the first XP_SAMPLE_MAX hits print pc/va/size/sub/priv. Passive:
	//	only observes cpu.* debug wires. Supporting evidence for the HW Run-12
	//	retest -- nonzero => the live workload exercises the fixed path.
	localparam				XP_SAMPLE_MAX = 4'd8;
	reg						xpage_stats = 1'b0;
	reg [63:0]				xp_s_load = 64'd0, xp_s_store = 64'd0;
	reg [63:0]				xp_u_load = 64'd0, xp_u_store = 64'd0;
	reg [3:0]				xp_samples = 4'd0;
	initial xpage_stats = $test$plusargs("xpage_stats");

	always @(posedge clk)
		if (!rst && xpage_stats && cpu.issue_lsu && !cpu.lsu_bare && cpu.lsu_xpage) begin
			//	priv is S(1) or U(0) here (M-mode is bare -> excluded by !lsu_bare)
			case ({cpu.csr_priv == 2'd1, cpu.lsu_is_store})
				2'b10:   xp_s_load  <= xp_s_load  + 1'b1;	//	S-mode load
				2'b11:   xp_s_store <= xp_s_store + 1'b1;	//	S-mode store
				2'b00:   xp_u_load  <= xp_u_load  + 1'b1;	//	U-mode load
				default: xp_u_store <= xp_u_store + 1'b1;	//	U-mode store (2'b01)
			endcase
			if (xp_samples < XP_SAMPLE_MAX) begin
				$display("[xpage] #%0d cyc=%0d pc=%016h va=%016h size=%0dB sub=%0d priv=%0d %s",
					xp_samples, cyc, cpu.ex_pc, cpu.lsu_addr, (16'd1 << cpu.lsu_size),
					cpu.ex_sub, cpu.csr_priv, cpu.lsu_is_store ? "ST" : "LD");
				xp_samples <= xp_samples + 1'b1;
				$fflush;
			end
		end

	task print_xpage_stats;
		begin
			if (xpage_stats) begin
				$display("[xpage_stats] total=%0d  S{load=%0d store=%0d}  U{load=%0d store=%0d}",
					xp_s_load + xp_s_store + xp_u_load + xp_u_store,
					xp_s_load, xp_s_store, xp_u_load, xp_u_store);
				$fflush;
			end
		end
	endtask

	wire					hpm_imem_ram_req = imem_arvalid && imem_arready && is_ram(imem_araddr);
	wire					hpm_dmem_ram_read_req = dmem_arvalid && dmem_arready && is_ram(dmem_araddr);
	wire					hpm_dmem_ram_write_req = dmem_awvalid && dmem_awready &&
													 dmem_wvalid && dmem_wready && is_ram(dmem_awaddr);
	wire [3:0]				hpm_wstrb_pop = {3'b0, dmem_wstrb[0]} + {3'b0, dmem_wstrb[1]} +
											  {3'b0, dmem_wstrb[2]} + {3'b0, dmem_wstrb[3]} +
											  {3'b0, dmem_wstrb[4]} + {3'b0, dmem_wstrb[5]} +
											  {3'b0, dmem_wstrb[6]} + {3'b0, dmem_wstrb[7]};

	assign hpm_events = {
		21'b0,
		(dmem_awvalid && dmem_wvalid && is_ram(dmem_awaddr) && !dmem_awready),
		(dmem_arvalid && is_ram(dmem_araddr) && !dmem_arready),
		(imem_arvalid && is_ram(imem_araddr) && !imem_arready),
		1'b0,
		(hpm_dmem_ram_write_req && dmem_wstrb == 8'hff),
		(hpm_dmem_ram_write_req && hpm_wstrb_pop == 4'd1),
		(hpm_dmem_ram_write_req && dmem_wstrb != 8'hff),
		hpm_imem_ram_req,
		hpm_dmem_ram_write_req,
		hpm_dmem_ram_read_req,
		1'b0
	};

	always @(*) begin
		//	block new writes while a B is pending OR an eth write is in flight; and
		//	don't accept an eth write while the bridge is busy (covers a write
		//	arriving while an eth read is in flight -- karu_eth drops a *_req
		//	asserted while busy, which would otherwise hang the AXI side).
		dmem_awready = !dmem_b_pending && !eth_wr_inflight &&
					   (!is_eth(dmem_awaddr) || !eth_busy);
		dmem_wready	 = !dmem_b_pending && !eth_wr_inflight &&
					   (!is_eth(dmem_awaddr) || !eth_busy);
		dmem_bvalid	 = dmem_b_pending;
		dmem_bid	 = dmem_b_id;
		dmem_bresp	 = `AXI_RESP_OKAY;
	end

	integer b;
	always @(posedge clk) begin
		if (rst) begin
			dmem_b_pending  <= 1'b0;
			eth_wr_inflight <= 1'b0;
		end else begin
			if (dmem_b_pending && dmem_bready)
				dmem_b_pending <= 1'b0;
			if (dmem_awvalid && dmem_awready && dmem_wvalid && dmem_wready) begin
				if (is_eth(dmem_awaddr)) begin
					//	hand to the bridge (eth_wr_req pulses this cycle); defer B.
					eth_wr_inflight <= 1'b1;
					dmem_b_id <= dmem_awid;
				end else begin
					for (b = 0; b < 8; b = b + 1) begin
						if (dmem_wstrb[b])
							write_byte(dmem_awaddr + b[31:0], dmem_wdata[b*8 +: 8]);
					end
					dmem_b_pending <= 1'b1;
					dmem_b_id <= dmem_awid;
				end
			end
			//	bridge finished the eth write -> now raise the B response.
			if (eth_wr_inflight && eth_wr_done) begin
				eth_wr_inflight <= 1'b0;
				dmem_b_pending  <= 1'b1;
			end
		end
	end

	//	+heartbeat=N : print cyc + PC + priv + satp every N cycles (live progress).
	//	Also a one-shot marker the first time the PC enters the kernel window.
	reg [63:0] hb_n = 0;
	reg        kentry_seen = 1'b0;
	initial plus_ok = $value$plusargs("heartbeat=%d", hb_n);

	always @(posedge clk) begin
		cyc <= cyc + 1'b1;
		if (!rst && !kentry_seen &&
			cpu.ifu_pc[31:0] >= 32'h8020_0000 && cpu.ifu_pc[31:0] < 32'h8100_0000) begin
			kentry_seen <= 1'b1;
			$display("\n[LINUX-TB] >>> kernel window entered @ cyc=%0d pc=%016h", cyc, cpu.ifu_pc);
			$fflush;
		end
		if (hb_n != 0 && !rst && (cyc % hb_n == 0)) begin
			$display("[HB] cyc=%0d pc=%016h priv=%0d satp=%h", cyc, cpu.ifu_pc,
				cpu.csr_priv, cpu.csr_satp);
			$fflush;
			end
			if (trap) begin
				$display("\n[LINUX-TB] core trap @ cyc=%0d pc=%016h", cyc, cpu.ifu_pc);
				print_contention_stats();
				print_xpage_stats();
				$finish;
			end
			if (cyc >= max_cycles) begin
				$display("\n[LINUX-TB] timeout @ cyc=%0d pc=%016h", cyc, cpu.ifu_pc);
				print_contention_stats();
				print_xpage_stats();
				$finish;
			end
		end

	//	=== sim pass/fail exit: a dmem write to SIM_EXIT_ADDR ends the run with
	//	that 32-bit code (0 = pass). linux_tb.cpp returns it (see +require_exit).
	initial begin
		sim_exit_code  = 32'd0;
		sim_exit_valid = 1'b0;
	end
	wire sim_exit_we = dmem_awvalid && dmem_awready && dmem_wvalid && dmem_wready &&
					   (dmem_awaddr == SIM_EXIT_ADDR);
	always @(posedge clk) begin
		if (sim_exit_we) begin
			sim_exit_code  <= dmem_wdata[31:0];
			sim_exit_valid <= 1'b1;
				if (dmem_wdata[31:0] == 32'd0)
					$display("\n[SIM-EXIT] PASS (code=0)");
				else
					$display("\n[SIM-EXIT] FAIL (code=%0d)", dmem_wdata[31:0]);
				print_contention_stats();
				print_xpage_stats();
				$fflush;
				$finish;
			end
	end

	//	=== userspace (U-mode) tracer for the exit_group(216) hunt (+utrace=1) ===
	//	Dumps the full GPR/CSR state at the first sret into U-mode (so we can see
	//	the initial userspace register/stack state the kernel set up), then traces
	//	each retired U-mode instruction (capped) and decodes every U-mode ECALL
	//	(a7=syscall, a0..a2=args) -- so the exit_group(216) syscall + the path to
	//	it are visible in one boot.
	reg [31:0] utrace = 0;
	reg        u_seen = 1'b0;
	reg [31:0] u_cnt  = 0;
	reg [31:0] utrace_max = 32'd20000;
	integer    ti;
	initial begin
		plus_ok = $value$plusargs("utrace=%d", utrace);
		plus_ok = $value$plusargs("utrace_max=%d", utrace_max);
	end
	always @(posedge clk) if (utrace != 0 && !rst) begin
		if (!u_seen && cpu.csr_priv == 2'd0) begin
			u_seen <= 1'b1;
			$display("\n[U-ENTRY] cyc=%0d pc=%016h sepc=%016h mstatus=%016h satp=%h",
				cyc, cpu.ifu_pc, cpu.csr.csr_sepc, cpu.csr.csr_mstatus, cpu.csr_satp);
			for (ti = 0; ti < 32; ti = ti + 1)
				$display("[U-ENTRY] x%02d=%016h", ti, cpu.rf.rx[ti]);
			$fflush;
		end
		if (cpu.perf_retire && cpu.csr_priv == 2'd0) begin
			if (u_cnt < utrace_max) begin
				$display("[U] pc=%016h ins=%08h imm=%016h tgt=%016h isc=%b redir=%b rpc=%016h",
					cpu.ex_pc, cpu.ex_ins, cpu.ex_imm, cpu.bru_target,
					cpu.ex_is_c, cpu.ifu_redir, cpu.ifu_redir_pc);
				u_cnt <= u_cnt + 1'b1;
			end
			if (cpu.ex_ins == 32'h0000_0073) begin	//	ECALL from U-mode
				$display("[U-ECALL] a7=%0d a0=%0d (a0=%h) a1=%h a2=%h pc=%016h",
					cpu.rf.rx[17], cpu.rf.rx[10], cpu.rf.rx[10],
					cpu.rf.rx[11], cpu.rf.rx[12], cpu.ex_pc);
				$fflush;
			end
		end
	end

`ifdef KARU_IRQ_TRACE
	reg timer_irq_q = 1'b0;
	always @(posedge clk) begin
		timer_irq_q <= timer_irq;
		if (timer_irq & ~timer_irq_q)
			$display("[IRQ] t=%0d MTIP^ mtime=%0d mtimecmp=%0d", cyc, mtime, mtimecmp);
		if (dmem_awvalid && dmem_awready && dmem_wvalid && dmem_wready &&
			dmem_awaddr[31:16] == 16'h0200 && dmem_awaddr[15:3] == 13'h800)
			$display("[IRQ] t=%0d mtimecmp<=%0d (mtime=%0d)", cyc, dmem_wdata, mtime);
	end
`endif

	karu64 #(
		.RESET_PC(RESET_PC)
	) cpu (
		.clk		(clk),
		.rst		(rst),
		.trap		(trap),
		.irq		(timer_irq),
		.irq_external_m	(external_irq_m),
		.irq_external_s	(external_irq_s),
		.time_in	(64'b0),		//	EXT_TIME=0: rdtime uses the cycle counter (sim mtime==cyc anyway)
		.uncache_page(32'h1000_0000),
		.hpm_events	(hpm_events),
		.cache_flush_req		(),
		.cache_flush_invalidate	(),
		.cache_flush_done		(1'b1),
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

	wire _unused = &{imem_arsize, imem_arburst, imem_arprot,
					dmem_arsize, dmem_arburst, dmem_arprot,
					dmem_awsize, dmem_awburst, dmem_awprot,
					dmem_wlast, plus_ok[0], eth_busy, 1'b0};
endmodule
