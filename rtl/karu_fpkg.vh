//  karu_fpkg.vh
//  Shared encodings for the floating-point unit (F + future D).
//  Field widths, rounding modes, fflag bit positions, canonical NaNs.

`ifndef KARU_FPKG_VH
`define KARU_FPKG_VH

`include "karu_ext.vh"                  //  F/D/V/K extension enables

//  ---- IEEE 754 single-precision field widths ----
`define FP_S_EXP_W      8
`define FP_S_MANT_W     23
`define FP_S_BIAS       127
`define FP_S_EXP_MAX    8'hFF

//  (future) double-precision
`define FP_D_EXP_W      11
`define FP_D_MANT_W     52
`define FP_D_BIAS       1023

//  ---- canonical NaNs ----
`define FP_S_QNAN       32'h7FC0_0000       // canonical quiet NaN, single
`define FP_S_NAN_BOX    32'hFFFF_FFFF       // upper 32 bits of NaN-box
`define FP_H_QNAN       16'h7E00            // canonical quiet NaN, half (Zvfhmin)
`define FP_H_NAN_BOX    48'hFFFF_FFFF_FFFF  // upper 48 bits of a half NaN-box (Zfhmin)

//  ---- frm encodings (matches RISC-V spec) ----
`define FRM_RNE         3'b000      // round to nearest, ties to even
`define FRM_RTZ         3'b001      // round toward zero (truncate)
`define FRM_RDN         3'b010      // round down (toward -inf)
`define FRM_RUP         3'b011      // round up (toward +inf)
`define FRM_RMM         3'b100      // round to nearest, ties to max magnitude
`define FRM_ROD         3'b110      // round-to-odd (synthetic; never from frm CSR).
                                    // Only the vector vfncvt.rod.f.f narrowing convert
                                    // drives this; karu_fcvt_sd interprets it.
`define FRM_DYN         3'b111      // dynamic: use frm CSR (instruction-level)

//  ---- fflags bit positions ----
`define FF_NX           0           // inexact
`define FF_UF           1           // underflow
`define FF_OF           2           // overflow
`define FF_DZ           3           // divide by zero
`define FF_NV           4           // invalid operation

//  ---- FPU sub-op encodings (uop.sub for UNIT_FPU) ----
//  Grouped so the dispatcher can route on a few bits.
`define FOP_ADD         5'h00       // fadd.s   (uses funct7=0000000)
`define FOP_SUB         5'h01       // fsub.s   (funct7=0000100)
`define FOP_MUL         5'h02       // fmul.s   (funct7=0001000)
`define FOP_DIV         5'h03       // fdiv.s   (funct7=0001100)
`define FOP_SQRT        5'h04       // fsqrt.s  (funct7=0101100, rs2=0)
`define FOP_MIN         5'h05       // fmin.s   (funct7=0010100, fn3=0)
`define FOP_MAX         5'h06       // fmax.s   (funct7=0010100, fn3=1)
`define FOP_SGNJ        5'h07       // fsgnj.s  (funct7=0010000, fn3=0)
`define FOP_SGNJN       5'h08       // fsgnjn.s (funct7=0010000, fn3=1)
`define FOP_SGNJX       5'h09       // fsgnjx.s (funct7=0010000, fn3=2)
`define FOP_EQ          5'h0a       // feq.s    (funct7=1010000, fn3=2)
`define FOP_LT          5'h0b       // flt.s    (funct7=1010000, fn3=1)
`define FOP_LE          5'h0c       // fle.s    (funct7=1010000, fn3=0)
`define FOP_CLASS       5'h0d       // fclass.s (funct7=1110000, fn3=1, rs2=0)
`define FOP_MV_X_W      5'h0e       // fmv.x.w  (funct7=1110000, fn3=0, rs2=0)
`define FOP_MV_W_X      5'h0f       // fmv.w.x  (funct7=1111000, fn3=0, rs2=0)
`define FOP_CVT_W_S     5'h10       // fcvt.w.s   (funct7=1100000, rs2=0)
`define FOP_CVT_WU_S    5'h11       // fcvt.wu.s  (funct7=1100000, rs2=1)
`define FOP_CVT_L_S     5'h12       // fcvt.l.s   (funct7=1100000, rs2=2)
`define FOP_CVT_LU_S    5'h13       // fcvt.lu.s  (funct7=1100000, rs2=3)
`define FOP_CVT_S_W     5'h14       // fcvt.s.w   (funct7=1101000, rs2=0)
`define FOP_CVT_S_WU    5'h15       // fcvt.s.wu  (funct7=1101000, rs2=1)
`define FOP_CVT_S_L     5'h16       // fcvt.s.l   (funct7=1101000, rs2=2)
`define FOP_CVT_S_LU    5'h17       // fcvt.s.lu  (funct7=1101000, rs2=3)
`define FOP_MADD        5'h18       // fmadd.{s|d}   (MADD opcode)
`define FOP_MSUB        5'h19       // fmsub.{s|d}
`define FOP_NMSUB       5'h1a       // fnmsub.{s|d}
`define FOP_NMADD       5'h1b       // fnmadd.{s|d}

//  Cross-precision conversions (introduced with the D extension).
//  The other FCVT/FMV/FCLASS opcodes are reused for the D variant by
//  the fp_is_d bit (set by the decoder from fmt).
`define FOP_CVT_S_D     5'h1c       // fcvt.s.d   (D -> S, rounds)
`define FOP_CVT_D_S     5'h1d       // fcvt.d.s   (S -> D, exact)

//  Zfhmin scalar FP16 conversions (the H<->S/D moves). The source/dest that
//  is NOT half is picked by is_d (0=single, 1=double):
//    FROM_H: H -> {S,D}  (fcvt.s.h / fcvt.d.h)   -- H source always
//    TO_H:   {S,D} -> H  (fcvt.h.s / fcvt.h.d)   -- H dest always
//  fmv.x.h / fmv.h.x reuse FOP_MV_X_W / FOP_MV_W_X with the is_h flag.
`define FOP_CVT_FROM_H  5'h1e       // half -> single/double (exact widen)
`define FOP_CVT_TO_H    5'h1f       // single/double -> half (rounds)

//  ---- Sub-op classification helpers ----
//  Ops that write the integer register file (rd is x reg, not f reg):
//    FCMP (EQ/LT/LE), FCLASS, FMV.X.W, FCVT.{W,WU,L,LU}.S
`define FOP_WRITES_X(sub) \
    ((sub) == `FOP_EQ || (sub) == `FOP_LT || (sub) == `FOP_LE \
     || (sub) == `FOP_CLASS || (sub) == `FOP_MV_X_W \
     || (sub) == `FOP_CVT_W_S || (sub) == `FOP_CVT_WU_S \
     || (sub) == `FOP_CVT_L_S || (sub) == `FOP_CVT_LU_S)

//  Ops that read an integer source (rs1 is x reg): FMV.{W,D}.X, FCVT.{S,D}.{W,WU,L,LU}
`define FOP_READS_X(sub) \
    ((sub) == `FOP_MV_W_X \
     || (sub) == `FOP_CVT_S_W || (sub) == `FOP_CVT_S_WU \
     || (sub) == `FOP_CVT_S_L || (sub) == `FOP_CVT_S_LU)

//  Canonical double-precision quiet NaN.
`define FP_D_QNAN       64'h7FF8_0000_0000_0000

//  ---- Zfa op selector (fp_zfa side field, FPU only; 0 = not a Zfa op) ----
//  is_d picks single/double; these reuse OP-FP funct7 groups with new
//  funct3/rs2, so they need a side channel rather than new FOP sub codes.
`define FPZ_NONE        4'd0
`define FPZ_FMINM       4'd1    //  fminm: fmin but canonical-NaN if either NaN
`define FPZ_FMAXM       4'd2    //  fmaxm
`define FPZ_FLEQ        4'd3    //  fleq: fle but quiet (NV only on sNaN)
`define FPZ_FLTQ        4'd4    //  fltq: flt but quiet
`define FPZ_FROUND      4'd5    //  fround: round to integer-valued float (rm)
`define FPZ_FROUNDNX    4'd6    //  froundnx: + sets NX on inexact
`define FPZ_FCVTMOD     4'd7    //  fcvtmod.w.d: f64 -> int32 mod 2^32 (rtz)
`define FPZ_FLI         4'd8    //  fli: load FP immediate from the 32-entry table

`endif
