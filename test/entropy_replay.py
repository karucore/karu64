#!/usr/bin/env python3
"""rtl/karu_entropy.v against its reference model, on the same symbols
(part of make entropy-test).

The model is test/dbg/board/entropy_health.py. Every case is a file of 4-bit
symbols and a mentropycfg value. test/tb_entropy_replay.sv feeds the file to
the RTL and writes down every failure with the status register after it; the
model does the same; the two lists must be equal, line for line. The cases
are generated here, with fixed seeds:

  healthy      uniform symbols at the reset cutoffs: no failure at all
  faults       every kind of fault once per lane and lag, far enough apart to
               be forgiven: each test, lane and lag must show up as a cause
  strikes      faults close together: the configured one is fatal
  startup      a fault during the start-up test: fatal at once
  random-*     tight random cutoffs on biased symbols, with seed accesses:
               many failures, strikes, forgiveness and alarms

A control changes one cutoff of the model and must make the lists differ.
With --data FILE..., captures from a board (one 4-bit symbol per byte, as
the NIST tools take them) are replayed too, at the reset cutoffs and at tight
ones. With --restart FILE... restart data is replayed row by row (--rows
symbols per restart, 1000 by default), each row from reset: a row shorter
than the start-up test of 1024 symbols says nothing about what follows it.

    python3 test/entropy_replay.py --out _build/entropy/replay [--data FILE...] [--restart FILE...]
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, random, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "test/dbg/board"))
import entropy_health as eh

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True)
parser.add_argument("--data", nargs="*", default=[], help="board captures to replay as well: one 4-bit symbol per byte")
parser.add_argument("--restart", nargs="*", default=[], help="restart data to replay row by row: one 4-bit symbol per byte")
parser.add_argument("--rows", type=int, default=1000, help="symbols per restart in the --restart files")
args = parser.parse_args()
OUT = Path(args.out).resolve()
OUT.mkdir(parents=True, exist_ok=True)

RESET = dict(eh.cutoffs(3.0, 0.75, 40), strikes=3, calm=24)       # the reset values of the RTL parameters
if (RESET["srct"], RESET["sapt"], RESET["rct"], RESET["apt"]) != (15, 124, 55, 719):
    sys.exit(f"entropy replay: the model's default cutoffs {RESET} are not the reset values of rtl/karu_entropy.v")
GAP = 4096

def build():
    r = subprocess.run(["verilator", "--binary", "--timing", "-Wno-fatal", "--top-module", "tb_entropy_replay",
                        "-Mdir", str(OUT / "obj"), "-o", "tb", str(ROOT / "test/tb_entropy_replay.sv"),
                        str(ROOT / "rtl/karu_entropy.v")], capture_output=True, text=True)
    if r.returncode:
        sys.exit("entropy replay: build failed\n" + (r.stdout + r.stderr)[-2000:])

def model_lines(symbols, cut, poll, rows=0):
    m, ev = eh.events(symbols, poll=poll, rows=rows, **cut)
    return [f"{i} {s:016x}" for i, s in ev] + [f"end {len(symbols)} {m.stat():016x}"], ev, m

def run(name, symbols, cut, poll=0, rows=0):
    """One case through the RTL and the model. Returns (equal, events, model)."""
    f = OUT / f"{name}.bin"; o = OUT / f"{name}.rtl"
    f.write_bytes(bytes(symbols))
    cfg = eh.cfg_value(cut["srct"], cut["sapt"], cut["rct"], cut["apt"], cut["strikes"], cut["calm"])
    r = subprocess.run([str(OUT / "obj" / "tb"), f"+file={f}", f"+out={o}", f"+cfg={cfg:x}", f"+poll={poll}", f"+rows={rows}"],
                       capture_output=True, text=True, timeout=900)
    if r.returncode or "entropy replay:" not in r.stdout:
        sys.exit(f"entropy replay: {name}: the bench failed\n" + (r.stdout + r.stderr)[-2000:])
    want, ev, m = model_lines(symbols, cut, poll, rows)
    (OUT / f"{name}.model").write_text("\n".join(want) + "\n")
    got = o.read_text().split("\n")[:-1]
    CASES[name] = (symbols, cut, poll, got)
    return got == want, ev, m

CASES = {}
results = []
def check(ok, what):
    results.append(bool(ok))
    print(("ok   " if ok else "FAIL ") + what, flush=True)

def healthy(rng, n):
    return [rng.randrange(16) for _ in range(n)]

def lane_fault(rng, lane, bit_at, n):
    return [(x & ~(1 << lane)) | (bit_at(i) << lane) for i, x in enumerate(healthy(rng, n))]

build()

# ---- healthy symbols at the reset cutoffs ----
rng = random.Random(1)
same, ev, m = run("healthy", healthy(rng, 300000), RESET)
check(same and not ev and m.state == eh.RUN, f"healthy symbols at the reset cutoffs {RESET}: no failure, RTL and model agree")

# ---- every kind of fault, forgiven in between ----
# The sequence is built against the model, so that each fault lasts exactly
# until it is detected and healthy symbols follow.
cut = dict(RESET, strikes=7, calm=11)                              # 2048 clean symbols forgive
rng = random.Random(2)
probe = eh.Health(**cut); seq = []
def feed(x):
    seq.append(x)
    return probe.step(x)
def calm(n):
    for _ in range(n):
        if feed(rng.randrange(16)): sys.exit("entropy replay: healthy symbols failed while building the fault case")
def fault(symbol_at, window=0):
    while window and probe.win % window: calm(1)                   # start on a window boundary
    for i in range(4 * eh.LWIN):
        if feed(symbol_at(i)): return calm(GAP)
    sys.exit("entropy replay: a fault of the fault case was not detected by the model")
def on_lane(lane, bit_at):
    return lambda i: (rng.randrange(16) & ~(1 << lane)) | (bit_at(i) << lane)
calm(eh.STARTUP + GAP)
fault(lambda i: 9)                                                 # a stuck symbol
fault(lambda i: 9 if i % 4 != 3 else rng.choice([0, 3, 6, 12, 15]), eh.SWIN)    # a likely symbol, never four times in a row
for lane in range(4):
    for bit_at in (lambda i: 0, lambda i: 1, lambda i: i & 1, lambda i: int(i % 3 == 0), lambda i: int(i % 4 < 2)):
        fault(on_lane(lane, bit_at))                               # stuck, and periods 2, 3 and 4
    fault(on_lane(lane, lambda i: int(i % 16 != 5)), eh.LWIN)      # fifteen ones in sixteen
same, ev, m = run("faults", seq, cut)
stats = [s for _, s in ev]
causes = 0; lanes = {0: 0, 1: 0, 2: 0, 3: 0}; lags = 0
for s in stats:
    causes |= (s >> 8) & 15; lags |= (s >> 16) & 15
    for l in range(4):
        if s >> (12 + l) & 1: lanes[l] |= (s >> 8) & 0xc
check(same, f"faults: RTL and model agree on {len(ev)} failures")
check(causes == 15 and lags == 15 and all(v == 0xc for v in lanes.values()),
      f"faults: every test (causes {causes:04b}), every lag ({lags:04b}) and both lane tests on every lane fail at least once")
check(m.state != eh.DEAD and m.strikes == 0, "faults: all of them forgiven, the source is not dead at the end")
check(max((s >> 4) & 7 for s in stats) == 1, "faults: never more than one strike held")

# ---- strikes ----
for strikes in (1, 2, 3, 5):
    cut = dict(RESET, strikes=strikes, calm=11)
    rng = random.Random(3 + strikes)
    seq = healthy(rng, eh.STARTUP + 100)
    for _ in range(6):                                             # a stuck symbol every 1500 symbols: never forgiven
        seq += [5] * cut["srct"] + healthy(rng, 1500)
    same, ev, m = run(f"strikes{strikes}", seq, cut)
    check(same and m.state == eh.DEAD and len(ev) == max(strikes, 1) and m.strikes == max(strikes, 1),
          f"strikes = {strikes}: failure number {max(strikes, 1)} is fatal and counted ({len(ev)} failures, RTL and model agree)")
cut = dict(RESET, strikes=2, calm=11)
rng = random.Random(9)
seq = healthy(rng, eh.STARTUP + 100)
for _ in range(6):                                                 # the same, 3200 symbols apart: forgiven each time
    seq += [5] * cut["srct"] + healthy(rng, 3200)
same, ev, m = run("forgiven", seq, cut)
check(same and m.state == eh.RUN and len(ev) == 6, "strikes = 2 with 2^11 clean symbols between failures: six failures, none fatal")

# ---- a fault during the start-up test ----
rng = random.Random(10)
seq = healthy(rng, 300) + [3] * RESET["srct"] + healthy(rng, 3000)
same, ev, m = run("startup", seq, RESET)
check(same and m.state == eh.DEAD and len(ev) == 1 and ev[0][0] == 300 + RESET["srct"] - 1 and not m.alarm,
      "a failure during the start-up test is fatal at once, and is no alarm")

# ---- rows: every row starts from reset ----
rng = random.Random(11)
seq = []
for row in range(40):
    r = healthy(rng, 1000)
    if row % 7 == 3: r[200:200 + RESET["srct"]] = [row % 16] * RESET["srct"]      # a stuck symbol in the start-up test
    if row % 7 == 5: r[990:1000] = [5] * 10                                        # the start of one, cut off by the restart
    seq += r
same, ev, m = run("rows", seq, RESET, rows=1000)
check(same and [i // 1000 for i, _ in ev] == [3, 10, 17, 24, 31, 38] and all(s & 3 == eh.DEAD for _, s in ev) and m.state == eh.BIST,
      f"rows of 1000 with a restart before each: a fault is fatal in its own row only ({len(ev)} failures, RTL and model agree)")
joined = model_lines(seq, RESET, 0)[0]
check(joined != CASES["rows"][3], "control: the same symbols replayed as one stream do not agree with the RTL run in rows")
# the model's command line writes the same list: every row, indices counted over the file, one end line
cli = subprocess.run([sys.executable, str(ROOT / "test/dbg/board/entropy_health.py"), "replay", "--rows", "1000",
                      "--cfg", hex(eh.cfg_value(RESET["srct"], RESET["sapt"], RESET["rct"], RESET["apt"], RESET["strikes"], RESET["calm"])),
                      "--events", str(OUT / "rows.cli"), str(OUT / "rows.bin")], capture_output=True, text=True)
check(cli.returncode == 0 and (OUT / "rows.cli").read_text().split("\n")[:-1] == CASES["rows"][3],
      "entropy_health.py replay --rows --events exports every row's failures, as the RTL lists them")

# ---- random cutoffs and random faults, with seed accesses ----
# Faults a little shorter and a little longer than what a test needs, at
# random distances: some are missed by one, some come during a start-up test
# and are fatal, some add up to the fatal strike, some are forgiven.
total = 0; ends = dict(alive=0, startup=0, retest=0, strikes=0)
for seed in range(60):
    rng = random.Random(100 + seed)
    cut = dict(srct=rng.randrange(6, 12), sapt=rng.randrange(70, 120), rct=rng.randrange(20, 40),
               apt=rng.randrange(700, 800), strikes=rng.choice([0, 1, 2, 3, 5, 7, 7, 7, 7, 7]), calm=rng.choice([9, 9, 9, 10, 11, 12]))
    poll = rng.choice([0, 1, 3, 7, 50, 1000])
    seq = healthy(rng, rng.choice([200] + [eh.STARTUP + 50] * 5))
    while len(seq) < 40000:
        kind = rng.choice([0, 0, 0, 0, 2, 2, 2, 2, 2, 1, 3, 4]); lane = rng.randrange(4); v = rng.randrange(16)
        if kind == 0:   seq += [v] * (cut["srct"] + rng.randrange(-1, 2))
        elif kind == 1: seq += [v if rng.random() < 0.7 else rng.randrange(16) for _ in range(rng.randrange(100, 200))]
        elif kind == 2:
            period = rng.randrange(1, 5); pattern = [rng.randrange(2) for _ in range(period)]
            seq += lane_fault(rng, lane, lambda i: pattern[i % period], cut["rct"] + rng.randrange(-2, 4))
        elif kind == 3: seq += lane_fault(rng, lane, lambda i: int(rng.random() < 0.9), rng.randrange(700, 1000))
        seq += healthy(rng, rng.choice([300] + [1100, 1500, 3000, 6000] * 4))
    same, ev, m = run(f"random-{seed}", seq, cut, poll)
    total += len(ev)
    if m.state != eh.DEAD:                                  ends["alive"] += 1
    elif len(ev) == 1 and ev[0][0] < eh.STARTUP:            ends["startup"] += 1     # in the first start-up test
    elif len(ev) > 1 and ev[-1][0] - ev[-2][0] <= eh.STARTUP: ends["retest"] += 1    # in the retest after a failure
    else:                                                   ends["strikes"] += 1     # the fatal strike
    if not same: check(False, f"random-{seed}: {cut}, a seed access every {poll}: RTL and model differ")
check(all(CASES[f"random-{i}"][3] == model_lines(*CASES[f"random-{i}"][:3])[0] for i in range(60)),
      f"60 random cases, {total} failures: RTL and model agree on every one")
check(total > 150 and min(ends.values()) >= 3, f"the random cases have failures to compare ({total}) and end in every way: {ends}")

# ---- control: a model that differs by one in one setting does not agree ----
for name, case in (("srct", "faults"), ("sapt", "faults"), ("rct", "faults"), ("apt", "faults"),
                   ("strikes", "strikes3"), ("calm", "forgiven")):
    symbols, cut, poll, got = CASES[case]
    want = model_lines(symbols, dict(cut, **{name: cut[name] + 1}), poll)[0]
    check(got != want, f"control: a model with {name} + 1 does not agree with the RTL on the case {case}")

# ---- captures from a board ----
TIGHT = dict(eh.cutoffs(3.526340, 0.8815, 20), strikes=7, calm=10)
def peaks(m):
    return (f"largest counts: symbol repetition {m.peak['srct']}, symbol proportion {m.peak['sapt']}, "
            f"lane repetition {max(m.peak['rct_lag'])} (by lag {m.peak['rct_lag']}), lane proportion {max(m.peak['apt'])}")
for f in map(Path, args.data):
    seq = list(f.read_bytes())
    if any(b > 15 for b in seq): sys.exit(f"entropy replay: {f} is not a file of 4-bit symbols")
    same, ev, m = run("data-" + f.stem, seq, RESET)
    check(same and not ev and m.state == eh.RUN, f"{f.name}: {len(seq)} consecutive symbols at the reset cutoffs: no failure, ends running ({peaks(m)})")
    same, ev, m = run("data-tight-" + f.stem, seq, TIGHT, poll=5)
    check(same, f"{f.name}: at tight cutoffs {TIGHT}: {len(ev)} failures, RTL and model agree")
for f in map(Path, args.restart):
    seq = list(f.read_bytes())
    if any(b > 15 for b in seq) or len(seq) % args.rows: sys.exit(f"entropy replay: {f} is not rows of {args.rows} 4-bit symbols")
    same, ev, m = run("restart-" + f.stem, seq, RESET, rows=args.rows)
    check(same and not ev, f"{f.name}: {len(seq) // args.rows} restarts of {args.rows} symbols at the reset cutoffs, each from reset: no failure ({peaks(m)})"
          + ("; no row reaches the end of the start-up test" if args.rows < eh.STARTUP else ""))

bad = results.count(False)
print(f"entropy replay: {'PASS' if not bad else 'FAIL'} ({len(results) - bad} of {len(results)} checks)")
sys.exit(1 if bad else 0)
