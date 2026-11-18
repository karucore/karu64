// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C7, DM side (plan 3.5 items 1-2): from an arbitrary
    // state (no register initialised), with the gate registered as karudbg_auth
    // provides it. Every property spans at most two cycles, so a short BMC from
    // a free state covers every reachable history.
    reg f_valid = 1'b0;
    reg f_next, f_en, f_idle, f_rd, f_fire, f_rst;
    reg [6:0] f_addr;
    always @(posedge clk) begin
        f_valid <= 1'b1;
        f_next <= debug_enable_next_i; f_en <= dbg_en; f_rst <= rst;
        f_idle <= cmd_state_q == CMD_IDLE;
        f_fire <= dmi_fire; f_rd <= req_op_i == 2'd1; f_addr <= req_addr_i;
    end
    // environment: debug_enable_i is the register of debug_enable_next_i
    always @* if (f_valid) assume(debug_enable_i == f_next);
    always @* if (f_valid && !rst && !f_rst) begin
        // every DM output is 0 in every locked cycle (ndmreset_o included)
        if (!dbg_en) assert(!halt_req_o && !resume_req_o && !resume_authorized_o &&
                            !ndmreset_o && !sba_req_valid_o);
        // no command launches while locked
        if (!f_en && f_idle) assert(cmd_state_q == CMD_IDLE);
        // the hart sees only the safe sequence while locked
        if (!dbg_en && mem_addr_i >= `KARUDBG_ABSTRACT && mem_addr_i < `KARUDBG_DATA)
            assert(mem_rdata_o == {2{32'h00100073}});
        if (!dbg_en && (mem_aligned_addr == `KARUDBG_DATA || mem_aligned_addr == `KARUDBG_FLAGS))
            assert(mem_rdata_o == 64'b0);
        // a DMI read accepted while locked returns only the locked view
        if (f_fire && f_rd && !f_en && f_addr != 7'h10 && f_addr != 7'h11 && f_addr != 7'h30)
            assert(resp_data_o == 0);
    end
