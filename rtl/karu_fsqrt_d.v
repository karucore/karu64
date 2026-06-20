//  karu_fsqrt_d.v
//  IEEE 754 binary64 square root, bit-serial digit-recurrence. Same
//  shape as karu_fsqrt (single) but with 11-bit exp / 53-bit mantissa
//  / bias 1023.  54-iteration restoring sqrt -> 1 + 52 result bits +
//  1 round bit; sticky = nonzero remainder.

`include "karu_fpkg.vh"

module karu_fsqrt_d (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,
    input  wire [63:0]  a,

    output reg          done,
    output reg [63:0]   res,
    output reg  [4:0]   flags,
    output wire [4:0]   latency
);
    //  ---- unpack + classify ----
    wire        a_sign = a[63];
    wire [10:0] a_exp  = a[62:52];
    wire [51:0] a_man  = a[51:0];
    wire        a_zero = (a_exp == 11'h000) && (a_man == 52'h0);
    wire        a_sub  = (a_exp == 11'h000) && (a_man != 52'h0);
    wire        a_inf  = (a_exp == 11'h7FF) && (a_man == 52'h0);
    wire        a_nan  = (a_exp == 11'h7FF) && (a_man != 52'h0);
    wire        a_snan = a_nan && !a_man[51];
    wire        a_iz   = a_zero;        //  true zero only; subnormals normalized

    function [5:0] clz52;
        input [51:0] v; integer i; reg fnd;
        begin
            clz52 = 6'd52; fnd = 1'b0;
            for (i = 51; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz52 = 6'd51 - i[5:0]; fnd = 1'b1; end
        end
    endfunction
    wire [5:0]  a_clz   = a_sub ? clz52(a_man) : 6'd0;
    wire [51:0] a_man_n = a_sub ? (a_man << (a_clz + 6'd1)) : a_man;

    wire neg_value = a_sign && !a_iz && !a_nan;

    wire special_active = a_nan || a_iz || a_inf || neg_value;
    wire [63:0] special_res =
        a_nan      ? `FP_D_QNAN :
        neg_value  ? `FP_D_QNAN :
        a_iz       ? a :
        a_inf      ? (a_sign ? `FP_D_QNAN : a) :
                     64'b0;
    wire [4:0]  special_flags =
        (a_snan    ? (5'b1 << `FF_NV) : 5'b0) |
        (neg_value ? (5'b1 << `FF_NV) : 5'b0) |
        ((a_inf && a_sign) ? (5'b1 << `FF_NV) : 5'b0);

    //  ---- normal path: digit-recurrence restoring sqrt ----
    //  Effective unbiased exponent; normalized subnormal = -1023 - a_clz.
    wire signed [12:0] exp_unb_s = a_sub
        ? (-13'sd1023 - {{7{1'b0}}, a_clz})
        : ($signed({2'b0, a_exp}) - 13'sd1023);
    wire        exp_odd = exp_unb_s[0];

    //  53-bit mantissa positioned in a 106-bit operand so the 54-iter
    //  loop produces a 54-bit quotient with leading 1 at bit 53.
    wire [52:0] a_mfull = {1'b1, a_man_n};
    wire [105:0] m_norm = exp_odd ? {a_mfull, 53'b0}
                                   : {1'b0, a_mfull, 52'b0};

    //  Result unbiased exp = floor(exp_unb / 2); rebias by +1023.
    wire signed [12:0] res_unb = (exp_unb_s - (exp_odd ? 13'sd1 : 13'sd0)) >>> 1;
    wire [10:0] res_exp_pre = res_unb[10:0] + 11'd1023;

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_FIN = 2'd2;
    reg [1:0]   state;
    reg [5:0]   cnt;
    reg [107:0] R;                  //  partial remainder, 108 bits for headroom
    reg [54:0]  Q;                  //  partial quotient (sqrt result), 55 bits
    reg [105:0] M;                  //  operand, consumed 2 bits/iter from MSB
    reg         sp_q;
    reg [63:0]  sp_res_q;
    reg [4:0]   sp_flags_q;
    reg [10:0]  exp_q;
    reg         sign_q;
    reg [2:0]   rm_q;

    wire [109:0] R_shifted = {R, M[105:104]};
    wire [109:0] trial     = {Q, 2'b01};
    wire        take      = (R_shifted >= trial);
    wire [107:0] R_next    = take ? R_shifted[107:0] - trial[107:0] : R_shifted[107:0];
    wire [54:0] Q_next    = take ? {Q[53:0], 1'b1} : {Q[53:0], 1'b0};
    wire [105:0] M_next    = {M[103:0], 2'b00};

    assign busy    = (state != S_IDLE);
    assign latency = 5'd31;                 //  clamped; actually 1+54+2

    //  ---- Final rounding / packing ----
    //  After 54 iterations, Q has 54 bits of result. Leading bit Q[53]
    //  is the implicit 1, Q[52:1] is the 52-bit fraction, Q[0] is round.
    //  Sticky = (R != 0).
    wire [51:0] m_field    = Q[52:1];
    wire        round_bit  = Q[0];
    wire        sticky_bit = |R;

    wire round_up =
        (rm_q == `FRM_RNE) ? (round_bit && (sticky_bit || m_field[0])) :
        (rm_q == `FRM_RTZ) ? 1'b0 :
        (rm_q == `FRM_RDN) ? (sign_q  && (round_bit || sticky_bit)) :
        (rm_q == `FRM_RUP) ? (!sign_q && (round_bit || sticky_bit)) :
        (rm_q == `FRM_RMM) ? round_bit :
                             1'b0;

    wire [53:0] m_rnd     = {1'b0, 1'b1, m_field} + {53'b0, round_up};
    wire        m_carry   = m_rnd[53];
    wire [51:0] m_final   = m_carry ? 52'b0 : m_rnd[51:0];
    wire [11:0] exp_final = {1'b0, exp_q} + {11'b0, m_carry};
    wire        inexact   = round_bit || sticky_bit;

    wire [63:0] normal_res = {sign_q, exp_final[10:0], m_final};
    wire [4:0]  normal_flags = inexact ? (5'b1 << `FF_NX) : 5'b0;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (req) begin
                    sign_q     <= a_sign;
                    exp_q      <= res_exp_pre;
                    sp_q       <= special_active;
                    sp_res_q   <= special_res;
                    sp_flags_q <= special_flags;
                    rm_q       <= rm;
                    Q          <= 55'b0;
                    R          <= 108'b0;
                    M          <= m_norm;
                    cnt        <= 6'd54;
                    state      <= S_RUN;
                end
                S_RUN: begin
                    Q   <= Q_next;
                    R   <= R_next;
                    M   <= M_next;
                    cnt <= cnt - 6'd1;
                    if (cnt == 6'd1) state <= S_FIN;
                end
                S_FIN: begin
                    res    <= sp_q ? sp_res_q   : normal_res;
                    flags  <= sp_q ? sp_flags_q : normal_flags;
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end
            endcase
        end
    end

    wire _unused = &{1'b0};
endmodule
