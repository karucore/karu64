#!/usr/bin/env python3
"""Formal lemmas of the debug-authentication plan (doc/debug-auth-plan.md 5.2).

Each lemma's property block (test/dbg/formal/*.vh) is spliced, under
`ifdef FORMAL, into a build copy of its module; the repository RTL is read
only. Every module input is free except the stated assumptions. For each
lemma the runner performs:

  * BMC from reset to the stated depth;
  * k-induction (unbounded proof) where the lemma claims one;
  * BMC of each mutant, which must FAIL, so the proof is not vacuous.

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


def smt2(lemma, cfg, out, text, tag, defines, replace=None):
    out.mkdir(parents=True, exist_ok=True)
    copy = out / f"{tag}.v"
    copy.write_text(text)
    flags = " ".join(f"-D{d}" for d in ["FORMAL"] + cfg["defines"] + defines)
    files = (core_rtl() if cfg["extra"] == "CORE_RTL" else
             dbg_core_rtl() if cfg["extra"] == "DBG_CORE_RTL" else cfg["extra"])
    extra = " ".join(str((replace or {}).get(e, ROOT / e)) for e in files)
    chp = "\n".join(f"chparam -set {p} {cfg['module']}" for p in cfg["chparams"])
    script = (f"read_verilog -sv -formal {flags} -I{ROOT}/dbg -I{ROOT}/rtl {copy} {extra}\n"
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
        block = (ROOT / cfg["block"]).read_text()
        rec = {"claim": cfg["claim"], "bmc_depth": cfg["bmc"], "induction_depth": cfg["induct"]}
        bounded = [cfg["bounded_define"]] if "bounded_define" in cfg else []
        replace = None
        if cfg.get("observe"):
            out.mkdir(parents=True, exist_ok=True)
            ofile = out / f"observed_{Path(cfg['mutate']).name}"
            ofile.write_text(observed(cfg, (ROOT / cfg["mutate"]).read_text()))
            replace = {cfg["mutate"]: ofile}
        model = smt2(name, cfg, out, splice(src, block), "proof_bounded", bounded, replace)
        rec["bmc"], rec["bmc_s"] = smtbmc(model, cfg["bmc"], False, out / "bmc.log", args.timeout)
        if cfg["induct"]:
            model = smt2(name, cfg, out, splice(src, block), "proof", [], replace)
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
                mmodel = smt2(name, cfg, out / "mutants", splice(msrc, block), mname, [])
            else:
                (out / "mutants").mkdir(parents=True, exist_ok=True)
                mfile = out / "mutants" / f"{mname}_{Path(target).name}"
                mfile.write_text(observed(cfg, msrc))
                mmodel = smt2(name, cfg, out / "mutants", splice(src, block), mname, [], {target: mfile})
            status, secs = smtbmc(mmodel, cfg["bmc"], False, out / "mutants" / f"{mname}.log", args.timeout)
            rec["mutants"][mname] = {"status": status, "seconds": secs, "detected": status == "FAILED"}
        good = (rec["bmc"] == "PASSED" and (not cfg["induct"] or rec["induction"] == "PASSED") and
                all(m["detected"] for m in rec["mutants"].values()))
        ok = ok and good
        results[name] = rec
        print(f"{'PASS' if good else 'FAIL'} {name}: BMC {rec['bmc']} (depth {cfg['bmc']}, {rec['bmc_s']} s)"
              + (f", induction {rec['induction']} (k={cfg['induct']}, {rec['induction_s']} s)" if cfg["induct"] else "")
              + "; mutants " + ", ".join(f"{k}={'detected' if v['detected'] else v['status']}"
                                         for k, v in rec["mutants"].items()), flush=True)
    (ROOT / args.out).mkdir(parents=True, exist_ok=True)
    (ROOT / args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
