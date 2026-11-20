# Zkr follow-up plan

Status: **plan, 2026-11-18.** When it was written nothing here was
implemented. It follows the
first board session of the Zkr image (bitstream `d7ff00dc…`), whose
GetNoise captures are summarised in
[the acceptance record](../dbg/BOARD_ACCEPTANCE-2026-11-18.md#noise-capture)
and kept in `_build/dbg/board-accept-20261118-rom2m-auth/` on the lab host.

*Status, 2026-11-18, later the same day.* Z1 and Z2 are implemented in RTL,
Z3 in the board scripts and the analysis, Z4's temperature and supply
readout in RTL, and Z5 in the U-Boot build. All of it is tested in
simulation and is in VCU118 bitstream `85f07e58…`, built at 23:40 UTC with
timing met. **It ran on the board on 2026-11-19**
([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md)): the burst capture fits
the noise model for the first time, and shows a dependence between lanes 2
and 3. Section 7 of
[the board test plan](../dbg/BOARD_TEST_PLAN.md) has the steps. The notes
under each item say what was built, what was decided where the plan left a
choice, and what is not done.

## 1. Why

The first captures (k = 1 to 32, 10^6 symbols each, no losses) show four
lanes with a fixed per-ring bias (lane 0 at 0.485 ones) and almost no serial
or cross-lane dependence. That is also their limitation: at one raw sample
per `SAMPLE_DIV = 256` clocks (3.4 µs at 75 MHz) the ring phase is already
decorrelated, so the per-lane fit of arXiv:2102.02196 sees no frequency F
and gives only a lower bound on the jitter variance (sigma^2 ≥ 0.13; only
lanes 2 and 3 at k = 1 show any autocorrelation). To fit (F, D, sigma^2),
the rings have to be sampled closer together, down to one sample per clock,
in consecutive runs long enough for the autocorrelation at many lags.
Software cannot do that through `mnoise`: the capture loop polls about every
34 clocks and stores each symbol to DDR, so it would start losing symbols
somewhere between 64 and 128 clocks per sample.

## 2. Work items

### Z1. Runtime sampling divider

- Replace the build-time `SAMPLE_DIV` of `flow/fpga/karu_rosc_rng.v` with a
  period P of 1 to 256 clocks, set at run time.
- Its reset value stays 256, so `seed`, the health tests and the
  authentication ROM behave as today unless software changes it.
- Decide where the field lives: a new field of `mentropycfg` (for example
  `[47:40]`), WARL against what the noise source supports, or a register of
  the characterisation block of Z2. OpenTitan's raw noise-source interface
  has no rate control, so either way the period is a sideband an ASIC
  source may ignore, and the field then reads back the fixed rate.
- A change of P restarts the start-up test, as a change of k does.

*Status, 2026-11-18: implemented, simulated.*
- **Where the field lives: in the capture block of Z2, not in
  `mentropycfg`, and it works only in test mode.** The period register is
  one of the capture block's registers. Outside the entropy block's test
  mode (`mnoise` `noise_test` clear), and whenever `mentropycfg` is locked,
  the noise source runs at the build's period (`SAMPLE_DIV`, 256) and the
  register cannot be written. So `seed`, the health tests and the
  authentication ROM see the source exactly as in the accepted image, by
  construction and not by a reset value; the CSR contract is unchanged;
  and an ASIC entropy block is not touched: `rtl/karu_entropy.v` gained
  only two status outputs (test mode, lock).
- The cost of that choice: a period other than the build's cannot be used
  for `seed`. That is deliberate while the source is uncharacterised (§4).
  If the characterisation calls for another production period, it becomes
  the build parameter, or the field moves into `mentropycfg` then.
- The noise source (`flow/fpga/karu_rosc_rng.v`) takes the period as an
  input, `rng_div_i`, in place of the parameter. The rings are not affected
  by it; it selects which values of the sampling flip-flops become symbols.
  At a period of one clock the valid signal stays high.
- A change of the period needs no restart: it can only happen in test mode,
  where no health test runs and `seed` is in `BIST`. Leaving test mode puts
  the build's period back in the same cycle and restarts the start-up test,
  as before. In test mode the period applies to `mnoise` as well, so
  `getnoise_capture.py` can be pointed at a period below 256 too.
- Tests: `make noise-burst-test` (periods 1, 2, 3, 5, 8 and 256 against a
  record of every symbol of the source; the first symbol after test mode
  comes a full build period after the one before it; 33 mutants).

### Z2. Burst capture for characterisation

- An FPGA-only block that records N consecutive raw 4-bit samples at period
  P into block RAM, then holds them for readout. For example, N = 32K
  samples is four 36 Kb BRAM tiles. The image uses about 318 of 2160.
- Read out through the debugger (SBA) or the hart, at leisure. A memory-mapped
  window on the FPGA crossbar needs no change to the core or to the CSR
  contract.
- Capture only while the source is in test mode (`mnoise` `noise_test` set),
  so `seed` is in `BIST` and no captured sample is ever also delivered as
  entropy. Refuse it while `mentropycfg` is locked. There is no PMP and
  OpenSBI leaves the MMIO range open to S-mode, so the test-mode gate is
  what keeps the window from exposing delivered entropy.
- Optional: sample on the 300 MHz `ui_clk` instead of the 75 MHz CPU clock,
  for four times finer time resolution, with the buffer in that domain.
- Not part of the ASIC entropy block; `rtl/karu_entropy.v` stays as it is.

*Status, 2026-11-18: implemented, simulated; block RAM and loops checked in
an out-of-context synthesis, then in bitstream `85f07e58…`, where the
routed paths into the four RAMs have at least +2.88 ns setup and +0.053 ns
hold. On the board on 2026-11-19: eight runs of 9 periods × 32 bursts,
all complete.*
- `flow/fpga/karu_noise_burst.v`, instantiated next to the noise source in
  `flow/fpga/karu_entropy_src.v`. A burst is 32,768 consecutive raw symbols
  (2,048 words of 16), in four 36 Kb block RAMs. Out of context, Vivado
  2026.1 infers the four RAMB36E2 and adds 104 LUTs and 96 flip-flops for
  the block; the loop check finds only the four rings.
- **The registers are in the system-control block, at `0x1000_0840`, not in
  a window of their own.** The plan assumed that a new memory-mapped window
  needs no change to the core. It does: the core's physical access
  permissions (`rtl/karu_pma.vh`) list the device ranges, and an address
  outside them faults. The system-control block is in the UART's page,
  which the core already allows, so the four registers (status and control,
  period, index, data) went there, and the recording is read through the
  index and data registers instead of being mapped. The bus decode
  (`flow/fpga/karu_ddr_xbar.v`) passes on privileged 64-bit accesses only.
- Test mode confines everything, as planned, and a little more: the period
  register, the status and the index return to their reset values when
  test mode ends or the configuration is locked, and the data register
  reads zero unless a capture completed in the current test-mode session.
  The RAM is not wiped; its contents are unreachable, because a new capture
  overwrites every word before it reports done.
- Not done: sampling on the 300 MHz `ui_clk`. One sample per 75 MHz clock is
  what this block gives.
- Tests: `make noise-burst-test` (the block with the noise model and the
  entropy block), `make ddr-noise-burst-test` (the registers through the
  SoC's bus decode from M-mode and, refused, from U-mode and with narrower
  accesses; eight decode mutants), `make zkr-loop-test` (unchanged, still
  no loop). All are in `make dbg-test`.

### Z3. Analysis and procedure

- A board script (`getnoise_burst.py`) that runs many bursts per period, for
  P = 1, 2, 4, …, 256, and writes the same `.bin`/`.json` pairs as the
  current capture, with P and the burst boundaries recorded. Runs are never
  joined across bursts.
- Extend `getnoise_analyze.py`: fit (F, D, sigma^2) per lane at each P,
  check that sigma^2 grows in proportion to P, and check that the P = 256
  results agree with the k-sweep captures of 2026-11-18. Add a spectrum
  per lane and per pair, to show beat frequencies and any locking between
  rings that the lag statistics would miss.
- Validate the extended analysis first on the simulation model
  (`karu_rosc_rng` with `SIM = 1`), whose F and sigma^2 are known: the fit
  must recover them. Mutants as for the current tests.

*Status, 2026-11-18: implemented, validated on generated data and on the
simulated source.* *2026-11-19: eight board runs analysed with it
([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2)).*
- `test/dbg/board/getnoise_burst.S` and `getnoise_burst.py`: 32 bursts by
  default at each of the periods 1, 2, 4, …, 256, written in the capture
  format with one run per burst; the sidecar has the period and a
  clock-cycle stamp at the start and end of every burst. The payload is
  one more hart program like `getnoise.S`: it enters test mode, sets the
  period, and copies each burst out of the capture block.
- `getnoise_analyze.py` reads both kinds of capture and compares them by
  the spacing of their samples in clocks (period times k). New for small
  sigma^2: a fit per burst at lags up to an eighth of the burst; the same
  fit pooled over bursts, and the ratio of the two as a sign of frequency
  wander between bursts; the sigma^2 by lag range; a spectrum per lane
  with the lines the model explains and any spurs; the coherence of each
  lane pair, for locking; the correlation of the lanes' per-burst
  frequencies, for shared wander; and agreement between captures of equal
  spacing. The sigma^2 that feeds the per-bit model figure is never the
  pooled one when the per-burst fits exist, and its lower end is the
  smallest of all the fits' lower ends.
- Validation. On the Python copy of the simulated source in its
  known-parameter mode, decimated to periods of 1 to 256, sigma^2 comes
  out within 3% where more than half the bursts can be fitted, and
  proportional to the period (log-log slope 0.99 to 1.01). On generated
  model data with 16 bursts of 32,768 symbols the value used is within
  about 5% of the truth at sigma^2 = 1e-2 per sample and 25% at 1e-5.
  `make dbg-getnoise-burst-test` ties the Verilog model to the Python copy
  through the real payload and bus decode, and
  `make dbg-burst-analysis-test` has the rest, with negative controls.
- Limits that matter for the board data
  ([harness README](../test/dbg/board/README.md#noise-capture-getnoise)
  has the list): a lane whose correlation outlasts an eighth of a burst
  gets F and sigma^2 but no per-bit figure; wander inside a burst raises
  sigma^2 and is only partly kept out; coherence and shared wander need
  the 32 bursts. On the board (2026-11-19) the model fits each lane, but
  the fitted jitter variance grows faster than in proportion to the
  spacing, so the real rings' jitter is not purely the model's white
  noise.

### Z4. Repeat captures

Still open from the board test plan (stage D), and worth doing with Z2:

- after several cold starts (reconfiguration) and several CPU resets;
- under different activity, at least Ethernet link up and down;
- with the FPGA temperature recorded (SYSMON) next to each capture.

*Status, 2026-11-18: readout implemented and simulated; the captures are
a procedure for the board session.* *2026-11-19: captured on the board
after three reconfigurations, two CPU resets, one software reset, with the
link up and down, and with the die temperature and supplies read before
and after every capture
([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2)).
The temperature stayed between 23.9 and 24.9 °C, so the behaviour over a
wider temperature range is still open.*
- `flow/fpga/karu_sysmon.v` reads the FPGA's die temperature, VCCINT and
  VCCAUX from the system monitor (SYSMONE4, in its default mode) every
  14 ms and shows them, with an update count, in one 64-bit register at
  `0x1000_0860`, readable by privileged 64-bit loads in any image built
  from this tree, in or out of test mode. The monitor is placed in the SLR
  of the ring oscillators (`flow/fpga/sysmon_constraints.tcl`); the Vivado
  hardware manager can still read it over JTAG.
- Both capture scripts read the register just before and just after each
  capture and store it in the sidecar, raw and decoded. They also keep a
  free-text note (`KARU_BOARD_GETNOISE_NOTE`, `KARU_BOARD_BURST_NOTE`) for
  the reset history and the link state, and the burst sidecar has a
  clock-cycle stamp per burst, so drift within a capture can be seen.
- Tests: `make sysmon-xsim-test` runs the readout against Xilinx's own
  SYSMONE4 model in Vivado's simulator, with a stimulus file that steps
  from 41.5 to 55.0 deg C; the readout decodes to the stimulus within
  0.6 deg C and 3 mV, and a control with two registers swapped fails.
  `make ddr-noise-burst-test` reads the register through the SoC from a
  model with fixed codes, and from U-mode, where it reads zero. An
  out-of-context Vivado run placed the monitor in the rings' SLR.
- Limits: the formula is the one for the on-chip reference (about 0.3 deg C
  from the external-reference one near 40 deg C); the register reads zero
  for the first update period after reset and in images built before it.
  The board test plan has the steps.

### Z5. U-Boot

- Move U-Boot on from v2025.01 (`flow/build_uboot.sh`, `UBOOT_REF`). The
  2 MiB ROM was grown for this: U-Boot's slot is ROM offsets
  `0x120000`–`0x1fbfff` (880 KiB), of which v2025.01 uses 579 KiB, leaving
  about 301 KiB. The 1 MiB ROM left about 46 KiB.
- Revisit the Zkr random-number driver (`RNG_RISCV_ZKR`), which is off
  because it waits without bound in `BIST` or `WAIT`. With a driver that
  times out, U-Boot could supply `kaslr-seed` and stop printing "No RNG
  device" before booting Linux; a driver that cannot time out stays off.
- Rebuild the ROM, check its manifest, and rerun stage A of the board test
  plan.

*Status, 2026-11-18: build and simulation done; in the ROM of bitstream
`85f07e58…` (802,453 bytes with the lab's baked boot command,
`0e560318…`). On the board on 2026-11-19: with the source on, `rng 0 10`
prints 16 bytes and U-Boot supplies a `kaslr-seed`; with it off, `rng`
answers "No RNG device" at once and the boot goes on.* `flow/build_uboot.sh` now builds v2026.10
(801,805 bytes with the configuration below and no boot command, of the
slot's 901,120) and refuses a tree that holds another release, instead of
building it under the new name.
- The Zkr driver of v2026.10 still waits without bound in `BIST` and
  `WAIT`, in its probe and in every read. It is enabled with a local patch,
  `flow/boot/uboot-zkr-timeout.patch`, that bounds each wait at 100 ms and
  returns an error; the script checks the driver's hash before and after.
  Without a word U-Boot prints "No RNG device" and boots on, as today.
- What the driver is used for: the `kaslr-seed` property that U-Boot adds
  to the device tree. Linux does not count it as entropy. `rng-seed`, which
  Linux would count, is not passed (`BOARD_RNG_SEED` stays off), so §4
  holds. The `rng` command is enabled, to try the driver from the prompt.
- `make uboot-boot-test` boots this U-Boot from the ROM in simulation, with
  the entropy source on and off, through one SBI reset each.

### Z6. SP 800-90B: joint-source assessment and health-test coverage

*Added 2026-11-19.* The [SP 800-90B assessment](sp800-90b-assessment.md)
finds the source not compliant. The noise-source sample is the 4-bit vector of
the four rings, not four separate bits; its non-IID statistical estimate is
3.53 bits per sample at the shipped spacing, and a delayed warm-restart
experiment passes the restart tool, but the health tests run per lane only,
fail the alternative-test criteria of §4.5, and rest on an assumed entropy;
the operational restart requirement is untested. The work, in order:

- RCT and APT (W = 512) on the 4-bit sample, with cutoffs from the assessed
  entropy and a documented false-alarm rate; keep the lane tests as
  diagnostics; add a test for short periodic patterns.
- A failure indication a consumer can read, distinct from start-up, and a
  rule that ends a recurring operational failure in `DEAD`.
- A fixed configuration: build-time constants or a boot-time lock for k and
  the cutoffs.
- Operational restart data: power-on or reconfiguration restarts, samples
  read through `seed` from the first `ES16` on.
- Data over temperature and supply, more boards or placements, and cold
  restarts; a physical rationale (the Z3 model with flicker and wander) for
  the entropy claim.

*Status, 2026-11-19: the first three items are implemented in RTL, tested
in simulation and built into bitstream `ddb168e1…` (2026-11-20, timing met;
[measurements](../dbg/MEASUREMENTS.md#fpga-image--2026-11-20)); on the
board on 2026-11-20 (below). (A first build that evening, `f3493b17…`, had a boot ROM from the
wrong compiler and was replaced before it was used.)*
- `rtl/karu_entropy.v` runs the two approved tests on the 4-bit sample and,
  per lane, a repetition count at lags 1 to 4 and the adaptive proportion
  test. A running failure latches the `BIST` alarm until a `seed` access
  has seen it; the third without 2^24 clean samples in between is fatal.
  A new read-only CSR, `mentropystat` (`0x7CA`), reports the state, the
  alarm, the strikes and what failed last.
- The cutoffs and the failure numbers stay writable through `mentropycfg`.
  The reset values are for a target of 3 bits per 4-bit sample (the rate
  the Zkr text asks) and a false-alarm probability of 2⁻⁴⁰ per test: 15
  and 124 on the sample, 55 and 719 per lane. They are the weakest
  configuration unless a build widens the limits: software can only make
  the tests stricter. Three bits is a target, not an established claim.
- `seed` is the entropy block's only consumer: the authentication block's
  own port and CSR (`mdbgrng`) are removed, and its ROM reads `seed`.
- GetNoise: the loss flag of `mnoise` is now also set when the source is
  switched off, when `mentropycfg` is written in test mode, and when the
  burst block's sampling period is written, so a run never spans a stopped
  source or a change of spacing.
- **Decided where the plan left a choice:** the fixed configuration is a
  one-sided limit, not a constant, so that software with an assessed claim
  can set its cutoffs; the spacing floor does not apply in test mode,
  where `seed` delivers nothing, so the GetNoise k-sweep still works.
- `make entropy-test` compares the RTL with a Python model of the health
  logic on generated faults and, with `ENTROPY_DATA=…` and
  `ENTROPY_RESTART=…`, on board captures: D18 and D19 raise no failure at
  the reset cutoffs and end running; the restart rows, replayed row by
  row, raise none either, but each row is shorter than a start-up test.
  [Section 9 of the assessment](sp800-90b-assessment.md#9-redesign-of-the-health-tests-rtl-2026-11-19)
  has the cutoffs, the rule for intermittent and persistent failures and
  the evidence.
- *2026-11-20, on the board* ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)):
  every interval read between resets (`mentropystat`), about 100 minutes
  in total, ended with zero failures on the real rings, and none in replay of that
  day's k = 16 and restart captures; the non-IID estimate at k = 16 was
  3.556 bits per sample. Two rings run at other frequencies relative to the
  clock than in `85f07e58…`: the characterisation is per bitstream. An
  hours-long reading is still open.
- Not done: the lock in the boot chain; the operational restart data; the
  data over the operating range; the physical rationale.

## 3. Order

Z1 and Z2 belong in one bitstream. Z3's simulation part can start before
it; Z4 can start on the current image. Z5 is independent of the others but
changes the boot ROM, so combine it with the next image build.

## 4. Out of scope

- An entropy claim: no figure for `seed` follows from these measurements
  without an independent assessment, and Linux keeps
  `random.trust_cpu=off` until then.
- Changing the production defaults (k, the cutoffs, P) before the
  characterisation is done.
