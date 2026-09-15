# Source this from the site-specific Cadence script. This file only supplies
# the design manifest; technology libraries, macro models and constraints are
# the responsibility of the trial flow. No FPGA sources are in this list.
set karu_repo [file normalize [file join [file dirname [info script]] ../..]]
set karu_top karu64
set karu_include_dirs [list [file join $karu_repo rtl]]
proc karu_manifest_lines {path} {
    set handle [open $path r]
    set lines [split [read $handle] "\n"]
    close $handle
    set result [list]
    foreach line $lines {
        set line [string trim $line]
        if {$line ne "" && ![string match "#*" $line]} { lappend result $line }
    }
    return $result
}
set karu_defines [karu_manifest_lines [file join $karu_repo flow asic rva23s64.defines]]
set karu_sources [list]
foreach path [karu_manifest_lines [file join $karu_repo flow asic karu64.f]] {
    lappend karu_sources [file join $karu_repo $path]
}
