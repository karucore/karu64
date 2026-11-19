# Physical-board debug acceptance harness

These scripts drive the debug-enabled VCU118 image through a real JTAG
adapter and OpenOCD. They are the drivers of the
[2026-11-16 campaign](../../../dbg/BOARD_ACCEPTANCE.md), moved here from that
campaign's artifact directory so that they are version-controlled. Logs,
traces and results are written to an artifact directory under `_build`,
never here.

**Status, 2026-11-17.** The scripts were changed after the campaign: paths
and addresses are configurable, every phase returns an exit status, and the
autoexec case counts executions. Those changes passed the offline self-test
and, for the autoexec case, a rehearsal on the simulated target.

Also on 2026-11-17 the boot ROM grew to 2 MiB, which moved the scratch SRAM,
and the default debug image began to start in the authentication island. The
phases now take the scratch addresses and the reset vector from the kind of
image under test ([Image kinds](#image-kinds)).

**Status, 2026-11-18.** Every script ran on the board with the `rom2m-auth`
image `d7ff00dc…`, in the order of
[the board test plan](../../../dbg/BOARD_TEST_PLAN.md), which also gives the
boot files, the switch positions and what to try when a stage fails. All
phases pass except translation (the known OpenOCD defect); see the
[2026-11-18 record](../../../dbg/BOARD_ACCEPTANCE-2026-11-18.md). Two limits
were too short for this board, where an SSH connection takes 30 to 55 s and
a reboot about 440 s: the SSH probe of `linux_reboot.py` (now
`KARU_BOARD_SSH_TIMEOUT`, 180 s) and the evidence copy of
`post_linux_host.py` (now 900 s). The reboot and boot waits now default to
900 s. Ask for the reset button by its label, `CPU_RESET`: PROG clears the
FPGA's configuration.

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
| 10a | `getnoise_capture.py` | fixture; image built with `KARU_ZKR`; DIP switch 4 off; `make dbg-getnoise-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT` | Optional, not an acceptance phase: raw noise capture, see [Noise capture](#noise-capture-getnoise). First run on the board 2026-11-18 |
| 10b | `getnoise_burst.py` | fixture; image with the burst capture block (built after 2026-11-18; `d7ff00dc…` has none); DIP switch 4 off; `make dbg-getnoise-burst-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT` | Optional, not an acceptance phase: bursts of raw noise at sampling periods of 1 to 256 clocks, see [Burst capture](#burst-capture). First run on the board 2026-11-19 |
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
`TIMEOUT`). The hart in the
state `baremetal_phase.py` leaves it in: reset-halted, fixture loaded. The
payload built into the artifact directory:
`make dbg-getnoise-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`. A reset clears a
locked `mentropycfg`; nothing else does.

**What it does.** The phase loads `getnoise.S` into DDR. For each k in
`KARU_BOARD_GETNOISE_K` it writes the parameter block and runs the payload
in M-mode until its `ebreak`. The payload saves `mentropycfg`, sets the
interval to k-1 with the two cutoffs unchanged, enters test mode, and takes
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
| `getnoise-k<k>.json` | k, symbols requested and stored, run lengths, losses, polls, `mentropycfg` before, during and after, the two cutoffs, SHA-256 of the `.bin` and of the payload, time, `KARU_BOARD_GETNOISE_NOTE`, and the temperature readout (`0x1000_0860`: die temperature, VCCINT, VCCAUX; zero on images built before 2026-11-19) before and after, raw and decoded. The phases record no bitstream identity; put it in the note |
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
  autocorrelation runs over hundreds of lags (added 2026-11-18 for the
  burst captures; it applies to every capture):
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
  figure: it is refused, as before, because the lags do not reach.
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

Before 2026-11-17 the per-lane verdict used the D = 1/2 bound alone and
passed lanes whose bias made the threshold impossible; the word verdict
used the distribution of single words alone; the independence verdict
passed for want of data. The self-test keeps one case of each.

**The capture loop keeps up at k = 1 on the board** (2026-11-18: 10^6
symbols in one run, no losses). In simulation an idle poll takes about 32
clocks, and the loop takes every symbol at 128 clocks per symbol (the
self-test checks this; 64 clocks also worked when measured once). The board
has 256 clocks per symbol at k = 1; there the loop polled about every 34
clocks. The run lengths in the sidecar show it either way.

## Burst capture

`getnoise_burst.py` records raw symbols with the rings sampled every 1 to
256 clock cycles, which `mnoise` is too slow for: the capture block next to
the noise source (`flow/fpga/karu_noise_burst.v`) sets the sampling period
and records 32,768 consecutive symbols per burst in block RAM, and the
payload copies each burst out. It ran on the board on 2026-11-19, eight
runs ([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-19.md#noise-capture-stage-d2));
`make dbg-getnoise-burst-test` is its simulation test.

**Needs.** An image with the capture block: `KARU_ZKR`, built from a tree
after 2026-11-18. Bitstream `d7ff00dc…` has no such block, and the phase
then stops at its first case with "no capture block in this image". DIP
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

## Authentication

`auth_phase.py` runs the debug authentication exchange of
[the contract](../../../doc/debug-auth-contract.md) against the window ROM
of an image built with `KARU_DBG_AUTH` (image kind `rom2m-auth`), through
OpenOCD's `riscv authdata_read` and `riscv authdata_write`. `authlib.py` is
the client: the mailbox operations, the CHALLENGE and RESPONSE frames and
the response of the algorithm that the challenge names.

**Algorithm.** Images built from 2026-11-18 on verify `0x04`, a SHA3-256
shared-secret MAC (contract §5.1). The key is the file
`_build/vcu118_auth_key.txt` (64 hex digits) that the image build generates
once and never overwrites; point `KARU_BOARD_AUTH_KEY` at it when the phase
runs elsewhere. Keep that file, and the bitstream, to yourself: anyone
with either can authenticate. `KARU_BOARD_AUTH_ALG=SHA3` makes the phase
stop if the board still runs an image with the older `TEST` ROM.

**The TEST algorithm protects nothing.** It is the contract's
simulation-only algorithm `0x80`, which the board images before 2026-11-18
and the simulation ROM use: the response is a fold of the challenge
with a key that is printed in the ROM source and in `authlib.py`. Anyone
can compute it. These cases show that the mechanism works; they say nothing
about keeping an attacker out, and an image with this ROM is not protected
in lifecycle `AUTH`. The production algorithm is decision D3 of the plan.

**Every case passed on the board on 2026-11-18**
([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-18.md)). It is also
rehearsed on the simulated target with the same ROM source
(`make dbg-board-auth-rehearsal-test`, and with the `0x04` build and a
public test key `make dbg-board-auth-sha3-rehearsal-test`). The `0x04` ROM
ran on the board on 2026-11-19 for `locked`, `authenticate`,
`wrong-response`, `replay`, `expiry` and `entropy-off`
([record](../../../dbg/BOARD_ACCEPTANCE-2026-11-19.md#authentication-stage-e));
the other cases were not rerun with it.

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
covered there, and shown only by the 2026-11-18 board run:

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
| `make dbg-getnoise-test` | `test_getnoise.py`: the capture payload on the Zkr simulation bench, compared symbol by symbol with a copy of the bench's noise model, with refusals, lost symbols, timeouts, a fault and three payload mutants; the capture phase as a process against a stand-in for OpenOCD that runs the loaded memory image on the same bench; the analysis on data generated from the model, with dependent lanes that must be flagged |

All six are part of `make dbg-test`. The
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
| `noise_model.py` | Python copy of the simulation's noise source, for the self-tests |
| `test_getnoise_burst.py`, `test_burst_analysis.py` | Self-tests of the burst capture and of the analysis of bursts, without a board |
| `getnoise_analyze.py` | Offline analysis of the captures |
| `test_getnoise.py` | Self-test of the three without a board |

The Linux selftest binaries and the installed `openssl_zvk_bench` come from
karudeb and are not part of this repository.
