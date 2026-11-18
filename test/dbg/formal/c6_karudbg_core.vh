// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C6cone: the hart-side reset (every submodule free) ----
    // The reset that reaches the core, the island and the routers is
    // asserted by POR, the platform hart reset, ndmreset and the
    // authentication block's hold/relock reset, and by nothing else.
    // check_auth_reset.py checks that those instances take core_rst.
    always @* begin
        if (rst || hart_reset_i || ndmreset_o || auth_reset_o) assert(core_rst);
        if (core_rst) assert(rst || hart_reset_i || ndmreset_o || auth_reset_o);
    end
