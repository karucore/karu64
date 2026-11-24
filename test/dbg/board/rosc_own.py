#!/usr/bin/env python3
# A ring oscillator's OWN phase noise from the meter's simultaneous edge counts
# of six rings (flow/fpga/karu_rosc_meter.v), with a lower confidence bound on
# the part an SP 800-90B claim may credit. doc/zkr-followup-plan.md (Z7) says
# why; doc/sp800-90b-assessment.md section 1 has the bound this feeds.
#
# What is measured. Ring r's phase x_r(k), in ring periods, is its count at
# record k (one record every N0 clocks, all rings read on one clock edge)
# times the count unit u, the ring periods in one count: 2 behind the divider
# that sits between a ring and its counter, 1 in the meter's direct mode, in
# which the counter is clocked by the ring itself (count_unit of the sidecar).
# Rates, variances, the bound and the verdict are in ring periods throughout.
# Against the clock it holds, besides the ring's own noise, everything the
# rings share: the time error of the sampling clock, which every ring sees in
# exact proportion to its rate f_r, and supply or temperature modulation, seen
# in proportion to f_r * s_r with sensitivities s_r that differ a little from
# ring to ring. Only a ring's own white frequency noise is fresh at every
# sample and independent of the other rings, so only that is credited.
#
# The statistic (Allan-type; every variance below is of this kind). For a
# series z and a span of m records, tau = m * N0 clocks,
#     d(k; m) = z(k + 2m) - 2 z(k + m) + z(k)       (overlapping: every k)
#     A_z(m)  = 1/2 * mean over k of d(k; m)^2
#             = tau^2 * (Allan variance of the fractional rate at tau)
# in periods^2, and for two series A_zw(m) = 1/2 mean d_z d_w. d is blind to a
# constant rate; a slow linear drift of the rate is taken out before, as one
# quadratic fitted to each ring's phase over each run. How A relates to the
# variance of the phase increment over the span given the past:
#   white FM, rate a periods^2 per clock: d is the difference of two
#     independent increments, so A = a * tau, and a * tau IS the variance of
#     the increment given everything before it. This is the credited part.
#   a constant resolution term, every reading with an independent error of
#     variance q: A = 3 q at every span. Counting in steps of u periods gives
#     q = u^2 / 12, so A = u^2 / 4: 1 behind the divider, 1/4 in direct mode.
#     It is measurement error, no phase variance at all.
#   flicker FM (S_y = h / f): A = 2 ln 2 * h * tau^2. That is the mean square
#     error of predicting the next span's increment by the last one's. The
#     best predictor does better, by how much depends on the spectrum outside
#     the measured spans, so A is an upper limit of the conditional variance
#     and nothing of it is credited.
# So own(tau) = c + a tau + b tau^2 is fitted and only a is used.
#
# Pairs. A pair is x_i - c x_j. With the fixed coefficient c = f_i / f_j the
# clock's time error cancels exactly, whatever its spectrum, and so does a
# supply modulation that the two rings see with equal sensitivity; of a supply
# term seen with sensitivities s_i and s_j the part (s_i - s_j) is left. The
# fitted coefficient is the ratio of the two rings' loadings on the shared
# part, which the other rings determine (c = sum_k A_ik / sum_k A_jk); it
# cancels one shared factor of any loadings and is undetermined when the
# shared part is small. The bound uses both: fixed coefficients in the hat of
# the three 3-stage rings, because that estimate is linear in the measured
# second moments (no small-sample bias, plain errors), exact against the clock
# and second order in the small sensitivity differences of like rings; fitted
# loadings in the factor models, because rings of other types differ in
# sensitivity at first order. It is the smallest of them (see "The bound").
#
# A ring's own variance at a span, from the matrix A_ij(m) of the usable
# rings; g_ij = A_ij / (f_i f_j) is the same in clock periods^2:
#   hat   three-cornered hat of rings 0, 4, 5 with fixed coefficients:
#         own_0 = f_0^2 (g_00 - g_04 - g_05 + g_45), likewise for 4 and 5.
#   ls    least squares of V_ij = psi_i + psi_j over all pairs, V_ij = g_ii +
#         g_jj - 2 g_ij the fixed-coefficient pair; it is the mean of all hats
#         that contain the ring.
#   f1    one shared factor of free loadings: g_ij = v_i v_j for i != j by
#         least squares, own_i = f_i^2 (g_ii - v_i^2). With three rings it is
#         the hat with fitted coefficients.
#   f2    two shared factors, the clock, whose loading is known (the same for
#         every ring in clock units), and one of free loadings: g_ij = rho +
#         v_i v_j. Needs four rings. Two factors of free loadings are not
#         fitted: they need five rings and are badly conditioned when the two
#         loadings are nearly proportional, as clock and supply are.
#   upper the regression of the ring on all others: own_i <= 1 / (A^-1)_ii,
#         whatever the shared part is; and a <= upper(tau) / tau at every span.
# f1 and f2 may move a ring's value away from ls by at most --sens-max times
# the measured first-order difference of the loadings; that is all a
# sensitivity difference of at most --sens-max can do, and it keeps them
# defined when there is no shared part to fit. Negative values are reported as
# they come; nothing is clamped at zero.
#
# Errors. The runs are cut into --blocks blocks of equal length; only
# differences that lie inside one block are used, at spans of 1, 2, 4, ...
# records up to a quarter of a block. Blocks then share no increment, and a
# bootstrap over blocks (--boot replicates) gives every standard error. The
# fit of c, a, b is weighted least squares over the spans, the weights fixed
# from the bootstrap variances, repeated on every replicate. A ring's fit
# starts at the first span over which its phase has moved by MOVE = 0.35
# count^2, 0.35 u^2 period^2, against the clock (assumption 6): behind the
# divider that is four times the movement that direct counting needs. The
# tables under "spans" use all overlapping differences of whole runs, up to
# a tenth of the longest run.
#
# The bound. For each method M that the usable rings allow,
#     a_low(M) = the smaller of a(M) - t * se(M) and the bootstrap's
#     (1 - conf) quantile; t the Student quantile for --conf (0.99,
#     one-sided) at blocks - 1 degrees of freedom,
# and a_low = min over M of a_low(M), M in hat (rings 0, 4, 5 usable), ls, f1,
# f2 (four rings). It holds if one of the methods is right: a method biased
# upward in a capture is overruled by one that is not, and a noisy or
# downward-biased method costs margin, not validity. The credited variance at
# a spacing is a_low * spacing. The variance needed is the one at which
# -log2 p_max(D, variance) of entropy_claim.py reaches --target (0.75 bit),
# D the lane bit's bias at its upper end (as entropy_claim.duty); "ratio" is
# the credited variance over it.
#
# A variance that grows linearly with the span is necessary for fresh noise.
# It does not by itself show that the increments cannot be predicted: that
# rests on the model below, and the checks under "assumptions" in the output
# test the parts of it that a capture can test. Each has ok = true, false or
# null (not testable here), with its statistic:
#   stationarity    a of ring 0, by the linear method (hat, else ls), block by
#                   block: its scatter between 8 consecutive segments, between
#                   runs, and its trend, each against random reorderings of
#                   the blocks (5,000); a failure is p < 0.001.
#   gaussian        per spacing: the second differences over the spacing,
#                   every 2m-th so that they share no increment, of ring 0
#                   less its regression on the other rings and of the pairs
#                   0-4 and 0-5; excess kurtosis against what counting errors
#                   alone give, tolerance 4 sqrt(24 / n) + 0.03, and the
#                   fractions beyond 2 and 3 standard deviations against a
#                   Gaussian's plus 4 binomial standard errors (upward only,
#                   readings dithered). Needs 200 such differences.
#   shared_factors  what one factor, and what clock and one factor, leave of
#                   the pairs' covariances, summed over spans and pairs in
#                   standard errors squared, against the bootstrap; a failure
#                   is p < 0.0001 for clock and one factor.
#   independence    the same left-over covariance pair by pair, as a
#                   correlation of the own parts and summed over the spans
#                   (z); a failure is |z| > 4.
#   memory          the constant term c of own(span) against the u^2 / 4 of
#                   counting in steps of u; noise whose memory is shorter than
#                   the fitted spans grows linearly there from a negative
#                   intercept and is not all fresh at a spacing near its
#                   memory; a failure is c below u^2 / 4 by 3.5 standard
#                   errors. (A wrong count unit does not show here: c scales
#                   with the unit that is applied, like everything else.)
#
# The verdict per spacing. With margin = --margin (2.0):
#   pass             a_low * spacing >= margin * the variance needed, and
#                    nothing below stands against it;
#   fail             not even the largest upper end of the methods, a + t se,
#                    gives the variance needed;
#   not established  otherwise (the tool says whether more records would
#                    decide, and about how many), and whatever the numbers when
#     - a check of "assumptions" fails or could not be made at this spacing;
#     - fewer than four rings are usable (three give as many equations as
#       unknowns, nothing tests the model), or ring 0 has no lane bit;
#     - ring 0 is locked to another ring (a pair is locked when its counts
#       keep a small rational ratio to within four counts each over a run, or
#       when its variance does not grow with the span while the other pairs'
#       does; the partner is left out of every estimate, of other locked
#       pairs both);
#     - hat and f2 (without a hat: f1 and f2) differ by more than 3.5
#       standard errors of the difference and twice the larger standard error;
#     - the fit c + a tau + b tau^2 does not describe a method's values, a
#       method lies above the model-free upper bound, an own variance of
#       ring 0 is negative by three standard errors, or a ring's loading
#       differs from its rate ratio by more than --sens-max;
#     - the spacing is outside the fitted spans;
#     - a spectral line in the phase of a pair the bound rests on (0-4, 0-5,
#       4-5 with the hat, else every pair) could add more than a tenth of
#       the credited variance (4 amplitude^2);
#     - the count and the lane bit of ring 0 do not fit each other: a
#       reading's error depends on the bit, through the slope of the count's
#       second difference on the bit's and that of its square on the bit; the
#       two together are 0.45 to 0.5 for bits of these counts at any latency
#       of the count (which the tool reports modulo one period), 0 for
#       unrelated bits, and scale with the unit applied over the true one:
#       below 0.2 or above 0.75 (by 4 standard errors) is a misfit, so counts
#       of single periods taken for double ones are caught here, counts of
#       three or four periods taken for double ones are not;
#     - a records file's sidecar has no count_unit, or --count-unit differs
#       from it;
#     - --pair or --bits was given and a ring is flagged, or nothing could
#       be compared (below);
#     - there are fewer than 32 blocks or 5 fitted spans;
#     - the capture has fewer than MIN_RECORDS = 300,000 usable records: those
#       that enter the fit, the blocks times the records of a block, after
#       every run set aside (flagged counts, losses, jumps, the least run
#       length); the end of a run too short for another block is not
#       counted. The records of the runs kept are reported beside them.
#       Estimates, bounds and checks are still reported, for bring-up.
#       --min-records lowers the number for tests only, and the output says
#       so;
#     - the instrument's health is not recorded (no bad_counts in the
#       sidecar of a records file), the sidecar's ring_mask is not the rings
#       whose counts move, or the rings of normal operation are not known;
#   cross-check only the capture was taken in direct mode (count unit 1: the
#                    counter is clocked by the ring, outside its flip-flop's
#                    guaranteed range), whatever its rings; or not with the
#                    rings that run in normal operation (strap_mask of the
#                    sidecar, CTRL[37:32] of the meter; --operating-mask
#                    overrides). It is analysed
#                    in full and "as_measured" has what the verdict would be,
#                    but a bound is claimed only from a capture of the
#                    operating rings.
#
# Four dissimilar rings (mask 0x0f: rings 0 to 3, one of each kind). There is
# no hat. ls, f1 and f2 apply. The 4 x 4 matrix has 10 second moments; the
# four own variances and one factor's four loadings leave 2 of them free, the
# clock (one more number, its loading being known) and one factor leave 1,
# and two factors of free loadings would need 11: f2 is identifiable only
# because the clock's loading is known. The bound is min(ls, f1, f2), which
# is never above f1. It is conservative when the shared part is the clock
# and at most one further factor; one degree of freedom tests that (the two
# checks above) and f1 must agree with f2. A capture of all six rings on the
# same board tests it with eight, and with the hat: take both.
#
# The count unit against the hardware. Nothing in one capture shows a divider
# that runs steadily at a wrong ratio: the meter's own check does not trip,
# and every figure here scales with the unit that is applied. Two checks
# from outside the capture, each blocking the verdict when a ring is flagged:
#   --pair OTHER  a capture of the same rings and spacing in the other
#       counting mode. Per ring: the ratio of the two mean rates in ring
#       periods per clock, which must be 1 (the hardware's counts are then in
#       the ratio of the units), its standard error, and the drift within each
#       capture. A ratio may be off 1 by 4 standard errors plus the drift
#       within the captures carried over the time between them (the sidecars'
#       time stamps; 100 capture lengths without them) plus 1e-4; and off the
#       median of all rings' ratios, which takes the common drift out, by 4
#       standard errors plus --sens-max of the median's distance from 1 plus
#       the drift within the captures.
#   --bits ANALYSIS.json  what getnoise_analyze.py wrote for bursts of
#       sampled bits at one clock per sample, which pass no counter and no
#       divider. A lane's fitted F is the fraction of its ring's periods per
#       clock, folded: F or 1 - F. Per mapped ring (--bits-map, default the
#       reference-bit bursts of rosc_count.py: lanes 0 to 3 are rings 0, 1, 4,
#       5): the distance of frac(rate) to the nearer of F and 1 - F, against
#       3 x F's stated uncertainty (the largest of the windows' scatter and
#       expected spread and the fits' standard errors) + rate x (the drift
#       within this capture + 3e-4 for the minutes between the captures).
#       Every mapped ring that runs in the capture must have a usable fit and
#       agree: a ring without one fails the check ("no usable frequency fit");
#       a mapped lane whose ring does not run is listed and does not count. A
#       wrong ratio puts frac(rate) anywhere, so n rings within tolerances t
#       agree by accident with a chance of about the product of 4 t.
# What the two can see. --bits compares the FOLDED frequency only: a count
# that is wrong by a whole number of periods per clock leaves the fraction as
# it is and passes. --pair compares one counter with the other: it sees such
# an error unless both modes share it, and cannot tell which mode is wrong.
# Both are needed; neither alone qualifies the instrument.
#
# Minimum data: 32 blocks of 4 * 16 records, 2,048 records, for the fit to
# exist at all (5 spans, 1 to 16 records) when ring 0 moves by 0.35 u^2
# period^2 per record against the clock; where it takes k records to move so
# far, k times as many. The spacing must be one of the fitted spans or
# between them, and the shape of the increments at a spacing of m records
# needs 400 m records. That is the floor for an estimate. For a verdict of
# "pass" the capture needs 300,000 usable records, in the blocks of the fit
# (MIN_RECORDS): in this
# tool's validation with counts of two periods the checks of the assumptions
# missed small violations at 30,000 records that they flagged at 300,000. The
# bound's width falls as 1 / sqrt of the records; test_rosc_own.py --need
# gives the records for a bound at 80 % of a, for either count unit.
#
# What the bound rests on, and what in the data would contradict it:
#  1. A ring's own noise is independent of every other usable ring's own
#     noise. Noise that two rings share and no third is credited to both by
#     some methods. Contradicted by: the independence check, hat and f2
#     disagreeing, a pair that does not diffuse (lock), a negative own
#     variance, hats of different partners disagreeing ("trios").
#  2. What the rings share reaches them through at most two factors: one in
#     exact proportion to f_r (the clock) and one of free loadings. A third
#     (a second supply with other sensitivities) is taken for own noise of
#     the rings it reaches least evenly. Contradicted by: the shared_factors
#     and independence checks, hat and f2 disagreeing.
#  3. The rings' sensitivities to the free factor differ by at most
#     --sens-max (0.25). Contradicted by: the loading ratios ("sensitivity").
#  4. A ring's own noise is white FM plus flicker FM plus a constant reading
#     error, so own(tau) = c + a tau + b tau^2 over the fitted spans. A
#     component between white and flicker (tau^1.5) would be credited in
#     part; one steeper than flicker lowers a. Contradicted by: the fit's
#     p-value ("p_fit"), the memory check, a changing with the spans fitted
#     ("a_by_range").
#  5. White FM seen at the fitted spans is white at the spacing: the spacing
#     must lie inside the fitted spans, or there is no verdict. Noise with a
#     memory far below N0 is white at every span the capture has, and is
#     fresh at such a spacing but for a part of the order memory / spacing.
#  6. A count's reading error (resolution of u periods, latency of the clock
#     crossing) is uniform over one count and independent from record to
#     record and of the other rings' errors. Two readings' errors are
#     correlated as exp(-2 pi^2 v / u^2), v the variance of the ring's
#     movement against the clock between them, so a ring's fit starts where
#     v >= 0.35 u^2 and the tool notes it when that is not the first span.
#     Contradicted by: a bad fit at the short spans.
#  7. The capture is stationary: one a for all of it. Contradicted by: the
#     stationarity check. Between captures: compare them.
#  8. The phase model of entropy_claim.p_max: Gaussian increments, bit = 1
#     while the phase fraction is in [0, D). Contradicted by: the gaussian
#     check, as far as second differences of counts show a shape (a ring's
#     own increments are never seen without a partner's and the counting
#     errors, which at 4,096 clocks and a = 5e-5 make up a half of the
#     variance in direct mode and five sixths behind the divider).
#  9. The meter read every count: a run in which it flagged one as unreadable
#     or as inconsistent with the one before (bad_counts of the sidecar not
#     zero; bad_rings names the rings) is left out of everything and listed
#     as rejected.
# 10. One count is u ring periods, exactly and all the time. Contradicted
#     by: --pair and --bits; within a capture only a unit taken too large
#     shows (the count against the lane bit).
# A violation of 1 or 2 too small for its check to flag can still raise a by
# about two of its standard errors (test_rosc_own.py --coverage, VIOLATION).
#
# Input: NAME.bin, the records of rosc_count.py (16 bytes each, two
# little-endian 64-bit words as the meter gives them), with its sidecar
# NAME.json (NAME.bin.json is accepted when there is no NAME.json; the
# sidecar's sha256 must be the file's); or an .npz with arrays totals
# [records x 6, unwrapped], bits [records] or [records x 4], n0 and
# optionally runs [[start, records]], clock_hz, stages, op_mask, count_unit
# (1 when absent, which is direct mode; --count-unit overrides). From the
# sidecar: period, every, runs, bad_counts, ring_mask, strap_mask (or
# op_mask), count_unit, clock_hz, stages, time. A records file's count unit
# is the sidecar's only: --count-unit then just sets what the numbers are in.
# Statistics are never joined across runs. The 20-bit totals are unwrapped in
# counts, before the unit is applied, with each ring's increment per record,
# taken from the data (the median of the increments modulo 2^20). That needs
# (a) the increment itself below 2^20 counts, f_r * N0 / u < 1,048,576, which
# holds for f_r < 16 u periods per clock at the largest N0 of 65,536 and is
# not visible in the data ("rates" in the sidecar, periods per clock, override
# it), and (b) every increment within 2^19 counts of the median, which is
# checked more strictly: a run is split wherever
# an increment is further than a quarter of the median from it, as after a
# lost record. A run also ends at a record without the valid bit, at the first
# record with the loss flag (the flag is sticky, so later losses would not be
# seen) and where the sequence number does not continue.
#
# Usage:
#   rosc_own.py NAME.bin [--text] [--out FILE] [--spacing N ...]
#               [--pair OTHER.bin] [--bits ANALYSIS.json [--bits-map L:R,...]]
#               [--operating-mask MASK] [--count-unit U] [--margin 2.0]
#               [--target 0.75] [--blocks 64] [--boot 400] [--conf 0.99]
#               [--sens-max 0.25] [--min-records N (tests only)]
# JSON goes to stdout, a readable summary with --text. Exit status: 0 when the
# capture was analysed and every spacing has a verdict, whatever the verdict
# (also "not established" and "cross-check only", and whatever --pair and
# --bits found); 2 when it could not be analysed at all: a file or sidecar
# that is missing, unreadable or not what it says, or no usable run (then the
# JSON has "error" and the top-level "rejected" with the reasons).
# Self-test: test_rosc_own.py (and its --coverage and --need studies).
# SPDX-License-Identifier: BSD-2-Clause
import argparse, datetime, functools, hashlib, json, math, os, statistics, sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from entropy_claim import p_max                                  # noqa: E402

NR = 6                                                           # rings in a record
MOD = 1 << 20                                                    # totals are modulo this
MIN_RUN = 16                                                     # records: a shorter run is set aside
# The least usable records of a capture whose verdict may be "pass": records in the blocks that enter the
# fit (blocks x records per block), the quantity the validation varied. From this tool's validation with
# counts of two periods (test_rosc_own.py --coverage, _build/rosc-own/coverage-unit2.log and
# violations-unit2-300k.log, 2026-11-21): at 30,000 records the checks of the assumptions miss small
# violations that still raise a (a third shared factor passed in 31 % of the trials with a 40 % too
# high, a doubling of a halfway in 16 %); at 300,000 they flagged those in 200 of 200.
MIN_RECORDS = 300000
MIN_BLOCKS = 32
MIN_SPANS = 5
P_MISFIT = 1e-4                                                  # the fit's p-value below which it is a misfit
Z_EXCESS = 4.0                                                   # a pair's unexplained covariance, in its errors
LINE_BIN0 = 6                                                    # lines are searched from this bin of a segment up
P_STATIONARY = 1e-3                                             # permutation p-value below which a is not stationary
Z_GAUSS, G_FLOOR = 4.0, 0.03                                     # kurtosis and tails: standard errors, and a floor
Z_MEMORY = 3.5                                                   # the constant term below the reading error's, in its errors
P2, P3 = 0.0455003, 0.0026998                                    # a Gaussian's fractions beyond 2 and 3 sd
MOVE = 0.35                                                      # counts^2 of movement that makes two readings independent
PAIR_Z, PAIR_FLOOR, PAIR_GAP = 4.0, 1e-4, 100.0                  # --pair: standard errors, least allowance, default gap
BITS_Z, BITS_DRIFT = 3.0, 3e-4                                   # --bits: errors of F, relative drift allowed between captures
BITS_MAP = {0: 0, 1: 1, 2: 4, 3: 5}                              # burst lane: ring, for the reference-bit bursts of rosc_count.py

def reading(unit):
    """The constant that counting in steps of `unit` periods adds to A: three times a uniform error's variance."""
    return 0.25 * unit * unit

SPACINGS = (4096, 16384)

# ---- small numerics (no scipy) ----
def norm_ppf(p):
    return statistics.NormalDist().inv_cdf(p)

def t_ppf(p, nu):
    """Student quantile, Hill's expansion in 1/nu (error below 1e-3 for nu >= 8)."""
    z = norm_ppf(p)
    g1 = (z ** 3 + z) / 4
    g2 = (5 * z ** 5 + 16 * z ** 3 + 3 * z) / 96
    g3 = (3 * z ** 7 + 19 * z ** 5 + 17 * z ** 3 - 15 * z) / 384
    g4 = (79 * z ** 9 + 776 * z ** 7 + 1482 * z ** 5 - 1920 * z ** 3 - 945 * z) / 92160
    return z + g1 / nu + g2 / nu ** 2 + g3 / nu ** 3 + g4 / nu ** 4

def gamma_mean_quantile(k, tail):
    """Upper quantile of the mean of k unit exponentials (Wilson-Hilferty)."""
    z = norm_ppf(1 - tail)
    return (1 - 1 / (9 * k) + z * math.sqrt(1 / (9 * k))) ** 3

@functools.lru_cache(maxsize=4096)
def _pmax(D, s2, grid):
    return p_max(D, s2, grid) if grid else p_max(D, s2)

def h_min(D, s2, grid=0):
    """Min-entropy bound per bit for a credited variance s2 and a duty D."""
    if not s2 > 0:
        return 0.0
    return -math.log2(_pmax(D, s2, grid))

@functools.lru_cache(maxsize=256)
def s2_needed(D, target):
    """The smallest credited variance whose bound reaches the target, or None."""
    if h_min(D, 4.0, 2048) < target:
        return None
    lo, hi = 0.0, 4.0
    for _ in range(36):
        mid = (lo + hi) / 2
        if h_min(D, mid, 2048) >= target: hi = mid
        else: lo = mid
    return hi

# ---- input ----
def split_words(w):
    """Fields of the two record words: valid, loss, seq, totals [n, 6], lane bits."""
    w0, w1 = w[:, 0], w[:, 1]
    m = np.uint64(MOD - 1)
    tot = np.stack([w0 & m, (w0 >> np.uint64(20)) & m, (w0 >> np.uint64(40)) & m,
                    w1 & m, (w1 >> np.uint64(20)) & m, (w1 >> np.uint64(40)) & m], 1).astype(np.int64)
    return (((w0 >> np.uint64(63)) & np.uint64(1)).astype(np.int64),
            ((w0 >> np.uint64(62)) & np.uint64(1)).astype(np.int64),
            ((w0 >> np.uint64(60)) & np.uint64(3)).astype(np.int64), tot,
            ((w1 >> np.uint64(60)) & np.uint64(15)).astype(np.uint8))

def unwrap_run(tot, nominal=None):
    """Unwrap one contiguous run of totals modulo 2^20. Returns (unwrapped int64, median increment,
    largest deviation of an increment from it)."""
    inc = np.diff(tot, axis=0) % MOD
    out = np.zeros_like(tot)
    med = np.zeros(tot.shape[1], dtype=np.int64)
    dev = np.zeros(tot.shape[1], dtype=np.int64)
    for r in range(tot.shape[1]):
        c = (inc[:, r] - inc[0, r] + MOD // 2) % MOD - MOD // 2  # circular, about the first one
        mu = int(inc[0, r] + np.median(c)) % MOD
        if nominal is not None and nominal[r] is not None:
            mu += MOD * int(round((nominal[r] - mu) / MOD))
        true = mu + (inc[:, r] - mu + MOD // 2) % MOD - MOD // 2
        med[r], dev[r] = mu, int(np.max(np.abs(true - mu))) if len(true) else 0
        out[1:, r] = np.cumsum(true)
    return out, med, dev

def sidecar_of(path):
    """<name>.json next to <name>.bin, as rosc_count.py writes it; <name>.bin.json is accepted too."""
    for p in (os.path.splitext(path)[0] + '.json', path + '.json'):
        if p != path and os.path.isfile(p):
            return p
    raise SystemExit(f"{path}: no sidecar {os.path.splitext(path)[0] + '.json'}")

def load_bin(path, sidecar=None):
    """Records of rosc_count.py with their sidecar (format karu64-rosc-count-1)."""
    side = json.load(open(sidecar or sidecar_of(path)))
    data = open(path, 'rb').read()
    if len(data) % 16:
        raise SystemExit(f'{path}: not a whole number of 16-byte records')
    if side.get('sha256') and hashlib.sha256(data).hexdigest() != side['sha256']:
        raise SystemExit(f'{path}: the file is not the one its sidecar describes (sha256)')
    valid, loss, seq, tot, lanes = split_words(np.frombuffer(data, dtype='<u8').reshape(-1, 2))
    n0 = int(side['period']) * int(side.get('every', 1))
    if int(side.get('clocks_per_record', n0)) != n0:
        raise SystemExit(f'{path}: the sidecar\'s clocks_per_record is not period x every')
    unit = side.get('count_unit')                                # ring periods per count: 2 behind the divider, 1 direct
    if unit is not None and (int(unit) != unit or int(unit) < 1):
        raise SystemExit(f'{path}: count_unit {unit!r} of the sidecar is not a whole number of periods')
    nominal = [None if f is None else f * n0 / (unit or 1) for f in side['rates']] if side.get('rates') else None
    try:
        stamp = datetime.datetime.fromisoformat(side['time']).timestamp()
    except (KeyError, TypeError, ValueError):
        stamp = None
    runs, rejected = [], []
    listed = side.get('runs') or [dict(start=0, records=len(tot))]
    # instrument health: the clock cycles of each run in which the meter flagged a ring's count, as not
    # readable or as an increment that does not fit the one before, and the rings it flagged
    bad_counts, bad_rings = side.get('bad_counts'), side.get('bad_rings')
    health = bad_counts is not None and len(bad_counts) == len(listed)
    for k, run in enumerate(listed):
        a, b = int(run['start']), int(run['start']) + int(run['records'])
        if a < 0 or b > len(tot) or b - a < 3:
            rejected.append(dict(start=a, records=b - a, why='outside the file or shorter than 3 records'))
            continue
        if health and int(bad_counts[k]):
            rings = sorted(int(r) for r in bad_rings[k]) if isinstance(bad_rings, list) and len(bad_rings) == len(listed) else None
            rejected.append(dict(start=a, records=b - a, rings=rings,
                                 why=f'{int(bad_counts[k])} clock cycle(s) in which the meter flagged a count as unreadable or '
                                     'inconsistent' + (', ring(s) ' + ', '.join(str(r) for r in rings) if rings else
                                                       ', rings not recorded' if rings is None else '')
                                     + ' (bad_counts): the totals of this run are not used'))
            continue
        bad = np.flatnonzero(valid[a:b] == 0)
        if len(bad):                                             # nothing after an invalid record is trusted
            rejected.append(dict(start=a + int(bad[0]), records=b - a - int(bad[0]), why='record without the valid bit'))
            b = a + int(bad[0])
        lost = np.flatnonzero(loss[a:b])
        if len(lost):                                            # the flag is sticky: later losses are not seen
            rejected.append(dict(start=a + int(lost[0]), records=b - a - int(lost[0]),
                                 why='loss flag set: this and later records of the run are not contiguous for certain'))
            b = a + int(lost[0])
        cuts = [a] + [a + 1 + int(i) for i in np.flatnonzero((np.diff(seq[a:b]) % 4) != 1)] + [b]
        for i, (s, e) in enumerate(zip(cuts[:-1], cuts[1:])):
            if i:
                rejected.append(dict(start=s, records=0, why='sequence number does not continue: run split here'))
            if e - s >= 3:
                runs.append((s, e))
            elif e > s:
                rejected.append(dict(start=s, records=e - s, why='shorter than 3 records'))
    op = side.get('op_mask', side.get('strap_mask'))             # the rings that run outside test mode (CTRL[37:32])
    return dict(tot=tot, wrapped=True, nominal=nominal, lanes=lanes, n0=n0, runs=runs, rejected=rejected,
                clock_hz=float(side.get('clock_hz', 75e6)), stages=side.get('stages'),
                ring_mask=side.get('ring_mask'), op_mask=None if op is None else int(op), health=bool(health),
                count_unit=None if unit is None else int(unit), time=stamp, file=path)

def load_npz(path):
    z = np.load(path)
    tot = np.asarray(z['totals']).astype(np.int64)
    bits = np.asarray(z['bits']) if 'bits' in z.files else None
    if bits is not None and bits.ndim == 2:                      # [records, 4] of 0/1
        bits = (bits[:, :4].astype(np.uint8) << np.arange(4, dtype=np.uint8)[None, :]).sum(1).astype(np.uint8)
    runs = [(int(a), int(a) + int(n)) for a, n in z['runs']] if 'runs' in z.files else [(0, len(tot))]
    return dict(tot=tot, wrapped=False, nominal=None, lanes=None if bits is None else bits.astype(np.uint8),
                n0=int(z['n0']), runs=runs, rejected=[],
                clock_hz=float(z['clock_hz']) if 'clock_hz' in z.files else 75e6,
                stages=[int(s) for s in z['stages']] if 'stages' in z.files else None, ring_mask=None,
                op_mask=int(z['op_mask']) if 'op_mask' in z.files else None, health=None,
                count_unit=int(z['count_unit']) if 'count_unit' in z.files else 1, time=None, file=path)

def load_capture(path):
    return load_npz(path) if path.endswith('.npz') else load_bin(path)

# ---- the statistic ----
def spans_upto(m_max):
    out, m = [], 1
    while m <= m_max:
        out.append(m)
        m *= 2
    return out

def second_moments(zs, m):
    """A_ij(m) pooled over the series in zs (each [n, rings]); None when no run is long enough."""
    acc, cnt = 0.0, 0
    for z in zs:
        if len(z) < 10 * m:
            continue
        d = z[2 * m:] - 2 * z[m:-m] + z[:-2 * m]
        acc = acc + d.T @ d
        cnt += len(d)
    return (0.5 * acc / cnt, cnt) if cnt else (None, 0)

def block_moments(zb, ms):
    """Per block and span: A_ij from the differences that lie inside the block. zb [B, L, rings]."""
    B, L, n = zb.shape
    out = np.empty((B, len(ms), n, n))
    for i, m in enumerate(ms):
        d = zb[:, 2 * m:] - 2 * zb[:, m:-m] + zb[:, :-2 * m]
        out[:, i] = 0.5 * np.matmul(d.transpose(0, 2, 1), d) / (L - 2 * m)
    return out

# ---- own variance from the matrix of second moments ----
def _diag(g):
    return np.einsum('...ii->...i', g)

def ls_fixed(g):
    """Least squares of V_ij = psi_i + psi_j, V the fixed-coefficient pair variance. Also the first-order
    loadings b (g_ij ~ b_i + b_j)."""
    n = g.shape[-1]
    d = _diag(g)
    V = d[..., :, None] + d[..., None, :] - 2 * g
    R = V.sum(-1)
    W = R.sum(-1, keepdims=True) / 2
    psi = (R - W / (n - 1)) / (n - 2)
    return psi, (d - psi) / 2

def one_factor(g, iters=40):
    """Least squares on the off-diagonal elements of g_ij = v_i v_j. Returns psi_i = g_ii - v_i^2 and v."""
    n = g.shape[-1]
    idx = np.arange(n)
    off = g.copy()
    off[..., idx, idx] = 0.0
    mean_off = off.sum((-1, -2)) / (n * (n - 1))
    v = np.sqrt(np.maximum(mean_off, 0.0))[..., None] * np.ones(n)
    for _ in range(iters):
        for i in range(n):
            num = (off[..., i, :] * v).sum(-1)
            den = (v * v).sum(-1) - v[..., i] ** 2
            ok = den > 0
            v[..., i] = np.where(ok, num / np.where(ok, den, 1.0), v[..., i])
    return _diag(g) - v * v, v

def clock_and_factor(g, b, sens, iters=30):
    """Least squares on the off-diagonal elements of g_ij = rho + v_i v_j: the clock, which every ring sees
    alike in clock units, and one factor of free loadings. Fitted in the equivalent form
        g_ij = alpha + a_i + a_j + kappa a_i a_j,  sum of a = 0,  0 <= kappa <= sens / max |a_i - a_j|
    (kappa = 0 is the fixed-coefficient solution b of ls_fixed, kappa alpha = 1 the single factor; the upper
    limit is what a sensitivity difference of at most sens allows), by Levenberg-Marquardt from both of
    these. Returns psi_i = g_ii - alpha - 2 a_i - kappa a_i^2 and what the fit leaves of each g_ij, i < j."""
    n = g.shape[-1]
    bs = g.shape[:-2]
    iu, ju = np.triu_indices(n, 1)
    scale = np.maximum(np.maximum(np.abs(g[..., iu, ju]).mean(-1), 1e-9 * np.abs(_diag(g)).mean(-1)), 1e-300)
    y = g[..., iu, ju] / scale[..., None]
    Z = np.linalg.svd(np.eye(n) - 1.0 / n)[0][:, :n - 1]          # basis of the vectors that sum to zero
    bn = b / scale[..., None]
    alpha0 = 2 * bn.mean(-1)
    a0 = bn - bn.mean(-1, keepdims=True)

    def model(alpha, at, kap):
        a = at @ Z.T
        return alpha[..., None] + a[..., iu] + a[..., ju] + kap[..., None] * a[..., iu] * a[..., ju], a

    def kmax(a):
        return sens / np.maximum((a.max(-1) - a.min(-1)), 1e-300)

    best = None
    for start in (0, 1):
        alpha, at = alpha0.copy(), a0 @ Z
        kap = np.zeros(bs) if start == 0 else np.minimum(1.0 / np.maximum(alpha0, 1e-300), kmax(a0))
        fit, a = model(alpha, at, kap)
        cost = ((y - fit) ** 2).sum(-1)
        lam = np.full(bs, 1e-3)
        for _ in range(iters):
            r = y - fit
            J = np.empty(bs + (len(iu), n + 1))
            J[..., 0] = 1.0
            da = np.zeros(bs + (len(iu), n))                       # d fit / d a_k
            rows = np.arange(len(iu))
            da[..., rows, iu] += 1 + kap[..., None] * a[..., ju]
            da[..., rows, ju] += 1 + kap[..., None] * a[..., iu]
            J[..., 1:n] = da @ Z
            J[..., n] = a[..., iu] * a[..., ju]
            H = np.matmul(J.swapaxes(-1, -2), J)
            gr = np.matmul(J.swapaxes(-1, -2), r[..., None])[..., 0]
            dg = _diag(H)
            Hd = H + (lam[..., None] * dg + 1e-12 * dg.max(-1, keepdims=True) + 1e-300)[..., None] * np.eye(n + 1)
            try:
                step = np.linalg.solve(Hd, gr[..., None])[..., 0]
            except np.linalg.LinAlgError:
                break
            alpha2, at2 = alpha + step[..., 0], at + step[..., 1:n]
            fit2, a2 = model(alpha2, at2, np.zeros(bs))
            kap2 = np.clip(kap + step[..., n], 0.0, kmax(a2))
            fit2, a2 = model(alpha2, at2, kap2)
            cost2 = ((y - fit2) ** 2).sum(-1)
            ok = cost2 < cost
            alpha = np.where(ok, alpha2, alpha)
            at = np.where(ok[..., None], at2, at)
            kap = np.where(ok, kap2, kap)
            cost = np.where(ok, cost2, cost)
            lam = np.where(ok, lam / 3, lam * 10)
            fit, a = model(alpha, at, kap)
        if best is None:
            best = [alpha, a, kap, cost]
        else:
            ok = cost < best[3]
            best = [np.where(ok, alpha, best[0]), np.where(ok[..., None], a, best[1]), np.where(ok, kap, best[2]),
                    np.where(ok, cost, best[3])]
    alpha, a, kap, _ = best
    psi = _diag(g) / scale[..., None] - alpha[..., None] - 2 * a - kap[..., None] * a * a
    resid = y - (alpha[..., None] + a[..., iu] + a[..., ju] + kap[..., None] * a[..., iu] * a[..., ju])
    return psi * scale[..., None], resid * scale[..., None]

def limited(psi_free, psi_ls, b, sens):
    """psi_free, moved away from psi_ls by at most sens times the largest first-order loading difference."""
    cap = sens * np.max(np.abs(b[..., :, None] - b[..., None, :]), axis=-1)
    q = psi_ls - psi_free
    q = np.where(np.isfinite(q), q, cap)
    return psi_ls - np.clip(q, -cap, cap), np.abs(q) > cap

def own_all(S, f, rings, sens):
    """Every method on S[..., n, n] (periods^2) of the rings listed (their numbers), f their rates.
    Returns {method: own[..., n] in periods^2, nan where the method does not apply} and the extras."""
    n = len(rings)
    ff = f[:, None] * f[None, :]
    g = S / ff
    f2 = f * f
    out, extra = {}, {}
    psi_ls, b = ls_fixed(g)
    out['ls'] = psi_ls * f2
    if all(r in rings for r in (0, 4, 5)):
        i0, i4, i5 = (rings.index(r) for r in (0, 4, 5))
        hat = np.full(psi_ls.shape, np.nan)
        for a, bb, c in ((i0, i4, i5), (i4, i0, i5), (i5, i0, i4)):
            hat[..., a] = g[..., a, a] - g[..., a, bb] - g[..., a, c] + g[..., bb, c]
        out['hat'] = hat * f2
    psi1, v1 = one_factor(g)
    psi1, lim1 = limited(psi1, psi_ls, b, sens)
    out['f1'] = psi1 * f2
    extra['load'] = v1                                           # in clock units: 1 + sensitivity, times a scale
    iu, ju = np.triu_indices(n, 1)
    extra['resid1'] = g[..., iu, ju] - v1[..., iu] * v1[..., ju]  # what one factor leaves of g_ij, clock periods^2
    if n >= 4:
        psi2, resid = clock_and_factor(g, b, sens)
        psi2, lim2 = limited(psi2, psi_ls, b, sens)
        out['f2'] = psi2 * f2
        extra['resid2'] = resid                                  # likewise for clock and one factor
    try:
        out['upper'] = 1.0 / _diag(np.linalg.inv(S))
    except np.linalg.LinAlgError:
        out['upper'] = 1.0 / _diag(np.linalg.pinv(S))
    return out, extra

def trio_hats(S, f, rings, ring=0):
    """Fixed-coefficient hats of one ring with every pair of partners: {(j, k): own[...]}."""
    g = S / (f[:, None] * f[None, :])
    i = rings.index(ring)
    out = {}
    for a in range(len(rings)):
        for c in range(a + 1, len(rings)):
            if i in (a, c):
                continue
            out[(rings[a], rings[c])] = (g[..., i, i] - g[..., i, a] - g[..., i, c] + g[..., a, c]) * f[i] ** 2
    return out

# ---- the fit own(tau) = c + a tau + b tau^2 ----
def tail_p(T, ref):
    """P(reference >= T), the reference taken as a gamma law of its sample's mean and variance."""
    m, v = float(np.mean(ref)), float(np.var(ref))
    if not (m > 0 and v > 0):
        return 1.0
    k = m * m / v
    z = ((max(float(T), 0.0) / m) ** (1 / 3) - (1 - 1 / (9 * k))) * 3 * math.sqrt(k)
    return 1 - statistics.NormalDist().cdf(z)

def fit_cab(tau, y, Y, tq, bcorr, alpha=0.0):
    """Weighted least squares on the point values y [spans] with the bootstrap replicates Y [R, spans].
    Returns a dict with c, a, b, their standard errors, the bounds of a and the fit's p-value."""
    var = Y.var(0)
    ok = np.isfinite(y) & np.isfinite(var) & (var > 0)
    if ok.sum() < 4:
        return None
    t, s = tau[ok] / tau[ok].max(), tau[ok].max()
    X = np.stack([np.ones(ok.sum()), t, t * t], 1)
    w = 1.0 / var[ok]
    K = np.linalg.solve(X.T @ (w[:, None] * X), X.T * w[None, :])     # [3, spans]
    th = K @ y[ok]
    TH = Y[:, ok] @ K.T
    se = TH.std(0) * bcorr
    res = y[ok] - X @ th
    chi = float((w * res * res).sum())
    dev = (Y[:, ok] - y[ok]) - (TH - th) @ X.T                       # residuals of the replicates' deviations
    p = tail_p(chi, (w * dev * dev).sum(1)) if ok.sum() > 3 else 1.0  # against what chi is like when the model holds
    sc = np.array([1.0, 1 / s, 1 / s ** 2])
    th, se = th * sc, se * sc
    lo_t, hi_t = th[1] - tq * se[1], th[1] + tq * se[1]
    lo_p, hi_p = (np.quantile(TH[:, 1], [alpha, 1 - alpha]) / s) if alpha else (lo_t, hi_t)
    return dict(c=float(th[0]), a=float(th[1]), b=float(th[2]), se_c=float(se[0]), se_a=float(se[1]),
                se_b=float(se[2]), a_low=float(min(lo_t, lo_p)), a_high=float(max(hi_t, hi_p)),
                a_low_t=float(lo_t), a_low_percentile=float(lo_p),
                spans=int(ok.sum()), chi2=chi, p_fit=p, _A=(TH[:, 1] / s), _K=K[1] / s, _ok=ok)

# ---- diagnostics ----
def find_lines(series, nseg, tail=1e-3, floor=4.0):
    """Lines in the spectrum of a phase series' first difference. series: list of 1-D arrays (runs).
    Returns [(cycles per record, phase amplitude in the series' unit, ratio to the background)]."""
    segs = []
    for z in series:
        d = np.diff(z)
        k = len(d) // nseg
        if k:
            segs.append(d[:k * nseg].reshape(k, nseg))
    if not segs:
        return [], 0
    segs = np.concatenate(segs)
    K = len(segs)
    win = np.hanning(nseg)
    P = (np.abs(np.fft.rfft(segs * win, axis=1)) ** 2).mean(0) / (win ** 2).sum()
    nb = len(P)
    # background: the median of chunks of bins, 8 bins wide at the low end and wider in proportion to the
    # frequency further up, joined by straight lines in log-log (exact for a power law, which flicker is)
    edges = [2]
    while edges[-1] < nb:
        edges.append(min(nb, edges[-1] + max(8, min(64, edges[-1] // 4))))
    if edges[-1] - edges[-2] < 8 and len(edges) > 2:
        edges.pop(-2)
    ctr = np.array([(a + b - 1) / 2 for a, b in zip(edges[:-1], edges[1:])])
    med = np.array([np.median(P[a:b]) for a, b in zip(edges[:-1], edges[1:])]) / (1 - 1 / (3 * K))
    kk = np.arange(nb, dtype=float)
    kk[0] = 1.0
    if len(ctr) > 1 and np.all(med > 0):
        lc, lm = np.log(ctr), np.log(med)
        lb = np.interp(np.log(kk), lc, lm)
        lo_, hi_ = kk < ctr[0], kk > ctr[-1]                      # beyond the outer chunks: their slope continued
        lb[lo_] = lm[0] + (lm[1] - lm[0]) / (lc[1] - lc[0]) * (np.log(kk[lo_]) - lc[0])
        lb[hi_] = lm[-1] + (lm[-1] - lm[-2]) / (lc[-1] - lc[-2]) * (np.log(kk[hi_]) - lc[-1])
        bg = np.exp(lb)
    else:
        bg = np.full(nb, max(float(np.median(P[1:])), 1e-300))
    thr = max(floor, gamma_mean_quantile(K, tail / nb))
    hot = np.flatnonzero((P > thr * bg) & (np.arange(nb) >= LINE_BIN0))
    out, i = [], 0
    while i < len(hot):
        j = i
        while j + 1 < len(hot) and hot[j + 1] - hot[j] <= 2:
            j += 1
        lo, hi = max(1, hot[i] - 2), min(nb - 1, hot[j] + 2)
        ex = np.maximum(P[lo:hi + 1] - bg[lo:hi + 1], 0)
        nu = float((ex * np.arange(lo, hi + 1)).sum() / ex.sum()) / nseg
        amp_d = math.sqrt(4 * ex.sum() / nseg)                   # amplitude of the first difference
        out.append((nu, amp_d / (2 * abs(math.sin(math.pi * nu))), float(P[hot[i]:hot[j] + 1].max() / bg[hot[i]])))
        i = j + 1
    return out, K

def rational(x, qmax=16):
    """Small p/q next to x: the (p, q), q <= qmax, with the smallest |x q - p|."""
    best = None
    for q in range(1, qmax + 1):
        p = round(x * q)
        if p < 1 or math.gcd(p, q) != 1:
            continue
        if best is None or abs(x * q - p) < best[2]:
            best = (p, q, abs(x * q - p))
    return best

# ---- the assumptions the data can test ----
LINEAR_NOTE = ('A variance that grows linearly with the span is necessary for fresh noise but does not by itself show that '
               'the increments cannot be predicted: the bound also needs the checks below and the model of the header.')

def stationarity(vals, block_run, rng, perms=5000):
    """Is a the same all through the capture? vals: per block, in time order, the block's value of the
    linear estimate of a (their mean is that estimate). Under stationarity the blocks are exchangeable, so
    the scatter between eight consecutive segments, between runs, and the trend are each compared with
    their values under random reorderings of the blocks."""
    B = len(vals)
    seg = np.zeros(B, dtype=int)
    for g, idx in enumerate(np.array_split(np.arange(B), 8)):
        seg[idx] = g
    shuffled = rng.permuted(np.tile(vals, (perms, 1)), axis=1)

    def between(v, lab):
        hot = (lab[:, None] == np.unique(lab)[None, :]).astype(float)
        cnt = hot.sum(0)
        return (((v @ hot) / cnt - v.mean(-1, keepdims=True)) ** 2 * cnt).sum(-1)

    def p_of(stat):
        return float((1 + (stat(shuffled) >= stat(vals)).sum()) / (perms + 1))

    t = np.arange(B) - (B - 1) / 2
    out = dict(blocks=B, p_segments=p_of(lambda v: between(v, seg)), p_trend=p_of(lambda v: np.abs(v @ t)),
               segments=[dict(blocks=[int(np.flatnonzero(seg == g)[0]), int(np.flatnonzero(seg == g)[-1])],
                              a=float(vals[seg == g].mean()),
                              se=float(vals[seg == g].std(ddof=1) / math.sqrt((seg == g).sum())) if (seg == g).sum() > 1 else None)
                         for g in range(8)], p_runs=None, runs=[])
    ids, cnt = np.unique(block_run, return_counts=True)
    if len(ids) >= 2 and cnt.min() >= 2:
        out['p_runs'] = p_of(lambda v: between(v, block_run))
    out['runs'] = [dict(run=int(i), blocks=int(c), a=float(vals[block_run == i].mean())) for i, c in zip(ids, cnt)]
    ps = [out['p_segments'], out['p_trend']] + ([out['p_runs']] if out['p_runs'] is not None else [])
    out['ok'] = bool(min(ps) >= P_STATIONARY)
    out['statistic'] = ('permutation p-values of the scatter of a between 8 consecutive segments, between runs, and of its '
                        f'trend; a failure is p < {P_STATIONARY}')
    return out

def gaussian_check(runs, running, use, f, n0, spacings, rng, unit):
    """Shape of ring 0's own-difference increments at each spacing: the second difference over the span of
    ring 0 less its regression on the other rings (the combination with the least of the others in it),
    and of the pairs with rings 4 and 5 (fixed coefficient). Every 2m-th difference is taken, so that they
    share no increment. Excess kurtosis is compared with what the counting errors alone give (each reading
    uniform over one count, `unit` periods: -0.6 times the squared share of a ring's reading error in the
    variance). The fractions beyond 2 and 3 standard deviations are compared with a Gaussian's, upward
    only; counts are whole numbers and the differences of a pair lie on a lattice about as coarse as their
    spread, so for the fractions every reading gets a uniform dither of one count first."""
    sel, i0, out = [running.index(i) for i in use], use.index(0), {}
    for s in spacings:
        m = max(1, int(round(s / n0)))
        D = [(r['z'][2 * m:] - 2 * r['z'][m:-m] + r['z'][:-2 * m])[::2 * m][:, sel] for r in runs if r['n'] > 4 * m]
        n = sum(len(d) for d in D)
        row = dict(span_clocks=int(m * n0), increments=int(n), series={})
        if n < 200:
            out[str(int(s))] = dict(row, ok=None, why='fewer than 200 increments that share nothing: '
                                    f'{200 * 2 * m} records are needed for this spacing')
            continue
        D = np.concatenate(D)
        u = (rng.random((3,) + D.shape) - 0.5) * unit
        Dd = D + u[0] - 2 * u[1] + u[2]                           # readings dithered by one count, for the tail fractions
        C = D.T @ D / n
        others = [k for k in range(len(use)) if k != i0]
        w = np.zeros(len(use))
        w[i0] = 1.0
        w[others] = -np.linalg.lstsq(C[np.ix_(others, others)], C[others, i0], rcond=None)[0]
        series = {'ring 0 less its regression on the others': w}
        for j in (4, 5):
            if j in use:
                w = np.zeros(len(use))
                w[i0], w[use.index(j)] = 1.0, -f[sel[i0]] / f[sel[use.index(j)]]
                series[f'pair 0-{j}'] = w
        tol = Z_GAUSS * math.sqrt(24 / n) + G_FLOOR
        t2, t3 = P2 + Z_GAUSS * math.sqrt(P2 * (1 - P2) / n), P3 + Z_GAUSS * math.sqrt(P3 * (1 - P3) / n)
        ok = True
        for name, w in series.items():
            e = D @ w
            e = e - e.mean()
            v = float((e * e).mean())
            if not v > 0:
                row['series'][name] = dict(ok=None, why='no variance')
                continue
            g2 = float((e ** 4).mean() / v ** 2 - 3)
            expect = float(-0.6 * ((2 * reading(unit) * w * w) ** 2).sum() / v ** 2)
            x = Dd @ w
            x = np.abs(x - x.mean()) / x.std()
            f2_, f3_ = float((x > 2).mean()), float((x > 3).mean())
            good = bool(abs(g2 - expect) <= tol and f2_ <= t2 and f3_ <= t3)
            ok &= good
            row['series'][name] = dict(ok=good, variance=v, excess_kurtosis=g2, expected=expect, tolerance=tol,
                                       beyond_2sd=f2_, limit_2sd=t2, beyond_3sd=f3_, limit_3sd=t3)
        out[str(int(s))] = dict(row, ok=bool(ok))
    return out

# ---- the analysis ----
DEFINITIONS = dict(
    statistic='A_z(m) = 1/2 mean_k (z(k+2m) - 2 z(k+m) + z(k))^2 over every k, z a phase in ring periods, span tau = m N0 '
              'clocks; A_zw(m) likewise with the product of two series. One quadratic per run is taken out of each phase first.',
    white_fm='A = a tau; a tau is the variance of the phase increment over tau given the past (credited)',
    resolution='A = 3 q for an independent reading error of variance q (counting in steps of u periods: u^2 / 4, 1 for the '
               'divided count, 1/4 for the direct one); no phase variance',
    flicker_fm='A = 2 ln2 h tau^2 = b tau^2: an upper limit of the increment\'s conditional variance; not credited',
    pair='x_i - c x_j: fixed c = f_i / f_j (cancels the clock exactly), fitted c = ratio of the loadings on the shared part',
    own='hat: f_0^2 (g_00 - g_04 - g_05 + g_45), g_ij = A_ij / (f_i f_j); ls: least squares of g_ii + g_jj - 2 g_ij = psi_i + '
        'psi_j; f1: g_ij = v_i v_j; f2: g_ij = rho + v_i v_j (clock and one factor); upper: 1 / (A^-1)_ii',
    bound='a_low = min over hat, ls, f1, f2 of (a - t se), and of the bootstrap percentile; credited variance = a_low x spacing; '
          'pass: credited variance >= margin x the variance that the target needs at the measured duty bound')

def prepare(cap, notes, rejected, unit):
    """Unwrap the runs (in counts), turn the counts into ring periods (one count is `unit` periods), find
    the running rings, split at jumps, take the ramp and a quadratic out. Returns the runs (dicts with x:
    int64 periods, raw: ramp out, z: residual phase), the running rings, the rates in periods per clock,
    the relative drift over the capture and the unwrap figures (in counts)."""
    n0, tot = int(cap['n0']), cap['tot']
    runs, unwrap = [], dict(count_unit=int(unit), median_increment=None, largest_deviation=[0] * NR)
    for a, b in cap['runs']:
        if b - a < MIN_RUN:
            rejected.append(dict(start=int(a), records=int(b - a), why=f'shorter than {MIN_RUN} records'))
            continue
        if cap.get('wrapped'):
            x, med, dev = unwrap_run(tot[a:b], cap.get('nominal'))
        else:
            x = tot[a:b] - tot[a]
            med = np.median(np.diff(x, axis=0), axis=0).astype(np.int64)
        runs.append(dict(start=a, n=b - a, x=x * unit, med=med * unit))
    if not runs:
        return None
    moving = np.array([[r['x'][-1, i] != 0 for i in range(NR)] for r in runs])
    running = [i for i in range(NR) if moving[:, i].all()]
    for i in range(NR):
        if moving[:, i].any() and not moving[:, i].all():
            notes.append(f'ring {i} runs in some runs and stands still in others: not used')
    if cap.get('ring_mask') is not None:
        want = [i for i in range(NR) if (int(cap['ring_mask']) >> i) & 1]
        if want != running:
            notes.append(f'ring_mask of the sidecar says rings {want}, the counts move for rings {running}')
    # An increment is taken for what it is modulo 2^20 next to the median. That is certain while it is within
    # 2^19 of the median; a run is split wherever one is further than a quarter of the median (below 2^18)
    # from it, which is no noise but a lost record or more.
    clean = []
    for r in runs:
        inc = np.diff(r['x'][:, running], axis=0)
        med = r['med'][running]
        dev = np.abs(inc - med)
        bad = np.flatnonzero((dev > 0.25 * np.maximum(np.abs(med), 1)).any(1))
        cuts = [0] + [int(i) + 1 for i in bad] + [r['n']]
        for k, (s, e) in enumerate(zip(cuts[:-1], cuts[1:])):
            if k:
                rejected.append(dict(start=int(r['start'] + s), records=0,
                                     why='count jumps by more than a quarter of the increment: run split here'))
            if e - s >= MIN_RUN:
                clean.append(dict(start=r['start'] + s, n=e - s, x=r['x'][s:e] - r['x'][s], med=r['med']))
                d = np.abs(np.diff(r['x'][s:e], axis=0) - r['med']).max(0) // unit
                unwrap['largest_deviation'] = [int(max(p, q)) for p, q in zip(unwrap['largest_deviation'], d)]
            elif e > s:
                rejected.append(dict(start=int(r['start'] + s), records=int(e - s), why=f'shorter than {MIN_RUN} records'))
    runs = clean
    if not runs or len(running) < 2:
        return None
    nr, ntot = len(running), sum(r['n'] for r in runs)
    q = np.round(np.average([r['med'][running] for r in runs], axis=0, weights=[r['n'] for r in runs])).astype(np.int64)
    unwrap['median_increment'] = [int(v) for v in np.round(np.average([r['med'] for r in runs], axis=0,
                                                                     weights=[r['n'] for r in runs]) / unit)]
    unwrap['condition'] = ('in counts: each increment is taken modulo 2^20 next to the median; certain within 2^19 = 524288 '
                           'of it, runs are split beyond a quarter of the median')
    rate, drift = np.zeros(nr), np.zeros(nr)
    for r in runs:                                               # the ramp out in integers, then one quadratic per run
        n = r['n']
        k = np.arange(n, dtype=np.int64)
        res = (r['x'][:, running] - k[:, None] * q[None, :]).astype(np.float64)
        t = np.linspace(-1.0, 1.0, n)
        P = np.stack([np.ones(n), t, 1.5 * t * t - 0.5], 1)
        coef = np.linalg.lstsq(P, res, rcond=None)[0]
        r['raw'], r['z'] = res, res - P @ coef
        rate += n * (q + coef[1] * 2 / (n - 1))
        drift += 12 * coef[2] / (n - 1)                          # change of the increment over this run
    inc = rate / ntot
    return runs, running, inc / n0, drift / inc, unwrap

def count_bit(e, mid, db, ones):
    """Do a ring's counts and its lane bit belong together? e: the second differences over one record of
    the ring's phase, less their regression on the other rings (which takes the shared part out and
    leaves the ring's own noise and reading errors); mid: the bit at the middle reading; db: the bit's
    second difference. The count is unit * floor((phase - latency) / unit) and the bit is 1 while the
    phase fraction is below D, so the middle reading's error depends on the bit. Two numbers show it,
    each between -1/2 and 1/2 whatever the unit, one large where the other vanishes:
      slope  of e on db: 1/2 - latency / D for a latency below D of a period, and back up to 1/2 at 1;
      square the slope of e^2 on the bit: 0 at a latency of 0 or 1/2, +1/2 at 1/4, -1/2 at 3/4.
    Their root sum of squares is 0.45 to 0.5 for bits of these counts and 0 for unrelated ones. The
    latency is only known modulo one period: the count is read through the divider and the counter."""
    n, sbb = len(e), float((db * db).sum())
    bc = mid - mid.mean()
    vb = float((bc * bc).mean())
    if n < 100 or not (sbb > 0 and vb > 0):
        return None
    beta = float((e * db).sum() / sbb)
    se_b = math.sqrt(max(float(((e - beta * db) ** 2).mean()), 0.0) / sbb)
    e2 = e * e - (e * e).mean()
    quad = float((e2 * bc).mean() / vb)
    se_q = math.sqrt(float((e2 * e2).mean()) / (vb * n))
    rel, se = math.hypot(beta, quad), max(se_b, se_q)
    if 0.2 <= rel <= 0.75 + PAIR_Z * se and rel >= PAIR_Z * se:
        ok = True
    elif rel + PAIR_Z * se < 0.3 or rel - PAIR_Z * se > 0.75:
        ok = False
    else:
        ok = None                                                # too noisy to tell
    lat = ones * (0.5 - beta)
    return dict(slope=beta, slope_se=se_b, square=quad, square_se=se_q, relation=rel,
                latency=float(min(max(lat if quad >= 0 else 1 - lat, 0.0), 1.0)), ok=ok)

def ring_table(runs, running, f, drift, rate_se, cap, z_duty):
    """Per ring: rate, drift, the lane bit's ones and duty, the count against the bit."""
    lanes, rows, duty = cap.get('lanes'), [], {}
    stages = cap.get('stages') or [None] * NR
    nbits = sum(r['n'] for r in runs)
    D = np.concatenate([r['z'][2:] - 2 * r['z'][1:-1] + r['z'][:-2] for r in runs])
    C = D.T @ D
    for j, i in enumerate(running):
        row = dict(ring=i, stages=stages[i] if i < len(stages) else None, rate=float(f[j]), rate_se=float(rate_se[j]),
                   hz=float(f[j] * cap.get('clock_hz', 75e6)), drift=float(drift[j]),
                   step_rms=None, first_span=None, ones=None, duty_hi=None, count_bit=None)
        if lanes is not None and i < 4:
            bit = [((lanes[r['start']:r['start'] + r['n']] >> i) & 1).astype(np.float64) for r in runs]
            ones = float(sum(b.sum() for b in bit) / nbits)
            row['ones'] = ones
            row['duty_hi'] = duty[i] = 0.5 + abs(ones - 0.5) + z_duty * math.sqrt(max(ones * (1 - ones), 0.0) / nbits)
            others = [k for k in range(len(running)) if k != j]
            e = D[:, j] - D[:, others] @ np.linalg.lstsq(C[np.ix_(others, others)], C[others, j], rcond=None)[0]
            if 0 < ones < 1:
                row['count_bit'] = count_bit(e, np.concatenate([b[1:-1] for b in bit]),
                                             np.concatenate([b[2:] - 2 * b[1:-1] + b[:-2] for b in bit]), ones)
        rows.append(row)
    return rows, duty

def lock_scan(runs, running, f, Mb, n0, unit):
    """Pairs that do not diffuse: the counts keep a small rational ratio exactly, or the pair's variance does
    not grow from the first fitted span to the last while the other pairs' does."""
    nr, B = len(running), len(Mb)
    T_clk = sum(r['n'] for r in runs) * n0
    ff = f[:, None] * f[None, :]
    dg = (Mb[:, -1] - Mb[:, 0]) / ff
    dd = _diag(dg)
    Dv = dd[:, :, None] + dd[:, None, :] - 2 * dg                # growth of the pair variance, clock periods^2
    Dm, Ds = Dv.mean(0), Dv.std(0, ddof=1) / math.sqrt(B)
    iu = np.triu_indices(nr, 1)
    med = float(np.median(Dm[iu]))
    rows, locks = [], []
    for a, b in zip(*iu):
        i, j = running[a], running[b]
        pq = rational(f[a] / f[b])
        hard, exc = False, None
        if pq and abs(f[a] * pq[1] - f[b] * pq[0]) * T_clk < 64 * (pq[0] + pq[1]) * unit:
            exc = max(int(np.ptp(pq[1] * r['x'][:, i] - pq[0] * r['x'][:, j])) for r in runs)
            hard = exc <= 4 * (pq[0] + pq[1]) * unit             # four counts of each ring, in periods
        flat = bool(nr >= 3 and med > 0 and Dm[a, b] + 3 * Ds[a, b] < 0.1 * med)
        rows.append(dict(pair=[i, j], ratio=float(f[a] / f[b]), near=[pq[0], pq[1]] if pq else None, excursion=exc,
                         growth=float(Dm[a, b] * f[a] ** 2), growth_se=float(Ds[a, b] * f[a] ** 2),
                         growth_median=float(med * f[a] ** 2), locked=bool(hard or flat),
                         why=('the counts keep the ratio %d:%d to within %d periods over every run' % (pq[0], pq[1], exc)
                              if hard else 'the pair variance does not grow with the span' if flat else None)))
        if hard or flat:
            locks.append((i, j))
    return rows, locks

def describe(S_full, running, f, n0, sens):
    """The tables of item 2: every ring against the clock and every pair, at all spans."""
    nr = len(running)
    tab = dict(m=list(S_full), clocks=[int(m * n0) for m in S_full], pieces=[int(S_full[m][1] // m) for m in S_full],
               ring_vs_clock={}, pairs={})
    for j, i in enumerate(running):
        tab['ring_vs_clock'][str(i)] = [float(S_full[m][0][j, j]) for m in S_full]
    for a in range(nr):
        for b in range(a + 1, nr):
            c = f[a] / f[b]
            row = dict(coefficient=float(c),
                       fixed=[float(S[a, a] + c * c * S[b, b] - 2 * c * S[a, b]) for S, _ in S_full.values()])
            third = [k for k in range(nr) if k not in (a, b)]
            if third:                                            # the loading ratio, from the other rings
                cf, fit_ = [], []
                for S, _ in S_full.values():
                    num, den = sum(S[a, k] for k in third), sum(S[b, k] for k in third)
                    cc = num / den if den > 0 and abs(num / den / c - 1) <= sens else None
                    cf.append(None if cc is None else float(cc))
                    fit_.append(None if cc is None else float(S[a, a] + cc * cc * S[b, b] - 2 * cc * S[a, b]))
                row['coefficient_fitted'], row['fitted'] = cf, fit_
            tab['pairs'][f'{running[a]}-{running[b]}'] = row
    return tab

def line_scan(runs, running, f, n0, clock_hz):
    """Lines in each ring's phase against the clock and in each pair's (fixed coefficient)."""
    longest = max(r['n'] for r in runs)
    nseg = 1 << max(6, min(16, int(math.log2(max(longest // 8, 64)))))
    if longest < 8 * nseg:
        return [], 'capture too short for the line search'
    hz, rows, nr = clock_hz / n0, [], len(running)
    to0 = (lambda a: (f[running.index(0)] / f[a]) ** 2) if 0 in running else (lambda a: 1.0)
    for a in range(nr):
        for nu, amp, ratio in find_lines([r['z'][:, a] for r in runs], nseg)[0]:
            rows.append(dict(series=f'ring {running[a]}', rings=[running[a]], cycles_per_record=nu, hz=nu * hz, amplitude=amp,
                             unit=f'periods of ring {running[a]}', over_background=ratio, variance_max=4 * amp * amp))
    for a in range(nr):
        for b in range(a + 1, nr):
            for nu, amp, ratio in find_lines([r['z'][:, a] - f[a] / f[b] * r['z'][:, b] for r in runs], nseg)[0]:
                rows.append(dict(series=f'pair {running[a]}-{running[b]}', rings=[running[a], running[b]],
                                 cycles_per_record=nu, hz=nu * hz, amplitude=amp, unit=f'periods of ring {running[a]}',
                                 over_background=ratio, variance_max=4 * amp * amp * to0(a)))
    return rows, (f'{nseg}-record segments; a frequency is known modulo the record rate {hz:.6g} Hz and is not searched '
                  f'below {LINE_BIN0 * hz / nseg:.4g} Hz; variance_max = 4 amplitude^2 is the most a line adds to the '
                  'statistic of that series (pairs: in periods^2 of ring 0)')

def block_length(runs, blocks):
    """The longest block that still gives the number of blocks asked (at least 16 records)."""
    L, lo, hi = 0, 16, max(r['n'] for r in runs)
    while lo <= hi:
        mid = (lo + hi) // 2
        if sum(r['n'] // mid for r in runs) >= blocks:
            L, lo = mid, mid + 1
        else:
            hi = mid - 1
    return L or 16

def block_rates(runs, L, nr, n0):
    """The standard error of each ring's mean rate, periods per clock: the scatter of the blocks' rates."""
    cut = [r for r in runs if r['n'] >= L]
    if not cut:
        return np.full(nr, np.nan)
    rb = np.concatenate([r['raw'][:(r['n'] // L) * L].reshape(-1, L, nr) for r in cut])
    return (rb[:, -1] - rb[:, 0]).std(0, ddof=1) / (L - 1) / math.sqrt(len(rb)) / n0 if len(rb) > 1 else np.full(nr, np.nan)

def pair_check(this, other, blocks, sens):
    """The same rings in the other counting mode: are the two captures' rates, in ring periods per clock,
    the same? this, other: dicts with file, unit, n0, running, f, se, drift, records, clock_hz, time.
    With the units applied the ratio of a ring's two rates must be 1 (the hardware's counts are then in
    the ratio of the units, 2). What may make it differ is the drift of the rings between the captures:
      - every ring's ratio may be off 1 by PAIR_Z standard errors, plus the drift seen within the two
        captures (relative change of the rate over each) carried over the time between them (from the
        sidecars' times; PAIR_GAP capture lengths when they have none), plus PAIR_FLOOR;
      - temperature and supply move all rings nearly alike, so a ring's ratio may differ from the median
        of all by PAIR_Z standard errors, plus sens of the median's own distance from 1, plus the drift
        within the captures.
    A counter or divider that runs steadily at a wrong rate shows in the second test at the level of the
    errors, and in the first when all rings are wrong alike."""
    out = dict(other=other['file'], count_unit=[int(this['unit']), int(other['unit'])], rings=[], ok=None, why=[])
    if this['unit'] == other['unit']:
        out['why'].append(f"both captures count in units of {this['unit']} period(s): the pair must be one of each mode")
    if this['n0'] != other['n0']:
        out['why'].append(f"the spacings differ: {this['n0']} and {other['n0']} clocks per record")
    if this['running'] != other['running']:
        out['why'].append(f"the rings differ: {this['running']} and {other['running']}")
    if out['why']:
        out['ok'] = False
        return out
    length = [c['records'] * c['n0'] / c['clock_hz'] for c in (this, other)]
    if this.get('time') is not None and other.get('time') is not None:
        gap = (abs(this['time'] - other['time']) + max(length)) / (sum(length) / 2)
        out['gap'] = dict(lengths=gap, source='the time stamps of the two sidecars')
    else:
        gap = PAIR_GAP
        out['gap'] = dict(lengths=gap, source='no time stamps: assumed')
    r = this['f'] / other['f']
    se = r * np.hypot(this['se'] / this['f'], other['se'] / other['f'])
    dr = np.abs(this['drift']) + np.abs(other['drift'])
    common = float(np.median(r - 1)) if len(r) >= 3 else 0.0
    out.update(common=common, statistic=f'ratio of the mean rates, this capture over the other; allowed: {PAIR_Z:g} standard '
               f'errors + {gap:.3g} x the drift within the captures + {PAIR_FLOOR:g}; from the median of the rings: {PAIR_Z:g} '
               f'standard errors + {sens:g} x the median\'s distance from 1 + the drift within the captures')
    bad = []
    for k, i in enumerate(this['running']):
        allowed = PAIR_Z * se[k] + gap * dr[k] + PAIR_FLOOR
        allowed_rel = PAIR_Z * se[k] + sens * abs(common) + dr[k]
        off, off_rel = float(r[k] - 1), float(r[k] - 1 - common)
        flag = bool(abs(off) > allowed or (len(r) >= 3 and abs(off_rel) > allowed_rel))
        out['rings'].append(dict(ring=i, rate=float(this['f'][k]), rate_other=float(other['f'][k]), ratio=float(r[k]), se=float(se[k]),
                                 counts_ratio=float((other['f'][k] / other['unit']) / (this['f'][k] / this['unit'])),
                                 drift=float(this['drift'][k]), drift_other=float(other['drift'][k]),
                                 off=off, allowed=float(allowed), off_from_median=off_rel, allowed_from_median=float(allowed_rel),
                                 flagged=flag))
        if flag:
            bad.append(i)
    out['ok'] = not bad
    if bad:
        out['why'].append('the rates of ring(s) ' + ', '.join(str(i) for i in bad) + ' in the two modes are not the same once the '
                          'count units are applied: more than the drift allows')
    return out

def bits_check(analysis, lane_ring, running, f, drift, name=None):
    """The count rates against the rings' sampled bits, which no counter and no divider has touched.
    analysis: what getnoise_analyze.py wrote for burst captures of sampled bits. For bursts at a sampling
    period of one clock a lane's fitted F is the fractional part of its ring's periods per clock, folded
    into [0, 1/2]: F or 1 - F. So for each mapped ring that runs here: the distance on the circle of
    frac(rate) to F and to 1 - F, the smaller of them, against
        BITS_Z * (F's stated uncertainty: the largest of the scatter of F between the windows, the
        windows' expected spread and the fits' standard errors)
        + rate * (the relative drift of the rate over this capture + BITS_DRIFT),
    BITS_DRIFT being what a ring is taken to drift between two captures some minutes apart.

    The check holds only when EVERY ring that the map names and that runs in this capture has a usable
    frequency fit and agrees: a ring without one fails the check ("no usable frequency fit"). A mapped
    lane whose ring does not run here is listed and does not count.

    What it can see: only the FOLDED frequency is compared, the fractional part of the periods per clock.
    A wrong ratio of the divider puts frac(rate) anywhere, so n rings agreeing within tolerances t_i
    happens by accident with a chance of about the product of 4 t_i. But a count that is wrong by a whole
    number of periods per clock leaves the fraction as it is and passes. That is what --pair, the direct
    count against the divided one, is for; and --pair alone cannot tell a divider that is right from a
    direct counter that loses the same share. Neither check alone qualifies the instrument."""
    out = dict(analysis=name, capture=None, map={str(k): v for k, v in lane_ring.items()}, rings=[], checked=0, required=0,
               failed=[], missing=[], not_running=[], ok=None, why=[],
               sees='the folded frequency only: the fraction of the periods per clock against F or 1 - F of the sampled bits. A '
                    'count wrong by a whole number of periods per clock passes; --pair is needed as well, and neither check '
                    'alone qualifies the instrument')
    caps = [c for c in analysis.get('captures', []) if c.get('clocks') == 1 and c.get('lanes')]
    if not caps:
        out['why'].append('no burst capture at a sampling period of one clock in the analysis')
        out['ok'] = False
        return out
    cap = caps[0]
    out['capture'] = cap.get('file')
    lanes = {l.get('lane'): l for l in cap['lanes']}
    chance = 1.0
    for lane, ring in sorted(lane_ring.items()):
        row = dict(ring=ring, lane=lane, ok=None)
        out['rings'].append(row)
        if ring not in running:
            row['why'] = 'the ring does not run in this capture: not counted'
            out['not_running'].append(ring)
            continue
        out['required'] += 1
        l = lanes.get(lane) or {}
        w, pooled, fit = l.get('windows') or {}, l.get('pooled') or {}, l.get('fit') or {}
        F = (w.get('F_median') if w.get('usable') and w.get('F_median') is not None else
             pooled.get('F') if pooled.get('identifiable') and pooled.get('F') is not None else
             fit.get('F') if fit.get('identifiable') else None)
        errs = [v for v in (w.get('F_spread'), w.get('F_expected_spread'), pooled.get('se_F'), fit.get('se_F')) if v]
        if F is None or not errs:
            row.update(ok=False, why='no usable frequency fit')
            out['missing'].append(ring)
            continue
        k = running.index(ring)
        rate = float(f[k])
        frac = rate - math.floor(rate)
        circle = lambda a, b: min(abs(a - b), 1 - abs(a - b))
        dist = min(circle(frac, F), circle(frac, 1 - F))
        tol = BITS_Z * max(errs) + rate * (abs(float(drift[k])) + BITS_DRIFT)
        row.update(rate=rate, frac=frac, F=float(F), F_uncertainty=float(max(errs)), distance=float(dist), tolerance=float(tol),
                   ok=bool(dist <= tol))
        out['checked'] += 1
        chance *= min(1.0, 4 * tol)
        if not row['ok']:
            out['failed'].append(ring)
    out.update(ok=bool(out['required'] and out['checked'] == out['required'] and not out['failed']),
               accidental=chance if out['checked'] else None,
               statistic=f'distance of frac(rate) to F or 1 - F against {BITS_Z:g} x F\'s uncertainty + rate x (drift within the '
                         f'capture + {BITS_DRIFT:g} between the captures); every mapped ring that runs must have a usable fit and '
                         'agree; a wrong ratio puts frac(rate) anywhere, so the agreement of the checked rings is accidental with '
                         'a chance of about the product of 4 x tolerance')
    if out['failed']:
        out['why'].append('the count rate does not agree with the ring\'s sampled frequency: the divider\'s ratio is not established '
                          '(ring(s) ' + ', '.join(str(i) for i in out['failed']) + ')')
    if out['missing']:
        out['why'].append('no usable frequency fit for ring(s) ' + ', '.join(str(i) for i in out['missing']) + ': every mapped ring '
                          f"that runs must be measured, and {out['checked']} of {out['required']} were")
    if not out['required']:
        out['why'].append('no mapped ring runs in this capture: nothing was checked against sampled bits')
    return out

def analyze(cap, spacings=SPACINGS, blocks=64, boot=400, conf=0.99, target=0.75, margin=2.0, sens=0.25, z_duty=2.576,
            operating_mask=None, count_unit=None, pair=None, bits=None, bits_map=None, bits_name=None, seed=1, lines=True,
            full=True, grid=0, min_records=None):
    """cap: the dict of load_capture. Returns the result (JSON-able). operating_mask: the rings that run
    in normal operation, in place of the capture's own record of it. count_unit: ring periods per count,
    for input that does not say (a records file must: the option then only sets what the numbers are
    in). pair: a capture of the same rings and spacing in the other counting mode. bits: the analysis of
    burst captures of sampled bits (getnoise_analyze.py), bits_map its lanes' rings. min_records: for
    tests only, in place of MIN_RECORDS; its use is written into the output. full=False skips
    the tables of all spans and the line search (for the coverage study); grid is p_max's grid (0: its
    default)."""
    notes, n0 = [], int(cap['n0'])
    rejected = list(cap.get('rejected', []))
    recorded = cap.get('count_unit')
    unit = int(count_unit if count_unit is not None else recorded if recorded is not None else 1)
    unit_why = None
    if cap.get('wrapped') and recorded is None:
        unit_why = ('count unit not recorded: the sidecar has no count_unit (2 behind the divider, 1 in direct mode); the '
                    f'numbers here take one count for {unit} period(s)')
    elif count_unit is not None and recorded is not None and int(count_unit) != int(recorded) and cap.get('wrapped'):
        unit_why = f'the count unit given ({int(count_unit)}) is not the one of the sidecar ({int(recorded)})'
    prep = prepare(cap, notes, rejected, unit)
    if prep is None:
        return dict(tool='rosc_own', error='no usable run, or fewer than two running rings', rejected=rejected, notes=notes,
                    verdict={str(int(s)): dict(spacing=int(s), verdict='not established', why=['no usable data'])
                             for s in spacings})
    runs, running, f, drift, unwrap = prep
    nr, ntot = len(running), sum(r['n'] for r in runs)
    # blocks: the longest that still gives the number asked; differences are taken inside a block only
    L = block_length(runs, blocks)
    cut = [r for r in runs if r['n'] >= L]
    zb = np.concatenate([r['z'][:(r['n'] // L) * L].reshape(-1, L, nr) for r in cut]) if cut else np.zeros((0, L, nr))
    block_run = np.concatenate([np.full(r['n'] // L, k) for k, r in enumerate(cut)]) if cut else np.zeros(0, dtype=int)
    B = len(zb)
    fit_ms = spans_upto(L // 4)
    tau = np.array(fit_ms, dtype=float) * n0
    rate_se = block_rates(runs, L, nr, n0)
    enough = B >= MIN_BLOCKS and len(fit_ms) >= MIN_SPANS
    if not enough:
        notes.append(f'too little data for a bound: {B} blocks of {L} records and {len(fit_ms)} spans; '
                     f'{MIN_BLOCKS} blocks and {MIN_SPANS} spans are needed')
    ring_rows, duty_hi = ring_table(runs, running, f, drift, rate_se, cap, z_duty)
    # the records that can carry a bound: those that enter the fit, whole blocks of the runs kept after
    # every run set aside (flagged counts, losses, jumps, the least run length); the end of a run too
    # short for another block is not among them. The records of the runs kept are reported beside them.
    in_runs = int(sum(r['n'] for r in cut))
    usable = int(B * L)
    least = MIN_RECORDS if min_records is None else int(min_records)
    lowered = least < MIN_RECORDS
    if lowered:
        notes.append(f'minimum lowered to {least} records for a test (--min-records): a capture that is to carry a bound needs '
                     f'{MIN_RECORDS}')
    data_mask = sum(1 << i for i in running)
    op_mask = cap.get('op_mask') if operating_mask is None else int(operating_mask)
    out = dict(tool='rosc_own', version=1, definitions=DEFINITIONS,
               input=dict(file=cap.get('file'), records=int(ntot), records_usable=usable, records_in_kept_runs=in_runs,
                          min_records=least,
                          min_records_lowered=bool(lowered), n0=n0, clock_hz=cap.get('clock_hz', 75e6),
                          runs=[dict(start=int(r['start']), records=int(r['n'])) for r in runs], rejected=rejected,
                          count_unit=unit, count_unit_recorded=recorded, count_unit_known=not unit_why,
                          counting=('direct: single periods, the counter clocked by the ring itself' if unit == 1 else
                                    f'divided: one count is {unit} ring periods'),
                          running=running, off=[i for i in range(NR) if i not in running], ring_mask=data_mask,
                          ring_mask_recorded=cap.get('ring_mask'), operating_mask=op_mask,
                          health={True: 'recorded: no run with a flagged count is used', False: 'not recorded',
                                  None: 'not applicable (no records file)'}[cap.get('health')],
                          blocks=int(B), block_records=int(L), unwrap=unwrap),
               notes=notes, rings=ring_rows, assumptions=dict(note=LINEAR_NOTE))
    lane, lane0_locked, use, line_rows = {}, False, list(running), []
    out['lock'] = dict(pairs=[], locked=[], dropped=[])
    if B >= 2 and len(fit_ms) >= 2:
        Mb = block_moments(zb, fit_ms)                           # [blocks, spans, rings, rings]
        S0 = Mb.mean(0)
        # The counting errors of two readings are independent once the phase has moved by a good part of a
        # count between them: their correlation falls as exp(-2 pi^2 v / unit^2), v the variance of the
        # movement against the clock in periods^2 (the ring's A less the reading error's unit^2 / 4). A
        # ring's fit starts at the first span with v >= MOVE unit^2.
        first = np.zeros(nr, dtype=int)
        for j, row in enumerate(ring_rows):
            mv = _diag(S0)[:, j] - reading(unit)
            row['step_rms'] = float(math.sqrt(max(mv[0], 0.0)))
            okm = np.flatnonzero(mv >= MOVE * unit * unit)
            first[j] = int(okm[0]) if len(okm) else len(fit_ms)
            row['first_span'] = int(tau[first[j]]) if first[j] < len(fit_ms) else None
            if first[j] > 0:
                notes.append(f"ring {row['ring']} moves by {row['step_rms']:.2f} period rms per record against the clock: "
                             'its counting errors are not independent from record to record, and '
                             + (f"its fit starts at {row['first_span']} clocks" if row['first_span'] else
                                'no fitted span is long enough for a fit') + ' (assumption 6)')
        rng = np.random.default_rng(seed)
        Srep = np.tensordot(rng.multinomial(B, np.full(B, 1.0 / B), size=boot) / B, Mb, axes=(1, 0))   # [R, spans, n, n]
        bcorr, tq = math.sqrt(B / (B - 1)), t_ppf(conf, B - 1)
        lock_rows, locks = lock_scan(runs, running, f, Mb, n0, unit)
        lane0_locked = any(0 in p for p in locks)
        drop = set()
        for i, j in locks:                                       # ring 0 stays; of other locked pairs both go
            drop |= ({j} if i == 0 else {i} if j == 0 else {i, j})
        use = [i for i in running if i not in drop]
        out['lock'] = dict(pairs=lock_rows, locked=[list(p) for p in locks], dropped=sorted(drop))
        if 0 not in use:
            notes.append('ring 0 does not run: no bound')
        if len(use) >= 3:
            lane = own_and_bound(out, S0, Srep, Mb, block_run, rng, f, running, use, first, fit_ms, tau, tq, bcorr, enough,
                                 sens, conf, notes, unit)
            if 0 in use:
                out['assumptions']['gaussian'] = gaussian_check(runs, running, use, f, n0, spacings, rng, unit)
        else:
            notes.append(f'{len(use)} usable rings: a ring\'s own variance needs three (two partners)')
    if full:
        S_full = {}
        for m in spans_upto(max(r['n'] for r in runs) // 10):
            S, cnt = second_moments([r['z'] for r in runs], m)
            if S is not None:
                S_full[m] = (S, cnt)
        if S_full:
            out['spans'] = describe(S_full, running, f, n0, sens)
            long_ms = [m for m in S_full if m not in fit_ms]
            if long_ms and len(use) >= 3 and 0 in use:           # ring 0's own variance at the long spans, points only
                sel = [running.index(i) for i in use]
                ol, _ = own_all(np.stack([S_full[m][0][np.ix_(sel, sel)] for m in long_ms]), f[sel], use, sens)
                out['spans']['own_long'] = dict(m=long_ms, clocks=[int(m * n0) for m in long_ms],
                                                ring0={k: v[:, use.index(0)].tolist() for k, v in ol.items()
                                                       if np.isfinite(v[:, use.index(0)]).all()})
        if lines:
            line_rows, note = line_scan(runs, running, f, n0, cap.get('clock_hz', 75e6))
            out['lines'] = dict(note=note, found=line_rows)
    # the same rings in the other counting mode
    if pair is not None:
        me = dict(file=cap.get('file'), unit=unit, n0=n0, running=running, f=f, se=rate_se, drift=drift, records=ntot,
                  clock_hz=cap.get('clock_hz', 75e6), time=cap.get('time'))
        ou = int(pair['count_unit']) if pair.get('count_unit') is not None else None
        prep2 = prepare(pair, [], [], ou) if ou else None
        if prep2 is None:
            out['pair'] = dict(other=pair.get('file'), count_unit=[unit, ou], ok=False, rings=[],
                               why=['the other capture has no usable run' if ou else 'the other capture\'s count unit is not recorded'])
        else:
            runs2, running2, f2, drift2, _ = prep2
            n2 = int(pair['n0'])
            out['pair'] = pair_check(me, dict(file=pair.get('file'), unit=ou, n0=n2, running=running2, f=f2,
                                              se=block_rates(runs2, block_length(runs2, blocks), len(running2), n2), drift=drift2,
                                              records=sum(r['n'] for r in runs2), clock_hz=pair.get('clock_hz', 75e6),
                                              time=pair.get('time')), blocks, sens)
    if bits is not None:
        out['bits'] = bits_check(bits, BITS_MAP if bits_map is None else bits_map, running, f, drift, bits_name)
    # verdict
    D = duty_hi.get(0)
    core_pairs = ([(0, 4), (0, 5), (4, 5)] if lane and 'hat' in lane['methods'] else [(a, b) for a in use for b in use if a < b])
    line_var = max([l['variance_max'] for l in line_rows if len(l['rings']) == 2 and tuple(l['rings']) in core_pairs] or [0.0])
    cb = next((r['count_bit'] for r in ring_rows if r['ring'] == 0), None)
    ass = out['assumptions']
    verdict = {}
    for s in spacings:
        why, v = [], dict(spacing=int(s))
        if unit_why:
            why.append(unit_why)
        if usable < least:
            why.append(f'{usable} usable records, a bound needs at least {least} (the records in the {B} blocks of {L} '
                       f'that enter the fit; {in_runs} in the runs kept)')
        if lowered:
            v['min_records_lowered'] = f'minimum lowered to {least} records for a test: not for a claim capture'
        if cap.get('health') is False:
            why.append('instrument health not recorded: the sidecar has no bad_counts for its runs')
        if 'pair' in out and not out['pair']['ok']:
            why.append('the pair of counting modes: ' + '; '.join(out['pair']['why']))
        if 'bits' in out and not out['bits']['ok']:
            why.append('; '.join(out['bits']['why']))
        if cap.get('ring_mask') is not None and int(cap['ring_mask']) != data_mask:
            why.append(f"the sidecar's ring_mask {int(cap['ring_mask']):#04x} is not the rings whose counts move ({data_mask:#04x})")
        if op_mask is None:
            why.append('the rings that run in normal operation are not known (strap_mask in the sidecar, or --operating-mask)')
        if not lane:
            why.append('no bound: ' + ('; '.join(notes) if notes else 'see notes'))
        else:
            v['credited_variance'] = lane['a_low'] * s
            if D is None:
                why.append('no lane bit of ring 0: the duty cycle is not known')
            else:
                need = s2_needed(math.ceil(D * 1e4) / 1e4, target)
                v.update(duty=D, variance_needed=need, ratio=None if not need else lane['a_low'] * s / need,
                         margin_required=margin, margin_met=bool(need and lane['a_low'] * s >= margin * need),
                         ratio_at_estimate=None if not need else lane['a'] * s / need,
                         ratio_at_upper=None if not need else lane['a_high'] * s / need,
                         h_min=h_min(D, lane['a_low'] * s, grid), h_min_at_estimate=h_min(D, lane['a'] * s, grid))
                v['bits_over_target'] = v['h_min'] - target
                if not need:
                    why.append('no variance reaches the target at this duty cycle')
            if len(use) < 4:
                why.append(f'{len(use)} usable rings: with three there are as many equations as unknowns and nothing '
                           'tests the model; four are needed')
            if lane0_locked:
                why.append('ring 0 is locked to another ring')
            if lane['disagree']:
                why.append('the methods disagree beyond their errors: ' + ' and '.join(lane['disagree']))
            if lane['misfit']:
                why.append('own(span) is not c + a span + b span^2 for ' + ', '.join(lane['misfit']))
            if lane['over_upper']:
                why.append('above the model-free upper bound: ' + ', '.join(lane['over_upper']))
            if lane['sens_over']:
                why.append('the shared part\'s loading differs from the rate ratio by more than --sens-max for ring(s) '
                           + ', '.join(str(i) for i in lane['sens_over']))
            if lane['negative']:
                why.append('a negative own variance of ring 0 at ' + ', '.join(str(c) for c in lane['negative']) + ' clocks')
            if not (lane['fit_from'] <= s <= lane['fit_to']):
                why.append(f"the spacing is outside the fitted spans ({lane['fit_from']} to {lane['fit_to']} clocks)")
            if line_var > 0.1 * max(lane['a_low'] * s, 0.0):
                why.append(f'a spectral line in a pair\'s phase can add {line_var:.3g} periods^2, more than a tenth of '
                           'the credited variance')
            if cb is not None and cb['ok'] is False:
                why.append(f"the count and the lane bit of ring 0 do not fit each other (relation {cb['relation']:.2f}; "
                           'bits of these counts give 0.45 to 0.5)')
            # the assumptions that the data can test
            st, sf, ind = ass.get('stationarity'), ass.get('shared_factors'), ass.get('independence')
            ga = ass.get('gaussian', {}).get(str(int(s)))
            me = ass.get('memory')
            if me and me['ok'] is False:
                why.append(f"the constant term of own(span) is below the {me['reading']:g} of counting in steps of {unit} "
                           f"period(s) ({me['z_min']:+.1f} standard errors): part of the linear growth has a memory and is "
                           'not all fresh at a short spacing')
            if st and st['ok'] is False:
                why.append(f"a is not the same all through the capture (p: segments {st['p_segments']:.2g}, trend "
                           f"{st['p_trend']:.2g}" + (f", runs {st['p_runs']:.2g}" if st['p_runs'] is not None else '') + ')')
            if sf and sf['ok'] is False:
                why.append(f"clock and one shared factor do not fit the covariances of the rings (p {sf['two_factor']['p']:.2g}): "
                           'more shared factors than the model has')
            if ind and ind['ok'] is False:
                why.append('own noise is not independent: covariance left after the model in pair(s) '
                           + ', '.join('%d-%d' % tuple(p_) for p_ in lane['excess']))
            if ga is None or ga['ok'] is None:
                why.append('the increments at this spacing could not be tested for a Gaussian shape'
                           + (': ' + ga['why'] if ga and ga.get('why') else ''))
            elif ga['ok'] is False:
                bad = [k for k, r in ga['series'].items() if r.get('ok') is False]
                why.append('the own-difference increments at this spacing are not Gaussian: ' + '; '.join(
                    f"{k}: excess kurtosis {ga['series'][k]['excess_kurtosis']:+.3f} for {ga['series'][k]['expected']:+.3f} "
                    f"+-{ga['series'][k]['tolerance']:.3f}, beyond 3 sd {ga['series'][k]['beyond_3sd']:.4f}" for k in bad))
        if why:
            v['verdict'] = 'not established'
        elif v['margin_met']:
            v['verdict'] = 'pass'
        elif v['ratio_at_upper'] < 1:
            v['verdict'] = 'fail'
        else:
            v['verdict'] = 'not established'
            need, est = v['variance_needed'], lane['a'] * s
            if est > margin * need:
                k = (lane['t'] * lane['se_a'] * s / (est - margin * need)) ** 2
                why.append(f"too little data: the estimate is {v['ratio_at_estimate']:.2f} times the need, its lower bound "
                           f"{v['ratio']:.2f} times, the margin asks {margin:g} times; about "
                           f'{int(math.ceil(ntot * k * 1.2 / 1000) * 1000)} records would decide')
            elif v['ratio'] >= 1:
                why.append(f"the bound reaches the need ({v['ratio']:.2f} times) but not the margin of {margin:g} times, and "
                           f"the estimate ({v['ratio_at_estimate']:.2f} times) does not either: more data will not decide")
            else:
                why.append(f"the lower bound is {v['ratio']:.2f} times the need and the upper end {v['ratio_at_upper']:.2f} "
                           'times: more data would decide between fail and not established')
        cross = []
        if op_mask is not None and op_mask != data_mask:           # not the rings of normal operation
            cross.append(f'taken with rings {data_mask:#04x} running; normal operation runs {op_mask:#04x}. A bound is claimed '
                         'only from a capture of the operating rings')
        if unit == 1 and not unit_why:                           # direct mode, and known to be
            cross.append('taken in direct mode (one count is one period): the counter is clocked by the ring itself, outside '
                         'the flip-flop\'s guaranteed range. A bound is claimed only from a capture behind the divider')
        if cross:
            v['as_measured'], v['verdict'] = v['verdict'], 'cross-check only'
            why += cross
        v['why'] = why
        verdict[str(int(s))] = v
    if lane:
        out['lane0'] = lane
        # the other rings, by the same rule; information only
        others = []
        for i in use:
            fm = out['fit'].get(str(i), {})
            if i == 0 or not fm:
                continue
            row = dict(ring=i, a={m: fm[m]['a'] for m in fm}, a_low=min(fm[m]['a_low'] for m in fm), duty=duty_hi.get(i))
            row['spacings'] = {str(int(s)): dict(credited_variance=row['a_low'] * s,
                                                 h_min=None if i not in duty_hi else h_min(duty_hi[i], row['a_low'] * s, grid))
                               for s in spacings}
            others.append(row)
        out['other_rings'] = dict(note='the same bound for the other rings; information only, no verdict', rings=others)
    out['verdict'] = verdict
    return out

def own_and_bound(out, S0, Srep, Mb, block_run, rng, f, running, use, first, fit_ms, tau, tq, bcorr, enough, sens, conf,
                  notes, unit):
    """Own variances by every method at the fitted spans, their fits, the diagnostics and assumption
    checks that need the bootstrap, and ring 0's bound. Fills out['own'], ['fit'], ['shared'],
    ['sensitivity'], ['trios'] and three entries of out['assumptions']; returns the lane-0 summary or {}."""
    sel = [running.index(i) for i in use]
    fu, n_use = f[sel], len(use)
    S_pt, S_rp = S0[:, sel][:, :, sel], Srep[:, :, sel][:, :, :, sel]
    own_pt, ex_pt = own_all(S_pt, fu, use, sens)
    own_rp, ex_rp = own_all(S_rp, fu, use, sens)
    methods = [m for m in ('hat', 'ls', 'f1', 'f2') if m in own_pt]
    own_tab, fits = dict(m=fit_ms, clocks=[int(t) for t in tau], rings={}), {}
    for j, i in enumerate(use):
        own_tab['rings'][str(i)], fits[str(i)] = {}, {}
        k0 = first[sel[j]]
        for m in methods + ['upper']:
            y, Y = own_pt[m][:, j], own_rp[m][:, :, j]
            if not np.isfinite(y).all():
                continue
            se = Y.std(0) * bcorr
            own_tab['rings'][str(i)][m] = dict(value=y.tolist(), se=se.tolist(),
                                               negative=[int(tau[k]) for k in range(len(y)) if y[k] + 3 * se[k] < 0])
            if m != 'upper' and enough and len(fit_ms) - k0 >= MIN_SPANS:
                ft = fit_cab(tau[k0:], y[k0:], Y[:, k0:], tq, bcorr, 1 - conf)
                if ft:
                    fits[str(i)][m] = ft
    out['own'] = own_tab
    # the shared part of each ring (total less own, by ls) and how it grows
    sh = {}
    for j, i in enumerate(use):
        tot_, ow = S_pt[:, j, j], own_pt['ls'][:, j]
        pos = (tot_ - ow) > 0
        sh[str(i)] = dict(total=tot_.tolist(), shared=(tot_ - ow).tolist(),
                          shared_over_own=((tot_ - ow) / np.where(np.abs(ow) > 0, ow, np.nan)).tolist(),
                          loglog_slope=float(np.polyfit(np.log(tau[pos]), np.log((tot_ - ow)[pos]), 1)[0]) if pos.sum() >= 3 else None)
    out['shared'] = dict(note='total: the ring against the clock; shared = total - own (ls); own includes the resolution term',
                         rings=sh)
    lane = {}
    if 0 not in use:
        _strip(fits)
        out['fit'] = fits
        return lane
    i0, k0 = use.index(0), first[running.index(0)]
    # loadings of the shared part relative to ring 0, against the rate ratios
    sens_over, sens_rows = [], []
    with np.errstate(divide='ignore', invalid='ignore'):
        ld = ex_rp['load'] / ex_rp['load'][:, :, i0:i0 + 1]
        lp = ex_pt['load'] / ex_pt['load'][:, i0:i0 + 1]
        lse = np.where(np.isfinite(ld).all(0), np.std(ld, axis=0), np.nan) * bcorr
    good = np.isfinite(lse) & (lse > 0) & (lse < 0.2) & np.isfinite(lp)          # spans at which the loading is defined
    for j, i in enumerate(use):
        if i == 0:
            continue
        pooled = pse = None
        if good[:, j].any():                                     # the mean over those spans, with its bootstrap error
            pooled = float(lp[good[:, j], j].mean())
            pse = float(np.std(ld[:, good[:, j], j].mean(1)) * bcorr)
            if abs(pooled - 1) > sens + 3 * pse:
                sens_over.append(i)
        sens_rows.append(dict(ring=i, rate_ratio=float(fu[j] / fu[i0]), loading_over_rate=pooled, se=pse,
                              by_span=[float(lp[k, j]) if good[k, j] else None for k in range(len(fit_ms))]))
    out['sensitivity'] = dict(note='loading of the shared part relative to ring 0 (f1), over the ratio of the rates: 1 for '
                              'the clock and for equal sensitivity; a difference is the sensitivity difference times the '
                              'share of the shared part that is not the clock', rings=sens_rows)
    # The number of shared factors, and the independence of own noise: what one factor, and clock and one
    # factor, leave of the pairs' covariances. With the model right it is zero within errors. The reference
    # is the bootstrap: the replicates' residuals less the capture's.
    excess, ass = [], out['assumptions']
    ass['shared_factors'] = dict(ok=None, why='needs four rings', one_factor=None, two_factor=None)
    ass['independence'] = dict(ok=None, why='needs four rings', pairs=[])
    if enough and k0 < len(fit_ms):
        def gof(key, dof):
            rp, rr = ex_pt[key][k0:], ex_rp[key][:, k0:] - ex_pt[key][k0:]
            rse = rr.std(0) * bcorr
            wr = np.where(rse > 0, 1 / np.where(rse > 0, rse, 1.0), 0.0)
            T, Tb = ((rp * wr) ** 2).sum(), ((rr * wr) ** 2).sum((1, 2))
            return dict(chi2=float(T), reference_mean=float(Tb.mean()), p=tail_p(T, Tb), free_per_span=dof), rp, rr, wr
        npair = n_use * (n_use - 1) // 2
        if n_use >= 4:
            one, _, _, _ = gof('resid1', npair - n_use)
            two, rp, rr, wr = gof('resid2', npair - n_use - 1)
            ass['shared_factors'] = dict(
                ok=bool(two['p'] >= P_MISFIT), one_factor=one, two_factor=two,
                statistic='sum over spans and pairs of (covariance left by the model / its standard error)^2 against its '
                          f'bootstrap reference; a failure is p < {P_MISFIT} for clock and one factor. A small p for one '
                          'factor alone says that the second is needed, and is no failure')
            T, Tb = (rp * wr).sum(0), (rr * wr).sum(1)
            zp = T / np.where(Tb.std(0) > 0, Tb.std(0) * bcorr, np.nan)
            o2 = own_pt['f2'][k0:] / fu ** 2                     # own variances by f2, clock periods^2
            rows = []
            for k, (a, b) in enumerate(zip(*np.triu_indices(n_use, 1))):
                den = o2[:, a] * o2[:, b]
                rows.append(dict(pair=[use[a], use[b]], z=None if not np.isfinite(zp[k]) else float(zp[k]),
                                 correlation=[float(rp[i, k] / math.sqrt(den[i])) if den[i] > 0 else None for i in range(len(den))],
                                 flagged=bool(np.isfinite(zp[k]) and abs(zp[k]) > Z_EXCESS)))
                if rows[-1]['flagged']:
                    excess.append(rows[-1]['pair'])
            ass['independence'] = dict(
                ok=not excess, clocks=[int(t) for t in tau[k0:]], pairs=rows,
                z_max=float(np.nanmax(np.abs(zp))) if np.isfinite(zp).any() else None,
                statistic='per pair: the covariance that clock and one factor leave, as a correlation of the own parts of the '
                          f'two rings at each span, and summed over the spans in standard errors (z); a failure is |z| > {Z_EXCESS:g}. '
                          'With four rings only one combination of the pairs is free')
    # ring 0 with every pair of partners, fixed coefficients
    if enough and len(fit_ms) - k0 >= MIN_SPANS:
        tp, tr, rows = trio_hats(S_pt, fu, use), trio_hats(S_rp, fu, use), []
        for key in tp:
            ft = fit_cab(tau[k0:], tp[key][k0:], tr[key][:, k0:], tq, bcorr)
            if ft:
                rows.append(dict(partners=list(key), a=ft['a'], se_a=ft['se_a'], _A=ft['_A']))
        if len(rows) >= 2:
            A_ = np.stack([r['_A'] for r in rows], 1)
            dse = (A_ - A_.mean(1, keepdims=True)).std(0) * bcorr
            am = np.array([r['a'] for r in rows])
            for r, z_ in zip(rows, (am - am.mean()) / np.where(dse > 0, dse, np.nan)):
                r['z_from_mean'] = None if not np.isfinite(z_) else float(z_)
        for r in rows:
            del r['_A']
        out['trios'] = dict(note='a of ring 0 from each pair of partners, fixed coefficients; z_from_mean: against the mean '
                            'of all, in standard errors. Partners of another ring type differ by their sensitivity',
                            rows=rows)
    f0 = fits.get('0')
    if enough and not f0:
        notes.append('no fit for ring 0: fewer than %d spans beyond its first usable one' % MIN_SPANS)
    if enough and f0:
        # stationarity, on the linear estimate (hat, else ls): its value block by block
        lin = 'hat' if 'hat' in f0 else 'ls'
        gb = Mb[:, k0:][:, :, sel][:, :, :, sel] / (fu[:, None] * fu[None, :])
        if lin == 'hat':
            i4, i5 = use.index(4), use.index(5)
            ob = (gb[..., i0, i0] - gb[..., i0, i4] - gb[..., i0, i5] + gb[..., i4, i5]) * fu[i0] ** 2
        else:
            ob = ls_fixed(gb)[0][..., i0] * fu[i0] ** 2
        ass['stationarity'] = dict(stationarity(ob[:, f0[lin]['_ok']] @ f0[lin]['_K'], block_run, rng), method=lin)
        # White FM leaves the constant term of own(span) at the reading error, unit^2 / 4 or more. Noise
        # with a memory shorter than the fitted spans grows linearly there too but from a negative intercept,
        # and is not all fresh at a spacing near its memory: a constant below unit^2 / 4 gives it away.
        zc = [(f0[m]['c'] - reading(unit)) / f0[m]['se_c'] for m in f0 if f0[m]['se_c'] > 0]
        ass['memory'] = dict(ok=bool(min(zc) >= -Z_MEMORY), reading=reading(unit), c={m: f0[m]['c'] for m in f0},
                             se={m: f0[m]['se_c'] for m in f0}, z_min=float(min(zc)),
                             statistic=f'the constant term c of own(span) against the {reading(unit):g} periods^2 of counting '
                                       f'in steps of {unit} period(s), in standard errors, the lowest of the methods; a failure '
                                       f'is below -{Z_MEMORY:g}')
        bound_methods = [m for m in methods if m in f0]
        primary = next(m for m in ('hat', 'f2', 'f1', 'ls') if m in f0)
        # agreement: hat against f2 where there is a hat, else f1 against f2 (the others are listed)
        core = [m for m in (('hat', 'f2') if 'hat' in f0 else ('f1', 'f2')) if m in f0]
        agree, disagree = [], []
        for x in range(len(bound_methods)):
            for y_ in range(x + 1, len(bound_methods)):
                m1, m2 = bound_methods[x], bound_methods[y_]
                d = f0[m1]['a'] - f0[m2]['a']
                sd = float((f0[m1]['_A'] - f0[m2]['_A']).std() * bcorr)
                flag = bool(abs(d) > 3.5 * sd and abs(d) > 2 * max(f0[m1]['se_a'], f0[m2]['se_a']))
                counts = m1 in core and m2 in core
                agree.append(dict(methods=[m1, m2], difference=d, se=sd, flagged=flag, counts=bool(counts)))
                if flag and counts:
                    disagree = [m1, m2]
        # the model-free upper bound of a: own(tau) >= a tau at every span
        up_hi = own_pt['upper'][:, i0] + tq * own_rp['upper'][:, :, i0].std(0) * bcorr
        a_upper = float(np.min(up_hi[k0:] / tau[k0:]))
        by_range = []                                            # a over shorter ranges of spans (primary method)
        for top in range(k0 + MIN_SPANS, len(fit_ms) + 1):
            ft = fit_cab(tau[k0:top], own_pt[primary][k0:top, i0], own_rp[primary][:, k0:top, i0], tq, bcorr)
            if ft:
                by_range.append(dict(top_clocks=int(tau[top - 1]), a=ft['a'], se_a=ft['se_a']))
        lane = dict(methods=bound_methods, primary=primary, a=f0[primary]['a'], se_a=f0[primary]['se_a'],
                    a_low=min(f0[m]['a_low'] for m in bound_methods), a_high=max(f0[m]['a_high'] for m in bound_methods),
                    a_upper_model_free=a_upper, conf=conf, t=tq, fit_from=int(tau[k0]), fit_to=int(tau[-1]),
                    agreement=agree, disagree=disagree,
                    over_upper=[m for m in bound_methods if f0[m]['a'] - 3 * f0[m]['se_a'] > a_upper],
                    misfit=[m for m in bound_methods if f0[m]['p_fit'] < P_MISFIT], sens_over=sens_over, excess=excess,
                    excess_z_max=ass['independence'].get('z_max'),
                    negative=sorted(set(c for m in bound_methods for c in own_tab['rings']['0'][m]['negative']
                                        if c >= tau[k0])), a_by_range=by_range)
    _strip(fits)
    out['fit'] = fits
    return lane

def _strip(fits):
    for fm in fits.values():
        for ft in fm.values():
            for k in ('_A', '_K', '_ok'):
                ft.pop(k, None)

# ---- text ----
def text(res):
    L = []
    P = L.append
    if 'error' in res:
        return '\n'.join(['rosc_own: ' + res['error']] + [f"  rejected at {r['start']} ({r['records']} records): {r['why']}"
                                                          for r in res.get('rejected', [])])
    i = res['input']
    P(f"capture {i['file']}: {i['records']} records of {i['n0']} clocks in {len(i['runs'])} run(s), "
      f"rings {i['running']} run, {i['blocks']} blocks of {i['block_records']}; {i['records_usable']} usable records (in the "
      f"blocks of the fit; {i['records_in_kept_runs']} in the runs kept), a bound needs {i['min_records']}"
      + (' (MINIMUM LOWERED FOR A TEST)' if i['min_records_lowered'] else ''))
    P(f"count unit {i['count_unit']}" + ('' if i['count_unit_known'] else ' (NOT ESTABLISHED: not in the sidecar, or not the sidecar\'s)')
      + f": {i['counting']}; rates and variances below are in ring periods")
    for r in i['rejected']:
        P(f"  rejected at {r['start']} ({r['records']} records): {r['why']}")
    P('ring stages  periods/clock      +-        MHz   drift   step   ones    count/bit')
    for r in res['rings']:
        cb = r['count_bit']
        P(f"{r['ring']:>4} {str(r['stages']):>6} {r['rate']:14.9f} {r['rate_se']:9.2e} {r['hz'] / 1e6:9.3f} "
          f"{r['drift']:+8.1e} {r['step_rms']:6.2f} "
          + (f"{r['ones']:6.4f}" if r['ones'] is not None else '     -')
          + (f"   relation {cb['relation']:.2f} (slope {cb['slope']:+.3f}, square {cb['square']:+.3f}) latency {cb['latency']:.3f} "
             f"{ {True: 'ok', False: 'INCONSISTENT', None: 'not decided'}[cb['ok']]}" if cb else ''))
    for p in res.get('lock', {}).get('pairs', []):
        if p['locked']:
            P(f"LOCK rings {p['pair'][0]} and {p['pair'][1]}: {p['why']}")
    if 'own' in res and '0' in res['own']['rings']:
        o = res['own']
        ms = [m for m in ('hat', 'ls', 'f1', 'f2', 'upper') if m in o['rings']['0']]
        P('ring 0, own variance (periods^2) by span:')
        P('  clocks ' + ''.join(f'{m:>20}' for m in ms) + '   shared/own')
        for k, c in enumerate(o['clocks']):
            P(f'{c:>8} ' + ''.join(f"{o['rings']['0'][m]['value'][k]:>11.4f} +-{o['rings']['0'][m]['se'][k]:<7.4f}" for m in ms)
              + f"   {res['shared']['rings']['0']['shared_over_own'][k]:9.1f}")
    if 'fit' in res:
        P('own(span) = c + a span + b span^2:')
        P('ring method        c            a per clock      +-          b          fit p')
        for r, fm in res['fit'].items():
            for m, ft in fm.items():
                P(f"{r:>4} {m:>6} {ft['c']:10.4f} {ft['a']:16.4e} {ft['se_a']:10.2e} {ft['b']:12.3e} {ft['p_fit']:8.3f}")
    if 'sensitivity' in res:
        for r in res['sensitivity']['rings']:
            if r['loading_over_rate'] is not None:
                P(f"ring {r['ring']}: rate ratio to ring 0 {r['rate_ratio']:.6f}, shared loading over it "
                  f"{r['loading_over_rate']:.4f} +-{r['se']:.4f}")
    for l in res.get('lines', {}).get('found', []):
        P(f"line in {l['series']}: {l['hz']:.6g} Hz, amplitude {l['amplitude']:.3g} {l['unit']}, "
          f"{l['over_background']:.1f} x background")
    if 'lane0' in res:
        l = res['lane0']
        P(f"lane 0: a = {l['a']:.4e} +-{l['se_a']:.2e} per clock ({l['primary']}); lower {int(l['conf'] * 100)} % bound over "
          f"{', '.join(l['methods'])}: {l['a_low']:.4e}; model-free upper bound {l['a_upper_model_free']:.4e}")
        for a in l['agreement']:
            if a['flagged']:
                P(f"  {a['methods'][0]} and {a['methods'][1]} differ by {a['difference']:.3e} +-{a['se']:.1e}")
    ass = res.get('assumptions', {})
    st, sf, ind = ass.get('stationarity'), ass.get('shared_factors'), ass.get('independence')
    word = {True: 'ok', False: 'FAILED', None: 'not tested'}
    if st:
        P(f"stationarity ({st['method']}, {st['blocks']} blocks): {word[st['ok']]}; p of the scatter between 8 segments "
          f"{st['p_segments']:.3g}, of the trend {st['p_trend']:.3g}" + (f", between runs {st['p_runs']:.3g}" if st['p_runs'] is not None else '')
          + '; a by segment: ' + ' '.join(f"{g['a']:.2e}" for g in st['segments']))
    if sf:
        P(f"shared factors: {word[sf['ok']]}" + (f"; clock and one factor p {sf['two_factor']['p']:.3g}, one factor alone p "
                                               f"{sf['one_factor']['p']:.3g}" if sf.get('two_factor') else f" ({sf.get('why')})"))
    if ind:
        P(f"independence of own noise: {word[ind['ok']]}" + (f"; largest |z| of a pair's left-over covariance {ind['z_max']:.2f}"
                                                            if ind.get('z_max') is not None else f" ({ind.get('why')})")
          + ''.join(f"; pair {r['pair'][0]}-{r['pair'][1]} z {r['z']:+.1f}" for r in ind.get('pairs', []) if r['flagged']))
    if ass.get('memory'):
        P(f"constant term against the {ass['memory']['reading']:g} of counting: {word[ass['memory']['ok']]}; lowest z "
          f"{ass['memory']['z_min']:+.2f}")
    if 'pair' in res:
        pr = res['pair']
        P(f"pair with {pr['other']}: {word[pr['ok']]}" + ''.join('; ' + w for w in pr['why']))
        for r in pr['rings']:
            P(f"  ring {r['ring']}: rate ratio {r['ratio']:.7f} +-{r['se']:.1e} (counts {r['counts_ratio']:.6f}), off 1 by "
              f"{r['off']:+.2e} (allowed {r['allowed']:.1e}), from the median {r['off_from_median']:+.2e} (allowed "
              f"{r['allowed_from_median']:.1e}), drift {r['drift']:+.1e} and {r['drift_other']:+.1e}"
              + ('  FLAGGED' if r['flagged'] else ''))
    for sp, ga in ass.get('gaussian', {}).items():
        P(f"Gaussian increments at {sp} clocks ({ga['increments']} increments): {word[ga['ok']]}"
          + ''.join(f"; {k}: excess kurtosis {r['excess_kurtosis']:+.3f} (expected {r['expected']:+.3f} +-{r['tolerance']:.3f}), "
                    f"beyond 3 sd {r['beyond_3sd']:.4f}" for k, r in ga['series'].items() if 'excess_kurtosis' in r)
          + (f" ({ga['why']})" if ga.get('why') else ''))
    i = res['input']
    if 'bits' in res:
        bt = res['bits']
        P(f"count rates against sampled bits ({bt['analysis']}): {word[bt['ok']]}; {bt['checked']} of the {bt.get('required', 0)} "
          'mapped ring(s) that run were checked' + ''.join('; ' + w for w in bt['why']))
        for r in bt['rings']:
            P(f"  ring {r['ring']} (burst lane {r['lane']}): " + (f"rate {r['rate']:.6f}, fraction {r['frac']:.5f}, F {r['F']:.5f} "
              f"+-{r['F_uncertainty']:.5f}, distance {r['distance']:.5f}, tolerance {r['tolerance']:.5f}"
              + ('' if r['ok'] else '  FLAGGED') if 'rate' in r else ('MISSING: ' if r['ok'] is False else 'not counted: ')
              + r.get('why', '')))
        if bt['checked']:
            P(f"  a wrong ratio of the divider would put the fraction anywhere: {bt['checked']} ring(s) within their tolerances "
              f"t by accident has a chance of about the product of 4 t = {bt['accidental']:.1e}")
        P('  this compares the folded frequency only (the fraction of the periods per clock, against F or 1 - F): a count wrong '
          'by a whole number of periods per clock passes it. --pair is needed as well; neither check alone qualifies the '
          'instrument')
    if i.get('operating_mask') is not None:
        P(f"rings in this capture {i['ring_mask']:#04x}, in normal operation {i['operating_mask']:#04x}; instrument health {i['health']}")
    else:
        P(f"rings in this capture {i['ring_mask']:#04x}, in normal operation: not known; instrument health {i['health']}")
    if i['count_unit'] == 1 and i['count_unit_known']:
        P('direct mode: the counter is clocked by the ring itself, outside its flip-flop\'s guaranteed range; every verdict of '
          'this capture is a cross-check only')
    for s, v in res['verdict'].items():
        line = (f"spacing {s:>6}: {v['verdict'].upper()}" + (f" (as measured: {v['as_measured']})" if 'as_measured' in v else '')
                + (f" [{v['min_records_lowered']}]" if 'min_records_lowered' in v else ''))
        if v.get('ratio') is not None:
            line += (f"; credited {v['credited_variance']:.4f} periods^2 = {v['ratio']:.2f} x the {v['variance_needed']:.4f} "
                     f"needed at duty {v['duty']:.4f} (margin asked: {v['margin_required']:g} x, "
                     f"{'met' if v['margin_met'] else 'not met'}); {v['h_min']:.4f} bit")
        P(line)
        for w in v['why']:
            P('    ' + w)
    if ass.get('note'):
        P(ass['note'])
    for n in res.get('notes', []):
        P('note: ' + n)
    return '\n'.join(L)

def main():
    ap = argparse.ArgumentParser(description='a ring oscillator\'s own phase noise from the meter\'s counts')
    ap.add_argument('capture', help='NAME.bin of rosc_count.py with its NAME.json, or an .npz')
    ap.add_argument('--text', action='store_true', help='a readable summary instead of JSON')
    ap.add_argument('--out', help='also write the JSON here')
    ap.add_argument('--spacing', type=int, nargs='*', default=[], help='clocks between kept samples, besides 4096 and 16384')
    ap.add_argument('--operating-mask', type=lambda v: int(v, 0), default=None,
                    help='the rings that run in normal operation (bit r: ring r), in place of the sidecar\'s strap_mask')
    ap.add_argument('--count-unit', type=int, default=None,
                    help='ring periods per count for input that does not say (.npz: default 1); a records file must say in '
                         'its sidecar, and without that this only sets what the numbers are in')
    ap.add_argument('--pair', metavar='OTHER', help='a capture of the same rings and spacing in the other counting mode: '
                    'compare the rates of the two')
    ap.add_argument('--bits', metavar='ANALYSIS.json', help='getnoise-analysis.json of burst captures of sampled bits at a '
                    'sampling period of one clock: compare each ring\'s count rate with its sampled frequency. Every mapped '
                    'ring that runs must have a usable fit and agree. Only the folded frequency is compared (the fraction of '
                    'the periods per clock, against F or 1 - F): a count wrong by a whole number of periods per clock passes, '
                    'so --pair is needed as well; neither check alone qualifies the instrument')
    ap.add_argument('--bits-map', default=None, metavar='LANE:RING,...',
                    help='the ring of each burst lane (0:0,1:1,2:4,3:5, the reference-bit bursts of rosc_count.py; ordinary '
                         'lane-bit bursts are 0:0,1:1,2:2,3:3)')
    ap.add_argument('--margin', type=float, default=2.0, help='a pass needs this many times the variance that the target needs')
    ap.add_argument('--min-records', type=int, default=None,
                    help=f'for tests only: the least usable records of a capture that may pass, in place of {MIN_RECORDS}; its '
                         'use is written into the output, and it is not for a capture that is to carry a bound')
    ap.add_argument('--target', type=float, default=0.75, help='min-entropy per bit that sets the variance needed')
    ap.add_argument('--blocks', type=int, default=64)
    ap.add_argument('--boot', type=int, default=400)
    ap.add_argument('--conf', type=float, default=0.99)
    ap.add_argument('--sens-max', type=float, default=0.25)
    ap.add_argument('--seed', type=int, default=1, help='of the bootstrap and the permutations')
    a = ap.parse_args()
    if a.blocks < MIN_BLOCKS:
        ap.error(f'--blocks must be at least {MIN_BLOCKS}')
    bits_map = None
    if a.bits_map:
        try:
            bits_map = {int(x.split(':')[0]): int(x.split(':')[1]) for x in a.bits_map.split(',')}
            assert all(0 <= k < 4 and 0 <= v < NR for k, v in bits_map.items())
        except (ValueError, IndexError, AssertionError):
            ap.error('--bits-map is LANE:RING,... with lanes 0 to 3 and rings 0 to 5')
    try:                                                         # exit status 2: nothing could be analysed
        cap = load_capture(a.capture)
        pair = load_capture(a.pair) if a.pair else None
        bits = json.load(open(a.bits)) if a.bits else None
        if bits is not None and not isinstance(bits, dict):
            raise ValueError(f'{a.bits}: not an analysis of getnoise_analyze.py')
    except SystemExit as e:
        print(f'rosc_own: {e}', file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError, IndexError) as e:
        print(f'rosc_own: cannot read the input: {type(e).__name__}: {e}', file=sys.stderr)
        return 2
    res = analyze(cap, spacings=tuple(dict.fromkeys(list(SPACINGS) + a.spacing)), blocks=a.blocks,
                  boot=a.boot, conf=a.conf, target=a.target, margin=a.margin, sens=a.sens_max,
                  operating_mask=a.operating_mask, count_unit=a.count_unit, pair=pair, bits=bits, min_records=a.min_records,
                  bits_map=bits_map, bits_name=a.bits, seed=a.seed)
    js = json.dumps(res, indent=1)
    if a.out:
        open(a.out, 'w').write(js + '\n')
    print(text(res) if a.text else js)
    return 2 if 'error' in res else 0

if __name__ == '__main__':
    sys.exit(main())
