//	tb_ns16550_loop.sv
//	=== karu_ns16550 with its real serializers, TX looped back to RX.
//
//	Built without SIM_TB, so the register file drives the real uart_tx and
//	uart_rx (SIM_TB replaces both with file/console models, which is why
//	this path had no simulation before). The bench is the software side: it
//	polls LSR, writes THR and reads RBR through the register interface, the
//	way an 8250 driver does: after each RBR read it reads LSR again and
//	takes another byte while LSR.DR is still set.
//
//	Every byte written to THR must come back exactly once and unchanged.
//	With the old uart_rx ack rule a read could leave LSR.DR set and the same
//	byte was read twice (board campaign 2026-11-16).
//
//	The last section places an RBR read on, just before and just after the
//	edge on which the next byte completes. On that edge the read returns the
//	old byte and the new one must stay ready. With the old wrapper, whose
//	pop was one cycle after the read, the new byte's ready flag was cleared
//	and the byte was lost (review 2026-11-17).
//
//	make uart-rx-test runs this bench against both mutants; each must fail.

`timescale 1ns/1ps

module tb_ns16550_loop;
	reg			clk = 1'b0;
	reg			rst = 1'b1;
	reg			re = 1'b0, we = 1'b0;
	reg [2:0]	raddr = 3'd0;
	reg [7:0]	wstrb = 8'h00;
	reg [63:0]	wdata = 64'h0;
	wire [63:0]	rdata;
	wire		txd, rts, intr, thr_ready;

	always #5 clk = !clk;

	karu_ns16550 #(.CPU_CLK_HZ(75000000)) dut (
		.clk(clk), .rst(rst), .re(re), .raddr(raddr), .we(we), .wstrb(wstrb),
		.wdata(wdata), .rdata(rdata), .uart_txd(txd), .uart_rxd(txd),
		.uart_rts(rts), .uart_cts(1'b1), .intr(intr), .thr_ready(thr_ready));

	localparam [7:0] LSR_DR = 8'h01, LSR_THRE = 8'h20;

	integer		seed = 7;
	integer		checks = 0;
	reg [7:0]	sb [0:2047];
	integer		sb_wr = 0, sb_rd = 0;

	task check(input cond, input [8*64-1:0] what);
		begin
			checks = checks + 1;
			if (!cond)
				$fatal(1, "FAIL ns16550 loop check %0d: %0s", checks, what);
		end
	endtask

	//	one accepted read beat of register a
	task rd(input [2:0] a, output [7:0] v);
		begin
			@(negedge clk); re = 1'b1; raddr = a;
			#1 v = rdata[8*a +: 8];
			@(negedge clk); re = 1'b0;
		end
	endtask
	//	one accepted byte write of register a
	task wr(input [2:0] a, input [7:0] v);
		begin
			@(negedge clk); we = 1'b1; wstrb = 8'h01 << a; wdata = {56'b0, v} << (8*a);
			@(negedge clk); we = 1'b0; wstrb = 8'h00;
		end
	endtask

	//	8250-style receive: take bytes while LSR.DR is set
	task automatic rx_chars(inout [7:0] lsr);
		reg [7:0] c;
		integer n;
		begin
			n = 0;
			while (lsr & LSR_DR) begin
				rd(3'd0, c);
				check(sb_rd < sb_wr, "byte read twice, or a byte that was never sent");
				check(c == sb[sb_rd], "byte received unchanged and in order");
				sb_rd = sb_rd + 1;
				n = n + 1;
				check(n <= 2, "LSR.DR cleared by the RBR read");
				rd(3'd5, lsr);
			end
		end
	endtask

	//	wait for LSR bit(s) without touching RBR
	task automatic wait_lsr(input [7:0] mask, input [8*40-1:0] what);
		reg [7:0] s;
		integer k;
		begin
			k = 0; rd(3'd5, s);
			while ((s & mask) != mask && k < 20000) begin
				repeat (8) @(posedge clk); rd(3'd5, s); k = k + 1;
			end
			check((s & mask) == mask, what);
		end
	endtask

	//	Byte a is ready and unread; byte b is on the line. One RBR read is
	//	placed `offset` cycles from the edge on which b completes (the
	//	receiver's stop-bit step).
	task automatic collide(input integer offset, input [7:0] a, input [7:0] b);
		reg [7:0] c, s;
		begin
			wait_lsr(LSR_THRE, "transmitter ready for the first byte");
			wr(3'd0, a);
			wait_lsr(LSR_DR | LSR_THRE, "first byte ready, transmitter free");
			wr(3'd0, b);
			@(negedge clk);
			while (!(dut.u_rx.idx == 4'd8 && dut.u_rx.rxd_s &&
					 dut.u_rx.tmr == (offset < 0 ? 14'd1 : 14'd0))) @(negedge clk);
			if (offset > 0) @(negedge clk);
			re = 1'b1; raddr = 3'd0;				//	the accepted RBR read
			#1 c = rdata[7:0];
			@(negedge clk); re = 1'b0;
			repeat (3) @(negedge clk);
			rd(3'd5, s);
			if (offset <= 0) begin
				//	before or on the completion edge: the old byte is read
				//	and the new one is a separate, still unread byte
				check(c == a, "read on or before the completion edge returns the old byte");
				check((s & LSR_DR) != 0, "byte completing on the read edge stays ready");
				rd(3'd0, c);
				check(c == b, "the new byte is delivered next");
			end else begin
				//	after it: the unread old byte was overwritten (no FIFO)
				check(c == b, "read after the completion edge returns the new byte");
			end
			repeat (3) @(negedge clk);
			rd(3'd5, s);
			check((s & LSR_DR) == 0, "nothing left ready after the collision case");
		end
	endtask

	integer		n, t;
	reg [7:0]	lsr, v;

	initial begin
		repeat (4) @(posedge clk); rst = 1'b0;
		wr(3'd1, 8'h01);						//	IER: received-data interrupt
		rd(3'd5, lsr);
		check((lsr & LSR_THRE) != 0 && (lsr & LSR_DR) == 0, "idle: THRE set, DR clear");
		check(!intr, "idle: no interrupt");

		//	---- spaced bytes: each is read with the line idle ----
		for (n = 0; n < 400; n = n + 1) begin
			//	the transmitter is still in its stop bit when the receiver
			//	reports the byte: wait for THRE as a driver does
			t = 0; rd(3'd5, lsr);
			while (!(lsr & LSR_THRE) && t < 20000) begin
				repeat (8) @(posedge clk); rd(3'd5, lsr); t = t + 1;
			end
			check((lsr & LSR_THRE) != 0 && (lsr & LSR_DR) == 0, "transmitter ready, receiver empty");
			v = $urandom(seed);
			sb[sb_wr] = v; sb_wr = sb_wr + 1;
			wr(3'd0, v);
			t = 0; rd(3'd5, lsr);
			while (!(lsr & LSR_DR) && t < 20000) begin
				repeat (1 + $urandom(seed) % 64) @(posedge clk);
				rd(3'd5, lsr); t = t + 1;
			end
			check((lsr & LSR_DR) != 0, "looped byte arrived");
			check(intr, "received-data interrupt asserted");
			repeat ($urandom(seed) % 2000) @(posedge clk);	//	interrupt latency
			rx_chars(lsr);
			check(!intr || (lsr & LSR_THRE) == 0, "interrupt released after the read");
		end
		check(sb_rd == sb_wr, "spaced bytes: each delivered exactly once");

		//	---- streaming: reads land while the next byte is on the line ----
		wr(3'd1, 8'h00);
		for (n = 0; n < 300; ) begin
			rd(3'd5, lsr);
			rx_chars(lsr);
			if (lsr & LSR_THRE) begin
				v = $urandom(seed);
				sb[sb_wr] = v; sb_wr = sb_wr + 1;
				wr(3'd0, v);
				n = n + 1;
			end
			repeat ($urandom(seed) % 300) @(posedge clk);
		end
		t = 0;
		while (sb_rd != sb_wr && t < 20000) begin
			rd(3'd5, lsr); rx_chars(lsr); repeat (16) @(posedge clk); t = t + 1;
		end
		check(sb_rd == sb_wr, "streamed bytes: each delivered exactly once");
		repeat (8000) @(posedge clk);

		//	---- RBR read around the completion edge of the next byte ----
		for (n = 0; n < 6; n = n + 1) begin
			collide(-1, 8'h11 + n[7:0], 8'h22 + n[7:0]);
			collide( 0, 8'h33 + n[7:0], 8'h44 + n[7:0]);
			collide( 1, 8'h55 + n[7:0], 8'h66 + n[7:0]);
		end
		rd(3'd5, lsr);
		check((lsr & LSR_DR) == 0, "no byte left over");

		$display("ns16550 loopback: PASS (%0d checks, %0d bytes)", checks, sb_wr);
		$finish;
	end

	initial begin
		#2000000000;
		$fatal(1, "FAIL ns16550 loop: global timeout");
	end
endmodule
