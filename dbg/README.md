# karudbg

karudbg is the opt-in implementation targeting RISC-V Debug 1.0 for Karu. It lives in
`karu64/dbg/` and is maintained as part of the karu64 repository. This document
tracks the implementation, testing plan and acceptance evidence. The opt-in
RTL and simulation targets have passed the functional gates below; board acceptance and a
Debug 1.0 compliance claim remain pending.

The base `KARU_DBG` configuration targets one RV64 hart using execution-based
debug with a Debug ROM and Program Buffer. Optional auto-execution, address
triggers and System Bus Access (SBA) are tracked in the
[extension implementation and testing plan](#extension-implementation-and-testing-plan).
`KARU_DBG_AUTOEXEC`, `KARU_DBG_TRIGGERS` and `KARU_DBG_SBA` select them
independently; `KARU_DBG_FULL` enables all three. The base configuration retains
the unsupported-feature fallback tests. The destination is an ASIC, with FPGA
validation; multi-hart support is out of scope.

The same update also includes the core/platform AXI protection-metadata work
required by [security review finding S1](../doc/security-review-2026-09-14.md#s1--high-axi-protection-metadata-does-not-describe-the-requester).
This is required for ordinary core traffic as well as debug-origin accesses;
it must work with `KARU_DBG` disabled. Deliver two ordered milestones in this
update: **A, AXI protection RTL and tests**, followed by **B, karudbg and its
integration tests**. Milestone A implements the bits and their propagation,
defines the platform mapping and passes `axi-prot-test` before debug integration
is accepted. Both milestones belong to the initial update. The implementation,
documented platform contract and tests for milestone A are complete. Platform
enforcement and board acceptance remain separate obligations.

## Progress checklist

The October 30 RTL registers the SBA issue hold to cut the new reset-to-trigger
feedthrough. Its combined functional gate passes, and the fresh full
two-trigger row restores input-to-register slack to +0.2328 ns. The complete
matrix and FPGA checklist below record the
October 29 checkpoint; that programming bundle is unchanged and does not
include this follow-up. See [current timing scope](MEASUREMENTS.md#registered-sba-pause--2026-10-30).

- [x] October 30 pause follow-up: combined source-hashed gate passes in 1,094.03 seconds with 274 unchanged inputs.
- [x] October 30 full two-trigger timing: input-to-register +0.2328 ns; register WNS −0.3978 ns, so the overall 200 MHz goal remains open.

October 29 checkpoint: autoexec, triggers and SBA pass the combined non-board gate on
the review-corrected source. The follow-up adds invariants, locked-SBA
discovery, scratch synchronization and the platform-cache completion handshake.
All six area and six timing rows were complete for that checkpoint;
the full two-trigger increment is 14.6147 kGE (+0.3316%). The 200 MHz goal
remains open, including a reset-input miss in the combined configuration.
The checkpoint FPGA image passes routed timing at 75 MHz. Checkpoint results are in
[measurements](MEASUREMENTS.md#extension-measurements--2026-10-29).
The 2026-10-29 image contains full two-trigger debug: whole-design setup/hold
slack is +0.010/+0.011 ns, CPU setup/hold +0.048/+0.011 ns, pulse-width
slack +0.005 ns, all 16 bus-skew constraints pass and bitstream DRC reports
zero errors. The packed karudeb inputs and programming bundle are verified;
board acceptance remains open. The base checklist
below records its reviewed checkpoint; the extension checklist records the
current implementation and evidence.
Check an item only when its implementation and
required tests are complete. Add source and result links beside completed
items; a documented design choice alone does not close an implementation item.

- [x] Record initial scope, specification review, adoption origins and design
  choices, including the mainline OpenOCD source baseline.
- [x] OpenOCD installation prerequisite: verify the pinned mainline build,
  runtime libraries, installed scripts and simulation adapters (2026-10-26;
  commands and version recorded in the [initial contract](#initial-contract)).
- [x] [Shared interface foundation](#1-shared-interface-foundation): build
  switch, core/DM interface, source manifests, provenance and license notices.
  See [combined source manifest](karudbg.f), [core integration](karudbg_core.v),
  [Solderpad license](LICENSE.Solderpad) and [ROM license](LICENSE.SiFive).
- [x] [Milestone A](#2-milestone-a-axi-protection-metadata): implement AXI
  protection propagation and the platform contract; pass `axi-prot-test` with
  debug disabled before accepting milestone B integration.
  Evidence: `make axi-prot-test`, 15/15 cases including five negative controls;
  reproducible logs and source hashes in `_build/dbg/axi-prot/results.json`.
- [x] DM register bank and abstract-command engine: implement the
  [initial contract](#initial-contract); pass `dbg-unit-test`.
  Evidence: 947 unit checks, including accepted-command channel reset and
  `ndmreset` abort/recovery; `_build/dbg/dm-unit.log`.
- [x] [Core Sdext and run control](#3-milestone-b-core-sdext-support-and-precise-run-control):
  implement halt/resume/step, debug CSRs and instruction rules; pass
  `dbg-core-test`, including rejected Program Buffer DRET.
- [x] [ROM and memory integration](#4-debug-rom-program-buffer-and-memory-integration):
  generate the ROM, enforce both aperture gates, support MMIO and pass
  `dbg-rom-test` and `dbg-memory-test`.
- [x] [Reset and conventional JTAG simulation](#5-reset-clock-crossing-and-jtag):
  verify reset domains and transport; pass
  `dbg-jtag-test` through pinned mainline OpenOCD/GDB.
  Evidence: 94 transport checks, four transport negative controls and the
  actual-core OpenOCD/GDB tests below. Physical CDC and FPGA integration have
  separate acceptance gates.
- [x] [Context and translation coverage](#testing-plan): pass
  `dbg-context-test` and complete `dbg-translation-test`, documenting supported
  mappings, tool limitations and debugger-policy differences.
  Evidence: shipping-profile context test and 28 OpenOCD translation checks;
  Svnapot software walks fail explicitly rather than returning a wrong HPA.
- [x] Functional acceptance: pass `dbg-test`, negative controls, four-state
  startup, lint and selected ordinary ISA regressions; rerun `axi-prot-test`
  with debug enabled. Publish the requirements-to-tests evidence.
  The historical base-debug aggregate passed in 293.86 seconds with unchanged input hashes.
  Ordinary ISA and ASIC startup checks are separate recorded runs.
- [x] FPGA platform integration: connect a board-compatible debug transport,
  retain the private debug aperture and reset contract, and verify the
  integration in simulation before board acceptance.
  USER4 nested-TAP, MMIO, GDB, translation and reset simulation pass on freshly
  compiled models. Standard-flow implementation has its separate gate below.
- [x] [ASIC inventory and mapped area](MEASUREMENTS.md): zero initialized
  state, unchanged data-memory geometry and the paired Yosys area estimate.
  The corrected conventional debug increment is 20.644 kGE (+0.471%);
  the post-review ASIC audit confirms zero initialized state and unchanged memory geometry.
- [x] [FPGA synthesis and timing acceptance](#synthesis-and-hardware-acceptance):
  standard-flow Vivado implementation at the 75 MHz core target, including
  corrected BSCANE2 clocks and narrow reset exceptions. Setup, hold, pulse width
  and all 16 bus-skew constraints pass; bitstream DRC reports zero errors.
  Evidence: `_build/vcu118_ddr.bit` and [routed measurements](MEASUREMENTS.md).
- [ ] 200 MHz mapped timing closure: the current OpenSTA results and path
  groups are recorded in [measurements](MEASUREMENTS.md).
  This ASIC performance goal is separate from the completed 75 MHz FPGA build.
- [ ] [Board acceptance](#synthesis-and-hardware-acceptance): demonstrate
  debug operations and MMIO, then normal karudeb boot and board acceptance
  after detach; record the tested configuration and compliance scope.

## Run the non-board gates

Run from the repository root. Tests need Verilator, Icarus, a RISC-V ELF
toolchain, RISC-V GDB, Python 3, Tcl 8.6 and the pinned mainline OpenOCD source/tools
described below. The isolated OpenOCD build also needs its normal Autotools
and Jim Tcl development dependencies. These prerequisites are installed for
the recorded validation; no board connection is used.

```sh
make dbg-test
```

This runs the bounded functional gates with three parallel make jobs and
records the command, tool identities, input hashes before/after, elapsed time
and overall result in `_build/dbg/validation.json`; detailed output is in
`_build/dbg/validation.log`. A source change during the run invalidates the
record. Set `DBG_GATE_JOBS` to adjust gate parallelism and `DBG_JOBS` for
the OpenOCD/model builds. Individual targets are listed below. Ordinary
`make test` remains the scalar ISA regression, separate from these debug gates.
Four-state trigger simulations have a configurable 240-second wall limit
(`DBG_TRIGGER_IV_TIMEOUT`); a timeout is a failure, and passing still requires
the test's explicit completion marker and all assertions.

The replay, build-binding, cycle-comparison and measurement helpers also have
bounded self-checks, including deliberately corrupted evidence:

```sh
PYTHONPATH=test/dbg python3 -m unittest \
  test_isa_replay test_htif_consumption test_idle_cycles \
  test_measurement_collector test_source_equivalence test_dm_equivalence
```

### Current combined validation record — 2026-10-30

`make dbg-test DBG_GATE_JOBS=3 DBG_JOBS=6` passed at 01:08 UTC in
1,094.03 seconds, including model rebuilds. All **274 captured input hashes**
match before and after the run. `_build/dbg/validation.json` records
`passed=true`, exit status zero, tool identities and source integrity;
`validation.log` contains the individual results. The helper self-checks above
also pass all 22 tests.

The gate covers base, independently enabled and combined extensions; native
OpenOCD/GDB and USER4 BSCAN; precise scalar/vector/guest triggers; SBA RAM/MMIO,
coherence and cancellation; mutation controls; four-state and six-seed ASIC
startup; seven build configurations; lint and reset constraints; and the
live-divider audit. Separate CPU replay passes 2872/2872 preserved ACT4
references and both 16-subject runs with identical idle cycle counts.
The [CPU replay record](#ordinary-isa-replay-with-debug-idle) explains its
reference and build-binding scope. Mapped results are in
[measurements](MEASUREMENTS.md#extension-measurements--2026-10-29).
This is pre-board evidence for the registered-pause RTL. The retained FPGA
image passed its own October 29 routed gate and has not been rebuilt with
this follow-up; hardware acceptance remains open. The prior functional
record is preserved in `_build/dbg/reset-pause/before-validation.json`.

### Historical base-debug validation record, 2026-10-26

The reviewed base conventional-JTAG and USER4 BSCAN implementation passed `make dbg-test`
in 293.86 seconds after rebuilding the generated models from a clean `_build`.
The run used committed review fixes at `175b842` and completed after the
hartinfo, exception-handler and reset-timing fixes.
At completion, `_build/dbg/validation.json` recorded exit status 0,
unchanged source hashes before/after, tool identities and the isolated OpenOCD
patch/build identity. That base run covered its recorded RTL, tests and build
inputs, including FPGA and conventional-top constraint sources. New runs replace
`validation.json` and `validation.log`; the old timing/counts below are historical
base evidence, not a validation claim for the current extension RTL. Functional
simulators do not execute the Vivado constraints; their scope is checked by the Tcl command-model test,
with separate OpenSTA netlist evidence recorded in [measurements](MEASUREMENTS.md).
Subsequent changes affecting a functional gate or its compiled models require
a new record.

| Check | Result and evidence under `_build/dbg/` |
| --- | --- |
| AXI protection, debug disabled and enabled | 15/15 cases each, including five source-mutation controls; `axi-prot/results.json`, `axi-prot-debug/results.json` |
| DM and abstract commands | 947 checks; `dm-unit.log` |
| TAP/CDC and debug-memory AXI | 94 transport checks and 813 AXI checks; four transport mutation controls |
| Scalar/FP actual-core debug | 186,580 checks, 285,376 cycles; `core/run.log` |
| Shipping-profile context debug | 587,501 checks, 890,049 cycles; `core-profile/run.log` |
| ASIC scalar four-state startup/debug | 163,115 checks, 250,381 cycles; `core-four-state/run.log` |
| AWREADY dependent on WVALID | 163,115 checks, 250,381 cycles; `core-aw-wait/run.log` |
| Core negative controls | Six source mutations detected: DPC, application trap leakage, wait instructions, unauthorized DRET, scratch corruption and extra stepping |
| OpenOCD actual-core memory/MMIO | Native-width transfers, counted side effects, block reads, faults and recovery pass; pristine-tool autoexec failure retained as a negative control |
| OpenOCD software translation | 28 checks; `openocd-translation/openocd-jtag.log`; unsupported Svnapot walks report errors |
| GDB 17.2 | GPR/CSR/RAM, 64-bit FP and 256-bit vector transfers, code update, exact stepping and detach/reconnect pass; `gdb/gdb-registers.log`, `gdb/gdb-context.log` |
| USER4 BSCAN | 1,680 protocol checks, including 481 reset/pause cases; three negative controls, 48 reset-release checks and 18 FPGA reset-ordering checks; actual-core OpenOCD, GDB and 28 translation checks pass |
| Conventional reset timing constraints | Tcl command-model scope checks, two bad-exception mutations and three fail-closed guards pass; `make dbg-ooc-reset-constraints-test` |
| Parsing and lint | Declaration-order, Verilator and strict Verilog-2001 checks pass |
| Separate ordinary ISA regression | `make test`: 110/110; `riscv-tests.log` |
| Separate ASIC checks | Four-state memory checks and `vresv`, `vperm`, `vstart` at seeds 1 and 42 pass; see [measurements](MEASUREMENTS.md) for inventory evidence |

The full-profile FP/vector tests use Verilator's two-state model with explicit
state initialization and round trips. Four-state core coverage is the scalar
ASIC/no-F configuration. Twenty isolated interrupt cases cover M/S/VS software,
timer and external sources, Sstc comparators and LCOFI routed to M/HS/VS. Each
checks masking in Debug Mode and single-step, preserved pending state and later
delivery. Long-operation crossings use MTIP; this is not an exhaustive
cross-product of every interrupt priority, delegation and long operation. Application
trap canaries cover machine trap state and H metadata, rather than every banked
VS CSR. No full ACT4 rerun, physical JTAG, FPGA board boot or silicon CDC signoff
is implied by these results. FPGA integration and synthesis have their own
checklist gates and measurement records.

The combined ASIC handoff is [karudbg.f](karudbg.f), or source
[sources.tcl](sources.tcl) for tool-neutral `karu_sources`,
`karu_include_dirs`, `karu_defines` and `karu_top`. The processor-only top remains `karu64`; optional debug modules elaborate
away when their switches are disabled. Generated ROM output is checked against
[its assembly source](rom/karudbg_rom.S); do not edit the encoded ROM by hand.

The [ASIC guide](../flow/asic/README.md) records the conventional source and
feature selection, common-clock/fabric assumptions, reset/CDC timing scope,
maintenance clock requirements and remaining scan/technology obligations.
`make dbg-config-matrix-test` emits strict parser/lint evidence for all seven
feature configurations; `make dbg-asic-random-test` reuses one full-profile
ASIC simulator across six startup seeds. These checks complement four-state
coverage and the memory-initialization audit; they do not replace foundry
macro binding, physical timing or DFT signoff.

## Specification and implementation origins

The normative reference is the ratified
[RISC-V Debug Specification v1.0, revised 2025-02-21](https://docs.riscv.org/reference/debug/v1.0/):

- [Debug Module and abstract commands](https://docs.riscv.org/reference/debug/v1.0/debug_module.html).
- [Sdext: Debug Mode, stepping, debug CSRs and resume](https://docs.riscv.org/reference/debug/v1.0/Sdext.html).
- [JTAG Debug Transport Module](https://docs.riscv.org/reference/debug/v1.0/dtm.html).
- [Sdtrig](https://docs.riscv.org/reference/debug/v1.0/Sdtrig.html), for address
  matching and the base configuration's absent-trigger behavior.

The adoption reference is
[pulp-platform/riscv-dbg at `643607e19df3435cfd77cc56143e2637f5900a6e`](https://github.com/pulp-platform/riscv-dbg/tree/643607e19df3435cfd77cc56143e2637f5900a6e).
That implementation advertises Debug 0.13.2. It provides a useful execution-based
design and verification material, but its version declaration and existing
tests do not establish Debug 1.0 compliance for karudbg.

karudbg adopts selected PULP modules into Karu's coding conventions and
interfaces. It is not maintained as a fork or submodule, and does not promise
upstream source or interface compatibility. For every adopted file:

- Record the original path, revision and source URL in its header, together
  with a short description of the adaptation.
- Retain applicable upstream copyright, SPDX and license notices. Include the
  required license texts when the first derived source is added. PULP sources
  use Solderpad Hardware License 0.51 and the ROM carries the SiFive Apache-2.0
  notice; the root BSD license must not be presented as replacing those terms.
- Track origins and intentional behavioral differences in this README as
  modules land. Review later upstream fixes individually.
- Adopt only the required helpers. Any retained third-party helper must have
  the same provenance and license treatment; avoid importing an entire support
  library for one primitive.

| Function to adopt | PULP reference | Karu adaptation |
| --- | --- | --- |
| DM register bank | `src/dm_csrs.sv`, `src/dm_pkg.sv` | Single hart; Debug 1.0 register behavior; optional autoexec and SBA registers |
| SBA register/transaction engine | `src/dm_sba.sv`, `src/dm_csrs.sv` | Portable native-width request interface, success-only increment and explicit ownership during DM deactivation |
| Abstract-command engine and debug memory | `src/dm_mem.sv` | RV64 transfers, Karu interfaces and exception protocol |
| Parking/command/resume ROM | `debug_rom/debug_rom.S`, `debug_rom/debug_rom.sv` | Two scratch CSRs; relocatable nonzero debug page; reproducible ROM generation |
| JTAG DTM and CDC | `src/dmi_jtag.sv`, `src/dmi_jtag_tap.sv`, `src/dmi_cdc.sv` | Local RTL conventions, explicit clock/reset contract and transport tests |
| FPGA transport reference, not adopted | `src/dmi_bscane_tap.sv` | Direct USER-chain protocol differs from mainline OpenOCD; Karu's original USER4 nested-TAP bridge implements the required framing |

## Initial contract

This table describes the base `KARU_DBG` configuration. The optional
[implemented SBA contract](#implemented-sba-contract) and extension checklist
record the additional feature configurations separately.

| Item | Initial scope |
| --- | --- |
| Harts | One hart, RV64; match Karu's `mhartid` and document hart-selection WARL behavior |
| Core configurations | RVA23S64 shipping geometry first, including H, FP, V and optional Zvk/Keccak; debug-disabled builds remain supported |
| Hart-facing data path | 64-bit, through the existing instruction/data memory interfaces |
| DMI | 32-bit register accesses; one DM; backpressure and sticky transport errors handled explicitly |
| Version fields | Implement `dmstatus.version=3`, `dtmcs.version=1`, `dcsr.debugver=4` from the first RTL revision; keep the compliance claim provisional until the acceptance gates pass |
| Run control | Halt, resume, single step, EBREAK entry, and halt before the first instruction when `haltreq` is held across reset |
| Debug CSRs | `dcsr`, `dpc`, `dscratch0`, `dscratch1`; accessible only in Debug Mode |
| Abstract commands | Access Register with 32- and 64-bit reads of RV64 GPR/CSR views, full-width writes, and `postexec`; define every exposed register's width and reject oversized/reserved accesses |
| Abstract data | Two 32-bit data registers for a 64-bit argument |
| Hart information | `hartinfo=0x00200000`: two scratch CSRs, no advertised data-register CSR/memory shadow (`datasize=0`); the private ROM still accesses its internal data window |
| Busy run control | Ignore `haltreq` (including zero), `resumereq` and `ackhavereset` writes during an abstract command, as Debug 1.0 recommends; `dmactive` and `ndmreset` remain available for recovery |
| Auto-execution | `abstractauto` unimplemented: read zero, ignore writes; data/Program Buffer accesses never implicitly re-execute a command |
| Program Buffer | Eight 32-bit words initially; explicit terminating EBREAK, `impebreak=0` |
| Debug access checks | `abstractcs.relaxedpriv=0`; ordinary M-mode permission and instruction-state checks apply |
| Memory access | Instructions executed by the halted hart; no independent system-bus manager |
| Peripheral access | Required: physical MMIO reads/writes through the Program Buffer and the hart's normal memory path |
| AXI protection | Milestone A: meaningful `ARPROT`/`AWPROT`, static trusted per-hart Secure/non-secure selection, and preservation of transaction attributes end to end |
| SBA | Base configuration: `sbasize=0`, absent registers read zero and ignore writes, no SBA requests. `KARU_DBG_SBA` adds the [independent manager](#implemented-sba-contract) |
| Triggers | Base configuration: absent CSRs. `KARU_DBG_TRIGGERS` adds two (optionally four) debugger-owned Sdtrig 1.0 address slots; see the [supported contract and tests](TRIGGERS.md) |
| Optional DM features | No hart arrays/groups, Quick Access, Access Memory command, or separately programmable reset-halt request |
| Availability fields | `stickyunavail=0`: report current availability; `ndmresetpending=0` as an unimplemented optional field; `havereset` remains sticky |
| Absent core features | `dcsr.cetrig`, `dcsr.pelp` and `dcsr.nmip` read zero; no Smdbltrp, Zicfilp or NMI source in the initial configuration |
| Authentication | No authentication protocol initially; advertise that accurately. Define a platform enable/lock policy before deployment |

The core's `debug_resume_ack_o` is the same-clock DRET acceptance event,
sampled by the DM on the edge that leaves Debug Mode. It deliberately has no
additional acknowledgement register or extra cycle of run-control latency.
INV40 checks this pulse contract alongside precise trigger entry and the SBA
maintenance request/acknowledgement history. Direction-filtered vector arming
and fetch-fault trigger admission during an SBA pause are covered by
`dbg-trigger-review-test`; `dbg-trigger-invariant-test` checks independent legal
sequences and 15 corrupted-observation controls. See the
[trigger verification contract](TRIGGERS.md) for their scope.

The compliance target is the full external-debug specification using its
Program Buffer option, rather than the separately defined "Minimal RISC-V
Debug Specification". SBA and hardware triggers are optional. The Program
Buffer must actually support the operations needed to access Karu's implemented
state; GPR access alone is not the acceptance criterion.

For the first core implementation, use `stepie=0`, `stoptime=0` and
`mprven=0`. This disables interrupts during stepping, leaves platform time
running, and gives debug load/store instructions physical M-mode accesses
without an interrupted MPRV setting translating the ROM's own handshake
loads/stores away from the debug page. This is a deliberate permitted departure
from the specification's recommendation to use `mprven=1`. Hardware-translated
debugger accesses are deferred; configure the debugger to translate virtual
addresses in software or use explicit physical addresses.

Use mainline OpenOCD: the archived `riscv-openocd` fork directs ongoing RISC-V
development upstream. The initial source-review baseline is
[mainline `cb0c224e936091156ecf3025ba05657408ed64c8`](https://github.com/openocd-org/openocd/blob/cb0c224e936091156ecf3025ba05657408ed64c8/src/target/riscv/riscv.c#L3200)
(2026-10-24), which implements software VS/G-stage translation, including
G-stage translation of VS page-table reads. Native autoexec, SBA and hardware
trigger interoperability tests use this pristine pin. Base-DM fallback and
software-translation tests use the pin plus the repository's
[OpenOCD compatibility patch](openocd-no-autoexec.patch). Record the selected
revision, patch and binary hashes; hardware autoexec support does not remove
the patch's independent software-walker safeguards. Software translation is
not automatically equivalent to hardware MPRV permission,
A/D, PBMT or pointer-masking behavior; document the supported debugger contract.

The OpenOCD installation prerequisite was verified on 2026-10-26. The binary
at `$RISCV/bin/openocd` reports
`Open On-Chip Debugger 0.12.0+dev-02773-gcb0c224e9`; the source revision matches
the full pin above. Scripts are installed under
`$RISCV/share/openocd/scripts`, runtime libraries resolve, and `remote_bitbang`,
`jtag_vpi` and `jtag_dpi` are available. Recheck the version and adapters with:

```sh
openocd --version
openocd -c 'echo [adapter list]; shutdown'
```

The pristine tool passes the transport/DM connection test. Its block Program
Buffer memory path assumes optional autoexec support and fails the deliberate
`dbg-openocd-negative-test` against the base `KARU_DBG` configuration's
advertised absence. Native block transfers pass when `KARU_DBG_AUTOEXEC` is
enabled. The isolated compatibility build probes autoexec and uses explicit single-element commands
when unavailable, avoiding speculative or trailing MMIO accesses. It also
rejects misaligned superpage PTEs and unsupported Svnapot software walks instead
of returning data from an incorrect HPA. These are debugger changes; Karu's
hardware Svnapot support is unchanged.

`make dbg-openocd-build` exports the pinned mainline source from
`OPENOCD_SRC` (default `$HOME/rv/src/openocd`) and builds under
`_build/dbg/openocd/`. Installed tools and the source checkout are not modified.
The manifest records the base revision, patch hash and binary hash. The patch
modifies GPL-2.0-or-later OpenOCD sources and retains their upstream notices;
it is not relicensed under the repository's BSD license. GDB acceptance uses
the installed RISC-V GDB (17.2 in the recorded run).

Implement `stopcount=1` to freeze all hart-local counters, including HPM
counters, while in Debug Mode. Time continues running. Define and test the WARL
behavior of other `dcsr` fields, including the H-specific privilege and EBREAK
controls. Preserve pending interrupts; counter freeze prevents new automatic
counter-overflow events, not explicit debugger writes to pending state.

Access Register must support every defined read size up to the actual width
of an accessible register, including `aarsize=2` reads of a 64-bit GPR or CSR.
A 32-bit read updates `data0` with the low 32 bits and leaves `data1` unchanged.
Publish the actual width of each exposed register. Initially support only
full-width writes: reject narrower writes, oversized accesses and reserved
`aarsize` encodings with `cmderr=not supported`, preserving the target register.
Full-width writes to read-only registers retain their architectural access
rules. With `transfer=0`, ignore transfer-only fields as specified and execute
`postexec` exactly once when requested.

The implemented abstract views are 64-bit GPRs and RV64 CSR views, with 32-bit
reads supported for each. ROM-owned `dscratch0`/`dscratch1` are excluded from
abstract transfers (`cmderr=not supported`); FP and vector abstract register
numbers are also unsupported. Those registers remain accessible through the
Program Buffer. Do not assume scratch CSR contents persist across the ROM's
own save/restore sequences.

## Memory-mapped peripheral access

Access to other memory-mapped peripherals is a required initial feature.
The debugger supplies an address and data through abstract register transfers,
then executes a scalar load or store followed by EBREAK in the Program Buffer.
Read results are returned through a GPR and the abstract data registers. The
hart performs the actual bus transaction, using its normal LSU and platform
interconnect. This can access mapped CLINT, PLIC, UART, Ethernet and other
peripherals according to their supported access widths and PMA permissions.

With the initial `mprven=0` policy, these are physical M-mode accesses. Use
explicit 8-, 16-, 32- or 64-bit scalar accesses as supported by the device;
do not turn a device-register read into a cache-line or vector read. Preserve
the working GPRs and enforce the existing device ordering and byte-lane rules.
Read-to-clear, FIFO-pop and write-one-to-clear registers require exactly the
requested accesses: DMI polling, retries and command completion must not
repeat a load/store or introduce a read-modify-write. Do not enable abstract
autoexec: `abstractauto` reads zero and ignores writes in the initial design,
including writes from OpenOCD. Test the tool's fallback for both one-element
and block reads, with no access past the requested elements. Report bus/access
faults through the debug-command exception path without changing application
trap state.

This mechanism works while the hart is architecturally halted but executing
debug commands. It requires the hart, its clock, memory path and target
peripheral to be operational. It cannot access peripherals while the hart is
held in reset or cannot execute the debug program, and does not provide
independent peripheral access while the application continues running.
Independent access while the application runs is provided by optional
`KARU_DBG_SBA`, subject to its [bus/reset contract](#implemented-sba-contract).
The current combined integration resets the SBA adapter with the hart and
affected fabric, so it does not service requests while those resets are asserted.

## Implementation sequence

### 1. Shared interface foundation

- Use `karudbg` for the DM top and `karudbg_*` for helpers under `dbg/`.
  Keep synthesizable RTL
  compatible with the existing Verilog-2001, Vivado, Yosys and Genus flows:
  declarations before use, separate net declarations and assignments, no
  power-up initializers, and no inferred latches or variable-input division
  or remainder operators.
- Define the opt-in `KARU_DBG` build switch in the normal extension
  configuration. It must not be implied by `KARU_RVA23S64`.
- Keep DM/DTM logic outside the processor's architectural CSR block. Define
  the halt-request and Debug Mode interface before changing core issue logic.
- Bring up the DM with a direct DMI bus-functional model first. JTAG must not
  be required to diagnose the DM or core state machine.
- Add a dedicated debug source manifest. The existing core-only ASIC manifest
  must keep its stated scope; add a separate combined integration top/manifest.

### 2. Milestone A: AXI protection metadata

Implement the requester metadata required by security review S1 first, with
debug disabled. Follow the
[AMBA AXI protection encoding, section A4.7](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf):

| Attribute | Encoding and implementation requirement |
| --- | --- |
| `AxPROT[0]` | 0 = unprivileged, 1 = privileged. Use the effective access context; ordinary U/VU accesses are unprivileged and S/HS/VS/M accesses are privileged |
| `AxPROT[1]` | 0 = Secure, 1 = Non-secure. Use the trusted per-hart `NONSECURE` parameter, default 1; RISC-V privilege does not select this domain |
| `AxPROT[2]` | 0 = data, 1 = instruction. Mark actual fetches as instruction accesses; PTE reads are data accesses even when emitted on the instruction AXI port |

The initial platform contract is deliberately limited and must accompany the
ASIC handoff and FPGA integration:

- `NONSECURE` is trusted elaboration-time platform configuration, shared by
  all accesses from the hart and fixed for that build. Debug entry does not
  change it. The tests use separate elaborations for values 0 and 1. No mutable
  domain input or runtime switching is implemented. A future reset-sampled
  strap would require quiescing/cancelling old requests and invalidating
  caches/TLB/PWC state before traffic under a changed domain.
- Privilege-based peripheral firewall rules apply only to regions forced
  non-cacheable for both fetch and data by the trusted physical map. Existing
  non-RAM/MMIO bypass paths are the initial targets. PBMT NC/IO also bypasses
  caches, but software-controlled PBMT alone is not a security boundary: a
  protected region must not be reachable through a cacheable alias.
- On cacheable RAM, `AxPROT[0]` reports the privilege of the access that caused
  a line fill and is advisory to the platform. Privilege-dependent read denial
  for that region cannot rely on an external firewall because later read hits
  do not go to the bus. Internal MMU permissions remain enforced. Write-through,
  no-write-allocate stores reach the bus with their own attributes.
- This static-domain contract permits existing cache tag and TLB/PWC formats
  to remain unchanged. It does not provide dynamic security domains or external
  M-versus-HS/VS isolation. `AxPROT` encodes only privileged/unprivileged,
  Secure/non-secure and instruction/data; do not overload these bits with
  debug identity or walk stage.

AXI USER or trusted parallel context sidebands, context-tagged caches, and
additional TLB/PWC partitioning are conditional later work. They become required
before a platform enforces rules on cacheable read hits or depends on requester
distinctions absent from `AxPROT`. Such a platform needs an approved reuse and
invalidation contract before it can use that policy. The initial debug aperture
still needs its explicit local debug-origin authorization.

- Cover every request producer: IFU, scalar LSU, vector LSU, I/D-cache
  misses and bypasses, atomics, CBOs, and both page walkers. A top-level mux
  alone cannot recover metadata that an inner module has discarded.
- Include MPRV/MPP/MPV and HLV/HLVX/HSV in the effective privilege calculation.
  HLVX is a data load, so `AxPROT[2]=0` despite its execute-permission check;
  HLV and HSV are also data accesses.
  PTE reads are privileged data transactions within the hart's fixed security
  domain; document host, VS and G-stage walk behavior. Ordinary guest/user
  data requests must retain their own effective privilege. Milestone B adds
  physical M-mode debug accesses within that same fixed security domain.
- Latch context when a request is accepted. Carry it with posted/queued
  vector stores, split accesses, bursts, outstanding walks and cached
  requests; never reconstruct it from live CSRs at a later bus handshake.
- Preserve attributes through `karu_ifu`, `karu_lsu`, `karu_mem`,
  `karu_icache`, `karu_sv39`, core arbiters, platform crossbars, width
  converters. Remove active-path constant protection assignments and
  ignored-input treatment where appropriate. Milestone B must carry the same
  attributes through the new debug-memory adapter.
- Validate cache behavior against the stated physical-map contract. Prove that
  privilege-protected peripheral addresses cannot allocate or hit in either
  cache, including through alternate mappings. Keep cacheable RAM read policy
  independent of privilege-based downstream denial in the initial integration.
- Keep all attributes stable with AR/AW while VALID is asserted, including
  under stalls, privilege changes, debug entry/exit and request arbitration.
- Propagate firewall rejection as the proper bus/access fault. While executing
  a debug command, report it through the command exception path. Do not retry
  side-effecting MMIO requests automatically.

This work supplies trustworthy metadata and its integration contract. It does
not by itself implement PMP, a firewall, register scrubbing or secure boot;
the other findings in the security review retain their own acceptance criteria.

### 3. Milestone B: core Sdext support and precise run control

The main integration points are `rtl/karu64.v`, `rtl/karu_csr.v`,
`rtl/karu_dec.v`, `rtl/karu_uop_defs.vh` and the IFU redirect interface.

- Add explicit Debug Mode state, `DRET` decoding, debug CSR permissions, and
  the `dcsr` entry-cause/privilege/V-state rules. DRET outside Debug Mode must
  raise an illegal-instruction exception.
- Latch halt requests independently of interrupt-enable and delegation bits.
  Stop accepting new normal instructions and reach a precise boundary after
  older work drains. Include scalar/vector memory operations, posted stores,
  page walks and cache maintenance in the boundary analysis.
  Once observed, a request remains latched until entry; clearing DM `haltreq`
  does not cancel it. The platform must bound active-instruction and memory
  completion latency to meet the specification's one-second halt-response
  requirement. This initial implementation does not abort a hung AXI slave.
- Initially finish an active vector/crypto instruction before halting; do not
  introduce mid-instruction preemption. Preserve existing restart state.
- Capture the next architectural instruction address in `dpc`, accounting for
  compressed instructions, taken branches, jumps, traps and returns. Do not
  require a successful fetch at that address before honoring a halt request.
- Reuse IFU redirect/discard machinery to handle outstanding responses without
  committing stale instructions. Keep AXI payload stable under backpressure.
- Implement stepping as one instruction or trap, not simply one
  `perf_retire` pulse. A stepped fault enters its normal trap handler and then
  halts before executing a handler instruction. Mask interrupts as required
  by the chosen `stepie` value.
- Route EBREAK/C.EBREAK to Debug Mode according to `dcsr`; otherwise retain
  the architectural breakpoint exception. Use the specified priority between
  simultaneous debug-entry causes and exceptions.
  For implemented simultaneous causes, use `haltreq` before EBREAK before
  single-step, matching [Debug 1.0 Table 8](https://docs.riscv.org/reference/debug/_attachments/riscv-debug-specification.pdf#page=57).
- On an authorized ROM-resume DRET, restore `dpc`, privilege and virtualization
  state and clear MPRV when returning below M-mode. Do not use or overwrite
  application trap CSRs as storage for debug entry.
- Freeze hart-local counters according to `stopcount`; do not freeze CLINT
  time. Freeze `cycle`, `instret` and all HPM increments and automatic overflow
  generation in Debug Mode, preserving pre-existing pending/OF state and
  ordinary explicit CSR-write semantics.
- Mask every implemented interrupt source in Debug Mode: machine external,
  software and timer; supervisor external/software/timer and LCOFI; virtual
  supervisor external/software/timer and delegated LCOFI. SGEIP is zero in
  the current GEILEN=0 configuration, and no NMI source is implemented. With
  `stepie=0`, mask interrupts during a single step too; retain pending state
  for subsequent normal execution.
- A halt request during WFI, WRS.NTO or WRS.STO completes the waiting
  instruction and then enters Debug Mode. Stepping over any of them treats it
  as a NOP. They also act as NOPs when executed in Debug Mode.
- Clear the LR/SC reservation on Debug Mode entry, without discarding prior
  memory effects. An SC after resume must fail unless a new LR establishes a
  reservation; exercise this for both W and D forms.

The Program Buffer uses the Sdext execution rules, with these explicit Karu
choices. Test the choices independently of ordinary M-mode execution:

| Instruction class in Debug Mode | Karu behavior |
| --- | --- |
| WFI, WRS.NTO, WRS.STO | Retiring NOP; no wait state |
| ECALL, MRET, SRET | Terminate the command through the debug exception path with `cmderr=exception`; leave application trap and return state unchanged |
| DRET | Honor only at the immutable ROM's designated resume instruction, during an authorized resume sequence; otherwise take the debug exception path, report `cmderr=exception` for an active command, and remain in Debug Mode |
| Branches, JAL and JALR | Support destinations inside and outside the Program Buffer, subject to ordinary fetch access checks; remain in Debug Mode |
| AUIPC and other implemented PC-dependent instructions | Support their defined operation using the debug execution PC; the adopted ROM itself relies on AUIPC |
| EBREAK/C.EBREAK | End the command and return to the parking loop without overwriting the saved DPC/cause |
| Other implemented instructions | M-mode baseline plus the Sdext overrides, selected `mprven`/`relaxedpriv` policy and existing instruction-state checks |

This selects support for both classes of control transfer and for PC-dependent
instructions; do not introduce ad-hoc optional-illegal cases that violate the
specification's all-or-none rules. ECALL/MRET/SRET behavior in Debug Mode is
UNSPECIFIED by the specification; the command-exception choice above is a
defined Karu contract, not an architectural trap into the application.

The specification's informative Appendix A.2 describes DRET outside Program
Buffer execution. Karu's ROM-only DRET rule is an implementation choice, not
a requirement that every Debug 1.0 hart use this ROM protocol. Qualify DRET
using the executing instruction's PC and the resume phase, not the live fetch
address. An accepted DM resume request and the ROM's RESUMING handshake must
authorize the exit; a command jumping to the ROM's DRET must not bypass this
sequence. Confirm the core's actual exit before acknowledging resume and
reporting it running. A rejected DRET must preserve saved DPC, privilege/V
state and the DM's halted status.

The normal command-exception entry remains `BASE+0x810`. Its handler saves
the current `a0`/`s0` before reporting the exception, preserving completed
Program Buffer or external-code writes, including a transfer followed by a
failing `postexec`. Faults in the generated transfer sequence
`[BASE+0x338, BASE+0x360)` use `BASE+0x890` instead and restore the borrowed
registers from their saved values. Selection uses the executing instruction's
PC. DRET remains at `BASE+0x888`; both exception entries are generated and
checked from the shared ROM/map sources.

### 4. Debug ROM, Program Buffer and memory integration

- Allocate a dedicated 4 KiB debug page outside existing ROM, scratch RAM and
  peripheral regions. Do not use PULP's default `0x1000`, which conflicts with
  Karu's boot ROM. Fix the page and entry offsets in one shared definition used
  by the core, platform decoder, ROM generator and tests.
- Support instruction fetch and data access to that page. Keep its dynamic
  Program Buffer, command instructions, data and handshake locations uncached.
  Existing low-address cache bypass is useful, but verify both I and D paths.
- Add an AXI slave adapter for the debug memory interface. PULP's simple
  request/data interface is not directly AXI. Handle independent AW/W arrival,
  byte enables, response holding and simultaneous instruction/data requests
  without duplicating a side effect or dropping a response.
- Enforce two independent debug-aperture gates. The core's PMA/access check
  permits the page only in Debug Mode, rejecting normal M/S/U/VS/VU accesses.
  The platform decoder routes the page only from the core's instruction and
  data ports; every other bus master receives a decode error with no DM
  request or side effect. PULP's DM slave interface carries no requester
  identity, so it cannot enforce that second gate internally. Check trusted
  source identity before arbitration discards it; `AxPROT` does not identify
  debug traffic. Check authorization when accepting a request and retain it
  until completion, including across mode transitions.
- Adopt the two-scratch ROM sequence and check preservation of its working
  registers. Build the ROM from assembly and compare generated contents in
  tests; do not maintain unrelated assembly and encoded copies by hand.
- While in Debug Mode, suppress architectural trap entry. Redirect command
  exceptions to the ROM exception path and report `cmderr=exception`; normal
  EBREAK termination must return to the parking loop without an exception
  error or overwriting the saved `dpc` and entry cause. Preserve application
  trap CSRs, including H trap metadata.
  This preserves completed instruction effects: [Debug 1.0 section 4.1(4)](https://docs.riscv.org/reference/debug/_attachments/riscv-debug-specification.pdf#page=53)
  explicitly permits partial vector destinations and `vstart` updates on a
  vector load/store fault. It does not require register rollback.
- Validate FP, vector and custom instructions through the Program Buffer.
  Apply the Sdext choices above, including ordinary FS/VS checks where
  applicable; save and restore any debugger-modified `mstatus`, vector
  configuration and working registers in the debugger/test sequence.
- Provide debugger memory-access sequences for scalar MMIO reads and writes.
  Confirm that the selected OpenOCD/GDB configuration uses the Program Buffer
  when SBA is absent, including explicit device access widths and error reports.
- Handle FENCE/FENCE.I and debug code updates explicitly. SBA being absent
  does not remove the need to synchronize instruction fetch after code writes.

### 5. Reset, clock crossing and JTAG

- Retain Karu's active-high synchronous core reset. System-clock karudbg
  control uses the same convention, with a separate debug reset domain so
  `ndmreset` cannot reset the DM, DMI or DTM that issued it.
- Define power-on, DM activation, transport reset and non-debug reset
  separately. Report `havereset` for every hart reset cause, not just requests
  initiated through the DM, and report hart unavailability during reset.
- `karudbg_core` resets its AXI ownership state with the hart. Its external
  responders/interconnect must share that cancellation reset, or be quiesced
  before reset, so no pre-reset response can be consumed as a new transaction.
  Hart-only reset with uncancelled external traffic is not supported.
- Honor a pending halt request before the first architectural instruction
  after reset. The optional reset-halt control bits may remain unimplemented.
- Adopt and verify the transport CDC handshake and reset flushing. TCK-domain
  reset behavior, including optional asynchronous TRST, is a separately
  documented transport requirement; do not change core reset semantics to
  match PULP's reset ports.
- Provide a conventional JTAG TAP for ASIC integration and remote-bitbang
  simulation. Check IDCODE, BYPASS, DTMCS, DMI, busy/error recovery and reset.
- Evaluate the FPGA BSCAN transport separately. PULP uses USER chains 3 and 4;
  establish compatibility with the board, Vivado debug IP and OpenOCD before
  assigning them. State whether that integration is the standard JTAG DTM or
  a custom transport, as required by the specification.

The DMI channel's reset contract permits withdrawing an unaccepted request or
pending response during `dmi_reset`. Connect the CDC's `dmi_reset_o` to the
DM's `dmi_reset_i`: the DM gates request-ready low during that reset and
discards the response-channel state. An already accepted command is not
undone. A substitute DMI endpoint must honor the same cancellation contract;
ordinary ready/valid rules apply outside reset.

The reserved DMI operation `op=3` produces sticky failed status without a DM
request. A failure response coincident with Capture-DR may instead leave
sticky busy status; this permitted transport choice does not promise retention
of the original failure code. Recovery uses the documented DTM status/reset
protocol. The private core-only memory bridges tie `allow_i` high because
their source identity is fixed by routing and ordinary-mode access is blocked
by the core PMA. The reusable adapter retains the authorization input for
integrations that need it; `AxPROT` does not identify debug origin.

The conventional TAP is tested through remote bitbang. Its parameterized
default IDCODE `0x00000db3` is the inherited PULP
integration/test placeholder, not an assigned Karu manufacturer identity.
ASIC integration must supply the appropriate assigned platform IDCODE.
Mainline OpenOCD's `riscv use_bscan_tunnel` implements a SiFive-style nested
TAP/data-register tunnel; it is not the PULP direct USER3-DTMCS/USER4-DMI
transport. The PULP BSCANE2 wrapper is therefore not imported as a drop-in
board solution. The original Karu [BSCAN tunnel](karudbg_bscan_tunnel.v)
instead implements the mainline nested-TAP framing on USER4, with a
[BSCANE2 wrapper](karudbg_bscan.v). Simulation covers the outer FPGA TAP,
pause/deselection, reset recovery and actual-core OpenOCD memory/MMIO access.
`make dbg-bscan-full-test` separately builds the full-profile/full-extension
composition and runs the native OpenOCD Program Buffer, trigger and SBA
scenarios, plus actual GDB hardware watchpoints, through that outer TAP. The
2026-10-29 run passes all four sessions, including counted-MMIO command-cache
recovery and actual GDB watchpoints. Its separate model and
flag record are under `_build/dbg/obj_bscan_core_full/`, with results under
`_build/dbg/bscan-full-*`. This covers the default full debug FPGA composition
in simulation; it is separate from a physical cable/board acceptance.
The two-edge reset-release conditioner works with stopped clocks; FPGA reset
ordering keeps the DM alive and holds the hart until the UI-side AXI responders
leave reset. Physical board transport acceptance remains pending.

The optional standard-flow target is:

```sh
make vcu118-ddr-sgmii-rom-rva23s64-dbg
```

It uses the existing karudeb profile ROM inputs and `_build/vcu118_ddr.*`
locations. USER4 is reserved for karudbg; the conflicting JTAG-AXI host-debug
configuration is rejected. [vcu118.cfg](vcu118.cfg) configures mainline OpenOCD
after an appropriate adapter configuration. This target defaults to
`KARU_DBG_FULL`; set `VCU118_DBG_EXT_DEFINES=` for base debug. The combined image
uses the pinned pristine OpenOCD for native autoexec/SBA block accesses;
base-DM Program Buffer blocks need the fallback patch. Software translation
retains the separately documented patched-walker policy. The FPGA TAP has IR length 6 and
USER4 opcode `0x23`; the tunneled RISC-V TAP has IR length 5. This optional
target is separate from the conventional-TAP OOC measurement and requires its
own implementation and board acceptance evidence.

## Testing plan

Keep test sources and harnesses in the repository, primarily under
`test/dbg/`, with shared firmware under `test/fw/` where appropriate. Put
generated models, ROM outputs, traces and reports under `_build/dbg/`.
Document exact commands, tool revisions, configuration flags and expected
results. The functional targets below are implemented; synthesis and board
acceptance are separate gates.

| Gate | Required coverage |
| --- | --- |
| `axi-prot-test` | Milestone A with debug disabled: effective privilege, fixed Secure/non-secure domain, request producers, cache contract, queues, stalls and peripheral firewall denial; extend and rerun with debug in milestone B |
| `dbg-unit-test` | DM CSR reset/WARL/read-only behavior; native/narrow reads and rejected writes; hart selection; current availability; activation; absent/autoexec registers; DMI backpressure; abstract-command errors and recovery |
| `dbg-autoexec-test` | All ten autoexec enables, read/write ordering, backpressure, busy/error behavior, exception recovery and reset cancellation |
| `dbg-autoexec-core-test`, `dbg-autoexec-gdb-test` | Native pinned OpenOCD/GDB with autoexec enabled; RAM blocks, exact MMIO counts, FP/vector registers and reconnect |
| `dbg-sba-unit-test` | SBA register/engine tests at 32/64-bit advertised address widths, DMI integration and negative controls |
| `dbg-sba-bus-test` | Core/SBA arbitration, native lane strobes, independent AW/W, bus errors, ownership, reset, pre-write drain and post-write maintenance; secure/non-secure and locked configurations |
| `dbg-sba-core-test`, `dbg-sba-core-negative-test` | Cached readback, live code replacement and independent retirement trace, LR/SC, MMIO, held instruction reads, cancellation/reset and four coherence mutations |
| `dbg-full-openocd-test` | Full-profile combined autoexec/trigger/SBA model with native OpenOCD Program Buffer and SBA acceptance |
| `dbg-trigger-openocd-test`, `dbg-trigger-gdb-test` | Actual hardware breakpoint/read/write/access watchpoint allocation, precise continuation, GDB reconnect and armed-trigger exclusion of independent SBA |
| `dbg-rom-test` | Reproducible ROM image; scratch preservation; halt/going/exception/resume handshake and authorized DRET; each supported abstract transfer; malformed commands |
| `dbg-core-test` | Precise halt/resume/step, correct DPC/cause, debug CSR permissions, EBREAK controls, rejected Program Buffer DRET and debug exception containment |
| `dbg-memory-test` | Core Debug Mode and platform requester gates for the debug page; MMIO permissions/cache bypass; access widths and byte lanes; device side effects; AXI stalls/errors; independent AW/W; repeated requests; dynamic Program Buffer updates; code-write/FENCE.I readback |
| `dbg-context-test` | M/S/U/VS/VU entry and return; H metadata; scalar FP, vector, Zvk and Keccak state round trips; representative arithmetic and memory instructions in Debug Mode |
| `dbg-translation-test` | Pinned OpenOCD software walks for host/guest pages, high GPAs, Svnapot, error containment and documented differences from hardware translation |
| `dbg-jtag-test` | TAP/DTM protocol, CDC, sticky busy/errors, TMS/TRST reset, frequency/phase variation, and OpenOCD/GDB through remote bitbang |
| `dbg-bscan-full-test` | Full-profile/full-extension USER4 tunnel with native OpenOCD Program Buffer, trigger and SBA cases plus GDB hardware watchpoints |
| `dbg-measurements-collector-test` | Synthetic measurement parsing, source/tool/library staleness and compatible-baseline delta checks |
| `dbg-config-matrix-test`, `dbg-asic-random-test` | Seven strict ASIC elaboration/lint compositions and six randomized full-feature startup seeds |
| `dbg-ooc-reset-constraints-test` | Tcl command-model checks for timed synchronous reset, narrow TCK reset exceptions and fail-closed guards; no Vivado or physical timing claim |
| `dbg-test` | Aggregate debug functional gate, including debug-enabled and debug-disabled protection tests; ordinary `make test` is a separate ISA regression |

Directed core tests must include:

- Halt with the interrupt enables clear; halt with the next instruction
  unfetched or faulting; halt during long FP/vector/crypto operations and
  posted-store drain; halt/resume requests near resets and command completion.
- No normal instruction retired before a requested reset halt, and no extra
  normal instruction retired during stepping. Debug ROM instructions must be
  distinguishable from normal execution in the scoreboard.
- Step over compressed instructions, taken/not-taken branches, JAL/JALR,
  ECALL, illegal instructions, memory faults, MRET/SRET and guest transitions.
  A branch to a faulting fetch address must first halt at that address; the
  fetch exception belongs to the following resume/step.
- Program Buffer exceptions leave application trap state unchanged; stepped
  exceptions outside Debug Mode update that state normally.
- Test 32-bit and native-width reads for every exposed register class, with
  high-bit canaries and unchanged `data1` after a 32-bit read. Check rejected
  narrow writes, oversized/reserved sizes and invalid register numbers for
  correct `cmderr` and no target-register side effect.
- Exercise every Program Buffer instruction choice above: wait instructions,
  ECALL/MRET/SRET command exceptions, AUIPC, forward/backward control transfers
  inside the buffer, and transfers to mapped code outside it. Check DPC/cause,
  application trap/return state and return to the parking loop.
- Execute DRET directly in the Program Buffer and after a command jumps to
  the ROM's resume DRET without an authorized resume sequence. Both must
  report a command exception, remain halted and preserve saved context.
  Then verify a normal resume: RESUMING precedes DRET, exactly one core exit
  occurs, and the DM's running/resume-ack state agrees with the core.
- Check deterministic LR/SC reservation loss across entry/resume, then a
  successful fresh LR/SC sequence. Assert each implemented interrupt source
  during Debug Mode and stepping, and verify masked delivery with preserved
  pending state. Put HPM counters at overflow boundaries and inject events
  while the ROM runs: no automatic increment, OF update or LCOFI generation
  may occur in Debug Mode. An interrupt pending before entry must survive.
- Register/memory canaries around every transfer. Cover x0, the ROM's scratch
  registers, FP NaN boxing, vector tails/masks and all 32 vector registers.
  Save/restore `vl`, `vtype`, `vstart`, FP status and debugger working state.
- Exercise peripheral access against a modeled device with read-to-clear,
  FIFO-pop and write-one-to-clear registers. Count accepted transactions and
  verify supported widths, addresses, byte enables and absence of extra reads
  or repeated writes under DMI/AXI stalls. Inject unmapped-address and bus
  errors; check command-error recovery and a subsequent successful MMIO access.
- Run OpenOCD one-element and block reads against the side-effecting device
  model. Verify exactly the requested accesses, no trailing speculative read,
  and correct fallback after attempts to enable unsupported `abstractauto`.
- Halt with MPRV/MPV and pointer masking configured, to show that debug entry
  still reaches the ROM and that DRET restores the intended execution context.
- Use a recording firewall model to check AR/AW attributes independently of
  payload values. Cover U/S/M/VS/VU, MPRV/MPV, H memory instructions, fetches,
  scalar/vector accesses, atomics, CBOs, host/guest PTE reads and debug commands.
  Test both static domain settings; every request must match the trusted
  setting. User/guest requests must not acquire a higher effective privilege;
  ordinary execution must not access the debug-only aperture.
- Check HLVX through an execute-only guest mapping: permission checks use
  execute semantics, while every resulting HLVX data request has
  `AxPROT[2]=0`. Record PTE reads separately; those are data transactions too.
- Attempt debug-page fetches, reads and writes in every normal privilege
  mode, including M, and from a second modeled bus master while the core is
  both halted and running. The core gate must reject normal-mode accesses;
  the platform gate must return decode errors to other masters without a DM
  handshake or side effect. Stall accepted debug requests across a mode
  transition to verify that authorization remains attached to each request.
- Deny unprivileged peripheral accesses in the firewall model and verify
  access faults. Attempt aliases and instruction fetches at those physical
  addresses; neither cache may serve or allocate them. Separately prime and
  reuse cacheable RAM across privilege modes under the documented advisory
  fill policy and normal MMU permissions. Use separate domain-0/domain-1
  elaborations; dynamic switching is deferred. Stall AR/AW and queue stores
  across privilege changes;
  the original request's attributes must remain unchanged.
- Reset during each DMI/abstract-command phase; DM deactivation and
  reactivation; sticky `havereset` and command-error clearing.
  The BSCAN sweep also interrupts every IR/DR frame position with reset pulses,
  pauses and stopped clocks. Reset puts framing in WAIT, which drives inner
  TMS low; the TAP reaches Idle before the next header preamble. An interrupted
  scan is discarded, and the debugger must reselect DTMCS/DMI after transport
  reset instead of relying on a cached IR selection. Check that no unintended
  DMI request is committed while recovering.
- Four-state startup checks and random initial values for unreset payloads.
  Control must become known after its reset; payload must be known whenever
  VALID is asserted and stable until accepted. Check control and validity
  rather than requiring defined idle payloads.

Use independent architectural scoreboards and specification-derived expected
results. Adapt applicable PULP and `riscv-tests/debug` cases with attribution;
audit their 0.13 assumptions. Use a reference implementation for supported
architectural outcomes where useful, without assuming its Debug ROM or
optional features match ours. ACT4 ordinary ISA passes are regression evidence,
not Debug 1.0 certification. Pin a suitable mainline OpenOCD/GDB combination;
the archived RISC-V fork and the historical fork in PULP's CI are not the
interoperability baseline.

Add negative controls proving that the checks detect an extra stepped
instruction, a wrong DPC, corrupted scratch state, an architectural trap from
a debug command, a dropped/duplicated AXI handshake, a clobbered protection bit,
and a cacheable alias of a protected peripheral. Counterexamples and logs
must identify the configuration and failing phase.

### OpenOCD software translation coverage

`dbg-translation-test` must use the pinned mainline OpenOCD source baseline
above (or an explicitly recorded replacement) and record its build revision,
translation/access settings, Karu configuration and page-table fixture. Compare
read results with independently placed sentinels and normal-execution hardware
walks where meaningful; do not reuse OpenOCD's algorithm as the expected-value
generator.

| Case | Required fixture and observation |
| --- | --- |
| Host Sv39 | 4 KiB, 2 MiB and 1 GiB leaves; valid and invalid superpage alignment |
| VS Sv39 over G Sv39x4 | Translate the VS page tables through G-stage too; cover Bare combinations as controls |
| x4 widening | Include a guest physical address above 4 GiB, both for a leaf mapping and for a VS page-table page; map to HPAs within Karu's supported physical range |
| Svnapot | Supported 64 KiB NAPOT mappings at VS and G stages, separately and combined; record a tool limitation if the selected OpenOCD cannot walk them |
| Faults | Invalid/missing entries at VS and G stages, including a G-stage failure reading a VS PTE; report an error without an unintended final data/device access |
| Permissions and attributes | Vary SUM/MXR, U/R/W/X and A/D bits, pointer masking and Svpbmt; record the software walk's outcome against the hardware result and intended debugger policy |

Classify each result as supported, explicitly unsupported, a documented
debugger-policy difference or a defect. Unsupported mappings must not silently
return data from the wrong HPA. Do not interpret physical debug access as proof
that hardware permission/A-D/attribute checks were applied. For positive and
failing debugger operations, verify preservation of application trap state
(`*epc`, `*cause`, `*tval`, H trap metadata), saved DPC/cause and working
registers, except for state the test explicitly asks the debugger to modify.
The published interoperability record must state which virtual mappings and
attributes the pinned tool actually supports.

## Synthesis and hardware acceptance

- Extend declaration-order lint and strict Verilog parsing to adopted RTL.
  Run Verilator lint, Icarus four-state tests and the ASIC initialization audit.
- Verify that debug-disabled elaboration removes the debug hardware. For
  debug-enabled builds, check register-file port counts, inferred memories,
  latch/divider absence and the combined source/memory inventory. Protection
  metadata support must remain in the ordinary core when debug is disabled;
  account for added transaction-attribute flops/queues. Milestone A preserves
  data/tag RAM geometry under its static-domain/cacheability contract; verify
  the inventory rather than assuming no change.
- Measure Yosys area and OpenSTA timing with the maintained 200 MHz target.
  Inspect the new issue gating, CSR and redirect paths; do not assume that a
  small DM makes their timing impact negligible.
- Run the shipping VCU118 configuration through Vivado implementation with
  the 75 MHz core target. Reuse the standard build locations and karudeb ROM
  inputs. Record routed timing and exact source/configuration hashes.
- On hardware, demonstrate reset halt, register/memory access, stepping and
  code updates through OpenOCD/GDB. Demonstrate a peripheral scratch-register
  read/write and UART access with the required width, preserving device state
  where applicable. Then run normal Linux/karudeb boot and the existing board
  acceptance tests after debugger detach.
- Keep compliance status provisional until the requirements-to-tests record,
  functional gates, tool interoperability and selected hardware configuration
  are all documented. Distinguish simulated, synthesized and board-tested
  configurations.

## Implemented SBA contract

`KARU_DBG_SBA` adds [SBA registers and ownership control](karudbg_sba.v) to
[the DM](karudbg.v), with [a bus arbiter/coherence coordinator](karudbg_bus.v)
downstream of the core caches and upstream of the platform decoder. The default
advertises `sbversion=1`, `sbasize=32` and native 8/16/32/64-bit transfers.
Unimplemented high address/data registers read zero. The portable register
engine also accepts a wider `SBASIZE` parameter, but the current 32-bit platform
adapter rejects every nonzero upper address bit before any bus transfer.
Unsupported sizes and misalignment cause `sberror` before bus activity.

One request is outstanding at a time. Address-triggered reads use the newly
written address; data-triggered reads return the previous data before starting
the next access. Writes combine the new low word with the saved high word.
Only successful transfers autoincrement. Errors are sticky and bitwise W1C;
busy address writes and data accesses set `sbbusyerror` without changing the
live request. Busy `sbcs` writes are ignored, a defined local choice for a case
the specification leaves undefined. Independent AW and W acceptance is
supported, with no retry, read-modify-write, extra MMIO transfer or burst.

SBA writes to DRAM (`0x80000000..0xffffffff`) or executable scratch SRAM
(`0x00101000..0x00110fff`) require maintenance. Scratch is uncached, but fetched
and decoded instructions can still be resident in the IFU. Custom maps must
supply `sba_ram` through `KARU_DBG_SBA_RAM_HEADER` and keep that classifier
consistent with their PMA header and decoder, including every writable
cacheable or executable region. Such a write first
registers the instruction-admission hold and waits for decoded work,
active units, posted stores and outstanding instruction transactions to drain.
Acceptance requires the registered hold as well as the quiet acknowledgement;
an instruction admitted on the hold's assertion edge must also drain. This
adds one control flip-flop and one hold-assertion clock before RAM-write
acceptance. Request VALID retains reset suppression, while the hold has no
combinational reset/request path into issue. Withdrawal before acceptance
releases the hold on the next clock. Neither AW nor W is presented before
the drain. The hold clears LR/SC
reservations. After the write response, including a failed response that may
have modified RAM, the existing whole I/D-cache flushes invalidate cached
aliases and poison refills, and the IFU restarts at the tracked architectural
next PC. Maintenance also pulses the existing platform `cache_flush_req`
with `cache_flush_invalidate=1`, then samples `cache_flush_done` after the
request clock, as for FENCE. An idle-high value at the request edge is not a
completion. Once requested, the core retains the acknowledgement even if an
instruction prefetch is still active, and waits for that read to drain before
completing maintenance. A platform with no additional maintenance may tie done high. The pause
and `sbbusy` remain asserted until that acknowledgement; an integration with
no external cache must still supply the completion handshake. SBA completion
waits for both local and external maintenance. This uses neither a Program
Buffer command nor a ROM-resume fence, preserves running versus halted state,
and costs a temporary issue pause and loss of cache contents. MMIO accesses
skip RAM maintenance. Page-table edits still require the appropriate translation
fence; live SBA is not an atomic snapshot of a running program.

The arbiter's `flush_o` is a level request in its maintenance state. The core
converts it to one local/platform flush pulse once internally idle; its
`debug_sba_quiet_o` then stays low until the external acknowledgement is
recorded. The platform must preserve dirty data when servicing maintenance.
An outer data cache must be on the coherent path shared by core and SBA;
bypassing an independent dirty cache needs additional pre-write coordination.

DMI/TAP reset preserves an accepted operation. Deactivation withdraws an
unaccepted request and releases its own hold; after platform acceptance,
cleanup drains even while inactive, and reactivation cannot bypass it. Shared
hart/fabric reset cancels ownership; an operation started before that reset,
while the DM remains active, reports `sberror=7` when canceled. This does not
promise an error response for new SBA commands issued while reset is held.
Debug 1.0's Reset Control contract permits only `dmcontrol` reads/writes and
`dmstatus.ndmresetpending` reads while `ndmreset` or any external reset is
asserted; all other DMI accesses are undefined. Here `ndmresetpending` is the
permitted unimplemented read-zero field. The platform must reset the responders
too, preventing stale responses from acquiring a new owner. An unresponsive older core transaction
can keep a RAM-write drain waiting indefinitely; an accepted SBA transaction
whose responder never replies likewise retains its owner and `sbbusy`.
Missing platform cache acknowledgement retains the maintenance pause.
No implicit watchdog permits an unfinished operation to be overtaken. The default PMA map has no non-idempotent executable device
region. A custom map permitting such instruction fetches needs its own rule
for restart and refetch during cache/fetch synchronization.

SBA transactions use physical addresses, privileged data `AxPROT`, and the
trusted static `NONSECURE` setting. They do not inherit hart pointer masking,
translation or privilege, and do not match hart watchpoints. The independent
master cannot reach the private debug page, even while the hart is halted.
The static `SBA_ENABLE=0` integration parameter removes the DM's SBA discovery
and register engine: `sbcs` and the other SBA registers read zero, advertise no
address size or transfer capabilities, and writes cannot launch a request or
maintenance. The independent bus gate also denies SBA traffic. Ordinary core
and Program Buffer accesses remain usable. This is a trusted SoC integration
policy, not an authentication protocol.

Focused simulator evidence on 2026-10-29:

| Command | Result and scope |
| --- | --- |
| `make dbg-sba-unit-test` | 365 checks / 24 transfers for each 32/64-bit engine configuration; 166 DM checks / 6 accepted requests; four failing RTL mutations; strict Verilog-2001 parse and Verilator lint |
| `make dbg-sba-invariant-test` | Independent handshake/ownership monitors, two passing baselines and 13 deliberately corrupted-state controls; request/response stability, routing isolation, registered pause, pre-write drain, maintenance and cancellation |
| `make dbg-sba-core-locked-test` | Actual core plus DMI: 441 checks; zero SBA discovery/register reads, ignored launch attempts and preserved ordinary debug |
| `make dbg-sba-review-negative-test` | Two rejected actual-core mutations: misleading locked discovery and omitted executable-scratch maintenance |
| `make dbg-sba-core-four-state-test` | Four-state ASIC model: cached and scratch live-code replacement, independent retirement trace and delayed external-cache acknowledgement while halted/running |
| `make dbg-sba-openocd-test` | Pinned unmodified OpenOCD, SBA-only RAM at every width and 1/2/5-element blocks, counted FIFO/read-to-clear MMIO, error recovery and private-page denial; deliberate core-cache warm/readback, executable replacement and running-hart access |

The OpenOCD test explicitly selects `riscv mem_access sysbus`, so Program Buffer
or abstract-memory fallback cannot satisfy its SBA accesses. Separate deliberate
Program Buffer reads check the core cache. Running-hart commands use `phys`:
without it, this OpenOCD version first tries to read hart privilege for software
translation, which requires a halted hart. Logs are under `_build/dbg/` and the
harnesses/configuration are under `test/dbg/`. Combined extension regressions,
updated mapped/routed measurements and board acceptance remain separate gates.

## Ordinary ISA replay with debug idle

`make dbg-isa-replay` rebuilds the full RVA23S64 shipping-geometry HTIF model
with `KARU_DBG_FULL`, CLINT and external interrupts, then replays the existing
self-checking ELFs under
`test/riscv-arch-test/work/karu64-rva23s64-smcntrpmf/elfs`. Debug inputs remain
inactive, so this checks ordinary execution with the additional RTL present;
it is separate from the DMI/JTAG, trigger and SBA tests.

The runner never regenerates Sail results or changes the ACT4 dependency.
The golden results are already baked into the ELFs. Before compilation,
`build_isa.py` snapshots the runtime source inputs and flags; it verifies them
after compilation and binds the simulator SHA-256 in
`_build/Vhtif_dbg_full/build-inputs.json`. The replay runner checks that binding
before executing ELFs. It records simulator, RTL/configuration and ELF
SHA-256 identities, the preserved reference-config
files, ACT4 revision/local dependency diff and exact simulator flags. It
verifies runtime input hashes again after execution. Other test-flow and
reference-generation files remain recorded provenance, with any changes listed
separately; editing an unrelated recipe does not change a compiled simulator
or golden ELF. Passing requires both an HTIF
zero exit and the RVCP pass marker, with no failure or timeout. A changed
input invalidates the run. Results and per-test logs retain relative test
paths, including dotted instruction names, to avoid collisions.

```sh
make dbg-isa-runner-test
make dbg-isa-manifest                # selection/hashes only; no ELF execution
make dbg-isa-replay                  # complete existing shipping inventory
make dbg-isa-replay EXT=rv64i/I,Zvbb,priv/InterruptsSm \
  DBG_ISA_OUT=_build/dbg/isa-replay-focused
make dbg-ordinary-isa-test           # Keccak/Zvk/Zvbb/vector/FMA and H subjects
python3 test/dbg/compare_idle_cycles.py --run-baseline
```

`EXT` here selects directory prefixes, rather than generating ACT4 slices:
`Zvbb` covers its four SEW directories; `rv64i/I` selects that specific path.
Defaults are four parallel ELFs, 120 seconds and 20 million cycles per ELF.
Override them through `DBG_ISA_JOBS`, `DBG_ISA_TIMEOUT` and
`DBG_ISA_MAX_CYCLES`. Passing temporary binary/hex images are removed;
`manifest.json`, `results.tsv`, `results.json` and logs remain under
`_build/dbg/isa-replay` or `_build/dbg/ordinary-isa`. Failed images are retained.
The ordinary subject target derives `tohost` from each ELF, so the H assembly
and C/vector firmware can share the same simulator without address overrides.

On 2026-10-29, all 16 ordinary subjects passed on the RTL with the registered
watch-address stage.
The matched base-debug and full-debug models also produced identical total
firmware cycle counts for every subject. The comparison checks identical ELF
and runtime-source hashes, successful bound builds, and flags differing only
by `KARU_DBG_FULL`. Representative complete-subject totals are:

| Subject | Base debug cycles | Full extensions idle cycles |
| --- | ---: | ---: |
| Keccak directed tests | 96,970 | 96,970 |
| Zvbb directed tests | 546,257 | 546,257 |
| FMA hazard tests | 88,951 | 88,951 |
| H preemption tests | 299,753 | 299,753 |

The complete 16-row table, source/result identities and log hashes are in
`_build/dbg/idle-cycle-comparison/{cycles.csv,manifest.json}`. The
[comparison harness](../test/dbg/compare_idle_cycles.py) can build and replay
the base model from the full run's recorded configuration. These are ordinary
execution cycle measurements with extensions inactive; frequency and area
remain separate synthesis measurements.

The current CPU replay on 2026-10-29 has **2872/2872 passing verdicts**
for existing shipping reference ELFs. The initial four-worker run produced
2870 passes and two wall-clock timeouts with a 120-second wall limit and a
20-million-cycle limit per ELF. Both timeout cases pass on bounded one-worker
retries with a 240-second wall limit and the same cycle limit; the original
results are retained alongside the retries. The ordinary subjects also pass
**16/16**, with zero cycle delta between base debug and idle full extensions.
This replays preserved Sail-baked golden results; it does not regenerate
references or establish debug compliance. Source/build identities, actual
frontend consumption, reference provenance, exact ELF identities and the full
result list are retained under `_build/dbg/isa-replay/`. The HTIF frontend does
not instantiate the DM; command-cache behavior is covered by the separate
958-check DM unit and real-hart DMI/OpenOCD tests. A forced frontend, compile
and link rebuild hashes 81 inputs before and after compilation, covers all 74
frontend source inputs and the C++ harness, and reproduces the exact tested
full-model executable (`d1f74befa79e6feba50438ff75819e45cd10333da380bae0cd23e24e1a54583d`).
`final-coverage.json` records the exact unique ELF inventory, selected passing
logs, original and retry manifests, executable identity and fresh build binding.
The maintained [replay harness](../test/dbg/replay_isa.py) supports individual
retries through repeated `--elf-file` arguments; each run records its command,
limits and identities. The base model is rebuilt too, and both 16-subject runs
are checked by [the independent verifier](../test/dbg/verify_htif_consumption.py).
The combined debug validation remains a separate gate.
The superseded pre-stage replay is retained only as build evidence under
`_build/dbg/isa-replay/pre-watch-stage/`.

## Extension implementation and testing plan

Started on 2026-10-29. The extension implementation and review follow-up pass
the fresh combined functional gate. All twelve mapped comparisons are complete.
The full-extension FPGA image passes 75 MHz routed acceptance; board testing
remains open. Check a task only when its implementation and required
evidence are complete; record the source revision, configuration, command,
result and artifact paths beside it. Reference documents are Debug 1.0's
[DM chapter](https://docs.riscv.org/reference/debug/v1.0/debug_module.html) and
[Sdtrig chapter](https://docs.riscv.org/reference/debug/v1.0/Sdtrig.html).

The destination is a single-hart RV64 ASIC. Use the conventional JTAG TAP/DTM
and portable core, DM and bus-interface RTL there. Keep Xilinx primitives,
USER4 framing, MIG and board clock/reset wiring in the FPGA integration.
Implement in this order: **contract and fixtures → autoexec → triggers → SBA
→ combined acceptance**. SBA interface/coherence design can proceed while
trigger implementation is tested.

| Milestone | Planned deliverable | Completion evidence |
| --- | --- | --- |
| E0 | ASIC/platform contracts and test fixtures | Reviewed interface, reset, matching and coherence decisions |
| E1 | Abstract-command auto-execution | DM protocol tests and actual OpenOCD bulk/MMIO tests |
| E2 | Hardware address breakpoints/watchpoints | CSR, scalar/vector/H tests, reference checks and GDB watchpoints |
| E3 | Independent System Bus Access | AXI, cache, protection and running-hart tests |
| E4 | Combined ASIC/FPGA acceptance | Integrated regressions, mapped estimates, ASIC handoff and routed FPGA results |

### E0 — contracts, configuration and shared fixtures

- [x] **E0.1** Specify independently selectable feature configurations:
  existing debug, each extension separately, all extensions, and debug disabled.
  Disabled features must elaborate away and report their absence correctly.
  Preserve the single-hart interface; do not add hart-array/group machinery.
- [x] **E0.2** Record exact supported trigger fields and WARL/reset behavior,
  SBA address/data widths and bus map, autoexec ordering, and error priorities
  before writing RTL, using the four fixed decisions below. Advertise only
  implemented and tested capabilities.
- [x] **E0.3** Specify core/DM/TCK/SBA clock and reset ownership. DM and SBA
  must remain usable while the hart is halted; distinguish hart halt/reset,
  `ndmreset`, `dmactive=0`, DMI reset and TAP reset. A platform-reset bus need
  not service SBA, but cancellation must not leave a stuck owner or stale reply.
- [x] **E0.4** Keep the existing synchronous core/DM reset convention and
  conditioned TCK reset release. Record ASIC clock-gating, scan/test-mode and
  reset/isolation requirements with the SoC integrator; do not substitute
  blanket timing exceptions or a global asynchronous-reset conversion.
- [x] **E0.5** Extend reusable fixtures: side-effect-counted MMIO, controllable
  faults/stalls, cached RAM aliases, instruction replacement, vector access
  traces and guest contexts. Store harnesses and negative controls under
  `test/dbg/`, with maintained Make targets; generated files stay in `_build`.

E0 evidence: the seven-row configuration matrix covers debug disabled, base,
each feature, full and four-slot full builds. Shared bus/core fixtures test
reset ownership and counted MMIO. The four follow-up corner cases are also
covered: cancellation during SBA maintenance, reservation clearing, older-core
write drain before either SBA write channel, and FF watchpoint/resume followed
by a real fault at the same element. Their detailed commands and evidence are
recorded under E2 and E3; no board test is implied.

#### Fixed E0 decisions

These choices resolve scope and behavior. The checklist separately records
implementation and test completion; a decision alone does not close an item.

**E0-D1 — debugger-owned triggers.** An active trigger must have `type=6`,
`dmode=1`, `action=1`. Authorized writes requesting `dmode=0` normalize the
slot to disabled `type=15`, with `dmode=0`; writing zero also disables it.
Unsupported active actions normalize to disabled type 15. Reset slots are
disabled type 15 with `dmode=0`. Existing `dmode=1` protection takes priority:
M-mode writes cannot alter any protected `tdata` register, and M-mode cannot
set `dmode`. In an unprotected slot, an M-mode write requesting an active
trigger therefore reads back disabled type 15 with `dmode=0`. Debug Mode can
clear `dmode`, but doing so disables the trigger even
if the write requests action 1. Discovery must report the supported types.
This follows the Debug 1.0 `tdata1` protection and action-1 rules. Native
OpenSBI/Linux-managed breakpoint/watchpoint exceptions are not supported in
this phase; an external debugger can still watch Linux and guest accesses.
Action 0 and `tcontrol` remain deferred.

**E0-D2 — whole-cache hardware coherence for SBA writes.** Reuse the existing
D-cache and I-cache flush/refill-poison mechanisms, rather than adding per-line
invalidation. For an SBA write to RAM that may have cached aliases, a hardware
maintenance handshake drains older core writes before issuing the SBA write
(before either AW or W can be accepted) and pauses new issue at an instruction
boundary. Clear the LSU's LR/SC reservation when entering RAM maintenance.
After the write response, flush both caches, discard
IFU prefetch and unissued decode state, and restart fetch at the held next
instruction PC. Do not report SBA completion until maintenance is acknowledged;
release the pause unless another halt/reset condition applies. Also perform
maintenance after a failed response if an accepted write may have modified RAM.
The default FPGA class includes the whole DRAM window and executable scratch,
regardless of CPU Svpbmt aliases. ASIC/custom maps must identify all equivalent
cached or executable writable regions.
Running-hart writes temporarily pause execution and lose cache contents.
Neither Program Buffer execution nor a ROM-resume fence is required. Pure MMIO
access does not invoke this RAM maintenance. Page-table edits still require
the appropriate architectural translation fence.

Maintenance cancellation is part of the hardware contract. DMI/TAP reset does
not cancel an already accepted SBA operation or release its pause early.
`dmactive=0` cancels a request before any SBA bus acceptance and releases its
own issue hold; once a bus transfer has started, retain ownership, drain it
and complete any required RAM maintenance before releasing the hold, while
discarding the abandoned debug result. Reactivation cannot bypass that cleanup.
`ndmreset` resets the core/caches and affected fabric together: cancel the
maintenance state through the platform reset handshake without waiting for
responses from a reset responder, and leave no stale hold after reset release.
External reset follows the same reset-domain ownership rules. A core device
access that never responds can keep the pre-write drain, and therefore
`sbbusy`, waiting indefinitely; there is no implicit watchdog or unsafe write
bypass. Deactivation may cancel a not-yet-issued SBA request, but recovery of
the original stuck core transaction requires platform reset.

**E0-D3 — compare the pointer-masked access address.** Apply the same pointer
masking transformation as the explicit memory access, then compare its
effective address before translation. Guest accesses compare before VS/G-stage
translation as applicable. With masking disabled, compare the original
effective address. Use the effective privilege and its MPRV/SPVP/MXR rules;
instruction PCs are not pointer-masked. CSR writes to `tdata2` are not masked:
the debugger programs the address/range it intends to match. SBA remains a
physical bus operation and does not inherit CPU pointer masking. The source
for this rule is the
[Pointer Masking specification, §17.1.2.6](https://docs.riscv.org/reference/isa/v20260120/priv/zpm.html),
which explicitly applies masking to memory addresses used by debug triggers.

**E0-D4 — fault-only-first watchpoints enter Debug Mode.** A hit at active
element `i`, including `i>0`, takes the precise debug entry, leaves `vl`
unchanged and sets `vstart=i`; DPC identifies the vector instruction. Preserve
completed earlier elements and stop before the matching element's side effects.
For segmented operations, stop before the matching segment's side effects so
element-level restart does not repeat non-idempotent field accesses. A genuine
earlier fault retains its normal priority/FF-trimming behavior; a watchpoint
must not be converted into a fault-only-first trim to avoid reporting it.
This chooses the behavior recommended by
[RVV 1.0's fault-only-first rules, §31.7.7](https://docs.riscv.org/reference/isa/v20240411/_attachments/riscv-unprivileged.pdf).

### E1 — abstract-command auto-execution

This is confined primarily to the DM. It reuses the existing saved command
and execution engine; it does not add another processor or memory master.

- [x] **E1.1** Implement `abstractauto` for both data registers and all eight
  Program Buffer words: ten writable enable bits, with other bits reading zero.
  Reset/`dmactive` behavior must agree with the register contract.
- [x] **E1.2** Trigger exactly once per accepted selected DMI access. A read
  returns the current value before re-execution; a write supplies the new value
  before re-execution. Route launches through the same availability, halted,
  command-validity, busy and `cmderr` checks as explicit command writes.
- [x] **E1.3** Test every enable bit, read and write, reserved bits, postexec,
  backpressure, busy/error clearing, exception recovery and reset cancellation.
  Assert no duplicate launch from a held request or a delayed response.
- [x] **E1.4** Run actual pinned OpenOCD/GDB bulk RAM/register transfers.
  For MMIO, count transactions for one-element and block transfers and prove
  the selected tool path makes no speculative, trailing or duplicate device
  access. Do not alter architectural autoexec semantics to hide tool overreads.
- [x] **E1.5** Test the native autoexec path and the unsupported-autoexec
  fallback configuration separately. Review the existing OpenOCD patch in
  parts: implementing autoexec does not remove its independent software-walk
  safeguards. Document any remaining tool policy needed for MMIO.
- [x] **E1.6** Negative controls must detect a duplicate command and incorrect
  read/write ordering. Pass the existing DM, command-exception and transport
  gates, then record incremental area and timing impact.

E1 directed evidence (2026-10-29): `make dbg-autoexec-test` passes 958
checks, and `make dbg-unit-test` retains the feature-off 947-check result.
The autoexec bench models Program Buffer contents independently and covers all
ten enable bits, busy data/Program Buffer writes, exception recovery, held
requests/responses, and DMI/platform/DM reset behavior. An explicit command
accepted while idle with `cmderr=0` replaces the autoexec command even if it
fails validation or the hart is not ready; writes while busy or with a sticky
error do not replace it. Five autoexec mutations must fail: absent launches,
duplicate launches, stale write operands, changing read replies and stale
command replay after an unsupported explicit command. They run with the
existing transport and SBA backend negative controls (17 total).

`make dbg-autoexec-core-test dbg-autoexec-gdb-test` uses the pinned pristine
mainline OpenOCD and a separate full-profile simulator compiled with
`KARU_DBG_AUTOEXEC`. The OpenOCD run passes,
including 8/16/32/64-bit RAM blocks and exact one-, three- and five-element FIFO
access counts; no trailing MMIO reads occur on this tested path. It also
caches a device-load command, replaces it with an unsupported explicit command,
clears the error and retries through autoexec: the unsupported-command error
returns without another device access. The full-extension native model passes
the same scenario. The raw-DMI probe disables periodic target polling,
flushes/invalidates OpenOCD's register context at its boundaries and writes the
pointer through Access Register. A delay longer than the normal poll period
keeps this check independent of deferred register writes and background polls.
GDB passes register, FP/vector context,
memory, stepping and reconnect checks on both models. The
feature-off `dbg-openocd-core-test` still passes using the patched fallback
while pristine OpenOCD's unsupported-autoexec negative
control fails as expected. The software-walker safeguards in the local patch
remain independent of autoexec support. Incremental area and 200 MHz timing
measurements are complete in [the matrix](MEASUREMENTS.md#extension-measurements--2026-10-29).
The [combined functional record](#current-combined-validation-record--2026-10-30)
also passes on the final sources.

### E2 — hardware address breakpoints and watchpoints

Start with **two address-match slots**, with a four-slot configuration for
cost/timing comparison. Use standard `mcontrol6` triggers for execute, load
and store addresses, with exact and supported NAPOT range matching. Initial
scope is debugger-owned triggers entering Debug Mode. Data-value matching,
chaining, instruction-count/interrupt/exception triggers, native breakpoint
actions and ASID/VMID/context matching are deferred; expose unsupported fields
through correct WARL/discovery behavior rather than partial emulation.

- [x] **E2.1** Implement `tselect`, `tinfo`, `tdata1`/`tdata2` and the required
  absent-register behavior. Specify type enumeration, slot exhaustion, hit
  reporting, `dmode` write protection and M/S/U/VS/VU matching. Disable matching
  during Debug Mode and establish the trigger debug-entry cause/priority.
  Apply E0-D1's disabled-type normalization and protected-write precedence.
  Evidence (2026-10-29 working tree): `make dbg-trigger-unit-test` passes
  1,298 checks with two slots and 1,302 with four; the actual-core four-state
  profile probe covers protected CSR writes and M/S/U/VS/VU contexts.
  Logs: `_build/dbg/trigger-unit.log`, `trigger4-unit.log` and
  `trigger-profile-four-state/run.log`; [supported contract](TRIGGERS.md).
- [x] **E2.2** Match execute addresses at an architectural instruction boundary,
  not speculative prefetch. Match data accesses before the core cache can hide
  them. Use E0-D3's post-masking, pre-translation address and its Pointer
  Masking specification reference, including guest execution; exclude implicit
  page walks, cache fills and independent SBA traffic from architectural matching.
  Evidence (2026-10-29 working tree): the four-state profile probe checks
  cached loads, split-fetch instruction-start priority, Sv39 and VS/G-stage
  aliases, and PMLEN 0/7/16 before translation. `make dbg-trigger-haccess-test`
  passes 20 HLV/HSV/HLVX cases across SPVP, HUPMM and MXR; log:
  `_build/dbg/trigger-haccess-four-state/run.log`. Native OpenOCD also checks
  that independent SBA traffic does not fire hart watchpoints.
- [x] **E2.3** Cover scalar integer/FP loads/stores, LR/SC, AMOs and the required
  cache-block operations. Define precise match/fault ordering and suppress
  watched side effects when using before-access timing. Resume must neither
  repeat a committed store nor omit an uncompleted access.
  Evidence: the actual-core probe covers integer and FP widths, LR/SC/AMOs,
  CBO.ZERO, translation/access-fault priority and counted MMIO continuation.
  The source audit confirms CBO clean/flush/invalidate use the same
  `lsu_is_cbo` before-access predicate; these three variants are not separate
  directed watchpoint cases. See `test/dbg/trigger_core_tests.vh` and
  `_build/dbg/trigger-profile-four-state/run.log`.
- [x] **E2.4** Integrate RVV at the active-element level. Cover contiguous,
  strided, indexed, segmented and whole-register accesses, fault-only-first,
  masks, tails and `vstart`. A 16-byte memory granule can contain several
  watched elements; comparing its AXI base alone is insufficient. Preserve
  completed elements and the correct restart point across debug entry.
  Apply E0-D4 to fault-only-first and segmented hits; do not trim `vl` on a hit.
  Evidence: `make dbg-trigger-vector-test` passes 1,066 independent four-state
  cases (47,752 checks). The core probe checks all four SEWs and FF
  watchpoint/resume/fault trimming. Whole-register EEW 8/16/32/64 device traces
  prove exact prefix and restart behavior; the reversion control detects an
  invalid interior-byte stop. Logs: `_build/dbg/trigger-vector-unit.log`,
  `trigger-whole-four-state/run.log`, `trigger-negative/whole-element/run.log`.
- [x] **E2.5** Keep comparators off normal critical paths where possible.
  Permit extra sequencing while triggers are enabled; measure that disabled
  triggers preserve normal cycle counts. Precompute range masks when configured
  if useful, use bounded/balanced logic, and infer no runtime divider/modulo or
  extra register-file/memory ports.
  The VLSU now registers each 64-bit post-masking watch address before comparing it,
  separating indexed address generation from global debug-entry control. This
  adds one cycle per armed field query; the disabled path is unchanged.
  Independent capture assertions and a stale-address negative control pass,
  together with the six-control suite and the profile/H/whole-register
  four-state probes. All 16 ordinary subjects have zero idle cycle delta.
  The complete current cost/path comparison, including the optional four-slot
  configuration and the separate 200 MHz closure gate, is recorded in
  [measurements](MEASUREMENTS.md#extension-measurements--2026-10-29).
- [x] **E2.6** Add CSR tests and directed instruction subjects. Sweep access
  widths, alignment, range boundaries, cache hits/misses, page boundaries,
  privilege/guest contexts and fault priority. For RVV, sweep SEW/LMUL, active
  lengths and masked/prestart/tail cases, including a match beyond the first
  byte/element of a granule. Check DPC, cause, registers, memory side effects,
  application trap state and exact continuation after disabling the trigger.
  Explicitly test M-mode writes to protected slots, `dmode=0,action=1` writes
  to writable slots, debugger disarming and zero writes. Test tagged/untagged
  address pairs at PMLEN 0/7/16, Sv39/Bare, MXR and MPRV/SPVP settings, and
  verify `tdata2` retains its written bits. For fault-only-first, test hits at
  elements 0, 1 and the last active element, masked element 0, nonzero `vstart`,
  segmented hits and an earlier real fault; verify unchanged `vl`, exact
  restart and no repeated non-idempotent access when the watchpoint fires.
  Also hit at element `i>0`, disable the watchpoint and resume with a real
  access fault at that element: expect normal FF completion with `vl=i`,
  `vstart=0`, no application trap, and the already completed prefix preserved.
  Evidence: the bank, independent VLSU, actual-core profile, whole-register
  device and H-access targets above cover these cases. CSR and application
  trap-state checks use the architectural DMI/Program Buffer interface;
  independent device traces count side effects. The test inventory is bounded,
  rather than an exhaustive proof of every encoding/context combination.
- [x] **E2.7** Cross-check supported trigger cases with a pinned Spike where
  its model covers the same semantics; use independent expected access traces
  and assertions for remaining cases. Do not weaken the oracle to match Karu.
  Exercise actual GDB hardware breakpoints and read/write/access watchpoints,
  slot allocation, stepping over a hit and detach/reconnect through OpenOCD.
  Evidence (2026-10-29 working tree): `make dbg-trigger-spike-test` passes
  the same `openocd_trigger_address.tcl` scenario used on Karu, covering
  execute/read/write/access matches before side effects and continuation.
  `_build/dbg/spike-triggers/reference.json` records the exact Spike binary
  SHA-256 and pinned OpenOCD version. The native OpenOCD and actual GDB
  trigger tests pass; logs are under `_build/dbg/openocd-triggers/` and
  `_build/dbg/gdb-triggers/`.
- [x] **E2.8** Negative controls must catch a missed cache-hit watchpoint,
  a missed later vector element, a masked-element false hit and a wrong restart
  point. Run the existing scalar/vector, privilege and debug regressions.
  Evidence: all six trigger mutations fail for their intended checks; the
  ordinary CPU replay passes 2872/2872 and directed subjects pass 16/16.

### E3 — System Bus Access

Adapt the SBA engine/register behavior from the pinned PULP `dm_sba.sv` and
`dm_csrs.sv`, retaining provenance and licenses. Start with one outstanding
single-beat access, native 8/16/32/64-bit transfers and a generic platform bus
adapter. Bursts and multiple outstanding requests are not prerequisites.

- [x] **E3.1** Implement truthful `sbcs`, `sbaddress*` and `sbdata*` discovery,
  read-on-address/data, write launch, autoincrement, sticky errors and busy
  rules. Increment only after a successful transfer. Never truncate an
  advertised address silently; reject invalid sizes/alignment/addresses before
  bus activity where possible.
- [x] **E3.2** Add arbitration upstream of the platform memory/peripheral
  decoder, downstream of the core caches. The existing FPGA host-loader mux
  selects DDR only while the CPU is held; it is not concurrent SBA arbitration.
  Preserve transaction ownership through independent AW/W acceptance and until
  B/RLAST, response backpressure and every supported reset sequence.
- [x] **E3.3** Implement E0-D2's hardware maintenance handshake using the
  existing whole-cache flush/refill-poison paths. Add the issue/drain and
  IFU/decode restart coordination, not a new cache-tag/per-line mechanism.
  Preserve running/halted state and report completion only after coherence
  acknowledgement, including errors with possible write side effects. Document
  cache-loss/stall cost and translation fences for edited page tables.
  Live SBA is not an atomic snapshot of a running program.
- [x] **E3.4** Preserve native-width MMIO and exact byte enables; make no
  speculative reads or automatic retries with duplicate device effects. Set
  AXI privilege/security/data attributes from an explicit debug-master policy,
  not the interrupted hart's mutable context. Retain core-only authorization
  for the private debug page and define the SoC enable/lock gate for SBA.
- [x] **E3.5** Test each access width and trigger mode, bus error, illegal
  address, unsupported size, alignment, autoincrement and error clearing.
  Stall AR/AW/W/R/B independently, including W before AW, and exercise reset
  and DMI cancellation at every transaction phase. Prove no lost, duplicated
  or misrouted transaction and no increment on failure.
  Inject `dmactive=0`, DMI/TAP reset and `ndmreset` during drain, bus transfer
  and cache/fetch maintenance; prove the E0-D2 cancellation rules and eventual
  release when the relevant bus/reset handshakes complete. Hold a core device
  response forever as a bounded test of waiting `sbbusy` and reset recovery.
- [x] **E3.6** Test cached-data readback after SBA writes, fills racing with
  invalidation, outstanding/posted CPU writes, code replacement plus fetch
  synchronization, and physical aliases. Exercise RAM and counted MMIO with
  the hart halted and running. Test prefetched/unissued old instructions,
  pending interrupts and errors after an accepted RAM write. Prove completion
  waits for maintenance, execution resumes at the correct PC without register
  corruption, and no Program Buffer command or ROM-resume fence is needed.
  Test an older posted CPU store and a later SBA write to the same address:
  the older write must complete first and SBA data must win. Test LR, SBA RAM
  write, SC failure, then a fresh LR/SC succeeding; include maintenance cancel.
- [x] **E3.7** Test OpenOCD's SBA method explicitly, including its block-access
  controls and error recovery. Do not allow an unnoticed Program Buffer
  fallback to make the SBA test pass. Verify inaccessible private-page and
  disabled-master attempts generate no downstream access.
- [x] **E3.8** Negative controls must catch an ignored bus error, a high-address
  alias, stale cached data after an SBA write and an extra MMIO transfer.

Directed extension evidence (2026-10-30): `dbg-sba-bus-test` passes 652
checks in each Secure and Non-secure configuration, including coincident AR/R
acceptance, plus 59 checks with SBA
locked off; the lock leaves ordinary core transactions working. Eight backend
mutations are rejected, including early write acceptance, dropping pause while
older core writes drain, skipped maintenance, wrong byte enables, damaged core
burst forwarding and high-address aliasing. Added controls reject a
combinational pause and RAM acceptance before the registered hold is asserted.

The focused actual-core SBA probe covers all native-width lane offsets,
cache-warmed readback, instruction replacement, a running loop and LR/SC.
Its live-code test patches the running increment instruction and independently
tracks retired PCs and opcodes: the first retirement after maintenance must
resume at the next architectural PC, and no old increment opcode may retire.
The four-state ASIC/no-F configuration completes 30,740 checks, including
held instruction AR/R, DMI reset, deactivation cancellation and a bounded
nonresponding instruction-read/reset recovery. Executable scratch replacement
is checked with the same independent PC/opcode trace as the DRAM loop.
A separate platform-cache model delays completion by 24 cycles in halted and
running cases and checks exactly one request/acknowledgement, no early SBA
response, preserved pause and eventual running-hart progress. Tests also cover
idle-high completion, coincident halt entry, cancellation during maintenance,
and acknowledgement arriving while an instruction prefetch is still active.
The acknowledgement must be retained until that read drains.
The same runner rejects eight
independent mutations that remove reservation clearing, D-cache invalidation,
I-cache invalidation or IFU redirection, allow an interrupt to overtake
maintenance, acknowledge an external-cache operation prematurely, or lose its
acknowledgement during a prefetch.
Reproduce with
`make dbg-sba-core-negative-test`; compilation and simulation have separate
120-second limits, and timeouts do not count as successful negative controls.

`dbg-trigger-openocd-test` passes with the full-profile combined simulator and
pristine pinned OpenOCD. It checks both trigger slots,
rejected third-slot allocation, execute/load/store/access hits and exact
before-access effects/continuation. It also autoexecutes a GPR read while a
watchpoint is armed, then performs physical SBA reads and a coherent write
while the hart runs with that watchpoint armed: SBA must not halt the hart.
`dbg-trigger-gdb-test` passes the actual GDB hardware breakpoint and read,
write and access watchpoint commands, in addition to FP/vector context and
reconnect coverage. The fixture ELF supplies symbols and CFI for its test
functions so GDB does not unwind an artificial uninitialized caller.

These are directed functional results. The final combined source-hashed
regression record, synthesis measurements and physical FPGA/board evidence
have separate acceptance gates below.

### E4 — combined verification, ASIC handoff and FPGA validation

ASIC-focused evidence (2026-10-29): `dbg-config-matrix-test` passes all
seven configurations, with strict Verilog-2001 preprocessing/elaboration,
Verilator diagnostics and recorded source integrity. Generated manifests and
preprocessed sources are under `_build/dbg/config-matrix/`; the disabled core
has no debug ports and the conventional ASIC sources contain no FPGA primitive.
The lint policy records its existing core warning exemptions and permits only
the two named unused `karu_varith` scratch outputs as undriven signals.

`dbg-asic-random-test` passes seeds 1, 2, 7, 19, 42 and 1234567 using one
full-profile, full-debug `KARU_ASIC` model built with `--x-initial unique` and
`--x-assign unique`. It executes the trigger and SBA architectural probes in
sequence, including translation, vector restart, live code replacement and
reset recovery. Each seed has a 90-second limit; the recorded input hashes
match before/after that run. Logs and model/source hashes are under `_build/dbg/asic-random/`.
This randomized two-state test supplements the separate four-state checks.
The full ASIC memory audit reports zero initialized state; the
[inventory and clock/reset/DFT contract](../flow/asic/README.md) records its
scope and the remaining technology-specific obligations.

- [x] **E4.1** Run bounded unit/assertion tests first, then directed Verilator,
  Spike and real OpenOCD/GDB tests. Reuse compiled models and unchanged
  reference artifacts, use explicit timeouts, and record seeds/configurations.
  Run focused ordinary ISA/ACT4 slices when core issue/trap logic changes;
  run the full applicable release inventory once the combined RTL is stable,
  in bounded batches. Ordinary ACT4 success is not a debug-compliance verdict.
- [x] **E4.2** Test interactions: watchpoint hit during normal execution followed
  by autoexec register access and SBA inspection; SBA accesses must not trigger
  hart watchpoints. Cover pending interrupts, stepping, guest state, command
  exceptions, reset recovery and ordinary execution after detach. Preserve the
  existing application trap-state and scratch-register invariants.
- [x] **E4.3** Run four-state and randomized `KARU_ASIC` startup tests. Prove
  disabled/unconfigured comparators and uninitialized payloads cannot leak X
  into control, handshakes or a false trigger. Re-run declaration-order lint,
  strict Verilog parsing, memory/initialization and live-divider audits.
- [x] **E4.4** Update generic source manifests, include/define lists, provenance
  and the combined ASIC inventory. Keep small trigger/DM state as control
  flops; preserve RF/cache/VRF macro interfaces unless an explicitly reviewed
  change requires otherwise. Conventional ASIC builds must contain no Xilinx
  primitives or dependence on FPGA power-up initialization.
- [x] **E4.5** Measure base, each extension and combined area/timing against
  identical RTL/tool/library baselines. Report absolute and incremental results
  and normal/debug cycle costs. The current 200 MHz OpenSTA target already
  misses timing; neither hiding reset/CDC paths nor passing FPGA timing closes
  that ASIC goal. Inspect trigger issue gating, SBA arbitration, invalidation
  fanout and register-to-register paths in particular.
- [x] **E4.6** Produce ASIC clock/reset/CDC/RDC and timing constraints for the
  supported integration, retaining bundled-data bounds and reset-release
  checks. Review test/scan and clock-gating interactions. NanGate45/Yosys and
  OpenSTA are comparative estimates; foundry libraries, memory binding, PVT,
  physical timing and DFT signoff remain technology-specific acceptance gates.
- [x] **E4.7** Rebuild the combined shipping FPGA image through the standard
  75 MHz RVA23S64/SGMII/ROM flow and locations. Pass routed setup, hold,
  pulse-width, bus-skew and DRC checks; record hashes and compare the packed
  karudeb inputs. Update discovery/companion documentation only as implemented
  features require it, with no unsupported certification claims.
- [ ] **E4.8** On FPGA, exercise hardware watchpoints/breakpoints, autoexec bulk
  access and SBA RAM/MMIO while halted and running, using reserved scratch
  memory and counted device tests. Verify detach, normal karudeb boot and the
  maintained board acceptance tests. Record simulator, FPGA and ASIC evidence
  separately; FPGA success does not establish silicon CDC/DFT/timing signoff.
- [x] **E4.9** Update the implemented contract, requirements-to-tests map,
  measurements, handoff and tool instructions as features land. Keep unmet
  gates unchecked and distinguish hardware support from debugger limitations.
  The current combined source-hashed record, all twelve fresh mapped rows,
  routed FPGA reports and verified programming bundle are recorded. Board
  acceptance and the 200 MHz ASIC timing goal remain separate open gates.

### Further deferred work

Multi-hart support is excluded from this plan. Authentication protocols,
dynamic security domains, richer context sidebands/cache partitioning, debug
power management and hardware-translated debugger memory access remain separate
scope. Production lifecycle/fuse policy belongs to the ASIC SoC integration;
the enable/lock and transaction-authorization contract must be explicit without
requiring those larger features in the first extension implementation.
