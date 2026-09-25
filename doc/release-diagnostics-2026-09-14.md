# RVA23S64 release diagnostics — updated 2026-09-22

This is the current handoff record for the opt-in RVA23S64 shipping
configuration. It reports source, simulation, synthesis and board evidence as
separate results. A passing configured suite or mapped estimate is not by
itself an ISA certification or physical signoff result.

The September 22 image passes board acceptance and the thorough Linux
7.2.6-zvk test run, including both KVM guests and vector SM4. No functional
regression was observed against the September 15 image.

## Source scope

The Genus declaration-order cleanup is recorded in commit `26b421c` on
`mjos-dev`; its source checks are described in the
[ASIC handoff](../flow/asic/README.md#coding-rules-for-the-genus-front-end).
The simulation, ACT4 and synthesis reference results below belong to the
September 15 checkpoint `a0062b9`, before that cleanup. The September 22
hardware results are tied to the new bitstream hash separately.

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

## Reference functional validation — 2026-09-15

| Check | Result |
| --- | --- |
| `make zvk-test-all` | PASS on the same ELF under Spike and Karu; Karu HTIF exit 0 at cycle 95,297 |
| Exact shipping `zvk-test` | PASS on a forced-fresh simulator; HTIF exit 0 at cycle 102,281 |
| `make zvk-kat zvk-decode-test zvk-decode-leaf-test` | PASS |
| Multi-group `.vs` semantics | `vaesem`, `vaesef`, `vaesdm`, `vaesdf`, `vaesz` and `vsm4r` PASS at `vl=8,m1` and `vl=16,m2`; later `vs2` element groups are deliberately distinct |
| `make diel-test-ship` | 215/215 operand-class checks PASS; HTIF exit 0 at cycle 6,046,463 |
| Directed H/platform checkpoint | CSR/H, PMU, two-stage translation, PLIC, memory stream, BRAM/DDR responder and five-delay preemption suites PASS as recorded by their maintained targets |
| `python3 flow/asic/audit.py` | PASS: 9 macro candidates, 2 register files, 4 scratch arrays, 97,024 logical data bits and zero initialized ASIC state |
| `python3 flow/asic/check.py` | PASS: four-state memory controls plus `vresv`, `vperm` and `vstart` with randomized startup seeds 1 and 42 |
| `make syn-runtime-div-audit{,-rva23s64}` | PASS for mandatory and exact shipping compositions: no live variable division/modulo operators; input manifests unchanged |

The multi-group `.vs` regression compares each operation against its `.vv`
equivalent with source element group zero repeated explicitly.

The DIEL result is a source review plus empirical cycle-equality test, not a
formal noninterference or physical side-channel claim. Full scope is in
[diel-review-2026-09-14.md](diel-review-2026-09-14.md).

## ACT4 — 2026-09-15

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

## Open-source synthesis — 2026-09-15

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

The current transfer contains only these files:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `_build/vcu118_ddr.bit` | 80,159,322 | `03eeb088971ef3a19183516ea53675cbaa141b8a935155cd8c80fb403a2e73d2` |
| `_build/vcu118_ddr.ltx` | 1,010 | `b4b1ce76f88f53501ca477b1c9203509a74dfbee529023656c78e5610b58c3f7` |

The bitstream header identifies Vivado 2026.1, `vcu118_ddr_top`, part
`xcvu9p-flga2104-2L-e`, and build date September 22. Programming with
Vivado/hw_server 2025.2.1 completed successfully; live UART capture remains
`_build/boot.log`.

The retained routed reports under `_build/fpga_rpt` describe the September
15 `c61da577…ed0da` reference image: CPU setup/hold **+0.046/+0.010 ns** at
75 MHz, whole-design **+0.009/+0.010 ns**, all 14 bus-skew constraints PASS,
and zero bitgen DRC errors. Reference utilization is 366,098 LUTs, 86,857
registers, 317.5 BRAM tiles and 29 DSPs. September 22 timing/utilization
reports were not transferred; these figures must not be relabelled as new
measurements.

## Board acceptance — 2026-09-22

Image: `03eeb088…e73d2`, 75 MHz, 2 GiB DRAM, Svpbmt-enabled RVA23S64 profile.
Boot: fu-boot → OpenSBI 1.8.1 → U-Boot 2025.01 → Linux 7.2.6-zvk →
Debian trixie NFS root.

| Check | Result |
| --- | --- |
| Root `board_accept.sh` | PASS; 256 MiB memory patterns, ISA discovery, PMU and KVM API |
| Zvknhk OpenSSL checks | 17 PASS |
| OpenSSL scalar/Zvk known answers | 92/92 match expected; 92/92 match scalar |
| SM4 ECB/CBC/CTR, `zvkb_zvksed`, `full`, `auto` | All match expected and scalar |
| KVM `ebreak_test` | Exit 0 |
| KVM `arch_timer -n 1 -i 2 -p 1 -m 0 -e 1000` | `PASS(vCPU-0)`, exit 0 |
| riscv-pqc `xtest`, 24/12-round `vkeccak.vi` | 39/39 PASS |
| `vill_probe` | 6 PASS |
| `validate_v_ptrace`, including syscall clobbering | 13 PASS, 6 SKIP, 0 FAIL |
| `vstate_ptrace` / `v_initval` | 2/2 / 1/1 PASS |
| `vstate_prctl` / `sigreturn` | 11 PASS, 2 SKIP / 2/2 PASS |
| CBO / hwprobe / which-cpus | 9/9 / 5/5 / 7/7 PASS |
| Cache-window probe, inside/outside 256 MiB | Fetch 4.41/4.42 cycles per instruction; loads 14.28/14.07 cycles per load; PASS |

Cache timings use `perf_run --user-count`; measured pages are at
`0x82d00000` and `0x938ae000`. The karudeb comparison reports cycle results
matching `c61da577` to two decimal places. OpenSSL's forced vector SM4 path
directly exercises the units changed by the declaration rewrite. These
results support no observed regression in Linux, KVM, crypto, vector ABI or
cache behavior; they are not a Cadence timing or formal equivalence result.

Evidence is on the board in `/root/thorough/` and `/root/accept-lint-03eeb088/`.
A local snapshot of result files, the karudeb transcripts, boot/programming
logs and hashes is retained in `_build/board-results-20260922/`.
See [fpga.md](fpga.md) for deployment and acceptance commands.

Process follow-up: reinstalling the NFS export removes the `/home/karu` ACL.
This run used `scp` for the twelve selftest binaries. An optional ACL grant
in karudeb's `install-nfs-root.sh` would make repeated deployment easier;
no installer change was made here.

## 1W2R FP register file image — 2026-09-24

Built from commit `7c2563e` (two-read-port `karu_fregfile`, FMA rs3 on the
time-shared port B; see the [changelog](../CHANGELOG.md)) with
`flow/with_vivado.sh make vcu118-ddr-sgmii-rom-rva23s64 VIVADO_THREADS=8`,
Vivado 2026.1, from an empty `_build` (all IP, U-Boot and ROM inputs
regenerated). Wall clock 1 h 54 min: synthesis 19 min, placement 37 min,
routing 31 min, post-route `phys_opt_design` 47 s, bitstream 2 min.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `_build/vcu118_ddr.bit` | 80,159,322 | `b11d5efb79a544f9205c893a7fd0b038302f71adc5e7fd12b54459bb3bc3b809` |
| `_build/vcu118_ddr.ltx` | 1,010 | `b4b1ce76f88f53501ca477b1c9203509a74dfbee529023656c78e5610b58c3f7` |

The bitstream header identifies `vcu118_ddr_top`, `xcvu9p-flga2104-2L-e`,
2026/09/24 20:27. `_build/vcu118_programming.tgz` packs both files.

Routed timing at 75 MHz, from `_build/fpga_rpt/ddr_rva23s64_sgmii_75_rom__*`:

| Metric | Result |
| --- | --- |
| Whole design setup / hold / pulse width | **0.000 / +0.012 / +0.005 ns**, 0 failing of 238,917 endpoints |
| `cpu_clk` setup / hold | **+0.077 / +0.012 ns**, 178,449 endpoints |
| Zero-slack endpoints | AXI width-converter to clock-converter FIFO paths inside the Xilinx DDR interconnect IP (`u_dwc` → `u_cdc`), as in earlier images |
| Bus skew | 14/14 constraints MET |
| DRC before bitstream | 0 errors |
| Synthesis log | 0 errors; 1 critical warning, the generated `ddr4_0_board.xdc` `BOARD_PART_PIN` line (Xilinx IP, benign) |
| Utilization | 349,701 LUTs, 87,428 registers, 5,099 LUT-as-memory, 317.5 BRAM tiles, 29 DSPs |

The router finished at −0.086 ns; the flow's automatic post-route
`phys_opt_design` closed it. None of the 100 worst-slack paths involves the
FP register file, the rs3 address steer or the FMA units; `frf/fx_reg` is
inferred as LUTRAM with two read replicas instead of three. Utilization is
16,397 LUTs below the September 15 reference figure, though that reference
predates other changes, so it is not attributable to this change alone.

Gate before synthesis, all on `7c2563e`: `h-test` fixtures, `h-preempt-test`
and the complete ACT4 profile inventory (2872/2872) in addition to the FP,
FMA-hazard, TestFloat, ASIC and lint checks recorded in the changelog. Boot
inputs (`make rva23-boot-inputs-check`) are the unchanged karudeb `main`
(`96ccaca`): `karu64-rva23s64-ddr.dtb`, OpenSBI `fw_jump.bin` and the staged
`rva23s64-ddr` netboot one-liner. **Board programming and acceptance of this
image have not been run**; `03eeb088…e73d2` remains the last accepted image.

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
