#	flow/syn/tcl/yosys_run_synth.tcl
#	Reads the karu64 RTL, runs the standard yosys synth + tech-map +
#	abc passes against the nangate45 liberty, and emits a pre-map
#	netlist, a final mapped netlist, an STA-friendly netlist, and an
#	area report.
#
#	The default flow is HIERARCHICAL: each leaf module is mapped by
#	abc independently. Flat mapping (`KARU_FLATTEN=1`) gives a marginally
#	better critical path because abc can optimise across module
#	boundaries, but on this design the flat AIG is ~186k nodes and
#	abc's nangate script takes longer than is useful for an
#	experimental eval flow. Hierarchical results are accurate to within
#	a few percent and complete in single-digit minutes.

set top      "karu64"
set out_dir  $::env(KARU_OUT_DIR)
set lib      $::env(KARU_LIB)
set clk_ps   $::env(KARU_CLK_PS)
set uprate   $::env(KARU_ABC_UPRATE_PS)
set abc_sdc  "$out_dir/generated/karu64.abc.sdc"
set flatten  [expr {[info exists ::env(KARU_FLATTEN)] && $::env(KARU_FLATTEN) ne "0" && $::env(KARU_FLATTEN) ne ""}]
set abc_fast [expr {![info exists ::env(KARU_ABC_FULL)] || $::env(KARU_ABC_FULL) eq "0" || $::env(KARU_ABC_FULL) eq ""}]
set noshare  [expr {[info exists ::env(KARU_NOSHARE)] && $::env(KARU_NOSHARE) ne "0" && $::env(KARU_NOSHARE) ne ""}]

set pre_map_v   "$out_dir/generated/${top}.pre_map.v"
set netlist_v   "$out_dir/generated/${top}_netlist.v"
set sta_v       "$out_dir/generated/${top}_netlist.sta.v"
set area_rpt    "$out_dir/reports/area.rpt"
set depth_rpt   "$out_dir/reports/depth.rpt"

set abc_clk_ps [expr {$clk_ps - $uprate}]
if {$abc_clk_ps <= 0} {
	puts "WARNING: KARU_ABC_UPRATE_PS ($uprate) >= KARU_CLK_PS ($clk_ps)."
}

yosys "read_liberty -lib $lib"

#	Optional `-D` flags from $KARU_DEFINES (space-separated list of
#	NAME or NAME=VAL tokens). Used to flip compile-time options like
#	KARU_MUL_CYCLES, KARU_M_DIV_CYCLES etc. when synthesising.
set defs ""
if {[info exists ::env(KARU_DEFINES)] && $::env(KARU_DEFINES) ne ""} {
	foreach tok $::env(KARU_DEFINES) {
		append defs " -D$tok"
	}
	puts "extra defines: $defs"
}

#	karu RTL is plain Verilog with `include guards under rtl/. Discover the
#	synthesizable core sources instead of maintaining a fragile hand list: this
#	picks up MMU/cache/vector/optional crypto dependencies while excluding
#	testbenches, assertions, and SoC peripherals that are outside the core flow.
set rtl_files [list ../../rtl/karu64.v]
foreach pattern [list ../../rtl/karu_*.v ../../rtl/zvk/*.v] {
	foreach file [lsort [glob -nocomplain $pattern]] {
		set base [file tail $file]
		if {$base in {
			htif_tb.v
			karu_assert.v
			karu_vrf_assert.v
			karu_plic_assert.v
			karu_clint.v
			karu_plic.v
		}} {
			continue
		}
		lappend rtl_files $file
	}
}
set rtl_unique [list]
array unset rtl_seen
foreach file $rtl_files {
	if {![info exists rtl_seen($file)]} {
		set rtl_seen($file) 1
		lappend rtl_unique $file
	}
}
puts "RTL sources: [llength $rtl_unique]"
yosys "read_verilog -defer -I../../rtl$defs $rtl_unique"

yosys "hierarchy -check -top $top"

#	-noabc: skip synth's internal abc invocation; we run our own
#	below so we control the script (otherwise the bit-serial fdiv /
#	fmul modules dominate runtime).
set synth_opts "-noabc"
if {$noshare} {
	puts "KARU_NOSHARE=1 -- synth skips SAT-based resource sharing"
	append synth_opts " -noshare"
}
if {$flatten} {
	puts "KARU_FLATTEN=1 -- flat synth (slow but slightly better timing)"
	yosys "synth $synth_opts -flatten -top $top"
} else {
	puts "hierarchical synth (default; set KARU_FLATTEN=1 for flat)"
	yosys "synth $synth_opts -top $top"
}
yosys "opt -purge"

yosys "write_verilog $pre_map_v"

#	Map flops to the library, then run abc with the abc-only SDC and
#	the (uprated) target period. With a hierarchical netlist abc runs
#	per leaf module; with a flat one it's a single (large) invocation.
yosys "dfflibmap -liberty $lib"
yosys "opt"
#	Custom -script: same as yosys' -fast variant but without the
#	`buffer; upsize; dnsize; stime -p` tail, which trips abc with
#	"node X has no fanout" on this design's dffe-heavy LSU/FPU
#	netlists. The map step alone gives a meaningful area + timing
#	picture; size adjustment can be added later if needed.
if {$abc_fast} {
	puts "abc with abc_fast.script (default; set KARU_ABC_FULL=1 for full quality script)"
	yosys "abc -liberty $lib -constr $abc_sdc -D $abc_clk_ps -script tcl/abc_fast.script"
} else {
	puts "abc full script (slow; better optimisation)"
	yosys "abc -liberty $lib -constr $abc_sdc -D $abc_clk_ps"
}

#	Flatten only if we entered flat -- for hierarchical runs we leave
#	the netlist as-is so OpenSTA can see module boundaries.
if {$flatten} {
	yosys "flatten"
}
yosys "clean"

yosys "write_verilog $netlist_v"

#	Produce an STA-friendly netlist: undef -> 0, split nets, strip
#	`$print` simulation cells (created from $display statements in
#	the RTL -- OpenSTA's verilog reader chokes on them), and strip
#	yosys-only attributes / hex / decimal formatting.
yosys "setundef -zero"
yosys "splitnets"
yosys "delete t:\$print"
yosys "clean"
yosys "write_verilog -noattr -noexpr -nohex -nodec $sta_v"

yosys "check"
yosys "tee -o $area_rpt stat -liberty $lib"

#	Per-module combinational logic depth (opt-in: set KARU_LTP=1).
#	`ltp -noff` reports, for every module, the longest purely combinational
#	(reg->reg / in->out, flops excluded) path in mapped standard-cell stages
#	-- a library-independent companion to OpenSTA's delay-weighted WNS. Run on
#	the MAPPED but **un-flattened** netlist on purpose: flattening karu64 is
#	both memory-heavy *and* introduces false combinational loops (bit-level
#	reconvergence in the regfile/LSU muxes and the FMA datapath) that defeat
#	ltp's topological sort and produce a meaningless multi-thousand-stage
#	"path". Un-flattened, ltp emits one clean line per module:
#	    Longest topological path in <module> (length=N):
#	The deepest *leaf* module's N is the per-pipeline-stage gate depth a given
#	extension adds (karu_fdiv/karu_fsqrt for F, karu_*_d for D, karu_varith
#	for V). Container modules (karu64, karu_fpu) report their instance-graph
#	path, not gate depth -- ignore them; the deepest leaf dominates the max.
#	A few wide modules (karu_ffma) emit loop warnings but still report a
#	usable length. Cheap and memory-light, so it can stay on for the sweep.
if {[info exists ::env(KARU_LTP)] && $::env(KARU_LTP) ne "0" && $::env(KARU_LTP) ne ""} {
	yosys "tee -o $depth_rpt ltp -noff"
}
