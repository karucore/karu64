#!/usr/bin/env python3
"""Mutant controls for the Zkr access rules in rtl/karu_csr.v (make zkr-test).

Each mutant changes one rule. The bench with H is rebuilt around the mutated
file and runs the full test image, test/karu_zkr_test.S. A mutant is caught
when the run does not end with HTIF exit 0, or when an assertion fires; one
that still passes is reported as MISSED and fails the run.

    python3 test/zkr_mutants.py --out _build/zkr/mut
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True)
parser.add_argument("--jobs", type=int, default=4)
parser.add_argument("--only", default=None, help="comma-separated mutant names")
args = parser.parse_args()
OUT = Path(args.out).resolve()
IMAGES = OUT.parent                         # the test images of make zkr-test
RTL = (ROOT / "rtl/karu_csr.v").read_text()

M = [
 ("read_only_form_allowed", "        (!wen_w ||\n         (virt ? !mseccfg_sseed", "        (\n         (virt ? !mseccfg_sseed"),
 ("s_mode_without_sseed",   "(priv == PRIV_S && !mseccfg_sseed))));", "1'b0)));"),
 ("u_mode_without_useed",   "((priv == PRIV_U && !mseccfg_useed) ||", "(1'b0 ||"),
 ("u_mode_gated_by_sseed",  "((priv == PRIV_U && !mseccfg_useed) ||", "((priv == PRIV_U && !mseccfg_sseed) ||"),
 ("guest_without_sseed_is_virtual", "(virt ? !mseccfg_sseed\n", "(virt ? 1'b0\n"),
 ("guest_with_sseed_executes", "assign seed_virtual = (op_addr == 12'h015) && virt;", "assign seed_virtual = 1'b0;"),
 ("guest_gated_by_useed",   "(virt ? !mseccfg_sseed\n", "(virt ? !mseccfg_useed\n"),
 ("sseed_not_writable",     "                        mseccfg_sseed <= new_v_w[9];\n", ""),
 ("useed_not_writable",     "                        mseccfg_useed <= new_v_w[8];\n", ""),
 ("mseccfg_extra_bit",      "{54'b0, mseccfg_sseed, mseccfg_useed, 8'b0}", "{54'b0, mseccfg_sseed, mseccfg_useed, 8'h01}"),
 ("mseccfg_absent",         "12'h015,12'h747,12'h7c8,12'h7c9,12'h7ca,", "12'h015,12'h7c8,12'h7c9,12'h7ca,"),
 ("mentropystat_absent",    "12'h015,12'h747,12'h7c8,12'h7c9,12'h7ca,", "12'h015,12'h747,12'h7c8,12'h7c9,"),
 # the legality term and !trap_req overlap for a CSR instruction's own trap, so
 # removing either one alone changes nothing; both together must be caught
 ("trapping_access_reported", "assign zkr_fire_o = op_req && !rst && !trap_req && (csr_exc_o == EXC_NONE) &&", "assign zkr_fire_o = op_req && !rst &&"),
 ("select_swapped",         "op_addr == 12'h015 ? 2'd0 : op_addr == 12'h7c8 ? 2'd1 :\n                       op_addr == 12'h7c9 ? 2'd2 : 2'd3;",
                            "op_addr == 12'h015 ? 2'd0 : op_addr == 12'h7c8 ? 2'd2 :\n                       op_addr == 12'h7c9 ? 2'd1 : 2'd3;"),
 ("status_reads_configuration", "op_addr == 12'h7c9 ? 2'd2 : 2'd3;", "op_addr == 12'h7c9 ? 2'd2 : 2'd2;"),
 ("status_reads_zero",      "(op_addr == 12'h015 || op_addr == 12'h7c8 || op_addr == 12'h7c9 || op_addr == 12'h7ca) ? zkr_rdata_i :",
                            "(op_addr == 12'h015 || op_addr == 12'h7c8 || op_addr == 12'h7c9) ? zkr_rdata_i :"),
 ("write_strobe_stuck",     "assign zkr_we_o = wen_w;", "assign zkr_we_o = 1'b1;"),
]
BAD = re.compile(r"FAIL|ERROR|FATAL|ASSERT|\*\*TIMEOUT\*\*|\*\*TRAP\*\*")

def run(m):
    name, old, new = m
    if RTL.count(old) != 1:
        return name, "PATTERN", f"found {RTL.count(old)} times"
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "karu_csr.v").write_text(RTL.replace(old, new))
    bench = d / "Vhtif_h" / "Vhtif_tb"
    b = subprocess.run(["make", "-s", "-C", str(ROOT), f"ZKR_DIR={d}",
                        "ZKR_TB_SRC=$(patsubst rtl/karu_csr.v," + str(d / "karu_csr.v") + ",$(HTIF_SRC))", str(bench)],
                       capture_output=True, text=True)
    if b.returncode or not bench.exists():
        return name, "BUILD", (b.stdout + b.stderr)[-300:]
    r = subprocess.run([str(bench), f"+hex={IMAGES / 'zkr_h.hex'}", "+tohost=1000", "+max_cycles=6000000"],
                       capture_output=True, text=True, timeout=1800)
    log = r.stdout + r.stderr
    (d / "run.log").write_text(log)
    done = re.search(r"\[HTIF\] exit (\d+) @", log)
    passed = bool(done) and done.group(1) == "0" and not BAD.search(log)
    why = next((l for l in log.splitlines() if "ASSERT" in l), "") or (f"exit {done.group(1)}" if done else "no HTIF exit")
    return name, ("MISSED" if passed else "caught"), why

if args.only:
    M = [m for m in M if m[0] in args.only.split(",")]
with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    results = list(pool.map(run, M))
bad = 0
for name, verdict, why in results:
    print(f"{verdict:7s} {name:32s} {why[:110]}")
    bad += verdict != "caught"
print(f"zkr access-rule mutants: {len(results) - bad} of {len(results)} caught")
sys.exit(1 if bad else 0)
