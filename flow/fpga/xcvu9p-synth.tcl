#	xcvu9p-synth.tcl
#	=== Vivado non-project batch flow: karu64 -> VCU118 bitstream.
#
#	Run through the Makefile after bringing Vivado into the environment:
#	    xilinx                       # the alias that sources Vivado's settings
#	    make vcu118.bit
#	The Makefile starts Vivado in _build because Vivado writes many side files
#	to its launch directory. Named outputs are also written under _build.
#
#	firmware.hex (the BRAM image) is read by karu_axi_mem relative to the
#	launch directory, i.e. _build -- `make vcu118.bit` stages it there.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

set part	xcvu9p-flga2104-2L-e
set top		vcu118_top

#	Shared report-archiving helper (config-tagged copies into
#	_build/fpga_rpt/ so each run's worst paths are retained, not clobbered).
source [karu_repo_path flow fpga karu_reports.tcl]

#	Throttle Vivado worker threads to cap peak memory (env VIVADO_THREADS).
if {[info exists ::env(VIVADO_THREADS)]} {
	set_param general.maxThreads $::env(VIVADO_THREADS)
	puts "VIVADO_THREADS: $::env(VIVADO_THREADS)"
}

#	core RTL (rtl/ plus optional rtl/zvk/) minus the simulation-only testbench
#	+ assertion checker
foreach fn [glob -type f [file join $::karu_repo_dir rtl *.v]] {
	if {[string match "*htif_tb.v"    $fn]} { continue }
	if {[string match "*_assert.v" $fn]} { continue }
	read_verilog $fn
}
foreach fn [glob -nocomplain -type f [file join $::karu_repo_dir rtl zvk *.v]] {
	read_verilog $fn
}

#	FPGA RTL (flow/fpga/) minus the simulation-only testbench
foreach fn [glob -type f [file join $::karu_repo_dir flow fpga *.v]] {
	if {[string match "*_tb.v" $fn]} { continue }
	read_verilog $fn
}

read_xdc [karu_repo_path flow fpga vcu118.xdc]

#	Build-time RTL knobs (multiplier/divider cycle counts, etc.) passed
#	from `make vcu118.bit` via the KARU_DEFINES env var, e.g.
#	    make vcu118.bit KARU_DEFINES="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64"
set vdefs {}
if {[info exists ::env(KARU_DEFINES)]} {
	foreach d $::env(KARU_DEFINES) { lappend vdefs $d }
}

#	Optional synth_design -directive (env KARU_SYNTH_DIRECTIVE), e.g.
#	    make vcu118.bit SYNTH_DIRECTIVE=RuntimeOptimized
#	RuntimeOptimized skips the slow timing-driven optimization pass -- the
#	full-vector core's all-element-parallel cones (karu_varith, VLEN=256 ->
#	32-wide) drive that pass into multi-hour single-threaded grinds. Use it
#	for a fast feasibility read (fit + estimated WNS + worst paths); drop it
#	for the final closure run.
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

#	Optional input-clock-period override for timing-target experiments, e.g.
#	    make vcu118.bit KARU_CLK_PERIOD=12.0
#	Redefines the XDC's clk_125mhz with a new period. MUST run AFTER synth_design
#	(create_clock/get_ports need an open design; pre-synth it errors "No open
#	design"). The derived core clock tracks: vcu118_top divides this input by 2
#	with BUFGCE_DIV, so the core clock target is 2*KARU_CLK_PERIOD unless the
#	divider/wrapper is changed. A real bitstream at a different frequency also
#	needs matching IUTSYS_CLK/UART_BITCLKS -- this override is for synth/timing
#	feasibility, not for producing a runnable bitstream at that rate.
if {[info exists ::env(KARU_CLK_PERIOD)] && $::env(KARU_CLK_PERIOD) ne ""} {
	set kp $::env(KARU_CLK_PERIOD)
	puts "KARU_CLK_PERIOD: retargeting clk_125mhz to ${kp} ns (core = [expr {2*$kp}] ns)"
	create_clock -period $kp -name clk_125mhz [get_ports { clk_125mhz_p }]
}

#	Post-synthesis snapshot (minutes in, before the long P&R). Estimated
#	routing, but enough to find the structural long paths to attack.
set synth_reports [list \
	[karu_rpt_path vcu118_synth_util.rpt] \
	[karu_rpt_path vcu118_synth_util_hier.rpt] \
	[karu_rpt_path vcu118_synth_timing.rpt] \
	[karu_rpt_path vcu118_synth_worstpaths.rpt] \
]

report_utilization              -file [lindex $synth_reports 0]
#	Per-module (hierarchical) area -> RELATIVE component sizes (karu_varith,
#	karu_vcrypto, karu_vlane[*], FPUs, ...). -50 levels reaches the leaf lanes.
report_utilization -hierarchical -hierarchical_depth 50 \
                                -file [lindex $synth_reports 1]
report_timing_summary           -file [lindex $synth_reports 2]
report_timing -max_paths 30 -nworst 30 -path_type full_clock_expanded \
                                -file [lindex $synth_reports 3]
write_checkpoint -force [karu_build_path vcu118_synth.dcp]

#	Retain this run's post-synth reports under a config tag (KARU_REPORT_TAG,
#	else the design top). Done here too so SYNTH_ONLY feasibility runs archive.
set rtag [karu_report_tag $top]
karu_archive_reports $rtag $synth_reports

#	Feasibility mode: stop after synthesis. The post-synth snapshot above
#	(util + estimated-route timing + 30 worst paths + checkpoint) is the fast
#	read on "does it elaborate, fit, and where are the long paths" -- minutes
#	in, before committing to the multi-hour P&R. Resume later from the .dcp.
#	Enable with `make vcu118.bit SYNTH_ONLY=1` (forwarded as KARU_SYNTH_ONLY).
if {[info exists ::env(KARU_SYNTH_ONLY)] && $::env(KARU_SYNTH_ONLY) ne ""} {
	puts "KARU_SYNTH_ONLY set -- stopping after synthesis (skipping P&R)."
	return
}

opt_design

#	Optional floorplan (KARU_FLOORPLAN=<name> -> flow/fpga/floorplan_<name>.tcl):
#	apply pblock constraints AFTER opt, BEFORE placement, to pull a route-bound
#	cluster into one physical neighborhood. Kept separate from normal builds
#	(no env => no constraints) until it wins consistently. See doc/fpga.md.
if {[info exists ::env(KARU_FLOORPLAN)] && $::env(KARU_FLOORPLAN) ne ""} {
	set fp [karu_repo_path flow fpga floorplan_$::env(KARU_FLOORPLAN).tcl]
	if {[file exists $fp]} { puts "FLOORPLAN: sourcing $fp"; source $fp } \
	else { puts "FLOORPLAN: $fp MISSING -- skipping" }
}

place_design
write_checkpoint -force [karu_build_path vcu118_place.dcp]

#	Place-only mode: stop after placement -- a fast read on WHERE cells land
#	(for floorplan inspection of the routed-cone cluster), skipping the long
#	route. Enable with `make vcu118.bit PLACE_ONLY=1` (-> KARU_PLACE_ONLY).
if {[info exists ::env(KARU_PLACE_ONLY)] && $::env(KARU_PLACE_ONLY) ne ""} {
	puts "KARU_PLACE_ONLY set -- stopping after placement (skipping route)."
	return
}

phys_opt_design
route_design
#	post-route physical opt only helps if there is still negative slack
if {[get_property SLACK [get_timing_paths -delay_type min_max]] < 0} {
	phys_opt_design
}
#	Save the routed checkpoint so placement is inspectable + floorplan-diffable
#	(the bitstream alone can't be reopened for cell placement).
write_checkpoint -force [karu_build_path vcu118_route.dcp]

set route_reports [list \
	[karu_rpt_path vcu118_utilization.rpt] \
	[karu_rpt_path vcu118_timing.rpt] \
	[karu_rpt_path vcu118_route_worstpaths.rpt] \
]

report_utilization              -file [lindex $route_reports 0]
report_timing_summary           -file [lindex $route_reports 1]
report_timing -max_paths 30 -nworst 30 -path_type full_clock_expanded \
                                -file [lindex $route_reports 2]

#	Retain this run's post-route reports under the same config tag.
karu_archive_reports $rtag $route_reports

write_bitstream -force [karu_build_path vcu118.bit]
