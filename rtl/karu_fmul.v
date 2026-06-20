//  karu_fmul.v
//  IEEE 754 binary32 (single-precision) multiplier.
//
//  Variable-cycles handshake:
//    req       (in)  pulse to start a new op
//    busy      (out) high while an op is in flight (cannot accept req)
//    done      (out) pulse high for the cycle res/flags are valid
//    latency   (out) cycles this implementation takes (constant for a
//                    given build; useful for pipelined / vector
//                    schedulers to reserve writeback slots)
//
//  Mantissa-multiply cycle count is set by KARU_F_MUL_CYCLES (or via
//  master KARU_MUL_CYCLES; see karu_cfg.vh).
//  Valid values: any divisor of 24 — {1, 2, 3, 4, 6, 8, 12, 24}.
//    1   : combinational 24x24 -> 48 (default; uses Verilog `*`)
//    N>1 : radix-2^K shift-and-add, K = 24/N bits per cycle, N cycles
//
//  Subnormal inputs are flushed to zero on this first pass (FTZ); the
//  bulk of rv64uf tests don't exercise true subnormal arithmetic.

`include "karu_fpkg.vh"
`include "karu_cfg.vh"

module karu_fmul (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,             //  rounding mode (frm or instr-level)
    input  wire [31:0]  a,
    input  wire [31:0]  b,

    output reg          done,
    output reg [31:0]   res,
    output reg  [4:0]   flags,

    //  Build-time latency hint (cycles from req to done observed).
    output wire [4:0]   latency
);
    //  Resolve effective cycle count.
    localparam F_REQ = `KARU_F_MUL_CYCLES;
    localparam F_MUL_CYCLES =
        (F_REQ == 1)  ? 1  :
        (F_REQ == 2)  ? 2  :
        (F_REQ == 3)  ? 3  :
        (F_REQ == 4)  ? 4  :
        (F_REQ <= 6)  ? 6  :
        (F_REQ <= 8)  ? 8  :
        (F_REQ <= 12) ? 12 : 24;
    localparam F_MUL_K = (F_MUL_CYCLES == 1) ? 24 : (24 / F_MUL_CYCLES);

    //  ==================================================================
    //  Unpack
    //  ==================================================================
    //  The exp/sign/special/normalize datapath is combinational and is sampled
    //  at result time. For the 1-cycle config that is the req cycle (operands
    //  live); the radix-2^K serial config captures several cycles later, after
    //  the live a/b have advanced to the next op -- so latch a_q/b_q at req and
    //  drive the datapath from them in the iterative case. (See karu_fmul_d.)
    reg [31:0] a_q, b_q;
    reg [2:0]  rm_q;    //  latch rm too -- iterative path rounds at result time,
                        //  when live `rm` reflects a later instruction (see karu_fmul_d).
    always @(posedge clk) if (req) begin a_q <= a; b_q <= b; rm_q <= rm; end
    wire [31:0] opa = (F_MUL_CYCLES == 1) ? a : a_q;
    wire [31:0] opb = (F_MUL_CYCLES == 1) ? b : b_q;
    wire [2:0]  orm = (F_MUL_CYCLES == 1) ? rm : rm_q;

    wire        a_sign = opa[31];
    wire [7:0]  a_exp  = opa[30:23];
    wire [22:0] a_man  = opa[22:0];
    wire        a_zero  = (a_exp == 8'h00) && (a_man == 23'h0);
    wire        a_sub   = (a_exp == 8'h00) && (a_man != 23'h0);
    wire        a_inf   = (a_exp == 8'hFF) && (a_man == 23'h0);
    wire        a_nan   = (a_exp == 8'hFF) && (a_man != 23'h0);
    wire        a_snan  = a_nan && !a_man[22];

    wire        b_sign = opb[31];
    wire [7:0]  b_exp  = opb[30:23];
    wire [22:0] b_man  = opb[22:0];
    wire        b_zero  = (b_exp == 8'h00) && (b_man == 23'h0);
    wire        b_sub   = (b_exp == 8'h00) && (b_man != 23'h0);
    wire        b_inf   = (b_exp == 8'hFF) && (b_man == 23'h0);
    wire        b_nan   = (b_exp == 8'hFF) && (b_man != 23'h0);
    wire        b_snan  = b_nan && !b_man[22];

    //  Subnormal *inputs* are normalized in place (we shift the mantissa
    //  left so the leading 1 sits at the implicit-1 position, and use a
    //  negative effective biased exponent). Only true zero counts as
    //  a_is_zero now. Subnormal *outputs* (true underflow) are still
    //  flushed to signed zero downstream.
    wire        a_is_zero = a_zero;
    wire        b_is_zero = b_zero;

    function [4:0] clz23;
        input [22:0] v;
        integer i;
        reg fnd;
        begin
            clz23 = 5'd23;
            fnd   = 1'b0;
            for (i = 22; i >= 0; i = i - 1) begin
                if (!fnd && v[i]) begin
                    clz23 = 5'd22 - i[4:0];
                    fnd   = 1'b1;
                end
            end
        end
    endfunction

    wire [4:0]  a_clz = a_sub ? clz23(a_man) : 5'd0;
    wire [4:0]  b_clz = b_sub ? clz23(b_man) : 5'd0;

    wire [22:0] a_man_norm = a_sub ? (a_man << (a_clz + 5'd1)) : a_man;
    wire [22:0] b_man_norm = b_sub ? (b_man << (b_clz + 5'd1)) : b_man;

    wire [23:0] a_mfull = {1'b1, a_man_norm};
    wire [23:0] b_mfull = {1'b1, b_man_norm};

    //  ==================================================================
    //  Special-case classification + result
    //  ==================================================================
    wire any_nan      = a_nan || b_nan;
    wire any_snan     = a_snan || b_snan;
    wire inv_inf_zero = (a_inf && b_is_zero) || (b_inf && a_is_zero);
    wire res_sign     = a_sign ^ b_sign;

    wire special_active = any_nan || inv_inf_zero
                         || a_inf || b_inf
                         || a_is_zero || b_is_zero;
    wire [31:0] special_res =
        any_nan         ? `FP_S_QNAN :
        inv_inf_zero    ? `FP_S_QNAN :
        (a_inf || b_inf) ? {res_sign, 8'hFF, 23'h000000} :
                           {res_sign, 31'b0};
    wire [4:0]  special_flags =
        (any_snan ? (5'b1 << `FF_NV) : 5'b0) |
        (inv_inf_zero ? (5'b1 << `FF_NV) : 5'b0);

    //  ==================================================================
    //  Normal multiply path
    //  ==================================================================
    wire signed [9:0] a_exp_eff = a_sub ? (10'sd0 - {{5{1'b0}}, a_clz})
                                        : $signed({2'b0, a_exp});
    wire signed [9:0] b_exp_eff = b_sub ? (10'sd0 - {{5{1'b0}}, b_clz})
                                        : $signed({2'b0, b_exp});
    wire signed [9:0] exp_sum_pre = a_exp_eff + b_exp_eff - 10'sd127;

    //  Fast-path pipeline depth (>=2 -> pipelined; clamped to >=3 in g_fastp).
    localparam F_MUL_PIPE = `KARU_F_MUL_PIPE;

    //  The normalize/round/pack datapath (below) is SHARED by all three multiply
    //  variants. It consumes "effective" inputs (eff_*) so one block serves the
    //  radix-2^K backup, the combinational fast path, and the pipelined fast
    //  path (which feeds it REGISTERED values).
    wire [47:0]       eff_prod;
    wire signed [9:0] eff_exp_sum_pre;
    wire              eff_res_sign;
    wire              eff_special_active;
    wire [31:0]       eff_special_res;
    wire [4:0]        eff_special_flags;
    wire [2:0]        eff_orm;
    wire sm_busy;
    wire sm_done;

    generate
    if (F_MUL_CYCLES != 1) begin : g_iter
        //  ------------------------------------------------------------------
        //  Iterative radix-2^K shift-and-add (the BACKUP). K = 24/F_MUL_CYCLES
        //  bits/cycle. Accumulator is 48 bits = {prod_high(24), mult_rem(24)}.
        //  Per cycle: consume K bits of multiplier, multiply by 24-bit
        //  multiplicand to make a (24+K)-bit partial, add to prod_high, then
        //  right-shift the 48-bit window by K.
        //  ------------------------------------------------------------------
        localparam SS_IDLE = 2'd0, SS_LOAD = 2'd1, SS_RUN = 2'd2, SS_FIN = 2'd3;
        reg [1:0]       sstate;
        reg [4:0]       scnt;
        reg [47:0]      sacc;
        reg [23:0]      sma;

        wire [F_MUL_K+23:0] smul_partial = sma * sacc[F_MUL_K-1:0];
        wire [F_MUL_K+23:0] smul_sum     = sacc[47:24] + smul_partial;
        wire [47:0]         smul_next    = { smul_sum, sacc[23:F_MUL_K] };

        assign eff_prod = sacc;
        assign sm_busy  = (sstate != SS_IDLE);
        assign sm_done  = (sstate == SS_FIN);

        always @(posedge clk) begin
            if (rst) begin
                sstate <= SS_IDLE;
            end else begin
                case (sstate)
                    SS_IDLE: if (req) sstate <= SS_LOAD;    //  a_q/b_q latch this cycle
                    SS_LOAD: begin
                        sma    <= a_mfull;                  //  now derived from a_q/b_q
                        sacc   <= {24'b0, b_mfull};
                        scnt   <= F_MUL_CYCLES[4:0];
                        sstate <= SS_RUN;
                    end
                    SS_RUN: begin
                        sacc <= smul_next;
                        scnt <= scnt - 5'd1;
                        if (scnt == 5'd1) sstate <= SS_FIN;
                    end
                    SS_FIN: sstate <= SS_IDLE;
                endcase
            end
        end
        assign eff_exp_sum_pre    = exp_sum_pre;
        assign eff_res_sign       = res_sign;
        assign eff_special_active = special_active;
        assign eff_special_res    = special_res;
        assign eff_special_flags  = special_flags;
        assign eff_orm            = orm;
    end else if (F_MUL_PIPE <= 1) begin : g_fast
        //  Combinational 24x24 -> 48 (default): one stage, eff_* = live wires.
        assign eff_prod           = a_mfull * b_mfull;
        assign sm_busy            = 1'b0;
        assign sm_done            = 1'b0;
        assign eff_exp_sum_pre    = exp_sum_pre;
        assign eff_res_sign       = res_sign;
        assign eff_special_active = special_active;
        assign eff_special_res    = special_res;
        assign eff_special_flags  = special_flags;
        assign eff_orm            = orm;
    end else begin : g_fastp
        //  PIPELINED fast 24x24 (FPGA Fmax): operand -> multiply -> round stages.
        //  busy high for the whole fill (single-op semantics) -> transparent to
        //  consumers; feed-forward / per-op-stateless (II=1 stream-capable).
        localparam NP = (F_MUL_PIPE < 3) ? 3 : F_MUL_PIPE;  //  register stages, >=3
        integer st;
        reg [NP-1:1]      vldp;
        reg [23:0]        r_amf, r_bmf;
        reg signed [9:0]  r_exp   [1:NP-1];
        reg               r_rsign [1:NP-1];
        reg               r_spec  [1:NP-1];
        reg [31:0]        r_sres  [1:NP-1];
        reg [4:0]         r_sflag [1:NP-1];
        reg [2:0]         r_orm   [1:NP-1];
        reg [47:0]        r_prod  [2:NP-1];

        always @(posedge clk) begin
            if (rst) begin
                vldp <= {(NP-1){1'b0}};
            end else begin
                vldp[1] <= req;
                for (st = 2; st <= NP-1; st = st + 1) vldp[st] <= vldp[st-1];
                if (req) begin r_amf <= a_mfull; r_bmf <= b_mfull; end
                r_exp[1]   <= exp_sum_pre;
                r_rsign[1] <= res_sign;
                r_spec[1]  <= special_active;
                r_sres[1]  <= special_res;
                r_sflag[1] <= special_flags;
                r_orm[1]   <= rm;
                r_prod[2]  <= r_amf * r_bmf;
                r_exp[2]   <= r_exp[1];
                r_rsign[2] <= r_rsign[1];
                r_spec[2]  <= r_spec[1];
                r_sres[2]  <= r_sres[1];
                r_sflag[2] <= r_sflag[1];
                r_orm[2]   <= r_orm[1];
                for (st = 3; st <= NP-1; st = st + 1) begin
                    r_prod[st]  <= r_prod[st-1];
                    r_exp[st]   <= r_exp[st-1];
                    r_rsign[st] <= r_rsign[st-1];
                    r_spec[st]  <= r_spec[st-1];
                    r_sres[st]  <= r_sres[st-1];
                    r_sflag[st] <= r_sflag[st-1];
                    r_orm[st]   <= r_orm[st-1];
                end
            end
        end
        assign eff_prod           = r_prod[NP-1];
        assign sm_busy            = |vldp;
        assign sm_done            = vldp[NP-1];
        assign eff_exp_sum_pre    = r_exp[NP-1];
        assign eff_res_sign       = r_rsign[NP-1];
        assign eff_special_active = r_spec[NP-1];
        assign eff_special_res    = r_sres[NP-1];
        assign eff_special_flags  = r_sflag[NP-1];
        assign eff_orm            = r_orm[NP-1];
    end
    endgenerate

    localparam NP_LAT = (F_MUL_PIPE < 3) ? 3 : F_MUL_PIPE;
    assign busy    = sm_busy;
    assign latency = (F_MUL_CYCLES != 1) ? ((2 + F_MUL_CYCLES) & 5'h1f) :
                     (F_MUL_PIPE <= 1)   ? 5'd2 : NP_LAT[4:0];

    //  ---- Normalize / round / pack (subnormal-aware) ----
    //  Product leading 1 is at bit47 (product in [2,4)) or bit46 ([1,2)).
    //  Build a 28-bit normalized value with the leading 1 at bit27 and
    //  guard/round/sticky in the low bits, then round -- denormalizing
    //  (right-shifting, exp field 0) when the exponent would be <= 0.
    wire        nshift = eff_prod[47];
    wire [23:0] sig24  = nshift ? eff_prod[47:24] : eff_prod[46:23];    //  leading at [23]
    wire        g_in   = nshift ? eff_prod[23]    : eff_prod[22];
    wire        r_in   = nshift ? eff_prod[22]    : eff_prod[21];
    wire        s_in   = nshift ? (|eff_prod[21:0]) : (|eff_prod[20:0]);
    wire signed [10:0] exp_n = $signed({eff_exp_sum_pre[9], eff_exp_sum_pre}) + {10'b0, nshift};

    wire [27:0] norm = {sig24, g_in, r_in, 1'b0, s_in};     //  leading 1 at bit27

    //  Denormalize when exp_n <= 0.
    wire signed [10:0] dshift_s = (exp_n <= 0) ? (11'sd1 - exp_n) : 11'sd0;
    wire [10:0] dshift  = dshift_s[10:0];
    wire [27:0] dn      = (dshift >= 11'd28) ? 28'b0 : (norm >> dshift);
    wire        dn_lost = (dshift == 0) ? 1'b0 :
                          (dshift >= 11'd28) ? (|norm) :
                          (|(norm & (~({28{1'b1}} << dshift))));

    wire [23:0] dsig  = dn[27:4];
    wire        round_bit = dn[3];
    wire        sticky    = dn[2] | (|dn[1:0]) | dn_lost;
    wire        subnormal_region = (exp_n <= 0);

    wire round_up =
        (eff_orm == `FRM_RNE) ? (round_bit && (sticky || dsig[0])) :
        (eff_orm == `FRM_RTZ) ? 1'b0 :
        (eff_orm == `FRM_RDN) ? (eff_res_sign  && (round_bit || sticky)) :
        (eff_orm == `FRM_RUP) ? (!eff_res_sign && (round_bit || sticky)) :
        (eff_orm == `FRM_RMM) ? round_bit :
                           1'b0;

    wire [24:0] mant_rnd  = {1'b0, dsig} + {24'b0, round_up};
    wire        rnd_carry = mant_rnd[24];
    wire        promote   = mant_rnd[23];
    wire        inexact   = round_bit || sticky;

    wire signed [10:0] exp_norm_final = exp_n + (rnd_carry ? 11'sd1 : 11'sd0);
    wire        over = !subnormal_region && (exp_norm_final >= 11'sd255);
    //  Tininess after rounding (SoftFloat / RISC-V rule): a subnormal-range
    //  result is tiny UNLESS rounding it at NORMAL precision (i.e. before the
    //  denormalizing shift) would already reach the smallest normal. The
    //  round increment is evaluated at the pre-denormalize position.
    wire nr_up =
        (eff_orm == `FRM_RNE) ? (g_in && (r_in || s_in || sig24[0])) :
        (eff_orm == `FRM_RTZ) ? 1'b0 :
        (eff_orm == `FRM_RDN) ? (eff_res_sign  && (g_in || r_in || s_in)) :
        (eff_orm == `FRM_RUP) ? (!eff_res_sign && (g_in || r_in || s_in)) :
        (eff_orm == `FRM_RMM) ? g_in :
                           1'b0;
    wire reaches_normal = (({1'b0, sig24} + {24'b0, nr_up}) >= 25'h100_0000);
    wire tiny_before = subnormal_region
                    && ((exp_n <= -11'sd1) || !reaches_normal);

    wire [31:0] over_res =
        ((eff_orm == `FRM_RTZ) ||
         (eff_orm == `FRM_RDN && !eff_res_sign) ||
         (eff_orm == `FRM_RUP &&  eff_res_sign))
            ? {eff_res_sign, 8'hFE, 23'h7FFFFF}
            : {eff_res_sign, 8'hFF, 23'h000000};

    wire [31:0] normal_res =
        over ? over_res :
        subnormal_region ? {eff_res_sign, (promote ? 8'd1 : 8'd0), mant_rnd[22:0]} :
                           {eff_res_sign, exp_norm_final[7:0], (rnd_carry ? 23'b0 : mant_rnd[22:0])};

    wire [4:0] normal_flags =
        (over                  ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (tiny_before && inexact ? (5'b1 << `FF_UF)                     : 5'b0) |
        (inexact && !over      ? (5'b1 << `FF_NX)                      : 5'b0);

    wire [31:0] res_w   = eff_special_active ? eff_special_res   : normal_res;
    wire [4:0]  flags_w = eff_special_active ? eff_special_flags : normal_flags;

    //  ==================================================================
    //  Unified output latch + done pulse
    //  ==================================================================
    //  out_fire = the cycle res_w is valid to latch: `req` for the 1-cycle
    //  combinational fast path, else the variant's internal done strobe
    //  (radix-2^K SS_FIN or the pipeline's last valid stage).
    wire out_fire = (F_MUL_CYCLES == 1 && F_MUL_PIPE <= 1) ? req : sm_done;
    always @(posedge clk) begin
        if (rst) begin
            done <= 1'b0;
        end else begin
            done <= out_fire;
            if (out_fire) begin
                res   <= res_w;
                flags <= flags_w;
            end
        end
    end

    wire _unused = &{1'b0};
endmodule
