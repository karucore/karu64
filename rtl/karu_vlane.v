//  karu_vlane.v
//  === one 64-bit (ELEN-wide) vector lane: the replicated vector-execute slice.
//
//  A vector register is VLEN bits = VLEN/64 contiguous 64-bit chunks; one
//  karu_vlane owns one chunk. karu_varith instantiates NLANES = VLEN/64 of these
//  via genvar (under (* keep_hierarchy *)) and assembles their per-chunk outputs,
//  so synthesis maps ONE lane and replicates it instead of choking on a flat
//  VLEN-wide all-element-parallel cone. The lane has TWO datapaths, mutually
//  exclusive in time (the core is single-issue):
//
//  1. INTEGER sub-word-SIMD ALU (combinational, the always block below): within
//     its 64 bits it processes 64/SEW elements in parallel (e8x8 / e16x4 /
//     e32x2 / e64x1), carry-killed at SEW boundaries. Covers the element-local,
//     normal-width ops: ALU, vmerge/vmv.v.*, vid, vmv.s.x, vadc/vsbc, fixed-point
//     (sat/avg/ssr/vsmul), Zvkb rotates/reversals, Zvbb element bit-reverse/
//     count and combinational mul/mac/div (gated by MUL_COMB/DIV_COMB -- when
//     the serial multiplier/divider is configured the parent
//     runs those and the lane's mul/div logic constant-folds away). Output:
    //     res_chunk (+ lane_sat). The element expressions match karu_varith's
    //     per-element arithmetic semantics.
//
//  2. A rolled-in scalar FP unit: one karu_fpu (F+D) + karu_vest7 (the
//     combinational 7-bit vfrec7/vfrsqrt7 estimate). The PARENT computes the
//     element operands and drives the standard req/busy/done handshake (the
//     fp_* ports); the lane just owns the FP hardware. karu_varith dispatches
//     element-wise FP across all NLANES lane FPUs in parallel, or sequences
//     cross-lane FP ops through lane 0 (see its FP-dispatch section).
//
//  Cross-lane / mask-producing / width-changing ops (compares->mask, reductions,
//  permute, widen/narrow, mask-logic, vfirst/vcpop/vmv.x.s, and all the FP
//  operand routing) do NOT live here -- they stay in karu_varith.

`include "karu_vcfg.vh"

(* keep_hierarchy = "yes" *)
module karu_vlane #(
    parameter integer MUL_COMB = 1,         //  1 = combinational mul/mac in-lane
    parameter integer DIV_COMB = 1          //  1 = combinational div in-lane
    //  Keep-old preservation is controlled by the parent's exact-write-set
    //  byte enables (gwbe_*); this lane always returns the raw element bytes.
    //  vold_chunk feeds only the MAC path.
) (
    input  wire        clk,
    input  wire        rst,
    //  this lane's 64 bits of each VRF read
    input  wire [63:0] vs2_chunk,
    input  wire [63:0] vs1_chunk,
    input  wire [63:0] vold_chunk,
    //  scalar / immediate operands (broadcast, same to every lane)
    input  wire [63:0] rs1_v,
    input  wire [63:0] imm,
    //  decode (broadcast)
    input  wire [5:0]  f6,
    input  wire [2:0]  vsew,
    input  wire [1:0]  vxrm,
    input  wire        b_vv, b_vx, b_vi,
    input  wire        is_mul, is_div, is_mac, is_mvmerge, is_vid, is_vmvsx,
    input  wire        is_carry_e, is_satadd, is_avg, is_vssr, is_vsmul,
    input  wire        is_brev8, is_rev8,   //  Zvkb VXUNARY0 reversals (0 when no Zvkb)
    input  wire        is_brev, is_vclz, is_vctz, is_vcpop, //  remaining Zvbb VXUNARY0
    input  wire        mv_is_vv,
    input  wire [63:0] mv_splat,
    //  per-lane predicate context
    input  wire        vm,              //  1 = unmasked
    input  wire [7:0]  v0_bits,         //  v0 mask bit per sub-element of this lane
    input  wire [31:0] vl,              //  vl_q
    input  wire [31:0] eg_base,         //  global element index of sub-element 0
    //  ---- FP datapath (operands supplied by the parent shell) ----
    //  The lane carries one scalar FP unit (karu_fpu) + the combinational
    //  7-bit estimate (karu_vest7).  The parent computes the element operands
    //  (element-wise parallel dispatch across lanes, or sequential through one
    //  lane for cross-lane FP ops) and drives the standard req/busy/done
    //  handshake.  Integer and FP never run together (single-issue), so the
    //  lane's two datapaths are mutually exclusive in time.
    input  wire        fp_req,
    input  wire [4:0]  fp_sub,          //  karu_fpu sub-op (FOP_*)
    input  wire        fp_is_d,
    input  wire [2:0]  fp_rm,
    input  wire [63:0] fp_op1,
    input  wire [63:0] fp_op2,
    input  wire [63:0] fp_op3,
    input  wire        fp_is_rec,       //  vest7: 1=vfrec7, 0=vfrsqrt7 (a = fp_op1)
    output wire        fp_busy,
    output wire        fp_done,
    output wire [63:0] fp_res,
    output wire [4:0]  fp_flags,
    output wire [63:0] est_res,         //  combinational 7-bit estimate of fp_op1
    output wire [4:0]  est_flags,
    //  outputs
    output reg  [63:0] res_chunk,
    output reg         lane_sat
);
    //  ==================================================================
    //  (1) integer sub-word-SIMD datapath (combinational)
    //  ==================================================================
    wire [6:0] sewb = 7'd8 << vsew;         //  bits/element
    wire [3:0] epc  = 4'd8 >> vsew;         //  elements per 64-bit chunk (e8->8 .. e64->1)

    //  sign-extend the low w bits of v to 64 (verbatim from karu_varith)
    function [63:0] sext;   input [63:0] v; input [6:0] w;
        sext = (w >= 7'd64) ? v : (v | (v[w-1] ? ({64{1'b1}} << w) : 64'h0));
    endfunction

`ifdef KARU_EN_ZVKB
    function [7:0] zvkb_bitrev8; input [7:0] v;
        zvkb_bitrev8 = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
    endfunction

    function [63:0] zvkb_brev8_word; input [63:0] v;
        zvkb_brev8_word = {
            zvkb_bitrev8(v[63:56]), zvkb_bitrev8(v[55:48]),
            zvkb_bitrev8(v[47:40]), zvkb_bitrev8(v[39:32]),
            zvkb_bitrev8(v[31:24]), zvkb_bitrev8(v[23:16]),
            zvkb_bitrev8(v[15:8]),  zvkb_bitrev8(v[7:0])
        };
    endfunction

    //  Reverse byte order independently within every element in this lane.
    //  Fixed slices are intentional: variable-width loop versions made the
    //  Yosys front end expand badly in earlier Zvk synthesis experiments.
    function [63:0] zvkb_rev8_chunk; input [63:0] v; input [2:0] ew;
        case (ew)
            3'd0: zvkb_rev8_chunk = v;
            3'd1: zvkb_rev8_chunk = {
                    v[55:48], v[63:56], v[39:32], v[47:40],
                    v[23:16], v[31:24], v[7:0],   v[15:8]};
            3'd2: zvkb_rev8_chunk = {
                    v[39:32], v[47:40], v[55:48], v[63:56],
                    v[7:0],   v[15:8],  v[23:16], v[31:24]};
            default: zvkb_rev8_chunk = {
                    v[7:0],   v[15:8],  v[23:16], v[31:24],
                    v[39:32], v[47:40], v[55:48], v[63:56]};
        endcase
    endfunction
`endif

`ifdef KARU_EN_ZVBB
    //  Bounded 8-bit leaves for the hierarchical count networks below. The
    //  largest element is assembled from byte/halfword/word results, giving
    //  logarithmic depth instead of the 64-step loop used by the scalar B unit.
    function [3:0] zvbb_pop8; input [7:0] v;
        reg [1:0] p0, p1, p2, p3; reg [2:0] q0, q1;
        begin
            p0 = v[0] + v[1]; p1 = v[2] + v[3];
            p2 = v[4] + v[5]; p3 = v[6] + v[7];
            q0 = {1'b0,p0} + {1'b0,p1}; q1 = {1'b0,p2} + {1'b0,p3};
            zvbb_pop8 = {1'b0,q0} + {1'b0,q1};
        end
    endfunction

    function [3:0] zvbb_clz8; input [7:0] v;
        begin
            casez (v)
                8'b1???????: zvbb_clz8 = 4'd0;
                8'b01??????: zvbb_clz8 = 4'd1;
                8'b001?????: zvbb_clz8 = 4'd2;
                8'b0001????: zvbb_clz8 = 4'd3;
                8'b00001???: zvbb_clz8 = 4'd4;
                8'b000001??: zvbb_clz8 = 4'd5;
                8'b0000001?: zvbb_clz8 = 4'd6;
                8'b00000001: zvbb_clz8 = 4'd7;
                default:     zvbb_clz8 = 4'd8;
            endcase
        end
    endfunction

    function [3:0] zvbb_ctz8; input [7:0] v;
        begin
            casez (v)
                8'b???????1: zvbb_ctz8 = 4'd0;
                8'b??????10: zvbb_ctz8 = 4'd1;
                8'b?????100: zvbb_ctz8 = 4'd2;
                8'b????1000: zvbb_ctz8 = 4'd3;
                8'b???10000: zvbb_ctz8 = 4'd4;
                8'b??100000: zvbb_ctz8 = 4'd5;
                8'b?1000000: zvbb_ctz8 = 4'd6;
                8'b10000000: zvbb_ctz8 = 4'd7;
                default:     zvbb_ctz8 = 4'd8;
            endcase
        end
    endfunction

    wire [3:0] zvbb_pc8 [0:7], zvbb_lz8 [0:7], zvbb_tz8 [0:7];
    wire [4:0] zvbb_pc16[0:3], zvbb_lz16[0:3], zvbb_tz16[0:3];
    wire [5:0] zvbb_pc32[0:1], zvbb_lz32[0:1], zvbb_tz32[0:1];
    wire [6:0] zvbb_pc64, zvbb_lz64, zvbb_tz64;
    genvar ZB8, ZB16, ZB32;
    generate
        for (ZB8 = 0; ZB8 < 8; ZB8 = ZB8 + 1) begin : g_zvbb_byte_count
            assign zvbb_pc8[ZB8] = zvbb_pop8(vs2_chunk[ZB8*8 +: 8]);
            assign zvbb_lz8[ZB8] = zvbb_clz8(vs2_chunk[ZB8*8 +: 8]);
            assign zvbb_tz8[ZB8] = zvbb_ctz8(vs2_chunk[ZB8*8 +: 8]);
        end
        for (ZB16 = 0; ZB16 < 4; ZB16 = ZB16 + 1) begin : g_zvbb_half_count
            assign zvbb_pc16[ZB16] = {1'b0,zvbb_pc8[2*ZB16]} + {1'b0,zvbb_pc8[2*ZB16+1]};
            assign zvbb_lz16[ZB16] = (|vs2_chunk[ZB16*16+8 +: 8])
                    ? {1'b0,zvbb_lz8[2*ZB16+1]}
                    : 5'd8 + {1'b0,zvbb_lz8[2*ZB16]};
            assign zvbb_tz16[ZB16] = (|vs2_chunk[ZB16*16 +: 8])
                    ? {1'b0,zvbb_tz8[2*ZB16]}
                    : 5'd8 + {1'b0,zvbb_tz8[2*ZB16+1]};
        end
        for (ZB32 = 0; ZB32 < 2; ZB32 = ZB32 + 1) begin : g_zvbb_word_count
            assign zvbb_pc32[ZB32] = {1'b0,zvbb_pc16[2*ZB32]} + {1'b0,zvbb_pc16[2*ZB32+1]};
            assign zvbb_lz32[ZB32] = (|vs2_chunk[ZB32*32+16 +: 16])
                    ? {1'b0,zvbb_lz16[2*ZB32+1]}
                    : 6'd16 + {1'b0,zvbb_lz16[2*ZB32]};
            assign zvbb_tz32[ZB32] = (|vs2_chunk[ZB32*32 +: 16])
                    ? {1'b0,zvbb_tz16[2*ZB32]}
                    : 6'd16 + {1'b0,zvbb_tz16[2*ZB32+1]};
        end
    endgenerate
    assign zvbb_pc64 = {1'b0,zvbb_pc32[0]} + {1'b0,zvbb_pc32[1]};
    assign zvbb_lz64 = (|vs2_chunk[63:32]) ? {1'b0,zvbb_lz32[1]}
                                           : 7'd32 + {1'b0,zvbb_lz32[0]};
    assign zvbb_tz64 = (|vs2_chunk[31:0])  ? {1'b0,zvbb_tz32[0]}
                                           : 7'd32 + {1'b0,zvbb_tz32[1]};

    reg [63:0] zvbb_pc_word, zvbb_lz_word, zvbb_tz_word;
    always @(*) begin
        zvbb_pc_word = 64'b0; zvbb_lz_word = 64'b0; zvbb_tz_word = 64'b0;
        case (vsew)
            3'd0: begin
                zvbb_pc_word = {{4'b0,zvbb_pc8[7]}, {4'b0,zvbb_pc8[6]},
                                {4'b0,zvbb_pc8[5]}, {4'b0,zvbb_pc8[4]},
                                {4'b0,zvbb_pc8[3]}, {4'b0,zvbb_pc8[2]},
                                {4'b0,zvbb_pc8[1]}, {4'b0,zvbb_pc8[0]}};
                zvbb_lz_word = {{4'b0,zvbb_lz8[7]}, {4'b0,zvbb_lz8[6]},
                                {4'b0,zvbb_lz8[5]}, {4'b0,zvbb_lz8[4]},
                                {4'b0,zvbb_lz8[3]}, {4'b0,zvbb_lz8[2]},
                                {4'b0,zvbb_lz8[1]}, {4'b0,zvbb_lz8[0]}};
                zvbb_tz_word = {{4'b0,zvbb_tz8[7]}, {4'b0,zvbb_tz8[6]},
                                {4'b0,zvbb_tz8[5]}, {4'b0,zvbb_tz8[4]},
                                {4'b0,zvbb_tz8[3]}, {4'b0,zvbb_tz8[2]},
                                {4'b0,zvbb_tz8[1]}, {4'b0,zvbb_tz8[0]}};
            end
            3'd1: begin
                zvbb_pc_word = {{11'b0,zvbb_pc16[3]}, {11'b0,zvbb_pc16[2]},
                                {11'b0,zvbb_pc16[1]}, {11'b0,zvbb_pc16[0]}};
                zvbb_lz_word = {{11'b0,zvbb_lz16[3]}, {11'b0,zvbb_lz16[2]},
                                {11'b0,zvbb_lz16[1]}, {11'b0,zvbb_lz16[0]}};
                zvbb_tz_word = {{11'b0,zvbb_tz16[3]}, {11'b0,zvbb_tz16[2]},
                                {11'b0,zvbb_tz16[1]}, {11'b0,zvbb_tz16[0]}};
            end
            3'd2: begin
                zvbb_pc_word = {{26'b0,zvbb_pc32[1]}, {26'b0,zvbb_pc32[0]}};
                zvbb_lz_word = {{26'b0,zvbb_lz32[1]}, {26'b0,zvbb_lz32[0]}};
                zvbb_tz_word = {{26'b0,zvbb_tz32[1]}, {26'b0,zvbb_tz32[0]}};
            end
            default: begin
                zvbb_pc_word = {57'b0,zvbb_pc64};
                zvbb_lz_word = {57'b0,zvbb_lz64};
                zvbb_tz_word = {57'b0,zvbb_tz64};
            end
        endcase
    end
`endif

    integer j, bb;
    reg [63:0]  ea, eb, au, bu, as, bs, smask, alu, mres, shamt;
    reg [63:0]  cu, macmul, macadd, macres;
    reg [127:0] pu, ps, psu;
    reg [64:0]  cy_add, cy_sub; reg cin;
    reg [63:0]  bden, divres;   reg dz, aneg, bneg;
    reg [63:0]  maga, magb, quotm, remm;
    reg [63:0]  umax_pat, smax_pat, smin_pat;
    reg [64:0]  usum, sadd, ssub, sres; reg [63:0] satres;  reg sat;
    reg [127:0] avg_v;  reg [63:0] avg_res; reg avg_rb, avg_lsb, avg_rnd;
    reg [63:0]  sh_v, sh_sh, ssr_res;   reg sh_dmsb, sh_stk, sh_lsb, sh_rnd;
    reg [127:0] sm_prod;    reg [63:0] sm_sh, sm_res0, sm_res;
    reg sm_dmsb, sm_stk, sm_lsb, sm_rnd, sm_sat;
    reg         el_sat;
    reg [63:0]  eres;   reg [31:0] eg;  reg active;
`ifdef KARU_EN_ZVKB
    reg [63:0]  zvkb_r, zvkb_ror, zvkb_rol, zvbb_elem;
`endif

    //  KARU_V_LANE_PIPE: 2-stage lane. Stage A extracts the SEW-decoded per-element
    //  operands + LOCAL geometry and ALL stage-B control/predicate inputs;
    //  an optional register boundary; stage B does arith + select + assemble.
    //  In particular, raw v0_bits depends on the parent's SEW-dependent mask
    //  selection. It must not bypass this boundary into the carry arithmetic.
    //  Knob off => the boundary is a wire (single combinational cycle). When on, the
    //  parent (karu_varith S_RUN) samples grp_res one cycle later.
    reg [63:0] auA[0:7], buA[0:7], asA[0:7], bsA[0:7], shA[0:7];
    reg [31:0] egA[0:7];  reg actA[0:7];
    reg [6:0]  sewbA;  reg [3:0] epcA;  reg [63:0] smaskA, voldA;
    reg [63:0] auP[0:7], buP[0:7], asP[0:7], bsP[0:7], shP[0:7];
    reg [31:0] egP[0:7];  reg actP[0:7];
    reg [6:0]  sewbP;  reg [3:0] epcP;  reg [63:0] smaskP, voldP;
    reg [5:0] f6P;
    reg [1:0] vxrmP;
    reg [4:0] immP;
    reg [63:0] rs1P, mv_splatP;
    reg [31:0] vlP;
    reg [7:0] v0P;
    reg b_viP, vmP, mv_is_vvP;
    reg is_mulP, is_divP, is_macP, is_mvmergeP, is_vidP, is_vmvsxP;
    reg is_carry_eP, is_sataddP, is_avgP, is_vssrP, is_vsmulP;
`ifdef KARU_EN_ZVKB
    reg [63:0] zvbbA, zvbbP;
    reg zvbb_unaryP;
    wire zvbb_unary = is_brev8 || is_rev8 || is_brev || is_vclz || is_vctz || is_vcpop;
    always @(*) begin
        zvbbA = 64'b0;
        if (is_brev8)      zvbbA = zvkb_brev8_word(vs2_chunk);
        else if (is_rev8)  zvbbA = zvkb_rev8_chunk(vs2_chunk, vsew);
`ifdef KARU_EN_ZVBB
        else if (is_brev)  zvbbA = zvkb_rev8_chunk(zvkb_brev8_word(vs2_chunk), vsew);
        else if (is_vclz)  zvbbA = zvbb_lz_word;
        else if (is_vctz)  zvbbA = zvbb_tz_word;
        else if (is_vcpop) zvbbA = zvbb_pc_word;
`endif
    end
`endif
    integer ja, jp;

    //  ==================================================================
    //  (1) INTEGER sub-word-SIMD ALU (2-stage pipeline-capable; see above)
    //  ==================================================================
    //  -- STAGE A: SEW decode + per-element operand extract --
    always @(*) begin
        smaskA = (sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
        sewbA = sewb;  epcA = epc;  voldA = vold_chunk;
        for (ja = 0; ja < 8; ja = ja + 1) begin
            egA[ja]  = eg_base + ja[31:0];
            actA[ja] = is_vmvsx ? (egA[ja] == 32'd0) : is_carry_e ? 1'b1 : (vm || v0_bits[ja[2:0]]);
            auA[ja]  = (vs2_chunk >> (ja*sewb)) & ~smaskA;
            buA[ja]  = b_vv ? ((vs1_chunk >> (ja*sewb)) & ~smaskA) :
                       b_vx ? (rs1_v & ~smaskA) : (imm & ~smaskA);
            asA[ja]  = sext(auA[ja], sewb);  bsA[ja] = sext(buA[ja], sewb);
            shA[ja]  = (b_vi ? {59'b0, imm[4:0]} : buA[ja]) & ({57'b0, sewb} - 64'd1);
        end
    end
    //  -- pipeline boundary (register when KARU_V_LANE_PIPE, else wire) --
`ifdef KARU_V_LANE_PIPE
    always @(posedge clk) begin
        sewbP <= sewbA; epcP <= epcA; smaskP <= smaskA; voldP <= voldA;
        {f6P, vxrmP, immP, rs1P, mv_splatP, vlP, v0P, b_viP, vmP, mv_is_vvP,
         is_mulP, is_divP, is_macP, is_mvmergeP, is_vidP, is_vmvsxP,
         is_carry_eP, is_sataddP, is_avgP, is_vssrP, is_vsmulP} <=
        {f6, vxrm, imm[4:0], rs1_v, mv_splat, vl, v0_bits, b_vi, vm, mv_is_vv,
         is_mul, is_div, is_mac, is_mvmerge, is_vid, is_vmvsx,
         is_carry_e, is_satadd, is_avg, is_vssr, is_vsmul};
`ifdef KARU_EN_ZVKB
        zvbbP <= zvbbA;
        zvbb_unaryP <= zvbb_unary;
`endif
        for (jp = 0; jp < 8; jp = jp + 1) begin
            auP[jp]<=auA[jp]; buP[jp]<=buA[jp]; asP[jp]<=asA[jp]; bsP[jp]<=bsA[jp];
            shP[jp]<=shA[jp]; egP[jp]<=egA[jp]; actP[jp]<=actA[jp];
        end
    end
`else
    always @(*) begin
        sewbP = sewbA; epcP = epcA; smaskP = smaskA; voldP = voldA;
        {f6P, vxrmP, immP, rs1P, mv_splatP, vlP, v0P, b_viP, vmP, mv_is_vvP,
         is_mulP, is_divP, is_macP, is_mvmergeP, is_vidP, is_vmvsxP,
         is_carry_eP, is_sataddP, is_avgP, is_vssrP, is_vsmulP} =
        {f6, vxrm, imm[4:0], rs1_v, mv_splat, vl, v0_bits, b_vi, vm, mv_is_vv,
         is_mul, is_div, is_mac, is_mvmerge, is_vid, is_vmvsx,
         is_carry_e, is_satadd, is_avg, is_vssr, is_vsmul};
`ifdef KARU_EN_ZVKB
        zvbbP = zvbbA;
        zvbb_unaryP = zvbb_unary;
`endif
        for (jp = 0; jp < 8; jp = jp + 1) begin
            auP[jp]=auA[jp]; buP[jp]=buA[jp]; asP[jp]=asA[jp]; bsP[jp]=bsA[jp];
            shP[jp]=shA[jp]; egP[jp]=egA[jp]; actP[jp]=actA[jp];
        end
    end
`endif
    //  -- STAGE B: arithmetic + result-select + byte-assemble --
    always @(*) begin
        res_chunk = voldP;          //  default: undisturbed
        lane_sat  = 1'b0;
        ea=0; eb=0; au=0; bu=0; as=0; bs=0; smask=0; alu=0; mres=0; shamt=0;
        cu=0; macmul=0; macadd=0; macres=0; cy_add=0; cy_sub=0; cin=0;
        bden=0; divres=0; dz=0; aneg=0; bneg=0; maga=0; magb=0; quotm=0; remm=0;
        pu=0; ps=0; psu=0; eres=0; eg=0; active=0;
        umax_pat=0; smax_pat=0; smin_pat=0; usum=0; sadd=0; ssub=0; sres=0;
        satres=0; sat=0; avg_v=0; avg_res=0; avg_rb=0; avg_lsb=0; avg_rnd=0;
        sh_v=0; sh_sh=0; ssr_res=0; sh_dmsb=0; sh_stk=0; sh_lsb=0; sh_rnd=0;
        sm_prod=0; sm_sh=0; sm_res0=0; sm_res=0; sm_dmsb=0; sm_stk=0; sm_lsb=0;
        sm_rnd=0; sm_sat=0; el_sat=0;
`ifdef KARU_EN_ZVKB
        zvkb_r=0; zvkb_ror=0; zvkb_rol=0; zvbb_elem=0;
`endif
        for (j = 0; j < 8; j = j + 1) begin
            if (j < epcP) begin
                au = auP[j]; bu = buP[j]; as = asP[j]; bs = bsP[j];
                shamt = shP[j]; eg = egP[j]; active = actP[j]; smask = smaskP;
`ifdef KARU_EN_ZVKB
                //  -- Zvkb rotates + packed Zvbb unary result --
                //  vror.vi carries uimm[5] in f6P[0] (funct6 01010x), so the .vi
                //  rotate amount is 6 bits; .vv/.vx use the element/scalar like
                //  the shifts. Shift-by-sewbP is well-defined here (<= 64 on a
                //  64-bit operand -> 0), so the r==0 wrap term vanishes.
                zvkb_r   = (b_viP ? {58'b0, f6P[0], immP[4:0]} : bu) & ({57'b0, sewbP} - 64'd1);
                zvkb_ror = ((au >> zvkb_r) | (au << ({57'b0, sewbP} - zvkb_r))) & ~smask;
                zvkb_rol = ((au << zvkb_r) | (au >> ({57'b0, sewbP} - zvkb_r))) & ~smask;
                zvbb_elem = (zvbbP >> (j*sewbP)) & ~smask;
`endif
                //  -- ALU --
                case (f6P)
                    6'b000000: alu = au + bu;                   //  vadd
                    6'b000010: alu = au - bu;                   //  vsub
                    6'b000011: alu = bu - au;                   //  vrsub
                    6'b001001: alu = au & bu;                   //  vand
                    6'b001010: alu = au | bu;                   //  vor
                    6'b001011: alu = au ^ bu;                   //  vxor
                    6'b100101: alu = au << shamt;               //  vsll
                    6'b101000: alu = au >> shamt;               //  vsrl
                    6'b101001: alu = $signed(as) >>> shamt;     //  vsra
                    6'b000100: alu = (au < bu) ? au : bu;       //  vminu
                    6'b000101: alu = ($signed(as) < $signed(bs)) ? au : bu; //  vmin
                    6'b000110: alu = (au > bu) ? au : bu;       //  vmaxu
                    6'b000111: alu = ($signed(as) > $signed(bs)) ? au : bu; //  vmax
`ifdef KARU_EN_ZVKB
                    6'b000001: alu = au & ~bu;                  //  vandn
                    6'b010100: alu = zvkb_ror;                  //  vror (.vi uimm[5]=0)
                    6'b010101: alu = b_viP ? zvkb_ror : zvkb_rol;    //  vrol; OPIVI = vror.vi uimm[5]=1
`endif
                    default:   alu = au;
                endcase
                //  -- MUL / MAC (combinational only when MUL_COMB) --
                if (MUL_COMB == 1) begin
                    pu  = au * bu;
                    ps  = $signed({{64{as[63]}}, as}) * $signed({{64{bs[63]}}, bs});
                    psu = $signed({{64{as[63]}}, as}) * {64'b0, bu};
                    case (f6P[1:0])
                        2'b01: mres = pu[63:0];                     //  vmul
                        2'b11: mres = ps  >> sewbP;                 //  vmulh
                        2'b00: mres = pu  >> sewbP;                 //  vmulhu
                        default: mres = psu >> sewbP;               //  vmulhsu
                    endcase
                    cu     = (voldP >> (j*sewbP)) & ~smask;
                    macmul = f6P[2] ? (bu * au) : (bu * cu);
                    macadd = f6P[2] ? cu : au;
                    macres = f6P[1] ? (macadd - macmul) : (macadd + macmul);
                end
                //  -- carry/borrow --
                cin    = vmP ? 1'b0 : v0P[j[2:0]];
                cy_add = {1'b0, au} + {1'b0, bu} + {64'b0, cin};
                cy_sub = {1'b0, au} - {1'b0, bu} - {64'b0, cin};
                //  -- divide (combinational only when DIV_COMB) --
                if (DIV_COMB == 1) begin
                    dz    = (bu == 64'd0);
                    bden  = dz ? 64'd1 : bu;
                    aneg  = as[63]; bneg = bs[63];
                    maga  = aneg ? (~as + 64'd1) : as;
                    magb  = (dz) ? 64'd1 : (bneg ? (~bs + 64'd1) : bs);
                    quotm = maga / magb;
                    remm  = maga % magb;
                    divres = f6P[1]
                        ? (f6P[0] ? (dz ? au : (aneg ? (~remm + 64'd1) : remm))
                                 : (dz ? au : (au % bden)))
                        : (f6P[0] ? (dz ? {64{1'b1}} : ((aneg^bneg) ? (~quotm + 64'd1) : quotm))
                                 : (dz ? {64{1'b1}} : (au / bden)));
                end
                //  -- fixed-point clamp patterns --
                umax_pat = ~smask;
                smax_pat = (~smask) >> 1;
                smin_pat = smax_pat + 64'd1;
                //  -- saturating add/sub --
                usum = {1'b0, au} + {1'b0, bu};
                sadd = $signed({as[63], as}) + $signed({bs[63], bs});
                ssub = $signed({as[63], as}) - $signed({bs[63], bs});
                sat  = 1'b0;    satres = 64'd0;
                if (is_sataddP) begin
                    if (!f6P[0]) begin
                        if (!f6P[1]) begin           //  vsaddu
                            sat    = usum[sewbP];
                            satres = sat ? umax_pat : usum[63:0];
                        end else begin              //  vssubu
                            sat    = (au < bu);
                            satres = sat ? 64'd0 : (au - bu);
                        end
                    end else begin
                        sres = f6P[1] ? ssub : sadd;
                        if ($signed(sres) > $signed({1'b0, smax_pat}))
                            begin sat=1'b1; satres = smax_pat; end
                        else if ($signed(sres) < $signed(-{1'b0, smin_pat}))
                            begin sat=1'b1; satres = smin_pat; end
                        else satres = sres[63:0];
                    end
                end
                //  -- averaging --
                if (is_avgP) begin
                    if (!f6P[0])
                        avg_v = (f6P[1] ? ({64'b0, au} - {64'b0, bu})
                                        : ({64'b0, au} + {64'b0, bu}))
                                & ((128'd1 << (sewbP + 7'd1)) - 128'd1);
                    else
                        avg_v = f6P[1]
                            ? ($signed({{64{as[63]}}, as}) - $signed({{64{bs[63]}}, bs}))
                            : ($signed({{64{as[63]}}, as}) + $signed({{64{bs[63]}}, bs}));
                    avg_rb  = avg_v[0];
                    avg_lsb = avg_v[1];
                    case (vxrmP)
                        2'b00: avg_rnd = avg_rb;
                        2'b01: avg_rnd = avg_rb & avg_lsb;
                        2'b10: avg_rnd = 1'b0;
                        default: avg_rnd = ~avg_lsb & avg_rb;
                    endcase
                    if (f6P[0]) avg_res = ($signed(avg_v) >>> 1) + {63'b0, avg_rnd};
                    else       avg_res = (avg_v >> 1) + {63'b0, avg_rnd};
                end
                //  -- scaling shift right --
                if (is_vssrP) begin
                    sh_v   = f6P[0] ? as : au;
                    if (f6P[0]) sh_sh = $signed(as) >>> shamt;
                    else       sh_sh = au >> shamt;
                    sh_dmsb = (shamt == 0) ? 1'b0 : ((sh_v >> (shamt - 64'd1)) & 64'd1);
                    sh_stk  = (shamt <= 1) ? 1'b0
                            : ((sh_v & ((64'd1 << (shamt - 64'd1)) - 64'd1)) != 0);
                    sh_lsb  = sh_sh[0];
                    case (vxrmP)
                        2'b00: sh_rnd = sh_dmsb;
                        2'b01: sh_rnd = sh_dmsb & (sh_stk | sh_lsb);
                        2'b10: sh_rnd = 1'b0;
                        default: sh_rnd = (shamt != 0) & ~sh_lsb & (sh_dmsb | sh_stk);
                    endcase
                    ssr_res = sh_sh + {63'b0, sh_rnd};
                end
                //  -- vsmul --
                if (is_vsmulP) begin
                    sm_prod = ps;
                    sm_sh   = $signed(sm_prod) >>> (sewbP - 7'd1);
                    sm_dmsb = (sewbP < 2) ? 1'b0 : ((sm_prod >> (sewbP - 7'd2)) & 128'd1);
                    sm_stk  = (sewbP < 3) ? 1'b0
                            : ((sm_prod & ((128'd1 << (sewbP - 7'd2)) - 128'd1)) != 0);
                    sm_lsb  = sm_sh[0];
                    case (vxrmP)
                        2'b00: sm_rnd = sm_dmsb;
                        2'b01: sm_rnd = sm_dmsb & (sm_stk | sm_lsb);
                        2'b10: sm_rnd = 1'b0;
                        default: sm_rnd = ~sm_lsb & (sm_dmsb | sm_stk);
                    endcase
                    sm_res0 = sm_sh + {63'b0, sm_rnd};
                    // The sole fractional-multiply overflow is MIN * MIN.
                    // Test operands before the e64 shifted product can wrap.
                    if (au == smin_pat && bu == smin_pat)
                        begin sm_sat=1'b1; sm_res = smax_pat; end
                    else begin sm_sat=1'b0; sm_res = sm_res0; end
                end
                //  -- result selection --
                if (is_mulP)            eres = mres;
                else if (is_divP)       eres = divres;
                else if (is_sataddP)    eres = satres;
                else if (is_avgP)       eres = avg_res;
                else if (is_vssrP)      eres = ssr_res;
                else if (is_vsmulP)     eres = sm_res;
                else if (is_macP)       eres = macres;
                else if (is_carry_eP)   eres = f6P[1] ? cy_sub[63:0] : cy_add[63:0];
                else if (is_vmvsxP)     eres = rs1P;
                else if (is_mvmergeP)
                    eres = (vmP || v0P[j[2:0]]) ? (mv_is_vvP ? bu : mv_splatP) : au;
                else if (is_vidP)       eres = {32'b0, eg};
`ifdef KARU_EN_ZVKB
                else if (zvbb_unaryP)    eres = zvbb_elem;
`endif
                else                   eres = alu;
                //  saturation flag: active in-vlP elements only
                el_sat = active && (eg < vlP)
                       && ((is_sataddP & sat) | (is_vsmulP & sm_sat));
                if (el_sat) lane_sat = 1'b1;
                //  -- write with mask/tail policy (per byte of the element) --
                //  Every byte gets the raw element result; tail/masked-off
                //  keep-old is represented by the parent's exact-write-set
                //  byte enables (gwbe_*).
                for (bb = 0; bb < 8; bb = bb + 1) begin
                    if (bb < (sewbP >> 3))
                        res_chunk[(j*(sewbP>>3)+bb)*8 +: 8] = eres[bb*8 +: 8];
                end
            end
        end
    end

    //  ==================================================================
    //  (2) rolled-in scalar FP unit + combinational 7-bit estimate.
    //  Operands and the req/done handshake are driven by karu_varith (per-lane
    //  for element-wise FP, lane 0 for cross-lane FP); is_d picks F vs D.
    //  ==================================================================
    //  is_h is the scalar Zfhmin fmv.x.h/fmv.h.x selector; the vector FP path
    //  never issues those, so it is tied low here.
    //  With lane pipelining, stage the complete FPU request as well. This
    //  separates parent operand selection / exact widening conversion from
    //  the FPU's input normalization. One fixed dispatch cycle is added to
    //  FPU operations; the combinational estimate path remains unchanged.
    wire fpu_req, fpu_busy;
    wire [4:0] fpu_sub;
    wire [2:0] fpu_rm;
    wire fpu_is_d;
    wire [63:0] fpu_op1, fpu_op2, fpu_op3;
`ifdef KARU_V_LANE_PIPE
    reg fp_reqP;
    reg [4:0] fp_subP;
    reg [2:0] fp_rmP;
    reg fp_is_dP;
    reg [63:0] fp_op1P, fp_op2P, fp_op3P;
    always @(posedge clk) begin
        if (rst) fp_reqP <= 1'b0;
        else fp_reqP <= fp_req;
        if (fp_req) begin
            fp_subP <= fp_sub; fp_rmP <= fp_rm; fp_is_dP <= fp_is_d;
            fp_op1P <= fp_op1; fp_op2P <= fp_op2; fp_op3P <= fp_op3;
        end
    end
    assign fpu_req = fp_reqP;
    assign fpu_sub = fp_subP;
    assign fpu_rm = fp_rmP;
    assign fpu_is_d = fp_is_dP;
    assign fpu_op1 = fp_op1P; assign fpu_op2 = fp_op2P; assign fpu_op3 = fp_op3P;
    // Include the waiting request so the parent's active/busy accounting
    // has no gap before the FPU accepts it.
    assign fp_busy = fp_reqP | fpu_busy;
`else
    assign fpu_req = fp_req;
    assign fpu_sub = fp_sub;
    assign fpu_rm = fp_rm;
    assign fpu_is_d = fp_is_d;
    assign fpu_op1 = fp_op1; assign fpu_op2 = fp_op2; assign fpu_op3 = fp_op3;
    assign fp_busy = fpu_busy;
`endif
    karu_fpu u_fpu (
        .clk(clk), .rst(rst),
        .req(fpu_req), .busy(fpu_busy), .sub(fpu_sub), .rm(fpu_rm), .is_d(fpu_is_d),
        .is_h(1'b0), .fp_zfa(4'd0), //  scalar-only Zfhmin/Zfa selectors unused in lanes
        .op1(fpu_op1), .op2(fpu_op2), .op3(fpu_op3),
        .done(fp_done), .res(fp_res), .fflags(fp_flags)
    );
    karu_vest7 u_est (
        .a(fp_op1), .is_d(fp_is_d), .is_rec(fp_is_rec), .rm(fp_rm),
        .res(est_res), .flags(est_flags)
    );
endmodule
