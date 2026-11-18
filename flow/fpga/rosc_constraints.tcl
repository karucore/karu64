#	rosc_constraints.tcl -- constraints for the ring-oscillator noise source
#	(flow/fpga/karu_rosc_rng.v). Source it after synth_design and call
#	karu_constrain_rosc. The procedure checks what it constrains and stops the
#	build if the netlist is not what it expects.
#
#	What it does:
#	  * finds the rings by their nets and checks that synthesis kept every
#	    stage: ring s must be STAGES + 2*s LUTs (3, 5, 7, 9 by default), one
#	    of them the two-input enable gate and the rest inverters;
#	  * places every LUT by hand, in ring order, each on its own 6-input LUT
#	    position: ring s in the slice at column X + KARU_ROSC_STEP*s, row Y,
#	    continuing in the slice above when a ring has more than eight
#	    stages. The first slice is KARU_ROSC_BASE ("X Y"; default "100 450",
#	    in the middle SLR of the XCVU9P next to the processor). A region
#	    constraint (pblock) is not enough: the placer was seen to pack three
#	    rings into one slice outside their regions;
#	  * keeps everything else out of those slices, so that a ring shares a
#	    slice with nothing;
#	  * cuts the paths from the rings into the sampling flip-flops out of the
#	    timing analysis: they are asynchronous by design.
#
#	The rings are combinational loops. Their nets carry
#	ALLOW_COMBINATORIAL_LOOPS in the RTL, so the loop check is a warning
#	(LUTLP-2), and check_timing reports one loop per ring.

proc karu_constrain_rosc {} {
	set base {100 450}
	if {[info exists ::env(KARU_ROSC_BASE)] && $::env(KARU_ROSC_BASE) ne ""} { set base $::env(KARU_ROSC_BASE) }
	set step 4
	if {[info exists ::env(KARU_ROSC_STEP)] && $::env(KARU_ROSC_STEP) ne ""} { set step $::env(KARU_ROSC_STEP) }
	lassign $base bx by
	set bel_names {A6LUT B6LUT C6LUT D6LUT E6LUT F6LUT G6LUT H6LUT}

	set noise [get_cells -hierarchical -filter {ORIG_REF_NAME == karu_rosc_rng || REF_NAME == karu_rosc_rng}]
	if {[llength $noise] != 1} { error "karu_rosc: expected one karu_rosc_rng instance, found [llength $noise]" }
	set rings 0
	set summary {}
	for {set s 0} {$s < 16} {incr s} {
		set nets [get_nets -quiet -hierarchical -filter "NAME =~ $noise/g_rings.g_ring\[$s\].inv\[*\]"]
		if {[llength $nets] == 0} { break }
		set luts [lsort -unique [get_cells -of_objects [get_pins -leaf -of_objects $nets -filter {DIRECTION == OUT}]]]
		set want [expr {3 + 2 * $s}]
		if {[llength $nets] != $want || [llength $luts] != $want} {
			error "karu_rosc: ring $s has [llength $nets] nets driven by [llength $luts] cells, expected $want of each: synthesis changed the ring"
		}
		set gate {}
		foreach c $luts {
			set ref [get_property REF_NAME $c]
			if {$ref eq "LUT2"} { lappend gate $c } elseif {$ref ne "LUT1"} {
				error "karu_rosc: ring $s stage $c is a $ref, not an inverter or the enable gate"
			}
		}
		if {[llength $gate] != 1} { error "karu_rosc: ring $s has [llength $gate] enable gates, expected 1" }

		#	walk the loop from the enable gate, so that stage i gets position i
		set order {}
		set cur [lindex $gate 0]
		for {set i 0} {$i < $want} {incr i} {
			lappend order $cur
			set out [get_nets -of_objects [get_pins $cur/O]]
			set next {}
			foreach c [get_cells -of_objects [get_pins -leaf -of_objects $out -filter {DIRECTION == IN}]] {
				if {[lsearch -exact $luts $c] >= 0} { lappend next $c }
			}
			if {[llength $next] != 1} { error "karu_rosc: ring $s is not a single loop at $cur" }
			set cur [lindex $next 0]
		}
		if {$cur ne [lindex $gate 0] || [llength [lsort -unique $order]] != $want} {
			error "karu_rosc: ring $s does not close after $want stages"
		}

		set x [expr {$bx + $step * $s}]
		set used {}
		for {set i 0} {$i < $want} {incr i} {
			set site "SLICE_X${x}Y[expr {$by + $i / 8}]"
			if {[llength [get_sites -quiet $site]] != 1} {
				error "karu_rosc: $site is not a slice on this part; set KARU_ROSC_BASE"
			}
			set bel [lindex $bel_names [expr {$i % 8}]]
			set_property BEL $bel [lindex $order $i]
			set_property LOC $site [lindex $order $i]
			lappend used "$site/$bel"
			if {[lsearch -exact $summary $site] < 0} { lappend summary $site }
		}
		#	nothing else in a ring's slices
		foreach site [lsort -unique [lmap u $used {lindex [split $u /] 0}]] {
			foreach b [get_bels -of_objects [get_sites $site]] {
				if {[lsearch -exact $used $b] < 0} { set_property PROHIBIT TRUE $b }
			}
		}
		incr rings
	}
	if {$rings != 4} { error "karu_rosc: found $rings rings, expected 4" }

	set samp [get_pins -hierarchical -filter "NAME =~ $noise/samp_q_reg\[*\]/D"]
	if {[llength $samp] != 4} { error "karu_rosc: expected 4 sampling flip-flops, found [llength $samp]" }
	set_false_path -to $samp
	puts "KARU_ROSC_CONSTRAINTS rings=$rings slices=[join $summary ,] sampling paths cut"
}

#	After place_design: every ring stage where it was put, and no ring slice
#	shared with anything else.
proc karu_check_rosc_placement {} {
	set noise [get_cells -hierarchical -filter {ORIG_REF_NAME == karu_rosc_rng || REF_NAME == karu_rosc_rng}]
	set seen {}
	for {set s 0} {$s < 4} {incr s} {
		set nets [get_nets -hierarchical -filter "NAME =~ $noise/g_rings.g_ring\[$s\].inv\[*\]"]
		set luts [lsort -unique [get_cells -of_objects [get_pins -leaf -of_objects $nets -filter {DIRECTION == OUT}]]]
		set sites [lsort -unique [get_property LOC $luts]]
		foreach site $sites {
			if {[lsearch -exact $seen $site] >= 0} { error "karu_rosc: rings share $site" }
			lappend seen $site
			set others [get_cells -quiet -filter "LOC == $site" -hierarchical]
			foreach c $others {
				if {[lsearch -exact $luts $c] < 0} { error "karu_rosc: $c shares $site with ring $s" }
			}
		}
		puts "KARU_ROSC_PLACED ring $s: [llength $luts] stages in [join $sites ,]"
	}
}
