#!/usr/bin/env bash
#	flow/run_fp_modes.sh -- run flow/run_fp_test.sh over all 17 ops
#	for every static rounding mode (rne/rtz/rdn/rup/rmm). Prints a
#	grid summary at the end.

set -u
cd "$(dirname "$0")/.."

OPS=(
	f32_add f32_sub f32_mul f32_div f32_sqrt f32_mulAdd
	f32_eq f32_le f32_lt
	f32_to_i32 f32_to_ui32 f32_to_i64 f32_to_ui64
	i32_to_f32 ui32_to_f32 i64_to_f32 ui64_to_f32
	f64_add f64_sub f64_mul f64_div f64_sqrt f64_mulAdd
	f64_eq f64_le f64_lt
	f64_to_i32 f64_to_ui32 f64_to_i64 f64_to_ui64
	i32_to_f64 ui32_to_f64 i64_to_f64 ui64_to_f64
	f32_to_f64 f64_to_f32
)
MODES=(rne rtz rdn rup rmm)

#	Run -> tally error count (or "PASS" if zero).
run_one() {
	local op=$1 rm=$2
	local out=$(RM=$rm flow/run_fp_test.sh "$op" 2>/dev/null | tr -d '\r')
	local errors=$(echo "$out" | sed -nE 's/^\[fp-test\] [^ ]+: [0-9]+ vectors, ([0-9]+) error.*/\1/p' | head -1)
	: ${errors:=?}
	if [[ $errors == 0 ]]; then echo "PASS"; else echo "$errors"; fi
}

#	Wide header
printf "\n%-14s" "op"
for rm in "${MODES[@]}"; do printf " %8s" "$rm"; done
echo
printf -- "----------------------------------------------------------------\n"

for op in "${OPS[@]}"; do
	printf "%-14s" "$op"
	for rm in "${MODES[@]}"; do
		v=$(run_one "$op" "$rm")
		printf " %8s" "$v"
	done
	echo
done
printf -- "----------------------------------------------------------------\n"
echo "  testfloat_ver caps at -errors 20 by default; '20' usually means"
echo "  'capped early'. Comparison/sign ops produce identical results"
echo "  across rounding modes (rm field is ignored for them)."
