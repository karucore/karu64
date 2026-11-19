#!/usr/bin/env python3
"""Boot the image's chain with the real U-Boot in simulation (make uboot-boot-test).

The ROM is built as for the board: fu-boot, karudeb's OpenSBI and device tree
with zkr, and U-Boot from flow/build_uboot.sh, here with a boot command for
the simulation in place of the network boot (test/dbg/uboot_sim_bootcmd.txt):
ask the random-number driver for 16 bytes, print the command's status, and
on the first boot reset the system through SBI; the second boot ends the
simulation. Two runs, in parallel:

  seed-on   the entropy source on: the driver delivers, in both boots
  seed-off  the entropy strap low: seed stays in BIST. The driver as
            released by U-Boot would wait for ever; the patched one
            (flow/boot/uboot-zkr-timeout.patch) gives up, U-Boot says so,
            and both boots go on

    python3 test/dbg/uboot_boot_test.py --sim SIM --dir DIR --rom ROM --release v2026.10 -- <simulator args>
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--sim", required=True)
parser.add_argument("--dir", required=True, help="where the run logs go")
parser.add_argument("--rom", required=True, help="the ROM image with U-Boot in its slot")
parser.add_argument("--release", required=True, help="the U-Boot release the banner must name, as its tag: v2026.10")
parser.add_argument("rest", nargs=argparse.REMAINDER)
args = parser.parse_args()
D = Path(args.dir).resolve()
D.mkdir(parents=True, exist_ok=True)
COMMON = [a for a in args.rest if a != "--"]
BANNER = "U-Boot " + args.release.lstrip("v")
RUNS = [
    # name, extra arguments, the rng command's status, what it prints
    ("seed-on",  [],            "[uboot-test] rng rc=0", r"^00000000: ([0-9a-f]{2} ){15}[0-9a-f]{2}"),
    ("seed-off", ["+zkr_en=0"], "[uboot-test] rng rc=1", r"^No RNG device"),
]

def run(spec):
    name, extra, status, printed = spec
    # The console goes straight to the log file, so that a run can be watched.
    with (D / f"run-{name}.log").open("w") as out:
        subprocess.run([args.sim, *COMMON, f"+rom={Path(args.rom).resolve()}", *extra], stdout=out, stderr=subprocess.STDOUT, timeout=28800)
    log = (D / f"run-{name}.log").read_text(errors="replace").replace("\r", "")
    problems = []
    def count(text): return log.count(text)
    if re.search(r"ASSERT|FATAL", log): problems.append("an assertion fired")
    if count("fu-boot: copying boot chain") != 2: problems.append(f"fu-boot ran {count('fu-boot: copying boot chain')} times, not 2")
    if len(re.findall(r"^OpenSBI v", log, re.M)) != 2: problems.append("OpenSBI did not start twice")
    if count(BANNER) != 2: problems.append(f"'{BANNER}' seen {count(BANNER)} times, not 2")
    if len(re.findall(r"^Net: +eth0: ethernet@", log, re.M)) != 2: problems.append("the Ethernet device was not found in both boots")
    if count(status) != 2: problems.append(f"'{status}' seen {count(status)} times, not 2")
    if len(re.findall(printed, log, re.M)) != 2: problems.append(f"the rng command did not print /{printed}/ in both boots")
    if count("[uboot-test] resetting") != 1 or count("[uboot-test] second boot") != 1: problems.append("not exactly one reset between two boots")
    if "[HTIF] exit 0 " not in log: problems.append("no HTIF exit 0")
    cycles = re.search(r"\[HTIF\] exit 0 @ cyc=(\d+)", log)
    return name, problems, int(cycles.group(1)) if cycles else 0

with ThreadPoolExecutor(max_workers=len(RUNS)) as pool:
    results = list(pool.map(run, RUNS))
failed = 0
for name, problems, cycles in results:
    print(f"{'FAIL' if problems else 'ok  '} {name:9s} {cycles} cycles {'; '.join(problems)}")
    failed += bool(problems)
if failed:
    sys.exit(1)
print(f"uboot-boot-test: PASS ({BANNER} from the ROM, twice in each of {len(RUNS)} runs; the random-number driver "
      "delivers with the entropy source on and gives up with it off)")
