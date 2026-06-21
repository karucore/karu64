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

module fpga_ddr_tb (input wire clk);

	localparam	RAM_XADR = 20;
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
		.RLAT	 (RLAT)
	) dut (
		.clk(clk), .rst(rst),
		.uart_txd(uart_txd), .uart_rxd(1'b1),
		.uart_rts(uart_rts), .uart_cts(1'b1),
		.trap(trap)
	);

	wire [RAM_XADR-4:0]	tohost_idx = tohost_off[RAM_XADR-1:3];
	reg  [63:0]			tohost_v;

	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (!rst) begin
			tohost_v = dut.dram.ram[tohost_idx];
			if (tohost_v[0]) begin
				$display("\n[HTIF] exit %0d @ cyc=%0d", tohost_v >> 1, cyc);
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
