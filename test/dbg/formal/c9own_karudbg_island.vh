// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of dbg/karudbg_island.v by
// test/dbg/run_auth_formal.py (lemma C9own), after c9_karudbg_island.vh: it
// has no assumption of its own and uses that block's f_init. The runner
// also names three port connections of the island's bridges in the build
// copy, so that what a bridge sees on its response-ready inputs can be
// asserted: f_i_rready, f_d_rready and f_d_bready are the expressions the
// RTL has on .s_rready of i_bridge and on .s_rready and .s_bready of
// d_bridge, moved into wires and otherwise unchanged.
    // ---- formal lemma C9own: response ownership for the whole transaction ----
    // Lemma C9 checks the owner flag one cycle after an address is accepted
    // and words its response checks with the router's own flags. This block
    // has ghost state of its own. It reads neither the router's flags
    // (im_owner, dr_owner, dw_owner, im_out, dr_out, dw_active) nor its
    // address decode (im_sel, dr_sel, dw_sel, in_island), except in the
    // strengthening invariants at the end, which the control runs leave out.
    //
    // g_?_out: a transaction is outstanding on the channel (i: imem read,
    // r: dmem read, w: dmem write), from the edge that accepts its address
    // to the edge that accepts its last response beat (R with RLAST, or B).
    // An address accepted on the edge of the previous transaction's last
    // beat is outstanding after it. g_?_isl: the destination of that
    // address, taken at the accepting edge from the address and the
    // module's parameters, and held through any number of stalled cycles
    // and response beats until the next address is accepted.
    function g_dest;                // 1: the island's ROM or SRAM range
        input [`AXI_ADDR_W-1:0] a;
        begin
            g_dest = (a >= ROM_BASE && a < ROM_END) || (a >= SRAM_BASE && a < SRAM_END);
        end
    endfunction
    reg g_i_out, g_i_isl, g_r_out, g_r_isl, g_w_out, g_w_isl;
    always @(posedge clk) begin
        if (rst) begin
            g_i_out <= 1'b0; g_r_out <= 1'b0; g_w_out <= 1'b0;
        end else begin
            if (up_imem_rvalid && up_imem_rready && up_imem_rlast) g_i_out <= 1'b0;
            if (up_dmem_rvalid && up_dmem_rready && up_dmem_rlast) g_r_out <= 1'b0;
            if (up_dmem_bvalid && up_dmem_bready) g_w_out <= 1'b0;
            if (up_imem_arvalid && up_imem_arready) begin g_i_out <= 1'b1; g_i_isl <= g_dest(up_imem_araddr); end
            if (up_dmem_arvalid && up_dmem_arready) begin g_r_out <= 1'b1; g_r_isl <= g_dest(up_dmem_araddr); end
            if (up_dmem_awvalid && up_dmem_awready) begin g_w_out <= 1'b1; g_w_isl <= g_dest(up_dmem_awaddr); end
        end
    end
    // The island's transaction, or a downstream one, is outstanding.
    wire g_i_island = g_i_out && g_i_isl, g_i_down = g_i_out && !g_i_isl;
    wire g_r_island = g_r_out && g_r_isl, g_r_down = g_r_out && !g_r_isl;
    wire g_w_island = g_w_out && g_w_isl, g_w_down = g_w_out && !g_w_isl;
    // For each channel, in every cycle outside reset:
    // (n) no transaction: no beat is presented to the core and none is
    //     taken from downstream;
    // (i) the island's transaction: the core is shown a beat exactly when
    //     the island bridge offers one, and it is that beat (ID, data,
    //     response code, LAST); the bridge sees the core's READY and
    //     downstream sees none;
    // (d) a downstream transaction: the same with the two sources swapped.
    // Not claimed: that the island bridge sees no READY with no transaction
    // outstanding. It does when the last one was the island's (the RTL
    // gates that READY with the owner flag alone); the bridge has no beat
    // to give then, which lemma C9 states over the router's flags, bounded.
    always @(posedge clk) if (!f_init && !rst) begin
        // imem, R
        assert(g_i_out || !up_imem_rvalid);
        assert(g_i_out || !dn_imem_rready);
        assert(!g_i_island || up_imem_rvalid == i_rvalid);
        assert(!(g_i_island && up_imem_rvalid) || up_imem_rid == i_rid);
        assert(!(g_i_island && up_imem_rvalid) || up_imem_rdata == i_rdata);
        assert(!(g_i_island && up_imem_rvalid) || up_imem_rresp == i_rresp);
        assert(!(g_i_island && up_imem_rvalid) || up_imem_rlast == i_rlast);
        assert(!g_i_island || f_i_rready == up_imem_rready);
        assert(!g_i_island || !dn_imem_rready);
        assert(!g_i_down || up_imem_rvalid == dn_imem_rvalid);
        assert(!(g_i_down && up_imem_rvalid) || up_imem_rid == dn_imem_rid);
        assert(!(g_i_down && up_imem_rvalid) || up_imem_rdata == dn_imem_rdata);
        assert(!(g_i_down && up_imem_rvalid) || up_imem_rresp == dn_imem_rresp);
        assert(!(g_i_down && up_imem_rvalid) || up_imem_rlast == dn_imem_rlast);
        assert(!g_i_down || dn_imem_rready == up_imem_rready);
        assert(!g_i_down || !f_i_rready);
        // dmem, R
        assert(g_r_out || !up_dmem_rvalid);
        assert(g_r_out || !dn_dmem_rready);
        assert(!g_r_island || up_dmem_rvalid == d_rvalid);
        assert(!(g_r_island && up_dmem_rvalid) || up_dmem_rid == d_rid);
        assert(!(g_r_island && up_dmem_rvalid) || up_dmem_rdata == d_rdata);
        assert(!(g_r_island && up_dmem_rvalid) || up_dmem_rresp == d_rresp);
        assert(!(g_r_island && up_dmem_rvalid) || up_dmem_rlast == d_rlast);
        assert(!g_r_island || f_d_rready == up_dmem_rready);
        assert(!g_r_island || !dn_dmem_rready);
        assert(!g_r_down || up_dmem_rvalid == dn_dmem_rvalid);
        assert(!(g_r_down && up_dmem_rvalid) || up_dmem_rid == dn_dmem_rid);
        assert(!(g_r_down && up_dmem_rvalid) || up_dmem_rdata == dn_dmem_rdata);
        assert(!(g_r_down && up_dmem_rvalid) || up_dmem_rresp == dn_dmem_rresp);
        assert(!(g_r_down && up_dmem_rvalid) || up_dmem_rlast == dn_dmem_rlast);
        assert(!g_r_down || dn_dmem_rready == up_dmem_rready);
        assert(!g_r_down || !f_d_rready);
        // dmem, B
        assert(g_w_out || !up_dmem_bvalid);
        assert(g_w_out || !dn_dmem_bready);
        assert(!g_w_island || up_dmem_bvalid == d_bvalid);
        assert(!(g_w_island && up_dmem_bvalid) || up_dmem_bid == d_bid);
        assert(!(g_w_island && up_dmem_bvalid) || up_dmem_bresp == d_bresp);
        assert(!g_w_island || f_d_bready == up_dmem_bready);
        assert(!g_w_island || !dn_dmem_bready);
        assert(!g_w_down || up_dmem_bvalid == dn_dmem_bvalid);
        assert(!(g_w_down && up_dmem_bvalid) || up_dmem_bid == dn_dmem_bid);
        assert(!(g_w_down && up_dmem_bvalid) || up_dmem_bresp == dn_dmem_bresp);
        assert(!g_w_down || dn_dmem_bready == up_dmem_bready);
        assert(!g_w_down || !f_d_bready);
`ifdef FORMAL_STRENGTHEN
        // Strengthening for the induction, not claims: the ghost state is
        // the router's. The control runs leave these out, so that a control
        // fails on the assertions above.
        assert(g_i_out == im_out && g_r_out == dr_out && g_w_out == dw_active);
        assert(!g_i_out || g_i_isl == im_owner);
        assert(!g_r_out || g_r_isl == dr_owner);
        assert(!g_w_out || g_w_isl == dw_owner);
`endif
    end
`ifdef FORMAL_COVER
    // Reachability, for the single model of test/dbg/run_auth_compose.py: a
    // stalled beat of the island's and a downstream beat that is not the
    // last one, so that a transaction there lasts more than one cycle.
    always @(posedge clk) if (!f_init && !rst) begin
        cover(g_r_island && up_dmem_rvalid && !up_dmem_rready);
        cover(g_r_down && up_dmem_rvalid && up_dmem_rready && !up_dmem_rlast);
    end
`endif
