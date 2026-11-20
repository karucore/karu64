// karudbg + karudbg_auth DM-level tests (KARU_DBG_AUTH): locked register view,
// authdata mailbox, unlock, revocation during a command, and the OPEN and
// DISABLED lifecycles. The hart side is driven directly through the DM memory
// port and the authentication CSR port.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karudbg_defs.vh"
module tb_dm_auth;
    localparam [63:0] ROM = 64'h0001_0000;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1, dmi_reset = 0;
    reg req_valid = 0, resp_ready = 1;
    reg [6:0] req_addr = 0;
    reg [1:0] req_op = 0;
    reg [31:0] req_data = 0;
    wire req_ready, resp_valid;
    wire [31:0] resp_data;
    wire [1:0] resp_op;
    wire halt_req, resume_req, resume_auth, ndmreset;
    reg halted = 0, resumed = 0, unavail = 0, hreset = 0;
    reg mem_req = 0, mem_write = 0;
    reg [11:0] mem_addr = 0;
    reg [63:0] mem_wdata = 0;
    reg [7:0] mem_be = 0;
    wire [63:0] mem_rdata;
    wire mem_ready, mem_error;
    // authentication block
    reg [1:0] lc = 1;
    reg strap = 1, revoke = 0;
    wire debug_enable, debug_enable_next, lc_auth, sys_reset, authbusy;
    wire auth_valid, auth_write, dm_active;
    wire [31:0] auth_wdata, auth_rdata;
    reg csr_fire = 0, csr_we = 0;
    reg [2:0] csr_sel = 0;
    reg [63:0] csr_wdata = 0;
    wire [63:0] csr_rdata;
    reg debug_mode = 0;
    integer checks = 0;
    reg [31:0] value;
    reg [63:0] word;

    karudbg dut (
        .clk(clk), .rst(rst), .dmi_reset_i(dmi_reset),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_addr_i(req_addr),
        .req_op_i(req_op), .req_data_i(req_data), .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready), .resp_data_o(resp_data), .resp_op_o(resp_op),
        .halt_req_o(halt_req), .resume_req_o(resume_req),
        .resume_authorized_o(resume_auth), .ndmreset_o(ndmreset),
        .hart_halted_i(halted), .hart_resume_ack_i(resumed),
        .hart_unavailable_i(unavail), .hart_reset_i(hreset || ndmreset || sys_reset),
        .mem_req_i(mem_req), .mem_write_i(mem_write), .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata), .mem_be_i(mem_be),
        .mem_rdata_o(mem_rdata), .mem_ready_o(mem_ready), .mem_error_o(mem_error),
        .sba_req_valid_o(), .sba_req_ready_i(1'b0), .sba_req_addr_o(),
        .sba_req_data_o(), .sba_req_size_o(), .sba_req_write_o(),
        .sba_resp_valid_i(1'b0), .sba_resp_ready_o(),
        .sba_resp_data_i(64'b0), .sba_resp_error_i(3'b0),
        .debug_enable_i(debug_enable), .debug_enable_next_i(debug_enable_next),
        .lc_auth_i(lc_auth), .auth_valid_o(auth_valid), .auth_write_o(auth_write),
        .auth_wdata_o(auth_wdata), .auth_rdata_i(auth_rdata), .authbusy_i(authbusy),
        .dmactive_o(dm_active));
    karudbg_auth #(.AUTH_ROM_BASE(ROM), .AUTH_ROM_END(ROM + 64'h1_0000)) auth (
        .clk(clk), .rst(rst), .lc_i(lc), .hold_strap_i(strap), .revoke_i(revoke),
        .debug_enable_o(debug_enable), .debug_enable_next_o(debug_enable_next),
        .lc_auth_o(lc_auth), .sys_reset_o(sys_reset),
        .dm_active_i(dm_active), .dmi_valid_i(auth_valid), .dmi_write_i(auth_write),
        .dmi_wdata_i(auth_wdata), .dmi_rdata_o(auth_rdata), .authbusy_o(authbusy),
        .core_in_reset_i(sys_reset), .csr_fire_i(csr_fire), .csr_sel_i(csr_sel),
        .csr_we_i(csr_we), .csr_wdata_i(csr_wdata), .csr_rdata_o(csr_rdata),
        .ex_pc_i(ROM), .issuing_i(csr_fire), .trap_i(1'b0), .dbg_enter_i(1'b0),
        .debug_mode_i(debug_mode), .priv_i(2'd3), .virt_i(1'b0));

    task check(input bit c, input string what);
        begin checks = checks + 1; if (!c) $fatal(1, "check %0d: %s", checks, what); end
    endtask
    task dmi(input [1:0] op, input [6:0] a, input [31:0] d, output [31:0] r);
        begin
            @(negedge clk); req_valid = 1; req_op = op; req_addr = a; req_data = d;
            @(posedge clk); #1; r = resp_data;
            @(negedge clk); req_valid = 0;
        end
    endtask
    task wr(input [6:0] a, input [31:0] d); reg [31:0] x; begin dmi(2, a, d, x); end endtask
    task rd(input [6:0] a, input [31:0] expect_v, input string what);
        reg [31:0] r;
        begin dmi(1, a, 0, r); check(r === expect_v, $sformatf("%s: DMI[%02x]=%08x expected %08x", what, a, r, expect_v)); end
    endtask
    task mw(input [11:0] a);
        begin
            @(negedge clk); mem_req = 1; mem_write = 1; mem_addr = a; mem_wdata = 0; mem_be = 8'h0f;
            @(negedge clk); mem_req = 0; mem_write = 0; mem_be = 0;
        end
    endtask
    task mr(input [11:0] a, output [63:0] r);
        begin mem_addr = a; mem_write = 0; #0.1 r = mem_rdata; end
    endtask
    task cw(input [2:0] sel, input [63:0] d);
        begin
            @(negedge clk); csr_fire = 1; csr_sel = sel; csr_we = 1; csr_wdata = d;
            @(negedge clk); csr_fire = 0; csr_we = 0;
        end
    endtask
    task por(input [1:0] l, input bit s);
        begin
            @(negedge clk); rst = 1; lc = l; strap = s; revoke = 0; halted = 0; debug_mode = 0;
            repeat (3) @(negedge clk); rst = 0;
        end
    endtask
    // Every non-exempt register reads 0 while locked.
    task locked_view(input string what);
        begin
            rd(7'h10, 1, what); rd(7'h11, 32'h00000003, what);
            rd(7'h04, 0, what); rd(7'h05, 0, what); rd(7'h12, 0, what);
            rd(7'h13, 0, what); rd(7'h16, 0, what); rd(7'h17, 0, what);
            rd(7'h18, 0, what); rd(7'h20, 0, what); rd(7'h38, 0, what);
            rd(7'h40, 0, what);
            check(!halt_req && !resume_req && !resume_auth && !ndmreset, {what, ": outputs 0"});
        end
    endtask

    initial begin
        // ---- AUTH, held at POR, locked ----
        por(1, 1);
        rd(7'h10, 0, "inactive");
        wr(7'h10, 1);
        check(sys_reset && !debug_enable, "AUTH held and locked");
        locked_view("AUTH locked");
        wr(7'h04, 32'hdeadbeef); wr(7'h20, 32'h00000013);
        wr(7'h10, 32'h80000003);                         // haltreq + ndmreset ignored
        check(!halt_req && !ndmreset, "locked dmcontrol ignores haltreq/ndmreset");
        wr(7'h17, 32'h00321001);                         // command ignored
        mr(12'h400, word); check(word == 0, "locked flags: no go");
        mr(12'h338, word); check(word == {2{32'h00100073}}, "locked abstract words are EBREAK");
        mr(12'h360, word); check(word == {2{32'h00100073}}, "locked Program Buffer is EBREAK");
        mr(12'h380, word); check(word == 0, "locked data window reads 0");
        locked_view("after ignored writes");
        // authdata is live: status, then REQUEST releases the hold
        dmi(1, 7'h30, 0, value); check(value[31:28] == 6 && value[23:21] == 1, "authdata status HOLD");
        wr(7'h30, 32'h10a50001);
        @(negedge clk); check(!sys_reset, "REQUEST over authdata releases the hold");
        dmi(1, 7'h30, 0, value); check(value[23:21] == 2, "REQUESTED");
        // ROM unlocks
        cw(0, 1);
        @(negedge clk); check(debug_enable, "ROM unlock");
        rd(7'h11, 32'h00000c83, "unlocked dmstatus");
        rd(7'h04, 0, "data0 was never written while locked");
        rd(7'h20, 0, "progbuf was never written while locked");
        wr(7'h10, 32'h80000001); check(halt_req, "unlocked haltreq");
        halted = 1; mw(12'h100);
        wr(7'h10, 32'h00000001);
        // ---- revocation during an executing command ----
        wr(7'h04, 32'h5a5a5a5a);
        wr(7'h17, 32'h00361001);                         // transfer + postexec
        mr(12'h400, word); check(word[0], "GO visible while unlocked");
        mw(12'h108);                                     // GOING: executing
        check(dut.cmd_state_q == 2, "command executing");
        @(negedge clk); debug_mode = 1;
        csr_fire = 1; csr_sel = 0; csr_we = 1; csr_wdata = 4;  // fw_lock from Debug Mode
        @(posedge clk); #1;
        check(!debug_enable, "gate falls on the fw_lock edge");
        check(!ndmreset && !halt_req && !resume_req, "all outputs 0 in the first locked cycle");
        @(negedge clk); csr_fire = 0; csr_we = 0;
        mr(12'h338, word); check(word == {2{32'h00100073}}, "revoked: executing hart sees EBREAK");
        mr(12'h380, word); check(word == 0, "revoked: data hidden from the hart");
        @(negedge clk); check(sys_reset, "relock reset for the Debug-Mode hart");
        debug_mode = 0; halted = 0;
        repeat (3) @(negedge clk);
        locked_view("revoked");
        wr(7'h10, 0); rd(7'h10, 0, "deactivation completes after revocation");
        wr(7'h10, 1); locked_view("reactivated while revoked");

        // ---- ndmreset clears on the same edge as the gate ----
        por(1, 1);
        wr(7'h10, 1); wr(7'h30, 32'h10a50001); cw(0, 1);
        @(negedge clk); check(debug_enable, "unlocked again");
        wr(7'h10, 3);
        check(ndmreset, "ndmreset set while unlocked");
        @(negedge clk); revoke = 1;
        @(posedge clk); #1;
        check(!debug_enable && !ndmreset, "ndmreset_o clears on the gate's falling edge");
        @(negedge clk); revoke = 0;

        // ---- OPEN: authdata absent, authenticated, strap ignored ----
        por(0, 1);
        wr(7'h10, 1);
        check(!sys_reset && debug_enable, "OPEN not held");
        rd(7'h11, 32'h00000c83, "OPEN dmstatus");
        rd(7'h30, 0, "OPEN authdata absent");
        wr(7'h30, 32'h10a50001); rd(7'h30, 0, "OPEN authdata writes ignored");

        // ---- DISABLED: locked, authdata absent ----
        por(2, 1);
        wr(7'h10, 1);
        check(!sys_reset && !debug_enable, "DISABLED boots locked, unheld");
        locked_view("DISABLED");
        rd(7'h30, 0, "DISABLED authdata absent");
        cw(0, 1); @(negedge clk); check(!debug_enable, "DISABLED cannot unlock");

        $display("karudbg DM auth: PASS (%0d checks)", checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "DM auth timeout"); end
endmodule
