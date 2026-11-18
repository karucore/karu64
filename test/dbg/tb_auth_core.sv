// KARU_DBG_AUTH on the real karudbg_core (karu64 + DM + auth + island):
// boot hold, REQUEST over authdata, the island ROM stub's window, unlock,
// revocation from Debug Mode with the relock reset, a rejected response, and
// the OPEN lifecycle. Driven only through DMI and the platform inputs.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karudbg_defs.vh"
`include "rtl/karu_assert.sv"
module tb_auth_core #(parameter ROM_HEX = "rom.hex");
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
    // Fabric-side R channels pass through a bench mux, so a forged beat
    // can be injected without disturbing the memory model's own state.
    wire ram_imem_rvalid, ram_imem_rlast, ram_dmem_rvalid, ram_dmem_rlast;
    wire [`AXI_DATA_W-1:0] ram_imem_rdata, ram_dmem_rdata;
    wire [`AXI_RESP_W-1:0] ram_imem_rresp, ram_dmem_rresp;
    reg inj_i = 0, inj_d = 0;
    reg [63:0] inj_data = 0;
    assign imem_rvalid = inj_i ? 1'b1 : ram_imem_rvalid;
    assign imem_rlast = inj_i ? 1'b1 : ram_imem_rlast;
    assign imem_rdata = inj_i ? inj_data : ram_imem_rdata;
    assign imem_rresp = inj_i ? 2'b00 : ram_imem_rresp;
    assign dmem_rvalid = inj_d ? 1'b1 : ram_dmem_rvalid;
    assign dmem_rlast = inj_d ? 1'b1 : ram_dmem_rlast;
    assign dmem_rdata = inj_d ? inj_data : ram_dmem_rdata;
    assign dmem_rresp = inj_d ? 2'b00 : ram_dmem_rresp;
    karudbg_test_ram memory (.*, .fifo_count(),
        .imem_rvalid(ram_imem_rvalid), .imem_rlast(ram_imem_rlast),
        .imem_rdata(ram_imem_rdata), .imem_rresp(ram_imem_rresp),
        .dmem_rvalid(ram_dmem_rvalid), .dmem_rlast(ram_dmem_rlast),
        .dmem_rdata(ram_dmem_rdata), .dmem_rresp(ram_dmem_rresp));


    localparam [63:0] RAM = 64'h8000_0000;
    integer checks = 0;
    reg saw_debug = 0, saw_breakpoint = 0;
    integer illegal_traps = 0;
    // Hostile fabric: inject the TEST response word as an external R beat
    // while the ROM's island SRAM load is presented (plan lemma C9).
    reg inject_armed = 0;
    integer injected = 0;
    always @(negedge clk) begin
        if (inject_armed && injected == 0 && dut.k_dmem_arvalid &&
            dut.k_dmem_araddr == 32'h0002_0000) begin
            injected = 1;
            inj_data = 64'h0000_0000_600d_f00d; inj_d = 1;
            repeat (3) @(negedge clk);
            inj_d = 0;
        end
    end
    reg [31:0] value;
    always @(posedge clk) cache_flush_done <= cache_flush_req && !rst;
    // Independent observation of the hart: Debug Mode entries and breakpoint
    // traps, sampled from the core's own state.
    always @(posedge clk) begin
        if (debug_mode_o) saw_debug <= 1;
        if (!rst && dut.core.trap_req && dut.core.trap_cause == 64'd3) saw_breakpoint <= 1;
        if (!rst && dut.core.trap_req && dut.core.trap_cause == 64'd2) illegal_traps <= illegal_traps + 1;
    end
    `include "test/dbg/trigger_checker.vh"

    task check(input bit c, input string what);
        begin checks = checks + 1; if (!c) $fatal(1, "auth core check %0d: %s", checks, what); end
    endtask
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
    task wait_parked;
        integer t;
        begin
            t = 0;
            while (!(debug_mode_o && dut.dm.parked_q) && t < 20000) begin @(negedge clk); t = t + 1; end
            check(t < 20000, "hart parked in Debug Mode");
        end
    endtask
    task command(input [31:0] word, input [2:0] err);
        integer t; reg [31:0] s;
        begin
            wr(7'h17, word);
            t = 0; s = 32'h1000;
            while (s[12] && t < 5000) begin rd(7'h16, s); t = t + 1; end
            check(!s[12] && s[10:8] == err, $sformatf("command %08x abstractcs=%08x", word, s));
        end
    endtask
    task poll_status_tx(input integer want);
        integer t;
        begin
            t = 0; rd(7'h30, value);
            while (value[4:0] < want && t < 5000) begin rd(7'h30, value); t = t + 1; end
            check(value[4:0] >= want, "challenge reached TX");
        end
    endtask
    task poll_authenticated(input bit want, input integer bound);
        integer t;
        begin
            t = 0; rd(7'h11, value);
            while (value[7] != want && t < bound) begin rd(7'h11, value); t = t + 1; end
        end
    endtask
    // Run the A1 stub protocol: REQUEST, read the challenge, send one word.
    task authenticate(input [31:0] response);
        begin
            wr(7'h30, 32'h10a50001);                       // REQUEST
            poll_status_tx(1);
            wr(7'h30, 32'h30000001);                       // RECV 1
            rd(7'h30, value); check(value == 32'hc0de0001, "challenge word");
            wr(7'h30, 32'h20000001);                       // SEND 1
            wr(7'h30, response);
        end
    endtask
    task por(input [1:0] lc, input bit strap);
        begin
            @(negedge clk); rst = 1; lc_i = lc; hold_strap_i = strap; revoke_i = 0;
            memory.clear_ram();
            memory.put_insn('h0, 32'h00128293);            // addi t0,t0,1
            memory.put_insn('h4, 32'hffdff06f);            // j -4
            memory.put_insn('h100, 32'h05500313);          // trap handler: li t1,0x55
            memory.put_insn('h104, 32'h0000006f);          // j .
            repeat (5) @(negedge clk); rst = 0;
            saw_debug = 0; saw_breakpoint = 0;
        end
    endtask

    initial begin
        // ---- AUTH, held, locked; successful authentication ----
        por(1, 1);
        wr(7'h10, 1);
        rd(7'h11, value); check(value == 32'h00000003, "locked dmstatus is version only");
        check(auth_reset_o, "boot hold keeps the hart in reset");
        wr(7'h10, 32'h80000001);                           // haltreq ignored
        repeat (50) @(negedge clk);
        check(!saw_debug, "no Debug Mode while held and locked");
        authenticate(32'h600df00d);
        poll_authenticated(1, 5000);
        check(value[7], "ROM unlock sets dmstatus.authenticated");
        wr(7'h10, 32'h80000001);
        wait_parked;
        command(32'h00321005, 0);                          // read t0
        rd(7'h04, value); check(value != 0, "application ran from RAM before the halt");
        // ---- firmware revocation with dcsr.ebreakm=1: the core gate alone
        // must turn the following EBREAK into a breakpoint exception ----
        memory.put_insn('h200, 32'h7c026073);              // csrsi mdbgauth, 4 (fw_lock)
        memory.put_insn('h204, 32'h00100073);              // ebreak
        memory.put_insn('h208, 32'h0000006f);              // j .
        wr(7'h04, 32'h00008003); wr(7'h05, 0); command(32'h003307b0, 0);  // dcsr.ebreakm, prv=M
        wr(7'h04, 32'h80000200); wr(7'h05, 0); command(32'h003307b1, 0);  // dpc
        wr(7'h10, 32'h40000001);                           // resume
        while (debug_mode_o) @(negedge clk);
        saw_debug = 0; saw_breakpoint = 0;
        repeat (1000) @(negedge clk);
        check(saw_breakpoint, "locked EBREAK with dcsr.ebreakm traps as a breakpoint");
        check(!saw_debug, "firmware revocation: no Debug Mode entry");
        rd(7'h11, value); check(value == 32'h00000003, "firmware revocation locks the DM");

        // ---- revocation from Debug Mode: abstract write of mdbgauth.fw_lock ----
        por(1, 1);
        wr(7'h10, 1);
        authenticate(32'h600df00d);
        poll_authenticated(1, 5000);
        check(value[7], "second unlock");
        wr(7'h10, 32'h80000001);
        wait_parked;
        wr(7'h04, 32'h4); wr(7'h05, 0);
        wr(7'h17, 32'h003307c0);
        repeat (200) @(negedge clk);
        rd(7'h11, value); check(value == 32'h00000003, "revoked: locked dmstatus");
        check(!debug_mode_o, "relock reset ended Debug Mode");
        saw_debug = 0;
        wr(7'h10, 32'h80000001);
        repeat (2000) @(negedge clk);
        check(!saw_debug && !debug_mode_o, "revoked: haltreq cannot enter Debug Mode");
        check(dut.core.ex_pc[63:31] == 1, "revoked hart runs the application");

        // ---- AUTH, wrong response: stays locked, EBREAK is an exception ----
        por(1, 1);
        memory.put_insn('h0, 32'h00100073);                // ebreak
        wr(7'h10, 1);
        authenticate(32'h0badbad0);
        repeat (3000) @(negedge clk);
        rd(7'h11, value); check(value == 32'h00000003, "wrong response stays locked");
        check(saw_breakpoint && !saw_debug, "locked EBREAK raises a breakpoint exception");

        // ---- AUTH, forged island SRAM load: a wrong response plus an
        // injected external R beat carrying the TEST word must not unlock ----
        por(1, 1);
        wr(7'h10, 1);
        inject_armed = 1; injected = 0;
        authenticate(32'h0badbad1);
        repeat (3000) @(negedge clk);
        inject_armed = 0;
        check(injected == 1, "injection fired at the island SRAM load");
        rd(7'h11, value); check(value == 32'h00000003, "forged island response cannot unlock");

        // ---- AUTH, system reset during the window closes it ----
        por(1, 1);
        wr(7'h10, 1);
        wr(7'h30, 32'h10a50001);
        poll_status_tx(1);                                 // ROM is waiting for RX
        @(negedge clk); hart_reset_i = 1;
        repeat (5) @(negedge clk); hart_reset_i = 0;
        repeat (200) @(negedge clk);
        wr(7'h30, 32'h00000000); rd(7'h30, value);
        check(value[23:21] == 3, "system reset in the window closes it");
        wr(7'h30, 32'h20000001); wr(7'h30, 32'h600df00d);
        repeat (2000) @(negedge clk);
        rd(7'h11, value); check(value == 32'h00000003, "no unlock after a system reset in the window");

        // ---- AUTH, no strap: boots locked without a window. The application
        // probes the CSR instruction-form table (contract 3): three illegal
        // forms trap with cause 2 and are skipped; a legal read does not. ----
        @(negedge clk); rst = 1; lc_i = 1; hold_strap_i = 0;
        memory.clear_ram();
        memory.put_insn('h0, 32'h7c102373);                // csrrs t1, mdbgrx, x0 (read-only: illegal)
        memory.put_insn('h4, 32'h7c20e073);                // csrrsi x0, mdbgtx, 1 (set form: illegal)
        memory.put_insn('h8, 32'hfc001073);                // csrrw x0, mdbgmbst, x0 (read-only CSR: illegal)
        memory.put_insn('hc, 32'hfc002e73);                // csrr t3, mdbgmbst (legal)
        memory.put_insn('h10, 32'h0000006f);               // j .
        memory.put_insn('h100, 32'h341023f3);              // handler: csrr t2, mepc
        memory.put_insn('h104, 32'h00438393);              //          addi t2, t2, 4
        memory.put_insn('h108, 32'h34139073);              //          csrw mepc, t2
        memory.put_insn('h10c, 32'h30200073);              //          mret
        repeat (5) @(negedge clk); rst = 0;
        illegal_traps = 0;
        repeat (2000) @(negedge clk);
        check(illegal_traps == 3, $sformatf("three illegal CSR forms trapped (%0d)", illegal_traps));
        check(dut.core.ex_pc == RAM + 'h10, "legal mdbgmbst read did not trap");
        wr(7'h10, 1);
        repeat (500) @(negedge clk);
        check(!auth_reset_o, "no strap, no hold");
        wr(7'h30, 32'h10a50001); rd(7'h30, value);
        check(value[23:21] == 3 && value[20:18] == 4, "REQUEST refused once the window closed");
        rd(7'h11, value); check(value == 32'h00000003, "boots locked");

        // ---- OPEN: strap ignored, debug available ----
        por(0, 1);
        check(!auth_reset_o, "OPEN ignores the strap");
        wr(7'h10, 1);
        rd(7'h11, value); check(value[7], "OPEN authenticated");
        wr(7'h10, 32'h80000001);
        wait_parked;
        rd(7'h30, value); check(value == 0, "OPEN authdata absent");

        $display("karudbg auth actual core: PASS (%0d checks)", checks);
        $finish;
    end
    initial begin #20000000; $fatal(1, "auth core: global timeout"); end
endmodule
