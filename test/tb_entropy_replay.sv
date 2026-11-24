//  tb_entropy_replay.sv -- rtl/karu_entropy.v against its reference model
//  (test/dbg/board/entropy_health.py), on the same symbols: make entropy-test,
//  driven by test/entropy_replay.py.
//
//      +file=<path>    one 4-bit symbol per byte; every symbol is kept (k = 1)
//      +lane=<n>       the strap lane_i: the lane of the symbols that is the
//                      noise source (0 without it)
//      +cfg=<hex>      the mentropycfg value to run with; the limits of this
//                      instance are the widest, so any value is taken
//      +out=<path>     one line "index mentropystat" per failure, index
//                      counting symbols from 0, then "end count mentropystat"
//                      and "words count check": the words that the seed
//                      accesses took, and a running check value of them
//      +poll=<n>       a seed access every n symbols (0: none)
//      +rows=<n>       restart data: the block is reset before every n-th
//                      symbol, so each row of n symbols starts from reset
//
//  A failure is taken from the module's own fail term; what is compared with
//  the model is where it happens, the status register after it, and every
//  word delivered.
//  SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_entropy_replay;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        rng_val = 0, fire = 0, we = 0;
    logic [3:0]  rng_b = 0;
    logic [1:0]  sel = 0, lane = 0;
    logic [63:0] wdata = 0;
    wire  [63:0] rdata;

    karu_entropy #(.INTERVAL_RESET(16'd0), .INTERVAL_MIN(16'd0),
                   .RCT_MAX(10'd1023), .APT_MAX(11'd1024), .STRIKE_MAX(3'd7), .CALM_MIN(5'd0)) dut (
        .clk(clk), .rst(rst), .en_i(1'b1), .lane_i(lane), .kshift_i(2'd0), .rng_en_o(), .rng_fips_o(),
        .rng_val_i(rng_val), .rng_b_i(rng_b),
        .csr_fire_i(fire), .csr_sel_i(sel), .csr_we_i(we), .csr_wdata_i(wdata),
        .csr_rdata_o(rdata), .respace_i(1'b0), .test_o(), .lock_o());

    string       file, out;
    logic [63:0] cfg;
    int          fd, od, c, n = 0, poll = 0, rows = 0, words = 0, lane_arg = 0;
    longint unsigned acc = 0;
    bit          failed;

    task automatic start();             //  out of reset, with the configuration written
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk); fire = 1; we = 1; sel = 2'd2; wdata = cfg;
        @(negedge clk); fire = 0; we = 0;
        if (dut.cfg_rdata != cfg) begin
            $display("FAIL entropy replay: configuration %016x was taken as %016x", cfg, dut.cfg_rdata); $fatal(1);
        end
    endtask

    initial begin
        if (!$value$plusargs("file=%s", file) || !$value$plusargs("out=%s", out) || !$value$plusargs("cfg=%h", cfg)) begin
            $display("FAIL entropy replay: +file, +out and +cfg are needed"); $fatal(1);
        end
        void'($value$plusargs("poll=%d", poll));
        void'($value$plusargs("rows=%d", rows));
        void'($value$plusargs("lane=%d", lane_arg));
        lane = lane_arg[1:0];           //  set under reset, and never changed
        fd = $fopen(file, "rb"); od = $fopen(out, "w");
        if (fd == 0 || od == 0) begin $display("FAIL entropy replay: cannot open %s or %s", file, out); $fatal(1); end
        start();
        c = $fgetc(fd);
        while (c >= 0) begin
            if (rows != 0 && n != 0 && n % rows == 0) begin     //  the next restart
                rng_val = 0; fire = 0; we = 0; rst = 1;
                start();
            end
            rng_val = 1; rng_b = c[3:0];
            fire = (poll != 0 && n % poll == poll - 1); we = fire; sel = 2'd0;
            #1; failed = dut.fail;
            if (fire && rdata[31:30] == 2'd2) begin words++; acc = acc * 64'h0000_0100_0000_01b3 + {48'b0, rdata[15:0]}; end
            @(negedge clk);
            if (failed) $fdisplay(od, "%0d %016x", n, dut.stat_rdata);
            n++;
            c = $fgetc(fd);
        end
        rng_val = 0; fire = 0; we = 0;
        $fdisplay(od, "end %0d %016x", n, dut.stat_rdata);
        $fdisplay(od, "words %0d %016x", words, acc);
        $fclose(od);
        $display("entropy replay: %0d symbols, lane %0d, %0d failures, state %0d, %0d words (check %016x)",
                 n, lane, dut.stat_rdata[47:32], dut.stat_rdata[1:0], words, acc);
        $finish;
    end
endmodule
