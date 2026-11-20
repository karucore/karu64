#!/usr/bin/env python3
"""SP 800-90B health-test replay and alternative-test check for the Karu64 noise source.

Offline; reads GetNoise capture files (one byte per symbol, bits [3:0] the four
lanes, bit 7 set on the first symbol of each run of consecutive samples). Each
run is replayed separately: samples are never joined across a run boundary,
and the tests start afresh in every run, as they do after a restart. For each
file:

  * the tests of the images up to 85f07e58 (rtl/karu_entropy.v before the
    redesign of 2026-11-19): per lane, binary, repetition count with cutoff
    --rct (41) and adaptive proportion over non-overlapping windows of 1024
    with cutoff --apt (821); a failure is counted as soon as a count reaches
    its cutoff, also in a final partial window, as that hardware does. The
    tests of the current RTL are modelled in entropy_health.py;
  * the approved tests of SP 800-90B section 4.4 applied to the 4-bit symbol
    (the noise source sample): repetition count with C = 1 + ceil(20/H) and
    adaptive proportion with W = 512, C = 1 + CRITBINOM(512, 2^-H, 1 - 2^-20),
    for the per-symbol min-entropy given with --h;

and, without data, the alternative-test criteria of section 4.5 at that H,
simulated for the per-lane tests as implemented and, for comparison, for the
4-bit tests:

  (a) a symbol value repeated more than 100/H consecutive times is detected
      with probability >= 99 %; both readings of "more than" are run:
      floor(100/H) + 1 and ceil(100/H) + 1 repetitions (they differ only when
      100/H is not an integer);
  (b) if one symbol value's probability rises to P* = 2^(-H/2), the change is
      detected with probability >= 50 % within 50,000 samples. Simulated with
      the degraded value 0000 at probability exactly P* and the other fifteen
      values uniform. Detection here is statistical, for either test set.

Usage: sp80090b_health.py --h 3.526 FILE...   (writes a JSON report to stdout)
"""
import argparse, json, math, random, sys
from math import comb

ALPHA_LOG2 = 20

def critbinom(n, p, q):
    s = 0.0
    for k in range(n + 1):
        s += comb(n, k) * p**k * (1 - p)**(n - k)
        if s >= q:
            return k
    return n

def symbol_cutoffs(h):
    return 1 + math.ceil(ALPHA_LOG2 / h), 1 + critbinom(512, 2**-h, 1 - 2**-ALPHA_LOG2)

def runs_of(raw):
    """Split a capture into its runs of consecutive samples (bit 7 starts a run)."""
    runs, cur = [], []
    for i, b in enumerate(raw):
        if b & 0x70:
            raise ValueError(f'byte {i}: bits [6:4] set ({b:#x}): not a GetNoise capture')
        if b & 0x80 and cur:
            runs.append(cur); cur = []
        if i == 0 and not b & 0x80:
            raise ValueError('the first byte does not start a run')
        cur.append(b & 0x0f)
    if cur: runs.append(cur)
    return runs

def rct(seq, c):
    """Longest repetition and the number of samples at which the count is >= c."""
    run = best = 1 if seq else 0; fails = 0
    for i in range(1, len(seq)):
        run = run + 1 if seq[i] == seq[i - 1] else 1
        best = max(best, run); fails += run >= c
    return best, fails

def apt(seq, w, c):
    """Largest window count and failures: non-overlapping windows of w, the
    count checked after every sample, including in a final partial window."""
    best = fails = 0
    for s in range(0, len(seq), w):
        ref = seq[s]; b = 1; failed = False
        for x in seq[s + 1:s + w]:
            if x == ref:
                b += 1
                if b >= c and not failed:
                    fails += 1; failed = True
        best = max(best, b)
    return best, fails

def replay(runs, rct_c, apt_c, s_rct, s_apt):
    lanes = []
    for l in range(4):
        r_best = r_fail = a_best = a_fail = 0
        for run in runs:
            bits = [(s >> l) & 1 for s in run]
            rb, rf = rct(bits, rct_c); ab, af = apt(bits, 1024, apt_c)
            r_best = max(r_best, rb); r_fail += rf; a_best = max(a_best, ab); a_fail += af
        lanes.append(dict(lane=l, max_repetition=r_best, rct_failures=r_fail,
                          max_apt_count=a_best, apt_failures=a_fail))
    r_best = r_fail = a_best = a_fail = 0
    for run in runs:
        rb, rf = rct(run, s_rct); ab, af = apt(run, 512, s_apt)
        r_best = max(r_best, rb); r_fail += rf; a_best = max(a_best, ab); a_fail += af
    sym = dict(rct_cutoff=s_rct, max_repetition=r_best, rct_failures=r_fail,
               apt_window=512, apt_cutoff=s_apt, max_apt_count=a_best, apt_failures=a_fail)
    return lanes, sym

def lanes_detect(seq, rct_c, apt_c):
    for l in range(4):
        bits = [(s >> l) & 1 for s in seq]
        if rct(bits, rct_c)[1] or apt(bits, 1024, apt_c)[1]:
            return True
    return False

def symbols_detect(seq, s_rct, s_apt):
    return bool(rct(seq, s_rct)[1] or apt(seq, 512, s_apt)[1])

def criterion_a(n, rct_c, apt_c, s_rct, s_apt, trials, rng):
    lane_hits = sym_hits = 0
    for _ in range(trials):
        v = rng.randrange(16)
        # neighbours differ from v, so the run is exactly n long
        pre = [rng.randrange(16) for _ in range(2047)] + [rng.choice([x for x in range(16) if x != v])]
        post = [rng.choice([x for x in range(16) if x != v])] + [rng.randrange(16) for _ in range(2047)]
        seq = pre + [v] * n + post
        lane_hits += lanes_detect(seq, rct_c, apt_c); sym_hits += symbols_detect(seq, s_rct, s_apt)
    return dict(repeat_length=n, trials=trials, lane_tests_detected=lane_hits, lane_rate=lane_hits / max(trials, 1),
                symbol_tests_detected=sym_hits, symbol_rate=sym_hits / max(trials, 1), required=0.99)

def criterion_b(h, rct_c, apt_c, s_rct, s_apt, trials, rng):
    p_star = 2 ** (-h / 2)
    lane_hits = sym_hits = 0
    for _ in range(trials):
        seq = [0 if rng.random() < p_star else rng.randrange(1, 16) for _ in range(50000)]
        lane_hits += lanes_detect(seq, rct_c, apt_c); sym_hits += symbols_detect(seq, s_rct, s_apt)
    return dict(p_0000=p_star, samples=50000, trials=trials, lane_tests_detected=lane_hits,
                lane_rate=lane_hits / max(trials, 1), symbol_tests_detected=sym_hits,
                symbol_rate=sym_hits / max(trials, 1), required=0.5)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='*')
    ap.add_argument('--h', type=float, required=True, help='min-entropy per 4-bit symbol used for the cutoffs')
    ap.add_argument('--rct', type=int, default=41)
    ap.add_argument('--apt', type=int, default=821)
    ap.add_argument('--trials', type=int, default=200)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    s_rct, s_apt = symbol_cutoffs(a.h)
    rep = dict(h_per_symbol=a.h, alpha=f'2^-{ALPHA_LOG2}', lane_cutoffs=dict(rct=a.rct, apt=a.apt, apt_window=1024),
               symbol_cutoffs=dict(rct=s_rct, apt=s_apt, apt_window=512), files=[])
    for f in a.files:
        runs = runs_of(open(f, 'rb').read())
        lanes, sym = replay(runs, a.rct, a.apt, s_rct, s_apt)
        rep['files'].append(dict(file=f, samples=sum(map(len, runs)), runs=len(runs), lanes=lanes, symbol=sym))
    n_floor = math.floor(100 / a.h) + 1
    n_ceil = math.ceil(100 / a.h) + 1
    rep['alternative_criteria'] = dict(
        a=[criterion_a(n, a.rct, a.apt, s_rct, s_apt, a.trials, rng) for n in sorted({n_floor, n_ceil})],
        b=criterion_b(a.h, a.rct, a.apt, s_rct, s_apt, max(20, a.trials // 10), rng))
    json.dump(rep, sys.stdout, indent=1); print()
    return 0                                # a report: the verdicts are in it, not in the status

if __name__ == '__main__':
    sys.exit(main())
