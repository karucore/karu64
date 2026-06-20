#!/usr/bin/env bash
#	flow/diff_test.sh -- diff karu64's commit log against spike for
#	one riscv-test. Useful for pinpointing the first divergence.
#
#	Usage:	flow/diff_test.sh <test-name> [context-lines]
#	  e.g.	flow/diff_test.sh rv64ui-p-sll
#
#	Outputs spike.log / karu.log under _build/ and prints the first
#	differing region. Filters out the spin loops that wait on tohost.

set -u
cd "$(dirname "$0")/.."

TEST=${1:?usage: $0 <test-name> [ctx-lines]}
CTX=${2:-5}
ELF=test/riscv-tests/isa/$TEST
HEX=_build/$TEST.hex
SPK=_build/$TEST.spike.log
KARU=_build/$TEST.karu.log

[[ -e _build/htif_tb.vvp ]] || make _build/htif_tb.vvp > /dev/null
[[ -x $ELF ]] || (cd test/riscv-tests/isa && make XLEN=64 "$TEST" > /dev/null)

riscv64-unknown-elf-objcopy -O binary "$ELF" /tmp/karu64_$$.bin
hexdump -v -e '1/8 "%016x\n"' /tmp/karu64_$$.bin > "$HEX"
rm -f /tmp/karu64_$$.bin

TOHOST_OFF=$(riscv64-unknown-elf-nm "$ELF" \
	| awk '/ tohost$/ { printf "%x\n", strtonum("0x"$1) - 0x80000000 }')
: ${TOHOST_OFF:=1000}

#	spike commit log: include all privilege levels (the test framework
#	mret's into U-mode for the body), strip the CSR-name annotations
#	(we don't reproduce them), and keep only user-space addresses.
spike --log-commits -l --log=/tmp/spike_$$.raw "$ELF" > /dev/null 2>&1 || true
grep -E '^core   0: [0-9] 0x000000008' /tmp/spike_$$.raw \
	| sed -E 's/^core   0: [0-9] /core   0: 3 /; s/ c[0-9]+_[a-z]+ 0x[0-9a-f]+//' \
	> "$SPK"
rm -f /tmp/spike_$$.raw

#	karu commit log
rm -f "$KARU"
vvp -N _build/htif_tb.vvp +hex="$HEX" +tohost="$TOHOST_OFF" +commit_log="$KARU" > /dev/null 2>&1

#	First diverging line
n_karu=$(wc -l < "$KARU")
n_spk=$(wc -l < "$SPK")
echo "spike: $n_spk lines, karu: $n_karu lines"

diff_line=$(diff "$SPK" "$KARU" | grep -m1 -nE '^[0-9]+(,[0-9]+)?[acd]' | cut -d: -f1)
if [[ -z $diff_line ]]; then
	echo "no divergence (commit-log identical)"
	exit 0
fi

#	Print context around the first diverging spike line.
spk_line=$(diff "$SPK" "$KARU" | sed -n "${diff_line}p" | sed -E 's/^([0-9]+).*/\1/')
echo "first divergence near spike line $spk_line:"
echo
diff -U "$CTX" "$SPK" "$KARU" | head -$(( CTX * 4 + 6 ))
