//  karu_fregfile.v
//  32 x 64-bit floating-point register file. Three read ports (rs1, rs2,
//  rs3) so a single FMA uop can pull all three sources in one cycle,
//  plus one write port. f0 is NOT hard-wired to zero (unlike x0).
//
//  NaN-boxing of single-precision values is the writer's responsibility:
//  the LSU's FLW path and the FPU's single-precision result path both
//  put `32'hFFFFFFFF` in the upper half. Readers that consume a single
//  check the upper half == all-ones and substitute canonical NaN
//  otherwise (see karu_fpu).

module karu_fregfile (
    input  wire         clk,

    input  wire [4:0]   rs1,
    output wire [63:0]  rs1_v,
    input  wire [4:0]   rs2,
    output wire [63:0]  rs2_v,
    input  wire [4:0]   rs3,
    output wire [63:0]  rs3_v,

    input  wire         we,
    input  wire [4:0]   rd,
    input  wire [63:0]  rd_v
);
    reg [63:0] fx [0:31];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) fx[i] = 64'b0;
    end

    always @(posedge clk) begin
        if (we) fx[rd] <= rd_v;     //  f0 has no special semantics
    end

    assign rs1_v = fx[rs1];
    assign rs2_v = fx[rs2];
    assign rs3_v = fx[rs3];
endmodule
