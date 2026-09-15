# Open-source synthesis flow

This directory maps `karu64` to the NanGate45 typical-corner library with
Yosys and reports timing with OpenSTA. It is intended for reproducible relative
area comparisons and early critical-path discovery, not tape-out signoff or an
absolute silicon Fmax claim.

Current measured results belong in [AREA_MATRIX.md](AREA_MATRIX.md). Do not
copy an older run's numbers into a new RTL checkpoint; each run fingerprints
the tools, Liberty, scripts and complete RTL input set.

## Requirements

- Yosys; the current release measurements use 0.69+24 (`d0e71cfb7`).
- OpenSTA 3.1.0 for the current release measurements. The exact executable
  path and hash are captured automatically in each run manifest.
- `NangateOpenCellLibrary_typical.lib`. The flow searches the standard sibling
  `src/flow` locations; override with `KARU_LIB`.
- `sv2v` only for the optional Ibex comparison target.

The flow resolves `yosys`, `yosys-abc` and `sta` from `PATH` and records paths,
versions and binary hashes in `log/manifest.txt`. Put the intended tools first
in `PATH` and verify them before starting a long run.

## Quick start

From the repository root:

```sh
# Small scalar sanity row.
KARU_DEFINES='KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_V KARU_NO_MEM' \
  flow/syn/syn_yosys.sh

# Exact shipping profile at a 5 ns (200 MHz) mapped target.
KARU_DEFINES='KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64 KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64 KARU_V_LANE_PIPE KARU_V_CWB_STAGE KARU_SMCNTRPMF KARU_SSCOFPMF' \
KARU_CLK_PS=5000 KARU_ABC_UPRATE_PS=2000 \
KARU_ABC_FAST=0 KARU_ABC_FULL=1 KARU_NO_STA=0 \
KARU_FLATTEN=0 KARU_NOSHARE=1 KARU_IN_PCT=30 KARU_OUT_PCT=70 \
KARU_OUT_DIR=_build/syn_out/timing_rva23s64_ship_200 \
  flow/syn/syn_yosys.sh

# Selected fast area rows.
KARU_NOSHARE=1 JOBS=1 PER_TIMEOUT=21600 \
CONFIGS='rv64gcv_default rv64gcv_zvkned rv64gcv_zvksed rv64gcv_zvk rv64gcv_zvk_keccak rva23s64_ship' \
  flow/syn/syn_area_matrix.sh
```

Vector/Zvk rows are memory-intensive. Run one row at a time unless the host has
enough physical memory for multiple retained Yosys processes and ABC children.
Use a cgroup memory limit for unattended work; `ulimit -v` limits address space,
not resident memory.

## Main controls

| Variable | Default | Meaning |
| --- | --- | --- |
| `KARU_LIB` | searched NanGate45 path | Liberty file |
| `KARU_CLK_PS` | `4000` | clock period in ps |
| `KARU_ABC_UPRATE_PS` | `2000` | extra ABC timing pressure (`period - uprate`) |
| `KARU_IN_PCT` / `KARU_OUT_PCT` | `30` / `70` | generic input/output timing budgets |
| `KARU_OUT_DIR` | timestamped `_build/syn_out` path | output directory |
| `KARU_DEFINES` | balanced arithmetic defaults | space-separated RTL defines; an explicit empty value selects header defaults |
| `KARU_NOSHARE` | unset | pass `-noshare` to Yosys; recommended for large vector comparisons |
| `KARU_FLATTEN` | unset | flatten before mapping |
| `KARU_LTP` | unset | emit pre-map per-module logic-depth report |
| `KARU_NO_STA` | inferred by caller | skip OpenSTA for area-only rows |
| `KARU_ABC_FAST` / `KARU_ABC_FULL` | area/timing dependent | select area-only or timing-oriented ABC script |

Timing runs use Yosys' full liberty script with buffering and sizing. Area-only
matrix rows use `abc_fast.script` so feature deltas remain comparable. OpenSTA
slack from a fast/unbuffered netlist is not meaningful.

`KARU_LTP=1` runs `ltp -noff` on the generic pre-map netlist. It is useful for
relative combinational-depth inspection, not a substitute for mapped timing.
The default skip list excludes hierarchy whose reconvergence prevents a valid
topological sort; override with `KARU_LTP_SKIP` only when needed.

## Runtime division/modulo audit

Variable `/` and `%` expressions can infer large combinational dividers. The
maintained audit preprocesses/elaborates the configured design, reports live
operators and rejects any variable divisor. Constant power-of-two operations
and generate-time parameter arithmetic are allowed.

```sh
make syn-runtime-div-audit
make syn-runtime-div-audit-rva23s64
```

The first target checks the mandatory RVA23S64 composition; the second checks
the exact shipping composition with I-cache, Zvk/Keccak, lane/writeback
pipelines and PMU options. Run both after arithmetic, address, lane-index or
parameterization changes. Serial multiply/divide configuration does not excuse
a live RTL `/` or `%` elsewhere. Results use the stable
`_build/syn_out/div_audit_rva23s64_{min,ship}` paths.

## Area matrix

`syn_area_matrix.sh` accepts named rows from its built-in table, a custom
`MATRIX_FILE`, or inline `MATRIX_ROWS`. Important profile/vector rows include:

- `rv64gcv_no_zvbb`, `rv64gcv_zvkb`, `rv64gcv_default`;
- `rv64gcv_vmul1`, `rv64gcv_vmul4`, `rv64gcv_vmul64`;
- `rv64gcv_zvkned`, `rv64gcv_zvknha`, `rv64gcv_zvknhb`,
  `rv64gcv_zvksed`, `rv64gcv_zvksh`, `rv64gcv_zvkg`;
- `rv64gcv_zvk`, `rv64gcv_keccak`, `rv64gcv_zvk_keccak`; and
- `rva23s64_min`, `rva23s64_ship`.

The shipping row enables RVA23S64, I-cache, all implemented Zvk leaves,
Keccak, integer multiply/divide 4/64, vector multiply/divide 16/64, lane/CWB
staging, Smcntrpmf and Sscofpmf.

`summary.csv` reports top area and hierarchy buckets. `kGE` uses
`NAND2_X1 = 0.798 um2` unless `NAND2_UM2` is overridden. The subtraction
columns remove the inclusive `karu_mem` and aggregate `karu_sv39` buckets for
orientation only; use a `KARU_NO_MEM` row when a directly synthesized
processor-only scalar number is required.

Feature deltas should compare rows from the same matrix invocation and
toolchain. Zvk leaf deltas are not additive because the umbrella shares decode,
sequencing and `karu_vcrypto` plumbing.

## Outputs and integrity checks

Each run writes beneath `_build/syn_out`:

- `summary.csv`, row console logs and the exact `rows.txt`;
- `log/manifest.txt` and before/after input hashes;
- `reports/area.rpt` and optional `reports/depth.rpt`;
- OpenSTA SDC, path-group, coverage, setup and electrical reports for timing
  runs; and
- mapped/pre-map netlists, which may be compressed for retention.

A row fails if input fingerprints change while it is running. With `JOBS>1`,
`summary.csv` is completion ordered; join by the `config` column.

## Constraints

The generic SDC has one `clk`; reset is false-pathed. Other inputs receive the
configured input delay and outputs the configured output delay. A library
buffer drives inputs and outputs see the configured load. OpenSTA reports
register-to-register, input-to-register, register-to-output and
input-to-output groups separately. Always inspect `check_setup`, unconstrained
endpoint coverage and slew/capacitance/fanout reports as well as WNS/TNS.

## Files

- `syn_setup.sh`: shared defaults and library discovery.
- `syn_yosys.sh`, `tcl/yosys_run_synth.tcl`: synthesis/mapping driver.
- `tcl/abc_fast.script`: area-only ABC mapping.
- `tcl/sta_run_reports.tcl`: OpenSTA reports, compatible with supported option
  spelling variants.
- `syn_area_matrix.sh`: named feature/profile rows.
- top-level `syn-runtime-div-audit{,-rva23s64}` targets plus
  `syn_yosys.sh`: live variable division/modulo check.
- `sdc/karu64.sdc.in`: generic timing constraints.
