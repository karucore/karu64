//  karu_fsqrt.v
//  IEEE 754 binary32 square root, bit-serial digit-recurrence.
//  Same handshake as the other multi-cycle FPU units.
//
//  Algorithm: 25-iteration restoring sqrt. Each iteration produces one
//  bit of the result and consumes two bits of the (normalized) input.
//  Special cases (NaN, -x, +/-inf, zero) bypass the loop and emit on
//  the cycle after req (latency 2).

`include "karu_fpkg.vh"

module karu_fsqrt (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,
    input  wire [31:0]  a,

    output reg          done,
    output reg [31:0]   res,
    output reg  [4:0]   flags,
    output wire [4:0]   latency
);
    //  ==================================================================
    //  Unpack + special-case classification
    //  ==================================================================
    wire        a_sign = a[31];
    wire [7:0]  a_exp  = a[30:23];
    wire [22:0] a_man  = a[22:0];
    wire        a_zero = (a_exp == 0) && (a_man == 0);
    wire        a_sub  = (a_exp == 0) && (a_man != 0);
    wire        a_inf  = (a_exp == 8'hFF) && (a_man == 0);
    wire        a_nan  = (a_exp == 8'hFF) && (a_man != 0);
    wire        a_snan = a_nan && !a_man[22];
    wire        a_iz   = a_zero;        //  true zero only; subnormals normalized

    function [4:0] clz23;
        input [22:0] v;
        integer i;
        reg fnd;
        begin
            clz23 = 5'd23; fnd = 1'b0;
            for (i = 22; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz23 = 5'd22 - i[4:0]; fnd = 1'b1; end
        end
    endfunction
    wire [4:0]  a_clz   = a_sub ? clz23(a_man) : 5'd0;
    wire [22:0] a_man_n = a_sub ? (a_man << (a_clz + 5'd1)) : a_man;

    //  sqrt(-x) for x>0 is invalid -> qNaN, NV
    //  sqrt(-0)  = -0 (spec)
    //  sqrt(+0)  = +0
    //  sqrt(+inf)= +inf
    //  sqrt(-inf)= qNaN, NV
    wire neg_value = a_sign && !a_iz && !a_nan;

    wire special_active = a_nan || a_iz || a_inf || neg_value;
    wire [31:0] special_res =
        a_nan      ? `FP_S_QNAN :
        neg_value  ? `FP_S_QNAN :
        a_iz       ? a :                    //  signed zero preserved
        a_inf      ? (a_sign ? `FP_S_QNAN : a) :
                     32'b0;
    wire [4:0]  special_flags =
        (a_snan    ? (5'b1 << `FF_NV) : 5'b0) |
        (neg_value ? (5'b1 << `FF_NV) : 5'b0) |
        ((a_inf && a_sign) ? (5'b1 << `FF_NV) : 5'b0);

    //  ==================================================================
    //  Normal path: bit-serial sqrt
    //  ==================================================================
    //  Normalize the input: split exponent into an even biased value and
    //  an odd-parity adjustment on the mantissa.
    //    exp_unb = a_exp - 127
    //    if exp_unb is even: sqrt input = 1.mantissa (24 bits), result
    //                        mantissa is the 24-bit sqrt of that.
    //    if exp_unb is odd : sqrt input = (1.mantissa * 2) shifted up by 1
    //                        so the algorithm sees a 25-bit normalized value.
    //  Result exponent = (exp_unb + (odd ? 1 : 0)) / 2 = (a_exp - 127 + odd) / 2.
    //  After unbias for the output: result a_exp = ((a_exp - 127 + odd) / 2) + 127
    //                                            = (a_exp + 127 + odd) / 2 (rounded).
    //  Effective unbiased exponent. A normalized subnormal (leading 1
    //  shifted up by a_clz+1) has unbiased exponent -127 - a_clz.
    wire signed [10:0] exp_unb_s = a_sub
        ? (-11'sd127 - {{6{1'b0}}, a_clz})
        : ($signed({3'b0, a_exp}) - 11'sd127);
    wire        exp_odd = exp_unb_s[0];

    //  Build the 48-bit normalized operand for the sqrt loop:
    //    if exp_odd: m = {1, a_man, 24'b0} >> 0 = {01.mantissa, ...} (no, 2x = 1.mantissa shifted left by 1)
    //    if even:    m = {1, a_man, 24'b0}
    //  The sqrt loop expects the operand "fully fractional" so the top bit
    //  is implicit 1 at the top of the working range.
    //
    //  Simpler formulation: feed 48 bits where the leading 1 is at:
    //    bit 47 for even exp (mantissa in [1, 2))
    //    bit 46 for odd  exp (mantissa in [1, 2)*2 = [2, 4) shifted down 1 to fit bit 46)
    //  Actually let me re-derive carefully...
    //
    //  The standard normalization: arrange the operand as a pair of
    //  groups of 2 bits, with leading 1 at the top of a 2-bit group.
    //  For 1.frac in [1, 2): leading 1 at bit 23 of the 24-bit mantissa.
    //    - if exp_unb even: shift left by 0
    //    - if exp_unb odd:  shift left by 1 to keep the leading 1 at an
    //                       odd bit position so the sqrt loop sees a 2x
    //                       operand
    //  Position mant_full = {1, a_man} in a 48-bit operand so the
    //  bit-serial sqrt yields a 24-bit Q with the leading 1 at bit 23.
    //    exp_odd=0 (even E): X = mant_full * 2^23 (47-bit, top bit at 46)
    //    exp_odd=1 (odd  E): X = mant_full * 2^24 (48-bit, top bit at 47)
    wire [23:0] a_mfull = {1'b1, a_man_n};
    wire [47:0] m_norm  = exp_odd ? {a_mfull, 24'b0}
                                   : {1'b0, a_mfull, 23'b0};

    //  Result exp (biased):
    //    even: (a_exp + 127) / 2
    //    odd : (a_exp + 126) / 2
    //  Result unbiased exp = floor(exp_unb / 2); rebias by +127.
    wire signed [10:0] res_unb = (exp_unb_s - (exp_odd ? 11'sd1 : 11'sd0)) >>> 1;
    wire [7:0] res_exp_pre = res_unb[7:0] + 8'd127;

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_FIN = 2'd2;
    reg [1:0]   state;
    reg [4:0]   cnt;
    reg [49:0]  R;                  //  partial remainder, 50 bits for headroom
    reg [25:0]  Q;                  //  partial quotient (sqrt result), 26 bits
    reg [47:0]  M;                  //  operand, consumed 2 bits/iter (from MSB)
    reg         sp_q;
    reg [31:0]  sp_res_q;
    reg [4:0]   sp_flags_q;
    reg [7:0]   exp_q;
    reg         sign_q;
    reg [2:0]   rm_q;

    //  per-iteration combinational step
    wire [51:0] R_shifted = {R, M[47:46]};  //  (R << 2) | top 2 bits of M
    wire [51:0] trial     = {Q, 2'b01};     //  (Q << 2) | 01 = Q*4 + 1
    wire        take      = (R_shifted >= trial);
    wire [49:0] R_next    = take ? R_shifted[49:0] - trial[49:0] : R_shifted[49:0];
    wire [25:0] Q_next    = take ? {Q[24:0], 1'b1} : {Q[24:0], 1'b0};
    wire [47:0] M_next    = {M[45:0], 2'b00};

    assign busy    = (state != S_IDLE);
    assign latency = 5'd28;                 //  ~1 setup + 25 iter + 2 fin

    //  ---- Final rounding / packing (combinational on Q/R when done) ----
    //  After 25 iterations, Q has 25 bits of result. Leading bit Q[24]
    //  is the implicit 1 of the mantissa. Bits Q[23:1] are the 23-bit
    //  mantissa fraction. Q[0] is the round bit. Sticky = (R != 0).
    wire [22:0] m_field    = Q[23:1];
    wire        round_bit  = Q[0];
    wire        sticky_bit = |R;

    wire round_up =
        (rm_q == `FRM_RNE) ? (round_bit && (sticky_bit || m_field[0])) :
        (rm_q == `FRM_RTZ) ? 1'b0 :
        (rm_q == `FRM_RDN) ? (sign_q  && (round_bit || sticky_bit)) :
        (rm_q == `FRM_RUP) ? (!sign_q && (round_bit || sticky_bit)) :
        (rm_q == `FRM_RMM) ? round_bit :
                             1'b0;

    wire [24:0] m_rnd     = {1'b0, 1'b1, m_field} + {24'b0, round_up};
    wire        m_carry   = m_rnd[24];
    wire [22:0] m_final   = m_carry ? 23'b0 : m_rnd[22:0];
    wire [8:0]  exp_final = {1'b0, exp_q} + {8'b0, m_carry};
    wire        inexact   = round_bit || sticky_bit;

    wire [31:0] normal_res = {sign_q, exp_final[7:0], m_final};
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
                    Q          <= 26'b0;
                    R          <= 50'b0;
                    M          <= m_norm;
                    cnt        <= 5'd25;
                    state      <= S_RUN;
                end
                S_RUN: begin
                    Q   <= Q_next;
                    R   <= R_next;
                    M   <= M_next;
                    cnt <= cnt - 5'd1;
                    if (cnt == 5'd1) state <= S_FIN;
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
