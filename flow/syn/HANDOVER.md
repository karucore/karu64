# Yosys/OpenSTA flow — handover (2026-09-11)

Status of the `flow/syn` check-up done on the lab workstation (31 GB, no
swap), and what to run on the larger machine. Everything below is in the
working tree of `dev-mjos`, **uncommitted** (6 files, +192/−66); nothing
under `flow/syn` touches the FPGA flow. Read together with `README.md`
(sections *Flow status* and *Timing observations*) and `AREA_MATRIX.md`.

## What was broken, what changed

| file | change | why |
|---|---|---|
| `syn_setup.sh`, `syn_setup.example.sh` | liberty lookup tries `../../../src/flow` (a `src/` checkout beside `karu64/`) then `../../src/flow`; `$KARU_LIB` still overrides | the old single path was inside the checkout, so `make synth` died before Yosys started |
| `tcl/sta_run_reports.tcl` | probes whether `report_checks` accepts `-group_path_count` (OpenSTA ≥ 2.5) or `-group_count` (2.4.0, what the lab box has) | every timing report was empty and the summary printed `WNS: n/a` |
| `tcl/yosys_run_synth.tcl` | (a) ABC script selection: full Yosys liberty script (`&nf` + `buffer; upsize; dnsize`) whenever STA runs, the custom `abc_fast.script` only for area-only runs (`KARU_NO_STA=1`), forced either way by `KARU_ABC_FULL=1` / `KARU_ABC_FAST=1`; (b) `KARU_LTP=1` depth report now runs on the pre-map netlist with `karu64` and `karu_mem` excluded (`KARU_LTP_SKIP` overrides), selection built as `a b %u %n` | (a) the fast script skips buffering, so OpenSTA reported −2174 ns through one unbuffered inverter; the full script is not slower here (4.5 vs 6 min); (b) on the mapped netlist ltp cannot see liberty flops and wrote a 3 GB `Detected loop` flood; a bare `a b %n` only inverts `b` |
| `README.md` | status section, tunables, re-measured results | |
| `rtl/karu_varith.v` (RTL, **one** change) | `vfslide1up/down` source index: `vf_sl_src / epr` and `% epr` → `>> epr_lg` and `& (epr-1)` | `epr` is a runtime value, so both synthesised a real 32-bit divider; it is always a power of two. Verified: `make vfp-test` 46/46 ok (incl. both slide cases); Vivado `elab-check-ddr` with `KARU_ZVK KARU_KECCAK` elaborates with 0 errors |

## Results obtained here (scalar only, NanGate45 typical, 4 ns target)

| run | area | WNS reg2reg | WNS in2reg | worst path | wall |
|---|---:|---:|---:|---|---:|
| RV64GC (`KARU_NO_V`), fast abc (old default) | 688,328 µm² | −2174 ns (artefact) | −13.3 ns | unbuffered `INV_X1` in the L1 data array, 2008 ns on one gate | 6 min + 13 min STA |
| RV64GC (`KARU_NO_V`), full abc | 618,460 µm² | −2.71 ns | +0.98 ns | 123 stages `fpu/u_fr_f2i_d → fpu/u_fr_i2f_d`, 6.67 ns | 4.5 min + 13 min STA |
| RV64GC core, no L1 (`KARU_NO_V KARU_NO_MEM`), full abc | 317,577 µm² = **398 kGE** | −2.73 ns | +0.96 ns | same path, 6.69 ns | 3.7 min + 13 min STA |

Pre-map leaf depths (un-mapped 2-input stages): `karu_i2f_d` 271, `karu_i2f`
269, `karu_ffma` 258, `karu_fmul_d` 239, `karu_bitmanip` 226, `karu_ffma_d`
222, `karu_fadd_d` 202, `karu_fdiv_d` 196, `karu_fsqrt_d` 175, `karu_fmul`
147, `karu_fadd` 110, `karu_fdiv` 102 (45 modules, 0.4 MB report, 0 loops).

Peak memory of a scalar run: ~2 GB. OpenSTA on the 35 MB hierarchical
netlist takes ~13 min for 100 paths × 4 groups (the `100` in
`sta_run_reports.tcl` is the knob if that matters).

## Vector rows: do NOT run on a 31 GB / no-swap host

`rv64gcv_zvk_keccak` (area-only, `KARU_NOSHARE=1`): first attempt aborted in
Yosys `opt` on `karu_varith` with an allocation failure under `ulimit -v
22000000` (18 GB resident); the retry under a 27 GB cap was at 21 GB resident
and still growing (pass 58.20, after ~3000 `OPT_EXPR` iterations on
`karu_varith`) when it **took the whole workstation down**. `ulimit -v` is not
a physical bound. Expect ≥ 25–40 GB for one vector row; `AREA_MATRIX.md`
reports `JOBS=4` reaching ~78 GB on the 86 GB box.

## What to run on the big machine

```sh
cd flow/syn
# 0. sanity: the scalar core-only timing row (≈ 4 min yosys + 13 min STA)
KARU_DEFINES="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_V KARU_NO_MEM" KARU_LTP=1 make synth

# 1. vector area rows (area-only -> fast abc; run leaves before umbrellas)
make area-matrix KARU_NOSHARE=1 JOBS=1 PER_TIMEOUT=7200 \
    CONFIGS="rv64gcv_default rv64gcv_keccak rv64gcv_zvk rv64gcv_zvk_keccak"
#    then, if the box has the headroom, JOBS=2 and the full list in AREA_MATRIX.md

# 2. vector timing + depth (never done before; full abc + STA on the vector core)
KARU_DEFINES="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_MEM KARU_ZVK KARU_KECCAK" \
KARU_NOSHARE=1 KARU_LTP=1 make synth
```

Guard memory with a cgroup, not `ulimit -v`, e.g.
`systemd-run --user --scope -p MemoryMax=60G make ...` (or a swap file), so a
runaway row is killed instead of the host.

Things to look at in the vector results:
- `reports/timing/reg2reg.rpt` worst path and which module owns it
  (`karu_varith` vs `karu_vlane` vs the FPU compose below).
- `reports/depth.rpt`: `karu_varith` / `karu_vlane` / `karu_vcrypto` /
  `keccak_round` leaf depths (expected ~10 stages for `keccak_round`).
- `reports/area.rpt`: `karu_varith`, `karu_vlane`, `karu_vrf_bram` leaf,
  `karu_vcrypto`, `keccak` — the matrix CSV already has these columns.
- Whether `KARU_NOSHARE=1` is still needed with this Yosys (0.65+73).

## Open design observations (not changed)

- **Scalar critical path** is the Zfa `fround.d`/`froundnx.d` compose in
  `karu_fpu` (`u_fr_f2i_d` → `u_fr_i2f_d`, one cycle): 6.7 ns in NanGate45
  (~150 MHz). Registering the compose (+1 cycle `fround` latency) would remove
  it. Irrelevant at the 75 MHz FPGA clock.
- **`karu_bitmanip`** `f_cpop`/`f_clz`/`f_ctz` are 64-iteration sequential
  loops (64-deep adder ripple / priority chains): deep pre-map (226) but not on
  the STA critical path; a tree popcount/clz would be cheaper.
- `karu_m.v` declares the combinational `*`/`/`/`%` result wires
  unconditionally; with the synthesis defaults (`MUL=4`, `DIV=64`) they are
  dead and pruned (area 20.5 kGE matches the README), so no combinational
  divider leaks in — but it relies on dead-code elimination.
- `karu_vlane.v` in-lane `/`/`%` exists only for `KARU_V_DIV_CYCLES=1`
  (`DIV_COMB`), which is the `SIM_TB` default, not the synthesis default (64).
- The L1 data array (`karu_1w1r_async_ram`) is a 348 kGE flop sea in this
  flow; quote `KARU_NO_MEM` rows for the processor, or blackbox the memory
  leaves as macros (not implemented; STA would need a stub liberty cell).

## Housekeeping

- Local outputs under `_build/syn_out/` (≈ 9.5 GB, mostly the STA-friendly
  netlists and abc logs of the three scalar runs): safe to delete (`make clean`
  in `flow/syn` removes the legacy dir; `rm -rf _build/syn_out` for these).
- Yosys 0.65+73 (`~/.local/bin/yosys`) and OpenSTA 2.4.0 (`/usr/local/bin/sta`)
  were used here; the README lists both versions as tested.
