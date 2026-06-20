#	pcspma_probe.tcl -- READ-ONLY: confirm the Xilinx 1G Ethernet PCS/PMA IP is
#	available for this part and dump its config params (to find the SelectIO/LVDS
#	transceiver-less option for VCU118 SGMII). Generates nothing persistent.
create_project -in_memory -part xcvu9p-flga2104-2L-e
set ipds [get_ipdefs -all *:ip:gig_ethernet_pcs_pma:*]
puts "PCSPMA_IPDEFS: $ipds"
puts "ALL_ETH_IPDEFS: [get_ipdefs -all *ethernet*]"
if {[llength $ipds] == 0} {
	puts "NO_PCSPMA_IP"
} else {
	set ipd [lindex $ipds 0]
	puts "USING_IPDEF: $ipd"
	if {[catch {create_ip -vlnv $ipd -module_name pcspma_probe} err]} {
		puts "CREATE_IP_ERR: $err"
	} else {
		set ip [get_ips pcspma_probe]
		report_property -all $ip -file _build/pcspma_props.txt
		puts "WROTE _build/pcspma_props.txt"
	}
}
