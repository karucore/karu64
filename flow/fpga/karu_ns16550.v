//	karu_ns16550.v
//	=== NS16550-compatible UART, register-layout matched to spike.
//
//	Spike's builtin model (riscv/ns16550.cc) sits at 0x10000000 with
//	reg-shift=0 / reg-io-width=1 (riscv/platform.h): the eight 16550
//	byte registers occupy byte offsets 0..7, i.e. exactly one 64-bit
//	word. We mirror that layout so one firmware binary (test/fw/ns16550.c)
//	drives the console on both spike and this device.
//
//	  off  read         write
//	   0   RBR          THR           (DLAB=1: DLL)
//	   1   IER          IER           (DLAB=1: DLM)
//	   2   IIR          FCR
//	   3   LCR          LCR
//	   4   MCR          MCR
//	   5   LSR          -             (DR / THRE / TEMT)
//	   6   MSR          -
//	   7   SCR          SCR
//
//	The serial transmit/receive shift logic is the minimal 8-N-1 pair
//	from the sloth project (uart_tx.v / uart_rx.v), found to work on the
//	VCU118. Under SIM_TB the physical serializer is replaced by an
//	immediate $write so console output is fast in simulation -- the
//	register decode and LSR polling the firmware exercises are unchanged.

`include "karu_ext.vh"

module karu_ns16550 #(
	parameter	BITCLKS = (`IUTSYS_CLK / 115200)
) (
	input  wire			clk,
	input  wire			rst,
	//	register-file access (decoded out of the AXI dmem path)
	input  wire			re,			//	read beat accepted this cycle
	input  wire [2:0]	raddr,		//	register index being read
	input  wire			we,			//	write beat accepted this cycle
	input  wire [7:0]	wstrb,		//	byte lanes written (= register idx)
	input  wire [63:0]	wdata,		//	write data (lane b -> register b)
	output wire [63:0]	rdata,		//	read data (lane b = register b)
	//	external serial interface
	output wire			uart_txd,
	input  wire			uart_rxd,
	output wire			uart_rts,
	input  wire			uart_cts,
	//	level-triggered interrupt request (-> PLIC source)
	output wire			intr,
	output wire			thr_ready
);
	//	LSR bits
	localparam	LSR_DR	 = 8'h01;
	localparam	LSR_THRE = 8'h20;
	localparam	LSR_TEMT = 8'h40;
	//	LCR bit
	localparam	LCR_DLAB = 8'h80;

	//	programmable registers
	reg [7:0]	ier;
	reg [7:0]	fcr;
	reg [7:0]	lcr;
	reg [7:0]	mcr;
	reg [7:0]	scr;
	reg [7:0]	dll, dlm;

	wire		dlab = lcr[7];

	//	per-register write decode (firmware uses byte stores: one lane)
	wire		wr0 = we & wstrb[0];	//	THR / DLL
	wire		wr1 = we & wstrb[1];	//	IER / DLM
	wire		wr2 = we & wstrb[2];	//	FCR
	wire		wr3 = we & wstrb[3];	//	LCR
	wire		wr4 = we & wstrb[4];	//	MCR
	wire		wr7 = we & wstrb[7];	//	SCR
	wire		rbr_read = re & (raddr == 3'd0) & ~dlab;

	//	==================== transmit ====================
	reg  [7:0]	tx_data;
	reg			tx_send;
	wire		tx_rdy;					//	uart_tx ready for next byte

	//	THR write (DLAB=0) launches a byte
	wire		thr_we_raw = wr0 & ~dlab;
	wire		thr_we = thr_we_raw & tx_rdy;
	assign		thr_ready = dlab || tx_rdy;

	always @(posedge clk) begin
		if (rst) begin
			tx_send <= 1'b0;
		end else begin
			tx_send <= thr_we;			//	one-cycle send pulse
			if (thr_we)
				tx_data <= wdata[7:0];
		end
	end

`ifdef SIM_TB
	//	fast console in simulation: emit immediately, always ready
	assign	uart_txd = 1'b1;
	assign	tx_rdy	 = 1'b1;
	always @(posedge clk) begin
		if (!rst && thr_we) begin
			$write("%c", wdata[7:0]);
			$fflush(32'h1);
		end
	end
`ifndef KARU_NO_ASSERT
	always @(posedge clk) begin
		if (!rst && thr_we_raw && !tx_rdy) begin
			$display("[ASSERT] ns16550 THR write accepted while not ready");
			$finish;
		end
	end
`endif
`else
	uart_tx #(
		.BITCLKS	(BITCLKS)
	) u_tx (
		.clk	(clk		),
		.rst	(rst		),
		.send	(tx_send	),
		.data	(tx_data	),
		.rdy	(tx_rdy		),
		.cts	(uart_cts	),
		.txd	(uart_txd	)
	);
`endif

	//	THRE/TEMT: high when the transmitter can accept a new byte
	wire [7:0]	lsr_tx = tx_rdy ? (LSR_THRE | LSR_TEMT) : 8'h00;

	//	==================== receive ====================
	wire [7:0]	rx_data;
	wire		rx_rdy;					//	uart_rx has a byte
	reg			rx_ack;					//	pulse to consume it

	//	RX consume trigger: normal NS16550 semantics. The memory system
	//	preserves MMIO read byte offsets, so RBR reads can be distinguished
	//	from LSR/IIR polls.
	always @(posedge clk) begin
		if (rst)
			rx_ack <= 1'b0;
		else
			rx_ack <= rbr_read & rx_rdy;
	end

	wire		_unused_rd = &{wr7, 1'b0};

`ifdef SIM_TB
	//	===== simulation RX model: feed bytes from a file =====
	//	`+uart_in=<file>` streams the file's bytes into the RX register one
	//	at a time; each byte stays "ready" (LSR.DR=1) until the CPU reads
	//	RBR, then the next byte is fetched. At EOF
	//	the RX simply goes idle (DR=0), which the firmware's poll loop sees
	//	as "no input". This exercises the exact register/LSR path the real
	//	uart_rx drives, with no serial timing model.
	reg  [8*256-1:0]	rx_fn;
	integer				rx_fh;
	reg					rx_open = 1'b0;
	integer				rx_ch;
	reg					rx_has  = 1'b0;
	reg  [7:0]			rx_byte = 8'h00;

	initial begin
		if ($value$plusargs("uart_in=%s", rx_fn)) begin
			rx_fh = $fopen(rx_fn, "rb");
			if (rx_fh != 0)
				rx_open = 1'b1;
		end
	end

	always @(posedge clk) begin
		if (rx_open) begin
			if (!rx_has) begin
				rx_ch = $fgetc(rx_fh);
				if (rx_ch >= 0) begin
					rx_byte <= rx_ch[7:0];
					rx_has  <= 1'b1;
				end else begin
					$fclose(rx_fh);
					rx_open <= 1'b0;
				end
			end else if (rx_ack) begin
				rx_has <= 1'b0;			//	consumed; refetch next cycle
			end
		end
	end

	assign	rx_rdy	 = rx_has;
	assign	rx_data	 = rx_byte;
	assign	uart_rts = ~rx_has;
	wire	_unused_rx = &{uart_rxd, 1'b0};
`else
	uart_rx #(
		.BITCLKS	(BITCLKS)
	) u_rx (
		.clk	(clk		),
		.rst	(rst		),
		.ack	(rx_ack		),
		.data	(rx_data	),
		.rdy	(rx_rdy		),
		.rts	(uart_rts	),
		.rxd	(uart_rxd	)
	);
`endif

	wire [7:0]	lsr = lsr_tx | (rx_rdy ? LSR_DR : 8'h00);

	//	==================== interrupt (16550 IIR/IER) ====================
	//	Level-triggered sources: received-data-available (IER[0] & LSR.DR) and
	//	transmitter-holding-register-empty (IER[1] & LSR.THRE). RDA outranks
	//	THRE. The PLIC treats this line as level-sensitive, so it deasserts
	//	when the firmware services the condition (reads RBR / writes THR).
	wire		irq_rda  = ier[0] & rx_rdy;
	wire		irq_thre = ier[1] & tx_rdy;
	assign		intr = irq_rda | irq_thre;

	//	IIR (read @ off 2): bit0=0 when an interrupt is pending; [3:1]=id
	//	(010=RDA, 001=THRE); [7:6]=11 when the FIFO is enabled (FCR[0]).
	wire [7:0]	iir   = irq_rda  ? 8'h04 :
						irq_thre ? 8'h02 :
								   8'h01;	//	no interrupt pending
	wire [7:0]	iir_r = iir | (fcr[0] ? 8'hC0 : 8'h00);

	//	==================== register writes ====================
	always @(posedge clk) begin
		if (rst) begin
			ier <= 8'h00;
			fcr <= 8'h00;
			lcr <= 8'h00;
			mcr <= 8'h08;	//	OUT2, matches spike reset
			scr <= 8'h00;
			dll <= 8'h0C;
			dlm <= 8'h00;
		end else begin
			if (wr0 &  dlab) dll <= wdata[ 7: 0];
			if (wr1 &  dlab) dlm <= wdata[15: 8];
			if (wr1 & ~dlab) ier <= wdata[15: 8] & 8'h0F;
			if (wr2)         fcr <= wdata[23:16];
			if (wr3)         lcr <= wdata[31:24];
			if (wr4)         mcr <= wdata[39:32];
			if (wr7)         scr <= wdata[63:56];
		end
	end

	//	==================== register reads ====================
	//	byte lane b carries register b; the LSU extracts the byte it asked
	//	for, so we expose the whole word and only act on side effects via
	//	`raddr` (RBR pop handled above).
	wire [7:0]	r0 = dlab ? dll : rx_data;	//	RBR / DLL
	wire [7:0]	r1 = dlab ? dlm : ier;		//	IER / DLM
	wire [7:0]	r2 = iir_r;					//	IIR: pending-interrupt id
	wire [7:0]	r3 = lcr;
	wire [7:0]	r4 = mcr;
	wire [7:0]	r5 = lsr;
	wire [7:0]	r6 = 8'hB0;					//	MSR: DCD|DSR|CTS-ish
	wire [7:0]	r7 = scr;

	assign rdata = { r7, r6, r5, r4, r3, r2, r1, r0 };

endmodule
