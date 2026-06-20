# Karu area matrix handoff

This is the fast, area-only scoping flow for the current `karu64` processor
top. It is intended for cloud runs where we want NAND2 gate-equivalent numbers
for feature and multiplier/divider choices before tightening the top-level
scope.

The matrix runner uses the same Nangate45/Yosys setup as `make synth`, but sets
`KARU_NO_STA=1` for each row. It still uses the default fast ABC script
(`abc_fast.script`) unless you explicitly set `KARU_ABC_FULL=1`. For vector
scoping, use `KARU_NOSHARE=1` initially: it skips Yosys' SAT-based `share`
pass, which otherwise dominates `karu_varith`/`karu_vlsu` runs.

## Run commands

From the repo root:

```sh
cd flow/syn
```

Recommended first cloud run: scalar/F/D and multiplier knobs.

```sh
PER_TIMEOUT=1800 \
CONFIGS="imac_m4d64 imac_nob_m4d64 imac_min_m4d64 imacb_min_m4d64 imafc_m4d64 rv64gc_m4d64 rv64gc_allcomb rv64gc_m16 rv64gc_m64 rv64gc_fp_serial rv64gc_m64_fp_serial" \
./syn_area_matrix.sh
```

For the processor-only scalar comparison, include the no-L1 rows:

```sh
PER_TIMEOUT=1800 \
CONFIGS="imac_core_m4d64 imacb_core_m4d64" \
./syn_area_matrix.sh
```

Recommended second cloud run: vector, vector multiplier, Zvk leaves, and
Keccak. Run the individual Zvk leaves before the umbrella rows; the umbrella
`KARU_ZVK` row is too coarse to isolate a synthesis hot spot.

```sh
KARU_NOSHARE=1 JOBS=2 PER_TIMEOUT=7200 \
CONFIGS="rv64gcv_default rv64gcv_vmul1 rv64gcv_vmul4 rv64gcv_vmul64 rv64gcv_zvkb rv64gcv_zvkned rv64gcv_zvknha rv64gcv_zvknhb rv64gcv_zvksed rv64gcv_zvksh rv64gcv_zvkg rv64gcv_zvk rv64gcv_keccak rv64gcv_zvk_keccak" \
./syn_area_matrix.sh
```

`JOBS` runs multiple configs concurrently. On the 86 GB cloud box, use `JOBS=2`
for the vector/Zvk/Keccak batch. A `JOBS=4` trial reached ~78 GiB used during
techmap, with no swap, so it is too close to the OOM edge. Rows are appended to
`summary.csv` as jobs finish, so parallel output is completion-ordered rather
than matrix-ordered.
`KARU_NOSHARE=1` changes the coarse Yosys flow by adding `synth -noshare`; use
it for first-pass vector deltas, then rerun selected rows without it if an exact
same-flow number is needed.

Full default matrix:

```sh
PER_TIMEOUT=7200 ./syn_area_matrix.sh
```

The Make wrapper passes the same environment through:

```sh
make area-matrix KARU_NOSHARE=1 JOBS=2 CONFIGS="rv64gcv_default rv64gcv_zvkned rv64gcv_zvkg rv64gcv_zvk rv64gcv_keccak rv64gcv_zvk_keccak" PER_TIMEOUT=7200
```

For unattended runs:

```sh
nohup env KARU_NOSHARE=1 JOBS=2 PER_TIMEOUT=7200 \
  CONFIGS="rv64gcv_default rv64gcv_vmul1 rv64gcv_vmul4 rv64gcv_vmul64 rv64gcv_zvkb rv64gcv_zvkned rv64gcv_zvknha rv64gcv_zvknhb rv64gcv_zvksed rv64gcv_zvksh rv64gcv_zvkg rv64gcv_zvk rv64gcv_keccak rv64gcv_zvk_keccak" \
  ./syn_area_matrix.sh > area_matrix.run.log 2>&1 &
```

## Outputs

Each run creates `_build/syn_out/area_matrix_<timestamp>/`.

Important files:

- `summary.csv`: one appended row per completed, failed, or timed-out config.
- `<config>.console.log`: full console log for that config.
- `<config>/reports/area.rpt`: raw Yosys `stat -liberty` area report.
- `rows.txt`: exact matrix rows used for this run.

With `JOBS>1`, `summary.csv` and the console progress table are completion
ordered. Join by the `config` column, not by row position.

Monitor progress with:

```sh
tail -f _build/syn_out/area_matrix_*/summary.csv
tail -f _build/syn_out/area_matrix_*/*.console.log
```

## CSV columns

`kGE` is `area_um2 / NAND2_X1`, using `NAND2_X1 = 0.798 um2` by default.
Override with `NAND2_UM2=<area>` if the library changes.

The current `karu64` top includes more than just a processor core:

- `kGE`: full current top.
- `kGE_minus_karu_mem`: subtracts the hierarchy bucket for `karu_mem`.
- `kGE_minus_karu_mem_sv39`: also subtracts the aggregate `karu_sv39` bucket.

Those subtraction columns are for orientation only. For processor-only/no-MMU
numbers, use the `*_core_*` rows, which synthesize with `KARU_NO_MEM` instead
of subtracting the `karu_mem` hierarchy bucket after the fact.

The remaining bucket columns come from Yosys hierarchy-area rows and are useful
for attribution:

- `karu_mem_kGE`: unified write-through L1/cache wrapper bucket.
- `karu_sv39_kGE`: aggregate Sv39 walker bucket (IMMU + DMMU when S is enabled).
- `karu_csr_kGE`: CSR/privilege block.
- `karu_bitmanip_kGE`: scalar Zba/Zbb/Zbs unit.
- `karu_m_kGE`: integer M extension.
- `karu_fpu_kGE`, `karu_fregfile_kGE`: FP container and FP register file.
- `karu_fmul_kGE`, `karu_fmul_d_kGE`: F/D standalone multipliers.
- `karu_ffma_kGE`, `karu_ffma_d_kGE`: F/D fused multiply-add datapaths.
- `karu_fdiv_kGE`, `karu_fdiv_d_kGE`: F/D dividers.
- `karu_varith_kGE`: vector arithmetic container, including vector mul/div.
- `karu_vcrypto_kGE`: standard Zvk crypto subunit.
- `keccak_kGE`: custom `vkeccak` permutation FSM and round datapath.

Hierarchy bucket areas may be rounded by Yosys in the design hierarchy table.
Use them for deltas and order-of-magnitude attribution; use `kGE` and the raw
`area.rpt` when exact top area matters.

## Matrix rows

Scalar and FP rows:

- `imac_m4d64`: RV64IMAC+B, no F/D/V/K.
- `imac_nob_m4d64`: RV64IMAC, no scalar B, no F/D/V/K.
- `imac_min_m4d64`: RV64IMAC, no B/S-mode/Sv39/HPM, no F/D/V/K.
- `imacb_min_m4d64`: RV64IMAC+B, no S-mode/Sv39/HPM, no F/D/V/K.
- `imac_core_m4d64`: RV64IMAC, no B/S-mode/Sv39/HPM/L1, no F/D/V/K.
- `imacb_core_m4d64`: RV64IMAC+B, no S-mode/Sv39/HPM/L1, no F/D/V/K.
- `imafc_m4d64`: RV64IMAFC+B, adds single-precision F.
- `rv64gc_m4d64`: RV64GC+B, F+D, no V/K.
- `rv64gc_allcomb`: RV64GC+B with 1-cycle M/F/D multiply and 1-cycle M divide.
- `rv64gc_m16`: RV64GC+B with isolated 16-cycle integer multiply.
- `rv64gc_m64`: RV64GC+B with isolated 64-cycle integer multiply.
- `rv64gc_fp_serial`: RV64GC+B with serial F/D multiply and FMA.
- `rv64gc_m64_fp_serial`: RV64GC+B with serial integer M plus serial F/D multiply and FMA.

Vector and crypto rows:

- `rv64gcv_default`: no explicit `KARU_DEFINES`; RTL non-SIM defaults resolve
  to M/F/D mul4, div64, vector mul16, vector div64, perm lanes 2.
- `rv64gcv_vmul1`: same defaults except 1-cycle vector multiply.
- `rv64gcv_vmul4`: same defaults except 4-cycle vector multiply.
- `rv64gcv_vmul64`: same defaults except 64-cycle vector multiply.
- `rv64gcv_zvkb`: default vector core plus Zvk bit-manip glue
  (`vandn`/`vbrev8`/`vrev8`/`vrol`/`vror`). This is lane logic and does not
  instantiate `karu_vcrypto`, so expect its area delta under `karu_varith` or
  `karu_vlane`, not `karu_vcrypto_kGE`.
- `rv64gcv_zvkned`: default vector core plus Zvkned AES.
- `rv64gcv_zvknha`: default vector core plus Zvknha SHA-256.
- `rv64gcv_zvknhb`: default vector core plus Zvknhb SHA-256/SHA-512; this
  implies Zvknha in `karu_ext.vh`.
- `rv64gcv_zvksed`: default vector core plus Zvksed SM4.
- `rv64gcv_zvksh`: default vector core plus Zvksh SM3.
- `rv64gcv_zvkg`: default vector core plus Zvkg GHASH/GCM.
- `rv64gcv_zvk`: default vector core plus all implemented standard Zvk leaves.
- `rv64gcv_keccak`: default vector core plus custom `vkeccak`.
- `rv64gcv_zvk_keccak`: default vector core plus both Zvk and `vkeccak`.

## Delta recipes

Use `kGE_minus_karu_mem_sv39` first, then confirm with raw `area.rpt`.

- F cost: `imafc_m4d64 - imac_m4d64`.
- D cost: `rv64gc_m4d64 - imafc_m4d64`.
- Scalar B cost: `imac_m4d64 - imac_nob_m4d64`; check
  `karu_bitmanip_kGE`.
- S-mode/Sv39/HPM scoped cost: compare `imac_nob_m4d64` with
  `imac_min_m4d64`; check `karu_sv39_kGE` and `karu_csr_kGE`.
- Scalar L1/cache wrapper cost: compare `imac_min_m4d64` with
  `imac_core_m4d64`, or `imacb_min_m4d64` with `imacb_core_m4d64`;
  check `karu_mem_kGE`.
- Integer multiplier cost: compare `rv64gc_m4d64`, `rv64gc_m16`,
  `rv64gc_m64`, and `rv64gc_allcomb`; check `karu_m_kGE`.
- F/D multiplier and FMA cost: compare `rv64gc_m4d64`,
  `rv64gc_fp_serial`, and `rv64gc_m64_fp_serial`; check `karu_fmul_*` and
  `karu_ffma_*`.
- Vector baseline cost: `rv64gcv_default - rv64gc_m4d64`.
- Vector multiplier cost: compare `rv64gcv_vmul1`, `rv64gcv_default`,
  `rv64gcv_vmul4`, and `rv64gcv_vmul64`; check `karu_varith_kGE`.
- Zvk leaf costs: compare `rv64gcv_zvkb`, `rv64gcv_zvkned`,
  `rv64gcv_zvknha`, `rv64gcv_zvknhb`, `rv64gcv_zvksed`, `rv64gcv_zvksh`, and
  `rv64gcv_zvkg` against `rv64gcv_default`. Check `karu_vcrypto_kGE` for the
  crypto leaves; check `karu_varith_kGE`/raw hierarchy for `rv64gcv_zvkb`.
- Zvk umbrella cost: `rv64gcv_zvk - rv64gcv_default`; use this only after the
  leaf rows identify which subextension is tractable.
- Keccak cost: `rv64gcv_keccak - rv64gcv_default`; check `keccak_kGE`.

## Extension gating facts

`rtl/karu_ext.vh` cascades feature opt-outs:

- `KARU_NO_F` also drops D, V, and K.
- `KARU_NO_D` also drops V and K.
- `KARU_NO_V` also drops K.
- `KARU_NO_B` drops scalar Zba/Zbb/Zbs decode/datapath.
- `KARU_NO_S` drops S-mode/Sv39 and ties fetch/data translation to PA=VA,
  pruning the IMMU/DMMU walkers.
- `KARU_NO_HPM` drops `mhpmcounter3..31` and `mhpmevent3..31`; `cycle`,
  `time`, and `instret` remain.
- `KARU_NO_MEM` drops the scalar L1/cache wrapper in non-vector builds and
  connects the scalar LSU directly to the existing dmem arbiter. Vector builds
  force `karu_mem` on because the VLSU uses its 128-bit vector port.

Zvk and Keccak are opt-in only. `KARU_ZVK` enables all implemented standard
Zvk leaves. The individual Zvk leaf knobs are `KARU_ZVKB`, `KARU_ZVKNED`,
`KARU_ZVKNHA`, `KARU_ZVKNHB`, `KARU_ZVKSED`, `KARU_ZVKSH`, and `KARU_ZVKG`.
`KARU_ZVKNHB` implies `KARU_ZVKNHA`. `KARU_ZVKB` is lane bit-manip glue and
does not imply the shared `KARU_EN_ZVK`/`karu_vcrypto` plumbing. `KARU_KECCAK`
enables the custom Keccak op. These are only effective when V is present.

`syn_setup.sh` now preserves an intentionally empty `KARU_DEFINES`, so a matrix
row with an empty define field passes no `-D` flags to Yosys and lets the RTL
headers choose their non-SIM defaults.

## Local checkpoint

A local RV64IMAC smoke run completed before the full matrix was moved to cloud:

```sh
KARU_OUT_DIR="../../_build/syn_out/check_imac_20260617_171325" \
KARU_DEFINES="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F" \
KARU_NO_STA=1 ./syn_yosys.sh
```

Result:

- full current top: 639.29 kGE.
- minus `karu_mem`: 262.10 kGE.
- minus `karu_mem` and two `karu_sv39` instances: 193.80 kGE.
- real no-L1/no-S/no-HPM/no-B scalar row (`imac_core_m4d64`): 104.53 kGE.
- real no-L1/no-S/no-HPM scalar+B row (`imacb_core_m4d64`): 121.13 kGE.

The later local matrix attempt was intentionally stopped before any row
completed; use the cloud run for real matrix data.

Current 86 GB cloud vector/Zvk/Keccak checkpoint, using
`KARU_NOSHARE=1 JOBS=2 PER_TIMEOUT=7200` in
`_build/syn_out/zvk_full_matrix_j2_20260617_202232/`. `_build/syn_out/` is not committed, so
the completed CSV rows are archived here.

The run completed all selected rows. A `JOBS=4` trial was too close to the
no-swap memory limit; the completed run briefly paused one of the two active
Yosys processes around overlapping large ABC peaks, then resumed it.

Top-level and structural buckets:

| row | defines | status | area um2 | kGE | delta kGE | no `karu_mem` | no `karu_mem`/Sv39 | `karu_mem` | `karu_sv39` | `karu_csr` | wall |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `rv64gcv_default` | empty | ok | 3272983.168 | 4101.48 | +0.00 | 3724.29 | 3655.98 | 377.19 | 68.32 | 85.96 | 2524s |
| `rv64gcv_vmul1` | `KARU_V_MUL_CYCLES=1` | ok | 5122336.730 | 6418.97 | +2317.49 | 6041.78 | 5973.46 | 377.19 | 68.32 | 85.96 | 3086s |
| `rv64gcv_vmul4` | `KARU_V_MUL_CYCLES=4` | ok | 3277947.526 | 4107.70 | +6.22 | 3730.51 | 3662.19 | 377.19 | 68.32 | 85.96 | 2494s |
| `rv64gcv_vmul64` | `KARU_V_MUL_CYCLES=64` | ok | 3271814.364 | 4100.02 | -1.46 | 3722.82 | 3654.51 | 377.19 | 68.32 | 85.96 | 2485s |
| `rv64gcv_zvkb` | `KARU_ZVKB` | ok | 3308090.114 | 4145.48 | +44.00 | 3768.28 | 3699.96 | 377.19 | 68.32 | 85.96 | 2547s |
| `rv64gcv_zvkned` | `KARU_ZVKNED` | ok | 3303714.680 | 4139.99 | +38.51 | 3762.79 | 3694.50 | 377.19 | 68.30 | 85.96 | 2518s |
| `rv64gcv_zvknha` | `KARU_ZVKNHA` | ok | 3325920.892 | 4167.82 | +66.34 | 3790.63 | 3722.31 | 377.19 | 68.32 | 85.96 | 2507s |
| `rv64gcv_zvknhb` | `KARU_ZVKNHB` | ok | 3325700.644 | 4167.54 | +66.06 | 3790.35 | 3722.03 | 377.19 | 68.32 | 85.96 | 2527s |
| `rv64gcv_zvksed` | `KARU_ZVKSED` | ok | 3288450.802 | 4120.87 | +19.39 | 3743.67 | 3675.38 | 377.19 | 68.30 | 85.96 | 2508s |
| `rv64gcv_zvksh` | `KARU_ZVKSH` | ok | 3300824.856 | 4136.37 | +34.89 | 3759.17 | 3690.86 | 377.19 | 68.32 | 85.96 | 2506s |
| `rv64gcv_zvkg` | `KARU_ZVKG` | ok | 3293559.066 | 4127.27 | +25.79 | 3750.08 | 3681.75 | 377.19 | 68.32 | 85.96 | 2506s |
| `rv64gcv_zvk` | `KARU_ZVK` | ok | 3418932.580 | 4284.38 | +182.90 | 3907.18 | 3838.88 | 377.19 | 68.30 | 85.96 | 2667s |
| `rv64gcv_keccak` | `KARU_KECCAK` | ok | 3341758.532 | 4187.67 | +86.19 | 3810.48 | 3742.16 | 377.19 | 68.32 | 85.96 | 2533s |
| `rv64gcv_zvk_keccak` | `KARU_ZVK KARU_KECCAK` | ok | 3487771.252 | 4370.64 | +269.16 | 3993.45 | 3925.15 | 377.19 | 68.30 | 85.96 | 2791s |

Compute and extension buckets:

| row | `varith` | delta `varith` | `vcrypto` | `keccak` | `bitmanip` | `fpu` | `fregfile` | `karu_m` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `rv64gcv_default` | 2706.77 | +0.00 | 0.00 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_vmul1` | 5025.06 | +2318.29 | 0.00 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_vmul4` | 2719.30 | +12.53 | 0.00 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_vmul64` | 2706.77 | +0.00 | 0.00 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvkb` | 2756.89 | +50.12 | 0.00 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvkned` | 2744.36 | +37.59 | 3.42 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvknha` | 2769.42 | +62.65 | 8.58 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvknhb` | 2769.42 | +62.65 | 8.58 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvksed` | 2731.83 | +25.06 | 3.47 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvksh` | 2744.36 | +37.59 | 9.54 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvkg` | 2731.83 | +25.06 | 4.60 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvk` | 2894.74 | +187.97 | 10.44 | 0.00 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_keccak` | 2794.49 | +87.72 | 0.00 | 31.13 | 17.67 | 491.23 | 30.45 | 20.55 |
| `rv64gcv_zvk_keccak` | 2982.46 | +275.69 | 10.44 | 31.13 | 17.67 | 491.23 | 30.45 | 20.55 |

Immediate deltas from this checkpoint:

- `rv64gcv_vmul1` adds 2317.49 kGE at top level versus default; almost all of
  it is in `karu_varith`. `rv64gcv_vmul4`, default `rv64gcv_default`
  (`vmul16`), and `rv64gcv_vmul64` are effectively the same size in this flow.
- Zvk leaf top-level deltas versus default are: `zvkb` +44.00 kGE, `zvkned`
  +38.51 kGE, `zvknha` +66.34 kGE, `zvknhb` +66.06 kGE, `zvksed` +19.39 kGE,
  `zvksh` +34.89 kGE, and `zvkg` +25.79 kGE.
- `rv64gcv_zvk` adds 182.90 kGE at top level. The leaf deltas are not
  additive because the umbrella row shares decode, sequencing, and
  `karu_vcrypto` plumbing.
- `rv64gcv_keccak` adds 86.19 kGE at top level. The explicit `keccak` bucket is
  31.13 kGE; `karu_varith` also grows by 87.72 kGE.
- `rv64gcv_zvk_keccak` adds 269.16 kGE at top level, matching the expected
  `zvk` plus Keccak combination within rounding.

The earlier Zvk hang was isolated to the lane-side ZVKB byte/bit reversal
frontend shape. `rtl/karu_vlane.v` now uses fixed-slice helper functions for
`vbrev8`/`vrev8`; after that change the `rv64gcv_zvkb` and umbrella Zvk rows
complete.

## Custom rows

Rows are `config|description|defines`. Provide a file:

```sh
MATRIX_FILE=/path/to/rows.txt PER_TIMEOUT=7200 ./syn_area_matrix.sh
```

Or pass rows directly:

```sh
MATRIX_ROWS='rv64gc_no_m|RV64GC without M|KARU_NO_M KARU_NO_V' ./syn_area_matrix.sh
```
