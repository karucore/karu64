// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of test/dbg/formal/c3_miter.v by
// test/dbg/run_auth_formal.py (plan 5.2); it reads both copies' internals.
    // ---- formal lemma C3 (plan 5.2): DM noninterference while locked ----
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @* begin
        if (f_init) assume(rst); else assume(!rst);
        assume(!debug_enable_i && !debug_enable_next_i);   // locked since POR
    end
    // Checked in every cycle after the reset cycle, the first one included:
    // the DMI can accept a request in it.
    always @* if (!f_init) begin
        // What the debugger sees: the DMI handshake and every response.
        assert(a_req_ready == b_req_ready);
        assert(a_resp_valid == b_resp_valid);
        assert(!a_resp_valid || (a_resp_data == b_resp_data && a_resp_op == b_resp_op));
        // What reaches the mailbox from the debugger's side.
        assert(a_auth_valid == b_auth_valid && a_auth_write == b_auth_write && a_dmactive == b_dmactive);
        assert(!a_auth_valid || a_auth_wdata == b_auth_wdata);
        // Strengthening for the induction, not claims: the observed registers
        // ({dmactive_q, deact_pending_q, cmd_state_q}) are equal in the two
        // copies, and the command engine is idle in both (C2 proves it of one).
        assert(a_obs == b_obs);
        assert(a_obs[1:0] == 2'd0);
    end
