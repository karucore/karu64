//  tb_entropy.sv -- unit test of rtl/karu_entropy.v (make entropy-test).
//
//  The noise source is replaced by driven symbols, so every expectation is
//  exact. test/entropy_mutants.py runs this bench against one-mechanism
//  mutants of the module, built without the module's own assertions.
//
//  Stimulus changes on the falling clock edge; an output sampled just after
//  it is what a CSR instruction executing in that cycle would read, and the
//  rising edge that follows is the one that acts on it.
//  SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_entropy;
    localparam [1:0] BIST = 2'd0, WAITS = 2'd1, ES16 = 2'd2, DEAD = 2'd3;
    localparam [63:0] NT = 64'h8000_0000, NT_NEW = 64'hA000_0000;

    logic clk = 0, rst_n = 0, rst_d = 0;
    always #5 clk = ~clk;

    logic        rng_val = 0, cfg_we = 0, noise_we = 0, ack = 0, en = 1, trng_ack = 0;
    logic [3:0]  rng_b = 0;
    logic [63:0] cfg_wdata = 0, noise_wdata = 0;
    wire  [63:0] csr_rdata;
    wire  [1:0]  opst;
    wire  [15:0] data;
    wire         rng_en;

    //  the core's sideband: one access per cycle
    logic       ro_fire = 0;                //  an access that does not write (CSRRS/CSRRC with x0)
    logic [1:0] ro_sel = 0;
    wire        csr_fire  = ack | cfg_we | noise_we | ro_fire;
    wire [1:0]  csr_sel   = ro_fire ? ro_sel : cfg_we ? 2'd2 : noise_we ? 2'd1 : 2'd0;
    wire [63:0] csr_wdata = cfg_we ? cfg_wdata : noise_we ? noise_wdata : 64'hdead_beef_dead_beef;
    wire [63:0] cfg_rdata   = dut.cfg_rdata;
    wire [63:0] noise_rdata = dut.noise_rdata;

    //  limits chosen so that the tests can reach them
    karu_entropy #(.INTERVAL_RESET(16'd0), .RCT_RESET(10'd16), .RCT_MAX(10'd64),
                   .APT_RESET(11'd600), .APT_MAX(11'd1024)) dut (
        .clk(clk), .rst(!rst_n), .en_i(en), .rng_en_o(rng_en), .rng_fips_o(),
        .rng_val_i(rng_val), .rng_b_i(rng_b),
        .csr_fire_i(csr_fire), .csr_sel_i(csr_sel), .csr_we_i(!ro_fire), .csr_wdata_i(csr_wdata),
        .csr_rdata_o(csr_rdata), .opst_o(opst), .data_o(data), .trng_ack_i(trng_ack));

    //  an instance with a floor on the interval above its reset value
    logic        lim_we = 0;
    logic [63:0] lim_wdata = 0;
    wire  [63:0] lim_rdata;
    karu_entropy #(.INTERVAL_RESET(16'd1), .INTERVAL_MIN(16'd3)) lim (
        .clk(clk), .rst(!rst_n), .en_i(1'b1), .rng_en_o(), .rng_fips_o(), .rng_val_i(1'b0), .rng_b_i(4'b0),
        .csr_fire_i(lim_we), .csr_sel_i(2'd2), .csr_we_i(1'b1), .csr_wdata_i(lim_wdata),
        .csr_rdata_o(lim_rdata), .opst_o(), .data_o(), .trng_ack_i(1'b0));

    //  an instance with the default parameters, fed one symbol per 256 clocks,
    //  to measure the time from reset to the first deliverable word
    logic       d_val = 0;
    logic [3:0] d_b = 0;
    wire  [1:0] d_opst;
    karu_entropy dflt (
        .clk(clk), .rst(!rst_d), .en_i(1'b1), .rng_en_o(), .rng_fips_o(), .rng_val_i(d_val), .rng_b_i(d_b),
        .csr_fire_i(1'b0), .csr_sel_i(2'd0), .csr_we_i(1'b0), .csr_wdata_i(64'b0),
        .csr_rdata_o(), .opst_o(d_opst), .data_o(), .trng_ack_i(1'b0));
    longint d_cycles = 0, d_first = 0;
    int     d_n = 0;
    always @(negedge clk) begin
        d_val <= 1'b0;
        if (rst_d) begin
            d_cycles <= d_cycles + 1;
            //  the pattern advances once per kept symbol (every 16th), so that the kept ones vary
            if (d_cycles % 256 == 255) begin d_val <= 1'b1; d_b <= 4'(((d_n / 16) * 3) % 16); d_n <= d_n + 1; end
            if (d_first == 0 && d_opst == ES16) d_first <= d_cycles;
        end
    end

    //  ---- checking ----
    int checks = 0;
    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) begin
            $display("FAIL entropy check %0d: %s (time %0t)", checks, what, $time);
            $fatal(1);
        end
    endtask

    //  ---- one cycle of activity, then one idle cycle ----
    logic [1:0]  o;
    logic [15:0] d;
    logic [63:0] n;
    task automatic op(input bit v, input [3:0] b, input bit a,
                      input bit cw, input [63:0] cd, input bit nw, input [63:0] nd);
        @(negedge clk);
        rng_val = v; rng_b = b; ack = a; cfg_we = cw; cfg_wdata = cd; noise_we = nw; noise_wdata = nd;
        #1; o = opst; d = data; n = noise_rdata;
        if (a) check(csr_rdata == {32'b0, opst, 14'b0, data}, "seed read value: OPST, entropy, all other bits zero");
        if (cw) check(csr_rdata == cfg_rdata, "mentropycfg read value");
        if (nw) check(csr_rdata == noise_rdata, "mnoise read value");
        @(negedge clk);
        rng_val = 0; ack = 0; cfg_we = 0; noise_we = 0;
    endtask

    //  ---- reference: the kept symbols after start-up, in order ----
    int         k = 1, src_n = 0, kept_n = 0, gi = 0;
    bit         drop = 0;
    logic [3:0] kept [$];
    task automatic ref_restart(input int new_k);
        k = new_k; src_n = 0; kept_n = 0; kept.delete();
    endtask
    function automatic [3:0] good();            //  balanced lanes, runs of at most four
        return 4'((gi * 3) % 16);
    endfunction

    task automatic sym(input [3:0] b);          //  one source symbol
        gi++;
        src_n++;
        if (src_n % k == 0) begin
            kept_n++;
            if (kept_n > 1024 && !drop) kept.push_back(b);
        end
        op(1, b, 0, 0, 64'b0, 0, 64'b0);
    endtask
    task automatic syms(input int count);
        repeat (count) sym(good());
    endtask
    task automatic seed();          op(0, 4'b0, 1, 0, 64'b0, 0, 64'b0); endtask   //  CSRRW seed
    task automatic look();          op(0, 4'b0, 0, 0, 64'b0, 0, 64'b0); endtask   //  no access
    task automatic cfgw(input [63:0] v);   op(0, 4'b0, 0, 1, v, 0, 64'b0); endtask
    task automatic noisew(input [63:0] v); op(0, 4'b0, 0, 0, 64'b0, 1, v); endtask //  CSRRW mnoise

    function automatic [63:0] cfg(input bit lock, input [10:0] apt, input [9:0] rct, input [15:0] interval);
        return {lock, 26'b0, apt, rct, interval};
    endfunction

    task automatic expect_word(input [15:0] got, input string what);
        logic [15:0] want;
        check(kept.size() >= 4, {what, ": a word was delivered without four kept symbols"});
        want = {kept[0], kept[1], kept[2], kept[3]};
        repeat (4) void'(kept.pop_front());
        check(got == want, $sformatf("%s: word %04x, expected %04x", what, got, want));
    endtask
    task automatic read_words(input int count, input string what);
        repeat (count) begin
            seed();
            check(o == ES16, {what, ": ES16 expected"});
            expect_word(d, what);
        end
    endtask
    task automatic seed_is(input [1:0] want, input string what);
        seed();
        check(o == want, $sformatf("%s: opst %0d, expected %0d", what, o, want));
        check(want == ES16 || d == 16'b0, {what, ": entropy bits outside ES16"});
    endtask
    function automatic bit storage_clean();
        for (int i = 0; i < 8; i++) if (dut.fifo[i] != 16'b0) return 0;
        return dut.part_q == 12'b0;
    endfunction

    //  an access without a write: it reads through the sideband and changes nothing
    logic [63:0] ro_data;
    task automatic read_only(input [1:0] sel);
        @(negedge clk); ro_fire = 1; ro_sel = sel;
        #1; ro_data = csr_rdata;
        @(negedge clk); ro_fire = 0;
    endtask

    task automatic reset();
        @(negedge clk); rst_n = 0; rng_val = 0; ack = 0; cfg_we = 0; noise_we = 0; en = 1; trng_ack = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        ref_restart(1); drop = 0;
    endtask

    int i;
    initial begin
        rst_d = 0; repeat (3) @(negedge clk); rst_d = 1;

        //  ================= start-up, data, bursts =================
        reset();
        seed_is(BIST, "after reset");
        check(cfg_rdata == cfg(0, 11'd600, 10'd16, 16'd0), "configuration reset values");
        syms(1023);
        seed_is(BIST, "1023 symbols into the start-up test");
        syms(1);
        seed_is(WAITS, "start-up test complete after exactly 1024 symbols");
        syms(12);
        seed_is(WAITS, "three words held: no burst is opened");
        syms(4);
        //  the RV64 four-read loop, starting with exactly four words and no refill
        @(negedge clk); ack = 1;
        for (i = 0; i < 4; i++) begin
            #1; check(opst == ES16, "four reads in consecutive cycles: ES16");
            expect_word(data, "four reads in consecutive cycles");
            @(negedge clk);
        end
        ack = 0;
        seed_is(WAITS, "fifth read after a burst of four");
        check(storage_clean(), "storage is wiped after the words were read");

        syms(20);                               //  five words
        read_only(2'd0);
        check(ro_data[31:30] == ES16, "an access without a write sees the word");
        read_only(2'd0);
        read_words(4, "an access without a write takes nothing: burst from five words");
        seed_is(WAITS, "one word left: no partial burst");
        syms(12);
        read_words(4, "the left-over word leads the next burst");
        seed_is(WAITS, "empty again");

        syms(32);                               //  eight words: full
        drop = 1; syms(6); drop = 0;            //  not taken while full
        read_words(8, "two bursts from a full buffer");
        seed_is(WAITS, "symbols that arrived while full were not buffered");
        syms(16);
        read_words(4, "packing resumes on a word boundary after being full");

        //  ================= configuration =================
        reset();
        syms(1024 + 16 + 2);                    //  four words and a partial one
        look(); check(o == ES16, "burst open before the configuration write");
        cfg_wdata = cfg(1, 11'd700, 10'd20, 16'd2);
        read_only(2'd2);
        check(ro_data == cfg(0, 11'd600, 10'd16, 16'd0), "mentropycfg read without a write");
        look(); check(o == ES16 && cfg_rdata == cfg(0, 11'd600, 10'd16, 16'd0), "and it changes nothing");
        cfgw(cfg(0, 11'd700, 10'd20, 16'd2));   //  k = 3
        ref_restart(3);
        seed_is(BIST, "a configuration write restarts the start-up test");
        check(storage_clean(), "a configuration write wipes the buffered words");
        check(cfg_rdata == cfg(0, 11'd700, 10'd20, 16'd2), "configuration read-back");
        syms(3071);
        seed_is(BIST, "k = 3: 3071 source symbols are 1023 kept ones");
        syms(1);
        seed_is(WAITS, "k = 3: start-up complete at 3072 source symbols");
        syms(48);
        read_words(4, "k = 3: words hold every third symbol");

        cfgw(cfg(0, 11'd1025, 10'd1000, 16'd5));
        ref_restart(6);
        check(cfg_rdata == cfg(0, 11'd1024, 10'd64, 16'd5), "cutoffs above the build limits are replaced by the limits");

        //  k = 5, and lock (an even k would make lane 0 of the test pattern constant)
        cfgw(cfg(1, 11'd700, 10'd20, 16'd4));
        ref_restart(5);
        check(cfg_rdata == cfg(1, 11'd700, 10'd20, 16'd4), "lock is set by an accepted write");
        syms(5 * 1024 + 5 * 16);
        look(); check(o == ES16, "locked: entropy is delivered");
        cfgw(cfg(0, 11'd1024, 10'd64, 16'd0));
        check(cfg_rdata == cfg(1, 11'd700, 10'd20, 16'd4), "locked: configuration writes are ignored");
        noisew(NT);
        look(); check(noise_rdata == 64'd1, "locked: test mode cannot be entered");
        read_words(4, "locked: ignored writes do not restart or wipe");

        @(negedge clk);
        check(lim_rdata[15:0] == 16'd3, "a reset interval below the floor is raised to the floor");
        lim_wdata = cfg(0, 11'd821, 10'd41, 16'd0); lim_we = 1; @(negedge clk); lim_we = 0; #1;
        check(lim_rdata[15:0] == 16'd3, "an interval below the floor is replaced by the floor");
        lim_wdata = cfg(0, 11'd821, 10'd41, 16'd7); lim_we = 1; @(negedge clk); lim_we = 0; #1;
        check(lim_rdata[15:0] == 16'd7, "an interval above the floor is accepted");

        //  ================= repetition count test =================
        reset();
        syms(1024 + 16);
        sym(good() & 4'b1011);                  //  lane 2 = 0
        repeat (15) sym(good() | 4'b0100);      //  lane 2 = 1, fifteen times
        look(); check(o == ES16, "fifteen repeats are below the cutoff of sixteen");
        //  the sixteenth repeat arrives in the cycle of a seed read
        gi++;
        op(1, good() | 4'b0100, 1, 0, 64'b0, 0, 64'b0);
        check(o != ES16 && d == 16'b0, "a read in the cycle of a health failure gets no entropy");
        ref_restart(1);
        seed_is(BIST, "a failure while running returns to the start-up test");
        check(storage_clean(), "a failure wipes the buffered words");
        check(rng_en, "the source stays enabled during the retest");
        syms(1024 + 16);
        read_words(4, "after a retest only new symbols are delivered");

        sym(good() & 4'b1110);                  //  lane 0 = 0
        repeat (16) sym(good() | 4'b0001);
        seed_is(BIST, "second failure while running");
        repeat (15) sym(good() | 4'b0001);
        seed_is(BIST, "fifteen repeats during the retest");
        sym(good() | 4'b0001);
        seed_is(DEAD, "a failure during the start-up test is fatal");
        check(!rng_en, "the source is disabled when dead");
        cfgw(cfg(0, 11'd1024, 10'd64, 16'd0));
        ref_restart(1);
        syms(1100);
        seed_is(DEAD, "dead until reset");
        //  raw samples are still available from a dead source, in test mode only
        noisew(NT);
        look(); check(rng_en, "test mode switches a dead source back on");
        check(opst == DEAD, "seed keeps reporting DEAD in test mode");
        op(1, 4'hC, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n == 64'hC000_000C, "a dead source still gives raw symbols");
        noisew(64'b0);
        look(); check(!rng_en && opst == DEAD, "leaving test mode: off again, still DEAD");

        //  ================= adaptive proportion test =================
        reset();
        syms(1024);                             //  one full window; the next starts here
        for (i = 0; i < 1024 && opst != BIST; i++)
            sym((good() & 4'b1101) | ((i % 4 != 3) ? 4'b0010 : 4'b0000));   //  lane 1: 1,1,1,0
        check(opst == BIST, "a lane at three ones in four fails the proportion test");
        check(i == 799, $sformatf("the 600th matching sample is the 799th of the window (got %0d)", i));
        ref_restart(1);
        for (i = 0; i < 1024 && opst != DEAD; i++)
            sym((good() & 4'b1101) | ((i % 4 != 3) ? 4'b0010 : 4'b0000));
        check(opst == DEAD && i == 799, "the same bias during the retest is fatal");

        //  ================= GetNoise =================
        reset();
        look(); check(noise_rdata == 64'd1, "mnoise reads 1 outside test mode");
        syms(1024 + 16);
        look(); check(o == ES16, "words held before test mode");
        noisew(NT);
        seed_is(BIST, "seed is in BIST in test mode");
        check(storage_clean(), "entering test mode wipes the buffered words");
        noisew(NT);
        check(n == 64'h8000_0000, "no symbol yet: valid = 0, loss = 0");
        op(1, 4'hA, 0, 0, 64'b0, 0, 64'b0);
        look(); check(noise_rdata == 64'hC000_000A, "a plain read observes the symbol");
        look(); check(noise_rdata == 64'hC000_000A, "a plain read does not take it");
        noise_wdata = 64'b0;
        read_only(2'd1);
        check(ro_data == 64'hC000_000A, "mnoise read without a write returns the symbol");
        look(); check(noise_rdata == 64'hC000_000A, "and neither takes it nor leaves test mode");
        noisew(NT);
        check(n == 64'hC000_000A, "CSRRW returns the symbol");
        look(); check(noise_rdata == 64'h8000_0000, "and has taken it");
        //  a new symbol in the cycle of the CSRRW
        op(1, 4'h5, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h6, 0, 0, 64'b0, 1, NT);
        check(n == 64'hC000_0005, "CSRRW with a symbol arriving: the held symbol is returned");
        noisew(NT);
        check(n == 64'hC000_0006, "the symbol that arrived in that cycle is kept, without loss");
        //  loss
        op(1, 4'h1, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h2, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n == 64'hE000_0002, "a symbol that was not taken is lost, and that is flagged");
        noisew(NT);
        check(n == 64'hA000_0000, "the loss flag stays set");
        op(1, 4'h3, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n == 64'hE000_0003, "symbols after a loss still carry the flag");
        //  start a new run
        op(1, 4'h4, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT_NEW);
        check(n == 64'hE000_0004, "the clearing write returns the old state");
        noisew(NT);
        check(n == 64'h8000_0000, "after it: nothing held, loss cleared");
        op(1, 4'h7, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n == 64'hC000_0007, "new run: consecutive symbols without the flag");
        //  a clearing write with a symbol arriving in the same cycle
        op(1, 4'h8, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h9, 0, 0, 64'b0, 0, 64'b0);     //  loses 8
        op(1, 4'hB, 0, 0, 64'b0, 1, NT_NEW);
        check(n == 64'hE000_0009, "clearing write with a symbol arriving");
        noisew(NT);
        check(n == 64'hC000_000B, "that symbol starts the new run");
        //  health tests do not run, and no entropy is delivered, in test mode
        repeat (1200) begin op(1, 4'hF, 0, 0, 64'b0, 0, 64'b0); check(opst == BIST, "BIST throughout test mode"); end
        //  decimation applies to GetNoise as well
        noisew(64'b0);
        look(); check(noise_rdata == 64'd1, "left test mode");
        cfgw(cfg(0, 11'd600, 10'd16, 16'd2));
        noisew(NT);
        op(1, 4'h1, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h2, 0, 0, 64'b0, 0, 64'b0);
        look(); check(noise_rdata == 64'h8000_0000, "k = 3: the first two symbols are not kept");
        op(1, 4'h3, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n == 64'hC000_0003, "k = 3: the third symbol is the sample");
        //  leaving test mode: start-up test again, then only new data
        noisew(64'b0);
        ref_restart(3);
        seed_is(BIST, "leaving test mode restarts the start-up test");
        syms(3072);
        seed_is(WAITS, "start-up complete after test mode");
        syms(48);
        read_words(4, "after test mode only new symbols are delivered");

        //  ================= the platform strap =================
        reset();
        syms(1024 + 16);
        look(); check(o == ES16 && rng_en, "running before the strap is pulled");
        @(negedge clk); en = 0; #1;
        check(opst == BIST && data == 16'b0, "strap low: BIST in the same cycle");
        check(!rng_en, "strap low: the noise source is disabled");
        @(negedge clk);
        check(storage_clean(), "strap low: buffered words are wiped");
        repeat (1100) begin op(1, good(), 1, 0, 64'b0, 0, 64'b0); gi++; check(o == BIST && d == 16'b0, "strap low: BIST whatever the source does"); end
        noisew(NT);
        op(1, 4'h9, 0, 0, 64'b0, 0, 64'b0);
        look(); check(noise_rdata == 64'h8000_0000, "strap low: no raw symbols either");
        noisew(64'b0);
        @(negedge clk); en = 1;
        ref_restart(1);
        syms(1023);
        seed_is(BIST, "strap released: the start-up test runs from the beginning");
        syms(1);
        seed_is(WAITS, "strap released: start-up complete after 1024 symbols");
        syms(16);
        read_words(4, "strap released: only new symbols are delivered");

        //  ================= the authentication block's port =================
        syms(16);
        seed(); check(o == ES16, "first word of a burst by seed"); expect_word(d, "seed then trng");
        repeat (2) begin
            @(negedge clk); trng_ack = 1; #1;
            check(opst == ES16, "words of the same burst through the trng port");
            expect_word(data, "trng port");
            @(negedge clk); trng_ack = 0;
        end
        seed(); check(o == ES16, "last word of the burst by seed"); expect_word(d, "trng then seed");
        seed_is(WAITS, "a burst is four words whichever port took them");

        //  ================= time to the first word, default parameters =================
        wait (d_first != 0 || d_opst == DEAD);
        check(d_opst != DEAD, "default-parameter instance is healthy");
        $display("default parameters, one source symbol per 256 clocks: first ES16 %0d clocks after reset (%.1f ms at 75 MHz)",
                 d_first, d_first / 75000.0);
        check(d_first > 4_259_840 - 300 && d_first < 4_259_840 + 300,
              "time to first word = (1024 + 16) kept symbols * 16 * 256 clocks");

        $display("entropy test: PASS (%0d checks)", checks);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL entropy test: timeout");
        $fatal(1);
    end
endmodule
