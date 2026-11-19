#!/usr/bin/env python3
"""Rehearse auth_phase.py without a board.

This starts the Verilator JTAG model of the core with the authentication
block and the real window ROM (test/dbg/tb_jtag_core.v built with
KARU_DBG_AUTH and test/dbg/auth_rom as its island ROM), a pristine OpenOCD
connected to it over remote_bitbang (auth-sim-server.cfg), and runs the
named cases of auth_phase.py unchanged, with its own client (authlib.py).
The model's ROM is the TEST build or the SHA3 (0x04) build of window.c;
for the latter, KARU_BOARD_AUTH_KEY names the key file it was built with
(the public test_key.txt in simulation), and is passed to the phase as is.

What stands in for the board:

  switches   plusargs of the model: +auth_lc=<0..3>, +auth_hold=<0|1>,
             +auth_trng_opst=<0..3> (0 is a source that stays in BIST);
             the defaults are AUTH, held, entropy available
  the reset  the step "por": OpenOCD's SRST, which +por_on_srst makes the
             power-on reset of the whole model, then a JTAG re-init. The
             model is started with +por_on_srst and +auth_trng_lfsr, so that
             the nonce source runs on across resets as a physical one does
  time       the simulation ROM's window is 400,000 clock cycles, not 2^30,
             so no duration is checked
  Linux      absent: the boot evidence over SSH is not asked for, and the
             reboot cases cannot run here. The model has no seed CSR either

OpenOCD cannot be restarted within one model run, so a case after "por" may
meet an OpenOCD that examined the target earlier; the phase then leaves the
examine check out and says so (KARU_BOARD_AUTH_STALE).

  --expect-fail TEXT   succeed only if every case FAILS with TEXT in its
                       detail (negative control)
  --mutate NAME        break the client's TEST computation before running
                       (a SHA3 client is broken with a wrong key file):
                       key (one key bit), rotation (rotate right), mask
                       (granted mask left out), fold (challenge words 16..19
                       left out)
  --plusarg +NAME      passed to the model
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, os, selectors, socket, subprocess, sys, time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--model", required=True, help="Vtb_jtag_core built with KARU_DBG_AUTH and the window ROM")
parser.add_argument("--openocd", default="openocd")
parser.add_argument("--out", required=True, help="artifact directory")
parser.add_argument("--timeout", type=int, default=600, help="simulator wall-clock bound, seconds")
parser.add_argument("--tag", default="auth", help="prefix of this run's files in --out")
parser.add_argument("--plusarg", action="append", default=[])
parser.add_argument("--expect-fail", default="")
parser.add_argument("--mutate", choices=("key", "rotation", "mask", "fold"))
parser.add_argument("steps", nargs="+", help="case names of auth_phase.py, and 'por'")
args = parser.parse_args()

SRC = Path(__file__).resolve().parent
ROOT = SRC.parents[2]
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

server = subprocess.Popen([args.model, "0", str(args.timeout), "+por_on_srst", "+auth_trng_lfsr", *args.plusarg],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
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
    log_path = out / f"{args.tag}-openocd.log"
    log = log_path.open("w")
    openocd = subprocess.Popen([args.openocd, "-f", str(SRC / "auth-sim-server.cfg")], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                               env=dict(os.environ, KARUDBG_RBB_PORT=greeting.strip().split("=", 1)[1], KARU_BOARD_RPC=rpc))
    deadline = time.monotonic() + 60
    while "BOARD_ACCEPT_SERVER_READY" not in log_path.read_text():
        if openocd.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError(f"OpenOCD did not become ready; see {log_path}")
        time.sleep(0.1)

    # The phase connects when imported. Its settings for this target: no
    # Linux, no seed CSR, no real-time window, one OpenOCD for the whole run.
    history = out / f"{args.tag}-history.json"
    history.unlink(missing_ok=True)
    os.environ.update(KARU_BOARD_RPC=rpc, KARU_BOARD_OUT=str(out), KARU_BOARD_AUTH_HISTORY=str(history),
                      KARU_BOARD_AUTH_BOOT="0", KARU_BOARD_AUTH_SEED="0", KARU_BOARD_AUTH_STALE="1", KARU_BOARD_AUTH_KEEP_SERVER="1",
                      KARU_BOARD_AUTH_WINDOW_MIN="0", KARU_BOARD_AUTH_WINDOW_MAX="300", KARU_BOARD_AUTH_TIMEOUT="120")
    sys.path.insert(0, str(SRC))
    import authlib
    import auth_phase as phase
    b = phase.b
    phase.m.poll = 0                                    # simulated time passes only while the model is driven

    if args.mutate == "key":
        authlib.TEST_KEY = authlib.TEST_KEY[:7] + (authlib.TEST_KEY[7] ^ 1,)
    elif args.mutate == "rotation":
        authlib.rotl = lambda x, r: ((x >> r) | (x << (32 - r))) & 0xffffffff if r else x
    elif args.mutate == "mask":
        good = authlib.test_signature
        authlib.test_signature = lambda challenge, granted=1: good(challenge, 0)
    elif args.mutate == "fold":
        good_fold = authlib.test_signature
        authlib.test_signature = lambda challenge, granted=1: good_fold(list(challenge[:16]) + [0] * 4, granted)

    for step in args.steps:
        if step == "por":                               # the CPU reset button
            b.cmd("poll off"); b.cmd("adapter assert srst"); b.cmd("adapter deassert srst"); b.cmd("jtag arp_init")
        else:
            phase.run(step)
    results = list(b.results)
    try:
        b.cmd("shutdown")
    except (RuntimeError, OSError):
        pass
    b.close()
    names = "; ".join(f"{r['name'].split(': ')[-1]}={r['status']}" + (f" ({str(r['detail'])[:150]})" if r["status"] != "PASS" else f" ({r['checks']} checks)")
                      for r in results)
    if args.expect_fail:
        ok = all(r["status"] == "FAIL" and args.expect_fail in str(r["detail"]) for r in results)
        print(("refused as it must be: " if ok else "NOT refused: ") + names)
    else:
        ok = all(r["status"] == "PASS" for r in results)
        print(("PASS" if ok else "FAIL") + " authentication rehearsal: " + names)
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
