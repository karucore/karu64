#!/usr/bin/env python3
# H_submitter for the Zkr noise source (SP 800-90B sections 3.1.3 and 3.2.2):
# a lower bound on the min-entropy of one kept 4-bit sample given everything
# before it, from the burst-capture analysis and from captures at the shipped
# spacing. doc/sp800-90b-assessment.md section 1 has the argument; this
# computes its numbers.
#
# The default mode is the bound for the four-lane source of image ddb168e1…,
# whose seed word held four consecutive 4-bit samples. The current source
# delivers one lane, sixteen kept bits per word: rosc_own.py measures it,
# with --own below as a cross-check.
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
# A seed word of that image held four consecutive samples; the bound holds for each given
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
# --own: lane 0's own jitter from the reference bits. rosc_count.py takes
# bursts in which a sample is {reference 1, reference 0, lane 1, lane 0}
# (refbits/getnoise-burst-p<P>.bin): lane 0 and the two reference rings are
# three rings of one kind, 3 inverters each, sampled at the same clock edge.
# For two of them the difference of the phase increments loses what the two
# share, and the (1, -1) component of the product of their bits decays with
# its variance, sA + sB - 2c, which the fit of --pairs gives per burst. With
# v(A, B) that variance per clock, and the own jitter of the three rings
# independent of each other,
#     v(A, B) = own(A) + own(B),
#     own(0)  = (v(0, r0) + v(0, r1) - v(r0, r1)) / 2,
# and likewise for each reference. --own reports v for the three pairs and the
# own variance of each ring, per sampling period, with the standard error
# over the bursts, and their mean over the periods at which all three pairs
# could be fitted; then, for lane 0, that own variance at 4,096 and at 16,384
# clocks as a ratio to the variance that --target bits per bit need (p_max
# above, with the duty's upper end over the bursts at z standard errors).
# What it assumes, and what it cannot see:
#   - the three rings are alike enough that what they share cancels in a
#     difference. A shared influence that moves ring A by g(A) times what it
#     moves ring 0 leaves (g(A) - g(B))^2 of its variance in v(A, B), and
#     (1 - g(r0)) (1 - g(r1)) of it in own(0): with g within 3 % of 1 and a
#     shared variance 20 times the own, at most 2 % of an own variance, of
#     either sign;
#   - the own jitter of a ring is independent of the other rings', and white
#     over the spans that are fitted: v per clock is then the same at every
#     sampling period, which the per-period values show or refute;
#   - the rings move together, and most of their jitter is shared, so that
#     the difference is the component with the smaller variance: v is taken
#     as sA + sB - 2 |rho| sqrt(sA sB) in every burst. The sign of the fitted
#     rho says nothing (it follows the folding of the frequencies, and at the
#     longer periods the fit may place the component at the sum of the two
#     frequencies as well as at their difference). For rings that share
#     little, |rho| near zero, this takes v too low; the mean |rho| of each
#     pair is in the output;
#   - the spans fitted are 64 samples, at most a few thousand clocks at the
#     longest period, and most of the weight is at a few hundred: nothing is
#     seen of what happens to the own jitter at longer spans, where flicker
#     noise would make it grow faster than this rate, and a lock or a bound
#     would make it grow slower. The multiplication to 4,096 and 16,384
#     clocks is an extrapolation.
# It is a cross-check of the meter's analysis (rosc_own.py), which measures
# at the spacing itself; it is not a second claim.
# The estimator's bias. With few lags the fit tends to put rho too low and v
# too high: on the generated rings of --self-test (bursts of 32,768 samples,
# a shared variance of 20 times the own) and the 24 lags that --pairs would
# choose at these values, rho came out 0.1 to 0.5 % low and v 2 to 12 % high
# over 32 bursts (standard errors 4 to 7 %). So --own always fits 64 lags.
# With them, for each case of the self-test, the three v were within 3.5 %
# of the truth at 2e-4 per sample and within 1.5 % at 8e-4, 3e-3 and 1.3e-2,
# and ring 0's own variance was within 4 % of an own variance at 1e-4 per
# sample (standard error 2 to 4 %) and within 2 % at 4e-4, 1.6e-3 and 6.4e-3
# (standard error 0.4 to 3 %); 192 bursts each, 48 at the last value. That is
# nothing beyond the standard errors, and nothing is corrected. The
# self-test prints how far each of its cases is from the truth. A pair whose
# two frequencies differ by nearly 0 or nearly 1/2 cycle per sample is
# fitted with more scatter, which the standard error over the bursts shows.
#
# Usage:
#   entropy_claim.py --analysis getnoise-analysis.json --samples d20-sym4.bin s20-rows.bin ...
#                    [--spacing 4096] [--credit 0.05 ...] [--target 3.0] [--z 2.576]
#   entropy_claim.py --analysis getnoise-analysis.json --pairs DIR [--periods 1,2,4,8,16,32,64]
#   entropy_claim.py --analysis refbits/getnoise-analysis.json --own refbits
#                    [--periods 1,2,4,8,16,32,64] [--target 0.75] [--z 2.576] [--samples ...]
#   entropy_claim.py --self-test [DIR]
# SPDX-License-Identifier: BSD-2-Clause
import argparse, itertools, json, math, os, sys

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

# ---- lane 0's own jitter from the reference bits ----
OWN_BITS = (0, 2, 3)                                         # of a reference-bit sample: lane 0, reference 0, reference 1
OWN_NAMES = ('lane 0', 'reference 0', 'reference 1')
OWN_PAIRS = ((0, 1), (0, 2), (1, 2))                         # of the three rings
OWN_LAGS = 64
OWN_SPACINGS = (4096, 16384)

def mean_se(values):
    m = sum(values) / len(values)
    return m, math.sqrt(sum((x - m) ** 2 for x in values) / (len(values) - 1) / len(values))

def own_period(windows, start, clocks, bits=OWN_BITS, lags=OWN_LAGS):
    """One capture. windows: the bursts; start(w, bit): (F, sigma^2 per sample) to start the fit of burst w from, or
    None if that ring's phase cannot be followed in it. Per pair of the three rings the variance per clock of the
    difference of their phase increments, per ring its own variance per clock, each with the standard error over the
    bursts in which all three pairs were fitted; None with fewer than eight such bursts."""
    fits = []
    for w, sym in enumerate(windows):
        first = [start(w, b) for b in bits]
        if any(f is None or f[0] is None or not f[1] or f[1] > 0.2 for f in first):
            continue                                         # no phase left to see in this burst
        fits.append([fit_pair(sym, bits[i], bits[j], first[i][0], first[j][0], first[i][1], first[j][1], lags) for i, j in OWN_PAIRS])
    if len(fits) < 8:
        return None
    # The rings move together, so the difference is the component of smaller variance. The sign of the fitted rho
    # says nothing: it follows the folding of the frequencies, and where a ring's own autocorrelation is gone after
    # a lag the fit may put the one long-lived component at the sum of two frequencies as well as at their difference.
    v = [[(f[k]['sA'] + f[k]['sB'] - 2 * abs(f[k]['rho']) * math.sqrt(f[k]['sA'] * f[k]['sB'])) / clocks for f in fits] for k in range(3)]
    own = [[(v[0][w] + v[1][w] - v[2][w]) / 2 for w in range(len(fits))],
           [(v[0][w] + v[2][w] - v[1][w]) / 2 for w in range(len(fits))],
           [(v[1][w] + v[2][w] - v[0][w]) / 2 for w in range(len(fits))]]
    return dict(windows=len(fits), pairs=[mean_se(x) for x in v], own=[mean_se(x) for x in own],
                abs_rho=[sum(abs(f[k]['rho']) for f in fits) / len(fits) for k in range(3)])

def variance_needed(D, target):
    """The smallest variance of the phase between two samples that gives `target` bits per bit at duty D; None if none does."""
    if -math.log2(p_max(D, 4.0, 2048)) < target:
        return None
    lo, hi = 0.0, 4.0
    for _ in range(40):
        mid = (lo + hi) / 2
        if -math.log2(p_max(D, mid, 2048)) >= target: hi = mid
        else: lo = mid
    return hi

def own(analysis, directory, periods, target, z, samples=None):
    """--own: see the header."""
    caps = {c['period']: c for c in analysis['captures'] if c.get('kind') == 'burst'}
    files = {P: os.path.join(directory, os.path.basename(c['file'])) for P, c in caps.items()}
    out = dict(source=directory, rings=list(OWN_NAMES), bits=list(OWN_BITS), lags=OWN_LAGS, periods=[],
               unit='ring periods^2 per clock',
               note='a cross-check of rosc_own.py at spans of at most a few hundred clocks, not a claim: see the header of entropy_claim.py')
    for P in periods:
        if P not in caps:
            continue
        lanes = {l['lane']: l['windows'] for l in caps[P]['lanes']}
        res = own_period(burst_runs(files[P]), lambda w, b: (lanes[b]['F'][w], lanes[b]['sigma2'][w]), caps[P]['clocks'])
        if res is None:
            out['periods'].append(dict(period=P, fitted=False, why='fewer than eight bursts in which all three rings could be followed'))
            continue
        out['periods'].append(dict(period=P, fitted=True, windows=res['windows'],
            difference=[dict(rings=[OWN_NAMES[i], OWN_NAMES[j]], variance=m, se=e, abs_rho=r)
                        for (i, j), (m, e), r in zip(OWN_PAIRS, res['pairs'], res['abs_rho'])],
            own=[dict(ring=n, variance=m, se=e) for n, (m, e) in zip(OWN_NAMES, res['own'])]))
    done = [p for p in out['periods'] if p['fitted']]
    if not done:
        out['mean'] = None
        return out
    out['mean'] = []
    for i, name in enumerate(OWN_NAMES):                     # the unweighted mean over the periods, which are separate captures
        ms, es = [p['own'][i]['variance'] for p in done], [p['own'][i]['se'] for p in done]
        m = sum(ms) / len(ms)
        out['mean'].append(dict(ring=name, variance=m, se=math.sqrt(sum(e * e for e in es)) / len(es), periods=[p['period'] for p in done],
                                between_periods_sd=math.sqrt(sum((x - m) ** 2 for x in ms) / (len(ms) - 1)) if len(ms) > 1 else None))
    D = duty(samples or [files[p['period']] for p in done], z)[OWN_BITS[0]]
    need, m, e = variance_needed(D, target), out['mean'][0]['variance'], out['mean'][0]['se']
    out['lane0'] = dict(duty=D, target_bits=target, z=z, variance_needed=need, at=[
        dict(clocks=n, variance=m * n, variance_low=(m - z * e) * n, bits=-math.log2(p_max(D, max(m, 0.0) * n)),
             ratio=None if need is None else m * n / need, ratio_low=None if need is None else (m - z * e) * n / need)
        for n in OWN_SPACINGS])
    return out

def generated_rings(rng, n, F, gain, shared, own_variance, D=0.5):
    """Samples of three rings, ring i in bit OWN_BITS[i]: increments F + gain * (a shared value) + its own noise."""
    import numpy as np
    common = rng.normal(0, math.sqrt(shared), n)
    sym = np.zeros(n, dtype=np.int64)
    for i in range(3):
        inc = F[i] + gain[i] * common + (rng.normal(0, math.sqrt(own_variance[i]), n) if own_variance[i] else 0.0)
        sym |= (((rng.random() + np.cumsum(inc)) % 1) < D).astype(np.int64) << OWN_BITS[i]
    return sym

def self_test_own(work, z=2.576, bursts=32):
    """--own on generated rings: three rings of nearly one frequency, a shared increment of 20 times the variance of
    an own one, which acts on each ring in proportion to its frequency, and known own variances per clock. Three cases
    at one sample per clock; the first of them again from files, as rosc_count.py writes them, through
    getnoise_analyze.py; and again at one sample per 64 clocks, where a ring's own autocorrelation is gone after a
    lag and the fit is free in the sign of rho."""
    import hashlib, subprocess
    import numpy as np
    rate = (20.12, 20.12 * 1.025, 20.12 * 0.985)             # periods per clock: within 3 % of each other
    gain, unit = [r / rate[0] for r in rate], 1e-4
    shared, ok = 20 * unit, True
    leak = shared * (gain[0] - gain[1]) * (gain[0] - gain[2])               # what the unequal sharing leaves in ring 0's value
    for name, own_variance, clocks, bursts in (('all three equal', (unit, unit, unit), 1, bursts), ("ring 0's zero", (0.0, unit, unit), 1, bursts),
                                               ("ring 0's four times the others'", (4 * unit, unit, unit), 1, bursts),
                                               ('all three equal, a sample every 64 clocks', (unit, unit, unit), 64, bursts // 2)):
        rng = np.random.default_rng(20261121)
        F = [(r * clocks) % 1 for r in rate]
        windows = [generated_rings(rng, 32768, F, gain, shared * clocks, [o * clocks for o in own_variance]) for _ in range(bursts)]
        first = [(min(f, 1 - f), (g * g * shared + o) * clocks) for f, g, o in zip(F, gain, own_variance)]
        res = own_period(windows, lambda w, b: first[OWN_BITS.index(b)], clocks)
        m, e = res['own'][0]
        if own_variance[0]:
            good = abs(m - own_variance[0]) <= z * e and e <= 0.2 * own_variance[0]
        else:
            good = m <= z * e and e <= 0.2 * unit
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} own variance, {name}: ring 0 has {own_variance[0]:.3e}, found {m:.3e} +- {e:.1e} "
              f"(standard error over {res['windows']} bursts): {(m - own_variance[0]) / e:+.2f} standard errors or {(m - own_variance[0]) / unit:+.1%} "
              f"of an own variance from the truth ({leak / unit:+.1%} is expected from the unequal sharing); "
              f"pairs {', '.join(f'{pm:.3e}' for pm, _ in res['pairs'])}, |rho| {', '.join(f'{r:.3f}' for r in res['abs_rho'])}")
        if own_variance[0] != unit or clocks != 1:
            continue
        # the same bursts as files: what rosc_count.py writes, getnoise_analyze.py for the starting values, then --own
        (work / 'refbits').mkdir(parents=True, exist_ok=True)
        path = work / 'refbits' / 'getnoise-burst-p1.bin'
        data = bytearray()
        for sym in windows:
            burst = bytearray(sym.astype(np.uint8).tobytes())
            burst[0] |= 0x80
            data += burst
        path.write_bytes(data)
        path.with_suffix('.json').write_text(json.dumps(dict(format='karu64-getnoise-burst-1', kind='burst', source='refbits',
            lanes=['lane 0', 'lane 1', 'reference 0', 'reference 1'], period=1, k=1, clock_hz=75000000, bursts=bursts, symbols_per_burst=32768,
            stored=len(data), runs=bursts, run_lengths=[32768] * bursts, sha256=hashlib.sha256(data).hexdigest()), indent=1) + '\n')
        tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'getnoise_analyze.py')
        r = subprocess.run([sys.executable, tool, str(path)], capture_output=True, text=True)
        out = own(json.load(open(path.with_name('getnoise-analysis.json'))), str(path.parent), [1, 2], 0.75, z) if r.returncode == 0 else None
        if out is None or not out['mean']:
            good, text = False, f"getnoise_analyze.py exit {r.returncode}: {r.stderr[-200:]}" if out is None else str(out['periods'])
        else:
            m, e, lane0 = out['mean'][0]['variance'], out['mean'][0]['se'], out['lane0']
            need, at = lane0['variance_needed'], lane0['at'][0]
            good = (abs(m - unit) <= z * e and e <= 0.2 * unit and out['mean'][0]['periods'] == [1] and need is not None and 0.09 < need < 0.12
                    and at['clocks'] == 4096 and abs(at['ratio'] - m * 4096 / need) < 1e-9 and at['ratio_low'] < at['ratio'] < 1.5 * unit * 4096 / need)
            text = (f"found {m:.3e} +- {e:.1e} over {out['periods'][0]['windows']} bursts; duty at most {lane0['duty']:.4f}, 0.75 bit needs "
                    f"{need:.4f}, at 4096 clocks the own variance is {at['ratio']:.2f} times that (lower end {at['ratio_low']:.2f}), "
                    f"at 16384 clocks {lane0['at'][1]['ratio']:.2f} times")
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} own variance, {name}, from files through getnoise_analyze.py and --own: {text}")
    return ok

def self_test(work=None):
    """The estimator on generated rings: two lanes, known F, variances and correlation. Then --own. `work` is a
    directory for the files of its last case; without one a temporary directory is used."""
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
    if work:
        from pathlib import Path
        ok &= self_test_own(Path(work))
    else:
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as temporary:
            ok &= self_test_own(Path(temporary))
    print('entropy_claim self-test: ' + ('PASS' if ok else 'FAIL'))
    return ok

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--analysis')
    ap.add_argument('--samples', nargs='+', help='4-bit samples, one per byte (bit 7 of a GetNoise capture is ignored)')
    ap.add_argument('--pairs', metavar='DIR', help='directory of the burst captures named in the analysis')
    ap.add_argument('--own', metavar='DIR', help="directory of the reference-bit bursts named in the analysis (rosc_count.py's refbits): "
                    "lane 0's own jitter from the three rings of its kind")
    ap.add_argument('--periods', default='1,2,4,8,16,32,64')
    ap.add_argument('--self-test', nargs='?', const='', metavar='DIR', help='run the self-test; DIR is where it may write the capture '
                    'that it generates for --own (default: a temporary directory)')
    ap.add_argument('--spacing', type=int, default=4096, help='clocks between kept samples (k = 16: 4096)')
    ap.add_argument('--credit', type=float, nargs='*', default=[1.0, 0.1, 0.05])
    ap.add_argument('--target', type=float, help='bits wanted: per 4-bit sample for the bound (3.0), per bit of lane 0 for --own (0.75)')
    ap.add_argument('--z', type=float, default=2.576)
    a = ap.parse_args()
    if a.self_test is not None:
        sys.exit(0 if self_test(a.self_test) else 1)
    if not a.analysis:
        ap.error('--analysis is needed')
    if a.pairs:
        print(json.dumps(pairs(json.load(open(a.analysis)), a.pairs, [int(p) for p in a.periods.split(',')]), indent=1))
        return
    if a.own:
        print(json.dumps(own(json.load(open(a.analysis)), a.own, [int(p) for p in a.periods.split(',')],
                             0.75 if a.target is None else a.target, a.z, a.samples), indent=1))
        return
    if a.target is None:
        a.target = 3.0
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
