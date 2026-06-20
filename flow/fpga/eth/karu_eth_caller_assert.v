//	karu_eth_caller_assert.v
//	Checker for the *caller side* of the karu_eth bridge -- the linux_tb dmem
//	front-end that drives the eth window: the AR/AW busy-gate and the multi-cycle
//	read/write handshake latches (eth_rd_ready, eth_wr_inflight). Complements
//	flow/fpga/eth/karu_eth_assert.v (which watches the bridge FSM itself): this one
//	watches that the *master* obeys the bridge's single-in-flight contract and
//	tracks completion correctly. Same passive model + plusargs as the others.
//
//	eth_rd_req / eth_wr_req are the one-cycle AR/AW-accept pulses for the eth
//	window (already factored in linux_tb); they are exactly what is forwarded to
//	the bridge as rd_req / wr_req.

module karu_eth_caller_assert #(
	parameter integer STOP_ON_FAIL = 1
) (
	input  wire	clk,
	input  wire	rst,

	input  wire	eth_busy,
	input  wire	eth_rd_req,
	input  wire	eth_wr_req,
	input  wire	eth_rd_done,
	input  wire	eth_wr_done,
	input  wire	eth_rd_ready,		//	read data latched, awaiting CPU consume
	input  wire	eth_wr_inflight		//	write handed to bridge, B deferred
);
	integer	fails   = 0;
	reg		enabled = 1'b1;
	reg		do_stop = 1'b1;
	reg [63:0] c_cyc  = 64'b0;

	initial begin
		if      ($test$plusargs("no_assert_stop")) do_stop = 1'b0;
		else if ($test$plusargs("no_assert"))      enabled = 1'b0;
	end

	//	one-cycle-delayed copies for the edge / handshake checks
	reg	rd_ready_q, wr_inflight_q, rd_done_q, wr_req_q, wr_done_q;
	always @(posedge clk) begin
		rd_ready_q    <= eth_rd_ready;
		wr_inflight_q <= eth_wr_inflight;
		rd_done_q     <= eth_rd_done;
		wr_req_q      <= eth_wr_req;
		wr_done_q     <= eth_wr_done;
	end

	`define CCHK(cond, tag) \
		if (enabled && !rst && !(cond)) begin \
			fails = fails + 1; \
			$display("[ETHC-ASSERT] FAIL cyc=%0d t=%0t: %s", c_cyc, $time, tag); \
			if (do_stop && STOP_ON_FAIL) begin \
				$display("[ETHC-ASSERT] %0d failure(s); stopping.", fails); \
				$finish; \
			end \
		end

	always @(posedge clk) begin
		c_cyc <= c_cyc + 64'b1;

		//	================= busy-gate contract =================
		//	karu_eth drops a *_req asserted while busy, so the dmem AR/AW accept
		//	(eth_rd_req / eth_wr_req) must never fire while the bridge is busy.
		//	(This is the linux_tb-side view of the AR/AW !eth_busy gate.)
		`CCHK(!(eth_rd_req && eth_busy), "CALL1 eth read accepted while bridge busy")
		`CCHK(!(eth_wr_req && eth_busy), "CALL2 eth write accepted while bridge busy")
		//	one transaction at a time: a read and a write are never launched into
		//	the bridge in the same cycle.
		`CCHK(!(eth_rd_req && eth_wr_req), "CALL3 eth read and write accepted same cycle")

		//	================= completion-latch handshake =================
		//	eth_rd_ready (read data available to the CPU) only rises the cycle
		//	after the bridge signalled rd_done.
		`CCHK(!(eth_rd_ready && !rd_ready_q) || rd_done_q,
			  "CALL4 eth_rd_ready rose without a preceding rd_done")
		//	eth_wr_inflight rises only on a write accept, and falls only on the
		//	bridge's wr_done.
		`CCHK(!(eth_wr_inflight && !wr_inflight_q) || wr_req_q,
			  "CALL5 eth_wr_inflight rose without a write accept")
		`CCHK(!(!eth_wr_inflight && wr_inflight_q) || wr_done_q,
			  "CALL6 eth_wr_inflight fell without a wr_done")
	end

	`undef CCHK
endmodule
