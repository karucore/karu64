#	elab-check.tcl
#	=== fast Vivado RTL-elaboration-only check (no synthesis/P&R).
#	Surfaces static range / elaboration errors quickly. Run through Makefile:
#	    make elab

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

foreach fn [glob -type f [file join $::karu_repo_dir rtl *.v]] {
	if {[string match "*htif_tb.v"    $fn]} { continue }
	if {[string match "*_assert.v" $fn]} { continue }
	read_verilog $fn
}
foreach fn [glob -nocomplain -type f [file join $::karu_repo_dir rtl zvk *.v]] {
	read_verilog $fn
}
foreach fn [glob -type f [file join $::karu_repo_dir flow fpga *.v]] {
	if {[string match "*_tb.v" $fn]} { continue }
	if {[string match "*_assert.v" $fn]} { continue }
	read_verilog $fn
}
read_xdc [karu_repo_path flow fpga vcu118.xdc]

#	Forward the same build-time RTL knobs the real synth uses (KARU_DEFINES),
#	so the elaboration check exercises the configured ISA (e.g. KARU_KECCAK,
#	the vector cycle/lane knobs) rather than only the bare default.
set vdefs {}
if {[info exists ::env(KARU_DEFINES)]} {
	foreach d $::env(KARU_DEFINES) { lappend vdefs $d }
}
if {[llength $vdefs] > 0} {
	puts "KARU_DEFINES: $vdefs"
	synth_design -rtl -part xcvu9p-flga2104-2L-e -top vcu118_top \
		-include_dirs [list [karu_repo_path rtl] [karu_repo_path rtl zvk] [karu_repo_path flow fpga]] \
		-verilog_define $vdefs
} else {
	synth_design -rtl -part xcvu9p-flga2104-2L-e -top vcu118_top \
		-include_dirs [list [karu_repo_path rtl] [karu_repo_path rtl zvk] [karu_repo_path flow fpga]]
}
puts "ELAB-CHECK: RTL elaboration completed"
