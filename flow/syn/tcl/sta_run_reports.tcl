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

#	Group paths so we can report each segment separately. all_registers also
#	returns D pins whose clocks/data have been constant-folded; OpenSTA does not
#	consider those pins timing endpoints and warns for each one passed to
#	group_path. Intersect with its actual endpoint set first.
set endpoint_names [dict create]
foreach p [sta::endpoints] {
	dict set endpoint_names [get_property $p full_name] 1
}
set flops_in [list]
foreach p [all_registers -edge_triggered -data_pins] {
	if {[dict exists $endpoint_names [get_property $p full_name]]} {
		lappend flops_in $p
	}
}
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

#	OpenSTA renamed the per-group path-count flag from -group_count (<= 2.4)
#	to -group_path_count (2.5+). Probe once and use whichever this binary
#	accepts, so the flow runs on both.
set gpc "-group_path_count"
if {[catch {report_checks -group_path_count 1 > /dev/null} err]} {
	set gpc "-group_count"
	puts "OpenSTA: -group_path_count unsupported, using -group_count"
}

proc dump {grp} {
	global rpt_dir gpc
	set rpt "${rpt_dir}/${grp}.rpt"
	set csv "${rpt_dir}/${grp}.csv.rpt"
	puts "Reporting $grp -> $rpt"
	report_checks {*}$gpc 100 -path_group $grp > $rpt
	set f [open $csv w]
	foreach p [find_timing_paths {*}$gpc 100 -path_group $grp] {
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
report_checks {*}$gpc 100 > $overall

foreach g {reg2reg reg2out in2reg in2out} { dump $g }

# Closure is a design-wide result, not just the first 100 reg-to-reg paths.
# Keep constraint coverage and electrical-limit violations beside WNS/TNS.
check_setup -verbose > ${rpt_dir}/check_setup.rpt
report_worst_slack -max > ${rpt_dir}/summary.rpt
report_tns >> ${rpt_dir}/summary.rpt
report_check_types -max_slew -max_capacitance -max_fanout -violators \
    > ${rpt_dir}/electrical.rpt

exit
