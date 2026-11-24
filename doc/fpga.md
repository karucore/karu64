# FPGA — VCU118 / xcvu9p

`karu64` targets the **Xilinx VCU118** board (part `xcvu9p-flga2104-2L-e`,
Virtex UltraScale+ VU9P), built with **Vivado 2026.1**. The part provides
6840 DSP48E2 units and 2160 36-Kib block-RAM tiles. The full-vector ROM
configuration targets a 75 MHz core clock.

There are two SoC flavours, sharing the same core (`rtl/`) verbatim:

- a **BRAM SoC** (`flow/fpga/fpga_top.v`) with on-chip memory — the simple
  bring-up and console target;
- a **DDR4 SoC** (`flow/fpga/vcu118_ddr_top.v` + `karu_ddr_xbar.v`) with DDR4
  main memory via the Xilinx MIG, Ethernet, and a baked boot ROM — the
  Linux target.

For the core's micro-architecture see [architecture.md](architecture.md); for
simulating the SoC see [flows.md](flows.md).

## Debug image

`make vcu118-ddr-sgmii-rom-rva23s64-dbg` builds the VCU118 debug image with
the default define list `KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR`, at 75 MHz.
It has:

- full debug: autoexec, two address triggers and SBA, reached through the
  USER4 BSCAN tunnel ([karudbg integration](#optional-karudbg-integration));
- debug authentication: the lifecycle and the boot hold on DIP switch
  SW12, the window ROM in the boot island, a SHA3-256 MAC under a key shared
  with the debugger host (algorithm `0x04`), and a hardware limit on the
  window of 2³¹ clocks (28.6 s) behind the ROM's own 2³⁰ (14.3 s);
- Zkr: the `seed` CSR and the ring-oscillator entropy source. `seed`
  delivers the bits of one ring, with SP 800-90B's health tests for a
  binary sample on that bit; `mnoise`, `mentropycfg` and `mentropystat`;
  five more rings, a counter on every ring behind a divider by two, a
  meter and the burst capture, all for characterisation; three soft
  straps; and the die temperature and supply readout
  ([the DDR4 SoC](#the-ddr4-soc-linux-target));
- the 2 MiB boot ROM: fu-boot, OpenSBI v1.9, U-Boot v2026.10 with the Zkr
  time-out patch, the `rva23s64-zkr-ddr` device tree `784e2762…` and the
  lab's boot command;
- the software reboot.

The current debug image is `20f8b265…630a`. It meets 75 MHz (setup
+0.026 ns, hold +0.010 ns, pulse width +0.005 ns; no DRC errors) and uses
377,391 LUTs (31.9%), 92,325 registers, 451.5 block-RAM tiles and 29 DSPs
([measurements](../dbg/MEASUREMENTS.md#fpga-image--2026-11-21)). It is
**board-tested** and accepted with documented exceptions
([record](../dbg/BOARD_ACCEPTANCE-2026-11-23.md)): OpenOCD's software
address translation fails with known walker results, the OpenSSL matrix
needs its completion phase, and five authentication cases were not run.
The OpenOCD and boot/detach findings are in
[the campaign record](../dbg/BOARD_ACCEPTANCE.md).
[The board test plan](../dbg/BOARD_TEST_PLAN.md) has the procedure. The
[SP 800-90B assessment](sp800-90b-assessment.md) covers its entropy
source: NIST's non-IID estimate is 0.810451 bits per sampled bit at the
shipped spacing, against the 0.75 that the Zkr text requires.

The preceding accepted image, `ddb168e1…096aad`
([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)), is kept with its bundle
in `_build/fpga_archive/2026-11-20-ddb168e1/` on the build host. **It has
the four-lane entropy source it was built with, not the one described in
this document:** a `seed` word is four 4-bit symbols of the four rings,
the health tests run on the 4-bit symbol and on each lane, `mentropycfg`
resets to `0x30c7c1eb3c37000f`, and the first word comes about 56.7 ms
after a reset on the board. It has four rings and no reference rings,
counters, meter or soft straps, and its authentication ROM polls `seed`
at most 200,000 times per word
([its assessment](sp800-90b-assessment-2026-11-20.md)).

**Programming bundle.** `make vcu118-program-bundle` packs
`_build/vcu118_programming.tgz`, mode 600, from the build outputs:

- `_build/vcu118_ddr.bit` and `_build/vcu118_ddr.ltx`;
- `_build/vcu118_rom_manifest.txt`;
- `_build/vcu118_rom_board.dtb`, the ROM's device tree, to be served as
  `board.dtb`;
- `_build/vcu118_auth_record.json` and `_build/vcu118_auth_key.txt`;
- `_build/vcu118_ddr.rom.json`, the boot ROM record, when the image build
  wrote one ([below](#optional-karudbg-integration)).

The key makes the bundle secret: whoever has it, or the bitstream, can
unlock the board's debugger. The bundle of `20f8b265…` has SHA-256
`131acaeb…6ceb`. Extract it from the repository root on the programming
host so the `_build/...` paths remain intact. The ROM manifest is read back
from the packed image, and its OpenSBI, U-Boot, device tree and boot
command are compared byte for byte with the build inputs. The lab settings
are server `192.168.42.1`, board `192.168.42.10`, TFTP `Image`/`board.dtb`
and NFS root `192.168.42.1:/srv/nfs/karudeb,vers=3,tcp,nolock`. Routed
reports are under `_build/fpga_rpt/`.

## Profile image (non-debug)

The RVA23S64 DDR/SGMII ROM image `28085356…abbd7` contains the element-group
`vkeccak.vi` (`99078e3`, branch `dev-keccak`). Vivado 2026.1 closed routed
timing at 75 MHz: whole-design setup/hold +0.007/+0.011 ns, `cpu_clk`
+0.244/+0.011 ns, 14/14 bus-skew constraints met and zero bitstream DRC
errors. It was built on a host without the board; the programming bundle
(bitstream, `.ltx`, ROM manifest and the ROM's DTB) at that checkpoint was
`_build/vcu118_programming.tgz`, SHA-256 `1ab66159…c178`. The ROM bakes
the lab netboot command and the karudeb `dev-keccak` (`b3b6abf`) control
DTB `d617ba56…0cec9`. **Validated on the board 2026-10-07**: programmed over
JTAG from this host (`make prog_vcu118_ddr`, 46 s), hands-off ROM netboot to
the Linux 7.2.6-zvk NFS-root prompt in 5.5 min from the reset (kernel at +1:04,
root mounted at +1:18, prompt at +5:28), `board_accept.sh` PASS, and the Zvknhk v0.2 checks
in karudeb (OpenSSL 4.0.2 17/17, riscv-pqc `xtest` 39/39, ML-KEM/ML-DSA KATs
720/720, 20/20 encoding-conformance cases) all pass; see the
[release diagnostics](release-diagnostics-2026-09-14.md#board-validation--2026-10-07).
The NFS root must carry karudeb `b3b6abf` or later software (older `vl=25`
binaries take SIGILL on this image). See also
[building on one host, booting from another](#building-on-one-host-booting-from-another).

## Tool environment

Use the wrapper to load Vivado's settings for one command. It keeps bundled
tools from shadowing the simulation toolchain in the parent shell. Set
`VIVADO_SETTINGS` to the installation's settings file when needed:

```sh
flow/with_vivado.sh make vcu118-ddr       # build -> _build/vcu118_ddr.bit
flow/with_vivado.sh make prog_vcu118_ddr  # separate, explicit JTAG programming
```

The boot/ROM builds compile bare-metal fu-boot, and U-Boot, with the
`XCHAIN` toolchain. Its default is `riscv64-unknown-elf-` by absolute path,
`$RISCV/bin/riscv64-unknown-elf-`, when `$RISCV` has that compiler, and
the name on `PATH` otherwise. The absolute path matters: a name on `PATH`
does not say which compiler runs (a link of that name once gave a build a
Linux-target GCC; see [measurements](../dbg/MEASUREMENTS.md)). Packing a boot ROM runs
`make toolchain-check`, which prints the compiler's path, its
`-dumpmachine` target and its version, and refuses a compiler that does
not target what its name says. The same line is written to
`_build/vcu118_fuboot_toolchain.txt` for fu-boot and for U-Boot, and from
there into the ROM manifest of the programming bundle.

If only a Linux GNU cross toolchain is installed, name it: fu-boot is
freestanding, so it builds fine. Such a compiler writes unwind tables by
default, so fu-boot and U-Boot then carry an `.eh_frame` section (about
1 KiB and 95 KiB); the check notes it.

```sh
flow/with_vivado.sh make vcu118-ddr-sgmii-rom-vec XCHAIN=riscv64-linux-gnu- \
     VIVADO_VMEM_KB=84000000 VIVADO_THREADS=8
```

**File modes.** An image with `KARU_DBG_AUTH` has the authentication key in
its island ROM, and therefore in its three checkpoints and in the
bitstream. For such an image the Makefile runs Vivado with `umask 077`,
and the flow sets those four files to mode 0600 and checks it
(`KARU_PRIVATE` lines in the log), like the key file, the ROM image and
the programming bundle. On the board host, unpack the bundle with
`umask 077` into a directory of mode 0700.

The Makefile launches Vivado from `_build`, so journals, logs, `.Xil`, generated
IP, project state, reports, checkpoints, and bitstreams stay under `_build`. The
sim/Spike targets should use the simulation toolchain's environment.

`make prog_vcu118_ddr` deliberately does **not** depend on the build rule — it
programs volatile FPGA configuration from whatever `_build/vcu118_ddr.bit`
exists (a prerequisite would let make
decide the bitstream is stale and silently start a multi-hour resynth). Build
first, then program.

Programming is **Vivado-version-tolerant**: the bitstream is opaque configuration
data streamed to the FPGA over JTAG, so a lab box running an *older* Vivado can
flash a bit built on a newer one. The deployed full-vector ROM bit (built on
2026.1) programs and boots from a **2025.2.1** `hw_server` / `prog_vcu118_ddr`
without issue. `flow/with_vivado.sh` sources 2026.1 if installed and otherwise
falls back to 2025.2.1, so the same command works on the build host and the lab
JTAG host.

`flow/hw_server.sh start|stop|status` manages the JTAG `hw_server`.
`flow/with_vivado.sh vivado -nolog -mode batch -source flow/hw_scan.tcl`
performs a read-only target/device scan without programming the FPGA.

### Driving the console from the host

The CPU console (NS16550, `console=ttyS0,115200`) is on the CP2105 **SCI** port —
`/dev/ttyUSB1` @ **115200** (the ECI port `ttyUSB0` is unused). Both host helpers
assert RTS, which the CTS-gated NS16550 TX requires:

- `flow/serial_cap.py /dev/ttyUSB1 115200 _build/boot.log` — capture the console
  to an unbuffered, line-timestamped log.
- `flow/hw_monitor.py /dev/ttyUSB1 115200 _build/monitor.log` — send commands
  from stdin to fu-boot, U-Boot or Linux and capture replies (`@wait <s>` sets
  the next command's response window).

The hands-off ROM bit (`vcu118-ddr-sgmii-rom-{gc,vec}`) bakes the netboot bootcmd
and skips console typing entirely — preferred when you control the build.

## The BRAM SoC (`flow/fpga/`)

```
flow/fpga/
  reset_ctrl.v      power-on-reset stretch + 2-FF synchronizer on the async button
  fpga_top.v        board-agnostic SoC: karu64 + BRAM + NS16550. Now the sim top
                    (driven by fpga_tb.v); the hardware board top is
                    vcu118_ddr_top.v (DDR4 main memory).
  karu_axi_mem.v    synthesizable AXI4 memory: imem (RO) + dmem (RW, INCR-burst
                    refill + one/two-beat write-through) from BRAM, 0x10000000 -> UART
  karu_ns16550.v    NS16550-register-compatible UART (wraps uart_tx/uart_rx)
  fpga_tb.v         verilator/iverilog testbench for fpga_top
```

### Memory map (spike-compatible)

| Region       | Base         | Notes                                              |
|--------------|--------------|----------------------------------------------------|
| Main RAM     | `0x80000000` | BRAM (`1 << RAM_XADR` bytes, default 1 MiB) / DDR4 |
| CLINT        | `0x02000000` | `msip` → machine software IRQ; `mtimecmp`/`mtime` → timer IRQ |
| PLIC         | `0x0c000000` | NS16550 = source 1 → `irq_external_m/s`            |
| NS16550 UART | `0x10000000` | one 4 KiB page, uncacheable; `intr` → PLIC          |

`RESET_PC = 0x80000000`, and the RAM base / `.tohost` placement match
`flow/spike.ld`, so the **same ELF runs on spike and on the board**. The layout
is bit-compatible with the default spike machine map, so a spike-targeted DTB
drives this SoC unchanged. Everything outside the DRAM window is uncacheable by
construction, so all MMIO bypasses the L1.

CLINT software and timer interrupts are wired to the core in both SoC
flavours. `mip.MSIP` reflects the MMIO-controlled hardware input and cannot
be set by CSR writes. `make irq-test ddr-irq-test` checks delivery, masking,
clear/rearm and interrupt drain with vector memory operations in flight.

### NS16550 console — one binary for spike and hardware

Spike has a builtin 16550 at `0x10000000` (`reg-shift=0`, `reg-io-width=1`,
IRQ 1). `karu_ns16550.v` mirrors that register layout (RBR/THR@0, IER@1,
IIR/FCR@2, LCR@3, MCR@4, **LSR@5**, MSR@6, SCR@7), so the driver
`test/fw/ns16550.c` is identical on both: develop on spike with a real console,
run the same image on the FPGA. Two conventions matter:

> **Byte-wide accesses only.** spike rejects any access whose width ≠ 1;
> `test/fw/ns16550.c` uses `volatile uint8_t *` throughout.

> **RX consume = a read of RBR.** As on a real 16550 and on spike, reading RBR
> (offset 0, DLAB=0) takes the received byte, and the byte taken is the one
> that read returns. `sio_getc()` still writes SCR (offset 7) after the read.
> That is left over from an earlier explicit-pop protocol and is now a
> harmless scratch write on both, so one binary advances exactly once on
> both. The receiver holds one byte and has no FIFO: a byte that is not read
> before the next one completes is overwritten. (The shared binary was
> validated on hardware — it caught a real directed-rounding FP bug that only
> showed on the fpga_top path, since the FP multiplier read `rm` live at
> result time instead of latching it at `req`.)

In simulation `karu_ns16550` swaps the serializer for an immediate `$write`
under `SIM_TB`; `+uart_in=<file>` models RX. See [flows.md](flows.md) for
`make fpga-sim` / `make spike-uart` / `make irq-test`.

### Reset and status LEDs

Reset is conditioned by `reset_ctrl` (power-on stretch + 2-FF synchronizer).
Two buttons assert reset (XOR'd): the dedicated **CPU_RESET** pushbutton
(`btn_rst_i`) and the **centre** of the 5-way pad (`btn_i[4]`), both with
`set_false_path`. `led_o[7:0] = {trap, rxd, txd, rts, cts, soft_rst,
sec_cnt[0], cyc_cnt[24]}`: `led[1]` is a ~0.5 Hz heartbeat, `led[0]` a faster
one (clock alive), `led[5]` flickers during TX, and **`led[7]` (trap) stays
OFF** in normal operation.

## The DDR4 SoC (Linux target)

For Linux, main memory moves to **DDR4 via the Xilinx MIG**. `karu_ddr_xbar.v`
merges the core's imem + dmem onto one AXI4 master toward the MIG user interface
and peels the CLINT/PLIC/UART/Ethernet MMIO off on-chip. The DRAM window is the
full **2 GiB** (`is_dram = pa[31]`). The MIG is generated by board automation
(`make mig-vcu118`: part `MT40A256M16GE-083E`, 512-bit AXI). The read-only
**I-cache is on by default** in DDR builds because they pay real
instruction-memory latency.

- **Ethernet:** a standalone **LiteEth** wishbone MAC (`flow/fpga/eth/`, a
  vendored LiteX core + the `karu_eth` wishbone↔AXI bridge on the `0x1100_0000`
  MMIO window), driving SGMII to the on-board DP83867 PHY. The upstream
  `liteeth` driver and a U-Boot S-mode payload complete the netboot
  path (U-Boot v2026.10).
- **Hands-off boot ROM:** `flow/boot/vcu118_fuboot.c` (fu-boot) is baked into a
  2 MiB boot ROM together with OpenSBI, U-Boot, and the control DTB. fu-boot
  copies each blob to DRAM and chains OpenSBI → U-Boot → netboot — no JTAG/host
  stage. The CPU auto-boots once MIG calibration completes. The legacy "hold CPU
  in reset, load DRAM over JTAG-AXI, release via VIO" bring-up path is gated
  behind `KARU_DDR_HOST_DBG` (off by default; no debug scaffold in the shipped
  bitstream).

  The ROM is packed by `flow/build_fuboot_rom.sh` at the offsets defined in
  the Makefile (`FUBOOT_*_OFF`); the same offsets are baked into fu-boot via the
  generated `flow/boot/fuboot_blobs.h`, so the two must agree exactly. The
  map; the core address is the offset plus `0x1000`:

  | Blob    | ROM offset  | Region   | copied by fu-boot to |
  |---------|-------------|----------|----------------------|
  | fu-boot | `0x000000`  | 60 KiB   | (runs in place)      |
  | (empty) | `0x00F000`  | 80 KiB   | core `0x1_0000..0x2_3fff`: the debug authentication island |
  | OpenSBI | `0x030000`  | 956 KiB  | `0x80000000`         |
  | (empty) | `0x11F000`  | 4 KiB    | core `0x12_0000`: the Debug Module's private page |
  | U-Boot  | `0x120000`  | 880 KiB  | `0x80200000`         |
  | DTB     | `0x1FC000`  | 16 KiB   | `0x81B00000`         |

  The generated blob-size header is refreshed on every ROM build, and the
  packer rejects any region overrun, and anything placed in either empty
  range, before P&R. Both ranges are decoded by debug logic in front of
  the ROM. The private page is also excluded from the ROM in the core's
  access permissions, so an access to it outside Debug Mode still faults;
  the first version of the 2 MiB map missed that, and the gate's debug
  core tests caught it. The scratch SRAM that fu-boot uses moved with the ROM's
  end, to `0x201000`. The size is one constant, `KARU_BOOT_ROM_PAGES` in
  `rtl/karu_bootmap.vh`, shared by the core's access permissions
  (`rtl/karu_pma.vh`), the boot memory and the bus decode. A full 2 MiB
  ROM would be 512 of the device's 2,160 block RAMs; the ROM takes 384,
  which is what remains when the two 256 KiB stretches of the layout that
  hold nothing (ROM offsets `0x80000..0xFFFFF`, the unused upper part of
  the OpenSBI region) are left out. The debug image `20f8b265…` uses
  451.5 block-RAM tiles in all.

  Build the companion firmware with `make -C ../karudeb karu-opensbi` when
  needed (OpenSBI v1.9; 277,712 bytes of the 956 KiB region). The vector ROM uses `build/karu64/opensbi/fw_jump.bin` and
  `build/karu64/karu64-zvk-ddr.dtb` from that checkout, the profile ROM
  `build/karu64/karu64-rva23s64-ddr.dtb`, and the debug image, which is
  built with `KARU_ZKR`, `build/karu64/karu64-rva23s64-zkr-ddr.dtb`; do not
  substitute firmware from a different image series. The embedded DTB and
  the separately TFTP-served `board.dtb` should be identical. The one
  deliberate exception is serving the plain `rva23s64-ddr` tree to the
  Zkr image, which makes Linux leave `seed` alone; the reverse, the `zkr`
  tree on an image without the CSRs, must never be done. OpenSBI moves the DTB from
  `0x81B00000` to `0x81C00000` (its `FW_JUMP_FDT_OFFSET`) for U-Boot; Linux
  receives the TFTP copy at `0x84000000` instead.

  After U-Boot relocates to DRAM, its baked netboot bootcmd (from the per-profile
  one-liner in `../karudeb/build/karu64/tftp/<variant>/uboot-netboot-one-line.txt`)
  TFTPs the kernel to `0x80200000` and the board DTB to `0x84000000`, then
  `booti 0x80200000 - 0x84000000`. The kernel `Image` `text_offset` is `0x200000`
  and DRAM base is `0x80000000`, so `0x80200000` is the required load address; the
  DTB at `0x84000000` (64 MiB in) clears the ~5 MiB kernel image. The one-liner's
  `serverip`/`ipaddr`/`nfsroot` must match the deployment's link — regenerate the
  staged files in `../karudeb` (e.g. `TFTP_SERVER=… NFS_SERVER=… GUEST_IP=…
  DTB_VARIANT=zvk-ddr ./scripts/stage-karu64-tftp.sh`) so the baked bootcmd and the
  control DTB agree on the network before building the ROM bit.
- **Software reboot (board-tested; each reboot goes through the boot ROM
  and OpenSBI):**
  the SoC has a system-control register at `0x1000_0800`, in the upper half
  of the UART's page. A privileged 32-bit write of `0x7777` resets the hart,
  the peripherals and both sides of the DDR AXI path, and the boot ROM runs
  again. DDR calibration, DRAM contents and the debug module survive.

  - **Software path.** Linux and U-Boot reboot through OpenSBI's system-reset
    call. OpenSBI's generic `syscon-reboot` driver writes the register, which
    it finds through the `syscon@10000800` and `reboot` nodes of the control
    DTB. Those nodes are in karudeb's profile device tree; no OpenSBI or
    kernel change is needed. The profile DTB with them has SHA-256
    `c477784a…5fa88f`.
  - **What the register accepts.** Only a write of exactly four bytes to
    register 0 with the value `0x7777` and a privileged bus attribute. M- and
    S-mode accesses and debug system-bus writes are privileged; U-mode
    accesses are not. Everything else written to the block is ignored, and
    it reads as zero. The core has no PMP, so an S-mode kernel can write the
    register directly as well as through OpenSBI.
  - **Reset path.** The request is a one-cycle pulse from logic that the
    reset clears. `karu_soft_reset.v` holds it for 256 CPU clock cycles and
    feeds the reset sequencer that `ndmreset` uses
    (`dbg/karudbg_fpga_reset.v`). Only the debug-enabled image has that
    sequencer: other VCU118 images accept the write and keep running, and
    OpenSBI then halts as it did before.
  - **Tests.** `make ddr-reboot-test` boots a firmware twice on the DDR
    simulation top and has seven decode mutants. `make dbg-fpga-reset-test`
    covers the sequencer with two mutants, requires the held reset to be a
    single flop, and checks the board top's reset wiring on its parsed
    netlist, since the board top itself is not simulated.
    `make sbi-reboot-test` runs the whole chain in simulation: the fu-boot
    ROM, karudeb's OpenSBI and DTB, and an S-mode payload that requests the
    reboot through SBI; with the `reboot` node removed OpenSBI must not
    offer system reset. It takes about twenty minutes and is not part of
    `make dbg-test`. On the board, `test/dbg/board/linux_reboot.py` is the
    check to run: it requires Linux to restart and, from the UART capture,
    the boot ROM and OpenSBI banners in between, since a restart alone would
    not show a hardware reset.
- **Straps on DIP switch SW12.** The four GPIO DIP
  switches are read as straps (`dip_i[3:0]`, position 1 is bit 0, on is 1).
  With all four off the image behaves as one without the features they
  control, so each is also the way to take a feature out of the boot if it
  misbehaves:

  | Position | Off | On | Needs |
  |---|---|---|---|
  | 1, 2 | lifecycle `OPEN`: the debugger works as before | 1 on: `AUTH`, the debugger must authenticate; 2 on: `DISABLED` | `KARU_DBG_AUTH` |
  | 3 | boot normally | hold the hart in reset until a debugger asks (only in `AUTH`) | `KARU_DBG_AUTH` |
  | 4 | entropy source on | entropy source off: `seed` stays in `BIST` | `KARU_ZKR` |

  The lifecycle and hold straps are sampled at power-on reset. The switch
  is SW12, active-high, factory default all off (UG1224, Table 3-29:
  SW12.1 B17, SW12.2 G16, SW12.3 J16, SW12.4 D21, LVCMOS12). For a first
  boot of a new image leave positions 1 to 3 off; position 4 on is a
  useful first control, because the boot then does not depend on the
  entropy source at all. With positions 1 and 3 on the hart is held in
  reset until a debugger asks, by design: that is not a hang.
- **Entropy source and Zkr (`KARU_ZKR`).** The core gains the `seed` CSR,
  `mseccfg` with `SSEED` and `USEED`, and three custom M-mode CSRs. Behind them:
  - `flow/fpga/karu_rosc_rng.v`: six free-running inverter rings, each
    sampled by one flip-flop. Four are the lanes of the raw 4-bit bus (3,
    5, 7 and 9 LUTs); two are reference rings of 3 LUTs, built and loaded
    like lane 0 and not on the bus. A reference's sampled bit never
    reaches the raw bus; the burst capture can record it. Nothing combines
    or whitens bits. One lane, lane 0 by default, supplies `seed`. The
    other five rings carry no entropy credit and exist to characterise
    that one. The ports are those of OpenTitan's raw noise source, with
    additions for the measurement: the sampling period, an enable per
    ring, the reference rings' bits, the counts and the counting mode.
    **No flip-flop is clocked by a ring.** A slice flip-flop of this part
    needs a clock period of at least 0.550 ns and high and low pulses of
    at least 0.275 ns (Vivado's library), and the 3-stage rings run at
    0.37 to 0.83 ns over the timing corners. So each ring has a divider
    by two between it and its counter (`karu_rosc_cnt`): two latches, each
    one look-up table (the explicit `LUT3` cells `div_m` and `div_s`),
    and a selector (`div_x`), whose output is the counter's clock. The
    counter is an 8-stage Johnson counter, with nothing between its
    flip-flops but one inverter, and two 2-bit coarse counters clocked
    half a cycle apart. It is sampled into the clock domain in every clock
    and decoded to a count modulo 64. **A count is in units of two ring
    periods.** The decode reads each coarse counter only well away from
    its own change, at least three counts after it and four before, and
    reports a sample that is not a valid code. The counter always runs,
    so a ring is loaded the same in test mode and outside it. Each ring
    also has its own enable and clear.
    A diagnostic mode of test mode, direct counting, puts the ring itself
    on the counter's clock; a count is then one ring period. For the
    fastest rings that is outside the flip-flop's guaranteed range, so the
    mode is a diagnostic and a cross-check of the divider on the board,
    and a capture taken in it never carries a bound. The mode changes only
    while every ring is off, which the noise source arranges itself.
  - `flow/fpga/rosc_constraints.tcl` checks that synthesis kept every
    stage, places every ring stage, the three look-up tables of every
    divider and every counter flip-flop by hand (set `KARU_ROSC_BASE` to
    move them), and keeps everything else out of those slices. It
    declares each counter's clock to the tool, with a period of 0.68,
    0.92, 1.36 and 1.72 ns for rings of 3, 5, 7 and 9 stages: a little
    under twice the ring's fastest period, less the duty allowance below,
    so that Vivado's own setup and pulse-width checks, which use the
    declared waveform, bound the counter's real clock. It marks the
    latches' loops as allowed and cuts the paths into the sampling
    flip-flops from timing (`KARU_ROSC_CONSTRAINTS` and `KARU_ROSC_PLACED`
    in the log).
    The rings and the dividers' latches are combinational loops by design:
    24 of them, six rings and eighteen latch loops, which Vivado reports
    as `LUTLP-2` warnings. They are the only loops allowed. The flow runs
    the `LUTLP-1` check right after synthesis and stops on any other loop
    (`KARU_LOOP_CHECK` in the log), because `write_bitstream` would refuse
    the design two hours later. A loop can also come through the CSR
    path: if the value read from `seed` depended combinationally on a
    value being written to another entropy CSR, every CSR set and clear
    instruction would close one. `make zkr-loop-test` checks that without
    Vivado.
    After routing, every image build reads the routed design, prints one
    `KARU_ROSC_COUNT` line per ring, and stops unless all of the checks
    below hold. Each is evaluated in four uniform states, every delay
    taken from one column of the timing model (slow corner max and min,
    fast corner max and min), because neighbouring cells move together
    with voltage, temperature and process; these four states are the
    build's gate. The ring's two halves are summed edge by edge round its
    loop, following each arc's sense. The model of this part gives every
    look-up-table arc the same rising and falling delay and every route
    one delay for both edges, so the model's ring has a duty cycle of
    exactly one half. The silicon's does not (lane 0's sampled bit was
    high 0.511 of the time on the board, image `ddb168e1…`), so each half
    is taken as at least 0.48 of the period (`KARU_ROSC_DUTY_MIN`), and
    each pulse of the divided clock as at least 0.96 of a ring period.
    That is an engineering allowance, twice what lane 0 showed, not a
    measured minimum for every ring. The checks:
    - the six conditions under which the two latches divide by exactly
      two, each edge where it acts, each at most 80 % of its limit, an
      engineering allowance for neighbouring cells to differ;
    - the counter clock's period and shorter pulse at least the declared
      period and half of it, and at least 1.1 times what the flip-flop
      needs;
    - the tool's own pulse-width report at every counter flip-flop
      (minimum period, high and low pulse, both corners) without negative
      slack; the flip-flop's limits are taken from that report;
    - no negative slack between the Johnson flip-flops at the declared
      period;
    - the spread of the sampled bits' routes at most half a counter
      period, all eight of them (Vivado's bus-skew constraint reaches
      six: bits 0 and 7 also clock the coarse counters, so the router
      treats them as clock sources and warns that it cannot apply it);
    - a coarse counter at most 2.5 counter periods early or late at its
      sampler;
    - fewer than 56 ring periods per clock in the fast corner: the meter
      unwraps a count modulo 64, also in direct counting.

    The other checks do not cover direct counting, by design. The log
    also gives each divider condition with the timing model's minimum and
    maximum of one corner mixed against it, for each delay separately and
    without removing the pessimism of the common path: on the small design
    below, up to 127 % of the limit for the 3-stage rings and 171 % for
    the skew condition of the 7-stage ring, both in the slow corner. That
    figure is a diagnostic of this measurement image and does not stop
    the build: the two latches share a slice, but their clock inputs are
    distinct route endpoints, and only the shared part of a route
    justifies cancelling its variation.
    **What the routed check cannot show is that the divider divides by
    two on the device.** A latch made of a look-up table relies on the
    table not glitching when a single input changes. Xilinx engineers have
    stated that for its function generators (older data books and
    application note XAPP024), but it is not in this part's data sheet.
    So the board's two ratio checks are mandatory, on every running ring
    of the final image, before any of its counts is used for a bound: the
    counts of the two counting modes must be in the ratio two, and each
    ring's count rate must agree with the frequency of its sampled bits.
    The second compares only the folded frequency, the fraction of a
    ring's periods per clock: a count wrong by a whole number of periods
    per clock passes it, and the first catches that
    ([board test plan, section 7](../dbg/BOARD_TEST_PLAN.md#7-the-next-image-one-ring-for-seed)).
    The numbers come from the timing model of routed designs, not from a
    board. In
    `ddb168e1…` the 3-stage ring's period is 0.43 ns in the fast corner
    and 0.98 ns in the slow one. The one-ring source has been placed and
    routed out of context and as a small real design with pins. There the
    3-stage rings have 0.37 to 0.83 ns (16 to 36 periods per 75 MHz
    clock), and lanes 1 to 3 have 0.50 to 1.07, 0.73 to 1.56 and 0.92 to
    1.93 ns out of context (lane 3: 0.97 to 2.05 ns in the small design).
    In the small design with the present constraints every divider
    condition is at 68 % of its limit or less in all four states (the
    3-stage rings; 53, 49 and 28 % for lanes 1 to 3). The counter clock
    of the 3-stage rings has a period of at least 0.752 ns and pulses of
    at least 0.361 ns, 1.37 and 1.31 times what the flip-flop needs (0.550
    and 0.275 ns), against 0.680 and 0.340 ns declared; the tool's
    pulse-width report gives 60 checks per ring at the counter's 12 clock
    pins, the smallest slack 0.065 ns. The paths between the Johnson
    flip-flops have at least 0.22 ns of slack at the declared period.
    Every timing constraint is met (setup slack 0.050 ns, hold 0.012 ns),
    the 24 loops are allowed and none is refused, and the small design's
    bitstream was written. In the image `20f8b265…` the rings are a little
    slower (3-stage 0.40 to 0.92 ns) and every margin wider: divider
    conditions at 62 % or less, the 3-stage counter clocks at 1.47 and
    1.41 times the flip-flop's limits, the pulse-width report's smallest
    slack 0.065 ns, timing met (setup +0.026 ns, hold +0.010 ns)
    ([measurements](../dbg/MEASUREMENTS.md#fpga-image--2026-11-21)).
  - `rtl/karu_entropy.v`: keeps every k-th symbol and takes from it the
    bit of one lane, the one that the static input `lane_i` names. That
    bit is the noise-source sample. The block runs the health tests on it,
    packs 16 consecutive samples into a word, the first in bit 15, and
    buffers eight words. No bit is combined with another. Words are
    released four at a time, because Linux and OpenSBI give up after 100
    and 1,000 polls, and are wiped as they are read. With the default
    parameters (k = 16) the first word is available 4,456,448 clocks after
    reset, 59.4 ms at 75 MHz, and the source delivers 1,144 words per
    second; at k = 64 the first word takes about 238 ms.
    The health tests are SP 800-90B's approved tests for a binary sample:
    the repetition count, here at lags 1 to 4 (cutoff 55), and the
    adaptive proportion test over a window of 1,024 (cutoff 719). The
    cutoffs are those for 0.75 bit per sample and a false-alarm
    probability of 2⁻⁴⁰ per test. The start-up test takes 1,024 kept
    samples. A running failure raises a `BIST` alarm that stays until a
    `seed` access has seen it, and a strike count ends a recurring failure
    in `DEAD`. There is no test on the 4-bit symbol or on the other lanes.
    A second static input, `kshift_i`, sets the spacing floor: outside
    test mode the smallest k is 16 << `kshift_i` with the default
    parameters, and the interval field resets to that floor. Software can
    only lengthen the spacing. In test mode the written interval is used.
  - `mentropycfg` (`0x7C9`) holds k, the two cutoffs, the two failure
    numbers and a lock; its reset values are the weakest it accepts. Bits
    [53:37] and [62] read zero and ignore writes. With the default
    parameters it resets to `0x30c0000b3c37000f` at a spacing floor of
    k = 16, and to `…001f`, `…003f` and `…007f` at floors of 32, 64 and
    128. `mentropystat` (`0x7CA`, read-only) reports the state, the alarm,
    the strikes, the last failure and the two static inputs: the lane in
    [21:20] and the spacing floor in [23:22]. `mnoise` (`0x7C8`) is the
    GetNoise test interface of the Zkr rationale and returns raw 4-bit
    symbols, all four lanes, with a loss flag while `seed` is held in
    `BIST`. It also works on a source that has failed its tests for good
    (`seed` then reports `DEAD`), which is when raw samples are most
    needed. The header of `rtl/karu_entropy.v` has the fields.
  - **Soft straps** (`flow/fpga/karu_softstrap.v`). Three settings of the
    entropy source are constants held in look-up tables, so that they can
    be changed in the routed design without placing or routing anything
    again, the rings included:

    | Strap | Default | Variable |
    |---|---|---|
    | the lane whose bits `seed` delivers | 0, the 3-stage ring | `STRAP_LANE`, 0 to 3 |
    | the spacing floor, k at least 16 << n | n = 0: k = 16 | `STRAP_KSHIFT`, 0 to 3 |
    | the rings that run outside test mode (bit r is ring r; 0 to 3 the lanes, 4 and 5 the references) | `0x0f`: the four lanes, the references off | `STRAP_RINGS` |

    Software cannot change a strap. The image build prints the straps
    after routing (`KARU_STRAP`).
    `make vcu118-strap-variant STRAP_KSHIFT=2` (or `STRAP_LANE=`,
    `STRAP_RINGS=0x3f`) opens the routed checkpoint of the last build,
    sets the look-up tables (`flow/fpga/strap_variant.tcl`) and writes a
    second bitstream, `_build/vcu118_ddr-k2.bit` for that example; a strap
    not given stays as built. It refuses a ring mask without the lane that
    `seed` delivers, before it writes anything. It also writes the
    checkpoint's own bitstream again. `flow/strap_diff.py` reads the
    bitstreams as header, configuration packets and frame data. The
    rewritten bitstream must have the image's payload byte for byte, so
    the checkpoint is the image's design. The variant may differ from it
    only in whole strap tables (four 16-bit parts in consecutive frames),
    in half tables where the tool has put a strap into a look-up table
    beside another function (four 8-bit parts), in the check bits of those
    frames, and in CRC words behind them. The check bits are the 48 of
    each frame in word 45 and the low half of word 46; the checker
    recomputes them, with the code of Project X-Ray, in every frame that
    differs, and they must be right in both files. That code matched
    every frame of five bitstreams Vivado wrote. A record,
    `_build/vcu118_ddr-k2.strap.json`, names image, checkpoint, variant
    and log by their hashes.
    `make vcu118-strap-bundle` with the same variables requires that
    record. It gives the variant its own authentication record and
    programming bundle, `_build/vcu118_programming-k2.tgz`, with member
    names relative under `_build/`; the island ROM and the key are those
    of the image it comes from. It takes the manifest and the device tree
    from the boot ROM image only after `flow/rom_record.py` has matched
    that image's hash to the image's ROM record (below). On the board host
    `KARU_BITFILE=vcu118_ddr-k2.bit make prog_vcu118_ddr` programs the
    variant, and the rule checks that this file is there.
    **The ROM record.** Every recipe that runs the image build hashes the
    boot ROM right after packing it, before Vivado, and after Vivado
    writes `_build/vcu118_ddr.rom.json`, which names the bitstream and the
    boot ROM image by their hashes. A bitstream counts as written by the
    build only if it is strictly newer, to the nanosecond, than the ROM's
    hash. A synthesis-only run leaves image and records as they were: the
    image build keeps the previous record until it has written the next
    one. The record names its bitstream by hash, so beside a newer
    bitstream it fails. The debug image also hashes its island ROM before
    the build, and writes its authentication record only after checking
    that the build wrote a new bitstream with that ROM unchanged and that
    the ROM record names the same bitstream. A bundle checks any ROM
    record present before it looks at the boot ROM's size, so a missing or
    cut ROM cannot make a bundle without manifest and device tree.
    The flow has been run from end to end, with the present tools and
    constraints, on a small real design of the entropy source, not on a
    full image: the image, the same payload written from the checkpoint in
    a later session, two variants with their records (one that changes one
    strap, which the tool had put in half a look-up table, the check bits
    of its four frames recomputed and right; and one that changes three,
    each a whole table), a wrong variant refused, and a mask without lane 0
    refused before anything was written.
    `make strap-flow-test` (70 checks) runs the checks of `strap_diff.py`
    and `rom_record.py` on generated files, and checks with `make -n` that
    every image target, the debug image included, hashes and records in
    the right order in both modes; the dry runs read stand-ins, in the
    test's own output directory, for the boot files from beside the
    repository, so they run on a clean checkout.
  - `flow/fpga/karu_noise_burst.v`: a measurement aid for
    characterising the rings, which `mnoise` is too slow for. In the
    entropy block's test mode, and only then, it sets the sampling period
    of the rings, 1 to 256 clocks, and records bursts of 32,768
    consecutive raw symbols in four block RAMs.
  - `flow/fpga/karu_rosc_meter.v`: the meter, for the measurement of a
    ring's own jitter; it too works in test mode only. It turns the six
    counts into running totals modulo 2^20, in the unit of the counts,
    and at every n-th raw sample takes a record: the six totals and the
    four lane bits of one clock edge. A record is held until it is read
    and is never overwritten; one that falls due meanwhile is dropped and
    sets the loss flag. From a series of records the host has every ring
    against the clock and every pair of rings against each other. The
    meter also sets which rings run in test mode and how the counters
    count (divided, or direct).
    It checks every enabled ring on every clock: a count that cannot be
    read, or an increment that differs from the one before by more than
    2, is counted and sets a flag for its ring that stays until the next
    start, so that a count wrong by sixteen cannot pass silently. The
    check holds off for 12 clocks after a ring is switched on, after a
    write of the counting mode and after test mode is entered. It does
    not see a divider that loses or gains a single period; the comparison
    of the two counting modes and of the sampled bits is for that.
    The meter can give the burst capture one ring's count, its lower or
    its upper four bits, or the two reference rings' bits beside those of
    lanes 0 and 1, in place of the symbol.

    The registers of both are in the system-control block, 64 bits each:

    | Address | Register |
    |---|---|
    | `0x1000_0840` | burst capture, status and control. Write bit 0: start a capture. Read: [0] capturing, [1] done, [2] capturing allowed, [3] `mentropycfg` locked, [4] noise source enabled, [5] test mode, [15:8] log2 of the symbols per burst, [31:16] words written so far, [63:32] `0x4b4e4231` |
    | `0x1000_0848` | burst capture, period: clock cycles per raw symbol, less one |
    | `0x1000_0850` | burst capture, index of the word that the data register returns next |
    | `0x1000_0858` | burst capture, data: sixteen symbols per word in sampling order, the first in bits [3:0]; a read moves the index on |
    | `0x1000_0860` | die temperature, VCCINT and VCCAUX from the system monitor (`flow/fpga/karu_sysmon.v`), with an update count; readable in or out of test mode |
    | `0x1000_0868` | meter, CTRL. Write: [15:0] a record at every n-th raw sample, n less one; [21:16] the rings that run in test mode; [22] the burst capture records one ring's count, [25:23] which ring, [27] its upper four bits `cnt[5:2]` instead of `cnt[3:0]`; [26] the burst capture records the two reference rings' bits beside those of lanes 0 and 1; [28] direct counting: a count is one ring period; [31] start. Read: the same, and [37:32] the strap, the rings of normal operation; [40] a record is held; [41] loss; [47:42] a flag per ring: since the start it had a count that was unreadable or whose increment differed from the one before by more than 2; [63:48] the clocks since the start in which an enabled ring had such a count, up to 65,535. The start bit clears both |
    | `0x1000_0870` | meter, DATA0: [63] a record is held, [62] loss, [61:60] the record's sequence number, [59:40], [39:20] and [19:0] the totals of rings 2, 1 and 0, in counts |
    | `0x1000_0878` | meter, DATA1: [63:60] the record's lane bits, [59:40], [39:20] and [19:0] the totals of rings 5, 4 and 3; a read takes the record |

    Only privileged 64-bit accesses reach them; anything else reads zero
    and writes nothing. Outside test mode, and whenever `mentropycfg` is
    locked, the period is the build's 256 clocks, the rings that run are
    those of the strap, the counters count behind the divider, no capture
    can be started, and the period, index
    and status are at their reset values; the burst data register reads
    zero unless a capture completed in the current test-mode session, and
    the meter's registers read zero. So `seed`, the health tests and the
    authentication ROM see the noise source exactly as without the two
    blocks, and nothing that is recorded is ever delivered as entropy.
    Test mode is entered through `mnoise`, from M-mode or the debugger.
    S-mode can reach the registers, as it can the reset register, but
    cannot enter test mode.
  **The entropy rate.** The Zkr text requires 0.75 bit of min-entropy
  per delivered bit. The [SP 800-90B assessment](sp800-90b-assessment.md)
  proposes that rate for image `20f8b265…` as the developer's estimate,
  for one board in lab conditions, with NIST's non-IID estimates of
  0.810 and 0.839. What part of the ring's measured jitter is fresh at
  that rate is still to be justified. On the
  earlier image `ddb168e1…` most of the jitter that the board shows is
  common to the four rings, and a ring's own jitter could not be measured
  there. That is why `seed` delivers one ring and why the reference
  rings, the counters and the meter exist: they measure that ring's own
  jitter at the delivered spacing, against the other rings
  ([plan, Z7](zkr-followup-plan.md#z7-one-ring-for-seed-and-the-measurement-of-its-own-jitter)).
  The meter's model did not give a lower confidence bound on the board:
  the own variance grows faster than white noise, and a periodic
  disturbance is common to the rings
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-23.md#the-captures-74)).
  The per-lane model is that of arXiv:2102.02196, and the ring
  frequencies relative to the clock depend on the bitstream's routing.
  The device tree with `zkr` is karudeb's `rva23s64-zkr-ddr` variant, and
  the build refuses a tree that disagrees with the image. If Linux should
  leave `seed` alone, serve the plain `rva23s64-ddr` `board.dtb`.
  **Never serve the `zkr` tree to an image without the CSRs** (`d5e603cd…`,
  `0b994847…` and older): Linux would execute a `seed` access that traps,
  early in boot and with no fallback. The `zkr` variant's boot command
  carries `random.trust_cpu=off`, so Linux mixes what `seed` delivers into
  its pool without counting it as entropy: Linux's pool is not a
  conditioner that the assessment covers. U-Boot's Zkr driver as released,
  v2026.10 included, waits without bound on `BIST` or `WAIT`.
  `flow/build_uboot.sh` builds v2026.10 with
  `flow/boot/uboot-zkr-timeout.patch`, which bounds every wait at 100 ms,
  and enables the driver. Its one use is the `kaslr-seed`
  property that U-Boot adds to the device tree, which Linux does not count
  as entropy; `rng-seed` is not passed. With the source off U-Boot prints
  "No RNG device" and boots on. `make uboot-boot-test` shows both in
  simulation. On the board, with image `20f8b265…` and the source on,
  `rng 0 10` prints 16 bytes and `/chosen` holds a `kaslr-seed`; with it
  off U-Boot prints "No RNG device" and the boot goes on
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-23.md)). With a spacing floor
  of k = 64 the first word comes about 238 ms after a reset, later than
  one 100 ms wait; a probe before it would fall back without a message
  that stops the boot, so whether U-Boot has its device and passes a
  `kaslr-seed` is checked on the board for every spacing
  ([board test plan](../dbg/BOARD_TEST_PLAN.md)).
  On the board top the noise source, the entropy block, the two
  measurement aids and the straps are joined by
  `flow/fpga/karu_entropy_src.v`, which is also what the simulation
  benches instantiate, with a behavioural model in place of the rings.
  Tests: `make entropy-test` (the block, 12,894 checks and 108 mutants,
  each caught by the check written for it, and its health tests and words
  against a Python model on the same symbols), `make zkr-test` (the
  access table in M, S, U, VS and VU, the value format, the custom CSRs and
  the strap on the core; 17 mutants), `make zkr-loop-test` (no
  combinational loop between the CSR file and the block),
  `make noise-burst-test` (the entropy source with the burst capture, the
  meter and the straps on the noise model: the period, bursts against a
  record of every symbol of the source, and what test mode confines;
  110,079 checks and 54 one-mechanism mutants), `make rosc-meter-test`
  (the dividers, the counters and the meter: seven meter runs on the
  behavioural source, a million-clock soak in each counting mode with
  nothing flagged, three sweeps of a divider over 3,000 delay
  combinations each, in which every combination inside the six
  conditions divides correctly, five runs of the counters as synthesised
  on bench-made rings with modelled routing delays, the Verilog model
  against its Python copy, and 113 mutants),
  `make ddr-noise-burst-test` (the registers of both blocks through the
  SoC's bus decode; eight mutants), `make strap-flow-test` (the checks
  of a strap variant on generated bitstreams, and the record steps of the
  image recipes; 70 checks) and `make zkr-test-spike` (the access table
  on Spike); all but the last are in the list of `make dbg-test`.
  The combined gate passed on the current sources on 2026-11-21 at
  16:02 UTC (475 inputs;
  [record](../dbg/README.md#current-combined-validation-record)), and
  `make image-boot-test` and `make dbg-seedcap-test`, outside it, on the
  same RTL and firmware. The full Vivado build produced `20f8b265…`
  later that day. `make uboot-boot-test` was outside this run.
  For the board: `test/dbg/board/getnoise_capture.py` takes raw symbols
  through `mnoise` at several k, keeping the runs of consecutive samples
  apart, and `getnoise_analyze.py` evaluates them offline: per lane the
  duty cycle, the autocorrelation within runs and a fit of (F, sigma^2),
  whether sigma^2 grows linearly with k, and, separately, the dependence
  between lanes and the distribution of whole symbols and words.
  `linux_zkr.py` checks that Linux lists `zkr`. `make dbg-getnoise-test`
  runs the payload on the simulated core and the analysis on synthetic
  model data. All three run in every board session.
  `getnoise_capture.py`, `seed_restart.py` and `entropy_fault.py` are
  adapted to the one-ring block and need an image with it; on
  `ddb168e1…` they do not work as before.
  For the burst capture, `getnoise_burst.py` records bursts at periods of
  1 to 256 clocks with the payload `getnoise_burst.S`, and writes them in
  the same file format, one run per burst, with the period and a
  clock-cycle stamp per burst in the sidecar; `getnoise_analyze.py` reads
  both kinds. `make dbg-getnoise-burst-test` runs the payload and the
  phase on the SoC simulation, where every burst is compared with a copy
  of the simulated source, and `make dbg-burst-analysis-test` validates
  the analysis of bursts on generated data with known parameters. Both run
  in the board sessions.
  For the meter, `rosc_count.py` writes the meter's records to files with
  the payload `rosc_count.S`. By default it takes, first with the rings
  of normal operation and then with all six, a record every 256, 1,024,
  4,096 and 16,384 clocks, counted behind the divider (`count_unit` 2 in
  the sidecar): a million records at each spacing, 400,000 at 16,384
  clocks or more. For each ring mask it also takes one capture in direct
  mode as a cross-check (`rosc-direct-…`; 100,000 records,
  `KARU_BOARD_ROSC_DIRECT_COUNT`). Then it takes bursts of each ring's
  count in an upper and a lower view, and bursts of the two reference
  rings' bits beside those of lanes 0 and 1 (`refbits/`). It reports the
  clocks that the meter flagged for every capture, and the analysis never
  uses a run that has one. Each sidecar says whether its capture can
  carry a bound (`for_bound`): not one in direct mode, nor one planned
  with fewer than 300,000 records.
  `rosc_own.py` computes each ring's own phase variance from pairs of
  rings, with a one-sided 99 % lower bound on the part that grows in
  proportion to time, and gives a verdict per spacing: `pass`, `fail`,
  `not established`, or `cross-check only` for a capture in direct mode
  or not taken with the rings of normal operation. A pass needs the bound
  to be at least twice the variance that 0.75 bit needs at the measured
  duty-cycle bound, no flagged count, every assumption check passing,
  and at least 300,000 usable records: those in the blocks that enter
  the fit, after runs with a flagged count, a loss or a jump are set
  aside, without the ends of runs too short for another block. The
  records of the runs kept are reported beside them. Below that
  `rosc_own.py` reports its estimates and bound and gives no pass
  (`--min-records` lowers the number for tests only). Two of its checks
  tie the unit of a count to the hardware: `--pair` compares the capture
  with one of the same rings and spacing in the other counting mode,
  whose counts must be in the ratio two, and `--bits` compares each
  ring's count rate with the frequency of its sampled bits. `--bits` must
  find a usable frequency for every ring that it maps and that runs in
  the capture, and it compares only the folded frequency (the fraction of
  a ring's periods per clock), which a count wrong by a whole number of
  periods per clock leaves unchanged: neither check alone qualifies the
  instrument.
  `rosc_own.py` is validated on generated rings with counts of two ring
  periods, as the meter gives them: the bound was at or below the truth in
  17,364 of 17,400 trials (99.8 %; no scenario under 99.0 %), and no trial
  passed in 6,000 with the ring's own white noise at zero. With counts of
  one period the figures were 19,340 of 19,400 and none of 6,000. Counts
  of two periods cost precision: the standard error of the credited rate
  is 1.5 to 2 times larger, and the checks of the assumptions need more
  data to see a small violation; hence the 300,000 usable records.
  `entropy_claim.py --own` takes the own variance of rings of one kind
  from the reference bits, without the counters; it reaches a few hundred
  clocks and is a cross-check, not a second bound.
  `make dbg-rosc-count-test` (844 checks, 123 bench runs) runs the payload
  and the phase on a model of the registers and on the SoC simulation,
  `make dbg-rosc-own-test` runs the analysis on generated rings with
  known own and shared noise (176 checks), and
  `make dbg-entropy-claim-test` runs `entropy_claim.py` on generated rings
  of known own variance. The November 23 measurement used the board
  meter and host analysis.
  The [Zkr follow-up plan](zkr-followup-plan.md) has the reasons, what was
  decided, and what is still open.
- **Debug authentication (`KARU_DBG_AUTH`).** The hart starts in the authentication
  island ROM at `0x1_0000`, which hands over to fu-boot at `0x1000`. The
  island keeps its default addresses and is decoded in front of the boot
  ROM, which is why the ROM layout leaves that range empty. The window ROM
  is the one of `test/dbg/auth_rom`, built to take its nonce, 16 words,
  from `seed`. It waits for each word through at most 2,000,000 polls
  (`TRNG_TRIES`; 200,000 in the ROM of `ddb168e1…`), which covers the
  start-up test and one burst at every spacing floor. It verifies a
  SHA3-256 MAC under the build tree's key (algorithm `0x04`; the key file
  is `_build/vcu118_auth_key.txt`, also in the bundle). The key is in the
  bitstream, and the production verifier awaits decision D3 of the
  [plan](debug-auth-plan.md), so in lifecycle `AUTH` this image is
  functional validation, not protection. A software reboot is a system
  reset: it does not reopen the authentication window, only power-on does
  (on the board: the CPU reset button, or reconfiguration). An image built
  with authentication but without `KARU_ZKR` gets the `-DAUTH_NO_SEED`
  ROM, which has no nonce source: it makes no challenge, never unlocks,
  and the boot goes on. The island's SRAM is data only in the access permissions:
  `make sv39-auth-pma-test` checks that through the address translator,
  including `HLVX`, which asks for execute permission and reads through
  the data port.
  `make image-boot-test` boots this composition in simulation with
  karudeb's OpenSBI and device tree (about fifteen minutes, outside
  `make dbg-test`). It has no debugger. The authentication exchange itself
  is tested on `karudbg_core`: `dbg-auth-window-seed-test` runs the window
  bench with the nonce read from `seed`, as this image's ROM does. For the
  board, `test/dbg/board/auth_phase.py` runs the exchange through OpenOCD,
  one case per switch setting; `make dbg-board-auth-rehearsal-test` (in
  `make dbg-test`) rehearses it with pristine OpenOCD against the simulated
  target and the real window ROM. [The board test plan](../dbg/BOARD_TEST_PLAN.md)
  has the order of work for the first session.
- **Bitstream variants** (one shared OpenSBI, per-profile control DTB +
  netboot bootcmd, sourced from `../karudeb`):
  - `make vcu118-ddr` — DDR4 Linux bring-up bit (`KARU_NO_V`, IMAFDC).
  - `make vcu118-ddr-sgmii-rom-gc` — scalar RV64GC hands-off netboot ROM bit.
  - `make vcu118-ddr-sgmii-rom-vec` — full RV64GCV + Zvk + Keccak hands-off ROM
    bit (adds the vector timing knobs below; enables the opt-in Smcntrpmf +
    Sscofpmf counter extensions, both reset-inert).

### Opt-in RVA23S64 boot selection

`make vcu118-ddr-sgmii-rom-rva23s64` reuses the vector SGMII ROM flow and
75 MHz timing settings, adding `KARU_RVA23S64`. The original vector target
is unchanged. Optional Zvk, Keccak and Smcntrpmf remain enabled in this FPGA
image; the profile contract supplies H/Ssstateen and requires Sscofpmf.

Build/stage the matching companion image first:

```sh
make -C ../karudeb karu64-rva23s64-check karu-opensbi
TFTP_SERVER=192.168.42.1 GUEST_IP=192.168.42.10 \
  NFS_SERVER=192.168.42.1 NFSROOT=/srv/nfs/karudeb \
  make -C ../karudeb karu64-rva23s64-tftp
make rva23-boot-inputs-check
flow/with_vivado.sh make vcu118-ddr-sgmii-rom-rva23s64
```

The wrapper selects `FUBOOT_RVA23_DTB` (default
`../karudeb/build/karu64/karu64-rva23s64-ddr.dtb`) and
`VCU118_NETBOOT_FILE_RVA23` (the one-liner under the matching profile TFTP
staging directory). It rejects a missing command/DTB, missing required
H/supervisor discovery leaves, or a mismatch with the staged `board.dtb`.
The ROM layout (`0x0`, `0x30000`, `0x120000`, `0x1FC000`, with the two empty
ranges of the table above) and the blob-overrun checks are those of the vector
target.
Reports default to tag `ddr_rva23s64_sgmii_75_rom`. The bitstream output is
the existing `_build/vcu118_ddr.bit`; the command does not program the board.

#### Optional karudbg integration

`make vcu118-ddr-sgmii-rom-rva23s64-dbg` adds `KARU_DBG` and
`VCU118_DBG_EXT_DEFINES` to the same 75 MHz profile/SGMII/ROM flow, with the
standard `_build/vcu118_ddr.*` outputs. It substitutes the processor-plus-DM
integration for the bare core and reserves FPGA **USER4** (`IR=0x23924`, 18 bits)
for a nested RISC-V TAP. The transport uses the existing board JTAG connector;
the only user pins it adds are the four DIP switches of the straps above.
`KARU_DDR_HOST_DBG` is rejected in this configuration until
the separate JTAG-AXI loader's USER-chain coexistence is configured.

The default is
`VCU118_DBG_EXT_DEFINES="KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR"`:

| Define | Adds | Consequence for the build |
| --- | --- | --- |
| `KARU_DBG_FULL` | autoexec, two address triggers, SBA | |
| `KARU_DBG_AUTH` | the authentication block and island, the lifecycle straps | builds `_build/vcu118_auth_rom.hex`; the hart starts at `0x1_0000` |
| `KARU_ZKR` | `seed` and the entropy source | the ROM takes karudeb's `rva23s64-zkr-ddr` tree and its boot command; the island ROM reads its nonce from `seed` |

Set `VCU118_DBG_EXT_DEFINES=KARU_DBG_FULL` for the image without
authentication and Zkr (plain `rva23s64-ddr` tree), and
`VCU118_DBG_EXT_DEFINES=` for the base Debug Module alone. The device tree
variant follows the define list, and the build refuses a tree whose `zkr`
does not match the image.

```sh
TFTP_SERVER=192.168.42.1 GUEST_IP=192.168.42.10 \
  NFS_SERVER=192.168.42.1 NFSROOT=/srv/nfs/karudeb \
  make -C ../karudeb karu-opensbi karu64-rva23s64-zkr-tftp
flow/with_vivado.sh make vcu118-ddr-sgmii-rom-rva23s64-dbg
```

The target runs the boot-input check itself, on the tree that belongs to its
define list. A standalone `make rva23-boot-inputs-check` looks at the plain
`rva23s64-ddr` tree, which is the right check only for the profile image and
for a debug image without `KARU_ZKR`.

The [target configuration](../dbg/vcu118.cfg) uses pinned mainline OpenOCD's
`riscv use_bscan_tunnel 5 0` and `riscv set_bscan_tunnel_ir 0x23924`.
Load the appropriate cable/adapter configuration before this target file.
Use the [tested isolated OpenOCD build](../dbg/README.md#initial-contract)
for software translation, including its documented walk safeguards. The combined
image supports native autoexec and SBA with the pinned pristine OpenOCD; the
base image needs the optional-autoexec fallback patch for Program Buffer blocks. The FPGA TAP's
IDCODE is distinct from the conventional simulation TAP's placeholder ID.
Do not run OpenOCD and Vivado Hardware Manager against the same cable at once.

The DM/DTM retain the conditioned board reset. `ndmreset` separately cancels
the hart, crossbar, both clock-converter sides, width converter and MIG AXI
interface, preserving the calibrated DDR PHY and DM. UI-side reset asserts
even if its clock stops; hart/crossbar reset releases only after the UI-side
responders and two CPU-clock edges. Raw TCK and gated USER4 DRCK have separate
reset-release synchronizers and explicit related-clock constraints. The clock
root is BSCANE2's `INTERNAL_TCK`; exported TCK and DRCK are derived from it,
so the primitive's falling-edge TDO sampling checks are timed as well. Bundled
DMI payload paths retain maximum-delay/skew checks; they are not hidden by a
blanket asynchronous-clock exception.

The non-board gates are `make dbg-bscan-test dbg-bscan-core-test
dbg-bscan-gdb-test dbg-bscan-translation-test dbg-bscan-full-test`. The full
composition uses its own model/flag record and the pinned pristine OpenOCD:
Program Buffer blocks, hardware breakpoints/watchpoints, SBA RAM/MMIO while
halted/running and GDB FP/vector/register context all pass through USER4. They exercise a behavioral
Xilinx outer TAP, the production tunnel and real DM/DTM/core with actual
OpenOCD/GDB, plus pause/abort/reset and negative controls. This verifies the
tunnel protocol and software integration, rather than a physical FPGA cable
or primitive timing. The synthesis/placement evidence and outstanding timing
gates are recorded in [karudbg measurements](../dbg/MEASUREMENTS.md). The
current debug image and its board status are at
[the top of this document](#debug-image); the profile images do not
contain karudbg.

For board programming on another host, run `make vcu118-program-bundle` and
transfer `_build/vcu118_programming.tgz`. Its members retain the `_build/...`
paths:

| Member | Contents |
| --- | --- |
| `_build/vcu118_ddr.bit` | the bitstream (mandatory) |
| `_build/vcu118_ddr.ltx` | debug probes, when the build produced them |
| `_build/vcu118_rom_manifest.txt` | bitstream and ROM hashes, the verbatim baked boot command, and the TFTP/NFS endpoints it names |
| `_build/vcu118_rom_board.dtb` | the control DTB extracted from the ROM, to be served as `board.dtb` |
| `_build/vcu118_ddr.rom.json` | the boot ROM record, when the image build wrote one |

`flow/rom_manifest.py` produces the manifest and the DTB by reading the
packed ROM image back, so they describe what the bitstream contains even if
karudeb has moved since. The target refuses to run when the ROM image is
newer than the bitstream, because a ROM repacked after the build no longer
describes it. Every image build also writes `_build/vcu118_ddr.rom.json`,
which names the bitstream and the boot ROM image by their hashes
(`flow/rom_record.py`; [the ROM record](#the-ddr4-soc-linux-target)). The
target then checks the ROM image against that record, refuses one that was
packed again whatever its time stamp, and puts the record into the bundle.
An image built before the record existed, such as `ddb168e1…`, is tied to
its ROM image by the time stamps only.
The programming host can extract the bundle at the repository root and run
`flow/with_vivado.sh make prog_vcu118_ddr`. For boot, stage `Image` from the
matching karudeb build and serve the bundled DTB as `board.dtb`.
The NFS rootfs is separate. Keep the ROM/TFTP DTBs identical (the one
exception is noted with the Zkr entry above) and use the normal
Svpbmt-enabled profile. The lab netboot command uses server 192.168.42.1,
board 192.168.42.10 and NFS root `/srv/nfs/karudeb`; TFTP loads Image at
0x80200000 and the DTB at 0x84000000.

#### Building on one host, booting from another

The build host needs the RAM for implementation; the board host owns JTAG,
TFTP and NFS. Each side contributes different pieces, and nothing checks
them against each other automatically:

| Piece | Comes from | Fixed when |
| --- | --- | --- |
| OpenSBI `fw_jump.bin` (v1.9) | build host, `../karudeb/build/karu64/opensbi/` | bitstream build (in ROM) |
| U-Boot v2026.10 (`flow/build_uboot.sh`, in `../u-boot-v2026.10-netboot`) and its boot command | build host; the command is the one-liner staged under `../karudeb/build/karu64/tftp/<variant>/` | bitstream build (in ROM) |
| Control DTB for OpenSBI and U-Boot | build host, `../karudeb/build/karu64/karu64-<variant>.dtb` | bitstream build (in ROM) |
| Kernel `Image` and `board.dtb` for Linux | board host, TFTP root | each boot |
| Root filesystem | board host, NFS export | each boot |

`<variant>` is `rva23s64-ddr` for the profile image and for a debug image
without `KARU_ZKR`, and `rva23s64-zkr-ddr` for the default debug image
(karudeb targets `karu64-rva23s64-tftp` and `karu64-rva23s64-zkr-tftp`).

The boot command is therefore decided on the **build host**. karudeb's
staging script defaults to `192.168.1.20` / `192.168.1.10`, so the build host
must stage with the lab values shown above even though it serves nothing
itself. Print the line that will be baked before starting the build:

```sh
cat ../karudeb/build/karu64/tftp/<variant>/uboot-netboot-one-line.txt
```

It must name the board host's TFTP server and board address, fetch `Image`
and `board.dtb` by exactly those names from the TFTP root, and carry the
kernel arguments the board host's NFS export expects
(`root=/dev/nfs ... nfsroot=192.168.42.1:/srv/nfs/karudeb,vers=3,tcp,nolock`,
`console=ttyS0,115200 earlycon`; the `zkr` variant adds
`random.trust_cpu=off`). `make rva23-boot-inputs-check` does not
inspect its contents. Changing any of it later means a new bitstream, or
interrupting U-Boot by hand.

On the board host, extract the bundle at the karu64 repository root, build
the same karudeb commit, and stage into the live TFTP root with the bundled
DTB:

```sh
cat _build/vcu118_rom_manifest.txt           # what this bitstream expects
DTB=$PWD/_build/vcu118_rom_board.dtb \
  TFTP_SERVER=192.168.42.1 GUEST_IP=192.168.42.10 \
  NFS_SERVER=192.168.42.1 NFSROOT=/srv/nfs/karudeb TFTP_ROOT=/srv/tftp \
  make -C ../karudeb karu64-rva23s64-tftp      # or karu64-rva23s64-zkr-tftp
sha256sum /srv/tftp/board.dtb
```

Either target serves the file given with `DTB=`; use the one that matches
the image so that the staging directory carries the right name. The kernel
`Image` that this stages is the board host's own build. Keep the lab's
accepted `Image` when the point of the session is the bitstream:
[the board test plan](../dbg/BOARD_TEST_PLAN.md) names it (the build host
has a different kernel binary).

The requirement is on the **served file**: `sha256sum /srv/tftp/board.dtb`
must equal the `control DTB` line of the manifest. `DTB=` makes the staging
script serve the given file instead of the one it compiles, which meets that
requirement by construction. The same hash is recorded for the bitstream in
the [release diagnostics](release-diagnostics-2026-09-14.md).

`make -C ../karudeb karu64-rva23s64-check` is a separate source check. It
recompiles the device trees with the board host's `dtc` and prints
`profile DTB sha256=...` for the plain tree and `zkr profile DTB sha256=...`
for the `zkr` variant. If the line for the image's variant shows the manifest
hash, the board host's checkout and `dtc` reproduce the ROM DTB. If it shows
something else, the checkout or the `dtc` differs from the build host's:
find out which before trusting a locally compiled DTB. Copying a DTB around
cannot change what this check prints, and it does not need to, as long as
the served file is the bundled one.

Images built from the element-group `vkeccak.vi` change onward (see
[rtl/zvk/README.md](../rtl/zvk/README.md#zvknhk-vkeccakvi-riscv-pqc)) also
need matching software in the root filesystem: karudeb from its `dev-keccak`
commit `b3b6abf`, with the Zvknhk OpenSSL built against riscv-pqc `main` at
`3c40d18` or later. Software built before that issues the instruction at
`vl=25` and takes SIGILL, which `board_accept.sh` reports as a failed crypto
check. The new software also runs on earlier images, so update and restage
the root filesystem first and program the bitstream second.

Capture UART with `python3 flow/serial_cap.py /dev/ttyUSB1 115200 _build/boot.log`.
From another terminal, with `hw_server` running and the intended board selected,
run `flow/with_vivado.sh make prog_vcu118_ddr`. This programs volatile FPGA
configuration, not flash; DDR calibration releases the CPU automatically.
After each new build, run karudeb's `board_accept.sh` as root. Require all
six `vill_probe` cases and the applicable ptrace cases, including syscall
clobbering; record skips separately. Run the cache/CPI probe with
`perf_run --user-count -- cache_window_probe` to enable its counters and
compare code/data costs across the 256 MiB boundary. Retain explicit
completion logs for crypto and KVM guest tests.

The profile DTS inherits the same hardware map and timing properties, removes
the incorrect inherited PMP description, and the companion kernel enables KVM
through an additional fragment. Staging without `TFTP_ROOT` does not update
the live TFTP service. Source configuration, routed timing closure and an
actual board/guest boot are separate results; none is implied by this target
name.

## Clocking and timing

The DDR4 board build derives the core `cpu_clk` from the MIG user clock —
`ui_clk` ÷ `KARU_DDR_CPU_DIV` (300 MHz / 4 = 75 MHz for the full-vector build),
through a `BUFGCE_DIV` in `vcu118_ddr_top.v`. That `CPU_CLK_HZ` (75 MHz) threads
as a parameter into `karu_ddr_xbar` → `karu_ns16550` (UART bit period =
`CPU_CLK_HZ / 115200`) and `karu_clint` (mtime tick = `CPU_CLK_HZ / 1e6`), so the
console stays at 115200 baud and the mtime tick at 1 MHz. The clock-consuming
modules default `CPU_CLK_HZ` to 100 MHz — matching the sim testbench clock and the
`KARU_DDR_CPU_DIV=3` base build (`make vcu118-ddr`); the deployed full-vector build
threads 75 MHz down via `DIV=4`.

Even at the relaxed ~75 MHz core clock (~13.3 ns), this RV64GCV core with
combinational mul/div has deep cones, so two levers shorten them:

- **Don't leave the multiplies combinational.** Setting `KARU_MUL_CYCLES=1`
  writes the 64×64 (`karu_m`) and 53×53 (`karu_fmul_d`) multiplies as a Verilog
  `*`, which maps to *unpipelined* DSP cascades — the classic Fmax killer. The
  multi-cycle knobs (`KARU_M_MUL_CYCLES`, `KARU_D_MUL_CYCLES`,
  `KARU_V_MUL_CYCLES`, `KARU_V_DIV_CYCLES`) and the FP fast-path multiply
  pipeline (`KARU_D_MUL_PIPE`) shorten them.
- **Two vector writeback levers** support full-vector timing closure: the 2-stage
  lane pipeline `KARU_V_LANE_PIPE` (splits the `vsew`→result cone) and the
  cold-funnel writeback stage `KARU_V_CWB_STAGE` (lands the whole-register
  assemblies in a dedicated register before the VRF-write funnel). Both
  preserve architectural results; their cycle cost depends on the workload.

The scalar `fround` converters now have an intermediate register. Vector
mask count/first-index operations use registered 16-bit summaries and a
balanced fold, removing a 128-deep conditional count chain. These stages add
fixed compute latency, not operand-dependent early exits. Default and shipping
Yosys configurations pass the [runtime-divider audit](../flow/syn/README.md#runtime-divisionmodulo-audit);
the serial arithmetic settings do not elaborate combinational dividers.
The lane stage captures controls and mask bits with its integer operands,
and a complete request register separates vector-FP operand selection from
FPU normalization. The latter adds one dispatch cycle per lane-FPU request.
The VLSU uses balanced first/last-active-element trees; this shortens its
request path without changing memory-access cycles.

The flow drops a **post-synthesis** snapshot (utilization / timing / worst-paths
/ `.dcp`) minutes in, before the long P&R, so structural long paths surface
early; the authoritative **post-route** reports are written at the end. Both land
under `_build/`. `make elab` / `make elab-ddr` are fast RTL-elaboration-only
checks for iterating on elaboration/range errors, and `make ooc OOC_TOP=<module>`
runs an out-of-context synth of a single module.

**Build resources:** configure Vivado's address-space limit (`VIVADO_VMEM_KB`)
and thread count (`VIVADO_THREADS`) for the available resources. Full-vector
implementation requires substantially more memory than scalar synthesis.
An address-space limit is not a resident-memory limit.

## Hardware status and repeat-build checks

The debug image `20f8b265…` passes Linux/NFS-root boot, `board_accept.sh`
(memory, cache, crypto, KVM API and profile checks), both KVM guests, the vector
selftests, riscv-pqc `xtest` and the Zvknhk OpenSSL pairs
([record](../dbg/BOARD_ACCEPTANCE-2026-11-23.md)). On-board TestFloat-3e
last ran with profile image `b11d5efb…` (36 functions, 0 errors); the
[release diagnostics](release-diagnostics-2026-09-14.md) record each
profile image's results by its hash.

For each new build, retain its routed timing reports, rerun `board_accept.sh`
as root with `perf_run`-enabled cache counters, and record crypto and KVM
guest completion logs against the bitstream hash. Dedicated multi-group
vector-crypto and resident-Keccak firmware suites remain separate from the
OpenSSL and instruction-vector checks.

QSPI configuration-flash reads and LiteEth throughput tuning remain platform
enhancements, not CPU-profile gates. Linux/rootfs/DTB/kernel artifacts come
from the companion `../karudeb` repository. Its ROM and TFTP DTB copies must
remain byte-identical when deploying a new build.
