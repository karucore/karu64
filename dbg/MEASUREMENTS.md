# karudbg measurements

The 2026-10-26 refresh measures the review-corrected shipping processor
composition with AXI protection metadata in both rows. The enabled row adds
core Sdext support, DM, private debug-memory bridges and conventional JTAG DTM,
including its TCK reset-release conditioner. It uses `karudbg_top`; the disabled
row uses `karu64`. FPGA BSCAN integration and board acceptance have separate
scope. Both area rows and the corrected timing comparison are complete.

## Configuration and tools

Both rows use VLEN=256, ELEN=64, VBUS=128, two 64-bit compute lanes with FP
units, 4 KiB I/D caches and the static `NONSECURE=1` parameter. Common defines:

```text
KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK
KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64
KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64
KARU_V_LANE_PIPE KARU_V_CWB_STAGE
KARU_SMCNTRPMF KARU_SSCOFPMF
```

The enabled row additionally defines `KARU_DBG`. Mapping retains FPGA/default
RTL initialization semantics, without `KARU_ASIC`. Memories map to standard
cells: these are comparative NanGate45 cell estimates, not physical SRAM-macro
area or ASIC signoff results. Separate ASIC initialization evidence is below.

Tools are Yosys 0.69+24 (`d0e71cfb7`), its associated ABC, OpenSTA 3.1.0 and
NanGate45 typical-corner Liberty. One kGE is 798 um² (`NAND2_X1=0.798 um²`).
The measured review fixes are committed at `175b842`; source/input fingerprints
in the run manifests identify the measured implementation.

## Mapped area

Hierarchical `synth -noshare`, no flattening, fast area-only ABC mapping,
STA disabled:

| Configuration | Top | Area (um²) | kGE |
| --- | --- | ---: | ---: |
| Shipping, debug disabled | `karu64` | 3,499,907.768 | 4,385.849 |
| Shipping + karudbg | `karudbg_top` | 3,516,381.946 | 4,406.494 |
| Debug increment | | 16,474.178 | 20.644 |

The measured increment is **0.4707%**. The enabled run completed with identical
before/after input fingerprints; its starting manifest SHA-256 is
`fa6e7dd5ca1f28cf72ffb0baf72e5ca26d0de8bf8a59e43e317c320db2541e5b`.
Yosys reported 23,063 MB peak memory. Evidence is under
`_build/syn_out/karudbg/{area_off,area_on}/`.

The disabled mapped design is reused with an explicit equivalence audit.
All 54 source token streams after Yosys preprocessing under the shipping
non-debug defines match `4058a60`, whose core sources match the recorded
mapping inputs. Mapping scripts, ABC constraints, tool binaries and Liberty
are unchanged. This proves the debug-only review changes do not alter the
reference design. Source, token, flow and tool evidence is in
`_build/syn_out/karudbg/off-source-equivalence/proof.json`.

## OpenSTA at 200 MHz

Timing uses a 5 ns core clock, timing-oriented ABC mapping with a 3 ns internal
budget, and 1.5 ns input/output delays. `KARU_IN_PCT=30` sets input arrival;
`KARU_OUT_PCT=70` sets the output deadline, leaving a 30% output delay budget.
The enabled top also constrains TCK at 100 ns (10 MHz).

| Configuration | Register-to-register WNS | TNS | Input-to-register WNS | Register-to-output WNS |
| --- | ---: | ---: | ---: | ---: |
| Debug disabled | -0.4436 ns | -26.11 ns | +1.1159 ns | +2.7162 ns |
| Debug enabled | -0.3977 ns | -16.93 ns | +0.0566 ns | +2.0143 ns |

Neither row closes at 200 MHz. Both longest paths start at IFU
`buf0_a[3]`, pass through compressed decode, the FP register file and
double-precision FMA operand logic, and end in `u_ffma_d/_30816_`, arriving
at 5.40 ns with debug disabled and 5.36 ns with debug enabled. The enabled
input-to-register minimum is the synchronous reset path to IFU `ins_pc[63]`.
It also has an input-to-output reset path to `debug_resume_ack_o`, with
**+0.7022 ns** slack. The disabled top has no input-to-output paths.
Electrical-limit violations remain in both rows, including high-fanout reset
nets. These are mapped timing estimates, not electrical or physical signoff.

Both core-only and debug constraints now time synchronous `rst` against the
core clock. The enabled constraints exempt only paths from external reset
ports to TCK-domain asynchronous reset pins. Registered reset-release
outputs retain their consumer recovery/removal checks. Bundled DMI payload
paths have maximum-delay bounds of 0.8 destination cycles; only first-stage
control D pins and asynchronous cross-domain hold checks are exempt.

The enabled mapping completed with identical before/after input fingerprints;
its starting manifest SHA-256 is
`80470a2ca7460d37d1604d73c0fc466577c0ad9b965ec8d632d40a3b2e39a5fb`.
Yosys reported 2,059.62 seconds and 23,079 MB peak memory. All 321 fingerprinted
inputs still matched after completion. The enabled setup-coverage report flags
only `trst_n` as having no input delay: it is an asynchronous reset input whose
paths to TCK asynchronous reset pins are explicitly exempt.

The disabled mapped netlist is unchanged as proven above; full OpenSTA
reporting was rerun under the corrected default SDC in 82.93 seconds with
identical before/after inputs. Its input coverage includes synchronous reset;
the setup-coverage report is empty.
Provenance is in `timing_off/log/sta-refresh.manifest.json`; current reports
are under `_build/syn_out/karudbg/{timing_off,timing_on}/reports/timing/`.

The reproducible conventional-top constraint command-model regression is
`make dbg-ooc-reset-constraints-test` (or
`tclsh test/dbg/test_ooc_reset_constraints.tcl`). It checks reset/clock/bundle
scope without Vivado and rejects broad-reset and released-reset-cut mutants,
plus three missing-stage/property/pin controls. A separate OpenSTA scope
check on the previous mapped netlist confirms timed synchronous reset and
retained reset-release paths (`_build/dbg/reset-timing-review/`). These scope
checks do not replace a current RTL mapping or physical timing validation.

## Routed VCU118 implementation — 2026-10-27

The committed review fixes at `175b842` completed the standard
`vcu118-ddr-sgmii-rom-rva23s64-dbg` flow with Vivado 2026.1, eight threads,
`ExtraTimingOpt` placement, `AggressiveExplore` physical optimization and
post-route physical optimization. No further RTL change was needed.

| Routed result | Value |
| --- | ---: |
| CPU clock | 75 MHz |
| Whole-design setup / hold slack | +0.005 / +0.011 ns |
| CPU setup / hold slack | +0.482 / +0.011 ns |
| Minimum pulse-width slack | +0.005 ns |
| Bus-skew constraints met | 16/16 |
| Minimum bus-skew slack | +2.699 ns |
| LUTs | 333,645 (28.22%) |
| Registers | 88,712 |
| Block-RAM tiles / DSPs | 317.5 / 29 |
| Bitstream DRC errors | 0 |

All constrained setup, hold and pulse-width paths pass. The tightest setup
margin is in the MIG's 300 MHz domain. The longest CPU path starts at IFU
`buf0_a_reg[7]`, passes through decode and FP-register operand logic, and ends
at double-FMA `s0_sigC_n_reg[33]`: 12.704 ns data-path delay, including
8.474 ns of routing. The last post-route setup violation was in the Ethernet
receive SERDES and was resolved by the standard physical-optimization pass.

The BSCAN constraints use the hard primitive's `INTERNAL_TCK`, derived TCK
and gated DRCK. The hard TDO sampling path has +46.708 ns setup and
+50.699 ns hold slack. Only incoming asynchronous reset pins of the four
reset-release helpers are exempt; their functional reset outputs remain
timed. Request/reply bundle skew is 1.518/1.405 ns against 5.333/40 ns bounds.
Physical implementation and its constraints are validated; actual board
transport, detach and karudeb boot acceptance remain open.

Evidence is `_build/fpga_rpt/vcu118_ddr_{timing,utilization,bus_skew}.rpt`,
the tagged copies under `_build/fpga_rpt/ddr_rva23s64_dbg_sgmii_75_rom__*`,
and `_build/vcu118_ddr_route.dcp`. The build log is
`_build/vcu118_ddr_synth.log`; source and ROM input hashes are recorded in
`_build/vcu118_build_inputs.json`. The boot ROM was checked byte-for-byte
against karudeb's OpenSBI, rebuilt U-Boot, profile DTB and staged netboot line.

The resulting `_build/vcu118_ddr.bit` has SHA-256
`bc5e3d3d1639d02c1657c44759d46fa6afd2e833f4811b9621aca66bab97571c`.
Use `make vcu118-program-bundle` to package it with its probes, ROM manifest
and extracted control DTB. See [FPGA handoff](../doc/fpga.md#optional-karudbg-integration)
for host-tool and board acceptance instructions.

## ASIC initialization and memory scope

The post-review combined audit uses `KARU_ASIC` and reports **zero initialized
state**, **97,024 data-array bits**, nine macro candidates, two 1W2R register
files and four scratch arrays. The small Program Buffer adds one control
array to the core-only inventory (34 versus 33); constant lookup arrays
remain 14. The tracked core-only inventory is not replaced by this combined
report. Evidence is `_build/dbg/asic-audit-combined/summary.json` and its
source/define manifests, RTLIL and CSV/Markdown inventories.

Small mapping comparisons of the integer RF, FP RF and 1W1R/1W2R RAM leaves
show identical primitive-cell inventories with and without `KARU_ASIC`; ASIC
mode removes initialization attributes. This does not substitute for a full
`KARU_ASIC` area/timing comparison. Four-state memory checks and randomized
`vresv`, `vperm`, `vstart` startup checks are separate functional evidence.

## Reproduce

From the repository root, with tools on `PATH` and `KARU_LIB` pointing to the
typical NanGate45 Liberty:

```sh
make dbg-syn-area-off
make dbg-syn-area-on
make dbg-syn-timing-off
make dbg-syn-timing-on
python3 flow/asic/audit.py --manifest dbg/karudbg.f --top karudbg_top \
  --define KARU_DBG --out _build/dbg/asic-audit-combined
```

Outputs use `_build/syn_out/karudbg/`. Bound simultaneous full-vector Yosys
jobs by available RAM; these runs each peak near 23 GB. Explicit overrides
are `DBG_SYN_DEFINES`, `DBG_SYN_ROOT` and `DBG_TCK_PS`. The conventional-JTAG
OOC and standard VCU118 board targets are documented in [README.md](README.md);
those implementations and board tests are not implied by these cell estimates.
