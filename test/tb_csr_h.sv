// SPDX-License-Identifier: BSD-3-Clause
// H CSR checkpoint: architectural ports only, no hierarchical forcing.
`include "karu_ext.vh"
`include "karu_uop_defs.vh"

module tb_csr_h;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, op_req=0, trap_req=0, mret_req=0, sret_req=0;
    reg [11:0] op_addr=0;
    reg [4:0] op_sub=`CSR_RS, op_rs1=0;
    reg [63:0] op_src=0, trap_epc=0, trap_cause=0, trap_tval=0;
    reg trap_gva=0, trap_gpa_valid=0;
    reg [63:0] trap_gpa=0, trap_tinst=0, time_in=0;
    reg irq_timer=0, irq_software=0, irq_external_m=0, irq_external_s=0;
    reg fp_dirty=0, v_dirty=0, retire=0;
    reg [31:0] hpm_events=0;
    wire [63:0] op_rd_v, trap_vec, irq_cause, ret_pc, satp_o, vsatp_o, hgatp_o;
    wire csr_illegal, irq_pending, virt_o, data_virt_o;
    wire [1:0] csr_exc_o, trap_target_o, irq_target_o, priv_o, data_priv_o;
    wire [1:0] status_fs_o, status_vs_o, vsstatus_fs_o, vsstatus_vs_o;
    wire status_sum_o, status_mxr_o, vsstatus_sum_o, vsstatus_mxr_o;
    wire pbmte_o, henvcfg_pbmte_o;
    wire hstatus_vtvm_o, hstatus_vtw_o, hstatus_vtsr_o, hstatus_hu_o, hstatus_spvp_o;
    wire [1:0] menvcfg_pmm_o, henvcfg_pmm_o, senvcfg_pmm_o, hstatus_hupmm_o;
    wire [1:0] cbo_zero_exc_o, cbo_cf_exc_o, cbo_inval_exc_o;
    wire [5:0] dpmlen_o;
    integer checks=0, n, m, h, s, p, bitno, counter_no, filter_bits, inhibit_bits;
    integer clock_ticks=0, csr_sample_tick=0;
    always @(posedge clk) clock_ticks<=clock_ticks+1;
    reg [63:0] value, before_value, pattern;
    localparam [63:0] MPV=64'h80_0000_0000;
    localparam [63:0] CTX=64'h2200; // host/guest FS=Initial, VS=Initial
    localparam [63:0] EPC_MASK=
`ifdef KARU_EN_C
        ~64'h1;
`else
        ~64'h3;
`endif
    localparam [63:0] COUNTERS=
`ifdef KARU_EN_HPM
        64'hffff_ffff;
`else
        64'h7;
`endif

    karu_csr dut (
        .clk(clk),.rst(rst),.op_req(op_req),.op_addr(op_addr),.op_src(op_src),
        .op_sub(op_sub),.op_rs1(op_rs1),.op_rd_v(op_rd_v),.csr_illegal(csr_illegal),
        .csr_exc_o(csr_exc_o),.trap_req(trap_req),.trap_epc(trap_epc),
        .trap_cause(trap_cause),.trap_tval(trap_tval),.trap_gva(trap_gva),
        .trap_gpa_valid(trap_gpa_valid),.trap_gpa(trap_gpa),.trap_tinst(trap_tinst),
        .trap_vec(trap_vec),.trap_target_o(trap_target_o),.irq_timer(irq_timer),
        .irq_software(irq_software),.irq_external_m(irq_external_m),
        .irq_external_s(irq_external_s),.irq_pending(irq_pending),
        .irq_cause(irq_cause),.irq_target_o(irq_target_o),.mret_req(mret_req),
        .sret_req(sret_req),.ret_pc(ret_pc),.priv_o(priv_o),.data_priv_o(data_priv_o),
        .virt_o(virt_o),.data_virt_o(data_virt_o),.satp_o(satp_o),
        .vsatp_o(vsatp_o),.hgatp_o(hgatp_o),.status_sum_o(status_sum_o),
        .status_mxr_o(status_mxr_o),.vsstatus_sum_o(vsstatus_sum_o),
        .vsstatus_mxr_o(vsstatus_mxr_o),.pbmte_o(pbmte_o),.henvcfg_pbmte_o(henvcfg_pbmte_o),
        .status_fs_o(status_fs_o),.status_vs_o(status_vs_o),
        .vsstatus_fs_o(vsstatus_fs_o),.vsstatus_vs_o(vsstatus_vs_o),
        .hstatus_vtvm_o(hstatus_vtvm_o),.hstatus_vtw_o(hstatus_vtw_o),
        .hstatus_vtsr_o(hstatus_vtsr_o),.hstatus_hu_o(hstatus_hu_o),
        .hstatus_spvp_o(hstatus_spvp_o),.menvcfg_pmm_o(menvcfg_pmm_o),
        .henvcfg_pmm_o(henvcfg_pmm_o),.senvcfg_pmm_o(senvcfg_pmm_o),
        .hstatus_hupmm_o(hstatus_hupmm_o),.dpmlen_o(dpmlen_o),
        .cbo_zero_exc_o(cbo_zero_exc_o),.cbo_cf_exc_o(cbo_cf_exc_o),
        .cbo_inval_exc_o(cbo_inval_exc_o),.fflags_set(1'b0),.fflags_in(5'b0),
        .fp_dirty(fp_dirty),.v_dirty(v_dirty),.retire(retire),.cyc_in(64'b0),
        .time_in(time_in),.hpm_events(hpm_events),.vset_req(1'b0),.vset_vtype(64'b0),
        .vset_vl(64'b0),.v_retire(1'b0),.v_fault_start_we(1'b0),
        .v_fault_start(64'b0),.vl_trim_req(1'b0),.vl_trim_val(64'b0),.vxsat_set(1'b0)
    );

    task automatic eq(input [63:0] got, want, input string label_text);
        begin
            checks++;
            if(got !== want) $fatal(1,"%s got=%016h expected=%016h",label_text,got,want);
        end
    endtask
    task automatic access_csr(input [11:0] a, input [4:0] op, input [63:0] v,
        input [1:0] expected, output [63:0] old);
        begin
            @(negedge clk); op_req=1;op_addr=a;op_sub=op;op_src=v;
            op_rs1=(op==`CSR_RW || v!=0) ? 5'd1 : 5'd0;
            #1; eq(csr_exc_o,expected,$sformatf("CSR %03h class",a));
            eq(csr_illegal,expected==1,"illegal alias");old=op_rd_v;csr_sample_tick=clock_ticks;
            @(posedge clk);#1;op_req=0;
        end
    endtask
    task automatic wr(input [11:0] a,input [63:0] v);
        reg [63:0] old;begin access_csr(a,`CSR_RW,v,0,old);end
    endtask
    task automatic rd(input [11:0] a,input [63:0] want,input [63:0] mask);
        reg [63:0] old;begin access_csr(a,`CSR_RS,0,0,old);eq(old&mask,want&mask,$sformatf("CSR %03h value",a));end
    endtask
    task automatic deny(input [11:0] a,input [1:0] kind,input do_write);
        reg [63:0] old;begin access_csr(a,do_write?`CSR_RW:`CSR_RS,do_write?~64'b0:0,kind,old);end
    endtask
    task automatic xret(input supervisor);
        begin
            @(negedge clk);sret_req=supervisor;mret_req=!supervisor;
            @(posedge clk);#1;sret_req=0;mret_req=0;
        end
    endtask
    task automatic enter(input [1:0] target,input guest);
        begin
            wr(12'h300,CTX | (64'(target)<<11) | (guest?MPV:0));
            xret(0);eq(priv_o,target,"entry privilege");eq(virt_o,guest,"entry V");
        end
    endtask
    task automatic trap(input [63:0] cause,input [1:0] target,input [63:0] vector);
        begin
            @(negedge clk);trap_req=1;trap_cause=cause;trap_epc=64'habcdef03;
            trap_tval=64'hfedcba9876543210;
            #1;eq(trap_target_o,target,"trap target");eq(trap_vec,vector,"trap vector");
            @(posedge clk);#1;trap_req=0;
            eq(priv_o,target==0?3:1,"trap privilege");eq(virt_o,target==2,"trap V");
        end
    endtask
    task automatic setup;
        integer k;
        begin
            @(negedge clk);rst=1;op_req=0;trap_req=0;mret_req=0;sret_req=0;
            fp_dirty=0;v_dirty=0;retire=0;time_in=0;hpm_events=0;
            irq_timer=0;irq_software=0;irq_external_m=0;irq_external_s=0;
            trap_gva=0;trap_gpa_valid=0;trap_gpa=0;trap_tinst=0;
            repeat(2) @(posedge clk);@(negedge clk);rst=0;
            #1;eq(virt_o,0,"reset V");eq(data_virt_o,0,"reset data V");
            eq(vsatp_o,0,"reset VS root");eq(hgatp_o,0,"reset G root");
            wr(12'h305,64'h1000);wr(12'h105,64'h2000);wr(12'h205,64'h3000);
            wr(12'h306,COUNTERS);wr(12'h606,COUNTERS);wr(12'h106,COUNTERS);
            wr(12'h30c,64'hc000_0000_0000_0000);
            for(k=1;k<4;k++) wr(12'h30c+12'(k),64'h8000_0000_0000_0000);
            for(k=0;k<4;k++) wr(12'h60c+12'(k),~64'b0);
            wr(12'h200,CTX);
        end
    endtask

    // Mode order matches the standardized filter fields: M, HS, U, VS, VU.
    task automatic counter_mode(input integer mode);
        begin
            if(mode!=0) enter((mode==1 || mode==3)?2'd1:2'd0,mode>=3);
        end
    endtask
    task automatic pulse_events(input [31:0] events,input retire_pulse,input integer count);
        begin
            @(negedge clk);hpm_events=events;retire=retire_pulse;
            repeat(count) @(posedge clk);
            #1;hpm_events=0;retire=0;
        end
    endtask

`ifdef KARU_EN_SMCNTRPMF
    task automatic fixed_filter(input integer mode,input [4:0] cycle_filter,
                                 input [4:0] instret_filter,input [63:0] inhibit);
        reg [63:0] start_cycle,end_cycle,start_ir,end_ir;
        integer start_tick,end_tick;
        begin
            setup();wr(12'h321,64'(cycle_filter)<<58);wr(12'h322,64'(instret_filter)<<58);
            wr(12'h320,inhibit);counter_mode(mode);
            access_csr(12'hc00,`CSR_RS,0,0,start_cycle);start_tick=csr_sample_tick;
            access_csr(12'hc02,`CSR_RS,0,0,start_ir);
            pulse_events(0,1,7);
            access_csr(12'hc02,`CSR_RS,0,0,end_ir);
            access_csr(12'hc00,`CSR_RS,0,0,end_cycle);end_tick=csr_sample_tick;
            eq(end_ir-start_ir,(instret_filter[4-mode] || inhibit[2])?0:7,
                $sformatf("instret mode=%0d filter=%b inhibit=%h",mode,instret_filter,inhibit));
            eq(end_cycle-start_cycle,(cycle_filter[4-mode] || inhibit[0])?0:64'(end_tick-start_tick),
                $sformatf("cycle mode=%0d filter=%b inhibit=%h",mode,cycle_filter,inhibit));
        end
    endtask
`endif
`ifdef KARU_EN_SSCOFPMF
    task automatic hpm_overflow(input integer mode,input delegate_hs,
                                input integer block_kind,input old_of);
        reg [63:0] cfg;
        reg new_request,of_after;
        begin
            setup();cfg=64'h5|(old_of?64'h8000_0000_0000_0000:0)|
                (block_kind==1?(64'b1<<(62-mode)):0);
            wr(12'h323,cfg);wr(12'hb03,~64'b0);
            wr(12'h320,block_kind==2?64'h8:0);
            wr(12'h304,64'h2000);wr(12'h303,delegate_hs?64'h2000:0);
            rd(12'h344,0,64'h2000); // neither preload nor OF writes request an interrupt
            counter_mode(mode);
            if(mode==0) wr(12'h300,CTX|8);
            if(mode==1) wr(12'h100,CTX|2);
            pulse_events(32'h20,0,1);
            new_request=(block_kind==0)&&!old_of;
            of_after=old_of||(block_kind==0);
            rd(12'hc03,block_kind==0?0:~64'b0,~64'b0);
            eq(irq_pending,new_request&&(!delegate_hs||mode!=0),"overflow interrupt eligibility");
            if(new_request&&(!delegate_hs||mode!=0)) begin
                eq(irq_cause,64'h8000_0000_0000_000d,"overflow physical cause");
                eq(irq_target_o,delegate_hs?1:0,"overflow M/HS target");
            end
            if(mode==2||mode==4) deny(12'hda0,mode==4?2:1,0);
            else rd(12'hda0,of_after?8:0,~64'b0);
            trap(2,0,64'h1000);
            rd(12'h323,cfg|(of_after?64'h8000_0000_0000_0000:0),~64'b0);
            rd(12'h344,new_request?64'h2000:0,64'h2000);
            rd(12'hda0,of_after?8:0,~64'b0);
            // Inhibition freezes counting; it does not acknowledge overflow.
            wr(12'h320,8);pulse_events(32'h20,0,3);
            rd(12'hb03,block_kind==0?0:~64'b0,~64'b0);
            rd(12'h344,new_request?64'h2000:0,64'h2000);
            rd(12'hda0,of_after?8:0,~64'b0);
        end
    endtask

    task automatic wr_with_event(input [11:0] a,input [63:0] v,input [31:0] events);
        begin
            @(negedge clk);op_req=1;op_addr=a;op_sub=`CSR_RW;op_src=v;op_rs1=1;hpm_events=events;
            #1;eq(csr_exc_o,0,"concurrent event CSR class");
            @(posedge clk);#1;op_req=0;hpm_events=0;
        end
    endtask
`endif

`ifdef KARU_EN_HPM
    task automatic hpm_filter(input integer mode,input [4:0] filter,input [63:0] inhibit);
        integer c;
        reg [4:0] bits_for_counter;
        begin
            setup();wr(12'h320,inhibit);
            for(c=3;c<32;c++) begin
                bits_for_counter=c[0]?filter:~filter;
                wr(12'h320+12'(c),
`ifdef KARU_EN_SSCOFPMF
                    (64'(bits_for_counter)<<58) |
`endif
                    64'(c));
            end
            counter_mode(mode);
            // All event IDs are distinct. Odd selectors get five pulses,
            // even selectors three; none depend on instruction retirement.
            pulse_events(32'hffff_fff8,0,3);pulse_events(32'haaaa_aaa8,0,2);
            for(c=3;c<32;c++) begin
                bits_for_counter=c[0]?filter:~filter;
                rd(12'hc00+12'(c),(inhibit[c]
`ifdef KARU_EN_SSCOFPMF
                    || bits_for_counter[4-mode]
`endif
                    )?0:(c[0]?5:3),~64'b0);
            end
        end
    endtask
`endif
    task automatic walkmask(input [11:0] a,input [63:0] mask);
        integer k;reg [63:0] pat;
        begin
            for(k=0;k<64;k++) begin
                pat=64'b1<<k;wr(a,pat);rd(a,pat&mask,~64'b0);
                wr(a,~pat);rd(a,(~pat)&mask,~64'b0);
            end
            wr(a,0);
        end
    endtask

    // Unsupported MODE writes preserve the complete old root/identifier,
    // not just MODE. Exercise every encoding through the architectural port.
    task automatic root_modes(input [11:0] a,input [63:0] mask);
        integer mode;
        reg [63:0] candidate, expected_root;
        begin
            expected_root=64'h8123_4567_89ab_cdef & mask;
            wr(a,expected_root);
            for(mode=0;mode<16;mode++) begin
                candidate=(64'(mode)<<60) | (64'h0fed_cba9_8765_4321 ^ (64'(mode)<<24));
                wr(a,candidate);
                if(mode==0 || mode==8) expected_root=candidate & mask;
                rd(a,expected_root,~64'b0);
            end
        end
    endtask

    initial begin
`ifndef KARU_EN_H
        $fatal(1,"tb_csr_h requires KARU_H");
`endif
        setup();
        rd(12'h301,64'h80,64'h80);
        walkmask(12'h602,64'hcb1ff);
`ifdef KARU_EN_SSCOFPMF
        wr(12'h303,64'h2000);
        walkmask(12'h603,64'h2444);
`else
        walkmask(12'h603,64'h444);
`endif
        // SGEIE is writable through both architectural aliases even though
        // GEILEN=0 keeps pending permanently clear and cannot raise an IRQ.
        setup();wr(12'h304,64'h1000);rd(12'h604,64'h1000,~64'b0);
        wr(12'h604,0);rd(12'h304,0,64'h1000);
        wr(12'h604,64'h1000);rd(12'h304,64'h1000,64'h1000);
        wr(12'h344,64'h1000);rd(12'h644,0,64'h1000);
        rd(12'h607,0,~64'b0);rd(12'he12,0,~64'b0);eq(irq_pending,0,"GEILEN=0 no SGEI");
        walkmask(12'h606,COUNTERS);walkmask(12'h607,0);
        rd(12'he12,0,~64'b0);deny(12'he12,1,1);
        wr(12'h303,0);rd(12'h303,64'h1444,~64'b0);
        wr(12'h303,~64'b0);rd(12'h303,64'h1444,64'h1444);
        wr(12'h600,~64'b0);rd(12'h600,64'h0003_0002_0070_03c0,~64'b0);
        wr(12'h600,64'h0001_0000_0000_0000);eq(hstatus_hupmm_o,0,"reserved HUPMM");
        wr(12'h180,64'h8001_0000_0008_0000);
        wr(12'h280,64'h0123_0000_1234_5678);eq(vsatp_o,64'h0123_0000_1234_5678,"VS Bare storage");
        wr(12'h280,64'h8fff_ffff_ffff_ffff);eq(vsatp_o,64'h8fff_ffff_ffff_ffff,"VS Sv39 storage");
        wr(12'h280,64'h9abc_0000_0000_0000);eq(vsatp_o,64'h8fff_ffff_ffff_ffff,"reject unsupported VS MODE");
        wr(12'h680,64'h0fff_ffff_ffff_ffff);eq(hgatp_o,64'h03ff_ffff_ffff_fffc,"G Bare WARL storage");
        wr(12'h680,64'h8fff_ffff_ffff_ffff);eq(hgatp_o,64'h83ff_ffff_ffff_fffc,"G Sv39x4 geometry and VMID");
        wr(12'h680,64'h9123_4567_89ab_cdef);eq(hgatp_o,64'h83ff_ffff_ffff_fffc,"reject unsupported G MODE");
        eq(satp_o,64'h8001_0000_0008_0000,"host root independent");

        setup();wr(12'h180,64'h8001_0000_0008_0000);
        root_modes(12'h280,~64'b0);
        root_modes(12'h680,64'hf3ff_ffff_ffff_fffc);
        eq(satp_o,64'h8001_0000_0008_0000,"M guest-root writes preserve host root");
        setup();wr(12'h180,64'h8001_0000_0008_0000);enter(1,0);
        root_modes(12'h280,~64'b0);
        root_modes(12'h680,64'hf3ff_ffff_ffff_fffc);
        eq(satp_o,64'h8001_0000_0008_0000,"HS guest-root writes preserve host root");
        setup();wr(12'h180,64'h8001_0000_0008_0000);
        wr(12'h680,64'h8123_4567_89ab_cdec);enter(1,1);
        root_modes(12'h180,~64'b0);
        eq(satp_o,64'h8001_0000_0008_0000,"VS satp alias preserves host root");
        eq(hgatp_o,64'h8123_4567_89ab_cdec,"VS satp alias preserves G root");

        setup();wr(12'h302,64'h400);wr(12'h140,64'h1111);wr(12'h240,64'h2222);
        enter(1,1);rd(12'h140,64'h2222,~64'b0);wr(12'h140,64'h3333);
        deny(12'h240,2,1);deny(12'h600,2,0);deny(12'h300,1,0);
        deny(12'h777,1,0);deny(12'h615,1,0);deny(12'he12,1,1);
        trap_gva=1;trap_gpa_valid=1;trap_gpa=64'h1234_5678_9abc_def3;trap_tinst=64'h3000;
        trap(10,1,64'h2000);rd(12'h140,64'h1111,~64'b0);rd(12'h240,64'h3333,~64'b0);
        rd(12'h600,64'h1c0,64'h1c0);rd(12'h643,64'h048d_159e_26af_37bc,~64'b0);
        rd(12'h64a,64'h3000,~64'b0);rd(12'h141,64'habcdef03&EPC_MASK,~64'b0);
        @(negedge clk);sret_req=1;#1;eq(ret_pc,64'habcdef03&EPC_MASK,"HS SRET PC");
        @(posedge clk);#1;sret_req=0;eq(virt_o,1,"HS return guest");
        rd(12'h140,64'h3333,~64'b0);
        trap_gva=0;trap_gpa_valid=0;trap_tinst=0;trap(10,1,64'h2000);
        rd(12'h643,0,~64'b0);rd(12'h64a,0,~64'b0);rd(12'h600,0,64'h40);

        setup();wr(12'h302,64'h100);wr(12'h602,64'h100);enter(0,1);
        deny(12'h100,2,0);trap(8,2,64'h3000);
        rd(12'h142,8,~64'b0);rd(12'h143,64'hfedcba9876543210,~64'b0);
        rd(12'h100,0,64'h100);xret(1);eq(priv_o,0,"VS SRET U");eq(virt_o,1,"VS SRET keeps V");
        trap_gva=1;trap_gpa_valid=1;trap_gpa=64'hffff_ffff_ffff_ffff;trap_tinst=64'h3000;
        trap(2,0,64'h1000);rd(12'h300,MPV|64'h40_0000_0000,MPV|64'h40_0000_0000|64'h1800);
        rd(12'h34b,64'h3fff_ffff_ffff_ffff,~64'b0);rd(12'h34a,64'h3000,~64'b0);
        xret(0);eq(priv_o,0,"MRET VU");eq(virt_o,1,"MRET restores V");

        // Every counter alias in every mode and enable combination. Machine
        // denial and read-only writes are illegal, ahead of guest denial;
        // an absent HPM CSR remains illegal even if every enable is set.
        for(p=0;p<5;p++) for(m=0;m<2;m++) for(h=0;h<2;h++) for(s=0;s<2;s++) begin
            setup();wr(12'h306,m?COUNTERS:0);wr(12'h606,h?COUNTERS:0);wr(12'h106,s?COUNTERS:0);
            wr(12'h320,COUNTERS);counter_mode(p);
            for(counter_no=0;counter_no<32;counter_no++) begin
                n=!COUNTERS[counter_no]?1:p==0?0:!m?1:(p==2&&!s)?1:
                    (p>=3&&(!h||(p==4&&!s)))?2:0;
                access_csr(12'hc00+12'(counter_no),`CSR_RS,0,2'(n),value);
                deny(12'hc00+12'(counter_no),1,1);
            end
        end
        // Machine-state gates win; each hstateen SE independently traps guest access.
        for(n=0;n<4;n++) begin
            setup();wr(12'h60c+12'(n),0);enter(1,1);deny(12'h10c+12'(n),2,0);
            setup();wr(12'h30c+12'(n),0);enter(1,1);deny(12'h10c+12'(n),1,0);
            setup();enter(1,1);rd(12'h10c+12'(n),0,~64'b0);
        end
        setup();wr(12'h60c,64'h8000_0000_0000_0000);enter(1,1);deny(12'h10a,2,0);
        setup();wr(12'h30c,64'h8000_0000_0000_0000);enter(1,1);deny(12'h10a,1,0);
        setup();wr(12'h60c,~64'b0);wr(12'h30c,0);rd(12'h60c,0,~64'b0);
        wr(12'h60c,0);wr(12'h30c,64'hc000_0000_0000_0000);rd(12'h60c,64'hc000_0000_0000_0000,~64'b0);

        // Every injected IRQ, HS interception / VS delivery and shifted vectors.
        for(n=0;n<3;n++) begin
            bitno=n==0?10:n==1?2:6;pattern=64'b1<<bitno;
            setup();wr(12'h304,pattern);wr(12'h645,pattern);enter(1,1);
            eq(irq_pending,1,"HS interrupt ignores HS SIE while guest");
            eq(irq_target_o,1,"injected IRQ intercepted HS");eq(irq_cause,64'h8000_0000_0000_0000|64'(bitno),"raw IRQ cause");
            trap(64'h8000_0000_0000_0000|64'(bitno),1,64'h2000);
            setup();wr(12'h304,pattern);wr(12'h603,pattern);wr(12'h645,pattern);wr(12'h205,64'h3001);
            enter(1,1);eq(irq_pending,0,"VS SIE masks IRQ");wr(12'h100,CTX|2);
            eq(irq_pending,1,"VS SIE enables IRQ");eq(irq_target_o,2,"VS IRQ target");
            trap(64'h8000_0000_0000_0000|64'(bitno),2,64'h3000+4*64'(bitno-1));
            rd(12'h142,64'h8000_0000_0000_0000|64'(bitno-1),~64'b0);
            setup();wr(12'h304,pattern);wr(12'h603,pattern);wr(12'h645,pattern);enter(0,0);
            eq(irq_pending,0,"VS IRQ disabled in nonvirtual U");
            setup();wr(12'h304,pattern);wr(12'h603,pattern);wr(12'h645,pattern);enter(0,1);
            eq(irq_pending,1,"VS IRQ enabled in VU despite SIE zero");
        end
        setup();wr(12'h603,64'h444);wr(12'h204,64'h222);rd(12'h604,64'h444,~64'b0);
        wr(12'h244,2);rd(12'h645,4,~64'b0);wr(12'h344,0);rd(12'h645,0,~64'b0);
        wr(12'h645,64'h440);wr(12'h644,0);rd(12'h645,64'h440,~64'b0);

        // HS CSR access rank differs from nominal S, and TVM affects only HS.
        setup();wr(12'h300,CTX|64'h100800);xret(0);
        rd(12'h600,64'h0000_0002_0000_0000,~64'b0);
        deny(12'h180,1,0);deny(12'h680,1,0);rd(12'h280,0,~64'b0);
        setup();wr(12'h300,CTX|MPV|64'h100800);xret(0);
        rd(12'h180,0,~64'b0);
        setup();wr(12'h600,64'h100000);enter(1,1);deny(12'h180,2,1);
        trap(2,0,64'h1000);rd(12'h280,0,~64'b0);

        // HS traps preserve SPVP when they did not originate in a guest.
        setup();wr(12'h600,64'h100);wr(12'h302,64'h100);enter(0,0);
        trap(8,1,64'h2000);rd(12'h600,64'h100,64'h1c0);
        // MRET returning to M never restores V, even with MPV set.
        setup();wr(12'h300,MPV|64'h1800);xret(0);
        eq(priv_o,3,"MRET M");eq(virt_o,0,"MRET M ignores MPV");rd(12'h300,0,MPV);

        // Ordinary effective privilege/V and independent host/guest MXR.
        for(p=0;p<3;p++) begin
            setup();n=p==2?3:p;wr(12'h300,MPV|64'h20000|(64'(n)<<11));
            eq(virt_o,0,"MPRV does not change nominal V");eq(data_priv_o,64'(n),"MPRV privilege");
            eq(data_virt_o,n!=3,"MPP=M ignores MPV");
        end
        setup();wr(12'h30a,64'h0000_0002_0000_0000);wr(12'h60a,64'h0000_0003_0000_0000);
        wr(12'h10a,64'h0000_0002_0000_0000);enter(1,1);eq(dpmlen_o,16,"VS uses henvcfg PMM");
        wr(12'h100,CTX|64'h80000);eq(dpmlen_o,0,"guest MXR disables PM");
        setup();wr(12'h30a,64'hc000_0000_0000_0000);wr(12'h60a,64'hc000_0000_0000_0000);
        eq(pbmte_o,1,"host PBMTE");eq(henvcfg_pbmte_o,1,"guest PBMTE");
        wr(12'h30a,0);eq(henvcfg_pbmte_o,0,"machine masks guest PBMTE");

        // CBO denial classes are nominal-context, not MPRV access-context.
        for(p=0;p<2;p++) for(m=0;m<2;m++) for(h=0;h<2;h++) for(s=0;s<2;s++) begin
            setup();wr(12'h30a,m?64'hf0:0);wr(12'h60a,h?64'hf0:0);wr(12'h10a,s?64'hf0:0);
            enter(2'(p),1);n=!m?1:(!h||(!p&&!s))?2:0;
            eq(cbo_zero_exc_o,64'(n),"guest CBO zero class");eq(cbo_cf_exc_o,64'(n),"guest CBO CF class");
            eq(cbo_inval_exc_o,64'(n),"guest CBO inval class");
        end
`ifdef KARU_EN_F
        setup();wr(12'h200,0);enter(1,1);deny(12'h001,1,1);
        eq(status_fs_o,1,"rejected FP CSR leaves host FS");eq(vsstatus_fs_o,0,"rejected FP CSR leaves guest FS");
        trap(2,0,64'h1000);wr(12'h300,CTX);rd(12'h001,0,~64'b0);
        setup();wr(12'h300,MPV|64'h800);xret(0);deny(12'h001,1,1);
        eq(status_fs_o,0,"host Off blocks guest FP CSR");eq(vsstatus_fs_o,1,"blocked FP leaves guest initial");
        setup();enter(1,1);@(negedge clk);fp_dirty=1;@(posedge clk);#1;fp_dirty=0;
        eq(status_fs_o,3,"host FP dirty");eq(vsstatus_fs_o,3,"guest FP dirty");
`endif
`ifdef KARU_EN_V
        setup();wr(12'h200,0);enter(1,1);deny(12'h008,1,1);
        eq(status_vs_o,1,"rejected vector CSR leaves host VS");eq(vsstatus_vs_o,0,"rejected vector CSR leaves guest VS");
        trap(2,0,64'h1000);wr(12'h300,CTX);rd(12'h008,0,~64'b0);
        setup();wr(12'h300,MPV|64'h800);xret(0);deny(12'h008,1,1);
        eq(status_vs_o,0,"host Off blocks guest vector CSR");eq(vsstatus_vs_o,1,"blocked vector leaves guest initial");
        setup();enter(1,1);@(negedge clk);v_dirty=1;@(posedge clk);#1;v_dirty=0;
        eq(status_vs_o,3,"host vector dirty");eq(vsstatus_vs_o,3,"guest vector dirty");
`endif
        // Guest timer: gated comparator, software injection, offset and wrap.
        setup();wr(12'h30a,64'h8000_0000_0000_0000);wr(12'h60a,64'h8000_0000_0000_0000);
        wr(12'h605,20);wr(12'h24d,120);wr(12'h304,64'h40);wr(12'h603,64'h40);
        time_in=100;enter(0,1);repeat(6) @(negedge clk);#1;
        rd(12'hc01,120,~64'b0);eq(irq_pending,1,"virtual timer comparator");eq(irq_cause,64'h8000_0000_0000_0006,"virtual timer cause");
        setup();wr(12'h605,1);time_in=~64'b0;enter(0,1);rd(12'hc01,0,~64'b0);
        setup();enter(1,1);deny(12'h14d,1,0);
        setup();wr(12'h30a,64'h8000_0000_0000_0000);enter(1,1);deny(12'h14d,2,0);
        setup();wr(12'h645,64'h40);wr(12'h304,64'h40);wr(12'h603,64'h40);enter(0,1);
        eq(irq_pending,1,"software VSTIP works with STCE disabled");
        setup();wr(12'h30a,64'h8000_0000_0000_0000);wr(12'h60a,64'h8000_0000_0000_0000);
        wr(12'h606,0);enter(1,1);deny(12'h14d,2,0);
`ifdef KARU_EN_SMCNTRPMF
        // All 32 privilege-filter combinations; opposite fixed-counter
        // settings also prove the two configuration CSRs are independent.
        for(p=0;p<5;p++) for(filter_bits=0;filter_bits<32;filter_bits++)
            fixed_filter(p,5'(filter_bits),~5'(filter_bits),0);
        for(p=0;p<5;p++) for(inhibit_bits=0;inhibit_bits<4;inhibit_bits++)
            fixed_filter(p,0,0,(inhibit_bits[0]?64'h1:0)|(inhibit_bits[1]?64'h4:0));
        setup();walkmask(12'h321,64'h7c00_0000_0000_0000);
        walkmask(12'h322,64'h7c00_0000_0000_0000);

        // xRET retirement belongs to its originating mode, not its target.
        // Synchronous exception entry supplies no retirement pulse.
        for(n=0;n<2;n++) begin
            setup();wr(12'h322,n?64'h4000_0000_0000_0000:64'h0800_0000_0000_0000);
            wr(12'h300,CTX|MPV|64'h800);wr(12'hb02,0);
            @(negedge clk);mret_req=1;retire=1;
            @(posedge clk);#1;mret_req=0;retire=0;
            eq(virt_o,1,"retiring MRET enters VS");rd(12'hc02,n?0:1,~64'b0);
            trap(2,0,64'h1000);rd(12'hb02,n?0:1,~64'b0);

            setup();wr(12'h322,n?64'h0800_0000_0000_0000:64'h0400_0000_0000_0000);
            enter(1,1);
            @(negedge clk);sret_req=1;retire=1;
            @(posedge clk);#1;sret_req=0;retire=0;
            eq(priv_o,0,"retiring VS SRET enters VU");eq(virt_o,1,"VS SRET retains V");
            rd(12'hc02,n?0:1,~64'b0);
        end
        // Counter filtering follows nominal execution, not MPRV/MPV's
        // effective data privilege. A guest-memory access from M counts M.
        for(n=0;n<2;n++) begin
            setup();wr(12'h322,n?64'h4000_0000_0000_0000:64'h0c00_0000_0000_0000);
            wr(12'h300,CTX|MPV|64'h20800);eq(data_virt_o,1,"PMU MPRV guest data context");
            eq(virt_o,0,"PMU retains nominal M context");pulse_events(0,1,5);
            rd(12'hb02,n?0:5,~64'b0);
        end
`endif
`ifdef KARU_EN_HPM
`ifdef KARU_EN_SSCOFPMF
        // Every programmable counter and filter pattern, with interleaved
        // complementary settings to catch accidental sharing of a selector
        // or a privilege filter between counters.
        for(p=0;p<5;p++) for(filter_bits=0;filter_bits<32;filter_bits++)
            hpm_filter(p,5'(filter_bits),0);
`else
        for(p=0;p<5;p++) hpm_filter(p,0,0);
`endif
        for(p=0;p<5;p++) begin
            hpm_filter(p,0,64'haaaa_aaa8);
            hpm_filter(p,0,64'h5555_5550);
`ifdef KARU_EN_SSCOFPMF
            // Reverse the per-counter filters so global inhibition is also
            // exercised while the even-numbered counters can count.
            hpm_filter(p,5'b11111,64'haaaa_aaa8);
            hpm_filter(p,5'b11111,64'h5555_5550);
`endif
        end
`ifdef KARU_EN_SSCOFPMF
        // Programmable counters use nominal execution privilege as well:
        // MPRV/MPV's guest data context must not select VS/VU filters.
        for(n=0;n<2;n++) begin
            setup();wr(12'h323,5|(n?64'h4000_0000_0000_0000:64'h0c00_0000_0000_0000));
            wr(12'h300,CTX|MPV|64'h20800);eq(data_virt_o,1,"HPM MPRV guest data context");
            eq(virt_o,0,"HPM retains nominal M context");pulse_events(32'h20,0,5);
            rd(12'hb03,n?0:5,~64'b0);
        end
        for(p=0;p<5;p++) for(m=0;m<2;m++) for(n=0;n<3;n++) for(h=0;h<2;h++)
            hpm_overflow(p,m!=0,n,h!=0);

        // scountovf masks inaccessible bits instead of trapping. Guest
        // S-mode checks machine AND hypervisor enables, but not scounteren.
        for(p=0;p<4;p++) if(p!=2) for(m=0;m<4;m++) for(h=0;h<4;h++) begin
            setup();wr(12'h323,64'h8000_0000_0000_0005);
            wr(12'h33f,64'h8000_0000_0000_0011);
            wr(12'h306,(m[0]?64'h8:0)|(m[1]?64'h8000_0000:0));
            wr(12'h606,(h[0]?64'h8:0)|(h[1]?64'h8000_0000:0));
            wr(12'h106,0);counter_mode(p);
            pattern=p==0?64'h8000_0008:
                ((m[0]&&(p!=3||h[0]))?64'h8:0)|((m[1]&&(p!=3||h[1]))?64'h8000_0000:0);
            rd(12'hda0,pattern,~64'b0);deny(12'hda0,1,1);
        end

        // Guest overflow is intercepted by HS (LCOFI is not delegated to
        // VS in this implementation). Acknowledging pending leaves OF set;
        // later wrapping while OF=1 keeps counting but cannot re-request.
        for(p=3;p<5;p++) begin
            setup();wr(12'h323,5);wr(12'hb03,~64'b0);
            wr(12'h304,64'h2000);wr(12'h303,64'h2000);wr(12'h603,64'h444);
            rd(12'h603,0,64'h2000);counter_mode(p);pulse_events(32'h20,0,1);
            eq(irq_target_o,1,"guest overflow intercepted by HS");
            trap(64'h8000_0000_0000_000d,1,64'h2000);
            rd(12'h142,64'h8000_0000_0000_000d,~64'b0);rd(12'hda0,8,~64'b0);
            wr(12'h144,0);rd(12'h144,0,64'h2000);rd(12'hda0,8,~64'b0);
            eq(irq_pending,0,"acknowledged guest overflow");
            trap(2,0,64'h1000);wr(12'hb03,~64'b0);pulse_events(32'h20,0,1);
            rd(12'hb03,0,~64'b0);rd(12'h344,0,64'h2000);rd(12'hda0,8,~64'b0);
            wr(12'h323,5);wr(12'hb03,~64'b0);rd(12'h344,0,64'h2000);
            pulse_events(32'h20,0,1);rd(12'h344,64'h2000,64'h2000);rd(12'hda0,8,~64'b0);
        end
        setup();wr(12'h323,5);wr(12'h33f,17);wr(12'hb03,~64'b0);wr(12'hb1f,~64'b0);
        pulse_events(32'h0002_0020,0,1);rd(12'hda0,64'h8000_0008,~64'b0);
        rd(12'hb03,0,~64'b0);rd(12'hb1f,0,~64'b0);rd(12'h344,64'h2000,64'h2000);

        // A genuine wrap wins a same-edge software clear of pending/OF.
        setup();wr(12'h323,5);wr(12'hb03,~64'b0);
        wr_with_event(12'h344,0,32'h20);rd(12'h344,64'h2000,64'h2000);rd(12'hda0,8,~64'b0);
        wr(12'h344,0);wr(12'h323,5);wr(12'hb03,~64'b0);
        wr_with_event(12'h323,5,32'h20);rd(12'h344,64'h2000,64'h2000);rd(12'hda0,8,~64'b0);

        // Conversely, a write to the counting CSR is the counter update for
        // that instruction.  Even when the selected event is high and the old
        // value is all ones, the suppressed implicit increment cannot raise
        // OF or LCOFIP.
        setup();wr(12'h323,5);wr(12'hb03,~64'b0);
        wr_with_event(12'hb03,0,32'h20);
        rd(12'hb03,0,~64'b0);
        rd(12'h344,0,64'h2000);rd(12'hda0,0,~64'b0);

        // Fixed counter wrap is deliberately not a programmable overflow.
        setup();wr(12'h320,5);wr(12'hb00,~64'b0);wr(12'hb02,~64'b0);wr(12'h320,0);
        pulse_events(0,1,1);rd(12'hc00,0,~64'b0);rd(12'hc02,0,~64'b0);
        rd(12'h344,0,64'h2000);rd(12'hda0,0,~64'b0);

        // Shlcofideleg aliases bit 13 to sip/sie, not to hip/hie/hvip.
        setup();wr(12'h303,64'h2000);wr(12'h603,64'h2444);
        wr(12'h204,64'h2222);rd(12'h304,64'h2444,~64'b0);
        rd(12'h204,64'h2222,~64'b0);rd(12'h104,64'h2000,~64'b0);
        wr(12'h244,64'h2002);rd(12'h344,64'h2004,~64'b0);
        rd(12'h244,64'h2002,~64'b0);rd(12'h144,64'h2000,~64'b0);
        rd(12'h644,4,~64'b0);rd(12'h645,4,~64'b0);
        wr(12'h644,64'h2000);rd(12'h344,64'h2000,~64'b0);
        wr(12'h645,64'h2000);rd(12'h645,0,~64'b0);
        wr(12'h244,0);rd(12'h344,0,~64'b0);
        wr(12'h645,64'h2000);rd(12'h344,0,~64'b0); // cannot inject without AIA
        wr(12'h603,0);wr(12'h204,64'h2000);wr(12'h244,64'h2000);
        rd(12'h204,0,~64'b0);rd(12'h244,0,~64'b0);rd(12'h344,0,~64'b0);
        wr(12'h603,64'h2000);wr(12'h303,0);
        rd(12'h603,0,64'h2000);
        wr(12'h603,64'h2000);rd(12'h603,0,64'h2000);
        wr(12'h303,64'h2000);rd(12'h603,0,64'h2000);
        wr(12'h303,0);
        wr(12'h204,64'h2000);wr(12'h244,64'h2000);
        rd(12'h204,0,~64'b0);rd(12'h244,0,~64'b0);rd(12'h344,0,~64'b0);

        // All origins and both delegation levels. No HS delivery while
        // hideleg[13]=1 and V=0; cause 13 stays unshifted in vectored VS entry.
        for(p=0;p<5;p++) for(m=0;m<2;m++) for(h=0;h<2;h++) begin
            setup();wr(12'h303,m?64'h2000:0);wr(12'h603,h?64'h2000:0);
            wr(12'h304,64'h2000);wr(12'h344,64'h2000);
            wr(12'h200,CTX|2);wr(12'h205,64'h3001);
            counter_mode(p);
            if(p==0) wr(12'h300,CTX|8);
            if(p==1) wr(12'h100,CTX|2);
            n=!m || (p!=0 && (!h || p>=3));
            eq(irq_pending,n,"LCOFI delivery with M/HS/VS delegation");
            if(n) begin
                eq(irq_cause,64'h8000_0000_0000_000d,"LCOFI unshifted cause");
                eq(irq_target_o,!m?0:h?2:1,"LCOFI selected destination");
                trap(irq_cause,!m?0:h?2:1,!m?64'h1000:h?64'h3034:64'h2000);
                rd(!m?12'h342:12'h142,64'h8000_0000_0000_000d,~64'b0);
                wr(!m?12'h344:12'h144,0);eq(irq_pending,0,"LCOFI target acknowledgment");
            end
        end
        // VS global enable and priority: timer outranks overflow, which is
        // still pending after the timer source is cleared.
        setup();wr(12'h303,64'h2000);wr(12'h603,64'h2040);
        wr(12'h204,64'h2020);wr(12'h144,64'h2000);wr(12'h645,64'h40);
        enter(1,1);eq(irq_pending,0,"VS SIE masks LCOFI and timer");
        wr(12'h100,CTX|2);eq(irq_cause,64'h8000_0000_0000_0006,"VSTI before LCOFI");
        trap(2,0,64'h1000);wr(12'h645,0);enter(0,1);
        eq(irq_pending,1,"VU LCOFI ignores VS SIE");eq(irq_cause,64'h8000_0000_0000_000d,"VS LCOFI after VSTI");
`endif
`endif
        $display("CSR_H_PASS checks=%0d",checks);$finish;
    end
    initial begin #10000000;$fatal(1,"CSR H timeout");end
endmodule
