//------------------------------------------------------------------------------
// Module   : sm3_msg_expansion
//
// Project  : Vector-Crypto Subsystem (Marian)
// Author(s): Endrit Isufi <endrit.isufi@tuni.fi>
// Created  : 10-July-2024
//
// Description: Vector SM3 Message expansion, containing logic to perform
//              eight rounds of SM3 message expansions.
//              Implemented using Sail specification defined within :
//              RISC-V Cryptography Extensions Volume II Vector Instructions
//              Version v1.0.0, 5 October 2023: RC3
//
// Parameters:
//  - None
//
// Inputs:
//  - msg_words_start_i: Message words W[7:0]
//  - msg_words_end_i  : Message words W[15:8]
//
// Outputs:
//  - msg_words_o      : Message words W[23:16]
//
// Revision History:
//  - Version 1.0: Initial release
//
//------------------------------------------------------------------------------

module sm3_msg_expansion
(
        input  wire [255:0] msg_words_start_i,
        input  wire [255:0] msg_words_end_i,

        output wire [255:0] msg_words_o
);

/***********
    * SIGNALS *
    ***********/

    reg [255:0] msg_words_start_s;
    reg [255:0] msg_words_end_s;
    reg [255:0] res_msg_words_s;

    reg [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
    reg [31:0] w8, w9, w10, w11, w12, w13, w14, w15;
    reg [31:0] w16, w17, w18, w19, w20, w21, w22, w23;

    /************************
    * SM3 MESSAGE EXPANSION *
    ************************/

    always @(*) begin
    //initial assignments
    w0  = 32'h0;
    w1  = 32'h0;
    w2  = 32'h0;
    w3  = 32'h0;
    w4  = 32'h0;
    w5  = 32'h0;
    w6  = 32'h0;
    w7  = 32'h0;
    w8  = 32'h0;
    w9  = 32'h0;
    w10  = 32'h0;
    w11  = 32'h0;
    w12  = 32'h0;
    w13  = 32'h0;
    w14  = 32'h0;
    w15  = 32'h0;
    w17 = 32'h0;
    w18 = 32'h0;
    w16 = 32'h0;
    w19 = 32'h0;
    w20 = 32'h0;
    w21 = 32'h0;
    w22 = 32'h0;
    w23 = 32'h0;
    msg_words_start_s = 256'h0;
    msg_words_end_s   = 256'h0;
    res_msg_words_s   = 256'h0;

    // SM3 message expansion logic
    msg_words_start_s = msg_words_start_i;
    msg_words_end_s   = msg_words_end_i;

    w0  = sm_rev8(msg_words_start_s[ 31:  0]);
    w1  = sm_rev8(msg_words_start_s[ 63: 32]);
    w2  = sm_rev8(msg_words_start_s[ 95: 64]);
    w3  = sm_rev8(msg_words_start_s[127: 96]);
    w4  = sm_rev8(msg_words_start_s[159:128]);
    w5  = sm_rev8(msg_words_start_s[191:160]);
    w6  = sm_rev8(msg_words_start_s[223:192]);
    w7  = sm_rev8(msg_words_start_s[255:224]);
    w8  = sm_rev8(msg_words_end_s[ 31:  0]);
    w9  = sm_rev8(msg_words_end_s[ 63: 32]);
    w10 = sm_rev8(msg_words_end_s[ 95: 64]);
    w11 = sm_rev8(msg_words_end_s[127: 96]);
    w12 = sm_rev8(msg_words_end_s[159:128]);
    w13 = sm_rev8(msg_words_end_s[191:160]);
    w14 = sm_rev8(msg_words_end_s[223:192]);
    w15 = sm_rev8(msg_words_end_s[255:224]);

    w16 = sm_zvksh_w(w0, w7,  w13, w3,  w10);
    w17 = sm_zvksh_w(w1, w8,  w14, w4,  w11);
    w18 = sm_zvksh_w(w2, w9,  w15, w5,  w12);
    w19 = sm_zvksh_w(w3, w10, w16, w6,  w13);
    w20 = sm_zvksh_w(w4, w11, w17, w7,  w14);
    w21 = sm_zvksh_w(w5, w12, w18, w8,  w15);
    w22 = sm_zvksh_w(w6, w13, w19, w9,  w16);
    w23 = sm_zvksh_w(w7, w14, w20, w10, w17);


    w16 = sm_rev8(w16);
    w17 = sm_rev8(w17);
    w18 = sm_rev8(w18);
    w19 = sm_rev8(w19);
    w20 = sm_rev8(w20);
    w21 = sm_rev8(w21);
    w22 = sm_rev8(w22);
    w23 = sm_rev8(w23);

    res_msg_words_s = {w23, w22, w21, w20, w19, w18, w17, w16};

    end

    assign msg_words_o = res_msg_words_s;

    /***********************
    * FUNCTION DEFINITIONS *
    ************************/

    //rotate X by a factor of S
    function [31:0] sm_ROL32;
        input [31:0] X;
        input integer S;
        begin
            sm_ROL32 = ((X << S) | (X >> (32 - S)));
        end
    endfunction

    // permutation
    function [31:0] sm_p_1;
    input [31:0] X;
    begin
        sm_p_1 = (X ^ sm_ROL32(X, 15) ^ sm_ROL32(X, 23));
    end
    endfunction

    /*endian byte swap */
    function [31:0] sm_rev8;
        input [31:0] word_i;
        begin
            sm_rev8 = (word_i >> 24 & 8'hff) |
                (word_i << 8 & 24'hff0000) |
                (word_i >> 8 & 16'hff00) |
                (word_i << 24 & 32'hff000000);
        end
    endfunction

    function [31:0] sm_zvksh_w;
        input [31:0] M16, M9, M3, M13, M6;
        begin
            sm_zvksh_w = (sm_p_1(M16 ^ M9 ^ sm_ROL32(M3, 15)) ^ sm_ROL32(M13, 7) ^ M6);
        end
    endfunction


endmodule
