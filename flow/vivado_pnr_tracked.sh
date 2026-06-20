#!/usr/bin/env bash
#	vivado_pnr_tracked.sh -- run a Vivado synth+P&R make target with wall-time +
#	peak-memory instrumentation. Samples the live vivado RSS (+ system used/avail)
#	every SAMPLE_SEC into a CSV, wraps the build in /usr/bin/time -v, and prints a
#	summary. Use for the heavy vcu118.bit / vcu118-ddr runs to characterise the
#	resource cost (the "how much time/RAM does full-vector P&R take" question).
#
#	Usage:  flow/vivado_pnr_tracked.sh <make target + VAR=val args...>
#	Env:    RUN_TAG (output label, default "pnr"), SAMPLE_SEC (default 15),
#	        VIVADO_SETTINGS (default the 2025.2.1 settings64 path).
set -uo pipefail
cd "$(dirname "$0")/.."

VIVADO_SETTINGS="${VIVADO_SETTINGS:-$HOME/Xilinx/2025.2.1/Vivado/.settings64-Vivado.sh}"
SAMPLE_SEC="${SAMPLE_SEC:-15}"
RUN_TAG="${RUN_TAG:-pnr}"
OUT="_build/pnr_${RUN_TAG}"
mkdir -p "$OUT"
MEM_CSV="$OUT/mem.csv"; TIME_LOG="$OUT/time.txt"; RUN_LOG="$OUT/run.log"
PEAK_FILE="$OUT/peak_rss_mb.txt"; echo 0 > "$PEAK_FILE"

if [ ! -f "$VIVADO_SETTINGS" ]; then echo "no Vivado settings at $VIVADO_SETTINGS" >&2; exit 2; fi
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"
echo "vivado: $(command -v vivado)"  | tee "$RUN_LOG"
echo "target: make $*"               | tee -a "$RUN_LOG"

echo "epoch,iso,elapsed_s,vivado_rss_mb,mem_used_mb,mem_avail_mb,phase" > "$MEM_CSV"
START=$(date +%s)

#	background sampler: total RSS of all vivado processes + system memory + the
#	current Vivado phase (last "Starting <phase>" line in the build log).
(
  peak=0
  while :; do
    now=$(date +%s); el=$((now-START))
    rss=$(ps --no-headers -o rss -C vivado 2>/dev/null | awk '{s+=$1} END{printf "%d", s/1024}')
    [ -z "$rss" ] && rss=0
    read -r used avail < <(free -m | awk '/Mem:/{print $3" "$7}')
    phase=$(grep -aoE "Starting (Synthesize|Logic Optimization|Placer|Physical|Routing|Power|Bitgen)[^.]*" "$RUN_LOG" 2>/dev/null | tail -1 | tr ',' ' ')
    echo "$now,$(date -Iseconds),$el,$rss,$used,$avail,$phase" >> "$MEM_CSV"
    if [ "$rss" -gt "$peak" ]; then peak=$rss; echo "$peak" > "$PEAK_FILE"; fi
    sleep "$SAMPLE_SEC"
  done
) & SAMPLER=$!
trap 'kill "$SAMPLER" 2>/dev/null' EXIT

/usr/bin/time -v -o "$TIME_LOG" make "$@" 2>&1 | tee -a "$RUN_LOG"
RC=${PIPESTATUS[0]}
kill "$SAMPLER" 2>/dev/null
END=$(date +%s); DUR=$((END-START))

{
  echo "================= TRACKED RUN SUMMARY ($RUN_TAG) ================="
  echo "exit code      : $RC"
  echo "wall time      : $((DUR/3600))h $(((DUR%3600)/60))m $((DUR%60))s  (${DUR}s)"
  echo "peak vivado RSS: $(cat "$PEAK_FILE") MB  (15s sampler)"
  grep -E "Maximum resident set size|Elapsed \(wall" "$TIME_LOG" 2>/dev/null | sed 's/^[[:space:]]*/  time -v: /'
  echo "artifacts      : $MEM_CSV  $TIME_LOG  $RUN_LOG"
} | tee "$OUT/summary.txt"
exit "$RC"
