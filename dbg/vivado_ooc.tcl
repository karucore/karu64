# karudbg conventional-JTAG integration: VCU118-device out-of-context build.
# This establishes core/DM/DTM implementation timing, not board pinout, DDR,
# BSCAN, ROM packing or a bootable bitstream. Use the board flow for those.
set repo [file dirname [file dirname [file normalize [info script]]]]
set out [file join $repo _build dbg vivado_ooc]
if {[info exists ::env(KARU_DBG_OUT)]} { set out [file normalize $::env(KARU_DBG_OUT)] }
file mkdir $out
set threads 8
if {[info exists ::env(VIVADO_THREADS)]} { set threads $::env(VIVADO_THREADS) }
set_param general.maxThreads $threads
set manifest [file join $repo dbg karudbg.f]
set handle [open $manifest r]
set sources {}
while {[gets $handle line] >= 0} {
    regsub {//.*$} $line "" line
    regsub {#.*$} $line "" line
    set line [string trim $line]
    if {$line ne ""} { lappend sources [file normalize [file join $repo $line]] }
}
close $handle
set tracked [concat $sources [glob [file join $repo rtl *.vh]] \
    [glob [file join $repo dbg *.vh]] [list $manifest [file normalize [info script]]]]
set before [exec sha256sum {*}$tracked]
set h [open [file join $out inputs.before.sha256] w]; puts $h $before; close $h

set defines {KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK KARU_DBG
    KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64 KARU_V_MUL_CYCLES=16
    KARU_V_DIV_CYCLES=64 KARU_V_LANE_PIPE KARU_V_CWB_STAGE
    KARU_SMCNTRPMF KARU_SSCOFPMF}
if {[info exists ::env(KARU_DEFINES)]} { set defines $::env(KARU_DEFINES) }
if {[lsearch -exact $defines KARU_DBG] < 0} { lappend defines KARU_DBG }
set period [expr {1000.0 / 75.0}]
set tck_period 100.0
if {[info exists ::env(KARU_DBG_PERIOD)]} { set period $::env(KARU_DBG_PERIOD) }
if {[info exists ::env(KARU_DBG_TCK_PERIOD)]} { set tck_period $::env(KARU_DBG_TCK_PERIOD) }
set h [open [file join $out manifest.txt] w]
puts $h "UTC [clock format [clock seconds] -gmt 1 -format %Y-%m-%dT%H:%M:%SZ]"
puts $h "[version]"
puts $h "TOP=karudbg_top PART=xcvu9p-flga2104-2L-e CORE_PERIOD_NS=$period TCK_PERIOD_NS=$tck_period"
puts $h "DEFINES=$defines"
puts $h $before
close $h

create_project -in_memory -part xcvu9p-flga2104-2L-e
read_verilog $sources
synth_design -mode out_of_context -part xcvu9p-flga2104-2L-e -top karudbg_top \
    -include_dirs [list [file join $repo rtl] [file join $repo dbg]] \
    -verilog_define $defines -directive Default
create_clock -name clk -period $period [get_ports clk]
create_clock -name tck -period $tck_period [get_ports tck]
set_max_delay -datapath_only [expr {$period * 0.8}] -from [get_clocks tck] -to [get_clocks clk]
set_max_delay -datapath_only [expr {$tck_period * 0.8}] -from [get_clocks clk] -to [get_clocks tck]
set_false_path -hold -from [get_clocks tck] -to [get_clocks clk]
set_false_path -hold -from [get_clocks clk] -to [get_clocks tck]
foreach signal {req_sync1 clear_sync1 resp_sync1 ack_sync1} {
    set first [get_cells -hier -filter "NAME =~ */${signal}_reg"]
    if {[llength $first] != 1} {
        error "CDC constraint did not find exactly one $signal first-stage flop"
    }
    set_false_path -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]
}
set request_bundle [get_cells -hier -filter {NAME =~ */request_payload_reg*}]
set request_capture [get_cells -hier -filter {NAME =~ */core_payload_reg*}]
set response_bundle [get_cells -hier -filter {NAME =~ */response_payload_reg*}]
set response_capture [get_cells -hier -filter {NAME =~ */last_data_reg* || NAME =~ */error_reg*}]
foreach group [list $request_bundle $request_capture $response_bundle $response_capture] {
    if {[llength $group] == 0} { error "CDC payload constraint matched no registers" }
}
set_bus_skew [expr {$period * 0.4}] -from $request_bundle -to $request_capture
set_bus_skew [expr {$tck_period * 0.4}] -from $response_bundle -to $response_capture
# rst is a timed synchronous input to the core/DM clk domain. Exempt only
# external-reset paths into TCK-domain asynchronous reset pins; the released
# reset's registered Q -> consumer reset checks remain timed.
set release_stages [get_cells -hier -filter {NAME =~ tck_reset_release/release_q_reg*}]
if {[llength $release_stages] != 2} {
    error "Reset constraint did not find exactly two TCK release stages"
}
foreach stage $release_stages {
    if {[string toupper [get_property ASYNC_REG $stage]] ni {TRUE 1}} {
        error "TCK reset release stage lacks ASYNC_REG: $stage"
    }
}
set tck_async_resets [all_registers -clock [get_clocks tck] -async_pins]
set release_reset_count 0
foreach pin $tck_async_resets {
    if {[string match {tck_reset_release/*} [get_property NAME $pin]]} {
        incr release_reset_count
    }
}
if {$release_reset_count != 2} {
    error "Reset constraint did not find exactly two TCK release reset pins"
}
set_false_path -from [get_ports {rst trst_n}] -to $tck_async_resets
set_input_delay -clock clk [expr {$period * 0.3}] [get_ports rst]
set_input_delay -clock clk [expr {$period * 0.3}] \
    [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst && NAME != tck && NAME != tms && NAME != tdi && NAME != trst_n}]
set_output_delay -clock clk [expr {$period * 0.3}] \
    [get_ports -filter {DIRECTION == OUT && NAME != tdo && NAME != tdo_oe}]
set_input_delay -clock tck 10.0 [get_ports {tms tdi}]
set_output_delay -clock tck 10.0 [get_ports {tdo tdo_oe}]
write_checkpoint -force [file join $out synth.dcp]
report_utilization -hierarchical -file [file join $out synth_utilization.rpt]
report_timing_summary -max_paths 20 -file [file join $out synth_timing.rpt]
opt_design
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_utilization -hierarchical -file [file join $out routed_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 100 -report_unconstrained \
    -file [file join $out routed_timing.rpt]
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_cdc -details -file [file join $out cdc.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
write_checkpoint -force [file join $out routed.dcp]
set after [exec sha256sum {*}$tracked]
set h [open [file join $out inputs.after.sha256] w]; puts $h $after; close $h
if {$before ne $after} {
    puts "ERROR: karudbg implementation inputs changed during the run"
    exit 1
}
set worst [get_timing_paths -delay_type max -max_paths 1]
set slack [get_property SLACK $worst]
puts "KARUDBG_VIVADO_OOC_COMPLETE: routed WNS=$slack ns core_period=$period ns tck_period=$tck_period ns"
if {$slack < 0} { exit 2 }
exit 0
