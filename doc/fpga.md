# FPGA — VCU118 / xcvu9p

`karu64` targets the **Xilinx VCU118** board (part `xcvu9p-flga2104-2L-e`,
Virtex UltraScale+ VU9P), built with **Vivado 2026.1** (previously 2025.2.1; the
full-vector ROM bit was last reproduced on 2026.1). The part is wildly
over-provisioned for this core (6840 DSP48E2, 4320 BRAM), so **area is a
non-issue — timing is the only question.**

There are two SoC flavours, sharing the same core (`rtl/`) verbatim:

- a **BRAM SoC** (`flow/fpga/fpga_top.v`) with on-chip memory — the simple
  bring-up and console target;
- a **DDR4 SoC** (`flow/fpga/vcu118_ddr_top.v` + `karu_ddr_xbar.v`) with DDR4
  main memory via the Xilinx MIG, Ethernet, and a baked boot ROM — the
  Linux target.

For the core's micro-architecture see [architecture.md](architecture.md); for
simulating the SoC see [flows.md](flows.md).

## Toolchain: the `xilinx` alias

Vivado is **not** on the default `$PATH` on purpose — sourcing its settings drags
a legacy Verilator into the environment that shadows the one used for the sims.
Bring Vivado in only when needed:

```sh
alias xilinx='source $HOME/Xilinx/2026.1/Vivado/settings64.sh'
xilinx
make vcu118-ddr          # synth + place + route -> _build/vcu118_ddr.bit
make prog_vcu118_ddr     # program a connected board over JTAG
```

The boot/ROM builds compile bare-metal fu-boot with the `XCHAIN` toolchain
(default `riscv64-unknown-elf-`). If only a Linux GNU cross toolchain is
installed, override it — fu-boot is freestanding, so it builds fine:

```sh
make vcu118-ddr-sgmii-rom-vec XCHAIN=riscv64-linux-gnu- \
     VIVADO_VMEM_KB=84000000 VIVADO_THREADS=8
```

The Makefile launches Vivado from `_build`, so journals, logs, `.Xil`, generated
IP, project state, reports, checkpoints, and bitstreams stay under `_build`. The
sim/spike targets must run in a shell where `xilinx` has **not** been sourced.

`make prog_vcu118_ddr` deliberately does **not** depend on the build rule — it
flashes whatever `_build/vcu118_ddr.bit` exists (a prerequisite would let make
decide the bitstream is stale and silently start a multi-hour resynth). Build
first, then program.

Programming is **Vivado-version-tolerant**: the bitstream is opaque configuration
data streamed to the FPGA over JTAG, so a lab box running an *older* Vivado can
flash a bit built on a newer one. The deployed full-vector ROM bit (built on
2026.1) programs and boots from a **2025.2.1** `hw_server` / `prog_vcu118_ddr`
without issue. `flow/with_vivado.sh` sources 2026.1 if installed and otherwise
falls back to 2025.2.1, so the same command works on the build host and the lab
JTAG host.

For one-off Vivado/JTAG work without changing your shell, `flow/with_vivado.sh
<cmd>` sources the settings in a subshell only (e.g. `flow/with_vivado.sh make
prog_vcu118_ddr` to program the DDR4/ROM bit), and `flow/hw_server.sh`
start|stop|status manages the JTAG `hw_server`.

### Driving the console from the host

The CPU console (NS16550, `console=ttyS0,115200`) is on the CP2105 **SCI** port —
`/dev/ttyUSB1` @ **115200** (the ECI port `ttyUSB0` is unused). Both host helpers
assert RTS, which the CTS-gated NS16550 TX requires:

- `flow/serial_cap.py /dev/ttyUSB1 115200 _build/boot.log` — capture the console
  to an unbuffered, line-timestamped log.
- `flow/uart_cl.py /dev/ttyUSB1 115200 _build/boot.log` — drive U-Boot/fu-boot or
  the Linux shell (commands on stdin; `@wait <s>` sets the post-command capture
  window). It types **one character at a time** and self-corrects against the
  echo: the NS16550 RX intermittently doubles host→FPGA characters, but the FPGA
  echo is clean and reflects the true line buffer, so it lands long commands that
  the older whole-line `uart_drive.py` loses to the glitch.

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
                    refill + single-beat write-through) from BRAM, 0x10000000 -> UART
  karu_ns16550.v    NS16550-register-compatible UART (wraps uart_tx/uart_rx)
  fpga_tb.v         verilator/iverilog testbench for fpga_top
```

### Memory map (spike-compatible)

| Region       | Base         | Notes                                              |
|--------------|--------------|----------------------------------------------------|
| Main RAM     | `0x80000000` | BRAM (`1 << RAM_XADR` bytes, default 1 MiB) / DDR4 |
| CLINT        | `0x02000000` | `msip`/`mtimecmp`/`mtime` → machine-timer interrupt |
| PLIC         | `0x0c000000` | NS16550 = source 1 → `irq_external_m/s`            |
| NS16550 UART | `0x10000000` | one 4 KiB page, uncacheable; `intr` → PLIC          |

`RESET_PC = 0x80000000`, and the RAM base / `.tohost` placement match
`flow/spike.ld`, so the **same ELF runs on spike and on the board**. The layout
is bit-compatible with the default spike machine map, so a spike-targeted DTB
drives this SoC unchanged. Everything outside the DRAM window is uncacheable by
construction, so all MMIO bypasses the L1.

### NS16550 console — one binary for spike and hardware

Spike has a builtin 16550 at `0x10000000` (`reg-shift=0`, `reg-io-width=1`,
IRQ 1). `karu_ns16550.v` mirrors that register layout (RBR/THR@0, IER@1,
IIR/FCR@2, LCR@3, MCR@4, **LSR@5**, MSR@6, SCR@7), so the driver
`test/fw/ns16550.c` is identical on both: develop on spike with a real console,
run the same image on the FPGA. Two conventions matter:

> **Byte-wide accesses only.** spike rejects any access whose width ≠ 1;
> `test/fw/ns16550.c` uses `volatile uint8_t *` throughout.

> **RX consume = a write to SCR, not a read.** karu64's LSU issues only
> 8-byte-aligned reads and extracts the byte itself, so a read can't be the
> RBR-pop trigger (every LSR poll would alias to "RBR read" and drain the FIFO).
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

  `FUBOOT_DTB_OFF` was moved `0xF0000`→`0xFC000` once a U-Boot v2025.01 built with
  `riscv64-linux-gnu` gcc-15 grew to ~579 KiB and overran the old 576 KiB U-Boot
  region; the move enlarges that region to 624 KiB while the ~2.8 KiB DTB still
  has a 16 KiB region (ROM stays 1 MiB — no `karu_boot_mem` change). If U-Boot
  ever overruns again, `build_fuboot_rom.sh` aborts with an explicit
  `... overruns its region` error before P&R, so the failure is fast and obvious.

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

- **Don't leave the multiplies combinational.** Default `KARU_MUL_CYCLES=1`
  writes the 64×64 (`karu_m`) and 53×53 (`karu_fmul_d`) multiplies as a Verilog
  `*`, which maps to *unpipelined* DSP cascades — the classic Fmax killer. The
  multi-cycle knobs (`KARU_M_MUL_CYCLES`, `KARU_D_MUL_CYCLES`,
  `KARU_V_MUL_CYCLES`, `KARU_V_DIV_CYCLES`) and the FP fast-path multiply
  pipeline (`KARU_D_MUL_PIPE`) shorten them.
- **Two vector writeback levers** close the full-vector bitstream: the 2-stage
  lane pipeline `KARU_V_LANE_PIPE` (splits the `vsew`→result cone) and the
  cold-funnel writeback stage `KARU_V_CWB_STAGE` (lands the whole-register
  assemblies in a dedicated register before the VRF-write funnel). Both are
  byte-identical when off and cost ~0.1 % cycles.

The flow drops a **post-synthesis** snapshot (utilization / timing / worst-paths
/ `.dcp`) minutes in, before the long P&R, so structural long paths surface
early; the authoritative **post-route** reports are written at the end. Both land
under `_build/`. `make elab` / `make elab-ddr` are fast RTL-elaboration-only
checks for iterating on elaboration/range errors, and `make ooc OOC_TOP=<module>`
runs an out-of-context synth of a single module.

**Memory-restricted hosts:** the recipes cap Vivado's address space
(`VIVADO_VMEM_KB`) and thread count (`VIVADO_THREADS`). The scalar/IMAFDC builds
fit a 32 GB box; the full-vector build wants more (≈84 GB box, 8 threads).

## Validated status

- **DDR4 main memory** is validated on the real VCU118: the bitstream programs,
  the MIG calibrates, and the DDR memtest payload (fill/verify, alias, strobe,
  executing from DDR) passes.
- **Scalar Linux on hardware:** a standalone, hands-off boot to a **BusyBox
  shell** from the bitstream-baked boot ROM (fu-boot + OpenSBI + U-Boot + DTB),
  with 2 GiB DRAM and a working **LiteEth network stack** (eth0 up, ping + TCP +
  wget) on the real board.
- **Full-vector Linux on hardware:** the RV64GCV + Zvk bitstream boots **Debian
  trixie NFS-root to a root shell** (`root@karudeb:~#`, kernel `7.1.2-zvk`) —
  the first RV64GCV bit to reach userspace on hardware. Timing closed with
  `KARU_V_CWB_STAGE` plus a MIG `DM_NO_DBI` fix (post-route WNS +0.040 ns,
  0 failing endpoints). OpenSBI enables `mstatus.VS` from `misa.V`; the kernel
  detects V and runs vector userspace.
- **In simulation:** OpenSBI → Linux boots to a BusyBox/Debian shell in
  Verilator (`make linux-sim` / `make linux-v-sim` / `make linux-v-irfs-sim`),
  matching spike on the identical image. The Linux harness can bind
  `rtl/karu_assert.sv` into the core for frontend/MMU regression checking.

The Linux/rootfs/DTB/kernel artifacts are produced by the companion `../karudeb`
repository.

### Open items

- Runtime functional retest of the vector-crypto paths — the Zvk three-operand
  `.vv` general-`vs1` SHA-2/SM3/GHASH decode that OpenSSL's runtime-dispatched
  vector SHA-2 needs — under the on-board benchmarks. The **boot-level** retest is
  done: the `vcu118-ddr-sgmii-rom-vec` bit (rebuilt on **Vivado 2026.1**, **closed
  timing** — post-route WNS +0.015 ns, cpu_clk-region cone +0.021 ns, 0 failing
  endpoints, DRC 0 errors, LUTs 29.8 %) was programmed from the lab JTAG host's
  older **2025.2.1** Vivado and auto-booted hands-off — validating the auto-boot
  reset removal — through OpenSBI → U-Boot → NFS-root **Linux 7.1.2** to userspace
  with no panic. What remains is exercising the crypto at runtime.
- QSPI config-flash hardware reads.
- LiteEth throughput tuning (~150 KB/s today).
- Advertising the standard Zvk leaves in the DTB `riscv,isa` string for
  userspace auto-detection.
