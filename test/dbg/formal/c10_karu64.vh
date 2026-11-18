// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C10: the core's one-outstanding-transaction contract ----
    // This is the assumption of lemma C9, proved on the core's AXI arbiters
    // with every submodule free. The ghost flags follow the island's rule:
    // set at AR/AW acceptance, cleared by the final R beat or by B.
    //
    // Environment assumption: an R or B beat is presented only for an
    // outstanding transaction. C9 guarantees exactly that at the island's
    // core-facing ports. The two lemmas lean on each other only through
    // registered flags: each one's guarantee in a cycle follows from the
    // other's in earlier cycles, so the pair composes by induction on time.
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @* if (f_init) assume(rst); else assume(!rst);
    reg f_iout, f_rout, f_wact;
    always @(posedge clk) begin
        if (rst) begin f_iout <= 0; f_rout <= 0; f_wact <= 0; end
        else begin
            if (imem_rvalid && imem_rready && imem_rlast) f_iout <= 0;
            if (dmem_rvalid && dmem_rready && dmem_rlast) f_rout <= 0;
            if (imem_arvalid && imem_arready) f_iout <= 1;
            if (dmem_arvalid && dmem_arready) f_rout <= 1;
            if (dmem_awvalid && dmem_awready) f_wact <= 1;
            if (dmem_bvalid && dmem_bready) f_wact <= 0;
        end
    end
    always @* if (!f_init) begin
        assume(!imem_rvalid || f_iout);
        assume(!dmem_rvalid || f_rout);
        assume(!dmem_bvalid || f_wact);
    end
    always @(posedge clk) if (!f_init && !rst) begin
        // no new address while one is outstanding on the channel
        assert(!(imem_arvalid && f_iout));
        assert(!(dmem_arvalid && f_rout));
        assert(!(dmem_awvalid && f_wact));
        // strengthening: the ghost flags are the arbiters' own "address sent"
        assert(f_iout == (im_rd_lock && im_ar_done));
        assert(f_rout == (rd_lock && rd_ar_done));
        assert(f_wact == (wr_lock && wr_aw_done));
    end
