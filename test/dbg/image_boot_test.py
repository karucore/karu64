#!/usr/bin/env python3
"""Boot the debug image's composition in simulation (make image-boot-test).

Four runs of the same simulator, in parallel; each boots the chain twice
because the payload reboots through SBI system reset.

  open      lifecycle OPEN, entropy on: both boots read four seed words
  auth      lifecycle AUTH, no debugger request: the same
  seed-off  entropy strap low: seed stays in BIST, and the boot goes on
  no-zkr    control: the device tree without zkr; OpenSBI leaves
            mseccfg.SSEED clear, so the payload's seed read traps

    python3 test/dbg/image_boot_test.py --sim SIM --dir DIR -- <simulator args>
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--sim", required=True)
parser.add_argument("--dir", required=True)
parser.add_argument("rest", nargs=argparse.REMAINDER)
args = parser.parse_args()
D = Path(args.dir).resolve()
COMMON = [a for a in args.rest if a != "--"]

SEED_OK = "[sbi-seed] four seed words within 100 polls"
SEED_OFF = "[sbi-seed] seed stays in BIST"
SEED_TRAP = "[sbi-seed] FAIL: the seed access trapped"
PASS = "[sbi-reboot] PASS"
RUNS = [
    # name, ROM image, extra arguments, expected seed line (twice), passes,
    # the straps the hardware must report having sampled
    ("open",     "zkr.rom.hex",     [],              SEED_OK,  True,  "[straps] lifecycle 0 (sampled 0), hold 0, entropy 1"),
    ("auth",     "zkr.rom.hex",     ["+auth_lc=1"],  SEED_OK,  True,  "[straps] lifecycle 1 (sampled 1), hold 0, entropy 1"),
    ("seed-off", "zkr-off.rom.hex", ["+zkr_en=0"],   SEED_OFF, True,  "[straps] lifecycle 0 (sampled 0), hold 0, entropy 0"),
    ("no-zkr",   "no-zkr.rom.hex",  [],              SEED_TRAP, False, "[straps] lifecycle 0 (sampled 0), hold 0, entropy 1"),
]

def run(spec):
    name, rom, extra, seed_line, passes, straps = spec
    r = subprocess.run([args.sim, *COMMON, f"+rom={D / rom}", *extra], capture_output=True, text=True, timeout=7200)
    log = r.stdout + r.stderr
    (D / f"run-{name}.log").write_text(log)
    problems = []
    def count(text): return log.count(text)
    if re.search(r"ASSERT|FATAL", log):
        problems.append("an assertion fired")
    if straps not in log:
        problems.append(f"the straps were not as intended: expected '{straps}'")
    if passes:
        if count("fu-boot: copying boot chain") != 2: problems.append(f"fu-boot ran {count('fu-boot: copying boot chain')} times, not 2")
        if len(re.findall(r"^OpenSBI v", log, re.M)) != 2: problems.append("OpenSBI did not start twice")
        if count(seed_line) != 2: problems.append(f"'{seed_line}' seen {count(seed_line)} times, not 2")
        if PASS not in log: problems.append("no reboot PASS")
        if "[HTIF] exit 0 " not in log: problems.append("no HTIF exit 0")
        if "[sbi-seed] FAIL" in log: problems.append("a seed check failed")
    else:
        if seed_line not in log: problems.append(f"the control did not report '{seed_line}'")
        if PASS in log: problems.append("the control passed")
    version = re.search(r"^OpenSBI v\S+", log, re.M)
    return name, problems, (version.group(0) if version else "no OpenSBI banner")

with ThreadPoolExecutor(max_workers=len(RUNS)) as pool:
    results = list(pool.map(run, RUNS))
failed = False
for name, problems, version in results:
    if problems:
        failed = True
        print(f"image-boot-test {name}: FAIL: " + "; ".join(problems))
    else:
        print(f"image-boot-test {name}: {'fails as it must' if name == 'no-zkr' else 'PASS'} ({version})")
if failed:
    sys.exit(1)
print("image-boot-test: PASS (island ROM -> fu-boot -> OpenSBI -> S-mode payload; seed read as Linux reads it; reboot; second boot)")
