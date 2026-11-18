#!/usr/bin/env python3
"""Offline analysis of GetNoise captures (getnoise_capture.py); no board access.

    python3 test/dbg/board/getnoise_analyze.py _build/dbg/board-accept/getnoise-k*.bin

A capture is one byte per raw symbol: bits [3:0] the symbol (lane i in bit i,
one sampled ring oscillator per lane), bit 7 on the first symbol of a run.
Only symbols of the same run are consecutive kept samples, so every statistic
that looks at neighbours is computed inside runs. The decimation k comes from
the capture's JSON sidecar, or from --k for a bare file.

Bits are never combined here: no statistic is taken of an XOR or sum of
lanes or samples. (Counting the positions where two bit strings differ uses
an XOR of big integers as a counting device; only the count leaves it.)

Per lane, per capture (model of arXiv:2102.02196: phase x_i = x_{i-1} +
N(F, sigma^2) mod 1, bit = 1 if x_i < D; D is the duty cycle):
  * ones fraction, an estimate of D;
  * repetitions: lengths of stretches of equal bits, and the largest count
    of the adaptive proportion test's 1024-symbol window, for comparison
    with the two health-test cutoffs;
  * the scaled autocorrelation C_j = 2 Pr(z_i = z_{i+j}) - 1, lags 1..N;
  * a fit of (F, sigma^2) per kept sample. Estimator: D is fixed to the ones
    fraction; least squares of the model's exact C_j against the measured
    C_1..C_M. The model value is the closed form
        C_j = (1-2D)^2 + (8/pi^2) sum_{n>=1} sin^2(pi n D)/n^2
                         * cos(2 pi n j F) * exp(-2 pi^2 n^2 j sigma^2),
    which is the paper's Eqn. 12 written as a Fourier series. A grid over
    F in [0, 1/2] and sigma^2 in [1e-4, 2] is followed by a local search.
    Limits: only F mod 1 is visible, and F cannot be told from 1 - F. When
    no C_j differs from (1-2D)^2 by more than four standard errors the data
    carry no trace of the phase, and the result is a lower bound on sigma^2
    and no F. The range given for sigma^2 comes from the fit's sensitivity
    to the C_j and their standard errors.

Per bit of a lane, as -log2 of a guessing probability, each with a lower end
(the probability taken at the upper end of a --confidence-z interval, 2.576
by default):
  * bias cap: max(p1, 1-p1). No estimate for a bit can be above it;
  * predictor cap: the success rate of a table that predicts a bit from the
    twelve before it, built on the first half of the capture and counted on
    the second half. Any explicit predictor's rate is a cap as well;
  * model: the average probability of guessing a bit when the previous phase
    is known, for the measured D and the fitted sigma^2. For D = 1/2 this is
    the p_e of the paper's Eqn. 16; for other D it grows towards the bias
    cap. The larger of that and the looser bound p_e <= 1 - tanh(pi sigma)/2
    is used. That bound alone assumes D = 1/2: it is printed for reference
    and never used by itself;
  * the estimate is the smallest of the three, and its lower end the
    smallest of their lower ends.
  The model figure is refused, and with it any verdict for the lane, when
  the model does not fit: when some measured C_j, at any computed lag, is
  more than --fit-z standard errors (5 by default) from the fitted model's
  value; when the serial correlation has not died out by the last lag, so
  that those standard errors are too small; or when the predictor guesses
  more bits than the model says anyone can. The standard error of C_j is
  sqrt((1 + 2 sum rho_m^2) / pairs), Bartlett's large-lag formula.

Across captures: the model says that keeping every k-th sample gives
sigma^2(k) = k sigma^2(1). The fitted values are compared with the line
through the origin whose slope is the mean of sigma^2(k)/k; captures whose
fit is only a lower bound are left out.

Across lanes: for all six pairs, at lag 0 and small lags, the correlation
(phi) of the two bits, the chi-square of their 2x2 table, the mutual
information, and a z score of phi that allows for the serial correlation of
each lane (Bartlett: var(phi) = sum_j rho_a(j) rho_b(j) / n for independent
lanes). A pair is flagged when |z| reaches --z. For the four lanes together,
the total correlation (sum of lane entropies minus symbol entropy) at lag 0,
flagged above four times the value that sampling alone gives. The report
also gives the smallest correlation the capture could have flagged.
These see dependence in the joint distribution of bits at a fixed lag. They
do not see jitter that rings of different frequency share.

Symbols and words: the empirical distribution of 4-bit symbols and of 16-bit
words (four consecutive symbols, first in the high nibble, taken from each
run's start without overlap), the most frequent value and -log2 of its
frequency. That figure describes the distribution of one symbol or word. It
says nothing about how well a word can be predicted from earlier words, and
with few words it is limited by the sample size; the report gives the value
that a uniform source would show with the same number of words. For words
there is a predictor cap too: how often the lane tables, run four bits
ahead from the twelve symbols before a word, get all sixteen bits right.

There is no verdict on whether the entropy is sufficient unless thresholds
are given. With thresholds the exit status is 1 when one is not met:
  --min-lane-bits X      every lane's lower end is at least X, and its model
                         fits
  --min-word-bits X      the smaller of the word distribution's figure (99%
                         bound) and the word predictor cap's lower end is at
                         least X
  --require-independent  nothing is flagged, and the capture is large enough
                         to have flagged a correlation of --max-undetected-phi
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, hashlib, itertools, json, math, re, struct, sys
from collections import Counter
from statistics import NormalDist
from pathlib import Path

LANES = 4
PAIRS = list(itertools.combinations(range(LANES), 2))
LANE_TAB = [bytes(48 + ((v >> lane) & 1) for v in range(256)) for lane in range(LANES)]
SYM_TAB = bytes(v & 15 for v in range(256))
K8 = 8 / math.pi ** 2
S2_GRID = [1e-4 * 10 ** (i / 10) for i in range(44)]        # 1e-4 .. 2, ten per decade
F_GRID = 1024                                               # F step 1/1024 over [0, 1/2]
ORDER = 12                                                  # bits of context of the predictor

# ---- the model ----
def model_c(F, D, s2, j):
    """C_j of the model with parameters (F, D, sigma^2 = s2)."""
    c = (1 - 2 * D) ** 2
    a = 2 * math.pi ** 2 * j * s2
    for n in range(1, 4000):
        e = math.exp(-a * n * n)
        if e < 1e-9:
            break
        c += K8 * math.sin(math.pi * n * D) ** 2 / (n * n) * math.cos(2 * math.pi * n * j * F) * e
    return c

def pe_bound(s2):
    """(p_e, -log2 p_e) from p_e <= 1 - tanh(pi sigma)/2; assumes D = 1/2."""
    pe = 1 - math.tanh(math.pi * math.sqrt(s2)) / 2
    return pe, max(0.0, -math.log2(pe))

def guess_probability(D, s2, points=512):
    """Average probability of guessing the next bit of a model lane from the
    previous phase: the mean over u of max(q, 1-q), where q(u) is the chance
    that a phase drawn from N(u, s2) mod 1 lies in [0, D). It is never below
    max(D, 1-D), and for D = 1/2 it is the p_e of the paper's Eqn. 16."""
    if s2 <= 0:
        return 1.0
    terms = []
    for n in range(1, 2000):
        e = math.exp(-2 * math.pi ** 2 * n * n * s2)
        if e < 1e-12:
            break
        terms.append((2 * math.pi * n, 2 * math.sin(math.pi * n * D) / (math.pi * n) * e))
    total = 0.0
    for i in range(points):
        u = (i + 0.5) / points - D / 2
        q = D + sum(a * math.cos(w * u) for w, a in terms)
        total += max(q, 1 - q)
    return min(1.0, total / points)

def model_guess(D, s2):
    """The guessing probability used for a lane: the bias-aware model value,
    and never less than the fair-duty bound."""
    return max(guess_probability(D, s2), pe_bound(s2)[0])

def fit(cs, D, ses, zc):
    """Least-squares (F, sigma^2) for measured C_1..C_M with standard errors ses."""
    base = (1 - 2 * D) ** 2
    signal = max(abs(c - base) / se for c, se in zip(cs, ses))
    if signal < 4:
        # No visible phase memory. Whatever F is, lag 1 or lag 2 would show
        # it if sigma^2 were small enough: bisect for the largest sigma^2 at
        # which one of them still exceeds four standard errors for every F.
        threshold = 4.4 * max(ses[:2])
        def visible(s2):
            return all(max(abs(model_c(g / 256, D, s2, j) - base) for j in (1, 2)) >= threshold for g in range(129))
        low, high = 0.0, 4.0
        if visible(S2_GRID[0]):
            low = S2_GRID[0]
            while high / low > 1.01:
                mid = math.sqrt(low * high)
                low, high = (mid, high) if visible(mid) else (low, mid)
        return dict(identifiable=False, F=None, sigma2=low, sigma2_low=low, sigma2_high=None, signal=signal)
    cos_tab = [math.cos(2 * math.pi * i / F_GRID) for i in range(F_GRID)]
    best = (math.inf, 0.0, S2_GRID[0])
    for s2 in S2_GRID:
        weights = []
        for j in range(1, len(cs) + 1):
            a, w = 2 * math.pi ** 2 * j * s2, []
            for n in range(1, 4000):
                e = math.exp(-a * n * n)
                if e < 1e-6:
                    break
                w.append(K8 * math.sin(math.pi * n * D) ** 2 / (n * n) * e)
            weights.append(w)
        for g in range(F_GRID // 2 + 1):
            err = 0.0
            for j, (w, c) in enumerate(zip(weights, cs), 1):
                step, idx, m = j * g % F_GRID, 0, base
                for wn in w:
                    idx = (idx + step) % F_GRID
                    m += wn * cos_tab[idx]
                err += (m - c) ** 2
                if err >= best[0]:
                    break
            else:
                best = (err, g / F_GRID, s2)
    def cost(F, s2):
        return sum((model_c(F, D, s2, j) - c) ** 2 for j, c in enumerate(cs, 1))
    err, F, s2 = best
    err, dF, ds = cost(F, s2), 1 / F_GRID, math.log(10) / 10
    while dF > 1e-7:
        moves = [(abs(F + dF), s2), (abs(F - dF), s2), (F, s2 * math.exp(ds)), (F, s2 * math.exp(-ds))]
        moves = [(1 - f if f > 0.5 else f, s) for f, s in moves]
        e2, F2, s22 = min((cost(f, s), f, s) for f, s in moves)
        if e2 < err:
            err, F, s2 = e2, F2, s22
        else:
            dF, ds = dF / 2, ds / 2
    # Standard error of ln(sigma^2): weighted least squares, linearised at the
    # optimum, in (F, ln sigma^2). When F does not matter (at 0 or 1/2) the
    # one-parameter value is used.
    hF, hs, a, b, c2 = 1e-5, 1e-3, 0.0, 0.0, 0.0
    for j, se in enumerate(ses, 1):
        dcF = (model_c(F + hF, D, s2, j) - model_c(F - hF, D, s2, j)) / (2 * hF)
        dcs = (model_c(F, D, s2 * math.exp(hs), j) - model_c(F, D, s2 * math.exp(-hs), j)) / (2 * hs)
        a += dcF * dcF / se ** 2; b += dcF * dcs / se ** 2; c2 += dcs * dcs / se ** 2
    det = a * c2 - b * b
    var = (a / det if det > 1e-9 * a * c2 else 1 / c2) if c2 > 0 else math.inf
    spread = math.exp(min(50.0, zc * math.sqrt(var)))
    return dict(identifiable=True, F=F, sigma2=s2, sigma2_low=s2 / spread, sigma2_high=s2 * spread,
                rms_residual=math.sqrt(err / len(cs)), at_grid_floor=s2 <= S2_GRID[0] * 1.001, signal=signal)

# ---- reading a capture ----
def load(path, k_arg=None):
    path = Path(path)
    raw = path.read_bytes()
    side = path.with_suffix(".json")
    meta = json.loads(side.read_text()) if side.exists() else {}
    if meta.get("sha256") and meta["sha256"] != hashlib.sha256(raw).hexdigest():
        raise ValueError(f"{path}: contents do not match the sha256 in {side.name}")
    k = meta.get("k") or k_arg
    if not k:
        raise ValueError(f"{path}: no sidecar with the decimation; give --k")
    runs = re.findall(rb"[\x80-\x8f][\x00-\x0f]*", raw)
    if not raw or sum(map(len, runs)) != len(raw):
        raise ValueError(f"{path}: not a capture (empty, first symbol without the run flag, or bits [6:4] set)")
    if meta and (meta.get("stored") != len(raw) or meta.get("run_lengths") != [len(r) for r in runs]):
        raise ValueError(f"{path}: symbol count or run lengths do not match {side.name}")
    return dict(file=str(path), k=int(k), meta=meta, runs=[r.translate(SYM_TAB) for r in runs])

# ---- statistics ----
def entropy(counts):
    n = sum(counts)
    return -sum(c / n * math.log2(c / n) for c in counts if c)

def bits(p):
    return max(0.0, -math.log2(min(1.0, max(p, 1e-300))))

def wilson_upper(hits, n, z):
    """Upper end of the Wilson score interval for hits out of n."""
    if n <= 0:
        return 1.0
    p = hits / n
    return min(1.0, (p + z * z / (2 * n) + z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / (1 + z * z / n))

def uniform_reference(n, values):
    """-log2 of the largest frequency a uniform source over `values` would
    typically show with n samples: the smallest count that fewer than half a
    value is expected to exceed."""
    lam = n / values                                        # counts are close to Poisson(lam)
    if lam > 500:
        c = lam + NormalDist().inv_cdf(1 - 0.5 / values) * math.sqrt(lam)
    else:
        c, pmf = 0, math.exp(-lam)
        cdf = pmf
        while values * (1 - cdf) >= 0.5:
            c += 1
            pmf *= lam / c
            cdf += pmf
    return -math.log2(min(1.0, max(c, 1) / n))

def most_common(counts, n, values):
    """Most frequent value and the min-entropy figures of an empirical distribution."""
    value, top = max(counts.items(), key=lambda kv: (kv[1], -kv[0]))
    p = top / n
    upper = min(1.0, p + 2.576 * math.sqrt(p * (1 - p) / max(n - 1, 1)))   # SP 800-90B 6.3.1
    return dict(samples=n, distinct=len(counts), most_common=value, count=top, p_max=p,
                min_entropy=-math.log2(p), min_entropy_99=-math.log2(upper),
                sample_limit=math.log2(n), uniform_reference=uniform_reference(n, values))

# ---- the predictor: a table from the twelve bits before, tried on data it has not seen ----
def split(pieces):
    """First and second half of [(length, lanes)], cut at a word boundary of a run."""
    half, seen, first, second = sum(n for n, _ in pieces) // 2, 0, [], []
    for n, lanes in pieces:
        k = min(n, max(0, half - seen)) // 4 * 4
        if k:
            first.append((k, tuple(a & ((1 << k) - 1) for a in lanes)))
        if n - k:
            second.append((n - k, tuple(a >> k for a in lanes)))
        seen += n
    return first, second

def windows(a, n, offset):
    """The 16-sample windows of a lane at offset, offset+16, ...; sample t of a window is its bit t."""
    count = (n - offset) // 16
    if count <= 0:
        return ()
    return struct.unpack(f"<{count}H", ((a >> offset) & ((1 << 16 * count) - 1)).to_bytes(2 * count, "little"))

def census(pieces, lane):
    """How often each 13-bit pattern (twelve bits, then the next) occurs in a lane."""
    seen = Counter()
    for n, lanes in pieces:
        for offset in range(16):
            seen.update(windows(lanes[lane], n, offset))
    ones, zeros = [0] * (1 << ORDER), [0] * (1 << ORDER)
    for window, count in seen.items():
        (ones if window >> ORDER & 1 else zeros)[window & ((1 << ORDER) - 1)] += count
    return ones, zeros

def predictors(pieces, zc):
    """Per-lane and whole-word success rates of the context tables, out of sample."""
    first, second = split(pieces)
    tables, lanes = [], []
    for lane in range(LANES):
        ones, zeros = census(first, lane)
        major = sum(ones) >= sum(zeros)
        table = [o > z or (o == z and major) for o, z in zip(ones, zeros)]      # context -> next bit
        ones, zeros = census(second, lane)
        hits = sum(o if t else z for o, z, t in zip(ones, zeros, table))
        tables.append(table)
        lanes.append(dict(order=ORDER, trained_on=sum(n for n, _ in first), tested=sum(ones) + sum(zeros), hits=hits))
    # four bits ahead from one context, feeding each prediction back in
    ahead = []
    for table in tables:
        row = []
        for context in range(1 << ORDER):
            c, guess = context, 0
            for t in range(4):
                bit = int(table[c])
                guess |= bit << t
                c = (c >> 1) | (bit << (ORDER - 1))
            row.append(guess)
        ahead.append(row)
    hits = tested = 0
    for n, sample in second:
        for offset in (0, 4, 8, 12):                        # words at symbols offset+12, +28, ... of the piece
            per_lane = [windows(a, n, offset) for a in sample]
            tested += len(per_lane[0])
            hits += sum(1 for word in zip(*per_lane)
                        if all(ahead[l][w & 0xfff] == w >> 12 for l, w in enumerate(word)))
    word = dict(tested=tested, hits=hits)
    if tested:
        word.update(rate=hits / tested, bits=bits(hits / tested) if hits else None, bits_low=bits(wilson_upper(hits, tested, zc)))
    return lanes, word

def analyze(cap, args):
    lags, zc = args.lags, args.confidence_z
    runs = cap["runs"]
    total = sum(map(len, runs))
    out = dict(file=cap["file"], k=cap["k"], symbols=total, runs=len(runs), longest_run=max(map(len, runs)),
               lanes=[], notes=[])
    cfg = cap["meta"].get("cfg_before")
    cutoffs = dict(rct=(int(cfg, 16) >> 16) & 0x3ff, apt=(int(cfg, 16) >> 26) & 0x7ff) if cfg else {}
    ints, rho = [], []
    for lane in range(LANES):
        text = [r.translate(LANE_TAB[lane]) for r in runs]              # b"0101..." per run
        ints.append([(len(t), int(t[::-1], 2)) for t in text])          # bit i = sample i
    predicted, word_predictor = predictors([(n, tuple(ints[l][i][1] for l in range(LANES)))
                                            for i, (n, _) in enumerate(ints[0])], zc)
    for lane in range(LANES):
        text = [r.translate(LANE_TAB[lane]) for r in runs]
        lane_bits = ints[lane]
        ones = sum(b.bit_count() for _, b in lane_bits)
        D = ones / total
        reps = Counter(len(m) for t in text for m in re.findall(rb"0+|1+", t))
        apt = max((t[i:i + 1024].count(t[i:i + 1]) for t in text for i in range(0, len(t) - 1023, 1024)), default=None)
        res = dict(lane=lane, ones_fraction=D,
                   repetitions=dict(longest=max(reps), mean=total / sum(reps.values()),
                                    histogram={str(n): c for n, c in sorted(reps.items())}),
                   apt_max_count=apt)
        if cutoffs:
            res["repetitions"]["at_or_over_cutoff"] = sum(c for n, c in reps.items() if n >= cutoffs["rct"])
            res["cutoffs"] = cutoffs
        cs, pairs = [], []
        for j in range(1, lags + 1):
            n = sum(m - j for m, _ in lane_bits if m > j)
            if not n:
                break
            same = sum(m - j - ((b ^ (b >> j)) & ((1 << (m - j)) - 1)).bit_count() for m, b in lane_bits if m > j)
            cs.append(2 * same / n - 1)
            pairs.append(n)
        res["autocorrelation"], res["pairs"] = cs, pairs
        var = 4 * D * (1 - D)
        rho.append([1 + (c - 1) / var for c in cs] if var > 0 else [])
        if 0 < D < 1 and len(cs) >= 2:
            # standard errors: of C_j (Bartlett, large lag) and of the ones fraction
            spread = 1 + 2 * sum(r * r for r in rho[lane])
            ses = [math.sqrt(spread / n) for n in pairs]
            se_D = math.sqrt(D * (1 - D) * max(1.0, 1 + 2 * sum(rho[lane])) / total)
            m = min(args.fit_lags, len(cs))
            f = res["fit"] = dict(fit(cs[:m], D, ses[:m], zc), lags=m)
            res["estimate"] = estimate(D, se_D, f, cs, ses, rho[lane], predicted[lane], zc, args.fit_z)
        else:
            out["notes"].append(f"lane {lane}: no fit and no estimate (constant lane, or no run of three symbols)")
        out["lanes"].append(res)

    # ---- cross-lane dependence ----
    cross = []
    for a, b in PAIRS:
        common = min(len(rho[a]), len(rho[b]))
        inflation = max(0.05, 1 + 2 * sum(x * y for x, y in zip(rho[a], rho[b])))
        truncated = common > 0 and abs(rho[a][common - 1]) > 0.05 and abs(rho[b][common - 1]) > 0.05
        rows = []
        for lag in range(-args.cross_lags, args.cross_lags + 1):        # lane a at i, lane b at i + lag
            n = n11 = na = nb = 0
            for (m, x), (_, y) in zip(ints[a], ints[b]):
                if m <= abs(lag):
                    continue
                mask = (1 << (m - abs(lag))) - 1
                u, v = ((x & mask), (y >> lag) & mask) if lag >= 0 else ((x >> -lag) & mask, y & mask)
                n += m - abs(lag); n11 += (u & v).bit_count(); na += u.bit_count(); nb += v.bit_count()
            den = na * (n - na) * nb * (n - nb)
            phi = (n * n11 - na * nb) / math.sqrt(den) if den else 0.0
            table = [(n11, na, nb), (na - n11, na, n - nb), (nb - n11, n - na, nb), (n - na - nb + n11, n - na, n - nb)]
            mi = sum(c / n * math.log2(c * n / (r * s)) for c, r, s in table if c)
            rows.append(dict(lag=lag, pairs=n, phi=phi, chi2=n * phi * phi, mi_bits=mi, z=phi * math.sqrt(n / inflation)))
        worst = max(rows, key=lambda r: abs(r["z"]))
        cross.append(dict(lanes=[a, b], inflation=inflation, truncated=truncated, lags=rows,
                          max_abs_z=abs(worst["z"]), at_lag=worst["lag"], flagged=abs(worst["z"]) >= args.z,
                          detectable_phi=min(1.0, args.z * math.sqrt(inflation / total))))
    late = ["%d,%d" % tuple(c["lanes"]) for c in cross if c["truncated"]]
    if late:
        out["notes"].append(f"lane pairs {' '.join(late)}: serial correlation reaches past the last lag computed, "
                            "so their z scores are overstated; use more --lags or longer runs")
    symbols = b"".join(runs)
    counts = {v: symbols.count(v) for v in range(16) if symbols.count(v)}
    lane_h = sum(entropy([l["ones_fraction"], 1 - l["ones_fraction"]]) for l in out["lanes"])
    tc = lane_h - entropy(list(counts.values()))
    floor = 11 * max(c["inflation"] for c in cross) / (2 * total * math.log(2))
    out["cross_lane"] = dict(pairs=cross, z_flag=args.z, flagged_pairs=[c["lanes"] for c in cross if c["flagged"]],
                             total_correlation_bits=tc, noise_floor_bits=floor, total_flagged=tc > 4 * floor,
                             detectable_phi=max(c["detectable_phi"] for c in cross))
    out["symbol_distribution"] = dict(most_common(counts, total, 16), counts=[counts.get(v, 0) for v in range(16)])
    words = Counter()
    for r in runs:
        words.update(struct.unpack(f">{len(r) // 4}I", r[:len(r) // 4 * 4]))
    if words:
        pack = lambda v: (v >> 12) & 0xf000 | (v >> 8) & 0xf00 | (v >> 4) & 0xf0 | v & 0xf
        w = out["word_distribution"] = most_common({pack(v): c for v, c in words.items()}, sum(words.values()), 65536)
        w["predictor"] = word_predictor
        # what a verdict uses: the smaller of the distribution's figure and the predictor cap
        w["bits_low"] = min(w["min_entropy_99"], word_predictor.get("bits_low", 0.0))
        w["limited_by"] = "distribution" if w["bits_low"] == w["min_entropy_99"] else "predictor"
    return out

def estimate(D, se_D, f, cs, ses, rho, pred, zc, fit_z):
    """Per-bit figures of one lane and whether its model fits; see the module text."""
    base = (1 - 2 * D) ** 2
    span = [max(1e-9, D - zc * se_D), min(1 - 1e-9, D + zc * se_D)]
    bias_p, bias_up = max(D, 1 - D), min(1.0, max(D, 1 - D) + zc * se_D)
    model_p = model_guess(D, f["sigma2"])
    model_up = max(model_guess(d, f["sigma2_low"]) for d in span)
    e = dict(scope="one bit of one lane", confidence_z=zc,
             bias=dict(p=bias_p, bits=bits(bias_p), bits_low=bits(bias_up)),
             model=dict(p=model_p, bits=bits(model_p), bits_low=bits(model_up), sigma2_is_lower_bound=not f["identifiable"]),
             fair_duty_bound=dict(p_e=pe_bound(f["sigma2"])[0], bits=pe_bound(f["sigma2"])[1],
                                  note="assumes D = 1/2; for reference, never used by itself"))
    tops = dict(bias=(bias_p, bias_up), model=(model_p, model_up))
    reasons = []
    # the fit: every computed lag against the fitted model
    worst, at = 0.0, 0
    for j, (c, se) in enumerate(zip(cs, ses), 1):
        z = abs(c - (model_c(f["F"], D, f["sigma2"], j) if f["identifiable"] else base)) / se
        if z > worst:
            worst, at = z, j
    if worst > fit_z:
        reasons.append(f"C_{at} is {worst:.1f} standard errors from the model")
    if abs(rho[-1]) > 0.05:
        reasons.append(f"serial correlation has not died out by lag {len(rho)}: use more --lags")
    if pred["tested"]:
        rate = pred["hits"] / pred["tested"]
        se = math.sqrt(rate * (1 - rate) * max(1.0, 1 + 2 * sum(rho)) / pred["tested"])
        rate_up = min(1.0, max(wilson_upper(pred["hits"], pred["tested"], zc), rate + zc * se))
        e["predictor"] = dict(pred, rate=rate, bits=bits(rate), bits_low=bits(rate_up))
        tops["predictor"] = (rate, rate_up)
        if rate - zc * se > model_up:
            reasons.append(f"a {ORDER}-bit context predictor guesses {rate:.4f} of the bits; the model allows {model_up:.4f}")
    else:
        e["predictor"] = None
        reasons.append("too few symbols to try a predictor")
    limit = max(tops, key=lambda name: tops[name][1])
    e.update(bits=bits(max(p for p, _ in tops.values())), bits_low=bits(tops[limit][1]), limited_by=limit,
             fit=dict(ok=not reasons, z=worst, at_lag=at, limit=fit_z, reasons=reasons))
    return e

def decimation(results, tolerance):
    """sigma^2 against k, per lane, over the captures with an identifiable fit."""
    table = []
    for lane in range(LANES):
        pts = sorted((r["k"], r["lanes"][lane]["fit"]["sigma2"]) for r in results
                     if r["lanes"][lane].get("fit", {}).get("identifiable"))
        row = dict(lane=lane, points=[], predicted=[], sigma2_per_raw_sample=None, exponent=None, linear=None)
        if pts:
            slope = sum(s / k for k, s in pts) / len(pts)   # every capture with the same relative weight
            row["sigma2_per_raw_sample"] = slope
            row["points"] = [dict(k=k, sigma2=s, predicted=k * slope, ratio=s / (k * slope)) for k, s in pts]
            for r in results:                               # the line, at every k captured, with that capture's D
                p = model_guess(r["lanes"][lane]["ones_fraction"], r["k"] * slope)
                row["predicted"].append(dict(k=r["k"], sigma2=r["k"] * slope, p=p, bits=bits(p)))
        if len({k for k, _ in pts}) >= 2:
            lx, ly = [math.log(k) for k, _ in pts], [math.log(s) for _, s in pts]
            mx, my = sum(lx) / len(lx), sum(ly) / len(ly)
            row["exponent"] = sum((x - mx) * (y - my) for x, y in zip(lx, ly)) / sum((x - mx) ** 2 for x in lx)
            row["linear"] = all(abs(p["ratio"] - 1) <= tolerance for p in row["points"])
        table.append(row)
    return table

# ---- report ----
def report(results, table, args, verdict):
    L = ["GetNoise capture analysis", ""]
    for r in results:
        L += [f"== {r['file']}: decimation k = {r['k']}, {r['symbols']} symbols in {r['runs']} run(s), longest {r['longest_run']}",
              "", "Per lane (each lane is one sampled ring; figures are per kept sample at this k):",
              f"  lane  ones(D)   longest-rep  apt-max   F        sigma^2    (range at z = {args.confidence_z})"]
        cut = r["lanes"][0].get("cutoffs")
        if cut:
            L.insert(-1, f"  (cutoffs in the capture's mentropycfg: repetition count {cut['rct']}, adaptive proportion {cut['apt']} of 1024)")
        for l in r["lanes"]:
            f = l.get("fit")
            head = f"  {l['lane']}     {l['ones_fraction']:.5f}   {l['repetitions']['longest']:<11}  {str(l['apt_max_count'] or '-'):<8}  "
            if not f:
                L.append(head + "(no fit)")
            elif f["identifiable"]:
                L.append(head + f"{f['F']:.5f}  {f['sigma2']:.5f}    ({f['sigma2_low']:.5f} .. {f['sigma2_high']:.5f})")
            else:
                L.append(head + f"  -      >={f['sigma2']:.4f}")
        if any(l.get("fit") and not l["fit"]["identifiable"] for l in r["lanes"]):
            L.append("  (>=: no autocorrelation above four standard errors; sigma^2 is a lower bound, F is not visible)")
        L += ["", "Per bit of a lane: -log2 of a guessing probability, in bits. The lower end is what a verdict uses.",
              "  lane  bias cap  predictor  model    (D=1/2 bound)  estimate  lower end  limited by  model fit"]
        for l in r["lanes"]:
            e = l.get("estimate")
            if not e:
                L.append(f"  {l['lane']}     (no estimate)")
                continue
            p = f"{e['predictor']['bits']:.4f}" if e["predictor"] else "  -   "
            fit_text = f"ok, z {e['fit']['z']:.1f}" if e["fit"]["ok"] else "REFUSED: " + "; ".join(e["fit"]["reasons"])
            L.append(f"  {l['lane']}     {e['bias']['bits']:.4f}    {p}     {'>=' if e['model']['sigma2_is_lower_bound'] else '  '}"
                     f"{e['model']['bits']:.4f}  ({e['fair_duty_bound']['bits']:.4f})       {e['bits']:.4f}    {e['bits_low']:.4f}     "
                     f"{e['limited_by']:<10}  {fit_text}")
        L += ["  bias cap: from the ones fraction alone. predictor: a table from the twelve bits before, tried on",
              "  the second half of the capture. model: guessing from the previous phase, with the measured D.",
              "  (D=1/2 bound): 1 - tanh(pi sigma)/2, shown for reference; it ignores the bias."]
        L += ["", "Autocorrelation C_j inside runs, lags 1..8:"]
        L += [f"  lane {l['lane']}: " + " ".join(f"{c:+.4f}" for c in l["autocorrelation"][:8]) for l in r["lanes"]]
        x = r["cross_lane"]
        L += ["", f"Cross-lane dependence (pair flagged when |z| >= {x['z_flag']}; z allows for each lane's serial correlation):",
              "  lanes  phi(lag 0)  chi2(lag 0)  MI bits(lag 0)  max|z|  at lag  flagged"]
        for c in x["pairs"]:
            zero = next(row for row in c["lags"] if row["lag"] == 0)
            L.append(f"  {c['lanes'][0]},{c['lanes'][1]}    {zero['phi']:+.5f}    {zero['chi2']:<11.2f}  {zero['mi_bits']:<14.6f}  "
                     f"{c['max_abs_z']:<6.2f}  {c['at_lag']:+d}      {'YES' if c['flagged'] else 'no'}")
        L.append(f"  four lanes at lag 0: total correlation {x['total_correlation_bits']:.6f} bits per symbol "
                 f"(independent lanes would show about {x['noise_floor_bits']:.6f} from sampling alone)"
                 + ("; DEPENDENT" if x["total_flagged"] else ""))
        L.append("  DEPENDENT LANES: " + ", ".join(f"{a},{b}" for a, b in x["flagged_pairs"]) if x["flagged_pairs"]
                 else "  no pair flagged, but the four lanes together are dependent" if x["total_flagged"]
                 else "  nothing flagged; this does not show independence (see the notes)")
        L.append(f"  a correlation below about {x['detectable_phi']:.4f} between two lanes would not have been flagged in this capture")
        for name, key, width in (("4-bit symbols", "symbol_distribution", 4), ("16-bit words", "word_distribution", 16)):
            d = r.get(key)
            if not d:
                continue
            L += ["", f"Empirical distribution of {name}: {d['samples']} samples, {d['distinct']} of {1 << width} values seen",
                  f"  most frequent {d['most_common']:#0{width // 4 + 2}x}: {d['count']} times, p = {d['p_max']:.6g}; "
                  f"-log2(p) = {d['min_entropy']:.4f} bits (99% bound {d['min_entropy_99']:.4f})",
                  f"  a uniform source would show about {d['uniform_reference']:.4f} with this many samples; "
                  f"no estimate from {d['samples']} samples can exceed {d['sample_limit']:.2f}"]
            wp = d.get("predictor")
            if wp and wp["tested"]:
                L.append(f"  predictor cap: the lane tables got all 16 bits of {wp['hits']} of {wp['tested']} words right; "
                         f"lower end {wp['bits_low']:.4f} bits. A verdict uses {d['bits_low']:.4f} (the {d['limited_by']})")
        L += [f"  note: {n}" for n in r["notes"]] + [""]
    L += ["== sigma^2 against the decimation k (model: sigma^2(k) = k * sigma^2(1))"]
    for row in table:
        if not row["points"]:
            L.append(f"  lane {row['lane']}: no capture with a visible autocorrelation")
            continue
        pts = "  ".join(f"k={p['k']}: {p['sigma2']:.5f} ({p['ratio']:.2f}x)" for p in row["points"])
        tail = "" if row["linear"] is None else (f"; log-log slope {row['exponent']:.2f}; "
               + ("linear" if row["linear"] else "NOT linear") + f" within {args.linear_tolerance:.0%}")
        L.append(f"  lane {row['lane']}: sigma^2 per raw sample {row['sigma2_per_raw_sample']:.6f}{tail}")
        L.append(f"          fitted: {pts}")
        L.append("          on the line, sigma^2 and the model figure with that capture's D (no range, not a verdict): "
                 + "  ".join(f"k={p['k']}: {p['sigma2']:.5f}, {p['bits']:.4f}" for p in row["predicted"]))
    L += ["", "Notes",
          "  - Per-lane figures describe one bit of one lane. They are not to be added up into a figure for",
          "    a symbol or a word: that would need independent lanes.",
          "  - The model figure holds only as far as the model does. A refused fit means it does not; a fit",
          "    that is not refused has passed the checks named above, no more.",
          "  - The cross-lane statistics see dependence between bits at a fixed lag. Rings of different",
          "    frequency that share jitter can pass them.",
          "  - The symbol and word distributions describe one value, not how well a value can be predicted",
          "    from earlier ones. The predictor caps are the measured part of that; they are caps, not estimates."]
    if verdict is None:
        L += ["", "No verdict: no thresholds were given."]
    else:
        L += ["", "Verdict against the given thresholds: " + ("met" if verdict["met"] else "NOT met")]
        L += [f"  {c['what']}: {'ok' if c['ok'] else 'FAILED'}" for c in verdict["checks"]]
    return "\n".join(L) + "\n"

def judge(results, args):
    """Checks against the thresholds given; None without thresholds. Every
    check uses the lower end of a measured figure, never a formula alone."""
    if args.min_lane_bits is None and args.min_word_bits is None and not args.require_independent:
        return None
    checks = []
    for r in results:
        if args.min_lane_bits is not None:
            for l in r["lanes"]:
                e, what = l.get("estimate"), f"k={r['k']} lane {l['lane']}: lower end of the per-bit estimate >= {args.min_lane_bits}"
                if not e:
                    checks.append(dict(what=what + " (no estimate for this lane)", ok=False))
                elif not e["fit"]["ok"]:
                    checks.append(dict(what=what + " (refused, the model does not fit: " + "; ".join(e["fit"]["reasons"]) + ")", ok=False))
                else:
                    caps = f"bias cap {e['bias']['bits_low']:.4f}, predictor cap {e['predictor']['bits_low']:.4f}, model {e['model']['bits_low']:.4f}"
                    checks.append(dict(what=what + f" (is {e['bits_low']:.4f}, the smallest of: {caps})",
                                       ok=e["bits_low"] >= args.min_lane_bits))
        if args.min_word_bits is not None:
            w = r.get("word_distribution")
            checks.append(dict(what=f"k={r['k']}: 16-bit word figure >= {args.min_word_bits} "
                               + (f"(is {w['bits_low']:.4f}, limited by the {w['limited_by']})" if w else "(no words)"),
                               ok=bool(w) and w["bits_low"] >= args.min_word_bits))
        if args.require_independent:
            x = r["cross_lane"]
            checks.append(dict(what=f"k={r['k']}: no lane dependence flagged", ok=not x["flagged_pairs"] and not x["total_flagged"]))
            checks.append(dict(what=f"k={r['k']}: a correlation of {args.max_undetected_phi} would have been flagged "
                               f"(this capture: {x['detectable_phi']:.4f})", ok=x["detectable_phi"] <= args.max_undetected_phi))
    return dict(met=all(c["ok"] for c in checks), checks=checks)

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("captures", nargs="+", help="capture files (*.bin); the sidecar *.json is read if present")
    p.add_argument("--k", type=int, help="decimation of a capture without a sidecar")
    p.add_argument("--out", help="directory for getnoise-analysis.txt and .json (default: next to the first capture)")
    p.add_argument("--lags", type=int, default=32, help="autocorrelation lags, also used for the standard errors (32)")
    p.add_argument("--fit-lags", type=int, default=8, help="lags used by the fit (8)")
    p.add_argument("--cross-lags", type=int, default=4, help="cross-lane lags -n..n (4)")
    p.add_argument("--z", type=float, default=4.5, help="|z| at which a lane pair is flagged (4.5)")
    p.add_argument("--confidence-z", type=float, default=2.576, help="z of the interval whose lower end a verdict uses (2.576)")
    p.add_argument("--fit-z", type=float, default=5.0, help="standard errors a C_j may lie from the fitted model (5)")
    p.add_argument("--linear-tolerance", type=float, default=0.25, help="allowed deviation of sigma^2(k) from the line (0.25)")
    p.add_argument("--min-lane-bits", type=float, help="verdict: required lower end of every lane's per-bit estimate")
    p.add_argument("--min-word-bits", type=float, help="verdict: required 16-bit word figure (distribution and predictor cap)")
    p.add_argument("--require-independent", action="store_true", help="verdict: no lane dependence may be flagged")
    p.add_argument("--max-undetected-phi", type=float, default=0.05,
                   help="with --require-independent: the capture must be able to flag this correlation (0.05)")
    args = p.parse_args(argv)
    try:
        caps = [load(path, args.k) for path in args.captures]
    except (OSError, ValueError) as e:
        print(f"getnoise_analyze: {e}", file=sys.stderr)
        return 2
    results = sorted((analyze(c, args) for c in caps), key=lambda r: r["k"])
    table = decimation(results, args.linear_tolerance)
    verdict = judge(results, args)
    text = report(results, table, args, verdict)
    out = Path(args.out) if args.out else Path(args.captures[0]).parent
    out.mkdir(parents=True, exist_ok=True)
    (out / "getnoise-analysis.txt").write_text(text)
    (out / "getnoise-analysis.json").write_text(json.dumps(dict(
        format="karu64-getnoise-analysis-2", captures=results, decimation=table, verdict=verdict), indent=1) + "\n")
    print(text, end="")
    return 1 if verdict and not verdict["met"] else 0

if __name__ == "__main__":
    sys.exit(main())
