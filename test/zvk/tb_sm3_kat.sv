// tb_sm3_kat.sv -- KAT for the locally cleaned Marian SM3 leaf cores (Zvksh:
// vsm3me.vv message expansion, vsm3c.vi compression). Each core does its full
// op combinationally in one call. Vectors are Marian's validated basic_sm3.h
// (spike-cross-checked, big-endian word form per the SM3 spec).
//
// pk8(w0..w7) models vle32: array element i -> bits[i*32 +: 32] (elem0 low).
//
//   vsm3me.vv vd, vs2, vs1 : sm3_msg_expansion(start=vs1, end=vs2) -> vd
//       vs1 = message_words_0, vs2 = message_words_1 -> message_words_ref_1
//   vsm3c.vi  vd, vs2, uimm=0 : sm3_compression(crnt=vd, msg=vs2, rnds=0) -> vd
//       vd = current_state_big_endian, vs2 = message_words_0 -> next_state_big_endian
//
// Build: verilator --binary --timing -Wno-UNOPTFLAT -Wno-WIDTH -Wno-UNUSEDSIGNAL
//   -Wno-DECLFILENAME -Wno-UNUSEDPARAM
//   rtl/zvk/sm3_compression.v rtl/zvk/sm3_msg_expansion.v
//   test/zvk/tb_sm3_kat.sv --top-module tb_sm3_kat

`timescale 1ns/1ps
module tb_sm3_kat;

    function automatic [255:0] pk8(input [31:0] w0,w1,w2,w3,w4,w5,w6,w7);
        pk8 = {w7,w6,w5,w4,w3,w2,w1,w0};   // w0 -> bits[31:0] (vle32 element 0)
    endfunction

    // ---- vsm3me.vv ----
    wire [255:0] me_vs1 = pk8(32'h80636261,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0);          // message_words_0
    wire [255:0] me_vs2 = pk8(32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h18000000);          // message_words_1
    wire [255:0] me_exp = pk8(32'h00E29290,32'h00000000,32'h06060C00,32'hED709C71,
                            32'h00000000,32'h1F800180,32'hA97D9F93,32'h00000000);             // message_words_ref_1
    wire [255:0] me_out;
    sm3_msg_expansion i_me (
        .msg_words_start_i (me_vs1),
        .msg_words_end_i   (me_vs2),
        .msg_words_o       (me_out)
    );

    // ---- vsm3c.vi uimm=0 ----
    wire [255:0] c_vd  = pk8(32'h6f168073,32'hb9b21449,32'hd7422417,32'h00068ada,
                           32'hbc306fa9,32'haa383116,32'h4dee8de3,32'h4e0efbb0);              // current_state_big_endian
    wire [255:0] c_vs2 = pk8(32'h80636261,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0,32'h0);          // message_words_0
    wire [255:0] c_exp = pk8(32'h8C4252EA,32'h2BC1EDB9,32'hE7DE2C00,32'h92726529,
                           32'h233A35AC,32'hF429ADB2,32'h794BE585,32'h89B150C5);             // next_state_big_endian
    wire [255:0] c_out;
    sm3_compression i_c (
        .crnt_state_i (c_vd),
        .msg_words_i  (c_vs2),
        .rnds_i       (5'd0),
        .next_state_o (c_out)
    );

    integer errs;
    initial begin
        #1;
        errs = 0;

        $display("-- SM3 vsm3me.vv --");
        if (me_out !== me_exp) begin errs=errs+1;
            $display("  FAIL got=%064h exp=%064h", me_out, me_exp);
        end else $display("  ok  vsm3me");

        $display("-- SM3 vsm3c.vi uimm=0 --");
        if (c_out !== c_exp) begin errs=errs+1;
            $display("  FAIL got=%064h exp=%064h", c_out, c_exp);
        end else $display("  ok  vsm3c");

        if (errs==0) $display("SM3_KAT: PASS");
        else         $display("SM3_KAT: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
