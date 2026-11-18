#!/usr/bin/env python3
"""Run the Zkr directed test images on their benches (part of make zkr-test).

Four runs must pass: M/S/U without H, the full table with H, the subset that
Spike also implements, and the strap-low image with the strap low. Two
controls must fail: the strap-low image with the strap high, and the full
image with the strap low. A run passes when HTIF reports exit 0 and the log
has no failure marker.

    python3 test/zkr_run.py --dir _build/zkr
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, re, subprocess, sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--dir", required=True)
parser.add_argument("--bench", default=None, help="bench directory holding Vhtif and Vhtif_h (default: --dir)")
parser.add_argument("--quiet", action="store_true")
args = parser.parse_args()
D = Path(args.dir).resolve()
B = Path(args.bench).resolve() if args.bench else D
RUN = ["+tohost=1000", "+max_cycles=6000000"]
BAD = re.compile(r"FAIL|ERROR|FATAL|ASSERT|\*\*TIMEOUT\*\*|\*\*TRAP\*\*")

def run(name, bench, image, extra=()):
    r = subprocess.run([str(B / bench / "Vhtif_tb"), f"+hex={D / image}", *extra, *RUN],
                       capture_output=True, text=True, timeout=1800)
    log = r.stdout + r.stderr
    (D / f"{name}.log").write_text(log)
    done = re.search(r"\[HTIF\] exit (\d+) @.*", log)
    ok = bool(done) and done.group(1) == "0" and not BAD.search(log)
    return ok, (done.group(0) if done else log.strip().splitlines()[-1] if log.strip() else "no output")

RUNS = [("m-s-u", "Vhtif", "zkr.hex", ()),
        ("with-h", "Vhtif_h", "zkr_h.hex", ()),
        ("cross", "Vhtif_h", "zkr_xchk.hex", ()),
        ("strap-low", "Vhtif_h", "zkr_off.hex", ("+zkr_en=0",))]
CONTROLS = [("control-strap-high", "Vhtif_h", "zkr_off.hex", ()),
            ("control-strap-low", "Vhtif_h", "zkr_h.hex", ("+zkr_en=0",))]
failed = []
for name, bench, image, extra in RUNS:
    ok, line = run(name, bench, image, extra)
    if not args.quiet or not ok:
        print(f"zkr-test {name}: {'PASS' if ok else 'FAIL'}  {line}")
    if not ok:
        failed.append(name)
for name, bench, image, extra in CONTROLS:
    ok, line = run(name, bench, image, extra)
    if not args.quiet or ok:
        print(f"zkr-test {name}: {'NOT DETECTED' if ok else 'fails as it must'}  {line}")
    if ok:
        failed.append(name)
if failed:
    print("zkr-test: FAIL " + ", ".join(failed))
    sys.exit(1)
print("zkr-test: PASS (4 runs, 2 controls)")
