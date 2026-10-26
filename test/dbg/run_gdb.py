#!/usr/bin/env python3
"""Bounded real GDB -> OpenOCD -> JTAG -> simulated-hart acceptance."""
# SPDX-License-Identifier: BSD-3-Clause
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import subprocess
import time
import re
import xml.etree.ElementTree as ET


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def gdb_check(expression, expected):
    return (f"if ({expression}) != {expected:#x}\n"
            f"  echo FAIL {expression}\\n\n  quit 1\nend\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--openocd", required=True)
    parser.add_argument("--gdb", default="riscv64-unknown-elf-gdb")
    parser.add_argument("--elf", required=True)
    parser.add_argument("--out", default="_build/dbg/gdb")
    args = parser.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not shutil.which(args.gdb):
        raise RuntimeError(f"Missing RISC-V GDB: {args.gdb}")
    processes = []
    started = time.monotonic()
    try:
        model = subprocess.Popen([args.model, "0", "60"], text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        processes.append(model)
        selector = selectors.DefaultSelector()
        selector.register(model.stdout, selectors.EVENT_READ)
        if not selector.select(10):
            raise RuntimeError("remote_bitbang listener did not start")
        first = model.stdout.readline()
        if not first.startswith("REMOTE_BITBANG_PORT="):
            raise RuntimeError(first)
        port = free_port()
        env = dict(os.environ, KARUDBG_RBB_PORT=first.strip().split("=", 1)[1],
                   KARUDBG_GDB_PORT=str(port))
        with (out / "openocd.log").open("w") as server_log:
            server = subprocess.Popen([args.openocd, "-f", "test/dbg/openocd_gdb.cfg"],
                                      env=env, text=True, stdout=server_log,
                                      stderr=subprocess.STDOUT)
            processes.append(server)
            deadline = time.monotonic() + 15
            while "KARUDBG_GDB_READY" not in (out / "openocd.log").read_text():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("OpenOCD GDB server did not become ready")
                time.sleep(0.05)
            prefix = ("set pagination off\nset confirm off\nset remotetimeout 5\n"
                      "set trace-commands on\n"
                      f"file {json.dumps(str(Path(args.elf).resolve()))}\n"
                      f"target extended-remote 127.0.0.1:{port}\n")

            def run_client(name, commands, marker):
                script = out / (name + ".gdb")
                script.write_text(prefix + commands + "detach\nquit\n")
                with (out / (name + ".log")).open("w") as client_log:
                    result = subprocess.run([args.gdb, "--batch", "-nx", "-x", str(script)],
                                            text=True, stdout=client_log,
                                            stderr=subprocess.STDOUT, timeout=35)
                text = (out / (name + ".log")).read_text()
                if result.returncode or marker not in text:
                    raise RuntimeError(f"GDB acceptance failed; see {out}/{name}.log")
                return text

            # Use plain GDB command files; no embedded Python dependency.
            commands = "set $a0 = 0x123456789abcdef0\n"
            commands += gdb_check("$a0", 0x123456789abcdef0)
            commands += "set $mscratch = 0x7654321012345678\n"
            commands += gdb_check("$mscratch", 0x7654321012345678)
            commands += "set {unsigned long long}0x80002000 = 0xfedcba9876543210\n"
            commands += gdb_check("*(unsigned long long*)0x80002000", 0xfedcba9876543210)
            commands += "set $mstatus = $mstatus | 0x6600\nmaintenance print xml-tdesc\n"
            commands += "echo PASS GDB registers memory description\\n\n"
            first_client = run_client("gdb-registers", commands,
                                      "PASS GDB registers memory description")
            description = re.search(r"<target\b.*?</target>", first_client, re.S)
            if not description:
                raise RuntimeError("GDB did not publish its target description")
            regno = 0
            registers = {}
            for register in ET.fromstring(description.group()).iter("reg"):
                regno = int(register.get("regnum", str(regno)))
                registers[register.get("name")] = (regno, int(register.get("bitsize")))
                regno += 1
            fp_name = "f0" if "f0" in registers else "ft0"
            patterns = [(fp_name, "000000000000f83f"), ("v0", "a5" * 32)]
            commands = ""
            for name, pattern in patterns:
                if name not in registers or registers[name][1] != len(pattern) * 4:
                    raise RuntimeError(f"Missing/wrong-width GDB register {name}")
                number = registers[name][0]
                commands += (f"echo WRITE_{name}_BEGIN\\n\n"
                             f"maintenance packet P{number:x}={pattern}\n"
                             f"echo WRITE_{name}_END\\n\n"
                             f"echo READ_{name}_BEGIN\\n\n"
                             f"maintenance packet p{number:x}\n"
                             f"echo READ_{name}_END\\n\n")
            commands += ("set {unsigned int}0x80001000 = 0x02a00513\n"
                         "set {unsigned int}0x80001004 = 0x00150513\n"
                         "set {unsigned int}0x80001008 = 0x0000006f\n"
                         "set $pc = 0x80001000\nstepi\n")
            commands += gdb_check("$pc", 0x80001004) + gdb_check("$a0", 42)
            commands += "stepi\n"
            commands += gdb_check("$pc", 0x80001008) + gdb_check("$a0", 43)
            commands += "echo PASS GDB real hart FP vector step detach\\n\n"
            second_client = run_client("gdb-context", commands, "PASS GDB real hart")
            for name, pattern in patterns:
                written = second_client.split(f"WRITE_{name}_BEGIN", 1)[1].split(f"WRITE_{name}_END", 1)[0]
                read = second_client.split(f"READ_{name}_BEGIN", 1)[1].split(f"READ_{name}_END", 1)[0]
                if 'received: "OK"' not in written or pattern not in read.lower():
                    raise RuntimeError(f"GDB raw register round trip failed for {name}")
            # 'detach' resumes the hart. Shut down the debug server afterwards.
            if server.poll() is None:
                server.terminate()
            server.wait(timeout=5)
        rest, _ = model.communicate(timeout=5)
        (out / "remote-bitbang.log").write_text(first + rest)
        if model.returncode or "PASS remote_bitbang" not in rest:
            raise RuntimeError("Simulator did not complete the GDB session cleanly")
        (out / "gdb-version.txt").write_text(subprocess.check_output(
            [args.gdb, "--version"], text=True))
        print(f"PASS GDB integration ({time.monotonic()-started:.2f}s); logs: {out}")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.kill()
            process.wait()


if __name__ == "__main__":
    main()
