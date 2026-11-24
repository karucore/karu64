#!/usr/bin/env python3
"""rtl/karu_entropy.v against its reference model, on the same symbols
(part of make entropy-test).

The model is test/dbg/board/entropy_health.py. Every case is a file of 4-bit
symbols, the lane of them that is the noise source (the strap lane_i) and a
mentropycfg value. test/tb_entropy_replay.sv feeds the file to the RTL and
writes down every failure with the status register after it, and a check
value over every word that seed delivered; the model does the same; the two
lists must be equal, line for line. The cases are generated here, with fixed
seeds:

  healthy-*    uniform symbols at the reset cutoffs, each lane as the source:
               no failure at all, and the words are that lane's bits, sixteen
               to a word, the first in bit 15 (computed here, without the
               model)
  faults-*     every kind of fault once per lag on the selected lane, far
               enough apart to be forgiven: both tests and every lag must
               show up as a cause, and the lane as the one that failed. In
               between, the same faults on the three other lanes at once,
               which must raise nothing
  strikes      faults close together: the configured one is fatal
  startup      a fault during the start-up test: fatal at once
  random-*     tight random cutoffs, faults on the selected lane and on the
               others, with seed accesses: many failures, strikes,
               forgiveness, alarms and words

Controls change one cutoff of the model, its lane or its word length, and
must make the lists differ. With --data FILE..., captures from a board (one
4-bit symbol per byte, as the NIST tools take them) are replayed too, with
lane --lane as the source, at the reset cutoffs and at tight ones. With
--restart FILE... restart data is replayed row by row (--rows symbols per
restart, 1000 by default), each row from reset: a row shorter than the
start-up test of 1024 samples says nothing about what follows it.

    python3 test/entropy_replay.py --out _build/entropy/replay [--lane N] [--data FILE...] [--restart FILE...]
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, random, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "test/dbg/board"))
import entropy_health as eh

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True)
parser.add_argument("--lane", type=int, default=0, choices=range(4), help="the lane of the --data and --restart files that is the noise source")
parser.add_argument("--data", nargs="*", default=[], help="board captures to replay as well: one 4-bit symbol per byte")
parser.add_argument("--restart", nargs="*", default=[], help="restart data to replay row by row: one 4-bit symbol per byte")
parser.add_argument("--rows", type=int, default=1000, help="symbols per restart in the --restart files")
args = parser.parse_args()
OUT = Path(args.out).resolve()
OUT.mkdir(parents=True, exist_ok=True)

RESET = dict(eh.cutoffs(0.75, 40), strikes=3, calm=24)             # the reset values of the RTL parameters
if (RESET["rct"], RESET["apt"]) != (55, 719):
    sys.exit(f"entropy replay: the model's default cutoffs {RESET} are not the reset values of rtl/karu_entropy.v")
GAP = 4096

def build():
    r = subprocess.run(["verilator", "--binary", "--timing", "-Wno-fatal", "--top-module", "tb_entropy_replay",
                        "-Mdir", str(OUT / "obj"), "-o", "tb", str(ROOT / "test/tb_entropy_replay.sv"),
                        str(ROOT / "rtl/karu_entropy.v")], capture_output=True, text=True)
    if r.returncode:
        sys.exit("entropy replay: build failed\n" + (r.stdout + r.stderr)[-2000:])

def model_lines(symbols, cut, poll, rows=0, lane=0):
    m, ev = eh.events(symbols, poll=poll, rows=rows, lane=lane, **cut)
    return ([f"{i} {s:016x}" for i, s in ev] + [f"end {len(symbols)} {m.stat():016x}", f"words {m.words} {m.acc:016x}"]), ev, m

def run(name, symbols, cut, poll=0, rows=0, lane=0):
    """One case through the RTL and the model. Returns (equal, events, model)."""
    f = OUT / f"{name}.bin"; o = OUT / f"{name}.rtl"
    f.write_bytes(bytes(symbols))
    cfg = eh.cfg_value(cut["rct"], cut["apt"], cut["strikes"], cut["calm"])
    r = subprocess.run([str(OUT / "obj" / "tb"), f"+file={f}", f"+out={o}", f"+cfg={cfg:x}", f"+poll={poll}", f"+rows={rows}", f"+lane={lane}"],
                       capture_output=True, text=True, timeout=900)
    if r.returncode or "entropy replay:" not in r.stdout:
        sys.exit(f"entropy replay: {name}: the bench failed\n" + (r.stdout + r.stderr)[-2000:])
    want, ev, m = model_lines(symbols, cut, poll, rows, lane)
    (OUT / f"{name}.model").write_text("\n".join(want) + "\n")
    got = o.read_text().split("\n")[:-1]
    CASES[name] = (symbols, cut, poll, got, lane)
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

def words_of(symbols, lane, count, first=eh.STARTUP, bits=16, msb_first=True):
    """The check value of the first `count` words that seed delivers when no
    test fails and no word is dropped: the bits of one lane after the start-up
    test, `bits` to a word. Written here from the symbols, not with the model."""
    stream = [(x >> lane) & 1 for x in symbols[first:]]
    acc = 0
    for w in range(count):
        chunk = stream[bits * w:bits * (w + 1)]
        if not chunk: break                                        # a control with longer words runs out of samples
        if not msb_first: chunk = chunk[::-1]
        acc = (acc * 0x100000001b3 + int("".join(map(str, chunk)), 2)) & eh.MASK64
    return f"words {count} {acc:016x}"

build()

# ---- healthy symbols at the reset cutoffs: no failure, and the words are the lane's bits ----
for lane in range(4):
    rng = random.Random(1 + lane)
    seq = healthy(rng, 120000)
    same, ev, m = run(f"healthy-{lane}", seq, RESET, poll=3, lane=lane)
    check(same and not ev and m.state == eh.RUN, f"healthy symbols, lane {lane} the source, at the reset cutoffs {RESET}: no failure, RTL and model agree")
    got = CASES[f"healthy-{lane}"][3][-1]
    check(m.words >= (len(seq) - eh.STARTUP) // 16 - 8 and got == words_of(seq, lane, m.words),
          f"lane {lane}: the {m.words} words that seed delivered are that lane's samples after the start-up test, sixteen to a word, the first in bit 15")
    check(all(got != words_of(seq, other, m.words) for other in range(4) if other != lane)
          and got != words_of(seq, lane, m.words, msb_first=False) and got != words_of(seq, lane, m.words, bits=15)
          and got != words_of(seq, lane, m.words, bits=17) and got != words_of(seq, lane, m.words, first=eh.STARTUP + 1),
          f"lane {lane}, control: not the bits of another lane, not in the other order, not 15 or 17 to a word, not from one sample later")

# ---- every kind of fault on the selected lane, forgiven in between ----
# The sequence is built against the model, so that each fault lasts exactly
# until it is detected and healthy symbols follow. Between the faults the
# same patterns sit on the three other lanes together, where they are not
# faults of the source.
PATTERNS = (lambda i: 0, lambda i: 1, lambda i: i & 1, lambda i: int(i % 3 == 0), lambda i: int(i % 4 < 2))   # stuck, periods 2, 3 and 4
for lane in range(4):
    cut = dict(RESET, strikes=7, calm=11)                          # 2048 clean samples forgive
    rng = random.Random(20 + lane)
    probe = eh.Health(lane=lane, **cut); seq = []
    others = [l for l in range(4) if l != lane]
    def feed(x):
        seq.append(x)
        return probe.step(x)
    def calm(n):
        for _ in range(n):
            if feed(rng.randrange(16)): sys.exit("entropy replay: healthy symbols failed while building the fault case")
    def fault(bit_at, window=0):
        while window and probe.win % window: calm(1)               # start on a window boundary
        for i in range(4 * eh.WIN):
            if feed((rng.randrange(16) & ~(1 << lane)) | (bit_at(i) << lane)): return calm(GAP)
        sys.exit("entropy replay: a fault of the fault case was not detected by the model")
    def elsewhere(bit_at, n):
        for i in range(n):
            b = bit_at(i)
            if feed((rng.randrange(2) << lane) | sum(b << l for l in others)):
                sys.exit("entropy replay: a pattern on the other lanes failed the model")
    calm(eh.STARTUP + GAP)
    for bit_at in PATTERNS:
        fault(bit_at)
        elsewhere(bit_at, 3 * eh.WIN)
    fault(lambda i: int(i % 16 != 5), eh.WIN)                      # fifteen ones in sixteen
    elsewhere(lambda i: int(i % 16 != 5), 3 * eh.WIN)
    same, ev, m = run(f"faults-{lane}", seq, cut, poll=5, lane=lane)
    stats = [s for _, s in ev]
    causes = lags = lanes = 0
    for s in stats:
        causes |= (s >> 8) & 15; lags |= (s >> 16) & 15; lanes |= (s >> 12) & 15
    check(same and len(ev) == len(PATTERNS) + 1, f"faults on lane {lane}: RTL and model agree on {len(ev)} failures, one per fault and none for the other lanes")
    check(causes == 0b1100 and lags == 15 and lanes == 1 << lane and all((s >> 20) & 15 == lane for s in stats),
          f"faults on lane {lane}: both tests (causes {causes:04b}), every lag ({lags:04b}), the lane reported is the selected one ({lanes:04b})")
    check(m.state != eh.DEAD and m.strikes == 0 and max((s >> 4) & 7 for s in stats) == 1 and m.words > 1000,
          f"faults on lane {lane}: all of them forgiven, never more than one strike held, and {m.words} words delivered around them")

# ---- strikes ----
for strikes in (1, 2, 3, 5):
    cut = dict(RESET, strikes=strikes, calm=11)
    rng = random.Random(3 + strikes)
    seq = healthy(rng, eh.STARTUP + 100)
    for _ in range(6):                                             # a stuck lane every 1500 symbols: never forgiven
        seq += lane_fault(rng, 0, lambda i: 1, cut["rct"]) + healthy(rng, 1500)
    same, ev, m = run(f"strikes{strikes}", seq, cut)
    check(same and m.state == eh.DEAD and len(ev) == max(strikes, 1) and m.strikes == max(strikes, 1),
          f"strikes = {strikes}: failure number {max(strikes, 1)} is fatal and counted ({len(ev)} failures, RTL and model agree)")
cut = dict(RESET, strikes=2, calm=11)
rng = random.Random(9)
seq = healthy(rng, eh.STARTUP + 100)
for _ in range(6):                                                 # the same, 3200 symbols apart: forgiven each time
    seq += lane_fault(rng, 0, lambda i: 1, cut["rct"]) + healthy(rng, 3200)
same, ev, m = run("forgiven", seq, cut)
check(same and m.state == eh.RUN and len(ev) == 6, "strikes = 2 with 2^11 clean samples between failures: six failures, none fatal")

# ---- a fault during the start-up test ----
rng = random.Random(10)
lead = healthy(rng, 300); lead[-1] &= ~1                           # the run of ones starts exactly here
seq = lead + lane_fault(rng, 0, lambda i: 1, RESET["rct"]) + healthy(rng, 3000)
same, ev, m = run("startup", seq, RESET)
check(same and m.state == eh.DEAD and len(ev) == 1 and ev[0][0] == 300 + RESET["rct"] - 1 and not m.alarm,
      "a failure during the start-up test is fatal at once, and is no alarm")

# ---- rows: every row starts from reset ----
rng = random.Random(11)
seq = []
for row in range(40):
    r = healthy(rng, 1000)
    if row % 7 == 3: r[200:200 + RESET["rct"]] = [x | 1 for x in r[200:200 + RESET["rct"]]]      # a stuck lane in the start-up test
    if row % 7 == 5: r[960:1000] = [x & ~1 for x in r[960:1000]]                                  # the start of one, cut off by the restart
    seq += r
same, ev, m = run("rows", seq, RESET, rows=1000)
check(same and [i // 1000 for i, _ in ev] == [3, 10, 17, 24, 31, 38] and all(s & 3 == eh.DEAD for _, s in ev) and m.state == eh.BIST,
      f"rows of 1000 with a restart before each: a fault is fatal in its own row only ({len(ev)} failures, RTL and model agree)")
joined = model_lines(seq, RESET, 0)[0]
check(joined != CASES["rows"][3], "control: the same symbols replayed as one stream do not agree with the RTL run in rows")
# the model's command line writes the same list: every row, indices counted over the file, one end line
cli = subprocess.run([sys.executable, str(ROOT / "test/dbg/board/entropy_health.py"), "replay", "--rows", "1000",
                      "--cfg", hex(eh.cfg_value(RESET["rct"], RESET["apt"], RESET["strikes"], RESET["calm"])),
                      "--events", str(OUT / "rows.cli"), str(OUT / "rows.bin")], capture_output=True, text=True)
check(cli.returncode == 0 and (OUT / "rows.cli").read_text().split("\n")[:-1] == CASES["rows"][3][:-1],
      "entropy_health.py replay --rows --events exports every row's failures, as the RTL lists them")
# ... and with --lane it takes that lane: the rows fail on lane 0 only
cli = subprocess.run([sys.executable, str(ROOT / "test/dbg/board/entropy_health.py"), "replay", "--rows", "1000", "--lane", "2",
                      "--cfg", hex(eh.cfg_value(RESET["rct"], RESET["apt"], RESET["strikes"], RESET["calm"])),
                      "--events", str(OUT / "rows-lane2.cli"), str(OUT / "rows.bin")], capture_output=True, text=True)
same, ev, m = run("rows-lane2", seq, RESET, rows=1000, lane=2)
check(cli.returncode == 0 and same and not ev and (OUT / "rows-lane2.cli").read_text().split("\n")[:-1] == CASES["rows-lane2"][3][:-1],
      "the same rows with lane 2 as the source: no failure in the RTL, the model, or entropy_health.py replay --lane 2")

# ---- random cutoffs and random faults, with seed accesses ----
# Faults a little shorter and a little longer than what a test needs, at
# random distances: some are missed by one, some come during a start-up test
# and are fatal, some add up to the fatal strike, some are forgiven. Faults
# on the other lanes are in the mix and must change nothing.
total = words = 0; ends = dict(alive=0, startup=0, retest=0, strikes=0)
N_RANDOM = 60
for seed in range(N_RANDOM):
    rng = random.Random(100 + seed)
    cut = dict(rct=rng.randrange(20, 40), apt=rng.randrange(600, 800),
               strikes=rng.choice([0, 1, 2, 3, 5, 7, 7, 7, 7, 7]), calm=rng.choice([9, 9, 9, 10, 11, 12]))
    poll = rng.choice([0, 1, 3, 7, 50, 1000]); lane = rng.randrange(4)
    seq = healthy(rng, rng.choice([200] + [eh.STARTUP + 50] * 5))
    while len(seq) < 40000:
        kind = rng.choice([0] * 8 + [1, 2, 2, 3]); where = lane if kind < 2 else rng.choice([l for l in range(4) if l != lane])
        if kind in (0, 2):                                         # a pattern of period 1 to 4, on the source or on another lane
            period = rng.randrange(1, 5); pattern = [rng.randrange(2) for _ in range(period)]
            seq += lane_fault(rng, where, lambda i: pattern[i % period], cut["rct"] + rng.randrange(-2, 4))
        else:                                                      # a bias
            seq += lane_fault(rng, where, lambda i: int(rng.random() < 0.8), rng.randrange(700, 1000))
        seq += healthy(rng, rng.choice([300] + [1100, 1500, 3000, 6000] * 4))
    same, ev, m = run(f"random-{seed}", seq, cut, poll, lane=lane)
    total += len(ev); words += m.words
    if m.state != eh.DEAD:                                  ends["alive"] += 1
    elif len(ev) == 1 and ev[0][0] < eh.STARTUP:            ends["startup"] += 1     # in the first start-up test
    elif len(ev) > 1 and ev[-1][0] - ev[-2][0] <= eh.STARTUP: ends["retest"] += 1    # in the retest after a failure
    else:                                                   ends["strikes"] += 1     # the fatal strike
    if not same: check(False, f"random-{seed}: {cut}, lane {lane}, a seed access every {poll}: RTL and model differ")
check(all(CASES[f"random-{i}"][3] == model_lines(*CASES[f"random-{i}"][:3], lane=CASES[f"random-{i}"][4])[0] for i in range(N_RANDOM)),
      f"{N_RANDOM} random cases, {total} failures, {words} words: RTL and model agree on every one")
check(total > 150 and words > 5000 and min(ends.values()) >= 3,
      f"the random cases have failures ({total}) and words ({words}) to compare and end in every way: {ends}")

# ---- control: a model that differs in one setting does not agree ----
for name, case in (("rct", "faults-0"), ("apt", "faults-0"), ("strikes", "strikes3"), ("calm", "forgiven")):
    symbols, cut, poll, got, lane = CASES[case]
    want = model_lines(symbols, dict(cut, **{name: cut[name] + 1}), poll, lane=lane)[0]
    check(got != want, f"control: a model with {name} + 1 does not agree with the RTL on the case {case}")
for case in ("faults-0", "faults-3", "healthy-1"):
    symbols, cut, poll, got, lane = CASES[case]
    check(all(got != model_lines(symbols, cut, poll, lane=other)[0] for other in range(4) if other != lane),
          f"control: a model with another lane as the source does not agree with the RTL on the case {case}")
symbols, cut, poll, got, lane = CASES["healthy-2"]
for bits in (15, 17):
    eh.WORD_BITS = bits
    want = model_lines(symbols, cut, poll, lane=lane)[0]
    eh.WORD_BITS = 16
    check(got[:-1] == want[:-1] and got[-1] != want[-1], f"control: a model with {bits} samples to a word agrees on the failures and not on the words")

# ---- captures from a board ----
TIGHT = dict(eh.cutoffs(0.8815, 20), strikes=7, calm=10)
def peaks(m):
    return f"largest counts: repetition {max(m.peak['rct_lag'])} (by lag {m.peak['rct_lag']}), proportion {m.peak['apt']}"
for f in map(Path, args.data):
    seq = list(f.read_bytes())
    if any(b > 15 for b in seq): sys.exit(f"entropy replay: {f} is not a file of 4-bit symbols")
    same, ev, m = run("data-" + f.stem, seq, RESET, lane=args.lane)
    check(same and not ev and m.state == eh.RUN,
          f"{f.name}: {len(seq)} consecutive samples of lane {args.lane} at the reset cutoffs: no failure, ends running ({peaks(m)})")
    same, ev, m = run("data-tight-" + f.stem, seq, TIGHT, poll=5, lane=args.lane)
    check(same, f"{f.name}: lane {args.lane} at tight cutoffs {TIGHT}: {len(ev)} failures, {m.words} words, RTL and model agree")
for f in map(Path, args.restart):
    seq = list(f.read_bytes())
    if any(b > 15 for b in seq) or len(seq) % args.rows: sys.exit(f"entropy replay: {f} is not rows of {args.rows} 4-bit symbols")
    same, ev, m = run("restart-" + f.stem, seq, RESET, rows=args.rows, lane=args.lane)
    check(same and not ev, f"{f.name}: {len(seq) // args.rows} restarts of {args.rows} samples of lane {args.lane} at the reset cutoffs, each from reset: no failure ({peaks(m)})"
          + ("; no row reaches the end of the start-up test" if args.rows < eh.STARTUP else ""))

bad = results.count(False)
print(f"entropy replay: {'PASS' if not bad else 'FAIL'} ({len(results) - bad} of {len(results)} checks)")
sys.exit(1 if bad else 0)
