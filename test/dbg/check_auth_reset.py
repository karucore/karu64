#!/usr/bin/env python3
"""Lemma C6 (doc/debug-auth-plan.md 5.2): reset values of the debug modules.

Each module is elaborated and flattened by Yosys, then simulated in four
states for exactly one clock edge with rst=1, every other input X and every
register X beforehand (`sim -reset rst -rstlen 1 -n 1 -w`). The value each
register holds after that edge is its reset value whatever the earlier state
and inputs were; an X means "not reset, or reset to an input-dependent
value". The check then requires, for every flop bit in the module:

  * value 0, or
  * the exact non-zero constant listed in NONZERO, or
  * X only for a register listed in UNRESET, with its justification.

A wrong reset constant, an inverted reset polarity, a missing reset and a
register reset from the wrong net all change that value, so all four fail.
A register that drives nothing is removed with the unused logic before the
simulation and is not checked; "present" lists registers that must be in the
netlist (the window counter of karudbg_auth exists only with WINDOW_LOG2 != 0).
The input-dependent reset values of karudbg_auth (UNRESET there) are proved
by the formal block test/dbg/formal/c6_karudbg_auth.vh, and the wiring of
each instance's reset pin by reset_pins() below.

--self-test applies the negative controls: each mutant must FAIL.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFINES = "-DKARU_DBG -DKARU_DBG_AUTH -DKARU_DBG_SBA -DKARU_DBG_AUTOEXEC"
MODULES = {
    "karudbg_auth": dict(
        files=["dbg/karudbg_auth.v"], memory_map=True, nonzero={},
        # POR-sampled trust inputs set these reset values (plan 2.2): lc_i,
        # hold_strap_i and revoke_i. Their values are proved by lemma C6v.
        unreset={"lc_q", "hold_q", "revoke_q", "debug_enable_o", "sys_reset_o"}),
    # The same block with the hardware window limit, at the VCU118 value.
    # With the default WINDOW_LOG2 = 0 the window counter win_cnt drives
    # nothing and Yosys removes it before the simulation, so the entry above
    # does not cover it; "present" makes its absence here an error.
    "karudbg_auth WINDOW_LOG2=31": dict(
        top="karudbg_auth", files=["dbg/karudbg_auth.v"], memory_map=True, nonzero={},
        chparam="WINDOW_LOG2 31", present={"win_cnt"},
        unreset={"lc_q", "hold_q", "revoke_q", "debug_enable_o", "sys_reset_o"}),
    "karudbg": dict(
        files=["dbg/karudbg.v", "dbg/karudbg_rom.v", "dbg/karudbg_sba.v"], memory_map=True,
        nonzero={"sba_req_size_o": "010"}, unreset=set()),
    "karudbg_island": dict(
        files=["dbg/karudbg_island.v", "dbg/karudbg_axi.v"], memory_map=False,
        chparam="SRAM_END 32'h00020040",
        # single-beat bridges: rlast is the constant 1
        nonzero={"d_bridge.s_rlast": "1", "i_bridge.s_rlast": "1"},
        # Bridge payload registers, each qualified by a reset pending/valid
        # flag (rd_pending, aw_pending, w_pending, s_rvalid, s_bvalid).
        unreset={"d_be", "d_bridge.mem_wdata_o", "d_bridge.rd_address", "d_bridge.rd_id",
                 "d_bridge.rd_len", "d_bridge.rd_error", "d_bridge.wr_address",
                 "d_bridge.wr_id", "d_bridge.wr_last", "d_bridge.wr_len", "d_bridge.wr_error",
                 "i_bridge.rd_address", "i_bridge.rd_id", "i_bridge.rd_len",
                 "i_bridge.rd_error"},
        # The ROM is constant. The SRAM is deliberately not reset: it keeps
        # its contents across hart and system resets, so a production ROM
        # must not leave secrets in it (plan A2).
        memories={"rom", "sram"}),
}
# Reset pin of each instance in karudbg_core (KARU_DBG_AUTH): POR-domain
# blocks take rst; everything on the hart side takes core_rst.
PINS = {"karudbg_auth": "rst", "karudbg": "rst", "karudbg_island": "core_rst", "karu64": "core_rst"}

MUTANTS = [
    # (name, module, file, before, after)
    ("grant_resets_to_1", "karudbg_auth", "dbg/karudbg_auth.v",
     "auth_req_q <= 0; auth_unlock_q <= 0; boot_done_q <= 0;",
     "auth_req_q <= 0; auth_unlock_q <= 1; boot_done_q <= 0;"),
    ("boot_done_not_reset", "karudbg_auth", "dbg/karudbg_auth.v",
     "auth_req_q <= 0; auth_unlock_q <= 0; boot_done_q <= 0;",
     "auth_req_q <= 0; auth_unlock_q <= 0;"),
    ("mailbox_reset_inverted", "karudbg_auth", "dbg/karudbg_auth.v",
     "        if (rst) begin\n            rx_rd <= 0;", "        if (!rst) begin\n            rx_rd <= 0;"),
    ("window_counter_not_reset", "karudbg_auth WINDOW_LOG2=31", "dbg/karudbg_auth.v",
     "            win_cnt <= {(WINDOW_LOG2+1){1'b0}};\n", ""),
    ("island_owner_not_reset", "karudbg_island", "dbg/karudbg_island.v",
     "im_owner <= 0; dr_owner <= 0; dw_owner <= 0; dw_active <= 0;",
     "im_owner <= 0; dr_owner <= 0; dw_owner <= 0;"),
]


def yosys(script):
    r = subprocess.run(["yosys", "-q", "-p", script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        raise RuntimeError("yosys failed:\n" + "\n".join(r.stdout.splitlines()[-5:]))


def reset_values(top, cfg, work, override=None):
    """{register name: reset value string, MSB first} for every flop of top."""
    netlist = work / f"{top}.json"
    files = [str(override[1]) if override and override[0] == f else str(ROOT / f) for f in cfg["files"]]
    chp = f"chparam -set {cfg['chparam']} {top}; " if "chparam" in cfg else ""
    yosys(f"read_verilog {DEFINES} -I{ROOT}/dbg -I{ROOT}/rtl {' '.join(files)}; {chp}"
          f"hierarchy -top {top}; proc; flatten; {'memory_map; ' if cfg['memory_map'] else ''}opt -full; opt_clean -purge; "
          f"sim -clock clk -reset rst -rstlen 1 -n 1 -w; write_json {netlist}")
    module = json.loads(netlist.read_text())["modules"][top]
    left = set(module.get("memories", {})) - cfg.get("memories", set())
    if left:
        raise RuntimeError(f"{top}: memories not covered: {sorted(left)}")
    owner = {}
    for name, net in module["netnames"].items():
        init = net.get("attributes", {}).get("init")
        for i, bit in enumerate(net["bits"]):
            # prefer a public name that carries the simulated value
            if bit not in owner or (init is not None and owner[bit][2] is None):
                owner[bit] = (name, i, init)
    values = {}
    for cell in module["cells"].values():
        if "dff" not in cell["type"] and "latch" not in cell["type"]:
            continue
        for bit in cell["connections"]["Q"]:
            name, i, init = owner[bit]
            v = init[len(init) - 1 - i] if init is not None and i < len(init) else "x"
            name = "<sram index>" if name.startswith("$shr$") else name
            values.setdefault(name, {})[i] = v
    return {n: "".join(bits[i] for i in sorted(bits, reverse=True)) for n, bits in values.items()}


def judge(top, cfg, values):
    errors = []
    for name, v in sorted(values.items()):
        if name in cfg["unreset"]:
            continue
        if name in cfg["nonzero"]:
            if v != cfg["nonzero"][name]:
                errors.append(f"{name} resets to {v}, expected {cfg['nonzero'][name]}")
        elif set(v) != {"0"}:
            errors.append(f"{name} resets to {v}, expected 0")
    stale = sorted(n for n in cfg["unreset"] if n not in values or "x" not in values[n])
    if stale:
        errors.append(f"allowlisted as unreset but reset or absent: {stale}")
    absent = sorted(n for n in cfg.get("present", ()) if n not in values)
    if absent:
        errors.append(f"register not in the netlist, so not checked: {absent}")
    return errors


def reset_pins(work, source=None):
    """Each instance in karudbg_core gets the reset net PINS names."""
    netlist = work / "core.json"
    yosys(f"read_verilog -sv {DEFINES} -I{ROOT}/dbg -I{ROOT}/rtl {source or ROOT / 'dbg/karudbg_core.v'}; "
          f"hierarchy -top karudbg_core; proc; write_json {netlist}")
    module = next(m for n, m in json.loads(netlist.read_text())["modules"].items()
                  if n.endswith("karudbg_core"))
    nets = {n: net["bits"] for n, net in module["netnames"].items()}
    errors, seen = [], set()
    for cell in module["cells"].values():
        kind = cell["type"].split("\\")[-1]
        if kind in PINS:
            seen.add(kind)
            if cell["connections"].get("rst") != nets[PINS[kind]]:
                errors.append(f"{kind}.rst is not {PINS[kind]}")
    errors += [f"no {k} instance found" for k in sorted(set(PINS) - seen)]
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="also run the negative controls")
    args = parser.parse_args()
    ok = True
    (ROOT / "_build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / "_build") as tmp:
        work = Path(tmp)
        for top, cfg in MODULES.items():
            # the key is the module, or a label for another parameter set of cfg["top"]
            values = reset_values(cfg.get("top", top), cfg, work)
            errors = judge(top, cfg, values)
            bits = sum(len(v) for v in values.values())
            if errors:
                ok = False
                print(f"FAIL C6 {top}: " + "; ".join(errors))
            else:
                print(f"PASS C6 {top}: {len(values)} registers ({bits} bits) at their reset values after "
                      f"one reset edge from an unknown state; {len(cfg['nonzero'])} non-zero, "
                      f"{len(cfg['unreset'])} allowlisted")
        errors = reset_pins(work)
        ok = ok and not errors
        print("FAIL C6 reset pins: " + "; ".join(errors) if errors else
              "PASS C6 reset pins: " + ", ".join(f"{k}.rst={v}" for k, v in PINS.items()))
        if args.self_test:
            for name, top, path, before, after in MUTANTS:
                text = (ROOT / path).read_text()
                if text.count(before) != 1:
                    raise RuntimeError(f"mutant {name}: site not unique in {path}")
                copy = work / f"{name}.v"
                copy.write_text(text.replace(before, after))
                cfg = MODULES[top]
                errors = judge(top, cfg, reset_values(cfg.get("top", top), cfg, work, (path, copy)))
                ok = ok and bool(errors)
                print(f"{'detected' if errors else 'NOT DETECTED'} C6 mutant {name}"
                      + (f": {errors[0]}" if errors else ""))
            # Control for "present": with the default WINDOW_LOG2 the window
            # counter is not in the netlist, which must be an error.
            cfg = dict(MODULES["karudbg_auth"], present={"win_cnt"})
            errors = judge("karudbg_auth", cfg, reset_values("karudbg_auth", cfg, work))
            ok = ok and bool(errors)
            print(f"{'detected' if errors else 'NOT DETECTED'} C6 control window_counter_absent_at_default"
                  + (f": {errors[0]}" if errors else ""))
            text = (ROOT / "dbg/karudbg_core.v").read_text()
            before = ".ROM_HEX(ISLAND_ROM_HEX)) island (\n        .clk(clk), .rst(core_rst),"
            if text.count(before) != 1:
                raise RuntimeError("mutant island_on_por_reset: site not unique")
            copy = work / "core_mutant.v"
            copy.write_text(text.replace(before, before.replace(".rst(core_rst)", ".rst(rst)")))
            errors = reset_pins(work, copy)
            ok = ok and bool(errors)
            print(f"{'detected' if errors else 'NOT DETECTED'} C6 mutant island_on_por_reset"
                  + (f": {errors[0]}" if errors else ""))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
