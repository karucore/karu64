# Zkt / Zvkt data-independent-latency review — 2026-09-14

Independent source review done against the RTL at commit `69c58cd` (branch
`dev-mjos`) plus the functional `.vs` correction described below, and a new empirical
cycle-count probe run on the RVA23S64 shipping-profile simulator. **Result:
no operand-dependent execution-latency violation found in any implemented
Zkt or Zvkt instruction, in the crypto leaves, or in `vkeccak.vi`.** Two
inventory corrections are recorded below. Two tangential functional
observations were investigated separately and do not change this result.

This is a source review plus a directed simulation measurement. It is not a
formal noninterference proof, a gate-level timing result, or a power/EM
side-channel claim.

## Normative lists used

Lists were taken on 2026-09-14 from the ratified text rendered at
[docs.riscv.org (Zkt)](https://docs.riscv.org/reference/isa/v20260120/unpriv/scalar-crypto.html)
and [docs.riscv.org (Zvkt)](https://docs.riscv.org/reference/isa/v20260120/unpriv/vector-crypto.html),
and the mandatory-extension list from the
[RVA23 profile](https://github.com/riscv/riscv-profiles/blob/main/src/rva23-profile.adoc).

Zkt (RV64 intersection with this core): RVI arithmetic/logic/shift/`slt*`
including the W forms; `mul`, `mulh`, `mulhsu`, `mulhu`, `mulw`; RVC
`c.nop`, `c.addi`, `c.addiw`, `c.lui`, `c.srli`, `c.srai`, `c.andi`, `c.sub`,
`c.xor`, `c.or`, `c.and`, `c.subw`, `c.addw`, `c.slli`, `c.mv`, `c.add`;
**Zcb `c.mul`, `c.not`, `c.zext.b`**; and, of the Zbkb/Zbkc/Zbkx list, the
instructions this core implements through Zbb: `andn`, `orn`, `xnor`, `rol`,
`ror`, `rori`, `rolw`, `rorw`, `roriw`, `rev8`, and the `packw rd,rs1,x0`
encoding (`zext.h`). Zicond's `czero.eqz`/`czero.nez` inherit the requirement
when Zkt is present. HINT encodings (`rd=x0`) are exempt. Loads, stores,
branches, division, FP and Zicsr are excluded.

Zvkt: all Zvbb (`vandn`, `vbrev`, `vbrev8`, `vrev8`, `vclz`, `vctz`,
`vcpop.v`, `vrol`, `vror`, `vwsll`), all Zvbc (`vclmul[h]`, **not
implemented**), add/sub and widening add/sub, carry ops, compares, copies,
extends, mask logic, multiply and multiply-add (including widening),
narrowing shifts, `vrgather*`, `vslide*`, `vslide1*`, `vfslide1*`. DIEL
applies to every data operand including inactive and tail elements and old
`vd`; `vl`, `vtype`, the execution mask, immediates, gather indices and the
`vslideup/down` offset are exempt. The crypto leaves (Zvkg, Zvkned,
Zvknha/b, Zvksed, Zvksh) each require DIEL of their own instructions.

## Scope of the RTL read

Four independent read-only passes over the full sources, one per area:

- Scalar: `karu_alu.v`, `karu_bitmanip.v`, `karu_m.v`, `karu_rvc64.v`,
  `karu_dec.v`, `karu_regfile.v`, and the issue/bypass/writeback/retire logic
  in `karu64.v`.
- Vector: all of `karu_varith.v`, `karu_vlane.v`, `karu_vrf_bram_wr.v`,
  `karu_vrf_bram.v`, `karu_ram_prim.v`, `karu_vcfg.vh`, `karu_cfg.vh`, and
  the vector issue/retire in `karu64.v`.
- Crypto: every file in `rtl/zvk/` and the `S_CREQ`..`S_CWR` and
  `S_KLOAD`..`S_KSTORE` wrapper states of `karu_varith.v`.
- Privileged/U64 inventory (appendix).

Configurations considered: the default build and the `KARU_RVA23S64`
shipping composition (`KARU_M_MUL_CYCLES=4`, `KARU_V_MUL_CYCLES=16`,
`KARU_V_LANE_PIPE`, `KARU_V_CWB_STAGE`, `KARU_ZVK`, `KARU_KECCAK`), and the
`KARU_MUL_CYCLES=1` combinational multipliers.

## Findings: scalar Zkt

All PASS. The pipeline has exactly one place where operand data could
influence timing, and it does not:

- Issue is `ex_valid && !exec_busy` ([karu64.v:1818](../rtl/karu64.v#L1818));
  `exec_busy` is a disjunction of unit-active flags and the posted-store drain
  ([karu64.v:1809-1810](../rtl/karu64.v#L1809)). No data term.
- Bypass compares register numbers only
  ([karu64.v:465-466](../rtl/karu64.v#L465)). Regfile writes are
  `if (we && rd != 0)` ([karu_regfile.v:232](../rtl/karu_regfile.v#L232)),
  with no old-versus-new suppression and no clock gating.
- ALU ops, including register-amount shifts, are one combinational cycle
  ([karu_alu.v:25-27, 38-40](../rtl/karu_alu.v#L25)); `czero.*` is a result
  mux ([karu_alu.v:60-61](../rtl/karu_alu.v#L60)).
- Multiply: combinational product at
  [karu_m.v:109](../rtl/karu_m.v#L109), or serial `cnt <= MUL_C`
  ([karu_m.v:226](../rtl/karu_m.v#L226)) decremented unconditionally with
  `done` at `cnt == 1` ([karu_m.v:238-239](../rtl/karu_m.v#L238)). Sign and
  W handling are combinational pre/post steps. The divider shares the FSM
  but always runs 64 steps and can never overlap a multiply because
  `m_active` blocks issue.
- Rotates use two fixed shifters and a `sh == 0` result mux
  ([karu_bitmanip.v:135-143](../rtl/karu_bitmanip.v#L135)); `rev8` and
  `zext.h` are wiring. Decoders take only the instruction word
  ([karu_dec.v:10](../rtl/karu_dec.v#L10),
  [karu_rvc64.v:15](../rtl/karu_rvc64.v#L15)).
- Zcb: `c.mul` expands to `mul` ([karu_rvc64.v:144-146](../rtl/karu_rvc64.v#L144)),
  `c.not` to `xori` ([:158-159](../rtl/karu_rvc64.v#L158)), `c.zext.b` to
  `andi` ([:148-149](../rtl/karu_rvc64.v#L148)); all land on the paths above.

The `vset*` datapath reads `ex_xrs2_v` whenever `ex_sub == VCFG_SETVL`, whose
encoding collides numerically with `ALU_SUB`/`M_MULH`
([karu64.v:603-611](../rtl/karu64.v#L603)); the derived values are consumed
only under `issue_vcfg`, so `sub`/`mulh` cannot trap or stall through it.

Scalar Zbkb/Zbkc/Zbkx/Zkn*/Zks* are not implemented; general `packw` traps.

## Findings: vector Zvkt

All PASS. Walk lengths are functions of `vl`, SEW, LMUL and instruction
fields only ([karu_varith.v:327-329, 529-530](../rtl/karu_varith.v#L327));
the only operand stall is the VRF fill on a register/granule tag mismatch
([karu_vrf_bram_wr.v:128-133](../rtl/karu_vrf_bram_wr.v#L128)); byte enables
derive from `vl`, the execution mask and the slide offset, never from data
([karu_varith.v:1920-1966](../rtl/karu_varith.v#L1920)).

| Family | Path and argument |
| --- | --- |
| add/sub/logic/shift, Zvbb unary and rotates | Lane loop `S_RUN`→`S_GWB` ([karu_varith.v:2392-2412](../rtl/karu_varith.v#L2392)); combinational lane ALU and count trees ([karu_vlane.v:141-217, 405-425](../rtl/karu_vlane.v#L141)). |
| widening add/sub, `vwsll` | `S_WRUN` passes fixed by `last_g` and `wide_iter` ([karu_varith.v:2570-2584](../rtl/karu_varith.v#L2570)). |
| `vadc`/`vsbc` | Carry bits from `v0` feed the adder only ([karu_vlane.v:443-445](../rtl/karu_vlane.v#L443)). |
| `vmadc`/`vmsbc`, compares, mask logic | `S_RUN` accumulation then `S_CMW` writes exactly `VGRAN_C` granules with full enables ([karu_varith.v:2734-2745](../rtl/karu_varith.v#L2734)); for carry and mask-logic ops every in-`vl` bit is written regardless of value ([:2195-2200](../rtl/karu_varith.v#L2195)). |
| copies, merge, extends | Lane path or `S_RUN`→`S_CWB` with fixed granule drain ([karu_varith.v:2413-2419, 2833-2848](../rtl/karu_varith.v#L2413)). |
| multiply / MAC, serial | `mcnt <= V_MUL_C` ([:2542](../rtl/karu_varith.v#L2542)), unconditional step to `mcnt == 1` ([:2548](../rtl/karu_varith.v#L2548)); `mle` walks all `epr` elements including inactive/tail ([:2558](../rtl/karu_varith.v#L2558)); widening uses the same step with `epr_w`/`wide_iter` ([:2587-2610](../rtl/karu_varith.v#L2587)). No remaining-bits early exit exists. |
| multiply / MAC, combinational | `au*bu` etc. in the lane ([karu_vlane.v:427-441](../rtl/karu_vlane.v#L427)). |
| narrowing shifts | `S_NA`/`S_NB` window loop over `epr_w` ([:2616-2635](../rtl/karu_varith.v#L2616)). |
| `vrgather*`, `vslide*`, `vslide1*` | `S_PLOAD` loads `load_n` registers (LMUL/EEW derived, [:423-424](../rtl/karu_varith.v#L423)); `S_PCOMP` steps `pse` to `epr` ([:2681-2696](../rtl/karu_varith.v#L2681)). Index values reach only the async-RAM read address and bounds mux ([:1389-1417, 1538](../rtl/karu_varith.v#L1389)); the inserted scalar only the result mux. |
| `vfslide1up/down.vf` | `vf_use_fpu = 0` ([:1657](../rtl/karu_varith.v#L1657)); `S_FRUN`→`S_FSWB` per element, boxing is a fixed concatenation ([:2144-2150, 2761-2827](../rtl/karu_varith.v#L2761)). |

`KARU_V_LANE_PIPE` adds one held cycle per lane granule
([:2396-2407](../rtl/karu_varith.v#L2396)); `KARU_V_CWB_STAGE` adds one
unconditional hop ([:2855-2858](../rtl/karu_varith.v#L2855)).

The only data-dependent transitions in the sequencer belong to `vcompress`
(`cmp_sel` at [:2705-2713](../rtl/karu_varith.v#L2705)), which Zvkt excludes
and which is reachable only from the `is_compress` dispatch arm. Reductions,
`viota`, `vcpop.m`/`vfirst`/`vms*f`, division and FP element ops are also
excluded and share no state with the listed families.

## Findings: crypto leaves and Zvknhk

All PASS. Every `done`, counter and state in the six clocked crypto modules
is conditioned on `req`, counters, opcode and immediate bits only:

- Wrapper FSM [karu_vcrypto.v:174-280](../rtl/zvk/karu_vcrypto.v#L174):
  `S_COMB` registers the AES / key-schedule / SM3-expansion network and
  pulses `done` two cycles after `req`; the iterative units are awaited on
  their own `done`.
- S-boxes are `assign` netlists ([sboxes.v](../rtl/zvk/sboxes.v)); no RAM,
  no cache, no arbitration.
- SHA-2: two steps for compression, four for the message schedule
  ([karu_sha2_iter.v:107-152](../rtl/zvk/karu_sha2_iter.v#L107)). SM4: four
  steps ([karu_sm4_iter.v:116-124](../rtl/zvk/karu_sm4_iter.v#L116)). SM3:
  four steps ([karu_sm3_iter.v:37-80](../rtl/zvk/karu_sm3_iter.v#L37)).
  GHASH: exactly `GC` busy cycles, `sidx += GK` unconditionally
  ([karu_ghash.v:71-78, 96-101](../rtl/zvk/karu_ghash.v#L71)).
- Element-group activity is `c_base_elem < vl_q`
  ([karu_varith.v:2279-2289](../rtl/karu_varith.v#L2279)); the decoder
  accepts only `vm=1` ([karu_dec.v:736](../rtl/karu_dec.v#L736)), so no mask
  bit enters. `S_CREQ`..`S_CWR` branch on group activity, EGW and register
  index only ([:2994-3054](../rtl/karu_varith.v#L2994)). The `.vs` key-group
  selector is the instruction suffix: the effective `vs2` read address remains
  at register/granule zero for every destination group and has no operand-data
  dependency.
- Keccak: round count from `imm_q[0]` only ([:2255](../rtl/karu_varith.v#L2255));
  `cnt` decrements to zero ([keccak.v:78-92](../rtl/zvk/keccak.v#L78));
  load/store bounded by `KVGRP` ([:3061-3076](../rtl/karu_varith.v#L3061)).

## Empirical probe

A bare-metal M-mode firmware ([test/fw/diel_subj.c](../test/fw/diel_subj.c),
SHA-256 `c0c9be60d89b98bac746ef5d19f6fb77b514f2c3806770f063206f88ec808b10`,
built with the `test/fw` HTIF runtime and `flow/fp_subj.ld`; build line
below) times a fixed block
per instruction with `rdcycle` around 16 scalar or 4 vector copies, under
several operand-value classes, everything else held constant. Classes:
scalar pairs {0,0}, {1,1}, {~0,~0}, {2^63,2^63}, mixed random, {0,r}, {r,0},
{1,r}, {r,~0}, {r,63}, {r,1}, {2^32-1, ~(2^32-1)}; vector triples of
(`v0` group, source group, source/old-`vd` group) over zero, one, all-ones,
sign-bit, alternating, two pseudo-random and an FP-special pattern
(NaN, Inf, -Inf, subnormal, -0), with the `vx` scalar and `vf` scalar drawn
from the class. Each class is measured three times back to back and the
minimum taken, which removes the cold-I-cache first call (the raw dump shows
`sraw` at 81 cycles on its first call only, 71 thereafter; the block cycle
count otherwise varies only with code alignment, 65 versus 71 for identical
ALU ops).

215 tests: 48 scalar (all Zkt families, including `c.mul`, `c.not`,
`c.zext.b`, and a mixed RVC block), 116 vector at full `vl`, 12 at partial
`vl` (tail elements varied), 15 masked with a fixed mask (inactive elements
varied, `tu,mu` and `ta,ma`), 22 crypto-leaf and 2 Keccak (12 and 24
rounds, state zero/ones/random).

| Model (Verilator, `SIM_TB`, `HTIF_TB_XADR=22`) | Result |
| --- | --- |
| `KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64 KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64 KARU_V_LANE_PIPE KARU_V_CWB_STAGE KARU_SMCNTRPMF KARU_SSCOFPMF` (shipping profile) | **215/215 identical across classes** |
| same flags, probe built without the crypto/Keccak sections (`_build/Vhtif_rva23s64_smcntrpmf`) | 191/191 |
| `KARU_RVA23S64 KARU_ZVK KARU_KECCAK KARU_MUL_CYCLES=1 KARU_DIV_CYCLES=1` (combinational multipliers, no I-cache, no lane pipe / CWB stage) | **215/215 identical across classes** (`mul`×16 = 78, `vmul.vv` e64 m2 ×4 = 101, `vwmul.vv` ×4 = 133 cycles) |

Representative block counts on the shipping model, identical for every
class (16 scalar or 4 vector copies plus two `rdcycle`):

| Block | Cycles | Block | Cycles |
| --- | --- | --- | --- |
| `add`×16 | 65 | `vadd.vv` e64 m2 ×4 | 117 |
| `mul`×16 | 129 | `vmul.vv` e64 m2 ×4 | 661 |
| `mulh`×16 | 113 | `vmul.vv` e8 m2 ×4 | 4693 |
| `c.mv`+`c.mul` ×16 | 177 | `vwmul.vv` e32 m2 ×4 | 1269 |
| `rol`×16 | 71 | `vrgather.vv` e64 m2 ×4 | 133 |
| `czero.eqz`×16 | 71 | `vfslide1up.vf` e64 m2 ×4 | 165 |
| `vmadc.vvm` ×4 | 107 | `vaesem.vv` e32 m1 ×4 | 85 |
| `vmand.mm` ×4 | 77 | `vghsh.vv` e32 m1 ×4 | 221 |
| `vnsrl.wv` e32 m2 ×4 | 179 | `vkeccak.vi` 24 rounds ×4 | 323 |

Build and run the recorded shipping-profile measurement:

```sh
make diel-test-ship
```

The probe checks equality across operand classes only; it does not compare
against a predicted latency and does not exercise operand-fill or store-drain
interactions with preceding instructions, which are outside the DIEL
requirement.

## Inventory note

The ratified Zkt Zcb table includes `c.mul`, `c.not` and `c.zext.b`. All three
are traced and measured above. The serial-multiplier and permutation-engine
arguments were independently confirmed in this review.

## Functional follow-up

Two observations from the reads were functional or privileged-architecture
questions, not DIEL findings. Both are now resolved and have **no** bearing
on the latency result above:

- The `.vs` forms of `vaesem/vaesef/vaesdm/vaesdf/vaesz` and `vsm4r` decode to the
  same internal operation as `.vv`. The integration formerly advanced the
  effective `vs2` read address with the destination group. It now preserves
  the suffix through `f6_q`, compensates the crypto-private base as the group
  counter advances, and selects source granule zero. `make zvk-test-all` passes every
  affected AES/SM4 form at `vl=8,m1` and `vl=16,m2` on Karu and Spike;
  the exact shipping configuration also passes. The full DIEL probe was rerun
  after the correction: **215/215 PASS**, with the recorded cycle counts unchanged.
- Pointer masking is disabled whenever `mstatus.MXR` (or `vsstatus.MXR` in a
  guest) is set ([karu_csr.v:377-380](../rtl/karu_csr.v#L377),
  [karu64.v:1256](../rtl/karu64.v#L1256)). This is required by the ratified
  pointer-masking rules: when MXR applies at the effective privilege mode of
  an explicit memory access, pointer masking does not apply, including in Bare mode.

## Appendix: RVA23S64 mandatory-extension cross-check

Two further read-only passes checked decode and privileged state against the
profile list; this is an inventory, not certification. Every RVA23U64
mandatory extension has a decode path and an execution unit in the default
build, including the encodings that must not trap (`pause`, `ntl.*`,
`mop.*`, `c.mop.*`, `prefetch.*`), misaligned scalar and vector accesses,
Zcb, Zba/Zbb/Zbs, Zicbom/Zicbop/Zicboz with `menvcfg`/`senvcfg` gating,
Zfhmin, Zfa, Zawrs, Zvfhmin, Zvbb and Supm. Every RVA23S64 privileged item
has RTL: Ss1p13 CSR set and trap values, Sv39 with reserved-bit, PBMT,
NAPOT and Svade checks, Svinval, Sstc with `vstimecmp`, Sscofpmf,
Ssnpm, and the Sha set (H CSR banks, HLV/HSV/HLVX, two-stage walks with
guest-page-fault reporting, `hstateen`/`sstateen`, GEILEN=0).

Legal-but-notable choices recorded during the pass: misaligned atomics and
misaligned IO accesses raise access fault rather than address-misaligned;
`sfence`/`hfence` operands are ignored (full flush); `hvip[13]` is not
writeable without optional AIA/Smcdeleg, while Shlcofideleg uses the shared
`sip`/`sie` LCOFI pending bit;
`mseccfg` is absent; odd `pmpcfg` CSRs read zero on RV64 instead of
trapping (permitted without Ssstrict); `mhpmevent = 0` selects
`hpm_events[0]`, which must be tied low by the SoC.
