// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module tb_reset_release;
    reg clk=0, reset_i=0;
    wire reset_n_o;
    integer phase, checks=0;
    karudbg_reset dut(.*);
    task check(input reg expected);
        begin
            #1;
            if(reset_n_o!==expected)$fatal(1,"Reset release phase%0d got%b expected%b",phase,reset_n_o,expected);
            checks=checks+1;
        end
    endtask
    initial begin
        for(phase=0;phase<8;phase=phase+1)begin
            clk=phase[0];#(phase+1);reset_i=1;check(0);
            // Assertion requires no destination clock, including when it
            // stopped high. Hold/deassert while the clock remains stopped.
            #20;check(0);reset_i=0;#20;check(0);
            clk=0;#5;clk=1;check(0);
            clk=0;#5;clk=1;check(1);
            clk=0;#5;check(1);
        end
        $display("PASS debug reset release checks=%0d",checks);
        $finish;
    end
endmodule
