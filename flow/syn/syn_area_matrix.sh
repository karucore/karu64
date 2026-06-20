#!/usr/bin/env bash
#	flow/syn/syn_area_matrix.sh -- area-only fast-flow matrix for karu64.
#
#	Runs the existing Yosys/Nangate flow with OpenSTA disabled, then parses
#	top kGE plus a few high-value hierarchy buckets. This is intended for
#	long-running design-space checks where exact run defines matter.

set -u
set -o pipefail

cd "$(dirname "$0")"

[ -f syn_setup.sh ] || { echo "syn_setup.sh missing" >&2; exit 1; }

NAND2_UM2="${NAND2_UM2:-0.798}"
PER_TIMEOUT="${PER_TIMEOUT:-1800}"
JOBS="${JOBS:-1}"
stamp="$(date +%Y%m%d_%H%M%S)"
matrix_dir="${MATRIX_OUT_DIR:-../../_build/syn_out/area_matrix_${stamp}}"
summary="$matrix_dir/summary.csv"

case "$JOBS" in
	''|*[!0-9]*)
		echo "JOBS must be a positive integer" >&2
		exit 1
		;;
esac
if [ "$JOBS" -lt 1 ]; then
	echo "JOBS must be >= 1" >&2
	exit 1
fi

mkdir -p "$matrix_dir"
echo "config,description,defines,status,area_um2,kGE,kGE_minus_karu_mem,kGE_minus_karu_mem_sv39,karu_mem_kGE,karu_sv39_kGE,karu_csr_kGE,karu_bitmanip_kGE,karu_m_kGE,karu_fpu_kGE,karu_fregfile_kGE,karu_fmul_kGE,karu_fmul_d_kGE,karu_ffma_kGE,karu_ffma_d_kGE,karu_fdiv_kGE,karu_fdiv_d_kGE,karu_varith_kGE,karu_vcrypto_kGE,keccak_kGE,wall_s,out_dir" > "$summary"

default_matrix() {
	cat <<'EOF'
imac_m4d64|RV64IMAC+B, balanced M/div, no F/D/V/K|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F
imac_nob_m4d64|RV64IMAC, no scalar B, balanced M/div|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F KARU_NO_B
imac_min_m4d64|RV64IMAC, no B/S-mode/Sv39/HPM, balanced M/div|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F KARU_NO_B KARU_NO_S KARU_NO_HPM
imacb_min_m4d64|RV64IMAC+B, no S-mode/Sv39/HPM, balanced M/div|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F KARU_NO_S KARU_NO_HPM
imac_core_m4d64|RV64IMAC, no B/S-mode/Sv39/HPM/L1, balanced M/div|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F KARU_NO_B KARU_NO_S KARU_NO_HPM KARU_NO_MEM
imacb_core_m4d64|RV64IMAC+B, no S-mode/Sv39/HPM/L1, balanced M/div|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_F KARU_NO_S KARU_NO_HPM KARU_NO_MEM
imafc_m4d64|RV64IMAFC+B, adds single-precision F|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_D
rv64gc_m4d64|RV64GC+B, F+D, no V/K|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_NO_V
rv64gc_allcomb|RV64GC+B, global 1-cycle M/F/D multiply and M divide|KARU_MUL_CYCLES=1 KARU_DIV_CYCLES=1 KARU_NO_V
rv64gc_m16|RV64GC+B, isolate integer M 16-cycle multiply|KARU_M_MUL_CYCLES=16 KARU_M_DIV_CYCLES=64 KARU_NO_V
rv64gc_m64|RV64GC+B, isolate integer M 64-cycle multiply|KARU_M_MUL_CYCLES=64 KARU_M_DIV_CYCLES=64 KARU_NO_V
rv64gc_fp_serial|RV64GC+B, serial F/D multiply and FMA|KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_F_MUL_CYCLES=24 KARU_F_FMA_CYCLES=24 KARU_D_MUL_CYCLES=53 KARU_D_FMA_CYCLES=53 KARU_NO_V
rv64gc_m64_fp_serial|RV64GC+B, serial M plus serial F/D multiply and FMA|KARU_M_MUL_CYCLES=64 KARU_M_DIV_CYCLES=64 KARU_F_MUL_CYCLES=24 KARU_F_FMA_CYCLES=24 KARU_D_MUL_CYCLES=53 KARU_D_FMA_CYCLES=53 KARU_NO_V
rv64gcv_default|RV64GCV, RTL ASIC defaults: M/F/D mul4 div64, V mul16|
rv64gcv_vmul1|RV64GCV, isolate 1-cycle vector multiply|KARU_V_MUL_CYCLES=1
rv64gcv_vmul4|RV64GCV, isolate 4-cycle vector multiply|KARU_V_MUL_CYCLES=4
rv64gcv_vmul64|RV64GCV, isolate 64-cycle vector multiply|KARU_V_MUL_CYCLES=64
rv64gcv_zvkb|RV64GCV default plus Zvk bit-manip glue only|KARU_ZVKB
rv64gcv_zvkned|RV64GCV default plus Zvkned AES only|KARU_ZVKNED
rv64gcv_zvknha|RV64GCV default plus Zvknha SHA-256 only|KARU_ZVKNHA
rv64gcv_zvknhb|RV64GCV default plus Zvknhb SHA-256/SHA-512 only|KARU_ZVKNHB
rv64gcv_zvksed|RV64GCV default plus Zvksed SM4 only|KARU_ZVKSED
rv64gcv_zvksh|RV64GCV default plus Zvksh SM3 only|KARU_ZVKSH
rv64gcv_zvkg|RV64GCV default plus Zvkg GHASH/GCM only|KARU_ZVKG
rv64gcv_zvk|RV64GCV default plus all implemented standard Zvk leaves|KARU_ZVK
rv64gcv_keccak|RV64GCV default plus custom vkeccak|KARU_KECCAK
rv64gcv_zvk_keccak|RV64GCV default plus Zvk and custom vkeccak|KARU_ZVK KARU_KECCAK
EOF
}

want_config() {
	local cfg="$1"
	if [ -z "${CONFIGS:-}" ]; then
		return 0
	fi
	case " $CONFIGS " in
		*" $cfg "*) return 0 ;;
		*) return 1 ;;
	esac
}

csv_escape() {
	printf '%s' "$1" | sed 's/"/""/g'
}

hier_area() {
	local rpt="$1" mod="$2"
	awk -v m="$mod" '$NF == m && $1 ~ /^[0-9]+$/ { area=$(NF-1) } END { if (area != "") print area + 0; else print 0 }' "$rpt" 2>/dev/null
}

kge() {
	local area="$1"
	awk -v a="$area" -v n="$NAND2_UM2" 'BEGIN { printf "%.2f", a / n / 1000.0 }'
}

append_locked() {
	local file="$1" line="$2"
	if command -v flock >/dev/null 2>&1; then
		{
			flock 9
			printf '%s\n' "$line" >> "$file"
		} 9>"$file.lock"
	else
		local lock="${file}.lockdir"
		while ! mkdir "$lock" 2>/dev/null; do sleep 0.05; done
		printf '%s\n' "$line" >> "$file"
		rmdir "$lock"
	fi
}

run_row() {
	local cfg="$1" desc="$2" defs="$3"
	local out console t0 rc wall rpt area status
	local top_kge mem_area sv39_area karu_mem_kge karu_sv39_kge
	local karu_csr_kge karu_bitmanip_kge no_mem_kge no_sv39_kge
	local karu_m_kge karu_fpu_kge karu_fregfile_kge
	local karu_fmul_kge karu_fmul_d_kge karu_ffma_kge karu_ffma_d_kge
	local karu_fdiv_kge karu_fdiv_d_kge karu_varith_kge
	local karu_vcrypto_kge keccak_kge row

	out="$matrix_dir/$cfg"
	console="$matrix_dir/${cfg}.console.log"
	t0=$(date +%s)
	KARU_OUT_DIR="$out" KARU_DEFINES="$defs" KARU_NO_STA=1 \
		timeout --signal=KILL "$PER_TIMEOUT" ./syn_yosys.sh \
		> "$console" 2>&1
	rc=$?
	wall=$(( $(date +%s) - t0 ))

	rpt="$out/reports/area.rpt"
	area="$(awk '/Chip area for top module/ { area=$NF } END { print area }' "$rpt" 2>/dev/null)"

	if [ -n "$area" ]; then
		status="ok"
		top_kge="$(kge "$area")"
		mem_area="$(hier_area "$rpt" karu_mem)"
		sv39_area="$(hier_area "$rpt" karu_sv39)"
		karu_mem_kge="$(kge "$mem_area")"
		karu_sv39_kge="$(kge "$sv39_area")"
		karu_csr_kge="$(kge "$(hier_area "$rpt" karu_csr)")"
		karu_bitmanip_kge="$(kge "$(hier_area "$rpt" karu_bitmanip)")"
		no_mem_kge="$(kge "$(awk -v a="$area" -v b="$mem_area" 'BEGIN { print a - b }')")"
		no_sv39_kge="$(kge "$(awk -v a="$area" -v b="$mem_area" -v c="$sv39_area" 'BEGIN { print a - b - c }')")"
		karu_m_kge="$(kge "$(hier_area "$rpt" karu_m)")"
		karu_fpu_kge="$(kge "$(hier_area "$rpt" karu_fpu)")"
		karu_fregfile_kge="$(kge "$(hier_area "$rpt" karu_fregfile)")"
		karu_fmul_kge="$(kge "$(hier_area "$rpt" karu_fmul)")"
		karu_fmul_d_kge="$(kge "$(hier_area "$rpt" karu_fmul_d)")"
		karu_ffma_kge="$(kge "$(hier_area "$rpt" karu_ffma)")"
		karu_ffma_d_kge="$(kge "$(hier_area "$rpt" karu_ffma_d)")"
		karu_fdiv_kge="$(kge "$(hier_area "$rpt" karu_fdiv)")"
		karu_fdiv_d_kge="$(kge "$(hier_area "$rpt" karu_fdiv_d)")"
		karu_varith_kge="$(kge "$(hier_area "$rpt" karu_varith)")"
		karu_vcrypto_kge="$(kge "$(hier_area "$rpt" karu_vcrypto)")"
		keccak_kge="$(kge "$(hier_area "$rpt" keccak)")"
	else
		if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then status="timeout"; else status="failed"; fi
		area=""; top_kge=""; no_mem_kge=""; no_sv39_kge=""
		karu_mem_kge=""; karu_sv39_kge=""; karu_csr_kge=""; karu_bitmanip_kge=""
		karu_m_kge=""; karu_fpu_kge=""; karu_fregfile_kge=""
		karu_fmul_kge=""; karu_fmul_d_kge=""; karu_ffma_kge=""; karu_ffma_d_kge=""
		karu_fdiv_kge=""; karu_fdiv_d_kge=""
		karu_varith_kge=""; karu_vcrypto_kge=""; keccak_kge=""
	fi

	row="$(printf '"%s","%s","%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"' \
		"$(csv_escape "$cfg")" "$(csv_escape "$desc")" "$(csv_escape "$defs")" \
		"$status" "${area:-}" "${top_kge:-}" "${no_mem_kge:-}" "${no_sv39_kge:-}" \
		"${karu_mem_kge:-}" "${karu_sv39_kge:-}" "${karu_csr_kge:-}" "${karu_bitmanip_kge:-}" \
		"${karu_m_kge:-}" "${karu_fpu_kge:-}" "${karu_fregfile_kge:-}" \
		"${karu_fmul_kge:-}" "${karu_fmul_d_kge:-}" "${karu_ffma_kge:-}" "${karu_ffma_d_kge:-}" \
		"${karu_fdiv_kge:-}" "${karu_fdiv_d_kge:-}" "${karu_varith_kge:-}" \
		"${karu_vcrypto_kge:-}" "${keccak_kge:-}" "$wall" "$out")"
	append_locked "$summary" "$row"

	printf '%-24s %-12s %-9s %-9s %-8s %ss\n' "$cfg" "$status" "${top_kge:--}" "${no_mem_kge:--}" "${no_sv39_kge:--}" "$wall"
}

rows_file="$matrix_dir/rows.txt"
if [ -n "${MATRIX_FILE:-}" ]; then
	cp "$MATRIX_FILE" "$rows_file"
elif [ -n "${MATRIX_ROWS:-}" ]; then
	printf '%s\n' "$MATRIX_ROWS" > "$rows_file"
else
	default_matrix > "$rows_file"
fi

echo "area matrix -> $matrix_dir"
echo "  per-config timeout: ${PER_TIMEOUT}s"
echo "  parallel jobs: ${JOBS}"
echo "  selected configs: ${CONFIGS:-<default matrix>}"
echo
printf '%-24s %-12s %-9s %-9s %-8s %s\n' config status kGE no_mem no_sv39 wall

active=0
while IFS='|' read -r cfg desc defs; do
	[ -n "${cfg:-}" ] || continue
	case "$cfg" in \#*) continue ;; esac
	want_config "$cfg" || continue

	if [ "$JOBS" -le 1 ]; then
		run_row "$cfg" "$desc" "${defs:-}"
	else
		run_row "$cfg" "$desc" "${defs:-}" &
		active=$((active + 1))
		if [ "$active" -ge "$JOBS" ]; then
			wait -n || true
			active=$((active - 1))
		fi
	fi
done < "$rows_file"

while [ "$active" -gt 0 ]; do
	wait -n || true
	active=$((active - 1))
done

echo
echo "summary: $summary"
echo "console logs: $matrix_dir/*.console.log"
