//	vcu118_top.v
//	=== board top for the Xilinx VCU118 (xcvu9p-flga2104-2L-e).
//
//	Minimal bring-up wrapper: differential 125 MHz system clock to single
//	ended, push-button reset, and the NS16550 serial pins on the on-board
//	CP2105 USB-UART. The serial / pin mapping is the one from the sloth
//	project, found to work on this board; the core underneath is karu64.
//	Pin constraints are in flow/fpga/vcu118.xdc.

`include "karu_ext.vh"

`ifndef SIM_TB
module vcu118_top (
	input  wire			clk_125mhz_p,
	input  wire			clk_125mhz_n,
	output wire			usb_uart_txd_o,
	input  wire			usb_uart_rxd_i,
	output wire			usb_uart_rts_o,
	input  wire			usb_uart_cts_i,
	input  wire			btn_rst_i,
	input  wire	[4:0]	btn_i,			//	(N, E, W, S, C)
	output wire [7:0]	led_o
);
	wire		clk_in125;	//	125 MHz board LVDS clock
	wire		clk;		//	core clock = 62.5 MHz (125/2, 16 ns)

	//	differential -> single-ended 125 MHz system clock (CLK_125MHZ, LVDS)
	IBUFGDS #(
		.IOSTANDARD		("LVDS" ),
		.DIFF_TERM		("FALSE"),
		.IBUF_LOW_PWR	("FALSE")
	) i_sysclk_iobuf (
		.I	(clk_125mhz_p),
		.IB	(clk_125mhz_n),
		.O	(clk_in125)
	);

	//	divide the 125 MHz input by 2 -> 62.5 MHz core clock (16 ns). 8 ns/125
	//	MHz did not close timing for the IMAFDC core (post-route WNS -2.35 ns);
	//	62.5 MHz leaves ~8 ns of margin. Vivado auto-derives the /2 generated
	//	clock from BUFGCE_DIV, so the XDC keeps the 8 ns constraint on the input
	//	port and core logic is analysed at 16 ns. `IUTSYS_CLK` (karu_ext.vh) is set
	//	to 62.5e6 so UART baud + the heartbeat track the real core frequency.
	BUFGCE_DIV #(
		.BUFGCE_DIVIDE	(2)
	) i_clkdiv (
		.I		(clk_in125),
		.CE		(1'b1),
		.CLR	(1'b0),
		.O		(clk)
	);

	//	power-on / button reset: a power-on stretch + 2-FF synchronizer on
	//	the async button level (reset_ctrl). The reset request is either the
	//	dedicated CPU-reset button or the centre directional button.
	wire		rst_req = btn_i[4] ^ btn_rst_i;
	wire		soft_rst_r;

	reset_ctrl #(
		.POR_CYCLES	(1024)				//	~8.2 us at 125 MHz
	) u_rst (
		.clk		(clk),
		.arst_in	(rst_req),
		.rst_out	(soft_rst_r)
	);

	//	one-second heartbeat counter (held in reset while soft_rst_r is high)
	reg [31:0]	sec_cnt_r	= 32'd0;
	reg [31:0]	cyc_cnt_r	= 32'd0;

	always @(posedge clk) begin
		if (soft_rst_r) begin
			cyc_cnt_r	<= 32'd0;
			sec_cnt_r	<= 32'd0;
		end else if (cyc_cnt_r == `IUTSYS_CLK - 1) begin
			cyc_cnt_r	<= 32'd0;
			sec_cnt_r	<= sec_cnt_r + 1'b1;
		end else begin
			cyc_cnt_r	<= cyc_cnt_r + 1'b1;
		end
	end

	wire		uart_txd;
	wire		uart_rxd = usb_uart_rxd_i;
	wire		uart_rts;
	wire		trap;

	assign		usb_uart_txd_o = uart_txd;
	assign		usb_uart_rts_o = ~uart_rts;		//	active-low RTS pin

	//	LED status: trap, serial lines, heartbeats
	assign led_o = {	trap,
						usb_uart_rxd_i, uart_txd,
						usb_uart_rts_o, usb_uart_cts_i,
						soft_rst_r,
						sec_cnt_r[0], cyc_cnt_r[24] };

	fpga_top #(
		.RAM_XADR	(20),				//	1 MiB on-chip RAM
		.RESET_PC	(32'h8000_0000),
		.HEXFILE	("firmware.hex")
	) soc (
		.clk		(clk),
		.rst		(soft_rst_r),
		.uart_txd	(uart_txd),
		.uart_rxd	(uart_rxd),
		.uart_rts	(uart_rts),
		.uart_cts	(~usb_uart_cts_i),	//	active-low CTS pin
		.trap		(trap)
	);

endmodule
`endif
