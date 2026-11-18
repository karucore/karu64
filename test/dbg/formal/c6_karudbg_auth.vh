// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C6v: POR values, from an arbitrary earlier state ----
    // No register is initialised and no input is constrained. After any
    // cycle with rst=1 the POR-domain state holds exactly these values,
    // including the ones sampled from the trust inputs in that cycle.
    reg f_valid = 1'b0;
    reg f_rst, f_strap, f_rev;
    reg [1:0] f_lc;
    always @(posedge clk) begin
        f_valid <= 1'b1; f_rst <= rst; f_lc <= lc_i; f_strap <= hold_strap_i; f_rev <= revoke_i;
    end
    always @* if (f_valid && f_rst) begin
        assert(lc_q == (f_lc == 2'd3 ? 2'd2 : f_lc));            // 3 decodes to DISABLED
        assert(hold_q == (f_strap && f_lc == 2'd1));              // hold only in AUTH
        assert(sys_reset_o == (f_strap && f_lc == 2'd1));
        assert(revoke_q == f_rev);
        assert(debug_enable_o == (f_lc == 2'd0 && !f_rev));       // open only in OPEN, unrevoked
        assert(!auth_unlock_q && !auth_req_q && !boot_done_q && !fw_lock_q && perm_req_q == 0);
        assert(!sess_event_q && !resp_started_q && !hart_started_q);
        assert(rx_count == 0 && tx_count == 0 && send_rem == 0 && recv_rem == 0);
        assert(rx_rd == 0 && rx_wr == 0 && tx_rd == 0 && tx_wr == 0);
        assert(err_q == 0 && !tx_full_q && !authbusy_o);
    end
