#	prog_vcu118_ddr.tcl
#	=== Program the VCU118 DDR4 bring-up bitstream and debug probes.
#	Default builds boot the CPU automatically once MIG calibration completes --
#	no VIO release step is needed after programming. The legacy hold/release
#	(release_vcu118_ddr.tcl) only applies to KARU_DDR_HOST_DBG builds.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

set bitfile [karu_env_build_path KARU_BITFILE vcu118_ddr.bit]
set ltxfile [karu_env_build_path KARU_LTXFILE vcu118_ddr.ltx]

if {![file exists $bitfile]} {
	puts "ERROR: missing $bitfile -- run make vcu118-ddr first"
	exit 1
}

open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [lindex [get_hw_targets] 0]
set_property PARAM.FREQUENCY 15000000 [get_hw_targets]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE $bitfile [current_hw_device]
if {[file exists $ltxfile]} {
	set_property PROBES.FILE $ltxfile [current_hw_device]
	set_property FULL_PROBES.FILE $ltxfile [current_hw_device]
}
program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]
