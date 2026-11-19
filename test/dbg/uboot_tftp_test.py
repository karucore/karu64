#!/usr/bin/env python3
"""U-Boot's network path in simulation: a TFTP download through the modelled
NIC (make uboot-tftp-test).

The board boots Linux only through U-Boot's TFTP download, so a new U-Boot
release is tried here before it goes into a ROM: the U-Boot that
flow/build_uboot.sh builds, without a baked boot command, runs on the Linux
simulation harness (flow/fpga/linux_tb.sv) behind karudeb's OpenSBI, with the
harness's packet backend answering ARP and TFTP. This script types at the
U-Boot prompt and reads the console:

  * the banner names the expected release, and the LiteEth device is found;
  * `tftpboot` fetches a 100 KiB file (seventy blocks at the block size
    U-Boot negotiates); U-Boot's own crc32 of what arrived equals the CRC
    of the file served;
  * a second file, whose length is not a multiple of any block size, the
    same way;
  * a file that does not exist ends in an error, not a hang.

    python3 test/dbg/uboot_tftp_test.py --sim SIM --img FLAT --dtb DTB --dir DIR --release v2026.10
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, os, random, re, select, signal, subprocess, sys, time, zlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--sim", required=True, help="the U-Boot network simulation (Vuboot/Vlinux_tb)")
parser.add_argument("--img", required=True, help="flat image: OpenSBI, and U-Boot 2 MiB in")
parser.add_argument("--dtb", required=True)
parser.add_argument("--dir", required=True, help="work directory: the files served, and the log")
parser.add_argument("--release", required=True, help="the U-Boot release the banner must name, as its tag: v2026.10")
parser.add_argument("--wall-seconds", type=float, default=3600)
args = parser.parse_args()
D = Path(args.dir).resolve()
tftp = D / "tftp"
tftp.mkdir(parents=True, exist_ok=True)
BANNER = "U-Boot " + args.release.lstrip("v")
# Where the files are loaded: above the U-Boot image at 0x80200000 and below
# the heap, which U-Boot puts in the upper half of the model's 32 MiB.
LOAD = "0x80400000"
SERVER, BOARD = "192.168.1.20", "192.168.1.10"
rng = random.Random(20261118)
FILES = {"blocks.bin": rng.randbytes(200 * 512), "odd.bin": rng.randbytes(33 * 512 + 77)}
for name, data in FILES.items():
    (tftp / name).write_bytes(data)

sim = subprocess.Popen([args.sim, f"+img={Path(args.img).resolve()}", f"+dtb={Path(args.dtb).resolve()}", f"+tftp_dir={tftp}",
                        f"+eth_server_ip={SERVER}", "+max_cycles=4000000000"],
                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
log, deadline = bytearray(), time.monotonic() + args.wall_seconds

def fail(why):
    os.killpg(sim.pid, signal.SIGKILL)
    (D / "console.log").write_bytes(log)
    sys.exit(f"FAIL uboot-tftp-test: {why} (console in {D / 'console.log'})")

def until(pattern, what, start):
    """Read the console until `pattern` appears after offset `start`; returns the match."""
    while True:
        found = re.search(pattern, log[start:].replace(b"\r", b""))
        if found:
            return found
        if time.monotonic() > deadline:
            fail(f"no {what} within the time allowed")
        if sim.poll() is not None:
            fail(f"the simulation ended before {what}")
        if select.select([sim.stdout], [], [], 1.0)[0]:
            chunk = os.read(sim.stdout.fileno(), 65536)
            if not chunk:
                fail(f"the simulation closed its output before {what}")
            log.extend(chunk)

def command(line, pattern, what):
    """Type one line at the prompt; wait for `pattern` and then the next prompt."""
    start = len(log)
    for ch in line.encode() + b"\n":                # one character at a time: the UART has no flow control
        sim.stdin.write(bytes([ch])); sim.stdin.flush()
        time.sleep(0.02)
    found = until(pattern, what, start)
    until(rb"=> $", "prompt after " + what, start + found.end())
    return found

until(rb"=> $", "U-Boot prompt", 0)
text = log.decode(errors="replace").replace("\r", "")
if BANNER not in text:
    fail(f"the banner does not name {BANNER}")
if not re.search(r"^Net: +eth0: ethernet@", text, re.M):
    fail("the Ethernet device was not found")
command(f"setenv ipaddr {BOARD}; setenv serverip {SERVER}", rb"", "setenv")
checked = []
for name, data in FILES.items():
    got = command(f"tftpboot {LOAD} {name}; echo tftp-rc=$? size=$filesize",
                  rb"tftp-rc=(\d+) size=([0-9a-f]*)\n", f"the result of tftpboot {name}")
    if got.group(1) != b"0" or int(got.group(2) or b"0", 16) != len(data):
        fail(f"tftpboot {name}: status {got.group(1).decode()}, size {got.group(2).decode()}, expected 0 and {len(data):x}")
    crc = command(f"crc32 {LOAD} $filesize", rb"==> ([0-9a-f]{8})\n", f"crc32 of {name}")
    if int(crc.group(1), 16) != zlib.crc32(data):
        fail(f"{name}: U-Boot's crc32 {crc.group(1).decode()} is not the file's {zlib.crc32(data):08x}")
    checked.append(f"{name} {len(data)} bytes")
got = command(f"tftpboot {LOAD} missing.bin; echo tftp-rc=$?", rb"tftp-rc=(\d+)\n", "the result of a missing file")
if got.group(1) == b"0":
    fail("a file that does not exist was reported as fetched")
os.killpg(sim.pid, signal.SIGKILL)
(D / "console.log").write_bytes(log)
print(f"uboot-tftp-test: PASS ({BANNER}: {', '.join(checked)} fetched by TFTP with matching CRC; a missing file is an error)")
