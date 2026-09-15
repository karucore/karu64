#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Export a pinned source snapshot; never modify the supplied Git repository.
set -euo pipefail
if (( $# < 2 )); then
    echo "usage: bash test/sail-karu/build.sh SOURCE_REPO OUTPUT_DIR [CMAKE_OPTIONS...]" >&2
    exit 2
fi
pin=22fad389cb0ca92ef8f3cfff91fe258f14ee8de8
this_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_repo=$(realpath -- "$1")
output_dir=$(realpath -m -- "$2")
shift 2
test "$(git -C "$source_repo" rev-parse "$pin^{commit}")" = "$pin"
case "$output_dir/" in
    "$source_repo/"*) echo "Output must be outside the source repository" >&2; exit 2 ;;
esac
patches=("$this_dir/patches/h-sgeie-delegation.patch" "$this_dir/patches/h-mideleg-reset.patch"
         "$this_dir/patches/hpmevent-selector-mask.patch"
         "$this_dir/patches/virtual-fault-address.patch")
patch_id=$(sha256sum "${patches[@]}" | sha256sum | cut -c1-16)
work_dir="$output_dir/$pin-$patch_id"
mkdir -p -- "$work_dir"
if [[ ! -d "$work_dir/source" ]]; then
    export_dir=$(mktemp -d "$work_dir/export.XXXXXXXX")
    git -C "$source_repo" archive --format=tar "$pin" | tar -xf - -C "$export_dir"
    for patch_file in "${patches[@]}"; do
        patch --batch --forward --fuzz=0 --no-backup-if-mismatch -p1 \
            -d "$export_dir" -i "$patch_file"
    done
    mv -- "$export_dir" "$work_dir/source"
    (cd "$work_dir/source" && rg --files --hidden --no-ignore -0 | sort -z \
        | xargs -0 sha256sum) > "$work_dir/source.sha256"
fi
verify_source() {
    # CMake configures these two Lean manifests in the source directory.
    # All exported files and any other additions must still match exactly.
    (cd "$work_dir/source" && rg --files --hidden --no-ignore -0 \
        -g '!lean_emulator/lake-manifest.json' -g '!lean_emulator/lakefile.toml' | sort -z \
        | xargs -0 sha256sum) | diff -u "$work_dir/source.sha256" -
}
verify_source
sha256sum "${patches[@]}" > "$work_dir/patches.sha256"
printf '%s\n' "$pin" > "$work_dir/upstream.commit"
# Source exports contain no .git. Prevent CMake's optional git-describe from
# accidentally describing the enclosing processor repository instead.
cmake -S "$work_dir/source" -B "$work_dir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDOWNLOAD_GMP=OFF \
    -DENABLE_RISCV_TESTS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE "$@"
# Optional compiler-query cache from the same Sail compiler. Copy it into
# this build, never share a writable cache with another source tree.
if [[ -n "${SAIL_SMT_CACHE:-}" && ! -e "$work_dir/build/model/sail_smt_cache" ]]; then
    cp -- "$SAIL_SMT_CACHE" "$work_dir/build/model/sail_smt_cache"
fi
cmake --build "$work_dir/build" --target sail_riscv_sim --parallel "${JOBS:-4}"
verify_source
sha256sum "$work_dir/build/c_emulator/sail_riscv_sim" > "$work_dir/binary.sha256"
printf 'Patched reference: %s\n' "$work_dir/build/c_emulator/sail_riscv_sim"
