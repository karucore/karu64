# flow/fpga/floorplan_vector.tcl
# ============================================================================
# NEGATIVE EXPERIMENT — DO NOT enable by default. Kept only for reproducibility.
# ============================================================================
# Vector-writeback locality floorplan (KARU_FLOORPLAN=vector). Sourced by
# flow/fpga/xcvu9p-synth.tcl AFTER opt_design, BEFORE place_design.
#
# VERDICT (measured): this pblock REGRESSED timing. At 16 ns the unconstrained
# placer is already optimal for the writeback cone, and forcing the lane /
# writeback / VRF cluster into SLR1 only raised internal congestion (router
# level 5-6) without improving the worst path. It did NOT move the limiter and
# made WNS/TNS worse. The actual 16 ns / 10 ns wins came from RTL pipeline cuts
# (KARU_V_WB_STAGE, KARU_V_FPWB_STAGE — see doc/architecture.md), not
# placement. Leave KARU_FLOORPLAN unset; this file documents a dead end.
#
# HYPOTHESIS that motivated it (turned out wrong): the 16 ns worst path (varith
# vsew_q/lane -> wdata_hot, ~86% route) looked like a PLACEMENT-scatter problem.
# The placed checkpoint (vec_wbstage_place) showed the cluster smeared across
# SLR boundaries on xcvu9p (SLR0=CR Y0-4, SLR1=Y5-9, SLR2=Y10-14):
#     g_lane[0/1]    Y2..8   (straddles SLR0/SLR1)
#     grp_res_q_reg  Y3..5
#     wdata_hot_reg  Y7..9
#     vrf adapter+BRAM Y5..9 (BRAM at X2-3 Y6-9)
# so the lane -> grp_res_q -> wdata_hot path crossed the SLR0/1 boundary. The
# fix below pulls that cluster into SLR1 (CR Y5..Y9), co-located with the VRF
# BRAM, leaving the scalar core / IFU / MMU / LSU / FPU / cache / AXI free.
# Measured result: congestion up, slack down. Abandoned in favour of RTL staging.
# ============================================================================

#	---- p_varith_wb: lane producers + writeback + granule regs ----
set wb_cells [get_cells -hier -filter {
	NAME =~ {*/varith_u/g_lane[*} ||
	NAME =~ {*/varith_u/*wdata*}  ||
	NAME =~ {*/varith_u/*grp*}
}]
puts "FLOORPLAN: p_varith_wb gets [llength $wb_cells] cells"
create_pblock p_varith_wb
add_cells_to_pblock [get_pblocks p_varith_wb] $wb_cells
#	SLR1, left 5 columns -- generous (~3x the cluster's CLB need)
resize_pblock p_varith_wb -add {CLOCKREGION_X0Y5:CLOCKREGION_X4Y9}

#	---- p_vrf: BRAM VRF adapter + the BRAM columns, inside the same SLR ----
set vrf_cells [get_cells -hier -filter {NAME =~ {*/cpu/vrf/*}}]
puts "FLOORPLAN: p_vrf gets [llength $vrf_cells] cells"
create_pblock p_vrf
add_cells_to_pblock [get_pblocks p_vrf] $vrf_cells
#	RAMB-bearing columns where the BRAM already landed (X2-3), SLR1
resize_pblock p_vrf -add {CLOCKREGION_X2Y5:CLOCKREGION_X3Y9}

puts "FLOORPLAN: vector writeback pblocks created (p_varith_wb + p_vrf, SLR1)"
