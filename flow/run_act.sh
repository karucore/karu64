#!/usr/bin/env bash
# flow/run_act.sh -- run ACT4-generated self-checking ELF(s) on karu64.
#
# ACT4 (the riscof successor) bakes the Sail-computed golden results into
# each ELF; the DUT just runs it. The test self-checks, prints
# "RVCP-SUMMARY: TEST PASSED|FAILED" over the HTIF console, and halts with
# tohost = 1 (pass) / 3 (fail). We classify on the HTIF exit code, with the
# RVCP marker as a cross-check.
#
# Usage:
#   flow/run_act.sh <elf>            # one ELF
#   flow/run_act.sh -d <dir>         # every *.elf under <dir>, in parallel
#
# Env overrides:
#   SIMV              verilator binary (default: the 4 MiB Vhtif_fp TB)
#   MAX_CYCLES        per-test cycle cap (default 2000000)
#   PER_TEST_TIMEOUT  wall-clock seconds per ELF (default 120)
#   JOBS              parallel jobs for -d mode (default min(nproc/2,8))
#   WORKDIR           scratch for .hex/.log (default _build/act-work)
#
# Exit: 0 if every ELF PASSED, 1 otherwise.

set -u
set -o pipefail
cd "$(dirname "$0")/.."

SIMV="${SIMV:-_build/Vhtif_fp/Vhtif_tb}"
MAX_CYCLES="${MAX_CYCLES:-2000000}"
PER_TEST_TIMEOUT="${PER_TEST_TIMEOUT:-120}"
WORKDIR="${WORKDIR:-_build/act-work}"
OBJCOPY="${OBJCOPY:-riscv64-unknown-elf-objcopy}"
NM="${NM:-riscv64-unknown-elf-nm}"

if (( $# < 1 )); then echo "usage: $0 <elf> | $0 -d <dir>" >&2; exit 2; fi
if [[ ! -x $SIMV ]]; then
  echo "[run_act] ERROR: $SIMV not found. Build it: make _build/Vhtif_fp/Vhtif_tb" >&2
  exit 2
fi

ELFS=()
if [[ "$1" == "-d" ]]; then
  shift; (( $# >= 1 )) || { echo "usage: $0 -d <dir>" >&2; exit 2; }
  while IFS= read -r -d '' f; do ELFS+=("$f"); done < <(find "$1" -type f -name '*.elf' -print0 | sort -z)
else
  ELFS+=("$1")
fi
(( ${#ELFS[@]} > 0 )) || { echo "[run_act] no ELFs found." >&2; exit 2; }

mkdir -p "$WORKDIR"
NCPU="$(nproc 2>/dev/null || echo 4)"
JOBS="${JOBS:-$(( NCPU/2 < 8 ? NCPU/2 : 8 ))}"; JOBS=$(( JOBS < 1 ? 1 : JOBS ))

run_one() {
  local elf="$1"
  local name; name="$(basename "${elf%.elf}")"
  local stem="${WORKDIR}/${name}"
  local hex="${stem}.hex" log="${stem}.log"
  local result code

  "$OBJCOPY" -O binary "$elf" "${stem}.bin" 2>/dev/null \
    || { printf '  %-44s %s\n' "$name" "OBJCOPY_FAIL" >&2; echo -e "${name}\tOBJCOPY_FAIL"; return; }
  hexdump -v -e '1/8 "%016x\n"' "${stem}.bin" > "$hex"

  # tohost byte-offset from the 0x80000000 load base (TB wants the offset).
  local off
  off="$("$NM" "$elf" | awk '/ tohost$/ { printf "%x", strtonum("0x"$1) - 0x80000000 }')"
  : "${off:=2000}"

  local out
  out="$(timeout --foreground "$PER_TEST_TIMEOUT" \
        "$SIMV" +hex="$hex" +tohost="$off" +max_cycles="$MAX_CYCLES" 2>&1)"
  code=$?
  printf '%s\n' "$out" > "$log"

  if grep -q '^\[HTIF\] exit 0 @' <<<"$out"; then
    result="PASS"
  elif grep -q 'RVCP-SUMMARY: TEST PASSED' <<<"$out"; then
    result="PASS"   # passed self-check even if exit decode was odd
  elif grep -q '^\[HTIF\] exit [1-9]' <<<"$out"; then
    result="FAIL"
  elif (( code == 124 )); then
    result="TIMEOUT"
  elif grep -q 'TRAP' <<<"$out"; then
    result="TRAP"
  else
    result="NO_MARKER"
  fi
  printf '  %-44s %-10s log=%s\n' "$name" "$result" "$log" >&2
  echo -e "${name}\t${result}"
}
export -f run_one
export SIMV MAX_CYCLES PER_TEST_TIMEOUT WORKDIR OBJCOPY NM

TSV="${WORKDIR}/results.tsv"; : > "$TSV"
printf '%s\n' "${ELFS[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} > "$TSV"

PASS=$(awk -F'\t' '$2=="PASS"' "$TSV" | wc -l)
TOTAL=$(awk 'NF' "$TSV" | wc -l)
echo
echo "[run_act] ${PASS}/${TOTAL} passed  ($(( TOTAL - PASS )) other) -- ${TSV}"
awk -F'\t' '$2!="PASS"{print "    "$1"  "$2}' "$TSV"
exit $(( PASS == TOTAL ? 0 : 1 ))
