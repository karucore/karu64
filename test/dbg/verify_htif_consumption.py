#!/usr/bin/env python3
"""Attach a complete fresh build to existing identical-binary ISA verdicts.

A forced rebuild must hash every frontend input before/after compilation and
produce the exact tested executable. Existing logs are independently checked
again, with immutable golden ELFs and conversion tools. The original replay
manifest is preserved; no source-change waiver or timestamp inference is used.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import json
from pathlib import Path
import shlex
import shutil
import sys

from replay_isa import ROOT, classify, digest, file_record, verify_records
from isa_inputs import frontend_sources


def capture(folder):
    run = json.loads((folder / "manifest.json").read_text())
    simulator = ROOT / run["simulator"]["path"]
    target = folder / "complete-build-binding"
    target.mkdir(exist_ok=True)
    for name in ("Vhtif_tb__verFiles.dat", "build-inputs.json"):
        shutil.copyfile(simulator.parent / name, target / name)


def verify(folder):
    manifest_path = folder / "manifest.json"
    run = json.loads(manifest_path.read_text())
    captured = folder / "complete-build-binding"
    frontend, build_path = captured / "Vhtif_tb__verFiles.dat", captured / "build-inputs.json"
    build = json.loads(build_path.read_text())
    if not build.get("passed") or "-B" not in build["command"] or build.get("unhashed_frontend_inputs"):
        raise ValueError("a successful forced rebuild with complete input coverage is required")
    if build["inputs_before"] != build["inputs_after"] or verify_records(build["inputs_before"]):
        raise ValueError("complete build inputs changed")
    if build["effective_flags"] != run["simulator_flags"]:
        raise ValueError("tested/rebuilt configuration flags differ")
    if build["simulator"]["sha256"] != run["simulator"]["sha256"] or verify_records([run["simulator"]]):
        raise ValueError("rebuilt simulator differs from the tested executable")
    if digest(frontend) != build["frontend_manifest"]["sha256"]:
        raise ValueError("captured frontend manifest changed")
    inputs = {item["path"]: item for item in build["inputs_before"]}
    actual = frontend_sources(frontend)
    if not actual or actual != set(build["consumed_source_paths"]) or not actual.issubset(inputs):
        raise ValueError("frontend coverage is incomplete")
    command = next((shlex.split(json.loads(line[2:])) for line in frontend.read_text().splitlines()
                    if line.startswith('C "')), None)
    if command is None or any(flag not in command for flag in run["simulator_flags"].split()):
        raise ValueError("frontend command/configuration mismatch")
    # The C++ harness is a compiler input too; Verilator records it in C but
    # not in its S (HDL frontend) list. Check every declared source argument.
    for word in command:
        path = Path(word)
        if path.suffix in {".v", ".sv", ".vh", ".svh", ".cpp", ".c", ".h"} and (ROOT / path).is_file():
            path = (ROOT / path).resolve()
            name = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
            if name not in inputs:
                raise ValueError("declared compiler input was not prehashed: " + name)
            actual.add(name)
    immutable = run["elfs_before"] + [run["simulator"]] + list(run["tools"].values())
    if run["elfs_before"] != run["elfs_after"] or verify_records(immutable):
        raise ValueError("ELF, simulator or conversion tool changed")
    results = json.loads((folder / "results.json").read_text())
    selected = {str((ROOT / item["path"]).relative_to(Path(run["elf_root"]))) for item in run["elfs_before"]}
    if len(results) != len(selected) or {item["elf"] for item in results} != selected:
        raise ValueError("result list differs from the exact selected ELF set")
    logs = []
    for item in results:
        path = folder / item["log"]
        if item["result"] != "PASS" or classify(path.read_text(errors="replace"), item["returncode"],
                                              ordinary=run["kind"] == "ordinary HTIF") != "PASS":
            raise ValueError("independent log recheck failed: " + item["elf"])
        logs.append({"elf": item["elf"], **file_record(path)})
    if file_record(folder / "results.tsv") != run["results"]:
        raise ValueError("replay result table changed")
    return {"passed": True, "tests": len(results),
            "method": "forced complete-source rebuild, identical executable SHA-256, independent log recheck",
            "original_manifest": file_record(manifest_path), "fresh_build_binding": file_record(build_path),
            "frontend_manifest": file_record(frontend), "simulator": run["simulator"],
            "tested_binary_sha256": run["simulator"]["sha256"],
            "rebuilt_binary_sha256": build["simulator"]["sha256"],
            "consumed_sources": [inputs[name] for name in sorted(actual)], "results": run["results"], "logs": logs,
            "elf_hashes_before_after_equal": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, default=ROOT / "_build/dbg/isa-replay")
    parser.add_argument("--capture", action="store_true", help="capture the fresh forced build record first")
    args = parser.parse_args()
    if args.capture:
        capture(args.run.resolve())
    record = verify(args.run.resolve())
    path = args.run / "consumption-verification.json"
    path.write_text(json.dumps(record, indent=2) + "\n")
    print(f"PASS identical rebuilt HTIF: {record['tests']} ELFs; {len(record['consumed_sources'])} SHA-bound inputs; {path}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
