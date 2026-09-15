#!/usr/bin/env bash
# Compare the same normative firmware on corrected and unmodified references.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
patched=$(realpath "${1:-_build/spike-sstc-f10808d48aec-patched/build/spike}")
baseline=$(realpath "${2:-_build/spike-sstc-f10808d48aec-baseline/build/spike}")
timer=$(realpath "${3:-_build/karu_htimer_test.elf}")
out=$(realpath -m "${SPIKE_RUN_OUT:-_build/spike-sstc-regression}")
case "$out" in "$repo"/_build/*) ;; *) echo 'SPIKE_RUN_OUT must be below _build/' >&2; exit 2;; esac
[[ ! -e $out ]] || { echo "Refusing to overwrite $out" >&2; exit 2; }
for input in "$patched" "$baseline" "$timer"; do
    [[ -f $input ]] || { echo "Missing input $input" >&2; exit 2; }
done
base_isa=rv64gcvh_zvl256b_zicntr_svinval_smstateen_svade_smnpm_ssnpm_zimop_zicclsm
mkdir -p "$(dirname "$out")"
mkdir "$out"
sha256sum "$patched" "$baseline" "$timer" > "$out/manifest.txt"
printf 'name\texpected\texit\tverdict\n' > "$out/results.tsv"
run_case() {
    local name=$1 expected=$2 model=$3 isa=$4 elf=$5 rc
    shift 5
    sha256sum "$elf" >> "$out/manifest.txt"
    # Spike's --instructions limit exits zero even without target HTIF success.
    # Use an external deadline instead, so an unfinished test cannot pass.
    printf '%q ' timeout 60s "$model" "--isa=$isa" "$@" "$elf" >> "$out/commands.txt"
    printf '\n' >> "$out/commands.txt"
    if timeout 60s "$model" "--isa=$isa" "$@" "$elf" > "$out/$name.log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    if [[ $expected == pass ]]; then
        if [[ $rc != 0 ]] || grep -Eiq 'FAILED|error:|assertion|terminate called' "$out/$name.log"; then
            printf '%s\t%s\t%s\tFAIL\n' "$name" "$expected" "$rc" >> "$out/results.tsv"
            echo "$name failed; inspect $out/$name.log" >&2
            return 1
        fi
    elif [[ $rc == 0 || $rc == 124 ]] || ! grep -Fq '*** FAILED *** (tohost = 1142)' "$out/$name.log"; then
        printf '%s\t%s\t%s\tFAIL\n' "$name" "$expected" "$rc" >> "$out/results.tsv"
        echo "$name did not reproduce case 1142; inspect its log" >&2
        return 1
    fi
    printf '%s\t%s\t%s\tPASS\n' "$name" "$expected" "$rc" >> "$out/results.tsv"
    echo "$name: PASS (expected $expected, exit $rc)"
}
run_case timer-patched pass "$patched" "${base_isa}_sstc" "$timer"
run_case timer-baseline fail1142 "$baseline" "${base_isa}_sstc" "$timer" --log-commits
for ref in patched baseline; do
    if [[ $ref == patched ]]; then model=$patched; else model=$baseline; fi
    run_case "sstc-$ref" pass "$model" rv64gcv_zvl256b_zicntr_sstc _build/karu_sstc_test.elf
    for name in karu_h_test karu_hfence_test karu_hmem_hfence_test karu_hvm_test; do
        run_case "$name-$ref" pass "$model" "$base_isa" "_build/$name.elf"
    done
done
echo "Results and input fingerprints: $out"
