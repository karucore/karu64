# karudbg

karudbg is the planned RISC-V Debug 1.0 implementation for Karu. It lives in
`karu64/dbg/` and is maintained as part of the karu64 repository. This document
is the initial implementation and testing plan; no debug RTL, build targets,
or compliance results are supplied yet.

The first implementation targets one RV64 hart, using execution-based debug
with a Debug ROM and Program Buffer. System Bus Access (SBA) and hardware
breakpoint/watchpoint triggers are outside the first implementation.

The same update also includes the core/platform AXI protection-metadata work
required by [security review finding S1](../doc/security-review-2026-09-14.md#s1--high-axi-protection-metadata-does-not-describe-the-requester).
This is required for ordinary core traffic as well as debug-origin accesses;
it must work with `KARU_DBG` disabled. Deliver two ordered milestones in this
update: **A, AXI protection RTL and tests**, followed by **B, karudbg and its
integration tests**. Milestone A implements the bits and their propagation,
defines the platform mapping and passes `axi-prot-test` before debug integration
is accepted. Both milestones belong to the initial update. S1 remains open
until its implementation, documented platform contract and tests are complete.

## Progress checklist

Current stage: implementation plan documented; RTL implementation and
validation have not started. Check an item only when its implementation and
required tests are complete. Add source and result links beside completed
items; a documented design choice alone does not close an implementation item.

- [x] Record initial scope, specification review, adoption origins and design
  choices, including the mainline OpenOCD source baseline.
- [x] OpenOCD installation prerequisite: verify the pinned mainline build,
  runtime libraries, installed scripts and simulation adapters (2026-10-26;
  commands and version recorded in the [initial contract](#initial-contract)).
- [ ] [Shared interface foundation](#1-shared-interface-foundation): build
  switch, core/DM interface, source manifests, provenance and license notices.
- [ ] [Milestone A](#2-milestone-a-axi-protection-metadata): implement AXI
  protection propagation and the platform contract; pass `axi-prot-test` with
  debug disabled before accepting milestone B integration.
- [ ] DM register bank and abstract-command engine: implement the
  [initial contract](#initial-contract); pass `dbg-unit-test`.
- [ ] [Core Sdext and run control](#3-milestone-b-core-sdext-support-and-precise-run-control):
  implement halt/resume/step, debug CSRs and instruction rules; pass
  `dbg-core-test`, including rejected Program Buffer DRET.
- [ ] [ROM and memory integration](#4-debug-rom-program-buffer-and-memory-integration):
  generate the ROM, enforce both aperture gates, support MMIO and pass
  `dbg-rom-test` and `dbg-memory-test`.
- [ ] [Reset, CDC and JTAG](#5-reset-clock-crossing-and-jtag): implement and
  verify reset domains, transport and FPGA BSCAN integration; pass
  `dbg-jtag-test` through pinned mainline OpenOCD/GDB.
- [ ] [Context and translation coverage](#testing-plan): pass
  `dbg-context-test` and complete `dbg-translation-test`, documenting supported
  mappings, tool limitations and debugger-policy differences.
- [ ] Functional acceptance: pass `dbg-test`, negative controls, four-state
  startup, lint and selected ordinary ISA regressions; rerun `axi-prot-test`
  with debug enabled. Publish the requirements-to-tests evidence.
- [ ] [Synthesis acceptance](#synthesis-and-hardware-acceptance): update ASIC
  inventories and Yosys area, run OpenSTA at the 200 MHz target and record
  Vivado routed timing at the 75 MHz core target.
- [ ] [Board acceptance](#synthesis-and-hardware-acceptance): demonstrate
  debug operations and MMIO, then normal karudeb boot and board acceptance
  after detach; record the tested configuration and compliance scope.

## Specification and implementation origins

The normative reference is the ratified
[RISC-V Debug Specification v1.0, revised 2025-02-21](https://docs.riscv.org/reference/debug/v1.0/):

- [Debug Module and abstract commands](https://docs.riscv.org/reference/debug/v1.0/debug_module.html).
- [Sdext: Debug Mode, stepping, debug CSRs and resume](https://docs.riscv.org/reference/debug/v1.0/Sdext.html).
- [JTAG Debug Transport Module](https://docs.riscv.org/reference/debug/v1.0/dtm.html).
- [Sdtrig](https://docs.riscv.org/reference/debug/v1.0/Sdtrig.html), for the
  required behavior when triggers are absent and for later extensions.

The adoption reference is
[pulp-platform/riscv-dbg at `643607e19df3435cfd77cc56143e2637f5900a6e`](https://github.com/pulp-platform/riscv-dbg/tree/643607e19df3435cfd77cc56143e2637f5900a6e).
That implementation advertises Debug 0.13.2. It provides a useful execution-based
design and verification material, but its version declaration and existing
tests do not establish Debug 1.0 compliance for karudbg.

karudbg will adopt selected PULP modules into Karu's coding conventions and
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
| DM register bank | `src/dm_csrs.sv`, `src/dm_pkg.sv` | Single hart; Debug 1.0 register behavior; no SBA advertisement |
| Abstract-command engine and debug memory | `src/dm_mem.sv` | RV64 transfers, Karu interfaces and exception protocol |
| Parking/command/resume ROM | `debug_rom/debug_rom.S`, `debug_rom/debug_rom.sv` | Two scratch CSRs; relocatable nonzero debug page; reproducible ROM generation |
| JTAG DTM and CDC | `src/dmi_jtag.sv`, `src/dmi_jtag_tap.sv`, `src/dmi_cdc.sv` | Local RTL conventions, explicit clock/reset contract and transport tests |
| FPGA transport option | `src/dmi_bscane_tap.sv` | Review USER-chain allocation and the board's JTAG tooling |

## Initial contract

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
| Auto-execution | `abstractauto` unimplemented: read zero, ignore writes; data/Program Buffer accesses never implicitly re-execute a command |
| Program Buffer | Eight 32-bit words initially; explicit terminating EBREAK, `impebreak=0` |
| Debug access checks | `abstractcs.relaxedpriv=0`; ordinary M-mode permission and instruction-state checks apply |
| Memory access | Instructions executed by the halted hart; no independent system-bus manager |
| Peripheral access | Required: physical MMIO reads/writes through the Program Buffer and the hart's normal memory path |
| AXI protection | Milestone A: meaningful `ARPROT`/`AWPROT`, static trusted per-hart Secure/non-secure selection, and preservation of transaction attributes end to end |
| SBA | Unimplemented: advertise `sbasize=0`, return zero and ignore writes for absent SBA registers, and generate no SBA requests |
| Triggers | Sdtrig absent; accesses to its CSRs raise illegal-instruction exceptions, including from Debug Mode |
| Optional DM features | No hart arrays/groups, Quick Access, Access Memory command, or separately programmable reset-halt request |
| Availability fields | `stickyunavail=0`: report current availability; `ndmresetpending=0` as an unimplemented optional field; `havereset` remains sticky |
| Absent core features | `dcsr.cetrig`, `dcsr.pelp` and `dcsr.nmip` read zero; no Smdbltrp, Zicfilp or NMI source in the initial configuration |
| Authentication | No authentication protocol initially; advertise that accurately. Define a platform enable/lock policy before deployment |

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
G-stage translation of VS page-table reads. This is a source inspection,
not an interoperability result. Use this revision for the first test build;
record any replacement revision explicitly. Verify host Sv39 and guest
Sv39/Sv39x4 accesses on Karu, including translated VS-PTE reads. Do not
advertise an untested virtual-access path. Software translation is not
automatically equivalent to hardware MPRV permission,
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

This completes tool installation only. No simulated-target connection or
`dbg-jtag-test` has run; transport and target interoperability remain unchecked.

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
Those capabilities require the deferred SBA system-bus manager and a working
target bus/peripheral reset domain.

## Implementation sequence

### 1. Shared interface foundation

- Use `karudbg` for the DM top and `karudbg_*` for helpers under `dbg/`.
  Keep synthesizable RTL
  compatible with the existing Verilog-2001, Vivado, Yosys and Genus flows:
  declarations before use, separate net declarations and assignments, no
  power-up initializers, and no inferred latches or variable-input division
  or remainder operators.
- Define a proposed opt-in `KARU_DBG` build switch in the normal extension
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
| `AxPROT[1]` | 0 = Secure, 1 = Non-secure. Use a trusted static per-hart integration input, tied Non-secure in default wrappers; RISC-V privilege does not select this domain |
| `AxPROT[2]` | 0 = data, 1 = instruction. Mark actual fetches as instruction accesses; PTE reads are data accesses even when emitted on the instruction AXI port |

The initial platform contract is deliberately limited and must accompany the
ASIC handoff and FPGA integration:

- The Secure/non-secure input is trusted platform configuration, stable during
  operation and shared by all accesses from the hart. It can change only across
  a platform reset that quiesces or cancels old bus requests and invalidates
  caches/TLB/PWC state before new traffic. Debug entry does not change it.
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

## Testing plan

Keep test sources and harnesses in the repository, primarily under
`test/dbg/`, with shared firmware under `test/fw/` where appropriate. Put
generated models, ROM outputs, traces and reports under `_build/dbg/`.
Document exact commands, tool revisions, configuration flags and expected
results as targets become available. Target names below are planned, not
currently implemented.

| Planned gate | Required coverage |
| --- | --- |
| `axi-prot-test` | Milestone A with debug disabled: effective privilege, fixed Secure/non-secure domain, request producers, cache contract, queues, stalls and peripheral firewall denial; extend and rerun with debug in milestone B |
| `dbg-unit-test` | DM CSR reset/WARL/read-only behavior; native/narrow reads and rejected writes; hart selection; current availability; activation; absent/autoexec registers; DMI backpressure; abstract-command errors and recovery |
| `dbg-rom-test` | Reproducible ROM image; scratch preservation; halt/going/exception/resume handshake and authorized DRET; each supported abstract transfer; malformed commands |
| `dbg-core-test` | Precise halt/resume/step, correct DPC/cause, debug CSR permissions, EBREAK controls, rejected Program Buffer DRET and debug exception containment |
| `dbg-memory-test` | Core Debug Mode and platform requester gates for the debug page; MMIO permissions/cache bypass; access widths and byte lanes; device side effects; AXI stalls/errors; independent AW/W; repeated requests; dynamic Program Buffer updates; code-write/FENCE.I readback |
| `dbg-context-test` | M/S/U/VS/VU entry and return; H metadata; scalar FP, vector, Zvk and Keccak state round trips; representative arithmetic and memory instructions in Debug Mode |
| `dbg-translation-test` | Pinned OpenOCD software walks for host/guest pages, high GPAs, Svnapot, error containment and documented differences from hardware translation |
| `dbg-jtag-test` | TAP/DTM protocol, CDC, sticky busy/errors, TMS/TRST reset, frequency/phase variation, and OpenOCD/GDB through remote bitbang |
| `dbg-test` | Aggregate functional gate plus the selected ordinary ISA regressions for debug-enabled and debug-disabled models |

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
  fill policy and normal MMU permissions. Check static-domain changes only
  across the prescribed reset/quiescence sequence, with invalidated caches
  and TLB/PWC state. Stall AR/AW and queue stores across privilege changes;
  the original request's attributes must remain unchanged.
- Reset during each DMI/abstract-command phase; DM deactivation and
  reactivation; sticky `havereset` and command-error clearing.
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

## Deferred work

SBA requires a separate AXI master, full-address error handling and a cache
coherence policy before it is advertised. Gate address autoincrement on a
successful bus transfer, including error-response tests required by v1.0.
Dynamic security domains, richer AXI context sidebands and context-sensitive
cache/TLB/PWC reuse require a separate platform contract when such protection
is needed; they are not prerequisites for milestone A's limited contract.
Hardware triggers, additional harts, authentication protocols, debug power
management and hardware-translated debugger memory accesses have separate
scope. Any later feature must update discoverability, provenance and the
requirements-to-tests record before being enabled.
