#	elab-check-ddr.tcl
#	=== fast Vivado RTL-elaboration-only check for the DDR4 bridge RTL.
#	Elaborates fpga_ddr_top (core + karu_ddr_xbar + behavioral karu_axi4_ram)
#	to confirm the new interconnect is Vivado-synthesizable (Vivado is stricter
#	than verilator/iverilog). Run through Makefile:
#	    make elab-ddr
#	KARU_DEFINES (default KARU_NO_V here, since the bridge is V-independent and
#	NO_V elaborates fast) is forwarded as -verilog_define. The DDR hardware flow
#	enables the I-cache by default, so this elaboration check does too.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

foreach fn [glob -type f [file join $::karu_repo_dir rtl *.v]] {
	if {[string match "*htif_tb.v"    $fn]} { continue }
	if {[string match "*_assert.v" $fn]} { continue }
	read_verilog $fn
}
foreach fn [glob -nocomplain -type f [file join $::karu_repo_dir rtl zvk *.v]] { read_verilog $fn }
foreach fn [glob -type f [file join $::karu_repo_dir flow fpga *.v]] {
	if {[string match "*_tb.v" $fn]} { continue }
	if {[string match "*_assert.v" $fn]} { continue }
	read_verilog $fn
}
foreach fn [list \
	[karu_repo_path flow fpga eth karu_eth.v] \
	[karu_repo_path flow fpga eth liteeth_core.v] \
	[karu_repo_path flow fpga eth eth_mii_loopback.v] \
] {
	read_verilog $fn
}

set vdefs {KARU_ETH_NO_MDIO_IOBUF KARU_ICACHE KARU_NO_V}
if {[info exists ::env(KARU_DEFINES)] && $::env(KARU_DEFINES) ne ""} {
	set vdefs {KARU_ETH_NO_MDIO_IOBUF KARU_ICACHE}
	foreach d $::env(KARU_DEFINES) { lappend vdefs $d }
}
puts "ELAB-CHECK-DDR KARU_DEFINES: $vdefs"

synth_design -rtl -part xcvu9p-flga2104-2L-e -top fpga_ddr_top \
	-include_dirs [list [karu_repo_path rtl] [karu_repo_path rtl zvk] [karu_repo_path flow fpga]] \
	-verilog_define $vdefs

puts "ELAB-CHECK-DDR: fpga_ddr_top RTL elaboration completed"
