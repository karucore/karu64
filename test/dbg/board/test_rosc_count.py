#!/usr/bin/env python3
"""Offline self-test of the meter capture (rosc_count.S, rosc_count.py); needs no board.

    make dbg-rosc-count-test

The payload under test is the file that goes to the board. A small driver in
front of it sets up the source and catches the payload's ebreak, since
neither target below has a debugger, then reads mnoise, mentropycfg, the
capture block and the meter itself. The same cases run on two targets.

Target A, a model in this file, needs no simulation (--offline runs it
alone). It executes the instructions that the payload and the driver use on
a memory image, with a cost in clocks for an instruction and for a bus
access close to the SoC's, and behind them mnoise, mentropycfg, mentropystat
and the registers at 0x1000_0840 as the headers of rtl/karu_entropy.v,
flow/fpga/karu_noise_burst.v and flow/fpga/karu_rosc_meter.v describe them,
with six synthetic rings. The model lists every record that the meter
handed out, with its clock and its place among the records that fell due,
so a capture is compared with exactly what was delivered, and a run that
joins records across a dropped one cannot pass.

Target B is the DDR SoC simulation with the entropy source, its meter and
its behavioural rings (fpga_ddr_tb, KARU_ZKR; make ddr-noise-burst-sim), so
that the payload reaches the registers the way it does on the board. Memory
is read back through the bench's +vec_out dump. The rings of the bench are
deterministic, and noise_model.py is their Python copy.

On both targets the records are also compared with the rings themselves,
which the test computes on its own from the target's ring model: the
records of a run must be the totals of all six rings and the lane bits at
clock edges that are period * every clocks apart, runs in order, at
distances that agree with the payload's stamps. Totals are compared as
differences from a run's first record, modulo 2^20. A ring that the capture
switched on (a reference ring, off outside test mode) starts from a phase
that the test does not know: its counts and its lane bit must fit one
phase, the same in every run.

A count is two ring periods: the meter's counters count each ring divided
by two, and a ring that has run since reset counts acc >> 1 of its periods
acc. With direct counting, a diagnostic mode, a count is one period; the
write that selects it restarts every ring, so that every ring then runs
from a phase of its own, and the runs are looked for near the place of a
divided capture with the same settings.

1. The payload on the target: records at several periods, spacings and ring
   masks, down to 64 clocks between records; the same in direct mode, where
   the run after the restart of the rings must start clean and the totals
   must be twice those of the divided capture; bursts of each ring's count
   (mode 1), its lower four bits and its upper four, in both ways of
   counting, with the ring's periods per clock rebuilt from the steps of
   the upper view; bursts of the reference bits (mode 2: lanes 0 and 1
   with the two reference rings, compared bit by bit with the rings, a ring
   that the capture switched on from one phase); on the model, a count that
   is 16 too high in one clock, which the meter must flag; losses, by
   records that come faster than the payload takes
   them and by the payload's `slow` parameter, with every run checked
   against the source and the limit on losses; the source left as it was
   found on every path; refusal of a locked source, of one already in test
   mode, of bad parameters, of an image without the capture block and
   (model) of one without the meter; a source that gives no samples; a
   store fault in the middle of a capture; the -DROSC_SIM build.
   Negative controls: ten mutants of the payload (test mode not left, a
   record taken without its valid flag, the loss flag ignored, the two
   words exchanged, the run's stamps wrong, no warm-up before the capture,
   the wrong ring in a count burst, the lane bits in place of the
   reference bits, pairs of periods counted when single ones were asked
   for, the lower bits of a count given for the upper) and tampered
   captures must each be caught by a named check; bursts of a count are
   not taken for reference bits, nor one view or unit of a count for the
   other.

2. rosc_count.py as a process against a stand-in for OpenOCD's Tcl RPC. The
   stand-in keeps the memory the phase writes, and on "resume" runs that
   memory image on the target, so the files the phase writes come from the
   real payload. Checked: the files, the sidecar and the exit status of a
   good capture, with the default ring masks in their order, the count
   unit, the meter's flags, and the capture in direct mode under its own
   name just before the divided one; a capture with a flagged count
   (model), which passes with a warning and is listed in the phase's
   summary and in its last line; that what the
   phase wrote unwraps to the rings' periods, through at least one wrap of
   a 20-bit total; runs split by losses; the count bursts in the burst file
   format; the reference bits as burst captures in the subdirectory
   refbits, and nowhere else; the default settings with every count scaled
   by one variable (model); refusal to analyse, of bad settings and of a
   missing payload,
   before anything is sent; an image without the capture block or without
   the meter; a source that is off; payload error statuses; a hart that
   never halts. Negative controls: a result block, a run table and a
   buffer altered behind the phase's back.
   The handoff: rosc_own.py, the analysis, runs as a process on the record
   files that the phase wrote. It has to read them, find the runs and the
   rings of the sidecar, and end without an error; nothing is asked of what
   it concludes; a run with a flagged count it has to set aside, and with
   --pair it has to take the two ways of counting together. Likewise
   getnoise_analyze.py on the files of refbits,
   which it has to read as burst captures at their periods, and
   entropy_claim.py --own on its analysis. The last needs scipy (a copy
   under _build/pylib is used): without it that step is not run, and the
   last line of this test says so.

What the model costs in clocks is what was measured on the bench on
2026-11-21: 56 clocks for a record, 33 for a poll that finds none, 51 for
the first fetch from a line of the instruction cache. No record is lost on
the bench from 58 clocks between records up.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, hashlib, json, os, re, selectors, socket, struct, subprocess, sys, threading, tkinter
from array import array
from pathlib import Path

SRC = Path(__file__).resolve().parent
ROOT = SRC.parents[2]
# The directory of noise_model.py, the Python copy of the bench's rings (target
# B only).
MODEL_DIR = SRC
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True, help="output directory; rosc_count.bin and rosc_count.symbols are expected in it")
parser.add_argument("--bench", default=str(ROOT / "_build/ddr-noise-burst/obj/Vfpga_ddr_tb"))
parser.add_argument("--xchain", default="riscv64-unknown-elf-")
parser.add_argument("--offline", action="store_true", help="target A only, no SoC simulation; the last line then does not report the whole test")
args = parser.parse_args()
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = 0

def check(cond, what):
    global checks
    checks += 1
    if not cond:
        raise SystemExit(f"FAIL rosc count self-test check {checks}: {what}")

# ---------------------------------------------------------------- builds ----
CC = [args.xchain + "gcc", "-march=rv64gc_zicsr", "-mabi=lp64d", "-nostdlib", "-static"]

def symbols(text):
    return {p[2]: int(p[0], 16) for line in text.splitlines() if len(p := line.split()) == 3}

def build(name, source, defines=(), text=0, entry="rosc_count"):
    """Assemble and link one file; returns (binary, symbols)."""
    elf = out / f"{name}.elf"
    subprocess.run(CC + [f"-D{d}" for d in defines] + [f"-Wl,-Ttext={text:#x},--no-relax,-e,{entry}", "-o", str(elf), str(source)],
                   check=True, capture_output=True, text=True)
    subprocess.run([args.xchain + "objcopy", "-O", "binary", "-j", ".text", str(elf), str(out / f"{name}.bin")], check=True)
    nm = subprocess.run([args.xchain + "nm", "-n", str(elf)], check=True, capture_output=True, text=True).stdout
    (out / f"{name}.symbols").write_text(nm)
    return (out / f"{name}.bin").read_bytes(), symbols(nm)

def mutant(name, *changes):
    """A build of rosc_count.S with some places changed: (old, new), each old unique in the file."""
    text = (SRC / "rosc_count.S").read_text()
    for old, new in changes:
        if text.count(old) != 1:
            raise SystemExit(f"FAIL rosc count self-test: mutant {name}: {old!r} is not unique in rosc_count.S")
        text = text.replace(old, new)
    (out / f"{name}.S").write_text(text)
    return build(name, out / f"{name}.S")

# The driver. It may preset mentropycfg and mnoise, then enters the payload.
# The payload has put mtvec back by the time it executes its ebreak, so the
# breakpoint exception arrives here.
DRIVER = r"""
	.option	norvc
	.section .text
	.globl	driver
driver:
	lla		t0, handler
	csrw	mtvec, t0
	lla		t2, d_entry
	ld		t0, 8(t2)
	beqz	t0, 1f
	csrw	0x7C9, t0
1:	ld		t0, 16(t2)
	beqz	t0, 2f
	csrw	0x7C8, t0
2:	ld		t0, 0(t2)
	jr		t0
	.balign	4
handler:
	lla		t2, d_entry
	csrr	t0, mcause
	sd		t0, 24(t2)
	csrr	t0, mepc
	sd		t0, 32(t2)
	csrr	t0, 0x7C8
	sd		t0, 40(t2)
	csrr	t0, 0x7C9
	sd		t0, 48(t2)
	li		t1, 0x10000840
	ld		t0, 0(t1)
	sd		t0, 56(t2)
	ld		t0, 8(t1)
	sd		t0, 64(t2)
	ld		t0, 24(t1)
	sd		t0, 72(t2)
	ld		t0, 40(t1)
	sd		t0, 80(t2)
	ld		t0, 48(t1)
	sd		t0, 88(t2)
	ld		t0, 56(t1)
	sd		t0, 96(t2)
	li		t0, 1
	li		t1, 0x80001000
	sd		t0, 0(t1)
3:	j		3b
	.balign	8
	.globl	d_entry
d_entry:	.dword 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
"""
BASE, SIZE = 0x80000000, 0x40000            # the part of the bench RAM that is loaded and dumped
LOAD = BASE + 0x2000                        # payload; the driver and the tohost page are below it
BUF = LOAD + 0x10000                        # where rosc_count.py puts the buffer
DIV = 8                                     # the bench's own sampling period (ZKR_SAMPLE_DIV)
LOG2W = 8                                   # and its capture block: 2^8 words, 4096 values per burst
# A configuration the bench does not have by itself, and that its limits
# accept: every field stricter than the reset value (calm 25, 2 strikes,
# proportion cutoff 700, repetition cutoff 37), k = 10.
PRE = (25 << 57) | (2 << 54) | (700 << 26) | (37 << 16) | 9
LOCK = 1 << 63
NBURST, MAGIC = 0x10000840, 0x4b4e4231
SYSMON_WORD = 0x0005999a4888a0f6
M20, M64 = (1 << 20) - 1, (1 << 64) - 1
LONG = 24                                   # records from which a run has one place in the source only
REF_RINGS = (0, 1, 4, 5)                    # the rings of a reference-bit sample, bit 0 first: lanes 0 and 1, references 0 and 1
FIELDS = ["status", "stored", "runs", "losses", "polls", "words", "nbctrl", "period_used", "mctrl", "cfg", "stat", "cfg_after",
          "stat_after", "noise_after", "nbctrl_after", "mctrl_after", "mcause", "mepc", "mctrl_end"]
DRIVEN = ["d_mcause", "d_mepc", "d_noise", "d_cfg", "d_nbctrl", "d_period", "d_nbdata", "d_mctrl", "d_data0", "d_data1"]
NPARAMS = 13                                # words of the payload's parameter block
WRITTEN = (1 << 29) - 1                     # the bits of the meter's control register that read back as written

(out / "driver.S").write_text(DRIVER)
driver_bin, driver_sym = build("driver", out / "driver.S", text=BASE, entry="driver")
if not (out / "rosc_count.symbols").exists():
    raise SystemExit(f"FAIL rosc count self-test: no rosc_count.symbols in {out}; run make dbg-rosc-count-test")
std_bin, SYM = (out / "rosc_count.bin").read_bytes(), symbols((out / "rosc_count.symbols").read_text())
sim_bin, sim_sym = build("rosc_count_sim", SRC / "rosc_count.S", ["ROSC_SIM"])
RUNS_MAX = (SYM["rosc_runs_end"] - SYM["rosc_runs"]) // 40
EBREAK = b"\x73\x00\x10\x00"
check(SYM["rosc_count"] == 0 and SYM["rosc_params"] == 8 and SYM["rosc_result"] == SYM["rosc_params"] + 8 * NPARAMS,
      "payload layout: entry first, then thirteen parameters, then the result block")
check(SYM["rosc_runs"] >= SYM["rosc_result"] + 8 * len(FIELDS) and SYM["rosc_runs"] % 8 == 0 and RUNS_MAX == 48 and len(FIELDS) == 19
      and len(std_bin) == SYM["rosc_runs_end"], "payload layout: the result block has nineteen words, and a run table of 48 entries ends the image")
check(len(std_bin) < 0x1000 and std_bin.count(EBREAK) == 1 and std_bin[SYM["rosc_stop"]:SYM["rosc_stop"] + 4] == EBREAK,
      "the board payload is small and stops at an ebreak, at rosc_stop")
check(EBREAK not in sim_bin and len(sim_bin) < 0x1000, "the ROSC_SIM build has no ebreak, and ends below the tohost page")
check(len(driver_bin) < 0x1000, "the driver ends below the tohost page")
loop = std_bin[SYM["poll"]:SYM["wait"]]
check(SYM["poll"] % 8 == 0 and SYM["wait"] - SYM["poll"] >= 32
      and [w & 0x7f for w in struct.unpack_from("<8I", loop)] == [0x03, 0x13, 0x63, 0x03, 0x23, 0x23, 0x13, 0x63]
      and struct.unpack_from("<I", loop, 28)[0] >> 31 == 1,
      "the record loop is eight instructions from an aligned address: two loads, two stores, a shift, an add, two branches, the last one back")
phase_text = (SRC / "rosc_count.py").read_text()
check(all(f"'{name}'" in phase_text for name in ("rosc_params", "rosc_result", "rosc_runs", "rosc_runs_end", "rosc_stop"))
      and re.search(r"FIELDS=\[([^\]]*)\]", phase_text).group(1).replace("\n", "").replace(" ", "").replace("'", "").split(",") == FIELDS,
      "the phase reads the payload's symbols and the result block in the payload's order")

def image(payload, params, precfg=PRE, prenoise=0, mem=None, entry=LOAD):
    """RAM image: driver, payload with its parameter block, driver words."""
    mem = bytearray(SIZE) if mem is None else bytearray(mem)
    mem[0:0x2000] = bytes(0x2000)
    mem[0:len(driver_bin)] = driver_bin
    if payload is not None:
        mem[LOAD - BASE:LOAD - BASE + len(payload)] = payload
    if params is not None:
        struct.pack_into(f"<{NPARAMS}Q", mem, LOAD - BASE + SYM["rosc_params"], *params)
    struct.pack_into("<3Q", mem, driver_sym["d_entry"] - BASE, entry, precfg, prenoise)
    return mem

def outcome(mem, sym=SYM, load=LOAD, driven=True):
    """Result block, run table, driver words and buffer of a finished run."""
    r = dict(zip(FIELDS, struct.unpack_from(f"<{len(FIELDS)}Q", mem, load - BASE + sym["rosc_result"])))
    d = dict(zip(DRIVEN, struct.unpack_from("<10Q", mem, driver_sym["d_entry"] - BASE + 24))) if driven else {}
    table = struct.unpack_from(f"<{5 * RUNS_MAX}Q", mem, load - BASE + sym["rosc_runs"])
    return dict(r, **d, table=[table[i:i + 5] for i in range(0, 5 * min(r["runs"], RUNS_MAX), 5)], buffer=bytes(mem[BUF - BASE:]))

IDLE = 100000
def params(period, every, mask, count, buf=BUF, size=None, idle=IDLE, losses=16, mode=0, ring=0, slow=0, direct=0, upper=0, words=1 << LOG2W):
    """The parameter block; the buffer is as large as what is wanted needs, unless a size is given."""
    need = count * (16 + 8 * words) if mode else 16 * count
    return [period - 1, every - 1, mask, count, buf, need if size is None else size, idle, losses, mode, ring, slow, direct, upper]

def unpack(buffer, count):
    """[(DATA0, DATA1)] of the first `count` records of a buffer."""
    w = struct.unpack_from(f"<{2 * count}Q", buffer)
    return list(zip(w[0::2], w[1::2]))

def fields(d0, d1):
    """(valid, loss and sequence number; totals of rings 0..5; lane bits) of a record."""
    return d0 >> 60, (d0 & M20, d0 >> 20 & M20, d0 >> 40 & M20, d1 & M20, d1 >> 20 & M20, d1 >> 40 & M20), d1 >> 60

def bursts_of(buffer, bursts, words):
    """[(start stamp, done stamp, values)] of the first `bursts` records of a mode 1 buffer."""
    size, result = 16 + 8 * words, []
    for i in range(bursts):
        t0, t1, *w = struct.unpack_from(f"<{2 + words}Q", buffer, i * size)
        result.append((t0, t1, bytes((x >> (4 * s)) & 15 for x in w for s in range(16))))
    return result

# ------------------------------------------------- the rings of a target ----
class Rings:
    """What the rings of a target do, as the test computes it: acc[r][t] is the
    number of periods of ring r after t clocks, with `frac` fractional bits,
    for a ring that has run since reset. The lane bit of ring r < 4 is 1 while
    the fraction is below `duty`. The meter counts whole periods from the
    clock at which a ring was switched on, and shows them halved (a count is
    two periods) unless it counts directly. So the count of a ring that has
    run since reset is acc >> (frac + 1), or acc >> frac with direct counting.
    A ring that the capture switched on, or restarted by changing the way of
    counting, runs from a phase of its own: its counts are those of
    (phi + acc[r][t]) for some phi below one count."""
    def __init__(self, frac, duty):
        self.frac, self.duty, self.acc, self.whole, self.shifted = frac, duty, [array("Q") for _ in range(6)], [[] for _ in range(6)], {}
    def upto(self, clocks):
        if len(self.acc[0]) < clocks:
            self.extend(clocks + 4096)
            self.shifted = {}
            for r in range(6):
                self.whole[r] = [a >> self.frac for a in self.acc[r]]
        return self
    def counts(self, r, below):
        """acc[r] without its `below` lowest bits: what a ring counts that has run since reset."""
        if (r, below) not in self.shifted:
            self.shifted[r, below] = [a >> below for a in self.acc[r]]
        return self.shifted[r, below]

class SyntheticRings(Rings):
    """The rings of target A: a rate per clock (20.12, 12.20, 8.28, 6.36, 20.18 and 20.08 periods, about the bench's
    with +rosc_turns=20) and a wobble of up to a quarter period, a hash of the clock, so that no two stretches of a
    ring look alike."""
    RATE = [1318584, 799539, 542638, 416809, 1322516, 1315963]
    X0 = [(0x13579bdf * (r + 1)) >> 16 & 0xffff for r in range(6)]
    def __init__(self):
        super().__init__(16, 0x8000)
    @classmethod
    def at(cls, r, t):
        x = (t * (0x9e3779b1 + 2 * r)) & 0xffffffff
        return cls.X0[r] + cls.RATE[r] * t + (((x ^ x >> 15) * 0x2c1b3c6d) >> 12 & 0x3fff)
    def extend(self, clocks):
        for r in range(6):
            self.acc[r].extend(self.at(r, t) for t in range(len(self.acc[r]), clocks))

class Source:
    """The rings of one run of a target, and which of them run outside test mode."""
    def __init__(self, rings, strap):
        self.rings, self.strap = rings, strap

def meet(xs, ys):
    """The intersection of two lists of intervals [lo, hi)."""
    return [(max(a, c), min(b, d)) for a, b in xs for c, d in ys if max(a, c) < min(b, d)]

def cyclic(lo, hi, size):
    """[lo, hi) modulo size as intervals within [0, size)."""
    lo, hi = lo % size, hi % size
    return [(lo, hi)] if lo < hi else [(0, hi), (lo, size)]

def phases(acc, steps, modulus, frac):
    """The phases phi, as intervals within one period, from which a ring counts steps[k] periods (modulo `modulus`)
    between acc[0] and acc[k]: the periods at acc[k] are (phi + acc[k]) >> frac."""
    one = 1 << frac
    n0, t0 = acc[0] >> frac, one - (acc[0] & (one - 1))             # phi >= t0: the first record is one period on
    lo_a, hi_a, lo_b, hi_b = 0, t0, t0, one
    for a, d in zip(acc[1:], steps[1:]):
        e, t = (d - (a >> frac) + n0) % modulus, one - (a & (one - 1))
        if e == 0: hi_a, lo_b = min(hi_a, t), max(lo_b, t)
        elif e == 1: lo_a, hi_b = max(lo_a, t), 0
        elif e == modulus - 1: hi_a, hi_b = 0, min(hi_b, t)
        else: return []
    return [(lo, hi) for lo, hi in ((lo_a, hi_a), (lo_b, hi_b)) if lo < hi]

def lane_fit(fit, f, bit, duty, one, span):
    """Of the phases in `fit`, below `span`, those from which a ring at a fraction f of a period reads `bit`."""
    base = cyclic(-f, duty - f, one) if bit else cyclic(duty - f, -f, one)
    return meet(fit, [(lo + k, hi + k) for k in range(0, span, one) for lo, hi in base])

def source_error(recs, runs, interval, mask, src, clocks, found=None, unit=2, hint=None):
    """None if every run is a stretch of the source: records `interval` clocks apart, each with the totals of the six
    rings and the lane bits of one clock edge, runs in order and at distances that agree with the payload's stamps.
    Else what is wrong. A total counts `unit` ring periods at a time. The runs are placed by the rings that are
    counted from the reset: those that run outside test mode, unless the capture counts directly, which restarts
    every ring. Where there is none, a run is looked for within 64 clocks of `hint` after its start stamp (the
    distance found for a capture with the same settings that could be placed). A ring that the capture switched on
    or restarted must fit one phase, the same in every run. `found` gets the clock of each run's first record (None:
    not placed), then the phases left for those rings."""
    rings = src.rings.upto(clocks + 64)
    one, acc, below = 1 << rings.frac, rings.acc, rings.frac + (unit == 2)
    span, since_reset = 1 << below, src.strap if unit == 2 else 0
    steady = [r for r in range(6) if mask >> r & since_reset >> r & 1]
    late = {r: [(0, span)] for r in range(6) if mask >> r & 1 and not since_reset >> r & 1}
    count = {r: rings.counts(r, below) for r in steady}
    after, anchor = 0, []
    def fitted(r, at, tot, lanes, old):
        """The phases of `old` from which ring r gives these totals and, if it is a lane, these bits."""
        a = [acc[r][t] for t in at]
        fit = meet(old, phases(a, [(t[r] - tot[0][r]) & M20 for t in tot], 1 << 20, below))
        for x, l in zip(a, lanes):
            if r >= 4 or not fit:
                break
            fit = lane_fit(fit, x & (one - 1), l >> r & 1, rings.duty, one, span)
        return fit
    for i, (start, n, c0, c1) in enumerate(runs):
        part = [fields(*x) for x in recs[start:start + n]]
        tot, lanes = [p[1] for p in part], [p[2] for p in part]
        for r in range(6):
            if not mask >> r & 1 and any(t[r] != tot[0][r] for t in tot):
                return f"run {i}: ring {r} is not in the mask, and its total changes"
            if not mask >> r & 1 and r < 4 and any((l ^ lanes[0]) >> r & 1 for l in lanes):
                return f"run {i}: ring {r} is not in the mask, and its lane bit changes"
        if n < 2:                                                             # one record: nothing to compare it with
            if found is not None: found.append(None)
            continue
        t0 = None
        if steady:
            want = {r: [(t[r] - tot[0][r]) & M20 for t in tot] for r in steady}
            def lanes_at(t):
                return all(((acc[r][t + k * interval] & (one - 1)) < rings.duty) == (l >> r & 1) for k, l in enumerate(lanes) for r in steady if r < 4)
            w, d1, totals_at = count[steady[0]], want[steady[0]][1], None
            for t in range(after, len(w) - (n - 1) * interval):
                if (w[t + interval] - w[t]) & M20 == d1 and all((count[r][t + k * interval] - count[r][t]) & M20 == want[r][k]
                                                                  for k in range(1, n) for r in steady):
                    if lanes_at(t):
                        t0 = t
                        break
                    totals_at = t if totals_at is None else totals_at
            if t0 is None and totals_at is None:
                return f"run {i}: its totals are not those of the rings at records {interval} clocks apart" + (f", after run {i - 1}" if i else "")
            if t0 is None:
                other = [s for s in range(-4, 5) if s and totals_at + s >= 0 and lanes_at(totals_at + s)]
                return f"run {i}: the lane bits are not the rings' outputs at the clock edge of the totals" + (f"; they are those of {other[0]:+d} clocks" if other else "")
            at = range(t0, t0 + n * interval, interval)
            if n >= LONG:
                for r in late:
                    late[r] = fitted(r, at, tot, lanes, late[r])
                    if not late[r]:
                        return f"run {i}: ring {r}, which the capture switched on, does not count as the source's ring does from any one phase"
                anchor.append(t0 - c0)
        elif hint is None:
            return "no ring of the mask is counted from the reset, and there is no place to look for the records"
        else:
            last = None
            for t in range(max(after, c0 + hint - 64), min(c0 + hint + 65, len(acc[0]) - (n - 1) * interval)):
                at, fits = range(t, t + n * interval, interval), {}
                for r in late:
                    fits[r] = fitted(r, at, tot, lanes, late[r])
                    if not fits[r]:
                        last = r
                        break
                else:
                    t0, late = t, fits
                    break
            if t0 is None:
                return (f"run {i}: ring {last}, which the capture restarted, does not count as the source's ring does from any one phase, "
                        f"at any clock within 64 of the one expected")
        if found is not None: found.append(t0)
        after = t0 + (n - 1) * interval + 1
    if anchor and max(anchor) - min(anchor) > 2 * interval + 64:
        return f"the runs are not as far apart in the source as by the payload's stamps: {anchor}"
    if found is not None: found.append(late)
    return None

def count_error(recs, period, ring, src, clocks, hint=None, found=None, unit=2, upper=False):
    """None if every burst is four bits of the count of the ring at consecutive samples `period` clocks apart, bursts
    in order and at distances that agree with the payload's stamps: of a count of `unit` periods, modulo 64, its lower
    four bits or, with `upper`, its upper four. A ring that is counted from the reset is found by its values. For a
    ring that the capture switched on or restarted, burst i is looked for within 16 clocks of hint[i] after its start
    stamp (the distances found for the bursts of a ring that could be found; the first burst of a capture starts
    later after its stamp than the others, its code being fetched for the first time), and all bursts must fit one
    phase. `found` gets the clock of each burst's first value less its stamp."""
    rings = src.rings.upto(clocks + 64)
    below = rings.frac + (unit == 2) + 2 * upper                # the bits of an accumulator below one step of a value
    acc, late, after, last = rings.acc[ring], [(0, 1 << below)], 0, None
    lines = {}
    for i, (c0, c1, burst) in enumerate(recs):
        n, t0 = len(burst), None
        if unit == 2 and src.strap >> ring & 1:
            steps = bytes((b - a) & 15 for a, b in zip(burst, burst[1:]))
            for r in range(period):
                if r not in lines:
                    line = rings.counts(ring, below)[r::period]
                    lines[r] = bytes((b - a) & 15 for a, b in zip(line, line[1:]))
                j = lines[r].find(steps, max(0, -(-(after - r) // period)))
                if j >= 0 and (t0 is None or r + j * period < t0):
                    t0 = r + j * period
        elif hint is None:
            return f"ring {ring} is not counted from the reset, and there is no burst of one that is to place it by"
        else:
            near = c0 + hint[min(i, len(hint) - 1)]
            for t in range(max(after, near - 16), min(near + 17, len(acc) - (n - 1) * period)):
                fit = meet(late, phases(acc[t:t + n * period:period], [(v - burst[0]) & 15 for v in burst], 16, below))
                if fit:
                    t0, late = t, fit
                    break
        if t0 is None:
            return f"burst {i} is not the count of ring {ring} at samples {period} clock(s) apart" + (f", after burst {i - 1}" if i else "")
        if last is not None and abs((t0 - last[0]) - (c0 - last[1])) > period + 64:
            return f"burst {i}: {t0 - last[0]} clocks after the one before in the source, {c0 - last[1]} by the payload's stamps"
        if found is not None: found.append(t0 - c0)
        last, after = (t0, c0), t0 + (n - 1) * period + 1
    return None

def refbits_error(recs, period, mask, src, clocks, found=None):
    """None if every burst is {reference 1, reference 0, lane 1, lane 0} of the source at consecutive samples `period`
    clocks apart, bursts in order and at distances that agree with the payload's stamps. The bursts are placed by the
    bits of the rings that run since reset. A ring that the capture switched on runs from a phase of its own, and its
    bit must fit one phase in all bursts; the bit of a ring outside the mask must not change. `found` gets the clock
    of each burst's first value."""
    rings = src.rings.upto(clocks + 64)
    one, acc = 1 << rings.frac, rings.acc
    steady = [i for i, r in enumerate(REF_RINGS) if mask >> r & src.strap >> r & 1]
    late = {i: [(0, one)] for i, r in enumerate(REF_RINGS) if mask >> r & 1 and not src.strap >> r & 1}
    still = [i for i, r in enumerate(REF_RINGS) if not mask >> r & 1]
    if not steady:
        return "neither lane 0 nor lane 1 runs outside test mode and is in the mask: nothing to place the bursts with"
    keep = sum(1 << i for i in steady)
    def stream(first):
        return bytes(sum(((acc[REF_RINGS[i]][t] & (one - 1)) < rings.duty) << i for i in steady) for t in range(first, len(acc[0]), period))
    lines, after, last, level = {}, 0, None, None
    for n, (c0, c1, burst) in enumerate(recs):
        if any(v >> 4 for v in burst):
            return f"burst {n}: a value above 15"
        for i in still:
            level = burst[0] if level is None else level
            if any((v ^ level) >> i & 1 for v in burst):
                return f"burst {n}: bit {i} is of ring {REF_RINGS[i]}, which is not in the mask, and it changes"
        want, t0 = bytes(v & keep for v in burst), None
        for r in range(period):
            if r not in lines:
                lines[r] = stream(r)
            j = lines[r].find(want, max(0, -(-(after - r) // period)))
            if j >= 0 and (t0 is None or r + j * period < t0):
                t0 = r + j * period
        if t0 is None:
            return f"burst {n}: bits {steady} are not rings {[REF_RINGS[i] for i in steady]} at samples {period} clock(s) apart" + (f", after burst {n - 1}" if n else "")
        for i in late:
            fit = late[i]
            for k, v in enumerate(burst):
                f = acc[REF_RINGS[i]][t0 + k * period] & (one - 1)
                fit = meet(fit, cyclic(-f, rings.duty - f, one) if v >> i & 1 else cyclic(rings.duty - f, -f, one))
                if not fit:
                    return (f"burst {n}: bit {i} is not ring {REF_RINGS[i]}, which the capture switched on, at the clock edges of the other bits "
                            f"from any one phase (value {k})")
            late[i] = fit
        if last is not None and abs((t0 - last[0]) - (c0 - last[1])) > period + 64:
            return f"burst {n}: {t0 - last[0]} clocks after the one before in the source, {c0 - last[1]} by the payload's stamps"
        if found is not None: found.append(t0)
        last, after = (t0, c0), t0 + (len(burst) - 1) * period + 1
    return None

# ------------------------------------------------ target A: the model ----
class Fault(Exception):
    def __init__(self, cause):
        self.cause = cause

class Target:
    """The entropy source as the payload meets it: mnoise, mentropycfg, mentropystat, the capture block and the meter,
    over six rings. A ring that is off holds its phase and has a count of zero; one that is switched on counts from
    zero. A count is two ring periods, the whole periods since the ring was switched on, halved and rounded down;
    with direct counting it is one period. A write that changes the way of counting stops every ring and starts those
    of the mask again three clocks later. `wrong` is (ring, clock): in that one clock the count of that ring is 16 too
    high, the one error that the decoding of the counter can make, and the meter flags it.
    `taken` lists what the meter handed out: (number among the records that fell due, clock, totals, lane bits).
    `started` lists the bursts: (clock of the first value, period, count source, ring, reference source, upper
    bits). `phi` has the phase from which each ring that was switched on runs, `restarts` the clocks at which the
    way of counting changed."""
    def __init__(self, rings, block=True, meter=True, off=False, strap=0x0f, wrong=None):
        self.rings, self.block, self.meter, self.en, self.strap, self.wrong = rings, block, meter, not off, strap, wrong
        self.test = self.lock = False
        self.cfg, self.stat, self.at, self.strobes, self.taken, self.started, self.phi, self.restarts = 0, 1, 0, 0, [], [], {}, []
        self.on, self.hold, self.since = [strap >> r & 1 for r in range(6)], [rings.at(r, 0) for r in range(6)], [0] * 6
        self.base, self.ref, self.direct = [0] * 6, [0] * 6, 0
        self.rest(0)
    def phase(self, r, t):
        return self.hold[r] + self.rings.at(r, max(t, self.since[r])) - self.rings.at(r, self.since[r])
    def count(self, r, t):
        periods = self.phase(r, t) >> self.rings.frac if self.on[r] else 0
        return (periods if self.direct else periods >> 1) + 16 * (self.wrong == (r, t))
    def total(self, r, t):
        return (self.base[r] + self.count(r, t) - self.ref[r]) & M20
    def bit(self, r, t):
        return self.on[r] and (self.phase(r, t) & ((1 << self.rings.frac) - 1)) < self.rings.duty
    def lanes(self, t):
        return sum(self.bit(r, t) << r for r in range(4))
    def refbits(self, t):
        return sum(self.bit(r, t) << i for i, r in enumerate(REF_RINGS))
    def gate(self, mask, now, direct=None):
        """The rings of the mask run from now on. With `direct` given the way of counting changes: every ring stops,
        and those of the mask start again three clocks later. A ring that stops has a count of zero from then on, and
        its total takes that one step, modulo 64."""
        one = 1 << self.rings.frac
        for r in range(6):
            if self.on[r] and (direct is not None or not mask >> r & 1):
                self.base[r], self.hold[r] = (self.total(r, now) + (-self.count(r, now) & 63)) & M20, self.phase(r, now) & (one - 1)
                self.ref[r] = self.on[r] = 0
        if direct is not None:
            self.direct = direct
            self.restarts.append(now)
        for r in range(6):
            if mask >> r & 1 and not self.on[r]:
                self.since[r], self.on[r] = now + (0 if direct is None else 3), 1
                self.phi[r] = self.hold[r] - self.rings.at(r, self.since[r])
        self.mask = mask
    def rest(self, now):
        """Entering and leaving test mode: the capture block and the meter at their reset values."""
        self.div, self.raw0 = DIV - 1, now
        self.busy = self.done = self.brk = self.loss = False
        self.idx = self.every = self.src = self.sel = self.refs = self.upper = self.cnt = self.seq = self.bad = self.flag = 0
        self.burst, self.held, self.rec = None, None, (0, [0] * 6, 0)
        phi = dict(self.phi)                                                # of the capture, not of what follows it
        self.gate(self.strap, now, 0 if self.direct else None)
        self.base, self.ref, self.phi = [0] * 6, [self.count(r, now) for r in range(6)], phi
    def sync(self, now):
        """Everything that happened up to this clock."""
        p = self.div + 1
        ka, kb = (self.at - self.raw0) // p, (now - self.raw0) // p
        if self.en and kb > ka and self.test and not self.lock and self.meter:
            due, cnt = divmod(self.cnt + kb - ka, self.every + 1)
            if due:
                t = self.raw0 + (ka + self.every + 1 - self.cnt) * p        # the sample of the first record that falls due
                if self.held is None:
                    self.rec = (self.seq, [self.total(r, t) for r in range(6)], self.lanes(t))
                    self.held = (self.strobes + 1, t) + self.rec[1:]
                    self.loss |= due > 1
                else:
                    self.loss = True
                self.strobes, self.seq = self.strobes + due, (self.seq + due) & 3
            self.cnt = cnt
        if self.wrong and self.at < self.wrong[1] <= now and self.test and not self.lock and self.meter and self.mask >> self.wrong[0] & 1:
            self.bad, self.flag = self.bad + 3, self.flag | 1 << self.wrong[0]     # that increment and the two after it do not fit
        if self.busy and now >= self.burst[0] + ((16 << LOG2W) - 1) * self.burst[1] + 2:
            self.busy, self.done = False, True
        self.at = now
    def read(self, reg, now):
        self.sync(now)
        allow = self.test and not self.lock
        if not self.block:
            return 0
        if reg == 0:
            return MAGIC << 32 | (LOG2W + 4) << 8 | self.brk << 6 | self.test << 5 | self.en << 4 | self.lock << 3 | allow << 2 | self.done << 1 | self.busy
        if reg == 1: return self.div
        if reg == 2: return self.idx
        if reg == 3:
            if not (allow and self.done):
                return 0
            first, p, src, sel, refs, upper = self.burst
            def value(t):                                                   # four bits of a count modulo 64, or four sampled bits
                if src:
                    return (self.count(sel, t) & 63) >> 2 if upper else self.count(sel, t) & 15
                return self.refbits(t) if refs else self.lanes(t)
            word = sum(value(t) << 4 * j for j, t in enumerate(range(first + 16 * self.idx * p, first + 16 * (self.idx + 1) * p, p)))
            self.idx = (self.idx + 1) & ((1 << LOG2W) - 1)
            return word
        if reg == 4: return SYSMON_WORD
        if not (allow and self.meter):
            return 0
        seq, tot, lanes = self.rec
        valid = self.held is not None
        if reg == 5:
            return (self.every | self.mask << 16 | self.src << 22 | self.sel << 23 | self.refs << 26 | self.upper << 27 | self.direct << 28
                    | self.strap << 32 | valid << 40 | self.loss << 41 | self.flag << 42 | min(self.bad, 65535) << 48)
        if reg == 6:
            return valid << 63 | self.loss << 62 | seq << 60 | tot[2] << 40 | tot[1] << 20 | tot[0]
        if valid:
            self.taken.append(self.held)
            self.held = None
        return lanes << 60 | tot[5] << 40 | tot[4] << 20 | tot[3]
    def write(self, reg, v, now):
        self.sync(now)
        if not (self.block and self.test and not self.lock):
            return
        if reg == 0 and v & 1 and not self.busy:
            p = self.div + 1
            self.done, self.busy, self.brk = False, self.en, not self.en
            self.burst = (self.raw0 + ((now - self.raw0) // p + 1) * p, p, self.src, self.sel if self.src and self.sel < 6 else 0, self.refs, self.upper)
            self.started.append(self.burst)
        elif reg == 1 and not self.busy:
            self.div, self.raw0 = v & 0xff, now
        elif reg == 2:
            self.idx = v & ((1 << LOG2W) - 1)
        elif reg == 5 and self.meter:
            self.every, self.src, self.sel, self.refs, self.upper = v & 0xffff, v >> 22 & 1, v >> 23 & 7, v >> 26 & 1, v >> 27 & 1
            if v >> 31 & 1:
                self.cnt, self.seq, self.held, self.loss, self.rec, self.bad, self.flag = 0, 0, None, False, (0, [0] * 6, 0), 0, 0
            if v >> 16 & 0x3f != self.mask or v >> 28 & 1 != self.direct:  # rings are switched: the loss flag, even with a start
                self.gate(v >> 16 & 0x3f, now, None if v >> 28 & 1 == self.direct else v >> 28 & 1)
                self.loss = True
    def csr(self, n, v, now):
        """Read (v is None) or write mnoise, mentropycfg or mentropystat."""
        self.sync(now)
        if v is None:
            return {0x7c8: self.test << 31 or 1, 0x7c9: self.cfg | self.lock << 63, 0x7ca: self.stat}[n]
        if n == 0x7c8 and not self.lock and bool(v >> 31 & 1) != self.test:
            self.test, self.stat = not self.test, 0
            self.rest(now)
        if n == 0x7c9 and not self.lock:
            self.cfg, self.lock = v & ~LOCK, bool(v >> 63)

def sx(v, bits):
    return v - (1 << bits) if v >> (bits - 1) & 1 else v

class Hart:
    """RV64 as far as the payload and the driver go, on a RAM image at BASE. An instruction costs STEP clocks and an
    access to a register or to the RAM BUS more; the first instruction from a line of 64 bytes costs COLD more, as a
    miss of the instruction cache does. With these a record costs the payload 56 clocks and a poll that finds none
    34. Measured on the bench, 2026-11-21: 56 and 33, and 51 for a line.
    Runs until the HTIF word is written; returns its code, or None if that does not happen."""
    STEP, BUS, COLD = 4, 6, 51
    def __init__(self, mem, target):
        self.mem, self.target, self.x, self.pc, self.clock, self.lines = bytearray(mem), target, [0] * 32, BASE, 64, set()
        self.csrs = {0x300: 0xa00001800, 0x305: 0, 0x341: 0, 0x342: 0}
    def bus(self, addr, value=None):
        self.clock += self.BUS
        off = addr - BASE
        if 0 <= off <= SIZE - 8 and not addr & 7:
            if value is None:
                return int.from_bytes(self.mem[off:off + 8], "little")
            self.mem[off:off + 8] = value.to_bytes(8, "little")
            if off == 0x1000 and value & 1:
                raise StopIteration
            return None
        if 0x10000800 <= addr < 0x10001000 and not addr & 7:               # the system-control block
            reg = (addr - NBURST) >> 3
            if 0 <= reg < 8:
                return self.target.read(reg, self.clock) if value is None else self.target.write(reg, value, self.clock)
            return 0 if value is None else None
        raise Fault(5 if value is None else 7)
    def csr(self, n, value=None):
        if n in self.csrs:
            if value is None: return self.csrs[n]
            self.csrs[n] = value
        elif n == 0xb00 and value is None:
            return self.clock
        elif n in (0x7c8, 0x7c9, 0x7ca):
            return self.target.csr(n, value, self.clock)
        else:
            raise Fault(2)
    def run(self, limit=3000000):
        x, mem = self.x, self.mem
        try:
            for _ in range(limit):
                pc = self.pc
                i = int.from_bytes(mem[pc - BASE:pc - BASE + 4], "little")
                self.clock += self.STEP
                if pc >> 6 not in self.lines:
                    self.lines.add(pc >> 6)
                    self.clock += self.COLD
                op, rd, f3, a, b, imm = i & 0x7f, i >> 7 & 31, i >> 12 & 7, x[i >> 15 & 31], x[i >> 20 & 31], sx(i >> 20, 12)
                sh, res, nxt = i >> 20 & 63, None, pc + 4
                try:
                    if op == 0x13:
                        res = (a + imm, a << sh, sx(a, 64) < imm, a < imm & M64, a ^ imm, (sx(a, 64) if i >> 30 & 1 else a) >> sh, a | imm, a & imm)[f3]
                    elif op == 0x33 and i >> 25 == 1:
                        res = {0: a * b, 5: a // b if b else M64, 7: a % b if b else a}[f3]
                    elif op == 0x33:
                        res = (a - b if i >> 30 & 1 else a + b, a << (b & 63), sx(a, 64) < sx(b, 64), a < b, a ^ b,
                               (sx(a, 64) if i >> 30 & 1 else a) >> (b & 63), a | b, a & b)[f3]
                    elif op == 0x1b and f3 == 0:
                        res = sx((a + imm) & 0xffffffff, 32)
                    elif op == 0x03 and f3 == 3:
                        res = self.bus((a + imm) & M64)
                    elif op == 0x23 and f3 == 3:
                        self.bus((a + sx(i >> 25 << 5 | rd, 12)) & M64, b)
                    elif op == 0x63:
                        if (a == b, a != b, None, None, sx(a, 64) < sx(b, 64), sx(a, 64) >= sx(b, 64), a < b, a >= b)[f3]:
                            nxt = pc + sx(i >> 31 << 12 | (i >> 7 & 1) << 11 | (i >> 25 & 63) << 5 | (i >> 8 & 15) << 1, 13)
                    elif op == 0x37:
                        res = sx(i & 0xfffff000, 32)
                    elif op == 0x17:
                        res = pc + sx(i & 0xfffff000, 32)
                    elif op == 0x6f:
                        res, nxt = pc + 4, pc + sx(i >> 31 << 20 | (i >> 12 & 255) << 12 | (i >> 20 & 1) << 11 | (i >> 21 & 1023) << 1, 21)
                    elif op == 0x67:
                        res, nxt = pc + 4, (a + imm) & M64 & ~1
                    elif op == 0x73 and f3:
                        src = i >> 15 & 31 if f3 & 4 else a
                        res = self.csr(i >> 20)
                        if f3 & 3 == 1: self.csr(i >> 20, src)
                        elif i >> 15 & 31: self.csr(i >> 20, res | src if f3 & 3 == 2 else res & ~src)
                    else:
                        raise Fault(3 if i == 0x00100073 else 2)
                except Fault as f:
                    self.csrs[0x341], self.csrs[0x342], res, nxt = pc, f.cause, None, self.csrs[0x305] & ~3
                if res is not None and rd:
                    x[rd] = int(res) & M64
                self.pc = nxt
        except StopIteration:
            return int.from_bytes(mem[0x1000:0x1008], "little") >> 1
        return None

class Model:
    """Target A."""
    name, exact, rings, strap = "model", True, SyntheticRings(), 0x0f
    def execute(self, tag, mem, strap=None, **options):
        self.last = Target(self.rings, strap=self.strap if strap is None else strap, **options)
        hart = Hart(mem, self.last)
        return hart.run(), hart.clock, bytes(hart.mem)
    def source(self, o):
        return Source(self.rings, o["mctrl"] >> 32 & 0x3f)                  # the rings that run outside test mode, as the meter says

# ------------------------------------------ target B: the SoC simulation ----
bench_runs = 0
def simulate(tag, mem, plusargs=(), max_cycles=4000000):
    """Run a RAM image on the bench. Returns (HTIF exit code or None, final cycle, RAM after)."""
    global bench_runs
    bench_runs += 1
    words = struct.unpack(f"<{SIZE // 8}Q", mem)
    (out / f"{tag}.hex").write_text("".join(f"{w:016x}\n" for w in words))
    dump = out / f"{tag}.dump"
    dump.unlink(missing_ok=True)
    r = subprocess.run([args.bench, f"+hex={out / tag}.hex", "+tohost=1000", f"+max_cycles={max_cycles}", f"+vec_out={dump}",
                        "+vec_out_start=0", f"+vec_out_words={SIZE // 8}", *plusargs], capture_output=True, text=True, timeout=1200)
    (out / f"{tag}.log").write_text(r.stdout + r.stderr)
    done = re.search(r"\[HTIF\] exit (\d+) @ cyc=(\d+)", r.stdout)
    if not done or not dump.exists() or re.search(r"ASSERT|FATAL", r.stdout + r.stderr):
        return None, 0, bytes(mem)
    after = [int(line, 16) for line in dump.read_text().split() if not line.startswith("/")]
    return int(done.group(1)), int(done.group(2)), struct.pack(f"<{len(after)}Q", *after)

class ModelRings(Rings):
    """The rings of the bench, from noise_model.py: the model is stepped a clock at a time and its accumulators
    (whole periods above 32 bits of phase) are kept. The model's own counts, lane bits and reference bits (counts(),
    upto() and refs()) must agree with them."""
    def __init__(self, noise_model, **settings):
        self.model = noise_model.NoiseModel(counts=True, **settings)
        super().__init__(32, self.model.duty)
    def extend(self, clocks):
        for t in range(len(self.acc[0]), clocks):
            self.model.upto(t)
            for r in range(6):
                self.acc[r].append(self.model.acc[r])
    def agrees(self, clocks):
        self.upto(clocks)
        counts, lanes, refs = self.model.counts(clocks), self.model.upto(clocks), self.model.refs(clocks)
        return all(counts[6 * t + r] == self.acc[r][t] >> self.model.unit & 63 for t in range(clocks) for r in range(6)) and \
            all(lanes[t] == sum(((self.acc[r][t] & 0xffffffff) < self.duty) << r for r in range(4)) for t in range(clocks)) and \
            all(refs[t] == sum(((self.acc[4 + r][t] & 0xffffffff) < self.duty) << r for r in range(2)) for t in range(clocks))

class Simulation:
    """Target B. Its rings run at the rate of real ones (+rosc_turns) with the known jitter of the characterisation
    model (+rosc_jitter); the same settings go to the Python copy."""
    name, exact, strap = "simulation", False, None
    SETTINGS = dict(jitter=10, turns=20)
    def __init__(self):
        sys.path.insert(0, str(MODEL_DIR))
        import noise_model
        if not hasattr(noise_model.NoiseModel, "counts"):
            raise SystemExit(f"FAIL rosc count self-test: noise_model.py in {MODEL_DIR} has no ring counts; see MODEL_DIR in this file")
        self.rings = ModelRings(noise_model, **self.SETTINGS)
        self.plusargs = [f"+rosc_{name}={value}" for name, value in self.SETTINGS.items()]
    def execute(self, tag, mem, off=False, block=True, max_cycles=4000000):
        code, clocks, after = simulate(tag, mem, self.plusargs + ["+zkr_en=0"] * off + ["+zkr_burst=0"] * (not block), max_cycles)
        return code, clocks, after
    def source(self, o):
        return Source(self.rings, o["mctrl"] >> 32 & 0x3f)                  # the rings that run outside test mode, as the meter says

# ------------------------------------------------------------- the cases ----
def problems(o, be, clocks, period, every, mask, count, pre=PRE, stop=None, slow=0, found=None, direct=0, hint=None, flagged=0):
    """Everything that is wrong with a capture of records that should have succeeded. `flagged` is what the meter's
    flags and its count of flagged clocks, bits [63:42] of its control register, should be at the end of the run."""
    bad, interval, word = [], period * every, every - 1 | mask << 16 | direct << 28
    stop = LOAD + SYM["rosc_stop"] if stop is None else stop
    if (o["d_mcause"], o["d_mepc"]) != (3, stop): bad.append("did not stop at its ebreak")
    if o["status"] != 0: bad.append(f"status {o['status']}")
    if o["stored"] != count: bad.append("stored count")
    if o["nbctrl"] >> 32 != MAGIC: bad.append("status register at entry")
    if o["period_used"] != period: bad.append("period read back")
    if o["mctrl"] & WRITTEN != word: bad.append("control register read back")
    if not (o["cfg"] == o["cfg_after"] == o["d_cfg"] == pre): bad.append("mentropycfg changed")
    if o["noise_after"] != 1 or o["d_noise"] != 1: bad.append("test mode not left")
    if o["nbctrl_after"] != (MAGIC << 32 | o["nbctrl"] & 0xff00 | 0x10) or o["d_nbctrl"] != o["nbctrl_after"]: bad.append("capture block not at rest afterwards")
    if o["d_period"] != DIV - 1: bad.append("sampling period not back at the build's")
    if o["mctrl_after"] or o["d_mctrl"] or o["d_data0"] or o["d_data1"] or o["d_nbdata"]: bad.append("data readable after test mode")
    runs = o["table"]
    if not 1 <= len(runs) <= o["losses"] + 1: bad.append("runs against losses")
    if [r[0] for r in runs] + [o["stored"]] != [0] + [r[0] + r[1] for r in runs] or any(r[1] == 0 for r in runs):
        return bad + ["the run table does not cover the records"]
    if any(o["buffer"][16 * count:16 * count + 64]): bad.append("wrote past the last record")
    recs = unpack(o["buffer"], o["stored"])
    for i, (start, n, c0, c1, ctrl) in enumerate(runs):
        flags = [d0 >> 60 for d0, _ in recs[start:start + n]]
        if any(f & 12 != 8 for f in flags): bad.append(f"run {i}: a record without the valid flag or with the loss flag")
        elif flags != [8 | k & 3 for k in range(n)]: bad.append(f"run {i}: sequence numbers do not count from 0")
        if not (n - 1) * interval <= c1 - c0 <= (n + 3) * interval + 4096 + 16 * slow * (n // 64 + 1):
            bad.append(f"run {i}: stamps {c1 - c0} clocks apart for {n} records")
        if i and c0 < runs[i - 1][3]: bad.append(f"run {i} starts before the one before it ended")
        if ctrl & WRITTEN != word: bad.append(f"run {i}: control register at its end")
        if ctrl >> 42 != flagged: bad.append(f"run {i}: the meter flagged a count: {ctrl >> 48} clock(s), rings {ctrl >> 42 & 63:#04x}")
    if runs and o["mctrl_end"] & ~(3 << 40) != runs[-1][4] & ~(3 << 40): bad.append("control register before test mode was left")
    err = source_error(recs, [r[:4] for r in runs], interval, mask, be.source(o), clocks, found, 1 if direct else 2, hint)
    if err: bad.append("records are not the source's: " + err)
    return bad

def advance(o, count):
    """Of the first run of a capture, which is all of it: what each ring's total advanced by, unwrapped."""
    tot = [fields(*x)[1] for x in unpack(o["buffer"], count)]
    return [sum((b[r] - a[r]) & M20 for a, b in zip(tot, tot[1:])) for r in range(6)]

def kept(target, stored):
    """Model only: what the meter handed out for the capture itself. Before it come the records of the warm-up,
    which the payload takes and does not keep: two, and one more for each try that a loss ended. None if there
    are more of those than the payload's four tries allow."""
    extra = len(target.taken) - stored
    return target.taken[extra:] if 2 <= extra <= 5 else None

def delivered_error(o, target):
    """Model only: None if the buffer holds exactly the records that the meter handed out after the warm-up, each
    run a stretch of records that fell due one after the other, and no two runs that could have been one."""
    recs, taken = [fields(*x)[1:] for x in unpack(o["buffer"], o["stored"])], kept(target, o["stored"])
    if taken is None or recs != [(tuple(tot), lanes) for _, _, tot, lanes in taken]:
        return "the buffer is not the records that the meter handed out after the warm-up, in order"
    for i, (start, n, c0, c1, _) in enumerate(o["table"]):
        due = [taken[k][0] for k in range(start, start + n)]
        if due != list(range(due[0], due[0] + n)):
            return f"run {i} joins records across one that the meter dropped"
        if i and due[0] <= taken[start - 1][0] + 1:
            return f"runs {i - 1} and {i} were split without a dropped record between them"
        if not (c0 < taken[start][1] and taken[start + n - 1][1] < c1):
            return f"run {i}: its stamps are not around its records"
    return None

def burst_problems(o, be, clocks, period, ring, mask, bursts, pre=PRE, stop=None, hint=None, found=None, direct=0, upper=0):
    """Everything that is wrong with a capture of bursts that should have succeeded: of the count of a ring, its lower
    or its upper four bits, or, with ring None, of the reference bits."""
    bad = []
    stop = LOAD + SYM["rosc_stop"] if stop is None else stop
    if (o["d_mcause"], o["d_mepc"]) != (3, stop): bad.append("did not stop at its ebreak")
    if o["status"] != 0: bad.append(f"status {o['status']}")
    if o["stored"] != bursts or o["runs"] or o["losses"]: bad.append("stored count")
    words = o["words"]
    if words != 1 << (((o["nbctrl"] >> 8) & 0xff) - 4): bad.append("words per burst against the status register")
    if o["period_used"] != period: bad.append("period read back")
    word = mask << 16 | direct << 28 | (1 << 26 if ring is None else 1 << 22 | ring << 23 | upper << 27)
    if o["mctrl"] & WRITTEN != word: bad.append("control register read back")
    if o["mctrl_end"] & WRITTEN != word: bad.append("control register before test mode was left")
    if o["mctrl_end"] >> 42: bad.append(f"the meter flagged a count: {o['mctrl_end'] >> 48} clock(s), rings {o['mctrl_end'] >> 42 & 63:#04x}")
    if o["polls"] < bursts: bad.append("fewer polls than bursts")
    if not (o["cfg"] == o["cfg_after"] == o["d_cfg"] == pre): bad.append("mentropycfg changed")
    if o["noise_after"] != 1 or o["d_noise"] != 1: bad.append("test mode not left")
    if o["nbctrl_after"] != (MAGIC << 32 | o["nbctrl"] & 0xff00 | 0x10) or o["d_nbctrl"] != o["nbctrl_after"]: bad.append("capture block not at rest afterwards")
    if o["d_period"] != DIV - 1: bad.append("sampling period not back at the build's")
    if o["mctrl_after"] or o["d_mctrl"] or o["d_data0"] or o["d_data1"] or o["d_nbdata"]: bad.append("data readable after test mode")
    if not 0 < words <= 4096: return bad + ["no usable burst size"]
    size, values = 16 + 8 * words, 16 * words
    if any(o["buffer"][bursts * size:bursts * size + 64]): bad.append("wrote past the last burst")
    recs = bursts_of(o["buffer"], bursts, words)
    for i, (t0, t1, _) in enumerate(recs):
        if not (values - 1) * period <= t1 - t0 <= (values + 1) * period + 4096: bad.append(f"burst {i}: stamps {t1 - t0} clocks apart")
        if i and t0 <= recs[i - 1][1]: bad.append(f"burst {i} starts before the one before it was done")
    if ring is None:
        err = refbits_error(recs, period, mask, be.source(o), clocks, found)
        if err: bad.append("values are not the reference bits: " + err)
    else:
        err = count_error(recs, period, ring, be.source(o), clocks, hint, found, 1 if direct else 2, bool(upper))
        if err: bad.append("values are not the ring's count: " + err)
    return bad

def one_run(o):
    """The capture is one run, and no record was lost."""
    return len(o["table"]) == 1 and o["losses"] == 0

def payload_cases(be):
    """Part 1 on one target."""
    name, stop = be.name, LOAD + SYM["rosc_stop"]
    def run(tag, payload, p, sym=SYM, **kw):
        options = {k: kw.pop(k) for k in ("off", "block", "meter", "strap", "wrong") if k in kw}
        code, clocks, mem = be.execute(f"{name}-{tag}", image(payload, p, **kw), **options)
        check(code == 0, f"{name} {tag}: the run ends through the driver (see {name}-{tag}.log)")
        return outcome(mem, sym), clocks

    # ---- good captures: several periods, spacings and ring masks. A count is two ring periods ----
    good, divided, pair = None, {}, 2 << be.rings.frac
    for period, every, mask, count in ((128, 1, 0x3f, 300), (32, 8, 0x3f, 600), (256, 4, 0x0f, 120), (1, 256, 0x3f, 150), (7, 37, 0x35, 100), (64, 1, 0x3f, 300)):
        o, clocks = run(f"p{period}-e{every}-m{mask:02x}", std_bin, params(period, every, mask, count))
        found = []
        bad = problems(o, be, clocks, period, every, mask, count, found=found)
        check(bad == [], f"{name}: {count} records, {period} x {every} clocks apart, ring mask {mask:#04x}: {bad}")
        check(one_run(o), f"{name}: {period} x {every} clocks is slow enough for one run without a loss: {o['losses']} losses, runs of {[r[1] for r in o['table']]}")
        divided[period, every, mask] = (o, found[0] - o["table"][0][2], clocks)     # the capture, and where its run began after its stamp
        if be.exact:
            err = delivered_error(o, be.last)
            check(err is None, f"{name}: {period} x {every} clocks: the buffer is what the meter handed out: {err}")
            check(found[0] == kept(be.last, count)[0][1] and all(any(lo <= be.last.phi[r] % pair < hi for lo, hi in fit) for r, fit in found[-1].items()),
                  f"{name}: {period} x {every} clocks: the comparison with the rings places the run at the clock of its first record, "
                  "and keeps the phase of every ring that was switched on")
        if (period, every) == (32, 8):
            good, good_clocks, good_mask = o, clocks, mask
            tot = [fields(*x)[1] for x in unpack(o["buffer"], count)]
            wraps = [sum(b[r] < a[r] for a, b in zip(tot, tot[1:])) for r in range(6)]
            check(wraps[0] >= 1 and wraps[4] >= 1, f"{name}: the 20-bit totals of rings 0 and 4 wrap within this capture: {wraps}")

    # negative controls on the checks themselves: tampered captures
    def tampered(change):
        t = bytearray(good["buffer"])
        change(t)
        return problems(dict(good, buffer=bytes(t)), be, good_clocks, 32, 8, good_mask, 600)
    def flip(offset, bit):
        def change(t):
            word, = struct.unpack_from("<Q", t, offset)
            struct.pack_into("<Q", t, offset, word ^ 1 << bit)
        return change
    check(any("records are not the source's" in p for p in tampered(flip(16 * 57, 23))), f"{name}: one bit of one total of ring 1 flipped is caught")
    late = "records are not the source's" if good["mctrl"] >> 36 & 1 else "does not count as the source's ring does"
    check(any(late in p for p in tampered(flip(16 * 301 + 8, 20))),
          f"{name}: one bit of a total of ring 4 flipped is caught" + ("" if good["mctrl"] >> 36 & 1 else ", for a ring that the capture switched on"))
    check(any("lane bits are not the rings' outputs" in p for p in tampered(flip(16 * 200 + 8, 60))), f"{name}: the bit of lane 0 flipped in one record is caught")
    def exchange(t):
        t[16 * 40:16 * 41], t[16 * 44:16 * 45] = t[16 * 44:16 * 45], t[16 * 40:16 * 41]
    check(any("records are not the source's" in p for p in tampered(exchange)), f"{name}: two records exchanged, with equal sequence numbers, are caught")
    def shift(t):
        t[16 * 100:16 * 599], t[16 * 599:16 * 600] = t[16 * 101:16 * 600], bytes(16)
    check(any("sequence numbers" in p or "valid flag" in p for p in tampered(shift)), f"{name}: a record missing from a run is caught")

    # ---- direct counting, the cross-check of the divider: a count is one ring period, and the write restarts every ring ----
    for period, every, mask, count in ((128, 1, 0x3f, 300), (32, 8, 0x3f, 600), (256, 4, 0x0f, 120)):
        o, clocks = run(f"direct-p{period}-e{every}-m{mask:02x}", std_bin, params(period, every, mask, count, direct=1))
        other, hint, _ = divided[period, every, mask]
        found = []
        bad = problems(o, be, clocks, period, every, mask, count, found=found, direct=1, hint=hint)
        check(bad == [], f"{name}: direct counting, {count} records, {period} x {every} clocks apart, ring mask {mask:#04x}: every ring from one phase: {bad}")
        check(o["mctrl"] >> 41 & 1 and one_run(o) and o["table"][0][4] >> 41 == 0 and unpack(o["buffer"], 1)[0][0] >> 60 == 8,
              f"{name}: the write that changes the way of counting sets the loss flag, and the run that is started after it is clean: "
              f"no loss, no flagged count, sequence numbers from 0 ({o['losses']} losses, control register {o['table'][0][4]:#x})")
        two, one = advance(o, count), advance(other, count)
        check(all(abs(two[r] - 2 * one[r]) <= 8 for r in range(6)) and all((two[r] > 1000) == (mask >> r & 1) for r in range(6)),
              f"{name}: over as many clocks the totals of a direct capture are twice those of a divided one, but for the rounding at its "
              f"ends and the rings' jitter: {two} against {one}")
        if be.exact:
            first = kept(be.last, count)[0][1]
            check(be.last.restarts[0] + 12 < o["table"][0][2] < first == found[0] and all(any(lo <= be.last.phi[r] % (pair // 2) < hi for lo, hi in fit)
                                                                                         for r, fit in found[-1].items())
                  and len(found[-1]) == bin(mask).count("1"), f"{name}: the rings were restarted more than twelve clocks before the run was started; "
                  "the comparison with the rings places the run at the clock of its first record and keeps the phase of every ring")
    # negative control: a direct capture is not twice a divided one if it is read as a divided one
    o, hint, clocks = divided[128, 1, 0x3f]
    check("does not count as the source's ring does" in str(source_error(unpack(o["buffer"], 300), [o["table"][0][:4]], 128, 0x3f, be.source(o), clocks, None, 1, hint)),
          f"{name}: a capture with counts of two periods is not taken for one with counts of one")
    if be.exact:
        # a count that is 16 too high in one clock, the one error the decoding of a counter can make: the meter flags it
        first = hint + o["table"][0][2]
        o, clocks = run("wrong", std_bin, params(128, 1, 0x3f, 300), wrong=(4, first + 128 * 150 + 64))
        bad = problems(o, be, clocks, 128, 1, 0x3f, 300, flagged=3 << 6 | 1 << 4)
        check(bad == [] and o["table"][0][4] >> 48 == 3 and o["table"][0][4] >> 42 & 63 == 1 << 4,
              f"{name}: a count of ring 4 that is 16 too high in one clock between two records leaves the totals right, and the meter flags ring 4 in "
              f"three clocks: {bad}, control register {o['table'][0][4]:#x}")
        check(any("the meter flagged a count: 3 clock(s), rings 0x10" in p for p in problems(o, be, clocks, 128, 1, 0x3f, 300)),
              f"{name}: and that capture does not pass for one without flagged counts")
        o, clocks = run("wrong-record", std_bin, params(128, 1, 0x3f, 300), wrong=(4, first + 128 * 150))
        bad = problems(o, be, clocks, 128, 1, 0x3f, 300, flagged=3 << 6 | 1 << 4)
        check(len(bad) == 1 and "ring 4, which the capture switched on, does not count as the source's ring does" in bad[0],
              f"{name}: in the clock of a record such a count is in the record's total, which the comparison with the rings shows, and it is flagged: {bad}")

    # ---- bursts of one ring's count: the lower four bits of a count modulo 64, and the upper four ----
    hint = None
    for ring, period, mask, bursts, direct, upper in ((0, 1, 0x3f, 3, 0, 0), (0, 1, 0x3f, 2, 0, 1), (3, 1, 0x3f, 2, 0, 1), (4, 1, 0x3f, 2, 0, 0), (4, 1, 0x3f, 2, 0, 1),
                                                     (5, 1, 0x3f, 2, 0, 1), (1, 3, 0x0f, 2, 0, 0), (2, 1, 0x34, 2, 0, 1),
                                                     (0, 1, 0x3f, 2, 1, 1), (0, 1, 0x3f, 2, 1, 0), (4, 1, 0x3f, 2, 1, 1), (3, 1, 0x3f, 2, 1, 0)):
        what = f"{'direct counting, ' if direct else ''}the {'upper' if upper else 'lower'} four bits of the count of ring {ring}"
        o, clocks = run(f"burst-r{ring}-p{period}-d{direct}-u{upper}", std_bin, params(period, 1, mask, bursts, mode=1, ring=ring, direct=direct, upper=upper))
        found = []
        bad = burst_problems(o, be, clocks, period, ring, mask, bursts, hint=hint, found=found, direct=direct, upper=upper)
        check(bad == [], f"{name}: {bursts} bursts of {what}, {period} clock(s) apart, ring mask {mask:#04x}: {bad}")
        if hint is None:
            hint, burst_o, burst_clocks = found, o, clocks
        recs = bursts_of(o["buffer"], bursts, o["words"])
        if period == 1:
            # the steps from clock to clock, and from them the ring's periods per clock
            rings, (c0, _, burst) = be.source(o).rings, recs[0]
            true = (rings.acc[ring][c0 + found[0] + len(burst) - 1] - rings.acc[ring][c0 + found[0]]) / (len(burst) - 1) / (1 << rings.frac)
            seen = sum((b - a) & 15 for a, b in zip(burst, burst[1:])) / (len(burst) - 1) * (4 if upper else 1) * (1 if direct else 2)
            if upper or true < (16 if direct else 32):
                check(abs(seen / true - 1) < 0.001, f"{name}: the steps of {what} from clock to clock give the ring's {true:.3f} periods per clock: {seen:.3f}")
            else:
                check(abs(seen + 16 - true) < 0.02, f"{name}: ring {ring} makes {true:.3f} periods per clock, and the steps of the lower four bits of its "
                      f"direct count show them only modulo 16: {seen:.3f}")
        if be.exact:
            check([c0 + d for (c0, _, _), d in zip(recs, found)] == [b[0] for b in be.last.started]
                  and all(b[2:] == (1, ring, 0, upper) for b in be.last.started), f"{name}: the bursts of {what} are placed at the clocks at which they began")
    check(any("values are not the ring's count" in p for p in burst_problems(burst_o, be, burst_clocks, 1, 1, 0x3f, 3) if "control" not in p),
          f"{name}: bursts of ring 0 are not taken for the count of ring 1")
    check(any("values are not the ring's count" in p for p in burst_problems(burst_o, be, burst_clocks, 1, 0, 0x3f, 3, upper=1) if "control" not in p),
          f"{name}: the lower four bits of a count are not taken for its upper four")

    # ---- bursts of the reference bits: lanes 0 and 1 with the two reference rings (mode 2) ----
    for period, mask, bursts in ((1, 0x3f, 3), (3, 0x3f, 2), (16, 0x3f, 2), (1, 0x33, 2), (4, 0x0f, 2)):
        o, clocks = run(f"refs-p{period}-m{mask:02x}", std_bin, params(period, 1, mask, bursts, mode=2))
        found = []
        bad = burst_problems(o, be, clocks, period, None, mask, bursts, found=found)
        check(bad == [], f"{name}: {bursts} bursts of the reference bits, {period} clock(s) apart, ring mask {mask:#04x}: {bad}")
        values = set().union(*(set(b) for _, _, b in bursts_of(o["buffer"], bursts, o["words"])))
        check(len({v & 3 for v in values}) == 4 and len({v >> 2 for v in values}) == (4 if mask >> 4 == 3 else 1),
              f"{name}: lanes 0 and 1 take every value in them, and so do the reference bits when their rings run: {sorted(values)}")
        if (period, mask) == (1, 0x3f):
            ref_o, ref_clocks = o, clocks
        if be.exact:
            check(found == [b[0] for b in be.last.started] and all(b[2:] == (0, 0, 1, 0) for b in be.last.started),
                  f"{name}: the bursts of the reference bits are placed at the clocks at which they began")
    def altered(change):
        t = bytearray(ref_o["buffer"])
        change(t)
        return burst_problems(dict(ref_o, buffer=bytes(t)), be, ref_clocks, 1, None, 0x3f, 3)
    def flip(offset, bit):
        def change(t):
            t[offset] ^= 1 << bit
        return change
    size = 16 + 8 * ref_o["words"]
    check(any("values are not the reference bits" in p and "burst 1" in p for p in altered(flip(size + 16 + 700, 0))), f"{name}: the bit of lane 0 flipped in one value is caught")
    late = "bit 2 is not ring 4, which the capture switched on" if not ref_o["mctrl"] >> 36 & 1 else "values are not the reference bits"
    check(any(late in p for p in altered(flip(2 * size + 16 + 900, 2))), f"{name}: the bit of reference 0 flipped in one value is caught")
    check(any("values are not the reference bits" in p for p in altered(flip(16 + 1500, 7))), f"{name}: the bit of reference 1 flipped in one value is caught")
    check(any("values are not the reference bits" in p for p in burst_problems(burst_o, be, burst_clocks, 1, None, 0x3f, 3) if "control" not in p),
          f"{name}: bursts of a ring's count are not taken for the reference bits")

    # ---- losses: records that come faster than the payload takes them ----
    o, clocks = run("fast", std_bin, params(4, 13, 0x3f, 120, losses=RUNS_MAX - 1))
    bad = problems(o, be, clocks, 4, 13, 0x3f, 120)
    check(bad == [] and o["losses"] >= 3 and len(o["table"]) >= 4 and 2 <= max(r[1] for r in o["table"]) <= 60,
          f"{name}: records 52 clocks apart are lost time and again: {o['losses']} losses, runs of {[r[1] for r in o['table']]}, every run a stretch of the source: {bad}")
    if be.exact:
        err = delivered_error(o, be.last)
        check(err is None, f"{name}: records 52 clocks apart: no run joins across a dropped record: {err}")
    o, clocks = run("fast-limit", std_bin, params(4, 13, 0x3f, 400, losses=3))
    table = [r[:2] for r in o["table"]]
    check(o["status"] == 12 and o["losses"] == 4 and 1 <= len(table) <= 4 and o["stored"] == sum(r[1] for r in table) < 400
          and o["noise_after"] == 1 and o["d_noise"] == 1 and o["d_nbctrl"] & 0x3f == 0x10 and o["d_mctrl"] == 0 and o["d_period"] == DIV - 1,
          f"{name}: the fourth loss with three allowed ends the capture with status LOSSES, its runs in the table, test mode left: {o['status']}, {table}")
    # ---- and by the payload's slow parameter: runs of 64 records ----
    o, clocks = run("slow", std_bin, params(128, 1, 0x3f, 200, slow=150))
    bad = problems(o, be, clocks, 128, 1, 0x3f, 200, slow=150)
    check(bad == [] and [r[:2] for r in o["table"]] == [(0, 64), (64, 64), (128, 64), (192, 8)] and o["losses"] == 3,
          f"{name}: slowed down after every 64th record, the capture is four runs: {[r[:2] for r in o['table']]}, {bad}")
    check(all(r[4] >> 41 & 1 for r in o["table"][:3]) and not o["table"][3][4] >> 41 & 1,
          f"{name}: the control register at the end of a run has the loss flag when a loss ended it")
    if be.exact:
        err = delivered_error(o, be.last)
        check(err is None, f"{name}: slowed down: no run joins across a dropped record: {err}")
    slow_o, slow_clocks = o, clocks

    # ---- refusals: nothing may change ----
    def untouched(o, noise=1, cfg=PRE, ctrl=0x10):
        return (o["stored"] == 0 and o["runs"] == 0 and o["d_cfg"] == cfg and o["d_noise"] == noise and o["d_nbctrl"] & 0x3f == ctrl
                and o["d_period"] == (DIV - 1 if o["d_nbctrl"] else 0) and o["mctrl"] == 0 and o["d_mctrl"] == 0 and not any(o["buffer"][:64]))
    o, _ = run("locked", std_bin, params(128, 1, 0x3f, 20), precfg=PRE | LOCK)
    check(o["status"] == 2 and untouched(o, cfg=PRE | LOCK, ctrl=0x18), f"{name}: a locked configuration is refused with status LOCKED, the source untouched")
    o, _ = run("busy", std_bin, params(128, 1, 0x3f, 20), prenoise=1 << 31)
    check(o["status"] == 3 and o["stored"] == 0 and o["d_noise"] >> 31 == 1 and o["d_nbctrl"] & 0x3f == 0x34 and not any(o["buffer"][:64]),
          f"{name}: a source already in test mode is refused with status BUSY, the other user's test mode still on")
    burst_size = 16 + 8 * (1 << LOG2W)
    for what, p in (("period 257", params(257, 1, 0x3f, 20)), ("every 65537", params(128, 65537, 0x3f, 20)), ("ring mask 0x40", params(128, 1, 0x40, 20)),
                    ("no records", params(128, 1, 0x3f, 0)), ("buffer too small", params(128, 1, 0x3f, 20, size=16 * 20 - 1)),
                    ("idle 0", params(128, 1, 0x3f, 20, idle=0)), ("more losses than the run table has room for", params(128, 1, 0x3f, 20, losses=RUNS_MAX)),
                    ("direct 2", params(128, 1, 0x3f, 20, direct=2)), ("upper 2", params(1, 1, 0x3f, 2, mode=1, upper=2)),
                    ("mode 3", params(128, 1, 0x3f, 20, mode=3, size=1 << 16)), ("ring 6", params(1, 1, 0x3f, 2, mode=1, ring=6)),
                    ("a ring outside the mask", params(1, 1, 0x0f, 2, mode=1, ring=4)),
                    ("bursts that do not fit", params(1, 1, 0x3f, 2, mode=1, size=2 * burst_size - 1)),
                    ("reference bursts that do not fit", params(1, 1, 0x3f, 2, mode=2, size=2 * burst_size - 1))):
        o, _ = run("param", std_bin, p)
        check(o["status"] == 4 and untouched(o), f"{name}: PARAM for {what}, source untouched")
    o, _ = run("noblock", std_bin, params(128, 1, 0x3f, 20), block=False)
    check(o["status"] == 8 and o["nbctrl"] == 0 and untouched(o, ctrl=0), f"{name}: an image without the capture block: NOBLOCK, test mode never entered")
    if be.exact:
        o, _ = run("nometer", std_bin, params(128, 1, 0x3f, 20), meter=False)
        check(o["status"] == 11 and o["stored"] == 0 and o["mctrl"] == 0 and o["period_used"] == 128 and o["noise_after"] == 1 and o["d_noise"] == 1
              and o["d_nbctrl"] & 0x3f == 0x10 and o["d_period"] == DIV - 1, f"{name}: an image without the meter: NOMETER, and test mode left again")
        o, clocks = run("strap", std_bin, params(128, 1, 0x3f, 100), strap=0x3f)
        bad = problems(o, be, clocks, 128, 1, 0x3f, 100)
        check(bad == [] and o["mctrl"] >> 32 & 0x3f == 0x3f, f"{name}: with all six rings running outside test mode: {bad}")

    # ---- waits are bounded, and the source is put back on the way out ----
    o, _ = run("off", std_bin, params(128, 1, 0x3f, 20, idle=3000), off=True)
    check(o["status"] == 6 and o["stored"] == 0 and o["runs"] == 0 and o["polls"] == 3000, f"{name}: source off (strap low): no record within the idle limit, status TIMEOUT")
    check(o["noise_after"] == 1 and o["d_noise"] == 1 and o["d_nbctrl"] & 0x3f == 0 and o["d_period"] == DIV - 1, f"{name}: TIMEOUT: test mode left, capture block at rest")
    o, _ = run("off-burst", std_bin, params(1, 1, 0x3f, 2, mode=1, idle=3000), off=True)
    check(o["status"] == 10 and o["stored"] == 0 and 0 < o["polls"] < 3000 and o["d_noise"] == 1, f"{name}: source off in mode 1: the capture block aborts the burst, status ABORTED")
    o, _ = run("fault", std_bin, params(128, 1, 0x3f, 20, buf=0x40000000))
    check(o["status"] == 7 and o["mcause"] == 7 and LOAD + SYM["take"] < o["mepc"] < LOAD + SYM["wait"],
          f"{name}: a faulting buffer address ends in status TRAP at the first store (mcause {o['mcause']}, mepc {o['mepc']:#x})")
    check(o["noise_after"] == 1 and o["d_noise"] == 1 and o["d_nbctrl"] & 0x3f == 0x10 and o["d_period"] == DIV - 1 and o["d_mctrl"] == 0
          and (o["d_mcause"], o["d_mepc"]) == (3, stop), f"{name}: TRAP in the middle of a capture: test mode left, normal stop")

    # ---- the ROSC_SIM build alone at the reset address, reporting through tohost ----
    mem = bytearray(SIZE)
    mem[:len(sim_bin)] = sim_bin
    struct.pack_into(f"<{NPARAMS}Q", mem, sim_sym["rosc_params"], *params(128, 1, 0x3f, 50))
    code, clocks, after = be.execute(f"{name}-tohost", mem)
    o = outcome(after, sim_sym, BASE, driven=False)
    check(code == 0 and o["status"] == 0 and o["stored"] == 50 and o["noise_after"] == 1, f"{name}: ROSC_SIM build: status 0 through tohost")
    err = source_error(unpack(o["buffer"], 50), [r[:4] for r in o["table"]], 128, 0x3f, be.source(o), clocks)
    check(err is None, f"{name}: ROSC_SIM build: records from the source: {err}")
    struct.pack_into(f"<{NPARAMS}Q", mem, sim_sym["rosc_params"], *params(128, 1, 0x40, 50))
    check(be.execute(f"{name}-tohost-param", mem)[0] == 4, f"{name}: ROSC_SIM build: an error status is the exit code")

    # ---- negative controls: mutants of the payload ----
    def mutated(tag, p, *changes, **kw):
        mut_bin, mut_sym = mutant("mutant_" + tag, *changes)
        if mut_sym["rosc_params"] != SYM["rosc_params"] or mut_sym["rosc_result"] != SYM["rosc_result"]:
            raise SystemExit(f"FAIL rosc count self-test: mutant {tag} moves the parameter block")
        o, clocks = run("mutant-" + tag, mut_bin, p, mut_sym, **kw)
        return o, clocks, LOAD + mut_sym["rosc_stop"]
    o, clocks, at = mutated("test", params(128, 1, 0x3f, 40), ("\tcsrw\tCSR_MNOISE, zero\n", "\tnop\n"))
    bad = problems(o, be, clocks, 128, 1, 0x3f, 40, stop=at)
    check("test mode not left" in bad and "capture block not at rest afterwards" in bad and "data readable after test mode" in bad and o["d_noise"] >> 31 == 1,
          f"{name}: mutant that stays in test mode is caught: {bad}")
    o, clocks, at = mutated("valid", params(128, 1, 0x3f, 40), ("\tbne\t\tt2, s6, wait\t", "\tnop\t"))
    bad = problems(o, be, clocks, 128, 1, 0x3f, 40, stop=at)
    check(o["status"] == 0 and any("without the valid flag" in p for p in bad), f"{name}: mutant that takes a record without waiting for the valid flag is caught: {bad}")
    o, clocks, at = mutated("loss", params(128, 1, 0x3f, 200, slow=150), ("\tsrli\tt2, t0, 62\n\tbne\t\tt2, s6, wait\t", "\tsrli\tt2, t0, 63\n\tbne\t\tt2, s6, wait\t"),
                            ("\tsrli\tt2, t0, 62\n\tbne\t\tt2, s6, 1b\n", "\tsrli\tt2, t0, 63\n\tbne\t\tt2, s6, 1b\n"), ("\tli\t\ts6, 2\n", "\tli\t\ts6, 1\n"))
    bad = problems(o, be, clocks, 128, 1, 0x3f, 200, stop=at, slow=150)
    check(o["status"] == 0 and len(o["table"]) == 1 and any("with the loss flag" in p for p in bad) and any("records are not the source's" in p for p in bad),
          f"{name}: mutant that ignores the loss flag joins runs, and is caught by the flag and by the comparison with the source: {bad}")
    if be.exact:
        check("joins records across one that the meter dropped" in str(delivered_error(o, be.last)), f"{name}: and by the list of what the meter handed out")
    o, clocks, at = mutated("words", params(128, 1, 0x3f, 40), ("\tsd\t\tt0, 0(s2)\n\tsd\t\tt1, 8(s2)\n", "\tsd\t\tt1, 0(s2)\n\tsd\t\tt0, 8(s2)\n"))
    bad = problems(o, be, clocks, 128, 1, 0x3f, 40, stop=at)
    check(any("valid flag" in p or "sequence numbers" in p for p in bad) and any("records are not the source's" in p for p in bad),
          f"{name}: mutant that stores the two words of a record the other way round is caught: {bad}")
    o, clocks, at = mutated("stamps", params(128, 1, 0x3f, 40), ("\tsd\t\tt0, RUN_CYCLE1(a5)\n", "\tsd\t\tt0, RUN_CYCLE0(a5)\n"))
    bad = problems(o, be, clocks, 128, 1, 0x3f, 40, stop=at)
    check(any("stamps" in p for p in bad), f"{name}: mutant that puts the end stamp of a run in place of its start stamp is caught: {bad}")
    o, clocks, at = mutated("warm", params(64, 1, 0x3f, 300), ("\tli\t\ta0, WARM_TRIES\t", "\tli\t\ta0, 0\t"))
    bad = problems(o, be, clocks, 64, 1, 0x3f, 300, stop=at)
    check(bad == [] and o["losses"] >= 1 and not one_run(o),
          f"{name}: mutant without the warm-up loses a record while its record loop is fetched from memory for the first time, "
          f"and is caught by the check for one run without a loss: {o['losses']} losses, runs of {[r[1] for r in o['table']]}, {bad}")
    if be.exact:
        check(len(be.last.taken) == 300 and kept(be.last, 300) is None, f"{name}: and by the list of what the meter handed out, which has no record before the capture's")
    o, clocks, at = mutated("ring", params(1, 1, 0x3f, 2, mode=1, ring=1), ("\tslli\tt0, t0, 23\n", "\tslli\tt0, t0, 24\n"))
    bad = burst_problems(o, be, clocks, 1, 1, 0x3f, 2, stop=at)
    check(any("control register read back" in p for p in bad) and any("values are not the ring's count" in p for p in bad),
          f"{name}: mutant that selects another ring for the count burst is caught: {bad}")
    o, clocks, at = mutated("refs", params(1, 1, 0x3f, 2, mode=2), ("\tslli\tt1, t1, 26\t", "\tslli\tt1, t1, 25\t"))
    bad = burst_problems(o, be, clocks, 1, None, 0x3f, 2, stop=at)
    check(o["status"] == 0 and any("control register read back" in p for p in bad) and any("values are not the reference bits" in p for p in bad),
          f"{name}: mutant that leaves the lane bits in the burst, in place of the reference bits, is caught: {bad}")
    o, clocks, at = mutated("direct", params(128, 1, 0x3f, 40, direct=1),
                            ("\tld\t\tt0, P_DIRECT(s0)\n\tslli\tt0, t0, 28\n\tor\t\ta6, a6, t0\n", "\tld\t\tt0, P_DIRECT(s0)\n\tslli\tt0, t0, 28\n\tnop\n"))
    bad = problems(o, be, clocks, 128, 1, 0x3f, 40, stop=at, direct=1, hint=divided[128, 1, 0x3f][1])
    check(o["status"] == 0 and "control register read back" in bad and any("records are not the source's" in p for p in bad),
          f"{name}: mutant that counts pairs of periods when asked to count directly is caught by the control register and by the totals: {bad}")
    o, clocks, at = mutated("upper", params(1, 1, 0x3f, 2, mode=1, ring=0, upper=1), ("\tslli\tt0, t0, 27\n\tor\t\ta6, a6, t0\n", "\tslli\tt0, t0, 27\n\tnop\n"))
    bad = burst_problems(o, be, clocks, 1, 0, 0x3f, 2, stop=at, upper=1)
    check(o["status"] == 0 and any("control register read back" in p for p in bad) and any("values are not the ring's count" in p for p in bad),
          f"{name}: mutant that gives the lower four bits of a count for the upper four is caught: {bad}")
    return slow_o, slow_clocks

# --------------------------------------------------------- capture phase ----
class FakeOpenOCD(threading.Thread):
    """Stand-in for OpenOCD's Tcl RPC with a target behind it.

    The target is this file's memory image: the phase's write_memory and
    read_memory work on it, and resume runs it on `backend` with the driver
    in front (in a thread; the hart reads "running" meanwhile). A read of
    the capture block's status register, which the phase makes before it
    loads anything, is answered with `ctrl`. Attributes steer one scenario:
    options for the target, tamper to alter memory after the run, hang for
    a hart that never halts.
    """
    def __init__(self):
        super().__init__(daemon=True)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(8)
        self.port = self.listener.getsockname()[1]
        self.mem, self.regs, self.state, self.backend = bytearray(SIZE), {}, "halted", None
        self.ctrl = MAGIC << 32 | (LOG2W + 4) << 8 | 0x10
        self.precfg, self.options, self.tamper, self.hang, self.sims, self.ran = PRE, {}, None, False, 0, []
    def execute(self, addr):
        self.sims += 1
        code, clocks, mem = self.backend.execute(f"{self.backend.name}-target-{self.sims}", image(None, None, self.precfg, mem=self.mem, entry=addr),
                                                 **self.options)
        if code != 0:
            return                                              # stays "running"
        self.mem[0x2000:] = mem[0x2000:]
        self.ran.append((clocks, self.backend.source(outcome(mem)), getattr(self.backend, "last", None)))
        if self.tamper:
            self.tamper(self.mem)
        self.regs["pc"] = struct.unpack_from("<Q", mem, driver_sym["d_entry"] - BASE + 32)[0]
        self.state = "halted"
    def command(self, name, *a):
        if name == "karu.cpu": return self.state
        if name == "halt": self.state = "halted"; return ""
        if name == "riscv": return "0x0" if a[0] == "dmi_read" else ""
        if name == "reg": self.regs[a[0]] = int(a[1], 0); return ""
        if name == "get_reg": return f"{a[-1]} {self.regs.get(a[-1], 0):#x}"
        if name == "read_memory" and int(a[0], 0) == NBURST + 0x20:   # the temperature readout
            return hex(SYSMON_WORD)
        if name == "read_memory" and int(a[0], 0) == NBURST:
            if (a[1], a[2], a[3]) != ("64", "1", "phys"):
                raise ValueError("the capture block takes 64-bit accesses only")
            return hex(self.ctrl)
        if name in ("write_memory", "read_memory"):
            addr, size = int(a[0], 0) - BASE, int(a[1]) // 8
            count = len(a[2].split()) if name == "write_memory" else int(a[2])
            if not 0x2000 <= addr <= SIZE - size * count or a[3] != "phys":
                raise ValueError(f"{name}: outside the stand-in's memory")
            if name == "read_memory":
                return " ".join(hex(int.from_bytes(self.mem[addr + i * size:addr + (i + 1) * size], "little")) for i in range(count))
            for i, v in enumerate(a[2].split()):
                self.mem[addr + i * size:addr + (i + 1) * size] = int(v, 0).to_bytes(size, "little")
            return ""
        if name == "resume":
            self.state = "running"
            if not self.hang:
                threading.Thread(target=self.execute, args=(int(a[0], 0),), daemon=True).start()
            return ""
        return ""                                               # poll
    def run(self):
        tcl = tkinter.Tcl()
        def py(name, *a):                                       # 0 and a result, or 1 and an error message
            try:
                tcl.globalsetvar("py_result", self.command(name, *a)); return 0
            except Exception as e:
                tcl.globalsetvar("py_result", str(e)); return 1
        tcl.createcommand("py", py)
        for name in ("karu.cpu", "halt", "riscv", "reg", "get_reg", "write_memory", "read_memory", "resume", "poll"):
            tcl.eval("proc %s {args} {if {[py %s {*}$args]} {error $::py_result} ; return $::py_result}" % (name, name))
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
                    chunk = sock.recv(1 << 20)
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

fake = FakeOpenOCD()
fake.start()

# The phase needs the bare-metal fixture of the selected image map for its
# trap handler and its final PC, and refuses any other. The capture itself is
# in DRAM and the same on every map. boardlib.py says where the fixture is.
MAP = dict(KARU_BOARD_IMAGE="rom2m-auth", KARU_BOARD_SCRATCH="", KARU_BOARD_SCRATCH_SIZE="", KARU_BOARD_RESET_PC="")
ENV = {k: v for k, v in os.environ.items() if not k.startswith("KARU_BOARD_ROSC_")}
fixture = int(subprocess.run([sys.executable, str(SRC / "boardlib.py")], env=dict(ENV, KARU_BOARD_OUT=str(out), **MAP),
                             check=True, capture_output=True, text=True).stdout, 16)
STAGES = [3, 5, 7, 9, 3, 3]
SYSMON = {"raw": hex(SYSMON_WORD), "updates": 5, "temp_c": 40.0, "vccint_v": 0.85, "vccaux_v": 1.8}

def phase(tag, payload=std_bin, argv=(), **env):
    """Run rosc_count.py as a process in its own artifact directory: (exit status, directory, case results, stderr)."""
    where = out / f"phase-{tag}"
    where.mkdir(exist_ok=True)
    for f in list(where.glob("rosc-*")) + list(where.glob("rosc_count.*")) + list(where.glob("refbits/*")):
        f.unlink()
    (where / "payload.symbols").write_text(f"{fixture:016x} T _start\n{fixture + 0x400:016x} T trap_handler\n")
    (where / "payload.bin").write_bytes(bytes(64))
    if payload is not None:
        (where / "rosc_count.bin").write_bytes(payload)
        (where / "rosc_count.symbols").write_text((out / "rosc_count.symbols").read_text())
    settings = dict(ENV, KARU_BOARD_OUT=str(where), KARU_BOARD_RPC=f"127.0.0.1:{fake.port}", KARU_BOARD_ROSC_ADDR=hex(LOAD),
                    KARU_BOARD_ROSC_SETTINGS="128x1,32x8", KARU_BOARD_ROSC_COUNT="100,600",
                    KARU_BOARD_ROSC_DIRECT_COUNT="150", KARU_BOARD_ROSC_BURSTS="2", KARU_BOARD_ROSC_REF_BURSTS="2", KARU_BOARD_ROSC_REF_PERIODS="1,4,16",
                    KARU_BOARD_ROSC_CLOCK_HZ="1000000", KARU_BOARD_ROSC_NOTE="self-test",
                    KARU_BOARD_ROSC_WAIT="300", **MAP)
    settings.update({"KARU_BOARD_ROSC_" + k.upper(): str(v) for k, v in env.items()})
    fake.mem[:], fake.ran = bytes(SIZE), []
    r = subprocess.run([sys.executable, str(SRC / "rosc_count.py"), *argv], env=settings, capture_output=True, text=True, timeout=1800)
    (where / "phase.log").write_text(r.stdout + r.stderr)
    results = json.loads((where / "rosc-count-results.json").read_text()) if (where / "rosc-count-results.json").exists() else []
    return r.returncode, where, results, r.stderr

def details(results):
    return " | ".join(str(r["detail"]) for r in results if r["status"] != "PASS")

def capture_runs(path):
    """The bursts of a capture file in the burst format, flags stripped; None if the bytes are not a capture."""
    data = path.read_bytes()
    runs = re.findall(rb"[\x80-\x8f][\x00-\x0f]*", data)
    return [bytes(v & 15 for v in r) for r in runs] if sum(map(len, runs)) == len(data) else None

def handoff(name, path, side, pair=None):
    """rosc_own.py, the analysis, as a process on a file that the phase wrote. It has to read the file, find the runs
    and the rings that the sidecar describes, and end without an error; a run with a flagged count it has to set
    aside. With `pair`, the capture of the same rings in the other way of counting, it has to compare the two and
    end without an error. What it makes of the records is its own test's business (test_rosc_own.py), and so is the
    form of the rest of its output."""
    r = subprocess.run([sys.executable, str(SRC / "rosc_own.py"), str(path)] + (["--pair", str(pair)] if pair else []), capture_output=True, text=True, timeout=900)
    path.with_name(path.stem + "-own.txt").write_text(r.stdout + r.stderr)
    listed, mask, clean = [(x["start"], x["records"]) for x in side["runs"]], side["ring_mask"], [not n for n in side["bad_counts"]]
    # its exit status: 0 when it analysed the capture, whatever the verdict; 2 when it could not, which is
    # what a capture with no run but flagged ones is
    wanted = 0 if any(clean) else 2
    check(r.returncode == wanted and "Traceback" not in r.stdout + r.stderr,
          f"{name} {path.name}: rosc_own.py reads the phase's file{' with its pair' if pair else ''} and ends without an error "
          f"(exit status {wanted}: {'analysed' if wanted == 0 else 'no run it may use'}): "
          f"exit {r.returncode}, {(r.stdout + r.stderr)[-300:]}")
    try:
        whole = json.loads(r.stdout)
        seen = whole["input"] if any(clean) else whole          # with no run that it can use it has no input section, only what it set aside
        used, left = [(x["start"], x["records"]) for x in seen.get("runs", [])], [x["start"] for x in seen["rejected"]]
        rings = (seen["n0"], seen["ring_mask"], seen["running"], seen["count_unit"]) if any(clean) else None
    except (ValueError, KeyError, TypeError) as e:
        used = left = rings = None
        seen = f"its output has no input section with runs, rejected, n0, ring_mask, running and count_unit: {e!r}"
    check(used is not None and (used != []) == any(clean) and all(x in listed for x in used) and all(x in used or x[0] in left for x in listed)
          and all(ok or x not in used for x, ok in zip(listed, clean)),
          f"{name} {path.name}: rosc_own.py finds the runs of the sidecar, each used as it is or set aside with a reason, and uses none with a flagged count: "
          f"{listed}, flagged {side['bad_counts']}, against {str(seen)[:600]}")
    if any(clean):
        check(rings == (side["period"] * side["every"], mask, [r for r in range(6) if mask >> r & 1], side["count_unit"]),
              f"{name} {path.name}: rosc_own.py finds the spacing, the rings and the count unit of the sidecar: {seen}")
    if pair:
        both = whole.get("pair") if used is not None else None
        check(isinstance(both, dict) and Path(str(both.get("other"))).name == pair.name
              and both.get("count_unit") == [side["count_unit"], json.loads(pair.with_suffix(".json").read_text())["count_unit"]],
              f"{name} {path.name}: rosc_own.py takes {pair.name} as the capture in the other way of counting, with the count units of the two sidecars: "
              f"{str({k: v for k, v in both.items() if k != 'rings'} if isinstance(both, dict) else both)[:500]}")

skipped = []
def analyses(name, refbits, periods):
    """The two tools for the reference bits, as processes on the directory that the phase wrote: getnoise_analyze.py has
    to read the files as burst captures at their periods and write its analysis next to them, and entropy_claim.py
    --own has to read that analysis and the files and end without an error. What they make of them is their own
    tests' business. entropy_claim.py needs scipy: without it that part is not run, and the last line says so."""
    files = [str(refbits / f"getnoise-burst-p{period}.bin") for period in periods]
    r = subprocess.run([sys.executable, str(SRC / "getnoise_analyze.py"), *files], capture_output=True, text=True, timeout=900)
    (refbits.parent / "refbits-analysis.txt").write_text(r.stdout + r.stderr)
    done = (refbits / "getnoise-analysis.json").exists()
    seen = json.loads((refbits / "getnoise-analysis.json").read_text())["captures"] if done else []
    check(r.returncode == 0 and "Traceback" not in r.stderr and [(c["kind"], c["period"], c["k"], c["runs"], c["symbols"]) for c in seen]
          == [("burst", period, 1, 2, 32 << LOG2W) for period in periods],
          f"{name}: getnoise_analyze.py reads the files of refbits as burst captures at their periods and writes refbits/getnoise-analysis.json: "
          f"exit {r.returncode}, {r.stderr[-300:]}")
    path = os.pathsep.join(x for x in (str(ROOT / "_build/pylib"), os.environ.get("PYTHONPATH")) if x)
    if subprocess.run([sys.executable, "-c", "import scipy.optimize"], env=dict(os.environ, PYTHONPATH=path), capture_output=True).returncode:
        skipped.append(f"{name}: entropy_claim.py --own not run, scipy cannot be imported")
        return
    r = subprocess.run([sys.executable, str(SRC / "entropy_claim.py"), "--analysis", str(refbits / "getnoise-analysis.json"), "--own", str(refbits),
                        "--periods", ",".join(map(str, periods))], env=dict(os.environ, PYTHONPATH=path), capture_output=True, text=True, timeout=900)
    (refbits.parent / "refbits-own.txt").write_text(r.stdout + r.stderr)
    try:
        own = json.loads(r.stdout)
        shape = (own["rings"], own["bits"], [p["period"] for p in own["periods"]])
    except (ValueError, KeyError, TypeError) as e:
        shape = repr(e)
    check(r.returncode == 0 and "Traceback" not in r.stderr and shape == (["lane 0", "reference 0", "reference 1"], [0, 2, 3], list(periods)),
          f"{name}: entropy_claim.py --own reads that analysis and the files, for lane 0 and the two reference rings at every period: "
          f"exit {r.returncode}, {shape}, {r.stderr[-300:]}")

def phase_cases(be):
    """Part 2 on one target."""
    name = be.name
    fake.backend, fake.options = be, {}

    # a good capture: two settings and one of them in direct mode, the default ring masks, the count bursts of all six rings
    # in both views and both ways of counting, the reference bits at three periods
    code, where, results, _ = phase(name + "-good")
    check(code == 0 and [r["status"] for r in results] == ["PASS"] * 35, f"{name}: the phase exits 0 with its 34 cases passed: {details(results)}")
    names = [r["name"] for r in results]
    check(["0x0f" in n for n in names[1:7]] == [True] * 3 + [False] * 3 and ["direct" in n for n in names[1:7]] == [True, False, False] * 2
          and all("128 x 1" in n for n in names[1:7:3]) and all("ring mask 0x3f" in n for n in names[4:34])
          and ["count bursts" in n for n in names[7:34]] == [True] * 24 + [False] * 3 and ["in direct mode" in n for n in names[7:31]] == [False] * 12 + [True] * 12
          and all("reference bits" in n for n in names[31:34]) and names[34] == "captures with flagged clocks",
          f"{name}: by default the rings of normal operation are captured first, then all six, each with the capture in direct mode just before the "
          "divided one that it is compared with; the count bursts, the two views of each ring in the two ways of counting, and then the reference "
          f"bits are taken with all six on: {names}")
    log = (where / "phase.log").read_text()
    check(str(results[34]["detail"]).startswith("none") and "rosc-count: 0 capture(s) in which the meter flagged a count" in log.splitlines()[-1]
          and all(r["detail"].get("flagged_clocks") == 0 and "warning" not in r["detail"] for r in results[1:34]),
          f"{name}: no capture has a flagged count, and the summary and the last line of the phase say so: {log.splitlines()[-1]}")
    ran = iter(fake.ran)
    def records(stem, count, period, every, mask, unit, hint, found):
        """The checks of one file of records; returns what its totals advanced by per clock, unwrapped."""
        clocks, src, target = next(ran)
        data, side = (where / f"{stem}.bin").read_bytes(), json.loads((where / f"{stem}.json").read_text())
        check(len(data) == 16 * count and side["sha256"] == hashlib.sha256(data).hexdigest() and side["records"] == count == side["requested"],
              f"{name} {stem}: the file holds the records, 16 bytes each, and the sidecar has its SHA-256")
        check((side["clock_hz"], side["period"], side["every"], side["ring_mask"], side["stages"], side["note"]) == (1000000, period, every, mask, STAGES, "self-test")
              and side["clocks_per_record"] == period * every and side["format"] == "karu64-rosc-count-1",
              f"{name} {stem}: the sidecar gives the clock, the period, every, the ring mask as a number, the stages and the note")
        check(side["count_unit"] == unit and ("direct" in side["counting"]) == (unit == 1) and side["bad_counts"] == [0] and side["bad_rings"] == [[]]
              and side["scale"] == 1, f"{name} {stem}: the sidecar says that a count is {unit} ring period(s), and has for its run the clocks with a "
              f"flagged count and the rings that had one, here none: {side['count_unit']}, {side['bad_counts']}, {side['bad_rings']}")
        check(side["for_bound"] is False and (("direct mode" in side["for_bound_why"]) if unit == 1 else
                                              (f"{count} records, fewer than the 300000 usable records a bound needs" in side["for_bound_why"])),
              f"{name} {stem}: the sidecar says that this capture cannot carry a bound, and why ({side['for_bound_why'][:60]})")
        runs = side["runs"]
        check(len(runs) == 1 and set(runs[0]) == {"start", "records", "cycle_start", "cycle_end"} and (runs[0]["start"], runs[0]["records"]) == (0, count)
              and (count - 1) * period * every <= runs[0]["cycle_end"] - runs[0]["cycle_start"] and side["losses"] == 0 and len(side["run_ctrl"]) == 1,
              f"{name} {stem}: one run, with its start, its records and its two stamps: {runs}")
        check(int(side["ctrl"], 16) & WRITTEN == (every - 1 | mask << 16 | (unit == 1) << 28) and side["strap_mask"] == src.strap == int(side["ctrl"], 16) >> 32 & 0x3f
              and int(side["mentropycfg_before"], 16) == PRE == int(side["mentropycfg_after"], 16)
              and int(side["mentropystat_before"], 16) >= 0 and int(side["mentropystat_after"], 16) >= 0 and side["noise_after"] == 1,
              f"{name} {stem}: the sidecar has the control register read back, the rings that run outside test mode, and mentropycfg and mentropystat before and after")
        check(side["sysmon_before"] == side["sysmon_after"] == SYSMON, f"{name} {stem}: the sidecar records the temperature readout, raw and decoded: {side['sysmon_before']}")
        recs, table = unpack(data, count), [(r["start"], r["records"], r["cycle_start"], r["cycle_end"]) for r in runs]
        err = source_error(recs, table, period * every, mask, src, clocks, found, unit, hint)
        check(err is None, f"{name} {stem}: the file holds the totals and lane bits of the source, at the stamped distances: {err}")
        if be.exact:
            check([fields(*x)[1:] for x in recs] == [(tuple(tot), lanes) for _, _, tot, lanes in kept(target, count)],
                  f"{name} {stem}: the file is what the meter handed out after the warm-up")
        # what the analysis will do with the file: unwrap the totals, and multiply by the unit. That must be the rings' periods.
        tot = [fields(*x)[1] for x in recs]
        sums = [[0] for _ in range(6)]
        for a, b in zip(tot, tot[1:]):
            for r in range(6):
                sums[r].append(sums[r][-1] + ((b[r] - a[r]) & M20))
        rate = [sums[r][-1] / ((count - 1) * period * every) for r in range(6)]
        near = [abs(unit * rate[r] / (src.rings.whole[r][clocks] / clocks) - 1) < 0.01 for r in range(6) if mask >> r & 1]
        check(all(near) and len(near) == bin(mask).count("1") and all(rate[r] == 0 for r in range(6) if not mask >> r & 1),
              f"{name} {stem}: unwrapped and times {unit}, every ring of the mask has its periods per clock, and a ring outside it stands still: "
              f"{[round(unit * x, 3) for x in rate]}")
        if count == 600:
            check(sums[0][-1] > 1 << 20 and any(b[0] < a[0] for a, b in zip(tot, tot[1:])), f"{name} {stem}: the total of ring 0 wraps in the file, and unwraps past 2^20")
        return side, rate
    for mask in (0x0f, 0x3f):
        entries = [next(ran) for _ in range(3)]                             # in the phase's order: direct, then the two divided captures
        ran, rest = iter([entries[1], entries[0], entries[2]]), ran         # here the divided one first: it says where to look for the direct one
        found = []
        side, rate = records(f"rosc-count-p128-e1-m{mask:02x}", 100, 128, 1, mask, 2, None, found)
        other, twice = records(f"rosc-direct-p128-e1-m{mask:02x}", 150, 128, 1, mask, 1, found[0] - side["runs"][0]["cycle_start"], None)
        check(all(abs(twice[r] / (2 * rate[r]) - 1) < 0.001 for r in range(6) if mask >> r & 1) and other["time"] <= side["time"],
              f"{name}: the capture in direct mode, named rosc-direct, counts twice what the divided capture after it counts: "
              f"{[round(x, 3) for x in twice]} against {[round(x, 3) for x in rate]} per clock")
        handoff(name, where / f"rosc-direct-p128-e1-m{mask:02x}.bin", other)
        handoff(name, where / f"rosc-count-p128-e1-m{mask:02x}.bin", side, where / f"rosc-direct-p128-e1-m{mask:02x}.bin")
        side, rate = records(f"rosc-count-p32-e8-m{mask:02x}", 600, 32, 8, mask, 2, None, None)
        handoff(name, where / f"rosc-count-p32-e8-m{mask:02x}.bin", side)
        ran = rest
    hint = None
    for direct in (0, 1):
        for ring in range(6):
            for upper in (1, 0):
                stem, (clocks, src, target) = f"rosc-{'direct-' if direct else ''}burst-r{ring}-{'hi' if upper else 'lo'}", next(ran)
                data, side = (where / f"{stem}.bin").read_bytes(), json.loads((where / f"{stem}.json").read_text())
                runs = capture_runs(where / f"{stem}.bin")
                check(runs is not None and [len(r) for r in runs] == [16 << LOG2W] * 2 == side["run_lengths"] and side["stored"] == len(data) == 32 << LOG2W,
                      f"{name} {stem}: two bursts of {16 << LOG2W} values, each flagged as a run, in the format of the burst capture")
                check(side["sha256"] == hashlib.sha256(data).hexdigest() and (side["format"], side["kind"], side["source"], side["ring"]) == ("karu64-getnoise-burst-1", "burst", "count", ring)
                      and (side["period"], side["k"], side["bursts"], side["ring_mask"], side["stages"], side["clock_hz"], side["note"]) == (1, 1, 2, 0x3f, STAGES, 1000000, "self-test")
                      and int(side["ctrl"], 16) & WRITTEN == (0x3f << 16 | 1 << 22 | ring << 23 | upper << 27 | direct << 28)
                      and (side["view"], side["count_bits"], side["count_unit"]) == (("upper", [5, 2]) if upper else ("lower", [3, 0])) + (1 if direct else 2,)
                      and (side["bad_count"], side["bad_rings"]) == (0, []) and len(side["burst_cycles"]) == 2 == len(side["burst_done_cycles"]) and side["sysmon_before"] == SYSMON,
                      f"{name} {stem}: the sidecar says which four bits of the count of ring {ring} the values are, in which unit, and that no count was flagged")
                found = []
                err = count_error(list(zip(side["burst_cycles"], side["burst_done_cycles"], runs)), 1, ring, src, clocks, hint, found, 1 if direct else 2, bool(upper))
                check(err is None, f"{name} {stem}: the file holds those bits of the count of ring {ring} clock by clock: {err}")
                hint = hint or found
                if upper:
                    first = side["burst_cycles"][0] + found[0]
                    true = (src.rings.acc[ring][first + len(runs[0]) - 1] - src.rings.acc[ring][first]) / (len(runs[0]) - 1) / (1 << src.rings.frac)
                    seen = sum((b - a) & 15 for a, b in zip(runs[0], runs[0][1:])) / (len(runs[0]) - 1) * 4 * side["count_unit"]
                    check(abs(seen / true - 1) < 0.001, f"{name} {stem}: its steps from clock to clock, times four and times the unit, are the ring's "
                          f"{true:.3f} periods per clock: {seen:.3f}")
    # the reference bits: burst captures by name and by format, in a directory of their own
    for period in (1, 4, 16):
        stem, (clocks, src, target) = f"refbits/getnoise-burst-p{period}", next(ran)
        data, side = (where / f"{stem}.bin").read_bytes(), json.loads((where / f"{stem}.json").read_text())
        runs = capture_runs(where / f"{stem}.bin")
        check(runs is not None and [len(r) for r in runs] == [16 << LOG2W] * 2 == side["run_lengths"] and side["stored"] == len(data) == 32 << LOG2W
              and side["sha256"] == hashlib.sha256(data).hexdigest(), f"{name} {stem}: two bursts of {16 << LOG2W} values in the format of the burst capture")
        check((side["format"], side["kind"], side["source"], side["lanes"]) == ("karu64-getnoise-burst-1", "burst", "refbits", ["lane 0", "lane 1", "reference 0", "reference 1"])
              and (side["period"], side["k"], side["bursts"], side["ring_mask"], side["clock_hz"], side["note"]) == (period, 1, 2, 0x3f, 1000000, "self-test")
              and int(side["ctrl"], 16) & WRITTEN == (0x3f << 16 | 1 << 26) and "NOT lanes 2 and 3" in side["encoding"] and side["sysmon_before"] == SYSMON,
              f"{name} {stem}: the sidecar is a burst capture's, and says that the samples are lanes 0 and 1 and the two reference rings")
        err = refbits_error(list(zip(side["burst_cycles"], side["burst_done_cycles"], runs)), period, 0x3f, src, clocks)
        check(err is None, f"{name} {stem}: the file holds the bits of lanes 0 and 1 and of the reference rings, sample by sample: {err}")
    check(sorted(f.name for f in (where / "refbits").iterdir()) == sorted(f"getnoise-burst-p{period}.{end}" for period in (1, 4, 16) for end in ("bin", "json"))
          and not list(where.glob("getnoise-burst-*")), f"{name}: the reference bits are in the subdirectory refbits and nowhere else")
    check(fake.regs["pc"] == fixture and fake.state == "halted", f"{name}: the phase leaves the hart halted at the fixture's entry, as the other phases do")
    analyses(name, where / "refbits", (1, 4, 16))

    # runs split by losses: the sidecar lists them, and the file never joins them
    code, where, results, _ = phase(name + "-slow", settings="128x1", count=200, masks="0x3f", direct_count=0, bursts=0, ref_bursts=0, slow=150)
    side = json.loads((where / "rosc-count-p128-e1-m3f.json").read_text()) if code == 0 else {}
    check(code == 0 and [(r["start"], r["records"]) for r in side["runs"]] == [(0, 64), (64, 64), (128, 64), (192, 8)] and side["losses"] == 3
          and [int(c, 16) >> 41 & 1 for c in side["run_ctrl"]] == [1, 1, 1, 0], f"{name}: a capture with three losses is four runs in the sidecar: {details(results)} {side.get('runs')}")
    recs = unpack((where / "rosc-count-p128-e1-m3f.bin").read_bytes(), 200)
    clocks, src, target = fake.ran[0]
    err = source_error(recs, [(r["start"], r["records"], r["cycle_start"], r["cycle_end"]) for r in side["runs"]], 128, 0x3f, src, clocks)
    check(err is None and all(a["cycle_end"] <= b["cycle_start"] for a, b in zip(side["runs"], side["runs"][1:])),
          f"{name}: every run of the file is a stretch of the source, the runs in order: {err}")
    joined = source_error(recs, [(0, 200, side["runs"][0]["cycle_start"], side["runs"][-1]["cycle_end"])], 128, 0x3f, src, clocks)
    check(joined is not None, f"{name}: negative control: the same file read as one run is not a stretch of the source")
    handoff(name, where / "rosc-count-p128-e1-m3f.bin", side)
    code, where, results, _ = phase(name + "-losses", settings="16x1", count=60, masks="0x3f", direct_count=0, bursts=0, ref_bursts=0, max_losses=2)
    check(code == 1 and "LOSSES" in details(results) and not list(where.glob("rosc-count-p*")), f"{name}: more losses than allowed fail the phase and leave no capture: {details(results)[:90]}")

    # a count that is wrong by sixteen in one clock: the meter flags it, the phase does not fail, and nobody can overlook it
    if be.exact:
        pair = dict(settings="128x1", count=300, masks="0x3f", direct_count=300, bursts=0, ref_bursts=0)
        code, where, results, _ = phase(name + "-clean", **pair)
        check(code == 0 and len(fake.ran) == 2, f"{name}: a capture of 300 records in each way of counting, to know its clocks: {details(results)}")
        at = [kept(target, 300)[150][1] for _, _, target in fake.ran]         # the clock of record 150 of the direct capture, and of the divided one
        clock = at[1] + 64
        check(at[0] - 128 * 100 < clock < at[0] + 128 * 100 and (clock - at[0]) % 128, f"{name}: one clock that is within both captures and at a record of neither")
        fake.options = dict(wrong=(4, clock))
        code, where, results, _ = phase(name + "-flagged", **pair)
        fake.options = {}
        log, files = (where / "phase.log").read_text(), ("rosc-direct-p128-e1-m3f", "rosc-count-p128-e1-m3f")
        sides = [json.loads((where / f"{stem}.json").read_text()) if code == 0 else {} for stem in files]
        found = [r["detail"] if code == 0 else {} for r in results[1:3]]
        check(code == 0 and [r["status"] for r in results] == ["PASS"] * 4
              and all(x["bad_counts"] == [3] and x["bad_rings"] == [[4]] and int(x["run_ctrl"][0], 16) >> 42 == (3 << 6 | 1 << 4) for x in sides)
              and [x["count_unit"] for x in sides] == [1, 2]
              and all((x["flagged_clocks"], x["flagged_rings"]) == (3, [4]) and "ring(s) [4] in 3 clock cycle(s)" in x["warning"] for x in found),
              f"{name}: a capture in which a count of ring 4 was wrong in one clock passes, in direct mode and in the divided one, with the three "
              f"flagged clocks and the ring in its sidecar and a warning in its case: {details(results)} {found}")
        check("direct mode" in found[0].get("warning", "") and "outside what the part guarantees" in found[0].get("warning", "")
              and "not expected" in found[1].get("warning", "") and "not expected" not in found[0].get("warning", ""),
              f"{name}: the warning of the capture in direct mode says why that mode may flag, and that of the divided one that it is not expected: {found}")
        last = log.splitlines()[-1] if log else ""
        check(results[-1]["name"] == "captures with flagged clocks" and results[-1]["status"] == "PASS"
              and results[-1]["detail"] == [dict(file="rosc-direct-p128-e1-m3f.bin", flagged_clocks=3, rings=[4], counting="direct"),
                                            dict(file="rosc-count-p128-e1-m3f.bin", flagged_clocks=3, rings=[4], counting="divided by two")]
              and last == "rosc-count: 2 capture(s) in which the meter flagged a count; rosc-direct-p128-e1-m3f.bin (direct): 3 clock(s), ring(s) [4]; "
                          "rosc-count-p128-e1-m3f.bin (divided by two): 3 clock(s), ring(s) [4]",
              f"{name}: and the phase's summary and its last line list both captures: {last}")
        handoff(name, where / "rosc-count-p128-e1-m3f.bin", sides[1])

    # every default but the number of records, which one variable scales: four settings, the two masks in their order
    if be.exact:
        code, where, results, _ = phase(name + "-defaults", settings="", count="", direct_count="", scale="0.0001", bursts=1, ref_bursts=1, ref_periods="")
        sides = [json.loads((where / f"rosc-count-p256-e{every}-m{mask}.json").read_text()) if code == 0 else {} for mask in ("0f", "3f") for every in (1, 4, 16, 64)]
        check(code == 0 and len(results) == 43 and [x["records"] for x in sides] == [100, 100, 100, 40] * 2 and all(x["scale"] == 0.0001 and x["count_unit"] == 2 for x in sides)
              and [r["name"].split(",")[1].strip() for r in results[1:11]] == ["ring mask 0x0f"] * 5 + ["ring mask 0x3f"] * 5
              and all(x["for_bound"] is False for x in sides)
              and (where / "phase.log").read_text().count("for bring-up, this capture cannot carry a bound") == 8,
              f"{name}: with the default settings and KARU_BOARD_ROSC_SCALE=0.0001 the phase takes 100, 100, 100 and 40 records (defaults 1,000,000 and 400,000) "
              f"at 256, 1,024, 4,096 and 16,384 "
              f"clocks, first with ring mask 0x0f, then with 0x3f; each scaled capture is said, on the console and in its sidecar, to be for bring-up: "
              f"{details(results)}")
        sides = [json.loads((where / f"rosc-direct-p256-e4-m{mask}.json").read_text()) if code == 0 else {} for mask in ("0f", "3f")]
        check(["direct" in r["name"] for r in results[1:11]] == [False, True, False, False, False] * 2 and all("256 x 4 = 1024" in r["name"] for r in results[2:11:5])
              and [(x["records"], x["count_unit"], x["clocks_per_record"]) for x in sides] == [(10, 1, 1024)] * 2 and not list(where.glob("rosc-direct-p256-e[!4]*")),
              f"{name}: by default the setting with a record every 1,024 clocks is also captured in direct mode, 100,000 records times the scale, "
              "for each ring mask and just before the divided capture of that setting")
        refs = [json.loads((where / f"refbits/getnoise-burst-p{period}.json").read_text()) if code == 0 else {} for period in (1, 2, 4, 8, 16, 32, 64)]
        check([r["name"].split(",")[1].strip() for r in results[35:42]] == [f"period {period} clocks" for period in (1, 2, 4, 8, 16, 32, 64)]
              and [(x["period"], x["bursts"]) for x in refs] == [(period, 1) for period in (1, 2, 4, 8, 16, 32, 64)],
              f"{name}: by default the reference bits are taken at sampling periods of 1, 2, 4, 8, 16, 32 and 64 clocks, and the scale does not change their bursts")

    # refusals before anything is sent
    sims = fake.sims
    code, where, results, err = phase(name + "-analyse", argv=[str(out / "x.bin")])
    check(code == 1 and "analyses nothing" in err and "rosc_own.py" in err and "Traceback" not in err and not list(where.glob("rosc-count-*")),
          f"{name}: asked to work on a file, the phase refuses and names the analysis: {err[-120:]}")
    for variable, value, reason in (("settings", "0x4", "period of 1..256"), ("settings", "256x65537", "every 1..65536"), ("settings", "256", "not <period>x<every>"),
                                    ("settings", "256x4x2", "not <period>x<every>"), ("count", "0", "not in 1.."), ("count", "5,6,7", "3 numbers for 2 settings"),
                                    ("masks", "0x40", "not in 0..63"), ("masks", "all", "not a comma separated list"), ("max_losses", "48", "not in 0..47"), ("direct_count", "-1", "not in 0.."),
                                    ("bursts", "-1", "not in 0.."), ("scale", "0", "not a factor above zero"), ("scale", "a tenth", "not a factor above zero"),
                                    ("ref_bursts", "many", "not a comma separated list"), ("ref_periods", "0", "not in 1..256"), ("ref_periods", "1,512", "not in 1..256")):
        code, where, results, err = phase(name + "-setting", **{variable: value})
        check(code == 1 and f"KARU_BOARD_ROSC_{variable.upper()}" in err and reason in err and "Traceback" not in err and not list(where.glob("rosc-count-*")),
              f"{name}: {variable}={value} is refused before the phase connects: {err[-120:]}")
    code, where, results, err = phase(name + "-nofile", payload=None)
    check(code == 1 and "make dbg-rosc-count-fixture" in err and "Traceback" not in err and not list(where.glob("rosc-count-*")),
          f"{name}: without the payload in the artifact directory the phase says how to build it: {err[-120:]}")
    check(fake.sims == sims, f"{name}: none of these reached the target")

    # an image without the capture block: refused before anything is loaded
    fake.ctrl = 0
    code, where, results, _ = phase(name + "-no-block")
    fake.ctrl = MAGIC << 32 | (LOG2W + 4) << 8 | 0x10
    check(code == 1 and "no capture block in this image" in details(results) and fake.sims == sims and not list(where.glob("rosc-count-p*")),
          f"{name}: an image without the capture block fails the phase before the payload is loaded: {details(results)[:90]}")
    fake.ctrl &= ~0x10
    code, where, results, _ = phase(name + "-source-off")
    fake.ctrl |= 0x10
    check(code == 1 and "the noise source is off" in details(results) and fake.sims == sims, f"{name}: a noise source that is off fails the phase before the payload is loaded")
    # the payload's status decides where the stand-in's answer and the target disagree
    quick = dict(settings="128x1", count=20, masks="0x3f", direct_count=0, bursts=0, ref_bursts=0)     # two cases: the load, and the records
    fake.options = dict(block=False)
    code, where, results, _ = phase(name + "-payload-no-block", **quick)
    check(code == 1 and "NOBLOCK" in details(results) and not list(where.glob("rosc-*.bin")), f"{name}: a payload error status fails the phase and leaves no capture: {details(results)[:80]}")
    if be.exact:
        fake.options = dict(meter=False)
        code, where, results, _ = phase(name + "-no-meter", **quick)
        check(code == 1 and "NOMETER" in details(results) and "the image has no meter" in details(results) and not list(where.glob("rosc-*.bin")),
              f"{name}: an image without the meter: NOMETER fails every capture: {details(results)[:80]}")
    fake.options = dict(off=True)
    code, where, results, _ = phase(name + "-timeout", **dict(quick, bursts=1))
    fake.options = {}
    check(code == 1 and "TIMEOUT" in details(results) and "ABORTED" in details(results) and not list(where.glob("rosc-*.bin")),
          f"{name}: a source that gives no samples: TIMEOUT for the records, ABORTED for the bursts: {details(results)[:80]}")
    fake.precfg = PRE | LOCK
    code, where, results, _ = phase(name + "-locked", **quick)
    fake.precfg = PRE
    check(code == 1 and "LOCKED" in details(results), f"{name}: a locked configuration fails the phase: {details(results)[:80]}")
    fake.hang = True
    code, where, results, _ = phase(name + "-hang", **dict(quick, wait=1))
    fake.hang = False
    check(code == 1 and "still running" in details(results) and fake.state == "halted", f"{name}: a payload that does not stop is halted and fails the phase")

    # negative controls: the target's memory altered after the run
    result, table = LOAD - BASE + SYM["rosc_result"], LOAD - BASE + SYM["rosc_runs"]
    def alter(offset, change):
        def tamper(mem):
            struct.pack_into("<Q", mem, offset, change(struct.unpack_from("<Q", mem, offset)[0]) & M64)
        return tamper
    def exchange(mem):
        a, b = BUF - BASE + 16 * 5, BUF - BASE + 16 * 6
        mem[a:a + 16], mem[b:b + 16] = mem[b:b + 16], mem[a:a + 16]
    for what, tamper, caught in (("a source left in test mode", alter(result + 8 * FIELDS.index("noise_after"), lambda v: 1 << 31 | 1), "test mode left"),
                                 ("a meter that still answers", alter(result + 8 * FIELDS.index("mctrl_after"), lambda v: 0x3f0000), "the meter reads zero after test mode"),
                                 ("another ring mask than the one asked for", alter(result + 8 * FIELDS.index("mctrl"), lambda v: v ^ 1 << 20), "the control register of the meter, read back"),
                                 ("another period", alter(result + 8 * FIELDS.index("period_used"), lambda v: 127), "the period the hardware used"),
                                 ("a changed mentropycfg", alter(result + 8 * FIELDS.index("cfg_after"), lambda v: v ^ 1), "mentropycfg as it was"),
                                 ("fewer records than asked for", alter(result + 8, lambda v: v - 1), "records stored"),
                                 ("a run table that does not cover the records", alter(table + 8, lambda v: v - 1), "the runs cover the records"),
                                 ("a run that cannot have been complete", alter(table + 24, lambda v: v - 20 * 128), "no run ended sooner than its records take"),
                                 ("a run that took too long", alter(table + 24, lambda v: v + 8192), "no run took longer than its records take"),
                                 ("a record with the loss flag", alter(BUF - BASE + 16 * 7, lambda v: v | 1 << 62), "every record has its valid flag and no loss flag"),
                                 ("a record without the valid flag", alter(BUF - BASE + 16 * 7, lambda v: v & ~(1 << 63)), "every record has its valid flag and no loss flag"),
                                 ("two records exchanged", exchange, "the sequence numbers of run 0 follow each other")):
        fake.tamper = tamper
        code, where, results, _ = phase(name + "-tamper", **quick)
        check(code == 1 and caught in details(results) and not list(where.glob("rosc-*.bin")), f"{name}: {what} fails the phase at \"{caught}\": {details(results)[:100]}")
    fake.tamper = None

# ------------------------------------------------------------------ main ----
tally = []
for target in [Model] + ([] if args.offline else [Simulation]):
    be, before = target(), checks
    if not be.exact:
        check(be.rings.agrees(20000), "the rings of the bench as this test steps them are noise_model.py's own counts, lane bits and reference bits")
    payload_cases(be)
    middle = checks
    phase_cases(be)
    tally.append(f"{be.name}: {middle - before} payload, {checks - middle} capture phase")
summary = f"({checks} checks: {'; '.join(tally)}; {bench_runs} bench runs)" + "".join(f"; NOT RUN: {x}" for x in skipped)
if args.offline:
    print(f"rosc count self-test, model only, the SoC simulation not run: PASS {summary}")
else:
    print(f"rosc count self-test: PASS {summary}")
sys.exit(0)
