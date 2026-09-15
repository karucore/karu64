# RVA23S64 configuration security review — 2026-09-14

Review date: **2026-09-14**. Source checkpoint: `69c58cd`. Scope: the
RVA23S64 ASIC processor handoff selected by
[`flow/asic/rva23s64.defines`](../flow/asic/rva23s64.defines), with supporting
review of the shared FPGA/profile integration where it establishes an interface
assumption. This is a source and configuration security review, not a penetration
test, formal information-flow proof, physical side-channel evaluation, secure-boot
certification or complete RVA23S64 conformance verdict.

The review is complemented by the current
[Zkt/Zvkt DIEL review](diel-review-2026-09-14.md).
That audit supports fixed cycle sequencing for its covered instruction families.
It deliberately excludes power/EM leakage, physical propagation differences,
secret-dependent software addresses and branches, and formal noninterference.

## Result

No new privilege-escalation or two-stage-translation RTL defect was found in the
reviewed CSR, trap, MMU, cache and atomic paths. The configuration should not yet
be treated as ready for an adversarial, secure-boot or mutually distrusting
multi-tenant deployment. Four high-severity integration or lifecycle gaps and one
medium-severity fault-integrity gap remain.

## Findings

### S1 — High: AXI protection metadata does not describe the requester

Instruction fetch, data traffic and page-table walks drive `ARPROT`/`AWPROT` to
zero in `karu_ifu`, `karu_mem`, `karu_lsu`, `karu_icache` and `karu_sv39`.
Under the [AMBA AXI protection encoding][axi], `3'b000` identifies an
unprivileged, Secure, data access. Machine, HS, VS, S, U and instruction accesses
therefore cannot be distinguished using the core's AXI protection outputs. A
downstream firewall that interprets the Secure bit literally would see every
transaction, including guest and U-mode traffic, as Secure.

The processor's internal page translation and PMA checks still apply; this
finding concerns protection delegated to the SoC interconnect or peripheral
firewalls. Before such a firewall is part of the security boundary, derive the
privileged/unprivileged and instruction/data fields from the effective access
context, define the intended Secure/non-secure mapping, or provide explicit
trusted-domain sidebands. Add assertions and adversarial bus tests for every
privilege and virtualization mode.

### S2 — High: zero PMP entries leave no M/HS physical carve-out

PMP is not implemented. `pmpcfg0..15` and `pmpaddr0..63` are present as WARL
read-zero CSRs, while the standard PMA function considers only the address and
access kind. Consequently, the hart has no programmable hardware boundary that
can keep an untrusted S/HS execution environment out of machine firmware,
platform secrets, or selected physical devices. Guest isolation still has the
implemented G-stage translation boundary; this finding concerns trust between
M-mode and the host supervisor, and physical containment when paging is Bare or
misconfigured.

PMP is optional in the [RISC-V privileged architecture][pmp] and is not in the
[RVA23S64 mandatory-extension list][rva23], so this is not an RVA23S64 profile
violation. A secure platform should implement PMP, preferably with the relevant
Smepmp lockdown policy, or provide equivalent physical enforcement in the SoC.
The latter depends on resolving S1 so the interconnect receives trustworthy
access-domain information.

### S3 — High when reset changes ownership: register state is not scrubbed

`KARU_ASIC` removes the FPGA/simulation initial values from the integer register
file, FP register file, vector register file and `v0` shadow. Those arrays begin
unspecified and retain their contents across soft reset. Control reset prevents
stale cache and TLB entries from remaining valid, but it does not erase prior
integer, FP, vector or crypto operand data. A warm reset, tenant transition or
security-domain restart can therefore expose residual secrets after the next
software context enables or reads the corresponding state.

Define whether reset is a confidentiality boundary. If it is, hold the core in a
trusted reset/boot state until hardware or immutable firmware has overwritten all
architectural register state and any retained scratch storage. Verify the scrub
under randomized initial state and across each supported reset and power-domain
sequence. The current ASIC checks validate correct handling of unspecified state;
they do not establish erasure.

### S4 — High for a secure-boot product: the handoff has no immutable reset path

The delivered top retains `RESET_PC=0x80000000`, in the writable DRAM region, and
the ASIC source manifest excludes the boot ROM, reset controller, system memory,
timer, interrupt controller and authentication logic. Unlike the VCU118 profile
SoC, the processor handoff therefore supplies no immutable first instruction or
authenticated chain of trust. Executing mutable or externally preloaded DRAM at
reset is not an acceptable root of trust where an attacker can alter that memory.

The SoC integration should override `RESET_PC` to immutable ROM, provide a
conditioned reset and authenticated boot chain, and bind the ROM and security
configuration into the delivered configuration manifest. This is a platform
obligation rather than an ISA-profile requirement.

### S5 — Medium: security-relevant state has no fault detection

The memory interfaces request no ECC or parity for register files, caches, vector
storage, or TLB/PWC-related arrays. Neither the handoff nor the source audit
provides an integrity response for a transient or injected storage fault. Such a
fault can silently change code/data, key material, translations or cached
permissions; availability failures are also possible.

Select parity/ECC behavior during macro binding according to the threat model.
At minimum, protect translation tags/data and architectural register storage,
define detected-error behavior, and add fault-injection checks that demonstrate a
contained trap or reset instead of silent use.

## Positive controls observed

- `KARU_RVA23S64` rejects mandatory ISA opt-outs and fixes the reviewed
  VLEN/ELEN/VBUS geometry.
- CSR privilege checks, state-enable gates, counter filtering and H/VS trap
  routing are explicit, with reset-deny defaults for state-enable controls.
- Host and guest TLB entries carry address-space/root context; translation fences
  invalidate TLB/PWC state and poison outstanding walks.
- PMA checks use the full physical address before the 32-bit AXI narrowing.
  Device atomics and misaligned atomics are rejected before bus activity.
- The single-issue, in-order core has no branch predictor or execution past an
  unresolved branch, reducing speculative-execution attack surface.
- The optional JTAG AXI loader and host hold are absent from the reviewed ASIC
  manifest.

## Validation run during this review

| Check | Result |
| --- | --- |
| `make rva23-config-test` | PASS: legacy 25, profile 10, conflicts 10, geometry 15×3 |
| `make csr-h-test-pmu` | PASS: 66,978 checks |
| `make sv39-test` | PASS: 35,155 checks; host/two-stage, flush/cancel and exact PTE reads |
| `make lsu-atomic-test` | PASS: 27,708 checks, including 8,762 rejected transactions |

These regressions support the reviewed architectural mechanisms. They do not
close S1–S5 or expand the completed DIEL audit beyond its documented scope.

[axi]: https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf
[pmp]: https://docs.riscv.org/reference/isa/priv/machine.html
[rva23]: https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html#_rva23s64_mandatory_extensions
