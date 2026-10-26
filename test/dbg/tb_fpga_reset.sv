// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module tb_fpga_reset;
    reg cpu_clk=0, ui_clk=0;
    reg cpu_run=1, ui_run=1;
    reg board_reset_i=1, ui_arst_i=1, ndmreset_i=0;
    wire soc_reset_o, ui_reset_o;
    integer checks=0;
    karudbg_fpga_reset dut(.*);
    always #7 if(cpu_run)cpu_clk=~cpu_clk;
    always #2 if(ui_run)ui_clk=~ui_clk;
    always @(negedge soc_reset_o)begin
        if(ui_reset_o!==0)$fatal(1,"Hart resumed before UI responder reset release");
        checks=checks+1;
    end
    task check_both(input reg expected);
        begin
            #1;
            if(soc_reset_o!==expected || ui_reset_o!==expected)
                $fatal(1,"Expected both reset%b got CPU%b UI%b",expected,soc_reset_o,ui_reset_o);
            checks=checks+1;
        end
    endtask
    task wait_running;
        begin
            wait(!soc_reset_o);check_both(0);
        end
    endtask
    initial begin
        #25;check_both(1);
        board_reset_i=0;ui_arst_i=0;wait_running;
        ndmreset_i=1;check_both(1);#50;ndmreset_i=0;
        // UI release occurs first; CPU stays reset for two CPU edges.
        wait(!ui_reset_o);
        if(!soc_reset_o)$fatal(1,"CPU reset release not synchronized");
        checks=checks+1;wait_running;
        // An asserted and withdrawn reset must still cancel downstream work
        // when its clock restarts. Do not depend on a polling delay or ROM.
        @(negedge ui_clk);ui_run=0;
        #9;ndmreset_i=1;check_both(1);#5;ndmreset_i=0;
        #80;check_both(1);ui_run=1;wait_running;
        // CPU clock may stop independently while UI finishes its reset.
        @(negedge cpu_clk);cpu_run=0;
        #5;ndmreset_i=1;check_both(1);#13;ndmreset_i=0;
        wait(!ui_reset_o);#50;
        if(!soc_reset_o)$fatal(1,"Stopped CPU clock released hart reset");
        checks=checks+1;cpu_run=1;wait_running;
        // A calibration/UI reset also reaches CPU-side agents immediately.
        ui_arst_i=1;check_both(1);#11;ui_arst_i=0;wait_running;
        $display("PASS FPGA debug reset ordering checks=%0d",checks);
        $finish;
    end
    initial begin #5000;$fatal(1,"FPGA debug reset timeout");end
endmodule
