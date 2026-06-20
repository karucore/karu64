#!/usr/bin/env bash
#	flow/syn/syn_yosys.sh -- drive the karu64 yosys + opensta flow.
#
#	Outputs land under $KARU_OUT_DIR (timestamped under _build/syn_out/ by
#	default). See README.md for the layout.

set -eu
set -o pipefail

cd "$(dirname "$0")"

if [ ! -f syn_setup.sh ]; then
	echo "syn_setup.sh missing -- copy syn_setup.example.sh and edit." >&2
	exit 1
fi
# shellcheck source=/dev/null
. ./syn_setup.sh

if [ ! -f "$KARU_LIB" ]; then
	echo "KARU_LIB does not exist: $KARU_LIB" >&2
	exit 1
fi

mkdir -p "$KARU_OUT_DIR/generated" "$KARU_OUT_DIR/log" "$KARU_OUT_DIR/reports/timing"

#	Generate the SDC: substitute clock period & IO delay percentages
#	from env into the template.
clk_ns=$(awk "BEGIN{printf \"%.4f\", $KARU_CLK_PS/1000.0}")
in_ns=$(awk  "BEGIN{printf \"%.4f\", ($KARU_IN_PCT/100.0)*($KARU_CLK_PS/1000.0)}")
out_ns=$(awk "BEGIN{printf \"%.4f\", (1.0 - $KARU_OUT_PCT/100.0)*($KARU_CLK_PS/1000.0)}")

sed -e "s/@CLK_NS@/$clk_ns/g" \
    -e "s/@IN_NS@/$in_ns/g"  \
    -e "s/@OUT_NS@/$out_ns/g" \
	sdc/karu64.sdc.in > "$KARU_OUT_DIR/generated/karu64.sdc"

#	ABC SDC is the same minus the clock (yosys' abc pass takes the
#	period via -D and only wants the driving cell / load).
cp sdc/karu64.abc.sdc "$KARU_OUT_DIR/generated/karu64.abc.sdc"

export KARU_OUT_DIR KARU_LIB KARU_CLK_PS KARU_ABC_UPRATE_PS

echo "===== yosys synthesis ====="
yosys -c tcl/yosys_run_synth.tcl 2>&1 | tee "$KARU_OUT_DIR/log/syn.log"

if [ "${KARU_NO_STA:-0}" = "1" ] || [ "${KARU_NO_STA:-}" = "yes" ]; then
	echo "===== opensta skipped (KARU_NO_STA) ====="
else
	echo "===== opensta reports ====="
	sta -no_init -no_splash tcl/sta_run_reports.tcl 2>&1 | tee "$KARU_OUT_DIR/log/sta.log"
fi

echo
echo "===== summary ====="
echo "outputs in $KARU_OUT_DIR/"
grep -E "^\s+(Chip area|Number of cells|Number of wires)" \
	"$KARU_OUT_DIR/reports/area.rpt" 2>/dev/null || true
echo "WNS (reg2reg): $(awk -F, 'BEGIN{m=1e9} {if($3+0<m)m=$3+0} END{printf "%.4f ns\n", m}' \
	"$KARU_OUT_DIR/reports/timing/reg2reg.csv.rpt" 2>/dev/null || echo 'n/a')"
