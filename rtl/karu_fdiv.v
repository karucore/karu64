//  karu_fdiv.v
//  IEEE 754 binary32 divide. Same handshake shape as karu_fsqrt.
//
//  The mantissa quotient is produced by an ITERATIVE restoring
//  digit-recurrence (radix 2^KARU_F_DIV_CYCLES, default 1 bit/cycle) instead
//  of a combinational Verilog `/` (which mapped to a wide ripple-carry array).
//  Bit-identical to floor((a_mfull<<26)/b_mfull): q_shift = (a_mfull>=b_mfull)
//  is quot[26], then Nfrac=26 restoring steps give quot[25:0], and the residue
//  after those steps is exactly num%den for the sticky bit.
//
//  Full IEEE subnormal support: subnormal inputs are normalized in place
//  (CLZ shift + negative effective biased exponent); subnormal results
//  underflow gradually (denormalized output, exp field 0) with correct
//  NX/UF flags (tininess after rounding, SoftFloat rule).

`include "karu_fpkg.vh"
`include "karu_cfg.vh"

module karu_fdiv (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,
    input  wire [31:0]  a,
    input  wire [31:0]  b,

    output reg          done,
    output reg [31:0]   res,
    output reg  [4:0]   flags,
    output wire [4:0]   latency
);
    localparam integer BPC   = (`KARU_F_DIV_CYCLES < 1) ? 1 : `KARU_F_DIV_CYCLES;
    localparam integer NFRAC = 26;  //  fractional quotient bits (quot[25:0])

    //  ==================================================================
    //  Unpack (subnormals: leading 0, normalized via CLZ)
    //  ==================================================================
    wire        a_sign = a[31];
    wire [7:0]  a_exp  = a[30:23];
    wire [22:0] a_man  = a[22:0];
    wire        a_zero = (a_exp == 0) && (a_man == 0);
    wire        a_sub  = (a_exp == 0) && (a_man != 0);
    wire        a_inf  = (a_exp == 8'hFF) && (a_man == 0);
    wire        a_nan  = (a_exp == 8'hFF) && (a_man != 0);
    wire        a_snan = a_nan && !a_man[22];

    wire        b_sign = b[31];
    wire [7:0]  b_exp  = b[30:23];
    wire [22:0] b_man  = b[22:0];
    wire        b_zero = (b_exp == 0) && (b_man == 0);
    wire        b_sub  = (b_exp == 0) && (b_man != 0);
    wire        b_inf  = (b_exp == 8'hFF) && (b_man == 0);
    wire        b_nan  = (b_exp == 8'hFF) && (b_man != 0);
    wire        b_snan = b_nan && !b_man[22];

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
    wire [4:0]  a_clz = a_sub ? clz23(a_man) : 5'd0;
    wire [4:0]  b_clz = b_sub ? clz23(b_man) : 5'd0;
    wire [22:0] a_man_n = a_sub ? (a_man << (a_clz + 5'd1)) : a_man;
    wire [22:0] b_man_n = b_sub ? (b_man << (b_clz + 5'd1)) : b_man;
    wire [23:0] a_mfull = {1'b1, a_man_n};
    wire [23:0] b_mfull = {1'b1, b_man_n};
    wire signed [10:0] a_eff = a_sub ? (11'sd0 - {{6{1'b0}}, a_clz}) : $signed({3'b0, a_exp});
    wire signed [10:0] b_eff = b_sub ? (11'sd0 - {{6{1'b0}}, b_clz}) : $signed({3'b0, b_exp});

    wire        a_iz = a_zero;      //  true zero only
    wire        b_iz = b_zero;
    wire        res_sign = a_sign ^ b_sign;

    //  ==================================================================
    //  Special cases
    //  ==================================================================
    wire any_nan     = a_nan || b_nan;
    wire any_snan    = a_snan || b_snan;
    wire inv_0_0     = a_iz && b_iz;
    wire inv_inf_inf = a_inf && b_inf;
    wire dz          = !a_iz && !a_nan && !a_inf && b_iz;   //  finite/0 -> inf

    wire special_active = any_nan || inv_0_0 || inv_inf_inf
                         || a_inf || b_inf || a_iz || dz;

    wire [31:0] special_res =
        any_nan      ? `FP_S_QNAN :
        inv_0_0      ? `FP_S_QNAN :
        inv_inf_inf  ? `FP_S_QNAN :
        dz           ? {res_sign, 8'hFF, 23'h0} :       //  x/0 -> signed inf
        a_inf        ? {res_sign, 8'hFF, 23'h0} :       //  inf/finite -> inf
        b_inf        ? {res_sign, 31'b0} :              //  finite/inf -> 0
        a_iz         ? {res_sign, 31'b0} :              //  0/finite -> 0
                       32'b0;
    wire [4:0]  special_flags =
        (any_snan    ? (5'b1 << `FF_NV) : 5'b0) |
        (inv_0_0     ? (5'b1 << `FF_NV) : 5'b0) |
        (inv_inf_inf ? (5'b1 << `FF_NV) : 5'b0) |
        (dz          ? (5'b1 << `FF_DZ) : 5'b0);

    //  ==================================================================
    //  Normal divide: iterative restoring a_mfull / b_mfull (both in [1,2))
    //  ==================================================================
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_FIN = 2'd2;
    reg [1:0]           state;
    reg [5:0]           cnt;            //  fractional bits remaining
    reg [23:0]          Yq;             //  divisor (b_mfull), < 2^24
    reg [23:0]          R;              //  partial remainder, always < Yq
    reg [25:0]          Q;              //  fractional quotient bits (quot[25:0])
    reg                 q26_q;          //  integer quotient bit (quot[26])
    reg signed [10:0]   exp_n_q;
    reg                 sign_q;
    reg [2:0]           rm_q;
    reg                 sp_q;
    reg [31:0]          sp_res_q;
    reg [4:0]           sp_flags_q;

    wire        q26_c  = (a_mfull >= b_mfull);
    wire [23:0] R_init = q26_c ? (a_mfull - b_mfull) : a_mfull;
    wire signed [10:0] exp_n_c = a_eff - b_eff + 11'sd127 - (q26_c ? 11'sd0 : 11'sd1);

    reg [24:0]  divR_t;
    reg [25:0]  divQ_t;
    reg         dq;
    reg [5:0]   nsteps;
    integer     dj;

    assign busy    = (state != S_IDLE);
    assign latency = 5'd28;             //  informational/clamped (issue gates on busy/done)

    //  ---- downstream operates on the registered quotient/remainder ----
    wire [26:0] quot   = {q26_q, Q};    //  quot[26:0]
    wire        rem_nz = |R;
    wire        q_shift = quot[26];
    wire [23:0] sig24 = q_shift ? quot[26:3] : quot[25:2];
    wire        g_in  = q_shift ? quot[2] : quot[1];
    wire        r_in  = q_shift ? quot[1] : quot[0];
    wire        s_in  = (q_shift ? quot[0] : 1'b0) | rem_nz;
    wire signed [10:0] exp_n = exp_n_q;

    //  ---- Unified denormal-aware normalize / round / pack ----
    wire [27:0] norm = {sig24, g_in, r_in, 1'b0, s_in}; //  leading 1 at bit27

    wire signed [10:0] dshift_s = (exp_n <= 0) ? (11'sd1 - exp_n) : 11'sd0;
    wire [10:0] dshift  = dshift_s[10:0];
    wire [27:0] dn      = (dshift >= 11'd28) ? 28'b0 : (norm >> dshift);
    wire        dn_lost = (dshift == 0) ? 1'b0 :
                          (dshift >= 11'd28) ? (|norm) :
                          (|(norm & (~({28{1'b1}} << dshift))));

    wire [23:0] dsig  = dn[27:4];
    wire        round_bit = dn[3];
    wire        sticky    = dn[2] | (|dn[1:0]) | dn_lost;
    wire        subnormal_region = (exp_n <= 0);

    wire round_up =
        (rm_q == `FRM_RNE) ? (round_bit && (sticky || dsig[0])) :
        (rm_q == `FRM_RTZ) ? 1'b0 :
        (rm_q == `FRM_RDN) ? (sign_q  && (round_bit || sticky)) :
        (rm_q == `FRM_RUP) ? (!sign_q && (round_bit || sticky)) :
        (rm_q == `FRM_RMM) ? round_bit :
                           1'b0;

    wire [24:0] mant_rnd  = {1'b0, dsig} + {24'b0, round_up};
    wire        rnd_carry = mant_rnd[24];
    wire        promote   = mant_rnd[23];
    wire        inexact   = round_bit || sticky;

    wire signed [10:0] exp_norm_final = exp_n + (rnd_carry ? 11'sd1 : 11'sd0);
    wire        over = !subnormal_region && (exp_norm_final >= 11'sd255);

    //  Tininess after rounding (SoftFloat rule): tiny unless rounding at
    //  normal precision (pre-denormalize) already reaches the smallest normal.
    wire nr_up =
        (rm_q == `FRM_RNE) ? (g_in && (r_in || s_in || sig24[0])) :
        (rm_q == `FRM_RTZ) ? 1'b0 :
        (rm_q == `FRM_RDN) ? (sign_q  && (g_in || r_in || s_in)) :
        (rm_q == `FRM_RUP) ? (!sign_q && (g_in || r_in || s_in)) :
        (rm_q == `FRM_RMM) ? g_in :
                           1'b0;
    wire reaches_normal = (({1'b0, sig24} + {24'b0, nr_up}) >= 25'h100_0000);
    wire tiny = subnormal_region && ((exp_n <= -11'sd1) || !reaches_normal);

    wire [31:0] over_res =
        ((rm_q == `FRM_RTZ) ||
         (rm_q == `FRM_RDN && !sign_q) ||
         (rm_q == `FRM_RUP &&  sign_q))
            ? {sign_q, 8'hFE, 23'h7FFFFF}
            : {sign_q, 8'hFF, 23'h000000};

    wire [31:0] normal_res =
        over ? over_res :
        subnormal_region ? {sign_q, (promote ? 8'd1 : 8'd0), mant_rnd[22:0]} :
                           {sign_q, exp_norm_final[7:0], (rnd_carry ? 23'b0 : mant_rnd[22:0])};

    wire [4:0] normal_flags =
        (over            ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (tiny && inexact ? (5'b1 << `FF_UF)                      : 5'b0) |
        (inexact && !over ? (5'b1 << `FF_NX)                     : 5'b0);

    wire [31:0] res_w   = sp_q ? sp_res_q   : normal_res;
    wire [4:0]  flags_w = sp_q ? sp_flags_q : normal_flags;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (req) begin
                    Yq         <= b_mfull;
                    R          <= R_init;
                    Q          <= 26'b0;
                    q26_q      <= q26_c;
                    exp_n_q    <= exp_n_c;
                    sign_q     <= res_sign;
                    rm_q       <= rm;
                    sp_q       <= special_active;
                    sp_res_q   <= special_res;
                    sp_flags_q <= special_flags;
                    cnt        <= NFRAC[5:0];
                    state      <= S_RUN;
                end
                S_RUN: begin
                    nsteps = (cnt > BPC[5:0]) ? BPC[5:0] : cnt;
                    divR_t = {1'b0, R};
                    divQ_t = Q;
                    for (dj = 0; dj < BPC; dj = dj + 1) begin
                        if (dj < nsteps) begin
                            divR_t = divR_t << 1;
                            dq     = (divR_t >= {1'b0, Yq});
                            if (dq) divR_t = divR_t - {1'b0, Yq};
                            divQ_t = {divQ_t[24:0], dq};
                        end
                    end
                    Q   <= divQ_t;
                    R   <= divR_t[23:0];
                    cnt <= cnt - nsteps;
                    if (cnt <= BPC[5:0]) state <= S_FIN;
                end
                S_FIN: begin
                    res   <= res_w;
                    flags <= flags_w;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

    wire _unused = &{1'b0};
endmodule
