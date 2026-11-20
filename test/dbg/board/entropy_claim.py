#!/usr/bin/env python3
# H_submitter for the Zkr noise source (SP 800-90B sections 3.1.3 and 3.2.2):
# a lower bound on the min-entropy of one kept 4-bit sample given everything
# before it, from the burst-capture analysis and from captures at the shipped
# spacing. doc/sp800-90b-assessment.md section 1 has the argument; this
# computes its numbers.
#
# Model (arXiv:2102.02196, the model of getnoise_analyze.py): each ring's
# phase, in ring periods, advances between two samples by a known amount plus
# Gaussian jitter, and the sampled bit is 1 while the phase mod 1 lies in
# [0, D), D the ring's duty cycle as sampled. The predictor is given the exact
# phase of every ring at the previous sample, the frequencies with their
# wander, and every influence the rings share; only the white jitter of each
# ring's own devices is credited, and of that only a fraction (--credit) of the
# smallest rate the bursts measure. For one ring the best guess of the next bit
# then succeeds with probability
#     p = max over u of max(q(u), 1 - q(u)),
#     q(u) = P(N(u, s2) mod 1 in [0, D)),   s2 = credit * w * spacing,
# w the credited jitter variance per clock. The worst case over u is taken, not
# the average the analysis prints, so the bound holds for every past. With
# independent white jitter in the four rings the guess of the whole sample
# succeeds with at most the product of the four p, so
#     H_inf(sample | past) >= sum over lanes of -log2 p.
# A seed word holds four consecutive samples; the bound holds for each given
# the ones before, so a word has at least four times it.
#
# w per lane: the lower end of the shortest-lag determined jitter fit of each
# burst capture at a sampling period of 1, 2 or 4 clocks, per clock, the
# smallest of them. D per lane: the bias's upper end (z standard errors) over
# every sample file given.
#
# The bound needs the credited jitter to be independent from ring to ring.
# --pairs measures how far it is: for each pair of lanes and each burst
# capture it fits, per window, the covariance c of the two rings' phase
# increments. The product of the two lanes' bits has components at the sum
# and the difference of the two ring frequencies, which decay with
# Var(dA + dB) and Var(dA - dB), that is with sA + sB + 2c and sA + sB - 2c;
# the per-lane autocorrelations give sA and sB. It reports |rho| =
# |c| / sqrt(sA sB) (the sign follows the folding of the frequencies).
# --self-test checks that estimator on generated rings of known correlation.
#
# Usage:
#   entropy_claim.py --analysis getnoise-analysis.json --samples d20-sym4.bin s20-rows.bin ...
#                    [--spacing 4096] [--credit 0.05 ...] [--target 3.0] [--z 2.576]
#   entropy_claim.py --analysis getnoise-analysis.json --pairs DIR [--periods 1,2,4,8,16,32,64]
#   entropy_claim.py --self-test
# SPDX-License-Identifier: BSD-2-Clause
import argparse, itertools, json, math, sys

def p_max(D, s2, grid=8192):
    """max over u of max(q, 1-q), q = P(N(u, s2) mod 1 in [0, D))."""
    if s2 <= 0:
        return 1.0
    terms = []
    for n in range(1, 100000):
        e = math.exp(-2 * math.pi ** 2 * n * n * s2)
        if e < 1e-16:
            break
        terms.append((2 * math.pi * n, 2 * math.sin(math.pi * n * D) / (math.pi * n) * e))
    def q(u):
        return D + sum(a * math.cos(w * (u - D / 2)) for w, a in terms)
    best_u, best = 0.0, 0.0
    for i in range(grid):
        u = i / grid
        v = q(u)
        if max(v, 1 - v) > best:
            best, best_u = max(v, 1 - v), u
    lo, hi = best_u - 1 / grid, best_u + 1 / grid           # refine by golden section
    f = lambda u: max(q(u), 1 - q(u))
    g = (math.sqrt(5) - 1) / 2
    for _ in range(60):
        a, b = hi - g * (hi - lo), lo + g * (hi - lo)
        if f(a) > f(b): hi = b
        else: lo = a
    return min(1.0, max(best, f((lo + hi) / 2)))

def white_rates(analysis):
    """Per lane: the smallest per-clock lower end of the shortest-lag determined fits, and where it came from."""
    rates = {}
    for c in analysis['captures']:
        if c.get('kind') != 'burst' or c.get('period') not in (1, 2, 4):
            continue
        for l in c['lanes']:
            best = (l.get('windows') or {}).get('sigma2_best')
            if not best or best.get('low') is None:
                continue
            per_clock = best['low'] / c['clocks']
            if l['lane'] not in rates or per_clock < rates[l['lane']][0]:
                rates[l['lane']] = (per_clock, f"P={c['period']}, lags up to {best['lag_max']}")
    return rates

def duty(files, z):
    """Per lane: the bias's upper end over all files, as a duty D on the side away from 1/2."""
    worst = {}
    for path in files:
        data = open(path, 'rb').read()
        n = len(data)
        for i in range(4):
            ones = sum((b >> i) & 1 for b in data) / n
            bias = abs(ones - 0.5) + z * math.sqrt(ones * (1 - ones) / n)
            worst[i] = max(worst.get(i, 0.0), bias)
    return {i: 0.5 + b for i, b in worst.items()}

def bound(rates, D, spacing, credit):
    per = []
    for i in range(4):
        p = p_max(D[i], credit * rates[i][0] * spacing)
        per.append(-math.log2(p))
    return sum(per), per

# ---- pairwise covariance of the rings' phase increments ----
NH = 9                                                       # harmonics of the square wave kept in the models

def _coeffs(D):
    import numpy as np
    n = np.arange(1, NH + 1)
    wn = (4 / np.pi ** 2) * np.sin(np.pi * n * D) ** 2 / n ** 2
    return np.concatenate([[0], n, -n]), np.concatenate([[(2 * D - 1) ** 2], wn, wn])

def lane_model(j, F, s, D):
    import numpy as np
    ns, ws = _coeffs(D)
    return (ws[:, None] * np.cos(2 * np.pi * np.outer(ns, j) * F) * np.exp(-2 * np.pi ** 2 * np.outer(ns ** 2, j) * s)).sum(0)

def pair_model(j, FA, FB, sA, sB, c, DA, DB):
    """Autocorrelation of the product of two lanes' +-1 bits, phases with jointly Gaussian increments."""
    import numpy as np
    nA, wA = _coeffs(DA); nB, wB = _coeffs(DB)
    N1 = nA[:, None, None]; N2 = nB[None, :, None]; J = j[None, None, :]
    W = (wA[:, None] * wB[None, :])[:, :, None]
    return (W * np.cos(2 * np.pi * J * (N1 * FA + N2 * FB))
            * np.exp(-2 * np.pi ** 2 * J * (N1 ** 2 * sA + N2 ** 2 * sB + 2 * N1 * N2 * c))).sum((0, 1))

def fit_pair(sym, A, B, FA0, FB0, sA0, sB0, L):
    """Least squares of (FA, FB, sA, sB, rho) on both lanes' and the product's autocorrelation, lags 1..L."""
    import numpy as np
    from scipy.optimize import least_squares
    a = 2.0 * ((sym >> A) & 1) - 1; b = 2.0 * ((sym >> B) & 1) - 1
    DA, DB = (a.mean() + 1) / 2, (b.mean() + 1) / 2
    j = np.arange(1, L + 1, dtype=float)
    ac = lambda x: np.array([np.mean(x[:-k] * x[k:]) for k in range(1, L + 1)])
    CA, CB, R = ac(a), ac(b), ac(a * b)
    def res(p):
        FA, FB, lA, lB, rho = p
        sA, sB = math.exp(lA), math.exp(lB)
        return np.concatenate([CA - lane_model(j, FA, sA, DA), CB - lane_model(j, FB, sB, DB),
                               R - pair_model(j, FA, FB, sA, sB, rho * math.sqrt(sA * sB), DA, DB)])
    best = None
    for rho0 in (0.0, 0.9, -0.9):
        r = least_squares(res, [FA0, FB0, math.log(sA0), math.log(sB0), rho0],
                          bounds=([0, 0, math.log(1e-7), math.log(1e-7), -0.9999], [0.5, 0.5, 0, 0, 0.9999]))
        if best is None or r.cost < best.cost:
            best = r
    FA, FB, lA, lB, rho = best.x
    return dict(rho=rho, sA=math.exp(lA), sB=math.exp(lB))

def burst_runs(path):
    import numpy as np
    d = np.frombuffer(open(path, 'rb').read(), dtype=np.uint8)
    starts = np.flatnonzero(d & 0x80)
    return [(d[a:b] & 15).astype(np.int64) for a, b in zip(starts, list(starts[1:]) + [len(d)])]

def pairs(analysis, directory, periods):
    out = []
    caps = {c['period']: c for c in analysis['captures'] if c.get('kind') == 'burst'}
    for P in periods:
        if P not in caps:
            continue
        cap = caps[P]
        windows = burst_runs(f"{directory}/{cap['file']}")
        lanes = {l['lane']: l['windows'] for l in cap['lanes']}
        for A, B in itertools.combinations(range(4), 2):
            rhos = []
            for w, sym in enumerate(windows):
                FA0, FB0, sA0, sB0 = lanes[A]['F'][w], lanes[B]['F'][w], lanes[A]['sigma2'][w], lanes[B]['sigma2'][w]
                if None in (FA0, FB0) or not sA0 or not sB0 or sA0 > 0.2 or sB0 > 0.2:
                    continue                                 # no phase left to see in this window
                L = int(min(64, max(6, 2.0 / (2 * math.pi ** 2 * (sA0 + sB0)))))
                rhos.append(abs(fit_pair(sym, A, B, FA0, FB0, sA0, sB0, L)['rho']))
            if len(rhos) >= 8:
                m = sum(rhos) / len(rhos)
                sd = math.sqrt(sum((r - m) ** 2 for r in rhos) / (len(rhos) - 1))
                out.append(dict(period=P, lanes=[A, B], windows=len(rhos), abs_rho=round(m, 4),
                                se=round(sd / math.sqrt(len(rhos)), 4)))
    return out

def self_test():
    """The estimator on generated rings: two lanes, known F, variances and correlation."""
    import numpy as np
    rng = np.random.default_rng(1)
    ok = True
    for rho in (0.0, 0.5, 0.95):
        got = []
        for _ in range(8):
            sA, sB = 2e-3, 1e-3
            cov = [[sA, rho * math.sqrt(sA * sB)], [rho * math.sqrt(sA * sB), sB]]
            inc = rng.multivariate_normal([0, 0], cov, size=32768)
            pa = (rng.random() + np.cumsum(0.41 + inc[:, 0])) % 1
            pb = (rng.random() + np.cumsum(0.116 + inc[:, 1])) % 1
            sym = (pa < 0.5).astype(np.int64) | ((pb < 0.5).astype(np.int64) << 1)
            got.append(fit_pair(sym, 0, 1, 0.41, 0.116, sA, sB, 64)['rho'])
        med = float(np.median(got))
        good = abs(med - rho) < 0.05
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} generated rho {rho}: fitted median {med:+.3f}")
    print('entropy_claim self-test: ' + ('PASS' if ok else 'FAIL'))
    return ok

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--analysis')
    ap.add_argument('--samples', nargs='+', help='4-bit samples, one per byte (bit 7 of a GetNoise capture is ignored)')
    ap.add_argument('--pairs', metavar='DIR', help='directory of the burst captures named in the analysis')
    ap.add_argument('--periods', default='1,2,4,8,16,32,64')
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--spacing', type=int, default=4096, help='clocks between kept samples (k = 16: 4096)')
    ap.add_argument('--credit', type=float, nargs='*', default=[1.0, 0.1, 0.05])
    ap.add_argument('--target', type=float, default=3.0)
    ap.add_argument('--z', type=float, default=2.576)
    a = ap.parse_args()
    if a.self_test:
        sys.exit(0 if self_test() else 1)
    if not a.analysis:
        ap.error('--analysis is needed')
    if a.pairs:
        print(json.dumps(pairs(json.load(open(a.analysis)), a.pairs, [int(p) for p in a.periods.split(',')]), indent=1))
        return
    if not a.samples:
        ap.error('--samples is needed for the bound')
    rates = white_rates(json.load(open(a.analysis)))
    if sorted(rates) != [0, 1, 2, 3]:
        sys.exit(f'no determined short-lag fit for every lane: {sorted(rates)}')
    D = duty(a.samples, a.z)
    out = dict(spacing=a.spacing, lanes=[dict(lane=i, white_per_clock=rates[i][0], from_=rates[i][1], duty=D[i],
                                              s2_at_spacing=rates[i][0] * a.spacing) for i in range(4)], bounds=[])
    for c in a.credit:
        h, per = bound(rates, D, a.spacing, c)
        out['bounds'].append(dict(credit=c, bits_per_sample=round(h, 4), per_lane=[round(x, 4) for x in per]))
    lo, hi = 1e-4, 1.0                                       # the smallest credit that still gives the target
    if bound(rates, D, a.spacing, hi)[0] < a.target:
        out['credit_for_target'] = None
    else:
        for _ in range(40):
            mid = math.sqrt(lo * hi)
            if bound(rates, D, a.spacing, mid)[0] >= a.target: hi = mid
            else: lo = mid
        out['credit_for_target'] = math.ceil(hi * 1e4) / 1e4      # rounded up: the share that does reach the target
    out['target'] = a.target
    print(json.dumps(out, indent=1))

if __name__ == '__main__':
    main()
