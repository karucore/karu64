#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build separate intentionally failing guests; never alter fixture inputs.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
FIXTURE=${KVM_OUT:-$ROOT/_build/kvm-karu-debugfix}
CONTROL=${KVM_CONTROL_OUT:-$ROOT/_build/kvm-karu-timer-controls}
CC=${KVM_CC:-riscv64-unknown-linux-gnu-gcc}
QEMU=${KVM_QEMU:-$(command -v qemu-system-riscv64)}
JOBS=${KVM_BUILD_JOBS:-8}
[[ ! -e "$CONTROL" ]] || { echo "choose a new KVM_CONTROL_OUT" >&2; exit 1; }
FIXTURE=$(cd -- "$FIXTURE" && pwd -P)
mkdir -p "$CONTROL"
CONTROL=$(cd -- "$CONTROL" && pwd -P)
SRC=$FIXTURE/src/linux-7.1.2
grep -qx 'patches=1' "$FIXTURE/source-state.txt"
(cd "$SRC" && sha256sum --quiet -c "$FIXTURE/source.sha256")
for mode in 1 2; do
    VARIANT=$CONTROL/$mode
    mkdir -p "$VARIANT/selftests"
    # Inject only into the RISC-V guest translation unit, not the host or
    # library sources. All other objects use the normal fixture flags.
    make -C "$SRC/tools/testing/selftests/kvm" ARCH=riscv CC="$CC" \
        OUTPUT="$VARIANT/selftests" KHDR_INCLUDES="-isystem $FIXTURE/kernel/usr/include" \
        EXTRA_CFLAGS="-march=rv64gc -mabi=lp64d -include $HERE/timer-negative.h -DKVM_TIMER_NEGATIVE=$mode" \
        LDFLAGS='-static -pthread -no-pie' -j"$JOBS" \
        "$VARIANT/selftests/riscv/arch_timer.o" > "$VARIANT/build.log" 2>&1
    make -C "$SRC/tools/testing/selftests/kvm" ARCH=riscv CC="$CC" \
        OUTPUT="$VARIANT/selftests" KHDR_INCLUDES="-isystem $FIXTURE/kernel/usr/include" \
        EXTRA_CFLAGS='-march=rv64gc -mabi=lp64d' \
        LDFLAGS='-static -pthread -no-pie' -j"$JOBS" \
        "$VARIANT/selftests/arch_timer" >> "$VARIANT/build.log" 2>&1
    sed -e "s|@OUT@|$FIXTURE|g" \
        -e "s|$FIXTURE/selftests/arch_timer|$VARIANT/selftests/arch_timer|" \
        "$HERE/rootfs.list.in" > "$VARIANT/rootfs.list"
    "$FIXTURE/kernel/usr/gen_init_cpio" -t 0 "$VARIANT/rootfs.list" > "$VARIANT/initramfs.cpio"
    set +e
    python3 "$HERE/run.py" --qemu "$QEMU" \
        --kernel "$FIXTURE/kernel/arch/riscv/boot/Image" \
        --opensbi "$FIXTURE/fw_jump.bin" --initramfs "$VARIANT/initramfs.cpio" \
        --wall-seconds 120 --log "$VARIANT/qemu.log"
    result=$?
    set -e
    [[ "$result" == 1 ]]
    grep -qF '[KVM-KARU] PASS ebreak_test exit=0' "$VARIANT/qemu.log"
    grep -qF '[KVM-KARU] RUN arch_timer' "$VARIANT/qemu.log"
    if [[ "$mode" == 1 ]]; then
        grep -qF 'Unexpected guest exit' "$VARIANT/qemu.log"
    else
        grep -qF 'shared_data->nr_iter == test_args.nr_iter' "$VARIANT/qemu.log"
    fi
    if grep -qF '[KVM-KARU] COMPLETE' "$VARIANT/qemu.log"; then
        echo 'negative timer guest unexpectedly completed' >&2
        exit 1
    fi
    sha256sum "$HERE/timer-negative.h" "$HERE/test_timer_controls.sh" \
        "$VARIANT/selftests/arch_timer" "$VARIANT/initramfs.cpio" > "$VARIANT/manifest.txt"
    printf 'PASS: timer negative control %s was rejected as intended\n' "$mode"
done
(cd "$SRC" && sha256sum --quiet -c "$FIXTURE/source.sha256")
