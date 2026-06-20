// Verilog SM4 four-round key expansion leaf using the shared combinational SM4 S-box.

module sm4_key_expansion
(
    input  wire [  2:0] rnd_i,
    input  wire [127:0] curr_rnd_key_i,
    output wire [127:0] next_rnd_key_o
);

    wire [31:0] rk0 = curr_rnd_key_i[ 31:  0];
    wire [31:0] rk1 = curr_rnd_key_i[ 63: 32];
    wire [31:0] rk2 = curr_rnd_key_i[ 95: 64];
    wire [31:0] rk3 = curr_rnd_key_i[127: 96];

    wire [4:0] rbase = {rnd_i, 2'b00};

    wire [31:0] b0 = rk1 ^ rk2 ^ rk3 ^ sm_constant_key(rbase);
    wire [31:0] s0;
    sm4_subword i_sub0 (.word_o(s0), .word_i(b0));
    wire [31:0] rk4 = sm_round_key(rk0, s0);

    wire [31:0] b1 = rk2 ^ rk3 ^ rk4 ^ sm_constant_key(rbase + 5'd1);
    wire [31:0] s1;
    sm4_subword i_sub1 (.word_o(s1), .word_i(b1));
    wire [31:0] rk5 = sm_round_key(rk1, s1);

    wire [31:0] b2 = rk3 ^ rk4 ^ rk5 ^ sm_constant_key(rbase + 5'd2);
    wire [31:0] s2;
    sm4_subword i_sub2 (.word_o(s2), .word_i(b2));
    wire [31:0] rk6 = sm_round_key(rk2, s2);

    wire [31:0] b3 = rk4 ^ rk5 ^ rk6 ^ sm_constant_key(rbase + 5'd3);
    wire [31:0] s3;
    sm4_subword i_sub3 (.word_o(s3), .word_i(b3));
    wire [31:0] rk7 = sm_round_key(rk3, s3);

    assign next_rnd_key_o = {rk7, rk6, rk5, rk4};

    function [31:0] sm_constant_key;
        input [4:0] r;
        begin
            case (r)
                5'h00: sm_constant_key = 32'h00070E15;
                5'h01: sm_constant_key = 32'h1C232A31;
                5'h02: sm_constant_key = 32'h383F464D;
                5'h03: sm_constant_key = 32'h545B6269;
                5'h04: sm_constant_key = 32'h70777E85;
                5'h05: sm_constant_key = 32'h8C939AA1;
                5'h06: sm_constant_key = 32'hA8AFB6BD;
                5'h07: sm_constant_key = 32'hC4CBD2D9;
                5'h08: sm_constant_key = 32'hE0E7EEF5;
                5'h09: sm_constant_key = 32'hFC030A11;
                5'h0A: sm_constant_key = 32'h181F262D;
                5'h0B: sm_constant_key = 32'h343B4249;
                5'h0C: sm_constant_key = 32'h50575E65;
                5'h0D: sm_constant_key = 32'h6C737A81;
                5'h0E: sm_constant_key = 32'h888F969D;
                5'h0F: sm_constant_key = 32'hA4ABB2B9;
                5'h10: sm_constant_key = 32'hC0C7CED5;
                5'h11: sm_constant_key = 32'hDCE3EAF1;
                5'h12: sm_constant_key = 32'hF8FF060D;
                5'h13: sm_constant_key = 32'h141B2229;
                5'h14: sm_constant_key = 32'h30373E45;
                5'h15: sm_constant_key = 32'h4C535A61;
                5'h16: sm_constant_key = 32'h686F767D;
                5'h17: sm_constant_key = 32'h848B9299;
                5'h18: sm_constant_key = 32'hA0A7AEB5;
                5'h19: sm_constant_key = 32'hBCC3CAD1;
                5'h1A: sm_constant_key = 32'hD8DFE6ED;
                5'h1B: sm_constant_key = 32'hF4FB0209;
                5'h1C: sm_constant_key = 32'h10171E25;
                5'h1D: sm_constant_key = 32'h2C333A41;
                5'h1E: sm_constant_key = 32'h484F565D;
                5'h1F: sm_constant_key = 32'h646B7279;
                default: sm_constant_key = 32'h00000000;
            endcase
        end
    endfunction

    function [31:0] sm_rol32;
        input [31:0] x;
        input integer s;
        begin
            sm_rol32 = (x << s) | (x >> (32 - s));
        end
    endfunction

    function [31:0] sm_round_key;
        input [31:0] x;
        input [31:0] s;
        begin
            sm_round_key = x ^ (s ^ sm_rol32(s, 13) ^ sm_rol32(s, 23));
        end
    endfunction

endmodule
