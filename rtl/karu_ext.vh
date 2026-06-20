//  karu_ext.vh
//  Build-time ISA-extension enable resolution.
//
//  Base core is RV64IC (I + C). The A, M, B, F, D, V and K
//  (vector-crypto, Zvk*) extensions are individually pluggable. Privilege
//  and profiling features are also build-time scoped for area studies.
//
//  Default: all extensions ENABLED unless config.vh or the build command opts
//  out. Opt OUT on the build line with any of:
//      -DKARU_NO_A   drop the A extension (atomics)
//      -DKARU_NO_M   drop the M extension (multiply/divide)
//      -DKARU_NO_B   drop scalar Zba/Zbb/Zbs bit-manipulation
//      -DKARU_NO_F   drop the F extension (single-precision FP)
//      -DKARU_NO_D   drop the D extension (double-precision FP)
//      -DKARU_NO_V   drop the V extension (vector)
//      -DKARU_NO_K   drop the K extension (vector crypto, Zvk*)
//      -DKARU_NO_S   drop S-mode/Sv39 (M/U privilege only; no MMU walkers)
//      -DKARU_NO_HPM drop mhpmcounter3..31/mhpmevent3..31
//      -DKARU_NO_MEM drop scalar L1/cache wrapper in non-vector builds
//
//  Dependency chain  K  >  V  >  D  >  F
//  (vector-crypto needs vectors; the RVA23 "V" = Zve64d needs double;
//   double needs single). Disabling a lower extension cascades upward:
//      KARU_NO_F  ==> also drops D, V, K
//      KARU_NO_D  ==> also drops V, K
//      KARU_NO_V  ==> also drops K
//
//  The RTL checks ONLY the canonical positive defines resolved here:
//      KARU_EN_A / KARU_EN_M / KARU_EN_B / KARU_EN_F / KARU_EN_D / KARU_EN_V
//      KARU_EN_K / KARU_EN_S / KARU_EN_HPM / KARU_EN_MEM
//  Never test KARU_NO_* directly in the RTL.

`ifndef KARU_EXT_VH
`define KARU_EXT_VH

//  --- cascade the opt-outs downward (K > V > D > F) ---
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
`ifdef KARU_NO_V
    `ifndef KARU_NO_K
        `define KARU_NO_K
    `endif
`endif

//  --- canonical positive enables (RTL uses these) ---
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
`ifndef KARU_NO_K
    `define KARU_EN_K
`endif
`ifndef KARU_NO_S
    `define KARU_EN_S
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

//  --- experimental Zvknhk single-instruction Keccak-f1600 (`vkeccak`) ---
//  Opt-IN only (default OFF): the 1600-bit round datapath is large and the
//  encoding is a non-standard custom opcode, so it is never in a default
//  build. Enable with -DKARU_KECCAK. Needs the vector unit (VRF + group
//  access), so it is suppressed when V is compiled out.
`ifdef KARU_KECCAK
    `ifndef KARU_NO_V
        `define KARU_EN_KECCAK
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
//      -DKARU_ZVKB     vandn/vbrev8/vrev8/vrol/vror (bit-manip glue; the leaf
//                      that completes the official Zvkn/Zvks profiles)
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
        `define KARU_EN_ZVKB
    `endif
    `ifdef KARU_ZVKB
        `define KARU_EN_ZVKB
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
        `define KARU_EN_SSTATEEN
    `endif
`endif

//  --- Smcntrpmf (counter privilege-mode filtering) ---
//  Opt-IN only (default OFF). mcyclecfg(0x321)/minstretcfg(0x322) add per-privilege
//  inhibit bits (MINH/SINH/UINH) to the fixed mcycle/minstret counters, so a
//  lower-privilege rdcycle/rdinstret can be made to count only its own mode (the
//  user-only-count fix). The cfg CSRs are M-mode; no hard S dependency (SINH is moot
//  without S).
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
