#	gen_pcspma.tcl
#	=== Generate the Xilinx 1G Ethernet PCS/PMA IP for VCU118 SGMII over the
#	transceiver-less SelectIO/LVDS path (Ethernet datapath slice D1).
#
#	Clock decision (the D1 hard gate): the SGMII reference on AT22/AU22 is the
#	**DP83867's 625 MHz SGMII clock output**, NOT a 125 MHz board clock --
#	  - UG1224: FPGA AT22 = DP83867 (U7) PHY1_SGMIICLK_P (and AU22 = ..._N);
#	  - DP83867E/IS/CS datasheet: continuous 625 MHz differential SGMII clock out;
#	  - board file part0_pins.xml: SGMIICLK_P/N = AT22/AU22, LVDS.
#	=> CONFIG.LvdsRefClk = 625 (the IP also supports 125/156.25/312.5). We do NOT
#	hand-wire an external IBUFDS/MMCM: with SupportLevel=Include_Shared_Logic_in_Core
#	the generated wrapper owns the LVDS ref buffering / MMCM / reset. D1 inspects the
#	generated port model (refclk625_* vs refclk125_*) before any clocking is wired.
#
#	Management interface is OFF: the external DP83867 is managed by our own MDIO FSM
#	(flow/fpga/eth/karu_dp83867_mdio.v); SGMII AN uses the IP's config/status vectors.
#	SGMII_PHY_Mode=false => MAC-side PCS talking to an external PHY (our case).
#
#	Run:  make gen-pcspma
#	Output: _build/ip/gig_ethernet_pcs_pma_0 (read by the synth flow in a later slice).

source [file join [file dirname [file normalize [info script]]] .. vivado_paths.tcl]

set part  xcvu9p-flga2104-2L-e
set ipdir [karu_build_path ip]

file mkdir $ipdir
file delete -force $ipdir/gig_ethernet_pcs_pma_0
create_project -in_memory -part $part

catch {
	set bp [lindex [get_board_parts -quiet *vcu118*] 0]
	if {$bp ne ""} { set_property board_part $bp [current_project]; puts "gen_pcspma: board_part = $bp" }
}

set ipd [get_ipdefs -quiet *:ip:gig_ethernet_pcs_pma:*]
puts "gen_pcspma: gig_ethernet_pcs_pma ipdefs = $ipd"
if {$ipd eq ""} { puts "gen_pcspma: ERROR gig_ethernet_pcs_pma IP not found in this install"; exit 1 }

create_ip -name gig_ethernet_pcs_pma -vendor xilinx.com -library ip \
	-module_name gig_ethernet_pcs_pma_0 -dir $ipdir

if {[catch {
	set_property -dict [list \
		CONFIG.Standard               {SGMII} \
		CONFIG.Physical_Interface     {LVDS} \
		CONFIG.LvdsRefClk             {625} \
		CONFIG.Management_Interface   {false} \
		CONFIG.SupportLevel           {Include_Shared_Logic_in_Core} \
		CONFIG.SGMII_PHY_Mode         {false} \
		CONFIG.Auto_Negotiation       {true} \
		CONFIG.TxLane0_Placement      {DIFF_PAIR_2} \
		CONFIG.RxLane0_Placement      {DIFF_PAIR_0} \
		CONFIG.Tx_In_Upper_Nibble     {0} \
	] [get_ips gig_ethernet_pcs_pma_0]
} cfgerr]} {
	puts "gen_pcspma: ERROR config failed: $cfgerr"
	exit 1
}

foreach k {Standard Physical_Interface LvdsRefClk Management_Interface \
		   SupportLevel SGMII_PHY_Mode Auto_Negotiation MaxDataRate} {
	puts "gen_pcspma: CONFIG.$k = [get_property CONFIG.$k [get_ips gig_ethernet_pcs_pma_0]]"
}

if {[catch {generate_target all [get_ips gig_ethernet_pcs_pma_0]} generr]} {
	puts "gen_pcspma: ERROR generate_target failed: $generr"
	exit 1
}
puts "gen_pcspma: generated gig_ethernet_pcs_pma_0 under $ipdir"
