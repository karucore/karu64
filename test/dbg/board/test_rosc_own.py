#!/usr/bin/env python3
"""Self-test of rosc_own.py on generated captures; needs no board.

    test_rosc_own.py              the self-test (about two minutes on one
                                  core)
    test_rosc_own.py --producer DIR
                                  the same, and it is an error if DIR, the
                                  output directory of test_rosc_count.py, has
                                  no capture written by rosc_count.py (without
                                  the option _build/rosc-count/test is used
                                  when it is there, and a note says when not)
    test_rosc_own.py --coverage [--unit 2]
                                  the coverage study (about 8 CPU hours at
                                  unit 2; --trials N, --jobs N, --only NAME
                                  ...); results in _build/rosc-own/
                                  coverage-unit<unit>.json. --unit 1 (direct
                                  mode) runs the smaller set UNIT1_SET
    test_rosc_own.py --need [--unit 2]
                                  records needed for a_low = 0.8 a

The generator below is the physical model of the six rings written out
forwards, with nothing of the estimator in it: for every record it builds
each ring's phase from the deterministic ramp, the ring's own white FM (a
random walk), its own flicker FM (1/f frequency noise from a spectrum,
integrated), the clock's time error (a random walk plus a bounded jitter)
times the ring's rate, a supply term (white, flicker or a line) times the
ring's rate and its sensitivity, and a drift. The counter steps once in
count_unit periods (2 behind the divider, the default everywhere here; 1 in
direct mode) and still shows the old count for a latency after a step: the
count is floor((phase - latency) / count_unit). The lane bit says whether
the phase fraction is below the duty cycle. The truth of a is the variance
rate given to the own random walk and nothing else. For the controls the
generator can also break the model: noise that two rings share and no other,
a further shared factor with its own sensitivities, a ring locked to
another, a telegraph component in ring 0's rate, an a that changes during
the capture, a counter that loses a steady share of the periods, and counts
made with another unit than the sidecar says.

A. The pieces: the Student quantile, the statistic for white FM, a reading
   error, counting in steps of one and two periods and flicker FM, the need
   of entropy_claim.p_max, every method on exact matrices, the line search.
B. Input: NAME.bin with NAME.json in the layout of rosc_count.py, the count
   unit, wrapping totals, .npz, N0 = 65536, runs split by a broken sequence,
   a jump of the counts, a loss flag and a missing valid bit, rings standing
   still; and the files that rosc_count.py itself wrote in its offline test.
C. Recovery of a over the expected ranges, as (estimate - truth) / error,
   behind the divider and (three rows) in direct mode.
D. Negative controls: no white noise in ring 0, flicker only, locked rings,
   a strong shared line, own noise that is not independent, three rings,
   two rings, too little data, lane bits that do not fit the counts, the
   count against the bit at latencies all round a period.
E. Verdicts: pass, fail, not established, the margin, the tables, the text.
F. Instrument health (bad_counts) and the rings of normal operation: a
   capture with another ring mask is a cross-check and never a pass; four
   dissimilar rings as the operating set.
G. The assumptions as checks: stationarity, Gaussian increments, the number
   of shared factors, independence, memory; each failed by a capture made
   to break it.
H. The count unit: a sidecar without it, direct mode as a cross-check, the
   pair of counting modes (--pair) and the sampled bits (--bits, on an
   analysis that getnoise_analyze.py itself wrote), each on right counts and
   on counts as if divided by 3 and as if not divided; --bits for every
   mapped ring that runs.
I. The least usable records of a capture that may pass: MIN_RECORDS counted
   in the blocks of the fit, after flagged runs are set aside and without the
   ends of runs too short for another block; the records of the runs kept
   reported beside them; a lowered minimum said in the result and the text.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, glob, hashlib, json, math, os, shutil, sys, time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rosc_own as ro                                            # noqa: E402

# The checks of the analysis itself run on generated captures far smaller than a capture that is to carry
# a bound (ro.MIN_RECORDS usable records), so they lower that minimum to LOW, which the result then says.
# Section I checks the minimum at its own value; the studies measure the statistics without it.
LOW = 1000
def analyze(cap, **kw):
    kw.setdefault('min_records', LOW)
    return ro.analyze(cap, **kw)

ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
OUT = os.path.join(ROOT, '_build', 'rosc-own')

F_NOM = (9.0371, 6.0113, 4.3127, 3.4219, 9.2203, 8.8459)         # periods per clock; references within 3 % of ring 0
STAGES = (3, 5, 7, 9, 3, 3)

# ---- generator ----
def flicker_walk(n, rng, osr=8):
    """Phase of unit-scale flicker FM at n records: 1/f frequency noise at osr steps per record,
    summed. Also returns the expected A(m) (rosc_own's statistic, m in records) of the series."""
    nf = 1 << int(math.ceil(math.log2(2 * n * osr)))
    k = np.arange(1, nf // 2 + 1)
    X = np.zeros(nf // 2 + 1, dtype=complex)
    X[1:] = (rng.standard_normal(nf // 2) + 1j * rng.standard_normal(nf // 2)) / np.sqrt(k)
    p = np.fft.irfft(X, nf)[:n * osr] * nf
    ph = np.concatenate([[0.0], np.cumsum(p)])[::osr][:n]
    def expect(m):
        M = m * osr
        w = 2 * np.pi * k / nf
        H = (np.sin(M * w / 2) / np.sin(w / 2)) ** 2 * 4 * np.sin(M * w / 2) ** 2
        return 0.5 * 2 * (2.0 / k * H).sum()
    return ph, expect

def flicker(n, n0, b, rng):
    """Flicker FM phase with A(tau) = b tau^2 (matched at 64 records), and its exact A(m)."""
    if not b:
        return np.zeros(n), (lambda m: 0.0)
    ph, ex = flicker_walk(n, rng)
    g = math.sqrt(b * (64 * n0) ** 2 / ex(64))
    return ph * g, (lambda m: ex(m) * g * g)

DEFAULT = dict(
    n0=1024, f=F_NOM,
    a0=5e-5,                                     # ring 0's own white FM, periods^2 per clock: the truth of a
    a_ref=5e-5,                                  # the other rings' own white FM and the scale of everything else,
                                                 # as ring 0 would have it: ring r gets a_ref (f_r / f_0)^2 own_scale[r]
    own_scale=(1, 1, 1, 1, 1, 1), white_others=1.0,
    own_flicker=0.0,                             # own flicker FM of every ring as a corner: the clocks at which
                                                 # b tau^2 = a_ref tau (0: none)
    shared=20.0,                                 # shared white FM over a_ref, in ring 0's phase
    supply_share=0.5,                            # of the shared white FM: this much supply, the rest clock
    clock_jitter=0.01,                           # bounded jitter of the sampling edge, clock periods rms
    supply_flicker=0.0,                          # supply flicker FM as a corner against the shared white part (0: none)
    line=None,                                   # (Hz, amplitude in periods of ring 0) on the supply term
    sens=(1, 1, 1, 1, 1, 1),                     # supply sensitivities
    duty=(0.5, 0.5, 0.5, 0.5), latency=(0.05, 0.08, 0.03, 0.06, 0.05, 0.04), latency_jitter=0.01,
    drift=1e-7,                                  # relative change of ring 0's rate over the capture (others 30 % more each)
    count_unit=2,                                # ring periods per count: 2 behind the divider, 1 in direct mode
    miscount=None,                               # (ring, factor): that ring's counter sees only this share of the periods
    rings=(1, 1, 1, 1, 1, 1), lock=None,         # lock: (i, j): ring j follows ring i
    extra=(),                                    # ((weights of the six rings, rate), ...): a further shared white FM with
                                                 # its own sensitivities, `rate` periods^2 per clock in ring 0's phase at
                                                 # weight 1: a third shared factor
    telegraph=None,                              # (dwell in clocks, rate): ring 0's rate toggles between two values at
                                                 # random times; over spans far above the dwell that is a diffusion of
                                                 # `rate` periods^2 per clock, below it a ramp that the past gives away
    a_step=None,                                 # (fraction of the capture, factor): ring 0's a is multiplied from there on
    private=(),                                  # ((i, j, ..., rate), ...): white FM shared by the rings listed and no
                                                 # other, periods^2 per clock in ring 0's phase: a pair breaks the
                                                 # independence of own noise, a larger group is one more shared factor
    clock_hz=75e6,
)
SENS_UNEQUAL = (1.0, 1.021, 1.034, 1.043, 1.004, 0.997)          # a few percent between types, less within one

def synth(n, rng, **kw):
    """One contiguous capture of n records. Returns totals [n, 6] int64 (not wrapped), bits [n] uint8, truth."""
    p = dict(DEFAULT, **kw)
    n0, f = p['n0'], np.array(p['f'], dtype=float)
    k = np.arange(n)
    f0 = f[0]
    # shared: the clock's time error J and the supply term S, both in clock periods
    w_sh = p['shared'] * p['a_ref'] / f0 ** 2                     # clock periods^2 per clock
    J = np.cumsum(rng.standard_normal(n) * math.sqrt(w_sh * (1 - p['supply_share']) * n0)) \
        + rng.standard_normal(n) * p['clock_jitter']
    S = np.cumsum(rng.standard_normal(n) * math.sqrt(w_sh * p['supply_share'] * n0))
    if p['supply_flicker']:
        S = S + flicker(n, n0, w_sh / p['supply_flicker'], rng)[0]
    if p['line']:
        hz, amp = p['line']
        S = S + amp / f0 * np.sin(2 * np.pi * hz / p['clock_hz'] * n0 * k + rng.uniform(0, 2 * np.pi))
    tot = np.zeros((n, 6), dtype=np.int64)
    bits = np.zeros(n, dtype=np.uint8)
    truth = dict(a=[], b=[], f=f.tolist())
    y_all = []
    private = {}
    for *group, rate in p['private']:                            # white FM that the rings listed share and no other
        c = np.cumsum(rng.standard_normal(n) * math.sqrt(rate / f0 ** 2 * n0))    # clock periods
        for r in group:
            private[r] = private.get(r, 0.0) + f[r] * c
    for weights, rate in p['extra']:                             # one more shared white FM, ring r seeing weights[r] of it
        c = np.cumsum(rng.standard_normal(n) * math.sqrt(rate / f0 ** 2 * n0))
        for r in range(6):
            private[r] = private.get(r, 0.0) + f[r] * weights[r] * c
    for r in range(6):
        scale = (f[r] / f0) ** 2 * p['own_scale'][r]
        a_r = (p['a0'] if r == 0 else p['a_ref'] * scale * p['white_others'])
        b_r = p['a_ref'] * scale / p['own_flicker'] if p['own_flicker'] else 0.0
        sd = np.full(n, math.sqrt(a_r * n0))
        if r == 0 and p['a_step']:
            sd[int(p['a_step'][0] * n):] *= math.sqrt(p['a_step'][1])
        W = np.cumsum(rng.standard_normal(n) * sd)
        if r == 0 and p['telegraph']:
            dwell, rate = p['telegraph']
            t = np.cumsum(rng.exponential(dwell, int(n * n0 / dwell * 1.2) + 64))   # the switching times, in clocks
            t = np.concatenate([[0.0], t[t < n * n0], [float(n * n0)]])
            lvl = math.sqrt(rate / dwell) * (1 - 2 * (np.arange(len(t) - 1) % 2)) * (1 if rng.random() < 0.5 else -1)
            W = W + np.interp(k * float(n0), t, np.concatenate([[0.0], np.cumsum(lvl * np.diff(t))]))
        Fl = flicker(n, n0, b_r, rng)[0]
        dr = p['drift'] * (1 + 0.3 * r) * f[r] * n0 / max(n, 1) * 0.5 * k.astype(float) ** 2
        y_all.append(rng.uniform(0, 1) + f[r] * (J + p['sens'][r] * S) + W + Fl + dr + private.get(r, 0.0))  # all but the ramp
        truth['a'].append(a_r)
        truth['b'].append(b_r)
    if p['lock']:
        i, j = p['lock']
        e = np.zeros(n)                                          # bounded phase difference: AR(1), 0.05 period rms
        x = rng.standard_normal(n) * 0.05 * math.sqrt(1 - 0.9 ** 2)
        for t in range(1, n):
            e[t] = 0.9 * e[t - 1] + x[t]
        y_all[j] = y_all[i] + 0.3 + e
        f = f.copy(); f[j] = f[i]
        truth['f'] = f.tolist()
    unit = int(p['count_unit'])
    for r in range(6):
        if not p['rings'][r]:
            continue
        inc = f[r] * n0
        whole = int(math.floor(inc))
        y = y_all[r] + (inc - whole) * k
        # The counter steps once in `unit` periods, and for `lat` periods after a step the old count is
        # still read: the count is floor((phase - lat) / unit), one count being `unit` periods.
        lat = np.maximum(p['latency'][r] + rng.standard_normal(n) * p['latency_jitter'], 0.0)
        periods = whole * k.astype(np.int64) + np.floor(y - lat).astype(np.int64)
        if p['miscount'] and p['miscount'][0] == r:              # a counter that loses a steady share of the periods
            periods = np.floor(periods * p['miscount'][1]).astype(np.int64)
        tot[:, r] = periods // unit
        if r < 4:
            bits |= ((y - np.floor(y)) < p['duty'][r]).astype(np.uint8) << r
    tot -= tot[0]
    truth['count_unit'] = unit
    return tot, bits, truth

def capture(n, rng, op_mask='same', **kw):
    """A generated capture as rosc_own.load_capture would return it. op_mask: the rings of normal
    operation; 'same': the rings of this capture."""
    tot, bits, truth = synth(n, rng, **kw)
    p = dict(DEFAULT, **kw)
    mask = sum(1 << r for r in range(6) if p['rings'][r])
    return dict(tot=tot, wrapped=False, nominal=None, lanes=bits, n0=p['n0'], runs=[(0, n)], rejected=[],
                clock_hz=p['clock_hz'], stages=list(STAGES), ring_mask=None, op_mask=mask if op_mask == 'same' else op_mask,
                health=None, count_unit=int(p['count_unit']), time=None, file='generated'), truth

def write_bin(path, tot, bits, n0, runs, loss_from=None, rings=63, strap=None, bad_counts=None, bad_rings=None, bad_seq=None,
              period=256, start_count=None, drop=(), sidecar=None, count_unit=2, when='2026-11-21T09:00:00+00:00'):
    """The meter's records as NAME.bin and a sidecar NAME.json with the keys of rosc_count.py (format
    karu64-rosc-count-1). tot: the totals in counts; count_unit: the ring periods in one count, as the
    sidecar says it. runs: [(start, n)] into tot (each restarts the sequence). strap: the rings of
    normal operation (default: those of the capture); drop: sidecar keys to leave out."""
    words = np.zeros((len(tot), 2), dtype=np.uint64)
    base = np.array(start_count if start_count is not None else [0] * 6, dtype=np.int64)
    t = ((tot + base) % ro.MOD).astype(np.uint64)
    seq = np.zeros(len(tot), dtype=np.uint64)
    for a, m in runs:
        seq[a:a + m] = np.arange(m) % 4
    if bad_seq is not None:
        seq[bad_seq:] = (seq[bad_seq:] + np.uint64(1)) % np.uint64(4)
    loss = np.zeros(len(tot), dtype=np.uint64)
    if loss_from is not None:
        loss[loss_from[0]:loss_from[1]] = 1
    words[:, 0] = (np.uint64(1) << np.uint64(63)) | (loss << np.uint64(62)) | (seq << np.uint64(60)) \
        | (t[:, 2] << np.uint64(40)) | (t[:, 1] << np.uint64(20)) | t[:, 0]
    words[:, 1] = (bits.astype(np.uint64) << np.uint64(60)) | (t[:, 5] << np.uint64(40)) | (t[:, 4] << np.uint64(20)) | t[:, 3]
    data = words.astype('<u8').tobytes()
    open(path, 'wb').write(data)
    every = n0 // period
    strap = rings if strap is None else strap
    bad_counts = [0] * len(runs) if bad_counts is None else bad_counts
    bad_rings = [[0] if b else [] for b in bad_counts] if bad_rings is None else bad_rings
    ctrl = [(every - 1) | rings << 16 | (count_unit == 1) << 28 | strap << 32 | b << 48 for b in bad_counts]
    stamp, table = 1000, []
    for a, m in runs:
        table.append(dict(start=int(a), records=int(m), cycle_start=stamp, cycle_end=stamp + m * n0 + 40))
        stamp += m * n0 + 5000
    side = dict(format='karu64-rosc-count-1', kind='records', period=period, every=every, clocks_per_record=n0, ring_mask=rings,
                requested=len(tot), records=len(tot), runs=table, run_ctrl=[hex(c) for c in ctrl], bad_counts=bad_counts,
                bad_rings=bad_rings,
                losses=len(runs) - 1, sha256=hashlib.sha256(data).hexdigest(), clock_hz=75000000, stages=list(STAGES),
                ctrl=hex(ctrl[-1] & ((1 << 48) - 1)), strap_mask=strap, count_unit=count_unit, time=when,
                note='generated by test_rosc_own.py')
    for k in drop:
        del side[k]
    json.dump(side, open(sidecar or os.path.splitext(path)[0] + '.json', 'w'), indent=1)

# ---- trials ----
def trial(args):
    """One generated capture through the tool. Returns the figures the studies need."""
    seed, n, kw, opts = args
    rng = np.random.default_rng(seed)
    cap, truth = capture(n, rng, **kw)
    # the studies measure what the statistics give; the record minimum is a rule on top of them (section I)
    res = ro.analyze(cap, **dict(dict(full=False, grid=1024, seed=seed, min_records=1), **opts))
    row = dict(seed=seed, truth=truth['a'][0], methods={}, a_low=None,
               verdict={k: v['verdict'] for k, v in res.get('verdict', {}).items()},
               why={k: v['why'] for k, v in res.get('verdict', {}).items()}, notes=res.get('notes', []),
               locked=res.get('lock', {}).get('locked', []))
    for m, ft in res.get('fit', {}).get('0', {}).items():
        row['methods'][m] = (ft['a'], ft['se_a'], ft['a_low'], ft['p_fit'], ft['b'], ft['c'])
    if 'lane0' in res:
        l = res['lane0']
        row.update(a=l['a'], se=l['se_a'], a_low=l['a_low'], a_high=l['a_high'], primary=l['primary'], disagree=bool(l['disagree']),
                   misfit=l['misfit'], limited=l['sens_over'], over=l['over_upper'], a_upper=l['a_upper_model_free'],
                   excess=l['excess'], zmax=l['excess_z_max'],
                   checks={k: (v.get('ok') if k != 'gaussian' else {s: g['ok'] for s, g in v.items()})
                           for k, v in res['assumptions'].items() if isinstance(v, dict)},
                   stat_p=min([p for p in (res['assumptions']['stationarity'][k] for k in ('p_segments', 'p_trend', 'p_runs'))
                               if p is not None]) if 'stationarity' in res['assumptions'] else None,
                   fact_p=(res['assumptions']['shared_factors'].get('two_factor') or {}).get('p'),
                   mem_z=res['assumptions'].get('memory', {}).get('z_min'),
                   ratio={k: v.get('ratio') for k, v in res['verdict'].items()},
                   need={k: v.get('variance_needed') for k, v in res['verdict'].items()},
                   as_measured={k: v.get('as_measured') for k, v in res['verdict'].items()},
                   agree=[(a['methods'], a['difference'], a['se'], a['counts']) for a in l['agreement']])
    return row

def run_trials(n, kw, trials, jobs=1, seed0=1000, opts=None):
    args = [(seed0 + i, n, kw, opts or {}) for i in range(trials)]
    if jobs > 1:
        import multiprocessing as mp
        with mp.Pool(jobs) as pool:
            return pool.map(trial, args, chunksize=max(1, trials // (jobs * 4)))
    return [trial(a) for a in args]

VERDICTS = ('pass', 'fail', 'not established', 'cross-check only')

def summarize(rows, margin=2.0):
    """Bias in standard errors, coverage of the lower bound, verdicts, failed checks."""
    out = dict(trials=len(rows))
    got = [r for r in rows if r.get('a_low') is not None]
    out['with_bound'] = len(got)
    for s in ('4096', '16384'):
        vs = [r['verdict'].get(s) for r in rows]
        out['verdict_' + s] = {k: vs.count(k) for k in VERDICTS}
        ms = [r.get('as_measured', {}).get(s) or r['verdict'].get(s) for r in rows]      # under the cross-check label
        out['measured_' + s] = {k: ms.count(k) for k in VERDICTS[:3]}
    if not got:
        return out
    truth = got[0]['truth']
    z = np.array([(r['a'] - truth) / r['se'] for r in got])
    failed = lambda k: int(sum(r['checks'].get(k) is False for r in got))
    out.update(truth=truth, a_mean=float(np.mean([r['a'] for r in got])), se_mean=float(np.mean([r['se'] for r in got])),
               a_sd=float(np.std([r['a'] for r in got], ddof=1)) if len(got) > 1 else None,
               z_mean=float(z.mean()), z_sd=float(z.std(ddof=1)) if len(got) > 1 else None,
               low_mean=float(np.mean([r['a_low'] for r in got])), low_median=float(np.median([r['a_low'] for r in got])),
               covered=int(sum(r['a_low'] <= truth for r in got)), high_covered=int(sum(r['a_high'] >= truth for r in got)),
               disagree=int(sum(bool(r['disagree']) for r in got)), misfit=int(sum(bool(r['misfit']) for r in got)),
               limited=int(sum(bool(r['limited']) for r in got)), over=int(sum(bool(r['over']) for r in got)),
               excess=int(sum(bool(r['excess']) for r in got)),
               checks=dict(stationarity=failed('stationarity'), shared_factors=failed('shared_factors'),
                           independence=failed('independence'), memory=failed('memory'),
                           gaussian_4096=int(sum(r['checks'].get('gaussian', {}).get('4096') is False for r in got)),
                           gaussian_16384=int(sum(r['checks'].get('gaussian', {}).get('16384') is False for r in got))),
               # the one outcome that must not happen: a pass where the truth does not have the margin
               false_pass={s: int(sum(1 for r in got if 'pass' in (r['verdict'].get(s), r['as_measured'].get(s)) and r['need'].get(s)
                                      and truth * int(s) < margin * r['need'][s])) for s in ('4096', '16384')},
               # and a pass, or a cross-check that would pass, whose bound is above the truth
               pass_above_truth=int(sum(1 for r in got for s in ('4096', '16384')
                                        if 'pass' in (r['verdict'].get(s), r['as_measured'].get(s)) and r['a_low'] > truth)))
    out['methods'] = {}
    for m in ('hat', 'ls', 'f1', 'f2'):
        g = [r['methods'][m] for r in got if m in r['methods']]
        if g:
            g = np.array(g)
            zz = (g[:, 0] - truth) / g[:, 1]
            out['methods'][m] = dict(a_mean=float(g[:, 0].mean()), a_sd=float(g[:, 0].std(ddof=1)) if len(g) > 1 else None,
                                     se_mean=float(g[:, 1].mean()), z_mean=float(zz.mean()),
                                     z_sd=float(zz.std(ddof=1)) if len(g) > 1 else None, covered=int((g[:, 2] <= truth).sum()), n=len(g))
    return out

# ---- the self-test ----
CHECKS = [0, 0]

def check(ok, what, detail=''):
    CHECKS[0] += 1
    CHECKS[1] += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {what}" + (f'  [{detail}]' if detail else ''), flush=True)
    return ok

def stat(z, m):
    return float(ro.second_moments([np.asarray(z, dtype=float).reshape(-1, 1)], m)[0][0, 0])

def pieces(rng):
    print('A. the pieces')
    for (p, nu), want in {(0.99, 63): 2.3870, (0.99, 31): 2.4528, (0.99, 10): 2.7638, (0.975, 20): 2.0860}.items():
        check(abs(ro.t_ppf(p, nu) - want) < 2e-3, f'Student quantile p={p} nu={nu}', f'{ro.t_ppf(p, nu):.4f} for {want}')
    # the statistic's conversions
    n, n0, a = 400000, 1024, 5e-5
    w = np.cumsum(rng.standard_normal(n) * math.sqrt(a * n0))
    for m in (1, 4, 32):
        got = stat(w, m)
        check(abs(got / (a * m * n0) - 1) < 0.03, f'white FM: A = a tau at m={m}', f'{got:.4f} for {a * m * n0:.4f}')
    q = 0.07
    e = rng.standard_normal(n) * math.sqrt(q)
    check(all(abs(stat(e, m) / (3 * q) - 1) < 0.02 for m in (1, 4, 32)), 'a constant resolution term: A = 3 q at every span',
          ', '.join(f'{stat(e, m):.4f}' for m in (1, 4, 32)) + f' for {3 * q:.4f}')
    walk = np.cumsum(9.037 * n0 + rng.standard_normal(n) * 1.3) + 0.3
    for unit in (1, 2):
        cnt = unit * np.floor(walk / unit)
        got = stat(cnt - 9.037 * n0 * np.arange(n), 1) - 1.3 ** 2
        check(abs(got - ro.reading(unit)) < 0.03 * unit ** 2 and ro.reading(unit) == 0.25 * unit ** 2,
              f'counting in steps of {unit} period(s) adds unit^2 / 4 = {ro.reading(unit):g}', f'{got:.4f}')
    fl, ex = flicker(n, n0, 3e-9, rng)
    r = [ex(m) / (3e-9 * (m * n0) ** 2) for m in (1, 2, 4, 64, 1024)]
    check(max(abs(x - 1) for x in r) < 0.015, 'generated flicker FM: expected A = b tau^2 at 1 to 1024 records',
          ', '.join(f'{x:.4f}' for x in r))
    got = np.mean([stat(flicker(100000, n0, 3e-9, rng)[0], 16) for _ in range(12)]) / (3e-9 * (16 * n0) ** 2)
    check(abs(got - 1) < 0.1, 'generated flicker FM: measured A against b tau^2 at 16 records', f'{got:.3f}')
    check(abs(ro.s2_needed(0.511, 0.75) - 0.103) < 0.001, 'entropy_claim.p_max: 0.75 bit at D = 0.511 needs 0.103 periods^2',
          f'{ro.s2_needed(0.511, 0.75):.4f}')
    check(ro.h_min(0.5, 0.0) == 0.0 and ro.h_min(0.5, -1.0) == 0.0, 'no credited variance, no entropy')
    # the methods on exact matrices: own variance psi, clock rho, a factor of loadings v
    f = np.array(F_NOM)
    psi = np.array([0.8, 0.5, 0.3, 0.2, 0.9, 0.7]) / f ** 2
    def S_of(rho, v, rings):
        g = rho + np.outer(v, v) + np.diag(psi)
        return (g * np.outer(f, f))[np.ix_(rings, rings)]
    v = 3.0 * np.array(SENS_UNEQUAL)
    for rings in ([0, 1, 2, 3, 4, 5], [0, 1, 2, 3], [0, 2, 3, 4, 5]):
        o, _ = ro.own_all(S_of(4.0, v, rings)[None], f[rings], rings, 0.25)
        check(np.allclose(o['f2'][0], (psi * f ** 2)[rings], rtol=2e-4), f'f2 exact for clock + one factor, rings {rings}',
              f"largest error {np.max(np.abs(o['f2'][0] / (psi * f ** 2)[rings] - 1)):.1e}")
        o, _ = ro.own_all(S_of(0.0, v, rings)[None], f[rings], rings, 0.25)
        check(np.allclose(o['f1'][0], (psi * f ** 2)[rings], rtol=1e-6) and np.allclose(o['f2'][0], (psi * f ** 2)[rings], rtol=2e-4),
              f'f1 and f2 exact for one factor of unequal loadings, rings {rings}')
        o, _ = ro.own_all(S_of(4.0, 3.0 * np.ones(6), rings)[None], f[rings], rings, 0.25)
        check(all(np.allclose(o[m][0], (psi * f ** 2)[rings], rtol=1e-6) for m in ('ls', 'f1', 'f2')),
              f'ls, f1, f2 exact for equal loadings, rings {rings}')
        if 'hat' in o:
            i = [rings.index(r) for r in (0, 4, 5)]
            check(np.allclose(o['hat'][0][i], (psi * f ** 2)[[0, 4, 5]], rtol=1e-9), f'hat exact for equal loadings, rings {rings}')
        check(np.all(o['upper'][0] >= (psi * f ** 2)[rings] * (1 - 1e-9)), f'the regression bound is above the own variance, rings {rings}')
    o, _ = ro.own_all(S_of(4.0, v, [0, 4, 5])[None], f[[0, 4, 5]], [0, 4, 5], 0.25)
    check('f2' not in o and 'hat' in o and 'f1' in o, 'three rings: hat and f1, no f2')
    o, _ = ro.own_all(S_of(0.0, np.zeros(6), [0, 1, 2, 3, 4, 5])[None], f, [0, 1, 2, 3, 4, 5], 0.25)
    check(all(np.allclose(o[m][0], psi * f ** 2, rtol=1e-9) for m in ('ls', 'f1', 'f2'))
          and np.allclose(o['hat'][0][[0, 4, 5]], (psi * f ** 2)[[0, 4, 5]], rtol=1e-9), 'no shared part: every method returns the diagonal')
    # lines
    k = np.arange(200000)
    z = 0.2 * np.sin(2 * np.pi * 0.0371 * k + 1.0) + np.cumsum(rng.standard_normal(len(k)) * 0.2)
    found, K = ro.find_lines([z], 16384)
    check(len(found) == 1 and abs(found[0][0] - 0.0371) < 1e-4 and abs(found[0][1] / 0.2 - 1) < 0.1,
          'a line of 0.2 period on a random walk: frequency and amplitude', str([(round(x[0], 5), round(x[1], 3)) for x in found]))
    found, K = ro.find_lines([np.cumsum(rng.standard_normal(len(k)) * 0.2) + flicker(len(k), 1024, 1e-9, rng)[0]], 16384)
    check(not found, 'no line in white plus flicker FM', str(found))
    check(ro.rational(1.5)[:2] == (3, 2) and ro.rational(1.0000001)[:2] == (1, 1) and ro.rational(0.3786)[:2] == (3, 8),
          'small rationals next to a ratio')

def formats(rng, producer_dir, producer_required):
    print('B. input: records, sidecar, wrapping, runs, losses, the producer\'s own files')
    d = os.path.join(OUT, 'selftest')
    os.makedirs(d, exist_ok=True)
    for old in glob.glob(os.path.join(d, '*')):                  # what an earlier run left
        shutil.rmtree(old) if os.path.isdir(old) else os.remove(old)
    n, n0 = 24000, 4096
    tot, bits, truth = synth(n, rng, n0=n0)
    cap = dict(tot=tot, wrapped=False, nominal=None, lanes=bits, n0=n0, runs=[(0, n)], rejected=[], clock_hz=75e6,
               stages=list(STAGES), ring_mask=None, op_mask=63, health=None, count_unit=2, time=None, file='generated')
    ref = analyze(cap, full=False, grid=1024)
    path = os.path.join(d, 'one.bin')
    write_bin(path, tot, bits, n0, [(0, n)], start_count=[1048000, 5, 99999, 524288, 1048575, 0])
    got = analyze(ro.load_capture(path), full=False, grid=1024)
    check(os.path.exists(os.path.join(d, 'one.json')) and not os.path.exists(path + '.json') and got['input']['records'] == n
          and got['input']['n0'] == n0 and got['input']['running'] == [0, 1, 2, 3, 4, 5],
          'NAME.bin with its sidecar NAME.json: all records in one run, N0 from period x every', str(got['input']['records']))
    check(got['lane0']['a'] == ref['lane0']['a'] and got['lane0']['a_low'] == ref['lane0']['a_low'],
          'records file (20-bit totals of half periods, wrapping every 57 records): the same result as the unwrapped totals',
          f"{got['lane0']['a']:.6e}")
    check(got['input']['count_unit'] == 2 and got['input']['count_unit_recorded'] == 2 and got['input']['unwrap']['count_unit'] == 2
          and abs(got['input']['unwrap']['median_increment'][0] * 2 / n0 - got['rings'][0]['rate']) < 0.01
          and abs(got['rings'][0]['rate'] - F_NOM[0]) < 1e-3,
          'the sidecar\'s count_unit 2 is applied: increments are unwrapped in counts, rates are in ring periods',
          f"{got['input']['unwrap']['median_increment'][0]} counts per record, {got['rings'][0]['rate']:.4f} periods per clock")
    check(got['input']['operating_mask'] == 63 and got['input']['ring_mask'] == 63 and got['input']['health'].startswith('recorded'),
          'the sidecar\'s strap_mask and bad_counts are taken: operating rings and instrument health', got['input']['health'])
    os.replace(os.path.join(d, 'one.json'), path + '.json')
    got = analyze(ro.load_capture(path), full=False, grid=1024)
    check(got['lane0']['a'] == ref['lane0']['a'], 'a sidecar named NAME.bin.json is accepted when there is no NAME.json')
    os.remove(path + '.json')
    try:
        ro.load_capture(path)
        check(False, 'a records file without a sidecar is refused')
    except SystemExit as e:
        check('no sidecar' in str(e) and 'one.json' in str(e), 'a records file without a sidecar is refused, the name it wants given', str(e)[-40:])
    write_bin(path, tot, bits, n0, [(0, n)])
    open(path, 'r+b').write(b'\x01')
    try:
        ro.load_capture(path)
        check(False, 'a file that is not the one of its sidecar is refused')
    except SystemExit as e:
        check('sha256' in str(e), 'a file that is not the one its sidecar describes (sha256) is refused')
    np.savez(os.path.join(d, 'one.npz'), totals=tot, bits=bits, n0=n0, op_mask=63, count_unit=2)
    got = analyze(ro.load_capture(os.path.join(d, 'one.npz')), full=False, grid=1024)
    check(got['lane0']['a'] == ref['lane0']['a'] and got['verdict']['16384']['verdict'] == ref['verdict']['16384']['verdict'] == 'pass',
          '.npz with count_unit 2: the same result')
    np.savez(os.path.join(d, 'two.npz'), totals=tot, n0=n0,
             bits=np.stack([(bits >> i) & 1 for i in range(4)], 1))
    got = analyze(ro.load_capture(os.path.join(d, 'two.npz')), full=False, grid=1024, operating_mask=63, count_unit=2)
    check(got['lane0']['a'] == ref['lane0']['a'] and got['rings'][0]['ones'] == ref['rings'][0]['ones'],
          '.npz with bits [records, 4] and --count-unit 2: the same result')
    got = analyze(ro.load_capture(os.path.join(d, 'two.npz')), full=False, grid=1024, operating_mask=63)
    check(got['input']['count_unit'] == 1 and abs(got['rings'][0]['rate'] * 2 - ref['rings'][0]['rate']) < 1e-6
          and all(v['verdict'] == 'cross-check only' for v in got['verdict'].values()),
          '.npz without a count unit: one period per count is taken, which is direct mode: cross-check only')
    # the largest supported N0: in direct mode the increment of the fast rings is above 2^19 counts
    tot2, bits2, _ = synth(3000, rng, n0=65536, count_unit=1)
    x, med, dev = ro.unwrap_run(tot2 % ro.MOD)
    check(np.array_equal(x, tot2) and med[0] > ro.MOD // 2 and dev.max() < ro.MOD // 8,
          'N0 = 65536, direct mode: increments of 592,000 counts unwrap, and stay within 2^17 of their median',
          f'median {med.tolist()}, largest deviation {int(dev.max())}')
    tot2h, _, _ = synth(3000, rng, n0=65536)
    x, medh, dev = ro.unwrap_run(tot2h % ro.MOD)
    check(np.array_equal(x, tot2h) and abs(medh[0] * 2 - med[0]) < 64 and dev.max() < 64,
          'N0 = 65536 behind the divider: half as many counts per record, unwrapped alike', f'median {medh.tolist()}')
    x, med, dev = ro.unwrap_run(tot2 % ro.MOD, nominal=[9.0371 * 65536 + ro.MOD] + [None] * 5)
    check(med[0] > ro.MOD, 'a nominal rate from the sidecar selects the multiple of 2^20')
    # two runs, a loss with a broken sequence, a loss flag, a silent loss of four records
    cut = np.concatenate([tot[:9000], tot[9003:16000], tot[16004:]])
    cb = np.concatenate([bits[:9000], bits[9003:16000], bits[16004:]])
    path = os.path.join(d, 'lossy.bin')
    write_bin(path, cut, cb, n0, [(0, 20000), (20000, len(cut) - 20000)], bad_seq=9000, loss_from=(22000, len(cut)))
    got = analyze(ro.load_capture(path), full=False, grid=1024)
    runs = [(r['start'], r['records']) for r in got['input']['runs']]
    check(runs == [(0, 9000), (9000, 6997), (15997, 4003), (20000, 2000)],
          'a broken sequence splits the run, a jump of the counts (four records lost) splits it, a loss flag ends it', str(runs))
    why = ' / '.join(sorted(set(r['why'] for r in got['input']['rejected'])))
    check(all(w in why for w in ('sequence number', 'loss flag', 'count jumps')), 'every split and rejection is reported', why)
    check(got['input']['records'] == 9000 + 6997 + 4003 + 2000 and abs(got['lane0']['a'] / 5e-5 - 1) < 0.3,
          'the runs are analysed without joining them', f"a = {got['lane0']['a']:.3e} from {got['input']['blocks']} blocks")
    words = np.fromfile(path, dtype='<u8').reshape(-1, 2).copy()
    words[5000, 0] &= np.uint64((1 << 63) - 1)
    words.tofile(path)
    side = json.load(open(os.path.join(d, 'lossy.json')))
    side['sha256'] = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    json.dump(side, open(os.path.join(d, 'lossy.json'), 'w'))
    got = analyze(ro.load_capture(path), full=False, grid=1024)
    check((0, 5000) in [(r['start'], r['records']) for r in got['input']['runs']]
          and any('valid bit' in r['why'] for r in got['input']['rejected']), 'a record without the valid bit ends its run')
    # references off
    tot3, bits3, _ = synth(30000, rng, rings=(1, 1, 1, 1, 0, 0))
    path = os.path.join(d, 'norefs.bin')
    write_bin(path, tot3, bits3, 1024, [(0, 30000)], rings=15)
    got = analyze(ro.load_capture(path), full=False, grid=1024)
    check(got['input']['running'] == [0, 1, 2, 3] and got['input']['off'] == [4, 5] and got['lane0']['methods'] == ['ls', 'f1', 'f2']
          and got['input']['ring_mask'] == 15, 'rings 4 and 5 standing still: found off, hat not used', str(got['lane0']['methods']))
    write_bin(path, tot3, bits3, 1024, [(0, 30000)], rings=63)
    got = analyze(ro.load_capture(path), full=False, grid=1024)
    check(any('ring_mask' in x for x in got['notes']) and all(v['verdict'] != 'pass' and any('ring_mask' in w for w in v['why'])
                                                              for v in got['verdict'].values()),
          'a ring_mask that does not fit the counts is noted and gives no pass')
    # the producer's own files: what rosc_count.py wrote in its offline test (test_rosc_count.py), through
    # its own capture() and publish(), against the stand-in for the board
    files = sorted(glob.glob(os.path.join(producer_dir, 'phase-*', 'rosc-count-p*.bin')))
    if not files:
        msg = f'no capture of rosc_count.py under {producer_dir} (its offline test writes them: make dbg-rosc-count-test)'
        if producer_required:
            check(False, 'the producer\'s files are analysed', msg)
        else:
            print('note: the handoff from rosc_count.py is NOT checked: ' + msg, flush=True)
    for path in files:
        side = json.load(open(os.path.splitext(path)[0] + '.json'))
        cap = ro.load_capture(path)
        res = analyze(cap, full=False, grid=1024)
        mask, unit = side['ring_mask'], side.get('count_unit')
        clean = [r for r, bad in zip(side['runs'], side['bad_counts']) if not bad and r['records'] >= ro.MIN_RUN]
        flagged = [(r, bad, k) for k, (r, bad) in enumerate(zip(side['runs'], side['bad_counts'])) if bad]
        rej = res['rejected'] if 'error' in res else res['input']['rejected']
        said = all(any(x['start'] == r['start'] and f'{bad} clock cycle(s) in which the meter flagged' in x['why']
                       and ('bad_rings' not in side or x['rings'] == sorted(side['bad_rings'][k])) for x in rej) for r, bad, k in flagged)
        if not clean:                                            # nothing to analyse: said so, with what was set aside
            ok = 'error' in res and said and len(rej) >= len(side['runs']) and all(v['verdict'] == 'not established' for v in res['verdict'].values())
            detail = f"{side['records']} records, no usable run: " + '; '.join(x['why'][:70] for x in rej)
        else:
            inp = res['input']
            rates = {r['ring']: r['rate'] for r in res['rings']}
            ok = (side['format'] == 'karu64-rosc-count-1' and cap['n0'] == side['clocks_per_record'] == inp['n0'] and said
                  and cap['runs'] == [(r['start'], r['start'] + r['records']) for r, bad in zip(side['runs'], side['bad_counts'])
                                      if not bad and r['records'] >= 3]
                  and inp['ring_mask'] == mask == inp['ring_mask_recorded'] and inp['operating_mask'] == side['strap_mask']
                  and inp['health'].startswith('recorded') and inp['clock_hz'] == side['clock_hz']
                  and inp['count_unit_recorded'] == unit and (unit is None or inp['count_unit'] == unit)
                  and sorted(rates) == [r for r in range(6) if mask >> r & 1] and all(0 < v < 64 for v in rates.values())
                  and set(res['verdict']) == {'4096', '16384'}
                  and all(v['verdict'] == ('cross-check only' if mask != side['strap_mask'] or unit == 1 else 'not established')
                          for v in res['verdict'].values())
                  and (unit is not None or all(any('count unit not recorded' in w for w in v['why']) for v in res['verdict'].values())))
            detail = (f"{inp['records']} records in {len(cap['runs'])} run(s), mask {mask:#04x}, strap {side['strap_mask']:#04x}, count_unit "
                      f"{'NOT IN THE SIDECAR' if unit is None else unit}, rates {' '.join(f'{v:.3f}' for v in rates.values())}; "
                      f"{res['verdict']['4096']['verdict']}: {res['verdict']['4096']['why'][0][:60]}")
        check(ok, f"written by rosc_count.py: {os.path.relpath(path, producer_dir)}: sidecar found; runs, N0, ring mask, strap mask, count "
              'unit, health and rates taken; flagged runs set aside with their rings; too few records for a bound, said so', detail)

RECOVERY = [
    # name, records, trials, generator arguments
    ('a 5e-5, shared 20x half clock half supply, equal sensitivity', 40000, 6, dict()),
    ('a 2e-5, shared 50x supply, unequal sensitivity', 40000, 6, dict(a0=2e-5, a_ref=2e-5, shared=50, supply_share=1.0, sens=SENS_UNEQUAL)),
    ('a 2e-4, shared 20x, unequal, own flicker (corner 16384 clocks)', 40000, 6,
     dict(a0=2e-4, a_ref=2e-4, sens=SENS_UNEQUAL, own_flicker=16384.0)),
    ('a 5e-5, shared 50x with supply flicker, unequal', 40000, 6, dict(shared=50, sens=SENS_UNEQUAL, supply_flicker=4096.0)),
    ('a 5e-5, N0 = 256, shared 50x, unequal', 60000, 6, dict(n0=256, shared=50, sens=SENS_UNEQUAL)),
    ('a 5e-5, N0 = 4096, shared 20x, unequal, own flicker', 30000, 6, dict(n0=4096, sens=SENS_UNEQUAL, own_flicker=65536.0)),
    ('a 5e-5, references off, shared 20x, equal', 40000, 6, dict(rings=(1, 1, 1, 1, 0, 0))),
    ('a 5e-5, references off, shared 50x supply, unequal', 40000, 6,
     dict(rings=(1, 1, 1, 1, 0, 0), shared=50, supply_share=1.0, sens=SENS_UNEQUAL)),
    ('a 5e-5, references off, shared 50x mixed, unequal, own flicker', 40000, 6,
     dict(rings=(1, 1, 1, 1, 0, 0), shared=50, sens=SENS_UNEQUAL, own_flicker=16384.0)),
    ('a 5e-5, N0 = 4096, no shared part at all (fit from 32768 clocks)', 100000, 4, dict(shared=0.0, n0=4096)),
    ('a 0 (ring 0 without white noise), shared 50x, unequal', 40000, 6, dict(a0=0.0, shared=50, sens=SENS_UNEQUAL)),
    ('a 1e-5, shared 50x, unequal', 40000, 6, dict(a0=1e-5, shared=50, sens=SENS_UNEQUAL)),
    ('direct mode (unit 1): a 5e-5, shared 20x, equal', 40000, 4, dict(count_unit=1)),
    ('direct mode (unit 1): a 2e-5, shared 50x supply, unequal', 40000, 4,
     dict(count_unit=1, a0=2e-5, a_ref=2e-5, shared=50, supply_share=1.0, sens=SENS_UNEQUAL)),
    ('direct mode (unit 1): a 5e-5, references off, shared 50x mixed, unequal', 40000, 4,
     dict(count_unit=1, rings=(1, 1, 1, 1, 0, 0), shared=50, sens=SENS_UNEQUAL)),
]

def recovery():
    print('C. recovery of a: (estimate - truth) / standard error, per trial; behind the divider (unit 2) unless it says direct')
    zs = []
    for name, n, trials, kw in RECOVERY:
        rows = run_trials(n, kw, trials, seed0=4000)
        s = summarize(rows)
        z = [(r['a'] - r['truth']) / r['se'] for r in rows if r.get('a_low') is not None]
        zs += z
        ok = len(z) == trials and max(abs(x) for x in z) < 4 and abs(np.mean(z)) < 1.5
        check(ok, name, 'z ' + ' '.join(f'{x:+.1f}' for x in z) + f"; se {s.get('se_mean', 0):.1e}; bound below the truth in "
              f"{s.get('covered')}/{s.get('with_bound')}")
    check(abs(np.mean(zs)) < 0.35 and 0.7 < np.std(zs, ddof=1) < 1.3, f'all {len(zs)} trials together: mean and spread of z',
          f'mean {np.mean(zs):+.2f}, sd {np.std(zs, ddof=1):.2f}')

def controls(rng):
    print('D. negative controls, each on full analyses')
    # ring 0 without white noise; all own noise flicker
    for name, kw in (('ring 0 without own white noise, everything else large', dict(a0=0.0, shared=50, sens=SENS_UNEQUAL, own_flicker=65536.0)),
                     ('all own noise flicker, none white', dict(a0=0.0, white_others=0.0, own_flicker=16384.0, shared=50, sens=SENS_UNEQUAL))):
        rows = run_trials(40000, kw, 6, seed0=5000)
        passes = sum(v == 'pass' for r in rows for v in r['verdict'].values())
        lows = [r['a_low'] / r['se'] for r in rows]
        check(passes == 0 and max(lows) < 1.0 and sum(x <= 0 for x in lows) >= 5 and max(abs(r['a']) for r in rows) < 0.2 * 5e-5,
              name + ': never a pass, the bound not above zero', 'a_low / se: ' + ' '.join(f'{x:+.1f}' for x in lows)
              + '; a: ' + ' '.join(f"{r['a']:+.1e}" for r in rows))
    # lock
    cap, truth = capture(60000, rng, lock=(0, 4))
    res = analyze(cap, grid=1024)
    check(res['lock']['locked'] == [[0, 4]] and 'hat' not in res['lane0']['methods'] and 4 not in [int(k) for k in res['fit']],
          'rings 0 and 4 locked: flagged, ring 4 and the hat left out', str(res['lock']['locked']))
    check(all(v['verdict'] == 'not established' and any('locked' in w for w in v['why']) for v in res['verdict'].values()),
          'rings 0 and 4 locked: not established')
    cap, truth = capture(60000, rng, lock=(1, 2))
    res = analyze(cap, grid=1024)
    check(res['lock']['locked'] == [[1, 2]] and res['lock']['dropped'] == [1, 2] and res['verdict']['16384']['verdict'] == 'pass'
          and abs(res['lane0']['a'] - 5e-5) < 4 * res['lane0']['se_a'],
          'rings 1 and 2 locked: both left out, ring 0 still measured against 3, 4, 5', f"a = {res['lane0']['a']:.3e}")
    # a strong shared line
    line = (1234.5, 5.0)
    cap, truth = capture(100000, rng, line=line, shared=50, sens=SENS_UNEQUAL)
    res = analyze(cap, grid=1024)
    found = [l for l in res['lines']['found'] if l['series'] == 'ring 0']
    check(len(found) == 1 and abs(found[0]['hz'] - 1234.5) < 2 and abs(found[0]['amplitude'] / 5 - 1) < 0.1,
          'a shared line of 5 periods at 1234.5 Hz: named in ring 0 with frequency and size',
          str([(round(l['hz'], 1), round(l['amplitude'], 2)) for l in found]))
    v = res['verdict']['4096']
    check(v['verdict'] == 'not established' or abs(res['lane0']['a'] - 5e-5) < 4 * res['lane0']['se_a'],
          'with the line and the references: the bound is unaffected or not established',
          f"{v['verdict']}, a = {res['lane0']['a']:.3e} +-{res['lane0']['se_a']:.1e}")
    cap, truth = capture(100000, rng, line=line, shared=50, sens=SENS_UNEQUAL, rings=(1, 1, 1, 1, 0, 0))
    res = analyze(cap, grid=1024)
    v = res['verdict']['16384']
    check((v['verdict'] == 'not established' and any('line' in w for w in v['why']))
          or abs(res['lane0']['a'] - 5e-5) < 4 * res['lane0']['se_a'],
          'with the line and without the references: the bound is unaffected, or not established because of the line',
          f"{v['verdict']}, a = {res['lane0']['a']:.3e} +-{res['lane0']['se_a']:.1e}; lines found in pairs: "
          f"{sum(len(l['rings']) == 2 for l in res['lines']['found'])}")
    # own noise that is not independent
    for pair in ((0, 1), (4, 5), (0, 4)):
        cap, truth = capture(60000, rng, shared=50, sens=SENS_UNEQUAL, private=((pair[0], pair[1], 2.5e-5),))
        res = analyze(cap, full=False, grid=1024)
        ind = res['assumptions']['independence']
        check(all(v['verdict'] == 'not established' and any('not independent' in w for w in v['why']) for v in res['verdict'].values())
              and ind['ok'] is False and list(pair) in [r['pair'] for r in ind['pairs'] if r['flagged']],
              f'rings {pair[0]} and {pair[1]} share noise of their own: the independence check fails and names the pair',
              f"z of the pair {[r['z'] for r in ind['pairs'] if r['pair'] == list(pair)][0]:+.1f}, a = {res['lane0']['a']:.2e}")
    # too few rings, too little data, count against bit
    cap, truth = capture(40000, rng, rings=(1, 0, 0, 0, 1, 1))
    res = analyze(cap, full=False, grid=1024)
    check(all(v['verdict'] == 'not established' and any('four are needed' in w for w in v['why']) for v in res['verdict'].values())
          and abs(res['lane0']['a'] - 5e-5) < 4 * res['lane0']['se_a'], 'three rings: an estimate, no verdict', f"a = {res['lane0']['a']:.3e}")
    cap, truth = capture(40000, rng, rings=(1, 0, 0, 0, 1, 0))
    res = analyze(cap, full=False, grid=1024)
    check('lane0' not in res and all(v['verdict'] == 'not established' for v in res['verdict'].values()), 'two rings: no bound', res['notes'][-1])
    cap, truth = capture(1800, rng)
    res = analyze(cap, full=False, grid=1024)
    check('lane0' not in res and all(v['verdict'] == 'not established' and 'too little data' in v['why'][0] for v in res['verdict'].values()),
          '1,800 records: too little data, said so', res['verdict']['4096']['why'][0][:90])
    cap, truth = capture(40000, rng)
    cap['lanes'] = np.roll(cap['lanes'], 7)
    res = analyze(cap, full=False, grid=1024)
    cb = res['rings'][0]['count_bit']
    check(cb['ok'] is False and res['verdict']['16384']['verdict'] == 'not established'
          and any('do not fit each other' in w for w in res['verdict']['16384']['why']),
          'lane bits that do not belong to the counts: flagged', f"slope {cb['slope']:+.3f}, square {cb['square']:+.3f}")
    for unit in (2, 1):
        want = (0.02, 0.2, 0.0, 0.1) if unit == 2 else (0.3, 0.6, 0.85, 1.25)
        cap, truth = capture(40000, rng, latency=want + (0.05, 0.05), duty=(0.5, 0.5, 0.5, 0.5), count_unit=unit, shared=50)
        res = analyze(cap, full=False, grid=1024)
        cbs = [r['count_bit'] for r in res['rings'][:4]]
        check(all(c['ok'] is True and 0.4 < c['relation'] < 0.6 and abs(c['latency'] - w % 1) < 0.03 for c, w in zip(cbs, want)),
              f'unit {unit}: count and bit fit whatever the latency of the count ({", ".join(f"{w:g}" for w in want)} period), '
              'and it is measured modulo one period',
              ' '.join(f"{c['latency']:.3f} (slope {c['slope']:+.2f}, square {c['square']:+.2f})" for c in cbs))

def verdicts(rng):
    print('E. verdicts, the margin and the report')
    cap, truth = capture(100000, rng, a0=1.5e-4, shared=50, sens=SENS_UNEQUAL, duty=(0.508, 0.5, 0.5, 0.5))
    res = analyze(cap, spacings=(4096, 16384, 1024, 3000, 600000))
    json.loads(json.dumps(res))
    v = res['verdict']
    check(all(v[k]['verdict'] == 'pass' and v[k]['margin_met'] and v[k]['ratio'] >= 2 for k in ('4096', '16384', '3000')),
          'a = 1.5e-4, 100,000 records: pass at 4,096, 16,384 and 3,000 clocks, the bound over twice the need',
          'ratios ' + ' '.join(f"{v[k]['ratio']:.2f}" for k in ('4096', '16384', '3000')))
    check(abs(v['4096']['duty'] - 0.508) < 0.006 and v['4096']['duty'] > 0.508 and abs(v['4096']['variance_needed'] - 0.1) < 0.01
          and abs(v['4096']['ratio'] - v['4096']['credited_variance'] / v['4096']['variance_needed']) < 1e-12,
          'the need is that of 0.75 bit at the lane bit\'s bias at its upper end; the ratio is the credited variance over it',
          f"duty {v['4096']['duty']:.4f}, need {v['4096']['variance_needed']:.4f}")
    check(v['1024']['verdict'] == 'not established' and 1 < v['1024']['ratio'] < 2 and not v['1024']['margin_met']
          and 'not the margin' in v['1024']['why'][0],
          'at 1,024 clocks the bound reaches the need and not the margin of 2: not established', v['1024']['why'][0][:80])
    r2 = analyze(cap, full=False, grid=1024, spacings=(1024,), margin=1.2)
    check(r2['verdict']['1024']['verdict'] == 'pass' and r2['verdict']['1024']['margin_required'] == 1.2, '--margin 1.2: the same bound passes')
    check(v['600000']['verdict'] == 'not established' and any('outside the fitted spans' in w for w in v['600000']['why']),
          'a spacing beyond the fitted spans: not established')
    cap, truth = capture(100000, rng, shared=50, sens=SENS_UNEQUAL)
    res = analyze(cap, spacings=(4096, 16384, 1024))
    v = res['verdict']
    check(v['16384']['verdict'] == 'pass' and v['4096']['verdict'] == 'not established' and 1.5 < v['4096']['ratio'] < 2
          and 'margin' in v['4096']['why'][0], 'a = 5e-5: pass at 16,384 clocks; at 4,096 the need is met, the margin is not',
          f"ratios {v['4096']['ratio']:.2f} and {v['16384']['ratio']:.2f}; {v['4096']['why'][0][:100]}")
    check(v['1024']['verdict'] == 'fail' and v['1024']['ratio_at_upper'] < 1, 'at 1,024 clocks not even the upper end reaches the need: fail',
          f"upper end {v['1024']['ratio_at_upper']:.2f} times the need")
    l = res['lane0']
    check(l['a_low'] < l['a'] < l['a_high'] and l['a_low'] <= min(res['fit']['0'][m]['a_low'] for m in l['methods'])
          and l['a'] < l['a_upper_model_free'], 'the bound is the smallest of the methods\' and below the model-free upper bound',
          f"{l['a_low']:.3e} < {l['a']:.3e} < {l['a_upper_model_free']:.3e}")
    sr = {r['ring']: r['loading_over_rate'] for r in res['sensitivity']['rings']}
    check(all(abs(sr[i] - (1 + 0.5 * (SENS_UNEQUAL[i] - 1))) < 0.006 for i in sr), 'loading ratios: half of the sensitivity difference, half of the shared part being the clock',
          ' '.join(f'{sr[i]:.4f}' for i in sorted(sr)))
    sh = res['shared']['rings']['0']
    check(40 < sh['shared_over_own'][-1] < 60 and 0.8 < sh['loglog_slope'] < 1.2, 'the shared part: 50 times the own part at the long spans, growing as the span',
          f"{sh['shared_over_own'][-1]:.1f}, slope {sh['loglog_slope']:.2f}")
    sp = res['spans']
    k = sp['m'].index(64)
    want = (51 * 5e-5 * 64 * 1024 + ro.reading(2), 2 * 5e-5 * 64 * 1024 + 2 * ro.reading(2))
    check(abs(sp['ring_vs_clock']['0'][k] / want[0] - 1) < 0.15 and abs(sp['pairs']['0-4']['fixed'][k] / want[1] - 1) < 0.15
          and sp['m'][-1] * 10 <= 100000 < sp['m'][-1] * 20,
          'tables: ring 0 against the clock and the pair 0-4 at 65,536 clocks, spans up to a tenth of the run',
          f"{sp['ring_vs_clock']['0'][k]:.1f} and {sp['pairs']['0-4']['fixed'][k]:.2f} for {want[0]:.1f} and {want[1]:.2f}")
    o = res['other_rings']['rings']
    check([r['ring'] for r in o] == [1, 2, 3, 4, 5] and all(abs(r['a']['f2'] / (5e-5 * (F_NOM[r['ring']] / F_NOM[0]) ** 2) - 1) < 0.2 for r in o),
          'the other rings\' a, for information', ' '.join(f"{r['a']['f2']:.2e}" for r in o))
    t = ro.text(res)
    check('PASS' in t and 'lane 0: a =' in t and 'does not by itself show' in t and 'margin asked: 2 x' in t and len(t.splitlines()) > 25
          and 'count unit 2: divided: one count is 2 ring periods' in t,
          'the text summary: the count unit, verdicts with ratio and margin, the checks, and that linear growth alone shows no '
          'unpredictability')

def health_and_masks(rng):
    print('F. instrument health and the rings of normal operation')
    d = os.path.join(OUT, 'selftest')
    n = 60000
    tot, bits, truth = synth(n, rng)
    path = os.path.join(d, 'health.bin')
    write_bin(path, tot, bits, 1024, [(0, 40000), (40000, 20000)], bad_counts=[0, 3], bad_rings=[[], [4, 1]])
    res = analyze(ro.load_capture(path), full=False, grid=1024)
    rej = [r for r in res['input']['rejected'] if 'bad_counts' in r['why']]
    check([(r['start'], r['records']) for r in res['input']['runs']] == [(0, 40000)] and len(rej) == 1
          and (rej[0]['start'], rej[0]['records']) == (40000, 20000) and rej[0]['rings'] == [1, 4]
          and '3 clock cycle(s) in which the meter flagged a count as unreadable or inconsistent, ring(s) 1, 4' in rej[0]['why']
          and res['verdict']['16384']['verdict'] == 'pass',
          'a run with flagged counts (bad_counts 3, bad_rings 1 and 4) is left out of every estimate and listed with the rings; '
          'the clean run is analysed', rej[0]['why'] if rej else '')
    import subprocess
    tool = [sys.executable, os.path.join(HERE, 'rosc_own.py'), '--min-records', str(LOW)]
    r = subprocess.run(tool + [path], capture_output=True, text=True)
    check(r.returncode == 0 and json.loads(r.stdout)['verdict']['16384']['verdict'] == 'pass' and not r.stderr,
          'exit status 0: the capture was analysed and has its verdicts')
    write_bin(path, tot, bits, 1024, [(0, 40000), (40000, 20000)], bad_counts=[1, 65535], drop=('bad_rings',))
    res = analyze(ro.load_capture(path), full=False, grid=1024)
    check('error' in res and 'lane0' not in res and all(v['verdict'] == 'not established' for v in res['verdict'].values())
          and len(res['rejected']) == 2 and all('rings not recorded' in x['why'] for x in res['rejected']),
          'every run with flagged counts: nothing is estimated', res.get('error', ''))
    r = subprocess.run(tool + [path], capture_output=True, text=True)
    js = json.loads(r.stdout) if r.stdout.startswith('{') else {}
    check(r.returncode == 2 and 'error' in js and [x['start'] for x in js['rejected']] == [0, 40000] and 'Traceback' not in r.stderr,
          'exit status 2 when no run is usable; the JSON has the error and what was set aside', js.get('error', r.stderr[-100:]))
    r2 = subprocess.run(tool + [path, '--text'], capture_output=True, text=True)
    check(r2.returncode == 2 and 'no usable run' in r2.stdout and 'flagged a count' in r2.stdout, 'and the text says why')
    fine = os.path.join(d, 'fine.bin')
    write_bin(fine, tot, bits, 1024, [(0, n)])
    for what, argv in (('a file that is not there', [os.path.join(d, 'nothing.bin')]),
                       ('a records file without its sidecar', [os.path.join(d, 'orphan.bin')]),
                       ('a --pair that is not there', [fine, '--pair', os.path.join(d, 'nothing.bin')]),
                       ('a --bits that is no analysis', [fine, '--bits', os.path.join(d, 'orphan.bin')])):
        open(os.path.join(d, 'orphan.bin'), 'wb').write(bytes(160))
        r = subprocess.run(tool + argv, capture_output=True, text=True)
        check(r.returncode == 2 and r.stderr.startswith('rosc_own: ') and 'Traceback' not in r.stderr and not r.stdout,
              f'exit status 2 and one line on stderr for {what}', r.stderr.strip()[-90:])
    write_bin(path, tot, bits, 1024, [(0, n)], drop=('bad_counts',))
    res = analyze(ro.load_capture(path), full=False, grid=1024)
    check(all(v['verdict'] == 'not established' and 'instrument health not recorded' in v['why'][0] for v in res['verdict'].values())
          and abs(res['lane0']['a'] - 5e-5) < 4 * res['lane0']['se_a'] and res['input']['health'] == 'not recorded',
          'a sidecar without bad_counts: analysed, and not established because the instrument\'s health is not recorded')
    # the mask of normal operation
    write_bin(path, tot, bits, 1024, [(0, n)], rings=63, strap=15)
    cap = ro.load_capture(path)
    res = analyze(cap, full=False, grid=1024)
    v = res['verdict']
    check(all(x['verdict'] == 'cross-check only' for x in v.values()) and v['16384']['as_measured'] == 'pass'
          and 'normal operation runs 0x0f' in v['16384']['why'][-1] and 'lane0' in res and res['assumptions']['stationarity']['ok'],
          'six rings captured, four run in normal operation: analysed in full, the verdict is "cross-check only"',
          f"as measured: {v['16384']['as_measured']}; {v['16384']['why'][-1][:70]}")
    res = analyze(cap, full=False, grid=1024, operating_mask=63)
    check(res['verdict']['16384']['verdict'] == 'pass' and res['input']['operating_mask'] == 63, '--operating-mask overrides the sidecar')
    res = analyze(cap, full=False, grid=1024, operating_mask=31)
    check(all(x['verdict'] == 'cross-check only' for x in res['verdict'].values()), 'any other operating mask: cross-check only')
    write_bin(path, tot, bits, 1024, [(0, n)], drop=('strap_mask',))
    res = analyze(ro.load_capture(path), full=False, grid=1024)
    check(all(x['verdict'] == 'not established' and any('normal operation are not known' in w for w in x['why']) for x in res['verdict'].values()),
          'the operating rings neither in the sidecar nor given: not established')
    np.savez(os.path.join(d, 'nomask.npz'), totals=tot, bits=bits, n0=1024, count_unit=2)
    res = analyze(ro.load_capture(os.path.join(d, 'nomask.npz')), full=False, grid=1024)
    check(all(x['verdict'] == 'not established' for x in res['verdict'].values()), '.npz without op_mask and without the option: not established')
    passes = 0
    for seed in range(4):                                        # a mask mismatch can never give a pass
        cap, _ = capture(40000, np.random.default_rng(7000 + seed), a0=2e-4, op_mask=15)
        res = analyze(cap, full=False, grid=1024)
        passes += sum(x['verdict'] == 'pass' for x in res['verdict'].values())
        ok = all(x['verdict'] == 'cross-check only' and x['as_measured'] == 'pass' for x in res['verdict'].values())
    check(passes == 0 and ok, 'a = 2e-4 with six rings while four run in operation, four captures: never a pass, each one a cross-check that would pass')
    # four dissimilar rings, the operating set: ls, f1, f2 and no hat
    tot4, bits4, _ = synth(100000, rng, rings=(1, 1, 1, 1, 0, 0), shared=50, sens=SENS_UNEQUAL)
    write_bin(path, tot4, bits4, 1024, [(0, 100000)], rings=15, strap=15)
    res = analyze(ro.load_capture(path), full=False, grid=1024)
    a = res['assumptions']
    check(res['lane0']['methods'] == ['ls', 'f1', 'f2'] and res['lane0']['primary'] == 'f2' and res['verdict']['16384']['verdict'] == 'pass'
          and res['lane0']['a_low'] <= res['fit']['0']['f1']['a_low'] and a['shared_factors']['two_factor']['free_per_span'] == 1
          and a['shared_factors']['one_factor']['free_per_span'] == 2 and a['independence']['ok'] and a['stationarity']['method'] == 'ls',
          'mask 0x0f in operation and in the capture: bound from ls, f1 and f2 (one degree of freedom tests clock and one factor)',
          f"a = {res['lane0']['a']:.3e} +-{res['lane0']['se_a']:.1e}, bound {res['lane0']['a_low']:.3e}, ratio at 16,384 "
          f"{res['verdict']['16384']['ratio']:.2f}")
    r = subprocess.run([sys.executable, os.path.join(HERE, 'rosc_own.py'), '--min-records', str(LOW), path, '--text', '--operating-mask', '0x0f', '--margin', '1.5',
                        '--spacing', '8192', '--out', os.path.join(d, 'out.json')], capture_output=True, text=True)
    js = json.load(open(os.path.join(d, 'out.json'))) if r.returncode == 0 else {}
    check(r.returncode == 0 and 'spacing  16384: PASS' in r.stdout and '8192' in js.get('verdict', {}) and 'margin asked: 1.5 x' in r.stdout
          and js['input']['operating_mask'] == 15, 'rosc_own.py as a command: --text, --operating-mask, --margin, --spacing, --out',
          r.stderr[-200:])

def assumptions(rng):
    print('G. the assumptions as checks')
    cap, truth = capture(100000, rng, shared=50, sens=SENS_UNEQUAL)
    res = analyze(cap, full=False, grid=1024)
    a = res['assumptions']
    check(set(a) == {'note', 'stationarity', 'gaussian', 'shared_factors', 'independence', 'memory'}
          and all(a[k]['ok'] is True for k in ('stationarity', 'shared_factors', 'independence', 'memory'))
          and all(g['ok'] is True for g in a['gaussian'].values()) and len(a['stationarity']['segments']) == 8,
          'a capture of the model: stationarity, Gaussian increments, shared factors, independence and memory all pass',
          f"p segments {a['stationarity']['p_segments']:.2f}, two factors p {a['shared_factors']['two_factor']['p']:.2f}, "
          f"largest pair z {a['independence']['z_max']:.1f}, c z {a['memory']['z_min']:+.1f}")
    g = a['gaussian']['4096']['series']
    check(all(abs(r['excess_kurtosis'] - r['expected']) < r['tolerance'] / 2 and -0.35 < r['expected'] < -0.12 for r in g.values())
          and set(g) == {'ring 0 less its regression on the others', 'pair 0-4', 'pair 0-5'},
          'Gaussian own noise: excess kurtosis as the counting errors of two periods alone give it (about -0.2), for the '
          'regression residual and both like pairs',
          ' '.join(f"{r['excess_kurtosis']:+.3f} for {r['expected']:+.3f}" for r in g.values()))
    def run(name, kw, expect, n=100000, **opts):
        cap, truth = capture(n, rng, **kw)
        res = analyze(cap, full=False, grid=1024, **opts)
        a = res['assumptions']
        failed = sorted([k for k in ('stationarity', 'shared_factors', 'independence', 'memory') if a.get(k, {}).get('ok') is False]
                        + ['gaussian ' + s for s, g in a.get('gaussian', {}).items() if g['ok'] is False]
                        + (['fit'] if res.get('lane0', {}).get('misfit') else []))
        none = all(v.get('as_measured', v['verdict']) == 'not established' for v in res['verdict'].values())
        check(all(e in failed for e in expect) and (none if expect else not failed), name,
              'failed: ' + (', '.join(failed) or 'none') + f"; a = {res['lane0']['a']:.2e}; " + ' '.join(v['verdict'] for v in res['verdict'].values()))
        return res
    res = run('own noise that doubles halfway: stationarity fails, not established', dict(a_step=(0.5, 2.0)), ['stationarity'])
    st = res['assumptions']['stationarity']
    check(st['p_segments'] < 1e-3 and np.mean([x['a'] for x in st['segments'][4:]]) > 1.6 * np.mean([x['a'] for x in st['segments'][:4]]),
          'the segments show the change', ' '.join(f"{x['a']:.1e}" for x in st['segments']))
    run('a telegraph component, rare large switches (dwell 10^6 clocks, 2.9 periods in 4,096 clocks): the increments at 16,384 '
        'clocks are not Gaussian, not established', dict(telegraph=(1e6, 0.5)), ['gaussian 16384'])
    run('the same with switches of 5.8 periods in 4,096 clocks: not Gaussian at 4,096 clocks either',
        dict(telegraph=(1e6, 2.0)), ['gaussian 4096', 'gaussian 16384'])
    run('direct mode (unit 1), switches of 2.9 periods: not Gaussian at both spacings', dict(telegraph=(1e6, 0.5), count_unit=1),
        ['gaussian 4096', 'gaussian 16384'])
    run('a telegraph component in place of white noise, dwell 16 records: the fit and its constant term fail, not established',
        dict(telegraph=(16384.0, 5e-5), a0=0.0), ['memory', 'fit'])
    run('the same with a dwell of 2 records: the constant term gives the memory away, not established',
        dict(telegraph=(2048.0, 5e-5), a0=0.0), ['memory'])
    run('the same with a dwell of 64 clocks: fresh at these spans, no check fails', dict(telegraph=(64.0, 5e-5), a0=0.0), [])
    run('a third and a fourth shared factor (rings 0-2 and rings 3-5 each share noise): the factor count fails',
        dict(private=((0, 1, 2, 2.5e-5), (3, 4, 5, 2.5e-5))), ['shared_factors'])
    cap, truth = capture(12000, rng)
    res = analyze(cap, full=False, grid=1024, spacings=(16384, 32768))
    v = res['verdict']['32768']
    check(res['assumptions']['gaussian']['32768']['ok'] is None and res['assumptions']['gaussian']['16384']['ok'] is True
          and v['verdict'] == 'not established' and any('could not be tested for a Gaussian shape' in w for w in v['why']),
          '12,000 records: too few independent increments at 32,768 clocks to test their shape, said so',
          [w for w in v['why'] if 'Gaussian' in w][0][-80:])

def burst_analysis(d, rng, f, lanes=(0, 1, 4, 5), bursts=8, n=8192, drift=1e-4):
    """Bursts of sampled bits of the rings listed, one sample per clock, in the format of the burst
    capture, and what getnoise_analyze.py itself (not a look-alike) makes of them: the path of its
    getnoise-analysis.json. The rings run at f (1 + drift): the bursts are of another time."""
    import contextlib, io
    import getnoise_analyze as ga
    os.makedirs(d, exist_ok=True)
    data = bytearray()
    for b in range(bursts):
        sym = np.zeros(n, dtype=np.uint8)
        shared = rng.standard_normal(n) * 0.0035                 # the clock's jitter, clock periods
        for lane, ring in enumerate(lanes):
            rate = f[ring] * (1 + drift)
            ph = rng.random() + np.cumsum(rate % 1 + rate * shared + rng.standard_normal(n) * 0.007)
            sym |= ((ph % 1) < 0.5).astype(np.uint8) << lane
        sym[0] |= 0x80
        data += sym.tobytes()
    path = os.path.join(d, 'getnoise-burst-p1.bin')
    open(path, 'wb').write(data)
    json.dump(dict(format='karu64-getnoise-burst-1', kind='burst', source='refbits', lanes=[f'ring {r}' for r in lanes], period=1, k=1,
                   clock_hz=75000000, bursts=bursts, symbols_per_burst=n, stored=len(data), runs=bursts, run_lengths=[n] * bursts,
                   sha256=hashlib.sha256(bytes(data)).hexdigest()), open(os.path.join(d, 'getnoise-burst-p1.json'), 'w'))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = ga.main([path, '--out', d])
    return os.path.join(d, 'getnoise-analysis.json') if rc in (0, 1) else None

def units(rng):
    print('H. the count unit, direct mode, the pair of counting modes, the sampled bits')
    d = os.path.join(OUT, 'selftest')
    n = 60000
    f = (9.137, 6.2113, 4.3127, 3.4219, 9.2603, 8.8459)          # fractions away from 0 and 1/2, for the sampled bits
    tot, bits, truth = synth(n, rng, f=f)                        # behind the divider: counts of two periods
    A = os.path.join(d, 'divided.bin')
    write_bin(A, tot, bits, 1024, [(0, n)], count_unit=2)
    good = analyze(ro.load_capture(A), full=False, grid=1024)
    check(good['input']['count_unit'] == 2 and good['verdict']['16384']['verdict'] == 'pass' and abs(good['rings'][0]['rate'] - f[0]) < 1e-3
          and abs(good['fit']['0']['hat']['c'] - 1.0) < 0.05 and good['assumptions']['memory']['reading'] == 1.0,
          'behind the divider: rates in ring periods, the constant term of own(span) is the 1.0 of counting in twos, pass',
          f"rate {good['rings'][0]['rate']:.4f}, c {good['fit']['0']['hat']['c']:.3f}, a {good['lane0']['a']:.2e}")
    write_bin(A, tot, bits, 1024, [(0, n)], drop=('count_unit',))
    res = analyze(ro.load_capture(A), full=False, grid=1024)
    check(all(v['verdict'] == 'not established' and 'count unit not recorded' in v['why'][0] for v in res['verdict'].values())
          and res['input']['count_unit_recorded'] is None and 'NOT ESTABLISHED' in ro.text(res),
          'a sidecar without count_unit: not established, "count unit not recorded"', res['verdict']['16384']['why'][0][:60])
    res = analyze(ro.load_capture(A), full=False, grid=1024, count_unit=2)
    check(all(v['verdict'] == 'not established' and 'count unit not recorded' in v['why'][0] for v in res['verdict'].values())
          and abs(res['lane0']['a'] - good['lane0']['a']) < 1e-12,
          '--count-unit sets what the numbers are in, and does not stand in for the sidecar', f"a {res['lane0']['a']:.2e}")
    write_bin(A, tot, bits, 1024, [(0, n)], count_unit=2)
    res = analyze(ro.load_capture(A), full=False, grid=1024, count_unit=1)
    check(all(v['verdict'] == 'not established' and any('not the one of the sidecar' in w for w in v['why']) for v in res['verdict'].values()),
          '--count-unit against the sidecar: not established')
    # direct mode: the same rings counted in single periods, ten minutes later, 3e-5 faster
    f2 = tuple(x * (1 + 3e-5) for x in f)
    tot1, bits1, _ = synth(n, rng, f=f2, count_unit=1)
    B = os.path.join(d, 'direct.bin')
    write_bin(B, tot1, bits1, 1024, [(0, n)], count_unit=1, when='2026-11-21T09:10:00+00:00')
    res = analyze(ro.load_capture(B), full=False, grid=1024)
    t = ro.text(res)
    check(all(v['verdict'] == 'cross-check only' and any('direct mode' in w for w in v['why']) for v in res['verdict'].values())
          and res['verdict']['16384']['as_measured'] == 'pass' and res['input']['count_unit'] == 1
          and abs(res['fit']['0']['hat']['c'] - 0.25) < 0.02 and 'direct mode: the counter is clocked by the ring itself' in t,
          'direct mode (count_unit 1): analysed in full, every verdict a cross-check only, said in the text',
          f"as measured {res['verdict']['16384']['as_measured']}, c {res['fit']['0']['hat']['c']:.3f}, a {res['lane0']['a']:.2e}")
    # the pair: the two modes' rates must be the same in ring periods
    res = analyze(ro.load_capture(A), full=False, grid=1024, pair=ro.load_capture(B))
    pr = res['pair']
    check(pr['ok'] is True and len(pr['rings']) == 6 and all(abs(r['ratio'] - (1 - 3e-5)) < 2e-6 and abs(r['counts_ratio'] - 2) < 1e-3
                                                             and not r['flagged'] for r in pr['rings'])
          and res['verdict']['16384']['verdict'] == 'pass' and pr['gap']['source'].startswith('the time stamps'),
          '--pair with the direct capture: every ring\'s rates agree within the drift (here 3e-5), the counts are in the ratio 2',
          f"ratios {' '.join(f'{r['ratio']:.6f}' for r in pr['rings'])}; allowed {pr['rings'][0]['allowed']:.1e}")
    # the divider at a wrong steady ratio: the meter notices nothing, the sidecar still says 2
    wrong = {}
    for name, kw in (('divided by 3', dict(count_unit=3)), ('not divided', dict(count_unit=1)), ('ring 2 loses 1 % of its periods', dict(miscount=(2, 0.99)))):
        totw, bitsw, _ = synth(n, rng, f=f, **kw)
        W = os.path.join(d, 'wrong.bin')
        write_bin(W, totw, bitsw, 1024, [(0, n)], count_unit=2)
        alone = analyze(ro.load_capture(W), full=False, grid=1024)
        res = analyze(ro.load_capture(W), full=False, grid=1024, pair=ro.load_capture(B))
        flagged = [r['ring'] for r in res['pair']['rings'] if r['flagged']]
        wrong[name] = (W, totw, bitsw)
        check(res['pair']['ok'] is False and flagged == ([2] if 'ring 2' in name else [0, 1, 2, 3, 4, 5])
              and all(v['verdict'] == 'not established' and any('pair of counting modes' in w for w in v['why']) for v in res['verdict'].values()),
              f'counts as if {name}, sidecar says 2: --pair flags ' + ('that ring' if 'ring 2' in name else 'every ring') + ', not established',
              f"ratios {' '.join(f'{r['ratio']:.4f}' for r in res['pair']['rings'])}; without --pair: {alone['verdict']['16384']['verdict']}, "
              f"a {alone['lane0']['a']:.2e}")
    for name, other in (('the same mode', A), ('another spacing', 'n0'), ('other rings', 'mask')):
        if other == 'n0':
            t4, b4, _ = synth(8000, rng, f=f, count_unit=1, n0=4096)
            other = os.path.join(d, 'other.bin')
            write_bin(other, t4, b4, 4096, [(0, 8000)], count_unit=1)
        elif other == 'mask':
            t4, b4, _ = synth(8000, rng, f=f, count_unit=1, rings=(1, 1, 1, 1, 0, 0))
            other = os.path.join(d, 'other.bin')
            write_bin(other, t4, b4, 1024, [(0, 8000)], count_unit=1, rings=15)
        res = analyze(ro.load_capture(A), full=False, grid=1024, pair=ro.load_capture(other))
        check(res['pair']['ok'] is False and not res['pair']['rings'] and res['verdict']['16384']['verdict'] == 'not established',
              f'--pair with a capture of {name}: no comparison, not established', res['pair']['why'][0][:70])
    # the sampled bits: no counter and no divider in their path. The real getnoise_analyze.py makes the analysis
    js = burst_analysis(os.path.join(d, 'refbits'), rng, f)
    ana = json.load(open(js))
    res = analyze(ro.load_capture(A), full=False, grid=1024, bits=ana, bits_name=js)
    bt = res['bits']
    t = ro.text(res)
    check(bt['ok'] is True and bt['checked'] == 4 and [r['ring'] for r in bt['rings']] == [0, 1, 4, 5]
          and all(r['ok'] and r['distance'] < r['tolerance'] < 0.02 for r in bt['rings']) and bt['accidental'] < 1e-4
          and bt['required'] == 4 and not bt['missing'] and res['verdict']['16384']['verdict'] == 'pass'
          and '4 of the 4 mapped ring(s) that run were checked' in t and 'by accident has a chance of about' in t,
          '--bits with the analysis that getnoise_analyze.py wrote for bursts of reference bits: four rings\' count rates agree with '
          'their sampled frequencies',
          ' '.join(f"ring {r['ring']}: {r['frac']:.4f} for {r['F']:.4f}, {r['distance']:.4f} of {r['tolerance']:.4f};" for r in bt['rings'])
          + f" chance {bt['accidental']:.0e}")
    # every mapped ring that runs must be measured: a usable fit for lane 0 alone does not do
    part = json.loads(json.dumps(ana))
    for c in part['captures']:
        if c.get('clocks') == 1:
            c['lanes'] = [l if l.get('lane') == 0 else dict(lane=l.get('lane'), windows=dict(usable=False),
                                                              pooled=dict(identifiable=False), fit=dict(identifiable=False))
                          for l in c['lanes']]
    res = analyze(ro.load_capture(A), full=False, grid=1024, bits=part, bits_name=js)
    bt = res['bits']
    check(bt['ok'] is False and bt['checked'] == 1 and bt['required'] == 4 and bt['missing'] == [1, 4, 5] and not bt['failed']
          and res['verdict']['16384']['verdict'] == 'not established'
          and any('no usable frequency fit for ring(s) 1, 4, 5' in w for w in res['verdict']['16384']['why']),
          '--bits with a usable frequency fit for lane 0 only: not ok, the three unmeasured rings named, not established',
          '; '.join(bt['why'])[:160])
    # a mapped lane whose ring does not run in the capture is listed and does not count
    t4, b4, _ = synth(n, rng, f=f, rings=(1, 1, 1, 1, 0, 0))
    C = os.path.join(d, 'four.bin')
    write_bin(C, t4, b4, 1024, [(0, n)], count_unit=2, rings=15)
    res = analyze(ro.load_capture(C), full=False, grid=1024, bits=ana, bits_name=js)
    bt = res['bits']
    check(bt['ok'] is True and bt['required'] == 2 and bt['checked'] == 2 and bt['not_running'] == [4, 5] and not bt['missing'],
          '--bits on a capture of rings 0 to 3 with fits for rings 0, 1, 4 and 5: 4 and 5 listed as not running and not counted',
          f"required {bt['required']}, checked {bt['checked']}, not running {bt['not_running']}")
    check('folded frequency only' in bt['sees'] and 'folded frequency only' in ro.text(res) and '--pair is needed' in ro.text(res),
          'what --bits can see is said in the result and the text: the folded frequency only; --pair is needed as well')
    for name in ('divided by 3', 'not divided'):
        W, totw, bitsw = wrong[name]
        write_bin(W, totw, bitsw, 1024, [(0, n)], count_unit=2)
        res = analyze(ro.load_capture(W), full=False, grid=1024, bits=ana, bits_name=js)
        bt = res['bits']
        check(bt['ok'] is False and sum(r['ok'] is False for r in bt['rings']) >= 3
              and all(v['verdict'] == 'not established' and any('the divider\'s ratio is not established' in w for w in v['why'])
                      for v in res['verdict'].values()),
              f'counts as if {name}: --bits flags the rings, "the divider\'s ratio is not established"',
              ' '.join(f"ring {r['ring']}: {r['distance']:.3f} of {r['tolerance']:.3f};" for r in bt['rings']))
    js2 = burst_analysis(os.path.join(d, 'lanebits'), rng, f, lanes=(0, 1, 2, 3))
    import subprocess
    r = subprocess.run([sys.executable, os.path.join(HERE, 'rosc_own.py'), '--min-records', str(LOW), A, '--text', '--pair', B, '--bits', js2, '--bits-map',
                        '0:0,1:1,2:2,3:3', '--out', os.path.join(d, 'out2.json')], capture_output=True, text=True)
    out = json.load(open(os.path.join(d, 'out2.json'))) if r.returncode == 0 else {}
    check(r.returncode == 0 and out['bits']['ok'] and [x['ring'] for x in out['bits']['rings']] == [0, 1, 2, 3] and out['pair']['ok']
          and 'count rates against sampled bits' in r.stdout and 'pair with' in r.stdout and 'spacing  16384: PASS' in r.stdout,
          'rosc_own.py as a command with --pair, --bits and --bits-map for ordinary lane bits', r.stderr[-200:])
    W = wrong['not divided'][0]
    write_bin(W, wrong['not divided'][1], wrong['not divided'][2], 1024, [(0, n)], count_unit=2)
    r = subprocess.run([sys.executable, os.path.join(HERE, 'rosc_own.py'), '--min-records', str(LOW), W, '--pair', B, '--bits', js], capture_output=True, text=True)
    out = json.loads(r.stdout) if r.returncode == 0 else {}
    check(r.returncode == 0 and out['pair']['ok'] is False and out['bits']['ok'] is False and out['pair']['count_unit'] == [2, 1]
          and os.path.basename(out['pair']['other']) == 'direct.bin'
          and all(v['verdict'] == 'not established' for v in out['verdict'].values()),
          'a flagged --pair and --bits change the verdict and not the exit status (0: the capture was analysed)')
    res = analyze(ro.load_capture(A), full=False, grid=1024, bits=dict(captures=[dict(clocks=4, lanes=[])]))
    check(res['bits']['ok'] is False and res['verdict']['16384']['verdict'] == 'not established',
          '--bits without a burst at one clock per sample: nothing checked, not established', res['bits']['why'][0])

def minimum(rng):
    print('I. the least usable records of a capture that may pass')
    d = os.path.join(OUT, 'selftest')
    cap, truth = capture(100000, rng, a0=1.5e-4, shared=50, sens=SENS_UNEQUAL)
    low = analyze(cap, full=False, grid=1024, spacings=(4096, 16384))
    res = ro.analyze(cap, full=False, grid=1024, spacings=(4096, 16384))
    v = res['verdict']
    check(ro.MIN_RECORDS == 300000 and res['input']['min_records'] == 300000 and not res['input']['min_records_lowered']
          and low['verdict']['16384']['verdict'] == 'pass'
          and all(x['verdict'] == 'not established' and any('usable records, a bound needs at least 300000' in w for w in x['why'])
                  for x in v.values())
          and res['lane0']['a_low'] is not None and v['16384'].get('ratio') is not None,
          'a capture of 100,000 records that passes below the minimum: not established at 300,000 usable records; its estimates, '
          'bound and ratio still given for bring-up',
          f"{res['input']['records_usable']} usable; {v['16384']['why'][0][:80]}; lowered: {low['verdict']['16384']['verdict']}")
    check(low['input']['min_records_lowered'] is True and 'min_records_lowered' in low['verdict']['16384']
          and 'MINIMUM LOWERED FOR A TEST' in ro.text(low) and 'min_records_lowered' not in v['16384']
          and 'MINIMUM LOWERED' not in ro.text(res),
          'a lowered minimum is said in the result and in the text, and only then')
    n = 320000
    tot, bits, truth = synth(n, rng, a0=1.5e-4, shared=50, sens=SENS_UNEQUAL)
    path = os.path.join(d, 'long.bin')
    write_bin(path, tot, bits, 1024, [(0, n)])
    res = ro.analyze(ro.load_capture(path), full=False, grid=1024, spacings=(4096, 16384))
    check(res['input']['records_usable'] >= 300000 and res['verdict']['16384']['verdict'] == 'pass',
          'a records file of 320,000 records, all usable: it may pass',
          f"{res['input']['records_usable']} usable, {res['verdict']['16384']['verdict']}")
    check(res['input']['records_usable'] == res['input']['blocks'] * res['input']['block_records'] == 320000
          and res['input']['records_in_kept_runs'] == 320000,
          'one run of 320,000: 64 blocks of 5,000, every record in the fit, both counts reported',
          f"{res['input']['blocks']} x {res['input']['block_records']}, {res['input']['records_in_kept_runs']} in the runs kept")
    write_bin(path, tot, bits, 1024, [(0, 290000), (290000, 30000)], bad_counts=[0, 3], bad_rings=[[], [1]])
    res = ro.analyze(ro.load_capture(path), full=False, grid=1024, spacings=(4096, 16384))
    v = res['verdict']['16384']
    check(res['input']['records_usable'] < 300000 and [r['start'] for r in res['input']['rejected']] == [290000]
          and v['verdict'] == 'not established' and any('usable records, a bound needs at least 300000' in w for w in v['why']),
          'the same 320,000 records with a flagged run of 30,000: fewer than 300,000 usable, not established',
          f"{res['input']['records_usable']} usable; {v['why'][0][:80]}")
    import subprocess
    r = subprocess.run([sys.executable, os.path.join(HERE, 'rosc_own.py'), path, '--text'], capture_output=True, text=True)
    check(r.returncode == 0 and 'a bound needs 300000' in r.stdout and 'NOT ESTABLISHED' in r.stdout and 'LOWERED' not in r.stdout
          and 'in the runs kept' in r.stdout,
          'as a command, without --min-records: the usable records, those of the runs kept and the minimum in the text, not established',
          r.stderr[-100:])
    # 304,000 records in sixteen runs that blocks of the right number do not fill: 64 blocks of 4,400 = 281,600 enter
    # the fit, and the ends of the longer runs do not. The minimum is for the records of the fit.
    n = 304000
    tot, bits, truth = synth(n, rng, a0=1.5e-4, shared=50, sens=SENS_UNEQUAL)
    runs, at = [], 0
    for k in range(16):
        runs.append((at, 17600 if k % 2 == 0 else 20400))
        at += runs[-1][1]
    write_bin(path, tot, bits, 1024, runs)
    res = ro.analyze(ro.load_capture(path), full=False, grid=1024, spacings=(4096, 16384))
    i, v = res['input'], res['verdict']['16384']
    low = analyze(ro.load_capture(path), full=False, grid=1024, spacings=(4096, 16384))
    check(i['records_in_kept_runs'] == 304000 and (i['blocks'], i['block_records']) == (64, 4400) and i['records_usable'] == 281600
          and v['verdict'] == 'not established' and any('281600 usable records, a bound needs at least 300000' in w for w in v['why'])
          and low['verdict']['16384']['verdict'] == 'pass',
          '304,000 records in sixteen uneven runs, 281,600 of them in the 64 blocks of the fit: not established (it passes with the '
          'minimum lowered)', f"{i['records_in_kept_runs']} kept, {i['blocks']} x {i['block_records']} = {i['records_usable']}; {v['why'][0][:90]}")

def self_test(producer_dir, producer_required):
    t0 = time.time()
    rng = np.random.default_rng(20261120)
    np.seterr(all='ignore')
    pieces(rng)
    formats(rng, producer_dir, producer_required)
    recovery()
    controls(rng)
    verdicts(rng)
    health_and_masks(rng)
    assumptions(rng)
    units(rng)
    minimum(rng)
    ok = CHECKS[1] == 0
    print(f'{time.time() - t0:.0f} s')
    print(f"rosc_own self-test: {'PASS' if ok else 'FAIL'} ({CHECKS[0]} checks" + ('' if ok else f', {CHECKS[1]} failed') + ')')
    return ok

# ---- the coverage study ----
U = dict(sens=SENS_UNEQUAL)
NOREF = dict(rings=(1, 1, 1, 1, 0, 0))
W3 = (1.0, 0.6, 0.3, 0.0, 1.0, 1.0)                            # a third shared factor: its sensitivities by ring
COVERAGE = [
    # name, records, generator arguments, analysis options
    ('a 5e-5, shared 20x, equal', 30000, dict(), {}),
    ('a 2e-5, shared 50x supply, unequal', 30000, dict(U, a0=2e-5, a_ref=2e-5, shared=50, supply_share=1.0), {}),
    ('a 2e-4, shared 20x, unequal', 30000, dict(U, a0=2e-4, a_ref=2e-4), {}),
    ('a 5e-5, shared 50x supply, unequal', 30000, dict(U, shared=50, supply_share=1.0), {}),
    ('a 5e-5, shared 50x mixed + supply flicker, unequal', 30000, dict(U, shared=50, supply_flicker=4096.0), {}),
    ('a 5e-5, own flicker corner 16384, shared 20x, unequal', 30000, dict(U, own_flicker=16384.0), {}),
    ('a 5e-5, own flicker corner 2048, shared 50x, unequal', 30000, dict(U, own_flicker=2048.0, shared=50), {}),
    ('a 5e-5, N0 256, shared 50x, unequal', 60000, dict(U, n0=256, shared=50), {}),
    ('a 5e-5, N0 4096, shared 20x, unequal, flicker 65536', 30000, dict(U, n0=4096, own_flicker=65536.0), {}),
    ('a 5e-5, 300,000 records, shared 50x mixed, unequal', 300000, dict(U, shared=50), {}),
    ('a 5e-5, 6,000 records, shared 20x, unequal', 6000, dict(U), {}),
    ('no refs: a 5e-5, shared 20x, equal', 30000, dict(NOREF), {}),
    ('no refs: a 5e-5, shared 50x supply, unequal', 30000, dict(NOREF, **U, shared=50, supply_share=1.0), {}),
    ('no refs: a 5e-5, shared 50x mixed, unequal, flicker 16384', 30000, dict(NOREF, **U, shared=50, own_flicker=16384.0), {}),
    ('no refs: a 5e-5, 300,000 records, shared 50x mixed, unequal', 300000, dict(NOREF, **U, shared=50), {}),
    ('no refs: a 2e-5, N0 256, shared 50x, unequal', 60000, dict(NOREF, **U, n0=256, a0=2e-5, a_ref=2e-5, shared=50), {}),
    ('no refs: a 2e-4, N0 4096, shared 20x, unequal', 30000, dict(NOREF, **U, n0=4096, a0=2e-4, a_ref=2e-4), {}),
    ('a 5e-5, no shared part, 100,000 records', 100000, dict(shared=0.0), {}),
    ('a 5e-5, shared line 5 periods, shared 50x, unequal', 30000, dict(U, shared=50, line=(1234.5, 5.0)), dict(full=True)),
    ('no refs: a 5e-5, shared line 5 periods, 50x, unequal', 30000, dict(NOREF, **U, shared=50, line=(1234.5, 5.0)), dict(full=True)),
    ('MASK a 2e-4, six rings captured, four in operation', 30000, dict(U, a0=2e-4, a_ref=2e-4, op_mask=15), {}),
    ('CONTROL a 0, shared 50x, unequal', 30000, dict(U, a0=0.0, shared=50), {}),
    ('CONTROL a 0, shared 50x, unequal, flicker 65536', 30000, dict(U, a0=0.0, shared=50, own_flicker=65536.0), {}),
    ('CONTROL no refs: a 0, shared 50x, unequal', 30000, dict(NOREF, **U, a0=0.0, shared=50), {}),
    ('CONTROL all own noise flicker (corner 16384)', 30000, dict(U, a0=0.0, white_others=0.0, own_flicker=16384.0, shared=50), {}),
    ('CONTROL all own noise flicker (corner 2048)', 30000, dict(U, a0=0.0, white_others=0.0, own_flicker=2048.0, shared=50), {}),
    ('CONTROL no refs: all own noise flicker (corner 16384)', 30000,
     dict(NOREF, **U, a0=0.0, white_others=0.0, own_flicker=16384.0, shared=50), {}),
    ('VIOLATION rings 0 and 1 share half of a', 30000, dict(U, shared=50, private=((0, 1, 2.5e-5),)), {}),
    ('VIOLATION rings 4 and 5 share a tenth of a', 30000, dict(U, shared=50, private=((4, 5, 5e-6),)), {}),
    ('VIOLATION rings 0 and 1 share a tenth of a', 30000, dict(U, shared=50, private=((0, 1, 5e-6),)), {}),
    ('VIOLATION rings 0 and 1 share a tenth of a, 300,000 records', 300000, dict(U, shared=50, private=((0, 1, 5e-6),)), {}),
    ('VIOLATION no refs: rings 0 and 1 share a tenth of a', 30000, dict(NOREF, **U, shared=50, private=((0, 1, 5e-6),)), {}),
    ('VIOLATION no refs: rings 0 and 1 share a tenth of a, 300,000 records', 300000,
     dict(NOREF, **U, shared=50, private=((0, 1, 5e-6),)), {}),
    ('VIOLATION no refs: rings 0 and 1 share half of a', 30000, dict(NOREF, **U, shared=50, private=((0, 1, 2.5e-5),)), {}),
    ('VIOLATION rings 0-3 share a second supply (5 a)', 30000, dict(U, shared=50, private=((0, 1, 2, 3, 2.5e-4),)), {}),
    ('VIOLATION a third shared factor (1 a at ring 0)', 30000, dict(U, shared=50, extra=((W3, 5e-5),)), {}),
    ('VIOLATION no refs: a third shared factor (1 a at ring 0)', 30000, dict(NOREF, **U, shared=50, extra=((W3, 5e-5),)), {}),
    ('VIOLATION no refs: a third shared factor (a tenth of a)', 30000, dict(NOREF, **U, shared=50, extra=((W3, 5e-6),)), {}),
    ('VIOLATION no refs: a third shared factor (a tenth of a), 300,000 records', 300000, dict(NOREF, **U, shared=50, extra=((W3, 5e-6),)), {}),
    ('VIOLATION own noise of ring 0 doubles halfway', 30000, dict(U, a_step=(0.5, 2.0)), {}),
    ('VIOLATION own noise of ring 0 grows by a fifth halfway', 30000, dict(U, a_step=(0.5, 1.2)), {}),
    ('VIOLATION telegraph for white noise, dwell 16 records', 30000, dict(U, a0=0.0, telegraph=(16384.0, 5e-5)), {}),
    ('VIOLATION telegraph for white noise, dwell 2 records', 30000, dict(U, a0=0.0, telegraph=(2048.0, 5e-5)), {}),
    ('VIOLATION telegraph, rare large switches (dwell 10^6 clocks)', 30000, dict(U, telegraph=(1e6, 0.5)), {}),
    ('VIOLATION no refs: telegraph for white noise, dwell 2 records', 30000, dict(NOREF, **U, a0=0.0, telegraph=(2048.0, 5e-5)), {}),
    ('telegraph for white noise, dwell 64 clocks (fresh at these spans)', 30000, dict(U, a0=0.0, telegraph=(64.0, 5e-5)), {}),
]

UNIT1_SET = ('a 5e-5, shared 20x, equal', 'a 2e-5, shared 50x supply, unequal', 'a 5e-5, shared 50x supply, unequal',
             'a 5e-5, own flicker corner 16384, shared 20x, unequal', 'a 5e-5, N0 4096, shared 20x, unequal, flicker 65536',
             'no refs: a 5e-5, shared 20x, equal', 'no refs: a 5e-5, shared 50x mixed, unequal, flicker 16384',
             'CONTROL a 0, shared 50x, unequal', 'CONTROL all own noise flicker (corner 16384)',
             'VIOLATION rings 0 and 1 share a tenth of a')

def coverage(trials, jobs, only=None, unit=2):
    """The study at one count unit: 2 (behind the divider, the default) runs every scenario, 1 (direct mode)
    the smaller set UNIT1_SET unless --only names others. Results go to coverage-unit<unit>.json."""
    os.makedirs(OUT, exist_ok=True)
    out = []
    print(f'coverage of the lower bound with a count unit of {unit}, {trials} trials per scenario (300,000-record scenarios: a '
          'fifth); verdict counts are pass / fail / not established / cross-check only, as the statistics give them (the '
          f'record minimum of {ro.MIN_RECORDS} usable records is a rule on top and is not applied here)', flush=True)
    for name, n, kw, opts in COVERAGE:
        if (only and not any(o in name for o in only)) or (not only and unit == 1 and name not in UNIT1_SET):
            continue
        t0 = time.time()
        tr = trials if n < 200000 else max(50, trials // 5)
        rows = run_trials(n, dict(kw, count_unit=unit), tr, jobs=jobs, seed0=100000, opts=opts)
        s = summarize(rows)
        s.update(name=name, records=n, count_unit=unit, seconds=time.time() - t0)
        out.append(s)
        vd = lambda k: '/'.join(str(s['verdict_' + k][v]) for v in VERDICTS)
        md = lambda k: '/'.join(str(s['measured_' + k][v]) for v in VERDICTS[:3])
        if 'truth' in s:
            ms = '  '.join(f"{m} {v['z_mean']:+.2f}/{v['z_sd']:.2f}/{v['covered']}" for m, v in s['methods'].items())
            c = s['checks']
            print(f"{name}\n    bound in {s['with_bound']}/{s['trials']}; a {s['a_mean']:.3e} (sd {s['a_sd']:.1e}, se {s['se_mean']:.1e}), "
                  f"z {s['z_mean']:+.2f} sd {s['z_sd']:.2f}; lower bound below the truth in {s['covered']}/{s['with_bound']} "
                  f"= {100 * s['covered'] / s['with_bound']:.1f} %, median bound {s['low_median']:.3e}; upper above in {s['high_covered']}\n"
                  f"    verdicts 4096: {vd('4096')}  16384: {vd('16384')}; under the cross-check label: {md('4096')} and {md('16384')}; "
                  f"passes without the margin in truth: {s['false_pass']['4096']} and {s['false_pass']['16384']}; passes (or would-be "
                  f"passes) with the bound above the truth: {s['pass_above_truth']}\n"
                  f"    failed: methods disagree {s['disagree']}, fit {s['misfit']}, upper {s['over']}, stationarity {c['stationarity']}, "
                  f"factors {c['shared_factors']}, independence {c['independence']}, memory {c['memory']}, Gaussian "
                  f"{c['gaussian_4096']} and {c['gaussian_16384']}; methods (z mean/sd/covered): {ms}  [{s['seconds']:.0f} s]", flush=True)
        else:
            print(f"{name}\n    no bound in any trial: verdicts 4096 {vd('4096')}, 16384 {vd('16384')}; {rows[0]['why'].get('16384', [''])[0][:300]}",
                  flush=True)
        json.dump(out, open(os.path.join(OUT, f'coverage-unit{unit}.json'), 'w'), indent=1)
    return out

def need(trials, jobs, unit=2):
    """Records for a_low = 0.8 a at a = 5e-5 under 20x shared noise. Results go to need-unit<unit>.json."""
    os.makedirs(OUT, exist_ok=True)
    out = []
    print(f'records for a_low = 0.8 a (a = 5e-5, shared 20x, unequal sensitivities) with a count unit of {unit}, median of '
          f'{trials} trials', flush=True)
    for label, kw in (('N0 1024', dict(U)), ('N0 4096', dict(U, n0=4096)),
                      ('N0 1024, own flicker corner 65536', dict(U, own_flicker=65536.0)),
                      ('N0 4096, own flicker corner 65536', dict(U, n0=4096, own_flicker=65536.0)),
                      ('N0 1024, own flicker corner 4096', dict(U, own_flicker=4096.0)),
                      ('N0 1024, no refs', dict(NOREF, **U)), ('N0 4096, no refs', dict(NOREF, **U, n0=4096))):
        pts = []
        for n in (5000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000):
            tr = trials if n <= 100000 else max(8, trials // 4)
            rows = [r for r in run_trials(n, dict(kw, count_unit=unit), tr, jobs=jobs, seed0=200000) if r.get('a_low') is not None]
            if not rows:
                continue
            ratio = float(np.median([r['a_low'] for r in rows])) / 5e-5
            pts.append((n, ratio, float(np.median([r['se'] for r in rows])) / 5e-5))
            print(f'  {label}: {n:>8} records: a_low / a = {ratio:.3f}, se / a = {pts[-1][2]:.4f}', flush=True)
            if ratio > 0.9:
                break
        got = None
        for (n1, r1, _), (n2, r2, _) in zip(pts[:-1], pts[1:]):
            if r1 < 0.8 <= r2:
                got = int(round(math.exp(math.log(n1) + (0.8 - r1) / (r2 - r1) * (math.log(n2) - math.log(n1))), -2))
        print(f'{label}: a_low reaches 0.8 a at about {got} records', flush=True)
        out.append(dict(label=label, points=pts, records=got))
        json.dump(out, open(os.path.join(OUT, f'need-unit{unit}.json'), 'w'), indent=1)
    return out

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--coverage', action='store_true')
    ap.add_argument('--need', action='store_true')
    ap.add_argument('--trials', type=int, default=None)
    ap.add_argument('--jobs', type=int, default=max(1, min(8, (os.cpu_count() or 2) // 2)))
    ap.add_argument('--only', nargs='*', help='coverage: scenarios whose name contains one of these')
    ap.add_argument('--unit', type=int, default=2, help='the studies: ring periods per count, 2 behind the divider (default), '
                    '1 for direct mode (coverage then runs a smaller set)')
    ap.add_argument('--producer', metavar='DIR', help='the output directory of test_rosc_count.py, whose captures (written by '
                    'rosc_count.py itself) are analysed; given, it is an error if there are none (default: '
                    '_build/rosc-count/test, checked when present)')
    a = ap.parse_args()
    if a.coverage:
        coverage(a.trials or 1000, a.jobs, a.only, a.unit)
        sys.exit(0)
    if a.need:
        need(a.trials or 40, a.jobs, a.unit)
        sys.exit(0)
    sys.exit(0 if self_test(a.producer or os.path.join(ROOT, '_build', 'rosc-count', 'test'), bool(a.producer)) else 1)

if __name__ == '__main__':
    main()
