#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Run the profile CSR contract on Sail and frozen, matching RTL models."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sail", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--simv", type=Path, action="append", required=True,
                        help="Existing RTL model matching the selected contract; repeat for variants")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--smcntrpmf", action="store_true",
                        help="Use the distinct optional fixed-counter contract (23, not 21 cases)")
    parser.add_argument("--cc", default=os.environ.get("CC_RISCV", "riscv64-unknown-elf-gcc"))
    parser.add_argument("--objcopy", default=os.environ.get("OBJCOPY", "riscv64-unknown-elf-objcopy"))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    config = args.config.resolve()
    configured_optional = json.loads(config.read_text())["extensions"]["Smcntrpmf"]["supported"]
    if configured_optional != args.smcntrpmf:
        parser.error("--smcntrpmf must match the reference configuration")
    cases = 23 if args.smcntrpmf else 21
    sail = args.sail.resolve()
    source = HERE / "csr-contract.S"
    linker = ROOT / "test/karu_priv_test.ld"
    elf = output / "csr-contract.elf"
    binary = output / "csr-contract.bin"
    hexfile = output / "csr-contract.hex"
    compile_command = [args.cc, "-march=rv64ih_zicsr", "-mabi=lp64", "-mcmodel=medany",
                       "-nostdlib", "-static", "-Wl,--no-relax", "-T", str(linker),
                       "-o", str(elf), str(source)]
    if args.smcntrpmf:
        compile_command.insert(1, "-DTEST_SMCNTRPMF")
    subprocess.run(compile_command, check=True)
    subprocess.run([args.objcopy, "-O", "binary", str(elf), str(binary)], check=True)
    raw = binary.read_bytes()
    raw += bytes((-len(raw)) % 8)
    hexfile.write_text("".join(f"{int.from_bytes(raw[i:i + 8], 'little'):016x}\n"
                               for i in range(0, len(raw), 8)))
    record = {"cases": cases, "smcntrpmf": args.smcntrpmf, "compile_command": compile_command,
              "inputs_sha256": {str(path): digest(path) for path in
                                (source, linker, Path(__file__), config)},
              "elf_sha256": digest(elf), "results": []}
    commands = [("sail", sail, [str(sail), "--config", str(config), str(elf)])]
    for index, sim in enumerate(args.simv):
        sim = sim.resolve()
        commands.append((f"rtl-{index}", sim, [str(sim), f"+hex={hexfile}",
                         "+tohost=1000", "+max_cycles=1000000"]))
    failures = []
    for name, model, command in commands:
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=120)
            returncode, text = result.returncode, result.stdout
        except subprocess.TimeoutExpired as error:
            returncode = 124
            text = (error.stdout or b"").decode(errors="replace") + "\nHOST_TIMEOUT\n"
        marker = (r"^SUCCESS\s*$" if name == "sail" else r"^\[HTIF\] exit 0 @")
        ok = (returncode == 0 and re.search(marker, text, re.MULTILINE) is not None and
              re.search(r"FAILURE|FAILED|HOST_TIMEOUT|%Error|Assertion failed|\[TIMEOUT\]", text) is None)
        log = output / f"{name}.log"
        log.write_text(text)
        record["results"].append({"model": name, "command": command,
                                  "model_sha256": digest(model), "returncode": returncode,
                                  "passed": ok, "log_sha256": digest(log)})
        print(f"PROFILE_CSR {name}: {'PASS' if ok else 'FAIL'} ({cases} cases), log={log}")
        if not ok:
            failures.append(name)
    (output / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    if failures:
        raise SystemExit("Profile CSR contract failed: " + ", ".join(failures))


if __name__ == "__main__":
    main()
