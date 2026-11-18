// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C9 (plan 5.2), every dn_* response input free ----
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @* if (f_init) assume(rst); else assume(!rst);
    // Core contract (karu64 rd_lock/wr_lock): at most one outstanding read
    // per channel and one write; a new AR may share the edge of the final R.
    wire f_i_done = up_imem_rvalid && up_imem_rready && up_imem_rlast;
    wire f_d_done = up_dmem_rvalid && up_dmem_rready && up_dmem_rlast;
    always @* if (!f_init) begin
        assume(!(up_imem_arvalid && im_out && !f_i_done));
        assume(!(up_dmem_arvalid && dr_out && !f_d_done));
        assume(!(up_dmem_awvalid && dw_active));
    end
    always @(posedge clk) if (!f_init && !rst) begin
        // island requests never reach the external side
        assert(!(up_imem_arvalid && im_sel && dn_imem_arvalid));
        assert(!(up_dmem_arvalid && dr_sel && dn_dmem_arvalid));
        assert(!(up_dmem_awvalid && dw_sel && dn_dmem_awvalid));
        // a response reaches the core only for an outstanding transaction,
        // and an island-owned one only from the island bridge
        assert(!up_imem_rvalid || im_out);
        assert(!up_dmem_rvalid || dr_out);
        assert(!up_dmem_bvalid || dw_active);
        assert(!(up_imem_rvalid && im_owner) || (i_rvalid && up_imem_rdata == i_rdata));
        assert(!(up_dmem_rvalid && dr_owner) || (d_rvalid && up_dmem_rdata == d_rdata));
        assert(!(up_dmem_bvalid && dw_owner) || d_bvalid);
        // an external beat is consumed only for an outstanding external one
        assert(!dn_imem_rready || (im_out && !im_owner));
        assert(!dn_dmem_rready || (dr_out && !dr_owner));
        assert(!dn_dmem_bready || (dw_active && !dw_owner));
`ifdef FORMAL_BOUNDED
        // Bridge-internal consistency, checked from reset by BMC only: a busy
        // island bridge implies an outstanding, island-owned transaction.
        assert(i_arready || (im_out && im_owner));
        assert(d_arready || (dr_out && dr_owner));
        assert(d_awready || (dw_active && dw_owner));
        assert(!d_bvalid || (dw_active && dw_owner));
        assert(!(i_rvalid && im_out && !im_owner));
        assert(!(d_rvalid && dr_out && !dr_owner));
`endif
    end
    // An accepted island request is island-owned and outstanding until its
    // final response; an accepted external one is external-owned.
    reg f_iacc, f_isel, f_dacc, f_dsel, f_wacc, f_wsel;
    always @(posedge clk) begin
        f_iacc <= up_imem_arvalid && up_imem_arready; f_isel <= im_sel;
        f_dacc <= up_dmem_arvalid && up_dmem_arready; f_dsel <= dr_sel;
        f_wacc <= up_dmem_awvalid && up_dmem_awready; f_wsel <= dw_sel;
    end
    always @(posedge clk) if (!f_init && !rst && !$past(rst) && !$past(f_init)) begin
        assert(!f_iacc || (im_out && im_owner == f_isel));
        assert(!f_dacc || (dr_out && dr_owner == f_dsel));
        assert(!f_wacc || (dw_active && dw_owner == f_wsel));
    end
