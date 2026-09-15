#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build an isolated, pinned Linux KVM host and upstream selftest guests.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
PATCHES=${KVM_PATCHES:-1}
case "$PATCHES" in
    1) DEFAULT_OUT=$ROOT/_build/kvm-karu-debugfix ;;
    0) DEFAULT_OUT=$ROOT/_build/kvm-karu-pristine ;;
    *) echo 'KVM_PATCHES must be 0 or 1' >&2; exit 1 ;;
esac
OUT=${KVM_OUT:-$DEFAULT_OUT}
KARUDEB=${KARUDEB:-$ROOT/../karudeb}
ARCHIVE=${KVM_LINUX_ARCHIVE:-$KARUDEB/build/kernel-source/linux-7.1.2.tar.xz}
OPENSBI=${KVM_OPENSBI:-$KARUDEB/build/karu64/opensbi/fw_jump.bin}
JOBS=${KVM_BUILD_JOBS:-8}
CC=${KVM_CC:-riscv64-unknown-linux-gnu-gcc}
HOSTCC=${KVM_HOST_CC:-/usr/bin/cc}
HOSTCXX=${KVM_HOST_CXX:-/usr/bin/c++}
ARCHIVE_SHA=37198c93727be247c9fb5309bb86cd5e496c61e5322cd8c4eca9476bb0b5883f
OPENSBI_SHA=307ff4379bb146646a0825b510e5f16b664c669e7b24390b381350a5a914fc21
export LC_ALL=C SOURCE_DATE_EPOCH=0
export KBUILD_BUILD_TIMESTAMP='1970-01-01 00:00:00 UTC'
export KBUILD_BUILD_USER=karu KBUILD_BUILD_HOST=kvm-fixture KBUILD_BUILD_VERSION=1

die() { echo "KVM fixture: $*" >&2; exit 1; }
check_hash() {
    [[ -f "$2" ]] || die "missing pinned input: $2"
    [[ $(sha256sum "$2" | cut -d' ' -f1) == "$1" ]] || die "source fingerprint mismatch: $2"
}
for tool in make tar patch sha256sum clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-readelf dtc fdtput "$CC" "$HOSTCC" "$HOSTCXX"; do
    command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "KVM_BUILD_JOBS must be a positive integer"
check_hash "$ARCHIVE_SHA" "$ARCHIVE"
check_hash "$OPENSBI_SHA" "$OPENSBI"
mkdir -p "$OUT"
OUT=$(cd -- "$OUT" && pwd -P)
SRC=$OUT/src/linux-7.1.2
KOUT=$OUT/kernel
TESTOUT=$OUT/selftests
source_state() {
    printf 'linux_archive_sha256=%s\npatches=%s\n' "$ARCHIVE_SHA" "$PATCHES"
    if [[ "$PATCHES" == 1 ]]; then
        (cd "$HERE" && sha256sum patches/guest-debug-config.patch patches/timer-done.patch)
    fi
}
if [[ ! -d "$SRC" ]]; then
    mkdir -p "$OUT/src"
    tar --no-same-owner -xf "$ARCHIVE" -C "$OUT/src"
    (cd "$SRC" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$OUT/source-pristine.sha256"
    if [[ "$PATCHES" == 1 ]]; then
        check_hash dea806f1db0f467e3403fe86546a0d9f96248421b7c0bdb2458d97d7e3c24e12 "$SRC/arch/riscv/kvm/vcpu.c"
        check_hash a37b9a404ee5537b1b72d5cdf333195cc85d1a60abbf98ecb91dc36cc2e144a4 "$SRC/arch/riscv/kvm/vcpu_config.c"
        check_hash 7b639f8a9d8522aa8cf7fc376b981dd120f5fe2e933c36271745baa37adc0699 "$SRC/tools/testing/selftests/kvm/arch_timer.c"
        patch --batch --fuzz=0 -p1 -d "$SRC" < "$HERE/patches/guest-debug-config.patch"
        patch --batch --fuzz=0 -p1 -d "$SRC" < "$HERE/patches/timer-done.patch"
    fi
    (cd "$SRC" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$OUT/source.sha256"
    source_state > "$OUT/source-state.txt"
elif [[ ! -f "$OUT/source.sha256" || ! -f "$OUT/source-pristine.sha256" || ! -f "$OUT/source-state.txt" ]]; then
    die "existing source snapshot has no complete manifest; choose a new KVM_OUT: $SRC"
fi
cmp -s "$OUT/source-state.txt" <(source_state) || die "source/patch mode changed; choose a new KVM_OUT"
(cd "$SRC" && sha256sum --quiet -c "$OUT/source.sha256")
mkdir -p "$KOUT" "$TESTOUT"
MAKE_ARGS=(-C "$SRC" O="$KOUT" ARCH=riscv LLVM=1 HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX")
make "${MAKE_ARGS[@]}" KCONFIG_ALLCONFIG="$HERE/kernel.config" allnoconfig
for option in CONFIG_KVM=y CONFIG_RISCV_ISA_V=y CONFIG_FPU=y CONFIG_BLK_DEV_INITRD=y CONFIG_BINFMT_ELF=y; do
    grep -qxF "$option" "$KOUT/.config" || die "required kernel setting lost: $option"
done
make "${MAKE_ARGS[@]}" -j"$JOBS" Image headers
make -C "$SRC/tools/testing/selftests/kvm" ARCH=riscv CC="$CC" \
    OUTPUT="$TESTOUT" KHDR_INCLUDES="-isystem $KOUT/usr/include" \
    EXTRA_CFLAGS='-march=rv64gc -mabi=lp64d' LDFLAGS='-static -pthread -no-pie' \
    -j"$JOBS" "$TESTOUT/riscv/ebreak_test" "$TESTOUT/arch_timer"
"$CC" -march=rv64gc -mabi=lp64d -static -no-pie -O2 -Wall -Wextra -Werror \
    "$HERE/init.c" -o "$OUT/init"
sed "s|@OUT@|$OUT|g" "$HERE/rootfs.list.in" > "$OUT/rootfs.list"
"$KOUT/usr/gen_init_cpio" -t 0 "$OUT/rootfs.list" > "$OUT/initramfs.cpio"
dtc -I dts -O dtb -o "$OUT/board.dtb" "$HERE/karu-kvm.dts"
IMAGE=$KOUT/arch/riscv/boot/Image
image_size=$(stat -c%s "$IMAGE")
initrd_size=$(stat -c%s "$OUT/initramfs.cpio")
initrd_end=$((0x81200000 + initrd_size))
((0x80200000 + image_size <= 0x81200000)) || die "kernel overlaps initramfs"
((initrd_end <= 0x81c00000)) || die "initramfs overlaps DTB"
(( $(stat -c%s "$OUT/board.dtb") <= 0x400000 )) || die "DTB exceeds RAM"
fdtput -t x "$OUT/board.dtb" /chosen linux,initrd-end 0 "$(printf '%x' "$initrd_end")"
cp "$OPENSBI" "$OUT/fw_jump.bin"
cp "$OUT/fw_jump.bin" "$OUT/flat.img"
dd if="$IMAGE" of="$OUT/flat.img" bs=4096 seek=512 conv=notrunc status=none
dd if="$OUT/initramfs.cpio" of="$OUT/flat.img" bs=4096 seek=4608 conv=notrunc status=none
(cd "$SRC" && sha256sum --quiet -c "$OUT/source.sha256")
{
    printf 'linux_archive_sha256=%s\nopensbi_sha256=%s\n' "$ARCHIVE_SHA" "$OPENSBI_SHA"
    printf 'image_bytes=%s\ninitrd_bytes=%s\ninitrd_end=0x%x\nram_bytes=33554432\n' \
        "$image_size" "$initrd_size" "$initrd_end"
    "$CC" --version | head -1
    "$HOSTCC" --version | head -1
    clang --version | head -1
    ld.lld --version
    source_state
    for tool in "$CC" "$HOSTCC" "$HOSTCXX" clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-readelf dtc fdtput; do
        sha256sum "$(command -v "$tool")"
    done
    sha256sum "$HERE"/build.sh "$HERE"/init.c "$HERE"/kernel.config "$HERE"/karu-kvm.dts \
        "$HERE"/README.md "$HERE"/run.py "$HERE"/test_runner.py \
        "$HERE"/timer-negative.h "$HERE"/test_timer_controls.sh \
        "$HERE"/rootfs.list.in "$OUT/source-pristine.sha256" "$OUT/source.sha256" \
        "$OUT/source-state.txt" "$KOUT/.config" "$IMAGE" \
        "$OUT/fw_jump.bin" "$OUT/init" "$TESTOUT/riscv/ebreak_test" "$TESTOUT/arch_timer" \
        "$OUT/initramfs.cpio" "$OUT/board.dtb" "$OUT/flat.img"
} > "$OUT/manifest.txt"
printf 'KVM fixture built: %s\n' "$OUT"
cat "$OUT/manifest.txt"
