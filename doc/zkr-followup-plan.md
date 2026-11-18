# Zkr follow-up plan

Status: **plan, 2026-11-18.** Nothing here is implemented. It follows the
first board session of the Zkr image (bitstream `d7ff00dc…`), whose
GetNoise captures are summarised in
[the acceptance record](../dbg/BOARD_ACCEPTANCE-2026-11-18.md#noise-capture)
and kept in `_build/dbg/board-accept-20261118-rom2m-auth/` on the lab host.

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

### Z4. Repeat captures

Still open from the board test plan (stage D), and worth doing with Z2:

- after several cold starts (reconfiguration) and several CPU resets;
- under different activity, at least Ethernet link up and down;
- with the FPGA temperature recorded (SYSMON) next to each capture.

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
