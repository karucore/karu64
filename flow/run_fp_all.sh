#!/usr/bin/env bash
#	flow/run_fp_all.sh -- run flow/run_fp_test.sh on every supported
#	TestFloat operation and print a summary table.

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

printf "\n%-14s %10s %10s %10s\n" "op" "vectors" "tested" "errors"
printf -- "----------------------------------------------\n"

n_clean=0; n_err=0
for op in "${OPS[@]}"; do
	#	2>/dev/null drops the per-chunk progress \r lines; testfloat_ver
	#	also injects \r progress markers on the same line as its summary,
	#	so we use our own script's `[fp-test] OP: N vectors, M error lines`
	#	summary line which is reliable.
	out=$(flow/run_fp_test.sh "$op" 2>/dev/null | tr -d '\r')
	gen=$(echo    "$out" | sed -nE 's/^\[fp-test\] op=.* gen=([0-9]+).*/\1/p' | head -1)
	tested=$(echo "$out" | sed -nE 's/^[[:space:]]+([0-9]+) tests performed.*/\1/p' | tail -1)
	errors=$(echo "$out" | sed -nE 's/^\[fp-test\] [^ ]+: [0-9]+ vectors, ([0-9]+) error.*/\1/p' | head -1)
	: ${errors:=?}
	: ${tested:=?}
	: ${gen:=?}
	if [[ "$errors" == "0" ]]; then
		n_clean=$((n_clean+1))
		printf "%-14s %10s %10s %10s\n" "$op" "$gen" "$tested" "PASS"
	else
		n_err=$((n_err+1))
		printf "%-14s %10s %10s %10s\n" "$op" "$gen" "$tested" "$errors"
	fi
done
printf -- "----------------------------------------------\n"
echo "  clean: $n_clean    with diffs: $n_err"
echo "  (testfloat_ver caps at -errors 20 by default; many of the"
echo "  diff counts are early-exit at the cap, not totals.)"
