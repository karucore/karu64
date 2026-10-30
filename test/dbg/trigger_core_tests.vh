// SPDX-License-Identifier: BSD-2-Clause
// Included in tb_dbg_core: architectural setup through DMI/Program Buffer only.
`ifdef KARU_DBG_TRIGGERS
    integer trigger_trap_reports=0;
    always @(posedge clk) if(!rst&&dut.core.trap_req&&trigger_trap_reports<4)begin
        trigger_trap_reports<=trigger_trap_reports+1;
        $display("trigger probe trap phase=%s cause=%h epc=%h tval=%h",phase,dut.core.trap_cause,dut.core.trap_epc,dut.core.trap_tval);
    end
    task trigger_config(input integer slot,input[63:0] addr,input[63:0] config_word);
        begin
            write_reg(16'h07a0,64'(slot));write_reg(16'h07a1,0);
            write_reg(16'h07a2,addr);write_reg(16'h07a1,config_word);
        end
    endtask
    task trigger_run(input[63:0] pc,input[63:0] stopped_pc,input integer cause);
        reg[63:0] csr_value;
        begin
            // put_insn changes the independent responder; execute the
            // architectural instruction-cache synchronization before reuse.
            pb(0,32'h0000100f);pb(1,32'h00100073);execute_pb(0);
            write_reg(16'h07b1,pc);
            write_reg(16'h07b0,64'h8003); // M, EBREAK to Debug Mode, no step
            resume_hart;wait_parked;
            expect_reg(16'h07b1,stopped_pc);read_reg(16'h07b0,csr_value);
            check(csr_value[8:6]==cause,"trigger debug-entry cause");
        end
    endtask
`ifdef KARU_EN_S
    task trigger_pte(input integer offset,input[63:0] pte);
        integer byte_index;
        begin for(byte_index=0;byte_index<8;byte_index=byte_index+1)
            memory.ram[offset+byte_index]=8'(pte>>(byte_index*8));
        end
    endtask
    task trigger_translated_tests;
        integer guest,pml,n;
        reg[63:0] host_env,guest_env,dcsr_word,tagged_addr,config_word,observed;
        begin
            phase="Sv39/guest translated and pointer-masked watchpoints";
            read_reg(16'h030a,host_env);
`ifdef KARU_EN_H
            read_reg(16'h060a,guest_env);
`endif
            for(n=0;n<4096;n=n+1)memory.ram['h8000+n]=0;
            // Root entries map both the instruction's identity VA and a data
            // VA below4GiB to the same physical1GiB DRAM superpage.
            trigger_pte('h8000,64'h200000cf);trigger_pte('h8010,64'h200000cf);
`ifdef KARU_EN_H
            for(n=0;n<4096;n=n+1)memory.ram['hc000+n]=0;
            trigger_pte('hc010,64'h200000df); // G stage requires U=1
`endif
            put_insn('h400,32'h0005a603);put_insn('h404,32'h00100073);
            for(guest=0;guest<2;guest=guest+1)begin
`ifdef KARU_EN_H
                if(1)begin
                    write_reg(16'h0280,guest?64'h8000000000080008:0);
                    write_reg(16'h0680,guest?64'h800000000008000c:0);
`else
                if(guest==0)begin
`endif
                    write_reg(16'h0180,guest?0:64'h8000000000080008);
                    pb(0,32'h12000073);
`ifdef KARU_EN_H
                    pb(1,32'h62000073);pb(2,32'h22000073);pb(3,32'h00100073);
`else
                    pb(1,32'h00100073);
`endif
                    execute_pb(0);
                    phase=$sformatf("translated guest%0d physical-alias probe",guest);
                    // Physical cache residency must not convert an address
                    // trigger into a physical-address comparator.
                    write_reg(16'h100b,64'h6000);
                    config_word=64'h6800000000001001|(guest?64'h1000000:64'h10);
                    trigger_config(0,64'h80006000,config_word);
                    pb(0,32'h0000100f);pb(1,32'h00100073);execute_pb(0);
                    dcsr_word=64'h3b001|(guest?32:0);
                    write_reg(16'h07b1,64'h80000400);write_reg(16'h07b0,dcsr_word);
                    resume_hart;wait_parked;expect_reg(16'h07b1,64'h80000404);
                    read_reg(16'h07b0,observed);check(observed[8:6]==1,"physical address is not virtual watch compare value");
                    for(pml=0;pml<3;pml=pml+1)begin
                        phase=$sformatf("translated guest%0d PMM%0d probe",guest,pml);
                        tagged_addr=pml==0?64'h6000:pml==1?64'hac00000000006000:64'habcd000000006000;
                        write_reg(16'h100b,tagged_addr);
                        if(guest==0)write_reg(16'h030a,(host_env&~64'h300000000)|(pml==0?0:pml==1?64'h200000000:64'h300000000));
`ifdef KARU_EN_H
                        else write_reg(16'h060a,(guest_env&~64'h300000000)|(pml==0?0:pml==1?64'h200000000:64'h300000000));
`endif
                        trigger_config(0,64'h6000,config_word);
                        write_reg(16'h07b1,64'h80000400);write_reg(16'h07b0,dcsr_word);
                        resume_hart;wait_parked;expect_reg(16'h07b1,64'h80000400);
                        read_reg(16'h07b0,observed);check(observed[8:6]==2,"Sv39/guest PM compare before translation");
                    end
                    write_reg(16'h07a1,0);
                end
            end
            write_reg(16'h0180,0);write_reg(16'h030a,host_env);
`ifdef KARU_EN_H
            write_reg(16'h0280,0);write_reg(16'h0680,0);write_reg(16'h060a,guest_env);
`endif
            pb(0,32'h12000073);pb(1,32'h00100073);execute_pb(0);
        end
    endtask
`endif
    task trigger_core_tests;
        integer n,op,reads_before,writes_before,mode,pml;
        reg[63:0] original_status,csr_value,mode_cfg,tagged_addr;
        reg[31:0] insn;
        begin
`ifdef TEST_TRIGGER_HACCESS
            trigger_haccess_tests;
`elsif TEST_WHOLE_PROBE
            trigger_vector_whole_tests;
`else
            phase="hardware trigger CSR and precise scalar probes";
            read_reg(16'h0300,original_status);
            write_reg(16'h0341,64'h12345678);write_reg(16'h0342,64'h45);write_reg(16'h0343,64'h89ab);
            expect_reg(16'h07a4,64'h01008040);
            expect_reg(16'h07a1,64'hf000000000000000);
            command(32'h003207a3,3); // no textra context support
            write_reg(16'h100c,100);
            put_insn('h400,32'h00160613);put_insn('h404,32'h00100073);
            trigger_config(0,64'h80000400,64'h6800000000001044);
            trigger_run(64'h80000400,64'h80000400,2);expect_reg(16'h100c,100);
            read_reg(16'h07a1,csr_value);check(csr_value[22],"execute hit0=before");
            write_reg(16'h07a1,0);
            trigger_run(64'h80000400,64'h80000404,1);expect_reg(16'h100c,101);
            // Every scalar integer access width; prime RAM in the core cache
            // through a real debug load before the normal watched load.
            for(n=0;n<64;n=n+1)memory.ram['h6000+n]=8'(n+1);
            write_reg(16'h100b,64'h80006000);
            for(op=0;op<4;op=op+1)begin
                insn=32'h00058603|(32'(op)<<12); // lb/lh/lw/ld a2,(a1)
                pb(0,insn);pb(1,32'h00100073);execute_pb(0);
                write_reg(16'h100c,64'hfeedface);
                put_insn('h400,insn);put_insn('h404,32'h00100073);
                trigger_config(0,64'h80006000,64'h6800000000001041);
                trigger_run(64'h80000400,64'h80000400,2);expect_reg(16'h100c,64'hfeedface);
                write_reg(16'h07a1,0);trigger_run(64'h80000400,64'h80000404,1);
                expect_reg(16'h100c,64'h0807060504030201&(~64'd0>>(64-(8<<op))));
            end
`ifdef KARU_EN_D
            // Scalar FP loads and stores use the same before-access probe.
            write_reg(16'h0300,original_status|64'h6000);
            write_reg(16'h100e,64'h1122334455667788);
            pb(0,32'hf2070153);pb(1,32'h00100073);execute_pb(0); // fmv.d.x f2,a4
            for(op=0;op<4;op=op+1)begin
                insn=op==0?32'h0005a107:op==1?32'h0005b107:op==2?32'h0025a027:32'h0025b027;
                put_insn('h400,insn);put_insn('h404,32'h00100073);
                trigger_config(0,64'h80006000,op<2?64'h6800000000001041:64'h6800000000001042);
                trigger_run(64'h80000400,64'h80000400,2);write_reg(16'h07a1,0);
            end
            write_reg(16'h0300,original_status);
`endif
            // LR is a load, SC is a store (including a failing SC), and an
            // AMO participates in both classes. Every hit is before side effects.
            for(op=0;op<4;op=op+1)begin
                insn=op==0?32'h1005b62f:op==1?32'h18e5b6af:32'h00e5b62f;
                put_insn('h400,insn);put_insn('h404,32'h00100073);
                trigger_config(0,64'h80006000,op==0||op==2?64'h6800000000001041:64'h6800000000001042);
                write_reg(16'h100c,64'hfeedface);write_reg(16'h100d,64'h1234);
                trigger_run(64'h80000400,64'h80000400,2);
                expect_reg(16'h100c,64'hfeedface);expect_reg(16'h100d,64'h1234);
                write_reg(16'h07a1,0);
            end
            // The implemented CBO policy compares its effective address,
            // rather than every byte in the block (Sdtrig section5.1.5.3 option3).
            put_insn('h400,32'h0045a00f);put_insn('h404,32'h00100073);
            trigger_config(0,64'h80006000,64'h6800000000001042);
            trigger_run(64'h80000400,64'h80000400,2);write_reg(16'h07a1,0);
            // Execute matching uses instruction-start PC even if the second
            // halfword faults. No instruction at the fault boundary is issued.
            memory.ram['hfffe]=8'h13;memory.ram['hffff]=8'h00;
            trigger_config(0,64'h8000fffe,64'h6800000000001044);
            trigger_run(64'h8000fffe,64'h8000fffe,2);write_reg(16'h07a1,0);
            trigger_config(0,64'h13000000,64'h6800000000001044);
            trigger_run(64'h13000000,64'h13000000,2);write_reg(16'h07a1,0);
`ifdef KARU_EN_S
            // Tagged MPRV-U accesses: pointer masking follows effective data
            // privilege, while trigger privilege remains the executing M mode.
            put_insn('h400,32'h300a1073);put_insn('h404,32'h0005a603);
            for(pml=0;pml<3;pml=pml+1)begin
                write_reg(16'h010a,pml==0?0:pml==1?64'h200000000:64'h300000000);
                tagged_addr=pml==2?64'habcd000080006000:64'hac00000080006000;
                write_reg(16'h100b,tagged_addr);write_reg(16'h1014,64'h20000);
                trigger_config(0,pml==0?tagged_addr:64'h80006000,64'h6800000000001041);
                trigger_run(64'h80000400,64'h80000404,2);
                expect_reg(16'h07a2,pml==0?tagged_addr:64'h80006000);write_reg(16'h07a1,0);
            end
            write_reg(16'h1014,64'ha0000); // MXR suppresses PM even under MPRV
            trigger_config(0,tagged_addr,64'h6800000000001041);
            trigger_run(64'h80000400,64'h80000404,2);write_reg(16'h07a1,0);
            write_reg(16'h010a,0);write_reg(16'h0300,original_status);
`endif
            // Actual instruction privilege/virtual-mode matching, not merely
            // programming CSR bits on an otherwise always-M-mode subject.
            put_insn('h400,32'h0005a603);put_insn('h404,32'h00100073);
            write_reg(16'h100b,64'h80006000);
            pb(0,32'h0000100f);pb(1,32'h00100073);execute_pb(0);
            for(mode=0;mode<5;mode=mode+1)begin
`ifdef KARU_EN_H
                if(1)begin
`else
                if(mode<3)begin
`endif
                mode_cfg=mode==0?64'h40:mode==1?64'h10:mode==2?64'h8:mode==3?64'h1000000:64'h800000;
                trigger_config(0,64'h80006000,64'h6800000000001001|mode_cfg);
                write_reg(16'h07b1,64'h80000400);
                write_reg(16'h07b0,64'hb000|(mode==0?3:(mode==1||mode==3)?1:0)|(mode>=3?32:0));
                resume_hart;wait_parked;expect_reg(16'h07b1,64'h80000400);
                read_reg(16'h07b0,csr_value);check(csr_value[8:6]==2,"actual privilege-mode watchpoint");
                write_reg(16'h07a1,0);
                end
            end
`ifdef KARU_EN_S
            trigger_translated_tests;
`endif
            // Exact MMIO store: no device side effect before the watchpoint;
            // disable/resume performs one, and only one, native-width write.
            write_reg(16'h100b,64'h10000000);write_reg(16'h100e,64'h12345678);
            put_insn('h400,32'h00e5a023);put_insn('h404,32'h00100073);
            trigger_config(0,64'h10000000,64'h6800000000001042);
            writes_before=mmio_writes;
            trigger_run(64'h80000400,64'h80000400,2);
            check(mmio_writes==writes_before,"watched store has no MMIO side effect");
            write_reg(16'h07a1,0);trigger_run(64'h80000400,64'h80000404,1);
            check(mmio_writes==writes_before+1&&mmio_value==64'h12345678,"resume issues exactly one MMIO store");
            // Protected tdata is not writable by ordinary M-mode software.
            put_insn('h400,32'h7a101073); // csrw tdata1,zero
            put_insn('h404,32'h0005a603);put_insn('h408,32'h00100073);
            trigger_config(0,64'h10000000,64'h6800000000001041);
            reads_before=mmio_reads;
            trigger_run(64'h80000400,64'h80000404,2);
            check(mmio_reads==reads_before,"M-mode cannot disarm protected data trigger");
            write_reg(16'h07a1,0);trigger_run(64'h80000404,64'h80000408,1);
            check(mmio_reads==reads_before+1,"protected-trigger continuation reads once");
            // Before-access address match outranks a load physical access fault.
            write_reg(16'h100b,64'h13000000);put_insn('h400,32'h0005a603);
            trigger_config(0,64'h13000000,64'h6800000000001041);
            trigger_run(64'h80000400,64'h80000400,2);
            write_reg(16'h07a1,0);
            expect_reg(16'h0341,64'h12345678);expect_reg(16'h0342,64'h45);expect_reg(16'h0343,64'h89ab);
`ifdef KARU_EN_V
            trigger_vector_tests;
`endif
            write_reg(16'h0300,original_status);write_reg(16'h07b0,3);write_reg(16'h07b1,64'h80000000);
            $display("karudbg trigger architectural probes: PASS");
`endif
        end
    endtask
`ifdef KARU_EN_V
    task trigger_vector_whole_tests;
        integer n,whole_size;
        reg[63:0] result;
        begin
            write_reg(16'h0300,64'h6600);
            // Whole-register addresses are probed at encoded element
            // starts. An interior-byte query must not stop after partial IO
            // effects and round vstart down to repeat those device bytes.
            phase="whole-register watchpoints and non-idempotent restart";
            for(whole_size=0;whole_size<4;whole_size=whole_size+1)begin
            write_reg(16'h100b,64'h10000100);
            put_insn('h400,32'h02858087|(32'(whole_size==0?0:whole_size+4)<<12));
            put_insn('h404,32'h00100073); // vl1re{8,16,32,64}.v v1,(a1)
            if(whole_size!=0)begin
            for(n=0;n<32;n=n+1)memory.debug_read_bytes[n]=0;
            write_reg(16'h0008,0);
            trigger_config(0,64'h10000101,64'h6800000000001041);
            // If a stop occurs here, dump the device trace before the generic
            // DPC assertion: old byte probes read indices0..2, then round the
            // restart index down to0 and would repeat them after resume.
            write_reg(16'h07b1,64'h80000400);write_reg(16'h07b0,64'h8003);
            pb(0,32'h0000100f);pb(1,32'h00100073);execute_pb(0);
            resume_hart;wait_parked;
            read_reg(16'h07b1,result);
            if(result!=64'h80000404)
                $display("whole-register interior stop pc=%h byte-read-counts0..3=%0d,%0d,%0d,%0d",result,memory.debug_read_bytes[0],memory.debug_read_bytes[1],memory.debug_read_bytes[2],memory.debug_read_bytes[3]);
            expect_reg(16'h07b1,64'h80000404);
            for(n=0;n<32;n=n+1)check(memory.debug_read_bytes[n]==1,"whole-register interior address does not duplicate device bytes");
            write_reg(16'h07a1,0);
            end
            for(n=0;n<32;n=n+1)memory.debug_read_bytes[n]=0;
            trigger_config(0,64'h10000110,64'h6800000000001041);
            trigger_run(64'h80000400,64'h80000400,2);expect_reg(16'h0008,64'(16>>whole_size));
            for(n=0;n<32;n=n+1)check(memory.debug_read_bytes[n]==(n<16?1:0),"whole-register watchpoint stops before complete encoded element");
            write_reg(16'h07a1,0);trigger_run(64'h80000400,64'h80000404,1);
            expect_reg(16'h0008,0);
            for(n=0;n<32;n=n+1)check(memory.debug_read_bytes[n]==1,"whole-register continuation reads every device byte once");
            end
        end
    endtask
    task trigger_vector_tests;
        integer sew,idx,n,maskcase;
        reg[63:0] result;
        reg[31:0] vload,vstore;
        begin
            phase="active-element vector watchpoints";
            write_reg(16'h0300,64'h6600);write_reg(16'h100b,64'h80006000);
            write_reg(16'h100d,64'h80006200);
            for(sew=0;sew<4;sew=sew+1)begin
                // e8/e16/e32/e64, m1, vl=4; v1 initialized independently.
                write_reg(16'h100c,4);
                pb(0,32'h00067057|(32'(sew)<<23));pb(1,32'h00100073);execute_pb(0);
                pb(0,32'h5e0030d7);pb(1,32'h00100073);execute_pb(0); // vmv.v.i v1,0
                vload=32'h02058087|(32'(sew==0?0:sew+4)<<12); // vle* v1,(a1)
                vstore=32'h020680a7|(32'(sew==0?0:sew+4)<<12); // vse* v1,(a3)
                put_insn('h400,vload);put_insn('h404,32'h00100073);
                trigger_config(0,64'h80006000+(64'd2<<sew),64'h6800000000001041);
                trigger_run(64'h80000400,64'h80000400,2);
                expect_reg(16'h0008,2);expect_reg(16'h0c20,4);
                // The stopped load has committed its prefix and kept its tail.
                write_reg(16'h0008,0);
                pb(0,vstore);pb(1,32'h00100073);execute_pb(0);
                write_reg(16'h0008,2);
                for(n=0;n<(4<<sew);n=n+1)
                    check(memory.ram['h6200+n]==(n<(2<<sew)?8'(n+1):8'd0),"vector prefix/tail at watchpoint");
                write_reg(16'h07a1,0);trigger_run(64'h80000400,64'h80000404,1);
                expect_reg(16'h0008,0);expect_reg(16'h0c20,4);
                pb(0,vstore);pb(1,32'h00100073);execute_pb(0);
                for(n=0;n<(4<<sew);n=n+1)check(memory.ram['h6200+n]==8'(n+1),"vector continuation fills remaining elements");
            end
            trigger_vector_whole_tests;
            // FF at i>0: watchpoint wins first, then after disabling it a real
            // access fault at that same element must trim rather than trap.
            write_reg(16'h100c,4);pb(0,32'h00067057);pb(1,32'h00100073);execute_pb(0);
            write_reg(16'h100b,64'h8000fffe);memory.ram['hfffe]=8'h12;memory.ram['hffff]=8'h34;
            put_insn('h400,32'h03058087);put_insn('h404,32'h00100073); // vle8ff.v v1,(a1)
            trigger_config(0,64'h80010000,64'h6800000000001041);
            trigger_run(64'h80000400,64'h80000400,2);expect_reg(16'h0008,2);expect_reg(16'h0c20,4);
            write_reg(16'h07a1,0);trigger_run(64'h80000400,64'h80000404,1);
            expect_reg(16'h0c20,2);expect_reg(16'h0008,0);
            pb(0,32'h020680a7);pb(1,32'h00100073);execute_pb(0);
            check(memory.ram['h6200]==8'h12&&memory.ram['h6201]==8'h34,"FF resume preserves previously completed prefix");
            expect_reg(16'h0341,64'h12345678);expect_reg(16'h0342,64'h45);expect_reg(16'h0343,64'h89ab);
        end
    endtask
`endif
`endif

`include "test/dbg/trigger_haccess_tests.vh"
