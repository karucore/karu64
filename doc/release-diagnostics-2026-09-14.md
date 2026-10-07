# RVA23S64 release diagnostics — updated 2026-10-06

This is the current handoff record for the opt-in RVA23S64 shipping
configuration. It reports source, simulation, synthesis and board evidence as
separate results. A passing configured suite or mapped estimate is not by
itself an ISA certification or physical signoff result.

The newest image, `28085356…abbd7` with the element-group `vkeccak.vi`
(October 6), is **validated on the board** (2026-10-07): it boots Linux
7.2.6-zvk, passes board acceptance and the full Zvknhk v0.2 software checks;
see [Board validation — 2026-10-07](#board-validation--2026-10-07). The
previous validated image is `b11d5efb…3b809` with the 1W2R FP register
file: it boots Linux 7.2.6-zvk and passes board acceptance. Its FP probe
completed; full on-board TestFloat3 is still running. The September 22
reference image also passed the separately recorded KVM guest and vector SM4
tests.

## Source scope

The Genus declaration-order cleanup is in merged commit `6fb913e`; its
source checks are described in the
[ASIC handoff](../flow/asic/README.md#coding-rules-for-the-genus-front-end).
The simulation, ACT4 and synthesis reference results below belong to the
September 15 checkpoint `a0062b9`, before that cleanup. The September 22
and September 25 hardware results are tied to their bitstream hashes separately.
The 1W2R FP register file was built from `7c2563e`; the element-group
`vkeccak.vi` image from `99078e3` (branch `dev-keccak`).

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

The September 22 reference transfer contained:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `_build/vcu118_ddr.bit` | 80,159,322 | `03eeb088971ef3a19183516ea53675cbaa141b8a935155cd8c80fb403a2e73d2` |
| `_build/vcu118_ddr.ltx` | 1,010 | `b4b1ce76f88f53501ca477b1c9203509a74dfbee529023656c78e5610b58c3f7` |

That bitstream was programmed and accepted on September 22. The current
`_build/vcu118_ddr.bit` is the September 24 build listed below. The standard
UART capture location is `_build/boot.log`.

The September 15 reference reports for `c61da577…ed0da` measured CPU
setup/hold **+0.046/+0.010 ns** at
75 MHz, whole-design **+0.009/+0.010 ns**, all 14 bus-skew constraints PASS,
and zero bitgen DRC errors. Reference utilization is 366,098 LUTs, 86,857
registers, 317.5 BRAM tiles and 29 DSPs. September 22 timing/utilization
reports were not transferred, and neither reference report set is in this
programming bundle. These figures must not be relabelled as new measurements.

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
2026/09/24 20:27. `_build/vcu118_programming.tgz` packs both files; its SHA-256
is `e8c3081005a9dcb96830f524385ce6fa43e5d4e1e696b2d976fe2b05c784eba8`.

Routed timing at 75 MHz, from the build host's
`_build/fpga_rpt/ddr_rva23s64_sgmii_75_rom__*` reports (the programming
transfer contains only the bitstream and `.ltx`):

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
`rva23s64-ddr` netboot one-liner.

### Board validation — 2026-09-25

The programming host verified the bundle hash, programmed `b11d5efb…3b809`
over JTAG with Vivado/hw_server 2025.2.1, and captured UART at
`_build/boot.log`. The bitstream reached DDR calibration, fu-boot,
OpenSBI 1.8.1, U-Boot 2025.01, Linux 7.2.6-zvk and the Debian NFS-root
console. The karudeb agent ran `board_accept.sh` as root and reported PASS.

| Check on the new image | Result |
| --- | --- |
| NFS root, Ethernet, ISA/DT profile leaves | PASS |
| KVM API VM/vCPU creation and run-area mapping | PASS; no guest execution in this check |
| Userspace memory patterns | 256 MiB, three patterns PASS |
| Zvknhk OpenSSL checks | 17 PASS across vector and software backends |
| `vill_probe` | 6/6 PASS |
| Cache-window probe | PASS; fetch 4.42/4.39 cycles per instruction, loads 14.21/14.30 cycles per load inside/outside the former 256 MiB boundary |
| User-only PMU probe | PASS under `board_accept.sh`'s 20% tolerance; x1.16 instruction ratio |
| `fp_probe` | Completed; independent `fmadd.d` 65.883, `fmul.d` 62.715 and `fadd.d` 6.932 cycles/op (best of five) |
| On-board TestFloat-3e | Completed: 36 functions, 0 errors (karudeb `doc/fp-datapath-20260925.md`, `doc/data/testfloat-20260925.txt`) |

The new image is accepted for the FPGA bring-up trial on the completed board
checks. The prior September 22 image's KVM guest tests, 92 OpenSSL known-answer
comparisons and other extended suites remain reference results until repeated
on this hash. The FP probe gives useful timing data but is not a before/after
latency comparison.

The agent's raw acceptance files are under `/root/accept-20260925/` in the
NFS root; the FP and TestFloat transcripts are in its scratchpad. A local
snapshot and the programming log are under `_build/board-results-20260925/`.

## Element-group `vkeccak.vi` image — 2026-10-06

Built from karu64 `99078e3` on branch `dev-keccak` (element-group
`vkeccak.vi`, see the [changelog](../CHANGELOG.md)) with
`flow/with_vivado.sh make vcu118-ddr-sgmii-rom-rva23s64 VIVADO_THREADS=8`,
Vivado 2026.1, on a build host without the board. IP, U-Boot and the ROM were
regenerated by the recipe. Wall clock 1 h 39 min: synthesis 20 min, opt
5 min, placement 31 min, routing 25 min, post-route `phys_opt_design` 35 s,
bitstream 2 min.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `_build/vcu118_ddr.bit` | 80,159,322 | `280853565418fc4874b00a0cbf509f9d47047ebba89c61f2e8bc35c5c91abbd7` |
| `_build/vcu118_ddr.ltx` | 1,010 | `b4b1ce76f88f53501ca477b1c9203509a74dfbee529023656c78e5610b58c3f7` |
| `_build/vcu118_rom_board.dtb` | 2,885 | `d617ba564798245c27343e16c86e5d76ea65ed534cc1dfcd5044f74ab3b0cec9` |
| `_build/vcu118_rom_manifest.txt` | 2,439 | (text; hashes below) |

The bitstream header identifies `vcu118_ddr_top`, `xcvu9p-flga2104-2L-e`,
2026/10/06 21:53. `_build/vcu118_programming.tgz` packs all four files (the
bundle now carries the ROM manifest and the ROM's DTB, produced by
`flow/rom_manifest.py` from the packed ROM image); its SHA-256 is
`1ab661594d407e0914b6118929ab6dec0b6e77ce29b4fb6824d1c72ca957c178`.

Routed timing at 75 MHz, from `_build/fpga_rpt/ddr_rva23s64_sgmii_75_rom__*`:

| Metric | Result |
| --- | --- |
| Whole design setup / hold / pulse width | **+0.007 / +0.011 / +0.005 ns**, 0 failing of 238,391 endpoints |
| `cpu_clk` setup / hold | **+0.244 / +0.011 ns**, 177,906 endpoints |
| Worst-slack endpoints | AXI width-converter to clock-converter FIFO paths inside the Xilinx DDR interconnect IP (`u_cdc` → `u_dwc`), as in the September images |
| Bus skew | 14/14 constraints MET |
| DRC before bitstream | 0 errors |
| Synthesis log | 0 errors; 1 critical warning, the generated `ddr4_0_board.xdc` `BOARD_PART_PIN` line (Xilinx IP, benign, same as September) |
| Utilization | 351,167 LUTs, 87,254 registers, 5,099 LUT-as-memory, 317.5 BRAM tiles, 29 DSPs |

The router finished at −0.261 ns; the flow's automatic post-route
`phys_opt_design` closed it. None of the 100 worst-slack paths involves the
Keccak core, the vector sequencer or the FP register file. Utilization is
1,466 LUTs above the September 24 image.

Constraint coverage was checked on the routed checkpoint because the
out-of-context synthesis of the DDR4 IP prints `extra characters after
close-brace at line 258 of ddr4_0.xdc` (the same message appeared in the
September 24 build). Lines 258 and 259 are two Xilinx-generated hold-only
false paths to the PHY `RIU_ADDR*` / `RIU_WR_DATA*` pins. In the routed
design both are applied: `report_exceptions -coverage` shows 132 and 352
endpoint pins at 100 % coverage, and hold paths to those pins report
`Timing Exception: False Path`. The ignored-exception list (ten
Xilinx-internal reset/synchronizer entries, non-existent or overridden
paths) and the `check_timing` counts are identical to the September 24
checkpoint: 0 unclocked pins, 0 unconstrained internal endpoints, 3 inputs
(`eth_mdio`, UART `cts`/`rxd`) and 11 outputs (DDR reset, MDIO, PHY reset,
LEDs, UART) without I/O delays, all asynchronous or slow pins. The message
is a limitation of the synthesizer's own constraint pass on the IP's
wildcard pin pattern, not a lost constraint.

ROM contents, read back from `_build/vcu118_fuboot.hex` (ROM SHA-256
`77a9e1ce0e678ab3084f3ef5537d53c0e4ee6aa8e8ff9efac2e2c80591c1400b`):

| Offset | Blob | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| `0x10000` | OpenSBI v1.8.1 `fw_jump.bin` | 275,728 | `307ff4379bb146646a0825b510e5f16b664c669e7b24390b381350a5a914fc21` |
| `0x60000` | U-Boot 2025.01, `bootdelay=2` | 513,061 | `c2994f9f5d26b952ebc31c731bc65f0ee5e3d29ddf6dd5077e33390d3028cec8` |
| `0xFC000` | control DTB `karu64-rva23s64-ddr` | 2,885 | `d617ba564798245c27343e16c86e5d76ea65ed534cc1dfcd5044f74ab3b0cec9` |

The DTB reproduces from karudeb `dev-keccak` `b3b6abf` (`dtc` 1.7.2) and
`make karu64-rva23s64-check` there passes 14 tests. The baked boot command
is the lab one-liner: TFTP server `192.168.42.1`, board `192.168.42.10`,
`Image` at `0x80200000` and `board.dtb` at `0x84000000` with three attempts
each, `console=ttyS0,115200 earlycon`, NFS root
`192.168.42.1:/srv/nfs/karudeb,vers=3,tcp,nolock`. The board host must
serve `board.dtb` with the hash above; see
[fpga.md](fpga.md#building-on-one-host-booting-from-another).

Pre-synth gate: the simulation checks recorded in the changelog entry for the
element-group change (line-for-line reference-Spike agreement of
`keccak-test-all`, the Keccak KAT bench and the rewritten firmware). Full
ACT4 was not rerun for this change. Board validation follows.

### Board validation — 2026-10-07

Host side first: the NFS root was restaged with karudeb `ccf5463` (contains
`b3b6abf`; `board_accept.sh`, `openssl-zvknhk`, `xtest`, the ML-KEM/ML-DSA
KAT binaries), `/srv/tftp/board.dtb` was confirmed at
`d617ba56…bcec9` (byte-identical to the ROM's DTB) and `/srv/tftp/Image` at
the unchanged 7.2.6-zvk kernel. The `_build/vcu118_ddr.bit` on the board host
hashed to `28085356…abbd7` and the bundle to `1ab66159…c178`; `git diff
99078e3..fad578f -- rtl/ flow/boot/ flow/fpga/` is empty, so the image
corresponds to the RTL at HEAD.

Programming and boot (console in `_build/boot.log`):

| time | stage |
|---|---|
| 10:48 | `flow/hw_server.sh`; `flow/with_vivado.sh make prog_vcu118_ddr` (Vivado 2025.2.1 lab host, 46 s) |
| 10:49:40 | fu-boot from the ROM; OpenSBI v1.8.1 "karu64 VCU118 DDR RVA23S64 Zvk+Keccak NFS-root"; U-Boot 2025.01 (Oct 06 build) |
| 10:50:05–10:50:45 | three ARP timeouts: the host had lost its `192.168.42.1/24` address; the ROM's three-attempt boot command gave up cleanly at the `=>` prompt instead of booting a partial image |
| 10:51:39 | host address restored by hand (`ip addr replace`), board reset; fu-boot/OpenSBI/U-Boot again |
| 10:52:43 | `Image` 9,077,836 B and `board.dtb` 2,885 B transferred; kernel 7.2.6-zvk started, base ISA `acdfhimv` |
| 10:52:57 | NFS root mounted |
| 10:57:07 | `root@karudeb:~#` |

Results (raw logs under karudeb `doc/data/*-20261007.txt`, write-up in
karudeb `doc/keccak-v02-20261007.md`):

| check | result |
|---|---|
| `board_accept.sh --expect-kernel 7.2.6-zvk --expect-isa …` | PASS, all checks green |
| OpenSSL 4.0.2 `zvknhk_bench --check-only` (SHA3/SHAKE, ML-KEM-768, ML-DSA-65, both `rv64gc_v_zvknhk` and `rv64gc` backends, fingerprints agree) | 17/17 |
| riscv-pqc `xtest` (Zvknhk instruction tests) | 39 vectors, `fail= 0` |
| ML-KEM 512/768/1024 and ML-DSA 44/65/87 reference KATs, two binaries each | 720 PASS, 0 FAIL |
| Encoding conformance (`tools/vkeccak_encodings.sh`, riscv-pqc `edge_probe0`) | 20/20: 7 legal shapes correct with all other registers untouched; 13 reserved shapes trap (`vl` not a multiple of 32, LMUL < m8, unaligned `vd`, `vstart` inside a group, SEW=32, `imm5=2`, `vill`, `vm=0`) |
| FP datapath (informational block of `board_accept.sh`) | within noise of the `b11d5efb` figures |

Benchmarks (same session, karudeb `pqc-bench`/`shake_bench` logs): ML-KEM-768
encaps 3,102,900 cycles (−1.3 % vs 2026-09-15), ML-DSA-65 sign 23,099,727
(−12.2 %, −37 % instructions) with identical `f1600` counts, so the v0.2
software wrapper is leaner than the extra `vsetvli` is expensive.

**Open item for the RTL**: the bare 24-round `vkeccak.vi` with the state
resident in the VRF went from 87.98 to 93.98 cycles (+6.0, 6.8 %) between the
`vl=25` image and this one; the timed loop is identical on both dates
(`vkeccak.vi` + `addi` + `bnez`, `vsetvli` outside). At VLEN=256 there is only
ever one element group, so the group-loop setup has nothing to amortise over.
The two `vl` switches a resident sponge needs per block cost 17.0 cycles
(~8.5 per `vsetvli`); together with the +6 that is the wrapper row's +21.8.

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
