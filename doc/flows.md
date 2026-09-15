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
    +read_error_addr=<hex>  inject SLVERR on the addressed 8-byte read beat
    +write_error_addr=<hex> inject SLVERR on a write burst touching that 8-byte beat
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

    make test                       # full configured upstream scalar suite
    make test-one  T=rv64ui-p-add
    make test-diff T=rv64um-p-mulh  # diff karu's commit log vs spike

`make test` covers six upstream Makefrags and derives its current count from
the provisioned submodule rather than from a hard-coded historical total.

| Suite | Exercises |
|---|---|
| `rv64ui-p` | RV64I integer ALU, control flow and loads/stores |
| `rv64uc-p` | RV64C compressed-instruction fetch |
| `rv64um-p` | RV64M mul/div/rem, including W variants |
| `rv64uf-p` | Single-precision FP and NaN-boxing |
| `rv64ud-p` | Double-precision FP |
| `rv64ua-p` | Atomics: LR/SC and AMOs |

`flow/run_test.sh` builds the ELF, `objcopy`/`hexdump`s it, looks up `tohost`
with `nm`, runs the simulator, and greps for `[HTIF] exit 0` (PASS),
`[HTIF] exit <n>` (FAIL, `n` = TESTNUM), or `TRAP`/`TIMEOUT`.
`flow/run_all_tests.sh` iterates the Makefrag test lists.
It now fails on missing Makefrags, an empty selection or a failed build;
zero tests must not be reported as a successful run.

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
a `-spike` variant exists) runs the **same ELF on Spike** as an independent
behavioral reference. Reserved-encoding checks may additionally need ACT4/Sail
where Spike permits reserved instruction forms.

    # Vector
    make vint-test     # integer vector + all-vl mask-summary sweep (+ vint-test-spike)
    make vperm-test    # permute/cross-lane          (+ vperm-test-spike)
    make vidx-test     # strided/indexed/segment LS  (+ vidx-test-spike)
    make vest-test     # vfrec7/vfrsqrt7 estimates   (+ vest-test-spike)
    make vfp-test      # vector FP arith/FMA/reduce/widen (no spike golden)
    make vstart-test   # vstart honor/clear/trap     (+ vstart-test-spike)
    make vresv-test    # vill + reserved-overlap traps (+ vresv-test-spike)
    make vwalk-test vwalk-test-ship vwalk-test-spike  # vl boundaries, masks, aliasing, tails
    make vmmu-test     # vector Sv39/Svade faults + software repair (+ vmmu-test-spike)
    make fsvs-test     # mstatus.FS/VS gating + Dirty/SD   (+ fsvs-test-spike)
    make vfh-test      # Zvfhmin FP16<->FP32 conv + e16/e8 trap (+ vfh-test-spike)

    # Scalar RVA23-mandatory (each with a -spike cross)
    make bitmanip-test zfhmin-test zfa-test rva-hints-test zcb-test \
         zicbo-test zihpm-test

    # Opt-in counter / state-enable knobs (dedicated bins)
    make stateen-test smcntrpmf-test sscofpmf-test

    # Unit models (no spike)
    make bitmanip-unit-test   # karu_bitmanip vs C model (156k vectors, 0-error)
    make fcvt-hs-test         # FP16 converters vs SoftFloat-3e (~3.95M, 0-error)

    # Zvk vector-crypto
    make zvk-decode-test zvk-decode-leaf-test   # OP-VE decode (umbrella + per-leaf)
    make zvk-kat                                 # standalone + aggregate leaf KATs
    make zvk-test-all                            # full-core AES/SHA2/SM4/SM3/GHASH on Karu + Spike
    make keccak-kat                              # Zvknhk vkeccak.vi datapath KAT (riscv-pqc KECCAK-P / KECCAK-P12)
    make keccak-test keccak-test-zvk             # full-core vkeccak.vi: spec KATs, fixed-group rules, reserved-encoding traps
    make zvkb-test                               # Zvkb leaf vs C model (+ zvkb-test-spike)
    make zvbb-test-all                           # full/subset/off decode gating + Karu/Spike behavior
    make keccak-bench keccak-sponge-test          # resident-state rate cycles and multi-block SHAKE KAT
    make keccak-compare                          # above plus checked GCC/Clang GC/Zbb/V+Zvbb baselines
    make mem-stream-test axi-bram-burst-test vrf-bram-test  # transport and VRF assertions

The [Keccak comparison harness](../test/keccak-sw/README.md) includes pinned
sources, full-output fixtures, generators and compiler/run manifests. See
[hardware throughput](keccak-throughput.md) and [software comparisons](keccak-software-comparison.md)
for the numbers and the distinction between vector-enabled C and a genuinely
register-resident permutation. The matched-profile ACT4 checkpoint is
2872/2872 on both minimal and shipping models. Results, prerequisites, patch
provenance and the run recipe are in
[test/act4-karu/README.md](../test/act4-karu/README.md).

**Ensure the simulator matches the RTL before trusting a vector/FP PASS.**
Build the top-level simulator target after RTL edits. If dependency tracking
or build flags are in doubt, `make -B -j4 _build/Vhtif_fp/Vhtif_tb` forces a
rebuild without deleting artifacts. Use the corresponding simulator target
for other configurations.

### Supervisor regressions

Reuse the existing firmware for end-to-end trap/translation checks, with
small unit benches for precise internal handshake cases:

```sh
make csr-test sv39-test ifu-test svinval-decode-test
make mmu-test mmu-test-spike vmmu-test vmmu-test-spike
make xpage-test xpage-test-spike access-test
make lsu-atomic-test atomic-align-test-spike
make tvm-test tvm-test-spike cbogate-test cbogate-test-spike
make supm-test supm-test-spike vsupm-test vsupm-test-spike
make sstc-test sstc-test-spike
make vmmu-pbmt-test vmmu-pbmt-test-spike icache-unit-test mem-stream-test
make vmmu-pbmt-fault-test eth-bridge-test plic-test axi-bram-burst-test
make keccak-sponge-pbmt-test
make irq-test ddr-irq-test
```

`csr-test` covers implemented CSR masks, WARL behavior, privilege, pending
interrupts, MPRV and Sstc's six CSR forms, permissions, 64-bit comparison and
two-cycle propagation bound. `sv39-test` checks the walker permission truth table,
Svade, Svnapot subpages/reserved encodings, Svpbmt attributes/PBMTE, page sizes,
PMA/AXI faults, inactive PTE-write channels and flushes
during outstanding reads. `ifu-test` checks compressed/split instructions at
page boundaries, exact instruction-fault values and canceled fetches.
`svinval-decode-test` distinguishes legal Svinval forms from reserved fields.

The scalar MMU firmware adds MPRV with MPP=S/U, SUM/MXR, A/D faults with
unchanged PTE/data, software repair through Svinval, non-leaf reserved bits,
64 KiB Svnapot mappings, MRET/SRET clearing, and CBO permissions/block boundaries. The vector MMU
firmware exercises Svade without partial writes, unchanged load destinations,
and software A/D repair/retry. `tvm-test` covers Svinval privilege checks,
including the ordering-only fences remaining legal in S-mode with TVM set.

`sstc-test` uses the existing HTIF privilege harness for 22 timer permission,
direct/legacy interrupt and vector-state cases; the same ELF passes Spike.
The optional simulator `+sstc_irqcheck` observer, enabled by this Make target,
requires hardware STIP to become pending while vector execution is busy and
checks that delivery waits for the operation to drain. It is a functional
ordering test, not a timer-latency performance benchmark.

`sv39-test`, `mmu-test`, `vmmu-pbmt-test`, `vmmu-pbmt-fault-test`,
`mem-stream-test`, `plic-test` and the IFU/I-cache/BRAM/DDR responders cover
the current translation and physical-memory behavior. Run the corresponding
Spike targets where supplied. `keccak-sponge-pbmt-test` reuses the resident
SHAKE128/SHAKE256 state test under NC and IO mappings; its whole-test cycle
total is functional coverage, not a throughput measurement. Current counts
and results belong in the release diagnostics rather than this command guide.

The separate ACT4 configuration enables S/U, Sv39/Svade/Svnapot/Svpbmt and non-H
Svinval/Sstc under privileged ISA 1.13:

```sh
make -C test/act4-karu config CONFIG_NAME=karu64-sv39
make -C test/act4-karu tests CONFIG_NAME=karu64-sv39 \
  EXT=Svbare,Svade,Svinval ACT_FLAGS=--fast
make -C test/act4-karu run CONFIG_NAME=karu64-sv39
```

The supervisor/CSR selection includes `InterruptsSstc`, Sv39, Svnapot and
Svpbmt cases and complements the full profile selection.
Reference generation, a DUT pass, a full supervisor audit and profile
certification are different results. Consult the
[ACT4 instructions](../test/act4-karu/README.md#configurations)
for the configuration manifest and verdicts, and the
[RVA23S64 status](rva23s64-plan.md) for remaining release gates.

### Hypervisor regressions

Current release evidence: both matched-profile ACT4 checkpoints pass
2872/2872. The shipping bitstream meets routed timing and passes Linux board
acceptance, including vector ABI and KVM API checks. See
[diagnostics](release-diagnostics-2026-09-14.md) for the exact scope and the
[FPGA boot procedure](fpga.md#opt-in-rva23s64-boot-selection) for hardware.

The opt-in H monitor lives in `test/karu_h_test.S` with its maintained linker
script. It shares firmware between Spike and HTIF; generated ELFs and logs
stay under `_build/`. Default release builds do not enable `KARU_H`.

For the opt-in mandatory profile composition, use `make rva23-config-test`
and `make -j4 rva23-sim`. This adds H/Ssstateen and Sscofpmf without optional
crypto or Smcntrpmf. Reuse the H firmware with
`make h-test VERI_H_DIR=_build/Vhtif_rva23s64 VFLAGS='-Irtl -DKARU_RVA23S64 -DHTIF_TB_CLINT -DHTIF_TB_EXTIRQ'`.
The two testbench flags select real timer/software and external interrupt
inputs for the profile ACT platform; they do not affect synthesized hardware.
`make clint-test` and `make extirq-test` run the 27/48-case device variants
of the existing Sstc firmware. `CLINT_TEST_ARGS`/`EXTIRQ_TEST_ARGS` accept
the usual memory-stall options; the external-input ABI is simulator-specific.
This is build/functional validation, not a profile-certification claim;
see [the profile test configuration](../test/act4-karu/README.md#configurations).

```sh
make csr-h-test hmem-decode-test svinval-decode-test ifu-test sv39-test
make sv39-compare-test
make -j4 h-test
# Build the isolated, pinned timer oracle once; see test/spike-karu/README.md.
JOBS=4 bash test/spike-karu/build.sh patched
make h-test-spike H_SPIKE=_build/spike-sstc-f10808d48aec-patched/build/spike
make -j4 h-context-keccak-test
make -j4 h-pmu-hw-test
```

`h-test` builds a separate H simulator and runs the 335-case Bare
memory/fence, 141-case two-stage, 187-case virtual-timer and 88-case two-guest
context variants. They share the same 53 baseline cases. To isolate one variant, set
`H_TEST_RUN_NAMES=karu_hvm_test`, `karu_hmem_hfence_test`, `karu_htimer_test`
or `karu_hcontext_test`.
`VERI_H_DIR` selects a separate output directory. Reproduce the H-enabled
shipping arithmetic/pipeline configuration with:

```sh
make -j4 h-test VERI_H_DIR=_build/Vhtif_h_ship \
  VFLAGS='-Irtl -DKARU_ICACHE -DKARU_ZVK -DKARU_KECCAK -DKARU_M_MUL_CYCLES=4 -DKARU_M_DIV_CYCLES=64 -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_SMCNTRPMF -DKARU_SSCOFPMF'
```

`sv39-compare-test` runs the same maintained walker scenarios with the guest
TLB enabled and disabled, comparing architectural completion signatures.
Directed assertions separately require zero PTE reads on hot translations
and exercise permission changes and cancellation; no second walker test
source is maintained.
The September 14 memory-path regression has 35,155 checks per cache setting
and matching signatures over 34,978 architectural completions. It includes
ROM/scratch PTEs at every level and malformed PWC burst termination.
`make mem-stream-test` additionally checks resident cacheable aliases after
scalar/vector NC/IO stores, including queued and partial/error paths without
an intervening cache flush. See the [release diagnostics](release-diagnostics-2026-09-14.md).

The paged fixture uses distinct VA/GPA/HPA and guest-PTE mappings, tests all
VS/G mode pairs, HLVX permissions, Svade, exact final/PTE fault metadata,
cross-page fetch/scalar accesses and vector fault-only-first trimming.
The timer fixture checks independent host/guest compares, virtual-time
offsets and wrap, all timer CSR forms/gates, actual VS/VU interrupts and
delegated VS traps. The normative reference uses the
[isolated Spike Sstc correction](../test/spike-karu/README.md); the unpatched
negative control must fail at its specific pending-bit case. No shared
installation is modified. `H_SPIKE_TIMEOUT` defaults to an external 60-second
deadline; instruction-count exhaustion must not be treated as completion.
Simulator success requires HTIF exit zero and no assertion/error/timeout
markers. Spike is the independent behavioral check, not a timing oracle.

The context variant switches A/B/A/B/A with distinct roots, ASIDs/VMIDs and
physical data/save areas. It checks software save/restore of all 32 FPRs and
all 32 vector registers, FP/vector controls, VS banks, independent timer and
software interrupt state, and delegated VS page-fault values. Switches are
also responsible for shared `scounteren`, `senvcfg` and `hstateen0..3`;
distinct guest counter/CBO/pointer-mask permissions and memory canaries
check their restoration. The fixture clears VSATP before changing guest
roots/environment and installs the new VSATP before fencing. Switches are
voluntary ECALLs with explicit guest fences, not asynchronous vector
preemption or a KVM workload. `h-context-keccak-test` adds the 91-case variant
in a separate H+Keccak simulator (`VERI_H_KECCAK_DIR` override). Guest A keeps
its state resident after 24 rounds, guest B clobbers it, and software restores
A before a 12-round permutation checked against the chained known answer.
The custom opcode has no Spike oracle; it is deliberately outside
`h-test-spike`'s default selection.

`make h-pbmt-test` selects the 300-case paged guest variant and requires
`+pbmt_guest_check`, the general PBMT observer and HTIF-zero completion.
The observer checks all nine VS/G type pairs against the fixture PTEs and
the final PA/type, scalar/vector/fetch transport and guest access-fault/FF
prefix behavior. It also checks 144 guest CBO combinations: nine VS/G pairs,
four operations and four permission states, with exact block accesses and
no side effects on denial. The CBO observer PASS marker is mandatory.
Repeat with `H_PBMT_ARGS='+ddr_stall=11 +imem_lat=2'` for
backpressure. `h-pbmt-test-spike` uses a matching 4 MiB memory extent and
`_svpbmt` ISA selection. Use `VERI_H_DIR`/`VFLAGS` as above to select each
profile pipeline; the [profile test record](../test/act4-karu/README.md#evidence-and-interpretation)
describes the composition. `+ddr_stall`, not `+ddr_lat`, is the supported
data-bus stall option; the latter is rejected explicitly.

The [release diagnostics](release-diagnostics-2026-09-14.md) record current
counts and whole-test cycles; these results are not full
H/Sha assurance or a guest performance benchmark. Asynchronous guest
preemption has its own directed checkpoint below; broader H architectural-reference
coverage and platform integration remain separate gates. The separate [H ACT4 configuration](../test/act4-karu/README.md#configurations)
uses Sail 0.14 without replacing the non-H reference baseline.

`h-preempt-test` runs the 96-case asynchronous variant with the mandatory
`+hcontext_preemptcheck` observer. It requires timer-pending edges during
FP/vector work in both guests, retirement before HS interrupt delivery and
precise resumed PCs, plus full saved-context canaries. For a profile model:

```sh
make -j4 h-preempt-test VERI_H_DIR=_build/Vhtif_rva23s64 \
  VFLAGS='-Irtl -DKARU_RVA23S64 -DHTIF_TB_CLINT -DHTIF_TB_EXTIRQ'
make h-preempt-test-spike H_SPIKE=_build/spike-sstc-f10808d48aec-patched/build/spike
```

Use `H_PREEMPT_ARGS='+ddr_stall=11 +imem_lat=2'` for backpressure, and a
separate model directory with the shipping flags above for that pipeline.
`H_PREEMPT_FP_TICKS`/`H_PREEMPT_VEC_TICKS` in the firmware select the stimulus
deadlines (defaults 256/64); an overlap miss fails rather than being counted
as preemption coverage. Current result counts are in
[the release diagnostics](release-diagnostics-2026-09-14.md).

`h-pmu-hw-test` builds an H+Sscofpmf+Smcntrpmf model in
`_build/Vhtif_h_pmu` (`VERI_H_PMU_DIR` override). It runs the existing
M/S/U hardware-event firmware plus 21 VS/VU cases for exact retire counts,
inhibit masks, MPRV independence, overflow/rearm and actual HS interrupt
delivery, including shared-pending Shlcofideleg delivery to VS as cause 13
and fallback to HS. No Spike event-oracle result is claimed: its programmable counters
are stubs. Use the shipping `VFLAGS` above and a separate model directory
to repeat the test on that pipeline.

`make -j4 htif-ddr-stall-test` reuses that model and the existing guest
FP/vector preemption firmware, with `+ddr_stall=0,1,2,5,17` in separate runs.
The injector delays AW/AR acceptance, every W beat, and publication of every
R beat and B response. It never retracts a published response. Nonzero runs
require observed AW/AR stalls, mid-burst W stalls and R/B delays using
`+ddr_stall_check`; logs are `_build/htif-ddr-stall-N.log`. The default zero
setting preserves ideal timing.

`make plic-test` includes gateway transition assertions and three deliberately
corrupted-state controls that must fail the appropriate assertion. A masked
in-service source can be recovered by re-enabling it and completing again.
`make mem-stream-test` likewise checks that simultaneous scalar/vector
requests in idle trip the arbitration assertion (load and store controls).
`make axi-bram-burst-test axi-ddr-hold-test` covers CLINT's read-only-zero
reserved MSIP bits, including writes through each byte lane.

The [Linux KVM fixture](../test/kvm-karu/README.md) builds an isolated kernel,
initramfs and simulation-only DTB, then requires actual upstream selftest
guest completion. A host boot banner or `/dev/kvm` alone is not a pass.

The accompanying non-H ordering regression extends `mmu-test` to 394 cases.
Its `+ifu_faultcheck` observer requires five real younger-fetch/older-data
fault overlaps, successful older operations retiring first, and older data
faults winning over the pending fetch fault. `mmu-test` requires both its
PASS marker and the existing PBMT observer marker. `tvm-test` has 39 cases,
including legal S-WFI with TW=0 and illegal U-WFI for either TW value.

## 7. SoC and Linux simulation

These use the NS16550 console (not HTIF) and the FPGA SoC harnesses. See
[fpga.md](fpga.md) for the SoC and bitstream details.

    make fpga-sim        # verilator fpga_top: boots _build/firmware.hex from BRAM over NS16550
    make spike-uart      # the same NS16550-console hello on spike
    make irq-test        # CLINT timer/software + PLIC/UART IRQ + interrupt-during-vector drain
    make ddr-irq-test    # the same suite through the DDR4/MIG bridge
    make icache-test     # opt-in I-cache: FENCE.I coherence + Sv39 fetch + IMMU arbitration

The software-interrupt case writes the CLINT MSIP MMIO register, checks
masking and delivery, clears and rearms the source, and confirms CSR writes
cannot inject or clear `mip.MSIP`. `make axi-bram-burst-test` also checks the
responder's MSIP output independently of the core.

    make linux-sim       # boot OpenSBI -> rv64imac Linux (../karudeb) to a BusyBox shell
    make linux-v-sim         # full RV64GCV kernel directly through OpenSBI fw_jump
    make linux-v-irfs-sim    # self-contained busybox initramfs; userspace RVV [VECTEST] PASS
    make eth-sim         # bare-metal LiteEth MAC TX->RX loopback smoke
    make uboot-net-sim   # U-Boot netboot over the modeled NIC (ARP/ICMP/TFTP responder)

`make linux-axi-test linux-axi-negative-test` directly exercises the Linux
SoC AXI responder. The positive suite checks independent AW/W arrival,
byte-lane alignment, multi-beat reads and burst-final write responses, stable
MMIO read snapshots and one-shot side effects under R-channel stalls, plus the
shared real CLINT time source. Two source-mutation controls deliberately
restore an early B response and shifted write lanes; both must fail. These
tests validate the responder rather than claiming that Linux or a KVM guest
completed on the processor RTL.

The Linux images come from the companion `../karudeb` repository; `make
karudeb-stage` stages the vector kernel/DTB/netboot artifacts into `_build/`.

`make linux-trace LINUX_TRACE_VECTOR=1` enables save/restore and bounded
waveforms with the vector/crypto RTL and assertions. Use `LINUX_DEFS` to
match the intended ISA and arithmetic pipelines. Saved state includes the
clock phase and harness counters; replay requires the same binary.
The [KVM checkpoint recipe](../test/kvm-karu/README.md#checkpoint-and-waveform-replay)
includes a short state-equivalence test and explains the distinction between
replay, integration verdicts and reference-model comparisons.

## 8. Build-time variant flags

ISA-extension gating (`KARU_NO_*`) and the per-unit mul/div/pipeline/vector
knobs are summarised in [architecture.md](architecture.md). Profile
compositions use their dedicated gates above. Examples:

    make veri                                          # everything combinational (default)
    KARU_DEFINES="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64" ...   # small-core mul/div
    KARU_DEFINES="KARU_NO_V" ...                       # scalar build (also restores iverilog)
