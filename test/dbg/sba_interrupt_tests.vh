// SPDX-License-Identifier: BSD-3-Clause
// A pending machine software interrupt must wait for RAM maintenance, then
// enter the ordinary handler exactly once. Inputs are platform pins, not
// forced internal CSR/pipeline state.
    reg sba_irq_watch=0;
    integer sba_irq_holds=0, sba_irq_entries=0, sba_irq_handled=0;
    always @(posedge clk) if(sba_irq_watch && !rst) begin
        if(dut.sba_pause && irq_software) begin
            check(!dut.core.irq_take,"SBA issue hold defers pending interrupt entry");
            check(!debug_mode_o,"SBA interrupt test stays in normal execution");
            sba_irq_holds++;
        end
        if(dut.core.perf_retire && dut.core.ex_pc==64'h80007f00)
            sba_irq_handled++;
        if(dut.core.irq_take) begin
            check(!dut.sba_pause,"SBA completes maintenance before interrupt entry");
            check(dut.core.csr_irq_cause==64'h8000000000000003,"machine software interrupt cause");
            sba_irq_entries++;
        end
    end
    task sba_pending_interrupt_test;
        reg [63:0] saved_status,saved_ie,saved_vec,saved_epc,saved_cause,saved_tval,saved_dpc;
        integer timeout_cycles;
        begin
            phase="SBA maintenance with pending interrupt";
            read_reg(16'h0300,saved_status);read_reg(16'h0304,saved_ie);
            read_reg(16'h0305,saved_vec);read_reg(16'h0341,saved_epc);
            read_reg(16'h0342,saved_cause);read_reg(16'h0343,saved_tval);
            read_reg(16'h07b1,saved_dpc);
            put_insn('h7e00,32'h00128293); // addi t0,t0,1
            put_insn('h7e04,32'hffdff06f); // j -4
            put_insn('h7f00,32'h001e0e13); // addi t3,t3,1
            put_insn('h7f04,32'h30200073); // mret
            pb(0,32'h0000100f);pb(1,32'h00100073);execute_pb(0);
            write_reg(16'h101c,0);write_reg(16'h1005,0);
            write_reg(16'h0305,64'h80007f00);write_reg(16'h0304,8);
            write_reg(16'h0300,saved_status|64'd8);
            write_reg(16'h07b0,3);write_reg(16'h07b1,64'h80007e00);
            sba_irq_watch=1;sba_irq_holds=0;sba_irq_entries=0;sba_irq_handled=0;
            resume_hart;
            fork
                begin
                    wait(dut.sba_pause);
                    @(negedge clk);irq_software=1;
                    wait(!dut.sba_pause);
                    wait(dut.core.irq_take);
                    @(posedge clk); #1; // retain the level through trap acceptance
                    @(negedge clk);irq_software=0;
                end
                begin sba_write(32'h80006000,3,64'hfeedface11223344,0);end
            join
            timeout_cycles=0;
            while(sba_irq_handled==0 && timeout_cycles<2000)begin
                @(negedge clk);timeout_cycles++;
            end
            if(timeout_cycles==2000)
                $fatal(1,"SBA IRQ handler timeout: entries=%0d handled=%0d pc=%h cause=%h epc=%h",sba_irq_entries,sba_irq_handled,dut.core.ex_pc,dut.core.csr.csr_mcause,dut.core.csr.csr_mepc);
            check(timeout_cycles<2000,"pending interrupt reaches handler after maintenance");
            wr(7'h10,32'h80000001);wait_parked;
            sba_irq_watch=0;
            expect_reg(16'h101c,1);
            check(sba_irq_holds>0 && sba_irq_entries==1 && sba_irq_handled==1,"interrupt held during maintenance and delivered once");
            check(memory.ram_word(32'h80006000)==64'hfeedface11223344,"interrupt does not bypass SBA data completion");
            write_reg(16'h0304,saved_ie);write_reg(16'h0300,saved_status);
            write_reg(16'h0305,saved_vec);write_reg(16'h0341,saved_epc);
            write_reg(16'h0342,saved_cause);write_reg(16'h0343,saved_tval);
            write_reg(16'h07b1,saved_dpc);
            $display("karudbg SBA pending interrupt: PASS");
        end
    endtask
