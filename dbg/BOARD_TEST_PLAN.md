# Board test plan: debug image with Zkr, authentication and the 2 MiB ROM

For the VCU118 debug image built on 2026-11-18 from this tree. It is the
first image with the 2 MiB boot ROM, the Zkr entropy source, debug
authentication and the SW12 straps. **Executed on 2026-11-18: every stage
passes**, apart from the known OpenOCD translation results; the
[acceptance record](BOARD_ACCEPTANCE-2026-11-18.md) has the results and the
deviations. Two of them concern this plan: ask for the CPU reset button by
its label `CPU_RESET` (PROG clears the FPGA), and allow about 4.5 minutes
per boot and 30–55 s per SSH connection (the harness defaults now do).
A newer image, `85f07e58…`, was built the same evening:
[section 7](#7-the-next-image-burst-capture-temperature-readout-sha3-authentication-u-boot-v202610)
has its identity and the steps it adds. It was tested on 2026-11-19; see the
[record](BOARD_ACCEPTANCE-2026-11-19.md).

**The SW12 switches are hard to reach.** Change them as rarely as possible:
group the cases by switch setting, change one switch per step, and use JTAG
reconfiguration (a full power-on, straps sampled again) or the software
reset (hart, peripherals and entropy source; not the authentication block)
instead of the CPU reset button where the test allows.

| | |
|---|---|
| Bitstream `_build/vcu118_ddr.bit` | SHA-256 `d7ff00dc494d8354ce596b3e7ebb07aabb2df92f9df186d8a3870b9a972a3e80`, 80,159,322 bytes |
| Bundle `_build/vcu118_programming.tgz` | SHA-256 `5e93e662769d1f352daf71a5fa5389d2b6ea7e8e5d6a5fbcc01e149db9ed869d` |
| Configuration | `KARU_RVA23S64`, `KARU_DBG`, `KARU_DBG_FULL`, `KARU_DBG_AUTH`, `KARU_ZKR`; 75 MHz |
| Timing | met: setup +0.051 ns, hold +0.011 ns; no DRC errors |
| Boot ROM | OpenSBI v1.9 (`cbbbe5ce…`), U-Boot 2025.01 (`0d305f3f…`), device tree `784e2762…` (`rva23s64-zkr-ddr`) |
| Island ROM | `c6efbc76…`: the `TEST` algorithm, nonce from `seed`, window of 2^30 cycles (14.3 s) |
| Sources | karu64 `d58aa6f` and karudeb `8dfc019`, each with uncommitted changes; `_build/vcu118_build_inputs.json` on the build host lists them and has the hash of every input |

The figures and their evidence are in
[measurements](MEASUREMENTS.md#fpga-image--2026-11-18). Check the bitstream
hash after the transfer; `_build/vcu118_rom_manifest.txt` in the bundle
repeats it, with the boot command that is baked into the ROM.

## 1. What the lab host needs

| Item | Where it comes from | Note |
|---|---|---|
| This repository at the build's sources | git, once the working tree of the build host is committed and pushed | The image was built from uncommitted changes; `_build/vcu118_build_inputs.json` on the build host lists them (it is not in the bundle) |
| `karudeb` at the build's sources | git, likewise | New device-tree variant `rva23s64-zkr-ddr` |
| `_build/vcu118_programming.tgz` | copy from the build host | Bitstream, `.ltx`, ROM manifest, and the device tree that is in the ROM |
| Kernel `Image` | the lab's accepted kernel, `3b45e852…`, release `7.4.0-rc3-zvk-dirty` | See section 2 |
| NFS root | unchanged | |

The lab host builds the bare-metal fixtures itself (`make dbg-board-fixture`,
`make dbg-getnoise-fixture`); they are small and need only the RISC-V
compiler.

## 2. Boot files: keep each bitstream with its own device tree

The ROM manifest in the bundle names the device tree to serve. For this
image it is the `zkr` tree:

| Bitstream | Device tree to serve as `board.dtb` | Kernel |
|---|---|---|
| this image | `784e2762…` (`rva23s64-zkr-ddr`; it is `vcu118_rom_board.dtb` in the bundle) | the accepted `3b45e852…` |
| `d5e603cd…` (2026-11-17, archived on the build host) | `c477784a…` (`rva23s64-ddr`) | the same |
| `0b994847…` (board-accepted 2026-11-16/17) | `d617ba56…` | the same |

- **Never serve the `zkr` tree to an older bitstream.** Linux would execute
  a `seed` access that the hardware answers with an illegal-instruction
  exception, early in boot and without a fallback.
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
  and does not count it as entropy. The source is uncharacterised, so this
  is deliberate. The first-boot time to "crng init done" may be longer than
  before.

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

Stop at the first stage that fails and use section 5.

### Stage A: first boot without the new sources of risk

1. Serve the files of section 2. Set SW12 to off, off, off, **on**.
2. Program the bitstream and capture the UART from the first character.
3. Expect, in order: the fu-boot banner and "copying boot chain from ROM",
   `OpenSBI v1.9` with `zkr` in "Boot HART ISA Extensions" and
   "Platform Reboot Device : syscon-reboot", U-Boot, Linux, the NFS root, a
   login prompt.
4. `KARU_BOARD_ZKR=1 python3 test/dbg/board/linux_zkr.py`: the device tree
   and `/proc/cpuinfo` list `zkr`. With position 4 on this shows that the
   boot does not depend on the entropy source.

This stage exercises, for the first time on hardware: the 2 MiB ROM and
its layout, the hart starting in the authentication island ROM and handing
over to fu-boot, the new scratch SRAM address, OpenSBI finding `zkr` and
writing `mseccfg`, and Linux reading a `seed` that reports `BIST`.

### Stage B: the same with the entropy source on

1. SW12 all off. Press CPU reset.
2. The same console sequence, then `linux_zkr.py` again.
3. Check the console for duplicated characters (the 2026-11-16 symptom; the
   fix is in this image and has not been seen on a board).
4. `python3 test/dbg/board/linux_reboot.py` with the UART capture: three
   software reboots, each through the boot ROM and OpenSBI.

### Stage C: debug acceptance, lifecycle `OPEN`

Follow [the harness README](../test/dbg/board/README.md) with
`KARU_BOARD_IMAGE=rom2m-auth` and a fixture built for it. Two expectations
are new and are checked by the harness itself: a reset-halt stops at
`0x10000`, and the fixture lives at `0x208000`. Translation (step 6) is
still expected to fail with a pristine OpenOCD, as in the last campaign.

### Stage D: raw noise

With SW12 position 4 off and OpenOCD running as in stage C:
`make dbg-getnoise-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT`, then
`getnoise_capture.py`, which captures at k = 1, 2, 4, 8, 16 and 32 by
default, then `getnoise_analyze.py` on the capture files. Put the
conditions of each run into `KARU_BOARD_GETNOISE_NOTE`; the note is stored
beside the capture. This is characterisation, not a pass or fail: bring
the capture files back. Beyond the single run:

- repeat after several cold starts (reconfiguration) and several CPU
  resets, to see how much the lanes' frequencies and the nonces move;
- capture under different activity if a way to produce it is at hand, and
  note the conditions. The capture runs with the hart under the debugger,
  so Linux cannot provide the load; the Ethernet link being up or down is
  one difference that is easy to make;
- keep the raw four-bit symbols; the analysis of the four lanes together
  is the open question, and it needs the simultaneous values.

If `seed` reports `DEAD` (the source failed its start-up test), the capture
still works: test mode switches a dead source back on.

### Stage E: authentication

`test/dbg/board/auth_phase.py`, one case per run. The
[harness README](../test/dbg/board/README.md#authentication) has the
table of cases with the switch positions and what must be seen. For every
case: set the switches, press CPU reset, start a fresh
`openocd -f test/dbg/board/auth-server.cfg`, then
`KARU_BOARD_AUTH_CASE=<case> python3 test/dbg/board/auth_phase.py`. Each
case first checks from the Debug Module that the switches are what it
needs and says so if they are not. Keep one artifact directory for the
series: `replay` and `fresh-nonce` use the challenges recorded by earlier
cases.

Suggested order:

1. `open` (positions 1 to 3 off). It is also the strap read-back: the
   lifecycle and hold bits of `mdbgauth`, and with position 4 on, `seed`
   staying in `BIST`. Do this first; it confirms the switch wiring and
   polarity before any case depends on them.
2. `locked`, `authenticate`, `fresh-nonce`, `wrong-response`, `replay`,
   `expiry` (positions 1 and 3 on, 4 off).
3. `no-hold` (1 on, 3 off), `entropy-off` (1, 3 and 4 on), `disabled`
   (2 on).
4. `reboot` in the power cycle of a passed `authenticate`, and
   `reboot-locked` after `no-hold`, both with Linux up.

`authenticate` is the first time the ROM draws its nonce from the real
rings: the challenge takes at least 57 ms to appear, the entropy source's
start-up test. The response algorithm is the simulation-only TEST
algorithm, which anyone can compute, so a pass shows that the mechanism
works and nothing about protection.

The same client and OpenOCD were rehearsed against the simulated target
with the same ROM source (`make dbg-board-auth-rehearsal-test`). Not
rehearsable: the BSCAN transport with a locked target, the switches and
the reset button, the ROM constants that differ on the FPGA (nonce from
`seed`, the 14.3 s window), and the cases that need Linux.

### Stage F: Linux acceptance

`board_accept.sh` as for every image, with the lab's kernel, then the KVM
guests. A guest's `seed` access traps to the host by design; the
acceptance does not depend on Zkr inside a guest.

## 5. If something fails

| Symptom | First thing to try | What it tells |
|---|---|---|
| Nothing on the UART after programming | Check SW12 positions 1 to 3 are off; press CPU reset | With 1 and 3 on the hart is held by design |
| No fu-boot banner with SW12 all off | Reprogram `d5e603cd…` or `0b994847…` with its own device tree | The island ROM hand-over or the 2 MiB ROM is at fault; there is no switch that bypasses them |
| Stops in or after OpenSBI | Position 4 on, CPU reset | If it then boots, the entropy path is involved |
| Linux stops early | Serve the plain `c477784a…` tree (and run `linux_zkr.py` with `KARU_BOARD_ZKR=0`) | If it then boots, Linux's use of `seed` is involved |
| Debugger cannot attach | SW12 positions 1 and 2 off, CPU reset | `OPEN` must behave as an image without authentication |
| Harness refuses to start | Read its message: fixture or image kind does not match | `KARU_BOARD_IMAGE` and the fixture must be for the same map |

An image without authentication and Zkr can be built from the same tree
with `VCU118_DBG_EXT_DEFINES=KARU_DBG_FULL`; it uses the plain device tree
and the harness kind `rom2m`.

## 6. What to bring back

- The UART capture from the first boot of each stage.
- The harness artifact directory (`KARU_BOARD_OUT`), with `SHA256SUMS`.
- The GetNoise capture files and their JSON sidecars, with a note of the
  conditions of each (cold start or reset, idle or network active).
- The SW12 positions used for every run.
- For any failure: the last console lines, the switch positions, and which
  row of section 5 was tried.

## 7. The next image: burst capture, temperature readout, SHA3 authentication, U-Boot v2026.10

*Built 2026-11-18, 21:32 to 23:40 UTC; tested on 2026-11-19, all stages pass ([record](BOARD_ACCEPTANCE-2026-11-19.md)).* Sections 1 to 6
were written for bitstream `d7ff00dc…` and apply to this image as well,
with the changes below. The image adds the burst capture for the entropy
source, the temperature and supply readout, the shared-secret
authentication algorithm and U-Boot v2026.10 with the patched Zkr driver
([Zkr follow-up plan](../doc/zkr-followup-plan.md)). All of them were tested
in simulation, and on the board on 2026-11-19
([record](BOARD_ACCEPTANCE-2026-11-19.md)).

| | |
|---|---|
| Bitstream `_build/vcu118_ddr.bit` | SHA-256 `85f07e58354646ff3102fe3ddfe8c2e91005b5171b895391aea7ea3795f2639a`, 80,159,322 bytes |
| Bundle `_build/vcu118_programming.tgz` | SHA-256 `fbdec6e42c75f0c5e236beeede5314f2e7962afb6935bc6615ebf852d6510f38`, mode 600: it holds the authentication key |
| Configuration | as `d7ff00dc…` (`KARU_RVA23S64`, `KARU_DBG`, `KARU_DBG_FULL`, `KARU_DBG_AUTH`, `KARU_ZKR`; 75 MHz), plus the capture block and the readout |
| Timing | met: setup +0.002 ns, hold +0.011 ns; no DRC errors |
| Boot ROM | OpenSBI `cbbbe5ce…` (the same as `d7ff00dc…`), U-Boot 2026.10 with the Zkr time-out patch (`0e560318…`), device tree `784e2762…` (the same) |
| Island ROM | `f518b750…`: algorithm `0x04`, SHA3-256 with a shared secret, key fingerprint `276bf6e96d8edecc`; nonce from `seed`, window of 2^30 cycles (14.3 s) |
| Sources | karu64 `a39f3da` and karudeb `db180ff`, karu64 with uncommitted changes; `_build/vcu118-2026-11-18c-sources/` on the build host holds them (the diff and the new files) |

The device tree and the kernel are those of section 2's first row. The
bundle's `vcu118_auth_record.json` ties the key to this bitstream: packing
the bundle refused to add a key that is not the one in its island ROM.

**Stage E, authentication.** The ROM now answers with algorithm `0x04`:
`auth_phase.py` computes the response from the key file in
`KARU_BOARD_AUTH_KEY`, by default `_build/vcu118_auth_key.txt`, which is
where the bundle puts it when it is unpacked at the root of the repository.
Set `KARU_BOARD_AUTH_ALG=SHA3` for every case, so that a case stops with a
message if the board still runs a `TEST` image. The cases, switches and
expectations are unchanged. A pass now also shows that a debugger without
the key is kept out; the key is in the bitstream and in the bundle, so it
keeps out no one who has either. On `d7ff00dc…` the burst phase stops at
its first case with "no capture block in this image", and the readout
reads zero.

**Stage A and B, first boot.** As before, and look at U-Boot's lines:

- the banner names 2026.10;
- with SW12 position 4 on (entropy source off) U-Boot prints
  "No RNG device" once before it starts Linux, about 0.1 s later than
  before, and boots. A hang at that point would be the released Zkr
  driver, without the time-out patch;
- with position 4 off there is no such line: U-Boot then puts a
  `kaslr-seed` into the device tree it hands to Linux. Whether the kernel
  uses it depends on its configuration (`CONFIG_RANDOMIZE_BASE`);
- `linux_zkr.py` and `linux_reboot.py` as before. Reboot is the test of
  U-Boot's reset path.
- At the U-Boot prompt (stop autoboot with a key), `rng 0 10` prints sixteen
  bytes from `seed` (device 0, 0x10 bytes; `rng 16` would ask for device 0x16
  and print "No RNG device"). `rng list` shows whether the driver is there.

**Stage D2, burst capture.** With position 4 off and OpenOCD running as in
stage C:

    make dbg-getnoise-burst-fixture DBG_BOARD_OUT=$KARU_BOARD_OUT    # also builds the bare-metal fixture
    python3 test/dbg/board/getnoise_burst.py
    python3 test/dbg/board/getnoise_analyze.py $KARU_BOARD_OUT/getnoise-burst-p*.bin

By default this takes 32 bursts of 32,768 symbols at each of the periods
1, 2, 4, …, 256 clocks: about 9 MiB read back through the debugger. It is
characterisation, not a pass or fail; the phase itself fails only if the
bookkeeping does not agree. Then:

- run the k-sweep of stage D again (`getnoise_capture.py`) in the same
  session, and give its files to the analysis together with the burst
  files: the burst capture at 256 clocks and the k = 1 capture should
  agree, and the analysis says whether they do;
- repeat the burst capture after each of three reconfigurations and three
  CPU_RESET presses, with the link up, and once with the Ethernet cable
  unplugged. One artifact directory per run, or move the files: a run
  overwrites the files of the one before;
- write into `KARU_BOARD_BURST_NOTE`, for every run: the bitstream, cold
  start or reset, link up or down. The FPGA's die temperature and supply
  voltages are read by the phase itself (the readout at `0x1000_0860`) and
  stored in the sidecar, before and after each capture;
- bring back all `.bin` and `.json` files. The analysis can be redone
  later; the captures cannot.

**If something fails.**

| Symptom | Try |
| --- | --- |
| U-Boot hangs after "Net:" or before "Starting kernel" | Note position 4. With it on the entropy source is off and `seed` stays in `BIST`: a hang there and not with position 4 off means the Zkr driver waits without bound, so the ROM was built without the patch; boot with position 4 off, and rebuild. A hang with position 4 off is something else: serve the previous image |
| Burst phase: "no capture block in this image" | The image predates the capture block |
| Burst phase: "the noise source is off" | Position 4 is on, or `seed` reports `DEAD`; `getnoise_capture.py` still works on a dead source and shows why |
| Burst phase: payload status `ABORTED` | The source was off during a burst: position 4 was switched on, or the source failed. Note it and repeat. The files of the previous run are kept |
| Burst phase: payload status `TIMEOUT` | A burst did not complete although the source stayed on. Note it, keep the console and the artifact directory, and repeat once |
| Authentication: "the ROM asks for algorithm TEST" | The board runs an older bitstream: reprogram this one |
| Authentication: the response is refused with SHA3 | Check the key file: `python3 flow/auth_record.py verify --record _build/vcu118_auth_record.json --bit _build/vcu118_ddr.bit --key $KARU_BOARD_AUTH_KEY` prints `key` for this bitstream's key and fails for any other |
| Burst phase: payload status `LOCKED` or `BUSY` | Something locked `mentropycfg` or left test mode on; a reset clears both |

