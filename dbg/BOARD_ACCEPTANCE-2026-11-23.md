# VCU118 acceptance — 2026-11-23 and 24: one-ring image, meter, `seed` data

The first board session of image `20f8b265…`, the one-ring entropy source
of Z7 ([Zkr follow-up plan](../doc/zkr-followup-plan.md#z7-one-ring-for-seed-and-the-measurement-of-its-own-jitter)),
following section 7 of [the board test plan](BOARD_TEST_PLAN.md#7-the-next-image-one-ring-for-seed),
with SW12 changed only for stage E on November 24. **Accepted, with
documented exceptions**, as on 2026-11-20:

- translation fails with the six known pristine-OpenOCD walker results;
- the OpenSSL matrix hits its 600 s limit in phase 12 and is completed by
  phase 13 (92 pairs, none missing or bad);
- stage A's own boot was not run: the boot with the source off is shown
  by the `entropy-off` case, in lifecycle `AUTH`; the cases `open`,
  `fresh-nonce`, `no-hold`, `reboot-locked` and `disabled` were not run.

Stages B, C, D, E, F and G pass.

- Authentication with SHA3 and the bundle's key works with the nonce from
  this image's `seed` (16 words of 65,536 clocks): unlock 0.19 s after the
  request; a wrong or replayed response is refused; the window closes at
  14.3 s; with the source off it closes after 1.78 s without a challenge.
- The health tests: every `mentropystat` reading is `0x1` with 0
  failures, two long runs of 2 h 08 min and 17 h 59 min among them; the
  five induced-failure cases pass.
- The image boots Linux with the source on: no "No RNG device" from
  U-Boot in any boot with the source on, a `kaslr-seed` in `/chosen`,
  `linux_zkr.py` 3 of 3; U-Boot's `rng` command reads `seed`.
- The meter is qualified on all six rings (7.3).
- No capture gives a bound on lane 0's own jitter (7.4): every verdict is
  *not established*. A 4,779.7 Hz disturbance common to the rings, and a
  growth that is not all fresh at short spans, fail the analysis's checks.
- Lane 0 at the shipped spacing: NIST's non-IID estimate is **0.810451 bit
  per bit** on 10⁶ consecutive bits from the meter (0.838673 through
  GetNoise), and 1,000 restarts of 1,000 bits through `seed` pass the
  restart test at that value. The first word after a reset comes at
  59.4 ms, as simulated for k = 16.

## Image and evidence

| Item | Tested value |
| --- | --- |
| Bitstream SHA-256 | `20f8b265bc6189d5a2428bfbc5bce586c92d0c474a6cc41550e6d66d7b6c630a`; bundle `131acaeb…6ceb`; [build record](MEASUREMENTS.md#fpga-image--2026-11-21) |
| Boot ROM | `73df94eb…`; U-Boot banner `2026.10-dirty (Nov 21 2026 - 16:27:09 +0000)`; device tree `784e2762…` |
| Key | `flow/auth_record.py verify` accepts the bundle's key for this bitstream; fingerprint `276bf6e96d8edecc`; island ROM `6f33eae4…` |
| Kernel | `7.4.0-rc3-zvk-dirty`, NFS root, `random.trust_cpu=off` |
| Straps | lane 0, kshift 0 (k = 16), rings `0x0f`; `mentropycfg` read `0x30c0000b3c37000f` (the reset value) and `mentropystat` `0x1` at 09:18 |
| Conditions | lab room, die 23.7–24.8 °C over the captures, nominal supplies, Ethernet link up, one board |

Evidence: `_build/dbg/board-accept-20261123-20f8b265/` on the lab host,
with `SHA256SUMS`: fixtures, `rosc-short/`, `rosc-full-1/`,
`seed-restart-1/` and the analysis outputs beside the captures; per-phase
results and traces; `mentropystat.log`; `chosen-boot1.txt` and
`chosen-*.txt` (sizes only); `noise-run1/` (stage D); `auth-history.json`
and the stage E case outputs; the post-Linux
evidence (`debug-accept/`, `openssl-matrix-result.json`); the helper
scripts used (`campaign-tools/`). The console is in `_build/boot.log`. The
NIST inputs and outputs are in
`_build/nist-90b/data/{m23,s23,g23-k16,w23}-lane0.bin` and
`_build/nist-90b/results/`.

## Session

| Time | Step |
| --- | --- |
| 09:10 | Programmed by JTAG (Vivado batch, 45 s); fu-boot 09:11:16, U-Boot 09:11:19, login 09:15:51 |
| 09:17–09:18 | `linux_zkr.py` 3 of 3; `/chosen` lists an 8-byte `kaslr-seed` |
| 09:18:48 | OpenOCD `server.cfg`, reset-halt, fixtures loaded; the registers read as above |
| 09:19–09:33 | 7.3: `rosc_count.py` at a tenth of the default counts (`rosc-short/`), 43 steps |
| 09:34–11:16 | 7.4: `rosc_count.py` at the default counts (`rosc-full-1/`), 42 steps |
| 11:16–11:18 | 7.7 step 2: `seed_restart.py`, 1,000 × 1,000 (`seed-restart-1/`) |
| 11:26:16 | OpenOCD `linux-server.cfg`, `clean_detach_boot.py` passes (DPC `0x10000`); login 11:30:50 |
| 13:34 | `mentropystat` (long run); the console handed from `serial_cap.py` to `campaign-tools/console_drive.py` with Linux idle at its prompt, held by that one process for the rest of the session |
| 13:35–14:07 | Stage B: software reboot to the U-Boot prompt; `linux_zkr.py`, `/chosen`; `linux_reboot.py` |
| 14:07–14:18 | Stage C: phases 1–10 from `server.cfg` |
| 14:18–14:36 | Stage D: k-sweep, bursts, delayed warm restarts |
| 14:36–14:52 | Stage G: `entropy_fault.py` |
| 14:52–15:34 | Stage F: `clean_detach_boot.py`, login 14:57:07; phases 12, 13, 14 |
| Nov 24, 08:51 | `mentropystat` (long run) |
| Nov 24, 09:09–09:16 | SW12 on, off, on, on: power-on by JTAG reconfiguration; `entropy-off` |
| Nov 24, 09:31–09:50 | SW12 on, off, on, off: `locked` and `authenticate` on one power-on, the boot check, `reboot`; then `wrong-response`, `replay`, `expiry`, one power-on each |
| Nov 24, 10:00 | SW12 all off: power-on by JTAG reconfiguration; login 10:04:45; `linux_zkr.py` 3 of 3, an 8-byte `kaslr-seed`; `mentropystat` `0x1` |

The steps from 13:34 on ran from `campaign-tools/run_stage_bcdgf.sh`,
which stops when OpenOCD does not examine the target, the fixture load
fails, or Linux does not come back. During the meter captures the source
is in test mode, so the health tests do not run, and the hart runs the
capture payload's polling loop. Every stage E power-on was a JTAG
reconfiguration of the same bitstream (the case records' "CPU reset
button" is the harness's fixed text); each case ran from a fresh
`auth-server.cfg` (`campaign-tools/auth_case.sh`). SW12 was changed three
times: to on, off, on, on, to on, off, on, off, and back to all off. The
board was left running Linux with SW12 all off.

## Results

| Stage | What | Result |
| --- | --- | --- |
| B | U-Boot prompt after a software reboot (13:35): `version`, `rng list`, `rng 0 10` twice | PASS: `RNG #0 - riscv_zkr`; 16 bytes each time, the two different; no "No RNG device"; login 13:40:42 |
| B | `linux_zkr.py`; `/chosen` over SSH | PASS 3/3; an 8-byte `kaslr-seed` (`chosen-stageB.txt`, size only) |
| B | `linux_reboot.py`: three software reboots | PASS 3/3: 446–448 s each, a new boot ID, the fu-boot and OpenSBI banners each time; no "No RNG device" |
| C | Phases 1–5, 7–10 | PASS. Reset-halt DPC `0x10000`; soak 600 s, 8,982 batches, 319,547 words verified, 449 halt and resume cycles |
| C | Phase 6, translation | FAIL, expected: the same six walker results as on 2026-11-19 and 2026-11-20 (two misaligned leaves, four Svnapot mappings) |
| D | k-sweep, k = 1 to 32 | PASS: 10⁶ symbols each, one run, no loss |
| D | Bursts: 9 periods × 32 bursts of 32,768 | PASS: every capture complete |
| D | `getnoise_restart.py`: 1,000 delayed warm restarts at k = 16 | PASS: no retries |
| G | `entropy_fault.py`, five cases | PASS 5/5 ([below](#health-tests)) |
| F | Phase 11, `clean_detach_boot.py` | PASS: DPC `0x10000`; login 14:57:07 |
| F | Phase 12, `post_linux_host.py` | `POST_LINUX_ACCEPT_FAIL`: OpenSSL hit its 600 s limit; `board_accept.sh`, both KVM tests, the vector selftests and `xtest` passed |
| F | Phase 13, `complete_crypto.py` | PASS: 92 pairs, none missing or bad |
| F | Phase 14, `linux_kernel_bp.py` | PASS: a hardware breakpoint at `__riscv_sys_getpid` in the live kernel, and continuation |
| E | on off on on: `entropy-off` | PASS: REQUEST accepted, the window closed 1.78 s later without a challenge; stays locked; U-Boot printed "No RNG device" once and booted; Linux up, no `kaslr-seed` in `/chosen` (`chosen-entropy-off.txt`) |
| E | on off on off: `locked`, `authenticate` (one power-on) | PASS: examine refused; then a 20-word challenge with algorithm `0x04` and a nonce, SHA3 response, unlocked 0.19 s after the REQUEST; examine, halt, `mdbgauth` `0x1019b`, register round trip, resume |
| E | the same power-on: the boot check with authentication | PASS: no "No RNG device"; an 8-byte `kaslr-seed` (`chosen-authenticated.txt`); login 09:37:19 |
| E | the same power-on: `reboot` | PASS: after a software reboot the grant is kept, the window stays `CLOSED`, a REQUEST is refused, the debugger works |
| E | `wrong-response`, `replay`, `expiry` (one power-on each) | PASS: one bad signature bit and a replayed response are refused, locked; the window last seen open at 14.27 s and closed by 14.32 s. The four challenges of the day all differ |

**Stage D's analysis** (`noise-run1/getnoise-analysis.txt`,
characterisation, no verdict). As on November 19 and 20, the k = 1
capture and the burst capture at 256 clocks differ on lane 3 (one lag at
z 5.1). On every lane σ² grows faster than in proportion to the spacing
(log-log slopes 1.12 to 1.39), which is what the meter showed (7.4). Die
23.7–24.5 °C.

## Health tests

`mentropystat` was read with the hart halted for a moment and no reset
(`campaign-tools/entstat.py`) before most steps that reset the SoC. Not
read: the intervals that the second and third reboots of `linux_reboot.py`
ended, and those inside the debugger phases. Every reading:

| Time | Interval since the last reset | `mentropystat` |
| --- | --- | --- |
| 13:34:23 | detach 11:26:16 (2 h 08 min) | `0x1`: running, no alarm, no strikes, 0 failures |
| 13:43:38 | software reboot 13:36 | `0x1`, 0 failures |
| 14:07:37, 14:07:44 | the last software reboot, 14:01:37 | `0x1`, 0 failures |
| 14:18:16 | the debugger phases' last reset-halt, 14:08 | `0x1`, 0 failures |
| 14:36:40 | the last restart of `getnoise_restart.py` (its captures in test mode) | `0x1`, 0 failures |
| 15:33:56 | detach 14:52:31 (41 min) | `0x1`, 0 failures |
| Nov 24, 08:51:16 | the same (17 h 59 min) | `0x1`, 0 failures |
| Nov 24, 10:07:25 | the final power-on, 10:00 | `0x1`, 0 failures |

`mentropycfg` read `0x30c0000b3c37000f` each time: the reset value,
cutoffs 55 and 719. The readings cover about 20.5 hours of the source
outside test mode, an estimated 1.35 × 10⁹ kept samples by the sampling
rate (18,311 per second at k = 16), without a failure.

**Induced failures** (`entropy_fault.py`, 14:36–14:52), on the real ring
with stricter cutoffs:

| Case | Result |
| --- | --- |
| `startup` | PASS: a start-up failure is fatal at once and raises no alarm |
| `each` | PASS: the repetition test (cutoff 18) fired after 0.12 s and the proportion test (cutoff 550) after 2.7 s; `mentropystat` named each, lane 0, and for the repetition test the lag |
| `strikes` | PASS: the alarm stays until one `seed` access has seen it; the third running failure gives `DEAD` |
| `forgive` | PASS: 2²⁴ clean samples cleared a strike, in 917 s against 916 s expected |
| `limits` | PASS: weaker values are replaced by the build's limits; with interval 0 written, a word through `seed` took 65,536 clocks, the floor for k = 16; the lock freezes the CSR |

## The instrument (7.3)

Every capture and burst of both runs passed with no lost record and no
flagged count (85 steps). On both runs:

- **`--pair`:** the counts behind the divider and in direct mode are in
  the ratio two on every ring, with the operating rings (`0x0f`) and with
  all six (`0x3f`). On the full run the rate ratios are within 1 × 10⁻⁴
  of one (allowed 1.1–5.5 × 10⁻³).
- **`--bits`:** each ring's count rate agrees with the folded frequency of
  its sampled bits on the 4 mapped rings that run (the reference-bit
  bursts for `0x3f`, lane bursts for `0x0f` on the short run).
- Gaussian increments at 4,096 clocks (full run, all six rings): ok.

So a count is two ring periods on every ring, and the captures can be used.

## The captures (7.4)

`rosc_count.py` with its defaults: records every 256 × E clocks, counted
behind the divider, and a direct-mode capture of 100,000 records per mask
for `--pair`.

| File | Clocks apart | Rings | Records | Die °C (start–end) | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `rosc-count-p256-e1-m0f.bin` | 256 | `0x0f` | 1,000,000 | 24.35–23.68 | `8e55d113…` |
| `rosc-direct-p256-e4-m0f.bin` | 1,024 | `0x0f` | 100,000 | 24.29–23.99 | `87d5fa21…` |
| `rosc-count-p256-e4-m0f.bin` | 1,024 | `0x0f` | 1,000,000 | 23.98–24.29 | `1b424697…` |
| `rosc-count-p256-e16-m0f.bin` | 4,096 | `0x0f` | 1,000,000 | 24.09–24.83 | `34ff40a5…` |
| `rosc-count-p256-e64-m0f.bin` | 16,384 | `0x0f` | 400,000 | 24.51–24.44 | `5a738885…` |
| `rosc-count-p256-e1-m3f.bin` | 256 | `0x3f` | 1,000,000 | 24.80–24.67 | `bbbbb0a8…` |
| `rosc-direct-p256-e4-m3f.bin` | 1,024 | `0x3f` | 100,000 | 24.69–24.48 | `1d29d2f1…` |
| `rosc-count-p256-e4-m3f.bin` | 1,024 | `0x3f` | 1,000,000 | 24.43–24.66 | `4096f5b8…` |
| `rosc-count-p256-e16-m3f.bin` | 4,096 | `0x3f` | 1,000,000 | 24.17–24.56 | `5cc6259a…` |
| `rosc-count-p256-e64-m3f.bin` | 16,384 | `0x3f` | 400,000 | 24.39–24.37 | `3b2d45ef…` |

**Verdicts** (`rosc_own.py <file> --text`), as the credited own variance of
lane 0 in ring periods² and its multiple of the 0.104 that 0.75 bit needs.
Captures with all six rings are cross-checks only.

| Capture | At 4,096 clocks | At 16,384 clocks |
| --- | --- | --- |
| `0x0f`, every 256 | not established; 0.84 (8.1×) | not established; 3.36 (32×) |
| `0x0f`, every 1,024 | not established; 2.43 (23×) | not established; 9.71 (93×) |
| `0x0f`, every 4,096 | not established; 13.5 (130×) | not established; 53.9 (518×) |
| `0x0f`, every 16,384 | not established; 31.9 (309×) | not established; 128 (1,234×) |
| `0x3f`, every 256 | cross-check, not established; 0.42 (4.0×) | 1.67 (16×) |
| `0x3f`, every 1,024 | cross-check, not established; 2.03 (20×) | 8.12 (78×) |
| `0x3f`, every 4,096 | cross-check, not established; 14.0 (134×) | 55.8 (537×) |
| `0x3f`, every 16,384 | cross-check, not established; 39.6 (375×) | 158 (1,501×) |

The margin is met on paper everywhere; the verdicts fail on the
assumption checks, and the credited value grows with the records' spacing,
which a model of fresh white noise would not give. The reasons, on every
operating-mask capture:

- a spectral line in a pair's phase that could add 9.4–27.8 periods²,
  more than a tenth of the credited variance;
- the constant term of the own variance against the span is below the one
  of counting (−23 to −93 standard errors): part of the linear growth has
  a memory and is not all fresh at a short spacing;
- the own variance is not *c + a·span + b·span²* for the least-squares
  and the frequency methods;
- on some captures also: the methods disagree, the least-squares value is
  above the model-free upper bound, the clock and one shared factor do
  not fit the rings' covariances (p below 10⁻¹⁰), covariance is left after
  the model between pairs of rings, or (16,384 clocks) the rate drifts
  through the capture and 4,096 clocks is outside the fitted spans.

**The 4,779.7 Hz disturbance.** Against the 75 MHz clock, lane 0's phase
carries a line at 4,779.72 Hz with an amplitude of 19.4 ring periods,
about 45,000 times the background: a frequency modulation of about
0.04 %. It has the same frequency in captures with records 256, 1,024 and
4,096 clocks apart, so it is not an alias. The three 3-stage rings follow
it alike (shared loadings of the references about 1.00), so it nearly
cancels between them: 0.16–0.36 periods in pairs 0-4, 0-5 and 4-5. Lanes
1 to 3 follow it 93–96 %, which leaves 1.75–2.63 periods in pairs 0-1,
0-2 and 0-3 and 0.70 in 1-2. The hart runs only the capture payload's
polling loop during the captures, so the source is not software on the
core; supply ripple or a periodic load on the board are the candidates.
Its source has not been looked for. A line of that period (about 15,700
clocks) also explains a negative constant term when a straight line is
fitted to spans up to a few thousand clocks.

Not run: `entropy_claim.py --own` on the reference bits (7.5), and the
captures after a reconfiguration and after a `CPU_RESET` (7.4 step 4).

## Lane 0 at the shipped spacing

**Sequential data.** Lane 0 (`DATA1[60]`) of `rosc-count-p256-e16-m0f.bin`:
10⁶ consecutive bits 4,096 clocks apart, the spacing of `seed`, with the
operating rings, recorded by the meter in test mode (SHA-256 of the bits
`8fc17444…`). `ea_non_iid -a -v … 1` (NIST tools `87c104d`):

| Estimator | Bits per bit |
| --- | --- |
| Most common value | 0.963013 |
| Collision | 0.928380 |
| Markov | 0.966405 |
| **Compression** | **0.810451** |
| t-tuple | 0.934685 |
| LRS | 0.965639 |
| MultiMCW | 0.973931 |
| Lag | 0.994518 |
| MultiMMC | 0.963387 |
| LZ78Y | 0.963171 |

H_original = 0.810451; 48.83 % of the bits are 1.

**Operational restarts.** `seed_restart.py`: 1,000 debugger resets
(`ndmreset`, the hart held), after each the first 1,000 bits through
`seed` (63 words), outside test mode with the reset configuration. Every
restart on the first attempt, no health-test alarm; the payload resumed
5.3–15.1 ms after the reset's release (median 8.5), the first `ES16` came
44.2–54.1 ms after its entry (median 50.9), and its longest gap between
polls was 161 clocks. Rows `1e0676a0…`, checked bit for bit against the
words as `seed` delivered them. `ea_restart -n -v … 1 0.810451`: X_max 565
against a cutoff of 639, H_r 0.816320, H_c 0.851729; the restart test
passes, min(H_r, H_c, H_I) = 0.810451.

**The first word.** Over the 1,000 restarts the first `seed` word took 995
distinct values, none more than twice. Under independent restarts the
one-sided 99 % upper limit on the most likely word's probability is
0.008379, so that word has at least 6.89 bits of min-entropy
([assessment](../doc/sp800-90b-assessment.md#entropy-claim-for-the-first-word-after-reset)).

**Through GetNoise (7.7 step 1).** Lane 0 of the k = 16 capture of stage
D (`noise-run1/getnoise-k16.bin`, `5b0fe147…`): 10⁶ consecutive bits 4,096
clocks apart, read through `mnoise` in test mode, 48.77 % ones (bits
`ff4dd951…`). `ea_non_iid -a -v … 1`: H_original **0.838673**, the
compression estimate again the lowest (most common value 0.961253,
collision 0.883823, t-tuple 0.911890).

**Delayed warm restarts**, the cross-check: lane 0 of the 1,000 rows of
`getnoise_restart.py` (each row at least about 150 ms after its reset).
`ea_restart -n -v … 1 0.810451`: X_max 576 against a cutoff of 638, H_r
0.817418, H_c 0.862506; passes.

**At the assessment's 0.75.** The
[SP 800-90B assessment](../doc/sp800-90b-assessment.md) proposes 0.75
bit per bit as the developer's estimate. `ea_restart … 1 0.75` passes on
both row sets with the same X_max, H_r and H_c (cutoffs 662 and 663), and
min(H_r, H_c, H_I) is then 0.75. Replayed through the health tests' model and
the RTL at the reset cutoffs (`make entropy-test`), the four datasets
raise no failure: the largest repetition count is 23 of 55 and the
largest window count 576 of 719.

**The spacing from the first word (7.7 step 4).** `mentropycfg` read
`0x30c0000b3c37000f` after a reset-halt, before the hart ran an
instruction: interval 15, the floor for k = 16. In the 1,000 operational
restarts the first `ES16` came 58.9–59.9 ms after the reset was released
(median 59.41 ms; the payload's resume time plus its wait for the word),
against 59.4 ms from simulation.

## Not done on this image

- Stage A's own boot (lifecycle `OPEN`, the source off), and the cases
  `open`, `fresh-nonce`, `no-hold`, `reboot-locked` and `disabled`.
- `entropy_claim.py --own` on the reference bits (7.5), and the captures
  of 7.4 after a reconfiguration and after a `CPU_RESET`.
- `make uboot-boot-test` on the build host.
