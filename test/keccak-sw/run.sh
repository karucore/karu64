#!/usr/bin/env bash
# Build/run the checked software comparison. All generated files stay in OUT.
set -euo pipefail
cd "$(dirname "$0")/../.."
src=test/keccak-sw
out=${OUT:-_build/keccak-sw}
mode=${1:-build}
gcc=${SW_GCC:-riscv64-unknown-linux-gnu-gcc}
clang=${SW_CLANG:-clang}
objcopy=${SW_OBJCOPY:-riscv64-unknown-linux-gnu-objcopy}
objdump=${SW_OBJDUMP:-riscv64-unknown-linux-gnu-objdump}
sim=${SIMV:-_build/Vhtif_zvk_kec_ship/Vhtif_tb}
spike=${SPIKE:-spike}
read -r -a compilers <<< "${SW_COMPILERS:-gcc clang}"
read -r -a rows <<< "${SW_ROWS:-gc zbb vec}"
mkdir -p "$out"
case "$mode" in build|run|spike) ;; *) echo "usage: bash $0 [build|run|spike]" >&2; exit 2;; esac
if [[ $mode == build ]]; then
    # Full stream fixtures come from portable C, SHAKE KATs independently from hashlib.
    "${HOST_CC:-cc}" -O2 "$src/sw_expected_gen.c" -o "$out/expected-gen"
    "$out/expected-gen" > "$out/sw_expected.h"
    cmp "$src/sw_expected.h" "$out/sw_expected.h"
    "${PYTHON:-python3}" "$src/gen_kat.py" > "$out/keccak_sw_kat.h"
    cmp test/fw/shake_kat.h "$out/keccak_sw_kat.h"
    {
        date -u
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            git rev-parse HEAD
            git status --short
        else
            echo 'No Git metadata (source archive); source hashes follow.'
        fi
        sha256sum "$src"/* test/fw/htif_start.S test/fw/htif.c test/fw/sio_generic.h test/fw/shake_kat.h
        "$gcc" --version
        "$objcopy" --version
        "$objdump" --version
        verilator --version
    } > "$out/manifest.txt"
elif [[ $mode == run ]]; then
    { date -u; printf 'SIMV=%s\n' "$sim"; sha256sum "$sim"; } > "$out/run-manifest.txt"
else
    { date -u; command -v "$spike"; "$spike" --help; } > "$out/spike-manifest.txt" 2>&1
fi
common=(-O3 -mabi=lp64d -mcmodel=medany -ffreestanding -fno-builtin -nostdlib -static -Itest/fw)
for cc in "${compilers[@]}"; do
for row in "${rows[@]}"; do
    tag=${cc}_${row}
    base=$out/sw_checked_$tag
    case "$row" in
        gc) arch=rv64gc;;
        zbb) arch=rv64gc_zbb;;
        vec) arch=rv64gcv_zbb_zvbb_zvl256b;;
        *) echo "unknown SW_ROWS entry: $row" >&2; exit 2;;
    esac
    case "$cc" in gcc|clang) ;; *) echo "unknown SW_COMPILERS entry: $cc" >&2; exit 2;; esac
    if [[ $mode == build ]]; then
        extra=()
        if [[ $cc == gcc ]]; then
            compiler=("$gcc")
            : > "$base.vec"
            report=(-fopt-info-vec-all="$base.vec")
            [[ $row != vec ]] || extra+=(-mrvv-vector-bits=zvl)
        else
            compiler=("$clang" --target=riscv64-unknown-linux-gnu "--sysroot=${SW_SYSROOT:-$("$gcc" -print-sysroot)}")
            report=(-Rpass=loop-vectorize -Rpass=slp-vectorizer)
            [[ $row != vec ]] || extra+=(-mrvv-vector-bits=256)
            "$clang" --version >> "$out/manifest.txt"
        fi
        # No LTO: the independent checker must observe all state/output words.
        (
            set -x
            "${compiler[@]}" "${common[@]}" -march="$arch" "${extra[@]}" "${report[@]}" -c "$src/keccak_sw_inline_bench.c" -o "$base.o" &&
            "$gcc" "${common[@]}" -O2 -march=rv64gc -T "$src/keccak_sw.ld" test/fw/htif_start.S test/fw/htif.c "$src/keccak_sw_mem.c" "$src/sw_check.c" "$base.o" -o "$base.elf" &&
            "$objcopy" -O binary "$base.elf" "$base.bin" &&
            hexdump -v -e '1/8 "%016x\n"' "$base.bin" > "$base.hex" &&
            "$objdump" -d "$base.elf" > "$base.dis"
        ) > "$base.compile" 2>&1 || { cat "$base.compile"; exit 1; }
        sha256sum "$base.elf" "$base.bin" >> "$out/manifest.txt"
        echo "$tag built"
    elif [[ $mode == run ]]; then
        echo "$tag: Verilator"
        "$sim" "+hex=$base.hex" +tohost=100000 +max_cycles=10000000 > "$base.log" 2>&1 || { cat "$base.log"; exit 1; }
        cat "$base.log"
        grep -q '\[HTIF\] exit 0 ' "$base.log"
        grep -q '\[SW KAT\] PASS' "$base.log"
        grep -q '\[STREAM\] ALL PASS' "$base.log"
    else
        # Spike is a functional oracle here, not a source of Karu cycle counts.
        echo "$tag: Spike (functional check only)"
        "$spike" --isa=rv64gcv_zvl256b_zicntr_zbb_zvbb "$base.elf" > "$base.spike.log" 2>&1 || { cat "$base.spike.log"; exit 1; }
        cat "$base.spike.log"
        grep -q '\[SW KAT\] PASS' "$base.spike.log"
        grep -q '\[STREAM\] ALL PASS' "$base.spike.log"
    fi
done
done
