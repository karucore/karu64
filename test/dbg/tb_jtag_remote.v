// OpenOCD transport fixture: real karudbg DM, hart held running.
// This checks TAP/DTM/CDC/DMI, not core instruction execution.
// SPDX-License-Identifier: BSD-2-Clause
module tb_jtag_remote (
    input wire clk, input wire rst,
    input wire tck, input wire tms, input wire tdi, input wire trst_n,
    output wire tdo,
    output reg [31:0] request_count
);
    wire req_valid, req_ready, resp_valid, resp_ready, dmi_reset;
    wire [6:0] req_addr;
    wire [1:0] req_op, resp_op;
    wire [31:0] req_data, resp_data;
    wire halt_req, resume_req, ndmreset;
    karudbg_jtag transport (
        .clk(clk),.rst(rst),.tck(tck),.tms(tms),.tdi(tdi),.trst_n(trst_n),
        .tdo(tdo),.tdo_oe(),.dmi_reset_o(dmi_reset),
        .req_valid_o(req_valid),.req_ready_i(req_ready),.req_addr_o(req_addr),
        .req_op_o(req_op),.req_data_o(req_data),.resp_valid_i(resp_valid),
        .resp_ready_o(resp_ready),.resp_data_i(resp_data),.resp_op_i(resp_op)
    );
    karudbg dm (
        .clk(clk),.rst(rst),.dmi_reset_i(dmi_reset),
        .req_valid_i(req_valid),.req_ready_o(req_ready),.req_addr_i(req_addr),
        .req_op_i(req_op),.req_data_i(req_data),.resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),.resp_data_o(resp_data),.resp_op_o(resp_op),
        .halt_req_o(halt_req),.resume_req_o(resume_req),.ndmreset_o(ndmreset),
        .hart_halted_i(1'b0),.hart_resume_ack_i(1'b0),
        .hart_unavailable_i(1'b0),.hart_reset_i(rst),
        .mem_req_i(1'b0),.mem_write_i(1'b0),.mem_addr_i(12'b0),
        .mem_wdata_i(64'b0),.mem_be_i(8'b0),
        .mem_rdata_o(),.mem_ready_o(),.mem_error_o()
    );
    always @(posedge clk)
        if (rst) request_count<=0;
        else if(req_valid && req_ready) request_count<=request_count+1'b1;
endmodule
