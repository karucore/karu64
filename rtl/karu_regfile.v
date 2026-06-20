//  karu_regfile.v
//  32x64-bit integer register file. x0 hard-wired to zero.
//  2 read ports (rs1, rs2), 1 write port (rd) for Phase 2; Phase 3 will
//  add more write ports for multi-FU completion.

module karu_regfile (
    input  wire         clk,

    input  wire [4:0]   rs1,
    output wire [63:0]  rs1_v,
    input  wire [4:0]   rs2,
    output wire [63:0]  rs2_v,

    input  wire         we,
    input  wire [4:0]   rd,
    input  wire [63:0]  rd_v
);
    reg [63:0] rx [0:31];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) rx[i] = 64'b0;
    end

    always @(posedge clk) begin
        if (we && rd != 5'd0)
            rx[rd] <= rd_v;
    end

    //  No write-through forwarding: the top issues one instruction per
    //  cycle, NB-updates rx[rd] at the end, and the next cycle's read
    //  naturally sees the new value. Adding combinational forwarding
    //  here creates a loop because wb_we/wb_v depend on the ALU output
    //  which itself depends on rs1_v/rs2_v.
    assign rs1_v = (rs1 == 5'd0) ? 64'b0 : rx[rs1];
    assign rs2_v = (rs2 == 5'd0) ? 64'b0 : rx[rs2];
endmodule
