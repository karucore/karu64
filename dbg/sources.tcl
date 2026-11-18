# Tool-neutral combined ASIC manifest. Site scripts supply libraries/macros.
# Processor-only users continue to source flow/asic/sources.tcl instead.
set karudbg_dir [file dirname [file normalize [info script]]]
source [file join $karudbg_dir .. flow asic sources.tcl]
set karu_top karudbg_top
lappend karu_include_dirs $karudbg_dir
lappend karu_defines KARU_DBG
set karu_sources [list]
set handle [open [file join $karudbg_dir karudbg.f] r]
while {[gets $handle line] >= 0} {
    regsub {//.*$} $line "" line
    regsub {#.*$} $line "" line
    set line [string trim $line]
    if {$line ne ""} { lappend karu_sources [file join $karu_repo $line] }
}
close $handle
