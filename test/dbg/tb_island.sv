// karudbg_island hostile-response tests (plan lemma C9, cut K3). External R
// and B beats are injected before, at and after every island request's
// acceptance, continuously or at seeded random cycles; island requests must
// complete only with island data, and no external beat may be consumed
// outside an outstanding external transaction. A clean phase then checks
// that ordinary external traffic still passes through. Further phases add
// random R/B backpressure on the core side, reset while island and external
// transactions are outstanding, and a pipelined master whose next address
// is accepted in the same cycle as the previous final response.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karu_axi_defs.vh"
module tb_island;
    localparam [31:0] ROM = 32'h0001_0000, SRAM = 32'h0002_0000, EXT = 32'h8000_0000;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    // up side (core)
    reg [3:0] iarid = 0, darid = 0, dawid = 0;
    reg [31:0] iaraddr = 0, daraddr = 0, dawaddr = 0;
    reg iarvalid = 0, darvalid = 0, dawvalid = 0, dwvalid = 0;
    reg [63:0] dwdata = 0;
    reg [7:0] dwstrb = 8'hff;
    wire iarready, darready, dawready, dwready;
    wire [3:0] irid, drid, dbid;
    wire [63:0] irdata, drdata;
    wire [1:0] irresp, drresp, dbresp;
    wire irlast, irvalid, drlast, drvalid, dbvalid;
    // down side (external, adversarial)
    wire [3:0] xiarid, xdarid, xdawid;
    wire [31:0] xiaraddr, xdaraddr, xdawaddr;
    wire [7:0] xiarlen, xdarlen, xdawlen;
    wire [2:0] xiarsize, xdarsize, xdawsize, xiarprot, xdarprot, xdawprot;
    wire [1:0] xiarburst, xdarburst, xdawburst;
    wire xiarvalid, xdarvalid, xdawvalid, xdwvalid, xdwlast, xirready, xdrready, xdbready;
    wire [63:0] xdwdata;
    wire [7:0] xdwstrb;
    reg xiarready = 1, xdarready = 1, xdawready = 1, xdwready = 1;
    reg xirvalid = 0, xdrvalid = 0, xdbvalid = 0, xirlast = 1, xdrlast = 1;
    reg [63:0] xirdata = 0, xdrdata = 0;
    reg [1:0] xirresp = 0, xdrresp = 0, xdbresp = 0;
    integer checks = 0, hostile = 0, seed = 1, junk_seen = 0;
    reg irready = 1, drready = 1, dbready = 1;
    integer bp = 0;                         // random core-side backpressure
    always @(negedge clk) if (bp != 0) begin
        irready = $random(seed) & 1; drready = $random(seed) & 1; dbready = $random(seed) & 1;
    end

    karudbg_island dut (
        .clk(clk), .rst(rst),
        .up_imem_arid(iarid), .up_imem_araddr(iaraddr), .up_imem_arlen(8'd0), .up_imem_arsize(3'd3),
        .up_imem_arburst(2'd1), .up_imem_arprot(3'd4), .up_imem_arvalid(iarvalid), .up_imem_arready(iarready),
        .up_imem_rid(irid), .up_imem_rdata(irdata), .up_imem_rresp(irresp), .up_imem_rlast(irlast),
        .up_imem_rvalid(irvalid), .up_imem_rready(irready),
        .dn_imem_arid(xiarid), .dn_imem_araddr(xiaraddr), .dn_imem_arlen(xiarlen), .dn_imem_arsize(xiarsize),
        .dn_imem_arburst(xiarburst), .dn_imem_arprot(xiarprot), .dn_imem_arvalid(xiarvalid),
        .dn_imem_arready(xiarready), .dn_imem_rid(4'd0), .dn_imem_rdata(xirdata), .dn_imem_rresp(xirresp),
        .dn_imem_rlast(xirlast), .dn_imem_rvalid(xirvalid), .dn_imem_rready(xirready),
        .up_dmem_arid(darid), .up_dmem_araddr(daraddr), .up_dmem_arlen(8'd0), .up_dmem_arsize(3'd3),
        .up_dmem_arburst(2'd1), .up_dmem_arprot(3'd0), .up_dmem_arvalid(darvalid), .up_dmem_arready(darready),
        .up_dmem_rid(drid), .up_dmem_rdata(drdata), .up_dmem_rresp(drresp), .up_dmem_rlast(drlast),
        .up_dmem_rvalid(drvalid), .up_dmem_rready(drready),
        .up_dmem_awid(dawid), .up_dmem_awaddr(dawaddr), .up_dmem_awlen(8'd0), .up_dmem_awsize(3'd3),
        .up_dmem_awburst(2'd1), .up_dmem_awprot(3'd0), .up_dmem_awvalid(dawvalid), .up_dmem_awready(dawready),
        .up_dmem_wdata(dwdata), .up_dmem_wstrb(dwstrb), .up_dmem_wlast(1'b1), .up_dmem_wvalid(dwvalid),
        .up_dmem_wready(dwready), .up_dmem_bid(dbid), .up_dmem_bresp(dbresp), .up_dmem_bvalid(dbvalid),
        .up_dmem_bready(dbready),
        .dn_dmem_arid(xdarid), .dn_dmem_araddr(xdaraddr), .dn_dmem_arlen(xdarlen), .dn_dmem_arsize(xdarsize),
        .dn_dmem_arburst(xdarburst), .dn_dmem_arprot(xdarprot), .dn_dmem_arvalid(xdarvalid),
        .dn_dmem_arready(xdarready), .dn_dmem_rid(4'd0), .dn_dmem_rdata(xdrdata), .dn_dmem_rresp(xdrresp),
        .dn_dmem_rlast(xdrlast), .dn_dmem_rvalid(xdrvalid), .dn_dmem_rready(xdrready),
        .dn_dmem_awid(xdawid), .dn_dmem_awaddr(xdawaddr), .dn_dmem_awlen(xdawlen), .dn_dmem_awsize(xdawsize),
        .dn_dmem_awburst(xdawburst), .dn_dmem_awprot(xdawprot), .dn_dmem_awvalid(xdawvalid),
        .dn_dmem_awready(xdawready), .dn_dmem_wdata(xdwdata), .dn_dmem_wstrb(xdwstrb), .dn_dmem_wlast(xdwlast),
        .dn_dmem_wvalid(xdwvalid), .dn_dmem_wready(xdwready), .dn_dmem_bid(4'd0), .dn_dmem_bresp(xdbresp),
        .dn_dmem_bvalid(xdbvalid), .dn_dmem_bready(xdbready));

    task check(input bit c, input string what);
        begin checks = checks + 1; if (!c) $fatal(1, "island check %0d: %s", checks, what); end
    endtask

    // Legitimate external responder (auto_resp=1): answers each accepted
    // external AR/AW after a short random delay, with address-derived data.
    integer auto_resp = 0;
    reg legit_r = 0, legit_dr = 0, legit_b = 0;
    reg ap_i = 0, ap_d = 0, ap_b = 0;
    reg [31:0] aa_i, aa_d;
    integer ad_i = 0, ad_d = 0, ad_b = 0;
    function [63:0] ext_data(input [31:0] a); ext_data = {32'h5afe_0000 | a[15:0], a}; endfunction
    always @(posedge clk) begin
        if (rst) begin ap_i <= 0; ap_d <= 0; ap_b <= 0; end
        else if (auto_resp != 0) begin
            if (xiarvalid && xiarready) begin ap_i <= 1; aa_i <= xiaraddr; ad_i <= 1 + ($random(seed) & 3); end
            if (xdarvalid && xdarready) begin ap_d <= 1; aa_d <= xdaraddr; ad_d <= 1 + ($random(seed) & 3); end
            if (xdwvalid && xdwready) begin ap_b <= 1; ad_b <= 1 + ($random(seed) & 3); end
            if (xirvalid && xirready && legit_r) ap_i <= 0;
            if (xdrvalid && xdrready && legit_dr) ap_d <= 0;
            if (xdbvalid && xdbready && legit_b) ap_b <= 0;
        end
    end
    always @(negedge clk) if (auto_resp != 0) begin
        if (ap_i && ad_i > 0) ad_i = ad_i - 1;
        if (ap_d && ad_d > 0) ad_d = ad_d - 1;
        if (ap_b && ad_b > 0) ad_b = ad_b - 1;
        legit_r = ap_i && ad_i == 0; legit_dr = ap_d && ad_d == 0; legit_b = ap_b && ad_b == 0;
        if (legit_r) begin xirvalid = 1; xirdata = ext_data(aa_i); xirresp = 0; end
        if (legit_dr) begin xdrvalid = 1; xdrdata = ext_data(aa_d); xdrresp = 0; end
        if (legit_b) begin xdbvalid = 1; xdbresp = 0; end
    end

    // Hostile external responder: junk R/B beats, continuously (hostile=1)
    // or on seeded random cycles (hostile=2), independent of any request.
    // While an external transaction is outstanding on a channel the junk
    // pauses there: the island cannot, and need not, judge external data.
    always @(negedge clk) begin
        #0.01;
        if (!legit_r && !ap_i) begin
            xirvalid = hostile == 1 || (hostile == 2 && ($random(seed) & 1));
            xirdata = 64'hbad0_0000_0000_0000 | $random(seed); xirresp = 0;
        end else if (!legit_r) xirvalid = 0;
        if (!legit_dr && !ap_d) begin
            xdrvalid = hostile == 1 || (hostile == 2 && ($random(seed) & 1));
            xdrdata = 64'hbad1_0000_0000_0000 | $random(seed); xdrresp = 0;
        end else if (!legit_dr) xdrvalid = 0;
        if (!legit_b && !ap_b) begin
            xdbvalid = hostile == 1 || (hostile == 2 && ($random(seed) & 1));
            xdbresp = 2'b10;
        end else if (!legit_b) xdbvalid = 0;
    end
    always @(posedge clk) if (!rst) begin
        if (xirvalid && xirready && !legit_r) junk_seen = junk_seen + 1;
        if (xdrvalid && xdrready && !legit_dr) junk_seen = junk_seen + 1;
        if (xdbvalid && xdbready && !legit_b) junk_seen = junk_seen + 1;
    end

    // Core-side monitors: every response beat the core would accept, in any
    // cycle including the AR/AW acceptance cycle (rready/bready are 1).
    integer ir_beats = 0, dr_beats = 0, db_beats = 0;
    reg [63:0] ir_last, dr_last;
    reg [1:0] ir_resp, dr_resp, db_resp;
    reg [63:0] dr_seq [0:15];
    always @(posedge clk) if (!rst) begin
        if (irvalid && irready) begin ir_beats = ir_beats + 1; ir_last = irdata; ir_resp = irresp; end
        if (drvalid && drready) begin
            dr_seq[dr_beats % 16] = drdata;
            dr_beats = dr_beats + 1; dr_last = drdata; dr_resp = drresp;
        end
        if (dbvalid && dbready) begin db_beats = db_beats + 1; db_resp = dbresp; end
    end
    // Master tasks drive at the negedge and sample handshakes at the
    // posedge, before that edge's register updates.
    task dread(input [31:0] a, input integer skew, output [63:0] d, output [1:0] r);
        integer t, b0;
        begin
            repeat (skew) @(negedge clk);
            b0 = dr_beats;
            darvalid = 1; daraddr = a; darid = darid + 1;
            t = 0; do begin @(posedge clk); t = t + 1; end while (!darready && t < 50);
            @(negedge clk); darvalid = 0;
            t = 0; do begin @(posedge clk); t = t + 1; end while (!(drvalid && drready) && t < 200);
            check(drvalid && drready, "dmem read completes");
            @(negedge clk);
            check(dr_beats == b0 + 1, $sformatf("exactly one dmem response beat (%0d)", dr_beats - b0));
            d = dr_last; r = dr_resp;
        end
    endtask
    task iread(input [31:0] a, input integer skew, output [63:0] d, output [1:0] r);
        integer t, b0;
        begin
            repeat (skew) @(negedge clk);
            b0 = ir_beats;
            iarvalid = 1; iaraddr = a; iarid = iarid + 1;
            t = 0; do begin @(posedge clk); t = t + 1; end while (!iarready && t < 50);
            @(negedge clk); iarvalid = 0;
            t = 0; do begin @(posedge clk); t = t + 1; end while (!(irvalid && irready) && t < 200);
            check(irvalid && irready, "imem read completes");
            @(negedge clk);
            check(ir_beats == b0 + 1, $sformatf("exactly one imem response beat (%0d)", ir_beats - b0));
            d = ir_last; r = ir_resp;
        end
    endtask
    task dwrite(input [31:0] a, input [63:0] v, input integer skew, output [1:0] r);
        integer t, u, b0;
        begin
            repeat (skew) @(negedge clk);
            b0 = db_beats;
            dawvalid = 1; dawaddr = a; dwvalid = 1; dwdata = v; dawid = dawid + 1;
            fork
                begin
                    t = 0; do begin @(posedge clk); t = t + 1; end while (!dawready && t < 50);
                    @(negedge clk); dawvalid = 0;
                end
                begin
                    u = 0; do begin @(posedge clk); u = u + 1; end while (!dwready && u < 50);
                    @(negedge clk); dwvalid = 0;
                end
            join
            t = 0; do begin @(posedge clk); t = t + 1; end while (!(dbvalid && dbready) && t < 200);
            check(dbvalid && dbready, "dmem write completes");
            @(negedge clk);
            check(db_beats == b0 + 1, $sformatf("exactly one write response beat (%0d)", db_beats - b0));
            r = db_resp;
        end
    endtask

    reg [63:0] d;
    reg [1:0] r;
    initial begin
        repeat (3) @(negedge clk); rst = 0;
        // ---- hostile phases: continuous junk, then seeded random junk ----
        for (hostile = 1; hostile <= 2; hostile = hostile + 1) begin
            for (integer s = 0; s < (hostile == 1 ? 1 : 8); s = s + 1) begin
                seed = 17 + s;
                for (integer k = 0; k < 6; k = k + 1) begin
                    dwrite(SRAM + 8 * k, 64'h600d_0000_0000_0000 + k + 16 * s, k % 3, r);
                    check(r == 0, "island SRAM write OKAY despite junk B beats");
                    dread(SRAM + 8 * k, k % 4, d, r);
                    check(d == 64'h600d_0000_0000_0000 + k + 16 * s && r == 0,
                          $sformatf("island SRAM read returns island data (got %h)", d));
                    iread(ROM + 8 * k, k % 4, d, r);
                    check(d == 0 && r == 0, $sformatf("island ROM fetch returns ROM data (got %h)", d));
                    iread(SRAM + 8 * k, k % 2, d, r);
                    check(r == 2'b10 && d[63:48] != 16'hbad0, "island SRAM is not executable");
                    dwrite(ROM + 8 * k, 64'h1, 0, r);
                    check(r == 2'b10, "island ROM is not writable");
                end
            end
        end
        check(junk_seen == 0, $sformatf("no external beat consumed outside an external transaction (%0d)", junk_seen));
        // ---- clean phase: external traffic is forwarded unchanged ----
        hostile = 0;
        @(negedge clk); xirvalid = 0; xdrvalid = 0; xdbvalid = 0;
        fork
            dread(EXT + 8, 0, d, r);
            begin
                wait (xdarvalid && xdarready); @(negedge clk);
                legit_dr = 1; xdrvalid = 1; xdrdata = 64'h0123_4567_89ab_cdef; xdrresp = 0;
                wait (xdrready); @(negedge clk); xdrvalid = 0; legit_dr = 0;
            end
        join
        check(d == 64'h0123_4567_89ab_cdef && r == 0, "external read forwarded");
        fork
            iread(EXT + 16, 0, d, r);
            begin
                wait (xiarvalid && xiarready); @(negedge clk);
                legit_r = 1; xirvalid = 1; xirdata = 64'h0000_0000_0000_0013; xirresp = 0;
                wait (xirready); @(negedge clk); xirvalid = 0; legit_r = 0;
            end
        join
        check(d == 64'h13 && r == 0, "external fetch forwarded");
        fork
            dwrite(EXT + 24, 64'h55, 0, r);
            begin
                wait (xdwvalid && xdwready); @(negedge clk);
                legit_b = 1; xdbvalid = 1; xdbresp = 0;
                wait (xdbready); @(negedge clk); xdbvalid = 0; legit_b = 0;
            end
        join
        check(r == 0, "external write response forwarded");
        // ---- backpressure: random R/B READY, legitimate external traffic
        // interleaved with island traffic, junk whenever the responder idles ----
        auto_resp = 1; hostile = 2; bp = 1; seed = 101;
        for (integer k = 0; k < 24; k = k + 1) begin
            dwrite(SRAM + 8 * (k % 8), 64'h7000 + k, k % 2, r);
            check(r == 0, "island write OKAY under backpressure");
            dread(EXT + 8 * k, k % 3, d, r);
            check(d == ext_data(EXT + 8 * k) && r == 0,
                  $sformatf("external read under backpressure (got %h)", d));
            dread(SRAM + 8 * (k % 8), k % 2, d, r);
            check(d == 64'h7000 + k && r == 0, $sformatf("island read under backpressure (got %h)", d));
            iread(EXT + 16 * k, k % 2, d, r);
            check(d == ext_data(EXT + 16 * k) && r == 0, "external fetch under backpressure");
            iread(ROM + 8 * k, 0, d, r);
            check(d == 0 && r == 0, "island fetch under backpressure");
        end
        bp = 0; @(negedge clk); irready = 1; drready = 1; dbready = 1;
        // ---- reset with island and external reads outstanding ----
        for (integer k = 0; k < 4; k = k + 1) begin
            begin : rst_case
                integer bi, bd, t;
                hostile = 0; @(negedge clk);
                bi = ir_beats; bd = dr_beats;
                darvalid = 1; daraddr = (k % 2) ? EXT + 'h40 : SRAM;
                iarvalid = 1; iaraddr = (k % 2) ? ROM : EXT + 'h80;
                t = 0; do begin @(posedge clk); t = t + 1; end while (!(darready && iarready) && t < 20);
                @(negedge clk); darvalid = 0; iarvalid = 0;
                rst = 1; hostile = 1;
                repeat (2) @(negedge clk); rst = 0;
                repeat (20) @(negedge clk);
                check(ir_beats == bi && dr_beats == bd,
                      "no response beat reaches the core after a reset with reads outstanding");
                check(junk_seen == 0, "no external beat consumed after reset");
                hostile = 0;
            end
        end
        dwrite(SRAM, 64'h4242, 0, r); dread(SRAM, 0, d, r);
        check(d == 64'h4242 && r == 0, "island usable after reset");
        // ---- pipelined: the next AR is accepted with the previous final R ----
        hostile = 2; seed = 202;
        begin : pipe
            reg [31:0] addrs [0:7];
            reg [63:0] want [0:7];
            integer n, t, b0, coincident;
            for (n = 0; n < 8; n = n + 1) begin
                addrs[n] = (n % 2) ? EXT + 'h100 + 8 * n : SRAM + 8 * n;
                if (n % 2 == 0) begin dwrite(SRAM + 8 * n, 64'h9000 + n, 0, r); want[n] = 64'h9000 + n; end
                else want[n] = ext_data(addrs[n]);
            end
            b0 = dr_beats; coincident = 0;
            @(negedge clk); darvalid = 1; daraddr = addrs[0];
            t = 0; do begin @(posedge clk); t = t + 1; end while (!darready && t < 50);
            @(negedge clk); darvalid = 0;
            for (n = 0; n < 8; n = n + 1) begin
                // Present the next address in the cycle the final R beat of
                // the current read is visible, so both handshakes can share
                // one edge.
                t = 0; while (!drvalid && t < 50) begin @(negedge clk); t = t + 1; end
                if (n < 7) begin darvalid = 1; daraddr = addrs[n + 1]; end
                @(posedge clk);
                if (n < 7) begin
                    if (darready) coincident = coincident + 1;
                    else begin
                        t = 0; do begin @(posedge clk); t = t + 1; end while (!darready && t < 50);
                    end
                end
                @(negedge clk); darvalid = 0;
            end
            repeat (5) @(negedge clk);
            check(dr_beats == b0 + 8, "pipelined reads: one beat each");
            for (n = 0; n < 8; n = n + 1)
                check(dr_seq[(b0 + n) % 16] == want[n],
                      $sformatf("pipelined read %0d data %h", n, dr_seq[(b0 + n) % 16]));
            check(coincident > 0, $sformatf("final R and next AR coincided (%0d)", coincident));
        end
        hostile = 0; auto_resp = 0;
        check(junk_seen == 0, "no junk consumed in any phase");
        $display("karudbg island: PASS (%0d checks)", checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "island timeout"); end
endmodule
