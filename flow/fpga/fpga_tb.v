//	fpga_tb.v
//	=== simulation testbench for fpga_top (verilator / iverilog).
//
//	Boots a firmware hex out of the on-chip BRAM, lets karu_ns16550 print
//	the console via its SIM_TB $write shortcut, and watches the HTIF
//	tohost word for an exit (the hello firmware calls htif_exit, which on
//	the FPGA just parks the core but in sim lets us stop cleanly).
//
//	  +hex=<file>        firmware image (default firmware.hex)
//	  +tohost=<hex>      tohost offset within RAM (default 0x1000)
//	  +max_cycles=<dec>  watchdog (default 2,000,000)
//	  +uart_in=<file>    bytes fed to the UART RX (karu_ns16550 SIM model)
//	  +reset_at=<dec>    cycle at which to pulse an async reset (0 = never)
//	  +reset_len=<dec>   length of the injected reset pulse (default 24)

`include "config.vh"

`ifndef SIM_TB
`define SIM_TB
`endif

module clk_gen;
	/* verilator lint_off STMTDLY */
	reg clk = 1;
	always #5 clk = ~clk;
	/* verilator lint_on STMTDLY */
	fpga_tb tb (clk);
endmodule

module fpga_tb (input wire clk);

	localparam	RAM_XADR = 20;

	reg [8*256-1:0]	hex_file;
	reg [31:0]		max_cycles = 32'd2_000_000;
	reg [31:0]		tohost_off = 32'h0000_1000;
	reg [31:0]		reset_at   = 32'd0;			//	0 = no injected reset
	reg [31:0]		reset_len  = 32'd24;
	integer			pa_ok;

	initial begin
		if (!$value$plusargs("hex=%s", hex_file))
			hex_file = "firmware.hex";
		pa_ok = $value$plusargs("max_cycles=%d", max_cycles);
		pa_ok = $value$plusargs("tohost=%h", tohost_off);
		pa_ok = $value$plusargs("reset_at=%d", reset_at);
		pa_ok = $value$plusargs("reset_len=%d", reset_len);
	end

	reg  [31:0]	cyc = 0;
	wire		trap;
	wire		uart_txd, uart_rts;

	//	async reset request into the real reset_ctrl conditioning module:
	//	the POR stretch holds reset at start; an optional `+reset_at` pulse
	//	models the operator pressing the reset button mid-run.
	reg			arst = 1'b0;
	always @(posedge clk) begin
		if (reset_at != 0 && cyc >= reset_at && cyc < reset_at + reset_len)
			arst <= 1'b1;
		else
			arst <= 1'b0;
		if (reset_at != 0 && cyc == reset_at)
			$display("\n[RESET-INJECT] asserting reset for %0d cyc @ cyc=%0d",
					 reset_len, cyc);
	end

	wire		rst;
	reset_ctrl #(
		.POR_CYCLES	(8)
	) u_rst (
		.clk		(clk),
		.arst_in	(arst),
		.rst_out	(rst)
	);

	fpga_top #(
		.RAM_XADR	(RAM_XADR)
	) dut (
		.clk		(clk),
		.rst		(rst),
		.uart_txd	(uart_txd),
		.uart_rxd	(1'b1),
		.uart_rts	(uart_rts),
		.uart_cts	(1'b1),
		.trap		(trap)
	);

	wire [RAM_XADR-4:0]	tohost_idx = tohost_off[RAM_XADR-1:3];
	reg  [63:0]			tohost_v;

	//	---- passive timing observer (irq-test TEST 4 evidence) ----
	//	Records when a PENDING interrupt co-occurs with an in-flight VLSU op:
	//	direct proof the deadline became pending DURING the vector load/store
	//	(so the drain gate -- irq_take requires !vlsu_active -- is actually
	//	exercised mid-VLSU, not merely after it). Harmless for non-irq sims
	//	(the co-occurrence never arises there, so it stays 0 and prints nothing).
	//	the firmware sets a marker word (0x80001100) high ONLY around TEST 4's
	//	strided store, so the observer credits that op specifically (not an
	//	incidental VLSU/IRQ overlap elsewhere). Marker is write-through RAM.
	localparam [31:0]	MARK_OFF = 32'h0000_1100;
	wire [RAM_XADR-4:0]	mark_idx = MARK_OFF[RAM_XADR-1:3];
	reg irq_during_vlsu_seen = 1'b0;
	always @(posedge clk) if (!rst) begin
		if (dut.sys.ram[mark_idx][0] && dut.cpu.csr_irq_pending && dut.cpu.vlsu_busy
			&& !irq_during_vlsu_seen) begin
			irq_during_vlsu_seen <= 1'b1;
			$display("[irq-obs] TEST4: interrupt pending DURING in-flight strided-store VLSU @ cyc=%0d", cyc);
		end
	end

	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (!rst) begin
			tohost_v = dut.sys.ram[tohost_idx];
			if (tohost_v[0]) begin
				$display("\n[HTIF] exit %0d @ cyc=%0d (irq_during_vlsu=%0d)",
						 tohost_v >> 1, cyc, irq_during_vlsu_seen);
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
