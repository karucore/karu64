#	flow/syn/tcl/ibex_run_synth.tcl
#	Run Ibex through the same Nangate45/Yosys mapping shape used by the
#	karu64 flow: hierarchical synth -noabc, dfflibmap, and abc_fast.script.

set top           "ibex_top"
set out_dir       $::env(IBEX_OUT_DIR)
set ibex_syn_dir  $::env(IBEX_SYN_DIR)
set lib           $::env(KARU_LIB)
set clk_ps        $::env(KARU_CLK_PS)
set uprate        $::env(KARU_ABC_UPRATE_PS)
set abc_sdc       "$out_dir/generated/ibex_top.abc.sdc"
set flatten       [expr {[info exists ::env(IBEX_FLATTEN)] && $::env(IBEX_FLATTEN) ne "0" && $::env(IBEX_FLATTEN) ne ""}]
set abc_fast      [expr {![info exists ::env(IBEX_ABC_FULL)] || $::env(IBEX_ABC_FULL) eq "0" || $::env(IBEX_ABC_FULL) eq ""}]

set pre_map_v "$out_dir/generated/${top}.pre_map.v"
set netlist_v "$out_dir/generated/${top}_netlist.v"
set sta_v     "$out_dir/generated/${top}_netlist.sta.v"
set area_rpt  "$out_dir/reports/area.rpt"

set abc_clk_ps [expr {$clk_ps - $uprate}]
if {$abc_clk_ps <= 0} {
	puts "WARNING: KARU_ABC_UPRATE_PS ($uprate) >= KARU_CLK_PS ($clk_ps)."
}

yosys "read_liberty -lib $lib"
yosys "read_verilog -defer -sv $ibex_syn_dir/rtl/prim_clock_gating.v $out_dir/generated/rtl/*.v"

foreach {param envvar} {
	RV32E             IBEX_RV32E
	RV32M             IBEX_RV32M
	RV32B             IBEX_RV32B
	RV32ZC            IBEX_RV32ZC
	RegFile           IBEX_REGFILE
	BranchTargetALU   IBEX_BRANCH_TARGET_ALU
	WritebackStage    IBEX_WRITEBACK_STAGE
	ICache            IBEX_ICACHE
	ICacheECC         IBEX_ICACHE_ECC
	ICacheScramble    IBEX_ICACHE_SCRAMBLE
	BranchPredictor   IBEX_BRANCH_PREDICTOR
	DbgTriggerEn      IBEX_DBG_TRIGGER_EN
	SecureIbex        IBEX_SECURE_IBEX
	PMPEnable         IBEX_PMP_ENABLE
	PMPGranularity    IBEX_PMP_GRANULARITY
	PMPNumRegions     IBEX_PMP_NUM_REGIONS
	MHPMCounterNum    IBEX_MHPM_COUNTER_NUM
	MHPMCounterWidth  IBEX_MHPM_COUNTER_WIDTH
} {
	if {[info exists ::env($envvar)] && $::env($envvar) ne ""} {
		puts "chparam $param = $::env($envvar)"
		yosys "chparam -set $param $::env($envvar) $top"
	}
}

yosys "hierarchy -check -top $top"

if {$flatten} {
	puts "IBEX_FLATTEN=1 -- flat synth"
	yosys "synth -noabc -flatten -top $top"
} else {
	puts "hierarchical synth (same default as karu64 flow)"
	yosys "synth -noabc -top $top"
}
yosys "opt -purge"
yosys "write_verilog $pre_map_v"

# Required when the latch register file is selected. Also maps Ibex's
# negative-level clock-gate latch so stat reports include its area.
yosys "techmap -map tcl/nangate_latch_map.v"
yosys "dfflibmap -liberty $lib"
yosys "opt"

if {$abc_fast} {
	puts "abc with abc_fast.script (same default as karu64 flow)"
	yosys "abc -liberty $lib -constr $abc_sdc -D $abc_clk_ps -script tcl/abc_fast.script"
} else {
	puts "abc full script"
	yosys "abc -liberty $lib -constr $abc_sdc -D $abc_clk_ps"
}

if {$flatten} {
	yosys "flatten"
}
yosys "clean"
yosys "write_verilog $netlist_v"

yosys "setundef -zero"
yosys "splitnets"
yosys "delete t:\$print"
yosys "clean"
yosys "write_verilog -noattr -noexpr -nohex -nodec $sta_v"

yosys "check"
yosys "tee -o $area_rpt stat -liberty $lib"
