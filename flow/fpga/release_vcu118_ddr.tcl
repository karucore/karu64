#	release_vcu118_ddr.tcl
#	=== Release the VCU118 DDR bring-up CPU from VIO hold/reset.
#	ONLY for KARU_DDR_HOST_DBG builds. Default builds have no VIO host hold and
#	boot the CPU automatically after MIG calibration, so this script then finds
#	no host_ctl probe and exits.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

proc get_vio_probe {vio name} {
	set p [get_hw_probes -of_objects $vio $name]
	if {[llength $p] == 0} { return "" }
	return [lindex $p 0]
}

proc vio_status {vio} {
	refresh_hw_vio $vio
	set hold [get_vio_probe $vio host_cpu_hold]
	set rst  [get_vio_probe $vio rst_ui_sync]
	set cal  [get_vio_probe $vio led_o_OBUF]
	set ctl  [get_vio_probe $vio host_ctl]
	puts "VIO_STATUS calib=[get_property INPUT_VALUE $cal] cpu_rst=[get_property INPUT_VALUE $rst] hold=[get_property INPUT_VALUE $hold] host_ctl=[get_property OUTPUT_VALUE $ctl]"
}

open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set ltxfile [karu_env_build_path KARU_LTXFILE vcu118_ddr.ltx]
if {[file exists $ltxfile]} {
	set_property PROBES.FILE $ltxfile [current_hw_device]
	set_property FULL_PROBES.FILE $ltxfile [current_hw_device]
}
refresh_hw_device [current_hw_device]

#	Default (auto-boot) bitstreams have no VIO -- the CPU boots itself once MIG
#	calibrates, so there is nothing to release. Treat that as a clean no-op
#	(exit 0), not an error: a `release` after a default `prog` should not fail a
#	make target. Only a KARU_DDR_HOST_DBG bit holds the CPU and needs releasing.
set vios [get_hw_vios]
if {[llength $vios] == 0} {
	puts "release_vcu118_ddr: no VIO in this design -- default auto-boot bitstream, nothing to release (no-op)."
	exit 0
}
#	A VIO IS present but lacks host_ctl: this is NOT the expected default-bit case
#	(default bits have no VIO at all, handled above). It means the attached
#	vcu118_ddr.ltx is wrong/stale, or an unexpected VIO is in the design -- fail
#	loudly rather than silently "succeed" without releasing anything.
set vio [lindex $vios 0]
set ctl [get_vio_probe $vio host_ctl]
if {$ctl eq ""} {
	puts "release_vcu118_ddr: ERROR a VIO is present but has no host_ctl probe -- likely a wrong/stale vcu118_ddr.ltx or an unexpected VIO. Not releasing."
	exit 1
}

vio_status $vio
set_property OUTPUT_VALUE 0 $ctl
commit_hw_vio $vio
after 100
vio_status $vio
puts "CPU released."
