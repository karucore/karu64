// SPDX-License-Identifier: BSD-3-Clause
// Keep the DM alive while ndmreset cancels both sides of the DDR AXI path.
// CPU-side agents may resume only after UI-side responders leave reset.
module karudbg_fpga_reset (
    input wire cpu_clk,
    input wire ui_clk,
    input wire board_reset_i,
    input wire ui_arst_i,
    input wire ndmreset_i,
    output wire soc_reset_o,
    output wire ui_reset_o
);
    wire ui_startup_reset;
    wire ui_reset_n, cpu_reset_n;
    reset_ctrl #(.POR_CYCLES(64)) ui_startup (
        .clk(ui_clk), .arst_in(ui_arst_i), .rst_out(ui_startup_reset)
    );
    karudbg_reset ui_cancel (
        .clk(ui_clk),
        .reset_i(ui_startup_reset || board_reset_i || ndmreset_i || ui_arst_i),
        .reset_n_o(ui_reset_n)
    );
    karudbg_reset cpu_cancel (
        .clk(cpu_clk), .reset_i(board_reset_i || ndmreset_i || !ui_reset_n),
        .reset_n_o(cpu_reset_n)
    );
    assign ui_reset_o = !ui_reset_n;
    assign soc_reset_o = !cpu_reset_n;
endmodule
