#	karu_reports.tcl
#	=== Shared report-archiving helper for the Vivado flows.
#
#	The synth/route flows write worst-path / timing / util reports into the
#	Vivado output directory (_build by default), where the next run may clobber
#	them. This helper copies each run's freshly-written reports into
#	_build/fpga_rpt/ under a config tag so they are retained and diffable.
#
#	Archived name = <tag>__<original basename>, e.g.
#	    _build/fpga_rpt/zvk_keccak_wb2__vcu118_synth_worstpaths.rpt
#	The double underscore separates the tag from the tool's own filename, so
#	re-running the same tag updates the same files (clean git diff) and different
#	tags never collide. These are the auto-archived raw reports; the curated
#	`<name>_PASS/FAIL_*.txt` snapshots are hand-named keepers.
#
#	Tag precedence: env KARU_REPORT_TAG, else the supplied default (the design top).

proc karu_report_tag {default} {
	if {[info exists ::env(KARU_REPORT_TAG)] && $::env(KARU_REPORT_TAG) ne ""} {
		return $::env(KARU_REPORT_TAG)
	}
	return $default
}

proc karu_archive_reports {tag files} {
	if {[info exists ::karu_rpt_dir]} {
		set dir $::karu_rpt_dir
	} else {
		set dir [file normalize _build/fpga_rpt]
	}
	file mkdir $dir
	foreach f $files {
		if {[file exists $f]} {
			set dst [file join $dir "${tag}__[file tail $f]"]
			file copy -force $f $dst
			puts "ARCHIVED: $dst"
		} else {
			puts "ARCHIVE-SKIP (missing): $f"
		}
	}
}
