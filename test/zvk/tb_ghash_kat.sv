// tb_ghash_kat.sv -- KAT for the iterative karu_ghash vs Marian's basic_gcm.h
// vghsh/vgmul vectors.
//
// basic_gcm.h is a TEST_VL=12 (3 element-group) test; one 128 element group =
// array elements [0..3]. We drive the FIRST group of each vector and check the
// first group of the reference outputs. (Each 128b group is processed
// independently by vghsh.vv/vgmul.vv, so group 0 is a complete standalone KAT.)
//
// pk(w0..w3) models vle32: array element i -> bits[i*32 +: 32] (elem0 low).
//
// Build: verilator --binary --timing -Wno-WIDTH -Wno-UNUSEDSIGNAL
//   -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
//   rtl/zvk/karu_ghash.v test/zvk/tb_ghash_kat.sv --top-module tb_ghash_kat

`timescale 1ns/1ps
module tb_ghash_kat;

    function automatic [127:0] pk(input [31:0] w0, w1, w2, w3);
        pk = {w3, w2, w1, w0};   // w0 -> bits[31:0] (vle32 element 0)
    endfunction

    // ---- basic_gcm.h, element group 0 (array elems [0..3]) ----
    // VGHSH.VV : vd=part_hash, vs2=hash_skey, vs1=cipher_text -> ref_new_part_hash
    wire [127:0] PH  = pk(32'h55088014, 32'h2A84400A, 32'h15422005, 32'hA9A11002); // gcm_part_hash
    wire [127:0] HK  = pk(32'h541A509C, 32'h2A0D284E, 32'h15069427, 32'hA9834A13); // gcm_hash_skey
    wire [127:0] CT  = pk(32'h0112D088, 32'h00896844, 32'h0044B422, 32'h00225A11); // gcm_cipher_text
    wire [127:0] GR  = pk(32'hBC148D6A, 32'h9F71BE42, 32'h2FA421E7, 32'h7A73AFF1); // gcm_ref_new_part_hash

    // VGMUL.VV : vd=multiplier, vs2=multiplicand -> ref_product
    wire [127:0] MUL = pk(32'h55088014, 32'h2A84400A, 32'h15422005, 32'hA9A11002); // gcm_multiplier
    wire [127:0] MND = pk(32'h0112D088, 32'h00896844, 32'h0044B422, 32'h00225A11); // gcm_multiplicand
    wire [127:0] PR  = pk(32'hC1870055, 32'hD297A538, 32'hEA1E1272, 32'h1D8D92B4); // gcm_ref_product

    // ---- iterative DUT ----
    reg          clk, rst, req, mode;
    reg  [127:0] dvd, dvs1, dvs2;
    wire         busy, done;
    wire [127:0] prod;
    karu_ghash dut (
        .clk(clk), .rst(rst), .req(req), .mode(mode),
        .vd(dvd), .vs1(dvs1), .vs2(dvs2),
        .busy(busy), .done(done), .prod(prod)
    );

    always #5 clk = ~clk;

    integer errs;
    reg [127:0] got_ghsh, got_gmul;

    task automatic run_op(input m, input [127:0] a_vd, input [127:0] a_vs1,
                        input [127:0] a_vs2, output [127:0] result);
        integer guard;
        begin
            @(negedge clk);
            mode = m; dvd = a_vd; dvs1 = a_vs1; dvs2 = a_vs2; req = 1'b1;
            @(negedge clk); req = 1'b0;
            guard = 0;
            while (!done && guard < 400) begin @(negedge clk); guard = guard + 1; end
            result = prod;
        end
    endtask

    initial begin
        clk = 0; rst = 1; req = 0; mode = 0; dvd = 0; dvs1 = 0; dvs2 = 0;
        errs = 0;
        @(negedge clk); @(negedge clk); rst = 0;
        @(negedge clk);

        // vghsh.vv  (vd=PH, vs1=CT, vs2=HK)
        run_op(1'b1, PH, CT, HK, got_ghsh);
        $display("-- vghsh.vv --");
        if (got_ghsh !== GR) begin errs=errs+1;
            $display("  FAIL iterative vs vector: got=%032h vec=%032h", got_ghsh, GR);
        end else $display("  ok  iterative   == published vector");

        // vgmul.vv  (vd=MUL, vs2=MND)
        run_op(1'b0, MUL, 128'h0, MND, got_gmul);
        $display("-- vgmul.vv --");
        if (got_gmul !== PR) begin errs=errs+1;
            $display("  FAIL iterative vs vector: got=%032h vec=%032h", got_gmul, PR);
        end else $display("  ok  iterative   == published vector");

        if (errs==0) $display("GHASH_KAT: PASS");
        else         $display("GHASH_KAT: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
