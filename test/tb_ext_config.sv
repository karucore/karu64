// Configuration-only probe; this is not an architectural conformance test.
`include "karu_ext.vh"
`include "karu_ext.vh" // Include guard must keep resolution idempotent.
module tb_ext_config;
    initial begin
`ifdef KARU_EN_C
        $display("EXT C");
`endif
`ifdef KARU_EN_A
        $display("EXT A");
`endif
`ifdef KARU_EN_M
        $display("EXT M");
`endif
`ifdef KARU_EN_B
        $display("EXT B");
`endif
`ifdef KARU_EN_F
        $display("EXT F");
`endif
`ifdef KARU_EN_D
        $display("EXT D");
`endif
`ifdef KARU_EN_V
        $display("EXT V");
`endif
`ifdef KARU_EN_S
        $display("EXT S");
`endif
`ifdef KARU_EN_H
        $display("EXT H");
`endif
`ifdef KARU_EN_HPM
        $display("EXT HPM");
`endif
`ifdef KARU_EN_MEM
        $display("EXT MEM");
`endif
`ifdef KARU_EN_ZVBB
        $display("EXT ZVBB");
`endif
`ifdef KARU_EN_ZVKB
        $display("EXT ZVKB");
`endif
`ifdef KARU_EN_KECCAK
        $display("EXT KECCAK");
`endif
`ifdef KARU_EN_ZVK
        $display("EXT ZVK");
`endif
`ifdef KARU_EN_ZVKNED
        $display("EXT ZVKNED");
`endif
`ifdef KARU_EN_ZVKNHA
        $display("EXT ZVKNHA");
`endif
`ifdef KARU_EN_ZVKNHB
        $display("EXT ZVKNHB");
`endif
`ifdef KARU_EN_ZVKSED
        $display("EXT ZVKSED");
`endif
`ifdef KARU_EN_ZVKSH
        $display("EXT ZVKSH");
`endif
`ifdef KARU_EN_ZVKG
        $display("EXT ZVKG");
`endif
`ifdef KARU_EN_SSTATEEN
        $display("EXT SSTATEEN");
`endif
`ifdef KARU_EN_SMCNTRPMF
        $display("EXT SMCNTRPMF");
`endif
`ifdef KARU_EN_SSCOFPMF
        $display("EXT SSCOFPMF");
`endif
        $display("EXT_CONFIG_PASS");
        $finish;
    end
endmodule
