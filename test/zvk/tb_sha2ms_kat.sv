// tb_sha2ms_kat.sv -- KAT for the locally cleaned Marian `msg_schedule` core (Zvknha
// vsha2ms.vv). It produces {W19,W18,W17,W16} from three input groups:
//   msg_words_0_i (vd)  = {W3, W2, W1, W0}    [W3=127:96 .. W0=31:0]
//   msg_words_1_i (vs2) = {W11,W10,W9, W4}
//   msg_words_2_i (vs1) = {W15,W14,W13,W12}
//   sha_op_i = 0 (SEW32/SHA-256), low 128b used.
// We compute the real SHA-256 message schedule for "abc" with the canonical
// recurrence and check the core's W16..W19 against it -- independent reference.
//
// Build: verilator --binary --timing -Wno-UNOPTFLAT -Wno-WIDTH -Wno-UNUSEDSIGNAL
//   -Wno-DECLFILENAME -Wno-UNUSEDPARAM
//   rtl/zvk/sha2_msg_schedule.v test/zvk/tb_sha2ms_kat.sv
//   --top-module tb_sha2ms_kat

`timescale 1ns/1ps
module tb_sha2ms_kat;

    reg [31:0] W [0:19];
    reg [63:0] W64 [0:19];

    function automatic [31:0] rotr(input [31:0] x, input integer n);
        rotr = (x >> n) | (x << (32 - n));
    endfunction
    function automatic [31:0] ssig0(input [31:0] x);
        ssig0 = rotr(x,7) ^ rotr(x,18) ^ (x >> 3);
    endfunction
    function automatic [31:0] ssig1(input [31:0] x);
        ssig1 = rotr(x,17) ^ rotr(x,19) ^ (x >> 10);
    endfunction
    function automatic [63:0] rotr64(input [63:0] x, input integer n);
        rotr64 = (x >> n) | (x << (64 - n));
    endfunction
    function automatic [63:0] ssig0_64(input [63:0] x);
        ssig0_64 = rotr64(x,1) ^ rotr64(x,8) ^ (x >> 7);
    endfunction
    function automatic [63:0] ssig1_64(input [63:0] x);
        ssig1_64 = rotr64(x,19) ^ rotr64(x,61) ^ (x >> 6);
    endfunction

    reg  [255:0] mw0, mw1, mw2;
    reg          sha_op;
    wire [255:0] mwo;

    msg_schedule dut (
        .msg_words_0_i (mw0),
        .msg_words_1_i (mw1),
        .msg_words_2_i (mw2),
        .sha_op_i      (sha_op),
        .msg_words_o   (mwo)
    );

    integer i, errs;
    reg [31:0] g16,g17,g18,g19;
    reg [63:0] g16_64,g17_64,g18_64,g19_64;

    initial begin
        // canonical W[0..19] for padded "abc"
        W[0]=32'h61626380;
        for (i=1;i<15;i=i+1) W[i]=32'h0;
        W[15]=32'h00000018;
        for (i=16;i<20;i=i+1)
            W[i] = ssig1(W[i-2]) + W[i-7] + ssig0(W[i-15]) + W[i-16];

        // pack inputs per the core's window definition (low 128b)
        mw0 = {128'b0, W[3],  W[2],  W[1],  W[0] };
        mw1 = {128'b0, W[11], W[10], W[9],  W[4] };
        mw2 = {128'b0, W[15], W[14], W[13], W[12]};
        sha_op = 1'b0;  // SHA-256
        #1;
        {g19,g18,g17,g16} = mwo[127:0];

        errs = 0;
        if (g16!==W[16]) begin errs=errs+1; $display("  FAIL W16 got=%08h exp=%08h",g16,W[16]); end
        if (g17!==W[17]) begin errs=errs+1; $display("  FAIL W17 got=%08h exp=%08h",g17,W[17]); end
        if (g18!==W[18]) begin errs=errs+1; $display("  FAIL W18 got=%08h exp=%08h",g18,W[18]); end
        if (g19!==W[19]) begin errs=errs+1; $display("  FAIL W19 got=%08h exp=%08h",g19,W[19]); end

        if (errs==0) $display("SHA256_MSGSCHED_KAT: PASS  W16..W19=%08h %08h %08h %08h",
                          g16,g17,g18,g19);
        else         $display("SHA256_MSGSCHED_KAT: FAIL (%0d errors)", errs);

        W64[0]=64'h6162638000000000;
        for (i=1;i<15;i=i+1) W64[i]=64'h0;
        W64[15]=64'h0000000000000018;
        for (i=16;i<20;i=i+1)
            W64[i] = ssig1_64(W64[i-2]) + W64[i-7] + ssig0_64(W64[i-15]) + W64[i-16];

        mw0 = {W64[3],  W64[2],  W64[1],  W64[0] };
        mw1 = {W64[11], W64[10], W64[9],  W64[4] };
        mw2 = {W64[15], W64[14], W64[13], W64[12]};
        sha_op = 1'b1;  // SHA-512
        #1;
        {g19_64,g18_64,g17_64,g16_64} = mwo;

        if (g16_64!==W64[16]) begin errs=errs+1; $display("  FAIL W64_16 got=%016h exp=%016h",g16_64,W64[16]); end
        if (g17_64!==W64[17]) begin errs=errs+1; $display("  FAIL W64_17 got=%016h exp=%016h",g17_64,W64[17]); end
        if (g18_64!==W64[18]) begin errs=errs+1; $display("  FAIL W64_18 got=%016h exp=%016h",g18_64,W64[18]); end
        if (g19_64!==W64[19]) begin errs=errs+1; $display("  FAIL W64_19 got=%016h exp=%016h",g19_64,W64[19]); end

        if (errs==0) $display("SHA512_MSGSCHED_KAT: PASS  W16..W19=%016h %016h %016h %016h",
                          g16_64,g17_64,g18_64,g19_64);
        else         $display("SHA_MSGSCHED_KAT: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
