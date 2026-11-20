// Idle stand-in for flow/fpga/eth/karu_eth.v, for four-state runs of the
// crossbar with Icarus (test/dbg/run_auth_revoke_ext.py, configuration
// iv4-xbar): the generated LiteEth core behind the real module does not get
// past time 0 there. Never busy, no interrupt. The bench that uses it makes
// no Ethernet access; one is an error here, so the stand-in cannot hide a
// test of the real device.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module karu_eth (
    input wire clk,
    input wire rst,
    input wire rd_req,
    input wire [31:0] rd_addr,
    input wire [2:0] rd_size,
    output reg rd_done,
    output reg [63:0] rd_data,
    input wire wr_req,
    input wire [31:0] wr_addr,
    input wire [7:0] wr_strb,
    input wire [63:0] wr_data,
    output reg wr_done,
    output wire busy,
    output wire eth_irq
);
    assign busy = 1'b0;
    assign eth_irq = 1'b0;
    initial begin rd_done = 1'b0; rd_data = 64'b0; wr_done = 1'b0; end
    always @(posedge clk) begin
        if (!rst && (rd_req === 1'b1 || wr_req === 1'b1))
            $fatal(1, "karu_eth_idle: Ethernet access at %08x (the stand-in has no device)",
                   rd_req === 1'b1 ? rd_addr : wr_addr);
    end
    wire unused = &{rd_size, wr_strb, wr_data, 1'b0};
endmodule
