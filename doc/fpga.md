# FPGA — VCU118 / xcvu9p

`karu64` targets the **Xilinx VCU118** board (part `xcvu9p-flga2104-2L-e`,
Virtex UltraScale+ VU9P), built with **Vivado 2026.1** (previously 2025.2.1; the
full-vector ROM bit was last reproduced on 2026.1). The part provides
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

## Current profile image — 2026-09-25

The RVA23S64 DDR/SGMII ROM image `b11d5efb…3b809` contains the 1W2R FP
register file (`7c2563e`). Vivado 2026.1 closed routed timing at 75 MHz:
whole-design setup/hold 0.000/+0.012 ns, `cpu_clk` +0.077/+0.012 ns,
14/14 bus-skew constraints met and zero bitstream DRC errors. The routed
reports remain on the build host; this programming host received the `.bit`
and `.ltx` bundle.

The image was programmed on September 25. It boots Linux 7.2.6-zvk from NFS
and passes `board_accept.sh` (memory, cache, crypto, KVM API and profile checks).
An FP probe completed; full on-board TestFloat3 is running. The September 22
reference image `03eeb088…e73d2` passed additional KVM guest, OpenSSL and
vector ABI tests, recorded separately by image hash. See
[diagnostics and result hashes](release-diagnostics-2026-09-14.md) and the
[matching boot selection](#opt-in-rva23s64-boot-selection).

## Tool environment

Use the wrapper to load Vivado's settings for one command. It keeps bundled
tools from shadowing the simulation toolchain in the parent shell. Set
`VIVADO_SETTINGS` to the installation's settings file when needed:

```sh
flow/with_vivado.sh make vcu118-ddr       # build -> _build/vcu118_ddr.bit
flow/with_vivado.sh make prog_vcu118_ddr  # separate, explicit JTAG programming
```

The boot/ROM builds compile bare-metal fu-boot with the `XCHAIN` toolchain
(default `riscv64-unknown-elf-`). If only a Linux GNU cross toolchain is
installed, override it — fu-boot is freestanding, so it builds fine:

```sh
flow/with_vivado.sh make vcu118-ddr-sgmii-rom-vec XCHAIN=riscv64-linux-gnu- \
     VIVADO_VMEM_KB=84000000 VIVADO_THREADS=8
```

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

> **RX consume = a write to SCR, not a read.** The UART retains its original
> explicit-pop protocol. Current scalar IO accesses preserve native byte
> addresses; this does not change the peripheral's RX-consume convention.
> `sio_getc()` reads RBR, then writes SCR (offset 7) to pop. On spike the read
> pops and the SCR write is a harmless scratch, so one binary advances exactly
> once on both. (Validated on hardware — it caught a real directed-rounding FP
> bug that only showed on the fpga_top path, since the FP multiplier read `rm`
> live at result time instead of latching it at `req`.)

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
  `liteeth` driver and a U-Boot v2025.01 S-mode payload complete the netboot
  path.
- **Hands-off boot ROM:** `flow/boot/vcu118_fuboot.c` (fu-boot) is baked into a
  1 MiB boot ROM together with OpenSBI, U-Boot, and the control DTB. fu-boot
  copies each blob to DRAM and chains OpenSBI → U-Boot → netboot — no JTAG/host
  stage. The CPU auto-boots once MIG calibration completes. The legacy "hold CPU
  in reset, load DRAM over JTAG-AXI, release via VIO" bring-up path is gated
  behind `KARU_DDR_HOST_DBG` (off by default; no debug scaffold in the shipped
  bitstream).

  The 1 MiB ROM is packed by `flow/build_fuboot_rom.sh` at the offsets defined in
  the Makefile (`FUBOOT_*_OFF`); the same offsets are baked into fu-boot via the
  generated `flow/boot/fuboot_blobs.h`, so the two must agree exactly. Current map:

  | Blob    | ROM offset | copied by fu-boot to |
  |---------|-----------|----------------------|
  | fu-boot | `0x00000` | (runs in place)      |
  | OpenSBI | `0x10000` | `0x80000000`         |
  | U-Boot  | `0x60000` | `0x80200000`         |
  | DTB     | `0xFC000` | `0x81B00000`         |

  Region capacities are 64 KiB for fu-boot, 320 KiB for OpenSBI, 624 KiB for
  U-Boot and 16 KiB for the DTB. The generated blob-size header is refreshed
  on every ROM build, and the packer rejects any region overrun before P&R.

  Build the companion firmware with `make -C ../karudeb karu-opensbi` when
  needed. The vector ROM uses `build/karu64/opensbi/fw_jump.bin` and
  `build/karu64/karu64-zvk-ddr.dtb` from that checkout; do not substitute
  firmware from a different image series. The embedded DTB and the separately
  TFTP-served `board.dtb` must be identical.

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
The 0/0x10000/0x60000/0xFC000 ROM layout and blob-overrun checks are unchanged.
Reports default to tag `ddr_rva23s64_sgmii_75_rom`. The bitstream output is
the existing `_build/vcu118_ddr.bit`; the command does not program the board.

For board programming on another host, run `make vcu118-program-bundle` and
transfer `_build/vcu118_programming.tgz`. Its members retain the `_build/...`
paths and contain the mandatory bitstream plus `_build/vcu118_ddr.ltx` when
available. The programming host can extract it at the repository root and run
`flow/with_vivado.sh make prog_vcu118_ddr`. For boot, separately stage `Image`
and `board.dtb` from the matching karudeb TFTP directory.
The NFS rootfs is separate. Keep the ROM/TFTP DTBs identical and use the normal
Svpbmt-enabled profile. The lab netboot command uses server 192.168.42.1,
board 192.168.42.10 and NFS root `/srv/nfs/karudeb`; TFTP loads Image at
0x80200000 and the DTB at 0x84000000.

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

The current image passes Linux/NFS-root boot, memory and cache probes,
Zvknhk OpenSSL checks, `vill_probe` and the KVM API check. The FP probe has
completed; full TestFloat3 is in progress. The extended vector ABI,
riscv-pqc and KVM guest results in the release diagnostics belong to the
September 22 reference image.

For each new build, retain its routed timing reports, rerun `board_accept.sh`
as root with `perf_run`-enabled cache counters, and record crypto and KVM
guest completion logs against the bitstream hash. Dedicated multi-group
vector-crypto and resident-Keccak firmware suites remain separate from the
OpenSSL and instruction-vector checks.

QSPI configuration-flash reads and LiteEth throughput tuning remain platform
enhancements, not CPU-profile gates. Linux/rootfs/DTB/kernel artifacts come
from the companion `../karudeb` repository. Its ROM and TFTP DTB copies must
remain byte-identical when deploying a new build.
