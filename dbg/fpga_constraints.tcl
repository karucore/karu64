# USER4's gated DRCK is the conventional DTM's clock inside this platform.
# Keep bundled payload and released-reset consumer paths timed. Exceptions
# cover the four first-stage control D pins, eight incoming asynchronous
# reset pins of the four two-stage reset-release helpers, and asynchronous
# core/DRCK hold checks. No exception cuts raw-TCK/DRCK functional paths.
proc karudbg_constrain_bscan {} {
    set drck [get_pins -hier -filter {NAME =~ *u_debug_transport/bscan/DRCK}]
    set raw_tck [get_pins -hier -filter {NAME =~ *u_debug_transport/bscan/TCK}]
    set internal_tck [get_pins -hier -filter {NAME =~ *u_debug_transport/bscan/INTERNAL_TCK}]
    if {[llength $drck] != 1} { error "karudbg: missing unique USER4 DRCK pin" }
    if {[llength $raw_tck] != 1} { error "karudbg: missing unique USER4 TCK pin" }
    if {[llength $internal_tck] != 1} { error "karudbg: missing unique USER4 INTERNAL_TCK pin" }
    # The hard BSCANE2 samples fabric TDO on this internal clock's falling
    # edge. Starting only at the exported TCK output leaves TDO unconstrained.
    create_clock -name karudbg_internal_tck -period 100.0 $internal_tck
    create_generated_clock -name karudbg_physical_tck -source $internal_tck -divide_by 1 $raw_tck
    create_generated_clock -name karudbg_tck -source $raw_tck -divide_by 1 $drck
    # These four helpers assert reset asynchronously and release after two
    # destination-clock edges. Their incoming asynchronous reset pins are
    # synchronizer boundaries, not recovery/removal targets. Keep stage Q->D
    # and every released-reset Q->functional-consumer path fully timed.
    foreach instance {
        u_debug_bus_reset/ui_cancel
        u_debug_bus_reset/cpu_cancel
        u_debug_transport/frame_reset_release
        u_debug_transport/reset_release
    } {
        set stages [get_cells -hier -filter "NAME =~ *${instance}/release_q_reg*"]
        if {[llength $stages] != 2} { error "karudbg: missing two reset stages in $instance" }
        foreach stage $stages {
            if {[string toupper [get_property ASYNC_REG $stage]] ni {TRUE 1}} {
                error "karudbg: reset stage lacks ASYNC_REG: $stage"
            }
        }
        set reset_pins [get_pins -of_objects $stages -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
        if {[llength $reset_pins] != 2} { error "karudbg: missing two asynchronous reset pins in $instance" }
        set_false_path -to $reset_pins
    }
    set tck [get_clocks karudbg_tck]
    set first [get_cells -hier -filter {NAME =~ *u_debug_transport/dtm/cdc/req_sync1_reg}]
    if {[llength $first] != 1} { error "karudbg: missing request synchronizer" }
    set core_clock [get_clocks -of_objects [get_pins -of_objects $first -filter {REF_PIN_NAME == C}]]
    if {[llength $core_clock] != 1} { error "karudbg: ambiguous core clock" }
    set core_period [get_property PERIOD $core_clock]
    set_max_delay -datapath_only [expr {$core_period * 0.8}] -from $tck -to $core_clock
    set_max_delay -datapath_only 80.0 -from $core_clock -to $tck
    set_false_path -hold -from $tck -to $core_clock
    set_false_path -hold -from $core_clock -to $tck
    foreach signal {req_sync1 clear_sync1 resp_sync1 ack_sync1} {
        set flop [get_cells -hier -filter "NAME =~ *u_debug_transport/dtm/cdc/${signal}_reg"]
        if {[llength $flop] != 1} { error "karudbg: missing unique $signal" }
        set_false_path -to [get_pins -of_objects $flop -filter {REF_PIN_NAME == D}]
    }
    set requests [get_cells -hier -filter {NAME =~ *u_debug_transport/dtm/cdc/request_payload_reg*}]
    set captures [get_cells -hier -filter {NAME =~ *u_debug_transport/dtm/cdc/core_payload_reg*}]
    set responses [get_cells -hier -filter {NAME =~ *u_debug_transport/dtm/cdc/response_payload_reg*}]
    set consumers [get_cells -hier -filter {NAME =~ *u_debug_transport/dtm/last_data_reg* || NAME =~ *u_debug_transport/dtm/error_reg*}]
    foreach group [list $requests $captures $responses $consumers] {
        if {[llength $group] == 0} { error "karudbg: missing bundled CDC registers" }
    }
    set_bus_skew [expr {$core_period * 0.4}] -from $requests -to $captures
    set_bus_skew 40.0 -from $responses -to $consumers
    puts "KARUDBG_BSCAN_CONSTRAINTS core=$core_clock period=$core_period ns TCK=100 ns USER4 INTERNAL_TCK/TDO timed"
}
