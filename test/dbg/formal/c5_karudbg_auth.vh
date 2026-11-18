// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C5 (plan 5.2), all inputs free after one POR ----
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @* if (f_init) assume(rst); else assume(!rst);
    reg f_past = 1'b0;
    reg f_unlock, f_done, f_lock, f_rev, f_req;
    reg [1:0] f_lc;
    reg f_pred;
    always @(posedge clk) begin
        f_past <= !f_init;
        f_unlock <= auth_unlock_q; f_done <= boot_done_q; f_lock <= fw_lock_q;
        f_rev <= revoke_q; f_req <= auth_req_q; f_lc <= lc_q;
        // the commit predicate, restated from ports and state
        f_pred <= csr_fire_i && !core_in_reset_i && csr_we_i && csr_sel_i == 3'd0 && csr_wdata_i[0] &&
                  ex_pc_i >= AUTH_ROM_BASE && ex_pc_i < AUTH_ROM_END && priv_i == 2'd3 && !virt_i &&
                  !debug_mode_i && lc_q == 2'd1 && auth_req_q && !boot_done_q &&
                  !trap_i && !dbg_enter_i &&
                  // a same-cycle session reset closes the window only after
                  // a response word was consumed (contract 4.1)
                  !((!dm_active_i || (dmi_valid_i && dmi_write_i && send_rem == 0 &&
                                      dmi_wdata_i[31:24] == 8'hf0)) && resp_started_q);
    end
    always @(posedge clk) if (f_past) begin
        assert(!f_unlock || auth_unlock_q);
        assert(!f_done || boot_done_q);
        assert(!f_lock || fw_lock_q);
        assert(!f_rev || revoke_q);
        assert(!f_req || auth_req_q);
        assert(lc_q == f_lc);
        assert(lc_q != 2'd3);
        assert(debug_enable_o == ((lc_q == 2'd0 || (lc_q == 2'd1 && auth_unlock_q)) &&
                                  !fw_lock_q && !revoke_q));
        assert(!(lc_q == 2'd2 && debug_enable_o));
        assert(!auth_unlock_q || lc_q == 2'd1);
        assert(f_unlock || !auth_unlock_q || f_pred);
        assert(!(f_done && !f_unlock && auth_unlock_q));
        assert(!(lc_q == 2'd0 && !fw_lock_q && !revoke_q && sys_reset_o));
        assert(rx_count <= 5'd16 && tx_count <= 5'd16 && send_rem <= 5'd16 - rx_count);
        // strengthening: counts agree with the circular pointers
        assert(rx_count[3:0] == rx_wr - rx_rd && tx_count[3:0] == tx_wr - tx_rd);
        assert(recv_rem <= tx_count && recv_rem <= 5'd16);
    end
    // ---- window closing (plan 2.2, 3.1; contract 4.1), stated from ports ----
    // Ghost copies of "hart has left reset" and "ROM has popped a response
    // word", then the four closing events. Each must set boot_done on the
    // next edge; none of this refers to boot_done_set or its terms.
    reg f_started, f_resp, f_close;
    wire f_live = csr_fire_i && !core_in_reset_i && !trap_i && !dbg_enter_i;
    wire f_pop = f_live && csr_we_i && csr_sel_i == 3'd1 && rx_count != 0;
    wire f_sess = !dm_active_i || (dmi_valid_i && dmi_write_i && send_rem == 0 &&
                                   dmi_wdata_i[31:24] == 8'hf0);
    wire f_exit = !core_in_reset_i && (trap_i || dbg_enter_i ||
                  (issuing_i && !(ex_pc_i >= AUTH_ROM_BASE && ex_pc_i < AUTH_ROM_END)));
    always @(posedge clk) begin
        if (rst) begin f_started <= 0; f_resp <= 0; f_close <= 0; end
        else begin
            if (!core_in_reset_i) f_started <= 1;
            if (f_pop) f_resp <= 1;
            f_close <= f_exit ||                                  // trap, Debug entry, issue outside the ROM
                       (core_in_reset_i && f_started) ||         // any reset after the hart first ran
                       (f_sess && (f_resp || f_pop)) ||          // session reset after a response word
                       (f_live && csr_we_i && csr_sel_i == 3'd0 && csr_wdata_i[1] && !debug_mode_i);
        end
    end
    always @(posedge clk) if (f_past) begin
        assert(f_started == hart_started_q && f_resp == resp_started_q);
        assert(!f_close || boot_done_q);
    end
    // ---- REQUEST and hold (plan 3.1): only a well-formed REQUEST in AUTH,
    // while held and before any earlier one, records the request; the hold
    // ends only by that REQUEST or by releasing the strap, and never returns.
    reg f_hold, f_strap, f_request;
    always @(posedge clk) begin
        f_hold <= hold_q; f_strap <= hold_strap_i;
        f_request <= dmi_valid_i && dmi_write_i && send_rem == 0 &&
                     dmi_wdata_i == 32'h10a50001 &&
                     lc_q == 2'd1 && hold_q && !auth_req_q && !boot_done_q;
    end
    always @(posedge clk) if (f_past) begin
        assert(f_req || !auth_req_q || f_request);
        assert(!auth_req_q || lc_q == 2'd1);
        assert(!hold_q || lc_q == 2'd1);
        assert(!hold_q || f_hold);
        assert(!(f_hold && !hold_q) || f_request || !f_strap);
    end
