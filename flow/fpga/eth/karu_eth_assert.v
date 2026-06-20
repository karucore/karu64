//	karu_eth_assert.v
//	State-transition / signalling checker for the karu_eth <-> LiteEth wishbone
//	bridge (flow/fpga/eth/karu_eth.v). Passive, same model as rtl/karu_assert.v: it
//	observes the bridge FSM + its wishbone master + the req/busy handshake and
//	flags any violation of the contracts the bridge is built on. No data-path
//	semantics (it never checks "the frame round-trips" -- that's make eth-sim).
//
//	Two of these would have fired on bugs hit during bring-up:
//	  - ETH3 (no *_req while busy) is exactly the caller contract the linux_tb
//	    AR/AW busy-gate enforces; a master that violated it (dropping a request)
//	    trips here at the offending cycle instead of hanging the AXI side.
//	  - the per-beat gap states (S_R0G/S_W0G) are mandatory between wishbone
//	    transfers (LiteX slaves register ack); ETH-TRANS forbids S_R0->S_R1 /
//	    S_W0->S_W1 directly, so a regression that re-introduced the stale-ack
//	    back-to-back bug is caught structurally.
//
//	Sim path: instantiated by flow/fpga/linux_tb.v with hierarchical refs into the
//	karu_eth instance (iverilog 14 has no `bind`). Formal path: define
//	KARU_ETH_ASSERT_BIND for the `bind karu_eth ...` at the bottom, and
//	KARU_ETH_ASSERT_SVA for the `assert property` form. Disable at runtime with
//	the shared +no_assert / +no_assert_stop plusargs.

module karu_eth_assert #(
	//	One bridge transaction (a 64-bit read = 2 wishbone beats, a write = 1-2)
	//	is ~10-20 cycles against the LiteX CSR/SRAM slaves. This deadline catches
	//	a slave that never acks (busy stuck) -- wide margin over the real worst.
	parameter integer ETH_STALL_LIMIT = 4000,
	parameter integer STOP_ON_FAIL    = 1
) (
	input  wire			clk,
	input  wire			rst,

	//	---- bridge FSM + req/done handshake ----
	input  wire [2:0]	st,			//	karu_eth.st
	input  wire			rd_req,
	input  wire			rd_done,
	input  wire			wr_req,
	input  wire			wr_done,
	input  wire			busy,

	//	---- wishbone master ----
	input  wire			wb_cyc,
	input  wire			wb_stb,
	input  wire			wb_we,
	input  wire			wb_ack,
	input  wire [3:0]	wb_sel,
	input  wire [3:0]	sel_lo,
	input  wire [3:0]	sel_hi
);
	//	FSM encoding -- MUST match karu_eth.v.
	localparam [2:0] S_IDLE = 3'd0,
					 S_R0   = 3'd1,
					 S_R0G  = 3'd2,
					 S_R1   = 3'd3,
					 S_W0   = 3'd4,
					 S_W0G  = 3'd5,
					 S_W1   = 3'd6;

	integer	fails   = 0;
	reg		enabled = 1'b1;
	reg		do_stop = 1'b1;
	reg [63:0] e_cyc = 64'b0;

	//	+no_assert       -> disable the checker entirely
	//	+no_assert_stop  -> report violations but keep simulating
	//	NB: $test$plusargs matches by PREFIX, so "+no_assert_stop" also satisfies
	//	$test$plusargs("no_assert"); detect the _stop form first so it doesn't get
	//	swallowed into a full disable.
	initial begin
		if      ($test$plusargs("no_assert_stop")) do_stop = 1'b0;
		else if ($test$plusargs("no_assert"))      enabled = 1'b0;
	end

	//	---- one-cycle-delayed copies for transition / done-pulse checks ----
	reg [2:0]	st_q;
	reg			wb_ack_q;
	reg [3:0]	sel_hi_q;
	reg			busy_q;
	always @(posedge clk) begin
		st_q     <= st;
		wb_ack_q <= wb_ack;
		sel_hi_q <= sel_hi;
		busy_q   <= busy;
	end

	//	---- hang watchdog: a transaction must complete (slave acks) ----
	reg [31:0]	eth_cnt;
	reg			hang_seen = 1'b0;	//	one-shot: fire once per stuck episode
	always @(posedge clk) begin
		if (rst) eth_cnt <= 0;
		else     eth_cnt <= (busy && !(rd_done || wr_done)) ? eth_cnt + 1 : 0;
	end

	//	Report a hang. Honours +no_assert_stop (do_stop) like ECHK: with it set,
	//	report and keep going (a one-shot latch below stops per-cycle spam);
	//	otherwise stop -- a hung bridge is not worth simulating through.
	task e_hang;
		input [8*48-1:0] tag;
		begin
			if (enabled && !rst) begin
				fails = fails + 1;
				$display("[ETH-ASSERT] HANG cyc=%0d t=%0t st=%0d: %0s",
					e_cyc, $time, st, tag);
				$display("[ETH-ASSERT]   busy=%b wb(cyc=%b stb=%b we=%b ack=%b)",
					busy, wb_cyc, wb_stb, wb_we, wb_ack);
				if (do_stop && STOP_ON_FAIL) begin
					$display("[ETH-ASSERT] %0d failure(s); stopping.", fails);
					$finish;
				end
			end
		end
	endtask

	`define ECHK(cond, tag) \
		if (enabled && !rst && !(cond)) begin \
			fails = fails + 1; \
			$display("[ETH-ASSERT] FAIL cyc=%0d t=%0t st=%0d->%0d: %s", \
				e_cyc, $time, st_q, st, tag); \
			if (do_stop && STOP_ON_FAIL) begin \
				$display("[ETH-ASSERT] %0d failure(s); stopping.", fails); \
				$finish; \
			end \
		end

	always @(posedge clk) begin
		e_cyc <= e_cyc + 64'b1;

		//	================= state validity / busy =================
		`ECHK(st <= S_W1, "ETH1 FSM in an undefined state")
		`ECHK(busy == (st != S_IDLE), "ETH2 busy != (st != IDLE)")

		//	================= req/busy handshake contract =================
		//	karu_eth latches a request only in S_IDLE and silently ignores a
		//	*_req asserted while busy -> the caller MUST hold off until !busy.
		`ECHK(!(busy && (rd_req || wr_req)), "ETH3 *_req asserted while busy (dropped request)")
		`ECHK(!(rd_req && wr_req), "ETH4 rd_req and wr_req in the same cycle")

		//	================= wishbone master well-formedness =================
		//	cyc is held across the whole transaction (incl. gap states); stb is
		//	pulsed only during the four transfer states.
		`ECHK(wb_cyc == (st != S_IDLE), "ETH5 wb_cyc != (transaction in flight)")
		`ECHK(wb_stb == (st == S_R0 || st == S_R1 || st == S_W0 || st == S_W1),
			  "ETH6 wb_stb asserted outside a transfer state")
		//	we matches read vs write transfer.
		`ECHK(wb_we == (st == S_W0 || st == S_W1), "ETH7 wb_we != (write transfer)")
		//	read beats use all four byte lanes; write beats drive the latched lane.
		`ECHK(!((st == S_R0 || st == S_R1) && wb_sel != 4'hf), "ETH8 read wb_sel != 0xf")
		`ECHK(!(st == S_W0 && wb_sel != sel_lo), "ETH9 S_W0 wb_sel != sel_lo")
		`ECHK(!(st == S_W1 && wb_sel != sel_hi), "ETH10 S_W1 wb_sel != sel_hi")
		//	a write transfer state is only entered with a non-zero lane.
		`ECHK(!(st == S_W0 && sel_lo == 4'b0), "ETH11 S_W0 with empty sel_lo")
		`ECHK(!(st == S_W1 && sel_hi == 4'b0), "ETH12 S_W1 with empty sel_hi")

		//	================= state-transition legality =================
		//	The only legal successors of each state. Notably S_R0 -> S_R1 and
		//	S_W0 -> S_W1 are FORBIDDEN: a gap state (stb low, wait for ack to
		//	clear) must sit between beats, else a registered-ack slave's stale
		//	ack/data is captured (the back-to-back bug fixed during bring-up).
		case (st_q)
			S_IDLE: `ECHK(st==S_IDLE || st==S_R0 || st==S_W0 || st==S_W1,
						  "ETH-TRANS illegal IDLE successor")
			S_R0:   `ECHK(st==S_R0  || st==S_R0G, "ETH-TRANS R0 must go to R0G (no direct R1)")
			S_R0G:  `ECHK(st==S_R0G || st==S_R1,  "ETH-TRANS illegal R0G successor")
			S_R1:   `ECHK(st==S_R1  || st==S_IDLE, "ETH-TRANS illegal R1 successor")
			S_W0:   `ECHK(st==S_W0  || st==S_W0G || st==S_IDLE,
						  "ETH-TRANS W0 must go to W0G/IDLE (no direct W1)")
			S_W0G:  `ECHK(st==S_W0G || st==S_W1,  "ETH-TRANS illegal W0G successor")
			S_W1:   `ECHK(st==S_W1  || st==S_IDLE, "ETH-TRANS illegal W1 successor")
			default:`ECHK(1'b0, "ETH-TRANS from an undefined state")
		endcase

		//	================= done-pulse well-formedness =================
		//	rd_done only the cycle after S_R1 captured (ack); wr_done only after
		//	the final write beat (S_W0 with no high lane, or S_W1) captured.
		`ECHK(!rd_done || (st_q == S_R1 && wb_ack_q),
			  "ETH13 rd_done without a completing S_R1 ack")
		`ECHK(!wr_done || ((st_q == S_W0 && wb_ack_q && sel_hi_q == 4'b0) ||
						   (st_q == S_W1 && wb_ack_q)),
			  "ETH14 wr_done without a completing write ack")
		`ECHK(!(rd_done && wr_done), "ETH15 rd_done and wr_done in the same cycle")

		//	================= hang guard =================
		//	Fire once per stuck episode (re-arms when busy clears) so that under
		//	+no_assert_stop (report-and-continue) it doesn't spam every cycle.
		if (!busy)
			hang_seen <= 1'b0;
		else if (eth_cnt > ETH_STALL_LIMIT && !hang_seen) begin
			hang_seen <= 1'b1;
			e_hang("bridge busy > ETH_STALL_LIMIT (wishbone slave never acked?)");
		end
	end

	wire _unused = &{1'b0, busy_q, wb_cyc};

	`undef ECHK

`ifdef KARU_ETH_ASSERT_SVA
	default clocking @(posedge clk); endclocking
	default disable iff (rst);

	a_eth1_state:   assert property (st <= S_W1);
	a_eth2_busy:    assert property (busy == (st != S_IDLE));
	a_eth3_req:     assert property (busy |-> !(rd_req || wr_req));
	a_eth4_req2:    assert property (!(rd_req && wr_req));
	a_eth5_cyc:     assert property (wb_cyc == (st != S_IDLE));
	a_eth6_stb:     assert property (wb_stb == (st==S_R0 || st==S_R1 || st==S_W0 || st==S_W1));
	a_eth7_we:      assert property (wb_we == (st==S_W0 || st==S_W1));
	a_eth8_rsel:    assert property ((st==S_R0 || st==S_R1) |-> wb_sel == 4'hf);
	a_eth9_wsel0:   assert property (st==S_W0 |-> wb_sel == sel_lo);
	a_eth10_wsel1:  assert property (st==S_W1 |-> wb_sel == sel_hi);
	//	gap states are mandatory between beats (stale-ack guard).
	a_eth_trans_r0: assert property (st==S_R0 |=> (st==S_R0 || st==S_R0G));
	a_eth_trans_w0: assert property (st==S_W0 |=> (st==S_W0 || st==S_W0G || st==S_IDLE));
	a_eth13_rdone:  assert property (rd_done |-> ($past(st)==S_R1 && $past(wb_ack)));
	a_eth15_dexcl:  assert property (!(rd_done && wr_done));
	//	liveness: a started transaction eventually completes.
	a_eth_live:     assert property ((!busy && (rd_req || wr_req)) |-> s_eventually (rd_done || wr_done));
`endif

endmodule

//	---------------------------------------------------------------------
//	Formal-flow attachment (bind to the bridge). iverilog has no `bind`, so the
//	sim path instantiates this from flow/fpga/linux_tb.v with hierarchical ports.
//	---------------------------------------------------------------------
`ifdef KARU_ETH_ASSERT_BIND
bind karu_eth karu_eth_assert u_karu_eth_assert (
	.clk(clk), .rst(rst),
	.st(st), .rd_req(rd_req), .rd_done(rd_done),
	.wr_req(wr_req), .wr_done(wr_done), .busy(busy),
	.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_ack(wb_ack),
	.wb_sel(wb_sel), .sel_lo(sel_lo), .sel_hi(sel_hi)
);
`endif
