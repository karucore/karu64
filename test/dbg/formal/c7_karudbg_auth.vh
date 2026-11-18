// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C7, relock (plan 3.5 item 3): from an arbitrary state,
    // a hart in Debug Mode with the gate closed is reset on the next cycle.
    reg f_valid = 1'b0;
    reg f_relock, f_rst;
    always @(posedge clk) begin
        f_valid <= 1'b1; f_rst <= rst;
        f_relock <= !debug_enable_o && debug_mode_i && !core_in_reset_i;
    end
    always @* if (f_valid && !rst && !f_rst) begin
        if (f_relock) assert(sys_reset_o);
        // revocation is monotone: once fw_lock or revoke_q is set, the gate
        // stays closed
        if (fw_lock_q || revoke_q) assert(!debug_enable_next_o);
    end
