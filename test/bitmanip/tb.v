`include "karu_uop_defs.vh"
module bm_tb (input wire [63:0] op1, input wire [63:0] op2, input wire [4:0] sub,
              input wire is_w, output wire [63:0] out);
    karu_bitmanip u (.op1(op1), .op2(op2), .sub(sub), .is_w(is_w), .out(out));
endmodule
