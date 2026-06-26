//  karu_fadd_d.v
//  IEEE 754 binary64 add / subtract. Structural mirror of karu_fadd
//  with widths scaled to D: 11-bit exp / 53-bit mantissa / bias 1023.
//  The "28-bit GRS form" in F becomes 57-bit here (1 carry + 1 leading +
//  52 mantissa + 3 G/R/S).
//
//  Split into a 3-stage multi-cycle pipeline (one op in flight; the core is
//  single-issue and gates on busy/done) so no single cycle carries the
//  128-bit align shift + 57-bit add + CLZ-normalize + denormalize + round in
//  series. Registered cut points do not change IEEE result/flag semantics.
//  Stages: S1 unpack+swap+align | S2 add+normalize | S3 denormalize+round+pack.
//
//  Full IEEE subnormal support: subnormal inputs (leading 0, effective biased
//  exp 1), gradual underflow to subnormal outputs, exact NX/UF (tininess after
//  rounding, SoftFloat rule).

`include "karu_fpkg.vh"

module karu_fadd_d (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire         is_sub,
    input  wire [2:0]   rm,
    input  wire [63:0]  a,
    input  wire [63:0]  b,

    output reg          done,
    output reg [63:0]   res,
    output reg  [4:0]   flags,
    output wire [4:0]   latency
);
    assign latency = 5'd4;

    localparam S_IDLE = 2'd0, ST2 = 2'd1, ST3 = 2'd2;
    reg [1:0]   st;
    assign busy = (st != S_IDLE);

    // ================================================================
    // STAGE 1 (issue-cycle inputs): unpack + swap + align
    // ================================================================
    wire        a_s = a[63];
    wire [10:0] a_e = a[62:52];
    wire [51:0] a_m = a[51:0];
    wire        a_zero = (a_e == 11'h000) && (a_m == 52'h0);
    wire        a_inf  = (a_e == 11'h7FF) && (a_m == 52'h0);
    wire        a_nan  = (a_e == 11'h7FF) && (a_m != 52'h0);
    wire        a_snan = a_nan && !a_m[51];
    wire        a_lead = (a_e != 0);
    wire [10:0] a_eff  = a_lead ? a_e : 11'd1;
    wire [52:0] a_mf   = {a_lead, a_m};

    wire        b_s = b[63] ^ is_sub;
    wire [10:0] b_e = b[62:52];
    wire [51:0] b_m = b[51:0];
    wire        b_zero = (b_e == 11'h000) && (b_m == 52'h0);
    wire        b_inf  = (b_e == 11'h7FF) && (b_m == 52'h0);
    wire        b_nan  = (b_e == 11'h7FF) && (b_m != 52'h0);
    wire        b_snan = b_nan && !b_m[51];
    wire        b_lead = (b_e != 0);
    wire [10:0] b_eff  = b_lead ? b_e : 11'd1;
    wire [52:0] b_mf   = {b_lead, b_m};

    wire        a_iz = a_zero;
    wire        b_iz = b_zero;

    wire any_nan      = a_nan || b_nan;
    wire any_snan     = a_snan || b_snan;
    wire inv_inf_inf  = a_inf && b_inf && (a_s != b_s);
    wire both_zero    = a_iz && b_iz;
    wire only_a_zero  = a_iz && !b_iz;
    wire only_b_zero  = b_iz && !a_iz;

    wire zz_sign = (a_s == b_s) ? a_s : (rm == `FRM_RDN);

    wire special_active =
        any_nan || (a_inf || b_inf) || both_zero || only_a_zero || only_b_zero;
    wire [63:0] special_res =
        any_nan          ? `FP_D_QNAN :
        inv_inf_inf      ? `FP_D_QNAN :
        (a_inf && b_inf) ? {a_s, 11'h7FF, 52'h0} :
        a_inf            ? {a_s, 11'h7FF, 52'h0} :
        b_inf            ? {b_s, 11'h7FF, 52'h0} :
        only_a_zero      ? {b_s, b_e, b_m} :
        only_b_zero      ? a :
        both_zero        ? {zz_sign, 63'b0} :
                           64'b0;
    wire [4:0] special_flags =
        (any_snan    ? (5'b1 << `FF_NV) : 5'b0) |
        (inv_inf_inf ? (5'b1 << `FF_NV) : 5'b0);

    wire ae_gt   = (a_eff > b_eff);
    wire ee_eq   = (a_eff == b_eff);
    wire am_ge   = (a_mf >= b_mf);
    wire a_bigger = ae_gt || (ee_eq && am_ge);

    wire [10:0] big_e = a_bigger ? a_eff : b_eff;
    wire [52:0] big_m = a_bigger ? a_mf  : b_mf;
    wire        big_s = a_bigger ? a_s   : b_s;
    wire [10:0] sm_e  = a_bigger ? b_eff : a_eff;
    wire [52:0] sm_m  = a_bigger ? b_mf  : a_mf;
    wire        sm_s  = a_bigger ? b_s   : a_s;

    wire [10:0] exp_diff = big_e - sm_e;

    wire [127:0]    sm_pad     = {sm_m, 75'b0};
    wire [127:0]    sm_shifted = (exp_diff >= 11'd128) ? 128'b0
                                                       : (sm_pad >> exp_diff);
    wire [127:0]    sm_discarded = (exp_diff == 11'd0)   ? 128'b0 :
                                   (exp_diff >= 11'd128) ? sm_pad :
                                   (sm_pad << (11'd128 - exp_diff));
    wire [55:0] sm_full_56 = sm_shifted[127:72];
    wire        sm_S       = (|sm_shifted[71:0]) | (|sm_discarded);
    wire [55:0] big_full_56 = {big_m, 3'b000};
    wire        eff_sub = (big_s != sm_s);

    //  stage-1 registers
    reg [55:0]          s1_big_full_56, s1_sm_full_56;
    reg                 s1_sm_S, s1_eff_sub, s1_big_s, s1_zz_sign;
    reg [10:0]          s1_big_e;
    reg                 s1_special_active;
    reg [63:0]          s1_special_res;
    reg [4:0]           s1_special_flags;
    reg [2:0]           s1_rm;

    // ================================================================
    // STAGE 2 (from s1): add/sub + normalize (CLZ)
    // ================================================================
    wire [56:0] sum_57 = s1_eff_sub
        ? ({1'b0, s1_big_full_56} - {1'b0, s1_sm_full_56} - {56'b0, s1_sm_S})
        : ({1'b0, s1_big_full_56} + {1'b0, s1_sm_full_56});
    wire all_zero = (sum_57 == 57'b0);

    function [5:0] clz57;
        input [56:0] v; integer i; reg fnd;
        begin clz57 = 6'd57; fnd = 1'b0;
            for (i = 56; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz57 = 6'd56 - i[5:0]; fnd = 1'b1; end
        end
    endfunction
    wire [5:0]  lz = clz57(sum_57);
    wire [56:0] norm = sum_57 << lz;
    wire signed [12:0] exp_n = $signed({2'b0, s1_big_e}) + 13'sd1 - $signed({7'b0, lz});

    //  stage-2 registers
    reg [56:0]          s2_norm;
    reg signed [12:0]   s2_exp_n;
    reg                 s2_sm_S, s2_big_s, s2_all_zero, s2_zz_sign;
    reg                 s2_special_active;
    reg [63:0]          s2_special_res;
    reg [4:0]           s2_special_flags;
    reg [2:0]           s2_rm;

    // ================================================================
    // STAGE 3 (from s2): denormalize + round + pack
    // ================================================================
    wire signed [12:0] dshift_s = (s2_exp_n <= 0) ? (13'sd1 - s2_exp_n) : 13'sd0;
    wire [12:0] dshift  = dshift_s[12:0];
    wire [56:0] dn      = (dshift >= 13'd57) ? 57'b0 : (s2_norm >> dshift);
    wire        dn_lost = (dshift == 0) ? 1'b0 :
                          (dshift >= 13'd57) ? (|s2_norm) :
                          (|(s2_norm & (~({57{1'b1}} << dshift))));

    wire [52:0] sig53  = dn[56:4];
    wire        g_bit  = dn[3];
    wire        r_bit  = dn[2];
    wire        s_bit  = (|dn[1:0]) | s2_sm_S | dn_lost;

    wire        subnormal_region = (s2_exp_n <= 0);
    wire        res_sign = s2_all_zero ? s2_zz_sign : s2_big_s;

    wire round_bit = g_bit;
    wire sticky    = r_bit | s_bit;
    wire round_up =
        (s2_rm == `FRM_RNE) ? (round_bit && (sticky || sig53[0])) :
        (s2_rm == `FRM_RTZ) ? 1'b0 :
        (s2_rm == `FRM_RDN) ? (res_sign  && (round_bit || sticky)) :
        (s2_rm == `FRM_RUP) ? (!res_sign && (round_bit || sticky)) :
        (s2_rm == `FRM_RMM) ? round_bit :
                           1'b0;

    wire [53:0] mant_rnd  = {1'b0, sig53} + {53'b0, round_up};
    wire        rnd_carry = mant_rnd[53];
    wire        promote   = mant_rnd[52];
    wire        inexact   = round_bit | sticky;

    wire signed [12:0] exp_norm_final = s2_exp_n + (rnd_carry ? 13'sd1 : 13'sd0);
    wire over = !subnormal_region && (exp_norm_final >= 13'sd2047);

    wire [52:0] nsig53 = s2_norm[56:4];
    wire        ng = s2_norm[3];
    wire        nr = s2_norm[2];
    wire        ns = (|s2_norm[1:0]) | s2_sm_S;
    wire nr_up =
        (s2_rm == `FRM_RNE) ? (ng && (nr || ns || nsig53[0])) :
        (s2_rm == `FRM_RTZ) ? 1'b0 :
        (s2_rm == `FRM_RDN) ? (res_sign  && (ng || nr || ns)) :
        (s2_rm == `FRM_RUP) ? (!res_sign && (ng || nr || ns)) :
        (s2_rm == `FRM_RMM) ? ng :
                           1'b0;
    wire reaches_normal = (({1'b0, nsig53} + {53'b0, nr_up}) >= 54'h20_0000_0000_0000);
    wire tiny_before = subnormal_region
                    && ((s2_exp_n <= -13'sd1) || !reaches_normal);

    wire [63:0] over_res =
        ((s2_rm == `FRM_RTZ) ||
         (s2_rm == `FRM_RDN && !res_sign) ||
         (s2_rm == `FRM_RUP &&  res_sign))
            ? {res_sign, 11'h7FE, 52'hF_FFFF_FFFF_FFFF}
            : {res_sign, 11'h7FF, 52'h0};

    wire [63:0] normal_res =
        s2_all_zero ? {s2_zz_sign, 63'b0} :
        over     ? over_res :
        subnormal_region ? {res_sign, (promote ? 11'd1 : 11'd0), mant_rnd[51:0]} :
                           {res_sign, exp_norm_final[10:0], (rnd_carry ? 52'b0 : mant_rnd[51:0])};

    wire [4:0] normal_flags =
        s2_all_zero ? 5'b0 :
        (over                   ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (tiny_before && inexact ? (5'b1 << `FF_UF)                      : 5'b0) |
        (inexact && !over       ? (5'b1 << `FF_NX)                      : 5'b0);

    wire [63:0] res_w   = s2_special_active ? s2_special_res : normal_res;
    wire [4:0]  flags_w = s2_special_active ? s2_special_flags : normal_flags;

    always @(posedge clk) begin
        if (rst) begin
            st   <= S_IDLE;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (req) begin
                    s1_big_full_56 <= big_full_56;
                    s1_sm_full_56  <= sm_full_56;
                    s1_sm_S        <= sm_S;
                    s1_eff_sub     <= eff_sub;
                    s1_big_s       <= big_s;
                    s1_zz_sign     <= zz_sign;
                    s1_big_e       <= big_e;
                    s1_special_active <= special_active;
                    s1_special_res    <= special_res;
                    s1_special_flags  <= special_flags;
                    s1_rm          <= rm;
                    st <= ST2;
                end
                ST2: begin
                    s2_norm      <= norm;
                    s2_exp_n     <= exp_n;
                    s2_sm_S      <= s1_sm_S;
                    s2_big_s     <= s1_big_s;
                    s2_all_zero  <= all_zero;
                    s2_zz_sign   <= s1_zz_sign;
                    s2_special_active <= s1_special_active;
                    s2_special_res    <= s1_special_res;
                    s2_special_flags  <= s1_special_flags;
                    s2_rm        <= s1_rm;
                    st <= ST3;
                end
                ST3: begin
                    res   <= res_w;
                    flags <= flags_w;
                    done  <= 1'b1;
                    st    <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    wire _unused = &{1'b0};
endmodule
