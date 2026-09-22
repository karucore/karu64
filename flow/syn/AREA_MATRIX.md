# Karu area and timing estimates

This file records the current release measurements for the `karu64` processor
top. Older checkpoints and superseded tool runs are intentionally omitted;
the retained output manifests under `_build/syn_out` bind each result to its
exact RTL, scripts, tools and Liberty input. These September 15 measurements
predate the Genus declaration cleanup; September 22 board results are in the
[release diagnostics](../../doc/release-diagnostics-2026-09-14.md).

These are comparative NanGate45 standard-cell estimates. They are not an ASIC
macro-area estimate, a signoff timing result or an FPGA utilization report.
Memories are mapped to cells by this flow; use the maintained
[`flow/asic` inventory](../asic/README.md) when planning SRAM replacement.

## Release setup

- Yosys 0.69+24 (`d0e71cfb7`).
- OpenSTA 3.1.0, resolved from `PATH` and fingerprinted in the run manifest.
- NanGate45 typical Liberty; `NAND2_X1 = 0.798 um2`.
- Hierarchical `synth -noshare`, no flattening.
- Generic timing constraints with 30% input and 70% output budgets.
- Full timing-oriented ABC mapping for the 5 ns run.
- Fast ABC mapping with STA disabled for area comparison rows.

The release refresh measures the two affected crypto leaves, their common
baseline and umbrella configurations, and the exact shipping composition. The
minimal RVA23S64 row does not enable vector crypto, so the `.vs` correction
cannot change its mapped logic.

## Current results — 2026-09-15

All six corrected-source rows completed successfully. The before/after input
manifests are byte-identical for every row; the summary CSV SHA-256 is
`03516f4e84df287f79e03f5a98a175f8ecb03b5a47c9d32580344836c6ea0c8c`.

| Configuration | Top kGE | Top − memory kGE | Memory kGE | Varith kGE | Vcrypto kGE | Keccak kGE |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rv64gcv_default` | 3667.90 | 3273.16 | 394.74 | 2180.45 | 0.00 | 0.00 |
| `rv64gcv_zvkned` | 3706.47 | 3311.74 | 394.74 | 2218.05 | 3.42 | 0.00 |
| `rv64gcv_zvksed` | 3683.68 | 3288.95 | 394.74 | 2192.98 | 3.47 | 0.00 |
| `rv64gcv_zvk` | 3806.98 | 3412.24 | 394.74 | 2318.30 | 10.44 | 0.00 |
| `rv64gcv_zvk_keccak` | 3894.17 | 3499.44 | 394.74 | 2406.02 | 10.44 | 31.20 |
| `rva23s64_ship` | 4390.60 | 3995.86 | 394.74 | 2543.86 | 10.44 | 31.20 |

Area output:
`_build/syn_out/area_matrix_zvk_vs_fsm_final_20260914/summary.csv`.

Against the common RV64GCV+Zvbb baseline, the isolated Zvkned and Zvksed rows
add 38.57 and 15.78 kGE respectively. All standard Zvk leaves together add
139.08 kGE. Adding the Keccak instruction to that row adds 87.19 kGE at the
top; this includes 31.20 kGE in the Keccak hierarchy and its wrapper/state
integration in `karu_varith`. The exact shipping composition is larger than
the feature-comparison rows because it also selects the profile, I-cache and
shipping pipeline/counter options.

The exact shipping timing row uses this composition:

```text
KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK
KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64
KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64
KARU_V_LANE_PIPE KARU_V_CWB_STAGE
KARU_SMCNTRPMF KARU_SSCOFPMF
```

| Target | Register-to-register WNS | TNS | Critical path | Coverage/electrical |
| --- | ---: | ---: | --- | --- |
| 5 ns / 200 MHz | -0.2043 ns | -5.13 ns | vector widening/estimate path (`karu_varith` through `u_widen_b` and lane `u_est`) | input-to-register +1.5412 ns; register-to-output +2.6833 ns; no input-to-output paths; electrical-limit violations remain |

Timing output:
`_build/syn_out/timing_rva23s64_ship_200_zvk_vs_fsm_final_20260914/`.
The full-ABC timing netlist is independent of the fast area netlists; do not
quote OpenSTA timing from an area row.

A bounded retry with a tighter 2.5 ns internal ABC budget produced the same
-0.2043 ns WNS and -5.13 ns TNS, at slightly higher mapped area, so the regular
map above is retained. The estimate corresponds to about 192.1 MHz at zero
register-to-register slack. The longest path begins at a `karu_varith` register,
passes through a high-fanout buffer chain, `u_widen_b` and the lane estimate
logic, and returns to `karu_varith`; it is not in the corrected AES/SM4 `.vs`
source-address path.

## Reproduce

Run the exact shipping 200 MHz estimate from the repository root:

```sh
PATH=/path/to/opensta/bin:$PATH \
KARU_LIB=/path/to/NangateOpenCellLibrary_typical.lib \
KARU_DEFINES='KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64 KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64 KARU_V_LANE_PIPE KARU_V_CWB_STAGE KARU_SMCNTRPMF KARU_SSCOFPMF' \
KARU_CLK_PS=5000 KARU_ABC_UPRATE_PS=2000 \
KARU_ABC_FAST=0 KARU_ABC_FULL=1 KARU_NO_STA=0 \
KARU_FLATTEN=0 KARU_NOSHARE=1 KARU_IN_PCT=30 KARU_OUT_PCT=70 \
KARU_OUT_DIR=_build/syn_out/timing_rva23s64_ship_200 \
  flow/syn/syn_yosys.sh
```

Run the affected area rows:

```sh
PATH=/path/to/opensta/bin:$PATH \
KARU_LIB=/path/to/NangateOpenCellLibrary_typical.lib \
KARU_CLK_PS=4000 KARU_ABC_UPRATE_PS=2000 \
KARU_ABC_FAST=1 KARU_ABC_FULL=0 KARU_NO_STA=1 \
KARU_FLATTEN=0 KARU_NOSHARE=1 KARU_IN_PCT=30 KARU_OUT_PCT=70 \
JOBS=1 PER_TIMEOUT=21600 \
CONFIGS='rv64gcv_default rv64gcv_zvkned rv64gcv_zvksed rv64gcv_zvk rv64gcv_zvk_keccak rva23s64_ship' \
  flow/syn/syn_area_matrix.sh
```

Use `CONFIGS` with any names from `syn_area_matrix.sh` for a broader design
space sweep. Compare feature deltas only among rows produced by the same run:
shared decode and execution logic means individual extension deltas are not
additive.

## Interpretation and checks

`summary.csv` reports top area and selected inclusive hierarchy buckets. The
`Top − memory` column subtracts the mapped `karu_mem` hierarchy for orientation;
it is not a separately synthesized core. FPGA LUT, register, BRAM and DSP use
comes only from the Vivado reports.

For timing, inspect all of the following rather than WNS alone:

- register-to-register, input-to-register, register-to-output and
  input-to-output path groups;
- constrained/unconstrained endpoint coverage;
- maximum slew, capacitance and fanout checks; and
- the longest-path report to identify the actual RTL cone.

Run `make syn-runtime-div-audit-rva23s64` after arithmetic or indexing changes.
The audit rejects live variable `/` and `%` operators that could infer an
unintended divider; constant and elaboration-time arithmetic are allowed.

See [README.md](README.md) for flow controls and output-file details.
