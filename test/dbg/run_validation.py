#!/usr/bin/env python3
"""Record the bounded non-board functional gate against its exact inputs."""
# SPDX-License-Identifier: BSD-3-Clause
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
SUFFIXES = {".v", ".vh", ".sv", ".mk", ".py", ".S", ".cc", ".cfg", ".sh",
            ".patch", ".f", ".tcl", ".in", ".xdc", ".ld"}


def input_hashes():
    paths = [ROOT / "Makefile"]
    for directory in ("rtl", "dbg", "test/dbg", "flow/fpga"):
        paths.extend(path for path in (ROOT / directory).rglob("*")
                     if path.is_file() and path.suffix in SUFFIXES)
    # Protection gates reuse the maintained memory-path benches, while lint
    # consumes the ASIC declaration-order checker. Fingerprint those inputs
    # too, without traversing unrelated third-party test checkouts.
    paths.extend(path for path in (ROOT / "test").iterdir()
                 if path.is_file() and path.suffix in SUFFIXES)
    paths.append(ROOT / "flow/asic/lint_decl.py")
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(set(paths))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="_build/dbg")
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    before = input_hashes()
    command = ["make", "--output-sync=target", f"-j{max(args.jobs, 1)}", "dbg-functional-gates"]
    started = time.monotonic()
    print("Running non-board functional gates; log:", out / "validation.log", flush=True)
    timed_out = False
    with (out / "validation.log").open("w") as log:
        try:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            exit_code = process.wait(timeout=900)
        except subprocess.TimeoutExpired:
            timed_out = True
            exit_code = 124
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    after = input_hashes()
    tools = {}
    for tool, option in (("verilator", "--version"), ("iverilog", "-V"),
                         ("openocd", "--version"),
                         (os.environ.get("DBG_GDB", "riscv64-unknown-elf-gdb"), "--version")):
        path = shutil.which(tool)
        if path:
            version = subprocess.run([path, option], text=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, timeout=10)
            tools[tool] = {"path": path, "version": version.stdout.splitlines()[0],
                           "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest()}
    record = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "command": command, "seconds": round(time.monotonic()-started, 2),
              "exit_code": exit_code, "timed_out": timed_out,
              "inputs_before": before, "inputs_after": after,
              "source_integrity": before == after, "tools": tools,
              "passed": exit_code == 0 and before == after}
    manifest = out / "openocd/manifest.txt"
    if manifest.exists():
        record["patched_openocd_manifest"] = manifest.read_text()
    (out / "validation.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"{'PASS' if record['passed'] else 'FAIL'} non-board functional gates; "
          f"{record['seconds']}s; record: {out / 'validation.json'}")
    raise SystemExit(0 if record["passed"] else 1)


if __name__ == "__main__":
    main()
