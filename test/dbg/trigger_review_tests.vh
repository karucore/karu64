`ifdef TEST_TRIGGER_REVIEW
// SPDX-License-Identifier: BSD-2-Clause
// Directed review regressions through architectural DMI/core interfaces.
`ifdef KARU_DBG_TRIGGERS
`ifdef KARU_EN_V
    task trigger_direction_run(input[31:0] instruction,output integer latency);
        integer start_cycle,timeout;
        begin
            put_insn('h400,instruction);put_insn('h404,32'h00100073);
            pb(0,32'h0000100f);pb(1,32'h00100073);execute_pb(0);
            write_reg(16'h07b1,64'h80000400);write_reg(16'h07b0,64'h8003);
            // Align the responder's periodic stall phase when comparing hot
            // store timings; control-program length is otherwise unrelated.
            while((cycle&7)!=0)@(negedge clk);
            resume_hart;
            timeout=0;
            while(!dut.core.vlsu_active&&timeout<2000)begin @(negedge clk);timeout++;end
            check(timeout<2000,"direction probe started vector instruction");
            check(!dut.core.vlsu.pelem_q,"opposite-direction watchpoint preserves normal vector walk");
            start_cycle=cycle;
            while(!dut.core.vlsu_done&&timeout<4000)begin @(negedge clk);timeout++;end
            check(timeout<4000,"direction probe completed vector instruction");
            latency=cycle-start_cycle;
            wait_parked;expect_reg(16'h07b1,64'h80000404);
            read_reg(16'h07b0,got);check(got[8:6]==1,"opposite-direction watchpoint does not fire");
        end
    endtask
    task trigger_direction_tests;
        integer kind,n,latency_warm,latency_base,latency_opposite;
        reg[31:0] instruction;
        begin
            phase="direction-filtered vector watchpoint arming";
            write_reg(16'h0300,64'h6600);write_reg(16'h100b,64'h80006000);write_reg(16'h100c,8);
            pb(0,32'h00067057);pb(1,32'h5e03b0d7);pb(2,32'h00100073);execute_pb(0);
            for(n=0;n<32;n++)memory.ram['h6000+n]=8'(n+1);
            for(kind=0;kind<2;kind++)begin
                instruction=kind==0?32'h02058087:32'h020580a7;
                trigger_config(0,64'h80006000,0);
                trigger_direction_run(instruction,latency_warm);
                trigger_direction_run(instruction,latency_base);
                trigger_config(0,64'h80006000,kind==0?64'h6800000000001042:64'h6800000000001041);
                trigger_direction_run(instruction,latency_opposite);
                check(latency_opposite==latency_base,"opposite-direction trigger preserves hot vector cycle count");
                trigger_config(0,0,0);
            end
            for(n=0;n<8;n++)check(memory.ram['h6000+n]==8'(n+1),"direction probe preserves loaded/stored bytes");
            $display("karudbg trigger direction filtering: PASS");
        end
    endtask
`endif
`ifdef KARU_DBG_SBA
    task trigger_pause_fetch_fault_test;
        integer timeout;
        reg seen_pending;
        reg[31:0] status;
        begin
            phase="SBA pause holds a fetch-fault execute watchpoint";
            write_reg(16'h0341,64'h12345678);write_reg(16'h0342,64'h45);write_reg(16'h0343,64'h6789);
            trigger_config(0,64'h80010000,64'h6800000000001044);
            memory.hold_i_r=1;
            write_reg(16'h07b1,64'h80010000);write_reg(16'h07b0,64'h8003);
            resume_hart;
            timeout=0;
            while(!memory.i_active&&timeout<2000)begin @(negedge clk);timeout++;end
            check(timeout<2000,"faulting fetch is outstanding before SBA pause");
            wr(7'h38,32'h00040000);wr(7'h39,32'h80006400);wr(7'h3c,32'h12345678);
            check(dut.core.debug_sba_pause_i,"SBA waits for outstanding fetch while holding issue");
            @(negedge clk);memory.hold_i_r=0;seen_pending=0;timeout=0;
            while(!debug_mode_o&&timeout<4000)begin
                if(dut.core.debug_sba_pause_i&&dut.core.ifu_fault_valid)begin
                    seen_pending=1;
                    check(!dut.core.trigger_exec_valid&&!dut.core.dbg_trigger_entry,
                          "SBA pause blocks pending fetch-fault trigger");
                end
                @(negedge clk);timeout++;
            end
            check(seen_pending,"fetch fault was observed during the SBA pause");
            check(timeout<4000,"fetch trigger enters Debug Mode after maintenance release");
            wait_parked;expect_reg(16'h07b1,64'h80010000);
            read_reg(16'h07b0,got);check(got[8:6]==2,"released fetch-fault watchpoint reports trigger cause");
            rd(7'h38,status);check(!status[21]&&!status[22]&&!status[14:12],"SBA completed before fetch trigger entry");
            check(memory.ram['h6400]==8'h78&&memory.ram['h6403]==8'h12,"SBA write survived deferred fetch trigger");
            expect_reg(16'h0341,64'h12345678);expect_reg(16'h0342,64'h45);expect_reg(16'h0343,64'h6789);
            trigger_config(0,0,0);
            $display("karudbg SBA fetch-fault trigger pause: PASS");
        end
    endtask
`endif
    task trigger_review_tests;
        begin
`ifdef KARU_EN_V
            trigger_direction_tests;
`endif
`ifdef KARU_DBG_SBA
            trigger_pause_fetch_fault_test;
`endif
            $display("karudbg trigger review regressions: PASS");
        end
    endtask
`endif

`endif
