// SPDX-License-Identifier: BSD-3-Clause
// Xilinx UltraScale+ USER4 nested-TAP bridge. USER1/2 remain available to
// Vivado's debug hub; USER4 must not be allocated to another design block.
module karudbg_bscan (
    input wire clk,
    input wire rst,
    output wire dmi_reset_o,
    output wire req_valid_o,
    input wire req_ready_i,
    output wire [6:0] req_addr_o,
    output wire [1:0] req_op_o,
    output wire [31:0] req_data_o,
    input wire resp_valid_i,
    output wire resp_ready_o,
    input wire [31:0] resp_data_i,
    input wire [1:0] resp_op_i
);
    wire drck, tck, raw_tck, frame_tck, tdi, tdo, capture, shift, selected, reset;
    wire inner_tck, inner_tms, inner_tdi, inner_trst_n, inner_tdo;
    wire dtm_trst_n;
    wire frame_trst_n;
    BSCANE2 #(.JTAG_CHAIN(4)) bscan (
        .TCK(raw_tck), .TDI(tdi), .TDO(tdo), .CAPTURE(capture), .SHIFT(shift),
        .SEL(selected), .RESET(reset), .DRCK(drck), .RUNTEST(), .TMS(), .UPDATE()
    );
    BUFG u_frame_clock (.I(raw_tck), .O(frame_tck));
    BUFG u_jtag_clock (.I(drck), .O(tck));
    karudbg_reset frame_reset_release (
        .clk(frame_tck), .reset_i(reset || rst), .reset_n_o(frame_trst_n)
    );
    karudbg_reset reset_release (
        .clk(tck), .reset_i(reset || rst), .reset_n_o(dtm_trst_n)
    );
    karudbg_bscan_tunnel tunnel (
        .tck(tck), .reset_i(!frame_trst_n), .select_i(selected),
        .capture_i(capture), .shift_i(shift), .tdi_i(tdi), .tdo_o(tdo),
        .inner_tck_o(inner_tck), .inner_tms_o(inner_tms),
        .inner_tdi_o(inner_tdi), .inner_trst_n_o(inner_trst_n),
        .inner_tdo_i(inner_tdo)
    );
    karudbg_jtag dtm (
        .clk(clk), .rst(rst), .tck(inner_tck), .tms(inner_tms),
        .tdi(inner_tdi), .trst_n(dtm_trst_n), .tdo(inner_tdo), .tdo_oe(),
        .dmi_reset_o(dmi_reset_o), .req_valid_o(req_valid_o),
        .req_ready_i(req_ready_i), .req_addr_o(req_addr_o), .req_op_o(req_op_o),
        .req_data_o(req_data_o), .resp_valid_i(resp_valid_i),
        .resp_ready_o(resp_ready_o), .resp_data_i(resp_data_i), .resp_op_i(resp_op_i)
    );
endmodule
