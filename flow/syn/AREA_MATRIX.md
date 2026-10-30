# Karu area and timing estimates

The complete debug-extension comparison is dated 2026-10-29. All twelve
area/timing rows were fresh mappings with identical before/after input hashes
at that checkpoint; no mapped-design reuse was used.
Manifests under `_build/syn_out` bind each result to RTL, scripts, tools and
Liberty. Earlier comparisons below are separate historical checkpoints.

The October 30 RTL registers the SBA pause to remove the reset-to-trigger
feedthrough introduced by fetch-fault pause qualification. The freshly mapped
full two-trigger row has register WNS **−0.3978 ns**, TNS **−17.40 ns** and
input-to-register slack **+0.2328 ns** (previously −0.1739 ns). Register-to-output
and input-to-output slack are +0.3106/+0.5794 ns. IO groups pass; 200 MHz
still misses on the IFU/decode-to-double-FMA register path. Only this timing
row was rerun; the area table and other timing values below retain the
October 29 source. See the
[pause follow-up](../../dbg/MEASUREMENTS.md#registered-sba-pause--2026-10-30)
for the current result and its scope. The accepted FPGA bundle is unchanged.

These are comparative NanGate45 standard-cell estimates, with memories mapped
to cells. They are not ASIC macro-area or signoff timing results. Use the
[ASIC inventory](../asic/README.md) when planning memory-macro replacement.

## Debug extensions — 2026-10-29

These rows use the same shipping processor and conventional-JTAG debug top.
Base debug has `KARU_DBG`; the full rows add autoexec, SBA and two or four
debugger-owned address triggers.

| Configuration | kGE | Increment kGE | Increment % |
| --- | ---: | ---: | ---: |
| Base debug | 4,406.7233 | 0.0000 | 0.0000 |
| Autoexec | 4,406.8260 | 0.1027 | 0.0023 |
| Two triggers | 4,412.8477 | 6.1243 | 0.1390 |
| SBA | 4,415.0943 | 8.3710 | 0.1900 |
| Full, two triggers | 4,421.3380 | 14.6147 | 0.3316 |
| Full, four triggers | 4,425.0677 | 18.3443 | 0.4163 |

All six timing rows are complete and none closes at 200 MHz. Base debug has
register-to-register WNS −0.3991 ns and TNS −16.64 ns; the selected full
two-trigger row has −0.3978 ns and −20.38 ns. The full row's longest path
remains IFU buffered address through compressed decode and FP operands to
double FMA, with 5.36 ns arrival. The registered VLSU watch address does not
set that critical path.

The full row also has **−0.1739 ns input-to-register slack**, from timed
synchronous `rst` through DM/SBA and trigger/core control to the IFU. The
specified input delay is 1.50 ns; arrival is 5.14 ns. Base debug's input group
passes at +0.4428 ns. Full-debug output groups pass (+0.3106 ns register-to-
output, +0.3510 ns input-to-output), so these results must not be summarized
as all IO paths passing.

The optional four-trigger row has WNS −0.9432 ns, TNS −96.76 ns and reset
input slack −0.2210 ns. Its longest path is scalar FP distribution through
widening/FP-estimate logic to `ksbuf`, not a trigger comparator. Mapping
variation in unchanged logic prevents attributing that difference solely to
the slot count.

See [the complete extension matrix and reproduction commands](../../dbg/MEASUREMENTS.md#extension-measurements--2026-10-29)
for all path groups, source/report evidence and the separate FPGA acceptance.
The standard full-debug/two-trigger FPGA image also completed on 2026-10-29:
75 MHz routed setup/hold +0.010/+0.011 ns overall and +0.048/+0.011 ns in the
CPU, with 16/16 bus-skew constraints and zero bitstream DRC errors. It uses
375,881 LUTs. Its +12.66% LUT count versus the older base-debug FPGA checkpoint
is an unisolated source/configuration comparison, not the controlled +0.3316%
NanGate45 increment. See the measurements for hashes and scope. Board testing
and 200 MHz mapped timing closure remain open.

## Historical shipping debug comparison — 2026-10-26

Both rows use RVA23S64, I-cache, Zvk, Keccak, pipeline and PMU defines with
AXI protection metadata. Geometry is VLEN=256/ELEN=64/VBUS=128, two 64-bit
compute lanes with FP units and static `NONSECURE=1`. The enabled row adds
`KARU_DBG`, DM/private bridges, conventional JTAG and its reset conditioner.
Mapping uses FPGA/default initialization semantics rather than `KARU_ASIC`;
separate ASIC audits confirm zero initialized state in that mode.

| Configuration | Top | kGE | Increment |
| --- | --- | ---: | ---: |
| Shipping, debug disabled | `karu64` | 4,385.849 | baseline |
| Shipping + karudbg | `karudbg_top` | 4,406.494 | +20.644 kGE / +0.4707% |

Yosys 0.69+24 (`d0e71cfb7`), hierarchical `synth -noshare`, fast area-only ABC,
NanGate45 typical (`NAND2_X1=0.798 um²`). The enabled area run has identical
before/after input fingerprints. The disabled design is reused after an exact
non-debug preprocessed-token comparison and mapping-flow/tool identity audit.

The corrected 200 MHz timing comparison uses explicit core-clock reset input
timing. Full OpenSTA reports were refreshed on the unchanged disabled mapped
netlist, and the enabled design was remapped from the corrected RTL:

| Configuration | Register-to-register WNS | TNS | Longest path |
| --- | ---: | ---: | --- |
| Debug disabled | -0.4436 ns | -26.11 ns | IFU buffered address through compressed decode/FP register file to double FMA |
| Debug enabled | -0.3977 ns | -16.93 ns | IFU buffered address through compressed decode/FP register file to double FMA |

Neither row closes at 200 MHz; electrical-limit violations remain, including
high-fanout reset nets. Enabled input-to-register and register-to-output slack
are +0.0566 ns and +2.0143 ns. Its newly timed synchronous reset also reaches
`debug_resume_ack_o` with +0.7022 ns input-to-output slack. The disabled row's
input-to-register and register-to-output slack are +1.1159 ns and +2.7162 ns;
it has no input-to-output paths. Both enabled runs have identical before/after
input fingerprints.
The review-corrected VCU118 debug build completed on 2026-10-27 at 75 MHz.
Whole-design routed setup/hold slack is +0.005/+0.011 ns; CPU setup slack is
+0.482 ns. All 16 bus-skew constraints pass and bitstream DRC reports zero
errors. Routed use is 333,645 LUTs, 88,712 registers, 317.5 BRAM tiles and
29 DSPs. Board acceptance remains open; FPGA timing closure does not change
the separate 200 MHz OpenSTA shortfall above.

See [karudbg measurements](../../dbg/MEASUREMENTS.md) for exact defines, current
source/tool evidence, disabled-row equivalence proof, initialization scope and
reproduction commands. This is a paired debug comparison, not a rerun of every
feature row.

## Release setup

The retained September 15 feature-matrix checkpoint used these settings;
its crypto-leaf refresh predates the current karudbg comparison.

- Yosys 0.69+24 (`d0e71cfb7`).
- OpenSTA 3.1.0, resolved from `PATH` and fingerprinted in the run manifest.
- NanGate45 typical Liberty; `NAND2_X1 = 0.798 um2`.
- Hierarchical `synth -noshare`, no flattening.
- Generic timing constraints with input arrival at 30% and output deadline at
  70% of the period (1.5 ns input/output delays for a 5 ns clock).
- Full timing-oriented ABC mapping for the 5 ns run.
- Fast ABC mapping with STA disabled for area comparison rows.

The September refresh measured the two affected crypto leaves, their common
baseline and umbrella configurations, and the exact shipping composition. The
minimal RVA23S64 row does not enable vector crypto, so the `.vs` correction
cannot change its mapped logic.

## Feature matrix checkpoint — 2026-09-15

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
