#!/usr/bin/env python3
"""Structural check of the software-reset wiring in the VCU118 board top.

The board top cannot be simulated here (MIG, clocking and transceiver IP),
so its reset wiring is checked on the parsed netlist of
flow/fpga/vcu118_ddr_top.v with KARU_DBG, without resolving the instances:

  * the request output of the bus decode (karu_ddr_xbar.sys_reset_req_o) is
    the request input of the reset sequencer
    (karudbg_fpga_reset.soft_reset_req_i), and is a real net;
  * the sequencer's SoC reset resets the bus decode and is the hart reset of
    karudbg_core;
  * karudbg_core's own reset, which the Debug Module and transport use, is
    the sequencer's board reset and not its SoC reset: a software reset must
    not reset the Debug Module.

--mutant applies a negative control: the request input tied to 0 must fail.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOP = ROOT / "flow/fpga/vcu118_ddr_top.v"
TIED = (".soft_reset_req_i(soft_reset_req),", ".soft_reset_req_i(1'b0),")


def check(source, work):
    netlist = work / "top.json"
    result = subprocess.run(
        ["yosys", "-q", "-p",
         f"read_verilog -sv -DKARU_DBG -DKARU_ETH_SGMII -I{ROOT}/rtl -I{ROOT}/dbg -I{ROOT}/flow/fpga {source}; "
         f"proc; write_json {netlist}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        raise RuntimeError("yosys failed:\n" + "\n".join(result.stdout.splitlines()[-5:]))
    module = json.loads(netlist.read_text())["modules"]["vcu118_ddr_top"]
    cells = {}
    for cell in module["cells"].values():
        cells.setdefault(cell["type"].split("\\")[-1], []).append(cell["connections"])
    errors = []
    for kind in ("karudbg_fpga_reset", "karu_ddr_xbar", "karudbg_core"):
        if len(cells.get(kind, [])) != 1:
            errors.append(f"expected exactly one {kind} instance")
    if errors:
        return errors
    seq, xbar, core = cells["karudbg_fpga_reset"][0], cells["karu_ddr_xbar"][0], cells["karudbg_core"][0]
    request = xbar.get("sys_reset_req_o")
    if not request or not isinstance(request[0], int):
        errors.append("karu_ddr_xbar.sys_reset_req_o is not connected to a net")
    if seq.get("soft_reset_req_i") != request:
        errors.append("karudbg_fpga_reset.soft_reset_req_i is not the bus decode's request")
    soc = seq.get("soc_reset_o")
    if xbar.get("rst") != soc:
        errors.append("the bus decode is not reset by the sequencer's SoC reset")
    if core.get("hart_reset_i") != soc:
        errors.append("the hart reset is not the sequencer's SoC reset")
    if core.get("rst") != seq.get("board_reset_i") or core.get("rst") == soc:
        errors.append("karudbg_core.rst (Debug Module) is not the board reset alone")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--mutant", action="store_true")
    args = parser.parse_args()
    work = Path(args.out)
    work.mkdir(parents=True, exist_ok=True)
    errors = check(TOP, work)
    if errors:
        print("FAIL software-reset wiring: " + "; ".join(errors))
        sys.exit(1)
    print("PASS software-reset wiring in vcu118_ddr_top: request reaches the sequencer; "
          "the sequencer resets the bus decode and the hart, not the Debug Module")
    if args.mutant:
        text = TOP.read_text()
        if text.count(TIED[0]) != 1:
            raise RuntimeError("mutant site not found exactly once")
        copy = work / "vcu118_ddr_top_mutant.v"
        copy.write_text(text.replace(*TIED))
        errors = check(copy, work)
        if not errors:
            print("request tied to 0: NOT detected")
            sys.exit(1)
        print(f"detected wiring mutant (request tied to 0): {errors[0]}")


if __name__ == "__main__":
    main()
