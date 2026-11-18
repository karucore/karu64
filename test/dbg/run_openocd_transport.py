#!/usr/bin/env python3
"""Run bounded OpenOCD remote_bitbang interoperability for TAP/DTM/DM."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import os
from pathlib import Path
import selectors
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--model", required=True)
parser.add_argument("--openocd", default="openocd")
parser.add_argument("--out", default="_build/dbg")
parser.add_argument("--config", default="test/dbg/openocd_transport.cfg")
parser.add_argument("--marker", default="PASS OpenOCD TAP DTM CDC DMI")
parser.add_argument("--debug", action="store_true")
parser.add_argument("--timeout", type=int, default=25)
parser.add_argument("--expect-failure", default="")
args = parser.parse_args()
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
server = subprocess.Popen([args.model, "0", str(args.timeout)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    selector = selectors.DefaultSelector()
    selector.register(server.stdout, selectors.EVENT_READ)
    if not selector.select(15):
        raise RuntimeError("remote_bitbang listener did not start")
    first_line = server.stdout.readline()
    if not first_line.startswith("REMOTE_BITBANG_PORT="):
        raise RuntimeError(f"Unexpected server greeting: {first_line}")
    port = first_line.strip().split("=", 1)[1]
    env = dict(os.environ, KARUDBG_RBB_PORT=port)
    with (out / "openocd-jtag.log").open("w") as log:
        command = [args.openocd, "-f", args.config]
        if args.debug:
            command.append("-d3")
        result = subprocess.run(command,
                                env=env, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout+5)
    rest, _ = server.communicate(timeout=5)
    (out / "remote-bitbang.log").write_text(first_line + rest)
    log_text = (out / "openocd-jtag.log").read_text()
    if args.expect_failure:
        if not result.returncode or server.returncode or args.expect_failure not in log_text:
            raise RuntimeError("Expected non-timeout OpenOCD mismatch did not occur")
        print(f"PASS pristine OpenOCD negative control: {args.expect_failure}")
        raise SystemExit(0)
    if result.returncode or server.returncode:
        raise RuntimeError(f"OpenOCD={result.returncode}, simulator={server.returncode}; see {out}/openocd-jtag.log and remote-bitbang.log")
    if args.marker not in log_text:
        raise RuntimeError("OpenOCD completion marker missing")
    print(rest.strip())
    print(f"PASS OpenOCD integration; logs: {out}/openocd-jtag.log")
finally:
    if server.poll() is None:
        server.kill()
        server.wait()
