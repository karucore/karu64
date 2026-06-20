#	ila_writepath_insert.tcl
#	Insert a write-path ILA into an existing vcu118 DDR synth checkpoint.
#
#	Default use:
#	    make vcu118-ddr-ila-writepath
#
#	Inputs/outputs can be overridden:
#	    ILA_IN_DCP=vcu118_ddr_synth.dcp       ;# relative paths resolve under _build
#	    ILA_OUT_DCP=vcu118_ddr_ila_synth.dcp
#	    ILA_IMPL=1                  ;# run opt/place/route and write bit/ltx
#	    ILA_DEPTH=1024
#	    ILA_INPUT_PIPE_STAGES=2
#	    ILA_PROFILE=threshold        ;# threshold or full
#	    ILA_MIG_WDATA_BITS=64       ;# allowed: 64, 128, 256, 512
#
#	The default threshold profile is intentionally tiny and ui_clk-centered:
#	MIG AW address/handshake plus a few context bits. Trigger in Hardware Manager on e.g.
#	    mig_awvalid && mig_awready && mig_awaddr[30:29] == 2'b11
#	when Linux is booted with mem=1536M (top 512 MiB reserved).
#	Set ILA_PROFILE=full only after the threshold catcher meets timing; full adds
#	c_* and data/strobe probes for converter-boundary correlation.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

proc env_default {name def} {
	if {[info exists ::env($name)] && $::env($name) ne ""} {
		return $::env($name)
	}
	return $def
}

proc env_truthy {name} {
	if {![info exists ::env($name)]} { return 0 }
	set v [string tolower $::env($name)]
	return [expr {$v ne "" && $v ne "0" && $v ne "false" && $v ne "no"}]
}

proc one_net {name} {
	set nets [get_nets -quiet $name]
	if {[llength $nets] != 1} {
		puts "ERROR: expected one net '$name', got [llength $nets]"
		exit 1
	}
	return [lindex $nets 0]
}

proc bus_nets {name msb lsb} {
	set out {}
	for {set i $lsb} {$i <= $msb} {incr i} {
		set n [get_nets -quiet ${name}\[$i\]]
		if {[llength $n] != 1} {
			puts "ERROR: expected one net '${name}\[$i\]', got [llength $n]"
			exit 1
		}
		lappend out [lindex $n 0]
	}
	return $out
}

proc add_probe {core idx nets label} {
	set port ${core}/probe${idx}
	set_property port_width [llength $nets] [get_debug_ports $port]
	connect_debug_port $port $nets
	puts "ILA probe${idx}: width=[llength $nets] $label"
}

set in_dcp  [karu_env_build_path ILA_IN_DCP  "vcu118_ddr_synth.dcp"]
set out_dcp [karu_env_build_path ILA_OUT_DCP "vcu118_ddr_ila_synth.dcp"]
set depth   [env_default ILA_DEPTH   "1024"]
set pipe_stages [env_default ILA_INPUT_PIPE_STAGES "2"]
set profile [string tolower [env_default ILA_PROFILE "threshold"]]
set mig_wdata_bits [env_default ILA_MIG_WDATA_BITS "64"]
if {$profile ni {threshold full}} {
	puts "ERROR: ILA_PROFILE must be one of: threshold full"
	exit 1
}
if {$mig_wdata_bits ni {64 128 256 512}} {
	puts "ERROR: ILA_MIG_WDATA_BITS must be one of: 64 128 256 512"
	exit 1
}

open_checkpoint $in_dcp

set core u_ila_writepath
create_debug_core $core ila
set_property C_DATA_DEPTH $depth [get_debug_cores $core]
set_property C_INPUT_PIPE_STAGES $pipe_stages [get_debug_cores $core]
set_property C_TRIGIN_EN false [get_debug_cores $core]
set_property C_TRIGOUT_EN false [get_debug_cores $core]
set_property C_ADV_TRIGGER true [get_debug_cores $core]
if {$profile eq "threshold"} {
	set nprobes 4
} else {
	set nprobes 14
}
for {set i 1} {$i < $nprobes} {incr i} {
	create_debug_port $core probe
}
connect_debug_port ${core}/clk [one_net ui_clk]

if {$profile eq "threshold"} {
	add_probe $core 0 [bus_nets mig_awaddr 30 0] "mig_awaddr[30:0]"
	add_probe $core 1 [list [one_net mig_awvalid] [one_net mig_awready]] "mig_awvalid,mig_awready"
	add_probe $core 2 [list \
		[one_net mig_awvalid] [one_net mig_awready] \
		[one_net mig_awaddr\[29\]] [one_net mig_awaddr\[30\]] \
	] "accepted AW + top-512M bits"
} else {
	add_probe $core 0  [bus_nets c_awaddr 30 0] "c_awaddr[30:0]"
	add_probe $core 1  [list [one_net c_awvalid] [one_net c_awready]] "c_awvalid,c_awready"
	add_probe $core 2  [bus_nets c_wdata 63 0] "c_wdata[63:0]"
	add_probe $core 3  [bus_nets c_wstrb 7 0] "c_wstrb[7:0]"
	add_probe $core 4  [list [one_net c_wvalid] [one_net c_wready]] "c_wvalid,c_wready"
	add_probe $core 5  [list [one_net c_bvalid] [one_net c_bready]] "c_bvalid,c_bready"

	add_probe $core 6  [bus_nets mig_awaddr 30 0] "mig_awaddr[30:0]"
	add_probe $core 7  [list [one_net mig_awvalid] [one_net mig_awready]] "mig_awvalid,mig_awready"
	add_probe $core 8  [bus_nets mig_wdata [expr {$mig_wdata_bits - 1}] 0] "mig_wdata[$mig_wdata_bits-1:0]"
	add_probe $core 9  [bus_nets mig_wstrb 63 0] "mig_wstrb[63:0]"
	add_probe $core 10 [list [one_net mig_wvalid] [one_net mig_wready]] "mig_wvalid,mig_wready"
	add_probe $core 11 [list [one_net mig_bvalid] [one_net mig_bready]] "mig_bvalid,mig_bready"

	#	Small duplicate trigger/correlation probe: accepted write + high address bits
	#	are easy to select in Hardware Manager without expanding the wide buses.
	add_probe $core 12 [list \
		[one_net c_awvalid] [one_net c_awready] \
		[one_net c_awaddr\[29\]] [one_net c_awaddr\[30\]] \
		[one_net mig_awvalid] [one_net mig_awready] \
		[one_net mig_awaddr\[29\]] [one_net mig_awaddr\[30\]] \
	] "accepted AW + high address bits"
}

#	Ethernet/MMIO correlation. These are cpu-clock-domain nets sampled by ui_clk;
#	treat them as context flags, not cycle-exact CDC measurements.
set eth_probe {}
foreach n {eth_busy eth_rd_req xbar/u_eth/eth_rd_done xbar/u_eth/eth_wr_done x_awvalid x_awready x_wready x_bvalid x_bready} {
	set got [get_nets -quiet $n]
	if {[llength $got] == 1} {
		lappend eth_probe [lindex $got 0]
	} else {
		puts "WARN: skipping optional net '$n' ([llength $got] matches)"
	}
}
if {$profile eq "threshold"} {
	add_probe $core 3 $eth_probe "eth/cpu-side context flags"
} else {
	add_probe $core 13 $eth_probe "eth/cpu-side context flags"
}

write_checkpoint -force $out_dcp
puts "ILA inserted checkpoint: $out_dcp"

if {[env_truthy ILA_IMPL]} {
	set opt_args {}
	set place_args {}
	set phys_opt_args {}
	set route_args {}
	opt_design {*}$opt_args
	place_design {*}$place_args
	write_checkpoint -force [karu_build_path vcu118_ddr_ila_postplace.dcp]
	phys_opt_design {*}$phys_opt_args
	route_design {*}$route_args
	set route_slack [get_property SLACK [get_timing_paths -delay_type min_max]]
	if {$route_slack < 0} {
		phys_opt_design {*}$phys_opt_args
	}
	report_utilization    -file [karu_rpt_path vcu118_ddr_ila_utilization.rpt]
	report_timing_summary -file [karu_rpt_path vcu118_ddr_ila_timing.rpt]
	report_bus_skew       -file [karu_rpt_path vcu118_ddr_ila_bus_skew.rpt]
	write_checkpoint -force [karu_build_path vcu118_ddr_ila_route.dcp]
	write_debug_probes -force [karu_build_path vcu118_ddr_ila.ltx]
	write_bitstream -force [karu_build_path vcu118_ddr_ila.bit]
	puts "ILA bitstream: [karu_build_path vcu118_ddr_ila.bit]"
	puts "ILA probes:    [karu_build_path vcu118_ddr_ila.ltx]"
}
