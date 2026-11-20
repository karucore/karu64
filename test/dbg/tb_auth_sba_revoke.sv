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
//
// The bench is simulator-neutral: four-state with Icarus (the make target)
// and two-state with Verilator, with and without KARU_ICACHE and the vector
// unit (test/dbg/run_auth_revoke_ext.py). In a build with the vector unit
// the application also stores and loads a vector, the load from an uncached
// page, so the vector load/store unit shares the data bus with the SBA.
//
// With AUTH_REVOKE_XBAR the responder is the VCU118 crossbar,
// flow/fpga/karu_ddr_xbar.v, with its devices and, behind its DDR port, the
// AXI memory model flow/fpga/karu_axi4_ram.v, connected and reset as in
// flow/fpga/fpga_ddr_top.v. The checks stay on the core's dmem port and the
// DMI. A beat of a main-memory transfer is then held on the DDR side of the
// crossbar, which keeps the crossbar's own read or write engine busy across
// the falling edge; the hart's device register is the CLINT's mtimecmp; and
// the scenarios in which the hart must keep running read the boot scratch
// SRAM instead, because an outstanding main-memory read also blocks the
// hart's fetches there. Further scenarios hold the address on the DDR port,
// hold a main-memory beat on the core side of the crossbar, and read and
// write the scratch SRAM (the crossbar's local engines). The crossbar's own
// assertions (SIM_TB) must stay silent.
//
// With AUTH_REVOKE_JTAG the debugger drives TCK, TMS and TDI of the JTAG
// transport, dbg/karudbg_jtag.v, instead of the DMI, and reads its results
// from TDO; the DMI checks then observe the transport's side of the DM.
// Further scenarios revoke while a read of sbdata0 is crossing the
// transport, so that the DM accepts it one edge after the falling edge of
// debug_enable, at that edge, and up to three edges before it.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karudbg_defs.vh"
`include "karu_bootmap.vh"
`include "rtl/karu_assert.sv"
module tb_auth_sba_revoke #(parameter ROM_HEX = "rom.hex",
                            parameter XBAR_ROM_HEX = "xbar_rom.hex",   // AUTH_REVOKE_XBAR: any small image
                            parameter integer DDR_RLAT = 1);           // and the DDR model's read latency
    reg clk = 0, rst = 1;
    always #5 clk = !clk;
    wire debug_mode_o, debug_resume_ack_o, trap;
    reg irq = 0, irq_software = 0, irq_external_m = 0, irq_external_s = 0;
    reg [63:0] time_in = 0;
`ifdef KARU_EN_V
    // The application's vector load comes from this page, past the D-cache.
    reg [31:0] uncache_page = 32'h8000_2000, hpm_events = 0;
`else
    reg [31:0] uncache_page = 0, hpm_events = 0;
`endif
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
    wire dmi_req_ready_o, dmi_resp_valid_o, ndmreset_o;
`ifdef AUTH_REVOKE_JTAG
    // The debugger is on the JTAG side of the transport, dbg/karudbg_jtag.v
    // (TAP, DTM and clock-domain crossing), as in dbg/karudbg_top.v. The DMI
    // signals the checks observe are then the transport's.
    reg hart_reset_i = 0;
    reg tck = 0, tms = 1, tdi = 0, trst_n = 1;
    wire tdo, tdo_oe;
    // The transport's TCK-side registers have an asynchronous reset (TRST or
    // the power-on reset), which a simulator applies on an edge: the
    // power-on reset is asserted 1 ns into the run, before any clock edge.
    initial begin rst = 0; #1 rst = 1; end
    wire dmi_reset_i, dmi_req_valid_i, dmi_resp_ready_i;
    wire [6:0] dmi_req_addr_i;
    wire [1:0] dmi_req_op_i;
    wire [31:0] dmi_req_data_i;
`else
    reg hart_reset_i = 0, dmi_reset_i = 0, dmi_req_valid_i = 0, dmi_resp_ready_i = 0;
    reg [6:0] dmi_req_addr_i = 0;
    reg [1:0] dmi_req_op_i = 0;
    reg [31:0] dmi_req_data_i = 0;
`endif
    wire [31:0] dmi_resp_data_o;
    wire [1:0] dmi_resp_op_o;
    reg [1:0] lc_i = 2'd1;
    reg hold_strap_i = 1'b1, revoke_i = 1'b0;
    wire auth_reset_o;
    karudbg_core #(.RESET_PC(64'h0001_0000), .ISLAND_ROM_HEX(ROM_HEX)) dut (.*);
`ifdef AUTH_REVOKE_JTAG
    karudbg_jtag dtm (.clk(clk), .rst(rst), .tck(tck), .tms(tms), .tdi(tdi), .trst_n(trst_n),
        .tdo(tdo), .tdo_oe(tdo_oe), .dmi_reset_o(dmi_reset_i),
        .req_valid_o(dmi_req_valid_i), .req_ready_i(dmi_req_ready_o), .req_addr_o(dmi_req_addr_i),
        .req_op_o(dmi_req_op_i), .req_data_o(dmi_req_data_i),
        .resp_valid_i(dmi_resp_valid_o), .resp_ready_o(dmi_resp_ready_i),
        .resp_data_i(dmi_resp_data_o), .resp_op_i(dmi_resp_op_o));
`endif
`ifndef AUTH_REVOKE_XBAR
    wire [31:0] mmio_reads, mmio_writes;
    wire [63:0] mmio_value;
`endif

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
`ifdef AUTH_REVOKE_XBAR
    // The gate for a main-memory address (bit 31) is on the DDR side of the
    // crossbar, below, unless gate_m is 0.
    reg gate_m = 1;
    wire r_at_m = gate_m && hold_r_addr[31];
    wire b_at_m = gate_m && hold_b_addr[31];
    wire a_at_m = gate_m && hold_a_addr[31];
`else
    wire r_at_m = 1'b0, b_at_m = 1'b0, a_at_m = 1'b0;
`endif
    wire hold_r = hold_r_en && !r_at_m && ar_addr_q == hold_r_addr;
    wire hold_b = hold_b_en && !b_at_m && aw_addr_q == hold_b_addr;
    assign dmem_rvalid = ram_dmem_rvalid && !hold_r;
    assign ram_dmem_rready = dmem_rready && !hold_r;
    assign dmem_bvalid = ram_dmem_bvalid && !hold_b;
    assign ram_dmem_bready = dmem_bready && !hold_b;
    wire hold_ar = hold_a_en && !a_at_m && dmem_araddr == hold_a_addr;
    wire hold_aw = hold_a_en && !a_at_m && dmem_awaddr == hold_a_addr;
    assign ram_dmem_arvalid = dmem_arvalid && !hold_ar;
    assign dmem_arready = ram_dmem_arready && !hold_ar;
    assign ram_dmem_awvalid = dmem_awvalid && !hold_aw;
    assign dmem_awready = ram_dmem_awready && !hold_aw;
`ifdef AUTH_REVOKE_XBAR
    // The crossbar and the DDR port have the system reset of
    // flow/fpga/fpga_ddr_top.v: the power-on reset, ndmreset and the
    // authentication block's reset (boot hold and relock).
    wire soc_rst = rst || hart_reset_i || ndmreset_o || auth_reset_o;
    wire [`AXI_ID_W-1:0] m_arid, m_rid, m_awid, m_bid;
    wire [`AXI_ADDR_W-1:0] m_araddr, m_awaddr;
    wire [`AXI_LEN_W-1:0] m_arlen, m_awlen;
    wire [`AXI_SIZE_W-1:0] m_arsize, m_awsize;
    wire [`AXI_BURST_W-1:0] m_arburst, m_awburst;
    wire [`AXI_PROT_W-1:0] m_arprot, m_awprot;
    wire [`AXI_DATA_W-1:0] m_rdata, m_wdata;
    wire [`AXI_RESP_W-1:0] m_rresp, m_bresp;
    wire [`AXI_STRB_W-1:0] m_wstrb;
    wire m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    wire m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
    // The same gates on the DDR port, between the crossbar (m_*) and the
    // memory model (ddr_*). The model answers an address two cycles later
    // at the earliest, so a gate closes before its beat can be presented.
    wire ddr_arvalid, ddr_arready, ddr_rvalid, ddr_rready;
    wire ddr_awvalid, ddr_awready, ddr_bvalid, ddr_bready;
    reg [31:0] m_ar_addr_q = 0, m_aw_addr_q = 0;
    wire hold_mr = hold_r_en && r_at_m && m_ar_addr_q == hold_r_addr;
    wire hold_mb = hold_b_en && b_at_m && m_aw_addr_q == hold_b_addr;
    wire hold_mar = hold_a_en && a_at_m && m_araddr == hold_a_addr;
    wire hold_maw = hold_a_en && a_at_m && m_awaddr == hold_a_addr;
    assign m_rvalid = ddr_rvalid && !hold_mr;
    assign ddr_rready = m_rready && !hold_mr;
    assign m_bvalid = ddr_bvalid && !hold_mb;
    assign ddr_bready = m_bready && !hold_mb;
    assign ddr_arvalid = m_arvalid && !hold_mar;
    assign m_arready = ddr_arready && !hold_mar;
    assign ddr_awvalid = m_awvalid && !hold_maw;
    assign m_awready = ddr_awready && !hold_maw;
    always @(posedge clk) begin
        if (soc_rst) begin m_ar_addr_q <= 0; m_aw_addr_q <= 0; end
        else begin
            if (m_arvalid && m_arready) m_ar_addr_q <= m_araddr;
            if (m_awvalid && m_awready) m_aw_addr_q <= m_awaddr;
        end
    end
    // A held beat that the responder presents (either gate).
    wire held_r_shown = (hold_r && ram_dmem_rvalid) || (hold_mr && ddr_rvalid);
    wire held_b_shown = (hold_b && ram_dmem_bvalid) || (hold_mb && ddr_bvalid);
    wire resp_r_shown = ram_dmem_rvalid || ddr_rvalid;
    // The crossbar's interrupt outputs are left open: the bench drives the
    // core's interrupt inputs, as it does with the test RAM model.
    karu_ddr_xbar #(.CPU_CLK_HZ(100000000), .ROM_HEX(XBAR_ROM_HEX)) xbar (.*, .rst(soc_rst),
        .dmem_rvalid(ram_dmem_rvalid), .dmem_rready(ram_dmem_rready),
        .dmem_bvalid(ram_dmem_bvalid), .dmem_bready(ram_dmem_bready),
        .dmem_arvalid(ram_dmem_arvalid), .dmem_arready(ram_dmem_arready),
        .dmem_awvalid(ram_dmem_awvalid), .dmem_awready(ram_dmem_awready),
        .uart_txd(), .uart_rxd(1'b1), .uart_rts(), .uart_cts(1'b0),
        .irq_timer(), .irq_software(), .irq_ext_m(), .irq_ext_s(), .clint_mtime(),
        .sys_reset_req_o(), .sysreg_re_o(), .sysreg_raddr_o(), .sysreg_rdata_i(64'b0),
        .sysreg_we_o(), .sysreg_waddr_o(), .sysreg_wdata_o());
    karu_axi4_ram #(.RAM_XADR(16), .MEM_BASE(32'h8000_0000), .RLAT(DDR_RLAT), .HEXFILE("")) ddr (
        .clk(clk), .rst(soc_rst),
        .s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arsize(m_arsize), .s_arburst(m_arburst),
        .s_arvalid(ddr_arvalid), .s_arready(ddr_arready),
        .s_rid(m_rid), .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast),
        .s_rvalid(ddr_rvalid), .s_rready(ddr_rready),
        .s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awsize(m_awsize), .s_awburst(m_awburst),
        .s_awvalid(ddr_awvalid), .s_awready(ddr_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast), .s_wvalid(m_wvalid), .s_wready(m_wready),
        .s_bid(m_bid), .s_bresp(m_bresp), .s_bvalid(ddr_bvalid), .s_bready(ddr_bready));
    // The hart's device register is the CLINT's mtimecmp; its stores are
    // counted where the CLINT takes them.
    integer mmio_writes = 0;
    always @(posedge clk) if (!soc_rst && xbar.clint_we) mmio_writes <= mmio_writes + 1;
`else
    wire held_r_shown = hold_r && ram_dmem_rvalid;
    wire held_b_shown = hold_b && ram_dmem_bvalid;
    wire resp_r_shown = ram_dmem_rvalid;
    // The responder is reset with the relock reset too, as karudbg_core
    // requires of an integration (it never fires here: the hart runs).
    karudbg_test_ram memory (.*, .fifo_count(), .hart_reset_i(hart_reset_i || auth_reset_o),
        .dmem_rvalid(ram_dmem_rvalid), .dmem_rready(ram_dmem_rready),
        .dmem_bvalid(ram_dmem_bvalid), .dmem_bready(ram_dmem_bready),
        .dmem_arvalid(ram_dmem_arvalid), .dmem_arready(ram_dmem_arready),
        .dmem_awvalid(ram_dmem_awvalid), .dmem_awready(ram_dmem_awready));
`endif
    always @(posedge clk) cache_flush_done <= cache_flush_req && !rst;
    `include "test/dbg/trigger_checker.vh"

    localparam [31:0] SBA_RD = 32'h8000_4000;      // SBA read target: the secret
    localparam [31:0] SBA_WR = 32'h8000_4100;      // SBA write target
    localparam [31:0] SBA_CANARY = 32'h8000_4300;  // target of every post-fall attempt
`ifdef AUTH_REVOKE_XBAR
    localparam [31:0] MMIO = 32'h0200_4000;        // the hart's device register: CLINT mtimecmp
    localparam [31:0] MMIO_LUI = 32'h02004337;     // lui t1, 0x2004
    // SBA targets in the boot scratch SRAM, which the crossbar serves itself.
    localparam [31:0] SCR_RD = {`KARU_BOOT_SCRATCH_LO, 12'h100};
    localparam [31:0] SCR_WR = {`KARU_BOOT_SCRATCH_LO, 12'h180};
`else
    localparam [31:0] MMIO = 32'h1000_0000;        // the hart's device register
    localparam [31:0] MMIO_LUI = 32'h10000337;     // lui t1, 0x10000
`endif
    localparam [31:0] APP = 32'h8000_0000;         // the hart's application
    localparam [31:0] RAM_CTR = 32'h8000_1000;     // the hart's RAM store
    localparam [31:0] VEC_ST = 32'h8000_1040;      // its vector store and, in the uncached
    localparam [31:0] VEC_LD = 32'h8000_2000;      // page, its vector load (KARU_EN_V)
    localparam [63:0] SECRET = 64'ha5ec2e70_d2a14ed7;
    localparam [63:0] WVAL = 64'h0bad5eed_6a7e0d17;
    localparam [63:0] CANARY = 64'hca7a5ca7_ca7a5ca7;
    localparam integer K_READ = 0, K_WRITE = 1, K_FWLOCK = 2, K_PENDING = 3, K_ADDR_R = 4, K_ADDR_W = 5,
                       K_HALTED = 6;
    // Where a scenario puts its SBA target and its gate. Only W_STD exists
    // with the test RAM model. With the crossbar: W_STD is main memory with
    // the gate on the DDR port, W_PORT main memory with the gate on the
    // core's dmem port, W_SCRATCH the boot scratch SRAM (gate on the dmem
    // port; the crossbar's main-memory read engine stays free for fetches).
    localparam integer W_STD = 0, W_PORT = 1, W_SCRATCH = 2;
`ifdef AUTH_REVOKE_XBAR
    localparam integer W_RUN = W_SCRATCH;    // read target while the hart must keep fetching
    localparam integer W_FABRIC = W_PORT;    // address stalled between the core and the responder
    localparam integer PEND_GATE = 1;        // the hart's beat that keeps the SBA waiting: B
`else
    localparam integer W_RUN = W_STD, W_FABRIC = W_STD;
    localparam integer PEND_GATE = 0;        // the hart's beat that keeps the SBA waiting: R
`endif
    // An SBA access is recognised by its address alone: the hart never
    // touches these pages.
    function automatic sba_page(input [31:0] a);
`ifdef AUTH_REVOKE_XBAR
        sba_page = a[31:12] == SBA_RD[31:12] || a[31:12] == SCR_RD[31:12];
`else
        sba_page = a[31:12] == SBA_RD[31:12];
`endif
    endfunction
    // The SBA read and write targets of the current scenario.
    reg [31:0] rd_a = SBA_RD, wr_a = SBA_WR;

    // Backdoor access to the responder's memory, by address.
`ifdef AUTH_REVOKE_XBAR
    task mem_clear;
        integer j;
        begin
            for (j = 0; j < 8192; j = j + 1) begin ddr.ram[j] = 64'b0; xbar.u_boot_mem.sram[j] = 64'b0; end
        end
    endtask
    function automatic [63:0] mem_word(input [31:0] a);
        mem_word = a[31] ? ddr.ram[a[15:3]] : xbar.u_boot_mem.sram[a[15:3] - 13'h200];
    endfunction
    task mem_byte(input [31:0] a, input [7:0] v);
        reg [63:0] w;
        begin
            w = mem_word(a);
            w[8*a[2:0] +: 8] = v;
            if (a[31]) ddr.ram[a[15:3]] = w;
            else xbar.u_boot_mem.sram[a[15:3] - 13'h200] = w;
        end
    endtask
`else
    task mem_clear; begin memory.clear_ram(); end endtask
    function automatic [63:0] mem_word(input [31:0] a);
        mem_word = memory.ram_word(a);
    endfunction
    task mem_byte(input [31:0] a, input [7:0] v); begin memory.ram[a[15:0]] = v; end endtask
`endif
    task mem_insn(input [31:0] a, input [31:0] insn);
        integer n;
        begin for (n = 0; n < 4; n = n + 1) mem_byte(a + n, insn[8*n +: 8]); end
    endtask

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
    reg [31:0] aw_cur = 0;                   // address of the write the W beats belong to
    integer sba_ar = 0, sba_aw = 0, sba_w = 0, sba_r = 0, sba_b = 0;
    integer t_sba_ar = -1, t_sba_aw = -1, t_sba_r = -1, t_sba_b = -1;
    integer t_held_r = -1, t_held_b = -1;   // edge at which a held beat was consumed
    reg r_was_held = 0, b_was_held = 0;
    integer core_r = 0, core_b = 0;          // completed core transactions
    integer cov_ar_stall = 0, cov_aw_stall = 0, cov_w_stall = 0;  // monitor coverage, whole run
    integer cov_vec_ld = 0, cov_vec_st = 0;  // the hart's vector loads and stores (KARU_EN_V)
    reg relock_seen = 0, ar_pre = 0, aw_pre = 0;
    integer t_ar_pre = -1, t_aw_pre = -1;    // first cycle a pre-fall SBA address was presented
`ifdef AUTH_REVOKE_XBAR
    // The DDR port: edge at which it accepted an SBA address, and what the
    // crossbar was doing for the SBA in the first locked cycle (coverage of
    // the whole run): main-memory read with its data outstanding or its
    // address stalled, main-memory write outstanding or its address stalled,
    // local (scratch SRAM) read and write, and a read cut by the relock reset.
    integer t_m_ar = -1, t_m_aw = -1;
    integer cov_x_rd = 0, cov_x_ar = 0, cov_x_wr = 0, cov_x_aw = 0, cov_x_lr = 0, cov_x_lw = 0, cov_x_reset = 0;
`endif
    always @(posedge clk) begin
        edge_n = edge_n + 1;
        if (rst) begin
            en_prev = 0; t_fall = -1; r_out = 0; aw_out = 0;
            ar_stall = 0; aw_stall = 0; w_stall = 0; r_shown = 0; b_shown = 0;
            sba_ar = 0; sba_aw = 0; sba_w = 0; sba_r = 0; sba_b = 0;
            t_sba_ar = -1; t_sba_aw = -1; t_sba_r = -1; t_sba_b = -1;
            t_held_r = -1; t_held_b = -1; r_was_held = 0; b_was_held = 0;
            core_r = 0; core_b = 0; relock_seen = 0; ar_pre = 0; aw_pre = 0; t_ar_pre = -1; t_aw_pre = -1;
`ifdef AUTH_REVOKE_XBAR
            t_m_ar = -1; t_m_aw = -1;
`endif
        end else begin
            if (en_prev && !dut.auth.debug_enable_o) t_fall = edge_n - 1;
`ifdef AUTH_REVOKE_XBAR
            // (crossbar states: dr_st 1 address, 2 data; owner 2 dmem; w_st 0
            // idle, 1 main memory, 2 local response; lr_st 0 idle)
            if (en_prev && !dut.auth.debug_enable_o) begin
                if (xbar.dr_own == 2'd2 && sba_page(xbar.dr_araddr)) begin
                    if (xbar.dr_st == 2'd2) cov_x_rd = cov_x_rd + 1;
                    if (xbar.dr_st == 2'd1) cov_x_ar = cov_x_ar + 1;
                end
                if (xbar.w_st == 2'd1 && sba_page(aw_addr_q)) cov_x_wr = cov_x_wr + 1;
                if (xbar.w_st == 2'd0 && m_awvalid && !m_awready && sba_page(m_awaddr)) cov_x_aw = cov_x_aw + 1;
                if (xbar.lr_st != 2'd0 && xbar.lr_own == 2'd2 && sba_page(xbar.boot_dmem_addr)) cov_x_lr = cov_x_lr + 1;
                if (xbar.w_st == 2'd2 && sba_page(aw_addr_q)) cov_x_lw = cov_x_lw + 1;
            end
            if (auth_reset_o && !rst && xbar.dr_st == 2'd2 && xbar.dr_own == 2'd2 && sba_page(xbar.dr_araddr))
                cov_x_reset = cov_x_reset + 1;
            if (!soc_rst) begin
                if (m_arvalid && m_arready && sba_page(m_araddr)) t_m_ar = edge_n;
                if (m_awvalid && m_awready && sba_page(m_awaddr)) t_m_aw = edge_n;
                // The target of the post-fall attempts never reaches the DDR port.
                if ((m_arvalid && m_araddr[31:3] == SBA_CANARY[31:3]) || (m_awvalid && m_awaddr[31:3] == SBA_CANARY[31:3]))
                    bad("LAUNCH", "the target of the post-fall attempts was presented on the DDR port");
            end
`endif
            en_prev = dut.auth.debug_enable_o;
            if (auth_reset_o && dut.auth.auth_unlock_q) relock_seen = 1;
`ifdef AUTH_REVOKE_XBAR
            // The crossbar decodes ARREADY and AWREADY from the address, which
            // is unknown after a reset until the hart's first access: a READY
            // may be X while its VALID is low, and only then.
            if ((^{dmem_arvalid, dmem_rvalid, dmem_awvalid, dmem_wvalid, dmem_bvalid,
                   dmi_req_ready_o, dmi_resp_valid_o}) === 1'bx ||
                (dmem_arvalid && dmem_arready === 1'bx) || (dmem_rvalid && dmem_rready === 1'bx) ||
                (dmem_awvalid && dmem_awready === 1'bx) || (dmem_wvalid && dmem_wready === 1'bx) ||
                (dmem_bvalid && dmem_bready === 1'bx))
`else
            if ((^{dmem_arvalid, dmem_arready, dmem_rvalid, dmem_rready, dmem_awvalid, dmem_awready,
                   dmem_wvalid, dmem_wready, dmem_bvalid, dmem_bready, dmi_req_ready_o, dmi_resp_valid_o}) === 1'bx)
`endif
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
                    if (dmem_araddr[31:12] == VEC_LD[31:12]) cov_vec_ld = cov_vec_ld + 1;
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
                    aw_out = 1; w_len = dmem_awlen; w_beats = 0; aw_cur = dmem_awaddr;
                    if (dmem_awaddr[31:6] == VEC_ST[31:6]) cov_vec_st = cov_vec_st + 1;
                    if (sba_page(dmem_awaddr)) begin
                        sba_aw = sba_aw + 1; t_sba_aw = edge_n;
                        if (!dut.auth.debug_enable_o && !aw_pre)
                            bad("LAUNCH", $sformatf("SBA AW to %08x after the fall", dmem_awaddr));
                    end
                    aw_pre = 0;
                end
                if (dmem_wvalid && dmem_wready) begin
                    // The responders accept W after AW, or with it (the
                    // crossbar's local writes; the AW is counted above).
                    if (!aw_out) bad("AXI", "W beat accepted with no write address");
                    w_beats = w_beats + 1;
                    if (dmem_wlast !== (w_beats == w_len + 1) || w_beats > w_len + 1)
                        bad("AXI", "WLAST does not match AWLEN");
                    if (sba_page(aw_cur)) sba_w = sba_w + 1;
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
                if (held_r_shown) r_was_held = 1;
                if (held_b_shown) b_was_held = 1;
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
    reg dmi_pend = 0, dmi_locked = 0, dmi_en_prev = 0;
    integer dmi_accepts = 0;                 // requests the DM has accepted since the reset
    // Edge of the last acceptance relative to the falling edge of
    // debug_enable_o (0: at that edge), once both have happened.
    integer dmi_acc_age = 0, dmi_fall_age = -1, dmi_acc_rel = 0;
    reg [6:0] dmi_addr_q = 0;
    reg [1:0] dmi_op_q = 0;
    always @(posedge clk) begin
        if (rst) begin dmi_pend = 0; dmi_accepts = 0; dmi_en_prev = 0; dmi_fall_age = -1; end
        else begin
            dmi_acc_age = dmi_acc_age + 1;
            if (dmi_fall_age >= 0) dmi_fall_age = dmi_fall_age + 1;
            if (dmi_en_prev && !dut.auth.debug_enable_o) begin
                dmi_fall_age = 1;                 // the fall was at the previous edge
                dmi_acc_rel = 1 - dmi_acc_age;    // of an acceptance before it
            end
            dmi_en_prev = dut.auth.debug_enable_o;
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
                dmi_pend = 1; dmi_locked = !dut.auth.debug_enable_o; dmi_accepts = dmi_accepts + 1;
                dmi_acc_age = 0;
                if (dmi_fall_age >= 0) dmi_acc_rel = dmi_fall_age;
                dmi_addr_q = dmi_req_addr_i; dmi_op_q = dmi_req_op_i;
            end
        end
    end

    // ---------------- DMI driver ----------------
    reg [31:0] value;
`ifdef AUTH_REVOKE_JTAG
    // JTAG: TCK is not related to clk (14.6 ns against 10 ns). A DMI access
    // is one scan of the 41-bit dmi register that issues it, then no-op
    // scans until the status is no longer busy; a busy status is sticky and
    // is cleared through dtmcs.dmireset, which does not cancel the access.
    // The result is what the debugger sees on TDO.
    localparam real TCK_HALF = 7.3;
    reg jtag_bit;
    reg [63:0] jtag_got;
    integer jtag_scans = 0, jtag_busy = 0;       // coverage, whole run
    task jtag_tick(input bit ms, input bit di);
        begin
            tck = 0; tms = ms; tdi = di; #(TCK_HALF);
            jtag_bit = tdo;
            tck = 1; #(TCK_HALF);
        end
    endtask
    task jtag_idle(input integer cycles);
        integer n;
        begin for (n = 0; n < cycles; n = n + 1) jtag_tick(0, 0); end
    endtask
    task jtag_ir(input [4:0] ir);
        integer n;
        begin
            jtag_tick(1, 0); jtag_tick(1, 0); jtag_tick(0, 0); jtag_tick(0, 0);
            for (n = 0; n < 5; n = n + 1) jtag_tick(n == 4, ir[n]);
            jtag_tick(1, 0); jtag_tick(0, 0);
        end
    endtask
    task jtag_dr(input integer width, input [63:0] out);
        integer n;
        begin
            jtag_got = 0;
            jtag_tick(1, 0); jtag_tick(0, 0); jtag_tick(0, 0);
            for (n = 0; n < width; n = n + 1) begin
                jtag_tick(n == width - 1, out[n]); jtag_got[n] = jtag_bit;
            end
            jtag_tick(1, 0); jtag_tick(0, 0);
            jtag_scans = jtag_scans + 1;
        end
    endtask
    // One process drives the TAP; the tasks below hand it a command and
    // wait. (The scans are then compiled once, not at every DMI access.)
    localparam integer JQ_ATTACH = 0, JQ_ISSUE = 1, JQ_COLLECT = 2, JQ_ACCESS = 3;
    reg jq_start = 0;
    integer jq_cmd = 0, jq_n, jq_t;
    reg [1:0] jq_op;
    reg [6:0] jq_addr;
    reg [31:0] jq_data, jq_result;
    initial forever begin
        wait (jq_start);
        if (jq_cmd == JQ_ATTACH) begin
            // After a power-on reset: TAP reset, IDCODE, dtmcs, then the dmi register.
            for (jq_n = 0; jq_n < 7; jq_n = jq_n + 1) jtag_tick(1, 0);
            jtag_idle(20);
            jtag_dr(32, 64'b0);
            if (jtag_got[31:0] !== 32'h0000_0db3) $fatal(1, "JTAG IDCODE %08x", jtag_got[31:0]);
            jtag_ir(5'h10); jtag_dr(32, 64'b0);
            if (jtag_got[14:0] !== 15'h1071) $fatal(1, "dtmcs %08x", jtag_got[31:0]);
            jtag_ir(5'h11);
        end
        if (jq_cmd == JQ_ISSUE || jq_cmd == JQ_ACCESS) jtag_dr(41, {23'b0, jq_addr, jq_data, jq_op});
        if (jq_cmd == JQ_COLLECT || jq_cmd == JQ_ACCESS) begin
            jtag_idle(8);
            jtag_dr(41, 64'b0);
            jq_t = 0;
            while (jtag_got[1:0] == 2'd3 && jq_t < 200) begin
                jtag_busy = jtag_busy + 1;
                jtag_ir(5'h10); jtag_dr(32, 64'h10000); jtag_ir(5'h11);     // dtmcs.dmireset
                jtag_idle(8);
                jtag_dr(41, 64'b0);
                jq_t = jq_t + 1;
            end
            if (jtag_got[1:0] !== 2'd0 || jtag_got[40:34] !== jq_addr)
                $fatal(1, "DMI over JTAG: status %0d, address %02x for an access of %02x",
                       jtag_got[1:0], jtag_got[40:34], jq_addr);
            jq_result = jtag_got[33:2];
        end
        jq_start = 0;
    end
    task jtag_attach;
        begin jq_cmd = JQ_ATTACH; jq_start = 1; wait (!jq_start); end
    endtask
    // The scan that issues an access; it returns half a TCK period after
    // the TCK edge that hands the request to the crossing.
    task dmi_issue(input [1:0] op, input [6:0] addr, input [31:0] data);
        begin
            jq_op = op; jq_addr = addr; jq_data = data;
            jq_cmd = JQ_ISSUE; jq_start = 1; wait (!jq_start);
        end
    endtask
    task dmi_collect(input [6:0] addr, output [31:0] result);
        begin
            jq_addr = addr;
            jq_cmd = JQ_COLLECT; jq_start = 1; wait (!jq_start);
            result = jq_result;
        end
    endtask
    task dmi(input [1:0] op, input [6:0] addr, input [31:0] data, output [31:0] result);
        begin
            jq_op = op; jq_addr = addr; jq_data = data;
            jq_cmd = JQ_ACCESS; jq_start = 1; wait (!jq_start);
            result = jq_result;
            @(negedge clk);
        end
    endtask
`else
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
`endif
    task wr(input [6:0] a, input [31:0] d); reg [31:0] x; begin dmi(2, a, d, x); end endtask
    task rd(input [6:0] a, output [31:0] r); begin dmi(1, a, 0, r); end endtask

    // ---------------- setup: POR, application, authentication ----------------
    // The application (RAM at 0x8000_0000). With fwlock=1 it first polls
    // mip.MSIP without touching the data bus, then sets mdbgauth.fw_lock;
    // then it loops on an MMIO store, an MMIO load and a RAM store.
    task load_program(input bit fwlock);
        integer n;
        begin
            mem_clear;
            mem_insn(APP + 'h00, 32'h00001e97);            // auipc t4, 0x1      (RAM_CTR)
            mem_insn(APP + 'h04, MMIO_LUI);                // lui   t1, MMIO
            mem_insn(APP + 'h08, 32'h00000393);            // li    t2, 0
            if (fwlock) begin
                mem_insn(APP + 'h0c, 32'h344022f3);        // poll: csrr t0, mip
                mem_insn(APP + 'h10, 32'h0082f293);        //       andi t0, t0, 8
                mem_insn(APP + 'h14, 32'hfe028ce3);        //       beqz t0, poll
                mem_insn(APP + 'h18, 32'h7c026073);        //       csrsi mdbgauth, 4 (fw_lock)
            end else
                for (n = 'h0c; n <= 'h18; n = n + 4) mem_insn(APP + n, 32'h00000013);
            mem_insn(APP + 'h1c, 32'h00138393);            // loop: addi t2, t2, 1
            mem_insn(APP + 'h20, 32'h00733023);            //       sd   t2, 0(t1)
            mem_insn(APP + 'h24, 32'h00033e03);            //       ld   t3, 0(t1)
            mem_insn(APP + 'h28, 32'h007eb023);            //       sd   t2, 0(t4)
`ifdef KARU_EN_V
            // With the vector unit the loop also stores four doublewords of a
            // vector register to RAM (VEC_ST) and loads four from the
            // uncached page (VEC_LD), after a prologue that turns mstatus.VS
            // on and sets vl.
            mem_insn(APP + 'h08, 32'h0380006f);            //       j    setup    (for li t2, 0)
            mem_insn(APP + 'h2c, 32'h020f70a7);            //       vse64.v v1, (t5)
            mem_insn(APP + 'h30, 32'h020ff107);            //       vle64.v v2, (t6)
            mem_insn(APP + 'h34, 32'h021100d7);            //       vadd.vv v1, v1, v2
            mem_insn(APP + 'h38, 32'hfe5ff06f);            //       j    loop
            mem_insn(APP + 'h40, 32'h00000393);            // setup: li  t2, 0
            mem_insn(APP + 'h44, 32'h60000293);            //       li   t0, 0x600
            mem_insn(APP + 'h48, 32'h3002a073);            //       csrs mstatus, t0  (VS)
            mem_insn(APP + 'h4c, 32'hcd8272d7);            //       vsetivli t0, 4, e64, m1, ta, ma
            mem_insn(APP + 'h50, 32'h040e8f13);            //       addi t5, t4, 64   (VEC_ST)
            mem_insn(APP + 'h54, 32'h00001fb7);            //       lui  t6, 0x1
            mem_insn(APP + 'h58, 32'h01df8fb3);            //       add  t6, t6, t4   (VEC_LD)
            mem_insn(APP + 'h5c, 32'h5e00b0d7);            //       vmv.v.i v1, 1
            mem_insn(APP + 'h60, 32'hfadff06f);            //       j    poll
            for (n = 0; n < 32; n = n + 1) mem_byte(VEC_LD + n, 8'h01 + n[7:0]);
`else
            mem_insn(APP + 'h2c, 32'hff1ff06f);            //       j    loop
`endif
            mem_insn(APP + 'h100, 32'h0000006f);           // trap handler: j .
            for (n = 0; n < 8; n = n + 1) begin
                mem_byte(SBA_RD + n, SECRET[8*n +: 8]);
                mem_byte(SBA_WR + n, 8'h00);
                mem_byte(SBA_CANARY + n, CANARY[8*n +: 8]);
`ifdef AUTH_REVOKE_XBAR
                mem_byte(SCR_RD + n, SECRET[8*n +: 8]);
`endif
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
            rd_a = SBA_RD; wr_a = SBA_WR;
`ifdef AUTH_REVOKE_XBAR
            gate_m = 1;
`endif
            load_program(fwlock);
            repeat (5) @(negedge clk); rst = 0;
`ifdef AUTH_REVOKE_JTAG
            jtag_attach;
`endif
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
            // (Three passes of the loop. The count of device stores is part
            // of the wait for the application with vector accesses, whose
            // pass has more beats; without them it is reached no later.)
            while ((core_r < r0 + 3 || core_b < b0 + 6 || mmio_writes < w0 + 3) && t < 3000) begin
                @(negedge clk); t = t + 1;
            end
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
            check(mem_word(SBA_CANARY) == CANARY, "LAUNCH", "post-fall SBA write target unchanged");
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
    // Target and gate of a scenario (after start, which sets the defaults).
    // The test RAM model has one gate and one target: nothing to choose.
    task place(input integer where);
        begin
`ifdef AUTH_REVOKE_XBAR
            gate_m = where == W_STD;
            if (where == W_SCRATCH) begin rd_a = SCR_RD; wr_a = SCR_WR; end
`endif
        end
    endtask
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
            check(!value[21] && value[14:12] == 0 && mem_word(SBA_WR) == WVAL, "PRE",
                  "authorized SBA write completes");
            check(sba_ar == 1 && sba_r == 1 && sba_aw == 1 && sba_b == 1, "PRE", "baseline handshakes");
            hart_progress("in the baseline");
        end
    endtask
    // An SBA read (or write) accepted on the bus, its R (B) beat held, then
    // revoke_i (or the hart's fw_lock) while the beat is held.
    task in_flight(input integer kind, input integer d, input integer where);
        integer t;
        reg is_b;
        string tag;
        begin
            is_b = kind == K_WRITE;
            tag = "";
            if (where == W_PORT) tag = " (gate on the dmem port)";
            if (where == W_SCRATCH) tag = " of the scratch SRAM";
            if (is_b) start($sformatf("SBA write%s, revoke_i, beat at %s", tag, off(d)), 0);
            else if (kind == K_FWLOCK) start($sformatf("SBA read%s, hart fw_lock, beat at %s", tag, off(d)), 1);
            else start($sformatf("SBA read%s, revoke_i, beat at %s", tag, off(d)), 0);
            place(where);
            if (is_b) begin
                hold_b_addr = wr_a; hold_b_en = 1;
                wr(7'h38, 32'h00060000);                   // sbaccess=64
                wr(7'h39, wr_a); wr(7'h3d, WVAL[63:32]); wr(7'h3c, WVAL[31:0]);
            end else begin
                hold_r_addr = rd_a; hold_r_en = 1;
                wr(7'h38, 32'h00160000);                   // sbreadonaddr, sbaccess=64
                wr(7'h39, rd_a);
            end
            t = 0;
            while (!(is_b ? (sba_aw == 1 && sba_w == 1 && held_b_shown)
                          : (sba_ar == 1 && held_r_shown)) && t < 3000) begin
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
            if (is_b) check(mem_word(wr_a) == WVAL, "DRAIN", "the accepted SBA write completed");
            finish_scenario(kind, d);
        end
    endtask
    // The DM has a request that the bus has not yet accepted (the hart's
    // MMIO load holds the bus, its R beat held) when revoke_i falls: the
    // request must be withdrawn, never reaching the bus.
    // With the crossbar the hart's main-memory store holds the bus instead,
    // its B beat held on the DDR port: the crossbar requires the data of a
    // device read to be taken at once (its assertion X19), so a held device
    // load would break the crossbar's own contract.
    task pending(input integer d);
        integer t;
        begin
            start($sformatf("SBA read waiting for the bus, revoke_i, core beat at %s", off(d)), 0);
`ifdef AUTH_REVOKE_XBAR
            // Arm the gate with no write outstanding, so no shown beat is hidden.
            t = 0;
            while (aw_out && t < 100) begin @(negedge clk); t = t + 1; end
            hold_b_addr = RAM_CTR; hold_b_en = 1;
            t = 0;
            while (!held_b_shown && t < 3000) begin @(negedge clk); t = t + 1; end
            check(t < 3000 && hold_mb, "PRE", "the hart's RAM store is held on the DDR port");
`else
            // Arm the gate with no read outstanding, so no shown beat is hidden.
            t = 0;
            while (r_out && t < 100) begin @(negedge clk); t = t + 1; end
            hold_r_addr = MMIO; hold_r_en = 1;
            t = 0;
            while (!held_r_shown && t < 3000) begin @(negedge clk); t = t + 1; end
            check(t < 3000, "PRE", "the hart's MMIO load is held");
`endif
            wr(7'h38, 32'h00160000);
            wr(7'h39, SBA_RD);
            repeat (20) @(negedge clk);
            rd(7'h38, value);
            check(value[21] && sba_ar == 0 && dut.auth.debug_enable_o, "PRE", "SBA request waits for the bus");
            revoke_and_release(d, PEND_GATE);
            wait_beat(PEND_GATE, d);
            finish_scenario(K_PENDING, d);
        end
    endtask

    // The SBA transfer is accepted by the bus arbiter, but its AR (or AW,
    // with W behind it) is still stalled at the fabric when revoke_i falls.
    // The address is released d edges after the fall: the transfer must
    // finish (one address, one response) and its data stay hidden.
    // With the crossbar and where == W_STD the write address is stalled by
    // the DDR port instead, through the crossbar (a read address stalled
    // there has already left the dmem port: ddr_ar_stall below).
    task addr_phase(input bit is_b, input integer d, input integer where);
        integer t;
        begin
            if (where == W_FABRIC)
                start($sformatf("SBA %s stalled at the fall, revoke_i, released at %s",
                                is_b ? "AW" : "AR", off(d)), 0);
            else
                start($sformatf("SBA %s stalled by the DDR port at the fall, revoke_i, released at %s",
                                is_b ? "AW" : "AR", off(d)), 0);
            place(where);
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
            if (is_b) check(mem_word(SBA_WR) == WVAL, "DRAIN", "the accepted SBA write completed");
            finish_scenario(is_b ? K_ADDR_W : K_ADDR_R, d);
        end
    endtask
`ifdef AUTH_REVOKE_XBAR
    // Crossbar only. The crossbar has accepted the SBA read on the dmem port
    // and presents its address on the DDR port, where it is stalled when
    // revoke_i falls and released d edges later. For the DM this is a read
    // whose data is late; the crossbar's read engine is still in its address
    // phase at the fall.
    task ddr_ar_stall(input integer d);
        integer t;
        begin
            start($sformatf("SBA read, AR stalled on the DDR port at the fall, revoke_i, released at %s", off(d)), 0);
            place(W_STD);
            hold_a_addr = SBA_RD; hold_a_en = 1;
            wr(7'h38, 32'h00160000);
            wr(7'h39, SBA_RD);
            t = 0;
            while (!(sba_ar == 1 && hold_mar && m_arvalid) && t < 3000) begin @(negedge clk); t = t + 1; end
            repeat (4) @(negedge clk);
            check(sba_ar == 1 && hold_mar && m_arvalid && t_m_ar < 0, "PRE", "SBA address stalled on the DDR port");
            rd(7'h38, value); check(value[21], "PRE", "sbbusy before the fall");
            check(dut.auth.debug_enable_o && t_fall < 0, "PRE", "debug enabled before the fall");
            revoke_and_release(d, 2);
            t = 0;
            while (sba_r == 0 && t < 300) begin @(negedge clk); t = t + 1; end
            check(sba_r == 1, "DRAIN", "the stalled transfer completes after the fall");
            check(t_fall >= 0 && t_sba_ar < t_fall && t_m_ar - t_fall == d && t_sba_r > t_m_ar, "PRE",
                  $sformatf("DDR port accepted the address at %s (released at %s)", off(t_m_ar - t_fall), off(d)));
            d_meas = t_sba_r - t_fall;
            finish_scenario(K_READ, d_meas);
        end
    endtask
`endif

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
            while (!(sba_ar == 1 && held_r_shown) && t < 3000) begin @(negedge clk); t = t + 1; end
            check(t < 3000, "PRE", "SBA read accepted and its beat held");
            rd(7'h38, value); check(value[21], "PRE", "sbbusy before the fall");
            @(negedge clk); revoke_i = 1;
            t = 0;
            while (!auth_reset_o && t < 50) begin @(negedge clk); t = t + 1; end
            d_meas = edge_n - t_fall;
            check(auth_reset_o && d_meas <= 4, "DRAIN",
                  $sformatf("relock reset within 4 cycles of the fall (%0d)", d_meas));
            while (auth_reset_o && t < 100) begin @(negedge clk); t = t + 1; end
            check(!resp_r_shown && sba_r == 0, "DRAIN", "the withheld beat was cancelled, never consumed");
            hold_r_en = 0;
            finish_scenario(K_HALTED, 0);
            check(!debug_mode_o, "PRE", "the hart left Debug Mode");
        end
    endtask

`ifdef AUTH_REVOKE_JTAG
    // JTAG only. An authorized SBA read has completed and sbdata0 holds the
    // secret. The debugger issues a read of sbdata0 at the transport, and
    // revoke_i rises while the request is in the clock-domain crossing, timed
    // from the crossing's own synchroniser so that the DM accepts the request
    // `want` edges after the falling edge of debug_enable: +1 (the first
    // locked acceptance), 0 (the falling edge itself) or earlier. A request
    // accepted at or before the falling edge was authorized and returns the
    // data (plan 3.5 item 1); one accepted later must return zero on TDO.
    integer race_open = 0, race_locked = 0;
    task dmi_race(input integer want);
        integer t, a0, rel;
        reg was_locked;
        reg [31:0] lo;
        begin
            start($sformatf("sbdata0 read crossing the transport, accepted at %s", off(want)), 0);
            wr(7'h38, 32'h00160000);
            wr(7'h39, SBA_RD);
            t = 0; rd(7'h38, value);
            while (value[21] && t < 100) begin rd(7'h38, value); t = t + 1; end
            rd(7'h3c, lo);
            check(!value[21] && lo == SECRET[31:0] && dut.auth.debug_enable_o, "PRE",
                  "authorized SBA read completed and sbdata0 returns the data");
            a0 = dmi_accepts;
            dmi_issue(1, 7'h3c, 0);
            check(dmi_accepts == a0 && !dtm.cdc.req_sync2, "PRE", "the request is in the crossing when its scan ends");
            // The second synchroniser stage, then the request is presented to
            // the DM for one cycle and accepted.
            t = 0;
            if (want > 0)
                while (!dtm.cdc.req_sync2 && t < 50) begin @(negedge clk); t = t + 1; end
            else begin
                while (!dmi_req_valid_i && t < 50) begin @(negedge clk); t = t + 1; end
                repeat (-want) @(negedge clk);
            end
            revoke_i = 1;
            dmi_collect(7'h3c, lo);
            @(negedge clk);
            t = 0;
            while (t_fall < 0 && t < 20) begin @(negedge clk); t = t + 1; end
            check(t_fall >= 0 && dmi_accepts == a0 + 1, "PRE", "the read reached the DM, and nothing else did");
            was_locked = dmi_locked; rel = dmi_acc_rel;
            check(rel == want && was_locked == (rel > 0), "PRE",
                  $sformatf("the DM accepted the read at %s (wanted %s)", off(rel), off(want)));
            if (was_locked) begin
                race_locked = race_locked + 1;
                if (lo == SECRET[31:0] || lo == SECRET[63:32])
                    check(0, "LEAK", $sformatf("sbdata0 read accepted after the fall returned %08x on TDO", lo));
                else check(lo == 0, "LOCKED", $sformatf("sbdata0 read accepted after the fall returned %08x on TDO", lo));
            end else begin
                race_open = race_open + 1;
                check(lo == SECRET[31:0], "PRE", "sbdata0 read accepted at or before the fall returns the data");
            end
            hart_progress("after the fall");
            locked_view("after the fall");
            launch_attempts;
            locked_view("after the attempts");
            check(sba_ar == 1 && sba_r == 1 && sba_aw == 0 && sba_b == 0, "DRAIN", "one SBA read in all");
            $display("scenario %s: SBA data register read accepted by the DM at %s (fall at edge %0d), TDO returned %08x",
                     scen, off(rel), t_fall, lo);
        end
    endtask
`endif

    integer i;
    integer sweep [0:6];
    initial begin
        sweep[0] = -1; sweep[1] = 0; sweep[2] = 1; sweep[3] = 2; sweep[4] = 3; sweep[5] = 8; sweep[6] = 40;
        baseline;
        for (i = 0; i < 7; i = i + 1) in_flight(K_READ, sweep[i], W_STD);
        for (i = 0; i < 7; i = i + 1) in_flight(K_WRITE, sweep[i], W_STD);
        in_flight(K_FWLOCK, 1, W_RUN);
        in_flight(K_FWLOCK, 6, W_RUN);
        pending(0);
        pending(3);
        addr_phase(0, 1, W_FABRIC);
        addr_phase(0, 4, W_FABRIC);
        addr_phase(1, 1, W_FABRIC);
        addr_phase(1, 4, W_FABRIC);
        halted_in_flight;
`ifdef AUTH_REVOKE_XBAR
        // Crossbar only: the beat held on the core side of the crossbar, the
        // crossbar's local engines, and the address held on the DDR port.
        in_flight(K_READ, 0, W_PORT);
        in_flight(K_READ, 2, W_PORT);
        in_flight(K_WRITE, 0, W_PORT);
        in_flight(K_WRITE, 2, W_PORT);
        in_flight(K_READ, 0, W_SCRATCH);
        in_flight(K_READ, 3, W_SCRATCH);
        in_flight(K_WRITE, 0, W_SCRATCH);
        in_flight(K_WRITE, 3, W_SCRATCH);
        ddr_ar_stall(1);
        ddr_ar_stall(4);
        addr_phase(1, 1, W_STD);
        addr_phase(1, 4, W_STD);
        check(cov_x_rd > 0 && cov_x_ar > 0 && cov_x_wr > 0 && cov_x_aw > 0 && cov_x_lr > 0 && cov_x_lw > 0 &&
              cov_x_reset > 0, "PRE",
              $sformatf("the crossbar held the SBA transfer in the first locked cycle: read data %0d, read address %0d, write %0d, write address %0d, local read %0d, local write %0d; read cut by the relock reset %0d",
                        cov_x_rd, cov_x_ar, cov_x_wr, cov_x_aw, cov_x_lr, cov_x_lw, cov_x_reset));
        check(xbar.u_xbar_assert.enabled && xbar.u_xbar_assert.fails == 0, "XBAR",
              $sformatf("the crossbar's assertions are armed and silent (%0d failures)", xbar.u_xbar_assert.fails));
        $display("crossbar in the first locked cycle: SBA read data outstanding %0d, read address stalled %0d, write outstanding %0d, write address stalled %0d, local read %0d, local write %0d; read cut by the relock reset %0d; assertion failures %0d",
                 cov_x_rd, cov_x_ar, cov_x_wr, cov_x_aw, cov_x_lr, cov_x_lw, cov_x_reset, xbar.u_xbar_assert.fails);
`endif
        check(cov_ar_stall > 0 && cov_aw_stall > 0 && cov_w_stall > 0, "PRE",
              $sformatf("the monitor saw stalled AR, AW and W (%0d, %0d, %0d cycles)",
                        cov_ar_stall, cov_aw_stall, cov_w_stall));
`ifdef KARU_EN_V
        // (Not counted as a check: every configuration reports the same number.)
        if (cov_vec_ld < 100 || cov_vec_st < 100)
            bad("PRE", $sformatf("the hart's vector loads and stores reached the data bus (%0d AR, %0d AW)",
                                 cov_vec_ld, cov_vec_st));
        $display("vector unit: %0d vector-load AR and %0d vector-store AW on the dmem port", cov_vec_ld, cov_vec_st);
`endif
`ifdef AUTH_REVOKE_JTAG
        for (i = 1; i >= -3; i = i - 1) dmi_race(i);
        check(race_open == 4 && race_locked == 1, "PRE",
              $sformatf("the DM's acceptance was put on both sides of the fall (%0d before, %0d after)",
                        race_open, race_locked));
        check(jtag_scans > 1000, "PRE", $sformatf("DMI accesses went through the TAP (%0d scans, %0d busy)",
                                                   jtag_scans, jtag_busy));
        $display("JTAG transport: %0d scans, %0d of them answered busy; sbdata0 read accepted after the fall %0d, at or before it %0d",
                 jtag_scans, jtag_busy, race_locked, race_open);
        if (errors != 0)
            $fatal(1, "karudbg auth SBA revocation, JTAG: FAIL (%0d of %0d checks)", errors, checks);
        $display("karudbg auth SBA revocation, JTAG: PASS (%0d checks, %0d scenarios)", checks, scenarios);
`elsif AUTH_REVOKE_XBAR
        if (errors != 0)
            $fatal(1, "karudbg auth SBA revocation, DDR crossbar: FAIL (%0d of %0d checks)", errors, checks);
        $display("karudbg auth SBA revocation, DDR crossbar: PASS (%0d checks, %0d scenarios)", checks, scenarios);
`else
        if (errors != 0)
            $fatal(1, "karudbg auth SBA revocation: FAIL (%0d of %0d checks)", errors, checks);
        $display("karudbg auth SBA revocation: PASS (%0d checks, %0d scenarios)", checks, scenarios);
`endif
        $finish;
    end
    initial begin #50000000; $fatal(1, "auth sba revoke: global timeout"); end
endmodule
