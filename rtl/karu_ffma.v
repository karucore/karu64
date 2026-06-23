//  karu_ffma.v
//  IEEE 754 binary32 *fused* multiply-add: rd = (-1)^np*(a*b) +/- c with a
//  SINGLE rounding (no intermediate rounding of the product). Covers all
//  four RISC-V ops via two control bits:
//    fmadd  : np=0 nc=0     ( a*b + c)
//    fmsub  : np=0 nc=1     ( a*b - c)
//    fnmsub : np=1 nc=0     (-a*b + c)
//    fnmadd : np=1 nc=1     (-a*b - c)
//
//  Direct port of Berkeley SoftFloat-3e softfloat_mulAddF32 +
//  softfloat_roundPackToF32 (the exact reference TestFloat checks against).
//
//  Split into a 4-stage multi-cycle pipeline (one op in flight; the core is
//  single-issue and gates on busy/done) so no single cycle carries the
//  24x24 multiply + 64-bit align/add + normalize + roundpack in series.
//  Every expression is preserved verbatim; only registered cut points are
//  inserted, so results are bit-identical to the old combinational form.
//  Stages: S1 unpack+multiply | S2 prod-normalize+align+add/sub |
//          S3 sub-normalize+pick | S4 roundPackToF32.

`include "karu_fpkg.vh"
`include "karu_cfg.vh"

module karu_ffma (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,
    input  wire         neg_prod,
    input  wire         neg_c,
    input  wire [31:0]  a,
    input  wire [31:0]  b,
    input  wire [31:0]  c,

    output reg          done,
    output reg [31:0]   res,
    output reg  [4:0]   flags,
    output wire [4:0]   latency
);
    //  Mantissa-multiply cycle count: KARU_F_FMA_CYCLES (defaults to the standalone
    //  KARU_F_MUL_CYCLES). 1 = combinational 24x24 (DSP, behaviour UNCHANGED);
    //  >1 = radix-2^K serial 24x24 shift-add (K=24/N), N extra cycles, no full
    //  multiplier array (K=1 at N=24 => DSP-free). Same valid set / clamp as fmul.
    localparam F_REQ = `KARU_F_FMA_CYCLES;
    localparam F_FMA_CYCLES =
        (F_REQ == 1)  ? 1  :
        (F_REQ == 2)  ? 2  :
        (F_REQ == 3)  ? 3  :
        (F_REQ == 4)  ? 4  :
        (F_REQ <= 6)  ? 6  :
        (F_REQ <= 8)  ? 8  :
        (F_REQ <= 12) ? 12 : 24;
    localparam F_FMA_K = (F_FMA_CYCLES == 1) ? 24 : (24 / F_FMA_CYCLES);
    //  serial path adds N SMUL cycles (combinational SMUL is 1 cycle).
    assign latency = 5'd6 + (F_FMA_CYCLES == 1 ? 5'd0 : F_FMA_CYCLES[4:0]);

    function [6:0] clz32;
        input [31:0] v; integer i; reg fnd;
        begin clz32 = 7'd32; fnd = 1'b0;
            for (i = 31; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz32 = 7'd31 - i[6:0]; fnd = 1'b1; end
        end
    endfunction
    function [6:0] clz64;
        input [63:0] v; integer i; reg fnd;
        begin clz64 = 7'd64; fnd = 1'b0;
            for (i = 63; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz64 = 7'd63 - i[6:0]; fnd = 1'b1; end
        end
    endfunction
    function [63:0] srj64;
        input [63:0] av; input [31:0] shamt;
        begin
            if (shamt >= 32'd63)      srj64 = {63'b0, (|av)};
            else if (shamt == 32'd0)  srj64 = av;
            else srj64 = (av >> shamt) | {63'b0, (|(av & ((64'b1 << shamt) - 64'b1)))};
        end
    endfunction
    function [31:0] srj32;
        input [31:0] av; input [31:0] shamt;
        begin
            if (shamt >= 32'd31)      srj32 = {31'b0, (|av)};
            else if (shamt == 32'd0)  srj32 = av;
            else srj32 = (av >> shamt) | {31'b0, (|(av & ((32'b1 << shamt) - 32'b1)))};
        end
    endfunction

    localparam S_IDLE = 3'd0, SMUL = 3'd1, ST2 = 3'd2, ST3 = 3'd3, ST4 = 3'd4;
    reg [2:0]   st;
    assign busy = (st != S_IDLE);

    // ================================================================
    // STAGE 1 (issue-cycle inputs): unpack + 24x24 multiply
    // ================================================================
    wire        signA = a[31];  wire [7:0] expA_r = a[30:23];  wire [22:0] sigA_r = a[22:0];
    wire        signB = b[31];  wire [7:0] expB_r = b[30:23];  wire [22:0] sigB_r = b[22:0];
    wire        signC = c[31] ^ neg_c;
    wire [7:0]  expC_r = c[30:23];  wire [22:0] sigC_r = c[22:0];
    wire        signProd = signA ^ signB ^ neg_prod;

    wire a_is_nan = (expA_r == 8'hFF) && (sigA_r != 0);
    wire b_is_nan = (expB_r == 8'hFF) && (sigB_r != 0);
    wire c_is_nan = (expC_r == 8'hFF) && (sigC_r != 0);
    wire a_snan = a_is_nan && !sigA_r[22];
    wire b_snan = b_is_nan && !sigB_r[22];
    wire c_snan = c_is_nan && !sigC_r[22];
    wire a_inf = (expA_r == 8'hFF) && (sigA_r == 0);
    wire b_inf = (expB_r == 8'hFF) && (sigB_r == 0);
    wire c_inf = (expC_r == 8'hFF) && (sigC_r == 0);

    wire        a_sub = (expA_r == 0) && (sigA_r != 0);
    wire        b_sub = (expB_r == 0) && (sigB_r != 0);
    wire        c_sub = (expC_r == 0) && (sigC_r != 0);
    wire [6:0]  a_sd = clz32({9'b0, sigA_r}) - 7'd8;
    wire [6:0]  b_sd = clz32({9'b0, sigB_r}) - 7'd8;
    wire [6:0]  c_sd = clz32({9'b0, sigC_r}) - 7'd8;
    wire signed [15:0] expA = a_sub ? (16'sd1 - {{9{1'b0}}, a_sd}) : $signed({8'b0, expA_r});
    wire signed [15:0] expB = b_sub ? (16'sd1 - {{9{1'b0}}, b_sd}) : $signed({8'b0, expB_r});
    wire signed [15:0] expC = c_sub ? (16'sd1 - {{9{1'b0}}, c_sd}) : $signed({8'b0, expC_r});
    wire [22:0] sigA_n = a_sub ? (sigA_r << a_sd) : sigA_r;
    wire [22:0] sigB_n = b_sub ? (sigB_r << b_sd) : sigB_r;
    wire [22:0] sigC_n = c_sub ? (sigC_r << c_sd) : sigC_r;

    wire a_is_zero = (expA_r == 0) && (sigA_r == 0);
    wire b_is_zero = (expB_r == 0) && (sigB_r == 0);
    wire c_is_zero = (expC_r == 0) && (sigC_r == 0);

    wire any_snan = a_snan || b_snan || c_snan;
    wire any_input_nan = a_is_nan || b_is_nan || c_is_nan;
    wire prodInf_argInf = a_inf || b_inf;
    wire prod_inf_times_zero = (a_inf && b_is_zero) || (b_inf && a_is_zero);
    wire prod_is_inf = prodInf_argInf && !prod_inf_times_zero && !a_is_nan && !b_is_nan;
    wire inf_minus_inf = prod_is_inf && c_inf && (signProd != signC);
    wire nv = any_snan || prod_inf_times_zero || inf_minus_inf;
    wire special_active = any_input_nan || prod_inf_times_zero || prod_is_inf || c_inf;
    wire [31:0] special_res =
        (any_input_nan || prod_inf_times_zero || inf_minus_inf) ? `FP_S_QNAN :
        prod_is_inf ? {signProd, 8'hFF, 23'h0} :
        c_inf       ? {signC, 8'hFF, 23'h0} :
                      32'b0;
    wire [4:0] special_flags = nv ? (5'b1 << `FF_NV) : 5'b0;

    wire zero_prod   = a_is_zero || b_is_zero;
    wire cancel_zero = c_is_zero && (signProd != signC);
    wire [31:0] zeroprod_res =
        cancel_zero ? {(rm == `FRM_RDN), 31'b0} : {signC, c[30:0]};

    wire signed [15:0] expProd0 = expA + expB - 16'sd126;
    wire [30:0] sigA31 = {1'b1, sigA_n, 7'b0};
    wire [30:0] sigB31 = {1'b1, sigB_n, 7'b0};

    //  stage-0 registers (unpack/normalize). Multiply operands registered so
    //  the 24x24 DSP gets registered inputs (its own cycle), keeping the
    //  front-end out of series with the multiply.
    reg [30:0]          s0_sigA31, s0_sigB31;
    reg signed [15:0]   s0_expProd0, s0_expC;
    reg                 s0_signProd, s0_signC, s0_c_is_zero;
    reg [22:0]          s0_sigC_n;
    reg                 s0_special_active, s0_zero_prod;
    reg [31:0]          s0_special_res, s0_zeroprod_res;
    reg [4:0]           s0_special_flags;
    reg [2:0]           s0_rm;
    wire [63:0] s1_sigProd0_w = {33'b0, s0_sigA31} * {33'b0, s0_sigB31};

    reg [63:0]          s1_sigProd0;
    reg signed [15:0]   s1_expProd0, s1_expC;
    reg                 s1_signProd, s1_signC, s1_c_is_zero;
    reg [22:0]          s1_sigC_n;
    reg                 s1_special_active, s1_zero_prod;
    reg [31:0]          s1_special_res, s1_zeroprod_res;
    reg [4:0]           s1_special_flags;
    reg [2:0]           s1_rm;

    // ================================================================
    // STAGE 2 (from s1): prod-normalize + align + add + sub (raw)
    // ================================================================
    wire        prod_lt = (s1_sigProd0 < 64'h2000_0000_0000_0000);
    wire signed [15:0] expProd = prod_lt ? (s1_expProd0 - 16'sd1) : s1_expProd0;
    wire [63:0] sigProd = prod_lt ? (s1_sigProd0 << 1) : s1_sigProd0;

    wire [31:0] sigC30 = {2'b0, 1'b1, s1_sigC_n, 6'b0};
    wire [63:0] sig64C = {sigC30, 32'b0};

    wire signed [15:0] expDiff   = expProd - s1_expC;
    wire signed [31:0] expDiff32 = expDiff;
    wire same_sign = (s1_signProd == s1_signC);

    wire [31:0] d_add_le = 32'd32 - expDiff32;
    wire [31:0] d_add_gt = expDiff32;
    wire [31:0] d_sub_lt = -expDiff32;
    wire [31:0] d_sub_gt = expDiff32;

    wire [63:0] srj_add_le  = srj64(sigProd, d_add_le);
    wire [31:0] add_sigZ_le = sigC30 + srj_add_le[31:0];
    wire [63:0] srj_add_gt  = srj64(sig64C, d_add_gt);
    wire [63:0] add_sig64_gt = sigProd + srj_add_gt;
    wire [63:0] srj_add_gt2 = srj64(add_sig64_gt, 32'd32);
    wire [31:0] add_sigZ_gt = srj_add_gt2[31:0];
    wire        add_le = (expDiff <= 0);
    wire signed [15:0] add_expZ0 = add_le ? s1_expC : expProd;
    wire [31:0] add_sigZ0 = add_le ? add_sigZ_le : add_sigZ_gt;
    wire        add_norm = (add_sigZ0 < 32'h4000_0000);
    wire signed [15:0] add_expZ = add_norm ? (add_expZ0 - 16'sd1) : add_expZ0;
    wire [31:0] add_sigZ = add_norm ? (add_sigZ0 << 1) : add_sigZ0;

    wire [63:0] srj_sub_lt  = srj64(sigProd, d_sub_lt);
    wire [63:0] sub_sig64_lt = sig64C - srj_sub_lt;
    wire [63:0] sub_sig64_eq = sigProd - sig64C;
    wire [63:0] srj_sub_gt  = srj64(sig64C, d_sub_gt);
    wire [63:0] sub_sig64_gt = sigProd - srj_sub_gt;
    wire        sub_eq_zero = (expDiff == 0) && (sub_sig64_eq == 64'b0);
    wire        eq_neg = (expDiff == 0) && sub_sig64_eq[63];
    wire [63:0] sub_sig64 =
        (expDiff < 0)  ? sub_sig64_lt :
        (expDiff == 0) ? (eq_neg ? (~sub_sig64_eq + 64'b1) : sub_sig64_eq) :
                         sub_sig64_gt;
    wire        sub_signZ =
        (expDiff < 0)  ? s1_signC :
        (expDiff == 0) ? (eq_neg ? !s1_signProd : s1_signProd) :
                         s1_signProd;
    wire signed [15:0] sub_expZ_base = (expDiff < 0) ? s1_expC : expProd;

    wire        use_czero = s1_c_is_zero;
    wire [63:0] srj_cz = srj64(sigProd, 32'd31);

    reg [31:0]          s2_add_sigZ;
    reg signed [15:0]   s2_add_expZ, s2_sub_expZ_base, s2_cz_exp;
    reg [63:0]          s2_sub_sig64;
    reg                 s2_sub_signZ, s2_sub_eq_zero, s2_use_czero, s2_same_sign, s2_signProd;
    reg [31:0]          s2_cz_sig;
    reg                 s2_special_active, s2_zero_prod;
    reg [31:0]          s2_special_res, s2_zeroprod_res;
    reg [4:0]           s2_special_flags;
    reg [2:0]           s2_rm;

    // ================================================================
    // STAGE 3 (from s2): sub-normalize (CLZ + shift) + pick rp_*
    // ================================================================
    wire [6:0]  sub_clz = clz64(s2_sub_sig64);
    wire signed [15:0] sub_shiftDist = {{9{1'b0}}, sub_clz} - 16'sd1;
    wire signed [15:0] sub_expZ = s2_sub_expZ_base - sub_shiftDist;
    wire signed [15:0] sub_sh2 = sub_shiftDist - 16'sd32;
    wire [31:0] neg_sub_sh2 = -{{16{sub_sh2[15]}}, sub_sh2};
    wire [63:0] srj_sub2 = srj64(s2_sub_sig64, neg_sub_sh2);
    wire [63:0] sub_sig64_l = s2_sub_sig64 << sub_sh2[5:0];
    wire [31:0] sub_sigZ = (sub_sh2 < 0) ? srj_sub2[31:0] : sub_sig64_l[31:0];

    wire        rp_sign_w = s2_use_czero ? s2_signProd : (s2_same_sign ? s2_signProd : s2_sub_signZ);
    wire signed [15:0] rp_exp_w = s2_use_czero ? s2_cz_exp
                              : (s2_same_sign ? s2_add_expZ : sub_expZ);
    wire [31:0] rp_sig_w = s2_use_czero ? s2_cz_sig
                       : (s2_same_sign ? s2_add_sigZ : sub_sigZ);
    wire        complete_cancel_w = !s2_special_active && !s2_zero_prod && !s2_use_czero
                                  && !s2_same_sign && s2_sub_eq_zero;

    reg                 s3_rp_sign, s3_complete_cancel;
    reg signed [15:0]   s3_rp_exp;
    reg [31:0]          s3_rp_sig;
    reg                 s3_special_active, s3_zero_prod;
    reg [31:0]          s3_special_res, s3_zeroprod_res;
    reg [4:0]           s3_special_flags;
    reg [2:0]           s3_rm;

    // ================================================================
    // STAGE 4 (from s3): roundPackToF32
    // ================================================================
    wire roundNearEven = (s3_rm == `FRM_RNE);
    wire roundNearMax  = (s3_rm == `FRM_RMM);
    wire [7:0] roundIncrement =
        (roundNearEven || roundNearMax) ? 8'h40 :
        ((s3_rm == (s3_rp_sign ? `FRM_RDN : `FRM_RUP)) ? 8'h7F : 8'h00);

    wire enter_block = (s3_rp_exp < 0) || (s3_rp_exp >= 16'sd253);
    wire subn = enter_block && (s3_rp_exp < 0);
    wire [31:0] srj_amt = -{{16{s3_rp_exp[15]}}, s3_rp_exp};
    wire [31:0] sub_sig_sh = srj32(s3_rp_sig, srj_amt);
    wire [31:0] eff_sig = subn ? sub_sig_sh : s3_rp_sig;
    wire signed [15:0] eff_exp = subn ? 16'sd0 : s3_rp_exp;
    wire [6:0] roundBits = eff_sig[6:0];

    wire [32:0] sig_plus_inc = {1'b0, s3_rp_sig} + {25'b0, roundIncrement};
    wire isTiny = subn && ((s3_rp_exp < -16'sd1) || (sig_plus_inc < 33'h0_8000_0000));
    wire overflow = enter_block && !subn
                 && ((s3_rp_exp > 16'sd253) || (sig_plus_inc >= 33'h0_8000_0000));

    wire [32:0] sig_rnd = ({1'b0, eff_sig} + {25'b0, roundIncrement}) >> 7;
    wire        tie_even = (roundBits == 7'h40) && roundNearEven;
    wire [31:0] sig_final0 = sig_rnd[31:0] & ~(tie_even ? 32'b1 : 32'b0);
    wire [31:0] exp_for_pack = (sig_final0 == 0) ? 32'b0 : {16'b0, eff_exp};
    wire [31:0] rp_packed = {s3_rp_sign, 31'b0} + (exp_for_pack << 23) + sig_final0;

    wire        rp_inexact = |roundBits;
    wire        rp_uf      = isTiny && (|roundBits);
    wire [31:0] over_res   = {s3_rp_sign, 8'hFF, 23'h0} - ((roundIncrement == 0) ? 32'b1 : 32'b0);

    wire [31:0] roundpack_res = overflow ? over_res : rp_packed;
    wire [4:0]  roundpack_flags =
        overflow ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) :
        ((rp_uf ? (5'b1 << `FF_UF) : 5'b0) | (rp_inexact ? (5'b1 << `FF_NX) : 5'b0));

    wire [31:0] res_w =
        s3_special_active  ? s3_special_res :
        s3_zero_prod       ? s3_zeroprod_res :
        s3_complete_cancel ? {(s3_rm == `FRM_RDN), 31'b0} :
                             roundpack_res;
    wire [4:0]  flags_w =
        s3_special_active  ? s3_special_flags :
        (s3_zero_prod || s3_complete_cancel) ? 5'b0 :
                             roundpack_flags;

    // ================================================================
    // Mantissa multiply: combinational (==1) or radix-2^K serial (>1).
    // sigA31*sigB31 == (sigA24*sigB24)<<14, so the serial path runs the proven
    // fmul 24x24->48 recurrence on the 24-bit significands then shifts <<14 --
    // the latched s1_sigProd0 is bit-identical to the combinational product.
    // ================================================================
    wire [23:0] sigA24 = sigA31[30:7];      //  {1'b1, sigA_n} (combinational at req)
    wire [23:0] sigB24 = sigB31[30:7];
    wire        mul_done;
    wire [63:0] mul_prod;
    //  FSM state encodings hoisted to module scope -- Genus rejects localparam
    //  declarations inside generate blocks; used by the g_fma_iter always below.
    localparam SS_IDLE = 2'd0, SS_RUN = 2'd1, SS_FIN = 2'd2;
    generate
    if (F_FMA_CYCLES == 1) begin : g_fma_comb
        assign mul_done = 1'b1;
        assign mul_prod = s1_sigProd0_w;    //  combinational 24x24 (DSP)
    end else begin : g_fma_iter
        reg [1:0]  sstate;
        reg [4:0]  scnt;
        reg [47:0] sacc;
        reg [23:0] sma;
        wire [F_FMA_K+23:0] smul_partial = sma * sacc[F_FMA_K-1:0];
        wire [F_FMA_K+23:0] smul_sum     = sacc[47:24] + smul_partial;
        wire [47:0]         smul_next    = { smul_sum, sacc[23:F_FMA_K] };
        always @(posedge clk) begin
            if (rst) sstate <= SS_IDLE;
            else case (sstate)
                SS_IDLE: if (st == S_IDLE && req) begin //  load from live operands at req
                    sma    <= sigA24;
                    sacc   <= {24'b0, sigB24};
                    scnt   <= F_FMA_CYCLES[4:0];
                    sstate <= SS_RUN;
                end
                SS_RUN: begin
                    sacc <= smul_next;
                    scnt <= scnt - 5'd1;
                    if (scnt == 5'd1) sstate <= SS_FIN;
                end
                SS_FIN: sstate <= SS_IDLE;
                default: sstate <= SS_IDLE;
            endcase
        end
        assign mul_done = (sstate == SS_FIN);
        assign mul_prod = {2'b0, sacc, 14'b0};  //  (sigA24*sigB24) << 14
    end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            st   <= S_IDLE;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (req) begin
                    //  stage 0: unpack/normalize -> register multiply operands
                    s0_sigA31      <= sigA31;
                    s0_sigB31      <= sigB31;
                    s0_expProd0    <= expProd0;
                    s0_expC        <= expC;
                    s0_signProd    <= signProd;
                    s0_signC       <= signC;
                    s0_c_is_zero   <= c_is_zero;
                    s0_sigC_n      <= sigC_n;
                    s0_special_active <= special_active;
                    s0_special_res    <= special_res;
                    s0_special_flags  <= special_flags;
                    s0_zero_prod      <= zero_prod;
                    s0_zeroprod_res   <= zeroprod_res;
                    s0_rm          <= rm;
                    st <= SMUL;
                end
                SMUL: if (mul_done) begin
                    //  stage 1: the 24x24 product (combinational fast path or the
                    //  serial engine's result), latched when ready (busy held meanwhile)
                    s1_sigProd0    <= mul_prod;
                    s1_expProd0    <= s0_expProd0;
                    s1_expC        <= s0_expC;
                    s1_signProd    <= s0_signProd;
                    s1_signC       <= s0_signC;
                    s1_c_is_zero   <= s0_c_is_zero;
                    s1_sigC_n      <= s0_sigC_n;
                    s1_special_active <= s0_special_active;
                    s1_special_res    <= s0_special_res;
                    s1_special_flags  <= s0_special_flags;
                    s1_zero_prod      <= s0_zero_prod;
                    s1_zeroprod_res   <= s0_zeroprod_res;
                    s1_rm          <= s0_rm;
                    st <= ST2;
                end
                ST2: begin
                    s2_add_sigZ      <= add_sigZ;
                    s2_add_expZ      <= add_expZ;
                    s2_sub_sig64     <= sub_sig64;
                    s2_sub_signZ     <= sub_signZ;
                    s2_sub_eq_zero   <= sub_eq_zero;
                    s2_sub_expZ_base <= sub_expZ_base;
                    s2_use_czero     <= use_czero;
                    s2_same_sign     <= same_sign;
                    s2_signProd      <= s1_signProd;
                    s2_cz_exp        <= expProd - 16'sd1;
                    s2_cz_sig        <= srj_cz[31:0];
                    s2_special_active <= s1_special_active;
                    s2_special_res    <= s1_special_res;
                    s2_special_flags  <= s1_special_flags;
                    s2_zero_prod      <= s1_zero_prod;
                    s2_zeroprod_res   <= s1_zeroprod_res;
                    s2_rm        <= s1_rm;
                    st <= ST3;
                end
                ST3: begin
                    s3_rp_sign   <= rp_sign_w;
                    s3_rp_exp    <= rp_exp_w;
                    s3_rp_sig    <= rp_sig_w;
                    s3_complete_cancel <= complete_cancel_w;
                    s3_special_active  <= s2_special_active;
                    s3_special_res     <= s2_special_res;
                    s3_special_flags   <= s2_special_flags;
                    s3_zero_prod       <= s2_zero_prod;
                    s3_zeroprod_res    <= s2_zeroprod_res;
                    s3_rm        <= s2_rm;
                    st <= ST4;
                end
                ST4: begin
                    res   <= res_w;
                    flags <= flags_w;
                    done  <= 1'b1;
                    st    <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    wire _unused = &{c_sub, 1'b0};

// synthesis translate_off
    //  FMA handshake invariants (sim only). The serial mantissa-multiply mode
    //  (F_FMA_CYCLES>1) holds `busy` across many cycles, so police the
    //  req/busy/done contract explicitly. busy = (st != S_IDLE); done pulses the
    //  cycle busy returns to 0 (ST4 schedules done<=1, st<=S_IDLE).
    reg ffa_busy_q, ffa_done_q;
    always @(posedge clk) begin
        ffa_busy_q <= !rst && busy;
        ffa_done_q <= !rst && done;
    end
    always @(posedge clk) if (!rst) begin
        //  H1: req accepted only while idle (single op in flight; caller waits on busy).
        if (req && busy)
            begin $display("[FFMA-ASSERT] req while busy @%0t", $time); $finish; end
        //  H2: busy stays high until done -- it may only fall on the done cycle.
        if (ffa_busy_q && !busy && !done)
            begin $display("[FFMA-ASSERT] busy fell without done @%0t", $time); $finish; end
        //  H3: done is a one-cycle pulse.
        if (ffa_done_q && done)
            begin $display("[FFMA-ASSERT] done held >1 cycle @%0t", $time); $finish; end
    end
// synthesis translate_on
endmodule
