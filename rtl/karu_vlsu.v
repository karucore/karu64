//  karu_vlsu.v
//  Vector load/store unit. Two engines, selected by `pelem`:
//
//  CONTIGUOUS (unit-stride vle/vse, mask vlm/vsm, whole-register vl<nf>re/
//  vs<nf>r -- mapped onto unit-stride by the core):
//    - arbitrary (byte-granular) base alignment: memory is touched in
//      aligned 16-byte granules and the in-vl bytes are gathered/scattered
//      to the right register-byte positions;
//    - nbytes = vl * EEW_bytes; load vd-byte i <- mem[base+i] for active
//      i<nbytes (inactive/tail kept = undisturbed); store strobed.
//
//  PER-ELEMENT (`pelem`: strided vlse/vsse, indexed vlux/vlox/vsux/vsox,
//  and all segment *seg* forms; unit-stride segment = stride nf*eewb):
//    - addr(i,f) = base + (indexed ? idx[i] : i*stride) + f*EEW_bytes;
//    - the index group (vs2, idx_eew) is buffered first, then the data
//      group (old vd / store source); one (element,field) per pass, with a
//      1-or-2-granule memory access for elements straddling a 16-byte line;
//    - segment field f -> register group vd + f*EMUL.
//
//  Masking (vm=0) and tail follow the agnostic-as-undisturbed convention
//  (keep old vd) to match the ACT4/Sail golden. LMUL/EMUL register groups
//  span vd..vd+n-1 contiguously. Single multi-cycle op at a time
//  (standard req/busy/done handshake).

`include "karu_vcfg.vh"

module karu_vlsu #(
    parameter integer GRAN = `KARU_VGRAN,
    parameter integer GW   = (`KARU_VGRAN > 1) ? $clog2(`KARU_VGRAN) : 1
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    output wire         busy,
    input  wire         is_store,
    input  wire [63:0]  base,           //  x[rs1] (64-bit VA -- phase V1 of
                                        //  doc/architecture.md; identity/bare
                                        //  until the V2 preflight translator)
    input  wire [4:0]   vd,             //  vd / vs3 (group base)
    input  wire [1:0]   eew,            //  0=8,1=16,2=32,3=64 (bytes = 1<<eew)
    input  wire [63:0]  vl,
    input  wire [31:0]  vstart,         //  first element to touch (RVV 3.7; elements
                                        //  below it are prestart = undisturbed/not stored)
    input  wire         vta,
    input  wire         vm,             //  1 = unmasked
    input  wire         vma,            //  mask-inactive policy: 1 = agnostic
    input  wire [3:0]   nreg,           //  registers in the group (1,2,4,8) -- per field
    input  wire [`KARU_VLEN-1:0] v0mask,    //  v0 (mask bit per element in bit i)
    //  -- per-element engine (strided / indexed / segment) --
    input  wire         pelem,          //  use the per-element path (else contiguous)
    input  wire         indexed,        //  indexed (addr = base + idx[i]); else linear stride
    input  wire [63:0]  stride,         //  linear byte stride (strided = x[rs2], signed
                                        //  64-bit; unit-seg = nf*eewb)
    input  wire [3:0]   nf,             //  segment field count (1..8)
    input  wire [4:0]   idx_vs,         //  index vector register base (indexed)
    input  wire [1:0]   idx_eew,        //  index element width (0=8..3=64)
    input  wire [3:0]   idx_nreg,       //  index group register count (EMUL at idx EEW)
    input  wire         ff,             //  fault-only-first (vle*ff / vlseg*ff): a fault
                                        //  past element 0 trims vl instead of trapping
    output reg          done,
    //  -- translation preflight (phase V2, doc/architecture.md) --
    //  Every memory access is translated through karu64's shared DMMU BEFORE
    //  any VRF write or store side effect (precise by construction; vstart
    //  stays 0 across a fault). In bare/M mode karu_sv39 answers identity in
    //  one cycle, so this unit needs no mode awareness at all.
    output reg          xlate_req,      //  1-cycle pulse
    output reg  [63:0]  xlate_va,
    output reg          xlate_st,       //  1 = store access (PTE W/D semantics)
    input  wire         xlate_done,     //  pulse; pa/fault valid this cycle
    input  wire         xlate_fault,
    input  wire [63:0]  xlate_pa,
    output reg          fault_abort,    //  pulse: op aborted on a translation fault
                                        //  (no architectural side effects occurred);
                                        //  the core traps with the DMMU cause/VA
    output reg          trim_req,       //  pulse: fault-only-first trimmed vl
    output reg  [31:0]  trim_vl,        //  the new (nonzero) vl

    //  -- karu_mem vector port --
    output reg          vmem_req,
    input  wire         vmem_busy,
    output reg          vmem_is_store,
    output reg  [63:0]  vmem_addr,      //  64-bit (V1); bare/identity today, so the
                                        //  core truncates to the 32-bit physical port
    output reg  [127:0] vmem_wdata,
    output reg  [15:0]  vmem_wstrb,
    input  wire         vmem_done,
    input  wire [127:0] vmem_rdata,

    //  -- VRF granule ports --
    output reg  [4:0]   vg_rs,
    output reg  [GW-1:0] vg_rg,
    input  wire [127:0] vg_rdata,
    output reg          vg_we,
    output reg  [4:0]   vg_wd,
    output reg  [GW-1:0] vg_wg,
    output reg  [127:0] vg_wdata
);
    localparam integer MAXRG = 8 * GRAN;    //  register granules at LMUL=8
    localparam integer MAXMG = MAXRG + 2;   //  + slack for the misaligned head

    //  latched request
    reg [63:0]  base_q;
    reg [4:0]   vd_q;
    reg         st_q, vta_q, vm_q, vma_q;
    reg [1:0]   eew_q;
    reg [`KARU_VLEN-1:0] v0_q;
    reg [31:0]  nbytes;         //  (last active element + 1) * EEW_bytes
    reg [31:0]  vst_b;          //  first active element * EEW_bytes
    reg [31:0]  act_lo_q;       //  first active element index (ff trim with a mask)
    //  ---- req-cycle ACTIVE-element bounds (contiguous path) ----
    //  RVV 7.x: only ACTIVE elements may access memory or raise exceptions.
    //  The translated/accessed byte range is therefore bounded by the FIRST
    //  and LAST active elements in [vstart, vl) -- prestart, masked-off and
    //  tail elements neither fault nor (for vle*ff) trim vl, even when they
    //  land on an unmapped page (review finding: the first version used
    //  [vstart, vl) and translated a masked-off second page). Combinational
    //  scan over the request inputs, sampled only at S_IDLE; this unit is
    //  nowhere near a timing wall. No active elements -> vst_b == nbytes ==
    //  0 -> the existing no-traffic path (loads write the unchanged group).
    integer ai;
    reg [31:0]  act_lo, act_hi; reg act_any;
    always @(*) begin
        act_lo = 32'd0; act_hi = 32'd0; act_any = 1'b0;
        for (ai = 0; ai < `KARU_VLEN; ai = ai + 1)
            if ((ai >= vstart) && (ai < vl) && (vm || v0mask[ai])) begin
                if (!act_any) act_lo = ai[31:0];
                act_hi  = ai[31:0];
                act_any = 1'b1;
            end
    end
    wire [31:0] vst_b_w = act_any ? (act_lo << eew) : 32'd0;
    wire [31:0] nb_w    = act_any ? ((act_hi + 32'd1) << eew) : 32'd0;
    reg [3:0]   boff;           //  base & 15
    reg [63:0]  base_al;        //  base & ~15
    reg [5:0]   n_mg;           //  memory granules covering [boff, boff+nbytes)
    reg [5:0]   nrg;            //  register granules in the group (nreg*GRAN)
    reg [5:0]   mg;             //  current memory granule
    reg [5:0]   rg;             //  current register granule (global, 0..nrg-1)

    wire [127:0] asm_gran;
    wire [127:0] st_wdata;
    wire [15:0]  st_strb;

    //  ---- translation state (V2 preflight) ----
    reg         ff_q;                   //  latched fault-only-first
    //  contiguous path: the whole group spans at most ONE 4 KiB boundary
    //  (8 regs x VLENB + misalign << 4096 -- guarded below), so two page
    //  translations cover every granule. vp0 = first accessed VA page;
    //  pp0/pp1 = its phys page and the next page's.
    reg [51:0]  vp0, pp0, pp1;
    //  pelem path: phys pages for the current element's 1-or-2 granules,
    //  plus a 1-entry VA-page -> PA-page cache (strided/segment ops hammer
    //  the same page; misses re-translate through the DMMU TLB, 1 cycle).
    reg [51:0]  pe_pp0, pe_pp1;
    reg         xc_v;
    reg [51:0]  xc_vp, xc_pp;
    reg         pe_pass1;               //  pelem STORE check-only pass (translate
                                        //  everything before the first byte hits memory)
// synthesis translate_off
    initial if (8 * `KARU_VLENB > 4096) begin
        $display("karu_vlsu: register group (8*VLENB=%0d) exceeds a 4 KiB page; the 2-page contiguous preflight does not cover it", 8*`KARU_VLENB);
        $finish(1);
    end
// synthesis translate_on

    //  per-granule VRF register/offset for the global granule index `rg`
    wire [4:0]      rg_reg = vd_q + rg[5:GW];   //  vd + (rg / GRAN)
    wire [GW-1:0]   rg_off = rg[GW-1:0];        //  rg % GRAN

    //  ================= per-element engine (strided/indexed/segment) =========
    localparam integer MAXB = 8 * `KARU_VLENB;      //  register-group bytes at the 8-reg max
    reg         idx_mode_q;
    reg [63:0]  stride_q;
    reg [3:0]   nf_q, nregf_q, idx_nreg_q;
    reg [4:0]   idx_vs_q;
    reg [1:0]   idx_eew_q;
    reg [31:0]  pe_vl;
    reg [31:0]  pe_vst;         //  latched vstart (pelem path; element units)
    reg [31:0]  pe_i;           //  element (segment) index
    reg [3:0]   pe_f;           //  field index within a segment
    reg [5:0]   pe_nrg, idx_nrg;    //  data / index group granule counts
    reg [127:0] g0d, g1d;       //  captured memory granules (element may straddle)
    wire [63:0] idxv;

    wire [31:0] eewb   = 32'd1 << eew_q;                    //  data element bytes
    wire [31:0] fld_rb = {28'b0, nregf_q} * `KARU_VLENB;    //  bytes per field register-group
    wire [4:0]  idx_rreg = idx_vs_q + rg[5:GW];
    wire [GW-1:0] idx_roff = rg[GW-1:0];

    //  current element address + geometry (64-bit VA arithmetic, V1: strided
    //  offsets wrap in 64 bits like the scalar XLEN stride; indexed offsets
    //  are zero-extended per the spec)
    wire [63:0] eaddr  = base_q
                       + (idx_mode_q ? idxv : ({32'b0, pe_i} * stride_q))
                       + ({60'b0, pe_f} * {32'b0, eewb});
    wire [3:0]  pe_off = eaddr[3:0];
    wire [63:0] g0abs  = {eaddr[63:4], 4'b0};
    wire        straddle = ({2'b0, pe_off} + eewb[5:0]) > 6'd16;
    //  V2 translation geometry. Contiguous: the first/last ACCESSED bytes
    //  (prestart excluded -- RVV 5.4) bound the <=2 pages to translate; each
    //  granule's PA is its VA offset under pp0/pp1. Pelem: the element's
    //  granule pair needs page(g0abs) and, when the pair crosses a 4 KiB
    //  boundary, page(g0abs+16).
    wire [63:0] va_first = base_q + {32'b0, vst_b};
    wire [63:0] va_last  = base_q + {32'b0, nbytes} - 64'd1;
    wire [63:0] g_va = base_al + ({58'b0, mg} << 4);
    wire [63:0] g_pa = {(g_va[63:12] == vp0) ? pp0 : pp1, g_va[11:0]};
    wire [51:0] pgA      = g0abs[63:12];
    wire [63:0] g1va     = g0abs + 64'd16;
    wire        need_hi  = straddle && (g1va[63:12] != pgA);
    //  fault-only-first trim geometry (contiguous): elements wholly below
    //  the faulting second page survive; 0 survivors = element-0 fault.
    wire [63:0] pg1_base = {va_first[63:12] + 52'd1, 12'b0};
    wire [63:0] ff_bytes = pg1_base - base_q;
    wire [31:0] ff_vl    = ff_bytes[31:0] >> eew_q;
    wire [31:0] ff_nb    = ff_vl << eew_q;
    wire        pe_act = vm_q || v0_q[pe_i[7:0]];
    wire [31:0] rbyte0 = ({28'b0, pe_f} * fld_rb) + (pe_i * eewb);  //  flat dest/src byte base

    //  store/writeback data assembled from the isolated scratch buffer.
    wire [127:0] pe_wd0, pe_wd1, pe_wbgran;
    wire [15:0]  pe_st0, pe_st1;

    localparam [5:0] S_IDLE=6'd0, S_RDREG=6'd1, S_RDREG_W=6'd2,
               S_MEMRD=6'd3, S_MEMRD_W=6'd4, S_LDWR=6'd5,
               S_STWR=6'd6, S_STWR_W=6'd7,
               S_PE_IDX=6'd8, S_PE_IDXW=6'd9, S_PE_RD=6'd10, S_PE_RDW=6'd11,
               S_PE_GO=6'd12, S_PE_RD0=6'd13, S_PE_RD0W=6'd14, S_PE_RD1=6'd15,
               S_PE_RD1W=6'd16, S_PE_LDB=6'd17, S_PE_WR0=6'd18, S_PE_WR0W=6'd19,
               S_PE_WR1=6'd20, S_PE_WR1W=6'd21, S_PE_NEXT=6'd22, S_PE_WB=6'd23;
    //  post-translate destination for the current pelem element (derived from
    //  the S_PE_* states above; moved below the enum so it follows its decls).
    wire [5:0]  pe_run   = pe_pass1 ? S_PE_NEXT : (st_q ? S_PE_WR0 : S_PE_RD0);
    //  Extra +1 wait states: the macro-VRF granule read is registered, so each
    //  VRF-read issue state needs one bubble before its capture state. See
    //  doc/architecture.md.
    localparam [5:0] S_RDREG_B=6'd24, S_PE_IDX_B=6'd25, S_PE_RD_B=6'd26;
    //  V2 translation-preflight states: contiguous 2-page xlate (XLT*) and
    //  the per-element 1-or-2 page xlate (PE_XL*).
    localparam [5:0] S_XLT0=6'd27, S_XLT0W=6'd28, S_XLT1=6'd29, S_XLT1W=6'd30,
               S_PE_XLA=6'd31, S_PE_XLAW=6'd32, S_PE_XLB=6'd33, S_PE_XLBW=6'd34;
    reg [5:0] state;
    assign busy = (state != S_IDLE);

    karu_vlsu_buf #(.GRAN(GRAN), .GW(GW)) buf_u (
        .clk(clk),
        .rg(rg), .mg(mg), .boff(boff), .nbytes(nbytes), .vst_b(vst_b),
        .eew_q(eew_q), .vm_q(vm_q), .v0_q(v0_q),
        .asm_gran(asm_gran), .st_wdata(st_wdata), .st_strb(st_strb),
        .idx_eew_q(idx_eew_q), .pe_i(pe_i), .rbyte0(rbyte0), .eewb(eewb),
        .pe_off(pe_off), .idxv(idxv), .pe_wd0(pe_wd0), .pe_wd1(pe_wd1),
        .pe_st0(pe_st0), .pe_st1(pe_st1), .pe_wbgran(pe_wbgran),
        .regbuf_we(state == S_RDREG_W), .regbuf_wrg(rg), .regbuf_wdata(vg_rdata),
        .membuf_we((state == S_MEMRD_W) && vmem_done), .membuf_wmg(mg), .membuf_wdata(vmem_rdata),
        .pib_we(state == S_PE_IDXW), .pib_wrg(rg), .pib_wdata(vg_rdata),
        .peb_gran_we(state == S_PE_RDW), .peb_wrg(rg), .peb_wdata(vg_rdata),
        .peb_elem_we(state == S_PE_LDB), .peb_elem_base(rbyte0), .peb_elem_off(pe_off),
        .peb_elem_g0(g0d), .peb_elem_g1(g1d)
    );

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; done<=0; vmem_req<=0; vg_we<=0;
            xlate_req<=0; fault_abort<=0; trim_req<=0;
        end else begin
            done<=0; vmem_req<=0; vg_we<=0;
            xlate_req<=0; fault_abort<=0; trim_req<=0;
            case (state)
                S_IDLE: if (req) begin
                    base_q<=base; vd_q<=vd; st_q<=is_store; vta_q<=vta;
                    vm_q<=vm; vma_q<=vma; v0_q<=v0mask; eew_q<=eew;
                    ff_q<=ff; xc_v<=0;
                    pe_pass1<=pelem && is_store;    //  stores: check-only pass first
                    rg<=0;
                    if (pelem) begin
                        idx_mode_q<=indexed; stride_q<=stride; nf_q<=nf; nregf_q<=nreg;
                        idx_vs_q<=idx_vs; idx_eew_q<=idx_eew; idx_nreg_q<=idx_nreg;
                        pe_vl<=vl[31:0]; pe_vst<=vstart; pe_i<=0; pe_f<=0;
                        pe_nrg  <= ({2'b0, nf} * {2'b0, nreg}) << GW;   //  nf*nreg*GRAN
                        idx_nrg <= {2'b0, idx_nreg} << GW;
                        state <= indexed ? S_PE_IDX : S_PE_RD;
                    end else begin
                        //  byte bounds = the ACTIVE element range (act_lo/act_hi
                        //  scan above): bytes outside it are prestart, tail or
                        //  masked-off -- all keep-old, never accessed, never
                        //  translated (RVV 5.4 / 7.x: they could be MMIO or, with
                        //  translation on, an unmapped page).
                        nbytes <= nb_w;
                        vst_b  <= vst_b_w;
                        act_lo_q <= act_lo;
                        boff    <= base[3:0];
                        base_al <= {base[63:4], 4'b0};
                        n_mg <= ((base[3:0] + nb_w) + 32'd15) >> 4;
                        nrg  <= {2'b0, nreg} << GW;     //  nreg * GRAN (GRAN = 1<<GW)
                        //  the granule walk starts at the first ACTIVE byte's granule
                        mg <= (({28'b0, base[3:0]} + vst_b_w) >> 4) & 6'h3F;
                        vg_rs<=vd; vg_rg<={GW{1'b0}};
                        state<=S_RDREG;
                    end
                end

                //  ---- read all register granules in the group into regbuf ----
                S_RDREG: begin
                    vg_rs<=rg_reg; vg_rg<=rg_off;
                    state<=S_RDREG_B;
                end
                S_RDREG_B: state<=S_RDREG_W;    //  BRAM registered-read bubble
                S_RDREG_W: begin
                    if (rg == nrg-1) begin
                        rg<=0;
                        //  no active bytes (vl == 0, or vstart >= vl) -> NO memory
                        //  traffic, no translation (RVV: no accessed element, no
                        //  exception). Loads still write the (unchanged) group;
                        //  stores do nothing. Otherwise translate the <=2 touched
                        //  pages BEFORE any memory access (V2 preflight).
                        state <= (vst_b >= nbytes) ? (st_q ? S_STWR : S_LDWR)
                                                   : S_XLT0;
                    end else begin
                        rg<=rg+1; state<=S_RDREG;
                    end
                end

                //  ---- contiguous preflight: translate the 1-or-2 pages the
                //  accessed byte range [va_first, va_last] touches ----
                S_XLT0: begin
                    xlate_req<=1; xlate_va<=va_first; xlate_st<=st_q;
                    state<=S_XLT0W;
                end
                S_XLT0W: if (xlate_done) begin
                    if (xlate_fault) begin
                        //  the FIRST ACTIVE element lives on this page. ff load
                        //  with act_lo > 0: the faulting element's index is
                        //  nonzero, so trim vl there and complete (nothing
                        //  below act_lo is active -> empty access range, the
                        //  group is written back unchanged). act_lo == 0 (a
                        //  true element-0 fault) or any store: trap.
                        if (ff_q && !st_q && act_lo_q != 32'd0) begin
                            trim_req<=1; trim_vl<=act_lo_q;
                            nbytes<=vst_b;          //  empty range
                            state<=S_LDWR;
                        end else begin
                            fault_abort<=1; state<=S_IDLE;
                        end
                    end else begin
                        vp0<=va_first[63:12]; pp0<=xlate_pa[63:12];
                        pp1<=xlate_pa[63:12];   //  overwritten if a 2nd page exists
                        if (va_last[63:12] != va_first[63:12]) state<=S_XLT1;
                        else state <= st_q ? S_STWR : S_MEMRD;
                    end
                end
                S_XLT1: begin
                    xlate_req<=1; xlate_va<=pg1_base; xlate_st<=st_q;
                    state<=S_XLT1W;
                end
                S_XLT1W: if (xlate_done) begin
                    if (xlate_fault) begin
                        //  fault-only-first LOAD: trim vl to the whole elements
                        //  below the faulting page and complete normally. The
                        //  first ACTIVE element is on page 0 here (XLT0 covered
                        //  its page), so ff_vl >= act_lo+1 >= 1; the act_lo_q
                        //  fallback is belt-and-braces for a straddling first
                        //  active element. Anything else traps.
                        if (ff_q && !st_q && (ff_vl != 32'd0 || act_lo_q != 32'd0)) begin
                            trim_req<=1;
                            trim_vl<= (ff_vl != 32'd0) ? ff_vl : act_lo_q;
                            nbytes <= (ff_vl != 32'd0) ? ff_nb : vst_b;
                            n_mg   <= (({26'b0, boff} + ((ff_vl != 32'd0) ? ff_nb : vst_b)) + 32'd15) >> 4;
                            state  <= ((ff_vl != 32'd0) && (vst_b < ff_nb)) ? S_MEMRD : S_LDWR;
                        end else begin
                            fault_abort<=1; state<=S_IDLE;
                        end
                    end else begin
                        pp1<=xlate_pa[63:12];
                        state <= st_q ? S_STWR : S_MEMRD;
                    end
                end

                //  ---- load: read memory granules, then assemble+write group ----
                //  (g_pa composes the granule's VA offset under the preflighted
                //  phys pages; identity when bare, so addresses are unchanged.)
                //  A granule with NO active bytes is never read at all (st_strb
                //  is pure geometry+mask, valid for loads too): a fully-masked-
                //  off granule may sit on read-sensitive MMIO. Its membuf slot
                //  stays stale -- asm_gran never selects inactive bytes.
                S_MEMRD: begin
                    if (st_strb == 16'b0) begin
                        if (mg == n_mg-1) begin mg<=0; state<=S_LDWR; end
                        else mg<=mg+1;
                    end else begin
                        vmem_req<=1; vmem_is_store<=0;
                        vmem_addr<= g_pa;
                        state<=S_MEMRD_W;
                    end
                end
                S_MEMRD_W: if (vmem_done) begin
                    if (mg == n_mg-1) begin mg<=0; state<=S_LDWR; end
                    else begin mg<=mg+1; state<=S_MEMRD; end
                end
                S_LDWR: begin
                    vg_we<=1; vg_wd<=rg_reg; vg_wg<=rg_off; vg_wdata<=asm_gran;
                    if (rg == nrg-1) begin done<=1; state<=S_IDLE; end
                    else rg<=rg+1;
                end

                //  ---- store: write each memory granule (byte-strobed) ----
                //  A granule whose strobes are all zero (fully masked-off body)
                //  is SKIPPED, not written: a zero-strobe AXI write is still an
                //  access an MMIO slave could observe.
                S_STWR: begin
                    if (vst_b >= nbytes) begin done<=1; state<=S_IDLE; end
                    else if (st_strb == 16'b0) begin
                        if (mg == n_mg-1) begin done<=1; state<=S_IDLE; end
                        else mg<=mg+1;
                    end else begin
                        vmem_req<=1; vmem_is_store<=1;
                        vmem_addr<= g_pa;
                        vmem_wdata<= st_wdata;
                        vmem_wstrb<= st_strb;
                        state<=S_STWR_W;
                    end
                end
                S_STWR_W: if (vmem_done) begin
                    if (mg == n_mg-1) begin done<=1; state<=S_IDLE; end
                    else begin mg<=mg+1; state<=S_STWR; end
                end

                //  ================= per-element engine =================
                //  ---- indexed: buffer the index vector group into pib ----
                S_PE_IDX: begin
                    vg_rs<=idx_rreg; vg_rg<=idx_roff;
                    state<=S_PE_IDX_B;
                end
                S_PE_IDX_B: state<=S_PE_IDXW;   //  BRAM registered-read bubble
                S_PE_IDXW: begin
                    if (rg == idx_nrg-1) begin rg<=0; state<=S_PE_RD; end
                    else begin rg<=rg+1; state<=S_PE_IDX; end
                end
                //  ---- read the data group (old vd for load, source for store) ----
                S_PE_RD: begin
                    vg_rs<=rg_reg; vg_rg<=rg_off;
                    state<=S_PE_RD_B;
                end
                S_PE_RD_B: state<=S_PE_RDW;     //  BRAM registered-read bubble
                S_PE_RDW: begin
                    if (rg == pe_nrg-1) begin
                        //  start the element walk at vstart (prestart elements are
                        //  never accessed); vstart >= vl touches no elements, same
                        //  as vl == 0 (loads still write back the unchanged group).
                        rg<=0; pe_i<=pe_vst; pe_f<=0;
                        state <= (pe_vl == 32'd0 || pe_vst >= pe_vl)
                               ? (st_q ? S_IDLE : S_PE_WB) : S_PE_GO;
                        if ((pe_vl == 32'd0 || pe_vst >= pe_vl) && st_q) done<=1;
                    end else begin rg<=rg+1; state<=S_PE_RD; end
                end
                //  ---- per (element,field): translate, then mem access ----
                S_PE_GO: begin
                    //  masked-off segment: skip entirely -- no translation, no
                    //  access, no fault (RVV: inactive elements never except).
                    //  Active: translate the element's page(s) first (S_PE_XL*).
                    if (!pe_act) state <= S_PE_NEXT;
                    else state <= S_PE_XLA;
                end

                //  ---- element translation: page(g0abs) (+ page(g0abs+16) when
                //  the granule pair straddles a 4 KiB boundary). The 1-entry
                //  cache short-circuits the common same-page-as-last-time case;
                //  misses hit the DMMU TLB (1 cycle). On a pelem STORE this runs
                //  twice: pe_pass1 walks every active element fault-checking
                //  only, so no byte is stored before all addresses prove good.
                //  Loads are single-pass: nothing architectural happens until
                //  S_PE_WB, so an inline fault aborts (or ff-trims) cleanly. ----
                S_PE_XLA: begin
                    if (xc_v && xc_vp == pgA) begin
                        pe_pp0 <= xc_pp;    pe_pp1 <= xc_pp;
                        state  <= need_hi ? S_PE_XLB : pe_run;
                    end else begin
                        xlate_req<=1; xlate_va<=g0abs; xlate_st<=st_q;
                        state<=S_PE_XLAW;
                    end
                end
                S_PE_XLAW: if (xlate_done) begin
                    if (xlate_fault) begin
                        //  ff LOAD past element 0: trim vl to the faulting element
                        //  and write back what loaded so far (peb holds < pe_i;
                        //  a partially-loaded first-faulting segment is allowed).
                        if (ff_q && !st_q && pe_i != 32'd0) begin
                            trim_req<=1; trim_vl<=pe_i; pe_vl<=pe_i;
                            rg<=0; state<=S_PE_WB;
                        end else begin fault_abort<=1; state<=S_IDLE; end
                    end else begin
                        pe_pp0 <= xlate_pa[63:12];  pe_pp1 <= xlate_pa[63:12];
                        xc_v<=1; xc_vp<=pgA; xc_pp<=xlate_pa[63:12];
                        state <= need_hi ? S_PE_XLB : pe_run;
                    end
                end
                S_PE_XLB: begin
                    xlate_req<=1; xlate_va<={g1va[63:12], 12'b0}; xlate_st<=st_q;
                    state<=S_PE_XLBW;
                end
                S_PE_XLBW: if (xlate_done) begin
                    if (xlate_fault) begin
                        if (ff_q && !st_q && pe_i != 32'd0) begin
                            trim_req<=1; trim_vl<=pe_i; pe_vl<=pe_i;
                            rg<=0; state<=S_PE_WB;
                        end else begin fault_abort<=1; state<=S_IDLE; end
                    end else begin
                        pe_pp1 <= xlate_pa[63:12];
                        //  cache the HIGH page: the next element usually starts there
                        xc_v<=1; xc_vp<=g1va[63:12]; xc_pp<=xlate_pa[63:12];
                        state <= pe_run;
                    end
                end
                S_PE_RD0: begin
                    vmem_req<=1; vmem_is_store<=0; vmem_addr<={pe_pp0, g0abs[11:0]};
                    state<=S_PE_RD0W;
                end
                S_PE_RD0W: if (vmem_done) begin
                    g0d<=vmem_rdata;
                    state <= straddle ? S_PE_RD1 : S_PE_LDB;
                end
                S_PE_RD1: begin
                    vmem_req<=1; vmem_is_store<=0; vmem_addr<={pe_pp1, g1va[11:0]};
                    state<=S_PE_RD1W;
                end
                S_PE_RD1W: if (vmem_done) begin g1d<=vmem_rdata; state<=S_PE_LDB; end
                S_PE_LDB: begin                 //  scatter the loaded element into peb
                    state <= S_PE_NEXT;
                end
                S_PE_WR0: begin
                    vmem_req<=1; vmem_is_store<=1; vmem_addr<={pe_pp0, g0abs[11:0]};
                    vmem_wdata<=pe_wd0; vmem_wstrb<=pe_st0;
                    state<=S_PE_WR0W;
                end
                S_PE_WR0W: if (vmem_done) state <= straddle ? S_PE_WR1 : S_PE_NEXT;
                S_PE_WR1: begin
                    vmem_req<=1; vmem_is_store<=1; vmem_addr<={pe_pp1, g1va[11:0]};
                    vmem_wdata<=pe_wd1; vmem_wstrb<=pe_st1;
                    state<=S_PE_WR1W;
                end
                S_PE_WR1W: if (vmem_done) state <= S_PE_NEXT;
                //  ---- advance (field then element); finish ----
                S_PE_NEXT: begin
                    if (pe_f == nf_q - 4'd1) begin
                        pe_f <= 4'd0;
                        if (pe_i == pe_vl - 32'd1) begin
                            if (pe_pass1) begin
                                //  store check-pass done, every address proved
                                //  good: run the real pass (cache stays warm)
                                pe_pass1<=0; pe_i<=pe_vst; state<=S_PE_GO;
                            end
                            else if (st_q) begin done<=1; state<=S_IDLE; end
                            else begin rg<=0; state<=S_PE_WB; end
                        end else begin pe_i <= pe_i + 32'd1; state<=S_PE_GO; end
                    end else begin pe_f <= pe_f + 4'd1; state<=S_PE_GO; end
                end
                //  ---- load writeback: flat bytes -> dest register granules ----
                S_PE_WB: begin
                    vg_we<=1; vg_wd<=rg_reg; vg_wg<=rg_off; vg_wdata<=pe_wbgran;
                    if (rg == pe_nrg-1) begin done<=1; state<=S_IDLE; end
                    else rg<=rg+1;
                end
            endcase
        end
    end
endmodule
