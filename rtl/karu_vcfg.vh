//  karu_vcfg.vh
//  Vector (RVV 1.0) build-time configuration. Guarded so a non-vector
//  build (no KARU_V) is byte-identical to the scalar core.
//
//    KARU_VLEN   bits per vector register (v0..v31)
//    KARU_VBUS_W internal "vector bus" / VRF access granule width
//    KARU_ELEN   max element width (RVA23 requires 64)
//
//  VRF is flat: a v-register is KARU_VLEN contiguous bits accessed
//  KARU_VBUS_W bits at a time. Defaults: VLEN=256, VBUS=128, ELEN=64.

`ifndef KARU_VCFG_VH
`define KARU_VCFG_VH

`include "karu_ext.vh"                  //  F/D/V/K extension enables

`ifndef KARU_VLEN
`define KARU_VLEN   256
`endif
`ifndef KARU_VBUS_W
`define KARU_VBUS_W 128
`endif
`ifndef KARU_ELEN
`define KARU_ELEN   64
`endif
//  Vector-FP element lanes: how many scalar-FP datapaths (karu_fpu) run in
//  parallel in karu_vfpu. 1 = smallest (one element at a time). The per-element
//  FP multiplier is still bit-serial/full via the scalar KARU_F_MUL_CYCLES /
//  KARU_D_MUL_CYCLES knobs; this is the orthogonal vector area<->throughput lever.
`ifndef KARU_VF_LANES
`define KARU_VF_LANES 1
`endif

//  Derived
`define KARU_VLENB   (`KARU_VLEN / 8)           //  bytes per v-reg (vlenb CSR)
`define KARU_VBUS_B  (`KARU_VBUS_W / 8)         //  bytes per VRF granule
`define KARU_VGRAN   (`KARU_VLEN / `KARU_VBUS_W)    //  granules per v-reg
//  granule-index width (>=1; matches karu64's local VGW). VGRAN=2 -> 1 bit.
`define KARU_VGW     ((`KARU_VGRAN > 1) ? $clog2(`KARU_VGRAN) : 1)

//  Datapath lane count: the compute datapath tracks the VBUS_W-wide bus --
//  KARU_VRF_NLANES 64-bit lanes -- and a VLEN register is processed in
//  KARU_VGRAN granule passes (VLEN scales by cycle budget, not lane width).
`define KARU_VRF_NLANES (`KARU_VBUS_W / 64)

//  ---- macro-VRF collapse (2026-06-12) ----
//  The BRAM-backed macro VRF (karu_vrf_bram + the karu_vrf_bram_wr
//  sequencing adapter) with EXACT byte-enable writeback is the ONLY
//  datapath: the flop VRF (karu_vregfile) and the KARU_VRF_BRAM /
//  KARU_VRF_BWE knobs were deleted, along with their dependents
//  (KARU_V_WB_STAGE / KARU_V_FPWB_STAGE are compiled in; KARU_V_WB_PIPE
//  and KARU_V_WB2 are gone -- the former was incompatible with the exact
//  byte-enable compute, the latter was moot once the hot path wrote
//  granules). Keep-old is realised purely by byte enables; old-vd is read
//  only as a genuine operand (doc/architecture.md).

`endif // KARU_VCFG_VH
