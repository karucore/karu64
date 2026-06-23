//  karu_varith.v
//  Vector integer/mask arithmetic core (lane datapath + group sequencer).
//  Multi-cycle: one register of the LMUL group per cycle (combinational VRF
//  read at the driven address, result written the same cycle). Decodes
//  directly from the forwarded (funct3, funct6, vs1-field, vm) -- the
//  "hub" interface -- so growing the op set is a datapath change here, not
//  a decoder rewrite (cf. doc/architecture.md).
//
//  Implemented (Stage 1: VALU + VMASK + VMUL):
//    OPIVV/OPIVX/OPIVI:
//      vadd vsub vrsub | vand vor vxor | vsll vsrl vsra |
//      vminu vmin vmaxu vmax | vmseq..vmsgt (compare->mask) |
//      vmerge / vmv.v.{i,x,v}
//    OPMVV/OPMVX:
//      vmul vmulh vmulhu vmulhsu | vm{and,andn,or,xor,orn,nand,nor,xnor}.mm |
//      vid.v | vfirst.m (->x)
//  Masking (vm=0) honoured for element-producing ops via v0; inactive ->
//  vma, tail -> vta. (Compares/mask-logic remain unmasked as the harness
//  uses them.) vstart is GUARANTEED 0 here: karu64 raises an illegal-
//  instruction exception at issue for any OP-V arithmetic op with nonzero
//  vstart (RVV 3.7 allowance), so this unit never sees one.

`include "karu_vcfg.vh"
`include "karu_cfg.vh"
`include "karu_fpkg.vh"
`include "karu_uop_defs.vh"

module karu_varith (
    input  wire         clk,
    input  wire         rst,
    input  wire         req,
    output wire         busy,
    output reg          done,

    input  wire [2:0]   vfunct3,    //  OP-V funct3 (000 OPIVV,100 OPIVX,011 OPIVI,010 OPMVV,110 OPMVX;
                                    //  FP: 001 OPFVV, 101 OPFVF)
    input  wire [5:0]   vfunct6,    //  OP-V funct6 (ins[31:26])
    input  wire [2:0]   vsew,
    input  wire [2:0]   vlmul,      //  vtype.vlmul (for true VLMAX incl. fractional)
    input  wire [31:0]  vl,
    input  wire         vta,
    input  wire         vma,
    input  wire [1:0]   vxrm,       //  fixed-point rounding mode
    output wire         vsat,       //  any element saturated this op (valid at done)
    input  wire         vm,         //  1 = unmasked
    input  wire [63:0]  imm,        //  sign-extended simm5 (.vi)
    input  wire [63:0]  rs1_v,      //  scalar x[rs1] (.vx)
    input  wire [3:0]   nreg,       //  registers in the group (LMUL)
    input  wire [4:0]   vd_base,
    input  wire [4:0]   vs1_base,   //  vs1 field (also unary selector)
    input  wire [4:0]   vs2_base,
    input  wire [`KARU_VLEN-1:0] v0,    //  mask register

    //  operand READ ADDRESSES (the adapter's granule fills key on these +
    //  the rdu_g* indices below; the whole-register d_* operand buses and
    //  their rd1/rd2/rd3 latches were DELETED -- subgoal)
    output wire [4:0]   r_vs1,
    output wire [4:0]   r_vs2,
    output wire [4:0]   r_vold,

    output reg          we,
    output reg  [4:0]   wd,
    output reg  [`KARU_VLEN-1:0] wdata,

    output wire         writes_x,   //  vfirst.m / (future) vmv.x.s
    output reg  [63:0]  x_res,

    //  ---- vector floating-point (OPFVV/OPFVF) ----
    input  wire [2:0]   frm,        //  rounding mode (fcsr.frm)
    input  wire [63:0]  frs1_v,     //  scalar f-operand (.vf)
    output reg          fflags_set, //  pulse with fflags at done
    output reg  [4:0]   fflags,
    output reg          writes_f,   //  vfmv.f.s: f[rd] = vs2[0]
    output reg  [63:0]  f_res,
    //  debug/assert: any in-lane FP unit active this cycle (req|busy|done).
    //  Exposed so karu_assert can check lane FP activity stays within an
    //  active vector op (the lane FPUs are otherwise invisible to the checker).
    output wire         fp_lane_active,

    //  ---- experimental single-instruction Keccak-f1600 (vkeccak) ----
    //  is_keccak is the issue-cycle decode (dec_unit==UNIT_VKECCAK, only ever
    //  asserted under KARU_EN_KECCAK). The op runs IN PLACE on the vd e64/m8
    //  group via this unit's normal VRF read (r_vold/d_vold) and write
    //  (we/wd/wdata) ports -- one ISOLATED 1600-bit Keccak permutation, never
    //  lane-replicated. Folded in here so karu64 has ONE vector-execute FU.
    input  wire         is_keccak,

    //  ---- standard vector crypto (Zvk*) ----
    //  is_vcrypto is the issue-cycle decode (dec_unit==UNIT_VCRYPTO, only ever
    //  asserted under KARU_EN_ZVK). vcrypto_cop is the decoded karu_vcrypto cop
    //  selector (same values as `VCRYPTO_*).
    input  wire         is_vcrypto,
    input  wire [4:0]   vcrypto_cop
    //  BRAM-VRF operand-fill stall: freezes this FSM while the adapter
    //  (karu_vrf_bram_wr) fills the granule operand latches from BRAM.
    //  Asserted only when a needed (address, granule) isn't resident yet
    //  (before a step consumes it), so it never freezes a just-launched
    //  subunit req. See doc/architecture.md
    , input wire        op_stall
    //  ---- granule source feed (the ONLY operand path) ----
    //  The adapter serves the CURRENT granule(s) each op needs instead of
    //  whole-register reads (the rd1/rd2/rd3 latches are deleted). Every op
    //  is a granule consumer (the classification below assigns exactly one
    //  GRAN class; rdu_gran is high whenever state != IDLE).
    //    rdu_vs1_g/rdu_vs2_g/rdu_vold_g = which sources this op reads NOW
    //      (phase-gated, so a writeback-only phase fills nothing);
    //    rdu_g1/rdu_g2/rdu_gv = the PER-OPERAND granule index (one bit --
    //      the adapter is elaboration-guarded to VGRAN==2 -- so vs1 can sit
    //      at granule r[0] while its wide source walks gpass, etc.);
    //    vs1_g/vs2_g/vold_g = the adapter's granule latches, stable across
    //      each pass (op_stall).
    , output wire       rdu_gran
    , output wire       rdu_vs1_g
    , output wire       rdu_vs2_g
    , output wire       rdu_vold_g
    , output wire       rdu_g1
    , output wire       rdu_g2
    , output wire       rdu_gv
    , input  wire [`KARU_VBUS_W-1:0] vs1_g
    , input  wire [`KARU_VBUS_W-1:0] vs2_g
    , input  wire [`KARU_VBUS_W-1:0] vold_g
    //  Canonical granule write port (replaces the 256-bit whole-register write
    //  for the hot, granule-loop datapaths). One VBUS_W register granule per g_we
    //  pulse: {g_wd, g_wg, g_wdata, g_wbe}. g_wlast marks an op's final granule
    //  (read-cache coherence). Muxed with the vlsu granule port in karu64.
    , output reg            g_we
    , output reg  [4:0]     g_wd
    , output reg  [`KARU_VGW-1:0]   g_wg
    , output reg  [`KARU_VBUS_W-1:0]    g_wdata
    , output reg  [`KARU_VBUS_B-1:0]    g_wbe
    , output reg            g_wlast
    //  VRF6 checker qualifiers for the write above (doc/architecture.md):
    //  vlgov = vl-governed ELEMENT data (tail-byte rule applies); mdest = a
    //  mask-register destination (bit-granular, rule exempt); vsew/epr = the
    //  DEST element width / elements-per-register (FP and widening ops differ
    //  from vtype.SEW). Since 6c-a, EVERY write family drives these: the hot
    //  paths from gwbe_*, the cold S_CWB funnel from the per-client cwb_*
    //  (only vl-AGNOSTIC writes -- vmv<nr>r, Zvk element groups, Keccak --
    //  remain vlgov=0-exempt by semantics).
    , output reg            g_wb_vlgov
    , output reg            g_wb_mdest
    , output reg  [2:0]     g_wb_vsew
    , output reg  [15:0]    g_wb_epr
);
    localparam VLEN  = `KARU_VLEN;
    localparam VLENB = `KARU_VLENB;
    //  Divider config (mirrors karu_m): 1 = combinational all-element-parallel;
    //  >1 = shared bit-serial restoring divider, one element at a time.
    localparam V_DIV_C = (`KARU_V_DIV_CYCLES > 1) ? 64 : 1;
    localparam BS_DIV  = (V_DIV_C != 1);
    //  Multiplier config (mirrors karu_m radix-2^K, K=64/V_MUL_C): 1 =
    //  combinational all-element-parallel; >1 = shared serial multiplier,
    //  one element at a time. Allowed {1,4,16,64}.
    localparam V_MUL_REQ = `KARU_V_MUL_CYCLES;
    localparam V_MUL_C =
        (V_MUL_REQ == 1)  ? 1  :
        (V_MUL_REQ <= 4)  ? 4  :
        (V_MUL_REQ <= 16) ? 16 : 64;
    localparam BS_MUL = (V_MUL_C != 1);


    //  ---- legacy whole-register write outputs (QUARANTINED) ----
    //  Every write goes through the granule g_* port (S_GWB / S_FPWR /
    //  S_CWB / S_CMW / inline Zvk). The we/wd/wdata outputs survive the
    //  2026-06-12 flop-VRF deletion only as a policed dead interface: this
    //  FSM never asserts `we`, and the karu_assert INV11/13/14/15 checks
    //  (via the karu64 vrf_we wire) fire if that ever regresses.
    localparam MK     = (V_MUL_C == 1) ? 1 : (64 / V_MUL_C);    //  bits/cycle (safe part-select when comb)
    //  VPERM gather crossbar lanes: output elements (data-indexed source
    //  selects) computed per cycle for vrgather.vv/ei16. Clamp the requested
    //  value to a power-of-2 in [1, VLEN/8]. Other VPERM ops use no crossbar.
    localparam PLANES_REQ = `KARU_V_PERM_LANES;
`ifdef KARU_V_PERM_RAM
    //  slice (b): serialized to ONE element/cycle -- every additional window
    //  lane would be another async read port on pram/iram (a replicated RAM
    //  copy), and the whole point is deleting the parallel read network.
    //  KARU_V_PERM_LANES is ignored.
    localparam PLANES = 1;
`else
    localparam PLANES =
        (PLANES_REQ >= (VLEN/8)) ? (VLEN/8) :
        (PLANES_REQ >= 16) ? 16 :
        (PLANES_REQ >= 8)  ? 8  :
        (PLANES_REQ >= 4)  ? 4  :
        (PLANES_REQ >= 2)  ? 2  : 1;
`endif

    //  ---- latched request ----
    //  (* max_fanout *) on the broadcast control regs. SEW/op-type fan out to
    //  every lane: vsew_q drove ~7226 loads in a full-vector post-synth report
    //  and heads the ~16 ns vsew_q->wdata writeback cone (78% routing). Capping
    //  fanout makes Vivado replicate the driver -> shorter local routes on that
    //  path. Verilog attribute, so verilator ignores it (functionally inert;
    //  simulation is bit-identical). Only affects synthesis placement.
    (* max_fanout = 100 *) reg [2:0]    f3_q;
    (* max_fanout = 100 *) reg [5:0]    f6_q;
    (* max_fanout = 100 *) reg [2:0]    vsew_q;
    reg [2:0]   vlmul_q;
    reg [31:0]  vl_q;
    reg         vta_q, vma_q, vm_q;
    reg [1:0]   vxrm_q;
    reg [63:0]  imm_q, rs1_q;
    reg [3:0]   nreg_q;
    reg [4:0]   vd_q, vs1_q, vs2_q;
    reg [`KARU_VLEN-1:0] v0_q;
    //  ---- FP-specific latched fields ----
    reg [2:0]   frm_q;
    reg [63:0]  frs1_q;
    (* max_fanout = 100 *) reg  is_fp_q;    //  this op is OPFVV/OPFVF (use the FP datapath + addressing)

    //  ---- decode (combinational on latched fields) ----
    wire opiv = (f3_q == 3'b000) || (f3_q == 3'b100) || (f3_q == 3'b011);
    wire opmv = (f3_q == 3'b010) || (f3_q == 3'b110);
    wire b_vv = (f3_q == 3'b000) || (f3_q == 3'b010);   //  operand b = vs1
    wire b_vx = (f3_q == 3'b100) || (f3_q == 3'b110);   //  operand b = x[rs1]
    wire b_vi = (f3_q == 3'b011);                       //  operand b = imm

    wire is_cmp     = opiv && (f6_q[5:3] == 3'b011);            //  OPIV compares
    wire is_mlg     = (f3_q == 3'b010) && (f6_q[5:3] == 3'b011);    //  OPMVV mask logic
    wire is_mul     = opmv && (f6_q[5:2] == 4'b1001);           //  1001xx mul/mulh*
    wire is_div     = opmv && (f6_q[5:2] == 4'b1000);           //  1000xx vdivu/vdiv/vremu/vrem (f6[1]=rem,f6[0]=signed)
    wire is_mac     = opmv && (f6_q[5:3] == 3'b101) && f6_q[0]; //  101xx1 vmadd/vnmsub/vmacc/vnmsac
    wire is_mvmerge = opiv && (f6_q == 6'b010111);              //  vmv.v.* / vmerge
    wire is_vmvnr   = b_vi && (f6_q == 6'b100111);              //  vmv<nr>r.v whole-reg move (.vi only)
    //  carry/borrow group (OPIV 0100xx): f6[0]=0 element (vadc/vsbc),
    //  f6[0]=1 mask-out (vmadc/vmsbc); f6[1]=1 subtract.
    wire is_carry   = opiv && (f6_q[5:2] == 4'b0100);
    wire is_carry_e = is_carry && !f6_q[0];                     //  vadc / vsbc -> element
    wire is_carry_m = is_carry &&  f6_q[0];                     //  vmadc / vmsbc -> mask
    //  -- fixed-point (OPIV 1000xx sat add/sub, 100111 vsmul, 10101x ssr; OPMV 0010xx avg) --
    wire is_satadd  = opiv && (f6_q[5:2] == 4'b1000);           //  vsaddu/vsadd/vssubu/vssub (f6[1]=sub,f6[0]=signed)
    wire is_vsmul   = opiv && (b_vv || b_vx) && (f6_q == 6'b100111);    //  vsmul.vv/.vx (OPIV; OPMV 100111 = vmulh)
    wire is_vssr    = opiv && (f6_q[5:1] == 5'b10101);          //  vssrl(101010)/vssra(101011), f6[0]=arith
    wire is_avg     = opmv && (f6_q[5:2] == 4'b0010);           //  vaaddu/vaadd/vasubu/vasub (f6[1]=sub,f6[0]=signed)
    //  -- widening (OPMV 11xxxx): dest = 2*SEW, 2*LMUL register group --
    wire is_wide    = opmv && (f6_q[5:4] == 2'b11);
    wire wide_w     = is_wide && (f6_q[5:2] == 4'b1101);        //  .w forms (vwadd.w etc.): vs2 already wide
    wire wide_mul   = is_wide && (f6_q[5:2] == 4'b1110);        //  vwmulu/vwmulsu/vwmul
    wire wide_mac   = is_wide && (f6_q[5:2] == 4'b1111);        //  vwmaccu/vwmacc/vwmaccus/vwmaccsu
    //  -- narrowing (OPIV 1011xx): vs2 = 2*SEW, dest = SEW --
    wire is_narrow  = opiv && (f6_q[5:2] == 4'b1011);
    wire narrow_clip= is_narrow && f6_q[1];                     //  vnclipu(101110)/vnclip(101111)
    //  -- reductions: OPMVV 0000xx single-width (.vs); OPIVV 11000x widening --
    wire is_red     = (f3_q == 3'b010) && (f6_q[5:3] == 3'b000);    //  vredsum/and/or/xor/minu/min/maxu/max
    wire is_wred    = (f3_q == 3'b000) && (f6_q[5:1] == 5'b11000);  //  vwredsumu(110000)/vwredsum(110001)
    wire is_reduce  = is_red || is_wred;
    wire is_alu     = opiv && !is_cmp && !is_mvmerge && !is_vmvnr && !is_carry
                    && !is_satadd && !is_vsmul && !is_vssr && !is_narrow && !is_wred
                    && !is_gather && !is_gei16 && !is_slideup && !is_slidedn;
    wire is_unary   = (f3_q == 3'b010) && (f6_q == 6'b010000);  //  VWXUNARY0 (OPMVV)
    wire is_munary  = (f3_q == 3'b010) && (f6_q == 6'b010100);  //  VMUNARY0
    //  VXUNARY0 (OPMVV 010010): integer extend vsext/vzext.vf{2,4,8}. vs1[2:1]
    //  picks the factor (01->/8, 10->/4, 11->/2), vs1[0] picks sign. Narrow
    //  source (EEW=SEW/f, EMUL=LMUL/f); normal-width dest.
    wire is_vext    = (f3_q == 3'b010) && (f6_q == 6'b010010)
                    && (vs1_q[4:3] == 2'b00) && (vs1_q[2:1] != 2'b00);
`ifdef KARU_EN_ZVKB
    //  Zvkb byte/bit reversals: VXUNARY0 (OPMVV 010010) like vsext/vzext but
    //  vs1 selectors 01000/01001 -- element-local unary on vs2, so they ride
    //  the lane (is_grp) path, not the whole-register ext_res path. The
    //  other Zvkb ops (vandn/vrol/vror) are OPIV encodings that fall into
    //  the is_alu catch-all; the lane f6 case implements them.
    wire is_brev8   = (f3_q == 3'b010) && (f6_q == 6'b010010) && (vs1_q == 5'b01000);
    wire is_rev8    = (f3_q == 3'b010) && (f6_q == 6'b010010) && (vs1_q == 5'b01001);
`else
    wire is_brev8   = 1'b0;
    wire is_rev8    = 1'b0;
`endif
    wire [2:0] ext_flog = 3'd4 - {1'b0, vs1_q[2:1]};            //  log2(factor): vf8->3, vf4->2, vf2->1
    wire       ext_sign = vs1_q[0];                             //  1 = vsext, 0 = vzext
    wire [6:0] ext_ssew = sewb >> ext_flog;                     //  source (narrow) element width
    wire is_vfirst  = is_unary  && (vs1_q == 5'b10001);
    wire is_vcpop   = is_unary  && (vs1_q == 5'b10000);         //  vcpop.m -> x
    wire is_vmvxs   = is_unary  && (vs1_q == 5'b00000);         //  vmv.x.s -> x
    wire is_vmvsx   = (f3_q == 3'b110) && (f6_q == 6'b010000) && (vs2_q == 5'b00000); //    vmv.s.x (vs2=selector, rs1=x src)
    wire is_vid     = is_munary && (vs1_q == 5'b10001);
    wire is_mscan   = is_munary && (vs1_q[4:2] == 3'b000) && (vs1_q[1:0] != 2'b00); //  vmsbf/vmsof/vmsif
    //  -- VPERM (cross-lane): slides, gather, compress, iota --
    wire is_gather   = opiv && (f6_q == 6'b001100);                 //  vrgather.v{v,x,i}
    wire is_gei16    = (f3_q == 3'b000) && (f6_q == 6'b001110);     //  vrgatherei16.vv (OPIVV)
    //  slideup/down are OPIVX/OPIVI only (OPMVX 001110/001111 = vslide1up/down)
    wire is_slideup  = ((f3_q == 3'b100) || b_vi) && (f6_q == 6'b001110);   //  vslideup.v{x,i}
    wire is_slidedn  = ((f3_q == 3'b100) || b_vi) && (f6_q == 6'b001111);   //  vslidedown.v{x,i}
    wire is_slide1up = (f3_q == 3'b110) && (f6_q == 6'b001110);     //  vslide1up.vx (OPMVX)
    wire is_slide1dn = (f3_q == 3'b110) && (f6_q == 6'b001111);     //  vslide1down.vx (OPMVX)
    wire is_compress = (f3_q == 3'b010) && (f6_q == 6'b010111);     //  vcompress.vm (OPMVV)
    wire is_viota    = is_munary && (vs1_q == 5'b10000);            //  viota.m
    //  true per-element (data-indexed) gather -> the only crossbar; handled in
    //  the lane-limited S_GATH path. vrgather.vx/.vi have one scalar index
    //  (a broadcast, no crossbar) and stay on the cheap whole-register path.
    wire is_gvv      = (is_gather && b_vv) || is_gei16;
    wire is_gscalar  = is_gather && (b_vx || b_vi);                 //  vrgather.vx/.vi (splat)
    wire is_perm     = is_gather || is_gei16 || is_slideup || is_slidedn
                    || is_slide1up || is_slide1dn || is_compress || is_viota;

    //  writes_x is sampled by the core at the issue/req cycle, so it must be
    //  combinational on the *input* fields (the _q latches still hold the
    //  previous op at that point). vfirst.m and vmv.x.s both write x.
    assign writes_x = (vfunct3 == 3'b010) && (vfunct6 == 6'b010000)
                    && (vs1_base == 5'b10001 || vs1_base == 5'b00000 || vs1_base == 5'b10000);
    //  element-producing group ops iterate the LMUL group; mask/unary/vmv.s.x
    //  write a single register.
    wire grp = is_alu || is_mul || is_div || is_mac || is_mvmerge || is_vid || is_cmp
            || is_carry_e || is_carry_m || is_satadd || is_vsmul || is_vssr || is_avg
            || is_vext || is_brev8 || is_rev8;
    //  vmv<nr>r.v copies imm+1 registers (1/2/4/8); other group ops span LMUL.
    wire [3:0] iter_n = is_vmvnr ? (imm_q[3:0] + 4'd1) : (grp ? nreg_q : 4'd1);

    wire [6:0] sewb = 7'd8 << vsew_q;               //  bits/element
    //  log2(sewb): sewb = 8<<vsew is a power of 2, so index*sewb barrel-shift
    //  amounts are SHIFTS, not multiplies. Using `<< sew_lg` keeps Vivado from
    //  mapping the gather/permute index geometry (pelem/gidx) to DSP48s, which
    //  otherwise anchor placement and add a long inter-DSP route on the writeback
    //  cone. Byte-identical (g*sewb == g<<sew_lg).
    wire [5:0] sew_lg = 6'd3 + {3'b0, vsew_q};      //  log2(bits/element) = 3..6
    //  epr (elements/reg = VLEN>>(3+vsew)) and epc_w (elems/64b chunk = 8>>vsew)
    //  are powers of 2 too -> r*epr and *epc_w geometry are SHIFTS, not DSPs.
    localparam LOG2VLEN = $clog2(VLEN);
    wire [5:0] epr_lg  = LOG2VLEN[5:0] - 6'd3 - {3'b0, vsew_q}; //  log2(epr)
    wire [5:0] epc_lg  = 6'd3 - {3'b0, vsew_q};                 //  log2(epc_w) = 0..3
    wire [5:0] eprw_lg = epr_lg - 6'd1;                         //  log2(epr_w = epr/2)
    wire [5:0] wsew_lg = sew_lg + 6'd1;                         //  log2(wsewb = 2*sewb)
    wire [5:0] essew_lg = sew_lg - {3'b0, ext_flog};            //  log2(ext_ssew = sewb>>ext_flog)
    //  r*epr / r*epr_w reused below via `ebase` / `ebase_w` (defined after `r`).
    wire [31:0] epr = VLEN[31:0] >> (3 + vsew_q);   //  elements/register

    reg [3:0] r;        //  dest register index within the (dest) group
    reg       nph;      //  narrowing phase: 0 = low wide src reg (2r), 1 = high (2r+1)
    reg [5:0] nse;      //  narrowing element-window start within the current phase
    reg [3:0] rch;      //  reduction: 64-bit chunk index within the current register
    //  register addressing.  widening: dest spans 2*LMUL regs (r), narrow
    //  sources at r>>1 (half = r[0]); .w forms read vs2 wide at r. narrowing:
    //  dest narrow at r, wide vs2 at 2r (+phase), narrow vs1/vold at r.
    wire [4:0] r_half = {2'b0, r[3:1]};                 //  r >> 1
    wire [4:0] r_dbl  = {r, 1'b0} + {4'b0, nph};        //  2r + phase
    //  ---- VPERM (cross-lane) buffers & geometry (forward-declared) ----
    localparam GBUF = VLEN*8;                           //  max group bits (LMUL<=8)
`ifdef KARU_V_PERM_RAM
    //  slice (b): the perm source/index buffers are distributed-RAM word
    //  arrays instead of GBUF-wide flop vectors -- deletes the 4096 buffer
    //  flops and (with the serialized window) turns the two GBUF->64
    //  variable barrel shifters (pelem/gidx) into native 64-bit word reads.
    //  Writes happen only in S_PLOAD, reads only in S_PCOMP/S_CMP_SCAN, so
    //  there is no read-during-write hazard.
    localparam WPR    = VLEN/64;                    //  64-bit words per v-reg
    localparam WPW    = (WPR > 1) ? $clog2(WPR) : 1;
    localparam PDEPTH = GBUF/64;                    //  words per source-group buffer
    localparam PWW    = $clog2(PDEPTH);             //  word-address width (any VLEN)
    (* ram_style = "distributed" *) reg [63:0] pram [0:PDEPTH-1];   //  vs2 source group
    (* ram_style = "distributed" *) reg [63:0] iram [0:PDEPTH-1];   //  vs1 index/mask group
    reg [WPW-1:0] plw;                              //  word subcounter within a reg
    reg [PWW-1:0] plwa;                             //  running load word address
`else
    reg [GBUF-1:0] pbuf;                                //  buffered vs2 source group (reg-contiguous)
    reg [GBUF-1:0] ibuf;                                //  buffered vs1 index/mask group
    reg plg;                                            //  granule sub-step (S_PLOAD)
`endif
    reg [3:0]  pli;                                     //  perm load counter
    reg        ld_active;                               //  high during the perm load phase
    reg [31:0] iota_acc;                                //  viota running prefix (carried per window)
    reg [`KARU_VLEN-1:0] pacc;                          //  per-register window accumulator (S_PCOMP)
    reg [31:0] pse;                                     //  window start element within the dest register

    //  perm load streams the source/index groups in: vs2_q+pli, vs1_q+pli.
    //  is_fp_q selects the FP datapath addressing (vf_r_*).
    assign r_vs1  = is_fp_q ? vf_r_vs1
                  : ld_active ? (vs1_q + {1'b0, pli})
                  : is_reduce ? vs1_q                       //  reduction: vs1[0] scalar seed
                  : is_wide   ? (vs1_q + r_half) : (vs1_q + {1'b0, r});
    assign r_vs2  = is_fp_q ? vf_r_vs2
                  : ld_active ? (vs2_q + {1'b0, pli})
                  : is_narrow ? (vs2_q + r_dbl)
                  : (is_wide && wide_w) ? (vs2_q + {1'b0, r})
                  : is_wide   ? (vs2_q + r_half)
                  : is_vext   ? (vs2_q + {1'b0, (r >> ext_flog)})   //  narrow src: f dest regs/src reg
                  :             (vs2_q + {1'b0, r});    //  reduction sweeps vs2_q+r
    assign r_vold = is_fp_q ? vf_r_vold
                  //    stage-4: the S_CMW vold_g fills key the mask register
                  : (is_cmp || is_carry_m) ? vd_q
                  : is_reduce ? vd_q : (vd_q + {1'b0, r});  //  reduction writes single reg vd
    wire [31:0] ebase = {28'b0, r} << epr_lg;   //  == r*epr (epr=2^epr_lg); shift, not DSP
    wire [31:0] ebase_eff = ebase;
    //  wide-element geometry: 2*SEW element, epr_w = epr/2 elements per reg
    wire [6:0]  wsewb = sewb << 1;                      //  wide element bits (<=64)
    wire [31:0] epr_w = epr >> 1;                       //  wide elements per register

    //  true VLMAX (elements in the group), honouring fractional LMUL
    wire [31:0] vlmax = vlmul_q[2] ? (epr >> (4 - {2'b0, vlmul_q[1:0]}))
                                   : (epr << vlmul_q[1:0]);
    //  index EMUL (registers) for vrgatherei16 (EEW=16); else = LMUL
    wire [4:0] gei_nreg = (vsew_q == 3'd0) ? {nreg_q, 1'b0}
                        : (vsew_q == 3'd1) ? {1'b0, nreg_q}
                        : (vsew_q == 3'd2) ? ({1'b0, nreg_q} >> 1)
                        :                    ({1'b0, nreg_q} >> 2);
    wire [3:0] idx_nreg = is_gei16
                        ? ((gei_nreg == 5'd0) ? 4'd1 : (gei_nreg > 5'd8 ? 4'd8 : gei_nreg[3:0]))
                        : nreg_q;
    //  registers to buffer: max(source LMUL, index EMUL when gathering)
    wire [3:0] load_n = ((is_gather && b_vv) || is_gei16)
                      ? ((idx_nreg > nreg_q) ? idx_nreg : nreg_q) : nreg_q;

    //  splat source for vmv.v.{x,i}
    wire [63:0] mv_splat = b_vx ? rs1_q : imm_q;
    wire        mv_is_vv = b_vv;

    //  ========================================================
    //  element-producing datapath (alu / mul / vmv|vmerge / vid)
    //  produces one VLEN-bit register, masked + tail-handled
    //  ========================================================
    function [63:0] sext;   input [63:0] v; input [6:0] w;
        sext = (w >= 7'd64) ? v : (v | (v[w-1] ? ({64{1'b1}} << w) : 64'h0));
    endfunction

    //  one reduction step a OP b -- matches the per-op semantics of the
    //  single-width/widening reductions (sum/and/or/xor/min{,u}/max{,u}).
    //  OP is associative+commutative for all eight, so a balanced tree of
    //  these gives the same result as a linear fold (with identity-filled
    //  inactive lanes); min/max sign-extend the low `sw` bits to compare but
    //  return the raw operand, exactly like the old in-line fold.
    function [63:0] redop;  input [63:0] a, b; input [2:0] op; input [6:0] sw;
        reg signed [63:0] sa, sb;
        begin
            sa = sext(a, sw);   sb = sext(b, sw);
            case (op)
                3'b000:  redop = a + b;                 //  sum
                3'b001:  redop = a & b;                 //  and
                3'b010:  redop = a | b;                 //  or
                3'b011:  redop = a ^ b;                 //  xor
                3'b100:  redop = (a  < b ) ? a : b;     //  minu
                3'b101:  redop = (sa < sb) ? a : b;     //  min
                3'b110:  redop = (a  > b ) ? a : b;     //  maxu
                default: redop = (sa > sb) ? a : b;     //  max
            endcase
        end
    endfunction
    localparam NLANE = VLEN/8;          //  max elements/register (e8)
    localparam RLOG  = $clog2(NLANE);   //  (legacy)
    //  Reductions fold ONE 64-bit chunk per cycle (REPC = max elements/chunk = e8)
    //  rather than a full VLEN-wide register tree -- a small, predictable cone.
    localparam REPC  = 8;               //  max elements per 64-bit chunk (64/8)

    //  ========================================================
    //  element-producing datapath: VLEN/64 sub-word-SIMD lanes (karu_vlane).
    //  Each lane owns one contiguous 64-bit chunk of the register and computes
    //  64/SEW elements; their res_chunks concatenate into grp_res. Replaces the
    //  old flat all-element-parallel loop so synthesis maps ONE lane and
    //  replicates it (see karu_vlane.v) instead of a VLEN-wide fused cone.
    //  ========================================================
    //  Step C: compute lanes track the VRF bus (KARU_VRF_NLANES = VBUS_W/64 = 2
    //  under KARU_VRF_BRAM; = VLEN/64 = 4 otherwise). VGRAN_C = CPR/NLANES granule
    //  passes cover a register: 2 under BRAM, 1 (byte-identical) for the flop core.
    localparam NLANES = `KARU_VRF_NLANES;
    //  CPR = 64-bit chunks per WHOLE v-register (vs NLANES = compute lanes).
    //  Today NLANES==CPR, but the 2-lane narrowing makes NLANES =
    //  KARU_VRF_NLANES (<CPR); uses that mean "chunks per register" (e.g. the
    //  reduction fold loop) must track CPR, not the lane count. VGRAN_C is the
    //  number of granule passes the lanes take to cover a register (=1 today).
    localparam CPR     = VLEN/64;
    localparam VGRAN_C = CPR / NLANES;
    //  elaboration guard: the granule loop assumes the NLANES compute lanes evenly
    //  tile a register's CPR chunks (VGRAN_C = CPR/NLANES exact), which in turn
    //  requires a clean VLEN/VBUS_W/64 geometry. A bad combo (NLANES not a divisor
    //  of CPR, zero, or > CPR; VBUS_W not a multiple of 64; VLEN not a multiple of
    //  VBUS_W) would silently cover only part of each register -- trip synth/elab
    //  here instead. Only the violating branch elaborates, so valid configs (flop
    //  NLANES==CPR, BRAM NLANES==2/CPR==4) instantiate nothing.
    generate
        if (NLANES == 0 || (CPR % NLANES) != 0 || NLANES > CPR
            || ((`KARU_VBUS_W % 64) != 0) || ((`KARU_VLEN % `KARU_VBUS_W) != 0))
            begin : g_nlanes_guard
                KARU_BAD_NLANES_must_divide_CPR _elab_error();
            end
    endgenerate
    //  narrowing window width: narrow elements processed per cycle (bounds the
    //  parallel barrel-shift/clip cone -- the worst combinational path). Per-reg
    //  cost becomes 2*ceil(epr_w/NWIN) cycles instead of 2.
    localparam NWIN   = NLANES;
    wire [3:0] epc_w = 4'd8 >> vsew_q;          //  elements per 64-bit chunk
    wire [`KARU_VLEN-1:0] grp_res;
    wire [NLANES-1:0]     lane_sat_arr;
    wire grp_sat = |lane_sat_arr;

    //  ---- 2-lane granule loop ----------------------------------
    //  The NLANES compute lanes cover a register's CPR 64-bit chunks over
    //  VGRAN_C = CPR/NLANES passes. Under KARU_VRF_BRAM NLANES=KARU_VRF_NLANES (=2)
    //  => VGRAN_C=2 (two passes); the flop/default build keeps NLANES==CPR =>
    //  VGRAN_C==1 (a single pass, BYTE-IDENTICAL to the pre-loop code). Each pass
    //  the lanes window to chunks [gwin, gwin+NLANES); grp_res holds that pass's
    //  LANEW bits, accumulated into grp_acc; the whole register is written on the
    //  last pass via grp_full.
    localparam LANEW = NLANES*64;                       //  lane-array output width / pass
    localparam GPW   = (VGRAN_C > 1) ? $clog2(VGRAN_C) : 1;
    reg  [GPW-1:0]        gpass;                        //  granule pass within a dest register
`ifdef KARU_V_LANE_PIPE
    reg                   lane_warm;                    //  2-stage lane: S_RUN warm-up cycle
`endif
    reg  [`KARU_VLEN-1:0] grp_acc;                      //  prior passes' accumulated result
    wire                  last_g = (gpass == (VGRAN_C-1));
    //  this pass's chunk base. Folds to a constant 0 at VGRAN_C==1 so the FP geg/
    //  fdbuf selects (which use gwin directly, not generate-gated) are static in
    //  the byte-identical build -- no live gpass mux there either.
    wire [31:0]           gwin   = (VGRAN_C > 1) ? (gpass * NLANES) : 32'd0;
    //  lane-based ops whose result comes from grp_res (granule-windowed). NOT
    //  is_vext (whole-register ext_res) nor cmp/mlg/mscan/vfirst (whole-reg).
    wire is_grp = is_alu || is_mul || is_div || is_mac || is_mvmerge || is_vid
               || is_vmvsx || is_carry_e || is_satadd || is_avg || is_vssr || is_vsmul
               || is_brev8 || is_rev8;
    reg  [`KARU_VLEN-1:0] grp_full;                     //  grp_acc + this pass's slice
    //  KARU_V_WB_STAGE: register the LANE OUTPUT (grp_res/grp_sat) before the
    //  accumulate + grp_full + wdata_hot writeback, cutting the route-bound
    //  lane->wdata_hot cone (the 16ns worst path). The accumulate/write then runs
    //  off the REGISTERED grp_res_q in S_GWB, so grp_full feeds from grp_res_q.
    reg  [`KARU_VLEN-1:0] grp_res_q;
    reg                   grp_sat_q;
    `define GRP_RES_EFF grp_res_q
    //  GENERATE-static at VGRAN_C==1 (the byte-identical build): grp_full is just
    //  grp_res, with NO live-gpass part-select in the hot writeback path. The
    //  dynamic accumulate only exists when there really are >1 granule passes.
    generate if (VGRAN_C > 1) begin : g_grpfull_dyn
        always @* begin
            grp_full = grp_acc;
            grp_full[gpass*LANEW +: LANEW] = `GRP_RES_EFF[LANEW-1:0];
        end
    end else begin : g_grpfull_stat
        always @* grp_full = `GRP_RES_EFF;              //  VGRAN_C==1: whole register, static
    end endgenerate

    //  ---- per-lane FP datapath bus ----
    //  The lane carries karu_fpu + karu_vest7; the parent drives operands and
    //  the req/done handshake. Driven by the FP FSM (2b/2d); tied off here in 2a.
    //  lane outputs (driven by the genvar) + parent-driven inputs (driven by
    //  the FP datapath block below).
    wire [NLANES-1:0]      lane_fp_busy, lane_fp_done;
    wire [NLANES*64-1:0]   lane_fp_res, lane_est_res;
    wire [NLANES*5-1:0]    lane_fp_flags, lane_est_flags;
    wire [NLANES-1:0]      lane_fp_req;
    wire [4:0]             lane_fp_sub;
    wire                   lane_fp_is_d, lane_fp_is_rec;
    wire [2:0]             lane_fp_rm;
    wire [NLANES*64-1:0]   lane_fp_op1, lane_fp_op2, lane_fp_op3;
    assign fp_lane_active = (|lane_fp_req) | (|lane_fp_busy) | (|lane_fp_done);

    //  Assertion-only debug tap (deep-ref'd by htif_tb -> karu_assert; never a
    //  port, so synthesis prunes it). Collapsed to a single bit here so the
    //  checker stays width-agnostic as NLANES (=VLEN/64) varies.
    //  dbg_fp_req_busy : a lane FP req while that lane is already busy. Must be 0
    //     -- the FSM issues a 1-cycle req pulse only when the lane is idle (`busy`
    //     is registered, so it rises the cycle AFTER req); a future pipelined-issue
    //     change that fed a busy lane would trip this.
    wire dbg_fp_req_busy = |(lane_fp_req & lane_fp_busy);

    genvar L;
    generate for (L = 0; L < NLANES; L = L + 1) begin : g_lane
        //  chunk index of this (pass,lane) within the whole register: gwin+L.
        //  At VGRAN_C==1 gwin==0 => gwin+L == L (byte-identical).
        //  chunk index of this (pass,lane). GENERATE-static at VGRAN_C==1 (= L,
        //  no live gpass in the hot lane operand select); dynamic only when there
        //  are >1 passes. Keeps the byte-identical build a true structural no-op.
        wire [31:0] gcL;
        if (VGRAN_C > 1) begin : g_gcl_dyn
            assign gcL = gwin + L[31:0];
        end else begin : g_gcl_stat
            assign gcL = L[31:0];
        end
        wire [31:0] eg_base_L = ebase_eff + (gcL << epc_lg);    //  gcL*epc_w; shift, not DSP
        wire [7:0]  v0b_L     = v0_q[eg_base_L[7:0] +: 8];
        karu_vlane #(.MUL_COMB(V_MUL_C == 1 ? 1 : 0),
                     .DIV_COMB(V_DIV_C == 1 ? 1 : 0)
                     ) u_lane (
            .clk(clk), .rst(rst),
            //  stage-3: GRAN ops take the adapter's granule latches (granule
            //  g = chunks [g*NLANES, (g+1)*NLANES) -- same window as gcL)
            //  granule latches only (the whole-register fallback is gone)
            .vs2_chunk (vs2_g [L*64 +: 64]),
            .vs1_chunk (vs1_g [L*64 +: 64]),
            .vold_chunk(vold_g[L*64 +: 64]),
            .rs1_v(rs1_q), .imm(imm_q),
            .f6(f6_q), .vsew(vsew_q), .vxrm(vxrm_q),
            .b_vv(b_vv), .b_vx(b_vx), .b_vi(b_vi),
            .is_mul(is_mul), .is_div(is_div), .is_mac(is_mac),
            .is_mvmerge(is_mvmerge), .is_vid(is_vid), .is_vmvsx(is_vmvsx),
            .is_carry_e(is_carry_e), .is_satadd(is_satadd), .is_avg(is_avg),
            .is_vssr(is_vssr), .is_vsmul(is_vsmul),
            .is_brev8(is_brev8), .is_rev8(is_rev8),
            .mv_is_vv(mv_is_vv), .mv_splat(mv_splat),
            .vm(vm_q), .v0_bits(v0b_L), .vl(vl_q), .eg_base(eg_base_L),
            //  FP datapath (operands packed 64b/lane into the lane bus)
            .fp_req(lane_fp_req[L]), .fp_sub(lane_fp_sub), .fp_is_d(lane_fp_is_d),
            .fp_rm(lane_fp_rm),
            .fp_op1(lane_fp_op1[L*64 +: 64]), .fp_op2(lane_fp_op2[L*64 +: 64]), .fp_op3(lane_fp_op3[L*64 +: 64]),
            .fp_is_rec(lane_fp_is_rec),
            .fp_busy(lane_fp_busy[L]), .fp_done(lane_fp_done[L]),
            .fp_res(lane_fp_res[L*64 +: 64]), .fp_flags(lane_fp_flags[L*5 +: 5]),
            .est_res(lane_est_res[L*64 +: 64]), .est_flags(lane_est_flags[L*5 +: 5]),
            .res_chunk(grp_res[L*64 +: 64]), .lane_sat(lane_sat_arr[L])
        );
    end endgenerate

    //  ========================================================
    //  vsext/vzext.vf{2,4,8}: produce one normal-width dest register per cycle.
    //  Source reg r>>log2(f) (set in r_vs2); within it, dest reg r reads its
    //  sub-block (r & (f-1)) of epr narrow elements. Each narrow element is
    //  sign-/zero-extended from ext_ssew to SEW. Mask/tail like the ALU path.
    //  ========================================================
    reg [`KARU_VLEN-1:0] ext_res;
    reg [63:0]  x_sval, x_ext, x_ssm, x_dsm;    reg [31:0] x_eg, x_nidx;    reg x_act;
    reg [4:0]   x_sub;  integer xe, xbb;
    //  the source sub-window for dest reg r is granule x_g2 of the source
    //  register; x_wbase = the window's bit offset within that register
    wire [4:0]  x_subw  = {1'b0, r} & ((5'd1 << ext_flog) - 5'd1);
    wire [31:0] x_wbase = ({27'b0, x_subw} << LOG2VLEN) >> ext_flog;
    wire        x_g2    = x_wbase[7];
    always @(*) begin
        ext_res = {`KARU_VLEN{1'b0}};   //  6c-b: keep-old = the suppressed byte enable
        x_sval=0; x_ext=0; x_eg=0; x_nidx=0; x_act=0;
        x_dsm = (sewb     >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);     //  dest SEW mask
        x_ssm = (ext_ssew >= 7'd64) ? 64'h0 : ({64{1'b1}} << ext_ssew); //  src EEW mask
        x_sub = {1'b0, r} & ((5'd1 << ext_flog) - 5'd1);                //  sub-block within src reg
        for (xe = 0; xe < VLEN/8; xe = xe + 1) begin
            if (xe < epr) begin
                x_eg   = ebase_eff + xe[31:0];
                x_act  = vm_q || v0_q[x_eg[7:0]];
                x_nidx = ({27'b0, x_sub} << epr_lg) + xe[31:0];         //  x_sub*epr (shift) + xe
                x_sval = (vs2_g >> (x_wbase[6:0] + (xe[31:0] << essew_lg))) & ~x_ssm;
                x_ext  = (ext_sign ? sext(x_sval, ext_ssew) : x_sval) & ~x_dsm;
                for (xbb = 0; xbb < 8; xbb = xbb + 1)
                    if (xbb < (sewb >> 3)) begin
                        //  6c-b: keep-old bytes stay at the zero seed -- the
                        //  byte enable IS the preservation; no d_vold read.
                        if (x_eg < vl_q && x_act)
                            ext_res[(xe*(sewb>>3)+xbb)*8 +: 8] = x_ext[xbb*8 +: 8];
                    end
            end
        end
    end

    //  ========================================================
    //  compares -> mask bits (read group, write one mask reg)
    //  ========================================================
    //  cmp_bits = compare result at active in-vl element positions;
    //  cmp_act  = positions this op writes (active && in-vl). Inactive/tail
    //  positions keep the old mask register (undisturbed) -- compares are
    //  mask-undisturbed for masked-off, tail-agnostic past vl.
    reg [`KARU_VLEN-1:0] cmp_bits, cmp_act;
    integer ce; reg [63:0] ca, cb, cau, cbu, cas, cbs, csm; reg cbit, cact, ccin; reg [31:0] ceg;
    reg [64:0] cca, ccs;
    wire [31:0] epg = epr / VGRAN_C;    //  elements per source granule
    always @(*) begin
        cmp_bits = {VLEN{1'b0}};    cmp_act = {VLEN{1'b0}};
        ca=0; cb=0; cau=0; cbu=0; cas=0; cbs=0; csm=0; cbit=0; cact=0; ccin=0; ceg=0; cca=0; ccs=0;
        for (ce = 0; ce < VLEN/8; ce = ce + 1) begin
            //  stage-4: one GRANULE of register r per pass, sourced from the
            //  granule latches (gpass term assumes VGRAN_C==2, the guarded
            //  BRAM geometry); cmp_bits land at their global positions and
            //  macc accumulates them raw across (r, gpass)
            if (ce < epg) begin
                ceg  = ebase_eff + (gpass ? epg : 32'd0) + ce[31:0];
                //  vmadc/vmsbc write every in-vl bit (v0 is carry-in, not
                //  predicate); compares write active in-vl bits only.
                cact = is_carry_m ? 1'b1 : (vm_q || v0_q[ceg[7:0]]);
                if (ceg < vl_q && cact) begin
                    csm = (sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
                    ca  = (vs2_g >> (ce*sewb)) & ~csm;
                    cb  = b_vv ? ((vs1_g >> (ce*sewb)) & ~csm) :
                          b_vx ? (rs1_q & ~csm) : (imm_q & ~csm);
                    cau = ca; cbu = cb; cas = sext(ca, sewb); cbs = sext(cb, sewb);
                    if (is_carry_m) begin
                        ccin = vm_q ? 1'b0 : v0_q[ceg[7:0]];
                        cca  = {1'b0, cau} + {1'b0, cbu} + {64'b0, ccin};
                        ccs  = {1'b0, cau} - {1'b0, cbu} - {64'b0, ccin};
                        cbit = f6_q[1] ? ccs[sewb] : cca[sewb];     //  borrow-out / carry-out
                    end else
                    case (f6_q[2:0])
                        3'b000: cbit = (cau == cbu);                //  vmseq
                        3'b001: cbit = (cau != cbu);                //  vmsne
                        3'b010: cbit = (cau <  cbu);                //  vmsltu
                        3'b011: cbit = ($signed(cas) <  $signed(cbs));  //  vmslt
                        3'b100: cbit = (cau <= cbu);                //  vmsleu
                        3'b101: cbit = ($signed(cas) <= $signed(cbs));  //  vmsle
                        3'b110: cbit = (cau >  cbu);                //  vmsgtu
                        3'b111: cbit = ($signed(cas) >  $signed(cbs));  //  vmsgt
                    endcase
                    cmp_bits[ceg[7:0]] = cbit;
                    cmp_act[ceg[7:0]]  = 1'b1;
                end
            end
        end
    end

    //  ========================================================
    //  mask-register logic (single register, vl bits)
    //  ========================================================
    //  mlg_act = bits this op writes (in-vl); tail (>=vl) keeps old (agnostic).
    reg [`KARU_VLEN-1:0] mlg_res, mlg_act; integer mi; reg ma, mb, mr;
    always @(*) begin
        mlg_res = {VLEN{1'b0}}; mlg_act = {VLEN{1'b0}}; ma=0; mb=0; mr=0;
        //  stage-4: one VBUS_W granule of mask bits per pass from the
        //  granule latches; bits land at their global positions and macc
        //  accumulates them raw (S_CMW writes against cmp_actall, whose
        //  is_mlg arm covers every in-vl bit). mlg_act is unused here.
        for (mi = 0; mi < `KARU_VBUS_W; mi = mi + 1) begin
            if (((gpass ? `KARU_VBUS_W : 0) + mi) < vl_q) begin
                ma = vs2_g[mi]; mb = vs1_g[mi];
                case (f6_q[2:0])
                    3'b000: mr =  (ma & ~mb);   3'b001: mr =  (ma &  mb);
                    3'b010: mr =  (ma |  mb);   3'b011: mr =  (ma ^  mb);
                    3'b100: mr =  (ma | ~mb);   3'b101: mr = ~(ma &  mb);
                    3'b110: mr = ~(ma |  mb);   default: mr = ~(ma ^  mb);
                endcase
                mlg_res[(gpass ? `KARU_VBUS_W : 0) + mi] = mr;
            end
        end
    end

    //  ---- vfirst.m : first *active* set bit (masked-off elements skipped) ----

    //  ---- vmv.x.s : element 0 of vs2, sign-extended to XLEN ----
    //  stage-4: element 0 lives in granule 0 (vmvxs is a single S_RUN
    //  visit at gpass==0, so vs2_g holds it)
    wire [63:0] vmvxs_res = sext(vs2_g[63:0] & ~((sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb)), sewb);

    //  ---- mask-scan (vmsbf/vmsof/vmsif) + vcpop.m ----
    //  source mask = d_vs2 (single mask reg). active = vm||v0[i], i<vl.
    //  ff = first active set bit; vcpop = count of active set bits.
    //  stage-4: the whole family (vmsbf/msof/msif, vfirst, vcpop) derives
    //  from a {found, first-index, count} SUMMARY of the active set bits.
    //  Each S_RUN pass folds one vs2_g granule into the summary regs
    //  (found_q/ff_q/cnt_q, seeded at accept); the combinational g* values
    //  include the current pass, so the last pass's x-results read them
    //  directly. The mscan WRITE bits are then recomputable from the
    //  summary alone (no source read) -- S_CMW serves them via mscan_wbits
    //  against cmp_actall's vm||v0 arm.
    reg         found_q;  reg [31:0] ff_q;  reg [63:0] cnt_q;
    reg gfound; reg [31:0] gff; reg [63:0] gcnt; integer gsi; reg [31:0] gsig;
    always @(*) begin
        gfound=found_q; gff=ff_q; gcnt=cnt_q; gsig=32'b0;
        for (gsi = 0; gsi < `KARU_VBUS_W; gsi = gsi + 1) begin
            gsig = (gpass ? 32'd`KARU_VBUS_W : 32'd0) + gsi[31:0];
            if (gsig < vl_q && (vm_q || v0_q[gsig[7:0]]) && vs2_g[gsi]) begin
                if (!gfound) begin gfound=1'b1; gff=gsig; end
                gcnt = gcnt + 64'd1;
            end
        end
    end
    reg [VLEN-1:0] mscan_wbits; integer swi; reg swb;
    always @(*) begin
        mscan_wbits = {VLEN{1'b0}}; swb=1'b0;
        for (swi = 0; swi < VLEN; swi = swi + 1)
            if (swi < vl_q && (vm_q || v0_q[swi])) begin
                case (vs1_q[1:0])
                    2'b01: swb = found_q ? (swi[31:0] <  ff_q) : 1'b1;  //  vmsbf
                    2'b10: swb = found_q && (swi[31:0] == ff_q);        //  vmsof
                    default: swb = found_q ? (swi[31:0] <= ff_q) : 1'b1;    //  vmsif
                endcase
                mscan_wbits[swi] = swb;
            end
    end

    //  ========================================================
    //  bit-serial divide (V_DIV_C > 1): shared restoring divider, one
    //  element at a time. Combinational element extractor + restoring step;
    //  the FSM iterates elements/bits and accumulates into dresbuf.
    //  ========================================================
    reg [5:0]   dle;            //  element index within current register
    reg [6:0]   dbit;           //  bit-step counter
    reg [127:0] dacc;           //  {rem, quot} restoring accumulator
    reg [`KARU_VLEN-1:0] dresbuf;   //  result for current register (init = old vd)
    reg [63:0]  de_a, de_b, de_as, de_bs, de_maga, de_magb, de_sm;
    reg [63:0]  de_quot, de_rem, de_qs, de_rs, dres_el;
    reg         de_aneg, de_bneg, de_dz;    reg [31:0] deg, dsh;
    reg [64:0]  dtop, dsub;     reg [127:0] dacc_next;
    integer db2;
    always @(*) begin
        de_sm  = (sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
        dsh    = {26'b0, dle} * {25'b0, sewb};      //  32-bit bit-offset (element dle)
        de_a   = (vs2_g >> dsh[6:0]) & ~de_sm;  //  granule dsh[7]
        de_b   = b_vv ? ((vs1_g >> dsh[6:0]) & ~de_sm)
               : b_vx ? (rs1_q & ~de_sm) : (imm_q & ~de_sm);
        de_as  = sext(de_a, sewb);  de_bs = sext(de_b, sewb);
        de_aneg = f6_q[0] & de_as[63];  de_bneg = f6_q[0] & de_bs[63];
        //  magnitude: negated case uses the signed value negated; otherwise the
        //  zero-extended value (de_a), NOT sign-extended (else high-bit unsigned
        //  operands look negative).
        de_maga = de_aneg ? (~de_as + 64'd1) : de_a;
        de_dz   = (de_b == 64'd0);
        de_magb = de_dz ? 64'd1 : (de_bneg ? (~de_bs + 64'd1) : de_b);
        deg     = ebase + {26'b0, dle};             //  r*epr via ebase (shift)
        //  restoring step (cf. karu_m): subtract divisor from the running top.
        dtop      = {dacc[127:64], dacc[63]};
        dsub      = dtop - {1'b0, de_magb};
        dacc_next = dsub[64] ? {dtop[63:0], dacc[62:0], 1'b0}   //  borrow: keep
                                : {dsub[63:0], dacc[62:0], 1'b1};   //  subtract
        //  element result (quot/rem, negate by sign; div-by-0 edge cases).
        de_quot = dacc[63:0];   de_rem = dacc[127:64];
        de_qs   = (de_aneg ^ de_bneg) ? (~de_quot + 64'd1) : de_quot;
        de_rs   = de_aneg ? (~de_rem + 64'd1) : de_rem;
        dres_el = f6_q[1] ? (de_dz ? de_a : de_rs) : (de_dz ? {64{1'b1}} : de_qs);
    end

    //  req-time is_div (latched f6_q not yet valid at the issue/req cycle)
    wire req_is_div = (vfunct3 == 3'b010 || vfunct3 == 3'b110) && (vfunct6[5:2] == 4'b1000);

    //  ========================================================
    //  bit-serial multiply (V_MUL_C > 1): shared radix-2^K shift-and-add
    //  multiplier (cf. karu_m), one element at a time. Covers vmul/vmulh*,
    //  the MAC ops, and vsmul. Combinational extractor + result former; the
    //  FSM (S_MLOAD/S_MSTEP/S_MFIN/S_MWR) iterates elements and bit-groups.
    //  ========================================================
    reg [5:0]   mle;            //  element index within current register
    reg [6:0]   mcnt;           //  bit-group step counter
    reg [127:0] macc_acc;       //  radix accumulator (holds product after MUL_C steps)
    reg [63:0]  mmul_a;         //  latched multiplicand magnitude
    reg [`KARU_VLEN-1:0] mresbuf;   //  result for current register (init = old vd)
    reg [63:0]  m_sm, m_a, m_b, m_as, m_bs, m_cu, m_maga, m_magb, m_addend, m_smax;
    reg         m_asig, m_bsig, m_aneg, m_bneg, m_neg, m_high;  reg [31:0] msh, meg;
    reg [127:0] m_signed;   reg [63:0] mlow, mhigh, m_macmul, m_macres, mres_el;
    reg [63:0]  msm_sh, msm_res0, msm_res;  reg msm_dmsb, msm_stk, msm_lsb, msm_rnd, msm_sat;
    integer mb2;
    always @(*) begin
        m_sm   = (sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
        m_smax = (~m_sm) >> 1;
        msh    = {26'b0, mle} * {25'b0, sewb};
        m_a    = (vs2_g >> msh[6:0]) & ~m_sm;   //  granule msh[7] (rdu_g2)
        m_b    = b_vv ? ((vs1_g >> msh[6:0]) & ~m_sm)
               : b_vx ? (rs1_q & ~m_sm) : (imm_q & ~m_sm);
        m_cu   = (vold_g >> msh[6:0]) & ~m_sm;
        m_as   = sext(m_a, sewb);   m_bs = sext(m_b, sewb);
        meg    = ebase + {26'b0, mle};              //  r*epr via ebase (shift)
        //  operand signedness: vmulh s*s, vmulhu u*u, vmulhsu s*u; vmul low
        //  and the MAC ops use unsigned magnitudes (low SEW bits unaffected).
        m_high = is_mul && (f6_q[1:0] != 2'b01);
        m_asig = is_vsmul | (is_mul & (f6_q[1:0] == 2'b11 || f6_q[1:0] == 2'b10));
        m_bsig = is_vsmul | (is_mul & (f6_q[1:0] == 2'b11));
        m_aneg = m_asig & m_as[63]; m_bneg = m_bsig & m_bs[63];
        if (is_mac) begin
            //  factors: b(=vs1/x) and a(=vs2, f6[2]=1) or vd(f6[2]=0); +addend
            m_maga   = f6_q[2] ? m_a : m_cu;
            m_magb   = m_b;
            m_neg    = 1'b0;
            m_addend = f6_q[2] ? m_cu : m_a;
        end else begin
            m_maga   = m_aneg ? (~m_as + 64'd1) : m_a;
            m_magb   = m_bneg ? (~m_bs + 64'd1) : m_b;
            m_neg    = m_aneg ^ m_bneg;
            m_addend = 64'd0;
        end
        //  result former (from the final radix product in macc_acc)
        m_signed = m_neg ? (~macc_acc + 128'd1) : macc_acc;
        mlow     = macc_acc[63:0];              //  vmul / MAC product low bits
        mhigh    = m_signed >> sewb;            //  vmulh* high SEW bits (masked on write)
        m_macmul = macc_acc[63:0];
        m_macres = f6_q[1] ? (m_addend - m_macmul) : (m_addend + m_macmul);
        //  vsmul: roundoff_signed(product, sewb-1), saturate high
        msm_sh   = $signed(m_signed) >>> (sewb - 7'd1);
        msm_dmsb = (sewb < 2) ? 1'b0 : ((m_signed >> (sewb - 7'd2)) & 128'd1);
        msm_stk  = (sewb < 3) ? 1'b0 : ((m_signed & ((128'd1 << (sewb - 7'd2)) - 128'd1)) != 0);
        msm_lsb  = msm_sh[0];
        case (vxrm_q)
            2'b00: msm_rnd = msm_dmsb;
            2'b01: msm_rnd = msm_dmsb & (msm_stk | msm_lsb);
            2'b10: msm_rnd = 1'b0;
            default: msm_rnd = ~msm_lsb & (msm_dmsb | msm_stk);
        endcase
        msm_res0 = msm_sh + {63'b0, msm_rnd};
        msm_sat  = ($signed(msm_res0) > $signed({1'b0, m_smax}));
        msm_res  = msm_sat ? m_smax : msm_res0;
        //  element result select
        if (is_vsmul)    mres_el = msm_res;
        else if (is_mac) mres_el = m_macres;
        else if (m_high) mres_el = mhigh;
        else             mres_el = mlow;
    end

    //  radix-2^K step (K=MK bits/cycle). mmul_a is the multiplicand magnitude;
    //  macc_acc starts at {64'b0, mag_b} and ends holding the 128-bit product.
    wire [MK+63:0] m_partial = mmul_a * macc_acc[MK-1:0];
    wire [MK+63:0] m_sum     = macc_acc[127:64] + m_partial;
    wire [127:0]   m_next     = { m_sum, macc_acc[63:MK] };

    //  req-time is_mul (covers mul/mulh*, MAC, vsmul) for the FSM branch
    wire req_is_mul =
        ((vfunct3 == 3'b010 || vfunct3 == 3'b110) &&
           ((vfunct6[5:2] == 4'b1001) || ((vfunct6[5:3] == 3'b101) && vfunct6[0])))
     || ((vfunct3 == 3'b000 || vfunct3 == 3'b100) && (vfunct6 == 6'b100111));

    //  ========================================================
    //  widening (OPMV 11xxxx): produce one wide (2*SEW) dest register per
    //  cycle. dest reg r in [0, 2*LMUL); narrow sources at reg r>>1, half
    //  r[0] (.vv/mul/mac); .w forms read vs2 wide at reg r. Masked + tailed.
    //  ========================================================
    wire [31:0] ebase_w = {28'b0, r} << eprw_lg;    //  == r*epr_w; shift, not DSP
    wire [31:0] epg_w32 = epr_w >> 1;               //  wide elements per granule
    wire [31:0] w_gbase = gpass[0] ? epg_w32 : 32'd0;   //  this pass's wide window
    reg [`KARU_VLEN-1:0] wide_res;
    integer we_i, wbj, w_noff;
    reg [63:0]  w_na, w_nb, w_na_s, w_nb_s, w_wa, w_vd, w_nsm, w_wsm;
    reg [63:0]  w_aa, w_bb, w_eres, w_pa, w_pb; reg [127:0] w_prod;
    reg         w_asig, w_bsig; reg [31:0] w_eg;    reg w_act;
    always @(*) begin
        wide_res = {`KARU_VLEN{1'b0}};  //  6c-b: keep-old = the suppressed byte enable
        w_na=0; w_nb=0; w_na_s=0; w_nb_s=0; w_wa=0; w_vd=0; w_aa=0; w_bb=0;
        w_eres=0; w_pa=0; w_pb=0; w_prod=0; w_asig=0; w_bsig=0; w_eg=0; w_act=0; w_noff=0; w_aa=0; w_bb=0;
        w_nsm = (sewb  >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
        w_wsm = (wsewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << wsewb);
        //  one GRANULE of the wide dest per pass (gpass): narrow sources for
        //  dest reg r all live in source granule r[0] (epr_w == epg; in-
        //  granule element = we_i), the wide vs2 (.w) and the mac addend
        //  live in granule gpass (in-granule element = we_i - w_gbase).
        for (we_i = 0; we_i < VLEN/16; we_i = we_i + 1) begin
            if (we_i < epr_w && we_i >= w_gbase && we_i < (w_gbase + epg_w32)) begin
                w_eg   = ebase_w + we_i[31:0];
                w_act  = vm_q || v0_q[w_eg[7:0]];
                w_noff = (r[0] ? epr_w : 32'd0) + we_i[31:0];   //  narrow elem index in src reg
                w_na   = (vs2_g >> (we_i << sew_lg)) & ~w_nsm;
                w_nb   = b_vv ? ((vs1_g >> (we_i << sew_lg)) & ~w_nsm)
                       : b_vx ? (rs1_q & ~w_nsm) : (imm_q & ~w_nsm);
                w_na_s = sext(w_na, sewb);  w_nb_s = sext(w_nb, sewb);
                w_wa   = (vs2_g  >> ((we_i - w_gbase) << wsew_lg)) & ~w_wsm;    //  wide vs2 (.w)
                w_vd   = (vold_g >> ((we_i - w_gbase) << wsew_lg)) & ~w_wsm;    //  wide mac addend
                if (wide_mul || wide_mac) begin
                    //  combinational widening mul only when V_MUL_C==1; otherwise
                    //  the serial multiplier (S_WMLOAD/S_MSTEP/S_WMFIN) handles it
                    //  and this product is constant-folded away.
                    if (V_MUL_C == 1) begin
                        //  a = vs2, b = vs1/x. signedness per op.
                        if (wide_mul) begin w_asig = f6_q[1];          w_bsig = f6_q[0]; end
                        else          begin w_asig = f6_q[1] ^ f6_q[0]; w_bsig = f6_q[0]; end
                        //  signed operand uses the (≤33-bit) sign-extended value;
                        //  unsigned uses the zero-extended value (positive in 64b),
                        //  so a single signed 64×64 covers all sign combinations.
                        w_pa   = w_asig ? w_na_s : w_na;
                        w_pb   = w_bsig ? w_nb_s : w_nb;
                        w_prod = $signed(w_pa) * $signed(w_pb);
                        w_eres = wide_mac ? (w_vd + w_prod[63:0]) : w_prod[63:0];
                    end
                end else begin
                    //  add/sub: a = wide vs2 (.w) or extended narrow; b = extended narrow
                    w_asig = f6_q[0];   w_bsig = f6_q[0];
                    w_aa   = wide_w ? w_wa : (w_asig ? w_na_s : w_na);
                    w_bb   = w_bsig ? w_nb_s : w_nb;
                    w_eres = f6_q[1] ? (w_aa - w_bb) : (w_aa + w_bb);
                end
                for (wbj = 0; wbj < 8; wbj = wbj + 1)
                    if (wbj < (wsewb >> 3)) begin
                        //  6c-b: BE keep-old; no d_vold merge in the cone
                        if (w_eg < vl_q && w_act)
                            wide_res[(we_i*(wsewb>>3)+wbj)*8 +: 8] = w_eres[wbj*8 +: 8];
                    end
            end
        end
    end

    //  req-time is_wide / is_narrow for the FSM branch selection
    wire req_is_wide   = (vfunct3 == 3'b010 || vfunct3 == 3'b110) && (vfunct6[5:4] == 2'b11);
    wire req_is_narrow = (vfunct3 == 3'b000 || vfunct3 == 3'b100 || vfunct3 == 3'b011)
                       && (vfunct6[5:2] == 4'b1011);
    //  widening mul/mac (funct6 111xxx) -- routed to the serial multiplier when BS_MUL
    wire req_is_wmul   = req_is_wide && (vfunct6[5:3] == 3'b111);

    //  ========================================================
    //  widening serial multiply (V_MUL_C>1): per-element radix multiply
    //  (reuses macc_acc / mmul_a / mcnt / m_next and the S_MSTEP step) with
    //  widening operand extraction + a 2*SEW result former. mle = wide elem.
    //  ========================================================
    reg [63:0]  wm_na, wm_nb, wm_na_s, wm_nb_s, wm_maga, wm_magb, wm_vd, wm_nsm, wm_wsm, wm_res;
    reg         wm_asig, wm_bsig, wm_aneg, wm_bneg, wm_neg; reg [31:0] wm_eg;   integer wm_noff;
    reg [127:0] wm_signed;
    wire [31:0] wm_vsh = {26'b0, mle} << wsew_lg;   //  wide-element bit offset
    always @(*) begin
        wm_nsm = (sewb  >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
        wm_wsm = (wsewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << wsewb);
        wm_noff = (r[0] ? epr_w : 32'd0) + {26'b0, mle};    //  narrow operand position
        //  the narrow window for dest reg r is exactly source granule r[0]
        //  (epr_w == epg); in-granule element = mle
        wm_na   = (vs2_g >> ({26'b0, mle} << sew_lg)) & ~wm_nsm;
        wm_nb   = b_vv ? ((vs1_g >> ({26'b0, mle} << sew_lg)) & ~wm_nsm)
                : b_vx ? (rs1_q & ~wm_nsm) : (imm_q & ~wm_nsm);
        wm_na_s = sext(wm_na, sewb);    wm_nb_s = sext(wm_nb, sewb);
        wm_vd   = (vold_g >> wm_vsh[6:0]) & ~wm_wsm;    //  wide dest old (granule wm_vsh[7])
        wm_eg   = ebase_w + {26'b0, mle};           //  r*epr_w via ebase_w (shift)
        if (wide_mul) begin wm_asig = f6_q[1];          wm_bsig = f6_q[0]; end
        else          begin wm_asig = f6_q[1] ^ f6_q[0]; wm_bsig = f6_q[0]; end
        wm_aneg = wm_asig & wm_na_s[63];    wm_bneg = wm_bsig & wm_nb_s[63];
        wm_maga = wm_aneg ? (~wm_na_s + 64'd1) : wm_na;
        wm_magb = wm_bneg ? (~wm_nb_s + 64'd1) : wm_nb;
        wm_neg  = wm_aneg ^ wm_bneg;
        wm_signed = wm_neg ? (~macc_acc + 128'd1) : macc_acc;
        wm_res  = wide_mac ? (wm_vd + wm_signed[63:0]) : wm_signed[63:0];
    end

    //  ========================================================
    //  narrowing (OPIV 1011xx): vs2 = 2*SEW (2*LMUL group), dest = SEW.
    //  Two phases per narrow dest reg: phase 0 reads wide src reg 2r (low
    //  epr_w dest elems), phase 1 reads 2r+1 (high). nbuf carries the result
    //  across phases (seed = old dest); written at phase 1. vnclip* saturate.
    //  ========================================================
    reg [`KARU_VLEN-1:0] nbuf, narrow_merge;
    //  2-STAGE PIPELINE (halves the per-cycle narrow combinational depth):
    //    stage A (S_NA): extract wide elem + variable shift + rounding-detect for
    //                    the window [nse,nse+NWIN); registered into pA_*.
    //    stage B (S_NB): add round + clip-to-SEW + merge into the dest-reg buffer.
    reg  [NWIN*64-1:0] nA_sh,  pA_sh;   //  shifted value per window element
    reg  [NWIN-1:0]    nA_rnd, pA_rnd;  //  rounding increment bit
    reg  [NWIN*6-1:0]  nA_loc, pA_loc;  //  dest narrow-element index (<= epr-1)
    reg  [NWIN-1:0]    nA_we,  pA_we;   //  write-enable (active & in-vl)
    //  -- stage A combinational --
    wire n_g2 = ({26'b0, nse} >= epg_w32);      //  this window's wide granule
    integer ne_i, nk, n_loc;
    reg [63:0]  n_wide, n_wide_s, n_b, n_shamt, n_shval, n_sh, n_nsm, n_wsm;
    reg         n_dmsb, n_stk, n_lsb, n_rnd, n_act; reg [31:0] n_eg;
    always @(*) begin
        nA_sh = {NWIN*64{1'b0}}; nA_rnd = {NWIN{1'b0}}; nA_loc = {NWIN*6{1'b0}}; nA_we = {NWIN{1'b0}};
        n_wide=0; n_wide_s=0; n_b=0; n_shamt=0; n_shval=0; n_sh=0;
        n_dmsb=0; n_stk=0; n_lsb=0; n_rnd=0; n_act=0; n_eg=0; n_loc=0;
        n_nsm  = (sewb  >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
        n_wsm  = (wsewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << wsewb);
        for (nk = 0; nk < NWIN; nk = nk + 1) begin
            ne_i = {26'b0, nse} + nk;
            if (ne_i < epr_w) begin
                n_loc = (nph ? epr_w : 32'd0) + ne_i;       //  dest narrow elem index
                n_eg  = ebase + n_loc[31:0];            //  r*epr via ebase (shift)
                n_act = vm_q || v0_q[n_eg[7:0]];
                //  wide source granule = n_g2 (window-aligned: NWIN divides
                //  epg_w); narrow shift-amount vs1 lives in granule nph
                //  (n_loc spans [nph*epr_w, nph*epr_w+epr_w) = granule nph)
                n_wide   = (vs2_g >> ((ne_i - (n_g2 ? epg_w32 : 32'd0)) << wsew_lg)) & ~n_wsm;
                n_wide_s = sext(n_wide, wsewb);
                n_b   = b_vv ? ((vs1_g >> (ne_i << sew_lg)) & ~n_nsm)
                      : b_vx ? rs1_q : imm_q;
                n_shamt = (b_vi ? {59'b0, imm_q[4:0]} : n_b) & ({57'b0, wsewb} - 64'd1);
                n_shval = f6_q[0] ? n_wide_s : n_wide;
                if (f6_q[0]) n_sh = $signed(n_wide_s) >>> n_shamt;  //  arith (nsra/nclip)
                else         n_sh = n_wide >> n_shamt;              //  logical (nsrl/nclipu)
                //  rounding (applied for vnclip*; vnsrl/vnsra truncate)
                n_dmsb = (n_shamt == 0) ? 1'b0 : ((n_shval >> (n_shamt - 64'd1)) & 64'd1);
                n_stk  = (n_shamt <= 1) ? 1'b0
                       : ((n_shval & ((64'd1 << (n_shamt - 64'd1)) - 64'd1)) != 0);
                n_lsb  = n_sh[0];
                case (vxrm_q)
                    2'b00: n_rnd = n_dmsb;
                    2'b01: n_rnd = n_dmsb & (n_stk | n_lsb);
                    2'b10: n_rnd = 1'b0;
                    default: n_rnd = (n_shamt != 0) & ~n_lsb & (n_dmsb | n_stk);
                endcase
                nA_sh[nk*64 +: 64] = n_sh;
                nA_rnd[nk]         = n_rnd;
                nA_loc[nk*6 +: 6]  = n_loc[5:0];
                nA_we[nk]          = n_act && (n_eg < vl_q);
            end
        end
    end
    //  -- stage B combinational (from the registered pA_*) --
    integer nbj, nk2;
    reg [`KARU_VLEN-1:0] n_base;
    reg [63:0]  nB_sh, nB_res0, nB_res, nB_nsm, nB_umax, nB_smax, nB_smin;
    reg         nB_rnd, n_clipsat, n_grpsat;    reg [5:0] nB_loc;
    always @(*) begin
        //  seed = old vd at the dest reg's first window (phase 0, nse 0), else the
        //  carried nbuf (across windows + the two phases).
        n_base       = (nph == 1'b0 && nse == 6'd0) ? {`KARU_VLEN{1'b0}} : nbuf;
        narrow_merge = n_base;  n_grpsat = 1'b0;
        nB_sh=0; nB_res0=0; nB_res=0; n_clipsat=0; nB_rnd=0; nB_loc=0;
        nB_nsm  = (sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
        nB_umax = ~nB_nsm;  nB_smax = (~nB_nsm) >> 1;   nB_smin = nB_smax + 64'd1;
        for (nk2 = 0; nk2 < NWIN; nk2 = nk2 + 1) begin
            nB_sh  = pA_sh[nk2*64 +: 64];
            nB_rnd = pA_rnd[nk2];
            nB_loc = pA_loc[nk2*6 +: 6];
            nB_res0 = nB_sh + (narrow_clip ? {63'b0, nB_rnd} : 64'd0);
            n_clipsat = 1'b0;
            if (narrow_clip && !f6_q[0]) begin              //  vnclipu (unsigned)
                if (nB_res0 > nB_umax) begin nB_res = nB_umax; n_clipsat = 1'b1; end
                else nB_res = nB_res0;
            end else if (narrow_clip) begin                 //  vnclip (signed)
                if ($signed(nB_res0) > $signed({1'b0, nB_smax}))
                    begin nB_res = nB_smax; n_clipsat = 1'b1; end
                else if ($signed(nB_res0) < $signed(-{1'b0, nB_smin}))
                    begin nB_res = nB_smin; n_clipsat = 1'b1; end
                else nB_res = nB_res0;
            end else nB_res = nB_res0;
            if (narrow_clip && n_clipsat && pA_we[nk2]) n_grpsat = 1'b1;
            //  masked-off / tail were excluded from pA_we -> keep seed (undisturbed)
            if (pA_we[nk2])
                for (nbj = 0; nbj < 8; nbj = nbj + 1)
                    if (nbj < (sewb >> 3))
                        narrow_merge[({26'b0,nB_loc}*(sewb>>3) + nbj[31:0])*8 +: 8] = nB_res[nbj*8 +: 8];
        end
    end

    //  ========================================================
    //  reductions (OPMVV 0000xx single-width / OPIVV 11000x widening): fold
    //  all active in-vl elements of the vs2 group into one accumulator,
    //  seeded by vs1[0], result -> vd[0]. One source register folded per
    //  cycle (combinational reduction across that register's elements).
    //  ========================================================
    //  2-STAGE PIPELINE (halves the per-cycle reduction-tree depth that was the
    //  125 MHz worst path): stage A (S_RED_A) extracts chunk rch's elements and
    //  folds 2 tree levels (REPC->2 partials); stage B (S_RED_B) does the last
    //  fold (2->1) + the combine with the running accumulator. One 64-bit chunk
    //  per A/B pair; the accumulator seeds from vs1[0] at the very first chunk.
    reg [63:0]  red_acc, red_next;
    //  shared, combinational on the (quasi-static) latched config -- used by both stages
    wire [6:0]  rwidth   = is_wred ? wsewb : sewb;
    wire [63:0] red_csm  = (rwidth >= 7'd64) ? 64'h0 : ({64{1'b1}} << rwidth);  //  result-width mask
    wire [63:0] red_ssm  = (sewb   >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);        //  SEW element mask
    wire [63:0] red_seed = vs1_g & ~red_csm;    //  vs1[0] scalar seed (granule 0)
    wire [63:0] red_base = (r == 4'd0 && rch == 4'd0) ? red_seed : red_acc;
    wire [2:0]  red_op   = is_wred ? 3'b000 : f6_q[2:0];                        //  widening = sum
    wire [63:0] red_ident = (red_op == 3'b001 || red_op == 3'b100) ? {64{1'b1}}         //  and / minu
                           : (red_op == 3'b101) ? ((64'h1 << (sewb - 7'd1)) - 64'h1)        //  min : SEW max-positive
                           : (red_op == 3'b111) ?  (64'h1 << (sewb - 7'd1))             //  max : SEW min-negative
                           :                       64'h0;                               //  sum / or / xor / maxu

    //  ---- stage A (combinational): extract chunk + fold 2 levels (REPC -> 2) ----
    reg [63:0]  red_t [0:2][0:REPC-1];  //  levels 0,1,2 of the chunk tree
    reg [63:0]  red_el, red_elx, nA_pp0, nA_pp1;    reg [31:0] rfeg;    integer rfe, rlev;
    always @(*) begin
        red_el = 0; red_elx = 0; rfeg = 0;
        //  level 0: the (<=REPC) SEW elements of chunk rch (bit rch*64 + rfe*sewb),
        //  widened for vwred; inactive/out-of-vl/beyond-epc -> identity.
        for (rfe = 0; rfe < REPC; rfe = rfe + 1) begin
            rfeg    = ebase + ({28'b0, rch} << epc_lg) + rfe[31:0]; //  r*epr + rch*epc_w; shifts
            //  chunk rch lives in granule rch[1]; in-granule chunk = rch[0]
            red_el  = (vs2_g >> (({31'b0, rch[0]} << 6) + (rfe[31:0] << sew_lg))) & ~red_ssm;
            red_elx = is_wred ? (f6_q[0] ? sext(red_el, sewb) : red_el) : red_el;
            red_t[0][rfe] = (({28'b0, rfe[3:0]} < epc_w) && (rfeg < vl_q) && (vm_q || v0_q[rfeg[7:0]]))
                          ? red_elx : red_ident;
        end
        //  fold 2 levels: REPC -> REPC/2 -> REPC/4 (= 2 for REPC=8)
        for (rlev = 0; rlev < 2; rlev = rlev + 1)
            for (rfe = 0; rfe < (REPC >> (rlev + 1)); rfe = rfe + 1)
                red_t[rlev+1][rfe] = redop(red_t[rlev][2*rfe], red_t[rlev][2*rfe+1], red_op, sewb);
        nA_pp0 = red_t[2][0];
        nA_pp1 = red_t[2][1];
    end

    //  ---- stage B (combinational, from the registered partials): last fold + accumulate ----
    reg [63:0]  red_pp0, red_pp1;   //  pipeline registers (stage A -> B)
    reg [63:0]  red_t3;
    reg [`KARU_VLEN-1:0] red_wdata; integer rwb;
    always @(*) begin
        red_t3   = redop(red_pp0, red_pp1, red_op, sewb);           //  final fold (2 -> 1)
        red_next = redop(red_base, red_t3, red_op, sewb) & ~red_csm;    //  combine with running base
        //  dest register: element0 = result; the rest stay undisturbed (old vd).
        //  Bound the copy to 8 bytes (rwidth<=64) -- looping to VLENB makes
        //  red_acc[rwb*8+:8] a statically out-of-range select (Vivado 8-524).
        red_wdata = {`KARU_VLEN{1'b0}}; //  6c-b: keep-old = the suppressed byte enable
        for (rwb = 0; rwb < 8; rwb = rwb + 1)
            if (rwb < (rwidth >> 3)) red_wdata[rwb*8 +: 8] = red_acc[rwb*8 +: 8];
    end
    wire req_is_reduce = ((vfunct3 == 3'b010) && (vfunct6[5:3] == 3'b000))
                       || ((vfunct3 == 3'b000) && (vfunct6[5:1] == 5'b11000));

    //  ========================================================
    //  VPERM (cross-lane): gather / slides / compress / iota.
    //  Both source groups are buffered first (S_PLOAD), then one dest
    //  register is computed+written per cycle (S_PCOMP) from the buffers.
    //  ========================================================
    //  source element g (SEW-wide) out of the flat source buffer pbuf
    function [63:0] pelem; input [31:0] g; reg [63:0] sm; reg [31:0] sh;
        begin
            sm = (sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);
            sh = g << sew_lg;                   //  == g * sewb (sewb = 2^sew_lg); shift, not DSP
`ifdef KARU_V_PERM_RAM
            //  SEW divides 64, so an element never straddles a word
            pelem = (pram[sh[6 +: PWW]] >> sh[5:0]) & ~sm;
`else
            pelem = (pbuf >> sh) & ~sm;
`endif
        end
    endfunction
    //  gather index value at element ge (SEW-wide from ibuf; ei16 -> 16-bit)
    function [63:0] gidx; input [31:0] ge; reg [63:0] sm; reg [31:0] sh; reg [6:0] iw;
        begin
            iw = is_gei16 ? 7'd16 : sewb;
            sm = (iw >= 7'd64) ? 64'h0 : ({64{1'b1}} << iw);
            sh = ge << (is_gei16 ? 6'd4 : sew_lg);  //  == ge * iw (iw = 2^lg); shift, not DSP
`ifdef KARU_V_PERM_RAM
            gidx = (iram[sh[6 +: PWW]] >> sh[5:0]) & ~sm;
`else
            gidx = (ibuf >> sh) & ~sm;
`endif
        end
    endfunction

    //  scalar offset / insert value: slide1* use 1; .vx uses x[rs1]; .vi uses
    //  the *unsigned* uimm5 (slides/gather immediates are zero-extended).
    wire [63:0] slide_off = (is_slide1up || is_slide1dn) ? 64'd1
                           : b_vx ? rs1_q : {59'b0, imm_q[4:0]};
    wire [63:0] gidx_sx   = b_vx ? rs1_q : {59'b0, imm_q[4:0]}; //  gather.vx/.vi index
    wire [63:0] elem_sm   = (sewb >= 7'd64) ? 64'h0 : ({64{1'b1}} << sewb);

    //  -- vcompress: SERIAL pack (replaces the old full-VLEN cmp_obuf scatter:
    //  a VLEN-wide prefix network + VLEN GBUF-wide barrel-shifts, which was the
    //  dominant Vivado tech-mapping hotspot and bypassed KARU_V_PERM_LANES).
    //  The pack is sequenced one source element/cycle (S_CMP_SCAN): out_idx is
    //  a plain running popcount (no prefix net), and each mask-selected source
    //  element is written with ONE variable byte-select/cycle. Dest pack
    //  (streaming): elements go into a single VLEN-wide staging register
    //  cstg; each time a dest register fills it is drained MID-SCAN through
    //  the shared S_CWB granule funnel (S_CMP_FLUSH, full BE -- every slot
    //  is freshly packed). S_CMP_WR then writes the final partial register
    //  with an exact lo_be and zero-BE-pads the remaining group registers
    //  (slot >= count -> UNDISTURBED via the suppressed enables, spec 16.5),
    //  so the op still ends with g_wlast on a register-final granule (WGN2)
    //  even when the packed bytes stop in an earlier granule. Special case:
    //  filling the group's LAST register implies count==VLMAX (all-selected),
    //  so that flush IS the op-ending drain (nothing left to scan or pad).
    //  No group buffer and no old-vd merge exist on this path.
    //  NB: vcompress vd/vs1/vs2 overlap is a reserved encoding; the buffered
    //  source (pbuf/ibuf) keeps overlap benign, but the core does NOT trap
    //  reserved encodings (unchecked by design). --
    reg [`KARU_VLEN-1:0] cstg;      //  staging: the dest register being packed
    reg [31:0]     cslot;           //  next free element slot within cstg
    reg [31:0]     cse;             //  source element index being examined
    reg [31:0]     out_idx;         //  packed count so far = next free dest slot
    reg [31:0]     cmp_count;       //  final packed count (latched at scan end)
`ifdef KARU_V_PERM_RAM
    wire           cmp_sel = (cse < vl_q) && iram[cse[6 +: PWW]][cse[5:0]]; //  in-vl & mask-selected
`else
    wire           cmp_sel = (cse < vl_q) && ibuf[cse[7:0]];    //  in-vl & mask-selected
`endif
    wire [63:0]    cmp_src = pelem(cse) & ~elem_sm;         //  one source element
    integer csb;

    //  -- per-dest-register compute, WINDOWED to PLANES elements/cycle.
    //  Each cycle merges the elements [pse, pse+PLANES) of register r into the
    //  accumulator (seeded with old vd at pse==0, carried in `pacc` otherwise);
    //  the register is written when the window reaches `epr`. This bounds the
    //  number of data-indexed source selects (`pelem`/`gidx` barrel muxes) to
    //  PLANES per cycle -- the knob that keeps the gather crossbar synthesizable.
    //  vrgather.vx/.vi collapse to a single broadcast (`bcast`, one pelem).
    reg [`KARU_VLEN-1:0] perm_res;  reg [31:0] iota_next;
    integer lane, pbb;
    reg [31:0] pe, pge, icnt;   reg [63:0] pidx, praw, psrc64, bcast;   reg pact, pwr, psrcbit;
`ifdef KARU_V_PERM_RAM
    reg [31:0] prd; reg [63:0] pval;                //  the one shared source read
`endif
    always @(*) begin
        perm_res = (pse == 32'd0) ? {`KARU_VLEN{1'b0}} : pacc;  //  6c-b: BE keep-old
        icnt = iota_acc;
`ifndef KARU_V_PERM_RAM
        //  vrgather.vx/.vi: one scalar/imm index -> one source read, broadcast
        bcast = (gidx_sx < {32'b0, vlmax}) ? pelem(gidx_sx[31:0]) : 64'd0;
`else
        bcast = 64'd0;          //  unused under PERM_RAM (gscalar reads pval)
`endif
        pe=0; pge=0; pidx=0; praw=0; psrc64=0; pact=0; pwr=0; psrcbit=0;
`ifdef KARU_V_PERM_RAM
        prd=0; pval=64'd0;
`endif
        if (is_perm)
        for (lane = 0; lane < PLANES; lane = lane + 1) begin
            pe = pse + lane[31:0];              //  element index within register r
            if (pe < epr) begin
                pge  = ebase + pe;
                pact = vm_q || v0_q[pge[7:0]];
                praw = 64'd0;   pwr = 1'b0;
`ifdef KARU_V_PERM_RAM
                //  ONE shared source-element read per cycle (one async pram
                //  port): the op class selects the index up front and the arms
                //  consume pval under their own bound checks. An out-of-range
                //  index may wrap the RAM word address; every arm that can
                //  produce one discards pval on exactly that condition.
                pidx = gidx(pge);
                prd  = is_gscalar  ? gidx_sx[31:0]
                     : is_gvv      ? pidx[31:0]
                     : is_slideup  ? (pge - slide_off[31:0])
                     : is_slide1up ? (pge - 32'd1)
                     : is_slidedn  ? (pge + slide_off[31:0])
                     :               (pge + 32'd1);     //  slide1dn
                pval = pelem(prd);
`endif
                if (is_viota) begin
                    praw = {32'b0, icnt};
                    pwr  = (pge < vl_q);
                    //  count active source-mask bits strictly before the NEXT element
`ifdef KARU_V_PERM_RAM
                    psrcbit = pram[pge[6 +: PWW]][pge[5:0]];    //  vs2 mask register, bit pge
`else
                    psrcbit = pbuf[pge[7:0]];       //  vs2 mask register, bit pge
`endif
                    if (pge < vl_q && pact && psrcbit) icnt = icnt + 32'd1;
                end else if (is_gscalar) begin
`ifdef KARU_V_PERM_RAM
                    praw = (gidx_sx < {32'b0, vlmax}) ? pval : 64'd0;
`else
                    praw = bcast;
`endif
                    pwr = (pge < vl_q);                             //  vrgather.vx/.vi splat
                end else if (is_gvv) begin
`ifdef KARU_V_PERM_RAM
                    praw = (pidx < {32'b0, vlmax}) ? pval : 64'd0;  //  vrgather.vv / ei16
`else
                    pidx = gidx(pge);                               //  vrgather.vv / ei16
                    praw = (pidx < {32'b0, vlmax}) ? pelem(pidx[31:0]) : 64'd0;
`endif
                    pwr  = (pge < vl_q);
                end else if (is_slideup) begin
                    //  64-bit offset compare (x[rs1] may exceed 2^32 -> all prestart);
                    //  the guard guarantees slide_off<=pge<=VLMAX so the low bits used
                    //  for the source index are exact.
                    if (({32'b0, pge} >= slide_off) && (pge < vl_q)) begin
`ifdef KARU_V_PERM_RAM
                        praw = pval;    pwr = 1'b1;
`else
                        praw = pelem(pge - slide_off[31:0]);    pwr = 1'b1;
`endif
                    end //  pge < off: prestart, undisturbed
                end else if (is_slide1up) begin
                    if (pge < vl_q) begin
`ifdef KARU_V_PERM_RAM
                        praw = (pge == 32'd0) ? (rs1_q & ~elem_sm) : pval;
`else
                        praw = (pge == 32'd0) ? (rs1_q & ~elem_sm) : pelem(pge - 32'd1);
`endif
                        pwr  = 1'b1;
                    end
                end else if (is_slidedn) begin
                    if (pge < vl_q) begin
                        psrc64 = {32'b0, pge} + slide_off;
`ifdef KARU_V_PERM_RAM
                        //  prd == psrc64[31:0] when in bounds (mod-2^32 equal)
                        praw   = (psrc64 < {32'b0, vlmax}) ? pval : 64'd0;
`else
                        praw   = (psrc64 < {32'b0, vlmax}) ? pelem(psrc64[31:0]) : 64'd0;
`endif
                        pwr    = 1'b1;
                    end
                end else if (is_slide1dn) begin
                    if (pge < vl_q) begin
`ifdef KARU_V_PERM_RAM
                        praw = (pge == (vl_q - 32'd1)) ? (rs1_q & ~elem_sm) : pval;
`else
                        praw = (pge == (vl_q - 32'd1)) ? (rs1_q & ~elem_sm) : pelem(pge + 32'd1);
`endif
                        pwr  = 1'b1;
                    end
                end
                //  write merge (per byte): tail -> vta?FF:old; masked/prestart -> old
                //  (vcompress is no longer here -- it has its own S_CMP_* path)
                for (pbb = 0; pbb < 8; pbb = pbb + 1)
                    if (pbb < (sewb >> 3)) begin
                        //  6c-b: unwritten bytes keep the seed/pacc carry --
                        //  BE preserves; no d_vold merge (slideup's below-
                        //  offset bytes are excluded by act_be's elo bound)
                        if (pge < vl_q && pwr && pact)
                            perm_res[(pe*(sewb>>3)+pbb)*8 +: 8] = praw[pbb*8 +: 8];
                    end
            end
        end
        iota_next = icnt;
    end

    //  req-time perm detection (input fields; _q not yet valid at S_IDLE)
    wire rq_opiv = (vfunct3 == 3'b000) || (vfunct3 == 3'b100) || (vfunct3 == 3'b011);
    wire req_is_perm =
           (rq_opiv && vfunct6 == 6'b001100)                            //  vrgather
        || ((vfunct3 == 3'b000) && vfunct6 == 6'b001110)            //  vrgatherei16
        || (((vfunct3 == 3'b100) || (vfunct3 == 3'b011)) &&         //  vslideup/down
            (vfunct6 == 6'b001110 || vfunct6 == 6'b001111))
        || ((vfunct3 == 3'b110) &&                                  //  vslide1up/down
            (vfunct6 == 6'b001110 || vfunct6 == 6'b001111))
        || ((vfunct3 == 3'b010) && vfunct6 == 6'b010111)            //  vcompress
        || ((vfunct3 == 3'b010) && vfunct6 == 6'b010100 && vs1_base == 5'b10000); //    viota

    //  ========================================================
    //  Vector floating-point datapath (OPFVV/OPFVF). Per-element reuse of the
    //  in-lane karu_fpu / karu_vest7. 2b sequences elements through lane 0's
    //  FPU (bit-identical to the old karu_vfpu); 2d dispatches the element-wise
    //  ops across all NLANES lane FPUs in parallel. All FP-local signals carry a
    //  vf_ prefix to avoid colliding with the integer datapath; the shared
    //  latched fields (f3_q/f6_q/vsew_q/vl_q/vm_q/vta_q/vma_q/v0_q/vd_q/vs1_q/
    //  vs2_q/nreg_q/epr) + frm_q/frs1_q are reused.
    //  ========================================================
    reg  [31:0]            fe;          //  FP element index within the (dest) register (seq path)
    reg  [3:0]             fs;          //  FP slot within a 64-bit chunk (parallel path, 0..epc_w-1)
    reg  [NLANES-1:0]      fp_pend;     //  parallel dispatch: lanes whose FPU op is outstanding
    reg  [63:0]            fracc;       //  FP reduction accumulator
    reg  [`KARU_VLEN-1:0]  fdbuf;       //  FP dest-register buffer
    reg  [`KARU_VLEN-1:0]  fmbuf;       //  FP compare-mask buffer
    //  Shared COLD whole-register -> granule writeback drain (S_CWB). A cold WR
    //  site loads these and enters S_CWB instead of driving a 256-bit whole-reg
    //  write. cwb_buf holds the assembled register; S_CWB writes it one VBUS_W
    //  granule per cycle (ascending), then advances r / returns to cwb_ret (or
    //  asserts done when cwb_done). r is held during the drain so operands stay
    //  stable (op_stall cannot freeze mid-write).
    reg  [`KARU_VLEN-1:0]  cwb_buf;
    reg  [4:0]            cwb_wd;
    reg  [GPW-1:0]        cwb_g;
    reg  [5:0]            cwb_ret;      //  state to enter after the granule writes
    reg                   cwb_done; //  assert done (op end) instead of returning
    reg                   cwb_wlast;    //  this op's final register -> g_wlast on last granule
    //  KARU_V_CWB_STAGE: decouple the COLD-funnel assembly register from the
    //  drain register. The deep combinational whole-register assemblies
    //  (ext_res/wide_res/narrow_merge/red_wdata/perm_res) head the route-bound
    //  vsew_q->cwb_buf cone -- the full-vector bit's sole core limiter (-2.195 ns
    //  @75 MHz, 83% route: cwb_buf is pinned at the VRF-write funnel, far from the
    //  assembly LUTs). Mirroring the S_GWB / S_FPWB lane & FP writeback stages:
    //  the assembly now lands in a DEDICATED register cwb_asm (free to cluster
    //  near the assembly), and a one-cycle S_CSTAGE hop copies it into cwb_buf for
    //  the drain. +1 cycle per staged cold register write (all latency-tolerant
    //  ops). Knob-off => the macros are cwb_buf / S_CWB => byte-identical (no
    //  cwb_asm register, no S_CSTAGE arm).
`ifdef KARU_V_CWB_STAGE
    reg  [`KARU_VLEN-1:0]  cwb_asm; //  cold assembly-output stage (placed near the assembly)
    `define CWB_T  cwb_asm
    `define CWB_NX S_CSTAGE
`else
    `define CWB_T  cwb_buf
    `define CWB_NX S_CWB
`endif
    //  KARU_V_FPWB_STAGE: register the non-FPU per-lane FP result (vf_p_relem,
    //  whose f6_q->est->fdbuf cone is the 10ns limiter) before the fdbuf write.
    //  S_FPAR registers these; S_FPWB writes fdbuf + advances. Cuts the cone.
    reg  [NLANES*64-1:0]  fp_relem_q;
    reg  [NLANES-1:0]     fp_wr_q;
    reg  [4:0]            fp_estfl_q;
    //  Sequential path (S_FRUN): the same lane_est cone reaches fdbuf via
    //  vf_res_elem (vf_is_est ? vf_est_res). Once the parallel path is staged
    //  this is the LAST combinational lane_est->fdbuf path (it is the 10ns
    //  limiter). S_FRUN registers the element result -> S_FSWB writes fdbuf +
    //  advances fe. Mirrors the S_FPAR/S_FPWB split.
    reg  [63:0]           f_relem_q;
    reg  [4:0]            f_estfl_q;
    reg                    vf_fpu_req;  //  FSM pulse -> lane FPU(s)

    wire        vf_is_d   = (vsew_q == 3'd3);
    wire        vf_is_vf  = (f3_q == 3'b101);
    wire        vf_is_add  = (f6_q == 6'b000000);
    wire        vf_is_sub  = (f6_q == 6'b000010);
    wire        vf_is_rsub = vf_is_vf && (f6_q == 6'b100111);
    wire        vf_is_mul  = (f6_q == 6'b100100);
    wire        vf_is_div  = (f6_q == 6'b100000);
    wire        vf_is_rdiv = vf_is_vf && (f6_q == 6'b100001);
    wire        vf_is_min  = (f6_q == 6'b000100);
    wire        vf_is_max  = (f6_q == 6'b000110);
    wire        vf_is_sgnj = (f6_q == 6'b001000);
    wire        vf_is_sgnjn= (f6_q == 6'b001001);
    wire        vf_is_sgnjx= (f6_q == 6'b001010);
    wire        vf_is_unary= (f6_q == 6'b010011);           //  VFUNARY1
    wire        vf_is_sqrt = vf_is_unary && (vs1_q == 5'b00000);
    wire        vf_is_class= vf_is_unary && (vs1_q == 5'b10000);
    wire        vf_is_rsqrt7 = vf_is_unary && (vs1_q == 5'b00100);
    wire        vf_is_rec7   = vf_is_unary && (vs1_q == 5'b00101);
    wire        vf_is_est    = vf_is_rsqrt7 || vf_is_rec7;
    wire        vf_is_eq   = (f6_q == 6'b011000);
    wire        vf_is_le   = (f6_q == 6'b011001);
    wire        vf_is_lt   = (f6_q == 6'b011011);
    wire        vf_is_ne   = (f6_q == 6'b011100);
    wire        vf_is_gt   = vf_is_vf && (f6_q == 6'b011101);
    wire        vf_is_ge   = vf_is_vf && (f6_q == 6'b011111);
    wire        vf_is_cmp  = vf_is_eq || vf_is_le || vf_is_lt || vf_is_ne || vf_is_gt || vf_is_ge;
    wire        vf_is_fma  = (f6_q[5:3] == 3'b101);
    wire        vf_is_merge= (f6_q == 6'b010111);           //  vfmerge.vfm / vfmv.v.f
    wire        vf_is_vmvsf= vf_is_vf && (f6_q == 6'b010000);   //  vfmv.s.f
    wire        vf_is_vmvfs= !vf_is_vf && (f6_q == 6'b010000);  //  vfmv.f.s
    wire        vf_is_fred = !vf_is_vf && ((f6_q==6'b000001)||(f6_q==6'b000011)||(f6_q==6'b000101)||(f6_q==6'b000111));
    wire        vf_red_max = f6_q[2] &&  f6_q[1];
    wire        vf_red_min = f6_q[2] && !f6_q[1];
    wire        vf_is_fsl1up = vf_is_vf && (f6_q == 6'b001110);
    wire        vf_is_fsl1dn = vf_is_vf && (f6_q == 6'b001111);
    wire        vf_is_cvt  = !vf_is_vf && (f6_q == 6'b010010);  //  VFUNARY0
    wire        vf_is_wcvt = vf_is_cvt && (vs1_q[4:3] == 2'b01);
    wire        vf_is_ncvt = vf_is_cvt && (vs1_q[4:3] == 2'b10);
    wire        vf_cvt_ff  = vf_is_cvt && (vs1_q[2:1] == 2'b10);
    //  Zvfhmin (the only FP16 ops): vfwcvt.f.f.v at SEW=16 (FP16->FP32) and
    //  vfncvt.f.f.w at SEW=16 (FP32->FP16). karu64 traps every OTHER e16/e8
    //  FP op, so reaching here at vsew==1 with f.f means Zvfhmin.
    //  widen f.f only (01100); vfwcvt.rod.f.f.v (01101) doesn't exist -> not
    //  Zvfhmin -> karu64 traps it as reserved (exact-predicate match there).
    wire        vf_zfh_w  = vf_is_wcvt && vf_cvt_ff && !vf_cvt_rod && (vsew_q == 3'd1); //  widen
    //  narrow f.f only (10100); the e16 vfncvt.rod.f.f.w (10101) is Zvfh, not
    //  Zvfhmin -> trapped at issue. (Base-V e64->e32 vfncvt.rod.f.f.w is still
    //  implemented and unaffected -- this is e16-specific.) The converter's
    //  ROD path stays (fcvt-hs validated) but is unreachable at e16.
    wire        vf_zfh_n  = vf_is_ncvt && vf_cvt_ff && !vf_cvt_rod && (vsew_q == 3'd1); //  narrow
    wire        vf_zfh    = vf_zfh_w || vf_zfh_n;
    wire        vf_cvt_rod = vf_is_cvt && (vs1_q[2:0] == 3'b101);
    wire        vf_cvt_i2f = vf_is_cvt && !vf_cvt_ff &&  vs1_q[1] && !vs1_q[2];
    wire        vf_cvt_f2i = vf_is_cvt && !vf_cvt_ff && (!vs1_q[1] || vs1_q[2]);
    wire        vf_cvt_uns = !vs1_q[0];
    wire        vf_cvt_rtz = vf_is_cvt && !vf_cvt_ff && vs1_q[2];
    wire        vf_is_wadd = (f6_q == 6'b110000) || (f6_q == 6'b110100);
    wire        vf_is_wsub = (f6_q == 6'b110010) || (f6_q == 6'b110110);
    wire        vf_is_w_w  = (f6_q == 6'b110100) || (f6_q == 6'b110110);
    wire        vf_is_wmul = (f6_q == 6'b111000);
    wire        vf_is_wfma = (f6_q[5:2] == 4'b1111);
    wire        vf_is_warith = vf_is_wadd || vf_is_wsub || vf_is_wmul || vf_is_wfma;
    wire        vf_is_wredu  = (f6_q == 6'b110001);
    wire        vf_is_wredo  = (f6_q == 6'b110011);
    wire        vf_is_wred   = vf_is_wredu || vf_is_wredo;
    //  Zvfhmin retargets widths: widen dest=FP32/src=FP16, narrow dest=FP16/
    //  src=FP32 (the FP32<->FP64 cvt assumptions don't apply at e16).
    wire        vf_dest64  = vf_zfh ? 1'b0 : ((vf_is_wcvt || vf_is_warith) ? 1'b1 : (vf_is_ncvt ? 1'b0 : vf_is_d));
    wire        vf_src64   = vf_zfh ? 1'b0 : (vf_is_ncvt ? 1'b1 : (vf_is_wcvt ? 1'b0 : vf_is_d));
    //  dest/src element width as log2(bytes): adds the e16 case (=1) for
    //  Zvfhmin; otherwise == the old (vf_dest64 ? 3 : 2) / (vf_src64 ? 3 : 2).
    wire [2:0]  vf_dlg     = vf_zfh_n ? 3'd1 : (vf_dest64 ? 3'd3 : 3'd2);
    wire [2:0]  vf_slg     = vf_zfh_w ? 3'd1 : (vf_src64  ? 3'd3 : 3'd2);
    wire        vf_cvt_long = vf_cvt_f2i ? vf_dest64 : vf_src64;
    wire        vf_cvt_isd  = vf_cvt_f2i ? vf_src64 : (vf_cvt_i2f ? vf_dest64 : vf_is_ncvt);
    wire        vf_use_fpu  = !vf_is_merge && !vf_is_vmvsf && !vf_is_fsl1up && !vf_is_fsl1dn && !vf_is_vmvfs && !vf_is_est && !vf_zfh;

    //  ================================================================
    //  Read-use classification (the adapter contract; doc/architecture.md
    //  ). EVERY op is a granule consumer: per-operand need flags +
    //  granule indices below. The old whole-register rdu_vold contract
    //  died with the rd1/rd2/rd3 latches.
    //  rdu_vs1 / rdu_vs2 are the LANE-GROUP (grp_gran) operand-need codes
    //  (consumed only by the grp_gran arm of rdu_vs*_g below): 00 = operand
    //  not read, 01 = the current granule suffices, 10 = whole register
    //  (unreachable for grp_gran -- the serial m_*/d_* paths that would
    //  need a different granule are NOT grp_gran; they are ser_gran with
    //  their own indices). NONE refinements: scalar/imm b-operand
    //  (.vx/.vi), vid (no sources), vmv.s.x (vs2 is a selector), and
    //  vmv.v.* (vm=1: the vs2 arm is never selected). The granule feed
    //  preserves the source-snapshot-before-dest-writes overlap rule by
    //  construction: passes walk granules forward, so a granule read at
    //  (reg, g) always precedes any write to it (see the adapter).
    //  cz_q routes Zvk (OP-VE) / vkeccak off the grp_gran path -- their
    //  funct fields ALIAS the OP-V integer decodes (e.g. vaes* f3=010
    //  f6=101xx1 pattern-matches is_mac). They are NOT whole-register
    //  consumers: czv_gran/czk_gran feed them granules too (EGW groups /
    //  keccak state collected one granule per cycle). cz_q just keeps the
    //  dispatch priority (is_vcrypto/is_keccak over the f6 classes)
    //  mirrored here. (The first granule-feed run, before this split, had
    //  the zvk/keccak KATs fail loudly -- the classification tripwire's
    //  predecessor.)
    localparam [1:0] RDU_NONE = 2'b00, RDU_GRAN = 2'b01, RDU_WHOLE = 2'b10;
    wire grp_gran = !cz_q && is_grp && !((BS_MUL && (is_mul || is_mac || is_vsmul)) || (BS_DIV && is_div));
    wire [1:0] rdu_vs1 = cz_q ? RDU_WHOLE
                       : ((is_grp && (b_vx || b_vi)) || is_vid) ? RDU_NONE
                       : grp_gran                               ? RDU_GRAN : RDU_WHOLE;
    wire [1:0] rdu_vs2 = cz_q ? RDU_WHOLE
                       : (is_vmvsx || is_vid || (is_mvmerge && vm_q)) ? RDU_NONE
                       : grp_gran ? RDU_GRAN : RDU_WHOLE;
    reg  cz_q;      //  latched at accept: op is Zvk/vkeccak (issue-cycle inputs)
    reg  czv_q, czk_q;  //  split: vcrypto / vkeccak (granule-feed classes)
    //  GRAN classes (every op belongs to exactly one; the per-class arms
    //  below pick the need flags and granule indices). Beyond the lane
    //  loop:
    //    fp_gran  FP PARALLEL element ops + vf compares -- ch1/ch2/chv
    //             are granule-windowed at (gwin+PL)*64; compares merge
    //             vold_g at the S_FPWR write (fmbuf holds raw bits).
    //    fseq_gran  FP SEQUENTIAL family (fe-indexed: warith/wcvt/ncvt/
    //             reductions/slides) -- each element read re-pointed to its
    //             granule (vf_e_sh/vf_src_sh/vf_w_sh/...).
    //    mv_gran  vmv<nr>r -- granule-streamed copy (vs2_g -> g_* port).
    //    pl_gran  perm S_PLOAD snapshot (BOTH buffer flavors) -- one
    //             granule per word; source needs are gated to ld_active,
    //             so the post-load r-walk triggers NO fills.
    //    red/ser/wser/wpar/nar/ext/cmp/msk_gran  the remaining classes
    //             (reductions, serial+parallel mul/div+widening, narrowing,
    //             extend, compares, mask family) -- see their arms below.
    //  Every class excludes cz_q (Zvk/vkeccak funct aliasing -- see above).
    //  vf_is_cvt = ALL of VFUNARY0 (vs1 is a selector, never data) -- the
    //  parallel subset here is i2f/f2i/single-width f2f; wcvt/ncvt are
    //  already excluded by vf_seqop.
    wire vf_unary = vf_is_sqrt || vf_is_class || vf_is_est || vf_is_cvt;
    wire fp_gran  = is_fp_q && !vf_seqop && !cz_q;
    //  FP SEQUENTIAL family: fe-indexed element reads, now granule-sourced.
    //  Needs are op-scoped (the write phases change no indices, so they
    //  trigger no fills).
    wire fseq_gran = is_fp_q && vf_seqop && !cz_q;
    //  FP source needs are STATE-gated to the consuming phase (S_FPAR /
    //  S_FPWAIT; assigned near the FSM): fp_gran itself stays op-scoped so
    //  the adapter keeps gneed-mode through S_FPWR, but with every need
    //  low the writeback granule walk (gpass reused as the write counter)
    //  triggers no source refills.
    wire fp_src_ph;
    wire cmp_src_ph, cmp_wr_ph; //  S_RUN / S_CMW (assigned near the FSM)
    wire cmp_gran = (is_cmp || is_carry_m) && !is_fp_q && !cz_q;
    wire red_gran = is_reduce && !is_fp_q && !cz_q;
    wire red_ph   = (state == S_RED_A) || (state == S_RED_B);   //  assigned states
    //  serial mul/div + serial widening-mul classes (compile-active only
    //  under the BS_* configs; the parallel forms ride grp_gran/wide paths)
    wire ser_gran  = ((BS_MUL && (is_mul || is_mac || is_vsmul))
                   || (BS_DIV && is_div)) && !is_fp_q && !cz_q;
    wire wser_gran = (BS_MUL && is_wide && (wide_mul || wide_mac)) && !is_fp_q && !cz_q;
    wire wpar_gran = is_wide && !(BS_MUL && (wide_mul || wide_mac)) && !is_fp_q && !cz_q;
    wire nar_gran  = is_narrow && !is_fp_q && !cz_q;
    wire ext_gran  = is_vext && !cz_q;
    wire wpar_ph   = (state == S_WRUN);
    wire nar_ph    = (state == S_NA);
    wire fpw_ph;    //  S_FPWR (assigned near the FSM)
    wire msk_gran = (is_mlg || is_mscan || is_vfirst || is_vcpop || is_vmvxs)
                 && !is_fp_q && !cz_q;
    wire mv_gran  = is_vmvnr && !is_fp_q && !cz_q;
    wire pl_gran  = is_perm && !is_fp_q && !cz_q;   //  both perm-buffer flavors
`ifdef KARU_EN_ZVK
    wire czv_gran = czv_q;
`else
    wire czv_gran = 1'b0;
`endif
`ifdef KARU_EN_KECCAK
    wire czk_gran = czk_q;
    wire czk_ld_ph;     //  S_KLOAD (assigned near the FSM)
`else
    wire czk_gran = 1'b0;
`endif
    assign rdu_gran  = (grp_gran || fp_gran || mv_gran || pl_gran || cmp_gran || msk_gran
                     || red_gran || ser_gran || wser_gran
                     || wpar_gran || nar_gran || ext_gran || fseq_gran
                     || czv_gran || czk_gran);
    assign rdu_vs1_g = (grp_gran && (rdu_vs1 == RDU_GRAN))
                    || (fp_gran && fp_src_ph && !vf_is_vf && !vf_unary)
                    || (cmp_gran && cmp_src_ph && b_vv)
                    || (msk_gran && is_mlg && cmp_src_ph)
                    || (red_gran && red_ph)
                    || ((ser_gran || wser_gran) && b_vv)
                    || (wpar_gran && wpar_ph && b_vv)
                    || (nar_gran && nar_ph && b_vv)
                    || (fseq_gran && ((vf_is_warith && !vf_is_vf) || vf_is_fred || vf_is_wred))
                    || czv_gran
                    || (pl_gran && ld_active);
    assign rdu_vs2_g = (grp_gran && (rdu_vs2 == RDU_GRAN))
                    || (fp_gran && fp_src_ph && !(vf_is_merge && vm_q))
                    || ((cmp_gran || msk_gran) && cmp_src_ph)
                    || mv_gran
                    || (red_gran && red_ph)
                    || ser_gran || wser_gran
                    || (wpar_gran && wpar_ph)
                    || (nar_gran && nar_ph)
                    || (ext_gran && cmp_src_ph)
                    || (fseq_gran && !vf_is_vmvsf)
                    || czv_gran
                    || (pl_gran && ld_active);
    assign rdu_vold_g = (grp_gran && is_mac)
                     || (fp_gran && vf_is_fma && fp_src_ph)
                     || ((cmp_gran || (msk_gran && (is_mlg || is_mscan))) && cmp_wr_ph)
                     || (ser_gran && is_mac)
                     || (wser_gran && wide_mac)
                     || (wpar_gran && wide_mac && wpar_ph)
                     || (fseq_gran && vf_is_wfma)
                     || (fp_gran && vf_is_cmp && fpw_ph)
                     || czv_gran
`ifdef KARU_EN_KECCAK
                     || (czk_gran && czk_ld_ph)
`endif
                     ;
`ifdef KARU_V_PERM_RAM
    wire rdu_gdef = (pl_gran && ld_active) ? plw[WPW-1] : gpass[0];
`else
    wire rdu_gdef = (pl_gran && ld_active) ? plg : gpass[0];
`endif
    assign rdu_g1 =
`ifdef KARU_EN_ZVK
                    czv_gran  ? czv_idx :
`endif
                    red_gran  ? 1'b0            //  vs1[0] seed: granule 0
                  : ser_gran  ? (is_div ? dsh[7] : msh[7])
                  : (wser_gran || wpar_gran) ? r[0] //  narrow window = granule r[0]
                  : nar_gran  ? nph             //  narrow shamt window = granule nph
                  : fseq_gran ? (vf_is_warith ? vf_wa_off[7] : 1'b0)
                  : rdu_gdef;
    assign rdu_g2 =
`ifdef KARU_EN_ZVK
                    czv_gran  ? czv_idx :
`endif
                    red_gran  ? rch[1]          //  64-bit chunk rch -> granule rch[1]
                  : ser_gran  ? (is_div ? dsh[7] : msh[7])
                  : wser_gran ? r[0]
                  : wpar_gran ? (wide_w ? gpass[0] : r[0])
                  : nar_gran  ? n_g2
                  : ext_gran  ? x_g2
                  : fseq_gran ? (vf_is_cvt ? vf_src_sh[7]
                               : (vf_is_fsl1up || vf_is_fsl1dn) ? vf_sl_sh[7]
                               : vf_is_w_w ? vf_w_sh[7]
                               : (vf_is_warith && !vf_is_vf) ? vf_wb_off[7]
                               : vf_is_warith ? vf_wb_off[7]
                               : vf_e_sh[7])
                  : rdu_gdef;
    assign rdu_gv =
`ifdef KARU_EN_ZVK
                    czv_gran  ? czv_idx :
`endif
`ifdef KARU_EN_KECCAK
                    czk_gran  ? kg :
`endif
                    ser_gran  ? msh[7]
                  : wser_gran ? wm_vsh[7]
                  : fseq_gran ? vf_w_sh[7]      //  wfma addend (wide element fe)
                  : gpass[0];

    //  ---- parallel vs sequential dispatch ----
    //  Element-wise same-width ops fan out across all NLANES lane FPUs (one
    //  chunk-element/lane/slot). Geometry-changing / cross-lane ops (widen,
    //  narrow, reductions, slides, vfmv.s.f/.f.s) keep the sequential lane-0
    //  path (S_FRUN / S_FRSEED). vf_seq routes the lane-bus operands to lane 0.
    wire        vf_seqop = vf_is_warith || vf_is_wcvt || vf_is_ncvt
                       || vf_is_fred || vf_is_wred
                       || vf_is_fsl1up || vf_is_fsl1dn || vf_is_vmvsf || vf_is_vmvfs;
    wire        vf_seq   = is_fp_q && vf_seqop;
    wire [3:0]  vf_epc   = epc_w;                   //  FP elements per 64-bit chunk (2 e32, 1 e64)

    //  ---- karu_fpu sub selection ----
    reg [4:0] vf_fop;
    always @(*) begin
        if      (vf_is_add)   vf_fop = `FOP_ADD;
        else if (vf_is_sub || vf_is_rsub) vf_fop = `FOP_SUB;
        else if (vf_is_mul)   vf_fop = `FOP_MUL;
        else if (vf_is_div || vf_is_rdiv) vf_fop = `FOP_DIV;
        else if (vf_is_sqrt)  vf_fop = `FOP_SQRT;
        else if (vf_is_min)   vf_fop = `FOP_MIN;
        else if (vf_is_max)   vf_fop = `FOP_MAX;
        else if (vf_is_sgnj)  vf_fop = `FOP_SGNJ;
        else if (vf_is_sgnjn) vf_fop = `FOP_SGNJN;
        else if (vf_is_sgnjx) vf_fop = `FOP_SGNJX;
        else if (vf_is_class) vf_fop = `FOP_CLASS;
        else if (vf_is_eq || vf_is_ne) vf_fop = `FOP_EQ;
        else if (vf_is_lt || vf_is_gt) vf_fop = `FOP_LT;
        else if (vf_is_le || vf_is_ge) vf_fop = `FOP_LE;
        else if (vf_cvt_ff)  vf_fop = vf_is_wcvt ? `FOP_CVT_D_S : `FOP_CVT_S_D;
        else if (vf_cvt_f2i) vf_fop = vf_cvt_long ? (vf_cvt_uns ? `FOP_CVT_LU_S : `FOP_CVT_L_S)
                                                 : (vf_cvt_uns ? `FOP_CVT_WU_S : `FOP_CVT_W_S);
        else if (vf_cvt_i2f) vf_fop = vf_cvt_long ? (vf_cvt_uns ? `FOP_CVT_S_LU : `FOP_CVT_S_L)
                                                 : (vf_cvt_uns ? `FOP_CVT_S_WU : `FOP_CVT_S_W);
        else if (vf_is_fred) vf_fop = vf_red_max ? `FOP_MAX : (vf_red_min ? `FOP_MIN : `FOP_ADD);
        else if (vf_is_wred) vf_fop = `FOP_ADD;
        else if (vf_is_wadd) vf_fop = `FOP_ADD;
        else if (vf_is_wsub) vf_fop = `FOP_SUB;
        else if (vf_is_wmul) vf_fop = `FOP_MUL;
        else if (vf_is_wfma) begin
            case (f6_q[1:0])
                2'b00: vf_fop = `FOP_MADD;
                2'b01: vf_fop = `FOP_NMADD;
                2'b10: vf_fop = `FOP_MSUB;
                default: vf_fop = `FOP_NMSUB;
            endcase
        end
        else if (vf_is_fma) begin
            case (f6_q[1:0])
                2'b00: vf_fop = `FOP_MADD;
                2'b01: vf_fop = `FOP_NMADD;
                2'b10: vf_fop = `FOP_MSUB;
                default: vf_fop = `FOP_NMSUB;
            endcase
        end else vf_fop = `FOP_ADD;
    end

    //  ---- element geometry (dual-width for widen/narrow) ----
    wire [31:0] vf_eprd   = (vf_is_wcvt || vf_is_warith) ? (epr >> 1) : epr;
    wire [31:0] vf_eprs   = vf_is_ncvt ? (epr >> 1) : epr;
    //  vf_eprd/vf_eprs are epr or epr/2 -> powers of 2; use shift/mask geometry.
    wire [5:0]  vf_eprd_lg = (vf_is_wcvt || vf_is_warith) ? eprw_lg : epr_lg;
    wire [5:0]  vf_eprs_lg = vf_is_ncvt ? eprw_lg : epr_lg;
    wire [3:0]  vf_nregd  = (vf_is_wcvt || vf_is_warith) ? (nreg_q << 1) : nreg_q;
    wire [31:0] vf_ebase  = {28'b0, r} << vf_eprd_lg;   //  r*vf_eprd (shift)
    wire [31:0] vf_geg    = vf_ebase + fe;
    wire [4:0]  vf_srcreg = vs2_q + (vf_geg >> vf_eprs_lg);             //  /vf_eprs (shift)
    wire [31:0] vf_src_el = vf_geg & ((32'd1 << vf_eprs_lg) - 32'd1);   //  %vf_eprs (mask)
    wire [7:0]  vf_seew_b = 8'd8 << vf_slg;         //  src element bytes*8 (e16/e32/e64)
    wire [5:0]  vf_seew_lg = {3'b0, vf_slg} + 6'd3; //  log2(vf_seew_b)

    //  ---- 6a: ACTIVE-byte enables for the hot granule writes ----
    //  (doc/architecture.md) Byte i of the current pass's granule maps to
    //  group-global DEST element e; the byte is enabled iff e is in-vl AND
    //  this op writes it: active (vm/v0), or ANY in-vl element for the
    //  merge/carry classes (vmerge writes vs2 INTO inactive elements;
    //  vadc/vsbc consume v0 as carry, not as a mask). Over-enabling is safe
    //  while the data stays pre-merged (6a keeps the merge); under-enabling
    //  a written element is the only hazard. Tail bytes (e >= vl) are NEVER
    //  enabled -- the VRF6 invariant. vstart is guaranteed 0 here (arith
    //  with nonzero vstart traps at issue).
    reg  [`KARU_VBUS_B-1:0] gwbe_grp_w, gwbe_fp_w;
    integer wbi;
    reg [31:0] wbe_e, wbe_f;
    always @(*) begin
        gwbe_grp_w = {`KARU_VBUS_B{1'b0}};
        gwbe_fp_w  = {`KARU_VBUS_B{1'b0}};
        for (wbi = 0; wbi < `KARU_VBUS_B; wbi = wbi + 1) begin
            //  integer S_GWB path: dest EEW = SEW
            wbe_e = ebase + (((gpass * `KARU_VBUS_B) + wbi[31:0]) >> vsew_q);
            gwbe_grp_w[wbi] = (wbe_e < vl_q) &&
                (is_vmvsx ? (wbe_e == 32'd0)    //  vmv.s.x: element 0 only
                          : (vm_q || v0_q[wbe_e[7:0]] || is_mvmerge || is_carry_e));
            //  FP S_FPWR path: dest EEW = e64 (D / widened) or e32 (F)
            wbe_f = vf_ebase + (((gpass * `KARU_VBUS_B) + wbi[31:0])
                                >> (vf_dest64 ? 3 : 2));
            gwbe_fp_w[wbi] = (wbe_f < vl_q) &&
                (vm_q || v0_q[wbe_f[7:0]] || vf_is_merge);
        end
    end

    //  ---- 6c: whole-register byte enables for the COLD (S_CWB) writes ----
    //  Each S_CWB client loads cwb_be (+ the VRF6 qualifiers) alongside
    //  cwb_buf; the funnel slices one granule of enables per write. Same
    //  exact-write-set discipline as the hot paths. The pre-merge is GONE
    //  and these enables are the ONLY keep-old -- exactness is mandatory,
    //  not an optimization (the slideup elo bound and the vfmv.s.f
    //  element-0 case exist for this).
    //  act_be: in [elo, vl) AND active at the dest element width; lo_be:
    //  the low n bytes (reductions/vcompress).
    function [`KARU_VLENB-1:0] act_be;
        input [31:0] eb0;   //  group-global element index of byte 0
        input [2:0]  dlg;   //  log2(dest element bytes) (0=e8..3=e64)
        input [31:0] elo;   //  first WRITABLE element (vslideup: the offset;
                            //  everything else: 0). Mandatory under 6c-b --
                            //  with the pre-merge seeds gone, an over-enabled
                            //  below-offset byte would write garbage.
        integer ab; reg [31:0] ae;
        begin
            for (ab = 0; ab < `KARU_VLENB; ab = ab + 1) begin
                ae = eb0 + (ab[31:0] >> dlg);
                act_be[ab] = (ae >= elo) && (ae < vl_q) && (vm_q || v0_q[ae[7:0]]);
            end
        end
    endfunction
    function [`KARU_VLENB-1:0] lo_be;
        input [31:0] nb;
        integer ab;
        for (ab = 0; ab < `KARU_VLENB; ab = ab + 1)
            lo_be[ab] = (ab[31:0] < nb);
    endfunction
    //  vcompress: dest register r holds packed elements [ebase, ebase+epr);
    //  written = the part of cmp_count that falls in this register.
    wire [31:0] cmpn_rem = (cmp_count > ebase) ? (cmp_count - ebase) : 32'd0;
    wire [31:0] cmpn_n   = (cmpn_rem > epr) ? epr : cmpn_rem;
    reg  [`KARU_VLENB-1:0] cwb_be;
    reg         cwb_vlgov, cwb_mdest;
    reg  [2:0]  cwb_vsew;
    reg  [15:0] cwb_epr;

    //  ---- per-element operand select (granule-sourced) ----
    //  element fe's bit offset / granule at the op's element width
    wire [5:0]  vf_e_lg  = vf_is_d ? 6'd6 : 6'd5;
    wire [31:0] vf_e_sh  = fe << vf_e_lg;
    wire [63:0] vf_e1raw = vs1_g  >> vf_e_sh[6:0];
    wire [63:0] vf_e2raw = vs2_g  >> vf_e_sh[6:0];
    wire [63:0] vf_evraw = vold_g >> vf_e_sh[6:0];
    wire [63:0] vf_e_vs1  = vf_is_d ? vf_e1raw : {32'hFFFF_FFFF, vf_e1raw[31:0]};
    wire [63:0] vf_e_vs2  = vf_is_d ? vf_e2raw : {32'hFFFF_FFFF, vf_e2raw[31:0]};
    wire [63:0] vf_e_vold = vf_is_d ? vf_evraw : {32'hFFFF_FFFF, vf_evraw[31:0]};
    wire [63:0] vf_sval   = frs1_q;
    wire [63:0] vf_e_b    = vf_is_vf ? vf_sval : vf_e_vs1;
    wire [31:0] vf_src_sh = vf_src_el << vf_seew_lg;    //  cvt source bit offset
    wire [63:0] vf_src_raw = vs2_g >> vf_src_sh[6:0];   //  granule vf_src_sh[7]
    wire [63:0] vf_cvt_opf = vf_src64 ? vf_src_raw : {32'hFFFF_FFFF, vf_src_raw[31:0]};
    //  Zvfhmin converters (combinational; validated vs SoftFloat-3e by
    //  test/fcvt_hs, 3.95M vectors x6RM incl ROD, 0-error). Widen is exact; narrow
    //  rounds per the effective rm (rod/rtz variants via lane_fp_rm).
    wire [31:0] vf_hs_res;  wire [4:0] vf_hs_fl;
    karu_fcvt_hs u_vhs (.a(vf_src_raw[15:0]), .res(vf_hs_res), .flags(vf_hs_fl));
    wire [15:0] vf_sh_res;  wire [4:0] vf_sh_fl;
    karu_fcvt_sh u_vsh (.rm(lane_fp_rm), .a(vf_src_raw[31:0]), .res(vf_sh_res), .flags(vf_sh_fl));
    wire [63:0] vf_zfh_res = vf_zfh_w ? {32'b0, vf_hs_res} : {48'b0, vf_sh_res};
    wire [4:0]  vf_zfh_fl  = vf_zfh_w ? vf_hs_fl : vf_sh_fl;
    wire [63:0] vf_cvt_opi = vf_src64 ? vf_src_raw : {32'b0,        vf_src_raw[31:0]};

    //  ---- widening-arith operands: widen narrow F element -> exact D ----
    localparam integer EPR32 = VLEN/32;
    localparam integer EPR32_LG = LOG2VLEN - 5;                 //  log2(EPR32 = VLEN/32)
    wire [31:0] vf_w_eidx = vf_is_wred ? (({28'b0, r} << EPR32_LG) + fe) : vf_geg;  //  r*EPR32 (shift)
    wire [4:0]  vf_wa_reg = vs1_q + (vf_w_eidx >> EPR32_LG);        //  /EPR32 (shift)
    wire [4:0]  vf_wb_reg = vs2_q + (vf_w_eidx >> EPR32_LG);
    wire [31:0] vf_wa_off = (vf_w_eidx & (EPR32-1)) << 5;       //  %EPR32 (mask)
    wire [31:0] vf_wb_off = (vf_w_eidx & (EPR32-1)) << 5;
    wire [31:0] vf_wa_raw = vf_is_vf ? frs1_q[31:0] : (vs1_g >> vf_wa_off[6:0]);    //  granule vf_wa_off[7]
    wire [31:0] vf_wb_raw = vs2_g >> vf_wb_off[6:0];                                //  granule vf_wb_off[7]
    wire [63:0] vf_wa_d, vf_wb_d;
    wire [4:0]  vf_wa_f, vf_wb_f;
    karu_fcvt_ds u_widen_a (.a(vf_wa_raw), .res(vf_wa_d), .flags(vf_wa_f));
    karu_fcvt_ds u_widen_b (.a(vf_wb_raw), .res(vf_wb_d), .flags(vf_wb_f));
    wire [31:0] vf_w_sh       = fe << 6;                //  wide (64-bit) element offset
    wire [63:0] vf_wide_vs2_w = vs2_g  >> vf_w_sh[6:0]; //  granule vf_w_sh[7]
    wire [63:0] vf_vold_d     = vold_g >> vf_w_sh[6:0];
    wire [4:0]  vf_widen_nv   = vf_wa_f | (vf_is_w_w ? 5'b0 : vf_wb_f);

    //  ---- operands (op1/op2/op3) ----
    reg [63:0] fop1, fop2, fop3;
    always @(*) begin
        fop1 = vf_e_vs2; fop2 = vf_e_b; fop3 = 64'b0;
        if (vf_is_fred || vf_is_wred) begin fop1 = fracc; fop2 = vf_is_wred ? vf_wb_d : vf_e_vs2; end
        else if (vf_is_warith) begin
            if (vf_is_wfma) begin fop1 = vf_wa_d; fop2 = vf_wb_d; fop3 = vf_vold_d; end
            else begin
                fop1 = vf_is_w_w ? vf_wide_vs2_w : vf_wb_d;
                fop2 = vf_wa_d;
            end
        end
        else if (vf_is_rsub || vf_is_rdiv) begin fop1 = vf_sval; fop2 = vf_e_vs2; end
        else if (vf_is_gt || vf_is_ge)     begin fop1 = vf_sval; fop2 = vf_e_vs2; end
        else if (vf_is_sqrt || vf_is_class) fop1 = vf_e_vs2;
        else if (vf_cvt_i2f)            fop1 = vf_cvt_opi;
        else if (vf_cvt_f2i || vf_cvt_ff)  fop1 = vf_cvt_opf;
        else if (vf_is_fma) begin
            fop1 = vf_e_b;
            if (f6_q[2]) begin fop2 = vf_e_vs2;  fop3 = vf_e_vold; end
            else         begin fop2 = vf_e_vold; fop3 = vf_e_vs2;  end
        end
    end

    //  ---- per-lane parallel FP operands (element-wise ops) ----
    //  For the parallel path each lane L processes element
    //  geg = r*epr + L*epc_w + fs out of its own 64-bit chunk.
    wire [NLANES*64-1:0] vf_p_op1, vf_p_op2, vf_p_op3, vf_p_relem;
    wire [NLANES*32-1:0] vf_p_geg;
    wire [NLANES-1:0]    vf_p_fire, vf_p_wr, vf_p_cmpbit;
    genvar PL;
    generate for (PL = 0; PL < NLANES; PL = PL + 1) begin : g_fpop
        wire [31:0] geg = ({28'b0, r} << epr_lg) + ((gwin + PL[31:0]) << epc_lg) + {28'b0, fs}; //  r*epr + (granule-windowed PL)*epc_w; shifts
        //  granule-windowed chunk: lane PL in pass gpass owns global chunk gwin+PL
        //  (== PL when VGRAN_C==1, byte-identical). Must match geg/act/fdbuf window.
        //  stage-4: FP-parallel GRAN ops take the adapter's granule latches
        wire [63:0] ch2 = vs2_g [PL*64 +: 64];
        wire [63:0] ch1 = vs1_g [PL*64 +: 64];
        wire [63:0] chv = vold_g[PL*64 +: 64];
        wire [63:0] e2  = vf_is_d ? ch2 : {32'hFFFF_FFFF, ch2[fs*32 +: 32]};
        wire [63:0] e1  = vf_is_d ? ch1 : {32'hFFFF_FFFF, ch1[fs*32 +: 32]};
        wire [63:0] ev  = vf_is_d ? chv : {32'hFFFF_FFFF, chv[fs*32 +: 32]};
        wire [63:0] eb  = vf_is_vf ? frs1_q : e1;
        wire [63:0] ci  = vf_is_d ? ch2 : {32'b0, ch2[fs*32 +: 32]};    //  i2f int source (raw)
        reg  [63:0] o1, o2, o3;
        always @(*) begin
            o1 = e2; o2 = eb; o3 = 64'b0;
            if      (vf_is_rsub || vf_is_rdiv) begin o1 = frs1_q; o2 = e2; end
            else if (vf_is_gt   || vf_is_ge)   begin o1 = frs1_q; o2 = e2; end
            else if (vf_is_sqrt || vf_is_class) o1 = e2;
            else if (vf_cvt_i2f)                o1 = ci;
            else if (vf_cvt_f2i)                o1 = e2;        //  float source (NaN-boxed)
            else if (vf_is_fma) begin
                o1 = eb;
                if (f6_q[2]) begin o2 = e2; o3 = ev; end
                else         begin o2 = ev; o3 = e2; end
            end
        end
        assign vf_p_op1[PL*64 +: 64] = o1;
        assign vf_p_op2[PL*64 +: 64] = o2;
        assign vf_p_op3[PL*64 +: 64] = o3;
        assign vf_p_geg[PL*32 +: 32] = geg;
        wire act  = vm_q || v0_q[geg[7:0]];
        wire invl = geg < vl_q;
        assign vf_p_fire[PL] = vf_use_fpu && act && invl;
        assign vf_p_wr[PL]   = vf_is_merge ? invl : (act && invl);
        wire [63:0] mval = (vm_q || v0_q[geg[7:0]]) ? frs1_q : e2;  //  vfmerge / vfmv.v.f
        assign vf_p_relem[PL*64 +: 64] = vf_is_est ? lane_est_res[PL*64 +: 64] : mval;
        assign vf_p_cmpbit[PL] = vf_is_ne ? ~lane_fp_res[PL*64] : lane_fp_res[PL*64];
    end endgenerate

    //  ---- lane FP bus: vf_seq -> lane 0 (sequential path); else parallel ----
    assign lane_fp_sub    = vf_fop;
    assign lane_fp_is_d   = (vf_is_warith || vf_is_wred) ? 1'b1 : (vf_is_cvt ? vf_cvt_isd : vf_is_d);
    assign lane_fp_rm     = vf_cvt_rod ? `FRM_ROD : (vf_cvt_rtz ? `FRM_RTZ : frm_q);
    assign lane_fp_is_rec = vf_is_rec7;
    genvar BL;
    generate for (BL = 0; BL < NLANES; BL = BL + 1) begin : g_fpbus
        assign lane_fp_op1[BL*64 +: 64] = vf_seq ? ((BL==0) ? fop1 : 64'b0) : vf_p_op1[BL*64 +: 64];
        assign lane_fp_op2[BL*64 +: 64] = vf_seq ? ((BL==0) ? fop2 : 64'b0) : vf_p_op2[BL*64 +: 64];
        assign lane_fp_op3[BL*64 +: 64] = vf_seq ? ((BL==0) ? fop3 : 64'b0) : vf_p_op3[BL*64 +: 64];
        assign lane_fp_req[BL]          = vf_fpu_req && (vf_seq ? (BL==0) : vf_p_fire[BL])
            //  Mask the lane FP req while the operand-fill stall freezes the FSM:
            //  op_stall can hold vf_fpu_req high across the stall, which would
            //  re-fire the req to an already-busy lane (INV19). Gating here lets
            //  it fire exactly once when op_stall drops (vf_fpu_req then
            //  self-clears via the default deassign). See [[vrf-bram-integration-plan]].
            && !op_stall
            ;
    end endgenerate

    //  combined fflags from lanes completing this cycle / non-fpu est lanes
    reg [4:0] vf_p_doneflags, vf_p_estflags; integer fl; integer flp;
    always @(*) begin
        vf_p_doneflags = 5'b0; vf_p_estflags = 5'b0;
        for (fl = 0; fl < NLANES; fl = fl + 1) begin
            if (fp_pend[fl] && lane_fp_done[fl])
                vf_p_doneflags = vf_p_doneflags | lane_fp_flags[fl*5 +: 5];
            if (vf_p_wr[fl])
                vf_p_estflags = vf_p_estflags | lane_est_flags[fl*5 +: 5];
        end
    end

    //  lane 0 FPU / estimate outputs
    wire        vf_fpu_busy  = lane_fp_busy[0];
    wire        vf_fpu_done  = lane_fp_done[0];
    wire [63:0] vf_fpu_res   = lane_fp_res[63:0];
    wire [4:0]  vf_fpu_flags = lane_fp_flags[4:0];
    wire [63:0] vf_est_res   = lane_est_res[63:0];
    wire [4:0]  vf_est_flags = lane_est_flags[4:0];

    //  ---- result -> element / mask bit ----
    wire        vf_cmp_bit   = vf_is_ne ? ~vf_fpu_res[0] : vf_fpu_res[0];
    wire [63:0] vf_merge_val = (vm_q || v0_q[vf_geg[7:0]]) ? vf_sval : vf_e_vs2;
    wire [31:0] vf_sl_src    = vf_is_fsl1up ? (vf_geg==32'd0 ? 32'd0 : vf_geg-32'd1) : (vf_geg+32'd1);
    wire [4:0]  vf_sl_reg    = vs2_q + (vf_sl_src / epr);
    wire [31:0] vf_sl_el     = vf_sl_src % epr;
    wire [31:0] vf_sl_sh     = vf_sl_el << vf_e_lg;     //  slide-source bit offset
    wire [63:0] vf_sl_raw    = vs2_g >> vf_sl_sh[6:0];  //  granule vf_sl_sh[7]
    wire [63:0] vf_slide_e   = vf_is_d ? vf_sl_raw : {32'hFFFF_FFFF, vf_sl_raw[31:0]};
    wire        vf_sl_bound  = vf_is_fsl1up ? (vf_geg==32'd0) : (vf_geg==(vl_q-32'd1));
    wire [63:0] vf_res_elem  = vf_is_vmvsf ? vf_sval :
                               vf_zfh ? vf_zfh_res :
                               vf_is_est ? vf_est_res :
                               (vf_is_fsl1up || vf_is_fsl1dn) ? (vf_sl_bound ? vf_sval : vf_slide_e) :
                               (vf_is_merge ? vf_merge_val : vf_fpu_res);
    wire        vf_active    = vm_q || v0_q[vf_geg[7:0]];
    wire        vf_write_el  = vf_is_vmvsf ? (vf_geg == 32'd0 && vl_q != 0)
                              : vf_is_merge ? (vf_geg < vl_q)
                              : (vf_active && (vf_geg < vl_q));
    wire [31:0] vf_red_g     = ebase + fe;          //  r*epr via ebase (shift)

    //  FP read addresses (muxed into r_vs1/r_vs2/r_vold when is_fp_q)
    wire [4:0] vf_r_vs1  = vf_is_warith ? vf_wa_reg : (vs1_q + {1'b0, r});
    wire [4:0] vf_r_vs2  = vf_is_cvt ? vf_srcreg :
                         (vf_is_fsl1up || vf_is_fsl1dn) ? vf_sl_reg :
                         (vf_is_warith && !vf_is_w_w) ? vf_wb_reg :
                         (vs2_q + {1'b0, r});
    wire [4:0] vf_r_vold = vf_is_cmp ? vd_q : (vd_q + {1'b0, r});

    //  req-time FP detection (input fields; _q not yet valid at S_IDLE)
    wire req_is_fp  = (vfunct3 == 3'b001) || (vfunct3 == 3'b101);
    //  vkeccak (only ever asserted under KARU_EN_KECCAK; 0 otherwise)
    wire req_is_keccak = is_keccak;
    wire req_is_vcrypto = is_vcrypto;
    wire req_fp_red = (vfunct3 == 3'b001) &&
                      ((vfunct6==6'b000001)||(vfunct6==6'b000011)||
                       (vfunct6==6'b000101)||(vfunct6==6'b000111)||
                       (vfunct6==6'b110001)||(vfunct6==6'b110011));
    //  sequential FP ops (lane-0 path): widen arith, widen/narrow cvt, slides,
    //  vfmv.s.f / vfmv.f.s. (Reductions are routed by req_fp_red above.)
    wire req_fp_seq =
           (req_is_fp && (vfunct6[5:4] == 2'b11))                               //  widen arith (11xxxx)
        || ((vfunct3 == 3'b001) && (vfunct6 == 6'b010010)                   //  wcvt/ncvt
            && (vs1_base[4:3] == 2'b01 || vs1_base[4:3] == 2'b10))
        || ((vfunct3 == 3'b101) && (vfunct6 == 6'b001110 || vfunct6 == 6'b001111))  //  slides
        || ((vfunct3 == 3'b101) && (vfunct6 == 6'b010000))                  //  vfmv.s.f
        || ((vfunct3 == 3'b001) && (vfunct6 == 6'b010000));                 //  vfmv.f.s

    //  ========================================================
    //  multi-cycle control
    //  ========================================================
    reg [`KARU_VLEN-1:0] macc;
    //  compare accumulator merge: start from the old mask register (at r=0,
    //  d_vold = v[vd_base]); overwrite only active in-vl bits. Inactive and
    //  tail bits stay undisturbed.
    //  stage-4 streamed mask write: the active set is RECOMPUTED here from
    //  v0_q/vm_q/vl_q (carry-mask writes every in-vl bit) instead of being
    //  accumulated -- S_CMW merges vold_g granule-by-granule against it.
    reg [`KARU_VLEN-1:0] cmp_actall; integer cai;
    always @(*) begin
        cmp_actall = {VLEN{1'b0}};
        for (cai = 0; cai < VLEN; cai = cai + 1)
            if (cai < vl_q && (is_carry_m || is_mlg || vm_q || v0_q[cai]))
                cmp_actall[cai] = 1'b1;
    end
    localparam S_IDLE=6'd0, S_RUN=6'd1, S_DLOAD=6'd2, S_DSTEP=6'd3, S_DFIN=6'd4, S_DWR=6'd5,
               S_MLOAD=6'd6, S_MSTEP=6'd7, S_MFIN=6'd8, S_MWR=6'd9,
               S_WRUN=6'd10, S_NA=6'd11, S_NB=6'd12,
               S_WMLOAD=6'd13, S_WMFIN=6'd14, S_WMWR=6'd15,
               S_RED_A=6'd16, S_REDWR=6'd17, S_PLOAD=6'd18, S_PCOMP=6'd19,
               S_RED_B=6'd33,
               //   FP states: sequential lane-0 path (widen/narrow/slides/vmv/reductions)
               S_FRUN=6'd20, S_FWAIT=6'd21, S_FWR=6'd22, S_FMWR=6'd23,
               S_FRSEED=6'd24, S_FRSTEP=6'd25, S_FRWAIT=6'd26, S_FRWR=6'd27,
               //   FP states: parallel element-wise path (all NLANES lane FPUs)
               S_FPAR=6'd28, S_FPWAIT=6'd29, S_FPWR=6'd30,
               //   vcompress serial pack
               S_CMP_SCAN=6'd31, S_CMP_WR=6'd32,
               //   vkeccak (load group / pulse round FSM / wait / store group)
               S_KLOAD=6'd34, S_KREQ=6'd35, S_KWAIT=6'd36, S_KSTORE=6'd37,
               //   standard Zvk: run one EGW128/256 group through karu_vcrypto
               S_CREQ=6'd39, S_CWAIT=6'd40, S_CWR=6'd41,
               //   KARU_V_WB_STAGE: registered lane-output writeback for the is_grp
               //   granule loop (S_RUN registers grp_res -> S_GWB accumulates+writes).
               S_GWB=6'd42,
               //   KARU_V_FPWB_STAGE: registered FP non-FPU writeback (S_FPAR registers
               //   vf_p_relem -> S_FPWB writes fdbuf), cutting the f6_q->est->fdbuf cone.
               S_FPWB=6'd43,
               //   KARU_V_FPWB_STAGE: registered SEQUENTIAL FP non-FPU writeback
               //   (S_FRUN registers vf_res_elem -> S_FSWB writes fdbuf), cutting the
               //   last combinational lane_est->fdbuf path.
               S_FSWB=6'd44,
               //   KARU_VRF_BRAM: shared COLD whole-register-> granule writeback drain.
               //   A cold site loads cwb_buf/cwb_wd (+cwb_done/cwb_ret) and enters here;
               //   S_CWB emits one VBUS_W granule/cycle (ascending wg), advancing r and
               //   returning to cwb_ret (or done) on the final granule. r is held until
               //   then, so operands are stable and op_stall never freezes mid-write.
               S_CWB=6'd45,
               //   streaming vcompress: mid-scan drain of a filled dest
               //   register (full BE) through S_CWB; if it is the group's LAST
               //   register (count==VLMAX) it is also the op-ending drain.
               S_CMP_FLUSH=6'd46,
               //   streamed mask-dest write (compares + mask family): one granule
               //   of the vd mask register per cycle, merging vold_g against the
               //   write-time-recomputed active set (cmp_actall).
               S_CMW=6'd47,
               //   Zvk: zero-BE wlast pad when the op ends on an inactive group
               S_CPAD=6'd48
`ifdef KARU_V_CWB_STAGE
               //   KARU_V_CWB_STAGE: cold assembly -> drain register hop
               , S_CSTAGE=6'd49
`endif
               ;
    reg [5:0] state;
    assign fp_src_ph = (state == S_FPAR) || (state == S_FPWAIT);
    assign cmp_src_ph = (state == S_RUN);
    assign cmp_wr_ph  = (state == S_CMW);
    assign fpw_ph     = (state == S_FPWR);
`ifdef KARU_EN_KECCAK
    assign czk_ld_ph  = (state == S_KLOAD);
`endif
    reg       wmul_q;   //  serial path is a widening multiply (shares S_MSTEP)
    //  widening iterates 2*LMUL dest registers
    wire [4:0] wide_iter = {nreg_q, 1'b0};
    reg       vsat_q;       //  sticky saturation across the op (output at done)
    assign busy = (state != S_IDLE);
    assign vsat = vsat_q;

    //  Assertion-only debug tap (deep-ref'd by htif_tb -> karu_assert; never a
    //  port, so synthesis prunes it). Const 0 when the 2-stage lane is compiled
    //  out, so the karu_assert wiring + KCHK are unconditional.
    //  dbg_lane_warm_bad : KARU_V_LANE_PIPE handshake monitor. The pipe spends one
    //     extra (held) S_RUN cycle -- lane_warm=1 -- so the lane's stage-1 captures
    //     the operands before stage-2's grp_res is sampled into S_GWB. lane_warm
    //     MUST be high ONLY while the is_grp granule loop runs in S_RUN; if a stale
    //     set ever leaked outside that path (into S_IDLE/S_GWB/a non-grp op), the
    //     next group op would skip its warm cycle and sample stage-2 before stage-1
    //     captured -> wrong result. (r/gpass are held across the warm cycle because
    //     is_grp skips the S_RUN advance, and the toggle forbids two warm cycles in
    //     a row, so "exactly one warm cycle per (r,gpass)" follows from this + that.)
`ifdef KARU_V_LANE_PIPE
    wire dbg_lane_warm_bad = lane_warm && !((state == S_RUN) && is_grp);
`else
    wire dbg_lane_warm_bad = 1'b0;
`endif

`ifdef KARU_EN_KECCAK
    //  ---- vkeccak datapath: ONE isolated Keccak-f1600 permutation ----
    //  The vd e64/m8 group (8 regs) is loaded one reg/cycle into sbuf via this
    //  unit's normal r_vold/d_vold read path; sbuf[1599:0] = the 1600-bit state
    //  (lanes 0..24). The single 24-round FSM runs in place; the group is then
    //  written back through we/wd/wdata (sbuf bits >=1600 = lanes 25..31 are
    //  undisturbed). vs1/vs2/vl are ignored. Requires VLEN>=200 (8*VLEN>=1600).
    localparam integer KVGRP = 8;
    reg  [KVGRP*VLEN-1:0]   ksbuf;
    reg kg;     //  granule sub-step within a register (S_KLOAD)
    reg                     kreq;
    wire                    kbusy, kdone;
    wire [1599:0]           kstate_o;
    keccak i_keccak (
        .clk(clk), .rst(rst), .req(kreq), .rounds_i(5'd24),
        .state_i(ksbuf[1599:0]), .busy(kbusy), .done(kdone), .state_o(kstate_o)
    );
    wire _kunused = &{1'b0, kbusy};
`endif

`ifdef KARU_EN_ZVK
    //  ---- standard Zvk datapath: ONE isolated karu_vcrypto instance ----
    //  This first integration targets the core's VLEN=256 configuration.
    //  EGW128 ops consume/write the low then high 128-bit halves of each vector
    //  register; EGW256 ops consume/write one whole register. Element groups
    //  whose first element is beyond vl are skipped.
    reg         creq;
    reg         chalf;          //  0=low 128, 1=high 128 for EGW128 ops
    reg [4:0]   ccop_q;
    wire        cbusy, cdone;
    wire [255:0] cres;
    wire c_sha2 = (ccop_q == `VCRYPTO_SHA2CH) || (ccop_q == `VCRYPTO_SHA2CL) ||
                  (ccop_q == `VCRYPTO_SHA2MS);
    wire c_egw256 = (ccop_q == `VCRYPTO_SM3C) || (ccop_q == `VCRYPTO_SM3ME) ||
                    (c_sha2 && (vsew_q == 3'd3));
    wire [4:0] caux = c_sha2 ? {4'b0, (vsew_q == 3'd3)} : imm_q[4:0];
    wire [31:0] c_egs128 =
        (vsew_q == 3'd0) ? 32'd16 :
        (vsew_q == 3'd1) ? 32'd8  :
        (vsew_q == 3'd2) ? 32'd4  : 32'd2;
    wire [31:0] c_egs256 =
        (vsew_q == 3'd0) ? 32'd32 :
        (vsew_q == 3'd1) ? 32'd16 :
        (vsew_q == 3'd2) ? 32'd8  : 32'd4;
    wire [31:0] c_egs = c_egw256 ? c_egs256 : c_egs128;
    wire [31:0] c_base_elem = ebase + (chalf ? c_egs : 32'd0);  //  r*epr via ebase (shift)
    wire c_group_active = c_base_elem < vl_q;
    //  EGW128: the granule latches ARE the half-register group (index =
    //  chalf). EGW256: the LOW halves are prefetched into clo_* (the
    //  S_CREQ !cpre_q pass, index 0), the latches then serve the highs.
    reg  [127:0] clo_vd, clo_vs1, clo_vs2;
    reg          cpre_q;
    wire         czv_idx = c_egw256 ? cpre_q : chalf;
    wire [255:0] c_egw_vd  = c_egw256 ? {vold_g, clo_vd } : {128'b0, vold_g};
    wire [255:0] c_egw_vs1 = c_egw256 ? {vs1_g,  clo_vs1} : {128'b0, vs1_g};
    wire [255:0] c_egw_vs2 = c_egw256 ? {vs2_g,  clo_vs2} : {128'b0, vs2_g};
    //  EGW128 writes ONLY its computed granule (S_CWR; no old-half merge);
    //  c_wdata serves the EGW256 whole-register drain.
    wire [`KARU_VLEN-1:0] c_wdata = cres[`KARU_VLEN-1:0];
    karu_vcrypto i_vcrypto (
        .clk(clk), .rst(rst), .req(creq), .cop(ccop_q), .aux(caux),
        .egw_vd(c_egw_vd), .egw_vs1(c_egw_vs1), .egw_vs2(c_egw_vs2),
        .busy(cbusy), .done(cdone), .egw_res(cres)
    );
    wire _cunused = &{1'b0, cbusy};
`endif


    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; done<=0; we<=0; r<=0; gpass<=0;
`ifdef KARU_V_LANE_PIPE
            lane_warm<=0;
`endif
            g_we<=0; g_wlast<=0;
            //  qualifier regs: reset-init only -- they HOLD between writes so an
            //  op_stall edge-captured write replays with its own op's values.
            g_wb_vlgov<=0; g_wb_mdest<=0; g_wb_vsew<=0; g_wb_epr<=0;
            cwb_be<=0; cwb_vlgov<=0; cwb_mdest<=0; cwb_vsew<=0; cwb_epr<=0;
            //  The whole-register write outputs are dead under KARU_VRF_BRAM (all
            //  varith writes go via the granule g_* port). Quarantine them to a
            //  constant 0 here so they are driven (no undriven-net noise; synth
            //  prunes them). karu64 leaves them disconnected from the adapter.
            wd<=5'd0; wdata<={`KARU_VLEN{1'b0}};
            is_fp_q<=0; vf_fpu_req<=0; fflags_set<=0; writes_f<=0; fp_pend<=0;
`ifdef KARU_EN_KECCAK
            kreq<=0;
`endif
`ifdef KARU_EN_ZVK
            creq<=0; chalf<=0; ccop_q<=5'd0;
`endif
        end else
        //  Global operand-fill freeze: while op_stall, hold ALL FSM state (the
        //  default pulse deassigns below also don't run, so `we` holds high for
        //  the adapter to edge-capture; done/creq/kreq are 0 at stall entry).
        if (!op_stall)
        begin
            done<=0; we<=0; vf_fpu_req<=0; fflags_set<=0; writes_f<=0;
            g_we<=0; g_wlast<=0;    //  one-cycle granule write pulse
`ifdef KARU_EN_KECCAK
            kreq<=0;
`endif
`ifdef KARU_EN_ZVK
            creq<=0;
`endif
            case (state)
                S_IDLE: if (req) begin
                    f3_q<=vfunct3; f6_q<=vfunct6; vsew_q<=vsew; vlmul_q<=vlmul; vl_q<=vl;
                    vta_q<=vta; vma_q<=vma; vm_q<=vm; imm_q<=imm; rs1_q<=rs1_v;
                    vxrm_q<=vxrm; vsat_q<=1'b0; cz_q<=is_vcrypto || is_keccak;
                    czv_q<=is_vcrypto; czk_q<=is_keccak;
`ifdef KARU_EN_ZVK
                    cpre_q<=1'b0;
`endif
`ifdef KARU_EN_KECCAK
                    kg<=1'b0;
`endif
`ifndef KARU_V_PERM_RAM
                    plg<=1'b0;
`endif
                    nreg_q<=nreg; vd_q<=vd_base; vs1_q<=vs1_base; vs2_q<=vs2_base;
                    v0_q<=v0; r<=0; macc<={VLEN{1'b0}}; dle<=0; mle<=0; nph<=0; nse<=0; rch<=0;
                    found_q<=1'b0; ff_q<=32'b0; cnt_q<=64'b0;
                    pli<=0; pse<=0; iota_acc<=0; ld_active <= req_is_perm && !req_is_fp;
`ifdef KARU_V_PERM_RAM
                    plw <= {WPW{1'b0}}; plwa <= {PWW{1'b0}};
`endif
                    wmul_q <= (BS_MUL && req_is_wmul);
                    //  FP fields + accumulator (mask seed deferred to run state: vd_q stale here)
                    frm_q<=frm; frs1_q<=frs1_v; is_fp_q<=req_is_fp; fe<=0; fs<=0; gpass<=0;
                    fflags<=5'b0; fp_pend<=0;
`ifdef KARU_EN_ZVK
                    ccop_q<=vcrypto_cop; chalf<=1'b0;
`endif
                    state<= req_is_vcrypto         ? S_CREQ
                          : req_is_keccak          ? S_KLOAD
                          : req_is_fp              ? (req_fp_red ? S_FRSEED
                                                    : req_fp_seq ? S_FRUN : S_FPAR)
                          : req_is_perm            ? S_PLOAD
                          : req_is_reduce          ? S_RED_A
                          : req_is_wide ? ((BS_MUL && req_is_wmul) ? S_WMLOAD : S_WRUN)
                          : req_is_narrow            ? S_NA
                          : (BS_DIV && req_is_div)   ? S_DLOAD
                          : (BS_MUL && req_is_mul)   ? S_MLOAD
                      : S_RUN;
                end
                S_RUN: begin
                    if (is_vmvnr) begin
                        //  stage-4: granule-streamed copy -- vs2_g straight to
                        //  the write port; no whole-register read, no cwb_buf.
                        //  op_stall holds this state until the granule fill
                        //  lands, so vs2_g is granule (vs2_q+r, gpass) here.
                        g_we<=1'b1; g_wd<=vd_q + r; g_wg<=gpass;
                        g_wdata<=vs2_g; g_wbe<={`KARU_VBUS_B{1'b1}};
                        g_wb_vlgov<=1'b0; g_wb_mdest<=1'b0; g_wb_vsew<=vsew_q; g_wb_epr<=epr[15:0];
                        g_wlast<=(r == iter_n - 4'd1) && last_g;
                        if (!last_g) gpass<=gpass+1'b1;
                        else begin
                            gpass<={GPW{1'b0}};
                            if (r == iter_n - 4'd1) begin done<=1; state<=S_IDLE; end
                            else r<=r+4'd1;
                        end
                    end else if (is_grp) begin
                        //  WB_STAGE: register the lane output this cycle; the
                        //  accumulate + grp_full + writeback (the route-bound cone)
                        //  runs next cycle in S_GWB off the registered grp_res_q.
`ifdef KARU_V_LANE_PIPE
                        //  The lane is 2-stage: spend one extra (warm) S_RUN cycle so
                        //  its stage-1 captures the operands (held -- gpass/r don't
                        //  advance for is_grp here) before stage-2's grp_res is sampled.
                        if (!lane_warm) begin
                            lane_warm <= 1'b1;
                        end else begin
                            lane_warm <= 1'b0;
                            grp_res_q <= grp_res;
                            grp_sat_q <= grp_sat;
                            state     <= S_GWB;
                        end
`else
                        grp_res_q <= grp_res;
                        grp_sat_q <= grp_sat;
                        state     <= S_GWB;
`endif
                    end else if (is_vext) begin
                        `CWB_T<=ext_res; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                        cwb_be<=act_be(ebase, vsew_q, 32'd0); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                        if (grp_sat) vsat_q<=1'b1;
                        if (r == iter_n - 1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                        else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_RUN; end
                        state<=`CWB_NX;
                    end else if (is_cmp || is_carry_m) begin
                        macc <= macc | cmp_bits;    //  raw bits; vold merged at S_CMW
                    end
                    else if (is_mlg) macc <= macc | mlg_res;
                    else if (is_mscan || is_vfirst || is_vcpop) begin
                        found_q<=gfound; ff_q<=gff; cnt_q<=gcnt;
                    end
                    //  A granule op holds r (and state) until its last granule pass;
                    //  all other ops (and the last pass) take the advance branch.
                    //  WB_STAGE: is_grp advances in S_GWB, not here (the `else`
                    //  chains into the original advance for all non-grp ops).
                    if (is_grp) begin
                    end else
                    //  vmvnr/vext route their whole-reg write through S_CWB, which
                    //  owns the r-advance / done -- skip the shared advance for them.
                    if (is_vmvnr || is_vext) begin
                    end else
                    //  compares/carry-mask + the mask family walk source granules
                    //  (stage-4; vmv.x.s reads only granule 0 -- single visit)
                    if ((is_grp || is_cmp || is_carry_m || is_mlg || is_mscan
                         || is_vfirst || is_vcpop) && !last_g) begin
                        gpass <= gpass + 1'b1;
                    end else begin
                        gpass <= {GPW{1'b0}};
                        if (r == iter_n - 1) begin
                            //  mask writes (single dest mask reg) -> granule drain;
                            //  scalar x-result ops (vfirst/vcpop/vmvxs) write x, not VRF.
                            if (is_cmp || is_carry_m) begin
                                state<=S_CMW; end   //  streamed mask write (gpass just reset to 0)
                            else if (is_mlg || is_mscan) begin
                                state<=S_CMW; end   //  streamed mask write
                            else begin
                                //  x-results from the scan summary (the g*
                                //  combinational values include this pass)
                                if (is_vfirst) x_res<=gfound ? {32'd0, gff} : {64{1'b1}};
                                else if (is_vcpop)  x_res<=gcnt;
                                else if (is_vmvxs)  x_res<=vmvxs_res;
                                done<=1; state<=S_IDLE;
                            end
                        end else r<=r+1;
                    end
                end

                S_GWB: begin
                    //  WB_STAGE writeback off the registered lane output grp_res_q.
                    //  Granule write: commit THIS pass's VBUS_W granule directly to
                    //  the VRF (no 256-bit accumulate). grp_res_q already has the
                    //  mask/tail keep-old is still pre-merged per element by the
                    //  lanes, so a disabled byte holds the same value the merge
                    //  wrote -- 6a enables ACTIVE bytes only (gwbe_grp_w; the
                    //  merge/carry classes over-enable, see the BE block) and
                    //  turns the VRF6 tail invariant on. g_wlast on the op's
                    //  final granule (read-cache coherence).
                    g_we    <= 1'b1;
                    g_wd    <= vd_q + r;
                    g_wg    <= gpass;
                    g_wdata <= grp_res_q[`KARU_VBUS_W-1:0];
                    g_wbe   <= gwbe_grp_w;
                    g_wlast <= last_g && (r == iter_n - 1);
                    g_wb_vlgov<=1'b1; g_wb_mdest<=1'b0;
                    g_wb_vsew<=vsew_q; g_wb_epr<=epr[15:0];
                    if (grp_sat_q) vsat_q<=1'b1;        //  sticky, OR every pass
                    if (!last_g) begin
                        gpass <= gpass + 1'b1;
                        state <= S_RUN;                 //  next granule, SAME dest reg: operands held
                    end else begin
                        gpass <= {GPW{1'b0}};
                        //  is also on (else stale op*_q/vold_q); plain S_RUN otherwise.
                        if (r == iter_n - 1) begin done<=1; state<=S_IDLE; end
                        else begin r <= r + 4'd1; state <= S_RUN; end
                    end
                end

                //  ---- bit-serial divide (V_DIV_C>1): one element at a time ----
                S_DLOAD: begin
                    dacc <= {64'b0, de_maga};
                    dbit <= 0;
                    state <= S_DSTEP;
                end
                S_DSTEP: begin
                    dacc <= dacc_next;
                    dbit <= dbit + 7'd1;
                    if (dbit == 7'd63) state <= S_DFIN;     //  64 restoring steps
                end
                S_DFIN: begin
                    //  store element dle's result (active in-vl only; else keep old)
                    if ((vm_q || v0_q[deg[7:0]]) && deg < vl_q)
                        for (db2 = 0; db2 < 8; db2 = db2 + 1)
                            if (db2 < (sewb >> 3))
                                dresbuf[(dle*(sewb>>3)+db2)*8 +: 8] <= dres_el[db2*8 +: 8];
                    if (dle == epr[5:0] - 6'd1) state <= S_DWR; //  register done
                    else begin dle <= dle + 6'd1; state <= S_DLOAD; end
                end
                S_DWR: begin
                    cwb_buf<=dresbuf; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                    cwb_be<=act_be(ebase, vsew_q, 32'd0); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                    if (r == nreg_q - 4'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                    else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_DLOAD; dle<=0; end
                    state<=S_CWB;
                end

                //  ---- bit-serial multiply (V_MUL_C>1): one element at a time ----
                S_MLOAD: begin
                    mmul_a   <= m_maga;
                    macc_acc <= {64'b0, m_magb};            //  multiplier into the low half
                    mcnt     <= V_MUL_C[6:0];
                    state    <= S_MSTEP;
                end
                S_MSTEP: begin
                    macc_acc <= m_next;
                    mcnt     <= mcnt - 7'd1;
                    if (mcnt == 7'd1) state <= wmul_q ? S_WMFIN : S_MFIN;   //  V_MUL_C radix steps
                end
                S_MFIN: begin
                    //  store element mle's result (active in-vl only; else keep old)
                    if ((vm_q || v0_q[meg[7:0]]) && meg < vl_q) begin
                        for (mb2 = 0; mb2 < 8; mb2 = mb2 + 1)
                            if (mb2 < (sewb >> 3))
                                mresbuf[(mle*(sewb>>3)+mb2)*8 +: 8] <= mres_el[mb2*8 +: 8];
                        if (is_vsmul && msm_sat) vsat_q <= 1'b1;
                    end
                    if (mle == epr[5:0] - 6'd1) state <= S_MWR; //  register done
                    else begin mle <= mle + 6'd1; state <= S_MLOAD; end
                end
                S_MWR: begin
                    cwb_buf<=mresbuf; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                    cwb_be<=act_be(ebase, vsew_q, 32'd0); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                    if (r == nreg_q - 4'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                    else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_MLOAD; mle<=0; end
                    state<=S_CWB;
                end

                //  ---- widening: one wide (2*SEW) dest register per cycle ----
                S_WRUN: begin
                    //  two source passes (wide_res holds this pass's granule,
                    //  zeros elsewhere -- OR-accumulate), then the cwb drain
                    if (!last_g) begin
                        `CWB_T <= wide_res;
                        gpass   <= gpass + 1'b1;
                    end else begin
                        `CWB_T<=`CWB_T | wide_res; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                        gpass<={GPW{1'b0}};
                        cwb_be<=act_be({26'b0, r} << eprw_lg, vsew_q + 3'd1, 32'd0); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q + 3'd1; cwb_epr<=epr_w[15:0];
                        if ({1'b0, r} == wide_iter - 5'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                        else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_WRUN; end
                        state<=`CWB_NX;
                    end
                end

                //  ---- widening serial multiply: per-element radix mul ----
                S_WMLOAD: begin
                    mmul_a   <= wm_maga;
                    macc_acc <= {64'b0, wm_magb};
                    mcnt     <= V_MUL_C[6:0];
                    state    <= S_MSTEP;                    //  shared radix step (wmul_q=1)
                end
                S_WMFIN: begin
                    //  store wide element mle (seed = old vd): in-vl active -> result;
                    //  tail (eg>=vl) + masked-off keep seed (old vd, undisturbed).
                    for (mb2 = 0; mb2 < 8; mb2 = mb2 + 1)
                        if (mb2 < (wsewb >> 3)) begin
                            if (wm_eg < vl_q && (vm_q || v0_q[wm_eg[7:0]]))
                                mresbuf[(mle*(wsewb>>3)+mb2)*8 +: 8] <= wm_res[mb2*8 +: 8];
                        end
                    if (mle == epr_w[5:0] - 6'd1) state <= S_WMWR;  //  wide reg done
                    else begin mle <= mle + 6'd1; state <= S_WMLOAD; end
                end
                S_WMWR: begin
                    cwb_buf<=mresbuf; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                    cwb_be<=act_be({26'b0, r} << eprw_lg, vsew_q + 3'd1, 32'd0); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q + 3'd1; cwb_epr<=epr_w[15:0];
                    if ({1'b0, r} == wide_iter - 5'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                    else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_WMLOAD; mle<=0; end
                    state<=S_CWB;
                end

                //  ---- narrowing (pipelined): stage A latches the window's
                //  shifted/rounded values; stage B clips+merges and advances.
                //  NWIN elems/window, 2 phases (low/high wide reg) per dest reg;
                //  nbuf accumulates across windows+phases, written at phase 1 end ----
                S_NA: begin             //  stage A: register the window's extract+shift+round
                    pA_sh<=nA_sh; pA_rnd<=nA_rnd; pA_loc<=nA_loc; pA_we<=nA_we;
                    state <= S_NB;
                end
                S_NB: begin             //  stage B: clip+merge; advance window/phase/reg
                    nbuf <= narrow_merge;
                    if (n_grpsat) vsat_q<=1'b1;
                    if ({26'b0, nse} + NWIN < epr_w) begin  //  more windows in this phase
                        nse <= nse + NWIN[5:0]; state <= S_NA;
                    end else if (nph == 1'b0) begin         //  phase 0 done -> phase 1 (wide reg 2r+1)
                        nph <= 1'b1; nse <= 6'd0; state <= S_NA;
                    end else begin                          //  phase 1 done -> write dest reg
                        `CWB_T<=narrow_merge; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                        cwb_be<=act_be(ebase, vsew_q, 32'd0); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                        nph<=1'b0; nse<=6'd0;
                        if (r == nreg_q - 4'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                        else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_NA; end
                        state<=`CWB_NX;
                    end
                end

                //  ---- reductions (pipelined): A latches the chunk's 2 partials,
                //  B folds them + accumulates; one 64-bit chunk per A/B pair ----
                S_RED_A: begin
                    red_pp0 <= nA_pp0; red_pp1 <= nA_pp1;
                    state <= S_RED_B;
                end
                S_RED_B: begin
                    red_acc <= red_next;                    //  accumulate this chunk's reduction
                    if (rch == CPR[3:0] - 4'd1) begin   //  all chunks of reg r folded (CPR, not lane count)
                        rch <= 4'd0;
                        if (r == nreg_q - 4'd1) state <= S_REDWR;
                        else begin r <= r + 4'd1; state <= S_RED_A; end
                    end else begin rch <= rch + 4'd1; state <= S_RED_A; end
                end
                S_REDWR: begin
                    //  vl=0 leaves vd unmodified (RVV reduction rule)
                    if (vl_q != 0) begin
                        `CWB_T<=red_wdata; cwb_wd<=vd_q; cwb_g<={GPW{1'b0}};
                        cwb_be<=lo_be(32'd1 << (is_wred ? vsew_q + 3'd1 : vsew_q)); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=is_wred ? vsew_q + 3'd1 : vsew_q; cwb_epr<=is_wred ? epr_w[15:0] : epr[15:0];
                        cwb_done<=1'b1; cwb_wlast<=1'b1;    //  single dest reg, op end
                        state<=`CWB_NX;
                    end else begin done<=1; state<=S_IDLE; end
                end

                //  ---- VPERM load: buffer the source/index groups, one reg/cycle ----
                S_PLOAD: begin
`ifdef KARU_V_PERM_RAM
                    //  one 64-bit word/cycle; pli (the VRF read address) advances
                    //  only after WPR word writes, so d_vs1/d_vs2 are held stable
                    //  stage-4: the snapshot words come from the granule feed
                    //  (vs*_g holds granule plw[WPW-1]; low bit = word within it)
                    pram[plwa] <= vs2_g[plw[0]*64 +: 64];
                    iram[plwa] <= vs1_g[plw[0]*64 +: 64];
                    plwa <= plwa + 1'b1;
                    if (plw != WPR - 1) plw <= plw + 1'b1;
                    else begin
                        plw <= {WPW{1'b0}};
                        if (pli == load_n - 4'd1) begin
`else
                    //  one granule per cycle from the granule latches (index plg)
                    pbuf[{26'b0, pli, plg} * `KARU_VBUS_W +: `KARU_VBUS_W] <= vs2_g;
                    ibuf[{26'b0, pli, plg} * `KARU_VBUS_W +: `KARU_VBUS_W] <= vs1_g;
                    if (!plg) plg <= 1'b1;
                    else begin
                    plg <= 1'b0;
                    if (pli == load_n - 4'd1) begin
`endif
                        ld_active <= 1'b0;  pli <= 0;   r <= 0; pse <= 0;
                        //  vcompress takes the serial-pack path; others the windowed VPERM
                        if (is_compress) begin
                            cse <= 0; out_idx <= 0; cslot <= 0; cstg <= {`KARU_VLEN{1'b0}}; state <= S_CMP_SCAN;
                        end else state <= S_PCOMP;
`ifdef KARU_V_PERM_RAM
                        end else pli <= pli + 4'd1;
                    end
`else
                    end else pli <= pli + 4'd1;
                    end
`endif
                end
                //  ---- VPERM compute: PLANES elements/cycle, write per register ----
                S_PCOMP: begin
                    pacc     <= perm_res;                   //  carry the window merge
                    iota_acc <= iota_next;                  //  carry viota running prefix
                    if (pse + PLANES >= epr) begin          //  register complete -> write
                        `CWB_T<=perm_res; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                        cwb_be<=act_be(ebase, vsew_q, is_slideup ? slide_off[31:0] : 32'd0); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                        pse <= 0;
                        if (r == nreg_q - 4'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                        else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_PCOMP; end
                        state<=`CWB_NX;
                    end else pse <= pse + PLANES[31:0];
                end

                //  ---- vcompress: serial pack, one source element/cycle ----
                S_CMP_SCAN: begin
                    if (cse >= vl_q) begin              //  scanned all in-vl sources
                        //  streaming: full regs were drained mid-scan; r continues
                        //  at the partial register (do NOT reset)
                        cmp_count <= out_idx;   state <= S_CMP_WR;
                    end else begin
                        if (cmp_sel) begin              //  mask-selected -> place at slot out_idx
                            for (csb = 0; csb < 8; csb = csb + 1)
                                if (csb < (sewb >> 3))
                                    cstg[(cslot*(sewb>>3) + csb[31:0])*8 +: 8] <= cmp_src[csb*8 +: 8];
                            if (cslot == epr - 32'd1) begin //  register filled -> drain
                                cslot <= 32'd0; state <= S_CMP_FLUSH;
                            end else cslot <= cslot + 32'd1;
                            out_idx <= out_idx + 32'd1;
                        end
                        cse <= cse + 32'd1;
                    end
                end
                //  ---- vcompress streaming: drain the filled staging register.
                //  Full BE (every slot freshly packed, all < count <= vl). S_CWB
                //  writes all granules ascending and advances r on return, so the
                //  granule contract (WGN2) is untouched. Filling the group's LAST
                //  register means count==VLMAX (every element selected): nothing
                //  remains to scan or pad, so that drain ends the op (else r would
                //  run past the group).
                S_CMP_FLUSH: begin
                    cwb_buf<=cstg; cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                    cwb_be<={`KARU_VLENB{1'b1}}; cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                    if (r == nreg_q - 4'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                    else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_CMP_SCAN; end
                    state<=S_CWB;
                end
                //  ---- stage-4 streamed mask-dest write (compares/carry-mask):
                //  granule g of vd = old (vold_g) where inactive, macc bits
                //  where active. Bit-RMW in data (mdest exempt, full BE).
                S_CMW: begin
                    g_we<=1'b1; g_wd<=vd_q; g_wg<=gpass;
                    g_wdata<=(vold_g & ~cmp_actall[gpass*`KARU_VBUS_W +: `KARU_VBUS_W])
                           | ((is_mscan ? mscan_wbits[gpass*`KARU_VBUS_W +: `KARU_VBUS_W]
                                        : macc[gpass*`KARU_VBUS_W +: `KARU_VBUS_W])
                              & cmp_actall[gpass*`KARU_VBUS_W +: `KARU_VBUS_W]);
                    g_wbe<={`KARU_VBUS_B{1'b1}};
                    g_wb_vlgov<=1'b0; g_wb_mdest<=1'b1; g_wb_vsew<=vsew_q; g_wb_epr<=epr[15:0];
                    g_wlast<=last_g;
                    if (!last_g) gpass<=gpass+1'b1;
                    else begin gpass<={GPW{1'b0}}; done<=1; state<=S_IDLE; end
                end
                //  ---- vcompress: write dest regs (packed | undisturbed-old-vd) ----
                S_CMP_WR: begin
                    //  partial register r: fresh slots 0..cmpn_n-1 of cstg; the
                    //  tail group registers get BE=0 (data don't-care)
                    cwb_buf<=cstg;
                    cwb_wd<=vd_q + r; cwb_g<={GPW{1'b0}};
                    cwb_be<=lo_be(cmpn_n << vsew_q); cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                    if (r == nreg_q - 4'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                    else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_CMP_WR; end
                    state<=S_CWB;
                end

                //  ========================================================
                //  FP: per-element sequencing (2b: through lane 0's FPU)
                //  ========================================================
                S_FRUN: begin
                    //  vfmv.f.s: f[rd] = vs2[0] (single scalar move; no VRF write)
                    if (vf_is_vmvfs) begin
                        f_res <= vf_e_vs2; writes_f <= 1'b1; done <= 1'b1; state <= S_IDLE;
                    end else begin
                        //  compare mask: seed from old vd here (vd_q valid now)
                        if (!vf_write_el) begin
                            //  masked-off / tail -> undisturbed; just advance
                            if (fe == vf_eprd - 1) state <= (vf_is_cmp ? S_FMWR : S_FWR);
                            else fe <= fe + 1;
                        end else if (vf_use_fpu) begin
                            vf_fpu_req <= 1'b1; state <= S_FWAIT;
                        end else begin
                            //  STAGE: register the element result (vf_res_elem, whose
                            //  vf_est_res->lane_est cone is the 10ns limiter) + flags;
                            //  S_FSWB writes fdbuf + advances fe next cycle. fe held here.
                            f_relem_q <= vf_res_elem;
                            f_estfl_q <= vf_is_est ? vf_est_flags : (vf_zfh ? vf_zfh_fl : 5'b0);
                            state     <= S_FSWB;
                        end
                    end
                end

                S_FWAIT: if (vf_fpu_done) begin
                    fflags <= fflags | vf_fpu_flags | (vf_is_warith ? vf_widen_nv : 5'b0);
                    if (vf_is_cmp) fmbuf[vf_geg[7:0]] <= vf_cmp_bit;
                    else if (vf_dest64) fdbuf[fe*64 +: 64] <= vf_fpu_res[63:0];
                    else                fdbuf[fe*32 +: 32] <= vf_fpu_res[31:0];
                    if (fe == vf_eprd - 1) state <= (vf_is_cmp ? S_FMWR : S_FWR);
                    else begin fe <= fe + 1; state <= S_FRUN; end
                end

                S_FWR: begin
                    cwb_buf<=fdbuf; cwb_wd<=vd_q + {1'b0, r}; cwb_g<={GPW{1'b0}};
                    cwb_be<= vf_is_vmvsf ? ((vl_q != 32'd0) ? lo_be(vf_is_d ? 32'd8 : 32'd4)
                                            : {`KARU_VLENB{1'b0}})
                         : act_be(vf_ebase, vf_dlg, 32'd0);
                    //  vfmv.s.f writes ELEMENT 0 only (vl=0: nothing) -- the FP
                    //  twin of the vmv.s.x exact-write-set case; everything else
                    //  through S_FWR writes all in-vl actives.
                    cwb_vlgov<=1'b1; cwb_mdest<=1'b0; cwb_vsew<=vf_dlg; cwb_epr<=vf_eprd[15:0];
                    fe<=0;
                    if (r == vf_nregd - 1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                    else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_FRUN; end
                    state<=S_CWB;
                end

                S_FMWR: begin
                    fe<=0;
                    if (r == vf_nregd - 1) begin
                        cwb_buf<=fmbuf; cwb_be<={`KARU_VLENB{1'b1}}; cwb_vlgov<=1'b0; cwb_mdest<=1'b1; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0]; cwb_wd<=vd_q; cwb_g<={GPW{1'b0}};
                        cwb_done<=1'b1; cwb_wlast<=1'b1; state<=S_CWB;
                    end else begin r<=r+1; state<=S_FRUN; end
                end

                S_FSWB: begin
                    //  write fdbuf from the REGISTERED sequential FP element
                    //  (f_relem_q), then advance fe (the advance staged S_FRUN
                    //  deferred). fe is unchanged since S_FRUN, so the slot matches.
                    //  Non-FPU branch never produces a compare -> always -> S_FWR.
                    fflags <= fflags | f_estfl_q;
                    if (vf_dest64)      fdbuf[fe*64 +: 64] <= f_relem_q[63:0];
                    else if (vf_zfh_n)  fdbuf[fe*16 +: 16] <= f_relem_q[15:0];  //  FP16 dest
                    else                fdbuf[fe*32 +: 32] <= f_relem_q[31:0];
                    if (fe == vf_eprd - 1) state <= S_FWR;
                    else begin fe <= fe + 1; state <= S_FRUN; end
                end

                //  Shared cold-write granule drain: write cwb_buf to {cwb_wd} one
                //  VBUS_W granule per cycle (ascending wg), then advance. r is held
                //  until the final granule so operands stay cached (no op_stall
                //  freeze mid-write); the final granule carries g_wlast=cwb_wlast.
                S_CWB: begin
                    g_we    <= 1'b1;
                    g_wd    <= cwb_wd;
                    g_wg    <= cwb_g;
                    g_wdata <= cwb_buf[cwb_g*`KARU_VBUS_W +: `KARU_VBUS_W];
                    g_wbe   <= cwb_be[cwb_g*`KARU_VBUS_B +: `KARU_VBUS_B];  //  6c
                    g_wlast <= (cwb_g == (VGRAN_C-1)) && cwb_wlast;
                    g_wb_vlgov<=cwb_vlgov; g_wb_mdest<=cwb_mdest;
                    g_wb_vsew<=cwb_vsew; g_wb_epr<=cwb_epr;
                    if (cwb_g != (VGRAN_C-1)) cwb_g <= cwb_g + 1'b1;
                    else begin
                        cwb_g <= {GPW{1'b0}};
                        if (cwb_done) begin done<=1; if (is_fp_q) fflags_set<=1'b1; state<=S_IDLE; end
                        else begin r <= r + 4'd1; state <= cwb_ret; end
                    end
                end

`ifdef KARU_V_CWB_STAGE
                //  KARU_V_CWB_STAGE: one-cycle hop -- move the registered cold
                //  assembly (cwb_asm) into the drain register, then drain in S_CWB.
                //  The deep combinational assembly now ends at cwb_asm (free to
                //  cluster near the assembly LUTs); cwb_asm->cwb_buf is a clean bus.
                S_CSTAGE: begin
                    cwb_buf <= cwb_asm;
                    state   <= S_CWB;
                end
`endif
                //  ---- FP reduction: acc = vs1[0]; acc OP= vs2[i] for active i ----
                S_FRSEED: begin
                    fracc <= (vf_is_d || vf_is_wred) ? vs1_g[63:0] : {32'hFFFF_FFFF, vs1_g[31:0]};  //  vs1[0] = granule 0
                    state <= S_FRSTEP;
                end
                S_FRSTEP: begin
                    if (vf_red_g < vl_q && (vm_q || v0_q[vf_red_g[7:0]]))
                        begin vf_fpu_req <= 1'b1; state <= S_FRWAIT; end
                    else begin
                        if (fe == epr - 1) begin
                            if (r == nreg_q - 1) begin r<=0; state<=S_FRWR; end
                            else begin r<=r+1; fe<=0; end
                        end else fe <= fe + 1;
                    end
                end
                S_FRWAIT: if (vf_fpu_done) begin
                    fracc <= vf_fpu_res; fflags <= fflags | vf_fpu_flags | (vf_is_wred ? vf_wb_f : 5'b0);
                    if (fe == epr - 1) begin
                        if (r == nreg_q - 1) begin r<=0; state<=S_FRWR; end
                        else begin r<=r+1; fe<=0; state<=S_FRSTEP; end
                    end else begin fe <= fe + 1; state <= S_FRSTEP; end
                end
                S_FRWR: begin               //  write vd[0] = acc (rest undisturbed); vl=0 -> no write
                    if (vl_q != 32'd0) begin
                        //  6c-b: only element 0 is enabled (lo_be below)
                        if (vf_is_d || vf_is_wred) cwb_buf <= {{(`KARU_VLEN-64){1'b0}}, fracc[63:0]};
                        else                       cwb_buf <= {{(`KARU_VLEN-32){1'b0}}, fracc[31:0]};
                        cwb_be<=lo_be((vf_is_d || vf_is_wred) ? 32'd8 : 32'd4);
                        cwb_vlgov<=1'b1; cwb_mdest<=1'b0;
                        cwb_vsew<=(vf_is_d || vf_is_wred) ? 3'd3 : 3'd2; cwb_epr<=vf_eprd[15:0];
                        cwb_wd<=vd_q; cwb_g<={GPW{1'b0}}; cwb_done<=1'b1; cwb_wlast<=1'b1;
                        state<=S_CWB;   //  fflags_set pulsed at S_CWB done (is_fp_q)
                    end else begin done<=1; fflags_set<=1; state<=S_IDLE; end
                end

                //  ========================================================
                //  FP parallel element-wise: all NLANES lane FPUs per slot
                //  ========================================================
                S_FPAR: begin
                    if (!vf_use_fpu) begin
                        //  merge / vfmv.v.f / estimate: write directly (no FPU)
                        //  STAGE: register the per-lane result + write context this
                        //  cycle; S_FPWB writes fdbuf + advances next cycle. Cuts the
                        //  f6_q->est->fdbuf cone (fs/gwin are held until S_FPWB).
                        fp_relem_q <= vf_p_relem;
                        fp_wr_q    <= vf_p_wr;
                        fp_estfl_q <= vf_p_estflags;
                        state      <= S_FPWB;
                    end else if (|vf_p_fire) begin
                        vf_fpu_req <= 1'b1; fp_pend <= vf_p_fire; state <= S_FPWAIT;
                    end else begin
                        //  all lanes masked-off / tail this slot -> nothing to write
                        if (fs == vf_epc - 1) begin
                            if (!last_g) begin gpass <= gpass + 1'b1; fs <= 4'd0; end   //  next granule (stay S_FPAR)
                            else begin gpass <= {GPW{1'b0}}; state <= S_FPWR; end   //  reset gpass for the S_FPWR granule-write up-count
                        end else fs <= fs + 4'd1;
                    end
                end

                S_FPWAIT: begin
                    fflags <= fflags | vf_p_doneflags;
                    for (flp = 0; flp < NLANES; flp = flp + 1)
                        if (fp_pend[flp] && lane_fp_done[flp]) begin
                            if (vf_is_cmp)
                                fmbuf[vf_p_geg[flp*32 +: 8]] <= vf_p_cmpbit[flp];
                            else if (vf_dest64) fdbuf[(gwin+flp)*64 +: 64]        <= lane_fp_res[flp*64 +: 64];
                            else                fdbuf[(gwin+flp)*64 + fs*32 +: 32] <= lane_fp_res[flp*64 +: 32];
                            fp_pend[flp] <= 1'b0;
                        end
                    //  all outstanding lanes have completed this cycle?
                    if ((fp_pend & ~lane_fp_done) == {NLANES{1'b0}}) begin
                        if (fs == vf_epc - 1) begin
                            if (!last_g) begin gpass <= gpass + 1'b1; fs <= 4'd0; state <= S_FPAR; end  //  next granule
                            else begin gpass <= {GPW{1'b0}}; state <= S_FPWR; end   //  reset gpass for the S_FPWR granule-write up-count
                        end else begin fs <= fs + 4'd1; state <= S_FPAR; end
                    end
                end

                S_FPWR: begin
                    //  Granule-write loop: fdbuf/fmbuf is fully assembled by now, so
                    //  write one VBUS_W granule per cycle. gpass UP-counts 0..VGRAN_C-1
                    //  (reset to 0 at the S_FPAR/S_FPWAIT/S_FPWB -> S_FPWR transition),
                    //  so granule {wg} ascends and g_wlast lands on the highest granule
                    //  (uniform with the integer path; satisfies GLR1/GLR2/WGN2). The
                    //  whole buffer is ready, so any order would do.
                    if (vf_is_cmp) begin                //  compares: one mask reg, write at last reg
                        if (r == vf_nregd - 1) begin
                            g_we    <= 1'b1; g_wd <= vd_q; g_wg <= gpass;
                            //  raw fmbuf bits where active, vold_g where not
                            //  (the fmbuf d_vold seed is gone)
                            g_wdata <= (vold_g & ~cmp_actall[gpass*`KARU_VBUS_W +: `KARU_VBUS_W])
                                     | (fmbuf[gpass*`KARU_VBUS_W +: `KARU_VBUS_W]
                                        & cmp_actall[gpass*`KARU_VBUS_W +: `KARU_VBUS_W]);
                            g_wbe   <= {`KARU_VBUS_B{1'b1}};
                            g_wlast <= (gpass == (VGRAN_C-1));
                            g_wb_vlgov<=1'b0; g_wb_mdest<=1'b1; //  mask dest: bit-granular
                            g_wb_vsew<=vsew_q; g_wb_epr<=epr[15:0];
                            if (gpass != (VGRAN_C-1)) gpass <= gpass + 1'b1;
                            else begin gpass<=0; fs<=4'd0; done<=1; fflags_set<=1; state<=S_IDLE; end
                        end else begin r<=r+1; gpass<=0; fs<=4'd0; state<=S_FPAR; end
                    end else begin
                        g_we    <= 1'b1; g_wd <= vd_q + {1'b0, r}; g_wg <= gpass;
                        g_wdata <= fdbuf[gpass*`KARU_VBUS_W +: `KARU_VBUS_W];
                        g_wbe   <= gwbe_fp_w;   //  6a: active bytes only (fdbuf pre-merged)
                        g_wlast <= (gpass == (VGRAN_C-1)) && (r == vf_nregd - 1);
                        g_wb_vlgov<=1'b1; g_wb_mdest<=1'b0;
                        g_wb_vsew<= vf_dest64 ? 3'd3 : 3'd2;    //  DEST width (widen != SEW)
                        g_wb_epr <= vf_eprd[15:0];
                        if (gpass != (VGRAN_C-1)) gpass <= gpass + 1'b1;
                        else begin
                            gpass <= 0; fs <= 4'd0;
                            if (r == vf_nregd - 1) begin done<=1; fflags_set<=1; state<=S_IDLE; end
                            else begin r<=r+1; state<=S_FPAR; end
                        end
                    end
                end
                S_FPWB: begin
                    //  write fdbuf from the REGISTERED non-FPU FP result (fp_relem_q),
                    //  then advance fs/gpass (the advance staged S_FPAR deferred).
                    //  fs/gwin are unchanged since S_FPAR, so the slot select matches.
                    if (vf_is_est) fflags <= fflags | fp_estfl_q;
                    for (flp = 0; flp < NLANES; flp = flp + 1)
                        if (fp_wr_q[flp]) begin
                            if (vf_dest64) fdbuf[(gwin+flp)*64 +: 64]        <= fp_relem_q[flp*64 +: 64];
                            else           fdbuf[(gwin+flp)*64 + fs*32 +: 32] <= fp_relem_q[flp*64 +: 32];
                        end
                    if (fs == vf_epc - 1) begin
                        if (!last_g) begin gpass <= gpass + 1'b1; fs <= 4'd0; state <= S_FPAR; end
                        else begin gpass <= {GPW{1'b0}}; state <= S_FPWR; end   //  reset gpass for the S_FPWR granule-write up-count
                    end else begin fs <= fs + 4'd1; state <= S_FPAR; end
                end
`ifdef KARU_EN_ZVK
                //  ====================================================
                //  standard Zvk: run each active EGW through karu_vcrypto
                //  ====================================================
                S_CREQ: begin
                    if (!c_group_active) begin
                        if (c_egw256 || chalf) begin
                            //  op ends on an inactive group: the last actual
                            //  write may sit on a non-final granule, so emit a
                            //  zero-BE pad with g_wlast (cache invalidate;
                            //  harmless if nothing was written)
                            if (r == nreg_q - 4'd1) state<=S_CPAD;
                            else begin r<=r+4'd1; chalf<=1'b0; cpre_q<=1'b0; end
                        end else begin
                            chalf<=1'b1;
                        end
                    end else if (c_egw256 && !cpre_q) begin
                        //  EGW256 low-half prefetch: indices are 0 this cycle
                        //  (op_stall has filled granule 0); latch and switch
                        clo_vd<=vold_g; clo_vs1<=vs1_g; clo_vs2<=vs2_g;
                        cpre_q<=1'b1;
                    end else begin
                        creq<=1'b1;
                        state<=S_CWAIT;
                    end
                end
                S_CPAD: begin
                    g_we<=1'b1; g_wd<=vd_q + {1'b0, r}; g_wg<={`KARU_VGW{1'b1}};
                    g_wdata<={`KARU_VBUS_W{1'b0}}; g_wbe<={`KARU_VBUS_B{1'b0}};
                    g_wlast<=1'b1; g_wb_vlgov<=1'b0; g_wb_mdest<=1'b0;
                    g_wb_vsew<=vsew_q; g_wb_epr<=epr[15:0];
                    done<=1'b1; state<=S_IDLE;
                end
                S_CWAIT: if (cdone) begin
                        cwb_g<={GPW{1'b0}};     //  init granule counter for the inline S_CWR loop
                        state<=S_CWR;
                    end
                S_CWR: begin
                    g_we    <= 1'b1; g_wd <= vd_q + {1'b0, r};
                    g_wbe   <= {`KARU_VBUS_B{1'b1}};
                    g_wb_vlgov<=1'b0; g_wb_mdest<=1'b0; //  element-group write: vl-GROUP gated
                    g_wb_vsew<=vsew_q; g_wb_epr<=epr[15:0];
                    if (!c_egw256) begin
                        //  EGW128: write ONLY the computed half-register granule
                        //  (exact enables; no old-half merge, no second write)
                        g_wg    <= chalf ? {`KARU_VGW{1'b1}} : {`KARU_VGW{1'b0}};
                        g_wdata <= cres[127:0];
                        g_wlast <= chalf && (r == nreg_q - 4'd1);
                        if (chalf) begin
                            if (r == nreg_q - 4'd1) begin done<=1'b1; state<=S_IDLE; end
                            else begin r<=r+4'd1; chalf<=1'b0; cpre_q<=1'b0; state<=S_CREQ; end
                        end else begin chalf<=1'b1; state<=S_CREQ; end
                    end else begin
                        //  EGW256: drain both granules of cres
                        g_wg    <= cwb_g;
                        g_wdata <= c_wdata[cwb_g*`KARU_VBUS_W +: `KARU_VBUS_W];
                        g_wlast <= (cwb_g == (VGRAN_C-1)) && (r == nreg_q - 4'd1);
                        if (cwb_g != (VGRAN_C-1)) cwb_g <= cwb_g + 1'b1;
                        else begin
                            cwb_g <= {GPW{1'b0}};
                            if (r == nreg_q - 4'd1) begin done<=1'b1; state<=S_IDLE; end
                            else begin r<=r+4'd1; chalf<=1'b0; cpre_q<=1'b0; state<=S_CREQ; end
                        end
                    end
                end
`endif
`ifdef KARU_EN_KECCAK
                //  ====================================================
                //  vkeccak: load vd e64/m8 group -> run f1600 -> store
                //  (one isolated 1600-bit permutation; r = group counter)
                //  ====================================================
                S_KLOAD: begin
                    //  one granule per cycle from vold_g (index kg)
                    ksbuf[{27'b0, r, kg} * `KARU_VBUS_W +: `KARU_VBUS_W] <= vold_g;
                    if (!kg) kg <= 1'b1;
                    else begin
                        kg <= 1'b0;
                        if (r == KVGRP[3:0]-4'd1) begin r<=4'd0; state<=S_KREQ; end
                        else r <= r + 4'd1;
                    end
                end
                S_KREQ:  begin kreq<=1'b1; state<=S_KWAIT; end
                S_KWAIT: if (kdone) begin ksbuf[1599:0]<=kstate_o; r<=4'd0; state<=S_KSTORE; end
                S_KSTORE: begin
                    cwb_buf<=ksbuf[r*VLEN +: VLEN]; cwb_wd<=vd_q + {1'b0, r}; cwb_g<={GPW{1'b0}};
                    cwb_be<={`KARU_VLENB{1'b1}}; cwb_vlgov<=1'b0; cwb_mdest<=1'b0; cwb_vsew<=vsew_q; cwb_epr<=epr[15:0];
                    if (r == KVGRP[3:0]-4'd1) begin cwb_done<=1'b1; cwb_wlast<=1'b1; end
                    else begin cwb_done<=1'b0; cwb_wlast<=1'b0; cwb_ret<=S_KSTORE; end
                    state<=S_CWB;
                end
`endif
            endcase
        end
    end
// synthesis translate_off
    //  Classification tripwire (sim only): every op must belong to a GRAN
    //  class -- an unclassified op would silently read stale operand
    //  latches (the old whole-register poison tripwire died with the
    //  rd1/rd2/rd3 latches).
    always @(posedge clk) if (!rst && (state != S_IDLE) && !rdu_gran) begin
        $display("[VARITH-ASSERT] unclassified op (rdu_gran=0) in state %0d @%0t", state, $time);
        $finish;
    end
// synthesis translate_on
// synthesis translate_off
//  Pulse-hazard safety net (sim only). While op_stall freezes the FSM, the
//  externally consumed START/COMPLETE pulses must NOT be held high -- that
//  would double-fire to karu64 / the subunits on unfreeze. `we` is exempt: the
//  adapter (karu_vrf_bram_wr) edge-captures + masks it. By construction these
//  pulse only while op_stall is low (after the operand fill), so this should
//  never trip; it guards the global-freeze contract (see the integration plan).
    //  The guarded signals are the ones CONSUMED outside the frozen FSM, which
    //  must never fire while op_stall holds (else they double-fire on unfreeze):
    //    - lane_fp_req : masked by !op_stall at the assign (so this checks the
    //      gate holds); vf_fpu_req itself MAY be frozen high -- that's fine.
    //    - done/fflags_set/writes_f/creq/kreq : completion/start pulses that by
    //      construction occur only with op_stall low; flag if one is frozen high.
    //  `we` is exempt -- the adapter edge-captures + masks it.
    always @(posedge clk) if (!rst && op_stall) begin
        if (done)         begin $display("[VRF-BRAM-ASSERT] op_stall && done @%0t",        $time); $finish; end
        if (|lane_fp_req) begin $display("[VRF-BRAM-ASSERT] op_stall && lane_fp_req @%0t",  $time); $finish; end
        if (fflags_set)   begin $display("[VRF-BRAM-ASSERT] op_stall && fflags_set @%0t",   $time); $finish; end
        if (writes_f)     begin $display("[VRF-BRAM-ASSERT] op_stall && writes_f @%0t",     $time); $finish; end
`ifdef KARU_EN_ZVK
        if (creq)         begin $display("[VRF-BRAM-ASSERT] op_stall && creq @%0t",         $time); $finish; end
`endif
`ifdef KARU_EN_KECCAK
        if (kreq)         begin $display("[VRF-BRAM-ASSERT] op_stall && kreq @%0t",         $time); $finish; end
`endif
    end

    //  ------------------------------------------------------------------
    //  Granule-loop sequencing invariants (sim only; doc/architecture.md).
    //  The NLANES compute lanes cover a register's CPR chunks over VGRAN_C =
    //  CPR/NLANES passes; gpass walks 0..VGRAN_C-1 PER dest register, the whole
    //  register is committed on the last pass (last_g), and r holds until then.
    //  At VGRAN_C==1 (the byte-identical flop path) every check below degenerates
    //  to always-true, so attaching this block costs nothing there.
    //  (Same inline $display/$finish style as the pulse-hazard block above; the
    //  port-level VRF contract is policed separately by karu_vrf_assert.)
    //  the legacy whole-register write-enable: permanently 0 since the
    //  flop-VRF deletion, so the checks below that key on it are vacuous
    //  guards against a regression re-driving it.
    wire va_grp_we = we;
    integer va_l;
    reg [GPW-1:0] va_gp_q;          //  gpass, previous cycle
    reg [3:0]     va_r_q;           //  r, previous cycle
    reg           va_grp_hold_q;    //  last cyc: is_grp non-last granule pass, !stall
    //  the granule pass that writes/advances: S_RUN normally, S_GWB under WB_STAGE
    //  (GLR3 = no write before last_g; GLR4 = r held until last_g).
    wire va_grp_wbstate = (state == S_GWB);
    always @(posedge clk) begin
        va_gp_q       <= gpass;
        va_r_q        <= r;
        va_grp_hold_q <= !rst && is_grp && va_grp_wbstate && !last_g && !op_stall;
    end

    always @(posedge clk) if (!rst) begin
        //  GLR1 (range): gpass always indexes a real granule pass -- protects the
        //  gpass*LANEW and (gwin+L)*64 dynamic part-selects.
        if (gpass >= VGRAN_C)
            begin $display("[VRF-BRAM-ASSERT] GLR1 gpass(%0d) >= VGRAN_C(%0d) @%0t", gpass, VGRAN_C, $time); $finish; end

        //  GLR2 (progression): gpass only holds, increments by one (below max), or
        //  wraps max->0. No skips/duplicates/back-steps => exact 0,1,..,VGRAN_C-1,0
        //  per dest register (and across register boundaries, which end at max).
        if (!( (gpass == va_gp_q)
            || ((gpass == va_gp_q + 1'b1) && (va_gp_q != (VGRAN_C-1)))
            || ((gpass == {GPW{1'b0}})    && (va_gp_q == (VGRAN_C-1))) ))
            begin $display("[VRF-BRAM-ASSERT] GLR2 illegal gpass step %0d->%0d (VGRAN_C=%0d) @%0t", va_gp_q, gpass, VGRAN_C, $time); $finish; end

        //  GLR3 (a non-last is_grp granule must not be the op's FINAL write):
        //  flop commits the WHOLE register only on the last pass, so va_grp_we
        //  (we/we_hot) must be 0 on a held (non-last) pass. BRAM writes EVERY pass
        //  via g_we, but g_wlast (op-final granule -> read-cache invalidate) must
        //  never fire on a non-last pass (else the cache invalidates mid-op).
        if (va_grp_hold_q && g_we && g_wlast)
            begin $display("[VRF-BRAM-ASSERT] GLR3 g_wlast on a non-last is_grp granule @%0t", $time); $finish; end

        //  GLR4 (dest reg held across granules): r does not advance until last_g.
        if (va_grp_hold_q && (r != va_r_q))
            begin $display("[VRF-BRAM-ASSERT] GLR4 r advanced mid-granule %0d->%0d @%0t", va_r_q, r, $time); $finish; end

        //  GLR5 (FP granule-write loop ends on the final granule): S_FPWR up-counts
        //  gpass 0..VGRAN_C-1 writing one granule/cycle, so the op's final granule
        //  write (g_wlast) must coincide with the highest granule (gpass==VGRAN_C-1).
        if ((state==S_FPWR) && g_we && g_wlast && (gpass != (VGRAN_C-1)))
            begin $display("[VRF-BRAM-ASSERT] GLR5 FP g_wlast at gpass(%0d) != last(%0d) @%0t", gpass, VGRAN_C-1, $time); $finish; end

        //  GLR6 (FP slot range): in the FP granule states fs indexes a real e32/e64
        //  slot -- protects the fs*32 part-selects. S_FPWB (staged parallel
        //  writeback) holds fs from S_FPAR and re-uses it in the same fs*32
        //  part-select, so it is covered here too (S_FPWB localparam is always
        //  defined; in non-FPWB builds state never reaches it).
        if (((state==S_FPAR) || (state==S_FPWAIT) || (state==S_FPWB)) && (fs >= vf_epc))
            begin $display("[VRF-BRAM-ASSERT] GLR6 fs(%0d) >= vf_epc(%0d) @%0t", fs, vf_epc, $time); $finish; end

        //  GLR7 (FP lane-request scope, busy): never request a lane that is busy
        //  (the granule-loop form of INV19); dbg_fp_req_busy = |(req & busy).
        if (dbg_fp_req_busy)
            begin $display("[VRF-BRAM-ASSERT] GLR7 FP req to a busy lane @%0t", $time); $finish; end

        //  GLR8 (FP lane-request scope, fire): a requested lane must be one this
        //  slot actually fires -- vf_seq drives lane 0 only, else per-lane vf_p_fire.
        for (va_l = 0; va_l < NLANES; va_l = va_l + 1)
            if (lane_fp_req[va_l] && !(vf_seq ? (va_l == 0) : vf_p_fire[va_l]))
                begin $display("[VRF-BRAM-ASSERT] GLR8 FP req to non-firing lane %0d @%0t", va_l, $time); $finish; end

        //  ---- granule write contract (WGN; varith-side) ----
        //  WGN1: a granule write addresses a real granule (protects {g_wd,g_wg}
        //        addressing in the adapter; the port width already bounds payload
        //        to one VBUS_W granule). g_wg walks with gpass, so GLR1/GLR2 cover
        //        its progression; this bounds the value. (Structurally always-true
        //        when VGRAN_C is a power of two == 2^VGW, e.g. VGRAN=2; the lint_off
        //        keeps it as a live contract for a future non-pow2 VGRAN.)
        /* verilator lint_off CMPCONST */
        /* verilator lint_off UNSIGNED */
        if (g_we && (g_wg >= VGRAN_C))
            begin $display("[VRF-BRAM-ASSERT] WGN1 g_wg(%0d) >= VGRAN_C(%0d) @%0t", g_wg, VGRAN_C, $time); $finish; end
        /* verilator lint_on UNSIGNED */
        /* verilator lint_on CMPCONST */
        //  WGN2: g_wlast (an op's FINAL granule write -> read-cache invalidate)
        //        may fire ONLY on a register's last granule. A g_wlast on a
        //        non-final granule would end the op mid-register (stale cache).
        if (g_we && g_wlast && (g_wg != (VGRAN_C-1)))
            begin $display("[VRF-BRAM-ASSERT] WGN2 g_wlast on non-final granule wg=%0d (last=%0d) @%0t", g_wg, VGRAN_C-1, $time); $finish; end
    end
// synthesis translate_on

endmodule
`undef CWB_T
`undef CWB_NX
