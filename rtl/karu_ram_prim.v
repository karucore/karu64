//  karu_ram_prim.v
//  Memory leaf wrappers for ASIC/FPGA substitution.
//
//  Keep inferred arrays in small, named modules so an ASIC flow can replace
//  them with technology SRAM/register-file macros without matching arrays buried
//  inside control logic. These wrappers deliberately preserve the existing RTL
//  timing models.

`include "karu_ext.vh"      //  timescale + `default_nettype none (self-contained leaf)

module karu_tdp_be_ram #(
    parameter integer DATA_W = 128,
    parameter integer DEPTH  = 64,
    parameter integer ADDR_W = 6,
    parameter integer NBYTES = DATA_W / 8
) (
    input  wire                 clk,

    input  wire                 a_en,
    input  wire                 a_we,
    input  wire [ADDR_W-1:0]    a_addr,
    input  wire [NBYTES-1:0]    a_be,
    input  wire [DATA_W-1:0]    a_wdata,
    output reg  [DATA_W-1:0]    a_rdata,

    input  wire                 b_en,
    input  wire                 b_we,
    input  wire [ADDR_W-1:0]    b_addr,
    input  wire [NBYTES-1:0]    b_be,
    input  wire [DATA_W-1:0]    b_wdata,
    output reg  [DATA_W-1:0]    b_rdata
);
    (* ram_style = "block" *)
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_W{1'b0}};
        a_rdata = {DATA_W{1'b0}};
        b_rdata = {DATA_W{1'b0}};
    end

    integer ba;
    always @(posedge clk) begin
        if (a_en) begin
            if (a_we) begin
                for (ba = 0; ba < NBYTES; ba = ba + 1)
                    if (a_be[ba])
                        mem[a_addr][ba*8 +: 8] <= a_wdata[ba*8 +: 8];
            end else begin
                a_rdata <= mem[a_addr];
            end
        end
    end

    integer bb;
    always @(posedge clk) begin
        if (b_en) begin
            if (b_we) begin
                for (bb = 0; bb < NBYTES; bb = bb + 1)
                    if (b_be[bb])
                        mem[b_addr][bb*8 +: 8] <= b_wdata[bb*8 +: 8];
            end else begin
                b_rdata <= mem[b_addr];
            end
        end
    end
endmodule

module karu_1w1r_async_ram #(
    parameter integer DATA_W = 64,
    parameter integer DEPTH  = 64,
    parameter integer ADDR_W = 6
) (
    input  wire                 clk,
    input  wire                 we,
    input  wire [ADDR_W-1:0]    waddr,
    input  wire [DATA_W-1:0]    wdata,
    input  wire [ADDR_W-1:0]    raddr,
    output wire [DATA_W-1:0]    rdata
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_W{1'b0}};
    end

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    assign rdata = mem[raddr];
endmodule

module karu_1w2r_async_ram #(
    parameter integer DATA_W = 64,
    parameter integer DEPTH  = 64,
    parameter integer ADDR_W = 6
) (
    input  wire                 clk,
    input  wire                 we,
    input  wire [ADDR_W-1:0]    waddr,
    input  wire [DATA_W-1:0]    wdata,
    input  wire [ADDR_W-1:0]    raddr0,
    output wire [DATA_W-1:0]    rdata0,
    input  wire [ADDR_W-1:0]    raddr1,
    output wire [DATA_W-1:0]    rdata1
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_W{1'b0}};
    end

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    assign rdata0 = mem[raddr0];
    assign rdata1 = mem[raddr1];
endmodule
