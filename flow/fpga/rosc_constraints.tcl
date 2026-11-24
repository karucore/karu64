#	rosc_constraints.tcl -- constraints for the ring-oscillator noise source
#	(flow/fpga/karu_rosc_rng.v). Source it after synth_design and call
#	karu_constrain_rosc; after place_design, karu_check_rosc_placement; after
#	route_design, karu_check_rosc_count. Each procedure checks what it works
#	on and stops the build if the netlist is not what it expects.
#
#	The rings. Six of them: the four lanes (ring s has 3 + 2*s stages) and
#	two reference rings built like lane 0 (3 stages). karu_constrain_rosc
#	  * finds each ring by its nets and checks that synthesis kept every
#	    stage: one two-input enable gate, the rest inverters;
#	  * places every LUT by hand, in ring order, each on its own 6-input LUT
#	    position: lane s in the slice at column X + KARU_ROSC_STEP*s, row Y,
#	    continuing in the slice above when a ring has more than eight
#	    stages; reference t in lane 0's column, KARU_ROSC_REF_DY[t] rows
#	    away, on the same positions as lane 0. The first slice is
#	    KARU_ROSC_BASE ("X Y"; default "100 450", in the middle SLR of the
#	    XCVU9P next to the processor). A region constraint (pblock) is not
#	    enough: the placer was seen to pack three rings into one slice
#	    outside their regions;
#	  * keeps everything else out of those slices, so that a ring shares a
#	    slice with nothing;
#	  * cuts the paths from the rings into the sampling flip-flops out of the
#	    timing analysis: they are asynchronous by design.
#
#	The counters (karu_rosc_cnt, one per ring). The 3-stage rings' period,
#	0.37 ns in the fast corner, is less than a flip-flop of this part may be
#	clocked with (0.550 ns), so in the measuring mode no ring clocks a
#	flip-flop: its output goes to a divider by two made of two look-up-table
#	latches, and the divider's output clocks the counter. What
#	hangs on a ring has to sit next to it and be the same for every ring:
#	  * the divider's two latches and the selector behind them (div_m,
#	    div_s, div_x), each on a fixed look-up-table position with its pins
#	    fixed, in the slice on the other side of the ring's interconnect
#	    column: the ring on the fastest pin of each;
#	  * the eight Johnson flip-flops in the lower half of that slice, in
#	    shift order, with their one inverter;
#	  * the eight flip-flops that sample them, in the slice above on the
#	    same eight positions, so that every one of the eight routes is the
#	    same step one row up; their second synchroniser stages in the upper
#	    half of that slice (the tool wants such a pair in one slice);
#	  * the two coarse counters in the slice below, one per half (each half
#	    has its own clock, a Johnson flip-flop);
#	  * nothing else in those three slices;
#	  * a clock on the selector's output, the counter's clock, declared a
#	    little faster than the divider can make it: twice the ring's period
#	    in the fast corner, less the duty allowance (below), as estimated
#	    when this file was written (KARU_ROSC_CLOCK_NS by ring length). The
#	    tool's own checks of the flip-flops' minimum period and pulse widths,
#	    and of the paths between the Johnson flip-flops, are then made for
#	    that period, and karu_check_rosc_count stops the build if the routed
#	    ring could be faster than the declaration in either half;
#	  * the routes into the sampling flip-flops limited in delay and, for
#	    the Johnson bits, in skew: a sample must not mix bits of different
#	    counter periods;
#	  * the clear of a counter limited in delay: it is released a clock
#	    before the ring starts.
#	karu_check_rosc_count then reads the routed design in four uniform
#	states, every delay from one column of the timing model (slow max, slow
#	min, fast max, fast min): each ring's two halves, edge by edge round its loop;
#	the divider's six conditions (below); the counter clock's period and
#	both its pulses against the declaration, and the tool's own pulse-width
#	report at every counter clock pin; the spread of the sampled bits'
#	routes; and how early or late a coarse counter can reach its sampler.
#	Delays of one state are compared with the ring's period in the same
#	state: neighbouring cells move together with voltage, temperature and
#	process. The counting
#	mode that puts the ring itself on the counter's clock (a diagnostic of
#	test mode) is outside these checks by design.
#
#	The duty allowance. The timing model of this part gives every look-up
#	table arc the same delay for a rising and a falling output, and every
#	route one delay for both edges (checked on a routed design, 2026-11-21:
#	DELAY_*_RISE = DELAY_*_FALL on every arc of the rings, the dividers and
#	the selectors, and net delays have no edge at all). So the model's ring
#	has halves of exactly half its period, and a pulse of the divided clock
#	of exactly one ring period. The silicon does not: lane 0's sampled bit
#	was high 0.511 of the time on the board (image ddb168e1…), so its ring's
#	halves differ by about 2 % of a period. The check therefore takes each
#	half of a ring as at least KARU_ROSC_DUTY_MIN (0.48) of its period: an
#	engineering allowance, twice what lane 0 showed, not a measured bound
#	for every ring; the board's ratio checks on every running ring are the
#	evidence that each divider works. It takes each pulse of the divided
#	clock as at least 2 x 0.48 = 0.96 of a ring period, and less again by any rise/fall difference the model does give
#	on the path (none on this part). It computes the halves edge by edge from
#	the arcs all the same, so that a model with such differences is used.
#
#	The rings are combinational loops, and so are the two latches of every
#	divider (each holds itself, and they feed each other). The rings' nets
#	carry ALLOW_COMBINATORIAL_LOOPS in the RTL; the latches' nets get it
#	here, because the attribute in the RTL does not reach them. The loop
#	check then gives warnings (LUTLP-2): six for the rings and three for
#	each divider. A loop that is refused (LUTLP-1) stops the image build
#	right after synthesis.

proc karu_rosc_noise {} {
	set noise [get_cells -hierarchical -filter {ORIG_REF_NAME == karu_rosc_rng || REF_NAME == karu_rosc_rng}]
	if {[llength $noise] != 1} { error "karu_rosc: expected one karu_rosc_rng instance, found [llength $noise]" }
	return $noise
}

#	The rings of the design: a list of {name kind index stages}, the lanes
#	first. Ring r of the noise source is entry r.
proc karu_rosc_rings {noise} {
	set rings {}
	for {set s 0} {$s < 16} {incr s} {
		if {[llength [get_nets -quiet -hierarchical -filter "NAME =~ $noise/g_rings.g_ring\[$s\].inv\[*\]"]] == 0} { break }
		lappend rings [list "lane $s" g_ring $s [expr {3 + 2 * $s}]]
	}
	for {set t 0} {$t < 16} {incr t} {
		if {[llength [get_nets -quiet -hierarchical -filter "NAME =~ $noise/g_rings.g_ref\[$t\].inv\[*\]"]] == 0} { break }
		lappend rings [list "reference $t" g_ref $t 3]
	}
	return $rings
}

#	The LUTs of one ring in loop order, the enable gate first; stage i
#	drives net inv[i], so the last one drives the ring's output.
proc karu_rosc_ring_luts {noise ring} {
	lassign $ring name kind idx want
	set nets [get_nets -hierarchical -filter "NAME =~ $noise/g_rings.$kind\[$idx\].inv\[*\]"]
	set luts [lsort -unique [get_cells -of_objects [get_pins -leaf -of_objects $nets -filter {DIRECTION == OUT}]]]
	if {[llength $nets] != $want || [llength $luts] != $want} {
		error "karu_rosc: $name has [llength $nets] nets driven by [llength $luts] cells, expected $want of each: synthesis changed the ring"
	}
	set gate {}
	foreach c $luts {
		set ref [get_property REF_NAME $c]
		if {$ref eq "LUT2"} { lappend gate $c } elseif {$ref ne "LUT1"} {
			error "karu_rosc: $name stage $c is a $ref, not an inverter or the enable gate"
		}
	}
	if {[llength $gate] != 1} { error "karu_rosc: $name has [llength $gate] enable gates, expected 1" }
	set order {}
	set cur [lindex $gate 0]
	for {set i 0} {$i < $want} {incr i} {
		lappend order $cur
		set out [get_nets -of_objects [get_pins $cur/O]]
		set next {}
		foreach c [get_cells -of_objects [get_pins -leaf -of_objects $out -filter {DIRECTION == IN}]] {
			if {[lsearch -exact $luts $c] >= 0} { lappend next $c }
		}
		if {[llength $next] != 1} { error "karu_rosc: $name is not a single loop at $cur" }
		set cur [lindex $next 0]
	}
	if {$cur ne [lindex $gate 0] || [llength [lsort -unique $order]] != $want} {
		error "karu_rosc: $name does not close after $want stages"
	}
	return $order
}

#	The slice next to a ring's slice, dy rows up: the nearest place for what
#	the ring clocks. It is the slice on the other side of the same
#	interconnect column where there is one (lane 0 and the references, which
#	share a column, then get the same geometry); otherwise the next slice
#	column to the right, or to the left.
proc karu_rosc_partner {site dy} {
	if {![regexp {^SLICE_X(\d+)Y(\d+)$} $site -> sx sy]} { error "karu_rosc: cannot read the site name $site" }
	set tile [get_tiles -of_objects [get_sites $site]]
	if {![regexp {^(.*)_X(\d+)Y(\d+)$} $tile -> type tx ty]} { error "karu_rosc: cannot read the tile name $tile of $site" }
	foreach t [get_tiles -quiet -filter "NAME =~ CLE*_X${tx}Y[expr {$ty + $dy}]"] {
		if {![string match "${type}_X*" $t]} {
			set s [get_sites -of_objects $t -filter {SITE_TYPE =~ SLICE*}]
			if {[llength $s] == 1} { return [get_property NAME $s] }
		}
	}
	foreach dx {1 -1} {
		set s [get_sites -quiet "SLICE_X[expr {$sx + $dx}]Y[expr {$sy + $dy}]"]
		if {[llength $s] == 1} { return [get_property NAME $s] }
	}
	error "karu_rosc: no slice next to $site in row [expr {$sy + $dy}]; set KARU_ROSC_BASE"
}

proc karu_rosc_prohibit_rest {sites used} {
	foreach site $sites {
		foreach b [get_bels -of_objects [get_sites $site]] {
			if {[lsearch -exact $used $b] < 0} { set_property PROHIBIT TRUE $b }
		}
	}
}

#	The cells of ring r's counter, by name.
proc karu_rosc_cnt_cells {noise r reg width} {
	set cells {}
	for {set i 0} {$i < $width} {incr i} {
		set c [get_cells -quiet "$noise/g_rings.g_cnt\[$r\].cnt/${reg}_reg\[$i\]"]
		if {[llength $c] != 1} { error "karu_rosc: counter of ring $r: expected one cell ${reg}_reg\[$i\], found [llength $c]" }
		lappend cells $c
	}
	return $cells
}

proc karu_constrain_rosc {} {
	set base {100 450}
	if {[info exists ::env(KARU_ROSC_BASE)] && $::env(KARU_ROSC_BASE) ne ""} { set base $::env(KARU_ROSC_BASE) }
	set step 4
	if {[info exists ::env(KARU_ROSC_STEP)] && $::env(KARU_ROSC_STEP) ne ""} { set step $::env(KARU_ROSC_STEP) }
	set ref_dy {12 -12}
	if {[info exists ::env(KARU_ROSC_REF_DY)] && $::env(KARU_ROSC_REF_DY) ne ""} { set ref_dy $::env(KARU_ROSC_REF_DY) }
	#	the clock declared on a counter, by ring length: a little under twice
	#	the ring's period in the fast corner less the duty allowance, 2 x 0.96
	#	x (0.368, 0.498, 0.728 and 0.922 ns when the source was placed and
	#	routed alone) = 0.707, 0.956, 1.398 and 1.770 ns; declared a little
	#	under that, 0.68, 0.92, 1.36 and 1.72 ns. The check after routing
	#	fails if a ring could be faster than the declaration in either half.
	array set clock_ns {3 0.68 5 0.92 7 1.36 9 1.72}
	if {[info exists ::env(KARU_ROSC_CLOCK_NS)] && $::env(KARU_ROSC_CLOCK_NS) ne ""} { array set clock_ns $::env(KARU_ROSC_CLOCK_NS) }
	lassign $base bx by
	set bel_names {A6LUT B6LUT C6LUT D6LUT E6LUT F6LUT G6LUT H6LUT}
	set low_ffs  {AFF AFF2 BFF BFF2 CFF CFF2 DFF DFF2}
	set high_ffs {EFF EFF2 FFF FFF2 GFF GFF2 HFF HFF2}

	set noise [karu_rosc_noise]
	set rings [karu_rosc_rings $noise]
	if {[llength $rings] != 6} { error "karu_rosc: found [llength $rings] rings, expected 6 (four lanes and two references)" }
	set summary {}
	set taken {}
	set r 0
	foreach ring $rings {
		lassign $ring name kind idx want
		set order [karu_rosc_ring_luts $noise $ring]
		if {$kind eq "g_ring"} {
			set x [expr {$bx + $step * $idx}]; set y $by
		} else {
			if {$idx >= [llength $ref_dy]} { error "karu_rosc: no row offset for $name in KARU_ROSC_REF_DY" }
			set x $bx; set y [expr {$by + [lindex $ref_dy $idx]}]
		}
		#	the ring
		set used {}
		set ring_sites {}
		for {set i 0} {$i < $want} {incr i} {
			set site "SLICE_X${x}Y[expr {$y + $i / 8}]"
			if {[llength [get_sites -quiet $site]] != 1} {
				error "karu_rosc: $site is not a slice on this part; set KARU_ROSC_BASE"
			}
			set bel [lindex $bel_names [expr {$i % 8}]]
			set_property BEL $bel [lindex $order $i]
			set_property LOC $site [lindex $order $i]
			lappend used "$site/$bel"
			if {[lsearch -exact $ring_sites $site] < 0} { lappend ring_sites $site }
		}
		karu_rosc_prohibit_rest $ring_sites $used

		#	the counter: Johnson flops in one slice, their samplers in the one
		#	above, the coarse counters in the one below
		set first "SLICE_X${x}Y${y}"
		set js [karu_rosc_partner $first 0]
		set ss [karu_rosc_partner $first 1]
		set cs [karu_rosc_partner $first -1]
		foreach s [concat $ring_sites [list $js $ss $cs]] {
			if {[lsearch -exact $taken $s] >= 0} { error "karu_rosc: $name needs $s, which another ring has" }
			lappend taken $s
		}
		set j  [karu_rosc_cnt_cells $noise $r j_q 8]
		set a  [karu_rosc_cnt_cells $noise $r a_q 2]
		set b  [karu_rosc_cnt_cells $noise $r b_q 2]
		set gm [karu_rosc_cnt_cells $noise $r gm_q 12]
		set gs [karu_rosc_cnt_cells $noise $r gs_q 12]
		set used {}
		set sused {}
		for {set i 0} {$i < 8} {incr i} {
			set_property BEL [lindex $low_ffs $i] [lindex $j $i];  set_property LOC $js [lindex $j $i]
			lappend used "$js/[lindex $low_ffs $i]"
			#	both positions before either place: placing one of a
			#	synchroniser pair makes the tool put the other beside it
			set_property BEL [lindex $low_ffs $i] [lindex $gm $i]
			set_property BEL [lindex $high_ffs $i] [lindex $gs $i]
			set_property LOC $ss [lindex $gm $i]
			set_property LOC $ss [lindex $gs $i]
			lappend sused "$ss/[lindex $low_ffs $i]" "$ss/[lindex $high_ffs $i]"
		}
		karu_rosc_prohibit_rest [list $ss] $sused
		#	the inverter that closes the Johnson counter: in front of its first flop
		set inv [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of_objects [get_pins [lindex $j 0]/D]] -filter {DIRECTION == OUT}]]
		if {[llength $inv] != 1 || [get_property REF_NAME $inv] ne "LUT1"} { error "karu_rosc: $name: the Johnson counter's inverter is not one LUT1 ($inv)" }
		set_property BEL A6LUT $inv; set_property LOC $js $inv
		lappend used "$js/A6LUT"
		#	the divider and the selector: fixed positions and pins, the ring
		#	on the fastest pin of each, alike for every ring
		foreach {cell bel} {div_m B6LUT div_s C6LUT div_x D6LUT} {
			set c [get_cells -quiet "$noise/g_rings.g_cnt\[$r\].cnt/$cell"]
			if {[llength $c] != 1 || [get_property REF_NAME $c] ne "LUT3"} { error "karu_rosc: $name: the divider's $cell is not one LUT3" }
			set_property BEL $bel $c; set_property LOC $js $c
			set_property LOCK_PINS {I0:A6 I1:A5 I2:A4} $c
			lappend used "$js/$bel"
		}
		#	The two latches are loops by design: each holds itself, and they
		#	feed each other. The loop check must know, or it refuses the
		#	design; the attribute on the wires in the RTL does not reach these
		#	nets, so it is set here, on the nets the two tables drive.
		foreach cell {div_m div_s} {
			set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets -of_objects [get_pins "$noise/g_rings.g_cnt\[$r\].cnt/$cell/O"]]
		}
		karu_rosc_prohibit_rest [list $js] $used
		set used {}
		foreach {cells ffs lut} [list $a {AFF BFF} A6LUT $b {EFF FFF} E6LUT] {
			for {set i 0} {$i < 2} {incr i} {
				set_property BEL [lindex $ffs $i] [lindex $cells $i]; set_property LOC $cs [lindex $cells $i]
				lappend used "$cs/[lindex $ffs $i]"
			}
			#	a coarse counter's own inverter
			set inv [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of_objects [get_pins [lindex $cells 0]/D]] -filter {DIRECTION == OUT}]]
			if {[llength $inv] != 1 || [get_property REF_NAME $inv] ne "LUT1"} { error "karu_rosc: $name: a coarse counter's inverter is not one LUT1 ($inv)" }
			set_property BEL $lut $inv; set_property LOC $cs $inv
			lappend used "$cs/$lut"
		}
		karu_rosc_prohibit_rest [list $cs] $used

		#	timing: the counter's clock on the selector's output, the two
		#	Johnson flops that clock the coarse counters as clocks derived
		#	from it
		set out [get_pins "$noise/g_rings.g_cnt\[$r\].cnt/div_x/O"]
		if {[llength $out] != 1} { error "karu_rosc: $name: no selector output for the counter's clock" }
		create_clock -name rosc$r -period $clock_ns($want) $out
		create_generated_clock -name rosc${r}_a -source $out -divide_by 16 [get_pins [lindex $j 0]/Q]
		create_generated_clock -name rosc${r}_b -source $out -divide_by 16 [get_pins [lindex $j 7]/Q]
		#	into the clock domain: short, and for the Johnson bits alike
		set_max_delay -datapath_only -from $j -to [lrange $gm 0 7] 0.500
		#	(the tool's bus skew adds on-chip variation to the spread of
		#	the routes; 0.65 of the counter's declared period. The router
		#	cannot apply it to bits 0 and 7, whose outputs also clock the
		#	coarse counters and so are clock sources to it (Route 35-462);
		#	karu_check_rosc_count checks the spread of all eight routes.)
		set_bus_skew -from $j -to [lrange $gm 0 7] [expr {0.65 * $clock_ns($want)}]
		set_max_delay -datapath_only -from [concat $a $b] -to [lrange $gm 8 11] 1.000
		#	the clear, from the clock domain
		set clr [get_cells "$noise/clr_q_reg\[$r\]"]
		if {[llength $clr] != 1} { error "karu_rosc: $name: no clear register clr_q_reg\[$r\]" }
		set_max_delay -datapath_only -from $clr -to [concat $j $a $b] 4.000
		set declared($r) $clock_ns($want)
		lappend summary "$name [join $ring_sites +] divider and counter $js samplers $ss coarse $cs clock $clock_ns($want)"
		incr r
	}

	#	every ring has a sampling flip-flop, the references too (their bits
	#	are for characterisation only)
	set samp [get_pins -hierarchical -filter "NAME =~ $noise/samp_q_reg\[*\]/D"]
	if {[llength $samp] != [llength $rings]} { error "karu_rosc: expected [llength $rings] sampling flip-flops, found [llength $samp]" }
	set_false_path -to $samp
	puts "KARU_ROSC_CONSTRAINTS rings=[llength $rings]: [join $summary {; }]; sampling paths cut"
}

#	After place_design: every ring stage and every counter flop where it
#	was put, and no ring slice shared with anything else.
proc karu_check_rosc_placement {} {
	set noise [karu_rosc_noise]
	set seen {}
	set r 0
	foreach ring [karu_rosc_rings $noise] {
		lassign $ring name kind idx want
		set luts [karu_rosc_ring_luts $noise $ring]
		set sites [lsort -unique [get_property LOC $luts]]
		foreach site $sites {
			if {[lsearch -exact $seen $site] >= 0} { error "karu_rosc: rings share $site" }
			lappend seen $site
			foreach c [get_cells -quiet -filter "LOC == $site" -hierarchical] {
				if {[lsearch -exact $luts $c] < 0} { error "karu_rosc: $c shares $site with $name" }
			}
		}
		set j [karu_rosc_cnt_cells $noise $r j_q 8]
		set jsite [lsort -unique [get_property LOC $j]]
		set csite [lsort -unique [get_property LOC [concat [karu_rosc_cnt_cells $noise $r a_q 2] [karu_rosc_cnt_cells $noise $r b_q 2]]]]
		set ssite [lsort -unique [get_property LOC [lrange [karu_rosc_cnt_cells $noise $r gm_q 12] 0 7]]]
		if {[llength $jsite] != 1 || [llength $csite] != 1 || [llength $ssite] != 1} { error "karu_rosc: $name: the counter is not in one slice per part ($jsite; $ssite; $csite)" }
		puts "KARU_ROSC_PLACED $name: [llength $luts] stages in [join $sites ,]; counter in $jsite, samplers in $ssite, coarse counters in $csite"
		incr r
	}
}

#	Delays as the timing model has them, in ns, in one corner (SLOW or FAST):
#	a net from its driver to one load, {min max} (the model gives a net one
#	delay for both edges); a cell from one input to its output for one
#	output edge (RISE or FALL), {min max}; and an arc's sense.
proc karu_rosc_net_mm {net pin corner} {
	if {[lsearch -exact [get_pins -leaf -of_objects $net] $pin] < 0} { error "karu_rosc: $pin is not on net $net: something was put in between" }
	foreach d [get_net_delays -of_objects $net -to $pin] {
		return [list [expr {[get_property ${corner}_MIN $d] / 1000.0}] [expr {[get_property ${corner}_MAX $d] / 1000.0}]]
	}
	error "karu_rosc: no delay for $net to $pin"
}
proc karu_rosc_arc_mm {from to corner edge} {
	foreach a [get_timing_arcs -from $from -to $to] {
		return [list [get_property DELAY_${corner}_MIN_${edge} $a] [get_property DELAY_${corner}_MAX_${edge} $a]]
	}
	error "karu_rosc: no timing arc from $from to $to"
}
proc karu_rosc_arc_sense {from to} {
	foreach a [get_timing_arcs -from $from -to $to] { return [get_property SENSE $a] }
	error "karu_rosc: no timing arc from $from to $to"
}
#	A cell's delay over both output edges: {smallest min, largest max}; and
#	the largest difference between its rising and its falling delay.
proc karu_rosc_arc_any {from to corner} {
	lassign [karu_rosc_arc_mm $from $to $corner RISE] rlo rhi
	lassign [karu_rosc_arc_mm $from $to $corner FALL] flo fhi
	return [list [expr {min($rlo, $flo)}] [expr {max($rhi, $fhi)}] [expr {max(abs($rlo - $flo), abs($rhi - $fhi))}]]
}

#	One ring's two halves in one corner, edge by edge round its loop from
#	its output (the net that reaches the divider): the time from a rising
#	edge there to the falling edge that follows (H) and from a falling edge
#	to the rising one (L), each as {min max} from the arcs of the edges that
#	actually travel, following each arc's sense; and the largest difference
#	between an arc's rising and falling delay on the loop. Returns
#	{H_min H_max L_min L_max uneven}.
proc karu_rosc_halves {luts corner} {
	set want [llength $luts]
	set order [concat [list [lindex $luts end]] $luts]
	set out {}
	set uneven 0.0
	foreach start {RISE FALL} {
		set edge $start
		set lo 0.0
		set hi 0.0
		for {set k 0} {$k < $want} {incr k} {
			set c [lindex $order $k]
			set nxt [lindex $order [expr {$k + 1}]]
			set net [get_nets -of_objects [get_pins $c/O]]
			set inpin {}
			foreach pn [get_pins -of_objects $nxt -filter {DIRECTION == IN}] {
				if {[get_nets -quiet -of_objects $pn] eq $net} { set inpin $pn }
			}
			if {$inpin eq ""} { error "karu_rosc: $c does not drive $nxt" }
			set opin [get_pins $nxt/O]
			switch -- [karu_rosc_arc_sense $inpin $opin] {
				negative_unate { set oedge [expr {$edge eq "RISE" ? "FALL" : "RISE"}] }
				positive_unate { set oedge $edge }
				default { error "karu_rosc: the arc $inpin to $opin is [karu_rosc_arc_sense $inpin $opin]: a ring stage must be an inverter or the enable gate" }
			}
			lassign [karu_rosc_net_mm $net $inpin $corner] nlo nhi
			lassign [karu_rosc_arc_mm $inpin $opin $corner $oedge] alo ahi
			set uneven [expr {max($uneven, [lindex [karu_rosc_arc_any $inpin $opin $corner] 2])}]
			set lo [expr {$lo + $nlo + $alo}]
			set hi [expr {$hi + $nhi + $ahi}]
			set edge $oedge
		}
		if {$edge eq $start} { error "karu_rosc: the ring does not invert round its loop" }
		lappend out $lo $hi
	}
	return [concat $out $uneven]
}

#	The tool's own pulse-width report for some cells, as rows
#	{type corner required actual slack pin}.
proc karu_rosc_pulse_rows {cells} {
	set rows {}
	foreach line [split [report_pulse_width -return_string -significant_digits 3 -limit 100000 -cells $cells] "\n"] {
		if {[regexp {^(Min Period|Low Pulse Width|High Pulse Width)\s+(\S+)\s+\S+\s+\S+\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\S+\s+(\S+)\s*$} \
			$line -> type corner req act slack pin]} {
			lappend rows [list $type $corner $req $act $slack $pin]
		}
	}
	return $rows
}

#	After route_design. The timing model gives each delay four values: a
#	minimum and a maximum in the slow corner and in the fast one. Each check
#	below is made in four states, every delay taken from the same one of the
#	four columns (slow max, slow min, fast max, fast min): voltage,
#	temperature and process move neighbouring cells together, and in one
#	state the ring and the cells next to it are at one point. A check that
#	compares delays of one state with each other holds in all four. The
#	model's spread between a corner's minimum and maximum is large (about
#	30 to 45 %); taking, for each delay of a condition, whichever end hurts
#	it, independently for cells side by side, and without removing the
#	pessimism of the common path as the tool's own analysis does, is printed
#	for the divider as a diagnostic ("mixed"), not required: the two latches
#	share a slice, but their clock inputs are distinct route endpoints, and
#	only the shared part of a route justifies cancelling its variation. The
#	80 % limit below is the engineering allowance left for neighbouring
#	cells to differ. For each ring:
#	  its halves H and L, edge by edge (karu_rosc_halves), each as at least
#	    the duty allowance of the ring's period (KARU_ROSC_DUTY_MIN, 0.48;
#	    see the head of this file), the period P = H + L;
#	  the divider (d a table's delay, c the ring's arrival at a latch's
#	    clock pin, r_xy the route from x's output to y's input; the master
#	    is open while the ring is low, the slave while it is high; the six
#	    conditions under which the two latches divide by exactly two, from
#	    the bench sweeps of test/tb_rosc_meter.sv), each edge where it acts:
#	      rising edge: the master closes before the slave's new output
#	        reaches it                    c_m(r) - c_s(r) < d_s + r_sm
#	      falling edge: the slave closes before the master's new output
#	        reaches it                    c_s(f) - c_m(f) < d_m + r_ms
#	      the slave's new output reaches the master before the master opens
#	                                      d_s + r_sm + c_s(r) - c_m(f) < H
#	      the master's new output reaches the slave before the slave opens
#	                                      d_m + r_ms + c_m(f) - c_s(r) < L
#	      each latch holds itself before it closes
#	                                      d_s + r_ss < H + c_s(f) - c_s(r)
#	                                      d_m + r_mm < L + c_m(r) - c_m(f)
#	    each left side at most 80 % of its right side in each state, with a
#	    table's slowest input and edge where a delay must be short and its
#	    fastest where it must be long; the model gives a route one delay for
#	    both edges, so c(r) = c(f) at a pin;
#	  the counter's clock: its period 2 P and its shorter pulse, at least
#	    2 x 0.48 x P less any rise/fall difference the model gives on the
#	    slave and the selector, in the fast corner at least the declared
#	    period and half of it, so that the tool's own checks, made with the
#	    declared waveform, bound the routed clock in both halves; and the
#	    tool's pulse-width report at every counter flip-flop (minimum period,
#	    minimum high and low pulse, both corners) with no negative slack.
#	    The period and pulse the flip-flops need are taken from that report
#	    (0.550 and 0.275 ns for a slice flip-flop of this part), and the
#	    routed clock must give at least 1.1 times each;
#	  the paths between the Johnson flip-flops: no negative slack at the
#	    declared period;
#	  the spread of the eight sampled bits' routes: at most half a counter
#	    period (at one period a sample could show a later bit changed and an
#	    earlier one not);
#	  a coarse counter at its sampler: at most 2.5 counter periods later
#	    than the earliest Johnson bit and at most 2.5 earlier than the
#	    latest (the decode allows three and four);
#	  ring periods per system clock in the fast corner below 56 (the meter
#	    unwraps modulo 64, also when it counts the ring directly).
proc karu_check_rosc_count {{clk_ns 13.333}} {
	set duty_min 0.48
	if {[info exists ::env(KARU_ROSC_DUTY_MIN)] && $::env(KARU_ROSC_DUTY_MIN) ne ""} { set duty_min $::env(KARU_ROSC_DUTY_MIN) }
	if {$duty_min <= 0.25 || $duty_min > 0.5} { error "karu_rosc: KARU_ROSC_DUTY_MIN=$duty_min is not a share of a period between 0.25 and 0.5" }
	set noise [karu_rosc_noise]
	set r 0
	set bad 0
	foreach ring [karu_rosc_rings $noise] {
		lassign $ring name kind idx want
		set why {}
		set luts [karu_rosc_ring_luts $noise $ring]
		set cnt "$noise/g_rings.g_cnt\[$r\].cnt"
		set ringnet [get_nets -of_objects [get_pins [lindex $luts end]/O]]
		set mq [get_nets -of_objects [get_pins $cnt/div_m/O]]
		set sq [get_nets -of_objects [get_pins $cnt/div_s/O]]
		set declared [get_property PERIOD [get_clocks rosc$r]]
		set div_worst 0.0
		set div_text {}
		set mix_text {}
		set half_text {}
		set model_uneven 0.0
		foreach corner {SLOW FAST} {
			lassign [karu_rosc_halves $luts $corner] h_lo h_hi l_lo l_hi uneven
			set model_uneven [expr {max($model_uneven, $uneven)}]
			lappend half_text [format "%s %.3f/%.3f to %.3f/%.3f" [string tolower $corner] $h_lo $l_lo $h_hi $l_hi]
			set nets [list \
				[karu_rosc_net_mm $ringnet [get_pins $cnt/div_m/I0] $corner] \
				[karu_rosc_net_mm $ringnet [get_pins $cnt/div_s/I0] $corner] \
				[karu_rosc_net_mm $sq [get_pins $cnt/div_m/I2] $corner] \
				[karu_rosc_net_mm $mq [get_pins $cnt/div_s/I2] $corner] \
				[karu_rosc_net_mm $sq [get_pins $cnt/div_s/I1] $corner] \
				[karu_rosc_net_mm $mq [get_pins $cnt/div_m/I1] $corner]]
			#	a table's arcs, every input and both edges: {min max} each
			foreach t {m s} {
				set arcs($t) {}
				foreach pin {I0 I1 I2} {
					foreach edge {RISE FALL} {
						lappend arcs($t) [karu_rosc_arc_mm [get_pins $cnt/div_$t/$pin] [get_pins $cnt/div_$t/O] $corner $edge]
					}
				}
			}
			set path_mm [list [karu_rosc_arc_any [get_pins $cnt/div_s/I0] [get_pins $cnt/div_s/O] $corner] \
				[karu_rosc_arc_any [get_pins $cnt/div_x/I1] [get_pins $cnt/div_x/O] $corner]]
			set path_uneven [expr {[lindex $path_mm 0 2] + [lindex $path_mm 1 2]}]
			set model_uneven [expr {max($model_uneven, $path_uneven)}]
			#	---- four uniform states: every delay from one column ----
			foreach col {0 1} cname {min max} {
				set hh [lindex [list $h_lo $h_hi] $col]
				set ll [lindex [list $l_lo $l_hi] $col]
				set pp [expr {$hh + $ll}]
				set per($corner,$cname) $pp
				set hh [expr {min($hh, $duty_min * $pp)}]
				set ll [expr {min($ll, $duty_min * $pp)}]
				lassign [lmap n $nets {lindex $n $col}] cm cs rsm rms rss rmm
				foreach t {m s} {
					set v [lmap x $arcs($t) {lindex $x $col}]
					set dlo($t) [tcl::mathfunc::min {*}$v]
					set dhi($t) [tcl::mathfunc::max {*}$v]
				}
				set skew [expr {$cm - $cs}]
				set q [list \
					[expr {$skew / ($dlo(s) + $rsm)}] \
					[expr {-$skew / ($dlo(m) + $rms)}] \
					[expr {($dhi(s) + $rsm - $skew) / $hh}] \
					[expr {($dhi(m) + $rms + $skew) / $ll}] \
					[expr {($dhi(s) + $rss) / $hh}] \
					[expr {($dhi(m) + $rmm) / $ll}]]
				foreach v $q { if {$v > $div_worst} { set div_worst $v } }
				lappend div_text [format "%s %s %s" [string tolower $corner] $cname [join [lmap v $q {format %.0f%% [expr {100.0 * $v}]}] {/}]]
				#	the divided clock's shorter pulse: one ring period, less the allowance and the model's rise/fall difference on the slave and the selector
				set pulse($corner,$cname) [expr {2 * $duty_min * $pp - $path_uneven}]
			}
			#	---- for information: the corner's min and max mixed against each condition ----
			set p_lo [expr {$h_lo + $l_lo}]
			set hh [expr {min($h_lo, $duty_min * $p_lo)}]
			set ll [expr {min($l_lo, $duty_min * $p_lo)}]
			lassign $nets cm cs rsm rms rss rmm
			foreach t {m s} {
				set dlo($t) [tcl::mathfunc::min {*}[lmap x $arcs($t) {lindex $x 0}]]
				set dhi($t) [tcl::mathfunc::max {*}[lmap x $arcs($t) {lindex $x 1}]]
			}
			set q [list \
				[expr {([lindex $cm 1] - [lindex $cs 0]) / ($dlo(s) + [lindex $rsm 0])}] \
				[expr {([lindex $cs 1] - [lindex $cm 0]) / ($dlo(m) + [lindex $rms 0])}] \
				[expr {($dhi(s) + [lindex $rsm 1] + [lindex $cs 1] - [lindex $cm 0]) / $hh}] \
				[expr {($dhi(m) + [lindex $rms 1] + [lindex $cm 1] - [lindex $cs 0]) / $ll}] \
				[expr {($dhi(s) + [lindex $rss 1]) / ($hh + [lindex $cs 0] - [lindex $cs 1])}] \
				[expr {($dhi(m) + [lindex $rmm 1]) / ($ll + [lindex $cm 0] - [lindex $cm 1])}]]
			lappend mix_text [format "%s %s" [string tolower $corner] [join [lmap v $q {format %.0f%% [expr {100.0 * $v}]}] {/}]]
		}
		if {$div_worst > 0.80} { lappend why "a divider condition uses more than 80 % of its limit" }
		set p_fast $per(FAST,min)
		set p_slow $per(SLOW,max)
		set pul_fast [tcl::mathfunc::min {*}[lmap k [array names pulse] {set pulse($k)}]]
		array unset pulse

		#	---- the counter's clock against the declaration and the tool's own pulse-width report ----
		set j  [karu_rosc_cnt_cells $noise $r j_q 8]
		set a  [karu_rosc_cnt_cells $noise $r a_q 2]
		set b  [karu_rosc_cnt_cells $noise $r b_q 2]
		set gm [karu_rosc_cnt_cells $noise $r gm_q 12]
		if {2 * $p_fast < $declared - 1e-6 || $pul_fast < $declared / 2 - 1e-6} {
			lappend why [format "the routed clock could be faster than declared: period %.3f ns and shorter pulse %.3f ns, declared %.3f and %.3f" \
				[expr {2 * $p_fast}] $pul_fast $declared [expr {$declared / 2}]]
		}
		set rows [karu_rosc_pulse_rows [concat $j $a $b]]
		set req_per 0.0
		set req_pul 0.0
		set worst 1e9
		foreach row $rows {
			lassign $row type corner req act slack pin
			if {$slack < $worst} { set worst $slack }
			if {[lsearch -exact $j [get_cells -of_objects [get_pins $pin]]] < 0} { continue }
			if {$type eq "Min Period"} {
				set req_per [expr {max($req_per, $req)}]
				if {abs($act - $declared) > 0.0015} { lappend why "the pulse-width report checks $pin at a period of $act ns, not the declared $declared" }
			} else {
				set req_pul [expr {max($req_pul, $req)}]
				if {abs($act - $declared / 2) > 0.0015} { lappend why "the pulse-width report checks $pin with a pulse of $act ns, not half the declared period" }
			}
			lappend seen($type) $pin
		}
		foreach c [concat $j $a $b] {
			set types [expr {[lsearch -exact $j $c] >= 0 ? {{Min Period} {Low Pulse Width} {High Pulse Width}} : {{Low Pulse Width} {High Pulse Width}}}]
			foreach type $types {
				set n 0
				foreach row $rows { if {[lindex $row 0] eq $type && [lindex $row 5] eq "$c/C"} { incr n } }
				if {$n == 0} { lappend why "the pulse-width report has no $type check at $c/C" }
			}
		}
		if {[llength $rows] == 0} { error "karu_rosc: $name: the pulse-width report has no rows for the counter: has its format changed?" }
		if {$worst < 0} { lappend why [format "the pulse-width report has negative slack at the counter (%.3f ns)" $worst] }
		if {$req_per <= 0 || $req_pul <= 0} { lappend why "the pulse-width report gives no minimum period or pulse for the Johnson flip-flops" } else {
			set f_per [expr {2 * $p_fast / $req_per}]
			set f_pul [expr {$pul_fast / $req_pul}]
			if {$f_per < 1.1 || $f_pul < 1.1} { lappend why "the counter's clock is within 10 % of the flip-flop's limits in the fast corner" }
		}
		array unset seen

		#	between Johnson flops, at the declared period
		set slack 1e9
		foreach path [get_timing_paths -quiet -from $j -to $j -max_paths 64 -nworst 1 -setup] {
			if {[get_property SLACK $path] < $slack} { set slack [get_property SLACK $path] }
		}
		if {$slack == 1e9} { error "karu_rosc: $name: no timed path between the Johnson flip-flops; is the counter's clock defined?" }
		if {$slack < 0} { lappend why "a path between the Johnson flip-flops fails at the declared period" }
		#	the eight routes into the samplers, and a coarse counter from its
		#	Johnson flop's output through its clock pin to its sampler, in each corner
		set spread 0.0
		set late 0.0
		set early 0.0
		foreach corner {SLOW FAST} {
			foreach col {0 1} cname {min max} {
				set cp [expr {2 * $per($corner,$cname)}]
				set lo 1e9
				set hi 0.0
				for {set i 0} {$i < 8} {incr i} {
					set net [get_nets -of_objects [get_pins [lindex $j $i]/Q]]
					set d [lindex [karu_rosc_net_mm $net [get_pins [lindex $gm $i]/D] $corner] $col]
					set lo [expr {min($lo, $d)}]
					set hi [expr {max($hi, $d)}]
				}
				set spread [expr {max($spread, ($hi - $lo) / $cp)}]
				set t_lo 1e9
				set t_hi 0.0
				foreach {cells jbit base} [list $a 0 8 $b 7 10] {
					set jq [get_nets -of_objects [get_pins [lindex $j $jbit]/Q]]
					for {set i 0} {$i < 2} {incr i} {
						set c [lindex $cells $i]
						set d1 [lindex [karu_rosc_net_mm $jq [get_pins $c/C] $corner] $col]
						set d2r [lindex [karu_rosc_arc_mm [get_pins $c/C] [get_pins $c/Q] $corner RISE] $col]
						set d2f [lindex [karu_rosc_arc_mm [get_pins $c/C] [get_pins $c/Q] $corner FALL] $col]
						set d3 [lindex [karu_rosc_net_mm [get_nets -of_objects [get_pins $c/Q]] [get_pins [lindex $gm [expr {$base + $i}]]/D] $corner] $col]
						set t_lo [expr {min($t_lo, $d1 + min($d2r, $d2f) + $d3)}]
						set t_hi [expr {max($t_hi, $d1 + max($d2r, $d2f) + $d3)}]
					}
				}
				set late  [expr {max($late, ($t_hi - $lo) / $cp)}]
				set early [expr {max($early, ($hi - $t_lo) / $cp)}]
			}
		}
		if {$spread > 0.5} { lappend why "the sampled bits' routes differ by more than half a counter period" }
		if {$late > 2.5 || $early > 2.5} { lappend why "a coarse counter is more than 2.5 counter periods from the Johnson bits at the samplers" }
		set per_clk_fast [expr {$clk_ns / $p_fast}]
		if {$per_clk_fast >= 56.0} { lappend why "the ring makes 56 periods or more per system clock in the fast corner" }
		if {[llength $why]} { incr bad }
		puts [format "KARU_ROSC_COUNT %s: ring halves rise-to-fall/fall-to-rise, edge by edge, %s ns (the model's largest rise/fall difference on these arcs %.3f ns; each half taken as at least %.2f of the period); ring period %.3f ns slow, %.3f ns fast (%.1f to %.1f per %.3f ns clock); divider conditions, share of limit, every delay of one state: %s (worst %.0f%%; with the corner's min and max mixed against each, for information: %s); counter clock in the fast corner: period %.3f ns, shorter pulse at least %.3f ns, declared %.3f and %.3f; pulse-width report at the %d counter clock pins: %d checks, worst slack %.3f ns, the flip-flop needs %.3f and %.3f ns, the routed clock gives %.2f and %.2f times that; Johnson paths slack %.3f ns at the declared period; sampling spread %.2f and coarse counters %.2f late, %.2f early, in counter periods: %s" \
			$name [join $half_text {, }] $model_uneven $duty_min $p_slow $p_fast [expr {$clk_ns / $p_slow}] $per_clk_fast $clk_ns [join $div_text {, }] \
			[expr {100.0 * $div_worst}] [join $mix_text {, }] \
			[expr {2 * $p_fast}] $pul_fast $declared [expr {$declared / 2}] [llength [concat $j $a $b]] [llength $rows] $worst $req_per $req_pul \
			[expr {$req_per > 0 ? 2 * $p_fast / $req_per : 0}] [expr {$req_pul > 0 ? $pul_fast / $req_pul : 0}] $slack $spread \
			[expr {$late > 0 ? $late : 0.0}] [expr {$early > 0 ? $early : 0.0}] [expr {[llength $why] ? "FAIL: [join $why {; }]" : "ok"}]]
		incr r
	}
	if {$bad} { error "karu_rosc: $bad ring counter(s) outside the limits" }
}
