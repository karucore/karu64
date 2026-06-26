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
//     (sat/avg/ssr/vsmul), and combinational mul/mac/div (gated by MUL_COMB/
//     DIV_COMB -- when the serial multiplier/divider is configured the parent
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

    function [63:0] zvkb_rev8_elem; input [63:0] v; input [6:0] w;
        case (w)
            7'd8:    zvkb_rev8_elem = {56'b0, v[7:0]};
            7'd16:   zvkb_rev8_elem = {48'b0, v[7:0], v[15:8]};
            7'd32:   zvkb_rev8_elem = {32'b0, v[7:0], v[15:8], v[23:16], v[31:24]};
            default: zvkb_rev8_elem = {v[7:0], v[15:8], v[23:16], v[31:24],
                                       v[39:32], v[47:40], v[55:48], v[63:56]};
        endcase
    endfunction
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
    reg [63:0]  zvkb_r, zvkb_ror, zvkb_rol, zvkb_rev;
`endif

    //  KARU_V_LANE_PIPE: 2-stage lane. Stage A extracts the SEW-decoded per-element
    //  operands + LOCAL sewbP/smaskP/epcP/voldP (killing the high-fanout vsew net in
    //  stage B); an optional register boundary; stage B does arith + select + assemble.
    //  Knob off => the boundary is a wire (single combinational cycle). When on, the
    //  parent (karu_varith S_RUN) samples grp_res one cycle later.
    reg [63:0] auA[0:7], buA[0:7], asA[0:7], bsA[0:7], shA[0:7];
    reg [31:0] egA[0:7];  reg actA[0:7];
    reg [6:0]  sewbA;  reg [3:0] epcA;  reg [63:0] smaskA, voldA;
    reg [63:0] auP[0:7], buP[0:7], asP[0:7], bsP[0:7], shP[0:7];
    reg [31:0] egP[0:7];  reg actP[0:7];
    reg [6:0]  sewbP;  reg [3:0] epcP;  reg [63:0] smaskP, voldP;
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
        for (jp = 0; jp < 8; jp = jp + 1) begin
            auP[jp]<=auA[jp]; buP[jp]<=buA[jp]; asP[jp]<=asA[jp]; bsP[jp]<=bsA[jp];
            shP[jp]<=shA[jp]; egP[jp]<=egA[jp]; actP[jp]<=actA[jp];
        end
    end
`else
    always @(*) begin
        sewbP = sewbA; epcP = epcA; smaskP = smaskA; voldP = voldA;
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
        zvkb_r=0; zvkb_ror=0; zvkb_rol=0; zvkb_rev=0;
`endif
        for (j = 0; j < 8; j = j + 1) begin
            if (j < epcP) begin
                au = auP[j]; bu = buP[j]; as = asP[j]; bs = bsP[j];
                shamt = shP[j]; eg = egP[j]; active = actP[j]; smask = smaskP;
`ifdef KARU_EN_ZVKB
                //  -- Zvkb rotates + reversals --
                //  vror.vi carries uimm[5] in f6[0] (funct6 01010x), so the .vi
                //  rotate amount is 6 bits; .vv/.vx use the element/scalar like
                //  the shifts. Shift-by-sewbP is well-defined here (<= 64 on a
                //  64-bit operand -> 0), so the r==0 wrap term vanishes.
                zvkb_r   = (b_vi ? {58'b0, f6[0], imm[4:0]} : bu) & ({57'b0, sewbP} - 64'd1);
                zvkb_ror = ((au >> zvkb_r) | (au << ({57'b0, sewbP} - zvkb_r))) & ~smask;
                zvkb_rol = ((au << zvkb_r) | (au >> ({57'b0, sewbP} - zvkb_r))) & ~smask;
                zvkb_rev = is_rev8 ? zvkb_rev8_elem(au, sewbP) : zvkb_brev8_word(au);
`endif
                //  -- ALU --
                case (f6)
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
                    6'b010101: alu = b_vi ? zvkb_ror : zvkb_rol;    //  vrol; OPIVI = vror.vi uimm[5]=1
`endif
                    default:   alu = au;
                endcase
                //  -- MUL / MAC (combinational only when MUL_COMB) --
                if (MUL_COMB == 1) begin
                    pu  = au * bu;
                    ps  = $signed({{64{as[63]}}, as}) * $signed({{64{bs[63]}}, bs});
                    psu = $signed({{64{as[63]}}, as}) * {64'b0, bu};
                    case (f6[1:0])
                        2'b01: mres = pu[63:0];                     //  vmul
                        2'b11: mres = ps  >> sewbP;                 //  vmulh
                        2'b00: mres = pu  >> sewbP;                 //  vmulhu
                        default: mres = psu >> sewbP;               //  vmulhsu
                    endcase
                    cu     = (voldP >> (j*sewbP)) & ~smask;
                    macmul = f6[2] ? (bu * au) : (bu * cu);
                    macadd = f6[2] ? cu : au;
                    macres = f6[1] ? (macadd - macmul) : (macadd + macmul);
                end
                //  -- carry/borrow --
                cin    = vm ? 1'b0 : v0_bits[j[2:0]];
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
                    divres = f6[1]
                        ? (f6[0] ? (dz ? au : (aneg ? (~remm + 64'd1) : remm))
                                 : (dz ? au : (au % bden)))
                        : (f6[0] ? (dz ? {64{1'b1}} : ((aneg^bneg) ? (~quotm + 64'd1) : quotm))
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
                if (is_satadd) begin
                    if (!f6[0]) begin
                        if (!f6[1]) begin           //  vsaddu
                            sat    = usum[sewbP];
                            satres = sat ? umax_pat : usum[63:0];
                        end else begin              //  vssubu
                            sat    = (au < bu);
                            satres = sat ? 64'd0 : (au - bu);
                        end
                    end else begin
                        sres = f6[1] ? ssub : sadd;
                        if ($signed(sres) > $signed({1'b0, smax_pat}))
                            begin sat=1'b1; satres = smax_pat; end
                        else if ($signed(sres) < $signed(-{1'b0, smin_pat}))
                            begin sat=1'b1; satres = smin_pat; end
                        else satres = sres[63:0];
                    end
                end
                //  -- averaging --
                if (is_avg) begin
                    if (!f6[0])
                        avg_v = (f6[1] ? ({64'b0, au} - {64'b0, bu})
                                        : ({64'b0, au} + {64'b0, bu}))
                                & ((128'd1 << (sewbP + 7'd1)) - 128'd1);
                    else
                        avg_v = f6[1]
                            ? ($signed({{64{as[63]}}, as}) - $signed({{64{bs[63]}}, bs}))
                            : ($signed({{64{as[63]}}, as}) + $signed({{64{bs[63]}}, bs}));
                    avg_rb  = avg_v[0];
                    avg_lsb = avg_v[1];
                    case (vxrm)
                        2'b00: avg_rnd = avg_rb;
                        2'b01: avg_rnd = avg_rb & avg_lsb;
                        2'b10: avg_rnd = 1'b0;
                        default: avg_rnd = ~avg_lsb & avg_rb;
                    endcase
                    if (f6[0]) avg_res = ($signed(avg_v) >>> 1) + {63'b0, avg_rnd};
                    else       avg_res = (avg_v >> 1) + {63'b0, avg_rnd};
                end
                //  -- scaling shift right --
                if (is_vssr) begin
                    sh_v   = f6[0] ? as : au;
                    if (f6[0]) sh_sh = $signed(as) >>> shamt;
                    else       sh_sh = au >> shamt;
                    sh_dmsb = (shamt == 0) ? 1'b0 : ((sh_v >> (shamt - 64'd1)) & 64'd1);
                    sh_stk  = (shamt <= 1) ? 1'b0
                            : ((sh_v & ((64'd1 << (shamt - 64'd1)) - 64'd1)) != 0);
                    sh_lsb  = sh_sh[0];
                    case (vxrm)
                        2'b00: sh_rnd = sh_dmsb;
                        2'b01: sh_rnd = sh_dmsb & (sh_stk | sh_lsb);
                        2'b10: sh_rnd = 1'b0;
                        default: sh_rnd = (shamt != 0) & ~sh_lsb & (sh_dmsb | sh_stk);
                    endcase
                    ssr_res = sh_sh + {63'b0, sh_rnd};
                end
                //  -- vsmul --
                if (is_vsmul) begin
                    sm_prod = ps;
                    sm_sh   = $signed(sm_prod) >>> (sewbP - 7'd1);
                    sm_dmsb = (sewbP < 2) ? 1'b0 : ((sm_prod >> (sewbP - 7'd2)) & 128'd1);
                    sm_stk  = (sewbP < 3) ? 1'b0
                            : ((sm_prod & ((128'd1 << (sewbP - 7'd2)) - 128'd1)) != 0);
                    sm_lsb  = sm_sh[0];
                    case (vxrm)
                        2'b00: sm_rnd = sm_dmsb;
                        2'b01: sm_rnd = sm_dmsb & (sm_stk | sm_lsb);
                        2'b10: sm_rnd = 1'b0;
                        default: sm_rnd = ~sm_lsb & (sm_dmsb | sm_stk);
                    endcase
                    sm_res0 = sm_sh + {63'b0, sm_rnd};
                    if ($signed(sm_res0) > $signed({1'b0, smax_pat}))
                        begin sm_sat=1'b1; sm_res = smax_pat; end
                    else begin sm_sat=1'b0; sm_res = sm_res0; end
                end
                //  -- result selection --
                if (is_mul)            eres = mres;
                else if (is_div)       eres = divres;
                else if (is_satadd)    eres = satres;
                else if (is_avg)       eres = avg_res;
                else if (is_vssr)      eres = ssr_res;
                else if (is_vsmul)     eres = sm_res;
                else if (is_mac)       eres = macres;
                else if (is_carry_e)   eres = f6[1] ? cy_sub[63:0] : cy_add[63:0];
                else if (is_vmvsx)     eres = rs1_v;
                else if (is_mvmerge)
                    eres = (vm || v0_bits[j[2:0]]) ? (mv_is_vv ? bu : mv_splat) : au;
                else if (is_vid)       eres = {32'b0, eg};
`ifdef KARU_EN_ZVKB
                else if (is_brev8 | is_rev8) eres = zvkb_rev;
`endif
                else                   eres = alu;
                //  saturation flag: active in-vl elements only
                el_sat = active && (eg < vl)
                       && ((is_satadd & sat) | (is_vsmul & sm_sat));
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
    karu_fpu u_fpu (
        .clk(clk), .rst(rst),
        .req(fp_req), .busy(fp_busy), .sub(fp_sub), .rm(fp_rm), .is_d(fp_is_d),
        .is_h(1'b0), .fp_zfa(4'd0), //  scalar-only Zfhmin/Zfa selectors unused in lanes
        .op1(fp_op1), .op2(fp_op2), .op3(fp_op3),
        .done(fp_done), .res(fp_res), .fflags(fp_flags)
    );
    karu_vest7 u_est (
        .a(fp_op1), .is_d(fp_is_d), .is_rec(fp_is_rec), .rm(fp_rm),
        .res(est_res), .flags(est_flags)
    );
endmodule
