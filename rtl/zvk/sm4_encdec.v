// Verilog SM4 four-round encrypt/decrypt leaf using the shared combinational SM4 S-box.

module sm4_encdec
(
    input  wire [127:0] rnd_state_i,
    input  wire [127:0] rnd_key_i,
    output wire [127:0] rnd_state_o
);

    wire [31:0] rk0 = rnd_key_i[ 31:  0];
    wire [31:0] rk1 = rnd_key_i[ 63: 32];
    wire [31:0] rk2 = rnd_key_i[ 95: 64];
    wire [31:0] rk3 = rnd_key_i[127: 96];

    wire [31:0] x0 = rnd_state_i[ 31:  0];
    wire [31:0] x1 = rnd_state_i[ 63: 32];
    wire [31:0] x2 = rnd_state_i[ 95: 64];
    wire [31:0] x3 = rnd_state_i[127: 96];

    wire [31:0] b0 = x1 ^ x2 ^ x3 ^ rk0;
    wire [31:0] s0;
    sm4_subword i_sub0 (.word_o(s0), .word_i(b0));
    wire [31:0] x4 = sm4_round(x0, s0);

    wire [31:0] b1 = x2 ^ x3 ^ x4 ^ rk1;
    wire [31:0] s1;
    sm4_subword i_sub1 (.word_o(s1), .word_i(b1));
    wire [31:0] x5 = sm4_round(x1, s1);

    wire [31:0] b2 = x3 ^ x4 ^ x5 ^ rk2;
    wire [31:0] s2;
    sm4_subword i_sub2 (.word_o(s2), .word_i(b2));
    wire [31:0] x6 = sm4_round(x2, s2);

    wire [31:0] b3 = x4 ^ x5 ^ x6 ^ rk3;
    wire [31:0] s3;
    sm4_subword i_sub3 (.word_o(s3), .word_i(b3));
    wire [31:0] x7 = sm4_round(x3, s3);

    assign rnd_state_o = {x7, x6, x5, x4};

    function [31:0] sm_rol32;
        input [31:0] x;
        input integer s;
        begin
            sm_rol32 = (x << s) | (x >> (32 - s));
        end
    endfunction

    function [31:0] sm4_round;
        input [31:0] x;
        input [31:0] s;
        begin
            sm4_round = x ^ (s ^ sm_rol32(s, 2) ^ sm_rol32(s, 10) ^
                       sm_rol32(s, 18) ^ sm_rol32(s, 24));
        end
    endfunction

endmodule

module sm4_subword
(
    output wire [31:0] word_o,
    input  wire [31:0] word_i
);
    sm4_sbox i_sbox3 (.fx(word_o[31:24]), .in(word_i[31:24]));
    sm4_sbox i_sbox2 (.fx(word_o[23:16]), .in(word_i[23:16]));
    sm4_sbox i_sbox1 (.fx(word_o[15: 8]), .in(word_i[15: 8]));
    sm4_sbox i_sbox0 (.fx(word_o[ 7: 0]), .in(word_i[ 7: 0]));
endmodule
