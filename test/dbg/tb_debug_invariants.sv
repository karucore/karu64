// SPDX-License-Identifier: BSD-2-Clause
// Independent driven-state positive/negative controls for INV40 and INV41.
`timescale 1ns/1ps
`include "karu_ext.vh"
`include "karudbg_defs.vh"
`include "karu_uop_defs.vh"
`ifndef KARU_DBG_TRIGGER_COUNT
`define KARU_DBG_TRIGGER_COUNT 2
`endif
module tb_debug_invariants;
    reg clk;
    reg rst;
    reg issuing;
    reg perf_retire;
    reg trap_req;
    reg wb_we;
    reg fwb_we;
    reg ex_valid;
    reg exec_busy;
    reg id_accept;
    reg lsu_req;
    reg vlsu_req;
    reg varith_req;
    reg [2-1:0] csr_priv;
    reg csr_virt;
    reg [4-1:0] ex_unit;
    reg [64-1:0] ifu_pc;
    reg dbg_mode;
    reg dbg_enter;
    reg dbg_trigger_entry;
    reg dbg_exit;
    reg dbg_resume_ack;
    reg dbg_halt_priority;
    reg [64-1:0] dbg_entry_pc;
    reg [64-1:0] dbg_dpc;
    reg [64-1:0] dbg_ex_pc;
    reg [3-1:0] dbg_cause;
    reg dbg_step;
    reg dbg_sys_issue;
    reg [31:0] dbg_ex_ins;
    reg dbg_csr_tw;
    reg dbg_csr_vtw;
    reg dbg_cacheop;
    reg dbg_enable;
    reg trigger_exec_valid;
    reg trigger_exec_hit;
    reg trigger_scalar_valid;
    reg trigger_data_valid;
    reg trigger_data_hit;
    reg trigger_v_valid;
    reg trigger_v_abort;
    reg trigger_data_load;
    reg trigger_data_store;
    reg trigger_data_armed;
    reg trigger_fetch_fault;
    reg trigger_io_pending;
    reg trigger_fs_off;
    reg [2-1:0] trigger_cbo_exc;
    reg trigger_hmem;
    reg trigger_hu;
    reg [`KARU_DBG_TRIGGER_COUNT-1:0] trigger_exec_slots;
    reg [`KARU_DBG_TRIGGER_COUNT-1:0] trigger_data_slots;
    reg [64*`KARU_DBG_TRIGGER_COUNT-1:0] trigger_controls;
    reg dbg_sba_pause;
    reg dbg_sba_flush_i;
    reg dbg_sba_flush;
    reg dbg_sba_idle;
    reg dbg_sba_sent;
    reg dbg_sba_done;
    reg dbg_sba_quiet;
    reg dbg_cache_req;
    reg dbg_cache_invalidate;
    reg dbg_cache_done;
    reg [63:0] dbg_sba_next_pc;
    reg dbg_sba_iflush, dbg_sba_dflush;
    reg ifu_redir;
    reg [63:0] ifu_redir_pc;
    wire unused_o;
    karu_debug_assert u_checker(.*);
    always #5 clk=!clk;
    integer fault, checks;
    task defaults;
        begin
            dbg_step=0; dbg_sys_issue=0; dbg_ex_ins=0;
            dbg_csr_tw=0; dbg_csr_vtw=0; dbg_cacheop=0; dbg_enable=1;
            issuing=0;
            perf_retire=0;
            trap_req=0;
            wb_we=0;
            fwb_we=0;
            ex_valid=0;
            exec_busy=0;
            id_accept=0;
            lsu_req=0;
            vlsu_req=0;
            varith_req=0;
            csr_priv=0;
            csr_virt=0;
            ex_unit=0;
            ifu_pc=0;
            dbg_mode=0;
            dbg_enter=0;
            dbg_trigger_entry=0;
            dbg_exit=0;
            dbg_resume_ack=0;
            dbg_halt_priority=0;
            dbg_entry_pc=0;
            dbg_dpc=0;
            dbg_ex_pc=0;
            dbg_cause=0;
            trigger_exec_valid=0;
            trigger_exec_hit=0;
            trigger_scalar_valid=0;
            trigger_data_valid=0;
            trigger_data_hit=0;
            trigger_v_valid=0;
            trigger_v_abort=0;
            trigger_data_load=0;
            trigger_data_store=0;
            trigger_data_armed=0;
            trigger_fetch_fault=0;
            trigger_io_pending=0;
            trigger_fs_off=0;
            trigger_cbo_exc=0;
            trigger_hmem=0;
            trigger_hu=0;
            trigger_exec_slots=0;
            trigger_data_slots=0;
            trigger_controls=0;
            dbg_sba_pause=0;
            dbg_sba_flush_i=0;
            dbg_sba_flush=0;
            dbg_sba_idle=0;
            dbg_sba_sent=0;
            dbg_sba_done=0;
            dbg_sba_quiet=0;
            dbg_cache_req=0;
            dbg_cache_invalidate=0;
            dbg_cache_done=0;
            dbg_sba_next_pc=0;
            dbg_sba_iflush=0;
            dbg_sba_dflush=0;
            ifu_redir=0;
            ifu_redir_pc=0;
            csr_priv=3;ex_unit=`UNIT_ALU;
            ifu_pc=64'h80000400;dbg_ex_pc=ifu_pc;dbg_entry_pc=ifu_pc;
            trigger_controls={2{64'hf000000000000000}};
            dbg_sba_idle=1;dbg_sba_quiet=1;dbg_sba_next_pc=ifu_pc;
        end
    endtask
    task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    initial begin
        clk=0;rst=1;fault=0;checks=0;
        if($value$plusargs("fault=%d",fault))begin end
        defaults;repeat(3)tick;rst=0;tick;
        if(fault==9)begin
            trigger_controls[63:0]=64'h6800000000001041;
            trigger_data_store=1;trigger_data_armed=1;
            tick;
        end
        if(fault==10)begin trigger_fetch_fault=1;trigger_exec_valid=1;dbg_sba_pause=1;tick;end
        if(fault==11)begin
            trigger_scalar_valid=1;ex_valid=1;ex_unit=`UNIT_LSU;trigger_hmem=1;csr_virt=1;csr_priv=1;tick;
        end
        if(fault==12)begin dbg_trigger_entry=1;tick;end
        // A complete before-execution trigger and next-cycle publication.
        trigger_controls[63:0]=64'h6800000000001044;
        ex_valid=1;trigger_exec_valid=1;trigger_exec_hit=1;trigger_exec_slots=1;
        dbg_trigger_entry=1;dbg_enter=1;
        if(fault==1)dbg_enter=0;
        if(fault==2)issuing=1;
        if(fault==3)dbg_entry_pc=ifu_pc+4;
        if(fault==4)csr_priv=0;
        if(fault==13)trigger_exec_valid=0;
        tick;
        trigger_exec_valid=0;trigger_exec_hit=0;trigger_exec_slots=0;
        dbg_enter=0;dbg_trigger_entry=0;ex_valid=0;dbg_mode=1;dbg_dpc=ifu_pc;dbg_cause=2;
        if(fault==14)dbg_cause=4;
        tick;checks++;
        defaults;tick;
        // Independent request/acknowledgement sequence, including a delayed
        // external cache completion. Control flops model the published state.
        dbg_sba_pause=1;dbg_sba_flush_i=1;dbg_sba_flush=1;dbg_sba_quiet=0;
        dbg_cache_req=1;dbg_cache_invalidate=1;dbg_sba_iflush=1;dbg_sba_dflush=1;
        // FENCE-compatible controllers may still report idle-high DONE on
        // the request edge, before accepting the maintenance request.
        dbg_cache_done=1;
        ifu_redir=1;ifu_redir_pc=dbg_sba_next_pc;
        if(fault==5)dbg_cache_req=0;
        if(fault==8)ifu_redir=0;
        if(fault==15)dbg_sba_dflush=0;
        tick;
        dbg_sba_sent=1;dbg_sba_flush=0;dbg_cache_req=0;dbg_cache_invalidate=0;dbg_cache_done=0;
        dbg_sba_iflush=0;dbg_sba_dflush=0;ifu_redir=0;
        if(fault==6)dbg_sba_quiet=1;
        if(fault==7)begin
            dbg_sba_flush=1;dbg_cache_req=1;dbg_cache_invalidate=1;
            dbg_sba_iflush=1;dbg_sba_dflush=1;ifu_redir=1;
        end
        tick;tick;
        // Redirect/refill activity may lower core idle after the request.
        // A legal external ACK must still be remembered, with quiet held
        // low until the speculative read drains independently.
        dbg_sba_idle=0;dbg_sba_quiet=0;dbg_cache_done=1;tick;
        dbg_sba_done=1;dbg_cache_done=0;tick;
        dbg_sba_idle=1;dbg_sba_quiet=1;tick;
        dbg_sba_flush_i=0;tick;
        dbg_sba_sent=0;dbg_sba_done=0;dbg_cache_done=0;dbg_sba_pause=0;tick;checks++;
        // INV41: legal WFI/FENCE/WRS observations, each followed by its
        // corrupted variant under +fault. Encodings are raw, independent of
        // the decoder: WFI 10500073, FENCE rw,rw 0330000f, WRS.NTO 00d00073,
        // WRS.STO 01d00073.
        defaults;tick;
        // Stepped U-mode WFI (S present, so U-mode WFI is illegal) traps.
        dbg_step=1;csr_priv=0;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;trap_req=1;
        if(fault==16)trap_req=0;
        tick;defaults;tick;checks++;
        // Stepped S-mode WFI with mstatus.TW traps; without TW it may wait.
        dbg_step=1;csr_priv=1;dbg_csr_tw=1;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;trap_req=1;
        if(fault==17)trap_req=0;
        tick;defaults;tick;
        dbg_step=1;csr_priv=1;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;tick;defaults;tick;checks++;
        // Stepped VS-mode WFI with hstatus.VTW and stepped VU-mode WFI raise
        // virtual-instruction traps; VS-mode without VTW may wait.
        dbg_step=1;csr_virt=1;csr_priv=1;dbg_csr_vtw=1;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;trap_req=1;
        if(fault==18)trap_req=0;
        tick;defaults;tick;
        dbg_step=1;csr_virt=1;csr_priv=0;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;trap_req=1;
        if(fault==19)trap_req=0;
        tick;defaults;tick;
        dbg_step=1;csr_virt=1;csr_priv=1;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;tick;defaults;tick;checks++;
        // Debug Mode WFI is a NOP at any privilege; M-mode ignores TW.
        dbg_mode=1;csr_priv=0;dbg_csr_tw=1;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;tick;defaults;tick;
        csr_priv=3;dbg_csr_tw=1;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;tick;defaults;tick;checks++;
        // A denied WFI may instead coincide with a halt-request Debug entry.
        csr_priv=0;dbg_sys_issue=1;dbg_ex_ins=32'h10500073;dbg_enter=1;dbg_halt_priority=1;
        if(fault==20)dbg_enter=0;
        tick;defaults;tick;checks++;
        // FENCE issues its ordering handshake in Debug Mode and when stepped.
        dbg_mode=1;dbg_sys_issue=1;dbg_ex_ins=32'h0330000f;dbg_cacheop=1;
        if(fault==21)dbg_cacheop=0;
        tick;defaults;tick;
        dbg_step=1;dbg_sys_issue=1;dbg_ex_ins=32'h0ff0000f;dbg_cacheop=1;
        if(fault==22)dbg_cacheop=0;
        tick;defaults;tick;checks++;
        // WRS is a NOP in Debug Mode and while stepping; FENCE.I (funct3=1)
        // and an opcode-0x0f encoding with WRS's imm12 are not WRS.
        dbg_mode=1;dbg_sys_issue=1;dbg_ex_ins=32'h00d00073;
        if(fault==23)dbg_cacheop=1;
        tick;defaults;tick;
        dbg_step=1;dbg_sys_issue=1;dbg_ex_ins=32'h01d00073;
        if(fault==24)dbg_cacheop=1;
        tick;defaults;tick;
        dbg_mode=1;dbg_sys_issue=1;dbg_ex_ins=32'h00d0000f;dbg_cacheop=1;tick;defaults;tick;
        dbg_sys_issue=1;dbg_ex_ins=32'h00d00073;dbg_cacheop=1;tick;defaults;tick;checks++;
        // INV42: locked, nothing enters Debug Mode; an EBREAK traps instead.
        dbg_enable=0;dbg_sys_issue=1;dbg_ex_ins=32'h00100073;trap_req=1;
        if(fault==25)begin trap_req=0;dbg_enter=1;dbg_halt_priority=1;end
        tick;defaults;tick;
        dbg_enable=0;
        if(fault==26)begin dbg_trigger_entry=1;dbg_enter=1;
            trigger_controls[63:0]=64'h6800000000001044;ex_valid=1;
            trigger_exec_valid=1;trigger_exec_hit=1;trigger_exec_slots=1;end
        tick;defaults;tick;checks++;
        $display("karudbg INV40 driven positive: PASS %0d sequences",checks);$finish;
    end
    initial begin #10000;$fatal(1,"INV40 fixture timeout");end
endmodule
