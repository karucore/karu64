//  karu_assert.sv
//  Architectural invariant / hang-guard checker for karu64.
//
//  This is a *passive* checker: it observes the core's internal state
//  and signaling and flags any violation of the architectural contracts
//  the core is built on. It contains NO instruction-semantics checks
//  (no "ADD computes a+b") -- only structural/protocol invariants on
//  state and handshaking, plus liveness watchdogs ("no op may take
//  longer than N cycles").
//
//  It is attached to the core with a `bind` statement (bottom of this
//  file), so the core RTL (karu64.v) is never modified and the checker
//  is absent from synthesis (flow/syn/ does not read this file). The same
//  boolean predicates are written so they translate directly into SVA
//  `assert property` form for a formal flow later -- see the
//  `KARU_ASSERT_SVA` block at the bottom.
//
//  Build: compiled into the sim builds only (added to HTIF_SRC in the
//  Makefile). Runtime knobs (plusargs):
//      +no_assert        disable the checker entirely
//      +no_assert_stop   report violations but do not $finish
//
//  All invariants are checked on the rising clock edge, sampling the
//  pre-edge (current-cycle) values -- standard assertion sampling.

`include "karu_axi_defs.vh"

module karu_assert #(
    //  Per-FU completion deadline: a multi-cycle unit that stays active
    //  this many cycles without asserting done is treated as hung. The FP
    //  sub-units are multi-cycle pipelines (iterative dividers ~56/58 cyc,
    //  digit-recurrence sqrt ~25/54, multi-stage FMA/add, 2-cycle conversions),
    //  and the integer divider is bit-serial (KARU_M_DIV_CYCLES up to 64) -- so
    //  the slowest legitimate scalar op is ~60-64 cycles, leaving the 1000-cycle
    //  default a wide margin. (This watches the top-level fpu_active duration,
    //  which spans whichever sub-unit the FPU dispatched; INV5h checks that it
    //  dispatched only one.)
    parameter integer STALL_LIMIT  = 1000,
    //  The vector unit's bit-serial divide (KARU_V_DIV_CYCLES>1) is the one
    //  legitimately long op: up to VLMAX elements * ~66 cycles (e8/LMUL8 =
    //  256*66 ~ 17k). Give varith its own generous deadline.
    parameter integer VARITH_STALL_LIMIT = 40000,
    //  The VLSU per-element engine (strided/indexed/segment) is likewise
    //  legitimately long: it walks up to VLMAX elements * nf fields, each a
    //  1-or-2-granule memory access, after buffering the index + data groups.
    //  A large e8 indexed / indexed-segment op is thousands of cycles, well
    //  over the 1000-cycle shared STALL_LIMIT, so give the VLSU its own bound.
    parameter integer VLSU_STALL_LIMIT = 40000,
    //  The vector-FP unit walks up to VLMAX elements through the scalar FP
    //  datapath (each a multi-cycle add/mul/div/sqrt), so a large op runs to
    //  many thousands of cycles -- it too needs a generous deadline.
    parameter integer VFPU_STALL_LIMIT = 200000,
    //  Fetch deadline: IFU not presenting a valid instruction for this
    //  many consecutive cycles => fetch hang (imem never responding,
    //  redirect drain stuck, ...).
    parameter integer FETCH_LIMIT  = 1000,
    //  Global progress deadline: no forward progress (no issue, no FU in
    //  flight) for this many cycles => livelock. Generous, because a
    //  legitimate spin loop still issues its branch every iteration.
    parameter integer RETIRE_LIMIT = 4000,
    //  1 => $finish on the first violation; 0 => count and continue.
    parameter integer STOP_ON_FAIL = 1,
    //  1 => also check AXI master VALID-stability (payload held until
    //  READY). 0 => skip the AXI signaling checks.
    parameter integer CHECK_AXI    = 1
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         trap,

    //  ---- issue / FU-active state ----
    input  wire         issuing,
    input  wire         lsu_active,
    input  wire         m_active,
    input  wire         fpu_active,
    input  wire         vlsu_active,
    input  wire         varith_active,
    input  wire         vfpu_active,
    input  wire         vkeccak_active,

    //  ---- multi-cycle handshakes ----
    input  wire         lsu_req,
    input  wire         lsu_done,
    input  wire         m_req,
    input  wire         m_done,
    input  wire         fpu_req,
    input  wire         fpu_done,
    input  wire [9:0]   fpu_sub_req,    //  per-op dispatch strobes to the FP sub-units
    input  wire         vlsu_req,
    input  wire         vlsu_done,
    input  wire         varith_req,
    input  wire         varith_done,
    input  wire         vfpu_req,
    input  wire         vfpu_done,
    input  wire         vfp_lane_active,    //  any in-lane FP unit active
    input  wire         vfp_req_busy,       //  a lane FP req issued to an already-busy lane (must be 0)
    input  wire         lane_warm_bad,      //  KARU_V_LANE_PIPE warm-cycle leaked outside is_grp S_RUN (must be 0)
    input  wire         vkeccak_req,
    input  wire         vkeccak_done,

    //  ---- writeback ----
    input  wire         wb_we,
    input  wire [4:0]   wb_rd,
    input  wire         fwb_we,

    //  ---- vector writeback + fixed-point flag ----
    input  wire         varith_g_we,    //  varith VRF granule write
    input  wire         vg_we,          //  granule VRF write (vlsu load)
    input  wire         vxsat_set,      //  fixed-point saturation sticky-set (varith)

    //  ---- vector memory master port (vlsu -> karu_mem, 16-byte granule) ----
    input  wire         vmem_req,       //  vector memory transaction request
    input  wire         vmem_is_store,  //  1 = store, 0 = load (reporting)
    input  wire [63:0]  vmem_addr,      //  granule address (must be 16-byte aligned; 64-bit VA since V1)

    //  ---- front-end ----
    input  wire         ifu_valid,
    input  wire [63:0]  ifu_pc,         //  64-bit PC (ecp5 rebase widened for Sv39)
    input  wire         ifu_redir,
    input  wire [63:0]  ifu_redir_pc,
    input  wire         perf_retire,

    //  ---- Sv39 translator ownership ----
    input  wire         i_mmu_busy,
    input  wire         i_mmu_req,
    input  wire         d_mmu_busy,
    input  wire         d_mmu_req,

    //  ---- AXI master request channels (for VALID-stability) ----
    input  wire         imem_arvalid,
    input  wire         imem_arready,
    input  wire [31:0]  imem_araddr,
    input  wire [`AXI_ID_W-1:0] imem_arid,
    input  wire [`AXI_LEN_W-1:0]    imem_arlen,
    input  wire [`AXI_SIZE_W-1:0]   imem_arsize,
    input  wire [`AXI_BURST_W-1:0]  imem_arburst,
    input  wire [`AXI_PROT_W-1:0]   imem_arprot,
    input  wire         dmem_arvalid,
    input  wire         dmem_arready,
    input  wire [31:0]  dmem_araddr,
    input  wire [`AXI_ID_W-1:0] dmem_arid,
    input  wire [`AXI_LEN_W-1:0]    dmem_arlen,
    input  wire [`AXI_SIZE_W-1:0]   dmem_arsize,
    input  wire [`AXI_BURST_W-1:0]  dmem_arburst,
    input  wire [`AXI_PROT_W-1:0]   dmem_arprot,
    input  wire         dmem_awvalid,
    input  wire         dmem_awready,
    input  wire [31:0]  dmem_awaddr,
    input  wire [`AXI_ID_W-1:0] dmem_awid,
    input  wire [`AXI_LEN_W-1:0]    dmem_awlen,
    input  wire [`AXI_SIZE_W-1:0]   dmem_awsize,
    input  wire [`AXI_BURST_W-1:0]  dmem_awburst,
    input  wire [`AXI_PROT_W-1:0]   dmem_awprot,
    input  wire         dmem_wvalid,
    input  wire         dmem_wready,
    input  wire [63:0]  dmem_wdata,
    input  wire [7:0]   dmem_wstrb,
    input  wire         dmem_wlast,

    //  ==== RVA23 semantic contracts (Supm / CBO / TVM-TW-TSR / Zfa) ====
    //  ---- Supm pointer masking ----
    input  wire [5:0]   csr_dpmlen,     //  current data-access PMLEN (0/7/16)
    input  wire [63:0]  lsu_addr,       //  masked scalar data effective address
    input  wire [63:0]  vlsu_base_pm,   //  masked vector base (0 when V disabled)
    //  ---- Zicbom/Zicboz ----
    input  wire         cbo_ill,        //  CBO disallowed by priv+envcfg -> illegal
    input  wire         lsu_is_cbo,     //  the in-flight LSU op is any cbo.*
    input  wire         lsu_is_cboz,    //  ... specifically cbo.zero
    input  wire         lsu_is_cbocf,   //  ... cbo.clean/flush
    input  wire         lsu_is_cboinval,//  ... cbo.inval
    input  wire         lsu_awvalid,    //  scalar LSU's own AW/W (not the dmmu PTW)
    input  wire         lsu_wvalid,
    input  wire [7:0]   lsu_wstrb,
    input  wire [63:0]  lsu_wdata_o,
    input  wire [31:0]  lsu_awaddr,
    //  ---- mstatus TVM/TW/TSR + privileged-illegal trap ----
    input  wire         sret_ill,       //  sret gated (U, or S+TSR)
    input  wire         sfence_ill,     //  sfence.vma gated (U, or S+TVM)
    input  wire         mret_ill,       //  mret below M
    input  wire         sys_priv_ill,   //  any privileged-illegal (incl wfi+TW)
    input  wire         sys_sret,       //  gated sret EFFECT (must be 0 when sret_ill)
    input  wire         sys_mret,       //  gated mret EFFECT
    input  wire         sys_sfencevma,  //  gated sfence.vma EFFECT
    input  wire         trap_req,
    input  wire [63:0]  trap_cause,
    //  ---- Zfa side-path routing ----
    input  wire [3:0]   ex_fp_zfa,      //  FPZ_* of the in-flight FP op
    input  wire [4:0]   ex_rd,          //  dest reg of the in-flight op (Zfa positive routing)

    //  ---- stronger CBO: beat counter + translated-first ----
    //  (reuses the existing lsu_req / lsu_awvalid ports for issue / AW)
    input  wire         lsu_xlate_active,   //  the LSU op is in its translation phase
    input  wire         lsu_bare,           //  bare-mode op (skips translation, PA=VA)
    input  wire         lsu_awready,        //  scalar LSU AW channel ready

    //  ---- Supm on the ACTUAL translation inputs ----
    input  wire         dmmu_req_lsu,   //  this DMMU request is the scalar LSU's
    input  wire [63:0]  dmmu_va,        //  the VA actually fed to the DMMU
    input  wire [63:0]  dmmu_va_exp,    //  expected scalar DMMU VA (walk-1 EA / walk-2 beat-2 VA)
    input  wire [63:0]  vlsu_base_q,    //  the base the VLSU latched (must be masked)

    //  ---- independent gating recompute (don't trust the *_ill / *_en wires) ----
    input  wire [1:0]   csr_priv,       //  0=U,1=S,3=M
    input  wire         menvcfg_cbze, menvcfg_cbcfe,    input wire [1:0] menvcfg_cbie,
    input  wire         senvcfg_cbze, senvcfg_cbcfe,    input wire [1:0] senvcfg_cbie,
    input  wire         cbo_zero_en, cbo_cf_en, cbo_inval_en,   //  csr's computed enables
    input  wire         csr_tvm, csr_tw, csr_tsr,
    input  wire         sys_sret_raw, sys_sfence_raw, sys_wfi_raw,

    //  ---- satp-TVM + counteren CSR gating as invariants ----
    input  wire         csr_op_req,
    input  wire [11:0]  csr_op_addr,
    input  wire         csr_illegal,
    input  wire [31:0]  csr_mcounteren,
    input  wire [31:0]  csr_scounteren
);
    integer fails   = 0;
    reg     enabled = 1'b1;
    reg     do_stop = 1'b1;
    reg [63:0] k_cyc  = 64'b0;

    //  NB: $test$plusargs does PREFIX matching, so "+no_assert_stop" also matches
    //  the "no_assert" query. Disambiguate (mirrors karu_vrf_assert) so
    //  "+no_assert_stop" means report-but-continue (checker stays ENABLED), and
    //  only a bare "+no_assert" fully disables. (If both given, report-continue.)
    reg na, nss;
    initial begin
        nss = $test$plusargs("no_assert_stop");
        na  = $test$plusargs("no_assert");
        if (nss)        do_stop = 1'b0;     //  report, do not $finish
        if (na && !nss) enabled = 1'b0;     //  bare +no_assert -> fully off
    end

    //  ---- watchdog counters ----
    reg [31:0] lsu_cnt, m_cnt, fpu_cnt, vlsu_cnt, varith_cnt, vfpu_cnt, vkeccak_cnt, fetch_cnt, ret_cnt;
    always @(posedge clk) begin
        if (rst) begin
            lsu_cnt    <= 0;
            m_cnt      <= 0;
            fpu_cnt    <= 0;
            vlsu_cnt   <= 0;
            varith_cnt <= 0;
            vfpu_cnt   <= 0;
            vkeccak_cnt <= 0;
            fetch_cnt  <= 0;
            ret_cnt    <= 0;
        end else begin
            //  A unit that is active without completing this cycle is
            //  one cycle closer to its deadline; reset on done/idle.
            lsu_cnt    <= (lsu_active    && !lsu_done)    ? lsu_cnt    + 1 : 0;
            m_cnt      <= (m_active      && !m_done)      ? m_cnt      + 1 : 0;
            fpu_cnt    <= (fpu_active    && !fpu_done)    ? fpu_cnt    + 1 : 0;
            vlsu_cnt   <= (vlsu_active   && !vlsu_done)   ? vlsu_cnt   + 1 : 0;
            varith_cnt <= (varith_active && !varith_done) ? varith_cnt + 1 : 0;
            vfpu_cnt   <= (vfpu_active   && !vfpu_done)   ? vfpu_cnt   + 1 : 0;
            vkeccak_cnt <= (vkeccak_active && !vkeccak_done) ? vkeccak_cnt + 1 : 0;
            fetch_cnt <= ifu_valid                 ? 0 : fetch_cnt + 1;
            //  Forward progress = an instruction issued this cycle, or a
            //  multi-cycle FU is in flight. NOT `perf_retire`: that only
            //  pulses on register writeback (rd!=0), so a long run of
            //  non-writeback ops -- e.g. the multi-thousand-NOP sleds the
            //  arch-test JAL/branch immediate-edge tests use -- would look
            //  like a livelock even though the core is advancing fine.
            ret_cnt   <= (issuing || lsu_active || m_active || fpu_active || vlsu_active || varith_active || vfpu_active || vkeccak_active)
                            ? 0 : ret_cnt + 1;
        end
    end

    //  ---- one-cycle-delayed copies for AXI stability checks ----
    reg         p_imem_arvalid, p_imem_arready;
    reg [31:0]  p_imem_araddr;
    reg [`AXI_ID_W-1:0] p_imem_arid;
    reg [`AXI_LEN_W-1:0]    p_imem_arlen;
    reg [`AXI_SIZE_W-1:0]   p_imem_arsize;
    reg [`AXI_BURST_W-1:0]  p_imem_arburst;
    reg [`AXI_PROT_W-1:0]   p_imem_arprot;
    reg         p_dmem_arvalid, p_dmem_arready;
    reg [31:0]  p_dmem_araddr;
    reg [`AXI_ID_W-1:0] p_dmem_arid;
    reg [`AXI_LEN_W-1:0]    p_dmem_arlen;
    reg [`AXI_SIZE_W-1:0]   p_dmem_arsize;
    reg [`AXI_BURST_W-1:0]  p_dmem_arburst;
    reg [`AXI_PROT_W-1:0]   p_dmem_arprot;
    reg         p_dmem_awvalid, p_dmem_awready;
    reg [31:0]  p_dmem_awaddr;
    reg [`AXI_ID_W-1:0] p_dmem_awid;
    reg [`AXI_LEN_W-1:0]    p_dmem_awlen;
    reg [`AXI_SIZE_W-1:0]   p_dmem_awsize;
    reg [`AXI_BURST_W-1:0]  p_dmem_awburst;
    reg [`AXI_PROT_W-1:0]   p_dmem_awprot;
    reg         p_dmem_wvalid, p_dmem_wready;
    reg [63:0]  p_dmem_wdata;
    reg [7:0]   p_dmem_wstrb;
    reg         p_dmem_wlast;
    always @(posedge clk) begin
        p_imem_arvalid <= imem_arvalid; p_imem_arready <= imem_arready;
        p_imem_araddr  <= imem_araddr;
        p_imem_arid    <= imem_arid;
        p_imem_arlen   <= imem_arlen;
        p_imem_arsize  <= imem_arsize;
        p_imem_arburst <= imem_arburst;
        p_imem_arprot  <= imem_arprot;
        p_dmem_arvalid <= dmem_arvalid; p_dmem_arready <= dmem_arready;
        p_dmem_araddr  <= dmem_araddr;
        p_dmem_arid    <= dmem_arid;
        p_dmem_arlen   <= dmem_arlen;
        p_dmem_arsize  <= dmem_arsize;
        p_dmem_arburst <= dmem_arburst;
        p_dmem_arprot  <= dmem_arprot;
        p_dmem_awvalid <= dmem_awvalid; p_dmem_awready <= dmem_awready;
        p_dmem_awaddr  <= dmem_awaddr;
        p_dmem_awid    <= dmem_awid;
        p_dmem_awlen   <= dmem_awlen;
        p_dmem_awsize  <= dmem_awsize;
        p_dmem_awburst <= dmem_awburst;
        p_dmem_awprot  <= dmem_awprot;
        p_dmem_wvalid  <= dmem_wvalid;  p_dmem_wready  <= dmem_wready;
        p_dmem_wdata   <= dmem_wdata;
        p_dmem_wstrb   <= dmem_wstrb;
        p_dmem_wlast   <= dmem_wlast;
    end

    //  CBO op tracker state (the checks live in the main block, below the KCHK
    //  macro definition).
    reg         cbo_track, cbo_track_zero, cbo_xlated, cbo_first, cbo_bare_q;
    reg [4:0]   cbo_beats;
    reg [31:0]  cbo_prev_addr;

    //  A hang is never something to keep simulating through.
    task k_hang;
        input [8*64-1:0] tag;
        begin
            if (enabled && !rst) begin
                $display("[KARU-ASSERT] HANG cyc=%0d t=%0t pc=%08h: %0s",
                    k_cyc, $time, ifu_pc, tag);
                $display("[KARU-ASSERT]   active: lsu=%b m=%b fpu=%b vlsu=%b varith=%b vfpu=%b  ifu_valid=%b",
                    lsu_active, m_active, fpu_active, vlsu_active, varith_active, vfpu_active, ifu_valid);
                $finish;
            end
        end
    endtask

    //  Uniform reporting + optional stop. Uses a blocking increment so a
    //  cycle with several simultaneous violations counts them all.
    `define KCHK(cond, tag) \
        if (enabled && !rst && !(cond)) begin \
            fails = fails + 1; \
            $display("[KARU-ASSERT] FAIL cyc=%0d t=%0t pc=%08h: %s", \
                k_cyc, $time, ifu_pc, tag); \
            if (do_stop && STOP_ON_FAIL) begin \
                $display("[KARU-ASSERT] %0d failure(s); stopping.", fails); \
                $finish; \
            end \
        end

    always @(posedge clk) begin
        k_cyc <= k_cyc + 64'b1;

        //  ==============================================================
        //  State invariants
        //  ==============================================================
        //  Single-issue, in-order: at most one multi-cycle FU in flight
        //  (includes the vector units vlsu/varith).
        `KCHK(({3'b0, lsu_active} + {3'b0, m_active} + {3'b0, fpu_active}
             + {3'b0, vlsu_active} + {3'b0, varith_active} + {3'b0, vfpu_active}
             + {3'b0, vkeccak_active}) <= 4'd1,
              "INV1 single-issue: >1 FU active simultaneously")

        //  No new request may be launched while any FU is in flight
        //  (issue is gated on all *_active being low).
        `KCHK(!((lsu_active || m_active || fpu_active || vlsu_active || varith_active || vfpu_active || vkeccak_active) &&
                (lsu_req    || m_req    || fpu_req    || vlsu_req    || varith_req    || vfpu_req    || vkeccak_req)),
              "INV2 req asserted while an FU is busy")

        //  A request only fires when its own unit is idle.
        `KCHK(!(lsu_req    && lsu_active),    "INV3 lsu_req while lsu_active")
        `KCHK(!(m_req      && m_active),      "INV4 m_req while m_active")
        `KCHK(!(fpu_req    && fpu_active),    "INV5 fpu_req while fpu_active")
        //  The FPU is single-issue internally: it launches at most one of its
        //  multi-cycle sub-units (fmul/fadd/fdiv/fsqrt/ffma, F and D) per op,
        //  so at most one dispatch strobe is high per cycle.
        `KCHK(((fpu_sub_req & (fpu_sub_req - 10'b1)) == 10'b0),
              "INV5h >1 FP sub-unit dispatched in one cycle")
        `KCHK(!(vlsu_req   && vlsu_active),   "INV5d vlsu_req while vlsu_active")
        `KCHK(!(varith_req && varith_active), "INV5e varith_req while varith_active")
        `KCHK(!(vfpu_req   && vfpu_active),   "INV5f vfpu_req while vfpu_active")   //  vfpu_* tied 0
        `KCHK(!(vkeccak_req && vkeccak_active), "INV5g vkeccak_req while vkeccak_active")
        //  Vector-FP units live inside karu_varith and run across NLANES lane
        //  FPUs. They are sub-FU (so INV1's single-issue is not violated by
        //  simultaneous lane fires), but they must only be active as part of an
        //  in-flight vector op: any lane FP activity implies varith_active.
        `KCHK(!(vfp_lane_active && !varith_active),
              "INV5j lane FP unit active outside varith_active")
        //  Per-lane FP handshake well-formedness: the vector FSM must never issue
        //  a lane FP `req` to a lane that is still busy with a prior element. Today
        //  the FSM is batch-and-wait (it waits for every dispatched lane's `done`
        //  before re-issuing), so this holds by construction; it is the guard that
        //  would fire first if a future pipelined-issue / streaming FSM fed a busy
        //  lane and silently dropped an element. (Mirrors INV2-INV5 at the lane.)
        `KCHK(!vfp_req_busy,
              "INV19 lane FP req issued to an already-busy lane")

        //  KARU_V_LANE_PIPE warm-cycle handshake. The 2-stage lane spends one
        //  extra (held) S_RUN cycle (lane_warm=1) so stage-1 captures the operands
        //  before stage-2's result is sampled into S_GWB. lane_warm must be high
        //  ONLY inside the is_grp granule loop in S_RUN; a stale set surviving into
        //  S_IDLE / S_GWB / a non-grp op would make the next group op skip its warm
        //  cycle and sample stage-2 before stage-1 captured -> wrong result. Tied
        //  to 0 when the pipe is compiled out, so this never fires there.
        `KCHK(!lane_warm_bad,
              "INV19b lane warm-cycle leaked outside the is_grp S_RUN path")

        //  A done pulse only occurs while that unit is active (units are
        //  idle out of reset and only run after an accepted request).
        `KCHK(!(lsu_done    && !lsu_active),    "INV6a lsu_done while !lsu_active")
        `KCHK(!(m_done      && !m_active),      "INV6b m_done while !m_active")
        `KCHK(!(fpu_done    && !fpu_active),    "INV6c fpu_done while !fpu_active")
        `KCHK(!(vlsu_done   && !vlsu_active),   "INV6d vlsu_done while !vlsu_active")
        `KCHK(!(varith_done && !varith_active), "INV6e varith_done while !varith_active")
        `KCHK(!(vfpu_done   && !vfpu_active),   "INV6f vfpu_done while !vfpu_active")
        `KCHK(!(vkeccak_done && !vkeccak_active), "INV6g vkeccak_done while !vkeccak_active")

        //  ==============================================================
        //  Writeback invariants
        //  ==============================================================
        //  x0 is hardwired zero: never commit a write to x0.
        `KCHK(!(wb_we && wb_rd == 5'd0), "INV7 integer writeback to x0")

        //  Single-issue => the integer and FP regfiles are never both
        //  written in the same cycle.
        `KCHK(!(wb_we && fwb_we), "INV8 x and f regfile written same cycle")

        //  ==============================================================
        //  Vector regfile / fixed-point invariants
        //  ==============================================================
        //  The VRF granule write has two mutually-exclusive sources (single-
        //  issue): varith (`varith_g_we`, incl. its multi-cycle widen/narrow/
        //  serial-mul/divide write phases) and vlsu loads (`vg_we`). Each only
        //  fires while its owner is in flight.
        `KCHK(!(vg_we  && !vlsu_active),   "INV12 VRF granule write while !vlsu_active")
        //  Single-issue => the two granule sources never fire together (the gw_*
        //  priority mux would otherwise drop the vlsu write).
        `KCHK(!(varith_g_we && vg_we), "INV13 both granule write sources same cycle")
        //  A vector op commits exactly one destination class: the vector
        //  regfile, or a scalar (x via vmv.x.s/vfirst/vcpop), never both.
        `KCHK(!(varith_g_we && wb_we),  "INV14 vector and integer regfile written same cycle")
        `KCHK(!(varith_g_we && fwb_we), "INV15 vector and FP regfile written same cycle")
        //  The fixed-point saturation flag (vxsat) is sticky-set only on a
        //  varith completion -- a mid-op element saturation must not leak
        //  into the architectural CSR before the op retires.
        `KCHK(!(vxsat_set && !varith_done), "INV16 vxsat_set without varith_done")

        //  ==============================================================
        //  Vector memory master port (vlsu -> karu_mem)
        //  ==============================================================
        //  The vector memory port is driven ONLY by the vlsu, and only while
        //  it is the active FU (nothing else owns this master).
        `KCHK(!(vmem_req && !vlsu_active), "INV17 vmem_req while !vlsu_active")
        //  The port is a 16-byte granule interface: every transaction address
        //  is granule-aligned. Both the contiguous path (base_al + mg*16) and
        //  the per-element engine (g0abs = eaddr & ~15, and +16 for the
        //  boundary-straddle beat) issue 16-aligned addresses -- a straddle/
        //  address bug that emitted a misaligned granule is caught here.
        `KCHK(!(vmem_req && (vmem_addr[3:0] != 4'b0)),
              "INV18 vmem granule address not 16-byte aligned")

        //  ==============================================================
        //  Front-end invariants
        //  ==============================================================
        //  RVC => instructions are 2-byte aligned; PC bit 0 is always 0.
        `KCHK(!(ifu_valid && ifu_pc[0]), "INV9 fetched PC not 2-byte aligned")
        `KCHK(!(ifu_redir && ifu_redir_pc[0]),
              "INV10 redirect target not 2-byte aligned")

        //  karu_sv39 samples req only while idle; a request while busy is
        //  dropped and may later alias an old translation completion.
        `KCHK(!(i_mmu_req && i_mmu_busy), "SV39I req while busy")
        `KCHK(!(d_mmu_req && d_mmu_busy), "SV39D req while busy")

        //  ==============================================================
        //  AXI master VALID-stability (signaling contract)
        //  Once VALID is asserted it must stay, with stable payload,
        //  until the corresponding READY is seen.
        //  ==============================================================
        if (CHECK_AXI != 0) begin
            `KCHK(!(p_imem_arvalid && !p_imem_arready &&
                    !(imem_arvalid && imem_arid == p_imem_arid &&
                      imem_araddr == p_imem_araddr && imem_arlen == p_imem_arlen &&
                      imem_arsize == p_imem_arsize && imem_arburst == p_imem_arburst &&
                      imem_arprot == p_imem_arprot)),
                  "AXI imem AR dropped/changed before ARREADY")
            `KCHK(!(p_dmem_arvalid && !p_dmem_arready &&
                    !(dmem_arvalid && dmem_arid == p_dmem_arid &&
                      dmem_araddr == p_dmem_araddr && dmem_arlen == p_dmem_arlen &&
                      dmem_arsize == p_dmem_arsize && dmem_arburst == p_dmem_arburst &&
                      dmem_arprot == p_dmem_arprot)),
                  "AXI dmem AR dropped/changed before ARREADY")
            `KCHK(!(p_dmem_awvalid && !p_dmem_awready &&
                    !(dmem_awvalid && dmem_awid == p_dmem_awid &&
                      dmem_awaddr == p_dmem_awaddr && dmem_awlen == p_dmem_awlen &&
                      dmem_awsize == p_dmem_awsize && dmem_awburst == p_dmem_awburst &&
                      dmem_awprot == p_dmem_awprot)),
                  "AXI dmem AW dropped/changed before AWREADY")
            `KCHK(!(p_dmem_wvalid && !p_dmem_wready &&
                    !(dmem_wvalid && dmem_wdata == p_dmem_wdata &&
                      dmem_wstrb == p_dmem_wstrb && dmem_wlast == p_dmem_wlast)),
                  "AXI dmem W dropped/changed before WREADY")
        end

        //  ==============================================================
        //  Supm pointer masking (data addresses canonicalised, fetch not)
        //  ==============================================================
        //  INV20: when PMLEN>0 the scalar data effective address must be
        //  canonical in its top PMLEN bits (= sign-extension of bit XLEN-1-PMLEN);
        //  this is the transform the masking wire is supposed to apply. (Fetch
        //  has no PM wire in its path, so it is structurally never masked.)
        `KCHK((csr_dpmlen != 6'd16) || (lsu_addr[63:48] == {16{lsu_addr[47]}}),
              "INV20a scalar data VA not PM-canonical (PMLEN16)")
        `KCHK((csr_dpmlen != 6'd7)  || (lsu_addr[63:57] == {7{lsu_addr[56]}}),
              "INV20b scalar data VA not PM-canonical (PMLEN7)")
        //  INV21: same for the vector (VLSU) base.
        `KCHK((csr_dpmlen != 6'd16) || (vlsu_base_pm[63:48] == {16{vlsu_base_pm[47]}}),
              "INV21a vector base not PM-canonical (PMLEN16)")
        `KCHK((csr_dpmlen != 6'd7)  || (vlsu_base_pm[63:57] == {7{vlsu_base_pm[56]}}),
              "INV21b vector base not PM-canonical (PMLEN7)")

        //  ==============================================================
        //  Zicbom/Zicboz contracts
        //  ==============================================================
        //  INV22: a CBO disallowed by privilege/envcfg must NOT issue to the LSU
        //  (it traps before any translation / memory effect).
        `KCHK(!(cbo_ill && lsu_req), "INV22 disallowed CBO reached the LSU")
        //  INV23: every cbo.zero write beat is a full 8-byte zero store to an
        //  8-byte-aligned address (the 64-byte block is written as 8x FF-strobe 0s).
        `KCHK(!(lsu_active && lsu_is_cboz && lsu_wvalid)
              || (lsu_wstrb == 8'hFF && lsu_wdata_o == 64'b0 && lsu_awaddr[2:0] == 3'b0),
              "INV23 cbo.zero beat not a full aligned zero store")
        //  INV24: cbo.clean/flush/inval (cbo && !zero) translate but emit no LSU
        //  write of their own (data effect is a NOP on the write-through L1).
        `KCHK(!(lsu_active && lsu_is_cbo && !lsu_is_cboz)
              || (!lsu_awvalid && !lsu_wvalid),
              "INV24 cbo.clean/flush/inval emitted an LSU write")

        //  ==============================================================
        //  mstatus TVM/TW/TSR + privileged-illegal trap
        //  ==============================================================
        //  INV25: a gated privileged op must not perform its architectural
        //  effect (the effect is the AND of raw && !illegal).
        `KCHK(!(sret_ill   && sys_sret),      "INV25a sret effect despite TSR/U gating")
        `KCHK(!(sfence_ill && sys_sfencevma), "INV25b sfence.vma effect despite TVM/U gating")
        `KCHK(!(mret_ill   && sys_mret),      "INV25c mret effect from below M")
        //  INV26: every privileged-illegal (sret/sfence/wfi/mret) AND every
        //  disallowed CBO vectors as an illegal-instruction (cause 2) trap.
        `KCHK(!(sys_priv_ill || cbo_ill) || (trap_req && trap_cause == 64'd2),
              "INV26 privileged/CBO illegal did not raise cause-2")

        //  ==============================================================
        //  Zfa side-path routing (FPZ_FCVTMOD=7 writes X; FPZ_FLI=8 writes F)
        //  ==============================================================
        `KCHK(!(fpu_done && ex_fp_zfa == 4'd7) || !fwb_we,
              "INV27 fcvtmod.w.d wrote the FP regfile (must write integer)")
        `KCHK(!(fpu_done && ex_fp_zfa == 4'd8) || !wb_we,
              "INV28 fli wrote the integer regfile (must write FP)")
        //  INV27b/INV28b positive routing: fcvtmod with a non-x0 dest MUST write
        //  the integer regfile; fli MUST write the FP regfile.
        `KCHK(!(fpu_done && ex_fp_zfa == 4'd7 && ex_rd != 5'd0) || wb_we,
              "INV27b fcvtmod.w.d (rd!=x0) did not write the integer regfile")
        `KCHK(!(fpu_done && ex_fp_zfa == 4'd8) || fwb_we,
              "INV28b fli did not write the FP regfile")

        //  ==============================================================
        //  Supm: the ACTUAL translation inputs (not just the helper wires)
        //  ==============================================================
        //  INV29: every scalar-LSU translation request feeds the expected masked
        //  VA -- the masked EA for the beat-1 walk, or the latched beat-2 VA for
        //  the second (cross-page) walk (catches a DMMU mux that translates the
        //  raw VA, or a beat-2 walk fed the wrong VA).
        `KCHK(!dmmu_req_lsu || (dmmu_va == dmmu_va_exp),
              "INV29 DMMU scalar VA != expected (masked EA / beat-2 VA)")
        //  INV30: the base the VLSU latched is PM-canonical (catches a re-wire of
        //  the VLSU base back to the raw register value). Only meaningful while a
        //  VLSU op is in flight -- base_q is otherwise stale (latched under an
        //  earlier priv/PMM), so gate on vlsu_active.
        `KCHK(!vlsu_active || (csr_dpmlen != 6'd16) || (vlsu_base_q[63:48] == {16{vlsu_base_q[47]}}),
              "INV30a VLSU latched base not PM-canonical (PMLEN16)")
        `KCHK(!vlsu_active || (csr_dpmlen != 6'd7)  || (vlsu_base_q[63:57] == {7{vlsu_base_q[56]}}),
              "INV30b VLSU latched base not PM-canonical (PMLEN7)")

        //  ==============================================================
        //  Independent recompute of the gating (priv + envcfg / mstatus)
        //  ==============================================================
        //  INV31: the csr's per-class CBO enables match a first-principles
        //  recompute from priv + menvcfg/senvcfg (catches a wrong-bit / wrong-
        //  privilege regression in karu_csr).
        `KCHK(cbo_zero_en  == ((csr_priv == 2'd3)
                            || (csr_priv == 2'd1 && menvcfg_cbze)
                            || (csr_priv == 2'd0 && menvcfg_cbze && senvcfg_cbze)),
              "INV31a cbo_zero_en disagrees with priv+envcfg recompute")
        `KCHK(cbo_cf_en    == ((csr_priv == 2'd3)
                            || (csr_priv == 2'd1 && menvcfg_cbcfe)
                            || (csr_priv == 2'd0 && menvcfg_cbcfe && senvcfg_cbcfe)),
              "INV31b cbo_cf_en disagrees with priv+envcfg recompute")
        `KCHK(cbo_inval_en == ((csr_priv == 2'd3)
                            || (csr_priv == 2'd1 && (menvcfg_cbie != 2'b00))
                            || (csr_priv == 2'd0 && (menvcfg_cbie != 2'b00) && (senvcfg_cbie != 2'b00))),
              "INV31c cbo_inval_en disagrees with priv+envcfg recompute")
        //  INV31d: end-to-end mapping -- a CBO that actually ISSUES to the LSU
        //  (cbo_ill did not block it) must have its OWN class enabled. Catches a
        //  wrong cbo_ill expression that pairs a class with the wrong enable.
        `KCHK(!(lsu_req && lsu_is_cboz)     || cbo_zero_en,
              "INV31d cbo.zero issued while its class is disabled")
        `KCHK(!(lsu_req && lsu_is_cbocf)    || cbo_cf_en,
              "INV31e cbo.clean/flush issued while its class is disabled")
        `KCHK(!(lsu_req && lsu_is_cboinval) || cbo_inval_en,
              "INV31f cbo.inval issued while its class is disabled")
        //  INV32: the sret/sfence illegal wires match a recompute from priv +
        //  mstatus.TVM/TSR (independent of karu64's expression).
        `KCHK(sret_ill   == (sys_sret_raw   && ((csr_priv == 2'd0) || (csr_priv == 2'd1 && csr_tsr))),
              "INV32a sret_ill disagrees with priv+TSR recompute")
        `KCHK(sfence_ill == (sys_sfence_raw && ((csr_priv == 2'd0) || (csr_priv == 2'd1 && csr_tvm))),
              "INV32b sfence_ill disagrees with priv+TVM recompute")
        //  INV33: a wfi that should trap (below M with TW) is reflected in
        //  sys_priv_ill.
        `KCHK(!(sys_wfi_raw && (csr_priv != 2'd3) && csr_tw) || sys_priv_ill,
              "INV33 wfi-below-M-with-TW not flagged privileged-illegal")

        //  ==============================================================
        //  CSR gating as invariants (satp-TVM, Zihpm/Zicntr counteren)
        //  ==============================================================
        //  INV34: an S-mode satp access with TVM must be illegal.
        `KCHK(!(csr_op_req && csr_op_addr == 12'h180 && csr_priv == 2'd1 && csr_tvm)
              || csr_illegal, "INV34 S-mode satp access under TVM not illegal")
        //  INV35: a user-counter read (0xC00-0xC1F) below M must be illegal when
        //  its mcounteren bit is clear (S/U) or scounteren bit is clear (U).
        `KCHK(!(csr_op_req && (csr_op_addr >= 12'hC00 && csr_op_addr <= 12'hC1F)
                && (csr_priv != 2'd3)
                && (!csr_mcounteren[csr_op_addr[4:0]]
                    || (csr_priv == 2'd0 && !csr_scounteren[csr_op_addr[4:0]])))
              || csr_illegal, "INV35 ungated counter read did not trap")

        //  ==============================================================
        //  Hang guards / liveness watchdogs
        //  ==============================================================
        if (lsu_cnt    > STALL_LIMIT) k_hang("LSU op exceeded STALL_LIMIT cycles");
        if (m_cnt      > STALL_LIMIT) k_hang("M op exceeded STALL_LIMIT cycles");
        if (fpu_cnt    > STALL_LIMIT) k_hang("FPU op exceeded STALL_LIMIT cycles");
        if (vlsu_cnt   > VLSU_STALL_LIMIT) k_hang("VLSU op exceeded VLSU_STALL_LIMIT cycles");
        if (varith_cnt > VARITH_STALL_LIMIT) k_hang("VARITH op exceeded VARITH_STALL_LIMIT cycles");
        if (vfpu_cnt   > VFPU_STALL_LIMIT)   k_hang("VFPU op exceeded VFPU_STALL_LIMIT cycles");
        if (vkeccak_cnt > STALL_LIMIT) k_hang("VKECCAK op exceeded STALL_LIMIT cycles");
        if (fetch_cnt > FETCH_LIMIT)  k_hang("IFU produced no instruction within FETCH_LIMIT cycles");
        if (ret_cnt   > RETIRE_LIMIT) k_hang("no forward progress within RETIRE_LIMIT cycles");

        //  ==============================================================
        //  CBO op tracker (sequential): translated-first + exactly-8 aligned
        //  monotonic cbo.zero beats. (State regs declared above; checks here so
        //  they sit inside the KCHK macro's scope.)
        //  ==============================================================
        if (rst) begin
            cbo_track <= 1'b0; cbo_track_zero <= 1'b0; cbo_xlated <= 1'b0;
            cbo_first <= 1'b0; cbo_beats <= 5'd0; cbo_prev_addr <= 32'd0;
            cbo_bare_q <= 1'b0;
        end else if (lsu_req && lsu_is_cbo) begin       //  a legal cbo issues
            cbo_track <= 1'b1; cbo_track_zero <= lsu_is_cboz;
            cbo_xlated <= 1'b0; cbo_beats <= 5'd0; cbo_first <= 1'b1;
            cbo_bare_q <= lsu_bare;
        end else if (cbo_track) begin
            if (lsu_xlate_active) cbo_xlated <= 1'b1;
            if (cbo_track_zero && lsu_awvalid && lsu_awready) begin //  one beat accepted
                `KCHK(!cbo_first || (lsu_awaddr[5:0] == 6'b0),
                      "INV23b cbo.zero first beat not 64B-aligned")
                `KCHK(cbo_first || (lsu_awaddr == cbo_prev_addr + 32'd8),
                      "INV23c cbo.zero beat address not previous+8")
                cbo_prev_addr <= lsu_awaddr;
                cbo_first     <= 1'b0;
                cbo_beats     <= cbo_beats + 5'd1;
            end
            if (lsu_done) begin
                `KCHK(cbo_xlated || lsu_xlate_active || cbo_bare_q,
                      "INV22b cbo completed without a translation phase (non-bare)")
                `KCHK(!cbo_track_zero || (cbo_beats == 5'd8),
                      "INV23d cbo.zero did not emit exactly 8 write beats")
                cbo_track <= 1'b0;
            end
        end
    end

    //  trap is surfaced separately by the testbench watchdog; reference
    //  it so an unused-port lint does not fire.
    wire _unused = &{1'b0, trap, perf_retire, vmem_is_store};

    `undef KCHK

    //  ==================================================================
    //  Optional SVA form of the (combinational) invariants, for a formal flow.
    //  The sequential CBO tracker checks (INV22b/23b/23c/23d) are realised only
    //  in the runtime checker above, not mirrored here.
    //  Off by default (iverilog's default mode does not parse SVA);
    //  define KARU_ASSERT_SVA when driving this through a tool that does
    //  (symbiyosys, verilator --assert with SVA, a commercial FV tool).
    //  ==================================================================
`ifdef KARU_ASSERT_SVA
    default clocking @(posedge clk); endclocking
    default disable iff (rst);

    a_inv1_single_issue: assert property (
        $onehot0({lsu_active, m_active, fpu_active, vlsu_active, varith_active,
                  vfpu_active, vkeccak_active}));
    a_inv2_no_req_busy: assert property (
        (lsu_active || m_active || fpu_active || vlsu_active || varith_active ||
         vfpu_active || vkeccak_active) |->
            !(lsu_req || m_req || fpu_req || vlsu_req || varith_req ||
              vfpu_req || vkeccak_req));
    a_inv3_lsu_req_idle: assert property (lsu_req |-> !lsu_active);
    a_inv4_m_req_idle:   assert property (m_req   |-> !m_active);
    a_inv5_fpu_req_idle: assert property (fpu_req |-> !fpu_active);
    a_inv5h_fpu_sub:     assert property ((fpu_sub_req & (fpu_sub_req - 10'b1)) == 10'b0);
    a_inv5d_vlsu_req_idle:   assert property (vlsu_req   |-> !vlsu_active);
    a_inv5e_varith_req_idle: assert property (varith_req |-> !varith_active);
    a_inv5f_vfpu_req_idle:   assert property (vfpu_req   |-> !vfpu_active); //  vfpu_* tied 0
    a_inv5g_vkeccak_req_idle:assert property (vkeccak_req |-> !vkeccak_active);
    a_inv5j_lane_fp:         assert property (vfp_lane_active |-> varith_active);
    a_inv19_fp_req_busy:     assert property (!vfp_req_busy);
    a_inv19b_lane_warm:      assert property (!lane_warm_bad);
    a_inv6a_lsu_done: assert property (lsu_done |-> lsu_active);
    a_inv6b_m_done:   assert property (m_done   |-> m_active);
    a_inv6c_fpu_done: assert property (fpu_done |-> fpu_active);
    a_inv6d_vlsu_done:   assert property (vlsu_done   |-> vlsu_active);
    a_inv6e_varith_done: assert property (varith_done |-> varith_active);
    a_inv6f_vfpu_done:   assert property (vfpu_done   |-> vfpu_active);
    a_inv6g_vkeccak_done: assert property (vkeccak_done |-> vkeccak_active);
    a_inv7_x0:    assert property (wb_we |-> (wb_rd != 5'd0));
    a_inv8_excl:  assert property (!(wb_we && fwb_we));
    a_inv12_vg_we:   assert property (vg_we  |-> vlsu_active);
    a_inv13_gran_excl: assert property (!(varith_g_we && vg_we));
    a_inv14_vrf_x:   assert property (!(varith_g_we && wb_we));
    a_inv15_vrf_f:   assert property (!(varith_g_we && fwb_we));
    a_inv16_vxsat:   assert property (vxsat_set |-> varith_done);
    a_inv17_vmem_own:  assert property (vmem_req |-> vlsu_active);
    a_inv18_vmem_align:assert property (vmem_req |-> (vmem_addr[3:0] == 4'b0));
    a_inv9_pc:    assert property (ifu_valid |-> !ifu_pc[0]);
    a_inv10_rdir: assert property (ifu_redir |-> !ifu_redir_pc[0]);
    a_sv39i_req_idle: assert property (i_mmu_req |-> !i_mmu_busy);
    a_sv39d_req_idle: assert property (d_mmu_req |-> !d_mmu_busy);

    //  AXI VALID-stability as liveness/stability properties.
    a_axi_imem_ar: assert property (
        (imem_arvalid && !imem_arready) |=>
            (imem_arvalid &&
             $stable({imem_arid, imem_araddr, imem_arlen, imem_arsize,
                      imem_arburst, imem_arprot})));
    a_axi_dmem_ar: assert property (
        (dmem_arvalid && !dmem_arready) |=>
            (dmem_arvalid &&
             $stable({dmem_arid, dmem_araddr, dmem_arlen, dmem_arsize,
                      dmem_arburst, dmem_arprot})));
    a_axi_dmem_aw: assert property (
        (dmem_awvalid && !dmem_awready) |=>
            (dmem_awvalid &&
             $stable({dmem_awid, dmem_awaddr, dmem_awlen, dmem_awsize,
                      dmem_awburst, dmem_awprot})));
    a_axi_dmem_w: assert property (
        (dmem_wvalid && !dmem_wready) |=>
            (dmem_wvalid && $stable({dmem_wdata, dmem_wstrb, dmem_wlast})));

    //  RVA23 semantic contracts.
    a_inv20a_pm16: assert property ((csr_dpmlen == 6'd16) |-> (lsu_addr[63:48] == {16{lsu_addr[47]}}));
    a_inv20b_pm7:  assert property ((csr_dpmlen == 6'd7)  |-> (lsu_addr[63:57] == {7{lsu_addr[56]}}));
    a_inv21a_vpm16: assert property ((csr_dpmlen == 6'd16) |-> (vlsu_base_pm[63:48] == {16{vlsu_base_pm[47]}}));
    a_inv21b_vpm7:  assert property ((csr_dpmlen == 6'd7)  |-> (vlsu_base_pm[63:57] == {7{vlsu_base_pm[56]}}));
    a_inv22_cbo_ill: assert property (cbo_ill |-> !lsu_req);
    a_inv23_cboz_beat: assert property (
        (lsu_active && lsu_is_cboz && lsu_wvalid) |->
            (lsu_wstrb == 8'hFF && lsu_wdata_o == 64'b0 && lsu_awaddr[2:0] == 3'b0));
    a_inv24_cbonop_nowrite: assert property (
        (lsu_active && lsu_is_cbo && !lsu_is_cboz) |-> (!lsu_awvalid && !lsu_wvalid));
    a_inv25a_sret: assert property (sret_ill   |-> !sys_sret);
    a_inv25b_sfence: assert property (sfence_ill |-> !sys_sfencevma);
    a_inv25c_mret: assert property (mret_ill   |-> !sys_mret);
    a_inv26_privcause: assert property ((sys_priv_ill || cbo_ill) |-> (trap_req && trap_cause == 64'd2));
    a_inv27_fcvtmod_x: assert property ((fpu_done && ex_fp_zfa == 4'd7) |-> !fwb_we);
    a_inv28_fli_f:     assert property ((fpu_done && ex_fp_zfa == 4'd8) |-> !wb_we);
    a_inv27b_fcvtmod_xpos: assert property ((fpu_done && ex_fp_zfa == 4'd7 && ex_rd != 5'd0) |-> wb_we);
    a_inv28b_fli_fpos:     assert property ((fpu_done && ex_fp_zfa == 4'd8) |-> fwb_we);
    a_inv29_dmmu_va: assert property (dmmu_req_lsu |-> (dmmu_va == dmmu_va_exp));
    a_inv30a_vbq16: assert property ((vlsu_active && csr_dpmlen == 6'd16) |-> (vlsu_base_q[63:48] == {16{vlsu_base_q[47]}}));
    a_inv30b_vbq7:  assert property ((vlsu_active && csr_dpmlen == 6'd7)  |-> (vlsu_base_q[63:57] == {7{vlsu_base_q[56]}}));
    a_inv31a_zen: assert property (cbo_zero_en  == ((csr_priv==2'd3)||(csr_priv==2'd1&&menvcfg_cbze)||(csr_priv==2'd0&&menvcfg_cbze&&senvcfg_cbze)));
    a_inv31b_cfen:assert property (cbo_cf_en    == ((csr_priv==2'd3)||(csr_priv==2'd1&&menvcfg_cbcfe)||(csr_priv==2'd0&&menvcfg_cbcfe&&senvcfg_cbcfe)));
    a_inv31c_inen:assert property (cbo_inval_en == ((csr_priv==2'd3)||(csr_priv==2'd1&&(menvcfg_cbie!=2'b00))||(csr_priv==2'd0&&(menvcfg_cbie!=2'b00)&&(senvcfg_cbie!=2'b00))));
    a_inv31d_zissue: assert property ((lsu_req && lsu_is_cboz)     |-> cbo_zero_en);
    a_inv31e_cfissue:assert property ((lsu_req && lsu_is_cbocf)    |-> cbo_cf_en);
    a_inv31f_inissue:assert property ((lsu_req && lsu_is_cboinval) |-> cbo_inval_en);
    a_inv32a_sret: assert property (sret_ill   == (sys_sret_raw   && ((csr_priv==2'd0)||(csr_priv==2'd1&&csr_tsr))));
    a_inv32b_sfence: assert property (sfence_ill == (sys_sfence_raw && ((csr_priv==2'd0)||(csr_priv==2'd1&&csr_tvm))));
    a_inv33_wfi: assert property ((sys_wfi_raw && (csr_priv!=2'd3) && csr_tw) |-> sys_priv_ill);
    a_inv34_satp_tvm: assert property ((csr_op_req && csr_op_addr==12'h180 && csr_priv==2'd1 && csr_tvm) |-> csr_illegal);
    a_inv35_ctren: assert property (
        (csr_op_req && (csr_op_addr >= 12'hC00 && csr_op_addr <= 12'hC1F) && (csr_priv != 2'd3)
         && (!csr_mcounteren[csr_op_addr[4:0]] || (csr_priv == 2'd0 && !csr_scounteren[csr_op_addr[4:0]])))
            |-> csr_illegal);
    //  NOTE: the sequential CBO tracker checks (INV22b / INV23b/c/d -- translated-
    //  first, exactly-8-aligned-monotonic cbo.zero beats) are runtime-checker-only
    //  (they need a small state machine); they are not mirrored as SVA here.

    //  Liveness: an active FU must eventually complete (bounded by the
    //  tool's depth; pair with a per-unit cycle bound in the engine).
    a_live_lsu: assert property (lsu_active |-> s_eventually lsu_done);
    a_live_m:   assert property (m_active   |-> s_eventually m_done);
    a_live_fpu: assert property (fpu_active |-> s_eventually fpu_done);
    a_live_vlsu:   assert property (vlsu_active   |-> s_eventually vlsu_done);
    a_live_varith: assert property (varith_active |-> s_eventually varith_done);
    a_live_vfpu:   assert property (vfpu_active   |-> s_eventually vfpu_done);
    a_live_vkeccak: assert property (vkeccak_active |-> s_eventually vkeccak_done);
`endif

endmodule

//  ---------------------------------------------------------------------
//  Formal-flow attachment. iverilog (the default sim) does not support
//  `bind`, so the simulation path instantiates this checker from the
//  testbench (htif_tb.v) with hierarchical port connections instead.
//  For a formal tool that does support `bind`, define KARU_ASSERT_BIND
//  and the checker attaches itself to every karu64 instance with no
//  testbench involvement (the port expressions resolve against karu64's
//  internal nets).
//  ---------------------------------------------------------------------
`ifdef KARU_ASSERT_BIND
bind karu64 karu_assert u_karu_assert (
    .clk(clk), .rst(rst), .trap(trap),
    .issuing(issuing),
    .lsu_active(lsu_active), .m_active(m_active), .fpu_active(fpu_active),
    .vlsu_active(vlsu_active), .varith_active(varith_active), .vfpu_active(1'b0),
    .vkeccak_active(1'b0),
    .lsu_req(lsu_req), .lsu_done(lsu_done),
    .m_req(m_req),     .m_done(m_done),
    .fpu_req(fpu_req), .fpu_done(fpu_done),
`ifdef KARU_EN_F
    .fpu_sub_req(fpu.dbg_fpu_sub_req),
`else
    .fpu_sub_req(10'b0),
`endif
    .vlsu_req(vlsu_req),     .vlsu_done(vlsu_done),
    .varith_req(varith_req), .varith_done(varith_done),
    .vfpu_req(1'b0),     .vfpu_done(1'b0),
    .vfp_lane_active(varith_fp_lane_active),
`ifdef KARU_EN_V
    .vfp_req_busy(varith_u.dbg_fp_req_busy),
    .lane_warm_bad(varith_u.dbg_lane_warm_bad),
`else
    .vfp_req_busy(1'b0),
    .lane_warm_bad(1'b0),
`endif
    .vkeccak_req(1'b0), .vkeccak_done(1'b0),
    .wb_we(wb_we), .wb_rd(wb_rd), .fwb_we(fwb_we),
    .varith_g_we(varith_g_we), .vg_we(vg_we), .vxsat_set(varith_vxsat),
    .vmem_req(vmem_req), .vmem_is_store(vmem_is_store), .vmem_addr(vmem_addr),
    .ifu_valid(ifu_valid), .ifu_pc(ifu_pc),
    .ifu_redir(ifu_redir), .ifu_redir_pc(ifu_redir_pc),
    .perf_retire(perf_retire),
    .i_mmu_busy(immu.busy), .i_mmu_req(immu.req),
    .d_mmu_busy(dmmu.busy), .d_mmu_req(dmmu.req),
    .imem_arvalid(imem_arvalid), .imem_arready(imem_arready),
    .imem_araddr(imem_araddr),
    .imem_arid(imem_arid), .imem_arlen(imem_arlen),
    .imem_arsize(imem_arsize), .imem_arburst(imem_arburst),
    .imem_arprot(imem_arprot),
    .dmem_arvalid(dmem_arvalid), .dmem_arready(dmem_arready),
    .dmem_araddr(dmem_araddr),
    .dmem_arid(dmem_arid), .dmem_arlen(dmem_arlen),
    .dmem_arsize(dmem_arsize), .dmem_arburst(dmem_arburst),
    .dmem_arprot(dmem_arprot),
    .dmem_awvalid(dmem_awvalid), .dmem_awready(dmem_awready),
    .dmem_awaddr(dmem_awaddr),
    .dmem_awid(dmem_awid), .dmem_awlen(dmem_awlen),
    .dmem_awsize(dmem_awsize), .dmem_awburst(dmem_awburst),
    .dmem_awprot(dmem_awprot),
    .dmem_wvalid(dmem_wvalid), .dmem_wready(dmem_wready),
    .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb), .dmem_wlast(dmem_wlast),
    //  RVA23 semantic contracts
    .csr_dpmlen(csr_dpmlen), .lsu_addr(lsu_addr),
`ifdef KARU_EN_V
    .vlsu_base_pm(vlsu_base_pm),
`else
    .vlsu_base_pm(64'b0),
`endif
    .cbo_ill(cbo_ill), .lsu_is_cbo(lsu_is_cbo), .lsu_is_cboz(lsu_is_cboz),
    .lsu_is_cbocf(lsu_is_cbocf), .lsu_is_cboinval(lsu_is_cboinval),
    .lsu_awvalid(lsu_awvalid), .lsu_wvalid(lsu_wvalid), .lsu_wstrb(lsu_wstrb),
    .lsu_wdata_o(lsu_wdata_o), .lsu_awaddr(lsu_awaddr),
    .sret_ill(sret_ill), .sfence_ill(sfence_ill), .mret_ill(mret_ill),
    .sys_priv_ill(sys_priv_ill), .sys_sret(sys_sret), .sys_mret(sys_mret),
    .sys_sfencevma(sys_sfencevma), .trap_req(trap_req), .trap_cause(trap_cause),
    .ex_fp_zfa(ex_fp_zfa),
    .ex_rd(ex_rd), .lsu_xlate_active(lsu_xlate_active), .lsu_bare(lsu_bare), .lsu_awready(km_s_awready),
    .dmmu_req_lsu(dmmu_req_lsu), .dmmu_va(dmmu.va), .dmmu_va_exp(lsu_dmmu_va_exp),
`ifdef KARU_EN_V
    .vlsu_base_q(vlsu.base_q),
`else
    .vlsu_base_q(64'b0),
`endif
    .csr_priv(csr_priv),
    .menvcfg_cbze(csr.menvcfg_cbze), .menvcfg_cbcfe(csr.menvcfg_cbcfe), .menvcfg_cbie(csr.menvcfg_cbie),
    .senvcfg_cbze(csr.senvcfg_cbze), .senvcfg_cbcfe(csr.senvcfg_cbcfe), .senvcfg_cbie(csr.senvcfg_cbie),
    .cbo_zero_en(cbo_zero_en), .cbo_cf_en(cbo_cf_en), .cbo_inval_en(cbo_inval_en),
    .csr_tvm(csr_tvm), .csr_tw(csr_tw), .csr_tsr(csr_tsr),
    .sys_sret_raw(sys_sret_raw), .sys_sfence_raw(sys_sfence_raw), .sys_wfi_raw(sys_wfi_raw),
    .csr_op_req(csr_req), .csr_op_addr(csr_addr), .csr_illegal(csr_illegal),
    .csr_mcounteren(csr.csr_mcounteren[31:0]), .csr_scounteren(csr.csr_scounteren[31:0])
);
`endif
