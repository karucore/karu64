# karudbg and core integration review — 2026-11-15

Review date: **2026-11-15**. Source checkpoint: `5d74fc3` (branch `rvdebug`).
Scope: the opt-in RISC-V Debug 1.0 implementation ([karudbg](../dbg/README.md))
with all extensions (`KARU_DBG_FULL`: autoexec, Sdtrig address triggers, System
Bus Access), its core Sdext integration, the Milestone A AXI protection
metadata, the SBA bus coordinator, and the VCU118 integration of those blocks.
The core's AXI manager interfaces (IFU, I-cache, data memory, LSU, VLSU and the
page-table walker) were reviewed for AXI robustness on the same checkpoint.
This is a source, simulation and bounded-formal review. It is not a
penetration test, physical side-channel evaluation, silicon/board validation
or Debug 1.0 compliance certification. Vivado was unavailable; no new
synthesis or timing result is claimed.

It follows the [2026-09-14 configuration review](security-review-2026-09-14.md),
whose finding numbers S1–S5 are continued here as S6 onward. S1 (AXI
protection metadata) has since been implemented; S2–S5 are platform
obligations unchanged by this branch and are not re-reported.

## Result at the reviewed checkpoint

No High or Medium RTL defect was found in the debug module, transport,
trigger bank, SBA coordinator or core run control. The trigger bank's CSR,
WARL and match logic was proven equivalent to an independent Sdtrig model
under bounded model checking, and random co-simulation of the SBA coordinator
with the DDR crossbar found no AXI, ordering or data errors. Randomized
AXI-slave testing of the shipping cache, I-cache and LSU paths, with error
injection and flushes, likewise found no protocol or data error.

One High-severity deployment gap remains: the debug module has no
authentication or runtime lock, so any JTAG access grants full machine-mode
control and independent bus mastering (S6). One Medium-severity AXI defect,
which predates this branch, affects only the scalar `KARU_NO_MEM` build
(S7). Six Low-severity defects were confirmed in simulation or by inspection
(S8–S13). They affect robustness and fidelity of debug operations, not the
isolation of a non-debugged system.

| ID | Severity | Area | Summary | Evidence |
| --- | --- | --- | --- | --- |
| S6 | High (deployment) | DM policy | No authentication or runtime enable/lock; JTAG = M-mode + SBA | Inspection |
| S7 | Medium (`KARU_NO_MEM` only) | Core AXI | LSU requires AW and W in the same cycle; an AXI slave accepting them separately causes endless repeated stores | Confirmed, simulation |
| S8 | Low | DM state machine | `dmactive=0` during a command silently corrupts hart `a0`/`s0` | Confirmed, actual core |
| S9 | Low | USER4 transport | Truncated USER4 scan desynchronizes inner TAP; later frames issue phantom DMI ops | Confirmed, simulation |
| S10 | Low | Reset/CDC | Combinational `ndmreset_o` drives asynchronous reset synchronizers (glitch) | Inspection |
| S11 | Low | Run control | Single-stepped WFI bypasses its illegal/virtual-instruction checks | Confirmed, actual core |
| S12 | Low | Run control | Debug WRS-as-NOP match also swallows `fence w,iow` / `fence 0,iow` | Confirmed, actual core |
| S13 | Low | Verification | Narrow SBA DRAM accesses violate the crossbar's DRAM contract assertions; debug top is never co-simulated with the crossbar | Confirmed, simulation |

Informational observations follow the findings.

**Remediation follow-up, 2026-11-15.** S7–S13 have RTL fixes in the working
tree. The fixes have not yet been committed, synthesized or run on a board.
Each finding section opens with its fix note.

An independent check of the first fixes found that S8 acknowledged
deactivation before the command engine had reset. S8 now holds
deactivation pending until the engine is idle.

The disposable reproducers are superseded by maintained targets in the
non-board gate. Each target is either sensitive to the pre-fix behaviour
through its own mutant control, or was shown once to fail on pre-fix RTL:

| Finding | Target | Negative evidence |
| --- | --- | --- |
| S7 | `lsu-aw-w-test` | In-target joint-only mutant |
| S7 | `nomem-aw-w-isa-test` | Positive end-to-end run. The joint-only mutant hung all 29 tests in a separate run. |
| S8 | `dbg-unit-test` | In-target early-acknowledgement mutant; pre-fix RTL also fails |
| S8 | `dbg-core-test` deactivation sweep | Positive. Protocol discrimination comes from `dbg-unit-test`. |
| S9 | `dbg-bscan-truncate-test` | In-target mutant without the TRST pulse |
| S10 | `dbg-ndmreset-flop-test` | In-target combinational mutant; pre-fix RTL also fails |
| S11, S12 | `dbg-run-control-test` (S11 includes VS/VU) | Positive. Pre-fix core failed in a separate run, caught by live INV41a. |
| S13 | `dbg-sba-xbar-test` | In-target raw-beat (X44) and `req_ready_ignores_core` (SBAB2) mutants |

INV41 has driven-state legal sequences and nine corrupted cases in
`dbg-trigger-invariant-test`.

`make dbg-test` passes the complete non-board gate with all of these
targets: 281 input hashes unchanged, exit status zero. The run took 309.69 s
on models reused from a 1,694.84 s full-rebuild run on the same RTL. The
record is in [dbg/README.md](../dbg/README.md#current-combined-validation-record).
`lsu-atomic-test` and `mem-stream-test` also pass.

**S6 follow-up, 2026-11-18.** S6 remains open. Three statements of the
2026-11-16 follow-up below have changed:

- *FPGA integration.* The default VCU118 debug image is now built with
  `KARU_DBG_AUTH` (bitstream `d7ff00dc…3e80`; every authentication case
  passed on the board on 2026-11-18,
  [record](../dbg/BOARD_ACCEPTANCE-2026-11-18.md)), with the
  lifecycle and the boot hold on DIP switches. With all switches off the
  lifecycle is `OPEN` and the exposure is that of S6. In `AUTH` the ROM
  verifies with the simulation-only `TEST` algorithm, whose key is public,
  so the image validates the mechanism and protects nothing. An FPGA is
  still not a security target for this scheme.
- *End-to-end OpenOCD run against the framed ROM.* It exists:
  `dbg-board-auth-rehearsal-test`, with pristine OpenOCD and the board's
  client against the simulated target.
- *A finding in the mitigation itself.* The island SRAM was executable in
  the physical access permissions, so `HLVX` could read it as code through
  the data port although the island refuses instruction fetches. It is
  data only now (`sv39-auth-pma-test`).

The production verifier (plan D3), the open formal lemmas and the
platform obligations are unchanged.

**S6 follow-up, 2026-11-16.** S6 remains open. An opt-in mitigation,
`KARU_DBG_AUTH`, now exists in RTL, but it is not complete and default builds
are unchanged: they still have no authentication and report
`authenticated=1`. The design is in the
[authentication plan](debug-auth-plan.md) and the normative interface in the
[contract](debug-auth-contract.md).

What exists:

- **Lifecycle gate.** A platform lifecycle input selects `OPEN`, `AUTH` or
  `DISABLED`. While debug is not enabled (`DISABLED`, or `AUTH` without a
  grant), the DM shows only the Debug 1.0 locked view and has no effect on
  the hart or the bus, and the core refuses Debug Mode entry.
  This is controls 1 and 2 of the list under S6: a lifecycle-derived enable,
  and a firmware lock that is sticky until power-on reset.
- **Challenge–response path.** In `AUTH`, a boot ROM in a trusted island can
  grant debug once per power-on reset, through an `authdata` mailbox. Hardware
  confines where the grant can come from: M-mode code issuing from the island
  ROM, before any trap, reset, Debug entry or exit from the ROM.
- **Revocation.** Firmware or a platform input can revoke debug until
  power-on reset; a hart caught in Debug Mode is then reset.
- **Evidence.** The functional gate covers these flows on the real core and
  with pristine pinned OpenOCD. Module-level formal lemmas with negative
  controls cover the locked DM, the core entry gate, the authentication
  block, revocation, CSR provenance, island response routing and reset
  values. The record is in
  [dbg/README.md](../dbg/README.md#debug-authentication-karu_dbg_auth).

What is missing before S6 can be closed:

- **No production verifier.** The only ROM is a simulation ROM whose `TEST`
  algorithm is a keyed XOR fold, not a signature. The signature algorithm is
  undecided (plan D3). Control 3 of the list is therefore a protocol and a
  hardware confinement, not yet an authentication.
- **Formal work is partial.** The bypass-freedom and noninterference lemmas
  (C1, C3) and the composition of the module-level lemmas are open.
- **Simulation is partial.** Four-state runs, revocation with an SBA
  transaction in flight, and an end-to-end OpenOCD run against the framed ROM
  are open.
- **The window deadline is a software cutoff** with a measured tolerance, not
  a hard one (contract §5.3).
- **No FPGA or silicon integration.** The VCU118 image does not include
  `KARU_DBG_AUTH`, and an FPGA is not a security target for this scheme.
- **Platform obligations** are the integrator's: island memories, lifecycle
  integrity, TRNG, strap and scan policy. They are listed in the
  [ASIC handoff](../flow/asic/README.md#debug-authentication-obligations-karu_dbg_auth).

A deployment that enables JTAG with a default build, or with `lc=OPEN`, has
the exposure S6 describes.

## Findings

### S6 — High for deployment: no debug authentication or runtime lock

`dmstatus` is a constant with `authenticated=1`
([dbg/karudbg.v:242](../dbg/karudbg.v#L242)); `authdata` is absent, and
[`karudbg_top`](../dbg/karudbg_top.v) has no enable, lifecycle or lock input.
The only access control is the static `SBA_ENABLE` parameter, which removes
SBA but leaves halt, abstract commands and the Program Buffer. Whoever can
drive TCK/TMS (or the VCU118 USER4 BSCAN chain) can halt the hart, execute
arbitrary M-mode code, read or write any physical address reachable by the
hart, and with SBA, master the bus while the hart runs. This bypasses every
architectural boundary, including any future PMP (S2) and the requester
metadata of S1, since debug accesses are by design privileged.

The README records the omission ("Define a platform enable/lock policy before
deployment"); it is reported here so that the ASIC handoff carries it as an
explicit obligation. Typical controls, in increasing order of flexibility:

1. A lifecycle/OTP-derived `debug_enable` input that clears `authenticated`
   and gates every DM side effect.
2. A firmware-written lock register, sticky until power-on reset, so boot ROM
   or secure firmware can disable or permit debug after its own checks
   (cf. Arm `DBGEN`/`SPIDEN`, and the RISC-V Sdsec per-privilege debug
   enables under development).
3. A challenge–response protocol through Debug 1.0 `authdata`
   (`dmstatus.authbusy`/`authenticated`): TRNG nonce bound to the device
   identity, signature verified against a key hash in OTP, constant-time
   verification and attempt rate limiting (cf. Arm PSA ADAC).

The [authentication and debug-lock plan](debug-auth-plan.md) develops the
third option with a ROM-confined window and a compositional proof plan.
Whichever is chosen, enforce it in the DM, not at the TAP, so that the
conventional TAP and the BSCAN tunnel are covered equally. While
unauthenticated, Debug 1.0 permits only `dmstatus`, `authdata` and
`dmcontrol.dmactive`; halt requests, abstract commands, Program Buffer and
SBA writes, `ndmreset` and `hartreset` must have no effect. Clear the
authorization at least on power-on reset, and decide whether `ndmreset` and
`dmactive=0` also clear it.

### S7 — Medium for `KARU_NO_MEM` builds: LSU write FSM requires joint AW/W acceptance

*Fix, 2026-11-15:* `S_AWW`, `S_AWW2`,
`S_AMO_B` and `S_CBOZ_W` now drop each VALID on its own handshake and wait for
B once both are accepted, with local checks that no request is pending in a
B-wait state. Verification:

- The S7 reproducer now reports `CLEAN`.
- A `KARU_NO_MEM` core passes 110/110 `rv64u{i,c,m,f,d,a}-p` tests both
  without stalls and with `+ddr_stall=3`.
- With a `_build` copy of `htif_tb` that accepts W two cycles after AW, the
  fixed core passes 110/110. The pre-fix LSU fails 19 AMO tests.
- The default (L1) core passes the same three runs.

Two maintained targets cover both acceptance orders.

- **`lsu-aw-w-test`** (`test/tb_lsu_aw_w.sv`) drives `karu_lsu` through every
  write state: aligned, IO and SC stores (`S_AWW`), split stores (`S_AWW2`),
  AMO (`S_AMO_B`) and CBO.ZERO (`S_CBOZ_W`). Each runs against a legal
  subordinate in four orders: joint, AW-first lag 1–4, W-first lag 1–4, and
  eight random seeds. The bench checks the handshake count per beat, the
  payloads, stability, the memory image and quiescence. A `_build` mutant
  restoring the joint-only handshake passes the joint order and fails each
  split order.
- **`nomem-aw-w-isa-test`** runs 29 ISA tests on a `KARU_NO_MEM` htif model
  with the new `+ddr_w_lag` (AW first) and `+ddr_aw_lag` (W first) options, at
  lags 1 and 3. The tests are all 19 `rv64ua-p` plus the scalar, misaligned,
  compressed and FP store tests. Each run's `[ddr_skew]` count must show only
  the requested order. The joint-only mutant hangs in all 29 tests.
- `lsu-atomic-test` still passes its 27,708 checks.


The LSU's write states advance only on
`awvalid && awready && wvalid && wready` in a single cycle
([rtl/karu_lsu.v:422-430](../rtl/karu_lsu.v#L422), and likewise `S_AWW2`,
`S_AMO_B` and `S_CBOZ_W`). AXI4 permits a subordinate to accept AW and W in
different cycles and in either order. In the default builds the LSU talks to
`karu_mem`, which always raises `s_awready` and `s_wready` together, and
[test/tb_lsu_atomic.sv](../test/tb_lsu_atomic.sv) records this as an internal
contract. With `KARU_NO_MEM`, however, the LSU is connected directly to the
external dmem arbiter ([rtl/karu64.v:2040-2077](../rtl/karu64.v#L2040)),
which masks `awready` after AW is accepted until B arrives
([rtl/karu64.v:1824-1827](../rtl/karu64.v#L1824)).

With a subordinate that accepts W one or more cycles after AW, the LSU never
observes the joint handshake. It keeps AW and W asserted and `bready` high,
consumes and ignores the first B (including any error response), and the
arbiter re-presents the same AW when its lock drops. A simulation of the real
`karu_lsu` with the arbiter's write gating and a W-delayed subordinate issued
the same store to `0x80000100` 12 times in 60 cycles without completing. In
`S_AMO_B`, B is sampled independently, so the FSM can return to IDLE with
`awvalid`/`wvalid` still asserted and then change the payload of a pending
VALID. On a device page each repeat is an extra side effect, such as an
additional UART character or doorbell write.

`KARU_NO_MEM` requires `KARU_NO_V`, so the RVA23S64 shipping and VCU118
configurations are not affected. The scalar area-matrix rows
(`imac_core_m4d64`, `imacb_core_m4d64`) and the
[flow/syn quick start](../flow/syn/README.md) use it, and that README
directs readers to it for directly synthesized processor-only numbers; no simulation
target exercises it. Track AW and W acceptance separately, as `karu_mem`'s
`S_WR_B`/`S_IO_W` states do, or insert an AW/W join adapter in the
`KARU_NO_MEM` branch, and add a simulation of that configuration with
independent AW/W stalls before it is used outside area estimation.

### S8 — Low: deactivating the DM during a command corrupts hart registers

*Fix, 2026-11-15 (revised):* Debug 1.0 makes `dmactive` readback the
acknowledgement that deactivation has completed, and an inactive DM holds
reset values. A first fix kept the executing words but let `dmactive` read 0
at once, so an immediate reactivation exposed the old command as busy.

Now a `dmactive=0` write while a command is busy, in GO or executing, is held
pending, and the DM stays fully active. Deactivation completes, and
`dmactive` reads 0, only once the engine is idle: the hart has parked,
faulted back to the ROM, been reset or become unavailable. The inactive state
then clears every register to its reset value, and reactivation starts idle.
A `dmcontrol` write with `dmactive=1` cancels a pending request.

Local checks enforce these rules:

- `dmactive` never falls while the engine is busy;
- an inactive DM holds reset values;
- the command template is stable while busy.

A hung Program Buffer keeps deactivation pending. Recovery is a `dmcontrol`
write with `dmactive=1, ndmreset=1`, which resets the hart and ends the
command with `cmderr=4`; deactivation then completes immediately.
OpenOCD's examine-time `dmactive` pulse waits for readback and is
unaffected when the DM is idle.

Maintained tests:

- `dbg-unit-test` checks the protocol at DM level: GO and executing requests,
  frozen words, cancellation, ndmreset recovery and unavailability. A mutant
  that acknowledges deactivation at once must fail.
- `dbg-core-test` sweeps the deactivation write over every cycle from the
  command launch until three consecutive delays find the engine already idle.
  That is 158 delays, 155 of them while busy. Every delay polls `dmactive` as
  the specification requires, and `a0`, `s0` and `mscratch` survive each one.
  A hung Program Buffer is recovered on the real core.


The ten-word abstract-command sequence is generated combinationally from
`command_q` ([dbg/karudbg.v:209-237](../dbg/karudbg.v#L209)). It borrows
`a0` and `s0`, saving them in `dscratch1`/`dscratch0` and restoring them
before its EBREAK. A `dmcontrol` write with `dmactive=0` is accepted even
while `busy=1` ([dbg/karudbg.v:405](../dbg/karudbg.v#L405)); on the next
clock the inactive branch clears `command_q` and the Program Buffer
([dbg/karudbg.v:341-354](../dbg/karudbg.v#L341)). A hart that is part-way
through the sequence then fetches NOPs instead of the restoring CSR reads,
reaches the EBREAK and returns to the ROM, which saves the corrupted values
as the program's `a0`/`s0`. Because `cmderr` is also reset, nothing reports
the corruption, and it survives resume.

Simulation of the actual core through DMI, sweeping the deactivation point
over 70 cycles of an Access Register command, corrupted registers at 20
points: `a0` became the debug-page base or an `auipc` result, and at two
points `s0` returned the transferred CSR value. The exposure is a window of
roughly 20 core cycles per command; it is most likely when a debugger
session that died mid-command is replaced and the new session pulses
`dmactive`.

Debug 1.0 allows the DM to take arbitrarily long to complete deactivation
(the debugger polls `dmactive`). Either keep `dmactive` reading 1 until a
busy command has reached HALTED, or retain `command_q` (and the Program
Buffer if `postexec` is running) until the hart parks, then perform the
remaining reset. Add an INV check that `a0`/`s0` at resume equal their values
at debug entry when no abstract write targeted them.

### S9 — Low: truncated USER4 scans desynchronize the inner TAP

*Fix, 2026-11-15:* the tunnel now pulses the inner TRST for one TCK at the
capture following an incomplete frame. The inner TAP reaches
Test-Logic-Reset without Update-DR, and the header's leading TMS=0 bits
return it to Idle. `karudbg_bscan` and the simulation wrapper
`tb_bscan_remote` now connect that output. The truncation sweep reports 0/52
anomalies, with no phantom DMI requests.

The maintained test is `dbg-bscan-truncate-test`. It cuts a USER4 DMI-write
frame after each of bits 1–52, without an outer TLR, and checks five things:

- no phantom or corrupted DMI request;
- DTMCS reads `0x1071`;
- the inner TAP is back in Idle;
- `data0` holds the expected value;
- a fresh write and readback works.

A mutant tunnel without the recovery pulse fails 110 of the 364 checks.


[`karudbg_bscan_tunnel`](../dbg/karudbg_bscan_tunnel.v) synthesizes inner-TAP
TMS assuming the inner TAP starts each frame in Run-Test/Idle. The outer
Capture-DR resets only the tunnel's own `phase`
([dbg/karudbg_bscan_tunnel.v:61-65](../dbg/karudbg_bscan_tunnel.v#L61)); the
inner TCK is the raw outer TCK and `inner_trst_n_o` follows only the tunnel
reset ([:31-33](../dbg/karudbg_bscan_tunnel.v#L31)). If a USER4 scan is cut
short (adapter fault, cable glitch, a tool other than the pinned OpenOCD), the
inner TAP stays in a Shift or Exit state, and later well-formed frames are
interpreted from that state. In simulation, truncating a DMI-write frame at
each of 52 positions and following it with a well-formed DTMCS select/read
misbehaved in 45 cases: DTMCS read as all zeros or all ones, unrequested DMI
reads and writes were issued to addresses 0x1c/0x1d, and with a cut after 50
bits the aborted `data0` write was completed by the unrelated frame. Shifted
data can therefore reach any DM register, including `dmcontrol`
(`ndmreset`/`haltreq`), `command` and `sbdata0` (an SBA bus write).

The repository's protocol test defines outer Test-Logic-Reset as the recovery,
and OpenOCD resets the chain at initialization, so this is a robustness issue
rather than a privilege boundary (S6 already grants full access). Make each
frame self-synchronizing: if the previous frame did not reach `PAD`, return
the inner TAP to a known state before the next header without committing the
partial request.

Do not recover with five TMS=1 clocks. From Shift-DR or Exit1-DR, that
sequence passes through Update-DR and would commit the truncated DMI
request before reaching Test-Logic-Reset. Instead:

- pulse a controlled inner reset (`inner_trst_n`, which forces
  Test-Logic-Reset asynchronously, without Update-DR); or
- suppress DMI commits while recovery is in progress.

Add a test that recovery itself issues no DMI operation, alongside the
truncation sweep.

*Correction, 2026-11-15:* an earlier revision of this paragraph suggested
the five-TMS sequence.

### S10 — Low: `ndmreset_o` is a combinational AND feeding asynchronous resets

*Fix, 2026-11-15:* `ndmreset_q` is set only while `dmactive` stays 1, and
`ndmreset_o` is that flop. A local assertion checks `ndmreset_q → dmactive_q`,
and the structural check finds a flop driver. The OR terms inside
`karudbg_fpga_reset` are unchanged.

`dbg-ndmreset-flop-test` (`test/dbg/check_output_flop.py`) maintains the
structural check with Yosys, on the base and SBA+autoexec builds. It requires
`ndmreset_o` to be driven only by a flop's Q. The pre-fix AND, restored as a
mutant, must fail.


`ndmreset_o = dmactive_q && ndmreset_q`
([dbg/karudbg.v:113](../dbg/karudbg.v#L113)) reaches the asynchronous reset
inputs of both `karudbg_reset` synchronizers in
[`karudbg_fpga_reset`](../dbg/karudbg_fpga_reset.v) through further OR logic.
A single `dmcontrol` write of `0x00000002` while the DM is active changes
`dmactive_q` 1→0 and `ndmreset_q` 0→1 on the same edge
([dbg/karudbg.v:406-407](../dbg/karudbg.v#L406)). The AND is logically 0
throughout, but a LUT or gate implementation can glitch high and
asynchronously reset the CPU-side SoC and the MIG AXI shim. The reset-input
false paths hide the hazard from timing analysis, and RTL simulation cannot
show it. Drive `ndmreset_o` from a single flop (for example, clear
`ndmreset_q` in the same branch that clears `dmactive_q`, then output
`ndmreset_q` alone), and register the OR terms in `karudbg_fpga_reset` in the
source domain before they reach an asynchronous reset pin. On the ASIC top
the same signal is used only as a synchronous reset term
([dbg/karudbg_core.v:90](../dbg/karudbg_core.v#L90)), where it is benign, but
an SoC integrator reusing `ndmreset_o` as an asynchronous reset inherits the
hazard.

### S11 — Low: single-stepped WFI bypasses its privilege checks

*Fix, 2026-11-15:* the `!dbg_step_active` terms are removed from `wfi_ill`
and `wfi_virtual`. INV41a recomputes WFI legality independently.

`dbg-run-control-test` (`test/dbg/tb_run_control.sv`, built with
`KARU_H`) checks, on the real core, the trap cause, `mepc`, the trap-origin
`mstatus.MPP`/`MPV`, and `dpc`/`dcsr.cause`. Its 15 WFI cases:

- U, U+TW and S+TW, stepped and unstepped, trap with `mcause=2`;
- VS+VTW, VU and VU+VTW trap with `mcause=22`;
- VS+TW and VU+TW trap with `mcause=2`;
- permitted stepped WFIs in M+TW, S and VS retire as NOPs.

The bench also attaches the live INV40/INV41 checker. Against the pre-fix
core, INV41a fires on the first stepped U-mode WFI. The driven-state fixture
in `dbg-trigger-invariant-test` adds INV41 legal sequences and nine
deliberately corrupted cases (INV41a ×5, INV41b ×2, INV41c ×2).


`wfi_ill` and `wfi_virtual` are gated with `!dbg_step_active`
([rtl/karu64.v:2565-2569, 2584-2588](../rtl/karu64.v#L2565)). With
`dcsr.step=1`, a WFI that must trap — always in U-mode on this core, in S-mode
with `mstatus.TW=1`, or in VU or VS with `hstatus.VTW=1` (virtual
instruction) — retires as a NOP and dpc advances. On the actual core a
stepped U-mode WFI halted with `dpc=pc+4` and `mcause` unchanged; the same
instruction run normally trapped with `mcause=2`.

Debug 1.0's single-step rules convert a stepped instruction to a NOP only when it "would
normally stall the hart"; an illegal or virtual-instruction WFI does not
stall, it traps. The program therefore behaves differently under a debugger
than without one. This is not an escalation (only the debugger can set
`step`), and the README's "stepping over any of them treats it as a NOP" is
broader than the specification. Remove `!dbg_step_active` from both terms;
keep `!debug_mode` in `wfi_ill` (Debug Mode executes at M, so it has no
effect there).

### S12 — Low: Debug-Mode WRS NOP matching also catches two FENCE encodings

*Fix, 2026-11-15:* `dbg_wrs_nop` also requires the SYSTEM opcode and
funct3=0, matching the decoder. INV41b requires every MISC-MEM FENCE to issue
its handshake, and INV41c requires WRS to remain a NOP in Debug Mode and while
stepping. All stepped and Program Buffer fence cases report `CLEAN`.
`dbg-run-control-test` maintains these six FENCE cases, three stepped and three
from the Program Buffer.


[rtl/karu64.v:2421-2423](../rtl/karu64.v#L2421) identifies WRS.NTO/WRS.STO
by `ex_sub == SYS_FENCE` and `ex_ins[31:20] ∈ {0x00d, 0x01d}`. The decoder
also maps ordinary MISC-MEM FENCE to `SYS_FENCE`
([rtl/karu_dec.v:131](../rtl/karu_dec.v#L131)), and the FENCE immediate
`fm|pred|succ` for `fence w,iow` is `0x01d` and for `fence 0,iow` is `0x00d`.
In Debug Mode or while stepping, those two fences retire as NOPs and skip
`issue_cacheop`, so no platform `cache_flush_req` handshake is made. Pulse
counting on the actual core shows exactly one missing handshake for each,
both from the Program Buffer and when stepped. Internal ordering remains
correct (`exec_busy` includes `mem_store_pending`), and the VCU118 ties
`cache_flush_done` high, so the effect is limited to ASIC platforms that
implement the FENCE handshake for an outer cache or write buffer. Also match
the SYSTEM opcode (`ex_ins[6:0] == 7'b1110011`, `funct3 == 0`).

### S13 — Low: narrow SBA DRAM accesses break the crossbar's DRAM-side contract

*Fix, 2026-11-15:* RAM-class SBA requests (`sba_ram`) now use one aligned
64-bit beat with byte strobes, with read-lane extraction in the adapter.
Device requests keep their exact address and size. Assertion SBAB9 checks
both forms. The crossbar co-simulation reports `CLEAN` for narrow SBA, and its
scoreboard controls still pass.

`dbg-sba-xbar-test` (`test/dbg/tb_sba_xbar.sv`) maintains the contained
co-simulation of `karudbg_bus`, the crossbar with its SIM_TB assertions, the
AXI RAM model and the real peripherals, with fixed seeds. It has two mutants:

- the pre-fix raw-beat path, with SBAB9 disabled, must fail on crossbar X44;
- `req_ready_ignores_core` must fail on SBAB2.

The complete debug-enabled VCU118 top is not simulated.


SBA forwards the requested size and unaligned address to the fabric
([dbg/karudbg_bus.v:143,151](../dbg/karudbg_bus.v#L143)). The crossbar passes
them through to its DRAM master, whose documented contract and assertions
(X38/X39/X44/X45 in
[flow/fpga/assert/karu_ddr_xbar_assert.v:372-385](../flow/fpga/assert/karu_ddr_xbar_assert.v#L372))
require 8-byte-aligned 64-bit INCR beats. A random co-simulation of the real
`karudbg_bus`, `karu_ddr_xbar` and peripherals failed X44/X45 within 13–420
cycles once SBA issued 8/16/32-bit DRAM writes, and passed (0 errors over
6×300k cycles) with SBA DRAM accesses forced to 64 bits. The transfers are
legal AXI, and on the VCU118 the 64→512 width converter (`PACKING_LEVEL=1`,
modifiable `AxCACHE`) should present full-width beats to the MIG, so a
hardware failure is not expected. The defect is that the only debug-enabled
integration, `vcu118_ddr_top`, is never simulated with the crossbar, and the
crossbar's narrower contract is violated by a legal debug master.
Either issue SBA DRAM accesses as aligned 64-bit beats with narrow `WSTRB`
and read-lane extraction (as the core does), or relax the assertions to
admit legal narrow single beats; in both cases add a bus+crossbar
co-simulation to the debug regression.

## Informational observations

These are documented choices, defense-in-depth gaps or fidelity notes. None
is a defect against the stated contract.

Debug module and transport:

- `havereset` is forced to 0 while `dmactive=0`
  ([dbg/karudbg.v:347](../dbg/karudbg.v#L347)), so a hart reset that occurs
  while the DM is inactive is never reported after activation.
- If the hart is stuck in the Program Buffer (for example, a device load that
  never responds) when the DM is reactivated, `dmstatus` reports running
  while the hart is still in Debug Mode; only `ndmreset` recovers. The SBA
  equivalent is documented. *Superseded by the S8 fix:* a deactivation
  request is no longer acknowledged while a command is busy, so the DM stays
  active with the command visible as busy. `dmactive=1, ndmreset=1` recovers
  the hart.
- SLVERR, DECERR and a missing RLAST all map to `sberror=2` (bad address)
  ([dbg/karudbg_bus.v:195,203](../dbg/karudbg_bus.v#L195)); Debug 1.0's
  `sberror=7` (other) better describes a responder error.

Bus and platform:

- The private debug-page bridges tie `allow_i` to 1
  ([dbg/karudbg_core.v:440,484](../dbg/karudbg_core.v#L440)), so exclusion of
  ordinary M-mode accesses rests on the `debug_mode_i` term in
  [`karu_pma_ok`](../rtl/karu_pma.vh#L27), applied at every producer (IFU,
  LSU, VLSU translation, page walker and TLB hits). SBA is excluded twice, by
  its own address check with `debug_mode_i=0` and by the page decoding to the
  boot-window hole on the external fabric. Driving `allow_i` from
  `debug_mode` would add an independent second gate for core traffic.
- The crossbar routes every non-boot `imem` address to DRAM and the MIG
  receives `araddr[30:0]` ([flow/fpga/karu_ddr_xbar.v:308](../flow/fpga/karu_ddr_xbar.v#L308),
  [flow/fpga/vcu118_ddr_top.v:431](../flow/fpga/vcu118_ddr_top.v#L431)), so a
  fetch of a device or unmapped address aliases into DRAM with OKAY. Only the
  core PMA prevents this; DECERR would be the safer fabric response. Reads of
  the boot-window hole (`0x111000–0x1fffff`) and writes to ROM likewise
  return OKAY.
- AxPROT is propagated to the MIG but enforced nowhere on the VCU118 fabric.
  This is consistent with Milestone A's advisory contract; S1's platform
  obligation remains open.
- The SBA arbiter gives the core strict priority. A zero-gap ideal master
  starves SBA indefinitely; the real core always leaves idle cycles between
  transactions, and halting the hart is an escape. No deadlock was found:
  RAM-write acceptance requires the registered pause and quiet, and the page
  walker never writes.
- `ndmreset` now also resets the MIG AXI shim
  ([flow/fpga/vcu118_ddr_top.v:160](../flow/fpga/vcu118_ddr_top.v#L160)),
  which was previously reset only at calibration and board reset. Behaviour
  with native-interface commands in flight is untested; include `ndmreset`
  during DRAM and SBA traffic in board acceptance.

Core AXI managers:

- In `KARU_EN_MEM` builds the raw dmem R channel is presented to both the
  DMMU walker and `karu_mem` ([rtl/karu64.v:1891,2031](../rtl/karu64.v#L1891));
  the imem side and the `KARU_NO_MEM` path filter it by read owner. Overlap is
  prevented today by scheduling (walks complete before the access is issued),
  not by construction, and no assertion covers it. Gating `rvalid` with
  `rd_owner_dmmu` would make it structural.
- An error on any beat of a line refill faults the whole access, even if the
  requested word returned OKAY; no partial line is marked valid. This is
  conservative and remains precise.
- Side note, not pursued: VLSU mask indexing (`pe_i[7:0]`) and 6-bit granule
  counters are sized for VLEN=256. Non-RVA23 builds with VLEN ≥ 512 would
  need wider fields; the current elaboration guard does not reject them.

Triggers:

- Only the lowest byte address of each access is compared, which Sdtrig
  permits (comparing the other accessed bytes is only recommended) and Spike matches ([dbg/TRIGGERS.md](../dbg/TRIGGERS.md)).
  A GDB watchpoint on a 4-byte object therefore does not fire for an aligned
  `sd` covering it, for example from `memcpy`. Worth stating in user notes.
- Privilege filtering uses the executing privilege, not the MPRV or HLV/HSV
  effective privilege. This is acceptable and matches Spike, but E0-D3 in
  [dbg/README.md](../dbg/README.md) can be read as saying the opposite; one
  clarifying sentence would help.
- With a data trigger armed, vector stores skip the check-only pre-pass. A
  page fault at element *k* then commits elements `vstart..k−1`, and a
  faulting segmented store repeats earlier fields on resume. RVV allows both,
  but side effects differ with and without a debugger attached, which matters
  for non-idempotent devices.
- A disabled slot always reads back `dmode=0`, and NAPOT discovery with a
  stale low-63-ones `tdata2` reports NAPOT as unsupported if `tdata1` is
  written first. Both are legal WARL choices; OpenOCD writes `tdata2` first.

Run control:

- DRET discards IFU prefetch but performs no TLB or I-cache maintenance.
  After Program Buffer stores or `satp`/`hgatp` writes the debugger must issue
  `fence.i`/`sfence.vma`; pinned OpenOCD issues `fence.i` but not an sfence.
- The README documents entry-cause priority haltreq > ebreak > step; the RTL
  places triggers between haltreq and ebreak. dpc is correct in all cases;
  only the documentation is incomplete.

## Positive controls observed

- **Debug CSRs and DRET.** `dcsr`/`dpc`/`dscratch*` raise illegal-instruction
  outside Debug Mode on both H and non-H paths. DRET is honoured only at the
  ROM's resume PC during an authorized RESUMING handshake. `dcsr` WARL maps
  `prv=2` and unsupported modes to U and forces `v=0` with `prv=M`.
- **Debug entry and exit.** Entry captures dpc/prv/v without touching
  application trap CSRs, clears the LR/SC reservation, masks all interrupt
  sources and freezes counters. It waits for long, vector, cache and
  posted-store work. Exit restores privilege and V and clears MPRV below M.
- **Halt races.** Halt cannot coincide with retire, LSU/VLSU fault or
  interrupt acceptance. A simultaneous fetch page fault is suppressed with a
  precise dpc and re-raised on resume. A page walk in flight at entry is
  poisoned before its PMA check, so no PTE read or TLB fill follows entry.
- **Isolation of the debug-disabled build.** Every debug path is under
  `ifdef KARU_DBG`; without it, `retire_issue` and `trap_req` reduce to the
  main-branch logic.
- **AxPROT derivation.** Requester privilege is latched at request time for
  IFU, LSU (including MPRV and HLV/HSV via SPVP), vector and AMO write phases.
  Page walks are privileged data accesses. SBA drives `{data, NONSECURE,
  privileged}`.
- **Trigger bank (formal).** Bounded model checking against an independent
  model (2 slots to depth 8, 4 slots to depth 6) proves exact and NAPOT
  match over all 64-bit values, `maskmax6=63` discovery, `dmode` write
  protection, normalization of unsupported encodings, `tselect` WARL and the
  absence of matching in Debug Mode. A one-bit NAPOT mutation is detected.
- **Trigger timing.** Execute triggers precede instruction faults. Load/store
  triggers precede misaligned, page and access faults. Watched stores, AMOs,
  SC and vector stores have no side effects before the hit.
- **DTM and CDC.** `dmistat` stickiness, `dmireset`/`dmihardreset`, 41-bit DMI
  scans, a 5-bit IR resetting to IDCODE and BYPASS for unknown instructions
  all behave correctly. A 27-run random stress across clock ratios from 1:97
  to 97:1, with backpressure and resets on both sides, produced no
  duplicated, reordered or stale DMI operation.
- **Abstract commands and SBA engine.** `cmderr` precedence, busy rules, the
  32-bit read leaving `data1` unchanged, single launches under autoexec, SBA
  error precedence (4 > 3 > 2), success-only autoincrement and read-on-data
  ordering all match Debug 1.0. `SBA_ENABLE=0` reads zero and launches
  nothing. All DM control state is reset; the only unreset register is
  handshake-guarded.
- **SBA coordinator AXI behaviour.** VALID is independent of READY and
  payloads are stable. Stray responses stall rather than being consumed.
  WSTRB and lane placement are correct at every legal offset. 7.5k RAM writes
  completed the pause → quiet → write → maintenance sequence without deadlock
  or data mismatch. The private page, 33-bit aliases and ROM writes are
  rejected before bus activity.

## Validation run during this review

This section records the evidence collected at the reviewed checkpoint. The
finding-specific checks have since been rewritten as maintained targets in
the non-board gate; see the remediation follow-up above. The `_build`
package is the original, gitignored evidence and is not part of the
repository.

All checks below were written for this review. Tracked files were not
modified, and the repository's own long `make dbg-*` gates were not rerun.
The checks are kept as regression tests in `_build/review-2026-11-15/pkg/`
on the review host; `_build` is not tracked, so they are not in the
repository. Each area
has a `run.sh` with fixed seeds, mutants applied as diffs to build-directory
copies, and an `expected.txt` in which every finding is `REPRO` until it is
fixed.

```sh
_build/review-2026-11-15/pkg/run_all.sh          # default mode, about 3 minutes warm
FULL=1 _build/review-2026-11-15/pkg/run_all.sh   # the full sweeps quoted below
```

On `5d74fc3`, the default mode matched `expected.txt` in all five areas when
run in place from the repository. The `FULL=1` sweeps were run once per area
during packaging and reproduced the figures below. Two of those figures
moved slightly:

- The random `karu_mem` sweep now reports 83,065 data checks. Its memory
  model was changed to corrupt data on error responses, which is needed to
  detect the error-fill mutant.
- The S12 case now measures `cache_flush_req` at the fence's issue cycle,
  instead of inferring the missing handshake from total pulse counts.

| Check | Result |
| --- | --- |
| Verilator `-Wall` lint, `karudbg_top` with `KARU_DBG_FULL` and the RVA23S64 shipping defines | No errors. Width, case and index warnings were triaged: indices are range-checked and incomplete `case` items are unreachable FSM encodings |
| Trigger bank vs independent Sdtrig model (Yosys SAT BMC) | PASS: 2 slots to depth 8, 4 slots to depth 6. NAPOT off-by-one mutation FAILS as intended |
| Actual core + DM, DMI-driven probes (Verilator) | S8 reproduced (20/70 deactivation points), S11 reproduced, and S12 reproduced by `cache_flush_req` pulse counts |
| DTM/CDC random stress (27 clock ratios, resets, backpressure) | PASS: 0 errors |
| USER4 truncation sweep (52 cut points) | 45/52 desynchronize (S9) |
| `karu_lsu` → `karu_mem` random AXI subordinate (backpressure, W-before-AW, SLVERR/DECERR, flushes, posted vector stores) | PASS: 48 runs, about 83k data checks, 0 errors. Three mutants (store-hit update, ARVALID drop on flush, valid line after error) detected |
| `karu_icache` random refill with error beats and FENCE.I during refill | PASS: 6 runs, about 51k checks. Two mutants detected |
| `karu_lsu` with `KARU_NO_MEM` arbiter gating, W accepted two cycles after AW | 12 AW / 12 W / 11 B for one store; store never completes (S7) |
| `karudbg_bus` + `karu_ddr_xbar` + peripherals random co-simulation | PASS with 64-bit SBA DRAM accesses (6 × 300k cycles, about 320k core reads, 100k writes and 48k SBA operations). Narrow SBA DRAM accesses FAIL X44/X45 (S13). Arbitration mutation detected by SBAB2 |

Board acceptance, mapped timing and a Debug 1.0 compliance claim remain the
open gates recorded in [dbg/README.md](../dbg/README.md). The fixes for
S7–S13 should be accompanied by `karu_assert` invariants and negative
controls in line with the existing debug verification practice.
