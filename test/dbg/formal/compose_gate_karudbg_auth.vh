// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of dbg/karudbg_auth.v by
// test/dbg/run_auth_compose.py; it reads only the module's ports.
    // ---- composition glue "gate": what the DM is given by this block ----
    // Lemmas C2, C3 and C7 are proved on the DM alone and assume things
    // about three of its inputs, which karudbg_core connects to outputs of
    // this block. No lemma of the plan states them, so the composition needs
    // them here. From an arbitrary state (no register initialised), with
    // every input free; f_rst marks the cycle after a POR cycle.
    reg f_valid = 1'b0;
    reg f_rst, f_next, f_access, f_lcauth;
    reg [1:0] f_lc;
    always @(posedge clk) begin
        f_valid <= 1'b1; f_rst <= rst; f_next <= debug_enable_next_o;
        f_access <= dmi_valid_i && dm_active_i; f_lcauth <= lc_auth_o; f_lc <= lc_i;
    end
    always @* if (f_valid && !f_rst) begin
        // (a) The gate is the register of its next state. C7 (DM side)
        // assumes debug_enable_i is debug_enable_next_i one clock later;
        // C2 and C3 assume both are 0. After a POR cycle the gate holds its
        // POR value instead (lemma C6v).
        assert(debug_enable_o == f_next);
        // (b) authbusy is 1 exactly in the clock after an authdata access
        // accepted by an active DM (plan 3.4): it depends on nothing but
        // what the DM forwards, never on the hart. C3 gives its two DMs the
        // same authbusy.
        assert(authbusy_o == f_access);
        // (c) "authdata is implemented" does not change between PORs.
        assert(lc_auth_o == f_lcauth);
    end
    // (c) It is set by the lifecycle sampled at POR and by nothing else.
    always @* if (f_valid && f_rst) assert(lc_auth_o == (f_lc == 2'd1));
