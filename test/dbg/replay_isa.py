#!/usr/bin/env python3
"""Replay existing self-checking ELFs with bounded jobs and immutable-input evidence.

ACT4 ELFs already contain Sail-computed expected results. This runner never
generates references, patches dependencies, or writes to the ELF/source tree.
It preserves relative test names, so equal basenames cannot overwrite logs.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from isa_inputs import runtime_paths

ROOT = Path(__file__).resolve().parents[2]
SHIPPING = "karu64-rva23s64-smcntrpmf"


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def file_record(path):
    path = Path(path).resolve()
    try:
        name = str(path.relative_to(ROOT))
    except ValueError:
        name = str(path)
    return {"path": name, "sha256": digest(path), "bytes": path.stat().st_size}


def select_elfs(root, selectors, explicit=()):
    root = Path(root).resolve()
    files = sorted({Path(p).resolve() for p in explicit} if explicit else root.rglob("*.elf"))
    selected = []
    for path in files:
        relative = path.relative_to(root)
        if not selectors or any(
            str(relative).startswith(token.rstrip("/") + "/") or
            ("/" not in token and relative.parent.name.startswith(token))
            for token in selectors
        ):
            selected.append(path)
    if not selected:
        raise ValueError("selection contains no ELFs")
    if any(not path.is_file() for path in selected):
        raise ValueError("selected ELF does not exist")
    return selected


def classify(output, returncode, timed_out=False, ordinary=False):
    if timed_out:
        return "TIMEOUT"
    if re.search(r"RVCP-SUMMARY:\s*TEST FAILED|\[FAIL\]|FAILURES:|\*\*TRAP\*\*|\*\*TIMEOUT\*\*", output):
        return "FAIL"
    exits = re.findall(r"^\[HTIF\] exit (\d+) @", output, re.MULTILINE)
    if any(value != "0" for value in exits):
        return "FAIL"
    if returncode:
        return "SIM_ERROR"
    if not exits:
        return "NO_EXIT"
    if not ordinary and "RVCP-SUMMARY: TEST PASSED" not in output:
        return "NO_MARKER"
    return "PASS"


def git_read(*args):
    result = subprocess.run(["git", "--no-optional-locks", *args], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            timeout=30, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    return result.stdout.strip() if result.returncode == 0 else None


def source_records():
    files = {ROOT / "Makefile", ROOT / "flow/sim_tb.cpp", Path(__file__).resolve(),
             ROOT / "test/dbg/build_isa.py"}
    for folder in ("rtl", "dbg", "test/fw", "test/act4-karu", "test/sail-karu"):
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and path.suffix in {".v", ".sv", ".vh", ".svh", ".mk", ".py",
                                                  ".S", ".c", ".h", ".ld", ".json", ".yaml", ".patch", ".sh"}:
                files.add(path)
    files.add(ROOT / "test/karu_h_test.S")
    files.add(ROOT / "test/karu_h_test.ld")
    files.update(ROOT / name for name in runtime_paths())
    return [file_record(path) for path in sorted(files) if path.is_file()]


def runtime_source(record):
    """Separate simulator/firmware inputs from other recorded flow provenance.

    Debug transport test recipes and reference-generation helpers cannot alter
    execution of an already compiled, hashed simulator and golden ELF. Their
    hashes remain in the record; changes to consumed RTL/build/runner inputs
    are fatal, as are simulator, ELF or conversion-tool changes.
    """
    return record["path"] in runtime_paths()


def reference_provenance(elf_root, out):
    work = elf_root.parent
    names = ("extensions.txt", "rvtest_config.h", "rvtest_config.svh", "rvmodel_macros.svh",
             ".act_build_cache.json", ".validated")
    existing = [work / name for name in names if (work / name).is_file()]
    config = ROOT / "_build/act-config" / work.name
    existing += [p for p in config.rglob("*") if p.is_file()] if config.is_dir() else []
    diff = git_read("-C", "test/riscv-arch-test", "diff", "--binary", "HEAD")
    (out / "act4-dependency.diff").write_text((diff or "") + "\n")
    return {
        "mode": "replay of existing Sail-baked golden ELFs; no reference generation",
        "configuration": work.name,
        "preserved_configuration_files": [file_record(p) for p in sorted(existing)],
        "act4_head": git_read("-C", "test/riscv-arch-test", "rev-parse", "HEAD"),
        "act4_tracked_status": git_read("-C", "test/riscv-arch-test", "status", "--short", "--untracked-files=no"),
        "act4_dependency_diff": file_record(out / "act4-dependency.diff"),
        "reference_generation": "not rerun; this record identifies the preserved inputs, not a new Sail verdict",
    }


def verify_records(records):
    changed = []
    for item in records:
        path = Path(item["path"])
        if not path.is_absolute():
            path = ROOT / path
        if not path.is_file() or digest(path) != item["sha256"]:
            changed.append(item["path"])
    return changed


def check_build_binding(simulator, flags):
    path = simulator.parent / "build-inputs.json"
    if not path.is_file():
        return None
    record = json.loads(path.read_text())
    if not record.get("passed") or record["effective_flags"] != flags:
        raise ValueError("simulator build record failed or flags differ")
    if record["simulator"]["sha256"] != digest(simulator) or verify_records(record["inputs_before"]):
        raise ValueError("simulator or its bound build inputs changed; rebuild before replay")
    return file_record(path)


def run_one(elf, elf_root, out, simulator, objcopy, nm, timeout, cycles, ordinary, keep_images):
    relative = elf.relative_to(elf_root)
    stem = out / "tests" / relative.with_suffix("")
    stem.parent.mkdir(parents=True, exist_ok=True)
    binary, image, log = (Path(str(stem) + suffix) for suffix in (".bin", ".hex", ".log"))
    started = time.monotonic()
    result = {"elf": str(relative), "result": "PREP_ERROR"}
    try:
        subprocess.run([objcopy, "-O", "binary", str(elf), str(binary)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        blob = binary.read_bytes()
        if len(blob) > 4 * 1024 * 1024:
            raise ValueError("binary exceeds the simulator's 4 MiB RAM")
        padded = blob + bytes((-len(blob)) & 7)
        with image.open("w") as stream:
            stream.writelines(f"{int.from_bytes(padded[n:n+8], 'little'):016x}\n"
                             for n in range(0, len(padded), 8))
        symbols = subprocess.run([nm, "--defined-only", str(elf)], check=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 timeout=timeout).stdout
        address = next((int(line.split()[0], 16) for line in symbols.splitlines()
                        if line.split()[-1:] == ["tohost"]), None)
        if address is None or not 0x80000000 <= address < 0x80400000:
            raise ValueError("missing or out-of-RAM tohost symbol")
        command = [str(simulator), f"+hex={image}", f"+tohost={address-0x80000000:x}",
                   f"+max_cycles={cycles}"]
        timed_out = False
        with log.open("w") as stream:
            try:
                process = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                         timeout=timeout)
                returncode = process.returncode
            except subprocess.TimeoutExpired:
                timed_out, returncode = True, 124
        result.update(result=classify(log.read_text(errors="replace"), returncode, timed_out, ordinary),
                      returncode=returncode, command=command)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        log.write_text(f"Preparation/execution error: {error}\n")
        result["error"] = str(error)
    result["seconds"] = round(time.monotonic() - started, 4)
    result["log"] = str(log.relative_to(out))
    if result["result"] == "PASS" and not keep_images:
        binary.unlink(missing_ok=True)
        image.unlink(missing_ok=True)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf-root", type=Path, default=ROOT / "test/riscv-arch-test/work" / SHIPPING / "elfs")
    parser.add_argument("--elf-file", type=Path, action="append", default=[])
    parser.add_argument("--ext", default="", help="comma-separated slice-directory prefixes, e.g. rv64i/I,Zvbb,priv/InterruptsSm")
    parser.add_argument("--sim", type=Path, default=ROOT / "_build/Vhtif_dbg_full/Vhtif_tb")
    parser.add_argument("--out", type=Path, default=ROOT / "_build/dbg/isa-replay")
    parser.add_argument("--flags", default="", help="exact simulator build flags, recorded with the result")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--max-cycles", type=int, default=20000000)
    parser.add_argument("--xchain", default="riscv64-unknown-elf-")
    parser.add_argument("--ordinary", action="store_true", help="ordinary HTIF firmware, rather than RVCP-marked ACT4")
    parser.add_argument("--dry-run", action="store_true", help="write selection and hashes without executing ELFs")
    parser.add_argument("--keep-images", action="store_true")
    args = parser.parse_args(argv)
    if min(args.jobs, args.timeout, args.max_cycles) < 1:
        parser.error("jobs, timeout and max-cycles must be positive")
    elf_root, simulator, out = args.elf_root.resolve(), args.sim.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    elfs = select_elfs(elf_root, [x.strip() for x in args.ext.split(",") if x.strip()], args.elf_file)
    if not simulator.is_file():
        raise ValueError(f"simulator does not exist: {simulator}")
    build_binding = check_build_binding(simulator, args.flags)
    tools = {name: shutil.which(args.xchain + name) for name in ("objcopy", "nm")}
    if not args.dry_run and not all(tools.values()):
        raise ValueError("RISC-V objcopy/nm not found; set --xchain or PATH")
    manifest = {
        "schema": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
        "dry_run": args.dry_run, "kind": "ordinary HTIF" if args.ordinary else "ACT4 golden replay",
        "git_head": git_read("rev-parse", "HEAD"), "simulator": file_record(simulator),
        "simulator_flags": args.flags, "jobs": args.jobs, "per_elf_timeout_seconds": args.timeout,
        "build_binding": build_binding,
        "max_cycles": args.max_cycles, "tools": {name: file_record(path) for name, path in tools.items() if path},
        "selection": args.ext, "elf_root": str(elf_root),
        "elfs_before": [file_record(path) for path in elfs], "sources_before": source_records(),
        "reference": None if args.ordinary else reference_provenance(elf_root, out),
    }
    manifest_path = out / "manifest.json"
    runtime = [record for record in manifest["sources_before"] if runtime_source(record)]
    manifest["runtime_source_paths"] = [record["path"] for record in runtime]
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Selected {len(elfs)} ELFs; manifest: {manifest_path}", flush=True)
    if args.dry_run:
        return 0
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, elf, elf_root, out, simulator, tools["objcopy"], tools["nm"],
                               args.timeout, args.max_cycles, args.ordinary, args.keep_images) for elf in elfs]
        for index, future in enumerate(as_completed(futures), 1):
            item = future.result()
            results.append(item)
            if item["result"] != "PASS" or index % 100 == 0 or index == len(elfs):
                print(f"[{index}/{len(elfs)}] {item['result']} {item['elf']}", flush=True)
    results.sort(key=lambda item: item["elf"])
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    (out / "results.tsv").write_text("".join(f"{r['elf']}\t{r['result']}\t{r['seconds']}\t{r['log']}\n" for r in results))
    manifest["elfs_after"] = [file_record(path) for path in elfs]
    manifest["changed_provenance"] = verify_records(manifest["sources_before"])
    manifest["changed_inputs"] = verify_records(runtime + manifest["elfs_before"] +
                                                [manifest["simulator"]] + list(manifest["tools"].values()) +
                                                ([build_binding] if build_binding else []))
    manifest["results"] = file_record(out / "results.tsv")
    manifest["counts"] = dict(Counter(item["result"] for item in results))
    manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
    manifest["passed"] = not manifest["changed_inputs"] and manifest["counts"] == {"PASS": len(elfs)}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"counts": manifest["counts"], "changed_inputs": manifest["changed_inputs"],
                      "passed": manifest["passed"]}), flush=True)
    return 0 if manifest["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(str(error))
