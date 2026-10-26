# karudbg measurements

The 2026-10-26 comparison measures the shipping processor composition with AXI
protection metadata in both rows. The debug row adds the core Sdext support,
DM, private debug-memory bridges and conventional JTAG DTM. It uses
`karudbg_top`; the debug-disabled row uses `karu64`. FPGA board integration and
board testing are separate acceptance gates.

The area and 200 MHz timing comparisons include the final TCK reset-release
conditioner and unchanged default IDCODE. The debug-disabled processor RTL
is unchanged. The optional BSCAN board integration is a separate build; its
final routed checks remain pending.

## Configuration and scope

Both rows use VLEN=256, ELEN=64, a 128-bit vector memory/granule interface,
two 64-bit compute lanes (each containing an FP unit), 4 KiB I/D caches and
the static `NONSECURE=1` parameter.
The common defines are:

```text
KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK
KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64
KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64
KARU_V_LANE_PIPE KARU_V_CWB_STAGE
KARU_SMCNTRPMF KARU_SSCOFPMF
```

The debug row additionally defines `KARU_DBG`. These mapping rows retain the
FPGA/default RTL initialization semantics; they do **not** define `KARU_ASIC`.
Yosys maps the memories to standard cells. These are comparative NanGate45
cell-area estimates, not physical SRAM-macro area or ASIC signoff results.
The separate ASIC initialization/inventory evidence is recorded below.

Tools: Yosys 0.69+24 (`d0e71cfb7`), its associated ABC, OpenSTA 3.1.0 and
NanGate45 typical-corner Liberty. One kGE is 798 um² (`NAND2_X1=0.798 um²`).
The run manifests record binary paths/hashes, the Liberty hash and all source
and flow fingerprints. Sources are the uncommitted implementation on top of
`7bbb76a3df9159eae680fac48f9286581e3fa897`; the commit alone does not identify
the measured design.

## Mapped area — final conventional debug top

Hierarchical `synth -noshare`, no flattening, fast area-only ABC mapping,
STA disabled. Both before/after input manifests match exactly.

| Configuration | Top | Area (um²) | kGE | Yosys reported peak memory (MB) |
| --- | --- | ---: | ---: | ---: |
| Shipping, debug disabled | `karu64` | 3,499,907.768 | 4,385.849 | 23,034 |
| Shipping + karudbg | `karudbg_top` | 3,516,134.566 | 4,406.184 | 23,251 |
| Debug increment | | 16,226.798 | 20.334 | |

The measured increment is **0.4636%**. The conditioner adds 12.502 um²
(0.0157 kGE) relative to the earlier debug baseline. Compare these two rows
with each other; the older feature matrix uses a different RTL checkpoint.
The disabled row is reused because its consumed processor sources, tools,
Liberty and mapping settings are unchanged; the flow update only narrowed
the input-fingerprint scope and added tool-resource hashes.

Evidence under `_build/syn_out/karudbg/{area_off,area_on}/` includes
`reports/area.rpt`, `log/manifest.txt` and both input manifests. SHA-256 of
`log/inputs.before.sha256`:

- Debug disabled: `bd2260380451be3c9aeae5e2ceb8e7b7e3e5d3dae38475d3c54cfcec4c29f4a5`.
- Debug enabled: `060ab217ba9a8ccde1f4061d93768d836c2ecb18e87df110637f06ce9f14f87d`.

## Timing and FPGA implementation

The paired OpenSTA runs target a 5 ns core clock (200 MHz), with timing-oriented
ABC mapping at a 3 ns internal budget and 1.5 ns input/output delays.
The settings are `KARU_IN_PCT=30`, `KARU_OUT_PCT=70`: the latter specifies
the output deadline at 70% of the period, so `set_output_delay` reserves the
remaining 30% (1.5 ns), rather than 3.5 ns.
The debug top additionally constrains TCK at 100 ns (10 MHz).

| Configuration | Register-to-register WNS | TNS | Input-to-register WNS | Register-to-output WNS |
| --- | ---: | ---: | ---: | ---: |
| Debug disabled | -0.4436 ns | -26.11 ns | +1.1159 ns | +2.7162 ns |
| Debug enabled, final conventional top | -0.7621 ns | -69.83 ns | +0.0538 ns | +2.0395 ns |

Neither row closes at 200 MHz. The enabled row's longest mapped path starts
at vector `frs1_q[0]`, passes through its fanout buffers, `u_widen_b` and
lane `u_est`, and ends at shared `ksbuf[348]` storage: 5.72 ns arrival against
a 4.96 ns setup requirement. More than 30 serial `BUF_X1` stages account for
about 2 ns before the widening/estimate logic. This mapped fanout-buffer
chain and the remaining electrical violations limit what the raw slack
comparison says about the RTL; it is not a measured delay through the two
new reset-conditioner flops. The disabled row starts at IFU `buf0_a[3]`,
passes through compressed decode, the FP register file and double-precision
FMA operand logic, and ends in `u_ffma_d/_30816_`, arriving at 5.40 ns.
The final enabled mapping differs from the earlier debug baseline despite
the same vector RTL source hash; the earlier slack is not the final result.
Slew and capacitance violations remain, including DTM reset-distribution
fanout. These are mapped timing estimates rather than electrical or physical
signoff. There are no input-to-output paths.
The disabled `check_setup` report is empty; the enabled report lists only
`trst_n`, which is intentionally false-pathed.

Evidence: `_build/syn_out/karudbg/{timing_off,timing_on}/`. The final enabled
run completed with identical before/after fingerprints and no OpenSTA errors;
its starting manifest SHA-256 is
`ea6196a8e4e160efd41c75e7950add091ee3a0e7fd747797d283027cb1e81897`.
The reused disabled wrapper exited with status 1 because its overly broad
source fingerprint saw four newly added, **unconsumed** debug files. No
pre-existing recorded dependency changed and its OpenSTA log has no error.
The preserved `baseline-consumed-input-audit.json` records the raw manifest
diffs, frontend source lists and that qualification; exact source snapshots
are under `baseline_inputs/`. The corrected flow fingerprints declared
sources and include closure instead of every unrelated debug source.

The baseline VCU118-device out-of-context run, before reset conditioning,
targets a 13.333333 ns core clock (75 MHz)
and 100 ns TCK. It completed with **routed WNS +0.238 ns, TNS 0, WHS +0.036 ns
and THS 0**. The longest internal path is vector reduction control/data,
`varith_u/rch[0]` to `red_pp0[54]`: 13.074 ns data delay, comprising 2.556 ns
logic and 10.518 ns routing, through 25 logic levels. Final utilization is
351,559 LUTs (349,499 logic and 2,060 LUTRAM), 63,255 FFs, four RAMB36 and
26 DSPs. No unrouted nets, partial nets or node overlaps remain.
This top has conventional JTAG and external AXI interfaces. It includes no
board DDR/clock IP, FPGA BSCAN transport, pin assignments or boot-ROM packing,
and does not produce a programmable board bitstream.
Its external ports have no `HD.PARTPIN_LOCS`: Vivado reports that these OOC
port segments cannot be physically routed. External AXI/JTAG timing therefore
uses the declared I/O delay assumptions; it is not evidence for routed board
or pad timing. Internal placement/routing and the final core/CDC paths are
the useful implementation measurements from this run.

CDC payload paths remain timed: each direction has a maximum datapath budget
of 0.8 destination cycles. Only the four first-stage control synchronizer D
pins are excluded from setup checks; asynchronous cross-domain hold checks
are excluded. Vivado also bounds request/response bus skew to 0.4 destination
cycles. OpenSTA uses its native `-ignore_clock_latency` option, including the
endpoint setup check. Simulation, timing WNS and structural CDC reports are
separate evidence; none alone establishes physical CDC signoff.
The routed request bundle covers 41 endpoints: actual bus skew 0.506 ns
against a 5.333 ns limit. The response bundle covers 34 endpoints: actual
skew 0.687 ns against 40 ns. Both maximum-delay directions remain timed,
with +10.083 ns and +79.235 ns slack respectively. The report-only follow-up
under `_build/dbg/vivado_ooc/` retains `bus_skew.rpt`, both crossing reports,
internal setup/hold reports and `final_report_checks.txt`.

The baseline CDC report has four recognized two-flop control synchronizers,
198 critical asynchronous-reset findings and 156 clock-enable warnings.
The reset findings prompted the final top-level reset-release conditioner;
this older report is **not** clean CDC evidence for the final implementation.
The external `rst` and `trst_n` paths are false-pathed in this OOC constraint
set. Their asynchronous release into the TCK-side state is therefore outside
the reported recovery/removal checks. The platform must control reset release
relative to TCK (including a stopped clock) or provide an appropriate local
release mechanism; a green setup/hold summary does not establish that contract.

## Final implementation checks and pending measurements

The final conventional top asynchronously asserts its transport reset and
releases it after two TCK rising edges, including when TCK was stopped. Its
IDCODE parameter reaches both DTM and TAP; the default remains the simulation
placeholder. Focused full-core OpenOCD interoperability and the passive
production-top reset monitor pass, as do declaration-order, Verilator and
strict Verilog-2001 parsing. An override-IDCODE elaboration check also passes.
The final debug-enabled area/timing runs use the standard
`_build/syn_out/karudbg/{area_on,timing_on}/` locations. Both are complete;
the final FPGA timing result is pending. The full board build completed synthesis
and placement, then stopped during routing. It produced no new debug bitstream;
`_build/vcu118_ddr.bit` remains the previously validated October 6 image.
The baseline OOC result above does not establish final board timing or reset
recovery/removal. Those require the final FPGA/ASIC integration reports.

The final BSCAN constraint source starts at the hard primitive's
`INTERNAL_TCK`, then derives exported TCK and gated DRCK, including the hard
TDO return sampling edge. It excludes only the eight incoming asynchronous
reset pins of four two-stage reset-release helpers, in addition to the four
control synchronizer D pins and asynchronous core/DRCK hold checks. The
22 framing-reset **consumer** endpoints remain timed. Source SHA-256:
`68382ac99d4873f660a1d09fe0f0bcee6d4cacb5dd2a5ddf4b57f2e954d8f76c`.

Static Tcl command-model validation passes the exception/clock/bundle scope
checks and six fail-closed controls. This is not netlist selector or physical
timing validation. An earlier synthesis-checkpoint experiment verifies the
internal-clock component: hard TDO setup +49.236 ns and hold +48.725 ns, with
the debug no-clock/unconstrained endpoint findings removed. The original
board synthesis reports also show 22 timed framing-reset consumer paths,
with recovery +98.987 ns and removal -0.135 ns before placement. Those values
do not validate the full final constraint set or final routed removal.

The stopped implementation loaded the preceding constraint set. Its
intermediate timing results therefore do not establish physical closure
under the corrected constraints. Corrected routed validation has not been
performed. Reports and provenance are under `_build/dbg/board_synth_reports/`,
`bscan_clock_experiment/`, `fpga-constraints-static.log` and
`fpga-timing-followup.json`. The constraint-only fix does not change tested
functional RTL.

The full board synthesis uses 342,082 LUTs (28.94% of the VCU118 device),
88,677 registers, 317.5 block-RAM tiles and 29 DSPs. These totals include the
DDR, Ethernet and boot-ROM integration; they are not a core-only debug-area
comparison. Post-placement CPU setup slack is **+0.977 ns at 75 MHz**. The
longest CPU path is vector reduction control/data, `r[0]` to `red_pp1[43]`,
with 12.434 ns data delay, including 10.621 ns of estimated routing.
The global -0.581 ns path enters a reset-release synchronizer from another
clock domain; the final constraints narrowly exempt its asynchronous input.
The output-to-consumer reset paths remain timed. These are feasibility and
constraint-audit results, rather than routed closure or board acceptance.
Reports are under `_build/dbg/board_postplace_reports/` and
`_build/fpga_rpt/ddr_rva23s64_dbg_sgmii_75_rom__*`; the placed checkpoint is
`_build/vcu118_ddr_postplace.dcp`.

## ASIC initialization and memory scope

The maintained core-only audit and the combined debug audit use `KARU_ASIC`.
Both report **zero initialized state** and **97,024 data-array bits** in the
macro-candidate/register-file/scratch categories. The combined top retains
nine macro candidates, two 1W2R register files and four scratch arrays; its
small Program Buffer adds one control array (34 versus 33). The tracked
core-only inventory is not replaced by the combined report.

Small Yosys comparisons of the integer RF, FP RF and 1W1R/1W2R asynchronous
RAM leaves have identical synthesized primitive cell inventories with and
without `KARU_ASIC`; the ASIC variants remove their initialization attributes.
This does not substitute for a full `KARU_ASIC` area/timing comparison.

Evidence: `_build/dbg/asic-audit/` and
`_build/dbg/asic-audit-combined/`, including source/define manifests, elaborated
RTLIL, CSV/Markdown inventories and `summary.json`. The maintained ASIC startup
check also passes its four-state memory checks and randomized `vresv`, `vperm`
and `vstart` subjects at seeds 1 and 42.

## Reproduce

From the repository root, with the required tools on `PATH` and `KARU_LIB`
pointing to the typical NanGate45 Liberty:

```sh
make dbg-syn-area-off
make dbg-syn-area-on
make dbg-syn-timing-off
make dbg-syn-timing-on
make dbg-vivado-ooc VIVADO=/path/to/vivado
python3 flow/asic/audit.py --out _build/dbg/asic-audit
python3 flow/asic/audit.py --manifest dbg/karudbg.f --top karudbg_top \
  --define KARU_DBG --out _build/dbg/asic-audit-combined
```

Area/timing outputs use `_build/syn_out/karudbg/`; Vivado outputs use
`_build/dbg/vivado_ooc/`. Keep simultaneous full-vector Yosys jobs bounded by
available RAM; these area runs each peaked near 23 GB. The targets expose
`DBG_SYN_DEFINES`, `DBG_SYN_ROOT` and `DBG_TCK_PS` for explicit overrides.
