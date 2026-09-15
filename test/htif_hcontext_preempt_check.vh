// Passive proof of timer preemption during the maintained two-guest work.
// The firmware supplies code intervals in the uncached HTIF page. No time,
// comparator or interrupt source is forced by this observer.
reg hcontext_preemptcheck = 0;
reg [3:0] hcp_overlap = 0, hcp_retired = 0, hcp_delivered = 0;
reg hcp_timer_prev = 0, hcp_inflight = 0;
reg [63:0] hcp_pc = 0;
integer hcp_slot = 0, hcp_guest = 0, hcp_kind = 0;
initial hcontext_preemptcheck = $test$plusargs("hcontext_preemptcheck");
always @(posedge clk) begin
    if (rst) begin
        hcp_overlap = 0; hcp_retired = 0; hcp_delivered = 0;
        hcp_timer_prev = 0; hcp_inflight = 0;
    end else if (hcontext_preemptcheck) begin
`ifdef KARU_EN_H
`ifdef KARU_EN_V
`ifdef KARU_EN_F
        if (ram['h238] == 1) begin // physical 0x800011c0
            if (cpu.csr.vstime_pending_q && !hcp_timer_prev) begin
                hcp_guest = int'(cpu.csr_hgatp[57:44]) - 3;
                if (!cpu.csr_virt || cpu.csr_priv != 1 || hcp_guest < 0 || hcp_guest > 1 ||
                    cpu.csr_vsatp[59:44] != 17 + hcp_guest || !cpu.csr.h_stce ||
                    cpu.csr.csr_hvip != 0 || !cpu.csr_irq_pending ||
                    cpu.csr_irq_cause != 64'h8000_0000_0000_0006 || cpu.csr_irq_target != 1)
                    $fatal(1,"Guest timer source/context mismatch at pending edge");
                hcp_kind = -1;
                if (cpu.fpu_active && cpu.ex_pc >= ram['h239] && cpu.ex_pc < ram['h23a])
                    hcp_kind = 0;
                if (cpu.varith_active && cpu.ex_pc >= ram['h23b] && cpu.ex_pc < ram['h23c])
                    hcp_kind = 1;
                if (hcp_kind < 0)
                    $fatal(1,"Guest timer did not become pending during selected FP/vector work: guest=%0d pc=%h",
                        hcp_guest,cpu.ex_pc);
                hcp_slot = hcp_guest + 2*hcp_kind;
                if (hcp_inflight || hcp_overlap[hcp_slot])
                    $fatal(1,"Duplicate guest preemption overlap, slot=%0d",hcp_slot);
                hcp_pc = cpu.ex_pc;
                hcp_overlap[hcp_slot] = 1;
                hcp_inflight = 1;
            end
            if (hcp_inflight) begin
                if (cpu.trap_req && !cpu.irq_take)
                    $fatal(1,"Unexpected synchronous trap during guest preemption");
                if (cpu.perf_retire) begin
                    if (hcp_retired[hcp_slot] || cpu.ex_pc != hcp_pc ||
                        (hcp_kind == 0 && !(cpu.fpu_active && cpu.fpu_done && cpu.fwb_we &&
                          cpu.fwb_rd == 0 && cpu.fwb_v == 64'h3ff0_0000_0000_0000)) ||
                        (hcp_kind == 1 && !(cpu.varith_active && cpu.varith_done)))
                        $fatal(1,"Guest operation retirement/writeback mismatch, slot=%0d",hcp_slot);
                    hcp_retired[hcp_slot] = 1;
                end
            end
            if (cpu.irq_take) begin
                if (!hcp_inflight || !hcp_retired[hcp_slot] || cpu.exec_busy || cpu.ex_valid ||
                    cpu.fwb_we || cpu.gw_we || !cpu.csr_virt ||
                    cpu.csr_irq_cause != 64'h8000_0000_0000_0006 || cpu.csr_irq_target != 1 ||
                    cpu.trap_epc != hcp_pc + 4)
                    $fatal(1,"Guest preemption was not drained/precise, slot=%0d pc=%h epc=%h",
                        hcp_slot,hcp_pc,cpu.trap_epc);
                hcp_delivered[hcp_slot] = 1;
                hcp_inflight = 0;
                $display("[hcontext_preemptcheck] guest=%0d %s pending -> retire -> HS IRQ, pc=%h",
                    hcp_guest,hcp_kind == 0 ? "FP" : "vector",hcp_pc);
            end
            hcp_timer_prev = cpu.csr.vstime_pending_q;
        end
`else
        $fatal(1,"hcontext_preemptcheck requires F");
`endif
`else
        $fatal(1,"hcontext_preemptcheck requires V");
`endif
`else
        $fatal(1,"hcontext_preemptcheck requires H");
`endif
    end
end
task automatic hcontext_preempt_check_finish;
    begin
        if (hcontext_preemptcheck) begin
            if (hcp_overlap != 4'b1111 || hcp_retired != 4'b1111 ||
                hcp_delivered != 4'b1111 || hcp_inflight || ram['h23d] != 4)
                $fatal(1,"Guest preemption coverage incomplete: overlap=%b retired=%b delivered=%b",
                    hcp_overlap,hcp_retired,hcp_delivered);
            $display("[hcontext_preemptcheck] PASS both guests FP/vector overlap, retirement and precise HS delivery");
        end
    end
endtask
