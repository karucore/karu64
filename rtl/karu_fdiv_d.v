//  karu_fdiv_d.v
//  IEEE 754 binary64 divide. Widening of karu_fdiv (single) to D:
//  53-bit mantissa, 11-bit exp, bias 1023.
//
//  The mantissa quotient is produced by an ITERATIVE restoring
//  digit-recurrence (radix 2^KARU_D_DIV_CYCLES, default 1 bit/cycle) instead
//  of a combinational Verilog `/`. This avoids a 108-bit divide cone in the
//  125 MHz timing path. The result is
//  bit-identical to floor((a_mfull<<55)/b_mfull): q_shift = (a_mfull>=b_mfull)
//  is quot[55], then Nfrac=55 restoring steps give quot[54:0], and the residue
//  after those steps is exactly num%den for the sticky bit.
//
//  Full IEEE subnormal support: subnormal inputs normalized in place (CLZ
//  + negative effective biased exponent); subnormal results underflow
//  gradually with exact NX/UF (tininess after rounding, SoftFloat rule).

`include "karu_fpkg.vh"
`include "karu_cfg.vh"

module karu_fdiv_d (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,
    input  wire [63:0]  a,
    input  wire [63:0]  b,

    output reg          done,
    output reg [63:0]   res,
    output reg  [4:0]   flags,
    output wire [4:0]   latency
);
    //  radix: quotient bits resolved per cycle (>=1)
    localparam integer BPC   = (`KARU_D_DIV_CYCLES < 1) ? 1 : `KARU_D_DIV_CYCLES;
    localparam integer NFRAC = 55;  //  fractional quotient bits (quot[54:0])

    //  ---- unpack (subnormals normalized via CLZ) ----
    wire        a_sign = a[63];
    wire [10:0] a_exp  = a[62:52];
    wire [51:0] a_man  = a[51:0];
    wire        a_zero = (a_exp == 11'h000) && (a_man == 52'h0);
    wire        a_sub  = (a_exp == 11'h000) && (a_man != 52'h0);
    wire        a_inf  = (a_exp == 11'h7FF) && (a_man == 52'h0);
    wire        a_nan  = (a_exp == 11'h7FF) && (a_man != 52'h0);
    wire        a_snan = a_nan && !a_man[51];

    wire        b_sign = b[63];
    wire [10:0] b_exp  = b[62:52];
    wire [51:0] b_man  = b[51:0];
    wire        b_zero = (b_exp == 11'h000) && (b_man == 52'h0);
    wire        b_sub  = (b_exp == 11'h000) && (b_man != 52'h0);
    wire        b_inf  = (b_exp == 11'h7FF) && (b_man == 52'h0);
    wire        b_nan  = (b_exp == 11'h7FF) && (b_man != 52'h0);
    wire        b_snan = b_nan && !b_man[51];

    function [5:0] clz52;
        input [51:0] v; integer i; reg fnd;
        begin
            clz52 = 6'd52; fnd = 1'b0;
            for (i = 51; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz52 = 6'd51 - i[5:0]; fnd = 1'b1; end
        end
    endfunction
    wire [5:0]  a_clz = a_sub ? clz52(a_man) : 6'd0;
    wire [5:0]  b_clz = b_sub ? clz52(b_man) : 6'd0;
    wire [51:0] a_man_n = a_sub ? (a_man << (a_clz + 6'd1)) : a_man;
    wire [51:0] b_man_n = b_sub ? (b_man << (b_clz + 6'd1)) : b_man;
    wire [52:0] a_mfull = {1'b1, a_man_n};
    wire [52:0] b_mfull = {1'b1, b_man_n};
    wire signed [12:0] a_eff = a_sub ? (13'sd0 - {{7{1'b0}}, a_clz}) : $signed({2'b0, a_exp});
    wire signed [12:0] b_eff = b_sub ? (13'sd0 - {{7{1'b0}}, b_clz}) : $signed({2'b0, b_exp});

    wire        a_iz = a_zero;
    wire        b_iz = b_zero;
    wire        res_sign = a_sign ^ b_sign;

    //  ---- special cases ----
    wire any_nan  = a_nan || b_nan;
    wire any_snan = a_snan || b_snan;
    wire inv_0_0  = a_iz && b_iz;
    wire inv_inf_inf = a_inf && b_inf;
    wire dz       = !a_iz && !a_nan && !a_inf && b_iz;

    wire special_active = any_nan || inv_0_0 || inv_inf_inf
                         || a_inf || b_inf || a_iz || dz;

    wire [63:0] special_res =
        any_nan      ? `FP_D_QNAN :
        inv_0_0      ? `FP_D_QNAN :
        inv_inf_inf  ? `FP_D_QNAN :
        dz           ? {res_sign, 11'h7FF, 52'h0} :
        a_inf        ? {res_sign, 11'h7FF, 52'h0} :
        b_inf        ? {res_sign, 63'b0} :
        a_iz         ? {res_sign, 63'b0} :
                       64'b0;
    wire [4:0]  special_flags =
        (any_snan    ? (5'b1 << `FF_NV) : 5'b0) |
        (inv_0_0     ? (5'b1 << `FF_NV) : 5'b0) |
        (inv_inf_inf ? (5'b1 << `FF_NV) : 5'b0) |
        (dz          ? (5'b1 << `FF_DZ) : 5'b0);

    //  ---- iterative restoring divide (a_mfull / b_mfull) ----
    //  q_shift = (a_mfull >= b_mfull) is the integer bit quot[55]; the residue
    //  starts at (a_mfull - b_mfull) when set, else a_mfull (always < b_mfull).
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_FIN = 2'd2;
    reg [1:0]           state;
    reg [6:0]           cnt;            //  fractional bits remaining
    reg [52:0]          Yq;             //  divisor (b_mfull), < 2^53
    reg [52:0]          R;              //  partial remainder, always < Yq
    reg [54:0]          Q;              //  fractional quotient bits (quot[54:0])
    reg                 q55_q;          //  integer quotient bit (quot[55])
    reg signed [12:0]   exp_n_q;
    reg                 sign_q;
    reg [2:0]           rm_q;
    reg                 sp_q;
    reg [63:0]          sp_res_q;
    reg [4:0]           sp_flags_q;

    wire        q55_c = (a_mfull >= b_mfull);
    wire [52:0] R_init = q55_c ? (a_mfull - b_mfull) : a_mfull;
    //  exp_n: a_eff - b_eff + bias, minus 1 when the quotient did NOT carry
    //  into bit 55 (q_shift==0), matching the original combinational form.
    wire signed [12:0] exp_n_c = a_eff - b_eff + 13'sd1023 - (q55_c ? 13'sd0 : 13'sd1);

    //  per-cycle radix-2^BPC restoring step block
    reg [53:0]  divR_t;
    reg [54:0]  divQ_t;
    reg         dq;
    reg [6:0]   nsteps;
    integer     dj;

    assign busy    = (state != S_IDLE);
    assign latency = 5'd31;             //  informational/clamped (issue gates on busy/done)

    //  ---- downstream operates on the registered quotient/remainder ----
    wire [55:0] quot   = {q55_q, Q};    //  quot[55:0]
    wire        rem_nz = |R;
    wire        q_shift = quot[55];
    wire [52:0] sig53 = q_shift ? quot[55:3] : quot[54:2];
    wire        g_in  = q_shift ? quot[2] : quot[1];
    wire        r_in  = q_shift ? quot[1] : quot[0];
    wire        s_in  = (q_shift ? quot[0] : 1'b0) | rem_nz;
    wire signed [12:0] exp_n = exp_n_q;

    //  ---- unified denormal-aware normalize / round / pack ----
    wire [56:0] norm = {sig53, g_in, r_in, 1'b0, s_in}; //  leading 1 at bit56

    wire signed [12:0] dshift_s = (exp_n <= 0) ? (13'sd1 - exp_n) : 13'sd0;
    wire [12:0] dshift  = dshift_s[12:0];
    wire [56:0] dn      = (dshift >= 13'd57) ? 57'b0 : (norm >> dshift);
    wire        dn_lost = (dshift == 0) ? 1'b0 :
                          (dshift >= 13'd57) ? (|norm) :
                          (|(norm & (~({57{1'b1}} << dshift))));

    wire [52:0] dsig  = dn[56:4];
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

    wire [53:0] mant_rnd  = {1'b0, dsig} + {53'b0, round_up};
    wire        rnd_carry = mant_rnd[53];
    wire        promote   = mant_rnd[52];
    wire        inexact   = round_bit || sticky;

    wire signed [12:0] exp_norm_final = exp_n + (rnd_carry ? 13'sd1 : 13'sd0);
    wire        over = !subnormal_region && (exp_norm_final >= 13'sd2047);

    wire nr_up =
        (rm_q == `FRM_RNE) ? (g_in && (r_in || s_in || sig53[0])) :
        (rm_q == `FRM_RTZ) ? 1'b0 :
        (rm_q == `FRM_RDN) ? (sign_q  && (g_in || r_in || s_in)) :
        (rm_q == `FRM_RUP) ? (!sign_q && (g_in || r_in || s_in)) :
        (rm_q == `FRM_RMM) ? g_in :
                           1'b0;
    wire reaches_normal = (({1'b0, sig53} + {53'b0, nr_up}) >= 54'h20_0000_0000_0000);
    wire tiny = subnormal_region && ((exp_n <= -13'sd1) || !reaches_normal);

    wire [63:0] over_res =
        ((rm_q == `FRM_RTZ) ||
         (rm_q == `FRM_RDN && !sign_q) ||
         (rm_q == `FRM_RUP &&  sign_q))
            ? {sign_q, 11'h7FE, 52'hF_FFFF_FFFF_FFFF}
            : {sign_q, 11'h7FF, 52'h0};

    wire [63:0] normal_res =
        over ? over_res :
        subnormal_region ? {sign_q, (promote ? 11'd1 : 11'd0), mant_rnd[51:0]} :
                           {sign_q, exp_norm_final[10:0], (rnd_carry ? 52'b0 : mant_rnd[51:0])};

    wire [4:0]  normal_flags =
        (over            ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (tiny && inexact ? (5'b1 << `FF_UF)                      : 5'b0) |
        (inexact && !over ? (5'b1 << `FF_NX)                     : 5'b0);

    wire [63:0] res_w   = sp_q ? sp_res_q   : normal_res;
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
                    Q          <= 55'b0;
                    q55_q      <= q55_c;
                    exp_n_q    <= exp_n_c;
                    sign_q     <= res_sign;
                    rm_q       <= rm;
                    sp_q       <= special_active;
                    sp_res_q   <= special_res;
                    sp_flags_q <= special_flags;
                    cnt        <= NFRAC[6:0];
                    state      <= S_RUN;
                end
                S_RUN: begin
                    nsteps = (cnt > BPC[6:0]) ? BPC[6:0] : cnt;
                    divR_t = {1'b0, R};
                    divQ_t = Q;
                    for (dj = 0; dj < BPC; dj = dj + 1) begin
                        if (dj < nsteps) begin
                            divR_t = divR_t << 1;
                            dq     = (divR_t >= {1'b0, Yq});
                            if (dq) divR_t = divR_t - {1'b0, Yq};
                            divQ_t = {divQ_t[53:0], dq};
                        end
                    end
                    Q   <= divQ_t;
                    R   <= divR_t[52:0];
                    cnt <= cnt - nsteps;
                    if (cnt <= BPC[6:0]) state <= S_FIN;
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
