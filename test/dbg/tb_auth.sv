// karudbg_auth unit tests against doc/debug-auth-contract.md. Independent
// expectations; every case drives the block's ports directly.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_auth;
    localparam [63:0] ROM = 64'h0001_0000, OUT = 64'h8000_0000;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    reg [1:0] lc = 1;
    reg strap = 0, revoke = 0;
    reg [1:0] opst = 2;
    reg [15:0] entropy = 16'hbeef;
    wire trng_ack, debug_enable, lc_auth, sys_reset, authbusy;
    reg dm_active = 1, dmi_valid = 0, dmi_write = 0;
    reg [31:0] dmi_wdata = 0;
    wire [31:0] dmi_rdata;
    reg core_rst = 0, csr_fire = 0, csr_we = 0;
    reg [2:0] csr_sel = 0;
    reg [63:0] csr_wdata = 0;
    wire [63:0] csr_rdata;
    reg [63:0] ex_pc = ROM;
    reg issuing = 0, trap = 0, dbg_enter = 0, debug_mode = 0, virt = 0;
    reg [1:0] priv = 3;
    integer checks = 0;
    reg [31:0] word;
    reg [63:0] value;

    karudbg_auth #(.AUTH_ROM_BASE(ROM), .AUTH_ROM_END(ROM + 64'h1_0000)) dut (
        .clk(clk), .rst(rst), .lc_i(lc), .hold_strap_i(strap), .revoke_i(revoke),
        .trng_opst_i(opst), .trng_data_i(entropy), .trng_ack_o(trng_ack),
        .debug_enable_o(debug_enable), .lc_auth_o(lc_auth), .sys_reset_o(sys_reset),
        .dm_active_i(dm_active), .dmi_valid_i(dmi_valid), .dmi_write_i(dmi_write),
        .dmi_wdata_i(dmi_wdata), .dmi_rdata_o(dmi_rdata), .authbusy_o(authbusy),
        .core_in_reset_i(core_rst), .csr_fire_i(csr_fire), .csr_sel_i(csr_sel),
        .csr_we_i(csr_we), .csr_wdata_i(csr_wdata), .csr_rdata_o(csr_rdata),
        .ex_pc_i(ex_pc), .issuing_i(issuing), .trap_i(trap), .dbg_enter_i(dbg_enter),
        .debug_mode_i(debug_mode), .priv_i(priv), .virt_i(virt));

    task check(input bit c, input string what);
        begin checks = checks + 1; if (!c) $fatal(1, "check %0d: %s", checks, what); end
    endtask
    task por(input [1:0] l, input bit s);
        begin
            @(negedge clk); rst = 1; lc = l; strap = s; revoke = 0;
            dm_active = 1; core_rst = 0; debug_mode = 0; priv = 3; virt = 0;
            ex_pc = ROM; issuing = 0; trap = 0; dbg_enter = 0;
            repeat (2) @(negedge clk); rst = 0;
        end
    endtask
    // One DMI authdata access; returns the read data for reads.
    task dmi(input bit wr, input [31:0] d, output [31:0] r);
        begin
            @(negedge clk); dmi_valid = 1; dmi_write = wr; dmi_wdata = d;
            #1 r = dmi_rdata;
            @(negedge clk); dmi_valid = 0; dmi_write = 0;
            check(authbusy, "authbusy follows an authdata access");
            @(negedge clk); check(!authbusy, "authbusy is a single cycle");
        end
    endtask
    task hw(input [31:0] d); reg [31:0] x; begin dmi(1, d, x); end endtask
    task status(output [31:0] s); begin dmi(0, 0, s); end endtask
    // One committed CSR access from the hart; returns the read value.
    task csr(input [2:0] sel, input bit we, input [63:0] d, output [63:0] r);
        begin
            @(negedge clk); csr_fire = 1; csr_sel = sel; csr_we = we; csr_wdata = d;
            issuing = 1; #1 r = csr_rdata;
            @(negedge clk); csr_fire = 0; csr_we = 0; issuing = 0;
        end
    endtask
    task cw(input [2:0] sel, input [63:0] d); reg [63:0] x; begin csr(sel, 1, d, x); end endtask
    function [2:0] st(input [31:0] s); st = s[23:21]; endfunction
    function [2:0] err(input [31:0] s); err = s[20:18]; endfunction

    initial begin
        // ---- OPEN: enabled from the first cycle; fw_lock revokes ----
        por(0, 0);
        check(debug_enable && !lc_auth && !sys_reset, "OPEN enabled out of reset");
        csr(0, 0, 0, value);
        check(value[3] && value[5:4] == 0 && !value[0], "OPEN mdbgauth view");
        @(negedge clk); debug_mode = 1;
        cw(0, 64'h4);                                   // fw_lock from Debug Mode
        check(!debug_enable, "fw_lock revokes OPEN debug");
        @(negedge clk); check(sys_reset, "relock resets a Debug-Mode hart");
        debug_mode = 0;
        @(negedge clk); check(!sys_reset, "relock ends when Debug Mode ends");
        csr(0, 0, 0, value); check(value[2] && !value[3], "fw_lock reads back");

        // ---- revoke_i ----
        por(0, 0);
        @(negedge clk); revoke = 1;
        @(negedge clk); revoke = 0;
        @(negedge clk); check(!debug_enable, "revoke_i revokes");
        csr(0, 0, 0, value); check(value[24], "revoked reads back");

        // ---- the strap holds only in AUTH ----
        por(0, 1);
        check(debug_enable && !sys_reset, "OPEN boots normally with the strap asserted");
        repeat (3) @(negedge clk); check(!sys_reset, "OPEN never held");
        // ---- DISABLED: never enabled, mailbox closed, strap ignored ----
        por(2, 1);
        check(!debug_enable && !sys_reset, "DISABLED boots normally with the strap asserted");
        status(word); check(st(word) == 3 && word[25:24] == 2, "DISABLED status CLOSED");
        hw(32'h10a50001); status(word);
        check(err(word) == 4, "DISABLED REQUEST is BAD_STATE");
        // ---- AUTH: releasing the strap boots without a request ----
        por(1, 1);
        check(sys_reset, "AUTH strap holds");
        @(negedge clk); strap = 0;
        @(negedge clk); @(negedge clk); check(!sys_reset, "strap release boots");

        // ---- AUTH, no strap: normal boot, window closes on leaving ROM ----
        por(1, 0);
        check(!debug_enable && !sys_reset, "AUTH boots locked");
        status(word); check(st(word) == 0 && word[31:28] == 6 && word[27:26] == 1, "AUTH IDLE status");
        hw(32'h10a50001); status(word); check(err(word) == 4, "REQUEST refused without hold");
        @(negedge clk); ex_pc = OUT; issuing = 1;
        @(negedge clk); issuing = 0; ex_pc = ROM;
        status(word); check(st(word) == 3, "issue outside ROM closes the window");
        hw(32'h0000000f); hw(32'h20000001); status(word);
        check(err(word) == 4, "SEND refused when CLOSED");

        // ---- AUTH with strap: hold, REQUEST, mailbox, unlock ----
        por(1, 1);
        check(sys_reset && !debug_enable, "strap holds the hart");
        status(word); check(st(word) == 1 && word[9:5] == 16 && word[4:0] == 0, "HOLD status");
        hw(32'h10a40001); status(word); check(err(word) == 3 && sys_reset, "bad key is BAD_OP");
        hw(32'h10a50003); status(word); check(err(word) == 3, "error is sticky");
        hw(32'hf0000000); status(word); check(err(word) == 0, "ABORT clears errors");
        csr(4, 0, 0, value); check(value[24] && !value[25], "ABORT raises the session event");
        cw(0, 64'h200_0000); csr(4, 0, 0, value); check(!value[24], "ROM acknowledges the event");
        hw(32'h01a50001); status(word); check(err(word) == 3, "reserved header bits");
        hw(32'hf0000000);
        hw(32'h10a50001);
        @(negedge clk); check(!sys_reset, "REQUEST releases the hold");
        status(word); check(st(word) == 2 && err(word) == 0, "REQUESTED");
        csr(0, 0, 0, value); check(value[7] && value[23:16] == 1 && !value[6], "auth_req and perm_req");
        hw(32'h10a50001); status(word); check(err(word) == 4, "second REQUEST refused");
        hw(32'hf0000000);
        // ROM -> host: challenge words
        for (integer k = 0; k < 3; k = k + 1) cw(2, 64'hc0de0000 + k);
        status(word); check(word[4:0] == 3, "TX available");
        hw(32'h30000004); status(word); check(err(word) == 2, "RECV beyond TX is UNDERFLOW");
        hw(32'hf0000000);
        for (integer k = 0; k < 3; k = k + 1) cw(2, 64'hc0de0000 + k);
        hw(32'h30000002);                               // reads now return data
        dmi(0, 0, word); check(word == 32'hc0de0000, "RECV pops first word");
        dmi(0, 0, word); check(word == 32'hc0de0001, "RECV pops second word");
        status(word); check(!word[10] && word[4:0] == 1, "RECV done");
        hw(32'h30000001); hw(32'h00000000);
        status(word); check(!word[10] && word[4:0] == 1, "STATUS cancels RECV");
        hw(32'h30000001); dmi(0, 0, word); check(word == 32'hc0de0002, "last TX word");
        // TX full is a ROM-side sticky error
        for (integer k = 0; k < 17; k = k + 1) cw(2, k);
        csr(4, 0, 0, value); check(value[13] && value[9:5] == 0, "TX_FULL sticky");
        hw(32'hf0000000);
        csr(4, 0, 0, value); check(!value[13] && value[9:5] == 16, "ABORT clears TX side");
        // host -> ROM: response words, with interrupted-SEND accounting
        hw(32'h20000011); status(word); check(err(word) == 1, "SEND 17 is OVERFLOW");
        hw(32'hf0000000);
        hw(32'h20000003);
        hw(32'h11111111);
        status(word); check(word[15:11] == 2, "SEND remaining reported");
        hw(32'h22222222); hw(32'h33333333);
        status(word); check(word[15:11] == 0 && word[9:5] == 13, "SEND complete");
        csr(1, 0, 0, value); check(value[32] && value[31:0] == 32'h11111111, "RX head visible");
        csr(1, 1, 0, value); check(value[31:0] == 32'h11111111, "pop returns the word");
        csr(1, 1, 0, value); check(value[31:0] == 32'h22222222, "second pop");
        csr(1, 1, 0, value); check(value[31:0] == 32'h33333333, "third pop");
        csr(1, 1, 0, value); check(!value[32] && value[31:0] == 0, "empty pop is invalid, no effect");
        // TRNG
        opst = 2; csr(3, 1, 0, value); check(value[31:30] == 2 && value[15:0] == 16'hbeef, "ES16 entropy");
        opst = 1; csr(3, 1, 0, value); check(value[31:30] == 1 && value[15:0] == 0, "WAIT carries no entropy");
        opst = 2;
        // The ROM has consumed response words, so any session reset now
        // closes the window in hardware (contract 4.1).
        csr(4, 0, 0, value); check(value[25] && value[2:0] == 0, "response consumption is recorded");
        hw(32'h20000002); hw(32'h12345678);
        @(negedge clk); dm_active = 0;
        repeat (3) @(negedge clk); dm_active = 1;
        csr(4, 0, 0, value);
        check(value[24] && value[4:0] == 0 && value[12:10] == 3, "deactivation after consumption closes the window");
        csr(0, 0, 0, value); check(value[1], "boot_done set by the session close");
        // ---- session resets before consumption never wrap or close ----
        por(1, 1);
        hw(32'h10a50001);
        cw(2, 64'h11);                                  // challenge word
        for (integer k = 0; k < 16; k = k + 1) hw(32'hf0000000);
        csr(4, 0, 0, value);
        check(value[24] && !value[25] && value[12:10] == 2 && value[9:5] == 16,
              "16 ABORTs: event visible, TX cleared, window open");
        cw(0, 64'h200_0000);
        for (integer k = 0; k < 32; k = k + 1) hw(32'hf0000000);
        csr(4, 0, 0, value); check(value[24] && value[12:10] == 2, "32 ABORTs: event still visible");
        cw(0, 64'h200_0000);
        // ---- after consumption, 16 and 32 resets while the ROM is paused ----
        hw(32'h20000002); hw(32'haaaa0001); hw(32'haaaa0002);
        cw(1, 0);                                       // ROM pops the first word
        for (integer k = 0; k < 16; k = k + 1) hw(32'hf0000000);
        csr(4, 0, 0, value); check(value[12:10] == 3, "16 ABORTs after consumption: window closed");
        for (integer k = 0; k < 16; k = k + 1) hw(32'hf0000000);
        csr(4, 0, 0, value); check(value[12:10] == 3, "32 ABORTs after consumption: still closed");
        cw(0, 1); @(negedge clk); check(!debug_enable, "no unlock after the session close");
        // ---- ABORT coinciding with the first RX pop ----
        por(1, 1);
        hw(32'h10a50001);
        hw(32'h20000001); hw(32'hbbbb0001);
        @(negedge clk);
        dmi_valid = 1; dmi_write = 1; dmi_wdata = 32'hf0000000;
        csr_fire = 1; csr_sel = 1; csr_we = 1; csr_wdata = 0; issuing = 1;
        @(negedge clk); dmi_valid = 0; dmi_write = 0; csr_fire = 0; csr_we = 0; issuing = 0;
        csr(4, 0, 0, value); check(value[12:10] == 3 && value[25], "ABORT with the first pop closes the window");
        // ---- deactivation coinciding with an unlock attempt after consumption ----
        por(1, 1);
        hw(32'h10a50001);
        hw(32'h20000001); hw(32'hcccc0001); cw(1, 0);
        @(negedge clk); dm_active = 0;
        csr_fire = 1; csr_sel = 0; csr_we = 1; csr_wdata = 1; issuing = 1;
        @(negedge clk); csr_fire = 0; csr_we = 0; issuing = 0; dm_active = 1;
        @(negedge clk); check(!debug_enable, "session reset dominates a same-cycle unlock");
        // ---- a system reset during the window closes it (plan 2.2) ----
        por(1, 1);
        hw(32'h10a50001);
        hw(32'h20000001); hw(32'hdddd0001);
        @(negedge clk); core_rst = 1;
        @(negedge clk); core_rst = 0;
        csr(0, 0, 0, value); check(value[1], "system reset in the window sets boot_done");
        status(word); check(st(word) == 3, "system reset in the window closes it");
        cw(0, 1); @(negedge clk); check(!debug_enable, "no unlock after a system reset");
        // ---- the boot hold itself does not close the window ----
        por(1, 1);
        repeat (4) @(negedge clk);
        csr(0, 0, 0, value); check(!value[1], "the POR boot hold is not a closing reset");
        // ---- CSR accesses in a reset cycle have no effect ----
        por(1, 1);
        hw(32'h10a50001);
        hw(32'h20000001); hw(32'heeee0001);
        @(negedge clk); core_rst = 1;
        csr_fire = 1; csr_sel = 1; csr_we = 1; issuing = 0;
        @(negedge clk); csr_fire = 1; csr_sel = 0; csr_we = 1; csr_wdata = 1;
        @(negedge clk); csr_fire = 0; csr_we = 0; core_rst = 0;
        @(negedge clk); check(!debug_enable, "unlock in a reset cycle is rejected");
        csr(4, 0, 0, value); check(!value[25], "a pop in a reset cycle consumes nothing");
        // ---- unlock predicate negatives, each in an otherwise legal cycle ----
        por(1, 1);
        hw(32'h10a50001);
        @(negedge clk); priv = 1; cw(0, 1); priv = 3;
        check(!debug_enable, "no unlock from S-mode");
        @(negedge clk); virt = 1; cw(0, 1); virt = 0;
        check(!debug_enable, "no unlock with V=1");
        @(negedge clk); debug_mode = 1; cw(0, 1); debug_mode = 0;
        check(!debug_enable, "no unlock from Debug Mode");
        csr(0, 0, 0, value); check(!value[1], "Debug Mode write cannot set boot_done");
        // Same-cycle trap: boot_exit_now dominates the unlock
        @(negedge clk); csr_fire = 1; csr_sel = 0; csr_we = 1; csr_wdata = 1; trap = 1; issuing = 1;
        @(negedge clk); csr_fire = 0; csr_we = 0; trap = 0; issuing = 0;
        @(negedge clk); check(!debug_enable, "trap in the unlock cycle wins");
        csr(0, 0, 0, value); check(value[1] && !value[0], "trap closed the window");

        // ---- AUTH: successful unlock, then relock ----
        por(1, 1);
        hw(32'h10a50001);
        @(negedge clk); ex_pc = OUT; cw(0, 1); ex_pc = ROM;
        check(!debug_enable, "no unlock from outside the ROM");
        por(1, 1);
        cw(0, 1); check(!debug_enable, "no unlock without REQUEST");
        por(1, 1);
        hw(32'h10a50001);
        cw(0, 1);
        @(negedge clk); check(debug_enable, "ROM unlock enables debug");
        csr(0, 0, 0, value); check(value[0] && value[8], "grant and permission read back");
        cw(0, 2); csr(0, 0, 0, value); check(value[1] && debug_enable, "boot_done keeps the grant");
        @(negedge clk); dm_active = 0; repeat (2) @(negedge clk); dm_active = 1;
        @(negedge clk); check(debug_enable, "grant survives a dmactive pulse");
        @(negedge clk); core_rst = 1; repeat (2) @(negedge clk); core_rst = 0;
        @(negedge clk); check(debug_enable, "grant survives a system reset");
        @(negedge clk); debug_mode = 1;
        cw(0, 4);
        check(!debug_enable, "fw_lock from Debug Mode revokes");
        @(negedge clk); check(sys_reset, "relock reset requested");
        debug_mode = 0;
        por(1, 1);
        check(!debug_enable, "POR re-locks");

        $display("karudbg_auth unit: PASS (%0d checks)", checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "auth unit timeout"); end
endmodule
