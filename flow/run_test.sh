#!/usr/bin/env bash
#	flow/run_test.sh -- run a single riscv-test through karu64 and report.
#
#	Usage:	flow/run_test.sh <test-name>
#	  e.g.	flow/run_test.sh rv64ui-p-add
#
#	Exit code:
#		0  PASS (test wrote 1 to tohost)
#		1  FAIL (test wrote (n<<1)|1 to tohost, n != 0)
#		2  TRAP/TIMEOUT/build error

set -u
cd "$(dirname "$0")/.."

TEST=${1:?usage: $0 <test-name>}
ELF=test/riscv-tests/isa/$TEST
HEX=_build/$TEST.hex
KARU_LOG=_build/$TEST.karu.log
BIN_TMP=$(mktemp /tmp/karu64_${TEST}.XXXXXX.bin)
trap 'rm -f "$BIN_TMP"' EXIT

#	pick simulator: SIM=veri | ivl  (default: veri if built, else ivl)
SIM=${SIM:-}
VERI_BIN=_build/Vhtif/Vhtif_tb
IVL_VVP=_build/htif_tb.vvp
if [[ -z $SIM ]]; then
	if   [[ -x $VERI_BIN ]]; then SIM=veri
	elif [[ -e $IVL_VVP  ]]; then SIM=ivl
	else echo "no simulator built; run: make veri or make _build/htif_tb.vvp" >&2; exit 2
	fi
fi
case $SIM in
	veri) [[ -x $VERI_BIN ]] || { echo "missing $VERI_BIN (try: make veri)";        exit 2; } ;;
	ivl)  [[ -e $IVL_VVP  ]] || { echo "missing $IVL_VVP (try: make _build/htif_tb.vvp)"; exit 2; } ;;
	*)    echo "unknown SIM=$SIM (use veri | ivl)"; exit 2 ;;
esac

if [[ ! -x $ELF ]]; then
	(cd test/riscv-tests/isa && make XLEN=64 "$TEST" > /dev/null 2>&1) \
		|| { echo "$TEST: BUILD FAIL"; exit 2; }
fi

riscv64-unknown-elf-objcopy -O binary "$ELF" "$BIN_TMP"
hexdump -v -e '1/8 "%016x\n"' "$BIN_TMP" > "$HEX"

#	tohost byte-offset from 0x80000000 (the binary's load base)
TOHOST_OFF=$(riscv64-unknown-elf-nm "$ELF" \
	| awk '/ tohost$/ { printf "%x\n", strtonum("0x"$1) - 0x80000000 }')
: ${TOHOST_OFF:=1000}

#	Capture both the HTIF exit message and any TRAP message.
rm -f "$KARU_LOG"
case $SIM in
	veri) out=$($VERI_BIN +hex="$HEX" +tohost="$TOHOST_OFF" +commit_log="$KARU_LOG" 2>&1) ;;
	ivl)  out=$(vvp -N $IVL_VVP +hex="$HEX" +tohost="$TOHOST_OFF" +commit_log="$KARU_LOG" 2>&1) ;;
esac

if echo "$out" | grep -q '^\[HTIF\] exit 0 @'; then
	echo "$TEST: PASS"
	exit 0
elif echo "$out" | grep -q '^\[HTIF\] exit [1-9]'; then
	code=$(echo "$out" | sed -n 's/^\[HTIF\] exit \([0-9]*\) @.*/\1/p')
	echo "$TEST: FAIL (testnum=$code)"
	exit 1
elif echo "$out" | grep -q 'TRAP\|TIMEOUT'; then
	echo "$TEST: TRAP/TIMEOUT"
	echo "$out" | tail -3 | sed 's/^/  /'
	exit 2
else
	echo "$TEST: UNKNOWN"
	echo "$out" | tail -3 | sed 's/^/  /'
	exit 2
fi
