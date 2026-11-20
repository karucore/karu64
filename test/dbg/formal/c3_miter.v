// SPDX-License-Identifier: BSD-2-Clause
// Lemma C3 (doc/debug-auth-plan.md 5.2), DM noninterference: two copies of
// karudbg see the same debugger (K1: every DMI input) and the same mailbox
// (the authentication block's side of authdata), and anything at all on
// their hart, debug-page and System Bus ports. With the gate closed since
// power-on, the debugger must not be able to tell them apart: the DMI
// handshake, every response and everything the DM passes to the mailbox
// must be identical, cycle by cycle.
//
// test/dbg/run_auth_formal.py splices test/dbg/formal/c3_karudbg.vh into a
// build copy of this file; the property block holds the assumptions and
// assertions. The runner also builds karudbg from a formal-only copy of
// dbg/karudbg.v with one extra output, f_obs_o: the registers that the
// induction has to tie together (dmactive_q, deact_pending_q, cmd_state_q).
//
// The gate's next state. Lemma C3 holds it at 0 in both copies, so one
// input serves both. With C3_SPLIT_NEXT defined (glue lemma C3n of
// test/dbg/run_auth_compose.py, which leaves the next state free) each copy
// has an input of its own: in the cycle before a grant takes effect both
// DMs are locked and their next states may differ, since the grant depends
// on what the hart does.
module karudbg_c3 (
    input wire clk,
    input wire rst,
    // K1, shared
    input wire dmi_reset_i,
    input wire req_valid_i,
    input wire [6:0] req_addr_i,
    input wire [1:0] req_op_i,
    input wire [31:0] req_data_i,
    input wire resp_ready_i,
    // the mailbox side of the authentication block, shared
    input wire lc_auth_i,
    input wire [31:0] auth_rdata_i,
    input wire authbusy_i,
    // the gate, shared (held closed by the property block)
    input wire debug_enable_i,
`ifdef C3_SPLIT_NEXT
    // the gate's next state, free and separate for each copy
    input wire a_debug_enable_next_i, b_debug_enable_next_i,
`else
    // the gate's next state, shared (held at 0 by the property block)
    input wire debug_enable_next_i,
`endif
    // hart, debug page and System Bus: free and separate for each copy
    input wire a_hart_halted_i, b_hart_halted_i,
    input wire a_hart_resume_ack_i, b_hart_resume_ack_i,
    input wire a_hart_unavailable_i, b_hart_unavailable_i,
    input wire a_hart_reset_i, b_hart_reset_i,
    input wire a_mem_req_i, b_mem_req_i,
    input wire a_mem_write_i, b_mem_write_i,
    input wire [11:0] a_mem_addr_i, b_mem_addr_i,
    input wire [63:0] a_mem_wdata_i, b_mem_wdata_i,
    input wire [7:0] a_mem_be_i, b_mem_be_i,
    input wire a_sba_req_ready_i, b_sba_req_ready_i,
    input wire a_sba_resp_valid_i, b_sba_resp_valid_i,
    input wire [63:0] a_sba_resp_data_i, b_sba_resp_data_i,
    input wire [2:0] a_sba_resp_error_i, b_sba_resp_error_i
);
    wire a_req_ready, b_req_ready, a_resp_valid, b_resp_valid;
    wire [31:0] a_resp_data, b_resp_data;
    wire [1:0] a_resp_op, b_resp_op;
    wire a_auth_valid, b_auth_valid, a_auth_write, b_auth_write, a_dmactive, b_dmactive;
    wire [31:0] a_auth_wdata, b_auth_wdata;
    wire a_halt, b_halt, a_resume, b_resume, a_resume_auth, b_resume_auth, a_ndm, b_ndm;
    wire a_sba_valid, b_sba_valid;
    wire [63:0] a_obs, b_obs;
`ifndef C3_SPLIT_NEXT
    wire a_debug_enable_next_i = debug_enable_next_i;
    wire b_debug_enable_next_i = debug_enable_next_i;
`endif

    karudbg a (
        .clk(clk), .rst(rst), .dmi_reset_i(dmi_reset_i),
        .req_valid_i(req_valid_i), .req_ready_o(a_req_ready), .req_addr_i(req_addr_i),
        .req_op_i(req_op_i), .req_data_i(req_data_i),
        .resp_valid_o(a_resp_valid), .resp_ready_i(resp_ready_i), .resp_data_o(a_resp_data), .resp_op_o(a_resp_op),
        .halt_req_o(a_halt), .resume_req_o(a_resume), .resume_authorized_o(a_resume_auth), .ndmreset_o(a_ndm),
        .hart_halted_i(a_hart_halted_i), .hart_resume_ack_i(a_hart_resume_ack_i),
        .hart_unavailable_i(a_hart_unavailable_i), .hart_reset_i(a_hart_reset_i),
        .mem_req_i(a_mem_req_i), .mem_write_i(a_mem_write_i), .mem_addr_i(a_mem_addr_i),
        .mem_wdata_i(a_mem_wdata_i), .mem_be_i(a_mem_be_i), .mem_rdata_o(), .mem_ready_o(), .mem_error_o(),
        .sba_req_valid_o(a_sba_valid), .sba_req_ready_i(a_sba_req_ready_i), .sba_req_addr_o(), .sba_req_data_o(),
        .sba_req_size_o(), .sba_req_write_o(), .sba_resp_valid_i(a_sba_resp_valid_i), .sba_resp_ready_o(),
        .sba_resp_data_i(a_sba_resp_data_i), .sba_resp_error_i(a_sba_resp_error_i),
        .debug_enable_i(debug_enable_i), .debug_enable_next_i(a_debug_enable_next_i), .lc_auth_i(lc_auth_i),
        .auth_valid_o(a_auth_valid), .auth_write_o(a_auth_write), .auth_wdata_o(a_auth_wdata),
        .auth_rdata_i(auth_rdata_i), .authbusy_i(authbusy_i), .dmactive_o(a_dmactive), .f_obs_o(a_obs));

    karudbg b (
        .clk(clk), .rst(rst), .dmi_reset_i(dmi_reset_i),
        .req_valid_i(req_valid_i), .req_ready_o(b_req_ready), .req_addr_i(req_addr_i),
        .req_op_i(req_op_i), .req_data_i(req_data_i),
        .resp_valid_o(b_resp_valid), .resp_ready_i(resp_ready_i), .resp_data_o(b_resp_data), .resp_op_o(b_resp_op),
        .halt_req_o(b_halt), .resume_req_o(b_resume), .resume_authorized_o(b_resume_auth), .ndmreset_o(b_ndm),
        .hart_halted_i(b_hart_halted_i), .hart_resume_ack_i(b_hart_resume_ack_i),
        .hart_unavailable_i(b_hart_unavailable_i), .hart_reset_i(b_hart_reset_i),
        .mem_req_i(b_mem_req_i), .mem_write_i(b_mem_write_i), .mem_addr_i(b_mem_addr_i),
        .mem_wdata_i(b_mem_wdata_i), .mem_be_i(b_mem_be_i), .mem_rdata_o(), .mem_ready_o(), .mem_error_o(),
        .sba_req_valid_o(b_sba_valid), .sba_req_ready_i(b_sba_req_ready_i), .sba_req_addr_o(), .sba_req_data_o(),
        .sba_req_size_o(), .sba_req_write_o(), .sba_resp_valid_i(b_sba_resp_valid_i), .sba_resp_ready_o(),
        .sba_resp_data_i(b_sba_resp_data_i), .sba_resp_error_i(b_sba_resp_error_i),
        .debug_enable_i(debug_enable_i), .debug_enable_next_i(b_debug_enable_next_i), .lc_auth_i(lc_auth_i),
        .auth_valid_o(b_auth_valid), .auth_write_o(b_auth_write), .auth_wdata_o(b_auth_wdata),
        .auth_rdata_i(auth_rdata_i), .authbusy_i(authbusy_i), .dmactive_o(b_dmactive), .f_obs_o(b_obs));
endmodule
