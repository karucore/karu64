//	fpga_ddr_tb.v
//	=== verilator/iverilog testbench for fpga_ddr_top (DDR4/MIG bridge sim).
//
//	Same harness as fpga_tb.v but the SoC main memory is the behavioral
//	karu_axi4_ram behind karu_ddr_xbar. Boots a firmware hex from that RAM,
//	prints over the modeled NS16550, and watches the HTIF tohost word.
//
//	  +hex=<file>        firmware image (default firmware.hex)
//	  +tohost=<hex>      tohost offset within DRAM (default 0x1000)
//	  +max_cycles=<dec>  watchdog (default 2,000,000)
//	  +uart_in=<file>    bytes fed to the UART RX
//	  +rom=<file>        boot ROM image (replaces the xbar's default ROM_HEX)
//	  +vec_out=<file>    at the HTIF exit, write DRAM words to this file
//	  +vec_out_start=<dec> +vec_out_words=<dec>   which 64-bit words
//
//	Top-level parameters (verilator -G) for runs that boot from the ROM:
//	RAM_XADR (DRAM size, log2 bytes), RESET_PC and CPU_CLK_HZ (sets how fast
//	CLINT mtime runs relative to the clock).

`include "karu_ext.vh"

`ifndef SIM_TB
`define SIM_TB
`endif

module clk_gen;
	/* verilator lint_off STMTDLY */
	reg clk = 1;
	always #5 clk = ~clk;
	/* verilator lint_on STMTDLY */
	fpga_ddr_tb tb (clk);
endmodule

module fpga_ddr_tb #(
	parameter		 RAM_XADR	= 20,
	parameter [31:0] RESET_PC	= 32'h8000_0000,
	parameter		 CPU_CLK_HZ	= 100000000,
	//	passed to fpga_ddr_top: the Zkr entropy source's rate, and the island
	//	ROM of a build with debug authentication
	parameter integer ZKR_SAMPLE_DIV = 256,
	parameter [15:0] ZKR_INTERVAL	= 16'd15,
	parameter integer ZKR_BURST_LOG2 = 11,
	parameter		 AUTH_ROM_HEX	= ""
) (input wire clk);

	localparam	RLAT	 = 4;			//	model a few MIG read-latency beats

	reg [8*256-1:0]	hex_file;
	reg [31:0]		max_cycles = 32'd2_000_000;
	reg [31:0]		tohost_off = 32'h0000_1000;
	integer			pa_ok;

	initial begin
		if (!$value$plusargs("hex=%s", hex_file))
			hex_file = "firmware.hex";
		pa_ok = $value$plusargs("max_cycles=%d", max_cycles);
		pa_ok = $value$plusargs("tohost=%h", tohost_off);
	end

	reg  [31:0]	cyc = 0;
	wire		trap;
	wire		uart_txd, uart_rts;

	//	power-on reset stretch
	wire		rst;
	reset_ctrl #(.POR_CYCLES(8)) u_rst (
		.clk(clk), .arst_in(1'b0), .rst_out(rst)
	);

	fpga_ddr_top #(
		.RAM_XADR(RAM_XADR),
		.RESET_PC(RESET_PC),
		.CPU_CLK_HZ(CPU_CLK_HZ),
		.ZKR_SAMPLE_DIV(ZKR_SAMPLE_DIV), .ZKR_INTERVAL(ZKR_INTERVAL), .ZKR_BURST_LOG2(ZKR_BURST_LOG2),
		.AUTH_ROM_HEX(AUTH_ROM_HEX),
		.RLAT	 (RLAT)
	) dut (
		.clk(clk), .rst(rst),
		.uart_txd(uart_txd), .uart_rxd(1'b1),
		.uart_rts(uart_rts), .uart_cts(1'b1),
		.trap(trap)
	);

	//	Optional boot ROM image. It is loaded on the first clock edge, still
	//	inside the power-on reset, so that it replaces the xbar's own image
	//	whatever the order of the initial blocks.
	reg [8*256-1:0]	rom_file;
	reg				rom_loaded = 1'b0;
	always @(posedge clk) if (!rom_loaded) begin
		rom_loaded <= 1'b1;
		if ($value$plusargs("rom=%s", rom_file))
			$readmemh(rom_file, dut.xbar.u_boot_mem.rom);
	end

	wire [RAM_XADR-4:0]	tohost_idx = tohost_off[RAM_XADR-1:3];
	reg  [63:0]			tohost_v;

	//	Optional dump of DRAM at the HTIF exit, as in rtl/htif_tb.v.
	reg [8*256-1:0]	vec_out_file;
	reg [31:0]		vec_out_start = 32'd0;		//	64-bit word index
	reg [31:0]		vec_out_words = 32'd0;
	reg				dump_vec_out = 1'b0;
	initial if ($value$plusargs("vec_out=%s", vec_out_file)) begin
		dump_vec_out = 1'b1;
		pa_ok = $value$plusargs("vec_out_start=%d", vec_out_start);
		pa_ok = $value$plusargs("vec_out_words=%d", vec_out_words);
	end

	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (!rst) begin
			tohost_v = dut.dram.ram[tohost_idx];
			if (tohost_v[0]) begin
				$display("\n[HTIF] exit %0d @ cyc=%0d", tohost_v >> 1, cyc);
				if (dump_vec_out) begin
					$writememh(vec_out_file, dut.dram.ram, vec_out_start, vec_out_start + vec_out_words - 1);
					$display("[HTIF] dumped %0d words to %0s", vec_out_words, vec_out_file);
				end
				$finish;
			end
		end
		if (trap) begin
			$display("\n[**TRAP**] cyc=%0d", cyc);
			$finish;
		end
		if (cyc >= max_cycles) begin
			$display("\n[**TIMEOUT**] cyc=%0d", cyc);
			$finish;
		end
	end

	wire _unused = &{uart_txd, uart_rts, 1'b0};

endmodule
