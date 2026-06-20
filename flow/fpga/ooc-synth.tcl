#	ooc-synth.tcl
#	=== Out-of-context (per-module) synthesis for diagnostics.
#
#	Synthesizes ONE module standalone (no top/SoC, ports left as boundary
#	pins) so we can read its area + logic depth + worst paths cheaply and in
#	isolation -- much smaller memory/runtime than the whole core, and it
#	pinpoints which vector module owns the timing/runtime wall.
#
#	Run through `make ooc` (after the `xilinx` alias), driven by env vars:
#	    KARU_OOC_TOP        module to synth (e.g. karu_varith)      [required]
#	    KARU_DEFINES        verilog defines (cycle/lane/VLEN knobs)  [optional]
#	    KARU_OOC_PERIOD     clock period ns for create_clock        [default 16]
#	    KARU_SYNTH_DIRECTIVE  synth_design -directive               [optional]
#	    VIVADO_THREADS      worker thread cap                        [optional]
#	Outputs under _build: ooc_<mod>_util.rpt / _timing.rpt / _worstpaths.rpt / .dcp

set part	xcvu9p-flga2104-2L-e

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

#	Shared report-archiving helper (config-tagged copies into _build/fpga_rpt/).
source [karu_repo_path flow fpga karu_reports.tcl]

if {![info exists ::env(KARU_OOC_TOP)] || $::env(KARU_OOC_TOP) eq ""} {
	puts "ERROR: set KARU_OOC_TOP to the module to synthesize."
	exit 1
}
set mod $::env(KARU_OOC_TOP)

if {[info exists ::env(VIVADO_THREADS)]} {
	set_param general.maxThreads $::env(VIVADO_THREADS)
}

set period 16.0
if {[info exists ::env(KARU_OOC_PERIOD)] && $::env(KARU_OOC_PERIOD) ne ""} {
	set period $::env(KARU_OOC_PERIOD)
}

#	core RTL only (rtl/ plus optional rtl/zvk/, no flow/fpga/ wrapper, no sim tb /
#	assertion checker)
foreach fn [glob -type f [file join $::karu_repo_dir rtl *.v]] {
	if {[string match "*htif_tb.v"    $fn]} { continue }
	if {[string match "*_assert.v" $fn]} { continue }
	read_verilog $fn
}
foreach fn [glob -nocomplain -type f [file join $::karu_repo_dir rtl zvk *.v]] {
	read_verilog $fn
}

set vdefs {}
if {[info exists ::env(KARU_DEFINES)]} {
	foreach d $::env(KARU_DEFINES) { lappend vdefs $d }
}
set dargs {}
if {[info exists ::env(KARU_SYNTH_DIRECTIVE)] && $::env(KARU_SYNTH_DIRECTIVE) ne ""} {
	set dargs [list -directive $::env(KARU_SYNTH_DIRECTIVE)]
}

puts "OOC: module=$mod  period=${period}ns  defines={$vdefs}  dargs={$dargs}"

if {[llength $vdefs] > 0} {
	synth_design -mode out_of_context -part $part -top $mod \
		-include_dirs [list [karu_repo_path rtl] [karu_repo_path rtl zvk]] \
		-verilog_define $vdefs {*}$dargs
} else {
	synth_design -mode out_of_context -part $part -top $mod \
		-include_dirs [list [karu_repo_path rtl] [karu_repo_path rtl zvk]] {*}$dargs
}

#	Constrain the module clock so the timing report is meaningful. OOC leaves
#	I/O delays at defaults (no surrounding context), so the WNS here is
#	approximate -- good for "how deep is the logic / which module is worst",
#	not an absolute closure number.
if {[llength [get_ports -quiet clk]] > 0} {
	create_clock -period $period -name clk [get_ports clk]
}

set ooc_reports [list \
	[karu_rpt_path ooc_${mod}_util.rpt] \
	[karu_rpt_path ooc_${mod}_timing.rpt] \
	[karu_rpt_path ooc_${mod}_worstpaths.rpt] \
]

report_utilization    -file [lindex $ooc_reports 0]
report_timing_summary -file [lindex $ooc_reports 1]
report_timing -max_paths 20 -nworst 20 -path_type full_clock_expanded \
                      -file [lindex $ooc_reports 2]
write_checkpoint -force [karu_build_path ooc_${mod}.dcp]

#	Retain this OOC run's reports under a config tag (KARU_REPORT_TAG, else the
#	module name) so per-module diagnostics aren't clobbered run-to-run.
karu_archive_reports [karu_report_tag "ooc_${mod}"] \
	$ooc_reports

puts "OOC-DONE: $mod"
