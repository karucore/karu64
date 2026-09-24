# RVA23S64 ASIC source handoff

This handoff covers **top `karu64`**, with RVA23S64, 4 KiB I-cache,
4 KiB data cache, Zvk/Keccak, VLEN=256, ELEN=64, a 128-bit vector bus,
and vector lane/writeback pipelines. This is the maintained processor
configuration for an ASIC flow, not the FPGA DDR/SGMII SoC.

The open-source reference flow is documented in
[the synthesis notes](../syn/README.md),
[area matrix](../syn/AREA_MATRIX.md) and
[architecture](../../doc/architecture.md). Those flows mapped memories to
logic; they do not bind foundry memory-compiler macros. The maintained
reference timing target is 5 ns / 200 MHz. Macro PVT corners, voltage, DFT/repair
options and final timing constraints must come from the target technology
setup; they cannot be inferred from this RTL.

## Files and configuration

| File | Purpose |
| --- | --- |
| [karu64.f](karu64.f) | 54 Verilog source files; paths relative to repository root |
| [karu64.headers](karu64.headers) | Included headers to deliver; add `rtl/` to the include search path |
| [rva23s64.defines](rva23s64.defines) | Required preprocessor definitions, one token per line |
| [sources.tcl](sources.tcl) | Tool-neutral Tcl: absolute `karu_sources`, `karu_include_dirs`, `karu_defines`, `karu_top` |
| [memories.csv](memories.csv) | Every elaborated array, source location and raw access counts |
| [memories.md](memories.md) | Readable inventory |
| [audit.py](audit.py) | Reproduce hierarchy, inventory, initialization checks and source hashes with Yosys |
| [check.py](check.py) | Four-state memory checks and core regressions with randomized startup |
| [lint_decl.py](lint_decl.py) | Declaration-order lint: flags `wire x = expr;` style declaration-assignments, use-before-declare, and undeclared names, per module (exit 1 on findings) |
| [fix_decl.py](fix_decl.py) | Mechanical rewrite for the two lint classes: splits declaration-assignments into `wire x;` + `assign x = expr;` and hoists declarations in front of their first use |

## Coding rules for the Genus front-end

Genus requires every net and variable to be declared before its first use
(port connections included) and does not accept declaration-assignments
(`wire x = expr;`) or variable initialisers (`reg x = 0;`). The manifest is
clean against both rules and `lint_decl.py` keeps it that way:

```sh
python3 flow/asic/lint_decl.py              # the manifest; exit 1 on findings
python3 flow/asic/fix_decl.py               # rewrite the manifest in place
```

The lint treats all `ifdef` branches as present and is exact on this code
base (zero `undeclared` names, its self-check for parser blind spots). The
fixer moves expression text verbatim, keeps every preprocessor line, places a
hoisted declaration in front of any `ifdef` construct that the original was
not inside of, and reports the one shape it does not rewrite (a shared
`wire x =` head with one body per `ifdef` branch). The 2026-09-21 rewrite was
verified equivalent by a per-file Yosys RTLIL diff before/after, strict
`iverilog -g2001` parses in eight configurations, the simulation
regressions, and the Vivado elaboration check. The rebuilt FPGA image
`03eeb088` also passes the September 22 Linux, KVM guest, crypto, vector ABI
and cache checks; forced vector SM4 matches reference and scalar outputs.
See the [board results](../../doc/release-diagnostics-2026-09-14.md#board-acceptance--2026-09-22).

Use the definitions as well as the file list. **`KARU_ASIC` is required** to
exclude FPGA power-up initialization. Do not define `SIM_TB`,
`CORE_COMMIT_LOG`, `KARU_ASSERT_BIND` or FPGA-specific switches for synthesis.
Non-SIM arithmetic defaults are MUL=4, DIV=64; effective double-precision
mantissa multiply/FMA is serial (53 cycles). The manifest explicitly fixes
the integer and vector cycle counts.

Top parameters retain their RTL defaults: `RESET_PC=0x80000000`,
`RESET_SP=0x80010000`, `EXT_TIME=0`. These are reset/interface choices, not
power-up initialization. A Linux SoC with an external timer normally sets
`EXT_TIME=1` and drives `time_in`; this does not change memory geometry.
All memory writes use the rising edge of **`karu64.clk`**. Architectural
control state requires active-high synchronous `rst`.

The list excludes testbenches, assertions, CLINT/PLIC peripherals, FPGA top,
boot ROM, MIG/DDR controller, Ethernet/SGMII, clock/reset primitives and debug
IP. `karu_vrf_bram` is generic RTL despite its name. Some optional crypto
source modules elaborate away. The external system RAM/ROM, timer and
interrupt-controller implementation belong to ASIC SoC integration, outside
this processor inventory.

`sources.tcl` supplies variables for the site's Genus script. It does not
load technology libraries or run Cadence. The manifest was elaborated with
Yosys; Cadence execution and compiler-macro binding have not been performed.

## Memory-compiler request

Sizes are **width in bits × depth in words**, before technology padding,
width splitting or replication. Append `.mem` to wrapper paths below to
identify their arrays; scalar/FP and scratch paths already name arrays.
These 15 data arrays total **97,024 logical bits**, excluding control
registers and constant lookup logic. All ASIC data arrays are uninitialized.

The September 14 release audit with Yosys 0.69+24 confirms the same geometry
and interfaces: nine macro candidates, two register files and four scratch
arrays; 33 control arrays and 14 constant lookup arrays are separate. No
initialized state is present. The checked-in CSV/Markdown inventory matches
that elaboration. Exact source hashes and reports are produced in the standard
`_build/asic-audit/` location. This is an inventory/initialization audit, not a
memory-macro area or timing estimate.

| Path from top | Width × depth | Current logical interface | Write mask |
| --- | ---: | --- | --- |
| `karu64.vrf.u_bram.mem_u` | 128 × 64 | TDP, two independent RW ports, synchronous reads | 16 byte enables on **each** port |
| `karu64.dmem_l1.line_data_u` | 512 × 64 | 1W1R, asynchronous read; parent ties addresses | None; full 512-bit write |
| `karu64.dmem_l1.line_tag_u` | 20 × 64 | 1W1R, asynchronous read; parent ties addresses | None |
| `karu64.icache.cdata_u` | 64 × 512 | 1W1R, asynchronous read, separate addresses | None |
| `karu64.icache.ctag_u` | 20 × 64 | 1W1R, asynchronous read, separate addresses | None |
| `karu64.immu.pwc_data_u` | 512 × 4 | 1W1R, asynchronous read | None |
| `karu64.dmmu.pwc_data_u` | 512 × 4 | 1W1R, asynchronous read | None |
| `karu64.varith_u.pram_u` | 64 × 32 | 1W2R, two asynchronous read addresses | None |
| `karu64.varith_u.iram_u` | 64 × 32 | 1W2R, two asynchronous read addresses | None |
| `karu64.rf.rx` | 64 × 32 | 1W2R register file, asynchronous reads | None; x0 writes suppressed/reads zero |
| `karu64.frf.fx` | 64 × 32 | 1W2R register file, asynchronous reads; port B time-shared for FMA rs3 | None; f0 is writable |
| `karu64.vlsu.buf_u.membuf` | 128 × 18 | Multi-read scratch, one full-word write | None |
| `karu64.vlsu.buf_u.regbuf` | 128 × 16 | Multi-read scratch, one full-word write | None |
| `karu64.vlsu.buf_u.pib` | 8 × 256 | Byte-addressed multi-access scratch | 16 consecutive bytes written together |
| `karu64.vlsu.buf_u.peb` | 8 × 256 | Byte-addressed multi-access scratch | 16-byte granule or up-to-8-byte element writes |

### Port semantics and mapping limits

- **VRF:** A/B each have independent enable, write enable, address and mask.
  A read captures data on the rising edge. An inactive or writing port holds
  its previous output (`NO_CHANGE`). No array/output reset is required.
  The protocol checker prohibits same-address cross-port R/W and W/W
  collisions, including disjoint-byte writes. Preserve that controller
  invariant when binding the macro; no defined macro collision result is
  needed under it. The generic model's pre-write cross-port read value is
  not relied upon by the controller. Byte enables are active high in the
  wrapper; no sub-byte mask is needed. Bit-enable macro pins can be driven in
  groups of eight. Preserve output hold if the macro updates outputs on writes.
- **Async wrappers:** full-word rising-edge writes, combinational reads with
  no read enable or output register. A same-address read reflects new data
  after the write edge. **Synchronous SP/SDP macros are not drop-in replacements.**
  Use a suitable async-read/register-file option or change the controller
  timing explicitly. D-cache stores already merge bytes into the old 512-bit
  line in logic; the leaf needs no byte mask. Parent address sharing does not
  remove this read-modify-write timing requirement.
- **Permutation buffers:** two independent async reads; writes occur in the
  load phase and reads in compute phases. Two replicated 1W1R memories with
  broadcast writes are one option if 1W2R is unavailable, doubling storage.
  A one-read-port SP macro alone cannot preserve this interface.
- **Scalar/FP RF:** retain flops or use compiled RFs with the stated async
  read ports; both files are 1W2R (the FP file reads FMA rs3 on port B during
  the issue window, so no third port is needed). No combinational
  write-through bypass is present. The rs3 steer adds one same-cycle path,
  `ex_rs3` register -> 5-bit address mux -> asynchronous FP RF read -> FMA
  stage-1 unpack, that STA must cover with the compiled macro's actual
  address-to-data delay; the mapped-to-logic reference flows do not model it. Preserve x0 handling externally; only 31 integer words hold
  useful state, though the declared address space is 32 words.
- **VLSU scratch:** retain flops for initial integration unless deliberately
  refactored. `membuf`/`regbuf` each have 16 raw word-read expressions that
  assemble a 16-byte window spanning at most two adjacent 128-bit words.
  `pib` has eight byte-read and sixteen byte-write expressions; `peb` has
  32 read and 24 write expressions before optimization. These are access
  sites, **not physical macro port counts**. Byte banking and address sharing
  can reduce ports, but that redesign is not supplied here. Element writes
  take priority over granule writes to the same `peb` byte. Selective writes
  preserve other bytes. The 18-word `membuf` includes misalignment slack.

No leaf requests ECC, parity, sleep/retention pins, redundancy repair, MBIST,
or independent clock domains. Physical/DFT requirements need integration
outside these interfaces. No Arm-specific macro names or pin polarity are
assumed. Width splitting/depth padding must preserve timing and semantics.
The VRF **64-word × 128-bit, 2RW, byte-mask** request is concrete. Ask whether
the compiler supports async reads before generating cache macros; four-word
PWC arrays and small tags may be more practical as flops.

## Other arrays: retain as logic/registers

The CSV lists all 33 additional inferred control arrays individually:

| Hierarchy (each listed instance) | Arrays: width × depth | Access requirements |
| --- | --- | --- |
| `karu64.immu`, `karu64.dmmu` | `tlb_vpn` 27×4, `tlb_ppn` 44×4, `tlb_perm` 8×4, `tlb_level` 2×4, `tlb_pbmt` 2×4, `tlb_asid` 16×4, `tlb_root` 44×4 | Associative tag/context comparison plus selected data reads and refill writes; validity reset separately |
| `karu64.immu`, `karu64.dmmu` | `gtlb_vpn` 29×4, `gtlb_hppn` 44×4, `gtlb_gppn` 44×4, `gtlb_vsperm` 8×4, `gtlb_gperm` 8×4, `gtlb_vspbmt` 2×4, `gtlb_gpbmt` 2×4 | Guest TLB parallel compare/selected data; refill writes; validity/context reset separately |
| `karu64.immu`, `karu64.dmmu` | `pwc_tag` 52×4 | Four parallel tag comparisons, one refill write; validity reset separately |
| `karu64.csr` | `csr_hpmcounter` 64×29 | All counters can increment each cycle; CSR access and synchronous reset |
| `karu64.csr` | `csr_mhpmevent` 64×29 | Parallel event/filter decode and overflow-bit updates; CSR access and synchronous reset |
| `karu64.csr` | `csr_hstateen` 64×4 | Parallel permission decode; CSR access and synchronous reset |

Array-shaped pipeline state is not addressable RAM. In `karu64.varith_u`,
`ms_count_q` (5×8) and `ms_first_q` (4×8) are parallel registers. In each
`karu64.varith_u.g_lane[0/1].u_lane`, `auP`, `buP`, `asP`, `bsP`, `shP`
(each 64×8), `egP` (32×8) and `actP` (1×8) are pipeline banks lowered to
individual flops before memory collection. Reduction trees and crypto
temporary arrays are combinational, not RAM. Packed registers such as the
256-bit `karu64.vrf.u_bram.v0_q`, valid vectors, line-fill buffers, guest
context and Keccak state also remain ordinary flops.

The inventory includes 14 constant tables from FLI values,
reciprocal/rsqrt estimates, Keccak LFSR seeds and AES/SM4 constants. These
originate in combinational case/functions, not `initial` or `$readmem*`.
Implement them as logic. The audit replaces Yosys' unstable `$auto$...` names
with the elaborated instance path, RTL source span, a short content digest and
an occurrence index. They need no startup load/reset and are not SRAM compiler
requests.

CSV `raw_read_accesses` / `raw_write_accesses` are pre-mapping access sites,
not compiler port requirements. In particular, the VRF shows 32 writes
because its two byte-enable loops each emit 16 byte slices. Its read flops
remain outside the collected array, so the raw read-clock mask is zero;
the wrapper interface still has one-cycle synchronous reads. The logical
contracts in the table above take precedence over these raw counts.
The audit uses Yosys [memory collection](https://yosyshq.readthedocs.io/projects/yosys/en/v0.54/cmd/memory_collect.html)
without mapping RAMs or changing their latency.

## Initialization sweep

Six storage-initializer locations and one declaration initializer were found:

| Source | Original power-up assignment | ASIC treatment |
| --- | --- | --- |
| `karu_ram_prim.v`, `karu_tdp_be_ram` | Array and both read outputs zero | Excluded by `KARU_ASIC`; FPGA RAM-style attribute also excluded |
| Same file, `karu_1w1r_async_ram` | Array zero | Excluded by `KARU_ASIC` |
| Same file, `karu_1w2r_async_ram` | Array zero | Excluded by `KARU_ASIC` |
| `karu_regfile.v` | Integer RF zero | Excluded by `KARU_ASIC`; x0 remains hard-wired |
| `karu_fregfile.v` | FP RF zero | Excluded by `KARU_ASIC` |
| `karu_vrf_bram.v` | `v0_q` zero | Excluded by `KARU_ASIC`, together with VRF initialization |
| `karu64.v` | Output declaration `trap = 0` | Removed; existing synchronous reset supplies zero |

The guarded values remain for existing FPGA/simulation builds. ASIC data
starts unspecified: software must write it before depending on it, including
v0 before use as a mask. VRF and shadow retain data together across soft
reset; resetting only the shadow would break coherence with retained VRF data.

Remaining `initial` occurrences are simulation-only geometry checks in
`karu_varith.v`/`karu_vlsu.v`, excluded `CORE_COMMIT_LOG` diagnostics, or
testbench/assertion files outside this manifest. RAM assertion declaration
initializers are within `synthesis translate_off`. Crypto comments saying
“initial assignments” describe combinational defaults. Constants, parameters
and synchronous reset values are intentional, not power-up initialization.

The audit checks elaborated RTLIL **before optimization** for initial
processes/attributes/memory initialization cells, then checks collected RAM
INIT values and net initializers. Result: **zero initialized state** for
this ASIC manifest. Constant lookup logic is separate. Repeat equivalent
checks in Cadence after integrating technology wrappers/models; this does
not establish DFT readiness or prove all software avoids uninitialized reads.

## Reproduce

```sh
python3 flow/asic/audit.py
```

Outputs in `_build/asic-audit/` include RTLIL, memory JSON, CSV/Markdown,
summary, tool version and source SHA-256 manifest. The command fails on
initialized state. Use a fresh `--out` directory when preserving a prior audit.
The checked-in inventory is a snapshot; regenerate after RTL/define changes.

The four-state memory test checks unspecified startup, x0, explicit writes,
VRF byte enables, output hold and soft-reset retention:

```sh
iverilog -g2012 -DKARU_ASIC -Irtl -s tb_asic_mem \
  -o _build/asic-audit/tb_asic_mem.vvp \
  rtl/karu_ram_prim.v rtl/karu_vrf_bram.v rtl/karu_vrf_assert.sv \
  rtl/karu_regfile.v rtl/karu_fregfile.v test/tb_asic_mem.sv
vvp _build/asic-audit/tb_asic_mem.vvp
```

The HTIF testbench now ignores `trap` during reset. Sampling before the
first reset edge incorrectly interpreted random ASIC startup as a processor
failure. The testbench is excluded from the synthesis file list.

The passive VRF checker tracks which bytes have been written in ASIC mode,
instead of assuming unwritten storage and its independent shadow both start
zero. Checks of written bytes, readback, mask coherence and collisions remain
enabled. Two deliberately corrupted written-byte cases verify that the
checker still detects failures. FPGA-mode checks retain their initial-zero
expectations; the existing `make vrf-bram-test` passes.

Run the complete focused startup regression with:

```sh
python3 flow/asic/check.py
```

Recorded results: four-state memory/checker test PASS; VRESV **131/131**,
VPERM **41/41**, VSTART **10/10** each pass with randomized startup seeds
1 and 42 and protocol assertions enabled. The model uses the ASIC manifest
plus explicit non-SIM arithmetic defaults; changing flags selects a different
build directory. Logs are under `_build/asic-check/`. The initialization audit
also detects the expected initializers when `KARU_ASIC` is omitted, providing
a negative control. These are RTL checks, not a Cadence timing or macro-model
equivalence result.
