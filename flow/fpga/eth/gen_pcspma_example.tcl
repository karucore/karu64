#	gen_pcspma_example.tcl
#	=== Generate the gig_ethernet_pcs_pma_0 EXAMPLE DESIGN as the reference for the
#	SGMII-over-LVDS top-level wiring (the native UltraScale bitslice/RIU + IBUFDS
#	refclk + reset glue that _support.v exposes but does not encapsulate). We do NOT
#	build the example; we read its top to model vcu118_ddr_top's PCS instantiation
#	correctly. Output: _build/ip_example/.
source [file join [file dirname [file normalize [info script]]] .. vivado_paths.tcl]

create_project -in_memory -part xcvu9p-flga2104-2L-e
catch {
	set bp [lindex [get_board_parts -quiet *vcu118*] 0]
	if {$bp ne ""} { set_property board_part $bp [current_project] }
}
read_ip [karu_build_path ip gig_ethernet_pcs_pma_0 gig_ethernet_pcs_pma_0.xci]
if {[catch {open_example_project -force -in_process -dir [karu_build_path ip_example] [get_ips gig_ethernet_pcs_pma_0]} err]} {
	puts "gen_pcspma_example: ERROR $err"
	exit 1
}
puts "gen_pcspma_example: example design generated under [karu_build_path ip_example]"
