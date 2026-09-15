#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Paired pristine/patched Sail 0.14 interrupt-reference regression."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

PIN = "22fad389cb0ca92ef8f3cfff91fe258f14ee8de8"
HERE = Path(__file__).resolve().parent
# name, firmware probe, GEILEN, H, pristine verdict (0=pass, 1=probe failure)
CASES = [
    ("sgeie_zero_mie", 0, 0, True, 0),
    ("sgeie_zero_hie", 1, 0, True, 0),
    ("sgeie_one_mie", 0, 1, True, 0),
    ("sgeie_one_hie", 1, 1, True, 0),
    ("sgeie_max_mie", 0, 63, True, 0),
    ("sgeie_max_hie", 1, 63, True, 0),
    ("reset_geilen_zero", 2, 0, True, 1),
    ("reset_geilen_one", 2, 1, True, 1),
    ("reset_geilen_max", 2, 63, True, 1),
    ("reset_no_h", 2, 0, False, 0),
    ("enables_no_h", 3, 0, False, 0),
    ("reset_route_hs", 4, 0, True, 1),
    ("reset_route_vs", 5, 0, True, 1),
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pristine", type=Path, required=True)
    parser.add_argument("--patched", type=Path)
    parser.add_argument("--config", type=Path, required=True,
                        help="Base Sail 0.14 RV64 H configuration")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC_RISCV", "riscv64-unknown-elf-gcc"))
    parser.add_argument("--timer-elf", type=Path,
                        help="Optional existing portable H timer monitor (no rebuild)")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    base = json.loads(args.config.read_text())
    models = [("pristine", args.pristine.resolve())]
    if args.patched:
        models.append(("patched", args.patched.resolve()))
    record = {"upstream_commit": PIN, "config_sha256": digest(args.config),
              "sources_sha256": {p.name: digest(p) for p in
                  [HERE / "interrupts.S", HERE / "interrupts.ld", HERE / "check.py"]},
              "patches_sha256": {p.name: digest(p) for p in sorted((HERE / "patches").glob("*.patch"))},
              "models": {}, "results": []}
    for name, binary in models:
        version = subprocess.check_output([str(binary), "--version"], text=True).strip()
        if version != "0.14":
            raise SystemExit(f"{name}: expected model version 0.14, got {version!r}")
        build_info = subprocess.check_output([str(binary), "--build-info"], text=True)
        if name == "pristine" and PIN[:8] not in build_info:
            raise SystemExit(f"Pristine model build info does not identify pinned source {PIN}")
        record["models"][name] = {"path": str(binary), "sha256": digest(binary),
                                  "version": version, "build_info": build_info}
    unexpected = []
    for name, probe, geilen, has_h, pristine_rc in CASES:
        config = json.loads(json.dumps(base))
        config["extensions"]["H"].update(supported=has_h, geilen=geilen)
        if not has_h:
            for extension in ("Sha", "Shcounterenw", "Shgatpa", "Shvsatpa", "Shvstvala", "Shvstvecd", "Shtvala"):
                config["extensions"][extension]["supported"] = False
            delegation = config["base"]["medeleg"]["delegatable_bits"]
            delegation["value"] = hex(int(delegation["value"], 0) & ~sum(1 << bit for bit in (10, 20, 21, 22, 23)))
        # Only the routing fixtures enter S/VS. Their assembly programs PMP;
        # this reference-only setting does not alter processor configuration.
        config["memory"]["pmp"].update(count=16, usable_count=16)
        config_path = output / f"{name}.json"
        config_path.write_text(json.dumps(config, indent=2) + "\n")
        elf = output / f"{name}.elf"
        command = [args.cc, "-march=rv64ih_zicsr", "-mabi=lp64", "-mcmodel=medany",
                   "-nostdlib", "-static", "-Wl,--no-relax", f"-DPROBE={probe}",
                   f"-DGEILEN={geilen}", f"-DH_PRESENT={int(has_h)}", "-T",
                   str(HERE / "interrupts.ld"), "-o", str(elf), str(HERE / "interrupts.S")]
        subprocess.run(command, check=True)
        for model_name, binary in models:
            subprocess.run([str(binary), "--config", str(config_path), "--validate-config"], check=True)
            expected = pristine_rc if model_name == "pristine" else 0
            log = output / f"{name}-{model_name}.log"
            run = [str(binary), "--config", str(config_path), "--inst-limit", "10000", str(elf)]
            with log.open("w") as stream:
                result = subprocess.run(run, stdout=stream, stderr=subprocess.STDOUT, timeout=30)
            # A configuration error or instruction-limit exit is not a
            # reproduced architectural failure, even if its exit code is 1.
            verdict = "SUCCESS" if expected == 0 else "FAILURE: 1 (0x00000001)"
            ok = result.returncode == expected and verdict in log.read_text()
            record["results"].append({"case": name, "model": model_name,
                                      "returncode": result.returncode, "expected": expected,
                                      "matches_expectation": ok, "command": run,
                                      "elf_sha256": digest(elf), "log_sha256": digest(log)})
            print(f"{name:22} {model_name:8} rc={result.returncode} expected={expected} {'OK' if ok else 'UNEXPECTED'}")
            if not ok:
                unexpected.append(f"{name}/{model_name}")
    if args.timer_elf:
        config = json.loads(json.dumps(base))
        config["memory"]["pmp"].update(count=16, usable_count=16)
        config_path = output / "timer-monitor.json"
        config_path.write_text(json.dumps(config, indent=2) + "\n")
        for name, binary in models:
            log = output / f"timer-monitor-{name}.log"
            run = [str(binary), "--config", str(config_path), "--inst-limit", "1000000", str(args.timer_elf.resolve())]
            with log.open("w") as stream:
                result = subprocess.run(run, stdout=stream, stderr=subprocess.STDOUT, timeout=60)
            # The full monitor is diagnostic: record its next failure rather
            # than attributing every unrelated reference issue to these fixes.
            record["results"].append({"case": "timer-monitor", "model": name,
                                      "returncode": result.returncode, "command": run,
                                      "elf_sha256": digest(args.timer_elf), "log_sha256": digest(log)})
            print(f"timer-monitor          {name:8} rc={result.returncode} (diagnostic)")
    report = output / "results.json"
    report.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Evidence: {report}")
    if unexpected:
        raise SystemExit("Unexpected probe results: " + ", ".join(unexpected))


if __name__ == "__main__":
    main()
