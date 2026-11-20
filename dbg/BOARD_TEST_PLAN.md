# Board test plan: the VCU118 debug image

For the VCU118 debug image ([FPGA guide](../doc/fpga.md#debug-image)): the
2 MiB boot ROM, the Zkr entropy source with its health tests, the burst
capture and the temperature readout, debug authentication with SHA3-256
(algorithm `0x04`) and the SW12 straps, and U-Boot v2026.10. The current
bitstream is `ddb168e1…`. Its latest run is the
[2026-11-20 record](BOARD_ACCEPTANCE-2026-11-20.md): accepted with
documented exceptions (translation fails with the known pristine-OpenOCD
walker results). Ask for the CPU reset button by its label `CPU_RESET`
(PROG clears the FPGA), and allow about 4.5 minutes per boot and 30–55 s
per SSH connection (the harness defaults do).

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
back to the previous accepted image, `85f07e58…` (archived on the build
host in `_build/fpga_archive/2026-11-18-85f07e58/`); copy its bundle over
before the session.

| | |
|---|---|
| Bitstream `_build/vcu118_ddr.bit` | SHA-256 `ddb168e1081c9b73c29cd5a16ab777ee8106a52d382469b5b741b094bc096aad`, 80,159,322 bytes |
| Bundle `_build/vcu118_programming.tgz` | SHA-256 `88dce485fadad7c63ba42e07bd7ed5f2124d69bbef8ca2f1a53b7b8c54817342`, mode 600: it holds the authentication key |
| Configuration | `KARU_RVA23S64`, `KARU_DBG`, `KARU_DBG_FULL`, `KARU_DBG_AUTH`, `KARU_ZKR`; 75 MHz |
| Timing | meets 75 MHz: setup +0.008 ns, hold +0.011 ns, pulse width +0.005 ns; no DRC errors |
| Boot ROM | OpenSBI v1.9 `cbbbe5ce…`, U-Boot 2026.10 with the Zkr time-out patch (`7a27c424…`, 802,453 bytes), device tree `784e2762…` (`rva23s64-zkr-ddr`); fu-boot and U-Boot built by `$RISCV/bin/riscv64-unknown-elf-gcc` (recorded in the ROM manifest of the bundle) |
| Island ROM | `f518b750…`: algorithm `0x04`, SHA3-256 with a shared secret, key fingerprint `276bf6e96d8edecc`; nonce from `seed`; window of 2^30 cycles (14.3 s), and a hardware limit of 2³¹ clocks (28.6 s) behind it |
| Entropy block | health tests on the 4-bit sample and on each lane; `mentropycfg` (`0x7C9`) reset value `0x30c7c1eb3c37000f`; `mentropystat` (`0x7CA`) |
| Sources | karu64 `f014194` with uncommitted changes (the diff and the new files are in `_build/vcu118-2026-11-19b-sources/` on the build host), karudeb `db180ff` |

The figures and their evidence are in
[measurements](MEASUREMENTS.md#fpga-image--2026-11-20). Check the bitstream
hash after the transfer; `_build/vcu118_rom_manifest.txt` in the bundle
repeats it, with the boot command that is baked into the ROM. The bundle's
`vcu118_auth_record.json` ties the key to this bitstream.

**Handling the bundle.** The bundle and the bitstream hold the
authentication key, like the key file. On the board host unpack the bundle
with `umask 077` into a directory of mode 0700, and keep the bitstream
there:

```sh
umask 077; mkdir -m 700 ~/karu-ddb168e1 && tar -C ~/karu-ddb168e1 -xzf vcu118_programming.tgz
```

**Which image is on the board.** U-Boot's banner tells the images apart:
this one prints `U-Boot 2026.10-dirty (Nov 19 2026 - 22:30:01 +0000)`, the
fallback `(Nov 18 2026 - 21:33:44 +0000)`. With debug access, `mentropycfg`
reads `0x30c7c1eb3c37000f` after reset in this image only.

## 1. What the lab host needs

| Item | Where it comes from | Note |
|---|---|---|
| This repository and `karudeb` at the build's sources | git | The device-tree variant `rva23s64-zkr-ddr` is karudeb's |
| `_build/vcu118_programming.tgz` | copy from the build host | Bitstream, `.ltx`, ROM manifest, the device tree that is in the ROM, the authentication record and key |
| Kernel `Image` | the lab's accepted kernel, `3b45e852…`, release `7.4.0-rc3-zvk-dirty` | See section 2 |
| NFS root | unchanged | |

The lab host builds the bare-metal fixtures itself (`make
dbg-board-fixture dbg-getnoise-fixture dbg-getnoise-burst-fixture
dbg-seedcap-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`); they are small and need
only the RISC-V compiler.

## 2. Boot files: keep each bitstream with its own device tree

The ROM manifest in the bundle names the device tree to serve:

| Bitstream | Device tree to serve as `board.dtb` | Kernel |
|---|---|---|
| this image, and the fallback `85f07e58…` | `784e2762…` (`rva23s64-zkr-ddr`; it is `vcu118_rom_board.dtb` in the bundle) | the accepted `3b45e852…` |
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
  and does not count it as entropy. No min-entropy is claimed for the
  source ([SP 800-90B assessment](../doc/sp800-90b-assessment.md)), so this
  is deliberate.

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
the phases read the die temperature and supplies themselves.

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
   first 1,000 samples of each read through `seed` (about 3 minutes), for
   SP 800-90B section 3.1.4. Then `ea_restart -n -v seed-restart-rows.bin 4
   <estimate>` with the k = 16 estimate of `ea_non_iid`.
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
   the 2^24-sample forgiveness case): a start-up failure, each test,
   strikes to `DEAD`, forgiveness, and the limits and lock, on the real
   rings, by stricter cutoffs. It resets the SoC, so take the readings of
   steps 1 and 2 first.

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

What to expect: a challenge at least 57 ms after the power-on (the entropy
source's start-up test), unlock about 0.2 s after the request, and in
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
| No fu-boot banner with SW12 all off | Program the fallback `85f07e58…` | The island ROM hand-over, the 2 MiB ROM or the RTL is at fault; there is no switch that bypasses them |
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
