//  karu_fcvt_d.v
//  IEEE 754 binary64 conversions, combinational:
//    karu_f2i_d   : FCVT.{W,WU,L,LU}.D
//    karu_i2f_d   : FCVT.D.{W,WU,L,LU}
//    karu_fcvt_sd : FCVT.S.D  (D -> S, rounds)
//    karu_fcvt_ds : FCVT.D.S  (S -> D, exact)
//
//  Conventions match karu_fcvt: is_long=1 means 64-bit int, is_unsigned=1
//  means unsigned variant, results are always sign-extended to 64.

`include "karu_fpkg.vh"

//  ==================================================================
//  Double -> Integer  (FCVT.W.D / FCVT.WU.D / FCVT.L.D / FCVT.LU.D)
//  ==================================================================
module karu_f2i_d (
    input  wire [2:0]   rm,
    input  wire         is_long,
    input  wire         is_unsigned,
    input  wire [63:0]  a,
    output wire [63:0]  res,
    output wire [4:0]   flags
);
    wire        a_sign = a[63];
    wire [10:0] a_exp  = a[62:52];
    wire [51:0] a_man  = a[51:0];
    wire        a_zero = (a_exp == 11'h000) && (a_man == 52'h0);
    wire        a_sub  = (a_exp == 11'h000) && (a_man != 52'h0);
    wire        a_inf  = (a_exp == 11'h7FF) && (a_man == 52'h0);
    wire        a_nan  = (a_exp == 11'h7FF) && (a_man != 52'h0);

    wire [63:0] sat_max =
        is_long ? (is_unsigned ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h7FFF_FFFF_FFFF_FFFF)
                : (is_unsigned ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0000_0000_7FFF_FFFF);
    wire [63:0] sat_min =
        is_long ? (is_unsigned ? 64'h0000_0000_0000_0000 : 64'h8000_0000_0000_0000)
                : (is_unsigned ? 64'h0000_0000_0000_0000 : 64'hFFFF_FFFF_8000_0000);

    wire signed [12:0] exp_unb = $signed({2'b0, a_exp}) - 13'sd1023;

    wire [52:0] mant_full = {1'b1, a_man};

    wire signed [12:0] shift_left  = exp_unb - 13'sd52;
    wire signed [12:0] shift_right = 13'sd52 - exp_unb;

    //  128-bit working width: enough headroom for shifts up to ~64 left
    //  (beyond which we always saturate via exp_overflow_l).
    wire        sl_overflow = (shift_left  >= 13'sd76); //  mantissa exits base128
    wire        sr_too_far  = (shift_right >= 13'sd128);
    wire [127:0] base128 = {75'b0, mant_full};
    wire [127:0] shifted_l = base128 << shift_left[6:0];
    wire [127:0] shifted_r = sr_too_far ? 128'b0 : (base128 >> shift_right[6:0]);

    wire is_left = (exp_unb >= 13'sd52);
    wire [127:0] shifted = is_left ? shifted_l : shifted_r;

    //  round_bit / sticky_mask: same shape as karu_fcvt's f2i.
    wire round_bit = is_left ? 1'b0 :
                     ((shift_right > 13'sd0 && shift_right <= 13'sd53)
                       ? base128[shift_right[6:0] - 1] : 1'b0);
    wire [127:0] sticky_mask =
        is_left                   ? 128'b0 :
        (shift_right >= 13'sd54)  ? {128{1'b0}} | { {(128-53){1'b0}}, 53'h1F_FFFF_FFFF_FFFF } :
        (shift_right >= 13'sd2)   ? ((128'b1 << (shift_right[6:0] - 1)) - 128'b1) :
                                    128'b0;
    wire sticky_bit = |(base128 & sticky_mask);

    wire [63:0] mag = shifted[63:0];
    wire        overflow_bits = sl_overflow || |shifted[127:64];

    //  D's exp can exceed 64 well before u64 overflow; flag here too.
    wire        exp_overflow_l = (exp_unb >= 13'sd64);

    wire round_up_mag =
        (rm == `FRM_RNE) ? (round_bit && (sticky_bit || mag[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (a_sign  && (round_bit || sticky_bit)) :
        (rm == `FRM_RUP) ? (!a_sign && (round_bit || sticky_bit)) :
        (rm == `FRM_RMM) ? round_bit :
                           1'b0;

    wire [64:0] mag_rnd  = {1'b0, mag} + {64'b0, round_up_mag};
    wire        mag_carry = mag_rnd[64];

    wire [63:0] signed_result = a_sign ? (~mag_rnd[63:0] + 64'b1) : mag_rnd[63:0];

    wire        is_inexact_in = round_bit || sticky_bit;
    wire        special_high = a_nan || a_inf || overflow_bits || mag_carry || exp_overflow_l;

    wire long_out_of_range_s =
        is_long && !is_unsigned &&
        (special_high ||
         (!a_sign && mag_rnd[63:0] >  64'h7FFF_FFFF_FFFF_FFFF) ||
         ( a_sign && mag_rnd[63:0] >  64'h8000_0000_0000_0000));
    wire long_out_of_range_u =
        is_long && is_unsigned &&
        (special_high || (a_sign && mag_rnd[63:0] != 64'b0));
    wire w_out_of_range_s =
        !is_long && !is_unsigned &&
        (special_high ||
         (!a_sign && mag_rnd[63:0] >  64'h7FFF_FFFF) ||
         ( a_sign && mag_rnd[63:0] >  64'h8000_0000));
    wire w_out_of_range_u =
        !is_long && is_unsigned &&
        (special_high ||
         (!a_sign && mag_rnd[63:0] >  64'hFFFF_FFFF) ||
         ( a_sign && mag_rnd[63:0] != 64'b0));

    wire any_out = long_out_of_range_s || long_out_of_range_u
                 || w_out_of_range_s || w_out_of_range_u;

    wire [63:0] sat_value = a_sign ? sat_min : sat_max;
    wire [63:0] nan_value = is_unsigned ? sat_max
                                        : (is_long ? 64'h7FFF_FFFF_FFFF_FFFF
                                                   : 64'h0000_0000_7FFF_FFFF);

    //  Subnormal flows through the shift path (mag 0, sticky set) -> rounds
    //  to 0 (or +/-1 directed) with NX. Only true zero short-circuits.
    wire        a_is_zero = a_zero;
    wire [63:0] base_result =
        a_is_zero ? 64'b0 :
        a_nan ? nan_value :
        any_out ? sat_value :
        is_long ? signed_result :
                  {{32{signed_result[31]}}, signed_result[31:0]};

    assign res = base_result;
    assign flags =
        a_is_zero ? 5'b0 :
        (a_nan || any_out) ? (5'b1 << `FF_NV)
        : (is_inexact_in   ? (5'b1 << `FF_NX) : 5'b0);
endmodule

//  ==================================================================
//  Integer -> Double  (FCVT.D.{W,WU,L,LU})
//  Doubles can represent ALL int32 exactly. For int64 with > 53
//  significant bits, rounding applies.
//  ==================================================================
module karu_i2f_d (
    input  wire [2:0]   rm,
    input  wire         is_long,
    input  wire         is_unsigned,
    input  wire [63:0]  x,
    output wire [63:0]  res,
    output wire [4:0]   flags
);
    wire [63:0] x_w =
        is_long ? x
                : (is_unsigned ? {32'b0, x[31:0]}
                                : {{32{x[31]}}, x[31:0]});

    wire        is_neg = !is_unsigned && x_w[63];
    wire [63:0] mag    = is_neg ? (~x_w + 64'b1) : x_w;

    wire        is_zero = (mag == 64'b0);

    function [6:0] clz64;
        input [63:0] v;
        integer i;
        reg fnd;
        begin
            clz64 = 7'd64;
            fnd   = 1'b0;
            for (i = 63; i >= 0; i = i - 1) begin
                if (!fnd && v[i]) begin
                    clz64 = 7'd63 - i[6:0];
                    fnd   = 1'b1;
                end
            end
        end
    endfunction
    wire [6:0] lz = clz64(mag);
    wire [6:0] msb_pos = 7'd63 - lz;

    //  Normalize so leading 1 lands at bit 52.
    wire signed [7:0] shift_amt = $signed({1'b0, msb_pos}) - 8'sd52;

    wire [127:0] src128 = {64'b0, mag};
    wire signed [7:0] neg_shift_amt = -shift_amt;
    wire [127:0] norm  = (shift_amt > 0) ? (src128 >> shift_amt[6:0])
                                         : (src128 << neg_shift_amt[6:0]);
    wire [52:0] mant_full   = norm[52:0];
    wire [51:0] mant_field  = mant_full[51:0];

    //  round_bit = mag[shift_amt-1]; sticky = OR of bits below.
    //  shift_amt range here is [-52, 11] for a 64-bit magnitude, so only
    //  the shift_amt > 0 path can lose bits (== msb_pos > 52, i.e. ints
    //  with >= 54 significant bits).
    wire [5:0]  sa = shift_amt[5:0];
    wire [63:0] dropped_mask64 =
        (shift_amt >= 8'sd2) ? ((64'b1 << (sa - 6'd1)) - 64'b1) : 64'b0;
    wire        round_bit  = (shift_amt > 0) ? mag[sa - 6'd1] : 1'b0;
    wire        sticky_bit = (shift_amt > 0) ? |(mag & dropped_mask64) : 1'b0;

    wire round_up =
        (rm == `FRM_RNE) ? (round_bit && (sticky_bit || mant_field[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (is_neg  && (round_bit || sticky_bit)) :
        (rm == `FRM_RUP) ? (!is_neg && (round_bit || sticky_bit)) :
        (rm == `FRM_RMM) ? round_bit :
                           1'b0;

    wire [53:0] mant_rnd   = {1'b0, mant_full} + {53'b0, round_up};
    wire        mant_carry = mant_rnd[53];
    wire [51:0] mant_final = mant_carry ? 52'b0 : mant_rnd[51:0];
    wire [10:0] exp_final;
    assign exp_final = is_zero ? 11'h000
                               : (11'd1023 + {4'b0, msb_pos} + {10'b0, mant_carry});

    wire [63:0] result =
        is_zero ? 64'b0
                : {is_neg, exp_final, mant_final};

    assign res = result;
    assign flags = (round_bit || sticky_bit) ? (5'b1 << `FF_NX) : 5'b0;
endmodule

//  ==================================================================
//  FCVT.S.D  (double -> single, rounds)
//  ==================================================================
module karu_fcvt_sd (
    input  wire [2:0]   rm,
    input  wire [63:0]  a,
    output wire [31:0]  res,
    output wire [4:0]   flags
);
    wire        a_sign = a[63];
    wire [10:0] a_exp  = a[62:52];
    wire [51:0] a_man  = a[51:0];
    wire        a_zero = (a_exp == 11'h000) && (a_man == 52'h0);
    wire        a_sub  = (a_exp == 11'h000) && (a_man != 52'h0);
    wire        a_inf  = (a_exp == 11'h7FF) && (a_man == 52'h0);
    wire        a_nan  = (a_exp == 11'h7FF) && (a_man != 52'h0);
    wire        a_snan = a_nan && !a_man[51];
    //  True zero short-circuits to signed zero. A D subnormal (~2^-1023)
    //  is far below S's range; it flows through to the underflow path
    //  (signed zero / smallest S subnormal) and raises UF+NX.
    wire        a_iz   = a_zero;

    //  Re-bias: D bias 1023, S bias 127. exp_s = a_exp - 1023 + 127 = a_exp - 896.
    wire signed [12:0] exp_unb = $signed({2'b0, a_exp}) - 13'sd1023;
    wire signed [12:0] exp_s_pre = exp_unb + 13'sd127;

    //  S mantissa is the top 23 of D mantissa; bits [28:0] of a_man are
    //  below the round bit. round_bit = a_man[28], sticky = |a_man[27:0].
    wire [22:0] man_s_unround = a_man[51:29];
    wire        round_bit     = a_man[28];
    wire        sticky_bit    = |a_man[27:0];

    wire round_up =
        (rm == `FRM_RNE) ? (round_bit && (sticky_bit || man_s_unround[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (a_sign  && (round_bit || sticky_bit)) :
        (rm == `FRM_RUP) ? (!a_sign && (round_bit || sticky_bit)) :
        (rm == `FRM_RMM) ? round_bit :
                           1'b0;

    wire        is_rod      = (rm == `FRM_ROD);
    wire [24:0] man_rnd     = {1'b0, 1'b1, man_s_unround} + {24'b0, round_up};
    wire        man_carry   = man_rnd[24];
    wire        inexact = round_bit || sticky_bit;
    //  round-to-odd: truncate (round_up==0 already) then force the LSB to 1 when
    //  the discarded bits are nonzero. Never carries, so exp is undisturbed.
    wire [22:0] man_trunc   = man_carry ? 23'b0 : man_rnd[22:0];
    wire [22:0] man_final   = is_rod ? (man_s_unround | {22'b0, inexact}) : man_trunc;
    wire signed [12:0] exp_final = (man_carry && !is_rod) ? (exp_s_pre + 13'sd1) : exp_s_pre;

    wire over    = (exp_final >= 13'sd255);     //  S exp max
    wire under   = (exp_final <= 13'sd0);       //  below S min normal

    //  ---------- Subnormal output path ----------
    //  D values with exp_unb in [-149, -127] produce S subnormals.
    //  S subnormal = 0.<23 bits> * 2^-126. We shift {1, D_mant_52}
    //  right by R = 29 + sub_shift so the leading bits land in the
    //  correct S subnormal positions, with round/sticky derived from
    //  the bits shifted off the bottom.
    wire signed [12:0] sub_shift = 13'sd1 - exp_s_pre;  //  positive when subnormal
    wire is_total_under = (sub_shift >= 13'sd25);       //  below 2^-149
    wire is_subn        = (exp_s_pre <= 13'sd0) && !is_total_under;

    wire [52:0] mfull_53 = {1'b1, a_man[51:0]};
    wire [12:0] R = 13'sd29 + sub_shift;
    wire [127:0] mfull_xx = {75'b0, mfull_53};
    wire [127:0] msh = (R >= 13'sd128) ? 128'b0 : (mfull_xx >> R[6:0]);
    wire [22:0] sub_mant_raw = msh[22:0];

    wire sub_round = (R >= 13'sd1 && R <= 13'sd53)
                        ? mfull_53[R[5:0] - 6'd1] : 1'b0;
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
    wire [23:0] sub_mant_rounded = {1'b0, sub_mant_raw} + {23'b0, sub_round_up};
    //  round-to-odd: truncate then force LSB on inexact (cannot carry to normal).
    wire        sub_mant_carry   = !is_rod && sub_mant_rounded[23]; //  promotes to smallest normal
    wire [22:0] sub_mant_final   = is_rod ? (sub_mant_raw | {22'b0, sub_inexact})
                                          : sub_mant_rounded[22:0];

    wire [31:0] subn_res =
        sub_mant_carry ? {a_sign, 8'h01, 23'h0}
                       : {a_sign, 8'h00, sub_mant_final};
    wire [4:0]  subn_flags =
        sub_inexact ? ((5'b1 << `FF_NX) | (5'b1 << `FF_UF)) : 5'b0;

    //  Total underflow (nonzero D value below 2^-149 in magnitude). Rounds
    //  to signed zero, except directed rounding away from zero (RDN of a
    //  negative, RUP of a positive) rounds to the smallest S subnormal.
    //  round-to-odd of a tiny nonzero value -> smallest S subnormal (odd), both signs.
    wire under_total_away = is_rod || (rm == `FRM_RDN && a_sign) || (rm == `FRM_RUP && !a_sign);
    wire [31:0] under_total_res   = under_total_away ? {a_sign, 8'h00, 23'h1}
                                                     : {a_sign, 31'b0};
    wire [4:0]  under_total_flags = (5'b1 << `FF_NX) | (5'b1 << `FF_UF);

    wire [31:0] under_res   = is_subn ? subn_res   : under_total_res;
    wire [4:0]  under_flags = is_subn ? subn_flags : under_total_flags;

    wire [31:0] normal_res =
        over  ? ((is_rod || (rm == `FRM_RTZ) ||
                  (rm == `FRM_RDN && !a_sign) ||
                  (rm == `FRM_RUP &&  a_sign))
                    ? {a_sign, 8'hFE, 23'h7FFFFF}   //  round-to-odd never -> infinity
                    : {a_sign, 8'hFF, 23'h000000})
        : under ? under_res
        :         {a_sign, exp_final[7:0], man_final};

    wire [4:0] normal_flags =
        (over  ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (under ? under_flags : 5'b0) |
        (!over && !under && inexact ? (5'b1 << `FF_NX) : 5'b0);

    assign res =
        a_iz   ? {a_sign, 31'b0} :
        a_nan  ? `FP_S_QNAN :
        a_inf  ? {a_sign, 8'hFF, 23'h0} :
                 normal_res;

    assign flags =
        a_snan ? (5'b1 << `FF_NV) :
        (a_iz || a_nan || a_inf) ? 5'b0 :
        normal_flags;
endmodule

//  ==================================================================
//  FCVT.D.S  (single -> double, exact). Result is always representable.
//  ==================================================================
module karu_fcvt_ds (
    input  wire [31:0]  a,
    output wire [63:0]  res,
    output wire [4:0]   flags
);
    wire        a_sign = a[31];
    wire [7:0]  a_exp  = a[30:23];
    wire [22:0] a_man  = a[22:0];
    wire        a_zero = (a_exp == 8'h00) && (a_man == 23'h0);
    wire        a_sub  = (a_exp == 8'h00) && (a_man != 23'h0);
    wire        a_inf  = (a_exp == 8'hFF) && (a_man == 23'h0);
    wire        a_nan  = (a_exp == 8'hFF) && (a_man != 23'h0);
    wire        a_snan = a_nan && !a_man[22];
    wire        a_iz   = a_zero;        //  true zero only

    //  A single subnormal converts EXACTLY to a double normal (D's range
    //  easily covers it): normalize the mantissa and adjust the exponent.
    function [4:0] clz23;
        input [22:0] v; integer i; reg fnd;
        begin
            clz23 = 5'd23; fnd = 1'b0;
            for (i = 22; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz23 = 5'd22 - i[4:0]; fnd = 1'b1; end
        end
    endfunction
    wire [4:0]  a_clz   = a_sub ? clz23(a_man) : 5'd0;
    wire [22:0] a_man_n = a_sub ? (a_man << (a_clz + 5'd1)) : a_man;

    //  Re-bias: S to D: exp_d = a_exp - 127 + 1023 = a_exp + 896 (normal).
    //  Normalized subnormal has unbiased exp -127 - a_clz -> biased 896 - a_clz.
    wire [10:0] exp_d   = a_sub ? (11'd896 - {6'b0, a_clz})
                                    : ({3'b0, a_exp} + 11'd896);
    wire [51:0] mant_d  = {a_man_n, 29'b0};

    assign res =
        a_iz   ? {a_sign, 63'b0} :
        a_nan  ? `FP_D_QNAN :
        a_inf  ? {a_sign, 11'h7FF, 52'h0} :
                 {a_sign, exp_d, mant_d};

    assign flags = a_snan ? (5'b1 << `FF_NV) : 5'b0;
endmodule
