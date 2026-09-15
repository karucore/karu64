#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Isolate the pinned UDB data correction for the architecturally legal GEILEN=0.
set -euo pipefail
this_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$this_dir/../.." && pwd)
out=$(realpath -m "${H_UDB_ROOT:-$repo/_build/udb-h-0.1.16}")
case "$out" in "$repo"/_build/*) ;; *) echo 'H_UDB_ROOT must be below _build/' >&2; exit 2;; esac
gem=$(BUNDLE_GEMFILE="$repo/test/riscv-arch-test/framework/src/act/data/Gemfile" bundle show udb)
[[ $(basename "$gem") == udb-0.1.16 ]] || { echo 'This correction requires UDB 0.1.16' >&2; exit 2; }
param=spec/std/isa/param/NUM_EXTERNAL_GUEST_INTERRUPTS.yaml
expected=714ac332d722a5b5dffd348f050807b29d2f42a82e1c4c56b3f439ccfa576434
[[ $(sha256sum "$gem/.data/$param") == "$expected "* ]] || {
    echo 'Pinned UDB parameter fingerprint mismatch; no correction applied' >&2
    exit 2
}
patch_file="$this_dir/patches/udb-geilen-zero.patch"
if [[ -e $out ]]; then
    [[ -f $out/manifest.sha256 ]] || { echo "Incomplete output $out; choose a fresh H_UDB_ROOT" >&2; exit 2; }
    (cd "$out" && sha256sum --status --check manifest.sha256)
    echo "Verified isolated H UDB data: $out"
    exit 0
fi
mkdir -p "$out"
cp -a "$gem/.data/." "$out/"
patch --batch --forward --fuzz=0 -p1 -d "$out" -i "$patch_file" > "$out/patch.log"
if grep -Eiq 'offset|fuzz|failed|reject' "$out/patch.log"; then
    echo "UDB patch was not exact; inspect $out/patch.log" >&2
    exit 2
fi
(
    cd "$out"
    find spec cfgs -type f -print0 | sort -z | xargs -0 sha256sum
    sha256sum "$patch_file"
) > "$out/manifest.sha256"
echo "Prepared isolated H UDB data: $out"
