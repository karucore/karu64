#	xcvu9p-ddr-synth.tcl
#	=== Vivado non-project batch flow: karu64 DDR4 top -> VCU118 bitstream.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

set part	xcvu9p-flga2104-2L-e
set top		vcu118_ddr_top
set ipdir	[karu_build_path ip]

#	Shared report-archiving helper (config-tagged copies into
#	_build/fpga_rpt/ so each run's worst paths are retained, not clobbered).
source [karu_repo_path flow fpga karu_reports.tcl]

create_project -in_memory -part $part
catch {
	set bp [lindex [get_board_parts -quiet *vcu118*] 0]
	if {$bp ne ""} {
		set_property board_part $bp [current_project]
		puts "board_part: $bp"
	}
}

if {[info exists ::env(VIVADO_THREADS)]} {
	set_param general.maxThreads $::env(VIVADO_THREADS)
	puts "VIVADO_THREADS: $::env(VIVADO_THREADS)"
}

proc env_directive_args {env_name cmd_name} {
	if {[info exists ::env($env_name)] && $::env($env_name) ne ""} {
		puts "$env_name: $::env($env_name) ($cmd_name -directive)"
		return [list -directive $::env($env_name)]
	}
	return {}
}

proc env_truthy {env_name} {
	if {![info exists ::env($env_name)] || $::env($env_name) eq ""} {
		return 0
	}
	set v [string tolower $::env($env_name)]
	return [expr {$v ne "0" && $v ne "false" && $v ne "no"}]
}

set ddr4_custom_2133 [env_truthy KARU_DDR4_CUSTOM_2133]
if {$ddr4_custom_2133} {
	puts "KARU_DDR4_CUSTOM_2133: experimental custom-mode DDR4-2133 MIG enabled"
}

#	Optional Ethernet PHY front-end (E3 slice 1: DP83867 MDIO management). Enabled by
#	KARU_ETH_PHY in KARU_DEFINES; adds the front-end RTL + the management-pin XDC. The
#	SGMII PCS/PMA datapath is a later slice.
set eth_phy 0
if {[info exists ::env(KARU_DEFINES)] && [lsearch -exact $::env(KARU_DEFINES) KARU_ETH_PHY] >= 0} {
	set eth_phy 1
	puts "KARU_ETH_PHY: DP83867 MDIO front-end enabled"
}

#	Optional full SGMII datapath (E3 D2b): the 1G PCS/PMA (SelectIO/LVDS) + LiteEth GMII
#	core. KARU_ETH_SGMII REQUIRES KARU_ETH_PHY (the MDIO/reset front-end manages the PHY).
set eth_sgmii 0
if {[info exists ::env(KARU_DEFINES)] && [lsearch -exact $::env(KARU_DEFINES) KARU_ETH_SGMII] >= 0} {
	set eth_sgmii 1
	if {!$eth_phy} {
		puts "ERROR: KARU_ETH_SGMII requires KARU_ETH_PHY (DP83867 MDIO/reset front-end)"
		exit 1
	}
	puts "KARU_ETH_SGMII: 1G PCS/PMA + LiteEth GMII datapath enabled"
}

#	Optional DDR4-debug scaffold: VIO CPU-hold + JTAG-AXI host loader. Off by
#	default (the CPU auto-boots). Only included when KARU_DDR_HOST_DBG is in
#	KARU_DEFINES -- the same flag makes vcu118_ddr_top instantiate the VIO/loader/
#	mux, so the RTL design and the IP read list stay in lock-step. (Generate the
#	IPs with `KARU_DDR_HOST_DBG=1 make mig-vcu118`.)
set host_dbg 0
if {[info exists ::env(KARU_DEFINES)] && [lsearch -exact $::env(KARU_DEFINES) KARU_DDR_HOST_DBG] >= 0} {
	set host_dbg 1
	puts "KARU_DDR_HOST_DBG: VIO hold + JTAG-AXI host loader included"
}

set ip_list [list \
	$ipdir/ddr4_0/ddr4_0.xci \
	$ipdir/axi_clock_converter_0/axi_clock_converter_0.xci \
	$ipdir/axi_dwidth_converter_0/axi_dwidth_converter_0.xci \
]
if {$host_dbg} {
	lappend ip_list $ipdir/vio_0/vio_0.xci
	lappend ip_list $ipdir/jtag_axi_0/jtag_axi_0.xci
}
if {$eth_sgmii} {
	lappend ip_list $ipdir/gig_ethernet_pcs_pma_0/gig_ethernet_pcs_pma_0.xci
}
foreach ip $ip_list {
	if {![file exists $ip]} {
		puts "ERROR: missing IP $ip -- run `make mig-vcu118` (+ `make gen-pcspma` for SGMII) first"
		exit 1
	}
	read_ip $ip
}
generate_target all [get_ips]
synth_ip [get_ips]

#	core RTL (rtl/ plus optional rtl/zvk/) minus simulation-only files.
foreach fn [glob -type f [file join $::karu_repo_dir rtl *.v]] {
	if {[string match "*htif_tb.v"    $fn]} { continue }
	if {[string match "*_assert.v" $fn]} { continue }
	read_verilog $fn
}
foreach fn [glob -nocomplain -type f [file join $::karu_repo_dir rtl zvk *.v]] {
	read_verilog $fn
}

#	FPGA RTL (flow/fpga/) minus simulation-only testbenches and the non-DDR board top.
foreach fn [glob -type f [file join $::karu_repo_dir flow fpga *.v]] {
	if {[string match "*_tb.v"         $fn]} { continue }
	if {[string match "*vcu118_top.v"  $fn]} { continue }
	read_verilog $fn
}
#	LiteEth hardware MAC wrapper. Keep sim-only DPI/checker primitive shims out of
#	Vivado; the DDR board probe has no external MDIO pin, so the define below
#	removes the generated internal MDIO IOBUF from this build.
read_verilog [karu_repo_path flow fpga eth karu_eth.v]
if {$eth_sgmii} {
	#	SGMII datapath: the GMII LiteEth core (exactly one core; no MII loopback).
	read_verilog [karu_repo_path flow fpga eth liteeth_core_gmii.v]
} else {
	#	MII loopback core (sim/loopback bring-up).
	read_verilog [karu_repo_path flow fpga eth liteeth_core.v]
	read_verilog [karu_repo_path flow fpga eth eth_mii_loopback.v]
}
if {$eth_phy} {
	read_verilog [karu_repo_path flow fpga eth karu_dp83867_mdio.v]
	read_verilog [karu_repo_path flow fpga eth karu_eth_phy_fe.v]
}

read_xdc [karu_repo_path flow fpga vcu118_ddr.xdc]
if {$ddr4_custom_2133} {
	read_xdc [karu_repo_path flow fpga ddr4_custom vcu118_ddr4_c1_custom_2133.xdc]
}
if {$eth_phy} {
	read_xdc [karu_repo_path flow fpga eth dp83867_mdio_pins.xdc]
}
if {$eth_sgmii} {
	read_xdc [karu_repo_path flow fpga eth sgmii_pins.xdc]
	#	LiteEth GMII CDC, scoped to the MAC instance (sys<->eth async + multireg
	#	false-paths). NO create_clock here -- clk125 comes from the PCS.
	read_xdc -ref liteeth_core [karu_repo_path flow fpga eth liteeth_gmii_cdc.xdc]
}

#	DDR hardware builds always pay real instruction-memory latency, so keep the
#	IFU-side cache enabled by default. Testbench builds remain opt-in.
set vdefs {KARU_ETH_NO_MDIO_IOBUF KARU_ICACHE}
if {$ddr4_custom_2133} {
	lappend vdefs KARU_DDR4_CUSTOM_2133
}
if {[info exists ::env(KARU_DEFINES)]} {
	foreach d $::env(KARU_DEFINES) { lappend vdefs $d }
}

set dargs {}
if {[info exists ::env(KARU_SYNTH_DIRECTIVE)] && $::env(KARU_SYNTH_DIRECTIVE) ne ""} {
	set dargs [list -directive $::env(KARU_SYNTH_DIRECTIVE)]
	puts "KARU_SYNTH_DIRECTIVE: $::env(KARU_SYNTH_DIRECTIVE)"
}

if {[llength $vdefs] > 0} {
	puts "KARU_DEFINES: $vdefs"
	synth_design -part $part -top $top \
		-include_dirs [list [karu_repo_path rtl] [karu_repo_path rtl zvk] [karu_repo_path flow fpga]] \
		-verilog_define $vdefs {*}$dargs
} else {
	synth_design -part $part -top $top \
		-include_dirs [list [karu_repo_path rtl] [karu_repo_path rtl zvk] [karu_repo_path flow fpga]] \
		{*}$dargs
}

if {$eth_sgmii} {
	puts "=== SGMII clock check (post-synth): expect the 625 MHz refclk + 125 MHz GMII ==="
	report_clocks            -file [karu_rpt_path vcu118_ddr_sgmii_clocks.rpt]
	report_clock_interaction -file [karu_rpt_path vcu118_ddr_sgmii_clock_interaction.rpt]
	check_timing -verbose    -file [karu_rpt_path vcu118_ddr_sgmii_check_timing.rpt]
}

set synth_reports [list \
	[karu_rpt_path vcu118_ddr_synth_util.rpt] \
	[karu_rpt_path vcu118_ddr_synth_timing.rpt] \
	[karu_rpt_path vcu118_ddr_synth_worstpaths.rpt] \
	[karu_rpt_path vcu118_ddr_synth_longest_paths.rpt] \
]

report_utilization              -file [lindex $synth_reports 0]
report_timing_summary           -file [lindex $synth_reports 1]
report_timing -max_paths 30 -nworst 30 -path_type full_clock_expanded \
                                -file [lindex $synth_reports 2]
report_timing -max_paths 100 -nworst 100 -sort_by slack -path_type full_clock_expanded \
                                -file [lindex $synth_reports 3]
write_checkpoint -force [karu_build_path vcu118_ddr_synth.dcp]

#	Retain this run's post-synth reports under a config tag (KARU_REPORT_TAG,
#	else the design top). Done here too so SYNTH_ONLY feasibility runs archive.
set rtag [karu_report_tag $top]
karu_archive_reports $rtag $synth_reports

if {[info exists ::env(KARU_SYNTH_ONLY)] && $::env(KARU_SYNTH_ONLY) ne ""} {
	puts "KARU_SYNTH_ONLY set -- stopping after synthesis (skipping P&R)."
	return
}

set opt_args      [env_directive_args KARU_OPT_DIRECTIVE      opt_design]
set place_args    [env_directive_args KARU_PLACE_DIRECTIVE    place_design]
set phys_opt_args [env_directive_args KARU_PHYS_OPT_DIRECTIVE phys_opt_design]
set route_args    [env_directive_args KARU_ROUTE_DIRECTIVE    route_design]

opt_design {*}$opt_args
#	Optional floorplan, applied after opt (cells exist) and before place. KARU_FLOORPLAN=mig
#	fences the vector mass out of SLR2 to de-congest the MIG's 300 MHz domain (see
#	flow/fpga/floorplan_mig.tcl). Unset => not sourced => byte-identical placement.
if {[info exists ::env(KARU_FLOORPLAN)] && $::env(KARU_FLOORPLAN) eq "mig"} {
	set fp [karu_repo_path flow fpga floorplan_mig.tcl]
	puts "KARU_FLOORPLAN=mig -- sourcing $fp"
	source $fp
}
place_design {*}$place_args
#	Save the placed checkpoint so a route failure (e.g. the native-LVDS SGMII bitslice)
#	is diagnosable (report_route_status / report_io) without re-placing.
write_checkpoint -force [karu_build_path vcu118_ddr_postplace.dcp]
phys_opt_design {*}$phys_opt_args
route_design {*}$route_args
set route_slack [get_property SLACK [get_timing_paths -delay_type min_max]]
if {$route_slack < 0 || [env_truthy KARU_POST_ROUTE_PHYS_OPT]} {
	if {$route_slack >= 0} {
		puts "KARU_POST_ROUTE_PHYS_OPT set -- running post-route phys_opt_design despite non-negative slack ($route_slack ns)."
	}
	phys_opt_design {*}$phys_opt_args
}

set route_reports [list \
	[karu_rpt_path vcu118_ddr_utilization.rpt] \
	[karu_rpt_path vcu118_ddr_timing.rpt] \
	[karu_rpt_path vcu118_ddr_route_worstpaths.rpt] \
	[karu_rpt_path vcu118_ddr_route_longest_paths.rpt] \
	[karu_rpt_path vcu118_ddr_bus_skew.rpt] \
]

report_utilization              -file [lindex $route_reports 0]
report_timing_summary           -file [lindex $route_reports 1]
report_timing -max_paths 30 -nworst 30 -path_type full_clock_expanded \
                                -file [lindex $route_reports 2]
report_timing -max_paths 100 -nworst 100 -sort_by slack -path_type full_clock_expanded \
                                -file [lindex $route_reports 3]
report_bus_skew                 -file [lindex $route_reports 4]
write_checkpoint -force [karu_build_path vcu118_ddr_route.dcp]
write_debug_probes -force [karu_build_path vcu118_ddr.ltx]

#	Retain this run's post-route reports under the same config tag.
karu_archive_reports $rtag $route_reports

write_bitstream -force [karu_build_path vcu118_ddr.bit]
