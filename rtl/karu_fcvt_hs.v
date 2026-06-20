//  karu_fcvt_hs.v
//  IEEE-754 binary16 conversion datapaths, serving BOTH the Zvfhmin vector
//  subset and the scalar Zfhmin FP16-minimal set (all RVA23-mandatory):
//    karu_fcvt_hs : H -> S, EXACT   (vfwcvt.f.f.v @SEW16 / fcvt.s.h; and
//                                    stage 1 of fcvt.d.h via hs->ds compose)
//    karu_fcvt_sh : S -> H, rounds  (vfncvt.f.f.w @SEW16 / fcvt.h.s)
//    karu_fcvt_dh : D -> H, rounds  (scalar fcvt.h.d; direct single rounding,
//                                    avoids the D->S->H double-rounding)
//  FP16 = 1 sign / 5 exp (bias 15) / 10 mantissa.  FP32 = 1 / 8 (bias 127) / 23.
//  FP64 = 1 / 11 (bias 1023) / 52.  Combinational; structure mirrors
//  karu_fcvt_ds / karu_fcvt_sd (S<->D) so the subnormal + rounding paths follow
//  the same TestFloat-validated shape with the widths retargeted. Full Zvfh /
//  Zfh (FP16 *arithmetic*) is NOT implemented; only these conversions are.
//  Math validated bit-exact vs SoftFloat-3e (make fcvt-hs-test).

`include "karu_fpkg.vh"

//  ==================================================================
//  FP16 -> FP32 (widen, EXACT). Every binary16 is representable in
//  binary32 -- including subnormals, which become binary32 normals.
//  ==================================================================
module karu_fcvt_hs (
    input  wire [15:0]  a,
    output wire [31:0]  res,
    output wire [4:0]   flags
);
    wire        a_sign = a[15];
    wire [4:0]  a_exp  = a[14:10];
    wire [9:0]  a_man  = a[9:0];
    wire        a_zero = (a_exp == 5'h00) && (a_man == 10'h0);
    wire        a_sub  = (a_exp == 5'h00) && (a_man != 10'h0);
    wire        a_inf  = (a_exp == 5'h1F) && (a_man == 10'h0);
    wire        a_nan  = (a_exp == 5'h1F) && (a_man != 10'h0);
    wire        a_snan = a_nan && !a_man[9];
    wire        a_iz   = a_zero;

    //  An FP16 subnormal converts EXACTLY to an FP32 normal: normalize the
    //  mantissa (drop the leading 1) and adjust the exponent.
    function [3:0] clz10;
        input [9:0] v; integer i; reg fnd;
        begin
            clz10 = 4'd10; fnd = 1'b0;
            for (i = 9; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz10 = 4'd9 - i[3:0]; fnd = 1'b1; end
        end
    endfunction
    wire [3:0]  a_clz   = a_sub ? clz10(a_man) : 4'd0;
    wire [9:0]  a_man_n = a_sub ? (a_man << (a_clz + 4'd1)) : a_man;

    //  Re-bias H->S: exp_s = a_exp - 15 + 127 = a_exp + 112 (normal).
    //  Normalized subnormal has biased S exp 112 - a_clz.
    wire [7:0]  exp_s  = a_sub ? (8'd112 - {4'b0, a_clz})
                                  : ({3'b0, a_exp} + 8'd112);
    wire [22:0] mant_s = {a_man_n, 13'b0};

    assign res =
        a_iz   ? {a_sign, 31'b0} :
        a_nan  ? `FP_S_QNAN :
        a_inf  ? {a_sign, 8'hFF, 23'h0} :
                 {a_sign, exp_s, mant_s};

    //  exact apart from the sNaN -> qNaN quieting (raises NV).
    assign flags = a_snan ? (5'b1 << `FF_NV) : 5'b0;
endmodule

//  ==================================================================
//  FP32 -> FP16 (narrow, rounds per frm). Overflow -> inf (or max,
//  round-dependent); gradual underflow -> FP16 subnormal/zero; NV on
//  sNaN; OF/UF/NX as IEEE. Mirrors karu_fcvt_sd (D->S).
//  ==================================================================
module karu_fcvt_sh (
    input  wire [2:0]   rm,
    input  wire [31:0]  a,
    output wire [15:0]  res,
    output wire [4:0]   flags
);
    wire        a_sign = a[31];
    wire [7:0]  a_exp  = a[30:23];
    wire [22:0] a_man  = a[22:0];
    wire        a_zero = (a_exp == 8'h00) && (a_man == 23'h0);
    wire        a_inf  = (a_exp == 8'hFF) && (a_man == 23'h0);
    wire        a_nan  = (a_exp == 8'hFF) && (a_man != 23'h0);
    wire        a_snan = a_nan && !a_man[22];
    wire        a_iz   = a_zero;        //  true zero short-circuits to signed zero

    //  Re-bias S->H: exp_h = a_exp - 127 + 15 = a_exp - 112.
    wire signed [10:0] exp_unb   = $signed({3'b0, a_exp}) - 11'sd127;
    wire signed [10:0] exp_h_pre = exp_unb + 11'sd15;

    //  H mantissa = top 10 of S mantissa; bits [12:0] are below it.
    wire [9:0]  man_h_unround = a_man[22:13];
    wire        round_bit     = a_man[12];
    wire        sticky_bit    = |a_man[11:0];

    wire round_up =
        (rm == `FRM_RNE) ? (round_bit && (sticky_bit || man_h_unround[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (a_sign  && (round_bit || sticky_bit)) :
        (rm == `FRM_RUP) ? (!a_sign && (round_bit || sticky_bit)) :
        (rm == `FRM_RMM) ? round_bit :
                           1'b0;
    wire        is_rod    = (rm == `FRM_ROD);
    wire [11:0] man_rnd   = {1'b0, 1'b1, man_h_unround} + {11'b0, round_up};
    wire        man_carry = man_rnd[11];
    wire        inexact   = round_bit || sticky_bit;
    wire [9:0]  man_trunc = man_carry ? 10'b0 : man_rnd[9:0];
    wire [9:0]  man_final = is_rod ? (man_h_unround | {9'b0, inexact}) : man_trunc;
    wire signed [10:0] exp_final = (man_carry && !is_rod) ? (exp_h_pre + 11'sd1) : exp_h_pre;

    wire over  = (exp_final >= 11'sd31);    //  H exp 0x1F == inf
    wire under = (exp_final <= 11'sd0);     //  below H min normal

    //  ---------- Subnormal output path ----------
    //  S values with exp_h_pre in (-9, 0] produce H subnormals; shift the
    //  S significand {1, 23-man} right so the leading bits land in the H
    //  subnormal field, deriving round/sticky from the discarded bits.
    wire signed [10:0] sub_shift = 11'sd1 - exp_h_pre;
    wire is_total_under = (sub_shift >= 11'sd12);   //  below 2^-25 (mant_bits+2)
    wire is_subn        = (exp_h_pre <= 11'sd0) && !is_total_under;

    wire [23:0] mfull_24 = {1'b1, a_man[22:0]};
    wire [10:0] R = 11'sd13 + sub_shift;            //  13 = 23 - 10 (mant offset)
    wire [63:0] mfull_xx = {40'b0, mfull_24};
    wire [63:0] msh = (R >= 11'sd64) ? 64'b0 : (mfull_xx >> R[5:0]);
    wire [9:0]  sub_mant_raw = msh[9:0];

    wire sub_round = (R >= 11'sd1 && R <= 11'sd24) ? mfull_24[R[4:0] - 5'd1] : 1'b0;
    wire [23:0] sub_sticky_mask =
        (R >= 11'sd25) ? 24'hFF_FFFF :
        (R >= 11'sd2)  ? ((24'b1 << (R[4:0] - 5'd1)) - 24'b1) :
        24'b0;
    wire sub_sticky = |(mfull_24 & sub_sticky_mask);

    wire sub_round_up =
        (rm == `FRM_RNE) ? (sub_round && (sub_sticky || sub_mant_raw[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (a_sign  && (sub_round || sub_sticky)) :
        (rm == `FRM_RUP) ? (!a_sign && (sub_round || sub_sticky)) :
        (rm == `FRM_RMM) ? sub_round :
                           1'b0;
    wire        sub_inexact      = sub_round || sub_sticky;
    wire [10:0] sub_mant_rounded = {1'b0, sub_mant_raw} + {10'b0, sub_round_up};
    wire        sub_mant_carry   = !is_rod && sub_mant_rounded[10]; //  -> smallest normal
    wire [9:0]  sub_mant_final   = is_rod ? (sub_mant_raw | {9'b0, sub_inexact})
                                          : sub_mant_rounded[9:0];

    wire [15:0] subn_res =
        sub_mant_carry ? {a_sign, 5'h01, 10'h0}
                       : {a_sign, 5'h00, sub_mant_final};
    wire [4:0]  subn_flags =
        sub_inexact ? ((5'b1 << `FF_NX) | (5'b1 << `FF_UF)) : 5'b0;

    //  Total underflow (nonzero, below 2^-25). Rounds to signed zero, except
    //  directed-away / round-to-odd -> smallest H subnormal.
    wire under_total_away = is_rod || (rm == `FRM_RDN && a_sign) || (rm == `FRM_RUP && !a_sign);
    wire [15:0] under_total_res   = under_total_away ? {a_sign, 5'h00, 10'h1}
                                                     : {a_sign, 15'b0};
    wire [4:0]  under_total_flags = (5'b1 << `FF_NX) | (5'b1 << `FF_UF);

    wire [15:0] under_res   = is_subn ? subn_res   : under_total_res;
    wire [4:0]  under_flags = is_subn ? subn_flags : under_total_flags;

    wire [15:0] normal_res =
        over  ? ((is_rod || (rm == `FRM_RTZ) ||
                  (rm == `FRM_RDN && !a_sign) ||
                  (rm == `FRM_RUP &&  a_sign))
                    ? {a_sign, 5'h1E, 10'h3FF}      //  max finite (never -> inf)
                    : {a_sign, 5'h1F, 10'h000})     //  inf
        : under ? under_res
        :         {a_sign, exp_final[4:0], man_final};

    wire [4:0] normal_flags =
        (over  ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (under ? under_flags : 5'b0) |
        (!over && !under && inexact ? (5'b1 << `FF_NX) : 5'b0);

    assign res =
        a_iz   ? {a_sign, 15'b0} :
        a_nan  ? `FP_H_QNAN :
        a_inf  ? {a_sign, 5'h1F, 10'h0} :
                 normal_res;

    assign flags =
        a_snan ? (5'b1 << `FF_NV) :
        (a_iz || a_nan || a_inf) ? 5'b0 :
        normal_flags;
endmodule

//  ==================================================================
//  FP64 -> FP16 (narrow, rounds per frm). For Zfhmin fcvt.h.d. Direct
//  single rounding (avoids the double-rounding of D->S->H). Mirrors
//  karu_fcvt_sd (D->S) with an FP16 destination.
//  ==================================================================
module karu_fcvt_dh (
    input  wire [2:0]   rm,
    input  wire [63:0]  a,
    output wire [15:0]  res,
    output wire [4:0]   flags
);
    wire        a_sign = a[63];
    wire [10:0] a_exp  = a[62:52];
    wire [51:0] a_man  = a[51:0];
    wire        a_zero = (a_exp == 11'h000) && (a_man == 52'h0);
    wire        a_inf  = (a_exp == 11'h7FF) && (a_man == 52'h0);
    wire        a_nan  = (a_exp == 11'h7FF) && (a_man != 52'h0);
    wire        a_snan = a_nan && !a_man[51];
    wire        a_iz   = a_zero;

    //  Re-bias D->H: exp_h = a_exp - 1023 + 15 = a_exp - 1008.
    wire signed [12:0] exp_unb   = $signed({2'b0, a_exp}) - 13'sd1023;
    wire signed [12:0] exp_h_pre = exp_unb + 13'sd15;

    //  H mantissa = top 10 of the 52-bit D mantissa; [41:0] are below it.
    wire [9:0]  man_h_unround = a_man[51:42];
    wire        round_bit     = a_man[41];
    wire        sticky_bit    = |a_man[40:0];

    wire round_up =
        (rm == `FRM_RNE) ? (round_bit && (sticky_bit || man_h_unround[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (a_sign  && (round_bit || sticky_bit)) :
        (rm == `FRM_RUP) ? (!a_sign && (round_bit || sticky_bit)) :
        (rm == `FRM_RMM) ? round_bit :
                           1'b0;
    wire        is_rod    = (rm == `FRM_ROD);
    wire [11:0] man_rnd   = {1'b0, 1'b1, man_h_unround} + {11'b0, round_up};
    wire        man_carry = man_rnd[11];
    wire        inexact   = round_bit || sticky_bit;
    wire [9:0]  man_trunc = man_carry ? 10'b0 : man_rnd[9:0];
    wire [9:0]  man_final = is_rod ? (man_h_unround | {9'b0, inexact}) : man_trunc;
    wire signed [12:0] exp_final = (man_carry && !is_rod) ? (exp_h_pre + 13'sd1) : exp_h_pre;

    wire over  = (exp_final >= 13'sd31);
    wire under = (exp_final <= 13'sd0);

    //  ---------- subnormal output ----------
    wire signed [12:0] sub_shift = 13'sd1 - exp_h_pre;
    wire is_total_under = (sub_shift >= 13'sd12);   //  mant_bits + 2
    wire is_subn        = (exp_h_pre <= 13'sd0) && !is_total_under;

    wire [52:0] mfull_53 = {1'b1, a_man[51:0]};
    wire [12:0] R = 13'sd42 + sub_shift;            //  42 = 52 - 10 (mant offset)
    wire [127:0] mfull_xx = {75'b0, mfull_53};
    wire [127:0] msh = (R >= 13'sd128) ? 128'b0 : (mfull_xx >> R[6:0]);
    wire [9:0]  sub_mant_raw = msh[9:0];

    wire sub_round = (R >= 13'sd1 && R <= 13'sd53) ? mfull_53[R[5:0] - 6'd1] : 1'b0;
    wire [52:0] sub_sticky_mask =
        (R >= 13'sd54) ? 53'h1F_FFFF_FFFF_FFFF :
        (R >= 13'sd2)  ? ((53'b1 << (R[5:0] - 6'd1)) - 53'b1) :
        53'b0;
    wire sub_sticky = |(mfull_53 & sub_sticky_mask);

    wire sub_round_up =
        (rm == `FRM_RNE) ? (sub_round && (sub_sticky || sub_mant_raw[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (a_sign  && (sub_round || sub_sticky)) :
        (rm == `FRM_RUP) ? (!a_sign && (sub_round || sub_sticky)) :
        (rm == `FRM_RMM) ? sub_round :
                           1'b0;
    wire        sub_inexact      = sub_round || sub_sticky;
    wire [10:0] sub_mant_rounded = {1'b0, sub_mant_raw} + {10'b0, sub_round_up};
    wire        sub_mant_carry   = !is_rod && sub_mant_rounded[10];
    wire [9:0]  sub_mant_final   = is_rod ? (sub_mant_raw | {9'b0, sub_inexact})
                                          : sub_mant_rounded[9:0];

    wire [15:0] subn_res =
        sub_mant_carry ? {a_sign, 5'h01, 10'h0}
                       : {a_sign, 5'h00, sub_mant_final};
    wire [4:0]  subn_flags =
        sub_inexact ? ((5'b1 << `FF_NX) | (5'b1 << `FF_UF)) : 5'b0;

    wire under_total_away = is_rod || (rm == `FRM_RDN && a_sign) || (rm == `FRM_RUP && !a_sign);
    wire [15:0] under_total_res   = under_total_away ? {a_sign, 5'h00, 10'h1}
                                                     : {a_sign, 15'b0};
    wire [4:0]  under_total_flags = (5'b1 << `FF_NX) | (5'b1 << `FF_UF);

    wire [15:0] under_res   = is_subn ? subn_res   : under_total_res;
    wire [4:0]  under_flags = is_subn ? subn_flags : under_total_flags;

    wire [15:0] normal_res =
        over  ? ((is_rod || (rm == `FRM_RTZ) ||
                  (rm == `FRM_RDN && !a_sign) ||
                  (rm == `FRM_RUP &&  a_sign))
                    ? {a_sign, 5'h1E, 10'h3FF}
                    : {a_sign, 5'h1F, 10'h000})
        : under ? under_res
        :         {a_sign, exp_final[4:0], man_final};

    wire [4:0] normal_flags =
        (over  ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (under ? under_flags : 5'b0) |
        (!over && !under && inexact ? (5'b1 << `FF_NX) : 5'b0);

    assign res =
        a_iz   ? {a_sign, 15'b0} :
        a_nan  ? `FP_H_QNAN :
        a_inf  ? {a_sign, 5'h1F, 10'h0} :
                 normal_res;
    assign flags =
        a_snan ? (5'b1 << `FF_NV) :
        (a_iz || a_nan || a_inf) ? 5'b0 :
        normal_flags;
endmodule
