//  karu_cfg.vh
//  Centralised resolution of the M / F / D mul/div cycle-count flags.
//
//  User-visible flags (set with -D on the build line or in karu_ext.vh):
//
//    Master multiplier cycle count (applies to M, F, D unless per-unit
//    overrides are set):
//      KARU_MUL_CYCLES = 1 | 4 | 16 | 64
//
//    Per-unit overrides (each unit has its own valid set; an out-of-set
//    value is clamped inside that unit's module):
//      KARU_M_MUL_CYCLES ∈ {1, 4, 16, 64}            integer M, 64-bit
//      KARU_F_MUL_CYCLES ∈ {1, 2, 3, 4, 6, 8, 12, 24} F mantissa, 24-bit
//      KARU_D_MUL_CYCLES ∈ {1, 53}                    D mantissa, 53-bit
//
//    Master divider cycle count (currently feeds the integer and vector
//    dividers only; F/D have separate radix knobs below):
//      KARU_DIV_CYCLES = 1 | 64
//
//    Per-unit integer divider override:
//      KARU_M_DIV_CYCLES ∈ {1, 64}
//
//  Resolution priority for each per-unit flag (highest first):
//      1. explicit per-unit define (e.g. KARU_F_MUL_CYCLES)
//      2. master flag (KARU_MUL_CYCLES or KARU_DIV_CYCLES)
//      3. default = 1 (combinational)
//
//  The modules read the resolved KARU_<unit>_MUL_CYCLES / DIV_CYCLES
//  defines directly (this header guarantees they are always defined).

`ifndef KARU_CFG_VH
`define KARU_CFG_VH

//  ======================================================================
//  BALANCED-FAST is the no-flags DEFAULT for SYNTH / ASIC builds:
//      MUL=4 DIV=64  V_MUL=16 V_DIV=64  => F_FMA=4, D_FMA=4
//      (the D mantissa knobs resolve to 4 and are clamped to bit-serial 53
//      inside karu_fmul_d / karu_ffma_d, i.e. EFFECTIVE D mul/FMA = 53 cycles)
//  Sim builds (-DSIM_TB) instead default to the COMBINATIONAL 1-cycle
//  reference -- fast sim + the documented benchmark baseline (a bit-serial
//  D default would make f64 TestFloat / fn-dsa ~50x slower). Any explicit
//  -D flag overrides either. Only CYCLE knobs default here; structural flags
//  (KARU_ZVK / KARU_KECCAK / ...) stay
//  explicit. Named build profiles depart from balanced via extra -D flags.
//  ======================================================================
//  Capture whether the USER set the master knobs (vs our balanced default
//  below) so an explicit master cascades to the vector mul too -- i.e.
//  KARU_MUL_CYCLES=1 really gives the all-combinational max-perf baseline
//  (V_MUL=1), while no-flags keeps the balanced V_MUL=16.
`ifdef KARU_MUL_CYCLES
    `define KARU_MUL_USER
`endif
`ifndef SIM_TB
    `ifndef KARU_MUL_CYCLES
        `define KARU_MUL_CYCLES 4
    `endif
    `ifndef KARU_DIV_CYCLES
        `define KARU_DIV_CYCLES 64
    `endif
`endif

//  ---------------------------------------------------------------- M
//  M multiplier
`ifndef KARU_M_MUL_CYCLES
    `ifdef KARU_MUL_CYCLES
        `define KARU_M_MUL_CYCLES `KARU_MUL_CYCLES
    `else
        `define KARU_M_MUL_CYCLES 1
    `endif
`endif

//  M divider
`ifndef KARU_M_DIV_CYCLES
    `ifdef KARU_DIV_CYCLES
        `define KARU_M_DIV_CYCLES `KARU_DIV_CYCLES
    `else
        `define KARU_M_DIV_CYCLES 1
    `endif
`endif

//  ---------------------------------------------------------------- F
`ifndef KARU_F_MUL_CYCLES
    `ifdef KARU_MUL_CYCLES
        `define KARU_F_MUL_CYCLES `KARU_MUL_CYCLES
    `else
        `define KARU_F_MUL_CYCLES 1
    `endif
`endif

//  ---------------------------------------------------------------- D
`ifndef KARU_D_MUL_CYCLES
    `ifdef KARU_MUL_CYCLES
        `define KARU_D_MUL_CYCLES `KARU_MUL_CYCLES
    `else
        `define KARU_D_MUL_CYCLES 1
    `endif
`endif

//  -------------------------------------------------- F / D FMA multiply
//  The FUSED-FMA mantissa multiply (karu_ffma 24x24, karu_ffma_d 53x53) is
//  serializable on the SAME radix-2^K / bit-serial engine as the standalone
//  multiply. This matters for an ASIC: there are no free DSP tiles, so every
//  combinational NxN product is permanent multiplier-array AREA -- the cycle
//  knob lets an area-driven build trade cycles for that area.
//
//  Resolution: KARU_F_FMA_CYCLES defaults to KARU_F_MUL_CYCLES, KARU_D_FMA_CYCLES
//  to KARU_D_MUL_CYCLES (both resolved just above), so the existing F/D multiply
//  flags cover FMA by default -- yet FMA can be dialed INDEPENDENTLY (fast fmul +
//  small ffma, or vice versa). The genuinely multiplier-array-FREE settings are
//  KARU_F_FMA_CYCLES=24 (K=1 => an AND, no `*`) and KARU_D_FMA_CYCLES=53 (bit
//  serial); intermediate N keeps a small KxN partial product that MAY still infer
//  a (smaller) DSP, exactly as the standalone KARU_F_MUL_CYCLES does today.
`ifndef KARU_F_FMA_CYCLES
    `define KARU_F_FMA_CYCLES `KARU_F_MUL_CYCLES
`endif
`ifndef KARU_D_FMA_CYCLES
    `define KARU_D_FMA_CYCLES `KARU_D_MUL_CYCLES
`endif

//  ------------------------------------------- F / D multiply PIPELINING
//  When the mantissa multiply is COMBINATIONAL (KARU_*_MUL_CYCLES == 1), the
//  whole unpack -> NxN multiply -> normalize/round cone is a single combinational
//  stage. The 53x53 D-mul fast path is the 125 MHz FPGA timing wall (it has no
//  internal register, so the tools cannot retime a pipelined DSP48 cascade into
//  it). KARU_*_MUL_PIPE inserts register stages around the multiply:
//      1 (default) : combinational fast path (latency 2) -- behaviour UNCHANGED.
//      >=2         : pipelined fast path (operand / multiply / round stages,
//                    clamped to >=3 stages), so the timing-driven flow packs a
//                    pipelined DSP cascade. The single-op handshake is preserved
//                    (busy stays high for the whole fill), so it is transparent
//                    to every consumer -- they wait on `done`. Results are
//                    bit-identical to the combinational path; only latency moves.
//  Orthogonal to the bit-serial BACKUP (KARU_*_MUL_CYCLES = 24/53), which is
//  unaffected by this knob.
`ifndef KARU_F_MUL_PIPE
    `define KARU_F_MUL_PIPE 1
`endif
`ifndef KARU_D_MUL_PIPE
    `define KARU_D_MUL_PIPE 1
`endif

//  ------------------------------------------------------- F / D dividers
//  karu_fdiv / karu_fdiv_d radix: quotient BITS PER CYCLE of the restoring
//  digit-recurrence. 1 = 1 bit/cycle (shortest critical path, most cycles) =
//  default; higher = fewer cycles but a wider per-cycle compare/subtract chain
//  (K chained subtracts). Latency ≈ ceil(Nfrac/this) + const, Nfrac = 55 (D) /
//  26 (F).
//
//  NOTE: this is deliberately INDEPENDENT of the integer `KARU_DIV_CYCLES`
//  (whose "1 = single combinational divide" semantics does not apply here).
//  An FP combinational divide is never generated.
`ifndef KARU_F_DIV_CYCLES
    `define KARU_F_DIV_CYCLES 1
`endif
`ifndef KARU_D_DIV_CYCLES
    `define KARU_D_DIV_CYCLES 1
`endif

//  ---------------------------------------------------------------- V
//  Vector divider (per-element): mirrors the M divider knob. 1 =
//  combinational (all elements of a register divided per cycle); >1 =
//  bit-serial shared divider, one element at a time (smallest area).
`ifndef KARU_V_DIV_CYCLES
    `ifdef KARU_DIV_CYCLES
        `define KARU_V_DIV_CYCLES `KARU_DIV_CYCLES
    `else
        `define KARU_V_DIV_CYCLES 1
    `endif
`endif

//  Vector multiplier (per-element): mirrors the M multiplier knob.
//  1 = combinational (all elements of a register multiplied per cycle);
//  >1 = bit-serial shared multiplier (radix-2^K shift-and-add, K=64/N),
//  one element at a time (smallest area). Allowed {1,4,16,64}.
`ifndef KARU_V_MUL_CYCLES
    `ifdef KARU_MUL_USER
        `define KARU_V_MUL_CYCLES `KARU_MUL_CYCLES  //  explicit master cascades to vector mul
    `elsif SIM_TB
        `define KARU_V_MUL_CYCLES 1                 //  sim default: combinational
    `else
        `define KARU_V_MUL_CYCLES 16                    //  synth/ASIC balanced default (area-controlled)
    `endif
`endif


`endif // KARU_CFG_VH
