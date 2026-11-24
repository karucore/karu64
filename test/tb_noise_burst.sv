//  tb_noise_burst.sv -- unit test of the FPGA entropy source with its burst
//  capture (make noise-burst-test): flow/fpga/karu_entropy_src.v, which is
//  karu_rosc_rng (behavioural model), rtl/karu_entropy.v,
//  flow/fpga/karu_noise_burst.v, flow/fpga/karu_rosc_meter.v and the soft
//  straps (flow/fpga/karu_softstrap.v).
//
//  The bench records every symbol the noise source emits, with its clock
//  cycle, so the expectations are exact: a burst is a stretch of that
//  record, and the sampling period is the distance between its entries. A
//  second instance, `quiet`, gets the same CSR accesses and no register
//  access at all; outside test mode the two must agree in every cycle. A
//  third, `alt`, built with LANE = 2, KSHIFT = 1 and RING_MASK = 110101,
//  gets the same CSR accesses; what it reports of its straps is checked.
//  test/noise_burst_mutants.py runs this bench against one-mechanism
//  mutants, built without the modules' own assertions.
//
//  Stimulus changes on the falling clock edge. A value read just after it is
//  what an access in that cycle returns; the rising edge that follows acts.
//  SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_noise_burst;
    localparam int DIV   = 8;                   //  the build's period
    localparam int LOG2W = 3;                   //  8 words: 128 symbols per burst
    localparam int WORDS = 1 << LOG2W, N = 16 * WORDS;
    localparam [2:0] R_CTRL = 3'd0, R_PERIOD = 3'd1, R_INDEX = 3'd2, R_DATA = 3'd3;
    localparam [2:0] M_CTRL = 3'd5, M_DATA0 = 3'd6, M_DATA1 = 3'd7;     //  the meter (karu_rosc_meter.v)
    localparam [63:0] NT = 64'h8000_0000, LOCK = 64'h8000_0000_0000_0000;
    localparam [1:0] BIST = 2'd0, ES16 = 2'd2;

    logic clk = 0, rst = 1, en = 1;
    always #5 clk = ~clk;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    //  CSR sideband, as the core drives it: one access per cycle
    logic        csr_fire = 0, csr_we = 0;
    logic [1:0]  csr_sel = 0;
    logic [63:0] csr_wdata = 0;
    //  register port, as the SoC's system-control block drives it
    logic        reg_re = 0, reg_we = 0;
    logic [2:0]  reg_raddr = 0, reg_waddr = 0;
    logic [63:0] reg_wdata = 0;
    wire  [63:0] reg_rdata, csr_rdata, q_csr_rdata, a_reg_rdata, a_csr_rdata;
    //  what seed reports, of the bench's two entropy sources
    wire  [1:0]  opst = dut.entropy.seed_opst, q_opst = quiet.entropy.seed_opst;
    wire  [15:0] data = dut.entropy.seed_data, q_data = quiet.entropy.seed_data;

    karu_entropy_src #(.SIM(1), .SAMPLE_DIV(DIV), .INTERVAL_RESET(16'd0), .BURST_LOG2_WORDS(LOG2W)) dut (
        .clk(clk), .rst(rst), .en_i(en),
        .csr_fire_i(csr_fire), .csr_sel_i(csr_sel), .csr_we_i(csr_we), .csr_wdata_i(csr_wdata), .csr_rdata_o(csr_rdata),
        .reg_re_i(reg_re), .reg_raddr_i(reg_raddr), .reg_rdata_o(reg_rdata),
        .reg_we_i(reg_we), .reg_waddr_i(reg_waddr), .reg_wdata_i(reg_wdata));
    karu_entropy_src #(.SIM(1), .SAMPLE_DIV(DIV), .INTERVAL_RESET(16'd0), .BURST_LOG2_WORDS(LOG2W)) quiet (
        .clk(clk), .rst(rst), .en_i(en),
        .csr_fire_i(csr_fire), .csr_sel_i(csr_sel), .csr_we_i(csr_we), .csr_wdata_i(csr_wdata), .csr_rdata_o(q_csr_rdata),
        .reg_re_i(1'b0), .reg_raddr_i(3'd0), .reg_rdata_o(),
        .reg_we_i(1'b0), .reg_waddr_i(3'd0), .reg_wdata_i(64'b0));
    //  a source built with other straps, on the same accesses as dut: only
    //  what it reports of its straps is looked at
    karu_entropy_src #(.SIM(1), .SAMPLE_DIV(DIV), .INTERVAL_RESET(16'd0), .BURST_LOG2_WORDS(LOG2W),
                       .LANE(2'd2), .KSHIFT(2'd1), .RING_MASK(6'b110101)) alt (
        .clk(clk), .rst(rst), .en_i(en),
        .csr_fire_i(csr_fire), .csr_sel_i(csr_sel), .csr_we_i(csr_we), .csr_wdata_i(csr_wdata), .csr_rdata_o(a_csr_rdata),
        .reg_re_i(reg_re), .reg_raddr_i(reg_raddr), .reg_rdata_o(a_reg_rdata),
        .reg_we_i(1'b0), .reg_waddr_i(3'd0), .reg_wdata_i(64'b0));

    //  ---- checking ----
    int checks = 0;
    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) begin
            $display("FAIL noise burst check %0d: %s (time %0t)", checks, what, $time);
            $fatal(1);
        end
    endtask

    //  ---- the record of the source: every symbol and its cycle ----
    logic [3:0] src_b [$];
    logic [3:0] cnt_b [$];                      //  ring 0's count of the same clock edge, low four bits
    logic [3:0] ref_b [$];                      //  the reference rings' bits of that edge above those of lanes 0 and 1
    longint     src_c [$];
    logic [3:0] osc_h [0:3];                    //  the ring outputs of the last cycles
    bit         track = 0;                      //  compare dut and quiet in every cycle
    int         mismatches = 0, late = 0;
    always @(negedge clk) begin
        if (!rst && dut.rng_val) begin
            src_b.push_back(dut.rng_b);
            cnt_b.push_back(dut.cnt[3:0]);
            ref_b.push_back({dut.noise.ref_b_o, dut.rng_b[1:0]});
            src_c.push_back(cyc);
            //  a symbol is the ring outputs of three clock edges earlier:
            //  sampling flop, synchroniser flop, output register
            if (dut.rng_b !== osc_h[2]) late++;
        end
        osc_h[3] <= osc_h[2]; osc_h[2] <= osc_h[1]; osc_h[1] <= osc_h[0]; osc_h[0] <= dut.noise.osc;
        if (track && !rst && {dut.rng_val, dut.rng_b, opst, data, csr_rdata} !== {quiet.rng_val, quiet.rng_b, q_opst, q_data, q_csr_rdata})
            mismatches++;
    end

    //  ---- accesses ----
    logic [63:0] got, got_a;                    //  got_a: the same access as the other source answers it
    task automatic csr(input [1:0] sel, input bit we, input [63:0] v);
        @(negedge clk); csr_fire = 1; csr_sel = sel; csr_we = we; csr_wdata = v;
        #1; got = csr_rdata; got_a = a_csr_rdata;
        @(negedge clk); csr_fire = 0; csr_we = 0;
    endtask
    task automatic regw(input [2:0] a, input [63:0] v);
        @(negedge clk); reg_we = 1; reg_waddr = a; reg_wdata = v;
        @(negedge clk); reg_we = 0;
    endtask
    task automatic regr(input [2:0] a);         //  a read that is taken
        @(negedge clk); reg_re = 1; reg_raddr = a;
        #1; got = reg_rdata;
        @(negedge clk); reg_re = 0;
    endtask
    task automatic look(input [2:0] a);         //  the value, without taking a read
        @(negedge clk); reg_raddr = a; #1; got = reg_rdata; got_a = a_reg_rdata;
    endtask
    //  the meter's next record: both words, and the symbol of its strobe
    logic [63:0] rec0, rec1;
    logic [3:0]  rec_sym;
    task automatic meter_record(input string what);
        int guard = 0;
        look(M_DATA0);
        while (!got[63]) begin
            check(guard++ < 64 * DIV, {what, ": a record comes"});
            look(M_DATA0);
        end
        rec0 = got; rec_sym = src_b[src_b.size() - 1];
        regr(M_DATA1); rec1 = got;
    endtask

    localparam [63:0] ID = {32'h4b4e_4231, 16'd0, 8'(LOG2W + 4), 8'd0};
    function automatic [63:0] status(input bit test, input bit en_b, input bit lock, input bit allow, input bit done, input bit busy,
                                     input bit aborted = 0);
        return ID | {57'b0, aborted, test, en_b, lock, allow, done, busy};
    endfunction

    //  the distance between the last `count` symbols of the record
    function automatic bit spaced(input int count, input int period);
        int n = src_c.size();
        if (n < count + 1) return 0;
        for (int i = n - count; i < n; i++) if (src_c[i] - src_c[i - 1] != longint'(period)) return 0;
        return 1;
    endfunction
    task automatic wait_symbols(input int count);
        int target = src_b.size() + count;
        while (src_b.size() < target) @(negedge clk);
    endtask

    //  ---- a capture: start, wait, read, compare with the record ----
    int first;
    logic [63:0] words [0:WORDS-1];
    task automatic start_capture();
        @(negedge clk); reg_we = 1; reg_waddr = R_CTRL; reg_wdata = 64'd1;
        #1; first = src_b.size();               //  symbols up to this cycle are before the capture
        @(negedge clk); reg_we = 0;
    endtask
    task automatic wait_done(input int period);
        int guard = 0;
        look(R_CTRL);
        while (!got[1]) begin
            check(got[0], "capturing until done");
            check(guard++ < (N + 4) * period + 16, "the capture ends after its symbols");
            look(R_CTRL);
        end
        check(!got[0] && got[31:16] == 16'd0, "done: not capturing, word count back at zero");
    endtask
    function automatic [63:0] expected_word(input int w);
        logic [63:0] v = 0;
        for (int s = 0; s < 16; s++) v[4 * s +: 4] = src_b[first + 16 * w + s];
        return v;
    endfunction
    task automatic read_all(input string what);
        regw(R_INDEX, 64'd0);
        for (int w = 0; w < WORDS; w++) begin
            regr(R_DATA);
            words[w] = got;
            check(got == expected_word(w), $sformatf("%s: word %0d is %016x, the source gave %016x", what, w, got, expected_word(w)));
        end
    endtask
    task automatic burst_at(input int period, input string what);
        int at;
        regw(R_PERIOD, 64'(period - 1));
        look(R_PERIOD);
        check(got == 64'(period - 1), {what, ": period register reads back"});
        wait_symbols(3);
        check(spaced(2, period), $sformatf("%s: the source's symbols are %0d clocks apart", what, period));
        start_capture();
        wait_done(period);
        check(src_b.size() >= first + N, {what, ": the source emitted a burst's worth of symbols"});
        for (int i = first + 1; i < first + N; i++)
            check(src_c[i] - src_c[i - 1] == longint'(period), $sformatf("%s: consecutive symbols of the burst %0d clocks apart", what, period));
        at = src_b.size();
        check(at <= first + N + 4 / period + 1, {what, ": done is reported within four clocks of the last symbol"});
        read_all(what);
    endtask

    task automatic enter_test();
        csr(2'd1, 1, NT);
        look(R_CTRL);
        check(got == status(1, 1, 0, 1, 0, 0), "in test mode: capturing is allowed, nothing captured");
    endtask
    //  Leaving test mode. The write is in cycle exit_cyc; a symbol recorded
    //  in the cycle after it was still sampled in test mode, later ones were not.
    longint exit_cyc;
    task automatic leave_test();
        @(negedge clk); csr_fire = 1; csr_sel = 2'd1; csr_we = 1; csr_wdata = 64'd0;
        exit_cyc = cyc;
        @(negedge clk); csr_fire = 0; csr_we = 0;
    endtask
    //  After `count` more symbols: every symbol sampled outside test mode
    //  comes at least the build's period after the one before it, the first
    //  one included, and from the second on exactly that period.
    task automatic check_exit(input int count, input string what);
        int seen = 0;
        wait_symbols(count);
        for (int j = 1; j < src_c.size(); j++) if (src_c[j] >= exit_cyc + 2) begin
            check(src_c[j] - src_c[j - 1] >= longint'(DIV), {what, ": no symbol is sampled early once test mode has ended"});
            if (seen > 0) check(src_c[j] - src_c[j - 1] == longint'(DIV), {what, ": the source is back at the build's period"});
            seen++;
        end
        check(seen >= count - 1, {what, ": symbols after test mode were looked at"});
    endtask
    task automatic expect_idle(input string what, input bit lock);
        look(R_CTRL);
        check(got == status(0, 1, lock, 0, 0, 0), {what, ": status shows no test mode, nothing held"});
        look(R_PERIOD); check(got == 64'(DIV - 1), {what, ": period register at the build's value"});
        look(R_INDEX);  check(got == 64'd0, {what, ": index at zero"});
        look(R_DATA);   check(got == 64'd0, {what, ": data reads zero"});
    endtask

    int i, n0;
    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        track = 1;

        //  ================= outside test mode: nothing to see, nothing to set =================
        expect_idle("after reset", 0);
        regw(R_PERIOD, 64'd0);
        regw(R_CTRL, 64'd1);
        regw(R_INDEX, 64'd5);
        expect_idle("register writes outside test mode", 0);
        regr(R_DATA);
        check(got == 64'd0, "a data read outside test mode returns zero");
        wait_symbols(6);
        check(spaced(5, DIV), "outside test mode the source runs at the build's period");
        //  run through the start-up test: seed delivers, as it does without this block
        while (opst != ES16) @(negedge clk);
        for (i = 0; i < 20; i++) begin regw(R_PERIOD, 64'(i)); regw(R_CTRL, 64'd1); regr(R_DATA); end
        wait_symbols(40);
        check(mismatches == 0, "outside test mode, register accesses change nothing the entropy block or the core sees");
        check(late == 0, "every symbol is the ring outputs of three clocks before");
        track = 0;

        //  ================= test mode: the period =================
        enter_test();
        check(opst == BIST, "test mode: seed is in BIST");
        look(R_PERIOD); check(got == 64'(DIV - 1), "test mode starts at the build's period");
        regw(R_PERIOD, 64'd2);
        n0 = src_b.size();
        repeat (4) @(negedge clk);
        check(src_b.size() > n0, "a shorter period takes effect within that period");
        wait_symbols(4);
        check(spaced(3, 3), "period 3");
        regw(R_PERIOD, 64'd0);
        wait_symbols(8);
        check(spaced(7, 1), "period 1: a symbol in every clock cycle");
        //  mnoise sees the source at this period
        csr(2'd1, 1, NT | 64'h2000_0000);
        csr(2'd1, 1, NT);
        check(got[31:29] == 3'b111, "period 1: a GetNoise poll every other cycle has a symbol and has lost one");
        //  a period write ends a run of mnoise symbols: the spacing changes
        regw(R_PERIOD, 64'd7);                  //  8 clocks per symbol: every one can be taken
        csr(2'd1, 1, NT | 64'h2000_0000);       //  a new run
        for (i = 0; i < 3; i++) begin
            do csr(2'd1, 1, NT); while (!got[30]);
            check(!got[29], "period 8: consecutive symbols of a run, none lost");
        end
        regw(R_PERIOD, 64'd3);
        do csr(2'd1, 1, NT); while (!got[30]);
        check(got[29], "the first symbol after a period write carries the loss flag: the run has ended");
        csr(2'd1, 1, NT | 64'h2000_0000);
        do csr(2'd1, 1, NT); while (!got[30]);
        check(!got[29], "a clearing write after it starts a new run at the new period");
        check(opst == BIST && dut.entropy.state_q == 2'd0 && dut.entropy.bist_cnt == 11'd0,
              "test mode at period 1: no health test runs, seed stays in BIST");

        //  ================= captures =================
        burst_at(1, "period 1");
        burst_at(2, "period 2");
        burst_at(5, "period 5");
        burst_at(DIV, "the build's period");
        burst_at(256, "period 256");

        //  ---- the index ----
        regw(R_INDEX, 64'd3);
        look(R_INDEX); check(got == 64'd3, "index write");
        look(R_DATA);  check(got == words[3], "data shows the word at the index without a read being taken");
        look(R_CTRL);  look(R_PERIOD);
        look(R_INDEX); check(got == 64'd3, "reads of other registers do not move the index");
        regr(R_CTRL); regr(R_PERIOD); regr(R_INDEX);
        look(R_INDEX); check(got == 64'd3, "taken reads of other registers do not move the index");
        //  two data reads in consecutive cycles
        @(negedge clk); reg_re = 1; reg_raddr = R_DATA;
        #1; check(reg_rdata == words[3], "first of two consecutive reads");
        @(negedge clk);
        #1; check(reg_rdata == words[4], "second of two consecutive reads: the next word is there one cycle later");
        @(negedge clk); reg_re = 0;
        look(R_INDEX); check(got == 64'd5, "two reads advance the index by two");
        regw(R_INDEX, 64'(WORDS - 1));
        regr(R_DATA); check(got == words[WORDS - 1], "last word");
        regr(R_DATA); check(got == words[0], "the index wraps to the first word");
        //  an index write and a data read in the same cycle: the write wins
        @(negedge clk); reg_we = 1; reg_waddr = R_INDEX; reg_wdata = 64'd6; reg_re = 1; reg_raddr = R_DATA;
        @(negedge clk); reg_we = 0; reg_re = 0;
        look(R_INDEX); check(got == 64'd6, "index write in the cycle of a data read");
        regr(R_DATA);  check(got == words[6], "and the word at the written index follows");

        //  ---- only bit 0 of the control register starts a capture ----
        regw(R_CTRL, 64'hffff_ffff_ffff_fffe);
        regw(R_CTRL, 64'd0);
        look(R_CTRL); check(got == status(1, 1, 0, 1, 1, 0), "a control write without the start bit starts nothing and keeps the recording");
        regw(R_INDEX, 64'd0);
        look(R_DATA); check(got == words[0], "and the recording is still there");

        //  ---- the word at the index in the cycle done appears ----
        //  With the index at the last word, which is written last, the data
        //  register must show the new word the moment it shows anything: never
        //  the word that the previous recording had there.
        regw(R_INDEX, 64'(WORDS - 1));
        look(R_DATA); check(got == words[WORDS - 1] && got != 64'd0, "the previous recording's last word is at the index");
        start_capture();
        look(R_DATA);
        while (got == 64'd0) begin
            check(src_b.size() <= first + N + 4, "the data register shows the new recording when the capture is done");
            look(R_DATA);
        end
        check(got == expected_word(WORDS - 1) && got != words[WORDS - 1],
              "the first non-zero value of the data register is the new last word, not the previous recording's");
        look(R_CTRL); check(got[1:0] == 2'b10, "and done is set with it");
        read_all("the capture read after watching its last word appear");

        //  ---- a running capture: no second start, no period change, no data ----
        regw(R_PERIOD, 64'd3);                  //  period 4
        wait_symbols(2);
        start_capture();
        i = first;
        wait_symbols(20);
        look(R_CTRL);  check(got[1:0] == 2'b01 && got[31:16] == 16'd1, "capturing: busy, one word written after twenty symbols");
        look(R_DATA);  check(got == 64'd0, "while a capture runs the previous recording cannot be read");
        regr(R_DATA);  check(got == 64'd0, "nor by a taken read");
        regw(R_PERIOD, 64'd0);
        //  the start bit again, in three consecutive cycles: at this period
        //  at most one of them is the cycle of a symbol
        @(negedge clk); reg_we = 1; reg_waddr = R_CTRL; reg_wdata = 64'd1;
        repeat (3) @(negedge clk);
        reg_we = 0;
        regw(R_INDEX, 64'd2);
        look(R_PERIOD); check(got == 64'd3, "a period write during a capture is ignored");
        first = i;
        wait_done(4);
        for (i = first + 1; i < first + N; i++)
            check(src_c[i] - src_c[i - 1] == 4, "the period did not change during the capture");
        read_all("a start written during a capture is ignored: the burst begins at the first start");
        //  register reads in every cycle of a capture at period 1 lose nothing
        regw(R_PERIOD, 64'd0);
        wait_symbols(2);
        start_capture();
        for (i = 0; i < N + 8; i++) begin
            @(negedge clk); reg_re = 1; reg_raddr = (i % 2 != 0) ? R_DATA : R_CTRL;
        end
        @(negedge clk); reg_re = 0;
        look(R_CTRL); check(got[1], "capture at period 1 with a register read in every cycle: done");
        read_all("reads during a capture at period 1");

        //  ================= leaving test mode =================
        check(words[WORDS - 1] != 64'd0 && words[0] != 64'd0, "the recording about to be abandoned is not all zero");
        regw(R_INDEX, 64'd0);
        look(R_DATA); check(got == words[0] , "before leaving: the recording is readable");
        look(R_PERIOD); check(got == 64'd0, "before leaving: the period is one clock");
        leave_test();
        expect_idle("after leaving test mode", 0);
        regr(R_DATA);
        check(got == 64'd0, "after leaving test mode a data read returns zero");
        check_exit(4, "after leaving test mode at period 1");
        check(opst == BIST, "leaving test mode restarts the start-up test");
        enter_test();
        look(R_DATA); check(got == 64'd0, "back in test mode: the old recording stays unreachable");
        regw(R_INDEX, 64'd0);
        regr(R_DATA); check(got == 64'd0, "and a read of it returns zero");
        look(R_PERIOD); check(got == 64'(DIV - 1), "and the period is the build's again");

        //  leaving in the middle of a capture
        regw(R_PERIOD, 64'd1);
        start_capture();
        wait_symbols(40);
        leave_test();
        expect_idle("after leaving test mode during a capture", 0);
        check_exit(4, "after leaving test mode during a capture at period 2");
        enter_test();
        look(R_CTRL); check(got == status(1, 1, 0, 1, 0, 0), "the abandoned capture does not continue");
        burst_at(2, "a capture after an abandoned one");
        leave_test();
        //  seed works again
        while (opst != ES16) @(negedge clk);
        check(1, "after test mode the start-up test passes and seed delivers");

        //  ================= the strap: a capture runs only while the source is on =================
        enter_test();
        burst_at(1, "before the strap tests");
        @(negedge clk); en = 0;
        repeat (3) @(negedge clk);
        look(R_CTRL); check(got == status(1, 0, 0, 1, 1, 0), "strap low: the status shows the source off, the recording still held");
        regw(R_PERIOD, 64'd0);
        start_capture();
        repeat (2) @(negedge clk);
        look(R_CTRL); check(got == status(1, 0, 0, 1, 0, 0, 1), "a capture started with the source off is aborted at once");
        look(R_DATA); check(got == 64'd0, "and the previous recording is forgotten");
        @(negedge clk); en = 1;
        repeat (20) @(negedge clk);
        look(R_CTRL); check(got == status(1, 1, 0, 1, 0, 0, 1), "switching the source on does not restart an aborted capture");
        //  the source off in exactly the cycle of the start, on again in the next
        @(negedge clk); reg_we = 1; reg_waddr = R_CTRL; reg_wdata = 64'd1; en = 0;
        @(negedge clk); reg_we = 0; en = 1;
        repeat (2 * N + 40) @(negedge clk);
        look(R_CTRL); check(got == status(1, 1, 0, 1, 0, 0, 1), "the source off only in the cycle of the start: aborted, not done");
        //  the source off for one cycle, inside a word and at a word boundary
        for (int where = 0; where < 3; where++) begin
            int stop_at = where == 0 ? 7 : where == 1 ? 16 : N - 1;
            regw(R_PERIOD, 64'd1);                  //  period 2
            wait_symbols(2);
            start_capture();
            while (src_b.size() < first + stop_at) @(negedge clk);
            @(negedge clk); en = 0;
            @(negedge clk); en = 1;
            repeat (2 * N + 40) @(negedge clk);
            look(R_CTRL);
            check(got == status(1, 1, 0, 1, 0, 0, 1),
                  $sformatf("the source off for one cycle after %0d symbols of a capture: aborted, not done", stop_at));
            look(R_DATA); check(got == 64'd0, "an aborted capture cannot be read");
        end
        //  a new capture after an abort is whole
        burst_at(2, "a capture after an aborted one");
        look(R_CTRL); check(got[6] == 1'b0, "a new capture clears the aborted flag");
        leave_test();

        //  ================= the lock =================
        //  locked while in test mode: test mode stays on, capturing ends
        enter_test();
        burst_at(1, "before the lock");
        csr(2'd2, 0, 64'd0);
        csr(2'd2, 1, got | LOCK);
        look(R_CTRL);   check(got == status(1, 1, 1, 0, 0, 0), "locked in test mode: capturing is not allowed, nothing held");
        look(R_PERIOD); check(got == 64'(DIV - 1), "locked: period register at the build's value");
        look(R_DATA);   check(got == 64'd0, "locked: data reads zero");
        regw(R_PERIOD, 64'd0); regw(R_CTRL, 64'd1); regw(R_INDEX, 64'd1);
        look(R_CTRL);   check(got == status(1, 1, 1, 0, 0, 0), "locked: a capture cannot be started");
        look(R_PERIOD); check(got == 64'(DIV - 1), "locked: the period cannot be changed");
        regr(R_DATA);   check(got == 64'd0, "locked: a data read returns zero");
        wait_symbols(4);
        check(spaced(3, DIV), "locked: the source runs at the build's period");
        //  locked outside test mode (after a reset): test mode cannot be entered
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        expect_idle("after a reset", 0);
        csr(2'd2, 0, 64'd0);
        csr(2'd2, 1, got | LOCK);
        csr(2'd1, 1, NT);
        expect_idle("locked outside test mode", 1);
        regw(R_PERIOD, 64'd0); regw(R_CTRL, 64'd1);
        expect_idle("locked outside test mode, after register writes", 1);

        //  ================= reset =================
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        enter_test();
        burst_at(3, "after a reset");
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        expect_idle("a reset ends test mode and forgets the recording", 0);
        enter_test();
        look(R_DATA); check(got == 64'd0, "after a reset the old recording is unreachable in test mode too");

        //  ================= the meter and the straps, through the wrapper =================
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        for (int a = 4; a < 8; a++) begin
            look(3'(a)); check(got == 64'd0, $sformatf("outside test mode register %0d reads zero", a));
        end
        csr(2'd3, 0, 64'd0);
        check(got[23:20] == 4'b0000, "mentropystat: lane 0 and the floor unshifted, the wrapper's defaults");
        check(got_a[23:20] == {2'd1, 2'd2}, "mentropystat of a source built with LANE = 2 and KSHIFT = 1 shows both");
        repeat (4) @(negedge clk);
        check(dut.ring_en == 6'b001111 && alt.ring_en == 6'b110101, "outside test mode the rings of RING_MASK run");
        enter_test();
        look(M_CTRL);
        check(got[37:32] == 6'b001111 && got[21:16] == 6'b001111 && got[15:0] == 16'd0,
              "test mode: the meter's control register shows the strap, the strap as its mask, and a record at every symbol");
        check(got_a[37:32] == 6'b110101, "the meter of a source built with RING_MASK = 110101 shows that strap");
        look(3'd4); check(got == 64'd0, "register 4 reads zero in test mode too");
        //  records at every fourth symbol; the references are off
        regw(M_CTRL, 64'h0000_0000_000f_0003);
        regw(M_CTRL, 64'h0000_0000_800f_0003);
        look(M_CTRL); check(got[15:0] == 16'd3 && got[41] == 1'b0, "the control register reads back; a start with the mask unchanged leaves no loss");
        meter_record("references off");
        check(!rec0[62], "the first record after a start: no loss");
        check(rec1[63:60] == rec_sym, "a record's lane bits are the symbol of its strobe");
        for (int i = 0; i < 40; i++) meter_record("references off");
        check(rec0[19:0] != 20'd0 && rec0[39:20] != 20'd0, "the totals of running rings move");
        check(rec1[59:20] == 40'd0, "the references are off: their totals stand at zero");
        //  the references on: a mask write ends a GetNoise run, and they count
        csr(2'd1, 1, NT | 64'h2000_0000);
        csr(2'd1, 0, 64'd0); check(got[31] && !got[29], "GetNoise: a new run, no loss");
        regw(M_CTRL, 64'h0000_0000_003f_0003);
        csr(2'd1, 0, 64'd0); check(got[29], "a write of the ring mask ends the GetNoise run: loss is set");
        repeat (4) @(negedge clk);
        check(dut.ring_en == 6'b111111, "in test mode the rings of the written mask run");
        regw(M_CTRL, 64'h0000_0000_803f_0003);
        for (int i = 0; i < 40; i++) meter_record("references on");
        check(rec1[39:20] != 20'd0 && rec1[59:40] != 20'd0, "the references are on: their totals move");
        //  the burst capture on ring 0's count instead of the lane bits
        regw(M_CTRL, 64'h0000_0000_007f_0003);
        regw(R_PERIOD, 64'd0);
        wait_symbols(3);
        start_capture();
        wait_done(1);
        regw(R_INDEX, 64'd0);
        for (int w = 0; w < WORDS; w++) begin
            logic [63:0] v;
            v = 64'd0;
            for (int s = 0; s < 16; s++) v[4 * s +: 4] = cnt_b[first + 16 * w + s];
            regr(R_DATA);
            check(got == v, $sformatf("burst source 1: word %0d is %016x, ring 0's counts were %016x", w, got, v));
        end
        check(cnt_b[first] != cnt_b[first + N - 1], "the count moved during that burst");
        //  ... and on the reference rings' bits beside lanes 0 and 1
        regw(M_CTRL, 64'h0000_0000_043f_0003);
        look(M_CTRL); check(got[26] && !got[22], "the reference source reads back");
        wait_symbols(3);
        start_capture();
        wait_done(1);
        regw(R_INDEX, 64'd0);
        begin
            int differ;
            differ = 0;
            for (int w = 0; w < WORDS; w++) begin
                logic [63:0] v;
                v = 64'd0;
                for (int s = 0; s < 16; s++) begin
                    v[4 * s +: 4] = ref_b[first + 16 * w + s];
                    if (ref_b[first + 16 * w + s][3:2] != src_b[first + 16 * w + s][3:2]) differ++;
                end
                regr(R_DATA);
                check(got == v, $sformatf("burst reference source: word %0d is %016x, the bits were %016x", w, got, v));
            end
            check(differ > N / 8, "the reference bits of that burst are not the bits of lanes 2 and 3");
        end
        regw(R_PERIOD, 64'(DIV - 1));             //  back to symbols far enough apart to tell which one a record holds
        wait_symbols(3);
        regw(M_CTRL, 64'h0000_0000_807f_0003);
        meter_record("burst source 1");
        check(rec1[63:60] == rec_sym, "with the burst on a count, a record's lane bits are still the lane bits");
        //  the counting mode: through the divider unless the meter asks for the ring itself
        check(dut.noise.dir_q == 1'b0, "the counters count through their dividers");
        csr(2'd1, 1, NT | 64'h2000_0000);
        regw(M_CTRL, 64'h0000_0000_103f_0003);
        look(M_CTRL); check(got[28], "the counting mode reads back");
        csr(2'd1, 0, 64'd0); check(got[29], "a change of the counting mode ends the GetNoise run: loss is set");
        repeat (16) @(negedge clk);
        check(dut.noise.dir_q == 1'b1, "the meter's direct counting reaches the noise source");
        //  the lock ends it
        csr(2'd2, 0, 64'd0);
        csr(2'd2, 1, got | LOCK);
        look(M_CTRL); check(got == 64'd0, "locked in test mode: the meter's control register reads zero");
        repeat (16) @(negedge clk);
        check(dut.noise.dir_q == 1'b0, "locked: the counters are back on their dividers");
        repeat (4) @(negedge clk);
        check(dut.ring_en == 6'b001111, "locked: the rings of the strap run");

        $display("noise burst test: PASS (%0d checks, %0d source symbols)", checks, src_b.size());
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL noise burst check: timeout");
        $fatal(1);
    end
endmodule
