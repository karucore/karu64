//  karu_fcvt.v
//  IEEE 754 single-precision <-> integer conversions, combinational.
//  Two top-level modules:
//    karu_f2i  : FCVT.{W,WU,L,LU}.S  (float -> int 32 or 64, signed/unsigned)
//    karu_i2f  : FCVT.S.{W,WU,L,LU}  (int 32 or 64 signed/unsigned -> float)
//
//  `is_long`  : 1 = 64-bit int, 0 = 32-bit int (sign-extended to 64 on output)
//  `is_unsigned`: 1 = unsigned int variant, 0 = signed

`include "karu_fpkg.vh"

//  ==================================================================
//  Float -> Integer
//  ==================================================================
module karu_f2i (
    input  wire [2:0]   rm,
    input  wire         is_long,
    input  wire         is_unsigned,
    input  wire [31:0]  a,
    output wire [63:0]  res,
    output wire [4:0]   flags
);
    wire        a_sign = a[31];
    wire [7:0]  a_exp  = a[30:23];
    wire [22:0] a_man  = a[22:0];
    wire        a_zero = (a_exp == 0) && (a_man == 0);
    wire        a_sub  = (a_exp == 0) && (a_man != 0);
    wire        a_inf  = (a_exp == 8'hFF) && (a_man == 0);
    wire        a_nan  = (a_exp == 8'hFF) && (a_man != 0);

    //  Saturation limits:
    //    signed 32: max = 0x7fffffff,    min = 0x80000000 (-2^31)
    //    unsigned 32: max = 0xffffffff,  min = 0
    //    signed 64: max = 0x7fff...,     min = 0x8000...
    //    unsigned 64: max = 0xffff...,   min = 0
    //  W-variant constants are pre-sign-extended to 64 bits (matches spec).
    wire [63:0] sat_max =
        is_long ? (is_unsigned ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h7FFF_FFFF_FFFF_FFFF)
                : (is_unsigned ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0000_0000_7FFF_FFFF);
    wire [63:0] sat_min =
        is_long ? (is_unsigned ? 64'h0000_0000_0000_0000 : 64'h8000_0000_0000_0000)
                : (is_unsigned ? 64'h0000_0000_0000_0000 : 64'hFFFF_FFFF_8000_0000);

    //  Unbiased exponent
    wire signed [9:0] exp_unb = {2'b0, a_exp} - 10'sd127;

    //  Mantissa with implicit 1, padded high
    wire [23:0] mant_full = {1'b1, a_man};

    //  Shift: result = mant_full << (exp_unb - 23) [if exp_unb >= 23]
    //       = mant_full >> (23 - exp_unb) [if exp_unb < 23]
    //  Use a 96-bit wide intermediate to capture any shifted bits for rounding.
    //  Position the 24-bit mantissa at bit positions [88:65] (top), so a
    //  left shift up to ~70 still fits and a right shift sets the round bit.
    wire signed [9:0] shift_left  = exp_unb - 10'sd23;  //  positive: shift left
    wire signed [9:0] shift_right = 10'sd23 - exp_unb;  //  positive: shift right

    //  Worst case left shift for unsigned 64-bit: result up to 2^64,
    //  exp up to 64, so shift_left up to 41. Use 96-bit working width.
    //
    //  NOTE: shift_left / shift_right can exceed 63 for tiny / huge
    //  operands (shift_right up to 149 for the smallest normal; shift_left
    //  up to 104 for the largest). We must NOT just truncate to [5:0] --
    //  doing so wraps the shift count and produces a garbage low-bit
    //  result instead of saturating to 0 / detecting overflow. Use 7-bit
    //  shift fields and add explicit "too far" gates.
    wire [95:0] base96 = {72'b0, mant_full};
    wire        sl_overflow = (shift_left  >= 10'sd73); //  mantissa exits base96
    wire        sr_too_far  = (shift_right >= 10'sd96); //  result mag is 0
    wire [95:0] shifted_l = base96 << shift_left[6:0];
    wire [95:0] shifted_r = sr_too_far ? 96'b0 : (base96 >> shift_right[6:0]);

    wire is_left = (exp_unb >= 10'sd23);
    wire [95:0] shifted = is_left ? shifted_l : shifted_r;

    //  Rounding bits when shifting right: bit just below LSB = round,
    //  OR of bits further below = sticky.
    //  When is_left: no bits dropped, round=0 sticky=0.
    wire round_bit = is_left ? 1'b0 : ((shift_right >  10'sd0 && shift_right <= 10'sd24)
                                       ? base96[shift_right[5:0] - 1] : 1'b0);
    wire sticky_bit;
    //  Sticky: OR of bits 0..shift_right-2 of base96 (the bits below round bit).
    //  For shift_right >= 25, round_bit is above the mantissa MSB, so the
    //  entire 24-bit mantissa is "below the round bit" and sticky_mask
    //  collapses to a full mantissa mask.
    wire [95:0] sticky_mask =
        (shift_right >= 10'sd25) ? 96'h0000_0000_0000_0000_00FF_FFFF :
        (shift_right >= 10'sd2)  ? ((96'b1 << (shift_right[5:0] - 1)) - 96'b1) :
        96'b0;
    assign sticky_bit = is_left ? 1'b0 : (|(base96 & sticky_mask));

    //  The integer magnitude (before sign), before rounding
    wire [63:0] mag = shifted[63:0];
    //  Bits that would overflow 64-bit (incl. left-shifts that exited base96)
    wire        overflow_bits = sl_overflow || |shifted[95:64];

    //  Apply rounding per rm
    wire round_up_mag =
        (rm == `FRM_RNE) ? (round_bit && (sticky_bit || mag[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (a_sign  && (round_bit || sticky_bit)) :
        (rm == `FRM_RUP) ? (!a_sign && (round_bit || sticky_bit)) :
        (rm == `FRM_RMM) ? round_bit :
                           1'b0;

    wire [64:0] mag_rnd = {1'b0, mag} + {64'b0, round_up_mag};
    wire        mag_carry = mag_rnd[64];

    //  Apply sign
    wire [63:0] signed_result = a_sign ? (~mag_rnd[63:0] + 64'b1) : mag_rnd[63:0];

    //  Range check
    //  Out of range conditions (for signed):
    //    - mag exceeds max representable magnitude
    //    - exponent too large
    //    - or NaN/inf
    //  For unsigned negative: out of range
    wire        is_inexact_in = round_bit || sticky_bit;
    wire        special_high = a_nan || a_inf || overflow_bits || mag_carry;

    //  "out of range" final check after applying sign
    //  For signed 32: signed_result must fit in [-2^31, 2^31-1]
    //  For signed 64: signed_result must be representable (mag must be <= 2^63
    //                 with sign or == 2^63 with negative sign)
    wire signed_neg_max_ok = a_sign && (mag_rnd[63:0] == 64'h8000_0000_0000_0000) && is_long;
    wire signed_neg_max_ok_w = a_sign && (mag_rnd[63:0] == 64'h0000_0000_8000_0000) && !is_long;

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
    //  NaN saturates to max per spec
    wire [63:0] nan_value = is_unsigned ? sat_max
                                        : (is_long ? 64'h7FFF_FFFF_FFFF_FFFF
                                                   : 64'h0000_0000_7FFF_FFFF);

    //  Only true zero short-circuits. A subnormal is a tiny nonzero value:
    //  it flows through the shift path (magnitude 0, sticky set) so it
    //  rounds to 0 (or +/-1 under directed rounding) and raises NX.
    wire        a_is_zero = a_zero;
    wire [63:0] base_result =
        a_is_zero ? 64'b0 :
        a_nan ? nan_value :
        any_out ? sat_value :
        is_long ? signed_result :
                  {{32{signed_result[31]}}, signed_result[31:0]};   //  W result always sign-extended

    assign res = base_result;
    assign flags =
        a_is_zero ? 5'b0 :
        (a_nan || any_out) ? (5'b1 << `FF_NV)
        : (is_inexact_in   ? (5'b1 << `FF_NX) : 5'b0);
endmodule

//  ==================================================================
//  Integer -> Float
//  ==================================================================
module karu_i2f (
    input  wire [2:0]   rm,
    input  wire         is_long,
    input  wire         is_unsigned,
    input  wire [63:0]  x,
    output wire [31:0]  res,
    output wire [4:0]   flags
);
    //  Extract operand at the right width
    wire [63:0] x_w =
        is_long ? x
                : (is_unsigned ? {32'b0, x[31:0]}
                                : {{32{x[31]}}, x[31:0]});

    //  Sign and magnitude
    wire        is_neg = !is_unsigned && x_w[63];
    wire [63:0] mag    = is_neg ? (~x_w + 64'b1) : x_w;

    wire        is_zero = (mag == 64'b0);

    //  Count leading zeros (find MSB position)
    function [6:0] clz64;
        input [63:0] v;
        integer i;
        reg done;
        begin
            clz64 = 7'd64;
            done  = 1'b0;
            for (i = 63; i >= 0; i = i - 1) begin
                if (!done && v[i]) begin
                    clz64 = 7'd63 - i[6:0];
                    done  = 1'b1;
                end
            end
        end
    endfunction
    wire [6:0] lz = clz64(mag);
    wire [6:0] msb_pos = 7'd63 - lz;        //  position of leading 1

    //  Normalize: shift mag so the leading 1 is at bit 23, with extra
    //  bits below for round/sticky.
    //    shift_amt = msb_pos - 23 (right shift if positive, left if negative)
    wire signed [7:0] shift_amt = $signed({1'b0, msb_pos}) - 8'sd23;

    //  Use 96-bit work area centered around bit 23 (low) to bit 86 (high).
    //  Source: mag in low 64 bits.
    wire [95:0] src96 = {32'b0, mag};
    wire signed [7:0] neg_shift_amt = -shift_amt;
    wire [95:0] norm  = (shift_amt > 0) ? (src96 >> shift_amt[6:0])
                                        : (src96 << neg_shift_amt[6:0]);
    //  After normalize: bit 23 has leading 1 (if magnitude was nonzero).
    //  Bits [22:0] are the mantissa.
    wire [23:0] mant_full   = norm[23:0];   //  includes the implicit leading 1
    wire [22:0] mant_field  = mant_full[22:0];

    //  Rounding bits: when shifting right (msb_pos > 23), we lost
    //  `shift_amt` low bits of mag. round_bit = mag[shift_amt-1];
    //  sticky_bit = OR of bits [shift_amt-2 : 0].
    //
    //  The earlier version of this block clamped both at shift_amt=24
    //  (so round_bit was always mag[23] and sticky_mask was always
    //  bits[22:0]) for the "shift_amt >= 24" case, missing NX for
    //  int->float conversions where the leading 1 sits above bit 23
    //  but the discarded bits aren't all zero. shift_amt's actual
    //  range here is [0, 40] (msb_pos <= 63), so 6 bits is enough.
    wire [5:0]  sa = shift_amt[5:0];
    wire [63:0] dropped_mask64 =
        (shift_amt >= 8'sd2) ? ((64'b1 << (sa - 6'd1)) - 64'b1) : 64'b0;
    wire        round_bit  = (shift_amt > 0) ? mag[sa - 6'd1] : 1'b0;
    wire        sticky_bit = (shift_amt > 0) ? |(mag & dropped_mask64) : 1'b0;

    //  Round
    wire round_up =
        (rm == `FRM_RNE) ? (round_bit && (sticky_bit || mant_field[0])) :
        (rm == `FRM_RTZ) ? 1'b0 :
        (rm == `FRM_RDN) ? (is_neg  && (round_bit || sticky_bit)) :
        (rm == `FRM_RUP) ? (!is_neg && (round_bit || sticky_bit)) :
        (rm == `FRM_RMM) ? round_bit :
                           1'b0;

    wire [24:0] mant_rnd   = {1'b0, mant_full} + {24'b0, round_up};
    wire        mant_carry = mant_rnd[24];
    wire [22:0] mant_final = mant_carry ? 23'b0 : mant_rnd[22:0];
    wire [7:0]  exp_final;
    //  Exponent of result = bias + msb_pos = 127 + msb_pos (if no round carry)
    //  If round carry: exp += 1.
    assign exp_final = is_zero ? 8'h00
                               : (8'd127 + {1'b0, msb_pos} + {7'b0, mant_carry});

    wire [31:0] result =
        is_zero ? 32'b0
                : {is_neg, exp_final, mant_final};

    assign res = result;
    assign flags = (round_bit || sticky_bit) ? (5'b1 << `FF_NX) : 5'b0;
endmodule
