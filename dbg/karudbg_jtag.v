// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright 2026 Markku-Juhani O. Saarinen.
// SPDX-License-Identifier: SHL-0.51
// Origin: pulp-platform/riscv-dbg, src/dmi_jtag.sv, revision
// 643607e19df3435cfd77cc56143e2637f5900a6e.
// https://github.com/pulp-platform/riscv-dbg/blob/643607e19df3435cfd77cc56143e2637f5900a6e/src/dmi_jtag.sv
// Adaptation: Debug 1.0 DTM, Verilog-2001, local four-phase CDC; dmireset
// clears only sticky status; hard reset flushes the DMI channel before reuse.
// Solderpad Hardware License 0.51; see LICENSE.Solderpad.

module karudbg_jtag #(
    parameter [31:0] IDCODE = 32'h0000_0db3
) (
    input wire clk, input wire rst,
    input wire tck, input wire tms, input wire tdi, input wire trst_n,
    output wire tdo, output wire tdo_oe, output wire dmi_reset_o,
    output wire req_valid_o, input wire req_ready_i,
    output wire [6:0] req_addr_o, output wire [1:0] req_op_o,
    output wire [31:0] req_data_o,
    input wire resp_valid_i, output wire resp_ready_o,
    input wire [31:0] resp_data_i, input wire [1:0] resp_op_i
);
    wire capture, shift, update, tap_reset, dtm_sel, dmi_sel;
    wire t_req_ready, t_resp_valid;
    wire hard_reset, clear;
    wire [33:0] t_response;
    wire [40:0] core_request;
    wire issue;
    wire reset_n;
    reg [40:0] dmi_shift;
    reg [31:0] dtm_shift;
    reg [6:0] last_address;
    reg [31:0] last_data;
    reg [1:0] error;
    reg active;
    wire [1:0] capture_status;

    assign reset_n = trst_n && !rst;
    assign hard_reset = dtm_sel && update && dtm_shift[17];
    assign clear = tap_reset || hard_reset;
    assign issue = dmi_sel && update && !clear && error == 0 &&
        !active && t_req_ready &&
        (dmi_shift[1:0] == 1 || dmi_shift[1:0] == 2);
    assign capture_status = error != 0 ? error : (active ? 2'd3 : 2'd0);
    assign req_addr_o = core_request[40:34];
    assign req_data_o = core_request[33:2];
    assign req_op_o = core_request[1:0];

    karudbg_jtag_tap #(.IDCODE(IDCODE)) tap (
        .tck(tck), .tms(tms), .tdi(tdi), .trst_n(reset_n),
        .tdo(tdo), .tdo_oe(tdo_oe),
        .capture_o(capture), .shift_o(shift), .update_o(update),
        .reset_o(tap_reset), .dtmcs_select_o(dtm_sel), .dmi_select_o(dmi_sel),
        .dtmcs_tdo_i(dtm_shift[0]), .dmi_tdo_i(dmi_shift[0])
    );
    karudbg_cdc cdc (
        .clk(clk), .rst(rst), .tck(tck), .trst_n(trst_n), .clear_i(clear),
        .t_req_valid_i(issue), .t_req_ready_o(t_req_ready), .t_req_i(dmi_shift),
        .t_resp_valid_o(t_resp_valid), .t_resp_ready_i(1'b1), .t_resp_o(t_response),
        .req_valid_o(req_valid_o), .req_ready_i(req_ready_i), .req_o(core_request),
        .resp_valid_i(resp_valid_i), .resp_ready_o(resp_ready_o),
        .dmi_reset_o(dmi_reset_o),
        .resp_i({resp_data_i, resp_op_i})
    );

    always @(posedge tck or negedge reset_n) begin
        if (!reset_n) begin
            dmi_shift <= 0; dtm_shift <= 0;
            last_address <= 0; last_data <= 0;
            error <= 0; active <= 0;
        end else if (clear) begin
            dmi_shift <= 0; dtm_shift <= 0;
            last_address <= 0; last_data <= 0;
            error <= 0; active <= 0;
        end else begin
            if (t_resp_valid) begin
                active <= 0;
                last_data <= t_response[33:2];
                if (error == 0 && t_response[1:0] != 0)
                    error <= t_response[1:0] == 3 ? 2'd3 : 2'd2;
            end
            if (capture && dtm_sel)
                // errinfo=0 (unimplemented), idle=1, abits=7, version=1.
                dtm_shift <= {17'b0, 3'd1, error, 6'd7, 4'd1};
            if (shift && dtm_sel) dtm_shift <= {tdi, dtm_shift[31:1]};
            if (capture && dmi_sel) begin
                dmi_shift <= {last_address, last_data, capture_status};
                if (active && error == 0) error <= 3;
            end
            if (shift && dmi_sel) dmi_shift <= {tdi, dmi_shift[40:1]};
            if (dmi_sel && update && error == 0 && dmi_shift[1:0] != 0) begin
                if (active || !t_req_ready) error <= 3;
                else if (dmi_shift[1:0] == 3) error <= 2;
                else begin
                    active <= 1;
                    last_address <= dmi_shift[40:34];
                end
            end
            // Debug 1.0: dmireset does not cancel an outstanding transaction.
            if (dtm_sel && update && dtm_shift[16]) error <= 0;
        end
    end
endmodule
