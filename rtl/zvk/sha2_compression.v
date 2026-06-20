//------------------------------------------------------------------------------
// Module   : msg_schedule
//
// Project  : Vector-Crypto Subsystem (Marian)
// Author(s): Tom Szymkowiak <thomas.szymkowiak@tuni.fi>
// Created  : 22-may-2024
//
// Description: SHA-2 Operation module, containing reg to perform two rounds
//              of compression.
//              This module supports both SHA-256 and SHA-512 operations. In the
//              former case, only the first half of each word is used.
//              Taken from Sail code listed within:
//              RISC-V Cryptography Extensions Volume II : Vector Instructions
//              Version v1.0.0, 22 August 2023 RC3,
//              Chapter 3.21 vsha2c[hl].vv
//
// Parameters:
//  - None
//
// Inputs:
//  - c_state_0_i    : current state {c, d, g, h} (vd)
//  - c_state_1_i    : current state {a, b, e, f} (vs2)
//  - msg_sched_pc_i : message schedule + constant (vs1)
//  - sha_op_i       :
//    0 = HIGH PART SEW32 (SHA256)
//    1 = HIGH PART SEW64 (SHA512)
//    2 = LOW PART SEW32 (SHA256)
//    3 = LOW PART SEW64 (SHA512)
//
// Outputs:
//  - n_state_o : next state {a, b, e, f}
//
// Revision History:
//  - Version 1.0: Initial release
//
//------------------------------------------------------------------------------

module compression
(
    input wire [256-1:0] c_state_0_i,
    input wire [256-1:0] c_state_1_i,
    input wire [256-1:0] msg_sched_pc_i,
    input wire [  1:0] sha_op_i,

    output wire [256-1:0] n_state_o
);

    localparam SHA2_COMP_HIGH = 1'b0;
    localparam SHA2_COMP_LOW  = 1'b1;

/***********
    * SIGNALS *
    ***********/

    reg [31:0] a_32, b_32, c_32, d_32, e_32, f_32, g_32, h_32;
    reg [63:0] a_64, b_64, c_64, d_64, e_64, f_64, g_64, h_64;

    reg [31:0] msg_sched_pc_32_s [0:3];
    reg [63:0] msg_sched_pc_64_s [0:3];

    reg [31:0] W0_32, W1_32;
    reg [63:0] W0_64, W1_64;

    reg [31:0] T1_32, T2_32;
    reg [63:0] T1_64, T2_64;

    reg [255:0] n_state_s;


/*********************
    * MESSAGE SHEDULING *
    *********************/

    always @* begin

        // default assignments
        a_32 = 32'b0;            a_64 = 64'b0;
        b_32 = 32'b0;            b_64 = 64'b0;
        c_32 = 32'b0;            c_64 = 64'b0;
        d_32 = 32'b0;            d_64 = 64'b0;
        e_32 = 32'b0;            e_64 = 64'b0;
        f_32 = 32'b0;            f_64 = 64'b0;
        g_32 = 32'b0;            g_64 = 64'b0;
        h_32 = 32'b0;            h_64 = 64'b0;

        msg_sched_pc_32_s[0] = 32'b0; msg_sched_pc_32_s[1] = 32'b0;
        msg_sched_pc_32_s[2] = 32'b0; msg_sched_pc_32_s[3] = 32'b0;
        msg_sched_pc_64_s[0] = 64'b0; msg_sched_pc_64_s[1] = 64'b0;
        msg_sched_pc_64_s[2] = 64'b0; msg_sched_pc_64_s[3] = 64'b0;

        W0_32 = 32'b0;           W0_64 = 64'b0;
        W1_32 = 32'b0;           W1_64 = 64'b0;

        T1_32 = 32'b0;           T1_64 = 64'b0;
        T2_32 = 32'b0;           T2_64 = 64'b0;

        n_state_s = 256'b0;


        if (sha_op_i[0] == 1'b1) begin // SHA-512 (SEW64)

            // initial assignments
            {a_64, b_64, e_64, f_64} = c_state_1_i;
            {c_64, d_64, g_64, h_64} = c_state_0_i;

            {msg_sched_pc_64_s[3], msg_sched_pc_64_s[2],
            msg_sched_pc_64_s[1], msg_sched_pc_64_s[0]} = msg_sched_pc_i;

            {W1_64, W0_64} = (sha_op_i[1] == SHA2_COMP_LOW) ?
                        {msg_sched_pc_64_s[1], msg_sched_pc_64_s[0]} :
                        {msg_sched_pc_64_s[3], msg_sched_pc_64_s[2]};

            T1_64 = h_64 + sum1_64(e_64) + ch_64(e_64, f_64, g_64) + W0_64;
            T2_64 = sum0_64(a_64) + maj_64(a_64, b_64, c_64);

            h_64 = g_64;
            g_64 = f_64;
            f_64 = e_64;
            e_64 = d_64 + T1_64;
            d_64 = c_64;
            c_64 = b_64;
            b_64 = a_64;
            a_64 = T1_64 + T2_64;

            T1_64 = h_64 + sum1_64(e_64) + ch_64(e_64, f_64, g_64) + W1_64;
            T2_64 = sum0_64(a_64) + maj_64(a_64, b_64, c_64);

            h_64 = g_64;
            g_64 = f_64;
            f_64 = e_64;
            e_64 = d_64 + T1_64;
            d_64 = c_64;
            c_64 = b_64;
            b_64 = a_64;
            a_64 = T1_64 + T2_64;

            n_state_s = {a_64, b_64, e_64, f_64};

        end else begin // SHA-256 (SEW32)

            // initial assignments (only extract lower half of buffer when SEW32)
            {a_32, b_32, e_32, f_32} = c_state_1_i[127:0];
            {c_32, d_32, g_32, h_32} = c_state_0_i[127:0];

            {msg_sched_pc_32_s[3], msg_sched_pc_32_s[2],
            msg_sched_pc_32_s[1], msg_sched_pc_32_s[0]} = msg_sched_pc_i[127:0];

            {W1_32, W0_32} = (sha_op_i[1] == SHA2_COMP_LOW) ?
                        {msg_sched_pc_32_s[1], msg_sched_pc_32_s[0]} :
                        {msg_sched_pc_32_s[3], msg_sched_pc_32_s[2]};

            T1_32 = h_32 + sum1_32(e_32) + ch_32(e_32, f_32, g_32) + W0_32;
            T2_32 = sum0_32(a_32) + maj_32(a_32, b_32, c_32);

            h_32 = g_32;
            g_32 = f_32;
            f_32 = e_32;
            e_32 = d_32 + T1_32;
            d_32 = c_32;
            c_32 = b_32;
            b_32 = a_32;
            a_32 = T1_32 + T2_32;

            T1_32 = h_32 + sum1_32(e_32) + ch_32(e_32, f_32, g_32) + W1_32;
            T2_32 = sum0_32(a_32) + maj_32(a_32, b_32, c_32);

            h_32 = g_32;
            g_32 = f_32;
            f_32 = e_32;
            e_32 = d_32 + T1_32;
            d_32 = c_32;
            c_32 = b_32;
            b_32 = a_32;
            a_32 = T1_32 + T2_32;

            // only fill lower half of output buffer when SEW32
            n_state_s[127:0] = {a_32, b_32, e_32, f_32};

        end

    end

/*********************
    * OUTPUT ASSIGNMENT *
    *********************/

    assign n_state_o = n_state_s;

/************************
    * FUNCTION DEFINITIONS *
    ************************/

    // Circular rotate right for SEW64
    function [63:0] ROTR_64;
        input [63:0] x;
        input integer n;
        begin
            ROTR_64 = ((x >> n) | (x << (64 - n)));
        end
    endfunction

    // Circular rotate right for SEW32
    function [31:0] ROTR_32;
        input [31:0] x;
        input integer n;
        begin
            ROTR_32 = ((x >> n) | (x << (32 - n)));
        end
    endfunction

    // sum0 for SEW64
    function [63:0] sum0_64;
        input [63:0] x;
        begin
            sum0_64 = (ROTR_64(x, 28) ^ ROTR_64(x, 34) ^ ROTR_64(x, 39));
        end
    endfunction

    // sum0 for SEW32
    function [31:0] sum0_32;
        input [31:0] x;
        begin
            sum0_32 = (ROTR_32(x, 2) ^ ROTR_32(x, 13) ^ ROTR_32(x, 22));
        end
    endfunction

    // sum1 for SEW64
    function [63:0] sum1_64;
        input [63:0] x;
        begin
            sum1_64 = (ROTR_64(x, 14) ^ ROTR_64(x, 18) ^ ROTR_64(x, 41));
        end
    endfunction

    // sum1 for SEW32
    function [31:0] sum1_32;
        input [31:0] x;
        begin
            sum1_32 = (ROTR_32(x, 6) ^ ROTR_32(x, 11) ^ ROTR_32(x, 25));
        end
    endfunction

    // ch function for SEW64
    function [63:0] ch_64;
        input [63:0] x;
        input [63:0] y;
        input [63:0] z;
        begin
            ch_64 = ((x & y) ^ ((~x) & z));
        end
    endfunction

    // ch function for SEW32
    function [31:0] ch_32;
        input [31:0] x;
        input [31:0] y;
        input [31:0] z;
        begin
            ch_32 = ((x & y) ^ ((~x) & z));
        end
    endfunction

    // maj function for SEW64
    function [63:0] maj_64;
        input [63:0] x;
        input [63:0] y;
        input [63:0] z;
        begin
            maj_64 = ((x & y) ^ (x & z) ^ (y & z));
        end
    endfunction

    // maj function for SEW32
    function [31:0] maj_32;
        input [31:0] x;
        input [31:0] y;
        input [31:0] z;
        begin
            maj_32 = ((x & y) ^ (x & z) ^ (y & z));
        end
    endfunction

endmodule
