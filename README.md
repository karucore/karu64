```
   __  ___                    ___
  /  |/  /__ ____  ___ ___   / _ \_______  _______ ___ ___ ___  _______
 / /|_/ / _ `/ _ \(_-</ -_) / ___/ __/ _ \/ __/ -_|_-<(_-</ _ \/ __(_-<
/_/  /_/\_,_/_//_/___/\__/ /_/  /_/  \___/\__/\__/___/___/\___/_/ /___/
    __ __                 _____ __ __
   / //_/___ ________  __/ ___// // /  RVA23U64 User Application Profile
  / ,< / __ `/ ___/ / / / __ \/ // /_  Full RVV 1.0 Vector, VLEN=256
 / /| / /_/ / /  / /_/ / /_/ /__  __/  Full Zvk Vector Crypto Features
/_/ |_\__,_/_/   \__,_/\____/  /_/     + PQC TG Vector Keccak Extension
```

# karu64

`karu64` is an RV64 core and FPGA bring-up tree. The Linux baseline is RV64GCV (RV64IMAFDCV + Zicsr + Zifencei, RVV 1.0 with Zvl256b), with M/S/U privilege, Sv39 translation, generic CLINT/PLIC/NS16550 platform services (interrupts and serial console). We also have full Zvkt (vector cryptography) extensions and Keccak available. We implement these components in portable Verilog under a permissive (BSD 3-Clause) license.

For testing on the [VCU118](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/vcu118.html) (Xilinx UltraScale+ FPGA) target, we instantiate a SoC with Xilinx DDR4 IP components for 2 GB of memory and [LiteEth/LiteX](https://github.com/enjoy-digital/liteeth) for a basic Gbit Ethernet that supports network boot and a filesystem.

The Linux/rootfs images, DTBs, kernel builds, and deployment artifacts are produced by the companion `karudeb` repository. The core, its flows, and the FPGA SoC are documented under [doc/](doc/) — see the Documentation section below.

The core is split into IFU, decoder, ALU, M (multiply/divide), FPU (single- and double-precision IEEE 754), LSU, CSR/privilege/MMU, register files, and vector execute blocks, all behind AXI4 instruction/data memory ports. The repository also carries freestanding firmware, Verilator and Icarus testbenches, VCU118 FPGA flows, Yosys/OpenSTA NanGate45 flows, and runners for riscv-tests, TestFloat, vector/crypto tests, and OpenSBI/Linux simulation.


## Documentation

- [doc/architecture.md](doc/architecture.md) — the core micro-architecture:
  pipeline and issue model, functional units, FPU, vector unit, privilege/MMU,
  the build-time configuration knobs, and RVA23 feature coverage.
- [doc/flows.md](doc/flows.md) — build/run flows, the riscv-tests + TestFloat +
  directed vector/Zvk/RVA23 suites, the Linux/SoC sims, and the spike commit-log
  divergence technique.
- [doc/fpga.md](doc/fpga.md) — the VCU118 SoC (BRAM and DDR4), NS16550 console,
  clocking/timing knobs, bitstream variants, and hardware/Linux status.
 
## Repo layout

    rtl/                    core RTL; top is rtl/karu64.v
      zvk/                  vector-crypto RTL, including custom keccak.v /
                            keccak_round.v
    test/fw/                bare-metal firmware and directed firmware tests
                            formerly under drv/
    test/zvk/               SystemVerilog Zvk KAT/decode testbenches
    test/coremark/          CoreMark port files
    test/riscv-tests/       git submodule, upstream riscv-tests
    test/SoftFloat-3e/      Berkeley SoftFloat 3e source
    test/TestFloat-3e/      Berkeley TestFloat 3e source
    flow/                   build/run scripts and linker scripts
      boot/                 VCU118 boot ROM / fu-boot sources
      fpga/                 VCU118 FPGA RTL, constraints, and Vivado Tcl
      syn/                  Yosys/OpenSTA synthesis-estimate flow
    doc/                    architecture, flows, and FPGA documentation
    _build/                 generated artifacts; intentionally gitignored

## Current status

- Scalar tests pass: `make test` is 110/110. Full generated RV64GCV [ACT4](test/act4-karu/): 2220 PASS / 0 FAIL — ACT4-clean. Targeted Zvk tests and end-to-end OpenSSL Crypto tests pass.
- Generated artifacts are built under `_build`: hello firmware, UART hello, `firmware.hex`, `vcu118_fuboot.hex`, commit logs, Vivado journals/logs, generated IP/project state, reports, checkpoints, and bitstreams.
- VCU118 DDR4 hardware is proven through MIG calibration, DDR memtest, hands-off boot from the bitstream-baked boot ROM, Debian Linux, and LiteEth networking.

## Architecture

### Block diagram

Two linked views — the SoC/top level, then the `karu64` core internals. Boxes map
to `rtl/` modules; the I-cache and DDR crossbar are build-gated paths.

```text
###########################  KARU64 — FIGURE 1: SoC / TOP LEVEL  #############################
#  sim tops: htif_tb · fpga_tb        hw tops: fpga_top -> vcu118_top / vcu118_ddr_top       #
#  clk/rst : reset_ctrl (POR stretch + 2-FF sync); BUFGCE_DIV or MIG-derived cpu_clk         #
##############################################################################################

                              +=====================================+
                              |          karu64  CORE               |
                              |   RV64GC + I M A F D C V + Zvk      |
                              |   single-issue · in-order · Sv39    |
                              |          ( see Figure 2 )           |
                              +===+=============================+===+
                                  |                             |
                   AXI4 imem (RO) |                             | AXI4 dmem (RW)
                                  v                             v
                        +-------------------+        +--------------------------+
                        | imem fetch (RO)   |        | dmem interconnect        |
                        |  DRAM 0x8000_0000 |        | (karu_ddr_xbar on DDR;   |
                        |   ..0x8FFF_FFFF   |        | peels MMIO off main mem) |
                        |  bootROM @0x1000  |        +--+------+-------+-----+--+
                        +-------------------+           |      |       |     |
                                                        v      v       v     v
                                                   +------+ +-----+ +-----+ +-----------+
                                                   | DRAM | |CLINT| |PLIC | | NS16550   |
                                                   | MIG/ | |0200_| |0c00_| | UART      |
                                                   | BRAM | |0000 | |0000 | | 1000_0000 |
                                                   |0x8.. | +--+--+ +--+--+ +-----+-----+
                                                   +------+    |       |          | console
                                                          timer|   ext |IRQ       | (TX/RX)
                                                          MTIP |  MEIP/SEIP       |
                                                               +-----+--+---------+
                                                                     |  irq lines
                                                                     v
                                                          (core CSR / trap logic)

                        +----------------------------------------------------+
                        | LiteEth MAC + karu_eth bridge (wired) @0x1100_0000 |
                        |   ext SGMII -> DP83867 PHY = PLANNED (board-link)  |
                        +----------------------------------------------------+


###########################  FIGURE 2: karu64 CORE INTERNALS  ################################

   FRONT-END (fetch -> decode)                                 REGISTER FILES
   ---------------------------                                 --------------

   +-----------+   ifu_w (insn word, to DECODE)    +--------------+   +------------------+
   | IFU       |=================================> | RVC64 + DEC  |   | x-RF  2R/1W      |
   | buf0/buf1 |                                   | + bitmanip   |   | f-RF  3R/1W      |
   | RVC realgn|                                   |  decode pass |   | VRF  (BRAM-backed|
   +-----+-----+                                   +------+-------+   |  vrf_bram + _wr) |
         | fetch reads (IFU AXI read master)              | uops      +----+-----+-------+
         v                                                v                ^ rd  | wb
   +-----------+    +----------------------+    +====================+     |     |
   | ICACHE    |==> | imem AXI master (RO) |    | ID/EX packet ex_*  |-----+     |
   | (opt; DM, |    |  = fetch + IMMU PTW  |    | issue + bypass +   | operands  |
   |  64B line)|    |    reads  (=> Fig 1) |    | hazard / 1-issue   |<----------+
   +-----------+    +----------^-----------+    | retire gate        |
                               | PTW reads      +=========+==========+
   +------------------------+  |                          |  dispatch
   | IMMU karu_sv39 (fetch  |==+                          v
   |  xlate; PTW + TLB)     |
   +------------------------+
        SCALAR EXECUTE                                    v          VECTOR EXECUTE
   +--------+ +--------+ +------+ +------+ +---------+         +--------------------------+
   | ALU    | |BITMANIP| | M    | | CSR  | | FPU     |         | VLSU (karu_vlsu)         |
   | 1-cyc  | |Zba/b/s | |mul/  | |M/S/U | | F/D     |         |  unit-stride / whole /   |
   |        | |        | |div   | |fcsr  | | disp.   |         |  mask / strided /        |
   +--------+ +--------+ +------+ +------+ +----+----+         |  indexed / segment       |
                                                |              |  (per-elem pelem engine) |
                              fmul fadd fdiv    |              +------------+-------------+
                              fsqrt fcvt fmisc  |                           |
                              ffma  +D-variants |              +------------v-------------+
                              +Zfa (karu_fzfa)  |              | VARITH (karu_varith)     |
                                                |              |  unified vec execute FSM |
   +------------------------+                   |              | +----------------------+ |
   | LSU (karu_lsu)         |                   |              | | VLANE x NLANES       | |
   |  ld/st + A (LR/SC,9AMO)|                   |              | |  SIMD e8/16/32/64    | |
   |  FLW FSW FLD FSD  flh  |                   |              | |  + rolled-in FPU     | |
   +-----------+------------+                   |              | |  + vest7 (recip est) | |
               |                                |              | +----------------------+ |
               | PA                             |              | | VCRYPTO (rtl/zvk/)   | |
               v             vxlate_* (shared,  |              | |  AES SHA2 SM4 SM3 GH | |
   +------------------------+  owner-latched)   |              | +----------------------+ |
   | DMMU  karu_sv39        |<------------------+--------------| | KECCAK (vkeccak)     | |
   | PTW + TLB              |     data xlate                   | +----------------------+ |
   | (LSU + VLSU preflight) |                                  +------------+-------------+
   +-----------+------------+                                               | 128-bit
               | PA                                                         v  vec port
   +========================================================================================+
   |  karu_mem  -  write-through L1  (scalar LSU port + 128-bit vector port; these two only)|
   |  page-table walks BYPASS this L1; the core-level dmem arbiter (karu64.v) muxes karu_mem|
   |  with DMMU reads/writes + IMMU A/D writes onto the single dmem AXI master              |
   +===================================================+====================================+
                                                       |
                                                       v   AXI4 dmem (RW) -> interconnect (Fig 1)

   WRITEBACK  ->  x-RF / f-RF / VRF      (invariant: <=1 FU retires/cycle, one dest class)
   PASSIVE    :  karu_assert (INV1..35 + hang guards) · karu_vrf_assert · karu_plic_assert
```

A few things the diagram encodes: there is **one data MMU** (`dmmu`), time-shared by
the scalar LSU and the VLSU preflight via an owner latch (`vxlate_*`); a second
`karu_sv39` (`immu`) translates fetch. **Vector FP has no separate unit** — it lives
inside each `VLANE` (a rolled-in `karu_fpu`); the standalone `FPU` box is scalar F/D
only. `karu_varith` is the umbrella that also runs Zvk (`VCRYPTO`) and `vkeccak` as FSM
modes. `karu_assert`/`karu_vrf_assert` are passive checkers (testbench-only, not in the
synth read list).

Two things the memory side gets right that are easy to misread: **`karu_mem` is an L1
for the two real data ports only** — the scalar LSU port and the 128-bit vector port.
Page-table walks do **not** go through it; the core-level dmem arbiter in `karu64.v`
muxes `karu_mem` with the DMMU's PTW reads/writes and the IMMU's A/D-bit writes onto the
single dmem AXI master. And the **DDR address map**: `is_dram = pa[31:28]==0x8` selects
DRAM `0x8000_0000..0x8FFF_FFFF` (the cacheable window), while the `fuboot` boot ROM is a
low window at `0x0000_1000`; `karu_ddr_xbar` peels CLINT/PLIC/UART/Ethernet/flash off as
MMIO. The LiteEth MAC + register path is wired into the DDR SoC (MII loopback today,
→ PLIC source 2); the external VCU118 SGMII → DP83867 PHY link is a planned board-link
step, not yet wired.

`karu64` implements an RV64GC (RV64IMAFDC) target with FLEN=64 f-regs
(NaN-boxed singles, raw 64-bit doubles):

- **I**: RV64I integer ALU, loads/stores over a 64-bit data bus, W-suffix
  arithmetic (`addw/subw/sllw/srlw/sraw` and immediate forms)
- **M**: full RV64M — mul, mulh, mulhsu, mulhu, div(u), rem(u), and the
  *W* variants. `karu_m.v` is parameterized by `KARU_M_MUL_CYCLES`
  ∈ {1, 4, 16, 64} (default 1: combinational `*`; otherwise radix-2^K
  shift-and-add) and `KARU_M_DIV_CYCLES` ∈ {1, 64} (default 1:
  combinational `/`/`%`; 64 = restoring bit-serial).
- **F**: IEEE 754 binary32 — fadd/fsub/fmul/fdiv/fsqrt, fmin/fmax,
  fsgnj/n/x, feq/flt/fle, fclass, fmv.x.w / fmv.w.x, all 8 fcvt variants
  (FCVT.{W,WU,L,LU}↔.S), and the four FMA forms (FMADD/FMSUB/FNMSUB/
  FNMADD). f-regs are 64-bit with NaN-boxed singles (upper 32 = all 1s).
  Sub-units have a uniform req/busy/done/result/fflags handshake plus
  a `latency` output so a future pipeline/vector scheduler can reserve
  writeback slots.
- **D**: IEEE 754 binary64 — same op coverage as F (fadd/fsub/fmul/fdiv/
  fsqrt.d, fmin/fmax/fsgnj/feq/flt/fle/fclass/fmv.{x.d,d.x}, all 8
  FCVT.{W,WU,L,LU}↔.D variants, the four FMA forms, plus the two
  cross-precision conversions FCVT.S.D and FCVT.D.S). FLD/FSD wire
  into the existing 64-bit LSU. The decoder produces `fp_is_d` from
  the instruction's fmt field; `karu_fpu` dispatches to D sub-units
  when set and bypasses the NaN-box check (D values use the full 64
  bits raw).
- **A**: LR.{W,D}, SC.{W,D}, and all nine AMOs (swap/add/xor/and/or/min/
  max/minu/maxu) in `.W` and `.D` widths. Implemented in `karu_lsu` as
  a load-then-compute-then-store sequence with an internal ALU; LR/SC
  use a single-bit reservation register (single-core in-order, so
  nothing else races). `aq`/`rl` bits are no-ops.
- **C**: RV64C compressed instructions with the standard RV64 swaps
  (`c.jal`→`c.addiw`, `c.flw/c.fsw` slots→`c.ld/c.sd`, 6-bit shamts,
  `c.addw/c.subw`)
- **Privilege/MMU**: M/S/U-mode support sufficient for OpenSBI and Linux,
  including trap/return paths, delegation, `satp`, and Sv39 translation
  through dual `karu_sv39` instances. IFU redirects and `sfence.vma` are
  treated as frontend kill/refetch points: stale IFU translations are
  discarded, new IFU translations are not issued while the IMMU is busy, and
  active Sv39 walks are poisoned by a concurrent flush so they cannot refill
  TLB/PWC state or start A/D writeback.
- **CSRs**: machine/supervisor trap and status CSRs plus `fcsr/frm/fflags`;
  sticky `fflags` are OR'd from FPU op completions. PMP is not implemented.
- **Interrupts**: CLINT timer and PLIC external interrupt paths are wired
  in the FPGA SoC and validated in simulation. MSIP exists as a CLINT
  register but is not yet delivered as a core IRQ.
- **Vector/crypto**: vector and vector-crypto RTL is present for the
  simulation/regression path. The scalar Linux and VCU118 DDR bring-up
  profiles currently build with V disabled; Linux-grade VLSU/Sv39 behavior
  is the next vector integration step.
- PC is 64-bit internally for Sv39 high-half kernel/user addresses. The
  current FPGA/sim memory maps still place RAM and MMIO in the low 4 GiB.

**Known limitations:** PMP is absent and MSIP is not delivered as an IRQ.
(FP is fully IEEE — gradual underflow, subnormal in/out, fused single-rounding
FMA — and vector load/store translates through the shared Sv39 DMMU.)

The top-level core wires together:

- `karu_ifu`: 64-bit AXI4 read-only instruction fetch, two-entry prefetch
  buffering, compressed-instruction realignment, redirects, and stale
  fetch drain after redirects. Its Sv39 request path uses `immu_busy` as the
  missing accept handshake and drops old translation completions after
  redirect/`sfence.vma`.
- `karu_dec` + `karu_rvc64`: RV64I/M/F decode plus RV64C expansion into
  shared unit/sub-op controls. The decoder also produces `rs1_is_f`/
  `rs2_is_f`/`rs3_is_f`/`rd_is_f` flags so the core knows which regfile
  to read/write per op (FMV.W.X reads x → writes f; FMV.X.W the reverse;
  FMA needs rs3 from f; etc.).
- `karu_alu`: integer ALU including RV64 W-ops.
- `karu_m`: M-extension functional unit (see above).
- `karu_lsu`: 64-bit AXI4 load/store unit. Byte/half/word/dword accesses,
  sign/zero extension, byte strobes for stores, split two-beat handling
  for misaligned accesses crossing an 8-byte boundary, and the FLW/FSW
  path that NaN-boxes loads into the f-regfile and pulls store data from
  it.
- `karu_fpu`: F-extension dispatcher. Routes ops to `karu_fmul`,
  `karu_fadd`, `karu_fdiv`, `karu_fsqrt`, `karu_fcvt`, and the
  combinational ops in `karu_fmisc`. FMA is a tiny mul→add sequencer
  with operand latching (the IFU has already advanced by the time the
  add stage runs).
- `karu_csr`: M-mode CSRs + fcsr/frm/fflags. FPU op completions
  sticky-OR into fflags.
- `karu_regfile` / `karu_fregfile`: integer and FP register files
  (separate, the FP file has 3 read ports for FMA).

The implementation is single-issue in-order today, but the code is
structured around explicit front-end, execute, LSU, M, FPU, CSR, and
writeback blocks so it can grow toward deeper pipelining and multi-issue
without keeping everything in one monolithic core file.


## No-Hardware Testing Quick start

Toolchain: a GNU `riscv64-unknown-elf-*` toolchain (mine is built
`--with-arch=rv64gcv --with-abi=lp64d`), plus `spike`, `iverilog`,
and `verilator` on `$PATH`.

    # clone with submodules (riscv-tests + its env/)
    git clone --recurse-submodules https://github.com/karucore/karu64.git

    # 1. build the hello firmware and run it on spike
    make spike
    # -> prints "[RESET]\n[PASS]\tAll tests ok.\n"

    # 2. simulate the same binary on scalar NO_V karu64 in iverilog
    make htif-sim
    # -> same output; _build/karu.log gets a spike-style commit trace

    # 3. or run it (much faster) under verilator
    make veri

    # 4. crank through the scalar riscv-tests suite
    make test
    # -> PASS: 110   FAIL: 0    TRAP/OTHER: 0

    # 5. drill into a single test or its divergence vs spike
    make test-one  T=rv64ui-p-add
    make test-diff T=rv64um-p-mulh

    # 6. Berkeley TestFloat stress test for the F extension
    make testfloat-build           # one-time
    make fp-test OP=f32_add        # one op, RNE, ~1s
    make fp-test OP=f32_mul RM=rtz # other rounding modes: rne/rtz/rdn/rup/rmm
    make fp-test OP=f32_div RM=dyn FRM=rdn  # DYN: firmware sets fcsr.frm
    make fp-test-regression        # RNE x 17 ops, ~25s with PARALLEL=20
    make fp-test-all               # 5 rounding modes x 17 ops + DYN sanity, ~3 min

### Basic Tests and Berkeley TestFloat

    make test
    # PASS: 110   FAIL: 0    TRAP/OTHER: 0

| Suite       | Tests | Status |
|-------------|------:|--------|
| `rv64ui-p`  |    38 | PASS   |
| `rv64uc-p`  |     1 | PASS   |
| `rv64um-p`  |    13 | PASS   |
| `rv64uf-p`  |    11 | PASS   |
| `rv64ud-p`  |    12 | PASS   |
| `rv64ua-p`  |    19 | PASS   |
| **Total**   | **110** | **all pass under iverilog and verilator** |

The full suite takes ~11s under iverilog, ~1.6s under verilator.

Notable cases worth knowing about:

- `rv64uc-p-rvc`: compressed-instruction fetch across 64-bit fetch
  boundaries.
- `rv64ui-p-ma_data`: misaligned loads/stores crossing an 8-byte
  boundary.
- `rv64uf-p-recoding`: special-case FP arithmetic (-Inf × 3, 0 × 1)
  and the canonical-NaN substitution for non-NaN-boxed values.
- `rv64uf-p-fmadd`: the four FMA forms.
- `rv64uf-p-fcvt_w`: float-to-int saturation for NaN, ±Inf, and
  out-of-range values, signed and unsigned, 32-bit and 64-bit.

Beyond `riscv-tests`, the repo wires up Berkeley TestFloat 3e —
46k+ weighted-random vectors per FP operation across all five RISC-V
rounding modes plus a DYN sanity check (~3 min wall with
`PARALLEL=20`). See [doc/flows.md](doc/flows.md) `#5 Berkeley
TestFloat` for the recipe. The F/D units do full subnormal
normalisation + gradual underflow and report **0 errors** across every
op and rounding mode.

### Architectural tests (ACT4)

Beyond `riscv-tests` and TestFloat, the repo runs **ACT4** — the RISC-V
Architectural Certification Tests (framework v4, the successor to the
deprecated `riscof`). Unlike a runtime signature compare, ACT4 uses the
**Sail** reference model (configured to match the DUT) to compute golden
results *ahead of time* and bake them into **self-checking ELFs**; karu64
just runs each one. The test self-checks internally, prints
`RVCP-SUMMARY: TEST PASSED|FAILED` over the HTIF console, and halts with
`tohost = 1`/`3`, which reuses the existing HTIF testbench.

    make -C test/act4-karu all              # generate Sail ELFs + run on karu64

The full scalar RV64GC sweep is **347/347 PASS** — fully conformant
(I/M/A/F/D/C, Zicsr/Zicntr/Zifencei, including full IEEE-754 subnormals and
fused single-rounding FMA).

ACT4 also covers **vector**: the framework generates the V test sources on
demand (its `vector-testgen` scripts, behind the `vector-tests` target),
rather than checking them in like the scalar suites. karu64's config already
declares the vector extensions — `Zve32x/64x`, `Zve32f/64f/64d`,
`Zvl32b…256b`, `VLEN=256` — so the selector can build the Vls*/Vi*/Vf slices;
landing those runs against the RVV RTL is the in-progress next step. See
[test/act4-karu/README.md](test/act4-karu/README.md) for the config, layout,
and per-slice status.

