# Zkr follow-up plan

**Goal.** Meet the RISC-V Zkr requirements at `seed`, including the
physical-source target of 192 bits of min-entropy per 256 bits delivered.
Software can then use a vetted conditioner to produce 128 full-entropy
bits from those 256 bits. The planned SP 800-90B self-assessment covers
the physical noise source, sampling and health tests in hardware, and the
conditioner in software. Keep the single output ring (lane 0) at the shipped spacing
(`k = 16`). Hardware AES is deferred. [Sign-off criteria](#zkr-and-software-sign-off)

Z1–Z6 cover four-ring image `ddb168e1…` and its
[November 20 board results](../dbg/BOARD_ACCEPTANCE-2026-11-20.md). Z7 uses
lane 0 alone for `seed`. Image `20f8b265…` passed meter qualification and
was [accepted on the board with documented exceptions](../dbg/BOARD_ACCEPTANCE-2026-11-23.md).
Its test-mode capture gave a non-IID estimate
of 0.810451 bits per sampled bit at the shipped spacing, and both restart
tests pass at 0.75. The [assessment](sp800-90b-assessment.md) proposes
the rate of 0.75 at `seed` as the developer's estimate, for one board in
lab conditions. Open: the justification of the fresh-jitter contribution
at that rate, the software conditioner, and data over a wider operating
range.

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

*Status: done; in the VCU118 image.*
- **Where the field lives: in the capture block of Z2, not in
  `mentropycfg`, and it works only in test mode.** The period register is
  one of the capture block's registers. Outside the entropy block's test
  mode (`mnoise` `noise_test` clear), and whenever `mentropycfg` is locked,
  the noise source runs at the build's period (`SAMPLE_DIV`, 256) and the
  register cannot be written. So `seed`, the health tests and the
  authentication ROM always see the source at the build's period, by
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
  comes a full build period after the one before it; one-mechanism
  mutants).

### Z2. Burst capture for characterisation

- An FPGA-only block that records N consecutive raw 4-bit samples at period
  P into block RAM, then holds them for readout. For example, N = 32K
  samples is four 36 Kb BRAM tiles, of the device's 2160.
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

*Status: done; in the VCU118 image. Every board burst capture so far is
complete ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md#noise-capture-and-entropy-estimates)).*
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

*Status: done; validated on generated data and on the simulated source,
and used for every board burst capture
([2026-11-19](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2),
[2026-11-20](../dbg/BOARD_ACCEPTANCE-2026-11-20.md#noise-capture-and-entropy-estimates)).*
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
  the 32 bursts. On the board the model fits each lane, but the fitted
  jitter variance grows faster than in proportion to the spacing (no lane
  meets the analysis's 25 % criterion), so the real rings' jitter is not
  purely the model's white noise. The ring frequencies relative to the
  clock depend on the bitstream's routing, so the characterisation belongs
  to a bitstream.

### Z4. Repeat captures

Captures beyond a single session, worth doing with Z2:

- after several cold starts (reconfiguration) and several CPU resets;
- under different activity, at least Ethernet link up and down;
- with the FPGA temperature recorded (SYSMON) next to each capture.

*Status: done at room temperature; a wider temperature range is open.*
Captures were taken after reconfigurations, CPU resets and a software
reset, with the link up and down, and with the die temperature and
supplies read before and after every capture
([record](../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2)).
The die stayed between 23.9 and 25.2 °C in every session.
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

*Status: done; in the ROM of the VCU118 image. On the board, with the
source on, `rng 0 10` prints 16 bytes and U-Boot supplies a `kaslr-seed`;
with it off, `rng` answers "No RNG device" at once and the boot goes on.*
`flow/build_uboot.sh` builds v2026.10
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

The [SP 800-90B assessment](sp800-90b-assessment-2026-11-20.md) treats the 4-bit
vector of the four rings as the noise-source sample. It makes no claim yet:
the jitter measured against the sampling clock is mostly shared between
the rings, so each ring's own jitter, which a claim may credit, is not
known. The work, with its state:

- **Done:** SP 800-90B's repetition count and adaptive proportion test
  (W = 512) on the 4-bit sample, with cutoffs for a documented target and
  false-alarm rate, and lane tests beside them, including a repetition
  count at lags 1 to 4 for short periodic patterns.
- **Done:** a failure indication a consumer can read, distinct from
  start-up, and a rule that ends a recurring operational failure in `DEAD`.
- **Done in hardware:** a configuration that software can only make
  stricter. The lock in the boot chain is open.
- **Done:** operational restart data, 1,000 restarts with samples read
  through `seed` from the first output, which pass NIST's restart test.
  Not at that count by power-on.
- **Done:** the argument's bound (`test/dbg/board/entropy_claim.py`):
  given each ring's own jitter, the min-entropy of a sample with the
  predictor given everything the rings share. **Measured with it:** the
  rings' phase increments are 90 to 100 % correlated at the spans the
  bursts resolve, so that input is not known.
- **Open, taken up by Z7:** a bitstream with counters that time the rings
  against each other, to measure a ring's own jitter; the spacing (k)
  chosen from it, and the configuration locked by the boot firmware; then
  the claim. Data over
  temperature and supply, more boards or placements, and power-on
  restarts, to widen it.

*Status: the first four are done, on the VCU118 image `ddb168e1…`
([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)); the measurement that
stops a claim is in
[section 1 of the assessment](sp800-90b-assessment-2026-11-20.md#1-entropy-claim-none).*
- `rtl/karu_entropy.v` runs the two approved tests on the 4-bit sample and,
  per lane, a repetition count at lags 1 to 4 and the adaptive proportion
  test. A running failure latches the `BIST` alarm until a `seed` access
  has seen it; the third without 2^24 clean samples in between is fatal.
  A read-only CSR, `mentropystat` (`0x7CA`), reports the state, the
  alarm, the strikes and what failed last.
- The cutoffs and the failure numbers are writable through `mentropycfg`.
  The reset values are for 3 bits per 4-bit sample (the rate the Zkr text
  asks; the design target, never a claim) and a false-alarm probability of
  2⁻⁴⁰ per test: 15
  and 124 on the sample, 55 and 719 per lane. They are the weakest
  configuration unless a build widens the limits: software can only make
  the tests stricter.
- `seed` is the entropy block's only consumer: the authentication ROM reads
  `seed`.
- GetNoise: the loss flag of `mnoise` is also set when the source is
  switched off, when `mentropycfg` is written in test mode, and when the
  burst block's sampling period is written, so a run never spans a stopped
  source or a change of spacing.
- **Decided where the plan left a choice:** the fixed configuration is a
  one-sided limit, not a constant, so that software with an assessed claim
  can set its cutoffs; the spacing floor does not apply in test mode,
  where `seed` delivers nothing, so the GetNoise k-sweep still works.
- Evidence: `make entropy-test` compares the RTL with a Python model of the
  health logic on generated faults and on the board captures, which raise
  no failure at the reset cutoffs. On the board, every interval read
  between resets ended with zero failures (about 2.4 hours), failures
  induced with stricter cutoffs show the alarm, the strikes, `DEAD`,
  forgiveness and the limits (`entropy_fault.py`), and the operational
  restart data passes `ea_restart` (`seed_restart.py`). The non-IID
  estimate at k = 16 is 3.556 bits per sample.
  [Section 5 of the assessment](sp800-90b-assessment-2026-11-20.md#5-health-tests-4)
  has the cutoffs, the rule for intermittent and persistent failures and
  the evidence.
- Not done: each ring's own jitter; the spacing and lock for a claim; the
  data over the operating range.

### Z7. One ring for `seed`, and the measurement of its own jitter

Decided on 2026-11-20, because Z6 could not reach a claim for four rings:
**`seed` delivers the bits of one ring, the 3-stage ring (lane 0); the
other rings stay as references for characterisation and carry no entropy
credit.** The next image is built so that the claim can be made on it, or
on a variant of it with the same placement and routing: everything the
measurement may still decide is a strap, not a rebuild.

**Why one ring.** With one ring the question is one number: given the
ring's previous phase, the sampling clock and every predictable clock or
supply variation, how well can the next sampled bit be guessed? If that
probability is at most 2^-0.75 = 0.5946 at every delivered step, 16
consecutive bits have at least 12 bits of min-entropy and 256 have the 192
that the Zkr text asks on its SP 800-90B route. The bound conditions on the
history, so dependence between successive bits is allowed. Under the model
of the [assessment](sp800-90b-assessment-2026-11-20.md#11-the-argument-and-the-step-that-fails)
that needs 0.103 ring periods² of fresh phase variance per sample (duty
cycle within 0.011 of one half): 1.4 % of the 3-stage ring's fitted
short-lag rate at 4,096 clocks, 0.35 % at 16,384. Four rings need about
5 % in each ring and independence between them. The short-lag estimates of
2026-11-19 put the 3-stage ring's own share at 6.8 × 10⁻⁵ to 1.6 × 10⁻⁴
ring periods² per clock, 2.7 to 6.4 times its need at 4,096 clocks, by a
model that also returns impossible negative values for another ring. That
supports the choice of ring and makes the measurement worth doing; it is
not a lower bound, and the spacing is chosen from the new image's
measurements, not from it.

**One-ring image `20f8b265…`.** The FPGA wrapper connects the following
components (`flow/fpga/karu_entropy_src.v`).

1. **Single-lane delivery** (`rtl/karu_entropy.v`). The noise-source sample
   is one bit, the selected lane of the 4-bit bus. A `seed` word is 16
   consecutive kept bits, the first in bit 15. The approved continuous
   tests are the repetition count and the adaptive proportion test
   (W = 1024) on that bit, with the repetition count also at lags 2 to 4;
   their reset cutoffs stay 55 and 719 (0.75 bit, 2⁻⁴⁰). The tests on the
   4-bit symbol and on the other lanes are removed, and their
   `mentropycfg` fields read zero. GetNoise and the burst capture keep all
   four lanes, in test mode only. The interface keeps OpenTitan's 4-bit
   bus; OpenTitan's `entropy_src` has the same single-channel mode
   (`CONF.RNG_BIT_ENABLE`, `RNG_BIT_SEL`). *Done in simulation
   (`make entropy-test`: 12,894 checks, 108 of 108 mutants, replay 45 of
   45).*
2. **Straps instead of rebuilds** (`flow/fpga/karu_softstrap.v`,
   `flow/fpga/strap_variant.tcl`). Three static inputs of the entropy
   source, each a look-up table constant that can be changed in the routed
   design without placing or routing anything again: the lane (0 to 3,
   default 0), the spacing floor (k at least 16, 32, 64 or 128; default
   16), and the rings that run outside test mode (default `0x0f`, lanes 0
   to 3). Software still can only lengthen the spacing. `mentropystat`
   shows the lane in [21:20] and the floor in [23:22].
   - `make vcu118-strap-variant` writes a variant from the image's routed
     checkpoint. It refuses a ring mask without the lane that `seed`
     delivers, before it writes anything. It also writes the checkpoint's
     own bitstream again. `flow/strap_diff.py` reads the files as header,
     configuration packets and frame data: that bitstream must have the
     image's payload byte for byte, so the checkpoint is the image's
     design; and the variant may differ from it only in whole strap tables
     (or half a table, where the tool has put a strap beside another
     function), the check bits of those frames, and the CRC words behind
     them. The check bits are recomputed in every frame that differs and
     must be right in both files. A record, `vcu118_ddr<tag>.strap.json`,
     names image, checkpoint, variant and log by their hashes.
   - Every recipe that builds an image hashes the boot ROM after packing
     and before Vivado, and writes the ROM record (`vcu118_ddr.rom.json`,
     `flow/rom_record.py`) after Vivado; the debug image writes its
     authentication record only after a check that the bitstream is new
     and its island ROM unchanged. `make vcu118-strap-bundle` makes the
     variant's bundle only with the variant's record, and takes the
     manifest and the device tree from the boot ROM image only after its
     hash matches the ROM record: a ROM packed again after the image is
     refused, whatever its time stamp. `ddb168e1…` was built before these
     records and is tied to its ROM by time stamp only.
   - Run from end to end, with the present tools and constraints, on a
     small real design of the entropy source: the image, the same payload
     from the checkpoint in a later session, two variants with their
     records (one that changes one strap, which the tool had put in half a
     look-up table, the check bits of its four frames recomputed and right;
     and one that changes three, each a whole table), a wrong variant
     refused and a mask without lane 0 refused before anything was
     written. The checks on generated files, with dry runs of all six image
     targets, full and synthesis-only, and stand-ins for the boot files
     from beside the repository, are `make strap-flow-test` (70 checks).
     *Done on a small design; not yet on a full image.*
3. **Reference rings.** Two more 3-stage rings, built like lane 0 and
   placed away from it, off outside test mode by default. With lanes 1 to
   3 that gives lane 0 five partners, two of them of its own kind, for
   which a shared supply or clock disturbance cancels best. A reference is
   loaded like lane 0: next stage, sampling flip-flop, counter. Its sampled
   bit never reaches the raw bus; the burst capture can record it.
   *Done in simulation and on a small design. The meter also captured the
   reference rings on the board.*
4. **A period counter on every ring** (`flow/fpga/karu_rosc_rng.v`,
   `karu_rosc_cnt`). The 3-stage rings run at 0.37 to 0.83 ns over the
   timing corners (16 to 36 periods per clock), and a slice flip-flop of
   this part may not be clocked faster than 0.550 ns, with pulses of at
   least 0.275 ns. So no flip-flop is clocked by a ring:
   - **A divider by two** sits between the ring and its counter: two
     look-up-table latches (`div_m`, `div_s`), the same elements as the
     ring, and a selector (`div_x`). The counter's clock has two ring
     periods, about 0.74 ns at the fastest, and each of its pulses about
     one. **A count is two ring periods.**
   - **The counter:** an 8-stage Johnson counter (one flip-flop changes per
     count, nothing between flip-flops but one inverter) and two 2-bit
     coarse counters clocked half a cycle apart for the counts above
     sixteen. The decode reads each coarse counter only well away from its
     own change, at least three counts after and four before, whichever of
     the two reaches the samplers first; a sample that is not a valid code
     is reported.
   - **Direct counting**, a diagnostic mode of test mode, puts the ring
     itself on the counter's clock; a count is then one ring period. That
     is outside the flip-flop's guaranteed range for the fastest rings, so
     the mode is a cross-check of the divider on the board and never
     carries a bound.
   - The counter always runs, so that a ring is loaded the same in test
     mode and outside it.
   - **Checked in the routed design by every image build**
     (`flow/fpga/rosc_constraints.tcl`, one `KARU_ROSC_COUNT` line per
     ring; the build stops otherwise). Each check is made in four uniform
     states, every delay from one column of the timing model (slow
     maximum, slow minimum, fast maximum, fast minimum); decided on
     2026-11-21, these four states are the build's gate. The checks: the
     six conditions under which the two latches divide by exactly two,
     each edge where it acts, each at most 80 % of its limit; the counter
     clock's period and shorter pulse, at least the declared clock (0.68,
     0.92, 1.36 and 1.72 ns for rings of 3, 5, 7 and 9 stages) and half of
     it, and at least 1.1 times what the flip-flop needs; Vivado's own
     pulse-width report at every counter clock pin, without negative slack
     (the flip-flop's limits are read from it); the paths between the
     Johnson flip-flops, without negative slack at the declared period;
     the sampled bits' routes, within half a counter period of each other;
     each coarse counter, at most 2.5 counter periods early or late at its
     sampler; and fewer than 56 ring periods per system clock in the fast
     corner. Twenty-four loops are allowed, the six rings and eighteen
     latch loops; a loop that the tool refuses stops the build after
     synthesis.
   - **Two engineering allowances.** The timing model gives every
     look-up-table arc the same rising and falling delay, so its ring has
     a duty of exactly one half. The check sums the ring's halves edge by
     edge round the loop and takes each as at least 0.48 of the period
     (`KARU_ROSC_DUTY_MIN`), and so each pulse of the divided clock as at
     least 0.96 of a ring period: twice what lane 0 showed on the board
     (duty 0.511), not a measured bound for every ring. The 80 % limit of
     the divider conditions leaves room for neighbouring cells to differ.
   - **The mixed figures are a diagnostic of this measurement image, not
     required.** With the minimum and maximum of one corner mixed against
     each divider condition, cell by cell, the conditions reach 127 % of
     their limit for the 3-stage rings and 171 % for the skew condition of
     the 7-stage ring (slow corner). The build prints them. The two latches share a slice, but their clock inputs are
     distinct route endpoints, and only the shared part of a route
     justifies cancelling its variation.
   - **In a small real design** with the present constraints: every
     divider condition at 68 % of its limit or less (the 3-stage rings;
     lanes 1 to 3 at 53, 49 and 28 %); the 3-stage rings' counter clock at
     least 0.752 ns with pulses of at least 0.361 ns, 1.37 and 1.31 times
     the flip-flop's limits, against 0.680 and 0.340 ns declared; the
     pulse-width report's smallest slack 0.065 ns; Johnson slack at least
     0.22 ns; timing met, a bitstream written, no loop refused.
   - **What the routed check cannot show:** that the divider divides by
     two on the device. It rests on a look-up table not glitching when one
     input changes, which Xilinx engineers have stated for its function
     generators but which is not in this part's data sheet. That, and the
     two allowances, are why both ratio checks on the board are mandatory
     (*Instrument health*, below).

   *Done in simulation (`make rosc-meter-test`, 113 of 113 mutants), out of
   context and on a small design. The board passed the divided/direct
   counting and sampled-frequency checks.*
5. **The meter** (`flow/fpga/karu_rosc_meter.v`, registers at
   `0x1000_0868`, test mode only): unwraps the six counters, and at every
   n-th raw sample records all six totals and the four lane bits of that
   clock edge. One capture gives every ring against the clock and every
   pair of rings against each other, at 4,096 and 16,384 clocks directly
   and at their multiples; the count of a ring divided by another's cancels
   the gate. It also sets which rings run in test mode and how the counters
   count, and it checks every ring on every clock: a count that cannot be
   read, or an increment that differs from the one before by more than two,
   is counted and flagged per ring, so that a count wrong by sixteen cannot
   pass silently. One period lost or gained by the divider is not seen
   there. The burst capture can record one ring's count, one value per
   clock, or the two reference rings' bits beside those of lanes 0 and 1.
   *Done in simulation (`make rosc-meter-test`, `make noise-burst-test`
   with 54 of 54 mutants, `make ddr-noise-burst-test`); exercised on the
   board on November 23.*
6. **Capture and analysis.** `test/dbg/board/rosc_count.S` and
   `rosc_count.py` take the records on the board: captures counted behind
   the divider (a million records per setting, 400,000 at settings of
   16,384 clocks or more), one capture in direct mode per ring mask
   (100,000 records), count bursts in an upper and a lower view, and
   bursts of the reference rings' bits. A capture's sidecar says whether
   it can carry a bound (`for_bound`, false in direct mode and for a
   capture planned with fewer than 300,000 records); flagged clocks are
   reported, never used. `rosc_own.py` computes each ring's own variance
   from the pairs (rings of one kind, all rings together, and models with
   one and two shared disturbances), splits its growth with the span into
   a constant (counter resolution), a linear part (white noise, the part a
   claim credits) and a quadratic part, and gives a one-sided 99 % lower
   bound on the linear part of lane 0, with a verdict per spacing: pass,
   fail, not established, or cross-check only. With `--pair` it compares
   the two counting modes ring by ring, and with `--bits` each ring's count
   rate with the frequency of its sampled bits; no check inside one
   capture can see a wrong count unit. Validated on generated rings with
   known own and shared noise, with counts of two ring periods as the
   meter gives them: the bound was at or below the truth in 17,364 of
   17,400 trials (99.8 %, no scenario under 99.0 %), and no trial passed in
   6,000 with the ring's own white noise at zero. A second instrument that
   does not use the counters: bursts of the reference rings' bits beside
   lane 0's, and `entropy_claim.py --own`, which takes the own variance of
   rings of one kind from the decay of the product of their bits. It
   reaches a few hundred clocks, not the spacing, and is a cross-check,
   not a second claim. *Done in simulation (`make dbg-rosc-count-test`,
   `dbg-rosc-own-test`, `dbg-entropy-claim-test`). The operating-mask
   board data gave no model-based bound.*

**Rules for the model-based lower bound.** These criteria were set before
the board captures. They apply to entropy credit under this model.

- **The ring mask of normal operation.** The bound is computed from
  captures taken with exactly the rings that run in normal operation.
  Captures with other rings on or off are cross-checks and cannot carry
  the claim: the same total variance can hide a different split between a
  ring's own noise and shared noise. The default image runs lanes 0 to 3,
  as every image so far, and keeps the two reference rings off; its bound
  comes from four-ring captures. If only six-ring captures give a bound,
  the image for the claim is the strap variant that runs all six, and its
  bound comes from six-ring captures. A mask that runs lane 0 alone cannot
  be characterised by this instrument and would need a physical argument of
  its own.
- **Margin.** A spacing is accepted when the one-sided 99 % lower bound on
  lane 0's credited variance at that spacing is at least **twice** the
  variance that 0.75 bit needs at the measured upper end of the duty-cycle
  bias (0.103 ring periods² at a bias of 0.011), in every accepted capture.
  At that bias the bound has to reach about 5.0 × 10⁻⁵ ring periods² per
  clock at k = 16, or 1.26 × 10⁻⁵ at k = 64. The factor is a choice made
  here; the assessment states it with the claim.
- **A passing fit is not yet a claim.** The analysis assumes stationary
  behaviour, at most two shared disturbances, Gaussian phase increments and
  independent own noise of the rings. A variance that grows in proportion
  to the elapsed time is what fresh jitter gives; it does not by itself
  show that the next bit cannot be predicted. The assessment has to justify
  each assumption for the final image, from the checks the analysis reports
  (stability over blocks and runs, the shape of the increments' distribution,
  the fit of the shared-disturbance models, what is left between rings) and
  from the physics of the rings. The statistics do not by themselves rule
  out a small dependence between the rings: with two of them sharing a
  tenth of their own noise, the four rings of normal operation and 300,000
  records, 199 of 200 trials gave no pass at 16,384 clocks and one passed,
  all 200 bounds below the truth. So the physical argument for the rings'
  independence is part of the sign-off. If the statistics pass and the
  physical explanation stays open, the outcome is the measured numbers
  with no claim.
- **Instrument health.** Only a capture counted behind the divider can
  carry a bound; one in direct mode is a cross-check. A run in which the
  meter flagged a counter sample, as unreadable or as inconsistent with
  the one before, is not used. No capture is used before the divider's
  ratio of two is established on the board by both checks, each on every
  running ring of the final image: the counts of the two counting modes
  in the ratio two (`rosc_own.py --pair`), and each ring's count rate
  against the frequency of its sampled bits (`--bits`). The second
  compares only the folded frequency, the fraction of a ring's periods
  per clock, which a count wrong by a whole number of periods per clock
  leaves unchanged; the first catches that. Each check covers every ring
  it maps and that runs, or fails.
- **Records.** A capture that carries a bound has at least 300,000 usable
  records: those in the blocks that enter the fit, after flagged runs are
  set aside. With fewer, the analysis's checks of its assumptions miss
  small violations: two rings sharing a tenth of their own noise are
  flagged in only 50 of 1,000 trials at 30,000 records, and with six rings
  at 300,000 records in all 200, as is every other small violation tried
  but one (the ring's noise growing by a fifth halfway: 170 of 200).
  `rosc_own.py` gives no pass below 300,000; `--min-records` is for its
  own tests only. A short capture is for bringing the instrument up.

**Board procedure for the jitter-model approach.** These tests document
what would support an entropy bound derived from the meter. The sequential
estimate and the operational restart result also stand as measurements
when the model cannot establish a bound.

1. *Screen lane 0 on the data already on the lab host* (no hardware;
   commands in the
   [board test plan, 7.2](../dbg/BOARD_TEST_PLAN.md#72-before-the-build-and-before-the-session)):
   `ea_non_iid` on lane 0 of D20 as a binary source, and `ea_restart` on
   lane 0 of S20 with its 1,000 rows of 1,000 kept; R20 as a separate
   cross-check. A failure disqualifies k = 16. A pass supports the
   candidate and no more: SP 800-90B takes the smaller of this estimate and
   the submitter's. Passed on 2026-11-23: lane 0 of D20 as a binary source
   is 0.864 bit per bit by `ea_non_iid` (the compression estimate is the
   lowest), and `ea_restart` at that value passes on lane 0 of S20 (X_max
   563 against a cutoff of 618; H_r 0.898, H_c 0.844) and of R20 (561;
   0.828, 0.812). So k = 16 stays the candidate.
2. *Measure the fresh jitter at the delivered spacing* on the new image,
   once its instrument is qualified on the board (*Instrument health*):
   the lower bound on lane 0's fresh variance at 4,096 and at 16,384
   clocks, by the rules above, with the counter resolution and the
   partners' unequal supply sensitivity accounted for and several pairings
   agreeing. One noisy difference gives no lower bound.
3. *The smallest spacing that clears the bound with the margin and still
   boots:* k = 16 first, k = 64 as the fallback (first `seed` word about
   59 ms or 238 ms after a cold start). At the chosen spacing, on the image
   with that spacing as its floor:
   - fresh sequential data (10⁶ kept bits through GetNoise) and
     operational restart data (1,000 restarts of 1,000 bits through
     `seed`), assessed as a binary source;
   - a cold boot with no authentication request, a cold boot with
     authentication, and a boot with the source switched off, each recorded
     with whether U-Boot had its random-number device and passed a
     `kaslr-seed`, not only with whether Linux reached a login. U-Boot's
     driver gives up on a wait after 100 ms; a probe earlier than the first
     word would fall back silently and Linux would still boot. The
     authentication ROM's per-word polling limit covers every floor.

#### Zkr and software sign-off

1. **At the CSR.** Verify access rules, destructive reads, `BIST`, `WAIT`,
   `ES16` and `DEAD`, including startup, health alarms and failure handling.
   For the chosen RISC-V physical-source route, justify at least **192 bits
   of min-entropy per 256 bits delivered by `seed`** (sixteen successful
   `ES16` reads), at the assessed spacing starting with the first word.
   This requirement applies before software conditioning. [RISC-V Scalar
   Crypto §§31.5.1–31.5.2.1](https://docs.riscv.org/reference/isa/v20240411/unpriv/scalar-crypto.html)
2. **Evidence for the rate.** State the developer's estimate
   (`H_submitter`) and explain why the sampled ring supplies that much
   fresh entropy given earlier outputs and predictable clock or supply
   variation. Support it with sequential and operational restart data
   from the same configuration across the claimed operating conditions.
   A technically justified argument grounded in the device measurements
   and relevant research can support the estimate. The meter model above
   is one possible argument. [SP 800-90B §§3.1 and 3.2.2](https://doi.org/10.6028/NIST.SP.800-90B)
   · [RISC-V evaluation guidance, §31.8.1](https://docs.riscv.org/reference/isa/v20240411/unpriv/scalar-crypto.html)
3. **At the software output.** Select a vetted conditioner, specify how
   many successful `ES16` words feed each invocation, and calculate the
   entropy credit for its output length from the justified input rate.
   Verify the implementation against known answers and test how the
   module handles hardware health and failure indications. Collecting
   more input can support the module's output claim at a lower input
   rate. The 192-per-256 requirement at the CSR still applies.
   [SP 800-90B §3.1.5](https://doi.org/10.6028/NIST.SP.800-90B)

Record the bitstream, lane, spacing, ring mask, operating range, software
version and conditioner configuration in the combined assessment. The
FPGA evidence applies to that implementation. An ASIC needs its own
physical measurements.

**Current evidence**, on `20f8b265…`
([assessment](sp800-90b-assessment.md)):

1. *At the CSR:* shown. The access rules, the states and the destructive
   read pass in simulation (`make zkr-test`, `make entropy-test`); on the
   board the health tests, the alarm, `DEAD` and the limits behave as
   designed, and the first word comes at the assessed spacing, 59.4 ms
   after a reset.
2. *Evidence for the rate:* proposed, with one step open. The proposed
   developer's estimate is 0.75 bit per bit. The non-IID estimates
   (0.810451 from the meter, 0.838673 through GetNoise) and both restart
   tests at 0.75 support it. The meter fits a linear term of lane 0's
   own jitter that is 8 times the need at its lower end, but its model
   failed its assumption checks (a periodic line, a constant term 25
   standard errors off), so how much of that term is fresh is not
   shown. Open: a reason to credit the needed eighth as unpredictable.
   The data is from one board at 23.7–24.8 °C and nominal supply; that
   is the range the proposal has.
3. *At the software output:* open. No conditioning module exists; the
   assessment lists what it has to do.

## 3. Out of scope

- Separate SP 800-90B certification of the Zkr hardware and formal
  laboratory validation. The deliverable is a developer
  [self-assessment](sp800-90b-assessment.md) of the software module with
  its specified Karu source. Linux keeps `random.trust_cpu=off`.
