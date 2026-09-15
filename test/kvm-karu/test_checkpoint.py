#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Compare uninterrupted and restored simulator state using a short boot prefix."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile


def fingerprint(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--image", type=Path, default=root / "_build/kvm-karu-debugfix/flat.img")
    parser.add_argument("--dtb", type=Path, default=root / "_build/kvm-karu-debugfix/board.dtb")
    args = parser.parse_args()
    command = [str(args.model.resolve(strict=True)),
               f"+img={args.image.resolve(strict=True)}", f"+dtb={args.dtb.resolve(strict=True)}",
               "+max_cycles=100000", "+heartbeat=100"]
    with tempfile.TemporaryDirectory(prefix="checkpoint-", dir=root / "_build") as directory:
        output = Path(directory)

        def run(*options, expect=0):
            result = subprocess.run(command + list(options), capture_output=True, text=True, timeout=60)
            if result.returncode != expect:
                raise AssertionError(result.stdout + result.stderr)
            return result.stdout + result.stderr

        baseline = output / "baseline.save"
        midway = output / "midway.save"
        replay = output / "replay.save"
        run("+save_at=1200", f"+save_file={baseline}", "+stop_at=1200")
        run("+save_at=1000", f"+save_file={midway}", "+stop_at=1000")
        run(f"+restore={midway}", "+save_at=1200", f"+save_file={replay}", "+stop_at=1200")
        if fingerprint(baseline) != fingerprint(replay):
            raise AssertionError("restored simulator state differs from uninterrupted execution")
        run(f"+restore={midway}", "+restore_at=999", "+stop_at=1001", expect=2)
        run(f"+restore={midway}", "+stop_at=1001", "+require_exit", expect=2)
        waveform = output / "window.vcd"
        run(f"+restore={midway}", f"+trace_file={waveform}",
            "+trace_from=1000", "+trace_to=1008", "+stop_at=1009")
        timestamps = []
        with waveform.open() as source:
            for line in source:
                if line.startswith("#"):
                    timestamps.append(int(line[1:]))
        if not timestamps or min(timestamps) != 1999 or max(timestamps) > 2016:
            raise AssertionError(f"waveform escaped the restored window: {timestamps}")
        print("CHECKPOINT_PASS: identical replay state, cycle guard, exit guard, bounded waveform")


if __name__ == "__main__":
    main()
