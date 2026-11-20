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
- Zkr: the `seed` CSR and the ring-oscillator entropy source, with
  SP 800-90B's health tests on the 4-bit sample and lane tests beside them,
  `mnoise`, `mentropycfg` and `mentropystat`, the burst capture for
  characterisation and the die temperature and supply readout
  ([the DDR4 SoC](#the-ddr4-soc-linux-target));
- the 2 MiB boot ROM: fu-boot, OpenSBI v1.9, U-Boot v2026.10 with the Zkr
  time-out patch, the `rva23s64-zkr-ddr` device tree `784e2762…` and the
  lab's boot command;
- the software reboot.

The current bitstream is `ddb168e1…096aad`. It meets 75 MHz (setup
+0.008 ns, hold +0.011 ns, pulse width +0.005 ns; no DRC errors) and uses
377,901 LUTs (32.0%), 91,757 registers, 451.5 block-RAM tiles and 29 DSPs
([measurements](../dbg/MEASUREMENTS.md#fpga-image--2026-11-20)). It is
**board-tested** and accepted with documented exceptions
([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)): OpenOCD's software
address translation fails with known walker results, and the OpenOCD and
boot/detach findings are in [the campaign record](../dbg/BOARD_ACCEPTANCE.md).
[The board test plan](../dbg/BOARD_TEST_PLAN.md) has the procedure. The
preceding accepted image, `85f07e58…`, is kept with its bundle in
`_build/fpga_archive/2026-11-18-85f07e58/` on the build host.

**Programming bundle.** `make vcu118-program-bundle` packs
`_build/vcu118_programming.tgz`, mode 600, from the build outputs:

- `_build/vcu118_ddr.bit` and `_build/vcu118_ddr.ltx`;
- `_build/vcu118_rom_manifest.txt`;
- `_build/vcu118_rom_board.dtb`, the ROM's device tree, to be served as
  `board.dtb`;
- `_build/vcu118_auth_record.json` and `_build/vcu118_auth_key.txt`.

The key makes the bundle secret: whoever has it, or the bitstream, can
unlock the board's debugger. The bundle of `ddb168e1…` has SHA-256
`88dce485…7342`. Extract it from the repository root on the programming
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
  the OpenSBI region) are left out. The debug image uses 451.5 block-RAM
  tiles in all.

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
  - `flow/fpga/karu_rosc_rng.v`: four free-running inverter rings (3, 5, 7
    and 9 LUTs), each sampled by one flip-flop; one ring is one raw bit.
    Nothing combines or whitens bits. Its ports are those of OpenTitan's raw
    noise source. `flow/fpga/rosc_constraints.tcl` checks that synthesis kept
    every inverter, gives each ring its own two-slice region (set
    `KARU_ROSC_BASE` to move them) and cuts the sampling paths from timing.
    The rings are combinational loops: Vivado reports them as `LUTLP-2`
    warnings and `check_timing` lists four loops. They are the only loops
    allowed. The flow runs the `LUTLP-1` check right after synthesis and
    stops on any other loop (`KARU_LOOP_CHECK` in the log), because
    `write_bitstream` would refuse the design two hours later. A loop can
    also come through the CSR path: if the value read from `seed` depended
    combinationally on a value being written to another entropy CSR, every
    CSR set and clear instruction would close one. `make zkr-loop-test`
    checks that without Vivado.
  - `rtl/karu_entropy.v`: keeps every k-th symbol, runs the health tests,
    packs four symbols into a 16-bit word and buffers eight words. A `seed`
    word is 16 raw bits. Words are released four at a time, because Linux
    and OpenSBI give up after 100 and 1,000 polls. With the default
    parameters the first word is available 56.8 ms after reset at 75 MHz.
    The health tests are SP 800-90B's repetition count and adaptive
    proportion test (W = 512) on the 4-bit symbol and, per lane, a
    repetition count at lags 1 to 4 and an adaptive proportion test
    (W = 1024). A running failure raises a `BIST` alarm that stays until a
    `seed` access has seen it, and a strike count ends a recurring failure
    in `DEAD` ([SP 800-90B assessment](sp800-90b-assessment.md)).
  - `mentropycfg` (`0x7C9`) holds k, the four cutoffs, the two failure
    numbers and a lock; its reset values are the weakest it accepts.
    `mentropystat` (`0x7CA`, read-only) reports the state, the alarm, the
    strikes and the last failure. `mnoise` (`0x7C8`) is the GetNoise test
    interface of the Zkr rationale
    and returns raw symbols with a loss flag while `seed` is held in `BIST`.
    It also works on a source that has failed its tests for good (`seed`
    then reports `DEAD`), which is when raw samples are most needed. The
    header of `rtl/karu_entropy.v` has the fields.
  - `flow/fpga/karu_noise_burst.v`: a measurement aid for
    characterising the rings, which `mnoise` is too slow for. In the
    entropy block's test mode, and only then, it sets the sampling period
    of the rings, 1 to 256 clocks, and records bursts of 32,768
    consecutive raw symbols in four block RAMs. Its registers are in the
    system-control block, 64 bits each:

    | Address | Register |
    |---|---|
    | `0x1000_0840` | status and control. Write bit 0: start a capture. Read: [0] capturing, [1] done, [2] capturing allowed, [3] `mentropycfg` locked, [4] noise source enabled, [5] test mode, [15:8] log2 of the symbols per burst, [31:16] words written so far, [63:32] `0x4b4e4231` |
    | `0x1000_0848` | period: clock cycles per raw symbol, less one |
    | `0x1000_0850` | index of the word that the data register returns next |
    | `0x1000_0858` | data: sixteen symbols per word in sampling order, the first in bits [3:0]; a read moves the index on |
    | `0x1000_0860` | die temperature, VCCINT and VCCAUX from the system monitor (`flow/fpga/karu_sysmon.v`), with an update count; readable in or out of test mode |

    Only privileged 64-bit accesses reach them; anything else reads zero
    and writes nothing. Outside test mode, and whenever `mentropycfg` is
    locked, the period is the build's 256 clocks, no capture can be
    started, and the period, index and status are at their reset values;
    the data register reads zero unless a capture completed in the current
    test-mode session. So `seed`, the health tests and the authentication
    ROM see the noise source exactly as without the block, and no recorded
    symbol is ever delivered as entropy. Test mode is entered through
    `mnoise`, from M-mode or the debugger. S-mode can reach the registers,
    as it can the reset register, but cannot enter test mode.
  **No min-entropy is claimed** ([SP 800-90B assessment](sp800-90b-assessment.md)):
  most of the jitter the board shows is common to the four rings, and
  each ring's own jitter has not been measured.
  The per-lane model is that of arXiv:2102.02196. Burst captures fit it to
  each lane, with a jitter variance that grows faster than the model's
  white noise, and the ring frequencies relative to the clock depend on
  the bitstream's routing
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md#noise-capture-and-entropy-estimates)).
  The device tree with `zkr` is karudeb's `rva23s64-zkr-ddr` variant, and
  the build refuses a tree that disagrees with the image. If Linux should
  leave `seed` alone, serve the plain `rva23s64-ddr` `board.dtb`.
  **Never serve the `zkr` tree to an image without the CSRs** (`d5e603cd…`,
  `0b994847…` and older): Linux would execute a `seed` access that traps,
  early in boot and with no fallback. The `zkr` variant's boot command
  carries `random.trust_cpu=off`, so Linux mixes what `seed` delivers into
  its pool without counting it as entropy; that is the right setting while
  there is no claim. U-Boot's Zkr driver as released,
  v2026.10 included, waits without bound on `BIST` or `WAIT`.
  `flow/build_uboot.sh` builds v2026.10 with
  `flow/boot/uboot-zkr-timeout.patch`, which bounds every wait at 100 ms,
  and enables the driver. Its one use is the `kaslr-seed`
  property that U-Boot adds to the device tree, which Linux does not count
  as entropy; `rng-seed` is not passed. With the source off U-Boot prints
  "No RNG device" and boots on. `make uboot-boot-test` shows both in
  simulation. On the board, with the source on `rng 0 10` prints 16 bytes
  and `/chosen` holds a `kaslr-seed`; with it off U-Boot prints "No RNG
  device" and the boot goes on
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)).
  On the board top the two are joined by `flow/fpga/karu_entropy_src.v`,
  which is also what the simulation benches instantiate, with a
  behavioural model in place of the rings.
  Tests: `make entropy-test` (the block, 86 mutants, and its health tests
  against a Python model on the same symbols), `make zkr-test` (the
  access table in M, S, U, VS and VU, the value format, the custom CSRs and
  the strap on the core; 17 mutants), `make zkr-loop-test` (no
  combinational loop between the CSR file and the block),
  `make noise-burst-test` (the capture block with the noise model and the
  entropy block: the period, bursts against a record of every symbol of
  the source, and what test mode confines; one-mechanism mutants),
  `make ddr-noise-burst-test` (its registers through the SoC's bus decode;
  eight mutants) and `make zkr-test-spike` (the access table on Spike);
  all but the last are in `make dbg-test`.
  For the board: `test/dbg/board/getnoise_capture.py` takes raw symbols
  through `mnoise` at several k, keeping the runs of consecutive samples
  apart, and `getnoise_analyze.py` evaluates them offline: per lane the
  duty cycle, the autocorrelation within runs and a fit of (F, sigma^2),
  whether sigma^2 grows linearly with k, and, separately, the dependence
  between lanes and the distribution of whole symbols and words.
  `linux_zkr.py` checks that Linux lists `zkr`. `make dbg-getnoise-test`
  runs the payload on the simulated core and the analysis on synthetic
  model data. All three run in every board session.
  For the burst capture, `getnoise_burst.py` records bursts at periods of
  1 to 256 clocks with the payload `getnoise_burst.S`, and writes them in
  the same file format, one run per burst, with the period and a
  clock-cycle stamp per burst in the sidecar; `getnoise_analyze.py` reads
  both kinds. `make dbg-getnoise-burst-test` runs the payload and the
  phase on the SoC simulation, where every burst is compared with a copy
  of the simulated source, and `make dbg-burst-analysis-test` validates
  the analysis of bursts on generated data with known parameters. Both run
  in the board sessions.
  The [Zkr follow-up plan](zkr-followup-plan.md) has the reasons, what was
  decided, and what is still open.
- **Debug authentication (`KARU_DBG_AUTH`).** The hart starts in the authentication
  island ROM at `0x1_0000`, which hands over to fu-boot at `0x1000`. The
  island keeps its default addresses and is decoded in front of the boot
  ROM, which is why the ROM layout leaves that range empty. The window ROM
  is the one of `test/dbg/auth_rom`, built to take its nonce from `seed`
  and to wait for the entropy source's start-up test. It verifies a
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

`flow/rom_manifest.py` produces the last two by reading the packed ROM image
back, so they describe what the bitstream contains even if karudeb has moved
since. The target refuses to run when the ROM image is newer than the
bitstream, because a ROM repacked after the build no longer describes it.
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

The debug image passes Linux/NFS-root boot, `board_accept.sh` (memory,
cache, crypto, KVM API and profile checks), both KVM guests, the vector
selftests, riscv-pqc `xtest` and the Zvknhk OpenSSL pairs
([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)). On-board TestFloat-3e
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
