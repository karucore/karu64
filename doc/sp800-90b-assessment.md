# SP 800-90B assessment of the Karu64 Zkr entropy source

Status: **assessment of the current design, 2026-11-20.** The entropy
block `rtl/karu_entropy.v` and the ring-oscillator noise source of the
VCU118 debug image, bitstream `ddb168e1…`, board-tested on 2026-11-20
([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)). The board data is from
that bitstream and, as further data on the same noise source, from the two
bitstreams before it (§2). Analysed with NIST's SP 800-90B tools. This is an
engineering self-assessment against
[NIST SP 800-90B](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-90B.pdf)
(January 2018), not a validation: no accredited laboratory has been
involved, and the FPGA ring oscillators are a stand-in for an ASIC noise
source.

## 1. Entropy claim: none yet

**No min-entropy claim is made.** On the tested image NIST's non-IID
estimate is 3.556 bits per 4-bit sample, and both restart datasets pass
with a trial entropy value of 3.0 (§4). A claim also needs H_submitter, the
developer's estimate with a technical argument about the noise source
(§3.1.3, §3.2.2). The argument below is complete but for one input, and
measuring that input shows that it does not support 3 bits per sample at
the shipped spacing.

### 1.1 The argument, and the step that fails

A claim of 3 bits per 4-bit sample means: **the best prediction of the next
sample, given all earlier samples and everything the four rings share,
succeeds with probability at most 1/8.**

**Model** (arXiv:2102.02196, the model of `getnoise_analyze.py`). Each
ring's phase, in ring periods, advances from one kept sample to the next
(4,096 clocks) by a known amount plus Gaussian jitter; the sampled bit is 1
while the phase mod 1 lies in [0, D), D the ring's duty cycle as sampled.
The predictor is given the exact phase of every ring at the previous
sample, the ring frequencies with their wander, and every influence the
rings share. What can be credited is the white jitter of each ring's own
devices: fresh at every step and independent of the other rings.

**The bound.** For one ring with s² of credited variance over 4,096 clocks,
the best guess of the next bit succeeds with probability
p = max over u of max(q(u), 1 − q(u)), q(u) = P(N(u, s²) mod 1 ∈ [0, D)),
the worst case over the previous phase u. With independent credited jitter
in the four rings, H∞(sample | past) ≥ Σ −log₂ p, and a `seed` word, four
consecutive samples, has four times that. The bursts give each ring's
total jitter rate at the shortest lags (the lower end of the fit, per
clock): 1.82 × 10⁻³, 8.74 × 10⁻⁴, 4.39 × 10⁻⁴ and 2.44 × 10⁻⁴ ring
periods² for lanes 0 to 3; the duty cycles' bias is at most 0.011.
Under the model, crediting a share of each ring's rate as fresh,
independent Gaussian noise gives (`test/dbg/board/entropy_claim.py`):

| Credited share of each ring's fitted short-lag variance | Bound, bits per 4-bit sample | Per lane |
| --- | --- | --- |
| all | 3.92 | 0.986, 0.975, 0.969, 0.992 |
| 10 % | 3.64 | 0.986, 0.973, 0.919, 0.758 |
| 5 % | 3.04 | 0.985, 0.923, 0.693, 0.435 |

3 bits per sample needs at least 4.85 % of each ring's fitted short-lag
variance to be fresh, independent noise of that ring.

**Measured: most of that jitter is shared.** `entropy_claim.py --pairs`
estimates, for each pair of rings and each burst window, the covariance of
the two rings' phase increments. The product of two lanes' bits has
components at the sum and the difference of the two ring frequencies; they
decay with the variance of the sum and of the difference of the two phase
increments, so the two decay rates give the covariance. On generated rings
the estimator returns the correlation it was given (0, 0.5 and 0.95,
within 0.02; `--self-test`). On the board, |ρ| per pair, the mean over 32
windows (standard error 0.001 to 0.01 at the short spans):

| Pair of lanes | Sampling period 1 | 2 | 4 | 8 | 16 | 32 | 64 clocks |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0–1 | 0.97 | 0.97 | 1.00 | 0.92 | 0.84 | 0.82 | 0.84 |
| 0–2 | 0.95 | 0.97 | 0.96 | 0.89 | 0.45 | 0.63 | 0.28 |
| 0–3 | 0.90 | 0.91 | 0.94 | 0.91 | 0.23 | 0.81 | 0.42 |
| 1–2 | 0.97 | 0.96 | 0.99 | 0.98 | 0.91 | 0.83 | 0.81 |
| 1–3 | 0.99 | 0.99 | 0.97 | 1.00 | 0.78 | 0.95 | 0.89 |
| 2–3 | 0.95 | 0.95 | 0.94 | 0.96 | 0.96 | 0.98 | 0.90 |

At the short spans the rate is measured over, the rings' phase increments
are 90 to 100 % correlated. One shared driver with a loading per ring
would leave each ring between about 0 and 20 % of its variance as its own;
the estimates from different pairs do not agree, and for lane 1 they leave
none. The jitter the bursts measure is mostly common to the four rings.
Jitter of the sampling clock, which every ring sees in proportion to its
frequency, or a shared supply would both do that; the ratios of the rings'
rates, close to 1/stages², fit either. Over spans of a few hundred clocks
(periods 16 to 64) the correlation stays above 0.8 for most pairs and
drops to 0.2–0.6 for lane 0's pairs; no capture measures it at the 4,096
clocks of the shipped spacing.

**So the independent share the bound needs is not established, and for at
least one ring the short-lag data leaves none.** The samples may still
carry entropy from the shared component, which is physical noise too, and
from the rings' own noise over longer spans; but a claim needs a bound,
and this data does not give one. The analyser's cross-lane checks, which
flagged nothing, look at the bits and cannot see a shared jitter between
rings of different frequencies; the pairwise covariance can.

**What would close it** (§7): measure the shared component and how it
accumulates over 4,096 clocks (a clock locked by a PLL does not
accumulate phase error over long spans, a shared supply can); measure the
rings against each other rather than against the common clock, which
cancels the clock's jitter; or choose a spacing at which the measured
independent share suffices.

### 1.2 SP 800-90B status

**The source is not SP 800-90B compliant: there is no min-entropy claim.**

| Area | State |
| --- | --- |
| Noise source, no conditioning, raw samples available | In place: four sampled ring oscillators, bits never combined (§3) |
| Entropy claim (§3.1.3, §3.2.2) | **None.** The argument of §1.1 needs each ring's own jitter, and the jitter measured against the sampling clock is mostly shared between the rings |
| Entropy estimate on the 4-bit sample (§3.1.3) | NIST's non-IID estimate 3.556 bits per sample at the shipped spacing (§4.3); a statistical estimate, not H_I |
| Restart tests (§3.1.4) | **Pass** with trial values of 3.556 and 3.0 on the operational output path: 1,000 restarts by a full reset of the entropy source, samples through `seed` (§4.4). Not at that count by power-on |
| Approved continuous tests on the noise-source sample (§4.3 item 1) | **Met:** §4.4.1 and §4.4.2 on the 4-bit sample; lane tests in addition (§5.1) |
| Cutoffs and false-alarm probability (§4.3 item 3) | Documented: derived from a target of 3 bits per sample at α = 2⁻⁴⁰ per test (§5.2). The target is not a claim; the lane cutoffs rest on a separate premise of 0.75 bit per lane bit |
| Failure notification, intermittent and persistent (§4.3 item 2) | **Met in mechanism**, and shown on the board with induced failures (§5.3, §5.5). A real failure of the source has not been observed |
| Start-up and on-demand testing (§4.3 items 4, 5) | Start-up: met on every test; on the board the first output comes 56.7 ms after a reset. On demand: a `mentropycfg` write or a reset, not yet named in an integration guide |
| Failure modes and operating edge (§4.3 items 8, 9) | Stuck lane, lane patterns of period 1 to 4, biased lane, dominant sample: tested. Not covered: lanes locked to each other, shared jitter, loss of jitter without a short period; no data away from 24 °C |
| Configuration | One-sided limits: software can only make the tests stricter and the spacing longer (outside test mode, k is at least 16); both shown on the board. The boot chain sets no lock (§6) |
| Health tests on the real rings | Every interval read between resets ended with zero failures: about 2.4 hours in all, the longest 55 minutes (§5.5) |
| Operating range (§3.2.1 item 3) | One board, 23.9–25.2 °C, nominal supply |

What a claim needs first is a measurement of each ring's own jitter
against another ring rather than against the sampling clock, and from it
the spacing at which that jitter alone gives the target (§7).

Recommended release wording: *"Karu64 implements the approved continuous
health tests of SP 800-90B on the four-bit noise-source sample, with
per-lane tests, start-up testing and a latched failure alarm. On the tested
VCU118 image NIST's non-IID estimate was 3.556 bits per four-bit sample,
and both restart datasets passed with a trial entropy value of 3.0. Most of
the jitter that the board shows is shared between the four rings; how much
of it is each ring's own has not been established, and no min-entropy is
claimed."* Linux keeps `random.trust_cpu=off`.

## 2. Scope and data

| Item | Value |
| --- | --- |
| Image | VCU118 bitstream `ddb168e1081c9b73c29cd5a16ab777ee8106a52d382469b5b741b094bc096aad` ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)). Further data on the same noise source from `85f07e58…` ([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md)) and `d7ff00dc…` ([record](../dbg/BOARD_ACCEPTANCE-2026-11-18.md)): the same ring RTL and placement, a different routing, and so other ring frequencies relative to the clock (§4.5) |
| Clock | 75 MHz CPU clock (`ui_clk` ÷ 4 of the DDR4 controller) |
| Shipped sampling | one raw symbol every 256 clocks; decimation k = 16 (`mentropycfg` reset value): one kept 4-bit sample every 4,096 clocks (54.6 µs, 18,310 samples/s), one 16-bit `seed` word per 4 samples |
| Shipped health-test configuration | `mentropycfg` = `0x30c7c1eb3c37000f`: on the 4-bit sample, repetition count cutoff 15 and adaptive proportion (W = 512) cutoff 124; per lane, repetition count at lags 1 to 4 cutoff 55 and adaptive proportion (W = 1024) cutoff 719; the third running failure within 2^24 clean samples is fatal; start-up test over 1,024 kept samples |
| Datasets on `ddb168e1…` (2026-11-20) | **D20**: 10⁶ consecutive kept samples at k = 16 through GetNoise (capture SHA-256 `0b87780b…eea9`). **S20**: operational restart data, 1,000 restarts × the first 1,000 samples through `seed` (`cf31abe4…e92b`). **R20**: delayed warm-restart data, 1,000 restarts × 1,000 samples through GetNoise (`67b2c695…71dd`) |
| Datasets on earlier bitstreams | **D19** (`85f07e58…`, 2026-11-19, `2dd45d85…2879`) and **D18** (`d7ff00dc…`, 2026-11-18, `c5940f11…99cc`), as D20; **R19** (`85f07e58…`, `1c3f37a1…33a4ac`), as R20 |
| Conditions | lab VCU118, die 23.9–25.2 °C, VCCINT 0.846–0.847 V (on-chip readout), lifecycle `OPEN`. The D and R captures ran under the debugger with the hart halted; S20 with the hart running the capture payload from reset |
| Tools | NIST `SP800-90B_EntropyAssessment` commit `87c104d` (2026-05-26; `ea_non_iid` 1.1.8), built locally; `test/dbg/board/entropy_health.py` and `make entropy-test` for the health tests |

Data files (lab host, not tracked): D20 is
`_build/dbg/board-accept-20261120-rom2m-auth/noise-run1/getnoise-k16.bin`,
S20 `_build/dbg/board-accept-20261120-rom2m-auth/seed-restart-rows.bin`, R20
`_build/dbg/board-accept-20261120-rom2m-auth/restart-rows.bin`; D19
`_build/dbg/board-accept-20261119-rom2m-auth/noise-run1-warm-linkup/getnoise-k16.bin`,
D18 `_build/dbg/board-accept-20261118-rom2m-auth/getnoise-k16.bin`, R19
`_build/dbg/sp80090b-restart-20261119/restart-rows.bin`. The tool inputs
(4-bit samples, one per byte; for GetNoise captures with the run-marker bit
stripped) and every tool output are in `_build/nist-90b/data/` and
`_build/nist-90b/results/`.

## 3. The entropy source as built

| SP 800-90B component (§2.2) | Karu64 | Source |
| --- | --- | --- |
| Noise source | Four free-running inverter rings of 3, 5, 7 and 9 stages, each LUT placed by hand in its own slices; each ring sampled by a flip-flop on the 75 MHz clock, with a second flip-flop against metastability. One raw sample is the 4-bit vector of the four rings, taken every 256 clocks. The rings are gated off during any reset | [`flow/fpga/karu_rosc_rng.v`](../flow/fpga/karu_rosc_rng.v), [`flow/fpga/rosc_constraints.tcl`](../flow/fpga/rosc_constraints.tcl) |
| Digitisation and decimation | Every k-th raw sample is kept (k = 16 at reset). Outside test mode k cannot go below the build's 16. The kept samples are what the health tests see and what `seed` delivers | [`rtl/karu_entropy.v`](../rtl/karu_entropy.v) |
| Health tests | On the 4-bit sample: repetition count and adaptive proportion (W = 512). Per lane: repetition count at lags 1 to 4 and adaptive proportion (W = 1024). A start-up test of 1,024 kept samples. Not run in test mode (§5) | `rtl/karu_entropy.v` |
| Conditioning | **None.** Four consecutive kept samples are packed into a 16-bit `seed` word, the first in bits [15:12]; no bit is combined with another | `rtl/karu_entropy.v` (`part_q`, `fifo`) |
| Output | `seed` CSR (`0x015`): `OPST` (`BIST`, `WAIT`, `ES16`, `DEAD`) and 16 bits in `ES16`; words buffered (8) and released four at a time; each word is wiped as it is read. `seed` is the only way out: the debug-authentication ROM reads it like any other M-mode software | `rtl/karu_entropy.v`; [`rtl/karu_csr.v`](../rtl/karu_csr.v) (access rules) |
| Test interfaces | `mnoise` (`0x7C8`, GetNoise, one raw kept sample per access) and the burst capture (consecutive raw samples at periods of 1–256 clocks); both only in test mode, during which `seed` reports `BIST`. `mentropycfg` (`0x7C9`) holds k, the four cutoffs, the strike number, the clean-sample count and a lock; `mentropystat` (`0x7CA`) reports the tests' state | `rtl/karu_entropy.v`, [`flow/fpga/karu_noise_burst.v`](../flow/fpga/karu_noise_burst.v) |
| Enable | Platform strap (SW12 position 4 on the VCU118): on holds the source off and `seed` in `BIST`; off, the default, leaves it on | [`flow/fpga/karu_entropy_src.v`](../flow/fpga/karu_entropy_src.v) |

**The sample is the 4-bit vector, not four bits.** SP 800-90B §3.1.6:
*"multiple copies of the same physical noise source are considered as a
single noise source (e.g., a source with eight ring oscillators, where the
sampled bits are concatenated to get an eight-bit output …)"*. The entropy
claim, the approved tests and their cutoffs therefore belong to the 4-bit
sample. Per-lane figures are diagnostics; they are not to be added, and the
board data shows why: on bitstream `85f07e58…` lanes 2 and 3 shared
frequency wander and, in one run, a coherence peak at about 2.05 MHz
([burst-capture findings](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2)).
On `ddb168e1…` no lane pair was flagged.

## 4. Entropy estimation (§3.1, §5, §6)

### 4.1 Data collection (§3.1.1)

D20, D19 and D18 are 10⁶ consecutive kept samples each, at the shipped
spacing, taken through `mnoise` by `test/dbg/board/getnoise_capture.py`.
Each is a single run without a lost sample. Test mode is entered for the
capture: the samples are the same kept samples the health tests and
`seed` would see, but the capture is not the operational output path, and
it ran with the hart halted under the debugger. Tool input: one sample per
byte, lane i in bit i.

The burst captures (periods of 1–256 clocks) describe the physics; they are
not datasets at the shipped spacing and are not used here.

### 4.2 IID or non-IID track (§3.1.2, §5)

All three datasets **pass** NIST's IID tests: chi-square independence and
goodness of fit, the longest repeated substring test, and every
permutation test (`ea_iid`, results `d20-sym4-iid.txt`, `d19-sym4-iid.txt`,
`d18-sym4-iid.txt`). On the IID track the estimate would be the
most-common-value figure, 3.94 bits per sample for D20.

**The non-IID track applies nevertheless.** The IID track needs the
submitter's rationale that the source is IID, and the physics says
otherwise: at shorter spacings the same rings show strong serial
correlation, a fitted jitter variance that grows faster than white noise,
frequency wander, and on one bitstream coupling between two lanes. Passing
the IID tests at 4,096 clocks per sample shows that these effects are small
at that spacing, not that they are absent.

### 4.3 Initial entropy estimate (§3.1.3, §6.3)

`ea_non_iid -a -v <file> 4` on the 4-bit samples, which also assesses the
serialised bitstring (4 × 10⁶ bits). D20:

| Estimator (§6.3) | Per sample (of 4) | Per bit |
| --- | --- | --- |
| Most common value | 3.935 | 0.987 |
| Collision | — | 0.949 |
| Markov | — | 0.990 |
| Compression | — | **0.889** |
| t-tuple | **3.855** | 0.927 |
| LRS | 3.983 | 0.998 |
| MultiMCW prediction | 3.959 | 0.995 |
| Lag prediction | 3.986 | 0.997 |
| MultiMMC prediction | 3.954 | 0.987 |
| LZ78Y prediction | 3.952 | 0.987 |
| **H_original** | **3.855** | |
| **H_bitstring** | | **0.889** |
| **min(H_original, 4 × H_bitstring)** | **3.556** | |

The same on the earlier bitstreams:

| Dataset | Bitstream | H_original | H_bitstring | min(H_original, 4 × H_bitstring) | Set by |
| --- | --- | --- | --- | --- | --- |
| D20 | `ddb168e1…` | 3.855 | 0.889 | **3.556** | compression, bitstring |
| D19 | `85f07e58…` | 3.856 | 0.882 | 3.526 | compression, bitstring |
| D18 | `d7ff00dc…` | 3.688 | 0.921 | 3.684 | t-tuple, sample |

SP 800-90B defines H_I = min(H_submitter, H_original, 4 × H_bitstring).
No H_submitter is established (§1), so no H_I. **NIST's statistical
estimate on the current bitstream is 3.555965 bits per 4-bit sample**: a
measurement, not a physical lower bound. A 16-bit `seed` word holds four
samples.

Per lane, as diagnostics only (`ea_non_iid` on each lane's binary stream):
D19 0.851, 0.849, 0.814, 0.810 and D18 0.834, 0.863, 0.894, 0.847 bits per
bit for lanes 0–3. Four times the smallest is not the sample's entropy.

### 4.4 Restart tests (§3.1.4)

**Operational restart data (S20).** §3.1.4.1 asks for samples collected
*"as soon as the entropy source is ready to produce outputs for real-world
use"*. `test/dbg/board/seed_restart.py` restarts the source 1,000 times by a
debugger reset (`ndmreset`, with `haltreq` held). That resets the hart, the
SoC and the entropy source through the same reset sequencer as the software
reset at `0x1000_0800`; the rings are gated off while the reset lasts and
start again. DDR calibration, the clocks and the Debug Module are not reset.
After each reset:

1. the hart halts before its first instruction (checked: DPC is the reset
   vector), so the boot ROM never runs and nothing reads `seed` before the
   payload;
2. the host points DPC at `test/dbg/board/seedcap.S`, already in DRAM, and
   resumes the hart 5.2 to 8.3 ms (median 6.0 ms) after the reset was
   released;
3. `seedcap.S` reads `seed` in the reset configuration (no test mode, no
   `mentropycfg` write), polling without a pause, and stores the first 250
   words, 1,000 samples, that the source delivers.

In every restart the payload polled `BIST` before the first `ES16`, so no
word was delivered before it, and its longest gap between two polls was at
most 161 clocks against 16,384 per word, so the source's buffer never filled
and no sample was dropped. The first word came 48.6 to 51.6 ms after the
payload started, about 56.7 ms after the reset: the start-up test of 1,024
samples. No restart had to be repeated and none raised a health-test alarm.
`make dbg-seedcap-test` shows on the simulation bench that the payload
stores exactly the first samples after the start-up test, in order, and
that a late start, `DEAD` and an alarm are reported. Collected on
2026-11-20 in 189 s, die 24.6–25.0 °C.

| `ea_restart -n -v s20-rows.bin 4 3.555965` | Result |
| --- | --- |
| Sanity check (§3.1.4.3): largest count of one value at one position, over rows and columns | X_max = 98, cutoff 132: passed |
| H_r (row dataset), H_c (column dataset) | 3.688, 3.688 bits per sample |
| Validation (§3.1.4.2): min(H_r, H_c) ≥ H_I / 2 | passed |
| min(H_r, H_c, H_I) | 3.556 bits per sample |

With a trial value of 3.0, `ea_restart -n -v s20-rows.bin 4 3.0` passes as
well: X_max 98 against the cutoff of 178, validation passed (and on R20,
X_max 97 against 178).

H_r and H_c are both set by the t-tuple estimator at t = 4, where the most
common 4-tuple occurs just the 35 times that the estimator needs:
p̂ = (35/999,997)^¼ = 0.0769. The same quantisation of that estimator gives
R20's H_c the same value; it is not a property the datasets share.

**Delayed warm restarts (R20, R19).** The same restarts with the first
samples taken through GetNoise at least 150 ms after each reset, after a
further digital restart by the payload's `mentropycfg` write and its entry
into test mode (`getnoise_restart.py`). Both pass as well:

| `ea_restart -n -v` with the dataset's own D estimate | X_max (cutoff) | H_r | H_c | Validation |
| --- | --- | --- | --- | --- |
| R20 (`ddb168e1…`, 3.555965) | 97 (130) | 3.873 | 3.688 | passed |
| R19 (`85f07e58…`, 3.526340) | 100 (133) | 3.856 | 3.862 | passed |

**Not covered:** restarts by power-on or reconfiguration at this count. On
`85f07e58…`, eight reconfiguration and reset runs of the burst capture gave
the same ring frequencies and jitter within their run-to-run spread
([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2)).

### 4.5 What the estimate does and does not establish

- It is a measurement for one board, one temperature (23.9–25.2 °C) and one
  bitstream, not for the operating range SP 800-90B asks a claim to hold
  over (§3.2.1 item 3, §4.3 item 9).
- The ring frequencies relative to the clock depend on the routing:
  between `85f07e58…` and `ddb168e1…`, with the rings in the same slices,
  lane 0 moved from F ≈ 0.16 to 0.41 and lane 3 from 0.48 to 0.016
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md#noise-capture-and-entropy-estimates)).
  The estimates at the shipped spacing hardly moved (3.526 and 3.556), but a
  characterisation belongs to a bitstream.
- What scrambles the samples is mostly shared between the rings (§1.1):
  phase noise of all four rings relative to the sampling clock, and on both
  bitstreams it grows faster than white noise would. The estimate counts it
  all; a claim may count only each ring's own noise.
- The figures are statistical estimates on 10⁶ samples; SP 800-90B's own
  estimators are the conservative part, not the physics.

## 5. Health tests (§4)

### 5.1 What the block does

| | `rtl/karu_entropy.v` |
| --- | --- |
| Tests on the 4-bit sample | repetition count (§4.4.1) and adaptive proportion with W = 512 (§4.4.2): the approved tests, on the noise-source sample |
| Tests per lane | repetition count at lags 1 to 4 (a lane bit equal to the bit g samples earlier: lag 1 is a stuck lane, lags 2 to 4 are patterns of period 2 to 4), and adaptive proportion (W = 1024). Developer-defined tests for the source's failure modes (§4.3 item 8), in addition to the approved ones |
| A running failure | the buffered words are wiped, the start-up test runs again, and `seed` reports `BIST` until one `seed` access has seen the failure: the alarm that the Zkr text requires to be "latched until polled at least once" |
| A recurring failure | counted as strikes; the third without 2^24 clean samples in between is fatal (`DEAD`) |
| A failure in a start-up test | `DEAD`, including the retest after a running failure |
| Configuration | k, four cutoffs, the strike number and the clean-sample count are writable through `mentropycfg`; **the build's reset values are the weakest configuration by default**, so software can make the tests stricter and the spacing longer, not the reverse. A lock bit freezes the CSR until reset. Test mode takes any k, for characterisation; `seed` delivers nothing there |
| GetNoise | a run never spans a stopped source or a change of spacing: the loss flag is set when the strap or the configuration changes, or when the burst block's sampling period (`0x1000_0848`) is written |
| Status for the consumer | `OPST`, with the latched alarm; and `mentropystat` (`0x7CA`, M-mode, read-only): state, alarm, strikes (the fatal one included), which test, lanes and lags failed last, failures since reset |

The lane tests are needed beside the sample tests: a sample with one dead
or periodic lane still varies in the other three, and the sample tests
cannot tell that from a source that meets the target.

### 5.2 Cutoffs: the target, the false-alarm probability, and their choice in software

A cutoff follows from a min-entropy and a false-alarm probability α per
test (`test/dbg/board/entropy_health.py cutoffs`):

- repetition count: C = 1 + ⌈−log₂α / H⌉ (§4.4.1);
- proportion: the smallest C with P(1 + B(W−1, 2⁻ᴴ) ≥ C) ≤ α. The first
  sample of a window always counts, so the count is 1 + B(W−1, p). The
  formula printed in §4.4.2, 1 + CRITBINOM(W, 2⁻ᴴ, 1 − α), gives one less on
  the sample test (123 for H = 3), whose alarm probability is 1.44 α: the
  cutoffs here are the ones that meet α for the comparison the hardware
  makes.

The lane cutoffs use the same formulas with the entropy per lane bit: a bit
with min-entropy h given the past equals any bit determined by the past
with probability at most 2⁻ʰ, so the bound of §4.4.1 holds at every lag.

**The reset values are for H = 3 bits per 4-bit sample, h = 0.75 bit per
lane bit and α = 2⁻⁴⁰ per test.** Three bits per sample is the rate of 0.75
that the Zkr text asks of an SP 800-90B source. It is the target of this
assessment, **not a claim** (§1). The lane cutoffs rest on a separate
premise, 0.75 bit per lane bit, which no measurement establishes either:
their false-alarm figures below hold under that premise.

| Test | Cutoff | Alarm probability of a source exactly at the target, in units of α | A healthy source trips it about every |
| --- | --- | --- | --- |
| Sample repetition | 15 | 0.25 per run | 116,000 years |
| Sample proportion, W = 512 | 124 | 0.64 per window | 10²⁷ years |
| Lane repetition, lags 1 to 4 | 55 | 0.71 per run | 3,100 years |
| Lane proportion, W = 1024 | 719 | 0.77 per window | 10²⁶ years |
| Any of them | | | 3,000 years |

α is a target per test. "Healthy" is four independent lanes of independent
bits with the largest lane bias of the board captures (0.509), at 18,310
samples per second. For that model the probability is exact for one lane at
one lag (a repetition count reaches C when exactly C − 1 comparisons in a
row match, which at lag g means g interleaved runs), for the sample
repetition count, and for one window of a proportion test. The rows of the
table add these up over lanes and lags, and the last row over the tests;
the events overlap, so those rows are upper bounds on the alarm
probability, and lower bounds on the interval, under the model. They say
nothing about a real source's dependence. α = 2⁻⁴⁰ and not 2⁻²⁰ because of
the sample rate: at 2⁻²⁰ (cutoffs 7 and 78 on the sample at the current
estimate) a healthy source would trip the sample repetition test about
every 15 minutes, and every false alarm costs a retest and a strike.

The cutoffs are configuration, not constants: software that has an
assessed claim sets the cutoffs for it and locks them.

| Target | Sample repetition | Sample proportion | Lane repetition | Lane proportion |
| --- | --- | --- | --- | --- |
| H = 1.0, h = 0.5 | 41 | 337 | 81 | 824 |
| H = 2.0, h = 0.5 | 21 | 202 | 81 | 824 |
| H = 3.0, h = 0.75 (reset) | 15 | 124 | 55 | 719 |
| H = 3.556, h = 0.889 (the D20 estimate) | 13 | 96 | 46 | 666 |

All at α = 2⁻⁴⁰. With the default build limits the last row can be
written, and nothing weaker than the reset row.

### 5.3 Failure handling (§4.3 item 2)

- **Notification.** A running failure is the non-fatal alarm of the Zkr
  text: `seed` reports `BIST` from the failure until one `seed` access has
  seen it, however much later, and delivers nothing meanwhile. A fatal
  failure is `DEAD` until reset, with the noise source switched off.
  `mentropystat` tells M-mode which test, lanes and lags failed and how
  often.
- **Intermittent or persistent.** A failure during any start-up test,
  including the retest after a running failure, is fatal. A running
  failure is a strike; 2^24 samples in a row without a failure (about 15
  minutes) clear the strikes; the third strike is fatal. The samples are
  counted from the failure, so the 1,024 of the retest are among them.
  Both numbers are configuration (`strikes`, `calm`), with the same
  one-sided limits. A `mentropycfg` write clears neither a strike nor the
  alarm.
- **Evidence for (a), "extremely likely intermittent".** A failure is
  treated as intermittent only if the source then passes a full start-up
  test and, for it to be forgotten, 2^24 further samples under all tests.
  A strike records that a count crossed its cutoff, nothing more. Under
  the model of 5.2 a healthy source does that less than once in 3,000
  years, so three within the forgiveness time are taken as a fault and
  end the source.
- **Evidence for (b), "a permanent failure is detected and ends in an
  error".** A fault that stays fails the retest, which is fatal: for a
  stuck or periodic lane within 58 samples of the first failure (3.2 ms).
  A fault that goes away and comes back within 15 minutes is fatal at its
  third occurrence. A fault that comes back less often than that is, by
  this rule, intermittent; every occurrence still wipes the buffer and
  raises the alarm.

### 5.4 §4.3 point by point

| §4.3 item | Requirement (paraphrased) | Karu64 | State |
| --- | --- | --- | --- |
| 1 | Continuous tests: the approved tests of §4.4, or developer-defined tests meeting §4.5 | §4.4.1 and §4.4.2 on the 4-bit sample; lane tests in addition | **Met** |
| 2 | On failure, notify the consuming application; intermittent-failure handling needs evidence; after a persistent failure, no output | Latched alarm, strikes, `DEAD` (5.3); shown on the board with induced failures (5.5) | **Met in mechanism**; how the real source fails has not been observed |
| 3 | A documented false-positive probability, 2⁻²⁰ to 2⁻⁴⁰ recommended | 2⁻⁴⁰ per test, with the cutoffs derived for the target (5.2) | **Met for the target**; the claim itself is open |
| 4 | Start-up tests run the continuous tests over at least 1,024 consecutive samples | Every test, sample and lane, over 1,024 kept samples before the first `ES16`; on the board the first output comes 56.7 ms after a reset | **Met** |
| 5 | On-demand testing, at least the start-up tests | An accepted `mentropycfg` write restarts the start-up test, as does a reset; once locked, only a reset | **Possible**; to be named in an integration guide |
| 6 | Health tests on noise-source samples before conditioning | There is no conditioning; the tests see the kept samples | **Met** |
| 7 | Documentation of every test, its rate, conditions and rationale | The header of `rtl/karu_entropy.v` and this document | **Partly**: rates and rationale per failure mode from board data |
| 8 | Known or suspected failure modes, with developer-defined tests for them | Lane repetition at lags 1 to 4 and lane proportion; see below | **Partly** |
| 9 | Emphasis on detection near the edge of the operating environment | No data outside 24 °C and nominal supply | **Not met** |

Failure modes of a ring-oscillator source and what detects them:

| Failure mode | Detected by | Gap |
| --- | --- | --- |
| A ring stuck at 0 or 1 | lane repetition at lag 1 (55 samples); sample repetition | — |
| A ring locked to the sampling clock in a short period (`0101…`, period 2 to 4) | lane repetition at lags 2 to 4 | longer periods |
| A biased ring | lane proportion | — |
| A dominant 4-bit value | sample proportion | — |
| Rings locked to each other, or a shared disturbance (supply ripple, a tone) | the sample proportion only for gross coupling | no test for weak coupling |
| Loss of jitter (temperature, supply, injection) that leaves no short period | lane proportion for strong bias only | no test of the jitter itself |
| Software reconfiguration | one-sided limits; the lock | the boot chain sets no lock (§6) |

### 5.5 Evidence

**Simulation and replay** (`make entropy-test`):

- **The block against a reference model.** `test/dbg/board/entropy_health.py`
  is the health logic in Python. `test/entropy_replay.py` feeds the same
  symbols to the RTL (`test/tb_entropy_replay.sv`) and to the model and
  compares every failure and the status register after it: healthy
  symbols, every kind of fault on every lane and lag, strikes, forgiveness,
  a failure during start-up, rows that each start from reset, and 60
  random cases with random cutoffs and `seed` accesses (212 failures).
  They agree everywhere, and a model that differs by one in any one
  setting does not.
- **Directed cases and mutants.** `test/tb_entropy.sv` has each test at its
  cutoff and one sample short of it, the alarm and its owner, the strikes,
  the limits and the status register (4,073 checks). 86 one-mechanism
  mutants of the module are all caught.
- **The criteria of §4.5**, at H = 3.0 and the reset cutoffs
  (`entropy_health.py criteria`). They are supplementary: the block
  implements the approved tests of §4.4. (a) More than 100/H = 33.3
  identical samples: a repetition count with cutoff 15 trips by the 15th
  of them, by construction; simulated with 34 and 35 repeats, 200 of 200
  each, all detected by the 15th sample (a few earlier, where the healthy
  samples before the fault happened to end with the repeated value). (b)
  One value at P* = 0.354 for 50,000 samples: 20 of 20, the slowest after
  3,926 samples. A case counts only if the healthy samples before the
  fault raise no failure and the failure comes while the fault lasts.
- **Failure modes** (same command, same rule): a lane stuck at 0 or 1 is
  detected at its 55th sample, a lane with a pattern of period 2, 3 or 4
  at its 56th to 58th, a lane biased to 0.74 within four windows, a stuck
  sample at its 15th; none missed. 200,000 uniform samples raise no
  failure.
- **The board captures replayed** (`make entropy-test ENTROPY_DATA=…
  ENTROPY_RESTART=…`), at the reset cutoffs, in the RTL and in the model:

  | Dataset | Failures | Longest sample repetition (cutoff 15) | Largest sample window count (124) | Largest lane repetition count, any lag (55) | Largest lane window count (719) |
  | --- | --- | --- | --- | --- | --- |
  | D20, 10⁶ consecutive samples | none; ends running | 6 | 52 | 24 (lag 1) | 572 |
  | D19 | none; ends running | 6 | 55 | 24 (lag 2) | 578 |
  | D18 | none; ends running | 6 | 53 | 25 (lag 1) | 586 |
  | R20, 1,000 restarts of 1,000, each from reset | none | 5 | 56 | 22 | 561 |
  | R19, the same | none | 5 | 55 | 21 | 578 |

  A row of R20 or R19 has 1,000 samples, fewer than the 1,024 of the
  start-up test: those rows show no false alarm in the first 1,000 samples
  after a restart, and S20 (below) covers what follows a completed
  start-up test. At much tighter cutoffs (7, 79, 24 and 633) D20, D19 and
  D18 give 2, 1 and 2 failures, at the same samples in RTL and model.

**On the board, the healthy source.** `mentropystat` was read before most
resets of the 2026-11-20 session, without a reset
([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md#health-tests-on-the-board)):
every interval read ended with zero failures, about 2.4 hours in all
(an estimated 1.6 × 10⁸ samples), the longest 55 minutes. In S20 every one
of the 1,000 start-up tests passed, and no restart raised an alarm in the
1,000 samples after it.

**On the board, induced failures** (`test/dbg/board/entropy_fault.py`).
Software may make the tests stricter, and a cutoff far below its reset
value makes the real rings fail that test within seconds. Each case starts
from a debugger reset, with the hart halted, so nothing else reads `seed`:

| Case | Set | What the board did |
| --- | --- | --- |
| Start-up failure | sample repetition cutoff 2: any two equal samples in a row | `DEAD` 21 ms after the write, during the start-up test: cause sample repetition, one failure, no alarm, no strike; `seed` read `DEAD`, and still did a second later |
| Each test | one at a time: sample repetition 5, sample proportion 46, lane repetition 21, lane proportion 550 | each failed while running, after 10.6, 1.9, 4.3 and 1.1 s; `mentropystat` named that test alone, and for the lane tests the lane (lane 1 both times) and the lag (2); each raised the alarm and one strike |
| Strikes | sample repetition 5 | the first running failure (0.21 s) raised the alarm and a strike; a `mentropycfg` write left both; one `seed` access returned `BIST` and cleared the alarm, not the strike; failures at 3.4 and 6.0 s; the third was fatal: `DEAD`, three strikes, and `seed` read `DEAD` |
| Forgiveness | sample repetition 5 until the first failure (7.8 s), then the reset cutoffs | the strike survived the write and cleared 920.5 s after the failure; 2^24 samples take 916.3 s |
| Limits | every field weaker than its reset value, and k = 1 | the cutoffs, the strike number and the clean-sample count read back as the build's limits; k read back as written, but `seed` delivered one word per 16,318 clocks, which is k = 16 (k = 1 would be 1,024); with the lock set a write changed nothing; a reset restored the reset value |

These show the mechanism on real noise; the failures are of stricter tests
on a healthy source, not of a failing source.

**The cost** (Vivado 2026.1, out-of-context synthesis of `karu_entropy_src`
for the VCU118 part, estimates before placement): `karu_entropy` uses 721
CLB LUTs and 576 flip-flops in the hierarchical utilization report (907 LUT
primitives before packing). The path from its registers to the value the
core reads has ten logic levels, 3.1 ns; the loop check finds only the
rings.

**Not shown by any of this:** that the target is met, or how the real
source fails.

### 5.6 For software that writes `mentropycfg`

The CSR has more fields than k and two cutoffs: the two sample cutoffs
`[43:37]` and `[53:44]`, the strike number `[56:54]` and the clean-sample
count `[61:57]`. A constant that leaves a cutoff field zero fails on the
next kept sample, which during the start-up test is fatal: `seed` reports
`DEAD` until reset. Change a field by read-modify-write:

```asm
    csrr  t0, 0x7C9         # mentropycfg: keep what is there
    li    t1, 0xffff
    not   t1, t1
    and   t0, t0, t1        # replace one field, here the interval
    ori   t0, t0, 31        # k = 32
    csrw  0x7C9, t0
    li    t1, 1 << 63       # the lock alone: set that bit
    csrs  0x7C9, t1
```

The capture payloads (`test/dbg/board/getnoise.S`) do it this way. Nothing
in the boot path (fu-boot, the island ROM, OpenSBI, U-Boot, Linux) writes
`mentropycfg`.

## 6. Other requirements and architectural notes

- **The configuration has one-sided limits.** The reset values are the
  weakest the CSR accepts: a weaker value is replaced by the limit, and
  outside test mode the source keeps at least the build's spacing whatever
  k is written (both shown on the board, §5.5), and nothing in the boot
  chain writes `mentropycfg`. A claim holds for the configuration it was
  made for; the boot firmware should then write that configuration (a
  longer spacing, if the claim needs one) and set the lock before any
  consumer reads `seed`. Nothing in the boot chain sets it yet.
- **The clock and the routing are part of the source.** Kept samples are
  counted in clocks of the 75 MHz CPU clock; a different clock or divider
  changes the sample spacing and invalidates the estimate, and so can a
  new routing of the rings (§4.5).
- **Test interfaces.** `mnoise` and the burst capture expose raw samples
  only in test mode, during which `seed` delivers nothing, and leaving test
  mode restarts the start-up test; no captured sample is ever delivered as
  entropy. That is the separation SP 800-90B expects of raw-data access.
- **One consumer.** `seed` is the only way out for a word, and a word is
  wiped as it is read, so no word reaches two consumers. The
  authentication ROM reads `seed` like any other M-mode software, and only
  a `seed` access clears the alarm.
- **Warm-up.** None beyond the start-up test; outputs appear about 57 ms
  after reset.
- **Operating range.** All data is from one board at 23.9–25.2 °C and
  nominal supply. The die temperature and supply readout
  (`flow/fpga/karu_sysmon.v`, `0x1000_0860`) makes captures at other
  conditions recordable.
- **FPGA versus ASIC.** The rings are LUTs with hand placement; an ASIC
  source would be a different noise source with its own assessment. The
  architecture (raw samples, sample-level tests, no conditioning, test
  mode, the operational restart capture) carries over; the numbers do not.

## 7. Work to reach a claim (Z6)

1. **Measure each ring's own jitter.** A new bitstream with counters that
   time one ring against another (one ring's edges over N periods of the
   other, many times, for N over several decades) and, for comparison,
   against the system clock. What the rings share, the sampling clock and
   the supply, cancels between two rings; the growth of the variance with N
   separates thermal noise (linear) from flicker (quadratic); three pairs
   give each ring's own thermal jitter. The counters are checked first in
   simulation with the behavioural source, whose lanes have a shared and an
   individual noise term.
2. **Choose the fixed parameters from it.** The spacing at which each
   ring's own thermal jitter alone gives the target, by the bound of §1.1
   with that jitter credited (software may lengthen the spacing up to
   k = 65,536 without new hardware); or, if no practical spacing does, a
   change of the noise source. Then the non-IID estimate and the restart
   test again at that spacing.
3. **Make the claim**, and fix its configuration: the boot firmware writes
   the spacing and sets the `mentropycfg` lock.
4. **Documentation:** the on-demand test named in an integration guide;
   the rates and rationale per failure mode (§4.3 items 5 and 7).
5. **Coverage of locked or coupled rings and of a loss of jitter that
   leaves no short period:** a test, or a rationale for why the existing
   ones suffice (§4.3 item 8).

To widen a claim, and for an ASIC:

6. Data over the operating range: temperature and supply corners, several
   boards or placements, power-on restarts; repeat the jitter measurement,
   the non-IID estimate and the restart test on each, per bitstream.
7. Optionally, a vetted conditioning component after the noise source,
   which would change a claim from per-sample entropy to full-entropy
   output (§3.1.5).

A self-assessed claim is not a validation; that needs an accredited
laboratory.

## 8. Reproduction

```sh
# NIST tools (commit 87c104d), with libdivsufsort and jsoncpp built locally
make -C SP800-90B_EntropyAssessment/cpp iid non_iid restart
# 4-bit samples: strip the run marker (bit 7) of a GetNoise capture
python3 -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(bytes(b&15 for b in d))" getnoise-k16.bin d20-sym4.bin
ea_iid -v d20-sym4.bin 4
ea_non_iid -a -v d20-sym4.bin 4
ea_restart -n -v s20-rows.bin 4 3.555965      # operational restarts, the D20 estimate
ea_restart -n -v s20-rows.bin 4 3.0           # the same with a trial value of 3.0
ea_restart -n -v r20-rows.bin 4 3.555965      # delayed warm restarts
# the bound of section 1.1 for credited shares, and the pairwise covariance
python3 test/dbg/board/entropy_claim.py --analysis getnoise-analysis.json \
    --samples d20-sym4.bin s20-rows.bin r20-rows.bin --credit 1 0.1 0.05
python3 test/dbg/board/entropy_claim.py --analysis getnoise-analysis.json --pairs noise-run1/
python3 test/dbg/board/entropy_claim.py --self-test
# health tests: cutoffs, the criteria and failure modes on the model, replay
python3 test/dbg/board/entropy_health.py cutoffs --h 3.0 --h-lane 0.75 --alpha 40
python3 test/dbg/board/entropy_health.py criteria
make entropy-test ENTROPY_DATA="d20-sym4.bin d19-sym4.bin d18-sym4.bin" ENTROPY_RESTART=r20-rows.bin
make dbg-seedcap-test                          # the restart payload on the simulation bench
# board data (server.cfg, lifecycle OPEN, source on)
python3 test/dbg/board/getnoise_capture.py     # k-sweep, includes k = 16
python3 test/dbg/board/seed_restart.py         # operational restarts, 1,000 x 1,000
python3 test/dbg/board/getnoise_restart.py     # delayed warm restarts, 1,000 x 1,000
python3 test/dbg/board/entropy_fault.py        # induced failures
```

## References

- NIST SP 800-90B, *Recommendation for the Entropy Sources Used for Random
  Bit Generation*, January 2018,
  <https://doi.org/10.6028/NIST.SP.800-90B>. Sections cited: 2.2, 3.1.1–3.1.6,
  3.2, 4.3, 4.4, 4.5, 5, 6.3.
- NIST SP 800-90B entropy assessment tools,
  <https://github.com/usnistgov/SP800-90B_EntropyAssessment>, commit `87c104d`.
- M.-J. O. Saarinen, *On Entropy and Bit Patterns of Ring Oscillator
  Jitter*, arXiv:2102.02196.
- RISC-V Scalar Cryptography, Zkr (`seed`, `mseccfg`), and its GetNoise
  rationale, as cited in the header of `rtl/karu_entropy.v`.
- Karu64: [Zkr follow-up plan](zkr-followup-plan.md),
  [board acceptance 2026-11-20](../dbg/BOARD_ACCEPTANCE-2026-11-20.md),
  [2026-11-19](../dbg/BOARD_ACCEPTANCE-2026-11-19.md),
  [2026-11-18](../dbg/BOARD_ACCEPTANCE-2026-11-18.md),
  [FPGA guide](fpga.md).
