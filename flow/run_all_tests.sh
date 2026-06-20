#!/usr/bin/env bash
#	flow/run_all_tests.sh -- run every rv64ui-p / rv64uc-p test through
#	karu64 and summarise pass/fail.

set -u
cd "$(dirname "$0")/.."

#	Make sure at least one sim is built. Default to verilator if neither.
SIM=${SIM:-}
if [[ -z $SIM ]]; then
	if   [[ -x _build/Vhtif/Vhtif_tb ]]; then SIM=veri
	elif [[ -e _build/htif_tb.vvp    ]]; then SIM=ivl
	else SIM=veri; fi
fi
case $SIM in
	veri) make _build/Vhtif/Vhtif_tb > /dev/null ;;
	ivl)  make _build/htif_tb.vvp    > /dev/null ;;
esac
export SIM
echo "using SIM=$SIM"

#	Pull the test list from the upstream Makefrags so we stay in sync.
get_tests() {
	local frag=$1 prefix=$2
	awk -v p="$prefix" '
		/^[a-z0-9]+_sc_tests = / { collecting = 1; next }
		collecting {
			cont = ($0 ~ /\\[ \t]*$/)
			gsub(/\\[ \t]*$/, "")
			for (i = 1; i <= NF; i++)
				if ($i != "") print p"-"$i
			if (!cont) collecting = 0
		}
	' "$frag"
}

tests=$(
	get_tests test/riscv-tests/isa/rv64ui/Makefrag rv64ui-p
	get_tests test/riscv-tests/isa/rv64uc/Makefrag rv64uc-p
	get_tests test/riscv-tests/isa/rv64um/Makefrag rv64um-p
	get_tests test/riscv-tests/isa/rv64uf/Makefrag rv64uf-p
	get_tests test/riscv-tests/isa/rv64ud/Makefrag rv64ud-p
	get_tests test/riscv-tests/isa/rv64ua/Makefrag rv64ua-p
)

#	Build them all up front (much faster than one-by-one).
echo "building $(echo "$tests" | wc -w) tests..."
(cd test/riscv-tests/isa && make XLEN=64 $tests > /dev/null 2>&1)

pass=0; fail=0; bad=0
fail_list=""; bad_list=""

for t in $tests; do
	if result=$(flow/run_test.sh "$t" 2>&1); then
		pass=$((pass+1))
		printf "  %-24s PASS\n" "$t"
	else
		rc=$?
		printf "  %-24s %s\n" "$t" "$(echo "$result" | head -1 | cut -d: -f2- | sed 's/^ //')"
		if (( rc == 1 )); then
			fail=$((fail+1)); fail_list+=" $t"
		else
			bad=$((bad+1)); bad_list+=" $t"
		fi
	fi
done

echo
echo "=========================================="
echo "  PASS: $pass    FAIL: $fail    TRAP/OTHER: $bad"
[[ -n $fail_list ]] && echo "  failing: $fail_list"
[[ -n $bad_list  ]] && echo "  trap/other: $bad_list"
echo "=========================================="

#	Exit non-zero if anything wasn't a PASS, so CI can pick it up.
(( fail + bad == 0 ))
