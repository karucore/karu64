#!/usr/bin/env python3
"""Compare ordinary HTIF cycles with base debug versus all extensions idle."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import csv
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

from replay_isa import ROOT, file_record


def load_run(folder):
    manifest = json.loads((folder / "manifest.json").read_text())
    if not manifest.get("passed") or manifest["kind"] != "ordinary HTIF":
        raise ValueError(f"not a successful ordinary firmware run: {folder}")
    if not manifest.get("build_binding") or manifest["changed_inputs"]:
        raise ValueError(f"missing build binding or changed inputs: {folder}")
    cycles, logs = {}, {}
    for item in json.loads((folder / "results.json").read_text()):
        if item["result"] != "PASS":
            raise ValueError(f"non-passing subject: {item['elf']}")
        path = folder / item["log"]
        matches = re.findall(r"^\[HTIF\] exit 0 @ (?:cyc=|cycle\s+)(\d+)",
                             path.read_text(errors="replace"), re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"missing or ambiguous exit-cycle count: {path}")
        cycles[item["elf"]] = int(matches[0])
        logs[item["elf"]] = file_record(path)
    return manifest, cycles, logs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=Path("_build/dbg/ordinary-isa-base"))
    parser.add_argument("--full", type=Path, default=Path("_build/dbg/ordinary-isa"))
    parser.add_argument("--out", type=Path, default=Path("_build/dbg/idle-cycle-comparison"))
    parser.add_argument("--run-baseline", action="store_true",
                        help="build base model and replay the exact full-run ELFs before comparing")
    args = parser.parse_args()
    if args.run_baseline:
        full, _, _ = load_run(args.full)
        profile = {"-DKARU_RVA23S64", "-DHTIF_TB_CLINT", "-DHTIF_TB_EXTIRQ"}
        raw = [flag for flag in full["simulator_flags"].split()
               if flag != "-DKARU_DBG_FULL" and flag not in profile]
        simulator = ROOT / "_build/Vhtif_dbg_base/Vhtif_tb"
        args.out.mkdir(parents=True, exist_ok=True)
        with (args.out / "base-build.log").open("w") as stream:
            subprocess.run(["make", "dbg-isa-sim", "DBG_ISA_DIR=_build/Vhtif_dbg_base",
                            "DBG_ISA_FLAGS=" + " ".join(raw)], cwd=ROOT,
                           stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=900)
        binding = json.loads((simulator.parent / "build-inputs.json").read_text())
        command = [sys.executable, "test/dbg/replay_isa.py", "--ordinary", "--sim", str(simulator),
                   "--elf-root", full["elf_root"], "--out", str(args.base.resolve()),
                   "--jobs", "4", "--timeout", "120", "--max-cycles", str(full["max_cycles"]),
                   "--flags=" + binding["effective_flags"]]
        for item in full["elfs_before"]:
            command.extend(["--elf-file", str(ROOT / item["path"])])
        with (args.out / "base-run.log").open("w") as stream:
            subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                           check=True, timeout=900)
        shutil.copyfile(simulator.parent / "build-inputs.json", args.base / "build-inputs.json")
    base, bc, bl = load_run(args.base)
    full, fc, fl = load_run(args.full)
    base_elfs = {item["path"]: item["sha256"] for item in base["elfs_before"]}
    full_elfs = {item["path"]: item["sha256"] for item in full["elfs_before"]}
    if base_elfs != full_elfs or set(bc) != set(fc):
        raise ValueError("baseline/full ELF identities or subjects differ")
    def runtime(manifest):
        return {item["path"]: item["sha256"] for item in manifest["sources_before"]
                if item["path"] in manifest["runtime_source_paths"]}
    if runtime(base) != runtime(full):
        raise ValueError("baseline/full source identities differ")
    bf, ff = base["simulator_flags"].split(), full["simulator_flags"].split()
    if "-DKARU_DBG_FULL" in bf or ff.count("-DKARU_DBG_FULL") != 1 or bf != [x for x in ff if x != "-DKARU_DBG_FULL"]:
        raise ValueError("flags must differ only by KARU_DBG_FULL")
    rows = [{"subject": name, "base_cycles": bc[name], "full_cycles": fc[name],
             "delta": fc[name] - bc[name]} for name in sorted(bc)]
    args.out.mkdir(parents=True, exist_ok=True)
    table = args.out / "cycles.csv"
    with table.open("w") as stream:
        writer = csv.DictWriter(stream, fieldnames=["subject", "base_cycles", "full_cycles", "delta"])
        writer.writeheader()
        writer.writerows(rows)
    passed = all(row["delta"] == 0 for row in rows)
    record = {"passed": passed, "subjects": len(rows),
              "scope": "shipping-geometry HTIF; ordinary execution with base Debug versus KARU_DBG_FULL extensions idle",
              "base_manifest": file_record(args.base / "manifest.json"),
              "full_manifest": file_record(args.full / "manifest.json"),
              "base_logs": bl, "full_logs": fl, "cycles": rows,
              "table": file_record(table)}
    (args.out / "manifest.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"{'PASS' if passed else 'FAIL'} idle extension cycles: {len(rows)} subjects; {table}")
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
