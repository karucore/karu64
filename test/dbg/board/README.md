# Physical-board debug acceptance harness

These scripts drive the debug-enabled VCU118 image through a real JTAG
adapter and OpenOCD. They are the drivers of the
[2026-11-16 campaign](../../../dbg/BOARD_ACCEPTANCE.md), moved here from that
campaign's artifact directory so that they are version-controlled. Logs,
traces and results are written to an artifact directory under `_build`,
never here.

**Board coverage.** The current image is the one-ring image
`20f8b265…`. The acceptance phases, `rosc_count.py`, the capture scripts,
`seed_restart.py` and `entropy_fault.py` ran on it on November 23 and 24
([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-23.md)), and the entropy
scripts target it
([SP 800-90B assessment](../../../doc/sp800-90b-assessment.md)). The
fallback, four-ring image `ddb168e1…`
([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-20.md)), needs the capture
scripts and fixtures of commit `ace91d5` for its entropy tests.

The phases take the scratch addresses and the reset vector from the kind
of image under test ([Image kinds](#image-kinds)). On this board an SSH
connection takes 30 to 55 s and a reboot about 440 s; the defaults allow for it
(`KARU_BOARD_SSH_TIMEOUT` 180 s, reboot and boot waits 900 s, the evidence
copy of `post_linux_host.py` 900 s). Ask for the reset button by its label,
`CPU_RESET`: PROG clears the FPGA's configuration.

The phases halt and reset the hart and overwrite scratch SRAM and DRAM. Sync
Linux first. Keep one hardware controller active: stop Vivado `hw_server`
and any other OpenOCD.

## Configuration

Everything host-specific comes from the environment; the defaults are the
lab's.

| Variable | Default | Used for |
| --- | --- | --- |
| `KARU_BOARD_OUT` | `_build/dbg/board-accept` | Artifact directory: fixture binaries, traces, results |
| `KARU_BOARD_RPC` | `127.0.0.1:6666` | OpenOCD Tcl RPC endpoint (scripts and `*.cfg`) |
| `KARU_BOARD_GDB_REMOTE` | `127.0.0.1:3333` | OpenOCD GDB server (scripts and `*.cfg`) |
| `KARU_BOARD_ADAPTER_CFG` | `interface/ftdi/digilent_jtag_smt2_nc.cfg` | Adapter script sourced by `server.cfg` and `linux-server.cfg` |
| `KARU_BOARD_TARGET_CFG` | `dbg/vcu118.cfg` | Board and target script sourced by the same |
| `KARU_BOARD_GDB` | `$RISCV/bin/riscv64-unknown-elf-gdb` | GDB binary (`gdb_phase.py`) |
| `KARU_BOARD_IP` | `192.168.42.10` | Board Linux address (SSH phases) |
| `KARU_BOARD_SSH_KEY` | `../karudeb/configs/ssh/karudeb_lab_ed25519` | Lab SSH key, by path only |
| `KARU_BOARD_KARUDEB` | `../karudeb` | karudeb checkout: kernel Image, selftests |
| `KARU_BOARD_SELFTESTS` | `$KARU_BOARD_KARUDEB/build/selftests-7.2.4` | Prebuilt Linux selftests copied to the board. The default is the November 16 campaign's build; point it at a build that matches the kernel in use |
| `KARU_BOARD_TFTP_IMAGE` | `/srv/tftp/Image` | Kernel Image the board boots |
| `KARU_BOARD_KERNEL_BUILD` | `$KARU_BOARD_KARUDEB/build/linux-riscv64-karu64-rva23s64` | Kernel build tree of the served Image: `System.map`, `kernel.release`, `Image` |
| `KARU_BOARD_KERNEL_IMAGE` | `Image` of that build | Local Image compared with the served one |
| `KARU_BOARD_KERNEL_LOAD_PA` | `0x80200000` | Physical address at which the Image is loaded |
| `KARU_BOARD_KERNEL_BP_SYMBOL` | `__riscv_sys_getpid` | Live-kernel breakpoint symbol, looked up in `System.map` |
| `KARU_BOARD_KERNEL_BP_VA`, `_PA` | from the symbol | Explicit breakpoint address instead of the lookup |
| `KARU_BOARD_EXPECT_KERNEL` | `kernel.release` of that build | Kernel release the board must report |
| `KARU_BOARD_REMOTE_DIR` | `/root/debug-accept` | Working directory on the board |
| `KARU_BOARD_IMAGE` | `rom2m-auth` | Kind of image on the board: `rom2m-auth`, `rom2m` or `rom1m`. Gives the scratch SRAM addresses and the reset vector; see [Image kinds](#image-kinds) |
| `KARU_BOARD_SCRATCH`, `KARU_BOARD_SCRATCH_SIZE`, `KARU_BOARD_RESET_PC` | from the image kind | Scratch SRAM base and size, and reset vector, of an image that is none of the kinds |
| `KARU_BOARD_SOAK_SECONDS` | `600` | Soak duration |
| `KARU_BOARD_REBOOT_CYCLES`, `KARU_BOARD_REBOOT_TIMEOUT` | `3`, `900` | Reboot count and seconds allowed per boot (`linux_reboot.py`) |
| `KARU_BOARD_SSH_TIMEOUT` | `180` | Seconds allowed for one SSH command in `linux_reboot.py` and `auth_phase.py`; a connection to the board takes 30 to 55 s |
| `KARU_BOARD_UART_LOG` | `_build/boot.log` | Running UART capture; `linux_reboot.py` looks for the boot ROM and OpenSBI banners in it |
| `KARU_BOARD_REBOOT_UART` | `1` | `0` drops the banner check: the result then shows a Linux restart only |
| `KARU_BOARD_GETNOISE_K` | `1,2,4,8,16,32` | Decimations k captured by `getnoise_capture.py`, one capture each |
| `KARU_BOARD_GETNOISE_COUNT` | `1000000` | Raw symbols per capture |
| `KARU_BOARD_GETNOISE_MIN_RUN` | `4096` | A capture fails if its longest run of consecutive symbols is shorter |
| `KARU_BOARD_GETNOISE_ADDR` | `0x88000000` | Where the capture payload is loaded in DDR; its buffer starts 64 KiB above |
| `KARU_BOARD_BURST_PERIODS` | `1,2,4,8,16,32,64,128,256` | Sampling periods, in clock cycles, captured by `getnoise_burst.py`, one capture each |
| `KARU_BOARD_BURST_COUNT` | `32` | Bursts per period |
| `KARU_BOARD_BURST_ADDR` | `0x88000000` | Where the burst payload is loaded in DDR; its buffer starts 64 KiB above |
| `KARU_BOARD_BURST_CLOCK_HZ` | `75000000` | The hart's clock, recorded in the sidecar and used for the waits |
| `KARU_BOARD_BURST_NOTE` | empty | Free text for the sidecar: bitstream, reset history, link state, temperature |
| `KARU_BOARD_ROSC_SETTINGS` | `256x1,256x4,256x16,256x64` | Settings of `rosc_count.py`, one capture each per ring mask: clocks per raw sample (1 to 256) x raw samples per record (1 to 65,536). The defaults give a record every 256, 1,024, 4,096 and 16,384 clocks |
| `KARU_BOARD_ROSC_COUNT` | `1000000`; `400000` at 16,384 clocks or more | Records per setting: one number for all settings, or one per setting. A capture that is to carry a bound needs 300,000 usable records (below) |
| `KARU_BOARD_ROSC_SCALE` | `1` | A factor on every record count, the defaults or those of `KARU_BOARD_ROSC_COUNT` and `KARU_BOARD_ROSC_DIRECT_COUNT`: `0.1` takes a tenth of the records in a tenth of the time. The bursts are not scaled |
| `KARU_BOARD_ROSC_MASKS` | `0x0f,0x3f` | Ring masks, each captured with every setting: ring r in bit r, rings 0 to 3 the lanes, 4 and 5 the reference rings. The defaults: the rings of normal operation first, then all six as the cross-check |
| `KARU_BOARD_ROSC_DIRECT_COUNT` | `100000` | Records of each capture in direct mode, the cross-check of the divider: one per ring mask, at the first setting with a record every 1,024 clocks (the first setting, if there is none). `KARU_BOARD_ROSC_SCALE` applies. `0` for none, which also leaves out the count bursts in direct mode |
| `KARU_BOARD_ROSC_BURSTS` | `4` | Bursts of each ring's count, one value per clock, for each of the six rings, each of the two views of its count and each way of counting, with all six rings on; `0` for none |
| `KARU_BOARD_ROSC_REF_BURSTS` | `32` | Bursts of the reference bits per sampling period, with all six rings on; `0` for none. `KARU_BOARD_ROSC_SCALE` does not apply |
| `KARU_BOARD_ROSC_REF_PERIODS` | `1,2,4,8,16,32,64` | Sampling periods, in clocks, of the bursts of the reference bits |
| `KARU_BOARD_ROSC_MAX_LOSSES` | `16` | Losses after which a capture still goes on with a new run (at most 47); one more fails it |
| `KARU_BOARD_ROSC_ADDR` | `0x88000000` | Where the meter payload is loaded in DDR; its buffer starts 64 KiB above (16 MB for a million records) |
| `KARU_BOARD_ROSC_CLOCK_HZ` | `75000000` | The hart's clock, recorded in the sidecar and used for the waits |
| `KARU_BOARD_ROSC_WAIT` | from the sizes | Seconds to wait for one capture before the hart is halted |
| `KARU_BOARD_ROSC_NOTE` | empty | Free text for the sidecar: bitstream, straps, reset history, link state |
| `KARU_BOARD_GETNOISE_WAIT` | from count and k | Seconds to wait for one capture before the hart is halted |
| `KARU_BOARD_GETNOISE_NOTE` | empty | Free text copied into each capture's sidecar: bitstream, board, temperature |
| `KARU_BOARD_AUTH_CASE` | none | The one case `auth_phase.py` runs; see [Authentication](#authentication) for the names and the other `KARU_BOARD_AUTH_*` settings |

The Linux phases name no kernel version. The expected release and the
live-kernel breakpoint address come from the kernel build tree, which must be
the build of the Image the board boots; `linux_kernel_bp.py` compares the two
Images before it uses `System.map`.

## Image kinds

The scratch SRAM (64 KiB) starts directly above the boot ROM, and the hart
starts in the authentication island when the image has one. The images that
exist differ in both, so the harness has to be told which kind is on the
board:

| `KARU_BOARD_IMAGE` | Image | Scratch SRAM | Reset vector | Fixture at |
| --- | --- | --- | --- | --- |
| `rom2m-auth` (default) | The default debug image (`KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR`): 2 MiB boot ROM | `0x201000`–`0x210fff` | `0x10000`, the authentication island, in every lifecycle | `0x208000` |
| `rom2m` | A debug image built without `KARU_DBG_AUTH`, for example `VCU118_DBG_EXT_DEFINES=KARU_DBG_FULL`: 2 MiB boot ROM | `0x201000`–`0x210fff` | `0x1000` | `0x208000` |
| `rom1m` | Images built before 2026-11-17, with the 1 MiB boot ROM: bitstream `d5e603cd…`, the board-accepted `0b994847…` | `0x101000`–`0x110fff` | `0x1000` | `0x108000` |

The table is `IMAGES` in `boardlib.py`, the one place that holds it. The
kind decides two things:

- **Scratch addresses.** Every scratch address a phase uses is the scratch
  base plus a fixed offset (`AREAS` in `boardlib.py`). On `rom1m` these are
  the addresses of the 2026-11-16 campaign; on the 2 MiB map each is 1 MiB
  higher. On the 2 MiB map the old addresses are ROM.
- **Reset vector.** After a reset-halt the DPC must equal the reset vector
  exactly; that is the evidence that the hart halted before its first
  instruction (`baremetal_phase.py`, `extended_phase.py`,
  `clean_detach_boot.py`).

**The fixture is linked for one map.** `make dbg-board-fixture` asks
`boardlib.py` for the address, so it follows `KARU_BOARD_IMAGE` from the
environment, or `DBG_BOARD_IMAGE=<kind>` on the command line. Export the
setting once and the fixture and the phases agree. `rom2m-auth` and `rom2m`
share a fixture; `rom1m` needs its own.

A fixture phase refuses to start, before it sends anything to the target,
if the fixture in the artifact directory is linked for another map, is
missing, is too long, or if an area would lie outside the scratch SRAM. The
message gives both addresses and the command that builds the right fixture.

For an image that is none of the three, set `KARU_BOARD_SCRATCH` and
`KARU_BOARD_RESET_PC`; `make dbg-board-fixture` reads `KARU_BOARD_SCRATCH`
too (or `DBG_BOARD_SCRATCH=`). A fourth kind, `sim`, is the simulated target
of the rehearsal, which `rehearse.py` selects itself.

The phases do not authenticate. On a `rom2m-auth` image they need lifecycle
`OPEN` (DIP switches 1 and 2 off). The reset-halt check against a hart that
starts at `0x10000` passed on the board on 2026-11-18; the rehearsal's
target starts at `0x80000000`.

## Running a campaign

Run everything from the repository root. Use a fresh artifact directory per
campaign, for example `export KARU_BOARD_OUT=$PWD/_build/dbg/board-accept-$(date +%Y%m%d)`.
Keep one host process on the console port for the whole session
([test plan](../../../dbg/BOARD_TEST_PLAN.md)): a boot froze on 2026-11-20
after the port changed hands while the kernel was printing. A wrapper that
runs phases needing an examined hart (stages C and D, and `linux_kernel_bp.py`)
should stop when OpenOCD fails to examine the target, rather than run the
later phases against it. This does not apply to `auth_phase.py`:
`auth-server.cfg` defers examination on purpose, and a refused examine of
a locked target is one of its passing checks.

1. Select the kind of image on the board, for example
   `export KARU_BOARD_IMAGE=rom2m-auth`, and build the fixture for it into
   the artifact directory:
   `make dbg-board-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`
2. Start OpenOCD and wait for `BOARD_ACCEPT_SERVER_READY`:
   `openocd -f test/dbg/board/server.cfg`
3. Run the phases one at a time, in this order. Never run two at once.

| # | Script | Needs | Notes |
| --- | --- | --- | --- |
| 1 | `linux_phase.py` | Linux running | Leaves Linux running |
| 2 | `baremetal_phase.py` | — | Reset-halts, with the DPC at the image kind's reset vector, and loads the fixture; later phases reuse it |
| 3 | `extended_phase.py` | fixture | |
| 4 | `gdb_phase.py` | fixture, GDB | |
| 5 | `transport_phase.py` | fixture | Uses the XCVU9P outer IR value |
| 6 | `translation_phase.py` | fixture | Expected to FAIL with a pristine OpenOCD (software page walker) |
| 7 | `runcontrol_phase.py` | fixture | |
| 8 | `privilege_phase.py` | fixture | |
| 9 | `crypto_aperture_phase.py` | fixture | |
| 10 | `soak_phase.py` | fixture | `KARU_BOARD_SOAK_SECONDS` |
| 10a | `getnoise_capture.py` | fixture; image built with `KARU_ZKR`; DIP switch 4 off; `make dbg-getnoise-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT` | Optional, not an acceptance phase: raw noise capture, see [Noise capture](#noise-capture-getnoise) |
| 10b | `getnoise_burst.py` | fixture; image with the burst capture block; DIP switch 4 off; `make dbg-getnoise-burst-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT` | Optional, not an acceptance phase: bursts of raw noise at sampling periods of 1 to 256 clocks, see [Burst capture](#burst-capture) |
| 10c | `rosc_count.py` | fixture; image with the meter (the next image, [board test plan, section 7](../../../dbg/BOARD_TEST_PLAN.md#7-the-next-image-one-ring-for-seed)); DIP switch 4 off; `make dbg-rosc-count-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT` | Optional, not an acceptance phase: the edge counts of the six rings, and bursts of the reference rings' bits, see [Meter capture](#meter-capture). About an hour and 45 minutes with the default settings, nearly all of it reading the records back; `KARU_BOARD_ROSC_SCALE=0.1` for a quarter of an hour |
| 11 | `clean_detach_boot.py` | `linux-server.cfg` | Restart OpenOCD with `linux-server.cfg` first. Reset-halts, with the DPC at the image kind's reset vector, then reboots normally and shuts OpenOCD down |
| 12 | `post_linux_host.py` | Linux over SSH | Copies and runs `post-linux.sh` on the board, collects evidence |
| 13 | `complete_crypto.py` | Linux over SSH | Completes the OpenSSL matrix if step 12 timed out; gives the matrix verdict |
| 14 | `linux_kernel_bp.py` | `linux-server.cfg`, Linux | Live kernel breakpoint; shuts OpenOCD down |
| 15 | `linux_reboot.py` | Linux over SSH, the UART capture, no OpenOCD; debug image `d5e603cd…fd9b2` or later | Software reboot, three times by default: Linux must restart, and the console must show the boot ROM and OpenSBI starting again. First run on the board 2026-11-18 |
| 16 | `linux_zkr.py` | Linux over SSH, no OpenOCD; image with `KARU_ZKR` and the `rva23s64-zkr-ddr` tree | Zkr discovery: the booted device tree and `/proc/cpuinfo` list `zkr`, and the kernel log has no archrandom error. `KARU_BOARD_ZKR=0` checks the fallback tree instead. It shows discovery, not that `seed` delivered words. First run on the board 2026-11-18 |
| 17 | `auth_phase.py` | `auth-server.cfg`, started afresh after the CPU reset button; image kind `rom2m-auth`; switches per case | Debug authentication, one case per run (`KARU_BOARD_AUTH_CASE`); see [Authentication](#authentication). Shuts OpenOCD down. First run on the board 2026-11-18 |

Invoke each as `python3 test/dbg/board/<script>`. Phases 1 to 16 assume
all four DIP switches off: lifecycle `OPEN`, no hold, entropy source on.

## Reading results

- **Exit status.** Each script exits 0 only if every case it ran passed and
  every restore step and its cleanup succeeded. A phase keeps running after a failed case, so the
  exit status and the per-case results are both needed: `<phase>-results.json`
  has one entry per case, `<phase>-commands.jsonl` every OpenOCD command and
  reply.
- **Translation phase.** Its non-zero exit with a pristine OpenOCD is the
  known tool defect, not a regression; `translation-issues.txt` lists the
  unsafe results.
- **Post-Linux.** `post_linux_host.py` follows the board's `status.tsv`.
  A timed-out OpenSSL matrix makes it exit non-zero; `complete_crypto.py`
  then completes the matrix and writes `openssl-matrix-result.json`.
- **Check counts** are host assertions, often word comparisons. They are
  not counts of specification requirements.

## What the cases do and do not show

- **Autoexec** (`baremetal_phase.autoexec`) counts executions with a Program
  Buffer increment: one per read and per write of the selected register,
  none for reads or writes of the other nine, none for either once the bit
  is cleared.
- **Coherence** (`extended_phase.coherence`) halts the hart to patch code.
  It shows that stale I-cache and D-cache contents are not used after an SBA
  write. It does not isolate invalidation of prefetched instructions on a
  running hart; there is no board test of that.
- **Transport** checks external effects and recovery of truncated frames.
  It cannot count internal DMI requests.
- **Reboot** (`linux_reboot.py`) makes two separate checks. A vanished
  marker, a new boot ID and a short uptime show that Linux restarted; a
  kexec would pass those too. A fu-boot banner followed by an OpenSBI banner
  on the UART capture shows that the restart went through the boot ROM. If
  the capture is not available the script fails, unless it is told to check
  the Linux restart alone, and it then says so in its result.

## Noise capture (GetNoise)

`getnoise_capture.py` takes raw symbols from the entropy source through the
`mnoise` CSR (the GetNoise test interface; contract in the header of
`rtl/karu_entropy.v`), and `getnoise_analyze.py` evaluates the files offline.
Both ran on the board on 2026-11-18 ([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-18.md#noise-capture)); `make dbg-getnoise-test` is their simulation test.

**Needs.** An image built with `KARU_ZKR`: only such an image has the
entropy source. Of the [image kinds](#image-kinds), `rom2m-auth` has it by
default; a `rom2m` image has it only if `KARU_ZKR` was among its defines
(`VCU118_DBG_EXT_DEFINES=KARU_DBG_FULL` alone gives none); the `rom1m`
images named there were built before the entropy source existed. Without
it the payload stops with status `TRAP` at its first CSR access. The
capture runs in DRAM and is the same on every map, but the phase is a
fixture phase and needs the fixture of the selected image kind. DIP switch
4 off (on holds the source off, and the capture ends with status
`TIMEOUT`). Switching the source off during a capture ends the run (the
loss flag), and so does a write to the burst block's sampling period
(`0x1000_0848`); nothing in the capture phases changes it within a run. The hart in the
state `baremetal_phase.py` leaves it in: reset-halted, fixture loaded. The
payload built into the artifact directory:
`make dbg-getnoise-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`. A reset clears a
locked `mentropycfg`; nothing else does.

**What it does.** The phase loads `getnoise.S` into DDR. For each k in
`KARU_BOARD_GETNOISE_K` it writes the parameter block and runs the payload
in M-mode until its `ebreak`. The payload saves `mentropycfg`, sets the
interval to k-1 with the other fields unchanged, enters test mode, and takes
one symbol per `csrrw` until it has the requested number. It then leaves
test mode and writes `mentropycfg` back, on every path that changed them;
a locked source, or one already in test mode, is refused untouched. While
the payload runs, `seed` is in `BIST`. When the source reports a lost
symbol the run ends: that poll's symbol is dropped and the next one starts
a new run. Runs are never joined. If the host gives up waiting and halts
the hart, the source may be left in test mode until the next reset.

**Output**, in the artifact directory:

| File | Content |
| --- | --- |
| `getnoise-k<k>.bin` | One byte per symbol, in capture order: bits [3:0] the symbol (lane i in bit i, one sampled ring per lane), bit 7 on the first symbol of a run. No bit is combined with another |
| `getnoise-k<k>.json` | k, symbols requested and stored, run lengths, losses, polls, `mentropycfg` before, during and after, the cutoffs and failure settings it holds, SHA-256 of the `.bin` and of the payload, time, `KARU_BOARD_GETNOISE_NOTE`, and the temperature readout (`0x1000_0860`: die temperature, VCCINT, VCCAUX; zero on images built before 2026-11-19) before and after, raw and decoded. The phases record no bitstream identity; put it in the note |
| `getnoise-results.json`, `getnoise-commands.jsonl` | Case results and OpenOCD trace, as for every phase |

A capture fails, and the phase exits non-zero, on a payload status other
than `OK` (`LOCKED`, `BUSY`, `TIMEOUT`, `TRAP` and so on, named in the case
detail), if the run flags in the buffer disagree with the payload's
counters, if `mentropycfg` was not restored or test mode not left, and if
the longest run is shorter than `KARU_BOARD_GETNOISE_MIN_RUN`.

**Analysis.** `python3 test/dbg/board/getnoise_analyze.py $KARU_BOARD_OUT/getnoise-k*.bin`
writes `getnoise-analysis.txt` and `getnoise-analysis.json` next to the
captures. It needs only the files. The model is that of arXiv:2102.02196: a
lane has a frequency F, a duty cycle D and a jitter variance sigma^2 per
sample, and decimation k gives the same process with k sigma^2.

- Per lane and per k: ones fraction (an estimate of D); longest repetition
  and largest adaptive-proportion window count, for the two cutoffs;
  autocorrelation inside runs; a least-squares fit of (F, sigma^2) to the
  autocorrelation, with a range for sigma^2. When no autocorrelation is
  left the fit gives a lower bound on sigma^2 only.
- Per bit of a lane, as -log2 of a guessing probability, each with a lower
  end (the probability at the upper end of a 99% interval):
  - the bias cap, from the ones fraction alone. A lane with 75% ones is
    worth at most 0.415 bits per bit, whatever else is true of it;
  - a predictor cap: how often a table built on the first half of the
    capture guesses a bit of the second half from the twelve bits before;
  - the model figure: the chance of guessing a bit from the previous phase,
    with the measured D and the fitted sigma^2. It is never taken above
    the bound p_e <= 1 - tanh(pi sigma)/2, which assumes D = 1/2 and is
    printed for reference only;
  - the estimate is the smallest of the three.
  The model figure is refused when the model does not fit: when a measured
  autocorrelation lies more than five standard errors from the fitted
  model at any computed lag, when the serial correlation has not died out
  by the last lag (use more `--lags`), or when the predictor guesses more
  bits than the model allows anyone.
- Across captures: whether sigma^2 grows in proportion to the spacing of
  the samples in clocks, which is the period times k (256 k for the
  captures through `mnoise`, the period for bursts).
- For samples close together, where sigma^2 per sample is small and the
  autocorrelation runs over hundreds of lags (for the burst captures; it
  applies to every capture):
  - a fit of (F, sigma^2) per window, at lags up to an eighth of the
    window, found from short lags outwards. Every run is a window; a run
    longer than `--window` (32,768) is cut. The report gives the median and
    the spread of F and of sigma^2 over the windows;
  - the same fit on the autocorrelation pooled over the windows. A ring's
    frequency wanders with temperature and supply, and pooling windows of
    different F makes the correlation die sooner, which looks like more
    jitter than there is. The ratio of the pooled to the per-window
    sigma^2 shows it, with the spread of F between windows, its drift
    against the bursts' time stamps, and sigma^2 by the largest lag used;
  - the sigma^2 behind the per-bit model figure is the per-window one, from
    the lag range that gives the smallest well-determined value, and its
    lower end is the smallest lower end of all the fits. The report says
    which was used. Wander must not raise the figure;
  - a spectrum per lane, from the autocorrelation: the lines that the
    fitted model explains, and any others as spurs;
  - for each lane pair, the coherence of the two lanes, from their
    cross-correlation pooled over the windows: a phase relation that
    repeats in every burst (locking), which the fixed-lag statistics miss;
    and the correlation of the two lanes' per-window frequencies (shared
    wander);
  - between captures with the same spacing, for example a burst capture
    at 256 clocks and a k = 1 capture: whether ones fraction and
    autocorrelation agree.
- Across lanes, kept apart from the per-lane figures: correlation,
  chi-square and mutual information for the six lane pairs at lag 0 and
  small lags, with a z score that allows for each lane's serial
  correlation, and the total correlation of the four lanes. Dependent lanes
  are flagged. Four lanes that each look fine may still be dependent, so a
  per-lane figure is never a figure for a symbol or a word.
- The empirical distribution of 4-bit symbols and of 16-bit words (four
  consecutive symbols), its most frequent value and -log2 of its frequency,
  next to what a uniform source would show with the same sample size. For
  words there is a predictor cap as well: how often the lane tables, run
  four bits ahead, get all sixteen bits of a word right.

What it does not show: that the model holds (a fit that is not refused has
passed the checks above, no more); independence of the lanes (rings of
different frequency that share jitter pass the pair statistics; the
coherence and the shared wander each see one kind of dependence more, not
all); how well a word can be predicted by anything better than the lane
tables.

Limits of the long-lag fit, from the self-test on generated data
(`test_burst_analysis.py` has the measured figures):

- With 16 bursts of 32,768 symbols the sigma^2 used is within about 5 to
  6% of the truth at 1e-2 and 1e-3 per sample, 12% at 1e-4, 25% at 1e-5
  and 35% at 1e-6; F within 1e-3 to 1e-5. At 1e-7 nothing is determined, and above
  about 0.05 F is not.
- A lane whose correlation outlasts an eighth of a window (sigma^2 below
  about 4e-5 at 32,768 symbols) gets F and sigma^2 but no per-bit model
  figure: it is refused, because the lags do not reach.
- Wander inside a burst raises the all-lag sigma^2; the value used is less
  exposed, not immune (a frequency ramp of 4e-3 across a burst raised it
  by a quarter).
- Coherence and shared wander need many windows: with 16 bursts the
  coherence threshold is 0.69, with 32 it is 0.46, and shared wander below
  a correlation of about 0.7 is not flagged with 32.
- Bursts joined into one run are refused when the sidecar is there. In a
  bare file with bursts shorter than `--window` they are not noticed and
  make sigma^2 look larger. Keep the sidecars with the captures.

It gives no verdict on whether the entropy is sufficient unless thresholds
are passed, and a verdict is made on the lower end of what was measured,
never on a formula alone:

| Option | Met when |
| --- | --- |
| `--min-lane-bits X` | Every lane's model fits, and the lower end of its estimate is at least X. A lane whose bias alone rules X out fails, and the reason names the caps |
| `--min-word-bits X` | The smaller of the word distribution's figure (99% bound) and the word predictor cap's lower end is at least X |
| `--require-independent` | Nothing is flagged, coherence and shared wander included, and the capture is large enough to have flagged a correlation of `--max-undetected-phi` (0.05) |

The self-test keeps a case for each way a verdict could pass wrongly: a
lane whose bias makes the threshold impossible, a word figure from the
distribution of single words alone, and independence for want of data.

**The capture loop keeps up at k = 1 on the board** (10^6 symbols in one
run, no losses). In simulation an idle poll takes about 32
clocks, and the loop takes every symbol at 128 clocks per symbol (the
self-test checks this; 64 clocks also worked when measured once). The board
has 256 clocks per symbol at k = 1; there the loop polled about every 34
clocks. The run lengths in the sidecar show it either way.

## Operational restart data and induced failures

Both need an image with `mentropystat` whose `seed` delivers one lane (image
`20f8b265…`; `ddb168e1…` delivers four lanes and needs the scripts as they
are at commit `ace91d5`), lifecycle `OPEN`,
the entropy source on (SW12 all off), `server.cfg`, and the fixtures of
`make dbg-board-fixture dbg-seedcap-fixture`. Both reset the SoC, so read
`mentropystat` first if the interval before them matters.

**`seed_restart.py`** collects the operational restart data of SP 800-90B
section 3.1.4: `KARU_BOARD_SEEDRESTART_COUNT` (1,000) restarts, and after
each the first `KARU_BOARD_SEEDRESTART_SAMPLES` (1,000) samples the source
delivers through `seed`. A sample is one bit, of the lane that
`mentropystat` names as the source, and a word holds sixteen: 63 words are
read per restart and their first 1,000 bits kept. A restart is a debugger
reset (`ndmreset`), which
resets the hart, the SoC and the entropy source and gates the rings off;
the hart is held by `haltreq` and halts before its first instruction (the
phase checks DPC), so the boot ROM never runs. Through raw DMI writes the
phase then points DPC at `seedcap.S`, already in DRAM, and resumes, about
6 ms after the reset is released. `seedcap.S` reads `seed` in the reset
configuration, without test mode, and stores the words from the first
`ES16` on. It shows that it was in time (it polled `BIST` before the first
`ES16`) and that it kept up (its longest gap between polls is under one
word); a restart that fails either check, or ends in a health-test alarm,
is recorded with its reason and repeated. Output: `seed-restart-rows.bin`
(one sample per byte, 0 or 1, row after row, the first sample of a word
from its bit 15), `seed-restart-words.bin` (the words as read) and
`seed-restart.json`. Run `ea_restart` on the rows, as a binary source.
`make dbg-seedcap-test` checks the payload on the simulation bench: it
stores exactly the first samples after the start-up test, in order, and
reports a late start, `DEAD` and an alarm.

**`entropy_fault.py`** shows the failure handling on the real rings.
Software may only make the tests stricter, and a cutoff far below the reset
value makes the real source fail that test within seconds. The cases, each
from a debugger reset (`KARU_BOARD_FAULT_CASES` selects some):
`startup` (a start-up failure is fatal at once and raises no alarm),
`each` (each of the two tests fires and `mentropystat` names it, with the
source's lane and the lags), `strikes` (the alarm stays until one `seed`
access has
seen it, a `mentropycfg` write clears neither the alarm nor the strike, the
third running failure is fatal and `seed` reports `DEAD`), `forgive` (2^24
clean samples, about 16 minutes at k = 16 and in proportion to k, clear a
strike) and `limits` (weaker
values are replaced by the build's limits, the spacing outside test mode
stays at the floor that `mentropystat` shows, k = 16 unless the image's
strap raises it, measured through `seed`, and the lock freezes the CSR until
reset). It leaves the hart halted after a reset.

## Burst capture

`getnoise_burst.py` records raw symbols with the rings sampled every 1 to
256 clock cycles, which `mnoise` is too slow for: the capture block next to
the noise source (`flow/fpga/karu_noise_burst.v`) sets the sampling period
and records 32,768 consecutive symbols per burst in block RAM, and the
payload copies each burst out. It ran on the board on 2026-11-19, eight
runs ([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2));
`make dbg-getnoise-burst-test` is its simulation test.

**Needs.** An image with the capture block (`KARU_ZKR`); in an image
without it the phase stops at its first case with "no capture block in
this image". DIP
switch 4 off. The hart reset-halted with the fixture loaded, as for
`getnoise_capture.py`. The payload built into the artifact directory:
`make dbg-getnoise-burst-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`.

**What it does.** The phase first reads the capture block's status register
(`0x1000_0840`) through the debugger: it must identify the block, be at
rest, and show the noise source enabled. It then loads `getnoise_burst.S`
into DDR. For each period in `KARU_BOARD_BURST_PERIODS` the payload, in
M-mode, enters the entropy source's test mode, writes the period, and for
each burst starts a capture, waits for it, and copies the 2,048 words to
the buffer with the clock-cycle count before and after. It leaves test
mode on every path that entered it; that puts the sampling period back at
256 clocks, forgets the recording and restarts the start-up test of
`seed`. `mentropycfg` is not written; a locked source, or one already in
test mode, is refused untouched. While the payload runs, `seed` is in
`BIST`.

**Output**, in the artifact directory:

| File | Content |
| --- | --- |
| `getnoise-burst-p<P>.bin` | One byte per symbol, as in `getnoise-k<k>.bin`: bits [3:0] the symbol, bit 7 on the first symbol of a burst. One run per burst. Inside a burst the symbols are consecutive samples P clocks apart; nothing is known about the samples between two bursts |
| `getnoise-burst-p<P>.json` | `kind` `burst`, the period, `k` = 1, the clock, bursts and symbols per burst, the clock-cycle stamps at the start and end of every burst, the status register before and after, `mentropycfg`, SHA-256 of the `.bin`, of the raw records and of the payload, time, `KARU_BOARD_BURST_NOTE`, and the temperature readout before and after, raw and decoded |
| `getnoise-burst-results.json`, `getnoise-burst-commands.jsonl` | Case results and OpenOCD trace, as for every phase |

A capture's files replace the previous ones only when both are complete;
a failed capture leaves the earlier files in place. A capture fails, and
the phase exits non-zero, on a payload status other
than `OK` (`LOCKED`, `BUSY`, `NOBLOCK`, `ABORTED`, `TIMEOUT`, `TRAP` and so on, named
in the case detail), if test mode was not left, if the capture block still
holds something afterwards, if the period read back is not the one asked
for, and if a burst's stamps are closer together than its symbols take or
further apart than they need (the source paused).

**Analysis.** The same `getnoise_analyze.py`, on the burst files, alone or
together with `getnoise-k*.bin` files; it takes the period from the
sidecar. See [Noise capture](#noise-capture-getnoise) for what it reports.

## Meter capture

`rosc_count.py` records how many periods each of the six rings has made, at
regular clock intervals: the four lanes (3, 5, 7 and 9 inverters) and the
two reference rings (3 inverters, like lane 0). The meter next to the noise
source (`flow/fpga/karu_rosc_meter.v`, registers at `0x1000_0868`) keeps a
running total per ring, modulo 2^20, and at every `every`-th raw sample
takes a record: the six totals and the four lane bits of one clock edge.
From a series of records the analysis has each ring against the clock and
every pair of rings against each other. The November 23 session used this
meter on image `20f8b265…`; `make dbg-rosc-count-test` is its simulation
test.

**The unit of a count is two ring periods.** A ring is too fast to clock a
flip-flop, so the meter's counters count each ring divided by two, and
every total in a record is in counts. Nothing in a `.bin` is multiplied:
the records are as read, and `count_unit` in the sidecar, 2, says what a
count is. Whoever reads the totals multiplies by it.

**Needs.** An image with the meter; an image with the burst capture block
but without the meter fails every capture with status `NOMETER`, and one
without the block stops at the first case. DIP switch 4 off. The hart
reset-halted with the fixture loaded, as for `getnoise_capture.py`. The
payload built into the artifact directory:
`make dbg-rosc-count-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`.

**What it does.** The phase checks the capture block's status register as
`getnoise_burst.py` does and loads `rosc_count.S` into DDR. Then, for each
ring mask in `KARU_BOARD_ROSC_MASKS` and each setting in
`KARU_BOARD_ROSC_SETTINGS`, the payload, in M-mode, enters the entropy
source's test mode, writes the sampling period, the ring mask and `every`,
starts the meter with a second write, and for each record polls `DATA0`
until it is valid, reads `DATA1`, which hands the record over, and stores
both words. The meter holds one record and never overwrites it. If the
payload is late, the meter drops the next record and sets its loss flag;
the payload then ends the run, writes the start bit again and begins a new
run with the next record. Runs are never joined, and after
`KARU_BOARD_ROSC_MAX_LOSSES` losses one more fails the capture. Before the
capture the payload takes two records that it does not keep: the first
pass through its record loop is fetched from memory and takes longer than
a record may wait. The payload leaves test mode on every path that entered
it, which puts the sampling period and the rings back and restarts the
start-up test of `seed`. `mentropycfg` is not written; a locked source, or
one already in test mode, is refused untouched. While the payload runs,
`seed` is in `BIST`.

**Direct counting, a diagnostic mode.** With CTRL[28] of the meter the
counters are clocked by the rings themselves and a count is one ring
period. For the fastest rings that is outside what the part guarantees for
a flip-flop, so it is no way to measure: a capture in direct mode is a
diagnostic and never carries a bound. It is there as a cross-check of the
divider on the board, where the two ways of counting must give totals in
the ratio 2. For the first setting with a record every 1,024 clocks, and
each ring mask, the phase takes one capture of `KARU_BOARD_ROSC_DIRECT_COUNT`
records in direct mode, just before the divided capture of that setting so
that the two are close in time. Its files are named `rosc-direct-...`, so
that they cannot be taken for a capture that a bound rests on, and their
sidecars have `count_unit` 1. `rosc_own.py <divided>.bin --pair
<direct>.bin` compares the rates of the two. The write that changes the
way of counting stops and restarts every ring; the payload starts its run
long after that, with a second write.

**The meter's flags.** The meter checks every count against the one before
it: a ring's increment in a clock may not differ from its increment in the
clock before by more than 2. A count that is wrong by sixteen, the one
error that the decoding of a counter can make, differs by 16. A count that
could not be read, or that does not fit, is flagged: the meter counts the
clocks in which a ring of the mask had one (CTRL[63:48]) and keeps a bit
per ring (CTRL[47:42]), both cleared by the start of a run. The sidecar has
them for every run, `bad_counts` and `bad_rings`. **A flagged count fails
no capture.** The case's detail has a warning, the analysis does not use
such a run, and so that nobody overlooks them the last entry of
`rosc-count-results.json`, "captures with flagged clocks", and the last
line that the script prints list every capture that has one. In the
divided mode a flagged count is not expected and wants an explanation. In
direct mode it may come with reason: a counter that is clocked faster than
its flip-flops are guaranteed for can miscount, which is what that mode is
not trusted for.

**The ring masks.** With the default image the two reference rings are off
outside test mode (`strap_mask` in the sidecar, the meter's CTRL[37:32]:
`0x0f`). What is measured with them on is not what `seed` sees, so a bound
can only be claimed from a capture taken with the rings of normal
operation. The default therefore captures with `0x0f` first and then with
all six rings, `0x3f`, as the cross-check.

After the records, for each of the six rings, the phase takes
`KARU_BOARD_ROSC_BURSTS` bursts of that ring's count, with all six rings
on: the meter puts four bits of the ring's count, a count modulo 64, in
place of the lane bits that the burst capture block records, at a sampling
period of one clock, so a burst is those bits at 32,768 consecutive
clocks. It is a check of every ring's counter. There are two views of each
ring. The upper four bits (CTRL[27], files `-hi`) are the count divided by
four: a 3-stage ring advances 8 to 18 counts per clock, so this view steps
by 2 to 4.5 per clock, and the steps, times four and times the unit, are
the ring's periods per clock; an error of sixteen in a count shows in it
as a step of four. The lower four bits (files `-lo`) are the position of
the counter; a step of more than 16 counts shows in them only modulo 16.
With direct captures on, both views are taken in direct mode as well
(`rosc-direct-burst-...`), where a 3-stage ring advances 16 to 36 counts
per clock.

**The reference bits.** Last, the phase takes
`KARU_BOARD_ROSC_REF_BURSTS` bursts at each sampling period in
`KARU_BOARD_ROSC_REF_PERIODS`, again with all six rings on, in which the
meter gives the burst capture block the sampled bits of the two reference
rings with lanes 0 and 1: a sample is {reference 1, reference 0, lane 1,
lane 0} in bits [3:0], all four of one clock edge. Lane 0 and the two
references are three rings of one kind. The difference of the phases of two
of them loses what they share, so the three pairs give each ring's own
jitter, without the counters: a cross-check of the meter's analysis at
spans of up to a few hundred clocks. The files go to the subdirectory
`refbits` of the artifact directory under the names of ordinary burst
captures, `getnoise-burst-p<P>`, so that the burst analysis reads them as
they are. **The subdirectory is what keeps them apart from captures of the
four lanes:** in these files bits 2 and 3 are the reference rings, not the
7- and 9-stage lanes. Do not copy them next to the files of
`getnoise_burst.py`.

**Output**, in the artifact directory:

| File | Content |
| --- | --- |
| `rosc-count-p<P>-e<E>-m<mask>.bin` | The records as read, 16 bytes each, two little-endian 64-bit words. `DATA0`: [63] valid, [62] loss, [61:60] sequence number, [59:40] total of ring 2, [39:20] ring 1, [19:0] ring 0. `DATA1`: [63:60] the lane bits at the record's clock edge (bit 60 is lane 0), [59:40] total of ring 5, [39:20] ring 4, [19:0] ring 3. P is the sampling period in clocks, E is `every`, the mask is two hexadecimal digits |
| `rosc-count-p<P>-e<E>-m<mask>.json` | `clock_hz`; `period` (clocks per raw sample) and `every`; `count_unit`, the ring periods in a count: 2; `ring_mask`, a number; `stages`, the inverters of rings 0 to 5; `runs`, a list of `{"start": index of the first record, "records": n, "cycle_start":, "cycle_end":}` with the clock-cycle count before the run was started and after it ended; `bad_counts`, for each run the clock cycles with a flagged count (CTRL[63:48] at the end of the run), and `bad_rings`, the rings that had one (CTRL[47:42]); `run_ctrl`, the whole control register at the end of each run ([41] the loss flag); `time`, when the capture ended, before its records were read back; `ctrl`, the control register read back after it was written (the write that changes the rings sets its loss flag; the start clears it) and `strap_mask`, the rings that run outside test mode; `mentropycfg` and `mentropystat` before and after; the temperature readout before and after, raw and decoded; `losses`, `polls`; SHA-256 of the `.bin` and of the payload; `for_bound` and `for_bound_why` (see "Records for a bound"); `KARU_BOARD_ROSC_NOTE` |
| `rosc-direct-p<P>-e<E>-m<mask>.bin`, `.json` | The capture in direct mode: the same format, `count_unit` 1, `for_bound` false. A cross-check of the divider, not a capture for a bound |
| `rosc-burst-r<R>-hi.bin`, `-lo.bin` | The count bursts of ring R in the format of `getnoise-burst-p<P>.bin`: one byte per value, bits [3:0] the upper four bits of the count (`-hi`: the count divided by four, modulo 16) or its lower four (`-lo`: the count modulo 16), bit 7 on the first value of a burst |
| `rosc-burst-r<R>-hi.json`, `-lo.json` | As for a burst capture, with `"source": "count"`, `"ring"`, `"view"` (`upper` or `lower`), `"count_bits"`, `"count_unit"`, the ring mask, and the meter's flags over the capture, `bad_count` and `bad_rings`. `getnoise_analyze.py` does not read `source`: do not give it these files |
| `rosc-direct-burst-r<R>-hi`, `-lo` | The same two views in direct mode, `count_unit` 1 |
| `refbits/getnoise-burst-p<P>.bin` | The bursts of the reference bits at a sampling period of P clocks, in the format of `getnoise-burst-p<P>.bin`: one byte per sample, bit 0 lane 0, bit 1 lane 1, bit 2 reference ring 0, bit 3 reference ring 1, bit 7 on the first sample of a burst |
| `refbits/getnoise-burst-p<P>.json` | As for a burst capture, with `"source": "refbits"`, `"lanes": ["lane 0", "lane 1", "reference 0", "reference 1"]` and the ring mask |
| `rosc-count-results.json`, `rosc-count-commands.jsonl` | Case results and OpenOCD trace, as for every phase |

Within a run the records are `period` x `every` clocks apart and their
sequence numbers count 0, 1, 2, 3, 0. Nothing is known about the time
between two runs but the stamps. A run whose `bad_counts` entry is not zero
is not used by the analysis; it does not fail the capture (see "The
meter's flags"). A capture's files replace the previous ones
only when both are complete. A capture fails, and the phase exits
non-zero, on a payload status other than `OK` (`LOCKED`, `BUSY`, `NOBLOCK`,
`NOMETER`, `TIMEOUT`, `LOSSES`, `ABORTED`, `TRAP` and so on, named in the
case detail), if test mode was not left or the meter still answers
afterwards, if the period or the control register read back is not what
was asked for, if the run table does not cover the records, if a run's
stamps are closer together than its records take or further apart than
they need, if a record lacks its valid flag or has the loss flag, and if
the sequence numbers within a run do not follow each other.

**How long it takes.** Capturing is short. Reading the records back
through the debugger is not: the captures of 2026-11-19 were read at
20 KiB/s (19.7 to 21.1 over the eight burst runs, 20.0 for the k-sweep),
and a record is 16 bytes. With the defaults, at 75 MHz, for one ring mask:

| Setting | Clocks between records | Records | Capture | Readout |
| --- | --- | --- | --- | --- |
| `256x1` | 256 | 1,000,000 | 3.4 s | 13 min |
| `256x4` | 1,024 | 1,000,000 | 13.7 s | 13 min |
| `256x16` | 4,096 | 1,000,000 | 55 s | 13 min |
| `256x64` | 16,384 | 400,000 | 87 s | 5.2 min |

That is 47 minutes for a mask and an hour and 35 minutes for the two
default masks. The two captures in direct mode (100,000 records each: 1.4 s, and
78 s to read) add less than three minutes. The count bursts, 24 captures
of four bursts for the six rings, the two views and the two ways of
counting, add two minutes, and the reference bits (seven periods, 32
bursts each: 3.5 MB) three; `KARU_BOARD_ROSC_SCALE` changes neither of
these two. In all about an hour and 45 minutes. `KARU_BOARD_ROSC_SCALE=0.1`
takes a quarter of an hour in all, for bring-up only.
`rosc-count-commands.jsonl` gets a line for every block of 32 KiB read; to
follow a run, `tail -f` it.

**Records for a bound.** A capture that is to carry a bound needs at least
300,000 usable records: those in the blocks that enter the fit, after
runs with a flagged count are set aside, without the ends of runs too
short for another block (`rosc_own.py` prints them beside the records of
the runs kept). With counts of two ring periods, the analysis's checks of
its own assumptions miss small violations at 30,000 records that they flag
at 300,000 (`rosc_own.py`, `MIN_RECORDS`; its validation is in
`test_rosc_own.py --coverage`). With fewer, `rosc_own.py` gives its
estimates and bound for bring-up and the verdict "not established";
`--min-records` lowers the number for the analysis's own tests only and is
never used on a capture that is to carry a bound. The defaults, a million
records and 400,000 at 16,384 clocks, leave room for exclusions. Each
sidecar says whether its capture can carry a bound (`for_bound`, with
`for_bound_why`): false for a direct capture and for one planned with
fewer than 300,000 records, which the phase also prints.

**How fast records can come.** A record costs the payload eight
instructions, two register reads and two stores to DDR. In the SoC
simulation that is 56 clocks, and no record was lost at any spacing tried
from 58 to 256 clocks (400 or 600 records each; at 57 and below records
are lost time and again). On the board a store to DDR takes about 10 clocks longer than in
the simulation, so about 78 clocks is the shortest `period` x `every` it
keeps up with; a store that waits for the memory controller delays one
record, so below about 128 clocks expect losses. The defaults start at
256. A capture shows the cost: a poll that finds no record takes about 33
clocks, and the clocks between two records less 33 times `polls` /
`records` is what a record took, 66 in the simulation at 128 and 256
clocks between records (the 56, and 10 for going by way of the wait).

**Analysis.** `python3 test/dbg/board/rosc_own.py <name>.bin --text`, which
reads `<name>.json` beside it; it needs only the two files, takes the unit
of the counts from the sidecar and does not use a run with a flagged count.
It gives each ring's own phase variance, for lane 0 the one-sided 99%
lower bound on the part that grows in proportion to time, the assumption
checks, and for the spacings of 4,096 and 16,384 clocks a verdict: `pass`,
`fail`, `not established`, or `cross-check only` for a capture in direct
mode or not taken with the rings of normal operation. A pass needs a bound
of at least twice the variance that 0.75 bit needs at the measured
duty-cycle bound, every assumption check, no flagged count and the usable
records above. Its exit status is 0 when the capture was analysed, whatever
the verdict, and 2 when it could not be (no usable run, fewer than two
running rings, an input it cannot read such as a missing sidecar).
`rosc_count.py` takes no arguments and analyses nothing.

Nothing inside one capture shows that a count is two ring periods. Two
checks from outside do, and both are needed on every ring that runs, before
any count of the image is used for a bound
([board test plan, section 7](../../../dbg/BOARD_TEST_PLAN.md#7-the-next-image-one-ring-for-seed)):

- `--pair <other>.bin`, the capture of the same rings and spacing in the
  other way of counting: per ring, the two rates in ring periods per clock
  must be equal. It sees a count wrong by a whole number of periods per
  clock unless both ways share it, and cannot tell which way is wrong.
- `--bits <dir>/getnoise-analysis.json`, the analysis of bursts at a
  sampling period of one clock: each ring's count rate against the
  frequency of its sampled bits, which pass no counter and no divider.
  `--bits-map` names the ring of each burst lane; the default,
  `0:0,1:1,2:4,3:5`, is for the reference bits under `refbits/`, and
  ordinary bursts of `getnoise_burst.py` need `0:0,1:1,2:2,3:3`. Every
  mapped ring that runs in the capture must have a usable frequency fit and
  agree. It compares only the folded frequency, the fraction of the periods
  per clock: a count wrong by a whole number of periods per clock passes
  it, which `--pair` catches.

For the reference bits, from the repository root:

    python3 test/dbg/board/getnoise_analyze.py $KARU_BOARD_OUT/refbits/getnoise-burst-p*.bin
    python3 test/dbg/board/entropy_claim.py --analysis $KARU_BOARD_OUT/refbits/getnoise-analysis.json --own $KARU_BOARD_OUT/refbits

The first takes the files, not the directory, and writes
`refbits/getnoise-analysis.txt` and `.json` next to them; in its report
lanes 2 and 3 are the reference rings. The second needs scipy (where it is
not installed, a copy under `_build/pylib` serves with
`PYTHONPATH=_build/pylib`) and takes a few minutes. It prints, per
sampling period, the variance per clock of the difference of the phase
increments of each pair among lane 0 and the two references, from them
each ring's own variance per clock with its standard error over the
bursts, the mean over the periods, and for lane 0 that variance at 4,096
and at 16,384 clocks as a ratio to what 0.75 bit per bit needs. It assumes
that the three rings share alike what they share and that a ring's own
jitter is white and independent of the others'; it sees spans of 64
samples and nothing beyond, so the two ratios are extrapolations. It is a
cross-check of `rosc_own.py`, not a second bound; the header of
`entropy_claim.py` has the assumptions and the measured bias of the
estimator.

## Authentication

`auth_phase.py` runs the debug authentication exchange of
[the contract](../../../doc/debug-auth-contract.md) against the window ROM
of an image built with `KARU_DBG_AUTH` (image kind `rom2m-auth`), through
OpenOCD's `riscv authdata_read` and `riscv authdata_write`. `authlib.py` is
the client: the mailbox operations, the CHALLENGE and RESPONSE frames and
the response of the algorithm that the challenge names.

**Algorithm.** The VCU118 image verifies `0x04`, a SHA3-256
shared-secret MAC (contract §5.1). The key is the file
`_build/vcu118_auth_key.txt` (64 hex digits) that the image build generates
once and never overwrites; point `KARU_BOARD_AUTH_KEY` at it when the phase
runs elsewhere. Keep that file, and the bitstream, to yourself: anyone
with either can authenticate. `KARU_BOARD_AUTH_ALG=SHA3` makes the phase
stop if the board runs an image with a `TEST` ROM.

**The TEST algorithm protects nothing.** It is the contract's
simulation-only algorithm `0x80`, which the simulation ROM uses: the response is a fold of the challenge
with a key that is printed in the ROM source and in `authlib.py`. Anyone
can compute it. These cases show that the mechanism works; they say nothing
about keeping an attacker out, and an image with this ROM is not protected
in lifecycle `AUTH`. The production algorithm is decision D3 of the plan.

**On the board** with the current image `20f8b265…`, `locked`,
`authenticate`, `reboot`, `wrong-response`, `replay`, `expiry` and
`entropy-off` pass with `0x04`
([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-23.md)); `open`,
`fresh-nonce`, `no-hold`, `disabled` and `reboot-locked` last ran
on the board with a `TEST` ROM
([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-18.md)). Every case is also
rehearsed on the simulated target with the same ROM source
(`make dbg-board-auth-rehearsal-test`, and with the `0x04` build and a
public test key `make dbg-board-auth-sha3-rehearsal-test`).

**How a case is run.** One case per run, because DIP switch SW12 is read
only at the power-on reset of the authentication block, which on the board
is the CPU reset button (or reconfiguration):

1. Set the switches for the case. Position 1 and 2 are the lifecycle (both
   off `OPEN`, 1 on `AUTH`, 2 on `DISABLED`), 3 holds the hart until a
   debugger sends a REQUEST (in `AUTH` only), 4 switches the entropy source
   off.
2. Press the CPU reset button.
3. Start OpenOCD: `openocd -f test/dbg/board/auth-server.cfg`. It does not
   examine the target at start, since a locked one refuses. Start it afresh
   for every case: an OpenOCD that examined the target once keeps its view
   across a reset, and the phase refuses to work with one.
4. `KARU_BOARD_AUTH_CASE=<case> python3 test/dbg/board/auth_phase.py`. With
   the hart held (switch 3 on) there is no hurry; once a case has sent its
   REQUEST the ROM's window is open for 2^30 clock cycles, about 14 s.

Step 2 is left out for three cases: `authenticate` may follow `locked` on
the same reset; `reboot` runs in the power cycle of a passed
`authenticate`, and `reboot-locked` in that of `no-hold`, both once Linux
is up, with only a fresh OpenOCD (step 3), which does not reset the board.
A reset there would clear the state they check.

Each case first compares what the Debug Module shows (lifecycle, grant,
window state) with what it needs, and stops with a message that names the
switches if they differ. The phase shuts OpenOCD down at the end.

| Case | Switches 1 2 3 4 | Reset | What must be seen |
| --- | --- | --- | --- |
| `open` | off off – on | button | The debugger attaches. `mdbgauth` reads lifecycle `OPEN`, no hold (whatever switch 3 says), debug enabled by the lifecycle alone. `seed`, read twenty times through the Program Buffer, stays in `BIST` |
| `locked` | on off on – | button | OpenOCD's examine is refused. `dmstatus` shows version 3 and nothing else, `dmcontrol` only `dmactive`, every other DM register reads 0, writes do nothing. The window is left unused, so `authenticate` can follow on the same reset |
| `authenticate` | on off on off | button | REQUEST accepted; a 20-word challenge with the ROM's device digest and a nonce; the response (SHA3 or TEST, as the challenge names); `dmstatus.authenticated` rises. Then: OpenOCD examines, the hart halts, `mdbgauth` shows the grant, a register round trip, resume; the window reads `CLOSED`; the grant survives a `dmactive` pulse |
| `fresh-nonce` | on off on off | button | As `authenticate`, after another reset, and its nonce differs from every earlier one on record |
| `wrong-response` | on off on off | button | A response with one signature bit wrong: stays locked, the window closes and refuses a further SEND |
| `replay` | on off on off | button | The response of an earlier `authenticate`, sent for the new challenge: stays locked, window closed |
| `expiry` | on off on off | button | No response: the window is still open 12 s after the REQUEST and closed by 17 s (2^30 cycles at 75 MHz are 14.3 s); stays locked; a late SEND is refused |
| `no-hold` | on off off – | button | No window: the mailbox reads `CLOSED`, a REQUEST is refused with `BAD_STATE`; stays locked; Linux boots |
| `entropy-off` | on off on on | button | REQUEST accepted, but no challenge ever appears and the window closes; stays locked; Linux boots |
| `disabled` | – on – – | button | No mailbox (`authdata` reads 0, a REQUEST changes nothing); stays locked; Linux boots |
| `reboot` | as `authenticate` | none | In the power cycle of a passed `authenticate`, with Linux up: after a software reboot the grant is still there, the window is still `CLOSED`, a REQUEST is refused, and the debugger still works |
| `reboot-locked` | as `no-hold` | none | After a locked boot, with Linux up: a software reboot leaves it locked, the window `CLOSED`, a REQUEST refused |

"Linux boots" is asked over SSH: Linux must answer, and must not have been
up for longer than the reset can be old (`KARU_BOARD_AUTH_RESET_AGE`). The
reboot cases follow `linux_reboot.py`, with its settings
(`KARU_BOARD_REBOOT_TIMEOUT`, `KARU_BOARD_UART_LOG`,
`KARU_BOARD_REBOOT_UART`): a new boot ID, and the boot ROM and OpenSBI
banners in the UART capture.

`replay` and `fresh-nonce` use `auth-history.json` in the artifact
directory, where every case that receives a challenge records it, with the
response it sent. Keep one artifact directory for the whole series.

| Variable | Default | Used for |
| --- | --- | --- |
| `KARU_BOARD_AUTH_CASE` | none | The case to run; without it the phase lists the cases and exits non-zero |
| `KARU_BOARD_AUTH_KEY` | `_build/vcu118_auth_key.txt` | The SHA3 (`0x04`) key file, 64 hex digits; read only when the ROM asks for SHA3, never printed |
| `KARU_BOARD_AUTH_ALG` | either | `SHA3` or `TEST`: stop with a message if the ROM's challenge names the other algorithm |
| `KARU_BOARD_AUTH_TIMEOUT` | `30` | Seconds allowed for the ROM to answer: challenge, decision |
| `KARU_BOARD_AUTH_WINDOW_MIN`, `_MAX` | `12`, `17` | Seconds after the REQUEST at which an unanswered window must still be open, and must be closed |
| `KARU_BOARD_AUTH_BOOT` | `1` | `0` leaves out the SSH evidence that the hart booted; the result then says so |
| `KARU_BOARD_AUTH_BOOT_TIMEOUT`, `KARU_BOARD_AUTH_RESET_AGE` | `900`, `300` | Seconds to wait for Linux, and seconds the reset may lie before the start of the case |
| `KARU_BOARD_AUTH_SEED` | `1` | `0`: the `open` case does not read `seed` (image without `KARU_ZKR`) |
| `KARU_BOARD_AUTH_HISTORY` | `auth-history.json` in the artifact directory | Challenges seen and responses sent |
| `KARU_BOARD_AUTH_KEEP_SERVER` | `0` | `1` leaves OpenOCD running at the end |
| `KARU_BOARD_AUTH_STALE` | `0` | `1` accepts an OpenOCD that examined the target before a reset and leaves the examine check out; for the rehearsal |

**What the rehearsal covers, and what only the board showed.** On the
simulated target every case except the two reboot cases runs, and with it
the exchange through pristine OpenOCD against the real ROM source. Not
covered there, and shown only on the board:

- the BSCAN transport and `auth-server.cfg` on the board (the file is only
  parsed, with a dummy adapter);
- the DIP switches and the reset button as the source of the straps;
- the FPGA build of the ROM: nonce from `seed` and the physical entropy
  source, the 2^30-cycle window and its duration in seconds;
- `seed` read from Debug Mode in the `open` case;
- everything that needs Linux: the boot evidence and the reboot cases.
  The self-test runs those, and the `seed` read, against scripted
  stand-ins only: that shows the steps hang together, not that the board
  behaves as the stand-ins do.

## Without a board

| Target | What it does |
| --- | --- |
| `make dbg-board-harness-test` | Offline self-test against a stand-in for OpenOCD's Tcl RPC: every script compiles; a phase's exit status follows its case results; the transport phase's own dispatch loop exits non-zero when its restore commands fail; kernel symbol lookup; the image kinds and their overrides, checked against `rtl/karu_bootmap.vh` and the reset vectors in `flow/fpga/vcu118_ddr_top.v`; a fixture for another map, too long, or outside the scratch SRAM is refused before anything is sent; `clean_detach_boot.py` as a process passes for each image kind at that kind's reset vector and fails at another kind's and one instruction further; the authentication client: its constants against the contract, the window ROM source and the window bench, its TEST response against the ROM's own C routine compiled for the host, the exchange against a model of the contract's mailbox; the authentication cases that need Linux, `seed` or a second boot, run against scripted stand-ins |
| `make dbg-board-rehearsal-test` | Runs the autoexec case through this harness and a real OpenOCD on the simulated full-debug target (`rehearse.py`, `sim-server.cfg`). It must pass, and must fail on a model with each of three injected autoexec defects (`autoexec_mutant.py`), one of them visible only through writes of unselected registers. It then runs the `load` case (reset-halt with the exact DPC, the fixture written to scratch SRAM and read back) on the simulated target's own map, image kind `sim`: it must pass, must fail when the reset vector of the default board image or the next instruction's address is expected, and must fail with the 1 MiB map, whose fixture address is ROM on this target |
| `make dbg-board-auth-rehearsal-test` | `auth_rehearse.py`: pristine OpenOCD and `auth_phase.py` with its own client against the simulated JTAG target running the window ROM of `test/dbg/auth_rom`. In one model run, with a power-on reset between cases: `locked`, `wrong-response`, `expiry`, `authenticate`, `replay`, `fresh-nonce`. In further runs, with the straps as plusargs: `no-hold`, `entropy-off` (a source in `BIST` and a dead one), `disabled`, `open`. Negative controls: four clients with a wrong TEST computation must fail to unlock, and cases started with the wrong switches must stop with the message that names them |
| `make dbg-getnoise-burst-test` | `test_getnoise_burst.py`: the burst payload on the DDR SoC simulation with the entropy source, through the real bus decode. Every burst is compared with a Python copy of the simulated noise source (`noise_model.py`): a stretch of every P-th symbol, bursts in order, at distances that agree with the payload's time stamps; for the default model and for the model with known parameters. Refusals (locked, already in test mode, bad parameters, an image without the capture block), a source without symbols, a fault, three payload mutants and three tampered captures. Then the phase against a stand-in for OpenOCD that runs the same simulation, and the analysis on the files the phase wrote |
| `make dbg-burst-analysis-test` | `test_burst_analysis.py`: the analysis of bursts on generated data with known (F, D, sigma^2): the per-window fit from 1e-5 to 1e-2; the copy of the simulated source decimated to periods of 1 to 256 clocks; proportionality to the spacing and a wrong period label; frequency wander within one lane and shared by two; an injected spur; locked lanes against independent lanes of equal frequency; agreement between a burst capture and a k = 1 capture; joined bursts; five controls that break one step of the analysis |
| `make dbg-rosc-count-test` | `test_rosc_count.py`: the meter payload and its phase on two targets. The first is a model in the test itself, which executes the payload's instructions against the registers as their headers describe them and lists every record that the meter handed out; the second is the DDR SoC simulation with the entropy source and its meter. On both, every run of records is compared with the rings themselves (for the simulation, `noise_model.py`): the totals of all six rings and the lane bits at clock edges `period` x `every` clocks apart, runs in order, at distances that agree with the payload's stamps; a ring that the capture switched on must fit one phase. Bursts of each ring's count; losses by records that come too fast and by slowing the payload down, with the limit on losses; refusals (locked, already in test mode, bad parameters, an image without the capture block or without the meter), a source without samples, a fault, ten payload mutants and tampered captures. Counts of two periods and, in direct mode, of one: the write that changes the way of counting restarts the rings and the run after it starts clean, and a direct capture's totals are twice a divided one's. Both views of a ring's count in both ways of counting, with the ring's periods per clock rebuilt from the steps of the upper view. On the model, a count that is 16 too high in one clock is flagged. Bursts of the reference bits, compared bit by bit with the rings. Then the phase against a stand-in for OpenOCD with either target behind it: the files and the sidecar, the unwrapped totals, the count unit and the meter's flags in the sidecars, the captures in direct mode under their own names, the default order of the ring masks and the scaling of the counts, runs split by losses, a flagged count that fails nothing and is listed in the phase's summary, refusal to analyse and of bad settings, error statuses, twelve alterations of the result block, the run table and the buffer; and `rosc_own.py` as a process on the record files, which has to find their runs and rings and end without an error, likewise `getnoise_analyze.py` and `entropy_claim.py --own` on the reference bits (the last only if scipy can be imported; the test's last line says when it was not run). `make dbg-rosc-count-model-test` runs the first target alone, in seconds |
| `make dbg-rosc-own-test` | `test_rosc_own.py`: `rosc_own.py` on generated rings whose own and shared noise are known, with the controls that must not pass (no own noise, own noise that is not white, locked rings, a mask other than that of normal operation, an unreadable counter), and on the captures that `make dbg-rosc-count-test` has just written, so that what the phase writes is what the analysis reads. About a minute. The coverage study behind the confidence bound, `test_rosc_own.py --coverage`, is not part of it |
| `make dbg-entropy-claim-test` | `entropy_claim.py --self-test`: the fit of two rings' phase increments on generated rings of known correlation; then `--own` on three generated rings of nearly one frequency whose shared jitter has 20 times the variance of their own: ring 0's own variance must come out within its stated error when all three are equal and when it is four times the others', and not significantly above zero when it is zero; the first case once more from files through `getnoise_analyze.py`. It needs scipy and uses a copy under `_build/pylib` if there is one; without scipy the target does not fail, and its last line says that the test was SKIPPED |
| `make dbg-getnoise-test` | `test_getnoise.py`: the capture payload on the Zkr simulation bench, compared symbol by symbol with a copy of the bench's noise model, with refusals, lost symbols, timeouts, a fault and three payload mutants; the capture phase as a process against a stand-in for OpenOCD that runs the loaded memory image on the same bench; the analysis on data generated from the model, with dependent lanes that must be flagged |

All of these are part of `make dbg-test`; `make dbg-entropy-claim-test` runs
there only where scipy can be imported and says so in its last line when it
was skipped. The
simulated target has the scratch SRAM of `rtl/karu_bootmap.vh` and 64 KiB of
RAM at `0x80000000`, which are one memory seen at two addresses, and its
reset vector is `0x80000000`. It has no other DDR and no UART, so only
cases that need the hart, the Debug Module and that memory can be
rehearsed. Rehearse a new or changed case this way before a campaign, with
a defect that it should catch.

## Files

| File | Role |
| --- | --- |
| `boardlib.py` | OpenOCD RPC client, case bookkeeping, exit status, configuration, the map and reset vector of each image kind |
| `*_phase.py`, `linux_kernel_bp.py`, `clean_detach_boot.py`, `linux_reboot.py`, `linux_zkr.py` | Board phases |
| `post_linux_host.py`, `post-linux.sh`, `complete_crypto.py`, `openssl-expected-matrix.json` | Post-detach Linux regression |
| `payload.S` | Bare-metal fixture, linked into the scratch SRAM of the image kind: at `0x208000`, or `0x108000` for `rom1m` |
| `translation-board.tcl` | Translation probes sourced by `translation_phase.py` |
| `server.cfg`, `linux-server.cfg` | OpenOCD servers for the board |
| `rehearse.py`, `sim-server.cfg`, `autoexec_mutant.py`, `test_boardlib.py` | Rehearsal and self-test without a board |
| `authlib.py`, `auth_phase.py`, `auth-server.cfg` | Debug authentication: client, phase, and the OpenOCD server for a target that may be locked |
| `auth_rehearse.py`, `auth-sim-server.cfg` | Rehearsal of the authentication phase on the simulated target |
| `getnoise.S`, `getnoise_capture.py` | GetNoise capture payload (position independent, loaded into DDR) and its phase |
| `getnoise_burst.S`, `getnoise_burst.py` | Burst capture payload and its phase |
| `rosc_count.S`, `rosc_count.py` | Meter capture payload (records of the six rings' totals, and bursts of one ring's count) and its phase |
| `test_rosc_count.py` | Self-test of the two without a board (`make dbg-rosc-count-test`) |
| `rosc_own.py`, `test_rosc_own.py` | Offline analysis of the meter's records ([Meter capture](#meter-capture)), and its self-test (`make dbg-rosc-own-test`) |
| `noise_model.py` | Python copy of the simulation's noise source, for the self-tests |
| `test_getnoise_burst.py`, `test_burst_analysis.py` | Self-tests of the burst capture and of the analysis of bursts, without a board |
| `getnoise_analyze.py` | Offline analysis of the captures |
| `test_getnoise.py` | Self-test of the three without a board |
| `getnoise_restart.py` | Delayed warm-restart data for SP 800-90B section 3.1.4 (1,000 restarts of 1,000 symbols, through GetNoise) |
| `seedcap.S`, `seed_restart.py` | Operational restart data for SP 800-90B section 3.1.4: after each debugger reset, the first 1,000 samples that `seed` delivers ([below](#operational-restart-data-and-induced-failures)) |
| `entropy_fault.py` | Induced health-test failures on the real rings, by stricter cutoffs ([below](#operational-restart-data-and-induced-failures)) |
| `entropy_claim.py` | The bound of the SP 800-90B argument (per-sample min-entropy for a credited share of each ring's jitter, worst case over the previous phase) and `--pairs`, the covariance of the rings' phase increments from the burst captures; `--own`, lane 0's own jitter from the reference bits that `rosc_count.py` captures, a cross-check of `rosc_own.py` ([Meter capture](#meter-capture)); with `--self-test` (`make dbg-entropy-claim-test`) ([assessment, section 1](../../../doc/sp800-90b-assessment.md#12-technical-justification); the four-ring argument is in [its dated record](../../../doc/sp800-90b-assessment-2026-11-20.md#11-the-argument-and-the-step-that-fails)) |
| `test_seedcap.py` | Self-test of `seedcap.S` on the Zkr simulation bench (`make dbg-seedcap-test`) |
| `sp80090b_health.py` | Replay of captures through the per-lane tests of the images up to `85f07e58…`, and the section 4.5 criteria for them |
| `entropy_health.py` | Python copy of the health tests of the current `rtl/karu_entropy.v`: cutoffs for an entropy rate and a false-alarm probability, replay of captures, the section 4.5 criteria and the failure modes. `make entropy-test` compares the RTL with it |

The Linux selftest binaries and the installed `openssl_zvk_bench` come from
karudeb and are not part of this repository.
