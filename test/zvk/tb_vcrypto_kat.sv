// tb_vcrypto_kat.sv -- unit KAT for the aggregated karu_vcrypto handshake.
// Drives one representative op per sub-extension through the uniform req/done
// handshake and checks each against the same standard vectors used in the
// per-core KATs. Proves the aggregator wiring + FSM, not just the leaf cores.
//
// Build: verilator --binary --timing -Wno-UNOPTFLAT -Wno-WIDTH -Wno-fatal
//   -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-WIDTHTRUNC
//   -Wno-WIDTHEXPAND rtl/zvk/sboxes.v
//   rtl/zvk/aes_encdec.v rtl/zvk/aes_key_expansion.v rtl/zvk/sha2_compression.v
//   rtl/zvk/sha2_msg_schedule.v rtl/zvk/sm4_encdec.v rtl/zvk/sm4_key_expansion.v
//   rtl/zvk/sm3_compression.v rtl/zvk/sm3_msg_expansion.v rtl/zvk/karu_sm3_iter.v
//   rtl/zvk/karu_ghash.v rtl/zvk/karu_vcrypto.v
//   test/zvk/tb_vcrypto_kat.sv --top-module tb_vcrypto_kat

`timescale 1ns/1ps
module tb_vcrypto_kat;

    localparam [4:0]
        COP_AESEM=1, COP_AESEF=2, COP_AESKF1=5, COP_SHA2CH=7, COP_SHA2MS=9,
        COP_SM4R=10, COP_SM4K=11, COP_SM3C=12, COP_SM3ME=13, COP_GHSH=14, COP_GMUL=15;

    function automatic [127:0] pk4(input [31:0] w0,w1,w2,w3);
        pk4 = {w3,w2,w1,w0};                 // w0 -> bits[31:0] (vle32 element 0)
    endfunction
    function automatic [255:0] pk8(input [31:0] w0,w1,w2,w3,w4,w5,w6,w7);
        pk8 = {w7,w6,w5,w4,w3,w2,w1,w0};
    endfunction
    function automatic [255:0] pk4_64(input [63:0] w0,w1,w2,w3);
        pk4_64 = {w3,w2,w1,w0};
    endfunction

    reg          clk, rst, req;
    reg  [4:0]   cop, aux;
    reg  [255:0] vd, vs1, vs2;
    wire         busy, done;
    wire [255:0] res;
    karu_vcrypto dut (
        .clk(clk), .rst(rst), .req(req), .cop(cop), .aux(aux),
        .egw_vd(vd), .egw_vs1(vs1), .egw_vs2(vs2),
        .busy(busy), .done(done), .egw_res(res)
    );

    // reference compression core for the vsha2ch routing check
    reg  [255:0] ch_vd, ch_vs1, ch_vs2;
    reg  [1:0]   ch_op;
    wire [255:0] ref_comp_o;
    compression i_ref_comp (
        .c_state_0_i   (ch_vd),
        .c_state_1_i   (ch_vs2),
        .msg_sched_pc_i(ch_vs1),
        .sha_op_i      (ch_op),
        .n_state_o     (ref_comp_o)
    );
    wire [255:0] ref_ms_o;
    msg_schedule i_ref_ms (
        .msg_words_0_i (ch_vd),
        .msg_words_1_i (ch_vs2),
        .msg_words_2_i (ch_vs1),
        .sha_op_i      (ch_op[0]),
        .msg_words_o   (ref_ms_o)
    );

    always #5 clk = ~clk;
    integer errs;

    task automatic run(input [4:0] c, input [4:0] a,
                     input [255:0] d, input [255:0] s1, input [255:0] s2);
        integer g;
        begin
            @(negedge clk);
            cop=c; aux=a; vd=d; vs1=s1; vs2=s2; req=1'b1;
            @(negedge clk); req=1'b0;
            g=0; while(!done && g<400) begin @(negedge clk); g=g+1; end
        end
    endtask

    task automatic chk(input [255:0] got, input [255:0] exp, input [255:0] name);
        begin
            if (got !== exp) begin errs=errs+1;
                $display("  FAIL %0s got=%064h exp=%064h", name, got, exp);
            end else $display("  ok  %0s", name);
        end
    endtask

    // AES second-instance reference (full-value check; mirrors tb_aes_kat C.1)
    // round[1].start -> vaesem(rk1) -> round[1].output
    function automatic [127:0] brev128(input [127:0] x);
        integer i; begin brev128=0;
            for (i=0;i<16;i=i+1) brev128[i*8 +: 8] = x[(15-i)*8 +: 8];
        end
    endfunction

    initial begin
        clk=0; rst=1; req=0; cop=0; aux=0; vd=0; vs1=0; vs2=0; errs=0;
        @(negedge clk); @(negedge clk); rst=0; @(negedge clk);

        // ---- AES vaesem: FIPS-197 C.1 round[1] (state=round[1].start, key=rk1) ----
        run(COP_AESEM, 5'd0,
                {128'b0, brev128(128'h00102030405060708090a0b0c0d0e0f0)}, 256'b0,   // round[1].start
                {128'b0, brev128(128'hd6aa74fdd2af72fadaa678f1d6ab76fe)});         // rk1
        chk(res[127:0], brev128(128'h89d810e8855ace682d1843d8cb128fe4), "vaesem"); // round[1].output

        // ---- SHA-256 vsha2ms (FIPS "abc"): vd={W3,W2,W1,W0} vs2={W11,W10,W9,W4} vs1={W15,W14,W13,W12} ----
        run(COP_SHA2MS, 5'd0,
                pk8(32'h61626380,32'h0,32'h0,32'h0, 32'h0,32'h0,32'h0,32'h0),       // vd  : W0..W3 (only W0 nz)
                pk8(32'h0,32'h0,32'h0,32'h00000018, 32'h0,32'h0,32'h0,32'h0),       // vs1 : W12..W15 (W15=0x18 in el3)
                pk8(32'h0,32'h0,32'h0,32'h0,        32'h0,32'h0,32'h0,32'h0));      // vs2 : W4,W9,W10,W11 (all 0)
        chk(res[127:0], pk4(32'h61626380,32'h000f0000,32'h7da86405,32'h600003c6), "vsha2ms"); // W16..W19

        // ---- SHA-256 vsha2ch (FIPS abc, first 2-round step) ----
        // vd={c,d,g,h}=H2,H3,H6,H7 ; vs2={a,b,e,f}=H0,H1,H4,H5 ; vs1 HIGH: W0+K0 lane2, W1+K1 lane3
        // Golden = a direct reference `compression` instance (the bare core is itself
        // proven end-to-end in tb_sha2_kat); this checks the aggregator's routing/wiring.
        ch_vd  = pk8(32'h3c6ef372,32'ha54ff53a,32'h1f83d9ab,32'h5be0cd19, 32'h0,32'h0,32'h0,32'h0);
        ch_vs1 = pk8(32'h0,32'h0,(32'h61626380+32'h428a2f98),(32'h00000000+32'h71374491), 32'h0,32'h0,32'h0,32'h0);
        ch_vs2 = pk8(32'h6a09e667,32'hbb67ae85,32'h510e527f,32'h9b05688c, 32'h0,32'h0,32'h0,32'h0);
        ch_op  = 2'b00;
        run(COP_SHA2CH, 5'd0, ch_vd, ch_vs1, ch_vs2);
        #1;  // let ref_comp settle
        chk(res[127:0], ref_comp_o[127:0], "vsha2ch (vs ref compression)");

        // ---- SHA-512 vsha2ch (first 2-round step): exercises Zvknhb SEW64 path ----
        ch_vd  = pk4_64(64'h3c6ef372fe94f82b,64'ha54ff53a5f1d36f1,
                    64'h1f83d9abfb41bd6b,64'h5be0cd19137e2179);
        ch_vs1 = pk4_64(64'h0,64'h0,
                    64'h6162638000000000 + 64'h428a2f98d728ae22,
                    64'h0 + 64'h7137449123ef65cd);
        ch_vs2 = pk4_64(64'h6a09e667f3bcc908,64'hbb67ae8584caa73b,
                    64'h510e527fade682d1,64'h9b05688c2b3e6c1f);
        ch_op  = 2'b01;
        run(COP_SHA2CH, 5'd1, ch_vd, ch_vs1, ch_vs2);
        #1;
        chk(res, ref_comp_o, "vsha2ch.e64 (vs ref compression)");

        // ---- SHA-512 vsha2ms: aggregate staged wrapper vs combinational reference ----
        ch_vd  = pk4_64(64'h6162638000000000,64'h0,64'h0,64'h0);
        ch_vs2 = pk4_64(64'h0,64'h0,64'h0,64'h0);
        ch_vs1 = pk4_64(64'h0,64'h0,64'h0,64'h0000000000000018);
        ch_op  = 2'b01;
        run(COP_SHA2MS, 5'd1, ch_vd, ch_vs1, ch_vs2);
        #1;
        chk(res, ref_ms_o, "vsha2ms.e64 (vs ref msg_schedule)");

        // ---- SM4 vsm4k (uimm=1) ----
        run(COP_SM4K, 5'd1, 256'b0, 256'b0,
                {128'b0, pk4(32'hF12186F9,32'h41662B61,32'h5A6AB19A,32'h7BA92077)});
        chk(res[127:0], pk4(32'h367360F4,32'h776A0C61,32'hB6BB89B3,32'h24763151), "vsm4k");

        // ---- SM4 vsm4r ----
        run(COP_SM4R, 5'd0,
                {128'b0, pk4(32'h01234567,32'h89ABCDEF,32'hFEDCBA98,32'h76543210)}, 256'b0,
                {128'b0, pk4(32'hF12186F9,32'h41662B61,32'h5A6AB19A,32'h7BA92077)});
        chk(res[127:0], pk4(32'h27FAD345,32'hA18B4CB2,32'h11C1E22A,32'hCC13E2EE), "vsm4r");

        // ---- SM3 vsm3me ----
        run(COP_SM3ME, 5'd0, 256'b0,
                pk8(32'h80636261,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0),        // vs1 = message_words_0
                pk8(32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h18000000));       // vs2 = message_words_1
        chk(res, pk8(32'h00E29290,32'h00000000,32'h06060C00,32'hED709C71,
                 32'h00000000,32'h1F800180,32'hA97D9F93,32'h00000000), "vsm3me");

        // ---- SM3 vsm3c (uimm=0) ----
        run(COP_SM3C, 5'd0,
                pk8(32'h6f168073,32'hb9b21449,32'hd7422417,32'h00068ada,
                        32'hbc306fa9,32'haa383116,32'h4dee8de3,32'h4e0efbb0),           // vd = current_state_be
                256'b0,
                pk8(32'h80636261,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0));       // vs2 = message_words_0
        chk(res, pk8(32'h8C4252EA,32'h2BC1EDB9,32'hE7DE2C00,32'h92726529,
                 32'h233A35AC,32'hF429ADB2,32'h794BE585,32'h89B150C5), "vsm3c");

        // ---- GHASH vghsh (basic_gcm.h group 0) ----
        run(COP_GHSH, 5'd0,
                {128'b0, pk4(32'h55088014,32'h2A84400A,32'h15422005,32'hA9A11002)}, // vd=part_hash
                {128'b0, pk4(32'h0112D088,32'h00896844,32'h0044B422,32'h00225A11)}, // vs1=cipher_text
                {128'b0, pk4(32'h541A509C,32'h2A0D284E,32'h15069427,32'hA9834A13)});// vs2=hash_skey
        chk(res[127:0], pk4(32'hBC148D6A,32'h9F71BE42,32'h2FA421E7,32'h7A73AFF1), "vghsh");

        // ---- GHASH vgmul ----
        run(COP_GMUL, 5'd0,
                {128'b0, pk4(32'h55088014,32'h2A84400A,32'h15422005,32'hA9A11002)}, // vd=multiplier
                256'b0,
                {128'b0, pk4(32'h0112D088,32'h00896844,32'h0044B422,32'h00225A11)});// vs2=multiplicand
        chk(res[127:0], pk4(32'hC1870055,32'hD297A538,32'hEA1E1272,32'h1D8D92B4), "vgmul");

        if (errs==0) $display("VCRYPTO_KAT: PASS");
        else         $display("VCRYPTO_KAT: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
