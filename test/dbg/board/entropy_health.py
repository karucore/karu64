#!/usr/bin/env python3
"""The health tests of rtl/karu_entropy.v, in Python, and what follows from them.

This is the reference model of the block's health logic and of its delivery.
The noise-source sample is one bit: the selected lane (--lane, the strap
lane_i) of every kept 4-bit symbol. On it run the two approved tests of
SP 800-90B, binary: the repetition count (section 4.4.1), here at lags 1 to
4, and the adaptive proportion test with a window of 1024 (4.4.2). Then the
start-up test of 1024 samples, the strike count, the alarm, and the packing
of sixteen samples into a seed word. The other three lanes of a symbol reach
nothing here. make entropy-test runs the RTL and this model on the same
symbols and compares every failure and every word (test/tb_entropy_replay.sv).

    entropy_health.py cutoffs [--h 0.75] [--alpha 40]
        the cutoffs for a claim of h bits of min-entropy per sample at a
        false-alarm probability of 2^-alpha per test, the probability each
        cutoff really has at that claim, and how often a source of
        independent bits with the measured bias would trip each test and
        any of them

    entropy_health.py replay [--lane N] [--cfg HEX | cutoff options] [--rows N] [--events FILE] FILE...
        replay captures through the model: failures, and the largest count
        each test reached. Files hold 4-bit symbols, one per byte, and the
        model takes bit N of each (0 by default): GetNoise captures (bit 7
        marks the first symbol of a run; each run is replayed from a fresh
        start-up test) or, with --raw, one run, or with --rows N runs of N
        symbols (restart data: one row per restart). A file of single bits,
        one per byte, is a file of 4-bit symbols for lane 0. --events writes
        the failure list of the first file in the format of the RTL bench:
        every run of it, indices counted from the start of the file, then
        one line with its length

    entropy_health.py criteria [--h 0.75] [--lane N] [cutoff options] [--trials N]
        SP 800-90B section 4.5, (a) and (b), simulated against the model, and
        the failure modes of section 4.3 item 8 on the selected lane: stuck
        at 0 and at 1, patterns of period 2, 3 and 4, a bias. A case counts
        only if the healthy symbols before the fault raise no failure and
        the failure comes while the fault lasts. The same faults on the
        three other lanes must raise nothing: those lanes are not the source

Cutoff options: --rct --apt --strikes --calm, or --cfg with a mentropycfg
value. Without them the cutoffs follow from --h and --alpha.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, json, math, random, sys
from fractions import Fraction
from math import comb

BIST, RUN, DEAD = 0, 1, 2
STARTUP, WIN = 1024, 1024
WORD_BITS, FIFO_WORDS, BURST = 16, 8, 4
RATE = 75e6 / 4096                              # samples per second: 75 MHz, 256 clocks, k = 16
MASK64 = (1 << 64) - 1

# ---- cutoffs (SP 800-90B section 4.4) ----

def binom_tail(n, p, c):
    """P(B(n, p) >= c), exact; p a Fraction."""
    return sum(Fraction(comb(n, k)) * p**k * (1 - p)**(n - k) for k in range(max(c, 0), n + 1))

def prob(x):
    return Fraction(x).limit_denominator(10**15)

def rct_cutoff(h, alpha_log2):
    """Section 4.4.1: 1 + ceil(-log2(alpha) / H). A run of C has probability at
    most 2^(-H (C - 1)) <= alpha."""
    return 1 + math.ceil(alpha_log2 / h)

def apt_alarm(c, p, window):
    """The probability that a window whose first sample has probability p reaches
    the count c: the first sample always counts, so the count is 1 + B(W-1, p)."""
    return binom_tail(window - 1, prob(p), c - 1)

def apt_cutoff(h, alpha_log2, window):
    """The smallest cutoff whose alarm probability at min-entropy h is at most
    2^-alpha_log2, for the comparison the hardware makes (count >= cutoff)."""
    p = prob(2.0**-h); target = Fraction(1, 2**alpha_log2); tail = Fraction(0)
    for k in range(window - 1, -1, -1):         # tail = P(B(W-1, p) >= k)
        tail += Fraction(comb(window - 1, k)) * p**k * (1 - p)**(window - 1 - k)
        if tail > target:
            return k + 2
    return 1

def apt_cutoff_nist(h, alpha_log2, window):
    """Section 4.4.2 as printed: 1 + CRITBINOM(W, 2^-H, 1 - alpha). It takes W
    trials where the hardware has W-1 after the first sample, and can be one
    less than apt_cutoff()."""
    p = prob(2.0**-h); target = Fraction(1, 2**alpha_log2); tail = Fraction(0)
    for c in range(window, -1, -1):
        t = Fraction(comb(window, c)) * p**c * (1 - p)**(window - c)
        if tail + t > target:
            return 1 + c
        tail += t
    return 1

def cutoffs(h, alpha_log2):
    """The cutoffs of the two tests for h bits of min-entropy per sample (one bit)."""
    if not 0 < h <= 1: raise ValueError(f'h = {h}: the sample is one bit, so 0 < h <= 1')
    return dict(rct=rct_cutoff(h, alpha_log2), apt=apt_cutoff(h, alpha_log2, WIN))

def cfg_fields(v):
    """The fields of a mentropycfg value. [53:37] are reserved and read zero."""
    return dict(interval=v & 0xffff, rct=(v >> 16) & 0x3ff, apt=(v >> 26) & 0x7ff, reserved=(v >> 37) & 0x1ffff,
                strikes=(v >> 54) & 7, calm=(v >> 57) & 31, lock=v >> 63)

def cfg_value(rct, apt, strikes, calm, interval=0, lock=0):
    return lock << 63 | calm << 57 | strikes << 54 | apt << 26 | rct << 16 | interval

# ---- the model ----

class Health:
    """One instance is the block after a reset, with every symbol kept and
    outside test mode. step() takes one 4-bit symbol, of which the sample is
    bit `lane`, and returns None, or the failure as a dict. With access=True a
    seed access is made in the same clock cycle: self.word is then the word it
    took, or None."""
    def __init__(self, rct, apt, strikes=3, calm=24, lane=0, kshift=0):
        self.c = dict(rct=rct, apt=apt, strikes=strikes, calm=calm)
        self.lane, self.kshift = lane, kshift
        self.state, self.bist, self.strikes, self.calm, self.alarm, self.fails = BIST, 0, 0, 0, 0, 0
        self.cause = self.lanes = self.lags = 0
        self.hist = [0, 0, 0, 0]; self.ref = 0
        self.peak = dict(rct_lag=[0] * 4, apt=0)            # the largest counts: repetition per lag, proportion
        self.words, self.acc, self.word = 0, 0, None        # words taken by seed accesses, and a running check value of them
        self.clear()

    def clear(self):
        self.win = self.seen = self.apt_c = 0
        self.rct_c = [0] * 4
        self.part, self.fifo, self.burst = [], [], 0        # the word being packed, the buffered words, words owed to the open burst

    def restart(self):                          # a configuration write, or test mode entered or left
        if self.state != DEAD:
            self.state, self.bist = BIST, 0
        self.calm = 0
        self.clear()

    def poll(self):                             # a seed access between two samples; the authentication port's is not one
        self.step(None, access=True)

    def stat(self):                             # the mentropystat value
        return (self.fails << 32 | self.kshift << 22 | self.lane << 20 | self.lags << 16 | self.lanes << 12 |
                self.cause << 8 | self.strikes << 4 | self.alarm << 2 | self.state)

    def step(self, x, access=False):
        """One clock cycle: a kept symbol x (None: no symbol in this cycle),
        and a seed access or not. Everything is decided from the state before
        the cycle, as the registers of the RTL do."""
        c, h = self.c, self.hist
        sample = x is not None and self.state != DEAD
        running = self.state == RUN
        cause = 0
        if sample:
            b = (x >> self.lane) & 1
            rct_n = [self.rct_c[g] + 1 if self.seen > g and b == h[g] else 1 for g in range(4)]
            apt_n = 1 if self.win == 0 else self.apt_c + (b == self.ref)
            rct_fail = [n >= c['rct'] for n in rct_n]
            cause = any(rct_fail) << 2 | (apt_n >= c['apt']) << 3
            self.peak['apt'] = max(self.peak['apt'], apt_n)
            for g in range(4): self.peak['rct_lag'][g] = max(self.peak['rct_lag'][g], rct_n[g])
        # delivery: a failure wins over a read in its cycle, and a latched alarm takes the access
        self.word = None
        deliver = self.burst != 0 and running and not cause
        pop = deliver and access and not self.alarm
        take = sample and running and len(self.fifo) < FIFO_WORDS and not cause
        if running and not cause:
            if take:
                self.part.append(b)
                if len(self.part) == WORD_BITS:             # the first sample in bit 15, the last in bit 0
                    self.fifo.append(int(''.join(map(str, self.part)), 2)); self.part = []
            if pop:
                self.word = self.fifo.pop(0); self.burst -= 1
                self.words += 1; self.acc = (self.acc * 0x100000001b3 + self.word) & MASK64
            if self.burst == 0 and len(self.fifo) >= BURST: self.burst = BURST
        if access and not (cause and running): self.alarm = 0
        if not sample:
            return None
        if cause:
            fatal = self.state == BIST or self.strikes + 1 >= c['strikes']
            self.cause = cause
            self.lanes = 1 << self.lane
            self.lags = sum(rct_fail[g] << g for g in range(4))
            self.fails = min(self.fails + 1, 0xffff)
            self.calm = 0
            if running:                         # a running failure: alarm and strike, the fatal one too
                self.alarm = 1
                self.strikes += 1
            self.state, self.bist = (DEAD if fatal else BIST), 0
            self.clear()
            return dict(cause=cause, lanes=self.lanes, lags=self.lags, fatal=fatal)
        self.seen = min(self.seen + 1, 4)
        self.hist = [b] + h[:3]
        if self.win == 0: self.ref = b
        self.win = (self.win + 1) % WIN
        self.rct_c, self.apt_c = rct_n, apt_n
        if self.strikes:
            self.calm += 1
            if (self.calm >> c['calm']) & 1:
                self.strikes = self.calm = 0
        if self.state == BIST:
            self.bist += 1
            if self.bist == STARTUP: self.state = RUN
        return None

def events(symbols, poll=0, rows=0, lane=0, **cut):
    """Replay one run. Returns the model and the list of (index, mentropystat)
    at every failure, index counting symbols from 0. With poll = n there is a
    seed access in the cycle of every n-th symbol; as in the RTL, a running
    failure in that cycle wins over it. With rows = n the source is reset
    before every n-th symbol (restart data); the model returned is the last
    row's, carrying the largest counts and the words of all rows."""
    m = Health(lane=lane, **cut); out = []
    for i, x in enumerate(symbols):
        if rows and i and i % rows == 0:
            old = m; m = Health(lane=lane, **cut); m.peak, m.words, m.acc = old.peak, old.words, old.acc
        failure = m.step(x, access=bool(poll) and i % poll == poll - 1)
        if failure: out.append((i, m.stat()))
    return m, out

# ---- input ----

def runs_of(raw, plain):
    """The runs of consecutive symbols in a capture."""
    if plain:
        if any(b & 0xf0 for b in raw): raise ValueError('not a file of 4-bit symbols')
        return [list(raw)]
    runs, cur = [], []
    for i, b in enumerate(raw):
        if b & 0x70: raise ValueError(f'byte {i}: bits [6:4] set ({b:#x}): not a GetNoise capture')
        if i == 0 and not b & 0x80: raise ValueError('the first byte does not start a run')
        if b & 0x80 and cur: runs.append(cur); cur = []
        cur.append(b & 0x0f)
    if cur: runs.append(cur)
    return runs

CAUSES = {2: 'repetition', 3: 'proportion'}

def describe(stat):
    cause = (stat >> 8) & 15
    return dict(state=('start-up', 'running', 'dead')[stat & 3], alarm=(stat >> 2) & 1, strikes=(stat >> 4) & 7,
                cause=[n for i, n in CAUSES.items() if cause >> i & 1],
                lanes=[l for l in range(4) if stat >> (12 + l) & 1], lags=[g + 1 for g in range(4) if stat >> (16 + g) & 1],
                lane=(stat >> 20) & 3, kshift=(stat >> 22) & 3, failures=(stat >> 32) & 0xffff)

# ---- false alarms of a healthy source ----

def log10(x):
    """log10 of a positive Fraction, also where a float would underflow."""
    return math.log10(x.numerator) - math.log10(x.denominator)

def interval(per_sample):
    """The mean time between events of this probability per sample."""
    if per_sample <= 0: return 'never'
    seconds = -log10(per_sample) - math.log10(RATE)                     # log10
    for unit, d in (('years', 365.25 * 86400), ('days', 86400), ('hours', 3600), ('minutes', 60), ('seconds', 1)):
        if seconds >= math.log10(d):
            e = seconds - math.log10(d)
            return f'{10**e:.3g} {unit}' if e < 6 else f'10^{e:.0f} {unit}'
    return f'{10**seconds:.3g} seconds'

def false_alarms(cut, p_bit=Fraction(509, 1000)):
    """The probability per sample that each test raises an alarm, and that
    either does, for a source whose bits are independent with P(more likely
    value) = p_bit (0.509 is the largest lane bias of the 2026-11-19
    captures). For that source the terms are exact:

    repetition  a count reaches C when exactly C - 1 comparisons in a row
                matched: Q(C - 1) - Q(C), with Q(m) the probability of m
                matches in a row. At lag g the m + g bits involved fall into g
                interleaved classes, each constant: Q(m) is the product over
                the classes of p^L + q^L. The figure adds the four lags.
    proportion  per window, the sum over the first bit's value of
                P(value) P(1 + B(W-1, P(value)) >= C); per sample, that over W.

    The lags overlap and so do the two tests, so the repetition figure and
    'any' are upper bounds on the probability of an alarm under this model."""
    p, q = p_bit, 1 - p_bit
    def same(n): return p**n + q**n                                       # n bits all equal
    def run(m, g):                                                         # m lag-g matches in a row
        sizes = [(m + g - r + g - 1) // g for r in range(g)]               # class sizes of m + g bits
        out = Fraction(1)
        for n in sizes: out *= same(n)
        return out
    c = cut
    rep = sum(run(c['rct'] - 1, g) - run(c['rct'], g) for g in (1, 2, 3, 4))
    prop = p * binom_tail(WIN - 1, p, c['apt'] - 1) + q * binom_tail(WIN - 1, q, c['apt'] - 1)
    rates = dict(repetition=rep, proportion=prop / WIN)
    rates['any'] = sum(rates.values())
    return {k: dict(log2_probability_per_sample=round(log10(v) / math.log10(2), 1), every=interval(v)) for k, v in rates.items()}

def at_the_claim(cut, h):
    """The alarm probability of each cutoff for a source exactly at the claim,
    as a multiple of the 2^-40 target: per run start for the repetition count,
    per window for the proportion."""
    return dict(repetition=float(prob(2.0**-h)**(cut['rct'] - 1) * 2**40),
                proportion=float(apt_alarm(cut['apt'], 2.0**-h, WIN) * 2**40))

# ---- SP 800-90B section 4.5 and the failure modes of section 4.3 item 8 ----

def healthy(rng, n):
    return [rng.randrange(16) for _ in range(n)]

def on_lane(rng, lane, bit_at, n):
    """Healthy symbols with lane `lane` replaced by bit_at(i)."""
    return [(x & ~(1 << lane)) | (bit_at(i) << lane) for i, x in enumerate(healthy(rng, n))]

def detects(lead, fault, cut, lane):
    """One case: healthy symbols (lead), then the fault. Returns the position
    in the fault, from 1, of the first failure, if the lead raised none and
    the first failure came during the fault; 0 if the lead failed (the case
    does not count); None if the fault was not detected while it lasted."""
    m = Health(lane=lane, **cut)
    for x in lead:
        if m.step(x): return 0
    for i, x in enumerate(fault):
        if m.step(x): return i + 1
    return None

def criteria(h, cut, trials, rng, lane=0):
    out = {}
    lead_n = STARTUP + 512
    def run(cases, fault_of, limit=None, on=lane):
        """cases tries; a try whose lead-in fails is repeated, at most 3 * cases."""
        done = hits = spoiled = worst = 0
        for _ in range(3 * cases):
            if done == cases: break
            at = detects(healthy(rng, lead_n), fault_of(), cut, on)
            if at == 0: spoiled += 1; continue
            done += 1
            if at is not None and (limit is None or at <= limit):
                hits += 1; worst = max(worst, at)
        return dict(trials=done, detected=hits, latest_detection=worst, lead_in_failures=spoiled)
    # (a) a sample value repeated more than 100/H times; the failure must come within the repeats
    a = []
    for n in sorted({math.floor(100 / h) + 1, math.ceil(100 / h) + 1}):
        def repeated(n=n):
            v = rng.randrange(2)
            return on_lane(rng, lane, lambda i: v, n)
        a.append(dict(repeats=n, required=0.99, certain=cut['rct'] <= n, **run(trials, repeated)))
    out['a_repeated_sample'] = a
    # (b) one value at P* = 2^(-H/2); the failure must come within 50,000 samples
    p_star = 2 ** (-h / 2)
    def shifted():
        v = rng.randrange(2)
        return on_lane(rng, lane, lambda i: v if rng.random() < p_star else 1 - v, 50000)
    out['b_probability_shift'] = dict(p=p_star, samples=50000, required=0.5, **run(max(20, trials // 10), shifted))
    # failure modes of the selected lane: each must be detected while it lasts, within `limit` samples
    p_bias = min(0.999, (cut['apt'] + 40) / WIN)            # a bias beyond the proportion cutoff
    faults = (('stuck_at_0', lambda i: 0, cut['rct'] + 4), ('stuck_at_1', lambda i: 1, cut['rct'] + 4),
              ('period_2', lambda i: i & 1, cut['rct'] + 4), ('period_3', lambda i: int(i % 3 == 0), cut['rct'] + 4),
              ('period_4', lambda i: int(i % 4 < 2), cut['rct'] + 4),
              ('period_4_one_in_four', lambda i: int(i % 4 == 0), cut['rct'] + 4),
              (f'biased_to_{p_bias:.3f}', lambda i: int(rng.random() < p_bias), 8 * WIN))
    modes = {}
    for name, bit_at, limit in faults:
        modes[name] = dict(limit=limit, **run(max(4, trials // 5), lambda: on_lane(rng, lane, bit_at, limit), limit))
    out['failure_modes'] = modes
    # the same faults on the three reference lanes, all at once: no failure, they are not the source
    others = [l for l in range(4) if l != lane]
    quiet = {}
    for name, bit_at, limit in faults:
        m = Health(lane=lane, **cut); failed = None
        seq = healthy(rng, lead_n + limit)
        for l in others: seq = [(x & ~(1 << l)) | (bit_at(i) << l) for i, x in enumerate(seq)]
        for i, x in enumerate(seq):
            if m.step(x): failed = i; break
        quiet[name] = dict(lanes=others, samples=len(seq), failure=failed)
    out['reference_lanes'] = quiet
    # and no alarm on healthy symbols
    m = Health(lane=lane, **cut); failed = None
    for i, x in enumerate(healthy(rng, 200000)):
        if m.step(x): failed = i; break
    out['healthy_symbols'] = dict(symbols=200000, failure=failed)
    return out

def verdict(report):
    ok = all(r['trials'] and r['detected'] >= r['required'] * r['trials'] for r in report['a_repeated_sample'])
    b = report['b_probability_shift']; ok &= b['trials'] > 0 and b['detected'] >= b['required'] * b['trials']
    ok &= all(m['trials'] and m['detected'] == m['trials'] for m in report['failure_modes'].values())
    ok &= all(m['failure'] is None for m in report['reference_lanes'].values())
    return bool(ok and report['healthy_symbols']['failure'] is None)

# ---- command line ----

CUT_KEYS = ('rct', 'apt', 'strikes', 'calm')

def cut_of(a):
    cut = cutoffs(a.h, a.alpha)
    cut.update(strikes=3, calm=24)
    if a.cfg is not None:
        f = cfg_fields(int(a.cfg, 0)); cut = {k: f[k] for k in CUT_KEYS}
    for k in CUT_KEYS:
        if getattr(a, k) is not None: cut[k] = getattr(a, k)
    return cut

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('mode', choices=('cutoffs', 'replay', 'criteria'))
    ap.add_argument('files', nargs='*')
    ap.add_argument('--h', type=float, default=0.75, help='claimed min-entropy per sample; the sample is one bit')
    ap.add_argument('--alpha', type=int, default=40, help='false-alarm probability 2^-ALPHA, per test')
    ap.add_argument('--lane', type=int, default=0, choices=range(4), help='the lane that is the noise source: bit LANE of a 4-bit symbol')
    ap.add_argument('--cfg', help='a mentropycfg value to take the cutoffs from')
    for k in CUT_KEYS: ap.add_argument('--' + k, type=int)
    ap.add_argument('--raw', action='store_true', help='files hold one 4-bit symbol per byte, one run')
    ap.add_argument('--rows', type=int, default=0, help='files hold 4-bit symbols in runs of ROWS: one row per restart')
    ap.add_argument('--events', help='replay: write the failures of the first file here, one "index stat" per line')
    ap.add_argument('--trials', type=int, default=200)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args()
    if not 0 < a.h <= 1: ap.error('--h is per sample, and the sample is one bit: 0 < h <= 1')
    cut = cut_of(a)
    if a.mode == 'cutoffs':
        c = cutoffs(a.h, a.alpha)
        rep = dict(h_per_sample=a.h, alpha_per_test=f'2^-{a.alpha}', cutoffs=c,
                   proportion_cutoff_by_the_formula_of_4_4_2=apt_cutoff_nist(a.h, a.alpha, WIN),
                   alarm_probability_at_the_claim_in_units_of_2_to_minus_40=at_the_claim(c, a.h) if a.alpha == 40 else None,
                   mentropycfg_cutoff_fields=hex(cfg_value(c['rct'], c['apt'], 0, 0)),
                   false_alarms_of_independent_bits_at_bias_0_509=false_alarms(c),
                   section_4_5=dict(a_repeats_more_than=100 / a.h, b_probability=2 ** (-a.h / 2)))
        json.dump(rep, sys.stdout, indent=1); print()
        return 0
    if a.mode == 'criteria':
        rep = dict(h_per_sample=a.h, lane=a.lane, cutoffs=cut, **criteria(a.h, cut, a.trials, random.Random(a.seed), a.lane))
        rep['verdict'] = 'PASS' if verdict(rep) else 'FAIL'
        json.dump(rep, sys.stdout, indent=1); print()
        return 0 if rep['verdict'] == 'PASS' else 1
    if not a.files: ap.error('replay needs capture files')
    rep = dict(lane=a.lane, cutoffs=cut, files=[]); failures = 0; exported = []; offset = 0; last = 0
    for n, f in enumerate(a.files):
        raw = open(f, 'rb').read()
        if a.rows:
            if any(b & 0xf0 for b in raw) or len(raw) % a.rows: raise ValueError(f'{f}: not rows of {a.rows} 4-bit symbols')
            runs = [list(raw[i:i + a.rows]) for i in range(0, len(raw), a.rows)]
        else:
            runs = runs_of(raw, a.raw)
        peak = dict(rct_lag=[0] * 4, apt=0); found = []; ended_dead = ended_running = 0
        for r, run in enumerate(runs):
            m, ev = events(run, lane=a.lane, **cut)
            found += [dict(run=r, symbol=i, **describe(s)) for i, s in ev]
            ended_dead += m.state == DEAD; ended_running += m.state == RUN
            peak['apt'] = max(peak['apt'], m.peak['apt'])
            for g in range(4): peak['rct_lag'][g] = max(peak['rct_lag'][g], m.peak['rct_lag'][g])
            if n == 0:                          # the event list of the first file: every run, indices counted over the file
                exported += [(offset + i, s) for i, s in ev]; offset += len(run); last = m.stat()
        if n == 0 and a.events:
            with open(a.events, 'w') as out:
                for i, s in exported: out.write(f'{i} {s:016x}\n')
                out.write(f'end {offset} {last:016x}\n')
        failures += len(found)
        rep['files'].append(dict(file=f, symbols=sum(map(len, runs)), runs=len(runs), failures=len(found),
                                 runs_ended_dead=ended_dead, runs_ended_running=ended_running,
                                 largest_counts=peak, first_failures=found[:20]))
    rep['failures'] = failures
    json.dump(rep, sys.stdout, indent=1); print()
    return 0                                    # a report: failures are data, not an error

if __name__ == '__main__':
    sys.exit(main())
