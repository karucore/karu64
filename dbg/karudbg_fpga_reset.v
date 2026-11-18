// SPDX-License-Identifier: BSD-3-Clause
// Keep the DM alive while ndmreset cancels both sides of the DDR AXI path.
// CPU-side agents may resume only after UI-side responders leave reset.
//
// A software reset request (system-control register, karu_ddr_xbar.v) takes
// the same path as ndmreset: it resets the hart, the SoC peripherals and both
// sides of the DDR AXI path, and leaves the DM, the DTM and DDR calibration
// alone. The request is a one-cycle pulse from logic that the reset clears,
// so karu_soft_reset, which only the board reset clears, holds it.
module karudbg_fpga_reset #(
    // Software reset pulse length in CPU clock cycles. The AXI converters on
    // the DDR path need their reset held for at least 16 cycles of their
    // slower clock.
    parameter integer SOFT_RESET_CYCLES = 256
) (
    input wire cpu_clk,
    input wire ui_clk,
    input wire board_reset_i,
    input wire ui_arst_i,
    input wire ndmreset_i,
    input wire soft_reset_req_i,
    output wire soc_reset_o,
    output wire ui_reset_o
);
    wire ui_startup_reset;
    wire ui_reset_n, cpu_reset_n;
    wire soft_reset;
    karu_soft_reset #(.HOLD_CYCLES(SOFT_RESET_CYCLES)) soft_hold (
        .clk(cpu_clk), .por_i(board_reset_i), .req_i(soft_reset_req_i), .reset_o(soft_reset)
    );
    reset_ctrl #(.POR_CYCLES(64)) ui_startup (
        .clk(ui_clk), .arst_in(ui_arst_i), .rst_out(ui_startup_reset)
    );
    karudbg_reset ui_cancel (
        .clk(ui_clk),
        .reset_i(ui_startup_reset || board_reset_i || ndmreset_i || soft_reset || ui_arst_i),
        .reset_n_o(ui_reset_n)
    );
    karudbg_reset cpu_cancel (
        .clk(cpu_clk), .reset_i(board_reset_i || ndmreset_i || soft_reset || !ui_reset_n),
        .reset_n_o(cpu_reset_n)
    );
    assign ui_reset_o = !ui_reset_n;
    assign soc_reset_o = !cpu_reset_n;
endmodule
