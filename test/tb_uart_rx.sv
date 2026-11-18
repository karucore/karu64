//	tb_uart_rx.sv
//	=== Unit test of flow/fpga/uart_rx.v: the "byte was read" handshake.
//
//	The receiver has no FIFO: one byte is ready (rdy) until the reader
//	pulses ack for one cycle (karu_ns16550.v does so in the cycle of the
//	accepted RBR read, the cycle in which the bus samples data; that
//	alignment is tested by tb_ns16550_loop.sv). The pulse must clear rdy in
//	whatever cycle it lands, including
//	the cycles in which the bit FSM takes a step (tmr == 0). It used to be
//	ignored there, so about one read in 41 with an idle line left the byte
//	ready and Linux's 8250 driver read it twice (board campaign 2026-11-16:
//	"tail" arrived as "taiil").
//
//	Checked, at the VCU118 setting (75 MHz, 115200 baud):
//	  * every byte value sent is received once and unchanged;
//	  * directed: an ack in each kind of FSM step cycle clears rdy
//	    (idle poll, start-bit detection, every data-bit sample);
//	  * an ack in the stop-bit cycle of the next byte refers to the old
//	    byte, still in data during that cycle, and leaves the new one ready;
//	  * a reader model with random service delays over back-to-back and
//	    spaced bytes never reads a byte twice;
//	  * an unread byte is overwritten by the next one (documented overrun).
//
//	make uart-rx-test also runs this against a copy with the old ack rule
//	(honoured only while tmr != 0), which must fail: once through the
//	receiver's own assertion and once, with assertions off, through the
//	checks here.

`timescale 1ns/1ps

module tb_uart_rx;
	localparam	BITCLKS = 651;				//	75 MHz / 115200

	reg			clk = 1'b0;
	reg			rst = 1'b1;
	reg			ack = 1'b0;
	reg			rxd = 1'b1;
	wire [7:0]	data;
	wire		rdy, rts;

	always #5 clk = !clk;

	uart_rx #(.BITCLKS(BITCLKS)) dut (
		.clk(clk), .rst(rst), .ack(ack), .data(data), .rdy(rdy), .rts(rts), .rxd(rxd));

	integer		checks = 0;
	integer		seed = 1;
	reg [7:0]	seen;						//	data sampled in a directed ack cycle

	task check(input cond, input [8*64-1:0] what);
		begin
			checks = checks + 1;
			if (!cond)
				$fatal(1, "FAIL uart_rx check %0d: %0s", checks, what);
		end
	endtask

	//	one 8-N-1 frame on the line; returns one stop-bit time after it
	task send(input [7:0] b);
		integer i;
		begin
			rxd = 1'b0; repeat (BITCLKS) @(posedge clk);
			for (i = 0; i < 8; i = i + 1) begin
				rxd = b[i]; repeat (BITCLKS) @(posedge clk);
			end
			rxd = 1'b1; repeat (BITCLKS) @(posedge clk);
		end
	endtask

	//	one-cycle ack, sampled by exactly one rising edge
	task pulse_ack;
		begin
			@(negedge clk); ack = 1'b1;
			@(negedge clk); ack = 1'b0;
		end
	endtask

	//	wait for a cycle in which the FSM steps (tmr == 0) in state `st`,
	//	then pulse ack in exactly that cycle
	task ack_on_step(input [3:0] st, output reg hit);
		integer t;
		begin
			hit = 1'b0; t = 0;
			@(negedge clk);
			while (!(dut.tmr == 0 && dut.idx == st) && t < 20 * BITCLKS) begin
				@(negedge clk); t = t + 1;
			end
			if (dut.tmr == 0 && dut.idx == st) begin
				hit = 1'b1;
				seen = data;						//	what a reader samples in the ack cycle
				ack = 1'b1; @(negedge clk); ack = 1'b0;
			end
		end
	endtask

	//	---- reader model: what the UART register file and a driver do ----
	//	When rdy is seen, wait a random service delay, take the byte and
	//	pulse ack one cycle later. Each byte taken is compared with the next
	//	byte sent (scoreboard), so a byte delivered twice, lost or changed
	//	is a mismatch.
	reg			reader_on = 1'b0;
	integer		max_delay = 1;
	reg [7:0]	sb [0:1023];
	integer		sb_wr = 0, sb_rd = 0, sb_bad = 0;
	integer		d;
	always begin
		@(posedge clk);
		if (reader_on && rdy) begin
			d = $urandom(seed) % max_delay;
			repeat (d) @(posedge clk);
			@(negedge clk);
			if (rdy) begin
				if (sb_rd >= sb_wr || data != sb[sb_rd]) sb_bad = sb_bad + 1;
				sb_rd = sb_rd + 1;
				ack = 1'b1; @(negedge clk); ack = 1'b0;
			end
		end
	end
	task send_scored(input [7:0] v);
		begin
			sb[sb_wr] = v; sb_wr = sb_wr + 1;	//	rdy rises before send() returns
			send(v);
		end
	endtask

	integer		i, n;
	reg			hit;

	initial begin
		repeat (4) @(posedge clk); rst = 1'b0;

		//	---- every byte value, read at a safe time ----
		for (i = 0; i < 256; i = i + 1) begin
			send(i[7:0]);
			check(rdy && data == i[7:0], "byte received unchanged");
			repeat (100) @(posedge clk);
			pulse_ack; @(negedge clk);
			check(!rdy, "ack clears rdy");
		end

		//	---- directed: ack in an idle-poll step cycle (the board case) ----
		for (i = 0; i < 8; i = i + 1) begin
			send(8'h69);
			check(rdy && data == 8'h69, "byte ready before the idle-step ack");
			repeat (37 * i + 5) @(posedge clk);
			ack_on_step(4'd9, hit);
			check(hit, "found an idle-poll step cycle");
			@(negedge clk);
			check(!rdy, "ack on an idle-poll step clears rdy");
		end

		//	---- directed: ack while the next byte is being received ----
		//	start-bit detection is also an idx 9 step; the eight data-bit
		//	samples are steps in idx 0..7
		for (i = 0; i < 9; i = i + 1) begin
			send(8'ha5);
			check(rdy && data == 8'ha5, "first byte ready");
			fork
				send(8'h3c);
				begin
					if (i == 8) begin
						//	the cycle that detects the start bit
						@(negedge clk);
						while (!(dut.tmr == 0 && dut.idx == 4'd9 && !dut.rxd_s)) @(negedge clk);
						ack = 1'b1; @(negedge clk); ack = 1'b0; hit = 1'b1;
					end else
						ack_on_step(i[3:0], hit);
					check(hit, "found the bit-step cycle");
					@(negedge clk);
					check(!rdy, "ack on a bit-FSM step clears rdy");
				end
			join
			check(rdy && data == 8'h3c, "second byte received after the mid-frame ack");
			repeat (50) @(posedge clk); pulse_ack; @(negedge clk);
			check(!rdy, "second byte consumed");
		end

		//	---- ack in the stop-bit cycle of the next byte: it stays ready ----
		send(8'h11);
		check(rdy && data == 8'h11, "first byte ready before the stop-bit race");
		fork
			send(8'h22);
			begin
				ack_on_step(4'd8, hit);
				check(hit, "found the stop-bit step cycle");
				check(seen == 8'h11, "data in the ack cycle is still the old byte");
				@(negedge clk);
				check(rdy && data == 8'h22, "byte completing in the ack cycle stays ready");
			end
		join
		repeat (50) @(posedge clk); pulse_ack; @(negedge clk);
		check(!rdy, "raced byte consumed");

		//	---- overrun: an unread byte is replaced by the next ----
		send(8'h55); send(8'haa);
		check(rdy && data == 8'haa, "unread byte is overwritten (no FIFO)");
		pulse_ack; @(negedge clk);
		check(!rdy, "overrun byte consumed");

		//	---- reader model, spaced bytes: nothing lost, nothing doubled ----
		//	The reader takes each byte while the line is idle, at a random
		//	point of the idle-poll period.
		reader_on = 1'b1; max_delay = 3000; sb_wr = 0; sb_rd = 0; sb_bad = 0;
		for (n = 0; n < 300; n = n + 1) begin
			send_scored($urandom(seed));
			repeat ($urandom(seed) % 2000 + 3100) @(posedge clk);	//	longer than any service delay
		end
		repeat (4000) @(posedge clk);
		check(sb_bad == 0 && sb_rd == sb_wr, "spaced bytes: each delivered exactly once, in order");

		//	---- reader model, back-to-back bytes with a fast reader ----
		//	The reader takes each byte while the next one is being received.
		max_delay = 3000; sb_wr = 0; sb_rd = 0; sb_bad = 0;		//	under half a frame
		for (n = 0; n < 300; n = n + 1)
			send_scored($urandom(seed));
		repeat (4000) @(posedge clk);
		check(sb_bad == 0 && sb_rd == sb_wr, "back-to-back bytes: each delivered exactly once, in order");
		reader_on = 1'b0;

		$display("uart_rx: PASS (%0d checks)", checks);
		$finish;
	end

	initial begin
		#2000000000;
		$fatal(1, "FAIL uart_rx: global timeout");
	end
endmodule
