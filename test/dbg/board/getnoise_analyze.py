#!/usr/bin/env python3
"""Offline analysis of GetNoise captures (getnoise_capture.py, getnoise_burst.py);
no board access.

    python3 test/dbg/board/getnoise_analyze.py _build/dbg/board-accept/getnoise-k*.bin
    python3 test/dbg/board/getnoise_analyze.py _build/dbg/board-accept/getnoise-burst-p*.bin

A capture is one byte per raw symbol: bits [3:0] the symbol (lane i in bit i,
one sampled ring oscillator per lane), bit 7 on the first symbol of a run.
Only symbols of the same run are consecutive kept samples, so every statistic
that looks at neighbours is computed inside runs. In a burst capture every
burst is a run. The JSON sidecar gives the decimation k (or --k for a bare
file) and, for a burst capture, the period: the clock cycles between two raw
symbols, 1 to 256. A capture without a period has 256, or --period. The
spacing of the kept samples is clocks = period * k; captures are sorted and
compared by it. A sidecar may also give clock_hz and burst_cycles, the clock
cycle at which each burst started.

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
  * the short-lag fit of (F, sigma^2) per kept sample. Estimator: D is fixed
    to the ones fraction; least squares of the model's exact C_j against the
    measured C_1..C_M. The model value is the closed form
        C_j = (1-2D)^2 + (8/pi^2) sum_{n>=1} sin^2(pi n D)/n^2
                         * cos(2 pi n j F) * exp(-2 pi^2 n^2 j sigma^2),
    which is the paper's Eqn. 12 written as a Fourier series. A grid over
    F in [0, 1/2] and sigma^2 in [1e-4, 2] is followed by a local search.
    Limits: only F mod 1 is visible, and F cannot be told from 1 - F. When
    no C_j differs from (1-2D)^2 by more than four standard errors the data
    carry no trace of the phase, and the result is a lower bound on sigma^2
    and no F. The range given for sigma^2 comes from the fit's sensitivity
    to the C_j and their standard errors.

Per window. With samples close together sigma^2 per sample is small (1e-5
at one clock, say), the autocorrelation reaches over thousands of lags, and
lags 1..8 do not show its decay. Every run is a window; a run longer than
--window symbols is cut into equal consecutive windows. Per lane and window:
  * the long-lag fit. C_j is counted at all lags up to an eighth of the
    window, 4096 at most. The same model is evaluated in another closed
    form: two rectangular waves a phase u apart agree with 1 - 4 min(|u|, D,
    1-D), which is piecewise linear, so its mean over a normal phase
    difference is a sum of one term per corner near j F; the cost does not
    grow as sigma^2 falls. The fit goes from short lags to long ones: a grid
    over F and sigma^2 at lags 1..4, then least squares (Gauss-Newton) at
    lags 1..8, then at every lag up to 8 and eight per octave up to 16, 32,
    .., each step starting from the one before, so that F is known well
    enough for the next. It stops when nothing is left of the fundamental at
    the largest lag. A window's own mean frequency is what its F fits, so
    the phase between two samples j apart has the variance of a bridge,
    j sigma^2 (1 - j/n) for n symbols; that is the variance used.
  * over the windows: how many could be fitted (some rho_1..rho_8 four
    standard errors from 0), the median and spread of F, the median and
    scatter of sigma^2 from the fits with all lags, and a range for that
    typical sigma^2 from the scatter between windows or the fits' own
    errors, whichever is larger. The fits' own errors are a rule of thumb
    fitted to model data (variance of ln sigma^2 = 2r / (1 + 16r), r the
    coherence time of the fundamental over the window), since the residuals
    of one fit are correlated from lag to lag.
  * sigma^2 by lag range: the median over windows of each step of the fits
    (largest lag 8, 16, 32, ..). On the model all steps agree. Wander of F
    inside a window, jitter that grows faster than white noise does, and
    bursts wrongly joined into one run raise the steps with long lags;
    noise of the sampling instant raises those with short lags. With eight
    windows or more, the steps whose scatter is within twice the smallest
    are the determined ones, and the smallest of their medians is the
    windows' sigma^2. Being the smallest of several, it is 1 to 4 % low on
    model data (10 % with F next to 1/4).
  * the pooled fit: the same long-lag fit on the autocorrelation pooled
    over the windows (no bridge). The frequency of a ring drifts with
    temperature and supply; when F differs from window to window the pooled
    autocorrelation decays faster and its sigma^2 is too large. Wander is
    indicated when the spread of the windows' F is three times what the
    jitter alone gives (sqrt(sigma^2 / n) and the fits' errors), when the
    pooled sigma^2 is 1.5 times the windows' at its lower end, or when the
    fits with all lags give 1.5 times the smallest step at their lower end.
    With burst stamps, F is also regressed on the time a window started.
  * the sigma^2 that feeds the model figure below: the windows' value when
    nine in ten windows could be fitted, else the pooled fit, and never more
    than the short-lag fit where that fit applies (the pooled sigma^2 is
    0.002 or more). Its lower end is the smallest of the lower ends of the
    windows, the pooled fit and the short-lag fit. The report says which.
  * the capture's fit, checked against the data as before: the short-lag
    fit, or the pooled long-lag fit where its sigma^2 is below 0.002. In
    that case, and when the correlation has not died out within --lags, the
    check uses all lags of the windows and the per-window fits.
  Limits: a window that holds few coherence times of the ring gives a poor
  sigma^2 from its long lags (scatter 0.3 in ln sigma^2 at 1e-5 and 32768
  symbols) and the typical value needs many windows; F next to 0, 1/4 or 1/2
  leaves no lag range better than another; at 1e-7 nothing is determined in
  32768 symbols. Wander inside a window is not removed, only avoided by
  the short lag ranges. Bursts joined into one run are noticed through the
  sidecar (run lengths, burst stamps); without it they are not, and raise
  sigma^2 where it is small.

Spectrum per lane (Blackman-Tukey): the autocorrelation pooled over the
windows, each with its own mean taken off, times a four-term Blackman-Harris
lag window, transformed (a radix-2 DFT written out here). 1 is the level of
a lane without memory; the floor is the median. The same is done with the
autocorrelation of the fitted model, window by window. The highest lines are
listed with their height over the floor and labelled n F where they are at
n F mod 1, folded. A spur is a stretch of the spectrum above the model's by
the chance level of one frequency times four, the allowance for the fit;
for a lane where nothing was fitted the model is a flat spectrum, and the
chance level alone decides. Limits: nothing below 1e-4 of the highest line
(the window's leakage); lines closer than 2/lags are one; a disturbance at
a model line is seen only when it is four times the line.

Coherence per pair of lanes: the cross-correlation at lags -L..L, pooled
over the windows, times a Parzen lag window, transformed, squared and
divided by the two lanes' spectra from the same lags and window. Two rings
that keep a phase relation which repeats in every window give a coherence
near 1 at their frequency. For independent lanes it is about one over the
number of independent segments: that number is the number of windows, since
two lanes of the same F that hold their phase through a window are one
segment per window; only when one of the lanes has no memory over the last
three quarters of the lags are pieces as long as the lag window counted. A
pair is flagged when the largest coherence exceeds the value that
independent segments reach with the probability of |z| = --z, shared out
over the frequencies. Limits: a coherence below that value is not seen (0.46
for 32 windows); frequencies at which a lane is below its leakage are not
judged; dependence whose phase changes from window to window is not seen.

Shared wander per pair of lanes: the rank correlation, over the windows, of
the two lanes' fitted F, as a z score that allows for the serial correlation
of the two series and for the number of windows (Student's t). A common
change of supply or temperature moves the rings together. Eight windows
fitted in both lanes are needed; about 0.7 is the smallest correlation that
32 windows can flag, and a wander smaller than the scatter of the fitted F
is not seen.

Per bit of a lane, as -log2 of a guessing probability, each with a lower end
(the probability taken at the upper end of a --confidence-z interval, 2.576
by default):
  * bias cap: max(p1, 1-p1). No estimate for a bit can be above it;
  * predictor cap: the success rate of a table that predicts a bit from the
    twelve before it, built on the first half of the capture and counted on
    the second half. Any explicit predictor's rate is a cap as well;
  * model: the average probability of guessing a bit when the previous phase
    is known, for the measured D and the sigma^2 named above. For D = 1/2
    this is the p_e of the paper's Eqn. 16; for other D it grows towards the
    bias cap. The larger of that and the looser bound p_e <= 1 - tanh(pi
    sigma)/2 is used. That bound alone assumes D = 1/2: it is printed for
    reference and never used by itself;
  * the estimate is the smallest of the three, and its lower end the
    smallest of their lower ends.
  The model figure is refused, and with it any verdict for the lane, when
  the model does not fit: when some measured C_j, at any computed lag, is
  more than --fit-z standard errors (5 by default) from the fitted model's
  value; when the serial correlation has not died out by the last lag, so
  that those standard errors are too small; or when the predictor guesses
  more bits than the model says anyone can. The standard error of C_j is
  sqrt((1 + 2 sum rho_m^2) / pairs), Bartlett's large-lag formula.

Across captures: the model says that sigma^2 is proportional to the spacing
in clocks. The values that feed the model figures are compared with the line
through the origin whose slope is the mean of sigma^2 / clocks; captures
with only a lower bound are left out. A slope above 1 in the log-log plot is
jitter that grows faster than white noise does. Captures with the same
spacing (a burst capture at period 256 and a k = 1 capture) are compared
lane by lane: the differences of the ones fraction and of C_1..C_8 over
their combined standard errors, flagged at --agree-z.

Across lanes: for all six pairs, at lag 0 and small lags, the correlation
(phi) of the two bits, the chi-square of their 2x2 table, the mutual
information, and a z score of phi that allows for the serial correlation of
each lane (Bartlett: var(phi) = sum_j rho_a(j) rho_b(j) / n for independent
lanes). When both lanes still remember in the last quarter of --lags, the
sum runs over the windows' lags instead, is not let below 1, and counts
lanes that remember past an eighth of a window as remembering to its end. A
pair is flagged when |z| reaches --z. For the four lanes together, the total
correlation (sum of lane entropies minus symbol entropy) at lag 0, flagged
above four times the value that sampling alone gives. The report also gives
the smallest correlation the capture could have flagged.
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
  --require-independent  no pair, coherence or shared wander is flagged, and
                         the capture is large enough to have flagged a
                         correlation of --max-undetected-phi
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, cmath, hashlib, itertools, json, math, re, struct, sys
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
DEFAULT_PERIOD = 256                                        # clocks per raw symbol of a capture whose sidecar has no period
ROOT_2, ROOT_2PI = math.sqrt(2), math.sqrt(2 * math.pi)
# the long-lag fit
KINK = 4.0                                                  # two rectangular waves u apart agree with C = 1 - 4 min(|u|, D, 1-D)
BRIDGE = 1.0                                                # share of j/n taken off the variance at lag j when a window's own F is fitted
LONG_LAGS = 4096                                            # largest lag of the fit and the spectrum; never above an eighth of a window
LAG_DENSE, LAG_OCTAVE, LAG_GROWTH = 8, 8, 2                 # every lag up to 8, then 8 per octave; the largest lag doubles per step
S2_START = (1e-6, 1e-4, 1e-3, 4e-3, 1.5e-2, 4e-2, 0.1, 0.25, 0.6)
S2_MIN, S2_MAX = 1e-9, 4.0
IDENT_Z = 4.0                                               # a window is fitted when some rho_1..rho_8 is this many standard errors from 0
MIN_WINDOW = 256                                            # shorter windows are not fitted
USABLE = 0.9                                                # share of the fitted windows that must be identifiable for their figures to be used
MIN_WANDER_WINDOWS = 8                                      # windows needed to judge wander, shared wander and drift
MEDIAN_ERROR = 1.5                                          # standard error of a median of n fits over scatter / sqrt(n): 1.25 for normal values, more as measured
STEP_SCATTER = 0.5                                          # scatter of ln sigma^2 between windows above which no step of the fits is determined
SHORT_FIT_MIN = 2e-3                                        # below this sigma^2 the short-lag fit cannot resolve the decay
WANDER_SPREAD, WANDER_RATIO = 3.0, 1.5                      # wander is indicated above these ratios
# spectra
TAPER = (0.35875, 0.48829, 0.14128, 0.01168)                # four-term Blackman-Harris: side lobes 92 dB (2.5e-5) below a line
LEAKAGE = 1e-4                                              # nothing is read below this share of a spectrum's highest point
SPECTRUM_Z = 5.0                                            # chance level of one frequency of a spectrum
MODEL_TOLERANCE = 4.0                                       # a spur stands this far above the fitted model's spectrum
LINES_KEPT, SPURS_KEPT, HARMONICS = 8, 16, 9
QUIET_Z = 5.0                                               # a lane is quiet when no rho in the last three quarters of the cross lags exceeds this

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

# ---- the long-lag fit ----
def model_lags(F, D, s2, lags, span=0, deriv=False):
    """C_j of the model at the given lags, and with deriv its derivatives by F
    and by ln sigma^2. The phase advance over j samples is j F + N(0, v) with
    v = j s2, or v = j s2 (1 - j/span) for a window of span samples whose own
    mean frequency is the F given. Two lanes a phase u apart agree with
    C(u) = 1 - KINK min(|u|, D, 1-D), a piecewise linear function, so for
    small v its mean over the normal distribution is a closed form with one
    term per corner near j F; for large v the Fourier series of model_c has
    few terms. Its cost does not grow as sigma^2 falls."""
    m, base = min(D, 1 - D), (1 - 2 * D) ** 2
    erfc, exp, floor, sin, cos, pi = math.erfc, math.exp, math.floor, math.sin, math.cos, math.pi
    corners = [(k + d, w) for k in (-1, 0, 1, 2) for d, w in ((0.0, 1.0), (m, -0.5), (-m, -0.5))]
    cs, dF, dS = [], [], []
    for j in lags:
        v = j * s2 * (1 - BRIDGE * j / span) if span else j * s2
        mu = j * F
        mu -= floor(mu)
        if v >= 0.04:
            a, c, cF, cS, n = 2 * pi * pi * v, base, 0.0, 0.0, 1
            while True:
                e = exp(-a * n * n)
                if e < 1e-10:
                    break
                w = K8 * sin(pi * n * D) ** 2 / (n * n) * e
                c += w * cos(2 * pi * n * mu)
                if deriv:
                    cF -= w * 2 * pi * n * j * sin(2 * pi * n * mu)
                    cS -= w * a * n * n * cos(2 * pi * n * mu)
                n += 1
            cs.append(c)
            if deriv:
                dF.append(cF); dS.append(cS)
            continue
        u = mu if mu <= 0.5 else 1 - mu
        h, slope, curve = (u if u < m else m), (1.0 if mu < m else 0.0 if mu < 1 - m else -1.0), 0.0
        if v > 0:
            s = math.sqrt(v)
            reach = 6 * s
            for p, w in corners:
                t = mu - p
                if -reach < t < reach:
                    t /= s
                    density, tail = exp(-0.5 * t * t) / ROOT_2PI, 0.5 * erfc(abs(t) / ROOT_2)
                    h += s * w * 2 * (density - abs(t) * tail)
                    if deriv:
                        slope += w * (-2 * tail if t > 0 else 2 * tail)
                        curve += w * density / s
        cs.append(1 - KINK * h)
        if deriv:
            dF.append(-KINK * j * slope); dS.append(-KINK * v * curve)
    return (cs, dF, dS) if deriv else cs

def ladder(top):
    """The lags of one step of the fit: every lag up to LAG_DENSE, then
    LAG_OCTAVE per octave up to top."""
    lags, x, ratio = list(range(1, min(LAG_DENSE, top) + 1)), float(LAG_DENSE), 2 ** (1 / LAG_OCTAVE)
    while True:
        x *= ratio
        j = int(round(x))
        if j > top:
            return lags
        if j > lags[-1]:
            lags.append(j)

def refine(F, theta, lags, cs, D, span):
    """Least squares in (F, theta = ln sigma^2) from a starting point, by
    damped Gauss-Newton steps. A step in F is limited to an eighth of the
    period that the model has in F at the largest lag, so that it stays in
    the valley it started in. Returns F, theta, the sum of squares and the
    normal matrix (a, b, c)."""
    def at(F, theta):
        mod, dF, dS = model_lags(F, D, math.exp(theta), lags, span, True)
        return sum((x - y) ** 2 for x, y in zip(mod, cs)), mod, dF, dS
    limit, damp = 1 / (8.0 * lags[-1]), 1e-3
    err, mod, dF, dS = at(F, theta)
    for _ in range(12):
        a = b = c = g1 = g2 = 0.0
        for x, y, p, q in zip(mod, cs, dF, dS):
            a += p * p; b += p * q; c += q * q; g1 += p * (x - y); g2 += q * (x - y)
        gain = None
        for _ in range(8):
            a2, c2 = a * (1 + damp) + 1e-30, c * (1 + damp) + 1e-30
            det = a2 * c2 - b * b
            if det > 0:
                F2 = abs(F + max(-limit, min(limit, -(c2 * g1 - b * g2) / det)))
                F2 = 1 - F2 if F2 > 0.5 else F2
                theta2 = min(math.log(S2_MAX), max(math.log(S2_MIN), theta + max(-1.5, min(1.5, -(a2 * g2 - b * g1) / det))))
                trial = at(F2, theta2)
                if trial[0] < err:
                    gain, F, theta, damp = err - trial[0], F2, theta2, max(damp / 10, 1e-9)
                    err, mod, dF, dS = trial
                    break
            damp *= 10
        if gain is None or gain < 1e-9 * err + 1e-18:
            break
    return F, theta, err, (sum(p * p for p in dF), sum(p * q for p, q in zip(dF, dS)), sum(q * q for q in dS))

STARTS = {}
def start_table(D):
    """For the start of fit_long: C_j of the model for j = 1..4 at every
    sigma^2 of S2_START and every phase advance g/128 per lag, with D rounded
    to 0.01 (the start only has to find the right valley)."""
    key = (round(D * 100), KINK, K8)
    if key not in STARTS:
        Dq = min(0.99, max(0.01, key[0] / 100))
        STARTS[key] = [[[model_lags(g / 128 / j, Dq, s2, [j])[0] for g in range(128)] for j in (1, 2, 3, 4)] for s2 in S2_START]
    return STARTS[key]

def fit_long(cs, D, n, span=0):
    """(F, sigma^2) from C_1..C_top of n symbols, D fixed; see the module
    text. span = n for one window (its own mean frequency is fitted), 0 for
    an autocorrelation pooled over windows. cs[j-1] is C_j."""
    top, base = len(cs), (1 - 2 * D) ** 2
    signal = max(abs(c - base) / (1 - base) * math.sqrt(max(n - j, 1)) for j, c in enumerate(cs[:LAG_DENSE], 1))
    if signal < IDENT_Z:
        return dict(identifiable=False, signal=signal)
    # the start: lags 1..4, where the model has one valley in F per quarter cycle at most
    table, first = start_table(D), cs[:4]
    start = min((sum((row[j * g % 128] - c) ** 2 for j, (row, c) in enumerate(zip(rows, first), 1)), g / 128, s2)
                for s2, rows in zip(S2_START, table) for g in range(65))
    F, theta, reach, steps = start[1], math.log(start[2]), LAG_DENSE, []
    while True:
        reach = min(reach, top)
        lags = ladder(reach)
        F, theta, err, (a, b, c) = refine(F, theta, lags, [cs[j - 1] for j in lags], D, span)
        # Standard errors from the residuals: least squares linearised at the optimum, the
        # residual variance not below that of independent bits. Where these lags do not show
        # sigma^2 at all, its error is without bound.
        noise, det = max(err / max(1, len(lags) - 2), 1.0 / n), a * c - b * b
        var_s, var_F = (noise * a / det, noise * c / det) if det > 1e-12 * a * c else (noise / c if c > 1e-12 else math.inf, math.inf)
        steps.append(dict(lag_max=reach, F=F, sigma2=math.exp(theta), se_ln=min(50.0, math.sqrt(var_s))))
        # stop at the last lag, or when nothing is left of the fundamental at the largest lag used
        if reach >= top or math.exp(-2 * math.pi ** 2 * reach * math.exp(theta)) < 1e-4:
            break
        reach *= LAG_GROWTH
    s2 = math.exp(theta)
    # The residuals are correlated from lag to lag, which their standard errors do not allow
    # for. A second part does, a rule of thumb fitted to model data: with r the coherence
    # time of the fundamental over the number of symbols, the variance of ln sigma^2 is
    # 2r / (1 + 16r).
    r = 1 / (2 * math.pi ** 2 * s2 * n)
    return dict(identifiable=True, F=F, sigma2=s2, se_ln=min(50.0, math.sqrt(var_s + 2 * r / (1 + 16 * r))), se_F=min(0.5, math.sqrt(var_F + s2 / n)),
                lag_max=reach, lags=len(lags), rms_residual=math.sqrt(err / len(lags)), signal=signal, steps=steps)

def span_of(f, zc):
    """A fit with its sigma^2 range at z = zc."""
    if f.get("identifiable"):
        spread = math.exp(min(50.0, zc * f["se_ln"]))
        f.update(sigma2_low=f["sigma2"] / spread, sigma2_high=f["sigma2"] * spread)
    return f

# ---- spectra ----
TWIDDLE = {}
def dft(x):
    """X[k] = sum_t x[t] exp(-2 pi i k t / n) for a list whose length n is a
    power of two (radix 2, recursive)."""
    n = len(x)
    if n == 1:
        return list(x)
    if n not in TWIDDLE:
        TWIDDLE[n] = [cmath.exp(-2j * math.pi * k / n) for k in range(n // 2)]
    even, odd = dft(x[0::2]), dft(x[1::2])
    odd = [t * v for t, v in zip(TWIDDLE[n], odd)]
    return [a + b for a, b in zip(even, odd)] + [a - b for a, b in zip(even, odd)]

WINDOWS = {}
def lag_window(top):
    """The lag window w(0..top) of the Blackman-Tukey estimates: four-term
    Blackman-Harris, w(0) = 1, falling to nearly 0 at the last lag."""
    if (top, TAPER) not in WINDOWS:
        WINDOWS[top, TAPER] = [sum(a * math.cos(i * math.pi * l / top) for i, a in enumerate(TAPER)) / sum(TAPER) for l in range(top + 1)]
    return WINDOWS[top, TAPER]

def cross_window(top):
    """The lag window w(0..top) of the cross-spectrum and of the two spectra
    it is compared with: Parzen's. Its transform is nowhere negative, so
    that what leaks from the lines of a lane only adds up, and the coherence
    between lines cannot exceed that at the lines."""
    if (top, "cross") not in WINDOWS:
        WINDOWS[top, "cross"] = [1 - 6 * u * u * (1 - u) if u <= 0.5 else 2 * (1 - u) ** 3 for u in (l / top for l in range(top + 1))]
    return WINDOWS[top, "cross"]

def bins_for(top):
    """Size of the transform for lags up to top: at least four points per lag."""
    return 1 << max(4, (4 * top - 1).bit_length())

def power_spectrum(rho, window=lag_window):
    """S(k / K), k = 0..K/2, of a lane from rho_1..rho_top: 1 + 2 sum w(l)
    rho_l cos(2 pi l k / K). A lane without memory has S = 1 everywhere."""
    top = len(rho)
    size, w = bins_for(top), window(top)
    x = [0.0] * size
    x[0] = 1.0
    for l, r in enumerate(rho, 1):
        x[l] = x[size - l] = w[l] * r
    return [v.real for v in dft(x)[:size // 2 + 1]]

def wilson_hilferty(dof, z):
    """The value that a chi-square variable over its dof exceeds with the
    probability that a standard normal variable exceeds z."""
    return max(0.0, 1 - 2 / (9 * dof) + z * math.sqrt(2 / (9 * dof))) ** 3

def fold(f):
    f %= 1.0
    return min(f, 1 - f)

def lane_spectrum(rho, ref, fitted, pairs, harmonics):
    """Lines and spurs of one lane: the spectrum of the measured rho against
    that of the fitted model (ref), both through the same window. harmonics is
    [(n, frequency, tolerance)] for the labels."""
    top = len(rho)
    S, R = power_spectrum(rho), power_spectrum(ref) if fitted else None
    half, size = len(S) - 1, 2 * (len(S) - 1)
    lobe = max(1, len(TAPER) * size // (2 * top))                              # half the main lobe of the window, in bins
    peak = max(S)
    floor = max(sorted(S)[half // 2], LEAKAGE * peak, 1e-12)
    # sampling: the estimate at one frequency has about 2 n / sum w^2 degrees of freedom
    dof = 2 * pairs / sum(2 * v * v for v in lag_window(top))
    chance = wilson_hilferty(dof, SPECTRUM_Z)
    if fitted:
        # the model's spectrum, widened by the main lobe so that a line may sit a little off
        wide = [max(R[max(0, k - lobe):k + lobe + 1]) for k in range(half + 1)]
        allowed = [chance * max(MODEL_TOLERANCE * v, floor) for v in wide]
    else:
        wide, allowed = [1.0] * (half + 1), [chance * max(1.0, floor)] * (half + 1)
    def label(k):
        for n, f, tol in harmonics:
            if abs(k / size - f) <= tol + lobe / size:
                return n
        return None
    # spurs: stretches of the spectrum above what the model allows; stretches less than a lobe apart are one
    spurs, over, k = [], [], 0
    while k <= half:
        if S[k] > allowed[k]:
            end = k
            while end < half and any(S[i] > allowed[i] for i in range(end + 1, min(half, end + lobe) + 1)):
                end += 1
            at = max(range(k, end + 1), key=S.__getitem__)
            over.append((k - lobe, end + lobe))
            spurs.append(dict(frequency=at / size, height=S[at] / floor, over_model=S[at] / max(wide[at], 1e-12)))
            k = end + 1
        else:
            k += 1
    spurs.sort(key=lambda s: -s["height"])
    # lines: the highest local maxima that stand clear of everything higher: between a line and
    # the nearest higher point on either side the spectrum falls to less than 1/clear of the line
    lines, clear, tried = [], max(2.0, chance * chance), 0
    for k in sorted(range(half + 1), key=lambda k: -S[k]):
        if S[k] <= chance * floor or len(lines) >= LINES_KEPT or tried >= 16 * LINES_KEPT:
            break
        if S[k] < max(S[max(0, k - lobe):k + lobe + 1]):
            continue
        tried += 1
        alone = True
        for step in (-1, 1):
            i = k + step
            while 0 <= i <= half and S[k] / clear <= S[i] <= S[k]:
                i += step
            alone = alone and not (0 <= i <= half and S[i] > S[k])
        if alone:
            spur = any(a <= k <= b for a, b in over)
            lines.append(dict(frequency=k / size, height=S[k] / floor, harmonic=None if spur else label(k), spur=spur))
    return dict(lags=top, bins=half, resolution=lobe / size, floor=floor, floor_is_leakage=floor == LEAKAGE * peak, peak=peak,
                degrees_of_freedom=dof, line_threshold=chance, spur_threshold=chance * (MODEL_TOLERANCE if fitted else 1.0),
                fitted=fitted, lines=lines, spurs=spurs[:SPURS_KEPT], spur_count=len(spurs))

# ---- reading a capture ----
def load(path, k_arg=None, period_arg=None):
    path = Path(path)
    raw = path.read_bytes()
    side = path.with_suffix(".json")
    meta = json.loads(side.read_text()) if side.exists() else {}
    if meta.get("sha256") and meta["sha256"] != hashlib.sha256(raw).hexdigest():
        raise ValueError(f"{path}: contents do not match the sha256 in {side.name}")
    k = meta.get("k") or k_arg
    if not k:
        raise ValueError(f"{path}: no sidecar with the decimation; give --k")
    try:
        k, period = int(k), int(meta.get("period") or period_arg or DEFAULT_PERIOD)
    except (TypeError, ValueError):
        k = period = 0
    if k < 1 or period < 1:
        raise ValueError(f"{path}: the period and the decimation must be positive integers")
    runs = re.findall(rb"[\x80-\x8f][\x00-\x0f]*", raw)
    if not raw or sum(map(len, runs)) != len(raw):
        raise ValueError(f"{path}: not a capture (empty, first symbol without the run flag, or bits [6:4] set)")
    if meta and (meta.get("stored") != len(raw) or meta.get("run_lengths") != [len(r) for r in runs]):
        raise ValueError(f"{path}: symbol count or run lengths do not match {side.name}")
    stamps = meta.get("burst_cycles")
    if stamps is not None and (not isinstance(stamps, list) or len(stamps) != len(runs) or not all(isinstance(s, int) for s in stamps)
                               or any(b <= a for a, b in zip(stamps, stamps[1:]))):
        raise ValueError(f"{path}: burst_cycles in {side.name} is not one increasing clock-cycle stamp per run")
    return dict(file=str(path), k=k, period=period, clocks=period * k, kind=meta.get("kind", "capture"), clock_hz=meta.get("clock_hz"),
                burst_cycles=stamps, meta=meta, runs=[r.translate(SYM_TAB) for r in runs])

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

# ---- per window: every run, or every piece of a run cut at --window symbols ----
def window_cuts(lengths, window):
    """(run, start, length) of the windows: each run in equal consecutive
    pieces of at most `window` symbols."""
    out = []
    for r, n in enumerate(lengths):
        pieces = -(-n // window)
        out += [(r, i * n // pieces, (i + 1) * n // pieces - i * n // pieces) for i in range(pieces)]
    return out

def agreements(b, n, top):
    """How many of the n - j pairs of samples j apart are equal, j = 1..top;
    b holds the n samples as bits. The top j bits of b ^ (b >> j) are those
    of b and are counted off again."""
    return [n - j - (b ^ (b >> j)).bit_count() + (b >> (n - j)).bit_count() for j in range(1, top + 1)]

def window_view(cap, ints, args):
    """The windows of a capture and, per lane, their fits and what is pooled
    over them: agreements, the autocorrelation with each window's own mean
    taken off (rho), and the same for the fitted model (ref). None when no
    run has MIN_WINDOW symbols."""
    wins = [w for w in window_cuts([len(r) for r in cap["runs"]], args.window) if w[2] >= MIN_WINDOW]
    if not wins:
        return None
    tops = [min(n // 8, LONG_LAGS) for _, _, n in wins]
    top, symbols = max(tops), sum(n for _, _, n in wins)
    # when a window started, in clock cycles: known between bursts from their stamps, and inside one run
    times = ([cap["burst_cycles"][r] + s * cap["clocks"] for r, s, _ in wins] if cap["burst_cycles"]
             else [s * cap["clocks"] for _, s, _ in wins] if len(cap["runs"]) == 1 else None)
    view = dict(wins=wins, tops=tops, top=top, symbols=symbols, times=times, lanes=[])
    for lane in range(LANES):
        same, pairs, rho, ref, ones, fits, pieces = [0] * top, [0] * top, [0.0] * top, [0.0] * top, 0, [], []
        for (r, s, n), reach in zip(wins, tops):
            b = (ints[lane][r][1] >> s) & ((1 << n) - 1)
            agree, count = agreements(b, n, reach), b.bit_count()
            pieces.append(b)
            ones += count
            same[:reach] = [x + y for x, y in zip(same, agree)]
            pairs[:reach] = [x + n - j for j, x in enumerate(pairs[:reach], 1)]
            D = count / n
            if not 0 < D < 1:
                fits.append(dict(identifiable=False, signal=0.0, symbols=n, ones_fraction=D))
                continue
            base = (1 - 2 * D) ** 2
            cs = [2 * a / (n - j) - 1 for j, a in enumerate(agree, 1)]
            rho[:reach] = [x + (n - j) * (c - base) / (1 - base) for j, (x, c) in enumerate(zip(rho, cs), 1)]
            f = fit_long(cs, D, n, n)
            if f["identifiable"]:
                live = min(reach, int(1.1 / f["sigma2"]) + 8)                   # beyond it the model has nothing left
                mod = model_lags(f["F"], D, f["sigma2"], range(1, live + 1), n)
                ref[:live] = [x + (n - j) * (c - base) / (1 - base) for j, (x, c) in enumerate(zip(ref, mod), 1)]
            fits.append(dict(f, symbols=n, ones_fraction=D))
        D = ones / symbols
        lane_view = dict(fits=fits, pieces=pieces, ones_fraction=D, pairs=pairs, cs=[2 * a / p - 1 for a, p in zip(same, pairs)],
                         rho=[x / p for x, p in zip(rho, pairs)], ref=[x / p for x, p in zip(ref, pairs)])
        lane_view["pooled"] = span_of(fit_long(lane_view["cs"], D, symbols), args.confidence_z) if 0 < D < 1 else dict(identifiable=False, signal=0.0)
        view["lanes"].append(lane_view)
    return view

def median(values):
    values = sorted(values)
    return (values[(len(values) - 1) // 2] + values[len(values) // 2]) / 2

def window_summary(view, lane, cap, zc):
    """What the windows of one lane say: the typical F and sigma^2 with their
    scatter, the drift of F, and the wander indicators."""
    lv = view["lanes"][lane]
    fits = lv["fits"]
    good = [f for f in fits if f["identifiable"]]
    w = dict(count=len(fits), identifiable=len(good), usable=len(good) >= max(1, math.ceil(USABLE * len(fits))),
             symbols=view["symbols"], longest=max(f["symbols"] for f in fits), lags=view["top"],
             F=[f.get("F") for f in fits], sigma2=[f.get("sigma2") for f in fits], start_cycle=view["times"])
    wander = dict(judged=len(good) >= MIN_WANDER_WINDOWS, indicated=False, sigma2_ratio=None, F_spread_ratio=None, inside_ratio=None, drift=None)
    if not good:
        return w, wander
    F_mid = median(f["F"] for f in good)
    logs = [math.log(f["sigma2"]) for f in good]
    mid, own = median(logs), math.sqrt(sum(f["se_ln"] ** 2 for f in good) / len(good))
    scatter = math.sqrt(sum((x - sum(logs) / len(logs)) ** 2 for x in logs) / (len(logs) - 1)) if len(logs) > 1 else 0.0
    # the range of the typical value: the larger of the scatter between windows and
    # the fits' own standard errors, for the median of len(good) of them
    se = (MEDIAN_ERROR if len(good) > 2 else 1.0) * max(scatter, own) / math.sqrt(len(good))
    spread = math.exp(min(50.0, zc * se))
    w.update(F_median=F_mid, F_min=min(f["F"] for f in good), F_max=max(f["F"] for f in good),
             F_spread=1.4826 * median(abs(f["F"] - F_mid) for f in good) if len(good) > 1 else None,
             F_expected_spread=math.sqrt(median(f["se_F"] ** 2 for f in good)),
             sigma2_median=math.exp(mid), sigma2_low=math.exp(mid) / spread, sigma2_high=math.exp(mid) * spread,
             sigma2_scatter=scatter, sigma2_own_error=own, se_ln=se, lag_max=max(f["lag_max"] for f in good))
    # sigma^2 by the largest lag of the fit, from the steps of the windows' fits. Wander inside
    # a window, jitter that grows faster than white noise, and bursts that were joined all show
    # at the long lags; noise of the sampling instant shows at the short ones. A step's scatter
    # is that between windows, or the fits' own error where that is larger (lags that do not
    # show sigma^2); the steps within twice the smallest scatter are the determined ones.
    w["by_lag"], w["sigma2_best"] = [], None
    if wander["judged"]:
        for reach in sorted({s["lag_max"] for f in good for s in f["steps"]}):
            steps = [s for f in good for s in f["steps"] if s["lag_max"] == reach]
            if len(steps) >= USABLE * len(good):
                values = [math.log(s["sigma2"]) for s in steps]
                centre, mean = median(values), sum(values) / len(values)
                error = max(math.sqrt(sum((x - mean) ** 2 for x in values) / (len(values) - 1)), math.sqrt(sum(s["se_ln"] ** 2 for s in steps) / len(steps)))
                w["by_lag"].append(dict(lag_max=reach, windows=len(steps), sigma2=math.exp(centre), scatter=error, determined=False,
                                        sigma2_low=math.exp(centre - min(50.0, zc * MEDIAN_ERROR * error / math.sqrt(len(steps))))))
        least = min(row["scatter"] for row in w["by_lag"])
        if least <= STEP_SCATTER:
            for row in w["by_lag"]:
                row["determined"] = row["scatter"] <= max(2 * least, 0.05)
            rows = [row for row in w["by_lag"] if row["determined"]]
            lowest = min(rows, key=lambda row: row["sigma2"])
            last = w["by_lag"][-1]
            w["sigma2_best"] = dict(value=lowest["sigma2"], low=min(row["sigma2_low"] for row in rows), lag_max=lowest["lag_max"],
                                    growth=last["sigma2"] / lowest["sigma2"], growth_low=last["sigma2_low"] / lowest["sigma2"])
    pooled = lv["pooled"]
    if pooled["identifiable"]:
        wander["sigma2_ratio"] = pooled["sigma2"] / w["sigma2_median"]
    # the spread of F says nothing where F is folded: within four spreads of 0 or 1/2
    if w["F_spread"] is not None and min(F_mid, 0.5 - F_mid) > 4 * max(w["F_spread"], w["F_expected_spread"]):
        wander["F_spread_ratio"] = w["F_spread"] / w["F_expected_spread"]
    if wander["judged"]:
        wander["inside_ratio"] = w["sigma2_best"]["growth"] if w["sigma2_best"] else None
        wander["indicated"] = bool((wander["F_spread_ratio"] or 0) >= WANDER_SPREAD or (wander["sigma2_ratio"] or 0) / spread >= WANDER_RATIO
                                   or (w["sigma2_best"] or dict(growth_low=0))["growth_low"] >= WANDER_RATIO)
        if view["times"]:
            # F against the time a window started: least squares
            pts = [(t, f["F"]) for t, f in zip(view["times"], fits) if f["identifiable"]]
            t0, f0 = sum(t for t, _ in pts) / len(pts), sum(f for _, f in pts) / len(pts)
            sxx = sum((t - t0) ** 2 for t, _ in pts)
            if sxx > 0:
                slope = sum((t - t0) * (f - f0) for t, f in pts) / sxx
                rest = sum((f - f0 - slope * (t - t0)) ** 2 for t, f in pts) / (len(pts) - 2)
                length = max(t for t, _ in pts) - min(t for t, _ in pts)
                wander["drift"] = dict(total=slope * length, cycles=length, z=slope / math.sqrt(rest / sxx) if rest > 0 else 0.0)
                if cap["clock_hz"]:
                    wander["drift"].update(seconds=length / cap["clock_hz"], per_second=slope * cap["clock_hz"])
    return w, wander

def choose(f, pooled, w):
    """The sigma^2 that feeds the model figure, and where it comes from. Wander
    of F between windows makes a pooled fit too large, so the value is that of
    the windows when enough of them could be fitted: the smallest over the
    determined lag ranges of their fits, or their median with all lags when
    no range is determined or the windows are few. Without usable windows it
    is the pooled long-lag fit. Where the capture's fit is the short-lag one,
    the value is not above that either. The lower end is the smallest of the
    lower ends of the windows, the pooled fit and the short-lag fit. A
    short-lag fit that gives only a lower bound stands alone, as before."""
    if f["method"] == "short-lag" and not f["identifiable"]:
        return dict(value=f["sigma2"], low=f["sigma2_low"], value_from="short-lag fit", low_from="short-lag fit", is_lower_bound=True, candidates={})
    found = {}
    if w and w["usable"]:
        best = w["sigma2_best"]
        found["windows"] = (best["value"], best["low"]) if best else (w["sigma2_median"], w["sigma2_low"])
    if pooled and pooled["identifiable"]:
        found["pooled fit"] = (pooled["sigma2"], pooled["sigma2_low"])
    if f["method"] == "short-lag":
        found["short-lag fit"] = (f["sigma2"], f["sigma2_low"])
    values = [n for n in found if n != "pooled fit" or "windows" not in found]
    value_from, low_from = min(values, key=lambda n: found[n][0]), min(found, key=lambda n: found[n][1])
    return dict(value=found[value_from][0], low=found[low_from][1], value_from=value_from, low_from=low_from, is_lower_bound=False,
                candidates={n: dict(sigma2=v, sigma2_low=low) for n, (v, low) in found.items()})

def harmonic_labels(F, D, s2, spread):
    """[(n, frequency, tolerance)] of the model's lines that are narrow enough
    to be told apart: n F mod 1 folded, as wide as its line and the scatter of F."""
    out = []
    for n in range(1, HARMONICS + 1):
        width = math.pi * n * n * s2
        if K8 * math.sin(math.pi * n * D) ** 2 / (n * n) > 1e-4 and width < 0.05:
            out.append((n, fold(n * F), width + 2 * n * spread))
    return out

def cross_spectrum(view, a, b, top, spectra, z_flag):
    """Coherence of two lanes from lags -top..top; spectra are the lanes' own
    spectra from the same lags. See the module text."""
    wins, la, lb = view["wins"], view["lanes"][a], view["lanes"][b]
    acc, pairs, used, symbols = [0.0] * (2 * top + 1), [0] * (2 * top + 1), 0, 0
    for (_, _, n), x, y, fa, fb in zip(wins, la["pieces"], lb["pieces"], la["fits"], lb["fits"]):
        Da, Db = fa["ones_fraction"], fb["ones_fraction"]
        if not (0 < Da < 1 and 0 < Db < 1):
            continue
        used, symbols = used + 1, symbols + n
        mean, scale = (2 * Da - 1) * (2 * Db - 1), 1 / math.sqrt(16 * Da * (1 - Da) * Db * (1 - Db))
        for lag in range(-top, top + 1):                                    # lane a at i, lane b at i + lag
            m = n - abs(lag)
            differ = ((x ^ (y >> lag)).bit_count() - (x >> m).bit_count() if lag >= 0
                      else ((x >> -lag) ^ y).bit_count() - (y >> m).bit_count())
            acc[lag + top] += m * (1 - 2 * differ / m - mean) * scale
            pairs[lag + top] += m
    out = dict(lanes=[a, b], lags=top, windows=used, judged=False, flagged=False, max_coherence=None, frequency=None, threshold=None)
    if not used:
        return out
    size, w = bins_for(top), cross_window(top)
    x = [0.0] * size
    for lag in range(-top, top + 1):
        x[lag % size] = w[abs(lag)] * acc[lag + top] / pairs[lag + top]
    Sab, Saa, Sbb = dft(x), spectra[a], spectra[b]
    # independent segments: the windows, unless one of the lanes has no memory
    # left over most of the lag range, so that pieces as long as the lag window count
    quiet = []
    for l in (la, lb):
        limit = QUIET_Z ** 2 * (1 + 2 * sum(r * r for r in l["rho"][:top // 4]))            # Bartlett, in squared standard errors
        quiet.append(all(r * r * p <= limit for r, p in zip(l["rho"][top // 4:top], l["pairs"][top // 4:top])))
    segments = segment_count(symbols, used, top, any(quiet))
    floor_a, floor_b = LEAKAGE * max(Saa), LEAKAGE * max(Sbb)
    judged = [k for k in range(size // 2 + 1) if Saa[k] > floor_a and Sbb[k] > floor_b]
    out.update(segments=segments, segments_are="pieces of the lag window" if any(quiet) else "windows", bins=size // 2 + 1, judged_bins=len(judged))
    if segments < 2 or not judged:
        return out
    chance = 2 * NormalDist().cdf(-z_flag) / len(judged)                    # per frequency, for all of them together
    k = max(judged, key=lambda k: abs(Sab[k]) ** 2 / (Saa[k] * Sbb[k]))
    value = min(1.0, abs(Sab[k]) ** 2 / (Saa[k] * Sbb[k]))
    threshold = 1 - chance ** (1 / (segments - 1))
    out.update(judged=True, max_coherence=value, frequency=k / size, phase=cmath.phase(Sab[k]) / (2 * math.pi), threshold=threshold,
               flagged=value >= threshold)
    return out

def segment_count(symbols, windows, top, quiet):
    """Independent segments behind a coherence estimate with lags up to top."""
    return symbols / (2 * sum(cross_window(top)) - 1) if quiet else windows

def shared_wander(view, a, b, z_flag):
    """Rank correlation of the per-window F of two lanes over the windows in
    which both could be fitted, with a z that allows for the serial
    correlation of each series (Bartlett) and for the number of windows."""
    both = [(x["F"], y["F"]) for x, y in zip(view["lanes"][a]["fits"], view["lanes"][b]["fits"]) if x["identifiable"] and y["identifiable"]]
    n = len(both)
    out = dict(lanes=[a, b], windows=n, judged=False, flagged=False, correlation=None, z=None)
    if n < MIN_WANDER_WINDOWS:
        return out
    def ranks(values):
        order = sorted(range(n), key=values.__getitem__)
        r = [0.0] * n
        for position, i in enumerate(order):
            r[i] = position - (n - 1) / 2
        return r
    ra, rb = ranks([p[0] for p in both]), ranks([p[1] for p in both])
    power = sum(v * v for v in ra)
    r = sum(u * v for u, v in zip(ra, rb)) / power
    serial = lambda v, k: sum(v[i] * v[i + k] for i in range(n - k)) / power
    inflation = max(1.0, 1 + 2 * sum(serial(ra, k) * serial(rb, k) for k in range(1, n // 4 + 1)))
    dof = n / inflation - 2
    if dof < 1:
        return dict(out, correlation=r, inflation=inflation)
    # Student's t of a correlation, as a normal score (Wallace's approximation)
    scale = (8 * dof + 1) / (8 * dof + 3)
    z = scale * math.sqrt(-dof * math.log(max(1e-300, 1 - r * r)))
    return dict(out, judged=True, correlation=r, inflation=inflation, z=z, flagged=z >= z_flag,
                detectable=math.sqrt(1 - math.exp(-(z_flag / scale) ** 2 / dof)))

def analyze(cap, args):
    lags, zc = args.lags, args.confidence_z
    runs = cap["runs"]
    total = sum(map(len, runs))
    out = dict(file=cap["file"], k=cap["k"], period=cap["period"], clocks=cap["clocks"], kind=cap["kind"], clock_hz=cap["clock_hz"],
               symbols=total, runs=len(runs), longest_run=max(map(len, runs)), lanes=[], notes=[])
    cfg = cap["meta"].get("cfg_before")
    cutoffs = dict(rct=(int(cfg, 16) >> 16) & 0x3ff, apt=(int(cfg, 16) >> 26) & 0x7ff) if cfg else {}
    ints, rho = [], []
    for lane in range(LANES):
        text = [r.translate(LANE_TAB[lane]) for r in runs]              # b"0101..." per run
        ints.append([(len(t), int(t[::-1], 2)) for t in text])          # bit i = sample i
    predicted, word_predictor = predictors([(n, tuple(ints[l][i][1] for l in range(LANES)))
                                            for i, (n, _) in enumerate(ints[0])], zc)
    view = window_view(cap, ints, args)
    if view is None:
        out["notes"].append(f"no run of {MIN_WINDOW} symbols: no per-window fits, spectra or coherence")
    else:
        out["windows"] = dict(count=len(view["wins"]), symbols=view["symbols"], longest=max(n for _, _, n in view["wins"]), lags=view["top"])
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
        lv = view["lanes"][lane] if view else None
        w = wander = None
        if lv:
            w, wander = window_summary(view, lane, cap, zc)
            res.update(windows=w, pooled=lv["pooled"], wander=wander)
        if 0 < D < 1 and len(cs) >= 2:
            # standard errors: of C_j (Bartlett, large lag) and of the ones fraction
            spread = 1 + 2 * sum(r * r for r in rho[lane])
            ses = [math.sqrt(spread / n) for n in pairs]
            se_D = math.sqrt(D * (1 - D) * max(1.0, 1 + 2 * sum(rho[lane])) / total)
            res["standard_errors"] = dict(ones_fraction=se_D, autocorrelation=ses)
            pooled, checked, ref, base = lv and lv["pooled"], (cs, ses, rho[lane]), None, (1 - 2 * D) ** 2
            if pooled and pooled["identifiable"] and pooled["sigma2"] < SHORT_FIT_MIN:
                # the serial correlation outlasts the short lags: the capture's fit is the pooled long-lag fit
                f = dict(pooled, method="long-lag", at_grid_floor=False)
            else:
                m = min(args.fit_lags, len(cs))
                f = dict(fit(cs[:m], D, ses[:m], zc), lags=m, method="short-lag")
            if lv and view["top"] > len(cs) and (f["method"] == "long-lag" or abs(rho[lane][-1]) > 0.05):
                # The model is then checked at all lags of the windows, against the per-window
                # fits when enough windows were fitted, with standard errors from all those lags.
                long_rho = lv["rho"]
                spread = 1 + 2 * sum(r * r for r in long_rho)
                reference = (lv["ref"] if w["usable"] else [0.0] * len(long_rho) if not f["identifiable"] else
                             [(c - base) / (1 - base) for c in model_lags(f["F"], D, f["sigma2"], range(1, len(long_rho) + 1))])
                checked, ref = (lv["cs"], [math.sqrt(spread / p) for p in lv["pairs"]], long_rho), [base + (1 - base) * r for r in reference]
            res["fit"], used = f, choose(f, pooled, w)
            res["sigma2_used"] = used
            res["estimate"] = estimate(D, se_D, f, used, *checked, predicted[lane], zc, args.fit_z, ref)
        else:
            out["notes"].append(f"lane {lane}: no fit and no estimate (constant lane, or no run of three symbols)")
        if lv and 0 < lv["ones_fraction"] < 1:
            # the spectrum, against the model as fitted: per window when enough windows were, else the capture's fit
            f, fitted, reference, labels = res.get("fit"), False, lv["ref"], []
            if w["usable"]:
                fitted, labels = True, harmonic_labels(w["F_median"], lv["ones_fraction"], w["sigma2_median"], w["F_spread"] or 0.0)
            elif f and f["identifiable"]:
                span = range(1, min(view["top"], int(1.1 / f["sigma2"]) + 8) + 1)
                base = (1 - 2 * D) ** 2
                reference = [(c - base) / (1 - base) for c in model_lags(f["F"], D, f["sigma2"], span)] + [0.0] * (view["top"] - len(span))
                fitted, labels = True, harmonic_labels(f["F"], D, f["sigma2"], 0.0)
            res["spectrum"] = lane_spectrum(lv["rho"], reference, fitted, view["symbols"], labels)
        out["lanes"].append(res)
    if view:
        top = min(args.coherence_lags, min(view["tops"]))
        spectra = [power_spectrum(l["rho"][:top], cross_window) for l in view["lanes"]]
        out["cross_spectrum"] = [cross_spectrum(view, a, b, top, spectra, args.z) for a, b in PAIRS]
        out["shared_wander"] = [shared_wander(view, a, b, args.z) for a, b in PAIRS]

    # ---- cross-lane dependence ----
    cross = []
    for a, b in PAIRS:
        ra, rb = rho[a], rho[b]
        common = min(len(ra), len(rb))
        truncated = common > 0 and abs(ra[common - 1]) > 0.05 and abs(rb[common - 1]) > 0.05
        # With windows there is a longer autocorrelation, used when both lanes still remember in the
        # last quarter of the lags (the last lag alone can be at a zero of an oscillation).
        late = lambda r: max(abs(v) for v in r[-(len(r) // 4 or 1):]) > 0.05
        longer = common > 0 and view is not None and view["top"] > common and late(ra[:common]) and late(rb[:common])
        if longer:
            ra, rb = view["lanes"][a]["rho"], view["lanes"][b]["rho"]
            truncated = late(ra) and late(rb)
        inflation = max(0.05, 1 + 2 * sum(x * y for x, y in zip(ra, rb)))
        if longer:
            # Two such lanes of different F average each other out, and the sum says so (it can
            # come close to 0); with F wandering it is not to be trusted that far: not below 1.
            # If they remember past an eighth of a window, they count as remembering to its end.
            inflation = max(inflation, 1.0) * (max(n for _, _, n in view["wins"]) / view["top"] if truncated else 1.0)
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
        # A constant lane has no variance: no correlation with it can be
        # measured, so the pair is reported as such and has no sensitivity.
        measurable = all(0.0 < out["lanes"][l]["ones_fraction"] < 1.0 for l in (a, b))
        cross.append(dict(lanes=[a, b], inflation=inflation, truncated=truncated, extended=longer and truncated, lags=rows,
                          max_abs_z=abs(worst["z"]), at_lag=worst["lag"], flagged=measurable and abs(worst["z"]) >= args.z,
                          measurable=measurable,
                          detectable_phi=min(1.0, args.z * math.sqrt(inflation / total)) if measurable else 1.0))
    late = ["%d,%d" % tuple(c["lanes"]) for c in cross if c["truncated"] and not c["extended"]]
    if late:
        out["notes"].append(f"lane pairs {' '.join(late)}: serial correlation reaches past the last lag computed, "
                            "so their z scores are overstated; use more --lags or longer runs")
    late = ["%d,%d" % tuple(c["lanes"]) for c in cross if c["extended"]]
    if late:
        out["notes"].append(f"lane pairs {' '.join(late)}: serial correlation reaches past an eighth of a window; their z scores "
                            "count it as lasting to the end of a window, which can only lower them")
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

def estimate(D, se_D, f, used, cs, ses, rho, pred, zc, fit_z, ref=None):
    """Per-bit figures of one lane and whether its model fits; see the module
    text. used is the sigma^2 that feeds the model figure (choose). ref, when
    given, is the fitted model's C_j at every lag of cs: the long-lag case."""
    base = (1 - 2 * D) ** 2
    span = [max(1e-9, D - zc * se_D), min(1 - 1e-9, D + zc * se_D)]
    bias_p, bias_up = max(D, 1 - D), min(1.0, max(D, 1 - D) + zc * se_D)
    model_p = model_guess(D, used["value"])
    model_up = max(model_guess(d, used["low"]) for d in span)
    e = dict(scope="one bit of one lane", confidence_z=zc,
             bias=dict(p=bias_p, bits=bits(bias_p), bits_low=bits(bias_up)),
             model=dict(p=model_p, bits=bits(model_p), bits_low=bits(model_up), sigma2_is_lower_bound=used["is_lower_bound"],
                        sigma2=used["value"], sigma2_low=used["low"], sigma2_from=used["value_from"], sigma2_low_from=used["low_from"]),
             fair_duty_bound=dict(p_e=pe_bound(f["sigma2"])[0], bits=pe_bound(f["sigma2"])[1],
                                  note="assumes D = 1/2; for reference, never used by itself"))
    tops = dict(bias=(bias_p, bias_up), model=(model_p, model_up))
    reasons = []
    # the fit: every computed lag against the fitted model
    worst, at = 0.0, 0
    for j, (c, se) in enumerate(zip(cs, ses), 1):
        z = abs(c - (ref[j - 1] if ref else model_c(f["F"], D, f["sigma2"], j) if f["identifiable"] else base)) / se
        if z > worst:
            worst, at = z, j
    if worst > fit_z:
        reasons.append(f"C_{at} is {worst:.1f} standard errors from the model")
    # with all lags of the windows the last eighth is looked at: the last lag alone can be at a zero of an oscillation
    if max(abs(r) for r in rho[-(len(rho) // 8 or 1):]) > 0.05 if ref else abs(rho[-1]) > 0.05:
        reasons.append(f"serial correlation has not died out by lag {len(rho)}: " + ("longer windows are needed" if ref else "use more --lags"))
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
    """sigma^2 against the spacing in clocks (period * k), per lane, over the
    captures whose sigma^2 is an estimate and not a lower bound. The value is
    the one that feeds the model figure. With one period in all captures the
    slope is also given per raw sample, as it was against k alone."""
    table, periods = [], {r["period"] for r in results}
    for lane in range(LANES):
        pts = [(r, r["lanes"][lane]["sigma2_used"]) for r in results
               if not r["lanes"][lane].get("sigma2_used", dict(is_lower_bound=True))["is_lower_bound"]]
        row = dict(lane=lane, points=[], predicted=[], sigma2_per_clock=None, sigma2_per_raw_sample=None, exponent=None, linear=None)
        if pts:
            slope = sum(u["value"] / r["clocks"] for r, u in pts) / len(pts)    # every capture with the same relative weight
            row["sigma2_per_clock"] = slope
            row["sigma2_per_raw_sample"] = slope * min(periods) if len(periods) == 1 else None
            row["points"] = [dict(k=r["k"], period=r["period"], clocks=r["clocks"], sigma2=u["value"], sigma2_low=u["low"], source=u["value_from"],
                                  predicted=r["clocks"] * slope, ratio=u["value"] / (r["clocks"] * slope)) for r, u in pts]
            for r in results:                               # the line, at every spacing captured, with that capture's D
                p = model_guess(r["lanes"][lane]["ones_fraction"], r["clocks"] * slope)
                row["predicted"].append(dict(k=r["k"], period=r["period"], clocks=r["clocks"], sigma2=r["clocks"] * slope, p=p, bits=bits(p)))
        if len({r["clocks"] for r, _ in pts}) >= 2:
            lx, ly = [math.log(r["clocks"]) for r, _ in pts], [math.log(u["value"]) for _, u in pts]
            mx, my = sum(lx) / len(lx), sum(ly) / len(ly)
            row["exponent"] = sum((x - mx) * (y - my) for x, y in zip(lx, ly)) / sum((x - mx) ** 2 for x in lx)
            row["linear"] = all(abs(p["ratio"] - 1) <= tolerance for p in row["points"])
        table.append(row)
    return table

def agreement(results, z_flag):
    """Captures with the same spacing in clocks, pair by pair: per lane the
    differences of the ones fraction and of C_1..C_8 over their combined
    standard errors."""
    out = []
    for x, y in itertools.combinations(results, 2):
        if x["clocks"] != y["clocks"]:
            continue
        lanes = []
        for a, b in zip(x["lanes"], y["lanes"]):
            ea, eb = a.get("standard_errors"), b.get("standard_errors")
            if not ea or not eb:
                lanes.append(dict(lane=a["lane"], compared=False, flagged=False))
                continue
            z_ones = (a["ones_fraction"] - b["ones_fraction"]) / math.hypot(ea["ones_fraction"], eb["ones_fraction"])
            zs = [(p - q) / math.hypot(s, t) for p, q, s, t in
                  list(zip(a["autocorrelation"], b["autocorrelation"], ea["autocorrelation"], eb["autocorrelation"]))[:8]]
            worst = max([abs(z_ones)] + [abs(z) for z in zs])
            lanes.append(dict(lane=a["lane"], compared=True, z_ones_fraction=z_ones, z_autocorrelation=zs, max_abs_z=worst, flagged=worst >= z_flag))
        out.append(dict(clocks=x["clocks"], captures=[x["label"], y["label"]], files=[x["file"], y["file"]], z_flag=z_flag, lanes=lanes,
                        flagged=any(l["flagged"] for l in lanes)))
    return out

# ---- report ----
def num(x):
    """A sigma^2, a spread or a spectral height: five decimals, or three significant digits when small or large."""
    return "-" if x is None else f"{x:.5f}" if 1e-3 <= abs(x) < 1e3 else f"{x:.2e}"

def report(results, table, pairs, args, verdict):
    L = ["GetNoise capture analysis", ""]
    for r in results:
        L += [f"== {r['file']} [{r['label']}]: clocks per symbol {r['clocks']} (period {r['period']} x decimation k = {r['k']}), "
              f"{r['symbols']} symbols in {r['runs']} run(s), longest {r['longest_run']}",
              "", "Per lane (each lane is one sampled ring; figures are per kept sample of this capture):",
              f"  lane  ones(D)   longest-rep  apt-max   F         sigma^2    (range at z = {args.confidence_z})   fit"]
        cut = r["lanes"][0].get("cutoffs")
        if cut:
            L.insert(-1, f"  (cutoffs in the capture's mentropycfg: repetition count {cut['rct']}, adaptive proportion {cut['apt']} of 1024)")
        for l in r["lanes"]:
            f = l.get("fit")
            head = f"  {l['lane']}     {l['ones_fraction']:.5f}   {l['repetitions']['longest']:<11}  {str(l['apt_max_count'] or '-'):<8}  "
            if not f:
                L.append(head + "(no fit)")
            elif f["identifiable"]:
                L.append(head + f"{f['F']:.6f}  {num(f['sigma2'])}    ({num(f['sigma2_low'])} .. {num(f['sigma2_high'])})   {f['method']}, {f['lags']} lags"
                         + (f" up to {f['lag_max']}" if "lag_max" in f else ""))
            else:
                L.append(head + f"  -       >={f['sigma2']:.4f}")
        if any(l.get("fit") and not l["fit"]["identifiable"] for l in r["lanes"]):
            L.append("  (>=: no autocorrelation above four standard errors; sigma^2 is a lower bound, F is not visible)")
        L.append("  fit: of the autocorrelation pooled over the capture; short-lag: lags 1..8; long-lag: where sigma^2 is below "
                 f"{SHORT_FIT_MIN} and the short lags cannot show it")
        if r.get("windows"):
            W = r["windows"]
            L += ["", f"Per window ({W['count']} windows of up to {W['longest']} symbols: every run, cut at --window = {args.window}; lags up to {W['lags']}):",
                  f"  lane  fitted   F median   F spread  (jitter alone)  sigma^2 median  scatter  (range at z = {args.confidence_z})   pooled fit  pooled/windows  wander"]
            for l in r["lanes"]:
                w, wa, p = l["windows"], l["wander"], l["pooled"]
                head = f"  {l['lane']}     {str(w['identifiable']) + '/' + str(w['count']):<7}  "
                if not w["identifiable"]:
                    L.append(head + "(no window with autocorrelation above four standard errors)")
                    continue
                L.append(head + f"{w['F_median']:.6f}   {num(w['F_spread']):<8}  {num(w['F_expected_spread']):<14}  {num(w['sigma2_median']):<14}  {w['sigma2_scatter']:<7.2f}  "
                         f"({num(w['sigma2_low'])} .. {num(w['sigma2_high'])})   {num(p['sigma2']) if p['identifiable'] else '-':<10}  "
                         f"{'-' if wa['sigma2_ratio'] is None else format(wa['sigma2_ratio'], '.2f'):<14}  "
                         + ("YES" if wa["indicated"] else "no" if wa["judged"] else "not judged") + ("" if w["usable"] else "  (too few fitted: not used)"))
            L += ["  fitted: windows with some rho_1..rho_8 four standard errors from 0. F spread: 1.48 x the median distance from the median.",
                  "  jitter alone: the spread of a window's mean frequency that sigma^2 and the fits' own errors give.",
                  "  sigma^2 median: of the fits with all lags. scatter: the standard deviation of ln sigma^2 between windows.",
                  "  range: of that median, from the scatter between windows or the fits' own errors, whichever is larger.",
                  "  pooled fit: the same fit on the autocorrelation pooled over the windows. Wander of F between windows makes it too large.",
                  f"  wander: F spread at {WANDER_SPREAD:g} x jitter alone or more; or, at the lower end, pooled/windows or all lags over the smallest lag range",
                  f"  (below) at {WANDER_RATIO:g} or more. Judged with {MIN_WANDER_WINDOWS} fitted windows.",
                  "  Not seen: F itself beyond F mod 1, folded to 0..1/2."]
            if any(l["windows"].get("by_lag") for l in r["lanes"]):
                L.append("  sigma^2 by the largest lag of the windows' fits (median of the windows; in brackets: scatter between windows too large to use):")
                for l in r["lanes"]:
                    w = l["windows"]
                    if w.get("by_lag"):
                        best = w["sigma2_best"]
                        L.append(f"    lane {l['lane']}: " + "  ".join(f"{row['lag_max']}: " + (num(row["sigma2"]) if row["determined"] else f"[{num(row['sigma2'])}]")
                                                                     for row in w["by_lag"])
                                 + (f";  smallest {num(best['value'])}, all lags x{best['growth']:.2f} of it" if best else ";  none determined"))
                L += ["  It rises with the lag where F wanders inside a window, where the jitter grows faster than white noise does, and where bursts",
                      "  were joined; it falls where the sampling instant has noise of its own. The smallest determined value feeds the model figure."]
            drift = [(l["lane"], l["wander"]["drift"]) for l in r["lanes"] if l["wander"]["drift"]]
            if drift:
                L.append("  F against the time a window started (least squares): " + "; ".join(
                    f"lane {lane} {d['total']:+.2e} over " + (f"{d['seconds']:.3g} s" if "seconds" in d else f"{d['cycles']} clocks") + f" (z {d['z']:+.1f})"
                    for lane, d in drift))
            used = [(l["lane"], l["sigma2_used"]) for l in r["lanes"] if l.get("sigma2_used")]
            if used:
                L.append("  sigma^2 behind the model figure: the windows' where they could be fitted, and for its lower end the smallest lower end of the fits:")
                L += [f"    lane {lane}: " + (f">={num(u['value'])} (a lower bound, {u['value_from']})" if u["is_lower_bound"] else
                                               f"{num(u['value'])} ({u['value_from']}), lower end {num(u['low'])} ({u['low_from']})") for lane, u in used]
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
        dead = [c["lanes"] for c in x["pairs"] if not c.get("measurable", True)]
        if dead:
            L.append("  UNMEASURABLE pairs (a lane is constant, so no correlation with it can be seen): "
                     + ", ".join(f"{a},{b}" for a, b in dead))
        spectra = [(l["lane"], l["spectrum"]) for l in r["lanes"] if l.get("spectrum")]
        if spectra:
            s = spectra[0][1]
            L += ["", f"Spectrum per lane (of the autocorrelation to lag {s['lags']}, pooled over windows; frequency in cycles per sample, 0..1/2;",
                  f"  lines closer than {s['resolution']:.2g} are one; heights are over the floor, the median of the spectrum; 1 = a lane without memory):"]
            for lane, s in spectra:
                lines = "  ".join(f"{q['frequency']:.5f} (x{q['height']:.3g}, " + ("SPUR" if q["spur"] else "model" if q["harmonic"] is None else
                                  "F" if q["harmonic"] == 1 else f"{q['harmonic']}F") + ")" for q in s["lines"])
                L.append(f"  lane {lane}: floor {num(s['floor'])}" + (" (the leakage of the highest line)" if s["floor_is_leakage"] else "")
                         + f"; lines: {lines or 'none above ' + format(s['line_threshold'], '.2f') + ' x the floor'}")
                L.append("          " + (f"SPURS, {s['spur_count']}: " + "  ".join(f"{q['frequency']:.5f} (x{q['height']:.3g}, x{q['over_model']:.3g} over the model)"
                                                                                  for q in s["spurs"])
                                         if s["spurs"] else f"no spur: nothing {s['spur_threshold']:.2f} x above "
                                         + ("the fitted model's spectrum" if s["fitted"] else "a lane without memory (nothing was fitted)")))
            L += ["  F, 3F, ..: at n F mod 1 of the fitted model. model: explained by the model's spectrum, at no line of a small n.",
                  f"  SPUR: above the spectrum of the fitted model by the chance level of one frequency times {MODEL_TOLERANCE:g}, the allowance for the fit.",
                  f"  Not seen: anything below {LEAKAGE:g} of the highest line of the lane, and a spur on top of a model line unless it is that much higher."]
        if r.get("cross_spectrum"):
            L += ["", f"Coherence between lanes (cross-correlation at lags -{r['cross_spectrum'][0]['lags']}..{r['cross_spectrum'][0]['lags']} pooled over windows, "
                  f"against the two spectra; flagged at the chance level of |z| = {args.z} for all frequencies together):",
                  "  lanes  segments                         frequencies  max coherence  at f      threshold  flagged"]
            for c in r["cross_spectrum"]:
                head = f"  {c['lanes'][0]},{c['lanes'][1]}    "
                if not c["judged"]:
                    L.append(head + "not judged: " + ("no window with both lanes changing" if not c["windows"] else
                                                      "one segment only" if c["segments"] < 2 else "no frequency at which both lanes are above their leakage"))
                    continue
                L.append(head + f"{format(c['segments'], '.0f') + ' ' + c['segments_are']:<31}  {str(c['judged_bins']) + '/' + str(c['bins']):<11}  "
                         f"{c['max_coherence']:<13.4f}  {c['frequency']:<8.5f}  {c['threshold']:<9.4f}  {'YES' if c['flagged'] else 'no'}")
            L += ["  A phase relation between two lanes that repeats in every window gives a coherence near 1 at their frequency; independent lanes",
                  "  give about 1/segments, whatever their frequencies. segments: the windows, or pieces as long as the lag window when a lane has",
                  "  no memory over most of the lags. A coherence below the threshold would not have been flagged, and frequencies at which a",
                  "  lane is below its leakage are not judged. Not seen: dependence whose phase changes from window to window."]
        if r.get("shared_wander"):
            L += ["", "Shared wander (rank correlation of the per-window F of two lanes; z allows for serial correlation and the number of windows):",
                  "  lanes  windows  correlation  z       flagged"]
            for c in r["shared_wander"]:
                head = f"  {c['lanes'][0]},{c['lanes'][1]}    {c['windows']:<7}  "
                L.append(head + (f"{c['correlation']:+.3f}       {c['z']:<6.2f}  {'YES' if c['flagged'] else 'no'}"
                                 f"   (below about {c['detectable']:.2f} it would not have been)" if c["judged"] else
                                 f"not judged: {MIN_WANDER_WINDOWS} windows fitted in both lanes are needed, without too much serial correlation"))
            L.append("  Not seen: a wander smaller than the scatter of the fitted F, which is at least what the jitter gives.")
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
    L += ["== sigma^2 against the spacing in clocks (model: sigma^2 is proportional to clocks = period x k)"]
    for row in table:
        if not row["points"]:
            L.append(f"  lane {row['lane']}: no capture with a visible autocorrelation")
            continue
        pts = "  ".join(f"{p['clocks']}: {num(p['sigma2'])} ({p['ratio']:.2f}x)" for p in row["points"])
        tail = "" if row["linear"] is None else (f"; log-log slope {row['exponent']:.2f}; "
               + ("linear" if row["linear"] else "NOT linear") + f" within {args.linear_tolerance:.0%}")
        per_sample = "" if row["sigma2_per_raw_sample"] is None else f" (per raw sample of {results[0]['period']} clocks {row['sigma2_per_raw_sample']:.6f})"
        L.append(f"  lane {row['lane']}: sigma^2 per clock {row['sigma2_per_clock']:.4e}{per_sample}{tail}")
        L.append(f"          measured, by clocks: {pts}")
        L.append("          on the line, sigma^2 and the model figure with that capture's D (no range, not a verdict): "
                 + "  ".join(f"{p['clocks']}: {num(p['sigma2'])}, {p['bits']:.4f}" for p in row["predicted"]))
    L += ["  measured: the sigma^2 behind each capture's model figure. The line is the mean of sigma^2 / clocks; a capture with only a",
          "  lower bound is left out. A slope above 1 means jitter that grows faster than white noise does (flicker, wander)."]
    if pairs:
        L += ["", f"== captures with the same spacing (differences over their combined standard errors; flagged at |z| >= {args.agree_z})"]
        for p in pairs:
            L.append(f"  {p['clocks']} clocks: {p['captures'][0]} against {p['captures'][1]}" + (": DIFFERENT" if p["flagged"] else ": no difference flagged"))
            L += [f"    lane {l['lane']}: ones fraction {l['z_ones_fraction']:+.1f}; C_1.. " + " ".join(f"{z:+.1f}" for z in l["z_autocorrelation"])
                  + ("   FLAGGED" if l["flagged"] else "") if l["compared"] else f"    lane {l['lane']}: not compared (no estimate)" for l in p["lanes"]]
        L += ["  The standard errors are those of each capture alone (Bartlett). Captures taken at different times differ in F when",
              "  the rings have drifted, and that shows here where the autocorrelation is visible."]
    L += ["", "Notes",
          "  - Per-lane figures describe one bit of one lane. They are not to be added up into a figure for",
          "    a symbol or a word: that would need independent lanes.",
          "  - The model figure holds only as far as the model does. A refused fit means it does not; a fit",
          "    that is not refused has passed the checks named above, no more.",
          "  - The cross-lane statistics see dependence between bits at a fixed lag. Rings of different",
          "    frequency that share jitter can pass them. The coherence sees a phase relation that repeats in",
          "    every window, and the shared wander a common change of frequency from window to window.",
          "  - A window's sigma^2 from all lags is one draw: its scatter is about 0.3 in ln sigma^2 when the",
          "    window holds only a few coherence times of the ring, so the typical value needs many windows.",
          "    Wander inside a window, jitter that grows faster than white noise, and bursts that were joined",
          "    into one run all raise it; the smallest lag range is less exposed, not immune.",
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
        name = r["label"]
        if args.min_lane_bits is not None:
            for l in r["lanes"]:
                e, what = l.get("estimate"), f"{name} lane {l['lane']}: lower end of the per-bit estimate >= {args.min_lane_bits}"
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
            checks.append(dict(what=f"{name}: 16-bit word figure >= {args.min_word_bits} "
                               + (f"(is {w['bits_low']:.4f}, limited by the {w['limited_by']})" if w else "(no words)"),
                               ok=bool(w) and w["bits_low"] >= args.min_word_bits))
        if args.require_independent:
            x = r["cross_lane"]
            checks.append(dict(what=f"{name}: no lane dependence flagged", ok=not x["flagged_pairs"] and not x["total_flagged"]))
            dead = [c["lanes"] for c in x["pairs"] if not c.get("measurable", True)]
            checks.append(dict(what=f"{name}: every lane pair measurable"
                               + (" (not: " + ", ".join(f"{a},{b}" for a, b in dead) + "; a lane is constant)" if dead else ""),
                               ok=not dead))
            checks.append(dict(what=f"{name}: a correlation of {args.max_undetected_phi} would have been flagged "
                               f"(this capture: {x['detectable_phi']:.4f})", ok=x["detectable_phi"] <= args.max_undetected_phi))
            # The two below can only fail on what was seen. What they could not have seen is in the report.
            flagged = [c["lanes"] for c in r.get("cross_spectrum", []) if c["flagged"]]
            judged = [c["threshold"] for c in r.get("cross_spectrum", []) if c["judged"]]
            checks.append(dict(what=f"{name}: no coherence between lanes flagged ("
                               + (", ".join(f"{a},{b}" for a, b in flagged) + " flagged" if flagged else
                                  f"{len(judged)} of {len(PAIRS)} pairs judged" + (f", a coherence of {max(judged):.3f} would have been flagged" if judged else "")) + ")",
                               ok=not flagged))
            flagged = [c["lanes"] for c in r.get("shared_wander", []) if c["flagged"]]
            judged = [c["detectable"] for c in r.get("shared_wander", []) if c["judged"]]
            checks.append(dict(what=f"{name}: no shared wander of the lanes' frequencies flagged ("
                               + (", ".join(f"{a},{b}" for a, b in flagged) + " flagged" if flagged else
                                  f"{len(judged)} of {len(PAIRS)} pairs judged" + (f", a rank correlation of {max(judged):.2f} would have been flagged" if judged else "")) + ")",
                               ok=not flagged))
    return dict(met=all(c["ok"] for c in checks), checks=checks)

def finite(value):
    """The results with null for anything that is not a number, so that the file is JSON."""
    if isinstance(value, dict):
        return {k: finite(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [finite(v) for v in value]
    return None if isinstance(value, float) and not math.isfinite(value) else value

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("captures", nargs="+", help="capture files (*.bin); the sidecar *.json is read if present")
    p.add_argument("--k", type=int, help="decimation of a capture without a sidecar")
    p.add_argument("--period", type=int, help=f"clock cycles per raw symbol of a capture whose sidecar does not give it ({DEFAULT_PERIOD})")
    p.add_argument("--out", help="directory for getnoise-analysis.txt and .json (default: next to the first capture)")
    p.add_argument("--lags", type=int, default=32, help="autocorrelation lags, also used for the standard errors (32)")
    p.add_argument("--fit-lags", type=int, default=8, help="lags used by the short-lag fit (8)")
    p.add_argument("--cross-lags", type=int, default=4, help="cross-lane lags -n..n (4)")
    p.add_argument("--window", type=int, default=32768, help="symbols per window: longer runs are cut into equal pieces of at most this (32768)")
    p.add_argument("--coherence-lags", type=int, default=512, help="lags -n..n of the cross-spectrum (512, at most an eighth of the shortest window)")
    p.add_argument("--z", type=float, default=4.5, help="|z| at which a lane pair, a coherence or a shared wander is flagged (4.5)")
    p.add_argument("--agree-z", type=float, default=4.5, help="|z| at which two captures of the same spacing are flagged as different (4.5)")
    p.add_argument("--confidence-z", type=float, default=2.576, help="z of the interval whose lower end a verdict uses (2.576)")
    p.add_argument("--fit-z", type=float, default=5.0, help="standard errors a C_j may lie from the fitted model (5)")
    p.add_argument("--linear-tolerance", type=float, default=0.25, help="allowed deviation of sigma^2 from the line through the origin (0.25)")
    p.add_argument("--min-lane-bits", type=float, help="verdict: required lower end of every lane's per-bit estimate")
    p.add_argument("--min-word-bits", type=float, help="verdict: required 16-bit word figure (distribution and predictor cap)")
    p.add_argument("--require-independent", action="store_true",
                   help="verdict: no lane dependence, coherence or shared wander may be flagged")
    p.add_argument("--max-undetected-phi", type=float, default=0.05,
                   help="with --require-independent: the capture must be able to flag this correlation (0.05)")
    args = p.parse_args(argv)
    if args.window < MIN_WINDOW or args.coherence_lags < 1 or (args.period is not None and args.period < 1):
        p.error(f"--window is at least {MIN_WINDOW}, --coherence-lags and --period at least 1")
    try:
        caps = [load(path, args.k, args.period) for path in args.captures]
    except (OSError, ValueError) as e:
        print(f"getnoise_analyze: {e}", file=sys.stderr)
        return 2
    results = sorted((analyze(c, args) for c in caps), key=lambda r: (r["clocks"], r["period"]))
    names = [f"P={r['period']} k={r['k']}" for r in results]
    for r, name in zip(results, names):
        r["label"] = name if names.count(name) == 1 else f"{name}, {Path(r['file']).name}"
    table, pairs = decimation(results, args.linear_tolerance), agreement(results, args.agree_z)
    verdict = judge(results, args)
    text = report(results, table, pairs, args, verdict)
    out = Path(args.out) if args.out else Path(args.captures[0]).parent
    out.mkdir(parents=True, exist_ok=True)
    (out / "getnoise-analysis.txt").write_text(text)
    (out / "getnoise-analysis.json").write_text(json.dumps(finite(dict(
        format="karu64-getnoise-analysis-3", captures=results, decimation=table, agreement=pairs, verdict=verdict)), indent=1) + "\n")
    print(text, end="")
    return 1 if verdict and not verdict["met"] else 0

if __name__ == "__main__":
    sys.exit(main())
