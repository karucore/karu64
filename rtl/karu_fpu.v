//  karu_fpu.v
//  Floating-point top-level dispatcher. Routes the incoming uop to the
//  appropriate sub-unit (fmul / fadd / fdiv / fsqrt / fcvt / fcmp /
//  fclass / fmv / fsgnj / fminmax) -- for both F (single, fmt=0) and D
//  (double, fmt=1) precision -- waits for its done, and presents a
//  single req/busy/done/res/flags handshake to the core.
//
//  Combinational ops (sgnj, class, cmp, fmv, min/max, cvt) latch on
//  the req cycle and done pulses the same cycle.
//
//  Multi-cycle ops (mul, div, sqrt, add) drive the sub-unit's req for
//  one cycle and propagate its done.
//
//  FMA is fused (single rounding): routed to karu_ffma (F) / karu_ffma_d
//  (D), which compute a*b +/- c over a full-width intermediate and round
//  once. (The older composed mul->add sequencer path was removed 2026-06;
//  FMA now parks in ST_WAIT like any other multi-cycle sub-unit.)
//
//  The result-width discriminator (rd_is_f) is set by the decoder; this
//  module produces a 64-bit `res`:
//    - F result going to f-regfile: NaN-boxed single in low 32
//    - D result going to f-regfile: raw 64-bit value
//    - integer regfile target (cmp/class/fmv.x/f2i): sign- or zero-ext

`include "karu_fpkg.vh"
`include "karu_uop_defs.vh"

module karu_fpu (
    input  wire         clk,
    input  wire         rst,

    //  -- request port --
    input  wire         req,
    output wire         busy,
    input  wire [4:0]   sub,
    input  wire [2:0]   rm,             //  rounding mode (DYN resolved upstream)
    input  wire         is_d,           //  1 = double-precision; 0 = single
    input  wire         is_h,           //  1 = Zfhmin half-precision fmv (x.h / h.x)
    input  wire [3:0]   fp_zfa,         //  Zfa op selector (FPZ_*, 0 = not Zfa)
    input  wire [63:0]  op1,
    input  wire [63:0]  op2,
    input  wire [63:0]  op3,            //  rs3 (FMA only)

    //  -- completion --
    output reg          done,
    output reg [63:0]   res,            //  64 bits
    output reg [4:0]    fflags
);
    //  ==================================================================
    //  NaN-box check for SINGLE-precision operand reads. Doubles use the
    //  full 64-bit register value with no boxing logic.
    //  ==================================================================
    function [31:0] unbox;
        input [63:0] v;
        begin
            unbox = (v[63:32] == 32'hFFFF_FFFF) ? v[31:0] : `FP_S_QNAN;
        end
    endfunction

    //  NaN-box check for HALF-precision operand reads (Zfhmin): an FP16 in a
    //  FLEN=64 f-register is boxed with the upper 48 bits all-1s.
    function [15:0] unbox16;
        input [63:0] v;
        begin
            unbox16 = (v[63:16] == `FP_H_NAN_BOX) ? v[15:0] : `FP_H_QNAN;
        end
    endfunction

    wire [31:0] f_op1 = unbox(op1);
    wire [31:0] f_op2 = unbox(op2);
    wire [31:0] f_op3 = unbox(op3);

    //  D-precision operand views (raw 64-bit, no boxing).
    wire [63:0] d_op1 = op1;
    wire [63:0] d_op2 = op2;
    wire [63:0] d_op3 = op3;

    //  ==================================================================
    //  Sub-op classification (precision-agnostic except for cross-cvt).
    //  ==================================================================
    //  Zfa ops that do NOT reuse a sub-based datapath (fli + the cvt-path
    //  fround/froundnx/fcvtmod) carry sub=FOP_ADD as a placeholder; suppress the
    //  sub classifications for them so the FPU routes purely on fp_zfa.
    //  (fminm/fmaxm/fleq/fltq DO reuse min/max/cmp and are not overridden.)
    wire zfa_override = (fp_zfa == `FPZ_FLI) || (fp_zfa == `FPZ_FROUND)
                     || (fp_zfa == `FPZ_FROUNDNX) || (fp_zfa == `FPZ_FCVTMOD);

    wire is_add  = ((sub == `FOP_ADD)  || (sub == `FOP_SUB)) && !zfa_override;
    wire is_sub  = (sub == `FOP_SUB);
    wire is_mul  = (sub == `FOP_MUL);
    wire is_div  = (sub == `FOP_DIV);
    wire is_sqrt = (sub == `FOP_SQRT);
    wire is_minmax = (sub == `FOP_MIN) || (sub == `FOP_MAX);
    wire is_max  = (sub == `FOP_MAX);
    wire is_sgnj_fam = (sub == `FOP_SGNJ) || (sub == `FOP_SGNJN) || (sub == `FOP_SGNJX);
    wire [1:0] sgnj_sub = (sub == `FOP_SGNJ)  ? 2'd0 :
                          (sub == `FOP_SGNJN) ? 2'd1 :
                          (sub == `FOP_SGNJX) ? 2'd2 : 2'd0;
    wire is_cmp = (sub == `FOP_EQ) || (sub == `FOP_LT) || (sub == `FOP_LE);
    wire [1:0] cmp_sub = (sub == `FOP_LE) ? 2'd0 :
                         (sub == `FOP_LT) ? 2'd1 : 2'd2;
    wire is_class = (sub == `FOP_CLASS);
    wire is_mvxw  = (sub == `FOP_MV_X_W);       //  FMV.X.W or FMV.X.D
    wire is_mvwx  = (sub == `FOP_MV_W_X);       //  FMV.W.X or FMV.D.X
    wire is_f2i   = (sub == `FOP_CVT_W_S) || (sub == `FOP_CVT_WU_S)
                 || (sub == `FOP_CVT_L_S) || (sub == `FOP_CVT_LU_S);
    wire is_i2f   = (sub == `FOP_CVT_S_W) || (sub == `FOP_CVT_S_WU)
                 || (sub == `FOP_CVT_S_L) || (sub == `FOP_CVT_S_LU);
    wire cvt_long     = (sub == `FOP_CVT_L_S)  || (sub == `FOP_CVT_LU_S)
                     || (sub == `FOP_CVT_S_L)  || (sub == `FOP_CVT_S_LU);
    wire cvt_unsigned = (sub == `FOP_CVT_WU_S) || (sub == `FOP_CVT_LU_S)
                     || (sub == `FOP_CVT_S_WU) || (sub == `FOP_CVT_S_LU);
    wire is_cvt_sd = (sub == `FOP_CVT_S_D);     //  D -> S (combinational+round)
    wire is_cvt_ds = (sub == `FOP_CVT_D_S);     //  S -> D (exact)
    //  Zfhmin H<->{S,D} conversions. is_d picks the non-half side.
    wire is_cvt_from_h = (sub == `FOP_CVT_FROM_H);  //  H -> S/D (exact widen)
    wire is_cvt_to_h   = (sub == `FOP_CVT_TO_H);    //  S/D -> H (rounds)
    wire is_fma = (sub == `FOP_MADD)  || (sub == `FOP_MSUB)
               || (sub == `FOP_NMSUB) || (sub == `FOP_NMADD);

    //  ==================================================================
    //  Combinational F sub-units
    //  ==================================================================
    wire [31:0] sgnj_res_s;
    karu_fsgnj u_sgnj_s (.sub(sgnj_sub), .a(f_op1), .b(f_op2), .res(sgnj_res_s));

    //  Zfa flag-modes: fminm/fmaxm (canonical-NaN) reuse min/max; fleq/fltq
    //  (quiet compare) reuse the comparator. is_max / cmp_sub come from sub.
    wire        zfa_m     = (fp_zfa == `FPZ_FMINM) || (fp_zfa == `FPZ_FMAXM);
    wire        zfa_quiet = (fp_zfa == `FPZ_FLEQ)  || (fp_zfa == `FPZ_FLTQ);

    wire [31:0] mm_res_s; wire [4:0] mm_flags_s;
    karu_fminmax u_mm_s (.is_max(is_max), .is_m(zfa_m), .a(f_op1), .b(f_op2),
                         .res(mm_res_s), .flags(mm_flags_s));

    wire [63:0] cmp_res_s; wire [4:0] cmp_flags_s;
    karu_fcmp u_cmp_s (.sub(cmp_sub), .is_quiet(zfa_quiet), .a(f_op1), .b(f_op2),
                       .res(cmp_res_s), .flags(cmp_flags_s));

    wire [63:0] cls_res_s;
    karu_fclass u_cls_s (.a(f_op1), .res(cls_res_s));

    wire [63:0] mvxw_res;
    //  FMV.X.W is a raw bit move; bypass NaN-box.
    karu_fmv_x_w u_mvxw_s (.a(op1[31:0]), .res(mvxw_res));

    wire [63:0] mvwx_res;
    karu_fmv_w_x u_mvwx_s (.x(op1), .res(mvwx_res));

    //  ---- 2-cycle conversion path ----
    //  The int<->float / S<->D conversions are deep combinational cones. They
    //  run the cycle AFTER their operand is registered (cvt_op1_q), so the
    //  front-end (IFU/decode/operand-select) is not in series with the
    //  conversion + result mux -- that combined cone was the last 125 MHz
    //  limiter. cf_op1q = NaN-box-checked single view of the registered operand.
    reg [63:0]  cvt_op1_q;
    reg [2:0]   cvt_rm_q;
    reg         cvt_long_q, cvt_unsigned_q;
    reg         cvt_f2i_q, cvt_i2f_q, cvt_sd_q, cvt_ds_q, cvt_isd_q;
    reg         cvt_fromh_q, cvt_toh_q;     //  Zfhmin H conversions in flight
    reg [3:0]   cvt_zfa_q;                  //  Zfa cvt-path op in flight (FPZ_*)
    wire [31:0] cf_op1q = unbox(cvt_op1_q);

    wire [63:0] f2i_res; wire [4:0] f2i_flags;
    karu_f2i u_f2i (.rm(cvt_rm_q), .is_long(cvt_long_q), .is_unsigned(cvt_unsigned_q),
                    .a(cf_op1q), .res(f2i_res), .flags(f2i_flags));

    wire [31:0] i2f_res; wire [4:0] i2f_flags;
    karu_i2f u_i2f (.rm(cvt_rm_q), .is_long(cvt_long_q), .is_unsigned(cvt_unsigned_q),
                    .x(cvt_op1_q), .res(i2f_res), .flags(i2f_flags));

    //  ---- Zfhmin FP16 conversions (combinational, on the registered operand) ----
    //  ch_op1q = NaN-box-checked half view of the registered operand.
    wire [15:0] ch_op1q = unbox16(cvt_op1_q);
    //  fcvt.s.h (and stage 1 of fcvt.d.h): H -> S, exact.
    wire [31:0] hs_res; wire [4:0] hs_flags;
    karu_fcvt_hs u_cvt_hs (.a(ch_op1q), .res(hs_res), .flags(hs_flags));
    //  fcvt.h.s: S -> H, rounds.
    wire [15:0] sh_res; wire [4:0] sh_flags;
    karu_fcvt_sh u_cvt_sh (.rm(cvt_rm_q), .a(cf_op1q), .res(sh_res), .flags(sh_flags));

    //  ==================================================================
    //  Zfa: fli ROM (immediate path) + fround single-precision compose.
    //  ==================================================================
    //  fli loads one of 32 architectural constants, indexed by op1[4:0].
    function [31:0] fli_s_rom; input [4:0] i; begin
        case (i)
            5'd0:  fli_s_rom = 32'hbf800000; 5'd1:  fli_s_rom = 32'h00800000;
            5'd2:  fli_s_rom = 32'h37800000; 5'd3:  fli_s_rom = 32'h38000000;
            5'd4:  fli_s_rom = 32'h3b800000; 5'd5:  fli_s_rom = 32'h3c000000;
            5'd6:  fli_s_rom = 32'h3d800000; 5'd7:  fli_s_rom = 32'h3e000000;
            5'd8:  fli_s_rom = 32'h3e800000; 5'd9:  fli_s_rom = 32'h3ea00000;
            5'd10: fli_s_rom = 32'h3ec00000; 5'd11: fli_s_rom = 32'h3ee00000;
            5'd12: fli_s_rom = 32'h3f000000; 5'd13: fli_s_rom = 32'h3f200000;
            5'd14: fli_s_rom = 32'h3f400000; 5'd15: fli_s_rom = 32'h3f600000;
            5'd16: fli_s_rom = 32'h3f800000; 5'd17: fli_s_rom = 32'h3fa00000;
            5'd18: fli_s_rom = 32'h3fc00000; 5'd19: fli_s_rom = 32'h3fe00000;
            5'd20: fli_s_rom = 32'h40000000; 5'd21: fli_s_rom = 32'h40200000;
            5'd22: fli_s_rom = 32'h40400000; 5'd23: fli_s_rom = 32'h40800000;
            5'd24: fli_s_rom = 32'h41000000; 5'd25: fli_s_rom = 32'h41800000;
            5'd26: fli_s_rom = 32'h43000000; 5'd27: fli_s_rom = 32'h43800000;
            5'd28: fli_s_rom = 32'h47000000; 5'd29: fli_s_rom = 32'h47800000;
            5'd30: fli_s_rom = 32'h7f800000; 5'd31: fli_s_rom = 32'h7fc00000;
        endcase
    end endfunction
    function [63:0] fli_d_rom; input [4:0] i; begin
        case (i)
            5'd0:  fli_d_rom = 64'hbff0000000000000; 5'd1:  fli_d_rom = 64'h0010000000000000;
            5'd2:  fli_d_rom = 64'h3ef0000000000000; 5'd3:  fli_d_rom = 64'h3f00000000000000;
            5'd4:  fli_d_rom = 64'h3f70000000000000; 5'd5:  fli_d_rom = 64'h3f80000000000000;
            5'd6:  fli_d_rom = 64'h3fb0000000000000; 5'd7:  fli_d_rom = 64'h3fc0000000000000;
            5'd8:  fli_d_rom = 64'h3fd0000000000000; 5'd9:  fli_d_rom = 64'h3fd4000000000000;
            5'd10: fli_d_rom = 64'h3fd8000000000000; 5'd11: fli_d_rom = 64'h3fdc000000000000;
            5'd12: fli_d_rom = 64'h3fe0000000000000; 5'd13: fli_d_rom = 64'h3fe4000000000000;
            5'd14: fli_d_rom = 64'h3fe8000000000000; 5'd15: fli_d_rom = 64'h3fec000000000000;
            5'd16: fli_d_rom = 64'h3ff0000000000000; 5'd17: fli_d_rom = 64'h3ff4000000000000;
            5'd18: fli_d_rom = 64'h3ff8000000000000; 5'd19: fli_d_rom = 64'h3ffc000000000000;
            5'd20: fli_d_rom = 64'h4000000000000000; 5'd21: fli_d_rom = 64'h4004000000000000;
            5'd22: fli_d_rom = 64'h4008000000000000; 5'd23: fli_d_rom = 64'h4010000000000000;
            5'd24: fli_d_rom = 64'h4020000000000000; 5'd25: fli_d_rom = 64'h4030000000000000;
            5'd26: fli_d_rom = 64'h4060000000000000; 5'd27: fli_d_rom = 64'h4070000000000000;
            5'd28: fli_d_rom = 64'h40e0000000000000; 5'd29: fli_d_rom = 64'h40f0000000000000;
            5'd30: fli_d_rom = 64'h7ff0000000000000; 5'd31: fli_d_rom = 64'h7ff8000000000000;
        endcase
    end endfunction
    wire [31:0] fli_s_val = fli_s_rom(op1[4:0]);
    wire [63:0] fli_d_val = fli_d_rom(op1[4:0]);

    //  fround.s / froundnx.s: compose f2i (rtz/rm) -> i2f, reusing the
    //  TestFloat-validated converters; special-case NaN/zero/already-integer.
    //  (int32 always fits because the compose path is only taken for E<23.)
    wire [63:0] frs_f2i_res; wire [4:0] frs_f2i_fl;
    karu_f2i u_fr_f2i_s (.rm(cvt_rm_q), .is_long(1'b0), .is_unsigned(1'b0),
                         .a(cf_op1q), .res(frs_f2i_res), .flags(frs_f2i_fl));
    wire [31:0] frs_i2f_res;
    karu_i2f u_fr_i2f_s (.rm(cvt_rm_q), .is_long(1'b0), .is_unsigned(1'b0),
                         .x(frs_f2i_res), .res(frs_i2f_res), .flags());
    wire        frs_sign = cf_op1q[31];
    wire [7:0]  frs_e    = cf_op1q[30:23];
    wire        frs_nan  = (frs_e == 8'hFF) && (cf_op1q[22:0] != 23'h0);
    wire        frs_snan = frs_nan && !cf_op1q[22];
    wire        frs_zero = (frs_e == 8'h00) && (cf_op1q[22:0] == 23'h0);
    wire signed [9:0] frs_E = $signed({2'b0, frs_e}) - 10'sd127;
    wire        frs_intq = (frs_E >= 10'sd23);              //  already integer (incl inf)
    wire        frs_compose0 = (frs_f2i_res[31:0] == 32'h0);    //  rounds to zero
    wire [31:0] fround_s_res =
        frs_nan  ? `FP_S_QNAN :
        frs_zero ? cf_op1q :
        frs_intq ? cf_op1q :
        frs_compose0 ? {frs_sign, 31'b0} : frs_i2f_res;
    wire        fround_s_nx = !frs_nan && !frs_zero && !frs_intq && frs_f2i_fl[`FF_NX];

    //  ==================================================================
    //  Combinational D sub-units
    //  ==================================================================
`ifdef KARU_EN_D
    wire [63:0] sgnj_res_d;
    karu_fsgnj_d u_sgnj_d (.sub(sgnj_sub), .a(d_op1), .b(d_op2), .res(sgnj_res_d));

    wire [63:0] mm_res_d; wire [4:0] mm_flags_d;
    karu_fminmax_d u_mm_d (.is_max(is_max), .is_m(zfa_m), .a(d_op1), .b(d_op2),
                           .res(mm_res_d), .flags(mm_flags_d));

    wire [63:0] cmp_res_d; wire [4:0] cmp_flags_d;
    karu_fcmp_d u_cmp_d (.sub(cmp_sub), .is_quiet(zfa_quiet), .a(d_op1), .b(d_op2),
                         .res(cmp_res_d), .flags(cmp_flags_d));

    wire [63:0] cls_res_d;
    karu_fclass_d u_cls_d (.a(d_op1), .res(cls_res_d));

    wire [63:0] mvxd_res;   karu_fmv_x_d u_mvxd_d (.a(op1), .res(mvxd_res));
    wire [63:0] mvdx_res;   karu_fmv_d_x u_mvdx_d (.x(op1), .res(mvdx_res));

    //  D <-> int and D <-> S conversions (combinational): supplied by
    //  karu_fcvt_d which contains all 10 D-specific cvt variants.
    wire [63:0] f2i_d_res;  wire [4:0] f2i_d_flags;
    wire [63:0] i2f_d_res;  wire [4:0] i2f_d_flags;
    wire [31:0] cvt_sd_res; wire [4:0] cvt_sd_flags;
    wire [63:0] cvt_ds_res; wire [4:0] cvt_ds_flags;
    karu_f2i_d u_f2i_d (.rm(cvt_rm_q), .is_long(cvt_long_q), .is_unsigned(cvt_unsigned_q),
                        .a(cvt_op1_q), .res(f2i_d_res), .flags(f2i_d_flags));
    karu_i2f_d u_i2f_d (.rm(cvt_rm_q), .is_long(cvt_long_q), .is_unsigned(cvt_unsigned_q),
                        .x(cvt_op1_q), .res(i2f_d_res), .flags(i2f_d_flags));
    karu_fcvt_sd u_cvt_sd (.rm(cvt_rm_q), .a(cvt_op1_q),
                           .res(cvt_sd_res), .flags(cvt_sd_flags));
    karu_fcvt_ds u_cvt_ds (.a(cf_op1q),
                           .res(cvt_ds_res), .flags(cvt_ds_flags));

    //  Zfhmin D-side converters (need D).
    //  fcvt.d.h = H->S->D, both stages exact (single composition, no double
    //  rounding); flags come from stage 1 (hs quiets sNaN -> NV).
    wire [63:0] hd_res;
    karu_fcvt_ds u_cvt_hd (.a(hs_res), .res(hd_res), .flags());
    //  fcvt.h.d = D->H direct (single rounding).
    wire [15:0] dh_res; wire [4:0] dh_flags;
    karu_fcvt_dh u_cvt_dh (.rm(cvt_rm_q), .a(cvt_op1_q), .res(dh_res), .flags(dh_flags));

    //  Zfa fround.d / froundnx.d: compose f2i_d (int64) -> i2f_d; int64 always
    //  holds the integer because the compose path is only taken for E<52.
    wire [63:0] frd_f2i_res; wire [4:0] frd_f2i_fl;
    karu_f2i_d u_fr_f2i_d (.rm(cvt_rm_q), .is_long(1'b1), .is_unsigned(1'b0),
                           .a(cvt_op1_q), .res(frd_f2i_res), .flags(frd_f2i_fl));
    wire [63:0] frd_i2f_res;
    karu_i2f_d u_fr_i2f_d (.rm(cvt_rm_q), .is_long(1'b1), .is_unsigned(1'b0),
                           .x(frd_f2i_res), .res(frd_i2f_res), .flags());
    wire        frd_sign = cvt_op1_q[63];
    wire [10:0] frd_e    = cvt_op1_q[62:52];
    wire        frd_nan  = (frd_e == 11'h7FF) && (cvt_op1_q[51:0] != 52'h0);
    wire        frd_snan = frd_nan && !cvt_op1_q[51];
    wire        frd_zero = (frd_e == 11'h0)   && (cvt_op1_q[51:0] == 52'h0);
    wire signed [12:0] frd_E = $signed({2'b0, frd_e}) - 13'sd1023;
    wire        frd_intq = (frd_E >= 13'sd52);
    wire        frd_compose0 = (frd_f2i_res == 64'h0);
    wire [63:0] fround_d_res =
        frd_nan  ? `FP_D_QNAN :
        frd_zero ? cvt_op1_q :
        frd_intq ? cvt_op1_q :
        frd_compose0 ? {frd_sign, 63'b0} : frd_i2f_res;
    wire        fround_d_nx = !frd_nan && !frd_zero && !frd_intq && frd_f2i_fl[`FF_NX];
    wire        frd_snan_w = frd_snan;

    //  fcvtmod.w.d (D -> int32 mod 2^32, rtz). Writes the integer regfile.
    wire [63:0] fcvtmod_res; wire [4:0] fcvtmod_flags;
    karu_fcvtmod_wd u_fcvtmod (.a(cvt_op1_q), .res(fcvtmod_res), .flags(fcvtmod_flags));
`else
    //  D disabled: no double-precision combinational units. The decoder
    //  traps every D op so is_d is permanently 0 and these never feed an
    //  output; tie them off so the is_d? muxes below pick the S path.
    wire [63:0] sgnj_res_d = 64'b0;
    wire [63:0] mm_res_d = 64'b0;   wire [4:0] mm_flags_d  = 5'b0;
    wire [63:0] cmp_res_d = 64'b0;  wire [4:0] cmp_flags_d = 5'b0;
    wire [63:0] cls_res_d = 64'b0;
    wire [63:0] mvxd_res = 64'b0;   wire [63:0] mvdx_res = 64'b0;
    wire [63:0] f2i_d_res = 64'b0;  wire [4:0] f2i_d_flags = 5'b0;
    wire [63:0] i2f_d_res = 64'b0;  wire [4:0] i2f_d_flags = 5'b0;
    wire [31:0] cvt_sd_res = 32'b0; wire [4:0] cvt_sd_flags = 5'b0;
    wire [63:0] cvt_ds_res = 64'b0; wire [4:0] cvt_ds_flags = 5'b0;
    //  D disabled: fcvt.d.h / fcvt.h.d are trapped in decode, so these are dead.
    wire [63:0] hd_res = 64'b0;
    wire [15:0] dh_res = 16'b0;     wire [4:0] dh_flags = 5'b0;
    //  D disabled: fround.d / fcvtmod.w.d (D ops) are trapped in decode.
    wire [63:0] fround_d_res = 64'b0;   wire fround_d_nx = 1'b0; wire frd_snan_w = 1'b0;
    wire [63:0] fcvtmod_res = 64'b0;    wire [4:0] fcvtmod_flags = 5'b0;
`endif

    //  ==================================================================
    //  Multi-cycle F sub-units
    //  ==================================================================
    reg         s_mul_req, s_add_req, s_div_req, s_sqrt_req;
    reg         s_add_is_sub;
    reg [31:0]  s_mul_a, s_mul_b, s_add_a, s_add_b;

    wire        s_mul_done, s_add_done, s_div_done, s_sqrt_done;
    wire [31:0] s_mul_res, s_add_res, s_div_res, s_sqrt_res;
    wire [4:0]  s_mul_flags, s_add_flags, s_div_flags, s_sqrt_flags;

    karu_fmul u_fmul (.clk(clk), .rst(rst),
        .req(s_mul_req), .busy(),
        .rm(rm), .a(s_mul_a), .b(s_mul_b),
        .done(s_mul_done), .res(s_mul_res), .flags(s_mul_flags), .latency());

    karu_fadd u_fadd (.clk(clk), .rst(rst),
        .req(s_add_req), .busy(), .is_sub(s_add_is_sub),
        .rm(rm), .a(s_add_a), .b(s_add_b),
        .done(s_add_done), .res(s_add_res), .flags(s_add_flags), .latency());

    karu_fdiv u_fdiv (.clk(clk), .rst(rst),
        .req(s_div_req), .busy(),
        .rm(rm), .a(f_op1), .b(f_op2),
        .done(s_div_done), .res(s_div_res), .flags(s_div_flags), .latency());

    karu_fsqrt u_fsqrt (.clk(clk), .rst(rst),
        .req(s_sqrt_req), .busy(),
        .rm(rm), .a(f_op1),
        .done(s_sqrt_done), .res(s_sqrt_res), .flags(s_sqrt_flags), .latency());

    //  Fused multiply-add (single rounding). np = negate product, nc =
    //  negate addend: fmadd 00, fmsub 01, fnmsub 10, fnmadd 11.
    wire        fma_np = (sub == `FOP_NMSUB) || (sub == `FOP_NMADD);
    wire        fma_nc = (sub == `FOP_MSUB)  || (sub == `FOP_NMADD);
    reg         s_fma_req;
    wire        s_fma_done; wire [31:0] s_fma_res; wire [4:0] s_fma_flags;
    karu_ffma u_ffma (.clk(clk), .rst(rst), .req(s_fma_req), .busy(),
        .rm(rm), .neg_prod(fma_np), .neg_c(fma_nc),
        .a(f_op1), .b(f_op2), .c(f_op3),
        .done(s_fma_done), .res(s_fma_res), .flags(s_fma_flags), .latency());

    //  D-FMA req is driven by the dispatcher FSM; keep the reg even when D
    //  is compiled out (the FSM still references it under a dead is_d path).
    reg         d_fma_req;

    //  ==================================================================
    //  Multi-cycle D sub-units
    //  ==================================================================
    reg         d_mul_req, d_add_req, d_div_req, d_sqrt_req;

    //  Debug/assertion bus: the per-op dispatch strobes to the multi-cycle FP
    //  sub-units. The FPU is single-issue internally -- exactly one sub-unit is
    //  launched per op -- so at most one of these is high in any cycle. Exposed
    //  for karu_assert (hierarchical ref cpu.fpu.dbg_fpu_sub_req); the d_*_req
    //  regs exist even under KARU_NO_D, so this needs no `ifdef.
    //  (Declared after the d_*_req regs above so iverilog 14's strict
    //  use-before-declare check is satisfied; verilator/Vivado tolerate either.)
    wire [9:0]  dbg_fpu_sub_req = {s_mul_req, s_add_req, s_div_req, s_sqrt_req,
                                   s_fma_req, d_mul_req, d_add_req, d_div_req,
                                   d_sqrt_req, d_fma_req};
    reg         d_add_is_sub;
    reg [63:0]  d_mul_a, d_mul_b, d_add_a, d_add_b;

`ifdef KARU_EN_D
    wire        d_fma_done; wire [63:0] d_fma_res; wire [4:0] d_fma_flags;
    karu_ffma_d u_ffma_d (.clk(clk), .rst(rst), .req(d_fma_req), .busy(),
        .rm(rm), .neg_prod(fma_np), .neg_c(fma_nc),
        .a(d_op1), .b(d_op2), .c(d_op3),
        .done(d_fma_done), .res(d_fma_res), .flags(d_fma_flags), .latency());

    wire        d_mul_done, d_add_done, d_div_done, d_sqrt_done;
    wire [63:0] d_mul_res, d_add_res, d_div_res, d_sqrt_res;
    wire [4:0]  d_mul_flags, d_add_flags, d_div_flags, d_sqrt_flags;

    karu_fmul_d u_fmul_d (.clk(clk), .rst(rst),
        .req(d_mul_req), .busy(),
        .rm(rm), .a(d_mul_a), .b(d_mul_b),
        .done(d_mul_done), .res(d_mul_res), .flags(d_mul_flags), .latency());

    karu_fadd_d u_fadd_d (.clk(clk), .rst(rst),
        .req(d_add_req), .busy(), .is_sub(d_add_is_sub),
        .rm(rm), .a(d_add_a), .b(d_add_b),
        .done(d_add_done), .res(d_add_res), .flags(d_add_flags), .latency());

    karu_fdiv_d u_fdiv_d (.clk(clk), .rst(rst),
        .req(d_div_req), .busy(),
        .rm(rm), .a(d_op1), .b(d_op2),
        .done(d_div_done), .res(d_div_res), .flags(d_div_flags), .latency());

    karu_fsqrt_d u_fsqrt_d (.clk(clk), .rst(rst),
        .req(d_sqrt_req), .busy(),
        .rm(rm), .a(d_op1),
        .done(d_sqrt_done), .res(d_sqrt_res), .flags(d_sqrt_flags), .latency());
`else
    //  D disabled: no multi-cycle double units. is_d/is_d_q are always 0,
    //  so the FSM never asserts d_*_req and the is_d_q? muxes pick the S
    //  path; these done/res/flags just need defined (constant) values.
    wire        d_fma_done = 1'b0; wire [63:0] d_fma_res = 64'b0; wire [4:0] d_fma_flags = 5'b0;
    wire        d_mul_done = 1'b0, d_add_done = 1'b0, d_div_done = 1'b0, d_sqrt_done = 1'b0;
    wire [63:0] d_mul_res = 64'b0, d_add_res = 64'b0, d_div_res = 64'b0, d_sqrt_res = 64'b0;
    wire [4:0]  d_mul_flags = 5'b0, d_add_flags = 5'b0, d_div_flags = 5'b0, d_sqrt_flags = 5'b0;
`endif

    //  ==================================================================
    //  Dispatcher state machine
    //  ==================================================================
    localparam ST_IDLE  = 3'd0;
    localparam ST_WAIT  = 3'd1;
    localparam ST_CVT   = 3'd2;     //  2nd cycle of the registered-operand conversion

    reg [2:0]   state;
    reg         is_d_q;             //  latched is_d for the in-flight op
    reg         result_is_x;

    assign busy = (state != ST_IDLE);

    //  combinational pre-result for immediate-finish ops
    reg [63:0]  imm_res;
    reg [4:0]   imm_flags;
    reg         imm_is_x;
    always @(*) begin
        imm_res    = 64'b0;
        imm_flags  = 5'b0;
        imm_is_x   = 1'b0;
        if (is_sgnj_fam) begin
            if (is_d) imm_res = sgnj_res_d;
            else      imm_res = {32'hFFFF_FFFF, sgnj_res_s};
        end else if (is_minmax) begin
            if (is_d) begin imm_res = mm_res_d; imm_flags = mm_flags_d; end
            else      begin imm_res = {32'hFFFF_FFFF, mm_res_s}; imm_flags = mm_flags_s; end
        end else if (is_cmp) begin
            if (is_d) begin imm_res = cmp_res_d; imm_flags = cmp_flags_d; end
            else      begin imm_res = cmp_res_s; imm_flags = cmp_flags_s; end
            imm_is_x = 1'b1;
        end else if (is_class) begin
            imm_res  = is_d ? cls_res_d : cls_res_s;
            imm_is_x = 1'b1;
        end else if (is_mvxw) begin
            //  fmv.x.h sign-extends the 16-bit value to XLEN (Zfhmin); the box
            //  is bypassed for raw bit moves, like fmv.x.w.
            imm_res  = is_h ? {{48{op1[15]}}, op1[15:0]}
                     : is_d ? mvxd_res : mvxw_res;
            imm_is_x = 1'b1;
        end else if (is_mvwx) begin
            //  fmv.h.x NaN-boxes the low 16 bits into the f-register.
            imm_res = is_h ? {`FP_H_NAN_BOX, op1[15:0]}
                    : is_d ? mvdx_res : mvwx_res;
        end else if (fp_zfa == `FPZ_FLI) begin
            //  fli: load architectural constant (index in op1[4:0]); writes f-reg.
            imm_res = is_d ? fli_d_val : {32'hFFFF_FFFF, fli_s_val};
        end
        //  int<->float and S<->D conversions are NOT here -- they take the
        //  2-cycle ST_CVT path (registered operand) for timing.
    end

    //  conversion result mux (ST_CVT), selected from the REGISTERED op type.
    //  FROM_H: dest S (is_d=0) NaN-boxed single, or D (is_d=1) raw 64.
    //  TO_H:   dest H always -> NaN-boxed half (upper 48 = 1s).
    //  Zfa cvt-path ops (registered in cvt_zfa_q): fround/froundnx/fcvtmod.
    wire        cvt_fround_q  = (cvt_zfa_q == `FPZ_FROUND) || (cvt_zfa_q == `FPZ_FROUNDNX);
    wire        cvt_fcvtmod_q = (cvt_zfa_q == `FPZ_FCVTMOD);
    wire        fround_snan = cvt_isd_q ? frd_snan_w : frs_snan;
    wire        fround_nx_v = cvt_isd_q ? fround_d_nx : fround_s_nx;
    wire [4:0]  fround_flags = (fround_snan ? (5'b1 << `FF_NV) : 5'b0)
                    | (((cvt_zfa_q == `FPZ_FROUNDNX) && fround_nx_v) ? (5'b1 << `FF_NX) : 5'b0);

    wire [63:0] cvt_res =
        cvt_f2i_q   ? (cvt_isd_q ? f2i_d_res : f2i_res) :
        cvt_i2f_q   ? (cvt_isd_q ? i2f_d_res : {32'hFFFF_FFFF, i2f_res}) :
        cvt_sd_q    ? {32'hFFFF_FFFF, cvt_sd_res} :
        cvt_ds_q    ? cvt_ds_res :
        cvt_fromh_q ? (cvt_isd_q ? hd_res : {32'hFFFF_FFFF, hs_res}) :
        cvt_toh_q   ? {`FP_H_NAN_BOX, (cvt_isd_q ? dh_res : sh_res)} :
        cvt_fround_q ? (cvt_isd_q ? fround_d_res : {32'hFFFF_FFFF, fround_s_res}) :
        cvt_fcvtmod_q ? fcvtmod_res :
                      64'b0;
    wire [4:0]  cvt_flags =
        cvt_f2i_q   ? (cvt_isd_q ? f2i_d_flags : f2i_flags) :
        cvt_i2f_q   ? (cvt_isd_q ? i2f_d_flags : i2f_flags) :
        cvt_sd_q    ? cvt_sd_flags :
        cvt_ds_q    ? cvt_ds_flags :
        cvt_fromh_q ? hs_flags :            //  hd compose: ds is exact on the quieted qNaN
        cvt_toh_q   ? (cvt_isd_q ? dh_flags : sh_flags) :
        cvt_fround_q ? fround_flags :
        cvt_fcvtmod_q ? fcvtmod_flags :
                      5'b0;
    wire        cvt_is_x = cvt_f2i_q || cvt_fcvtmod_q;  //  these target the integer regfile
    wire        zfa_cvt = (fp_zfa == `FPZ_FROUND) || (fp_zfa == `FPZ_FROUNDNX)
                       || (fp_zfa == `FPZ_FCVTMOD);
    wire        is_cvt = is_f2i || is_i2f || is_cvt_sd || is_cvt_ds
                 || is_cvt_from_h || is_cvt_to_h || zfa_cvt;

    wire is_immediate = is_sgnj_fam || is_minmax || is_cmp || is_class
                     || is_mvxw || is_mvwx || (fp_zfa == `FPZ_FLI);

    //  ===== sub-unit req strobes =====
    always @(*) begin
        s_mul_req    = 1'b0;    d_mul_req    = 1'b0;
        s_add_req    = 1'b0;    d_add_req    = 1'b0;
        s_div_req    = 1'b0;    d_div_req    = 1'b0;
        s_sqrt_req   = 1'b0;    d_sqrt_req   = 1'b0;
        s_fma_req    = 1'b0;    d_fma_req    = 1'b0;
        s_add_is_sub = 1'b0;    d_add_is_sub = 1'b0;
        s_mul_a      = f_op1;   s_mul_b      = f_op2;
        s_add_a      = f_op1;   s_add_b      = f_op2;
        d_mul_a      = d_op1;   d_mul_b      = d_op2;
        d_add_a      = d_op1;   d_add_b      = d_op2;
        case (state)
            ST_IDLE: if (req) begin
                if (is_add) begin
                    if (is_d) begin d_add_req = 1'b1; d_add_is_sub = is_sub; end
                    else      begin s_add_req = 1'b1; s_add_is_sub = is_sub; end
                end else if (is_mul) begin
                    if (is_d) d_mul_req = 1'b1; else s_mul_req = 1'b1;
                end else if (is_div) begin
                    if (is_d) d_div_req = 1'b1; else s_div_req = 1'b1;
                end else if (is_sqrt) begin
                    if (is_d) d_sqrt_req = 1'b1; else s_sqrt_req = 1'b1;
                end else if (is_fma) begin
                    if (is_d) d_fma_req = 1'b1; //  fused single-rounding
                    else      s_fma_req = 1'b1;
                end
            end
        endcase
    end

    //  ===== sequential state =====
    always @(posedge clk) begin
        if (rst) begin
            state  <= ST_IDLE;
            done   <= 1'b0;
            res    <= 64'b0;
            fflags <= 5'b0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: if (req) begin
                    result_is_x <= imm_is_x;
                    is_d_q      <= is_d;
                    if (is_immediate) begin
                        res    <= imm_res;
                        fflags <= imm_flags;
                        done   <= 1'b1;
                    end else if (is_cvt) begin
                        //  register the operand + op type; convert in ST_CVT
                        cvt_op1_q      <= op1;
                        cvt_rm_q       <= rm;
                        cvt_long_q     <= cvt_long;
                        cvt_unsigned_q <= cvt_unsigned;
                        cvt_f2i_q      <= is_f2i;
                        cvt_i2f_q      <= is_i2f;
                        cvt_sd_q       <= is_cvt_sd;
                        cvt_ds_q       <= is_cvt_ds;
                        cvt_fromh_q    <= is_cvt_from_h;
                        cvt_toh_q      <= is_cvt_to_h;
                        cvt_zfa_q      <= zfa_cvt ? fp_zfa : `FPZ_NONE;
                        cvt_isd_q      <= is_d;
                        state <= ST_CVT;
                    end else if (is_add || is_mul || is_div || is_sqrt) begin
                        state <= ST_WAIT;
                    end else if (is_fma) begin
                        state <= ST_WAIT;   //  F and D both fused (single rounding)
                    end
                end
                ST_CVT: begin
                    res         <= cvt_res;
                    fflags      <= cvt_flags;
                    result_is_x <= cvt_is_x;
                    done        <= 1'b1;
                    state       <= ST_IDLE;
                end
                ST_WAIT: begin
                    if (s_mul_done || s_add_done || s_div_done || s_sqrt_done || s_fma_done) begin
                        res    <= s_mul_done  ? {32'hFFFF_FFFF, s_mul_res}  :
                                  s_add_done  ? {32'hFFFF_FFFF, s_add_res}  :
                                  s_div_done  ? {32'hFFFF_FFFF, s_div_res}  :
                                  s_sqrt_done ? {32'hFFFF_FFFF, s_sqrt_res} :
                                                {32'hFFFF_FFFF, s_fma_res};
                        fflags <= s_mul_done  ? s_mul_flags :
                                  s_add_done  ? s_add_flags :
                                  s_div_done  ? s_div_flags :
                                  s_sqrt_done ? s_sqrt_flags :
                                                s_fma_flags;
                        done   <= 1'b1;
                        state  <= ST_IDLE;
                    end else if (d_mul_done || d_add_done || d_div_done || d_sqrt_done || d_fma_done) begin
                        res    <= d_mul_done  ? d_mul_res  :
                                  d_add_done  ? d_add_res  :
                                  d_div_done  ? d_div_res  :
                                  d_sqrt_done ? d_sqrt_res  :
                                                d_fma_res;
                        fflags <= d_mul_done  ? d_mul_flags :
                                  d_add_done  ? d_add_flags :
                                  d_div_done  ? d_div_flags :
                                  d_sqrt_done ? d_sqrt_flags :
                                                d_fma_flags;
                        done   <= 1'b1;
                        state  <= ST_IDLE;
                    end
                end
            endcase
        end
    end

    wire _unused = &{result_is_x, 1'b0};

// synthesis translate_off
    //  #4 (FPU single-issue): sub-unit req strobes fire ONLY in the dispatch cycle
    //  (ST_IDLE). While an op is in flight -- notably the fused serial FMA, which
    //  parks in ST_WAIT for 4/53+ cycles -- no second sub-unit req may strobe, or
    //  the in-flight result would be lost. (karu_assert separately checks
    //  at-most-one req/cycle via the fpu_sub_req one-hot; this checks WHEN.)
    always @(posedge clk) if (!rst) begin
        if (|dbg_fpu_sub_req && !(state == ST_IDLE))
            begin $display("[FPU-ASSERT] sub-unit req while op in flight (state=%0d) @%0t", state, $time); $finish; end
    end
// synthesis translate_on
endmodule
