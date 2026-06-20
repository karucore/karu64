//  karu_vrf_assert.v
//  Passive protocol checker for the BRAM-backed macro-VRF.
//  See doc/architecture.md for the architecture this enforces.
//
//  Like karu_assert.v this is a *passive* checker: it observes the two
//  BRAM ports + the v0 flop shadow and flags any violation of the VRF
//  access contract. It carries NO instruction semantics -- only the
//  structural/protocol invariants of the dual-port-BRAM register file:
//  port collisions, address range, write-only-while-active, the v0
//  shadow-coherence optimization, and the undisturbed-tail rule.
//
//  It is NOT in the synthesized core (flow/syn/ + the fpga read lists exclude
//  *_assert.v). The sim path instantiates it from the testbench with
//  hierarchical connections (iverilog 14 has no `bind`); a formal flow
//  uses the `bind` block (KARU_VRF_ASSERT_BIND) and the SVA mirror
//  (KARU_VRF_ASSERT_SVA) at the bottom.
//
//  Runtime knobs (plusargs, shared with karu_assert):
//      +no_assert        disable the checker entirely
//      +no_assert_stop   report violations but do not $finish
//
//  All invariants sample at posedge clk, gated on !rst. The behavioural
//  shadow array `sh` mirrors BRAM writes so VRF5 (v0 == BRAM[reg0]) is a
//  real cross-check; it is also valid auxiliary state for a formal tool.

`include "karu_vcfg.vh"

module karu_vrf_assert #(
    parameter integer VLEN   = `KARU_VLEN,
    parameter integer VBUS_W = `KARU_VBUS_W,
    //  1 => $finish on first violation; 0 => count and continue.
    parameter integer STOP_ON_FAIL = 1,
    //  Backstop: a vector unit active this many cycles without touching
    //  the BRAM at all is treated as stuck. Generous (bit-serial divide
    //  reads operands only periodically) -- matches VARITH_STALL_LIMIT.
    parameter integer ACCESS_STALL_LIMIT = 40000
) (
    input  wire                 clk,
    input  wire                 rst,

    //  ---- active context (which unit owns the ports this cycle) ----
    input  wire                 varith_active,
    input  wire                 vlsu_active,

    //  ---- BRAM port A (read-mostly; may write for 2-granule writes) ----
    //  (address/byte-enable widths use inline exprs so they are visible in
    //  the port list; the body re-declares them as localparams AW/NBYTES.)
    input  wire                 a_en,
    input  wire                 a_we,
    input  wire [$clog2(32*(VLEN/VBUS_W))-1:0]  a_addr,
    input  wire [(VBUS_W/8)-1:0]                a_be,
    input  wire [VBUS_W-1:0]    a_wdata,
    input  wire [VBUS_W-1:0]    a_rdata,    //  registered read data (valid 1 cyc after a read)

    //  ---- BRAM port B (primary writeback port) ----
    input  wire                 b_en,
    input  wire                 b_we,
    input  wire [$clog2(32*(VLEN/VBUS_W))-1:0]  b_addr,
    input  wire [(VBUS_W/8)-1:0]                b_be,
    input  wire [VBUS_W-1:0]    b_wdata,
    input  wire [VBUS_W-1:0]    b_rdata,    //  registered read data (valid 1 cyc after a read)

    //  ---- v0 mask flop shadow under test ----
    input  wire [VLEN-1:0]      v0,

    //  ---- writeback semantics qualifiers ----
    //  wb_vl_governed : this cycle's element write(s) obey the vl tail (VRF6).
    //  wb_mask_dest   : this cycle's write targets a *mask* register with
    //                   bit-granular semantics -- keep-old is merged into the
    //                   write DATA (read-modify-write), NOT done by byte-enable,
    //                   so the tail-byte rule (VRF6) does not apply (a granule
    //                   byte may legitimately be enabled while holding kept bits).
    //  wb_group_reg : base register vd of the current LMUL group, so the
    //                 tail element index can be made GROUP-GLOBAL --
    //                 vl counts across the whole group, not per register.
    //  wb_epr       : elements per single v-register at the current SEW
    //                 (= VLEN / (8<<vsew); the core's `epr`/`v_base`).
    input  wire                 wb_vl_governed,
    input  wire                 wb_mask_dest,
    input  wire [15:0]          wb_vl,          //  current vl (element count, group-global)
    input  wire [2:0]           wb_vsew,        //  0=e8,1=e16,2=e32,3=e64
    input  wire [4:0]           wb_group_reg,   //  vd (group base register)
    input  wire [15:0]          wb_epr          //  elements per register
);
    //  ---- derived geometry (must match the DUT) ----
    localparam integer NBYTES = VBUS_W / 8;                 //  byte lanes / write-enables
    localparam integer VGRAN  = VLEN / VBUS_W;              //  granules (= entries) per v-reg
    localparam integer NENT   = 32 * VGRAN;                 //  BRAM depth
    localparam integer AW     = $clog2(NENT);               //  address width
    localparam integer GB     = (VGRAN > 1) ? $clog2(VGRAN) : 1;    //  granule-index bits

    integer fails   = 0;
    reg     enabled = 1'b1;
    reg     do_stop = 1'b1;
    reg [63:0] k_cyc  = 64'b0;

    //  NB: $test$plusargs does PREFIX matching, so "+no_assert_stop" also
    //  matches the "no_assert" query. Disambiguate so "+no_assert_stop" means
    //  report-but-continue (checker stays active), and only a bare "+no_assert"
    //  fully disables. (If both are given, treat as report-continue.)
    reg na, nss;
    initial begin
        nss = $test$plusargs("no_assert_stop");
        na  = $test$plusargs("no_assert");
        if (nss)        do_stop = 1'b0;     //  report, do not $finish
        if (na && !nss) enabled = 1'b0;     //  bare +no_assert -> fully off
    end

    //  ==================================================================
    //  Behavioural shadow of the BRAM, reconstructed from the observed WRITE
    //  stream (same byte enables the real array uses). Two distinct uses:
    //    VRF5a -- v0 flop shadow must equal this write-stream reconstruction
    //             of reg 0 (catches a broken v0 write-through).
    //    VRF5b -- on any registered READ, the DUT's returned read data must
    //             equal this shadow (catches a broken BRAM write path,
    //             including the reg-0 path that VRF5a alone cannot see).
    //  Writes are range-guarded so an (illegal) out-of-range address cannot
    //  index outside `sh` before VRF3 reports it.
    //  ==================================================================
    reg [VBUS_W-1:0] sh [0:NENT-1];
    integer i, e;
    initial for (i = 0; i < NENT; i = i + 1) sh[i] = {VBUS_W{1'b0}};

    always @(posedge clk) begin
        if (!rst) begin
            if (a_en && a_we && a_addr < NENT)
                for (e = 0; e < NBYTES; e = e + 1)
                    if (a_be[e]) sh[a_addr][e*8 +: 8] <= a_wdata[e*8 +: 8];
            if (b_en && b_we && b_addr < NENT)
                for (e = 0; e < NBYTES; e = e + 1)
                    if (b_be[e]) sh[b_addr][e*8 +: 8] <= b_wdata[e*8 +: 8];
        end
    end

    //  VRF5a: v0 (reg 0) reconstructed from the write-stream shadow == the
    //  DUT's flop shadow. reg 0 occupies shadow entries [0 .. VGRAN-1]
    //  (granule g = bits [g*VBUS_W +: VBUS_W] of the register).
    reg     v0_ok;
    integer gg;
    always @* begin
        v0_ok = 1'b1;
        for (gg = 0; gg < VGRAN; gg = gg + 1)
            if (v0[gg*VBUS_W +: VBUS_W] !== sh[gg]) v0_ok = 1'b0;
    end

    //  VRF5b: registered-read coherence. Capture each port's read this cycle;
    //  next cycle the DUT presents r*data, which must equal the shadow for the
    //  address read. (Skipped if a write hit the same address last cycle, i.e.
    //  a R/W collision -- but VRF2 already forbids that.) A read of reg 0 here
    //  is what actually proves the BRAM reg-0 contents (not just the flop).
    reg              a_rd_q, b_rd_q;
    reg [AW-1:0]     a_raddr_q, b_raddr_q;
    always @(posedge clk) begin
        if (rst) begin a_rd_q <= 1'b0; b_rd_q <= 1'b0; end
        else begin
            a_rd_q <= a_en && !a_we && (a_addr < NENT);  a_raddr_q <= a_addr;
            b_rd_q <= b_en && !b_we && (b_addr < NENT);  b_raddr_q <= b_addr;
        end
    end
    wire a_rdata_ok = !a_rd_q || (a_rdata === sh[a_raddr_q]);
    wire b_rdata_ok = !b_rd_q || (b_rdata === sh[b_raddr_q]);

    //  ==================================================================
    //  Undisturbed-tail check (VRF6): a vl-governed *element* write must not
    //  enable any byte whose GROUP-GLOBAL element index is >= vl. vl counts
    //  across the whole LMUL group, so the index is
    //      (reg - group_reg)*epr + (granule-local element)
    //  -- using the register decoded from the write address. One-directional
    //  (disabling extra bytes for masking is always fine). Does NOT apply to
    //  mask-destination writes (wb_mask_dest), whose keep-old is merged into
    //  the data via RMW, so an enabled byte may legitimately straddle vl.
    //  ==================================================================
    function port_tail_bad;
        input [AW-1:0]      addr;
        input [NBYTES-1:0]  be;
        input [15:0]        vl;
        input [2:0]         vsew;
        input [4:0]         group_reg;
        input [15:0]        epr;
        integer             j;
        reg [GB-1:0]        gran;
        reg [4:0]           reg_idx;
        reg [31:0]          base, eidx;
        reg                 bad;
        begin
            gran    = (VGRAN > 1) ? addr[GB-1:0]   : {GB{1'b0}};
            reg_idx = addr[AW-1:GB];                    //  register number from addr
            //  group-global base element of this register
            base    = (reg_idx - group_reg) * {16'b0, epr};
            bad     = 1'b0;
            for (j = 0; j < NBYTES; j = j + 1)
                if (be[j]) begin
                    //  global element index = reg base + granule-local element
                    eidx = base + (((gran * NBYTES) + j) >> vsew);
                    if (eidx >= {16'b0, vl}) bad = 1'b1;
                end
            port_tail_bad = bad;
        end
    endfunction

    wire a_tail_bad = a_en && a_we && wb_vl_governed && !wb_mask_dest
                    && port_tail_bad(a_addr, a_be, wb_vl, wb_vsew, wb_group_reg, wb_epr);
    wire b_tail_bad = b_en && b_we && wb_vl_governed && !wb_mask_dest
                    && port_tail_bad(b_addr, b_be, wb_vl, wb_vsew, wb_group_reg, wb_epr);

    //  ---- port-collision helpers ----
    wire same_addr = (a_addr == b_addr);
    wire ww_collide = a_en && a_we && b_en && b_we && same_addr;
    wire rw_collide = (a_en && a_we && b_en && !b_we && same_addr)
                   || (b_en && b_we && a_en && !a_we && same_addr);
    wire a_wr = a_en && a_we;
    wire b_wr = b_en && b_we;
    wire any_access = a_en || b_en;
    wire any_write  = a_wr || b_wr;
    wire unit_active = varith_active || vlsu_active;

    //  ---- liveness backstop watchdog ----
    //  Counts *continuous* unit-active cycles (resets when idle). Trips on a
    //  stuck transaction whether or not it keeps poking the BRAM -- so a FSM
    //  wedged mid-op (looping reads/writes forever) is caught too, not just a
    //  BRAM-idle hang. The bound matches karu_assert's VARITH/VLSU stall
    //  limits; transaction *correctness* length is karu_assert's job, this is
    //  a self-contained backstop for the formal/standalone use of this module.
    reg [31:0] act_cnt;
    always @(posedge clk) begin
        if (rst) act_cnt <= 0;
        else     act_cnt <= unit_active ? act_cnt + 1 : 0;
    end

    task k_hang;
        input [8*64-1:0] tag;
        begin
            if (enabled && !rst) begin
                $display("[KARU-VRF] HANG cyc=%0d t=%0t: %0s", k_cyc, $time, tag);
                $display("[KARU-VRF]   varith=%b vlsu=%b a_en=%b b_en=%b", varith_active, vlsu_active, a_en, b_en);
                $finish;
            end
        end
    endtask

    //  Uniform reporting + optional stop (mirrors karu_assert's KCHK).
    `define VCHK(cond, tag) \
        if (enabled && !rst && !(cond)) begin \
            fails = fails + 1; \
            $display("[KARU-VRF] FAIL cyc=%0d t=%0t: %s", k_cyc, $time, tag); \
            if (do_stop && STOP_ON_FAIL) begin \
                $display("[KARU-VRF] %0d failure(s); stopping.", fails); \
                $finish; \
            end \
        end

    always @(posedge clk) begin
        k_cyc <= k_cyc + 64'b1;

        //  VRF1: never two writes to the same BRAM entry (TDP W/W undefined).
        `VCHK(!ww_collide, "VRF1 same-address write/write collision (ports A,B)")

        //  VRF2: never read one port while the other writes the same entry
        //  (design never relies on read-during-write data).
        `VCHK(!rw_collide, "VRF2 same-address read-while-write collision (ports A,B)")

        //  VRF3: every active address is in range [0, 32*VGRAN).
        `VCHK(!a_en || (a_addr < NENT), "VRF3 port A address out of range")
        `VCHK(!b_en || (b_addr < NENT), "VRF3 port B address out of range")

        //  VRF4: any BRAM access (read OR write) happens only while a vector
        //  unit owns the ports (no spurious/idle access on either port).
        `VCHK(!any_access || unit_active, "VRF4 BRAM accessed while no vector unit active")

        //  VRF5a: v0 flop shadow == reg 0 reconstructed from the write stream
        //  (catches a broken v0 write-through).
        `VCHK(v0_ok, "VRF5a v0 flop shadow != write-stream reg 0 (write-through bug)")

        //  VRF5b: registered read data == shadow (catches a broken BRAM write
        //  path; a read of reg 0 here proves the BRAM reg-0 contents).
        `VCHK(a_rdata_ok, "VRF5b port A read data != BRAM shadow")
        `VCHK(b_rdata_ok, "VRF5b port B read data != BRAM shadow")

        //  VRF6: a vl-governed element write never enables a tail byte (e>=vl).
        //  (mask-dest writes are exempt -- keep-old is in the data, see above.)
        `VCHK(!a_tail_bad, "VRF6 port A enables a tail byte (undisturbed-tail violated)")
        `VCHK(!b_tail_bad, "VRF6 port B enables a tail byte (undisturbed-tail violated)")

        //  VRF7: exclusive port ownership -- varith and the LSU are
        //  single-issue and never own the BRAM ports in the same cycle.
        `VCHK(!(varith_active && vlsu_active), "VRF7 varith and vlsu both active (port ownership)")

        //  WDOG: a vector unit stayed active longer than any legal op => stuck.
        if (act_cnt > ACCESS_STALL_LIMIT[31:0]) k_hang("WDOG vector unit active beyond stall limit");
    end

    `undef VCHK

    //  ==================================================================
    //  Optional SVA mirror, for a formal flow. Off by default (iverilog's
    //  default mode does not parse SVA). The shadow array `sh`, `v0_ok`,
    //  and the *_tail_bad / *_collide wires are shared auxiliary state, so
    //  the properties below are the exact same predicates as above.
    //  ==================================================================
`ifdef KARU_VRF_ASSERT_SVA
    default clocking @(posedge clk); endclocking
    default disable iff (rst);

    a_vrf1_ww:    assert property (!ww_collide);
    a_vrf2_rw:    assert property (!rw_collide);
    a_vrf3a_rng:  assert property (a_en |-> (a_addr < NENT));
    a_vrf3b_rng:  assert property (b_en |-> (b_addr < NENT));
    a_vrf4_act:   assert property (any_access |-> unit_active);
    a_vrf5a_v0:   assert property (v0_ok);
    a_vrf5b_rda:  assert property (a_rdata_ok);
    a_vrf5b_rdb:  assert property (b_rdata_ok);
    a_vrf6a_tl:   assert property (!a_tail_bad);
    a_vrf6b_tl:   assert property (!b_tail_bad);
    a_vrf7_excl:  assert property (!(varith_active && vlsu_active));
    //  Liveness backstop: an active unit must eventually become idle (its op
    //  completes). Stronger than "eventually touches BRAM" -- catches a FSM
    //  wedged while still poking the ports.
    a_vrf_live:   assert property (unit_active |-> s_eventually (!unit_active));
`endif

endmodule

//  ---------------------------------------------------------------------
//  Formal-flow attachment. The sim path instantiates this from the
//  testbench (hierarchical connections) because iverilog has no `bind`.
//  Define KARU_VRF_ASSERT_BIND for a tool that supports `bind`; the port
//  expressions resolve against the karu_vrf_bram instance's nets. Adjust
//  the instance path (`vrf`) to match the integration in karu64.v.
//  ---------------------------------------------------------------------
`ifdef KARU_VRF_ASSERT_BIND
bind karu_vrf_bram karu_vrf_assert #(.VLEN(VLEN), .VBUS_W(VBUS_W)) u_karu_vrf_assert (
    .clk(clk), .rst(rst),
    .varith_active(1'b1),   //  connect to the core's varith_active at integration
    .vlsu_active(1'b0),     //  connect to the core's vlsu_active at integration
    .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_be(a_be), .a_wdata(a_wdata), .a_rdata(a_rdata),
    .b_en(b_en), .b_we(b_we), .b_addr(b_addr), .b_be(b_be), .b_wdata(b_wdata), .b_rdata(b_rdata),
    .v0(v0),
    .wb_vl_governed(1'b0),  //  connect to the writeback vl-governed qualifier
    .wb_mask_dest(1'b0),    //  connect to the mask-destination qualifier
    .wb_vl(16'd0), .wb_vsew(3'd0),
    .wb_group_reg(5'd0),    //  connect to vd (group base register)
    .wb_epr(16'd0)          //  connect to elements-per-register (epr / v_base)
);
`endif
