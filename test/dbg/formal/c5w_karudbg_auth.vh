// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py, after c5_karudbg_auth.vh: it has no reset
// assumption of its own and uses that block's f_past, f_unlock, f_done,
// f_pred (the commit predicate) and f_close (the closing events of C5).
    // ---- formal lemma C5w: the hardware window limit (WINDOW_LOG2) ----
    // Stated from ports and ghost state; win_open and win_expire are not
    // used, and win_cnt only in the strengthening invariant.
    //
    // f_wreq is a ghost copy of "the REQUEST was accepted", set by the edge
    // that accepts it. f_wage counts the clocks since that edge and stops at
    // 2^WINDOW_LOG2 + 1: in clock n after the edge (n = 1, 2, ...) it is
    // n - 1, the number of whole clocks the request has been in. Only POR
    // clears them; neither looks at the hart, the session or boot_done.
    localparam [WINDOW_LOG2+1:0] F_WLIMIT = {{(WINDOW_LOG2+1){1'b0}}, 1'b1} << WINDOW_LOG2;
    reg f_wreq;
    reg [WINDOW_LOG2+1:0] f_wage;
    wire f_waccept = dmi_valid_i && dmi_write_i && send_rem == 0 &&
                     dmi_wdata_i == 32'h10a50001 &&
                     lc_q == 2'd1 && hold_q && !f_wreq && !boot_done_q;
    always @(posedge clk) begin
        if (rst) begin f_wreq <= 1'b0; f_wage <= 0; end
        else begin
            if (f_waccept) f_wreq <= 1'b1;
            if (f_wreq && f_wage <= F_WLIMIT) f_wage <= f_wage + 1'b1;
        end
    end
    // The request is recorded exactly by the accepting edge.
    always @(posedge clk) if (f_past) assert(f_wreq == auth_req_q);
    generate if (WINDOW_LOG2 != 0) begin : f_wlimit
        always @(posedge clk) if (f_past) begin
            // (a) Once 2^WINDOW_LOG2 clocks have passed, the next edge sets
            // boot_done: it is set in every clock after clock 2^WINDOW_LOG2 + 1.
            assert(f_wage <= F_WLIMIT || boot_done_q);
            // (b) The grant does not rise on that edge or on any later one.
            assert(!(f_wage > F_WLIMIT && !f_unlock && auth_unlock_q));
            // The limit is exact. (c) On each of the first 2^WINDOW_LOG2
            // edges the timer refuses nothing: the commit predicate sets the
            // grant.
            assert(!(f_pred && f_wage <= F_WLIMIT) || auth_unlock_q);
            // (d) Before the edge of (a), boot_done is set only by a closing
            // event of C5.
            assert(!(!f_done && boot_done_q) || f_close || f_wage > F_WLIMIT);
`ifdef FORMAL_STRENGTHEN
            // Strengthening for the induction: while boot_done is clear, the
            // block's counter is the ghost one (both 0 before the REQUEST).
            // The mutant runs leave it out, so a control fails on (a) to (d).
            assert(boot_done_q || {1'b0, win_cnt} == f_wage);
`endif
        end
    end else begin : f_wnone
        // WINDOW_LOG2 = 0, no limit in hardware: (c) and (d) on every edge.
        always @(posedge clk) if (f_past) begin
            assert(!f_pred || auth_unlock_q);
            assert(!(!f_done && boot_done_q) || f_close);
        end
    end endgenerate
