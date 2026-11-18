#!/usr/bin/env python3
"""Offline self-test of the board harness; needs no board and no OpenOCD.

A stand-in for OpenOCD's Tcl RPC port evaluates each command in a Tcl
interpreter with a few stub procedures, which is enough to exercise the
client, the case bookkeeping and the exit status. Checked:

  * every harness script compiles;
  * a phase whose cases all pass exits 0;
  * a failed case is recorded, later cases still run, and the phase exits
    non-zero (the 2026-11-16 scripts ignored case() and exited 0);
  * a failing cleanup and a failing RPC command also give a non-zero exit;
  * transport_phase.py's own dispatch loop, run with stand-in cases: when
    the restore commands after each case fail, the phase exits non-zero
    (those errors used to be discarded);
  * every script that runs cases ends through Board.finish();
  * the image map: the kinds and their overrides, the kinds against the
    RTL they describe, the scratch areas at the 2026-11-16 campaign's
    addresses on the 1 MiB map, a fixture built for another map or too long
    or outside the scratch SRAM refused with the reason, before anything is
    sent to the target;
  * the reset vector: clean_detach_boot.py as a process, for each image
    kind, passes when the hart halts at that kind's vector and fails at any
    other kind's, and one instruction further (the comparison is exact);
  * the authentication client (authlib.py): its constants against the
    contract, the window ROM's source and the window bench; its TEST
    response against the ROM's own C routine, compiled for the host; the
    mailbox exchange against a model of the contract's mailbox, with a
    wrong response, a closed window and a missing challenge; the case list
    of auth_phase.py against the README;
  * kernel symbol lookup and instruction length, used by the live-kernel
    breakpoint so that it follows the kernel that is actually built.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, json, os, random, re, selectors, shutil, socket, subprocess, sys, threading, tkinter
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True)
args = parser.parse_args()
SRC = Path(__file__).resolve().parent
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = 0

def check(cond, what):
    global checks
    checks += 1
    if not cond:
        raise SystemExit(f"FAIL board harness self-test check {checks}: {what}")

class FakeOpenOCD(threading.Thread):
    """Answers 0x1a-terminated Tcl commands on any number of connections.

    One thread owns the Tcl interpreter and multiplexes the sockets, so a
    control connection can change stub behaviour while a phase is connected.
    """
    def __init__(self):
        super().__init__(daemon=True)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(8)
        self.port = self.listener.getsockname()[1]
    def run(self):
        tcl = tkinter.Tcl()
        tcl.eval("proc ok {args} {return ok}")
        tcl.eval("proc boom {args} {error {stub failure}}")
        # A Debug Module as far as reset-halt needs one: data0/data1, abstract
        # register transfers into ::csr, and ndmreset, which puts ::reset_pc
        # into dpc (CSR 0x7b1 = 1969). ::drift moves dpc on a write of dcsr,
        # as a hart would that ran on.
        tcl.eval("set ::reset_pc 0x10000 ; set ::drift 0 ; set ::data 0 ; array set ::csr {}")
        tcl.eval("""proc riscv {sub args} {
            lassign $args a v
            if {$sub eq {dmi_read}} {
                switch -- [expr {$a}] {
                    4 { return [format 0x%x [expr {$::data & 0xffffffff}]] }
                    5 { return [format 0x%x [expr {$::data >> 32}]] }
                    17 { return 0xc82 }
                    default { return 0x0 }
                }
            }
            if {$sub eq {dmi_write}} {
                switch -- [expr {$a}] {
                    4 { set ::data [expr {($::data & ~0xffffffff) | $v}] }
                    5 { set ::data [expr {($::data & 0xffffffff) | ($v << 32)}] }
                    16 { if {$v & 2} { set ::csr(1969) [expr {$::reset_pc}] } }
                    23 {
                        set reg [expr {$v & 0xffff}]
                        if {$v & 0x10000} {
                            set ::csr($reg) $::data
                            if {$reg == 0x7b0} { incr ::csr(1969) $::drift }
                        } else {
                            set ::data [expr {[info exists ::csr($reg)] ? $::csr($reg) : 0}]
                        }
                    }
                }
            }
            return {}
        }""")
        tcl.eval("proc halt {args} {return {}}")
        tcl.eval("proc karu.cpu {args} {return halted}")
        tcl.eval("proc shutdown {args} {return {}}")
        # the restore commands of transport_phase.py; ::fail_restore makes them fail
        tcl.eval("set ::fail_restore 0")
        tcl.eval("proc adapter {args} {if {$::fail_restore} {error {adapter speed rejected}} ; return {}}")
        tcl.eval("proc poll {args} {if {$::fail_restore} {error {poll rejected}} ; return {}}")
        selector = selectors.DefaultSelector()
        selector.register(self.listener, selectors.EVENT_READ)
        pending = {}
        while True:
            for key, _ in selector.select():
                sock = key.fileobj
                if sock is self.listener:
                    conn, _ = sock.accept()
                    selector.register(conn, selectors.EVENT_READ)
                    pending[conn] = b""
                    continue
                try:
                    chunk = sock.recv(65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    selector.unregister(sock); sock.close(); del pending[sock]
                    continue
                buf = pending[sock] + chunk
                while b"\x1a" in buf:
                    command, buf = buf.split(b"\x1a", 1)
                    sock.sendall(tcl.eval(command.decode()).encode() + b"\x1a")
                pending[sock] = buf

server = FakeOpenOCD()
server.start()
os.environ["KARU_BOARD_RPC"] = f"127.0.0.1:{server.port}"
os.environ["KARU_BOARD_OUT"] = str(out)
MAP_SETTINGS = ("KARU_BOARD_IMAGE", "KARU_BOARD_SCRATCH", "KARU_BOARD_SCRATCH_SIZE", "KARU_BOARD_RESET_PC")
for name in MAP_SETTINGS:           # the caller's board selection must not reach this test
    os.environ.pop(name, None)
sys.path.insert(0, str(SRC))
import boardlib
from boardlib import Board

# ---- every script compiles ----
scripts = sorted(SRC.glob("*.py"))
for path in scripts:
    compile(path.read_text(), str(path), "exec")
check(len(scripts) >= 15, "harness scripts found")

# ---- all cases pass: exit status 0 ----
b = Board("selftest-pass")
check(b.cmd("ok 1 2") == "ok", "RPC round trip")
check(b.dmi(0x16) == 0, "DMI read helper")
b.case("first", lambda: b.equal(1, 1, "equal"))
b.case("second", lambda: b.require(True, "require"))
check(b.finish() == 0, "passing phase exits 0")
saved = json.loads((out / "selftest-pass-results.json").read_text())
check([r["status"] for r in saved] == ["PASS", "PASS"], "results recorded")

# ---- a failed case: recorded, later cases still run, exit status 1 ----
b = Board("selftest-fail")
ran = []
check(b.case("passes", lambda: ran.append(1)) is True, "case() reports a pass")
check(b.case("assertion fails", lambda: b.equal(1, 2, "deliberate")) is False, "case() reports a failure")
check(b.case("RPC command fails", lambda: b.cmd("boom")) is False, "a Tcl error fails the case")
b.case("still runs", lambda: ran.append(2))
check(ran == [1, 2], "cases after a failure still run")
check(b.finish() == 1, "a phase with failed cases exits non-zero")
saved = json.loads((out / "selftest-fail-results.json").read_text())
check([r["status"] for r in saved] == ["PASS", "FAIL", "FAIL", "PASS"], "failures recorded per case")
check("stub failure" in saved[2]["detail"], "RPC error text kept")

# ---- a failing cleanup alone is a failure ----
b = Board("selftest-cleanup")
b.case("passes", lambda: None)
def bad_cleanup():
    raise RuntimeError("cleanup could not restore the hart")
check(b.finish(bad_cleanup) == 1, "a failing cleanup exits non-zero")
saved = json.loads((out / "selftest-cleanup-results.json").read_text())
check(saved[-1]["name"] == "phase cleanup" and saved[-1]["status"] == "FAIL", "cleanup failure recorded")

# ---- transport_phase.py: its actual dispatch and restore code ----
# Stand-in cases replace the hardware cases; everything else is the phase's
# own code. With working restore commands it exits 0; with failing ones each
# restore is recorded as a failure and it exits non-zero.
(out / "payload.symbols").write_text(f"{boardlib.FIXTURE:016x} T _start\n")
(out / "payload.bin").write_bytes(bytes(64))
import transport_phase as tp
control = Board("selftest-control")
stand_ins = [("stand-in one", lambda: None), ("stand-in two", lambda: None)]
check(len(tp.CASES) == 4 and tp.main.__defaults__[0] is tp.CASES, "transport phase dispatches its four cases by default")
check(tp.main(cases=stand_ins) == 0, "transport dispatch with working restores exits 0")
saved = json.loads((out / "transport-results.json").read_text())
check([r["status"] for r in saved] == ["PASS", "PASS"], "no restore entry when restores work")
control.cmd("set ::fail_restore 1")
tp.b = tp.bm.b = Board("transport")
check(tp.main(cases=stand_ins) == 1, "transport dispatch with failing restores exits non-zero")
saved = json.loads((out / "transport-results.json").read_text())
check([r["status"] for r in saved] == ["PASS", "FAIL", "PASS", "FAIL"], "each failed restore is recorded")
check(saved[1]["name"] == "restore after stand-in one" and "adapter speed rejected" in saved[1]["detail"],
      "restore failure names its case and keeps the error")
control.cmd("set ::fail_restore 0")
control.close()

# ---- the image map: kinds, overrides, and the RTL they describe ----
ROOT = SRC.parents[2]
KINDS = ("rom2m-auth", "rom2m", "rom1m")                    # the three kinds of board image
image = boardlib.image_map({})
check(boardlib.IMAGE == image and (image["image"], image["scratch"], image["size"], image["reset_pc"]) == ("rom2m-auth", 0x201000, 0x10000, 0x10000),
      "no setting: the default debug image, 2 MiB boot ROM, hart starting in the authentication island")
maps = {kind: boardlib.image_map({"KARU_BOARD_IMAGE": kind}) for kind in boardlib.IMAGES}
check([(maps[k]["scratch"], maps[k]["reset_pc"]) for k in KINDS] == [(0x201000, 0x10000), (0x201000, 0x1000), (0x101000, 0x1000)],
      "scratch base and reset vector of the three image kinds")
check({name: boardlib.area(name, maps["rom1m"]) for name in boardlib.AREAS} ==
      dict(fixture=0x108000, probe=0x108700, code=0x108800, vector=0x108900, patch=0x109000, matrix=0x10c000, data=0x10e000, page=0x10f000),
      "on the 1 MiB map every scratch area is where the 2026-11-16 campaign had it")
check(all(boardlib.area(name, maps["rom2m"]) - boardlib.area(name, maps["rom1m"]) == 0x100000 for name in boardlib.AREAS)
      and boardlib.FIXTURE == 0x208000, "on the 2 MiB map the same areas are 1 MiB higher")
spans = sorted(boardlib.AREAS.values())
check(all(a + n <= b for (a, n), (b, _) in zip(spans, spans[1:])) and spans[-1][0] + spans[-1][1] <= 0x10000,
      "the scratch areas do not overlap and end inside 64 KiB")
custom = boardlib.image_map({"KARU_BOARD_IMAGE": "rom1m", "KARU_BOARD_SCRATCH": "0x301000", "KARU_BOARD_RESET_PC": "0x2000", "KARU_BOARD_SCRATCH_SIZE": "0x20000"})
check((custom["scratch"], custom["size"], custom["reset_pc"]) == (0x301000, 0x20000, 0x2000) and boardlib.area("data", custom) == 0x30e000
      and "KARU_BOARD_SCRATCH=0x301000" in boardlib.describe(custom), "explicit scratch base, size and reset vector replace the kind's")
check(boardlib.image_map({"KARU_BOARD_RESET_PC": "0x2000"})["scratch"] == 0x201000, "an override leaves the rest of the kind alone")

def refusal(fn, *a):
    """The reason a harness function refuses with, or None if it goes on."""
    try:
        fn(*a)
    except SystemExit as e:
        return str(e.code)
    return None
reason = refusal(boardlib.image_map, {"KARU_BOARD_IMAGE": "rom4m"})
check(reason and "rom4m is not an image kind" in reason and all(kind in reason for kind in KINDS), f"an unknown image kind is refused, with the kinds named: {reason}")
check("is not a number" in (refusal(boardlib.image_map, {"KARU_BOARD_SCRATCH": "2 MiB"}) or ""), "an override that is not a number is refused")

# The kinds describe RTL that lives elsewhere. If that moves again, this is where it shows.
def number(text):
    return int(text.replace("_", ""), 16)
bootmap = (ROOT / "rtl/karu_bootmap.vh").read_text()
pages = number(re.search(r"`define KARU_BOOT_ROM_PAGES 20'h(\w+)", bootmap).group(1))
lo, hi = (number(re.search(rf"`define KARU_BOOT_SCRATCH_{end} \(20'h(\w+) \+ `KARU_BOOT_ROM_PAGES\)", bootmap).group(1)) for end in ("LO", "HI"))
check(((lo + pages) << 12, (hi - lo) << 12) == (maps["rom2m-auth"]["scratch"], maps["rom2m-auth"]["size"])
      and maps["rom2m"]["scratch"] == maps["sim"]["scratch"] == maps["rom2m-auth"]["scratch"],
      "rom2m-auth, rom2m and sim have the scratch SRAM of rtl/karu_bootmap.vh")
top = (ROOT / "flow/fpga/vcu118_ddr_top.v").read_text()
vectors = [number(v) for v in re.findall(r"karudbg_core #\(\.RESET_PC\(64'h(\w+)\)", top)]
auth = re.search(r"`ifdef KARU_DBG_AUTH\s[^`]*?karudbg_core #\(\.RESET_PC\(64'h(\w+)\)", top)
check(sorted(vectors) == [0x1000, 0x10000] and auth and number(auth.group(1)) == maps["rom2m-auth"]["reset_pc"] and maps["rom2m"]["reset_pc"] == 0x1000,
      "rom2m-auth and rom2m have the reset vectors of flow/fpga/vcu118_ddr_top.v, with and without KARU_DBG_AUTH")
default = re.search(r"parameter \[63:0\] RESET_PC=64'h(\w+)", (ROOT / "dbg/karudbg_top.v").read_text())
bench = (ROOT / "test/dbg/tb_jtag_core.v").read_text()
check(number(default.group(1)) == maps["sim"]["reset_pc"] and re.search(r"\n\s*karudbg_top dut \(", bench)        # no RESET_PC override
      and "KARU_BOOT_SCRATCH_LO" in (ROOT / "test/dbg/karudbg_test_ram.sv").read_text(),
      "sim has the reset vector and scratch SRAM of the rehearsal's simulated target")

# ---- the fixture must be the selected map's, and fit ----
def fixture_dir(name, start, length=1480, symbols=True):
    where = out / name
    where.mkdir(exist_ok=True)
    for f in where.glob("payload.*"):
        f.unlink()
    if symbols:
        (where / "payload.symbols").write_text(f"{start:016x} T _start\n{start + 0x400:016x} T trap_handler\n")
        (where / "payload.bin").write_bytes(bytes(length))
    return where
for kind in boardlib.IMAGES:
    start = boardlib.area("fixture", maps[kind])
    check(boardlib.fixture_symbols(fixture_dir("fixture-" + kind, start), maps[kind]) == {"_start": start, "trap_handler": start + 0x400},
          f"{kind}: its own fixture is accepted")
old, new = fixture_dir("fixture-rom1m", 0x108000), fixture_dir("fixture-rom2m", 0x208000)
reason = refusal(boardlib.fixture_symbols, old, maps["rom2m-auth"])
check(reason and all(text in reason for text in ("linked at 0x108000", "has the fixture at 0x208000", "scratch SRAM 0x201000..0x210fff",
                                                  "make dbg-board-fixture", "DBG_BOARD_IMAGE=rom2m-auth", "KARU_BOARD_IMAGE=rom1m")),
      f"a fixture linked for the 1 MiB map is refused on the 2 MiB map, with both addresses and both ways out: {reason}")
reason = refusal(boardlib.fixture_symbols, new, maps["rom1m"])
check(reason and "linked at 0x208000" in reason and "has the fixture at 0x108000" in reason and "KARU_BOARD_IMAGE=rom2m-auth or rom2m or sim" in reason,
      "and the other way round")
check(refusal(boardlib.fixture_symbols, new, maps["rom2m"]) is None, "rom2m-auth and rom2m share one fixture")
reason = refusal(boardlib.fixture_symbols, new, custom)
check(reason and "has the fixture at 0x308000" in reason and "DBG_BOARD_SCRATCH=0x301000" in reason and "without KARU_BOARD_SCRATCH" in reason,
      f"a fixture for a preset is refused on an explicit map, with the make variables that build the right one: {reason}")
reason = refusal(boardlib.fixture_symbols, fixture_dir("fixture-none", 0, symbols=False), image)
check(reason and "no payload.symbols and payload.bin" in reason and "make dbg-board-fixture" in reason, "a missing fixture is refused with the command that builds it")
limit = boardlib.AREAS["fixture"][1]
check(refusal(boardlib.fixture_symbols, fixture_dir("fixture-long", 0x208000, limit), image) is None, "a fixture that just fits is accepted")
reason = refusal(boardlib.fixture_symbols, fixture_dir("fixture-long", 0x208000, limit + 1), image)
check(reason and f"is {limit + 1} bytes" in reason and "would run into the area at 0x208700" in reason, f"a fixture one byte too long is refused: {reason}")
small = boardlib.image_map({"KARU_BOARD_SCRATCH_SIZE": "0xefff"})
reason = refusal(boardlib.fixture_symbols, new, small)
check(reason and "'page' area 0x20f000..0x20ffff" in reason and "outside the scratch SRAM" in reason, f"an area outside the scratch SRAM is refused: {reason}")
check(refusal(boardlib.fixture_symbols, new, boardlib.image_map({"KARU_BOARD_SCRATCH_SIZE": "0xf000"})) is None, "and a scratch SRAM that just holds them is accepted")

# As processes: a fixture phase given the wrong fixture stops with the reason
# and exit status 1 before it connects, so nothing has reached the target.
def process(script, where, **settings):
    env = dict(os.environ, KARU_BOARD_OUT=str(where), **settings)
    for f in where.glob("*-commands.jsonl"):
        f.unlink()
    return subprocess.run([sys.executable, str(SRC / script)], env=env, capture_output=True, text=True, timeout=120)
for script in ("baremetal_phase.py", "privilege_phase.py", "getnoise_capture.py"):
    r = process(script, old)
    check(r.returncode == 1 and "board harness: the fixture in" in r.stderr and "linked at 0x108000" in r.stderr and "Traceback" not in r.stderr
          and not list(old.glob("*-commands.jsonl")), f"{script} refuses the 1 MiB fixture on the default map: exit {r.returncode}, {r.stderr[-120:]}")
r = process("baremetal_phase.py", old, KARU_BOARD_IMAGE="rom4m")
check(r.returncode == 1 and "rom4m is not an image kind" in r.stderr and "Traceback" not in r.stderr, "a phase with an unknown image kind stops with the reason")
r = process("privilege_phase.py", old, KARU_BOARD_IMAGE="rom1m")
check("board harness:" not in r.stderr and list(old.glob("privilege-commands.jsonl")), "with the matching image kind the same phase gets as far as the target")

# ---- the reset vector: exact, and the image kind's ----
control = Board("selftest-control")
def detach(kind, vector, drift=0):
    """clean_detach_boot.py as a process: (exit status, failed details)."""
    control.cmd(f"set ::reset_pc {vector:#x} ; set ::drift {drift} ; array unset ::csr")
    where = out / ("detach-" + kind)
    where.mkdir(exist_ok=True)
    r = process("clean_detach_boot.py", where, KARU_BOARD_IMAGE=kind)
    results = json.loads((where / "clean-detach-boot-results.json").read_text())[-1:]
    return r.returncode, " ".join(str(x["detail"]) for x in results if x["status"] != "PASS"), r.stdout
for kind in KINDS:
    code, detail, text = detach(kind, maps[kind]["reset_pc"])
    check(code == 0 and f'"dpc": "{maps[kind]["reset_pc"]:#x}"' in text and f'"image": "{kind} (' in text, f"{kind}: reset-halt at {maps[kind]['reset_pc']:#x} passes: {detail}")
    wrong = 0x10000 if maps[kind]["reset_pc"] == 0x1000 else 0x1000
    code, detail, _ = detach(kind, wrong)
    check(code == 1 and f"reset-halt DPC before first instruction: {wrong} != {maps[kind]['reset_pc']}" in detail, f"{kind}: reset-halt at {wrong:#x}, another kind's vector, fails: {detail}")
    code, detail, _ = detach(kind, maps[kind]["reset_pc"] + 4)
    check(code == 1 and "reset-halt DPC before first instruction" in detail, f"{kind}: a hart one instruction past its reset vector fails")
    code, detail, _ = detach(kind, maps[kind]["reset_pc"], drift=2)
    check(code == 1 and f"reset-halt DPC: {maps[kind]['reset_pc'] + 2} != {maps[kind]['reset_pc']}" in detail, f"{kind}: clean_detach_boot.py's own comparison is exact too: {detail}")
env = dict(os.environ, KARU_BOARD_RESET_PC="0x80000000")
control.cmd("set ::reset_pc 0x80000000 ; set ::drift 0 ; array unset ::csr")
r = subprocess.run([sys.executable, str(SRC / "clean_detach_boot.py")], env=env, capture_output=True, text=True, timeout=120)
check(r.returncode == 0 and "KARU_BOARD_RESET_PC=0x80000000" in r.stdout, "an explicit reset vector is the one expected")
control.cmd("set ::reset_pc 0x10000 ; array unset ::csr")
b = Board("selftest-reset")
check(b.case("reset-halt", b.reset_halt) is True and boardlib.RESET_PC == 0x10000, "Board.reset_halt() expects the default kind's vector, 0x10000")
control.cmd("set ::reset_pc 0x1000 ; array unset ::csr")
check(b.case("reset-halt", b.reset_halt) is False and "4096 != 65536" in b.results[-1]["detail"], "and fails at 0x1000, which every image built before 2026-11-17 had")
b.close()
control.close()
for name in ("boardlib.py", "clean_detach_boot.py"):
    check("0x1000,'reset-halt" not in (SRC / name).read_text(), f"{name} has no fixed reset vector")
for path in scripts:
    if path.name not in ("boardlib.py", "test_boardlib.py", "test_getnoise.py"):
        check(not re.search(r"0x(10[89a-f]|20[89a-f])[0-9a-f]{3}\b", path.read_text()), f"{path.name} has no fixed scratch address")
check(not re.search(r"0x00?10[89a-f][0-9a-f]{3}\b", (SRC / "translation-board.tcl").read_text()), "translation-board.tcl has no fixed scratch address")

# ---- linux_reboot.py: evidence of a boot through the ROM ----
# A changed boot ID and a short uptime also follow a kexec. Only fu-boot and
# then OpenSBI banners on the console show a reset to the boot ROM.
import linux_reboot
through_rom = ("[12:40:17] Restarting system\n[12:40:18] ## fu-boot: copying boot chain from ROM to DDR\r\n"
               "[12:40:19] OpenSBI v1.9\r\n[12:40:25] Linux version 7.4.0\n")
check(linux_reboot.rom_boot_evidence(through_rom) == "OpenSBI v1.9", "fu-boot then OpenSBI banners are evidence of a ROM boot")
check(linux_reboot.rom_boot_evidence("Restarting system\nLinux version 7.4.0\n") is None, "a restart without boot banners is not")
check(linux_reboot.rom_boot_evidence("OpenSBI v1.9\n## fu-boot: copying boot chain from ROM to DDR\n") is None,
      "an OpenSBI banner from before the fu-boot banner does not count")
linux_reboot.UART_LOG = out / "no-such-console.log"
check(linux_reboot.NEED_UART and linux_reboot.cycle(1) is False, "without a console capture a cycle fails instead of passing")
check("cannot show that the restart goes through the boot ROM" in linux_reboot.results[-1]["detail"], "and says why")

# ---- linux_zkr.py: reading an ISA description ----
import linux_zkr
check(linux_zkr.isa_has("isa\t\t: rv64imafdcbvh_zicbom_zbs_zkr_zkt_zvbb", "zkr"), "zkr found in a /proc/cpuinfo isa line")
check(not linux_zkr.isa_has("isa\t\t: rv64imafdcbvh_zicbom_zbs_zkt_zvkr0", "zkr"), "zkt and look-alikes are not zkr")
check(linux_zkr.isa_has("i\0m\0zbs\0zkr\0zkt\0", "zkr") and not linux_zkr.isa_has("i\0m\0zkt\0", "zkr"),
      "zkr found, or not, in a device-tree string list")

# ---- kernel symbol lookup (linux_kernel_bp.py) ----
# The addresses of the 2026-11-16 campaign's 7.2.6 kernel must come out of a
# System.map carrying them; another kernel's map gives its own addresses.
(out / "System.map").write_text(
    "ffffffff80000000 T _start\nffffffff80001000 T _text\n"
    "ffffffff80048eaa T __riscv_sys_getpid\nffffffff8004b49a T other_symbol\n")
va, pa = boardlib.kernel_symbol("__riscv_sys_getpid", out / "System.map")
check(va == 0xffffffff80048eaa and pa == 0x80248eaa, "symbol resolves to the campaign's virtual and physical address")
check(boardlib.kernel_symbol("other_symbol", out / "System.map") == (0xffffffff8004b49a, 0x8024b49a), "another symbol resolves independently")
try:
    boardlib.kernel_symbol("missing_symbol", out / "System.map"); missing = False
except KeyError:
    missing = True
check(missing, "a symbol that is not in System.map is an error, not a default")
check(boardlib.insn_length(bytes([0x01, 0x45, 0x13, 0x05]), 0) == 2, "compressed instruction length")
check(boardlib.insn_length(bytes([0x01, 0x45, 0x13, 0x05]), 2) == 4, "32-bit instruction length")
for name in ("linux_kernel_bp.py", "post_linux_host.py", "post-linux.sh"):
    text = (SRC / name).read_text()
    check("7.2.6" not in text and "80048eaa" not in text, f"{name} names no fixed kernel release or address")

# ---- authlib.py: the authentication client ----
# Constants: the contract's tables, the ROM's source and the window bench
# each state them once more; a change in any of those shows here.
import authlib
contract = (ROOT / "doc/debug-auth-contract.md").read_text()
rom_source = ROOT / "test/dbg/auth_rom/window.c"
rom, host_model = rom_source.read_text(), (ROOT / "test/dbg/auth_rom/host_test.c").read_text()
bench = (ROOT / "test/dbg/tb_auth_window.sv").read_text()
def c_words(text, name):
    return tuple(int(w, 16) for w in re.findall(r"0x([0-9a-f]+)u", re.search(name + r"\[[^\]]*\] = \{([^}]*)\}", text).group(1)))
def c_define(name):
    return int(re.search(rf"#define {name}\s+(\w+?)u?\s", rom).group(1), 0)
check(c_words(rom, "test_key") == authlib.TEST_KEY == c_words(host_model, "host_key"), "TEST key of window.c and host_test.c")
check(c_words(rom, "device_digest") == authlib.DEVICE_DIGEST, "device digest of window.c")
check((c_define("ALG_TEST"), c_define("TEST_SIG_WORDS"), c_define("CHALLENGE_WORDS")) == (authlib.ALG_TEST, authlib.TEST_SIG_WORDS, authlib.CHALLENGE_WORDS),
      "algorithm identifier and frame sizes of window.c")
check("challenge[0] = (0x01u << 24) | (1u << 16) | (ALG_TEST << 8);" in rom and authlib.frame_header(authlib.CHALLENGE, authlib.ALG_TEST) == 0x01018000
      and "challenge[1] = 72u | (perm_req << 16) | (lc << 24);" in rom and authlib.CHALLENGE_BODY_BYTES == 72, "challenge header and length word as window.c builds them")
sample = [authlib.frame_header(authlib.CHALLENGE, authlib.ALG_TEST), 0x01010048, *authlib.DEVICE_DIGEST, *range(0x1000, 0x1008), 0, 0]
check("if (i == 0) return 0x02018000u;" in host_model and "if (i == 1) return 0x00010020u;" in host_model
      and authlib.response(sample)[:2] == [0x02018000, 0x00010020] and len(authlib.response(sample)) == 10, "response header and length word as host_test.c sends them")
for word, text in ((authlib.request_word(), "32'h10a50001"), (authlib.header(authlib.OP_SEND, 10), "32'h2000000a"),
                   (authlib.header(authlib.OP_RECV, 0), "32'h30000000 | n"), (authlib.header(authlib.OP_ABORT), "32'hf0000000")):
    check(text in bench and f"{word:08x}" in text, f"authdata word {word:#010x} as tb_auth_window.sv writes it")
operations = dict(re.findall(r"\| `(STATUS|REQUEST|SEND|RECV|ABORT)(?: n)?` \| `0x([0-9A-F])` \|", contract))
check({k: int(v, 16) for k, v in operations.items()} == dict(STATUS=authlib.OP_STATUS, REQUEST=authlib.OP_REQUEST, SEND=authlib.OP_SEND,
      RECV=authlib.OP_RECV, ABORT=authlib.OP_ABORT) and "`0xA5` key" in contract and authlib.REQUEST_KEY == 0xa5, "operation codes and REQUEST key of contract 4.1")
check("| 31:28 | Magic `0x6` |" in contract and "| 27:26 | Protocol version, 1 |" in contract and "| 23:21 | Session state" in contract
      and "| 20:18 | Sticky error: 0 none, 1 `OVERFLOW`, 2 `UNDERFLOW`, 3 `BAD_OP`, 4 `BAD_STATE` |" in contract
      and "| 15:11 | `SEND remaining`" in contract and "| 9:5 | RX free (0–16) |" in contract and "| 4:0 | TX available (0–16) |" in contract,
      "status word layout of contract 4.2")
check(all(f"| {code} | `{name}` |" in contract for code, name in authlib.STATES.items()), "session states of contract 4.3")
check("`0x01` CHALLENGE (TX), `0x02` RESPONSE (RX), `0x03` RESULT (TX)" in contract and "| `0x80` | `TEST`" in contract
      and (authlib.CHALLENGE, authlib.RESPONSE, authlib.RESULT, authlib.FRAME_VERSION) == (1, 2, 3, 1), "frame types and the TEST identifier of contract 5")
check(all(f"| {bit} | `{name}` |" in contract for bit, name in ((0, "auth_unlock"), (1, "boot_done"), (2, "fw_lock"), (3, "debug_enable"),
      ("5:4", "lc"), (6, "hold"), (7, "auth_req"), (24, "revoked"))) and "| `0x7C0` | `mdbgauth` |" in contract
      and (authlib.AUTH_UNLOCK, authlib.BOOT_DONE, authlib.FW_LOCK, authlib.DEBUG_ENABLE, authlib.HOLD, authlib.AUTH_REQ, authlib.REVOKED, authlib.CSR_MDBGAUTH)
      == (1, 2, 4, 8, 0x40, 0x80, 1 << 24, 0x7c0), "mdbgauth fields of contract 3.1")
held = authlib.parse_status(0x65200200)
check((held["mailbox"], held["lc"], held["state"], held["error"], held["send_remaining"], held["rx_free"], held["tx_available"])
      == (True, "AUTH", "HOLD", None, 0, 16, 0) and authlib.parse_status(0x65704a04)["state"] == "CLOSED"
      and authlib.parse_status(0x65704a04)["error"] == "BAD_STATE" and authlib.parse_status(0x65704a04)["send_remaining"] == 9
      and authlib.parse_status(0x65704a04)["tx_available"] == 4
      and not authlib.parse_status(0)["mailbox"] and not authlib.parse_status(0x55200200)["mailbox"], "status words are taken apart as contract 4.2 lays them out")
def rejected(words):
    try:
        authlib.parse_challenge(words)
    except ValueError:
        return True
    return False
check(authlib.parse_challenge(sample) == dict(perm_req=1, lc="AUTH", digest=list(authlib.DEVICE_DIGEST), nonce=list(range(0x1000, 0x1008)), por_counter=0)
      and rejected(sample[:19]) and rejected([sample[0] ^ 0x100] + sample[1:]) and rejected([sample[0], sample[1] ^ 8] + sample[2:]),
      "a challenge is taken apart, and one with another header, length or size is rejected")

# The TEST response against the ROM's own routine: window.c compiled for the
# host, as host_test.c does, with nothing mocked that the routine uses.
(out / "test_signature.c").write_text(f"""#include <stdio.h>
#include <stdlib.h>
#define AUTH_ROM_HOST
#include "{rom_source}"
uint64_t mock_read(unsigned c) {{ (void)c; return 0; }}
uint64_t mock_rw(unsigned c, uint64_t w) {{ (void)c; (void)w; return 0; }}
void mock_set(unsigned c, uint64_t w) {{ (void)c; (void)w; }}
void mock_write(unsigned c, uint64_t w) {{ (void)c; (void)w; }}
uint64_t mock_cycles(void) {{ return 0; }}
int main(int argc, char **argv) {{
    uint32_t sig[TEST_SIG_WORDS];
    if (argc != 2 + (int)CHALLENGE_WORDS) return 2;
    for (unsigned i = 0; i < CHALLENGE_WORDS; i++) challenge[i] = (uint32_t)strtoul(argv[2 + i], 0, 16);
    test_signature((uint32_t)strtoul(argv[1], 0, 16), sig);
    for (unsigned i = 0; i < TEST_SIG_WORDS; i++) printf("%08x\\n", sig[i]);
    return 0;
}}
""")
compiler = shutil.which("cc") or shutil.which("gcc")
check(compiler is not None, "a host C compiler, to run the ROM's TEST routine")
built = subprocess.run([compiler, "-O1", "-o", str(out / "test_signature"), str(out / "test_signature.c")], capture_output=True, text=True)
check(built.returncode == 0, f"window.c compiles for the host: {built.stderr[-300:]}")
def rom_signature(challenge, granted):
    r = subprocess.run([str(out / "test_signature"), f"{granted:x}", *[f"{w:x}" for w in challenge]], capture_output=True, text=True, check=True)
    return [int(line, 16) for line in r.stdout.split()]
rng = random.Random(0x80)
vectors = [(sample, 1)] + [([rng.getrandbits(32) for _ in range(20)], granted) for granted in (1, 1, 0x01, 0x80, 0xff, 0x5a)]
check(all(authlib.test_signature(c, g) == rom_signature(c, g) for c, g in vectors), "authlib's TEST response equals the ROM routine's on seven challenges and five masks")
check(rom_signature(sample, 1)[0] == authlib.TEST_KEY[0] ^ 0x01010101 ^ sample[0] ^ sample[8] ^ sample[16],
      "word 0 of the routine's output is the key, the mask and challenge words 0, 8 and 16")
broken = authlib.rotl
authlib.rotl = lambda x, r: ((x >> r) | (x << (32 - r))) & 0xffffffff if r else x
check(any(authlib.test_signature(c, g) != rom_signature(c, g) for c, g in vectors), "negative control: with the rotation reversed the comparison fails")
authlib.rotl = broken

# The exchange against a model of the contract's mailbox (section 4) with a
# ROM behind it that pushes a challenge a few words at a time and accepts
# exactly the response that the C routine computes.
class MailboxModel:
    def __init__(self, challenge, accept, state="HOLD"):
        self.challenge, self.accept, self.state = list(challenge), accept, state
        self.tx, self.rx, self.to_push, self.send, self.recv, self.error = [], [], [], 0, 0, 0
        self.authenticated, self.dmactive, self.log = False, 0, []
    def rom(self):                                          # the ROM's turn: push three words, or judge a full response
        if self.state != "REQUESTED": return
        for _ in range(3):
            if self.to_push and len(self.tx) < 16: self.tx.append(self.to_push.pop(0))
        if len(self.rx) == 10:
            self.authenticated, self.state = self.rx == self.accept, "CLOSED"
    def fail(self, code):
        self.error = self.error or code
    def dmi(self, address, value=None):
        if address == authlib.DMCONTROL:
            if value is None: return self.dmactive
            self.dmactive = value & 1
        elif address == authlib.DMSTATUS and value is None:
            return 3 | (self.authenticated << 7)
        return 0
    def cmd(self, command):
        self.log.append(command)
        if command == "riscv authdata_read":
            self.rom()
            if self.recv:
                self.recv -= 1
                return f"{self.tx.pop(0):#010x}"
            code = {"IDLE": 0, "HOLD": 1, "REQUESTED": 2, "CLOSED": 3}[self.state]
            return f"{(6 << 28) | (1 << 26) | (1 << 24) | (code << 21) | (self.error << 18) | (self.send << 11) | ((16 - len(self.rx)) << 5) | len(self.tx):#010x}"
        word = int(command.split()[-1], 16)
        if self.send:
            self.rx.append(word); self.send -= 1
        elif word >> 24 & 0xf: self.fail(3)
        elif word >> 28 == authlib.OP_STATUS: self.recv = 0
        elif word >> 28 == authlib.OP_REQUEST:
            if word != 0x10a50001: self.fail(3)
            elif self.state != "HOLD": self.fail(4)
            else: self.state, self.to_push = "REQUESTED", list(self.challenge)
        elif word >> 28 == authlib.OP_SEND:
            if self.state == "CLOSED": self.fail(4)
            elif not 1 <= word & 0x1f <= 16 - len(self.rx): self.fail(1)
            else: self.send = word & 0x1f
        elif word >> 28 == authlib.OP_RECV:
            if not 1 <= word & 0x1f <= len(self.tx): self.fail(2)
            else: self.recv = word & 0x1f
        elif word >> 28 == authlib.OP_ABORT: self.tx, self.rx, self.send, self.recv, self.error = [], [], 0, 0, 0
        else: self.fail(3)
        self.rom()
        return ""
challenge = vectors[1][0]
accept = [0x02018000, 0x00010020] + rom_signature(challenge, 1)
model = MailboxModel(challenge, accept)
box = authlib.Mailbox(model, poll=0)
box.activate()
check(box.status()["state"] == "HOLD" and not box.authenticated(), "model: held and locked")
box.request()
received = box.receive(20, 5)
recvs = [int(c.split()[-1], 16) & 0x1f for c in model.log if c.startswith("riscv authdata_write 0x3")]
check(received == challenge and len(recvs) >= 2 and sum(recvs) == 20 and model.error == 0, f"a 20-word challenge comes through the 16-word FIFO in several RECVs: {recvs}")
box.send(authlib.response(received))
check(box.wait_decision(5) is True and model.rx == accept, "the response the client builds is the one the ROM routine accepts")
model = MailboxModel(challenge, accept); box = authlib.Mailbox(model, poll=0); box.request()
wrong = authlib.response(box.receive(20, 5)); wrong[9] ^= 0x80000000
box.send(wrong)
check(box.wait_decision(5) is False and box.status()["state"] == "CLOSED", "one wrong bit: no grant, and the client reports the closed window")
writes = len(model.log)
try:
    box.send(authlib.response(challenge)); refused_text = ""
except RuntimeError as e:
    refused_text = str(e)
check("BAD_STATE" in refused_text and sum(c.startswith("riscv authdata_write") for c in model.log[writes:]) == 1,
      "a SEND into a closed window is reported, and no payload word follows the refused header")
model = MailboxModel(challenge, accept, state="CLOSED"); box = authlib.Mailbox(model, poll=0); box.request()
try:
    box.receive(20, 1); missing = ""
except TimeoutError as e:
    missing = str(e)
check("0 of 20 words received" in missing and "CLOSED" in missing and box.status()["error"] == "BAD_STATE", "no challenge from a closed window: the client says what it saw")

# auth_phase.py: one case per run, and the same list in its header and the README
import auth_phase
auth_phase.b.close()
readme = (SRC / "README.md").read_text()
header_text = (SRC / "auth_phase.py").read_text().split("from boardlib import")[0]
check(len(auth_phase.CASES) == 12 and all(f"| `{name}` |" in readme and f"#   {name} " in header_text for name in auth_phase.CASES),
      "every authentication case is in the phase's header and in the README table")
check("protects nothing" in readme and "protects" in header_text and "protects nothing" in (SRC / "authlib.py").read_text(),
      "README, phase and client say that the TEST algorithm protects nothing")
# The cases that need Linux, the seed CSR or a second boot cannot be
# rehearsed on the simulated target. They are run here against scripted
# stand-ins, which shows that their steps hang together and that they stop
# for the right reasons; the stand-ins are assumptions, not the board.
class ScriptedTarget:
    """OpenOCD and the Debug Module as auth_phase.py uses them, in Python."""
    def __init__(self, lc, mailbox=None, authenticated=False, seed=0):
        self.lc, self.mailbox, self.authenticated, self.seed = lc, mailbox, authenticated, seed
        self.examined, self.state, self.dmactive, self.data, self.cmderr, self.progbuf0 = False, "running", 0, 0, 0, 0
        self.csr = {0x7c0: (lc << 4) | (8 if lc == 0 else 0), 0x100a: 0x1111, 0x1008: 0x2222, 0x7b1: 0x80200000}
    def open(self):
        return self.lc == 0 or (self.mailbox is not None and self.mailbox.authenticated) or self.authenticated
    def command(self, command):
        words = command.split()
        if words[0] == "karu.cpu":
            if words[1] == "was_examined": return str(int(self.examined))
            if words[1] == "curstate": return self.state
            if not self.open(): raise RuntimeError("examine refused")
            self.examined = True
        elif words[0] == "halt": self.state = "halted"
        elif words[0] == "resume": self.state = "running"
        elif words[:2] == ["riscv", "dmi_read"]:
            address = int(words[2], 0)
            if address == 0x10: return hex(self.dmactive)
            if address == 0x11: return hex(3 | (0x80 if self.open() else 0))
            if not self.open(): return "0x0"
            return hex({4: self.data & 0xffffffff, 5: self.data >> 32, 0x16: self.cmderr << 8}.get(address, 0))
        elif words[:2] == ["riscv", "dmi_write"]:
            address, value = int(words[2], 0), int(words[3], 0)
            if address == 0x10: self.dmactive = value & 1
            elif not self.open(): pass
            elif address == 4: self.data = (self.data & ~0xffffffff) | value
            elif address == 5: self.data = (self.data & 0xffffffff) | (value << 32)
            elif address == 0x16: self.cmderr = 0
            elif address == 0x20: self.progbuf0 = value
            elif address == 0x17 and value == 0x40000:          # run the Program Buffer: csrrw s0, seed, x0
                if self.progbuf0 == 0x01501473 and self.seed is not None: self.csr[0x1008] = self.seed
                else: self.cmderr = 3
            elif address == 0x17:
                reg = value & 0xffff
                if value & 0x10000: self.csr[reg] = self.data
                else: self.data = self.csr.get(reg, 0)
        elif words[0] == "get_reg": return f"{words[-1].strip('{}')} {self.csr[0x7b1 if 'pc' in words[-1] else 0x100a]:#x}"
        elif words[0] == "reg": self.csr[0x100a] = int(words[2], 0)
        elif words[:2] == ["riscv", "authdata_read"]:
            return self.mailbox.cmd(command) if self.mailbox and self.dmactive else "0x00000000"
        elif words[:2] == ["riscv", "authdata_write"]:
            if self.mailbox and self.dmactive: self.mailbox.cmd(command)
        return ""
class ScriptedBoard(Board):
    def __init__(self, tag, target):
        self.tag, self.target, self.parser, self.results, self.checks = tag, target, tkinter.Tcl(), [], 0
        self.trace = (out / (tag + "-commands.jsonl")).open("a", buffering=1)
    def cmd(self, command):
        return self.target.command(command)
    def close(self):
        self.trace.close()
class ScriptedLinux:
    """SSH as linux_reboot.py uses it: a board that is up, and reboots through the ROM unless told otherwise."""
    def __init__(self, uptime=40, console=None, through_rom=True):
        self.boot, self.uptime, self.down, self.console, self.through_rom, self.on_reboot = 1, uptime, 0, console, through_rom, None
    def up(self):
        self.down -= 1
        return self.down < 0
    def ssh(self, command, timeout=60):
        if command == "reboot":
            self.boot, self.down, self.uptime = self.boot + 1, 2, 20
            if self.console and self.through_rom:
                with self.console.open("a") as f: f.write("## fu-boot: copying boot chain from ROM to DDR\nOpenSBI v1.9\n")
            if self.on_reboot: self.on_reboot()
        text = {"cat /proc/sys/kernel/random/boot_id": f"boot-{self.boot}\n", "cut -d. -f1 /proc/uptime": f"{self.uptime}\n"}.get(command, "")
        return subprocess.CompletedProcess(command, 0, text, "")
real_sleep, auth_phase.time.sleep = auth_phase.time.sleep, lambda seconds: None
def offline(name, target, linux=None, **settings):
    """One case of auth_phase.py on scripted stand-ins: (passed, detail)."""
    auth_phase.b = ScriptedBoard("auth-offline", target)
    auth_phase.m = authlib.Mailbox(auth_phase.b, poll=0)
    linux = linux or ScriptedLinux()
    auth_phase.lr.ssh, auth_phase.lr.ssh_up = linux.ssh, linux.up
    auth_phase.BOOT, auth_phase.SEED, auth_phase.STALE, auth_phase.RESET_AGE, auth_phase.TIMEOUT = True, True, False, 300.0, 5.0
    auth_phase.lr.NEED_UART, auth_phase.lr.UART_LOG, auth_phase.lr.TIMEOUT = linux.console is not None, linux.console or out / "no-console.log", 60
    for key, value in settings.items(): setattr(auth_phase, key, value)
    with open(os.devnull, "w") as quiet:                    # a failing case prints its traceback
        stdout, stderr, sys.stdout, sys.stderr = sys.stdout, sys.stderr, quiet, quiet
        try: passed = auth_phase.run(name)
        finally: sys.stdout, sys.stderr = stdout, stderr
    auth_phase.b.close()
    return passed, str(auth_phase.b.results[-1]["detail"])
def window(state, authenticated=False):
    box = MailboxModel(challenge, accept, state=state)
    box.authenticated = authenticated
    return box
passed, detail = offline("open", ScriptedTarget(0, seed=0))
check(passed and "BIST in 20 reads" in detail and "'mdbgauth': '0x8'" in detail, f"open: straps read back, seed in BIST: {detail}")
passed, detail = offline("open", ScriptedTarget(0, seed=0x80001234))
check(not passed and "switch 4 off?" in detail and "0x80001234" in detail, f"open with the entropy source on fails and says which switch: {detail[:120]}")
passed, detail = offline("open", ScriptedTarget(0, seed=None))
check(not passed and "seed cannot be read" in detail and "KARU_ZKR" in detail, "open on an image without seed says so")
passed, detail = offline("open", ScriptedTarget(0, seed=None), SEED=False)
check(passed and "not read (KARU_BOARD_AUTH_SEED=0)" in detail, "and passes without the seed check when told to leave it out")
passed, detail = offline("no-hold", ScriptedTarget(1, window("CLOSED")))
check(passed and "Linux answers, up for 40 s" in detail and "'examine_while_locked': 'refused'" in detail, f"no-hold: locked, REQUEST refused, Linux up: {detail}")
passed, detail = offline("no-hold", ScriptedTarget(1, window("CLOSED")), ScriptedLinux(uptime=5000))
check(not passed and "was the button pressed?" in detail, "no-hold with a Linux that has been up too long fails: no evidence of a boot after the reset")
passed, detail = offline("no-hold", ScriptedTarget(1, window("HOLD")))
check(not passed and "switch 3 is on" in detail, "no-hold with the hart held stops with the switch named")
passed, detail = offline("disabled", ScriptedTarget(2))
check(passed and "Linux answers" in detail, f"disabled: no mailbox, locked, Linux up: {detail}")
console = out / "auth-console.log"
console.write_text("earlier boot\n")
target = ScriptedTarget(1, window("CLOSED", authenticated=True))
target.csr[0x7c0] = 0x1019b                                 # mdbgauth as the simulated target shows it after a grant
passed, detail = offline("reboot", target, ScriptedLinux(console=console))
check(passed and "OpenSBI v1.9" in detail and "'mdbgauth': '0x1019b'" in detail, f"reboot after authenticate: grant kept, window closed, debugger works: {detail}")
passed, detail = offline("reboot", target, ScriptedLinux(console=console, through_rom=False))
check(not passed and "did not go through the boot ROM" in detail, "reboot without boot ROM banners on the console fails")
reopened = ScriptedLinux(console=console)
reopened.on_reboot = lambda: setattr(target.mailbox, "state", "HOLD")
passed, detail = offline("reboot", target, reopened)
check(not passed and "window still closed after the reboot" in detail, "negative control: a reboot that reopened the window fails the case")
target.mailbox.state = "CLOSED"
dropped = ScriptedLinux(console=console)
dropped.on_reboot = lambda: setattr(target.mailbox, "authenticated", False)
passed, detail = offline("reboot", target, dropped)
check(not passed and "is what it was before the reboot" in detail, "negative control: a reboot that dropped the grant fails the case")
passed, detail = offline("reboot-locked", ScriptedTarget(1, window("CLOSED")), ScriptedLinux(console=console))
check(passed and "OpenSBI v1.9" in detail, f"reboot-locked: still locked, window closed: {detail}")
passed, detail = offline("reboot", ScriptedTarget(1, window("CLOSED")), ScriptedLinux(console=console))
check(not passed and "run the authenticate case first" in detail, "reboot without a grant stops and says what it needs")
stale = ScriptedTarget(1, window("HOLD"))
stale.examined = True
passed, detail = offline("locked", stale)
check(not passed and "Restart it after the reset" in detail, "an OpenOCD that examined the target before is not trusted")
auth_phase.time.sleep = real_sleep

auth_dir = out / "auth-phase"
auth_dir.mkdir(exist_ok=True)
for value in ("", "unlock"):
    r = process("auth_phase.py", auth_dir, KARU_BOARD_AUTH_CASE=value)
    saved = json.loads((auth_dir / "auth-results.json").read_text())
    check(r.returncode == 1 and saved[-1]["name"] == "authentication: case selection" and all(name in saved[-1]["detail"] for name in auth_phase.CASES),
          f"auth_phase.py with KARU_BOARD_AUTH_CASE={value!r} runs nothing, lists the cases and exits 1")

# ---- as a process: the exit status a campaign driver sees ----
phase = ("import sys; sys.path.insert(0, %r)\nfrom boardlib import *\nb=Board('selftest-proc')\n"
         "b.case('x', lambda: b.require(%s, 'deliberate'))\nsys.exit(b.finish())\n")
for value, expected in (("True", 0), ("False", 1)):
    result = subprocess.run([sys.executable, "-c", phase % (str(SRC), value)], capture_output=True, text=True, timeout=60)
    check(result.returncode == expected, f"phase process exit status {expected} (got {result.returncode}: {result.stderr[-200:]})")

# ---- every script that runs cases ends through finish() ----
for path in scripts:
    text = path.read_text()
    if path.name in ("boardlib.py", "authlib.py", "test_boardlib.py", "rehearse.py", "autoexec_mutant.py"):
        continue
    check("sys.exit(" in text, f"{path.name} sets a process exit status")
    if "Board(" in text:
        check(".finish(" in text, f"{path.name} ends through Board.finish()")
        check(not text.rstrip().endswith("b.close()"), f"{path.name} does not end with a bare close()")

print(f"board harness self-test: PASS ({checks} checks, {len(scripts)} scripts)")
