#	hw_scan.tcl -- READ-ONLY JTAG scan: confirm the VCU118 is reachable.
#	Opens the hardware target and lists devices. Does NOT program anything.
open_hw_manager
connect_hw_server -url localhost:3121
set tgts [get_hw_targets]
puts "HW_TARGETS: $tgts"
if {[llength $tgts] == 0} { puts "ERROR: no hw_targets (board/JTAG not visible)"; exit 1 }
current_hw_target [lindex $tgts 0]
set_property PARAM.FREQUENCY 15000000 [get_hw_targets]
open_hw_target
set devs [get_hw_devices]
puts "HW_DEVICES: $devs"
current_hw_device [lindex $devs 0]
refresh_hw_device -update_hw_probes false [current_hw_device]
puts "DONE_PROP: [get_property REGISTER.IR.BIT6_DONE [current_hw_device]]"
puts "SCAN_OK"
close_hw_target
disconnect_hw_server
