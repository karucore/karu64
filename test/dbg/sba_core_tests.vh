// Architectural SBA coherence/restart tests, included inside tb_dbg_core.
// SPDX-License-Identifier: BSD-3-Clause
`ifdef TEST_SBA_PROBE
`ifdef TEST_SBA_CORE_LOCKED
    defparam dut.SBA_ENABLE=0;
`endif
    integer sba_ar_count=0,sba_aw_count=0;
    always @(posedge clk) if(!rst&&!hart_reset_i&&!ndmreset_o)begin
        if(dmem_arvalid&&dmem_arready)sba_ar_count++;
        if(dmem_awvalid&&dmem_awready)sba_aw_count++;
    end
    reg sba_live_watch=0,sba_live_flush_seen=0,sba_live_first_pending=0;
    reg [63:0] sba_live_expected_pc=0,sba_live_base=64'h80005000;
    integer sba_live_retired=0,sba_live_flushes=0;
    // Independent architectural trace: derive the next PC from the two known
    // loop instructions, never from the DUT maintenance restart register.
    always @(posedge clk) if(sba_live_watch&&!rst&&!hart_reset_i&&!ndmreset_o)begin
        if(dut.core.dbg_sba_flush)begin
            sba_live_flush_seen=1;sba_live_first_pending=1;sba_live_flushes++;
        end
        if(dut.core.perf_retire&&!debug_mode_o)begin
            check(dut.core.ex_pc==sba_live_expected_pc,
                  "SBA live maintenance resumes independently expected next PC");
            if(sba_live_first_pending)begin
                check(sba_live_flush_seen,"first post-maintenance retirement is tracked");
                sba_live_first_pending=0;
            end
            if(dut.core.ex_pc==sba_live_base)begin
                    check(dut.core.ex_ins==(sba_live_flush_seen?32'h00228293:32'h00128293),
                          "SBA live code patch discards every stale increment opcode");
                    sba_live_expected_pc=sba_live_base+4;
                end else if(dut.core.ex_pc==sba_live_base+4)begin
                    check(dut.core.ex_ins==32'hffdff06f,"SBA live loop jump remains intact");
                    sba_live_expected_pc=sba_live_base;
                end else $fatal(1,"SBA live loop retired an unexpected PC");
            sba_live_retired++;
        end
    end
    task sba_wait(input [2:0] expected_error);
        reg [31:0] status;
        integer polls;
        begin
            status=32'h00200000;polls=0;
            while(status[21]&&polls<1000)begin rd(7'h38,status);polls++;end
            if(status[21]||status[22]||status[14:12]!=expected_error)
                $fatal(1,"SBA status=%08x expected error=%0d pc=%x",status,expected_error,dut.core.ex_pc);
            checks++;
        end
    endtask
    task sba_write(input [31:0] address,input [2:0] size,input [63:0] data,input [2:0] error);
        begin
            wr(7'h38,32'(size)<<17);wr(7'h39,address);
            wr(7'h3d,data[63:32]);wr(7'h3c,data[31:0]);sba_wait(error);
            if(error)wr(7'h38,(32'(size)<<17)|32'h7000);
        end
    endtask
    task sba_read(input [31:0] address,input [2:0] size,input [2:0] error,output [63:0] data);
        reg [31:0] lo,hi;
        begin
            wr(7'h38,(32'(size)<<17)|32'h100000);wr(7'h39,address);sba_wait(error);
            // readondata remains clear: returning the value has no second bus access.
            if(error)begin wr(7'h38,(32'(size)<<17)|32'h7000);data=0;end
            else begin rd(7'h3d,hi);rd(7'h3c,lo);data={hi,lo};end
        end
    endtask
    task sba_core_tests;
        integer size,offset,n,reads_before,writes_before,retired_before;
        reg [63:0] expected,data,mask,dpc_before,csr_before;
        begin
            phase="SBA coherence";
`ifdef TEST_SBA_CORE_LOCKED
            reads_before=sba_ar_count;writes_before=sba_aw_count;
            for(n='h38;n<='h3f;n++)begin
                wr(7'(n),32'hffffffff);rd(7'(n),value);
                check(value==0,"locked SBA discovery/registers read zero");
            end
            repeat(30)@(negedge clk);
            check(sba_ar_count==reads_before&&sba_aw_count==writes_before&&
                  !dut.sba_req_valid&&!dut.sba_pause,"locked DM cannot launch SBA or maintenance");
            read_reg(16'h07b1,data);check(data==64'h80000000,"locked SBA preserves ordinary debug");
            $display("karudbg locked core SBA: PASS (%0d checks)",checks);
            $finish;
`endif
            rd(7'h38,value);
            check(value[31:29]==1&&value[11:5]==32&&value[4:0]==15,"SBA native discovery");
            write_reg(16'h1008,64'h1234567812345678);
            write_reg(16'h100a,64'habcdabcd11223344);
            write_reg(16'h0341,64'h80000200);write_reg(16'h0342,64'h1234);write_reg(16'h0343,64'h5678);
            read_reg(16'h07b1,dpc_before);read_reg(16'h07b0,csr_before);
            // A warmed core load must observe every native-width SBA lane write.
            for(size=0;size<4;size++)for(offset=0;offset<8;offset=offset+(1<<size))begin
                for(n=0;n<8;n++)memory.ram['h4000+size*64+n]=8'h55;
                write_reg(16'h100b,64'h80004000+64'(size*64));
                pb(0,32'h0005b603);pb(1,32'h00100073);execute_pb(0);
                expect_reg(16'h100c,64'h5555555555555555);
                sba_write(32'h80004000+32'(size*64+offset),3'(size),64'h0123456789abcdef,0);
                mask=size==3?64'hffffffffffffffff:((64'b1<<(8*(1<<size)))-1);
                expected=(64'h5555555555555555&~(mask<<(8*offset)))|
                         ((64'h0123456789abcdef&mask)<<(8*offset));
                execute_pb(0);expect_reg(16'h100c,expected);
                sba_read(32'h80004000+32'(size*64),3,0,data);
                check(data==expected,"SBA/core coherent native-width data");
                // Reinitialize through SBA so the next cached read is genuine.
                sba_write(32'h80004000+32'(size*64),3,64'h5555555555555555,0);
            end
            expect_reg(16'h1008,64'h1234567812345678);expect_reg(16'h100a,64'habcdabcd11223344);
            expect_reg(16'h0341,64'h80000200);expect_reg(16'h0342,64'h1234);expect_reg(16'h0343,64'h5678);
            expect_reg(16'h07b1,dpc_before);expect_reg(16'h07b0,csr_before);
            // Warm a decoded/fetched instruction, then replace it through SBA.
            put_insn('h5000,32'h00100293);put_insn('h5004,32'h00100073);
            step_at(64'h80005000,64'h80005004);expect_reg(16'h1005,1);
            sba_write(32'h80005000,2,64'h02a00293,0);
            step_at(64'h80005000,64'h80005004);expect_reg(16'h1005,42);
            // LR survives normal debug-ROM parking, but an SBA RAM maintenance
            // must kill it. A subsequent unbroken LR/SC pair must still work.
            write_reg(16'h100b,64'h80006000);write_reg(16'h100e,64'h9988776655443322);
            sba_write(32'h80006000,3,64'h1111222233334444,0);
            pb(0,32'h1005b62f);pb(1,32'h00100073);execute_pb(0);
            pb(0,32'h18e5b6af);pb(1,32'h00100073);execute_pb(0);expect_reg(16'h100d,0);
            pb(0,32'h1005b62f);pb(1,32'h00100073);execute_pb(0);
            sba_write(32'h80006000,3,64'h5566778899aabbcc,0);
            pb(0,32'h18e5b6af);pb(1,32'h00100073);execute_pb(0);expect_reg(16'h100d,1);
            check(memory.ram_word(32'h80006000)==64'h5566778899aabbcc,"failed SC preserves SBA data");
            pb(0,32'h1005b62f);pb(1,32'h18e5b6af);pb(2,32'h00100073);execute_pb(0);
            expect_reg(16'h100d,0);
            check(memory.ram_word(32'h80006000)==64'h9988776655443322,"fresh LR/SC succeeds after maintenance");
            // Exact MMIO read/write, error recovery and no route to the private page.
            reads_before=mmio_reads;writes_before=mmio_writes;
            sba_write(32'h10000000,2,64'h12345678,0);
            sba_read(32'h10000000,2,0,data);
            check(data[31:0]==32'h12345678&&mmio_reads==reads_before+1&&mmio_writes==writes_before+1,
                  "SBA MMIO has exactly requested side effects");
            sba_read(32'h10000080,2,2,data);
            reads_before=sba_ar_count;writes_before=sba_aw_count;
            sba_read(32'h00120380,2,2,data);sba_write(32'h00120380,2,0,2);
            check(sba_ar_count==reads_before&&sba_aw_count==writes_before,"SBA cannot route to private debug page");
            sba_read(32'h80006000,3,0,data);check(data==64'h9988776655443322,"SBA error recovery");
            // Running hart: maintenance is a transparent bounded pause, not a
            // debug entry or Program Buffer command. It resumes ordinary work.
            sba_write(32'h80005000,3,64'hffdff06f00128293,0);
            write_reg(16'h07b0,3);write_reg(16'h07b1,64'h80005000);
            sba_live_expected_pc=64'h80005000;sba_live_watch=1;
            resume_hart;retired_before=normal_retired;
            sba_write(32'h80005000,2,64'h00228293,0);
            sba_read(32'h80005000,2,0,data);
            check(data[31:0]==32'h00228293&&!debug_mode_o,"live SBA code write/read keeps hart running");
            repeat(100)@(negedge clk);
            check(normal_retired>retired_before,"running hart makes progress after maintenance");
            wr(7'h10,32'h80000001);wait_parked;
            check(sba_live_flushes==1&&!sba_live_first_pending&&sba_live_retired>0,
                  "live code maintenance flush and post-flush progress observed");
            sba_live_watch=0;
            read_reg(16'h07b1,data);
            check(data==64'h80005000||data==64'h80005004,"live maintenance resumes architectural instruction stream");
            expect_reg(16'h0341,64'h80000200);expect_reg(16'h0342,64'h1234);expect_reg(16'h0343,64'h5678);
            // Scratch SRAM is executable and the IFU can hold prefetched code
            // even though it is outside the cached DRAM aperture.
            sba_live_base=64'h00105000;
            sba_write(32'h00105000,3,64'hffdff06f00128293,0);
            write_reg(16'h07b0,3);write_reg(16'h07b1,sba_live_base);
            sba_live_flush_seen=0;sba_live_flushes=0;sba_live_first_pending=0;
            sba_live_expected_pc=sba_live_base;sba_live_retired=0;sba_live_watch=1;
            resume_hart;
            repeat(30)@(negedge clk);
            sba_write(32'h00105000,2,64'h00228293,0);
            repeat(100)@(negedge clk);
            wr(7'h10,32'h80000001);wait_parked;
            check(sba_live_flushes==1&&!sba_live_first_pending&&sba_live_retired>2,
                  "scratch code replacement flushes prefetch and resumes independent trace");
            sba_live_watch=0;sba_live_base=64'h80005000;
            sba_ifetch_tests;
            sba_pending_interrupt_test;
            $display("karudbg focused SBA probe: PASS (%0d checks)",checks);
        end
    endtask
    `include "test/dbg/sba_ifetch_tasks.vh"
    `include "test/dbg/sba_interrupt_tests.vh"
`endif
