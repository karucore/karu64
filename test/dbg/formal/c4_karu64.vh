// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C4 (plan 5.2): one step from an arbitrary state ----
    // No register is initialised and no input is constrained, so this is a
    // sound over-approximation of every reachable state.
    reg f_valid = 1'b0;
    reg f_mode, f_en, f_rst;
    always @(posedge clk) begin
        f_valid <= 1'b1; f_mode <= debug_mode; f_en <= debug_enable_i; f_rst <= rst;
    end
    always @* begin
        if (f_valid && !f_rst) assert(!(debug_mode && !f_mode && !f_en));
        assert(!dbg_enter || debug_enable_i);
        // reset value: after any cycle with rst=1 the hart is not in Debug Mode
        if (f_valid && f_rst) assert(!debug_mode);
    end
