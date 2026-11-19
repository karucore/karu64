#!/usr/bin/env python3
"""Offline self-test of the burst part of getnoise_analyze.py; needs no board
and no simulation bench.

    make dbg-burst-analysis-test

Everything is generated here: lanes of the model of arXiv:2102.02196 with
known (F, D, sigma^2) (phase x += N(F, sigma^2) mod 1, bit = x < D), and the
Python copy of the RTL's characterisation model (noise_model.py), sampled
every P clocks by taking every P-th symbol of its clock-by-clock stream.
The figures that the checks look at are written to burst-analysis-figures.txt
in the output directory. The tolerances are those of HOLD and of the checks
themselves; they were set at about four standard deviations of what 25 seeds
gave, and the test passes with each of those seeds.

A. The pieces: the closed form of C_j against the Fourier series and its
   derivatives, the transform against a direct sum, the spectrum of a
   cosine, windows that stay inside runs.
B. Per-window fits on 16 bursts of 32768 symbols with sigma^2 = 1e-5 .. 1e-2
   at D = 0.5 and D = 0.485, and with 1e-6 and F next to 1/4 and 1/2: F,
   sigma^2 with all lags and from the lag ranges, their ranges, the pooled
   fit, no wander, no spur, the model's lines at F and 3F, no drift.
C. The RTL model copy with jitter = 10 at P = 1, 2, 4, .., 256: the fits
   against noise_model.parameters(10, period=P) where the autocorrelation is
   visible, a lower bound where it is not, sigma^2 proportional to clocks.
   Negative control: one capture with a wrong period in its sidecar. A bare
   file and --period; burst stamps that do not increase.
D. Wander: windows with different F. The pooled fit is too large, the
   windows' sigma^2 is right and is what the model figure uses; wander that
   two lanes share is flagged, wander of their own and a drift are not; the
   drift shows against the burst stamps. A ramp of F inside every window:
   the fit with all lags is raised, the smallest lag range much less.
E. Spectra: lines put on a lane (its duty cycle or its frequency modulated)
   are reported as spurs at their frequencies, on lanes with and without
   memory; the lane next to them has none.
F. Coherence: two lanes locked in phase are flagged; independent lanes of
   one F that hold their phase through a burst, with a new phase in every
   burst, are not (one pair, then six).
G. Captures with the same spacing (a burst capture at P = 256, a k = 1
   capture without a period, one at P = 64 and k = 4): agreement for one
   source, a flag for another.
H. Bursts joined into one run. Under their sidecar: refused (noticed).
   Without a sidecar: bursts as long as the window give the same windows and
   the same result (not noticed, not improved); shorter ones are not noticed
   and RAISE sigma^2 where it is small. That is a limit, and it is shown.
I. Negative controls on the analysis itself, by changing one constant or one
   step of the module: the slope of the agreement function; the comparison
   of a spectrum with the fitted model's; the number of independent segments
   behind a coherence; the choice of the sigma^2 that feeds the model
   figure; the lag ranges of the fits. Each is caught by a check of B to F.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, contextlib, hashlib, io, json, math, random, sys
from pathlib import Path

SRC = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True, help="output directory")
args = parser.parse_args()
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(SRC))
import noise_model
import getnoise_analyze as ga
checks, figures = 0, []

def check(cond, what):
    global checks
    checks += 1
    if not cond:
        (out / "burst-analysis-figures.txt").write_text("\n".join(figures) + "\n")
        raise SystemExit(f"FAIL burst analysis self-test check {checks}: {what}")

def note(text):
    figures.append(text)

# ------------------------------------------------------------ generators ----
def lane(rng, F, D, s2, n, duty=None, sweep=None):
    """n bits of the model. duty = (a, f): the threshold is D + a cos(2 pi f i);
    sweep = (a, f): the step is F + a cos(2 pi f i). Both are disturbances
    that the model does not have."""
    x, sd, bits, gauss, cos, tau = rng.random(), math.sqrt(s2), bytearray(n), rng.gauss, math.cos, 2 * math.pi
    if duty is None and sweep is None:
        for i in range(n):
            x = (x + gauss(F, sd)) % 1.0
            bits[i] = x < D
    else:
        (da, df), (sa, sf) = duty or (0.0, 0.0), sweep or (0.0, 0.0)
        for i in range(n):
            x = (x + gauss(F + sa * cos(tau * sf * i), sd)) % 1.0
            bits[i] = x < D + da * cos(tau * df * i)
    return bits

def locked(rng, F, D, s2, n, apart, slack):
    """Two lanes of one phase: the second is `apart` cycles behind, give or take N(0, slack^2) at every sample."""
    x, sd, a, b, gauss = rng.random(), math.sqrt(s2), bytearray(n), bytearray(n), rng.gauss
    for i in range(n):
        x = (x + gauss(F, sd)) % 1.0
        a[i] = x < D
        b[i] = (x + gauss(apart, slack)) % 1.0 < D
    return a, b

def write(name, runs, k=1, flags=True, **side):
    """Capture file and sidecar. runs: per run four lanes of bits, or the symbols as bytes."""
    packed = [r if isinstance(r, bytes) else bytes(a | b << 1 | c << 2 | d << 3 for a, b, c, d in zip(*r)) for r in runs]
    data = b"".join(bytes([r[0] | 0x80]) + r[1:] for r in packed) if flags else bytes([packed[0][0] | 0x80]) + b"".join(packed)[1:]
    path = out / f"{name}.bin"
    path.write_bytes(data)
    if side.pop("bare", False):
        path.with_suffix(".json").unlink(missing_ok=True)
    else:
        path.with_suffix(".json").write_text(json.dumps(dict(k=k, stored=len(data), run_lengths=[len(r) for r in packed] if flags else [len(data)],
                                                             sha256=hashlib.sha256(data).hexdigest(), **side)))
    return str(path)

def bursts(period, lengths, gap=250000):
    """Sidecar keys of a burst capture: bursts started one after the other, `gap` clocks apart."""
    stamps, t = [], 1000
    for n in lengths:
        stamps.append(t)
        t += n * period + gap
    return dict(kind="burst", period=period, clock_hz=75000000, burst_cycles=stamps)

def analysis(tag, files, *options):
    """Run the analysis; returns (exit status, its JSON or None, its text)."""
    where = out / f"analysis-{tag}"
    for f in where.glob("getnoise-analysis.*"):
        f.unlink()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        code = ga.main([*files, "--out", str(where), *options])
    done = (where / "getnoise-analysis.json").exists()
    return code, json.loads((where / "getnoise-analysis.json").read_text(), parse_constant=not_json) if done else None, \
        (where / "getnoise-analysis.txt").read_text() if done else ""

def not_json(constant):
    raise SystemExit(f"FAIL burst analysis self-test: {constant} in getnoise-analysis.json")

def fold(f):
    f %= 1.0
    return min(f, 1 - f)

def series(F, D, s2, j):
    """C_j of the model from its Fourier series, written out here once more."""
    c, n = (1 - 2 * D) ** 2, 1
    while True:
        e = math.exp(-2 * math.pi ** 2 * n * n * j * s2)
        if e < 1e-13:
            return c
        c += 8 / math.pi ** 2 * math.sin(math.pi * n * D) ** 2 / (n * n) * math.cos(2 * math.pi * n * j * F) * e
        n += 1

# ---------------------------------------------------------------- pieces ----
rng = random.Random(210202196)
worst = 0.0
for _ in range(2000):
    F, D, s2, j = rng.random() / 2, rng.choice([0.5, 0.485, 0.3, 0.62]), 10 ** rng.uniform(-6.5, -0.3), rng.choice([1, 2, 3, 7, 30, 500, 4000])
    worst = max(worst, abs(ga.model_lags(F, D, s2, [j])[0] - series(F, D, s2, j)))
check(worst < 1e-8, f"the closed form of C_j agrees with the Fourier series for sigma^2 from 3e-7 to 0.5 (worst {worst:.1e})")
check(abs(ga.model_lags(0.1, 0.625, 0.04, [1])[0] - (4 * (0.454492 - 0.625) + 1)) < 2e-6, "closed form against the paper's Fig. 3 (p11 = 0.454492)")
c, dF, dS = ga.model_lags(0.137, 0.485, 3e-4, [57], 0, True)
slope_F = (ga.model_lags(0.137 + 1e-8, 0.485, 3e-4, [57])[0] - ga.model_lags(0.137 - 1e-8, 0.485, 3e-4, [57])[0]) / 2e-8
slope_s = (ga.model_lags(0.137, 0.485, 3e-4 * math.exp(1e-4), [57])[0] - ga.model_lags(0.137, 0.485, 3e-4 * math.exp(-1e-4), [57])[0]) / 2e-4
check(abs(dF[0] - slope_F) < 1e-4 * abs(slope_F) and abs(dS[0] - slope_s) < 1e-4 * abs(slope_s), "its derivatives by F and by ln sigma^2 are those of the function")
x = [complex(rng.gauss(0, 1), rng.gauss(0, 1)) for _ in range(64)]
direct = [sum(v * complex(math.cos(2 * math.pi * k * t / 64), -math.sin(2 * math.pi * k * t / 64)) for t, v in enumerate(x)) for k in range(64)]
check(max(abs(a - b) for a, b in zip(ga.dft(x), direct)) < 1e-9, "the transform is the discrete Fourier transform")
tone = ga.power_spectrum([0.5 * math.cos(2 * math.pi * 0.2 * l) for l in range(1, 257)])
check(max(range(len(tone)), key=tone.__getitem__) == round(0.2 * 2 * (len(tone) - 1)) and min(tone) > -1e-3 * max(tone),
      "the spectrum of a cosine autocorrelation is one line at its frequency, with side lobes below a thousandth")
cuts = ga.window_cuts([70000, 100, 32768, 32769], 32768)
check([n for _, _, n in cuts] == [23333, 23333, 23334, 100, 32768, 16384, 16385] and all(s + n <= [70000, 100, 32768, 32769][r] for r, s, n in cuts),
      "runs are cut into equal windows of at most --window symbols, and no window leaves its run")

# ------------------------------------------------- B. per-window fits ----
N, W = 32768, 16
LANES = [(0.137, 1e-5), (0.291, 1e-4), (0.412, 1e-3), (0.068, 1e-2)]             # (F, sigma^2) per sample
# What the checks hold for 16 windows of 32768, by sigma^2: |F - true| of the windows' median; the factor by which
# the median of the fits with all lags, and the pooled fit, may be off; the same for the sigma^2 that is used, from
# the determined lag ranges; and for one window. They are about four standard deviations of what was seen over
# many seeds, so that a change of the seed does not fail them.
HOLD = {1e-6: (1e-5, 1.5, 1.35, 4.0), 1e-5: (3e-5, 1.7, 1.25, 3.5), 1e-4: (1e-4, 1.25, 1.12, 3.0), 1e-3: (3e-4, 1.08, 1.06, 1.4), 1e-2: (1e-3, 1.05, 1.05, 1.2)}
NEAR = {2: (3e-5, 2.0, 1.6, 5.0), 3: (1e-4, 1.25, 1.2, 3.0)}                    # F next to 1/4 and to 1/2: no lag range is better than another
ROOM = 1.5                                                                      # a range may miss the truth by this many of its standard errors

def off(value, truth, factor):
    return not truth / factor <= value <= truth * factor

def fit_errors(cap, truth, tag, windows=W, hold={}):
    """Per-window results of one capture against the true (F, D, sigma^2) per lane."""
    bad = []
    for l, (F, D, s2) in zip(cap["lanes"], truth):
        w, p, u, s, where = l["windows"], l["pooled"], l["sigma2_used"], l["spectrum"], f"{tag} lane {l['lane']}"
        tol_F, tol_all, tol_used, tol_one = hold.get(l["lane"], HOLD[s2])
        note(f"{where}: true F {fold(F):.6f} sigma^2 {s2:.0e} D {D} | {w['identifiable']}/{w['count']} windows, F {w.get('F_median', 0):.6f} "
             f"spread {ga.num(w.get('F_spread'))} (jitter {ga.num(w.get('F_expected_spread'))}), sigma^2 x{w.get('sigma2_median', 0) / s2:.3f} "
             f"(x{w.get('sigma2_low', 0) / s2:.2f} .. x{w.get('sigma2_high', 0) / s2:.2f}, scatter {w.get('sigma2_scatter', 0):.2f}) | "
             f"by lag " + " ".join(f"{r['lag_max']}:" + (f"x{r['sigma2'] / s2:.2f}~{r['scatter']:.2f}" if r["determined"] else f"[x{r['sigma2'] / s2:.2f}~{r['scatter']:.2f}]") for r in w.get("by_lag", []))
             + f" | pooled x{p.get('sigma2', 0) / s2:.3f} | used x{u['value'] / s2:.3f}, low x{u['low'] / s2:.3f} ({u['value_from']}, {u['low_from']}) | "
             f"fit {l['fit']['method']} | wander {l['wander']['indicated']} | spurs {s['spur_count']}, lines "
             + " ".join(f"{q['frequency']:.4f}:{q['harmonic']}" for q in s["lines"][:4]))
        if abs(l["ones_fraction"] - D) > 0.003: bad.append(f"{where} D")
        if w["count"] != windows or w["identifiable"] != windows or not w["usable"]: bad.append(f"{where} windows fitted"); continue
        room = math.exp(ROOM * w["se_ln"])
        if abs(w["F_median"] - fold(F)) > tol_F: bad.append(f"{where} F {w['F_median']:.6f}")
        if off(w["sigma2_median"], s2, tol_all): bad.append(f"{where} sigma^2 median x{w['sigma2_median'] / s2:.3f}")
        if not w["sigma2_low"] / room <= s2 <= w["sigma2_high"] * room: bad.append(f"{where} sigma^2 range misses the truth")
        if any(off(v, s2, tol_one) for v in w["sigma2"]): bad.append(f"{where} a window's sigma^2 is off by more than x{tol_one}")
        if not p["identifiable"] or off(p["sigma2"], s2, tol_all) or abs(p["F"] - fold(F)) > tol_F: bad.append(f"{where} pooled fit")
        if l["wander"]["indicated"] or not 0.67 < l["wander"]["sigma2_ratio"] < 1.5: bad.append(f"{where} wander {l['wander']['sigma2_ratio']:.2f}")
        if u["is_lower_bound"] or off(u["value"], s2, tol_used) or u["low"] > s2 * room or u["low"] > u["value"]: bad.append(f"{where} sigma^2 used x{u['value'] / s2:.3f}, low x{u['low'] / s2:.3f}")
        if windows >= ga.MIN_WANDER_WINDOWS and (not w["sigma2_best"] or u["value"] > w["sigma2_best"]["value"]
                                                 or (s2 < ga.SHORT_FIT_MIN and u["value_from"] != "windows")): bad.append(f"{where} not from the lag ranges")
        if l["fit"]["method"] != ("long-lag" if s2 < ga.SHORT_FIT_MIN else "short-lag") or not l["fit"]["identifiable"]: bad.append(f"{where} fit method")
        if abs(l["fit"]["F"] - fold(F)) > max(tol_F, 3e-4) or off(l["fit"]["sigma2"], s2, tol_all): bad.append(f"{where} the capture's fit")
    return bad

def spectrum_errors(cap, truth, tag, third=True):
    """A lane of the model: no spur, its strongest line at F, and 3F where the line is narrow."""
    bad = []
    for l, (F, D, s2) in zip(cap["lanes"], truth):
        s, where = l["spectrum"], f"{tag} lane {l['lane']}"
        if s["spur_count"] or any(q["spur"] for q in s["lines"]): bad.append(f"{where} spur at {s['spurs'][0]['frequency']:.4f}" if s["spurs"] else f"{where} spur")
        if not s["fitted"] or not s["lines"]: bad.append(f"{where} no line"); continue
        if s["lines"][0]["harmonic"] != 1 or abs(s["lines"][0]["frequency"] - fold(F)) > s["resolution"] + math.pi * s2: bad.append(f"{where} strongest line")
        if third and s2 <= 1e-4 and not any(q["harmonic"] == 3 and abs(q["frequency"] - fold(3 * F)) < s["resolution"] + 9 * math.pi * s2 for q in s["lines"]): bad.append(f"{where} no line at 3F")
    return bad

pure = {}
for D in (0.5, 0.485):
    truth = [(F, D, s2) for F, s2 in LANES]
    name = write(f"fit-d{D}", [[lane(rng, *p, N) for p in truth] for _ in range(W)], **bursts(1, [N] * W))
    code, res, text = analysis(f"fit-d{D}", [name])
    cap = pure[D] = res["captures"][0]
    check(code == 0 and res["format"] == "karu64-getnoise-analysis-3" and (cap["period"], cap["clocks"], cap["k"], cap["kind"], cap["runs"], cap["windows"]["count"]) == (1, 1, 1, "burst", W, W),
          f"D = {D}: the capture is read as {W} bursts at one clock per symbol, one window each")
    bad = fit_errors(cap, truth, f"D={D}")
    check(bad == [], f"D = {D}: per-window fits recover F and sigma^2 = 1e-5 .. 1e-2 within the tolerances of HOLD: {bad}")
    bad = spectrum_errors(cap, truth, f"D={D}")
    check(bad == [], f"D = {D}: no spur on a lane of the model, and its lines are labelled: {bad}")
    check(not any(c["flagged"] for c in cap["cross_spectrum"]) and not any(c["flagged"] for c in cap["shared_wander"]) and not cap["cross_lane"]["flagged_pairs"],
          f"D = {D}: independent lanes: no coherence, no shared wander and no pair flagged")
    check(all(l["wander"]["drift"] and abs(l["wander"]["drift"]["z"]) < 4 and abs(l["wander"]["drift"]["seconds"] - (cap["lanes"][0]["windows"]["start_cycle"][-1] - 1000) / 75e6) < 1e-9
              for l in cap["lanes"]), f"D = {D}: F against the bursts' clock stamps: no drift, over the time between the first and the last burst")
    check("Per window (16 windows" in text and "Spectrum per lane" in text and "Coherence between lanes" in text and "Shared wander" in text
          and "sigma^2 against the spacing in clocks" in text, "the report has the new parts")
est = [l["estimate"] for l in pure[0.5]["lanes"]]
check(all(e["model"]["sigma2"] == l["sigma2_used"]["value"] and e["model"]["sigma2_low"] == l["sigma2_used"]["low"] for e, l in zip(est, pure[0.5]["lanes"]))
      and not est[0]["fit"]["ok"] and "has not died out by lag 4096" in est[0]["fit"]["reasons"][0] and est[2]["fit"]["ok"] and est[3]["fit"]["ok"],
      "the model figure names its sigma^2; it is refused where the correlation outlasts an eighth of a window (1e-5) and accepted at 1e-3 and 1e-2")
code, res, text = analysis("fit-verdict", [str(out / "fit-d0.5.bin")], "--require-independent")
check(code == 0 and all(c["ok"] for c in res["verdict"]["checks"]) and sum("coherence" in c["what"] or "shared wander" in c["what"] for c in res["verdict"]["checks"]) == 2,
      "--require-independent is met by independent lanes, with a check for coherence and one for shared wander")
# 1e-6: the window is shorter than the coherence time (50000 samples)
truth = [(0.137, 0.5, 1e-6), (0.291, 0.485, 1e-6), (0.2501, 0.5, 1e-5), (0.4987, 0.485, 1e-4)]
code, res, text = analysis("fit-small", [write("fit-small", [[lane(rng, *p, N) for p in truth] for _ in range(W)], **bursts(1, [N] * W))])
bad = fit_errors(res["captures"][0], truth, "small", hold=NEAR) + spectrum_errors(res["captures"][0], truth, "small", False)
check(bad == [], f"sigma^2 = 1e-6, and F next to 1/4 and 1/2: {bad}")

# ------------------------------------------- C. the RTL model copy ----
CLOCKS, JITTER, PERIODS = 1 << 22, 10, (1, 2, 4, 8, 16, 32, 64, 128, 256)
stream = noise_model.NoiseModel(jitter=JITTER).upto(CLOCKS)
ONE = noise_model.parameters(JITTER)
check(len(stream) == CLOCKS and [round(F, 6) for F, _, _ in ONE] == [0.12, 0.2, 0.28, 0.36] and all(D == 0.5 for _, D, _ in ONE)
      and all(abs(s2 / ((m + 1) ** 2 * 8.138e-5) - 1) < 1e-3 for m, (_, _, s2) in enumerate(ONE)),
      "the characterisation model: F = 0.12, 0.20, 0.28, 0.36 and sigma^2 = 8.14e-5 (m+1)^2 per clock")
model_files = {}
for P in PERIODS:
    kept = stream[::P]                                                          # every P-th clock: genuine decimation
    length = max(4096, min(N, len(kept) // 16))
    count = min(16, len(kept) // length)
    starts = [i * (len(kept) // count) for i in range(count)]
    model_files[P] = write(f"model-p{P}", [kept[s:s + length] for s in starts], kind="burst", period=P, clock_hz=75000000, burst_cycles=[s * P for s in starts])
code, res, text = analysis("model", list(model_files.values()))
check(code == 0 and [(c["period"], c["clocks"]) for c in res["captures"]] == [(P, P) for P in PERIODS] and res["captures"][-1]["runs"] == 4
      and res["captures"][0]["longest_run"] == N, "nine captures, sorted by their spacing in clocks; 16 bursts of 32768 at P = 1, 4 of 4096 at P = 256")

def model_errors(res):
    """The fits against noise_model.parameters. Visible: the model's C_1 or C_2 is six standard errors from
    its mean or more. Then sigma^2 within 10 % (15 % above 0.06 per sample), and F by sigma^2 per sample:
    below 0.02 within six times sqrt(sigma^2 / symbols), the scatter of the capture's mean frequency, or
    1e-4; below 0.06 within 0.03; above, F is not determined. Not visible: under three standard errors;
    then a lower bound below the true sigma^2 and no F."""
    bad, seen = [], [0, 0, 0]
    for cap in res["captures"]:
        for l, (F, D, s2) in zip(cap["lanes"], noise_model.parameters(JITTER, period=cap["period"])):
            f, u, w, where = l["fit"], l["sigma2_used"], l["windows"], f"P={cap['period']} lane {l['lane']}"
            signal = max(abs(series(F, D, s2, j) - (1 - 2 * D) ** 2) for j in (1, 2)) * math.sqrt(cap["symbols"])
            tol_F, tol_s = (max(1e-4, 6 * math.sqrt(s2 / cap["symbols"])), 0.10) if s2 < 2e-2 else (0.03, 0.10) if s2 < 6e-2 else (1.0, 0.15)
            note(f"{where}: true F {fold(F):.4f} sigma^2 {s2:.3e}, signal {signal:.1f} | fit {f['method']} "
                 + (f"F {f['F']:.5f} sigma^2 x{f['sigma2'] / s2:.3f}" if f["identifiable"] else f">= x{f['sigma2'] / s2:.3f}")
                 + f" | windows {w['identifiable']}/{w['count']}" + (f" x{w['sigma2_median'] / s2:.3f} (x{w['sigma2_low'] / s2:.2f} .. x{w['sigma2_high'] / s2:.2f})" if w["identifiable"] else "")
                 + f" | used x{u['value'] / s2:.3f}, low x{u['low'] / s2:.3f} ({u['value_from']})")
            if abs(l["ones_fraction"] - D) > 0.01: bad.append(f"{where} D")
            if l["spectrum"]["spur_count"] or l["wander"]["indicated"]: bad.append(f"{where} spur or wander")
            room = math.exp(ROOM * w["se_ln"]) if w["identifiable"] else 1.0
            if u["low"] > s2 * room: bad.append(f"{where} lower end x{u['low'] / s2:.3f} above the truth")
            if signal >= 6:
                seen[0] += 1
                if not f["identifiable"] or u["is_lower_bound"]: bad.append(f"{where} not fitted"); continue
                if abs(f["F"] - fold(F)) > tol_F: bad.append(f"{where} F {f['F']:.5f}")
                if abs(f["sigma2"] / s2 - 1) > tol_s or abs(u["value"] / s2 - 1) > tol_s: bad.append(f"{where} sigma^2 x{f['sigma2'] / s2:.3f}, used x{u['value'] / s2:.3f}")
                if w["usable"] and (abs(w["sigma2_median"] / s2 - 1) > tol_s or abs(w["F_median"] - fold(F)) > tol_F or not w["sigma2_low"] / room <= s2 <= w["sigma2_high"] * room):
                    bad.append(f"{where} windows x{w['sigma2_median'] / s2:.3f}")
            elif signal < 3:
                seen[1] += 1
                if f["identifiable"] or f["F"] is not None or not u["is_lower_bound"] or not 0.03 < u["value"] < s2 or w["identifiable"]:
                    bad.append(f"{where} should be a lower bound")
            else:
                seen[2] += 1
    for row, (F, D, s2) in zip(res["decimation"], ONE):
        note(f"lane {row['lane']}: sigma^2 per clock x{row['sigma2_per_clock'] / s2:.3f} of the truth, log-log slope {row['exponent']:.3f}, by clocks "
             + " ".join(f"{p['clocks']}:{p['ratio']:.2f}" for p in row["points"]))
        if not row["linear"]: bad.append(f"lane {row['lane']} not linear in clocks")
        if abs(row["sigma2_per_clock"] / s2 - 1) > 0.08: bad.append(f"lane {row['lane']} sigma^2 per clock")
        if abs(row["exponent"] - 1) > 0.05: bad.append(f"lane {row['lane']} exponent")
        if any(p["clocks"] != p["period"] * p["k"] for p in row["points"] + row["predicted"]): bad.append(f"lane {row['lane']} clocks")
    return bad, seen
bad, seen = model_errors(res)
check(bad == [], f"the RTL model copy at P = 1 .. 256: {bad}")
check(seen[0] >= 30 and seen[1] >= 2 and sum(seen) == 36, f"of 36 lane captures {seen[0]} have a visible autocorrelation, {seen[1]} have none, {seen[2]} are in between")
rows = res["decimation"]
check([len(r["points"]) for r in rows] == [9, 9, 8, 7] and all(len(r["predicted"]) == 9 and r["sigma2_per_raw_sample"] is None for r in rows),
      "sigma^2 against clocks: a lower bound is not a point of the line; no figure per raw sample when the periods differ")
check(all(abs(r["predicted"][-1]["sigma2"] / (256 * s2) - 1) < 0.08 for r, (_, _, s2) in zip(rows, ONE))
      and all(l["sigma2_used"]["is_lower_bound"] and l["sigma2_used"]["value"] < 0.5 * 256 * s2 for l, (_, _, s2) in list(zip(res["captures"][-1]["lanes"], ONE))[2:]),
      "the line gives sigma^2 at 256 clocks within 8 %, where the capture at 256 clocks itself has only a bound under half of it (lanes 2 and 3)")
check(not any(c["flagged"] for cap in res["captures"] for c in cap["cross_spectrum"] + cap["shared_wander"]) and not any(cap["cross_lane"]["flagged_pairs"] for cap in res["captures"]),
      "the model's lanes are independent: nothing flagged at any period")
check(res["agreement"] == [] and "captures with the same spacing" not in text, "no two captures share a spacing: nothing to compare")

# negative control: the P = 4 capture with period 16 in its sidecar
side = json.loads((out / "model-p4.json").read_text())
(out / "model-mislabel.bin").write_bytes((out / "model-p4.bin").read_bytes())
(out / "model-mislabel.json").write_text(json.dumps(dict(side, period=16)))
code, wrong, _ = analysis("mislabel", [model_files[1], model_files[2], str(out / "model-mislabel.bin")])
check(code == 0 and [c["clocks"] for c in wrong["captures"]] == [1, 2, 16] and all(r["linear"] is False and r["exponent"] < 0.7 for r in wrong["decimation"]),
      f"a capture with a wrong period in its sidecar breaks the proportionality on every lane: slopes {[round(r['exponent'], 2) for r in wrong['decimation']]}")
code, right, _ = analysis("mislabel-not", [model_files[1], model_files[2], model_files[4]])
check(all(r["linear"] and abs(r["exponent"] - 1) < 0.1 for r in right["decimation"]), "and the same three captures with the right period do not")
# a bare file takes its period from --period, and 256 without it
(out / "model-bare.bin").write_bytes((out / "model-p4.bin").read_bytes())
(out / "model-bare.json").unlink(missing_ok=True)
check(analysis("bare", [str(out / "model-bare.bin")])[0] == 2, "a bare file needs --k")
code, a, _ = analysis("bare", [str(out / "model-bare.bin")], "--k", "1")
code, b, _ = analysis("bare-p", [str(out / "model-bare.bin")], "--k", "1", "--period", "4")
check((a["captures"][0]["period"], a["captures"][0]["clocks"], b["captures"][0]["period"], b["captures"][0]["clocks"]) == (256, 256, 4, 4)
      and abs(b["decimation"][0]["sigma2_per_clock"] / ONE[0][2] - 1) < 0.15 and b["decimation"][0]["sigma2_per_raw_sample"] == 4 * b["decimation"][0]["sigma2_per_clock"],
      "without a sidecar the period is 256 clocks unless --period says otherwise")
side["burst_cycles"][3] = side["burst_cycles"][2]
(out / "model-stamps.bin").write_bytes((out / "model-p4.bin").read_bytes())
(out / "model-stamps.json").write_text(json.dumps(side))
check(analysis("stamps", [str(out / "model-stamps.bin")])[0] == 2, "burst stamps that do not increase are refused")

# ------------------------------------------------------- D. wander ----
NW, WW, S2W = 8192, 32, 1e-4
together, alone = [rng.gauss(0, 8e-4) for _ in range(WW)], [rng.gauss(0, 8e-4) for _ in range(WW)]
runs = [[lane(rng, 0.137 + together[i], 0.5, S2W, NW), lane(rng, 0.291 - together[i], 0.5, S2W, NW), lane(rng, 0.412 + alone[i], 0.5, S2W, NW),
         lane(rng, 0.068 + 2e-3 * i / WW, 0.5, S2W, NW)] for i in range(WW)]
wander_file = write("wander", runs, **bursts(1, [NW] * WW))
code, res, text = analysis("wander", [wander_file])
cap = res["captures"][0]
for l in cap["lanes"]:
    w, u, d = l["windows"], l["sigma2_used"], l["wander"]
    note(f"wander lane {l['lane']}: windows x{w['sigma2_median'] / S2W:.3f} (x{w['sigma2_low'] / S2W:.2f} .. x{w['sigma2_high'] / S2W:.2f}), pooled x{l['pooled']['sigma2'] / S2W:.2f}, "
         f"ratio {d['sigma2_ratio']:.2f}, F spread {w['F_spread']:.2e} / {w['F_expected_spread']:.2e} = {d['F_spread_ratio']:.1f}, indicated {d['indicated']}, "
         f"used x{u['value'] / S2W:.3f} low x{u['low'] / S2W:.3f} ({u['value_from']}, {u['low_from']}), drift {d['drift']['total']:+.2e} z {d['drift']['z']:+.1f}")
three = cap["lanes"][:3]
check(all(l["pooled"]["sigma2"] > 1.5 * S2W and l["wander"]["sigma2_ratio"] > 1.5 for l in three),
      f"F differs from window to window: the pooled sigma^2 is too large, x{[round(l['pooled']['sigma2'] / S2W, 2) for l in three]}")
check(all(l["windows"]["identifiable"] == WW and not off(l["windows"]["sigma2_median"], S2W, 1.3)
          and l["windows"]["sigma2_low"] / math.exp(ROOM * l["windows"]["se_ln"]) <= S2W <= l["windows"]["sigma2_high"] * math.exp(ROOM * l["windows"]["se_ln"])
          for l in cap["lanes"]), "the windows' median sigma^2 is right within a factor 1.3, and its range holds the truth")
check(all(l["wander"]["indicated"] and l["wander"]["F_spread_ratio"] > ga.WANDER_SPREAD and 3.5e-4 < l["windows"]["F_spread"] < 1.6e-3 for l in three),
      "wander is reported: the spread of F is 8e-4 as put in, several times what the jitter gives")
check(all(l["sigma2_used"]["value_from"] == "windows" and not off(l["sigma2_used"]["value"], S2W, 1.15) and l["sigma2_used"]["low"] <= S2W * math.exp(ROOM * l["windows"]["se_ln"])
          and l["estimate"]["model"]["sigma2"] == l["windows"]["sigma2_best"]["value"] and l["estimate"]["model"]["sigma2_from"] == "windows" for l in three),
      "the model figure uses the windows' sigma^2, not the pooled one")
drift = cap["lanes"][3]["wander"]["drift"]
check(abs(drift["total"] / (2e-3 * (WW - 1) / WW) - 1) < 0.15 and drift["z"] > 6 and abs(drift["per_second"] * drift["seconds"] - drift["total"]) < 1e-12
      and all(abs(l["wander"]["drift"]["z"]) < 4 for l in three),
      f"a frequency that rises by 2e-3 over the capture shows as drift against the burst stamps ({drift['total']:+.2e}, z {drift['z']:.1f}); the others have none")
shared = {tuple(c["lanes"]): c for c in cap["shared_wander"]}
note("shared wander: " + ", ".join(f"{a},{b}: r {c['correlation']:+.2f} z {c['z']:.1f}" for (a, b), c in shared.items()) + f"; flagged above |r| {shared[0, 1]['detectable']:.2f}")
check(shared[0, 1]["flagged"] and shared[0, 1]["correlation"] < -0.8 and [k for k, c in shared.items() if c["flagged"]] == [(0, 1)] and all(c["judged"] for c in shared.values()),
      "wander that two lanes share (here with opposite signs) is flagged; a lane with wander of its own and one that drifts are not")
check("wander" in text and "YES" in text.split("Shared wander")[1].split("Empirical")[0], "the report says so")
code, res, text = analysis("wander-verdict", [wander_file], "--require-independent")
failed = [c["what"] for c in res["verdict"]["checks"] if not c["ok"]]
check(code == 1 and len(failed) == 1 and "shared wander" in failed[0] and "0,1 flagged" in failed[0], f"--require-independent fails on shared wander alone: {failed}")

# limit: a frequency that moves inside every window, here half a cosine from F + a to F - a over the window
RAMPS = (0.0, 1e-4, 5e-4, 2e-3)
runs = [[lane(rng, F, 0.5, S2W, NW, sweep=(a, 0.5 / NW)) for (F, _), a in zip(LANES, RAMPS)] for _ in range(16)]
code, res, text = analysis("ramp", [write("ramp", runs, **bursts(1, [NW] * 16))])
ramp = res["captures"][0]["lanes"]
inside, least = [l["windows"]["sigma2_median"] / S2W for l in ramp], [l["sigma2_used"]["value"] / S2W for l in ramp]
note("a ramp of F inside every window, by 2 x " + ", ".join(f"{a:g}" for a in RAMPS) + ": sigma^2 of the fits with all lags " + " ".join(f"x{v:.2f}" for v in inside)
     + ", used " + " ".join(f"x{v:.2f}" for v in least) + ", all lags over smallest " + " ".join(f"x{l['wander']['inside_ratio']:.2f}" for l in ramp)
     + "; wander indicated " + str([l["wander"]["indicated"] for l in ramp]))
check(abs(inside[0] - 1) < 0.2 and abs(inside[1] - 1) < 0.25 and inside[2] > 1.15 and inside[3] > 3,
      f"wander inside a window raises the sigma^2 of a fit with all lags once it exceeds what the jitter gives: x{[round(v, 2) for v in inside]}")
check(all(0.85 < v < 1.1 for v in least[:3]) and all(l["sigma2_used"]["value_from"] == "windows" for l in ramp[1:])
      and ramp[2]["wander"]["inside_ratio"] > 1.15 and ramp[3]["wander"]["inside_ratio"] > 2.5 and ramp[3]["wander"]["indicated"] and not ramp[0]["wander"]["indicated"],
      f"the model figure uses the smallest sigma^2 over the lag ranges of the fits, which the ramps of 2e-4 and 1e-3 leave alone (x{[round(v, 2) for v in least]}); the report shows the growth with the lag")
check(1.1 < least[3] < 1.5, f"limit: a ramp of 4e-3 inside every window, 36 times what the jitter gives, still raises it, by x{least[3]:.2f} instead of x{inside[3]:.2f}")

# ----------------------------------------------------- E. spectra ----
NS, WS = 32768, 8
runs = [[lane(rng, 0.137, 0.5, 1e-4, NS), lane(rng, 0.291, 0.5, 1e-4, NS, sweep=(6e-3, 0.02)), lane(rng, 0.412, 0.5, 1e-2, NS, duty=(0.05, 0.0731)),
         lane(rng, 0.3, 0.5, 0.5, NS, duty=(0.03, 0.2113))] for _ in range(WS)]
code, res, text = analysis("spur", [write("spur", runs, **bursts(1, [NS] * WS))])
spec = [l["spectrum"] for l in res["captures"][0]["lanes"]]
for i, s in enumerate(spec):
    note(f"spur lane {i}: floor {s['floor']:.4f}, fitted {s['fitted']}, threshold x{s['spur_threshold']:.2f}, {s['spur_count']} spurs: "
         + " ".join(f"{q['frequency']:.4f} (x{q['height']:.3g}, x{q['over_model']:.3g} over the model)" for q in s["spurs"][:6]))
near = lambda s, f: any(abs(q["frequency"] - f) <= s["resolution"] for q in s["spurs"])
check(spec[0]["spur_count"] == 0 and spec[0]["lines"][0]["harmonic"] == 1, "a lane of the model next to disturbed ones has no spur")
check(near(spec[1], 0.291 - 0.02) and near(spec[1], 0.291 + 0.02) and all(any(abs(q["frequency"] - fold(n * 0.291 + m * 0.02)) < 2 * spec[1]["resolution"] + math.pi * n * n * 1e-4
      for n in (1, 3, 5) for m in range(-3, 4) if m) for q in spec[1]["spurs"]),
      "a frequency swept by 0.02 cycles per sample: spurs at F - 0.02 and F + 0.02, and every spur is such a sideband of F, 3F or 5F")
check(spec[2]["fitted"] and spec[2]["spurs"] and abs(spec[2]["spurs"][0]["frequency"] - 0.0731) <= spec[2]["resolution"] and spec[2]["spur_count"] <= 3,
      "a duty cycle modulated at 0.0731 on a lane with memory (sigma^2 = 0.01): the strongest spur is there")
check(not spec[3]["fitted"] and spec[3]["spur_count"] == 1 and abs(spec[3]["spurs"][0]["frequency"] - 0.2113) <= spec[3]["resolution"],
      "the same at 0.2113 on a lane without memory: one spur, at that frequency")
check(any(q["spur"] for q in spec[3]["lines"]) and "SPURS" in text and "(x" in text, "spurs are among the lines listed, and in the report")
swept = res["captures"][0]["lanes"][1]["windows"]["sigma2_median"] / 1e-4
note(f"spur lane 1: sigma^2 of the windows x{swept:.2f} of the jitter put in")
check(0.8 < swept < 1.3, f"the fast sweep leaves the windows' sigma^2 nearly as it was (x{swept:.2f}): the spurs are what shows it")

# --------------------------------------------------- F. coherence ----
NC, WC = 8192, 16
runs = []
for _ in range(WC):
    a, b = locked(rng, 0.21, 0.5, 1e-5, NC, 0.3, 0.02)
    runs.append([a, b, lane(rng, 0.33, 0.5, 1e-7, NC), lane(rng, 0.33, 0.5, 1e-7, NC)])
locked_file = write("locked", runs, **bursts(1, [NC] * WC))
code, res, text = analysis("locked", [locked_file])
cap = res["captures"][0]
coh = {tuple(c["lanes"]): c for c in cap["cross_spectrum"]}
note("coherence: " + ", ".join(f"{a},{b}: {c['max_coherence']:.3f} at {c['frequency']:.4f} against {c['threshold']:.3f} ({c['segments']:.0f} {c['segments_are']})" for (a, b), c in coh.items()))
check(coh[0, 1]["flagged"] and coh[0, 1]["max_coherence"] > 0.9 and abs(coh[0, 1]["frequency"] - 0.21) < 0.004 and abs(abs(coh[0, 1]["phase"]) - 0.3) < 0.02,
      f"two lanes locked 0.3 cycles apart: coherence {coh[0, 1]['max_coherence']:.3f} at their frequency, phase {coh[0, 1]['phase']:+.3f}")
check(coh[2, 3]["judged"] and not coh[2, 3]["flagged"] and coh[2, 3]["segments"] == WC and coh[2, 3]["segments_are"] == "windows" and coh[2, 3]["max_coherence"] < 0.6 * coh[2, 3]["threshold"],
      f"two independent lanes of the same F that hold their phase through a burst (sigma^2 = 1e-7), with a new phase in every burst: "
      f"{coh[2, 3]['max_coherence']:.3f} against a threshold of {coh[2, 3]['threshold']:.3f} for {WC} windows")
check([k for k, c in coh.items() if c["flagged"]] == [(0, 1)] and all(abs(l["windows"]["F_median"] - F) < 1e-4 for l, F in zip(cap["lanes"], (0.21, 0.21, 0.33, 0.33))),
      "no other pair is flagged, and all four lanes are fitted at their F")
check(not {tuple(c["lanes"]): c for c in cap["cross_lane"]["pairs"]}[2, 3]["flagged"], "the fixed-lag statistic does not flag the independent pair either")
code, res, text = analysis("locked-verdict", [locked_file], "--require-independent")
failed = [c["what"] for c in res["verdict"]["checks"] if not c["ok"]]
check(code == 1 and any("coherence" in f and "0,1 flagged" in f for f in failed) and not any("2,3" in f for f in failed), f"--require-independent fails on the coherence: {failed}")
# the hard case six times over: four independent lanes, all of one F, each holding its phase through a burst
same_file = write("same-f", [[lane(rng, 0.33, 0.5, 1e-7, NC) for _ in range(4)] for _ in range(WC)], **bursts(1, [NC] * WC))
code, res, text = analysis("same-f", [same_file], "--require-independent")
same = res["captures"][0]["cross_spectrum"]
note("four independent lanes of one F: coherence " + " ".join(f"{c['max_coherence']:.3f}" for c in same) + f" against {same[0]['threshold']:.3f}; fixed-lag |z| "
     + " ".join(f"{c['max_abs_z']:.1f}" for c in res["captures"][0]["cross_lane"]["pairs"]))
check(all(c["judged"] and not c["flagged"] and c["segments"] == WC for c in same) and max(c["max_coherence"] for c in same) > 2 / WC
      and not res["captures"][0]["cross_lane"]["flagged_pairs"] and not any(c["flagged"] for c in res["captures"][0]["shared_wander"]),
      f"four independent lanes of one F: none of the six pairs is flagged, with coherences up to {max(c['max_coherence'] for c in same):.3f} at F or a multiple of it")
failed = [c["what"] for c in res["verdict"]["checks"] if not c["ok"]]
check(code == 1 and len(failed) == 1 and "would have been flagged" in failed[0],
      f"--require-independent is still not met, for want of data: {WC} bursts that hold their phase cannot show a correlation of 0.05 ({failed})")

# --------------------------------------- G. captures of one spacing ----
ONE_SOURCE = [(0.28, 0.485, 0.021), (0.20, 0.497, 0.083), (0.32, 0.492, 0.19), (0.16, 0.493, 0.33)]      # per 256 clocks
OTHER = [(0.28, 0.455, 0.021), (0.20, 0.497, 0.040), (0.32, 0.492, 0.19), (0.16, 0.493, 0.33)]
files = [write("same-burst", [[lane(rng, *p, 8192) for p in ONE_SOURCE] for _ in range(8)], **bursts(256, [8192] * 8)),
         write("same-k1", [[lane(rng, *p, 65536) for p in ONE_SOURCE]]),
         write("same-other", [[lane(rng, *p, 65536) for p in OTHER]], k=4, period=64)]
code, res, text = analysis("same", files)
pairs = {tuple(sorted(Path(f).stem for f in p["files"])): p for p in res["agreement"]}
for names, p in pairs.items():
    note(f"agreement {names[0]} / {names[1]}: " + ", ".join(f"lane {l['lane']} max |z| {l['max_abs_z']:.1f}" for l in p["lanes"]))
check(code == 0 and len(pairs) == 3 and all(c["clocks"] == 256 for c in res["captures"]) and {(c["period"], c["k"]) for c in res["captures"]} == {(256, 1), (64, 4)},
      "three captures at 256 clocks per symbol: a burst capture at P = 256, a k = 1 capture without a period, one at P = 64 and k = 4")
check(not pairs["same-burst", "same-k1"]["flagged"] and all(l["compared"] and l["max_abs_z"] < 4.5 and len(l["z_autocorrelation"]) == 8 for l in pairs["same-burst", "same-k1"]["lanes"]),
      "a burst capture and a k = 1 capture of one source agree: ones fraction and C_1..C_8 within 4.5 combined standard errors")
other = pairs["same-burst", "same-other"]
check(other["flagged"] and [l["flagged"] for l in other["lanes"]] == [True, True, False, False] and abs(other["lanes"][0]["z_ones_fraction"]) > 4.5
      and abs(other["lanes"][1]["z_autocorrelation"][0]) > 4.5 and abs(other["lanes"][1]["z_ones_fraction"]) < 4.5 and pairs["same-k1", "same-other"]["flagged"]
      and other["clocks"] == 256,
      "a source with another duty cycle on lane 0 and another sigma^2 on lane 1 is flagged on those lanes, by the ones fraction and by C_1")
check("DIFFERENT" in text and "no difference flagged" in text and len({c["label"] for c in res["captures"]}) == 3, "the report names the three pairs, and the captures by file where their labels would be equal")

# ----------------------------------------------- H. joined bursts ----
NJ, WJ = 4096, 32
truth = [(F, 0.5, s2) for F, s2 in LANES]
runs = [[lane(rng, *p, NJ) for p in truth] for _ in range(WJ)]
apart = write("joined-not", runs, **bursts(1, [NJ] * WJ))
write("joined-flags", runs, flags=False, bare=True)
(out / "joined-flags.json").write_text((out / "joined-not.json").read_text())
check(analysis("joined-flags", [str(out / "joined-flags.bin")])[0] == 2, "bursts joined into one run under their sidecar are refused (noticed)")
write("joined-side", runs, flags=False, **bursts(1, [NJ] * WJ))
check(analysis("joined-side", [str(out / "joined-side.bin")])[0] == 2, "and so is a sidecar of one run that still has a stamp for every burst (noticed)")
bare = write("joined-bare", runs, flags=False, bare=True)
code, sep, _ = analysis("joined-not", [apart], "--window", str(NJ))
code, one, _ = analysis("joined-bare-w", [bare], "--k", "1", "--period", "1", "--window", str(NJ))
both = list(zip(sep["captures"][0]["lanes"], one["captures"][0]["lanes"]))
check(one["captures"][0]["runs"] == 1 and sep["captures"][0]["runs"] == WJ and one["captures"][0]["windows"]["count"] == WJ and
      all(a["windows"]["sigma2"] == b["windows"]["sigma2"] and a["windows"]["F"] == b["windows"]["F"] and a["windows"]["by_lag"] == b["windows"]["by_lag"] and a["pooled"] == b["pooled"]
          for a, b in both) and all(a["sigma2_used"] == b["sigma2_used"] for a, b in both[:3])
      and all(abs(b["sigma2_used"][key] / a["sigma2_used"][key] - 1) < 0.01 for a, b in both for key in ("value", "low")),
      "without a sidecar, bursts as long as --window are cut where they were joined: the same windows and fits, and the same sigma^2 "
      "(within 1 % where the short-lag fit, which is made over the whole run, has a part): not noticed, not improved")
code, mixed, _ = analysis("joined-bare", [bare], "--k", "1", "--period", "1", "--window", str(4 * NJ))
four = list(zip(sep["captures"][0]["lanes"], mixed["captures"][0]["lanes"]))
rise = [b["sigma2_used"]["value"] / a["sigma2_used"]["value"] for a, b in four]
whole = [b["windows"]["sigma2_median"] / a["windows"]["sigma2_median"] for a, b in four]
note("joined bursts of 4096, four to a window, against the bursts kept apart: sigma^2 with all lags " + " ".join(f"x{r:.2f}" for r in whole)
     + ", used " + " ".join(f"x{r:.2f}" for r in rise) + ", all lags over smallest " + " ".join(f"x{b['wander']['inside_ratio']:.2f}" for _, b in four)
     + "; wander indicated " + str([b["wander"]["indicated"] for _, b in four]) + ", fit refused " + str([not b["estimate"]["fit"]["ok"] for _, b in four]))
check(mixed["captures"][0]["windows"]["count"] == WJ // 4 and whole[0] > 1.2 and rise[0] > 1.1 and all(r < 1.1 for r in rise[2:] + whole[2:])
      and not any(b["wander"]["indicated"] for _, b in four),
      f"limit: shorter bursts joined without a sidecar are not noticed, and where sigma^2 is small it comes out larger: at 1e-5 x{whole[0]:.2f} with all lags "
      f"and x{rise[0]:.2f} as used, from the short lag ranges; at 1e-3 and 1e-2 nothing changes")

# --------------------------------- I. negative controls on the module ----
control, control_truth = str(out / "fit-d0.5.bin"), [(F, 0.5, s2) for F, s2 in LANES]             # a capture of part B, which passed there
def with_change(name, value, tag, files, *options):
    """The analysis with one attribute of the module changed."""
    saved = getattr(ga, name)
    setattr(ga, name, value)
    try:
        return analysis(tag, files, *options)
    finally:
        setattr(ga, name, saved)
code, broken, _ = with_change("KINK", 3.0, "control-kink", [control])
bad = fit_errors(broken["captures"][0], control_truth, "KINK=3")
check(sum("sigma^2 median" in e for e in bad) >= 3, f"a wrong slope of the agreement function (3 for 4) misses sigma^2: {bad[:4]}")
whole_spectrum = ga.lane_spectrum
code, broken, _ = with_change("lane_spectrum", lambda rho, ref, fitted, pairs, harmonics: whole_spectrum(rho, ref, False, pairs, harmonics), "control-model", [control])
bad = spectrum_errors(broken["captures"][0], control_truth, "no model")
check(sum("spur" in e for e in bad) == 4, f"a spectrum that is not compared with the fitted model's reports the model's own lines as spurs: {bad[:4]}")
code, broken, _ = with_change("segment_count", lambda symbols, windows, top, quiet: symbols / (2 * sum(ga.lag_window(top)) - 1), "control-segments", [same_file])
wrong = broken["captures"][0]["cross_spectrum"]
check(sum(c["flagged"] for c in wrong) >= 2 and [c["max_coherence"] for c in wrong] == [c["max_coherence"] for c in same] and wrong[0]["segments"] > 10 * WC,
      f"counting pieces of the lag window as independent where the lanes remember ({wrong[0]['segments']:.0f} for {WC} windows) flags "
      f"{sum(c['flagged'] for c in wrong)} of the six independent pairs")
def pooled_only(f, pooled, w):
    return dict(value=pooled["sigma2"], low=pooled["sigma2_low"], value_from="pooled fit", low_from="pooled fit", is_lower_bound=False, candidates={})
code, broken, _ = with_change("choose", pooled_only, "control-choose", [wander_file])
check(all(l["sigma2_used"]["value"] > 1.5 * S2W and l["estimate"]["model"]["sigma2"] > 1.5 * S2W for l in broken["captures"][0]["lanes"][:3]),
      "feeding the model figure from the pooled fit takes the inflated sigma^2 under wander: the check of part D catches it")
code, broken, _ = with_change("STEP_SCATTER", 0.0, "control-steps", [str(out / "ramp.bin")])
without = [l["sigma2_used"]["value"] / S2W for l in broken["captures"][0]["lanes"]]
check(without[2] > 1.15 and without[3] > 3 and all(l["windows"]["sigma2_best"] is None for l in broken["captures"][0]["lanes"]),
      f"without the lag ranges of the fits the model figure takes the sigma^2 that wander inside a window has raised (x{[round(v, 2) for v in without]}): the check of part D catches it")

(out / "burst-analysis-figures.txt").write_text("\n".join(figures) + "\n")
# A constant capture: no lane has variance, so independence cannot be
# measured, and --require-independent must not pass for it (review of 2026-11-18).
const_path = out / "constant.bin"
const = bytes([0x85]) + bytes([0x05]) * 32767
const_path.write_bytes(const)
const_path.with_suffix(".json").write_text(json.dumps(dict(kind="burst", period=1, k=1, stored=len(const), run_lengths=[len(const)],
                                                           sha256=hashlib.sha256(const).hexdigest())))
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    code = ga.main([str(const_path), "--out", str(out / "analysis-constant"), "--require-independent"])
text = (out / "analysis-constant" / "getnoise-analysis.txt").read_text()
check(code == 1 and "UNMEASURABLE pairs" in text and "every lane pair measurable (not:" in text,
      "a constant capture fails --require-independent: its lane pairs are unmeasurable")
print(f"burst analysis self-test: PASS ({checks} checks)")
sys.exit(0)
