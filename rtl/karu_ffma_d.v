//  karu_ffma_d.v
//  IEEE 754 binary64 *fused* multiply-add, single rounding. D mirror of
//  karu_ffma, ported from SoftFloat-3e softfloat_mulAddF64 (the uint128
//  form) + softfloat_roundPackToF64. Covers all four RISC-V variants via
//  np (negate product) / nc (negate addend).
//
//  Datapath is the same combinational SoftFloat port as before, but split
//  into a 5-stage multi-cycle pipeline (one op in flight; the core is
//  single-issue and gates on busy/done) so no single cycle carries the
//  53x53 multiply + 128-bit align/add + normalize + roundpack in series
//  (that ~35 ns cone was the 125 MHz timing wall once the divider was fixed).
//  Every expression is preserved verbatim; only registered cut points are
//  inserted, so results are bit-identical to the old combinational form.
//  Stages: S1 unpack+multiply | S2 prod-normalize+align | S3 add/sub |
//          S4 sub-normalize+pick | S5 roundPackToF64.

`include "karu_fpkg.vh"
`include "karu_cfg.vh"

module karu_ffma_d (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,
    input  wire         neg_prod,
    input  wire         neg_c,
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    input  wire [63:0]  c,

    output reg          done,
    output reg [63:0]   res,
    output reg  [4:0]   flags,
    output wire [7:0]   latency
);
    //  Mantissa-multiply cycle count: KARU_D_FMA_CYCLES (defaults to the standalone
    //  KARU_D_MUL_CYCLES). 1 = combinational 53x53 (DSP, behaviour UNCHANGED);
    //  else = radix-2 bit-serial 53x53 (no multiplier array), 53 extra cycles --
    //  exactly the {1,53} clamp karu_fmul_d uses. Latency port widened to [7:0] to
    //  hold 7+53 (karu_fpu leaves .latency() unconnected, so this is free).
    localparam D_REQ = `KARU_D_FMA_CYCLES;
    localparam D_FMA_CYCLES = (D_REQ == 1) ? 1 : 53;
    assign latency = 8'd7 + (D_FMA_CYCLES == 1 ? 8'd0 : 8'd53);

    function [6:0] clz64;
        input [63:0] v; integer i; reg fnd;
        begin clz64 = 7'd64; fnd = 1'b0;
            for (i = 63; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz64 = 7'd63 - i[6:0]; fnd = 1'b1; end
        end
    endfunction
    function [6:0] clz52;
        input [51:0] v; integer i; reg fnd;
        begin clz52 = 7'd52; fnd = 1'b0;
            for (i = 51; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz52 = 7'd51 - i[6:0]; fnd = 1'b1; end
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
    function [127:0] srj128;
        input [127:0] av; input [31:0] shamt;
        begin
            if (shamt >= 32'd127)      srj128 = {127'b0, (|av)};
            else if (shamt == 32'd0)   srj128 = av;
            else srj128 = (av >> shamt) | {127'b0, (|(av & ((128'b1 << shamt) - 128'b1)))};
        end
    endfunction

    localparam S_IDLE = 3'd0, SMUL = 3'd1, S2 = 3'd2, S3 = 3'd3, S4 = 3'd4, S5 = 3'd5;
    reg [2:0]   st;
    assign busy = (st != S_IDLE);

    // ================================================================
    // STAGE 1 (combinational on the issue-cycle inputs a/b/c/rm/np/nc)
    // unpack + 53x53 multiply
    // ================================================================
    wire        signA = a[63];  wire [10:0] expA_r = a[62:52];  wire [51:0] sigA_r = a[51:0];
    wire        signB = b[63];  wire [10:0] expB_r = b[62:52];  wire [51:0] sigB_r = b[51:0];
    wire        signC = c[63] ^ neg_c;
    wire [10:0] expC_r = c[62:52];  wire [51:0] sigC_r = c[51:0];
    wire        signZ0 = signA ^ signB ^ neg_prod;

    wire a_is_nan = (expA_r == 11'h7FF) && (sigA_r != 0);
    wire b_is_nan = (expB_r == 11'h7FF) && (sigB_r != 0);
    wire c_is_nan = (expC_r == 11'h7FF) && (sigC_r != 0);
    wire a_snan = a_is_nan && !sigA_r[51];
    wire b_snan = b_is_nan && !sigB_r[51];
    wire c_snan = c_is_nan && !sigC_r[51];
    wire a_inf = (expA_r == 11'h7FF) && (sigA_r == 0);
    wire b_inf = (expB_r == 11'h7FF) && (sigB_r == 0);
    wire c_inf = (expC_r == 11'h7FF) && (sigC_r == 0);

    wire        a_sub = (expA_r == 0) && (sigA_r != 0);
    wire        b_sub = (expB_r == 0) && (sigB_r != 0);
    wire        c_sub = (expC_r == 0) && (sigC_r != 0);
    wire [6:0]  a_sd = clz52(sigA_r) + 7'd1;
    wire [6:0]  b_sd = clz52(sigB_r) + 7'd1;
    wire [6:0]  c_sd = clz52(sigC_r) + 7'd1;
    wire signed [15:0] expA = a_sub ? (16'sd1 - {{9{1'b0}}, a_sd}) : $signed({5'b0, expA_r});
    wire signed [15:0] expB = b_sub ? (16'sd1 - {{9{1'b0}}, b_sd}) : $signed({5'b0, expB_r});
    wire signed [15:0] expC = c_sub ? (16'sd1 - {{9{1'b0}}, c_sd}) : $signed({5'b0, expC_r});
    wire [51:0] sigA_n = a_sub ? (sigA_r << a_sd) : sigA_r;
    wire [51:0] sigB_n = b_sub ? (sigB_r << b_sd) : sigB_r;
    wire [51:0] sigC_n = c_sub ? (sigC_r << c_sd) : sigC_r;

    wire a_is_zero = (expA_r == 0) && (sigA_r == 0);
    wire b_is_zero = (expB_r == 0) && (sigB_r == 0);
    wire c_is_zero = (expC_r == 0) && (sigC_r == 0);

    wire any_snan = a_snan || b_snan || c_snan;
    wire any_input_nan = a_is_nan || b_is_nan || c_is_nan;
    wire prodInf_argInf = a_inf || b_inf;
    wire prod_inf_times_zero = (a_inf && b_is_zero) || (b_inf && a_is_zero);
    wire prod_is_inf = prodInf_argInf && !prod_inf_times_zero && !a_is_nan && !b_is_nan;
    wire inf_minus_inf = prod_is_inf && c_inf && (signZ0 != signC);
    wire nv = any_snan || prod_inf_times_zero || inf_minus_inf;
    wire special_active = any_input_nan || prod_inf_times_zero || prod_is_inf || c_inf;
    wire [63:0] special_res =
        (any_input_nan || prod_inf_times_zero || inf_minus_inf) ? `FP_D_QNAN :
        prod_is_inf ? {signZ0, 11'h7FF, 52'h0} :
        c_inf       ? {signC, 11'h7FF, 52'h0} :
                      64'b0;
    wire [4:0] special_flags = nv ? (5'b1 << `FF_NV) : 5'b0;

    wire zero_prod   = a_is_zero || b_is_zero;
    wire cancel_zero = c_is_zero && (signZ0 != signC);
    wire [63:0] zeroprod_res =
        cancel_zero ? {(rm == `FRM_RDN), 63'b0} : {signC, c[62:0]};

    wire signed [15:0] expProd0 = expA + expB - 16'sd1022;
    wire [62:0] sigA63 = {1'b1, sigA_n, 10'b0};
    wire [62:0] sigB63 = {1'b1, sigB_n, 10'b0};

    //  stage-0 registers (unpack/normalize). The multiply operands are
    //  registered so the 53x53 DSP gets registered inputs (its own cycle),
    //  keeping the front-end (IFU/decode) out of series with the multiply.
    reg [62:0]          s0_sigA63, s0_sigB63;
    reg signed [15:0]   s0_expProd0, s0_expC;
    reg                 s0_signZ0, s0_signC, s0_c_is_zero;
    reg [51:0]          s0_sigC_n;
    reg                 s0_special_active, s0_zero_prod;
    reg [63:0]          s0_special_res, s0_zeroprod_res;
    reg [4:0]           s0_special_flags;
    reg [2:0]           s0_rm;
    wire [127:0] s1_sig128_0_w = {65'b0, s0_sigA63} * {65'b0, s0_sigB63};

    //  stage-1 registers
    reg [127:0]         s1_sig128_0;
    reg signed [15:0]   s1_expProd0;
    reg                 s1_signZ0, s1_signC;
    reg signed [15:0]   s1_expC;
    reg [51:0]          s1_sigC_n;
    reg                 s1_c_is_zero;
    reg                 s1_special_active, s1_zero_prod;
    reg [63:0]          s1_special_res, s1_zeroprod_res;
    reg [4:0]           s1_special_flags;
    reg [2:0]           s1_rm;

    // ================================================================
    // STAGE 2 (from s1): product-normalize + alignment
    // ================================================================
    wire        prod_lt = (s1_sig128_0[127:64] < 64'h2000_0000_0000_0000);
    wire signed [15:0] expProd = prod_lt ? (s1_expProd0 - 16'sd1) : s1_expProd0;
    wire [127:0] sig128p = prod_lt ? (s1_sig128_0 << 1) : s1_sig128_0;

    wire [63:0]  sigC62  = {2'b0, 1'b1, s1_sigC_n, 9'b0};
    wire [127:0] sigC128 = {sigC62, 64'b0};

    wire signed [15:0] cz_exp  = expProd - 16'sd1;
    wire [63:0]        cz_sigZ = (sig128p[127:64] << 1) | {63'b0, (|sig128p[63:0])};

    wire signed [15:0] expDiff   = expProd - s1_expC;
    wire signed [31:0] expDiff32 = expDiff;
    wire        same_sign = (s1_signZ0 == s1_signC);

    wire [31:0]  nd = -expDiff32;
    wire [63:0]  aln_v64_jam = srj64(sig128p[127:64], nd);
    wire [127:0] aln_short1  = (sig128p >> 1) | {127'b0, (|sig128p[0])};
    wire         align_jamv64 = (same_sign || (expDiff < -16'sd1));
    wire [127:0] sig128Z_neg = align_jamv64 ? {aln_v64_jam, sig128p[63:0]} : aln_short1;
    wire [127:0] sig128C_gt  = srj128(sigC128, expDiff32);

    wire [127:0] sig128Z = (expDiff < 0) ? sig128Z_neg : sig128p;
    wire [127:0] sig128C = (expDiff < 0) ? sigC128 :
                           (expDiff == 0) ? sigC128 : sig128C_gt;
    wire signed [15:0] expZ_al = (expDiff < 0) ? s1_expC : expProd;

    //  stage-2 registers
    reg [127:0]         s2_sig128Z, s2_sig128C, s2_sig128p;
    reg [63:0]          s2_sigC62;
    reg signed [15:0]   s2_expZ_al, s2_expDiff, s2_cz_exp;
    reg                 s2_same_sign, s2_use_czero, s2_signZ0, s2_signC;
    reg [63:0]          s2_cz_sigZ;
    reg                 s2_special_active, s2_zero_prod;
    reg [63:0]          s2_special_res, s2_zeroprod_res;
    reg [4:0]           s2_special_flags;
    reg [2:0]           s2_rm;

    // ================================================================
    // STAGE 3 (from s2): add (same sign) + sub (opposite sign), raw
    // ================================================================
    wire [63:0]  add_sigZ_le = (s2_sigC62 + s2_sig128Z[127:64]) | {63'b0, (|s2_sig128Z[63:0])};
    wire [127:0] add_sum128  = s2_sig128Z + s2_sig128C;
    wire [63:0]  add_sigZ_gt = add_sum128[127:64] | {63'b0, (|add_sum128[63:0])};
    wire         add_le = (s2_expDiff <= 0);
    wire [63:0]  add_sigZ0 = add_le ? add_sigZ_le : add_sigZ_gt;
    wire         add_norm = (add_sigZ0 < 64'h4000_0000_0000_0000);
    wire signed [15:0] add_expZ = add_norm ? (s2_expZ_al - 16'sd1) : s2_expZ_al;
    wire [63:0]  add_sigZ  = add_norm ? (add_sigZ0 << 1) : add_sigZ0;

    wire [127:0] sub_lt_128 = s2_sig128C - s2_sig128Z;
    wire [63:0]  sub_eq_v64 = s2_sig128p[127:64] - s2_sigC62;
    wire [127:0] sub_eq_128_pre = {sub_eq_v64, s2_sig128p[63:0]};
    wire         sub_eq_zero = (s2_expDiff == 0) && (sub_eq_v64 == 0) && (s2_sig128p[63:0] == 0);
    wire         eq_neg = (s2_expDiff == 0) && sub_eq_v64[63];
    wire [127:0] sub_eq_128 = eq_neg ? (~sub_eq_128_pre + 128'b1) : sub_eq_128_pre;
    wire [127:0] sub_gt_128 = s2_sig128Z - s2_sig128C;
    wire [127:0] sub_128 =
        (s2_expDiff < 0)  ? sub_lt_128 :
        (s2_expDiff == 0) ? sub_eq_128 :
                            sub_gt_128;
    wire sub_signZ =
        (s2_expDiff < 0)  ? s2_signC :
        (s2_expDiff == 0) ? (eq_neg ? !s2_signZ0 : s2_signZ0) :
                            s2_signZ0;

    //  stage-3 registers
    reg [63:0]          s3_add_sigZ;
    reg signed [15:0]   s3_add_expZ, s3_expZ_al, s3_cz_exp;
    reg [127:0]         s3_sub_128;
    reg                 s3_sub_signZ, s3_sub_eq_zero;
    reg                 s3_use_czero, s3_same_sign, s3_signZ0;
    reg [63:0]          s3_cz_sigZ;
    reg                 s3_special_active, s3_zero_prod;
    reg [63:0]          s3_special_res, s3_zeroprod_res;
    reg [4:0]           s3_special_flags;
    reg [2:0]           s3_rm;

    // ================================================================
    // STAGE 4 (from s3): sub normalize (CLZ + shift) + pick rp_*
    // ================================================================
    wire        sub_v64_zero = (s3_sub_128[127:64] == 64'b0);
    wire [63:0] sub_hi = sub_v64_zero ? s3_sub_128[63:0] : s3_sub_128[127:64];
    wire [63:0] sub_lo = sub_v64_zero ? 64'b0 : s3_sub_128[63:0];
    wire signed [15:0] sub_expZ_b0 = s3_expZ_al - (sub_v64_zero ? 16'sd64 : 16'sd0);
    wire [6:0]  sub_clz = clz64(sub_hi);
    wire signed [15:0] sub_shiftDist = {{9{1'b0}}, sub_clz} - 16'sd1;
    wire signed [15:0] sub_expZ = sub_expZ_b0 - sub_shiftDist;
    wire        sd_neg = (sub_shiftDist < 0);
    wire [63:0] ssrj = srj64(sub_hi, 32'd1);
    wire [127:0] ssl128 = {sub_hi, sub_lo} << sub_shiftDist[6:0];
    wire [63:0] sub_sigZ_raw = sd_neg ? ssrj : ssl128[127:64];
    wire [63:0] sub_sigZ = sub_sigZ_raw | {63'b0, (sd_neg ? 1'b0 : (|ssl128[63:0]))
                                                | (sd_neg ? (|sub_lo) : 1'b0)};

    wire        rp_sign_w = s3_use_czero ? s3_signZ0 : (s3_same_sign ? s3_signZ0 : s3_sub_signZ);
    wire signed [15:0] rp_exp_w = s3_use_czero ? s3_cz_exp : (s3_same_sign ? s3_add_expZ : sub_expZ);
    wire [63:0] rp_sig_w = s3_use_czero ? s3_cz_sigZ : (s3_same_sign ? s3_add_sigZ : sub_sigZ);
    wire        complete_cancel_w = !s3_special_active && !s3_zero_prod && !s3_use_czero
                                  && !s3_same_sign && s3_sub_eq_zero;

    //  stage-4 registers
    reg                 s4_rp_sign, s4_complete_cancel;
    reg signed [15:0]   s4_rp_exp;
    reg [63:0]          s4_rp_sig;
    reg                 s4_special_active, s4_zero_prod;
    reg [63:0]          s4_special_res, s4_zeroprod_res;
    reg [4:0]           s4_special_flags;
    reg [2:0]           s4_rm;

    // ================================================================
    // STAGE 5 (from s4): roundPackToF64
    // ================================================================
    wire roundNearEven = (s4_rm == `FRM_RNE);
    wire roundNearMax  = (s4_rm == `FRM_RMM);
    wire [10:0] roundIncrement =
        (roundNearEven || roundNearMax) ? 11'h200 :
        ((s4_rm == (s4_rp_sign ? `FRM_RDN : `FRM_RUP)) ? 11'h3FF : 11'h000);

    wire enter_block = (s4_rp_exp < 0) || (s4_rp_exp >= 16'sd2045);
    wire subn = enter_block && (s4_rp_exp < 0);
    wire [31:0] srj_amt = -{{16{s4_rp_exp[15]}}, s4_rp_exp};
    wire [63:0] sub_sig_sh = srj64(s4_rp_sig, srj_amt);
    wire [63:0] eff_sig = subn ? sub_sig_sh : s4_rp_sig;
    wire signed [15:0] eff_exp = subn ? 16'sd0 : s4_rp_exp;
    wire [9:0]  roundBits = eff_sig[9:0];

    wire [64:0] sig_plus_inc = {1'b0, s4_rp_sig} + {54'b0, roundIncrement};
    wire isTiny = subn && ((s4_rp_exp < -16'sd1) || (sig_plus_inc < 65'h0_8000_0000_0000_0000));
    wire overflow = enter_block && !subn
                 && ((s4_rp_exp > 16'sd2045) || (sig_plus_inc >= 65'h0_8000_0000_0000_0000));

    wire [64:0] sig_rnd = ({1'b0, eff_sig} + {54'b0, roundIncrement}) >> 10;
    wire        tie_even = (roundBits == 10'h200) && roundNearEven;
    wire [63:0] sig_final0 = sig_rnd[63:0] & ~(tie_even ? 64'b1 : 64'b0);
    wire [63:0] exp_for_pack = (sig_final0 == 0) ? 64'b0 : {48'b0, eff_exp};
    wire [63:0] rp_packed = {s4_rp_sign, 63'b0} + (exp_for_pack << 52) + sig_final0;

    wire        rp_inexact = |roundBits;
    wire        rp_uf      = isTiny && (|roundBits);
    wire [63:0] over_res   = {s4_rp_sign, 11'h7FF, 52'h0} - ((roundIncrement == 0) ? 64'b1 : 64'b0);

    wire [63:0] roundpack_res = overflow ? over_res : rp_packed;
    wire [4:0]  roundpack_flags =
        overflow ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) :
        ((rp_uf ? (5'b1 << `FF_UF) : 5'b0) | (rp_inexact ? (5'b1 << `FF_NX) : 5'b0));

    wire [63:0] res_w =
        s4_special_active  ? s4_special_res :
        s4_zero_prod       ? s4_zeroprod_res :
        s4_complete_cancel ? {(s4_rm == `FRM_RDN), 63'b0} :
                             roundpack_res;
    wire [4:0]  flags_w =
        s4_special_active  ? s4_special_flags :
        (s4_zero_prod || s4_complete_cancel) ? 5'b0 :
                             roundpack_flags;

    // ================================================================
    // FSM: one op flows S1->S5 (5 cycles); core is single-issue
    // ================================================================
    // ================================================================
    // Mantissa multiply: combinational (==1) or radix-2 bit-serial (53).
    // sigA63*sigB63 == (sigA53*sigB53)<<20, so the serial path runs the proven
    // fmul_d 53x53->106 bit-serial recurrence on the 53-bit significands then
    // shifts <<20 -- the latched s1_sig128_0 is bit-identical to the `*` product.
    // ================================================================
    wire [52:0] sigA53 = sigA63[62:10];     //  {1'b1, sigA_n} (combinational at req)
    wire [52:0] sigB53 = sigB63[62:10];
    wire         mul_done;
    wire [127:0] mul_prod;
    //  FSM state encodings hoisted to module scope -- Genus rejects localparam
    //  declarations inside generate blocks; used by the g_dfma_iter always below.
    localparam SS_IDLE = 2'd0, SS_RUN = 2'd1, SS_FIN = 2'd2;
    generate
    if (D_FMA_CYCLES == 1) begin : g_dfma_comb
        assign mul_done = 1'b1;
        assign mul_prod = s1_sig128_0_w;    //  combinational 53x53 (DSP)
    end else begin : g_dfma_iter
        reg [1:0]   sstate;
        reg [6:0]   scnt;
        reg [105:0] sacc;
        reg [52:0]  sma;
        wire [53:0]  smul_sum  = sacc[105:53] + (sacc[0] ? sma : 53'b0);
        wire [105:0] smul_next = { smul_sum, sacc[52:1] };
        always @(posedge clk) begin
            if (rst) sstate <= SS_IDLE;
            else case (sstate)
                SS_IDLE: if (st == S_IDLE && req) begin //  load from live operands at req
                    sma    <= sigA53;
                    sacc   <= {53'b0, sigB53};
                    scnt   <= 7'd53;
                    sstate <= SS_RUN;
                end
                SS_RUN: begin
                    sacc <= smul_next;
                    scnt <= scnt - 7'd1;
                    if (scnt == 7'd1) sstate <= SS_FIN;
                end
                SS_FIN: sstate <= SS_IDLE;
                default: sstate <= SS_IDLE;
            endcase
        end
        assign mul_done = (sstate == SS_FIN);
        assign mul_prod = {2'b0, sacc, 20'b0};  //  (sigA53*sigB53) << 20
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
                    s0_sigA63      <= sigA63;
                    s0_sigB63      <= sigB63;
                    s0_expProd0    <= expProd0;
                    s0_signZ0      <= signZ0;
                    s0_signC       <= signC;
                    s0_expC        <= expC;
                    s0_sigC_n      <= sigC_n;
                    s0_c_is_zero   <= c_is_zero;
                    s0_special_active <= special_active;
                    s0_special_res    <= special_res;
                    s0_special_flags  <= special_flags;
                    s0_zero_prod      <= zero_prod;
                    s0_zeroprod_res   <= zeroprod_res;
                    s0_rm          <= rm;
                    st <= SMUL;
                end
                SMUL: if (mul_done) begin
                    //  stage 1: the 53x53 product (combinational fast path or the
                    //  serial engine's result), latched when ready (busy held meanwhile)
                    s1_sig128_0    <= mul_prod;
                    s1_expProd0    <= s0_expProd0;
                    s1_signZ0      <= s0_signZ0;
                    s1_signC       <= s0_signC;
                    s1_expC        <= s0_expC;
                    s1_sigC_n      <= s0_sigC_n;
                    s1_c_is_zero   <= s0_c_is_zero;
                    s1_special_active <= s0_special_active;
                    s1_special_res    <= s0_special_res;
                    s1_special_flags  <= s0_special_flags;
                    s1_zero_prod      <= s0_zero_prod;
                    s1_zeroprod_res   <= s0_zeroprod_res;
                    s1_rm          <= s0_rm;
                    st <= S2;
                end
                S2: begin
                    s2_sig128Z   <= sig128Z;
                    s2_sig128C   <= sig128C;
                    s2_sig128p   <= sig128p;
                    s2_sigC62    <= sigC62;
                    s2_expZ_al   <= expZ_al;
                    s2_expDiff   <= expDiff;
                    s2_cz_exp    <= cz_exp;
                    s2_cz_sigZ   <= cz_sigZ;
                    s2_same_sign <= same_sign;
                    s2_use_czero <= s1_c_is_zero;
                    s2_signZ0    <= s1_signZ0;
                    s2_signC     <= s1_signC;
                    s2_special_active <= s1_special_active;
                    s2_special_res    <= s1_special_res;
                    s2_special_flags  <= s1_special_flags;
                    s2_zero_prod      <= s1_zero_prod;
                    s2_zeroprod_res   <= s1_zeroprod_res;
                    s2_rm        <= s1_rm;
                    st <= S3;
                end
                S3: begin
                    s3_add_sigZ  <= add_sigZ;
                    s3_add_expZ  <= add_expZ;
                    s3_expZ_al   <= s2_expZ_al;
                    s3_cz_exp    <= s2_cz_exp;
                    s3_sub_128   <= sub_128;
                    s3_sub_signZ <= sub_signZ;
                    s3_sub_eq_zero <= sub_eq_zero;
                    s3_use_czero <= s2_use_czero;
                    s3_same_sign <= s2_same_sign;
                    s3_signZ0    <= s2_signZ0;
                    s3_cz_sigZ   <= s2_cz_sigZ;
                    s3_special_active <= s2_special_active;
                    s3_special_res    <= s2_special_res;
                    s3_special_flags  <= s2_special_flags;
                    s3_zero_prod      <= s2_zero_prod;
                    s3_zeroprod_res   <= s2_zeroprod_res;
                    s3_rm        <= s2_rm;
                    st <= S4;
                end
                S4: begin
                    s4_rp_sign   <= rp_sign_w;
                    s4_rp_exp    <= rp_exp_w;
                    s4_rp_sig    <= rp_sig_w;
                    s4_complete_cancel <= complete_cancel_w;
                    s4_special_active  <= s3_special_active;
                    s4_special_res     <= s3_special_res;
                    s4_special_flags   <= s3_special_flags;
                    s4_zero_prod       <= s3_zero_prod;
                    s4_zeroprod_res    <= s3_zeroprod_res;
                    s4_rm        <= s3_rm;
                    st <= S5;
                end
                S5: begin
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
    //  (D_FMA_CYCLES==53) holds `busy` across 53+ cycles, so police the
    //  req/busy/done contract explicitly. busy = (st != S_IDLE); done pulses the
    //  cycle busy returns to 0 (S5 schedules done<=1, st<=S_IDLE).
    reg ffa_busy_q, ffa_done_q;
    always @(posedge clk) begin
        ffa_busy_q <= !rst && busy;
        ffa_done_q <= !rst && done;
    end
    always @(posedge clk) if (!rst) begin
        //  H1: req accepted only while idle (single op in flight; caller waits on busy).
        if (req && busy)
            begin $display("[FFMA_D-ASSERT] req while busy @%0t", $time); $finish; end
        //  H2: busy stays high until done -- it may only fall on the done cycle.
        if (ffa_busy_q && !busy && !done)
            begin $display("[FFMA_D-ASSERT] busy fell without done @%0t", $time); $finish; end
        //  H3: done is a one-cycle pulse.
        if (ffa_done_q && done)
            begin $display("[FFMA_D-ASSERT] done held >1 cycle @%0t", $time); $finish; end
    end
// synthesis translate_on
endmodule
