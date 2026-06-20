#!/usr/bin/env bash
#	flow/syn/syn_sweep.sh -- synthesise karu64 across several ISA-extension
#	configurations and tabulate rough gate count (kGE) + combinational
#	logic depth (yosys `ltp -noff`) for each.
#
#	Each config is the extension-gating set from rtl/karu_ext.vh
#	(KARU_NO_F/D/V/K, cascade K>V>D>F) optionally combined with the
#	mul/div cycle knobs. Because `hierarchy -top karu64` prunes the
#	uninstantiated modules *before* synth, a gated config never feeds the
#	dropped units (e.g. karu_varith) to yosys at all -- so the smaller
#	configs synth fast and fully even though the full IMAFDCV core stalls
#	yosys (karu_varith proc/vcompress; see README.md).
#
#	Usage:
#	    ./syn_sweep.sh                 # default config list (below)
#	    BASE_DEFINES="" ./syn_sweep.sh # all-combinational (deepest path)
#	    PER_TIMEOUT=1800 ./syn_sweep.sh
#	    CONFIGS="imac imafc" ./syn_sweep.sh   # subset
#
#	Output: _build/syn_out/sweep_<stamp>/{<cfg>/, summary.csv} + a printed table.

set -u
cd "$(dirname "$0")"

[ -f syn_setup.sh ] || { echo "syn_setup.sh missing -- copy syn_setup.example.sh and edit." >&2; exit 1; }

#	NAND2_X1 cell area (um^2) for the kGE conversion. NanGate45 typical.
NAND2_UM2="${NAND2_UM2:-0.798}"
#	Per-config wall-clock budget (seconds). The full IMAFDCV config is
#	expected to exceed this and be marked "timeout".
PER_TIMEOUT="${PER_TIMEOUT:-2400}"
#	Shared defines applied to every config (extension flags appended).
#	Default = README "small core". Set BASE_DEFINES="" for the
#	all-combinational variant (deepest critical path, largest area).
BASE_DEFINES="${BASE_DEFINES:-KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64}"

#	config label -> extra (extension) defines. Cascade means NO_F alone
#	gives IMAC, NO_D gives IMAFC, NO_V gives IMAFDC, none gives full.
declare -A CFG_DEFS=(
	[imac]="KARU_NO_F"
	[imafc]="KARU_NO_D"
	[imafdc]="KARU_NO_V"
	[imafdcv]=""
)
declare -A CFG_DESC=(
	[imac]="RV64IMAC (base; no F/D/V)"
	[imafc]="RV64IMAFC (single-prec FP)"
	[imafdc]="RV64IMAFDC (double-prec FP)"
	[imafdcv]="RV64IMAFDCV (full; may stall yosys)"
)
CONFIGS="${CONFIGS:-imac imafc imafdc imafdcv}"

stamp="$(date +%Y%m%d_%H%M%S)"
sweep_dir="../../_build/syn_out/sweep_${stamp}"
mkdir -p "$sweep_dir"
summary="$sweep_dir/summary.csv"
echo "config,description,defines,status,area_um2,kGE,seq_pct,depth_levels,depth_module" > "$summary"

echo "sweep -> $sweep_dir   base_defines=[$BASE_DEFINES]  per_timeout=${PER_TIMEOUT}s"
echo

for cfg in $CONFIGS; do
	ext="${CFG_DEFS[$cfg]:-}"
	desc="${CFG_DESC[$cfg]:-$cfg}"
	defs="$(echo "$BASE_DEFINES $ext" | sed 's/^ *//;s/ *$//')"
	out="$sweep_dir/$cfg"
	echo "===================================================================="
	echo "[$cfg] $desc"
	echo "       defines: ${defs:-<none>}"
	echo "===================================================================="

	#	Run the existing single-config flow: yosys area + ltp depth, no STA.
	KARU_OUT_DIR="$out" KARU_DEFINES="$defs" KARU_LTP=1 KARU_NO_STA=1 \
		timeout --signal=KILL "$PER_TIMEOUT" ./syn_yosys.sh \
		> "$sweep_dir/${cfg}.console.log" 2>&1
	rc=$?

	area_rpt="$out/reports/area.rpt"
	depth_rpt="$out/reports/depth.rpt"

	#	Total chip area (incl. submodules) -- last field of the top-module
	#	line. Written before the (optional) ltp block, so it survives an ltp
	#	failure; parse regardless of exit code.
	area="$(awk '/Chip area for top module/{print $NF}' "$area_rpt" 2>/dev/null)"
	#	Top-module sequential-element share = the LAST "sequential elements"
	#	line (per-module lines precede it).
	seqpct="$(grep -a 'sequential elements' "$area_rpt" 2>/dev/null | tail -1 | grep -oE '[0-9.]+%' | tr -d '%')"
	#	Deepest reliably-measured leaf module. ltp's topological sort is
	#	defeated by bit-level reconvergence in the stateful control modules
	#	(karu_m / karu_csr / karu_lsu / karu_mem / karu_regfile / ifu / top),
	#	which then emit "Detected loop ... in <mod>" and report a bogus
	#	thousand-stage length. We therefore take the max length over modules
	#	that did NOT loop (and skip the karu64 container). The deepest clean
	#	leaf is the combinational gate depth a given extension contributes
	#	(karu_fdiv/karu_fsqrt for F, karu_*_d for D, karu_varith for V).
	read -r depth depmod < <(awk '
		/Detected loop/        { loop[$NF]=1; next }   # last field = module name
		/Longest topological path in/ {
			mod=$5
			if (match($0,/length=[0-9]+/)) len[mod]=substr($0,RSTART+7,RLENGTH-7)+0
		}
		END {
			for (m in len)
				if (m!="karu64" && !(m in loop) && len[m]>maxn) { maxn=len[m]; maxmod=m }
			if (maxn>0) printf "%d %s", maxn, maxmod
		}
	' "$depth_rpt" 2>/dev/null)

	if [ -n "$area" ]; then
		kge="$(awk "BEGIN{printf \"%.1f\", $area/$NAND2_UM2/1000.0}")"
		if [ -n "${depth:-}" ]; then status="ok"; else status="ok (no-depth)"; depth="-"; depmod="-"; fi
	else
		status="$([ $rc -eq 137 ] && echo timeout || echo FAILED)"
		area="-"; kge="-"; seqpct="-"; depth="-"; depmod="-"
	fi

	printf '%s,"%s","%s",%s,%s,%s,%s,%s,%s\n' \
		"$cfg" "$desc" "${defs:-<none>}" "$status" "$area" "$kge" "${seqpct:-/}" "$depth" "${depmod:-/}" >> "$summary"
	echo "  -> status=$status  kGE=${kge}  seq%=${seqpct:-/}  depth=${depth} (${depmod:-/})"
	echo
done

echo "===================================================================="
echo "SWEEP SUMMARY  ($sweep_dir/summary.csv)"
echo "===================================================================="
#	Pretty-print the CSV as an aligned table.
awk -F',' '
	function strip(s){ gsub(/^"|"$/,"",s); return s }
	NR==1 { printf "%-9s %-34s %-12s %-9s %-6s %-7s %-16s\n","config","description","status","kGE","seq%","depth","deepest-module"; next }
	{ printf "%-9s %-34s %-12s %-9s %-6s %-7s %-16s\n", $1, strip($2), $4, $6, $7, $8, $9 }
' "$summary"
echo
echo "(depth = deepest leaf-module gate-level logic path, 'ltp -noff'; per-config"
echo " full area + per-module breakdown in <cfg>/reports/area.rpt, depth.rpt)"
