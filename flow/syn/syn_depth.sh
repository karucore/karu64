#!/usr/bin/env bash
#	flow/syn/syn_depth.sh -- FAST per-module logic-depth probe, no full synthesis.
#
#	Logic depth is a *per-module* property: the F/D/V/K extension flags only
#	include/exclude whole modules, they don't reshape any module's internals
#	(only the cycle-count knobs -- KARU_MUL_CYCLES etc. -- do that). So we
#	measure each module ONCE, standalone, and a given core configuration's
#	depth is just the max over the modules it contains.
#
#	Per module: read the RTL, `hierarchy -top <module>` (keeps only that
#	module + its submodule closure, discards the rest), elaborate (proc),
#	decompose to generic gates (techmap), and `ltp -noff` for the longest
#	combinational (reg->reg / in->out) path in gate stages. This skips abc
#	tech-mapping, liberty, dfflibmap and OpenSTA -- seconds per module for
#	everything except the big combinational dividers and karu_varith.
#
#	Why standalone + techmap avoids the false-loop problem that defeats `ltp`
#	in the mapped area-synth flow (make sweep):
#	  - ltp finds flops by cell type. After `dfflibmap` flops are liberty
#	    DFF_X1 cells ltp does NOT recognise, so it reads every Q->D feedback
#	    as a combinational loop and reports a bogus thousand-stage path. Here
#	    flops stay as yosys `$_DFF_` cells, which `ltp -noff` excludes.
#	  - Running each module as its OWN top removes the cross-module
#	    instance graph, so there is no opaque-instance loop (the only thing
#	    that loops whole-core is the karu64 container, whose number is the
#	    instance path, not gate depth, anyway).
#
#	IMPORTANT: techmap is UNOPTIMISED (no abc minimisation), so these depths
#	are an *upper bound* / relative indicator, not the final mapped
#	critical-path depth (e.g. karu_alu techmap=27 vs abc-mapped=22). For the
#	optimised depth + area use `make sweep`; this is the fast, all-modules,
#	all-configs (incl. the vector core the area synth can't finish) companion.
#	Set DEPTH_AIG=1 to decompose to a 2-input AIG (`aigmap`) instead.
#
#	Usage:
#	    ./syn_depth.sh                         # all modules, small-core knobs
#	    DEFINES="" ./syn_depth.sh              # all-combinational (deepest)
#	    DEFINES="KARU_MUL_CYCLES=16" ./syn_depth.sh
#	    MODULES="karu_fdiv karu_varith" ./syn_depth.sh   # subset
#	    PER_TIMEOUT=600 ./syn_depth.sh         # per-module budget (s)
#	    DEPTH_AIG=1 ./syn_depth.sh
#
#	Output: _build/syn_out/depth_<stamp>/{<mod>.rpt, summary.csv} + a printed table
#	annotated with which configuration first needs each module.

set -u
cd "$(dirname "$0")"

RTL="$(find ../../rtl -maxdepth 2 -type f -name '*.v' \
	| sort \
	| grep -Ev '/(htif_tb|.*assert|karu_plic|karu_clint)\.v$' \
	| tr '\n' ' ')"
DECOMP="${DEPTH_AIG:+aigmap}"; DECOMP="${DECOMP:-techmap}"
#	Cycle-count knobs that actually reshape modules. Default = README "small
#	core" (matches `make sweep`). FP dividers/sqrt are always combinational.
DEFINES="${DEFINES-KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64}"
PER_TIMEOUT="${PER_TIMEOUT:-900}"
dflags=""; for t in $DEFINES; do dflags="$dflags -D$t"; done

#	Classify a module name -> the first config that needs it (for the table
#	and the per-config max). Double-precision (_d / cross-precision S<->D)
#	needs D; vector (karu_v*) needs V; the FP single units need F; the rest
#	are the IMAC base.
classify() {
	case "$1" in
		*_d|karu_fcvt_sd|karu_fcvt_ds)                   echo D ;;
		karu_v*)                                          echo V ;;
		karu_f*)                                          echo F ;;   # f2i/i2f/fadd/fmul/fdiv/fsqrt/fclass/fcmp/fminmax/fsgnj/fmv_*_w/fmv_w_x/fregfile
		*)                                                echo IMAC ;;
	esac
}
#	Auto-discover the real module names (exclude the checker and the two
#	container modules -- karu64 has no standalone file here and karu_fpu's
#	leaves are probed individually).
MODULES="${MODULES:-$(grep -hoE '^module +[A-Za-z_][A-Za-z0-9_]*' ../../rtl/karu_*.v \
	| awk '{print $2}' | grep -vxE 'karu_assert|karu_fpu' | sort)}"

stamp="$(date +%Y%m%d_%H%M%S)"
out="../../_build/syn_out/depth_${stamp}"; mkdir -p "$out"
summary="$out/summary.csv"
echo "module,needs_ext,depth_stages,status,wall_s" > "$summary"
echo "fast per-module depth probe ($DECOMP, no abc/liberty)"
echo "  defines: [${DEFINES:-<all-combinational>}]   per-module timeout: ${PER_TIMEOUT}s"
echo "  -> $out"
echo
printf '%-16s %-5s %-8s %-9s %s\n' module ext depth status wall

for M in $MODULES; do
	rpt="$out/$M.rpt"
	t0=$(date +%s)
	timeout --signal=KILL "$PER_TIMEOUT" \
		yosys -p "read_verilog -I../../rtl$dflags $RTL; hierarchy -top $M; proc; opt; $DECOMP; opt; ltp -noff" \
		> "$rpt" 2>&1
	rc=$?
	wall=$(( $(date +%s) - t0 ))
	#	Deepest path reported for THIS module's subtree (max over the module
	#	and any submodules it pulls in; excludes nothing -- a leaf reports
	#	just itself, a container's deepest submodule wins, which is what we
	#	want). Container's own instance-path line is always shorter.
	depth=$(grep -a "Longest topological path in" "$rpt" \
		| grep -av "paramod" \
		| sed -E 's/.*\(length=([0-9]+)\):/\1/' | sort -n | tail -1)
	if [ -n "$depth" ]; then st=ok
	elif [ $rc -eq 137 ]; then st=timeout; depth="-"
	else st=FAILED; depth="-"; fi
	ext="$(classify "$M")"
	printf '%-16s %-5s %-8s %-9s %ds\n' "$M" "$ext" "$depth" "$st" "$wall"
	echo "$M,$ext,$depth,$st,$wall" >> "$summary"
done

echo
echo "===================================================================="
echo "PER-CONFIG DEPTH = max over modules present ($DECOMP stages, upper bound)"
echo "===================================================================="
awk -F',' '
	function ord(e){ return e=="IMAC"?0 : e=="F"?1 : e=="D"?2 : 3 }
	NR==1||$4!="ok"{next}
	{ o=ord($2); d=$3+0
	  for(c=o;c<=3;c++){ if(d>mx[c]){mx[c]=d; mm[c]=$1} } }
	END{
	  split("IMAC F D V",nm," "); split("RV64IMAC RV64IMAFC RV64IMAFDC RV64IMAFDCV",fn," ")
	  for(c=0;c<=3;c++) printf "  %-13s depth %-6s (%s)\n", fn[c+1], mx[c], mm[c]
	}' "$summary"
echo
echo "per-module reports: $out/<module>.rpt ; summary: $summary"
