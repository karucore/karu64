# karudbg measurements

## Registered SBA pause — 2026-10-30

The fetch-fault trigger qualification added on October 29 exposed a new
combinational path: reset-gated SBA request VALID reached the arbiter pause,
then the execute-trigger comparators and core issue/CSR logic. This caused
the full-row input-to-register miss below; it was not a pre-existing base
debug timing failure.

The arbiter now registers its pause. A RAM request cannot be accepted until
that registered hold is high and the core reports quiet, so an instruction
admitted on the hold's assertion edge still drains before AW/W. Actual request
VALID keeps its reset suppression. Cancellation clears an unaccepted hold on
the next clock; accepted writes retain it through response/maintenance.
This adds one control flip-flop and a hold-assertion clock to RAM-write setup.
The combined non-board gate passes at 01:08 UTC in 1,094.03 seconds with all
274 captured inputs unchanged; the current arbiter source SHA-256 is
`48bff334aa27d34a5bc35b5e5d3337355897b7155ddd7e9798f48a81388829fc`.
The bus bench passes 652 checks in each security configuration; all 13
invariant corruption controls and 17 transport/backend controls are rejected.
The full two-trigger timing row was freshly mapped with unchanged 200 MHz
constraints, tools and Liberty. Only `dbg/karudbg_bus.v` differs between its
captured synthesis inputs and the October 29 run. The current result is:

| Configuration | Reg-to-reg WNS ns | TNS ns | Input-to-reg ns | Reg-to-output ns | Input-to-output ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full, two triggers | −0.3978 | −17.40 | +0.2328 | +0.3106 | +0.5794 |

Input-to-register slack improves from −0.1739 to +0.2328 ns; all three IO
groups now pass. The worst input path still starts at timed synchronous reset
and ends in the IFU, but goes through ordinary DM/core control, rather than
the SBA request/pause and trigger-comparator chain. The register-to-register
miss remains on the IFU/decode-to-double-FMA path, so 200 MHz is still open.
The four-trigger row and area rows have not been rerun for this change.

Reproduce with `make DBG_SYN_EXTENSION=full dbg-syn-extension-timing`.
The mapped reports and before/after input hashes are in
`_build/syn_out/karudbg/timing_full/`; the independently checked result is
`_build/dbg/reset-pause/results.json`. Running `make dbg-measurements-report`
now marks only this timing row current and the retained October 29 rows
stale against the changed source; it does not silently reuse their numbers.

The October 29 FPGA image and programming bundle below are unchanged and
retain their recorded 75 MHz acceptance. They contain the earlier pause
implementation, rather than this RTL follow-up.

## Extension measurements — 2026-10-29

All six area and six timing rows were freshly mapped after the review fixes
for SBA discovery, scratch-memory coherence, external-cache completion and
trigger direction/pause qualification. Every row has identical before/after
input fingerprints for that checkpoint's RTL, tools, flow and Liberty;
no netlist or source-equivalence reuse was used. The core source SHA-256 is
`989822449d1646d4f6471c3628b4eee2964e2b6c77d858bb8598cb427d6fb5ee`.
These tables retain the October 29 checkpoint. The subsequent pause register
is covered separately above; its area and four-trigger timing are not inferred
from these measurements. The original full timing row is preserved in
`_build/syn_out/karudbg/timing_full-2026-10-29.tgz` and its collected matrix in
`_build/dbg/reset-pause/before-measurements.json`.

The comparison uses the same shipping processor and conventional-JTAG
`karudbg_top` for base debug, autoexec only, two triggers only, SBA only,
all extensions with two triggers, and all extensions with four triggers.
`KARU_DBG_FULL` enables autoexec, triggers and SBA. The standard 75 MHz
FPGA debug target selects the full two-trigger configuration; mapped cell
estimates and routed FPGA acceptance are separate results.

`make dbg-measurements-report` checks the evidence and writes row validity,
source/tool/library hashes and worst-path endpoints to
`_build/syn_out/karudbg/measurements/measurements.{json,md}`.

| Configuration | Area kGE | Increment kGE | Increment % |
| --- | ---: | ---: | ---: |
| Base debug | 4,406.7233 | 0.0000 | 0.0000 |
| Autoexec | 4,406.8260 | 0.1027 | 0.0023 |
| Two triggers | 4,412.8477 | 6.1243 | 0.1390 |
| SBA | 4,415.0943 | 8.3710 | 0.1900 |
| Full, two triggers | 4,421.3380 | 14.6147 | 0.3316 |
| Full, four triggers | 4,425.0677 | 18.3443 | 0.4163 |

The increments use the fresh base-debug area row. Area uses fast ABC;
timing uses a separate timing-oriented mapping at 200 MHz. These NanGate45
typical estimates map memories to cells, rather than ASIC SRAM macros.

| Configuration | Reg-to-reg WNS ns | TNS ns | Input-to-reg ns | Reg-to-output ns | Input-to-output ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Base debug | −0.3991 | −16.64 | +0.4428 | +2.0461 | +0.7750 |
| Autoexec | −0.3991 | −16.64 | +0.3823 | +2.0191 | +0.7549 |
| Two triggers | −0.3975 | −16.55 | +0.4174 | +0.4459 | +0.7041 |
| SBA | −0.3978 | −17.36 | +0.4749 | +1.9740 | +0.7171 |
| Full, two triggers | −0.3978 | −20.38 | −0.1739 | +0.3106 | +0.3510 |
| Full, four triggers | −0.9432 | −96.76 | −0.2210 | +0.2706 | +0.3039 |

No row closes at 200 MHz. The selected full two-trigger row has register-to-
register WNS −0.3978 ns and TNS −20.38 ns. Its longest path starts at IFU
`_6986_`, passes through buffered-address/compressed-decode and FP operands,
and ends at double FMA `u_ffma_d/_30816_`: 5.36 ns data arrival. Base debug
has the same critical-path family at −0.3991 ns. The small slack difference
is mapping variation, rather than evidence that debug improves timing.

The full row also fails input-to-register timing at **−0.1739 ns**. The path
starts at synchronous `rst`, traverses DM/SBA and trigger/core control, and
ends at IFU `_7340_`. Its 5.14 ns arrival includes the specified 1.50 ns input
delay. The synchronous reset path is timed; it is not covered by the TCK
asynchronous-reset exception. The archived full timing row retains the
detailed cone. Base debug's corresponding group passes at +0.4428 ns.
The full row's `debug_resume_ack_o` output paths pass: +0.3106 ns from a
register and +0.3510 ns from an input. There is no general IO-clean claim.

The optional four-trigger row has WNS −0.9432 ns and TNS −96.76 ns. Its
longest path runs from `frs1_q[0]`, through buffered scalar distribution,
widening and the lane FP-estimate unit, to `ksbuf[348]`: 5.90 ns arrival.
It does not traverse a trigger comparator. Its reset input group also fails
at −0.2210 ns. Independent mappings vary in unchanged datapaths, so the
slack difference cannot be assigned entirely to the two extra trigger slots.
The four-slot row is a cost comparison, not the default FPGA composition.

The registered 64-bit watch address separates indexed effective-address
generation from trigger comparison and global entry control. It adds one
cycle per armed vector field query; the disabled sequence is unchanged.
All 16 ordinary subjects have identical full/base cycle counts. No RF,
cache or VRF memory port was added.

Whole-row memory use can reach about 35 GB including ABC subprocesses;
Yosys's own approximately 23 GB peak excludes those children. Bound concurrent
rows by available memory. All source/configuration and raw-report evidence is
under `_build/syn_out/karudbg/{area,timing}_<configuration>/`.

## Historical base-debug measurements — 2026-10-26

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

## Routed VCU118 implementation — 2026-10-29

The standard `vcu118-ddr-sgmii-rom-rva23s64-dbg` flow completed with
`KARU_DBG_FULL`: autoexec, two address triggers and SBA. It uses Vivado
2026.1 build 6511674, eight threads, `ExtraTimingOpt` placement and
`AggressiveExplore` physical optimization. The standard post-route pass
closed the remaining setup violation; no additional RTL or flow change was
needed. All 149 captured production/boot inputs match before, after and at
final verification. This is the recorded working tree at HEAD `aa7fbe4`,
including uncommitted implementation changes, rather than a clean-commit build.

| Routed result | Value |
| --- | ---: |
| CPU clock | 75 MHz |
| Whole-design setup / hold slack | +0.010 / +0.011 ns |
| CPU setup / hold slack | +0.048 / +0.011 ns |
| Minimum pulse-width slack | +0.005 ns |
| Bus-skew constraints met | 16/16 |
| Minimum bus-skew slack | +2.141 ns |
| LUTs | 375,881 (31.79%) |
| Registers | 89,881 |
| Block-RAM tiles / DSPs | 317.5 / 29 |
| Bitstream DRC errors | 0 |

All constrained setup, hold and pulse-width paths pass. The tightest setup
margin is in the MIG's 300 MHz domain. The longest CPU path runs from vector
arithmetic `vs1_q_reg[3]` to FP-result register `f_relem_q_reg[23]`:
13.013 ns data-path delay, including 9.568 ns of routing. This is the
75 MHz routed result, separate from the unmet 200 MHz mapped-cell target.

The earlier October 27 base-debug image used 333,645 LUTs; this snapshot uses
375,881, a **12.66% increase**. Both use the same Vivado build, placement and
physical-optimization directives. The expanded common defines retain
RVA23S64, I-cache, Zvk/Keccak, DDR divide-by-four, SGMII/TAXI, vector
multiply/divide 16/64, lane/CWB staging and PMU support; the new explicit
feature define is `KARU_DBG_FULL`. The RTL checkpoint also changed from
`175b842` to this working tree, and the rebuilt U-Boot binary differs despite
the same version and boot command. Fu-boot, OpenSBI, DTB and staged boot-line
hashes are unchanged. No same-RTL base/full Vivado comparison was run, so the
cause of the LUT increase remains unisolated. It must not be presented as the
controlled NanGate45 feature increment of +0.3316%.

Evidence is `_build/fpga_rpt/vcu118_ddr_{timing,utilization,bus_skew}.rpt`,
the tagged reports under `_build/fpga_rpt/ddr_rva23s64_dbg_sgmii_75_rom__*`,
and `_build/vcu118_ddr_route.dcp`. The source/boot input hashes, actual defines,
report hashes, resources and output hashes are in
`_build/vcu118_build_inputs.json`; `_build/vcu118_full_verification.json`
records the independent final checks. The packed ROM matches fu-boot,
OpenSBI, U-Boot, the profile DTB and 644-byte lab netboot command byte for byte,
including zero padding and the fixed offsets.

The new `_build/vcu118_ddr.bit` has SHA-256
`8c8ea6bd481b782f8c5f69699ca98de3e91e9f6c5fd63806db6a3eb450b14592`.
`make vcu118-program-bundle` produced `_build/vcu118_programming.tgz`
(14,208,769 bytes), SHA-256
`279d3319b8b4365481e786e711bf5317f2ff28069c3e66711d9da18216b01137`.
Its four members keep their `_build/...` paths: bitstream, probes, ROM
manifest and extracted control DTB. The DTB remains `d617ba56…0cec9`, matching
karudeb `a3e6b70`. The previous base bitstream and its hash metadata are
retained as `_build/vcu118_ddr.base-2026-10-27.bit` and
`_build/vcu118_build_inputs.base-2026-10-27.json`.

The image has not been programmed or booted on the board. Physical USER4
transport, full-extension debugger acceptance, detach and normal karudeb boot
remain pending. See [FPGA handoff](../doc/fpga.md#optional-karudbg-integration)
for the native pinned OpenOCD and board acceptance instructions.

## ASIC initialization and memory scope

The base-debug post-review combined audit uses `KARU_ASIC` and reports **zero initialized
state**, **97,024 data-array bits**, nine macro candidates, two 1W2R register
files and four scratch arrays. The small Program Buffer adds one control
array to the core-only inventory (34 versus 33); constant lookup arrays
remain 14. The tracked core-only inventory is not replaced by this combined
report. Evidence is `_build/dbg/asic-audit-combined/summary.json` and its
source/define manifests, RTLIL and CSV/Markdown inventories.

The full-extension audit was refreshed on 2026-10-29 with `KARU_ASIC`,
`KARU_DBG` and `KARU_DBG_FULL`. It also reports **zero initialized state** and
**97,024 data-array bits**, with the same nine macro candidates, two register
files, four scratch arrays and 14 constant lookup arrays. Control arrays rise
from 34 in base debug to 37: trigger `address`, `control` and `napot_mask` are
64×2 each, 384 logical bits in total. Four slots double those logical control
bits without adding a data RAM port. Autoexec/SBA add scalar control registers;
the RF/cache/VRF macro interfaces remain unchanged. Exact source
hashes and before/after integrity records are in
`_build/dbg/asic-audit-full/manifest.json`, with generated inventories and
`summary.json` alongside it. This structural audit is separate from mapping.

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
jobs by available RAM, including ABC subprocesses. Explicit overrides
are `DBG_SYN_DEFINES`, `DBG_SYN_ROOT` and `DBG_TCK_PS`. The conventional-JTAG
OOC and standard VCU118 board targets are documented in [README.md](README.md);
those implementations and board tests are not implied by these cell estimates.

For extension rows, use the maintained recipe with
`DBG_SYN_EXTENSION=base`, `autoexec`, `triggers`, `sba`, `full` or `full4`:

```sh
make DBG_SYN_EXTENSION=full dbg-syn-extension-area
make DBG_SYN_EXTENSION=full dbg-syn-extension-timing
make dbg-measurements-collector-test dbg-measurements-report
```

The collector reads `area_<row>` and `timing_<row>` under `DBG_SYN_ROOT`;
it does not start synthesis. It writes `measurements/measurements.json` and
`measurements/measurements.md` under that build directory. A row is reported
only after checking fresh reports, before/after fingerprints, current source,
tool and Liberty hashes, and the expected feature/clock configuration.
Missing or in-progress rows remain pending; stale or inconsistent rows supply
no current metrics. All twelve rows above are fresh mappings with exact raw
input equality; none uses the collector's separately verified historical
source-equivalence reuse mechanism. Deltas require the same non-feature
configuration, effective inputs, tools and library as the base row.
The kGE conversion uses the library's 0.798 µm² `NAND2_X1`; path-group minima
come from the CSV reports, while TNS comes from OpenSTA's full summary.
