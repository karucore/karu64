# Flows — build, simulate, and validate

This document covers how to build firmware, simulate `karu64`, and run the
validation suites. The architecture is described in
[architecture.md](architecture.md); the FPGA SoC in [fpga.md](fpga.md).

Most flows run **HTIF** — the standard RISC-V host/target mailbox — so the same
ELF works under spike, Icarus Verilog, and Verilator. The FPGA/console flows use
an NS16550 UART instead (see [fpga.md](fpga.md)).

Toolchain: the `riscv64-unknown-elf-` GNU toolchain
(`--with-arch=rv64gcv --with-abi=lp64d`), plus `spike`, `iverilog`, and
`verilator` on `$PATH`. Submodules (`riscv-tests`, Berkeley TestFloat-3e +
SoftFloat-3e under `test/`) are initialised with
`git submodule update --init --recursive`.

## 1. The hello firmware (`test/fw/htif*.c`, `flow/spike.ld`)

`test/fw/htif.c` defines the `tohost`/`fromhost` mailbox symbols and a console
`sio_putc` on top of HTIF:

    while (tohost != 0) { }
    tohost = ((uint64_t)1 << 56) | ((uint64_t)1 << 48) | (uint8_t)ch;   // device 1, cmd 1

Exit packs `(code << 1) | 1`. `test/fw/htif_start.S` is the minimal `_start`
(set sp, zero BSS, enable `mstatus.FS/VS` so one ELF runs on spike and karu64,
call `main`, `htif_exit`). `flow/spike.ld` puts `.text.init` at `0x80000000`
and pins `.tohost` at `0x80001000` so the testbench knows where to watch.

    make spike         # build _build/hello.elf and run it under spike

Output:

    [RESET]
    [PASS]  All tests ok.

## 2. Icarus Verilog (`make htif-sim`)

`rtl/htif_tb.v` is a single-file testbench: a 128 KiB RAM model preloaded from
`_build/hello.hex` (`hexdump -v -e '1/8 "%016x\n"'`, one 64-bit word per line)
via `$readmemh`, two AXI4 slave ports (`imem_*` RO, `dmem_*` RW), and an HTIF
watcher that polls `ram[tohost_idx]` each cycle. Plusargs:

    +hex=<file.hex>       image to load
    +tohost=<hex-offset>  byte offset from 0x80000000 to the tohost word (default 1000)
    +commit_log=<file>    commit-log path when built with CORE_COMMIT_LOG

`make htif-sim` writes `_build/karu.log`; `[HTIF] exit 0` means a clean finish.

## 3. Verilator (`make veri`)

Same testbench, ~7× faster. `flow/sim_tb.cpp` forwards `+plusargs`, instantiates
`Vhtif_tb`, and clocks until `$finish`.

    make veri                               # _build/hello.elf
    SIM=veri make test-one T=rv64ui-p-add   # any riscv-test

The riscv-tests runner honours `SIM=veri|ivl` (auto-picks veri if built).

## 4. riscv-tests + the spike commit-log technique

The upstream `env/p` environment sets text at `0x80000000`, configures trap
handlers, and `mret`s into the test body in U-mode; `RVTEST_PASS/FAIL` `ecall`
back to M-mode, which writes `TESTNUM` to `tohost`. karu64 implements the full
M/S/U privilege + trap machinery this exercises (`satp`, `medeleg`/`mideleg`,
delegation, the legality gate); see [architecture.md](architecture.md).

    make test                       # full suite, 110/110 under both sims
    make test-one  T=rv64ui-p-add
    make test-diff T=rv64um-p-mulh  # diff karu's commit log vs spike

`make test` covers six upstream Makefrags:

| Suite      | Exercises                                       | Tests | Status |
|------------|-------------------------------------------------|------:|--------|
| `rv64ui-p` | RV64I integer ALU + control flow + loads/stores |    38 | PASS   |
| `rv64uc-p` | RV64C compressed-instruction fetch              |     1 | PASS   |
| `rv64um-p` | RV64M mul/div/rem (+ W variants)                |    13 | PASS   |
| `rv64uf-p` | RV32F single-precision FP + NaN-boxing          |    11 | PASS   |
| `rv64ud-p` | RV64D double-precision FP                       |    12 | PASS   |
| `rv64ua-p` | RV64A atomics: LR/SC + 9 AMOs (W/D)             |    19 | PASS   |
| **Total**  |                                                 | **110** | **all PASS** (iverilog + verilator) |

`flow/run_test.sh` builds the ELF, `objcopy`/`hexdump`s it, looks up `tohost`
with `nm`, runs the simulator, and greps for `[HTIF] exit 0` (PASS),
`[HTIF] exit <n>` (FAIL, `n` = TESTNUM), or `TRAP`/`TIMEOUT`.
`flow/run_all_tests.sh` iterates the Makefrag test lists.

### The commit-log divergence technique

Built with `-DCORE_COMMIT_LOG` (default sim rule), karu64 emits one line per
retired instruction in **exactly spike's `--log-commits` format**:

    core   0: 3 0x<pc> (0x<insn>) [x<rd> 0x<val>] [mem 0x<addr> [0x<val>]]

(4-hex insn for RVC, else 8-hex; loads defer one cycle until read data is
captured; M/FPU/vector ops defer until their unit's `done`.) `flow/diff_test.sh`
normalises spike's log (priv→3, strips CSR-write annotations) and reports the
**first** divergence — the fastest localiser for a real bug. Spin loops on
`tohost==0` diverge in iteration count; that is expected, not a bug.

**Known gap:** the log emits f-target ops as `pc (ins)` without spike's
`f<rd> 0x<val>` field, so an FPU compute bug usually surfaces at the *next*
x-writing op (`fmv.x.w`/`feq.s`) rather than at the arithmetic itself.

## 5. Berkeley TestFloat (FP arithmetic stress)

TestFloat-3e at `-level 1` generates 46k+ weighted-random + corner-case vectors
per op (NaN, ±Inf, subnormals, rounding-tie boundaries) — far better at finding
arithmetic bugs than the directed `rv64uf/ud-p` suites. karu64's F/D units are
**fully IEEE (gradual underflow, subnormal in/out, fused single-rounding FMA)**
and report **0 errors** across every op and rounding mode.

    make testfloat-build             # one-time: build SoftFloat + TestFloat into _build/
    make fp-test OP=f32_add          # one op; env RM=<rne|rtz|rdn|rup|rmm|dyn> FRM=<rne..rmm>
    make fp-test-regression          # RNE × 17 ops (~45 min: the mulAdd suites are 6.13M vectors)
    make fp-test-all                 # 5 rm × 17 ops + DYN sanity (~3 min, PARALLEL=20)
    make fp-test-dyn                 # DYN-only sanity (read frm CSR)

Pipeline per op: `testfloat_gen` → `flow/run_fp_test.sh` chunks the operands,
packs them to RAM-hex, runs the verilator `htif_tb` (4 MiB RAM, `HTIF_TB_XADR=22`),
dumps the output region, and pipes it to `testfloat_ver`. Chunks fan out up to
`PARALLEL=20` concurrently and are stitched in index order. The subject firmware
`test/fw/fp_subj.c` dispatches the op via inline asm; six rounding-mode variants
are built (`_build/fp_subj_{rne,rtz,rdn,rup,rmm,dyn}.elf`), and the `dyn` variant
writes the requested 3-bit `frm` into `fcsr` at startup so the DYN path is
genuinely exercised.

The FP targets always use the verilator build (`_build/Vhtif_fp/`): iverilog
allocates each RAM element as a sim object, so 4 MiB of RAM elaborates
impractically slowly, whereas verilator emits a plain C++ array.

## 6. Directed vector / FP / RVA23 cross-checks

Each subject lives in `test/fw/*_subj.c`, runs on the verilator core, and (where
a `-spike` variant exists) runs the **same ELF on spike** as golden. spike is
current and golden for these crosses.

    # Vector
    make vint-test     # integer vector              (+ vint-test-spike)
    make vperm-test    # permute/cross-lane          (+ vperm-test-spike)
    make vidx-test     # strided/indexed/segment LS  (+ vidx-test-spike)
    make vest-test     # vfrec7/vfrsqrt7 estimates   (+ vest-test-spike)
    make vfp-test      # vector FP arith/FMA/reduce/widen (no spike golden)
    make vstart-test   # vstart honor/clear/trap     (+ vstart-test-spike)
    make vresv-test    # vill + reserved-overlap traps (+ vresv-test-spike)
    make vmmu-test     # vector LS through Sv39 (V2/V3/V4) (+ vmmu-test-spike)
    make fsvs-test     # mstatus.FS/VS gating + Dirty/SD   (+ fsvs-test-spike)
    make vfh-test      # Zvfhmin FP16<->FP32 conv + e16/e8 trap (+ vfh-test-spike)

    # Scalar RVA23-mandatory (each with a -spike cross)
    make bitmanip-test zfhmin-test zfa-test rva-hints-test zcb-test \
         zicbo-test supm-test cbogate-test tvm-test zihpm-test

    # Opt-in counter / state-enable knobs (dedicated bins)
    make stateen-test smcntrpmf-test sscofpmf-test

    # Unit models (no spike)
    make bitmanip-unit-test   # karu_bitmanip vs C model (156k vectors, 0-error)
    make fcvt-hs-test         # FP16 converters vs SoftFloat-3e (~3.95M, 0-error)

    # Zvk vector-crypto
    make zvk-decode-test zvk-decode-leaf-test   # OP-VE decode (umbrella + per-leaf)
    make zvk-kat                                 # standalone + aggregate leaf KATs
    make zvk-test                                # full-core AES/SHA2/SM4/SM3/GHASH smoke
    make zvkb-test                               # Zvkb leaf vs C model (+ zvkb-test-spike)

**Force a clean rebuild before trusting a vector/FP PASS.** An incremental build
can leave a *stale* verilator binary that "passes" against old logic. After
editing `karu_varith.v`/`karu_vlane.v`/`karu64.v`, `touch` the top RTL file (or
`rm -rf _build/Vhtif_fp`) and rebuild.

## 7. SoC and Linux simulation

These use the NS16550 console (not HTIF) and the FPGA SoC harnesses. See
[fpga.md](fpga.md) for the SoC and bitstream details.

    make fpga-sim        # verilator fpga_top: boots _build/firmware.hex from BRAM over NS16550
    make spike-uart      # the same NS16550-console hello on spike
    make irq-test        # directed CLINT timer + PLIC/UART IRQ + interrupt-during-vector drain
    make ddr-irq-test    # the same suite through the DDR4/MIG bridge
    make icache-test     # opt-in I-cache: FENCE.I coherence + Sv39 fetch + IMMU arbitration

    make linux-sim       # boot OpenSBI -> rv64imac Linux (../karudeb) to a BusyBox shell
    make linux-v-sim         # full RV64GCV kernel directly through OpenSBI fw_jump
    make linux-v-irfs-sim    # self-contained busybox initramfs; userspace RVV [VECTEST] PASS
    make eth-sim         # bare-metal LiteEth MAC TX->RX loopback smoke
    make uboot-net-sim   # U-Boot netboot over the modeled NIC (ARP/ICMP/TFTP responder)

The Linux images come from the companion `../karudeb` repository; `make
karudeb-stage` stages the vector kernel/DTB/netboot artifacts into `_build/`.

## 8. Build-time variant flags

ISA-extension gating (`KARU_NO_*`) and the per-unit mul/div/pipeline/vector
knobs are summarised in [architecture.md](architecture.md). All documented
combinations pass the 110-test riscv-tests suite. Examples:

    make veri                                          # everything combinational (default)
    KARU_DEFINES="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64" ...   # small-core mul/div
    KARU_DEFINES="KARU_NO_V" ...                       # scalar build (also restores iverilog)
