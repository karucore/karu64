// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of dbg/karudbg.v by
// test/dbg/run_auth_compose.py; it reads the module internals.
    // ---- composition glue "dm": two cycles that lemmas C2 and C7 leave out ----
    // From an arbitrary state (no register initialised), every input free,
    // the gate included. No assumption.
    reg f_valid = 1'b0;
    reg f_rst, f_en, f_fire, f_rd;
    reg [6:0] f_addr;
    always @(posedge clk) begin
        f_valid <= 1'b1; f_rst <= rst; f_en <= dbg_en;
        f_fire <= dmi_fire; f_rd <= req_op_i == 2'd1; f_addr <= req_addr_i;
    end
    // (a) The first cycle after a POR cycle. Lemma C2 states its properties
    // from the second cycle after POR and lemma C7 (DM side) skips the cycle
    // after a reset cycle, so neither says anything about this one. In it,
    // whatever the gate is: no DM output is asserted, the command engine is
    // idle, no DMI response is offered, and with the gate closed the hart's
    // debug page offers only the safe sequence.
    always @* if (f_valid && f_rst && !rst) begin
        assert(!halt_req_o && !resume_req_o && !resume_authorized_o && !ndmreset_o);
        assert(!sba_req_valid_o);
        assert(cmd_state_q == CMD_IDLE);
        assert(!resp_valid_o);
        if (!dbg_en && mem_addr_i >= `KARUDBG_ABSTRACT && mem_addr_i < `KARUDBG_DATA)
            assert(mem_rdata_o == {2{32'h00100073}});
        if (!dbg_en && (mem_aligned_addr == `KARUDBG_DATA || mem_aligned_addr == `KARUDBG_FLAGS))
            assert(mem_rdata_o == 64'b0);
    end
    // (b) The locked view of dmcontrol and dmstatus after a fall of the
    // gate. Lemma C7 (DM side) states the locked view for every register but
    // dmcontrol, dmstatus and authdata; lemma C2 states these two only for a
    // DM locked since POR. For a read accepted in any locked cycle, whatever
    // happened before: dmcontrol shows dmactive only, and dmstatus shows
    // version 3, authenticated=0 and authbusy only (or reads 0, inactive).
    always @* if (f_valid && !rst && !f_rst && f_fire && f_rd && !f_en) begin
        if (f_addr == 7'h10) assert(resp_data_o[31:1] == 0);
        if (f_addr == 7'h11)
            assert(resp_data_o == 0 || (resp_data_o[31:7] == 0 && resp_data_o[5:0] == 6'h03));
    end
