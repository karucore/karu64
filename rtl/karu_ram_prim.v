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
`ifndef KARU_ASIC
    (* ram_style = "block" *)
`endif
    reg [DATA_W-1:0] mem [0:DEPTH-1];

`ifndef KARU_ASIC
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_W{1'b0}};
        a_rdata = {DATA_W{1'b0}};
        b_rdata = {DATA_W{1'b0}};
    end
`endif

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
// synthesis translate_off
    // A zero-enable write must preserve the addressed storage, even when a
    // fractional vector group's unused address wraps to register zero.
    reg az_q = 0, bz_q = 0;
    reg [ADDR_W-1:0] az_addr, bz_addr;
    reg [DATA_W-1:0] az_data, bz_data;
    always @(posedge clk) begin
        if (az_q && mem[az_addr] !== az_data) $fatal(1, "zero-BE port A changed storage");
        if (bz_q && mem[bz_addr] !== bz_data) $fatal(1, "zero-BE port B changed storage");
        az_q <= a_en && a_we && !(|a_be) &&
                !(b_en && b_we && (|b_be) && b_addr == a_addr);
        bz_q <= b_en && b_we && !(|b_be) &&
                !(a_en && a_we && (|a_be) && a_addr == b_addr);
        az_addr <= a_addr; az_data <= mem[a_addr];
        bz_addr <= b_addr; bz_data <= mem[b_addr];
    end
// synthesis translate_on
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

`ifndef KARU_ASIC
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_W{1'b0}};
    end
`endif

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

`ifndef KARU_ASIC
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_W{1'b0}};
    end
`endif

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    assign rdata0 = mem[raddr0];
    assign rdata1 = mem[raddr1];
endmodule
