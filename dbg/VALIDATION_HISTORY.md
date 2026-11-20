# karudbg validation history

Dated records of the combined functional gate and of the base-debug
validation, newest first. The current record is in
[README.md](README.md#current-combined-validation-record).

## Gate runs, 2026-11-15 to 2026-11-19

**After the first image build: review follow-ups on the test side,
2026-11-19 21:25 UTC.** `make dbg-test` passed in 771.87 seconds with
all **455 captured input hashes** unchanged, while Vivado finished the
image on the same host. No RTL, flow or boot source changed since the
entry below, which is the tree that the superseded bitstream `f3493b17…`
was built from.
Changed since then:
- `dbg-auth-bypass-image-test`: lemma C1 with the define list and the
  parameters of the image's synthesis (the instruction cache, the reset
  vector in the island ROM, the hardware window limit at 2³¹ clocks, an
  island ROM image), where it had a list of its own that had drifted
  ([plan, A3](../doc/debug-auth-plan.md)). The result is the same;
- `test/dbg/board/auth_rehearse.py`: only its description of the model's
  `seed` CSR;
- five new files that the gate hashes and does not run: the composition of
  the authentication lemmas, `make dbg-auth-compose-test`
  (`test/dbg/run_auth_compose.py` and four files under `test/dbg/formal/`).
  It passed at 21:31 UTC in 1,025 s beside the gate (718 s alone), reading T1's third bullet from the plan and with the image's corrected define list for its single model. With `--tx-words-only`, the earlier wording, the same results fail on that item. Its summary line still says three findings are open: it counts the T1 finding, which the report body marks closed by the rewording. Two are open.

**Zkr health tests, `mdbgrng` removed, window timer, 2026-11-19 19:29 UTC
(the tree of the superseded bitstream `f3493b17…`).**
`make dbg-test DBG_GATE_JOBS=3 DBG_JOBS=6` passed in 720.41 seconds with
all **450 captured input hashes** unchanged. The image build started from
the same sources right after it and ended at 21:20 UTC with timing met
([measurements](MEASUREMENTS.md#fpga-build--2026-11-19-f3493b17-superseded)). Changed in the
gate since the entry below:
- `entropy-test`: 4,062 checks and 83 mutants (were 3,740 and 33), then
  `rtl/karu_entropy.v` against the Python model of its health tests on the
  same symbols (`test/entropy_replay.py`, 22 checks with controls) and the
  criteria of SP 800-90B section 4.5 on that model;
- `zkr-test`: the read-only `mentropystat` CSR and its access rules; 17
  mutants (were 14);
- `noise-burst-test`: a period write ends an `mnoise` run; 37 mutants;
- `dbg-auth-unit-test`: no `mdbgrng`; the hardware window limit, 413 checks
  and four more mutants; `dbg-auth-core-test`: `0x7C3` is an illegal
  instruction; the window benches draw their nonce from `seed`;
- `dbg-auth-revoke-ext-test`, new: the revocation bench in twelve
  configurations, with the DDR crossbar as responder and through JTAG (334
  scenario runs, 12,444 checks, 36 mutant builds);
- `dbg-getnoise-test`: with the strap low every poll finds the loss flag;
- `ddr-noise-burst-test`: its firmware is built without unwind tables. As
  committed in `32c2258` it ran 24 bytes into the `tohost` page with the
  Linux-targeting compiler.
Earlier runs of this round, on earlier states of the tree: 14:54 UTC
(805.28 s, with that firmware linked by hand) and 17:26 UTC (745.97 s);
one at 18:05 UTC failed in `dbg-getnoise-test`, whose strap-low case had
not been updated for the GetNoise run break.
Outside the gate, on the same sources:
- `dbg-auth-formal-test`: 15 entries pass, with the window-timer lemma C5w
  and 55 controls (19:08 UTC, about 20 minutes);
- `image-boot-test`: the island ROM, fu-boot, OpenSBI, an S-mode reader of
  `seed`, reboot and second boot, in lifecycle `OPEN`, in lifecycle `AUTH`
  with no request (the hold strap clear and the DMI idle: nothing
  authenticates in this test), and with the entropy strap low;
  `uboot-tftp-test`; `uboot-boot-test` (U-Boot 2026.10 from the ROM with
  the entropy source on and off, through one SBI reset each);
- `dbg-board-auth-rehearsal-test` and its SHA3 variant, which are where a
  successful authentication exchange runs (OpenOCD against the JTAG model
  of the core, the `seed` CSR served by a bench source);
- the board captures replayed through the RTL and the model
  (`make entropy-test ENTROPY_DATA=… ENTROPY_RESTART=…`): D18 and D19 raise
  no failure at the reset cutoffs and end running, and the restart rows,
  row by row, raise none;
- an out-of-context synthesis of the entropy source before the last two
  changes to it (no loop; 721 CLB LUTs and 576 flip-flops for the block).
The composition of the authentication lemmas came after this run: see
the entry above.
`sysmon-xsim-test` passed at 17:50 UTC and reads nothing that changed
since. **Not run on a board, and no full Linux boot has been simulated
with these changes.**

**Burst capture, temperature readout and SHA3 authentication, 2026-11-18
21:32 UTC.** `make dbg-test DBG_GATE_JOBS=3 DBG_JOBS=6` passed in
864.54 seconds on the frozen tree the image was built from, with all **441
captured input hashes** unchanged. An earlier run of this round, before the
SHA3 authentication and the review fixes, passed at 18:31 UTC (659.12
seconds, 428 inputs). A baseline
run of the same clone before any of this work passed at 16:18 UTC (585.77
seconds, 416 inputs), after two defects that only a fresh clone shows were
fixed: the Zkr bench rule did not create its directory, and
`test_isa_replay.py` failed with the temporary directory inside the
repository. **This tree is not the accepted image's: bitstream `d7ff00dc…`
was built before these changes.** Bitstream `85f07e58…` was built from it
right after this run (21:32 to 23:40 UTC, timing met; board-tested on
2026-11-19, [record](BOARD_ACCEPTANCE-2026-11-19.md); see
[measurements](MEASUREMENTS.md#fpga-image--2026-11-18-evening)).
Since the 00:31 run the gate gained:
- `noise-burst-test`: the FPGA entropy source with its burst capture
  (`flow/fpga/karu_noise_burst.v`, with the noise model and
  `rtl/karu_entropy.v`): the sampling period, bursts against a record of
  every symbol of the source, what test mode confines, and the abort of a
  capture during which the source was off (107,134 checks); 36
  one-mechanism mutants caught by the bench alone;
- `ddr-noise-burst-test`: the capture's registers and the temperature
  readout through the DDR SoC's bus decode, from M-mode and, refused, from
  U-mode and with narrower accesses; eight decode mutants, each failing
  with its own message;
- `dbg-getnoise-burst-test`: the burst payload and the burst phase on that
  SoC simulation, every burst compared with a Python copy of the simulated
  source, three payload mutants, and the analysis on the phase's files (93
  checks);
- `dbg-burst-analysis-test`: the analysis of bursts on generated data with
  known parameters, with five controls (71 checks);
- the board harness self-test, now 214 checks over 30 scripts;
- `dbg-board-auth-sha3-rehearsal-test`: the board client and the island
  ROM built for algorithm `0x04` (SHA3-256 shared secret), with the public
  test key, against the simulated JTAG target;
- `dbg-auth-sba-revoke-test`: revocation with an SBA transfer outstanding,
  24 timings, four-state, three controls;
- `dbg-auth-bypass-test` and `dbg-auth-bypass-image-test`: lemma C1 as a
  structural inventory, in a reduced configuration and in the image's.
`rtl/karu_entropy.v` changed by two status outputs only; `entropy-test`
(33 of 33 mutants), `zkr-test` and `zkr-loop-test` pass unchanged, and
`ddr-reboot-test` passes with its seven mutants on the changed bus decode.

Outside the gate, on the same frozen tree on 2026-11-18:
`make dbg-auth-formal-test` passed (13 min 47 s), with C3 new and C8
strengthened, every control detected; `make image-boot-test` passed with
the board's own SHA3 island ROM and the temperature readout (island ROM,
fu-boot from the 2 MiB ROM, OpenSBI v1.9 with the `zkr` tree, an S-mode
payload that reads `seed` and reboots, in `OPEN` and `AUTH`, with the
entropy strap low, and the no-Zkr control); `make uboot-boot-test` passed
(62 min): U-Boot 2026.10 from the ROM boots twice in each run, its patched
Zkr driver delivers 16 bytes with the entropy source on and gives up with
it off; `make uboot-tftp-test` fetched two files by TFTP with matching CRC;
`make sysmon-xsim-test` passed against Xilinx's SYSMONE4 model. The KVM
fixture, re-pinned to OpenSBI v1.9, completed both guests on QEMU and on
RTL. An out-of-context Vivado run placed the system monitor in the rings'
SLR and routed the capture block with 10.8 ns of slack on its RAM address.

**Zkr, 2 MiB boot ROM and authentication in the FPGA image, 2026-11-18 00:31
UTC.** `make dbg-test DBG_GATE_JOBS=3 DBG_JOBS=6` passed in 463.26
seconds, alongside the FPGA build, with all **416 captured input hashes**
unchanged. It follows two runs on 2026-11-17 (22:42, 709.95 seconds, 410
inputs; 23:26, 586.01 seconds, 415 inputs) that passed on RTL which Vivado
then refused to write a bitstream for: it had a combinational loop between
the CSR file and the entropy block, which no simulation in the gate could
see. The loop is fixed and `zkr-loop-test` is the gate's check for it.
Since the 11:33 run of 2026-11-17 the gate gained:
- `entropy-test`: `rtl/karu_entropy.v` with driven symbols (3,740 checks)
  and 33 one-mechanism mutants caught by the bench alone;
- `zkr-test`: the `seed` access table in M, S, U, VS and VU, `mseccfg`, the
  value format, word delivery, the custom CSRs and the platform strap on
  the core, two controls, and 14 access-rule mutants;
- `zkr-loop-test`: Yosys finds no logic loop in `karu_csr` with
  `karu_entropy` connected as in the SoC, nor in `karu_entropy` with every
  output fed back into its write-side inputs; the control, the term that
  the first build was refused for, is found by both;
- `dbg-getnoise-test`: the GetNoise capture payload on the simulated core,
  the offline analysis on synthetic model data, and the capture phase
  against a stand-in debugger (104 checks);
- `dbg-board-auth-rehearsal-test`: the board's authentication client and
  pristine OpenOCD against the simulated target running the real window
  ROM: locked examine, a correct response, a wrong one, replay, a fresh
  nonce after another power-on reset, expiry, the straps, and four client
  mutants;
- the board harness self-test, now 204 checks: the phases take the scratch
  SRAM address and the reset vector from the kind of image under test;
- `dbg-auth-window-seed-test` (in `dbg-auth-test`): the window bench with
  the nonce read from `seed`, as the FPGA ROM does; the bench confirms the
  source of every nonce word;
- `sv39-auth-pma-test`: the island SRAM and the Debug Module's page are
  inside the boot ROM's span and are not ROM, checked through the address
  translator with `HLVX` as the detecting case of the control.
Two defects of the first 2 MiB map were found by this gate and fixed before
this run: ordinary accesses reached the Debug Module's private page
(`dbg-core-test`), and the System Bus Access classification and several
test models still had the old scratch SRAM range (`dbg-sba-core-test`). A
third, the island SRAM being executable in the access permissions, came from
review; it was already so with the 1 MiB ROM.

Outside the gate, rerun on the same fixed RTL on 2026-11-18:
`make dbg-auth-formal-test` passed (12 min 26 s), `make zkr-test-spike`
(Spike agrees on the access table), `make csr-test`, `make h-test`,
`make sv39-test`, and `make
image-boot-test`: the island ROM, fu-boot from the 2 MiB ROM, karudeb's
OpenSBI v1.9 with the `zkr` device tree and an S-mode payload that reads
`seed` as Linux does and reboots through SBI, in lifecycle `OPEN` and
`AUTH`, with the entropy strap low, and a control with the tree without
`zkr`. The board top elaborates in Vivado with the image's define list and
the ring placement was checked out of context.

The first board session with this image, on 2026-11-18, followed
[the board test plan](BOARD_TEST_PLAN.md); every stage passes
([record](BOARD_ACCEPTANCE-2026-11-18.md)).

**Software reboot, 2026-11-17 11:33 UTC.** `make dbg-test
DBG_GATE_JOBS=3 DBG_JOBS=6` passed in 595.14 seconds from an empty `_build`,
alongside the FPGA build, with all **394 captured input hashes** unchanged.
It follows an 11:05 run (490.52 seconds, the same inputs by name) and adds
only the board reboot script's console-banner check and its self-test.
Since the 10:21 run the tree has the software
reboot of the VCU118 SoC (system-control register, reset stretcher, reset
sequencer input; see [the FPGA guide](../doc/fpga.md)). The gate now also
runs `ddr-reboot-test` with its seven decode mutants, and
`dbg-fpga-reset-test` gained the software-reset cases, two mutants, the
single-flop check and the board-top wiring check. The input record grew from
334 to 394 files because it now also covers C sources, the HTIF firmware
directory and its linker script.

Outside the gate, on the same tree: `make sbi-reboot-test` passed (24
minutes): the fu-boot ROM, karudeb's OpenSBI v1.9 and profile DTB, and an
S-mode payload reboot the simulated SoC through SBI system reset; with the
reboot node removed, OpenSBI offers no system reset. `make irq-test
ddr-irq-test` also pass on this tree. The formal gate was not rerun; none of
its inputs changed. The debug image `d5e603cd…fd9b2` was built from
this tree on 2026-11-17 and meets timing; it has not run on a board. See
[measurements](MEASUREMENTS.md#fpga-image--2026-11-17).

**Board-campaign follow-ups, 2026-11-17 10:21 UTC.** `make dbg-test
DBG_GATE_JOBS=3 DBG_JOBS=6` passed in 604.41 seconds from an empty `_build`,
with all **334 captured input hashes** unchanged. It ran alongside the FPGA
build, which is why it took longer than an unloaded full run. Since the
2026-11-16 09:43 run the tree has:
- the VCU118 OpenOCD outer-TAP configuration fix made during the board
  campaign;
- the two FPGA UART receive-path fixes and the HTIF firmware link-layout fix;
- the board harness under [test/dbg/board/](../test/dbg/board/README.md),
  which accounts for most of the new hashed inputs.

The gate now also runs `uart-rx-test`, `dbg-board-harness-test` and
`dbg-board-rehearsal-test`. An earlier run at 09:54 UTC (345.43 seconds, the
same 334 inputs by name) preceded the last harness corrections: recorded
restore failures in the transport phase, write accesses in the autoexec
case with a third injected defect, and kernel-independent Linux phases.
Outside the gate, `make irq-test ddr-irq-test` pass on the same tree. The
formal gate was not rerun; none of its inputs changed.

**Review corrections, 2026-11-16 08:08 UTC.** `make dbg-test DBG_GATE_JOBS=3
DBG_JOBS=6` passed in 334.85 seconds with all **307 captured input hashes**
unchanged; the run reused unchanged simulator builds, which is why it is
shorter than the 22:24 run. Since that run it adds the simulation ROM's
deadline fix, `dbg-auth-rom-host-test`, and the deadline-boundary cases and
mutant ROM in `dbg-auth-window-test`.

The separate formal gate (`dbg-auth-formal-test`) passed afterwards on the
same sources: lemmas C2, C4, C5, C6v, C6cone, C7 (two parts), C8, C9 and C10,
each with all of its mutants detected, and the C6 reset-value check with its
five negative controls. Log: `_build/dbg/auth-formal.log`.

**Rerun, 09:43 UTC.** After a comment-only change to the simulation ROM
source (the deadline wording), the same command passed in 329.55 seconds
with all 307 input hashes unchanged during the run. The ROM image is
byte-identical to the 08:08 one. The formal gate was not rerun; none of its
inputs changed.

**Final run of the session, 22:24 UTC.** `make dbg-test DBG_GATE_JOBS=3
DBG_JOBS=6` passed in 739.93 seconds, with all **304 captured input hashes**
unchanged. Since the 20:45 run it adds:
- the debug-page router fix and its forged-load and forged-fetch cases, with
  the router mutant;
- the extended island bench;
- `dbg-auth-openocd-test` (pristine OpenOCD authentication and rejection);
- `dbg-auth-window-test` (A2 simulation ROM, including replay);
- the C8 hardening.

The formal lemmas (`dbg-auth-formal-test`) are a separate gate. All passed at
22:16 UTC; C6 was checked separately.

**A1 review fixes, 20:45 UTC.** `make dbg-test DBG_GATE_JOBS=3 DBG_JOBS=6`
passed in 657.86 seconds. All **290 captured input hashes** match before and
after the run. This run covers the island outstanding-transaction fix, the
system-reset window close, `dbg-auth-island-test` and the forged-load and
reset scenarios on the real core. All 16 authentication mutants are caught:
- 9 in the unit bench;
- 1 island;
- 3 DM;
- 1 `OPEN` equivalence;
- 2 real core.

**Authentication (A1) update, 20:15 UTC.** `make dbg-test DBG_GATE_JOBS=3
DBG_JOBS=6` passed in 556.08 seconds under the new 2,700-second bound. All
**289 captured input hashes** match before and after the run. It adds
`dbg-auth-test` ([Debug authentication](README.md#debug-authentication-karu_dbg_auth)):
- all 12 authentication mutants are caught;
- both `OPEN` equivalence proofs pass;
- the `OPEN` real-core summary is identical.

The run reused models built by a 20:05 UTC run on the same RTL. That run took
1,294 seconds and failed only because the transport negative control
`autoexec-held-replay` still patched the pre-A1 text of the DMI write guard;
its pattern was then updated.

The record below covers the S7–S13 fixes before A1.

`make dbg-test DBG_GATE_JOBS=3 DBG_JOBS=6` passed at 19:00 UTC in 309.69
seconds. All **281 captured input hashes** match before and after the run.

That run reused the simulation models built by an 18:09 UTC run on the same
RTL. The 18:09 run passed in 1,694.84 seconds, including model rebuilds, with
280 unchanged inputs. The 19:00 run adds only the S10 structural check and
documentation of which targets carry in-target mutants. `_build/dbg/validation.json` records
`passed=true`, exit status zero, no timeout, tool identities and source
integrity, and `validation.log` contains the individual results. The run
covers the uncommitted working tree with the S7–S13 fixes.

In addition to everything in the October 30 gate, it runs the review
regressions. Targets marked † are positive runs whose failure on pre-fix
RTL was shown separately, not by a mutant inside the target:

| Finding | Target | Result |
| --- | --- | --- |
| S7 | `lsu-aw-w-test` | Every LSU write state passes in joint, AW-first, W-first and random orders. The joint-only mutant fails each split order. |
| S7 | `nomem-aw-w-isa-test` † | 116/116 runs: 29 ISA tests, AW-first and W-first, lags 1 and 3. |
| S8 | `dbg-unit-test` | 1,151 checks. The early-acknowledgement mutant is caught. |
| S8 | real-core deactivation sweep † | Six core variants. The default variant runs 158 delays, 155 while busy, with `a0`, `s0` and `mscratch` intact, and recovers a hung Program Buffer. |
| S9 | `dbg-bscan-truncate-test` | 52 cuts, 364 checks. The mutant without the TRST pulse fails. |
| S10 | `dbg-ndmreset-flop-test` | `ndmreset_o` is a single flop on the base and SBA+autoexec builds. The combinational mutant is caught. |
| S11, S12 | `dbg-run-control-test` † | 21 cases, including VS/VU, with live INV40/INV41. |
| S13 | `dbg-sba-xbar-test` | Narrow-SBA seeds and a no-SBA control pass. Raw-beat and `req_ready_ignores_core` mutants are caught by X44 and SBAB2. |
| INV41 | `dbg-trigger-invariant-test` | 24 corrupted cases detected, nine of them INV41. |

The scalar actual-core run records 328,613 checks over 514,695 cycles; the
deactivation sweep accounts for the increase over October 30.

Both runs used three gate jobs on an otherwise idle machine. A full rebuild
leaves about 105 seconds of margin under the 1,800-second gate bound, so
consider raising the bound before adding more tests. This is pre-board functional evidence only. No synthesis,
timing or FPGA image covers this RTL yet.

## Combined validation record — 2026-10-30

This record covers the October 30 registered-pause RTL, before the
2026-11-15 review fixes. `make dbg-test DBG_GATE_JOBS=3 DBG_JOBS=6` passed at 01:08 UTC in
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
The [CPU replay record](README.md#ordinary-isa-replay-with-debug-idle) explains its
reference and build-binding scope. Mapped results are in
[measurements](MEASUREMENTS.md#extension-measurements--2026-10-29).
This is pre-board evidence for the registered-pause RTL. The retained FPGA
image passed its own October 29 routed gate and has not been rebuilt with
this follow-up; hardware acceptance remains open. The prior functional
record is preserved in `_build/dbg/reset-pause/before-validation.json`.

## Base-debug validation record — 2026-10-26

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
