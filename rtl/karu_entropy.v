//  karu_entropy.v
//  === Entropy source behind the Zkr seed CSR.
//
//  It takes raw symbols from a noise source with OpenTitan's raw interface
//  (rng_en, rng_valid, rng_bits) and delivers 16-bit words in the seed format
//  (OPST + entropy, taken by the access that reads them).
//
//      raw symbols --> keep every k-th --> health tests --> pack 4 symbols
//                           |                                    |
//                           +--> GetNoise (mnoise), test mode    +--> FIFO --> seed
//
//  Bits are never combined. A seed word is 16 raw bits: four consecutive kept
//  symbols of four lanes, each lane one sampled ring oscillator. The only
//  "ratio" is the decimation k. In the model of arXiv:2102.02196 a lane with
//  parameters (F, D, sigma^2) -- D is the duty cycle -- kept at every k-th
//  sample is the same process with (k*F mod 1, D, k*sigma^2). The bits that
//  seed delivers, the bits the health tests see and the bits GetNoise shows
//  are the same bits.
//
//  That is a statement about one lane. It says nothing about the entropy of
//  a word: lanes may depend on each other, and four lanes that each pass
//  their health tests may carry one lane's entropy. The joint behaviour of
//  the lanes has to be measured on the routed design through GetNoise, whose
//  symbols are the four lanes sampled on the same clock edge.
//
//  Health tests (NIST SP 800-90B, section 4; doc/sp800-90b-assessment.md).
//  The noise-source sample of SP 800-90B is the kept 4-bit symbol (section
//  3.1.6: copies of one noise source, concatenated). On every kept symbol:
//
//    on the symbol   repetition count (4.4.1): the same symbol srct times in
//                    a row; adaptive proportion (4.4.2): sapt occurrences of
//                    a window's first symbol in that window of 512
//    on each lane    repetition count at lags 1 to 4: a lane bit equal to
//                    the bit g samples earlier, rct - 1 times in a row (lag
//                    1 is a stuck lane, lags 2 to 4 are patterns of period 2
//                    to 4, such as 0101...); adaptive proportion: apt
//                    occurrences of a window's first bit in that window of
//                    1024
//
//  The two symbol tests are the approved tests. The lane tests are there
//  for failures that the symbol tests cannot see: a symbol with one dead or
//  periodic lane still has three lanes' worth of variation. If a bit has
//  min-entropy h given everything before it, it equals any bit determined by
//  the past with probability at most 2^-h, so the cutoff formula of 4.4.1
//  holds for every lag. Cutoffs for a false-alarm probability a per test
//  and min-entropy H per symbol, h per lane bit:
//      repetition  1 + ceil(-log2(a) / H)
//      proportion  the smallest C with P(1 + B(W-1, 2^-H) >= C) <= a
//  The first symbol of a window always counts, hence 1 + B(W-1, p). The
//  formula of 4.4.2, 1 + CRITBINOM(W, 2^-H, 1 - a), gives one less on the
//  symbol (123 for H = 3), which exceeds a by a factor of 1.4. The reset
//  values are for a = 2^-40, H = 3 bits per symbol and h = 0.75 bit per lane
//  bit: 15 and 124, 55 and 719. test/dbg/board/entropy_health.py computes
//  them.
//
//  Failures. A failure in a start-up test is fatal: DEAD until reset. A
//  failure while running wipes the buffered words and returns to the
//  start-up test, and seed reports BIST from then until one seed access has
//  seen it, however long that takes and whether or not the retest has
//  finished: the alarm of the Zkr text, "latched until polled at least
//  once". Running failures are counted (strikes).
//  2^calm kept symbols in a row without a failure clear the count; the
//  failure that makes the count reach the configured number is fatal. So a
//  fault that keeps coming back ends in DEAD, and one that does not come
//  back for 2^calm symbols is treated as intermittent.
//
//  CSR sideband (csr_sel_i), one committed access per instruction:
//
//  0   seed. Every access is a write form (the core rejects read-only ones)
//      and takes the word it reads. [31:30] OPST, [15:0] entropy when OPST is
//      ES16, everything else zero, including the custom bits [23:16].
//
//  1   mnoise, the GetNoise test interface suggested in the Zkr rationale.
//      Capture uses one instruction, CSRRW rd, mnoise, rs, which returns the
//      status and symbol of that cycle and takes the symbol in the same cycle:
//          write   [31] noise_test: enter (1) or leave (0) test mode
//                  [29] with [31]: also clear the loss flag (start a new run)
//          read    noise_test = 0: constant 1 (present, no samples)
//                  noise_test = 1: [31] 1, [30] symbol valid, [29] loss flag,
//                  [3:0] symbol
//      A symbol that arrives in the cycle of the CSRRW is kept for the next
//      one. The loss flag is set when a symbol replaces one that was not
//      taken, and stays set. It is also set when the source is switched off
//      (the strap), when mentropycfg is written, and when the platform
//      changes the spacing of the raw symbols (respace_i): the rings stop,
//      or the spacing starts again or changes, so the next symbol does not
//      follow the last one even if none was overwritten. A symbol not yet
//      taken is dropped then, and while the source is off the flag cannot
//      be cleared.
//      Symbols returned with valid = 1 and loss = 0 since the last clearing
//      write are consecutive kept samples. After
//      loss = 1 the run has ended: write [31] and [29], discard what that
//      write returns, and the valid symbols after it form a new run. A read
//      without a write only observes. While noise_test is set the seed side
//      stays in BIST and gives no entropy. Test mode also works after the
//      source has failed its tests for good: seed then keeps reporting DEAD,
//      and the raw symbols are there to show why.
//
//  2   mentropycfg, read/write unless locked:
//          [15:0]  interval    k-1: every k-th symbol of the source is kept.
//                              Read back as written. Outside test mode the
//                              source uses at least INTERVAL_MIN
//          [25:16] rct         lane repetition cutoff (<= RCT_MAX)
//          [36:26] apt         lane proportion cutoff, window 1024
//                              (<= APT_MAX)
//          [43:37] srct        symbol repetition cutoff (<= SRCT_MAX)
//          [53:44] sapt        symbol proportion cutoff, window 512
//                              (<= SAPT_MAX; 513 or more could never fire)
//          [56:54] strikes     the running failure that is fatal: the n-th
//                              without 2^calm clean symbols in between
//                              (<= STRIKE_MAX; 0 and 1: the first)
//          [61:57] calm        log2 of the clean symbols that clear the
//                              strike count (>= CALM_MIN)
//          [63]    lock        set-only until reset; freezes this CSR and
//                              noise_test
//      An accepted write empties the FIFO and restarts the start-up test;
//      that is also the on-demand test. It does not clear the strike count
//      or a latched alarm. Values outside the build's limits are replaced
//      by the limit. The limits are one-sided: with the default parameters
//      the reset values are the weakest configuration, and software can only
//      make the tests stricter and the spacing longer. A cutoff of zero
//      fails on the first symbol, which is fatal: a way to switch seed off
//      until reset. So change a field by read-modify-write, never by
//      writing a constant that leaves the other fields zero:
//          csrr  t0, mentropycfg       # keep what is there
//          ...                         # replace the one field in t0
//          csrw  mentropycfg, t0
//          li    t1, 1 << 63           # the lock alone: set that bit
//          csrs  mentropycfg, t1
//
//  3   mentropystat, read-only (writes are ignored):
//          [1:0]   state       0 start-up test, 1 running, 2 dead
//          [2]     alarm       a running failure that no seed access has
//                              seen yet
//          [6:4]   strikes     running failures not yet cleared, the fatal
//                              one included
//          [11:8]  cause       of the last failure: [8] symbol repetition,
//                              [9] symbol proportion, [10] lane repetition,
//                              [11] lane proportion
//          [15:12] lanes       the lanes whose tests failed then
//          [19:16] lags        the lags that failed then ([16] is lag 1)
//          [47:32] failures    since reset, saturating
//
//  Delivery. Consumers poll briefly (Linux 7.4 stops after 100 polls for four
//  words, OpenSBI 1.9 after 1000 unsuccessful ones), so words are buffered and
//  released in bursts of BURST: ES16 appears only when BURST words are held,
//  and stays until that many have been read. Words are wiped as they are read
//  and on every restart or failure. A health failure wins over a read in the
//  same cycle: that read gets no entropy. Nothing is delivered while the
//  alarm is latched. seed is the only way out for a word: the debug
//  authentication ROM reads seed like any other M-mode software.
//
//  en_i is a platform strap. While it is low the noise source is off and
//  seed stays in BIST, which every consumer handles by falling back.
//
//  References: The RISC-V Instruction Set Manual, current text
//  (github.com/riscv/riscv-isa-manual, main; read 2026-11-17 and 2026-11-19):
//    Volume I,  src/unpriv/zk.adoc (commit 8dd6545, 2026-11-10): "The seed
//               CSR" (the BIST alarm and its latch, DEAD), "Entropy Source
//               Requirements", "Security Controls and Health Tests",
//               "Suggested GetNoise Test Interface"; published as
//               docs.riscv.org/reference/isa/unpriv/scalar-crypto.html
//    Volume II, src/priv/machine.adoc: mseccfg SSEED/USEED and the "Entropy
//               Source Access Control" table
//  NIST SP 800-90B (January 2018), sections 3.1.6, 4.3, 4.4.1, 4.4.2.
//  SPDX-License-Identifier: BSD-2-Clause

module karu_entropy #(
    //  Reset values, and the weakest values that software can set. A limit
    //  follows its reset value unless the build says otherwise, so that the
    //  reset configuration is the weakest one.
    parameter [15:0] INTERVAL_RESET = 16'd15,           //  k-1 after reset
    parameter [15:0] INTERVAL_MIN   = INTERVAL_RESET,   //  smallest k-1 outside test mode
    parameter [6:0]  SRCT_RESET     = 7'd15,            //  1 + ceil(40 / 3)
    parameter [6:0]  SRCT_MAX       = SRCT_RESET,
    parameter [9:0]  SAPT_RESET     = 10'd124,          //  P(1 + B(511, 2^-3) >= 124) <= 2^-40
    parameter [9:0]  SAPT_MAX       = SAPT_RESET,
    parameter [9:0]  RCT_RESET      = 10'd55,           //  1 + ceil(40 / 0.75)
    parameter [9:0]  RCT_MAX        = RCT_RESET,
    parameter [10:0] APT_RESET      = 11'd719,          //  P(1 + B(1023, 2^-0.75) >= 719) <= 2^-40
    parameter [10:0] APT_MAX        = APT_RESET,
    parameter [2:0]  STRIKE_RESET   = 3'd3,             //  the third running failure is fatal
    parameter [2:0]  STRIKE_MAX     = STRIKE_RESET,
    parameter [4:0]  CALM_RESET     = 5'd24,            //  2^24 kept symbols: 15 minutes at 18,310/s
    parameter [4:0]  CALM_MIN       = CALM_RESET,
    parameter integer FIFO_LOG2     = 3,        //  8 words
    parameter [2:0]  BURST          = 3'd4      //  words released together: one 64-bit read
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        en_i,            //  platform strap; low holds the source off

    //  raw noise source (OpenTitan: entropy_src_rng_enable/valid/bits, rng_fips)
    output wire        rng_en_o,
    output wire        rng_fips_o,
    input  wire        rng_val_i,
    input  wire [3:0]  rng_b_i,

    //  CSR sideband from the core
    input  wire        csr_fire_i,
    input  wire [1:0]  csr_sel_i,       //  0 seed, 1 mnoise, 2 mentropycfg, 3 mentropystat
    input  wire        csr_we_i,
    input  wire [63:0] csr_wdata_i,
    output wire [63:0] csr_rdata_o,

    //  from a platform block that sets the spacing of the raw symbols (the
    //  burst capture of flow/fpga/karu_noise_burst.v): it changes in this
    //  cycle, which ends a run of GetNoise symbols. Tie low without one.
    input  wire        respace_i,

    //  status, for a platform block that works only in test mode (the burst
    //  capture of flow/fpga/karu_noise_burst.v): noise_test is set, and the
    //  configuration is locked. Both are registers. May be left open.
    output wire        test_o,
    output wire        lock_o
);
    localparam [1:0] SEL_SEED = 2'd0, SEL_NOISE = 2'd1, SEL_CFG = 2'd2, SEL_STAT = 2'd3;
    localparam [1:0] OPST_BIST = 2'd0, OPST_WAIT = 2'd1, OPST_ES16 = 2'd2, OPST_DEAD = 2'd3;
    localparam [1:0] S_BIST = 2'd0, S_RUN = 2'd1, S_DEAD = 2'd2;
    localparam [10:0] STARTUP = 11'd1024;       //  consecutive symbols without a failure
    localparam integer FIFO_WORDS = 1 << FIFO_LOG2;

    wire csr_wr   = csr_fire_i && csr_we_i;
    wire seed_ack = csr_wr && csr_sel_i == SEL_SEED;
    wire noise_we = csr_wr && csr_sel_i == SEL_NOISE;
    wire cfg_we   = csr_wr && csr_sel_i == SEL_CFG;

    //  ---- configuration ----
    reg [15:0] int_q;
    reg [9:0]  rct_q;
    reg [10:0] apt_q;
    reg [6:0]  srct_q;
    reg [9:0]  sapt_q;
    reg [2:0]  strike_q;
    reg [4:0]  calm_q;
    reg        lock_q, test_q;

    wire cfg_write   = cfg_we && !lock_q;
    wire noise_write = noise_we && !lock_q;
    wire test_next   = csr_wdata_i[31];

    //  build limits; with the widest limits a comparison is constant
    /* verilator lint_off UNSIGNED */
    /* verilator lint_off CMPCONST */
    function [15:0] lim_int(input [15:0] v);
        lim_int = (v < INTERVAL_MIN) ? INTERVAL_MIN : v;
    endfunction
    function [9:0] lim_rct(input [9:0] v);
        lim_rct = (v > RCT_MAX) ? RCT_MAX : v;
    endfunction
    function [10:0] lim_apt(input [10:0] v);
        lim_apt = (v > APT_MAX) ? APT_MAX : v;
    endfunction
    function [6:0] lim_srct(input [6:0] v);
        lim_srct = (v > SRCT_MAX) ? SRCT_MAX : v;
    endfunction
    function [9:0] lim_sapt(input [9:0] v);
        lim_sapt = (v > SAPT_MAX) ? SAPT_MAX : v;
    endfunction
    function [2:0] lim_strike(input [2:0] v);
        lim_strike = (v > STRIKE_MAX) ? STRIKE_MAX : v;
    endfunction
    function [4:0] lim_calm(input [4:0] v);
        lim_calm = (v < CALM_MIN) ? CALM_MIN : v;
    endfunction
    /* verilator lint_on CMPCONST */
    /* verilator lint_on UNSIGNED */

    //  a restart wipes everything downstream of the configuration
    wire restart = cfg_write || (noise_write && (test_next != test_q));
    wire hold    = !en_i;

    always @(posedge clk)
        if (rst) begin
            int_q    <= INTERVAL_RESET;
            rct_q    <= lim_rct(RCT_RESET);
            apt_q    <= lim_apt(APT_RESET);
            srct_q   <= lim_srct(SRCT_RESET);
            sapt_q   <= lim_sapt(SAPT_RESET);
            strike_q <= lim_strike(STRIKE_RESET);
            calm_q   <= lim_calm(CALM_RESET);
            lock_q   <= 1'b0;
            test_q   <= 1'b0;
        end else begin
            if (cfg_write) begin
                int_q    <= csr_wdata_i[15:0];
                rct_q    <= lim_rct(csr_wdata_i[25:16]);
                apt_q    <= lim_apt(csr_wdata_i[36:26]);
                srct_q   <= lim_srct(csr_wdata_i[43:37]);
                sapt_q   <= lim_sapt(csr_wdata_i[53:44]);
                strike_q <= lim_strike(csr_wdata_i[56:54]);
                calm_q   <= lim_calm(csr_wdata_i[61:57]);
                lock_q   <= csr_wdata_i[63];
            end
            if (noise_write)
                test_q <= test_next;
        end

    wire [63:0] cfg_rdata = {lock_q, 1'b0, calm_q, strike_q, sapt_q, srct_q, apt_q, rct_q, int_q};

    //  ---- decimation: the kept symbols are what everything below sees ----
    //  The floor on the interval holds wherever seed can deliver. In test mode
    //  seed delivers nothing and the interval is the one written, so that the
    //  source can be characterised at any spacing.
    reg [15:0] int_cnt;
    wire [15:0] int_use = test_q ? int_q : lim_int(int_q);
    wire sym_in = rng_val_i && en_i;
    wire sym_v  = sym_in && (int_cnt == int_use);
    always @(posedge clk)
        if (rst || restart || hold) int_cnt <= 16'd0;
        else if (sym_in)            int_cnt <= sym_v ? 16'd0 : int_cnt + 16'd1;

    //  ---- health tests: on the symbol, and on each lane ----
    reg [1:0]  state_q;
    reg [9:0]  win_idx;                         //  position in the lane window of 1024; [8:0] in the symbol window of 512
    reg [2:0]  seen_q;                          //  symbols since the last restart, up to four
    reg [3:0]  hist [0:3];                      //  the last four symbols, hist[0] the latest
    reg [3:0]  win_ref;                         //  first symbol of the lane window
    reg [3:0]  sapt_ref;                        //  first symbol of the symbol window
    reg [6:0]  srct_cnt;
    reg [9:0]  sapt_cnt;
    reg [9:0]  rct_cnt [0:15];                  //  lane l at lag g+1: [4*l + g]
    reg [10:0] apt_cnt [0:3];
    reg [9:0]  rct_n   [0:15];
    reg [10:0] apt_n   [0:3];
    reg [15:0] rct_fail;                        //  this symbol fails, per lane and lag
    reg [3:0]  apt_fail;                        //  ... per lane
    integer l, g;

    wire       win_first  = (win_idx == 10'd0);
    wire       swin_first = (win_idx[8:0] == 9'd0);
    wire [6:0] srct_n = (seen_q != 3'd0 && rng_b_i == hist[0]) ? srct_cnt + 7'd1 : 7'd1;
    wire [9:0] sapt_n = swin_first            ? 10'd1 :
                        (rng_b_i == sapt_ref) ? sapt_cnt + 10'd1 : sapt_cnt;
    wire       srct_fail = (srct_n >= srct_q);
    wire       sapt_fail = (sapt_n >= sapt_q);

    always @* begin
        for (l = 0; l < 4; l = l + 1) begin
            for (g = 0; g < 4; g = g + 1) begin
                rct_n[4*l+g] = (seen_q > g[2:0] && rng_b_i[l] == hist[g][l]) ? rct_cnt[4*l+g] + 10'd1 : 10'd1;
                rct_fail[4*l+g] = (rct_n[4*l+g] >= rct_q);
            end
            apt_n[l] = win_first                  ? 11'd1 :
                       (rng_b_i[l] == win_ref[l]) ? apt_cnt[l] + 11'd1 : apt_cnt[l];
            apt_fail[l] = (apt_n[l] >= apt_q);
        end
    end

    //  what failed: the tests, the lanes and the lags
    wire [3:0] lane_rct  = {|rct_fail[15:12], |rct_fail[11:8], |rct_fail[7:4], |rct_fail[3:0]};
    wire [3:0] lag_rct   = rct_fail[15:12] | rct_fail[11:8] | rct_fail[7:4] | rct_fail[3:0];
    wire [3:0] cause     = {|apt_fail, |rct_fail, sapt_fail, srct_fail};

    wire test_run = sym_v && !test_q && (state_q != S_DEAD);
    wire fail     = test_run && (|cause);
    wire clear    = restart || fail || hold;    //  health and output state back to empty

    always @(posedge clk)
        if (rst || clear) begin
            win_idx <= 10'd0; seen_q <= 3'd0; srct_cnt <= 7'd0; sapt_cnt <= 10'd0;
            for (l = 0; l < 16; l = l + 1) rct_cnt[l] <= 10'd0;
            for (l = 0; l < 4; l = l + 1) apt_cnt[l] <= 11'd0;
            if (rst) begin
                win_ref <= 4'b0; sapt_ref <= 4'b0;
                for (l = 0; l < 4; l = l + 1) hist[l] <= 4'b0;
            end
        end else if (test_run) begin
            if (seen_q != 3'd4) seen_q <= seen_q + 3'd1;
            hist[0] <= rng_b_i; hist[1] <= hist[0]; hist[2] <= hist[1]; hist[3] <= hist[2];
            if (win_first)  win_ref  <= rng_b_i;
            if (swin_first) sapt_ref <= rng_b_i;
            win_idx  <= win_idx + 10'd1;        //  wraps at 1024
            srct_cnt <= srct_n;
            sapt_cnt <= sapt_n;
            for (l = 0; l < 16; l = l + 1) rct_cnt[l] <= rct_n[l];
            for (l = 0; l < 4; l = l + 1) apt_cnt[l] <= apt_n[l];
        end

    //  ---- strikes: running failures that have not been cleared ----
    //  The strike count and the alarm are not touched by a restart: only a
    //  reset, clean symbols or a seed access change them.
    reg [2:0]  strike_cnt;
    reg [31:0] calm_cnt;                        //  clean symbols since the last failure, while there are strikes
    wire run_fail = fail && (state_q == S_RUN);
    wire fatal    = fail && ((state_q == S_BIST) || ({1'b0, strike_cnt} + 4'd1 >= {1'b0, strike_q}));
    wire [31:0] calm_n = calm_cnt + 32'd1;

    always @(posedge clk)
        if (rst) begin
            strike_cnt <= 3'd0; calm_cnt <= 32'd0;
        end else if (fail) begin
            calm_cnt <= 32'd0;
            if (run_fail) strike_cnt <= strike_cnt + 3'd1;     //  the fatal one too: at most 7
        end else if (restart) begin
            calm_cnt <= 32'd0;
        end else if (test_run && strike_cnt != 3'd0) begin
            if (calm_n[calm_q]) begin strike_cnt <= 3'd0; calm_cnt <= 32'd0; end
            else                calm_cnt <= calm_n;
        end

    //  ---- the alarm: a running failure, held until a seed access has seen it ----
    //  Only seed: an access through the authentication block's port is not
    //  a poll of seed and leaves the alarm for seed's reader.
    reg alarm_q;
    always @(posedge clk)
        if (rst)           alarm_q <= 1'b0;
        else if (run_fail) alarm_q <= 1'b1;     //  a failure wins over an access in the same cycle
        else if (seed_ack) alarm_q <= 1'b0;

    //  ---- what the last failure was, and how many there have been ----
    reg [3:0]  cause_q, lanes_q, lags_q;
    reg [15:0] fails_q;
    always @(posedge clk)
        if (rst) begin
            cause_q <= 4'b0; lanes_q <= 4'b0; lags_q <= 4'b0; fails_q <= 16'd0;
        end else if (fail) begin
            cause_q <= cause; lanes_q <= lane_rct | apt_fail; lags_q <= lag_rct;
            if (fails_q != 16'hffff) fails_q <= fails_q + 16'd1;
        end

    //  ---- state: start-up test, running, dead ----
    //  A failure while running returns to the start-up test, unless it is the
    //  one that uses up the strikes. A failure during a start-up test is
    //  fatal. Dead is until reset. A fatal failure wins over a restart in the
    //  same cycle.
    reg [10:0] bist_cnt;
    always @(posedge clk)
        if (rst) begin
            state_q <= S_BIST; bist_cnt <= 11'd0;
        end else if (state_q == S_DEAD || fatal) begin
            state_q <= S_DEAD;
        end else if (restart || hold || fail) begin
            state_q <= S_BIST; bist_cnt <= 11'd0;
        end else if (test_run && state_q == S_BIST) begin
            if (bist_cnt == STARTUP - 11'd1) state_q <= S_RUN;
            bist_cnt <= bist_cnt + 11'd1;
        end

    //  ---- pack four raw symbols into a word; no bit is combined with another ----
    reg [11:0] part_q;                          //  the first three symbols of a word
    reg [1:0]  nib_cnt;
    reg [15:0] fifo [0:FIFO_WORDS-1];
    reg [FIFO_LOG2:0]   fill_q;
    reg [FIFO_LOG2-1:0] rd_q, wr_q;
    reg [2:0]  burst_q;                         //  words still owed to the open burst
    wire full    = (fill_q == FIFO_WORDS[FIFO_LOG2:0]);
    wire take    = test_run && (state_q == S_RUN) && !full && !fail;
    wire push    = take && (nib_cnt == 2'd3);
    //  No delivery in a cycle in which a health failure wipes the words: the
    //  failure wins over the read. A restart is deliberately not in this
    //  term. It comes from a CSR write, which the same hart cannot make in
    //  the cycle of a seed read, and it depends on the value being written.
    //  With it here, the value read from seed would depend combinationally on
    //  the written value, and a CSR set or clear instruction computes the
    //  written value from the read one: a combinational loop through the
    //  core. Nothing that reaches csr_rdata_o may depend on csr_wdata_i,
    //  csr_we_i or csr_fire_i (make zkr-loop-test).
    wire deliver = (burst_q != 3'd0) && (state_q == S_RUN) && !test_q && !fail && !hold;
    wire pop     = deliver && seed_ack && !alarm_q;
    wire [FIFO_LOG2:0] fill_n = fill_q + {{FIFO_LOG2{1'b0}}, push} - {{FIFO_LOG2{1'b0}}, pop};
    wire [2:0] burst_n = burst_q - {2'b0, pop};
    integer w;

    always @(posedge clk)
        if (rst) begin
            part_q <= 12'b0; nib_cnt <= 2'd0; fill_q <= {(FIFO_LOG2+1){1'b0}};
            rd_q <= {FIFO_LOG2{1'b0}}; wr_q <= {FIFO_LOG2{1'b0}}; burst_q <= 3'd0;
            for (w = 0; w < FIFO_WORDS; w = w + 1) fifo[w] <= 16'b0;
        end else if (clear || state_q != S_RUN) begin
            part_q <= 12'b0; nib_cnt <= 2'd0; fill_q <= {(FIFO_LOG2+1){1'b0}};
            rd_q <= {FIFO_LOG2{1'b0}}; wr_q <= {FIFO_LOG2{1'b0}}; burst_q <= 3'd0;
            for (w = 0; w < FIFO_WORDS; w = w + 1) fifo[w] <= 16'b0;
        end else begin
            if (take) begin
                nib_cnt <= nib_cnt + 2'd1;
                part_q  <= push ? 12'b0 : {part_q[7:0], rng_b_i};
            end
            if (push) begin
                fifo[wr_q] <= {part_q, rng_b_i};
                wr_q <= wr_q + 1'b1;
            end
            if (pop) begin                      //  wipe on read
                fifo[rd_q] <= 16'b0;
                rd_q <= rd_q + 1'b1;
            end
            fill_q <= fill_n;
            //  a burst opens only when it can be served in full without refill
            if (burst_n == 3'd0 && fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST})
                burst_q <= BURST;
            else
                burst_q <= burst_n;
        end

    //  What seed reports: DEAD first, then BIST for the start-up test, test
    //  mode, the strap and a latched alarm.
    wire [1:0]  seed_opst = (state_q == S_DEAD)           ? OPST_DEAD :
                            (test_q || hold || state_q == S_BIST || alarm_q) ? OPST_BIST :
                            deliver                       ? OPST_ES16 : OPST_WAIT;
    wire [15:0] seed_data = (seed_opst == OPST_ES16) ? fifo[rd_q] : 16'b0;

    //  ---- GetNoise: one raw symbol at a time, with a loss indicator ----
    reg [3:0] raw_q;
    reg       raw_v, raw_lost;
    wire raw_pop = noise_write && test_q && test_next;      //  CSRRW that stays in test mode
    wire raw_new = raw_pop && csr_wdata_i[29];              //  ... and starts a new run
    //  A run also ends when the source stops (the strap), when its spacing
    //  starts again (a configuration write) or when the platform changes it:
    //  the symbol after that does not follow the one before it at the same
    //  distance, whether or not one was overwritten.
    wire raw_break = hold || cfg_write || respace_i;
    always @(posedge clk)
        if (rst || !test_q || (noise_write && !test_next)) begin
            raw_q <= 4'b0; raw_v <= 1'b0; raw_lost <= 1'b0;
        end else begin
            if (raw_pop) begin raw_v <= 1'b0; raw_q <= 4'b0; end
            if (raw_new) raw_lost <= 1'b0;
            if (sym_v) begin                    //  a symbol in the cycle of a pop is kept
                if (raw_v && !raw_pop) raw_lost <= 1'b1;
                raw_q <= rng_b_i; raw_v <= 1'b1;
            end
            if (raw_break) begin                //  wins over a clearing write and over a symbol
                raw_lost <= 1'b1; raw_v <= 1'b0; raw_q <= 4'b0;
            end
        end

    wire [63:0] noise_rdata = test_q ? {32'b0, 1'b1, raw_v, raw_lost, 25'b0, raw_q} : 64'd1;
    wire [63:0] seed_rdata  = {32'b0, seed_opst, 14'b0, seed_data};
    wire [63:0] stat_rdata  = {16'b0, fails_q, 12'b0, lags_q, lanes_q, cause_q, 1'b0, strike_cnt, 1'b0, alarm_q, state_q};

    assign csr_rdata_o = (csr_sel_i == SEL_SEED)  ? seed_rdata  :
                         (csr_sel_i == SEL_NOISE) ? noise_rdata :
                         (csr_sel_i == SEL_CFG)   ? cfg_rdata   : stat_rdata;

    //  A dead source is switched off, except in test mode: raw samples are
    //  what one needs to find out why it died. seed stays DEAD regardless.
    assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);
    assign rng_fips_o = 1'b0;
    assign test_o     = test_q;
    assign lock_o     = lock_q;

`ifndef KARU_NO_ASSERT
    // synthesis translate_off
    integer a;
    reg was_dead, was_alarm, was_ack;
    always @(posedge clk) begin
        was_dead  <= !rst && (state_q == S_DEAD);
        was_alarm <= !rst && alarm_q;
        was_ack   <= seed_ack;
    end
    always @(posedge clk) if (!rst) begin
        if (test_q && seed_opst == OPST_ES16) begin
            $display("ASSERT: karu_entropy: ES16 while noise_test is set"); $fatal;
        end
        if (seed_opst != OPST_ES16 && seed_data != 16'b0) begin
            $display("ASSERT: karu_entropy: entropy bits outside ES16"); $fatal;
        end
        if (state_q != S_RUN && (fill_q != 0 || burst_q != 3'd0 || part_q != 12'b0)) begin
            $display("ASSERT: karu_entropy: output state outside RUN"); $fatal;
        end
        if ({1'b0, burst_q} > fill_q) begin
            $display("ASSERT: karu_entropy: open burst exceeds the buffered words"); $fatal;
        end
        if (pop && fail) begin
            $display("ASSERT: karu_entropy: a word was delivered in the cycle of a health failure"); $fatal;
        end
        if (hold && (seed_opst == OPST_ES16 || seed_opst == OPST_WAIT)) begin
            $display("ASSERT: karu_entropy: not in BIST while the source is held off"); $fatal;
        end
        if (alarm_q && (seed_opst == OPST_ES16 || seed_opst == OPST_WAIT)) begin
            $display("ASSERT: karu_entropy: a latched alarm is not reported as BIST by seed"); $fatal;
        end
        if (alarm_q && seed_ack && pop) begin
            $display("ASSERT: karu_entropy: the seed access that takes the alarm took a word"); $fatal;
        end
        if (was_dead && state_q != S_DEAD) begin
            $display("ASSERT: karu_entropy: left DEAD without a reset"); $fatal;
        end
        if (was_alarm && !alarm_q && !was_ack) begin
            $display("ASSERT: karu_entropy: an alarm was cleared without a seed access"); $fatal;
        end
        //  a count at its cutoff is a failure, and a failure clears the counts
        if ((srct_cnt != 7'd0 && srct_cnt >= srct_q) || (sapt_cnt != 10'd0 && sapt_cnt >= sapt_q)) begin
            $display("ASSERT: karu_entropy: a symbol count at its cutoff survived"); $fatal;
        end
        for (a = 0; a < 16; a = a + 1)
            if (rct_cnt[a] != 10'd0 && rct_cnt[a] >= rct_q) begin
                $display("ASSERT: karu_entropy: a lane repetition count at its cutoff survived"); $fatal;
            end
        for (a = 0; a < 4; a = a + 1)
            if (apt_cnt[a] != 11'd0 && apt_cnt[a] >= apt_q) begin
                $display("ASSERT: karu_entropy: a lane proportion count at its cutoff survived"); $fatal;
            end
        if (state_q != S_DEAD && strike_cnt != 3'd0 && {1'b0, strike_cnt} + 4'd1 > {1'b0, STRIKE_MAX}) begin
            $display("ASSERT: karu_entropy: more strikes than the build allows, and not dead"); $fatal;
        end
        if (strike_cnt > STRIKE_MAX && STRIKE_MAX != 3'd0) begin
            $display("ASSERT: karu_entropy: the strike count passed the build limit"); $fatal;
        end
    end
    // synthesis translate_on
`endif
endmodule
