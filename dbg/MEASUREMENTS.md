# karudbg measurements

## Mapped area and 200 MHz timing — 2026-11-18

A refresh of the November 15 rows, and the first rows with `KARU_ZKR`. Every
row below is a fresh mapping of the tree that the
[November 18 FPGA image](#fpga-image--2026-11-18) was built from, with
identical input fingerprints before and after, in new roots
(`_build/syn_out/karudbg-2026-11-18/` and `…-2026-11-18-zkr/`). Flow,
Liberty, tools and the shipping processor configuration are those of the
November 15 rows; the November 15 evidence directory itself no longer
exists, because `_build` was emptied on November 17.

**Why a refresh.** Since November 15 the mapped source changed in three
places, none of them large:
- the boot map in the physical access permissions (`rtl/karu_pma.vh`: the
  ROM is 2 MiB, and the Debug Module's page is excluded from it), in every
  configuration;
- the same constants in the System Bus Access classification
  (`dbg/karudbg_bus.v`), in the debug rows;
- in the authentication row, the island SRAM excluded from the ROM
  predicate, and one gating change in `karudbg_auth` from November 16: a
  CSR access in a trap or Debug-entry cycle has no effect.

**Area** (fast area mapping; 1 kGE = 798 µm²; memories mapped to cells):

| Configuration | Top | Area µm² | Area kGE | Increment over no debug | Change since Nov 15 |
| --- | --- | ---: | ---: | ---: | ---: |
| No debug | `karu64` | 3,500,029 | 4,386.002 | — | +0.126 kGE |
| Base debug | `karudbg_top` | 3,516,670 | 4,406.854 | +20.852 kGE (+0.48 %) | +0.058 kGE |
| Full debug | `karudbg_top` | 3,528,394 | 4,421.547 | +35.545 kGE (+0.81 %) | +0.125 kGE |
| Full debug + `KARU_DBG_AUTH` | `karudbg_top` | 4,639,889 | 5,814.397 | as on Nov 15: the island SRAM as flip-flops | +0.102 kGE |
| No debug + `KARU_ZKR` | `karu64` | 3,500,040 | 4,386.015 | +0.014 kGE | new |
| `karu_entropy` alone | `karu_entropy` | 3,985 | 4.994 | | new |

- The boot-map change costs about 0.1 kGE in every row. The increments of
  debug over no debug are unchanged to the second decimal, so the November
  15 breakdown of the authentication logic (about 21.9 kGE, an estimate)
  stands.
- **Zkr in the core is below the resolution of this mapping.** With
  `KARU_ZKR` the CSR file has two more flip-flops (`SSEED`, `USEED`) and
  831 more cells, and maps to 65,157 µm² instead of 65,146 µm²: ABC maps
  the module's read multiplexer differently, and that hides the increment.
  The row shows that the cost is small, not what it is.
- **The entropy block** is the measurable part: 4.99 kGE here and 4.21 kGE
  in the timing mapping, with 336 flip-flops. It sits outside `karu64`, on
  the `zkr_*` ports. A noise source comes on top and is not costed: the
  FPGA rings are not an ASIC design.

**Timing at 200 MHz** (timing-oriented mapping, OpenSTA, unchanged
constraints: 1.5 ns input delay, outputs due at 70 % of the period):

| Configuration | Reg-to-reg WNS ns | TNS ns | Input-to-reg ns | Reg-to-output ns | Input-to-output ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| No debug | −0.4436 | −26.11 | +1.0484 | +2.7162 | — |
| No debug + `KARU_ZKR` | −0.4436 | −19.22 | +1.5555 | +0.8656 | +1.2261 |
| Full debug | −1.0840 | −118.84 | +0.2836 | +0.4122 | +0.5672 |
| Full debug + `KARU_DBG_AUTH` | −0.3978 | −37.07 | +0.0956 | **−0.2297** | +0.0178 |
| Full debug + `KARU_DBG_AUTH` + `KARU_ZKR` | −0.9153 | −96.37 | +0.3796 | **−0.2867** | **−0.0050** |
| `karu_entropy` alone | +3.6363 | 0 | +2.2987 | +2.2881 | +0.9505 |

The last full row is the configuration of the FPGA image, without the FPGA
wrappers and without the entropy block, whose ports are top-level ports
here.

- **Register to register: nothing new.** The bare core has exactly the
  October 26 result with and without Zkr: −0.4436 ns on the IFU to
  double-FMA path. The authentication row has that path family at
  −0.3978 ns, as on November 15. The full row and the row with Zkr have
  their worst path inside `varith_u` instead (−1.08 ns, the November 15
  figure to the digit, and −0.92 ns), where the authentication row has
  −0.36 ns. The vector RTL is the same in all three and does not depend on
  `KARU_ZKR`, so this is again the mapping variation of that unit, now seen
  in three independent mappings. It is not attributed to Zkr: the pair of
  bare-core rows, which differ only in `KARU_ZKR`, agree.
- **Two outputs miss the output budget in the debug tops. This is new.**
  - `trng_ack_o` (the authentication block's acknowledge to the platform
    TRNG): −0.23 ns, and −0.29 ns in the row with Zkr. On November 15 this
    group passed at +0.31 ns. The cause is the November 16 change that
    kills a CSR access in a trap or Debug-entry cycle: the strobe now waits
    for that decision. The change was right, and was not re-measured until
    now.
  - `zkr_fire_o` (the strobe that makes a `seed`, `mnoise` or
    `mentropycfg` access take effect): −0.19 ns. It has to wait for the
    same decision.

  In both, the path runs from a core flop through the trigger logic
  (`karu_trigger`) to the CSR file and out, arriving at 3.7 to 3.8 ns of
  the 5 ns cycle. On the bare core, without triggers, `zkr_fire_o` has
  +1.34 ns. The reset input reaches `trng_ack_o` with −0.005 ns in the
  Zkr row.

  What it means: with the generic budget, which leaves the consumer 1.5 ns,
  these strobes are late. The consumer of `zkr_fire_o` is `karu_entropy`,
  which alone needs far less than a cycle after its inputs (input-to-register
  +2.30 ns under the same 1.5 ns input delay), so the composition is close
  to closing at 200 MHz but is not shown to close: no row maps the core
  and the block together. For an ASIC the strobes need a budget of their
  own or the consumer placed next to the CSR file. At the FPGA's 75 MHz
  none of this matters, and the routed image meets timing.
- **The read-to-write path through the core** is visible in the Zkr rows as
  an input-to-output path, `zkr_rdata_i` to `zkr_wdata_o`, with +1.43 to
  +1.52 ns: about 0.5 ns of logic. It is the reason the entropy block must
  not let its read value depend on the written value
  (`make zkr-loop-test`).
- **`karu_entropy` alone meets 200 MHz.** Its tightest path, +0.95 ns, runs
  from the incoming symbol to the value read from `seed`: a health-test
  failure in the cycle of a read wins over the read.

All of these are mapped estimates under generic constraints, as before:
no row closes 200 MHz register to register, and the ASIC goal remains
open.

Each full-core mapping took 23 to 37 minutes and peaked at 23.0 GB in
Yosys; four ran at a time. `rows.json` in the first root has every figure
above with the worst path of each group, read with the parsers of
`dbg/collect_measurements.py`. `make dbg-measurements-report` covers only
the base and full rows of a root; the others were read from their reports.

Reproduce, with `ROOT=$PWD/_build/syn_out/karudbg-2026-11-18`:

```sh
make dbg-syn-area-off dbg-syn-timing-off DBG_SYN_ROOT=$ROOT
make DBG_SYN_EXTENSION=base dbg-syn-extension-area DBG_SYN_ROOT=$ROOT
make DBG_SYN_EXTENSION=full dbg-syn-extension-area dbg-syn-extension-timing DBG_SYN_ROOT=$ROOT
make DBG_SYN_EXTENSION=fullauth dbg-syn-extension-area dbg-syn-extension-timing DBG_SYN_ROOT=$ROOT

# the rows with Zkr: the default define list of dbg/synthesis.mk plus KARU_ZKR
ZDEF="$(sed -n 's/^DBG_SYN_DEFINES ?= //p' dbg/synthesis.mk) KARU_ZKR"
make dbg-syn-area-off dbg-syn-timing-off DBG_SYN_ROOT=$ROOT-zkr DBG_SYN_DEFINES="$ZDEF"
make DBG_SYN_EXTENSION=fullauth dbg-syn-extension-timing DBG_SYN_ROOT=$ROOT-zkr DBG_SYN_DEFINES="$ZDEF"

# the entropy block alone
printf 'rtl/karu_entropy.v\n' > $ROOT/karu_entropy.f
KARU_TOP=karu_entropy KARU_RTL_MANIFEST=$ROOT/karu_entropy.f KARU_DEFINES='' \
  KARU_CLK_PS=5000 KARU_NOSHARE=1 KARU_NO_STA=0 KARU_ABC_FAST=0 KARU_ABC_FULL=1 \
  KARU_ABC_UPRATE_PS=2000 KARU_OUT_DIR=$ROOT/timing_entropy flow/syn/syn_yosys.sh
```

## Debug and authentication area — 2026-11-15

*Superseded as the current rows by
[the November 18 refresh](#mapped-area-and-200-mhz-timing--2026-11-18); the
breakdown of the authentication logic below still stands.*

These rows measure the RTL after the 2026-11-15 security fixes (S7–S13, the
island and debug-page response rule) and authentication milestone A1. They
use the same flow, liberty, shipping processor configuration and fast-ABC area
mapping as the October 29 rows, in a separate root,
`_build/syn_out/karudbg-2026-11-15/`, so the earlier evidence is unchanged.
Areas are NanGate45 typical cells. 1 GE = 0.798 µm² (NAND2_X1), so 1 kGE =
798 µm², and memories
are mapped to cells, not SRAM macros.

| Configuration | Top | Area µm² | Area kGE | Increment over no debug |
| --- | --- | ---: | ---: | ---: |
| No debug | `karu64` | 3,499,929 | 4,385.876 | — |
| Base debug | `karudbg_top` | 3,516,623 | 4,406.796 | +20.920 kGE (+0.48 %) |
| Full debug (autoexec, two triggers, SBA) | `karudbg_top` | 3,528,294 | 4,421.422 | +35.546 kGE (+0.81 %) |
| Full debug + `KARU_DBG_AUTH` | `karudbg_top` | 4,639,807 | 5,814.295 | see below |

Full debug is within 0.1 kGE of its October 29 row (4,421.338 kGE), so the
security fixes cost almost no area.

**Authentication.** The raw row is dominated by the 16 KB island SRAM, which
this flow maps to about 136 K flip-flops. The block breakdown below is from
the same row's per-module report, plus a standalone island mapping with an
8-word SRAM to separate its logic (`island_probe/`):

| Component | kGE |
| --- | ---: |
| `karudbg_auth` (grant, mailbox FIFOs, CSRs, relock) | 13.10 |
| Island bridges (two `karudbg_axi`, 256 KB window) | ≈ 5.0 |
| Island routing and decode | ≈ 2.7 |
| DM, core and router changes | ≈ 1.0 |
| **Authentication logic, total (estimate)** | **≈ 21.9 (+0.50 % of full debug)** |
| Island SRAM array (16 KB) mapped to flip-flops | ≈ 1,371 |

The ≈ 21.9 kGE figure is an estimate, not a measured implementation: the
bridge and routing rows come from the reduced-memory probe, and nothing here
was mapped with ASIC memory macros. In an ASIC the island SRAM (16 KB) and
island ROM (64 KB) are memory macros and are not costed here. The zero-initialised simulation ROM optimises away in
this mapping. The full row shows the SRAM as flip-flops only for completeness.

Reproduce with `make DBG_SYN_EXTENSION=<base|full|fullauth> dbg-syn-extension-area
DBG_SYN_ROOT=$PWD/_build/syn_out/karudbg-2026-11-15` and
`make dbg-syn-area-off DBG_SYN_ROOT=...`. Each row took about 22–40 minutes and
peaked near 23 GB in Yosys.

**Timing at 200 MHz** (timing-oriented mapping, OpenSTA, unchanged
constraints):

| Configuration | Reg-to-reg WNS ns | TNS ns | Input-to-reg ns | Reg-to-output ns | Input-to-output ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full debug | −1.0840 | −118.84 | +0.2237 | +0.6781 | +0.5949 |
| Full debug + `KARU_DBG_AUTH` | −0.3978 | −16.86 | +0.2442 | +0.3141 | +0.5078 |

The authentication row's worst register-to-register path is the known IFU →
double-FMA family, at exactly the October 30 slack. All IO groups pass, so
authentication adds no new critical path.

The full row's −1.08 ns path lies entirely inside `varith_u`, on a chain of
single-drive buffers from one high-fanout flop. The vector RTL is unchanged
since the review commit `528ae08`, and the same unit's worst path in the
authentication row has +0.037 ns. This is mapping variation, which the
October 29 notes already describe for independent mappings of unchanged
datapaths; it is not a debug or security-fix path. Mapping variation is the
likely explanation, not a proven one, and this mapped full-debug netlist
fails 200 MHz by 1.08 ns as it stands. The 200 MHz ASIC goal remains open,
as before.

## FPGA image — 2026-11-20

`make vcu118-ddr-sgmii-rom-rva23s64-dbg VIVADO_THREADS=8
UBOOT_NETBOOT_DIR=$PWD/_build/u-boot-v2026.10-netboot`, with the default define
list (`KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR`, 75 MHz, Vivado 2026.1).
Compared with `85f07e58…` it has the redesigned health tests of the
entropy block (`rtl/karu_entropy.v`: the two SP 800-90B tests on the 4-bit
sample, lane tests at lags 1 to 4, the alarm latch, strikes and
`mentropystat`), no `mdbgrng`, and the hardware limit on the
authentication window (2³¹ clocks). Its RTL is that of `f3493b17…` below,
which it replaces: the difference is the boot ROM's firmware, compiled by
the bare-metal compiler again, and the file modes. **Board-tested on
2026-11-20**, accepted with documented exceptions: see the
[acceptance record](BOARD_ACCEPTANCE-2026-11-20.md).

- **Build.** 2026-11-19 22:29 to 2026-11-20 00:10 UTC (synthesis 23,
  placement 35, routing 25 minutes), from karu64 `f014194` and karudeb
  `db180ff`, **karu64 with uncommitted changes**. The diff and the new
  files are kept in `_build/vcu118-2026-11-19b-sources/` with their hashes.
  No file that the image is built from changed during the build. Changed
  during it, on the test side: the two proof additions of the second
  review (`test/dbg/formal/c3_miter.v`, `c9own_karudbg_island.vh`,
  `compose_c9c10_karudbg_core.vh`, `test/dbg/run_auth_formal.py`,
  `run_auth_compose.py`), a comment in `test/dbg/check_auth_bypass.py`,
  and documents. The functional gate passed on the tree the build started from (22:28 UTC, 455 inputs) and again, with those test-side changes, during the build (23:25 UTC, 456 inputs; [README](README.md)).
- **The define list and the parameters** are those of `f3493b17…` and, but
  for the entropy block's cutoffs and `AUTH_WINDOW_LOG2` = 31, of
  `85f07e58…`.
- **Final timing:**
  - setup WNS +0.008 ns, TNS 0, over 278,548 endpoints. The worst path is
    in the DDR4 interface's clock domain (+0.008 ns); `cpu_clk` has
    +0.255 ns;
  - hold WHS +0.011 ns (`cpu_clk` +0.011 ns, the DDR4 domain +0.013 ns);
    pulse width +0.005 ns;
  - all 16 bus-skew constraints pass, with at least 2.39 ns margin.
- The router ended at +0.002 ns; the flow's post-route `phys_opt_design`
  left +0.008 ns.
- DRC at `write_bitstream`: 0 errors. One critical warning in the log, the
  known `BOARD_PART_PIN` message from the DDR4 IP's board file.
- The self-checking constraints ran: `KARUDBG_BSCAN_CONSTRAINTS`,
  `KARU_LOOP_CHECK no combinational loop outside the ring oscillators`,
  `KARU_ROSC_CONSTRAINTS rings=4`, the four `KARU_ROSC_PLACED` lines in the
  same slices as `85f07e58…` (`SLICE_X100Y450` to `SLICE_X112Y451`), and
  `KARU_SYSMON_CONSTRAINTS monitor … at SYSMONE4_X0Y1 in SLR1, with the
  rings`. New: four `KARU_PRIVATE` lines, one for each file that holds the
  authentication key (below).
- Resources: 377,901 LUTs (32.0%), 91,757 registers, 451.5 block-RAM tiles,
  29 DSPs, 1 SYSMONE4. The implementation is the same as the superseded build's below: the utilisation report is identical and so is the timing report. The 14,664 LUTs more than `85f07e58…` are
  discussed under the superseded build; the per-module report of this
  image is `_build/post-route-z7-hier.rpt`.
- **Read back from the routed design** (`_build/vcu118_ddr_route.dcp`,
  read-only queries, `_build/post-route-z7.log`): setup into the entropy
  block's registers +1.444 ns, out of them +3.230 ns, inside the block
  +5.411 ns; out of the window counter into `auth_unlock_q` +9.598 ns;
  no cell named for the removed TRNG port; `report_drc` on loops: no
  LUTLP-1, four LUTLP-2 (the rings of 3, 5, 7 and 9 LUTs).
- **Boot ROM.** `_build/vcu118_fuboot.hex` (image `f15d7740…`) was compared
  byte for byte with its inputs: fu-boot (11,808 bytes) at 0, OpenSBI
  `fw_jump` (`cbbbe5ce…`) at `0x30000`, U-Boot `2026.10-dirty`
  (`7a27c424…`, 802,453 bytes) at `0x120000`, and the device tree
  (`784e2762…`) at `0x1FC000`; the regions between them are empty.
  **Against the ROM of the board-accepted `85f07e58…` it differs in 5
  bytes, all in the build date that U-Boot prints** (`Nov 19 2026 - 22:30:01 +0000`
  here). fu-boot, OpenSBI, the device tree, the boot command and every
  other byte of U-Boot are the same, so this ROM's U-Boot is the binary
  that booted on the board on 2026-11-19 but for that string.
- **Compilers.** fu-boot and U-Boot were built by
  `$RISCV/bin/riscv64-unknown-elf-gcc` (`-dumpmachine`:
  `riscv64-unknown-elf`; GCC 16.1.0), taken by absolute path. The Makefile
  now does that when `$RISCV` has the compiler, `make toolchain-check`
  refuses a compiler that does not target what its name says, and the
  compiler of each binary is recorded when the ROM is packed
  (`_build/vcu118_fuboot_toolchain.txt`) and repeated in the ROM manifest
  of the bundle. `flow/build_uboot.sh` cleans a U-Boot tree whose recorded
  compiler differs before it builds. The same compiler built the firmware
  of the simulations that ran on these sources (`image-boot-test`,
  `uboot-tftp-test`, `uboot-boot-test`: all pass).
- **Island ROM.** `_build/vcu118_auth_rom.hex` (`f518b750…`), rebuilt with
  the same compiler, is byte-identical to that of `85f07e58…`, with the
  same key (fingerprint `276bf6e96d8edecc`). Its flags:
  `-DTRNG_TRIES=200000 -DWINDOW_CYCLES=1073741824ull -DAUTH_ROM_NEXT=0x1000
  -DAUTH_ROM_NO_MTVEC -DAUTH_ALG_SHA3`. `_build/vcu118_auth_record.json`
  records the bitstream hash, the ROM flags and hash and the key
  fingerprint, and the bundle was packed only after that record verified.
- **File modes.** The key is in the island ROM, and so in the three
  checkpoints and in the bitstream. For an image with `KARU_DBG_AUTH` the
  Makefile now runs Vivado with `umask 077`, and the flow sets those four
  files to mode 0600 and checks it: the log has `KARU_PRIVATE` for
  `vcu118_ddr_synth.dcp`, `vcu118_ddr_postplace.dcp`,
  `vcu118_ddr_route.dcp` and `vcu118_ddr.bit`. The bundle is 0600 and
  strips group and other access from its members. The bitstreams in
  `_build/fpga_archive/` were set to 0600 by hand on 2026-11-19; until then
  the `.bit` and `.dcp` files of every image with a key were 0664 in a
  home directory that the group can enter.
- None of these checks decodes the `.bit` file, as before.

The bitstream SHA-256 is
`ddb168e1081c9b73c29cd5a16ab777ee8106a52d382469b5b741b094bc096aad`; the
bundle `_build/vcu118_programming.tgz` (mode 600, with the key) is
`88dce485fadad7c63ba42e07bd7ed5f2124d69bbef8ca2f1a53b7b8c54817342`. This
image's reports are in `_build/fpga_rpt/`; the accepted image and the
superseded build are kept, each with its bundle and reports, in
`_build/fpga_archive/2026-11-18-85f07e58/` and
`_build/fpga_archive/2026-11-19-f3493b17/`.

## FPGA build — 2026-11-19 (`f3493b17…`, superseded)

`make vcu118-ddr-sgmii-rom-rva23s64-dbg VIVADO_THREADS=8
UBOOT_NETBOOT_DIR=$PWD/_build/u-boot-v2026.10-netboot`, with the default define
list (`KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR`, 75 MHz, Vivado 2026.1).
Compared with `85f07e58…` below it has the redesigned health tests of the
entropy block (`rtl/karu_entropy.v`: the two SP 800-90B tests on the 4-bit
sample, lane tests at lags 1 to 4, the alarm latch, strikes and
`mentropystat`), no `mdbgrng`, and the hardware limit on the
authentication window (2³¹ clocks). **Superseded by `ddb168e1…` (above) and
never programmed**: its fu-boot and U-Boot came from a Linux-target
compiler, as the boot ROM items below explain. The RTL is the same in
both. Kept in `_build/fpga_archive/2026-11-19-f3493b17/`.

- **Build.** 2026-11-19, 19:30 to 21:20 UTC (1 h 50 min: synthesis 24,
  placement 36, routing 25 minutes), from karu64 `f014194` and karudeb
  `db180ff`, **karu64 with uncommitted changes**. The diff and the new
  files are kept in `_build/vcu118-2026-11-19-sources/` with their hashes.
  No file that the image is built from changed during the build. Three
  test-side files did (`dbg/auth.mk`, `test/dbg/check_auth_bypass.py`,
  `test/dbg/board/auth_rehearse.py`), five test files are new, and so did
  documents. The functional gate passed on the build's sources just before
  (19:29 UTC, 450 inputs) and on the tree with the test-side changes
  after (21:25 UTC, 455 inputs; [README](README.md)).
- **The define list and the parameters** are those of `85f07e58…`, read
  from the two synthesis logs: the same `KARU_DEFINES` line, and the bound
  parameters differ only in the entropy block's cutoffs and limits and in
  `AUTH_WINDOW_LOG2` = 31. The five tool commands are the same.
- **Final timing:**
  - setup WNS +0.008 ns, TNS 0, over 278,548 endpoints. The worst path is
    in the DDR4 interface's clock domain, from the AXI width converter into
    the DDR4 controller's write-response FIFO; `cpu_clk` has +0.255 ns;
  - hold WHS +0.011 ns (on `cpu_clk`); pulse width +0.005 ns;
  - all 16 bus-skew constraints pass, with at least 2.39 ns margin.
- The router ended at +0.002 ns; the flow's post-route `phys_opt_design`
  left +0.008 ns. Nothing of the new logic is among the 30 reported worst
  paths.
- DRC at `write_bitstream`: 0 errors. One critical warning in the log, the
  known `BOARD_PART_PIN` message from the DDR4 IP's board file.
- The self-checking constraints ran: `KARUDBG_BSCAN_CONSTRAINTS`,
  `KARU_LOOP_CHECK no combinational loop outside the ring oscillators`,
  `KARU_ROSC_CONSTRAINTS rings=4`, the four `KARU_ROSC_PLACED` lines in the
  same slices as `85f07e58…` (`SLICE_X100Y450` to `SLICE_X112Y451`), and
  `KARU_SYSMON_CONSTRAINTS monitor … at SYSMONE4_X0Y1 in SLR1, with the
  rings`.
- Resources: 377,901 LUTs (32.0%), 91,757 registers, 451.5 block-RAM tiles,
  29 DSPs, 1 SYSMONE4. That is 14,664 LUTs and 631 registers more than
  `85f07e58…`. The registers are about what the new logic adds. The LUTs
  are not: the whole entropy source is 778 LUTs and the authentication
  block 406, against 214,850 in the vector arithmetic unit. Synthesis
  already ends 18,818 LUT primitives apart, and the two totals are the two
  seen before (376,035 LUTs on November 17, 362,437 on November 18, which
  the notes below call a difference between two optimisation runs). It is
  not attributed further: no per-module report of `85f07e58…` was kept.
  This image's is `_build/post-route-z6-hier.rpt`. The placement differs
  as well: most block RAM is in SLR2 here and was in SLR1 there. The
  boot memory has 418 block RAMs, and the design's 451 are as many as in
  `85f07e58…`: the larger U-Boot fills block RAMs that were already
  there.
- **Read back from the routed design** (`_build/vcu118_ddr_route.dcp`,
  read-only queries, `_build/post-route-z6.log`):
  - the entropy block (`u_entropy/entropy`) is 703 LUTs (895 LUT
    primitives before pairing), 576 flip-flops and 34 carry chains; out of
    context it was 721 and 576, and the block of `85f07e58…` 413 and 332.
    With the rings' sampler and the burst capture the source is 778 LUTs
    and 696 flip-flops. Setup into the block's registers +1.444 ns, from
    the core's CSR address through the write decode to a cutoff field's
    register, 9 levels. Out of them +3.230 ns, 17 levels: from the count of
    samples seen, through the tests' verdict and `seed`'s read data, into a
    CSR register. Inside the block +5.411 ns. Hold into it +0.024 ns;
  - the window counter is 32 flip-flops in `cpu/auth`, on `cpu_clk`. Out
    of it into `auth_unlock_q` +9.598 ns, 3 levels; into it +11.869 ns;
  - no cell is named for the removed TRNG port;
  - `report_drc` on loops: no LUTLP-1, four LUTLP-2 (the rings of 3, 5, 7
    and 9 LUTs).
- **Boot ROM.** `_build/vcu118_fuboot.hex` (image `2639b44e…`) was compared
  byte for byte with its inputs: fu-boot (12,848 bytes) at 0, OpenSBI
  `fw_jump` (`cbbbe5ce…`) at `0x30000`, U-Boot `2026.10-dirty`
  (`4a823f6c…`, 899,245 bytes) at `0x120000`, and the device tree
  (`784e2762…`) at `0x1FC000`; the regions between them are empty. OpenSBI,
  the device tree and the boot command are byte-identical to `85f07e58…`.
- **fu-boot and U-Boot were compiled by a different compiler than for
  `85f07e58…`.** The build's `PATH` had `~/.local/bin` before `$RISCV/bin`,
  and `~/.local/bin/riscv64-unknown-elf-gcc` is a link to the Linux-target
  compiler (`riscv64-unknown-linux-gnu`, the same GCC 16.1.0 sources;
  U-Boot's own build record names its include directory). That compiler
  writes unwind tables by default and the bare-metal one does not, so each
  binary carries an `.eh_frame` section that it did not have: 1,040 bytes
  in fu-boot (11,808 before) and 96,792 in U-Boot (802,453 before), which
  is the whole difference in size. U-Boot now ends 1,875 bytes below the
  device-tree slot; the packer checks that it fits. fu-boot from the same
  sources and compiler boots in `image-boot-test`, and U-Boot's simulation
  configuration from the same compiler in `uboot-boot-test`; the U-Boot
  binary of this ROM, the netboot configuration, has run nowhere. The
  Makefile now takes the bare-metal compiler by absolute path and checks
  it, and `ddb168e1…` above was built that way.
- **Island ROM.** `_build/vcu118_auth_rom.hex` (`f518b750…`) is
  byte-identical to that of `85f07e58…`, with the same key (fingerprint
  `276bf6e96d8edecc`): that ROM already drew its nonce from `seed`. Its
  flags are now `-DTRNG_TRIES=200000 -DWINDOW_CYCLES=1073741824ull
  -DAUTH_ROM_NEXT=0x1000 -DAUTH_ROM_NO_MTVEC -DAUTH_ALG_SHA3`.
  `_build/vcu118_auth_record.json` records the bitstream hash, the ROM
  flags and hash and the key fingerprint, and the bundle was packed only
  after that record verified.
- None of these checks decodes the `.bit` file, as before.

The bitstream SHA-256 is
`f3493b179ea848de9ac522463788339d0cd316d7f30bb86f541b87cd38730b63`; the
bundle `_build/vcu118_programming.tgz` (mode 600, with the key) is
`32ceafcdca623c118338bc8268d9c65468eb64b5a55c87fc4edeab53b97560d1`. This
build, its bundle, its reports and its logs are kept in
`_build/fpga_archive/2026-11-19-f3493b17/`.

## FPGA image — 2026-11-18 evening

`make vcu118-ddr-sgmii-rom-rva23s64-dbg VIVADO_THREADS=8
UBOOT_NETBOOT_DIR=$PWD/_build/u-boot-v2026.10-netboot`, with the default define
list (`KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR`, 75 MHz, Vivado 2026.1).
Compared with `d7ff00dc…` below it adds the entropy source's burst capture
(`flow/fpga/karu_noise_burst.v`), the temperature and supply readout
(`flow/fpga/karu_sysmon.v`), the SHA3-256 shared-secret island ROM
(algorithm `0x04`) and U-Boot v2026.10 with the Zkr time-out patch.
**Board-tested on 2026-11-19**, all stages pass: see the
[acceptance record](BOARD_ACCEPTANCE-2026-11-19.md).

- **Build.** 2026-11-18, 21:32 to 23:40 UTC (2 h 7 min: synthesis 25,
  placement 36, routing 37 minutes, post-route optimisation 7), from karu64
  `a39f3da` and karudeb `db180ff`, **karu64 with uncommitted changes**. No
  source file changed during the build; two documents did. The diff and the
  new files are kept in `_build/vcu118-2026-11-18c-sources/` with their
  hashes. The functional gate passed on the same sources just before
  (21:32 UTC, 441 inputs; [README](README.md)).
- **Final timing:**
  - setup WNS +0.002 ns, TNS 0, over 276,720 endpoints; `cpu_clk` setup
    +0.002 ns;
  - hold WHS +0.011 ns; pulse width +0.005 ns;
  - all 16 bus-skew constraints pass, with at least 2.27 ns margin.
- The router ended at WNS −0.301 ns (TNS −16.95 ns); the flow's post-route
  `phys_opt_design` closed it to +0.002 ns. The worst path is in the vector
  unit (`varith_u`); nothing of the new logic is among the reported worst
  paths.
- DRC at `write_bitstream`: 0 errors. One critical warning in the log, the
  known `BOARD_PART_PIN` message from the DDR4 IP's board file.
- The self-checking constraints ran: `KARUDBG_BSCAN_CONSTRAINTS`,
  `KARU_LOOP_CHECK no combinational loop outside the ring oscillators`,
  `KARU_ROSC_CONSTRAINTS rings=4`, the four `KARU_ROSC_PLACED` lines in the
  same slices as `d7ff00dc…` (`SLICE_X100Y450` to `SLICE_X112Y451`), and
  `KARU_SYSMON_CONSTRAINTS monitor … at SYSMONE4_X0Y1 in SLR1, with the
  rings`.
- Resources: 363,237 LUTs (30.7%), 91,126 registers, 451.5 block-RAM tiles,
  29 DSPs, 1 SYSMONE4. The six more tiles than `d7ff00dc…` are the capture
  block's four and two more in the boot ROM (386 RAMs), whose larger U-Boot
  leaves less of the layout empty.
- **Read back from the routed design** (`_build/vcu118_ddr_route.dcp`,
  read-only queries, `_build/post-route-burst.log` and
  `_build/post-route-bram.log`):
  - the capture block's four RAMB36E2 are at `RAMB36_X7Y90` to `X7Y93`.
    Setup into their address pins +2.879 ns, from the core's load path
    through the bus decode (the out-of-context estimate was +10.8 ns);
    hold +0.053 ns. Into their data pins +12.18 ns; out of them, into the
    read-data register, +9.64 ns;
  - the monitor's paths have at least +7.13 ns, and the paths through the
    read-data selection that the capture block and the readout share at
    least +3.61 ns;
  - `report_drc` on loops: no LUTLP-1, four LUTLP-2 (the rings of 3, 5, 7
    and 9 LUTs).
- **Boot ROM.** `_build/vcu118_fuboot.hex` (`9e850d63…`) was compared byte
  for byte with its sources: OpenSBI `fw_jump` (`cbbbe5ce…`, the same as
  `d7ff00dc…`) at `0x30000`, U-Boot `2026.10-dirty` (`0e560318…`, 802,453
  bytes, the tree at `v2026.10` with only `drivers/rng/riscv_zkr_rng.c`
  changed, to `94e649a1…`, the patched driver; `BOARD_RNG_SEED` off) at
  `0x120000`, and the device tree (`784e2762…`, the same) at `0x1FC000`.
  The ROM manifest in the bundle repeats this from the packed image.
- **Island ROM.** `_build/vcu118_auth_rom.hex` (`f518b750…`), built with
  `-DCSR_RNG=0x015 -DTRNG_TRIES=200000 -DWINDOW_CYCLES=1073741824ull
  -DAUTH_ROM_NEXT=0x1000 -DAUTH_ROM_NO_MTVEC -DAUTH_ALG_SHA3`. The key
  (fingerprint `276bf6e96d8edecc`) was generated on the build host at
  20:25 UTC. It is in `_build/vcu118_auth_key.txt` (mode 600), which git
  ignores, and the build checked that the ROM holds it exactly
  once. `_build/vcu118_auth_record.json` records the bitstream hash, the
  ROM flags and hash and the key fingerprint. The bundle was packed only
  after that record verified.
- None of these checks decodes the `.bit` file, as before.

The bitstream SHA-256 is
`85f07e58354646ff3102fe3ddfe8c2e91005b5171b895391aea7ea3795f2639a`; the
bundle `_build/vcu118_programming.tgz` (mode 600, with the key) is
`fbdec6e42c75f0c5e236beeede5314f2e7962afb6935bc6615ebf852d6510f38`. This
image's reports replace those of `d7ff00dc…` in `_build/fpga_rpt/` on this
build host.

## FPGA image — 2026-11-18

`make vcu118-ddr-sgmii-rom-rva23s64-dbg` with its default define list
(`KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR`, 75 MHz, Vivado 2026.1). Compared
with the November 17 image it adds the Zkr `seed` CSR with the
ring-oscillator entropy source, debug authentication with its island, the
2 MiB boot ROM, the four SW12 straps and, in the ROM, the `zkr` device tree.
**Board-tested on 2026-11-18:** every stage of
[the board test plan](BOARD_TEST_PLAN.md) passes, apart from the known
OpenOCD translation results; see the
[acceptance record](BOARD_ACCEPTANCE-2026-11-18.md).

- **Two builds.** The first ran on 2026-11-17 from 22:27 to 00:13 UTC,
  routed with timing met (+0.003 ns) and was refused at `write_bitstream`
  by DRC LUTLP-1: a combinational loop between `karu_csr` and
  `karu_entropy`, described in the changelog. The fix is one term in
  `rtl/karu_entropy.v`. The second, this image, ran on 2026-11-18 from
  00:23 to 02:20 UTC (1 h 57 min: synthesis 25, placement 37, routing 32
  minutes), alongside the functional gate, the formal gate, the boot
  simulation and four Yosys mappings.
- **Inputs.** Its 261 hashed inputs did not change during the build. They
  are karu64 commit `d58aa6f` and karudeb commit `8dfc019` **plus
  uncommitted changes in both**; `_build/vcu118_build_inputs.json` lists the
  changed files and the hash of every input.
- **Loop check.** Right after synthesis the flow now runs the LUTLP-1 check:
  `KARU_LOOP_CHECK no combinational loop outside the ring oscillators`. The
  same commands find one violation in the first build's synthesised
  netlist, which is kept as the control
  (`_build/loopcheck/bad_synth.dcp`).
- **Final timing:**
  - setup WNS +0.051 ns, TNS 0, over 275,925 endpoints;
  - hold WHS +0.011 ns;
  - pulse width +0.005 ns;
  - 0 violated paths.
- The router ended with timing met (setup +0.034 ns); the flow's post-route
  `phys_opt_design` ran anyway and left +0.051 ns.
- `cpu_clk`: setup +0.198 ns, hold +0.011 ns.
- The worst path is in the DDR4 controller IP (`mmcm_clkout0`, 3.333 ns),
  not in the processor.
- All 16 bus-skew constraints pass, with at least 2.68 ns margin.
- DRC at `write_bitstream`: 0 errors. One critical warning in the log, the
  known `BOARD_PART_PIN` message from the DDR4 IP's board file.
- The self-checking constraints ran:
  `KARUDBG_BSCAN_CONSTRAINTS core=cpu_clk period=13.333 ns TCK=100 ns`,
  `KARU_ROSC_CONSTRAINTS rings=4 … sampling paths cut`, and after placement
  one `KARU_ROSC_PLACED` line per ring: 3 stages in `SLICE_X100Y450`, 5 in
  `SLICE_X104Y450`, 7 in `SLICE_X108Y450`, 9 in `SLICE_X112Y450` and
  `SLICE_X112Y451`.
- Resources: 362,437 LUTs (30.7%), 90,983 registers, 445.5 block-RAM tiles,
  29 DSPs. The November 17 image had 376,035 LUTs and 317.5 tiles; the LUT
  count is lower although the design is larger, which is a difference
  between two optimisation runs and not a saving.
- **Read back from the routed design** (`_build/vcu118_ddr_route.dcp`,
  read-only queries, logs in `_build/loopcheck/`):
  - `report_drc`: no LUTLP-1; four LUTLP-2, the allowed loops of 3, 5, 7
    and 9 LUTs. Its other warnings are in logic and IP that this work did
    not touch: DSP pipelining (DPIP-2, DPOP-3, DPOP-4), cascaded clock
    buffers and an unused clock buffer in the Ethernet and DDR4 IP
    (REQP-1852, -1853, -1877), the debug hub (PDCN-1569) and nets without
    routable loads (RTSTAT-10).
  - The four ring-to-sampler paths carry a false-path exception for setup
    and hold, as intended; the synchroniser flops behind the samplers are
    ordinary paths with at least +12.8 ns.
  - `dip_i[0..3]` are on `B17`, `G16`, `J16` and `D21` with `LVCMOS12`.
  - The entropy source is 442 LUTs and 362 flip-flops. The slowest path
    out of its registers has +1.88 ns and the slowest into them +0.63 ns
    (from the power-on reset flop).
  - The boot ROM is 384 block RAMs, not the 512 of a full 2 MiB: synthesis
    leaves out the two 256 KiB stretches of the layout that hold nothing.
    The island's ROM and SRAM are in LUTs, not in block RAM.
- **Boot ROM.** The packed image that synthesis read
  (`_build/vcu118_fuboot.hex`) was compared byte for byte with its sources:
  fu-boot at offset 0, OpenSBI v1.9 (`cbbbe5ce…`) at `0x30000`, U-Boot
  2025.01 (`0d305f3f…`) at `0x120000` and the device tree (`784e2762…`,
  with `zkr` and the reboot nodes) at `0x1FC000`. Everything else is zero,
  the island range and the Debug Module's page included. The device tree
  equals the staged `board.dtb`, and the baked boot command carries
  `random.trust_cpu=off`.
- **Island ROM.** `_build/vcu118_auth_rom.hex` (`c6efbc76…`) was built with
  `-DCSR_RNG=0x015 -DTRNG_TRIES=200000 -DWINDOW_CYCLES=1073741824ull
  -DAUTH_ROM_NEXT=0x1000 -DAUTH_ROM_NO_MTVEC`: nonce from `seed`, a window
  of 2^30 cycles (14.3 s at 75 MHz), hand-over to the boot ROM. It verifies
  with the simulation-only `TEST` algorithm.
- None of these checks decodes the `.bit` file. The checkpoint is the
  routed design that the same Vivado run wrote the bitstream from, and the
  ROM images are the memory initialisation it was given.

The bitstream SHA-256 is
`d7ff00dc494d8354ce596b3e7ebb07aabb2df92f9df186d8a3870b9a972a3e80`.
Reports are in `_build/fpga_rpt/`, the bundle is
`_build/vcu118_programming.tgz` (`5e93e662…`), and
`_build/vcu118_full_verification.json` records the figures above with the
output and report hashes. The November 17 image is archived in
`_build/fpga_archive/2026-11-17-d5e603cd/`.

## FPGA image — 2026-11-17

`make vcu118-ddr-sgmii-rom-rva23s64-dbg` (`KARU_DBG_FULL`, 75 MHz, Vivado
2026.1) rebuilt the debug image from an empty `_build`. Compared with the
November 15 image it adds the two UART receive-path fixes, the software
reboot (system-control register and reset stretcher) and, in the boot ROM,
OpenSBI v1.9 and the device tree with the `syscon-reboot` nodes. It does not
include `KARU_DBG_AUTH`. **It has not been programmed into a board, and no
board test has run on it.**

- The build ran from 11:21 to 13:33 UTC (2 h 12 min), partly alongside the
  functional gate. Its 253 hashed inputs are byte-identical to karu64 commit
  `d58aa6f` and did not change during the build; the boot inputs come from
  karudeb commit `8dfc019`. `_build/vcu118_build_inputs.json` has the list.
- The router ended at WNS −0.113 ns (TNS −3.527 ns). Physical optimisation
  inside `route_design` brought it to −0.019 ns and the flow's post-route
  `phys_opt_design` closed it.
- **Final:**
  - setup WNS +0.003 ns, TNS 0, over 244,159 endpoints;
  - hold WHS +0.002 ns;
  - pulse width +0.005 ns;
  - 0 violated paths.
- `cpu_clk`: setup +0.113 ns, hold +0.011 ns.
- The worst path is again in the Xilinx AXI clock-converter and
  width-converter IP on the DDR side (`mmcm_clkout0`, 3.333 ns), not in the
  processor. The margin there is 3 ps, less than the 8 ps of November 15.
- All 16 bus-skew constraints pass, with at least 2.69 ns margin.
- DRC: 0 errors. One critical warning, the known `BOARD_PART_PIN` message
  from the DDR4 IP's board file.
- The self-checking debug constraints ran:
  `KARUDBG_BSCAN_CONSTRAINTS core=cpu_clk period=13.333 ns TCK=100 ns`.
- Resources: 376,035 LUTs (31.8%), 89,844 registers, 317.5 block-RAM tiles,
  29 DSPs.
- **Reboot logic in the routed design.** Read back from
  `_build/vcu118_ddr_route.dcp`: `u_debug_bus_reset/soft_hold` is present
  with its eight-bit counter and single output flop, and that flop drives
  the release logic of both reset sequencers (`ui_startup` and `ui_cancel`).
  The registers that can reach it are the write address, privilege bit,
  32 data bits and eight strobes of the processor's data-bus master, the
  debug module's System Bus Access master (which the decode admits by
  design), the bus arbitration and write-channel state, and power-on reset.
  UART, flash and the CTS pin appear only through the shared write-wait
  term, which is qualified by address and cannot hold a write to this
  register. The slowest path into it has +4.48 ns.
- **Boot ROM.** The packed ROM image that synthesis read
  (`_build/vcu118_fuboot.hex`) was compared byte for byte with its sources:
  fu-boot, OpenSBI v1.9 (`cbbbe5ce…`), U-Boot 2025.01 and the device tree
  (`c477784a…`), which is also the staged `board.dtb`.
- Neither check decodes the `.bit` file. The checkpoint is the routed
  design that the same Vivado run wrote the bitstream from, and the ROM
  image is the memory initialisation it was given. On the board, the
  OpenSBI banner and a program-with-verify are the direct checks.

The bitstream SHA-256 is
`d5e603cdf92cb22474e9ac073de33ebf2d5ac16d6f5d22ac38b2b4ec8dffd9b2`.
Reports are in `_build/fpga_rpt/ddr_rva23s64_dbg_sgmii_75_rom__*`, the bundle
is `_build/vcu118_programming.tgz` (`6d7cad04…`), and
`_build/vcu118_full_verification.json` records the figures above with the
output and report hashes. The November 15 image is no longer in `_build`,
which was emptied before this build.

## FPGA image — 2026-11-15

`make vcu118-ddr-sgmii-rom-rva23s64-dbg` (`KARU_DBG_FULL`, 75 MHz, Vivado
2026.1) rebuilt the debug image with all 2026-11-15 security fixes. It does
not include `KARU_DBG_AUTH`; plan A5 is a proposal for review.

- The router ended at WNS −0.057 ns; the flow's automatic post-route
  `phys_opt_design` closed it.
- **Final:**
  - setup WNS +0.008 ns, TNS 0;
  - hold WHS +0.005 ns;
  - pulse width +0.005 ns;
  - 0 violated paths.
- `cpu_clk`: setup +0.070 ns, hold +0.010 ns.
- The worst path is in the Xilinx AXI width/clock-converter IP on the DDR
  side, as in earlier images.
- All bus-skew constraints pass, with at least 2.75 ns margin.
- DRC: 0 errors.

The bitstream SHA-256 is
`0b994847163b0d471816edb2b63f1c5c94d777f9b829f48364d9521512378b22`.
Reports are in `_build/fpga_rpt/ddr_rva23s64_dbg_sgmii_75_rom__*` and the
bundle in `_build/vcu118_programming.tgz`. The October 29 bit, bundle and
reports are archived in `_build/fpga_archive/2026-10-29/`, together with
that image's `vcu118_build_inputs.json` and `vcu118_full_verification.json`.
`_build/vcu118_full_verification.json` was regenerated on 2026-11-16 from the
November 15 reports and outputs: timing, resources, and output and report
hashes. The October record's independent checks were not rerun for this
image, so its packed-ROM byte comparison and 149-input manifest fields are
null there, and no `vcu118_build_inputs.json` exists for this image. Board
acceptance is recorded separately in [BOARD_ACCEPTANCE.md](BOARD_ACCEPTANCE.md)
for the November 16 run. No board was connected during synthesis.

## Registered SBA pause — 2026-10-30

The fetch-fault trigger qualification added on October 29 exposed a new
combinational path: reset-gated SBA request VALID reached the arbiter pause,
then the execute-trigger comparators and core issue/CSR logic. This caused
the full-row input-to-register miss below; it was not a pre-existing base
debug timing failure.

The arbiter now registers its pause. A RAM request cannot be accepted until
that registered hold is high and the core reports quiet, so an instruction
admitted on the hold's assertion edge still drains before AW/W. Actual request
VALID keeps its reset suppression. Cancellation clears an unaccepted hold on
the next clock; accepted writes retain it through response/maintenance.
This adds one control flip-flop and a hold-assertion clock to RAM-write setup.
The combined non-board gate passes at 01:08 UTC in 1,094.03 seconds with all
274 captured inputs unchanged; the current arbiter source SHA-256 is
`48bff334aa27d34a5bc35b5e5d3337355897b7155ddd7e9798f48a81388829fc`.
The bus bench passes 652 checks in each security configuration; all 13
invariant corruption controls and 17 transport/backend controls are rejected.
The full two-trigger timing row was freshly mapped with unchanged 200 MHz
constraints, tools and Liberty. Only `dbg/karudbg_bus.v` differs between its
captured synthesis inputs and the October 29 run. The current result is:

| Configuration | Reg-to-reg WNS ns | TNS ns | Input-to-reg ns | Reg-to-output ns | Input-to-output ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full, two triggers | −0.3978 | −17.40 | +0.2328 | +0.3106 | +0.5794 |

Input-to-register slack improves from −0.1739 to +0.2328 ns; all three IO
groups now pass. The worst input path still starts at timed synchronous reset
and ends in the IFU, but goes through ordinary DM/core control, rather than
the SBA request/pause and trigger-comparator chain. The register-to-register
miss remains on the IFU/decode-to-double-FMA path, so 200 MHz is still open.
The four-trigger row and area rows have not been rerun for this change.

Reproduce with `make DBG_SYN_EXTENSION=full dbg-syn-extension-timing`.
The mapped reports and before/after input hashes are in
`_build/syn_out/karudbg/timing_full/`; the independently checked result is
`_build/dbg/reset-pause/results.json`. Running `make dbg-measurements-report`
now marks only this timing row current and the retained October 29 rows
stale against the changed source; it does not silently reuse their numbers.

The October 29 FPGA image and programming bundle below are unchanged and
retain their recorded 75 MHz acceptance. They contain the earlier pause
implementation, rather than this RTL follow-up.

## Extension measurements — 2026-10-29

All six area and six timing rows were freshly mapped after the review fixes
for SBA discovery, scratch-memory coherence, external-cache completion and
trigger direction/pause qualification. Every row has identical before/after
input fingerprints for that checkpoint's RTL, tools, flow and Liberty;
no netlist or source-equivalence reuse was used. The core source SHA-256 is
`989822449d1646d4f6471c3628b4eee2964e2b6c77d858bb8598cb427d6fb5ee`.
These tables retain the October 29 checkpoint. The subsequent pause register
is covered separately above; its area and four-trigger timing are not inferred
from these measurements. The original full timing row is preserved in
`_build/syn_out/karudbg/timing_full-2026-10-29.tgz` and its collected matrix in
`_build/dbg/reset-pause/before-measurements.json`.

The comparison uses the same shipping processor and conventional-JTAG
`karudbg_top` for base debug, autoexec only, two triggers only, SBA only,
all extensions with two triggers, and all extensions with four triggers.
`KARU_DBG_FULL` enables autoexec, triggers and SBA. The standard 75 MHz
FPGA debug target selects the full two-trigger configuration; mapped cell
estimates and routed FPGA acceptance are separate results.

`make dbg-measurements-report` checks the evidence and writes row validity,
source/tool/library hashes and worst-path endpoints to
`_build/syn_out/karudbg/measurements/measurements.{json,md}`.

| Configuration | Area kGE | Increment kGE | Increment % |
| --- | ---: | ---: | ---: |
| Base debug | 4,406.7233 | 0.0000 | 0.0000 |
| Autoexec | 4,406.8260 | 0.1027 | 0.0023 |
| Two triggers | 4,412.8477 | 6.1243 | 0.1390 |
| SBA | 4,415.0943 | 8.3710 | 0.1900 |
| Full, two triggers | 4,421.3380 | 14.6147 | 0.3316 |
| Full, four triggers | 4,425.0677 | 18.3443 | 0.4163 |

The increments use the fresh base-debug area row. Area uses fast ABC;
timing uses a separate timing-oriented mapping at 200 MHz. These NanGate45
typical estimates map memories to cells, rather than ASIC SRAM macros.

| Configuration | Reg-to-reg WNS ns | TNS ns | Input-to-reg ns | Reg-to-output ns | Input-to-output ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Base debug | −0.3991 | −16.64 | +0.4428 | +2.0461 | +0.7750 |
| Autoexec | −0.3991 | −16.64 | +0.3823 | +2.0191 | +0.7549 |
| Two triggers | −0.3975 | −16.55 | +0.4174 | +0.4459 | +0.7041 |
| SBA | −0.3978 | −17.36 | +0.4749 | +1.9740 | +0.7171 |
| Full, two triggers | −0.3978 | −20.38 | −0.1739 | +0.3106 | +0.3510 |
| Full, four triggers | −0.9432 | −96.76 | −0.2210 | +0.2706 | +0.3039 |

No row closes at 200 MHz. The selected full two-trigger row has register-to-
register WNS −0.3978 ns and TNS −20.38 ns. Its longest path starts at IFU
`_6986_`, passes through buffered-address/compressed-decode and FP operands,
and ends at double FMA `u_ffma_d/_30816_`: 5.36 ns data arrival. Base debug
has the same critical-path family at −0.3991 ns. The small slack difference
is mapping variation, rather than evidence that debug improves timing.

The full row also fails input-to-register timing at **−0.1739 ns**. The path
starts at synchronous `rst`, traverses DM/SBA and trigger/core control, and
ends at IFU `_7340_`. Its 5.14 ns arrival includes the specified 1.50 ns input
delay. The synchronous reset path is timed; it is not covered by the TCK
asynchronous-reset exception. The archived full timing row retains the
detailed cone. Base debug's corresponding group passes at +0.4428 ns.
The full row's `debug_resume_ack_o` output paths pass: +0.3106 ns from a
register and +0.3510 ns from an input. There is no general IO-clean claim.

The optional four-trigger row has WNS −0.9432 ns and TNS −96.76 ns. Its
longest path runs from `frs1_q[0]`, through buffered scalar distribution,
widening and the lane FP-estimate unit, to `ksbuf[348]`: 5.90 ns arrival.
It does not traverse a trigger comparator. Its reset input group also fails
at −0.2210 ns. Independent mappings vary in unchanged datapaths, so the
slack difference cannot be assigned entirely to the two extra trigger slots.
The four-slot row is a cost comparison, not the default FPGA composition.

The registered 64-bit watch address separates indexed effective-address
generation from trigger comparison and global entry control. It adds one
cycle per armed vector field query; the disabled sequence is unchanged.
All 16 ordinary subjects have identical full/base cycle counts. No RF,
cache or VRF memory port was added.

Whole-row memory use can reach about 35 GB including ABC subprocesses;
Yosys's own approximately 23 GB peak excludes those children. Bound concurrent
rows by available memory. All source/configuration and raw-report evidence is
under `_build/syn_out/karudbg/{area,timing}_<configuration>/`.

## Historical base-debug measurements — 2026-10-26

The 2026-10-26 refresh measures the review-corrected shipping processor
composition with AXI protection metadata in both rows. The enabled row adds
core Sdext support, DM, private debug-memory bridges and conventional JTAG DTM,
including its TCK reset-release conditioner. It uses `karudbg_top`; the disabled
row uses `karu64`. FPGA BSCAN integration and board acceptance have separate
scope. Both area rows and the corrected timing comparison are complete.

## Configuration and tools

Both rows use VLEN=256, ELEN=64, VBUS=128, two 64-bit compute lanes with FP
units, 4 KiB I/D caches and the static `NONSECURE=1` parameter. Common defines:

```text
KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK
KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64
KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64
KARU_V_LANE_PIPE KARU_V_CWB_STAGE
KARU_SMCNTRPMF KARU_SSCOFPMF
```

The enabled row additionally defines `KARU_DBG`. Mapping retains FPGA/default
RTL initialization semantics, without `KARU_ASIC`. Memories map to standard
cells: these are comparative NanGate45 cell estimates, not physical SRAM-macro
area or ASIC signoff results. Separate ASIC initialization evidence is below.

Tools are Yosys 0.69+24 (`d0e71cfb7`), its associated ABC, OpenSTA 3.1.0 and
NanGate45 typical-corner Liberty. One kGE is 798 um² (`NAND2_X1=0.798 um²`).
The measured review fixes are committed at `175b842`; source/input fingerprints
in the run manifests identify the measured implementation.

## Mapped area

Hierarchical `synth -noshare`, no flattening, fast area-only ABC mapping,
STA disabled:

| Configuration | Top | Area (um²) | kGE |
| --- | --- | ---: | ---: |
| Shipping, debug disabled | `karu64` | 3,499,907.768 | 4,385.849 |
| Shipping + karudbg | `karudbg_top` | 3,516,381.946 | 4,406.494 |
| Debug increment | | 16,474.178 | 20.644 |

The measured increment is **0.4707%**. The enabled run completed with identical
before/after input fingerprints; its starting manifest SHA-256 is
`fa6e7dd5ca1f28cf72ffb0baf72e5ca26d0de8bf8a59e43e317c320db2541e5b`.
Yosys reported 23,063 MB peak memory. Evidence is under
`_build/syn_out/karudbg/{area_off,area_on}/`.

The disabled mapped design is reused with an explicit equivalence audit.
All 54 source token streams after Yosys preprocessing under the shipping
non-debug defines match `4058a60`, whose core sources match the recorded
mapping inputs. Mapping scripts, ABC constraints, tool binaries and Liberty
are unchanged. This proves the debug-only review changes do not alter the
reference design. Source, token, flow and tool evidence is in
`_build/syn_out/karudbg/off-source-equivalence/proof.json`.

## OpenSTA at 200 MHz

Timing uses a 5 ns core clock, timing-oriented ABC mapping with a 3 ns internal
budget, and 1.5 ns input/output delays. `KARU_IN_PCT=30` sets input arrival;
`KARU_OUT_PCT=70` sets the output deadline, leaving a 30% output delay budget.
The enabled top also constrains TCK at 100 ns (10 MHz).

| Configuration | Register-to-register WNS | TNS | Input-to-register WNS | Register-to-output WNS |
| --- | ---: | ---: | ---: | ---: |
| Debug disabled | -0.4436 ns | -26.11 ns | +1.1159 ns | +2.7162 ns |
| Debug enabled | -0.3977 ns | -16.93 ns | +0.0566 ns | +2.0143 ns |

Neither row closes at 200 MHz. Both longest paths start at IFU
`buf0_a[3]`, pass through compressed decode, the FP register file and
double-precision FMA operand logic, and end in `u_ffma_d/_30816_`, arriving
at 5.40 ns with debug disabled and 5.36 ns with debug enabled. The enabled
input-to-register minimum is the synchronous reset path to IFU `ins_pc[63]`.
It also has an input-to-output reset path to `debug_resume_ack_o`, with
**+0.7022 ns** slack. The disabled top has no input-to-output paths.
Electrical-limit violations remain in both rows, including high-fanout reset
nets. These are mapped timing estimates, not electrical or physical signoff.

Both core-only and debug constraints now time synchronous `rst` against the
core clock. The enabled constraints exempt only paths from external reset
ports to TCK-domain asynchronous reset pins. Registered reset-release
outputs retain their consumer recovery/removal checks. Bundled DMI payload
paths have maximum-delay bounds of 0.8 destination cycles; only first-stage
control D pins and asynchronous cross-domain hold checks are exempt.

The enabled mapping completed with identical before/after input fingerprints;
its starting manifest SHA-256 is
`80470a2ca7460d37d1604d73c0fc466577c0ad9b965ec8d632d40a3b2e39a5fb`.
Yosys reported 2,059.62 seconds and 23,079 MB peak memory. All 321 fingerprinted
inputs still matched after completion. The enabled setup-coverage report flags
only `trst_n` as having no input delay: it is an asynchronous reset input whose
paths to TCK asynchronous reset pins are explicitly exempt.

The disabled mapped netlist is unchanged as proven above; full OpenSTA
reporting was rerun under the corrected default SDC in 82.93 seconds with
identical before/after inputs. Its input coverage includes synchronous reset;
the setup-coverage report is empty.
Provenance is in `timing_off/log/sta-refresh.manifest.json`; current reports
are under `_build/syn_out/karudbg/{timing_off,timing_on}/reports/timing/`.

The reproducible conventional-top constraint command-model regression is
`make dbg-ooc-reset-constraints-test` (or
`tclsh test/dbg/test_ooc_reset_constraints.tcl`). It checks reset/clock/bundle
scope without Vivado and rejects broad-reset and released-reset-cut mutants,
plus three missing-stage/property/pin controls. A separate OpenSTA scope
check on the previous mapped netlist confirms timed synchronous reset and
retained reset-release paths (`_build/dbg/reset-timing-review/`). These scope
checks do not replace a current RTL mapping or physical timing validation.

## Routed VCU118 implementation — 2026-10-29

The standard `vcu118-ddr-sgmii-rom-rva23s64-dbg` flow completed with
`KARU_DBG_FULL`: autoexec, two address triggers and SBA. It uses Vivado
2026.1 build 6511674, eight threads, `ExtraTimingOpt` placement and
`AggressiveExplore` physical optimization. The standard post-route pass
closed the remaining setup violation; no additional RTL or flow change was
needed. All 149 captured production/boot inputs match before, after and at
final verification. This is the recorded working tree at HEAD `aa7fbe4`,
including uncommitted implementation changes, rather than a clean-commit build.

| Routed result | Value |
| --- | ---: |
| CPU clock | 75 MHz |
| Whole-design setup / hold slack | +0.010 / +0.011 ns |
| CPU setup / hold slack | +0.048 / +0.011 ns |
| Minimum pulse-width slack | +0.005 ns |
| Bus-skew constraints met | 16/16 |
| Minimum bus-skew slack | +2.141 ns |
| LUTs | 375,881 (31.79%) |
| Registers | 89,881 |
| Block-RAM tiles / DSPs | 317.5 / 29 |
| Bitstream DRC errors | 0 |

All constrained setup, hold and pulse-width paths pass. The tightest setup
margin is in the MIG's 300 MHz domain. The longest CPU path runs from vector
arithmetic `vs1_q_reg[3]` to FP-result register `f_relem_q_reg[23]`:
13.013 ns data-path delay, including 9.568 ns of routing. This is the
75 MHz routed result, separate from the unmet 200 MHz mapped-cell target.

The earlier October 27 base-debug image used 333,645 LUTs; this snapshot uses
375,881, a **12.66% increase**. Both use the same Vivado build, placement and
physical-optimization directives. The expanded common defines retain
RVA23S64, I-cache, Zvk/Keccak, DDR divide-by-four, SGMII/TAXI, vector
multiply/divide 16/64, lane/CWB staging and PMU support; the new explicit
feature define is `KARU_DBG_FULL`. The RTL checkpoint also changed from
`175b842` to this working tree, and the rebuilt U-Boot binary differs despite
the same version and boot command. Fu-boot, OpenSBI, DTB and staged boot-line
hashes are unchanged. No same-RTL base/full Vivado comparison was run, so the
cause of the LUT increase remains unisolated. It must not be presented as the
controlled NanGate45 feature increment of +0.3316%.

Evidence is `_build/fpga_rpt/vcu118_ddr_{timing,utilization,bus_skew}.rpt`,
the tagged reports under `_build/fpga_rpt/ddr_rva23s64_dbg_sgmii_75_rom__*`,
and `_build/vcu118_ddr_route.dcp`. The source/boot input hashes, actual defines,
report hashes, resources and output hashes are in
`vcu118_build_inputs.json`; `vcu118_full_verification.json`
records the independent final checks (both now in
`_build/fpga_archive/2026-10-29/`, since `_build/` holds the November 15
image). The packed ROM matches fu-boot,
OpenSBI, U-Boot, the profile DTB and 644-byte lab netboot command byte for byte,
including zero padding and the fixed offsets.

The new `_build/vcu118_ddr.bit` has SHA-256
`8c8ea6bd481b782f8c5f69699ca98de3e91e9f6c5fd63806db6a3eb450b14592`.
`make vcu118-program-bundle` produced `_build/vcu118_programming.tgz`
(14,208,769 bytes), SHA-256
`279d3319b8b4365481e786e711bf5317f2ff28069c3e66711d9da18216b01137`.
Its four members keep their `_build/...` paths: bitstream, probes, ROM
manifest and extracted control DTB. The DTB remains `d617ba56…0cec9`, matching
karudeb `a3e6b70`. The previous base bitstream and its hash metadata are
retained as `_build/vcu118_ddr.base-2026-10-27.bit` and
`_build/vcu118_build_inputs.base-2026-10-27.json`.

This image was never programmed into a board. The acceptance that was
pending when this section was written (physical USER4 transport, the
full-extension debugger, detach and a normal karudeb boot) was done on its
November 15 rebuild ([board acceptance](BOARD_ACCEPTANCE.md), 2026-11-16)
and on the November 18 image
([record](BOARD_ACCEPTANCE-2026-11-18.md)). See
[FPGA handoff](../doc/fpga.md#optional-karudbg-integration) for the native
pinned OpenOCD and the board acceptance instructions.

## ASIC initialization and memory scope

The base-debug post-review combined audit uses `KARU_ASIC` and reports **zero initialized
state**, **97,024 data-array bits**, nine macro candidates, two 1W2R register
files and four scratch arrays. The small Program Buffer adds one control
array to the core-only inventory (34 versus 33); constant lookup arrays
remain 14. The tracked core-only inventory is not replaced by this combined
report. Evidence is `_build/dbg/asic-audit-combined/summary.json` and its
source/define manifests, RTLIL and CSV/Markdown inventories.

The full-extension audit was refreshed on 2026-10-29 with `KARU_ASIC`,
`KARU_DBG` and `KARU_DBG_FULL`. It also reports **zero initialized state** and
**97,024 data-array bits**, with the same nine macro candidates, two register
files, four scratch arrays and 14 constant lookup arrays. Control arrays rise
from 34 in base debug to 37: trigger `address`, `control` and `napot_mask` are
64×2 each, 384 logical bits in total. Four slots double those logical control
bits without adding a data RAM port. Autoexec/SBA add scalar control registers;
the RF/cache/VRF macro interfaces remain unchanged. Exact source
hashes and before/after integrity records are in
`_build/dbg/asic-audit-full/manifest.json`, with generated inventories and
`summary.json` alongside it. This structural audit is separate from mapping.

Small mapping comparisons of the integer RF, FP RF and 1W1R/1W2R RAM leaves
show identical primitive-cell inventories with and without `KARU_ASIC`; ASIC
mode removes initialization attributes. This does not substitute for a full
`KARU_ASIC` area/timing comparison. Four-state memory checks and randomized
`vresv`, `vperm`, `vstart` startup checks are separate functional evidence.

## Reproduce

From the repository root, with tools on `PATH` and `KARU_LIB` pointing to the
typical NanGate45 Liberty:

```sh
make dbg-syn-area-off
make dbg-syn-area-on
make dbg-syn-timing-off
make dbg-syn-timing-on
python3 flow/asic/audit.py --manifest dbg/karudbg.f --top karudbg_top \
  --define KARU_DBG --out _build/dbg/asic-audit-combined
```

Outputs use `_build/syn_out/karudbg/`. Bound simultaneous full-vector Yosys
jobs by available RAM, including ABC subprocesses. Explicit overrides
are `DBG_SYN_DEFINES`, `DBG_SYN_ROOT` and `DBG_TCK_PS`. The conventional-JTAG
OOC and standard VCU118 board targets are documented in [README.md](README.md);
those implementations and board tests are not implied by these cell estimates.

For extension rows, use the maintained recipe with
`DBG_SYN_EXTENSION=base`, `autoexec`, `triggers`, `sba`, `full` or `full4`:

```sh
make DBG_SYN_EXTENSION=full dbg-syn-extension-area
make DBG_SYN_EXTENSION=full dbg-syn-extension-timing
make dbg-measurements-collector-test dbg-measurements-report
```

The collector reads `area_<row>` and `timing_<row>` under `DBG_SYN_ROOT`;
it does not start synthesis. It writes `measurements/measurements.json` and
`measurements/measurements.md` under that build directory. A row is reported
only after checking fresh reports, before/after fingerprints, current source,
tool and Liberty hashes, and the expected feature/clock configuration.
Missing or in-progress rows remain pending; stale or inconsistent rows supply
no current metrics. All twelve rows above are fresh mappings with exact raw
input equality; none uses the collector's separately verified historical
source-equivalence reuse mechanism. Deltas require the same non-feature
configuration, effective inputs, tools and library as the base row.
The kGE conversion uses the library's 0.798 µm² `NAND2_X1`; path-group minima
come from the CSV reports, while TNS comes from OpenSTA's full summary.
