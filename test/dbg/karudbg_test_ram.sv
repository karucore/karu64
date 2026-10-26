// Shared bounded AXI RAM/device fixture for direct-DMI and JTAG core tests.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module karudbg_test_ram #(
    parameter [63:0] INITIAL_MMIO=64'h0000000087654321,
    parameter ENABLE_FIFO=0,
    parameter BOOT_LOOP=0,
    parameter AW_WAIT_WVALID=0
) (
    input wire clk,
    input wire rst,
    input wire hart_reset_i,
    input wire ndmreset_o,
    input wire [3:0] imem_arid,
    input wire [31:0] imem_araddr,
    input wire [7:0] imem_arlen,
    input wire [2:0] imem_arsize,
    input wire [1:0] imem_arburst,
    input wire [2:0] imem_arprot,
    input wire  imem_arvalid,
    output wire imem_arready,
    output reg [3:0] imem_rid,
    output reg [63:0] imem_rdata,
    output reg [1:0] imem_rresp,
    output reg  imem_rlast,
    output reg  imem_rvalid,
    input wire imem_rready,
    input wire [3:0] dmem_arid,
    input wire [31:0] dmem_araddr,
    input wire [7:0] dmem_arlen,
    input wire [2:0] dmem_arsize,
    input wire [1:0] dmem_arburst,
    input wire [2:0] dmem_arprot,
    input wire  dmem_arvalid,
    output wire dmem_arready,
    output reg [3:0] dmem_rid,
    output reg [63:0] dmem_rdata,
    output reg [1:0] dmem_rresp,
    output reg  dmem_rlast,
    output reg  dmem_rvalid,
    input wire dmem_rready,
    input wire [3:0] dmem_awid,
    input wire [31:0] dmem_awaddr,
    input wire [7:0] dmem_awlen,
    input wire [2:0] dmem_awsize,
    input wire [1:0] dmem_awburst,
    input wire [2:0] dmem_awprot,
    input wire  dmem_awvalid,
    input wire [63:0] dmem_wdata,
    input wire [7:0] dmem_wstrb,
    input wire  dmem_wlast,
    input wire  dmem_wvalid,
    input wire  dmem_bready,
    output wire dmem_awready,
    output wire dmem_wready,
    output reg [3:0] dmem_bid,
    output reg [1:0] dmem_bresp,
    output reg dmem_bvalid,
    output integer mmio_reads,
    output integer mmio_writes,
    output reg [63:0] mmio_value,
    output reg [31:0] fifo_count
);
    reg [7:0] ram [0:65535];
    integer cycle = 0;
    reg i_active = 0, d_active = 0, w_active = 0;
    reg [31:0] i_addr, d_addr, w_addr;
    reg [7:0] i_left, d_left, w_left;
    reg [2:0] i_size, d_size, w_size;
    reg [3:0] i_id, d_id, w_id;
    reg w_error;
    integer b, init_index;
    initial begin
        mmio_reads=0; mmio_writes=0; mmio_value=INITIAL_MMIO; fifo_count=0;
        imem_rid=0; imem_rdata=0; imem_rresp=0; imem_rlast=0; imem_rvalid=0;
        dmem_rid=0; dmem_rdata=0; dmem_rresp=0; dmem_rlast=0; dmem_rvalid=0;
        dmem_bid=0; dmem_bresp=0; dmem_bvalid=0;
        for(init_index=0;init_index<65536;init_index=init_index+1) ram[init_index]=0;
        if(BOOT_LOOP) begin
            put_insn(0,32'h00128293); // addi t0,t0,1
            put_insn(4,32'hffdff06f); // jal x0,-4
        end
    end
    task clear_ram;
        integer j;
        begin for(j=0;j<65536;j=j+1) ram[j]=0; end
    endtask
    assign imem_arready = !i_active && !imem_rvalid && cycle[1:0] != 0;
    assign dmem_arready = !d_active && !dmem_rvalid && cycle[1:0] != 1;
    assign dmem_awready = !w_active && !dmem_bvalid && cycle[2:0] != 2 &&
        (!AW_WAIT_WVALID || dmem_wvalid);
    assign dmem_wready = w_active && cycle[1:0] != 1;

    function [63:0] ram_word(input [31:0] address);
        integer offset, n;
        begin
            ram_word = 0;
            offset = int'({address[15:3],3'b0});
            for (n = 0; n < 8; n = n + 1)
                ram_word[n*8 +: 8] = ram[offset+n];
        end
    endfunction
    task put_insn(input integer offset, input [31:0] insn);
        integer n;
        begin for (n = 0; n < 4; n = n + 1) ram[offset+n] = insn[n*8 +: 8]; end
    endtask
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (rst || hart_reset_i || ndmreset_o) begin
            i_active <= 0; d_active <= 0; w_active <= 0;
            imem_rvalid <= 0; dmem_rvalid <= 0; dmem_bvalid <= 0;
        end else begin
            if (imem_arvalid && imem_arready) begin
                i_active <= 1; i_addr <= imem_araddr; i_left <= imem_arlen;
                i_size <= imem_arsize; i_id <= imem_arid;
            end
            if (imem_rvalid && imem_rready) begin
                imem_rvalid <= 0;
                if (imem_rlast) i_active <= 0;
                else begin i_addr <= i_addr + (32'd1 << i_size); i_left <= i_left - 1; end
            end else if (i_active && !imem_rvalid && cycle[2:0] != 3) begin
                imem_rid <= i_id; imem_rdata <= ram_word(i_addr);
                imem_rresp <= i_addr[31:16] == 16'h8000 ? 0 : 3;
                imem_rlast <= i_left == 0; imem_rvalid <= 1;
            end
            if (dmem_arvalid && dmem_arready) begin
                d_active <= 1; d_addr <= dmem_araddr; d_left <= dmem_arlen;
                d_size <= dmem_arsize; d_id <= dmem_arid;
            end
            if (dmem_rvalid && dmem_rready) begin
                dmem_rvalid <= 0;
                if (dmem_rlast) d_active <= 0;
                else begin d_addr <= d_addr + (32'd1 << d_size); d_left <= d_left - 1; end
            end else if (d_active && !dmem_rvalid && cycle[2:0] != 4) begin
                dmem_rid <= d_id;
                dmem_rdata <= ram_word(d_addr);
                dmem_rresp <= d_addr[31:16] == 16'h8000 ? 0 : 3;
                if (d_addr[31:12] == 20'h10000) begin
                    dmem_rdata <= mmio_value;
                    dmem_rresp <= d_addr[11:0] == 0 ? 0 : 2;
                    if(ENABLE_FIFO && d_addr[11:0] >= 8 && d_addr[11:0] <= 24) begin
                        if(d_size != 2) $fatal(1, "FIFO requires native 32-bit access");
                        dmem_rdata <= {32'b0, (32'ha5a50000+fifo_count)} << (d_addr[2] ? 32:0);
                        dmem_rresp <= 0; fifo_count <= fifo_count+1;
                    end
                    if(ENABLE_FIFO && d_addr[11:0] == 32) begin
                        dmem_rdata <= {32'b0, fifo_count}; dmem_rresp <= 0;
                    end
                    if(ENABLE_FIFO && d_addr[11:0] == 40) begin
                        dmem_rdata <= 64'(mmio_reads); dmem_rresp <= 0;
                    end
                    if (d_addr[11:0] == 0) begin
                        mmio_reads <= mmio_reads + 1;
                        mmio_value <= 0; // read-to-clear; every extra read is visible
                    end
                end
                dmem_rlast <= d_left == 0; dmem_rvalid <= 1;
            end
            if (dmem_awvalid && dmem_awready) begin
                w_active <= 1; w_addr <= dmem_awaddr; w_left <= dmem_awlen;
                w_size <= dmem_awsize; w_id <= dmem_awid; w_error <= 0;
            end
            if (dmem_wvalid && dmem_wready) begin
                if (w_addr[31:16] == 16'h8000) begin
                    for (b = 0; b < 8; b = b + 1)
                        if (dmem_wstrb[b]) ram[{w_addr[15:3],3'b0}+b] <= dmem_wdata[8*b +: 8];
                end else if (w_addr[31:12] == 20'h10000 && w_addr[11:0] == 0) begin
                    for (b = 0; b < 8; b = b + 1)
                        if (dmem_wstrb[b]) mmio_value[8*b +: 8] <= dmem_wdata[8*b +: 8];
                    mmio_writes <= mmio_writes + 1;
                end else w_error <= 1;
                if (dmem_wlast !== (w_left == 0)) $fatal(1,"memory responder: WLAST/len mismatch");
                if (w_left == 0) begin
                    w_active <= 0; dmem_bid <= w_id; dmem_bvalid <= 1;
                    dmem_bresp <= w_error || !(w_addr[31:16] == 16'h8000 ||
                        (w_addr[31:12] == 20'h10000 && w_addr[11:0] == 0)) ? 2 : 0;
                end else begin w_addr <= w_addr + (32'd1 << w_size); w_left <= w_left - 1; end
            end
            if (dmem_bvalid && dmem_bready) dmem_bvalid <= 0;
        end
    end

endmodule
