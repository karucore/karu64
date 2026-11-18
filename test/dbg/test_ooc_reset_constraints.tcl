# SPDX-License-Identifier: BSD-3-Clause
# Exercise the conventional-top Vivado constraint block with a command model.
# This checks Tcl scope/guards, not actual netlist selection or physical timing.
# Run from any directory: tclsh test/dbg/test_ooc_reset_constraints.tcl
set root [file normalize [file join [file dirname [info script]] ../..]]
set handle [open [file join $root dbg vivado_ooc.tcl] r]
set source_text [read $handle]
close $handle
set begin [string first {create_clock -name clk} $source_text]
set end [string first {write_checkpoint -force [file join $out synth.dcp]} $source_text]
if {$begin < 0 || $end <= $begin} { error "Cannot locate OOC constraint block" }
set constraint_block [string range $source_text $begin [expr {$end - 1}]]

proc option {args name} {
    set index [lsearch -exact $args $name]
    if {$index < 0} { error "Missing $name in $args" }
    return [lindex $args [expr {$index + 1}]]
}
proc setup {mode} {
    global cells async_pins cuts delays clocks maxdelays skews period tck_period
    set period 5.0; set tck_period 100.0
    set cuts {}; set delays {}; set clocks {}; set maxdelays {}; set skews {}
    set cells [dict create]
    foreach n {0 1} {
        if {$mode eq "missing_stage" && $n == 1} { continue }
        set cell [format {tck_reset_release/release_q_reg[%d]} $n]
        dict set cells $cell [expr {$mode eq "missing_async_reg" && $n == 1 ? "FALSE" : "TRUE"}]
    }
    foreach name {req_sync1 clear_sync1 resp_sync1 ack_sync1} {
        dict set cells dtm/cdc/${name}_reg TRUE
    }
    foreach name {request_payload core_payload response_payload} {
        dict set cells dtm/cdc/${name}_reg_0 FALSE
    }
    dict set cells dtm/last_data_reg_0 FALSE
    dict set cells dtm/error_reg_0 FALSE
    set async_pins [list {tck_reset_release/release_q_reg[0]/CLR} \
        {tck_reset_release/release_q_reg[1]/CLR} dtm/state_reg/CLR dtm/tap/tdo_reg/PRE]
    if {$mode eq "missing_reset_pin"} { set async_pins [lreplace $async_pins 1 1] }
}
proc get_cells {args} {
    global cells
    set result {}
    foreach clause [split [string map {|| |} [option $args -filter]] |] {
        if {![regexp {NAME =~ ([^ ]+)} [string trim $clause] -> pattern]} { error "Unexpected cell selector" }
        foreach cell [dict keys $cells] {
            if {[string match $pattern $cell]} { lappend result $cell }
        }
    }
    return [lsort -unique $result]
}
proc get_pins {args} {
    if {[option $args -filter] ne "REF_PIN_NAME == D"} { error "Unexpected pin selector" }
    set result {}
    foreach cell [option $args -of_objects] { lappend result $cell/D }
    return $result
}
proc get_property {property object} {
    global cells
    if {$property eq "ASYNC_REG"} { return [dict get $cells $object] }
    if {$property eq "NAME"} { return $object }
    error "Unexpected property $property"
}
proc all_registers {args} {
    global async_pins
    if {[option $args -clock] ne "tck" || [lsearch -exact $args -async_pins] < 0} {
        error "Reset pins must be selected by TCK and asynchronous role"
    }
    return $async_pins
}
proc get_ports {args} {
    if {[lsearch -exact $args -filter] < 0} { return [lindex $args 0] }
    set filter [option $args -filter]
    set result {clk rst tck tms tdi trst_n data_i hart_reset_i}
    if {[string first {DIRECTION == OUT} $filter] >= 0} { set result {data_o tdo tdo_oe} }
    foreach {clause name} [regexp -all -inline {NAME != ([[:alnum:]_]+)} $filter] {
        set index [lsearch -exact $result $name]
        if {$index >= 0} { set result [lreplace $result $index $index] }
    }
    return $result
}
proc get_clocks {name} { return $name }
proc create_clock {args} { global clocks; dict set clocks [option $args -name] [option $args -period] }
proc set_false_path {args} { global cuts; lappend cuts $args }
proc set_max_delay {args} { global maxdelays; lappend maxdelays $args }
proc set_bus_skew {args} { global skews; lappend skews $args }
proc set_input_delay {args} { global delays; lappend delays $args }
proc set_output_delay {args} {}

proc check_scope {} {
    global cuts delays async_pins maxdelays skews
    set async_count 0; set hold_count 0; set control_count 0; set rst_count 0
    foreach cut $cuts {
        if {[lsearch -exact $cut -hold] >= 0} {
            if {[lsort [list [option $cut -from] [option $cut -to]]] ne {clk tck}} { error "Unexpected hold cut" }
            incr hold_count
        } elseif {[lsearch -exact $cut -from] >= 0} {
            if {[lsort [option $cut -from]] ne {rst trst_n} ||
                [lsort [option $cut -to]] ne [lsort $async_pins]} { error "Broad external reset cut" }
            incr async_count
        } else {
            foreach pin [option $cut -to] {
                if {![regexp {^dtm/cdc/(?:req_sync1|clear_sync1|resp_sync1|ack_sync1)_reg/D$} $pin]} {
                    error "Cut would hide released reset, synchronous data or payload timing: $pin"
                }
                incr control_count
            }
        }
    }
    foreach delay $delays {
        if {"rst" in [lindex $delay end]} {
            if {[option $delay -clock] ne "clk" || [lindex $delay 2] != 1.5} { error "Wrong synchronous reset input delay" }
            incr rst_count
        }
    }
    if {$async_count != 1 || $hold_count != 2 || $control_count != 4 || $rst_count != 1} { error "Wrong reset/control exception scope" }
    if {[llength $maxdelays] != 2 || [llength $skews] != 2} { error "Bundled data lost its timing constraints" }
}

setup positive
uplevel #0 $constraint_block
check_scope
puts "PASS OOC reset scope: clk reset timed; external reset cuts only TCK async pins; release/data paths retained"
set scoped {set_false_path -from [get_ports {rst trst_n}] -to $tck_async_resets}
foreach {name replacement} {
    broad_reset_cut {set_false_path -from [get_ports {rst trst_n}]}
    released_reset_cut {set_false_path -to $tck_async_resets}
} {
    setup positive
    set mutant [string map [list $scoped $replacement] $constraint_block]
    if {$mutant eq $constraint_block} { error "Mutation did not apply" }
    if {![catch {uplevel #0 $mutant; check_scope} why]} { error "Accepted bad reset scope: $name" }
    puts "PASS negative $name: $why"
}
foreach mode {missing_stage missing_async_reg missing_reset_pin} {
    setup $mode
    if {![catch {uplevel #0 $constraint_block} why]} { error "Missing guard for $mode" }
    puts "PASS negative $mode: $why"
}
puts "PASS OOC CONSTRAINT COMMAND MODEL (not netlist selection or physical timing)"
