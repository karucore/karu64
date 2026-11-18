# VCU118 acceptance — 2026-11-18: Zkr, debug authentication, 2 MiB ROM

The first board session of the image with the Zkr entropy source, debug
authentication in the FPGA, the SW12 straps, the 2 MiB boot ROM, software
reboot and OpenSBI v1.9. It followed [the board test plan](BOARD_TEST_PLAN.md),
stages A to F, on the lab host. All stages pass. The one failing phase is
the translation phase, with the same six pristine-OpenOCD software-walker
results as [on 2026-11-16](BOARD_ACCEPTANCE.md#findings). Two harness
timeouts were too short for this board; the runs used longer ones, and the
harness now has them as defaults (see [Deviations](#deviations)).

The authentication cases use the simulation-only `TEST` algorithm, which
anyone can compute. They show that the mechanism works on the hardware:
straps, mailbox, window, nonce, grant, revocation by reset. They show
nothing about protection. No entropy figure for `seed` follows from the
noise captures.

## Image and evidence

| Item | Tested value |
| --- | --- |
| Board | VCU118, XCVU9P, 75 MHz CPU, 2 GiB DDR4 |
| Bitstream SHA-256 | `d7ff00dc494d8354ce596b3e7ebb07aabb2df92f9df186d8a3870b9a972a3e80` (bundle `5e93e662…`), [build record](MEASUREMENTS.md#fpga-image--2026-11-18) |
| Configuration | `KARU_RVA23S64`, `KARU_DBG_FULL`, `KARU_DBG_AUTH`, `KARU_ZKR` |
| Boot ROM | OpenSBI v1.9 `cbbbe5ce…`, U-Boot 2025.01 `0d305f3f…`, device tree `784e2762…` (`rva23s64-zkr-ddr`); island ROM `c6efbc76…` |
| Served files | `board.dtb` `784e2762…`; `Image` `3b45e852…`, `7.4.0-rc3-zvk-dirty` |
| Sources at the session | karu64 `750c114`, karudeb `d723a31` (both clean). The bitstream was built from `d58aa6f` and `8dfc019` with uncommitted changes, since committed; its input manifest is on the build host and was not compared here |
| OpenOCD | `0.12.0+dev-02815-g83e3febc6`, binary `1c3079e9…`, as on 2026-11-16 |
| Adapter, console | Digilent JTAG-SMT2-NC `210308AE622F`; CP2105 SCI at 115200 baud |

Evidence: `_build/dbg/board-accept-20261118-rom2m-auth/` on the lab host,
bundled as `_build/dbg/board-accept-20261118-rom2m-auth.tgz` (22,283,198
bytes, 438 files), SHA-256
`0ce9956d49f73e4b063165cdbe68cc05b174811d49a2616685428fdf254e583a`. In it:
`CAMPAIGN-NOTES.md` (stage by stage, with switch positions and times),
per-phase JSON results and JSONL command traces, the UART capture
`uart-boot-20261118.log`, the noise captures and their analysis, the
post-Linux evidence, `auth-history.json`, the two programming logs and
`SHA256SUMS-campaign` over every file.

## Results

| Stage | SW12 1–4 | What | Result |
| --- | --- | --- | --- |
| A | off off off on | Island ROM → fu-boot → OpenSBI v1.9 (`zkr`, `syscon-reboot`) → U-Boot → Linux → NFS root; `linux_zkr.py` | PASS. Login 4.5 min after programming |
| A | same | `auth_phase.py` `open`: lifecycle, hold and `seed` read back | PASS: `mdbgauth=0xa`; `seed` BIST in 20 reads |
| B | all off | Same boot with the entropy source on; console compared with stage A | PASS; no duplicated characters (the 2026-11-16 symptom) |
| B | all off | `linux_zkr.py`; `linux_reboot.py`, three cycles | PASS; each cycle 440–443 s, fu-boot and OpenSBI banners after every `reboot: Restarting system` |
| C | all off | Phases 1–5, 7–10, 11, 14: Linux context, reset-halt and fixture, extended, GDB, transport, run control, privilege, crypto aperture, 600 s soak, clean detach, live kernel breakpoint | PASS. Reset-halt DPC = `0x10000` (the island) in phases 2 and 11; fixture at `0x208000` |
| C | all off | Phase 6, translation | FAIL, expected: the six known walker cases |
| D | all off | GetNoise, k = 1, 2, 4, 8, 16, 32 | PASS: 10^6 symbols each, one run, no losses (see [Noise](#noise-capture)) |
| F | all off | Phase 12: `board_accept.sh`, KVM `ebreak_test` and `arch_timer`, `validate_v_ptrace`, `vstate_ptrace`, `vstate_prctl`, `v_initval`, `xtest`; phase 13 | PASS. OpenSSL hit its 600 s limit in phase 12, as on 2026-11-16; phase 13 completed all 92 pairs, none missing or wrong |
| E | on off on off | `locked`, `authenticate` (same reset), `reboot` (same power cycle, Linux up) | PASS. Unlocked 0.16 s after REQUEST; grant and `CLOSED` window kept across a software reboot |
| E | same | `fresh-nonce`, `wrong-response`, `replay` (one reset each) | PASS. Four distinct nonces from `seed` across the series |
| E | same | `expiry` | PASS. Window last seen open at 14.31 s, closed by 14.36 s (2^30 cycles at 75 MHz: 14.32 s) |
| E | on off off off | `no-hold`, then `reboot-locked` | PASS. Locked DM: examine refused, `dmstatus=0x3`, `dmcontrol` only `dmactive`, other registers 0, writes and `haltreq` ignored; Linux boots; a software reboot leaves it locked |
| E | on off on on | `entropy-off` | PASS. The ROM gets no ES16 word, closes the window 0.21 s after REQUEST without a challenge; Linux boots |
| E | off on off off | `disabled` | PASS. No mailbox; locked; Linux boots |

Also shown on hardware for the first time: the hart starting in the island
ROM and handing over to fu-boot in every lifecycle; the 2 MiB ROM layout and
the new scratch SRAM; the CPU_RESET button as the straps' power-on reset
(nine presses, each retraining DDR4); the software reset through
`0x1000_0800` (eight reboots in total); and GetNoise keeping up at k = 1.

## Noise capture

`getnoise_capture.py` at k = 1, 2, 4, 8, 16 and 32 (256 clocks per raw
sample, so 3.4 µs to 109 µs between kept samples), after reconfiguration,
three software reboots and the debugger phases, hart under the debugger,
Ethernet up. `getnoise_analyze.py` without thresholds, so no verdict:

| Lane (ring stages) | Ones fraction | Longest repetition (cutoff 41) | Largest APT count (cutoff 821) |
| --- | --- | --- | --- |
| 0 (3) | 0.485–0.486 | 18–22 | 570–586 |
| 1 (5) | 0.497–0.498 | 18–25 | 554–562 |
| 2 (7) | 0.491–0.493 | 19–21 | 566–574 |
| 3 (9) | 0.492–0.494 | 17–25 | 561–573 |

- The bias is a fixed property of each ring; it does not change with k.
- Serial correlation is visible only at k = 1, on lanes 3 (lag-1 0.026) and
  2 (0.005). Everywhere else the fit finds no autocorrelation and gives
  only a lower bound on the jitter, sigma^2 ≥ 0.13, so F is not seen and
  the model figure (0.754 bits per bit) is that bound, not a measurement.
- No lane pair is flagged at any k; a correlation above about 0.0045 would
  have been.
- 16-bit words: 13.2–13.4 bits at the 99 % bound from the distribution and
  the word predictor, which is what 250,000 samples can show (a uniform
  source gives about 14.0).

The source behaves as designed. Characterising it needs samples much closer
together than one per 256 clocks; that and the repeated captures are in the
[Zkr follow-up plan](../doc/zkr-followup-plan.md). A separate read of 1,088
`seed` words from the debugger, before the captures, returned ES16 every
time.

## Deviations

1. **PROG pressed instead of CPU_RESET** while preparing stage B. The FPGA
   lost its configuration (all GPIO LEDs off, DTM unreadable) and was
   reprogrammed with the same bitstream, which was also stage B's
   power-on reset. Ask for the button by its label.
2. **SSH is slow on this board**: 30–55 s per connection (OpenSSH 10 on a
   75 MHz hart over NFS). `linux_reboot.py` probed with 30 s and never saw
   the board return; its first two runs failed for that reason alone (the
   reboots themselves went through the ROM). The passing runs used a
   wrapper with 180 s per SSH command, `KARU_BOARD_REBOOT_TIMEOUT=900` and
   `KARU_BOARD_AUTH_BOOT_TIMEOUT=900`. These are now the harness defaults
   (`KARU_BOARD_SSH_TIMEOUT`).
3. **`post_linux_host.py` evidence copy timed out** at 180 s; it takes about
   4.5 minutes. The archive was fetched again by hand with the same command;
   the limit is now 900 s.
4. **One TFTP stall** in 11 kernel loads (13:06, after a CPU_RESET): ten
   packet timeouts, then U-Boot's retry loaded the Image in 3 s. The host
   NIC had no receive errors and 24 transmit drops.

## Notes

- U-Boot prints "No RNG device" before every boot. Its `kaslr-seed` step
  finds no RNG driver, because the Zkr driver is deliberately off
  (`flow/build_uboot.sh`). It is harmless and was there on 2026-11-16 too.
- The SIGILL trace of `vstate_exec_nolibc` on the console during phase 12
  is that selftest's intended trap, as in earlier campaigns.
- Not done: noise captures after several cold starts and resets and under
  different activity (plan stage D extras), and the GPIO-LED and
  temperature records that would go with them.
