// Revocation with an SBA transaction in flight (doc/debug-auth-plan.md 3.5,
// milestone A4), on the real karudbg_core with KARU_DBG_AUTH and
// KARU_DBG_SBA: karu64, the DM with its SBA engine, karudbg_bus, the
// authentication block and the island, booted through the ROM stub. The
// hart runs an application that keeps using the data bus. The debugger
// authenticates and starts an SBA access; the bench holds part of it on the
// core's dmem port and debug is revoked while it is held:
//   - the R beat of a read or the B beat of a RAM write, released from one
//     edge before the falling edge to 40 after (revoke_i), and a read with
//     the fall produced by the hart setting mdbgauth.fw_lock;
//   - the AR or AW of an accepted transfer, still stalled at the fabric;
//   - a request the bus has not accepted yet (the hart's load holds it);
//   - a read whose R beat is withheld for good while the hart is in Debug
//     Mode: the relock reset (item 3) cancels it instead.
// Each scenario starts from a power-on reset; an authorized baseline first
// shows the same held read and write completing with their data.
//
// Checked independently of the DUT's own assertions, on the dmem port and
// the DMI:
//   AXI     handshake protocol on the dmem port: no X on a handshake,
//           VALID and payload held until READY, R/B only for an outstanding
//           transaction, RLAST and WLAST, one outstanding transaction per
//           channel, nothing outstanding across a reset;
//   DRAIN   the accepted SBA transfer completes: exactly one AR (or AW and
//           W) and exactly one R (or B) beat, consumed when released;
//   LAUNCH  no SBA access reaches the bus after the fall, whatever the
//           debugger writes to sbcs, sbaddress0 and sbdata0/1;
//   LOCKED  every DMI read accepted after the fall returns the locked view;
//   LEAK    no DMI response after the fall carries the drained read data;
//   HART    the hart's own loads and stores complete after the drain (the
//           bus is not left owned by the SBA);
//   PRE     preconditions and the timing of the scenario itself.
// A failed check prints "FAIL [TAG]" and the run continues, so the make
// target can tell which check caught each RTL mutant.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karudbg_defs.vh"
`include "rtl/karu_assert.sv"
module tb_auth_sba_revoke #(parameter ROM_HEX = "rom.hex");
    reg clk = 0, rst = 1;
    always #5 clk = !clk;
    wire debug_mode_o, debug_resume_ack_o, trap;
    reg irq = 0, irq_software = 0, irq_external_m = 0, irq_external_s = 0;
    reg [63:0] time_in = 0;
    reg [31:0] uncache_page = 0, hpm_events = 0;
    wire cache_flush_req, cache_flush_invalidate;
    reg cache_flush_done = 0;
    wire [`AXI_ID_W-1:0] imem_arid, imem_rid, dmem_arid, dmem_rid, dmem_awid, dmem_bid;
    wire [`AXI_ADDR_W-1:0] imem_araddr, dmem_araddr, dmem_awaddr;
    wire [`AXI_LEN_W-1:0] imem_arlen, dmem_arlen, dmem_awlen;
    wire [`AXI_SIZE_W-1:0] imem_arsize, dmem_arsize, dmem_awsize;
    wire [`AXI_BURST_W-1:0] imem_arburst, dmem_arburst, dmem_awburst;
    wire [`AXI_PROT_W-1:0] imem_arprot, dmem_arprot, dmem_awprot;
    wire [`AXI_DATA_W-1:0] imem_rdata, dmem_rdata, dmem_wdata;
    wire [`AXI_RESP_W-1:0] imem_rresp, dmem_rresp, dmem_bresp;
    wire [`AXI_STRB_W-1:0] dmem_wstrb;
    wire imem_arvalid, imem_arready, imem_rlast, imem_rvalid, imem_rready;
    wire dmem_arvalid, dmem_arready, dmem_rlast, dmem_rvalid, dmem_rready;
    wire dmem_awvalid, dmem_awready, dmem_wlast, dmem_wvalid, dmem_wready;
    wire dmem_bvalid, dmem_bready;
    reg hart_reset_i = 0, dmi_reset_i = 0, dmi_req_valid_i = 0, dmi_resp_ready_i = 0;
    wire dmi_req_ready_o, dmi_resp_valid_o, ndmreset_o;
    reg [6:0] dmi_req_addr_i = 0;
    reg [1:0] dmi_req_op_i = 0;
    reg [31:0] dmi_req_data_i = 0;
    wire [31:0] dmi_resp_data_o;
    wire [1:0] dmi_resp_op_o;
    reg [1:0] lc_i = 2'd1;
    reg hold_strap_i = 1'b1, revoke_i = 1'b0;
    reg [1:0] trng_opst_i = 2'd2;
    reg [15:0] trng_data_i = 16'h5a5a;
    wire trng_ack_o, auth_reset_o;
    karudbg_core #(.RESET_PC(64'h0001_0000), .ISLAND_ROM_HEX(ROM_HEX)) dut (.*);
    wire [31:0] mmio_reads, mmio_writes;
    wire [63:0] mmio_value;

    // ---- held responses: the dmem R and B channels pass through a bench
    // gate. A beat of the transaction to hold_r_addr (hold_b_addr) is hidden
    // from the core, VALID and READY both, until the bench releases it. The
    // gate closes before the responder can first present the beat (the beat
    // follows its address handshake by at least one cycle) and opens once,
    // so the core never sees a VALID withdrawn.
    // The address phase can be held the same way: an AR or AW to hold_a_addr
    // stays unaccepted (READY low to the core, VALID hidden from the
    // responder) until the gate opens, once.
    wire ram_dmem_rvalid, ram_dmem_rready, ram_dmem_bvalid, ram_dmem_bready;
    wire ram_dmem_arvalid, ram_dmem_arready, ram_dmem_awvalid, ram_dmem_awready;
    reg hold_r_en = 0, hold_b_en = 0, hold_a_en = 0;
    reg [31:0] hold_a_addr = 0;
    reg [31:0] hold_r_addr = 0, hold_b_addr = 0;
    reg [31:0] ar_addr_q = 0, aw_addr_q = 0;  // address of the last accepted AR / AW
    wire hold_r = hold_r_en && ar_addr_q == hold_r_addr;
    wire hold_b = hold_b_en && aw_addr_q == hold_b_addr;
    assign dmem_rvalid = ram_dmem_rvalid && !hold_r;
    assign ram_dmem_rready = dmem_rready && !hold_r;
    assign dmem_bvalid = ram_dmem_bvalid && !hold_b;
    assign ram_dmem_bready = dmem_bready && !hold_b;
    wire hold_ar = hold_a_en && dmem_araddr == hold_a_addr;
    wire hold_aw = hold_a_en && dmem_awaddr == hold_a_addr;
    assign ram_dmem_arvalid = dmem_arvalid && !hold_ar;
    assign dmem_arready = ram_dmem_arready && !hold_ar;
    assign ram_dmem_awvalid = dmem_awvalid && !hold_aw;
    assign dmem_awready = ram_dmem_awready && !hold_aw;
    // The responder is reset with the relock reset too, as karudbg_core
    // requires of an integration (it never fires here: the hart runs).
    karudbg_test_ram memory (.*, .fifo_count(), .hart_reset_i(hart_reset_i || auth_reset_o),
        .dmem_rvalid(ram_dmem_rvalid), .dmem_rready(ram_dmem_rready),
        .dmem_bvalid(ram_dmem_bvalid), .dmem_bready(ram_dmem_bready),
        .dmem_arvalid(ram_dmem_arvalid), .dmem_arready(ram_dmem_arready),
        .dmem_awvalid(ram_dmem_awvalid), .dmem_awready(ram_dmem_awready));
    always @(posedge clk) cache_flush_done <= cache_flush_req && !rst;
    `include "test/dbg/trigger_checker.vh"

    localparam [31:0] SBA_RD = 32'h8000_4000;      // SBA read target: the secret
    localparam [31:0] SBA_WR = 32'h8000_4100;      // SBA write target
    localparam [31:0] SBA_CANARY = 32'h8000_4300;  // target of every post-fall attempt
    localparam [31:0] MMIO = 32'h1000_0000;        // the hart's device register
    localparam [31:0] RAM_CTR = 32'h8000_1000;     // the hart's RAM store
    localparam [63:0] SECRET = 64'ha5ec2e70_d2a14ed7;
    localparam [63:0] WVAL = 64'h0bad5eed_6a7e0d17;
    localparam [63:0] CANARY = 64'hca7a5ca7_ca7a5ca7;
    localparam integer K_READ = 0, K_WRITE = 1, K_FWLOCK = 2, K_PENDING = 3, K_ADDR_R = 4, K_ADDR_W = 5,
                       K_HALTED = 6;
    // An SBA access is recognised by its address alone: the hart never
    // touches this page.
    function automatic sba_page(input [31:0] a);
        sba_page = a[31:12] == SBA_RD[31:12];
    endfunction

    integer checks = 0, errors = 0, scenarios = 0;
    function automatic string off(input integer d);
        if (d < 0) off = $sformatf("fall%0d", d);
        else off = $sformatf("fall+%0d", d);
    endfunction
    string scen = "setup";
    task bad(input string tag, input string what);
        begin
            errors = errors + 1;
            $display("auth sba revoke FAIL [%s] %s: %s (t=%0t)", tag, scen, what, $time);
        end
    endtask
    task check(input bit c, input string tag, input string what);
        begin checks = checks + 1; if (!c) bad(tag, what); end
    endtask

    // ---------------- independent monitor of the dmem port ----------------
    // Edges are numbered; "locked at edge E" means debug_enable_o was 0 in
    // the cycle before E, so E is at least one edge after the falling edge.
    // An SBA-page AR or AW accepted at a locked edge is a launch unless it
    // was already presented in an unlocked cycle and held since (accepted
    // work finishing its address phase, plan 3.5 item 2).
    integer edge_n = 0, t_fall = -1;
    reg en_prev = 0, r_out = 0, aw_out = 0;
    reg ar_stall = 0, aw_stall = 0, w_stall = 0, r_shown = 0, b_shown = 0;
    reg [55:0] ar_pay = 0, aw_pay = 0;
    reg [72:0] w_pay = 0;
    reg [70:0] r_pay = 0;
    reg [5:0] b_pay = 0;
    integer r_left = 0, w_beats = 0, w_len = 0;
    integer sba_ar = 0, sba_aw = 0, sba_w = 0, sba_r = 0, sba_b = 0;
    integer t_sba_ar = -1, t_sba_aw = -1, t_sba_r = -1, t_sba_b = -1;
    integer t_held_r = -1, t_held_b = -1;   // edge at which a held beat was consumed
    reg r_was_held = 0, b_was_held = 0;
    integer core_r = 0, core_b = 0;          // completed core transactions
    integer cov_ar_stall = 0, cov_aw_stall = 0, cov_w_stall = 0;  // monitor coverage, whole run
    reg relock_seen = 0, ar_pre = 0, aw_pre = 0;
    integer t_ar_pre = -1, t_aw_pre = -1;    // first cycle a pre-fall SBA address was presented
    always @(posedge clk) begin
        edge_n = edge_n + 1;
        if (rst) begin
            en_prev = 0; t_fall = -1; r_out = 0; aw_out = 0;
            ar_stall = 0; aw_stall = 0; w_stall = 0; r_shown = 0; b_shown = 0;
            sba_ar = 0; sba_aw = 0; sba_w = 0; sba_r = 0; sba_b = 0;
            t_sba_ar = -1; t_sba_aw = -1; t_sba_r = -1; t_sba_b = -1;
            t_held_r = -1; t_held_b = -1; r_was_held = 0; b_was_held = 0;
            core_r = 0; core_b = 0; relock_seen = 0; ar_pre = 0; aw_pre = 0; t_ar_pre = -1; t_aw_pre = -1;
        end else begin
            if (en_prev && !dut.auth.debug_enable_o) t_fall = edge_n - 1;
            en_prev = dut.auth.debug_enable_o;
            if (auth_reset_o && dut.auth.auth_unlock_q) relock_seen = 1;
            if ((^{dmem_arvalid, dmem_arready, dmem_rvalid, dmem_rready, dmem_awvalid, dmem_awready,
                   dmem_wvalid, dmem_wready, dmem_bvalid, dmem_bready, dmi_req_ready_o, dmi_resp_valid_o}) === 1'bx)
                bad("AXI", $sformatf("X on a dmem or DMI handshake signal: AR %b%b R %b%b AW %b%b W %b%b B %b%b DMI %b%b",
                                     dmem_arvalid, dmem_arready, dmem_rvalid, dmem_rready, dmem_awvalid, dmem_awready,
                                     dmem_wvalid, dmem_wready, dmem_bvalid, dmem_bready, dmi_req_ready_o, dmi_resp_valid_o));
            // A hart/system reset resets the dmem port and its responder
            // together (karudbg_core): nothing stays outstanding across it.
            if (auth_reset_o || hart_reset_i || ndmreset_o) begin
                r_out = 0; aw_out = 0; ar_stall = 0; aw_stall = 0; w_stall = 0;
                r_shown = 0; b_shown = 0; r_was_held = 0; b_was_held = 0; ar_pre = 0; aw_pre = 0;
            end else begin
                // stability of stalled VALIDs (master side) and shown beats
                // (responder side, i.e. this bench's gate)
                if (ar_stall && (!dmem_arvalid ||
                    {dmem_arid, dmem_araddr, dmem_arlen, dmem_arsize, dmem_arburst, dmem_arprot} !== ar_pay))
                    bad("AXI", "AR VALID dropped or payload changed before ARREADY");
                if (aw_stall && (!dmem_awvalid ||
                    {dmem_awid, dmem_awaddr, dmem_awlen, dmem_awsize, dmem_awburst, dmem_awprot} !== aw_pay))
                    bad("AXI", "AW VALID dropped or payload changed before AWREADY");
                if (w_stall && (!dmem_wvalid || {dmem_wdata, dmem_wstrb, dmem_wlast} !== w_pay))
                    bad("AXI", "W VALID dropped or payload changed before WREADY");
                if (r_shown && (!dmem_rvalid || {dmem_rid, dmem_rdata, dmem_rresp, dmem_rlast} !== r_pay))
                    bad("AXI", "R VALID dropped or beat changed before RREADY");
                if (b_shown && (!dmem_bvalid || {dmem_bid, dmem_bresp} !== b_pay))
                    bad("AXI", "B VALID dropped or response changed before BREADY");
                // R before AR: the final beat of one read may meet the next AR
                if (dmem_rvalid && dmem_rready) begin
                    if (!r_out) bad("AXI", "R beat consumed with no read outstanding");
                    else begin
                        if (dmem_rlast !== (r_left == 0)) bad("AXI", "RLAST does not match ARLEN");
                        if (r_left == 0) begin
                            r_out = 0;
                            if (r_was_held) t_held_r = edge_n;
                            r_was_held = 0;
                            if (sba_page(ar_addr_q)) begin sba_r = sba_r + 1; t_sba_r = edge_n; end
                            else core_r = core_r + 1;
                        end else r_left = r_left - 1;
                    end
                end
                if (dmem_arvalid && dmem_arready) begin
                    if (r_out) bad("AXI", "second AR while a read is outstanding");
                    r_out = 1; r_left = dmem_arlen;
                    if (sba_page(dmem_araddr)) begin
                        sba_ar = sba_ar + 1; t_sba_ar = edge_n;
                        if (!dut.auth.debug_enable_o && !ar_pre)
                            bad("LAUNCH", $sformatf("SBA AR to %08x after the fall", dmem_araddr));
                    end
                    ar_pre = 0;
                end
                if (dmem_bvalid && dmem_bready) begin
                    if (!aw_out || w_beats != w_len + 1)
                        bad("AXI", "B before the write's AW and every W beat");
                    aw_out = 0;
                    if (b_was_held) t_held_b = edge_n;
                    b_was_held = 0;
                    if (sba_page(aw_addr_q)) begin sba_b = sba_b + 1; t_sba_b = edge_n; end
                    else core_b = core_b + 1;
                end
                if (dmem_awvalid && dmem_awready) begin
                    if (aw_out) bad("AXI", "second AW while a write is outstanding");
                    aw_out = 1; w_len = dmem_awlen; w_beats = 0;
                    if (sba_page(dmem_awaddr)) begin
                        sba_aw = sba_aw + 1; t_sba_aw = edge_n;
                        if (!dut.auth.debug_enable_o && !aw_pre)
                            bad("LAUNCH", $sformatf("SBA AW to %08x after the fall", dmem_awaddr));
                    end
                    aw_pre = 0;
                end
                if (dmem_wvalid && dmem_wready) begin
                    // This responder accepts W only after AW.
                    if (!aw_out) bad("AXI", "W beat accepted with no write address");
                    w_beats = w_beats + 1;
                    if (dmem_wlast !== (w_beats == w_len + 1) || w_beats > w_len + 1)
                        bad("AXI", "WLAST does not match AWLEN");
                    if (sba_page(aw_addr_q)) sba_w = sba_w + 1;
                end
                // (The stability checks above hold a stalled address in place.)
                if (dmem_arvalid && !dmem_arready && sba_page(dmem_araddr) && dut.auth.debug_enable_o) begin
                    if (!ar_pre) t_ar_pre = edge_n;
                    ar_pre = 1;
                end
                if (dmem_awvalid && !dmem_awready && sba_page(dmem_awaddr) && dut.auth.debug_enable_o) begin
                    if (!aw_pre) t_aw_pre = edge_n;
                    aw_pre = 1;
                end
                if (hold_r && ram_dmem_rvalid) r_was_held = 1;
                if (hold_b && ram_dmem_bvalid) b_was_held = 1;
                if (ar_stall) cov_ar_stall = cov_ar_stall + 1;
                if (aw_stall) cov_aw_stall = cov_aw_stall + 1;
                if (w_stall) cov_w_stall = cov_w_stall + 1;
                ar_stall = dmem_arvalid && !dmem_arready;
                aw_stall = dmem_awvalid && !dmem_awready;
                w_stall = dmem_wvalid && !dmem_wready;
                r_shown = dmem_rvalid && !dmem_rready;
                b_shown = dmem_bvalid && !dmem_bready;
                ar_pay = {dmem_arid, dmem_araddr, dmem_arlen, dmem_arsize, dmem_arburst, dmem_arprot};
                aw_pay = {dmem_awid, dmem_awaddr, dmem_awlen, dmem_awsize, dmem_awburst, dmem_awprot};
                w_pay = {dmem_wdata, dmem_wstrb, dmem_wlast};
                r_pay = {dmem_rid, dmem_rdata, dmem_rresp, dmem_rlast};
                b_pay = {dmem_bid, dmem_bresp};
            end
        end
    end
    // Addresses for the hold gate, updated with the handshake.
    always @(posedge clk) begin
        if (rst || auth_reset_o || hart_reset_i || ndmreset_o) begin ar_addr_q <= 0; aw_addr_q <= 0; end
        else begin
            if (dmem_arvalid && dmem_arready) ar_addr_q <= dmem_araddr;
            if (dmem_awvalid && dmem_awready) aw_addr_q <= dmem_awaddr;
        end
    end

    // ---------------- DMI response monitor ----------------
    // The DM captures read data when it accepts a request, so a request
    // accepted at an edge with debug_enable_o already 0 must get the locked
    // view: only dmcontrol (0x10), dmstatus (0x11) and authdata (0x30) may be
    // nonzero, and nothing may carry a word of the drained read data.
    reg dmi_pend = 0, dmi_locked = 0;
    reg [6:0] dmi_addr_q = 0;
    reg [1:0] dmi_op_q = 0;
    always @(posedge clk) begin
        if (rst) dmi_pend = 0;
        else begin
            if (dmi_resp_valid_o && dmi_resp_ready_i && dmi_pend) begin
                if (dmi_locked && dmi_op_q == 1) begin
                    if (dmi_resp_data_o == SECRET[31:0] || dmi_resp_data_o == SECRET[63:32])
                        bad("LEAK", $sformatf("DMI read of 0x%02x after the fall returned drained data %08x",
                                              dmi_addr_q, dmi_resp_data_o));
                    else if (dmi_addr_q != 7'h10 && dmi_addr_q != 7'h11 && dmi_addr_q != 7'h30 &&
                             dmi_resp_data_o != 0)
                        bad("LOCKED", $sformatf("DMI read of 0x%02x after the fall returned %08x",
                                                dmi_addr_q, dmi_resp_data_o));
                end
                dmi_pend = 0;
            end
            if (dmi_req_valid_i && dmi_req_ready_o) begin
                dmi_pend = 1; dmi_locked = !dut.auth.debug_enable_o;
                dmi_addr_q = dmi_req_addr_i; dmi_op_q = dmi_req_op_i;
            end
        end
    end

    // ---------------- DMI driver ----------------
    reg [31:0] value;
    task dmi(input [1:0] op, input [6:0] addr, input [31:0] data, output [31:0] result);
        integer t;
        begin
            @(negedge clk);
            dmi_req_valid_i = 1; dmi_req_addr_i = addr; dmi_req_op_i = op; dmi_req_data_i = data;
            t = 0; while (!dmi_req_ready_o && t < 100) begin @(negedge clk); t = t + 1; end
            if (!dmi_req_ready_o) $fatal(1, "DMI request timeout");
            @(posedge clk); #1; @(negedge clk); dmi_req_valid_i = 0;
            t = 0; while (!dmi_resp_valid_o && t < 100) begin @(negedge clk); t = t + 1; end
            if (!dmi_resp_valid_o || dmi_resp_op_o != 0) $fatal(1, "DMI response timeout/error");
            result = dmi_resp_data_o;
            dmi_resp_ready_i = 1; @(posedge clk); #1; @(negedge clk); dmi_resp_ready_i = 0;
        end
    endtask
    task wr(input [6:0] a, input [31:0] d); reg [31:0] x; begin dmi(2, a, d, x); end endtask
    task rd(input [6:0] a, output [31:0] r); begin dmi(1, a, 0, r); end endtask

    // ---------------- setup: POR, application, authentication ----------------
    // The application (RAM at 0x8000_0000). With fwlock=1 it first polls
    // mip.MSIP without touching the data bus, then sets mdbgauth.fw_lock;
    // then it loops on an MMIO store, an MMIO load and a RAM store.
    task load_program(input bit fwlock);
        integer n;
        begin
            memory.clear_ram();
            memory.put_insn('h00, 32'h00001e97);           // auipc t4, 0x1      (RAM_CTR)
            memory.put_insn('h04, 32'h10000337);           // lui   t1, 0x10000  (MMIO)
            memory.put_insn('h08, 32'h00000393);           // li    t2, 0
            if (fwlock) begin
                memory.put_insn('h0c, 32'h344022f3);       // poll: csrr t0, mip
                memory.put_insn('h10, 32'h0082f293);       //       andi t0, t0, 8
                memory.put_insn('h14, 32'hfe028ce3);       //       beqz t0, poll
                memory.put_insn('h18, 32'h7c026073);       //       csrsi mdbgauth, 4 (fw_lock)
            end else
                for (n = 'h0c; n <= 'h18; n = n + 4) memory.put_insn(n, 32'h00000013);
            memory.put_insn('h1c, 32'h00138393);           // loop: addi t2, t2, 1
            memory.put_insn('h20, 32'h00733023);           //       sd   t2, 0(t1)
            memory.put_insn('h24, 32'h00033e03);           //       ld   t3, 0(t1)
            memory.put_insn('h28, 32'h007eb023);           //       sd   t2, 0(t4)
            memory.put_insn('h2c, 32'hff1ff06f);           //       j    loop
            memory.put_insn('h100, 32'h0000006f);          // trap handler: j .
            for (n = 0; n < 8; n = n + 1) begin
                memory.ram['h4000 + n] = SECRET[8*n +: 8];
                memory.ram['h4100 + n] = 8'h00;
                memory.ram['h4300 + n] = CANARY[8*n +: 8];
            end
        end
    endtask
    task authenticate;
        integer t;
        begin
            wr(7'h10, 1);
            wr(7'h30, 32'h10a50001);                       // REQUEST
            t = 0; rd(7'h30, value);
            while (value[4:0] < 1 && t < 5000) begin rd(7'h30, value); t = t + 1; end
            wr(7'h30, 32'h30000001);                       // RECV 1
            rd(7'h30, value); check(value == 32'hc0de0001, "PRE", "stub challenge word");
            wr(7'h30, 32'h20000001);                       // SEND 1
            wr(7'h30, 32'h600df00d);                       // the stub's TEST response
            t = 0; rd(7'h11, value);
            while (!value[7] && t < 5000) begin rd(7'h11, value); t = t + 1; end
            check(value[7], "PRE", "authenticated");
        end
    endtask
    task start(input string name, input bit fwlock);
        integer t;
        begin
            scen = name; scenarios = scenarios + 1;
            @(negedge clk); rst = 1; lc_i = 1; hold_strap_i = 1; revoke_i = 0; irq_software = 0;
            hold_r_en = 0; hold_b_en = 0; hold_a_en = 0;
            load_program(fwlock);
            repeat (5) @(negedge clk); rst = 0;
            authenticate;
            if (fwlock) begin
                t = 0;
                while (!(dut.core.ex_pc >= 64'h8000_000c && dut.core.ex_pc <= 64'h8000_0014) && t < 5000) begin
                    @(negedge clk); t = t + 1;
                end
                check(t < 5000, "PRE", "application polls mip");
            end else begin
                t = 0;
                while ((core_r < 3 || core_b < 6) && t < 5000) begin @(negedge clk); t = t + 1; end
                check(core_r >= 3 && core_b >= 6, "PRE", "application uses the data bus");
            end
        end
    endtask

    // ---------------- shared phases ----------------
    integer d_meas;
    // Revoke at the edge after negedge 2 and open the gate at negedge 2+d,
    // so the held beat is consumed d edges after the falling edge.
    task revoke_and_release(input integer d, input integer gate);  // gate 0 R, 1 B, 2 address
        integer n;
        begin
            for (n = 0; n <= 2 + (d > 0 ? d : 0); n = n + 1) begin
                @(negedge clk);
                if (n == 2) revoke_i = 1;
                if (n == 2 + d) begin
                    if (gate == 0) hold_r_en = 0;
                    else if (gate == 1) hold_b_en = 0;
                    else hold_a_en = 0;
                end
            end
        end
    endtask
    task wait_beat(input bit is_b, input integer d);
        integer t;
        begin
            t = 0;
            while ((is_b ? t_held_b : t_held_r) < 0 && t < 200) begin @(negedge clk); t = t + 1; end
            check((is_b ? t_held_b : t_held_r) >= 0, "DRAIN", "the released beat is consumed");
            t = 0;
            while (t_fall < 0 && t < 20) begin @(negedge clk); t = t + 1; end
            d_meas = (is_b ? t_held_b : t_held_r) - t_fall;
            check(t_fall >= 0 && d_meas == d, "PRE",
                  $sformatf("held beat consumed %0d edges after the fall (wanted %0d)", d_meas, d));
        end
    endtask
    // The hart's own loads and stores complete again.
    task hart_progress(input string when);
        integer t, r0, b0, w0;
        begin
            r0 = core_r; b0 = core_b; w0 = mmio_writes;
            t = 0;
            while ((core_r < r0 + 3 || core_b < b0 + 6) && t < 3000) begin @(negedge clk); t = t + 1; end
            check(core_r >= r0 + 3 && core_b >= b0 + 6, "HART",
                  $sformatf("hart loads and stores complete %s (%0d reads, %0d writes in %0d cycles)",
                            when, core_r - r0, core_b - b0, t));
            check(mmio_writes >= w0 + 3, "HART", $sformatf("hart MMIO stores land %s", when));
        end
    endtask
    task locked_view(input string when);
        integer n;
        begin
            rd(7'h11, value); check(value == 32'h00000003, "LOCKED", $sformatf("dmstatus %08x %s", value, when));
            rd(7'h10, value); check(value == 32'h00000001, "LOCKED", $sformatf("dmcontrol %08x %s", value, when));
            rd(7'h04, value); check(value == 0, "LOCKED", $sformatf("data0 %08x %s", value, when));
            for (n = 'h38; n <= 'h3f; n = n + 1) begin
                rd(7'(n), value);
                if (value == SECRET[31:0] || value == SECRET[63:32])
                    check(0, "LEAK", $sformatf("SBA register 0x%02x reads drained data %08x %s", n, value, when));
                else
                    check(value == 0, "LOCKED", $sformatf("SBA register 0x%02x reads %08x %s", n, value, when));
            end
        end
    endtask
    // Every SBA trigger a debugger has: an sbdata0 write, an sbaddress0 write
    // with sbreadonaddr, an sbdata0 read with sbreadondata.
    task launch_attempts;
        integer ar0, aw0;
        begin
            ar0 = sba_ar; aw0 = sba_aw;
            wr(7'h38, 32'h00467000);                       // clear errors, sbaccess=64
            wr(7'h39, SBA_CANARY);
            wr(7'h3d, 32'hbadc0de0); wr(7'h3c, 32'hbadc0de1);
            repeat (100) @(negedge clk);
            wr(7'h38, 32'h0056f000);                       // + sbreadonaddr, sbreadondata
            wr(7'h39, SBA_CANARY);
            repeat (100) @(negedge clk);
            rd(7'h3c, value);
            repeat (200) @(negedge clk);
            check(sba_ar == ar0 && sba_aw == aw0, "LAUNCH",
                  $sformatf("no SBA access after the fall (%0d AR, %0d AW)", sba_ar - ar0, sba_aw - aw0));
            check(memory.ram_word(SBA_CANARY) == CANARY, "LAUNCH", "post-fall SBA write target unchanged");
        end
    endtask
    task finish_scenario(input integer kind, input integer d);
        begin
            // The drained transfer alone: one AR and one R, or one AW, one W
            // and one B; none at all for a request withdrawn before the bus.
            check(kind == K_PENDING ? (sba_ar == 0 && sba_r == 0 && sba_aw == 0 && sba_b == 0) :
                  kind == K_HALTED ? (sba_ar == 1 && sba_r == 0 && sba_aw == 0 && sba_b == 0) :
                  (kind == K_WRITE || kind == K_ADDR_W) ?
                                    (sba_aw == 1 && sba_w == 1 && sba_b == 1 && sba_ar == 0 && sba_r == 0) :
                                    (sba_ar == 1 && sba_r == 1 && sba_aw == 0 && sba_b == 0), "DRAIN",
                  $sformatf("SBA handshakes at the drain: %0d AR, %0d R, %0d AW, %0d W, %0d B",
                            sba_ar, sba_r, sba_aw, sba_w, sba_b));
            hart_progress("after the drain");
            locked_view("after the drain");
            launch_attempts;
            locked_view("after the attempts");
            hart_progress("after the attempts");
            if (kind == K_HALTED) check(relock_seen, "PRE", "the relock reset fired: the hart was halted");
            else check(!relock_seen, "PRE", "no relock reset: the hart was running");
            if (kind == K_HALTED)
                $display("scenario %s: SBA AR accepted on the bus at edge %0d, fall at edge %0d, relock reset at %s cancelled it; R never returned",
                         scen, t_sba_ar, t_fall, off(d_meas));
            else if (kind == K_PENDING)
                $display("scenario %s: SBA request waiting for the bus at the fall (edge %0d); core beat consumed at %s; no SBA beat on the bus",
                         scen, t_fall, off(d_meas));
            else if (kind == K_ADDR_R)
                $display("scenario %s: SBA AR presented from edge %0d, fall at edge %0d, AR accepted at %s, R at %s",
                         scen, t_ar_pre, t_fall, off(t_sba_ar - t_fall), off(t_sba_r - t_fall));
            else if (kind == K_ADDR_W)
                $display("scenario %s: SBA AW presented from edge %0d, fall at edge %0d, AW accepted at %s, B at %s",
                         scen, t_aw_pre, t_fall, off(t_sba_aw - t_fall), off(t_sba_b - t_fall));
            else if (kind == K_WRITE)
                $display("scenario %s: SBA AW accepted on the bus at edge %0d, fall at edge %0d, held B consumed at %s",
                         scen, t_sba_aw, t_fall, off(d_meas));
            else
                $display("scenario %s: SBA AR accepted on the bus at edge %0d, fall at edge %0d, held R consumed at %s",
                         scen, t_sba_ar, t_fall, off(d_meas));
        end
    endtask

    // ---------------- scenarios ----------------
    // Authorized baseline: the same held read and write without revocation
    // complete with their data, so the secret is reachable while debug is
    // enabled and the gate, attribution and counts of this bench work.
    task baseline;
        integer t;
        reg [31:0] lo, hi;
        begin
            start("authorized baseline", 0);
            hold_r_addr = SBA_RD; hold_r_en = 1;
            wr(7'h38, 32'h00160000);                       // sbreadonaddr, sbaccess=64
            wr(7'h39, SBA_RD);
            repeat (60) @(negedge clk);
            check(sba_ar == 1 && t_held_r < 0, "PRE", "baseline read is held");
            rd(7'h38, value); check(value[21], "PRE", "sbbusy while the read is held");
            hold_r_en = 0;
            t = 0; rd(7'h38, value);
            while (value[21] && t < 100) begin rd(7'h38, value); t = t + 1; end
            rd(7'h3d, hi); rd(7'h3c, lo);
            check({hi, lo} == SECRET && value[14:12] == 0, "PRE", "authorized SBA read returns the data");
            hold_b_addr = SBA_WR; hold_b_en = 1;
            wr(7'h38, 32'h00060000);
            wr(7'h39, SBA_WR); wr(7'h3d, WVAL[63:32]); wr(7'h3c, WVAL[31:0]);
            repeat (60) @(negedge clk);
            check(sba_aw == 1 && sba_w == 1 && t_held_b < 0, "PRE", "baseline write is held");
            hold_b_en = 0;
            t = 0; rd(7'h38, value);
            while (value[21] && t < 100) begin rd(7'h38, value); t = t + 1; end
            check(!value[21] && value[14:12] == 0 && memory.ram_word(SBA_WR) == WVAL, "PRE",
                  "authorized SBA write completes");
            check(sba_ar == 1 && sba_r == 1 && sba_aw == 1 && sba_b == 1, "PRE", "baseline handshakes");
            hart_progress("in the baseline");
        end
    endtask
    // An SBA read (or write) accepted on the bus, its R (B) beat held, then
    // revoke_i (or the hart's fw_lock) while the beat is held.
    task in_flight(input integer kind, input integer d);
        integer t;
        reg is_b;
        begin
            is_b = kind == K_WRITE;
            if (is_b) start($sformatf("SBA write, revoke_i, beat at %s", off(d)), 0);
            else if (kind == K_FWLOCK) start($sformatf("SBA read, hart fw_lock, beat at %s", off(d)), 1);
            else start($sformatf("SBA read, revoke_i, beat at %s", off(d)), 0);
            if (is_b) begin
                hold_b_addr = SBA_WR; hold_b_en = 1;
                wr(7'h38, 32'h00060000);                   // sbaccess=64
                wr(7'h39, SBA_WR); wr(7'h3d, WVAL[63:32]); wr(7'h3c, WVAL[31:0]);
            end else begin
                hold_r_addr = SBA_RD; hold_r_en = 1;
                wr(7'h38, 32'h00160000);                   // sbreadonaddr, sbaccess=64
                wr(7'h39, SBA_RD);
            end
            t = 0;
            while (!(is_b ? (sba_aw == 1 && sba_w == 1 && hold_b && ram_dmem_bvalid)
                          : (sba_ar == 1 && hold_r && ram_dmem_rvalid)) && t < 3000) begin
                @(negedge clk); t = t + 1;
            end
            check(t < 3000, "PRE", "SBA transfer accepted and its beat held");
            rd(7'h38, value); check(value[21], "PRE", "sbbusy before the fall");
            check(dut.auth.debug_enable_o && t_fall < 0, "PRE", "debug enabled before the fall");
            if (kind == K_FWLOCK) begin
                // The hart sets fw_lock when it sees MSIP; the gate opens d
                // edges after the falling edge it produces.
                @(negedge clk); irq_software = 1;
                t = 0;
                while (dut.auth.debug_enable_o && t < 2000) begin @(negedge clk); t = t + 1; end
                check(!dut.auth.debug_enable_o && !revoke_i, "PRE", "the hart's fw_lock revoked debug");
                repeat (d - 1) @(negedge clk);
                hold_r_en = 0;
            end else revoke_and_release(d, is_b);
            wait_beat(is_b, d);
            if (is_b) check(memory.ram_word(SBA_WR) == WVAL, "DRAIN", "the accepted SBA write completed");
            finish_scenario(kind, d);
        end
    endtask
    // The DM has a request that the bus has not yet accepted (the hart's
    // MMIO load holds the bus, its R beat held) when revoke_i falls: the
    // request must be withdrawn, never reaching the bus.
    task pending(input integer d);
        integer t;
        begin
            start($sformatf("SBA read waiting for the bus, revoke_i, core beat at %s", off(d)), 0);
            // Arm the gate with no read outstanding, so no shown beat is hidden.
            t = 0;
            while (r_out && t < 100) begin @(negedge clk); t = t + 1; end
            hold_r_addr = MMIO; hold_r_en = 1;
            t = 0;
            while (!(hold_r && ram_dmem_rvalid) && t < 3000) begin @(negedge clk); t = t + 1; end
            check(t < 3000, "PRE", "the hart's MMIO load is held");
            wr(7'h38, 32'h00160000);
            wr(7'h39, SBA_RD);
            repeat (20) @(negedge clk);
            rd(7'h38, value);
            check(value[21] && sba_ar == 0 && dut.auth.debug_enable_o, "PRE", "SBA request waits for the bus");
            revoke_and_release(d, 0);
            wait_beat(0, d);
            finish_scenario(K_PENDING, d);
        end
    endtask

    // The SBA transfer is accepted by the bus arbiter, but its AR (or AW,
    // with W behind it) is still stalled at the fabric when revoke_i falls.
    // The address is released d edges after the fall: the transfer must
    // finish (one address, one response) and its data stay hidden.
    task addr_phase(input bit is_b, input integer d);
        integer t;
        begin
            start($sformatf("SBA %s stalled at the fall, revoke_i, released at %s",
                            is_b ? "AW" : "AR", off(d)), 0);
            hold_a_addr = is_b ? SBA_WR : SBA_RD; hold_a_en = 1;
            if (is_b) begin
                wr(7'h38, 32'h00060000);
                wr(7'h39, SBA_WR); wr(7'h3d, WVAL[63:32]); wr(7'h3c, WVAL[31:0]);
            end else begin
                wr(7'h38, 32'h00160000);
                wr(7'h39, SBA_RD);
            end
            t = 0;
            while (!(is_b ? aw_pre : ar_pre) && t < 3000) begin @(negedge clk); t = t + 1; end
            repeat (4) @(negedge clk);
            check((is_b ? aw_pre : ar_pre) && sba_ar == 0 && sba_aw == 0, "PRE", "SBA address stalled at the fabric");
            rd(7'h38, value); check(value[21], "PRE", "sbbusy before the fall");
            revoke_and_release(d, 2);
            t = 0;
            while ((is_b ? sba_b : sba_r) == 0 && t < 300) begin @(negedge clk); t = t + 1; end
            check((is_b ? sba_b : sba_r) == 1, "DRAIN", "the stalled transfer completes after the fall");
            check((is_b ? t_sba_aw : t_sba_ar) > t_fall && t_fall >= 0, "PRE", "address accepted after the fall");
            if (is_b) check(memory.ram_word(SBA_WR) == WVAL, "DRAIN", "the accepted SBA write completed");
            finish_scenario(is_b ? K_ADDR_W : K_ADDR_R, d);
        end
    endtask

    // The hart is in Debug Mode and the responder withholds the R beat of an
    // accepted SBA read for good. Revocation cannot drain it; the relock
    // reset (plan 3.5 item 3) resets the hart, the dmem port and, as an
    // integration must, the responder, which cancels the transfer within a
    // few cycles. The beat is never consumed, nothing reaches the debugger,
    // and the hart reruns the ROM (window closed) into the application.
    task halted_in_flight;
        integer t;
        begin
            start("SBA read, hart in Debug Mode, revoke_i, R withheld", 0);
            wr(7'h10, 32'h80000001);
            t = 0;
            while (!(debug_mode_o && dut.dm.parked_q) && t < 20000) begin @(negedge clk); t = t + 1; end
            check(debug_mode_o, "PRE", "hart halted in Debug Mode");
            hold_r_addr = SBA_RD; hold_r_en = 1;
            wr(7'h38, 32'h00160000);
            wr(7'h39, SBA_RD);
            t = 0;
            while (!(sba_ar == 1 && hold_r && ram_dmem_rvalid) && t < 3000) begin @(negedge clk); t = t + 1; end
            check(t < 3000, "PRE", "SBA read accepted and its beat held");
            rd(7'h38, value); check(value[21], "PRE", "sbbusy before the fall");
            @(negedge clk); revoke_i = 1;
            t = 0;
            while (!auth_reset_o && t < 50) begin @(negedge clk); t = t + 1; end
            d_meas = edge_n - t_fall;
            check(auth_reset_o && d_meas <= 4, "DRAIN",
                  $sformatf("relock reset within 4 cycles of the fall (%0d)", d_meas));
            while (auth_reset_o && t < 100) begin @(negedge clk); t = t + 1; end
            check(!ram_dmem_rvalid && sba_r == 0, "DRAIN", "the withheld beat was cancelled, never consumed");
            hold_r_en = 0;
            finish_scenario(K_HALTED, 0);
            check(!debug_mode_o, "PRE", "the hart left Debug Mode");
        end
    endtask

    integer i;
    integer sweep [0:6];
    initial begin
        sweep[0] = -1; sweep[1] = 0; sweep[2] = 1; sweep[3] = 2; sweep[4] = 3; sweep[5] = 8; sweep[6] = 40;
        baseline;
        for (i = 0; i < 7; i = i + 1) in_flight(K_READ, sweep[i]);
        for (i = 0; i < 7; i = i + 1) in_flight(K_WRITE, sweep[i]);
        in_flight(K_FWLOCK, 1);
        in_flight(K_FWLOCK, 6);
        pending(0);
        pending(3);
        addr_phase(0, 1);
        addr_phase(0, 4);
        addr_phase(1, 1);
        addr_phase(1, 4);
        halted_in_flight;
        check(cov_ar_stall > 0 && cov_aw_stall > 0 && cov_w_stall > 0, "PRE",
              $sformatf("the monitor saw stalled AR, AW and W (%0d, %0d, %0d cycles)",
                        cov_ar_stall, cov_aw_stall, cov_w_stall));
        if (errors != 0)
            $fatal(1, "karudbg auth SBA revocation: FAIL (%0d of %0d checks)", errors, checks);
        $display("karudbg auth SBA revocation: PASS (%0d checks, %0d scenarios)", checks, scenarios);
        $finish;
    end
    initial begin #50000000; $fatal(1, "auth sba revoke: global timeout"); end
endmodule
