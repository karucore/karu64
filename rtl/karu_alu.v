//  karu_alu.v
//  Single-cycle combinational ALU. Inputs op1/op2/sub-op/is_w; output
//  is the 64-bit result. The caller decides what to put on op1/op2
//  (register / immediate / pc).
//
//  `is_w` selects the RV64 W-suffix variants: operate on low 32 bits,
//  sign-extend the 32-bit result to 64. SLL/SRL/SRA use the low 5 bits
//  of op2 for W variants, low 6 bits otherwise.

`include "karu_uop_defs.vh"

module karu_alu (
    input  wire [63:0]  op1,
    input  wire [63:0]  op2,
    input  wire [4:0]   sub,
    input  wire         is_w,
    output wire [63:0]  out
);
    //  64-bit results
    wire [63:0] add64 = op1 + op2;
    wire [63:0] sub64 = op1 - op2;
    wire [63:0] and64 = op1 & op2;
    wire [63:0] or64  = op1 | op2;
    wire [63:0] xor64 = op1 ^ op2;
    wire [63:0] sll64 = op1 << op2[5:0];
    wire [63:0] srl64 = op1 >> op2[5:0];
    wire [63:0] sra64 = $signed(op1) >>> op2[5:0];

    //  SLT/SLTU (signed/unsigned compare)
    wire [63:0] sltu64 = {63'b0, op1 < op2};
    wire [63:0] slt64  =
        {63'b0, (op1[63] == 1 && op2[63] == 0) ||
                ((op1[63] == op2[63]) && (op1 < op2))};

    //  32-bit (W) results
    wire [31:0] add32 = op1[31:0] + op2[31:0];
    wire [31:0] sub32 = op1[31:0] - op2[31:0];
    wire [31:0] sll32 = op1[31:0] << op2[4:0];
    wire [31:0] srl32 = op1[31:0] >> op2[4:0];
    wire [31:0] sra32 = $signed(op1[31:0]) >>> op2[4:0];
    wire [63:0] add32w = {{32{add32[31]}}, add32};
    wire [63:0] sub32w = {{32{sub32[31]}}, sub32};
    wire [63:0] sll32w = {{32{sll32[31]}}, sll32};
    wire [63:0] srl32w = {{32{srl32[31]}}, srl32};
    wire [63:0] sra32w = {{32{sra32[31]}}, sra32};

    assign out =
        sub == `ALU_ADD  ? (is_w ? add32w : add64) :
        sub == `ALU_SUB  ? (is_w ? sub32w : sub64) :
        sub == `ALU_AND  ? and64 :
        sub == `ALU_OR   ? or64  :
        sub == `ALU_XOR  ? xor64 :
        sub == `ALU_SLL  ? (is_w ? sll32w : sll64) :
        sub == `ALU_SRL  ? (is_w ? srl32w : srl64) :
        sub == `ALU_SRA  ? (is_w ? sra32w : sra64) :
        sub == `ALU_SLT  ? slt64 :
        sub == `ALU_SLTU ? sltu64 :
        sub == `ALU_PASS ? op2 :
        //  Zicond conditional-zero: condition on op2 (rs2), value from op1 (rs1).
        sub == `ALU_CZEQZ ? ((op2 == 64'b0) ? 64'b0 : op1) :
        sub == `ALU_CZNEZ ? ((op2 != 64'b0) ? 64'b0 : op1) :
                           64'b0;
endmodule
