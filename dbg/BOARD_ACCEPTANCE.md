# VCU118 debug acceptance — 2026-11-16

The next campaign, with Zkr and debug authentication, is
[2026-11-18](BOARD_ACCEPTANCE-2026-11-18.md).

The debug-enabled image was tested through the physical Digilent adapter and
USER4 tunnel, without rebuilding the bitstream. Directed hardware tests and
a ten-minute concurrent-execution soak pass. Post-detach Linux acceptance,
both KVM guests and all 92 OpenSSL Zvk known-answer pairs also pass.
The new pristine OpenOCD has
software-address-translation defects described below. Full Debug 1.0
compliance is not claimed.

## Configuration and evidence

| Item | Tested value |
| --- | --- |
| Board | VCU118, XCVU9P, 75 MHz CPU, 2 GiB DDR4 |
| Bitstream SHA-256 | `0b994847163b0d471816edb2b63f1c5c94d777f9b829f48364d9521512378b22` |
| Features | RVA23S64, I-cache, full Zvk/Keccak, `KARU_DBG_FULL`: autoexec, two address triggers, SBA |
| Authentication | Not built into this image; not a hardware authentication test |
| Board configuration | [vcu118.cfg](vcu118.cfg), 18-bit outer IR, USER4 `0x23924`, five-bit inner IR |
| Adapter | Digilent JTAG-SMT2-NC, serial `210308AE622F`, FTDI |
| OpenOCD | `0.12.0+dev-02815-g83e3febc6`, full revision `83e3febc6e951322ff5c9793c2f222352006bd0e` |
| OpenOCD binary SHA-256 | `1c3079e9c8c52224905e9dbd9185e5908958c5b58414d07ad70b441d0f4283c6` |
| GDB | Installed RISC-V ELF GDB 17.2 |
| Linux | `7.2.6-zvk`, TFTP/NFS root |
| UART | CP2105 SCI, 115200 baud, `_build/boot.log` |

Evidence is under `_build/dbg/board-accept-20261116/`: executable Python/Tcl
drivers, assembly and ELF fixtures, per-command JSONL traces, per-phase JSON
results, GDB command files/transcripts, OpenOCD logs, input hashes and Linux
results. These are physical-board runs. The separately labelled unit-suite
results are simulation evidence for the current source tree.

The evidence bundle is `_build/dbg/board-accept-20261116.tgz` (7,199,900 bytes,
458 files), SHA-256
`c00488e0c91b0d4559d9c697d820b55e59a20c231544120a7a48b5f66a33f2e0`.
Its `SHA256SUMS` covers the individual artifacts; `summary.json` selects the
final results and preserves the translation failure and timeout continuation.

The source checkout at campaign start was clean at `643a8de`, as recorded
in `manifest.json`.
The transferred bitstream is identified by its hash, not inferred to be
identical to that source checkout. Its ROM manifest records build provenance.

## Hardware coverage

| Group | Result and scope |
| --- | --- |
| Linux context | Discovery; all 32 GPRs over 16 patterns, x0 and CSR handling, saved-state restoration; 100 halt/resume cycles |
| Live Linux kernel breakpoint | Hardware execute trigger at high canonical VA `0xffffffff80048eaa` (`__riscv_sys_getpid`), S-mode cause 2; instruction bytes at PA `0x80248eaa` match the served Image; removal, resume and SSH workload completion pass |
| Abstract commands | 32/64-bit reads, 64-bit writes, unsupported commands/registers/sizes, sticky errors, clearing and recovery; fault containment |
| Program Buffer | Arithmetic, completed GPR effects across faults, illegal instructions, rejected MRET/SRET/DRET, WFI/WRS behavior and fences |
| Autoexec | Implemented mask and cached unsupported-command retry. The run accessed DATA0/DATA1 and all eight Program Buffer registers with their autoexec bit set, but **did not establish that those accesses execute anything**; see the [review follow-up](#review-follow-up--2026-11-17) |
| Memory | Progbuf and SBA, 8/16/32/64-bit values, block lengths 1/2/5/17/65, byte lanes and adjacent-byte preservation; scratch SRAM and DRAM at low, middle and high physical addresses |
| SBA errors | Unsupported sizes, all misalignment offsets, private-page/PMA denial, recovery, read-on-address/data, success-only increment, tool rejection above the 32-bit address range |
| Actual MMIO | UART scratch preservation, status and transmitted strings through both access paths; no simulated FIFO/counter addresses used |
| Scalar run control | Compressed and ordinary instructions, branches, fences, LR/SC reservation loss, exactly-once AMO, fault/EBREAK stepping, WFI privilege/virtual traps, counter freeze while platform time advances |
| Privilege | M/S/U/VS/VU EBREAK and data watchpoints; stepped MRET into S/U/VS/VU; watchpoints after PMLEN 7 and 16 pointer masking |
| FP/vector state | All 32 FP and 32 vector registers over fixed and random patterns, raw GDB packets, vector configuration preservation, FADD/FMA execution |
| Address triggers | Native OpenOCD and GDB allocation, both slots, excess-slot rejection, reuse, hardware execute breakpoints, read/write/access watchpoints and WARL behavior |
| Vector restart | Load/store EEW 8/16/32/64, completed prefixes, segmented, masked, fault-only-first and whole-register cases; preserved VL, precise DPC/vstart and completion after disarming |
| Coherence | Warm D-cache invalidation. An instruction replaced through SBA in DRAM is the one executed by the next raw-DMI step, with no debugger-injected FENCE.I or Program Buffer command: evidence that a stale I-cache line is not used. The same check passes in scratch SRAM, but **does not isolate invalidation of prefetched instructions**: the hart was halted for the patch, and leaving Debug Mode redirects fetch by itself; see the [review follow-up](#review-follow-up--2026-11-17) |
| Concurrent execution | SBA while scalar divide, FP divide and vector arithmetic execute; architectural results and operands checked after halt |
| Keccak | 24-round, 12-round and dependent-chain known answers in Debug Mode and normal execution, state-tail preservation, rejected encoding containment |
| Isolation | Normal M-mode reads/writes of debug CSRs and DRET trap; private debug page rejects normal read/write/fetch and independent SBA |
| Transport | All 52 partial USER4 frame positions recover; intended committed writes remain intact, no observed corrupted data; reserved DMI op, sticky failure, dmireset and dtmhardreset |
| Clock sweep | 100/250/500 kHz and 1/2/5/10 MHz, 300 DMI patterns at each frequency |
| Reset/deactivation | Reset-halt DPC `0x1000` before the first ROM instruction; hung Program Buffer recovery with ndmreset; delayed deactivation acknowledgement and cancellation; 100 deactivate/reactivate cycles |
| GDB | Target XML, GPR/CSR/memory widths, FP/vector packets, stepping, software/hardware breakpoints, all watchpoint directions, detach/reconnect |
| Soak | 600.19 s, 8,966 batches, 319,115 returned data values verified, 448 halt/resume cycles, varying JTAG clock, armed watchpoint exclusion for SBA and core-side coherence checks |

The ten hardware phases excluding the translation probe contain 39 passing
groups. Counts in JSON are host assertions, often word comparisons or state
checks, not counts of independent specification requirements.

The kernel breakpoint uses a hardware execution trigger; it does not depend
on OpenOCD's software page walker. Its Linux `satp` values differ before run
and at the breakpoint because scheduling can switch address spaces. The
halted register readback is stable and the breakpoint context uses Sv39.
The served Image matches the local kernel Image, SHA-256
`172000bf20fc98c01bf108c448ec2977dd66f60e9b3f2dd1bc0c2f0d507bcf4a`.

## Post-detach Linux regression

After the clean reset/detach sequence, Linux booted normally from TFTP/NFS.
The following checks run over SSH as root, using the installed lab key.

| Check | Result |
| --- | --- |
| `board_accept.sh --mem 256` with kernel/ISA expectations | PASS: NFS/network, 2 GiB visible, three 256 MiB memory patterns, counters (probe x1.16), cache-window coverage, reserved-vtype probe and scalar FP probe |
| Zvknhk OpenSSL checks | 17/17, both Keccak and software backends |
| KVM `ebreak_test` | Exit 0; guest execution and debug handling |
| KVM `arch_timer -n 1 -i 2 -p 1 -m 0 -e 1000` | Exit 0, `PASS(vCPU-0)` |
| `validate_v_ptrace` | 13 pass, 0 fail, 6 skip; includes syscall vector-state discard |
| `vstate_ptrace` | 2 pass, 0 fail |
| `vstate_prctl` | 11 pass, 0 fail, 2 skip; includes exec helpers |
| `v_initval` | 1 pass, 0 fail |
| riscv-pqc `xtest` | 39 pass, 0 fail |
| Full OpenSSL Zvk known-answer matrix | 92/92 unique algorithm/capability pairs match both expected answers and scalar reference |
| Final health after live-kernel debugging | Linux responsive over SSH; KVM VM/vCPU creation and `vill_probe` pass |

The first full OpenSSL matrix hit the harness's 600-second timeout after
52 successful rows. A separately recorded continuation completed 44 rows,
including four overlaps: together they cover all 92 expected pairs with no
missing or mismatching result. The original `status.tsv` retains exit 124
and its aggregate failure marker; `openssl-matrix-result.json` records the
completed matrix. This was a test-time limit, not a failed known answer.

The prebuilt Linux selftests come from karudeb's 7.2.4 selftest build and run
against the 7.2.6-zvk board kernel; copies and hashes are retained. The vector
prctl tests intentionally cause SIGILL in child processes when vector use is
disabled. Those expected user-process signal reports appear in `dmesg`;
the TAP results pass and the kernel remains untainted. Board timestamps
start at the Unix epoch; use the host campaign manifest for the run date.

Linux remains running, OpenOCD and `hw_server` are stopped, and UART capture
continues at `_build/boot.log`. The artifact directory contains a frozen copy
of that capture and the final Linux health log.

## Findings

### OpenOCD software walker: invalid superpages accepted

The new pristine tool returns `0x13579bdf` for deliberately misaligned
2 MiB and 1 GiB leaves instead of rejecting them. This is a debugger
software-walk defect; the positive Sv39 hardware-walk controls pass.

### OpenOCD software walker: Svnapot resolves the wrong physical page

The host Svnapot fixture expects data from the selected 64 KiB mapping;
OpenOCD instead returns `0x0405b593` from the wrong page. VS-stage, G-stage
and combined-stage probes likewise return data rather than rejecting the
unsupported mapping (`0x2468ace0`, `0x0405b593`, `0x2468ace0`).

The complete adapted translation fixture reaches 28 checks, including host
and guest mappings, high-GPA page tables, Bare combinations, invalid leaves,
fault containment and policy probes. Six probes expose these two defect
families. `translation-phase.log`, `translation-issues.txt` and
`translation-board.tcl` preserve the cases and exact results. The synthetic
counted-MMIO assertion is omitted on hardware; benign scratch replaces the
fixture's final device mapping.

These are the hazards covered by the separate safeguards in
[openocd-no-autoexec.patch](openocd-no-autoexec.patch). Successful attachment,
physical memory access and GDB register tests do not validate Linux virtual
memory debugging. The patch was not applied to the installed binary in this
campaign. SUM/MXR/U permissions, A/D, PBMT and pointer masking also retain the
documented debugger-policy differences.

### Reset/detach: enabled EBREAK controls stop the OpenSBI semihosting probe

The first post-test reboot stopped before the OpenSBI banner. Reattachment
found DPC `0x8001a3d4`, an EBREAK between the RISC-V semihosting marker
instructions, with EBREAK-to-debug controls enabled. The downloaded firmware
code, registers and recovery commands are retained in the diagnostic traces.
This was a debug stop, not a hung AXI transaction.

Clearing the controls and resuming through raw DMI, without OpenOCD's
automatic EBREAK step-over, allowed the OpenSBI semihosting-detection probe to continue. The stopped instruction
was at `0x8001a3d4`, between the semihosting signature instructions
`slli zero,zero,31` and `srai zero,zero,7`. A second clean
boot uses the following sequence: disable OpenOCD's `set_ebreakm/s/u` policy,
reset-halt, clear the DCSR EBREAK fields and step bit, verify raw DPC `0x1000`,
resume through DMI, then shut down OpenOCD. It passes the probe and reaches
Linux without intervention. `clean-detach-boot.json` and its command trace
record this sequence. The legacy `set_ebreak*` commands work on the tested
tool but print its deprecation notice.

Do not assume that `shutdown` alone restores the firmware's EBREAK policy.
The debugger boot/detach workflow needs this cleanup or explicit handling
of the firmware's semihosting probe. No RTL change was made for this finding.

### Test-driver interactions

- When resuming from an EBREAK stop, OpenOCD may single-step the first
  instruction with watchpoints temporarily disabled, even when a new PC is
  supplied. A watchpoint test whose first instruction is the vector load
  therefore misses the intended stop. Establishing a debug-request halt
  before the test proves the hardware watchpoint and restart behavior.
- A high-level `step` of EBREAK may implement debugger step-over rather than
  execute its architectural exception. The architectural EBREAK-trap probe
  uses raw DMI stepping.
- Inspect raw DPC after a raw reset; OpenOCD's cached context must be
  reconciled before using high-level register results.
- The initial failed OpenOCD examination returned process exit zero.
  Acceptance checks explicit target state, completion markers and values.

Serial-driven diagnostic commands under Linux occasionally acquired duplicate
characters (for example, `tail` arrived as `taiil`). Directed debug checks
use JTAG, and post-boot acceptance uses SSH; UART TX capture remains usable.
The campaign did not isolate the cause, and it is not in the debug RTL.

*Triage, 2026-11-17.* The FPGA UART receiver ignored the "byte was read"
pulse on about one read in 41 with an idle line, so the driver read the same
byte twice. That is fixed in the source tree, together with a related
byte-loss race in the UART register wrapper; see the
[changelog](../CHANGELOG.md). The mechanism is shown in simulation. The
tested image `0b994847…78b22` predates the fix, so the board still shows the
duplicates until an image is rebuilt, and the fix is not confirmed on
hardware.

Initial harness failures and their corrections are retained alongside the
final results. They are not classified as RTL defects. No new RTL defect has
been confirmed by the directed tests or soak.

## Review follow-up — 2026-11-17

A review of the campaign's drivers and logs confirmed the recorded results
(bundle and artifact hashes, 39 passing groups) and found no debug RTL
defect. It narrowed two coverage claims and found two harness weaknesses.
The harness changes below are in the source tree but **have not run on the
board**; the results above are those of the scripts frozen in the bundle.

- **Autoexec triggers.** The campaign's test set each autoexec bit, read the
  trigger register twelve times and then checked a value that no execution
  could have changed. Run against a simulated target whose DATA1 and Program
  Buffer triggers are dead, that test passes. The campaign therefore shows
  the implemented mask and the error path, not that the ten triggers
  execute; simulation (`dbg-autoexec-test`, `dbg-autoexec-core-test`) is the
  evidence for that. The harness test now counts executions with a Program
  Buffer increment: exactly one per read and per write of the selected
  register, none for reads or writes of the nine other registers, none for
  either once the bit is cleared. `make dbg-board-rehearsal-test` runs it
  through the same harness on the simulated full-debug target, where it
  passes and fails for three injected autoexec defects.
- **Instruction coherence.** The test halts the hart before patching code
  and leaves Debug Mode to execute it. Debug entry and exit redirect the
  fetch unit, so prefetched instructions are discarded whatever SBA
  maintenance does. The DRAM case still shows that a stale I-cache line is
  not used. Whether an SBA write to a running hart invalidates instructions
  that are already prefetched is not shown by this campaign. Simulation
  covers live code replacement, with coherence mutants (`dbg-sba-core-test`,
  `dbg-sba-core-negative-test`). A board test would have to patch code under
  a running hart without halting it; none exists yet.
- **Exit status.** A phase kept running after a failed case and most
  scripts then exited 0. The recorded per-case results are unaffected (they
  were checked individually). Every phase now ends through one aggregate
  status, non-zero if any case, any restore step between cases or the final
  cleanup failed (`make dbg-board-harness-test`). The translation phase is expected to exit
  non-zero with a pristine OpenOCD.
- **Harness location.** The drivers, fixture source and OpenOCD
  configurations existed only in the ignored `_build` tree. They are now in
  [test/dbg/board/](../test/dbg/board/README.md), with the host paths, board
  address, ports and adapter taken from the environment. Campaign logs and
  frozen evidence stay under `_build`. The Linux phases no longer name a
  kernel version: the expected release and the live-kernel breakpoint
  address are read from the kernel build tree of the served Image. The
  campaign's scripts had the 7.2.6 addresses built in; the lab kernel moved
  to Linux 7.4-rc3 on November 17.

## Supplementary simulation

The following current-source targets pass in a separately recorded run:

```sh
make -j2 dbg-unit-test dbg-autoexec-test dbg-dtm-test \
  dbg-sba-unit-test dbg-sba-bus-test dbg-trigger-unit-test \
  dbg-bscan-truncate-test
```

They include error/ownership/deactivation/truncation negative controls and
the four-trigger/64-bit-SBA configurations absent from this FPGA image.
See `supplementary-unit-results.json` and `supplementary-unit.log`. They do
not constitute hardware evidence for those absent configurations.

## Limits

The campaign cannot observe exact internal request counts or inject
cycle-accurate AXI/CDC faults on this bitstream. The physical partial-frame
test checks external effects and recovery; request-count invariants have
separate simulation evidence. Actual UART tests cannot reproduce the
simulation fixture's read-to-clear/FIFO access counters. Arbitrary bus
nonresponse, independent fabric resets and cold-power lifecycle behavior
were not exercised. Authentication, four-trigger hardware, production ASIC
macros, CDC signoff and full Debug 1.0 compliance remain outside this board
result. No synthesis, bitstream rebuild or Git write operation was performed.
