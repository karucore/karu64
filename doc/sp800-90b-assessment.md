# SP 800-90B assessment of the Karu64 Zkr entropy source

Karu64's Zkr entropy source is one sampled ring oscillator behind the
RISC-V `seed` CSR, with SP 800-90B health tests and no conditioning in
hardware. This is the developer's self-assessment of it on VCU118 image
`20f8b265…`.

**The goal** is the one that the RISC-V Zkr text sets for a physical
entropy source on its SP 800-90B route: every SP 800-90B component and
health-test mechanism, and a min-entropy of 192 bits in each 256 bits
that `seed` delivers (a rate of 0.75), so that software which conditions
2:1 with a vetted conditioner obtains 128-bit full-entropy blocks. The
hardware and that software are then one SP 800-90B entropy source: noise
source, sampling and health tests in hardware, conditioning in software.
[Sign-off criteria](zkr-followup-plan.md#zkr-and-software-sign-off)

**Result.** The source implements `seed` and the SP 800-90B components
that belong in hardware. On the board, two sequential captures gave
non-IID estimates of 0.810451 and 0.838673 bits per sampled bit, and both
restart datasets pass at 0.75, including the first outputs delivered
through `seed` after 1,000 resets. **We propose 0.75 bit per delivered
bit** as the developer's estimate, for this board under the tested lab
conditions ([§1](#1-the-entropy-statement-and-its-justification)). One
step of its justification is open: how much of the ring's measured phase
variation is fresh at each kept bit, once the known disturbance and the
drift are accounted for. The conditioner is the consuming software's
part, is not in this repository, and remains to be assessed
([§6](#6-software-post-processing)).

This is a self-assessment ("self-certification" in the RISC-V text). A
validation is a separate process at an accredited laboratory. The FPGA
measurements apply to the tested bitstream and board; an ASIC needs its
own. The four-ring source of the earlier image `ddb168e1…` has
[its own dated assessment](sp800-90b-assessment-2026-11-20.md).

## 1. The entropy statement and its justification

### 1.1 The statement

**The proposed developer's estimate (H_submitter) is 0.75 bit of
min-entropy per sample**, given all earlier samples: 12 bits per `seed`
word and 192 bits per 256 delivered bits, from the first word after a
reset. It is proposed for image `20f8b265…` at k = 16 with ring mask
`0x0f`, in the conditions of §2. It is the rate that RISC-V requires, not
the most that the statistics would allow: every statistical estimate
below is higher. It stays a proposal until the open step of 1.2 is
closed.

### 1.2 Technical justification

RISC-V asks for "a stochastic model or a heuristic argument that explains
why the noise source output is from a random, rather than pseudorandom
(deterministic) process, and is not easily predictable or externally
observable", and adds that a complete physical model is not necessary.
SP 800-90B §3.2.2 asks for the same: where the unpredictability comes
from, and a technical argument for the stated rate.

**Where the unpredictability comes from.** The ring has no state but its
phase. Thermal noise in its three stages makes every period a little
longer or shorter, independently of the periods before, so the phase
performs a random walk whose variance grows in proportion to time
(Hajimiri et al.; Baudet et al.). The sampling flip-flop reads which half
of its period the ring is in at a clock edge that is not synchronised to
it. The model is that of arXiv:2102.02196: between two kept samples the
phase advances by a fixed amount plus Gaussian jitter of variance s², in
ring periods², and the bit is 1 while the phase mod 1 lies in [0, D),
D being the duty cycle as sampled. On this bitstream the ring makes 19.51
periods per clock, so a kept sample is 79,900 ring periods after the one
before, and D differs from one half by about 0.013.

**How much jitter 0.75 bit needs.** Give the predictor the exact phase at
the previous sample, the ring's frequency with all its slow wander, and
every periodic or shared disturbance: everything except the jitter that
is fresh since the previous sample. Its best guess of the next bit then
succeeds with probability p = max over u of max(q(u), 1 − q(u)),
q(u) = P(N(u, s²) mod 1 ∈ [0, D)), and the bit has −log₂ p of
min-entropy given the past (`test/dbg/board/entropy_claim.py`):

| Fresh jitter between two samples, s² (s), in ring periods | Min-entropy per bit at D = 0.513 |
| --- | --- |
| 0.05 (0.22) | 0.416 |
| **0.104 (0.32)** | **0.750** |
| 0.2 (0.45) | 0.929 |
| 0.42 (0.65) and more | 0.963, the cap that the duty cycle sets |

So the requirement is a third of a ring period of fresh jitter, standard
deviation, per kept sample: 0.22 ns in 54.6 µs.

**How much the board shows.** Three measurements of 2026-11-23, by
different instruments:

1. *The ring's own jitter, against the other rings.* The meter counts
   the periods of every ring on the same clock edges. In the difference
   of two rings' counts the sampling clock's jitter and what both rings
   see alike cancel, and the pairs give each ring's own phase variance
   by span (`rosc_own.py`). In the capture of the operating rings with
   records every 256 clocks, the term of lane 0's own variance that
   grows in proportion to the span, as fresh noise must, is 4.0 × 10⁻⁴
   periods² per clock, and 2.0 × 10⁻⁴ at the one-sided 99 % lower end of
   the fit: 0.84 periods² per kept sample at the lower end, 8 times the
   0.104 needed. **The fit does not say how much of that term is fresh.**
   The same report finds that a periodic line could add 27.8 periods² to
   a pair's phase variance, and that the fitted constant lies 25 standard
   errors below the value that counting gives, which means that part of
   the linear growth has a memory. With all six rings running the lower
   end is 0.42 (4 times the need), with a line that could add 0.69. Lane
   0's whole own variance over one kept sample is 11.7 to 19.6 periods²
   by every method and capture; most of that is slow wander and the
   line.
2. *The jitter against the sampling clock, from the bits.* Sampled every
   clock, the ring's bits lose their correlation at a rate of 4.3 × 10⁻⁴
   periods² per clock (lower end 3.5 × 10⁻⁴), and faster at longer
   spacings (`getnoise_analyze.py` on the burst captures). In proportion
   that is 1.4 to 1.8 periods² per kept sample. It counts everything
   that moves the ring against the clock at that time scale, the clock's
   own jitter included.
3. *The delivered bits themselves.* In G23, 10⁶ samples at the delivered
   spacing, no autocorrelation at lags 1 to 8 is above four standard
   errors. Under the model that needs at least 0.13 periods² per kept
   sample, which is as much as 10⁶ bits can show and gives at least
   0.754 bit. A predictor with twelve bits of context, trained on the
   first half of the capture, guesses a bit of the second half with a
   success that leaves 0.990 bit. This is about predictors that use the
   bits alone, not one that knows the disturbance.

**The statistics support the proposal.** The lowest of NIST's ten
non-IID estimators gives 0.810 bit per bit on one capture of 10⁶ bits and
0.839 on another ([§4.3](#43-initial-entropy-estimate-313-63)), and both
restart datasets pass at 0.75. They do not replace the argument:
SP 800-90B takes the initial estimate as the smaller of the developer's
estimate and the statistical one, so H_I = 0.75 holds once
H_submitter = 0.75 is justified.

**What is not counted.**

- What lane 0 shares with the other rings: the sampling clock's jitter
  and common disturbances. Over one kept sample that is 27 times lane 0's
  own variance (the meter, at 4,096 clocks). On the four-ring image it
  was the obstacle
  ([its assessment](sp800-90b-assessment-2026-11-20.md#11-the-argument-and-the-step-that-fails));
  with one ring as the source the argument does not need it.
- The slow wander of the ring's own frequency, and a periodic disturbance
  at 4,779.7 Hz that modulates all the rings by about 0.04 %
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-23.md#the-captures-74)). Both
  move the phase by many periods between samples, and both are given to
  the predictor in full.

**The open step.** The argument needs 0.104 periods² of fresh jitter per
kept sample: one eighth of the lower end of the linear term that the
meter fits for the operating rings, a quarter with all six. A heuristic argument may
supply that, as RISC-V allows; what it has to give is a reason to credit
that share as unpredictable once the 4,779.7 Hz line and the drift are
accounted for. The meter does not give one. It was built to turn
measurement 1 into a lower confidence bound under a stated model, and by
its own rules no capture gives a bound: the model of the own variance (a
constant, a linear and a quadratic term) does not fit, the constant term
is below that of counting, and the line is left in the pairs of unlike
rings. The figures above are therefore measured sizes, not bounds on
what is fresh. Until that step is closed, 0.75 is a proposal that the
physics makes plausible and that the measurements and the statistics
support, for the conditions of §2 and not beyond them
([§7](#7-other-requirements-resilience-and-limits)).

**Why the rate should not change in normal operation.** The cause is
thermal noise, which does not wear out. The meter's stationarity check
(the linear part of the own variance in eight segments of a capture)
passes on seven of the eight captures, and fails on one of the two with
records every 16,384 clocks, where the rate drifts. The ones fraction of
lane 0 is 0.487 to 0.489 in every capture of the session, and the health
tests, whose cutoffs are those of this rate, raised no alarm in 20.5
hours ([§5.5](#55-evidence)). Temperature and supply change the ring's
frequency and its jitter; no data away from the lab conditions exists.

### 1.3 Status

By the items of RISC-V's "Checklists for Design and Self-Certification":

| Item | State | Section |
| --- | --- | --- |
| ISA behaviour of `seed`: states, access control, destructive reads | **Met**, in simulation and on the board | [§3.2](#32-risc-v-requirements-at-seed) |
| Technical justification for entropy | **Proposed, with one step open.** An argument from the physics of the ring with measurements of its jitter, of the kind that RISC-V asks for. Open: a reason to credit the needed share of the measured jitter as fresh. The meter's stochastic-model bound is not established | [§1.2](#12-technical-justification) |
| Entropy source design review | Noise source, health tests and a security boundary are in place; the approved tests of SP 800-90B §4.4 run on the noise-source sample. The conditioner is software's. §4.3 of SP 800-90B item by item | [§3](#3-the-entropy-source-as-built), [§5.4](#54-43-item-by-item), [§6](#6-software-post-processing) |
| Experimental tests | NIST's non-IID estimate is 0.810 bit per bit (0.839 on a second capture), above the 0.75 required; both restart tests pass; the health tests fire, latch and end the source as designed, and raised no alarm in 20.5 hours | [§4](#4-entropy-estimation-31-63), [§5.5](#55-evidence) |
| Resilience | **Not assessed** beyond lab conditions: one board, 23.7–24.8 °C, nominal supply, no active attack | [§7](#7-other-requirements-resilience-and-limits) |

The figures, all for lane 0 at the shipped spacing (one kept bit every
4,096 clocks) with the operating ring mask:

| | |
| --- | --- |
| Developer's estimate, H_submitter (proposed) | 0.75 bit per bit: 12 bits per `seed` word, 192 per 256 bits |
| NIST non-IID estimate, H_original | **0.810451** on 10⁶ bits from the meter; 0.838673 on 10⁶ bits through GetNoise |
| Initial estimate, H_I = min(H_submitter, H_original) | 0.75, once the proposed H_submitter is justified |
| Restart tests at 0.75 | pass, on 1,000 operational restarts through `seed` and on 1,000 delayed warm restarts |
| Health tests | repetition count (cutoff 55) and adaptive proportion (W = 1024, cutoff 719), for 0.75 bit at α = 2⁻⁴⁰; no failure in an estimated 1.35 × 10⁹ samples |
| Delivery | the first `seed` word 59.4 ms after a reset; then 1,144 words per second, 256 bits in 14.0 ms |

## 2. Scope and data

| Item | Value |
| --- | --- |
| Image | VCU118 bitstream `20f8b265bc6189d5a2428bfbc5bce586c92d0c474a6cc41550e6d66d7b6c630a` ([build and sources](../dbg/MEASUREMENTS.md#fpga-image--2026-11-21); [board record](../dbg/BOARD_ACCEPTANCE-2026-11-23.md)) |
| Straps | lane 0 is the source; spacing floor k = 16; rings `0x0f` (the four lanes run outside test mode) |
| Clock | 75 MHz CPU clock (`ui_clk` ÷ 4 of the DDR4 controller) |
| Sampling | one raw sample every 256 clocks; every 16th is kept: one sample every 4,096 clocks (54.6 µs, 18,311 per second); a `seed` word is 16 samples, 65,536 clocks (1,144 words per second) |
| Health-test configuration | `mentropycfg` = `0x30c0000b3c37000f`, the reset value: repetition cutoff 55, proportion cutoff 719, the third running failure within 2²⁴ clean samples fatal; start-up test over 1,024 samples |
| Conditions | one lab VCU118; die 23.7–24.8 °C, VCCINT 0.846–0.848 V (on-chip readout); Ethernet link up; lifecycle `OPEN` |
| Tools | NIST `SP800-90B_EntropyAssessment` commit `87c104d` (`ea_non_iid` 1.1.8), built locally; `test/dbg/board/entropy_health.py` and `make entropy-test` for the health tests; `rosc_own.py` and `getnoise_analyze.py` for the jitter |

Datasets, all of 2026-11-23 (lab host, not tracked; in
`_build/dbg/board-accept-20261123-20f8b265/`, the tool inputs and outputs
in `_build/nist-90b/`):

| | Content | File (SHA-256) |
| --- | --- | --- |
| **M23** | 10⁶ consecutive samples, recorded by the meter in test mode beside the ring counts | lane 0 of `rosc-full-1/rosc-count-p256-e16-m0f.bin` (`34ff40a5…`); bits `8fc17444…` |
| **G23** | 10⁶ consecutive samples through GetNoise (`mnoise`) at k = 16 | lane 0 of `noise-run1/getnoise-k16.bin` (`5b0fe147…`); bits `ff4dd951…` |
| **S23** | operational restart data: 1,000 restarts, the first 1,000 samples of each through `seed` | `seed-restart-1/seed-restart-rows.bin` (`1e0676a0…`) |
| **W23** | delayed warm restarts: 1,000 restarts, 1,000 samples of each through GetNoise | lane 0 of `noise-run1/restart-rows.bin` (`b4f3b9f2…`); bits `8c1101c2…` |

The jitter measurements use the meter's ring counts (`rosc-full-1/`,
eight captures) and the burst captures of the same session
(`noise-run1/`).

## 3. The entropy source as built

| SP 800-90B component (§2.2) | Karu64 | Source |
| --- | --- | --- |
| Noise source | A free-running ring of three inverters, each a LUT placed by hand, at 1,463 MHz on this bitstream. A flip-flop on the 75 MHz clock samples it, with a second flip-flop against metastability; one raw sample every 256 clocks. Three more rings of 5, 7 and 9 stages run beside it; two further 3-stage rings run in test mode only. No other ring reaches `seed` or a health test. The rings are gated off during any reset | [`flow/fpga/karu_rosc_rng.v`](../flow/fpga/karu_rosc_rng.v), [`flow/fpga/rosc_constraints.tcl`](../flow/fpga/rosc_constraints.tcl), [`flow/fpga/karu_softstrap.v`](../flow/fpga/karu_softstrap.v) |
| Digitisation and decimation | Every k-th raw sample is kept: k = 16 at reset, and never less outside test mode whatever software writes. The kept bit of the 3-stage ring is the noise-source sample: what the health tests see and what `seed` delivers | [`rtl/karu_entropy.v`](../rtl/karu_entropy.v) |
| Health tests | Repetition count at lags 1 to 4 and adaptive proportion (W = 1024); a start-up test of 1,024 samples. Not run in test mode ([§5](#5-health-tests-4)) | `rtl/karu_entropy.v` |
| Conditioning | **None in hardware.** Sixteen consecutive samples are packed into a `seed` word, the first in bit 15; no bit is combined with another. Conditioning is the consuming software's ([§6](#6-software-post-processing)) | `rtl/karu_entropy.v` |
| Output | `seed` CSR (`0x015`): `OPST` (`BIST`, `WAIT`, `ES16`, `DEAD`) and 16 bits in `ES16`; words buffered (8) and released four at a time; each word is wiped as it is read. `seed` is the only way out | `rtl/karu_entropy.v`; [`rtl/karu_csr.v`](../rtl/karu_csr.v) (access rules) |
| Test interfaces | `mnoise` (`0x7C8`, GetNoise: the raw kept samples of all four lanes), the burst capture and the meter of ring counts; all in test mode only, during which `seed` reports `BIST`. `mentropycfg` (`0x7C9`): k, the two cutoffs, the strike number, the clean-sample count and a lock. `mentropystat` (`0x7CA`): the tests' state | `rtl/karu_entropy.v`, [`flow/fpga/karu_noise_burst.v`](../flow/fpga/karu_noise_burst.v), [`flow/fpga/karu_rosc_meter.v`](../flow/fpga/karu_rosc_meter.v) |
| Enable | Platform strap (SW12 position 4 on the VCU118): on holds the source off and `seed` in `BIST` | [`flow/fpga/karu_entropy_src.v`](../flow/fpga/karu_entropy_src.v) |

[The FPGA guide](fpga.md#the-ddr4-soc-linux-target) describes the
hardware in full.

### 3.1 The sample is one bit

SP 800-90B §3.1.6 counts several copies of one physical noise source as a
single source whose sample is their concatenation. Here one ring is the
source: the other rings reach neither `seed` nor a health test, so no
statement about independence between rings is needed, and none is made.
The sample is one bit, the estimate, the approved tests and their cutoffs
are for that bit, and a `seed` word holds sixteen samples.

### 3.2 RISC-V requirements at `seed`

The normative text is "Entropy Source" in the scalar cryptography chapter
of the RISC-V unprivileged specification; the test interface follows its
"Suggested GetNoise Test Interface".

| Requirement | Karu64 | Shown by |
| --- | --- | --- |
| `seed` at `0x015`; `OPST` in [31:30], `entropy` in [15:0]; `entropy` is zero unless `OPST` is `ES16` | As specified; the reserved and the custom bits read zero | `make zkr-test` |
| A read-only CSR instruction raises an illegal-instruction exception; any other form reads `seed`, and the written value is ignored | The core rejects every form that does not write, in every mode | `make zkr-test`, and `make zkr-test-spike` as a cross-check |
| Access outside M-mode only where `mseccfg.SSEED` or `USEED` grants it | S and HS mode need `SSEED`, U mode `USEED`; VS and VU mode get a virtual-instruction exception with `SSEED` set, so that a hypervisor can emulate the access, and an illegal-instruction exception otherwise | `make zkr-test`, with and without H |
| Wipe-on-read: no `entropy` word is made available twice | A word is wiped as it is read; buffered words are wiped on every restart and failure | `make entropy-test` |
| `BIST` during the self-test, and as the non-fatal alarm "latched until polled at least once" | `BIST` through the start-up test; after a running failure `BIST` until one `seed` access has seen it, however much later | `make entropy-test`; on the board ([§5.5](#55-evidence)) |
| `WAIT` when no word is available yet | As specified | `make entropy-test` |
| `DEAD`: an unrecoverable self-test error | A failure in a start-up test, or the third running failure; until reset, with the noise source switched off | `make entropy-test`; on the board |
| Initialization, test mode and health alarms are signalled | All three read as `BIST`; a fatal failure as `DEAD` | the same |
| A physical source on the SP 800-90B route: all required components and health-test mechanisms | [§3](#3-the-entropy-source-as-built), [§5](#5-health-tests-4); the conditioner in software | this document |
| 192 bits of min-entropy in each 256 bits of `ES16` output, a rate of 0.75 | Proposed as the developer's estimate, with NIST's estimates of 0.810 and 0.839; one step of its justification is open | [§1](#1-the-entropy-statement-and-its-justification), [§4](#4-entropy-estimation-31-63) |
| Test interface (suggested): a custom M-mode CSR; with `noise_test` set, `seed` returns no `ES16`; on leaving, back through zeroization and self-test | `mnoise` at `0x7C8`: `seed` reports `BIST` in test mode; leaving it empties the buffer and runs the start-up test again. No captured sample is ever delivered as entropy | `make zkr-test`, `make noise-burst-test` |

On the board, U-Boot and Linux read `seed` in every boot and the
debug-authentication ROM in every authentication. The
[acceptance](../dbg/BOARD_ACCEPTANCE-2026-11-23.md) passes with the
source on, and the boot with the source off (U-Boot's and the ROM's
time-out paths) in its `entropy-off` case.

<a id="current-board-measurement"></a>

## 4. Entropy estimation (§3.1, §6.3)

### 4.1 Data collection (§3.1.1)

M23 and G23 are 10⁶ consecutive samples each, at the shipped spacing and
ring mask, each a single run without a lost sample. Both are taken in
test mode: the samples are the kept samples that the health tests and
`seed` would see, but the capture is not the operational output path.
M23 was recorded by the meter beside the ring counts, with the hart
running the capture payload's polling loop (die 24.09–24.83 °C); G23
through `mnoise` by `test/dbg/board/getnoise_capture.py` (die
24.09–24.31 °C). The tool input is one bit per byte. S23 comes through
the operational path, `seed` ([§4.4](#44-restart-tests-314)).

### 4.2 IID or non-IID track (§3.1.2)

No IID claim is made. The physics says otherwise: at shorter spacings
the ring's bits are strongly correlated, its jitter grows faster than
white noise, and its frequency wanders. The source is assessed on the
non-IID track.

### 4.3 Initial entropy estimate (§3.1.3, §6.3)

`ea_non_iid -a -v <file> 1`:

| Estimator (§6.3) | M23 | G23 |
| --- | --- | --- |
| Most common value | 0.963013 | 0.961253 |
| Collision | 0.928380 | 0.883823 |
| Markov | 0.966405 | 0.962838 |
| Compression | **0.810451** | **0.838673** |
| t-tuple | 0.934685 | 0.911890 |
| LRS | 0.965639 | 0.965639 |
| MultiMCW prediction | 0.973931 | 0.969879 |
| Lag prediction | 0.994518 | 0.996204 |
| MultiMMC prediction | 0.963387 | 0.961526 |
| LZ78Y prediction | 0.963171 | 0.961285 |
| **H_original** | **0.810451** | **0.838673** |

48.83 % of the bits of M23 and 48.77 % of G23 are 1, and the
most-common-value estimate is that bias. The compression estimate is the
lowest on both. Lane 0 of the three earlier bitstreams, the same ring
with other routings, gave 0.864, 0.851 and 0.834.

H_I = min(H_submitter, H_original). With the proposed H_submitter it is
min(0.75, 0.810451) = **0.75 bit per sample**, and it stands once that
proposal is justified ([§1.2](#12-technical-justification)). A `seed`
word holds sixteen samples.

### 4.4 Restart tests (§3.1.4)

**Operational restart data (S23).** §3.1.4.1 asks for samples collected
"as soon as the entropy source is ready to produce outputs for real-world
use". `test/dbg/board/seed_restart.py` restarts the source 1,000 times by
a debugger reset (`ndmreset`, with `haltreq` held). That resets the hart,
the SoC and the entropy source through the same reset sequencer as the
software reset; the rings are gated off while the reset lasts and start
again. DDR calibration, the clocks and the Debug Module are not reset.
After each reset:

1. the hart halts before its first instruction (checked: DPC is the reset
   vector), so the boot ROM never runs and nothing reads `seed` before
   the payload;
2. the host points DPC at `test/dbg/board/seedcap.S`, already in DRAM,
   and resumes the hart 5.3 to 15.1 ms (median 8.5 ms) after the reset
   was released;
3. `seedcap.S` reads `seed` in the reset configuration (no test mode, no
   `mentropycfg` write), polling without a pause, and stores the first 63
   words that the source delivers, of which the first 1,000 bits are
   kept.

In every restart the payload polled `BIST` before the first `ES16`, so no
word was delivered before it, and its longest gap between two polls was
161 clocks against 65,536 per word, so no sample was dropped. The first
word came 58.9 to 59.9 ms after the reset was released (median 59.41 ms),
which is the start-up test of 1,024 samples and one burst of four words:
4,456,448 clocks, 59.4 ms, in simulation. No restart had to be repeated
and none raised a health-test alarm. The rows were checked bit for bit
against the words as `seed` delivered them. `make dbg-seedcap-test` shows
on the simulation bench that the payload stores exactly the first samples
after the start-up test, in order, and that a late start, `DEAD` and an
alarm are reported.

**Delayed warm restarts (W23).** The same restarts with the samples taken
through GetNoise at least 150 ms after each reset, after a further
digital restart by the payload's entry into test mode
(`getnoise_restart.py`). A cross-check; no retries.

| `ea_restart -n -v <rows> 1 0.75` | S23 | W23 |
| --- | --- | --- |
| Sanity check (§3.1.4.3): largest count of one value at one position, over rows and columns | X_max = 565, cutoff 662: passed | X_max = 576, cutoff 663: passed |
| H_r (row dataset), H_c (column dataset) | 0.816320, 0.851729 | 0.817418, 0.862506 |
| Validation (§3.1.4.2): min(H_r, H_c) ≥ H_I / 2 | passed | passed |
| min(H_r, H_c, H_I) | **0.75** | 0.75 |

Both also pass with the measured 0.810451 as the trial value (cutoffs 639
and 638). The tool simulates its cutoff, so a replay can give a slightly
different one.

**Not covered:** restarts by power-on or reconfiguration at this count.
In the session's six power-ons by reconfiguration with the source on, the
first consumer had its words each time: the authentication ROM its nonce
in four, U-Boot its `kaslr-seed` in three.

<a id="entropy-claim-for-the-first-word-after-reset"></a>

### 4.5 The first word after a reset

Software that reads one word at boot gets the word that S23 records.
Over the 1,000 restarts the first `seed` word took 995 distinct values,
and the most frequent occurred twice. For a population word of maximum
probability p_max, its count is Binomial(1000, p_max) if the restarts are
independent draws from one distribution, and it can be no larger than the
observed maximum of two. Inverting the one-sided binomial test at 1 %
gives p_max ≤ 0.008380, so −log₂ p_max ≥ 6.89 bits at 99 % confidence.
That is all that 1,000 restarts can show about a 16-bit word: it is a
check that the first word is not a constant or one of a few values, and
no more. It bounds a guess made from the test configuration alone; it
does not establish independence of the resets, and it does not cover a
predictor that observes clock phase, reset timing or other physical
state.

### 4.6 What the estimate does and does not establish

- It is for one board, one bitstream and 23.7–24.8 °C at nominal supply,
  not for the operating range that SP 800-90B asks a statement to hold
  over (§3.2.1 item 3, §4.3 item 9).
- The ring's frequency relative to the clock depends on the routing, and
  with it how neighbouring samples relate. Over four bitstreams the
  estimate for lane 0 at the shipped spacing stayed between 0.81 and 0.87
  (0.834, 0.851, 0.864, 0.810), but a characterisation belongs to a
  bitstream.
- NIST's figures are statistical estimates on 10⁶ samples. They are the
  conservative part of the method, not a physical bound, and they cannot
  see a predictor that knows more than the bits.
- The proposed 0.75 is about the bit sequence given its past. An
  observer of the ring's phase, or one who can impose a frequency on the
  ring, is outside it ([§7](#7-other-requirements-resilience-and-limits)).

## 5. Health tests (§4)

### 5.1 What the block does

| | `rtl/karu_entropy.v` |
| --- | --- |
| Tests on the sample | The repetition count (§4.4.1) and the adaptive proportion test with W = 1024 (§4.4.2): the approved tests for a binary sample. The repetition count also runs at lags 2 to 4 (the bit equal to the bit g samples earlier), which catches patterns of period 2 to 4 such as `0101…`: developer-defined tests for the source's failure modes (§4.3 item 8), beside the approved ones |
| Start-up | Both tests over 1,024 consecutive samples before the first word; those samples are not delivered |
| A running failure | The buffered words are wiped, the start-up test runs again, and `seed` reports `BIST` until one `seed` access has seen the failure |
| A recurring failure | Counted as strikes; the third without 2²⁴ clean samples in between is fatal (`DEAD`) |
| A failure in a start-up test | `DEAD`, including the retest after a running failure |
| Configuration | k, the two cutoffs, the strike number and the clean-sample count are writable through `mentropycfg`. **The reset values are the weakest configuration**: software can make the tests stricter and the spacing longer, not the reverse. A lock bit freezes the CSR and test mode until reset |
| Test mode | Takes any k and any ring mask, for characterisation; `seed` delivers nothing there, and the tests do not run |
| Status for the consumer | `OPST`, with the latched alarm; and `mentropystat` (M-mode, read-only): state, alarm, strikes, which test and lags failed last, failures since reset |

### 5.2 Cutoffs and the false-alarm probability

A cutoff follows from a min-entropy H per sample and a false-alarm
probability α per test (`test/dbg/board/entropy_health.py cutoffs`):

- repetition count: C = 1 + ⌈−log₂α / H⌉ (§4.4.1);
- proportion: the smallest C with P(1 + B(W−1, 2⁻ᴴ) ≥ C) ≤ α. The first
  sample of a window always counts. The formula printed in §4.4.2,
  1 + CRITBINOM(W, 2⁻ᴴ, 1 − α), gives the same cutoff here.

A bit with min-entropy h given the past equals any bit determined by the
past with probability at most 2⁻ʰ, so the bound of §4.4.1 holds at every
lag.

**The reset values are for H = 0.75 and α = 2⁻⁴⁰: 55 and 719.** They are
the cutoffs of the proposed rate.

| Test | Cutoff | Alarm probability of a source exactly at H = 0.75, in units of α | A healthy source trips it about every |
| --- | --- | --- | --- |
| Repetition, lags 1 to 4 | 55 | 0.71 per run | 10,500 years |
| Proportion, W = 1024 | 719 | 0.77 per window | 10²⁶ years |

"Healthy" is a source of independent bits with lane 0's measured bias,
0.512, at 18,311 samples per second (`false_alarms` in
`entropy_health.py`). The `cutoffs` command prints the figures for a bias
of 0.509, 12,300 years and 10²⁷: the bias matters, 0.003 more of it
raises the repetition alarm rate by 18 %. The row for the repetition
count adds up the four lags, whose events overlap, so it is an upper
bound on the alarm probability under that model. It says nothing about a real source's
dependence. α is 2⁻⁴⁰ and not 2⁻²⁰ because of the sample rate: every
false alarm costs a retest and a strike.

The cutoffs are configuration. Software may write stricter ones, for
example 51 and 695 for 0.81 bit at the same α
(`entropy_health.py cutoffs --h 0.81`); nothing weaker than the reset
values is accepted.

### 5.3 Failure handling (§4.3 item 2)

- **Notification.** A running failure is the non-fatal alarm of the Zkr
  text: `seed` reports `BIST` from the failure until one `seed` access
  has seen it, and delivers nothing meanwhile. A fatal failure is `DEAD`
  until reset, with the noise source switched off. `mentropystat` tells
  M-mode which test and lags failed and how often.
- **Intermittent or persistent.** A failure during any start-up test,
  including the retest after a running failure, is fatal. A running
  failure is a strike; 2²⁴ samples in a row without a failure (15
  minutes) clear the strikes; the third strike is fatal. Both numbers
  are configuration (`strikes`, `calm`), with the same one-sided limits.
  A `mentropycfg` write clears neither a strike nor the alarm.
- **Evidence for "extremely likely intermittent".** A failure is treated
  as intermittent only if the source then passes a full start-up test
  and, for it to be forgotten, 2²⁴ further samples under both tests.
  Under the model of 5.2 a healthy source fails about once in 10,500
  years, so three failures within the forgiveness time are taken as a
  fault and end the source.
- **Evidence for "a permanent failure is detected and ends in an
  error".** A fault that stays fails the retest, which is fatal: for a
  stuck or periodic ring within 58 samples of the first failure
  (3.2 ms). A fault that goes away and comes back within 15 minutes is
  fatal at its third occurrence. A fault that comes back less often is,
  by this rule, intermittent; every occurrence still wipes the buffer
  and raises the alarm.

### 5.4 §4.3 item by item

| §4.3 item | Requirement (paraphrased) | Karu64 | State |
| --- | --- | --- | --- |
| 1 | Continuous tests: the approved tests of §4.4, or developer-defined tests meeting §4.5 | §4.4.1 and §4.4.2 on the binary sample; the repetition count at lags 2 to 4 in addition | **Met** |
| 2 | On failure, notify the consuming application; intermittent-failure handling needs evidence; after a persistent failure, no output | Latched alarm, strikes, `DEAD` (5.3); shown on the board with induced failures (5.5) | **Met in mechanism**; how the real source fails has not been observed |
| 3 | A documented false-positive probability, 2⁻²⁰ to 2⁻⁴⁰ recommended | 2⁻⁴⁰ per test, with the cutoffs derived for the proposed rate (5.2) | **Met** |
| 4 | Start-up tests run the continuous tests over at least 1,024 consecutive samples | Both tests over 1,024 samples before the first `ES16`; on the board the first output comes 59.4 ms after a reset | **Met** |
| 5 | On-demand testing, at least the start-up tests | An accepted `mentropycfg` write from M-mode restarts the start-up test, as does a reset; once locked, only a reset ([§6](#6-software-post-processing)) | **Met** |
| 6 | Health tests on noise-source samples before conditioning | There is no conditioning in hardware; the tests see the kept samples | **Met** |
| 7 | Documentation of every test, its rate, conditions and rationale | The header of `rtl/karu_entropy.v` and this section | **Met** |
| 8 | Known or suspected failure modes, with developer-defined tests for them | The table below | **Partly**: two failure modes have no test of their own |
| 9 | Emphasis on detection near the edge of the operating environment | No data outside 24 °C and nominal supply | **Not met** |

Failure modes of a ring-oscillator source and what detects them:

| Failure mode | Detected by | Gap |
| --- | --- | --- |
| The ring stuck at 0 or 1 | repetition count at lag 1, at the 55th sample | — |
| The ring locked to the sampling clock in a short period (`0101…`, period 2 to 4) | repetition count at lags 2 to 4, at the 56th to 58th sample | longer periods |
| A biased ring | proportion test: a bias of 0.74 within four windows | — |
| The ring locked to another ring or to a disturbance (supply ripple, an injected tone) | the tests above, if the lock leaves a short period or a bias | no test for a lock that leaves neither |
| Loss of jitter (temperature, supply) that leaves no short period | the proportion test for a strong bias only | no test of the jitter itself |
| Software reconfiguration | one-sided limits; the lock | the boot chain sets no lock ([§7](#7-other-requirements-resilience-and-limits)) |

### 5.5 Evidence

**Simulation and replay** (`make entropy-test`; passed on the current
sources on 2026-11-24):

- **Directed cases and mutants.** `test/tb_entropy.sv` has each test at
  its cutoff and one sample short of it, the alarm and its owner, the
  strikes, the limits and the status register (12,894 checks). 108
  one-mechanism mutants of the module are each caught by the check
  written for them.
- **The block against a reference model.** `entropy_health.py` is the
  health logic in Python. `test/entropy_replay.py` feeds the same symbols
  to the RTL and to the model and compares every failure, the status
  register after it and every word delivered: healthy symbols, every
  kind of fault at every lag, the same faults on the lanes that are not
  the source (which must raise nothing), strikes, forgiveness, a failure
  during start-up, and random cases with random cutoffs and `seed`
  accesses (51 checks with the four board files below). A model that
  differs by one in any one setting does not agree.
- **The criteria of §4.5**, at H = 0.75 and the reset cutoffs
  (`entropy_health.py criteria`). They are supplementary: the block
  implements the approved tests. (a) More than 100/H = 133.3 identical
  samples: 200 of 200 runs of 134 and of 135 are detected, by the 55th
  sample. (b) One value at P* = 0.771 for 50,000 samples: 20 of 20, the
  slowest after 2,481 samples.
- **Failure modes** (same command): the ring stuck at 0 or 1 is detected
  at its 55th sample, a pattern of period 2, 3 or 4 at its 56th to 58th,
  a bias of 0.741 within 3,559 samples; none missed in 40 trials each.
- **The board captures replayed**, in the RTL and in the model, at the
  reset cutoffs:

  | Dataset | Failures | Largest repetition count, any lag (cutoff 55) | Largest window count (cutoff 719) |
  | --- | --- | --- | --- |
  | M23, 10⁶ consecutive samples | none; ends running | 19 | 568 |
  | G23, 10⁶ consecutive samples | none; ends running | 23 | 575 |
  | S23, 1,000 restarts of 1,000, each from reset | none | 20 | 560 |
  | W23, the same | none | 21 | 576 |

  M23 and G23 raise no failure at much tighter cutoffs either (24 and
  633). A row of S23 or W23 has 1,000 samples, fewer than the 1,024 of
  the start-up test: those rows show no false alarm in the first 1,000
  samples after a restart.

**On the board, the healthy source.** `mentropystat` was read without a
reset before most resets of the session
([record](../dbg/BOARD_ACCEPTANCE-2026-11-23.md#health-tests)): every
reading was `0x1`, running with no failure since reset. The intervals
read add up to 20.5 hours outside test mode, the longest 17 h 59 min: an
estimated 1.35 × 10⁹ samples. In S23 every one of the 1,000 start-up
tests passed.

**On the board, induced failures** (`test/dbg/board/entropy_fault.py`,
five cases, all pass). Software may make the tests stricter, and a cutoff
far below its reset value makes the real ring fail that test within
seconds. Each case starts from a debugger reset, with the hart halted, so
nothing else reads `seed`:

| Case | What the board did |
| --- | --- |
| Start-up failure | fatal at once: `DEAD`, no alarm and no strike |
| Each test | with a repetition cutoff of 18 the ring failed after 0.12 s, with a proportion cutoff of 550 after 2.7 s; `mentropystat` named the test, lane 0 and, for the repetition count, the lag; each raised the alarm and one strike |
| Strikes | the alarm stayed until one `seed` access had seen it; a `mentropycfg` write cleared neither it nor the strike; the third running failure was fatal and `seed` read `DEAD` |
| Forgiveness | 2²⁴ clean samples cleared a strike after 917 s; they take 916 s |
| Limits | every field written weaker than its reset value, and k = 1: the cutoffs, the strike number and the clean-sample count read back as the build's limits, and a word through `seed` still took 65,536 clocks, which is k = 16; with the lock set a write changed nothing |

These show the mechanism on real noise. The failures are those of
stricter tests on a healthy source, not of a failing source.

### 5.6 For software that writes `mentropycfg`

The fields are the interval `[15:0]` (k − 1), the repetition cutoff
`[25:16]`, the proportion cutoff `[36:26]`, the strike number `[56:54]`,
the clean-sample count `[61:57]` and the lock `[63]`; the rest read zero
and ignore writes. A constant that leaves a cutoff field zero fails on
the next sample, which during the start-up test is fatal: `seed` reports
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

The capture payloads (`test/dbg/board/getnoise.S`) do it this way.
Nothing in the boot path (fu-boot, the island ROM, OpenSBI, U-Boot,
Linux) writes `mentropycfg`.

## 6. Software post-processing

RISC-V puts the cryptographic conditioner on the software side of `seed`:
"the `entropy` ES16 output must always be compressed 2:1 (or more) before
being used as keying material or considered 'full entropy'". For the
SP 800-90B route the software module and this source are assessed
together. What the module has to do:

1. **Poll** with `csrrw rd, seed, x0` and take bits [15:0] only when
   `OPST` is `ES16`. `WAIT` and `BIST` mean "no word yet": poll again.
   After a reset `BIST` lasts 59.4 ms. A `BIST` that follows `WAIT` or
   `ES16` is the non-fatal alarm: log it. `DEAD` is final until reset:
   stop, and do not fall back to a weaker source.
2. **Collect at least sixteen `ES16` words, 256 bits, for every 128 bits
   of output.** They need not come from consecutive polls. At 1,144
   words per second that is 14 ms per block.
3. **Condition with a vetted conditioner** of SP 800-90B §3.1.5.1.1: an
   approved hash, HMAC, CMAC, CBC-MAC, or one of the derivation
   functions of SP 800-90A. The entropy of its output follows from
   §3.1.5.1.2 with the chosen function's output length and its narrowest
   internal width, and a digest that is truncated has a rule of its own,
   so that figure belongs to the software's assessment. As one example,
   AES-CMAC with its native 128-bit output (n_out = nw = 128) on 256 bits
   of input that hold 192 bits of min-entropy gives 128 − 10⁻¹⁸ bits by
   that section's formula, and the input meets the n + 64 bits that
   SP 800-90C asks for a full-entropy block of n = 128 bits, with
   nothing to spare. Taking more input per block gives a margin against
   a rate lower than the one proposed; RISC-V recommends at least 512
   bits to seed a DRBG of 256-bit strength.
4. **Test the conditioner against known answers**, and whatever DRBG it
   seeds.
5. **Leave the configuration alone, or tighten and lock it.** The reset
   configuration is the assessed one and needs no write. Boot firmware
   may set the `mentropycfg` lock before the first consumer runs; set
   outside test mode, the lock also keeps test mode off until reset. The
   on-demand test of SP 800-90B is a `mentropycfg` write from M-mode,
   which runs the start-up test again, or a reset.
6. **Keep the source to one trusted consumer.** A word that one reader
   takes is gone for the others, and polling by one delays another. Give
   lower privilege modes a virtual source (a DRBG seeded from `seed`)
   rather than `mseccfg.SSEED` or `USEED`, unless they are trusted.

**No such module is in this repository.** The software that reads `seed`
on the board makes no entropy statement of its own: OpenSBI enables
S-mode access when the device tree lists `zkr`; U-Boot takes a
`kaslr-seed` for the kernel's address layout; Linux mixes `seed` words
into its pool and, with the lab's `random.trust_cpu=off`, credits them
with nothing; the debug-authentication ROM uses sixteen words as a
nonce, which needs uniqueness and not secrecy.

## 7. Other requirements, resilience and limits

- **Operating range.** All data is from one board at 23.7–24.8 °C and
  nominal supply (§3.2.1 item 3). The die temperature and supply readout
  (`flow/fpga/karu_sysmon.v`, `0x1000_0860`) is recorded with every
  capture, so that captures at other conditions can be compared.
- **The clock and the routing are part of the source.** Samples are
  counted in clocks of the 75 MHz CPU clock; a different clock, divider
  or routing of the ring changes the spacing or the ring's frequency
  relative to the clock, and the estimate with it. The lane, the spacing
  floor and the ring mask are straps of the routed design and belong to
  the assessed configuration.
- **The security boundary** (§3.2.2). The noise source, the tests and
  the buffer are inside the SoC; `seed` is the only way out for a word,
  and a word is wiped as it is read. Raw samples and ring counts are
  visible only in test mode, which only M-mode or a debugger can enter
  and during which `seed` delivers nothing; leaving it restarts the
  start-up test. The running counts of the tests cannot be read;
  `mentropystat` shows M-mode which test failed last and how often, and
  a reset clears it. A debugger with access to the hart has M-mode's
  view: in lifecycle `OPEN`, as on the lab board, that is anyone on the
  JTAG cable ([debug authentication](debug-auth-plan.md)).
- **Observation and influence.** Not assessed: electromagnetic or power
  observation of the ring's phase, and injection of a frequency through
  the supply, which can lock a ring oscillator. The health tests catch a
  lock only when it leaves a short period or a bias (5.4). The periodic
  disturbance at 4,779.7 Hz that the meter sees on all rings is given
  to the predictor in the argument of 1.2; its origin on the board is
  not known.
- **Configuration.** The reset values are the weakest that the CSR
  accepts, and outside test mode the source keeps at least the strap's
  spacing whatever is written (both shown on the board, 5.5). Nothing in
  the boot chain writes `mentropycfg`, and nothing sets the lock.
- **Warm-up.** None beyond the start-up test; the first word comes
  59.4 ms after a reset.
- **FPGA and ASIC.** The rings are LUTs with hand placement. An ASIC
  source would be a different noise source with its own measurements
  and assessment. The architecture carries over (raw samples, one ring
  as the source, sample-level tests, no conditioning, test mode, the
  operational restart capture, the meter); the numbers do not.

## 8. Open items

In order of weight for the goal:

1. **The rate justification**: a reason to credit at least 0.104
   periods² per kept sample, an eighth of the meter's fitted linear term,
   as fresh once the 4,779.7 Hz line and the drift are accounted for
   ([§1.2](#12-technical-justification)). Until then 0.75 is a proposed
   estimate. An analysis that models the line and the wander, or a
   measurement in which they are absent or cancel, would close it; so
   would a bound from the meter under its stated model.
2. **The software module**: a vetted conditioner with its known-answer
   tests and its handling of `BIST`, `WAIT` and `DEAD`
   ([§6](#6-software-post-processing)), the entropy of its output for the
   construction chosen, and the combined assessment that names its
   version and configuration.
3. **The operating range**: captures at other temperatures and supply
   voltages, on other boards and placements, and restarts by power-on;
   the non-IID estimate, the restart test and the jitter measurement on
   each. Until then the proposal is for the conditions of §2
   (§4.3 item 9).
4. **The lock**: boot firmware that sets it before the first consumer.
5. **Failure modes without a test of their own**: a lock that leaves no
   short period, and a loss of jitter; a test, or a rationale for why
   the existing ones suffice (§4.3 item 8).
6. **The 4,779.7 Hz disturbance**: its origin.

## 9. Reproduction

Run from the repository root with the NIST tools (commit `87c104d`) on
the path. The data is in `_build/dbg/board-accept-20261123-20f8b265/` on
the lab host.

M23: each 16-byte meter record holds two little-endian 64-bit words, and
lane 0 is `DATA1[60]`.

```sh
A=_build/dbg/board-accept-20261123-20f8b265
tmpdir=$(mktemp -d)
python3 - "$A/rosc-full-1/rosc-count-p256-e16-m0f.bin" "$tmpdir/m23-lane0.bin" <<'PYTHON'
from hashlib import sha256
from pathlib import Path
import sys

records = Path(sys.argv[1]).read_bytes()
assert len(records) == 1_000_000 * 16
assert sha256(records).hexdigest() == "34ff40a54260af500b631385f81fe6826aafd1b49ac6ab946ecb8e5cc3ff62fd"
samples = bytes((byte >> 4) & 1 for byte in records[15::16])
assert sha256(samples).hexdigest() == "8fc17444534f21ab856a278c5ea70b0813801389c5fea4f99f68c34f3c2b0cb3"
Path(sys.argv[2]).write_bytes(samples)
PYTHON
ea_non_iid -a -v "$tmpdir/m23-lane0.bin" 1
```

G23 and W23: lane 0 is bit 0 of every byte of a GetNoise capture.

```sh
lane0() { python3 -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(bytes(b&1 for b in d))" "$1" "$2"; }
lane0 "$A/noise-run1/getnoise-k16.bin" "$tmpdir/g23-lane0.bin"   # ff4dd9510f43f458c8a065d5c897809643dfdcb7eca7353f6884fe9a82799d51
lane0 "$A/noise-run1/restart-rows.bin" "$tmpdir/w23-lane0.bin"   # 8c1101c22ed886e924411ab4b235b6c09e298b8b68f7a002db950c78479c38d6
ea_non_iid -a -v "$tmpdir/g23-lane0.bin" 1
```

The restart tests:

```sh
rows=$A/seed-restart-1/seed-restart-rows.bin
sha256sum "$rows"  # 1e0676a0df8d19984c9b01103da9f92181ca133bf2f72cdfacbdf6574d596b72
ea_restart -n -v "$rows" 1 0.75
ea_restart -n -v "$tmpdir/w23-lane0.bin" 1 0.75
```

The first-word bound of 4.5, from the same rows (one byte per bit, the
first bit of a word first):

```sh
python3 - "$rows" <<'PYTHON'
from collections import Counter
from math import comb, log2
from pathlib import Path
import sys

rows = Path(sys.argv[1]).read_bytes()
assert len(rows) == 1_000_000 and set(rows) == {0, 1}
counts = Counter(rows[i:i + 16] for i in range(0, len(rows), 1000))
n, maximum = sum(counts.values()), max(counts.values())
lo, hi = 0.0, 1.0
for _ in range(60):
    p = (lo + hi) / 2
    tail = sum(comb(n, k) * p**k * (1 - p)**(n - k) for k in range(maximum + 1))
    if tail > 0.01:
        lo = p
    else:
        hi = p
print(n, len(counts), maximum, hi, -log2(hi))
PYTHON
```

The jitter of 1.2 and the health tests of §5:

```sh
# the ring's own jitter from the meter's counts (measurement 1), and the bound's table
python3 test/dbg/board/rosc_own.py "$A/rosc-full-1/rosc-count-p256-e1-m0f.bin" --text
python3 -c "import sys; sys.path.insert(0,'test/dbg/board'); import entropy_claim as e; print(e.variance_needed(0.513, 0.75))"
# the bits: bursts and the k-sweep (measurements 2 and 3)
python3 test/dbg/board/getnoise_analyze.py "$A"/noise-run1/getnoise-k*.bin "$A"/noise-run1/getnoise-burst-p*.bin
# health tests: cutoffs, criteria and failure modes on the model; the block, its mutants, and the captures replayed
python3 test/dbg/board/entropy_health.py cutoffs --h 0.75 --alpha 40
python3 test/dbg/board/entropy_health.py criteria
make entropy-test ENTROPY_LANE=0 ENTROPY_DATA="$tmpdir/m23-lane0.bin $tmpdir/g23-lane0.bin" \
    ENTROPY_RESTART="$rows $tmpdir/w23-lane0.bin"
make zkr-test dbg-seedcap-test
# board data (server.cfg, lifecycle OPEN, source on)
python3 test/dbg/board/rosc_count.py           # the meter: counts and M23
python3 test/dbg/board/getnoise_capture.py     # k-sweep, includes G23
python3 test/dbg/board/seed_restart.py         # S23
python3 test/dbg/board/getnoise_restart.py     # W23
python3 test/dbg/board/entropy_fault.py        # induced failures
```

The recorded tool outputs are in `_build/nist-90b/results/`
(`m23-lane0-non_iid.txt`, `g23-k16-lane0-non_iid.txt`,
`s23-lane0-restart*.txt`, `w23-lane0-restart*.txt`).

## References

- NIST SP 800-90B, *Recommendation for the Entropy Sources Used for Random
  Bit Generation*, January 2018,
  <https://doi.org/10.6028/NIST.SP.800-90B>. Sections cited: 2.2,
  3.1.1–3.1.6, 3.2, 4.3, 4.4, 4.5, 6.3.
- NIST SP 800-90B entropy assessment tools,
  <https://github.com/usnistgov/SP800-90B_EntropyAssessment>, commit `87c104d`.
- *The RISC-V Instruction Set Manual, Volume I*, scalar cryptography
  chapter: "Entropy Source" with "The seed CSR", "Entropy Source
  Requirements" and "Access Control to seed"; and, non-normative,
  "Checklists for Design and Self-Certification", "Security Controls and
  Health Tests", "Cryptographic Conditioners" and "Suggested GetNoise
  Test Interface"
  (<https://docs.riscv.org/reference/isa/unpriv/scalar-crypto.html>;
  source `src/unpriv/zk.adoc`, read 2026-11-24). Volume II for
  `mseccfg`.
- M.-J. O. Saarinen, *On Entropy and Bit Patterns of Ring Oscillator
  Jitter*, arXiv:2102.02196.
- A. Hajimiri, S. Limotyrakis, T. H. Lee, *Jitter and Phase Noise in Ring
  Oscillators*, IEEE Journal of Solid-State Circuits 34(6), 1999.
- M. Baudet, D. Lubicz, J. Micolod, A. Tassiaux, *On the Security of
  Oscillator-Based Random Number Generators*, Journal of Cryptology
  24(2), 2011.
- Karu64: [Zkr follow-up plan](zkr-followup-plan.md),
  [board record 2026-11-23](../dbg/BOARD_ACCEPTANCE-2026-11-23.md),
  [four-ring assessment 2026-11-20](sp800-90b-assessment-2026-11-20.md),
  [FPGA guide](fpga.md).
