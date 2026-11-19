#	sysmon_constraints.tcl -- placement of the system monitor of
#	flow/fpga/karu_sysmon.v. Source it after synth_design and call
#	karu_constrain_sysmon.
#
#	The XCVU9P has one SYSMONE4 per SLR. The temperature readout is there to
#	go with the ring-oscillator captures, so its monitor is placed in the SLR
#	that holds the rings (their base slice, KARU_ROSC_BASE, default
#	"100 450"); without rings it is left to the placer. There must be exactly
#	one instance.

proc karu_constrain_sysmon {} {
	set mon [get_cells -quiet -hierarchical -filter {REF_NAME == SYSMONE4 || ORIG_REF_NAME == SYSMONE4}]
	if {[llength $mon] != 1} { error "karu_sysmon: expected one SYSMONE4, found [llength $mon]" }
	set base {100 450}
	if {[info exists ::env(KARU_ROSC_BASE)] && $::env(KARU_ROSC_BASE) ne ""} { set base $::env(KARU_ROSC_BASE) }
	lassign $base bx by
	set rings [get_cells -quiet -hierarchical -filter {ORIG_REF_NAME == karu_rosc_rng || REF_NAME == karu_rosc_rng}]
	if {[llength $rings] == 0} {
		puts "KARU_SYSMON_CONSTRAINTS no rings; monitor $mon left to the placer"
		return
	}
	set slr [get_slrs -of_objects [get_sites SLICE_X${bx}Y${by}]]
	set sites [get_sites -quiet -filter {SITE_TYPE == SYSMONE4} -of_objects $slr]
	if {[llength $sites] != 1} { error "karu_sysmon: expected one SYSMONE4 site in $slr, found [llength $sites]" }
	set_property LOC [lindex $sites 0] $mon
	puts "KARU_SYSMON_CONSTRAINTS monitor $mon at [lindex $sites 0] in $slr, with the rings"
}
