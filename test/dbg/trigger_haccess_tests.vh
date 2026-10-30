// SPDX-License-Identifier: BSD-2-Clause
// Architectural HLV/HLVX/HSV watchpoint context and pointer-masking probes.
`ifdef KARU_DBG_TRIGGERS
`ifdef KARU_EN_H
    task trigger_haccess_run(input[31:0] instruction,input[63:0] context_word,
                            input[63:0] address_value,input[63:0] match_address,
                            input[63:0] trigger_word);
        reg[63:0] observed;
        begin
            put_insn('h400,instruction);put_insn('h404,32'h00100073);
            pb(0,32'h0000100f);pb(1,32'h00100073);execute_pb(0);
            write_reg(16'h100b,address_value);
            trigger_config(0,match_address,trigger_word);
            expect_reg(16'h07a2,match_address);
            write_reg(16'h07b1,64'h80000400);write_reg(16'h07b0,context_word);
            resume_hart;wait_parked;expect_reg(16'h07b1,64'h80000400);
            read_reg(16'h07b0,observed);check(observed[8:6]==2,"H access watchpoint debug cause");
            write_reg(16'h07a1,0);
        end
    endtask
    task trigger_haccess_tests;
        integer n,kind,context_kind,pml;
        reg[63:0] saved_status,saved_hstatus,saved_henv,saved_senv;
        reg[63:0] saved_satp,saved_vsatp,saved_hgatp;
        reg[63:0] pmm,hs,new_senv,new_henv,tagged_addr,match_addr,mode_word,trigger_word;
        begin
            phase="forced-guest HLV/HSV watchpoint SPVP/HUPMM context";
            read_reg(16'h0300,saved_status);read_reg(16'h0600,saved_hstatus);
            read_reg(16'h060a,saved_henv);read_reg(16'h010a,saved_senv);
            read_reg(16'h0180,saved_satp);read_reg(16'h0280,saved_vsatp);
            read_reg(16'h0680,saved_hgatp);
            for(n=0;n<4096;n=n+1)begin memory.ram['h8000+n]=0;memory.ram['hc000+n]=0;end
            trigger_pte('h8000,64'h200000cf);trigger_pte('h8010,64'h200000cf);
            trigger_pte('hc010,64'h200000df);
            write_reg(16'h0180,0);write_reg(16'h0280,64'h8000000000080008);
            write_reg(16'h0680,64'h800000000008000c);
            write_reg(16'h0300,saved_status&~64'h80000); // MXR initially zero
            write_reg(16'h100c,64'h11223344);
            pb(0,32'h62000073);pb(1,32'h22000073);pb(2,32'h00100073);execute_pb(0);
            for(context_kind=0;context_kind<3;context_kind=context_kind+1)
                for(pml=0;pml<3;pml=pml+1)begin
                    pmm=pml==0?0:pml==1?2:3;
                    tagged_addr=pml==2?64'habcd000000006000:64'hac00000000006000;
                    match_addr=pml==0?tagged_addr:64'h6000;
                    // HS/SPVP=1 takes henvcfg; HS/SPVP=0 takes senvcfg;
                    // U/HU=1 takes HUPMM. Other PMM knobs are independently0.
                    hs=(saved_hstatus&~64'h0003000000000300)|64'h200;
                    if(context_kind==0)hs=hs|64'h100;
                    if(context_kind==2)hs=hs|(pmm<<48);
                    new_senv=(saved_senv&~64'h300000000)|(context_kind==1?pmm<<32:0);
                    new_henv=(saved_henv&~64'h300000000)|(context_kind==0?pmm<<32:0);
                    write_reg(16'h0600,hs);write_reg(16'h010a,new_senv);write_reg(16'h060a,new_henv);
                    mode_word=context_kind==2?64'h3b000:64'h3b001;
                    for(kind=0;kind<2;kind=kind+1)begin
                        trigger_word=64'h6800000000001000|(context_kind==2?8:16)|(kind==0?1:2);
                        trigger_haccess_run(kind==0?32'h6805c673:32'h6ac5c073,
                                            mode_word,tagged_addr,match_addr,trigger_word);
                    end
                end
            // HLVX is unmasked even with a nonzero HUPMM; MXR disables PM for
            // ordinary HLV as well. Both compare the full tagged address.
            tagged_addr=64'habcd000000006000;
            trigger_haccess_run(32'h6835c673,64'h3b000,tagged_addr,tagged_addr,64'h6800000000001009);
            write_reg(16'h0300,saved_status|64'h80000);
            trigger_haccess_run(32'h6805c673,64'h3b000,tagged_addr,tagged_addr,64'h6800000000001009);
            write_reg(16'h0300,saved_status);write_reg(16'h0600,saved_hstatus);
            write_reg(16'h060a,saved_henv);write_reg(16'h010a,saved_senv);
            write_reg(16'h0180,saved_satp);write_reg(16'h0280,saved_vsatp);
            write_reg(16'h0680,saved_hgatp);
            write_reg(16'h07b0,3);write_reg(16'h07b1,64'h80000000);
            $display("karudbg H access watchpoints: PASS 20 SPVP/HUPMM/MXR/HLVX cases");
        end
    endtask
`endif
`endif
