#	flow/syn/syn_setup.example.sh
#	Source from syn_setup.sh (which is .gitignored). Sets the env vars
#	the rest of the flow (syn_yosys.sh / syn_sta.sh / tcl/*.tcl) reads.
#	Copy to syn_setup.sh and edit if you need to change paths or
#	timing.

#	NanGate45 typical-corner liberty file. Adjust if it moves.
export KARU_LIB="${KARU_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../src/flow && pwd)/NangateOpenCellLibrary_typical.lib}"

#	Target clock period in picoseconds. 4000 ps = 250 MHz, same nominal
#	as the ibex flow. karu64 is bigger so it likely won't meet this at
#	first -- the flow still reports WNS and the area report so you can
#	dial it in.
export KARU_CLK_PS="${KARU_CLK_PS:-4000}"

#	ABC sees a tighter clock than the SDC target so it optimises harder.
#	Effective ABC period = KARU_CLK_PS - KARU_ABC_UPRATE_PS.
export KARU_ABC_UPRATE_PS="${KARU_ABC_UPRATE_PS:-2000}"

#	By default abc runs in -fast mode (skips fraig/scorr/dch/nf
#	pre-passes), which on this design is ~5 min vs >>1 hr for the full
#	quality script. Set KARU_ABC_FULL=1 to use the full script.
#export KARU_ABC_FULL=1

#	Flat synthesis: synth -flatten before abc. Marginally better
#	critical path; very slow on this design (full FPU). Off by default.
#export KARU_FLATTEN=1

#	Verilog `-D` flags passed through to read_verilog. Default config
#	is the "small core" sweep result: 4-cycle integer multiplier,
#	bit-serial integer divider, 4-cycle F mantissa multiplier,
#	bit-serial D mantissa multiplier. This is ~32% smaller (255 kGE vs
#	374 kGE) than the all-combinational variant and is the sweet spot
#	per the README's area sweep. To let the RTL headers resolve their
#	own non-SIM defaults instead, set KARU_DEFINES="".
export KARU_DEFINES="${KARU_DEFINES-KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64}"

#	IO budget as % of clock period. set_input_delay is applied as
#	(IN_PCT/100)*period at every non-clock input; set_output_delay as
#	(1 - OUT_PCT/100)*period at every output. Defaults assume the core
#	is the only thing in the budget on each side.
export KARU_IN_PCT="${KARU_IN_PCT:-30}"
export KARU_OUT_PCT="${KARU_OUT_PCT:-70}"

#	Output directory. Defaults to a timestamped subdir of _build/syn_out/.
if [ -z "${KARU_OUT_DIR:-}" ]; then
	export KARU_OUT_DIR="../../_build/syn_out/karu64_$(date +%Y%m%d_%H%M%S)"
fi
