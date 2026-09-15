#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run a Linux KVM fixture; require completed guests, not a host boot banner."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

TESTS = ("ebreak_test", "arch_timer")
COMPLETE = "[KVM-KARU] COMPLETE tests=2 failed=0 skipped=0"


class Results:
    def __init__(self):
        self.started = []
        self.passed = []
        self.completed = False

    def accept(self, line):
        line = line.rstrip("\r")
        if any(marker in line for marker in ("[KVM-KARU] FAIL", "Kernel panic", "Oops:", "%Error", "Assertion failed")):
            raise RuntimeError(f"guest/host failure: {line}")
        if line.startswith("[KVM-KARU] RUN "):
            name = line.removeprefix("[KVM-KARU] RUN ")
            if len(self.started) >= len(TESTS) or name != TESTS[len(self.started)]:
                raise RuntimeError(f"unexpected test start: {line}")
            if self.started != self.passed:
                raise RuntimeError(f"test started before its predecessor passed: {line}")
            self.started.append(name)
        elif line.startswith("[KVM-KARU] PASS "):
            if len(self.passed) >= len(TESTS):
                raise RuntimeError(f"duplicate test result: {line}")
            name = TESTS[len(self.passed)]
            if line != f"[KVM-KARU] PASS {name} exit=0" or self.started != self.passed + [name]:
                raise RuntimeError(f"unexpected test result: {line}")
            self.passed.append(name)
        elif line == COMPLETE:
            if self.completed:
                raise RuntimeError("duplicate completion marker")
            if self.passed != list(TESTS):
                raise RuntimeError("completion marker without both completed upstream tests")
            self.completed = True
            return True
        return False


def stop_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)


def run(command, log_path, wall_seconds, echo=True):
    results = Results()
    pending = b""
    deadline = time.monotonic() + wall_seconds
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("xb") as log:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            while True:
                if time.monotonic() >= deadline:
                    raise RuntimeError("wall-clock timeout before completed guest tests")
                if not selector.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                    if process.poll() is not None:
                        raise RuntimeError(f"simulator exited {process.returncode} without completion")
                    continue
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    # A process can close its output without exiting.  Do not
                    # turn EOF into an unbounded wait outside the wall limit.
                    raise RuntimeError(f"simulator output closed without completion (status={process.poll()})")
                log.write(chunk)
                log.flush()
                if echo:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    results.accept(line.decode("utf-8", errors="replace"))
                if len(pending) > 1024 * 1024:
                    raise RuntimeError("unterminated simulator output exceeded one MiB")
                if results.completed:
                    # Validate every complete line already read, including any
                    # failure after COMPLETE, before deliberately stopping.
                    # This is not a claim about subsequent kernel uptime.
                    log.write(b"[KVM-RUNNER] PASS: both upstream guests completed; stopping simulator\n")
                    return 0
        except RuntimeError as error:
            message = f"[KVM-RUNNER] FAIL: {error}\n"
            log.write(message.encode())
            if echo:
                print(message, end="", file=sys.stderr)
            return 1
        finally:
            selector.close()
            stop_process(process)
            process.stdout.close()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    platform = parser.add_mutually_exclusive_group(required=True)
    platform.add_argument("--model", type=Path)
    platform.add_argument("--qemu", type=Path, help="QEMU TCG fixture control using its generated virt DTB")
    parser.add_argument("--qemu-cpu", default="rv64,h=true,v=true,vlen=256,sstc=true,sv48=false,sv57=false",
                        help="QEMU CPU properties for the fixture control")
    parser.add_argument("--image", type=Path, default=root / "_build/kvm-karu-debugfix/flat.img")
    parser.add_argument("--dtb", type=Path, default=root / "_build/kvm-karu-debugfix/board.dtb")
    parser.add_argument("--kernel", type=Path, default=root / "_build/kvm-karu-debugfix/kernel/arch/riscv/boot/Image")
    parser.add_argument("--initramfs", type=Path, default=root / "_build/kvm-karu-debugfix/initramfs.cpio")
    parser.add_argument("--opensbi", type=Path, default=root / "_build/kvm-karu-debugfix/fw_jump.bin")
    parser.add_argument("--log", required=True, type=Path, help="new log path; existing logs are never overwritten")
    parser.add_argument("--max-cycles", type=int, default=1000000000)
    parser.add_argument("--wall-seconds", type=float, default=14400)
    parser.add_argument("--plusarg", action="append", default=[])
    args = parser.parse_args()
    if args.wall_seconds <= 0 or args.max_cycles <= 0:
        parser.error("timeouts must be positive")
    input_names = ("qemu", "kernel", "initramfs", "opensbi") if args.qemu else ("model", "image", "dtb")
    for name in input_names:
        path = getattr(args, name).resolve(strict=True)
        setattr(args, name, path)
    args.log = args.log.resolve()
    if args.log.exists() or args.log.with_suffix(args.log.suffix + ".json").exists():
        parser.error("log or metadata path already exists; choose a new log name")
    if args.qemu:
        if args.plusarg:
            parser.error("--plusarg applies only to the RTL model")
        command = [str(args.qemu), "-machine", "virt", "-accel", "tcg,thread=single", "-cpu", args.qemu_cpu,
                   "-smp", "1", "-m", "32M", "-nographic", "-no-reboot", "-bios", str(args.opensbi),
                   "-kernel", str(args.kernel), "-initrd", str(args.initramfs),
                   "-append", "console=ttyS0,115200 earlycon rdinit=/init panic=-1 nokaslr"]
    else:
        command = [str(args.model), f"+img={args.image}", f"+dtb={args.dtb}",
                   f"+max_cycles={args.max_cycles}", "+heartbeat=10000000", *args.plusarg]
    inputs = [getattr(args, name) for name in input_names] + [Path(__file__)]
    if not args.qemu:
        for option in args.plusarg:
            if option.startswith("+restore="):
                inputs.append(Path(option.removeprefix("+restore=")).resolve(strict=True))
    metadata = {
        "command": command, "wall_seconds": args.wall_seconds,
        "inputs": {str(path): sha256(path) for path in inputs},
    }
    args.log.parent.mkdir(parents=True, exist_ok=True)
    metadata_path = args.log.with_suffix(args.log.suffix + ".json")
    with metadata_path.open("x") as output:
        json.dump(metadata, output, indent=2)
        output.write("\n")
    return run(command, args.log, args.wall_seconds)


if __name__ == "__main__":
    sys.exit(main())
