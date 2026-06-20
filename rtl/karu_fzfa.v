//  karu_fzfa.v
//  Zfa datapath that doesn't reuse an existing unit: fcvtmod.w.d.
//  (fround/froundnx reuse f2i->i2f; fminm/fmaxm/fleq/fltq are flag-modes of
//  karu_fminmax/karu_fcmp; fli is a ROM in karu_fpu.)
//
//  fcvtmod.w.d: convert a binary64 to a signed 32-bit integer using
//  round-toward-zero, then reduce modulo 2^32 (i.e. keep the low 32 bits and
//  sign-extend bit 31 to XLEN). Flags:
//    NV = NaN | inf | (the rtz integer is outside [-2^31, 2^31-1])
//    NX = a nonzero fraction was discarded (and not NaN/inf)
//  Validated bit-exact against spike (make zfa-test).

`include "karu_fpkg.vh"

module karu_fcvtmod_wd (
    input  wire [63:0]  a,
    output wire [63:0]  res,
    output wire [4:0]   flags
);
    wire        s     = a[63];
    wire [10:0] e     = a[62:52];
    wire [51:0] m     = a[51:0];
    wire        is_nan = (e == 11'h7FF) && (m != 52'h0);
    wire        is_inf = (e == 11'h7FF) && (m == 52'h0);
    wire        is_zero= (e == 11'h0)   && (m == 52'h0);
    wire        is_sub = (e == 11'h0)   && (m != 52'h0);
    wire signed [12:0]  E = $signed({2'b0, e}) - 13'sd1023;
    wire [52:0] sig = {1'b1, m};        //  implicit-1 significand (normal)

    //  ---- 0 <= E < 52 path (right-shift out the fractional bits) ----
    wire [5:0]  shift     = 6'd52 - E[5:0];     //  valid only when 0<=E<52
    wire [52:0] intpart   = sig >> shift;       //  integer magnitude (< 2^52)
    wire [52:0] frac_mask = (53'b1 << shift) - 53'b1;
    wire        frac_lo_nz = (sig & frac_mask) != 53'b0;
    wire        oor_lo = (!s && (intpart > 53'h0000_7FFF_FFFF)) //  > 2^31-1 (pos)
                       || ( s && (intpart > 53'h0000_8000_0000));   //  > 2^31   (neg)

    //  ---- E >= 52 path (already integer, |int| >= 2^52 -> out of range) ----
    wire [31:0] mag32_hi = (E - 13'sd52 >= 13'sd32) ? 32'b0
                           : (sig[31:0] << (E - 13'sd52));  //  (sig<<k) mod 2^32

    //  magnitude reduced mod 2^32, the discarded-fraction flag, and whether the
    //  true |integer| exceeds the signed-32 range.
    reg  [31:0] mag32;
    reg         frac_nz;
    reg         oor;
    always @(*) begin
        mag32 = 32'b0; frac_nz = 1'b0; oor = 1'b0;
        if (is_zero) begin
            //  exact zero -> 0, no flags
        end else if (is_sub || E < 13'sd0) begin
            //  |x| < 1 -> rtz integer is 0, fraction discarded
            frac_nz = 1'b1;
        end else if (E >= 13'sd52) begin
            mag32 = mag32_hi;   oor = 1'b1;
        end else begin
            mag32 = intpart[31:0];  frac_nz = frac_lo_nz;   oor = oor_lo;
        end
    end

    //  2's-complement mod 2^32, then sign-extend bit 31.
    wire [31:0] res32 = s ? (~mag32 + 32'd1) : mag32;
    assign res = (is_nan || is_inf) ? 64'd0 : {{32{res32[31]}}, res32};

    assign flags =
        ((is_nan || is_inf || oor) ? (5'b1 << `FF_NV) : 5'b0) |
        ((!is_nan && !is_inf && frac_nz) ? (5'b1 << `FF_NX) : 5'b0);
endmodule
