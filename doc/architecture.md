# karu64 — architecture

`karu64` (`rtl/karu64.v`) is a configurable RV64 core. Its Linux configuration
selects **RVA23S64** through `KARU_RVA23S64`, including full **RVV 1.0** and
**Zvbb**, **H/Sha virtualization**, Sv39/Svade/Svnapot/Svpbmt paging, Svinval,
Sstc and trap delegation. The shipping FPGA build also enables **Zvk** vector
crypto and draft **Zvknhk** Vector Keccak (`vkeccak.vi`). The core is
**single-issue, in-order**, with a registered **ID/EX stage** and a **64-bit PC**.
Validation limits and platform obligations are recorded separately.

This document describes the micro-architecture as implemented. For build/run
flows see [flows.md](flows.md); for the FPGA SoC and bitstreams see
[fpga.md](fpga.md); for profile and release status see
[rva23s64-plan.md](rva23s64-plan.md) and
[release-diagnostics-2026-09-14.md](release-diagnostics-2026-09-14.md).

## Pipeline and issue model

The core is a classic in-order machine with one registered packet between
decode and execute:

```
        ┌──────── AXI4 (read-only) ──────► IMEM (via I-cache, optional)
        │  AR/R
   ┌────┴─────┐
   │   IFU    │  prefetch (buf0/buf1) + RVC realign + cross-quadword assembly
   └────┬─────┘            ▲ IMMU (Sv39) translates fetch VA in paged modes
        │ 16/32-bit insns
   ┌────▼─────┐
   │  DECODE  │  karu_rvc64 (RVC expand) + karu_dec (RV64 decode + post-passes)
   └────┬─────┘
        │
   ┌────▼─────┐
   │  ID/EX   │  one-entry registered packet (ex_*) + operand bypass
   └────┬─────┘
        │ issue (one FU at a time)
   ┌────┴────────────────────────────────────────────────┐
   │  ALU  bitmanip  BRU  CSR  M  LSU  FPU  varith  vlsu │
   └────┬────────────────────────────────────────────────┘
        │ writeback (integer / FP / vector regfile)
   ┌────▼─────┐
   │ REGFILES │  integer 2R/1W, FP 2R/1W, vector VRF (BRAM-backed)
   └──────────┘
```

**Single-issue is enforced structurally.** The core gates new issue (`*_active`
registers in `karu64.v`) on the functional units' busy state: a multi-cycle unit
holds `busy` from `req` until its `done` pulse, and nothing else issues
meanwhile. Single-cycle units (ALU, bit-manip, BRU, CSR, vset*) retire in their
issue cycle. The structural contracts this relies on (at most one FU active per
cycle, one writeback port per cycle, etc.) are checked continuously by the
passive assertion library `rtl/karu_assert.sv` (see "Invariants" below).

### Functional-unit handshake

Every multi-cycle unit (`karu_m`, the FPU stack, `karu_lsu`, `karu_varith`,
`karu_vlsu`) shares one handshake:

```
req     (in)  pulse one cycle to start a new op when busy is low
busy    (out) high while an op is in flight
done    (out) one-cycle pulse when result/flags are valid (same cycle as res)
res     (out) result
flags   (out) fflags (FPU) / status
latency (out) build-time constant: cycles req→done
```

**Operand-stability gotcha.** Decoder outputs are combinational on the IFU's
current instruction, which advances as soon as `issuing` fires. Units that latch
their inputs at `req` time (LSU, M, all FP sub-units) are safe; anything that
must read an operand *after* the req cycle latches it explicitly (the FMA path
latches `op3` as `fma_op3_q` because its add stage runs several cycles later).

## Modules (`rtl/`)

### Front end and memory

- **`karu_ifu`** — AXI4 fetch + RVC realign. Holds two 64-bit prefetch entries
  (`buf0`/`buf1`) and assembles 32-bit instructions including the
  cross-quadword case (`pc[2:0]==6`). In paged modes the fetch VA is translated
  by the IMMU `karu_sv39` instance first; redirects flush the prefetch buffers
  and discard any in-flight stale translation/AXI response. Fetch uses the
  actual execution privilege, never MPRV. A second page is demanded only when
  the instruction needs it; a compressed instruction at a page's final
  halfword can retire without touching its successor. Instruction faults
  retain the instruction-start PC for EPC and the actual faulting instruction
  byte for `tval`, including the second halfword of a split instruction.
  EBREAK and C.EBREAK also report their instruction address in `tval`;
  the access-fault firmware checks both breakpoint widths and EPC values.
- **`karu_icache`** — read-only direct-mapped instruction cache (64-byte lines,
  `KARU_ICACHE_KB` KiB, default 4), slotted between the IFU's AXI read master and
  `imem` behind an arbiter lock so an IMMU page-walk can't preempt a refill
  burst. `FENCE.I` invalidates it. Opt-in in generic/testbench builds
  (`KARU_ICACHE`, off → byte-identical); on by default in DDR Vivado builds,
  which pay real instruction-memory latency. The standard cacheable DRAM
  range is `0x80000000–0xffffffff` (2 GiB), matching the PMA map and DDR
  crossbar. Svpbmt NC/IO fetches bypass
  both tag hits and allocation; IO fetch is demand-only and observes the
  physical fetch-safety restrictions.
- **`karu_mem`** — unified write-through L1 (scalar LSU + 128-bit vector port →
  dmem master; DMMU PTE reads bypass this L1 through the `karu64.v` arbiter).
  IMMU PTE reads use the instruction-side arbiter. Svade walkers have no
  page-table writes. Everything outside the DRAM window is uncacheable by
  construction, so all MMIO bypasses the L1. The standard DRAM window is
  `0x80000000–0xffffffff`, including vector-store posting and burst eligibility;
  nonzero PBMT and the explicit `uncache_page` still force bypass.
  Cacheable vector stores use two-beat bursts and one waiting granule slot.
  The core drains the active/waiting stores at instruction boundaries, so
  FENCE, AMO, MMIO and interrupt entry remain ordered after write responses.
  Svpbmt carries translated attributes separately from PA.
  NC/IO bypass cache hits/allocation, posting and two-beat vector-store bursts.
  Bypass stores invalidate a matching resident cache line, including writes
  through the vector IO sequencer; cacheable stores retain byte-enabled hit
  updates. This maintains CPU-store aliases, not external DMA coherence.
  Non-idempotent IO vector accesses use exact active-element transfers;
  masked and tail elements do not cause bus accesses. PBMT=0 devices inherit
  physical IO behavior; scalar accesses retain their native width/address.
  Architectural and integrated bus/fault coverage is recorded below.
- **Memory leaves** — large inferred arrays are kept behind named leaf modules
  for ASIC macro substitution: `karu_ram_prim.v` contains the generic true
  dual-port byte-enable and async-read RAM wrappers used by the VRF, caches,
  PWC, and VPERM buffers; `karu_vlsu_buf.v` isolates the VLSU scratch buffers
  behind a sequencer-facing interface. The leaf interfaces preserve the current
  RTL timing models.
  The [ASIC source handoff](../flow/asic/README.md) lists every elaborated
  memory for the RVA23S64 processor, including ports, masks and async-read
  constraints. Its `KARU_ASIC` configuration excludes FPGA power-up values;
  it does not itself substitute synchronous SRAM macros.

### Decode and scalar integer

- **`karu_dec` + `karu_rvc64`** — RV64I/M/F/D/V decode + RVC expansion. A decode
  post-pass also recognises the bit-manip ops and raises a vectoring cause-2
  illegal-instruction exception for disabled/illegal encodings.
- **`karu_alu`** — single-cycle combinational integer ALU (includes the *W
  32-bit ops and Zicond `czero.eqz`/`czero.nez`).
- **`karu_bitmanip`** — single-cycle combinational Zba/Zbb/Zbs (the
  RVA23-mandatory scalar bit-manipulation set).
- **`karu_m`** — RV64M (mul/mulh\*/div(u)/rem(u) + W variants). The multiplier
  is `KARU_MUL_CYCLES` ∈ {1,4,16,64} (1 = combinational, >1 = radix-2^K
  shift-add); the divider is `KARU_DIV_CYCLES` ∈ {1,64} (64 = restoring
  bit-serial). Sign handling is at the boundary (magnitudes → unsigned → negate).

### Load/store and atomics

- **`karu_lsu`** — AXI4 load/store with cross-8-byte misaligned support (two-beat
  split), the FP loads/stores (FLW/FSW/FLD/FSD, and `flh`/`fsh` with upper-48
  NaN-box), and the full **A extension** (LR/SC + 9 AMOs in W/D) via an internal
  read-compute-write ALU. `cbo.zero` is a real 8×8-byte zeroing loop.
  **Bare-mode data accesses** (effective M-privilege or `satp.MODE=Bare`)
  bypass the registered
  Sv39 handshake (`lsu_bare`): the LSU starts in the issue cycle with PA=VA,
  saving ~1 cycle/op for ordinary M-mode firmware. With MPRV set, MPP selects
  the effective S/U data privilege and can require translation even while
  instructions execute in M-mode.

Zicbom management operations (`cbo.inval`, `cbo.clean`, `cbo.flush`) use
load-or-store permissions, including execute-only mappings made readable by
MXR. Under Svade they require A but not D, and report store-class faults.
`cbo.zero` requires store permission and A/D. Every CBO addresses the aligned
64-byte block containing its effective address; it is not an 8-byte access
starting there and never requires the next page merely because the supplied
address is at offset `0xfff`.
`cbo.zero` retains that whole-block footprint on permitted device addresses;
it is an exception to the native-width/inactive-byte rule for ordinary loads
and stores and must not be used on device registers.

Smnpm/Ssnpm pointer masking uses the effective data privilege. Virtual
addresses sign-extend the retained address, while Bare/physical addresses
zero-extend it; MXR disables pointer masking. Scalar addresses are masked after
effective-address calculation. The VLSU captures the same controls and masks
each final element address, including index/stride offsets, before preflight.
Instruction fetch is never pointer-masked.

Physical permissions are checked before the 64-bit address is narrowed to AXI.
`rtl/karu_pma.vh` defines the standard map: 2 GiB RAM at `0x80000000`, read-only
boot ROM at `0x1000..0x100fff`, scratch SRAM at `0x101000..0x110fff`, and the
CLINT, PLIC, UART, Ethernet and SPI-controller windows. Holes, addresses above
32 bits, writes to ROM and instruction fetches from devices raise access
faults. Other integrations supply `KARU_PMA_CUSTOM_HEADER`, defining the same
`karu_pma_ok(address, access_kind)` and `karu_pma_io(address)` functions with
4-KiB-aligned regions; the vector preflight caches permissions by page.
The second function marks non-idempotent device memory when PBMT=0.
Nonzero PBMT overrides the memory type, never permission checks.
This is a static PMA policy,
not programmable PMP or a claim that every device supports every access width.

AXI SLVERR/DECERR responses propagate through the data cache, scalar LSU,
page-table walkers and instruction path; errored refills are not cached.
Access faults use causes 1/5/7, distinct from page faults 12/13/15, and report
the corresponding virtual address. Vector loads commit their buffered prefix
before a bus-error trap, with `vstart` identifying the failed element; a
fault-only-first load instead trims `vl` for a fault after element zero.
Posted contiguous stores remain architecturally active through the final B
response, retain virtual-address metadata, and cancel their queued suffix on
error. Per-element/device stores wait for their response. A bus-error store
can have committed a prefix; preflight permission faults occur before stores.
`make access-test mem-stream-test` exercises these paths, including injected
errors, split accesses, masked/segmented ff loads and posted-store cancellation.

### CSR, privilege, and MMU

- **`karu_csr`** — M/S/U CSRs: trap delegation (`medeleg`/`mideleg`), `mret`/
  `sret` with the MPP/SPP/MPIE/SPIE stacks, a CSR-legality gate, `satp`,
  `mstatus.FS/VS` context-state gating (Off → FP/vector ops and their CSRs raise
  vectoring cause-2; execution sets the field Dirty and derives SD), HPM
  counters, and `fcsr`/`frm`/`fflags`. Unsupported `satp.MODE` writes preserve
  the entire old register; supported Bare/Sv39 writes retain the implemented
  ASID/PPN fields. MPP, trap-vector
  modes, EPC alignment, delegation, interrupt and counter-enable masks follow
  the implemented configuration. MRET returning below M and host SRET clear
  MPRV; VS SRET does not modify the host MPRV field.
  Software `mip.SEIP` state is distinct from the external SEIP input, including
  CSR read-modify-write operations; undelegated supervisor interrupts can
  target M-mode. FIOM is writable, with its stronger ordering already supplied
  by the in-order memory drain.
- **`karu_sv39`** — Sv39 MMU with a small TLB and PTE-line cache, instantiated
  for fetch and data. It uses **Svade only**: A=0, or a store with D=0, raises
  page-fault cause 12/13/15 with the original VA. A load-filled D=0 TLB entry
  still rejects a later store. `menvcfg.ADUE` is read-only zero; optional
  Svadu hardware PTE updates are not implemented. Non-leaf U/A/D and
  unsupported PTE bits are rejected. All AXI write outputs are tied inactive.
  Host PWC line fills are restricted to DRAM; ROM/scratch and IO PTEs use
  exact single-beat reads. Early or missing burst RLAST faults instead of
  validating a partial PWC line. Guest walks continue to use exact reads.
- **Svnapot** — standard 64 KiB NAPOT leaves have N=1 at level zero and
  `PPN[3:0]=1000`. Fixed slices substitute the addressed VPN low nibble;
  the TLB retains an ordinary 4 KiB entry for that subpage rather than a
  range matcher. Other NAPOT encodings/non-leaf uses fault. Existing
  permissions, Svade checks, PTE-line caching and invalidation still apply.
- **Svpbmt** — S-enabled builds expose reset-zero `menvcfg.PBMTE`
  (bit 62). Enabled leaf encodings 00/01/10 select PMA/NC/IO; 11 and nonzero
  non-leaf fields fault. Both walkers retain attributes with TLB entries;
  data paths carry first/second-page types independently through split
  accesses. Page types do not override physical access permissions. In the
  opt-in H implementation, a nonzero VS leaf type overrides the G leaf type;
  implicit VS-PTE reads use their G-stage type and physical permissions.
- **Sstc** — S-enabled builds provide RV64 `stimecmp` (0x14d, reset all
  ones) and `menvcfg.STCE` (bit 63, reset zero). M access to `stimecmp` is
  unconditional; S access requires STCE and `mcounteren.TM`, independently
  of `scounteren.TM`; U access traps. A two-stage unsigned comparison with
  `time_in` registers four 16-bit summaries and their final fold. A changed
  comparator value reaches hardware STIP within two subsequent clock edges.
  STCE selects hardware STIP exclusively and makes `mip.STIP` read-only;
  STCE=0 restores legacy M-firmware injection. The implementation clears the
  software-STIP latch when STCE changes. Interrupt delivery retains normal
  privilege/delegation rules and waits for an in-flight vector operation to
  drain. Opt-in H adds `htimedelta`, `vstimecmp` and virtual timer pending
  state, covered by CSR tests and the 187-case guest timer monitor. Linux/KVM
  timer results are recorded in the release diagnostics. RV32-only high-half
  CSRs remain absent.
- **Svinval and invalidation** — `SINVAL.VMA` uses the conservative full
  TLB/PWC flush and frontend redirect already used by `SFENCE.VMA`. Outstanding
  reads drain, but canceled walks do not repopulate either cache or start
  further PTE reads. Existing issue/memory-drain ordering also supplies
  `SFENCE.W.INVAL`/`SFENCE.INVAL.IR`. All three Svinval instructions require
  S or M privilege; TVM applies to `SINVAL.VMA`, not the ordering-only fences.
  `mret`/`sret`/`sfence.vma` retain their privilege and TVM/TW/TSR checks.
- **H/Sha virtualization** — `KARU_H`, enabled by `KARU_RVA23S64`, provides
  nominal/effective virtualization state, H/VS CSR banks, M/HS/VS trap/return
  and injected-interrupt routing,
  virtual-instruction exceptions and dual host/guest FS/VS gates. HLV/HLVX/HSV
  use forced guest access context; HFENCE/HINVAL conservatively flush both
  walkers. A registered controller translates VS PTE addresses through G
  before translating the final GPA (VS Bare/Sv39, G Bare/Sv39x4). Precise
  guest GPA and implicit-PTE `tinst=0x3000` reach IFU and data traps. Fetch-walk
  cancellation drains asserted reads without starting subsequent IO reads;
  younger fetch faults wait for older execution and posted stores.
  Four guest-TLB entries retain resolved HPA/GPA, separate VS/G permissions
  and PBMT, tagged by both roots, ASID/VMID and attribute enables. A registered
  hit stage rechecks live access controls and physical permissions; invalidation
  is conservative. Cached/uncached differential checks and the Bare, paged and
  virtual-timer monitors pass. The timer reference uses the documented pinned
  Spike and Sail corrections. Software two-guest FP/vector/timer,
  shared-control and resident-Keccak save/restore pass 88/91-case monitors.
  The integrated VS/VU PMU fixture has 21 cases, including six added
  Shlcofideleg delivery cases. With H+Sscofpmf, `hideleg[13]` delegates
  LCOFI to VS without changing cause 13; `vsip/vsie[13]` alias `sip/sie[13]`
  when delegated. `hvip/hip/hie[13]` stay zero (no AIA injection).
  Karudeb Linux 7.2.4 KVM clears `hideleg` and uses Ssaia's `hvien` path
  for guest PMU injection; it does not use Shlcofideleg. Guest perf sampling
  with that kernel needs the optional, unimplemented Ssaia extension.
  MIE/HIE.SGEIE is writable with H; MIDELEG[12] is read-only one, while
  GEILEN=0 keeps `hgeip/hgeie` and SGEIP zero. A separate 96-case
  fixture proves asynchronous guest FP/vector preemption, including pending
  timer overlap, drained retirement and precise resume, on both pipelines;
  Linux/KVM preemption and broader Sha assurance remain open. The shipping
  `rva23s64-ddr` image enables H and advertises the bound profile. Hardware
  KVM guest execution is validated by `ebreak_test` and `arch_timer`; exact
  image coverage is in the [release diagnostics](release-diagnostics-2026-09-14.md).
- **`karu_clint` / `karu_plic`** — single-hart CLINT (`msip`/`mtimecmp`/`mtime`
  at `0x0200_0000`, drives machine-software and machine-timer interrupts)
  and a minimal PLIC (NS16550 = source 1), feeding
  `irq_software`/`irq`/`irq_external_m`/`irq_external_s`. `mip.MSIP` is a
  read-only view of the MMIO-controlled CLINT input, not a CSR injection
  latch. MSIP register bits 31:1 are read-only zero. Both BRAM and DDR SoCs
  wire this path, including the VCU118 top.
  PLIC pending/gateway state supports priority arbitration and claim/complete;
  threshold gates notification but does not block polling a claim. A native
  claim read snapshots its data and removes the pending source atomically,
  so AXI R backpressure cannot repeat or corrupt the side effect. Completion
  requires the source enabled in that context; after masking a claimed source,
  re-enable and complete again to recover. No debug MMIO register is added.

Directed entry points are `make csr-test sv39-test ifu-test
svinval-decode-test sstc-test sstc-test-spike`, plus the existing scalar/vector MMU and privilege
firmware. A separate `karu64-sv39` ACT4 configuration selects a privileged-1.13
test configuration alongside the M-only regression.
See [flows.md](flows.md#supervisor-regressions) and the
[profile roadmap](rva23s64-plan.md); this is not an exhaustive supervisor audit.

### Floating point (`karu_fpu`)

`karu_fpu` is the F/D dispatcher: a uniform req/busy/done/result/flags handshake
to the core, routing by the decoder's `is_d` precision bit. All F/D arithmetic
does **full subnormal-input normalisation + gradual-underflow output**
(tininess-after-rounding NX/UF) — 0 errors vs Berkeley TestFloat-3e across 46k+
vectors/op × 5 rounding modes.

- **F sub-units:** `karu_fmul`, `karu_fadd`, `karu_fdiv`, `karu_fsqrt`
  (25-cyc bit-serial), `karu_fcvt`, and combinational `karu_fmisc`
  (sgnj/minmax/cmp/class/fmv).
- **D sub-units** (53-bit mantissa, 11-bit exp, bias 1023): `karu_fmul_d`,
  `karu_fadd_d`, `karu_fdiv_d`, `karu_fsqrt_d` (54-cyc), `karu_fcvt_d`
  (f2i/i2f and the combinational cross-precision `fcvt.s.d`/`fcvt.d.s`), plus the
  D misc ops in `karu_fmisc.v`.
- **Fused FMA:** `karu_ffma` / `karu_ffma_d` compute `(-1)^np·(a·b) ± c` with a
  **single rounding** over a full-width intermediate (SoftFloat-3e
  `mulAddF{32,64}` port; all four variants via np/nc). 0-error vs TestFloat
  `mulAdd`.
- **Zfhmin** (FP16-minimal): the half conversions `fcvt.{s,d}.h`/`fcvt.h.{s,d}`,
  `fmv.x.h`/`fmv.h.x`, and `flh`/`fsh` (upper-48 NaN-box). No FP16 *arithmetic*.
- **Zfa** (additional scalar FP): `fli`/`fminm`/`fmaxm`/`fleq`/`fltq`/`fround`/
  `froundnx`/`fcvtmod.w.d`, routed via a 4-bit `fp_zfa` side field (`fli` is a
  ROM, `fround` composes f2i→i2f with a registered integer intermediate,
  `fcvtmod` lives in `karu_fzfa.v`). `fround`/`froundnx` take three dispatcher
  cycles rather than the two-cycle ordinary conversion path, for every input
  class. `make zfa-test-all` compares the complete result/flags digest with
  Spike, including ties, signed zeros, subnormals, exponent boundaries and NaNs.

**NaN-boxing.** f-regs are 64 bits; singles are stored with the upper 32 all-1s.
Writers (FLW, FPU writeback) box on write; readers of singles substitute the
canonical NaN `0x7FC00000` if the box is broken. Raw moves (`fmv.x.w`) bypass
the box per spec. D values use the full 64 bits.

### Vector unit (RVV 1.0 "V")

Mask count/first/prefix operations summarize each 128-bit source granule in
two fixed compute phases. The first registers eight independent 16-bit
population counts and first-set-bit indices; the second combines them using
balanced trees and updates the running summary. Counts are nine bits wide
(0..256), rather than a chain of 64-bit increments. Prefix-mask writeback uses
the completed first-index summary. There is no operand-dependent early exit.

Vector-FP issue checks
both FS and VS, and legal vector-FP operations conservatively dirty FS.
Source EEW, register-group geometry and reserved-field checks run before any
memory or register side effect. Ssstrict is not advertised: the selected
reserved-encoding tests do not constitute an exhaustive audit.
The datapath is built as a
replicated lane array so synthesis maps one lane and copies it:

- **`karu_vrf_bram` + `karu_vrf_bram_wr`** — the macro-VRF: a dual-port
  BRAM-backed vector register file plus a sequencing adapter. Whole-register
  reads latch with `op_stall` refill; writes are granule-serial with **exact byte
  enables**, which is how the vta/vma "undisturbed (keep-old)" tail is realised
  (old-vd is read only as a genuine operand). This is the only VRF.
- **`karu_vlane`** — one 64-bit sub-word-SIMD lane (e8×8 / e16×4 / e32×2 /
  e64×1) with a rolled-in scalar `karu_fpu` and the `karu_vest7` estimate helper.
  Instantiated `NLANES = VLEN/64` times via genvar with `keep_hierarchy`.
- **`karu_varith`** — the unified vector-execute engine. It owns the lane array
  and sequences both the integer datapath (arith / mask / fixed-point /
  widen-narrow / reductions / permute) **and** the FP datapath (OPFVV/OPFVF
  through the lane FPUs, including widening F→D). `vkeccak` and Zvk also run here
  as FSM modes.
- **`karu_vlsu`** — vector load/store: unit-stride, whole-register, mask,
  strided, indexed (ordered≡unordered in this in-order core), and segment.
  Strided/indexed/segment go through the per-element `pelem` engine (1-or-2
  granule access for straddling elements). The VLSU **translates through the
  shared Sv39 DMMU** with a preflight pass (only ACTIVE elements translated,
  precise fault-abort), so vector page faults trap/delegate with exact
  cause/tval/epc. Its temporary register, memory, index, and element buffers
  live in `karu_vlsu_buf`. `vle*ff`/`vlseg*ff` trim on a faulting tail.
  Contiguous loads bypass the old-vd snapshot and write exact active-byte
  enables. Contiguous stores snapshot only the active interval, with one
  granule per cycle after priming the synchronous VRF read.
- **`karu_vest7`** — the 7-bit `vfrec7`/`vfrsqrt7` estimates (a verbatim port of
  spike's `fall_reciprocal.c`).

Implemented vector ops: `vset*`, the full load-store set, the integer ALU +
compares→mask + mask logic, `vmul`/`vmulh*`/MAC/`vdiv`/`vrem`, carry
(`vadc`/`vmadc`/`vsbc`/`vmsbc`), moves/merges (`vmv.x.s`/`vmv.s.x`/`vmv<nr>r.v`/
`vmv.v.*`/`vmerge`), mask population (`vid`/`vfirst`/`vcpop`/`vmsbf`/`vmsof`/
`vmsif`), fixed-point (sat add/sub, averaging, `vsmul`, `vssrl`/`vssra`,
`vnclip(u)` with `vxsat`/`vxrm`), widening/narrowing, reductions (balanced-tree
fold, including widening), integer extend (`vsext`/`vzext.vf{2,4,8}`), and the
permute/cross-lane family (`vslide*`, `vrgather[ei16]`, `vcompress.vm`,
`viota.m`). Full Zvbb adds `vandn`, rotates, byte/full reversals,
`vclz`/`vctz`/`vcpop`, and widening `vwsll.{vv,vx,vi}`. Counts use bounded
8-bit leaves and a balanced byte/halfword/word tree in each lane; `vwsll`
reuses the staged widening sequencer. The current
[Zkt/Zvkt review](diel-review-2026-09-14.md)
found no protected-operand-dependent latency in the required implemented
families, including serial multiplies, gather/slide and FP slide-one. This
does not cover every vector operation: for example, `vcompress` is excluded
from Zvkt and can have selection-dependent sequencing. The audit distinguishes
execution masks and explicitly exempt controls from masks used as data;
it is not a physical side-channel or formal noninterference proof. Vector FP covers
arith/FMA/min-max/sgnj/compares/`vfclass`/
conversions/reductions/`vfslide1*` at SEW32→F and SEW64→D, with **Zvfhmin**
FP16↔FP32 conversions; every other e16/e8 vector-FP encoding traps cause-2.

### Vector-crypto and Keccak

- **`karu_vcrypto` (`rtl/zvk/`)** — aggregated Zvk leaf datapaths behind one
  req/busy/done handshake, driven by `karu_varith` as an FSM mode. Standard Zvk
  leaves are opt-in (`KARU_ZVK` + per-leaf knobs): Zvkned (AES), Zvknha (SHA-256),
  Zvknhb (+SHA-512), Zvksed (SM4), Zvksh (SM3), and Zvkg (GHASH). Zvkb is the
  bit-manip glue subset already supplied by default-on Zvbb. Decode maps the
  official OP-VE major opcode `0x77` (not OP-V
  `0x57`) to `UNIT_VCRYPTO`; SEW legality is enforced per the vector-crypto SEW
  table.
- **`vkeccak.vi`** — an opt-in (`KARU_KECCAK`) implementation of the draft
  **Zvknhk** Vector Keccak extension (riscv-pqc `zvknhk.adoc`): one
  Keccak-p[1600,24] or Keccak-p[1600,12] permutation (selected by `imm5`) on a
  fixed 2048-bit element group at `vd`, independent of `vl`/LMUL, with the state
  tail (elements 25..31) preserved. OP-VE `0x77`, VAES.vs selector `10010`,
  exact-matched so Zvk encodings don't alias; reserved encodings (`SEW≠64`,
  `imm5>1`, `vm=0`, unaligned `vd`, `vstart≠0`) trap. Folded into `karu_varith`
  using one isolated `keccak`/`keccak_round` instance that is never
  lane-replicated. Encoding and semantics: rtl/zvk/README.md.
  Both VRF ports reload one 256-bit state register per fill. The ideal-memory
  SHAKE absorb/squeeze measurements are in [keccak-throughput.md](keccak-throughput.md).
  The [reproducible software comparison](keccak-software-comparison.md) covers
  GCC/Clang GC, Zbb and vector-enabled C; those C builds are not resident RVV
  permutations. The instruction-assisted benchmark keeps state in the VRF.

### Register files

- **`karu_regfile`** — integer 2R/1W.
- **`karu_fregfile`** — FP 2R/1W, 32 × 64-bit. FMA's rs3 is read on port B
  during the FMA's issue window (the port is idle then, since decode cannot
  accept behind a long-latency op), so FMA costs no extra cycle.
- The vector VRF is the BRAM-backed macro-VRF described above.

## Memory map and AXI

The core exposes AXI4 master ports for instruction fetch and data. In the
testbench two 64-bit slave ports (imem RO, dmem RW) back one RAM array at
`0x80000000`; in the FPGA SoC the same devices sit as MMIO siblings (CLINT
`0x0200_0000`, PLIC `0x0c00_0000`, NS16550 `0x1000_0000`), and the DDR4 variant
merges imem+dmem onto one AXI master toward the MIG. The PC is **64-bit**
internally; platforms place RAM in the low 4 GiB (the DDR4 build widens the DRAM
window to the full 2 GiB).

## Build-time configuration

ISA extensions are individually pluggable (`rtl/karu_ext.vh`). The base core is
RV64-**I**; C/A/M/B/F/D/V are gated by `KARU_NO_C` / `KARU_NO_A` / `KARU_NO_M` /
`KARU_NO_B` / `KARU_NO_F` / `KARU_NO_D` / `KARU_NO_V`, with the dependency cascade
**V ⊃ D ⊃ F** (dropping F also drops D/V, etc.). Full Zvbb is enabled by
every normal V build because RVA23U64 requires it; `KARU_NO_ZVBB` is the area
opt-out, and `KARU_NO_ZVBB KARU_ZVKB` retains the smaller subset. Vector crypto
(Zvk*) is opt-in via the `KARU_ZVK*` flags and needs V. Disabled instructions raise a vectoring
cause-2 illegal-instruction exception and their units are not instantiated.

`KARU_RVA23S64` is an opt-in composition contract: it requires the mandatory
baseline plus H/Ssstateen and Sscofpmf, rejects conflicting ISA opt-outs,
and checks VLEN256/ELEN64/VBUS128 geometry (RV64 is structural). Optional Zvk, Keccak and
Smcntrpmf are not implied. `make rva23-sim` builds this composition separately;
`make rva23-config-test` checks it across preprocessing, elaboration and
synthesis. This does not enable the profile in legacy FPGA targets or
certify architectural/platform compliance.
The latest complete configured ACT4 inventory passes 2872/2872 tests on both
minimal and shipping-profile RTL models with matched Sail references;
the eight local ACT4 dependency patches and exact coverage limits are listed
in the [test instructions](../test/act4-karu/README.md#evidence-and-interpretation).
The [release diagnostics](release-diagnostics-2026-09-14.md) keep this result
separate from Linux/KVM and physical board validation.

With S enabled, host U-mode WFI deliberately raises illegal instruction
regardless of TW. Builds without S retain U-mode WFI when TW=0. Under H,
VU-mode WFI raises virtual instruction unless TW requires illegal instruction.
This implementation choice is reflected in the matched reference configuration.

Performance/area knobs (full table in the repository build notes) include the
per-unit mul/div cycle counts (`KARU_{M,F,D,V}_*_CYCLES`), FP fast-path multiply
pipelining (`KARU_F_MUL_PIPE`/`KARU_D_MUL_PIPE`), and the two
vector timing levers that close the full-vector FPGA bitstream — the 2-stage lane
pipeline (`KARU_V_LANE_PIPE`) and the cold-funnel writeback stage
(`KARU_V_CWB_STAGE`). The lane boundary captures integer controls, mask bits
and scalar inputs alongside the operand arrays. It also stages complete FPU
requests, adding one fixed dispatch cycle per lane-FPU request; the
combinational reciprocal-estimate path is unchanged. Each knob is
byte-identical when off.

The VLSU finds the first and last active element with balanced priority trees
over the qualified mask (`vstart <= element < vl`). This preserves empty-mask,
tail and fault-only-first behavior without a VLEN-deep priority chain.

## RVA23 feature coverage

Implemented RVA23-mandatory extensions beyond the base ISA: Zba/Zbb/Zbs
(bit-manip), Zicond, Zimop/Zcmop, Zawrs, Zihintntl, Zcb, Zicbom/Zicbop/Zicboz
(CBO, with `menvcfg`/`senvcfg` gating), Zfa, Zfhmin, Supm pointer masking
(Smnpm + Ssnpm), Zicntr/Zihpm counters with `mcounteren`/`scounteren` gating,
the Zvfhmin vector FP16↔FP32 conversions, and full Zvbb. Opt-in, default-off (byte-identical
when off) counter/state extensions: Smcntrpmf, Sscofpmf, and Smstateen/Ssstateen.
The RVA23-*optional* vector extensions full Zvfh and Zvbc are
deliberately not implemented.

Svade, 64 KiB Svnapot, Svinval, Sstc, Svpbmt and the Sha augmented
hypervisor package are implemented in the opt-in profile. See the
[profile status](rva23s64-plan.md) for validation scope and remaining platform
gates. The Svpbmt
implementation carries PBMTE and page types through scalar/vector memory, fetch
and cache-block paths; NC/IO bypass caches and posted vector stores, and IO
uses exact active-element transfers. The supervisor ACT4 manifest enables
Svpbmt for verification. Architectural, integrated bus-observer and directed
fault tests pass, including physical-device native-width behavior. Broader
platform/profile assurance and hardware boot are separate results, not implied
by those focused tests. The current profile's independent area/timing,
September 25 board acceptance and September 22 KVM guest results
are in the [release diagnostics](release-diagnostics-2026-09-14.md).

## Invariants and hang guards (`rtl/karu_assert.sv`)

`karu_assert` is a passive checker of the core's architectural state and
signaling (not instruction semantics — that is what riscv-tests and TestFloat
cover). It is not in the core; `htif_tb.v` instantiates it via hierarchical refs.
It encodes the structural contracts the single-issue design depends on — at most
one FU active per cycle (`$onehot0`), no `*_req` while any FU is busy, never write
`x0`, integer and FP regfiles never written the same cycle, exactly one VRF write
port per cycle, vector memory addresses granule-aligned, plus a set of RVA23
semantic contracts (Supm address canonicalisation, CBO beat shape/enables,
privilege-illegal → cause-2, Zfa write-class). Per-FU `STALL_LIMIT` and global
`RETIRE_LIMIT` hang guards print the PC + active-FU state and `$finish` on a
runaway; `+no_assert` disables, `+no_assert_stop` reports-and-continues.

## What is not implemented

karu64 is single-issue and in-order; there is **no** issue queue, dual-issue,
register renaming, speculation past unresolved branches, or branch prediction
beyond not-taken. PMP reads 0. These are possible future directions, not current
RTL.
