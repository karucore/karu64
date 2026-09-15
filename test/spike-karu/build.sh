#!/usr/bin/env bash
# Build a pinned, isolated timer oracle. Never modify or install over a checkout.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
pin=f10808d48aec727b41757334ff18c416b0242516
tree=1080400980fda5c8eed77c9dc02b124c0e3e7e77
mode=${1:-patched}
case "$mode" in patched|baseline) ;; *) echo "usage: bash $0 [patched|baseline]" >&2; exit 2;; esac
src=$(realpath "${SPIKE_SOURCE:-$repo/../src/riscv-isa-sim}")
out=$(realpath -m "${SPIKE_OUT:-$repo/_build/spike-sstc-${pin:0:12}-$mode}")
jobs=${JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be positive' >&2; exit 2; }
case "$out" in "$repo"/_build/*) ;; *) echo 'SPIKE_OUT must be below this repository/_build/' >&2; exit 2;; esac
[[ ! -e $out ]] || { echo "Refusing to overwrite $out; choose a new SPIKE_OUT" >&2; exit 2; }
[[ $(git -C "$src" rev-parse HEAD) == "$pin" &&
   $(git -C "$src" rev-parse 'HEAD^{tree}') == "$tree" ]] || {
    echo "Unsupported Spike source: require commit $pin, tree $tree" >&2
    exit 2
}

# Export the committed tree, not working-tree modifications or existing objects.
mkdir -p "$(dirname "$out")"
mkdir "$out"
mkdir "$out/src" "$out/build"
git -C "$src" archive --format=tar "$pin" | tar -xf - -C "$out/src"
(
    cd "$out/src"
    printf '%s\n' \
        'cbee9a7b03d7aa1c4764549c85890366b26112a89879d98923460f75059b22aa  riscv/csrs.cc' \
        '7e9c3a84531c1e4e616b9d6520be71943b0d609fba30722fe61f26463ce53246  riscv/csrs.h' \
        '300db68bde1853934b4360c0e0aeec31ae31f161542d5a4f6e2483412d7dcb46  riscv/csr_init.cc' |
        sha256sum --check
) > "$out/source-check.log"
if [[ $mode == patched ]]; then
    patch --directory="$out/src" --strip=1 --fuzz=0 --batch --forward \
        --input="$repo/test/spike-karu/patches/sstc-pending.patch" > "$out/patch.log"
    if grep -Eiq 'offset|fuzz|failed|reject' "$out/patch.log"; then
        echo "Patch was not exact; inspect $out/patch.log" >&2
        exit 2
    fi
fi
{
    printf 'source_commit=%s\nsource_tree=%s\nmode=%s\n' "$pin" "$tree" "$mode"
    printf 'CC=%s\nCXX=%s\nCFLAGS=%s\nCXXFLAGS=%s\nJOBS=%s\n' \
        "${CC:-gcc}" "${CXX:-g++}" "${CFLAGS:--O1 -g0}" "${CXXFLAGS:--O1 -g0}" "$jobs"
    sha256sum "$repo/test/spike-karu/patches/sstc-pending.patch" \
        "$out/src/riscv/csrs.cc" "$out/src/riscv/csrs.h" "$out/src/riscv/csr_init.cc"
    "${CXX:-g++}" --version
} > "$out/manifest.txt"
(
    cd "$out/build"
    # Do not let the exported source inherit Karu's Git version information.
    export GIT_CEILING_DIRECTORIES="$out"
    CC="${CC:-gcc}" CXX="${CXX:-g++}" \
        CFLAGS="${CFLAGS:--O1 -g0}" CXXFLAGS="${CXXFLAGS:--O1 -g0}" \
        ../src/configure --prefix="$out/install-unused" > "$out/configure.log" 2>&1
    make -j"$jobs" "project_ver=$pin-sstc-$mode" spike > "$out/build.log" 2>&1
)
sha256sum "$out/build/spike" >> "$out/manifest.txt"
printf '%s\n' "$out/build/spike"
