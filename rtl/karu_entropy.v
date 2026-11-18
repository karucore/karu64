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
//      taken, and stays set. Symbols returned with valid = 1 and loss = 0
//      since the last clearing write are consecutive kept samples. After
//      loss = 1 the run has ended: write [31] and [29], discard what that
//      write returns, and the valid symbols after it form a new run. A read
//      without a write only observes. While noise_test is set the seed side
//      stays in BIST and gives no entropy. Test mode also works after the
//      source has failed its tests for good: seed then keeps reporting DEAD,
//      and the raw symbols are there to show why.
//
//  2   mentropycfg, read/write unless locked:
//          [15:0]  interval    k-1: every k-th symbol of the source is kept
//          [25:16] rct         repetition count cutoff, per lane (<= RCT_MAX)
//          [36:26] apt         adaptive proportion cutoff, per lane, window
//                              1024 (<= APT_MAX)
//          [63]    lock        set-only until reset; freezes this CSR and
//                              noise_test
//      An accepted write empties the FIFO and restarts the start-up test.
//      Values outside the build's limits are replaced by the limit.
//
//  Delivery. Consumers poll briefly (Linux 7.4 stops after 100 polls for four
//  words, OpenSBI 1.9 after 1000 unsuccessful ones), so words are buffered and
//  released in bursts of BURST: ES16 appears only when BURST words are held,
//  and stays until that many have been read. Words are wiped as they are read
//  and on every restart or failure. A health failure wins over a read in the
//  same cycle: that read gets no entropy.
//
//  en_i is a platform strap. While it is low the noise source is off and
//  seed stays in BIST, which every consumer handles by falling back.
//
//  References: The RISC-V Instruction Set Manual, current text
//  (github.com/riscv/riscv-isa-manual, main; read 2026-11-17):
//    Volume I,  src/unpriv/zk.adoc (commit 8dd6545, 2026-11-10): "The seed
//               CSR", "Entropy Source Requirements", "Suggested GetNoise Test
//               Interface"; published as
//               docs.riscv.org/reference/isa/unpriv/scalar-crypto.html
//    Volume II, src/priv/machine.adoc: mseccfg SSEED/USEED and the "Entropy
//               Source Access Control" table
//  SPDX-License-Identifier: BSD-2-Clause

module karu_entropy #(
    parameter [15:0] INTERVAL_RESET = 16'd15,   //  k-1 after reset
    parameter [15:0] INTERVAL_MIN   = 16'd0,    //  smallest k-1 that software can set
    parameter [9:0]  RCT_RESET      = 10'd41,   //  1 + ceil(20 / 0.5)
    parameter [9:0]  RCT_MAX        = 10'd1023, //  loosest cutoff that software can set
    parameter [10:0] APT_RESET      = 11'd821,  //  provisional
    parameter [10:0] APT_MAX        = 11'd1024, //  1025 or more could never fire
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
    input  wire [1:0]  csr_sel_i,       //  0 seed, 1 mnoise, 2 mentropycfg
    input  wire        csr_we_i,
    input  wire [63:0] csr_wdata_i,
    output wire [63:0] csr_rdata_o,

    //  the same words for the debug authentication block (its trng_* port)
    output wire [1:0]  opst_o,
    output wire [15:0] data_o,
    input  wire        trng_ack_i
);
    localparam [1:0] SEL_SEED = 2'd0, SEL_NOISE = 2'd1, SEL_CFG = 2'd2;
    localparam [1:0] OPST_BIST = 2'd0, OPST_WAIT = 2'd1, OPST_ES16 = 2'd2, OPST_DEAD = 2'd3;
    localparam [1:0] S_BIST = 2'd0, S_RUN = 2'd1, S_DEAD = 2'd2;
    localparam [10:0] STARTUP = 11'd1024;       //  consecutive symbols without a failure
    localparam integer FIFO_WORDS = 1 << FIFO_LOG2;

    wire csr_wr   = csr_fire_i && csr_we_i;
    wire ack      = (csr_wr && csr_sel_i == SEL_SEED) || trng_ack_i;
    wire noise_we = csr_wr && csr_sel_i == SEL_NOISE;
    wire cfg_we   = csr_wr && csr_sel_i == SEL_CFG;

    //  ---- configuration ----
    reg [15:0] int_q;
    reg [9:0]  rct_q;
    reg [10:0] apt_q;
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
    /* verilator lint_on CMPCONST */
    /* verilator lint_on UNSIGNED */

    //  a restart wipes everything downstream of the configuration
    wire restart = cfg_write || (noise_write && (test_next != test_q));
    wire hold    = !en_i;

    always @(posedge clk)
        if (rst) begin
            int_q  <= lim_int(INTERVAL_RESET);
            rct_q  <= lim_rct(RCT_RESET);
            apt_q  <= lim_apt(APT_RESET);
            lock_q <= 1'b0;
            test_q <= 1'b0;
        end else begin
            if (cfg_write) begin
                int_q  <= lim_int(csr_wdata_i[15:0]);
                rct_q  <= lim_rct(csr_wdata_i[25:16]);
                apt_q  <= lim_apt(csr_wdata_i[36:26]);
                lock_q <= csr_wdata_i[63];
            end
            if (noise_write)
                test_q <= test_next;
        end

    wire [63:0] cfg_rdata = {lock_q, 26'b0, apt_q, rct_q, int_q};

    //  ---- decimation: the kept symbols are what everything below sees ----
    reg [15:0] int_cnt;
    wire sym_in = rng_val_i && en_i;
    wire sym_v  = sym_in && (int_cnt == int_q);
    always @(posedge clk)
        if (rst || restart || hold) int_cnt <= 16'd0;
        else if (sym_in)            int_cnt <= sym_v ? 16'd0 : int_cnt + 16'd1;

    //  ---- health tests, per lane ----
    reg [1:0]  state_q;
    reg [9:0]  apt_idx;                         //  position in the 1024-symbol window
    reg [3:0]  rct_last, apt_ref;
    reg [9:0]  rct_cnt [0:3];
    reg [10:0] apt_cnt [0:3];
    reg [3:0]  rct_fail, apt_fail;              //  this symbol fails, per lane
    reg [9:0]  rct_n   [0:3];
    reg [10:0] apt_n   [0:3];
    reg        seen_q;                          //  a symbol since the last restart
    integer l;

    always @* begin
        for (l = 0; l < 4; l = l + 1) begin
            rct_n[l] = (seen_q && rng_b_i[l] == rct_last[l]) ? rct_cnt[l] + 10'd1 : 10'd1;
            apt_n[l] = (apt_idx == 10'd0)         ? 11'd1 :
                       (rng_b_i[l] == apt_ref[l]) ? apt_cnt[l] + 11'd1 : apt_cnt[l];
            rct_fail[l] = (rct_n[l] >= rct_q);
            apt_fail[l] = (apt_n[l] >= apt_q);
        end
    end

    wire test_run = sym_v && !test_q && (state_q != S_DEAD);
    wire fail     = test_run && ((|rct_fail) || (|apt_fail));
    wire clear    = restart || fail || hold;    //  health and output state back to empty

    always @(posedge clk)
        if (rst) begin
            apt_idx <= 10'd0; rct_last <= 4'b0; apt_ref <= 4'b0; seen_q <= 1'b0;
            for (l = 0; l < 4; l = l + 1) begin rct_cnt[l] <= 10'd0; apt_cnt[l] <= 11'd0; end
        end else if (clear) begin
            apt_idx <= 10'd0; seen_q <= 1'b0;
            for (l = 0; l < 4; l = l + 1) begin rct_cnt[l] <= 10'd0; apt_cnt[l] <= 11'd0; end
        end else if (test_run) begin
            seen_q   <= 1'b1;
            rct_last <= rng_b_i;
            if (apt_idx == 10'd0) apt_ref <= rng_b_i;
            apt_idx  <= apt_idx + 10'd1;        //  wraps at 1024
            for (l = 0; l < 4; l = l + 1) begin rct_cnt[l] <= rct_n[l]; apt_cnt[l] <= apt_n[l]; end
        end

    //  ---- state: start-up test, running, dead ----
    //  A failure while running returns to the start-up test. A failure during
    //  the start-up test is fatal until reset.
    reg [10:0] bist_cnt;
    always @(posedge clk)
        if (rst) begin
            state_q <= S_BIST; bist_cnt <= 11'd0;
        end else if (state_q == S_DEAD) begin
            state_q <= S_DEAD;
        end else if (restart || hold) begin
            state_q <= S_BIST; bist_cnt <= 11'd0;
        end else if (fail) begin
            state_q <= (state_q == S_BIST) ? S_DEAD : S_BIST;
            bist_cnt <= 11'd0;
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
    wire pop     = ack && deliver;
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

    assign opst_o = (state_q == S_DEAD)           ? OPST_DEAD :
                    (test_q || hold || state_q == S_BIST) ? OPST_BIST :
                    deliver                       ? OPST_ES16 : OPST_WAIT;
    assign data_o = (opst_o == OPST_ES16) ? fifo[rd_q] : 16'b0;

    //  ---- GetNoise: one raw symbol at a time, with a loss indicator ----
    reg [3:0] raw_q;
    reg       raw_v, raw_lost;
    wire raw_pop = noise_write && test_q && test_next;      //  CSRRW that stays in test mode
    wire raw_new = raw_pop && csr_wdata_i[29];              //  ... and starts a new run
    always @(posedge clk)
        if (rst || !test_q || restart) begin
            raw_q <= 4'b0; raw_v <= 1'b0; raw_lost <= 1'b0;
        end else begin
            if (raw_pop) begin raw_v <= 1'b0; raw_q <= 4'b0; end
            if (raw_new) raw_lost <= 1'b0;
            if (sym_v) begin                    //  a symbol in the cycle of a pop is kept
                if (raw_v && !raw_pop) raw_lost <= 1'b1;
                raw_q <= rng_b_i; raw_v <= 1'b1;
            end
        end

    wire [63:0] noise_rdata = test_q ? {32'b0, 1'b1, raw_v, raw_lost, 25'b0, raw_q} : 64'd1;
    wire [63:0] seed_rdata  = {32'b0, opst_o, 14'b0, data_o};

    assign csr_rdata_o = (csr_sel_i == SEL_SEED)  ? seed_rdata  :
                         (csr_sel_i == SEL_NOISE) ? noise_rdata :
                         (csr_sel_i == SEL_CFG)   ? cfg_rdata   : 64'b0;

    //  A dead source is switched off, except in test mode: raw samples are
    //  what one needs to find out why it died. seed stays DEAD regardless.
    assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);
    assign rng_fips_o = 1'b0;

`ifndef KARU_NO_ASSERT
    // synthesis translate_off
    always @(posedge clk) if (!rst) begin
        if (test_q && opst_o == OPST_ES16) begin
            $display("ASSERT: karu_entropy: ES16 while noise_test is set"); $fatal;
        end
        if (opst_o != OPST_ES16 && data_o != 16'b0) begin
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
        if (hold && (opst_o == OPST_ES16 || opst_o == OPST_WAIT)) begin
            $display("ASSERT: karu_entropy: not in BIST while the source is held off"); $fatal;
        end
    end
    // synthesis translate_on
`endif
endmodule
