// SPDX-License-Identifier: BSD-3-Clause
// Real DM+DTM behind a simulated Xilinx USER4 outer TAP.
module tb_bscan_remote (
    input wire clk, input wire rst,
    input wire tck, input wire tms, input wire tdi, input wire trst_n,
    output wire tdo, output wire [31:0] request_count
`ifdef KARUDBG_BSCAN_CORE
    ,input wire hart_reset,
    output wire [63:0] debug_pc,
    output wire debug_parked
`endif
);
    wire capture,shift,selected,reset,user_tdo,drck;
    wire itck,itms,itdi,itrst_n,itdo;
    wire dtm_trst_n;
    wire frame_trst_n;
    xilinx_tap_model outer_tap (
        .tck(tck),.tms(tms),.tdi(tdi),.trst_n(trst_n),.tdo(tdo),
        .capture_o(capture),.shift_o(shift),.select_o(selected),
        .reset_o(reset),.drck_o(drck),.user_tdo_i(user_tdo)
    );
    karudbg_bscan_tunnel tunnel (
        .tck(drck),.reset_i(!frame_trst_n),.select_i(selected),
        .capture_i(capture),.shift_i(shift),.tdi_i(tdi),.tdo_o(user_tdo),
        .inner_tck_o(itck),.inner_tms_o(itms),.inner_tdi_o(itdi),
        .inner_trst_n_o(itrst_n),.inner_tdo_i(itdo)
    );
    karudbg_reset frame_reset_release (
        .clk(tck), .reset_i(reset||rst), .reset_n_o(frame_trst_n)
    );
    karudbg_reset reset_release (
        .clk(itck), .reset_i(reset||rst), .reset_n_o(dtm_trst_n)
    );
`ifdef KARUDBG_BSCAN_CORE
    tb_jtag_core target_fixture (
        .hart_reset(hart_reset),.debug_pc(debug_pc),.debug_parked(debug_parked),
`else
    tb_jtag_remote target_fixture (
`endif
        .clk(clk),.rst(rst),.tck(itck),.tms(itms),.tdi(itdi),
        .trst_n(dtm_trst_n),.tdo(itdo),.request_count(request_count)
    );
endmodule
