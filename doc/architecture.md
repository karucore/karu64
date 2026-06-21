# karu64 — architecture

`karu64` (`rtl/karu64.v`) is a small **RV64GC** soft-core — RV64IMAFDC +
Zicsr/Zifencei, the full RVV 1.0 **V** vector set, optional **Zvk**
vector-crypto, and a custom `vkeccak` — with **M/S/U privilege, Sv39 paging,
and trap delegation**. It is **single-issue, in-order**, with a registered
**ID/EX stage** and a **64-bit PC**, and it boots Linux to userspace on FPGA.

This document describes the micro-architecture as implemented. For build/run
flows see [flows.md](flows.md); for the FPGA SoC and bitstreams see
[fpga.md](fpga.md).

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
   │ REGFILES │  integer 2R/1W, FP 3R/1W, vector VRF (BRAM-backed)
   └──────────┘
```

**Single-issue is enforced structurally.** The core gates new issue (`*_active`
registers in `karu64.v`) on the functional units' busy state: a multi-cycle unit
holds `busy` from `req` until its `done` pulse, and nothing else issues
meanwhile. Single-cycle units (ALU, bit-manip, BRU, CSR, vset*) retire in their
issue cycle. The structural contracts this relies on (at most one FU active per
cycle, one writeback port per cycle, etc.) are checked continuously by the
passive assertion library `rtl/karu_assert.v` (see "Invariants" below).

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
  and discard any in-flight stale translation/AXI response.
- **`karu_icache`** — read-only direct-mapped instruction cache (64-byte lines,
  `KARU_ICACHE_KB` KiB, default 4), slotted between the IFU's AXI read master and
  `imem` behind an arbiter lock so an IMMU page-walk can't preempt a refill
  burst. `FENCE.I` invalidates it. Opt-in in generic/testbench builds
  (`KARU_ICACHE`, off → byte-identical); on by default in DDR Vivado builds,
  which pay real instruction-memory latency.
- **`karu_mem`** — unified write-through L1 (scalar LSU + 128-bit vector port →
  dmem master; vector and immu/dmmu PTW traffic arbitrated onto dmem in
  `karu64.v`). Everything outside the DRAM window is uncacheable by
  construction, so all MMIO bypasses the L1.

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
  **Bare-mode data accesses** (M-priv or `satp.mode≠Sv39`) bypass the registered
  Sv39 handshake (`lsu_bare`): the LSU starts in the issue cycle with PA=VA,
  saving ~1 cycle/op for M-mode firmware. The S/U translated path is unchanged.

### CSR, privilege, and MMU

- **`karu_csr`** — M/S/U CSRs: trap delegation (`medeleg`/`mideleg`), `mret`/
  `sret` with the MPP/SPP/MPIE/SPIE stacks, a CSR-legality gate, `satp`,
  `mstatus.FS/VS` context-state gating (Off → FP/vector ops and their CSRs raise
  vectoring cause-2; execution sets the field Dirty and derives SD), HPM
  counters, and `fcsr`/`frm`/`fflags`. `mret`/`sret`/`sfence.vma` are
  privilege-checked; `mstatus` TVM/TW/TSR are enforced.
- **`karu_sv39`** — Sv39 MMU (page-table walker + small TLB, A/D writeback,
  page-fault causes 12/13/15). Instantiated twice (immu, dmmu); bare mode and
  M-priv bypass translation. An overlapping `sfence.vma` poisons an in-flight
  walk (it drains to `done` but does not fill the TLB or start an A/D write).
- **`karu_clint` / `karu_plic`** — single-hart CLINT (`msip`/`mtimecmp`/`mtime`
  at `0x0200_0000`, drives the machine-timer interrupt) and a minimal PLIC
  (NS16550 = source 1), feeding `irq`/`irq_external_m`/`irq_external_s`.

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
  ROM, `fround` composes f2i→i2f, `fcvtmod` lives in `karu_fzfa.v`).

**NaN-boxing.** f-regs are 64 bits; singles are stored with the upper 32 all-1s.
Writers (FLW, FPU writeback) box on write; readers of singles substitute the
canonical NaN `0x7FC00000` if the box is broken. Raw moves (`fmv.x.w`) bypass
the box per spec. D values use the full 64 bits.

### Vector unit (RVV 1.0 "V")

The base RVV 1.0 set is functionally complete and ACT4-clean (the full generated
RV64GCV ACT4 suite runs 2220 PASS / 0 FAIL). The datapath is built as a
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
  cause/tval/epc. `vle*ff`/`vlseg*ff` trim on a faulting tail.
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
`viota.m`). Vector FP covers arith/FMA/min-max/sgnj/compares/`vfclass`/
conversions/reductions/`vfslide1*` at SEW32→F and SEW64→D, with **Zvfhmin**
FP16↔FP32 conversions; every other e16/e8 vector-FP encoding traps cause-2.

### Vector-crypto and Keccak

- **`karu_vcrypto` (`rtl/zvk/`)** — aggregated Zvk leaf datapaths behind one
  req/busy/done handshake, driven by `karu_varith` as an FSM mode. Standard Zvk
  leaves are opt-in (`KARU_ZVK` + per-leaf knobs): Zvkned (AES), Zvknha (SHA-256),
  Zvknhb (+SHA-512), Zvksed (SM4), Zvksh (SM3), Zvkg (GHASH), Zvkb (the
  bit-manip glue). Decode maps the official OP-VE major opcode `0x77` (not OP-V
  `0x57`) to `UNIT_VCRYPTO`; SEW legality is enforced per the vector-crypto SEW
  table.
- **`vkeccak`** — an opt-in (`KARU_KECCAK`) custom Keccak-f1600 permutation
  instruction (opcode `0x77`, exact-matched so Zvk encodings don't alias), folded
  into `karu_varith` using one isolated `keccak`/`keccak_round` instance that is
  never lane-replicated.

### Register files

- **`karu_regfile`** — integer 2R/1W.
- **`karu_fregfile`** — FP 3R/1W, 32 × 64-bit.
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
**V ⊃ D ⊃ F** (dropping F also drops D/V, etc.). Vector crypto (Zvk*) is opt-in
via the `KARU_ZVK*` flags and needs V. Disabled instructions raise a vectoring
cause-2 illegal-instruction exception and their units are not instantiated.

Performance/area knobs (full table in the repository build notes) include the
per-unit mul/div cycle counts (`KARU_{M,F,D,V}_*_CYCLES`), FP fast-path multiply
pipelining (`KARU_F_MUL_PIPE`/`KARU_D_MUL_PIPE`), the gather crossbar width
(`KARU_V_PERM_LANES`), permute-buffer LUTRAM (`KARU_V_PERM_RAM`), and the two
vector timing levers that close the full-vector FPGA bitstream — the 2-stage lane
pipeline (`KARU_V_LANE_PIPE`) and the cold-funnel writeback stage
(`KARU_V_CWB_STAGE`). Each knob is byte-identical when off.

## RVA23 feature coverage

Implemented RVA23-mandatory extensions beyond the base ISA: Zba/Zbb/Zbs
(bit-manip), Zicond, Zimop/Zcmop, Zawrs, Zihintntl, Zcb, Zicbom/Zicbop/Zicboz
(CBO, with `menvcfg`/`senvcfg` gating), Zfa, Zfhmin, Supm pointer masking
(Smnpm + Ssnpm), Zicntr/Zihpm counters with `mcounteren`/`scounteren` gating,
and the Zvfhmin vector FP16↔FP32 conversions. Opt-in, default-off (byte-identical
when off) counter/state extensions: Smcntrpmf, Sscofpmf, and Smstateen/Ssstateen.
The RVA23-*optional* vector extensions full Zvfh, full Zvbb, and Zvbc are
deliberately not implemented (optional → conformant).

## Invariants and hang guards (`rtl/karu_assert.v`)

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
