// Already-issued instruction reads must drain before a coherent SBA write.
// Included inside tb_dbg_core under TEST_SBA_PROBE.
// SPDX-License-Identifier: BSD-2-Clause
    task sba_start_held_fetch(input integer offset, input bit hold_address);
        integer timeout_cycles;
        begin
            put_insn(offset,32'h00128293);put_insn(offset+4,32'hffdff06f);
            memory.hold_i_ar=hold_address;memory.hold_i_r=!hold_address;
            write_reg(16'h07b0,3);write_reg(16'h07b1,64'h80000000+64'(offset));
            resume_hart;
            timeout_cycles=0;
            while((hold_address ? !imem_arvalid : !memory.i_active) && timeout_cycles<5000)begin
                @(negedge clk);timeout_cycles++;
            end
            check(timeout_cycles<5000,"instruction transaction reaches selected stall phase");
            check(hold_address ? !imem_arready : !imem_rvalid,
                  "instruction transaction actually held before SBA");
        end
    endtask
    task sba_launch_drain_probe(input [63:0] data);
        begin
            wr(7'h38,32'h60000);wr(7'h39,32'h80006000);
            wr(7'h3d,data[63:32]);wr(7'h3c,data[31:0]);
        end
    endtask
    task sba_check_held_drain(input integer count);
        integer n;
        begin
            for(n=0;n<count;n++)begin
                @(negedge clk);
                check(!dmem_awvalid&&!dmem_wvalid,
                      "SBA AW and W both wait for older instruction read");
                check(dut.sba_pause&&!dut.sba_quiet,
                      "stalled instruction read retains maintenance hold");
            end
            rd(7'h38,value);check(value[21]&&!value[22],"stalled fetch keeps sbbusy without busyerror");
        end
    endtask
    task sba_ifetch_tests;
        integer previous_aw,previous_retire;
        reg [63:0] before_data;
        begin
            phase="SBA instruction read drain";
            before_data=memory.ram_word(32'h80006000);previous_aw=sba_aw_count;
            sba_start_held_fetch('h7000,1);
            sba_launch_drain_probe(64'hdead001122334455);
            sba_check_held_drain(24);
            // A transport reset cannot release the issue hold or cancel an
            // accepted DMI request waiting for pre-write maintenance.
            @(negedge clk);dmi_reset_i=1;
            repeat(4)@(negedge clk);
            dmi_reset_i=0;sba_check_held_drain(24);
            check(sba_aw_count==previous_aw&&memory.ram_word(32'h80006000)==before_data,
                  "held AR causes no early SBA write after DMI reset");
            memory.hold_i_ar=0;sba_wait(0);
            check(memory.ram_word(32'h80006000)==64'hdead001122334455,
                  "SBA follows completion of old held instruction AR");
            previous_retire=normal_retired;repeat(100)@(negedge clk);
            check(normal_retired>previous_retire,"instruction stream continues after held AR maintenance");
            wr(7'h10,32'h80000001);wait_parked;

            previous_aw=sba_aw_count;
            sba_start_held_fetch('h7400,0);
            sba_launch_drain_probe(64'hdead5566778899aa);sba_check_held_drain(32);
            check(sba_aw_count==previous_aw,"held instruction R prevents SBA AW");
            memory.hold_i_r=0;sba_wait(0);
            check(memory.ram_word(32'h80006000)==64'hdead5566778899aa,
                  "SBA follows completion of old held instruction R");
            wr(7'h10,32'h80000001);wait_parked;

            // Deactivation may cancel this unaccepted SBA request, but must
            // not fabricate a response to the still outstanding core fetch.
            before_data=memory.ram_word(32'h80006000);previous_aw=sba_aw_count;
            sba_start_held_fetch('h7800,1);
            sba_launch_drain_probe(64'hbadbadbadbadbad0);sba_check_held_drain(16);
            wr(7'h10,0);repeat(4)@(negedge clk);
            check(!dut.sba_pause&&imem_arvalid&&!imem_arready,
                  "deactivation releases own pause but preserves old core transaction");
            check(sba_aw_count==previous_aw&&memory.ram_word(32'h80006000)==before_data,
                  "canceled pre-write request never changes RAM");
            memory.hold_i_ar=0;repeat(150)@(negedge clk);
            wr(7'h10,1);wr(7'h10,32'h80000001);wait_parked;

            // A nonresponding core target intentionally blocks coherent SBA.
            // Shared hart/fabric reset is the recovery path; no timeout or
            // fake completion permits the write to overtake the old read.
            before_data=memory.ram_word(32'h80006000);previous_aw=sba_aw_count;
            sba_start_held_fetch('h7c00,0);
            sba_launch_drain_probe(64'hbadbadbadbadbad1);sba_check_held_drain(96);
            wr(7'h10,32'h80000003);
            repeat(5)@(negedge clk);
            check(!dut.sba_pause&&!memory.i_active,
                  "ndmreset cancels maintenance and reset responder together");
            memory.hold_i_r=0;
            wr(7'h10,32'h80000001);wait_parked;
            rd(7'h38,value);check(!value[21],"no stale maintenance ownership after reset");
            check(sba_aw_count==previous_aw&&memory.ram_word(32'h80006000)==before_data,
                  "reset recovery does not perform abandoned SBA write");
            wr(7'h38,32'h67000);
            sba_write(32'h80006000,3,64'h0123456789abcdef,0);
            check(memory.ram_word(32'h80006000)==64'h0123456789abcdef,
                  "fresh SBA works after stuck-fetch reset recovery");
            $display("karudbg SBA instruction drain: PASS");
        end
    endtask
