#	bounce_cpu.tcl -- pulse host_ctl 1->0 to reset the CPU back into the monitor
#	(re-emits the fu-boot banner). Read-only otherwise.
open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
if {[file exists vcu118_ddr.ltx]} {
	set_property PROBES.FILE vcu118_ddr.ltx [current_hw_device]
	set_property FULL_PROBES.FILE vcu118_ddr.ltx [current_hw_device]
}
refresh_hw_device [current_hw_device]
set vio [lindex [get_hw_vios] 0]
set ctl [lindex [get_hw_probes -of_objects $vio host_ctl] 0]
set_property OUTPUT_VALUE 1 $ctl; commit_hw_vio $vio
after 300
set_property OUTPUT_VALUE 0 $ctl; commit_hw_vio $vio
puts "BOUNCED"
