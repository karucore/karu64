#!/usr/bin/env python3
"""Formal lemmas of the debug-authentication plan (doc/debug-auth-plan.md 5.2).

Each lemma's property block (test/dbg/formal/*.vh) is spliced, under
`ifdef FORMAL, into a build copy of its module; the repository RTL is read
only. Every module input is free except the stated assumptions. For each
lemma the runner performs:

  * BMC from reset to the stated depth;
  * k-induction (unbounded proof) where the lemma claims one;
  * BMC of each mutant, which must FAIL, so the proof is not vacuous. A lemma
    may mark the strengthening invariants that name the mutated logic's own
    state ("strengthen_define"): they are asserted in the proof runs and left
    out of the mutant runs, so a mutant fails on the lemma's own properties.
    A lemma with several blocks may name one of them as its own ("own_block"):
    in its mutant runs the other blocks keep their assumptions and ghost
    state and their assertions become cover statements, which BMC does not
    check, so each mutant has to fail on an assertion of the lemma's own
    block. A mutant may name that assertion ("expect"), and every assertion
    of the own block has to fail in at least one mutant run.

The assertions a run failed on are taken from yosys-smtbmc's log and
recorded, with the step, in results.json.

Tools: Yosys (read_verilog -formal, write_smt2) and yosys-smtbmc with z3.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]

def core_rtl():
    out = subprocess.run(["make", "-s", "-p", "-n"], cwd=ROOT, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True).stdout
    line = next(l for l in out.splitlines() if re.match(r"^CORE_RTL *:?= ", l))
    files = line.split("=", 1)[1].split()
    return [f for f in files if f != "rtl/karu64.v"] + ["rtl/karu_sv39.v"]


def dbg_core_rtl():
    dbg = [l.strip() for l in (ROOT / "dbg/karudbg.f").read_text().splitlines()
           if l.strip().endswith(".v") and "karudbg_core.v" not in l]
    return sorted(set(core_rtl() + ["rtl/karu64.v"] + dbg))


LEMMAS = {
    "C4": dict(
        module="karu64", src="rtl/karu64.v", block="test/dbg/formal/c4_karu64.vh",
        extra="CORE_RTL", defines=["KARU_DBG", "KARU_DBG_AUTH", "KARU_DBG_TRIGGERS", "KARU_NO_V"],
        chparams=[], bmc=2, induct=0, cut_submodules=True,
        claim="core entry (K5): from an arbitrary state with free inputs, every submodule "
              "output free, debug_mode rises only if debug_enable_i was 1 (one-step, sound "
              "over-approximation of all reachable states); debug_mode is 0 after any reset cycle",
        mutants=[("no_core_gate", "    assign dbg_enter = !debug_mode && dbg_en && (",
                  "    assign dbg_enter = !debug_mode && ("),
                 ("debug_mode_resets_to_1", "            debug_mode <= 0;\n            dbg_halt_pending <= 0;",
                  "            debug_mode <= 1;\n            dbg_halt_pending <= 0;")]),
    "C6v": dict(
        module="karudbg_auth", src="dbg/karudbg_auth.v", block="test/dbg/formal/c6_karudbg_auth.vh",
        extra=[], defines=[], chparams=[], bmc=2, induct=0,
        claim="POR values of karudbg_auth from an arbitrary earlier state with free inputs: the "
              "lifecycle, hold, revocation and gate take the values sampled from the trust inputs "
              "in the reset cycle; grant, request, boot_done, fw_lock and the mailbox are 0",
        mutants=[("gate_open_outside_OPEN", "debug_enable_o <= lc_i == LC_OPEN && !revoke_i;",
                  "debug_enable_o <= lc_i != 2'd2 && !revoke_i;"),
                 ("hold_outside_AUTH", "hold_q <= hold_strap_i && lc_i == LC_AUTH;", "hold_q <= hold_strap_i;"),
                 ("lc3_not_disabled", "lc_q <= lc_i == 2'd3 ? 2'd2 : lc_i;", "lc_q <= lc_i;"),
                 ("grant_resets_to_1", "auth_req_q <= 0; auth_unlock_q <= 0; boot_done_q <= 0;",
                  "auth_req_q <= 0; auth_unlock_q <= 1; boot_done_q <= 0;")]),
    "C6cone": dict(
        module="karudbg_core", src="dbg/karudbg_core.v", block="test/dbg/formal/c6_karudbg_core.vh",
        extra="DBG_CORE_RTL", defines=["KARU_DBG", "KARU_DBG_AUTH", "KARU_DBG_TRIGGERS", "KARU_NO_V"],
        chparams=[], bmc=1, induct=0, cut_submodules=True,
        claim="hart-side reset in karudbg_core, every submodule free: core_rst is asserted exactly "
              "by POR, the platform hart reset, ndmreset and the authentication hold/relock reset",
        mutants=[("auth_reset_not_in_cone", "assign core_rst = rst || hart_reset_i || ndmreset_o || auth_reset_o;",
                  "assign core_rst = rst || hart_reset_i || ndmreset_o;")]),
    "C8": dict(
        module="karu64", src="rtl/karu64.v", block="test/dbg/formal/c8_karu64.vh",
        extra="CORE_RTL", defines=["KARU_DBG", "KARU_DBG_AUTH", "KARU_DBG_TRIGGERS", "KARU_NO_V"],
        chparams=[], bmc=1, induct=0, cut_submodules=True, cut_keep=["karu_csr"],
        claim="provenance at K2: from an arbitrary state, every submodule except the CSR file "
              "free, an authentication-CSR commit is reported only for an issuing CSR "
              "instruction outside reset that takes no trap and no Debug entry in that cycle; "
              "the PC, privilege and closing signals are the issuing instruction's; the issue "
              "signal and, on every issue, the PC reach karudbg_auth on every cycle",
        mutants=[("csr_request_not_issue", "    assign csr_req  = issue_csr;",
                  "    assign csr_req  = ex_valid;"),
                 ("issue_not_reported", "    assign auth_issuing_o = issuing;",
                  "    assign auth_issuing_o = issuing && ex_unit == `UNIT_CSR;"),
                 ("pc_from_fetch", "    assign auth_ex_pc_o = ex_pc;",
                  "    assign auth_ex_pc_o = ifu_pc;")]),
    "C10": dict(
        module="karu64", src="rtl/karu64.v", block="test/dbg/formal/c10_karu64.vh",
        extra="CORE_RTL", defines=["KARU_DBG", "KARU_DBG_AUTH", "KARU_DBG_TRIGGERS", "KARU_NO_V"],
        chparams=[], bmc=8, induct=2, cut_submodules=True,
        claim="core AXI arbiters, every submodule free: no new AR on imem or dmem and no new AW "
              "while one is outstanding on that channel, given that R and B beats arrive only "
              "for outstanding transactions (which C9 guarantees at the island)",
        mutants=[("imem_ar_repeats", "assign imem_arvalid = !im_ar_done && (", "assign imem_arvalid = ("),
                 ("dmem_aw_repeats", "assign dmem_awvalid = !wr_aw_done && (", "assign dmem_awvalid = (")]),
    "C2": dict(
        module="karudbg", src="dbg/karudbg.v", block="test/dbg/formal/c2_karudbg.vh",
        extra=["dbg/karudbg_rom.v", "dbg/karudbg_sba.v"],
        defines=["KARU_DBG_AUTH", "KARU_DBG_SBA", "KARU_DBG_AUTOEXEC"], chparams=[],
        bmc=8, induct=8,
        claim="DM locked since POR: all outputs 0, engine and debugger state at reset, "
              "no DMI disclosure, hart page offers only EBREAK/zero",
        mutants=[("locked_view_removed", "        if (dmactive_q && !dbg_en) begin",
                  "        if (1'b0) begin"),
                 ("safe_sequence_removed", "            mem_rdata_o = dbg_en ? {abstract_word",
                  "            mem_rdata_o = 1'b1 ? {abstract_word")]),
    "C5": dict(
        module="karudbg_auth", src="dbg/karudbg_auth.v", block="test/dbg/formal/c5_karudbg_auth.vh",
        extra=[], defines=[], chparams=[], bmc=12, induct=3,
        claim="karudbg_auth: monotone POR state, lc constant, debug_enable equals its formula, "
              "grant only in AUTH, grant rise only under the full commit predicate, "
              "no grant after boot_done, OPEN never held or reset unless revoked; boot_done is "
              "set on the edge after a trap, Debug entry or issue outside the ROM, after any "
              "reset once the hart has run, after a session reset once a response word was "
              "popped, and after the ROM's own write; the request is recorded only by a "
              "well-formed REQUEST in AUTH while held, and the hold ends only by it or by the strap",
        mutants=[("unlock_without_request", "lc_auth && auth_req_q && !boot_done_q",
                  "lc_auth && !boot_done_q"),
                 ("unlock_beats_trap", [(" && !boot_exit_now && !sess_close_now;", " && !sess_close_now;"),
                                        (" && !core_in_reset_i && !trap_i && !dbg_enter_i;",
                                         " && !core_in_reset_i;")]),
                 ("no_exit_close", "assign boot_done_set = boot_exit_now || sess_close_now || reset_close ||",
                  "assign boot_done_set = sess_close_now || reset_close ||"),
                 ("no_session_close", "assign boot_done_set = boot_exit_now || sess_close_now || reset_close ||",
                  "assign boot_done_set = boot_exit_now || reset_close ||"),
                 ("no_reset_close", "assign boot_done_set = boot_exit_now || sess_close_now || reset_close ||",
                  "assign boot_done_set = boot_exit_now || sess_close_now ||"),
                 ("no_rom_close", "csr_sel_i == SEL_AUTH && csr_wdata_i[1] && !debug_mode_i);",
                  "csr_sel_i == SEL_AUTH && 1'b0 && !debug_mode_i);"),
                 ("hold_released_by_any_request",
                  "!(dmi_header && hdr_op == OP_REQUEST && hdr_rsvd_ok && req_arg_ok && req_state_ok);",
                  "!(dmi_header && hdr_op == OP_REQUEST);"),
                 ("request_any_argument", "assign req_arg_ok = dmi_wdata_i[23:16] == 8'ha5 &&",
                  "assign req_arg_ok = 1'b1 ||"),
                 # The review's control: every automatic closing term removed.
                 ("no_automatic_close", "assign boot_done_set = boot_exit_now || sess_close_now || reset_close ||",
                  "assign boot_done_set =")]),
    "C7dm": dict(
        module="karudbg", src="dbg/karudbg.v", block="test/dbg/formal/c7_karudbg.vh",
        extra=["dbg/karudbg_rom.v", "dbg/karudbg_sba.v"],
        defines=["KARU_DBG_AUTH", "KARU_DBG_SBA", "KARU_DBG_AUTOEXEC"], chparams=[],
        bmc=4, induct=0,
        claim="revocation, DM side, from an arbitrary state: every output 0 in every locked "
              "cycle (ndmreset_o on the falling edge), no command launch, hart sees only the "
              "safe sequence, DMI reads accepted while locked return the locked view",
        mutants=[("ndmreset_old_gate", "if (!dbg_en_next) ndmreset_q <= 0;",
                  "if (!dbg_en) ndmreset_q <= 0;")]),
    "C7relock": dict(
        module="karudbg_auth", src="dbg/karudbg_auth.v", block="test/dbg/formal/c7_karudbg_auth.vh",
        extra=[], defines=[], chparams=[], bmc=4, induct=0,
        claim="revocation, relock: from an arbitrary state a Debug-Mode hart with the gate "
              "closed is reset on the next cycle (k=1); revocation is monotone",
        mutants=[("no_relock_reset", "assign relock_d = !debug_enable_o && debug_mode_i && !core_in_reset_i;",
                  "assign relock_d = 1'b0;")]),
    "C3": dict(
        module="karudbg_c3", src="test/dbg/formal/c3_miter.v", block="test/dbg/formal/c3_karudbg.vh",
        extra=["dbg/karudbg.v", "dbg/karudbg_rom.v", "dbg/karudbg_sba.v"],
        defines=["KARU_DBG_AUTH", "KARU_DBG_SBA", "KARU_DBG_AUTOEXEC"], chparams=[],
        bmc=10, induct=6, mutate="dbg/karudbg.v",
        # The two copies' hidden state must be tied together for induction.
        # The proof uses a formal-only copy of karudbg.v with one extra output,
        # f_obs_o, carrying these registers; the repository file is unchanged.
        observe=["dmactive_q", "deact_pending_q", "cmd_state_q"],
        observe_after="    output wire dmactive_o           // session reset for karudbg_auth\n",
        claim="DM noninterference: two copies of karudbg with the gate closed since POR, the same "
              "DMI inputs and the same mailbox, and free, separate hart, debug-page and System Bus "
              "inputs, give the debugger identical DMI handshakes and responses and pass identical "
              "words to the mailbox, in every cycle",
        mutants=[("locked_view_removed", "        if (dmactive_q && !dbg_en) begin",
                  "        if (1'b0) begin"),
                 # data0 as a channel: the hart may write it while locked, the
                 # locked-state clearing is gone, and the locked view shows it.
                 # The RTL has all three safeguards; any one alone keeps it shut.
                 ("data0_channel_ungated", [
                     ("                    data_q <= 0;\n                    for (i = 0; i < 8; i = i + 1) progbuf_q[i] <= 0;",
                      "                    for (i = 0; i < 8; i = i + 1) progbuf_q[i] <= 0;"),
                     ("            if (mem_fire && mem_write_i && dbg_en &&\n                mem_aligned_addr == `KARUDBG_DATA) begin",
                      "            if (mem_fire && mem_write_i &&\n                mem_aligned_addr == `KARUDBG_DATA) begin"),
                     ("                7'h11: dmi_read = {25'b0, auth_busy, 6'h03};\n                7'h30:",
                      "                7'h11: dmi_read = {25'b0, auth_busy, 6'h03};\n                7'h04: dmi_read = data_q[31:0];\n                7'h30:")]),
                 ("hart_state_in_locked_dmstatus", "                7'h11: dmi_read = {25'b0, auth_busy, 6'h03};",
                  "                7'h11: dmi_read = {22'b0, hart_halted_i, 2'b0, auth_busy, 6'h03};")]),
    "C9": dict(
        module="karudbg_island", src="dbg/karudbg_island.v", block="test/dbg/formal/c9_karudbg_island.vh",
        extra=["dbg/karudbg_axi.v"], defines=[], chparams=["SRAM_END 32'h00020040"],
        bmc=12, induct=6, bounded_define="FORMAL_BOUNDED",
        claim="island: requests never leak downstream; a response reaches the core only for an "
              "outstanding transaction and, island-owned, only from the island; external beats "
              "are consumed only for outstanding external transactions. Burst lengths are "
              "unconstrained on every channel; the only assumption is the core's "
              "one-outstanding-transaction contract (proved separately as C10)",
        mutants=[("owner_only_mux",
                  "assign up_dmem_rvalid = dr_out && (dr_owner ? d_rvalid : dn_dmem_rvalid);",
                  "assign up_dmem_rvalid = dr_owner ? d_rvalid : dn_dmem_rvalid;")]),
}

# ---- C9own: response ownership on the island for the whole transaction ----
# C9's block and the ownership block together, so every C9 property is proved
# again in the same model; the ownership block adds no assumption. Its ghost
# state does not read the router's flags or address decode.
C9OWN_BLOCK = "test/dbg/formal/c9own_karudbg_island.vh"
# (name, ghost prefix, owner flag, outstanding flag, bridge prefix, valid, ready, bridge port, fields)
C9OWN_CHANNELS = [
    ("imem_r", "g_i", "im_owner", "im_out", "i", "rvalid", "rready", "s_rready", ["rid", "rdata", "rresp", "rlast"]),
    ("dmem_r", "g_r", "dr_owner", "dr_out", "d", "rvalid", "rready", "s_rready", ["rid", "rdata", "rresp", "rlast"]),
    ("dmem_b", "g_w", "dw_owner", "dw_active", "d", "bvalid", "bready", "s_bready", ["bid", "bresp"]),
]


def c9own_controls():
    """One control for each assertion of the ownership block: a one-line
    change of the router that breaks that assertion and no other. Returns
    the mutants and, by name, the assertion each has to fail on."""
    mutants, expect = [], {}

    def add(name, before, after, expr):
        mutants.append((name, before, after))
        expect[name] = expr
    for ch, g, own, out, br, valid, ready, port, fields in C9OWN_CHANNELS:
        bus = ch.split("_")[0]                                      # imem or dmem
        up, dn, isl = f"up_{bus}_", f"dn_{bus}_", f"{br}_"
        probe = f"f_{br}_{ready}"
        for f in fields:
            line = f"    assign {up}{f} = {own} ? {isl}{f} : {dn}{f};"
            add(f"{ch}_{f}_from_downstream", line, f"    assign {up}{f} = {dn}{f};",
                f"!({g}_island && {up}{valid}) || {up}{f} == {isl}{f}")
            add(f"{ch}_{f}_from_island", line, f"    assign {up}{f} = {isl}{f};",
                f"!({g}_down && {up}{valid}) || {up}{f} == {dn}{f}")
        line = f"    assign {up}{valid} = {out} && ({own} ? {isl}{valid} : {dn}{valid});"
        add(f"{ch}_valid_without_outstanding", line, f"    assign {up}{valid} = {own} ? {isl}{valid} : {dn}{valid};",
            f"{g}_out || !{up}{valid}")
        add(f"{ch}_valid_from_downstream", line, f"    assign {up}{valid} = {out} && {dn}{valid};",
            f"!{g}_island || {up}{valid} == {isl}{valid}")
        add(f"{ch}_valid_from_island", line, f"    assign {up}{valid} = {out} && {isl}{valid};",
            f"!{g}_down || {up}{valid} == {dn}{valid}")
        line = f"    assign {dn}{ready} = {up}{ready} && {out} && !{own};"
        add(f"{ch}_downstream_ready_without_outstanding", line, f"    assign {dn}{ready} = {up}{ready} && !{own};",
            f"{g}_out || !{dn}{ready}")
        add(f"{ch}_downstream_ready_to_non_owner", line, f"    assign {dn}{ready} = {up}{ready} && {out};",
            f"!{g}_island || !{dn}{ready}")
        add(f"{ch}_downstream_ready_not_the_cores", line, f"    assign {dn}{ready} = {out} && !{own};",
            f"!{g}_down || {dn}{ready} == {up}{ready}")
        line = f".{port}({up}{ready} && {own})"
        add(f"{ch}_island_ready_to_non_owner", line, f".{port}({up}{ready})", f"!{g}_down || !{probe}")
        add(f"{ch}_island_ready_not_the_cores", line, f".{port}({own})", f"!{g}_island || {probe} == {up}{ready}")
    return mutants, expect


C9OWN_MUTANTS, C9OWN_EXPECT = c9own_controls()
# Mechanisms that are not one assertion's: each has to fail on some assertion
# of the ownership block.
C9OWN_MUTANTS += [
    ("response_valid_by_current_address",
     "    assign up_imem_rvalid = im_out && (im_owner ? i_rvalid : dn_imem_rvalid);",
     "    assign up_imem_rvalid = im_out && (im_sel ? i_rvalid : dn_imem_rvalid);"),
    ("response_data_by_current_address",
     "    assign up_dmem_rdata = dr_owner ? d_rdata : dn_dmem_rdata;",
     "    assign up_dmem_rdata = dr_sel ? d_rdata : dn_dmem_rdata;"),
    ("owner_latched_one_cycle_late", [
        ("    reg im_out, dr_out;              // a read is outstanding on the channel\n",
         "    reg im_out, dr_out;              // a read is outstanding on the channel\n    reg mut_acc, mut_sel;\n"),
        ("            im_out <= 0; dr_out <= 0;\n", "            im_out <= 0; dr_out <= 0; mut_acc <= 0;\n"),
        ("            if (up_imem_arvalid && up_imem_arready) begin im_owner <= im_sel; im_out <= 1; end\n",
         "            if (mut_acc) im_owner <= mut_sel;\n"
         "            mut_acc <= up_imem_arvalid && up_imem_arready; mut_sel <= im_sel;\n"
         "            if (up_imem_arvalid && up_imem_arready) im_out <= 1;\n")]),
    ("write_owner_not_latched",
     "            if (up_dmem_awvalid && up_dmem_awready) begin dw_owner <= dw_sel; dw_active <= 1; end",
     "            if (up_dmem_awvalid && up_dmem_awready) begin dw_active <= 1; end"),
    ("imem_outstanding_cleared_by_any_beat",
     "            if (up_imem_rvalid && up_imem_rready && up_imem_rlast) im_out <= 0;",
     "            if (up_imem_rvalid && up_imem_rready) im_out <= 0;"),
    ("dmem_outstanding_cleared_by_any_beat",
     "            if (up_dmem_rvalid && up_dmem_rready && up_dmem_rlast) dr_out <= 0;",
     "            if (up_dmem_rvalid && up_dmem_rready) dr_out <= 0;"),
    ("read_id_sides_swapped",
     "    assign up_dmem_rid = dr_owner ? d_rid : dn_dmem_rid;",
     "    assign up_dmem_rid = dr_owner ? dn_dmem_rid : d_rid;"),
    ("rlast_forced",
     "    assign up_imem_rlast = im_owner ? i_rlast : dn_imem_rlast;",
     "    assign up_imem_rlast = 1'b1;"),
    ("downstream_read_error_reported_okay",
     "    assign up_imem_rresp = im_owner ? i_rresp : dn_imem_rresp;",
     "    assign up_imem_rresp = im_owner ? i_rresp : 2'b00;"),
    ("downstream_write_error_reported_okay",
     "    assign up_dmem_bresp = dw_owner ? d_bresp : dn_dmem_bresp;",
     "    assign up_dmem_bresp = dw_owner ? d_bresp : 2'b00;"),
    # the router's decode against the block's: part of the island's range goes downstream
    ("sram_range_routed_downstream",
     "                        ({32'b0, a} >= {32'b0, SRAM_BASE} && {32'b0, a} < {32'b0, SRAM_END});",
     "                        ({32'b0, a} >= {32'b0, SRAM_BASE} && {32'b0, a} < {32'b0, SRAM_BASE});"),
    ("last_rom_word_routed_downstream",
     "            in_island = ({32'b0, a} >= {32'b0, ROM_BASE} && {32'b0, a} < {32'b0, ROM_END}) ||",
     "            in_island = ({32'b0, a} >= {32'b0, ROM_BASE} && {32'b0, a} < {32'b0, ROM_END} - 64'd8) ||"),
]
LEMMAS["C9own"] = dict(
    module="karudbg_island", src="dbg/karudbg_island.v",
    block=["test/dbg/formal/c9_karudbg_island.vh", C9OWN_BLOCK], own_block=C9OWN_BLOCK,
    extra=["dbg/karudbg_axi.v"], defines=[], chparams=["SRAM_END 32'h00020040"],
    # The controls run with an 8-word ROM as well: the model of the default
    # ROM takes a minute to build and to load, and there are 56 of them.
    # ROM_END goes first, so that no model is elaborated with the default ROM.
    mutant_chparams=["ROM_END 32'h00010040", "SRAM_END 32'h00020040"], defer=True,
    # The port connections of the bridges that the block names (see probed()).
    probes={"f_i_rready": ("i_bridge", "s_rready"), "f_d_rready": ("d_bridge", "s_rready"),
            "f_d_bready": ("d_bridge", "s_bready")},
    bmc=12, induct=6, bounded_define="FORMAL_BOUNDED", strengthen_define="FORMAL_STRENGTHEN",
    claim="island, every C9 property, and with ghost state that reads neither the router's flags nor "
          "its address decode: the destination of each accepted address (imem read, dmem read, dmem "
          "write) is remembered until the next one is accepted; in every cycle outside reset, with no "
          "transaction outstanding no response beat is presented to the core and none is taken from "
          "downstream; during the island's transaction the core is shown a beat exactly when the island "
          "bridge offers one, with that beat's ID, data, response code and LAST, the bridge sees the "
          "core's READY and downstream sees none; during a downstream transaction the same with the "
          "two sources swapped. Burst lengths, stalls and the downstream responses are unconstrained; "
          "the assumptions are C9's (one outstanding transaction per channel, no reset after the first "
          "cycle)",
    mutants=C9OWN_MUTANTS, expect=C9OWN_EXPECT)

# ---- C5w: the hardware window limit of karudbg_auth (WINDOW_LOG2) ----
# C5's block and the window block together, so every C5 property is proved
# again with the timer present. C5 itself has the default WINDOW_LOG2 = 0 and
# says nothing of a window that closes by itself: C5w0 proves that it does not.
WIN_COUNT = "if (win_open && !win_cnt[WINDOW_LOG2]) win_cnt <= win_cnt + 1'b1;"
WIN_EXPIRE = "assign win_expire = (WINDOW_LOG2 != 0) && win_open && win_cnt[WINDOW_LOG2];"
WIN_BLOCK = "        !win_expire &&\n"
WIN_CLOSE = "|| reset_close || win_expire ||"
WIN_RESET = "            win_cnt <= {(WINDOW_LOG2+1){1'b0}};\n"
WIN_LAST = "(win_open && (&win_cnt[WINDOW_LOG2-1:0]))"     # clock 2^WINDOW_LOG2 of the window
WIN_FULL = "(win_open && win_cnt[WINDOW_LOG2])"            # win_expire without its WINDOW_LOG2 != 0
WINDOW_MUTANTS = [
    ("window_never_expires", WIN_EXPIRE, "assign win_expire = 1'b0;"),
    ("unlock_in_the_expiry_clock", WIN_BLOCK, "        1'b1 &&\n"),
    ("expiry_does_not_close", WIN_CLOSE, "|| reset_close ||"),
    ("window_one_clock_short", WIN_COUNT,
     "if (win_open && !win_cnt[WINDOW_LOG2]) win_cnt <= win_cnt + (win_cnt == 0 ? 2 : 1);"),
    # the limit is 2^WINDOW_LOG2 + 1: the counter runs on and one more bit is compared
    ("window_one_clock_long", [
        (WIN_COUNT, "if (win_open) win_cnt <= win_cnt + 1'b1;"),
        (WIN_EXPIRE, "assign win_expire = (WINDOW_LOG2 != 0) && win_open && win_cnt[WINDOW_LOG2] && win_cnt[0];")]),
    ("window_restarts_with_the_hart", WIN_COUNT, "if (core_in_reset_i) win_cnt <= 0; else " + WIN_COUNT),
    ("window_pauses_in_hart_reset", WIN_COUNT,
     "if (win_open && !core_in_reset_i && !win_cnt[WINDOW_LOG2]) win_cnt <= win_cnt + 1'b1;"),
    ("window_counts_from_por", WIN_COUNT,
     "if (lc_auth && !boot_done_q && !win_cnt[WINDOW_LOG2]) win_cnt <= win_cnt + 1'b1;"),
    ("window_counter_not_reset", WIN_RESET, ""),
    # The two halves of an early expiry, one at a time: (c) and (d) of the block.
    ("unlock_refused_one_clock_early", WIN_BLOCK, f"        !win_expire && !{WIN_LAST} &&\n"),
    ("window_closes_one_clock_early", WIN_CLOSE, f"|| reset_close || win_expire || {WIN_LAST} ||"),
]
# WINDOW_LOG2 = 0: the timer is not off (a window of one clock), then its two halves.
WINDOW_OFF_MUTANTS = [
    ("limit_not_off", WIN_EXPIRE, f"assign win_expire = {WIN_FULL};"),
    ("unlock_refused_with_no_limit", WIN_BLOCK, f"        !{WIN_FULL} &&\n"),
    ("window_closes_with_no_limit", WIN_CLOSE, f"|| reset_close || {WIN_FULL} ||"),
]


def window_lemma(log2, bmc, mutants):
    return dict(
        module="karudbg_auth", src="dbg/karudbg_auth.v",
        block=["test/dbg/formal/c5_karudbg_auth.vh", "test/dbg/formal/c5w_karudbg_auth.vh"],
        extra=[], defines=[], chparams=[f"WINDOW_LOG2 {log2}"], bmc=bmc, induct=3,
        strengthen_define="FORMAL_STRENGTHEN",
        claim=f"karudbg_auth with WINDOW_LOG2={log2}: every C5 property, and, from ports and "
              "ghost state: the request is recorded exactly by the edge that accepts the REQUEST; "
              + ("with a ghost count of the clocks since that edge, boot_done is set on the edge "
                 "after 2^WINDOW_LOG2 such clocks; the grant rises neither on that edge nor later; "
                 "on each earlier edge the commit predicate sets the grant; before that edge "
                 "boot_done is set only by a closing event of C5; nothing but POR restarts the count"
                 if log2 else
                 "there is no limit in hardware: on every edge the commit predicate sets the grant, "
                 "and boot_done is set only by a closing event of C5"),
        mutants=mutants)


# A control is a trace from POR through the whole window: 2^WINDOW_LOG2 + 5
# steps. The value of the VCU118 image, 31, is out of reach for all of them
# but the reset of the counter; its induction is as short as the others'.
LEMMAS["C5w0"] = window_lemma(0, 12, WINDOW_OFF_MUTANTS)
LEMMAS["C5w1"] = window_lemma(1, 10, WINDOW_MUTANTS)
LEMMAS["C5w3"] = window_lemma(3, 16, WINDOW_MUTANTS)
LEMMAS["C5w31"] = window_lemma(31, 12, [m for m in WINDOW_MUTANTS if m[0] == "window_counter_not_reset"])


def observed(cfg, text):
    """A formal-only copy of a module with f_obs_o = {the registers in cfg["observe"]}."""
    if not cfg.get("observe"):
        return text
    anchor = cfg["observe_after"]
    if text.count(anchor) != 1:
        raise RuntimeError(f"observe: anchor not unique in {cfg['mutate']}")
    # The new port goes after the anchor's port name, before any comment.
    head, sep, tail = anchor.partition("//")
    text = text.replace(anchor, head.rstrip() + ",  " + sep + tail.rstrip("\n")
                        + "\n    output wire [63:0] f_obs_o   // formal-only copy\n")
    i = text.rindex("endmodule")
    return text[:i] + "    assign f_obs_o = {" + ", ".join(cfg["observe"]) + "};\n" + text[i:]


def splice(text, block):
    i = text.rindex("endmodule")
    return text[:i] + "`ifdef FORMAL\n" + block + "`endif\n" + text[i:]


def probed(cfg, text):
    """A build copy in which the port connections named by cfg["probes"]
    (wire: (instance, port)) are wires: ".port(expression)" of that instance
    becomes ".port(wire)", and "wire <wire> = expression;" is declared before
    the instance. The expression is the one in the text, a mutant's included,
    so the wire is the net the instance sees and a property block can name
    it (a hierarchical name would be a new free wire)."""
    for wire, (inst, port) in cfg.get("probes", {}).items():
        heads = list(re.finditer(r"^[^\n;]*\b" + inst + r" \(\n", text, re.M))
        if len(heads) != 1:
            raise RuntimeError(f"probe {wire}: instance {inst} not found once in {cfg['src']}")
        start, end = heads[0].start(), text.index(");", heads[0].end())
        ports = list(re.finditer(r"\." + port + r"\(", text[heads[0].end():end]))
        if len(ports) != 1:
            raise RuntimeError(f"probe {wire}: port {port} of {inst} not found once in {cfg['src']}")
        a = heads[0].end() + ports[0].end()
        b, depth = a, 1
        while depth:
            depth += (text[b] == "(") - (text[b] == ")")
            b += 1
        expr = text[a:b - 1]
        text = (text[:start] + f"    wire {wire} = {expr};   // formal-only copy: .{port} of {inst}\n"
                + text[start:a] + wire + text[b - 1:])
    return text


def asserts(text):
    """Every assert(...) of a property block, comments ignored: (line, expression)."""
    s = re.sub(r"//[^\n]*", lambda m: " " * len(m.group()), text)
    found = []
    for m in re.finditer(r"\bassert\s*\(", s):
        i, depth = m.end(), 1
        while depth and i < len(s):
            depth += (s[i] == "(") - (s[i] == ")")
            i += 1
        found.append((s.count("\n", 0, m.start()) + 1, " ".join(s[m.end():i - 1].split())))
    return found


def without(text, defines):
    """A block with the lines under `ifdef <one of the defines> blanked (not nested)."""
    for d in defines:
        text = re.sub(r"`ifdef " + d + r"\b.*?`endif", lambda m: "\n" * m.group().count("\n"), text, flags=re.S)
    return text


def assert_lines(text, parts):
    """Line of the build copy splice(text, blocks) -> (block file, line in it,
    expression), for every assert() of the blocks ((file, text) in order)."""
    line, found = text[:text.rindex("endmodule")].count("\n") + 2, {}
    for name, block in parts:
        if not block.endswith("\n"):
            raise RuntimeError(f"{name}: no newline at the end of the block")
        for l, expr in asserts(block):
            found[line + l - 1] = (name, l, expr)
        line += block.count("\n")
    return found


def failed_asserts(log, copy, lines):
    """What a yosys-smtbmc log says failed: the step, and the assertions as
    (block file, line, expression) where the line is one of a block's."""
    text = log.read_text()
    steps = re.findall(r"Checking assertions in step (\d+)", text)
    hits = sorted(set((path, int(line)) for path, line in re.findall(r"Assert failed in [^:]+: (\S+?):(\d+)", text)))
    return (int(steps[-1]) if steps else None,
            [lines.get(line, (Path(path).name, line, "?")) if Path(path) == copy else (Path(path).name, line, "?")
             for path, line in hits])


def controls_blocks(parts, own):
    """The blocks for the mutant runs of a lemma with "own_block": every
    other block keeps its assumptions and ghost state, and its assertions
    become cover statements (not checked by BMC), line for line."""
    return [(name, text if name == own else re.sub(r"\bassert(\s*\()", r"cover\1", text)) for name, text in parts]


def smt2(lemma, cfg, out, text, tag, defines, replace=None, chparams=None):
    out.mkdir(parents=True, exist_ok=True)
    copy = out / f"{tag}.v"
    copy.write_text(text)
    flags = " ".join(f"-D{d}" for d in ["FORMAL"] + cfg["defines"] + defines)
    files = (core_rtl() if cfg["extra"] == "CORE_RTL" else
             dbg_core_rtl() if cfg["extra"] == "DBG_CORE_RTL" else cfg["extra"])
    extra = " ".join(str((replace or {}).get(e, ROOT / e)) for e in files)
    chp = "\n".join(f"chparam -set {p} {cfg['module']}" for p in (cfg["chparams"] if chparams is None else chparams))
    # "defer": the module is elaborated when its parameters are set, not
    # before with the default ones as well (the island's ROM initialisation
    # takes 20 s each time).
    defer = "-defer " if cfg.get("defer") else ""
    script = (f"read_verilog -sv -formal {defer}{flags} -I{ROOT}/dbg -I{ROOT}/rtl {copy} {extra}\n"
              f"{chp}\n"
              + (f"hierarchy -top {cfg['module']}\nproc\n"
                 f"cutpoint {cfg['module']}/t:* {cfg['module']}/t:$* %d {cfg['module']}/t:$paramod* %u"
                 + "".join(f" {cfg['module']}/t:{k} %d" for k in cfg.get("cut_keep", [])) + "\n"
                 f"hierarchy -top {cfg['module']}\nopt_clean\n" if cfg.get("cut_submodules")
                 else f"prep -top {cfg['module']}\n")
              + "async2sync\ndffunmap\n"
              f"write_smt2 -wires {out / (tag + '.smt2')}\n")
    (out / f"{tag}.ys").write_text(script)
    r = subprocess.run(["yosys", "-q", "-l", str(out / f"{tag}.yosys.log"), str(out / f"{tag}.ys")],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        raise RuntimeError(f"{lemma} {tag}: yosys failed; see {out / (tag + '.yosys.log')}")
    # A name Yosys does not know, such as a hierarchical reference into a
    # submodule, becomes a new free wire: an assertion over it proves nothing.
    if "is implicitly declared" in (out / f"{tag}.yosys.log").read_text():
        raise RuntimeError(f"{lemma} {tag}: an identifier is implicitly declared; see {out / (tag + '.yosys.log')}")
    return out / f"{tag}.smt2"


def smtbmc(model, depth, induct, log, timeout):
    cmd = ["yosys-smtbmc", "-s", "z3", "-t", str(depth)]
    if induct:
        cmd.insert(1, "-i")
    cmd.append(str(model))
    t0 = time.monotonic()
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    text = r.stdout.replace("\r", "\n")
    log.write_text(text)
    status = re.findall(r"Status: (\w+)", text)
    return (status[-1] if status else "UNKNOWN"), round(time.monotonic() - t0, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="_build/dbg/auth-formal")
    parser.add_argument("--timeout", type=int, default=2400)
    parser.add_argument("lemmas", nargs="*", default=sorted(LEMMAS))
    args = parser.parse_args()
    results, ok = {}, True
    for name in args.lemmas:
        cfg = LEMMAS[name]
        out = (ROOT / args.out / name).resolve()
        src = (ROOT / cfg["src"]).read_text()
        # "block" is one property file, or several spliced in the order given.
        parts = [(b, (ROOT / b).read_text()) for b in
                 ([cfg["block"]] if isinstance(cfg["block"], str) else cfg["block"])]
        block = "".join(text for _, text in parts)
        own = cfg.get("own_block")
        # In the mutant runs of a lemma with an own block, only its assertions are checked.
        mparts = controls_blocks(parts, own) if own else parts
        mblock = "".join(text for _, text in mparts)
        rec = {"claim": cfg["claim"], "bmc_depth": cfg["bmc"], "induction_depth": cfg["induct"]}
        bounded = [cfg["bounded_define"]] if "bounded_define" in cfg else []
        # A strengthening invariant that names the mutated logic's own state is
        # asserted in the proof runs only: a mutant has to fail without it.
        strengthen = [cfg["strengthen_define"]] if "strengthen_define" in cfg else []
        replace = None
        if cfg.get("observe"):
            out.mkdir(parents=True, exist_ok=True)
            ofile = out / f"observed_{Path(cfg['mutate']).name}"
            ofile.write_text(observed(cfg, (ROOT / cfg["mutate"]).read_text()))
            replace = {cfg["mutate"]: ofile}
        model = smt2(name, cfg, out, splice(probed(cfg, src), block), "proof_bounded", bounded + strengthen, replace)
        rec["bmc"], rec["bmc_s"] = smtbmc(model, cfg["bmc"], False, out / "bmc.log", args.timeout)
        if cfg["induct"]:
            model = smt2(name, cfg, out, splice(probed(cfg, src), block), "proof", strengthen, replace)
            rec["induction"], rec["induction_s"] = smtbmc(model, cfg["induct"], True,
                                                          out / "induction.log", args.timeout)
        rec["mutants"] = {}
        for mutant in cfg["mutants"]:
            mname = mutant[0]
            edits = mutant[1] if len(mutant) == 2 else [(mutant[1], mutant[2])]
            # A mutant edits the lemma's module, or the file named by "mutate"
            # (for a miter, the module it instantiates twice).
            target = cfg.get("mutate", cfg["src"])
            msrc = src if target == cfg["src"] else (ROOT / target).read_text()
            for before, after in edits:
                if msrc.count(before) != 1:
                    raise RuntimeError(f"{name} mutant {mname}: site not unique in {target}")
                msrc = msrc.replace(before, after)
            if target == cfg["src"]:
                mtext = probed(cfg, msrc)
                mmodel = smt2(name, cfg, out / "mutants", splice(mtext, mblock), mname, [],
                              chparams=cfg.get("mutant_chparams"))
            else:
                mtext = src
                (out / "mutants").mkdir(parents=True, exist_ok=True)
                mfile = out / "mutants" / f"{mname}_{Path(target).name}"
                mfile.write_text(observed(cfg, msrc))
                mmodel = smt2(name, cfg, out / "mutants", splice(src, mblock), mname, [], {target: mfile},
                              chparams=cfg.get("mutant_chparams"))
            status, secs = smtbmc(mmodel, cfg["bmc"], False, out / "mutants" / f"{mname}.log", args.timeout)
            step, failed = failed_asserts(out / "mutants" / f"{mname}.log", out / "mutants" / f"{mname}.v",
                                          assert_lines(mtext, mparts))
            # With an own block: a failure on one of its assertions, and on
            # the one the mutant names if it names one.
            want = cfg.get("expect", {}).get(mname)
            hit = [f for f in failed if f[0] == own and (want is None or f[2] == want)]
            rec["mutants"][mname] = {"status": status, "seconds": secs, "step": step,
                                     "failed": [f"{Path(f[0]).name}:{f[1]}: assert({f[2]})" for f in failed],
                                     "detected": status == "FAILED" and (not own or bool(hit))}
            if want is not None:
                rec["mutants"][mname]["expect"] = want
        good = (rec["bmc"] == "PASSED" and (not cfg["induct"] or rec["induction"] == "PASSED") and
                all(m["detected"] for m in rec["mutants"].values()))
        if own:
            # Every assertion of the own block (the strengthening invariants
            # and the BMC-only ones aside) fails in at least one mutant run.
            claims = asserts(without(dict(parts)[own], strengthen + bounded + ["FORMAL_COVER"]))
            rec["killed"] = {f"{Path(own).name}:{l}: assert({e})":
                             sorted(m for m, r in rec["mutants"].items()
                                    if r["detected"] and f"{Path(own).name}:{l}: assert({e})" in r["failed"])
                             for l, e in claims}
            rec["unkilled"] = sorted(a for a, by in rec["killed"].items() if not by)
            good = good and not rec["unkilled"]
        ok = ok and good
        results[name] = rec
        print(f"{'PASS' if good else 'FAIL'} {name}: BMC {rec['bmc']} (depth {cfg['bmc']}, {rec['bmc_s']} s)"
              + (f", induction {rec['induction']} (k={cfg['induct']}, {rec['induction_s']} s)" if cfg["induct"] else "")
              + "; mutants " + ", ".join(f"{k}={'detected' if v['detected'] else v['status']}"
                                         for k, v in rec["mutants"].items())
              + (f"; {len(rec['killed']) - len(rec['unkilled'])}/{len(rec['killed'])} assertions of "
                 f"{Path(own).name} fail in a mutant run" if own else ""), flush=True)
    (ROOT / args.out).mkdir(parents=True, exist_ok=True)
    (ROOT / args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
