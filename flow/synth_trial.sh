#!/usr/bin/env bash
#
#	synth_trial.sh -- full-featured RV64GCV+Zvk+Keccak trial synthesis driver.
#
#	Sequentially OOCs each functional unit for area/resource sizing, then runs
#	a full-core synth-only pass at 75 MHz for a timing-closure estimate.
#	Continues past a failing run so one bad module doesn't abort the batch.
#	Run from the repo root in a shell where Vivado settings have been sourced.
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOGDIR="$ROOT/_build/synth_trial"
mkdir -p "$LOGDIR"

#	full-featured area-friendly config
FEAT_DEFS="KARU_MUL_CYCLES=4 KARU_DIV_CYCLES=64 KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64 KARU_V_PERM_LANES=2 KARU_ZVK KARU_KECCAK"

#	memory guard for a 32 GB / 0-swap host: graceful malloc-fail, not OOM-thrash
VMEM=26000000
THREADS=16
DIR=RuntimeOptimized

#	OOC modules (small/fast first to validate the flow, big ones last)
OOC_MODS="keccak karu_vrf_bram karu_vcrypto karu_vlsu karu_vlane karu_varith karu64"

echo "=== synth_trial start ==="
echo "config: $FEAT_DEFS"
date

for m in $OOC_MODS; do
	echo ">>> OOC $m ..."
	t0=$SECONDS
	make ooc OOC_TOP="$m" OOC_DEFINES="$FEAT_DEFS" OOC_PERIOD=13.33 \
		SYNTH_DIRECTIVE="$DIR" VIVADO_VMEM_KB="$VMEM" VIVADO_THREADS="$THREADS" \
		> "$LOGDIR/ooc_$m.out" 2>&1
	rc=$?
	dt=$((SECONDS - t0))
	echo "<<< OOC $m rc=$rc (${dt}s)"
done

echo ">>> full-core DDR synth-only @ 75 MHz (MIG ui_clk / KARU_DDR_CPU_DIV=4 = 300/4) ..."
t0=$SECONDS
make vcu118_ddr.bit KARU_DEFINES="$FEAT_DEFS KARU_DDR_CPU_DIV=4" \
	SYNTH_ONLY=1 SYNTH_DIRECTIVE="$DIR" VIVADO_VMEM_KB="$VMEM" VIVADO_THREADS="$THREADS" \
	> "$LOGDIR/full_synth.out" 2>&1
rc=$?
dt=$((SECONDS - t0))
echo "<<< full-core synth-only rc=$rc (${dt}s)"

echo "=== synth_trial done ==="
date
