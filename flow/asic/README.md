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
regressions, and the Vivado elaboration check. The Genus-cleanup FPGA image
`03eeb088` passed the September 22 Linux, KVM guest, crypto, vector ABI
and cache checks; forced vector SM4 matched reference and scalar outputs.
The later 1W2R FP image `b11d5efb` closes FPGA routed timing and passes
September 25 board acceptance and the FP probe. See the
[image-specific board results](../../doc/release-diagnostics-2026-09-14.md).

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

Optional external debug has a separate combined top, `karudbg_top`, and
source manifest [dbg/karudbg.f](../../dbg/karudbg.f), enabled explicitly with
`KARU_DBG` and include paths `rtl/` and `dbg/`. It does not change this
processor-only manifest's scope. The DM/ROM/DTM origins, licenses, clocks,
reset domains, protection contract and acceptance gates are in
[dbg/README.md](../../dbg/README.md). `NONSECURE` defaults to 1; integrations
must preserve AXI attributes and use the documented cacheability restrictions
before treating an external firewall as a security boundary.
The combined top keeps core/DM reset synchronous and conditions asynchronous
JTAG reset release over two TCK edges. Its `IDCODE` parameter must be set to
the assigned platform identity; the default is a simulation placeholder.
The October 29 full-extension audit reports zero initialized state and the
same 97,024 data-array bits: nine macro candidates, two 1W2R register files
and four scratch arrays. Core-only/base-debug/full-debug control-array counts
are 33/34/37; constant lookup arrays remain 14. The extra three full-debug
arrays are trigger address, control and precomputed NAPOT masks, each 64×2
(384 logical bits together, or 768 with four slots). These small parallel
control arrays belong in flops. They add no ports or geometry changes to
RF/cache/VRF macros. See `_build/dbg/asic-audit-full/` for the exact defines,
source hashes, elaborated RTLIL and generated inventory.

The [karudbg extension plan](../../dbg/README.md#extension-implementation-and-testing-plan)
tracks auto-execution, hardware address triggers and SBA for the single-hart
ASIC, with separate FPGA validation. It covers the portable bus/clock/reset
contract, cache coherence, four-state startup, macro-interface preservation,
CDC/RDC, timing and DFT integration. The extension RTL is independently selectable
and includes the [implemented trigger contract](../../dbg/TRIGGERS.md).
The earlier measurements above describe the base debug implementation; consult
the current combined validation/measurement record before quoting extension
costs. Multi-hart support is excluded.
The [fixed E0 decisions](../../dbg/README.md#fixed-e0-decisions) select
debugger-owned triggers, post-pointer-masking
address comparison, explicit FF watchpoint entry, and reuse of whole-cache
flush/refill-poison logic for SBA coherence. Writes to DRAM and executable
scratch SRAM (`0x00201000..0x00210fff`) use a hardware issue/drain and
fetch-resynchronization handshake, without Program Buffer execution. The
issue hold is registered; RAM-write acceptance requires that hold and quiet,
including any instruction admitted on the hold's assertion edge. This breaks
reset-gated request VALID's combinational path into trigger/issue control;
request suppression during reset remains active. Scratch
also needs maintenance because its instructions can be prefetched. For a
custom physical map, override `sba_ram` through
`KARU_DBG_SBA_RAM_HEADER` to cover its writable cacheable and executable regions;
the default classifier is not inferred from `KARU_PMA_CUSTOM_HEADER`. After the
write response, the core pulses platform `cache_flush_req` with
`cache_flush_invalidate=1` and samples `cache_flush_done` after the request
clock before acknowledging SBA completion or releasing the issue hold. An
idle-high done value on the request edge is ignored. After the request,
acknowledgement is latched even while a prefetch is active; SBA completion
still waits for the core to become quiet. A platform without
additional maintenance may tie done high. An outer data cache must share the
coherent core/SBA path, or add pre-write coordination; maintenance must preserve
dirty data. Account for the cache-loss/stall cost. The common
hart/fabric reset must reset affected responders and cancel pending external
maintenance together. A nonresponding older access, an accepted SBA access
without a response, or a missing maintenance acknowledgement can retain the
hold indefinitely; no implicit timeout discards ownership.
The vector trigger query registers a 64-bit post-masking address before its
comparator, with one extra cycle per armed field and no change to the disabled
path or any memory macro port. The payload has no reset and is qualified by
its sequencing state. Four-state capture checks and a stale-address negative
control exercise that contract. The full-debug CPU replay passes 2872/2872
preserved ACT4 ELFs, and 16 ordinary subjects have zero idle cycle delta;
the combined functional gate also passes with 274 unchanged input hashes.
All twelve mapped comparisons completed at the October 29 checkpoint. The
October 30 registered-pause follow-up restores full two-trigger input-to-register
slack to +0.2328 ns; register WNS remains −0.3978 ns, so 200 MHz is still open.
Other timing and area rows retain the October 29 source. See the
[current timing scope](../../dbg/MEASUREMENTS.md#registered-sba-pause--2026-10-30).
Technology-specific physical signoff has its own acceptance gate.

For the combined ASIC top, source [dbg/sources.tcl](../../dbg/sources.tcl)
to obtain the maintained absolute source paths, both include directories,
`KARU_ASIC` profile defines and `karu_top=karudbg_top`. It selects base debug;
append `KARU_DBG_FULL` to `karu_defines` for all extensions, or append the
individual `KARU_DBG_AUTOEXEC`, `KARU_DBG_TRIGGERS`, `KARU_DBG_SBA` defines.
Use `KARU_DBG_TRIGGER_COUNT=4` only with the trigger feature enabled. Do not
substitute FPGA source lists or remove `KARU_ASIC` for this top.

The extensions introduce no additional clock domain: trigger, autoexec, SBA
and maintenance state use `clk`; the existing TAP/DTM uses `tck`. The exposed
AXI interface is synchronous to `clk`. A different fabric clock requires an
explicit CDC bridge preserving transaction ownership and reset cancellation.
Keep the common core/DM/SBA clock active during debug, including while halted.
RAM coherence requires core clock edges; any future core clock gate must wake
for maintenance before acknowledging completion. Halting instruction retirement
does not require stopping that clock.

Use [dbg/karudbg.sdc.in](../../dbg/karudbg.sdc.in) as the conventional-top
clock/reset/CDC timing template. Synchronous `rst` remains timed against
`clk`, including new reset fanout. Exceptions cover only first-stage control
synchronizers and external-reset ingress to TCK asynchronous reset pins;
reset-release recovery/removal paths and bounded bundled-data paths remain
timed. `ndmreset` resets the hart, arbiter and affected fabric responders
together, preserving the DM; a transport reset preserves accepted commands and
SBA work. Foundry RDC/CDC analysis must check those ownership and release
contracts rather than applying blanket clock-group or reset cuts.

Scan insertion and clock-gating cells are SoC integration work. Quiesce the
DMI/bus protocol around scan, provide the required test clocks and reset
control, retain synchronizer identification, and re-establish protocol reset
before functional execution. The generic RTL/constraints do not establish
scan coverage, ATPG, a foundry macro binding, PVT timing or silicon CDC/RDC
signoff. `NONSECURE` and `SBA_ENABLE` are trusted static integration parameters;
`SBA_ENABLE=0` also removes SBA discovery/capabilities and launch state from the
DM (all SBA registers read zero), while retaining the bus-side deny gate and
ordinary core/Program Buffer operation.
Default builds have no debug authentication. The opt-in `KARU_DBG_AUTH`
scheme and what it requires from the SoC are described next.

### Debug authentication obligations (`KARU_DBG_AUTH`)

`KARU_DBG_AUTH` gates debug by a lifecycle input and lets a boot ROM grant it
once per power-on reset. The design is in the
[plan](../../doc/debug-auth-plan.md), the interface in the
[contract](../../doc/debug-auth-contract.md) and the open finding in the
[review](../../doc/security-review-2026-11-15.md) (S6). It is not
production-ready: there is no production signature verifier, and the formal
and simulation milestones are partial. The RTL assumes all of the following;
none is checked by the generic flow.

| Obligation | What the SoC must provide |
| --- | --- |
| Island ROM | A real ROM macro for `[AUTH_ROM_BASE, AUTH_ROM_END)`, 64 KB by default, holding the window code. `RESET_PC` and the reset `mtvec` must lie inside it (prior finding S4). The RTL array is a simulation model |
| Island SRAM | An SRAM macro, 16 KB by default, reachable only through the island. It is deliberately not reset and keeps its contents across hart and system resets, so the ROM must not leave secrets in it, or must scrub it (plan D1) |
| Island response paths | Nothing outside `karudbg_core` may drive the island's memories or their responses. No other bus manager, test wrapper or repair logic may reach them |
| Verification key | The public key or its hash in OTP or ROM, read only through the island |
| Lifecycle `lc_i` | A two-bit value from OTP or a lifecycle controller, stable from power-on reset and sampled in the reset cycle. `0` is `OPEN`, `1` is `AUTH`, `2` and `3` are `DISABLED`. Its integrity is assumed; an attacker who can change it owns debug |
| Power-on reset | `rst` of `karudbg_top` must be a true power-on reset. It is the only reset that clears the grant, `boot_done`, the firmware lock and revocation. System and hart resets must use `hart_reset_i` |
| Reset fan-out | `auth_reset_o` (boot hold and relock) joins the hart-side reset inside `karudbg_core`; fabric responders that share the hart reset must follow it, as for `ndmreset` |
| Boot-hold strap `hold_strap_i` | A physical-presence input sampled at power-on reset. It only delays boot in `AUTH`. It is treated as adversary-controlled and grants nothing by itself |
| Revocation `revoke_i` | Optional trusted input; tie low if unused. Once high it disables debug until power-on reset |
| TRNG port | A health-checked entropy source on `trng_opst_i`, `trng_data_i` and `trng_ack_o`, with the Zkr `seed` status encoding. The nonce is only as good as this source |
| Scan and DFT | The scan controller must force `debug_enable` low and reset `karudbg_auth` on scan entry and exit (plan D6). Scan access to the grant, the mailbox or the island SRAM is outside the proof |
| ROM software | The obligations of plan §6: interrupts off, trap vector in ROM, fresh nonce, fixed-size parsing, constant-time verification, a fault-resistant decision. The simulation ROM under `test/dbg/auth_rom/` does not meet them and must not be shipped; its `TEST` algorithm (`0x80`) must be rejected by a production ROM |
| Window deadline | The ROM's `WINDOW_CYCLES` limit is a software cutoff with an implementation-dependent tolerance. A hard cutoff needs a worst-case margin in the ROM or a hardware timer (contract §5.3) |

Mapped size, from [measurements](../../dbg/MEASUREMENTS.md): the
authentication logic is an estimated 21.9 kGE on top of full debug, partly
derived from a reduced-memory probe. The two island memories are not costed,
and no run used ASIC memory macros. At 200 MHz the authentication netlist's
worst path is the existing fetch-to-FMA path; authentication adds no new
critical path, and the 200 MHz goal itself is still unmet.

Fault injection, glitching, probing and side channels are outside the claim.
An FPGA is never the security target, because its configuration port can
replace the design.

`make dbg-config-matrix-test` checks off/base/each/full/four-slot configurations
using strict Verilog-2001 parsing and Verilator, with preprocessed sources,
defines and manifests under `_build/dbg/config-matrix/`. It rejects leaked
debug ports in the disabled core and FPGA primitives in the conventional ASIC
sources. `make dbg-asic-random-test` reuses one full-profile `KARU_ASIC` model
for six randomized startup seeds; four-state checks remain separate. The
constraints' executable scope regression is
`make dbg-ooc-reset-constraints-test`; it checks the Tcl contract, not physical
timing or technology-specific CDC selection.

`sources.tcl` supplies variables for the site's Genus script. It does not
load technology libraries or run Cadence. The manifest was elaborated with
Yosys; Cadence execution and compiler-macro binding have not been performed.

### Entropy source obligations (`KARU_ZKR`)

`KARU_ZKR` is opt-in and is not part of `flow/asic/karu64.f`: the core then
has the `seed`, `mseccfg`, `mnoise` and `mentropycfg` CSRs and expects an
entropy source on its `zkr_*` ports. An ASIC that enables it must provide:

- **A noise source.** `flow/fpga/karu_rosc_rng.v` is for FPGA only: its
  rings are LUT loops kept by Vivado attributes. The replacement connects
  through the same raw interface (`rng_en`, `rng_fips`, a one-cycle
  `rng_val`, four `rng_b` lanes, no back-pressure), which is the one
  OpenTitan's entropy block expects from its analog sensor top.
- **`rtl/karu_entropy.v` unchanged in front of it**, so that the bits the
  health tests see, the bits `seed` delivers and the bits the GetNoise
  interface shows stay the same bits. Add `rtl/karu_entropy.v` to the file
  list.
- **Parameters from an assessment.** The reset interval, its floor
  (`INTERVAL_MIN`) and the health-test cutoffs and their ceilings
  (`RCT_MAX`, `APT_MAX`) are provisional. They have to come from raw data
  of the actual source, fitted per lane to the stochastic model and
  checked for dependence between lanes.
- **A policy for the test interface.** `mnoise` gives M-mode raw samples
  and holds `seed` in `BIST` meanwhile. Firmware should set the lock bit of
  `mentropycfg` before leaving M-mode; a production device may want the
  interface tied off.
- **A power-on reset value for the platform strap** (`en_i`), and, as for
  the debug block, scan must not expose or drive the source.
- **No path from the written value back to the read value.** A CSR set or
  clear instruction computes the value it writes from the value it reads,
  so `zkr_wdata_o` depends combinationally on `zkr_rdata_i` inside the core
  (about 0.5 ns in the 200 MHz mapping). Whatever sits behind the ports
  must not let the value it returns depend on `zkr_wdata_o`, `zkr_we_o` or
  `zkr_fire_o` in the same cycle. `rtl/karu_entropy.v` keeps to that, and
  `make zkr-loop-test` checks it; the first FPGA build of the block did
  not, and was refused for the loop.
- **Registered noise inputs.** In `rtl/karu_entropy.v` the incoming symbol
  reaches the value read from `seed` combinationally: a health-test
  failure in the cycle of a read wins over the read. `rng_val` and `rng_b`
  should therefore come from registers, as they do in the FPGA source.

*Estimates, 2026-11-18* (NanGate45 typical, the flow of
[the measurements](../../dbg/MEASUREMENTS.md#mapped-area-and-200-mhz-timing--2026-11-18)):
`karu_entropy` alone is 4.99 kGE in the area mapping and meets 200 MHz
with +0.95 ns on its tightest path, the one from the incoming symbol to
the read value. The CSR-side logic in the core is below the resolution of
the area mapping. `zkr_fire_o` has to wait for the decision that the
access takes effect. On the bare core it has +1.34 ns against the generic
output budget of that flow; in the top with full debug and authentication,
where that decision also passes through the trigger logic, it misses the
budget by 0.19 ns, and the authentication block's `trng_ack_o` misses it by
0.23 to 0.29 ns for the same reason. An integration should give these
strobes a budget of their own or place their consumers next to the CSR
file.

## Memory-compiler request

Sizes are **width in bits × depth in words**, before technology padding,
width splitting or replication. Append `.mem` to wrapper paths below to
identify their arrays; scalar/FP and scratch paths already name arrays.
These 15 data arrays total **97,024 logical bits**, excluding control
registers and constant lookup logic. All ASIC data arrays are uninitialized.

The October 9 audit with Yosys 0.69+24 confirms the same geometry
and interfaces: nine macro candidates, two register files and four scratch
arrays; 33 control arrays and 14 constant lookup arrays are separate. No
initialized state is present. The checked-in CSV/Markdown inventory matches
that elaboration. Exact source hashes and reports are produced in the standard
`_build/asic-audit/` location. This is an inventory/initialization audit, not a
memory-macro area or timing estimate.

The current Arm compiler available for the trial produces **1RW or 2RW**
macros: every port can read or write, and read data arrives after a clock
edge. Its RAMs need at least 32 words; confirm the RF compiler's geometry
separately. The port counts below describe the *RTL's logical accesses*.
They are not requests for 1R1W or 1W2R compiler variants. A row labelled
"2RW + retime" needs a controller/pipeline change for the synchronous read;
it cannot be rebound by changing only the memory leaf.

| Path from top | Width × depth | Current RTL access/timing | 1/2RW compiler fit | Write mask |
| --- | ---: | --- | --- | --- |
| `karu64.vrf.u_bram.mem_u` | 128 × 64 | 2 RW, synchronous reads | 2RW candidate; check masks and output hold | 16 byte enables on **each** port |
| `karu64.dmem_l1.line_data_u` | 512 × 64 | 1W1R, asynchronous read; parent ties addresses | 2RW for concurrent read/write + retime | None; full 512-bit write |
| `karu64.dmem_l1.line_tag_u` | 20 × 64 | 1W1R, asynchronous read; parent ties addresses | 2RW for concurrent read/write + retime | None |
| `karu64.icache.cdata_u` | 64 × 512 | 1W1R, asynchronous read; separate addresses | 2RW for concurrent read/write + retime | None |
| `karu64.icache.ctag_u` | 20 × 64 | 1W1R, asynchronous read; separate addresses | 2RW for concurrent read/write + retime | None |
| `karu64.immu.pwc_data_u` | 512 × 4 | 1W1R, asynchronous read | 2RW + retime; pad 4 → 32 words or retain flop logic | None |
| `karu64.dmmu.pwc_data_u` | 512 × 4 | 1W1R, asynchronous read | 2RW + retime; pad 4 → 32 words or retain flop logic | None |
| `karu64.varith_u.pram_u` | 64 × 32 | 1W2R, asynchronous reads | No direct fit; flop logic or two replicated 2RW macros + retime | None |
| `karu64.varith_u.iram_u` | 64 × 32 | 1W2R, asynchronous reads | No direct fit; flop logic or two replicated 2RW macros + retime | None |
| `karu64.rf.rx` | 64 × 32 | 1W2R, asynchronous reads | No direct fit; flop logic or two replicated 2RW macros + retime | None; x0 writes suppressed/reads zero |
| `karu64.frf.fx` | 64 × 32 | 1W2R, asynchronous reads; port B also reads FMA rs3 | No direct fit; flop logic or two replicated 2RW macros + retime | None; f0 is writable |
| `karu64.vlsu.buf_u.membuf` | 128 × 18 | Multi-read combinational scratch; one write | No direct fit; flop logic or banked/replicated 1/2RW redesign; pad 18 → 32 | None |
| `karu64.vlsu.buf_u.regbuf` | 128 × 16 | Multi-read combinational scratch; one write | No direct fit; flop logic or banked/replicated 1/2RW redesign; pad 16 → 32 | None |
| `karu64.vlsu.buf_u.pib` | 8 × 256 | Byte-addressed multi-access scratch | No direct fit; flop logic or banked/replicated 1/2RW redesign | 16 consecutive bytes written together |
| `karu64.vlsu.buf_u.peb` | 8 × 256 | Byte-addressed multi-access scratch | No direct fit; flop logic or banked/replicated 1/2RW redesign | 16-byte granule or up-to-8-byte element writes |

The leaf RAM definitions are in [karu_ram_prim.v](../../rtl/karu_ram_prim.v).
Instantiation sites are [karu_mem.v](../../rtl/karu_mem.v) (D-cache),
[karu_icache.v](../../rtl/karu_icache.v),
[karu_sv39.v](../../rtl/karu_sv39.v) (PWC),
[karu_varith.v](../../rtl/karu_varith.v) (permutation buffers), and
[karu_vrf_bram.v](../../rtl/karu_vrf_bram.v) (VRF). Scalar/FP register files
are instantiated in [karu64.v](../../rtl/karu64.v) and defined in
[karu_regfile.v](../../rtl/karu_regfile.v) and
[karu_fregfile.v](../../rtl/karu_fregfile.v); VLSU scratch arrays are declared
in [karu_vlsu_buf.v](../../rtl/karu_vlsu_buf.v).

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
- **Asynchronous-read wrappers:** full-word rising-edge writes, combinational
  reads with no read enable or output register. A same-address read reflects
  new data after the write edge. The available 1RW/2RW macros cannot replace
  these leaves directly. A simultaneous read and write needs two RW ports;
  the controller must also issue the read address a cycle earlier or otherwise
  absorb the registered-read latency, including stalls and read-after-write
  behavior. D-cache stores already merge bytes into the old 512-bit line in
  logic; the leaf needs no byte mask. Parent address sharing does not remove
  this read-modify-write timing requirement.
- **Permutation buffers:** two independent combinational reads; writes occur
  in the load phase and reads in compute phases. Two replicated 2RW macros
  with broadcast writes can supply the three logical accesses, at twice the
  storage cost, but still require a registered-read timing redesign. Time
  multiplexing is possible only if the access schedule permits it.
- **Scalar/FP RF:** both files have one write and two combinational read
  accesses (the FP file reads FMA rs3 on port B during the issue window, so
  no third port is needed). The available synchronous macros do not implement
  that timing. Retaining the files as flop-and-mux logic preserves it; using
  two replicated 2RW macros with broadcast writes additionally requires an
  operand-pipeline redesign. No combinational write-through bypass is
  present. The current rs3 path is `ex_rs3` register -> 5-bit address mux ->
  combinational FP RF read -> FMA stage-1 unpack. Preserve x0 handling
  externally; only 31 integer words hold useful state, though the declared
  address space is 32 words.
- **VLSU scratch:** “retain flops” means synthesize the RTL arrays as standard
  cell flip-flops plus combinational read muxes and write decode, retaining
  current access timing rather than binding them to SRAM. This costs area and
  power. `membuf`/`regbuf` each have 16 raw word-read expressions that
  assemble a 16-byte window spanning at most two adjacent 128-bit words.
  `pib` has eight byte-read and sixteen byte-write expressions; `peb` has
  32 read and 24 write expressions before optimization. These are access
  sites, **not physical macro port counts**. A TCDM-style banked scratchpad
  built from 1RW/2RW macros is plausible, but needs explicit banking,
  arbitration, byte-write handling and registered-read scheduling. That
  redesign is not supplied here. Element writes
  take priority over granule writes to the same `peb` byte. Selective writes
  preserve other bytes. The 18-word `membuf` includes misalignment slack.

No leaf requests ECC, parity, sleep/retention pins, redundancy repair, MBIST,
or independent clock domains. Physical/DFT requirements need integration
outside these interfaces. No Arm-specific macro names or pin polarity are
assumed. Width splitting/depth padding must preserve timing and semantics.
The VRF **64-word × 128-bit, 2RW, byte-mask** request is the only direct
port/timing candidate, subject to checking the compiler's byte enables and
output-hold behavior. Other arrays need RTL timing/port changes or flop logic
before their macro specifications can be finalized. Four-word PWC arrays need
padding to 32 words if implemented in these RAM macros; flops may be simpler.

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

The default audit remains core-only. Audit the opt-in combined debug top
separately, retaining the standard ASIC profile defines and adding `KARU_DBG`:

```sh
python3 flow/asic/audit.py --manifest dbg/karudbg.f --top karudbg_top \
  --define KARU_DBG --out _build/dbg/asic-audit-combined
```

For the full extensions, add `--define KARU_DBG_FULL` and use
`--out _build/dbg/asic-audit-full`. `--define` is repeatable. Source paths in either manifest are relative to the
repository root; a source manifest may use `#` or `//` comments. Each audit
writes its inventory and provenance only under `--out`; the combined report
does not replace the checked-in core-only CSV/Markdown files. A subsequent
`--report-only --out ...` uses the top recorded in that output's manifest.

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
