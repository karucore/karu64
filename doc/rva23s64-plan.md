# RVA23S64 profile status

`KARU_RVA23S64` is the opt-in composition used for the supervisor-profile
simulator, ASIC source manifest and VCU118 profile image. It binds the
mandatory RVA23S64 ISA features implemented by karu64, including the RVA23U64
baseline, H/Sha, Ssstateen and Sscofpmf, and rejects conflicting opt-outs or
unsupported VLEN/ELEN/VBUS geometry.

This document is a current implementation and release checklist. It is not a
certification statement. Historical bug narratives and completed implementation
plans are intentionally not retained; the tests and current diagnostics are the
regression record.

## Implemented profile features

| Area | Implemented behavior and maintained evidence |
| --- | --- |
| RVA23U64 baseline | RV64GCV, Zba/Zbb/Zbs, Zicond, Zimop/Zcmop, Zawrs, Zihintntl, Zcb, Zicbom/Zicbop/Zicboz, Zfa, Zfhmin, Supm and full Zvbb. ACT4 plus directed Spike tests cover the configured instruction set. |
| Ss1p13 foundation | M/S/U trap, delegation, return, counter, environment and state-enable CSRs implement the privileged-1.13 contract used by the profile. |
| Address translation | Bare and Sv39, Svade fault-on-clear A/D, 64 KiB Svnapot, Svpbmt, conservative Svinval and full-address fault reporting. |
| Timers and PMU | Sstc, Sscofpmf, optional Smcntrpmf, virtual time and Shlcofideleg cause-13 delegation. |
| Sha | H CSR banks and traps; VS Bare/Sv39; G Bare/Sv39x4; two-stage walks; HLV/HLVX/HSV; HFENCE/HINVAL; guest timers, pointer masking, PBMT/CBO and FP/vector state. GEILEN=0 is supported. |
| Platform memory behavior | Full 2 GiB FPGA DRAM PMA/cache window, exact device accesses, bus-error access faults, natural atomic alignment, vector fault-only-first trimming, posted-store draining, cache-alias invalidation and exact local PTE reads. |

The microarchitectural details are in [architecture.md](architecture.md).
Configuration and execution recipes are in [flows.md](flows.md),
[fpga.md](fpga.md) and the test-specific READMEs.

## Current validation

- The matched minimal and shipping profile ACT4 checkpoint passed 2872/2872
  configured tests each. ACT4 reference/harness patches, composition and replay
  rules are documented in [test/act4-karu/README.md](../test/act4-karu/README.md).
- Directed H monitors cover two-stage translation, PBMT/CBO, virtual timers,
  counter filtering, Shlcofideleg, guest FP/vector context switches and
  asynchronous preemption. The current Sail and Spike adjustments are isolated
  under their test directories.
- The September 25 VCU118 1W2R FP image passes Linux 7.2.6-zvk board
  acceptance at 75 MHz, including memory, cache, crypto and KVM API checks;
  full on-board TestFloat3 is in progress. The September 22 reference image
  passed the KVM guest and extended vector ABI tests. Image-specific coverage
  and separately dated synthesis measurements are in the
  [release diagnostics](release-diagnostics-2026-09-14.md).
- Optional vector crypto and `vkeccak.vi` are outside the ACT4 profile
  selection. Their known-answer, decode, Spike and multi-element-group tests
  are documented in [rtl/zvk/README.md](../rtl/zvk/README.md).
- The current security and data-independent-latency scopes are recorded in
  [security-review-2026-09-14.md](security-review-2026-09-14.md) and
  [diel-review-2026-09-14.md](diel-review-2026-09-14.md).

Exact current run status and synthesis artifacts are listed in
[release-diagnostics-2026-09-14.md](release-diagnostics-2026-09-14.md).

## Deliberate limits

The current profile configuration remains one hart with Sv39 and small,
sequential translation structures. RVA23S64 does not require Sv48/Sv57, AIA,
IMSIC, an IOMMU, PMP, full Zvfh, Zvbc, Zacas, Zabha, hardware A/D updates or
Ssstrict, so these are not enabled by the profile contract.

Two distinctions matter for integration:

- Guest PMU overflow injection in the karudeb Linux 7.2.4 KVM tree uses the
  optional Ssaia `hvien` path. Karu implements mandatory Sscofpmf and the
  standard Shlcofideleg shared-pending path, but not Ssaia. Guest perf sampling
  with that kernel is therefore unavailable even though the mandatory profile
  behavior is present.
- The CPU profile does not itself provide PMP, an immutable reset/boot path,
  AXI requester-security metadata, register-state scrubbing or memory ECC.
  Those platform-security obligations are described in the security review.

## Release gates

Before treating a source checkpoint as a release candidate:

1. Run the matched ACT4 profile composition and all directed supervisor/H,
   vector, crypto, memory and assertion suites on a simulator rebuilt from the
   same RTL.
2. Run `make diel-test-ship`; retain equality across all operand classes and
   the final `ALL PASS`/HTIF exit markers.
3. Refresh the Yosys area matrix and 200 MHz OpenSTA result with the documented
   tool/library versions. Treat electrical checks and timing separately from
   the area estimate.
4. Build `vcu118-ddr-sgmii-rom-rva23s64` in the standard `_build` directory,
   verify all routed clock constraints, and retain the bitstream, reports,
   build log and boot-input hashes.
5. Boot the matching karudeb OpenSBI/U-Boot/Image/DTB/rootfs set. Run board
   vector ABI, cache/performance, crypto/Keccak and KVM timer/exception tests;
   keep ROM and TFTP DTBs byte-identical.

Profile conformance, Linux distribution compatibility and a secure deployment
environment are separate acceptance claims and should be reported separately.
