// SPDX-License-Identifier: BSD-2-Clause
// Portable INV40 attachment; DUT hierarchy is the core inside karudbg_core.
`ifdef KARU_DBG
    karu_debug_assert debug_contract_checker (
        .clk(dut.core.clk),
        .rst(dut.core.rst),
        .issuing(dut.core.issuing),
        .perf_retire(dut.core.perf_retire),
        .trap_req(dut.core.trap_req),
        .wb_we(dut.core.wb_we),
        .fwb_we(dut.core.fwb_we),
        .ex_valid(dut.core.ex_valid),
        .exec_busy(dut.core.exec_busy),
        .id_accept(dut.core.id_accept),
        .lsu_req(dut.core.lsu_req),
        .vlsu_req(dut.core.vlsu_req),
        .varith_req(dut.core.varith_req),
        .csr_priv(dut.core.csr_priv),
        .csr_virt(dut.core.csr_virt),
        .ex_unit(dut.core.ex_unit),
        .ifu_pc(dut.core.ifu_pc),
        .ifu_redir(dut.core.ifu_redir), .ifu_redir_pc(dut.core.ifu_redir_pc),
        .dbg_mode(dut.core.debug_mode),
        .dbg_enter(dut.core.dbg_enter),
        .dbg_trigger_entry(dut.core.dbg_trigger_entry),
        .dbg_exit(dut.core.dbg_exit),
        .dbg_resume_ack(dut.core.debug_resume_ack_o),
        .dbg_halt_priority((dut.core.debug_halt_req_i || dut.core.dbg_halt_pending)),
        .dbg_entry_pc(dut.core.dbg_entry_pc),
        .dbg_dpc(dut.core.dbg_dpc),
        .dbg_ex_pc(dut.core.ex_pc),
        .dbg_cause(dut.core.csr.csr_dcsr[8:6]),
`ifdef KARU_DBG_TRIGGERS
        .trigger_exec_valid(dut.core.trigger_exec_valid),
        .trigger_exec_hit(dut.core.trigger_exec_hit),
        .trigger_scalar_valid(dut.core.trigger_scalar_valid),
        .trigger_data_valid(dut.core.trigger_data_valid),
        .trigger_data_hit(dut.core.trigger_data_hit),
        .trigger_v_valid(dut.core.trigger_v_valid),
        .trigger_v_abort(dut.core.trigger_v_abort),
        .trigger_data_load(dut.core.trigger_data_load),
        .trigger_data_store(dut.core.trigger_data_store),
        .trigger_data_armed(dut.core.trigger_data_armed),
        .trigger_fetch_fault(dut.core.ifu_fault_valid),
        .trigger_io_pending(dut.core.immu_pte_io_pending),
        .trigger_fs_off(dut.core.fs_off_ill),
        .trigger_cbo_exc(dut.core.cbo_exc),
        .trigger_hmem(dut.core.ex_hmem),
        .trigger_hu(dut.core.csr_hu),
        .trigger_exec_slots(dut.core.csr.triggers.exec_hit),
        .trigger_data_slots(dut.core.csr.triggers.data_hit),
        .trigger_controls(dut.core.csr.triggers.debug_controls),
`endif
`ifdef KARU_DBG_SBA
        .dbg_sba_pause(dut.core.debug_sba_pause_i),
        .dbg_sba_flush_i(dut.core.debug_sba_flush_i),
        .dbg_sba_flush(dut.core.dbg_sba_flush),
        .dbg_sba_idle(dut.core.dbg_sba_idle),
        .dbg_sba_sent(dut.core.dbg_sba_cache_sent),
        .dbg_sba_done(dut.core.dbg_sba_cache_done),
        .dbg_sba_quiet(dut.core.debug_sba_quiet_o),
        .dbg_cache_req(dut.core.cache_flush_req),
        .dbg_cache_invalidate(dut.core.cache_flush_invalidate),
        .dbg_cache_done(dut.core.cache_flush_done),
        .dbg_sba_next_pc(dut.core.dbg_sba_next_pc), .dbg_sba_iflush(dut.core.icache_flush),
`ifdef KARU_EN_MEM
        .dbg_sba_dflush(dut.core.dmem_l1.flush),
`else
        .dbg_sba_dflush(1'b1),
`endif
`endif
        .unused_o()
    );
`endif
