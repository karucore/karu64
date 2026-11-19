// tb_sysmon_xsim.v -- flow/fpga/karu_sysmon.v with Xilinx's own SYSMONE4
// simulation model (make sysmon-xsim-test; needs Vivado's simulator and its
// unisims library, so it is not in make dbg-test).
//
// The monitor model reads its analog inputs from test/sysmon_design.txt:
// 41.5 deg C, VCCINT 0.851 V and VCCAUX 1.805 V from time 0, then 55.0 deg C,
// 0.849 V and 1.799 V from 2 ms. The readout must decode to those values
// (within one LSB of the conversions), with an update counter that counts,
// after the monitor's own start-up, in which the codes read zero. The
// monitor averages its conversions and takes a few milliseconds to settle
// on the new values, so they are checked from 6 ms on; in between the
// readout must lie between the two.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_sysmon_xsim;
    reg clk = 0, rst = 1;
    always #6.667 clk = ~clk;                       // 75 MHz
    wire [63:0] v;
    karu_sysmon #(.SIM(0), .PERIOD_LOG2(12)) dut (.clk(clk), .rst(rst), .value_o(v));

    real t, vi, va;
    integer updates = 0, seen_first = 0, seen_second = 0, last_count = 0;
    task check(input ok, input [8*80:1] what);
        if (!ok) begin
            $display("FAIL sysmon xsim: %0s (raw %h at %0t)", what, v, $time);
            $finish;
        end
    endtask
    function close(input real a, input real b, input real tol);
        close = (a > b - tol) && (a < b + tol);
    endfunction

    initial begin
        repeat (20) @(posedge clk);
        rst = 0;
        while ($time < 7_000_000) begin
            @(v[63:48]);
            #1;
            updates = updates + 1;
            check(v[63:48] == last_count + 1, "the update counter counts by one");
            last_count = v[63:48];
            t  = v[15:0] * 509.3140064 / 65536.0 - 280.2308787;
            vi = v[31:16] * 3.0 / 65536.0;
            va = v[47:32] * 3.0 / 65536.0;
            if (v[47:0] != 48'b0) begin
                if ($time < 2_000_000) begin
                    check(close(t, 41.5, 0.6) && close(vi, 0.851, 0.003) && close(va, 1.805, 0.003),
                          "first stimulus: 41.5 C, 0.851 V, 1.805 V");
                    if (!seen_first) $display("sysmon: %f C, %f V, %f V at %0t", t, vi, va, $time);
                    seen_first = 1;
                end else if ($time < 6_000_000) begin
                    check(t > 41.0 && t < 55.6, "while settling, the temperature lies between the two values");
                end else begin
                    check(close(t, 55.0, 0.6) && close(vi, 0.849, 0.003) && close(va, 1.799, 0.003),
                          "second stimulus: 55.0 C, 0.849 V, 1.799 V");
                    if (!seen_second) $display("sysmon: %f C, %f V, %f V at %0t", t, vi, va, $time);
                    seen_second = 1;
                end
            end
        end
        check(seen_first && seen_second, "both stimulus values were read");
        $display("sysmon xsim test: PASS (%0d updates; temperature, VCCINT and VCCAUX follow the stimulus)", updates);
        $finish;
    end
    initial begin #8_000_000; $display("FAIL sysmon xsim: timeout"); $finish; end
endmodule
