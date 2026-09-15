// Exhaustive rd/rs1/rs2 mask checks for the seven translation-invalidation
// major encodings. Privilege and trap-state checks live in karu_tvm_test.S;
// PTE-store ordering and retranslation checks live in karu_mmu_test.S.
`timescale 1ns/1ps
`include "karu_uop_defs.vh"
module tb_svinval_decode;
    reg [31:0] ins;
    wire [3:0] unit;
    wire [4:0] sub, rd, rs1, rs2;
    reg [4:0] expected;
    integer family, fn7, d, a, b, checked;
    karu_dec dut(.ins(ins), .unit(unit), .sub(sub), .rd(rd), .rs1(rs1), .rs2(rs2));
    initial begin
        checked = 0;
        for (family = 0; family < 7; family = family + 1) begin
            case (family)
                0: fn7 = 7'h09;
                1: fn7 = 7'h0b;
                2: fn7 = 7'h0c;
                3: fn7 = 7'h13;
                4: fn7 = 7'h33;
                5: fn7 = 7'h11;
                6: fn7 = 7'h31;
            endcase
            for (d = 0; d < 32; d = d + 1)
                for (a = 0; a < 32; a = a + 1)
                    for (b = 0; b < 32; b = b + 1) begin
                        ins = (fn7 << 25) | (b << 20) | (a << 15) | (d << 7) | 32'h73;
                        expected = `SYS_TRAP;
                        if (d == 0 && (family == 0 || family == 1))
                            expected = `SYS_SFENCEVMA;
                        if (d == 0 && a == 0 && b < 2 && family == 2)
                            expected = `SYS_SFENCEINVAL;
`ifdef KARU_EN_H
                        if (d == 0 && (family == 3 || family == 5))
                            expected = `SYS_HFENCEVVMA;
                        if (d == 0 && (family == 4 || family == 6))
                            expected = `SYS_HFENCEGVMA;
`endif
                        #1;
                        if (unit !== `UNIT_SYS || sub !== expected || rd !== 0 || rs1 !== 0 || rs2 !== 0)
                            $fatal(1, "decode ins=%08x unit=%d sub=%d expected=%d", ins, unit, sub, expected);
                        checked = checked + 1;
                    end
        end
        $display("SVINVAL_DECODE_PASS cases=%0d", checked);
        $finish;
    end
endmodule
