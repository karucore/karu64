#!/usr/bin/env python3
"""Prove SBA register/ownership tests discriminate selected RTL faults."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", default="_build/dbg/negative-sba")
args = parser.parse_args()
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
source = Path("dbg/karudbg_sba.v").read_text()
cases = [
    ("ignored-bus-error", "if (resp_error_i != 0)", "if (1'b0)",
     "expected 2007180f"),
    ("high-address-alias", "assign req_addr_o = address_q;",
     "assign req_addr_o = {32'b0, address_q[31:0]};", "exact width/address/data"),
    ("duplicate-request", "if (req_valid_o && req_ready_i) state_q <= RESPONSE;",
     "if (1'b0) state_q <= RESPONSE;", "one request accepted"),
    ("lost-inflight-owner", "if (state_q == REQUEST) state_q <= IDLE;",
     "if (state_q != IDLE) state_q <= IDLE;", "SBAR2 response ownership"),
]
for name, old, new, expected in cases:
    if old not in source:
        raise RuntimeError(f"{name}: mutation location missing")
    mutated = out / f"{name}.v"
    mutated.write_text(source.replace(old, new))
    binary = out / f"{name}.vvp"
    subprocess.run(["iverilog", "-g2012", "-DTEST_SBA64", "-s", "tb_sba",
                    "-o", str(binary), "test/dbg/tb_sba.sv", str(mutated)],
                   check=True, timeout=20)
    result = subprocess.run(["vvp", str(binary)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=20)
    (out / f"{name}.log").write_text(result.stdout)
    if result.returncode == 0 or expected not in result.stdout:
        raise RuntimeError(f"{name}: expected diagnostic missing: {result.stdout}")
    print(f"PASS SBA negative control {name}")
