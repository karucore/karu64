# RVA23S64 release diagnostics — updated 2026-09-15

This is the current handoff record for the opt-in RVA23S64 shipping
configuration. It reports source, simulation, synthesis and board evidence as
separate results. A passing configured suite or mapped estimate is not by
itself an ISA certification or physical signoff result.

The shipping image passes September 15 board acceptance with Linux
7.2.4-zvk. Build identity, validation results and remaining limits follow.

## Source scope

The measured release checkpoint is commit
`a0062b9dda485bb391729b7c7aca13be4a3aee33` on `dev-mjos`. Each generated
manifest also records the exact source hashes, so the evidence remains
attributable after documentation-only updates.
The vector-crypto correction used by every current run has
`rtl/karu_varith.v` SHA-256
`af7b6829866f4cd45ac7bc480435d6c05c775d1fe4e4805d28e354bd24c9ee19`.

The shipping composition is:

```text
KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK
KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64
KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64
KARU_V_LANE_PIPE KARU_V_CWB_STAGE
KARU_SMCNTRPMF KARU_SSCOFPMF
```

The current RTL includes the full 2 GiB cache window, exact local PTE reads,
malformed-burst rejection, cacheable-alias invalidation after bypass stores,
bus-error access faults, Shlcofideleg, writable SGEIE under H, CLINT/PLIC and
DDR-stall assertion coverage, corrected `vsetvl` high-bit legality, and the
vector-crypto `.vs` source-group fix.

## Functional validation

| Check | Current result |
| --- | --- |
| `make zvk-test-all` | PASS on the same ELF under Spike and Karu; Karu HTIF exit 0 at cycle 95,297 |
| Exact shipping `zvk-test` | PASS on a forced-fresh simulator; HTIF exit 0 at cycle 102,281 |
| `make zvk-kat zvk-decode-test zvk-decode-leaf-test` | PASS |
| Multi-group `.vs` semantics | `vaesem`, `vaesef`, `vaesdm`, `vaesdf`, `vaesz` and `vsm4r` PASS at `vl=8,m1` and `vl=16,m2`; later `vs2` element groups are deliberately distinct |
| `make diel-test-ship` | 215/215 operand-class checks PASS; HTIF exit 0 at cycle 6,046,463 |
| Current directed H/platform checkpoint | CSR/H, PMU, two-stage translation, PLIC, memory stream, BRAM/DDR responder and five-delay preemption suites PASS as recorded by their maintained targets |
| `python3 flow/asic/audit.py` | PASS: 9 macro candidates, 2 register files, 4 scratch arrays, 97,024 logical data bits and zero initialized ASIC state |
| `python3 flow/asic/check.py` | PASS: four-state memory controls plus `vresv`, `vperm` and `vstart` with randomized startup seeds 1 and 42 |
| `make syn-runtime-div-audit{,-rva23s64}` | PASS for mandatory and exact shipping compositions: no live variable division/modulo operators; input manifests unchanged |

The multi-group `.vs` regression compares each operation against its `.vv`
equivalent with source element group zero repeated explicitly.

The DIEL result is a source review plus empirical cycle-equality test, not a
formal noninterference or physical side-channel claim. Full scope is in
[diel-review-2026-09-14.md](diel-review-2026-09-14.md).

## ACT4

The final exact-shipping replay passed **2872/2872** configured tests. It used
Sail 0.14, regenerated all 2872 reference ELFs for the current configuration,
and ran the current shipping Verilator composition. Post-run SHA-256
verification found no reference-ELF changes. The result table SHA-256 is
`4c6f803430acc47d53e1e03e0a6475a7a9c263c9e6c228fce29ec9908856d9f5`.

The retained evidence is under
`_build/act-work-rva23s64-smcntrpmf-fsm-final`: `results.tsv`,
`results.sha256`, the before/after reference-ELF manifests,
reference/model/simulator identity hashes and individual logs. The profile
configuration itself is maintained under `test/act4-karu`. Exact patch provenance,
coverage boundaries and reproduction commands are in
[test/act4-karu/README.md](../test/act4-karu/README.md).

## Open-source synthesis

The corrected-source refresh uses:

- Yosys 0.69+24 (`d0e71cfb7`);
- OpenSTA 3.1.0 (exact executable and hash in the run manifest);
- NanGate45 typical, NAND2_X1 = 0.798 square micrometres;
- hierarchical `-noshare`, 30% input and 70% output budgets;
- the full timing ABC script for the 5 ns target and `abc_fast.script` for
  area-only rows.

The exact shipping 5 ns run reports register-to-register WNS -0.2043 ns and
TNS -5.13 ns (about 192.1 MHz at zero slack). Input-to-register WNS is
+1.5412 ns, register-to-output WNS is +2.6833 ns, and there are no
input-to-output paths. A tighter full-ABC retry produced the same critical
slack, so the smaller regular map under
`_build/syn_out/timing_rva23s64_ship_200_zvk_vs_fsm_final_20260914` is retained.
The limiting cone is the existing vector widening/estimate path through
`u_widen_b` and lane `u_est`, not the `.vs` correction. Electrical-limit
violations remain in this generic estimate.

The affected/reference area rows (`rv64gcv_default`, `rv64gcv_zvkned`,
`rv64gcv_zvksed`, `rv64gcv_zvk`, `rv64gcv_zvk_keccak`, `rva23s64_ship`) all
completed successfully under
`_build/syn_out/area_matrix_zvk_vs_fsm_final_20260914`, with identical
before/after input manifests. The top areas are respectively 3667.90,
3706.47, 3683.68, 3806.98, 3894.17 and 4390.60 kGE. The exact hierarchy
breakdown, commands and interpretation are in
[flow/syn/AREA_MATRIX.md](../flow/syn/AREA_MATRIX.md).

## VCU118 implementation

The current standard build is:

```sh
flow/with_vivado.sh make vcu118-ddr-sgmii-rom-rva23s64
```

The standard target writes `_build/vcu118_ddr.bit`, reports under
`_build/fpga_rpt`, and `_build/vcu118_ddr_build.log`; it does not program the
board. This release implementation uses Vivado 2026.1.

The ROM build uses:

| Input | SHA-256 |
| --- | --- |
| karudeb OpenSBI `fw_jump.bin` | `307ff4379bb146646a0825b510e5f16b664c669e7b24390b381350a5a914fc21` |
| ROM RVA23S64 DTB | `d617ba564798245c27343e16c86e5d76ea65ed534cc1dfcd5044f74ab3b0cec9` |
| staged TFTP `board.dtb` | `d617ba564798245c27343e16c86e5d76ea65ed534cc1dfcd5044f74ab3b0cec9` |

`make rva23-boot-inputs-check` passes and the two DTB copies are identical.
The standard Vivado 2026.1 run completed at 2026-09-15 02:47 UTC. Bitgen and
its prerequisite DRC completed with zero errors. The final routed design meets
every user timing constraint: whole-design setup/hold WNS is
**+0.009/+0.010 ns**, and the 75 MHz `cpu_clk` setup/hold WNS is
**+0.046/+0.010 ns**. All 14 bus-skew constraints pass; the smallest margin is
+2.167 ns. Utilization is 366,098 CLB LUTs (30.97%), 86,857 CLB registers
(3.67%), 317.5 BRAM tiles (14.70%), and 29 DSPs (0.42%).

The generated handoff artifacts are:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `_build/vcu118_ddr.bit` | 80,159,322 | `c61da577953658e8a2e82f63a7ff03f48e0ec46027fc359d521ceb17711ed0da` |
| `_build/vcu118_ddr.ltx` | 1,010 | `b4b1ce76f88f53501ca477b1c9203509a74dfbee529023656c78e5610b58c3f7` |
| `_build/vcu118_ddr_route.dcp` | 358,144,611 | `bfa990f8dd8e21ebdd577b61f5165ead6928eeeb19ddf1a74f234e6dd70bbb41` |

Reports use the `ddr_rva23s64_sgmii_75_rom` tag in `_build/fpga_rpt`.
Programming completed successfully with Vivado/hw_server 2025.2.1.
Live UART capture uses `_build/boot.log`.

## Board acceptance — 2026-09-15

Image: `c61da577…ed0da`, 75 MHz, 2 GiB DRAM, normal Svpbmt-enabled profile.
Boot: fu-boot → OpenSBI 1.8.1 → U-Boot 2025.01 → Linux 7.2.4-zvk →
Debian trixie NFS root.

| Check | Result |
| --- | --- |
| Root `board_accept.sh` | PASS |
| Boot, NFS, Ethernet, ISA discovery | PASS |
| Memory patterns | 512 MiB PASS |
| PMU | Live cycle/instret counters; probe ratio ×1.09 |
| Zvknhk OpenSSL | 17 checks PASS across both backends |
| riscv-pqc instruction vectors | 39 PASS |
| `vill_probe` | 6 PASS |
| `validate_v_ptrace` | 13 PASS, 6 inapplicable-case SKIP, 0 FAIL; syscall clobbering PASS |
| Cache-window performance | PASS reported by karudeb with `perf_run --user-count` |
| KVM API | VM/vCPU creation and run-area mapping PASS |

Evidence: `_build/board-accept-c61da577-20260915/` contains the saved acceptance
transcript, probe outputs, boot/programming logs and hashes. The cache result
above is the corrected handoff result; the retained zero-cycle capture is
invalid. Current PQC/OpenSSL measurements are under
`../karudeb/build/paper-data-20260915/`.

Scope: KVM guest execution has hardware coverage on the September 14 image;
the retained September 15 KVM log covers the API only. Dedicated multi-group
`.vs` and resident-Keccak suite results are simulation evidence. Board
acceptance does not establish profile certification or ASIC security signoff.
See [fpga.md](fpga.md) for repeatable deployment and acceptance commands.

## Retained artifacts

Generated build products stay under `_build`. For handoff retain at least:

- `vcu118_ddr.bit`, optional `vcu118_ddr.ltx`, the Vivado build log and final
  post-route reports;
- OpenSTA/area manifests, summary CSV and timing reports;
- current ACT4 results plus reference/model/ELF hashes; and
- the DIEL and directed Zvk logs.

Regenerable intermediate Verilator C++, Vivado IP/project state and per-test
hex/bin/objdump files are not source inputs. Do not delete active job outputs
until their manifests and final reports have been captured.
