# VCU118 acceptance — 2026-11-19: burst capture, SHA3 authentication, U-Boot v2026.10

The board session of image `85f07e58…`, following
[the board test plan](BOARD_TEST_PLAN.md) (its section 7 at the time)
on the lab host. **Accepted, with documented exceptions.** Every stage was
completed. Two phases did not exit cleanly, as on 2026-11-16 and 2026-11-18:
- translation, with the six known pristine-OpenOCD walker results of
  [2026-11-16](BOARD_ACCEPTANCE.md#findings), identical to
  [2026-11-18](BOARD_ACCEPTANCE-2026-11-18.md);
- phase 12, which recorded `POST_LINUX_ACCEPT_FAIL` because the OpenSSL
  matrix hit its 600 s limit (rc 124). Every other test of that phase
  passed, and phase 13 completed the matrix: 92 pairs, none missing or bad.

Stage E ran a reduced set of
authentication cases, with JTAG reconfiguration as the power-on reset; see
[Authentication](#authentication-stage-e).

The authentication cases show that a correct SHA3 response unlocks and that
the tested wrong and replayed responses do not. That is not a general
assurance that a debugger without the key is kept out, and the key is in
the bitstream and in the programming bundle, so it says nothing about
anyone who has either. No entropy figure for `seed` follows from the
noise captures; they do show a dependence between two lanes
([Noise](#noise-capture-stage-d2)).

## Image and evidence

| Item | Tested value |
| --- | --- |
| Bitstream SHA-256 | `85f07e58354646ff3102fe3ddfe8c2e91005b5171b895391aea7ea3795f2639a`; bundle `fbdec6e4…`; [build record](MEASUREMENTS.md#fpga-image--2026-11-18-evening) |
| Configuration | as `d7ff00dc…`, plus the burst capture block and the temperature and supply readout |
| Boot ROM | OpenSBI `cbbbe5ce…`, U-Boot 2026.10 with the Zkr time-out patch `0e560318…`, device tree `784e2762…` |
| Island ROM | `f518b750…`, algorithm `0x04` (SHA3-256, shared secret), key fingerprint `276bf6e96d8edecc`; `flow/auth_record.py verify` accepts the bundle's key for this bitstream |
| Served files | `board.dtb` `784e2762…`; `Image` `3b45e852…` (`7.4.0-rc3-zvk-dirty`) |
| Sources | built from karu64 `a39f3da` with uncommitted changes, since committed in `64c9266` (which also holds later documentation); the build host's `_build/vcu118-2026-11-18c-sources/` was not compared here |
| OpenOCD, adapter, console | as on 2026-11-18 |

Evidence: `_build/dbg/board-accept-20261119-rom2m-auth/` on the lab host
(bundle and hash in the [Evidence bundle](#evidence-bundle) section). It
holds the per-phase results and command traces, the UART capture
`uart-boot-20261119.log`, one directory per noise run with its captures,
sidecars and analysis, `noise-summary.txt`, `auth-history.json`, the
programming logs and the helper scripts used (`campaign-tools/`).

## Results

| Stage | SW12 1–4 | What | Result |
| --- | --- | --- | --- |
| B | all off | First boot: island ROM, fu-boot, OpenSBI v1.9 (`zkr`), U-Boot 2026.10, TFTP, Linux, NFS | PASS. `/chosen` held a `kaslr-seed` (8 bytes) when checked over SSH after this boot, which is what the Zkr driver does with the source on. That output was not saved at the time; `chosen-observations.txt` transcribes it |
| B | all off | `linux_zkr.py`; `linux_reboot.py`, three cycles with the new default limits | PASS; 441–446 s per cycle, through the boot ROM and U-Boot 2026.10 each time |
| A | off off off on | U-Boot prompt: `rng list`, `rng 0 10`; then autoboot | PASS: both answer "No RNG device" at once; autoboot prints it once and boots; `linux_zkr.py` passes. `/chosen` had no `kaslr-seed` when checked over SSH (transcribed in `chosen-observations.txt`) |
| — | all off | U-Boot prompt with the source on | PASS: `rng list` shows `RNG #0 - riscv_zkr`; `rng 0 10` prints 16 bytes |
| C | all off | Phases 1–5, 7–11, 14 | PASS, as on 2026-11-18 |
| C | all off | Phase 6, translation | FAIL, expected: the same six walker results |
| D2 | all off | Burst capture, eight runs, and the k-sweep | PASS: every capture complete (see [Noise](#noise-capture-stage-d2)) |
| F | all off | Phase 12: `board_accept.sh`, KVM `ebreak_test` and `arch_timer`, vector selftests, `xtest`, OpenSSL | Phase 12 FAIL (`POST_LINUX_ACCEPT_FAIL`): the OpenSSL matrix hit its 600 s limit (rc 124); every other test passed (`post-linux-run.log`). The evidence copy now completes within its limit |
| F | all off | Phase 13: completes the OpenSSL matrix | PASS: 92 unique pairs, none missing or bad (`openssl-matrix-result.json`). With it the acceptance holds, as on 2026-11-16 and 2026-11-18 |
| E | on off on off | `locked`, `authenticate` (one power-on), `wrong-response`, `replay`, `expiry` (one each) | PASS with SHA3 (see [Authentication](#authentication-stage-e)) |
| E | on off on on | `entropy-off` | PASS: window closed 0.21 s after REQUEST without a challenge; U-Boot printed "No RNG device" once; Linux booted locked |

The board was left reprogrammed with SW12 all off, booted to Linux.

## Noise capture (stage D2)

Each run: 32 bursts of 32,768 consecutive raw symbols at each sampling
period of 1, 2, 4, …, 256 clocks. Run 1 also has the k-sweep
(`getnoise_capture.py`, 10^6 symbols at each k from 1 to 32). The die
temperature stayed between 23.9 and 24.9 °C and VCCINT between 0.8455 and
0.8474 V over all 144 readings of the new readout.

| Run | Reset before it | Lane 0 F, σ²/clock | Lane 1 | Lane 2 | Lane 3 |
| --- | --- | --- | --- | --- | --- |
| 1 | none (after the debugger phases), link up | 0.158, 2.04e-3 | 0.107, 1.36e-3 | 0.464, 0.90e-3 | 0.481, 0.79e-3 |
| 2 | CPU_RESET | 0.163, 2.29e-3 | 0.108, 1.38e-3 | 0.463, 0.97e-3 | 0.481, 0.71e-3 |
| 3 | CPU_RESET | 0.160, 2.30e-3 | 0.109, 1.39e-3 | 0.464, 0.90e-3 | 0.480, 0.73e-3 |
| 4 | software reset (debugger SBA write of `0x7777` to `0x1000_0800`) | 0.159, 2.27e-3 | 0.113, 1.30e-3 | 0.466, 0.87e-3 | 0.480, 0.77e-3 |
| 5 | none; Ethernet cable unplugged | 0.163, 2.09e-3 | 0.108, 1.43e-3 | 0.462, 0.81e-3 | 0.482, 0.68e-3 |
| 6–8 | JTAG reconfiguration | 0.154–0.159, 2.03–2.68e-3 | 0.105–0.109, 1.28–1.51e-3 | 0.462–0.464, 0.85–0.95e-3 | 0.481–0.482, 0.77–0.88e-3 |

F is a ring's frequency relative to the clock (folded), fitted at one
sample per clock; σ² per clock is the fitted jitter variance divided by the
spacing. It is a model parameter: neither a jitter amplitude nor an entropy
estimate. Ones fractions stayed between 0.491 and 0.496.

- **The model can now be fitted.** At one sample per clock every lane shows
  its frequency, and F scales with the period as the model of
  arXiv:2102.02196 predicts. At 256 clocks per sample (the earlier
  captures) it could not be fitted.
- **The fitted jitter variance per clock** falls with ring length: about 2.2 × 10⁻³ for the
  3-stage ring, 1.4 × 10⁻³, 0.9 × 10⁻³ and 0.75 × 10⁻³ for the 9-stage
  ring.
- **Not white noise.** σ² grows faster than in proportion to the spacing
  (log-log slopes 1.09 to 1.29 in run 1), which the analysis reports as not
  linear: a flicker or wander component. Only the white part could be
  credited as independent.
- **Resets.** Reconfiguration, CPU_RESET and the software reset give the
  same picture within the run-to-run spread (F ±0.005, σ² ±15–20 %); so
  does the link being down. The software reset resets the entropy source
  with the hart (it is on `soc_rst`), so it can stand in for the button in
  noise repeats, and needs nobody at the board. It does not stand in for
  authentication (no new window).
- **Lanes 2 and 3 are not independent.** The analysis flags this pair in
  four places:

  | Run | Test | Value |
  | --- | --- | --- |
  | 1 | shared frequency wander, P = 1 | r = −0.78, z 4.78 |
  | 2 | shared frequency wander, P = 1 | r = −0.85, z 5.08 |
  | 2 | cross-correlation at lag −2, P = 8 | z 4.79 |
  | 8 | coherence at P = 2 and P = 4 | 0.016 and 0.009, threshold 0.007 |

  In run 8 the coherence peaks at the same frequency per clock at both
  periods, about 0.027 cycles per clock (about 2.05 MHz). A common
  disturbance reaching the two rings, such as supply ripple, would explain
  this; that is a hypothesis, not established. Lanes 2 and 3 sit in neighbouring slice
  columns. Two further flags are at the threshold: shared wander of lanes
  1 and 2 (run 4, z 4.58) and 1 and 3 (run 7, z 4.51). The burst at 256
  clocks and the k = 1 sweep of run 1, taken eight minutes apart, also
  differ on lane 3 (z 6.9), which the analysis attributes to drift.
  A per-lane figure therefore cannot be added up into a figure for a word.

## Authentication (stage E)

Every case was run with `KARU_BOARD_AUTH_ALG=SHA3` and the bundle's key.

| Case | Result |
| --- | --- |
| `locked` | examine refused; window left unused |
| `authenticate` | algorithm SHA3; unlocked 0.20 s after the REQUEST (0.16 s with `TEST` on 2026-11-18); grant in `mdbgauth`; register round trip; window `CLOSED` |
| `wrong-response` | one bit wrong: locked, window closed, further SEND refused |
| `replay` | the 12:03 UTC response sent for a new challenge: locked |
| `expiry` | last seen open at 14.28 s, closed by 14.33 s (2^30 cycles: 14.32 s) |
| `entropy-off` | no challenge; window closed after 0.21 s; Linux booted |

The four challenges carry distinct nonces, and each names algorithm `0x04`.

**Reduced set.** Between this image's sources and those of `d7ff00dc…`, the
authentication RTL (`karudbg_auth`, the Debug Module, the core gate, the
island) did not change; the island ROM (`window.c`, new `sha3.c`, the key)
and the entropy block did. The cases above exercise what changed. `open`,
`no-hold`, `disabled`, `reboot` and `reboot-locked` test unchanged RTL and
were not repeated; they passed on 2026-11-18. `fresh-nonce` also exercises
the entropy source and the ROM's challenge path, which did change, and was
not rerun as a case: the four distinct nonces of this session are
supporting evidence, not that case.

**Reconfiguration as the power-on.** Each case's power-on was a JTAG
reprogramming of the same bitstream, which resets the authentication block
and samples the straps, as the CPU reset button does. The case records
still say "CPU reset button", which is the harness's fixed text.

## Notes and findings

- **The SW12 switches are hard to reach** (tiny, read with a phone
  camera). Sessions should change them as rarely as possible: group the
  cases by switch setting, change one switch per step, and use
  reconfiguration or the software reset instead of the button where the
  test allows.
- A debugger SBA write that triggers the software reset is reported by
  OpenOCD as "failed to write memory": the reset cancels the write's
  response. The SBA status shows no error afterwards.
- After that software reset, `server.cfg`'s EBREAK controls stopped the hart
  at OpenSBI's semihosting probe (`0x8001c364`), the known interaction of
  2026-11-16; the noise capture did not need the boot to continue.
- U-Boot 2026.10 prints "Loading Environment from nowhere..." twice; this
  is cosmetic.
- The burst phase's `TIMEOUT` message still asks whether switch 4 is on,
  although switch 4 now gives `ABORTED` (noted by the build host); it did
  not occur.

## Evidence bundle

`_build/dbg/board-accept-20261119-rom2m-auth.tgz` on the lab host; its size,
file count and SHA-256 are in `board-accept-20261119-rom2m-auth.tgz.sha256`
beside it, and `SHA256SUMS-campaign` inside covers every file.
