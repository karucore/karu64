#!/usr/bin/env python3
"""Composition of the debug-authentication lemmas (doc/debug-auth-plan.md
5.3 and 7, milestone A3): a single model for lemma C9 with lemma C10, and
the composition report for claims T1-T4.

1. The single model. The build copy of dbg/karudbg_core.v is the top: the
   real core (rtl/karu64.v, every submodule a free cut point, as in C10)
   and the real island (dbg/karudbg_island.v with its bridges and memories,
   as in C9) on the real nets and the real hart reset. The island's
   downstream response nets and every other instance of karudbg_core are
   free cut points. The island copy carries lemma C9's own property block
   and the core copy lemma C10's own; the runner turns each block's
   assumptions about the other side into assertions and keeps one
   assumption, a reset in the first cycle. A link block compares the
   island's flags with C10's ghost flags. The island copy also carries
   lemma C9own's block (response ownership for the whole transaction,
   ghost state of its own, no assumption). Proved by BMC and k-induction;
   each mutant must fail on a named assertion; cover statements are reached.

2. Glue lemmas (formal/compose_* next to this script): facts that the
   composition needs and that no lemma of the plan states. Each has
   controls. C3n runs the C3 miter with a separate, free next-state input
   of the gate for each of its two DMs; three of its controls must fail
   there and pass with one shared input.

3. One configuration. The lemmas on the core are proved again with lemma
   C1's defines, and the sources of every other lemma are compared after
   preprocessing, so that one configuration is covered by all of them.

4. The report. Every assume() of every property block used by the lemma
   table of run_auth_formal.py, by the glue lemmas and by the single model
   is extracted and matched against the table in this file; so is every
   model restriction (parameters, shared inputs of the C3 miter). Each
   table entry names what discharges it: an assertion of another lemma
   (found in that lemma's block and proved in this run), the single model,
   a glue lemma, a stated platform assumption (quoted from the plan) or the
   hypothesis of the claim. An assumption with no entry, an entry with no
   assumption, a citation that is not found and a cited lemma that did not
   pass all fail the run. Implications between a cited assertion and an
   assumption are checked by the solver, with one control per hypothesis.
   The steps from the lemmas to T1-T4 are listed with their citations;
   every step that is an argument and not a check is marked NOT
   MACHINE-CHECKED.

The lemmas C2-C10 (run_auth_formal.py), C1 (check_auth_bypass.py) and C6
(check_auth_reset.py) are run by this script as they are, each as its own
process; nothing of theirs is changed. The repository RTL is read only;
everything is written under --out, apart from the temporary directories
of the tools under _build/.

Output: <out>/composition-report.txt, <out>/results.json, and one log per
solver or script run under <out>, written as the run goes.

Exit status 0 only if every proof passed, every control failed as it must
and the report has no undischarged assumption. One assumption depends on
the plan's wording of T1 bullet 3 (the report's finding F7): it is
discharged by the wording since 2026-11-19, which the script reads from the
plan, and undischarged with the earlier one (--tx-words-only);
--mailbox-reading accepts the wider reading whatever the plan says.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent


def find_root():
    """The repository: --root, or the nearest directory above this script
    (then above the working directory) that holds dbg/karudbg.f. The script
    works from test/dbg/ and from a staging directory under _build/."""
    for i, a in enumerate(sys.argv):
        if a == "--root" and i + 1 < len(sys.argv):
            return Path(sys.argv[i + 1]).resolve()
        if a.startswith("--root="):
            return Path(a.split("=", 1)[1]).resolve()
    for start in (HERE, Path.cwd().resolve()):
        for d in (start, *start.parents):
            if (d / "dbg/karudbg.f").is_file():
                return d
    sys.exit("run_auth_compose.py: no dbg/karudbg.f above the script or the working directory; give --root")


ROOT = find_root()
# The lemma scripts are imported for their tables only; importing must not
# leave a __pycache__ entry under test/dbg/, nor may the scripts this one runs.
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(ROOT / "test/dbg"))
import run_auth_formal as base      # noqa: E402  the lemma table, read only
import check_auth_bypass as c1      # noqa: E402  lemma C1's tables, read only
import check_auth_reset as c6       # noqa: E402  lemma C6's tables, read only

PLAN = "doc/debug-auth-plan.md"
FORMAL = "test/dbg/formal"                      # the lemmas' property blocks
C9_BLOCK = f"{FORMAL}/c9_karudbg_island.vh"
C10_BLOCK = f"{FORMAL}/c10_karu64.vh"
C9OWN_BLOCK = base.C9OWN_BLOCK                  # lemma C9own's own block, after C9's in the island copy
COMPOSE = HERE / "formal"                       # this script's own blocks, next to it


def rel(path):
    """A path as the report shows it: relative to the repository."""
    p = Path(path)
    return str(p.relative_to(ROOT)) if p.is_absolute() and ROOT in p.parents else str(path)


STATUS_MITER = rel(COMPOSE / "compose_status_miter.v")
LINK_BLOCK = rel(COMPOSE / "compose_c9c10_karudbg_core.vh")
GATE_BLOCK = rel(COMPOSE / "compose_gate_karudbg_auth.vh")
DM_BLOCK = rel(COMPOSE / "compose_dm_karudbg.vh")


# ---------------------------------------------------------------------------
# text
def norm(s):
    return " ".join(s.split())


def read(path):
    return (ROOT / path).read_text()


def calls(text, name):
    """Every name(...) in Verilog text, comments ignored: position, line, expression."""
    s = re.sub(r"//[^\n]*", lambda m: " " * len(m.group()), text)
    found = []
    for m in re.finditer(r"\b" + name + r"\s*\(", s):
        i, depth = m.end(), 1
        while depth and i < len(s):
            depth += (s[i] == "(") - (s[i] == ")")
            i += 1
        found.append(dict(pos=m.start(), line=s.count("\n", 0, m.start()) + 1,
                          expr=norm(s[m.end():i - (depth == 0)])))
    return found


def edit(text, edits, what):
    for before, after in edits:
        if text.count(before) != 1:
            raise RuntimeError(f"{what}: edit site not unique: {before[:70]!r}")
        text = text.replace(before, after)
    return text


def splice(text, block):
    i = text.rindex("endmodule")
    return text[:i] + "`ifdef FORMAL\n" + block + "`endif\n" + text[i:]


def blocks_of(cfg):
    return [cfg["block"]] if isinstance(cfg["block"], str) else list(cfg["block"])


def file_sha256(path):
    """The SHA-256 of a file's bytes, as sha256sum prints it: the report's fingerprints."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sha(*parts):
    """A key over several parts, each followed by a NUL so that their
    boundaries count. Not the SHA-256 of a file: that is file_sha256()."""
    h = hashlib.sha256()
    for p in parts:
        h.update(p.encode() if isinstance(p, str) else p)
        h.update(b"\0")
    return h.hexdigest()


# ---------------------------------------------------------------------------
# tools
def sh(cmd, log, timeout):
    """Run a command with its output going straight to the log, so that a long run can be followed."""
    t0 = time.monotonic()
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "w") as f:
        try:
            rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=timeout, cwd=ROOT).returncode
        except subprocess.TimeoutExpired:
            rc = -9
            f.write("\nTIMEOUT\n")
    return rc, log.read_text(errors="replace"), round(time.monotonic() - t0, 1)


def yosys(work, tag, script, timeout):
    work.mkdir(parents=True, exist_ok=True)
    ys, log = work / f"{tag}.ys", work / f"{tag}.yosys.log"
    ys.write_text(script)
    rc, _, secs = sh(["yosys", "-q", "-l", str(log), str(ys)], work / f"{tag}.yosys.out", timeout)
    if rc:
        raise RuntimeError(f"yosys failed ({rc}); see {log}")
    text = log.read_text()
    # A name Yosys does not know becomes a new free wire: an assertion over
    # it proves nothing (the same refusal as run_auth_formal.py).
    if "is implicitly declared" in text:
        raise RuntimeError(f"an identifier is implicitly declared; see {log}")
    return text, secs


def smtbmc(model, depth, mode, log, timeout, vcd=None):
    cmd = (["yosys-smtbmc", "-s", "z3", "--noprogress", "-t", str(depth)] +
           {"bmc": [], "induction": ["-i"], "cover": ["-c"]}[mode])
    if vcd:
        cmd += ["--dump-vcd", str(vcd)]
    rc, text, secs = sh(cmd + [str(model)], log, timeout)
    status = re.findall(r"Status: (\w+)", text)
    steps = [int(s) for s in re.findall(r"(?:Checking assertions|Trying induction|Checking cover reachability) in step (\d+)", text)]
    return dict(mode=mode, depth=depth, seconds=secs, log=str(log.relative_to(ROOT)),
                status="TIMEOUT" if rc == -9 else (status[-1] if status else "UNKNOWN"),
                last_step=steps[-1] if steps else None,
                failed=sorted(set(re.findall(r"Assert failed in ([^:]+): (\S+?):(\d+)", text))),
                reached=len(re.findall(r"Reached cover statement", text)),
                unreached=len(re.findall(r"Unreached cover statement", text)))


def read_verilog(defines, files):
    flags = " ".join(f"-D{d}" for d in ["FORMAL"] + list(defines))
    return f"read_verilog -sv -formal {flags} -I{ROOT}/dbg -I{ROOT}/rtl {' '.join(str(f) for f in files)}\n"


def smt2_counts(model):
    text = model.read_text()
    return dict(asserts=text.count("; yosys-smt2-assert "), assumes=text.count("; yosys-smt2-assume "),
                covers=text.count("; yosys-smt2-cover "))


def failed_text(failed):
    """(module, file, line) of yosys-smtbmc -> the source line of the build copy."""
    out = []
    for module, path, line in failed:
        try:
            found = [c["expr"] for c in calls(Path(path).read_text(), "assert") if c["line"] == int(line)]
        except OSError:
            found = []
        out.append(dict(module=module.split("\\")[-1].split("/")[-1], file=Path(path).name, line=int(line),
                        expr=found[0] if found else "?"))
    return out


# ---------------------------------------------------------------------------
# 1. The single model for C9 with C10
#
# The interface between the two lemmas: each row is one assume() of one
# lemma's block and the assertion of the other lemma's block that discharges
# it. The runner refuses to build the model unless the blocks' assumptions
# are exactly these (and the reset assumption), so an assumption added to
# either block cannot slip in unproved.
INTERFACE = [
    dict(id="c9.imem-ar", lemma="C9", assume="!(up_imem_arvalid && im_out && !f_i_done)",
         by="C10", guarantee="!(imem_arvalid && f_iout)", flags="im_out = f_iout",
         what="no AR on imem while an imem read is outstanding"),
    dict(id="c9.dmem-ar", lemma="C9", assume="!(up_dmem_arvalid && dr_out && !f_d_done)",
         by="C10", guarantee="!(dmem_arvalid && f_rout)", flags="dr_out = f_rout",
         what="no AR on dmem while a dmem read is outstanding"),
    dict(id="c9.dmem-aw", lemma="C9", assume="!(up_dmem_awvalid && dw_active)",
         by="C10", guarantee="!(dmem_awvalid && f_wact)", flags="dw_active = f_wact",
         what="no AW while a write is outstanding"),
    dict(id="c10.imem-r", lemma="C10", assume="!imem_rvalid || f_iout",
         by="C9", guarantee="!up_imem_rvalid || im_out", flags="f_iout = im_out",
         what="an R beat on imem only for an outstanding read"),
    dict(id="c10.dmem-r", lemma="C10", assume="!dmem_rvalid || f_rout",
         by="C9", guarantee="!up_dmem_rvalid || dr_out", flags="f_rout = dr_out",
         what="an R beat on dmem only for an outstanding read"),
    dict(id="c10.dmem-b", lemma="C10", assume="!dmem_bvalid || f_wact",
         by="C9", guarantee="!up_dmem_bvalid || dw_active", flags="f_wact = dw_active",
         what="a B beat only for an outstanding write"),
]
LINK_EXPR = "f_island_obs[2:0] == f_core_obs"
OBS_ISLAND = "{im_owner, dr_owner, dw_owner, im_out, dr_out, dw_active}"
OBS_CORE = "{f_iout, f_rout, f_wact}"
RESET_ONCE = "always @* if (f_init) assume(rst); else assume(!rst);"
RESET_FIRST = "always @* if (f_init) assume(rst);"
CORE_PORTS_END = "    output wire                     dmem_bready\n);"
ISLAND_PORTS_END = "    input wire dn_dmem_bvalid, output wire dn_dmem_bready\n);"
ISLAND_INST = ".ROM_HEX(ISLAND_ROM_HEX)) island (\n        .clk(clk),"
CORE_INST = "karu64 #(.RESET_PC(RESET_PC),.EXT_TIME(EXT_TIME),.NONSECURE(NONSECURE)) core (\n        .clk(clk),"
CORE_WIRES = "    wire core_rst, halt_req, resume_req, resume_authorized;\n"
SINGLE_BMC, SINGLE_INDUCT = 12, 6


def lemma_mutant(lemma, name):
    m = next(m for m in base.LEMMAS[lemma]["mutants"] if m[0] == name)
    return m[1] if len(m) == 2 else [(m[1], m[2])]


def own_mutant(name, what):
    """A control of lemma C9own that names its assertion, for the single
    model: there, too, it must fail on that assertion of the ownership block."""
    return (name, "island", "dbg/karudbg_island.v", lemma_mutant("C9own", name), what,
            [base.LEMMAS["C9own"]["expect"][name]])


def single_mutants():
    """(name, side, file, edits, what, the assertions one of which must fail)."""
    c9 = {i["id"]: i for i in INTERFACE}
    def both(i):
        return [c9[i]["assume"], c9[i]["guarantee"]]
    return [
        # Lemma C9own in the single model. These five are caught by no other
        # assertion of the model, so the failure is the ownership block's;
        # a control that also breaks C9, C10 or the link is run in lemma
        # C9own, where only the ownership block's assertions are checked.
        own_mutant("imem_r_rid_from_downstream",
                   "the ID of an island fetch's response is taken from downstream"),
        own_mutant("imem_r_rlast_from_island",
                   "RLAST of a downstream burst on imem is the idle island bridge's, which is 1"),
        own_mutant("dmem_b_bresp_from_island",
                   "the response code of a downstream write is the idle island bridge's, OKAY"),
        own_mutant("dmem_r_island_ready_to_non_owner",
                   "the island bridge sees the core's RREADY during a downstream read"),
        own_mutant("dmem_b_downstream_ready_not_the_cores",
                   "downstream sees BREADY for its write whether or not the core is ready"),
        ("imem_ar_repeats", "core", "rtl/karu64.v", lemma_mutant("C10", "imem_ar_repeats"),
         "the core raises ARVALID on imem while a read is outstanding (lemma C10's own control)",
         both("c9.imem-ar")),
        ("dmem_aw_repeats", "core", "rtl/karu64.v", lemma_mutant("C10", "dmem_aw_repeats"),
         "the core raises AWVALID while a write is outstanding (lemma C10's own control)",
         both("c9.dmem-aw")),
        ("dmem_ar_repeats", "core", "rtl/karu64.v",
         [("assign dmem_arvalid = !rd_ar_done && (", "assign dmem_arvalid = (")],
         "the core raises ARVALID on dmem while a read is outstanding", both("c9.dmem-ar")),
        ("imem_lock_released_by_any_beat", "core", "rtl/karu64.v",
         [("    assign im_r_last_fire = imem_rvalid && imem_rready && imem_rlast;",
           "    assign im_r_last_fire = imem_rvalid && imem_rready;")],
         "the imem arbiter gives up its grant on the first beat of a burst, not the last",
         both("c9.imem-ar") + ["f_iout == (im_rd_lock && im_ar_done)"]),
        ("owner_only_mux", "island", "dbg/karudbg_island.v", lemma_mutant("C9", "owner_only_mux"),
         "an external R beat on dmem reaches the core with no read outstanding (lemma C9's own control)",
         both("c10.dmem-r")),
        ("unsolicited_imem_beat", "island", "dbg/karudbg_island.v",
         [("assign up_imem_rvalid = im_out && (im_owner ? i_rvalid : dn_imem_rvalid);",
           "assign up_imem_rvalid = im_owner ? i_rvalid : dn_imem_rvalid;")],
         "an unsolicited external R beat on imem reaches the core (plan 5.4's control for C9)",
         both("c10.imem-r")),
        ("island_flag_not_cleared", "island", "dbg/karudbg_island.v",
         [("            if (up_imem_rvalid && up_imem_rready && up_imem_rlast) im_out <= 0;\n", "")],
         "the island never clears its imem flag, so the two sides disagree on what is outstanding",
         [LINK_EXPR, c9["c9.imem-ar"]["assume"]]),
        ("island_not_reset_with_the_hart", "wiring", "dbg/karudbg_core.v",
         [(ISLAND_INST + " .rst(core_rst),", ISLAND_INST + " .rst(rst),")],
         "the island is reset by POR only, the core by every hart reset: a later reset leaves "
         "the island's flags set", [LINK_EXPR] + [i["assume"] for i in INTERFACE]),
    ]


def own_block():
    """Lemma C9own's own block as it is; it must not assume anything."""
    text = read(C9OWN_BLOCK)
    if calls(text, "assume"):
        raise RuntimeError(f"{C9OWN_BLOCK}: the ownership block has an assumption")
    return text


def single_block(path, lemma):
    """The lemma's own block for the single model: the reset is assumed in
    the first cycle only and every other assumption becomes an assertion."""
    text = read(path)
    if text.count(RESET_ONCE) != 1:
        raise RuntimeError(f"{path}: reset assumption not found as expected")
    text = text.replace(RESET_ONCE, RESET_FIRST)
    turned = []
    for c in reversed(calls(text, "assume")):
        if c["expr"] == "rst":
            continue
        text = text[:c["pos"]] + "assert" + text[c["pos"] + len("assume"):]
        turned.insert(0, c["expr"])
    expected = [i["assume"] for i in INTERFACE if i["lemma"] == lemma]
    if turned != expected:
        raise RuntimeError(f"{path}: assumptions {turned} are not the interface table's {expected}")
    return text


def island_nets():
    """The nets of karudbg_core on the island's downstream response inputs."""
    core = read("dbg/karudbg_core.v")
    inst = core[core.index(ISLAND_INST):]
    inst = inst[:inst.index(");")]
    net = dict(re.findall(r"\.(\w+)\((\w+)\)", inst))
    inputs = re.findall(r"input wire (?:\[[^\]]*\] )?(dn_\w+)", read("dbg/karudbg_island.v"))
    nets = [net[p] for p in inputs]
    if len(nets) != 17 or not all(n.startswith("c_") for n in nets):
        raise RuntimeError(f"unexpected downstream response nets of the island: {nets}")
    return nets


def single_model(work, tag, defines, mutate=None, timeout=1800):
    """Build copies and the SMT model of the single model; returns (path, facts)."""
    work.mkdir(parents=True, exist_ok=True)
    src = {f: read(f) for f in ("rtl/karu64.v", "dbg/karudbg_island.v", "dbg/karudbg_core.v")}
    for f, edits in (mutate or {}).items():
        src[f] = edit(src[f], edits, f"{tag}: {f}")
    core = edit(src["rtl/karu64.v"], [(CORE_PORTS_END, CORE_PORTS_END[:-3] + ",\n    output wire [2:0] f_obs_o\n);")], tag)
    core = splice(core, single_block(C10_BLOCK, "C10") + f"    assign f_obs_o = {OBS_CORE};\n")
    island = edit(src["dbg/karudbg_island.v"],
                  [(ISLAND_PORTS_END, ISLAND_PORTS_END[:-3] + ",\n    output wire [5:0] f_obs_o\n);")], tag)
    # lemma C9own's block after C9's, with the bridges' ready connections named as in the lemma
    island = base.probed(base.LEMMAS["C9own"], island)
    island = splice(island, single_block(C9_BLOCK, "C9") + own_block() + f"    assign f_obs_o = {OBS_ISLAND};\n")
    top = edit(src["dbg/karudbg_core.v"],
               [(ISLAND_INST, ISLAND_INST + " .f_obs_o(f_island_obs),"),
                (CORE_INST, CORE_INST + " .f_obs_o(f_core_obs),"),
                (CORE_WIRES, CORE_WIRES + "    wire [5:0] f_island_obs;\n    wire [2:0] f_core_obs;\n")], tag)
    top = splice(top, read(LINK_BLOCK))
    copies = {"rtl/karu64.v": work / f"{tag}_karu64.v", "dbg/karudbg_island.v": work / f"{tag}_karudbg_island.v",
              "dbg/karudbg_core.v": work / f"{tag}_karudbg_core.v"}
    for f, text in (("rtl/karu64.v", core), ("dbg/karudbg_island.v", island), ("dbg/karudbg_core.v", top)):
        copies[f].write_text(text)
    files = [copies["dbg/karudbg_core.v"]] + [copies.get(f, ROOT / f) for f in base.dbg_core_rtl()]
    nets = island_nets()
    sub = "t:* */t:$* %d */t:$paramod* %u"      # every instance of a user module
    script = (read_verilog(defines, files) +
              "hierarchy -top karudbg_core\nproc\n"
              # the core: every submodule a free cut point, as in lemma C10
              f"cutpoint karudbg_core/c:core %M */{sub} %i\n"
              # karudbg_core: everything but the core and the island
              f"cutpoint karudbg_core/{sub.replace('*/', 'karudbg_core/')} karudbg_core/c:core %d karudbg_core/c:island %d\n"
              # the island's downstream responders: free, as in lemma C9
              f"cutpoint {' '.join('karudbg_core/w:' + n for n in nets)}\n"
              "hierarchy -top karudbg_core\nmemory_collect\nopt_clean\nasync2sync\ndffunmap\n"
              f"write_smt2 -wires {work / (tag + '.smt2')}\n")
    log, secs = yosys(work, tag, script, timeout)
    cells = re.findall(r"Removing cell (\S+), making all cell outputs cutpoints", log)
    wires = re.findall(r"Making wire (\S+) a cutpoint", log)
    kept = [c for c in cells if c.split(".")[-1] in ("core", "island")]
    if kept or sorted(w.split(".")[-1] for w in wires) != sorted(nets):
        raise RuntimeError(f"{tag}: unexpected cut points: {kept} {wires}")
    facts = dict(yosys_seconds=secs, defines=list(defines),
                 cut_cells=sorted(c.split("\\")[-1] for c in cells),
                 cut_nets=sorted(w.split(".")[-1] for w in wires), **smt2_counts(work / f"{tag}.smt2"))
    return work / f"{tag}.smt2", facts


def single_proof(out, config, defines, timeout):
    """BMC (with C9's BMC-only bridge assertions) and k-induction of one configuration."""
    work = out / "c9c10" / config
    res = dict(config=config)
    # FORMAL_STRENGTHEN: the ownership block's invariants, in the proof runs only
    model, facts = single_model(work, "proof_bounded", list(defines) + ["FORMAL_BOUNDED", "FORMAL_STRENGTHEN"])
    res["bmc"] = dict(smtbmc(model, SINGLE_BMC, "bmc", work / "bmc.log", timeout), **facts)
    model, facts = single_model(work, "proof", list(defines) + ["FORMAL_STRENGTHEN"])
    res["induction"] = dict(smtbmc(model, SINGLE_INDUCT, "induction", work / "induction.log", timeout), **facts)
    for r in (res["bmc"], res["induction"]):
        r["failed"] = failed_text(r["failed"])
    # nothing but the first-cycle reset is assumed: one assume() per block
    res["ok"] = (res["bmc"]["status"] == "PASSED" and res["induction"]["status"] == "PASSED" and
                 res["bmc"]["assumes"] == 2 and res["induction"]["assumes"] == 2)
    return res


def single_cover(out, defines, timeout):
    work = out / "c9c10" / "cover"
    model, facts = single_model(work, "cover", list(defines) + ["FORMAL_COVER"])
    res = dict(smtbmc(model, SINGLE_BMC, "cover", work / "cover.log", timeout), **facts)
    res["ok"] = res["status"] == "PASSED" and res["unreached"] == 0 and res["reached"] == res["covers"] > 0
    return res


def single_mutant(out, defines, mutant, timeout):
    name, side, path, edits, what, expect = mutant
    work = out / "c9c10" / "mutants"
    model, facts = single_model(work, name, defines, {path: edits})
    res = dict(smtbmc(model, SINGLE_BMC, "bmc", work / f"{name}.log", timeout, vcd=work / f"{name}.vcd"),
               side=side, file=path, what=what, expect=expect, yosys_seconds=facts["yosys_seconds"])
    res["failed"] = failed_text(res["failed"])
    res["detected"] = res["status"] == "FAILED" and any(f["expr"] in expect for f in res["failed"])
    return res


# ---------------------------------------------------------------------------
# 2. Glue lemmas: module-level, in the style of run_auth_formal.py
LOCKED = "assume(!debug_enable_i && !debug_enable_next_i);"
LOCKED_NOW = "if (!f_init) assume(!debug_enable_i);"


def next_free(text):
    """C2's or C3's block with debug_enable_next_i free and the gate assumed
    closed in every cycle after the POR cycle (not in the POR cycle)."""
    return edit(text, [(LOCKED, LOCKED_NOW)], "C2n/C3n")


SPLIT = "C3_SPLIT_NEXT"         # the C3 miter with a next-state input of the gate for each DM
# The gate's next state made visible to a locked debugger: in the read data,
# in the handshake and in the response code. Two DMs with one shared
# next-state input cannot differ in it, so these pass there.
C3N_SPLIT_MUTANTS = [
    ("next_state_in_locked_dmstatus", "                7'h11: dmi_read = {25'b0, auth_busy, 6'h03};",
     "                7'h11: dmi_read = {24'b0, dbg_en_next, auth_busy, 6'h03};"),
    ("next_state_stalls_the_dmi", "    assign req_ready_o = !rst && !dmi_reset_i && (!resp_valid_o || resp_ready_i);",
     "    assign req_ready_o = !rst && !dmi_reset_i && (!resp_valid_o || resp_ready_i) && !(dbg_en_next && !dbg_en);"),
    ("next_state_in_the_response_op", "                resp_op_o <= req_op_i == 3 ? 2'b10 : 2'b00;",
     "                resp_op_o <= (req_op_i == 3 || (dbg_en_next && !dbg_en)) ? 2'b10 : 2'b00;"),
]


def miter_inputs(split):
    """The shared inputs of the C3 miter (the others are a_ and b_ pairs), as
    lemma C3 builds it or, split, as glue lemma C3n does (C3_SPLIT_NEXT)."""
    miter = read(base.LEMMAS["C3"]["src"])
    start = miter.index("module karudbg_c3")
    header = re.sub(r"`ifdef " + SPLIT + r"\n(.*?)`else\n(.*?)`endif\n", lambda m: m.group(1 if split else 2),
                    miter[start:miter.index(");", start)], flags=re.S)
    if "`" in header:
        raise RuntimeError("the C3 miter's port list has a directive this script does not know")
    names = [s for line in re.findall(r"input wire (?:\[[^\]]*\] )?([^\n/]*)", header) for s in re.findall(r"\w+", line)]
    return [s for s in names if not s.startswith(("a_", "b_"))], [s for s in names if s.startswith(("a_", "b_"))]


def glue_table():
    c2, c3 = base.LEMMAS["C2"], base.LEMMAS["C3"]
    return {
        "gate": dict(
            module="karudbg_auth", src="dbg/karudbg_auth.v", block=GATE_BLOCK, extra=[], defines=[],
            variants=[[], ["WINDOW_LOG2 3"], ["WINDOW_LOG2 31"]], bmc=3, induct=0,
            claim="karudbg_auth, from an arbitrary state with every input free, in every cycle whose "
                  "previous cycle was not a POR cycle: debug_enable_o is the previous debug_enable_next_o; "
                  "authbusy_o is 1 exactly after an authdata access forwarded by an active DM; lc_auth_o "
                  "does not change. After a POR cycle lc_auth_o is (lc_i == AUTH) as sampled",
            mutants=[("next_held_one_clock", "    assign debug_enable_next_o = debug_enable_d;",
                      "    assign debug_enable_next_o = debug_enable_d || debug_enable_o;"),
                     ("gate_falls_one_clock_late", "            debug_enable_o <= debug_enable_d;",
                      "            debug_enable_o <= debug_enable_d || (debug_enable_o && fw_lock_set);"),
                     ("authbusy_follows_the_hart", "            authbusy_o <= dmi_valid_i && !session_reset;",
                      "            authbusy_o <= (dmi_valid_i && !session_reset) || rom_pop;"),
                     ("authdata_withdrawn_after_boot", "    assign lc_auth_o = lc_auth;",
                      "    assign lc_auth_o = lc_auth && !boot_done_q;")]),
        "dm": dict(
            module="karudbg", src="dbg/karudbg.v", block=DM_BLOCK, extra=c2["extra"], defines=c2["defines"],
            variants=[[]], bmc=4, induct=0,
            claim="karudbg, from an arbitrary state with every input free and no assumption: (a) in the "
                  "first cycle after a POR cycle no DM output is asserted, the command engine is idle, no "
                  "DMI response is offered and a closed gate shows the hart only the safe sequence; (b) a "
                  "read of dmcontrol or dmstatus accepted in any locked cycle returns the locked view",
            mutants=[("ndmreset_resets_to_1",
                      "        if (rst) begin\n            dmactive_q <= 0;\n            deact_pending_q <= 0;\n"
                      "            halt_q <= 0;\n            ndmreset_q <= 0;",
                      "        if (rst) begin\n            dmactive_q <= 0;\n            deact_pending_q <= 0;\n"
                      "            halt_q <= 0;\n            ndmreset_q <= 1;"),
                     ("safe_sequence_removed",) + tuple(lemma_mutant("C2", "safe_sequence_removed")[0]),
                     ("hart_state_in_locked_dmstatus",) + tuple(lemma_mutant("C3", "hart_state_in_locked_dmstatus")[0]),
                     ("hart_state_in_locked_dmcontrol",
                      "            case (req_addr_i)\n                7'h10: dmi_read = {31'b0, dmactive_q};\n"
                      "                7'h11: dmi_read = {25'b0, auth_busy, 6'h03};",
                      "            case (req_addr_i)\n                7'h10: dmi_read = {30'b0, hart_halted_i, dmactive_q};\n"
                      "                7'h11: dmi_read = {25'b0, auth_busy, 6'h03};")]),
        # C2 and C3 again, with one assumption fewer: debug_enable_next_i is
        # free, and the gate is assumed closed only after the POR cycle. The
        # blocks, depths and controls are the lemmas' own.
        "C2n": dict(c2, derive=next_free, variants=[[]],
                    claim="lemma C2's assertions with debug_enable_next_i free: the gate closed in every "
                          "cycle after the POR cycle is the only assumption besides the reset"),
        # C3n: the miter with C3_SPLIT_NEXT, a next-state input for each DM.
        # "contrast": these controls are run again on the miter without it
        # and must pass there, so that it is the separate inputs that catch them.
        "C3n": dict(c3, derive=next_free, variants=[[]], defines=list(c3["defines"]) + [SPLIT],
                    mutants=list(c3["mutants"]) + C3N_SPLIT_MUTANTS,
                    contrast=dict(without=SPLIT, mutants=[m[0] for m in C3N_SPLIT_MUTANTS]),
                    claim="lemma C3's assertions with debug_enable_next_i free and separate for each of the "
                          "two DMs (the miter with C3_SPLIT_NEXT): the gate closed in both in every cycle "
                          "after the POR cycle is the only assumption besides the reset"),
    }


def glue_block(cfg):
    text = "".join(read(b) for b in blocks_of(cfg))
    return cfg["derive"](text) if "derive" in cfg else text


def glue_model(work, tag, cfg, chparams, mutate_edits, bounded):
    """SMT model of a module-level lemma (prep flow, as run_auth_formal.py)."""
    work.mkdir(parents=True, exist_ok=True)
    target = cfg.get("mutate", cfg["src"])          # the file a mutant edits
    replace = {}
    if mutate_edits or cfg.get("observe"):
        text = edit(read(target), mutate_edits or [], f"{tag}: {target}")
        if cfg.get("observe"):
            text = base.observed(cfg, text)
        if target != cfg["src"]:
            replace[target] = work / f"{tag}_{Path(target).name}"
            replace[target].write_text(text)
    src = edit(read(cfg["src"]), mutate_edits or [], tag) if target == cfg["src"] else read(cfg["src"])
    copy = work / f"{tag}.v"
    copy.write_text(splice(src, glue_block(cfg)))
    defines = list(cfg["defines"]) + ([cfg["bounded_define"]] if bounded and "bounded_define" in cfg else [])
    files = [copy] + [replace.get(e, ROOT / e) for e in cfg["extra"]]
    script = (read_verilog(defines, files) +
              "".join(f"chparam -set {p} {cfg['module']}\n" for p in list(cfg.get("chparams", [])) + chparams) +
              f"prep -top {cfg['module']}\nasync2sync\ndffunmap\nwrite_smt2 -wires {work / (tag + '.smt2')}\n")
    yosys(work, tag, script, 900)
    return work / f"{tag}.smt2"


def glue_lemma(out, name, cfg, timeout):
    work = out / "glue" / name
    res = dict(claim=cfg["claim"], module=cfg["module"], runs=[], mutants={})
    for chparams in cfg["variants"]:
        tag = "proof" + "".join("_" + re.sub(r"\W+", "", p) for p in chparams)
        run = dict(chparams=chparams)
        model = glue_model(work, tag + "_bounded", cfg, chparams, None, True)
        run["bmc"] = smtbmc(model, cfg["bmc"], "bmc", work / f"{tag}.bmc.log", timeout)
        run.update(smt2_counts(model))
        if cfg["induct"]:
            model = glue_model(work, tag, cfg, chparams, None, False)
            run["induction"] = smtbmc(model, cfg["induct"], "induction", work / f"{tag}.induction.log", timeout)
        for r in ("bmc", "induction"):
            if r in run:
                run[r]["failed"] = failed_text(run[r]["failed"])
        res["runs"].append(run)
    for m in cfg["mutants"]:
        edits = m[1] if len(m) == 2 else [(m[1], m[2])]
        model = glue_model(work / "mutants", m[0], cfg, [], edits, False)
        r = smtbmc(model, cfg["bmc"], "bmc", work / "mutants" / f"{m[0]}.log", timeout)
        r["failed"] = failed_text(r["failed"])
        r["detected"] = r["status"] == "FAILED"
        res["mutants"][m[0]] = r
    # The named controls again in the model without one define: they must
    # pass there (bounded), or the define is not what catches them.
    contrast = cfg.get("contrast")
    if contrast:
        other = dict(cfg, defines=[d for d in cfg["defines"] if d != contrast["without"]])
        res["contrast"] = dict(without=contrast["without"], mutants={})
        for m in cfg["mutants"]:
            if m[0] in contrast["mutants"]:
                edits = m[1] if len(m) == 2 else [(m[1], m[2])]
                model = glue_model(work / "contrast", m[0], other, [], edits, False)
                r = smtbmc(model, cfg["bmc"], "bmc", work / "contrast" / f"{m[0]}.log", timeout)
                r["failed"] = failed_text(r["failed"])
                res["contrast"]["mutants"][m[0]] = r
    res["ok"] = (all(r["bmc"]["status"] == "PASSED" and r.get("induction", {"status": "PASSED"})["status"] == "PASSED"
                     for r in res["runs"]) and all(m["detected"] for m in res["mutants"].values()) and
                 all(m["status"] == "PASSED" for m in res.get("contrast", {}).get("mutants", {}).values()))
    return res


# ---------------------------------------------------------------------------
# 3a. The existing evidence, run as it is
def base_lemma(out, name, timeout):
    d = out / "lemmas" / name
    rc, text, secs = sh([sys.executable, str(ROOT / "test/dbg/run_auth_formal.py"), "--out", str(d), name],
                        out / "lemmas" / f"{name}.log", timeout)
    res = dict(seconds=secs, rc=rc, log=str((out / "lemmas" / f"{name}.log").relative_to(ROOT)),
               line=next((l for l in text.splitlines() if l.startswith(("PASS", "FAIL"))), ""))
    try:
        res.update(json.loads((d / "results.json").read_text())[name])
    except (OSError, KeyError, ValueError):
        pass
    res["ok"] = (rc == 0 and res.get("bmc") == "PASSED" and
                 (not res.get("induction_depth") or res.get("induction") == "PASSED") and
                 all(m["detected"] for m in res.get("mutants", {}).values()))
    logs = sorted((d / name).glob("*.yosys.log")) if (d / name).is_dir() else []
    res["cut_cells"] = sorted(set(c.split(".")[-1] for l in logs for c in
                                  re.findall(r"Removing cell (\S+), making all cell outputs cutpoints", l.read_text())))
    return res


def base_script(out, name, cmd, timeout):
    log = out / f"{name}.log"
    rc, text, secs = sh([sys.executable] + cmd, log, timeout)
    return dict(ok=rc == 0, rc=rc, seconds=secs, log=str(log.relative_to(ROOT)),
                lines=[l for l in text.splitlines() if l.startswith(("PASS", "FAIL", "detected", "MISSED"))])


def lemma_at(out, name, defines, timeout):
    """A lemma of the table as it is, but with other defines: its block, its
    model flow (run_auth_formal.smt2), its depths and its controls."""
    cfg = dict(base.LEMMAS[name], defines=list(defines))
    work = out / "config" / name
    src, block = read(cfg["src"]), "".join(read(b) for b in blocks_of(cfg))
    model = base.smt2(name, cfg, work, splice(src, block), "proof", [])
    res = dict(defines=list(defines), mutants={},
               bmc=smtbmc(model, cfg["bmc"], "bmc", work / "bmc.log", timeout))
    if cfg["induct"]:
        res["induction"] = smtbmc(model, cfg["induct"], "induction", work / "induction.log", timeout)
    for m in cfg["mutants"]:
        edits = m[1] if len(m) == 2 else [(m[1], m[2])]
        mmodel = base.smt2(name, cfg, work / "mutants", splice(edit(src, edits, f"{name} {m[0]}"), block), m[0], [])
        r = smtbmc(mmodel, cfg["bmc"], "bmc", work / "mutants" / f"{m[0]}.log", timeout)
        res["mutants"][m[0]] = dict(r, detected=r["status"] == "FAILED")
    res["ok"] = (res["bmc"]["status"] == "PASSED" and res.get("induction", {"status": "PASSED"})["status"] == "PASSED"
                 and all(m["detected"] for m in res["mutants"].values()))
    return res


def witness_status(out, timeout):
    """The witness for the open point on T1 bullet 3: BMC of the status
    miter must FAIL, that is, find two runs with the same DM side and the
    same TX pushes whose authdata read data differ."""
    work = out / "witness"
    work.mkdir(parents=True, exist_ok=True)
    yosys(work, "status", read_verilog([], [ROOT / STATUS_MITER, ROOT / "dbg/karudbg_auth.v"]) +
          f"prep -top compose_status_miter\nasync2sync\ndffunmap\nwrite_smt2 -wires {work / 'status.smt2'}\n", 300)
    res = smtbmc(work / "status.smt2", 10, "bmc", work / "status.log", timeout, vcd=work / "status.vcd")
    res["failed"] = failed_text(res["failed"])
    res.update(smt2_counts(work / "status.smt2"), vcd=rel(work / "status.vcd"),
               ok=res["status"] == "FAILED" and bool(res["failed"]))
    return res


def lemma_files(cfg):
    """The RTL files of a module-level lemma: its module and what it instantiates."""
    files = [cfg["src"]] + list(cfg["extra"]) + ([cfg["mutate"]] if "mutate" in cfg else [])
    return sorted(set(f for f in files if not f.startswith(FORMAL)))


def config_sources(out, config):
    """For every lemma that is not proved again with the composition's
    defines: do its RTL files preprocess (iverilog -E, includes expanded) to
    the same text under its own defines and under the composition's? Then
    the lemma's model is the same module in both."""
    work = out / "config" / "sources"
    todo = {f"lemma {n}": (lemma_files(cfg), cfg["defines"]) for n, cfg in base.LEMMAS.items()
            if cfg["module"] not in ("karu64", "karudbg_core")}
    todo["lemma C6"] = (sorted(set(f for m in c6.MODULES.values() for f in m["files"]) | {"dbg/karudbg_core.v"}),
                        [d[2:] for d in c6.DEFINES.split()])
    todo.update({f"glue lemma {n}": (lemma_files(cfg), cfg["defines"]) for n, cfg in glue_table().items()})
    cache = {}

    def pp(path, defines):
        key = (path, tuple(defines))
        if key not in cache:
            tag = f"{Path(path).name}.{sha(' '.join(defines))[:8]}"
            rc, text, _ = sh(["iverilog", "-E", "-o", str(work / f"{tag}.v"), f"-I{ROOT}/dbg", f"-I{ROOT}/rtl"] +
                             [f"-D{d}" for d in defines] + [str(ROOT / path)], work / f"{tag}.log", 120)
            if rc:
                raise RuntimeError(f"iverilog -E failed on {path}: {text[-200:]}")
            cache[key] = (work / f"{tag}.v").read_text().split()       # compared without white space
        return cache[key]
    res = {}
    for name, (files, defines) in todo.items():
        differ = [f for f in files if pp(f, defines) != pp(f, config)]
        res[name] = dict(files=files, defines=list(defines), differ=differ, ok=not differ,
                         image_differ=[f for f in files if pp(f, defines) != pp(f, c1.IMAGE_DEFINES)])
    # control: the comparison sees a define that matters
    res["control"] = dict(ok=pp("dbg/karudbg.v", ["KARU_DBG_AUTH"]) != pp("dbg/karudbg.v", config),
                          what="dbg/karudbg.v with KARU_DBG_AUTH alone must differ from the configuration's")
    return res


# ---------------------------------------------------------------------------
# 3b. Wiring of karudbg_core, read from Yosys's netlist of the module
def wiring_table():
    up = re.findall(r"(?:input|output) wire (?:\[[^\]]*\] )?(up_\w+)", read("dbg/karudbg_island.v"))
    k2 = dict(c1._H_OF_K2, virt_i="auth_virt_o")
    return {
        "gate": ("the DM and the core take the gate, and the DM its next state, from karudbg_auth",
                 [("auth.debug_enable_o", "dm.debug_enable_i"), ("auth.debug_enable_o", "core.debug_enable_i"),
                  ("auth.debug_enable_next_o", "dm.debug_enable_next_i")]),
        "por": ("karudbg_auth and the DM are reset by POR only", [("auth.rst", "rst"), ("dm.rst", "rst")]),
        "hart-reset": ("the core and the island share the hart reset; karudbg_auth sees it and drives into it",
                       [("core.rst", "core_rst"), ("island.rst", "core_rst"), ("auth.core_in_reset_i", "core_rst"),
                        ("auth.sys_reset_o", "auth_reset_o"), ("dm.ndmreset_o", "ndmreset_o")]),
        "debug-mode": ("the core's Debug Mode output is what karudbg_auth and the DM see",
                       [("core.debug_mode_o", "auth.debug_mode_i"), ("core.debug_mode_o", "dm.hart_halted_i")]),
        "K2": ("cut K2: karudbg_auth's hart port is the core's CSR sideband",
               [(f"core.{o}", f"auth.{i}") for i, o in sorted(k2.items())]),
        "K1.mbox": ("the mailbox side of authdata between the DM and karudbg_auth",
                    [("dm.auth_valid_o", "auth.dmi_valid_i"), ("dm.auth_write_o", "auth.dmi_write_i"),
                     ("dm.auth_wdata_o", "auth.dmi_wdata_i"), ("dm.dmactive_o", "auth.dm_active_i"),
                     ("auth.dmi_rdata_o", "dm.auth_rdata_i"), ("auth.authbusy_o", "dm.authbusy_i"),
                     ("auth.lc_auth_o", "dm.lc_auth_i")]),
        "K3": ("cut K3, hart side: the island's upstream ports are the core's imem and dmem ports",
               [(f"core.{p[3:]}", f"island.{p}") for p in up]),
        "run-control": ("the DM's halt and resume requests reach the core",
                        [("dm.halt_req_o", "core.debug_halt_req_i"), ("dm.resume_authorized_o", "core.debug_resume_req_i")]),
    }


def wiring_check(out, defines):
    work = out / "wiring"
    work.mkdir(parents=True, exist_ok=True)
    flags = " ".join(f"-D{d}" for d in defines)
    yosys(work, "core", f"read_verilog -sv {flags} -I{ROOT}/dbg -I{ROOT}/rtl {ROOT / 'dbg/karudbg_core.v'}\n"
          f"hierarchy -top karudbg_core\nproc\nwrite_json {work / 'core.json'}\n", 300)
    module = next(m for n, m in json.loads((work / "core.json").read_text())["modules"].items()
                  if n.endswith("karudbg_core"))

    def bits(name):
        if "." not in name:
            return module["netnames"][name]["bits"]
        inst, port = name.split(".")
        return module["cells"][inst]["connections"][port]
    res = {}
    for group, (what, pairs) in wiring_table().items():
        bad = []
        for a, b in pairs:
            try:
                if bits(a) != bits(b) or not bits(a):
                    bad.append(f"{a} is not {b}")
            except KeyError as e:
                bad.append(f"{a} / {b}: {e} not found")
        res[group] = dict(what=what, pairs=len(pairs), ok=not bad, errors=bad)
    return dict(ok=all(g["ok"] for g in res.values()), groups=res)


# ---------------------------------------------------------------------------
# 3c. Implications between cited assertions and an assumption, by the solver
def idents(expr):
    return set(re.findall(r"[A-Za-z_]\w*", re.sub(r"\d+'[bdhoBDHO][0-9a-fA-F_]+", " ", expr)))


def checks_table():
    """name -> hypotheses, conclusion. A hypothesis or conclusion is
    (kind, where, fragment): an assert() or assume() of a block (the full
    expression is taken from the block), or text of this table."""
    obs = [("f_island_obs", 6, OBS_ISLAND), ("f_core_obs", 3, OBS_CORE)]
    t = {}
    for i in INTERFACE:
        t[i["id"]] = dict(what=f"{i['by']}'s guarantee and the link give {i['lemma']}'s assumption: {i['what']}",
                          hyps=[("assert", i["by"], i["guarantee"]), ("assert", "link", LINK_EXPR)],
                          concl=("assume", i["lemma"], i["assume"]), defs=obs, alias="K3")
    w2 = {"f_lc": 2, "lc_q": 2}
    t["gate.por"] = dict(what="the gate is closed in the cycle after POR unless the sampled lifecycle is OPEN",
                         hyps=[("assert", "C6v", "debug_enable_o == (f_lc == 2'd0 && !f_rev)"),
                               ("text", "hypothesis: lifecycle not OPEN", "f_lc != 2'd0")],
                         concl=("text", "", "!debug_enable_o"), widths=w2)
    t["lc.por"] = dict(what="lc_q is not OPEN after POR unless the sampled lifecycle is OPEN",
                       hyps=[("assert", "C6v", "lc_q == (f_lc == 2'd3 ? 2'd2 : f_lc)"),
                             ("text", "hypothesis: lifecycle not OPEN", "f_lc != 2'd0")],
                       concl=("text", "", "lc_q != 2'd0"), widths=w2)
    t["gate.locked"] = dict(what="the gate is closed while the lifecycle is not OPEN and the grant is 0",
                            hyps=[("assert", "C5", "debug_enable_o == ((lc_q == 2'd0"),
                                  ("text", "hypothesis: lifecycle not OPEN, auth_unlock=0", "lc_q != 2'd0 && !auth_unlock_q")],
                            concl=("text", "", "!debug_enable_o"), widths=w2)
    t["gate.next"] = dict(what="debug_enable_next_o was 0 in the cycle before a cycle with the gate closed",
                          hyps=[("assert", "gate", "debug_enable_o == f_next"), ("text", "the gate is closed", "!debug_enable_o")],
                          concl=("text", "", "!f_next"))
    t["disabled.lc"] = dict(what="lc_q is DISABLED after POR when the sampled lifecycle is DISABLED (2 or 3)",
                            hyps=[("assert", "C6v", "lc_q == (f_lc == 2'd3 ? 2'd2 : f_lc)"),
                                  ("text", "hypothesis: lifecycle DISABLED", "f_lc == 2'd2 || f_lc == 2'd3")],
                            concl=("text", "", "lc_q == 2'd2"), widths=w2)
    t["disabled.grant"] = dict(what="no grant in DISABLED",
                               hyps=[("assert", "C5", "!auth_unlock_q || lc_q == 2'd1"),
                                     ("text", "hypothesis: lifecycle DISABLED", "lc_q == 2'd2")],
                               concl=("text", "", "!auth_unlock_q"), widths=w2)
    t["disabled.gate"] = dict(what="the gate is closed in DISABLED",
                              hyps=[("assert", "C5", "!(lc_q == 2'd2 && debug_enable_o)"),
                                    ("text", "hypothesis: lifecycle DISABLED", "lc_q == 2'd2")],
                              concl=("text", "", "!debug_enable_o"), widths=w2)
    return t


def check_run(work, name, spec, texts, k3):
    """Valid implication, and invalid without any one hypothesis."""
    work.mkdir(parents=True, exist_ok=True)
    hyps, concl = [texts[h] for h in spec["hyps"]], texts[spec["concl"]]
    defs = spec.get("defs", [])
    used = set().union(*(idents(e) for e in hyps + [concl]))
    defs = [d for d in defs if d[0] in used]
    used |= set().union(*(idents(d[2]) for d in defs)) if defs else set()
    alias = {i: c for c, i in k3 if i in used} if spec.get("alias") else {}
    inputs = sorted((used | set(alias.values())) - set(alias) - {d[0] for d in defs})
    width = spec.get("widths", {})

    def module(drop):
        ports = ",\n".join(f"    input wire {'[%d:0] ' % (width[n] - 1) if n in width else ''}{n}" for n in inputs)
        body = "".join(f"    wire {i} = {c};\n" for i, c in sorted(alias.items()))
        body += "".join(f"    wire [{w - 1}:0] {n} = {e};\n" for n, w, e in defs)
        body += "    always @* begin\n"
        body += "".join(f"        assume({h});\n" for j, h in enumerate(hyps) if j != drop)
        return f"module chk (\n{ports}\n);\n{body}        assert({concl});\n    end\nendmodule\n"

    def solve(tag, drop):
        (work / f"{tag}.v").write_text(module(drop))
        yosys(work, tag, f"read_verilog -sv -formal {work / (tag + '.v')}\nprep -top chk\nasync2sync\n"
              f"write_smt2 -wires {work / (tag + '.smt2')}\n", 120)
        return smtbmc(work / f"{tag}.smt2", 1, "bmc", work / f"{tag}.log", 120)["status"]
    res = dict(what=spec["what"], hyps=hyps, concl=concl, alias=alias, valid=solve(name, None),
               controls=[solve(f"{name}.without{j}", j) for j in range(len(hyps))])
    res["ok"] = res["valid"] == "PASSED" and all(c == "FAILED" for c in res["controls"])
    return res


# ---------------------------------------------------------------------------
# 4. The tables of the report
#
# A discharge is a list of references:
#   ("lemma", name, fragment)   an assert() of that lemma's block; the lemma passed in this run
#   ("glue", name, fragment)    the same for a glue lemma of this file (fragment None: the lemma)
#   ("model", fragment)         an assert() of the single model for C9 with C10 (None: the model)
#   ("script", name, text)      C1 or C6, as run by this script
#   ("check", name)             an implication proved by the solver (checks_table)
#   ("wiring", group)           net identities of karudbg_core (wiring_table)
#   ("platform", id)            a stated platform assumption (PLATFORM), quoted from the plan
#   ("hypothesis", claim, text) the hypothesis of the claim itself
#   ("text", file, fragment)    text that must be present in a file
#   ("absent", file, word)      a word that must not occur in a file
#   ("above", text)             discharged by another entry of the same table
#   ("argument", text)          NOT MACHINE-CHECKED: a step of reasoning, never the only reference
def L(lemma, fragment):
    return ("lemma", lemma, fragment)


def G(name, fragment=None):
    return ("glue", name, fragment)


def M(fragment=None):
    return ("model", fragment)


def P(pid):
    return ("platform", pid)


def K(name):
    return ("check", name)


def W(group):
    return ("wiring", group)


def N(text):
    return ("argument", text)


PLATFORM = {
    "P-POR": dict(quotes=["The adversary does **not** control the island, POR, the clock, the lifecycle",
                          "starting from POR, for every adversary"],
                  text="Power-on reset and the clock are outside adversary control (plan 1.2). The claims are "
                       "stated from POR (plan 4): a run starts with a clock in which karudbg_top's rst is 1."),
    "P-LC": dict(quotes=["the integrity of `lc`;", "Platform OTP/lifecycle input, stable from POR"],
                 text="The lifecycle input lc_i is trusted and stable from POR (plan 1.1, 9); revoke_i is a "
                      "trusted platform input (contract 3.4)."),
    "P-ISLAND": dict(quotes=["the island contents and response paths (§1.1);"],
                     text="The island's ROM contents and its response paths are trusted (plan 1.1, 9)."),
    "P-ROM": dict(quotes=["the ROM obligations of §6."],
                  text="The island ROM meets the obligations of plan 6: it decides whether to unlock. Needed "
                       "for the corollary of plan 4, not for T1-T4."),
    "P-TRNG": dict(quotes=["a healthy TRNG;"],
                   text="A healthy entropy source for the challenge nonce (plan 9). Needed for the corollary, "
                        "not for T1-T4."),
    "P-2STATE": dict(quotes=["under 2-state semantics", "gate-level equivalence (a later LEC step can extend it);"],
                     text="The evidence is for the RTL under 2-state, single-clock semantics, at the file "
                          "hashes recorded in this report; not for a gate-level netlist (plan 9)."),
    "P-PHYS": dict(quotes=["Fault injection, glitching, probing and scan access are outside the claim"],
                   text="No fault injection, glitching, probing or scan access (plan 1.2, 9; D6 for scan)."),
}
# Plan 9 lists this as an assumption; it is one no longer.
FORMER = dict(quote="the core's single-outstanding-per-channel contract used by C9;",
              text="Plan 9 lists the core's single-outstanding-per-channel contract as an assumption of the "
                   "evidence. It is proved (lemma C10) and discharged against C9 in one model (section 2).")

POR_FIRST = dict(what="the run starts with a POR cycle", by=[P("P-POR"), ("initials",)], notes=[])
POR_ONCE = dict(
    what="no POR after the first cycle",
    by=[P("P-POR"), ("script", "C6", "after one reset edge from an unknown state every flop of karudbg_auth, "
                                     "karudbg and karudbg_island holds its reset value, or is a listed payload "
                                     "register, memory or POR-sampled value (the last proved by C6v)")],
    notes=[N("a later POR starts a new run: the model's first cycle is a reset cycle from an unconstrained "
             "state, so the part of a real run from its last POR cycle on is a run of the model")])
HART_FIRST = dict(what="the run starts with a hart-reset cycle",
                  by=[L("C6cone", "core_rst"), P("P-POR"), W("hart-reset"), ("initials",)], notes=[])
HART_ONCE = dict(
    what="no hart reset after the first cycle (hart_reset_i is an adversary input)",
    by=[M()],
    notes=[])
GATE = [L("C6v", "debug_enable_o == (f_lc == 2'd0 && !f_rev)"), K("gate.por"),
        L("C6v", "lc_q == (f_lc == 2'd3 ? 2'd2 : f_lc)"), K("lc.por"), L("C5", "lc_q == f_lc"),
        L("C5", "debug_enable_o == ((lc_q == 2'd0"), K("gate.locked"), W("gate")]
GATE_HYP = ("hypothesis", "T1", "lifecycle AUTH or DISABLED and auth_unlock=0 (T4: DISABLED)")
GATE_INDUCTION = N("that the gate stays closed from POR while the grant is 0 is an induction over the "
                   "cycles from these per-cycle facts")


def locked_since_por(variant):
    return dict(
        what="the gate and its next state are 0 in every cycle (locked since POR)",
        by=[GATE_HYP] + GATE + [G("gate", "debug_enable_o == f_next"), K("gate.next"), G(variant)],
        notes=[GATE_INDUCTION,
               N("PARTIAL as stated: in the cycle in which the unlock commits the grant is still 0 and T1 "
                 f"still applies, but debug_enable_next_o is 1. Glue lemma {variant} proves the same "
                 "assertions with debug_enable_next_i free"
                 + (" and separate for each of the two DMs" if variant == "C3n" else "") + ", which covers that cycle"),
               N("the block assumes this in the POR cycle too, where the real gate is arbitrary; "
                 f"{variant} does not")])


def locked_after_por():
    return dict(what="the gate is 0 in every cycle after the POR cycle", by=[GATE_HYP] + GATE, notes=[GATE_INDUCTION])


def interface(i):
    return dict(what=i["what"], by=[L(i["by"], i["guarantee"]), M(i["assume"]), K(i["id"]), W("K3")], notes=[])


def assumptions_table():
    """(source, assume expression) -> discharge. A source is a block file,
    or "derived:<name>" for a block this script derives from one."""
    t = {}
    for f, variant in ((f"{FORMAL}/c2_karudbg.vh", "C2n"), (f"{FORMAL}/c3_karudbg.vh", "C3n")):
        t[f, "rst"], t[f, "!rst"] = POR_FIRST, POR_ONCE
        t[f, "!debug_enable_i && !debug_enable_next_i"] = locked_since_por(variant)
        t[f"derived:{variant}", "rst"], t[f"derived:{variant}", "!rst"] = POR_FIRST, POR_ONCE
        t[f"derived:{variant}", "!debug_enable_i"] = locked_after_por()
    t[f"{FORMAL}/c5_karudbg_auth.vh", "rst"], t[f"{FORMAL}/c5_karudbg_auth.vh", "!rst"] = POR_FIRST, POR_ONCE
    t[f"{FORMAL}/c7_karudbg.vh", "debug_enable_i == f_next"] = dict(
        what="the DM's gate input is its next-state input one clock later",
        by=[G("gate", "debug_enable_o == f_next"), W("gate")],
        notes=[N("the block assumes this in every cycle, the glue lemma proves it for every cycle whose "
                 "previous cycle was not a POR cycle. C7 starts from an arbitrary state, so the part of a "
                 "real run from the first cycle after POR on is a run of C7's model, and C7's assertions "
                 "apply from the second cycle after POR. The first is glue lemma dm (a)")])
    for f, lemma in ((C9_BLOCK, "C9"), (C10_BLOCK, "C10")):
        t[f, "rst"], t[f, "!rst"] = HART_FIRST, HART_ONCE
        t[f"derived:C9C10/{lemma}", "rst"] = HART_FIRST
        for i in INTERFACE:
            if i["lemma"] == lemma:
                t[f, i["assume"]] = interface(i)
    return t


# Shared inputs of the C3 miter: what makes the two runs' value the same.
def miter_table():
    k1 = dict(what="the same DMI inputs in both runs",
              by=[("hypothesis", "T1", "the two runs receive the same DMI inputs"),
                  ("script", "C1", "cut K1 is the DM's DMI port: req_valid_i, req_addr_i, req_op_i, "
                                   "req_data_i, resp_ready_i, dmi_reset_i")], notes=[])
    gate = dict(what="the gate, closed in both runs", by=[("above", "the block's assumption on the gate")], notes=[])
    return {
        "clk": dict(what="one clock", by=[P("P-POR")], notes=[]),
        "rst": dict(what="the same POR", by=[P("P-POR")], notes=[]),
        **{s: k1 for s in c1._sigs("K1")},
        "lc_auth_i": dict(what="the same lifecycle in both runs",
                          by=[G("gate", "lc_auth_o == (f_lc == 2'd1)"), G("gate", "lc_auth_o == f_lcauth"),
                              P("P-LC"), W("K1.mbox")], notes=[]),
        "authbusy_i": dict(
            what="the same authbusy in both runs",
            by=[G("gate", "authbusy_o == f_access"), L("C6v", "err_q == 0 && !tx_full_q && !authbusy_o"),
                L("C3", "a_auth_valid == b_auth_valid && a_auth_write == b_auth_write && a_dmactive == b_dmactive"),
                W("K1.mbox")],
            notes=[N("authbusy in a cycle is a function of what the DM forwarded in the cycle before, which "
                     "C3 proves equal for the two DMs: an induction over the cycles through one register. The "
                     "miter has one shared authbusy input and no karudbg_auth block")]),
        "auth_rdata_i": dict(
            what="the same authdata read data in both runs",
            by=[("reading",)],
            notes=[N("OPEN, wording of T1: the miter shares the whole read data of the mailbox, which is a "
                     "TX word or the status word. T1 says 'the same mailbox TX words'. The status word "
                     "(karudbg_auth.v, status_word) carries the session state, the RX free count, the TX "
                     "count and the error code, and these move with the ROM's pops and pushes, a trap, a "
                     "reset and boot_done: with hart activity and its timing. T1 bullet 3 follows from C3 "
                     "only when its hypothesis is read as 'the same authdata read data, status words "
                     "included, cycle for cycle'. No lemma derives that from the TX words alone, and it "
                     "is not true of them alone")]),
        "debug_enable_i": gate, "debug_enable_next_i": gate,
    }


def scope_chparam(module, param):
    if module == "karudbg_island" and param == "SRAM_END 32'h00020040":
        return dict(what="the lemma is run with an 8-word island SRAM", by=[M()],
                    notes=[], text="the single model runs C9's assertions on the island as karudbg_core "
                                   "instantiates it, with the RTL's own SRAM size")
    if module == "karudbg_auth" and re.fullmatch(r"WINDOW_LOG2 \d+", param):
        return dict(what="a value of the hardware window limit (0: none)", by=[("variant",)], notes=[],
                    text="a configuration variant, not an assumption: this lemma proves C5's block again for "
                         "this value, so the C5 assertions cited below hold for it too")
    return None


T1_LOCKED = "the gate is closed in every cycle from POR in which the lifecycle is not OPEN and the grant is 0"
C7_OUT = "!halt_req_o && !resume_req_o && !resume_authorized_o"
EBREAK = "mem_rdata_o == {2{32'h00100073}}"
DISABLED = [L("C6v", "lc_q == (f_lc == 2'd3 ? 2'd2 : f_lc)"), K("disabled.lc"), L("C5", "lc_q == f_lc"), P("P-LC")]
CLAIMS = [
    dict(id="T1.1", quote="The hart never enters Debug Mode.",
         title="while auth_unlock=0, the hart never enters Debug Mode",
         steps=[
             (T1_LOCKED, [GATE_HYP, P("P-LC")] + GATE + [GATE_INDUCTION]),
             ("POR resets the hart, and after any hart-reset cycle the hart is not in Debug Mode",
              [L("C6cone", "core_rst"), W("hart-reset"), L("C4", "!debug_mode")]),
             ("debug_mode rises only in the clock after one in which the core's gate input was 1",
              [L("C4", "!(debug_mode && !f_mode && !f_en)")]),
             ("so debug_mode is 0 from POR up to and including the first cycle in which the grant is set",
              [N("induction over the cycles from the facts above")]),
         ]),
    dict(id="T1.2", quote="The DM never launches halt, resume, `ndmreset`, `hartreset`, an abstract",
         title="while auth_unlock=0, the DM launches no halt, resume, ndmreset, hartreset, abstract command "
               "or SBA request",
         steps=[
             (T1_LOCKED, [GATE_HYP, P("P-LC")] + GATE + [GATE_INDUCTION]),
             ("in the first cycle after POR no DM output is asserted and the command engine is idle",
              [G("dm", "!halt_req_o && !resume_req_o && !resume_authorized_o && !ndmreset_o"),
               G("dm", "!sba_req_valid_o"), G("dm", "cmd_state_q == CMD_IDLE")]),
             ("in every later cycle with the gate closed, halt, resume, ndmreset and the SBA request are 0",
              [L("C7dm", C7_OUT), ("above", "C7's assumption on the gate, section 3.1")]),
             ("the command engine, idle in one locked cycle, is idle in the next",
              [L("C7dm", "cmd_state_q == CMD_IDLE"), N("induction over the cycles from the first one")]),
             ("the same for a DM locked since POR, with every debugger-written register at its reset value",
              [L("C2", "!halt_req_o && !resume_req_o && !resume_authorized_o && !ndmreset_o"),
               L("C2", "!sba_req_valid_o"),
               L("C2", "cmd_state_q == CMD_IDLE && command_q == 0 && data_q == 0 && autoexec_q == 0"),
               G("C2n"), ("above", "C2's assumptions, section 3.1")]),
             ("the hart-facing debug page offers no debugger content while the gate is closed",
              [L("C7dm", EBREAK), L("C7dm", "mem_rdata_o == 64'b0"), G("dm", EBREAK), G("dm", "mem_rdata_o == 64'b0")]),
             ("the DM has no hartreset request at all", [("absent", "dbg/karudbg.v", "hartreset")]),
             ("the outputs named are the DM's side effects", [("k4",)]),
         ]),
    dict(id="T1.3", quote="The DMI response stream is identical for any two runs that differ only in",
         title="while auth_unlock=0, the DMI response stream does not depend on hart, memory or fabric state",
         steps=[
             (T1_LOCKED, [GATE_HYP, P("P-LC")] + GATE + [GATE_INDUCTION]),
             ("two DMs with the same DMI inputs and the same mailbox side, locked since POR, with separate "
              "free hart, debug-page and System Bus inputs, give the same DMI handshake and the same "
              "responses in every cycle after POR",
              [L("C3", "a_req_ready == b_req_ready"), L("C3", "a_resp_valid == b_resp_valid"),
               L("C3", "!a_resp_valid || (a_resp_data == b_resp_data && a_resp_op == b_resp_op)"),
               ("above", "C3's assumptions, section 3.1")]),
             ("the same with debug_enable_next_i free and separate for each of the two DMs, which covers the "
              "cycle in which the unlock commits: the grant depends on the hart, so the two runs' next "
              "states may differ in a cycle in which both are locked",
              [G("C3n")]),
             ("the mailbox side of the two runs is the same", [("above", "the shared inputs of the C3 miter, "
                                                                "section 3.2, with its OPEN point on the status word")]),
             ("the DMI response stream of T1 is the one at the DM's DMI port",
              [("script", "C1", "cut K1 is the DM's DMI port; JTAG, DTM and BSCAN are behind it"),
               N("the DTM and the JTAG TAP are in no lemma: that they carry DMI requests and responses and "
                 "nothing else of the hart is not checked")]),
         ]),
    dict(id="T2", quote="`auth_unlock` rises only when a CSR",
         title="auth_unlock rises only when a CSR instruction fetched from the island ROM commits the predicate",
         steps=[
             ("the grant is 0 after POR",
              [L("C6v", "!auth_unlock_q && !auth_req_q && !boot_done_q && !fw_lock_q && perm_req_q == 0")]),
             ("the grant rises only in the clock after the commit predicate held, with every input of "
              "karudbg_auth free: no DMI sequence, reset or other input sets it otherwise",
              [L("C5", "f_unlock || !auth_unlock_q || f_pred"),
               ("text", f"{FORMAL}/c5_karudbg_auth.vh",
                "f_pred <= csr_fire_i && !core_in_reset_i && csr_we_i && csr_sel_i == 3'd0 && csr_wdata_i[0] &&")]),
             ("never outside AUTH and never after boot_done",
              [L("C5", "!auth_unlock_q || lc_q == 2'd1"), L("C5", "!(f_done && !f_unlock && auth_unlock_q)")]),
             ("nothing reaches the state of karudbg_auth but the DM's mailbox outputs, cut K2, the strap and "
              "trusted inputs", [("script", "C1", "the frontier of the karudbg_auth state equals its allowlist")]),
             ("cut K2 is the core's CSR sideband and its Debug Mode output",
              [W("K2"), W("debug-mode"), ("script", "C1", "each K2 signal is driven by the hart's own sideband port")]),
             ("the core reports a commit only for a CSR instruction issuing at EX outside reset with no trap "
              "and no Debug entry in that cycle, and the PC, privilege and virtualisation mode it reports "
              "are that instruction's",
              [L("C8", "!rst && issuing && ex_unit == `UNIT_CSR"), L("C8", "!trap_req && !dbg_enter"),
               L("C8", "auth_ex_pc_o == ex_pc && auth_issuing_o")]),
             ("a response to an island-range request on the core's own ports comes only from the island, "
              "with nothing assumed about the core or the fabric",
              [M("!(up_imem_rvalid && im_owner) || (i_rvalid && up_imem_rdata == i_rdata)"),
               M("!f_iacc || (im_out && im_owner == f_isel)"), M("!up_imem_rvalid || im_out"), P("P-ISLAND")]),
             ("and that for every beat of the transaction, however long it stalls: the destination of the "
              "accepted address is remembered in ghost state that reads neither the island's owner flags "
              "nor its address decode",
              [M("!g_i_island || up_imem_rvalid == i_rvalid"),
               M("!(g_i_island && up_imem_rvalid) || up_imem_rdata == i_rdata"),
               M("!(g_i_island && up_imem_rvalid) || up_imem_rresp == i_rresp"),
               M("!(g_i_island && up_imem_rvalid) || up_imem_rlast == i_rlast"),
               M("!g_i_island || !dn_imem_rready"), L("C9own", "!g_i_island || up_imem_rvalid == i_rvalid")]),
             ("the instruction issuing at EX in M-mode with its PC in the ROM range was fetched from the "
              "island ROM",
              [N("OPEN: this needs the core's fetch path to be correct: that the word at EX is the word its "
                 "imem port returned for that PC (IFU, prefetch buffer, optional I-cache, RVC expansion, "
                 "redirects) and that an M-mode fetch is untranslated. No lemma states it: C8 checks the "
                 "PC range of the committing instruction and the single model the bus. Plan 9 does not list "
                 "it as an assumption")]),
             ("which instruction yields which csr_sel, csr_we and csr_wdata",
              [N("the CSR file's decode of the authentication CSRs is in no lemma (C8 keeps karu_csr in its "
                 "model but asserts nothing about these three); simulation only (dbg-auth-core-test)")]),
         ]),
    dict(id="T3.1", quote="**New work stops at t₀+1.**",
         title="relock, item 1: new work stops in the first locked cycle",
         steps=[
             ("in every cycle with the gate closed, whatever came before, halt, resume, ndmreset and the SBA "
              "request are 0; ndmreset_o already in the first locked cycle",
              [L("C7dm", C7_OUT), ("above", "C7's assumption on the gate, section 3.1")]),
             ("no command starts while the gate is closed", [L("C7dm", "cmd_state_q == CMD_IDLE")]),
             ("a DMI read accepted in a locked cycle returns 0 for every register but dmcontrol, dmstatus and authdata",
              [L("C7dm", "resp_data_o == 0")]),
             ("and the locked view for dmcontrol and dmstatus",
              [G("dm", "resp_data_o[31:1] == 0"), G("dm", "resp_data_o == 0 || (resp_data_o[31:7] == 0")]),
             ("from the first locked cycle the debug page returns only ROM words and the safe sequence",
              [L("C7dm", EBREAK), L("C7dm", "mem_rdata_o == 64'b0")]),
             ("once fw_lock or revoke_q is set the gate stays closed until POR",
              [L("C7relock", "!debug_enable_next_o"), L("C5", "!f_lock || fw_lock_q"), L("C5", "!f_rev || revoke_q"),
               G("gate", "debug_enable_o == f_next")]),
             ("that Program Buffer, data and abstractauto writes are refused while locked",
              [N("no lemma states the write side after a fall; what is proved is the effect: nothing "
                 "debugger-written is read back over DMI or served to the hart in a locked cycle, and the "
                 "gate does not reopen. C2 proves the registers themselves at reset values only for a DM "
                 "locked since POR")]),
         ]),
    dict(id="T3.2", quote="**Accepted SBA work keeps its existing ownership contract**",
         title="relock, item 2: accepted SBA work completes without disclosure",
         steps=[
             ("no SBA request is made in a locked cycle and no DMI read accepted in one returns SBA data",
              [L("C7dm", C7_OUT), L("C7dm", "resp_data_o == 0")]),
             ("an accepted transaction keeps its ownership contract and runs to completion",
              [N("in no lemma. Simulation only: dbg-auth-sba-revoke-test (plan 7, A4)")]),
         ]),
    dict(id="T3.3", quote="**A hart in Debug Mode at t₀** receives a system reset within *k* cycles.",
         title="relock, item 3: a hart in Debug Mode is reset one clock after the gate is closed (k = 1)",
         steps=[
             ("a hart in Debug Mode, not in reset, with the gate closed: the relock reset is asserted in the "
              "next cycle, with hart progress, dmactive and responders free",
              [L("C7relock", "sys_reset_o"), W("debug-mode"), W("hart-reset")]),
             ("the relock reset resets the hart, and after a hart-reset cycle the hart is not in Debug Mode",
              [L("C6cone", "core_rst"), L("C4", "!debug_mode")]),
             ("a running hart cannot enter Debug Mode while the gate is closed",
              [L("C4", "!(debug_mode && !f_mode && !f_en)"), L("C4", "!dbg_enter || debug_enable_i"), W("gate")]),
         ]),
    dict(id="T4", quote="With `lc=DISABLED`, `auth_unlock` stays 0",
         title="in DISABLED the grant stays 0 and the gate closed, so T1 holds in every cycle",
         steps=[
             ("lc_q is DISABLED after POR and does not change", DISABLED),
             ("the grant is 0 after POR and stays 0",
              [L("C6v", "!auth_unlock_q && !auth_req_q && !boot_done_q && !fw_lock_q && perm_req_q == 0"),
               L("C5", "!auth_unlock_q || lc_q == 2'd1"), K("disabled.grant")]),
             ("the gate is closed after POR and stays closed",
              [L("C6v", "debug_enable_o == (f_lc == 2'd0 && !f_rev)"), K("gate.por"),
               L("C5", "!(lc_q == 2'd2 && debug_enable_o)"), K("disabled.gate")]),
             ("so T1 applies to every cycle", [("above", "claims T1.1 to T1.3, with their marked steps")]),
         ]),
]

# initial blocks in the sources of the modelled modules: none sets a register
# that a model keeps, so each model starts from an unconstrained state
INITIALS = {
    "dbg/karudbg_sba.v": ["SBASIZE must be"],                # parameter check, translate_off
    "dbg/karudbg_island.v": ["rom[k] = 64'b0"],              # ROM contents (trusted, constant)
    "dbg/karudbg_core.v": ["KARU_BOOT_DEBUG_PAGE"],          # address-map check, translate_off
    "rtl/karu64.v": ["commit_log", "log_lpending = 1'b0", "log_mpending = 1'b0", "log_fpending = 1'b0"],
}

FINDINGS = [
    dict(id="F1", closed=("glue", "gate"),
         text="Lemma C7 (DM side) assumes that debug_enable_i is debug_enable_next_i one clock later. No "
              "assertion of C1-C10 states that of karudbg_auth's two outputs. Without it the DM could hold "
              "ndmreset_o in a locked cycle (ndmreset_q is gated by the next state). Glue lemma gate (a) "
              "proves it."),
    dict(id="F2", closed=("glue", "C2n", "C3n"),
         text="Lemmas C2 and C3 assume debug_enable_next_i = 0 in every cycle. In the cycle in which the "
              "unlock commits, the grant is still 0 (T1 applies) and debug_enable_next_o is 1, so C2 and C3 "
              "as stated do not cover that cycle. C2n and C3n prove the same assertions with "
              "debug_enable_next_i free."),
    dict(id="F3", closed=("glue", "dm"),
         text="The first cycle after POR is covered by neither C2 (its assertions start one cycle later, "
              "f_past) nor C7 (it skips the cycle after a reset cycle), so no lemma said that the DM's "
              "outputs are 0 in it. Glue lemma dm (a) proves it."),
    dict(id="F4", closed=("glue", "dm"),
         text="After a fall of the gate, C7 states the locked DMI view for every register except dmcontrol, "
              "dmstatus and authdata, and C2 states dmcontrol and dmstatus only for a DM locked since POR. "
              "Nothing said that dmstatus hides hart state after a revocation. Glue lemma dm (b) proves it."),
    dict(id="F5", closed=("single",),
         text="Lemmas C9 and C10 assume no hart reset after the first cycle, and lemma C9 runs with an "
              "8-word SRAM. hart_reset_i is an adversary input (plan 1.2). The single model assumes the "
              "reset in the first cycle only and uses the RTL's SRAM size."),
    dict(id="F6", closed=("glue", "gate"),
         text="The C3 miter gives its two DMs one shared authbusy and one shared 'authdata implemented' "
              "input. No lemma said that karudbg_auth's authbusy_o depends only on what the DM forwards, "
              "or that lc_auth_o is constant. Glue lemma gate (b), (c) proves both; that the two runs then "
              "have the same authbusy is an induction through one register, not a check."),
    dict(id="F7", closed=("reading",),
         text="T1 bullet 3 as worded does not follow from C3. C3 gives the two runs the same authdata "
              "read data; T1 gives them 'the same mailbox TX words'. The read data is a TX word or the status "
              "word, and the status word depends on hart activity and its timing (session state, RX free "
              "count, TX count, error code): the witness of section 1.6 is two runs with the same DM side "
              "and the same TX pushes that read different words. Either T1 is to be read (and worded) with "
              "the mailbox's read data, status included, as the declassified channel (--mailbox-reading), "
              "or a lemma is missing. With the earlier wording the shared read data of the C3 miter is "
              "undischarged and this script fails; the plan words T1 with the read data since 2026-11-19."),
    dict(id="F8", closed=None,
         text="T2's 'fetched from the island ROM' rests on the correctness of the core's fetch path "
              "(IFU, prefetch, I-cache, RVC, privilege and translation at fetch), which no lemma covers and "
              "plan 9 does not list as an assumption. The lemmas give: the committing instruction's PC is "
              "in the ROM range (C5, C8), and island-range bus requests are answered only by the island, "
              "for every beat of the transaction (single model, lemma C9own). Nothing follows the fetched "
              "word from the imem port to EX: fetch-to-execute provenance is open in every configuration, "
              "the VCU118 image's included; neither the single model's 'image' run nor lemma C1's --image "
              "inventory is about it."),
    dict(id="F9", closed=("config",),
         text="As run by run_auth_formal.py the lemmas share no configuration: the core lemmas (C4, C6cone, "
              "C8, C10) are proved without KARU_DBG_SBA, the DM lemmas with it, and C1 with KARU_DBG_FULL. "
              "This run proves the core lemmas again with C1's defines and checks that the other lemmas' "
              "sources do not see the difference, so C1's configuration is covered by every lemma "
              "(section 3.3)."),
    dict(id="F10", closed=None,
         text="The VCU118 debug image's configuration is not that of the composition, and three separate "
              "runs touch it. (a) The single model's configuration 'image' has the image's define list "
              "only (check_auth_bypass.py: IMAGE_DEFINES; H, the vector unit, Zkr, the I-cache), with "
              "karudbg_core's default top-level parameters and with the authentication block cut out, as "
              "every instance but the core and the island is: it covers the bus ownership property of C9 "
              "with C10 under those defines and nothing else of the image. (b) Lemma C1's --image "
              "inventory is the run with the image's parameters as well (IMAGE_PARAMS: the island reset "
              "vector, external time, AUTH_WINDOW_LOG2 = 31) and with the I-cache in the fetch path; this "
              "script does not make that run. (c) The window timer at width 31 is lemma C5w31, with glue "
              "gate's variant for 31. C4, C6cone, C8 and C10 are not run with the image's defines, and "
              "C6v and C7relock not with its window parameter; the sources of the DM, karudbg_auth and "
              "island lemmas do not change with the defines (section 3.3). Fetch-to-execute provenance "
              "is open for the image as for every configuration (F8)."),
    dict(id="F11", closed=("glue", "C3n"),
         text="Glue lemma C3n gave the two DMs of the C3 miter one shared debug_enable_next_i. In the "
              "cycle before a grant takes effect both DMs are locked and their next states can differ, "
              "since the grant depends on what the hart does; T1 covers that cycle, and the shared input "
              "left such pairs of runs out. C3n now runs the miter with a separate, free next-state input "
              "for each DM (C3_SPLIT_NEXT). Three controls that show the next state to a locked debugger "
              "(in dmstatus, in the DMI ready and in the response code) fail there and pass with the "
              "shared input."),
    dict(id="F12", closed=("ownership",),
         text="Lemma C9 checks the owner flag one cycle after an address is accepted; its later response "
              "checks use the island's own owner flags, and the single model compared only the three "
              "outstanding flags with independent state. Nothing said, from state independent of the "
              "router, that every beat of a stalled or multi-beat response comes from the destination "
              "of the accepted address. Lemma C9own does: it remembers the destination in ghost state "
              "that reads neither the owner flags nor the address decode, and checks each beat shown to "
              "the core (valid, ID, data, response code, LAST) and both READY paths against it, on all "
              "three channels. Each of its assertions fails in a control. Its block is in the single "
              "model too."),
]


def finding_state(f, results, single_ok):
    """(open, state) of a finding: one answer for the report's list, the
    count in the summary line and the open flag in results.json."""
    def passed(group, name):
        return bool(results.get(group, {}).get(name, {}).get("ok"))
    if not f["closed"]:
        return True, "OPEN"
    kind, names = f["closed"][0], f["closed"][1:]
    if kind == "reading":       # finding F7: what T1's third bullet gives the two runs
        source = results["options"].get("reading_source") if results["options"]["mailbox_reading"] else None
        if source == "plan":
            return False, "closed by the wording of T1 in the plan since 2026-11-19, which this run read"
        if results["options"]["mailbox_reading"]:
            return True, "OPEN; the wider reading is accepted on the command line"
        return True, "OPEN"
    ok = (single_ok if kind == "single" else
          bool(results.get("config")) and all(x.get("ok") for x in results["config"].values()) if kind == "config" else
          passed("lemmas", "C9own") and single_ok if kind == "ownership" else
          all(passed("glue", n) for n in names))
    return (False, "closed by this run") if ok else (True, "NOT CLOSED: its proof did not pass")


# ---------------------------------------------------------------------------
# 5. The report
class Report:
    def __init__(self, results):
        self.r = results
        self.problems = []          # anything here fails the run
        self.arguments = []         # every NOT MACHINE-CHECKED step, in order
        self.plan = norm(read(PLAN))
        self.glue = glue_table()
        self.lines = []
        self.current = set()        # the arguments of the claim being printed
        self.flag = False           # a problem was recorded since it was last cleared

    def out(self, text=""):
        self.lines.append(text)

    def problem(self, text):
        if text not in self.problems:
            self.problems.append(text)
        self.flag = True
        return f"*** {text} ***"

    def argument(self, text):
        """The number of a NOT MACHINE-CHECKED step; one number per distinct text."""
        if text not in self.arguments:
            self.arguments.append(text)
        self.current.add(self.arguments.index(text) + 1)
        return self.arguments.index(text) + 1

    def find(self, sources, fragment, kind="assert"):
        """The one kind(...) whose expression is, or else contains, the fragment."""
        frag, hits = norm(fragment), []
        for label, text in sources:
            for c in calls(text, kind):
                if frag in c["expr"]:
                    hits.append((c["expr"] == frag, label, c))
        exact = [h for h in hits if h[0]]
        hits = exact if exact else hits
        if len(hits) != 1:
            return None, self.problem(f"{kind}({fragment}) found {len(hits)} times in {[s[0] for s in sources]}")
        return hits[0][2]["expr"], f"{hits[0][1]}:{hits[0][2]['line']}"

    def lemma_sources(self, name):
        return [(Path(b).name, read(b)) for b in blocks_of(base.LEMMAS[name])]

    def glue_sources(self, name):
        cfg = self.glue[name]
        label = "+".join(Path(b).name for b in blocks_of(cfg)) + (" (derived)" if "derive" in cfg else "")
        return [(label, glue_block(cfg))]

    def model_sources(self):
        return [(f"{Path(C9_BLOCK).name} as in the island copy", single_block(C9_BLOCK, "C9")),
                (f"{Path(C9OWN_BLOCK).name} as it is, after it in the island copy", own_block()),
                (f"{Path(C10_BLOCK).name} as in the core copy", single_block(C10_BLOCK, "C10")),
                (Path(LINK_BLOCK).name, read(LINK_BLOCK))]

    def passed(self, group, name):
        return bool(self.r.get(group, {}).get(name, {}).get("ok"))

    def single_ok(self):
        s = self.r.get("single", {})
        return (bool(s.get("proofs")) and all(p.get("ok") for p in s["proofs"].values()) and
                bool(s.get("cover", {}).get("ok")) and bool(s.get("mutants")) and
                all(m.get("detected") for m in s["mutants"].values()))

    def ref(self, ref):
        """(text, machine-checked) of one reference; records problems."""
        kind = ref[0]
        if kind == "lemma":
            if ref[1] not in base.LEMMAS:
                return self.problem(f"lemma {ref[1]} is not in the lemma table"), True
            expr, where = self.find(self.lemma_sources(ref[1]), ref[2])
            ok = self.passed("lemmas", ref[1])
            if not ok:
                self.problem(f"lemma {ref[1]} is cited and did not pass in this run")
            return f"lemma {ref[1]} [{'proved' if ok else 'NOT PROVED'}]: assert({expr})  ({where})", True
        if kind == "glue":
            ok = self.passed("glue", ref[1])
            if not ok:
                self.problem(f"glue lemma {ref[1]} is cited and did not pass in this run")
            state = "proved" if ok else "NOT PROVED"
            if ref[2] is None:
                return f"glue lemma {ref[1]} [{state}]", True
            expr, where = self.find(self.glue_sources(ref[1]), ref[2])
            return f"glue lemma {ref[1]} [{state}]: assert({expr})  ({where})", True
        if kind == "model":
            ok = self.single_ok()
            if not ok:
                self.problem("the single model for C9 with C10 is cited and did not pass in this run")
            state = "proved" if ok else "NOT PROVED"
            if ref[1] is None:
                return f"single model C9 with C10 [{state}]", True
            expr, where = self.find(self.model_sources(), ref[1])
            return f"single model C9 with C10 [{state}]: assert({expr})  ({where})", True
        if kind == "script":
            ok = self.passed("scripts", ref[1])
            if not ok:
                self.problem(f"{ref[1]} is cited and did not pass in this run")
            return f"{ref[1]} [{'passed' if ok else 'NOT PASSED'}]: {ref[2]}", True
        if kind == "check":
            c = self.r.get("checks", {}).get(ref[1])
            if not c or not c.get("ok"):
                return self.problem(f"implication check {ref[1]} missing or failed"), True
            return (f"implication {ref[1]} [valid; invalid without any one hypothesis]: "
                    + " and ".join(f"[{h}]" for h in c["hyps"]) + "  =>  [" + c["concl"] + "]"), True
        if kind == "wiring":
            w = self.r.get("wiring", {}).get(ref[1])
            if not w or not w.get("ok"):
                return self.problem(f"wiring {ref[1]} missing or wrong: {w and w.get('errors')}"), True
            return f"wiring {ref[1]} [netlist of karudbg_core, {w['pairs']} port pairs]: {w['what']}", True
        if kind == "platform":
            if ref[1] not in PLATFORM:
                return self.problem(f"platform assumption {ref[1]} is not in the table"), True
            return f"platform assumption {ref[1]}: {PLATFORM[ref[1]]['text']}", True
        if kind == "hypothesis":
            return f"hypothesis of {ref[1]}: {ref[2]}", True
        if kind == "text":
            if norm(ref[2]) not in norm(read(ref[1])):
                return self.problem(f"text not found in {ref[1]}: {ref[2]}"), True
            return f"{ref[1]}: {norm(ref[2])} ...", True
        if kind == "absent":
            if ref[2] in read(ref[1]):
                return self.problem(f"'{ref[2]}' occurs in {ref[1]}"), True
            return f"'{ref[2]}' does not occur in {ref[1]} [text search]", True
        if kind == "initials":
            ok = self.r.get("initials", {}).get("ok")
            if not ok:
                self.problem("an unlisted initial block in a modelled source file")
            return ("no register of the modelled modules has an initial value, so the state before the "
                    "first cycle is unconstrained [source search for initial blocks]"), True
        if kind == "reading":
            if self.r["options"]["mailbox_reading"]:
                if self.r["options"].get("reading_source") == "plan":
                    return ("hypothesis of T1 as the plan words it (section 4, read from the file): the two runs "
                            "receive the same authdata read data, the mailbox's TX words and its status words"), True
                return ("hypothesis of T1, READ AS (--mailbox-reading): the two runs receive the same authdata "
                        "read data, status words included"), True
            return self.problem("UNDISCHARGED with T1 worded as 'the same mailbox TX words': the C3 miter shares "
                                "the authdata read data, status words included (finding F7)"), True
        if kind == "variant":
            return "configuration variant, nothing to discharge", True
        if kind == "above":
            return f"see {ref[1]}", True
        if kind == "k4":
            return self.k4(), True
        if kind == "argument":
            return f"NOT MACHINE-CHECKED ({self.argument(ref[1])}): {ref[1]}", False
        return self.problem(f"unknown reference {ref}"), True

    def k4(self):
        """Which K4 outputs of the DM (lemma C1's cut list) an assertion names."""
        texts = (self.lemma_sources("C2") + self.lemma_sources("C7dm") + self.glue_sources("dm"))
        named = set()
        for _, text in texts:
            for c in calls(text, "assert"):
                named |= idents(c["expr"])
        k4 = c1._sigs("K4.out")
        rest = [s for s in k4 if s not in named]
        text = ("the K4 outputs named in no assertion (" + ", ".join(rest) + ") are the payload of an SBA "
                "request that is never valid, the ready of the SBA response and the ready/error of the debug "
                "page: not side effects by themselves")
        return (f"of lemma C1's K4 outputs, assertions of C2, C7 and glue dm name "
                f"{', '.join(s for s in k4 if s in named)}. NOT MACHINE-CHECKED ({self.argument(text)}): {text}")

    def discharge(self, entry, indent):
        """Print a discharge; it needs at least one reference that is not an argument."""
        solid = 0
        for ref in entry["by"] + entry.get("notes", []):
            text, machine = self.ref(ref)
            solid += machine and ref[0] not in ("above",) or ref[0] == "above"
            self.out(f"{indent}- {text}")
        return solid

    # -- sections ----------------------------------------------------------
    def evidence(self):
        r = self.r
        self.out("1. Evidence produced by this run")
        self.out("")
        self.out("1.1 Lemma table of test/dbg/run_auth_formal.py, each lemma run as its own process")
        for name in sorted(base.LEMMAS):
            x, cfg = r["lemmas"].get(name, {}), base.LEMMAS[name]
            kind = f"BMC depth {cfg['bmc']} {x.get('bmc', '?')}"
            if cfg["induct"]:
                kind += f", induction k={cfg['induct']} {x.get('induction', '?')}"
            muts = x.get("mutants", {})
            own = ""
            if cfg.get("own_block"):
                killed = x.get("killed", {})
                own = (f", each on an assertion of {Path(cfg['own_block']).name}, and "
                       f"{sum(bool(by) for by in killed.values())}/{len(killed) or '?'} of its assertions fail in a control")
            self.out(f"  {'PASS' if x.get('ok') else 'FAIL'} {name} ({cfg['module']}): {kind}; "
                     f"{sum(m['detected'] for m in muts.values())}/{len(cfg['mutants'])} controls failed as "
                     f"they must{own}; {x.get('seconds', '?')} s")
            if not x.get("ok"):
                self.problem(f"lemma {name} did not pass: {x.get('error') or x.get('line') or x.get('log')}")
        for name, cfg in sorted(base.LEMMAS.items()):
            if not cfg.get("own_block"):
                continue
            x = r["lemmas"].get(name, {})
            muts = x.get("mutants", {})
            self.out("")
            self.out(f"1.1a Lemma {name}: each assertion of {cfg['own_block']} and the controls that fail on it")
            self.out("  In these control runs only that block's assertions are checked, without its strengthening")
            self.out("  invariants; the other block keeps its assumptions. Line numbers are the block's.")
            for a, by in x.get("killed", {}).items():
                self.out(f"  {a}")
                self.out("      fails in: " + (", ".join(f"{m} (step {muts[m].get('step')})" for m in by) or
                                              self.problem(f"lemma {name}: no control fails on {a}")))
            if not x.get("killed"):
                self.problem(f"lemma {name}: no record of the assertions its controls fail on")
            self.out("  Controls for a mechanism of the router, naming no assertion (each fails on one or more of the above):")
            for m, v in muts.items():
                if "expect" not in v:
                    self.out(f"    {m}: {v.get('status')} in step {v.get('step')} on "
                             + "; ".join(f.split(": ", 1)[1] for f in v.get("failed", [])))
        self.out("")
        self.out("1.2 Lemma C1 (test/dbg/check_auth_bypass.py) and lemma C6 (test/dbg/check_auth_reset.py)")
        for name in ("C1", "C6"):
            x = r["scripts"].get(name, {})
            self.out(f"  {'PASS' if x.get('ok') else 'FAIL'} {name}: {x.get('seconds', '?')} s"
                     + (", with its controls" if r["options"]["base_controls"] else
                        ", without its own controls (run it with --self-test, or this script with --base-controls)"))
            for l in x.get("lines", []):
                self.out(f"       {l}")
            if not x.get("ok"):
                self.problem(f"{name} did not pass: {x.get('error') or x.get('log')}")
        self.out("")
        self.out(f"1.3 Glue lemmas of this script (property blocks {rel(COMPOSE)}/compose_*, or derived)")
        for name, cfg in self.glue.items():
            x = r["glue"].get(name, {})
            runs = "; ".join(
                (f"[{', '.join(run['chparams'])}] " if run["chparams"] else "") +
                f"BMC depth {run['bmc']['depth']} {run['bmc']['status']}" +
                (f", induction k={run['induction']['depth']} {run['induction']['status']}" if "induction" in run else "") +
                f" ({run['asserts']} assertions, {run['assumes']} assumptions)" for run in x.get("runs", []))
            self.out(f"  {'PASS' if x.get('ok') else 'FAIL'} {name} ({cfg['module']}): {runs}")
            self.out(f"       {cfg['claim']}")
            for m, v in x.get("mutants", {}).items():
                self.out(f"       control {m}: {v['status']}" +
                         (" on assert(" + "), assert(".join(sorted(set(f['expr'] for f in v['failed']))) + ")"
                          if v["failed"] else ""))
            c = x.get("contrast", {})
            for m, v in c.get("mutants", {}).items():
                self.out(f"       control {m} in the model without {c['without']} (one shared next-state input): "
                         f"{v['status']} at BMC depth {v['depth']}"
                         + (", not caught there: the separate inputs are what catches it" if v["status"] == "PASSED"
                            else ": *** expected to pass there ***"))
            if not x.get("ok"):
                self.problem(f"glue lemma {name} did not pass: {x.get('error', '')}")
        self.out("")
        self.out("1.4 Implications checked by the solver (each also fails without any one of its hypotheses)")
        for name, x in r["checks"].items():
            self.out(f"  {'PASS' if x.get('ok') else 'FAIL'} {name}: {x.get('what', '')}")
            if not x.get("ok"):
                self.problem(f"implication check {name} failed: {x.get('error') or (x.get('valid'), x.get('controls'))}")
        self.out("")
        self.out("1.5 Wiring of karudbg_core (Yosys netlist of the module: the two ports are the same net)")
        for name, x in r["wiring"].items():
            self.out(f"  {'PASS' if x.get('ok') else 'FAIL'} {name}: {x.get('pairs', '?')} port pairs. {x.get('what', '')}")
            if not x.get("ok"):
                self.problem(f"wiring {name}: {x.get('errors') or x.get('error')}")
        self.out("")
        w = r.get("witness", {}).get("status", {})
        self.out(f"1.6 Witness for finding F7 ({STATUS_MITER}; expected to FAIL)")
        self.out(f"  {'FOUND' if w.get('ok') else 'NOT FOUND'}: two karudbg_auth blocks with the same trusted inputs, "
                 "the same DM side and the same TX pushes, other hart inputs free and separate. BMC "
                 f"{w.get('status')} in step {w.get('last_step')}: "
                 + "; ".join(f"assert({f['expr']})" for f in w.get("failed", [])) + f". Trace: {w.get('vcd')}")
        if not w.get("ok"):
            self.problem(f"the witness for finding F7 was not found: {w.get('error') or w.get('status')}; "
                         "the finding and the table entry for auth_rdata_i need another look")
        self.out("")
        x = r["initials"]
        self.out("1.7 initial blocks in the sources of the modelled modules")
        self.out(f"  {'PASS' if x['ok'] else 'FAIL'}: {x['found']} found, each listed as not setting a register "
                 "a model keeps (parameter checks, simulation logging, ROM contents)")
        for e in x["errors"]:
            self.problem(e)
        self.out("")

    def single(self):
        s = self.r["single"]
        self.out("2. The single model for lemma C9 with lemma C10")
        self.out("")
        self.out("  Top: a build copy of dbg/karudbg_core.v. Kept: the core's own logic (rtl/karu64.v) and")
        self.out("  the island (dbg/karudbg_island.v) with its two bridges, ROM and SRAM at the RTL's sizes,")
        self.out("  on the real nets and the real hart reset core_rst. Lemma C9's block is in the island copy")
        self.out("  and lemma C10's block in the core copy, both as they are in the repository except that")
        self.out("  the runner turns each assumption about the other side into an assertion and assumes the")
        self.out("  reset in the first cycle only. Lemma C9own's block follows C9's in the island copy as it")
        self.out("  is (it assumes nothing), with the bridges' three response-ready connections named as in")
        self.out("  the lemma. Its four strengthening invariants are asserted in the proof runs and left out")
        self.out("  of the control runs.")
        for config, p in s.get("proofs", {}).items():
            self.out("")
            self.out(f"  Configuration '{config}'" + {"C1": " (lemma C1's defines, the composition's)",
                                                    "lemma": " (lemma C10's defines)",
                                                    "image": " (the VCU118 debug image's define list only: "
                                                             "karudbg_core's default top-level parameters, not "
                                                             "the image's; the authentication block is a cut "
                                                             "point here as in every configuration; see 3.3)"}.get(config, "")
                     + f": {' '.join(d for d in p.get('induction', {}).get('defines', []) if d != 'FORMAL_STRENGTHEN')}")
            if not p.get("ok"):
                self.problem(f"single model, configuration {config}: {p.get('error') or 'proof failed'}")
                self.out(f"    FAIL {p.get('error', '')}")
            if "bmc" not in p:
                continue
            b, i = p["bmc"], p["induction"]
            self.out(f"    free cut points: every instance in the core ({', '.join(c.split('.')[-1] for c in b['cut_cells'] if 'karu64' in c)});")
            self.out(f"      in karudbg_core {', '.join(c.split('.')[-1] for c in b['cut_cells'] if 'karu64' not in c)};")
            self.out(f"      the island's downstream response nets ({len(b['cut_nets'])}: {', '.join(b['cut_nets'])});")
            self.out("      every input of karudbg_core. So hart_reset_i, ndmreset and the hold/relock reset can")
            self.out("      assert the hart reset in any cycle.")
            self.out(f"    assumed: {i['assumes']} assume() in the model, the reset in the first cycle, once in each block.")
            self.out(f"    BMC from that reset cycle (arbitrary state before it), depth {b['depth']}: {b['status']}, "
                     f"{b['asserts']} assertions including C9's six BMC-only bridge assertions and C9own's four "
                     f"strengthening invariants, {b['seconds']} s "
                     f"(+{b['yosys_seconds']} s Yosys). BOUNDED for those six, as in lemma C9.")
            k = i["depth"] - i["last_step"] if i.get("last_step") is not None else "?"
            self.out(f"    k-induction (yosys-smtbmc -i -t {i['depth']}): {i['status']} with k = {k}, "
                     f"{i['asserts']} assertions, {i['seconds']} s. UNBOUNDED for these.")
        self.out("")
        self.out("  What is asserted, and which assertion of one lemma discharges which assumption of the other:")
        for i in INTERFACE:
            c = self.r["checks"].get(i["id"], {})
            self.out(f"    {i['lemma']} assumes  {i['assume']}")
            self.out(f"      asserted in the single model; {i['by']} asserts  {i['guarantee']}")
            self.out(f"      link: {i['flags']}; solver: guarantee and link imply the assumption "
                     f"[{'valid' if c.get('ok') else 'NOT VALID'}]; {i['what']}")
        self.out(f"    link ({LINK_BLOCK}): assert({LINK_EXPR}), in every cycle after the first")
        self.out("  Every assertion of the model, from the build copies' blocks:")
        turned = [i["assume"] for i in INTERFACE]
        for label, text in self.model_sources():
            self.out(f"    {label}:")
            lo = text.find("`ifdef FORMAL_BOUNDED")
            hi = text.find("`endif", lo) if lo >= 0 else -1
            slo = text.find("`ifdef FORMAL_STRENGTHEN")
            shi = text.find("`endif", slo) if slo >= 0 else -1
            for c in calls(text.split("`ifdef FORMAL_COVER")[0], "assert"):
                self.out(f"      assert({c['expr']})"
                         + ("   <- an assumption of the lemma, asserted here" if c["expr"] in turned else "")
                         + ("   (BMC only)" if lo < c["pos"] < hi else "")
                         + ("   (strengthening invariant, proof runs only)" if slo < c["pos"] < shi else ""))
        self.out("")
        self.out("  Controls (BMC, each must fail on one of the named assertions):")
        for name, m in s.get("mutants", {}).items():
            got = "; ".join(f"{f['module']}: assert({f['expr']})" for f in m.get("failed", []))
            self.out(f"    {'failed as it must' if m.get('detected') else 'NOT DETECTED'} [{m.get('side', '?')} side] "
                     f"{name}: {m.get('what', m.get('error', ''))}")
            self.out(f"        {m.get('status')} in step {m.get('last_step')}, {m.get('seconds')} s: {got}")
            if not m.get("detected"):
                self.problem(f"single model: control {name} was not detected")
        c = s.get("cover", {})
        self.out("")
        self.out(f"  Reachability: {c.get('reached')} of {c.get('covers')} cover statements reached within depth "
                 f"{c.get('depth')} ({c.get('status')}): an island and an external response of each kind is "
                 "delivered to the core, and one after a second reset; a beat of the island's is stalled and "
                 "a downstream beat that is not the last one is delivered.")
        if not c.get("ok"):
            self.problem(f"single model: cover statements not all reached: {c.get('error', '')}")
        if not s.get("mutants") or not s.get("proofs"):
            self.problem("single model: proofs or controls missing")
        self.out("")

    def assumptions(self):
        table, seen = assumptions_table(), set()
        self.out("3. Assumptions of the lemma models and what discharges them")
        self.out("")
        self.out("3.1 Every assume() of every property block (extracted from the files)")
        users = {}
        for name, cfg in sorted(base.LEMMAS.items()):
            for b in blocks_of(cfg):
                users.setdefault(b, []).append(name)
        sources = [(b, read(b), "lemma " + ", ".join(u)) for b, u in sorted(users.items())]
        sources += [(f"derived:{n}", glue_block(cfg), f"glue lemma {n}, derived from {', '.join(blocks_of(cfg))}")
                    if "derive" in cfg else (cfg["block"], read(cfg["block"]), f"glue lemma {n}")
                    for n, cfg in self.glue.items()]
        sources += [("derived:C9C10/C9", single_block(C9_BLOCK, "C9"), f"single model, derived from {C9_BLOCK}"),
                    ("derived:C9C10/C10", single_block(C10_BLOCK, "C10"), f"single model, derived from {C10_BLOCK}"),
                    (LINK_BLOCK, read(LINK_BLOCK), "single model, link")]
        total = 0
        for source, text, user in sources:
            found = calls(text, "assume")
            self.out(f"  {source} ({user}): {len(found) or 'no'} assume()")
            for c in found:
                total += 1
                entry = table.get((source, c["expr"]))
                seen.add((source, c["expr"]))
                if entry is None:
                    self.out("    " + self.problem(f"UNDISCHARGED: assume({c['expr']}) at {source}:{c['line']} "
                                                   "has no entry in the table"))
                    continue
                self.out(f"    assume({c['expr']})  line {c['line']}: {entry['what']}")
                if not self.discharge(entry, "      "):
                    self.problem(f"assume({c['expr']}) of {source} is discharged by an argument only")
        for key in sorted(set(table) - seen):
            self.problem(f"stale table entry: no assume({key[1]}) in {key[0]}")
        self.totals = dict(assumptions=total)
        self.out("")
        self.out("3.2 Model restrictions that are not assume() statements")
        n = 0
        for name, cfg in sorted(base.LEMMAS.items()):
            for p in cfg.get("chparams", []):
                n += 1
                entry = scope_chparam(cfg["module"], p)
                if entry is None:
                    self.out("  " + self.problem(f"UNDISCHARGED: lemma {name} sets parameter {p} of {cfg['module']}, "
                                                 "which has no entry in the table"))
                    continue
                self.out(f"  lemma {name}: parameter {p} of {cfg['module']}: {entry['what']}; {entry['text']}")
                self.discharge(entry, "      ")
        shared, _ = miter_inputs(False)
        mt = miter_table()
        self.out(f"  lemma C3: the miter ({base.LEMMAS['C3']['src']}) gives both copies of the DM the same value on "
                 f"{len(shared)} inputs; every other input is free and separate:")
        for s in shared:
            n += 1
            entry = mt.get(s)
            if entry is None:
                self.out("    " + self.problem(f"UNDISCHARGED: shared miter input {s} has no entry in the table"))
                continue
            self.out(f"    {s}: {entry['what']}")
            self.discharge(entry, "      ")
        for s in sorted(set(mt) - set(shared)):
            self.problem(f"stale table entry: the C3 miter has no shared input {s}")
        if sorted(s for s in shared if s in c1._sigs("K1")) != sorted(c1._sigs("K1")):
            self.problem("the C3 miter does not share exactly lemma C1's K1 signals")
        # glue lemma C3n: the same miter with a next-state input for each copy
        split, pairs = miter_inputs(True)
        own = [s for s in pairs if s.endswith("debug_enable_next_i")]
        if (sorted(set(shared) - set(split)) != ["debug_enable_next_i"] or set(split) - set(shared) or
                sorted(own) != ["a_debug_enable_next_i", "b_debug_enable_next_i"] or
                SPLIT not in self.glue["C3n"]["defines"] or SPLIT in base.LEMMAS["C3"]["defines"]):
            self.problem("glue lemma C3n's miter does not differ from lemma C3's in debug_enable_next_i alone")
        self.out(f"  glue lemma C3n: the same miter with {SPLIT}: debug_enable_next_i is not shared; each copy has a "
                 f"free input of its own ({', '.join(sorted(own))}). The other {len(split)} shared inputs are "
                 "lemma C3's, discharged as above; the gate itself is closed in both by the derived block's "
                 "assumption (section 3.1).")
        self.totals["restrictions"] = n
        self.out("")
        self.configuration()
        self.out("3.4 Free cut points and bounded parts (nothing to discharge)")
        self.out("  A cut point replaces an instance's outputs by free values, and a free input takes any")
        self.out("  value: the model has more runs than the RTL, so what is proved of it holds of the RTL.")
        self.out("  It says nothing about what the cut instance does.")
        for name, cfg in sorted(base.LEMMAS.items()):
            x = self.r["lemmas"].get(name, {})
            what = []
            if cfg.get("cut_submodules"):
                what.append("cut: " + (", ".join(x.get("cut_cells", [])) or "?") +
                            (f" (kept: {', '.join(cfg['cut_keep'])})" if cfg.get("cut_keep") else ""))
            if cfg.get("observe"):
                what.append("formal-only output of " + ", ".join(cfg["observe"]) + " added to a copy of " + cfg["mutate"])
            if cfg.get("bounded_define"):
                what.append(f"the assertions under {cfg['bounded_define']} are BMC-only: BOUNDED, depth {cfg['bmc']}")
            if cfg.get("probes"):
                what.append("in the build copy the connections " +
                            ", ".join(f".{p} of {i}" for i, p in cfg["probes"].values()) +
                            " are named wires (" + ", ".join(cfg["probes"]) + "), the RTL's expressions unchanged")
            if cfg.get("own_block"):
                what.append(f"in its control runs only the assertions of {Path(cfg['own_block']).name} are checked "
                            "(the other block's become cover statements; its assumptions stay)")
            if cfg.get("mutant_chparams"):
                what.append("its control runs set " + ", ".join(cfg["mutant_chparams"]) +
                            " (a smaller ROM, for run time; the proof runs have the RTL's)")
            if not cfg["induct"]:
                reset = any(c["expr"] == "rst" for b in blocks_of(cfg) for c in calls(read(b), "assume"))
                what.append(f"BMC depth {cfg['bmc']}, no induction" + ("" if reset else
                            ": from an arbitrary state, for properties that span no more cycles than the depth"))
            if what:
                self.out(f"  {name} ({cfg['module']}): " + "; ".join(what))
        self.out("")

    def configuration(self):
        config = self.r["options"]["config"]
        self.out("3.3 Configuration")
        self.out(f"  The composition is for one configuration, that of lemma C1: {' '.join(config)}")
        self.out("  Each lemma in it:")
        src = self.r.get("sources", {})
        if not src.get("control", {}).get("ok"):
            self.problem(f"the source comparison has no teeth or did not run: {src.get('error', '')}")

        def alike(name, _files=None, _defines=None):
            x = src.get(name, {})
            if not x.get("ok"):
                self.problem(f"{name} is not proved in the composition's configuration: "
                             f"{x.get('differ') or 'its sources were not compared'}")
            return (f"proved with {' '.join(x.get('defines', [])) or 'no define'}; its RTL files "
                    f"({', '.join(Path(f).name for f in x.get('files', []))}) "
                    + ("preprocess to the same text, white space aside, with those and with the configuration's defines [iverilog -E]"
                       if x.get("ok") else "DO NOT preprocess to the same text with the configuration's defines"))
        for name, cfg in sorted(base.LEMMAS.items()):
            if cfg["module"] in ("karu64", "karudbg_core"):
                x = self.r.get("config", {}).get(name, {})
                if not x.get("ok"):
                    self.problem(f"lemma {name} with the composition's defines did not pass: {x.get('error', '')}")
                muts = x.get("mutants", {})
                self.out(f"    {name}: run by run_auth_formal.py with {' '.join(cfg['defines'])}; proved again by "
                         f"this run with the configuration's defines: BMC depth {cfg['bmc']} "
                         f"{x.get('bmc', {}).get('status', '?')}"
                         + (f", induction k={cfg['induct']} {x.get('induction', {}).get('status', '?')}" if cfg["induct"] else "")
                         + f", {sum(m['detected'] for m in muts.values())}/{len(cfg['mutants'])} controls failed as they must")
            else:
                self.out(f"    {name}: {alike('lemma ' + name)}")
        self.out("    C1: run with exactly these defines")
        self.out(f"    C6: {alike('lemma C6')}")
        for name in self.glue:
            self.out(f"    glue {name}: {alike('glue lemma ' + name)}")
        proofs = self.r["single"].get("proofs", {})
        if not proofs.get("C1", {}).get("ok"):
            self.problem("the single model is not proved with the composition's defines")
        self.out("    single model: proved with these defines, and also with those of lemma C10 ("
                 + "; ".join(f"{c}: {'proved' if p.get('ok') else 'NOT PROVED'}" for c, p in proofs.items()) + ")")
        self.out("    wiring: read from the netlist elaborated with these defines")
        # karudbg_auth's parameter: which lemma is proved for which value
        values = {}
        for name, cfg in sorted(base.LEMMAS.items()):
            if cfg["module"] == "karudbg_auth":
                v = [p.split()[1] for p in cfg.get("chparams", []) if p.startswith("WINDOW_LOG2 ")] or ["0"]
                values.setdefault(v[0], []).append(name)
        for run in self.r["glue"].get("gate", {}).get("runs", []):
            v = [p.split()[1] for p in run["chparams"] if p.startswith("WINDOW_LOG2 ")] or ["0"]
            values.setdefault(v[0], []).append("glue gate")
        self.out("  Parameters: the composition is for WINDOW_LOG2 = 0 (no hardware window limit), the default of "
                 "karudbg_auth, karudbg_core and karudbg_top. The lemmas on karudbg_auth by value: "
                 + "; ".join(f"{v}: {', '.join(n)}" for v, n in sorted(values.items(), key=lambda x: int(x[0]))) + ".")
        self.out("  The island's ROM and SRAM ranges and AUTH_ROM_BASE/END are the defaults in every model.")
        same = sorted(n for n, x in src.items() if n != "control" and x.get("image_differ") == [])
        changed = sorted(n for n, x in src.items() if n != "control" and x.get("image_differ"))
        self.out("  The VCU118 debug image. Three runs touch its configuration; they are not one configuration:")
        self.out("    its define list (check_auth_bypass.py, IMAGE_DEFINES): " + " ".join(c1.IMAGE_DEFINES))
        self.out("    its parameters (check_auth_bypass.py, IMAGE_PARAMS): "
                 + ", ".join(f"{k} = {v}" for k, v in c1.IMAGE_PARAMS.items()))
        self.out(f"    (a) the single model's configuration 'image': {'proved' if proofs.get('image', {}).get('ok') else 'NOT PROVED'} "
                 "(section 2). It has the define list only.")
        self.out("        Its top-level parameters are karudbg_core's defaults, not the image's, and the")
        self.out("        authentication block is cut out of it, as is every instance but the core and the")
        self.out("        island. It is evidence for the bus ownership property of C9 with C10 under the")
        self.out("        image's defines, and for nothing else of the image.")
        self.out("    (b) lemma C1's --image inventory (check_auth_bypass.py --image) is the run with the image's")
        self.out("        parameters as well: the I-cache in the fetch path, the island reset vector, external")
        self.out("        time and the window parameter 31. This script does not make that run.")
        self.out("    (c) the window timer at width 31 is lemma C5w31 (section 1.1), with glue gate's variant for 31.")
        self.out(f"    sources unchanged by the define list, white space aside [iverilog -E]: {', '.join(same) or 'none'}"
                 + (f"; CHANGED: {', '.join(changed)}" if changed else ""))
        self.out("    Fetch-to-execute provenance (finding F8) is open for the image as for every configuration.")
        text = ("the VCU118 debug image's configuration: lemmas C4, C6cone, C8 and C10 are not run with its "
                "defines; the single model's 'image' run has its define list but karudbg_core's default "
                "parameters and no authentication block; lemma C1 has the image's parameters only in its own "
                "--image run, which this script does not make; and of the lemmas on karudbg_auth only C5w31 "
                "and glue gate have its AUTH_WINDOW_LOG2 = 31. Its top level (flow/fpga) is in no model")
        self.out(f"    NOT MACHINE-CHECKED ({self.argument(text)}): {text}")
        self.out("")

    def claims(self):
        self.out("4. Claims T1-T4 (plan 4) from the lemmas")
        self.out("")
        self.out("  Cycle 0 is the last POR cycle. Each step lists what it rests on. A step with a reference")
        self.out("  marked NOT MACHINE-CHECKED is an argument at that point, not a proof.")
        for claim in CLAIMS:
            if norm(claim["quote"]) not in self.plan:
                self.problem(f"claim {claim['id']}: its text is not in {PLAN}: {claim['quote']}")
            self.current, self.flag = set(), False
            self.out("")
            self.out(f"  {claim['id']}: {claim['title']}")
            for n, (text, refs) in enumerate(claim["steps"], 1):
                self.out(f"    step {n}. {text}")
                for ref in refs:
                    self.out(f"        - {self.ref(ref)[0]}")
            self.out(f"    => {claim['id']}: "
                     + ("every cited assertion is proved in this run" if not self.flag else
                        "NOT ESTABLISHED: a cited item is missing or did not pass")
                     + f"; NOT MACHINE-CHECKED in the derivation: {', '.join(f'({n})' for n in sorted(self.current)) or 'no step marked'}"
                     + ". That the steps together give the claim is read, not checked.")
        self.out("")

    def tail(self):
        self.out("5. Platform assumptions that remain (plan 1, 6, 9)")
        for pid, p in PLATFORM.items():
            for q in p["quotes"]:
                if norm(q) not in self.plan:
                    self.problem(f"platform assumption {pid}: quote not found in {PLAN}: {q}")
            self.out(f"  {pid}: {p['text']}")
        if norm(FORMER["quote"]) not in self.plan:
            self.problem(f"quote not found in {PLAN}: {FORMER['quote']}")
        self.out(f"  No longer an assumption: {FORMER['text']}")
        self.out("")
        self.out("6. Everything in this report that is NOT MACHINE-CHECKED")
        for n, a in enumerate(self.arguments, 1):
            self.out(f"  ({n}) {a}")
        self.out("  Also: lemma C1 is structural (a path counts whether or not it can carry a value); the")
        self.out("  lemmas and the single model stop at karudbg_core, only C1 runs on karudbg_top; the")
        self.out("  VCU118 top is not karudbg_top.")
        self.out("")
        self.out("7. Findings")
        for f in FINDINGS:
            self.out(f"  {f['id']} [{finding_state(f, self.r, self.single_ok())[1]}] {f['text']}")
        self.out("")

    def build(self):
        self.evidence()
        self.single()
        self.assumptions()
        self.claims()
        self.tail()
        return self


def initials_check():
    files = sorted(set(f for cfg in list(base.LEMMAS.values()) for f in [cfg["src"]] +
                       (cfg["extra"] if isinstance(cfg["extra"], list) else [])) |
                   {"rtl/karu64.v", "rtl/karu_csr.v", "dbg/karudbg_core.v", "dbg/karudbg_island.v", "dbg/karudbg_axi.v"})
    errors, found = [], 0
    for f in files:
        if f.startswith(FORMAL):
            continue
        text = read(f)
        for m in re.finditer(r"^[ \t]*initial\b", text, re.M):
            found += 1
            chunk = text[m.start():m.start() + 400]
            if not any(a in chunk for a in INITIALS.get(f, [])):
                errors.append(f"unlisted initial block in {f}, line {text.count(chr(10), 0, m.start()) + 1}")
        for m in re.finditer(r"^[ \t]*reg\b[^;=]*=[^=]", text, re.M):
            errors.append(f"register with an initial value in {f}, line {text.count(chr(10), 0, m.start()) + 1}")
    return dict(ok=not errors, errors=errors, found=found, files=files)


def check_texts(report):
    """The expressions of every implication check, taken from the blocks."""
    texts = {}
    for spec in checks_table().values():
        for kind, where, frag in spec["hyps"] + [spec["concl"]]:
            if kind == "text":
                texts[kind, where, frag] = frag
            else:
                src = (report.model_sources() if where == "link" else report.glue_sources(where)
                       if where in report.glue else report.lemma_sources(where))
                texts[kind, where, frag] = report.find(src, frag, kind)[0]
    return texts


# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", help="the repository (default: found from dbg/karudbg.f above this script)")
    parser.add_argument("--out", default="_build/formal-compose/run", help="output directory, inside the repository")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=2400, help="per solver or script run, seconds")
    parser.add_argument("--base-controls", action="store_true",
                        help="run C1 and C6 with --self-test (their own negative controls)")
    parser.add_argument("--mailbox-reading", action="store_true",
                        help="accept that T1 gives the two runs the same authdata read data, status words "
                             "included (finding F7), whatever the plan says. Not needed while the plan's T1 says "
                             "so itself (doc/debug-auth-plan.md section 4, as reworded on 2026-11-19): the "
                             "script reads the bullet")
    parser.add_argument("--tx-words-only", action="store_true",
                        help="check against the earlier wording of T1, 'the same mailbox TX words': the shared "
                             "read data of the C3 miter is then undischarged and the run fails")
    parser.add_argument("--only", help="development only: run only the tasks whose name starts with one of "
                                       "these comma-separated prefixes; the run does not pass")
    parser.add_argument("--reuse", action="store_true",
                        help="development only: take a task's result from <out>/tasks.json when the RTL and "
                             "property files are unchanged; the report says so and the run does not pass")
    args = parser.parse_args()
    # T1's third bullet as the plan words it: the hypothesis that the C3 miter's
    # shared read data has to be an instance of.
    plan = (ROOT / "doc/debug-auth-plan.md").read_text()
    t1 = plan[plan.index("**T1 "):plan.index("**T2 ")] if "**T1 " in plan and "**T2 " in plan else ""
    plan_reading = " ".join(t1.split()).find("the same authdata read data: the mailbox's TX words and its status words") >= 0
    if args.tx_words_only and args.mailbox_reading:
        parser.error("--tx-words-only and --mailbox-reading exclude each other")
    reading_source = None if args.tx_words_only else "flag" if args.mailbox_reading else "plan" if plan_reading else None
    args.mailbox_reading = reading_source is not None
    out = (ROOT / args.out).resolve()
    if ROOT not in out.parents:
        parser.error("--out must be inside the repository")
    out.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("TMPDIR", str(ROOT / "_build/tmp"))
    Path(os.environ["TMPDIR"]).mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()

    inputs = sorted(set(list((ROOT / "rtl").rglob("*.v")) + list((ROOT / "rtl").rglob("*.vh")) +
                        list((ROOT / "dbg").glob("*.v")) + list((ROOT / "dbg").glob("*.vh")) +
                        list((ROOT / FORMAL).glob("*")) + list(COMPOSE.glob("compose_*")) +
                        [ROOT / "dbg/karudbg.f", ROOT / "Makefile"] +
                        [ROOT / "test/dbg" / f for f in ("run_auth_formal.py", "check_auth_bypass.py", "check_auth_reset.py")]))
    key = sha(*[p.read_bytes() for p in inputs])
    old = {}
    if args.reuse and (out / "tasks.json").exists():
        saved = json.loads((out / "tasks.json").read_text())
        old = saved["tasks"] if saved.get("key") == key else {}

    # The composition's configuration is lemma C1's; the single model is also
    # proved with lemma C10's own defines.
    config = list(c1.DEFINES)
    configs = {"C1": config, "lemma": list(base.LEMMAS["C10"]["defines"]), "image": list(c1.IMAGE_DEFINES)}
    if sorted(base.LEMMAS["C10"]["defines"]) != sorted(base.LEMMAS["C6cone"]["defines"]):
        raise RuntimeError("C10 and C6cone are run with different defines")
    tasks = {}
    for name in base.LEMMAS:
        tasks[f"lemmas/{name}"] = lambda name=name: base_lemma(out, name, args.timeout)
    self_test = ["--self-test"] if args.base_controls else []
    tasks["scripts/C1"] = lambda: base_script(out, "C1", [str(ROOT / "test/dbg/check_auth_bypass.py"), "--out",
                                                           str(out / "c1")] + self_test, args.timeout)
    tasks["scripts/C6"] = lambda: base_script(out, "C6", [str(ROOT / "test/dbg/check_auth_reset.py")] + self_test,
                                              args.timeout)
    for cname, defines in configs.items():
        tasks[f"single/proofs/{cname}"] = lambda c=cname, d=defines: single_proof(out, c, d, args.timeout)
    tasks["single/cover"] = lambda: single_cover(out, config, args.timeout)
    for m in single_mutants():
        tasks[f"single/mutants/{m[0]}"] = lambda m=m: single_mutant(out, config, m, args.timeout)
    for name, cfg in glue_table().items():
        tasks[f"glue/{name}"] = lambda name=name, cfg=cfg: glue_lemma(out, name, cfg, args.timeout)
    for name, cfg in base.LEMMAS.items():
        if cfg["module"] in ("karu64", "karudbg_core"):
            tasks[f"config/{name}"] = lambda name=name: lemma_at(out, name, config, args.timeout)
    tasks["wiring"] = lambda: wiring_check(out, config)
    tasks["witness/status"] = lambda: witness_status(out, args.timeout)

    if args.only:
        tasks = {n: t for n, t in tasks.items() if n.startswith(tuple(args.only.split(","))) or n in old}

    def guarded(name, fn):
        if name in old:
            return dict(old[name], reused=True)
        try:
            return fn()
        except Exception as e:      # a task that cannot run is a failed task
            return dict(ok=False, error=f"{type(e).__name__}: {e}")
    # the long tasks first
    order = sorted(tasks, key=lambda n: (not n.startswith("single/proofs"), not n.startswith(("scripts", "single")), n))
    done = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {name: pool.submit(guarded, name, tasks[name]) for name in order}
        for name in order:
            done[name] = futures[name].result()
            print(f"  [{round(time.monotonic() - t0):5d} s] {name}: "
                  f"{'ok' if done[name].get('ok') or done[name].get('detected') else 'NOT OK'}"
                  f"{' (reused)' if done[name].get('reused') else ''}", flush=True)
    (out / "tasks.json").write_text(json.dumps(dict(key=key, tasks=done), indent=1) + "\n")

    results = dict(options=dict(base_controls=args.base_controls, jobs=args.jobs, config=config,
                                mailbox_reading=args.mailbox_reading, reading_source=reading_source),
                   lemmas={}, scripts={}, glue={}, config={},
                   witness={}, single=dict(proofs={}, mutants={}), checks={}, wiring={})
    for name, res in done.items():
        parts = name.split("/")
        node = results
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        if name == "wiring":
            results["wiring"] = res.get("groups") or {"netlist": dict(res, pairs=0, what="")}
        else:
            node[parts[-1]] = res
    results["initials"] = initials_check()
    results["sources"] = guarded("sources", lambda: config_sources(out, config))
    report = Report(results)
    try:
        texts = check_texts(report)
        k3 = [(c.split(".")[1], i.split(".")[1]) for c, i in wiring_table()["K3"][1]]
        for name, spec in checks_table().items():
            results["checks"][name] = guarded(f"checks/{name}", lambda: check_run(out / "checks", name, spec, texts, k3))
    except Exception as e:
        report.problem(f"implication checks could not be built: {type(e).__name__}: {e}")
    report.problems.clear()
    report.build()
    # The same results under the wider reading of T1 (finding F7), so that one
    # run shows what the verdict depends on.
    other = None
    if not args.mailbox_reading:
        other = Report(dict(results, options=dict(results["options"], mailbox_reading=True))).build().problems

    reused = sorted(n for n, r in done.items() if r.get("reused"))
    for r in [report] + ([other] if other is not None else []):
        add = r.problem if isinstance(r, Report) else r.append
        if args.only:
            add("--only: not every task was run")
        if reused:
            add(f"{len(reused)} task results were reused from an earlier run (--reuse): not a fresh run")
    hashes = {rel(p): file_sha256(p)[:16] for p in inputs + [Path(__file__).resolve()]
              if p.parent.name == "formal" or p.name in ("karu64.v", "karu_csr.v", "karudbg.v", "karudbg_auth.v",
                                                         "karudbg_island.v", "karudbg_axi.v", "karudbg_core.v",
                                                         "karudbg_sba.v", "karudbg_rom.v", "run_auth_formal.py",
                                                         "check_auth_bypass.py", "check_auth_reset.py",
                                                         "run_auth_compose.py")}
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE, text=True).stdout.strip()
    ok = not report.problems
    s = results["single"]
    n_mut = sum(bool(m.get("detected")) for m in s["mutants"].values())
    n_glue_mut = sum(bool(m.get("detected")) for g in results["glue"].values() for m in g.get("mutants", {}).values())
    states = {f["id"]: finding_state(f, results, report.single_ok()) for f in FINDINGS}
    open_f = sum(is_open for is_open, _ in states.values())
    summary = (f"{'PASS' if ok else 'FAIL'} compose: single model C9 with C10 "
               f"{', '.join(c + ' ' + ('proved' if p.get('ok') else 'FAILED') for c, p in s['proofs'].items())} "
               f"(BMC depth {SINGLE_BMC}, induction), {n_mut}/{len(s['mutants'])} controls failed as they must; "
               f"{sum(bool(g.get('ok')) for g in results['glue'].values())}/{len(results['glue'])} glue lemmas, "
               f"{n_glue_mut} controls; {sum(bool(c.get('ok')) for c in results['checks'].values())}/"
               f"{len(results['checks'])} implications; {sum(bool(l.get('ok')) for l in results['lemmas'].values())}/"
               f"{len(results['lemmas'])} lemmas, C1 and C6 "
               f"{'passed' if len(results['scripts']) == 2 and all(x.get('ok') for x in results['scripts'].values()) else 'FAILED'}; "
               f"{report.totals['assumptions']} assumptions and {report.totals['restrictions']} model restrictions, "
               f"{sum('UNDISCHARGED' in p for p in report.problems)} undischarged; "
               f"{len(report.arguments)} steps not machine-checked; {open_f} findings open; "
               f"{round(time.monotonic() - t0)} s")
    header = ["Composition report: debug authentication, claims T1-T4 from lemmas C1-C10",
              f"{rel(Path(__file__).resolve())}, {time.strftime('%Y-%m-%d %H:%M:%S %Z')}, git HEAD {head} plus the "
              "working tree; SHA-256 of each file the evidence is for, first 16 hex digits "
              "(sha256sum FILE | cut -c1-16):"]
    header += [f"  {h}  {f}" for f, h in sorted(hashes.items())]
    header += ["", summary, ""]
    if args.mailbox_reading and reading_source == "plan":
        header += ["T1's third bullet, read from doc/debug-auth-plan.md, gives the two runs the same authdata read "
                   "data, status words included (the wording since 2026-11-19). See finding F7.", ""]
    elif args.mailbox_reading:
        header += ["READING ACCEPTED ON THE COMMAND LINE (--mailbox-reading): T1's 'the same mailbox TX words' is "
                   "read as 'the same authdata read data, status words included'. See finding F7.", ""]
    else:
        extra = [p for p in (other or []) if p not in report.problems]
        left = [p for p in report.problems if p in (other or [])]
        reading = ("With --mailbox-reading (T1's 'the same mailbox TX words' read as 'the same authdata read data, "
                   "status words included'; finding F7) the same results give "
                   + (f"{len(left) + len(extra)} problem(s): " + "; ".join(left + extra) if left or extra
                      else "no problem: every assumption is then discharged."))
        header += [reading, ""]
    if report.problems:
        header += ["PROBLEMS (each fails the run):"] + [f"  - {p}" for p in report.problems] + [""]
    (out / "composition-report.txt").write_text("\n".join(header + report.lines) + "\n")
    results.update(ok=ok, summary=summary, problems=report.problems, not_machine_checked=report.arguments,
                   interface=INTERFACE, hashes=hashes, seconds=round(time.monotonic() - t0),
                   findings=[dict(id=f["id"], open=states[f["id"]][0], state=states[f["id"]][1], text=f["text"])
                             for f in FINDINGS])
    (out / "results.json").write_text(json.dumps(results, indent=1, default=str) + "\n")
    for p in report.problems:
        print(f"PROBLEM: {p}")
    print(f"report: {(out / 'composition-report.txt').relative_to(ROOT)}")
    if not args.mailbox_reading:
        print(reading)
    print(summary)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
