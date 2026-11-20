# VCU118 acceptance — 2026-11-20: health tests on the sample, no `mdbgrng`, window limit

The first board session of image `ddb168e1…`, following
[section 8 of the board test plan](BOARD_TEST_PLAN.md#8-the-2026-11-20-image-health-tests-on-the-sample-no-mdbgrng-a-hardware-window-limit)
on the lab host, with SW12 changed as rarely as possible. **Accepted, with
documented exceptions**, as on 2026-11-19:

- translation fails with the six known pristine-OpenOCD walker results,
  identical to [2026-11-19](BOARD_ACCEPTANCE-2026-11-19.md);
- phase 12 records `POST_LINUX_ACCEPT_FAIL` because the OpenSSL matrix hit
  its 600 s limit; phase 13 completed it (92 pairs, none missing or bad).

One boot froze, after a hand-over of the console port between two host
processes ([Console hand-over](#finding-a-boot-froze-after-a-console-port-hand-over)).
The freeze did not recur in four further software reboots, and every later reset and reconfiguration of the session booted; the cause is open.

Every recorded interval of the new health tests on the real rings ended
with zero failures, about 100 minutes in total
([Health tests](#health-tests-on-the-board)); other intervals were cleared
by a reset without a reading, and the tests do not run in test mode. That is
evidence that they do not raise false alarms on this source in those
intervals; it is not evidence that they detect a failing source, which is
shown in simulation only.

## Image and evidence

| Item | Tested value |
| --- | --- |
| Bitstream SHA-256 | `ddb168e1081c9b73c29cd5a16ab777ee8106a52d382469b5b741b094bc096aad`; bundle `88dce485…817342`; [build record](MEASUREMENTS.md#fpga-image--2026-11-20) |
| Boot ROM | read back from the bundle's manifest: OpenSBI `cbbbe5ce…`, U-Boot 2026.10 `7a27c424…` (banner `Nov 19 2026 - 22:30:01`), device tree `784e2762…`; fu-boot and U-Boot built by `$RISCV`'s `riscv64-unknown-elf-gcc` |
| Key | `flow/auth_record.py verify` accepts the bundle's key for this bitstream; fingerprint `276bf6e96d8edecc` |
| Served files | `board.dtb` `784e2762…`; `Image` `3b45e852…` (`7.4.0-rc3-zvk-dirty`) |
| Sources | built from karu64 `f014194` with uncommitted changes, since committed as `713f69d` on `zkr-dev`; karudeb `db180ff` |
| Fixtures | rebuilt from `713f69d` for the new `mentropycfg` layout; harness self-test 222 checks, 33 scripts |

Evidence: `_build/dbg/board-accept-20261120-rom2m-auth/` on the lab host:
per-phase results and traces, `mentropystat.log`, `chosen-stageB.txt`,
`noise-run1/` (k-sweep and burst capture with analysis), `restart-rows.bin`
and `restart.json`, the post-Linux evidence, `auth-history.json`, and the
helper scripts used (`campaign-tools/`). The UART capture is
`_build/boot.log`. The NIST tool outputs are in `_build/nist-90b/results/`
(`d20-*`, `r20-*`).

## Results

| Stage | SW12 1–4 | What | Result |
| --- | --- | --- | --- |
| B | all off | First boot after programming | PASS. U-Boot banner `Nov 19 2026 - 22:30:01`; no "No RNG device"; `/chosen` held an 8-byte `kaslr-seed` (`chosen-stageB.txt`, size only); login 4.3 min after the kernel started |
| B | all off | `linux_zkr.py` | PASS 3/3 |
| B | all off | U-Boot prompt with the source on, twice (`rng list`, `rng 0 10`) | PASS: `RNG #0 - riscv_zkr`, 16 bytes each time |
| B | all off | Software reboots | 4 of 5 booted: three by `linux_reboot.py` (441–446 s each) and one driven at the U-Boot prompt with one process holding the console port. The first, at 09:01, froze after a console port hand-over; see the finding below. Every boot after a reconfiguration (seven) or a detach by debugger reset-halt (two) reached Linux or, in Stage E, the state the case expects |
| C | all off | Phases 1–5, 7–11, 14 | PASS. Reset-halt DPC `0x10000`; soak 600 s, 9,548 batches |
| C | all off | Phase 6, translation | FAIL, expected: the same six walker results as on 2026-11-19 |
| D, D2 | all off | k-sweep (k = 1 to 32), one burst run (9 periods × 32 bursts), 1,000 delayed warm restarts | PASS: every capture complete, no retries (see [Noise](#noise-capture-and-entropy-estimates)) |
| F | all off | Phase 12 | `POST_LINUX_ACCEPT_FAIL`: OpenSSL hit its 600 s limit; `board_accept.sh`, both KVM tests, the vector selftests and `xtest` passed |
| F | all off | Phase 13 | PASS: 92 pairs, none missing or bad |
| E | on off on off | `locked`, `authenticate` (one power-on); `wrong-response`, `replay`, `expiry` (one each), with SHA3 and the bundle's key | PASS. Unlock 0.19 s after the REQUEST; window last seen open at 14.29 s, closed by 14.35 s; four distinct nonces, all algorithm `0x04` |
| E | on off on on | `entropy-off` | PASS: window closed 0.21 s after the REQUEST without a challenge; U-Boot printed "No RNG device" once and booted (stage A's time-out path); Linux booted locked |

Every Stage E power-on was a JTAG reconfiguration of the same bitstream
(the case records' "CPU reset button" is the harness's fixed text). The
cases that test only authentication RTL unchanged since 2026-11-18 (`open`,
`no-hold`, `disabled`, `reboot`, `reboot-locked`) and `fresh-nonce` were not
run. SW12 was changed three times in the session: to `on off on off`, to
`on off on on`, and back to all off.

The `expiry` case shows that the ROM's deadline (2³⁰ clocks, 14.3 s) still
closes the window. The new hardware limit (2³¹ clocks, 28.6 s) was not
reached, so it has no board evidence; it is tested in simulation.

## Health tests on the board

`mentropystat` (`0x7CA`) was read with the hart halted for a moment and no
reset (`campaign-tools/entstat.py`) before most steps that reset the SoC,
since any reset clears it. Not read: the intervals ended by the three
software reboots of `linux_reboot.py`, by the debugger phases' reset-halts
before the last one, and by the Stage E power-ons; in locked `AUTH` it
cannot be read. The tests also do not run while the source is in test mode
(the GetNoise, burst and restart captures). Every reading:

| Time | Interval since the last reset | `mentropystat` |
| --- | --- | --- |
| 08:57, 08:59 | power-on 08:49 | `0x1`: running, no alarm, no strikes, 0 failures |
| 09:53, 09:54 | detach 09:12:50 (41 min) | `0x1`, 0 failures |
| 10:19 | software reboot 10:12:30 | `0x1`, 0 failures |
| 10:26 (twice) | software reboot 10:21 | `0x1`, 0 failures |
| 10:36 | the debugger phases' last reset-halt | `0x1`, 0 failures |
| 11:09 | detach 10:54:26 | `0x1`, 0 failures |
| 12:04 | reconfiguration 12:00:19 | `0x1`, 0 failures (start of the long run) |
| 12:11 | the same | `0x1`, 0 failures |

`mentropycfg` read `0x30c7c1eb3c37000f` each time, the reset value of this
image. The tests run while the source is outside test mode, about 18,300
kept samples per second, so these intervals cover, by that rate, an
estimated 1.1 × 10⁸ samples without a failure at the reset cutoffs (15 and 124 on the 4-bit
sample, 55 and 719 per lane). Replay of the day's captures through the
tree's model of the health logic (`test/entropy_replay.py`, 25/25 checks)
agrees: no failure on the 10⁶-sample k = 16 capture (largest counts 6 of
15, 52 of 124, 24 of 55, 572 of 719) nor on any of the 1,000 restart rows.

**Long run.** The board was reprogrammed at 12:00:19 with SW12 all off and
left running Linux; at 12:11:45, before any reset, `mentropystat` read `0x1`
with 0 failures. That interval is 11 minutes, not the hours section 8 asks
for: **the hours-long reading is still open.** The board was left running so
that it can be taken before the next reset. Over the day the readings
cover about 100 minutes of the source outside test mode (an estimated
1.1 × 10⁸ kept samples, from the sampling rate), and every one of them
ended with zero failures; the intervals listed above as not read are not
part of that.

## Noise capture and entropy estimates

| | D19 (`85f07e58…`, 2026-11-19) | D20 (`ddb168e1…`, today) |
| --- | --- | --- |
| `ea_non_iid`: H_original, H_bitstring | 3.856, 0.882 | 3.855, 0.889 |
| min(H_original, 4 × H_bitstring), per 4-bit sample | 3.526 | 3.556 |
| `ea_iid` | passed | passed |
| Delayed warm restarts, `ea_restart` with that value as a trial input: X_max (cutoff), H_r, H_c | 100 (133), 3.856, 3.862 | 97 (130), 3.873, 3.688 |

These are statistical estimates, not an established H_I, and the restart
data is the delayed warm-restart experiment of the
[assessment](../doc/sp800-90b-assessment.md#44-restart-tests-314-a-delayed-warm-restart-experiment),
not the operational restart requirement.

**The ring frequencies are a property of the bitstream.** The burst capture
was analysed as on 2026-11-19. As then, all four lanes miss the analysis's
25 % criterion for a jitter variance proportional to the sample spacing
(log-log slopes 1.10 to 1.25), so the white-noise model does not describe
them fully. The fitted variance per clock of lanes 0 to 2 lies within the
range of the eight 2026-11-19 runs; lane 3's, 0.55 × 10⁻³, lies below it
(0.68–0.88 × 10⁻³). Two lanes run at different frequencies relative to the
clock:

| Lane | F, `85f07e58…` (eight runs) | F, `ddb168e1…` | σ²/clock, `85f07e58…` | σ²/clock, `ddb168e1…` |
| --- | --- | --- | --- | --- |
| 0 (3 stages) | 0.154–0.163 | **0.409** | 2.0–2.7e-3 | 2.1e-3 |
| 1 (5 stages) | 0.105–0.113 | 0.116 | 1.3–1.5e-3 | 1.5e-3 |
| 2 (7 stages) | 0.462–0.466 | 0.465 | 0.81–0.97e-3 | 0.88e-3 |
| 3 (9 stages) | 0.480–0.482 | **0.016** | 0.68–0.88e-3 | 0.55e-3 |

The rings are placed in the same slices; the routing of the implementation
differs. F is the folded fraction of a ring frequency many times the
75 MHz clock, so a few percent change in a ring's delay moves it a lot.
Lane 3 at F ≈ 0.016 changes value only about every 30 samples at one
sample per clock. At the shipped spacing (4,096 clocks) this makes no
visible difference, as the estimates and the replay above show, but the
characterisation has to be repeated for every bitstream. No lane pair was
flagged for dependence in this run; the 256-clock burst and the k = 1
capture differ on lane 3 (z 6.8), as on 2026-11-19. Die 23.9–25.2 °C.

## Finding: a boot froze after a console port hand-over

At 09:01 a software reboot was driven at the U-Boot prompt by one host
process (`uboot_prompt.py`), which released the serial port when the kernel
started; the capture (`serial_cap.py`) reopened it. The kernel printed up to
`SBI TIME extension detected` and one character of the next line, then
nothing. The board stopped answering on the network, and OpenOCD found the
hart running (`dmstatus` `0xc83`) but could not halt it. A debugger
reset-halt (`ndmreset`) at 09:12:50 recovered it.

- The freeze did not recur in four subsequent software reboots with the
  console port left open, nor when the same U-Boot test was repeated with
  one process holding the port throughout (`campaign-tools/console_drive.py`).
  That establishes recovery, not the cause: an intermittent FPGA-side stall
  is not ruled out.
- A mechanism exists in the SoC: a write to the UART's transmit register
  waits while the UART is not ready (`uart_thr_wait`,
  `flow/fpga/karu_ddr_xbar.v`), and the UART only transmits while the host
  asserts RTS (the FPGA's CTS). A hart stalled in that store cannot halt.
  It is not established: there was no CTS trace, and the reopening process
  asserts RTS, so why the stall did not clear is not explained. If it
  recurs, record GPIO LED 3 (the raw CTS input) before any reset.
- Practice: keep one process holding the console port from before a reset
  until the end of the session.

A side effect: the session's first wrapper script did not stop when
OpenOCD failed to examine the target, so its later steps ran against an
unexamined target and failed; those steps were rerun with a fail-fast
wrapper (`campaign-tools/run_stage_cd.sh`) and passed.

## Not done

- Authentication cases `open`, `no-hold`, `disabled`, `reboot`,
  `reboot-locked` and `fresh-nonce` on this image.
- The hardware window limit on the board (the ROM's deadline comes first).
- Operational restart data, a wider temperature range, and a fallback
  image on the lab host: `85f07e58…` was not available here if this image
  had failed to boot.
