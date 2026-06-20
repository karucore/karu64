#!/usr/bin/env bash
#	flow/syn/ibex_yosys.sh -- Ibex kGE baseline using the karu64 Yosys flags.

set -eu
set -o pipefail

cd "$(dirname "$0")"

if [ ! -f syn_setup.sh ]; then
	echo "syn_setup.sh missing" >&2
	exit 1
fi
# shellcheck source=/dev/null
. ./syn_setup.sh

IBEX_ROOT="${IBEX_ROOT:-../../../ibex}"
IBEX_SYN_DIR="$IBEX_ROOT/syn"
IBEX_CONFIG="${IBEX_CONFIG:-small}"

if [ ! -d "$IBEX_ROOT/rtl" ] || [ ! -d "$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl" ]; then
	echo "IBEX_ROOT does not look like an Ibex checkout: $IBEX_ROOT" >&2
	exit 1
fi
if [ ! -f "$KARU_LIB" ]; then
	echo "KARU_LIB does not exist: $KARU_LIB" >&2
	exit 1
fi
if ! command -v sv2v >/dev/null 2>&1; then
	echo "sv2v not found on PATH" >&2
	exit 1
fi

set_default() {
	local name="$1" value="$2"
	eval "[ -n \"\${$name:-}\" ] || export $name=\"$value\""
}

case "$IBEX_CONFIG" in
	small)
		set_default IBEX_RV32E 0
		set_default IBEX_RV32M 2              # ibex_pkg::RV32MFast
		set_default IBEX_RV32B 0              # ibex_pkg::RV32BNone
		set_default IBEX_RV32ZC 0             # ibex_pkg::RV32Zca
		set_default IBEX_REGFILE 0            # ibex_pkg::RegFileFF
		set_default IBEX_BRANCH_TARGET_ALU 0
		set_default IBEX_WRITEBACK_STAGE 0
		set_default IBEX_PMP_ENABLE 0
		set_default IBEX_PMP_NUM_REGIONS 4
		set_default IBEX_MHPM_COUNTER_NUM 0
		set_default IBEX_MHPM_COUNTER_WIDTH 40
		;;
	small-latch)
		set_default IBEX_RV32E 0
		set_default IBEX_RV32M 2
		set_default IBEX_RV32B 0
		set_default IBEX_RV32ZC 0
		set_default IBEX_REGFILE 2            # ibex_pkg::RegFileLatch
		set_default IBEX_BRANCH_TARGET_ALU 0
		set_default IBEX_WRITEBACK_STAGE 0
		set_default IBEX_PMP_ENABLE 0
		set_default IBEX_PMP_NUM_REGIONS 4
		set_default IBEX_MHPM_COUNTER_NUM 0
		set_default IBEX_MHPM_COUNTER_WIDTH 40
		;;
	maxperf)
		set_default IBEX_RV32E 0
		set_default IBEX_RV32M 3              # ibex_pkg::RV32MSingleCycle
		set_default IBEX_RV32B 0
		set_default IBEX_RV32ZC 3             # ibex_pkg::RV32ZcaZcbZcmp
		set_default IBEX_REGFILE 0
		set_default IBEX_BRANCH_TARGET_ALU 1
		set_default IBEX_WRITEBACK_STAGE 1
		set_default IBEX_PMP_ENABLE 0
		set_default IBEX_PMP_NUM_REGIONS 4
		set_default IBEX_MHPM_COUNTER_NUM 0
		set_default IBEX_MHPM_COUNTER_WIDTH 40
		;;
	maxperf-pmp-bmfull)
		set_default IBEX_RV32E 0
		set_default IBEX_RV32M 3
		set_default IBEX_RV32B 3              # ibex_pkg::RV32BFull
		set_default IBEX_RV32ZC 3
		set_default IBEX_REGFILE 0
		set_default IBEX_BRANCH_TARGET_ALU 1
		set_default IBEX_WRITEBACK_STAGE 1
		set_default IBEX_PMP_ENABLE 1
		set_default IBEX_PMP_NUM_REGIONS 16
		set_default IBEX_MHPM_COUNTER_NUM 0
		set_default IBEX_MHPM_COUNTER_WIDTH 40
		;;
	custom)
		;;
	*)
		echo "Unknown IBEX_CONFIG=$IBEX_CONFIG" >&2
		echo "Known: small small-latch maxperf maxperf-pmp-bmfull custom" >&2
		exit 1
		;;
esac

set_default IBEX_ICACHE 0
set_default IBEX_ICACHE_ECC 0
set_default IBEX_ICACHE_SCRAMBLE 0
set_default IBEX_BRANCH_PREDICTOR 0
set_default IBEX_DBG_TRIGGER_EN 0
set_default IBEX_SECURE_IBEX 0
set_default IBEX_PMP_GRANULARITY 0

if [ -z "${IBEX_OUT_DIR:-}" ]; then
	IBEX_OUT_DIR="../../_build/syn_out/ibex_${IBEX_CONFIG}_$(date +%Y%m%d_%H%M%S)"
	export IBEX_OUT_DIR
fi
export IBEX_ROOT IBEX_SYN_DIR IBEX_CONFIG

mkdir -p "$IBEX_OUT_DIR/generated/rtl" "$IBEX_OUT_DIR/log" "$IBEX_OUT_DIR/reports"
cp sdc/karu64.abc.sdc "$IBEX_OUT_DIR/generated/ibex_top.abc.sdc"

convert_prim() {
	local file="$1"
	local module
	module="$(basename -s .sv "$file")"
	sv2v \
		--define=SYNTHESIS --define=YOSYS \
		"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_count_pkg.sv" \
		"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv" \
		-I"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl" \
		"$file" > "$IBEX_OUT_DIR/generated/rtl/${module}.v"
}

convert_core() {
	local file="$1"
	local module
	module="$(basename -s .sv "$file")"
	case "$module" in
		*_pkg) return ;;
	esac
	sv2v \
		--define=SYNTHESIS --define=YOSYS \
		"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_util_pkg.sv" \
		"$IBEX_ROOT"/rtl/*_pkg.sv \
		"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_ram_1p_pkg.sv" \
		"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv" \
		-I"$IBEX_ROOT/rtl" \
		-I"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl" \
		-I"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim_generic/rtl" \
		-I"$IBEX_ROOT/vendor/lowrisc_ip/dv/sv/dv_utils" \
		"$file" > "$IBEX_OUT_DIR/generated/rtl/${module}.v"
}

rewrite_prims() {
	:
}

echo "===== sv2v Ibex ($IBEX_CONFIG) ====="
for file in \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_count.sv" \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_dec.sv" \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_enc.sv" \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim/rtl/prim_lfsr.sv" \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_and2.sv" \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_buf.sv" \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_clock_mux2.sv" \
	"$IBEX_ROOT/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_flop.sv"; do
	convert_prim "$file"
	rewrite_prims "$IBEX_OUT_DIR/generated/rtl/$(basename -s .sv "$file").v"
done

for file in "$IBEX_ROOT"/rtl/*.sv; do
	module="$(basename -s .sv "$file")"
	case "$module" in
		ibex_tracer|ibex_tracer_pkg|ibex_top_tracing) continue ;;
	esac
	convert_core "$file"
	case "$module" in
		*_pkg) ;;
		*) rewrite_prims "$IBEX_OUT_DIR/generated/rtl/${module}.v" ;;
	esac
done

echo "===== yosys Ibex baseline ====="
yosys -c tcl/ibex_run_synth.tcl 2>&1 | tee "$IBEX_OUT_DIR/log/syn.log"

echo
echo "===== summary ====="
echo "outputs in $IBEX_OUT_DIR/"
grep -E "^\s+(Chip area for top module|Number of cells|Number of wires)" \
	"$IBEX_OUT_DIR/reports/area.rpt" 2>/dev/null || true
awk '/Chip area for top module/ {
	area=$NF
	printf "NAND2_X1 kGE: %.2f\n", area / 0.798 / 1000.0
}' "$IBEX_OUT_DIR/reports/area.rpt"
