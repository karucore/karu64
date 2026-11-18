#!/usr/bin/env python3
"""Rehearse board acceptance cases against the simulated JTAG target.

The board phases cannot run without the VCU118, but the harness only needs
an OpenOCD Tcl RPC port. This starts the Verilator JTAG model of the real
core (remote_bitbang), an OpenOCD connected to it (sim-server.cfg), and runs
the named cases of baremetal_phase.py unchanged. It is how a board case is
checked before a campaign, and, with an RTL mutant model, how it is shown to
fail when the feature it claims to test is broken.

The simulated target has its own map, which this script selects as
boardlib.py's image kind "sim": the scratch SRAM of rtl/karu_bootmap.vh,
64 KiB of RAM at 0x8000_0000 that is the same memory, and the reset vector
0x8000_0000. It has no other DDR and no UART, so only cases that need the
hart, the Debug Module and that memory can run here. --out must hold the
fixture built for this map (dbg/board.mk does that).

  --expect-fail TEXT   succeed only if every named case FAILS with TEXT in
                       its detail (negative control on a mutant model)
  --plusarg +NAME      passed to the simulator; selects a defect in a mutant
                       model (autoexec_mutant.py)
  --reset-pc ADDR      expect this reset vector instead of the target's
  --scratch ADDR       use this scratch SRAM base instead of the target's;
                       both are for negative controls of the "load" case
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, os, selectors, socket, subprocess, sys, time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--model", required=True, help="Vtb_jtag_core binary")
parser.add_argument("--openocd", default="openocd")
parser.add_argument("--out", required=True, help="artifact directory; must already hold payload.symbols")
parser.add_argument("--timeout", type=int, default=600, help="simulator wall-clock bound, seconds")
parser.add_argument("--expect-fail", default="")
parser.add_argument("--tag", default="rehearsal", help="prefix of this run's log files in --out")
parser.add_argument("--plusarg", action="append", default=[], help="simulator plusarg, e.g. +autoexec_dead")
parser.add_argument("--reset-pc", help="reset vector to expect in place of the simulated target's (negative control)")
parser.add_argument("--scratch", help="scratch SRAM base to use in place of the simulated target's (negative control)")
parser.add_argument("cases", nargs="+", help="function names in baremetal_phase.py")
args = parser.parse_args()

SRC = Path(__file__).resolve().parent
ROOT = SRC.parents[2]
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

server = subprocess.Popen([args.model, "0", str(args.timeout), *args.plusarg], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
openocd = None
status = 1
try:
    selector = selectors.DefaultSelector()
    selector.register(server.stdout, selectors.EVENT_READ)
    if not selector.select(15):
        raise RuntimeError("remote_bitbang listener did not start")
    greeting = server.stdout.readline()
    if not greeting.startswith("REMOTE_BITBANG_PORT="):
        raise RuntimeError(f"unexpected simulator greeting: {greeting}")
    rpc = f"127.0.0.1:{free_port()}"
    env = dict(os.environ, KARUDBG_RBB_PORT=greeting.strip().split("=", 1)[1], KARU_BOARD_RPC=rpc)
    log_path = out / f"{args.tag}-openocd.log"
    log = log_path.open("w")
    openocd = subprocess.Popen([args.openocd, "-f", str(SRC / "sim-server.cfg")], cwd=ROOT, env=env,
                               stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 60
    while "BOARD_ACCEPT_SERVER_READY" not in log_path.read_text():
        if openocd.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError(f"OpenOCD did not become ready; see {log_path}")
        time.sleep(0.1)

    # The phase module connects when imported; point it at this server first.
    os.environ["KARU_BOARD_RPC"] = rpc
    os.environ["KARU_BOARD_OUT"] = str(out)
    # The map of the simulated target, whatever the caller's environment
    # selects for a board: boardlib.py's image kind "sim". Its memory model
    # (test/dbg/karudbg_test_ram.sv) has the scratch SRAM where
    # rtl/karu_bootmap.vh puts it, and tb_jtag_core.v leaves the reset
    # vector at karudbg_top's default, 0x8000_0000.
    os.environ["KARU_BOARD_IMAGE"] = "sim"
    for name in ("KARU_BOARD_SCRATCH", "KARU_BOARD_SCRATCH_SIZE", "KARU_BOARD_RESET_PC"):
        os.environ.pop(name, None)
    if args.reset_pc:
        os.environ["KARU_BOARD_RESET_PC"] = args.reset_pc
    if args.scratch:
        os.environ["KARU_BOARD_SCRATCH"] = args.scratch
    sys.path.insert(0, str(SRC))
    import baremetal_phase as bm
    b = bm.b
    b.halt()
    for name in args.cases:
        b.case(name, getattr(bm, name))
    results = list(b.results)
    try:
        b.cmd("shutdown")
    except (RuntimeError, OSError):
        pass
    b.close()
    if args.expect_fail:
        ok = all(r["status"] == "FAIL" and args.expect_fail in str(r["detail"]) for r in results)
        print(("detected by the board case: " if ok else "NOT detected: ")
              + "; ".join(f"{r['name']}={r['status']} ({str(r['detail'])[:110]})" for r in results))
    else:
        ok = all(r["status"] == "PASS" for r in results)
        print(("PASS" if ok else "FAIL") + " board-case rehearsal: "
              + ", ".join(f"{r['name']}={r['status']} ({r['checks']} checks)" for r in results))
    status = 0 if ok and results else 1
finally:
    for proc in (openocd, server):
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
    if server.stdout:
        (out / f"{args.tag}-simulator.log").write_text(server.stdout.read())
sys.exit(status)
