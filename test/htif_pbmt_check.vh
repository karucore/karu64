// Optional full-core Svpbmt transaction observer, included inside htif_tb.
// +pbmt_check checks any attributed traffic; =1/=2 additionally requires NC/IO.
// Successful walker results are the attribute oracle, not later PTE memory:
// changing a PTE without invalidation may legally leave a cached translation.
// All state below is testbench-only. The byte oracle uses architectural vector
// geometry/masks rather than the VLSU's generated granule enables.

integer pbmt_check_mode = 0;
integer pbmt_guest_check = 0;
integer pbmt_arg;
initial begin
    if ($test$plusargs("pbmt_check")) pbmt_check_mode = 3;
    pbmt_arg = $value$plusargs("pbmt_check=%d", pbmt_check_mode);
    if (pbmt_check_mode < 0 || pbmt_check_mode > 3)
        $fatal(1, "pbmt_check expects 1=NC, 2=IO, or no value=any");
    if ($test$plusargs("pbmt_guest_check")) begin
        pbmt_guest_check=1;
        if (pbmt_check_mode == 0) pbmt_check_mode=3;
`ifndef KARU_EN_H
        $fatal(1, "pbmt_guest_check requires KARU_EN_H and H_TEST_PBMT firmware");
`endif
    end
end

// Fixture-specific independent oracle for H_TEST_PBMT in karu_h_test.S.
// Sample the actual VS/G leaf PTEs when a request starts, not a downstream
// attribute and not PTE contents at completion. This fixture flushes after
// changing a leaf/root; it does not expect unsynchronized PTE writes to
// invalidate a legal cached translation. Other roots/pages are left alone.
reg [3:0] pbmt_guest_seen [0:8]; // scalar R/W, vector R/W for each VS/G pair
reg [8:0] pbmt_guest_if_seen = 0;
integer pbmt_guest_faults = 0, pbmt_guest_ff_errors = 0;
reg pbmt_guest_d_pending=0, pbmt_guest_i_pending=0;
reg [63:0] pbmt_guest_d_pa, pbmt_guest_i_pa;
reg [1:0] pbmt_guest_d_type, pbmt_guest_i_type;
integer pbmt_guest_d_pair, pbmt_guest_i_pair, pbmt_guest_d_kind, pbmt_guest_k;
reg [143:0] pbmt_guest_cbo_seen = 0;
reg pbmt_guest_cbo_active = 0, pbmt_guest_cbo_sampled;
reg [63:0] pbmt_guest_cbo_pc, pbmt_guest_cbo_pa;
reg [31:0] pbmt_guest_cbo_ins;
reg [1:0] pbmt_guest_cbo_attr;
reg pbmt_guest_cbo_m, pbmt_guest_cbo_h, pbmt_guest_cbo_s;
integer pbmt_guest_cbo_pair, pbmt_guest_cbo_form, pbmt_guest_cbo_gate;
integer pbmt_guest_cbo_slot, pbmt_guest_cbo_cause, pbmt_guest_cbo_req;
integer pbmt_guest_cbo_aw, pbmt_guest_cbo_w, pbmt_guest_cbo_b, pbmt_guest_cbo_i;
reg [1:0] pbmt_guest_cbo_priv = 0, pbmt_guest_cbo_cbie = 0;

task automatic pbmt_guest_sample(
    input [63:0] va, input [63:0] vsatp, input [63:0] hgatp, input virt,
    output sampled, output [63:0] pa, output [1:0] attr, output integer pair);
    reg [63:0] vsleaf, gleaf, gpa;
    begin
        sampled=0; pa=0; attr=0; pair=0;
        if (virt && vsatp[63:60] == 8 && hgatp[63:60] == 8 &&
            vsatp[43:0] == 44'h90010 && hgatp[43:0] == 44'h80050 &&
            va[63:21] == 43'h200 &&
            (va[20:12] == 32 || va[20:12] == 33 ||
             va[20:12] == 100 || va[20:12] == 101)) begin
            vsleaf=ram[(32'h42000 >> 3)+integer'(va[20:12])];
            gpa={8'b0,vsleaf[53:10],va[11:0]};
            gleaf=ram[(32'h56000 >> 3)+integer'(gpa[20:12])];
            if (vsleaf[0] && (vsleaf[1] || vsleaf[3]) &&
                gleaf[0] && (gleaf[1] || gleaf[3]) &&
                vsleaf[62:61] != 3 && gleaf[62:61] != 3) begin
                sampled=1;
                pa={8'b0,gleaf[53:10],va[11:0]};
                attr=vsleaf[62:61] != 0 ? vsleaf[62:61] : gleaf[62:61];
                pair=integer'(vsleaf[62:61])*3+integer'(gleaf[62:61]);
            end
        end
    end
endtask

`ifdef KARU_EN_H
// Independent CBO oracle: the fixture's VA and raw PTE/ENVCFG fields define
// the expected operation, not the decoder's permission or PBMT outputs.
// The valid-bit check pins this write-through implementation's conservative
// flush policy; clean is architecturally permitted, not required, to evict.
always @(posedge clk) begin
    if (rst) begin
        pbmt_guest_cbo_seen=0; pbmt_guest_cbo_active=0;
        pbmt_guest_cbo_priv=0; pbmt_guest_cbo_cbie=0;
    end else if (pbmt_guest_check != 0) begin
`ifdef KARU_EN_MEM
        if (cpu.issuing && cpu.csr_virt && cpu.ex_ins[19:0] == 20'h5a00f) begin
            if (pbmt_guest_cbo_active) $fatal(1,"PBMT guest CBO overlap");
            case (cpu.ex_ins[31:20])
                4: pbmt_guest_cbo_form=0;
                1: pbmt_guest_cbo_form=1;
                2: pbmt_guest_cbo_form=2;
                0: pbmt_guest_cbo_form=3;
                default: $fatal(1,"PBMT guest CBO fixture has unknown instruction");
            endcase
            pbmt_guest_sample(64'h400200bf,cpu.csr_vsatp,cpu.csr_hgatp,1'b1,
                pbmt_guest_cbo_sampled,pbmt_guest_cbo_pa,pbmt_guest_cbo_attr,pbmt_guest_cbo_pair);
            if (!pbmt_guest_cbo_sampled || pbmt_guest_cbo_pa != 64'h800600bf ||
                cpu.lsu_addr != 64'h400200bf || !cpu.csr.menvcfg_pbmte ||
                !cpu.csr.csr_henvcfg[62])
                $fatal(1,"PBMT guest CBO fixture address/root/PBMTE mismatch");
            if (pbmt_guest_cbo_form == 0) begin
                pbmt_guest_cbo_m=cpu.csr.menvcfg_cbze;
                pbmt_guest_cbo_h=cpu.csr.csr_henvcfg[7];
                pbmt_guest_cbo_s=cpu.csr.senvcfg_cbze;
            end else if (pbmt_guest_cbo_form == 3) begin
                pbmt_guest_cbo_m=|cpu.csr.menvcfg_cbie;
                pbmt_guest_cbo_h=|cpu.csr.csr_henvcfg[5:4];
                pbmt_guest_cbo_s=|cpu.csr.senvcfg_cbie;
            end else begin
                pbmt_guest_cbo_m=cpu.csr.menvcfg_cbcfe;
                pbmt_guest_cbo_h=cpu.csr.csr_henvcfg[6];
                pbmt_guest_cbo_s=cpu.csr.senvcfg_cbcfe;
            end
            pbmt_guest_cbo_gate=0; pbmt_guest_cbo_cause=0;
            if (!pbmt_guest_cbo_m) begin
                pbmt_guest_cbo_gate=1; pbmt_guest_cbo_cause=2;
                if (pbmt_guest_cbo_h || pbmt_guest_cbo_s)
                    $fatal(1,"PBMT guest CBO machine-priority case omitted lower denials");
            end else if (!pbmt_guest_cbo_h) begin
                pbmt_guest_cbo_gate=2; pbmt_guest_cbo_cause=22;
            end else if (cpu.csr_priv == 0 && !pbmt_guest_cbo_s) begin
                pbmt_guest_cbo_gate=3; pbmt_guest_cbo_cause=22;
            end
            if (cpu.csr_priv > 1) $fatal(1,"PBMT guest CBO not in VS/VU");
            pbmt_guest_cbo_slot=pbmt_guest_cbo_pair*16+pbmt_guest_cbo_form*4+pbmt_guest_cbo_gate;
            if (pbmt_guest_cbo_seen[pbmt_guest_cbo_slot])
                $fatal(1,"PBMT guest CBO duplicated coverage slot %0d",pbmt_guest_cbo_slot);
            if (pbmt_guest_cbo_gate == 0) begin
                pbmt_guest_cbo_priv[cpu.csr_priv]=1;
                if (pbmt_guest_cbo_form == 3)
                    pbmt_guest_cbo_cbie[cpu.csr.menvcfg_cbie == 3]=1;
            end
            pbmt_guest_cbo_active=1; pbmt_guest_cbo_pc=cpu.ex_pc;
            pbmt_guest_cbo_ins=cpu.ex_ins; pbmt_guest_cbo_req=0;
            pbmt_guest_cbo_aw=0; pbmt_guest_cbo_w=0; pbmt_guest_cbo_b=0;
        end
        if (pbmt_guest_cbo_active) begin
            // Page-table reads use the separate DMMU owner, never this L1
            // master. No CBO in this write-through implementation reads data.
            if (cpu.km_arvalid || cpu.lsu_arvalid)
                $fatal(1,"PBMT guest CBO generated a data read");
            if (pbmt_guest_cbo_gate != 0) begin
                if (cpu.dmmu_req || cpu.lsu_req_pa || cpu.dmem_l1.flush ||
                    cpu.km_awvalid || cpu.km_wvalid || cpu.lsu_awvalid || cpu.lsu_wvalid ||
                    cpu.perf_retire || cpu.wb_we || cpu.fwb_we || cpu.gw_we)
                    $fatal(1,"PBMT denied guest CBO reached translation/memory/cache/writeback");
                if (cpu.trap_req) begin
                    // CSR trap-target encoding is 0=M, 1=HS, 2=VS, not MPP.
                    if (cpu.trap_cause != 64'(pbmt_guest_cbo_cause) || cpu.trap_epc != pbmt_guest_cbo_pc ||
                        cpu.trap_tval != {32'b0,pbmt_guest_cbo_ins} || cpu.trap_gva ||
                        cpu.trap_gpa_valid || cpu.trap_gpa != 0 || cpu.trap_tinst != 0 ||
                        cpu.csr_trap_target != (pbmt_guest_cbo_cause == 2 ? 0 : 1))
                        $fatal(1,"PBMT denied guest CBO metadata slot=%0d cause=%0d/%0d pc=%h/%h tval=%h/%h target=%0d GVA=%b GPA-valid=%b GPA=%h tinst=%h",
                            pbmt_guest_cbo_slot,cpu.trap_cause,pbmt_guest_cbo_cause,cpu.trap_epc,pbmt_guest_cbo_pc,
                            cpu.trap_tval,pbmt_guest_cbo_ins,cpu.csr_trap_target,cpu.trap_gva,
                            cpu.trap_gpa_valid,cpu.trap_gpa,cpu.trap_tinst);
                    pbmt_guest_cbo_seen[pbmt_guest_cbo_slot]=1;
                    pbmt_guest_cbo_active=0;
                end
            end else begin
                if (cpu.trap_req) $fatal(1,"PBMT allowed guest CBO trapped");
                if (cpu.lsu_req_pa) begin
                    if (cpu.lsu_pa_w != pbmt_guest_cbo_pa || cpu.lsu_pbmt != pbmt_guest_cbo_attr)
                        $fatal(1,"PBMT guest CBO lost translated PA/type");
                    pbmt_guest_cbo_req=pbmt_guest_cbo_req+1;
                    if (pbmt_guest_cbo_form != 0 &&
                        (!cpu.dmem_l1.flush || !cpu.dmem_l1.line_valid[(32'h80060080>>6)&(cpu.dmem_l1.SETS-1)] ||
                         cpu.dmem_l1.line_tag_u.mem[(32'h80060080>>6)&(cpu.dmem_l1.SETS-1)] !=
                         (32'h80060080 >> (6+cpu.dmem_l1.IDXW))))
                        $fatal(1,"PBMT guest management CBO did not flush its warmed physical alias");
                end
                if (pbmt_guest_cbo_form != 0 &&
                    (cpu.km_awvalid || cpu.km_wvalid || cpu.lsu_awvalid || cpu.lsu_wvalid))
                    $fatal(1,"PBMT guest management CBO wrote data in write-through cache");
                if (dmem_awvalid && dmem_awready && cpu.wr_owner == 0) begin
                    if (pbmt_guest_cbo_form != 0 || pbmt_guest_cbo_aw >= 8 ||
                        dmem_awaddr != 32'h80060080+32'(pbmt_guest_cbo_aw*8) ||
                        dmem_awlen != 0 || dmem_awsize != 3)
                        $fatal(1,"PBMT guest CBO.ZERO changed block/beat geometry");
                    pbmt_guest_cbo_aw=pbmt_guest_cbo_aw+1;
                end
                if (dmem_wvalid && dmem_wready && cpu.wr_owner == 0) begin
                    if (pbmt_guest_cbo_form != 0 || dmem_wdata != 0 || dmem_wstrb != 8'hff || !dmem_wlast)
                        $fatal(1,"PBMT guest CBO.ZERO changed data/byte footprint");
                    pbmt_guest_cbo_w=pbmt_guest_cbo_w+1;
                end
                if (dmem_bvalid && dmem_bready && cpu.wr_owner == 0)
                    pbmt_guest_cbo_b=pbmt_guest_cbo_b+1;
                if (cpu.perf_retire) begin
                    if (cpu.ex_pc != pbmt_guest_cbo_pc || !cpu.lsu_done || pbmt_guest_cbo_req != 1 ||
                        pbmt_guest_cbo_aw != (pbmt_guest_cbo_form == 0 ? 8 : 0) ||
                        pbmt_guest_cbo_w != pbmt_guest_cbo_aw || pbmt_guest_cbo_b != pbmt_guest_cbo_aw)
                        $fatal(1,"PBMT guest CBO retired without exact completed effects");
                    if (pbmt_guest_cbo_form != 0 &&
                        cpu.dmem_l1.line_valid[(32'h80060080>>6)&(cpu.dmem_l1.SETS-1)])
                        $fatal(1,"PBMT guest management CBO left its physical cache alias valid");
                    pbmt_guest_cbo_seen[pbmt_guest_cbo_slot]=1;
                    pbmt_guest_cbo_active=0;
                end
            end
            if (!pbmt_guest_cbo_active) begin
                if (ram['hc00f] != 64'h13579bdf2468ace0 || ram['hc018] != 64'h13579bdf2468ace0)
                    $fatal(1,"PBMT guest CBO changed a neighboring word");
                for (pbmt_guest_cbo_i=0;pbmt_guest_cbo_i<8;pbmt_guest_cbo_i=pbmt_guest_cbo_i+1)
                    if (ram['hc010+pbmt_guest_cbo_i] !=
                        (pbmt_guest_cbo_gate == 0 && pbmt_guest_cbo_form == 0 ? 64'b0 : 64'h13579bdf2468ace0))
                        $fatal(1,"PBMT guest CBO block bytes disagree with permitted operation");
            end
        end
`else
        $fatal(1,"PBMT guest CBO observer requires KARU_EN_MEM");
`endif
    end
end

always @(posedge clk) begin
    if (rst) begin
        pbmt_guest_d_pending=0; pbmt_guest_i_pending=0;
        pbmt_guest_if_seen=0; pbmt_guest_faults=0; pbmt_guest_ff_errors=0;
        for (pbmt_guest_k=0;pbmt_guest_k<9;pbmt_guest_k=pbmt_guest_k+1)
            pbmt_guest_seen[pbmt_guest_k]=0;
    end else if (pbmt_guest_check != 0) begin
        if (cpu.dmmu_done) begin
            if (pbmt_guest_d_pending && !cpu.dmmu_fault) begin
                if (cpu.dmmu_pa !== pbmt_guest_d_pa || cpu.dmmu_pbmt !== pbmt_guest_d_type)
                    $fatal(1,"PBMT guest data translation differs from VS/G PTE oracle: PA=%h/%h type=%0d/%0d pair=%0d",
                        cpu.dmmu_pa,pbmt_guest_d_pa,cpu.dmmu_pbmt,pbmt_guest_d_type,pbmt_guest_d_pair);
                if (pbmt_guest_d_kind >= 0)
                    pbmt_guest_seen[pbmt_guest_d_pair][pbmt_guest_d_kind]=1;
            end
            pbmt_guest_d_pending=0;
        end
        if (cpu.immu_done) begin
            if (pbmt_guest_i_pending && !cpu.immu_fault && !cpu.ifu.xlate_discard && !cpu.ifu_redir) begin
                if (cpu.immu_pa !== pbmt_guest_i_pa || cpu.immu_pbmt !== pbmt_guest_i_type)
                    $fatal(1,"PBMT guest fetch translation differs from VS/G PTE oracle");
                pbmt_guest_if_seen[pbmt_guest_i_pair]=1;
            end
            pbmt_guest_i_pending=0;
        end
        if (cpu.dmmu.req && !cpu.dmmu.busy) begin
            pbmt_guest_sample(cpu.dmmu.va,cpu.dmmu.vsatp,cpu.dmmu.hgatp,cpu.dmmu.virt,
                pbmt_guest_d_pending,pbmt_guest_d_pa,pbmt_guest_d_type,pbmt_guest_d_pair);
            pbmt_guest_d_kind=cpu.dmmu.access == 1 ? 0 : cpu.dmmu.access == 2 ? 1 : -1;
            if (pbmt_guest_d_kind >= 0 && cpu.vxlate_req) pbmt_guest_d_kind=pbmt_guest_d_kind+2;
        end
        if (cpu.immu.req && !cpu.immu.busy)
            pbmt_guest_sample(cpu.immu.va,cpu.immu.vsatp,cpu.immu.hgatp,cpu.immu.virt,
                pbmt_guest_i_pending,pbmt_guest_i_pa,pbmt_guest_i_type,pbmt_guest_i_pair);
        // All four explicit bus-error cases retain the guest VA/GVA and
        // zero non-reportable GPA/tinst. FF errors after a completed prefix
        // trim instead of generating one of these architectural traps.
        if (cpu.trap_req && cpu.csr_virt && cpu.trap_tval == 64'h40020030 &&
            pbmt_guest_d_pa[31:24] == 8'h88 && pbmt_guest_d_type != 0) begin
            if ((cpu.trap_cause != 5 && cpu.trap_cause != 7) || !cpu.trap_gva ||
                cpu.trap_gpa_valid || cpu.trap_gpa != 0 || cpu.trap_tinst != 0)
                $fatal(1,"PBMT guest physical bus error has wrong architectural metadata");
            pbmt_guest_faults=pbmt_guest_faults+1;
        end
        if (cpu.vmem_fault && cpu.csr_virt && cpu.vlsu_ff &&
            cpu.vmem_fault_va == 64'h40021000)
            pbmt_guest_ff_errors=pbmt_guest_ff_errors+1;
    end
end
`endif

integer pbmt_nc_requests = 0, pbmt_io_requests = 0;
integer pbmt_vector_requests = 0, pbmt_io_bytes = 0;
integer pbmt_if_nc = 0, pbmt_if_io = 0;
integer pbmt_ar_count = 0, pbmt_aw_count = 0, pbmt_w_count = 0, pbmt_b_count = 0;
integer pbmt_r_count = 0;
reg [1:0] pbmt_scalar_first, pbmt_scalar_second;
reg [1:0] pbmt_scalar_attr0, pbmt_scalar_attr1;
reg [31:0] pbmt_scalar_pa0, pbmt_scalar_pa1;
reg [2:0] pbmt_scalar_io_size;
reg [1:0] pbmt_if_xlate, pbmt_if_attr;
reg pbmt_if_prev_ar = 0, pbmt_fetch_safe_prev = 0, pbmt_if_active = 0;
reg [31:0] pbmt_if_pa;
integer pbmt_if_bus_ar = 0, pbmt_if_bus_r = 0;

// One active L1 operation plus its one-entry vector waiting slot. The small
// observer FIFO follows request pulses, independently of the L1's own tags.
reg [1:0] pbmt_q_type [0:3];
reg [31:0] pbmt_q_pa [0:3];
reg [63:0] pbmt_q_va [0:3];
reg [15:0] pbmt_q_mask [0:3];
reg [1:0] pbmt_q_size [0:3];
reg pbmt_q_store [0:3];
integer pbmt_q_rd = 0, pbmt_q_wr = 0, pbmt_q_count = 0;
reg pbmt_active = 0, pbmt_active_vector, pbmt_active_store;
reg [1:0] pbmt_active_type;
reg [31:0] pbmt_active_pa;
reg [63:0] pbmt_active_va;
reg [15:0] pbmt_active_mask, pbmt_seen_mask;
reg [2:0] pbmt_active_size;
reg pbmt_read_pending, pbmt_write_pending, pbmt_write_data;
reg [7:0] pbmt_expected_wstrb;
reg [63:0] pbmt_last_io_va;
reg pbmt_error_seen;
integer pbmt_i, pbmt_j, pbmt_slot, pbmt_off, pbmt_bytes, pbmt_size;
reg [15:0] pbmt_transfer_mask;
reg [1:0] pbmt_expected_type;
reg pbmt_capture;

`ifdef KARU_EN_V
reg [15:0] pbmt_page_valid;
reg [51:0] pbmt_page_va [0:15], pbmt_page_pa [0:15];
reg [1:0] pbmt_page_type [0:15];
integer pbmt_page_replace;
reg [63:0] pbmt_vbase, pbmt_vstride, pbmt_vl;
reg [31:0] pbmt_vstart;
reg [1:0] pbmt_veew;
reg pbmt_vmasked, pbmt_vpelem, pbmt_vindexed, pbmt_vvirtual;
reg [5:0] pbmt_vpmlen;
reg [`KARU_VLEN-1:0] pbmt_vmask;
reg [63:0] pbmt_elem_raw, pbmt_elem_va, pbmt_delta;
reg [31:0] pbmt_elem_index;
reg [15:0] pbmt_expected_mask;
reg [1:0] pbmt_expected_size;

function automatic [63:0] pbmt_mask_pointer(input [63:0] a);
    begin
        case (pbmt_vpmlen)
            7: pbmt_mask_pointer = {{7{pbmt_vvirtual && a[56]}},a[56:0]};
            16: pbmt_mask_pointer = {{16{pbmt_vvirtual && a[47]}},a[47:0]};
            default: pbmt_mask_pointer = a;
        endcase
    end
endfunction
`endif

// Find the next complete active IO element, or one byte of a partial or
// unaligned element. This is an independent bounded byte-set calculation.
task automatic pbmt_next_transfer;
    begin
        pbmt_off = 16;
        for (pbmt_j=15; pbmt_j>=0; pbmt_j=pbmt_j-1)
            if (pbmt_active_mask[pbmt_j] && !pbmt_seen_mask[pbmt_j]) pbmt_off=pbmt_j;
        if (pbmt_off == 16) $fatal(1, "PBMT IO extra transaction after all active bytes");
        pbmt_size = pbmt_active_size;
        pbmt_bytes = 1 << pbmt_size;
        if ((pbmt_off & (pbmt_bytes-1)) != 0 || pbmt_off+pbmt_bytes > 16)
            pbmt_size=0;
        for (pbmt_j=0; pbmt_j<8; pbmt_j=pbmt_j+1)
            if (pbmt_j < pbmt_bytes && pbmt_off+pbmt_j < 16 &&
                (!pbmt_active_mask[pbmt_off+pbmt_j] || pbmt_seen_mask[pbmt_off+pbmt_j]))
                pbmt_size=0;
        pbmt_bytes = 1 << pbmt_size;
        pbmt_transfer_mask = ((16'h0001 << pbmt_bytes)-1) << pbmt_off;
        pbmt_expected_wstrb = ((8'h01 << pbmt_bytes)-1) << (pbmt_off & 7);
    end
endtask

task automatic pbmt_check_finish;
    begin
        if (pbmt_check_mode != 0) begin
            if (pbmt_q_count != 0 || pbmt_read_pending || pbmt_write_pending)
                $fatal(1, "PBMT observer has undrained attributed requests");
            if ((pbmt_check_mode == 1 && pbmt_nc_requests+pbmt_if_nc == 0) ||
                (pbmt_check_mode == 2 && pbmt_io_requests+pbmt_if_io == 0) ||
                (pbmt_nc_requests+pbmt_io_requests+pbmt_if_nc+pbmt_if_io == 0))
                $fatal(1, "PBMT expected attributed traffic was not observed");
            $display("[pbmt_check] PASS NC=%0d IO=%0d vector=%0d IO-bytes=%0d IF-NC=%0d IF-IO=%0d",
                pbmt_nc_requests,pbmt_io_requests,pbmt_vector_requests,pbmt_io_bytes,pbmt_if_nc,pbmt_if_io);
            if (pbmt_guest_check != 0) begin
                for (pbmt_guest_k=0;pbmt_guest_k<9;pbmt_guest_k=pbmt_guest_k+1)
                    if (pbmt_guest_seen[pbmt_guest_k] !== 4'b1111 || !pbmt_guest_if_seen[pbmt_guest_k])
                        $fatal(1,"PBMT guest VS/G pair %0d missing scalar/vector R/W or fetch coverage",pbmt_guest_k);
                if (pbmt_guest_faults != 4 || pbmt_guest_ff_errors != 2 || pbmt_if_nc == 0 || pbmt_if_io == 0)
                    $fatal(1,"PBMT guest missing explicit faults, FF errors or attributed fetches: faults=%0d FF=%0d",
                        pbmt_guest_faults,pbmt_guest_ff_errors);
                if (pbmt_guest_cbo_active || pbmt_guest_cbo_seen !== {144{1'b1}} ||
                    pbmt_guest_cbo_priv !== 2'b11 || pbmt_guest_cbo_cbie !== 2'b11)
                    $fatal(1,"PBMT guest CBO matrix incomplete: seen=%h VS/VU=%b CBIE=%b",
                        pbmt_guest_cbo_seen,pbmt_guest_cbo_priv,pbmt_guest_cbo_cbie);
                $display("[pbmt_guest_check] PASS pairs=9 scalar/vector R/W + IFU faults=4 FF-prefix=2");
                $display("[pbmt_guest_check] CBO PASS pairs=9 forms=4 allowed=36 denied=108, exact block/no-side-effects");
            end
        end
    end
endtask

always @(posedge clk) begin
    if (rst) begin
        pbmt_scalar_first=0; pbmt_scalar_second=0;
        pbmt_scalar_attr0=0; pbmt_scalar_attr1=0;
        pbmt_if_xlate=0; pbmt_if_attr=0; pbmt_if_active=0;
        pbmt_if_prev_ar=0; pbmt_fetch_safe_prev=0;
        pbmt_q_rd=0; pbmt_q_wr=0; pbmt_q_count=0; pbmt_active=0;
        pbmt_read_pending=0; pbmt_write_pending=0; pbmt_write_data=0;
`ifdef KARU_EN_V
        pbmt_page_valid=0; pbmt_page_replace=0;
`endif
    end else if (pbmt_check_mode != 0) begin
        // Translation-to-client propagation, including different attributes
        // on the two pages of a scalar split access.
        if (cpu.lsu_walk1_done) begin
            pbmt_scalar_first=cpu.dmmu_pbmt;
            pbmt_scalar_second=cpu.dmmu_pbmt;
        end
        if (cpu.lsu_walk2_done) pbmt_scalar_second=cpu.dmmu_pbmt;
        if (cpu.lsu_req_pa) begin
            pbmt_scalar_attr0=cpu.lsu_bare ? 0 : pbmt_scalar_first;
            pbmt_scalar_attr1=cpu.lsu_bare ? 0 : pbmt_scalar_second;
            pbmt_scalar_pa0=cpu.lsu_pa_w[31:0]; pbmt_scalar_pa1=cpu.lsu_addr2[31:0];
            pbmt_scalar_io_size=cpu.lsu.is_cboz_in ? 3'd3 : {1'b0,cpu.lsu_size};
            if (cpu.lsu_pbmt !== pbmt_scalar_attr0 || cpu.lsu_pbmt2 !== pbmt_scalar_attr1)
                $fatal(1, "PBMT scalar translation attributes lost cyc=%0d pc=%h bare=%b xpage=%b got=%0d/%0d expected=%0d/%0d",
                    cyc,cpu.ex_pc,cpu.lsu_bare,cpu.lsu_xpage_q,
                    cpu.lsu_pbmt,cpu.lsu_pbmt2,pbmt_scalar_attr0,pbmt_scalar_attr1);
        end

        if (cpu.immu_done && !cpu.immu_fault && !cpu.ifu.xlate_discard && !cpu.ifu_redir)
            pbmt_if_xlate=cpu.immu_pbmt;
        if (cpu.ifu_arvalid && !pbmt_if_prev_ar) begin
            if (cpu.ifu_ar_pbmt !== pbmt_if_xlate)
                $fatal(1, "PBMT IFU translation attribute lost");
            pbmt_if_attr=pbmt_if_xlate; pbmt_if_pa=cpu.ifu_araddr;
            pbmt_if_active=1; pbmt_if_bus_ar=0; pbmt_if_bus_r=0;
            if (pbmt_if_attr == 2 && !pbmt_fetch_safe_prev)
                $fatal(1, "PBMT IO fetch launched before older execution drained");
            if (pbmt_if_attr == 1) pbmt_if_nc=pbmt_if_nc+1;
            if (pbmt_if_attr == 2) pbmt_if_io=pbmt_if_io+1;
        end
        if (pbmt_if_active && pbmt_if_attr != 0) begin
            if (imem_arvalid && imem_arready && !cpu.im_owner_immu) begin
                if (imem_arlen != 0 || imem_arsize != 3 || imem_araddr != pbmt_if_pa)
                    $fatal(1, "PBMT uncached fetch widened/refilled or changed address");
                pbmt_if_bus_ar=pbmt_if_bus_ar+1;
            end
            if (imem_rvalid && imem_rready && !cpu.im_owner_immu) pbmt_if_bus_r=pbmt_if_bus_r+1;
`ifdef KARU_ICACHE
            if (cpu.icache.cdata_we || cpu.icache.ctag_we)
                $fatal(1, "PBMT NC/IO fetch allocated an I-cache line");
`endif
            if (cpu.ifu_rvalid_w && cpu.ifu_rready) begin
                if (pbmt_if_bus_ar != 1 || pbmt_if_bus_r != 1)
                    $fatal(1, "PBMT NC/IO fetch hit cache or duplicated memory access");
                pbmt_if_active=0;
            end
        end
        pbmt_if_prev_ar=cpu.ifu_arvalid;
        pbmt_fetch_safe_prev=cpu.ifu.fetch_safe;

`ifdef KARU_EN_V
        if (cpu.vlsu.req && !cpu.vlsu.busy) begin
            pbmt_page_valid=0; pbmt_page_replace=0;
            pbmt_vbase=cpu.vlsu.base; pbmt_vstride=cpu.vlsu.stride;
            pbmt_vl=cpu.vlsu.vl; pbmt_vstart=cpu.vlsu.vstart;
            pbmt_veew=cpu.vlsu.eew; pbmt_vmask=cpu.vlsu.v0mask;
            pbmt_vmasked=!cpu.vlsu.vm; pbmt_vpelem=cpu.vlsu.pelem;
            pbmt_vindexed=cpu.vlsu.indexed; pbmt_vpmlen=cpu.vlsu.dpmlen;
            pbmt_vvirtual=cpu.vlsu.pm_virtual;
        end
        if (cpu.vxlate_done && !cpu.vxlate_fault) begin
            pbmt_slot=-1;
            for (pbmt_i=0; pbmt_i<16; pbmt_i=pbmt_i+1)
                if (pbmt_page_valid[pbmt_i] && pbmt_page_va[pbmt_i] == cpu.vxlate_va[63:12]) pbmt_slot=pbmt_i;
            if (pbmt_slot < 0) begin
                pbmt_slot=pbmt_page_replace; pbmt_page_replace=(pbmt_page_replace+1)&15;
            end
            pbmt_page_valid[pbmt_slot]=1;
            pbmt_page_va[pbmt_slot]=cpu.vxlate_va[63:12];
            pbmt_page_pa[pbmt_slot]=cpu.vxlate_pa[63:12];
            pbmt_page_type[pbmt_slot]=cpu.dmmu_pbmt;
        end
        if (cpu.vmem_req) begin
            pbmt_slot=-1;
            for (pbmt_i=0; pbmt_i<16; pbmt_i=pbmt_i+1)
                if (pbmt_page_valid[pbmt_i] && pbmt_page_va[pbmt_i] == cpu.vmem_va[63:12]) pbmt_slot=pbmt_i;
            if (pbmt_slot < 0) $fatal(1, "PBMT vector request without observed page translation");
            pbmt_expected_type=pbmt_page_type[pbmt_slot];
            if (cpu.vmem_pbmt !== pbmt_expected_type || cpu.vmem_addr[63:12] != pbmt_page_pa[pbmt_slot])
                $fatal(1, "PBMT vector translation PA/attribute lost");
            pbmt_expected_mask=0;
            if (pbmt_vpelem) begin
                pbmt_elem_raw=pbmt_vbase + (pbmt_vindexed ? cpu.vlsu.idxv :
                    ({32'b0,cpu.vlsu.pe_i} * pbmt_vstride)) +
                    ({60'b0,cpu.vlsu.pe_f} << pbmt_veew);
                pbmt_elem_va=pbmt_mask_pointer(pbmt_elem_raw);
                pbmt_elem_index=cpu.vlsu.pe_i;
                for (pbmt_i=0; pbmt_i<16; pbmt_i=pbmt_i+1) begin
                    pbmt_delta=(cpu.vmem_va + pbmt_i)-pbmt_elem_va;
                    if (pbmt_delta < (64'd1 << pbmt_veew) && pbmt_elem_index >= pbmt_vstart &&
                        {32'b0,pbmt_elem_index} < pbmt_vl &&
                        (!pbmt_vmasked || pbmt_vmask[pbmt_elem_index])) pbmt_expected_mask[pbmt_i]=1;
                end
            end else begin
                pbmt_elem_va=pbmt_mask_pointer(pbmt_vbase);
                for (pbmt_i=0; pbmt_i<16; pbmt_i=pbmt_i+1) begin
                    // Low-word subtraction also handles XLEN/tag wrap at a page boundary.
                    pbmt_delta={32'b0,(cpu.vmem_va[31:0]+32'(pbmt_i)-pbmt_vbase[31:0])};
                    pbmt_elem_index=pbmt_delta[31:0] >> pbmt_veew;
                    if (!pbmt_delta[31] && pbmt_elem_index >= pbmt_vstart &&
                        {32'b0,pbmt_elem_index} < pbmt_vl &&
                        (!pbmt_vmasked || pbmt_vmask[pbmt_elem_index])) pbmt_expected_mask[pbmt_i]=1;
                end
            end
            pbmt_expected_size=(pbmt_elem_va & ((64'd1 << pbmt_veew)-1)) != 0 ? 0 : pbmt_veew;
            if ((cpu.vmem_is_store ? cpu.vmem_wstrb : cpu.vmem_rstrb) !== pbmt_expected_mask ||
                cpu.vmem_size !== pbmt_expected_size || pbmt_expected_mask == 0)
                $fatal(1, "PBMT vector active-byte/element-size geometry mismatch");
            if (pbmt_q_count == 4) $fatal(1, "PBMT vector observer request FIFO overflow");
            pbmt_q_type[pbmt_q_wr]=pbmt_expected_type; pbmt_q_pa[pbmt_q_wr]=cpu.vmem_addr[31:0];
            pbmt_q_va[pbmt_q_wr]=cpu.vmem_va; pbmt_q_mask[pbmt_q_wr]=pbmt_expected_mask;
            pbmt_q_size[pbmt_q_wr]=pbmt_expected_size; pbmt_q_store[pbmt_q_wr]=cpu.vmem_is_store;
            pbmt_q_wr=(pbmt_q_wr+1)&3; pbmt_q_count=pbmt_q_count+1;
        end
`endif

`ifdef KARU_EN_MEM
        // These checks run before capture below: the RTL request registers
        // still name the preceding operation until the edge's NBA updates.
        if (pbmt_active && cpu.dmem_l1.state != 0 && pbmt_active_type != 0) begin
            if (cpu.dmem_l1.req_pbmt !== pbmt_active_type || !cpu.dmem_l1.req_uncacheable ||
                cpu.dmem_l1.req_posted || cpu.dmem_l1.line_data_we)
                $fatal(1, "PBMT attributed L1 operation lost type, posted, or wrote cache");
        end
        if (pbmt_active && pbmt_active_type != 0) begin
            if (dmem_arvalid && dmem_arready && !cpu.rd_owner_dmmu) begin
                if (pbmt_read_pending || pbmt_write_pending || dmem_arlen != 0)
                    $fatal(1, "PBMT uncached read duplicated, reordered, or refilled");
                if (pbmt_active_vector && pbmt_active_type == 2) begin
                    pbmt_next_transfer;
                    if (dmem_araddr != ({pbmt_active_pa[31:4],4'b0}+32'(pbmt_off)) ||
                        dmem_arsize != 3'(pbmt_size)) $fatal(1, "PBMT IO read address/size differs from active element");
                    pbmt_seen_mask=pbmt_seen_mask|pbmt_transfer_mask;
                    pbmt_io_bytes=pbmt_io_bytes+pbmt_bytes;
                    pbmt_last_io_va={pbmt_active_va[63:4],4'b0}+64'(pbmt_off);
                end else if (pbmt_active_vector) begin
                    if (dmem_araddr != ({pbmt_active_pa[31:4],4'b0}+32'(pbmt_ar_count*8)) || dmem_arsize != 3)
                        $fatal(1,"PBMT NC vector read repeated or changed granule beat");
                end else if (!pbmt_active_vector && (dmem_araddr != pbmt_active_pa || dmem_arsize != pbmt_active_size))
                    $fatal(1, "PBMT scalar uncached read address/size changed");
                pbmt_read_pending=1; pbmt_ar_count=pbmt_ar_count+1;
            end
            if (dmem_rvalid && dmem_rready && !cpu.rd_owner_dmmu) begin
                if (!pbmt_read_pending || !dmem_rlast) $fatal(1, "PBMT unexpected read response/burst");
                pbmt_read_pending=0; pbmt_r_count=pbmt_r_count+1;
                if (dmem_rresp[1]) pbmt_error_seen=1;
            end
            if (dmem_awvalid && dmem_awready && cpu.wr_owner == 0) begin
                if (pbmt_read_pending || pbmt_write_pending || dmem_awlen != 0)
                    $fatal(1, "PBMT uncached write duplicated, posted, or burst");
                if (pbmt_active_vector && pbmt_active_type == 2) begin
                    pbmt_next_transfer;
                    if (dmem_awaddr != ({pbmt_active_pa[31:4],4'b0}+32'(pbmt_off)) ||
                        dmem_awsize != 3'(pbmt_size)) $fatal(1, "PBMT IO write address/size differs from active element");
                    pbmt_seen_mask=pbmt_seen_mask|pbmt_transfer_mask;
                    pbmt_io_bytes=pbmt_io_bytes+pbmt_bytes;
                    pbmt_last_io_va={pbmt_active_va[63:4],4'b0}+64'(pbmt_off);
                end else if (pbmt_active_vector) begin
                    pbmt_off=(pbmt_aw_count != 0 || pbmt_active_mask[7:0] == 0) ? 8 : 0;
                    pbmt_expected_wstrb=pbmt_off == 0 ? pbmt_active_mask[7:0] : pbmt_active_mask[15:8];
                    if (dmem_awaddr != ({pbmt_active_pa[31:4],4'b0}+32'(pbmt_off)) || dmem_awsize != 3)
                        $fatal(1,"PBMT NC vector write repeated or changed active half");
                end else if (!pbmt_active_vector && (dmem_awaddr != pbmt_active_pa || dmem_awsize != pbmt_active_size))
                    $fatal(1, "PBMT scalar uncached write address/size changed");
                if (!pbmt_active_vector && pbmt_active_type == 2)
                    pbmt_expected_wstrb=((8'h01 << (1 << pbmt_active_size))-1) << pbmt_active_pa[2:0];
                pbmt_write_pending=1; pbmt_write_data=0; pbmt_aw_count=pbmt_aw_count+1;
            end
            if (dmem_wvalid && dmem_wready && cpu.wr_owner == 0) begin
                // The HTIF slave accepts W only with or after its AW.
                if (!pbmt_write_pending || pbmt_write_data || !dmem_wlast)
                    $fatal(1, "PBMT extra/missing-last write data");
                if ((pbmt_active_vector || pbmt_active_type == 2) && dmem_wstrb !== pbmt_expected_wstrb)
                    $fatal(1, "PBMT NC/IO write touches inactive/duplicate bytes");
                pbmt_write_data=1; pbmt_w_count=pbmt_w_count+1;
            end
            if (dmem_bvalid && dmem_bready && cpu.wr_owner == 0) begin
                if (!pbmt_write_pending || !pbmt_write_data) $fatal(1, "PBMT B before accepted AW/W");
                pbmt_write_pending=0; pbmt_b_count=pbmt_b_count+1;
                if (dmem_bresp[1]) pbmt_error_seen=1;
            end
            if ((pbmt_active_vector && cpu.vmem_done) ||
                (!pbmt_active_vector && (cpu.km_s_rvalid || cpu.km_s_bvalid))) begin
                if (pbmt_read_pending || pbmt_write_pending ||
                    (pbmt_active_store ? pbmt_b_count == 0 : pbmt_r_count == 0))
                    $fatal(1, "PBMT NC/IO completion without external response (cache hit/posting)");
                if (pbmt_active_vector && pbmt_active_type == 2) begin
                    if (!pbmt_error_seen && pbmt_seen_mask !== pbmt_active_mask)
                        $fatal(1, "PBMT IO completion omitted active bytes");
                    if (pbmt_error_seen && cpu.vmem_fault_va != pbmt_last_io_va)
                        $fatal(1, "PBMT IO bus fault lost exact constituent address");
                end else if (!pbmt_error_seen) begin
                    pbmt_bytes=pbmt_active_vector ? (pbmt_active_store ?
                        (integer'(|pbmt_active_mask[7:0])+integer'(|pbmt_active_mask[15:8])) : 2) : 1;
                    if (pbmt_active_store ?
                        (pbmt_aw_count != pbmt_bytes || pbmt_w_count != pbmt_bytes || pbmt_b_count != pbmt_bytes) :
                        (pbmt_ar_count != pbmt_bytes || pbmt_r_count != pbmt_bytes))
                        $fatal(1, "PBMT uncached completion has wrong transfer count");
                end
                pbmt_active=0;
            end
        end

        pbmt_capture=0;
        if (cpu.dmem_l1.state == 0) begin
            if (cpu.dmem_l1.vq_valid ||
                (!cpu.lsu_arvalid && !(cpu.lsu_awvalid && cpu.lsu_wvalid) && cpu.vmem_req)) begin
                if (pbmt_q_count == 0) $fatal(1, "PBMT vector capture without request");
                pbmt_active_type=pbmt_q_type[pbmt_q_rd]; pbmt_active_pa=pbmt_q_pa[pbmt_q_rd];
                pbmt_active_va=pbmt_q_va[pbmt_q_rd]; pbmt_active_mask=pbmt_q_mask[pbmt_q_rd];
                pbmt_active_size={1'b0,pbmt_q_size[pbmt_q_rd]}; pbmt_active_store=pbmt_q_store[pbmt_q_rd];
                pbmt_active_vector=1; pbmt_q_rd=(pbmt_q_rd+1)&3; pbmt_q_count=pbmt_q_count-1;
                pbmt_capture=1;
            end else if (cpu.lsu_arvalid || (cpu.lsu_awvalid && cpu.lsu_wvalid)) begin
                pbmt_active_store=!cpu.lsu_arvalid; pbmt_active_vector=0;
                pbmt_active_pa=pbmt_active_store ? cpu.lsu_awaddr : cpu.lsu_araddr;
                // AR2/AWW2 identify the second constituent even when two VA
                // pages alias the same PA page with different attributes.
                pbmt_active_type=(cpu.lsu.state == 4'd3 || cpu.lsu.state == 4'd7)
                    ? pbmt_scalar_attr1 : pbmt_scalar_attr0;
                if ((pbmt_active_store ? cpu.lsu_aw_pbmt : cpu.lsu_ar_pbmt) !== pbmt_active_type)
                    $fatal(1, "PBMT scalar AXI attribute lost");
                pbmt_active_size=pbmt_active_store ? cpu.lsu_awsize : cpu.lsu_arsize;
                if (pbmt_active_type == 2 && pbmt_active_size != pbmt_scalar_io_size)
                    $fatal(1, "PBMT scalar IO changed architectural access width");
                pbmt_capture=1;
            end
        end
        if (pbmt_capture) begin
            pbmt_active=1; pbmt_seen_mask=0; pbmt_error_seen=0;
            pbmt_read_pending=0; pbmt_write_pending=0; pbmt_write_data=0;
            pbmt_ar_count=0; pbmt_r_count=0; pbmt_aw_count=0; pbmt_w_count=0; pbmt_b_count=0;
            if (pbmt_active_type == 1) pbmt_nc_requests=pbmt_nc_requests+1;
            if (pbmt_active_type == 2) pbmt_io_requests=pbmt_io_requests+1;
            if (pbmt_active_vector && pbmt_active_type != 0) pbmt_vector_requests=pbmt_vector_requests+1;
        end
        if (cpu.vmem_fault) begin pbmt_q_count=0; pbmt_q_rd=pbmt_q_wr; end
`else
        $fatal(1, "pbmt_check requires KARU_EN_MEM");
`endif
    end
end
