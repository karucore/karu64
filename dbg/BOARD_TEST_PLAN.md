# Board test plan: the VCU118 debug image

For the VCU118 debug image ([FPGA guide](../doc/fpga.md#debug-image)): the
2 MiB boot ROM, the Zkr entropy source (one ring for `seed`) with its
health tests, the burst capture, the meter and the temperature readout,
debug authentication with SHA3-256 (algorithm `0x04`) and the SW12
straps, and U-Boot v2026.10. The current debug image is `20f8b265…`. Its
latest run is the [2026-11-23 record](BOARD_ACCEPTANCE-2026-11-23.md):
accepted with documented exceptions (translation fails with the known
pristine-OpenOCD walker results). Ask for the CPU reset button by its label
`CPU_RESET` (PROG clears the FPGA), and allow about 4.5 minutes per boot
and 30–55 s per SSH connection (the harness defaults do).

**Sections 1 to 6 are the stages of an acceptance; section 7 is the
entropy source's part:** the meter, the data for the
[SP 800-90B assessment](../doc/sp800-90b-assessment.md) and the boot
checks. The entropy scripts and fixtures (`seed_restart.py`,
`entropy_fault.py`, `getnoise_capture.py`, `rosc_count.py`, `seedcap.S`)
are those of the current sources and need an image with the one-ring
block. On the fallback `ddb168e1…`, which has the four-lane block, stages
D and G need the scripts and fixtures of commit `ace91d5`.

**The SW12 switches are hard to reach.** Change them as rarely as possible:
group the cases by switch setting, change one switch per step, and use JTAG
reconfiguration (a full power-on, straps sampled again) or the software
reset (hart, peripherals and entropy source; not the authentication block)
instead of the CPU reset button where the test allows.

**Keep one process on the console port.** A boot froze once when one host
process released the serial port and another reopened it while the kernel
was printing ([record](BOARD_ACCEPTANCE-2026-11-20.md#finding-a-boot-froze-after-a-console-port-hand-over)).
Open the port once, before the first reset, and keep it open: to drive
U-Boot, use one process that drives the prompt and then keeps capturing.
If a boot stops on the console, read GPIO LED 3 (the FPGA's CTS input)
before any reset.

**Keep a fallback image on the lab host.** The failure tables say to go
back to the previous accepted image, `ddb168e1…` (archived on the build
host in `_build/fpga_archive/2026-11-20-ddb168e1/`); copy its bundle over
before the session.

| | |
|---|---|
| Bitstream `_build/vcu118_ddr.bit` | SHA-256 `20f8b265bc6189d5a2428bfbc5bce586c92d0c474a6cc41550e6d66d7b6c630a`, 80,159,322 bytes |
| Bundle `_build/vcu118_programming.tgz` | SHA-256 `131acaeb9d503b69c747a9222662c49da544226e570e7eed1ac03f89e8cb6ceb`, mode 600: it holds the authentication key. It also has the boot-ROM record `vcu118_ddr.rom.json` |
| Configuration | `KARU_RVA23S64`, `KARU_DBG`, `KARU_DBG_FULL`, `KARU_DBG_AUTH`, `KARU_ZKR`; 75 MHz |
| Timing | meets 75 MHz: setup +0.026 ns, hold +0.010 ns, pulse width +0.005 ns; no DRC errors; every routed check of the six counters `ok` |
| Straps | `lane=0 kshift=0 (k at least 16) rings=0x0f` |
| Boot ROM | `73df94eb…`: OpenSBI v1.9 `cbbbe5ce…`, U-Boot 2026.10 with the Zkr time-out patch, device tree `784e2762…` (`rva23s64-zkr-ddr`); fu-boot and U-Boot built by `$RISCV/bin/riscv64-unknown-elf-gcc` (recorded in the ROM manifest of the bundle) |
| Island ROM | `6f33eae4…`: algorithm `0x04`, SHA3-256 with a shared secret, key fingerprint `276bf6e96d8edecc`; nonce from `seed`, at most 2,000,000 polls per word; window of 2^30 cycles (14.3 s), and a hardware limit of 2³¹ clocks (28.6 s) behind it |
| Entropy block | one lane, lane 0; the binary health tests; `mentropycfg` (`0x7C9`) reset value `0x30c0000b3c37000f`; `mentropystat` (`0x7CA`) shows the lane and the spacing floor; the meter at `0x1000_0868` |
| Sources | karu64 as in the [build record](MEASUREMENTS.md#fpga-image--2026-11-21) (the commit that adds it, documents aside); karudeb `db180ff` |

The figures and their evidence are in
[measurements](MEASUREMENTS.md#fpga-image--2026-11-21). Check the bitstream
hash after the transfer; `_build/vcu118_rom_manifest.txt` in the bundle
repeats it, with the boot command that is baked into the ROM. The bundle's
`vcu118_auth_record.json` ties the key to this bitstream.

**Handling the bundle.** The bundle and the bitstream hold the
authentication key, like the key file. On the board host unpack the bundle
with `umask 077` into a directory of mode 0700, and keep the bitstream
there:

```sh
umask 077; mkdir -m 700 ~/karu-20f8b265 && tar -C ~/karu-20f8b265 -xzf vcu118_programming.tgz
```

**Which image is on the board.** U-Boot's banner tells the images apart:
this one prints `U-Boot 2026.10-dirty (Nov 21 2026 - 16:27:09 +0000)`, the
fallback `(Nov 19 2026 - 22:30:01 +0000)`. With debug access, `mentropycfg`
reads `0x30c0000b3c37000f` after reset in this image and
`0x30c7c1eb3c37000f` in the fallback.

## 1. What the lab host needs

| Item | Where it comes from | Note |
|---|---|---|
| This repository and `karudeb` at the build's sources | git | The device-tree variant `rva23s64-zkr-ddr` is karudeb's |
| `_build/vcu118_programming.tgz` | copy from the build host | Bitstream, `.ltx`, ROM manifest, the device tree that is in the ROM, the authentication record and key |
| Kernel `Image` | the lab's accepted kernel, `3b45e852…`, release `7.4.0-rc3-zvk-dirty` | See section 2 |
| NFS root | unchanged | |

The lab host builds the bare-metal fixtures itself (`make
dbg-board-fixture dbg-getnoise-fixture dbg-getnoise-burst-fixture
dbg-seedcap-fixture dbg-rosc-count-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`);
they are small and need only the RISC-V compiler.

## 2. Boot files: keep each bitstream with its own device tree

The ROM manifest in the bundle names the device tree to serve:

| Bitstream | Device tree to serve as `board.dtb` | Kernel |
|---|---|---|
| this image, and the fallback `ddb168e1…` | `784e2762…` (`rva23s64-zkr-ddr`; it is `vcu118_rom_board.dtb` in the bundle) | the accepted `3b45e852…` |
| images without the Zkr CSRs (`d5e603cd…`, `0b994847…` and older) | the plain tree (`c477784a…`, or `d617ba56…` for `0b994847…`) | the same |

- **Never serve the `zkr` tree to an image without the Zkr CSRs.** Linux
  would execute a `seed` access that the hardware answers with an
  illegal-instruction exception, early in boot and without a fallback.
- Serving the plain `c477784a…` tree to this image is safe and is the way
  to make Linux leave `seed` alone: OpenSBI still enables the CSR, Linux
  never reads it.
- The kernel staged on the build host (`b0295cd6…`, release
  `7.4.0-rc3-zvk`) is not the board-accepted binary. The image does not
  contain a kernel, so use the lab's accepted `Image`. If the build host's
  kernel is used instead, that is a new kernel under test, and
  `board_accept.sh --expect-kernel 7.4.0-rc3-zvk-dirty` will rightly fail
  on its release string.
- The boot command baked into this image's U-Boot carries
  `random.trust_cpu=off`: Linux mixes what `seed` delivers into its pool
  and does not count it as entropy. Linux's pool is not a conditioner
  that the [SP 800-90B assessment](../doc/sp800-90b-assessment.md)
  covers, so this is deliberate.

## 3. Switches

SW12 is the four-pole GPIO DIP switch, active-high, factory default all off.
The straps are read at power-on reset of the debug logic, which on the
board is the CPU reset button or reconfiguration.

| Position | Off | On |
|---|---|---|
| 1 | lifecycle `OPEN`: the debugger works without authentication | lifecycle `AUTH` |
| 2 | | lifecycle `DISABLED` (with or without position 1) |
| 3 | boot normally | in `AUTH`: hold the hart in reset until a debugger asks |
| 4 | entropy source on | entropy source off: `seed` stays in `BIST` |

With positions 1 and 3 on the hart does not run until a debugger sends a
request. That is the hold, not a hang.

## 4. Order of work

Stop at the first stage that fails and use section 5. With the switches all
off, stages B, C, D, G and F run without a switch change; A and E need
them. A session usually runs B first, then C, D and G from one OpenOCD,
then F, and groups A and E by switch setting.

### Stage A: boot with the entropy source off

1. Serve the files of section 2. Set SW12 to off, off, off, **on**.
2. Program the bitstream (or press `CPU_RESET`) and capture the UART from
   the first character.
3. Expect, in order: the fu-boot banner and "copying boot chain from ROM",
   `OpenSBI v1.9` with `zkr` in "Boot HART ISA Extensions" and
   "Platform Reboot Device : syscon-reboot", U-Boot 2026.10, which prints
   "No RNG device" once before it starts Linux and boots on (a hang there
   would be the released Zkr driver, without the time-out patch), Linux,
   the NFS root, a login prompt.
4. `KARU_BOARD_ZKR=1 python3 test/dbg/board/linux_zkr.py`: the device tree
   and `/proc/cpuinfo` list `zkr`. With position 4 on this shows that the
   boot does not depend on the entropy source.

### Stage B: the same with the entropy source on

1. SW12 all off; reset.
2. The same console sequence, without "No RNG device": U-Boot puts a
   `kaslr-seed` into the device tree it hands to Linux (`/chosen`). Then
   `linux_zkr.py` again.
3. At the U-Boot prompt (stop autoboot with a key, from the one process
   that holds the console), `rng list` shows the driver and `rng 0 10`
   prints sixteen bytes from `seed` (device 0, 0x10 bytes).
4. `python3 test/dbg/board/linux_reboot.py` with the UART capture: three
   software reboots, each through the boot ROM and OpenSBI.

### Stage C: debug acceptance, lifecycle `OPEN`

Follow [the harness README](../test/dbg/board/README.md) with
`KARU_BOARD_IMAGE=rom2m-auth` and fixtures built for it. The harness checks
that a reset-halt stops at `0x10000` and that the fixture lives at
`0x208000`. Translation (step 6) is expected to fail with a pristine
OpenOCD.

### Stage D: noise and restart data

With SW12 position 4 off and OpenOCD running as in stage C. This is
characterisation and data collection, not a pass or fail: bring every
`.bin` and `.json` back. Put the conditions of each run (cold start or
reset, link up or down, what ran before) into the phase's note variable;
the phases read the die temperature and supplies themselves. GetNoise
and the burst capture give all four lanes, lane i in bit i; lane 0 is the
source.

1. **k-sweep:** `getnoise_capture.py` captures at k = 1, 2, 4, 8, 16 and 32
   (`KARU_BOARD_GETNOISE_NOTE`).
2. **Burst capture:** `getnoise_burst.py` takes 32 bursts of 32,768 symbols
   at each of the periods 1, 2, 4, …, 256 clocks, about 9 MiB through the
   debugger (`KARU_BOARD_BURST_NOTE`). Then `getnoise_analyze.py` on the
   burst and k-sweep files together: the burst capture at 256 clocks and
   the k = 1 capture should agree, and the analysis says whether they do.
   Repeat after reconfigurations and `CPU_RESET` presses, and once with
   the Ethernet cable unplugged, one artifact directory per run (a run
   overwrites the files of the one before).
3. **Operational restart data:** `seed_restart.py`, 1,000 restarts with the
   first 1,000 samples of each read through `seed`, one bit per byte
   (about 3 minutes), for SP 800-90B section 3.1.4. Then
   `ea_restart -n -v seed-restart-rows.bin 1 0.75` (7.7).
4. **Delayed warm restarts:** `getnoise_restart.py`, the same through
   GetNoise (about 6 minutes), for comparison.

If `seed` reports `DEAD`, the GetNoise capture still works: test mode
switches a dead source back on. The burst phase then stops with "the noise
source is off".

### Stage G: health tests

1. **Read `mentropystat` before every reset**, with the hart halted for a
   moment and without a reset (an abstract read of CSR `0x7CA`;
   `b.rawread(0x7ca)` in the harness), and note the time since the last
   reset. Any reset clears it. `1` is running with no failure since reset.
2. **A long run:** leave the board running Linux with SW12 all off for
   hours and read `mentropystat` before the next reset. The tests run while
   the source is outside test mode, about 18,300 samples per second.
3. **Induced failures:** `entropy_fault.py` (about 17 minutes, most of it
   the forgiveness case: 2^24 samples, 16 minutes at k = 16 and in
   proportion to k): a start-up failure, each of the two tests, strikes
   to `DEAD`, forgiveness, and the limits and lock, on the real ring, by
   stricter cutoffs. It resets the SoC, so take the readings of steps 1
   and 2 first.

### Stage E: authentication

`test/dbg/board/auth_phase.py`, one case per run, with
`KARU_BOARD_AUTH_ALG=SHA3` (so that a case stops if the board runs an image
with a `TEST` ROM) and the key in `KARU_BOARD_AUTH_KEY`, by default
`_build/vcu118_auth_key.txt`, where the bundle puts it. The
[harness README](../test/dbg/board/README.md#authentication) has the table
of cases with the switch positions and what must be seen. A case runs
from a fresh `openocd -f test/dbg/board/auth-server.cfg` (start it anew for
every case; it does not reset the board), then
`KARU_BOARD_AUTH_CASE=<case> python3 test/dbg/board/auth_phase.py`. Before
most cases, set the switches and give the power-on (`CPU_RESET`, or a JTAG
reconfiguration of the same bitstream). Three cases take no power-on of
their own:

- `authenticate` may follow `locked` on the same power-on, which leaves the
  window unused;
- `reboot` runs in the power cycle of a passed `authenticate`, once Linux
  is up: a power-on would clear the grant it checks;
- `reboot-locked` runs in the power cycle of `no-hold`, once Linux is up.

Each case first checks from the Debug Module that the switches are what it
needs and says so if they are not. Keep one artifact directory for the
series: `replay` and `fresh-nonce` use the challenges recorded by earlier
cases.

Grouped by switch setting:

1. off, off, off, on: `open`, the strap read-back (lifecycle and hold bits
   of `mdbgauth`, and `seed` staying in `BIST` with the source off);
2. on, off, on, on: `entropy-off`;
3. on, off, on, off: `locked` and `authenticate` on one power-on, then
   `reboot` with Linux up; then `fresh-nonce`, `wrong-response`, `replay`
   and `expiry`, each on its own power-on;
4. on, off, off, off: `no-hold`, then `reboot-locked` with Linux up;
5. on, on, off, off: `disabled`; then all off.

What to expect: a challenge at least 59.4 ms after the power-on (the
entropy source's start-up test and its first words; about 238 ms with a
spacing floor of k = 64), unlock about 0.2 s after the request, and in
`expiry` the window closed by the ROM's deadline at about 14.3 s; the
hardware limit (28.6 s) is not reached in any case. A pass shows that a
debugger without the key is kept out; the key is in the bitstream and in
the bundle, so it keeps out no one who has either. The same client and
OpenOCD are rehearsed against the simulated target
(`make dbg-board-auth-rehearsal-test`, `make
dbg-board-auth-sha3-rehearsal-test`); not rehearsable are the BSCAN
transport with a locked target, the switches, the power-on, and the cases
that need Linux.

### Stage F: Linux acceptance

`board_accept.sh` as for every image, with the lab's kernel, then the KVM
guests and the post-Linux phases. A guest's `seed` access traps to the host
by design; the acceptance does not depend on Zkr inside a guest.

## 5. If something fails

| Symptom | First thing to try | What it tells |
|---|---|---|
| Nothing on the UART after programming | Check SW12 positions 1 to 3 are off; reset | With 1 and 3 on the hart is held by design |
| No fu-boot banner with SW12 all off | Program the fallback `ddb168e1…` | The island ROM hand-over, the 2 MiB ROM or the RTL is at fault; there is no switch that bypasses them |
| Stops in or after OpenSBI | Position 4 on, reset | If it then boots, the entropy path is involved |
| U-Boot hangs after "Net:" or before "Starting kernel" | Note position 4. A hang only with it on means the Zkr driver waits without bound (a ROM built without the patch) | With it off, something else: program the fallback |
| Linux stops early | Serve the plain `c477784a…` tree (and run `linux_zkr.py` with `KARU_BOARD_ZKR=0`) | If it then boots, Linux's use of `seed` is involved |
| The console stops during a boot | Read GPIO LED 3 before any reset; then check that one host process holds the port | See the console practice above |
| `seed` is `DEAD` (U-Boot "No RNG device" with switch 4 **off**, no challenge in `authenticate`) | Read `mentropystat` first (below) | The start-up test failed, or a third running failure |
| Debugger cannot attach | SW12 positions 1 and 2 off, reset | `OPEN` must behave as an image without authentication |
| Harness refuses to start | Read its message: fixture or image kind does not match | `KARU_BOARD_IMAGE` and the fixture must be for the same map |
| Burst phase: "no capture block in this image" | The image predates the capture block | |
| Burst phase: payload status `ABORTED` or `TIMEOUT` | Note it and repeat once; keep the console and the artifact directory | The source was off during a burst, or a burst did not complete |
| Burst or GetNoise phase: payload status `LOCKED` or `BUSY` | A reset clears both | Something locked `mentropycfg` or left test mode on |
| `seed_restart.py` repeats restarts | Read the reasons in `seed-restart.json` | `LATE`: the payload started after the first output; `ALARM`: a health-test failure in the first samples |
| Authentication: "the ROM asks for algorithm TEST" | Program this bitstream | The board runs an older image |
| Authentication: the response is refused with SHA3 | `python3 flow/auth_record.py verify --record _build/vcu118_auth_record.json --bit _build/vcu118_ddr.bit --key $KARU_BOARD_AUTH_KEY` | It prints `key` for this bitstream's key and fails for any other |
| The authentication window closes before 14 s | Report the time | Not expected |

**If `seed` is ever `DEAD`.** What the tests found is in `mentropystat`, and
the entropy block is reset with the SoC (`soc_rst` in
`flow/fpga/vcu118_ddr_top.v`). Any reset clears it: a reboot, `reset halt`,
reprogramming, and any fixture set-up that resets the SoC, the capture
scripts included. So, in this order:

1. **Read `mentropystat` first**, with the hart halted and without a
   reset. It names the test, the lanes and the lags that failed. This needs
   debug access: lifecycle `OPEN`, or `AUTH` with a grant given earlier in
   the same power cycle.
2. **In locked `AUTH` it cannot be read.** A source that died before
   authentication gives the ROM no nonce, so no challenge comes, nothing
   can be granted, and JTAG has no way to the CSR; a reset into `OPEN`
   clears the evidence. Keep what the failed boot did show: the UART log
   (U-Boot's "No RNG device", what OpenSBI and Linux print) and the mailbox
   as read over JTAG (the status word and the absence of a challenge), and
   record that the cause could not be read.
3. Only then capture with `getnoise_capture.py` (test mode switches a dead
   source back on) and compare with the latest k = 16 capture.

An image without authentication and Zkr can be built from the same tree
with `VCU118_DBG_EXT_DEFINES=KARU_DBG_FULL`; it uses the plain device tree
and the harness kind `rom2m`.

## 6. What to bring back

- The UART capture of the whole session, from one process.
- The harness artifact directory (`KARU_BOARD_OUT`), with `SHA256SUMS`.
- The capture and restart files and their JSON sidecars, with the
  conditions of each run.
- Every `mentropystat` reading, with the time since the last reset.
- The SW12 positions used for every run, and how each power-on was given.
- For any failure: the last console lines, the switch positions, and which
  row of section 5 was tried.

<a id="7-the-next-image-one-ring-for-seed"></a>

## 7. The entropy source: meter, data and boot checks

The board part of Z7 of the
[Zkr follow-up plan](../doc/zkr-followup-plan.md#z7-one-ring-for-seed-and-the-measurement-of-its-own-jitter);
[the FPGA guide](../doc/fpga.md#the-ddr4-soc-linux-target) describes the
hardware. On image `20f8b265…` the meter passed its qualification (7.3),
the operating-mask capture gave a non-IID estimate of 0.810451 bits per
sampled bit, and the model of 7.4 gave no lower bound. Of 7.7, the data,
the health tests, the spacing and two of the three boot checks pass. The
third, the boot with the source off, was not run as 7.7 specifies it
(SW12 off, off, off, on): it passed in lifecycle `AUTH`, in the
`entropy-off` case ([record](BOARD_ACCEPTANCE-2026-11-23.md)). The
[SP 800-90B assessment](../doc/sp800-90b-assessment.md) uses these
results.

**The goal** is that of the
[Zkr follow-up plan](../doc/zkr-followup-plan.md#zkr-and-software-sign-off):
`seed` delivers at least 192 bits of min-entropy per 256 bits, as the
RISC-V Zkr text requires, and the software module that consumes it
conditions with a vetted conditioner, under one self-assessment for this
bitstream and the stated operating range. The board gives two of its
parts, on the same image, lane, spacing and ring mask:

1. The evidence for the rate at `seed`: sequential and operational restart
   data at the spacing (7.7), in every operating condition that the
   assessment is to name, and the ring's jitter from the meter (7.3 to
   7.5). The assessment proposes the rate from these. Its open step is
   how much of the measured jitter is fresh; a bound from 7.4 would
   close it, and so would another reason to credit that share.
2. The behaviour at `seed`: the start-up and continuous health tests, the
   alarm and the failure handling, and the assessed spacing from the first
   word that the boot ROM consumes (7.7).

### 7.1 What differs from the fallback image

| | `ddb168e1…` | `20f8b265…` |
|---|---|---|
| A `seed` word | four 4-bit symbols of the four rings | 16 consecutive bits of one ring, lane 0 (the 3-stage ring) by default |
| Health tests | on the 4-bit symbol and on each lane | repetition count at lags 1 to 4 and adaptive proportion (W = 1024), on that bit only |
| `mentropycfg` after reset | `0x30c7c1eb3c37000f` | `0x30c0000b3c37000f` with the spacing floor at k = 16; `…003f` at k = 64 |
| `mentropystat` | state, alarm, strikes, last failure | the same, and the lane in [21:20] and the spacing floor in [23:22] (0: k = 16, 2: k = 64) |
| First `seed` word after a reset | about 56.7 ms | 59.4 ms at k = 16; about 238 ms at k = 64, from simulation |
| Rings | four | six: the four lanes and two 3-stage reference rings, which are off outside test mode |
| Ring counters | none | one per ring, behind a divider by two: a count is two ring periods. Read through the meter, in test mode |
| Authentication ROM | at most 200,000 polls of `seed` per word | at most 2,000,000 |
| Scripts and fixtures of stages D and G | commit `ace91d5` | the current sources |

### 7.2 Before the build and before the session

1. **Decide which conditions the assessment is to name:** supply voltage,
   die temperature, and activity on the board (the Ethernet link up or
   down, what else runs). Each needs its own data in 7.4 and 7.7. A
   condition that is not captured is not in the assessment: the stated
   range is what was measured.
2. **Screen lane 0 on the data already on the lab host, before the session**
   (step 1 of Z7's board procedure; no board). D20, S20 and R20 are
   the files of the
   [assessment, section 2](../doc/sp800-90b-assessment-2026-11-20.md#2-scope-and-data);
   lane 0 is bit 0 of every 4-bit sample:

   ```sh
   lane0() { python3 -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(bytes(b&1 for b in d))" "$1" "$2"; }
   lane0 d20-sym4.bin d20-lane0.bin; lane0 s20-rows.bin s20-lane0.bin; lane0 r20-rows.bin r20-lane0.bin
   ea_non_iid -a -v d20-lane0.bin 1
   ea_restart -n -v s20-lane0.bin 1 <the estimate>     # 1,000 rows of 1,000
   ea_restart -n -v r20-lane0.bin 1 <the estimate>     # the cross-check
   ```

   The rate cannot be stated above this estimate, so an estimate below
   0.75 bit per bit, or a restart test that fails, disqualifies k = 16: take
   the k = 64 strap variant (7.6) to the session. A pass supports the
   candidate and no more.

   **Result (2026-11-23):** lane 0 of D20 as a binary source is 0.864 bit
   per bit by `ea_non_iid` (the compression estimate is the lowest), and
   `ea_restart` at that value passes on lane 0 of S20 (X_max 563 against a
   cutoff of 618; H_r 0.898, H_c 0.844) and of R20 (561; 0.828, 0.812). The
   lane-0 files and the tool outputs are in
   `_build/nist-90b/data/*-lane0.bin` and
   `_build/nist-90b/results/*-lane0-*`.
3. **From the build log**, record the six `KARU_ROSC_COUNT` lines and the
   `KARU_STRAP` line (`lane=0 kshift=0 (k at least 16) rings=0x0f` for the
   default image). A `KARU_ROSC_COUNT` line has, for one ring: its
   halves, each taken as at least 0.48 of the period; its period in the
   slow and the fast corner; the six conditions of its divider as shares
   of their limits, each at most 80 %, in four states with every delay
   from one column of the timing model, and, for information only, with
   the corner's minimum and maximum mixed; the counter clock's period and
   shorter pulse against the declared clock; Vivado's pulse-width report
   at the counter clock pins against the flip-flop's limits; the slack
   between the Johnson flip-flops; and how far the sampled bits and the
   coarse counters are apart at the samplers. Every line must end in `ok`,
   or the build stops. The 0.48 and the 80 % are engineering allowances,
   so the lines are the timing model's word that the divider divides by
   two, not the device's; 7.3 is the board's.

### 7.3 First: qualify the instrument

No capture is used before this passes. The routed check of the build
cannot show that the divider divides by two on the device: it rests on
engineering allowances, not on a measured pulse width for every ring. A
counter that miscounts would give wrong variances without any other sign.
So the two ratio checks, steps 3 and 4, are mandatory on every running
ring of the final image before any of its counts is used for a bound, and
the instrument is qualified only when both pass. Conditions as for stage
D: SW12 all off, OpenOCD running as in stage C, the hart reset-halted with
the fixture.

1. **A short run of the capture:** `KARU_BOARD_ROSC_SCALE=0.1 python3
   test/dbg/board/rosc_count.py`, about a quarter of an hour. The script
   takes no arguments. For each ring mask (`0x0f`, then `0x3f`) it takes
   records at four spacings, counted behind the divider (`count_unit` 2
   in the sidecar), and one capture in direct mode, where the ring itself
   clocks the counter (`rosc-direct-…`, `count_unit` 1). Then it takes
   bursts of every ring's count in an upper and a lower view, in both
   counting modes, and bursts of the reference rings' bits under
   `refbits/`. [The harness README](../test/dbg/board/README.md#meter-capture)
   has the settings, the files and the failure statuses.
2. **The meter's flags are zero.** The meter flags a clock in which an
   enabled ring's count could not be read or its increment differed from
   the one before by more than 2. The sidecar has them for every run,
   `bad_counts` and `bad_rings`, and the last line that the script prints
   lists every capture with a flagged clock. No capture counted behind
   the divider may be on that list. In direct mode a flagged count may
   come with reason; record it.
3. **The two counting modes agree** (the divider divides by two): for
   each ring mask,
   `python3 test/dbg/board/rosc_own.py $KARU_BOARD_OUT/rosc-count-p256-e4-m0f.bin --pair $KARU_BOARD_OUT/rosc-direct-p256-e4-m0f.bin --text`
   (and the same with `m3f`). It compares, ring by ring, the rates of the
   two captures in ring periods per clock, which must be equal; the
   counts are then in the ratio two. It sees a count wrong by a whole
   number of periods per clock unless both modes share the error, and it
   cannot tell which mode is wrong.
4. **Each ring's count rate agrees with the frequency of its sampled
   bits,** which pass no counter and no divider:

   ```sh
   python3 test/dbg/board/getnoise_analyze.py $KARU_BOARD_OUT/refbits/getnoise-burst-p*.bin
   python3 test/dbg/board/rosc_own.py $KARU_BOARD_OUT/rosc-count-p256-e4-m3f.bin \
       --bits $KARU_BOARD_OUT/refbits/getnoise-analysis.json --text
   ```

   The reference-bit bursts cover lanes 0 and 1 and the two reference
   rings, with all six rings on, so they go with a records file of mask
   `0x3f`; the default `--bits-map` is theirs. For the 7- and 9-stage
   rings give `--bits` the `getnoise-analysis.json` of ordinary one-clock
   bursts of `getnoise_burst.py` (stage D), with
   `--bits-map 0:0,1:1,2:2,3:3` and a records file of mask `0x0f`.
   Every ring the map names and that runs in the capture must have a
   usable frequency and agree; one without a usable frequency fails the
   step. This compares only the folded frequency, the fraction of a
   ring's periods per clock: a count wrong by a whole number of periods
   per clock passes it. That is what step 3 is for.
5. **The count bursts in both views** (`rosc-burst-r<R>-hi`, `-lo`, and
   `rosc-direct-burst-…`): the flags in their sidecars are zero for the
   bursts counted behind the divider. In the upper view a count that is
   wrong by sixteen shows as a step of four. No script analyses these
   files; bring them back.

If 2, 3 or 4 does not hold, stop: see 7.9.

### 7.4 Then: the captures of the jitter

Acceptance step 2 of Z7: the ring's own jitter, and a lower bound on it
where the model holds. Only a capture counted behind the divider and
taken with the rings of normal operation can carry a bound. Without a
bound the captures still give the measured jitter that the assessment
cites.

1. `python3 test/dbg/board/rosc_count.py` with its default settings, and
   the conditions of the run in `KARU_BOARD_ROSC_NOTE`: a record every
   256, 1,024, 4,096 and 16,384 clocks, first with the rings of normal
   operation (mask `0x0f` for the default image) and then with all six.
   Reading the records back through the debugger takes most of the time:
   about an hour and 45 minutes in all, by the readout rate of earlier
   captures. The phase reads the die temperature and the supplies before
   and after each capture.
2. Repeat 7.3 steps 2 to 4 on this run's files: only a run whose
   instrument checks hold is used.
3. For every records file of the operating mask (`rosc-count-*-m0f.bin`
   for the default image):
   `python3 test/dbg/board/rosc_own.py <file>.bin --text` (it reads
   `<file>.json` beside it). It prints each ring's own phase variance
   from the pairs of rings, for lane 0 the one-sided 99 % lower bound on
   the part that grows in proportion to time, the assumption checks, and
   for the spacings of 4,096 and 16,384 clocks a verdict: `pass`, `fail`
   or `not established`. A pass needs a bound of at least twice the
   variance that 0.75 bit needs at the measured duty-cycle bound, every
   assumption check, no flagged count and at least 300,000 usable
   records. A capture whose records are further apart than a spacing
   gives no verdict for it.
4. **One accepted capture for every condition of 7.2 step 1,** one
   artifact directory per run, and also after a reconfiguration and after
   a `CPU_RESET`. The rule asks for the margin in every accepted capture.
   A capture that is to carry a bound has at least 300,000 usable
   records: those in the blocks that enter the fit, after runs with a
   flagged count are set aside (`rosc_own.py` gives them beside the
   records of the runs kept). With fewer, the analysis's checks of its
   assumptions miss small violations, and `rosc_own.py` gives no pass.
   The defaults, a million records and 400,000 at 16,384 clocks, leave
   room for exclusions, and the sidecar's `for_bound` must be true. A
   short capture is for bringing the instrument up, not for a bound;
   `--min-records` is for the analysis's own tests and is never used on a
   capture that is to carry a bound.

`rosc_own.py` is validated on generated rings with counts of two ring
periods, as the meter gives them (the bound at or below the truth in
99.8 % of 17,400 trials, no pass in 6,000 trials without own white noise).
No check inside one capture can see a wrong count unit, which is why the
qualification of 7.3 comes first.

### 7.5 Cross-checks

None of these can carry a bound; each has to agree with 7.4 or be
explained.

- The captures with all six rings (`…-m3f.bin`): `rosc_own.py` analyses
  them in full and marks them `cross-check only`. Six rings test the
  analysis's model of the shared disturbances with eight degrees of
  freedom, four dissimilar rings with one.
- The captures in direct mode (`rosc-direct-…`): `cross-check only` as
  well, whatever their rings.
- The reference bits, without the counters:
  `python3 test/dbg/board/entropy_claim.py --analysis $KARU_BOARD_OUT/refbits/getnoise-analysis.json --own $KARU_BOARD_OUT/refbits`
  (it needs scipy). It gives the own variance of lane 0 and of the two
  reference rings from the decay of the product of their bits. It reaches
  a few hundred clocks, not the spacing.

### 7.6 A strap variant, if 7.4 asks for one

If 7.4 passes at 16,384 clocks and not at 4,096 (k = 64), or gives a bound
only from captures with all six rings (7.9), the image for that bound is a
strap variant of this one, not a rebuild. The flow has been run from end
to end on a small real design, not on a full image, and no variant has
been programmed into a board: record the logs. The file names below are
for `STRAP_KSHIFT=2`; with `STRAP_RINGS=0x3f` the tag is `-rings0x3f` in
place of `-k2`.

1. **The variant,** on the build host, from the routed design of the
   image: `make vcu118-strap-variant STRAP_KSHIFT=2` (k at least 64), or
   `STRAP_RINGS=0x3f` (all six rings outside test mode). It refuses a ring
   mask without the lane that `seed` delivers, before it writes anything.
   It writes `_build/vcu118_ddr-k2.bit` and prints the straps as built
   and as written (`KARU_STRAP … kshift=2 (k at least 64)`). It also
   writes the checkpoint's own bitstream again and checks that this has
   the image's payload byte for byte, and that the variant differs from
   it only in the changed strap tables, their frames' check bits and CRC
   words (`STRAP_DIFF` lines). The record
   `_build/vcu118_ddr-k2.strap.json` names image, checkpoint, variant and
   log by their hashes.
2. **Its bundle:** `make vcu118-strap-bundle STRAP_KSHIFT=2`, which
   requires that record and gives the variant its own authentication
   record and `_build/vcu118_programming-k2.tgz`. The key is the image's.
3. **Programming,** on the board host:
   `KARU_BITFILE=vcu118_ddr-k2.bit flow/with_vivado.sh make prog_vcu118_ddr`.
4. **7.3 and 7.4 again, on the variant.** The sign-off asks for all its
   parts on the same final image. The captures of the image it comes from
   say what to expect, because a variant has that image's rings wire for
   wire.

### 7.7 The spacing: data, health tests and boot checks

Run these checks on the final image and spacing, in every condition that
the assessment is to name.

1. **Fresh sequential data:** `KARU_BOARD_GETNOISE_K=16 python3
   test/dbg/board/getnoise_capture.py` (or `=64`): 10⁶ kept symbols. Take
   lane 0 as in 7.2 step 2 and run `ea_non_iid -a -v <file> 1`. The Zkr
   text requires 0.75 bit per bit, so the estimate must not be below it.
2. **Operational restart data:** `python3 test/dbg/board/seed_restart.py`:
   1,000 restarts, the first 1,000 bits of each through `seed`. Then
   `ea_restart -n -v seed-restart-rows.bin 1 0.75`, the assessment's
   proposed estimate; record the trial value, observed maximum, cutoff,
   row and column estimates, and verdict.
3. **The health tests and the failure handling:** stage G with
   `entropy_fault.py`, which shows a start-up failure, each of the two
   tests, the alarm, the strikes to `DEAD`, forgiveness, and the limits
   and the lock, and measures through `seed` that the spacing outside
   test mode is the floor.
4. **The spacing from the first word:** `mentropycfg` read after a reset,
   before any software has run, holds the floor as its interval, and the
   timing of the first word in `seed-restart.json` fits it (59.4 ms at
   k = 16, about 238 ms at k = 64, after the reset). No software sets the
   spacing.
5. **Boot checks**, each from a power-on (`CPU_RESET` or reconfiguration),
   without stopping U-Boot at its prompt, and each recorded with two
   observations besides the login: whether U-Boot printed "No RNG device",
   and whether `/chosen` of the device tree that Linux got holds a
   `kaslr-seed` (over SSH; record its size, not its value):

   | Boot | SW12 | Expected |
   |---|---|---|
   | no authentication request | all off | no "No RNG device"; a `kaslr-seed`; login |
   | with authentication | on, off, on, off, and the `authenticate` case of stage E | unlock; then the same |
   | source off | off, off, off, on | "No RNG device" once; no `kaslr-seed`; login |

   U-Boot's driver gives up on a wait after 100 ms and Linux boots either
   way, so a login alone does not show that U-Boot had its device.

### 7.8 What to bring back, besides section 6

- The build log's `KARU_ROSC_COUNT` and `KARU_STRAP` lines, and for a
  strap variant its log and its `.strap.json` record.
- Every file that `rosc_count.py` wrote, with its sidecar, for every run,
  and what the script printed last (the captures with flagged clocks).
- The output of `rosc_own.py` for each records file, of its `--pair` and
  `--bits` runs, and of `entropy_claim.py --own`.
- For every capture: the condition it stands for (supply, die
  temperature, activity) and how the board was started.
- The lane 0 files and the tool outputs of 7.2 and 7.7.
- For each boot check: the console capture, the "No RNG device"
  observation and the `/chosen` listing.

### 7.9 What each outcome means

| Outcome | Meaning | Then |
|---|---|---|
| A capture ends with status `NOMETER` | the image has no meter | it is not this image |
| 7.3: a capture counted behind the divider has a flagged clock | the meter could not read a count, or a count did not fit the one before | not expected: stop and report which rings and how often. The analysis does not use such a run; a bound needs the cause |
| 7.3: `--bits` flags a ring of a capture counted behind the divider | a count is not two ring periods on that ring: its divider does not divide by two on the device, or its counter miscounts | no capture is used. Direct counting is left as a diagnostic and cannot carry a bound; report it. The remedy is a change of the image |
| 7.3: `--bits` has no usable frequency for a ring that runs | the ratio is not established on that ring | the step fails: no capture is used; report |
| 7.3: `--pair` flags a ring and `--bits` does not | one of the two counting modes miscounts on that ring. Direct counting is outside the flip-flop's guaranteed range and may be the one | the ratio is established by one check only: report, and use no capture until it is explained |
| 7.3 holds | the instrument counts; nothing yet about the jitter | 7.4 |
| `pass` at 4,096 clocks in every capture of 7.4 whose records are that close or closer | lane 0's own jitter clears the bound with the margin at k = 16, under the conditions captured | 7.7 at k = 16, on this image |
| not that, but `pass` at 16,384 clocks in every capture of 7.4 | k = 64 is the candidate | the strap variant of 7.6, then 7.7 at k = 64 |
| `pass` under some conditions and not under others | a bound holds only for the conditions that passed | name those conditions with the bound |
| a bound only from captures with mask `0x3f` | it does not hold for an image that runs four rings | the image for that bound is the variant with `STRAP_RINGS=0x3f` (7.6); capture again on it |
| `fail` | not even the upper end of the estimates gives the variance that 0.75 bit needs | the ring's own jitter does not support the rate at that spacing; report |
| `not established` | no bound from this capture: too few records, an assumption check that failed or could not be made, locked rings, or estimates that disagree. The outcome on `20f8b265…` | read the reason that the tool gives; more records if it says they would decide; otherwise report the measured jitter and the reason. The rate then stays a proposal, supported by the measured sizes and the estimates of 7.7, until the fresh share of the jitter is justified |
| every verdict passes | a lower bound under the meter's model; the assessment has to justify each assumption for the final image, from the checks and from the physics of the rings | bring everything back; if the explanation stays open, the outcome is the measured numbers without a bound |
| 7.5: a cross-check disagrees with 7.4 | an assumption of the analysis does not hold as the bound needs it | report; no bound until it is explained |
| 7.7: the estimate is below 0.75 bit per bit, or a restart test fails | the rate at `seed` falls short of what the Zkr text requires | that spacing is out |
| 7.7: a health-test case does not show what stage G expects, or the spacing is not the floor from the first word | the behaviour at `seed` is not shown | report; the configuration does not meet the goal |
| 7.7: "No RNG device" or no `kaslr-seed` with the source on | U-Boot's driver gave up before a word came; Linux still boots | that spacing does not pass the boot check; report which boot |
