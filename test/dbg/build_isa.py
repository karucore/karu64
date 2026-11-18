#!/usr/bin/env python3
"""Bind a shipping-geometry debug-idle HTIF simulator to its build inputs."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys

from replay_isa import ROOT, file_record, runtime_source, source_records, verify_records
from isa_inputs import frontend_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, required=True)
    parser.add_argument("--flags", required=True, help="VFLAGS before rva23-sim adds profile/interrupt switches")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--force", action="store_true", help="force fresh frontend, compile and link, allowing ccache")
    args = parser.parse_args()
    folder = args.dir.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    effective = args.flags + " -DKARU_RVA23S64 -DHTIF_TB_CLINT -DHTIF_TB_EXTIRQ"
    command = ["make", f"-j{args.jobs}", "rva23-sim", f"VERI_RVA23_DIR={args.dir}",
               f"DBG_ISA_DIR={args.dir}", "DBG_ISA_FLAGS=" + args.flags, "VFLAGS=" + args.flags]
    if args.force:
        command.insert(1, "-B")
    # Distinct ISA invocations can share this model without racing a rebuild.
    with (folder / "build-inputs.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        inputs = [item for item in source_records() if runtime_source(item)]
        record = {"schema": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
                  "command": command, "effective_flags": effective, "inputs_before": inputs}
        result = subprocess.run(command, cwd=ROOT, env=os.environ)
        record["returncode"] = result.returncode
        record["inputs_after"] = [item for item in source_records() if runtime_source(item)]
        record["changed_inputs"] = verify_records(inputs)
        if {item["path"] for item in inputs} != {item["path"] for item in record["inputs_after"]}:
            record["changed_inputs"].append("runtime input set changed during build")
        simulator = folder / "Vhtif_tb"
        record["simulator"] = file_record(simulator) if simulator.is_file() else None
        frontend = folder / "Vhtif_tb__verFiles.dat"
        actual = frontend_sources(frontend) if frontend.is_file() else set()
        record["frontend_manifest"] = file_record(frontend) if frontend.is_file() else None
        record["consumed_source_paths"] = sorted(actual)
        record["unhashed_frontend_inputs"] = sorted(actual - {item["path"] for item in inputs})
        record["passed"] = result.returncode == 0 and not record["changed_inputs"] and record["simulator"] is not None and bool(actual) and not record["unhashed_frontend_inputs"]
        record["finished_utc"] = datetime.now(timezone.utc).isoformat()
        path = folder / "build-inputs.json"
        path.write_text(json.dumps(record, indent=2) + "\n")
        if not record["passed"]:
            sys.exit(f"Simulator build/input binding failed: {path}")
        print(f"Simulator source binding: {path} ({len(inputs)} unchanged inputs)", flush=True)


if __name__ == "__main__":
    main()
