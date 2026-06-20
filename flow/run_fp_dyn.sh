#!/usr/bin/env bash
#	flow/run_fp_dyn.sh -- DYN rounding-mode sanity test.
#	For each frm value, run the dyn firmware on a couple of representative
#	ops and verify the result matches what the static-rm firmware produces.
#	If the DYN path through the core is broken (e.g. csr_frm not read at
#	issue, or wrong rm encoding), the diff counts will differ.

set -u
cd "$(dirname "$0")/.."

#	Only ops that actually consult rm. Comparisons/sign-injection
#	would test nothing for DYN.
DYN_OPS=(f32_add f32_mul f32_sqrt f32_to_i32 i64_to_f32
         f64_add f64_mul f64_sqrt f64_to_i32 i64_to_f64 f64_to_f32)
MODES=(rne rtz rdn rup rmm)

count_errors() {
	local op=$1 rm=$2 frm=$3
	local out=$(RM=$rm FRM=$frm flow/run_fp_test.sh "$op" 2>/dev/null | tr -d '\r')
	local errors=$(echo "$out" | sed -nE 's/^\[fp-test\] [^ ]+: [0-9]+ vectors, ([0-9]+) error.*/\1/p' | head -1)
	: ${errors:=?}
	echo "$errors"
}

printf "\n[DYN sanity]  Each cell: static-rm errors vs dyn-rm errors (with frm=mode)\n"
printf "%-14s" "op"
for rm in "${MODES[@]}"; do printf " %12s" "$rm"; done
echo
printf -- "----------------------------------------------------------------------------------\n"

mismatch=0
for op in "${DYN_OPS[@]}"; do
	printf "%-14s" "$op"
	for rm in "${MODES[@]}"; do
		e_static=$(count_errors "$op" "$rm" "$rm")
		e_dyn=$(count_errors "$op" "dyn" "$rm")
		if [[ "$e_static" == "$e_dyn" ]]; then
			printf " %5s = %5s" "$e_static" "$e_dyn"
		else
			printf " %5s ! %5s" "$e_static" "$e_dyn"
			mismatch=$((mismatch+1))
		fi
	done
	echo
done
printf -- "----------------------------------------------------------------------------------\n"
if (( mismatch == 0 )); then
	echo "  DYN matches static: each dyn-rm cell has identical error count to its static-rm peer."
else
	echo "  $mismatch dyn/static mismatches -- the DYN path may not be reading frm correctly."
fi
