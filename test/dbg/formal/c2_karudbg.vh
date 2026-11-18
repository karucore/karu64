// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C2 (plan 5.2): DM inert while locked since reset ----
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @* begin
        if (f_init) assume(rst); else assume(!rst);
        assume(!debug_enable_i && !debug_enable_next_i);   // locked since POR
    end
    reg f_past = 1'b0;
    reg f_rd;
    reg [6:0] f_addr;
    always @(posedge clk) begin
        f_past <= !f_init;
        if (dmi_fire) begin f_rd <= req_op_i == 2'd1; f_addr <= req_addr_i; end
    end
    always @(posedge clk) if (f_past) begin
        // no effect on the platform or the hart
        assert(!halt_req_o && !resume_req_o && !resume_authorized_o && !ndmreset_o);
        assert(!sba_req_valid_o);
        // the engine and every debugger-written register keep reset values
        assert(cmd_state_q == CMD_IDLE && command_q == 0 && data_q == 0 && autoexec_q == 0);
        assert(progbuf_q[0] == 0 && progbuf_q[1] == 0 && progbuf_q[2] == 0 && progbuf_q[3] == 0 &&
               progbuf_q[4] == 0 && progbuf_q[5] == 0 && progbuf_q[6] == 0 && progbuf_q[7] == 0);
        assert(!halt_q && !ndmreset_q && !resume_pending_q && cmderr_q == 0);
        // nothing about the hart is disclosed over DMI
        assert(!(resp_valid_o && f_rd && f_addr != 7'h10 && f_addr != 7'h11 && f_addr != 7'h30) ||
               resp_data_o == 0);
        assert(!(resp_valid_o && f_rd && f_addr == 7'h11) || resp_data_o == 0 || (resp_data_o[31:7] == 0 && resp_data_o[5:0] == 6'h03));
        assert(!(resp_valid_o && f_rd && f_addr == 7'h10) || resp_data_o[31:1] == 0);
        // the hart-facing page offers no debugger content
        assert(!(mem_addr_i >= `KARUDBG_ABSTRACT && mem_addr_i < `KARUDBG_DATA) ||
               mem_rdata_o == {2{32'h00100073}});
        assert(!(mem_aligned_addr == `KARUDBG_DATA || mem_aligned_addr == `KARUDBG_FLAGS) ||
               mem_rdata_o == 64'b0);
    end
