#	hw_probes.tcl -- READ-ONLY: dump every VIO probe + value (to find what HW state
#	is queryable over JTAG, e.g. the eth PHY id_ok). Does not change any output.
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
foreach vio [get_hw_vios] {
	refresh_hw_vio $vio
	puts "=== VIO [get_property NAME $vio] ==="
	foreach p [get_hw_probes -of_objects $vio] {
		puts "PROBE: [get_property NAME $p]  IN=[get_property INPUT_VALUE $p]"
	}
}
close_hw_target
disconnect_hw_server
