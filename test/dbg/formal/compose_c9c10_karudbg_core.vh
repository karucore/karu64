// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of dbg/karudbg_core.v by
// test/dbg/run_auth_compose.py. It is the link of the single model for
// lemma C9 with lemma C10 (doc/debug-auth-plan.md 5.2 and 7, A3).
//
// In that model the island copy carries lemma C9's own block and the core
// copy carries lemma C10's own block, each with its assumptions about the
// other side turned into assertions by the runner; nothing is assumed about
// the bus between them. C9 states the core's contract over the island's
// flags, C10 states its guarantee over ghost flags of its own. The runner
// gives each copy one formal-only output so that the two sets of flags can
// be compared here:
//   f_island_obs = {im_owner, dr_owner, dw_owner, im_out, dr_out, dw_active}
//   f_core_obs   = {f_iout, f_rout, f_wact}
//
// The island copy also carries lemma C9own's block after C9's, as it is
// (c9own_karudbg_island.vh; it assumes nothing). That block checks every
// response beat against ghost state of its own, and its strengthening
// invariants compare the island's three owner flags, as well as the three
// flags compared below, with that ghost state.
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    // The island's "a transaction is outstanding on this channel" flags are
    // C10's ghost flags, in every cycle after the first, a reset cycle
    // included. The first cycle is the reset cycle from an arbitrary state.
    always @* if (!f_init) assert(f_island_obs[2:0] == f_core_obs);
`ifdef FORMAL_COVER
    // Reachability, so that the proof is not vacuous: each kind of response
    // is delivered to the core, and one is delivered after a later reset.
    reg f_reset_again = 1'b0;
    always @(posedge clk) if (!f_init && core_rst) f_reset_again <= 1'b1;
    always @(posedge clk) if (!f_init && !core_rst) begin
        cover(k_imem_rvalid && k_imem_rready && k_imem_rlast && f_island_obs[5]);
        cover(k_imem_rvalid && k_imem_rready && k_imem_rlast && !f_island_obs[5]);
        cover(k_dmem_rvalid && k_dmem_rready && k_dmem_rlast && f_island_obs[4]);
        cover(k_dmem_rvalid && k_dmem_rready && k_dmem_rlast && !f_island_obs[4]);
        cover(k_dmem_bvalid && k_dmem_bready && f_island_obs[3]);
        cover(k_dmem_bvalid && k_dmem_bready && !f_island_obs[3]);
        cover(f_reset_again && k_imem_rvalid && k_imem_rready && f_island_obs[5]);
        cover(f_reset_again && k_dmem_bvalid && k_dmem_bready && f_island_obs[3]);
    end
`endif
