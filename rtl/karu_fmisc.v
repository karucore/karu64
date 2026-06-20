//  karu_fmisc.v
//  Combinational F-extension ops collected in one file:
//    - karu_fsgnj   : FSGNJ.S / FSGNJN.S / FSGNJX.S
//    - karu_fminmax : FMIN.S / FMAX.S (with NaN/zero rules)
//    - karu_fcmp    : FEQ.S / FLT.S / FLE.S (rd = int 0/1)
//    - karu_fclass  : FCLASS.S (rd = 10-bit class mask)
//    - karu_fmv_x_w : FMV.X.W (bits of f-reg low 32 -> sign-extended x)
//    - karu_fmv_w_x : FMV.W.X (x[31:0] -> f-reg, NaN-boxed)

`include "karu_fpkg.vh"

//  ------------------------------------------------------------------
//  FSGNJ family. sub picks which variant:
//    0 = FSGNJ  (sign of b)
//    1 = FSGNJN (sign of !b)
//    2 = FSGNJX (sign of a XOR b)
module karu_fsgnj (
    input  wire [1:0]   sub,
    input  wire [31:0]  a,
    input  wire [31:0]  b,
    output wire [31:0]  res
);
    wire new_sign =
        (sub == 2'd0) ?  b[31] :
        (sub == 2'd1) ? ~b[31] :
                        a[31] ^ b[31];
    assign res = {new_sign, a[30:0]};
endmodule

//  ------------------------------------------------------------------
//  FMIN / FMAX (sub: 0=min, 1=max). Spec quirks:
//    - if either input is signaling NaN, set NV and propagate canonical qNaN
//    - if one is quiet NaN and other is number, return the number
//    - if both NaN, return canonical qNaN
//    - -0 < +0 for min/max purposes (not the usual equality)
module karu_fminmax (
    input  wire         is_max,
    input  wire         is_m,       //  Zfa fminm/fmaxm: canonical NaN if EITHER input NaN
    input  wire [31:0]  a,
    input  wire [31:0]  b,
    output wire [31:0]  res,
    output wire [4:0]   flags
);
    wire        a_nan  = (a[30:23] == 8'hFF) && (a[22:0] != 23'h0);
    wire        b_nan  = (b[30:23] == 8'hFF) && (b[22:0] != 23'h0);
    wire        a_snan = a_nan && !a[22];
    wire        b_snan = b_nan && !b[22];
    wire        a_neg  = a[31];
    wire        b_neg  = b[31];
    wire [30:0] a_abs  = a[30:0];
    wire [30:0] b_abs  = b[30:0];

    //  signed compare: a < b
    wire a_lt_b =
        (a_neg && !b_neg) ? 1'b1 :
        (!a_neg && b_neg) ? 1'b0 :
        (a_neg && b_neg)  ? (a_abs > b_abs) :
                            (a_abs < b_abs);
    wire a_eq_b = (a == b);
    //  -0 < +0 for FMIN/FMAX: treat as a_lt_b when signs differ and both zero
    wire a_is_zero = (a[30:0] == 31'b0);
    wire b_is_zero = (b[30:0] == 31'b0);
    wire both_zero = a_is_zero && b_is_zero;
    //  If both zero and signs differ: a_lt_b = a is -0 (a_neg=1)
    wire a_lt_b_z = both_zero ? (a_neg && !b_neg) : a_lt_b;

    wire pick_a = is_max ? !a_lt_b_z : a_lt_b_z;

    //  fmin/fmax return the non-NaN operand; Zfa fminm/fmaxm (is_m) return the
    //  canonical NaN whenever EITHER operand is NaN.
    assign res =
        (is_m && (a_nan || b_nan)) ? `FP_S_QNAN :
        (a_nan && b_nan) ? `FP_S_QNAN :
        a_nan            ? b :
        b_nan            ? a :
        pick_a           ? a : b;

    assign flags = (a_snan || b_snan) ? (5'b1 << `FF_NV) : 5'b0;
endmodule

//  ------------------------------------------------------------------
//  FCMP: FEQ.S / FLT.S / FLE.S
//    sub: 0=LE, 1=LT, 2=EQ
//  Spec:
//    - FEQ: quiet (NaN inputs return 0, only signaling-NaN sets NV)
//    - FLT, FLE: signaling (any NaN input sets NV, result = 0)
module karu_fcmp (
    input  wire [1:0]   sub,
    input  wire         is_quiet,   //  Zfa fleq/fltq: NV only on signaling NaN
    input  wire [31:0]  a,
    input  wire [31:0]  b,
    output wire [63:0]  res,        //  0 or 1, written to int regfile
    output wire [4:0]   flags
);
    wire        a_nan  = (a[30:23] == 8'hFF) && (a[22:0] != 23'h0);
    wire        b_nan  = (b[30:23] == 8'hFF) && (b[22:0] != 23'h0);
    wire        a_snan = a_nan && !a[22];
    wire        b_snan = b_nan && !b[22];
    wire        any_nan = a_nan || b_nan;
    wire        any_snan = a_snan || b_snan;

    //  Signed compare with -0 == +0 (IEEE compare equates the two zeros)
    wire        a_zero = (a[30:0] == 31'b0);
    wire        b_zero = (b[30:0] == 31'b0);
    wire        eq_raw = (a == b);
    wire        eq_z   = a_zero && b_zero;  //  -0 == +0
    wire        eq     = eq_raw || eq_z;
    wire        a_neg = a[31];
    wire        b_neg = b[31];
    wire [30:0] a_abs = a[30:0];
    wire [30:0] b_abs = b[30:0];
    wire        lt =
        eq_z ? 1'b0 :
        (a_neg && !b_neg) ? 1'b1 :
        (!a_neg && b_neg) ? 1'b0 :
        (a_neg && b_neg)  ? (a_abs > b_abs) :
                            (a_abs < b_abs);

    wire is_le = (sub == 2'd0);
    wire is_lt = (sub == 2'd1);
    wire is_eq = (sub == 2'd2);

    wire result_bit =
        any_nan ? 1'b0 :
        is_eq   ? eq :
        is_lt   ? lt :
        is_le   ? (lt || eq) :
                  1'b0;

    assign res = {63'b0, result_bit};
    //  FLT/FLE signal on any NaN; FEQ and the Zfa quiet forms (fleq/fltq)
    //  signal only on a signaling NaN.
    wire nv = is_quiet ? any_snan
            : (is_eq && any_snan) || ((is_lt || is_le) && any_nan);
    assign flags = nv ? (5'b1 << `FF_NV) : 5'b0;
endmodule

//  ------------------------------------------------------------------
//  FCLASS.S: writes 10-bit one-hot classification mask to rd (int).
//    bit 0: -inf
//    bit 1: -normal
//    bit 2: -subnormal
//    bit 3: -0
//    bit 4: +0
//    bit 5: +subnormal
//    bit 6: +normal
//    bit 7: +inf
//    bit 8: signaling NaN
//    bit 9: quiet NaN
module karu_fclass (
    input  wire [31:0]  a,
    output wire [63:0]  res
);
    wire        s    = a[31];
    wire [7:0]  e    = a[30:23];
    wire [22:0] m    = a[22:0];
    wire        zero = (e == 0) && (m == 0);
    wire        sub  = (e == 0) && (m != 0);
    wire        inf  = (e == 8'hFF) && (m == 0);
    wire        nan  = (e == 8'hFF) && (m != 0);
    wire        snan = nan && !m[22];
    wire        qnan = nan && m[22];
    wire        norm = !zero && !sub && !inf && !nan;

    wire [9:0] mask = {
        qnan,                   //  bit 9
        snan,                   //  bit 8
        !s && inf,              //  bit 7
        !s && norm,             //  bit 6
        !s && sub,              //  bit 5
        !s && zero,             //  bit 4
         s && zero,             //  bit 3
         s && sub,              //  bit 2
         s && norm,             //  bit 1
         s && inf               //  bit 0
    };
    assign res = {54'b0, mask};
endmodule

//  ------------------------------------------------------------------
//  FMV.X.W: bits of the f-register's low 32 -> sign-extended to 64.
//  The f-source is fed in raw (no NaN-box check); behavior on un-boxed
//  values is implementation-defined per spec but RISC-V requires:
//    "FMV.X.W moves the single-precision value in f-reg rs1 into
//     integer register rd. The bits are not modified in the
//     transfer..."
//  If the f-reg holds a non-NaN-boxed value (upper 32 not all 1s),
//  some implementations substitute canonical NaN. We match spike:
//  move raw low 32 sign-extended, regardless of the upper bits.
module karu_fmv_x_w (
    input  wire [31:0]  a,
    output wire [63:0]  res
);
    assign res = {{32{a[31]}}, a};
endmodule

//  ------------------------------------------------------------------
//  FMV.W.X: bits of int reg low 32 -> NaN-boxed into 64-bit f-reg.
module karu_fmv_w_x (
    input  wire [63:0]  x,
    output wire [63:0]  res
);
    assign res = {`FP_S_NAN_BOX, x[31:0]};
endmodule

//  ==================================================================
//  Double-precision variants. Mostly mechanical 32->64-bit widenings
//  of the modules above (exp 11 bits, mant 52 bits, no NaN-box).
//  ==================================================================

//  FSGNJ.D / FSGNJN.D / FSGNJX.D
module karu_fsgnj_d (
    input  wire [1:0]   sub,
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    output wire [63:0]  res
);
    wire new_sign =
        (sub == 2'd0) ?  b[63] :
        (sub == 2'd1) ? ~b[63] :
                        a[63] ^ b[63];
    assign res = {new_sign, a[62:0]};
endmodule

//  FMIN.D / FMAX.D
module karu_fminmax_d (
    input  wire         is_max,
    input  wire         is_m,       //  Zfa fminm.d/fmaxm.d
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    output wire [63:0]  res,
    output wire [4:0]   flags
);
    wire        a_nan  = (a[62:52] == 11'h7FF) && (a[51:0] != 52'h0);
    wire        b_nan  = (b[62:52] == 11'h7FF) && (b[51:0] != 52'h0);
    wire        a_snan = a_nan && !a[51];
    wire        b_snan = b_nan && !b[51];
    wire        a_neg  = a[63];
    wire        b_neg  = b[63];
    wire [62:0] a_abs  = a[62:0];
    wire [62:0] b_abs  = b[62:0];

    wire a_lt_b =
        (a_neg && !b_neg) ? 1'b1 :
        (!a_neg && b_neg) ? 1'b0 :
        (a_neg && b_neg)  ? (a_abs > b_abs) :
                            (a_abs < b_abs);
    wire a_is_zero = (a[62:0] == 63'b0);
    wire b_is_zero = (b[62:0] == 63'b0);
    wire both_zero = a_is_zero && b_is_zero;
    wire a_lt_b_z = both_zero ? (a_neg && !b_neg) : a_lt_b;

    wire pick_a = is_max ? !a_lt_b_z : a_lt_b_z;

    assign res =
        (is_m && (a_nan || b_nan)) ? `FP_D_QNAN :
        (a_nan && b_nan) ? `FP_D_QNAN :
        a_nan            ? b :
        b_nan            ? a :
        pick_a           ? a : b;

    assign flags = (a_snan || b_snan) ? (5'b1 << `FF_NV) : 5'b0;
endmodule

//  FCMP.D: FEQ.D / FLT.D / FLE.D  (sub: 0=LE, 1=LT, 2=EQ)
module karu_fcmp_d (
    input  wire [1:0]   sub,
    input  wire         is_quiet,   //  Zfa fleq.d/fltq.d
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    output wire [63:0]  res,
    output wire [4:0]   flags
);
    wire        a_nan  = (a[62:52] == 11'h7FF) && (a[51:0] != 52'h0);
    wire        b_nan  = (b[62:52] == 11'h7FF) && (b[51:0] != 52'h0);
    wire        a_snan = a_nan && !a[51];
    wire        b_snan = b_nan && !b[51];
    wire        any_nan  = a_nan || b_nan;
    wire        any_snan = a_snan || b_snan;

    wire        a_zero = (a[62:0] == 63'b0);
    wire        b_zero = (b[62:0] == 63'b0);
    wire        eq_raw = (a == b);
    wire        eq_z   = a_zero && b_zero;
    wire        eq     = eq_raw || eq_z;
    wire        a_neg = a[63];
    wire        b_neg = b[63];
    wire [62:0] a_abs = a[62:0];
    wire [62:0] b_abs = b[62:0];
    wire        lt =
        eq_z ? 1'b0 :
        (a_neg && !b_neg) ? 1'b1 :
        (!a_neg && b_neg) ? 1'b0 :
        (a_neg && b_neg)  ? (a_abs > b_abs) :
                            (a_abs < b_abs);

    wire is_le = (sub == 2'd0);
    wire is_lt = (sub == 2'd1);
    wire is_eq = (sub == 2'd2);

    wire result_bit =
        any_nan ? 1'b0 :
        is_eq   ? eq :
        is_lt   ? lt :
        is_le   ? (lt || eq) :
                  1'b0;

    assign res = {63'b0, result_bit};
    wire nv = is_quiet ? any_snan
            : (is_eq && any_snan) || ((is_lt || is_le) && any_nan);
    assign flags = nv ? (5'b1 << `FF_NV) : 5'b0;
endmodule

//  FCLASS.D: 10-bit mask (same encoding as FCLASS.S).
module karu_fclass_d (
    input  wire [63:0]  a,
    output wire [63:0]  res
);
    wire        s    = a[63];
    wire [10:0] e    = a[62:52];
    wire [51:0] m    = a[51:0];
    wire        zero = (e == 11'h0) && (m == 52'h0);
    wire        sub  = (e == 11'h0) && (m != 52'h0);
    wire        inf  = (e == 11'h7FF) && (m == 52'h0);
    wire        nan  = (e == 11'h7FF) && (m != 52'h0);
    wire        snan = nan && !m[51];
    wire        qnan = nan && m[51];
    wire        norm = !zero && !sub && !inf && !nan;

    wire [9:0] mask = {
        qnan, snan,
        !s && inf,  !s && norm, !s && sub,  !s && zero,
         s && zero,  s && sub,   s && norm,  s && inf
    };
    assign res = {54'b0, mask};
endmodule

//  FMV.X.D: raw 64-bit move from f-reg to x-reg.
module karu_fmv_x_d (
    input  wire [63:0]  a,
    output wire [63:0]  res
);
    assign res = a;
endmodule

//  FMV.D.X: raw 64-bit move from x-reg to f-reg (no NaN-box).
module karu_fmv_d_x (
    input  wire [63:0]  x,
    output wire [63:0]  res
);
    assign res = x;
endmodule
