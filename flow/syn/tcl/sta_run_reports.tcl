#	flow/syn/tcl/sta_run_reports.tcl
#	Read the post-synth (STA-friendly) netlist + liberty + sdc, then
#	dump per-path-group timing reports.

set top     "karu64"
set out_dir $::env(KARU_OUT_DIR)
set lib     $::env(KARU_LIB)
set sta_v   "$out_dir/generated/${top}_netlist.sta.v"
set sdc     "$out_dir/generated/${top}.sdc"
set rpt_dir "$out_dir/reports/timing"

read_liberty $lib
read_verilog $sta_v
link_design $top
read_sdc $sdc

#	Group paths so we can report each segment separately.
set flops_in  [all_registers -edge_triggered -data_pins]
set flops_out [all_registers -edge_triggered -clock_pins]
set non_clk_inputs [list]
set out_ports [list]
foreach p [get_ports *] {
	set n [get_property $p full_name]
	set d [get_property $p direction]
	if {$d eq "input" && $n ne "clk"} { lappend non_clk_inputs $p }
	if {$d eq "output"}                { lappend out_ports     $p }
}

group_path -name reg2reg -from $flops_out -to $flops_in
group_path -name reg2out -from $flops_out -to $out_ports
group_path -name in2reg  -from $non_clk_inputs -to $flops_in
group_path -name in2out  -from $non_clk_inputs -to $out_ports

proc dump {grp} {
	global rpt_dir
	set rpt "${rpt_dir}/${grp}.rpt"
	set csv "${rpt_dir}/${grp}.csv.rpt"
	puts "Reporting $grp -> $rpt"
	report_checks -group_path_count 100 -path_group $grp > $rpt
	set f [open $csv w]
	foreach p [find_timing_paths -group_path_count 100 -path_group $grp] {
		set sp [get_property [get_property $p startpoint] full_name]
		set ep [get_property [get_property $p endpoint]   full_name]
		set sl [get_property $p slack]
		puts $f [format "%s,%s,%.4f" $sp $ep $sl]
	}
	close $f
}

#	Overall (no -path_group) -- the design-level WNS.
set overall "${rpt_dir}/overall.rpt"
puts "Reporting overall -> $overall"
report_checks -group_path_count 100 > $overall

foreach g {reg2reg reg2out in2reg in2out} { dump $g }

exit
