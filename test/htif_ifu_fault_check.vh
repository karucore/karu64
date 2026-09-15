// Optional full-core ordering observer for karu_mmu_test's five page-tail
// cases. The uncached firmware marker is a phase, not a DUT-derived oracle.
// Require actual younger-fetch/older-data overlap, then check which operation
// completes first. This file is included inside the simulation-only htif_tb.
reg ifu_faultcheck = 0;
reg [4:0] ifc_overlap = 0, ifc_walk2 = 0, ifc_complete = 0, ifc_outcome = 0;
integer ifc_phase;
initial ifu_faultcheck = $test$plusargs("ifu_faultcheck");
always @(posedge clk) begin
    if (rst) begin
        ifc_overlap = 0; ifc_walk2 = 0; ifc_complete = 0; ifc_outcome = 0;
    end else if (ifu_faultcheck) begin
        ifc_phase = int'(ram['h230]); // physical 0x80001180
        if (ifc_phase >= 1 && ifc_phase <= 5 && cpu.ex_pc == 64'h4ffc) begin
            if (cpu.ifu_fault_valid && cpu.lsu_active) begin
                ifc_overlap[ifc_phase-1] = 1;
                if (!cpu.lsu_page_fault && cpu.trap_req)
                    $fatal(1,"IFU fault overtook older LSU, phase=%0d",ifc_phase);
            end
            if (cpu.ifu_fault_valid && cpu.lsu_walk2_start)
                ifc_walk2[ifc_phase-1] = 1;
            if (cpu.lsu_active && cpu.lsu_done && !cpu.lsu_fault)
                ifc_complete[ifc_phase-1] = 1;
            if (ifc_phase >= 4 && (cpu.lsu_req_pa || cpu.lsu_arvalid || cpu.lsu_awvalid))
                $fatal(1,"Faulting split access escaped translation preflight, phase=%0d",ifc_phase);
            if (cpu.trap_req && ifc_overlap[ifc_phase-1] && !ifc_outcome[ifc_phase-1]) begin
                if (ifc_phase <= 3) begin
                    if (cpu.trap_cause != 12 || !ifc_complete[ifc_phase-1] || cpu.lsu_active)
                        $fatal(1,"Fetch fault delivered before older LSU completion, phase=%0d",ifc_phase);
                end else if (cpu.trap_cause != (ifc_phase == 4 ? 13 : 15))
                    $fatal(1,"Younger fetch fault defeated older data fault, phase=%0d cause=%0d",
                        ifc_phase,cpu.trap_cause);
                ifc_outcome[ifc_phase-1] = 1;
            end
        end
    end
end
task automatic ifu_fault_check_finish;
    begin
        if (ifu_faultcheck) begin
            if (ifc_overlap != 5'b11111 || ifc_walk2[4:1] != 4'b1111 || ifc_outcome != 5'b11111)
                $fatal(1,"IFU fault ordering coverage incomplete: overlap=%b walk2=%b outcome=%b",
                    ifc_overlap,ifc_walk2,ifc_outcome);
            $display("[ifu_faultcheck] PASS five overlaps, split walks, completion and older-fault priority");
        end
    end
endtask
