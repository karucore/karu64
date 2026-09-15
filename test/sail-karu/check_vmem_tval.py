#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Paired pinned Sail execution probes for virtual access-fault addresses."""

import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess

from check import HERE, PIN, digest

OPS = ("ld", "sd", "lr_d", "amo_d", "sc_d", "hsv_d", "hlv_d", "hlvx_wu", "lr_w", "amo_w")
# The helper is not used by AMO, unsuccessful SC, HLV or HLVX. Their
# independent original-VA reporting paths are deliberate unchanged controls.
HELPER_OPS = {0, 1, 2, 5, 8}
HIGH = 0x140000010
NEGATIVE = 0xFFFFFFC040000010  # Canonical Sv39, not a malformed address.
LOW = 0x40000010


def cases():
    """name, operation, VA, translated, split, delegate, PA bits, split order."""
    for op, operation in enumerate(OPS):
        for delegate in (0, 1):
            yield (f"high_{operation}_{'s' if delegate else 'm'}", op, HIGH, 1, 0, delegate, 32, False)
    for width in (32, 56):
        for op in (0, 1, 2, 5):
            yield (f"negative_{OPS[op]}_pa{width}", op, NEGATIVE, 1, 0, 1, width, False)
    for op in (0, 1):
        yield (f"negative_{OPS[op]}_pa64", op, NEGATIVE, 1, 0, 1, 64, False)
        yield (f"high_{OPS[op]}_pa56", op, HIGH, 1, 0, 1, 56, False)
    for op in (0, 1, 2, 3):
        for delegate in (0, 1):
            yield (f"low_{OPS[op]}_{'s' if delegate else 'm'}", op, LOW, 1, 0, delegate, 32, False)
    for op in (0, 1, 2, 3, 4):
        yield (f"bare_{OPS[op]}", op, LOW, 0, 0, 1, 32, False)
    for va_name, va in (("high", HIGH), ("negative", NEGATIVE), ("low", LOW)):
        for op in (0, 1):
            for decreasing in (False, True):
                for delegate in ((0, 1) if va_name != "low" else (1,)):
                    yield (f"split_{va_name}_{OPS[op]}_{'reverse' if decreasing else 'forward'}_"
                           f"{'s' if delegate else 'm'}", op, (va & ~4095) + 4092,
                           1, 1, delegate, 32, decreasing)
    for va_name, va in (("high", HIGH), ("negative", NEGATIVE), ("low", LOW)):
        for op in (0, 1):
            for decreasing in (False, True):
                for delegate in (0, 1):
                    yield (f"pmp_offset_{va_name}_{OPS[op]}_{'reverse' if decreasing else 'forward'}_"
                           f"{'s' if delegate else 'm'}", op, (va & ~4095) + 0x104,
                           1, 2, delegate, 32, decreasing)


def model_record(binary):
    version = subprocess.check_output([str(binary), "--version"], text=True).strip()
    if version != "0.14":
        raise SystemExit(f"Expected actual Sail 0.14, got {version!r}: {binary}")
    build_info = subprocess.check_output([str(binary), "--build-info"], text=True)
    pin_file = binary.parents[2] / "upstream.commit"
    if pin_file.is_file():
        if pin_file.read_text().strip() != PIN:
            raise SystemExit(f"Unexpected isolated source pin: {pin_file}")
    elif PIN[:8] not in build_info:
        raise SystemExit(f"Model provenance does not identify pinned source {PIN}: {binary}")
    result = {"path": str(binary), "sha256": digest(binary), "version": version,
              "build_info": build_info}
    for name in ("source.sha256", "patches.sha256", "upstream.commit"):
        path = binary.parents[2] / name
        if path.is_file():
            result[name] = {"sha256": digest(path), "path": str(path)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True,
                        help="Pinned model before the virtual-address correction (original or three-patch)")
    parser.add_argument("--after", type=Path,
                        help="Isolated corrected model; omit for the negative-control stage")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC_RISCV", "riscv64-unknown-elf-gcc"))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    models = [("before", args.before.resolve())]
    if args.after:
        models.append(("after", args.after.resolve()))
    base = json.loads(args.config.read_text())
    # Keep this fixture independent of the separate event-selector patch.
    base["extensions"]["Zihpm"].pop("event_selector_mask", None)
    if base["base"]["xlen"] != 64 or not base["extensions"]["H"]["supported"]:
        raise SystemExit("The probe requires a real RV64 H/Sv39 base configuration")
    for region in base["memory"]["regions"]:
        start = int(region["base"]["value"], 0)
        end = start + int(region["size"]["value"], 0)
        if start < 0x40002000 and end > 0x40000000:
            raise SystemExit("Fixture requires an unmapped physical PMA hole at 0x40000000..0x40001fff")
    base["memory"]["pmp"].update(count=16, usable_count=16, grain=0, na4_supported=True)
    base["memory"]["misaligned"]["exceptions"]["load_store"] = {"None": None}
    base["memory"]["misaligned"]["byte_by_byte"] = False
    # Faults must report informative addresses, not a permitted all-zero policy.
    for field in ("load_access_fault", "samo_access_fault"):
        if not base["base"]["xtval_nonzero"].get(field):
            raise SystemExit(f"Fixture requires xtval_nonzero.{field}")
    record = {"upstream_commit": PIN, "base_config_sha256": digest(args.config),
              "sources_sha256": {p.name: digest(p) for p in
                  (HERE / "vmem_tval.S", HERE / "interrupts.ld", HERE / "check_vmem_tval.py")},
              "models": {name: model_record(binary) for name, binary in models}, "results": []}
    unexpected = []
    for name, op, va, translated, split, delegate, pa_bits, decreasing in cases():
        config = copy.deepcopy(base)
        config["memory"]["physaddr_bits"] = pa_bits
        config["memory"]["misaligned"]["order_decreasing"] = decreasing
        path = output / f"{name}.json"
        path.write_text(json.dumps(config, indent=2) + "\n")
        elf = output / f"{name}.elf"
        compile_command = [args.cc, "-march=rv64imah_zicsr", "-mabi=lp64", "-mcmodel=medany",
                           "-nostdlib", "-static", "-Wl,--no-relax", f"-DOP={op}",
                           f"-DTEST_VA={va:#x}", f"-DTRANSLATED={translated}", f"-DSPLIT={split}",
                           f"-DDELEGATE={delegate}", "-T", str(HERE / "interrupts.ld"),
                           "-o", str(elf), str(HERE / "vmem_tval.S")]
        subprocess.run(compile_command, check=True)
        expected_va = ((va & ~4095) + 4096) if split == 1 else va + (4 if split == 2 else 0)
        before_fails = op in HELPER_OPS and expected_va >> pa_bits != 0
        for model, binary in models:
            validate = [str(binary), "--config", str(path), "--validate-config"]
            subprocess.run(validate, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            expected = int(before_fails) if model == "before" else 0
            log = output / f"{name}-{model}.log"
            command = [str(binary), "--config", str(path), "--trace-exception", "--trace-csr",
                       "--inst-limit", "10000", str(elf)]
            with log.open("w") as stream:
                run = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=30)
            marker = "FAILURE: 1 (0x00000001)" if expected else "SUCCESS"
            text = log.read_text()
            csr = "stval" if delegate else "mtval"
            observed = re.findall(rf"CSR {csr} \(0x[0-9A-Fa-f]+\) -> (0x[0-9A-Fa-f]+)", text)
            expected_observed = expected_va & ((1 << pa_bits) - 1) if expected else expected_va
            ok = (run.returncode == expected and marker in text and len(observed) == 1
                  and int(observed[0], 0) == expected_observed)
            record["results"].append({"case": name, "model": model, "expected": expected,
                                      "returncode": run.returncode, "matches_expectation": ok,
                                      "fault_virtual_address": hex(expected_va), "pa_bits": pa_bits,
                                      "observed_tval": observed, "expected_observed_tval": hex(expected_observed),
                                      "config_sha256": digest(path), "elf_sha256": digest(elf),
                                      "log_sha256": digest(log), "compile_command": compile_command,
                                      "command": command})
            print(f"{name:38} {model:6} rc={run.returncode} expected={expected} {'OK' if ok else 'UNEXPECTED'}")
            if not ok:
                unexpected.append(f"{name}/{model}")
    result = output / "results.json"
    result.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Evidence: {result}")
    if unexpected:
        raise SystemExit("Unexpected probe results: " + ", ".join(unexpected))


if __name__ == "__main__":
    main()
