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
- [OpenSTA](https://github.com/parallaxsw/OpenSTA) (tested with 3.1)
- `sv2v` for the optional `make ibex` comparison target
- NanGate45 typical-corner liberty file at
  `../../src/flow/NangateOpenCellLibrary_typical.lib` (relative to this
  directory). Override via `$KARU_LIB`.

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
| `KARU_DEFINES` | `KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64` | Space-separated `-D` flags passed to `read_verilog`. Default is the "small core" config; see results below. Set to empty (`KARU_DEFINES=""`) to pass no explicit defines and let the RTL headers resolve their non-SIM defaults. Use `KARU_MUL_CYCLES=1 KARU_DIV_CYCLES=1` for the all-combinational variant. For the vector core, add e.g. `KARU_V_PERM_LANES=2` to keep the `vrgather` crossbar ABC-mappable. **Feature gating** also goes here: `KARU_NO_F` / `KARU_NO_D` / `KARU_NO_V` (cascade `V⊃D⊃F`) drop FP/vector units; `KARU_NO_B` drops scalar Zba/Zbb/Zbs; `KARU_NO_S` drops S-mode/Sv39 and prunes both MMU walkers; `KARU_NO_HPM` drops `mhpmcounter3..31`/`mhpmevent3..31`; `KARU_NO_MEM` drops the scalar L1/cache wrapper in non-vector builds. `hierarchy -top` then prunes disabled modules/state. |
| `KARU_NOSHARE` | unset | When set, passes `-noshare` to Yosys `synth`, skipping SAT-based resource sharing. Use this for first-pass vector/Zvk/Keccak area rows; the default `share` pass was CPU-bound in `karu_varith`/`karu_vlsu` and produced no completed vector rows in a 13-minute local attempt. |
| `KARU_LTP` | unset | When set (`KARU_LTP=1`), emit `reports/depth.rpt` — per-module library-independent combinational logic depth (`ltp -noff`) on the **un-flattened** mapped netlist (one `Longest topological path in <mod> (length=N)` line per module). Cheap and memory-light. **Caveat:** the stateful control modules (`karu_m`/`karu_csr`/`karu_lsu`/`karu_mem`/`karu_regfile`/IFU/top) trip ltp's topological sort on bit-level reconvergence (`Detected loop ...`) and report a bogus length — ignore those; the FP/vector compute leaves (`karu_fdiv`, `karu_fsqrt`, `karu_*_d`, `karu_varith`) are clean. `make sweep` already filters the looped modules out. |

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
- Standard Zvk vector-crypto leaf rows, umbrella Zvk, and custom Keccak opt-ins.

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
register files at 56 kGE combined) are not affected by the multiplier
flags — they're already iterative (the D divider is bit-serial by
construction) or are flop-based register files where the cell count is
data, not logic. Switching to an SRAM-backed regfile would shrink that
last 56 kGE by ~3× but is not in scope for this flow.

### Timing observations

`WNS (reg2reg)` is reported around `−249 ns` in every config above. **This
number is not real** — the fast abc script we use (`strash; dretime;
retime; map`) skips the cell-resizing (`buffer; upsize; dnsize`) passes
because those crashed with `node has no fanout` errors on the
DFFE-heavy LSU / FPU modules. Without sizing, OpenSTA scores the
high-fanout inverter at the integer regfile read-mux output with
~125 ns of delay per gate, dominating the slack.

The **structural critical path** is real, and identical across all
multiplier configs: PC reg → IFU prefetch → RVC expand → decoder →
regfile read → FU operand input → first FU state register, about
~30 gates in the front-end plus ~84 gates of FU operand-stage logic
ending in `karu_fdiv_d`'s first state register. This is a single
"issue cycle" combinational chain. The realistic input-side critical
path (`in2reg`) is `dmem_bvalid → 18 gates of LSU atomic/SC-aware
writeback logic → LSU state reg`, with `−0.73 ns` slack at the 4 ns
target — the only real timing violator the flow surfaces.

If you need realistic absolute Fmax numbers (rather than relative
comparisons), set `KARU_ABC_FULL=1` and `KARU_CLK_PS=10000` (10 ns
target). The full-quality abc script takes 30–60 min hierarchically vs.
~3 min for the fast script.

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
