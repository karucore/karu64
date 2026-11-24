//  tb_entropy.sv -- unit test of rtl/karu_entropy.v (make entropy-test).
//
//  The noise source is replaced by driven symbols, so every expectation is
//  exact. test/entropy_mutants.py runs this bench against one-mechanism
//  mutants of the module, built without the module's own assertions.
//  test/entropy_replay.py compares the health logic and the words with the
//  reference model on long sequences; this bench has the directed cases: the
//  lane that is the source and the three that are not, each test at its
//  cutoff and one sample short of it, the alarm, the strikes, the status
//  register, the limits and the spacing floor, and everything on the delivery
//  and GetNoise side.
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

    logic        rng_val = 0, cfg_we = 0, noise_we = 0, ack = 0, en = 1, respace = 0;
    logic [3:0]  rng_b = 0;
    logic [1:0]  lane = 0;                  //  the strap lane_i; changed only under reset
    logic [63:0] cfg_wdata = 0, noise_wdata = 0;
    wire  [63:0] csr_rdata;
    wire         rng_en;

    //  the core's sideband: one access per cycle
    logic       ro_fire = 0;                //  an access that does not write (CSRRS/CSRRC with x0)
    logic [1:0] ro_sel = 0;
    logic       stat_we = 0;                //  a write to mentropystat
    wire        csr_fire  = ack | cfg_we | noise_we | ro_fire | stat_we;
    wire [1:0]  csr_sel   = ro_fire ? ro_sel : stat_we ? 2'd3 : cfg_we ? 2'd2 : noise_we ? 2'd1 : 2'd0;
    wire [63:0] csr_wdata = (cfg_we | stat_we) ? cfg_wdata : noise_we ? noise_wdata : 64'hdead_beef_dead_beef;
    wire [63:0] cfg_rdata   = dut.cfg_rdata;
    wire [63:0] noise_rdata = dut.noise_rdata;
    wire [63:0] stat        = dut.stat_rdata;
    wire [1:0]  st_state    = stat[1:0];    //  0 start-up test, 1 running, 2 dead
    wire        st_alarm    = stat[2];
    wire [2:0]  st_strikes  = stat[6:4];
    wire [3:0]  st_cause    = stat[11:8];   //  [10] repetition, [11] proportion; [9:8] zero
    wire [3:0]  st_lanes    = stat[15:12];
    wire [3:0]  st_lags     = stat[19:16];
    wire [1:0]  st_lane     = stat[21:20];  //  the straps
    wire [1:0]  st_kshift   = stat[23:22];
    wire [15:0] st_fails    = stat[47:32];
    localparam [3:0] C_RCT = 4'b0100, C_APT = 4'b1000;

    //  Cutoffs and limits chosen so that the tests can reach them, and so
    //  that the pseudo-random symbols between the tests never come near.
    localparam int RCT = 40, APT = 700, CALM = 11;
    karu_entropy #(.INTERVAL_RESET(16'd0), .RCT_RESET(10'd40), .RCT_MAX(10'd64),
                   .APT_RESET(11'd700), .APT_MAX(11'd1024),
                   .STRIKE_RESET(3'd3), .STRIKE_MAX(3'd5), .CALM_RESET(5'd11), .CALM_MIN(5'd10)) dut (
        .clk(clk), .rst(!rst_n), .en_i(en), .lane_i(lane), .kshift_i(2'd0), .rng_en_o(rng_en), .rng_fips_o(),
        .rng_val_i(rng_val), .rng_b_i(rng_b),
        .csr_fire_i(csr_fire), .csr_sel_i(csr_sel), .csr_we_i(!ro_fire), .csr_wdata_i(csr_wdata),
        .csr_rdata_o(csr_rdata), .respace_i(respace), .test_o(), .lock_o());
    //  what a seed access reads in this cycle
    wire  [1:0]  opst = dut.seed_rdata[31:30];
    wire  [15:0] data = dut.seed_rdata[15:0];
    //  the status register with nothing in it but the straps
    function automatic [63:0] stat_straps();
        return {40'b0, 2'd0, lane, 20'b0};
    endfunction

    //  An instance with a floor on the interval above its reset value: the
    //  build's smallest k is 4, the reset value asks for k = 2, and the strap
    //  kshift_i multiplies the floor by 1, 2, 4 or 8. Its source is lane 1.
    logic        lim_rst_n = 0, lim_we = 0, lim_val = 0;
    logic [1:0]  lim_kshift = 0;
    logic [3:0]  lim_b = 0;
    longint unsigned lim_prng = 64'hd1b5_4a32_d192_ed03;
    always @(negedge clk) begin
        lim_prng = lim_prng ^ (lim_prng << 13); lim_prng = lim_prng ^ (lim_prng >> 7); lim_prng = lim_prng ^ (lim_prng << 17);
        lim_b <= lim_prng[23:20];
    end
    function automatic [63:0] dcfg(input [15:0] interval);    //  the default configuration with another interval
        return {1'b0, 1'b0, 5'd24, 3'd3, 17'd0, 11'd719, 10'd55, interval};
    endfunction
    logic [1:0]  lim_sel = 2'd2;
    logic [63:0] lim_wdata = 0;
    wire  [63:0] lim_rdata;
    karu_entropy #(.INTERVAL_RESET(16'd1), .INTERVAL_MIN(16'd3)) lim (
        .clk(clk), .rst(!lim_rst_n), .en_i(1'b1), .lane_i(2'd1), .kshift_i(lim_kshift),
        .rng_en_o(), .rng_fips_o(), .rng_val_i(lim_val), .rng_b_i(lim_b),
        .csr_fire_i(lim_we), .csr_sel_i(lim_sel), .csr_we_i(1'b1), .csr_wdata_i(lim_wdata),
        .csr_rdata_o(lim_rdata), .respace_i(1'b0), .test_o(), .lock_o());
    int lim_kept = 0;
    always @(posedge clk) if (lim.sym_v) lim_kept <= lim_kept + 1;
    task automatic lim_reset(input [1:0] kshift);   //  the strap changes under reset only
        @(negedge clk); lim_rst_n = 0; lim_kshift = kshift; lim_we = 0; lim_val = 0; lim_sel = 2'd2;
        repeat (3) @(negedge clk);
        lim_rst_n = 1;
        @(negedge clk);
    endtask
    task automatic lim_write(input [1:0] sel, input [63:0] v);
        @(negedge clk); lim_sel = sel; lim_wdata = v; lim_we = 1;
        @(negedge clk); lim_we = 0; lim_sel = 2'd2;
    endtask
    task automatic lim_symbols(input int count, output int kept);     //  one source symbol per clock
        @(negedge clk); kept = lim_kept; lim_val = 1;
        repeat (count) @(negedge clk);
        lim_val = 0;
        @(negedge clk); kept = lim_kept - kept;
    endtask

    //  Instances that are only reset, for the interval after reset: a reset
    //  value above the floor, a floor that the field cannot hold, and the
    //  default parameters with each value of the strap.
    wire [63:0] unused_rdata [0:4];
    karu_entropy #(.INTERVAL_RESET(16'd40), .INTERVAL_MIN(16'd3)) above (
        .clk(clk), .rst(!rst_d), .en_i(1'b1), .lane_i(2'd0), .kshift_i(2'd2),
        .rng_en_o(), .rng_fips_o(), .rng_val_i(1'b0), .rng_b_i(4'b0),
        .csr_fire_i(1'b0), .csr_sel_i(2'd0), .csr_we_i(1'b0), .csr_wdata_i(64'b0),
        .csr_rdata_o(unused_rdata[0]), .respace_i(1'b0), .test_o(), .lock_o());
    karu_entropy #(.INTERVAL_RESET(16'd1), .INTERVAL_MIN(16'h2fff)) sat (
        .clk(clk), .rst(!rst_d), .en_i(1'b1), .lane_i(2'd0), .kshift_i(2'd3),
        .rng_en_o(), .rng_fips_o(), .rng_val_i(1'b0), .rng_b_i(4'b0),
        .csr_fire_i(1'b0), .csr_sel_i(2'd0), .csr_we_i(1'b0), .csr_wdata_i(64'b0),
        .csr_rdata_o(unused_rdata[1]), .respace_i(1'b0), .test_o(), .lock_o());
    for (genvar gk = 1; gk < 4; gk++) begin : dk
        karu_entropy u (
            .clk(clk), .rst(!rst_d), .en_i(1'b1), .lane_i(2'd3), .kshift_i(2'(gk)),
            .rng_en_o(), .rng_fips_o(), .rng_val_i(1'b0), .rng_b_i(4'b0),
            .csr_fire_i(1'b0), .csr_sel_i(2'd0), .csr_we_i(1'b0), .csr_wdata_i(64'b0),
            .csr_rdata_o(unused_rdata[1 + gk]), .respace_i(1'b0), .test_o(), .lock_o());
    end

    //  an instance with the default parameters, fed one symbol per 256 clocks,
    //  to measure the time from reset to the first deliverable word
    logic       d_val = 0;
    logic [3:0] d_b = 0;
    karu_entropy dflt (
        .clk(clk), .rst(!rst_d), .en_i(1'b1), .lane_i(2'd0), .kshift_i(2'd0),
        .rng_en_o(), .rng_fips_o(), .rng_val_i(d_val), .rng_b_i(d_b),
        .csr_fire_i(1'b0), .csr_sel_i(2'd0), .csr_we_i(1'b0), .csr_wdata_i(64'b0),
        .csr_rdata_o(), .respace_i(1'b0), .test_o(), .lock_o());
    wire  [1:0] d_opst = dflt.seed_rdata[31:30];
    longint d_cycles = 0, d_first = 0;
    longint unsigned d_prng = 64'h2545_f491_4f6c_dd1d;
    always @(negedge clk) begin
        d_val <= 1'b0;
        if (rst_d) begin
            d_cycles <= d_cycles + 1;
            if (d_cycles % 256 == 255) begin
                d_val <= 1'b1; d_b <= d_prng[23:20];
                d_prng = d_prng ^ (d_prng << 13); d_prng = d_prng ^ (d_prng >> 7); d_prng = d_prng ^ (d_prng << 17);
            end
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
    //  o and d are what seed read in the cycle of the operation
    logic [1:0]  o;
    logic [15:0] d;
    logic [63:0] n_rd;
    task automatic op(input bit v, input [3:0] b, input bit a,
                      input bit cw, input [63:0] cd, input bit nw, input [63:0] nd);
        @(negedge clk);
        rng_val = v; rng_b = b; ack = a; cfg_we = cw; cfg_wdata = cd; noise_we = nw; noise_wdata = nd;
        #1; o = dut.seed_rdata[31:30]; d = dut.seed_rdata[15:0]; n_rd = noise_rdata;
        if (a) check(csr_rdata == dut.seed_rdata && csr_rdata == {32'b0, o, 14'b0, d},
                     "seed read value: OPST, entropy, all other bits zero");
        if (cw) check(csr_rdata == cfg_rdata, "mentropycfg read value");
        if (nw) check(csr_rdata == noise_rdata, "mnoise read value");
        @(negedge clk);
        rng_val = 0; ack = 0; cfg_we = 0; noise_we = 0;
    endtask

    //  ---- reference: the samples after start-up, in order ----
    //  A sample is the bit of the selected lane in a kept symbol.
    int  k = 1, src_n = 0, kept_n = 0;
    bit  drop = 0;
    bit  kept [$];
    task automatic ref_restart(input int new_k);
        k = new_k; src_n = 0; kept_n = 0; kept.delete();
    endtask
    //  Symbols of a healthy source: a fixed pseudo-random sequence (xorshift64).
    //  No lane of it has a period, and no count of it comes near a cutoff.
    longint unsigned prng = 64'h9e37_79b9_7f4a_7c15;
    function automatic [3:0] good();
        prng = prng ^ (prng << 13); prng = prng ^ (prng >> 7); prng = prng ^ (prng << 17);
        return prng[23:20];
    endfunction
    function automatic int rnd(input int below);    //  0 .. below-1
        prng = prng ^ (prng << 13); prng = prng ^ (prng >> 7); prng = prng ^ (prng << 17);
        return int'({1'b0, prng[40:10]} % below);
    endfunction
    //  the symbol s with the bit b on the selected lane
    function automatic [3:0] on_lane(input [3:0] s, input bit b);
        return (s & ~(4'b1 << lane)) | (4'(b) << lane);
    endfunction
    //  the symbol s with the bit b on each of the three other lanes
    function automatic [3:0] off_lane(input [3:0] s, input bit b);
        return (s & (4'b1 << lane)) | ({4{b}} & ~(4'b1 << lane));
    endfunction
    //  a pattern whose shortest period is L (1 to 4), at position i
    function automatic bit pat(input int L, input int i);
        int j = ((i % 12) + 12) % 12;
        case (L)
            1:       return 1;
            2:       return j % 2 == 0;
            3:       return j % 3 == 0;
            default: return j % 4 < 2;
        endcase
    endfunction

    task automatic sym(input [3:0] b);          //  one source symbol
        src_n++;
        if (src_n % k == 0) begin
            kept_n++;
            if (kept_n > 1024 && !drop) kept.push_back(b[lane]);
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

    function automatic [63:0] cfgx(input bit lock, input [4:0] calm, input [2:0] strikes,
                                   input [10:0] apt, input [9:0] rct, input [15:0] interval);
        return {lock, 1'b0, calm, strikes, 17'b0, apt, rct, interval};
    endfunction
    //  the cutoffs and the interval, the other fields as after reset
    function automatic [63:0] cfg(input bit lock, input [10:0] apt, input [9:0] rct, input [15:0] interval);
        return cfgx(lock, 5'd11, 3'd3, apt, rct, interval);
    endfunction
    localparam [63:0] CFG_RESET = {1'b0, 1'b0, 5'd11, 3'd3, 17'b0, 11'd700, 10'd40, 16'd0};
    localparam [63:0] CFG_RESERVED = 64'h403f_ffe0_0000_0000;    //  [62] and [53:37]
    task automatic statw(input [63:0] v);       //  a write to the read-only status register
        @(negedge clk); stat_we = 1; cfg_wdata = v;
        @(negedge clk); stat_we = 0;
    endtask

    task automatic expect_word(input [15:0] got, input string what);
        logic [15:0] want;
        check(kept.size() >= 16, {what, ": a word was delivered without sixteen samples"});
        for (int j = 15; j >= 0; j--) want[j] = kept.pop_front();     //  the first sample in bit 15
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
        return dut.part_q == 15'b0;
    endfunction

    //  an access without a write: it reads through the sideband and changes nothing
    logic [63:0] ro_data;
    task automatic read_only(input [1:0] sel);
        @(negedge clk); ro_fire = 1; ro_sel = sel;
        #1; ro_data = csr_rdata;
        @(negedge clk); ro_fire = 0;
    endtask

    task automatic reset();
        @(negedge clk); rst_n = 0; rng_val = 0; ack = 0; cfg_we = 0; noise_we = 0; en = 1; respace = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        ref_restart(1); drop = 0;
    endtask
    task automatic reset_on(input [1:0] l);     //  a reset with another lane as the source
        @(negedge clk); rst_n = 0; lane = l;
        reset();
    endtask

    //  ---- helpers for the health tests ----
    //  A period-L pattern on the source, made exact: the four samples before
    //  it carry the opposite of what the pattern would have there, so no count
    //  starts early. The count at lag L then reaches the cutoff c at position
    //  c + L - 2 of the pattern, and no other lag gets there first. The other
    //  three lanes carry healthy bits throughout.
    task automatic anti(input int L);
        for (int j = -4; j < 0; j++) sym(on_lane(good(), !pat(L, j)));
    endtask
    task automatic pattern(input int L, input int first, input int count);
        for (int j = first; j < first + count; j++) sym(on_lane(good(), pat(L, j)));
    endtask
    //  one running failure: the source stuck for exactly as long as the cutoff
    task automatic fail_once();
        anti(1); pattern(1, 0, RCT);
        ref_restart(1);
    endtask
    //  healthy symbols until a window starts
    task automatic to_window();
        while (dut.win_idx != 10'd0) sym(good());
    endtask
    task automatic running();                   //  reset, start-up test passed, a burst open
        reset();
        syms(1024 + 64);
        look(); check(o == ES16 && st_state == 2'd1, "running, with words to read");
    endtask
    task automatic running_on(input [1:0] l);
        reset_on(l);
        syms(1024 + 64);
        look(); check(o == ES16 && st_state == 2'd1 && st_lane == l, "running, with words to read");
    endtask
    task automatic expect_fail(input [3:0] cause, input [3:0] lags, input string what);
        look();
        check(st_cause == cause && st_lanes == (4'b1 << lane) && st_lags == lags,
              $sformatf("%s: cause %04b lanes %04b lags %04b, expected %04b %04b %04b", what, st_cause, st_lanes, st_lags, cause, 4'b1 << lane, lags));
    endtask
    //  The three other lanes with a fault, the source healthy: count symbols
    //  (a multiple of 64), read back as words while they come. kind: 0 stuck
    //  at 0, 1 stuck at 1, 2 to 4 a pattern of that period, 5 a copy of the
    //  source, 6 its complement.
    task automatic elsewhere(input int kind, input int count, input string what);
        logic [3:0] s;
        for (int j = 0; j < count; j++) begin
            s = good();
            case (kind)
                0:       s = off_lane(s, 0);
                1:       s = off_lane(s, 1);
                5:       s = off_lane(s, s[lane]);
                6:       s = off_lane(s, !s[lane]);
                default: s = off_lane(s, pat(kind, j));
            endcase
            sym(s);
            if (j % 64 == 63) begin
                look(); check(st_fails == 16'd0 && st_state == 2'd1 && !st_alarm && st_strikes == 3'd0, {what, ": no failure"});
                read_words(4, {what, ": the words are the source's samples"});
            end
        end
    endtask

    int i, n, lag, kept_lim, fl;
    logic [15:0] fails0;
    logic [3:0]  v;
    bit          one;
    initial begin
        rst_d = 0; repeat (3) @(negedge clk); rst_d = 1;

        //  ================= start-up, data, bursts: each lane as the source =================
        for (int l = 0; l < 4; l++) begin
            reset_on(2'(l));
            seed_is(BIST, "after reset");
            check(cfg_rdata == CFG_RESET, "configuration reset values");
            check(stat == stat_straps() && st_lane == 2'(l) && st_kshift == 2'd0,
                  "status after reset: start-up test, no alarm, no strikes, no failures; the straps");
            for (i = 0; i < 16; i++) sym(4'(i));
            look(); check(st_state == 2'd0 && st_fails == 16'd0, "each of the sixteen symbol values once: no test looks at the symbol, no failure");
            syms(1023 - 16);
            seed_is(BIST, "1023 samples into the start-up test");
            check(st_state == 2'd0, "status: start-up test");
            syms(1);
            seed_is(WAITS, "start-up test complete after exactly 1024 samples");
            check(st_state == 2'd1, "status: running");
            syms(48);
            seed_is(WAITS, "three words held: no burst is opened");
            syms(15);
            seed_is(WAITS, "the fourth word one sample short: still no burst");
            check(dut.fill_q == 4'd3, "fifteen samples are not a word");
            syms(1);
            check(dut.fill_q == 4'd4, "the sixteenth sample completes the word");
            syms(1);
            check(dut.fill_q == 4'd4, "and the seventeenth starts the next one");
            //  the RV64 four-read loop, starting with exactly four words and no refill
            @(negedge clk); ack = 1;
            for (i = 0; i < 4; i++) begin
                #1; check(opst == ES16, "four reads in consecutive cycles: ES16");
                expect_word(data, "four reads in consecutive cycles");
                @(negedge clk);
            end
            ack = 0;
            seed_is(WAITS, "fifth read after a burst of four");
            check(dut.fifo[0] == 16'b0 && dut.fifo[1] == 16'b0 && dut.fifo[2] == 16'b0 && dut.fifo[3] == 16'b0,
                  "the words are wiped as they are read");

            syms(79);                               //  with the one before: five words
            read_only(2'd0);
            check(ro_data[31:30] == ES16, "an access without a write sees the word");
            read_only(2'd0);
            read_words(4, "an access without a write takes nothing: burst from five words");
            seed_is(WAITS, "one word left: no partial burst");
            syms(48);
            read_words(4, "the left-over word leads the next burst");
            seed_is(WAITS, "empty again");
            check(storage_clean(), "storage is wiped after the words were read");

            syms(128);                              //  eight words: full
            drop = 1; syms(21); drop = 0;           //  not taken while full
            read_words(8, "two bursts from a full buffer");
            seed_is(WAITS, "samples that arrived while full were not buffered");
            syms(64);
            read_words(4, "packing resumes on a word boundary after being full");

            //  GetNoise shows the symbols as the source gave them, all four lanes
            noisew(NT);
            noisew(NT);
            check(n_rd == 64'h8000_0000, "test mode entered: no symbol held from before, no loss");
            for (i = 0; i < 16; i++) begin
                op(1, 4'(i), 0, 0, 64'b0, 0, 64'b0);
                noisew(NT);
                check(n_rd == (64'hC000_0000 | 64'(i)), $sformatf("source lane %0d: GetNoise returns symbol %0x with all four lanes", l, i));
                look(); check(noise_rdata == 64'h8000_0000, "and the CSRRW has taken it");
            end
            noisew(64'b0);
        end

        //  ================= configuration =================
        reset_on(2'd0);
        syms(1024 + 64 + 9);                    //  four words and a partial one
        look(); check(o == ES16, "burst open before the configuration write");
        cfg_wdata = cfg(1, 11'd800, 10'd30, 16'd2);
        read_only(2'd2);
        check(ro_data == CFG_RESET, "mentropycfg read without a write");
        look(); check(o == ES16 && cfg_rdata == CFG_RESET, "and it changes nothing");
        cfgw(cfg(0, 11'd800, 10'd30, 16'd2));   //  k = 3
        ref_restart(3);
        seed_is(BIST, "a configuration write restarts the start-up test");
        check(storage_clean(), "a configuration write wipes the buffered words");
        check(cfg_rdata == cfg(0, 11'd800, 10'd30, 16'd2), "configuration read-back");
        syms(3071);
        seed_is(BIST, "k = 3: 3071 source symbols are 1023 samples");
        syms(1);
        seed_is(WAITS, "k = 3: start-up complete at 3072 source symbols");
        syms(192);
        read_words(4, "k = 3: words hold every third symbol's bit");

        cfgw(cfgx(0, 5'd3, 3'd7, 11'd1025, 10'd1000, 16'd5));
        ref_restart(6);
        check(cfg_rdata == cfgx(0, 5'd10, 3'd5, 11'd1024, 10'd64, 16'd5),
              "values weaker than the build limits are replaced by the limits: both cutoffs, strikes and calm");
        cfgw(cfgx(0, 5'd31, 3'd0, 11'd650, 10'd35, 16'd5));
        check(cfg_rdata == cfgx(0, 5'd31, 3'd0, 11'd650, 10'd35, 16'd5), "stricter values are taken as written");
        cfgw(CFG_RESERVED | cfg(0, 11'd700, 10'd40, 16'd5));
        check(cfg_rdata == cfg(0, 11'd700, 10'd40, 16'd5), "the reserved fields, [62] and [53:37], read zero when ones are written");
        check((cfg_rdata & CFG_RESERVED) == 64'b0 && (CFG_RESERVED & cfgx(1, 5'd31, 3'd7, 11'h7ff, 10'h3ff, 16'hffff)) == 64'b0,
              "the reserved fields are the bits outside every field");

        cfgw(cfg(1, 11'd800, 10'd30, 16'd4));   //  k = 5, and lock
        ref_restart(5);
        check(cfg_rdata == cfg(1, 11'd800, 10'd30, 16'd4), "lock is set by an accepted write");
        syms(5 * 1024 + 5 * 64);
        look(); check(o == ES16, "locked: entropy is delivered");
        cfgw(cfg(0, 11'd1024, 10'd64, 16'd0));
        check(cfg_rdata == cfg(1, 11'd800, 10'd30, 16'd4), "locked: configuration writes are ignored");
        noisew(NT);
        look(); check(noise_rdata == 64'd1, "locked: test mode cannot be entered");
        read_words(4, "locked: ignored writes do not restart or wipe");

        //  the status register: read through the sideband, and not writable
        reset_on(2'd3);
        syms(1024 + 64);
        read_only(2'd3);
        check(ro_data == stat && ro_data == (64'd1 | stat_straps()) && ro_data[21:20] == 2'd3,
              "mentropystat read: running, the lane strap, nothing else");
        statw(64'hffff_ffff_ffff_ffff);
        look(); check(stat == (64'd1 | stat_straps()) && cfg_rdata == CFG_RESET && noise_rdata == 64'd1 && o == ES16,
                      "a write to mentropystat changes nothing");
        read_words(4, "and takes no word");

        //  ================= the spacing floor =================
        //  The build's smallest k is 4; the strap makes the floor 4, 8, 16 or
        //  32. The reset value of the parameter, k = 2, is below all of them.
        for (int ks = 0; ks < 4; ks++) begin
            fl = 4 << ks;
            lim_reset(2'(ks));
            check(lim.cfg_rdata[15:0] == 16'(fl - 1),
                  $sformatf("kshift %0d: after reset the interval is the floor, k = %0d (it reads %0d)", ks, fl, lim.cfg_rdata[15:0]));
            check((lim.cfg_rdata | 64'hffff) == dcfg(16'hffff), "and the other fields are the default ones");
            check(lim.stat_rdata == {40'b0, 2'(ks), 2'd1, 20'b0}, "mentropystat shows the floor's shift and the lane");
            lim_symbols(1600, kept_lim);
            check(kept_lim == 1600 / fl, $sformatf("kshift %0d: every %0d-th symbol is kept after reset (%0d of 1600)", ks, fl, kept_lim));
            lim_write(2'd2, dcfg(16'd0));
            check(lim.cfg_rdata[15:0] == 16'd0, "a written interval reads back as written");
            lim_symbols(1600, kept_lim);
            check(kept_lim == 1600 / fl, $sformatf("kshift %0d: k = 1 written, the floor is used (%0d of 1600)", ks, kept_lim));
            lim_write(2'd2, dcfg(16'd3));
            lim_symbols(1600, kept_lim);
            check(kept_lim == 1600 / fl, $sformatf("kshift %0d: the build's smallest k written, the floor is used (%0d of 1600)", ks, kept_lim));
            lim_write(2'd2, dcfg(16'(2 * fl - 1)));
            lim_symbols(1600, kept_lim);
            check(kept_lim == 800 / fl, $sformatf("kshift %0d: an interval above the floor is used (%0d of 1600)", ks, kept_lim));
            lim_write(2'd2, dcfg(16'd0));
            lim_write(2'd1, NT);                    //  test mode: seed delivers nothing, any spacing
            lim_symbols(1600, kept_lim);
            check(kept_lim == 1600, $sformatf("kshift %0d: test mode with k = 1, every symbol is a sample (%0d of 1600)", ks, kept_lim));
            lim_write(2'd1, 64'b0);
            lim_symbols(1600, kept_lim);
            check(kept_lim == 1600 / fl, $sformatf("kshift %0d: test mode left, the floor again (%0d of 1600)", ks, kept_lim));
        end
        check(above.cfg_rdata[15:0] == 16'd40, "a reset value above the floor (k = 41 against 16) is the interval after reset");
        check(sat.cfg_rdata[15:0] == 16'hffff, "a floor that the field cannot hold is the largest interval");
        check(dflt.cfg_rdata == 64'h30c0_000b_3c37_000f && dk[1].u.cfg_rdata == 64'h30c0_000b_3c37_001f &&
              dk[2].u.cfg_rdata == 64'h30c0_000b_3c37_003f && dk[3].u.cfg_rdata == 64'h30c0_000b_3c37_007f,
              "default parameters: mentropycfg after reset for kshift 0 to 3, k = 16, 32, 64 and 128");
        check(dk[1].u.stat_rdata[23:20] == 4'b0111 && dk[2].u.stat_rdata[23:20] == 4'b1011 && dk[3].u.stat_rdata[23:20] == 4'b1111,
              "default parameters: mentropystat shows each shift, and lane 3");

        //  ================= repetition: a stuck source, the alarm =================
        running_on(2'd2);
        anti(1);
        pattern(1, 0, RCT - 1);                 //  ones, one short of the cutoff
        look(); check(o == ES16 && st_fails == 16'd0, "one repeat short of the cutoff: no failure");
        //  the repeat that reaches the cutoff arrives in the cycle of a seed read
        op(1, on_lane(good(), 1), 1, 0, 64'b0, 0, 64'b0);
        check(o != ES16 && d == 16'b0, "a read in the cycle of a health failure gets no entropy");
        ref_restart(1);
        expect_fail(C_RCT, 4'b0001, "the source stuck");
        check(st_state == 2'd0 && st_alarm && st_strikes == 3'd1 && st_fails == 16'd1,
              "status: start-up test again, alarm, one strike, one failure");
        check(opst == BIST, "a failure while running returns to the start-up test");
        check(storage_clean(), "a failure wipes the buffered words");
        check(rng_en, "the source stays enabled during the retest");
        //  the failure cleared the counts: one more of the same is counted from one
        sym(on_lane(good(), 1));
        look(); check(st_fails == 16'd1 && st_state == 2'd0, "the source stuck for one sample more: counted from one again, no second failure");
        //  nobody reads seed while the retest runs and words are buffered again
        syms(1023 + 128);
        look();
        check(st_state == 2'd1 && dut.fill_q == 4'd8, "retest passed, the buffer is full");
        check(o == BIST && d == 16'b0 && st_alarm, "the alarm is still reported as BIST: the read in the failing cycle did not take it");
        read_only(2'd0);
        check(ro_data[31:30] == BIST, "an access without a write sees the alarm");
        look(); check(o == BIST && st_alarm, "and does not take it");
        seed_is(BIST, "the first seed access after the failure sees BIST");
        check(!st_alarm, "and that access clears the alarm");
        read_words(8, "after it only samples from after the retest are delivered");

        //  a second failure: the alarm again, taken by the first seed access after the retest
        anti(1); pattern(1, 0, RCT);
        ref_restart(1);
        expect_fail(C_RCT, 4'b0001, "the source stuck again");
        check(st_strikes == 3'd2 && st_alarm && st_fails == 16'd2, "second failure: two strikes");
        syms(1024 + 64);
        look(); check(o == BIST && d == 16'b0 && st_alarm, "seed reports the alarm");
        seed_is(BIST, "the first seed access sees BIST");
        check(!st_alarm, "and clears the alarm");
        read_words(4, "the burst follows");

        //  the third running failure, none of them forgiven, is fatal
        anti(1); pattern(1, 0, RCT);
        ref_restart(1);
        look(); check(st_state == 2'd2 && st_strikes == 3'd3 && st_fails == 16'd3 && st_alarm, "the third strike is fatal, and counted");
        seed_is(DEAD, "seed reports DEAD");
        check(!rng_en, "the source is disabled when dead");
        cfgw(cfg(0, 11'd700, 10'd40, 16'd0));
        syms(1100);
        seed_is(DEAD, "dead until reset: a configuration write does not revive it");
        //  raw samples are still available from a dead source, in test mode only
        noisew(NT);
        look(); check(rng_en, "test mode switches a dead source back on");
        check(opst == DEAD, "seed keeps reporting DEAD in test mode");
        op(1, 4'hC, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hC000_000C, "a dead source still gives raw symbols");
        noisew(64'b0);
        look(); check(!rng_en && opst == DEAD, "leaving test mode: off again, still DEAD");

        running();
        anti(1); pattern(1, 0, RCT);
        ref_restart(1);
        seed_is(BIST, "a failure while running");
        check(st_strikes == 3'd1 && st_state == 2'd0, "one strike, start-up test");
        syms(500);
        anti(1); pattern(1, 0, RCT - 1);
        look(); check(st_state == 2'd0, "one repeat short during the retest: still testing");
        sym(on_lane(good(), 1));
        seed_is(DEAD, "a failure during the retest is fatal, whatever the strikes");
        check(st_strikes == 3'd1 && st_fails == 16'd2 && st_state == 2'd2, "status: dead, the strike count as it was");

        //  the source stuck at zero is the same failure
        running();
        for (i = 0; i < 4; i++) sym(on_lane(good(), 1));
        for (i = 0; i < RCT - 1; i++) sym(on_lane(good(), 0));
        look(); check(st_fails == 16'd0 && st_state == 2'd1, "zeros, one short of the cutoff: no failure");
        sym(on_lane(good(), 0));
        ref_restart(1);
        expect_fail(C_RCT, 4'b0001, "the source stuck at zero");

        //  ================= repetition at lags 1 to 4, each lane as the source =================
        //  2^11 clean samples between the failures, so none of them is fatal
        for (int l = 0; l < 4; l++) begin
            running_on(2'(l));
            fails0 = 16'd0;
            for (lag = 1; lag <= 4; lag++) begin
                anti(lag);
                pattern(lag, 0, RCT + lag - 2);
                look(); check(st_fails == fails0 && st_state == 2'd1,
                              $sformatf("lane %0d, period %0d: %0d samples of the pattern are one short", l, lag, RCT + lag - 2));
                sym(on_lane(good(), pat(lag, RCT + lag - 2)));
                ref_restart(1);
                fails0++;
                expect_fail(C_RCT, 4'b1 << (lag - 1), $sformatf("lane %0d, period %0d", l, lag));
                check(st_fails == fails0 && st_strikes == 3'd1 && st_state == 2'd0, "counted, one strike, start-up test");
                syms(2048);
                look(); check(st_strikes == 3'd0 && st_state == 2'd1, "forgiven after 2^11 clean samples");
                seed_is(BIST, "the alarm of that failure");
            end
            read_words(4, "four forgiven failures later the source still delivers");
        end

        //  a restart forgets the samples before it: a pattern that carries on
        //  across a configuration write is counted from the write
        for (lag = 1; lag <= 4; lag++) begin
            reset_on(2'd1);
            pattern(lag, 0, 12);
            cfgw(CFG_RESET);
            pattern(lag, 12, RCT + lag - 2);
            look(); check(st_state == 2'd0 && st_fails == 16'd0,
                          $sformatf("period %0d across a restart: no failure one sample early", lag));
            sym(on_lane(good(), pat(lag, 12 + RCT + lag - 2)));
            look(); check(st_state == 2'd2 && st_lags == (4'b1 << (lag - 1)), "and the failure on the next one (fatal: start-up test)");
        end

        //  ================= the three other lanes are not the source =================
        //  Each fault for two windows and more, on all three at once: no test
        //  sees it, and the words are the source's samples, bit for bit.
        for (int l = 0; l < 4; l += 3) begin
            running_on(2'(l));
            read_words(4, "the first burst");
            elsewhere(0, 2176, $sformatf("source lane %0d, the others stuck at 0", l));
            elsewhere(1, 2176, $sformatf("source lane %0d, the others stuck at 1", l));
            elsewhere(2, 2176, $sformatf("source lane %0d, the others with period 2", l));
            elsewhere(3, 2176, $sformatf("source lane %0d, the others with period 3", l));
            elsewhere(4, 2176, $sformatf("source lane %0d, the others with period 4", l));
            elsewhere(5, 2176, $sformatf("source lane %0d, the others copies of it", l));
            elsewhere(6, 2176, $sformatf("source lane %0d, the others its complement", l));
            check(st_fails == 16'd0 && st_cause == 4'b0 && st_lanes == 4'b0 && st_lags == 4'b0, "nothing was ever reported");
            //  ... and with them stuck, the source's own fault is found as before
            for (i = 0; i < 4; i++) sym(off_lane(on_lane(good(), 0), 1));
            for (i = 0; i < RCT - 1; i++) sym(off_lane(on_lane(good(), 1), 1));
            look(); check(st_fails == 16'd0, "the source one repeat short, the others stuck: no failure");
            sym(off_lane(on_lane(good(), 1), 1));
            ref_restart(1);
            expect_fail(C_RCT, 4'b0001, "the source stuck among stuck lanes: its lane alone is reported");
        end

        //  ================= proportion, window 1024 =================
        running_on(2'd1);
        to_window();
        //  window 1: a one first, and 698 more among the 1023 that follow, at
        //  places drawn at random: 699 in the window, one short
        n = 0;
        for (i = 0; i < 1024; i++) begin
            one = (i == 0) || (rnd(1024 - i) < (APT - 1 - n));
            if (one) n++;
            sym(on_lane(good(), one));
        end
        look(); check(n == APT - 1 && st_fails == 16'd0 && dut.win_idx == 10'd0, "a window with its first bit 699 times: no failure");
        //  window 2 starts with a zero, beside ones on the three other lanes;
        //  ones are three in four of the rest
        sym(off_lane(4'b0, 1));
        for (i = 1; i < 1024; i++) begin
            v = good();
            sym(on_lane(good(), v[3:2] != 2'b00));
        end
        look(); check(st_fails == 16'd0, "a frequent value that is not the window's first: no failure; the count started again");
        //  window 3: a one first, then three ones in four, in no pattern
        n = 0;
        for (i = 0; n < APT - 1; i++) begin
            v = good();
            if (i == 0 || v[3:2] != 2'b00) begin sym(on_lane(good(), 1)); n++; end
            else sym(on_lane(good(), 0));
        end
        look(); check(i < 1023 && st_fails == 16'd0 && st_state == 2'd1, $sformatf("699 ones in %0d samples of the third window: no failure", i));
        sym(on_lane(good(), 0));
        look(); check(st_fails == 16'd0, "a zero does not count");
        sym(on_lane(good(), 1));
        ref_restart(1);
        expect_fail(C_APT, 4'b0000, "the 700th one of the window");
        check(st_state == 2'd0 && st_alarm && st_strikes == 3'd1, "start-up test, alarm, one strike");
        n = 0;
        for (i = 0; n < APT && opst != DEAD; i++) begin
            v = good();
            if (i == 0 || v[3:2] != 2'b00) begin sym(on_lane(good(), 1)); n++; end
            else sym(on_lane(good(), 0));
        end
        check(opst == DEAD && n == APT, "the same bias during the retest is fatal, at the 700th one");
        //  the first bit of a window may be a zero: zeros are counted then
        running();
        to_window();
        n = 0;
        for (i = 0; n < APT - 1; i++) begin
            v = good();
            if (i == 0 || v[3:2] != 2'b00) begin sym(on_lane(good(), 0)); n++; end
            else sym(on_lane(good(), 1));
        end
        look(); check(i < 1023 && st_fails == 16'd0, "699 zeros in a window that starts with a zero: no failure");
        sym(on_lane(good(), 0));
        ref_restart(1);
        expect_fail(C_APT, 4'b0000, "the 700th zero of the window");

        //  ================= strikes =================
        running_on(2'd3);
        //  one strike, forgiven by exactly 2^11 clean samples
        fail_once();
        look(); check(st_strikes == 3'd1, "first failure: one strike");
        syms(2047);
        look(); check(st_strikes == 3'd1, "2047 clean samples: the strike stands");
        syms(1);
        look(); check(st_strikes == 3'd0 && st_fails == 16'd1 && st_alarm, "the 2048th clears it; the failure count and the alarm stay");
        //  clean samples count from the last failure
        fail_once();
        syms(1500);
        fail_once();
        look(); check(st_strikes == 3'd2 && st_state == 2'd0, "two failures 1500 samples apart: two strikes");
        syms(1000);
        look(); check(st_strikes == 3'd2, "1000 clean samples after the second: both stand");
        //  a configuration write clears neither the strikes nor the alarm
        cfgw(CFG_RESET);
        ref_restart(1);
        look(); check(st_strikes == 3'd2 && st_alarm && st_state == 2'd0, "a configuration write keeps the strikes and the alarm");
        syms(1024 + 64);
        seed_is(BIST, "the alarm outlives the restart");
        read_words(4, "words after it");
        //  ... but it starts the count of clean samples again
        syms(800);
        look(); check(st_strikes == 3'd2, "1000 clean samples before and 1888 after the write: not forgiven");
        //  the third strike is fatal, also when a configuration write comes in the same cycle
        anti(1); pattern(1, 0, RCT - 1);
        op(1, on_lane(good(), 1), 0, 1, CFG_RESET, 0, 64'b0);
        look(); check(st_state == 2'd2 && st_fails == 16'd4, "the fatal failure wins over a restart in its cycle");
        seed_is(DEAD, "third strike: DEAD");
        check(st_strikes == 3'd3, "the fatal strike is counted");

        //  the number of strikes is configurable: 5, 1 and 0
        running();
        cfgw(cfgx(0, 5'd11, 3'd5, 11'd700, 10'd40, 16'd0));
        ref_restart(1);
        syms(1024);
        for (i = 1; i <= 5; i++) begin
            fail_once();
            look(); check(st_state == (i == 5 ? 2'd2 : 2'd0) && st_strikes == 3'(i),
                          $sformatf("strikes = 5: failure %0d %s", i, i == 5 ? "is fatal" : "is a strike"));
            syms(1100);
        end
        for (i = 0; i < 2; i++) begin
            running();
            cfgw(cfgx(0, 5'd11, 3'(i), 11'd700, 10'd40, 16'd0));
            ref_restart(1);
            syms(1024 + 64);
            look(); check(o == ES16, "running");
            fail_once();
            seed_is(DEAD, $sformatf("strikes = %0d: the first running failure is fatal", i));
            check(st_strikes == 3'd1 && st_fails == 16'd1, "and reads as one strike");
        end
        //  ... and so is the number of clean samples
        running();
        cfgw(cfgx(0, 5'd12, 3'd3, 11'd700, 10'd40, 16'd0));
        ref_restart(1);
        syms(1024);
        fail_once();
        syms(4095);
        look(); check(st_strikes == 3'd1, "calm = 12: 4095 clean samples do not forgive");
        syms(1);
        look(); check(st_strikes == 3'd0, "the 4096th does");

        //  a cutoff of zero fails on the first sample: fatal
        reset();
        cfgw(cfgx(0, 5'd11, 3'd3, 11'd700, 10'd0, 16'd0));
        seed_is(BIST, "a zero repetition cutoff written");
        sym(good());
        seed_is(DEAD, "the first sample fails it");
        check(st_cause == C_RCT && st_lags == 4'b1111, "by repetition, at every lag");
        reset();
        cfgw(cfgx(0, 5'd11, 3'd3, 11'd0, 10'd40, 16'd0));
        sym(good());
        seed_is(DEAD, "a zero proportion cutoff: the first sample fails it");
        check(st_cause == C_APT && st_lags == 4'b0000, "by proportion");

        //  ================= GetNoise: all four lanes, whichever is the source =================
        reset_on(2'd1);
        look(); check(noise_rdata == 64'd1, "mnoise reads 1 outside test mode");
        syms(1024 + 64);
        look(); check(o == ES16, "words held before test mode");
        noisew(NT);
        seed_is(BIST, "seed is in BIST in test mode");
        check(storage_clean(), "entering test mode wipes the buffered words");
        noisew(NT);
        check(n_rd == 64'h8000_0000, "no symbol yet: valid = 0, loss = 0");
        op(1, 4'hA, 0, 0, 64'b0, 0, 64'b0);
        look(); check(noise_rdata == 64'hC000_000A, "a plain read observes the symbol, all four lanes of it");
        look(); check(noise_rdata == 64'hC000_000A, "a plain read does not take it");
        noise_wdata = 64'b0;
        read_only(2'd1);
        check(ro_data == 64'hC000_000A, "mnoise read without a write returns the symbol");
        look(); check(noise_rdata == 64'hC000_000A, "and neither takes it nor leaves test mode");
        noisew(NT);
        check(n_rd == 64'hC000_000A, "CSRRW returns the symbol");
        look(); check(noise_rdata == 64'h8000_0000, "and has taken it");
        //  a new symbol in the cycle of the CSRRW
        op(1, 4'h5, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h6, 0, 0, 64'b0, 1, NT);
        check(n_rd == 64'hC000_0005, "CSRRW with a symbol arriving: the held symbol is returned");
        noisew(NT);
        check(n_rd == 64'hC000_0006, "the symbol that arrived in that cycle is kept, without loss");
        //  loss
        op(1, 4'h1, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h2, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hE000_0002, "a symbol that was not taken is lost, and that is flagged");
        noisew(NT);
        check(n_rd == 64'hA000_0000, "the loss flag stays set");
        op(1, 4'h3, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hE000_0003, "symbols after a loss still carry the flag");
        //  start a new run
        op(1, 4'h4, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT_NEW);
        check(n_rd == 64'hE000_0004, "the clearing write returns the old state");
        noisew(NT);
        check(n_rd == 64'h8000_0000, "after it: nothing held, loss cleared");
        op(1, 4'h7, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hC000_0007, "new run: consecutive symbols without the flag");
        //  a clearing write with a symbol arriving in the same cycle
        op(1, 4'h8, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h9, 0, 0, 64'b0, 0, 64'b0);     //  loses 8
        op(1, 4'hB, 0, 0, 64'b0, 1, NT_NEW);
        check(n_rd == 64'hE000_0009, "clearing write with a symbol arriving");
        noisew(NT);
        check(n_rd == 64'hC000_000B, "that symbol starts the new run");
        //  the source switched off between two symbols: the run has ended,
        //  although the symbol before the gap was taken and nothing was overwritten
        op(1, 4'h1, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hC000_0001, "a symbol of the run, taken");
        @(negedge clk); en = 0;
        repeat (8) @(negedge clk);
        en = 1;
        look(); check(noise_rdata == 64'hA000_0000, "the source was off for eight clocks: the loss flag is set, nothing held");
        op(1, 4'h2, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hE000_0002, "the symbol after the gap carries the flag: it does not follow the one before");
        noisew(NT_NEW);
        op(1, 4'h3, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hC000_0003, "a clearing write after the gap starts a new run");
        //  a symbol not yet taken when the source stops is dropped
        op(1, 4'h4, 0, 0, 64'b0, 0, 64'b0);
        @(negedge clk); en = 0;
        @(negedge clk); #1;
        check(noise_rdata == 64'hA000_0000, "source off with a symbol held: the symbol is dropped, the flag set");
        //  while the source is off the flag cannot be cleared
        noisew(NT_NEW);
        look(); check(noise_rdata == 64'hA000_0000, "a clearing write while the source is off does not start a run");
        @(negedge clk); en = 1;
        look(); check(noise_rdata == 64'hA000_0000, "source on again: the flag stays until it is cleared");
        noisew(NT_NEW);
        look(); check(noise_rdata == 64'h8000_0000, "cleared");
        //  the source off for the one cycle of a clearing write: the break wins
        @(negedge clk); en = 0; noise_we = 1; noise_wdata = NT_NEW;
        @(negedge clk); en = 1; noise_we = 0;
        look(); check(noise_rdata == 64'hA000_0000, "a clearing write in the cycle the source stops does not hide the break");
        noisew(NT_NEW);
        //  a configuration write restarts the spacing: the run has ended
        op(1, 4'h5, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hC000_0005, "a symbol of the new run, taken");
        cfgw(CFG_RESET);
        look(); check(noise_rdata == 64'hA000_0000, "a configuration write in test mode sets the loss flag");
        op(1, 4'h6, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hE000_0006, "the symbol after it carries the flag");
        op(1, 4'h7, 0, 0, 64'b0, 0, 64'b0);
        cfgw(CFG_RESET);
        look(); check(noise_rdata == 64'hA000_0000, "a symbol held at a configuration write is dropped");
        noisew(NT_NEW);
        //  the platform changes the spacing of the raw symbols: the run has ended
        op(1, 4'h8, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hC000_0008, "a symbol of the new run, taken");
        @(negedge clk); respace = 1;
        @(negedge clk); respace = 0;
        look(); check(noise_rdata == 64'hA000_0000, "a change of the spacing sets the loss flag");
        op(1, 4'h9, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hE000_0009, "the symbol after it carries the flag");
        noisew(NT_NEW);
        //  health tests do not run, and no entropy is delivered, in test mode
        repeat (1200) begin op(1, 4'hF, 0, 0, 64'b0, 0, 64'b0); check(opst == BIST, "BIST throughout test mode"); end
        check(st_fails == 16'd0 && st_state != 2'd2, "a stuck source in test mode is no failure");
        //  decimation applies to GetNoise as well
        noisew(64'b0);
        look(); check(noise_rdata == 64'd1, "left test mode");
        cfgw(cfg(0, 11'd700, 10'd40, 16'd2));
        noisew(NT);
        op(1, 4'h1, 0, 0, 64'b0, 0, 64'b0);
        op(1, 4'h2, 0, 0, 64'b0, 0, 64'b0);
        look(); check(noise_rdata == 64'h8000_0000, "k = 3: the first two symbols are not kept");
        op(1, 4'h3, 0, 0, 64'b0, 0, 64'b0);
        noisew(NT);
        check(n_rd == 64'hC000_0003, "k = 3: the third symbol is the sample");
        //  leaving test mode: start-up test again, then only new data
        noisew(64'b0);
        ref_restart(3);
        seed_is(BIST, "leaving test mode restarts the start-up test");
        syms(3072);
        seed_is(WAITS, "start-up complete after test mode");
        syms(192);
        read_words(4, "after test mode only new samples are delivered");

        //  ================= the platform strap =================
        reset_on(2'd2);
        syms(1024 + 64);
        look(); check(o == ES16 && rng_en, "running before the strap is pulled");
        @(negedge clk); en = 0; #1;
        check(opst == BIST && data == 16'b0, "strap low: BIST in the same cycle");
        check(!rng_en, "strap low: the noise source is disabled");
        @(negedge clk);
        check(storage_clean(), "strap low: buffered words are wiped");
        repeat (1100) begin op(1, 4'h5, 1, 0, 64'b0, 0, 64'b0); check(o == BIST && d == 16'b0, "strap low: BIST whatever the source does"); end
        check(st_fails == 16'd0, "strap low: a stuck source is no failure");
        //  a symbol that arrives with the strap low is not a sample at all:
        //  with a cutoff that the first sample fails, nothing fails until the strap is released
        cfgw(cfgx(0, 5'd11, 3'd3, 11'd700, 10'd1, 16'd0));
        repeat (4) op(1, 4'h3, 0, 0, 64'b0, 0, 64'b0);
        look(); check(st_state == 2'd0 && st_fails == 16'd0 && opst == BIST, "strap low: a symbol is not tested");
        @(negedge clk); en = 1;
        sym(4'h3);
        look(); check(st_state == 2'd2 && st_fails == 16'd1, "strap released: the first sample is, and fails that cutoff");
        reset();
        syms(1024 + 64);
        @(negedge clk); en = 0;
        noisew(NT);
        op(1, 4'h9, 0, 0, 64'b0, 0, 64'b0);
        look(); check(noise_rdata == 64'hA000_0000, "strap low: no raw symbols either, and the loss flag says that no run is in progress");
        noisew(64'b0);
        @(negedge clk); en = 1;
        ref_restart(1);
        syms(1023);
        seed_is(BIST, "strap released: the start-up test runs from the beginning");
        syms(1);
        seed_is(WAITS, "strap released: start-up complete after 1024 samples");
        syms(64);
        read_words(4, "strap released: only new samples are delivered");

        //  ================= time to the first word, default parameters =================
        wait (d_first != 0 || d_opst == DEAD);
        check(d_opst != DEAD, "default-parameter instance is healthy");
        check(dflt.cfg_rdata == {1'b0, 1'b0, 5'd24, 3'd3, 17'd0, 11'd719, 10'd55, 16'd15},
              "default parameters: k = 16, cutoffs 55 and 719, 3 strikes, 2^24 clean samples, nothing in the reserved fields");
        $display("default parameters, one source symbol per 256 clocks: first ES16 %0d clocks after reset (%.1f ms at 75 MHz)",
                 d_first, d_first / 75000.0);
        check(d_first > 4_456_448 - 300 && d_first < 4_456_448 + 300,
              "time to first word = (1024 + 64) samples * 16 * 256 clocks");

        $display("entropy test: PASS (%0d checks)", checks);
        $finish;
    end

    initial begin
        #3_000_000_000;
        $display("FAIL entropy test: timeout");
        $fatal(1);
    end
endmodule
