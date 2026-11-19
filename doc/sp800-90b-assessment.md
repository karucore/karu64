# SP 800-90B assessment of the Karu64 Zkr entropy source

Status: **assessment, 2026-11-19.** Board data from the VCU118 image
`85f07e58…` (and, for comparison, `d7ff00dc…`), analysed with NIST's
SP 800-90B tools. This is an engineering self-assessment against
[NIST SP 800-90B](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-90B.pdf)
(January 2018), not a validation: no accredited laboratory has been
involved, and the FPGA ring oscillators are a stand-in for an ASIC noise
source.

## 1. Verdict

**Karu64's `seed` source is not SP 800-90B compliant, and no compliant
min-entropy claim can be made for it yet.** What is in place, and what is
missing:

| Area | State |
| --- | --- |
| Noise source, no conditioning, raw samples available | In place: four sampled ring oscillators, bits never combined (§3) |
| Entropy estimate on the four-bit sample | Measured, not claimed: NIST's non-IID estimators give 3.53 bits per 4-bit sample at the shipped spacing, a statistical estimate and not an established H_I (no H_submitter). A delayed warm-restart experiment passes the restart tool with that value as a trial input; the operational restart requirement has not been tested (§4). One board, one session, 24 °C |
| Approved health tests on the noise-source sample | **Not met.** The RTL runs binary RCT and APT on each lane separately, not on the 4-bit sample, and those lane tests fail both criteria for alternative tests (§4.5) by a wide margin (§5.3) |
| Health-test cutoffs from an assessed entropy | **Not met.** RCT 41 assumes 0.5 bit per lane bit; APT 821 corresponds to about 0.44; neither derives from an assessment (§5.2) |
| Failure notification | **Partly.** A failure while running returns `seed` to `BIST`, which consumers cannot tell apart from ordinary start-up (§5.4) |
| Configuration of the assessed source | **Not enforced.** M-mode software can change the decimation and weaken the cutoffs (to 1,023 equal bits and a fully matching window), and nothing locks `mentropycfg` in the boot chain (§6) |
| Documentation and operating range | Partly: this document; one board, one placement, 23.9–24.9 °C, nominal supply (§6) |

Recommended release wording: *"Karu64 implements per-lane RCT/APT health
tests and start-up output gating. The joint entropy of the four-ring source
has not been assessed under SP 800-90B; no min-entropy is claimed for a
`seed` word."* Linux keeps `random.trust_cpu=off`.

## 2. Scope and data

| Item | Value |
| --- | --- |
| Image | VCU118 bitstream `85f07e58354646ff3102fe3ddfe8c2e91005b5171b895391aea7ea3795f2639a` ([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md)); comparison data from `d7ff00dc…` ([record](../dbg/BOARD_ACCEPTANCE-2026-11-18.md)) |
| Clock | 75 MHz CPU clock (`ui_clk` ÷ 4 of the DDR4 controller) |
| Shipped sampling | one raw symbol every 256 clocks; decimation k = 16 (`mentropycfg` reset value): one kept 4-bit symbol every 4,096 clocks (54.6 µs, 18,310 symbols/s), one 16-bit `seed` word per 4 symbols |
| Shipped health-test configuration | per lane: RCT cutoff 41; APT window 1024, cutoff 821; start-up: 1,024 kept symbols |
| Datasets | **D19**: 10⁶ consecutive kept symbols at k = 16, 2026-11-19, image `85f07e58…` (SHA-256 `2dd45d85…2879`); **D18**: the same on 2026-11-18, image `d7ff00dc…` (`c5940f11…99cc`); **R19**: delayed warm-restart data, 1,000 restarts × 1,000 symbols, 2026-11-19, image `85f07e58…` (§4.4) |
| Conditions | lab VCU118, die 23.9–24.9 °C, VCCINT 0.846 V (on-chip readout), lifecycle `OPEN`, captures under the debugger with the hart halted |
| Tools | NIST `SP800-90B_EntropyAssessment` commit `87c104d` (2026-05-26; `ea_non_iid` 1.1.8), built locally; `test/dbg/board/sp80090b_health.py` for the health-test replay |

Data files (lab host, not tracked): the D19 capture is
`_build/dbg/board-accept-20261119-rom2m-auth/noise-run1-warm-linkup/getnoise-k16.bin`,
D18 is `_build/dbg/board-accept-20261118-rom2m-auth/getnoise-k16.bin`, R19 is
`_build/dbg/sp80090b-restart-20261119/restart-rows.bin`. The tool inputs
(4-bit symbols with the run-marker bit stripped, one per byte) and every
tool output are in `_build/nist-90b/data/` and `_build/nist-90b/results/`.

## 3. The entropy source as built

| SP 800-90B component (§2.2) | Karu64 | Source |
| --- | --- | --- |
| Noise source | Four free-running inverter rings of 3, 5, 7 and 9 stages, each LUT placed by hand in its own slices; each ring sampled by a flip-flop on the 75 MHz clock, with a second flip-flop against metastability. One raw sample is the 4-bit vector of the four rings, taken every 256 clocks | [`flow/fpga/karu_rosc_rng.v`](../flow/fpga/karu_rosc_rng.v), [`flow/fpga/rosc_constraints.tcl`](../flow/fpga/rosc_constraints.tcl) |
| Digitisation and decimation | Every k-th raw sample is kept (k = 16 at reset, 1 to 65,536 settable). The kept samples are what the health tests see and what `seed` delivers | [`rtl/karu_entropy.v`](../rtl/karu_entropy.v) |
| Health tests | Per lane: repetition count and adaptive proportion on binary samples; a start-up test of 1,024 kept samples. Not run in test mode | `rtl/karu_entropy.v` (`rct_*`, `apt_*`, `bist_cnt`) |
| Conditioning | **None.** Four consecutive kept samples are packed into a 16-bit `seed` word; no bit is combined with another | `rtl/karu_entropy.v` (`part_q`, `fifo`) |
| Output | `seed` CSR (`0x015`): `OPST` (`BIST`, `WAIT`, `ES16`, `DEAD`) and 16 bits in `ES16`; words buffered (8) and released four at a time; each word is wiped as it is read. The debug-authentication ROM draws its nonce from the same buffer | `rtl/karu_entropy.v`; [`rtl/karu_csr.v`](../rtl/karu_csr.v) (access rules) |
| Test interfaces | `mnoise` (`0x7C8`, GetNoise, one raw kept sample per access) and the burst capture (consecutive raw samples at periods of 1–256 clocks); both only in test mode, during which `seed` reports `BIST`. `mentropycfg` (`0x7C9`) holds k, the two cutoffs and a lock | `rtl/karu_entropy.v`, [`flow/fpga/karu_noise_burst.v`](../flow/fpga/karu_noise_burst.v) |
| Enable | Platform strap (SW12 position 4 on the VCU118): off holds the source off and `seed` in `BIST` | [`flow/fpga/karu_entropy_src.v`](../flow/fpga/karu_entropy_src.v) |

**The sample is the 4-bit vector, not four bits.** SP 800-90B §3.1.6:
*"multiple copies of the same physical noise source are considered as a
single noise source (e.g., a source with eight ring oscillators, where the
sampled bits are concatenated to get an eight-bit output …)"*. The entropy
claim, the health tests and their cutoffs therefore belong to the 4-bit
sample. Per-lane figures are diagnostics; they are not to be added, and the
board data shows why: lanes 2 and 3 share frequency wander and, in one
run, a coherence peak at about 2.05 MHz
([burst-capture findings](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2)).

## 4. Entropy estimation (§3.1, §5, §6)

### 4.1 Data collection (§3.1.1)

D19 and D18 are 10⁶ consecutive kept samples each, at the shipped
spacing, taken through `mnoise` by `test/dbg/board/getnoise_capture.py`.
Each is a single run without a lost sample. Test mode is entered for the
capture: the samples are the same kept samples the health tests and
`seed` would see, but the capture is not the operational output path, and
it ran with the hart halted under the debugger. Tool input: bit 7 (the run
marker) stripped; one sample per byte, lane i in bit i.

The eight burst-capture runs of 2026-11-19 (periods of 1–256 clocks)
describe the physics; they are not datasets at the shipped spacing and
are not used here.

### 4.2 IID or non-IID track (§3.1.2, §5)

Both datasets **pass** NIST's IID tests: chi-square independence and
goodness of fit, the longest repeated substring test, and every
permutation test (`ea_iid`, results `d19-sym4-iid.txt`, `d18-sym4-iid.txt`).
On the IID track the estimate would be the most-common-value figure,
3.91 and 3.90 bits per sample.

**The non-IID track applies nevertheless.** The IID track needs the
submitter's rationale that the source is IID, and the physics says
otherwise: at shorter spacings the same rings show strong serial
correlation, a fitted jitter variance that grows faster than white noise,
frequency wander, and coupling between lanes 2 and 3. Passing the IID tests
at 4,096 clocks per sample shows that these effects are small at that
spacing, not that they are absent.

### 4.3 Initial entropy estimate (§3.1.3, §6.3)

`ea_non_iid -a -v <file> 4` on the 4-bit samples, which also assesses the
serialised bitstring (4 × 10⁶ bits):

| Estimator (§6.3) | D19, per sample (of 4) | D19, per bit | D18, per sample | D18, per bit |
| --- | --- | --- | --- | --- |
| Most common value | 3.914 | 0.980 | 3.899 | 0.977 |
| Collision | — | 0.930 | — | 0.932 |
| Markov | — | 0.981 | — | 0.978 |
| Compression | — | **0.882** | — | 0.938 |
| t-tuple | **3.856** | 0.929 | **3.688** | **0.921** |
| LRS | 3.873 | 0.972 | 3.906 | 0.994 |
| MultiMCW prediction | 3.976 | 0.989 | 3.944 | 0.987 |
| Lag prediction | 3.984 | 0.998 | 3.992 | 0.998 |
| MultiMMC prediction | 3.935 | 0.981 | 3.929 | 0.977 |
| LZ78Y prediction | 3.934 | 0.981 | 3.929 | 0.977 |
| **H_original** | **3.856** | | **3.688** | |
| **H_bitstring** | | **0.882** | | **0.921** |
| **min(H_original, 4 × H_bitstring)** | **3.526** | | **3.684** | |

SP 800-90B defines H_I = min(H_submitter, H_original, 4 × H_bitstring).
No H_submitter has been stated, so no H_I is established. **The D19
statistical estimate is 3.526340 bits per 4-bit sample**, set by the
compression estimator on the bitstring; D18, a different bitstream with
the rings in the same slices, gives 3.684, set by the t-tuple estimator.
These are measurements, not a physical lower bound. A 16-bit `seed` word
holds four samples.

Per lane, as diagnostics only (`ea_non_iid` on each lane's binary stream):
D19 0.851, 0.849, 0.814, 0.810 and D18 0.834, 0.863, 0.894, 0.847 bits per
bit for lanes 0–3. Four times the smallest is not the sample's entropy.

### 4.4 Restart tests (§3.1.4): a delayed warm-restart experiment

**This is not a pass of the operational restart requirement.** §3.1.4.1
asks for samples collected *"as soon as the entropy source is ready to
produce outputs for real-world use"*. The data below begins later, so a
repeatable weakness confined to the first outputs after a restart could be
missed.

**What was done.** 1,000 restarts by a debugger reset-halt (`ndmreset` with
`haltreq`), which resets the hart, the SoC and the entropy source through
the same reset sequencer as the software reset at `0x1000_0800`: the rings
stop and start again. DDR calibration, the clocks and the Debug Module are
not reset. Per restart, `test/dbg/board/getnoise_restart.py`:

1. releases the reset and waits 50 ms (inside `reset_halt()` in
   `test/dbg/board/boardlib.py`), then checks the reset vector;
2. waits until 100 ms after `reset_halt()` returned;
3. runs the GetNoise payload, which rewrites `mentropycfg` and enters test
   mode (`test/dbg/board/getnoise.S`); both restart the entropy block's
   digital sequence (decimation counter, health tests), not the rings;
4. captures 1,000 consecutive kept samples at k = 16 (none lost; no capture
   had to be repeated).

So each row begins at least about 150 ms after the reset, and after a
further digital restart, while the start-up test would have released the
first operational output at about 57 ms. Collected on 2026-11-19 in 340 s;
die 24.0–24.9 °C; row dataset SHA-256 `1c3f37a1…33a4ac`.

**Result**, with the D19 estimate 3.526340 as a trial input:

| `ea_restart -n -v restart-rows.bin 4 3.526340` | Result |
| --- | --- |
| Sanity check (§3.1.4.3): largest count of one value at one position, over rows and columns | X_max = 100, cutoff 133: passed |
| H_r (row dataset), H_c (column dataset) | 3.856, 3.862 bits per sample |
| Validation (§3.1.4.2): min(H_r, H_c) ≥ trial input / 2 | passed |
| min(H_r, H_c, trial input) | 3.526 bits per sample |

**What the operational version needs.** Samples from the first `ES16` on,
through the output path: a payload that is already running when the
start-up test completes and reads `seed` in M-mode without entering test
mode, faster than words are produced (about 4,600 per second), so that the
8-word buffer never overflows and four consecutive samples come out of
every word. And restarts as deployed: power-on or reconfiguration, which
were not collected 1,000 times here. On 2026-11-19 eight reconfiguration and reset runs
of the burst capture gave the same ring frequencies and jitter within
their run-to-run spread
([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2)).

### 4.5 What the estimate does and does not establish

- It is a measurement for one board, one placement of the rings, one
  bitstream and one temperature (23.9–24.9 °C), not for the operating
  range SP 800-90B asks the claim to hold over (§3.2.1 item 3, §4.3 item 9).
- The jitter that makes the rings unpredictable is partly flicker and
  wander (burst captures). A model-based lower bound that credits only the
  white component has not been derived; it is the physical rationale an
  H_submitter would need.
- The figures are statistical estimates on 10⁶ samples; SP 800-90B's own
  estimators are the conservative part, not the physics.

## 5. Health tests (§4), point by point

### 5.1 Requirements of §4.3

| §4.3 item | Requirement (paraphrased) | Karu64 | Status |
| --- | --- | --- | --- |
| 1 | Continuous tests: the approved tests of §4.4, or developer-defined tests meeting §4.5 | Binary RCT and APT on each lane; nothing on the 4-bit sample | **Not met** (§5.3) |
| 2 | On failure, notify the consuming application; intermittent-failure handling needs evidence; after a persistent failure, no output | Start-up failure: `DEAD` until reset. Running failure: buffered words wiped, back to `BIST`, start-up test rerun, output resumes if it passes | **Partly** (§5.4) |
| 3 | A documented false-positive probability, 2⁻²⁰ to 2⁻⁴⁰ recommended | α = 2⁻²⁰ is the basis of the RCT cutoff's comment; not documented for the APT cutoff, and both rest on an assumed entropy | **Partly** |
| 4 | Start-up tests run the continuous tests over at least 1,024 consecutive samples | 1,024 consecutive kept samples with no failure before the first `ES16`; with the shipped settings about 57 ms after reset | **Met** for the tests that exist |
| 5 | On-demand testing, at least the start-up tests | Any accepted write of `mentropycfg` restarts the start-up test; a reset does too. Once `mentropycfg` is locked, only a reset | **Partly**: possible, not documented as the on-demand mechanism, and nothing uses it |
| 6 | Health tests on noise-source samples before conditioning | There is no conditioning; the tests see the kept samples | **Met** |
| 7 | Documentation of every test, its rate, conditions and rationale | `rtl/karu_entropy.v` header and this document | **Partly**: rationale against the source's failure modes is missing |
| 8 | Known or suspected failure modes, with developer-defined tests for them | Not documented; no test for ring locking or common-mode coupling between lanes | **Not met** (§5.5) |
| 9 | Emphasis on detection near the edge of the operating environment | Not addressed; no data outside 24 °C and nominal supply | **Not met** |

### 5.2 The approved tests (§4.4) and the shipped cutoffs

The tests the RTL implements follow §4.4's algorithms exactly, per lane:

- RCT: a count of identical consecutive values, reset to 1 on a change;
  failure when the count reaches C (`rtl/karu_entropy.v`, `rct_n`, `rct_fail`).
- APT: the first value of each non-overlapping window of 1,024 samples, the
  count of its occurrences in the window, failure when the count reaches C
  (`apt_idx`, `apt_ref`, `apt_n`, `apt_fail`). The optional extension of
  §4.4.2 for binary sources (also checking W − B ≥ C) is not implemented.

Their cutoffs for α = 2⁻²⁰, C_RCT = 1 + ⌈20/H⌉ and
C_APT = 1 + CRITBINOM(W, 2⁻ᴴ, 1 − α), computed exactly
(`sp80090b_health.py`; the binary values match §4.4.2's Table 2):

| H | Binary RCT | Binary APT, W = 1024 | 4-bit RCT | 4-bit APT, W = 512 |
| --- | --- | --- | --- | --- |
| 0.4 per bit | 51 | 840 | — | — |
| 0.5 per bit | **41** (shipped) | 793 | — | — |
| ≈ 0.44 per bit | — | **821** (shipped) | — | — |
| 1.0 per bit | 21 | 589 | — | — |
| 3.526 per sample (D19 estimate) | — | — | **7** | **79** |

The shipped pair is inconsistent (0.5 and about 0.44 bits per bit), and
neither value follows from an assessment. Moving the APT to 793 would fix
the inconsistency but not the basis; the cutoffs should be derived from the
assessed per-sample H and a documented false-alarm target (§4.3 item 3),
after the tests are moved to the sample (§5.3).

Replay of both datasets, each a single run (`sp80090b_health.py --h 3.526340`, report
`results/health-replay-h3.526.json`):

| Dataset | Lane tests as built (41 / 821): max run, max window count, failures | 4-bit tests at H = 3.526 (7 / 79): max run, max window count, failures |
| --- | --- | --- |
| D18 | 25, 586, none | 6, 53, none |
| D19 | 22, 578, none | 6, 55, none |

No false alarm either way. The lane maxima would fail lane cutoffs derived
from H = 1 (21 and 589); that says nothing about the right cutoffs, only
that the lane bits are not 1 bit per bit.

### 5.3 The lane tests are not an alternative to the sample tests (§4.5)

§4.5 allows developer-defined tests in place of the approved ones if they
detect, with H the assessed entropy per sample:

- (a) a value repeated more than 100/H consecutive times, with probability
  of at least 99 %;
- (b) a change that raises one value's probability to P* = 2^(−H/2), with
  probability of at least 50 % within 50,000 samples.

With H = 3.526 bits per sample, 100/H = 28.36: (a) is a run of more than
28.36 identical 4-bit samples, which is 29 on a literal reading and 30 if
100/H is rounded up first; both were simulated. (b) is P* = 2^(−1.763) =
0.2946. Simulated with `sp80090b_health.py --h 3.526340` (report
`results/health-replay-h3.526.json`): in (a) the run sits among uniform
samples with neighbours that differ from it; in (b) `0000` has probability
exactly P* and the other fifteen values share the rest uniformly.

| Criterion | Required | Lane tests as built (41 / 821) | 4-bit tests (7 / 79, W = 512) |
| --- | --- | --- | --- |
| (a) 29 identical samples | ≥ 99 % | 1 of 200 (0.5 %) | 200 of 200 |
| (a) 30 identical samples | ≥ 99 % | 2 of 200 (1 %) | 200 of 200 |
| (b) `0000` at 0.2946 for 50,000 samples | ≥ 50 % | 0 of 20 | 20 of 20 |

A run of 29 or 30 identical samples gives each lane a run of that length,
under its cutoff of 41, so the lane RCT catches it only when the run
happens to extend a run already present in a lane. With `0000` at 0.2946,
each lane's ones fraction falls to about 0.38, far inside the lane APT's
821 of 1,024. On the sample, the RCT (cutoff 7) detects any run of 7 or
more deterministically; the APT's detection of a probability shift is
statistical, and it detected all 20 simulated sequences. **Item 1 of §4.3
is therefore not met**: the sample-level RCT and APT (W = 512) have to be
added, or tests that meet (a) and (b) with evidence.

### 5.4 Failure handling and notification (§4.3 item 2)

| Event | `state` | `seed` reports | Output |
| --- | --- | --- | --- |
| Reset, start-up test running | `BIST` | `BIST` | none |
| Start-up test fails | `DEAD` until reset | `DEAD` | none; rings switched off (except in test mode) |
| Running test fails | back to `BIST`, start-up test rerun | `BIST`, then `ES16` if it passes | buffered words wiped; a read in the failing cycle gets no entropy |
| Test mode, or the source disabled by the strap | — | `BIST` | none |

What is missing for §4.3 item 2:

- **Notification.** A running failure shows as `BIST`, the same state as
  start-up, test mode and a disabled source. A consumer cannot tell that a
  failure happened, and nothing counts failures. A distinct indication (a
  sticky failure flag or counter in `mentropycfg`, or the `WAIT`/`BIST`
  distinction used deliberately) is needed.
- **Intermittent versus persistent.** A fault present while the start-up
  test runs ends in `DEAD`: a lane that stays stuck after a running
  failure fails the rerun start-up test and latches `DEAD`, with no
  output. The gap is a recurring fault that passes each recovery start-up
  test and fails again in operation: the source cycles between `BIST` and
  `ES16` indefinitely, delivering words between failures, with no
  persistent notification and no escalation. SP 800-90B asks for evidence
  that failures handled this way are intermittent, and that a permanent
  failure ends in an error condition and no output. A rule (for example,
  `DEAD` after N failures within M samples) and its rationale are needed.

### 5.5 Failure modes not covered (§4.3 items 8–9)

Known or plausible failure modes of a ring-oscillator source and whether
anything detects them:

| Failure mode | Detected by | Gap |
| --- | --- | --- |
| A ring stuck at 0 or 1 | lane RCT (run of 41) | — |
| A ring locked to the sampling clock (periodic, e.g. `0101…`) | not by RCT or APT on the lane (a period-2 pattern passes both) | needs a test for short periodic patterns (§4.3 item 8 gives `101…01` as the example) |
| Rings locked to each other, or a shared disturbance (supply ripple, a 2.05 MHz tone) | the 4-bit APT only for gross coupling | no test for weak coupling; the board shows a lane 2–3 dependence |
| Loss of jitter (temperature, supply, injection) | lane APT for strong bias only | no test of the jitter itself |
| Software reconfiguration (k, cutoffs) | none | §6 |

## 6. Other requirements and architectural notes

- **Configuration is not fixed.** M-mode software can set k down to 1
  (`INTERVAL_MIN = 0`) for operational output, not only in test mode, and
  raise the cutoffs to 1,023 and 1,024. That weakens the tests to a run of
  1,023 equal bits and a window in which all 1,024 bits match; it does not
  disable them. The `mentropycfg` lock bit freezes the configuration until
  reset, but no firmware sets it. An assessment holds only for the
  assessed configuration. `INTERVAL_MIN`, `RCT_MAX` and `APT_MAX` are
  one-sided build limits and cannot fix one value. Fixing the
  configuration needs either build parameters that make k and the cutoffs
  constants with no write path, or a lock set by the boot firmware before
  any consumer reads `seed`; the assessed values should be documented
  with the clock.
- **The clock is part of the source.** Kept samples are counted in clocks
  of the 75 MHz CPU clock; a different clock or divider changes the sample
  spacing and invalidates the estimate.
- **Test interfaces.** `mnoise` and the burst capture expose raw samples
  only in test mode, during which `seed` delivers nothing, and leaving test
  mode restarts the start-up test; no captured sample is ever delivered as
  entropy. That is the separation SP 800-90B expects of raw-data access.
- **Shared consumers.** The authentication ROM and `seed` draw from the same
  buffer; a word is wiped as it is read, so no word reaches two consumers.
- **Warm-up.** None beyond the start-up test; outputs appear about 57 ms
  after reset.
- **Operating range.** All data is from one board at 23.9–24.9 °C and
  nominal supply. The die temperature and supply readout
  (`flow/fpga/karu_sysmon.v`, `0x1000_0860`) makes captures at other
  conditions recordable.
- **FPGA versus ASIC.** The rings are LUTs with hand placement; an ASIC
  source would be a different noise source with its own assessment. The
  architecture (raw samples, sample-level tests, no conditioning, test
  mode) carries over; the numbers do not.

## 7. Work to reach a defensible claim (Z6)

1. Health tests on the 4-bit sample: RCT and APT (W = 512) with cutoffs from
   the assessed H and a documented α; keep the lane tests as additional
   diagnostics. Add a test for short periodic patterns.
2. Failure reporting: a sticky failure indication readable by the consumer,
   a rule that ends a recurring operational failure in `DEAD`, and their
   rationale.
3. Fixed configuration: build-time constants (no write path) or a boot-time
   lock for k and the cutoffs; document the assessed clock and spacing.
4. Operational restart data: 1,000 restarts by power-on or reconfiguration,
   with samples read through `seed` from the first `ES16` on (§4.4).
5. Data over the operating range: temperature and supply corners, several
   boards or placements, cold starts; repeat the non-IID and restart
   assessments on each.
6. A physical rationale for H_submitter from the burst captures: a model
   with flicker and wander, crediting the white component only.
7. Optionally, a vetted conditioning component after the noise source,
   which would change the claim from per-sample entropy to full-entropy
   output (§3.1.5).

## 8. Reproduction

```sh
# NIST tools (commit 87c104d), with libdivsufsort and jsoncpp built locally
make -C SP800-90B_EntropyAssessment/cpp iid non_iid restart
# 4-bit samples: strip the run marker (bit 7) of a GetNoise capture
python3 -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(bytes(b&15 for b in d))" getnoise-k16.bin d19-sym4.bin
ea_iid -v d19-sym4.bin 4
ea_non_iid -a -v d19-sym4.bin 4
ea_restart -n -v restart-rows.bin 4 3.526340
# health-test replay and the alternative-test criteria
python3 test/dbg/board/sp80090b_health.py --h 3.526340 getnoise-k16.bin
# board data
python3 test/dbg/board/getnoise_capture.py     # k-sweep, includes k = 16
python3 test/dbg/board/getnoise_restart.py     # delayed warm restarts, 1,000 x 1,000
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
  [board acceptance 2026-11-19](../dbg/BOARD_ACCEPTANCE-2026-11-19.md),
  [board acceptance 2026-11-18](../dbg/BOARD_ACCEPTANCE-2026-11-18.md),
  [FPGA guide](fpga.md).
