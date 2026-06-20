#	flow/fpga/floorplan_mig.tcl
#	============================================================================
#	DISPROVEN EXPERIMENT (2026-06-16) — DO NOT enable. Kept for the record.
#	The hypothesis (vector mass crowds the MIG in SLR2 -> long MIG-internal routes ->
#	the +0.037 mmcm_clkout0 margin) was FALSIFIED by the corrected soft-pblock P&R:
#	fencing varith_u out of SLR2 left mmcm_clkout0 at **+0.003 (unchanged vs +0.037
#	baseline)** -> the MIG +0.037 path is INTRINSIC MIG-internal routing, NOT vector
#	crowding. Worse, it crashed cpu_clk to **-0.999 (10315 failing endpoints)** via the
#	varith<->vrf carry-chain split + core displacement. Net: floorplan can't raise the
#	MIG margin and badly hurts the core. The retained DDR4-2133 down-bin is an
#	explicit experimental custom-mode variant, not a default replacement. Leave
#	KARU_FLOORPLAN unset.
#	============================================================================
#	MIG breathing-room keepout (KARU_FLOORPLAN=mig). Sourced by
#	flow/fpga/xcvu9p-ddr-synth.tcl AFTER opt_design, BEFORE place_design.
#	============================================================================
#	GOAL (not achieved — see DISPROVEN banner above): raise the margin on the 300 MHz
#	MIG domain (mmcm_clkout0), which
#	is the binding clock for the DDR data path (WNS +0.037 at DDR4-2400) and the
#	prime suspect for load-correlated DDR corruption (the +0.037 ns AXI-CDC/cal
#	margin erodes under sustained-load PVT). The cpu_clk core sits at +0.286 and is
#	NOT the limiter; the cpu_clk notch would target the wrong clock.
#
#	ROOT CAUSE (from the routed-DCP placement probe, doc/fpga.md):
#	  - MIG (u_ddr4) is anchored at clock regions X4Y12..X4Y14 = SLR2 (DDR4 pins).
#	  - The 350k-cell vector mass (varith_u) SPILLS INTO SLR2 (X1..X4 Y10..Y13),
#	    crowding the MIG's neighborhood.
#	  - The worst mmcm_clkout0 path is MIG-INTERNAL cal logic (u_ddr_cal_top/...
#	    cplx_dqin_byte) at 91.7% route over 2 logic levels -> it routes the long
#	    way through a congested SLR2.
#
#	LEVER: fence varith_u OUT of SLR2 (into SLR0+SLR1 = Y0..Y9), leaving SLR2
#	clear for the MIG + its AXI converters + DDR4/SGMII IO so the MIG's internal
#	cal/AXI routing places compact and short -> margin on mmcm_clkout0.
#
#	WHY THIS != the backfired floorplan_vector.tcl (which REGRESSED timing): that
#	one CLUSTERED the writeback/VRF into a single SLR (Y5..Y9) -> congestion level
#	5-6. This one does the OPPOSITE -- it gives the vector mass TWO full SLRs
#	(X0Y0:X5Y9, ~788k LUTs for ~350k cells, ~44% util) and only EXCLUDES SLR2. It
#	is an A/B knob (KARU_FLOORPLAN=mig); unset => byte-identical (not sourced).
#	============================================================================

set vec_roots [get_cells -hier -filter {NAME =~ */varith_u}]
puts "FLOORPLAN-MIG: fencing [llength $vec_roots] varith_u hierarchy root(s) out of SLR2 (into SLR0+SLR1)"
if {[llength $vec_roots] == 0} {
	puts "FLOORPLAN-MIG: WARNING no varith_u hierarchy root matched -- pblock not created"
} else {
	if {[llength [get_pblocks -quiet p_vec_no_slr2]] != 0} {
		delete_pblocks [get_pblocks p_vec_no_slr2]
	}
	create_pblock p_vec_no_slr2
	#	Add the hierarchy root, not the 350k+ flattened primitive descendants.
	#	Flattening that list made add_cells_to_pblock effectively hang before
	#	placement; the pblock intent is the same at the hierarchy boundary.
	add_cells_to_pblock [get_pblocks p_vec_no_slr2] $vec_roots
	#	SLR0 + SLR1 = all clock-region rows Y0..Y9, full width X0..X5.
	resize_pblock p_vec_no_slr2 -add {CLOCKREGION_X0Y0:CLOCKREGION_X5Y9}
	#	SOFT pblock: a placement BIAS away from SLR2, NOT a hard containment. A HARD
	#	pblock over flattened varith primitives stalled Vivado before placement --
	#	too many cells to push through pblock Tcl. Soft lets the placer
	#	relax where needed, so it runs at normal speed/threading while still pulling the
	#	vector mass out of SLR2 to give the MIG room. (Routing unconstrained; the MIG
	#	and other non-member cells place freely.)
	set_property IS_SOFT TRUE [get_pblocks p_vec_no_slr2]
	puts "FLOORPLAN-MIG: p_vec_no_slr2 (SOFT) -> CLOCKREGION_X0Y0:CLOCKREGION_X5Y9 (SLR0+SLR1)"
}
