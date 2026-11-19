# Changelog

All notable changes to `karu64`. Format follows
[Keep a Changelog](https://keepachangelog.com/); the repository has no tags
yet; unreleased changes appear first, followed by merged checkpoints.

## [Unreleased]

### Tested — VCU118 board session, 2026-11-19

- Image `85f07e58…` (burst capture, temperature and supply readout, SHA3
  authentication, U-Boot v2026.10) is accepted with documented exceptions:
  translation fails with the six known OpenOCD walker results, and phase 12
  records `POST_LINUX_ACCEPT_FAIL` because OpenSSL hit its 600 s limit,
  completed by phase 13 (92 pairs, none missing or bad). The record
  is [dbg/BOARD_ACCEPTANCE-2026-11-19.md](dbg/BOARD_ACCEPTANCE-2026-11-19.md).
  - U-Boot 2026.10: with the source on, `rng 0 10` prints 16 bytes; with
    it off, `rng` answers "No RNG device" at once and the boot goes on.
    `/chosen/kaslr-seed` was present and absent accordingly when checked
    over SSH. Three software reboots.
  - The debugger phases and the Linux, KVM and OpenSSL acceptance pass as
    on 2026-11-18; the harness's new default limits need no wrapper.
  - Authentication with SHA3-256 and the build's key, six cases: `locked`,
    `authenticate`, `wrong-response`, `replay`, `expiry`, `entropy-off`,
    with JTAG reconfiguration as the power-on. `open`, `no-hold`,
    `disabled`, `reboot`, `reboot-locked` and `fresh-nonce` were not rerun.
  - Burst capture: eight runs (warm, two CPU resets, a software reset, the
    link down, three reconfigurations), each at 9 periods × 32 bursts. The
    noise model can be fitted at last: the fitted jitter variance per clock
    falls with ring length, grows faster than white noise would, and is
    stable across resets.
    **Lanes 2 and 3 are not independent**: shared frequency wander in two
    runs, a lagged cross-correlation, and a coherence peak at about 2.05 MHz
    in another; supply ripple is a hypothesis. Die temperature 23.9–24.9 °C throughout.
- The SW12 switches are hard to reach; the test plan now asks to change them
  as rarely as possible and to use reconfiguration or the software reset
  instead of the button where the test allows.

### Added — burst capture and temperature readout for the entropy source, SHA3 debug authentication, U-Boot v2026.10

Implemented on 2026-11-18 after the board session, from the
[Zkr follow-up plan](doc/zkr-followup-plan.md) (Z1 to Z5). Tested in
simulation, and built into VCU118 bitstream `85f07e58…` the same evening
(75 MHz met, setup +0.002 ns; [measurements](dbg/MEASUREMENTS.md#fpga-image--2026-11-18-evening)).
Board-tested on 2026-11-19; see the entry above. Bitstream `d7ff00dc…` has
none of it.

- **Sampling period in test mode (Z1).** `flow/fpga/karu_rosc_rng.v` takes
  its sampling period as an input, 1 to 256 clocks, in place of the
  `SAMPLE_DIV` parameter. Outside the entropy block's test mode the period
  is the build's 256, by construction: the register that sets it belongs to
  the capture block and exists only in test mode. `rtl/karu_entropy.v`
  gains two status outputs (`test_o`, `lock_o`) and is otherwise unchanged;
  the CSR contract is unchanged.
- **Burst capture (Z2).** `flow/fpga/karu_noise_burst.v` records 32,768
  consecutive raw symbols at the chosen period in four block RAMs. Its four
  registers are in the system-control block at `0x1000_0840`, read through
  an index and a data register, because a new address window would have
  needed a change to the core's physical access permissions. The bus decode
  passes on privileged 64-bit accesses only. Everything is confined to test
  mode: outside it, or with `mentropycfg` locked, nothing can be set or
  started and nothing is readable; leaving test mode forgets the recording.
  A window of one cycle in which the data register could have shown a word
  of the previous recording was found in review and closed (done is
  reported a cycle after the last word is written), with a bench check and
  a mutant.
- **Board scripts (Z3).** `getnoise_burst.S` and `getnoise_burst.py` capture
  bursts at periods of 1 to 256 clocks and write them in the capture file
  format, one run per burst, with the period and a clock-cycle stamp per
  burst in the sidecar. `noise_model.py` is the Python copy of the
  simulation's noise source, which gains a model with known parameters
  (`+rosc_jitter`, `+rosc_duty`) for the analysis to be validated on.
- **Analysis (Z3).** `getnoise_analyze.py` reads burst captures and
  compares all captures by the spacing of their samples in clocks. For
  samples close together it fits (F, sigma^2) per burst at lags up to an
  eighth of the burst, compares that with the fit pooled over bursts to
  show frequency wander, and takes the per-burst value, never the pooled
  one, for the per-bit model figure. It adds a spectrum per lane with the
  lines the model explains and any spurs, the coherence of each lane pair
  (locking), the correlation of the lanes' per-burst frequencies (shared
  wander) and the agreement of captures with equal spacing. On the copy of
  the simulated source, decimated to periods of 1 to 256 clocks, sigma^2
  comes out within 3% and proportional to the period. `--require-
  independent` now also fails on coherence or shared wander. The JSON
  format is `karu64-getnoise-analysis-3`; the earlier keys are kept. Eight
  board runs were analysed with it on 2026-11-19 (entry above).
- **Burst capture hardening (from review).** A capture runs only while the
  noise source is on: if it is off in any cycle of a capture, the start
  cycle included, the capture is aborted, holds nothing, and status bit 6
  says so; a burst with a gap could otherwise have been reported done. The
  payload reports it as status `ABORTED`.
- **Temperature readout (Z4).** `flow/fpga/karu_sysmon.v` reads the die
  temperature, VCCINT and VCCAUX from the system monitor every 14 ms into a
  register at `0x1000_0860`; the monitor is placed in the rings' SLR. Both
  capture scripts store it, raw and decoded, before and after each capture,
  and keep the previous capture's files until the new ones are complete.
  `make sysmon-xsim-test` checks it against Xilinx's SYSMONE4 model.
- **Tests, all in `make dbg-test`:** `noise-burst-test` (the capture block
  with the noise model and the entropy block; 36 one-mechanism mutants),
  `ddr-noise-burst-test` (the registers through the SoC's bus decode, from
  M-mode and, refused, from U-mode and with narrower accesses; eight decode
  mutants), `dbg-getnoise-burst-test` (the payload and the phase on the SoC
  simulation, every burst compared with the simulated source; three payload
  mutants) and `dbg-burst-analysis-test`.
- **Checked outside simulation:** an out-of-context Vivado synthesis of the
  entropy source infers the four RAMB36E2, adds 104 LUTs and 96 flip-flops
  for the capture block, meets 75 MHz with 10.6 ns to spare and has no loop
  but the four rings; the board top elaborates with the new wiring.
- **U-Boot (Z5).** `flow/build_uboot.sh` builds v2026.10 (801,805 bytes of
  the 901,120-byte slot) and refuses a tree of another release; the
  Makefile's default tree is `../u-boot-v2026.10`. The Zkr random-number
  driver is enabled with `flow/boot/uboot-zkr-timeout.patch`, which bounds
  its waits at 100 ms: the released driver waits without bound in `BIST`
  and `WAIT`. Its one use is `kaslr-seed`; `rng-seed` is not passed.
  `make uboot-boot-test` boots it from the ROM in simulation: with the
  entropy source on the driver delivers, with it off U-Boot reports "No
  RNG device" and boots on; `make uboot-tftp-test` fetches two files by
  TFTP through the modelled NIC. It is the first release after v2025.01 to
  go on the board.

### Added — SHA3-256 shared-secret debug authentication (algorithm 0x04)

- The FPGA image's island ROM verifies
  SHA3-256(key ‖ "karudbg-auth-v1" ‖ challenge ‖ granted) with a 32-byte key
  generated per build tree (`_build/vcu118_auth_key.txt`, owner-only); the
  board client computes the same (`KARU_BOARD_AUTH_KEY`). Simulation builds
  keep the TEST algorithm and a public test key. The ROM wipes its key
  copies and clears the island SRAM before leaving. This is an interim
  choice for the FPGA (contract §5.1, plan D3): anyone with the bitstream,
  or with the debugger in lifecycle `OPEN`, or privileged software on the
  hart, can read the key.
- `flow/auth_record.py` records, right after the bitstream is built, its
  hash, the algorithm, the island ROM's hash and the key's fingerprint; the
  programming bundle adds the key only when the record matches the
  bitstream, the ROM and the key file, and is written as a fresh mode-600
  file.

### Added — formal lemmas C1 and C3, C8 strengthened

- **C3** (Debug Module noninterference while locked): two copies with the
  same DMI and mailbox inputs and free, separate hart, debug-page and SBA
  inputs give identical DMI handshakes, responses and mailbox words in
  every cycle after reset. Unbounded (k = 6), with three controls.
- **C1** (bypass freedom): `make dbg-auth-bypass-test`, a structural
  inventory of the flattened `karudbg_top`: what reaches each protected
  element without crossing a cut, against an explicit allowlist; five
  controls. It compares which sources reach each element, so a further
  path from an already allowed source is not reported.
- **C8** also proves that the issue signal, and the PC on every issue,
  reach the authentication block in every cycle (the window closes on any
  issue outside the ROM); two more controls.

### Changed — KVM fixture pinned to OpenSBI v1.9

- `test/kvm-karu` pinned karudeb's OpenSBI v1.8.1 while karudeb has built
  v1.9 at the default path since 2026-11-17, so the fixture's build stopped
  with a fingerprint mismatch. The pin is now v1.9 (`cbbbe5ce…a638`), the
  binary of the board image's ROM. The kernel and initramfs of the fixture
  come out byte-identical to the v1.8.1 fixture's.
  With v1.9 both upstream guests complete under the fixture's QEMU control
  and on RTL (about 245 million cycles); the results are in
  [test/kvm-karu/README.md](test/kvm-karu/README.md#results-with-opensbi-v19).

### Fixed — a fresh clone could not pass `make dbg-test`

Found when the gate was run on a new clone, with an empty `_build` and
`TMPDIR` inside the repository:

- The Zkr bench rule did not create its directory, which only existed if
  another rule had run first; with parallel jobs from an empty `_build` the
  bench build failed.
- `test_isa_replay.py` compared a path in a form that holds only when the
  temporary directory is outside the repository; with `TMPDIR` inside it
  the self-test failed.

### Fixed — documentation

- The FPGA guide's section on debug images is no longer headed "Latest
  completed debug image — 2026-10-29", and the statement there and in the
  measurements that the image "has not been programmed" now says which
  image that was and where the acceptance was done since.

### Tested — VCU118 board session, 2026-11-18

- The debug image `d7ff00dc…3e80` (Zkr, debug authentication, 2 MiB boot
  ROM, SW12 straps, software reboot, OpenSBI v1.9) ran every stage of
  [the board test plan](dbg/BOARD_TEST_PLAN.md) on the lab VCU118; all
  pass. The record is
  [dbg/BOARD_ACCEPTANCE-2026-11-18.md](dbg/BOARD_ACCEPTANCE-2026-11-18.md).
  - Boot through the authentication island into fu-boot, OpenSBI v1.9 with
    `zkr` and `syscon-reboot`, U-Boot, Linux `7.4.0-rc3-zvk-dirty` on NFS;
    Linux lists `zkr`; no duplicated console characters.
  - Software reboot: eight in total, each back through the boot ROM and
    OpenSBI.
  - The debugger phases on the 2 MiB map, including reset-halt at the
    island (`0x10000`), the 600 s soak, detach and a live kernel
    breakpoint. Translation fails with the six known pristine-OpenOCD
    walker results of 2026-11-16.
  - `board_accept.sh`, the KVM tests, the vector selftests, `xtest` and all
    92 OpenSSL pairs.
  - All twelve authentication cases, with the nonce from the physical
    entropy source and the `TEST` algorithm (no protection is claimed).
  - GetNoise: 10^6 raw symbols at each k from 1 to 32, no losses. The
    lanes show a fixed bias (lane 0 at 0.485) and no detectable
    dependence. At one raw sample per 256 clocks the noise model cannot be
    fitted, so no entropy figure follows.
- Found on the board: an SSH connection takes 30–55 s and a reboot about
  440 s, which the harness's limits did not allow for (below); and one
  TFTP stall in 11 kernel loads, recovered by U-Boot's retry.

### Changed — board harness limits

- `linux_reboot.py` and `auth_phase.py`: one SSH command may take
  `KARU_BOARD_SSH_TIMEOUT` seconds (default 180; the reboot probe used 30 s
  and never saw the board return). `KARU_BOARD_REBOOT_TIMEOUT` and
  `KARU_BOARD_AUTH_BOOT_TIMEOUT` default to 900 s (were 300 s).
- `post_linux_host.py`: the evidence copy may take 900 s (was 180 s; it
  takes about 4.5 minutes), the remote `mkdir` 180 s.
- `make dbg-board-harness-test` passes (204 checks, 26 scripts).

### Added — Zkr follow-up plan

- [doc/zkr-followup-plan.md](doc/zkr-followup-plan.md): a runtime sampling
  divider, burst capture of raw samples for characterisation, repeat
  captures, and a U-Boot update using the headroom of the 2 MiB ROM.

### Fixed — documentation

- Board-status statements across the FPGA guide, the READMEs, the
  authentication plan (A5 is done), the board harness README and the S6
  follow-up now describe the tested image.
- The 2026-11-15 security review no longer links into the untracked
  `_build` tree.

### Added — Zkr entropy source, 2 MiB boot ROM, authentication in the FPGA image

Implemented and simulated on 2026-11-17, and built into the VCU118 debug
image on 2026-11-18: bitstream `d7ff00dc…3e80`, timing met at 75 MHz
([measurements](dbg/MEASUREMENTS.md#fpga-image--2026-11-18)). Board-tested
on 2026-11-18; see above.

- **Zkr (`KARU_ZKR`, opt-in).** The `seed` CSR (`0x015`) with the access
  rules of the ISA manual's table (M always; S/HS with `SSEED`; U with
  `USEED`; VS/VU a virtual-instruction exception with `SSEED`, illegal
  otherwise; a form that does not write is always illegal), `mseccfg`
  (`0x747`) with only `SSEED` and `USEED`, and two custom M-mode CSRs:
  `mnoise` (`0x7C8`), the GetNoise test interface, and `mentropycfg`
  (`0x7C9`), which holds the sampling interval, the health-test cutoffs and
  a lock. The custom bits of `seed` are zero.
- **Entropy source.** `flow/fpga/karu_rosc_rng.v` is one sampled inverter
  ring per raw bit, four bits, with the ports of OpenTitan's raw noise
  source and a behavioural model for simulation. `rtl/karu_entropy.v` keeps
  every k-th symbol, runs repetition-count and adaptive-proportion tests
  per lane, and packs four raw symbols into a `seed` word. No bit is
  combined with another anywhere. Words are buffered and released four at
  a time. **No entropy figure has been established** (first raw captures on
  the board 2026-11-18, above); the reset parameters are
  provisional.
- **Tests.** `make entropy-test` (3,740 checks; 33 one-mechanism mutants
  caught by the bench alone), `make zkr-test` (the access table with and
  without H, the value format, the custom CSRs, the platform strap; two
  controls; 14 access-rule mutants), `make zkr-test-spike` (Spike agrees on
  the access table). The first two are in `make dbg-test`, as are the
  later `zkr-loop-test`, `sv39-auth-pma-test`, `dbg-getnoise-test` and
  `dbg-board-auth-rehearsal-test` below.
- **Boot ROM 2 MiB.** `KARU_BOOT_ROM_PAGES` in the new `rtl/karu_bootmap.vh`
  is shared by the access permissions, the boot memory and the bus decode.
  The scratch SRAM moved to `0x201000`. The layout leaves core
  `0x1_0000..0x2_3fff` empty for the authentication island and the page at
  `0x12_0000` empty for the Debug Module, with OpenSBI at ROM offset
  `0x30000`, U-Boot at `0x120000` and the DTB at `0x1FC000`. The Debug
  Module's page stays outside the ROM in the access permissions: the first
  version of this change let ordinary accesses reach it, which
  `dbg-core-test` and `dbg-core-full-four-state-test` caught.
- **Debug authentication in the VCU118 debug image.** `KARU_DBG_AUTH` and
  `KARU_ZKR` join `KARU_DBG_FULL` in `VCU118_DBG_EXT_DEFINES`. The hart
  starts in the island ROM, built from `test/dbg/auth_rom` to read its
  nonce from `seed`, and continues in fu-boot. The ROM still verifies with
  the non-cryptographic `TEST` algorithm (decision D3 is open).
- **Straps.** DIP switch SW12: positions 1 and 2 the debug lifecycle,
  3 the boot hold, 4 entropy source off. All off behaves as an image
  without these features.
- **Device tree.** karudeb gains the `rva23s64-zkr-ddr` variant; the plain
  `rva23s64-ddr` tree is unchanged. The image build refuses a tree whose
  `zkr` does not match `KARU_ZKR`.
- `make image-boot-test`: the composition in simulation, from the island
  ROM through fu-boot and OpenSBI v1.9 to an S-mode payload that reads
  `seed` as Linux does and reboots; with lifecycle `OPEN` and `AUTH`, with
  the entropy strap low, and a control with the tree without `zkr`. All
  four runs behave as intended: OpenSBI lists `zkr`, four `seed` words
  arrive within 100 polls on both boots, and with the strap low `seed`
  stays in `BIST` while the boot and the reboot go on.
- **Ring placement.** `flow/fpga/rosc_constraints.tcl` places every ring
  stage by hand and keeps everything else out of the rings' slices. Two
  defects were found on the way, both by its own checks: synthesis folded
  upstream logic into a ring's enable gate (the noise source now registers
  its enable locally), and region constraints alone let the placer pack
  three rings into one slice. Checked on an out-of-context place and route
  of the entropy source: 486 LUTs, 362 flip-flops, no block RAM.
- `dbg-auth-window-seed-test`: the authentication window bench again with
  the nonce read from `seed` (108 checks; every nonce word from `seed`,
  none from `mdbgrng`).
- **Board tooling.** `test/dbg/board/getnoise_capture.py` and
  `getnoise_analyze.py` (raw capture through `mnoise` and its offline
  analysis, `make dbg-getnoise-test`, 104 checks), and `linux_zkr.py`
  (Linux lists `zkr`). None has run on a board.
- The board top elaborates in Vivado with the image's define list.
- **Review follow-ups, same day.**
  - The island SRAM (`0x2_0000..0x2_3fff`) was executable in the access
    permissions, because it lies inside the ROM's span; that was already
    so with the 1 MiB ROM. The island refuses instruction fetches from it,
    but `HLVX` asks for execute permission and reads through the data
    port. It is now data only. `make sv39-auth-pma-test` checks the island
    and the Debug Module's page through the address translator; its
    control is caught by the `HLVX` case.
  - An image with authentication and without `KARU_ZKR` got a ROM that
    read `seed`, which would trap with no trap vector once a debugger sent
    a request. The ROM's nonce source now follows the image, and the ROM is
    rebuilt when its flags change.
  - GetNoise works on a source that has gone `DEAD`: test mode switches
    the rings back on, and `seed` keeps reporting `DEAD`.
  - The board harness takes the scratch SRAM address and the reset vector
    from the kind of image under test (`KARU_BOARD_IMAGE`: `rom2m-auth`,
    `rom2m`, `rom1m`), builds the fixture for it, and refuses a fixture
    linked for another map. Before this, the fixture and several phases
    pointed into what is ROM in the new map, and the reset-halt checks
    expected `0x1000`.
  - `test/dbg/board/auth_phase.py` with `authlib.py`: the authentication
    exchange on the board through OpenOCD, one case per switch setting,
    rehearsed on the simulated target with the real window ROM
    (`make dbg-board-auth-rehearsal-test`, in the gate).
  - `getnoise_analyze.py` could pass a per-lane threshold that the lane's
    measured bias makes impossible. Its verdicts now use the lower end of
    the smallest of the bias cap, a predictor cap and a duty-cycle-aware
    model figure, and are refused when the model does not fit.
  - U-Boot's Zkr random-number driver is explicitly off; the `zkr` device
    tree is staged with `random.trust_cpu=off`.
  - `dbg/BOARD_TEST_PLAN.md`: the order of work for the first board
    session with this image, the boot files to pair with it, and what to
    do when a stage fails.
- **Combinational loop between the CSR file and the entropy block,
  2026-11-18.** The first build of this image routed with timing met and
  was then refused at `write_bitstream` (DRC LUTLP-1). The value read from
  `seed` depended on "no restart in this cycle", a restart depends on the
  value being written to `mentropycfg` or `mnoise`, and a CSR set or clear
  instruction computes the written value from the read one. The two
  halves are never active together (they belong to different CSR
  addresses), so no simulation noticed, and the out-of-context run of the
  entropy source alone could not contain it.
  - `rtl/karu_entropy.v`: a restart no longer gates delivery. Nothing the
    block lets the core read depends on the write strobes, the written
    value or the acknowledge. A health failure still wins over a read in
    the same cycle.
  - `make zkr-loop-test` (in the gate): Yosys looks for logic loops in
    `karu_csr` with `karu_entropy` connected as in the SoC, and in
    `karu_entropy` with every output fed back into its write-side inputs.
    The control restores the old term, and both must report a loop.
  - `flow/fpga/xcvu9p-ddr-synth.tcl` runs the LUTLP-1 check right after
    synthesis and stops there, instead of two hours later. The ring
    oscillators are allowed loops and are not among its violations. The
    refused build's synthesised netlist is the control: one violation.
- **Image and measurements, 2026-11-18.**
  - The rebuilt debug image `d7ff00dc…3e80` meets timing at 75 MHz (setup
    +0.051 ns, hold +0.011 ns). Read back from the routed design: no loop
    but the four rings, the sampling paths cut from timing, the switches
    on the intended pins. It passed the board session of 2026-11-18.
  - The NanGate45 area rows and the 200 MHz OpenSTA rows were mapped again,
    with first rows for `KARU_ZKR`
    ([measurements](dbg/MEASUREMENTS.md#mapped-area-and-200-mhz-timing--2026-11-18)).
    Areas moved by about 0.1 kGE; the entropy block is about 5 kGE;
    register-to-register timing is unchanged. Two CSR strobe outputs,
    `trng_ack_o` and `zkr_fire_o`, miss the generic output budget in the
    debug tops by 0.19 to 0.29 ns. That is recorded as an ASIC integration
    obligation; no RTL was changed for it.
  - Documentation sweep: the FPGA guide's build recipe and ROM figures for
    the `zkr` variant, status lines in the authentication plan and the
    debug README, missing test rows, and karudeb's README. karudeb's
    `karu64-rva23s64-check` also prints the `zkr` tree's hash.

### Built — VCU118 debug image, 2026-11-17

- `make vcu118-ddr-sgmii-rom-rva23s64-dbg` from an empty `_build`, at karu64
  commit `d58aa6f` and karudeb commit `8dfc019`: bitstream SHA-256
  `d5e603cdf92cb22474e9ac073de33ebf2d5ac16d6f5d22ac38b2b4ec8dffd9b2`.
  It contains the UART receive fixes, the software reboot, and OpenSBI v1.9
  with the reboot device-tree nodes in its ROM.
- Timing is met at 75 MHz with little margin: setup +0.003 ns, hold
  +0.002 ns, no failing paths; `cpu_clk` has +0.113 ns. DRC reports no
  errors. See [measurements](dbg/MEASUREMENTS.md#fpga-image--2026-11-17).
- Not programmed and not tested on a board.

### Added — software reboot of the VCU118 SoC

- A system-control register at `0x1000_0800` (upper half of the UART's
  page): a privileged 32-bit write of `0x7777` resets the hart, the
  peripherals and both sides of the DDR AXI path, and the boot ROM runs
  again. DDR calibration, DRAM contents and the debug module survive.
  Writes of another value, width or register and U-mode writes are ignored.
- The request joins the reset sequencer used for `ndmreset`
  (`dbg/karudbg_fpga_reset.v`) through a new pulse stretcher
  (`flow/fpga/karu_soft_reset.v`, 256 CPU cycles). Only the debug-enabled
  image implements the reset; other VCU118 images ignore the request.
- The UART now decodes only the lower half of its page. Its registers used
  to repeat through all 4 KiB.
- Software uses it through OpenSBI's generic `syscon-reboot` driver. The
  `syscon` and `reboot` device-tree nodes and the move to OpenSBI v1.9 are
  in karudeb; the profile DTB changes, so the boot ROM changes with it.
- Tests: `make ddr-reboot-test` (firmware boots twice on the DDR simulation
  top; seven decode mutants), `dbg-fpga-reset-test` (sequencer with two
  mutants, single-flop check of the held reset, and a structural check of
  the board top's reset wiring), and `make sbi-reboot-test` (fu-boot ROM,
  OpenSBI v1.9 and an S-mode payload rebooting through SBI system reset, in
  simulation; not part of the hashed gate because it uses karudeb's
  binaries). `test/dbg/board/linux_reboot.py` is the board check. It
  requires a Linux restart and, on the UART capture, the boot ROM and
  OpenSBI banners in between; a restart alone would also follow a kexec.
- In karudeb, the OpenSBI build now refuses a source at a different
  version than requested, including worktree and submodule checkouts, and a
  source without Git metadata unless that is asked for explicitly. Its own
  clone is recognised by resolved location, so a relative `SRC_DIR` no
  longer blocks the upgrade from v1.8.1. `make karu-opensbi-check` there
  tests the rules offline.
- The functional gate's input record now also covers C sources, the HTIF
  firmware directory and its linker script; they were built by gated tests
  but not hashed.
- The debug image `d5e603cd…fd9b2` built on 2026-11-17 contains it and was
  never programmed. The 2026-11-18 image `d7ff00dc…3e80` contains it too,
  and on the board eight reboots went back through the boot ROM and
  OpenSBI.

### Changed — board acceptance harness and claims (review of 2026-11-17)

- The physical-board drivers, fixture source and OpenOCD configurations of
  the November 16 campaign existed only under the ignored `_build` tree. They
  are now in [test/dbg/board/](test/dbg/board/README.md). Host paths, the
  board address, ports and the adapter come from the environment, with the
  lab values as defaults. The changed scripts ran on the board on
  2026-11-18.
- Every phase script now exits non-zero if any of its cases, a restore step
  between cases or its cleanup failed. Before, a failed case was recorded
  but most scripts exited 0, and the transport phase discarded restore
  errors.
- The board autoexec case now counts executions with a Program Buffer
  increment: one per read and per write of the selected register, none for
  reads or writes of the other nine registers, none for either once the bit
  is cleared. The campaign's
  version re-read an unchanged register and passes on a target whose DATA1
  and Program Buffer triggers are dead.
- New targets, both in `make dbg-test`: `dbg-board-harness-test` (offline
  self-test of the harness and its exit status) and
  `dbg-board-rehearsal-test` (the autoexec case through the same harness and
  a real OpenOCD on the simulated full-debug target; it must fail for three
  injected autoexec defects). `uart-rx-test` joins `make dbg-test` too.
- The Linux phases no longer name a kernel version. The expected release
  and the live-kernel breakpoint address come from the kernel build tree of
  the served Image, so the harness follows karudeb's move to Linux 7.4-rc3.
- [dbg/BOARD_ACCEPTANCE.md](dbg/BOARD_ACCEPTANCE.md) narrows two claims of
  the November 16 campaign: it did not establish that the ten autoexec
  triggers execute, and its SRAM code-patch case does not isolate
  invalidation of prefetched instructions. No debug RTL changed.

### Fixed — HTIF firmware link layout

- `flow/spike.ld` placed `.bss` before the `.tohost` page pinned at
  `0x80001000`. `irq_test` had grown past it and no longer linked, so
  `make irq-test ddr-irq-test` could not run. `.bss` now follows `.tohost`,
  and an assertion reports text or data reaching the pinned page. Both
  interrupt tests pass again, including UART receive through both bus
  wrappers.
- The comment in `test/fw/ns16550.c` said an SCR write consumes a received
  byte; the RBR read does. No code changed.

### Fixed — FPGA UART receive path

- **Byte read twice.** `flow/fpga/uart_rx.v` honoured the "byte was read"
  pulse only in cycles where its bit timer was non-zero. A pulse on a bit-FSM
  step was lost, the byte stayed ready, and the reader took it twice: at
  75 MHz about one read in 41 with an idle line. This is the likely cause of
  the duplicated console characters seen under Linux in the November 16
  board campaign; that link is shown in simulation. On the board on
  2026-11-18, with the fix, the console showed no duplicated characters.
  The pulse now clears the ready flag in any cycle, and a byte whose stop
  bit completes in the same cycle stays ready.
- **Byte lost.** `flow/fpga/karu_ns16550.v` popped the receiver one cycle
  after the accepted RBR read. If the next byte completed on the read edge,
  the reader got the old byte and the late pop cleared the new byte's ready
  flag: the new byte was lost. The pop is now on the edge of the accepted
  read, the same edge on which the bus snapshots the data, so the byte
  popped is the byte returned and a byte completing on that edge stays
  ready. This race was found in review on 2026-11-17; it predates the fix
  above and has not been observed on the board.
- Both modules have a simulation-only local assertion. `make uart-rx-test`
  runs two benches. `test/tb_uart_rx.sv` covers every byte value, a read on
  each kind of FSM step, the stop-bit race, overrun and a random reader
  model. `test/tb_ns16550_loop.sv` drives `karu_ns16550` with its real
  serializers in loopback and reads as an 8250 driver does: 700 bytes each
  come back exactly once, and an RBR read placed just before, on and just
  after the completion edge of the next byte behaves as specified. Two
  mutants, one per defect, must fail. The serializers were previously not
  simulated: `SIM_TB` replaces them with file and console models.
- [doc/fpga.md](doc/fpga.md) said that an SCR write consumes a received
  byte; the RBR read does.
- The VCU118 debug image `0b994847…78b22` predates these fixes. The image
  `d5e603cd…fd9b2` built on 2026-11-17 includes them and was never
  programmed; `d7ff00dc…3e80`, which also includes them, ran on the board on
  2026-11-18.

### Tested — physical VCU118 debug acceptance

- Physical OpenOCD/GDB acceptance covers register state, stepping, triggers,
  vector restart, Program Buffer, SBA/coherence, transport recovery and a
  ten-minute mixed-execution soak on debug image `0b994847…78b22`.
  The new pristine OpenOCD still mishandles invalid superpages and Svnapot in
  software walks, and normal firmware boot needs EBREAK-policy cleanup at
  detach. See [board acceptance](dbg/BOARD_ACCEPTANCE.md) for results, evidence
  and remaining scope.

### Fixed — VCU118 OpenOCD outer TAP configuration

- Use the XCVU9P's 18-bit instruction register and USER4 opcode `0x23924`.
  Physical OpenOCD discovery, halt, PC/DCSR reads and resume now pass on the
  debug image; Linux remains responsive after detach. See the
  [board smoke test](dbg/README.md#board-transport-smoke-test--2026-11-16).

### Added — debug authentication RTL (`KARU_DBG_AUTH`, plan milestone A1)

- An opt-in, lifecycle-gated debug authentication scheme, implementing
  [doc/debug-auth-contract.md](doc/debug-auth-contract.md). Builds without
  `KARU_DBG_AUTH` are unchanged.
  - `karudbg_auth` holds the POR-domain grant, boot hold, `authdata`
    mailbox, revocation (firmware or debugger `fw_lock`, or the platform
    `revoke_i`) and relock reset.
  - `karudbg_island` serves the island ROM and SRAM on the core's own ports.
  - The DM shows the Debug 1.0 locked register view and gates its outputs
    with a registered enable. `ndmreset_o` clears on the enable's falling
    edge.
  - The core gates every Debug Mode entry source and adds the authentication
    CSRs `0x7C0–0x7C3` and `0xFC0`, with Zkr-style pop semantics.
- A session reset after the ROM has consumed a response word closes the
  authentication window in hardware, so a host cannot defeat the one-attempt
  rule by repeated `ABORT`s.
- A hart or system reset after boot closes the window, and a CSR access in a
  reset cycle has no effect.
- The island forwards an external response only for an outstanding external
  transaction accepted in an earlier cycle, so the fabric cannot forge an
  island load. Hostile-response tests cover it, including backpressure,
  reset with transactions outstanding, and pipelined address acceptance.
- `karudbg_core`'s debug-page router applies the same rule in every debug
  build. A hostile fabric can no longer complete a debug-page load or fetch
  at the transition from external traffic. `dbg-run-control-test` now forges
  both cases and keeps the pre-fix router as a mutant.
- With `lc=OPEN` the DM is proven sequentially equivalent to the
  unauthenticated DM, and the full real-core debug bench runs cycle-identical.
  An authentication build still decodes the island addresses in every
  lifecycle, so this is not equivalence for programs that use them.
- New invariants INV42a/b. New gate targets in `dbg-auth-test` with mutant
  controls. The non-board gate bound is now 2,700 s.
- A2 simulation island ROM (`test/dbg/auth_rom/`) implementing the contract's
  frame protocol with the simulation-only `TEST` algorithm, tested on the real
  core (`dbg-auth-window-test`).
- Pristine OpenOCD authentication and rejection flows (`dbg-auth-openocd-test`).
- Formal lemmas C2 and C4–C10 (`dbg-auth-formal-test`), module level; C1, C3
  and the composition are open. C8 hardened the core: a CSR access in a trap
  or Debug-entry cycle has no authentication effect.
- 2026-11-16 review corrections:
  - the simulation ROM could grant after its deadline (an available RX word
    skipped the expiry check; no check before the grant; ABORT restarts
    before the time check). Fixed, with `dbg-auth-rom-host-test` and
    deadline-boundary cases in `dbg-auth-window-test`;
  - C5 now proves window closing, `REQUEST` and hold;
  - C9 no longer assumes single-beat requests, and new lemma C10 proves its
    remaining assumption on the core;
  - C6 checks reset values, polarity and reset nets, not only names, with
    negative controls; C4 proves `debug_mode=0` after reset.
- Milestone status: A1 and A6 done; A2 (simulation ROM only), A3 and A4
  partial.
- Yosys area (NanGate45), in [measurements](dbg/MEASUREMENTS.md):
  - full debug: +35.5 kGE (+0.81 %) over no debug;
  - authentication logic: an estimated 21.9 kGE more (partly from a
    reduced-memory probe, no ASIC memory macros), plus 64 KB ROM and 16 KB
    SRAM macros.

### Fixed — 2026-11-15 security review findings S7–S13

Findings are in [the review](doc/security-review-2026-11-15.md). S6 (debug
authentication) remains open; see the [plan](doc/debug-auth-plan.md).

- **S7:** in `KARU_NO_MEM` builds, `karu_lsu` accepts AW and W independently,
  in either order, in every write state. Before, a subordinate that accepted
  them in different cycles lost B responses and repeated stores.
- **S8:** `dmactive=0` during a busy abstract command is acknowledged only
  once the command engine is idle. An acknowledged deactivation therefore
  always leaves reset values, and the hart's borrowed `a0`/`s0` are restored.
  `dmactive=1, ndmreset=1` recovers a hung Program Buffer.
- **S9:** the USER4 tunnel pulses the inner DTM TRST after a truncated frame,
  so the nested TAP resynchronises without an outer Test-Logic-Reset.
  Recovery adds no extra or corrupted DMI request. A write the truncated
  frame had already committed remains valid.
- **S10:** `ndmreset_o` is a single flop. The combinational AND with
  `dmactive` no longer feeds the reset synchronizers.
- **S11:** a single-stepped WFI keeps its illegal- and virtual-instruction
  traps (U, `mstatus.TW`, VS with `hstatus.VTW`, and VU).
- **S12:** only SYSTEM-opcode WRS executes as a Debug-Mode or stepped NOP.
  `fence w,iow` and `fence 0,iow` keep the platform FENCE handshake.
- **S13:** RAM-class SBA requests use aligned 64-bit beats with byte strobes,
  matching the crossbar's DRAM-port contract; device requests keep their exact
  size.
- New invariants:
  - INV41a–c in `karu_debug_assert` check WFI legality, the FENCE handshake
    and WRS-as-NOP;
  - SBAB9 checks the SBA beat form;
  - local checks cover DM deactivation, the tunnel TRST pulse and LSU write
    quiescence.
- New regressions in the non-board gate:
  - with in-target mutant controls: `lsu-aw-w-test`,
    `dbg-bscan-truncate-test`, `dbg-sba-xbar-test` and
    `dbg-ndmreset-flop-test`;
  - positive end-to-end runs, whose failure on pre-fix RTL was shown
    separately: `nomem-aw-w-isa-test` and `dbg-run-control-test`.

  `dbg-unit-test` (with an S8 mutant), `dbg-core-test` and
  `dbg-trigger-invariant-test` (INV41 controls) also gain cases.
- `htif_tb` gains opt-in `+ddr_w_lag=N` and `+ddr_aw_lag=N`, which accept AW
  and W in different cycles. Default behaviour is unchanged.
- The combined non-board gate passes with 281 unchanged inputs: 309.69 s on
  reused models, 1,694.84 s with full rebuilds.
  Area, timing and the VCU118 debug image were remeasured on 2026-11-15; see
  [measurements](dbg/MEASUREMENTS.md). The routed 75 MHz image meets timing at
  +0.008 ns.

### Fixed — registered SBA issue hold

- Register the SBA pause and require it before accepting a RAM write. This
  cuts the reset-to-trigger/issue path introduced by fetch-fault pause
  qualification, while preserving reset suppression of bus requests and
  draining work admitted on the hold's assertion edge. Directed tests and
  negative controls cover registered timing, cancellation and early acceptance.
  The combined gate passes with 274 unchanged inputs, including 13 invariant
  corruption controls and 17 transport/backend controls.
  Fresh full two-trigger OpenSTA input-to-register slack is +0.2328 ns,
  replacing −0.1739 ns with unchanged constraints. Register WNS remains
  −0.3978 ns on the IFU/decode-to-double-FMA path; 200 MHz is still open.
  The October 29 FPGA programming bundle is unchanged; the full two-trigger
  200 MHz timing follow-up is recorded in [measurements](dbg/MEASUREMENTS.md).

### Added — karudbg autoexec, address triggers and System Bus Access

- Core trigger-entry and maintenance invariants, plus SBA ownership/handshake
  scoreboards, are exercised by deliberately corrupted controls. Static
  `SBA_ENABLE=0` now hides SBA discovery as well as denying bus traffic.
  Executable scratch writes synchronize fetch, and coherent writes wait for
  the platform cache-maintenance acknowledgement. Watchpoint arming respects
  vector load/store direction; fetch-fault triggers wait through SBA pauses.
- Independent `KARU_DBG_AUTOEXEC`, `KARU_DBG_TRIGGERS` and `KARU_DBG_SBA`
  switches extend the base DM; `KARU_DBG_FULL` selects all three. Autoexec
  supports both data registers and all eight Program Buffer words.
- Two debugger-owned `mcontrol6` address triggers (four optionally) support
  before-access breakpoints/watchpoints, including vector element restart.
  Native M-mode breakpoint actions, chains and data-value matching are deferred.
- SBA provides native 8/16/32/64-bit physical RAM and MMIO access. RAM writes
  drain older core accesses, clear LR/SC reservations, invalidate both caches
  and restart fetch before completion, including while the application runs.
  The private debug page remains accessible only through the core's ports.
- The standard 75 MHz debug FPGA target selects the combined extensions;
  `VCU118_DBG_EXT_DEFINES=` reproduces the base configuration. Current extension
  validation and pending gates are tracked in [dbg/README.md](dbg/README.md).
- Autoexec caches every accepted explicit command, including unsupported or
  not-ready commands, while ignoring command writes during busy/sticky error.
  The 958-check DM regression and counted-MMIO OpenOCD test prevent stale
  command replay; baseline DM coverage remains 947 checks.
- Register each 64-bit vector watch address before its trigger comparison,
  adding one cycle per armed field query while preserving the disabled path.
  The full-debug CPU replay passes 2872/2872 preserved ACT4 reference ELFs;
  all 16 ordinary subjects pass with zero idle cycle delta. Focused SBA
  four-state testing passes 30,740 checks and rejects eight coherence/ordering
  mutations, including lost or premature external-cache acknowledgements.
  The review follow-up passes the combined gate with 274 unchanged input hashes.
  Current validation and mapped comparison records are in [dbg/README.md](dbg/README.md) and
  [dbg/MEASUREMENTS.md](dbg/MEASUREMENTS.md). The separate full-extension
  FPGA image passes 75 MHz routed acceptance; board testing remains open.

### Fixed — debug metadata, exceptions and reset timing

- `hartinfo` advertises two scratch CSRs without a data-register memory shadow;
  the former 12-bit address could not describe the private data window.
- Program Buffer exceptions preserve completed `a0`/`s0` writes, including an
  abstract transfer followed by a failing `postexec`. Faults inside generated
  transfer code use a separate ROM entry to restore its temporary GPRs.
- Synchronous reset paths remain timed in the core and debug synthesis flows.
  External-reset exceptions are restricted to TCK asynchronous reset pins.
  Directed tests cover the exception cases and BSCAN resets during scans.
  The historical base-debug checkpoint completed Vivado implementation on 2026-10-27 at
  75 MHz: whole-design setup/hold +0.005/+0.011 ns, CPU setup +0.482 ns,
  16/16 bus-skew constraints met and zero bitstream DRC errors. Board
  acceptance remains pending.

### Added — opt-in karudbg and AXI requester metadata

- `KARU_DBG` enables precise execution-based debug entry, resume and stepping,
  debug CSRs, counter freeze and command-exception containment. The separate
  `dbg/` integration supplies a single-hart Debug 1.0-targeted DM, eight-word
  Program Buffer, generated two-scratch ROM and conventional JTAG DTM. The base
  configuration omits SBA and hardware triggers; optional extensions are above.
  Authentication is outside the current scope. The private debug page is
  accessible only in Debug Mode through the core's ports.
- The optional VCU118 debug target connects the DM through a USER4 nested-TAP
  BSCAN tunnel compatible with mainline OpenOCD. Transport reset release is
  synchronized, and `ndmreset` cancels both sides of the DDR AXI path before
  releasing the hart while leaving the DM alive.
- AXI instruction/data and effective privilege attributes now propagate through
  request producers, caches, queues and the FPGA DDR interconnect. A trusted
  `NONSECURE` parameter selects the static per-hart security domain. External
  privilege enforcement is limited to physically non-cacheable regions; this
  does not add PMP or dynamic security domains.
- Repository tests cover the DM, AXI adapter, CDC/reset, actual-core register
  and execution context, MMIO, OpenOCD and GDB. The pinned OpenOCD compatibility
  patch handles absent autoexec and rejects unsupported software translations
  safely. See [dbg/README.md](dbg/README.md) for commands, scope and acceptance
  status. FPGA board/BSCAN acceptance and a compliance claim remain pending.

### Documented — out-of-range `vstart` policy (issue #5)

- [doc/architecture.md](doc/architecture.md#vector-unit-rvv-10-v) now states
  the existing behavior. `vstart` keeps only `log2(VLEN)` bits. Vector loads
  and stores with a reserved out-of-range `vstart` (≥ `evl` for
  whole-register forms, ≥ VLMAX for the others) complete without trapping,
  write no elements and clear `vstart`, as in Spike and the ACT4 Sail
  configuration (`Vstart_Ignore`). Vector arithmetic still traps on any
  nonzero `vstart`. No RTL change.

### Changed — trial ASIC memory-compiler inventory

- The memory inventory now distinguishes RTL access timing from the trial
  compiler's 1RW/2RW synchronous-read macros. Only the VRF is a direct
  port/timing candidate; 1W1R and 1W2R leaves require a registered-read
  redesign or flop logic. See [flow/asic/README.md](flow/asic/README.md)
  and [memories.md](flow/asic/memories.md).

### Changed — `vkeccak.vi` follows the Zvknhk element-group rules (breaking)

- The instruction now implements the element-group form of the draft Zvknhk
  specification (riscv-pqc `main` at `3c40d18`, "Zvknhk: process multiple
  Keccak element groups per instruction", with its Sail/Spike/QEMU reference
  models; verified against the identical pre-merge tree `15ea9cb`):
  it permutes element groups `vstart/32 .. vl/32-1` (EGS=32, EGW=2048,
  SEW=64) of an ordinary LMUL register group at `vd`. At VLEN=256 an `LMUL=8`
  group is exactly one element group, so `e64,m8,vl=32` runs one permutation
  and an empty range (`vl=0`, or `vstart` a multiple of 32 and `>= vl`) is a
  no-op that completes and zeroes `vstart`. The Keccak datapath, encoding,
  round selection and state-tail behaviour are unchanged.
- New illegal-instruction cases: `LMUL*VLEN < 2048` (any LMUL but 8, even at
  `vl=0`), and `vl` or `vstart` not a multiple of 32. `vstart=32,64,...` no
  longer traps. **Software that issued `vkeccak.vi` at `vl=25` or under
  another LMUL now traps**; it must set `e64,m8,vl=32` for the instruction.
  The normal active sequence (`e64,m8`, `vl=32`, `vstart=0`) also runs on the
  previous fixed-group implementation; the newly legal empty-range cases do
  not behave the same there (it trapped on any nonzero `vstart` and permuted
  at `vl=0`).
- `karu64.v` refuses to elaborate `KARU_KECCAK` unless VLEN=256: the
  sequencer handles one element group per instruction, which is the whole
  `LMUL=8` group only there.
- Invariants: `karu_assert` INV39a..f (issue legality recomputed from the
  CSRs; one Keccak-core start and one group of VRF granule writes per active
  element group, none for an empty range; no write outside the `vd` group;
  `vstart` zero afterwards), `karu_varith` KSQ1..7 on the Keccak sequencer
  states, and `keccak.v` K1..3 on the core handshake.
- `test/fw/keccak_subj.c` is rewritten for the new rules (39 checks: KATs,
  state tail under `vta`, neighbours, six range cases, 24 reserved cases
  with `vstart` preservation) and `make keccak-test-all` requires line-for-line
  agreement with the riscv-pqc reference Spike. Benchmark, sponge,
  guest-context and DIEL firmware now issue the instruction at `vl=32`.
- Cost: the permutation is unchanged (79 / 67 cycles resident); the two `vl`
  switches a resident sponge needs per block add about 7 cycles, giving
  228.88 / 209.56 absorb and 163.75 / 151.56 squeeze cycles per 168 / 136 B
  block. See [doc/keccak-throughput.md](doc/keccak-throughput.md).
- VCU118 profile image built from this change (`99078e3`, Vivado 2026.1,
  `vcu118-ddr-sgmii-rom-rva23s64`, on a host without the board):
  `28085356…abbd7`, routed setup/hold +0.007/+0.011 ns whole-design and
  +0.244/+0.011 ns on `cpu_clk`, 14/14 bus skew, 0 DRC errors, 351,167 LUTs;
  no worst path touches the Keccak core or vector sequencer. The ROM bakes
  the lab netboot command and karudeb `dev-keccak` (`b3b6abf`) DTB
  `d617ba56…bcec9`. **Validated on the board 2026-10-07** with karudeb
  `ccf5463` software in the NFS root: hands-off netboot to the 7.2.6-zvk
  prompt, `board_accept.sh` PASS, OpenSSL 4.0.2 Zvknhk checks 17/17,
  riscv-pqc `xtest` 39/39, ML-KEM/ML-DSA KATs 720/720, encoding conformance
  20/20 (the v0.2 reserved shapes trap). Open item: the resident 24-round
  permutation costs 93.98 cycles, +6.0 over the single-group image. See the
  [release diagnostics](doc/release-diagnostics-2026-09-14.md#board-validation--2026-10-07).

### Added — ROM manifest in the programming bundle

- `flow/rom_manifest.py` reads the packed `_build/vcu118_fuboot.hex` back and
  writes `_build/vcu118_rom_manifest.txt` (bitstream, ROM, OpenSBI, U-Boot and
  DTB hashes, the verbatim baked boot command and the TFTP/NFS endpoints it
  names) plus `_build/vcu118_rom_board.dtb`, the control DTB extracted from
  the ROM. `make vcu118-program-bundle` includes both for ROM images and
  refuses a ROM image newer than the bitstream. The board host serves the
  extracted DTB (`DTB=... make -C ../karudeb karu64-rva23s64-tftp`) so the
  served `board.dtb` matches the ROM by construction; see
  [doc/fpga.md](doc/fpga.md#building-on-one-host-booting-from-another).

### Changed — FP register file is 1W2R (was 1W3R)

- `karu_fregfile` now has two asynchronous read ports, the same shape as the
  integer register file, so a standard two-read compiled register file can
  implement it (the 1W3R macro was the memory-generator blocker). FMA still
  costs no extra cycle: decode reads rs1/rs2 as before, and port B is steered
  to `ex_rs3` while the FMA holds the ID/EX packet and while the FPU runs it,
  a window in which decode cannot accept and no FP writeback can land. The
  FPU's `op3` is the live port-B output; the 64-flop `ex_frs3_v` latch is gone.
- New `karu_assert` group INV38a..l: port-B ownership/steer integrity, no FP
  write in an issue or accept cycle, and a shadow copy of the FP register file
  that checks every FP source operand consumed by the FPU, the vector `.vf`
  path and FP stores against the latest write to that register. A local
  `[FRF-ASSERT]` in `karu_fregfile` rejects writes with an unknown address.
- New `make fma-hazard-test-all`: every f-register producer feeding the rs3 of
  an immediately following FMA, chains, aliasing, malformed NaN boxes and FMAs
  accepted as a busy unit drains, digest-compared with Spike. `flow/asic` inventory and
  `test/tb_asic_mem.sv` updated for the two-port file.
- VCU118 profile image built from this change (`7c2563e`, Vivado 2026.1,
  `vcu118-ddr-sgmii-rom-rva23s64`): `b11d5efb…3b809`, routed setup/hold
  0.000/+0.012 ns whole-design and +0.077/+0.012 ns on `cpu_clk`, 14/14 bus
  skew, 0 DRC errors, 349,701 LUTs; no worst path touches the FP register
  file. Pre-synth gate: H fixtures, preemption and full ACT4 2872/2872. The
  programmed image boots Linux 7.2.6-zvk and passes `board_accept.sh`, including
  memory, cache, crypto and KVM API checks; the FP probe completed. Full
  on-board TestFloat3 remains in progress. See the
  [release diagnostics](doc/release-diagnostics-2026-09-14.md#1w2r-fp-register-file-image--2026-09-24).

### Board validation — 2026-09-22

- The Genus-cleanup VCU118 image `03eeb088` passes Linux 7.2.6-zvk acceptance:
  OpenSSL 92/92 known answers and scalar comparisons (including forced vector
  SM4), both KVM guest tests, 39/39 Keccak vectors, vector ABI and cache checks.
  No regression observed against `c61da577`; detailed results and evidence
  locations are in the [release diagnostics](doc/release-diagnostics-2026-09-14.md).

### Changed — strict declare-before-use, no declaration-assignments (Genus)

- Every `wire x = expr;` in the ASIC manifest plus `karu_clint`/`karu_plic`
  (2,453 statements across 43 files) is now `wire x;` + `assign x = expr;`,
  and the seven remaining use-before-declare cases in `karu64.v` (instance
  port connections and cache/VLSU fault wires read before their declaration)
  have their declarations hoisted. The five sim-only `reg x = 0;` initialisers
  (commit-log and translate_off regions) became `initial` statements. No
  functional change: per-file Yosys RTLIL is identical before and after,
  strict `iverilog -g2001` parses clean in eight configurations, and the
  simulation regressions and Vivado elaboration pass.
- New `flow/asic/lint_decl.py` (declaration-order lint, exit 1 on findings)
  and `flow/asic/fix_decl.py` (the mechanical rewrite); see
  `flow/asic/README.md`, *Coding rules for the Genus front-end*.

## RVA23S64 — 2026-09-10 … 2026-09-15

### Profile implementation and handoff — 2026-09-14 … 2026-09-15

- Correct standard vector-crypto `.vs` execution so all AES round/zero forms
  and SM4 always read element group zero of `vs2` for every destination group.
  Add multi-group `vl=8,m1` and `vl=16,m2` Karu/Spike checks and a reproducible
  `diel-test-ship` target; the 215-case shipping DIEL probe remains clean.
- Consolidate release documentation around the current architecture, profile,
  diagnostics, security and DIEL reviews. Remove superseded bug reports and
  completed implementation plans while retaining maintained test recipes and
  ASIC memory/source manifests.
- Generate the corrected karudeb-compatible RVA23S64 VCU118 ROM bitstream with
  Vivado 2026.1. Routed 75 MHz CPU setup/hold is +0.046/+0.010 ns and
  whole-design worst setup/hold is +0.009/+0.010 ns; all 14 bus-skew
  constraints pass and bitgen DRC reports zero errors. The image passes
  Linux 7.2.4-zvk board acceptance, including memory, crypto, vector ABI and
  KVM API checks. Exact results are in the release diagnostics.
- Reject every reserved high register-supplied `vtype` bit, producing canonical
  `vill=1`, `vl=0` and restoring Linux syscall vector-state discard. Expand
  both I/D-cache eligibility and vector-store posting from 256 MiB to the
  full standard 2 GiB DRAM window. Preserve PBMT/MMIO bypass behavior and
  add directed legality, address-boundary and transport regressions.
- Refresh the post-review Yosys 0.69+24 area matrix and exact-shipping
  OpenSTA 3.1.0 estimate. At 200 MHz the current shipping map reports
  register-to-register WNS −0.2043 ns and TNS −5.13 ns (about 192.1 MHz at
  zero slack); the limiting cone is the existing vector widening/estimate
  datapath rather than the corrected crypto source address. Non-register path
  groups pass, while generic electrical-limit violations remain. The matched
  area rows are 3667.90 kGE for RV64GCV+Zvbb, 3706.47 for Zvkned, 3683.68 for
  Zvksed, 3806.98 for all standard Zvk leaves, 3894.17 with Keccak, and
  4390.60 kGE for the exact shipping composition; every input manifest is
  unchanged across its run.
- Record FPGA execution of the `ebreak_test` and `arch_timer` KVM selftests,
  with image-specific results in the release diagnostics.
- Restrict page-walker line bursts to DRAM; ROM/scratch use exact PTE reads.
  Reject malformed PWC burst termination instead of publishing partial lines.
  Invalidate resident data-cache aliases on NC/IO and explicitly uncached
  CPU stores, including the vector IO sequencer. Add directed regressions.
- Add Shlcofideleg guest overflow delegation with shared `sip/sie` bit 13
  and unshifted VS cause 13; leave AIA injection unimplemented. Make SGEIE
  writable with H and keep its MIDELEG alias policy consistent. Extend CSR
  and guest PMU tests; update the isolated Sail SGEIE consistency patch.
- Restore PLIC gateway assertions with negative controls, assert idle
  scalar/vector request exclusivity, hardwire CLINT MSIP reserved bits to
  zero, and extend HTIF DDR stalls to W/R/B with mid-burst coverage checks.
- Record [FPGA boot procedures](doc/fpga.md#opt-in-rva23s64-boot-selection)
  and [diagnostics](doc/release-diagnostics-2026-09-14.md), keeping earlier
  throughput and timing records explicitly tied to their measured revisions.

### Supervisor foundation — development toward RVA23S64

- Extend Linux checkpoint builds to the vector/profile RTL. Save and restore
  harness time and clock phase, support bounded replay, and verify complete
  replay-state equivalence in the maintained KVM test harness.
- Set the ACT profile timer lead time for its cycle-based CLINT, avoiding an
  early one-shot interrupt race in ZawrsS/U before the initial trap-count read.
  Complete matched-profile reruns pass 2872/2872 unique tests each on minimal
  and shipping models, with post-run reference ELF hash verification and the
  eight local ACT4 harness/generator/UDB patches described in
  [the test instructions](test/act4-karu/README.md#evidence-and-interpretation).
- Preserve `&&`, quotes and backslashes in baked U-Boot netboot commands;
  avoid the v2025.01 config helper's unescaped sed replacement and verify
  the final Kconfig value before compilation.
- Add opt-in `KARU_RVA23S64` composition, binding H/Ssstateen and Sscofpmf
  to the mandatory baseline and rejecting incompatible opt-outs/geometry.
  Add `rva23-sim` and cross-tool `rva23-config-test`. Legacy/default board
  advertisements remain unchanged; the companion profile image advertises
  the opt-in composition explicitly.
- Add explicit `vcu118-ddr-sgmii-rom-rva23s64`, sharing the vector ROM and
  75 MHz flow with profile-specific karudeb DT/netboot inputs. Validate required
  boot-discovery leaves and ROM/staged-TFTP DTB identity before building.
  Companion sources share the existing board and NFS kernel configuration,
  adding H/supervisor discovery and a KVM fragment only in the profile variant.
- Add matched minimal and optional-Smcntrpmf ACT4 profile references: each
  passes the initial 42-test selection and corrected 56-test focused expansion,
  with separate 21/23-case CSR contracts. Extend
  the guest paging fixture to all VS/G PBMT pairs and physical-fault/FF
  prefixes, checked end-to-end by the bus observer on both pipelines. Its
  300-case variant adds all 144 guest CBO type/permission combinations,
  with mandatory exact-block and denied-side-effect observer coverage.
- Add opt-in real CLINT and independent external-input devices to the profile
  HTIF platform, reusing the timer fixture for 27/48 directed cases. Both
  pipelines pass ideal/stalled runs; legacy RAM-only models remain available.
  Bind the profile ACT timer/IRQ macros and non-overlapping linker symbols,
  and describe the exact LR/SC reservation and physical atomic-fault priority.
- Reject misaligned RAM LR/SC/AMOs and all unsupported physical-device
  atomics before any data-bus request, independently of PBMT. Preserve
  aligned NC/IO RAM atomics and ordinary misaligned accesses. Add
  `lsu-atomic-test` (27,708 checks), extend the existing access fixture with
  396 atomic cases, and cross-check its 286 RAM-only cases with Spike.
  Record and test the single-writer platform memory assumptions.
- Add development-only `KARU_H`: H/VS CSR banks, guest entry/returns, M/HS/VS
  trap and injected-interrupt routing, illegal-versus-virtual exception
  priority, dual FP/vector context gates, HLV/HLVX/HSV and HFENCE/HINVAL.
  Add registered VS Bare/Sv39 and G Bare/Sv39x4 translation, including guest
  PTE accesses, precise guest fault metadata, Svade and composed PBMT.
  Bare memory/fence and paged monitors pass 335 and 141 cases respectively
  on both integrated configurations and Spike (53 baseline cases overlap).
  Add a four-entry, context-tagged guest TLB with registered permission/PMA
  completion; cached/uncached walker checks have matching architectural
  signatures. The 187-case virtual-timer monitor passes both cores and an
  isolated pinned Spike correction, with no normative-case exclusions.
  Expand H counter/PMU coverage across M/HS/U/VS/VU modes. Software two-guest
  FP/vector/timer/shared-control switching and the resident-Keccak chained
  known answer pass both pipelines (88/91 cases), including memory stalls.
  Add 15 integrated VS/VU hardware-event cases covering exact counts,
  inhibit masks, MPRV independence and HS overflow delivery. Add eight
  delegated VS/VU instruction-page-fault cases, including second-halfword
  faults, exact VS trap state and repair/retry. Record the
  Ss1p13/Sha audit and maintained isolated Sail/KVM
  test fixtures. Correct ACT4's H capability and HS trap harness; all 40
  selected H-enabled CSR/exception/timer tests pass with the corrected
  reference and no exclusions. A 96-case asynchronous guest FP/vector switch
  now passes both pipelines with actual timer-overlap/retirement/precise-PC
  assertions, ideal and stalled. Full H/Sha/profile and Linux/KVM validation remain
  separate gates. See
  the current architecture and profile documentation.
- Correct the Linux AXI simulation responder for independent AW/W handshakes,
  aligned byte lanes, burst-final B responses, stable MMIO read snapshots and
  one-shot side effects, using the real shared CLINT time source. Maintained
  positive and two mutation controls verify the protocol checks; these are
  responder tests, not an RTL Linux/KVM verdict.
- Complete the scoped Zkt/Zvkt source audit, now superseded by the current
  [DIEL review](doc/diel-review-2026-09-14.md), including
  serial multiplies, permutations and enabled crypto leaves. No required
  instruction has a protected-operand-dependent completion path in the
  audited sources; this is not formal or physical side-channel validation.
- Defer younger fetch faults until older execution and posted stores drain;
  older data faults retain priority. Cancel discarded fetch walks without
  launching further side-effecting PTE reads, while draining already asserted
  AXI requests. Retain exact IFU guest-fault metadata through split fetches.
- Implement **Svade-only** A/D handling in both Sv39 walkers and their TLB
  hit paths. A=0, or a store with D=0, now faults instead of updating the PTE.
  **Behavior change:** software must set A/D and invalidate translations
  before retrying. `menvcfg.ADUE` is read-only zero; optional Svadu hardware
  updates are not implemented. Remove the walker writeback FSM and tie its
  write channels inactive; reject reserved non-leaf U/A/D bits.
- Add non-H Svinval using conservative full TLB/PWC invalidation and the
  existing instruction/memory drain. Keep TVM checks on `SINVAL.VMA`, not on
  the ordering-only fences. Cancel outstanding walks without stale refills.
- Add non-H Sstc in S-enabled builds: 64-bit `stimecmp`, reset-disabled
  `menvcfg.STCE`, and a two-stage unsigned timer comparator. S access requires
  STCE and `mcounteren.TM`; M access is unconditional and U access traps.
  Enabled STIP is hardware-only; disabling STCE restores firmware injection.
  Add `sstc-test`/`sstc-test-spike`, including vector-state preservation and
  `+sstc_irqcheck` proof of pending-during-vector, deferred interrupt delivery.
- Add standard 64 KiB Svnapot leaves using fixed PPN/VPN slices and existing
  4 KiB-subpage TLB entries. Extend the walker and existing MMU firmware for
  subpages, permissions, A/D faults, reserved encodings and invalidation.
- Add non-H Svpbmt support: reset-disabled PBMTE and page attributes
  through scalar/vector memory, fetch and CBO paths. NC/IO bypass caches and
  posted vector stores; IO transfers only active elements. Retain PMA access
  restrictions. Preserve completed within-granule IO load prefixes and exact
  failed-byte addresses on bus errors; initialize Bare second-page PA/type
  independently of stale translated requests. Add integrated bus-observer,
  injected-error and NC/IO resident-state SHAKE tests.
- Treat physical devices as IO when PBMT=0, preserving scalar native access
  widths and vector active-byte semantics. Custom PMA headers now provide
  `karu_pma_io` as well as `karu_pma_ok`. Correct CLINT narrow byte lanes and
  Ethernet read-side effects; implement PLIC claim/complete arbitration and
  atomic claim-data capture under RREADY stalls. Both SoC IRQ tests pass.
- Correct MPRV/MPP effective data privilege, including Bare bypass and shared
  scalar/vector translation. Fetch retains actual execution privilege;
  MRET returning below M and host SRET clear MPRV; VS SRET preserves it.
  Pointer masking uses effective
  privilege, sign-extension for virtual addresses, zero-extension for Bare
  addresses, and MXR suppression; vector masking applies after element-address
  calculation rather than only to the base register.
- Reject unsupported `satp.MODE` writes without changing `satp`; normalize
  CSR WARL fields and implemented delegation/interrupt/counter-enable masks.
  Preserve the separate software
  `mip.SEIP` latch during read-modify-write, route undelegated supervisor
  interrupts to M, and implement writable FIOM with existing strong ordering.
- Correct instruction-fault `tval` and page-boundary demand: a compressed
  instruction need not access the next page, and a split instruction keeps
  its start PC as EPC while reporting the faulting halfword address.
  EBREAK and C.EBREAK report the instruction address in `tval`, with directed
  EPC/address checks for informative breakpoint traps.
- Connect the existing CLINT MSIP register to the core in BRAM and DDR SoCs,
  including the VCU118 top. Keep `mip.MSIP` read-only and extend the existing
  interrupt firmware with MMIO delivery, masking, clear/rearm and CSR
  write-immunity checks; add a responder-level assertion/clear test.
- Mask `vstart` to its VLEN-derived index width and reserve the time/upper
  bits of `mcountinhibit`. Add full-bit CSR read/write/fault-update sweeps.
- Give all Zicbom management operations load-or-store/MXR permissions and
  A-only checks; retain store/D requirements for ZERO. Exclude CBOs from
  ordinary 8-byte cross-page checks, preserving their aligned 64-byte extent.
- Add `csr-test`, `sv39-test`, `ifu-test` and `svinval-decode-test`; extend
  existing MMU, vector-MMU and privilege firmware rather than duplicate it.
  Add the independent `karu64-sv39` ACT4 privileged-1.13 starter configuration.
  The Svpbmt/physical-IO checkpoint passes **97/97** selected supervisor tests
  on default and four Svpbmt tests on shipping, retaining Sstc/Svnapot.
  Scalar MMU (389 cases), vector NC/IO and injected-fault observers pass both
  models; scalar/vector firmware also passes Spike.
  The walker passes 28,506 checks, IFU 126 and I-cache 330. The five CSR rows
  pass 7,045 / 7,045 / 7,052 / 1,280 / 1,280. PLIC passes 49,208 checks;
  Ethernet bridge rows pass 44 cases each. Independent full ACT4 regressions
  also pass **2600/2600 in each configuration** at this physical-IO checkpoint,
  with matching architectural/HTIF verdicts and no error/timeout markers.
  These models predate the subsequent H and precise-fetch-ordering changes.
  The previous Sstc/Svnapot checkpoint passed 93/93 default and five shipping
  feature cases, plus directed timer/MMU firmware on both models and Spike.
  Correct the ACT4 Sm counter-wrap
  generator to avoid a cycles-per-instruction assumption, and update DDR
  protocol assertions for the implemented one/two-beat stores.
  See [the test flows](doc/flows.md#supervisor-regressions).
  These changes are an implementation milestone, **not** full `Ss1p13` or
  RVA23S64 certification; see [the completion roadmap](doc/rva23s64-plan.md).
  The preceding, pre-Sstc/Svnapot supervisor-foundation rerun of all 2600
  existing ACT4 tests passes in both default and shipping arithmetic/pipeline
  configurations: **2600/2600 each**, with no failures, timeouts or missing
  verdicts. Directed/KAT, SoC interrupt,
  lint and runtime-divider checks also pass. The `b9f0145` area/timing
  results below remain the preceding baseline, not measurements of this RTL.
  Broader platform assurance, H/Sha and the full profile audit remain
  outstanding. Default/shipping structural divider audits also pass with
  Yosys 0.69+24 (`d0e71cfb7`); these are not new measured area/timing results.

### Fixed and optimized — vector legality and SHAKE throughput

- Pipeline vector mask summaries (`vcpop.m`, `vfirst.m`, prefix masks) using
  balanced 16-bit partial-count/priority trees and a registered final fold.
  Replace the 128-deep conditional count chain with a nine-bit accumulator;
  add a Spike-checked sweep of every `vl=0..256` and five source/mask patterns.
- Complete the existing lane register boundary: capture mask bits, opcode,
  rounding, predicates and scalar result inputs alongside the operands.
  This removes the SEW-dependent mask-selection bypass into carry arithmetic
  without adding instruction cycles.
- Stage the complete vector-FPU request with `KARU_V_LANE_PIPE`, separating
  operand widening/selection from FPU input normalization. Each lane-FPU
  request gains one fixed dispatch cycle; reciprocal estimates are unchanged.
- Replace the VLSU's linear first/last-active-element priority scan with
  balanced trees. Active ranges, fault preflight and memory cycle counts
  are unchanged.
- Elaboration-gate scalar combinational multiply/divide in serial builds.
  Add `KARU_DIV_AUDIT_ONLY=1` to reject live division/modulo operators in
  release synthesis configurations before technology mapping.
- Full-vector 200 MHz mapped setup at `b9f0145` improves from WNS −7.2097 ns to
  +0.0698 ns with zero TNS; full-ABC mapped area decreases 1.15%.
  Constraint coverage is clean, but electrical-limit violations remain.
  Record the mapping sequence and reproduction command in the
  [synthesis-flow instructions](flow/syn/README.md).
- Complete routed VCU118 vector ROM/SGMII timing at `b9f0145`: 75 MHz core
  setup +0.205 ns, hold +0.011 ns, with zero TNS/THS across all constrained
  clock groups. Bitstream generation completed; no programming or boot test
  was performed. This result predates the supervisor-foundation changes.

- Share integer widening/narrowing SEW/LMUL/alignment/overlap checks across
  base V and Zvbb; enforce masked destination-v0 rules with mask/reduction
  exceptions. Fractional widening no longer drains an empty adjacent register.
- Correct mask-destination exceptions for FP min/max reductions and prefix
  masks; expand the reserved-encoding suite to 71 cases. Add `vwalk-test`,
  `vwalk-test-ship` and `vwalk-test-spike` for vector-length boundary sweeps,
  plus VLSU request-contract and lane-geometry assertions.
- Fetch Keccak state through both VRF read ports, launch demand reads earlier,
  and bound element-local lane walks by vl. Contiguous loads use byte-enabled
  writes; contiguous store snapshots are bounded and pipelined.
- Burst cacheable vector stores, omit empty halves, and buffer a waiting
  granule; drain at instruction boundaries. Update HTIF and FPGA BRAM write
  backends for bursts. Add SHAKE correctness and AXI transport regressions.
- Add `make keccak-bench`: ideal-memory absorb is 221.75/197.75 cycles and
  squeeze is 156.88/144.56 cycles at 168/136 bytes after access-fault fixes. See
  [the throughput report](doc/keccak-throughput.md) for scope and release gates.
- Add `test/keccak-sw/` and `make keccak-compare`: reproducible six-row
  GCC/Clang RV64GC, Zbb and vector-enabled software comparison, pinned portable
  source, generated-fixture checks, full-state/output verification, and Spike
  cross-checks. Document [the measured comparison](doc/keccak-software-comparison.md),
  including the absence of a resident software-RVV permutation in these C builds.
- Regenerate and run the full ACT4 suite on the `b9f0145` baseline with the act4
  branch tip (`80d5633`), Sail 0.13.1 and udb 0.1.16: 2600 PASS / 0 FAIL across
  2600 unique ELFs, including scalar 389/389 (22 Zfa cases) and Zvbb 61/61. All 2549 previous
  cases still pass. Repeat the full set after the timing-pipeline changes:
  2600/2600 in both default and shipping arithmetic/pipeline simulations.
  Bring the DUT config forward (Sail 0.13.1
  schema, `V` declared with `support_level: Full`, Zihpm and Zmmul declared,
  generated `rvtest_config.h`), which also unblocks the nine `Vx64`
  `vmulh*`/`vsmul` tests the old flow could not generate. The initial 2550 tally
  double-counted a test across batches. Enable ACT4's standard M-mode trap
  handler, declare the implemented time CSR and omit absent HTIF timer MMIO;
  all 29 formerly blocked references now generate and pass. Fix vector-FP
  FS=Off rejection and strict source/group/reserved-field checks exposed by
  these cases. Extend the runner guards for the expanded suites.
  The maintained regression recipe is in [test/act4-karu/README.md](test/act4-karu/README.md).
- Extend vector legality to FP widening/narrowing, extension/gather source
  geometry, permute overlap, mixed-EEW sources and vector-memory groups/fields.
  Correct the earlier masked-source-v0 interpretation: mask EEW=1 conflicts
  with wider element data, even where Spike permits the reserved encoding.
  Include vector-FP in FS dirty tracking; the 25-case FS/VS suite checks
  rejected-operation side effects and enabled flag/scalar-register writes.
- Register the intermediate integer in Zfa `fround`/`froundnx`, breaking the
  composed converter timing path at the cost of one extra dispatcher cycle.
  Expand Zfa edge coverage and add `zfa-test-all` with an enforced Spike
  result/flags digest comparison. Suppress `fcvtmod.w.d` NX when NV is raised;
  the expanded overflow-with-fraction cases exposed this pre-existing flag bug.
  Enable the ACT4 ZfaF/ZfaD slices in the maintained DUT/reference configuration.
- Fix `vfmv.s.f` group writes, XLEN-wide slide offsets, and e64 `vsmul`
  saturation in both combinational and serial multipliers. All 106 prior
  ACT4 failures now pass.
- Add physical access checks and AXI-error propagation through caches, LSU,
  page-table walkers and fetch. Preserve fault-only-first trimming; report
  vector bus faults with VA/vstart. Keep posted stores active until their final
  response and cancel queued suffixes on error. HTIF/BRAM models reject RAM
  aliases outside their windows; the DDR crossbar preserves error responses.
  Add `access-test` and extend the shared AXI responder regression.
- Make the riscv-tests runner fail on missing sources, an empty test selection
  or a failed build; an unpopulated submodule previously returned a false
  successful zero-test summary.
- Consolidate shared privilege-test linker scripts and SHAKE known-answer
  data; remove the duplicate synthesis setup template. ACT4 uses the caller's
  tool environment instead of a hardwired home-directory installation.

### Changed — `vkeccak` now implements the Zvknhk specification (breaking)

- The Keccak instruction follows the draft **Zvknhk** Vector Keccak extension
  of the RISC-V PQC TG, [riscv/riscv-pqc](https://github.com/riscv/riscv-pqc)
  `src/zvknhk.adoc` (commit `260e14b`), and is binary-compatible with that
  repository's Spike and QEMU reference models:
  `vkeccak.vi vd, imm5` = `.insn r 0x77, 0x2, 0x53, vd, x18, imm5`
  (MATCH `0xa6092077`, MASK `0xfe0ff07f`). `imm5=0` runs Keccak-p[1600,24]
  (SHA-3/SHAKE), `imm5=1` runs Keccak-p[1600,12] with round constants
  RC[12..23] (TurboSHAKE/KangarooTwelve); all other values are reserved.
- Operand semantics per the spec: one fixed 2048-bit element group at `vd`
  (`NREG = ceil(2048/VLEN)` registers, 8 at VLEN=256), independent of `vl`
  (including `vl=0`) and LMUL; elements 25..31 (the state tail) and all other
  registers are untouched.
- Reserved encodings raise an illegal-instruction trap at issue with no side
  effects: `SEW≠64`, `imm5>1`, `vm=0`, `vd` not NREG-aligned, `vstart≠0`.
- **Breaking:** the previous keccak-xrv form (`.insn r 0x77,0x2,0x53,vd,x17,x24`,
  fixed 24 rounds) is no longer decoded and traps. Software must use the new
  encoding; `../karudeb` was updated in step.
  (`rtl/karu_dec.v`, `rtl/zvk/keccak.v`, `rtl/karu_varith.v`, `rtl/karu64.v`)

### Added

- Full RVA23U64-mandatory **Zvbb**. The existing Zvkb lane operations are
  joined by `vbrev.v`, `vclz.v`, `vctz.v`, `vcpop.v`, and
  `vwsll.{vv,vx,vi}`. Unary counts use bounded byte leaves and balanced trees;
  `vwsll` reuses the staged base-V widening engine. Normal V builds enable
  Zvbb; `KARU_NO_ZVBB` is the synthesis-isolation opt-out.
- `make zvbb-test-all`: one self-checking ELF on Karu and Spike, covering all
  unary SEWs (including exhaustive e8 inputs), mask/tail preservation, all
  widening-shift forms, fractional LMUL with an adjacent-register canary,
  LMUL=2→4 and maximum LMUL=4→8 traversal, legal overlap, and reserved
  widening encodings.
- `make keccak-kat`: standalone `keccak.v` known-answer test with the spec's
  KECCAK-P (24-round) and KECCAK-P12 (12-round) vectors (`test/zvk/tb_keccak_kat.sv`).
- `make keccak-test` / `make keccak-test-zvk`: full-core `vkeccak.vi` test on
  the `KARU_KECCAK` and the shipping `KARU_ZVK KARU_KECCAK` builds — spec KATs,
  two dependent ops back to back, fixed-group / state-tail / `vl` / LMUL rules,
  and 11 reserved-encoding trap cases with a no-side-effect check
  (`test/fw/keccak_subj.c`). The decode bench covers the new encoding and the
  trapping of the old word.
- `CHANGELOG.md` (this file).

### Fixed

- `rtl/karu_varith.v`: the `vfslide1up/down` source index used `/ epr` and
  `% epr` with a runtime divisor, which synthesised a 32-bit divider; now a
  shift and mask (`epr` is a power of two). No functional change
  (`make vfp-test` 46/46; Vivado elaboration clean).
- Makefile: the `Vhtif_kec` / `Vhtif_zvk_kec` Verilator rules did not create
  their output directories and failed in a clean checkout.
- Correct `flow/syn` (Yosys + OpenSTA estimate flow) failures:
  liberty lookup only searched inside the checkout; OpenSTA 2.4 rejected
  `-group_path_count` so every timing report was empty; `KARU_LTP=1` ran `ltp`
  on the mapped netlist and produced a multi-GB false-loop report; the fast
  ABC script skips buffering/sizing so STA slack was meaningless (thousands of
  ns on one unbuffered inverter). Timing runs now use the full ABC script, the
  depth report runs pre-map with the top/cache modules excluded, and the
  scripts adapt to the OpenSTA version. Re-measured RV64GC core-only numbers
  are in `flow/syn/README.md` (398 kGE, ~6.7 ns critical path through the Zfa
  `fround.d` compose in NanGate45 typical).

### Documentation

- `README.md`, `doc/architecture.md`, `doc/flows.md`, `rtl/zvk/README.md`:
  Zvknhk encoding/semantics, the spec location and commit, the new test
  targets; "custom/experimental Keccak" wording removed.
- `flow/syn/README.md`: flow status, corrected tunables, re-measured timing
  and the note that RV64GCV rows need a ≥64 GB host.

### Hardware status

- VCU118 vec ROM bitstream rebuilt from `48e4d86` with Vivado 2026.1
  (`ddr_vec_sgmii_75_rom`, WNS +0.045 ns at 75 MHz, DRC clean; ROM = fu-boot +
  OpenSBI v1.8.1 + U-Boot 2025.01 + zvk-ddr DTB), programmed and booted to a
  Debian NFS-root shell on the lab board (2026-09-11).
- That image requires CPU_RESET or reprogramming for restart. Its warm-reset
  TFTP failure handling is superseded by the current ROM's bounded retries
  and `&&` success guards.

## [main @ `8da799a`] — 2026-06-21 … 2026-06-29

Initial public tree (`73b4906 init`, 2026-06-21) and June follow-ups:

- RV64GCV core (RV64IMAFDCV + Zicsr/Zifencei, RVV 1.0, Zvl256b), M/S/U with
  Sv39, CLINT/PLIC/NS16550; `make test` 110/110; generated RV64GCV ACT4
  2220 PASS / 0 FAIL.
- Zvk vector crypto (Zvkned, Zvknha/b, Zvksed, Zvksh, Zvkg, Zvkb) behind
  `KARU_ZVK*`; Keccak-f[1600] permutation instruction behind `KARU_KECCAK`
  (pre-Zvknhk keccak-xrv encoding, replaced above).
- VCU118 SoC: BRAM and DDR4 (MIG) variants, LiteEth SGMII netboot, hands-off
  boot ROM (fu-boot + OpenSBI + U-Boot + DTB); Debian NFS-root Linux with
  kernel 7.1.2 boots from the bitstream built with Vivado 2026.1.
- Verilog-2001 audit for Genus/Vivado, explicit memory leaf modules, Yosys /
  OpenSTA NanGate45 estimate flow and area matrix, Marian-derived Zvk leaf
  cores with KATs.
