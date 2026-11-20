// SPDX-License-Identifier: BSD-2-Clause
// A witness, not a lemma: test/dbg/run_auth_compose.py expects the assertion
// below to FAIL and keeps the trace. It is the evidence for the open point
// of the composition report on claim T1, bullet 3 (doc/debug-auth-plan.md 4).
//
// Lemma C3 gives its two copies of the DM the same authdata read data. T1
// asks only for "the same mailbox TX words". Here two copies of karudbg_auth
// have the same trusted inputs, the same DM side (every authdata access and
// the session reset: cut K1.mbox) and the same TX pushes by the hart, word
// for word and cycle for cycle; every other hart input is free and separate.
// If the read data were a function of the DM side and the TX words, a read
// of authdata would return the same word in both. It does not: the status
// word also carries the session state, the RX free count and the error
// code, which move with the hart's pops, traps and resets.
module compose_status_miter (
    input wire clk,
    input wire rst,
    // trusted inputs, shared
    input wire [1:0] lc_i,
    input wire hold_strap_i,
    input wire revoke_i,
    // the DM side (K1.mbox), shared
    input wire dm_active_i,
    input wire dmi_valid_i,
    input wire dmi_write_i,
    input wire [31:0] dmi_wdata_i,
    // the hart side (K2): free and separate for each copy
    input wire a_core_in_reset_i, b_core_in_reset_i,
    input wire a_csr_fire_i, b_csr_fire_i,
    input wire [2:0] a_csr_sel_i, b_csr_sel_i,
    input wire a_csr_we_i, b_csr_we_i,
    input wire [63:0] a_csr_wdata_i, b_csr_wdata_i,
    input wire [63:0] a_ex_pc_i, b_ex_pc_i,
    input wire a_issuing_i, b_issuing_i,
    input wire a_trap_i, b_trap_i,
    input wire a_dbg_enter_i, b_dbg_enter_i,
    input wire a_debug_mode_i, b_debug_mode_i,
    input wire [1:0] a_priv_i, b_priv_i,
    input wire a_virt_i, b_virt_i
);
    wire [31:0] a_rdata, b_rdata;

    karudbg_auth a (
        .clk(clk), .rst(rst), .lc_i(lc_i), .hold_strap_i(hold_strap_i), .revoke_i(revoke_i),
        .debug_enable_o(), .debug_enable_next_o(), .lc_auth_o(), .sys_reset_o(),
        .dm_active_i(dm_active_i), .dmi_valid_i(dmi_valid_i), .dmi_write_i(dmi_write_i),
        .dmi_wdata_i(dmi_wdata_i), .dmi_rdata_o(a_rdata), .authbusy_o(),
        .core_in_reset_i(a_core_in_reset_i), .csr_fire_i(a_csr_fire_i), .csr_sel_i(a_csr_sel_i),
        .csr_we_i(a_csr_we_i), .csr_wdata_i(a_csr_wdata_i), .csr_rdata_o(),
        .ex_pc_i(a_ex_pc_i), .issuing_i(a_issuing_i), .trap_i(a_trap_i), .dbg_enter_i(a_dbg_enter_i),
        .debug_mode_i(a_debug_mode_i), .priv_i(a_priv_i), .virt_i(a_virt_i));

    karudbg_auth b (
        .clk(clk), .rst(rst), .lc_i(lc_i), .hold_strap_i(hold_strap_i), .revoke_i(revoke_i),
        .debug_enable_o(), .debug_enable_next_o(), .lc_auth_o(), .sys_reset_o(),
        .dm_active_i(dm_active_i), .dmi_valid_i(dmi_valid_i), .dmi_write_i(dmi_write_i),
        .dmi_wdata_i(dmi_wdata_i), .dmi_rdata_o(b_rdata), .authbusy_o(),
        .core_in_reset_i(b_core_in_reset_i), .csr_fire_i(b_csr_fire_i), .csr_sel_i(b_csr_sel_i),
        .csr_we_i(b_csr_we_i), .csr_wdata_i(b_csr_wdata_i), .csr_rdata_o(),
        .ex_pc_i(b_ex_pc_i), .issuing_i(b_issuing_i), .trap_i(b_trap_i), .dbg_enter_i(b_dbg_enter_i),
        .debug_mode_i(b_debug_mode_i), .priv_i(b_priv_i), .virt_i(b_virt_i));

    // A TX push as the hart makes it: a live write access to mdbgtx.
    wire a_push = a_csr_fire_i && !a_core_in_reset_i && !a_trap_i && !a_dbg_enter_i &&
                  a_csr_we_i && a_csr_sel_i == 3'd2;
    wire b_push = b_csr_fire_i && !b_core_in_reset_i && !b_trap_i && !b_dbg_enter_i &&
                  b_csr_we_i && b_csr_sel_i == 3'd2;
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @* begin
        if (f_init) assume(rst); else assume(!rst);
        // the same mailbox TX words, in the same cycles
        assume(a_push == b_push);
        assume(!a_push || a_csr_wdata_i[31:0] == b_csr_wdata_i[31:0]);
        // expected to fail: a read of authdata returns the same word
        if (!f_init && dmi_valid_i && !dmi_write_i) assert(a_rdata == b_rdata);
    end
endmodule
