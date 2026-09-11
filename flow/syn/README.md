# karu64 — open-source synthesis flow

A small Yosys + OpenSTA flow that drops `karu64` onto the **NanGate45**
typical-corner library and reports gate-count, cell area, and timing
slack per path group. Patterned after the `ibex/syn` flow; the RTL is
plain Verilog so the karu64 path has no `sv2v` step. The optional Ibex
baseline target does use `sv2v`, matching the upstream Ibex source format.

**This is not a tape-out flow.** Numbers here are useful for relative
comparisons (before/after a refactor, fast vs. bit-serial mult, F vs.
F+D, etc.) and for spotting timing hot-spots, not as absolute area or
Fmax targets.

## Requirements

- [Yosys](https://github.com/YosysHQ/yosys) (tested with 0.65)
- [OpenSTA](https://github.com/parallaxsw/OpenSTA) (tested with 2.4.0 and
  3.1; `tcl/sta_run_reports.tcl` probes for the `-group_count` vs
  `-group_path_count` spelling so both work)
- `sv2v` for the optional `make ibex` comparison target
- NanGate45 typical-corner liberty file `NangateOpenCellLibrary_typical.lib`,
  looked up in `../../../src/flow` (a `src/` checkout next to `karu64/`, the
  usual layout) and then `../../src/flow` (inside the checkout). Override via
  `$KARU_LIB`.

## Flow status (checked 2026-09-11)

Re-validated on a 31 GB / no-swap workstation with Yosys 0.65+73 and OpenSTA
2.4.0. Four things were broken and are fixed in the tree:

- `syn_setup.sh` only looked for the liberty file inside the checkout, so
  `make synth` died before Yosys started.
- OpenSTA 2.4 rejected `report_checks -group_path_count`, so every timing
  report was empty and the summary printed `WNS: n/a`.
- `KARU_LTP=1` ran `ltp` on the *mapped* netlist; with liberty `DFF_X1`
  cells ltp no longer recognises flops, reads every Q→D feedback as a loop
  and wrote a 3 GB `depth.rpt` of `Detected loop` lines with bogus lengths
  for every module. It now runs on the pre-map netlist with the `karu64`
  top and `karu_mem` excluded (both trip the sort through submodule
  reconvergence); one clean line per leaf module, 0.4 MB.
- The fast ABC script produced netlists whose STA slack is meaningless (see
  *Timing observations*); timing runs now use the full script.

What works: `make synth` (area + real STA) for the scalar configurations,
`make depth`, `make sweep`/`make area-matrix` for scalar rows (~2 GB peak).
The full RV64GCV+Zvk+Keccak row is **not runnable on a 31 GB / no-swap
host**: Yosys' `opt` on `karu_varith` aborted with an allocation failure under
a 22 GB `ulimit -v` (18 GB resident at that point), and a retry under a 27 GB
cap was still growing past 21 GB resident when it took the whole machine
down. `ulimit -v` is not a physical-memory bound. Run vector rows on the
86 GB box as `AREA_MATRIX.md` says, and if a local guard is ever needed use
a cgroup limit (`systemd-run --user --scope -p MemoryMax=20G ...`).

## First-time setup

```
make synth                             # or: ./syn_yosys.sh
make ibex                              # optional same-flow Ibex baseline
make area-matrix CONFIGS="imac_m4d64 rv64gc_m4d64"  # optional fast area matrix
```

`syn_setup.sh` is tracked as the shared default because the usual developer
environments are similar. The example file is kept as the template; both
resolve the liberty path automatically from `../../src/flow/`.

## Tunables

All set via env vars in `syn_setup.sh` or one-shot on the make line:

| Var | Default | Meaning |
|---|---:|---|
| `KARU_LIB` | `../../src/flow/NangateOpenCellLibrary_typical.lib` | Liberty file |
| `KARU_CLK_PS` | `4000` (250 MHz) | Target clock period in ps |
| `KARU_ABC_UPRATE_PS` | `2000` | ABC's clock is `KARU_CLK_PS - KARU_ABC_UPRATE_PS` ps; tighter -> abc optimises harder |
| `KARU_IN_PCT` | `30` | Input arrival as % of period |
| `KARU_OUT_PCT` | `70` | Output settling as % of period |
| `KARU_OUT_DIR` | `_build/syn_out/karu64_<timestamp>/` | Run output tree |
| `KARU_DEFINES` | `KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64` | Space-separated `-D` flags passed to `read_verilog`. Default is the "small core" config; see results below. Set to empty (`KARU_DEFINES=""`) to pass no explicit defines and let the RTL headers resolve their non-SIM defaults. Use `KARU_MUL_CYCLES=1 KARU_DIV_CYCLES=1` for the all-combinational variant. **Feature gating** also goes here: `KARU_NO_F` / `KARU_NO_D` / `KARU_NO_V` (cascade `V⊃D⊃F`) drop FP/vector units; `KARU_NO_B` drops scalar Zba/Zbb/Zbs; `KARU_NO_S` drops S-mode/Sv39 and prunes both MMU walkers; `KARU_NO_HPM` drops `mhpmcounter3..31`/`mhpmevent3..31`; `KARU_NO_MEM` drops the scalar L1/cache wrapper in non-vector builds. `hierarchy -top` then prunes disabled modules/state. |
| `KARU_NOSHARE` | unset | When set, passes `-noshare` to Yosys `synth`, skipping SAT-based resource sharing. Use this for first-pass vector/Zvk/Keccak area rows; the default `share` pass was CPU-bound in `karu_varith`/`karu_vlsu` and produced no completed vector rows in a 13-minute local attempt. |
| `KARU_LTP` | unset | When set (`KARU_LTP=1`), emit `reports/depth.rpt` — per-module library-independent combinational logic depth (`ltp -noff`) on the **pre-map** generic-gate netlist (after `synth`, before `dfflibmap`; on the mapped netlist ltp cannot see the liberty flops and floods the report with false loops). The `karu64` top and `karu_mem` are excluded because bit-level reconvergence through their submodule instances trips ltp's topological sort; override the skip list with `KARU_LTP_SKIP="mod ..."`. One `Longest topological path in <mod> (length=N)` line per module; N is un-mapped 2-input gate stages (abc shortens them), so use it as a relative/upper-bound depth like `syn_depth.sh`. Cheap: ~15 s. |
| `KARU_ABC_FULL` / `KARU_ABC_FAST` | unset | Which ABC script maps the netlist. Default: the **full** Yosys liberty script (`&nf` map + `buffer; upsize; dnsize`) whenever STA runs, the custom `abc_fast.script` (no buffering/sizing) for area-only runs (`KARU_NO_STA=1`, i.e. `area-matrix`/`sweep`, keeping their kGE comparable with the published rows). `KARU_ABC_FULL=1` / `KARU_ABC_FAST=1` force either. The fast netlist's STA slack is not meaningful (thousands of ns on one unbuffered gate); the full script is not slower on this design (~4.5 min vs ~6 min, scalar core). |

Shortcut:

```
make synth CLK=3000          # retarget to 3000 ps (~333 MHz)
KARU_DEFINES="KARU_MUL_CYCLES=1 KARU_DIV_CYCLES=1" make synth
```

## ISA-extension sweep (`make sweep`)

`./syn_sweep.sh` (= `make sweep`) synthesises karu64 across the four
ISA-extension configurations and tabulates **rough gate count (kGE)** and
**combinational logic depth** for each:

| config | gating define | ISA |
|---|---|---|
| `imac`    | `KARU_NO_F` | RV64IMAC+B (base scalar bitmanip enabled by default) |
| `imafc`   | `KARU_NO_D` | RV64IMAFC+B (single-precision FP) |
| `imafdc`  | `KARU_NO_V` | RV64IMAFDC+B (double-precision FP) |
| `imafdcv` | *(none)*    | RV64IMAFDCV+B (full; vector) |

Each runs the normal yosys flow (area + `ltp` depth, STA skipped) under a
per-config `timeout`, writing `_build/syn_out/sweep_<stamp>/<cfg>/` plus a combined
`summary.csv` and a printed table. Knobs: `CONFIGS="imac imafc"` for a subset,
`BASE_DEFINES=""` for the all-combinational (deepest/largest) variant,
`PER_TIMEOUT=<sec>`.

Two things make this work cleanly:
- `hierarchy -top karu64` **prunes the gated-out modules before synth**, so a
  smaller config never even feeds the dropped units to yosys. In particular
  `imac`/`imafc`/`imafdc` skip `karu_varith` entirely — the module that
  otherwise stalls yosys `proc` on the full core. So the smaller configs
  complete in minutes even though the full
  `imafdcv` typically hits the timeout and is reported as `timeout`.
- **Gate count = total chip area / NAND2_X1 (0.798 µm²) = kGE**, the standard
  rough-gate proxy; per-module breakdown is in each `<cfg>/reports/area.rpt`.
- **Depth = deepest *loop-free* leaf module** from `ltp -noff` (the sweep
  filters out the control/cache modules ltp can't sort; see the `KARU_LTP`
  caveat above). This isolates the combinational depth each extension adds.

## Area/feature matrix (`make area-matrix`)

`./syn_area_matrix.sh` (= `make area-matrix`) is the current cloud handoff
runner for NAND2 gate-equivalent scoping. It runs the same Nangate45/Yosys
flow with OpenSTA disabled (`KARU_NO_STA=1`) and appends a CSV row for each
config.

It covers:
- RV64IMAC+B, RV64IMAFC+B, and RV64GC+B feature deltas.
- Optional scalar-B, S-mode/Sv39, HPM, and scalar no-L1 scoping rows.
- Integer M, F-mul, D-mul, and FMA serialization knobs.
- RV64GCV baseline and vector multiplier knobs.
- Standard Zvk vector-crypto leaf rows, umbrella Zvk, and Zvknhk Keccak opt-ins.

See [`AREA_MATRIX.md`](AREA_MATRIX.md) for the recommended scalar and vector
batches, CSV column definitions, and delta recipes. Typical selected run:

```
make area-matrix CONFIGS="imac_m4d64 imafc_m4d64 rv64gc_m4d64" PER_TIMEOUT=1800
make area-matrix CONFIGS="imac_m4d64 imac_nob_m4d64 imac_min_m4d64 imacb_min_m4d64 imac_core_m4d64 imacb_core_m4d64" PER_TIMEOUT=1800
make area-matrix KARU_NOSHARE=1 JOBS=2 CONFIGS="rv64gcv_default rv64gcv_vmul1 rv64gcv_vmul4 rv64gcv_vmul64 rv64gcv_zvkb rv64gcv_zvkned rv64gcv_zvknha rv64gcv_zvknhb rv64gcv_zvksed rv64gcv_zvksh rv64gcv_zvkg rv64gcv_zvk rv64gcv_keccak rv64gcv_zvk_keccak" PER_TIMEOUT=7200
```

## Outputs

```
_build/syn_out/karu64_YYYYMMDD_HHMMSS/
├── generated/
│   ├── karu64.sdc                  # SDC actually used by sta
│   ├── karu64.abc.sdc              # driving cell / load for abc
│   ├── karu64.pre_map.v            # pre tech-map (generic gates)
│   ├── karu64_netlist.v            # post-map netlist (nangate45 cells)
│   └── karu64_netlist.sta.v        # same netlist, sta-friendly
├── reports/
│   ├── area.rpt                    # yosys stat -liberty
│   └── timing/
│       ├── overall.rpt             # design WNS / 100 worst paths
│       ├── reg2reg.rpt + .csv.rpt
│       ├── reg2out.rpt + .csv.rpt
│       ├── in2reg.rpt + .csv.rpt
│       └── in2out.rpt + .csv.rpt
└── log/
    ├── syn.log
    └── sta.log
```

The summary the script prints at the end pulls the total chip area
from `area.rpt` and the worst reg-to-reg slack from
`reg2reg.csv.rpt`.

## Results (NanGate45 typical, hierarchical synth, `abc -fast` script)

### Ibex same-flow baseline

`make ibex` converts the local `../../../ibex` checkout with `sv2v`, then runs
it through the same Nangate45 liberty, Yosys version, hierarchical
`synth -noabc`, `dfflibmap`, `abc_fast.script`, and NAND2_X1 kGE conversion
used here. Official Ibex config names follow `../../../ibex/ibex_configs.yaml`;
`small-latch` is the local `small` config with `RegFileLatch`.

NAND2_X1 = 0.798 um2.

| Ibex config | Area (um2) | kGE |
|---|---:|---:|
| `small` | 32658.150 | 40.92 |
| `small-latch` | 28578.774 | 35.81 |
| `maxperf` | 39032.042 | 48.91 |
| `maxperf-pmp-bmfull` | 72914.058 | 91.37 |

Latest local run directories:

```
_build/syn_out/ibex_small_20260617_173946/
_build/syn_out/ibex_small-latch_20260617_173528/
_build/syn_out/ibex_maxperf_20260617_173607/
_build/syn_out/ibex_maxperf-pmp-bmfull_20260617_173629/
```

Direct flow comparison with Ibex is now possible. The current full `karu64`
top includes RV64 state, `karu_mem`, and two Sv39 walkers. A smoke RV64IMAC+B run
(`KARU_DEFINES="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F"`) measured:

| karu64 scope arithmetic | kGE |
|---|---:|
| current top | 639.29 |
| minus `karu_mem` | 262.10 |
| minus `karu_mem` and 2x `karu_sv39` | 193.80 |

Those subtraction columns are useful for orientation. For processor-only
numbers, use the matrix rows with `KARU_NO_MEM`, for example
`imac_core_m4d64` or `imacb_core_m4d64`, which synthesize the no-L1 scalar
profile directly. Local no-L1 scalar rows measured:

| karu64 matrix row | kGE |
|---|---:|
| `imac_core_m4d64` | 104.53 |
| `imacb_core_m4d64` | 121.13 |

> **Scope note (2026-06-17):** the historical numbers below are the scalar-core
> area sweep. The current area-matrix flow now also completes full RV64GCV
> area-only rows on the 86 GB cloud box with `KARU_NOSHARE=1 JOBS=2`; see
> `AREA_MATRIX.md` for the completed vector/Zvk/Keccak checkpoint. Standard Zvk
> leaf, umbrella, and Zvk+Keccak rows now complete after the lane-side ZVKB
> byte/bit reversal rewrite in `rtl/karu_vlane.v`.

### Area sweep across multiplier configurations

NAND2_X1 = 0.798 µm², so 1 kGE ≈ 798 µm². The flow is hierarchical (each
module mapped by abc independently), so per-module numbers are accurate
to within a few % of a flat run.

| Config | `KARU_M_MUL_CYCLES` | `KARU_M_DIV_CYCLES` | `KARU_F_MUL_CYCLES` | `KARU_D_MUL_CYCLES` | Total |
|---|---:|---:|---:|---:|---:|
| all combinational (no `KARU_DEFINES`) | 1 | 1 | 1 | 1 | **374.0 kGE** |
| **small core (default)** — `KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64` | 4 | 64 | 4 | 53 | **254.9 kGE** (−32%) |
| smallest reasonable — `KARU_MUL_CYCLES=16 KARU_DIV_CYCLES=64` | 16 | 64 | 24 | 53 | **244.5 kGE** (−35%) |

The default is the small-core sweet spot. Going past `MUL=4` only
recovers another 10 kGE for a much longer multiply latency (16 cycles
for an integer mul instead of 4). The all-combinational variant carries
99 kGE in the integer multiplier alone — a single-cycle 64×64 array —
and the D-precision combinational multiplier costs another 38 kGE.

### Per-module breakdown for the default config

| Module | kGE | % of total |
|---|---:|---:|
| karu_fdiv_d (D divider, bit-serial)              | 71.3 | 28% |
| karu_fregfile (3R/1W f-regs, 32×64)              | 30.5 | 12% |
| karu_regfile (2R/1W x-regs, 32×64)               | 25.9 | 10% |
| **karu_m (M extension, 4-cycle mul + bit-serial div)** | **20.5** | **8%** |
| karu_fdiv (F divider, bit-serial)                | 16.4 | 6% |
| karu_lsu (AXI4 + atomics + misalign)             | 11.3 | 4% |
| karu_fadd_d, karu_fpu, karu_csr, karu_fsqrt_d ...| ~30 | 12% |
| karu_alu, karu_ifu, karu64 wrap                  | ~14 | 5% |
| **karu_fmul (F-mul, 4-cycle)**                   | **4.0** | **2%** |
| **karu_fmul_d (D-mul, bit-serial)**              | **3.7** | **1%** |
| rest (small FP units, RVC, decoder)              | ~27 | 11% |

The two big remaining contributors (`karu_fdiv_d` at 71 kGE and the
scalar/FP register files at 56 kGE combined) are not affected by the
multiplier flags — they're already iterative (the D divider is bit-serial by
construction) or are flop-based register files where the cell count is data,
not logic. The vector VRF and other large inferred arrays are isolated behind
memory leaves for ASIC macro substitution; compiled scalar/FP regfiles are
still outside this flow.

### Timing observations (re-measured 2026-09-11, Yosys 0.65+73 / OpenSTA 2.4.0)

Same RV64GC (`KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_V`) RTL, two ABC
scripts, 4 ns (250 MHz) target:

| abc script | area (µm²) | WNS reg2reg | WNS in2reg | worst reg2reg path |
|---|---:|---:|---:|---|
| `abc_fast.script` (old default) | 688,328 | −2174 ns | −13.3 ns | one unbuffered `INV_X1` in the L1 data array with 2008 ns on that single gate |
| full Yosys script (new default for STA runs) | 618,460 | **−2.71 ns** | +0.98 ns | 123 stages, `fpu/u_fr_f2i_d` → `fpu/u_fr_i2f_d`, 6.67 ns |

The fast-script slack is an artefact: without `buffer; upsize; dnsize`
every high-fanout net (the cache-array enable here; the integer regfile
read mux in older runs) hangs off one X1 gate and OpenSTA extrapolates
thousands of ns for it. All 100 reported worst paths share that one gate.
The custom script exists because `map` followed by `buffer` aborts with
`node N has no fanout` on `karu_lsu`; Yosys' default `&nf`-based script
does not trip that abort, and on this Yosys it is not slower.

With a buffered netlist the numbers are meaningful. The RV64GC core's
critical path is the Zfa `fround.d`/`froundnx.d` compose: `karu_fpu` chains
a dedicated `karu_f2i_d` into a `karu_i2f_d` in one cycle (`u_fr_f2i_d`,
`u_fr_i2f_d`), 6.67 ns in NanGate45 typical, i.e. ~150 MHz. 63 of the 100
worst reg→reg endpoints are in `karu_fpu`, the other 34 in the integer
register file. Inputs and outputs meet the generic 30 %/70 % IO budget.
Registering the `fround` compose would remove that path at the cost of one
cycle of `fround` latency; not done (irrelevant at the 75 MHz FPGA clock).

The L1 data array is a 348 kGE flop sea in this flow (it would be an SRAM
macro in silicon), so the processor-only row is the one to quote. Same
knobs plus `KARU_NO_MEM`, full ABC script, `KARU_LTP=1`:

| row | area | WNS reg2reg | WNS in2reg | WNS reg2out | worst path | wall |
|---|---:|---:|---:|---:|---|---:|
| RV64GC core, no L1 (`KARU_NO_V KARU_NO_MEM`) | 317,577 µm² = **398 kGE** | −2.73 ns | +0.96 ns | +2.30 ns | same `fround.d` compose, 6.69 ns | 3.7 min yosys + 13 min STA |

Biggest blocks in that row: `karu_csr` 70 kGE, `karu_fregfile` 31, `karu_ffma_d`
31, `karu_regfile` 26, `karu_sv39` 21 (kGE, NAND2_X1 = 0.798 µm²).

Pre-map logic depth (`KARU_LTP=1`, un-mapped 2-input gate stages, deepest
leaves; the same run): `karu_i2f_d` 271, `karu_i2f` 269, `karu_ffma` 258,
`karu_fmul_d` 239, `karu_bitmanip` 226, `karu_ffma_d` 222, `karu_fadd_d` 202,
`karu_fdiv_d` 196, `karu_fsqrt_d` 175, `karu_fmul` 147, `karu_fadd` 110,
`karu_fdiv` 102. `karu_bitmanip` is deep because `f_cpop`/`f_clz`/`f_ctz` are
written as 64-iteration sequential loops (a 64-deep ripple of 8-bit adds and
64-deep priority chains); abc restructures most of it, and it is not on the
STA critical path, but a tree-shaped popcount/clz would make it cheaper.

## Constraints

The default SDC (`sdc/karu64.sdc.in`) is intentionally generic:

- `clk` is the only clock; `rst` is treated as ideal (`set_false_path`).
- Every other input gets `set_input_delay  KARU_IN_PCT%·period`.
- Every output gets `set_output_delay (100-KARU_OUT_PCT)%·period`.
- `BUF_X2` drives inputs, outputs see a 10 fF load.

If you want a realistic AXI budget (e.g. tight read-data path,
loose write-strobe), edit `sdc/karu64.sdc.in` and add explicit
`set_input_delay` / `set_output_delay` entries before the catch-all
`[all_inputs]` line. Per-port overrides take precedence in OpenSTA.

## Files

```
flow/syn/
├── AREA_MATRIX.md          # cloud handoff for feature/area matrix runs
├── HANDOVER.md             # 2026-09-11 flow check-up: fixes, results, what to run on the big box
├── Makefile                # synth / ibex / matrix / sweep / clean wrappers
├── README.md               # this file
├── syn_setup.sh            # tracked shared env-var defaults
├── syn_setup.example.sh    # env-var template
├── syn_yosys.sh            # main driver (yosys then sta)
├── syn_area_matrix.sh      # area-only Karu feature/knob matrix
├── syn_sweep.sh            # legacy ISA sweep with optional depth
├── syn_depth.sh            # library-independent depth helper
├── ibex_yosys.sh           # optional same-flow Ibex baseline driver
├── sdc/
│   ├── karu64.sdc.in       # SDC template (substituted by syn_yosys.sh)
│   └── karu64.abc.sdc      # minimal SDC consumed by yosys' abc pass
└── tcl/
    ├── yosys_run_synth.tcl # synth + tech-map + abc + writeback
    ├── ibex_run_synth.tcl  # Ibex baseline synth using karu64 flags
    ├── nangate_latch_map.v # latch techmap for Ibex latch/clock-gate cells
    └── sta_run_reports.tcl # timing reports per path group
```
