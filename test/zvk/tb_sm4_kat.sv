// tb_sm4_kat.sv -- KAT for the locally cleaned Marian SM4 leaf cores (Zvksed).
// Each core performs all FOUR SM4 rounds of its op in ONE combinational call,
// so the TB uses a single instance of each (NOT a chain).
//
// Vectors are Marian's validated basic_sm4.h reference (= the SM4 standard
// GB/T 32907-2016 example, key 0123456789abcdeffedcba9876543210). pk(w0..w3)
// models a vle32 load: array element i -> vector element i -> bits[i*32 +: 32],
// so element 0 / first word lands in bits[31:0].
//
//   vsm4k.vi vd, vs2, uimm=1 : sm4_key_expansion(rnd_i=1, curr=vs2)
//       vs2 = sm4_round_keys (rk0..rk3) -> ref_round_keys_0 (rk4..rk7)
//   vsm4r.vv vd, vs2         : sm4_encdec(state=vd, key=vs2)
//       vd = sm4_state0, vs2 = sm4_round_keys -> ref_cipher_0
//
// Build: verilator --binary --timing -Wno-UNOPTFLAT -Wno-WIDTH -Wno-UNUSEDSIGNAL
//   -Wno-DECLFILENAME -Wno-UNUSEDPARAM
//   rtl/zvk/sm4_encdec.v rtl/zvk/sm4_key_expansion.v
//   test/zvk/tb_sm4_kat.sv --top-module tb_sm4_kat

`timescale 1ns/1ps
module tb_sm4_kat;

    function automatic [127:0] pk(input [31:0] w0, w1, w2, w3);
        pk = {w3, w2, w1, w0};   // w0 -> bits[31:0] (vle32 element 0)
    endfunction

    // ---- vsm4k.vi (uimm=1 -> rnd_i=1, CK[4..7]) ----
    wire [127:0] k_in  = pk(32'hF12186F9, 32'h41662B61, 32'h5A6AB19A, 32'h7BA92077); // rk0..rk3
    wire [127:0] k_exp = pk(32'h367360F4, 32'h776A0C61, 32'hB6BB89B3, 32'h24763151); // rk4..rk7
    wire [127:0] k_out;
    sm4_key_expansion i_keyexp (
        .rnd_i          (3'd1),
        .curr_rnd_key_i (k_in),
        .next_rnd_key_o (k_out)
    );

    // ---- vsm4r.vv (4-round encrypt) ----
    wire [127:0] r_state = pk(32'h01234567, 32'h89ABCDEF, 32'hFEDCBA98, 32'h76543210); // sm4_state0
    wire [127:0] r_keys  = pk(32'hF12186F9, 32'h41662B61, 32'h5A6AB19A, 32'h7BA92077); // rk0..rk3
    wire [127:0] r_exp   = pk(32'h27FAD345, 32'hA18B4CB2, 32'h11C1E22A, 32'hCC13E2EE); // ref_cipher_0
    wire [127:0] r_out;
    sm4_encdec i_encdec (
        .rnd_state_i (r_state),
        .rnd_key_i   (r_keys),
        .rnd_state_o (r_out)
    );

    integer errs;
    initial begin
        #1;
        errs = 0;

        $display("-- SM4 vsm4k.vi uimm=1 --");
        if (k_out !== k_exp) begin errs=errs+1;
            $display("  FAIL got=%032h exp=%032h", k_out, k_exp);
        end else $display("  ok  vsm4k=%032h", k_out);

        $display("-- SM4 vsm4r.vv (4-round) --");
        if (r_out !== r_exp) begin errs=errs+1;
            $display("  FAIL got=%032h exp=%032h", r_out, r_exp);
        end else $display("  ok  vsm4r=%032h", r_out);

        if (errs==0) $display("SM4_KAT: PASS");
        else         $display("SM4_KAT: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
