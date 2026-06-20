# vivado_paths.tcl -- shared path setup for Vivado batch flows.
#
# Vivado writes journals, logs, .Xil, generated project state, and other side
# files into its launch directory. The Makefile starts Vivado from _build; these
# helpers let scripts still find repo sources by absolute path and put named
# outputs under _build when run directly.

set ::karu_fpga_dir [file dirname [file normalize [info script]]]
set ::karu_repo_dir [file normalize [file join $::karu_fpga_dir ../..]]
if {[info exists ::env(KARU_REPO_ROOT)] && $::env(KARU_REPO_ROOT) ne ""} {
	set ::karu_repo_dir [file normalize $::env(KARU_REPO_ROOT)]
}

set ::karu_build_dir [file join $::karu_repo_dir _build]
if {[info exists ::env(KARU_BUILD_DIR)] && $::env(KARU_BUILD_DIR) ne ""} {
	set ::karu_build_dir [file normalize $::env(KARU_BUILD_DIR)]
}
file mkdir $::karu_build_dir

proc karu_repo_path {args} {
	return [file normalize [file join $::karu_repo_dir {*}$args]]
}

proc karu_build_path {args} {
	return [file normalize [file join $::karu_build_dir {*}$args]]
}

#	Synth/route/STA report directory: _build/fpga_rpt. All Vivado .rpt outputs go
#	here (checkpoints/bitstreams stay in _build via karu_build_path).
set ::karu_rpt_dir [file join $::karu_build_dir fpga_rpt]
file mkdir $::karu_rpt_dir

proc karu_rpt_path {args} {
	return [file normalize [file join $::karu_rpt_dir {*}$args]]
}

proc karu_env_path {name def} {
	if {[info exists ::env($name)] && $::env($name) ne ""} {
		set p $::env($name)
	} else {
		set p $def
	}
	if {[file pathtype $p] eq "relative"} {
		return [file normalize [file join $::karu_repo_dir $p]]
	}
	return [file normalize $p]
}

proc karu_env_build_path {name def} {
	if {[info exists ::env($name)] && $::env($name) ne ""} {
		set p $::env($name)
	} else {
		set p $def
	}
	if {[file pathtype $p] eq "relative"} {
		return [karu_build_path $p]
	}
	return [file normalize $p]
}

puts "KARU_REPO_ROOT: $::karu_repo_dir"
puts "KARU_BUILD_DIR: $::karu_build_dir"
