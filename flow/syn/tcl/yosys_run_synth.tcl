#	flow/syn/tcl/yosys_run_synth.tcl
#	Reads the karu64 RTL, runs the standard yosys synth + tech-map +
#	abc passes against the nangate45 liberty, and emits a pre-map
#	netlist, a final mapped netlist, an STA-friendly netlist, and an
#	area report.
#
#	The default flow is HIERARCHICAL: each leaf module is mapped by ABC
#	independently. Flat mapping (`KARU_FLATTEN=1`) permits cross-module
#	optimization but needs more resources. Partitioning and memory mapping
#	affect both area and timing estimates; see README.md for measured scope.

set top      "karu64"
set out_dir  $::env(KARU_OUT_DIR)
set lib      $::env(KARU_LIB)
set clk_ps   $::env(KARU_CLK_PS)
set uprate   $::env(KARU_ABC_UPRATE_PS)
set abc_sdc  "$out_dir/generated/karu64.abc.sdc"
set flatten  [expr {[info exists ::env(KARU_FLATTEN)] && $::env(KARU_FLATTEN) ne "0" && $::env(KARU_FLATTEN) ne ""}]
#	ABC script selection. The "fast" custom script (strash; dretime; retime;
#	map) skips ABC's buffer/upsize/dnsize passes -- `map` followed by `buffer`
#	aborts with "node N has no fanout" on the DFFE-heavy LSU -- so its netlist
#	has unbuffered high-fanout nets and OpenSTA reports thousands of ns on a
#	single inverter (the L1 data-array enable, or the regfile read mux).
#	Yosys' default liberty script (&nf mapper + buffer/upsize/dnsize) does not
#	trip that abort and, on Yosys 0.65, is not slower here (scalar core:
#	~4.5 min vs ~6 min). So:
#	  - timing runs (STA enabled)         -> full script, unless KARU_ABC_FAST=1
#	  - area-only runs (KARU_NO_STA=1,     -> fast script, unless KARU_ABC_FULL=1
#	    i.e. area-matrix / sweep rows)        (keeps the published kGE comparable)
proc env_true {name} {
	return [expr {[info exists ::env($name)] && $::env($name) ne "0" && $::env($name) ne ""}]
}
if {[env_true KARU_ABC_FAST]} {
	set abc_fast 1
} elseif {[env_true KARU_ABC_FULL]} {
	set abc_fast 0
} else {
	set abc_fast [env_true KARU_NO_STA]
}
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
			karu_assert.sv
			karu_vrf_assert.sv
			karu_plic_assert.sv
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

# Fast structural regression for accidental runtime division/modulo. Resolve
# parameters and dead branches first: explicit one-cycle divider configs are
# expected to fail this audit, while the default ASIC / FPGA serial configs
# must contain none of these operators. Constant power-of-two indexing folds
# to shifts/masks before this check. No mapping or STA is needed.
if {[env_true KARU_DIV_AUDIT_ONLY]} {
	yosys "proc"
	yosys "opt_expr -full"
	yosys "opt_clean -purge"
	yosys "tee -o $out_dir/reports/div_operators.rpt select -list t:\$div t:\$mod t:\$divfloor t:\$modfloor"
	yosys "select -assert-none t:\$div t:\$mod t:\$divfloor t:\$modfloor"
	puts "RUNTIME_DIV_AUDIT_PASS: no live division/modulo operators"
	exit
}

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

#	Per-module combinational logic depth (opt-in: set KARU_LTP=1).
#	`ltp -noff` reports, for every module, the longest purely combinational
#	(reg->reg / in->out, flops excluded) path in generic gate stages -- a
#	library-independent companion to OpenSTA's delay-weighted WNS. It is run
#	HERE, on the post-`synth` generic-gate netlist and BEFORE dfflibmap, on
#	purpose: once flops are liberty DFF_X1 cells ltp no longer recognises them,
#	reads every Q->D feedback as a combinational loop, and (with Yosys 0.65)
#	emits a multi-GB report of `Detected loop` lines with meaningless lengths
#	for every module. On the generic netlist flops are $_DFF_* cells that
#	-noff excludes, so each module reports one clean line:
#	    Longest topological path in <module> (length=N):
#	N counts un-mapped 2-input gate stages (abc will shorten them), so treat it
#	as a relative/upper-bound depth, like flow/syn/syn_depth.sh. Container
#	modules (karu64, karu_fpu) report their instance-graph path, not gate depth
#	-- the deepest *leaf* dominates the max.
#	Even on the generic netlist, ltp's topological sort trips on bit-level
#	reconvergence through submodule instances in the karu64 top and in the
#	karu_mem cache wrapper (`Detected loop at \lsu_araddr ...` / `\hit_line`,
#	tens of millions of lines). Those two are containers, not the compute
#	leaves we want, so they are excluded via a `%n` (inverted) selection.
#	Override the skip list with KARU_LTP_SKIP="mod1 mod2 ...".
if {[info exists ::env(KARU_LTP)] && $::env(KARU_LTP) ne "0" && $::env(KARU_LTP) ne ""} {
	set ltp_skip "karu64 karu_mem"
	if {[info exists ::env(KARU_LTP_SKIP)]} { set ltp_skip $::env(KARU_LTP_SKIP) }
	#	Selection stack: push every skipped module, union them (N-1 x %u --
	#	a bare "a b %n" only inverts b and unions a back in), then invert.
	#	A name that does not exist in this configuration (karu_mem under
	#	KARU_NO_MEM) just warns.
	set ltp_sel $ltp_skip
	for {set i 1} {$i < [llength $ltp_skip]} {incr i} { append ltp_sel " %u" }
	append ltp_sel " %n"
	puts "KARU_LTP=1 -- ltp -noff on the pre-map netlist, skipping: $ltp_skip"
	yosys "tee -o $depth_rpt ltp -noff $ltp_sel"
}

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
	puts "abc with abc_fast.script (area-only; no buffering/sizing -- STA slack is NOT meaningful)"
	yosys "abc -liberty $lib -constr $abc_sdc -D $abc_clk_ps -script tcl/abc_fast.script"
} else {
	puts "abc default liberty script (&nf map + buffer/upsize/dnsize; STA-grade netlist)"
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
