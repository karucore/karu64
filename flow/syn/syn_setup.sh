#	flow/syn/syn_setup.sh -- shared synthesis defaults.
#	Source from the synthesis drivers. Override paths, defines and timing
#	through environment variables; no per-machine copy is required.

#	NanGate45 typical-corner liberty file. Adjust if it moves.
#	Searched relative to this directory: ../../../src/flow (sibling of the karu64
#	checkout, the usual layout) first, then ../../src/flow (inside the checkout).
if [ -z "${KARU_LIB:-}" ]; then
	for _d in ../../../src/flow ../../src/flow; do
		_p="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd "$_d" 2>/dev/null && pwd)/NangateOpenCellLibrary_typical.lib"
		if [ -f "$_p" ]; then KARU_LIB="$_p"; break; fi
	done
	unset _d _p
fi
export KARU_LIB="${KARU_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../src/flow/NangateOpenCellLibrary_typical.lib}"

#	Target clock period in picoseconds. 4000 ps = 250 MHz, same nominal
#	as the ibex flow. karu64 is bigger so it likely won't meet this at
#	first -- the flow still reports WNS and the area report so you can
#	dial it in.
export KARU_CLK_PS="${KARU_CLK_PS:-4000}"

#	ABC sees a tighter clock than the SDC target so it optimises harder.
#	Effective ABC period = KARU_CLK_PS - KARU_ABC_UPRATE_PS.
export KARU_ABC_UPRATE_PS="${KARU_ABC_UPRATE_PS:-2000}"

#	ABC script: timing runs (STA on) use Yosys' full liberty script (with
#	buffer/upsize/dnsize -- needed for meaningful slack); area-only runs
#	(KARU_NO_STA=1: area-matrix / sweep) use the fast custom script. Force
#	either way with KARU_ABC_FULL=1 / KARU_ABC_FAST=1. On Yosys 0.65 the full
#	script is not slower on the scalar core (~4.5 min vs ~6 min).
#export KARU_ABC_FULL=1
#export KARU_ABC_FAST=1

#	Flat synthesis: synth -flatten before abc. Marginally better
#	critical path; very slow on this design (full FPU). Off by default.
#export KARU_FLATTEN=1

#	Verilog `-D` flags passed through to read_verilog. Balanced arithmetic
#	does not disable features: the headers still enable FP, V and Zvbb.
#	Add KARU_NO_V for a scalar row, or set KARU_DEFINES="" to let the
#	headers resolve all non-SIM defaults without explicit overrides.
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
