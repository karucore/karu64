//  karu_ext.vh
//  High-level RTL configuration: ISA-extension enable resolution plus the
//  system/board knobs, kept in one configuration header.
//
//  Base core is RV64I. The C, A, M, B, F, D and V extensions are individually
//  pluggable. Vector crypto (Zvk*) is opt-IN, scoped by its own KARU_ZVK*
//  flags in the section further down. Privilege and profiling features are
//  also build-time scoped for area studies. KARU_H enables the implemented
//  H/two-stage-translation block; it alone does not select the Sha/profile
//  composition or establish complete architectural/platform certification.
//  KARU_RVA23S64 opts into the mandatory-feature build composition below;
//  it is not a platform/compliance certification or a new release default.
//
//  Default: all extensions ENABLED unless the build command opts out. Opt OUT
//  on the build line with any of:
//      -DKARU_NO_C   drop the C extension (compressed instructions)
//      -DKARU_NO_A   drop the A extension (atomics)
//      -DKARU_NO_M   drop the M extension (multiply/divide)
//      -DKARU_NO_B   drop scalar Zba/Zbb/Zbs bit-manipulation
//      -DKARU_NO_F   drop the F extension (single-precision FP)
//      -DKARU_NO_D   drop the D extension (double-precision FP)
//      -DKARU_NO_V   drop the V extension (vector; also drops Zvk* crypto)
//      -DKARU_NO_ZVBB drop full Zvbb from an otherwise normal V build
//      -DKARU_NO_S   drop S-mode/Sv39 (M/U privilege only; no MMU walkers)
//      -DKARU_NO_HPM drop mhpmcounter3..31/mhpmevent3..31
//      -DKARU_NO_MEM drop scalar L1/cache wrapper in non-vector builds
//
//  Dependency chain  V  >  D  >  F
//  (the RVA23 "V" = Zve64d needs double; double needs single; the opt-in Zvk*
//   crypto leaves need V). Disabling a lower extension cascades upward:
//      KARU_NO_F  ==> also drops D, V
//      KARU_NO_D  ==> also drops V
//
//  The RTL checks ONLY the canonical positive defines resolved here:
//      KARU_EN_C / KARU_EN_A / KARU_EN_M / KARU_EN_B / KARU_EN_F / KARU_EN_D
//      KARU_EN_V / KARU_EN_S / KARU_EN_H / KARU_EN_HPM / KARU_EN_MEM
//      KARU_EN_ZVBB / KARU_EN_ZVKB
//  Never test KARU_NO_* directly in the RTL.

`ifndef KARU_EXT_VH
`define KARU_EXT_VH

//  ======================================================================
//  System / board configuration
//  ======================================================================
//  KARU_ASIC removes FPGA power-up values from RAM/register-file storage and
//  the v0 shadow, and excludes FPGA RAM inference attributes. It does not
//  change memory read latency or instantiate a foundry macro. Architectural
//  control reset remains required; unreset data must be written before use.
`timescale  1 ns / 1 ps
`default_nettype none

//  --- opt-in RVA23S64 build contract ---
//  Ratified profile: riscv/riscv-profiles, src/rva23-profile.adoc,
//  "RVA23S64 Mandatory Extensions". The default baseline supplies the U64
//  instruction leaves, Zifencei and S-mode mechanisms. Sha additionally needs
//  H (which enables Ssstateen below), and S64 requires Sscofpmf. Do not silently
//  override an ISA opt-out and produce a configuration with a misleading name.
//  PMA, progress, DIEL, complete privilege behavior and platform certification
//  remain independent validation obligations; this switch only binds knobs.
//  Zvk, draft Keccak and Smcntrpmf are optional and are NOT implied here.
//  RV64 is structural; karu64 checks the validated VLEN256/ELEN64/VBUS128 geometry.
`ifdef KARU_RVA23S64
    `ifdef KARU_NO_C
        `error "KARU_RVA23S64 conflicts with KARU_NO_C"
    `endif
    `ifdef KARU_NO_A
        `error "KARU_RVA23S64 conflicts with KARU_NO_A"
    `endif
    `ifdef KARU_NO_M
        `error "KARU_RVA23S64 conflicts with KARU_NO_M"
    `endif
    `ifdef KARU_NO_B
        `error "KARU_RVA23S64 conflicts with KARU_NO_B"
    `endif
    `ifdef KARU_NO_F
        `error "KARU_RVA23S64 conflicts with KARU_NO_F"
    `endif
    `ifdef KARU_NO_D
        `error "KARU_RVA23S64 conflicts with KARU_NO_D"
    `endif
    `ifdef KARU_NO_V
        `error "KARU_RVA23S64 conflicts with KARU_NO_V"
    `endif
    `ifdef KARU_NO_ZVBB
        `error "KARU_RVA23S64 conflicts with KARU_NO_ZVBB"
    `endif
    `ifdef KARU_NO_S
        `error "KARU_RVA23S64 conflicts with KARU_NO_S"
    `endif
    `ifdef KARU_NO_HPM
        `error "KARU_RVA23S64 conflicts with KARU_NO_HPM (Sscofpmf requires HPM)"
    `endif
    `ifndef KARU_H
        `define KARU_H
    `endif
    `ifndef KARU_SSCOFPMF
        `define KARU_SSCOFPMF
    `endif
`endif

//  --- cascade the opt-outs downward (V > D > F) ---
`ifdef KARU_NO_F
    `ifndef KARU_NO_D
        `define KARU_NO_D
    `endif
`endif
`ifdef KARU_NO_D
    `ifndef KARU_NO_V
        `define KARU_NO_V
    `endif
`endif

//  --- canonical positive enables (RTL uses these) ---
`ifndef KARU_NO_C
    `define KARU_EN_C
`endif
`ifndef KARU_NO_A
    `define KARU_EN_A
`endif
`ifndef KARU_NO_M
    `define KARU_EN_M
`endif
`ifndef KARU_NO_B
    `define KARU_EN_B
`endif
`ifndef KARU_NO_F
    `define KARU_EN_F
`endif
`ifndef KARU_NO_D
    `define KARU_EN_D
`endif
`ifndef KARU_NO_V
    `define KARU_EN_V
`endif
`ifndef KARU_NO_S
    `define KARU_EN_S
`endif
// karu64 has fixed RV64 privilege state. Guest development requires the
// supervisor machinery and automatically includes the state-enable hierarchy.
`ifdef KARU_H
    `ifdef KARU_EN_S
        `define KARU_EN_H
        `define KARU_EN_SSTATEEN
    `else
        `error "KARU_H requires supervisor support; remove KARU_NO_S"
    `endif
`endif
`ifndef KARU_NO_HPM
    `define KARU_EN_HPM
`endif
`ifdef KARU_EN_V
    `define KARU_EN_MEM
`else
    `ifndef KARU_NO_MEM
        `define KARU_EN_MEM
    `endif
`endif

//  --- Zvknhk single-instruction Keccak-p[1600] (`vkeccak.vi`, riscv-pqc) ---
//  Opt-IN only (default OFF): the 1600-bit round datapath is large and the
//  extension is still a draft (riscv-pqc zvknhk.adoc), so it is never in a
//  default build. Enable with -DKARU_KECCAK. Needs the vector unit (VRF +
//  group access), so it is suppressed when V is compiled out.
`ifdef KARU_KECCAK
    `ifndef KARU_NO_V
        `define KARU_EN_KECCAK
    `endif
`endif

//  --- Zvbb/Zvkb vector bit-manipulation ---
//  Full Zvbb is part of RVA23U64 and is therefore present in every normal V
//  build.  -DKARU_NO_ZVBB is the area-isolation opt-out; -DKARU_ZVKB can be
//  combined with it to retain only the smaller crypto bit-manipulation subset.
//  Zvbb is a strict superset of Zvkb, so its internal enable also enables the
//  shared Zvkb lane operations.
`ifndef KARU_NO_V
    `ifndef KARU_NO_ZVBB
        `define KARU_EN_ZVBB
    `endif
    `ifdef KARU_EN_ZVBB
        `define KARU_EN_ZVKB
    `endif
`endif

//  --- standard Zvk vector-crypto leaves ---
//  Opt-IN only (default OFF), like KARU_KECCAK. The coarse -DKARU_ZVK umbrella
//  enables all implemented standard leaves. Each official leaf can also be
//  enabled independently:
//      -DKARU_ZVKNED   AES
//      -DKARU_ZVKNHA   SHA-256
//      -DKARU_ZVKNHB   SHA-256 + SHA-512 (implies Zvknha)
//      -DKARU_ZVKSED   SM4
//      -DKARU_ZVKSH    SM3
//      -DKARU_ZVKG     GHASH/GCM
//      -DKARU_ZVKB     vandn/vbrev8/vrev8/vrol/vror only (normally already
//                      supplied by default-on Zvbb)
//  Needs V; all are suppressed when V is compiled out. KARU_EN_ZVK is the
//  aggregate "any standard Zvk *crypto* leaf is present" define used for the
//  shared karu_vcrypto plumbing. Zvkb deliberately does NOT imply KARU_EN_ZVK:
//  its ops are plain lane-ALU element ops and need none of that plumbing.
`ifndef KARU_NO_V
    `ifdef KARU_ZVK
        `define KARU_EN_ZVKNED
        `define KARU_EN_ZVKNHA
        `define KARU_EN_ZVKNHB
        `define KARU_EN_ZVKSED
        `define KARU_EN_ZVKSH
        `define KARU_EN_ZVKG
        `ifndef KARU_EN_ZVKB
            `define KARU_EN_ZVKB
        `endif
    `endif
    `ifdef KARU_ZVKB
        `ifndef KARU_EN_ZVKB
            `define KARU_EN_ZVKB
        `endif
    `endif
    `ifdef KARU_ZVKNED
        `define KARU_EN_ZVKNED
    `endif
    `ifdef KARU_ZVKNHA
        `define KARU_EN_ZVKNHA
    `endif
    `ifdef KARU_ZVKNHB
        `define KARU_EN_ZVKNHB
        `define KARU_EN_ZVKNHA
    `endif
    `ifdef KARU_ZVKSED
        `define KARU_EN_ZVKSED
    `endif
    `ifdef KARU_ZVKSH
        `define KARU_EN_ZVKSH
    `endif
    `ifdef KARU_ZVKG
        `define KARU_EN_ZVKG
    `endif
`endif
`ifdef KARU_EN_ZVKNED
    `define KARU_EN_ZVK
`endif
`ifdef KARU_EN_ZVKNHA
    `define KARU_EN_ZVK
`endif
`ifdef KARU_EN_ZVKNHB
    `define KARU_EN_ZVK
`endif
`ifdef KARU_EN_ZVKSED
    `define KARU_EN_ZVK
`endif
`ifdef KARU_EN_ZVKSH
    `define KARU_EN_ZVK
`endif
`ifdef KARU_EN_ZVKG
    `define KARU_EN_ZVK
`endif

//  --- Smstateen / Ssstateen (state-enable) ---
//  Opt-IN only (default OFF; keeps all current builds byte-identical). Adds
//  mstateen0(0x30C)/sstateen0(0x10C) and traps lower-privilege access to the
//  extension CSR state they gate (today: senvcfg via ENVCFG, sstateen0 via SE0).
//  Needs S-mode (it gates S/U access), so it is suppressed when S is compiled out.
`ifdef KARU_SSTATEEN
    `ifdef KARU_EN_S
        `ifndef KARU_EN_SSTATEEN
            `define KARU_EN_SSTATEEN
        `endif
    `endif
`endif

//  --- Smcntrpmf (counter privilege-mode filtering) ---
//  Opt-IN only (default OFF). mcyclecfg(0x321)/minstretcfg(0x322) add per-privilege
//  inhibit bits (MINH/SINH/UINH) to the fixed mcycle/minstret counters, so a
//  lower-privilege rdcycle/rdinstret can be made to count only its own mode. The
//  cfg CSRs are M-mode; no hard S dependency (SINH is moot without S).
`ifdef KARU_SMCNTRPMF
    `define KARU_EN_SMCNTRPMF
`endif

//  --- Sscofpmf (counter-overflow + privilege filtering for the programmable HPM counters) ---
//  Opt-IN only (default OFF). Adds OF(overflow) + MINH/SINH/UINH inhibit bits to
//  mhpmevent3..31, the read-only scountovf(0xDA0) OF bitmap, and the LCOFI local
//  count-overflow interrupt (mip/mie bit 13). Needs the HPM counters.
`ifdef KARU_SSCOFPMF
    `ifdef KARU_EN_HPM
        `define KARU_EN_SSCOFPMF
    `endif
`endif

`endif // KARU_EXT_VH
