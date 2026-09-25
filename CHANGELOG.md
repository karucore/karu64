# Changelog

All notable changes to `karu64`. Format follows
[Keep a Changelog](https://keepachangelog.com/); the repository has no tags
yet; unreleased changes appear first, followed by merged checkpoints.

## [Unreleased]

### Changed — FP register file is 1W2R (was 1W3R)

- `karu_fregfile` now has two asynchronous read ports, the same shape as the
  integer register file, so a standard two-read compiled register file can
  implement it (the 1W3R macro was the memory-generator blocker). FMA still
  costs no extra cycle: decode reads rs1/rs2 as before, and port B is steered
  to `ex_rs3` while the FMA holds the ID/EX packet and while the FPU runs it,
  a window in which decode cannot accept and no FP writeback can land. The
  FPU's `op3` is the live port-B output; the 64-flop `ex_frs3_v` latch is gone.
- New `karu_assert` group INV38a..l: port-B ownership/steer integrity, no FP
  write in an issue or accept cycle, and a shadow copy of the FP register file
  that checks every FP source operand consumed by the FPU, the vector `.vf`
  path and FP stores against the latest write to that register. A local
  `[FRF-ASSERT]` in `karu_fregfile` rejects writes with an unknown address.
- New `make fma-hazard-test-all`: every f-register producer feeding the rs3 of
  an immediately following FMA, chains, aliasing, malformed NaN boxes and FMAs
  accepted as a busy unit drains, digest-compared with Spike. `flow/asic` inventory and
  `test/tb_asic_mem.sv` updated for the two-port file.
- VCU118 profile image built from this change (`7c2563e`, Vivado 2026.1,
  `vcu118-ddr-sgmii-rom-rva23s64`): `b11d5efb…3b809`, routed setup/hold
  0.000/+0.012 ns whole-design and +0.077/+0.012 ns on `cpu_clk`, 14/14 bus
  skew, 0 DRC errors, 349,701 LUTs; no worst path touches the FP register
  file. Pre-synth gate: H fixtures, preemption and full ACT4 2872/2872. The
  programmed image boots Linux 7.2.6-zvk and passes `board_accept.sh`, including
  memory, cache, crypto and KVM API checks; the FP probe completed. Full
  on-board TestFloat3 remains in progress. See the
  [release diagnostics](doc/release-diagnostics-2026-09-14.md#1w2r-fp-register-file-image--2026-09-24).

### Board validation — 2026-09-22

- The Genus-cleanup VCU118 image `03eeb088` passes Linux 7.2.6-zvk acceptance:
  OpenSSL 92/92 known answers and scalar comparisons (including forced vector
  SM4), both KVM guest tests, 39/39 Keccak vectors, vector ABI and cache checks.
  No regression observed against `c61da577`; detailed results and evidence
  locations are in the [release diagnostics](doc/release-diagnostics-2026-09-14.md).

### Changed — strict declare-before-use, no declaration-assignments (Genus)

- Every `wire x = expr;` in the ASIC manifest plus `karu_clint`/`karu_plic`
  (2,453 statements across 43 files) is now `wire x;` + `assign x = expr;`,
  and the seven remaining use-before-declare cases in `karu64.v` (instance
  port connections and cache/VLSU fault wires read before their declaration)
  have their declarations hoisted. The five sim-only `reg x = 0;` initialisers
  (commit-log and translate_off regions) became `initial` statements. No
  functional change: per-file Yosys RTLIL is identical before and after,
  strict `iverilog -g2001` parses clean in eight configurations, and the
  simulation regressions and Vivado elaboration pass.
- New `flow/asic/lint_decl.py` (declaration-order lint, exit 1 on findings)
  and `flow/asic/fix_decl.py` (the mechanical rewrite); see
  `flow/asic/README.md`, *Coding rules for the Genus front-end*.

## RVA23S64 — 2026-09-10 … 2026-09-15

### Profile implementation and handoff — 2026-09-14 … 2026-09-15

- Correct standard vector-crypto `.vs` execution so all AES round/zero forms
  and SM4 always read element group zero of `vs2` for every destination group.
  Add multi-group `vl=8,m1` and `vl=16,m2` Karu/Spike checks and a reproducible
  `diel-test-ship` target; the 215-case shipping DIEL probe remains clean.
- Consolidate release documentation around the current architecture, profile,
  diagnostics, security and DIEL reviews. Remove superseded bug reports and
  completed implementation plans while retaining maintained test recipes and
  ASIC memory/source manifests.
- Generate the corrected karudeb-compatible RVA23S64 VCU118 ROM bitstream with
  Vivado 2026.1. Routed 75 MHz CPU setup/hold is +0.046/+0.010 ns and
  whole-design worst setup/hold is +0.009/+0.010 ns; all 14 bus-skew
  constraints pass and bitgen DRC reports zero errors. The image passes
  Linux 7.2.4-zvk board acceptance, including memory, crypto, vector ABI and
  KVM API checks. Exact results are in the release diagnostics.
- Reject every reserved high register-supplied `vtype` bit, producing canonical
  `vill=1`, `vl=0` and restoring Linux syscall vector-state discard. Expand
  both I/D-cache eligibility and vector-store posting from 256 MiB to the
  full standard 2 GiB DRAM window. Preserve PBMT/MMIO bypass behavior and
  add directed legality, address-boundary and transport regressions.
- Refresh the post-review Yosys 0.69+24 area matrix and exact-shipping
  OpenSTA 3.1.0 estimate. At 200 MHz the current shipping map reports
  register-to-register WNS −0.2043 ns and TNS −5.13 ns (about 192.1 MHz at
  zero slack); the limiting cone is the existing vector widening/estimate
  datapath rather than the corrected crypto source address. Non-register path
  groups pass, while generic electrical-limit violations remain. The matched
  area rows are 3667.90 kGE for RV64GCV+Zvbb, 3706.47 for Zvkned, 3683.68 for
  Zvksed, 3806.98 for all standard Zvk leaves, 3894.17 with Keccak, and
  4390.60 kGE for the exact shipping composition; every input manifest is
  unchanged across its run.
- Record FPGA execution of the `ebreak_test` and `arch_timer` KVM selftests,
  with image-specific results in the release diagnostics.
- Restrict page-walker line bursts to DRAM; ROM/scratch use exact PTE reads.
  Reject malformed PWC burst termination instead of publishing partial lines.
  Invalidate resident data-cache aliases on NC/IO and explicitly uncached
  CPU stores, including the vector IO sequencer. Add directed regressions.
- Add Shlcofideleg guest overflow delegation with shared `sip/sie` bit 13
  and unshifted VS cause 13; leave AIA injection unimplemented. Make SGEIE
  writable with H and keep its MIDELEG alias policy consistent. Extend CSR
  and guest PMU tests; update the isolated Sail SGEIE consistency patch.
- Restore PLIC gateway assertions with negative controls, assert idle
  scalar/vector request exclusivity, hardwire CLINT MSIP reserved bits to
  zero, and extend HTIF DDR stalls to W/R/B with mid-burst coverage checks.
- Record [FPGA boot procedures](doc/fpga.md#opt-in-rva23s64-boot-selection)
  and [diagnostics](doc/release-diagnostics-2026-09-14.md), keeping earlier
  throughput and timing records explicitly tied to their measured revisions.

### Supervisor foundation — development toward RVA23S64

- Extend Linux checkpoint builds to the vector/profile RTL. Save and restore
  harness time and clock phase, support bounded replay, and verify complete
  replay-state equivalence in the maintained KVM test harness.
- Set the ACT profile timer lead time for its cycle-based CLINT, avoiding an
  early one-shot interrupt race in ZawrsS/U before the initial trap-count read.
  Complete matched-profile reruns pass 2872/2872 unique tests each on minimal
  and shipping models, with post-run reference ELF hash verification and the
  eight local ACT4 harness/generator/UDB patches described in
  [the test instructions](test/act4-karu/README.md#evidence-and-interpretation).
- Preserve `&&`, quotes and backslashes in baked U-Boot netboot commands;
  avoid the v2025.01 config helper's unescaped sed replacement and verify
  the final Kconfig value before compilation.
- Add opt-in `KARU_RVA23S64` composition, binding H/Ssstateen and Sscofpmf
  to the mandatory baseline and rejecting incompatible opt-outs/geometry.
  Add `rva23-sim` and cross-tool `rva23-config-test`. Legacy/default board
  advertisements remain unchanged; the companion profile image advertises
  the opt-in composition explicitly.
- Add explicit `vcu118-ddr-sgmii-rom-rva23s64`, sharing the vector ROM and
  75 MHz flow with profile-specific karudeb DT/netboot inputs. Validate required
  boot-discovery leaves and ROM/staged-TFTP DTB identity before building.
  Companion sources share the existing board and NFS kernel configuration,
  adding H/supervisor discovery and a KVM fragment only in the profile variant.
- Add matched minimal and optional-Smcntrpmf ACT4 profile references: each
  passes the initial 42-test selection and corrected 56-test focused expansion,
  with separate 21/23-case CSR contracts. Extend
  the guest paging fixture to all VS/G PBMT pairs and physical-fault/FF
  prefixes, checked end-to-end by the bus observer on both pipelines. Its
  300-case variant adds all 144 guest CBO type/permission combinations,
  with mandatory exact-block and denied-side-effect observer coverage.
- Add opt-in real CLINT and independent external-input devices to the profile
  HTIF platform, reusing the timer fixture for 27/48 directed cases. Both
  pipelines pass ideal/stalled runs; legacy RAM-only models remain available.
  Bind the profile ACT timer/IRQ macros and non-overlapping linker symbols,
  and describe the exact LR/SC reservation and physical atomic-fault priority.
- Reject misaligned RAM LR/SC/AMOs and all unsupported physical-device
  atomics before any data-bus request, independently of PBMT. Preserve
  aligned NC/IO RAM atomics and ordinary misaligned accesses. Add
  `lsu-atomic-test` (27,708 checks), extend the existing access fixture with
  396 atomic cases, and cross-check its 286 RAM-only cases with Spike.
  Record and test the single-writer platform memory assumptions.
- Add development-only `KARU_H`: H/VS CSR banks, guest entry/returns, M/HS/VS
  trap and injected-interrupt routing, illegal-versus-virtual exception
  priority, dual FP/vector context gates, HLV/HLVX/HSV and HFENCE/HINVAL.
  Add registered VS Bare/Sv39 and G Bare/Sv39x4 translation, including guest
  PTE accesses, precise guest fault metadata, Svade and composed PBMT.
  Bare memory/fence and paged monitors pass 335 and 141 cases respectively
  on both integrated configurations and Spike (53 baseline cases overlap).
  Add a four-entry, context-tagged guest TLB with registered permission/PMA
  completion; cached/uncached walker checks have matching architectural
  signatures. The 187-case virtual-timer monitor passes both cores and an
  isolated pinned Spike correction, with no normative-case exclusions.
  Expand H counter/PMU coverage across M/HS/U/VS/VU modes. Software two-guest
  FP/vector/timer/shared-control switching and the resident-Keccak chained
  known answer pass both pipelines (88/91 cases), including memory stalls.
  Add 15 integrated VS/VU hardware-event cases covering exact counts,
  inhibit masks, MPRV independence and HS overflow delivery. Add eight
  delegated VS/VU instruction-page-fault cases, including second-halfword
  faults, exact VS trap state and repair/retry. Record the
  Ss1p13/Sha audit and maintained isolated Sail/KVM
  test fixtures. Correct ACT4's H capability and HS trap harness; all 40
  selected H-enabled CSR/exception/timer tests pass with the corrected
  reference and no exclusions. A 96-case asynchronous guest FP/vector switch
  now passes both pipelines with actual timer-overlap/retirement/precise-PC
  assertions, ideal and stalled. Full H/Sha/profile and Linux/KVM validation remain
  separate gates. See
  the current architecture and profile documentation.
- Correct the Linux AXI simulation responder for independent AW/W handshakes,
  aligned byte lanes, burst-final B responses, stable MMIO read snapshots and
  one-shot side effects, using the real shared CLINT time source. Maintained
  positive and two mutation controls verify the protocol checks; these are
  responder tests, not an RTL Linux/KVM verdict.
- Complete the scoped Zkt/Zvkt source audit, now superseded by the current
  [DIEL review](doc/diel-review-2026-09-14.md), including
  serial multiplies, permutations and enabled crypto leaves. No required
  instruction has a protected-operand-dependent completion path in the
  audited sources; this is not formal or physical side-channel validation.
- Defer younger fetch faults until older execution and posted stores drain;
  older data faults retain priority. Cancel discarded fetch walks without
  launching further side-effecting PTE reads, while draining already asserted
  AXI requests. Retain exact IFU guest-fault metadata through split fetches.
- Implement **Svade-only** A/D handling in both Sv39 walkers and their TLB
  hit paths. A=0, or a store with D=0, now faults instead of updating the PTE.
  **Behavior change:** software must set A/D and invalidate translations
  before retrying. `menvcfg.ADUE` is read-only zero; optional Svadu hardware
  updates are not implemented. Remove the walker writeback FSM and tie its
  write channels inactive; reject reserved non-leaf U/A/D bits.
- Add non-H Svinval using conservative full TLB/PWC invalidation and the
  existing instruction/memory drain. Keep TVM checks on `SINVAL.VMA`, not on
  the ordering-only fences. Cancel outstanding walks without stale refills.
- Add non-H Sstc in S-enabled builds: 64-bit `stimecmp`, reset-disabled
  `menvcfg.STCE`, and a two-stage unsigned timer comparator. S access requires
  STCE and `mcounteren.TM`; M access is unconditional and U access traps.
  Enabled STIP is hardware-only; disabling STCE restores firmware injection.
  Add `sstc-test`/`sstc-test-spike`, including vector-state preservation and
  `+sstc_irqcheck` proof of pending-during-vector, deferred interrupt delivery.
- Add standard 64 KiB Svnapot leaves using fixed PPN/VPN slices and existing
  4 KiB-subpage TLB entries. Extend the walker and existing MMU firmware for
  subpages, permissions, A/D faults, reserved encodings and invalidation.
- Add non-H Svpbmt support: reset-disabled PBMTE and page attributes
  through scalar/vector memory, fetch and CBO paths. NC/IO bypass caches and
  posted vector stores; IO transfers only active elements. Retain PMA access
  restrictions. Preserve completed within-granule IO load prefixes and exact
  failed-byte addresses on bus errors; initialize Bare second-page PA/type
  independently of stale translated requests. Add integrated bus-observer,
  injected-error and NC/IO resident-state SHAKE tests.
- Treat physical devices as IO when PBMT=0, preserving scalar native access
  widths and vector active-byte semantics. Custom PMA headers now provide
  `karu_pma_io` as well as `karu_pma_ok`. Correct CLINT narrow byte lanes and
  Ethernet read-side effects; implement PLIC claim/complete arbitration and
  atomic claim-data capture under RREADY stalls. Both SoC IRQ tests pass.
- Correct MPRV/MPP effective data privilege, including Bare bypass and shared
  scalar/vector translation. Fetch retains actual execution privilege;
  MRET returning below M and host SRET clear MPRV; VS SRET preserves it.
  Pointer masking uses effective
  privilege, sign-extension for virtual addresses, zero-extension for Bare
  addresses, and MXR suppression; vector masking applies after element-address
  calculation rather than only to the base register.
- Reject unsupported `satp.MODE` writes without changing `satp`; normalize
  CSR WARL fields and implemented delegation/interrupt/counter-enable masks.
  Preserve the separate software
  `mip.SEIP` latch during read-modify-write, route undelegated supervisor
  interrupts to M, and implement writable FIOM with existing strong ordering.
- Correct instruction-fault `tval` and page-boundary demand: a compressed
  instruction need not access the next page, and a split instruction keeps
  its start PC as EPC while reporting the faulting halfword address.
  EBREAK and C.EBREAK report the instruction address in `tval`, with directed
  EPC/address checks for informative breakpoint traps.
- Connect the existing CLINT MSIP register to the core in BRAM and DDR SoCs,
  including the VCU118 top. Keep `mip.MSIP` read-only and extend the existing
  interrupt firmware with MMIO delivery, masking, clear/rearm and CSR
  write-immunity checks; add a responder-level assertion/clear test.
- Mask `vstart` to its VLEN-derived index width and reserve the time/upper
  bits of `mcountinhibit`. Add full-bit CSR read/write/fault-update sweeps.
- Give all Zicbom management operations load-or-store/MXR permissions and
  A-only checks; retain store/D requirements for ZERO. Exclude CBOs from
  ordinary 8-byte cross-page checks, preserving their aligned 64-byte extent.
- Add `csr-test`, `sv39-test`, `ifu-test` and `svinval-decode-test`; extend
  existing MMU, vector-MMU and privilege firmware rather than duplicate it.
  Add the independent `karu64-sv39` ACT4 privileged-1.13 starter configuration.
  The Svpbmt/physical-IO checkpoint passes **97/97** selected supervisor tests
  on default and four Svpbmt tests on shipping, retaining Sstc/Svnapot.
  Scalar MMU (389 cases), vector NC/IO and injected-fault observers pass both
  models; scalar/vector firmware also passes Spike.
  The walker passes 28,506 checks, IFU 126 and I-cache 330. The five CSR rows
  pass 7,045 / 7,045 / 7,052 / 1,280 / 1,280. PLIC passes 49,208 checks;
  Ethernet bridge rows pass 44 cases each. Independent full ACT4 regressions
  also pass **2600/2600 in each configuration** at this physical-IO checkpoint,
  with matching architectural/HTIF verdicts and no error/timeout markers.
  These models predate the subsequent H and precise-fetch-ordering changes.
  The previous Sstc/Svnapot checkpoint passed 93/93 default and five shipping
  feature cases, plus directed timer/MMU firmware on both models and Spike.
  Correct the ACT4 Sm counter-wrap
  generator to avoid a cycles-per-instruction assumption, and update DDR
  protocol assertions for the implemented one/two-beat stores.
  See [the test flows](doc/flows.md#supervisor-regressions).
  These changes are an implementation milestone, **not** full `Ss1p13` or
  RVA23S64 certification; see [the completion roadmap](doc/rva23s64-plan.md).
  The preceding, pre-Sstc/Svnapot supervisor-foundation rerun of all 2600
  existing ACT4 tests passes in both default and shipping arithmetic/pipeline
  configurations: **2600/2600 each**, with no failures, timeouts or missing
  verdicts. Directed/KAT, SoC interrupt,
  lint and runtime-divider checks also pass. The `b9f0145` area/timing
  results below remain the preceding baseline, not measurements of this RTL.
  Broader platform assurance, H/Sha and the full profile audit remain
  outstanding. Default/shipping structural divider audits also pass with
  Yosys 0.69+24 (`d0e71cfb7`); these are not new measured area/timing results.

### Fixed and optimized — vector legality and SHAKE throughput

- Pipeline vector mask summaries (`vcpop.m`, `vfirst.m`, prefix masks) using
  balanced 16-bit partial-count/priority trees and a registered final fold.
  Replace the 128-deep conditional count chain with a nine-bit accumulator;
  add a Spike-checked sweep of every `vl=0..256` and five source/mask patterns.
- Complete the existing lane register boundary: capture mask bits, opcode,
  rounding, predicates and scalar result inputs alongside the operands.
  This removes the SEW-dependent mask-selection bypass into carry arithmetic
  without adding instruction cycles.
- Stage the complete vector-FPU request with `KARU_V_LANE_PIPE`, separating
  operand widening/selection from FPU input normalization. Each lane-FPU
  request gains one fixed dispatch cycle; reciprocal estimates are unchanged.
- Replace the VLSU's linear first/last-active-element priority scan with
  balanced trees. Active ranges, fault preflight and memory cycle counts
  are unchanged.
- Elaboration-gate scalar combinational multiply/divide in serial builds.
  Add `KARU_DIV_AUDIT_ONLY=1` to reject live division/modulo operators in
  release synthesis configurations before technology mapping.
- Full-vector 200 MHz mapped setup at `b9f0145` improves from WNS −7.2097 ns to
  +0.0698 ns with zero TNS; full-ABC mapped area decreases 1.15%.
  Constraint coverage is clean, but electrical-limit violations remain.
  Record the mapping sequence and reproduction command in the
  [synthesis-flow instructions](flow/syn/README.md).
- Complete routed VCU118 vector ROM/SGMII timing at `b9f0145`: 75 MHz core
  setup +0.205 ns, hold +0.011 ns, with zero TNS/THS across all constrained
  clock groups. Bitstream generation completed; no programming or boot test
  was performed. This result predates the supervisor-foundation changes.

- Share integer widening/narrowing SEW/LMUL/alignment/overlap checks across
  base V and Zvbb; enforce masked destination-v0 rules with mask/reduction
  exceptions. Fractional widening no longer drains an empty adjacent register.
- Correct mask-destination exceptions for FP min/max reductions and prefix
  masks; expand the reserved-encoding suite to 71 cases. Add `vwalk-test`,
  `vwalk-test-ship` and `vwalk-test-spike` for vector-length boundary sweeps,
  plus VLSU request-contract and lane-geometry assertions.
- Fetch Keccak state through both VRF read ports, launch demand reads earlier,
  and bound element-local lane walks by vl. Contiguous loads use byte-enabled
  writes; contiguous store snapshots are bounded and pipelined.
- Burst cacheable vector stores, omit empty halves, and buffer a waiting
  granule; drain at instruction boundaries. Update HTIF and FPGA BRAM write
  backends for bursts. Add SHAKE correctness and AXI transport regressions.
- Add `make keccak-bench`: ideal-memory absorb is 221.75/197.75 cycles and
  squeeze is 156.88/144.56 cycles at 168/136 bytes after access-fault fixes. See
  [the throughput report](doc/keccak-throughput.md) for scope and release gates.
- Add `test/keccak-sw/` and `make keccak-compare`: reproducible six-row
  GCC/Clang RV64GC, Zbb and vector-enabled software comparison, pinned portable
  source, generated-fixture checks, full-state/output verification, and Spike
  cross-checks. Document [the measured comparison](doc/keccak-software-comparison.md),
  including the absence of a resident software-RVV permutation in these C builds.
- Regenerate and run the full ACT4 suite on the `b9f0145` baseline with the act4
  branch tip (`80d5633`), Sail 0.13.1 and udb 0.1.16: 2600 PASS / 0 FAIL across
  2600 unique ELFs, including scalar 389/389 (22 Zfa cases) and Zvbb 61/61. All 2549 previous
  cases still pass. Repeat the full set after the timing-pipeline changes:
  2600/2600 in both default and shipping arithmetic/pipeline simulations.
  Bring the DUT config forward (Sail 0.13.1
  schema, `V` declared with `support_level: Full`, Zihpm and Zmmul declared,
  generated `rvtest_config.h`), which also unblocks the nine `Vx64`
  `vmulh*`/`vsmul` tests the old flow could not generate. The initial 2550 tally
  double-counted a test across batches. Enable ACT4's standard M-mode trap
  handler, declare the implemented time CSR and omit absent HTIF timer MMIO;
  all 29 formerly blocked references now generate and pass. Fix vector-FP
  FS=Off rejection and strict source/group/reserved-field checks exposed by
  these cases. Extend the runner guards for the expanded suites.
  The maintained regression recipe is in [test/act4-karu/README.md](test/act4-karu/README.md).
- Extend vector legality to FP widening/narrowing, extension/gather source
  geometry, permute overlap, mixed-EEW sources and vector-memory groups/fields.
  Correct the earlier masked-source-v0 interpretation: mask EEW=1 conflicts
  with wider element data, even where Spike permits the reserved encoding.
  Include vector-FP in FS dirty tracking; the 25-case FS/VS suite checks
  rejected-operation side effects and enabled flag/scalar-register writes.
- Register the intermediate integer in Zfa `fround`/`froundnx`, breaking the
  composed converter timing path at the cost of one extra dispatcher cycle.
  Expand Zfa edge coverage and add `zfa-test-all` with an enforced Spike
  result/flags digest comparison. Suppress `fcvtmod.w.d` NX when NV is raised;
  the expanded overflow-with-fraction cases exposed this pre-existing flag bug.
  Enable the ACT4 ZfaF/ZfaD slices in the maintained DUT/reference configuration.
- Fix `vfmv.s.f` group writes, XLEN-wide slide offsets, and e64 `vsmul`
  saturation in both combinational and serial multipliers. All 106 prior
  ACT4 failures now pass.
- Add physical access checks and AXI-error propagation through caches, LSU,
  page-table walkers and fetch. Preserve fault-only-first trimming; report
  vector bus faults with VA/vstart. Keep posted stores active until their final
  response and cancel queued suffixes on error. HTIF/BRAM models reject RAM
  aliases outside their windows; the DDR crossbar preserves error responses.
  Add `access-test` and extend the shared AXI responder regression.
- Make the riscv-tests runner fail on missing sources, an empty test selection
  or a failed build; an unpopulated submodule previously returned a false
  successful zero-test summary.
- Consolidate shared privilege-test linker scripts and SHAKE known-answer
  data; remove the duplicate synthesis setup template. ACT4 uses the caller's
  tool environment instead of a hardwired home-directory installation.

### Changed — `vkeccak` now implements the Zvknhk specification (breaking)

- The Keccak instruction follows the draft **Zvknhk** Vector Keccak extension
  of the RISC-V PQC TG, [riscv/riscv-pqc](https://github.com/riscv/riscv-pqc)
  `src/zvknhk.adoc` (commit `260e14b`), and is binary-compatible with that
  repository's Spike and QEMU reference models:
  `vkeccak.vi vd, imm5` = `.insn r 0x77, 0x2, 0x53, vd, x18, imm5`
  (MATCH `0xa6092077`, MASK `0xfe0ff07f`). `imm5=0` runs Keccak-p[1600,24]
  (SHA-3/SHAKE), `imm5=1` runs Keccak-p[1600,12] with round constants
  RC[12..23] (TurboSHAKE/KangarooTwelve); all other values are reserved.
- Operand semantics per the spec: one fixed 2048-bit element group at `vd`
  (`NREG = ceil(2048/VLEN)` registers, 8 at VLEN=256), independent of `vl`
  (including `vl=0`) and LMUL; elements 25..31 (the state tail) and all other
  registers are untouched.
- Reserved encodings raise an illegal-instruction trap at issue with no side
  effects: `SEW≠64`, `imm5>1`, `vm=0`, `vd` not NREG-aligned, `vstart≠0`.
- **Breaking:** the previous keccak-xrv form (`.insn r 0x77,0x2,0x53,vd,x17,x24`,
  fixed 24 rounds) is no longer decoded and traps. Software must use the new
  encoding; `../karudeb` was updated in step.
  (`rtl/karu_dec.v`, `rtl/zvk/keccak.v`, `rtl/karu_varith.v`, `rtl/karu64.v`)

### Added

- Full RVA23U64-mandatory **Zvbb**. The existing Zvkb lane operations are
  joined by `vbrev.v`, `vclz.v`, `vctz.v`, `vcpop.v`, and
  `vwsll.{vv,vx,vi}`. Unary counts use bounded byte leaves and balanced trees;
  `vwsll` reuses the staged base-V widening engine. Normal V builds enable
  Zvbb; `KARU_NO_ZVBB` is the synthesis-isolation opt-out.
- `make zvbb-test-all`: one self-checking ELF on Karu and Spike, covering all
  unary SEWs (including exhaustive e8 inputs), mask/tail preservation, all
  widening-shift forms, fractional LMUL with an adjacent-register canary,
  LMUL=2→4 and maximum LMUL=4→8 traversal, legal overlap, and reserved
  widening encodings.
- `make keccak-kat`: standalone `keccak.v` known-answer test with the spec's
  KECCAK-P (24-round) and KECCAK-P12 (12-round) vectors (`test/zvk/tb_keccak_kat.sv`).
- `make keccak-test` / `make keccak-test-zvk`: full-core `vkeccak.vi` test on
  the `KARU_KECCAK` and the shipping `KARU_ZVK KARU_KECCAK` builds — spec KATs,
  two dependent ops back to back, fixed-group / state-tail / `vl` / LMUL rules,
  and 11 reserved-encoding trap cases with a no-side-effect check
  (`test/fw/keccak_subj.c`). The decode bench covers the new encoding and the
  trapping of the old word.
- `CHANGELOG.md` (this file).

### Fixed

- `rtl/karu_varith.v`: the `vfslide1up/down` source index used `/ epr` and
  `% epr` with a runtime divisor, which synthesised a 32-bit divider; now a
  shift and mask (`epr` is a power of two). No functional change
  (`make vfp-test` 46/46; Vivado elaboration clean).
- Makefile: the `Vhtif_kec` / `Vhtif_zvk_kec` Verilator rules did not create
  their output directories and failed in a clean checkout.
- Correct `flow/syn` (Yosys + OpenSTA estimate flow) failures:
  liberty lookup only searched inside the checkout; OpenSTA 2.4 rejected
  `-group_path_count` so every timing report was empty; `KARU_LTP=1` ran `ltp`
  on the mapped netlist and produced a multi-GB false-loop report; the fast
  ABC script skips buffering/sizing so STA slack was meaningless (thousands of
  ns on one unbuffered inverter). Timing runs now use the full ABC script, the
  depth report runs pre-map with the top/cache modules excluded, and the
  scripts adapt to the OpenSTA version. Re-measured RV64GC core-only numbers
  are in `flow/syn/README.md` (398 kGE, ~6.7 ns critical path through the Zfa
  `fround.d` compose in NanGate45 typical).

### Documentation

- `README.md`, `doc/architecture.md`, `doc/flows.md`, `rtl/zvk/README.md`:
  Zvknhk encoding/semantics, the spec location and commit, the new test
  targets; "custom/experimental Keccak" wording removed.
- `flow/syn/README.md`: flow status, corrected tunables, re-measured timing
  and the note that RV64GCV rows need a ≥64 GB host.

### Hardware status

- VCU118 vec ROM bitstream rebuilt from `48e4d86` with Vivado 2026.1
  (`ddr_vec_sgmii_75_rom`, WNS +0.045 ns at 75 MHz, DRC clean; ROM = fu-boot +
  OpenSBI v1.8.1 + U-Boot 2025.01 + zvk-ddr DTB), programmed and booted to a
  Debian NFS-root shell on the lab board (2026-09-11).
- That image requires CPU_RESET or reprogramming for restart. Its warm-reset
  TFTP failure handling is superseded by the current ROM's bounded retries
  and `&&` success guards.

## [main @ `8da799a`] — 2026-06-21 … 2026-06-29

Initial public tree (`73b4906 init`, 2026-06-21) and June follow-ups:

- RV64GCV core (RV64IMAFDCV + Zicsr/Zifencei, RVV 1.0, Zvl256b), M/S/U with
  Sv39, CLINT/PLIC/NS16550; `make test` 110/110; generated RV64GCV ACT4
  2220 PASS / 0 FAIL.
- Zvk vector crypto (Zvkned, Zvknha/b, Zvksed, Zvksh, Zvkg, Zvkb) behind
  `KARU_ZVK*`; Keccak-f[1600] permutation instruction behind `KARU_KECCAK`
  (pre-Zvknhk keccak-xrv encoding, replaced above).
- VCU118 SoC: BRAM and DDR4 (MIG) variants, LiteEth SGMII netboot, hands-off
  boot ROM (fu-boot + OpenSBI + U-Boot + DTB); Debian NFS-root Linux with
  kernel 7.1.2 boots from the bitstream built with Vivado 2026.1.
- Verilog-2001 audit for Genus/Vivado, explicit memory leaf modules, Yosys /
  OpenSTA NanGate45 estimate flow and area matrix, Marian-derived Zvk leaf
  cores with KATs.
