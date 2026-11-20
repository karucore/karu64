#!/usr/bin/env python3
"""The health tests of rtl/karu_entropy.v, in Python, and what follows from them.

This is the reference model of the block's health logic: the two tests on the
4-bit symbol (SP 800-90B sections 4.4.1 and 4.4.2), the lane tests (repetition
at lags 1 to 4, adaptive proportion), the start-up test of 1024 symbols, the
strike count and the alarm. make entropy-test runs the RTL and this model on
the same symbols and compares every failure (test/tb_entropy_replay.sv).

    entropy_health.py cutoffs [--h 3.0] [--h-lane 0.75] [--alpha 40]
        the cutoffs for a claim of H bits per symbol and h per lane bit at a
        false-alarm probability of 2^-alpha per test, the probability each
        cutoff really has at that claim, and how often a source of four
        independent lanes with the measured bias would trip each test and
        any of them

    entropy_health.py replay [--cfg HEX | cutoff options] [--rows N] [--events FILE] FILE...
        replay captures through the model: failures, and the largest count
        each test reached. Files are GetNoise captures (bit 7 marks the first
        symbol of a run; each run is replayed from a fresh start-up test) or,
        with --raw, one 4-bit symbol per byte in one run, or with --rows N in
        runs of N symbols (restart data: one row per restart). --events
        writes the failure list of the first file in the format of the RTL
        bench: every run of it, indices counted from the start of the file,
        then one line with its length

    entropy_health.py criteria [--h 3.0] [cutoff options] [--trials N]
        SP 800-90B section 4.5, (a) and (b), simulated against the model, and
        the failure modes of section 4.3 item 8: a stuck lane, lanes with a
        pattern of period 2, 3 and 4, a biased lane, a stuck symbol. A case
        counts only if the healthy symbols before the fault raise no failure
        and the failure comes while the fault lasts

Cutoff options: --srct --sapt --rct --apt --strikes --calm, or --cfg with a
mentropycfg value. Without them the cutoffs follow from --h, --h-lane, --alpha.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, json, math, random, sys
from fractions import Fraction
from math import comb

BIST, RUN, DEAD = 0, 1, 2
STARTUP, SWIN, LWIN = 1024, 512, 1024
RATE = 75e6 / 4096                              # kept symbols per second: 75 MHz, 256 clocks, k = 16

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
    """The probability that a window whose first symbol has probability p reaches
    the count c: the first symbol always counts, so the count is 1 + B(W-1, p)."""
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
    trials where the hardware has W-1 after the first symbol, and can be one
    less than apt_cutoff()."""
    p = prob(2.0**-h); target = Fraction(1, 2**alpha_log2); tail = Fraction(0)
    for c in range(window, -1, -1):
        t = Fraction(comb(window, c)) * p**c * (1 - p)**(window - c)
        if tail + t > target:
            return 1 + c
        tail += t
    return 1

def cutoffs(h, h_lane, alpha_log2):
    return dict(srct=rct_cutoff(h, alpha_log2), sapt=apt_cutoff(h, alpha_log2, SWIN),
                rct=rct_cutoff(h_lane, alpha_log2), apt=apt_cutoff(h_lane, alpha_log2, LWIN))

def cfg_fields(v):
    """The fields of a mentropycfg value."""
    return dict(interval=v & 0xffff, rct=(v >> 16) & 0x3ff, apt=(v >> 26) & 0x7ff, srct=(v >> 37) & 0x7f,
                sapt=(v >> 44) & 0x3ff, strikes=(v >> 54) & 7, calm=(v >> 57) & 31, lock=v >> 63)

def cfg_value(srct, sapt, rct, apt, strikes, calm, interval=0, lock=0):
    return lock << 63 | calm << 57 | strikes << 54 | sapt << 44 | srct << 37 | apt << 26 | rct << 16 | interval

# ---- the model ----

class Health:
    """One instance is the health logic after a reset. step() takes one kept
    symbol outside test mode and returns None, or the failure as a dict."""
    def __init__(self, srct, sapt, rct, apt, strikes=3, calm=24):
        self.c = dict(srct=srct, sapt=sapt, rct=rct, apt=apt, strikes=strikes, calm=calm)
        self.state, self.bist, self.strikes, self.calm, self.alarm, self.fails = BIST, 0, 0, 0, 0, 0
        self.cause = self.lanes = self.lags = 0
        self.hist = [0, 0, 0, 0]; self.lref = self.sref = 0
        self.peak = dict(srct=0, sapt=0, rct=[0] * 4, rct_lag=[0] * 4, apt=[0] * 4)   # rct: per lane at lag 1; rct_lag: per lag, any lane
        self.clear()

    def clear(self):
        self.win = self.seen = self.srct_c = self.sapt_c = 0
        self.rct_c = [0] * 16; self.apt_c = [0] * 4

    def restart(self):                          # a configuration write, or test mode entered or left
        if self.state != DEAD:
            self.state, self.bist = BIST, 0
        self.calm = 0
        self.clear()

    def poll(self):                             # a seed access; the authentication port's is not one
        self.alarm = 0

    def stat(self):                             # the mentropystat value
        return (self.fails << 32 | self.lags << 16 | self.lanes << 12 | self.cause << 8 |
                self.strikes << 4 | self.alarm << 2 | self.state)

    def step(self, x):
        if self.state == DEAD:
            return None
        c, h = self.c, self.hist
        srct_n = self.srct_c + 1 if self.seen and x == h[0] else 1
        sapt_n = 1 if self.win % SWIN == 0 else self.sapt_c + (x == self.sref)
        rct_n, apt_n = [0] * 16, [0] * 4
        for l in range(4):
            b = (x >> l) & 1
            for g in range(4):
                rct_n[4 * l + g] = self.rct_c[4 * l + g] + 1 if self.seen > g and b == (h[g] >> l) & 1 else 1
            apt_n[l] = 1 if self.win == 0 else self.apt_c[l] + (b == (self.lref >> l) & 1)
        rct_fail = [n >= c['rct'] for n in rct_n]
        apt_fail = [n >= c['apt'] for n in apt_n]
        cause = (srct_n >= c['srct']) | (sapt_n >= c['sapt']) << 1 | any(rct_fail) << 2 | any(apt_fail) << 3
        self.peak['srct'] = max(self.peak['srct'], srct_n); self.peak['sapt'] = max(self.peak['sapt'], sapt_n)
        for l in range(4):
            self.peak['rct'][l] = max(self.peak['rct'][l], rct_n[4 * l])        # lag 1: the longest run
            self.peak['apt'][l] = max(self.peak['apt'][l], apt_n[l])
            for g in range(4):
                self.peak['rct_lag'][g] = max(self.peak['rct_lag'][g], rct_n[4 * l + g])
        if cause:
            fatal = self.state == BIST or self.strikes + 1 >= c['strikes']
            self.cause = cause
            self.lanes = sum((any(rct_fail[4 * l:4 * l + 4]) or apt_fail[l]) << l for l in range(4))
            self.lags = sum(any(rct_fail[4 * l + g] for l in range(4)) << g for g in range(4))
            self.fails = min(self.fails + 1, 0xffff)
            self.calm = 0
            if self.state == RUN:               # a running failure: alarm and strike, the fatal one too
                self.alarm = 1
                self.strikes += 1
            self.state, self.bist = (DEAD if fatal else BIST), 0
            self.clear()
            return dict(cause=cause, lanes=self.lanes, lags=self.lags, fatal=fatal)
        self.seen = min(self.seen + 1, 4)
        self.hist = [x] + h[:3]
        if self.win == 0: self.lref = x
        if self.win % SWIN == 0: self.sref = x
        self.win = (self.win + 1) % LWIN
        self.srct_c, self.sapt_c, self.rct_c, self.apt_c = srct_n, sapt_n, rct_n, apt_n
        if self.strikes:
            self.calm += 1
            if (self.calm >> c['calm']) & 1:
                self.strikes = self.calm = 0
        if self.state == BIST:
            self.bist += 1
            if self.bist == STARTUP: self.state = RUN
        return None

def events(symbols, poll=0, rows=0, **cut):
    """Replay one run. Returns the model and the list of (index, mentropystat)
    at every failure, index counting symbols from 0. With poll = n there is a
    seed access in the cycle of every n-th symbol; as in the RTL, a running
    failure in that cycle wins over it. With rows = n the source is reset
    before every n-th symbol (restart data); the model returned is the last
    row's, carrying the largest counts of all rows."""
    m = Health(**cut); out = []
    for i, x in enumerate(symbols):
        if rows and i and i % rows == 0:
            peak = m.peak; m = Health(**cut); m.peak = peak
        running = m.state == RUN
        failure = m.step(x)
        if poll and i % poll == poll - 1 and not (failure and running): m.poll()
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

CAUSES = ('symbol repetition', 'symbol proportion', 'lane repetition', 'lane proportion')

def describe(stat):
    cause = (stat >> 8) & 15
    return dict(state=('start-up', 'running', 'dead')[stat & 3], alarm=(stat >> 2) & 1, strikes=(stat >> 4) & 7,
                cause=[n for i, n in enumerate(CAUSES) if cause >> i & 1],
                lanes=[l for l in range(4) if stat >> (12 + l) & 1], lags=[g + 1 for g in range(4) if stat >> (16 + g) & 1],
                failures=(stat >> 32) & 0xffff)

# ---- false alarms of a healthy source ----

def log10(x):
    """log10 of a positive Fraction, also where a float would underflow."""
    return math.log10(x.numerator) - math.log10(x.denominator)

def interval(per_symbol):
    """The mean time between events of this probability per kept symbol."""
    if per_symbol <= 0: return 'never'
    seconds = -log10(per_symbol) - math.log10(RATE)                     # log10
    for unit, d in (('years', 365.25 * 86400), ('days', 86400), ('hours', 3600), ('minutes', 60), ('seconds', 1)):
        if seconds >= math.log10(d):
            e = seconds - math.log10(d)
            return f'{10**e:.3g} {unit}' if e < 6 else f'10^{e:.0f} {unit}'
    return f'{10**seconds:.3g} seconds'

def false_alarms(cut, p_lane=Fraction(509, 1000)):
    """The probability per kept symbol that each test raises an alarm, and that
    any does, for a source of four independent lanes whose bits are independent
    with P(more likely value) = p_lane (0.509 is the largest lane bias of the
    2026-11-19 captures). For that source the terms are exact:

    repetition  a count reaches C when exactly C - 1 comparisons in a row
                matched: Q(C - 1) - Q(C), with Q(m) the probability of m
                matches in a row. At lag g the m + g bits involved fall into g
                interleaved classes, each constant: Q(m) is the product over
                the classes of p^L + q^L. On the symbol the lanes multiply.
    proportion  per window, the sum over the first symbol's value of
                P(value) P(1 + B(W-1, P(value)) >= C); per symbol, that over W.

    The lane figures add the terms over four lanes (and four lags), and 'any'
    adds the four tests. Those events overlap, so the lane figures and 'any'
    are upper bounds on the probability of an alarm under this model."""
    p, q = p_lane, 1 - p_lane
    def same(n): return p**n + q**n                                       # n bits of one lane all equal
    def lane_run(m, g):                                                    # m lag-g matches in a row
        sizes = [(m + g - r + g - 1) // g for r in range(g)]               # class sizes of m + g bits
        out = Fraction(1)
        for n in sizes: out *= same(n)
        return out
    c = cut
    sym_rep = same(c['srct'])**4 - same(c['srct'] + 1)**4                  # four lanes at lag 1
    sym_prop = Fraction(0)
    for ones in range(5):                                                  # symbols by their number of likely bits
        ps = p**ones * q**(4 - ones)
        sym_prop += comb(4, ones) * ps * binom_tail(SWIN - 1, ps, c['sapt'] - 1)
    lane_rep = 4 * sum(lane_run(c['rct'] - 1, g) - lane_run(c['rct'], g) for g in (1, 2, 3, 4))
    lane_prop = 4 * (p * binom_tail(LWIN - 1, p, c['apt'] - 1) + q * binom_tail(LWIN - 1, q, c['apt'] - 1))
    rates = dict(symbol_repetition=sym_rep, symbol_proportion=sym_prop / SWIN,
                 lane_repetition=lane_rep, lane_proportion=lane_prop / LWIN)
    rates['any'] = sum(rates.values())
    return {k: dict(log2_probability_per_symbol=round(log10(v) / math.log10(2), 1), every=interval(v)) for k, v in rates.items()}

def at_the_claim(cut, h, h_lane):
    """The alarm probability of each cutoff for a source exactly at the claim,
    as a multiple of the 2^-40 target: per run start for a repetition count,
    per window for a proportion."""
    return dict(
        symbol_repetition=float(prob(2.0**-h)**(cut['srct'] - 1) * 2**40),
        symbol_proportion=float(apt_alarm(cut['sapt'], 2.0**-h, SWIN) * 2**40),
        lane_repetition=float(prob(2.0**-h_lane)**(cut['rct'] - 1) * 2**40),
        lane_proportion=float(apt_alarm(cut['apt'], 2.0**-h_lane, LWIN) * 2**40))

# ---- SP 800-90B section 4.5 and the failure modes of section 4.3 item 8 ----

def healthy(rng, n):
    return [rng.randrange(16) for _ in range(n)]

def detects(lead, fault, tail, cut):
    """One case: healthy symbols (lead), the fault, healthy symbols again (tail).
    Returns the position in the fault, from 1, of the first failure, if the
    lead raised none and the first failure came during the fault; 0 if the
    lead failed (the case does not count); None if the fault was not detected
    while it lasted."""
    m = Health(**cut)
    for x in lead:
        if m.step(x): return 0
    for i, x in enumerate(fault):
        if m.step(x): return i + 1
    return None

def criteria(h, cut, trials, rng):
    out = {}
    lead_n = STARTUP + 512
    def run(cases, fault_of, limit=None):
        """cases tries; a try whose lead-in fails is repeated, at most 3 * cases."""
        done = hits = spoiled = worst = 0
        for _ in range(3 * cases):
            if done == cases: break
            at = detects(healthy(rng, lead_n), fault_of(), [], cut)
            if at == 0: spoiled += 1; continue
            done += 1
            if at is not None and (limit is None or at <= limit):
                hits += 1; worst = max(worst, at)
        return dict(trials=done, detected=hits, latest_detection=worst, lead_in_failures=spoiled)
    # (a) a symbol repeated more than 100/H times; the failure must come within the repeats
    a = []
    for n in sorted({math.floor(100 / h) + 1, math.ceil(100 / h) + 1}):
        r = run(trials, lambda: [rng.randrange(16)] * n)
        a.append(dict(repeats=n, required=0.99, certain=cut['srct'] <= n, **r))
    out['a_repeated_symbol'] = a
    # (b) one symbol at P* = 2^(-H/2), the others uniform; the failure must come within 50,000 symbols
    p_star = 2 ** (-h / 2)
    def shifted():
        v = rng.randrange(16); other = [x for x in range(16) if x != v]
        return [v if rng.random() < p_star else rng.choice(other) for _ in range(50000)]
    out['b_probability_shift'] = dict(p=p_star, samples=50000, required=0.5, **run(max(20, trials // 10), shifted))
    # failure modes: each must be detected while it lasts, within `limit` symbols
    modes = {}
    def lane_mode(name, bit_at, limit):
        total = dict(trials=0, detected=0, latest_detection=0, lead_in_failures=0)
        for lane in range(4):
            r = run(max(1, trials // 20),
                    lambda: [(x & ~(1 << lane)) | (bit_at(i) << lane) for i, x in enumerate(healthy(rng, limit))], limit)
            for k in total: total[k] = max(total[k], r[k]) if k == 'latest_detection' else total[k] + r[k]
        modes[name] = dict(limit=limit, **total)
    lane_mode('lane_stuck_at_0', lambda i: 0, cut['rct'] + 4)
    lane_mode('lane_stuck_at_1', lambda i: 1, cut['rct'] + 4)
    lane_mode('lane_period_2', lambda i: i & 1, cut['rct'] + 4)
    lane_mode('lane_period_3', lambda i: int(i % 3 == 0), cut['rct'] + 4)
    lane_mode('lane_period_4', lambda i: int(i % 4 < 2), cut['rct'] + 4)
    lane_mode('lane_period_4_one_in_four', lambda i: int(i % 4 == 0), cut['rct'] + 4)
    p_bias = min(0.999, (cut['apt'] + 40) / LWIN)           # a lane biased beyond its proportion cutoff
    lane_mode(f'lane_biased_to_{p_bias:.3f}', lambda i: int(rng.random() < p_bias), 8 * LWIN)
    modes['symbol_stuck'] = dict(limit=cut['srct'], **run(max(1, trials // 20), lambda: [rng.randrange(16)] * cut['srct'], cut['srct']))
    out['failure_modes'] = modes
    # and no alarm on healthy symbols
    m = Health(**cut); failed = None
    for i, x in enumerate(healthy(rng, 200000)):
        if m.step(x): failed = i; break
    out['healthy_symbols'] = dict(symbols=200000, failure=failed)
    return out

def verdict(report):
    ok = all(r['trials'] and r['detected'] >= r['required'] * r['trials'] for r in report['a_repeated_symbol'])
    b = report['b_probability_shift']; ok &= b['trials'] > 0 and b['detected'] >= b['required'] * b['trials']
    ok &= all(m['trials'] and m['detected'] == m['trials'] for m in report['failure_modes'].values())
    return bool(ok and report['healthy_symbols']['failure'] is None)

# ---- command line ----

def cut_of(a):
    cut = cutoffs(a.h, a.h_lane, a.alpha)
    cut.update(strikes=3, calm=24)
    if a.cfg is not None:
        f = cfg_fields(int(a.cfg, 0)); cut = {k: f[k] for k in ('srct', 'sapt', 'rct', 'apt', 'strikes', 'calm')}
    for k in ('srct', 'sapt', 'rct', 'apt', 'strikes', 'calm'):
        if getattr(a, k) is not None: cut[k] = getattr(a, k)
    return cut

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('mode', choices=('cutoffs', 'replay', 'criteria'))
    ap.add_argument('files', nargs='*')
    ap.add_argument('--h', type=float, default=3.0, help='claimed min-entropy per 4-bit symbol')
    ap.add_argument('--h-lane', type=float, default=0.75, help='min-entropy per lane bit behind the lane cutoffs')
    ap.add_argument('--alpha', type=int, default=40, help='false-alarm probability 2^-ALPHA, per test')
    ap.add_argument('--cfg', help='a mentropycfg value to take the cutoffs from')
    for k in ('srct', 'sapt', 'rct', 'apt', 'strikes', 'calm'): ap.add_argument('--' + k, type=int)
    ap.add_argument('--raw', action='store_true', help='files hold one 4-bit symbol per byte, one run')
    ap.add_argument('--rows', type=int, default=0, help='files hold 4-bit symbols in runs of ROWS: one row per restart')
    ap.add_argument('--events', help='replay: write the failures of the first file here, one "index stat" per line')
    ap.add_argument('--trials', type=int, default=200)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args()
    cut = cut_of(a)
    if a.mode == 'cutoffs':
        c = cutoffs(a.h, a.h_lane, a.alpha)
        rep = dict(h_per_symbol=a.h, h_per_lane_bit=a.h_lane, alpha_per_test=f'2^-{a.alpha}', cutoffs=c,
                   proportion_cutoffs_by_the_formula_of_4_4_2=dict(sapt=apt_cutoff_nist(a.h, a.alpha, SWIN),
                                                                    apt=apt_cutoff_nist(a.h_lane, a.alpha, LWIN)),
                   alarm_probability_at_the_claim_in_units_of_2_to_minus_40=at_the_claim(c, a.h, a.h_lane) if a.alpha == 40 else None,
                   mentropycfg_cutoff_fields=hex(cfg_value(c['srct'], c['sapt'], c['rct'], c['apt'], 0, 0)),
                   false_alarms_of_four_independent_lanes_at_bias_0_509=false_alarms(c),
                   section_4_5=dict(a_repeats_more_than=100 / a.h, b_probability=2 ** (-a.h / 2)))
        json.dump(rep, sys.stdout, indent=1); print()
        return 0
    if a.mode == 'criteria':
        rep = dict(h_per_symbol=a.h, cutoffs=cut, **criteria(a.h, cut, a.trials, random.Random(a.seed)))
        rep['verdict'] = 'PASS' if verdict(rep) else 'FAIL'
        json.dump(rep, sys.stdout, indent=1); print()
        return 0 if rep['verdict'] == 'PASS' else 1
    if not a.files: ap.error('replay needs capture files')
    rep = dict(cutoffs=cut, files=[]); failures = 0; exported = []; offset = 0; last = 0
    for n, f in enumerate(a.files):
        raw = open(f, 'rb').read()
        if a.rows:
            if any(b & 0xf0 for b in raw) or len(raw) % a.rows: raise ValueError(f'{f}: not rows of {a.rows} 4-bit symbols')
            runs = [list(raw[i:i + a.rows]) for i in range(0, len(raw), a.rows)]
        else:
            runs = runs_of(raw, a.raw)
        peak = dict(srct=0, sapt=0, rct=[0] * 4, rct_lag=[0] * 4, apt=[0] * 4); found = []; ended_dead = ended_running = 0
        for r, run in enumerate(runs):
            m, ev = events(run, **cut)
            found += [dict(run=r, symbol=i, **describe(s)) for i, s in ev]
            ended_dead += m.state == DEAD; ended_running += m.state == RUN
            peak['srct'] = max(peak['srct'], m.peak['srct']); peak['sapt'] = max(peak['sapt'], m.peak['sapt'])
            for l in range(4):
                peak['rct'][l] = max(peak['rct'][l], m.peak['rct'][l]); peak['apt'][l] = max(peak['apt'][l], m.peak['apt'][l])
                peak['rct_lag'][l] = max(peak['rct_lag'][l], m.peak['rct_lag'][l])
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
