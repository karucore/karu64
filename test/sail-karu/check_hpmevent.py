#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Check configurable HPM selector WARL masks without changing default Sail behavior."""

import argparse
import json
import os
from pathlib import Path
import subprocess

from check import HERE, PIN, digest


# name, explicit mask (None tests the omitted-field default), H, Sscofpmf
CASES = [
    ("default", None, True, True),
    ("explicit_default", 0xFFFFFFFF, True, True),
    ("karu", 0x1F, True, True),
    ("karu_no_h", 0x1F, False, True),
    ("karu_no_sscofpmf", 0x1F, True, False),
    ("zero", 0, True, True),
    ("sparse", 0x80000011, True, True),
    ("default_no_h", None, False, True),
    ("default_no_sscofpmf", None, True, False),
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pristine", type=Path, required=True)
    parser.add_argument("--patched", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC_RISCV", "riscv64-unknown-elf-gcc"))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    base = json.loads(args.config.read_text())
    models = [("pristine", args.pristine.resolve()), ("patched", args.patched.resolve())]
    record = {
        "upstream_commit": PIN,
        "base_config_sha256": digest(args.config),
        "sources_sha256": {p.name: digest(p) for p in
            (HERE / "hpmevent.S", HERE / "interrupts.ld", HERE / "check_hpmevent.py", HERE / "check.py")},
        "patches_sha256": {p.name: digest(p) for p in sorted((HERE / "patches").glob("*.patch"))},
        "models": {}, "results": [], "config_checks": [],
    }
    for name, binary in models:
        version = subprocess.check_output([str(binary), "--version"], text=True).strip()
        if version != "0.14":
            raise SystemExit(f"{name}: expected model version 0.14, got {version!r}")
        build_info = subprocess.check_output([str(binary), "--build-info"], text=True)
        if name == "pristine" and PIN[:8] not in build_info:
            raise SystemExit(f"Pristine model does not identify pinned commit {PIN}")
        record["models"][name] = {"path": str(binary), "sha256": digest(binary),
                                   "version": version, "build_info": build_info}
    unexpected = []
    for name, mask, has_h, cofp in CASES:
        event_mask = 0xFFFFFFFF if mask is None else mask
        high_mask = ((0xFC if has_h else 0xF0) << 56) if cofp else 0
        elf = output / f"{name}.elf"
        compile_command = [
            args.cc, "-march=rv64i_zicsr", "-mabi=lp64", "-mcmodel=medany", "-nostdlib", "-static",
            "-Wl,--no-relax", f"-DEVENT_MASK={hex(event_mask)}", f"-DHIGH_MASK={hex(high_mask)}",
            "-T", str(HERE / "interrupts.ld"), "-o", str(elf), str(HERE / "hpmevent.S"),
        ]
        subprocess.run(compile_command, check=True)
        for model_name, binary in models:
            config = json.loads(json.dumps(base))
            config["extensions"]["H"].update(supported=has_h, geilen=0)
            config["extensions"]["Zihpm"]["supported"] = True
            config["extensions"]["Zihpm"].pop("event_selector_mask", None)
            config["extensions"]["Sscofpmf"]["supported"] = cofp
            config["base"]["writable_hpm_counters"] = {"len": 32, "value": "0xfffffff8"}
            config["base"]["scounteren_writable_bits"] = {"len": 32, "value": "0xffffffff"}
            config["base"]["hcounteren_writable_bits"] = {"len": 32, "value": "0xffffffff"}
            if not has_h:
                for extension in ("Sha", "Shcounterenw", "Shgatpa", "Shvsatpa", "Shvstvala", "Shvstvecd", "Shtvala"):
                    config["extensions"][extension]["supported"] = False
                bits = config["base"]["medeleg"]["delegatable_bits"]
                bits["value"] = hex(int(bits["value"], 0) & ~sum(1 << bit for bit in (10, 20, 21, 22, 23)))
            # The pristine schema has no mask parameter. Run the same ELF
            # with its genuine fixed-mask behavior; never count schema rejection
            # or an instruction-limit exit as the expected board-mask mismatch.
            if model_name == "patched" and mask is not None:
                config["extensions"]["Zihpm"]["event_selector_mask"] = {"len": 32, "value": hex(mask)}
            config_path = output / f"{name}-{model_name}.json"
            config_path.write_text(json.dumps(config, indent=2) + "\n")
            subprocess.run([str(binary), "--config", str(config_path), "--validate-config"], check=True)
            expected = int(model_name == "pristine" and event_mask != 0xFFFFFFFF)
            command = [str(binary), "--config", str(config_path), "--inst-limit", "10000", str(elf)]
            log = output / f"{name}-{model_name}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=30)
            marker = "SUCCESS" if expected == 0 else "FAILURE: 1 (0x00000001)"
            ok = result.returncode == expected and marker in log.read_text()
            record["results"].append({
                "case": name, "model": model_name, "event_mask": hex(event_mask),
                "expected_returncode": expected, "returncode": result.returncode, "matches_expectation": ok,
                "compile_command": compile_command, "command": command, "elf_sha256": digest(elf),
                "config_sha256": digest(config_path), "log_sha256": digest(log),
            })
            print(f"{name:22} {model_name:8} rc={result.returncode} expected={expected} {'OK' if ok else 'UNEXPECTED'}")
            if not ok:
                unexpected.append(f"{name}/{model_name}")

    # Compatibility normalization must not hide malformed explicit values or
    # supply unrelated required fields. These are schema tests, not firmware
    # negative controls, and are recorded separately from the paired probes.
    legacy_config = output / "default-patched.json"
    invalid_configs = []
    for name, value in (("wrong_width", {"len": 64, "value": "0x1f"}),
                        ("null_mask", None)):
        config = json.loads(legacy_config.read_text())
        config["extensions"]["Zihpm"]["event_selector_mask"] = value
        invalid_configs.append((name, config))
    config = json.loads(legacy_config.read_text())
    config["extensions"]["Zihpm"].pop("supported")
    invalid_configs.append(("missing_supported", config))
    for name, config in invalid_configs:
        config_path = output / f"invalid-{name}.json"
        config_path.write_text(json.dumps(config, indent=2) + "\n")
        command = [str(args.patched.resolve()), "--config", str(config_path), "--validate-config"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=30)
        log = output / f"invalid-{name}.log"
        log.write_text(result.stdout)
        ok = result.returncode != 0 and "Schema conformance check failed" in result.stdout
        record["config_checks"].append({"case": name, "command": command,
            "returncode": result.returncode, "matches_expectation": ok,
            "config_sha256": digest(config_path), "log_sha256": digest(log)})
        print(f"invalid_{name:14} patched  rc={result.returncode} {'OK' if ok else 'UNEXPECTED'}")
        if not ok:
            unexpected.append(f"config/{name}")

    # A legacy base config must also accept the field through the public CLI
    # override mechanism; Sail's merge rejects keys missing from the base.
    override = output / "karu-override.json"
    override.write_text(json.dumps({"extensions": {"Zihpm": {
        "event_selector_mask": {"len": 32, "value": "0x1f"}}}}, indent=2) + "\n")
    command = [str(args.patched.resolve()), "--config", str(legacy_config),
               "--config-override", str(override), "--inst-limit", "10000", str(output / "karu.elf")]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=30)
    log = output / "karu-override.log"
    log.write_text(result.stdout)
    ok = result.returncode == 0 and "SUCCESS" in result.stdout
    record["config_checks"].append({"case": "legacy_cli_override", "command": command,
        "returncode": result.returncode, "matches_expectation": ok,
        "config_sha256": digest(legacy_config), "override_sha256": digest(override),
        "elf_sha256": digest(output / "karu.elf"), "log_sha256": digest(log)})
    print(f"legacy_cli_override    patched  rc={result.returncode} {'OK' if ok else 'UNEXPECTED'}")
    if not ok:
        unexpected.append("config/legacy_cli_override")
    report = output / "results.json"
    report.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Evidence: {report}")
    if unexpected:
        raise SystemExit("Unexpected probe results: " + ", ".join(unexpected))


if __name__ == "__main__":
    main()
