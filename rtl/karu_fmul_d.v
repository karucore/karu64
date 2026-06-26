//  karu_fmul_d.v
//  IEEE 754 binary64 (double-precision) multiplier. Direct widening of
//  karu_fmul: 11-bit exp / 52-bit mantissa / 1023 bias.
//
//  Mantissa-multiply cycle count is set by KARU_D_MUL_CYCLES (or via
//  master KARU_MUL_CYCLES; see karu_cfg.vh).
//  Valid values: {1, 53}.
//    1  : combinational 53x53 -> 106 (default; uses Verilog `*`)
//    53 : radix-2 bit-serial mantissa multiply
//
//  53 is prime so we can't easily multi-cycle this in between without
//  zero-padding the mantissa; the available knobs match karu_fmul's
//  flag scheme but the D-precision unit only honours the two extremes
//  (any iterative cycle count >1 maps to 53). FTZ on input subnormals.

`include "karu_fpkg.vh"
`include "karu_cfg.vh"

module karu_fmul_d (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire [2:0]   rm,
    input  wire [63:0]  a,
    input  wire [63:0]  b,

    output reg          done,
    output reg [63:0]   res,
    output reg  [4:0]   flags,
    output wire [4:0]   latency
);
    //  Resolve effective cycle count.
    localparam D_REQ = `KARU_D_MUL_CYCLES;
    localparam D_MUL_CYCLES = (D_REQ == 1) ? 1 : 53;

    //  Operand source: the combinational exp/sign/special/normalize datapath
    //  is sampled at result time. For the 1-cycle config that is the req cycle
    //  (operands live), but the bit-serial config captures 53+ cycles later --
    //  by which point the live a/b have moved to the next op (the core's IFU
    //  advances on issue). So the iterative path latches a_q/b_q at req and
    //  drives the whole datapath from them.
    reg [63:0] a_q, b_q;
    reg [2:0]  rm_q;    //  rm must be latched too: the iterative path rounds at
                        //  RESULT time (cycle req+53), by when the live `rm` reflects
                        //  a later instruction (issue advances).
    always @(posedge clk) if (req) begin a_q <= a; b_q <= b; rm_q <= rm; end
    wire [63:0] opa = (D_MUL_CYCLES == 1) ? a : a_q;
    wire [63:0] opb = (D_MUL_CYCLES == 1) ? b : b_q;
    wire [2:0]  orm = (D_MUL_CYCLES == 1) ? rm : rm_q;

    //  ---- unpack ----
    wire        a_sign = opa[63];
    wire [10:0] a_exp  = opa[62:52];
    wire [51:0] a_man  = opa[51:0];
    wire        a_zero = (a_exp == 11'h000) && (a_man == 52'h0);
    wire        a_sub  = (a_exp == 11'h000) && (a_man != 52'h0);
    wire        a_inf  = (a_exp == 11'h7FF) && (a_man == 52'h0);
    wire        a_nan  = (a_exp == 11'h7FF) && (a_man != 52'h0);
    wire        a_snan = a_nan && !a_man[51];

    wire        b_sign = opb[63];
    wire [10:0] b_exp  = opb[62:52];
    wire [51:0] b_man  = opb[51:0];
    wire        b_zero = (b_exp == 11'h000) && (b_man == 52'h0);
    wire        b_sub  = (b_exp == 11'h000) && (b_man != 52'h0);
    wire        b_inf  = (b_exp == 11'h7FF) && (b_man == 52'h0);
    wire        b_nan  = (b_exp == 11'h7FF) && (b_man != 52'h0);
    wire        b_snan = b_nan && !b_man[51];

    wire        a_is_zero = a_zero;     //  true zero only; subnormals normalized
    wire        b_is_zero = b_zero;

    function [5:0] clz52;
        input [51:0] v; integer i; reg fnd;
        begin
            clz52 = 6'd52; fnd = 1'b0;
            for (i = 51; i >= 0; i = i - 1)
                if (!fnd && v[i]) begin clz52 = 6'd51 - i[5:0]; fnd = 1'b1; end
        end
    endfunction
    wire [5:0]  a_clz = a_sub ? clz52(a_man) : 6'd0;
    wire [5:0]  b_clz = b_sub ? clz52(b_man) : 6'd0;
    wire [51:0] a_man_n = a_sub ? (a_man << (a_clz + 6'd1)) : a_man;
    wire [51:0] b_man_n = b_sub ? (b_man << (b_clz + 6'd1)) : b_man;
    wire [52:0] a_mfull = {1'b1, a_man_n};
    wire [52:0] b_mfull = {1'b1, b_man_n};
    wire signed [12:0] a_exp_eff = a_sub ? (13'sd0 - {{7{1'b0}}, a_clz}) : $signed({2'b0, a_exp});
    wire signed [12:0] b_exp_eff = b_sub ? (13'sd0 - {{7{1'b0}}, b_clz}) : $signed({2'b0, b_exp});

    //  ---- special cases ----
    wire any_nan      = a_nan || b_nan;
    wire any_snan     = a_snan || b_snan;
    wire inv_inf_zero = (a_inf && b_is_zero) || (b_inf && a_is_zero);
    wire res_sign     = a_sign ^ b_sign;

    wire special_active = any_nan || inv_inf_zero
                         || a_inf || b_inf
                         || a_is_zero || b_is_zero;
    wire [63:0] special_res =
        any_nan         ? `FP_D_QNAN :
        inv_inf_zero    ? `FP_D_QNAN :
        (a_inf || b_inf) ? {res_sign, 11'h7FF, 52'h0} :
                           {res_sign, 63'b0};
    wire [4:0]  special_flags =
        (any_snan     ? (5'b1 << `FF_NV) : 5'b0) |
        (inv_inf_zero ? (5'b1 << `FF_NV) : 5'b0);

    //  ---- normal multiply ----
    wire signed [12:0] exp_sum_pre = a_exp_eff + b_exp_eff - 13'sd1023;

    //  Fast-path pipeline depth (>=2 -> pipelined; clamped to >=3 inside g_fastp).
    localparam D_MUL_PIPE = `KARU_D_MUL_PIPE;

    //  The normalize/round/pack datapath (below) is SHARED by all three multiply
    //  variants. It consumes a set of "effective" inputs (eff_*) so one block
    //  serves: the bit-serial backup, the combinational fast path, and the
    //  pipelined fast path (which feeds it REGISTERED values).
    wire [105:0]       eff_prod;
    wire signed [12:0] eff_exp_sum_pre;
    wire               eff_res_sign;
    wire               eff_special_active;
    wire [63:0]        eff_special_res;
    wire [4:0]         eff_special_flags;
    wire [2:0]         eff_orm;
    wire sm_busy;
    wire sm_done;

    //  state encodings + pipe depth hoisted to module scope -- Genus rejects
    //  localparam decls inside generate blocks; used by the g_iter / g_fastp arms.
    localparam SS_IDLE = 2'd0, SS_LOAD = 2'd1, SS_RUN = 2'd2, SS_FIN = 2'd3;
    localparam NP = (D_MUL_PIPE < 3) ? 3 : D_MUL_PIPE;  //  register stages, >=3
    generate
    if (D_MUL_CYCLES != 1) begin : g_iter
        //  Bit-serial mantissa multiply: 53 iters, K=1 bit/cycle -- the BACKUP
        //  multiplier (smallest area). Latched a_q/b_q drive the datapath.
        //  SS_LOAD waits one cycle for a_q/b_q (hence a_mfull/b_mfull) to be
        //  valid before seeding the accumulator.
        reg [1:0]       sstate;
        reg [6:0]       scnt;
        reg [105:0]     sacc;
        reg [52:0]      sma;

        wire [53:0]     smul_sum  = sacc[105:53] + (sacc[0] ? sma : 53'b0);
        wire [105:0]    smul_next = { smul_sum, sacc[52:1] };

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
                        sacc   <= {53'b0, b_mfull};
                        scnt   <= 7'd53;
                        sstate <= SS_RUN;
                    end
                    SS_RUN: begin
                        sacc <= smul_next;
                        scnt <= scnt - 7'd1;
                        if (scnt == 7'd1) sstate <= SS_FIN;
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
    end else if (D_MUL_PIPE <= 1) begin : g_fast
        //  Combinational 53x53 (default): the whole unpack->mul->round cone is
        //  one stage; eff_* = live combinational signals, output reg on req.
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
        //  PIPELINED fast 53x53 (FPGA Fmax): operand stage -> multiply stage(s)
        //  -> round stage, so the timing-driven flow packs a pipelined DSP48
        //  cascade. `busy` stays high for the whole fill (single-op semantics),
        //  so this is transparent to every consumer (they wait on `done`). The
        //  datapath is feed-forward / per-op-stateless, so it is also II=1
        //  stream-capable for a future pipelined-issue vector FSM.
        integer st;
        reg [NP-1:1]      vldp;
        reg [52:0]        r_amf, r_bmf;
        reg signed [12:0] r_exp   [1:NP-1];
        reg               r_rsign [1:NP-1];
        reg               r_spec  [1:NP-1];
        reg [63:0]        r_sres  [1:NP-1];
        reg [4:0]         r_sflag [1:NP-1];
        reg [2:0]         r_orm   [1:NP-1];
        reg [105:0]       r_prod  [2:NP-1];

        always @(posedge clk) begin
            if (rst) begin
                vldp <= {(NP-1){1'b0}};
            end else begin
                vldp[1] <= req;
                for (st = 2; st <= NP-1; st = st + 1) vldp[st] <= vldp[st-1];
                //  stage 1: latch the (live, computed-at-req) operands + control
                if (req) begin r_amf <= a_mfull; r_bmf <= b_mfull; end
                r_exp[1]   <= exp_sum_pre;
                r_rsign[1] <= res_sign;
                r_spec[1]  <= special_active;
                r_sres[1]  <= special_res;
                r_sflag[1] <= special_flags;
                r_orm[1]   <= rm;
                //  stage 2: the 53x53 multiply (from stage-1 operands)
                r_prod[2]  <= r_amf * r_bmf;
                r_exp[2]   <= r_exp[1];
                r_rsign[2] <= r_rsign[1];
                r_spec[2]  <= r_spec[1];
                r_sres[2]  <= r_sres[1];
                r_sflag[2] <= r_sflag[1];
                r_orm[2]   <= r_orm[1];
                //  stages 3..NP-1: product + control passthrough (extra cascade regs)
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

    localparam NP_LAT = (D_MUL_PIPE < 3) ? 3 : D_MUL_PIPE;
    assign busy    = sm_busy;
    assign latency = (D_MUL_CYCLES != 1) ? 5'd31 :
                     (D_MUL_PIPE <= 1)   ? 5'd2  : NP_LAT[4:0];

    //  ---- Normalize / round / pack (subnormal-aware) ---- driven by eff_*
    wire        nshift = eff_prod[105];
    wire [52:0] sig53  = nshift ? eff_prod[105:53] : eff_prod[104:52];  //  leading at [52]
    wire        g_in   = nshift ? eff_prod[52]      : eff_prod[51];
    wire        r_in   = nshift ? eff_prod[51]      : eff_prod[50];
    wire        s_in   = nshift ? (|eff_prod[50:0]) : (|eff_prod[49:0]);
    wire signed [12:0] exp_n = eff_exp_sum_pre + {{12{1'b0}}, nshift};

    wire [56:0] norm = {sig53, g_in, r_in, 1'b0, s_in}; //  leading 1 at bit56

    wire signed [12:0] dshift_s = (exp_n <= 0) ? (13'sd1 - exp_n) : 13'sd0;
    wire [12:0] dshift  = dshift_s[12:0];
    wire [56:0] dn      = (dshift >= 13'd57) ? 57'b0 : (norm >> dshift);
    wire        dn_lost = (dshift == 0) ? 1'b0 :
                          (dshift >= 13'd57) ? (|norm) :
                          (|(norm & (~({57{1'b1}} << dshift))));

    wire [52:0] dsig  = dn[56:4];
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

    wire [53:0] mant_rnd  = {1'b0, dsig} + {53'b0, round_up};
    wire        rnd_carry = mant_rnd[53];
    wire        promote   = mant_rnd[52];
    wire        inexact   = round_bit || sticky;

    wire signed [12:0] exp_norm_final = exp_n + (rnd_carry ? 13'sd1 : 13'sd0);
    wire        over = !subnormal_region && (exp_norm_final >= 13'sd2047);

    wire nr_up =
        (eff_orm == `FRM_RNE) ? (g_in && (r_in || s_in || sig53[0])) :
        (eff_orm == `FRM_RTZ) ? 1'b0 :
        (eff_orm == `FRM_RDN) ? (eff_res_sign  && (g_in || r_in || s_in)) :
        (eff_orm == `FRM_RUP) ? (!eff_res_sign && (g_in || r_in || s_in)) :
        (eff_orm == `FRM_RMM) ? g_in :
                           1'b0;
    wire reaches_normal = (({1'b0, sig53} + {53'b0, nr_up}) >= 54'h20_0000_0000_0000);
    wire tiny_before = subnormal_region && ((exp_n <= -13'sd1) || !reaches_normal);

    wire [63:0] over_res =
        ((eff_orm == `FRM_RTZ) ||
         (eff_orm == `FRM_RDN && !eff_res_sign) ||
         (eff_orm == `FRM_RUP &&  eff_res_sign))
            ? {eff_res_sign, 11'h7FE, 52'hF_FFFF_FFFF_FFFF}
            : {eff_res_sign, 11'h7FF, 52'h0};

    wire [63:0] normal_res =
        over ? over_res :
        subnormal_region ? {eff_res_sign, (promote ? 11'd1 : 11'd0), mant_rnd[51:0]} :
                           {eff_res_sign, exp_norm_final[10:0], (rnd_carry ? 52'b0 : mant_rnd[51:0])};

    wire [4:0] normal_flags =
        (over                   ? ((5'b1 << `FF_OF) | (5'b1 << `FF_NX)) : 5'b0) |
        (tiny_before && inexact ? (5'b1 << `FF_UF)                      : 5'b0) |
        (inexact && !over       ? (5'b1 << `FF_NX)                      : 5'b0);

    wire [63:0] res_w   = eff_special_active ? eff_special_res   : normal_res;
    wire [4:0]  flags_w = eff_special_active ? eff_special_flags : normal_flags;

    //  ---- unified output register ----
    //  out_fire = the cycle res_w is valid to latch: `req` for the 1-cycle
    //  combinational fast path, else the variant's internal done strobe
    //  (bit-serial SS_FIN or the pipeline's last valid stage).
    wire out_fire = (D_MUL_CYCLES == 1 && D_MUL_PIPE <= 1) ? req : sm_done;
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
