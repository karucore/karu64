//  karu_vrf_bram_wr.v
//  Sequencing adapter: presents the whole-register + granule operand
//  interface to karu_varith / karu_vlsu, backed by the dual-port BRAM VRF
//  (karu_vrf_bram). See doc/architecture.md.
//
//  Contract (the conditions on the global op_stall freeze):
//    * op_stall = varith_active && need_fill, and need_fill is purely
//      address-driven -> it asserts BEFORE karu_varith consumes a newly
//      addressed operand set, never after a subunit-req launch (those pulse
//      after the fill, while op_stall is low).
//    * A write coinciding with op_stall is EDGE-CAPTURED into whold on the
//      op_stall 0->1 edge and committed once (drain); a write with no fill
//      commits directly. cap_pending suppresses the one-cycle direct replay of
//      the frozen producer pulse on the F_IDLE return. So a write never
//      double-fires while varith is frozen.
//
//  WRITES (granule-only): one register granule per g_we pulse, committed to BRAM
//  port A at {g_wd, g_wg} with byte-enable g_wbe (karu_varith merges tail/mask
//  per element via the lanes, so g_wbe is full today; partial g_wbe is the
//  undisturbed-without-RMW path once reads narrow). g_wlast (op's final granule)
//  drives read-cache coherence. The g_we port is shared varith/vlsu (single-
//  issue; muxed in karu64 by write signal).
//
//  READS: per-operand GRANULE latches (vs1_g/vs2_g/vold_g) refilled whenever a
//  requested address changes; varith is stalled meanwhile. v0 is the BRAM flop
//  shadow (combinational, never stalled). vlsu's registered granule read is
//  absorbed by a +1 wait state in karu_vlsu.
//
//  Specialised to VGRAN=2 (VLEN=2*VBUS_W); guarded at elaboration.

`include "karu_vcfg.vh"

module karu_vrf_bram_wr #(
    parameter integer VLEN   = `KARU_VLEN,
    parameter integer VBUS_W = `KARU_VBUS_W
) (
    input  wire                 clk,
    input  wire                 rst,

    //  ---- karu_varith operand read ADDRESSES (granule fills key on these) ----
    input  wire [4:0]           vr_rs,      //  old vd
    input  wire [4:0]           vr_rs2,     //  vs1
    input  wire [4:0]           vr_rs3,     //  vs2
    output wire [VLEN-1:0]      vr_v0,      //  mask (from BRAM flop shadow)

    //  ---- granule source feed ----
    //  vs1_g/vs2_g/vold_g are filled per (address, per-operand granule
    //  index) as the need flags demand; varith stalls (op_stall) until the
    //  requested granules land. Overlap/coherence: ops walk granules
    //  FORWARD, so a granule is always read before any same-op write
    //  reaches it; every fill rewrites all three tags and op-final writes
    //  (direct or drained g_wlast) clear them.
    input  wire                 src_g1,     //  vs1's granule (vr_rs2)
    input  wire                 src_g2,     //  vs2's granule (vr_rs3)
    input  wire                 src_gv,     //  vold's granule (vr_rs)
    input  wire                 src_vs1,
    input  wire                 src_vs2,
    input  wire                 src_vold,
    output wire [VBUS_W-1:0]    vs1_g,
    output wire [VBUS_W-1:0]    vs2_g,
    output wire [VBUS_W-1:0]    vold_g,

    //  ---- granule write/read port (1-bit granule index, VGRAN=2) ----
    //  CANONICAL varith write interface (and the vlsu port): one register granule
    //  per g_we pulse {g_wd, g_wg, g_wdata[VBUS_W-1:0], g_wbe}. Muxed in karu64
    //  between varith (varith_active) and vlsu (vlsu_active) -- single-issue, never
    //  concurrent. g_wlast marks an op's FINAL granule write: only then are
    //  the granule operand tags invalidated (a mid-granule-loop write must
    //  NOT clear them -- in-place vd==vs2 needs the old granule held across
    //  the loop).
    //  vlsu drives g_wlast=1 every write (independent granules) and g_wbe=all-ones.
    input  wire [4:0]           g_rs,
    input  wire                 g_rg,
    output wire [VBUS_W-1:0]    g_rdata,
    input  wire                 g_we,
    input  wire [4:0]           g_wd,
    input  wire                 g_wg,
    input  wire [VBUS_W-1:0]    g_wdata,
    input  wire [VBUS_W/8-1:0]  g_wbe,
    input  wire                 g_wlast,
    //  VRF6 checker qualifiers for the CURRENT granule write (sim-only
    //  consumers; see doc/architecture.md). Driven by karu64's mux:
    //  varith's per-write values, or 0 (exempt) for vlsu writes.
    input  wire                 wb_vlgov,
    input  wire                 wb_mdest,
    input  wire [15:0]          wb_vl,
    input  wire [2:0]           wb_vsew,
    input  wire [4:0]           wb_greg,
    input  wire [15:0]          wb_epr,

    //  ---- context + stall ----
    input  wire                 varith_active,  //  varith_busy
    input  wire                 vlsu_active,    //  vlsu_busy
    output wire                 op_stall        //  freeze karu_varith's FSM
);
    localparam integer NB    = VBUS_W / 8;
    localparam integer VGRAN = VLEN / VBUS_W;
    localparam integer AW    = $clog2(32 * VGRAN);      //  {reg[4:0], gran} = 6 for VGRAN=2

    //  Elaboration guard: the fill/write logic hardcodes 2 granules per reg.
    generate if (VGRAN != 2) begin : g_guard
        ERROR_karu_vrf_bram_wr_requires_VGRAN_eq_2 bad_config();
    end endgenerate

    //  ---- BRAM ports (driven combinationally below) ----
    reg                 a_en, a_we, b_en, b_we;
    reg  [AW-1:0]       a_addr, b_addr;
    reg  [NB-1:0]       a_be, b_be;
    reg  [VBUS_W-1:0]   a_wdata, b_wdata;
    wire [VBUS_W-1:0]   a_rdata, b_rdata;

    karu_vrf_bram #(.VLEN(VLEN), .VBUS_W(VBUS_W)) u_bram (
        .clk(clk), .rst(rst),
        .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_be(a_be), .a_wdata(a_wdata), .a_rdata(a_rdata),
        .b_en(b_en), .b_we(b_we), .b_addr(b_addr), .b_be(b_be), .b_wdata(b_wdata), .b_rdata(b_rdata),
        .v0(vr_v0)
    );
    assign g_rdata = a_rdata;   //  vlsu granule read (registered; +1 wait in karu_vlsu)

    //  ---- granule operand latches + (address, granule) tags ----
    //  Operand cache: one VBUS_W granule per source operand, tagged by source
    //  register and granule index.
    reg  [VBUS_W-1:0]   vs1_gq, vs2_gq, vold_gq;
    reg  [4:0]  g2a, g3a, g1a;
    reg         g2g, g3g, g1g;
    reg         g2v, g3v, g1v;
    wire gn2 = src_vs1 && (!g2v || (g2a != vr_rs2) || (g2g != src_g1));
    wire gn3 = src_vs2 && (!g3v || (g3a != vr_rs3) || (g3g != src_g2));
    wire gn1 = src_vold && (!g1v || (g1a != vr_rs) || (g1g != src_gv));
    wire need_fill = gn2 || gn3 || gn1;
    assign vs1_g = vs1_gq;  assign vs2_g = vs2_gq;  assign vold_g = vold_gq;
    assign op_stall = varith_active && need_fill;
    wire   start_fill = varith_active && need_fill;     //  == op_stall

    //  fill FSM: read vs1/vs2 granules (ports A+B), then vold's granule
    //  when needed. 2-3 cycles per fill.
    localparam F_IDLE=4'd0, F_DRAIN=4'd1, G_RD0=4'd6, G_RD1=4'd7, G_RD2=4'd8;
    reg [3:0]       fs;
    //  edge-captured granule write: held while a
    //  write coincides with a fill, drained in F_DRAIN.
    reg [4:0]       whold_wd;
    reg             whold_wg;       //  captured granule index
    reg             whold_wlast;    //  captured g_wlast (tag-clear on drain)
    reg [NB-1:0]    whold_wbe;      //  captured byte-enable
    reg [VBUS_W-1:0]    whold_wdata;    //  captured granule payload

    //  Replay suppression: a write edge-captured into whold (drain path) leaves
    //  the producer's live pulse FROZEN high through the whole fill (op_stall holds
    //  karu_varith's pulse defaults). On the F_IDLE cycle op_stall drops, that
    //  stale pulse is still high for one clock -> direct_gw/direct_wr would commit
    //  it a SECOND time (and a final g_wlast would re-invalidate the just-refilled
    //  cache). cap_pending masks the direct paths from capture until one unstalled
    //  clock lets the producer clear its pulse. (Honours the "captured once" rule.)
    reg cap_pending;

    //  A granule write commits DIRECTLY when no fill is starting and no captured
    //  write is still being suppressed. vlsu writes always see start_fill=0
    //  (varith inactive) -> immediate, even on the cycle vlsu_busy drops; varith
    //  writes commit direct, or are edge-captured and drained when they coincide
    //  with a fill. One unified path -- no varith/vlsu classification (the caller
    //  mux selects the source by its write signal).
    wire direct_gw = (fs == F_IDLE) && g_we  && !start_fill && !cap_pending;

    //  ---- combinational BRAM port drivers ----
    always @* begin
        a_en=1'b0; a_we=1'b0; a_addr={AW{1'b0}}; a_be={NB{1'b0}}; a_wdata={VBUS_W{1'b0}};
        b_en=1'b0; b_we=1'b0; b_addr={AW{1'b0}}; b_be={NB{1'b0}}; b_wdata={VBUS_W{1'b0}};
        if (direct_gw) begin
            //  direct GRANULE commit (vlsu immediate | varith direct), port A.
            a_en=1'b1; a_we=1'b1; a_addr={g_wd,g_wg}; a_be=g_wbe; a_wdata=g_wdata;
        end else if (vlsu_active) begin
            a_en=1'b1; a_we=1'b0; a_addr={g_rs,g_rg};   //  vlsu granule read
        end else begin
            case (fs)
            F_DRAIN: begin  //  drain the edge-captured granule write (one port)
                a_en=1'b1; a_we=1'b1; a_addr={whold_wd,whold_wg}; a_be=whold_wbe; a_wdata=whold_wdata;
            end
            G_RD0: begin    //  granule fill: vs1 on A, vs2 on B (as consumed)
                if (src_vs1) begin a_en=1'b1; a_addr={vr_rs2,src_g1}; end
                if (src_vs2) begin b_en=1'b1; b_addr={vr_rs3,src_g2}; end
            end
            G_RD1: if (src_vold) begin a_en=1'b1; a_addr={vr_rs,src_gv}; end    //  vold granule
            G_RD2: ;    //  capture only
            default: ;  //  F_IDLE: a direct granule commit is handled by direct_gw above
            endcase
        end
    end

    //  ---- fill / write sequencing ----
    //  cap_pending lifecycle: set when a write is edge-captured into whold; held
    //  through the fill (op_stall high); cleared on the first unstalled clock,
    //  by which time the frozen producer pulse has gone low. Suppresses the
    //  one-cycle direct-commit replay on the F_IDLE return (see direct_gw/_wr).
    always @(posedge clk) begin
        if (rst) cap_pending <= 1'b0;
        else if ((fs==F_IDLE) && start_fill && g_we) cap_pending <= 1'b1;
        else if (!op_stall) cap_pending <= 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            fs<=F_IDLE;
            g2v<=1'b0; g3v<=1'b0; g1v<=1'b0;
        end else begin
            case (fs)
            F_IDLE: begin
                if (start_fill) begin
                    //  edge-capture a granule write coinciding with the stall (frozen
                    //  g_we; start_fill is only ever high under varith). Drained writes
                    //  rely on the FOLLOWING refill for coherence, so no invalidate here.
                    if (g_we) begin
                        whold_wd<=g_wd; whold_wg<=g_wg; whold_wbe<=g_wbe; whold_wdata<=g_wdata;
                        whold_wlast<=g_wlast; end
                    fs <= g_we ? F_DRAIN : G_RD0;
                end else if (direct_gw && g_wlast) begin
                    //  direct commit -> invalidate the granule tags so a later
                    //  op reusing this register refills. ONLY on the op's FINAL
                    //  granule (g_wlast); vlsu drives g_wlast=1 every write,
                    //  while a varith mid-loop write (g_wlast=0) holds the tags
                    //  (in-place vd==vs2 needs the old operand across granules).
                    g2v<=1'b0; g3v<=1'b0; g1v<=1'b0;
                end
            end
            F_DRAIN: begin
                fs <= G_RD0;
                //  a drained op-FINAL write: clear the granule tags (the
                //  following fill then re-reads anything it needs)
                if (whold_wlast) begin g2v<=1'b0; g3v<=1'b0; g1v<=1'b0; end
            end
            G_RD0: fs<=G_RD1;
            G_RD1: begin
                if (src_vs1) vs1_gq<=a_rdata;
                if (src_vs2) vs2_gq<=b_rdata;
                //  rewrite ALL granule tags every fill (no stale survivors)
                g2a<=vr_rs2; g2g<=src_g1; g2v<=src_vs1;
                g3a<=vr_rs3; g3g<=src_g2; g3v<=src_vs2;
                if (src_vold) fs<=G_RD2;
                else begin g1v<=1'b0; fs<=F_IDLE; end
            end
            G_RD2: begin
                vold_gq<=a_rdata;
                g1a<=vr_rs; g1g<=src_gv; g1v<=1'b1;
                fs<=F_IDLE;
            end
            default: fs<=F_IDLE;
            endcase
        end
    end

    //  ---- passive checker on the BRAM ports (SIM ONLY) ----
    //  Count the late/direct write commits in the activity context so VRF4
    //  (access => a unit active) holds on the final-write cycle (varith) and on
    //  the last granule write (vlsu) -- both happen as *_busy drops.
    //  Wrapped in synthesis translate_off: Vivado skips it (the synth read list
    //  excludes *_assert.v, so karu_vrf_assert is absent there) while verilator
    //  keeps it (it does not honour the pragma -- proven by the checker firing).
    //  Activity attribution for VRF4 (access => a unit active) / VRF7 (never both).
    //  A granule direct commit (direct_gw) is varith's only when varith_active is
    //  high (mid-op); a granule write while !varith_active is a vlsu write OR a
    //  varith FINAL write as varith_busy drops -- both attributed to vlsu here so
    //  the two never appear active together (the adapter can't distinguish them,
    //  and either attribution satisfies "access => some unit active").
    wire varith_wr_cyc = (fs == F_DRAIN);
    wire chk_varith = varith_active || varith_wr_cyc;
    wire chk_vlsu   = vlsu_active || (g_we && !varith_active);
// synthesis translate_off
    //  VRF8 (read-cache coherence, granule-tag form): a committed op-final
    //  write (g_wlast) must invalidate ALL the granule operand tags, so the
    //  next op refills from BRAM. The F_DRAIN write-with-fill path is exempt
    //  (its tag-clear + following fill re-read are checked by VRF5b); a
    //  varith mid-loop write (g_wlast=0) deliberately KEEPS the tags.
    reg vrf8_wr_q;
    always @(posedge clk) vrf8_wr_q <= !rst && (direct_gw && g_wlast);
    always @(posedge clk) if (!rst && vrf8_wr_q && (g1v || g2v || g3v)) begin
        $display("[VRF-BRAM-ASSERT] VRF8 write committed but granule tags still valid @%0t", $time);
        $finish;
    end

    //  WGN3 (no replay across op_stall): a write edge-captured into whold and
    //  drained must NOT also commit live on the F_IDLE return cycle. At F_IDLE
    //  with a frozen producer pulse still high and a capture pending, cap_pending
    //  must mask the direct paths, so the only F_IDLE write source is masked ->
    //  a_we must be low. A high a_we here means the suppression failed (replay).
    wire wgn3_risk = (fs==F_IDLE) && !start_fill && cap_pending && g_we;
    always @(posedge clk) if (!rst && wgn3_risk && a_we) begin
        $display("[VRF-BRAM-ASSERT] WGN3 edge-captured write replayed after op_stall @%0t", $time);
        $finish;
    end

    karu_vrf_assert #(.VLEN(VLEN), .VBUS_W(VBUS_W)) u_chk (
        .clk(clk), .rst(rst),
        .varith_active(chk_varith), .vlsu_active(chk_vlsu),
        .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_be(a_be), .a_wdata(a_wdata), .a_rdata(a_rdata),
        .b_en(b_en), .b_we(b_we), .b_addr(b_addr), .b_be(b_be), .b_wdata(b_wdata), .b_rdata(b_rdata),
        .v0(vr_v0),
        .wb_vl_governed(wb_vlgov), .wb_mask_dest(wb_mdest),
        .wb_vl(wb_vl), .wb_vsew(wb_vsew), .wb_group_reg(wb_greg), .wb_epr(wb_epr)
    );
// synthesis translate_on
endmodule
