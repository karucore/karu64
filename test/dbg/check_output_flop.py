#!/usr/bin/env python3
"""Require a module output port to be driven directly by a flip-flop's Q.

Used for karudbg's ndmreset_o (security review 2026-11-15, S10): an output
that feeds asynchronous reset synchronizers must not be a combinational
function, which could glitch when its inputs change on the same edge.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys


def driver_cells(sources, top, port, defines, includes, out):
    out.mkdir(parents=True, exist_ok=True)
    flags = " ".join([f"-D{d}" for d in defines] + [f"-I{i}" for i in includes])
    netlist = out / "netlist.json"
    # opt_clean -purge makes the port net canonical, so an assign alias
    # cannot hide the driving cell behind a renamed wire.
    script = (f"read_verilog {flags} {' '.join(map(str, sources))}; "
              f"hierarchy -check -top {top}; proc; opt -full; opt_clean -purge; "
              f"write_json {netlist}")
    result = subprocess.run(["yosys", "-q", "-l", str(out / "yosys.log"), "-p", script],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        raise RuntimeError(f"yosys failed; see {out / 'yosys.log'}\n{result.stdout}")
    module = json.loads(netlist.read_text())["modules"][top]
    if port not in module["ports"] or module["ports"][port]["direction"] != "output":
        raise RuntimeError(f"{top}.{port} is not an output port")
    bits = module["ports"][port]["bits"]
    drivers = []
    for name, cell in module["cells"].items():
        for pin, direction in cell.get("port_directions", {}).items():
            if direction == "output" and any(b in bits for b in cell["connections"][pin]):
                drivers.append((name, cell["type"], pin))
    return bits, drivers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top", required=True)
    parser.add_argument("--port", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("-D", dest="defines", action="append", default=[])
    parser.add_argument("-I", dest="includes", action="append", default=[])
    parser.add_argument("sources", nargs="+", type=Path)
    args = parser.parse_args()
    if not shutil.which("yosys"):
        sys.exit("check_output_flop: yosys not found")
    bits, drivers = driver_cells(args.sources, args.top, args.port, args.defines,
                                 args.includes, Path(args.out))
    flops = [d for d in drivers if "dff" in d[1].lower() and d[2] == "Q"]
    if any(isinstance(b, str) for b in bits):
        print(f"FAIL {args.top}.{args.port}: constant-driven bits {bits}")
        sys.exit(1)
    if len(drivers) != 1 or len(flops) != 1:
        print(f"FAIL {args.top}.{args.port}: not driven directly by one flop: {drivers}")
        sys.exit(1)
    print(f"PASS {args.top}.{args.port} driven by flop {flops[0][0]} ({flops[0][1]})")


if __name__ == "__main__":
    main()
