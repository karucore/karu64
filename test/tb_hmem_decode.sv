// SYSTEM funct3=100: exhaustive selectors and destination registers, with
// representative base registers. The explicit instruction-word oracle checks
// HLV/HLVX/HSV, reserved neighbours and preservation of the Zimop space.
`timescale 1ns/1ps
`include "karu_uop_defs.vh"
module tb_hmem_decode;
    reg [31:0] ins;
    wire [3:0] unit;
    wire [4:0] sub, rd, rs1, rs2;
    wire [63:0] imm;
    wire [1:0] size;
    wire sign_l, use_imm, rs1_is_f, rs2_is_f, rd_is_f;
    integer selector, d, a, base, checks;
    reg load_op, store_op, mop;
    reg [1:0] expected_size;
    reg expected_sign;
    karu_dec dut(.ins(ins), .unit(unit), .sub(sub), .rd(rd), .rs1(rs1), .rs2(rs2),
        .imm(imm), .size(size), .sign_l(sign_l), .use_imm(use_imm),
        .rs1_is_f(rs1_is_f), .rs2_is_f(rs2_is_f), .rd_is_f(rd_is_f));
    initial begin
        checks = 0;
        for (selector = 0; selector < 4096; selector = selector + 1)
            for (d = 0; d < 32; d = d + 1)
                for (a = 0; a < 4; a = a + 1) begin
                    case (a)
                        0: base = 0;
                        1: base = 1;
                        2: base = 10;
                        3: base = 31;
                    endcase
                    ins = (selector << 20) | (base << 15) | (d << 7) | 32'h4073;
                    load_op = 0; store_op = 0;
                    expected_size = 0; expected_sign = 0;
`ifdef KARU_EN_H
                    case (selector)
                        'h600: begin load_op=1; expected_size=0; expected_sign=1; end
                        'h601: begin load_op=1; expected_size=0; end
                        'h640: begin load_op=1; expected_size=1; expected_sign=1; end
                        'h641, 'h643: begin load_op=1; expected_size=1; end
                        'h680: begin load_op=1; expected_size=2; expected_sign=1; end
                        'h681, 'h683: begin load_op=1; expected_size=2; end
                        'h6c0: begin load_op=1; expected_size=3; expected_sign=1; end
                    endcase
                    if (d == 0) begin
                        if ((ins & 32'hfe007fff) == 32'h62004073) begin store_op=1; expected_size=0; end
                        if ((ins & 32'hfe007fff) == 32'h66004073) begin store_op=1; expected_size=1; end
                        if ((ins & 32'hfe007fff) == 32'h6a004073) begin store_op=1; expected_size=2; end
                        if ((ins & 32'hfe007fff) == 32'h6e004073) begin store_op=1; expected_size=3; end
                    end
`endif
                    mop = ((ins & 32'hb3c0707f) == 32'h81c04073) ||
                          ((ins & 32'hb200707f) == 32'h82004073);
                    #1;
                    if (load_op || store_op) begin
                        if (unit !== `UNIT_LSU || sub !== (store_op ? `LSU_STORE : `LSU_LOAD) ||
                            rd !== d[4:0] || rs1 !== base[4:0] ||
                            rs2 !== (store_op ? ins[24:20] : 5'b0) || imm !== 0 ||
                            size !== expected_size || sign_l !== expected_sign ||
                            use_imm !== 0 || rs1_is_f !== 0 || rs2_is_f !== 0 || rd_is_f !== 0)
                            $fatal(1,"H memory decode ins=%08x unit=%d sub=%d size=%d sign=%d",
                                ins,unit,sub,size,sign_l);
                    end else if (mop) begin
                        if (unit !== `UNIT_ALU || sub !== `ALU_ADD || rd !== d[4:0] ||
                            rs1 !== 0 || rs2 !== 0 || use_imm !== 0)
                            $fatal(1,"Zimop decode changed ins=%08x",ins);
                    end else if (unit !== `UNIT_SYS || sub !== `SYS_TRAP)
                        $fatal(1,"reserved H memory encoding accepted ins=%08x",ins);
                    checks = checks + 1;
                end
        $display("HMEM_DECODE_PASS checks=%0d", checks);
        $finish;
    end
endmodule
