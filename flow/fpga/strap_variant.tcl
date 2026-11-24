#	strap_variant.tcl -- a second bitstream from a routed design, different
#	only in the soft straps of the entropy source (flow/fpga/karu_softstrap.v,
#	flow/fpga/karu_entropy_src.v). Nothing is placed or routed again: the
#	variant has the placement and the routing of the image it comes from,
#	the ring oscillators included, wire for wire.
#
#	Run through `make vcu118-strap-variant`. Environment:
#	    KARU_STRAP_DCP      the routed checkpoint          [_build/vcu118_ddr_route.dcp]
#	    KARU_STRAP_OUT      the bitstream to write         [required]
#	    KARU_STRAP_LANE     0..3: the lane seed delivers   [keep]
#	    KARU_STRAP_KSHIFT   0..3: spacing floor, k at least 16 << n [keep]
#	    KARU_STRAP_RINGS    mask of the rings that run outside test mode, e.g. 0x0f [keep]
#	A strap that is not given keeps the value of the checkpoint. The script
#	stops without writing a variant if it does not find exactly the strap
#	cells it expects, if a value does not read back, if the lane that seed
#	delivers would not be among the rings that run (the source could then
#	only fail its start-up test, and authentication would get no nonce), if
#	the straps asked for are those of the checkpoint (nothing to write), or
#	if any net is left unrouted. It prints a KARU_STRAP line with the straps
#	as built and one with the straps as written, KARU_STRAP_CHANGED with the
#	number of strap bits changed, and a KARU_STRAP_VARIANT line with the
#	values the bitstream has.
#
#	Before it changes anything it writes the checkpoint's own bitstream
#	again, to KARU_STRAP_OUT with ".base.bit" appended: flow/strap_diff.py
#	compares that with the image (it must be the same design) and with the
#	variant (only the straps may differ), records the three, and removes it.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

proc karu_strap_cells {name width} {
	set cells {}
	for {set i 0} {$i < $width} {incr i} {
		set c [get_cells -quiet -hierarchical -filter "REF_NAME == LUT1 && NAME =~ *g_strap_${name}\[$i\].s/g_lut.strap"]
		if {[llength $c] != 1} { error "karu_strap: expected one cell for strap $name\[$i\], found [llength $c]" }
		lappend cells $c
	}
	return $cells
}

#	The value of a strap as the design has it: bit 0 of each table's INIT.
#	Both bits of a table must agree, or the cell is not a strap as built.
proc karu_strap_get {name width} {
	set v 0
	set i 0
	foreach c [karu_strap_cells $name $width] {
		set init [get_property INIT $c]
		if {$init eq "2'h3"} { set v [expr {$v | (1 << $i)}] } elseif {$init ne "2'h0"} {
			error "karu_strap: $c has INIT $init, neither 2'h0 nor 2'h3"
		}
		incr i
	}
	return $v
}

proc karu_strap_set {name width value} {
	if {$value < 0 || $value >= (1 << $width)} { error "karu_strap: $name = $value does not fit $width bits" }
	set i 0
	foreach c [karu_strap_cells $name $width] {
		set_property INIT [expr {(($value >> $i) & 1) ? "2'h3" : "2'h0"}] $c
		incr i
	}
	if {[karu_strap_get $name $width] != $value} { error "karu_strap: $name does not read back $value" }
}

proc karu_strap_report {} {
	set lane [karu_strap_get lane 2]
	set kshift [karu_strap_get k 2]
	set rings [karu_strap_get ring 6]
	puts [format "KARU_STRAP lane=%d kshift=%d (k at least %d) rings=0x%02x" $lane $kshift [expr {16 << $kshift}] $rings]
	return [list $lane $kshift $rings]
}

#	Only when run as the script of a Vivado session, not when sourced for
#	the procedures (the image build prints the straps with karu_strap_report).
if {[info exists ::env(KARU_STRAP_OUT)] && $::env(KARU_STRAP_OUT) ne ""} {
	set dcp [karu_build_path vcu118_ddr_route.dcp]
	if {[info exists ::env(KARU_STRAP_DCP)] && $::env(KARU_STRAP_DCP) ne ""} { set dcp $::env(KARU_STRAP_DCP) }
	open_checkpoint $dcp
	puts "KARU_STRAP checkpoint $dcp, as built:"
	set built [karu_strap_report]
	#	what is asked for, checked before anything is written
	lassign $built lane kshift rings
	foreach {ename var width} {KARU_STRAP_LANE lane 2 KARU_STRAP_KSHIFT kshift 2 KARU_STRAP_RINGS rings 6} {
		if {[info exists ::env($ename)] && $::env($ename) ne ""} {
			set $var [expr {$::env($ename)}]
			if {[set $var] < 0 || [set $var] >= (1 << $width)} { error "karu_strap: $ename = $::env($ename) does not fit $width bits" }
		}
	}
	set changed 0
	foreach v0 $built v1 [list $lane $kshift $rings] {
		for {set x [expr {$v0 ^ $v1}]} {$x != 0} {set x [expr {$x >> 1}]} { incr changed [expr {$x & 1}] }
	}
	if {$changed == 0} { error "karu_strap: the straps asked for are those of the checkpoint; nothing to write" }
	if {!(($rings >> $lane) & 1)} {
		error [format "karu_strap: lane %d is not among the rings that run (0x%02x): seed would never leave its start-up test" $lane $rings]
	}
	set unrouted {ROUTE_STATUS == UNROUTED || ROUTE_STATUS == PARTIAL || ROUTE_STATUS == CONFLICTS || ROUTE_STATUS == ANTENNAS}
	set before [llength [get_nets -quiet -hierarchical -filter $unrouted]]
	#	the checkpoint's own bitstream, before any change
	write_bitstream -force "$::env(KARU_STRAP_OUT).base.bit"
	file attributes "$::env(KARU_STRAP_OUT).base.bit" -permissions 0600
	karu_strap_set lane 2 $lane
	karu_strap_set k 2 $kshift
	karu_strap_set ring 6 $rings
	set after [llength [get_nets -quiet -hierarchical -filter $unrouted]]
	if {$before != 0 || $after != 0} { error "karu_strap: nets not fully routed: $before before the change, $after after" }
	puts "KARU_STRAP as written:"
	set written [karu_strap_report]
	if {$written ne [list $lane $kshift $rings]} { error "karu_strap: the straps as written are not those asked for" }
	puts "KARU_STRAP_CHANGED $changed"
	write_bitstream -force $::env(KARU_STRAP_OUT)
	file attributes $::env(KARU_STRAP_OUT) -permissions 0600
	puts [format "KARU_STRAP_VARIANT %s lane=%d kshift=%d rings=0x%02x from %s" [file tail $::env(KARU_STRAP_OUT)] $lane $kshift $rings [file tail $dcp]]
}
