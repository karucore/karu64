#!/usr/bin/env python3
"""Reintroduce two responder defects in isolated copies; require rejection.

The maintained responder, existing bus master test and positive model are never
modified. Copies, commands, hashes and logs remain under a unique _build folder.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "flow/fpga/linux_tb.sv"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    source = SOURCE.read_text()
    original_hash = digest(SOURCE)
    output = Path(tempfile.mkdtemp(prefix="linux-axi-negative-", dir=ROOT / "_build"))
    cases = (
        ("early_b", "if (dmem_wlast) begin", "if (dmem_wlast || wr_left != 0) begin",
         "B response before final W beat"),
        ("shifted_lanes", "write_byte({wr_addr[31:3],3'b0} + b[31:0],",
         "write_byte(wr_addr + b[31:0],", "read 80001021 got"),
    )
    results = []
    for name, old, new, expected in cases:
        if source.count(old) != 1:
            raise RuntimeError(f"{name}: mutation anchor must match exactly once")
        directory = output / name
        directory.mkdir()
        changed = directory / "linux_tb.sv"
        changed.write_text(source.replace(old, new))
        model_dir = directory / "model"
        binary = model_dir / "Vtb_axi_mem_burst"
        command = ["make", "-s", f"LINUX_AXI_DIR={model_dir}",
                   f"LINUX_AXI_TB={changed}", str(binary)]
        with (directory / "build.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                           timeout=300, check=True)
        with (directory / "run.log").open("w") as log:
            run = subprocess.run([str(binary)], cwd=ROOT, stdout=log,
                                 stderr=subprocess.STDOUT, timeout=30)
        text = (directory / "run.log").read_text()
        if run.returncode == 0 or expected not in text or "[AXI-LINUX] ALL PASS" in text:
            raise RuntimeError(f"{name}: missing expected negative verdict; see {directory}")
        results.append({"case": name, "command": command, "returncode": run.returncode,
                        "expected": expected, "source_sha256": digest(changed),
                        "binary_sha256": digest(binary), "log": str(directory / "run.log")})
        print(f"{name}: expected rejection PASS", flush=True)
    if digest(SOURCE) != original_hash:
        raise RuntimeError("maintained responder changed during controls")
    (output / "results.json").write_text(json.dumps(
        {"maintained_source_sha256": original_hash, "cases": results}, indent=2) + "\n")
    print(f"2/2 negative controls PASS; evidence: {output}")


if __name__ == "__main__":
    main()
