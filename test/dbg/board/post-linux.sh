#!/bin/bash
# Runs on the board (copied by post_linux_host.py). Exit status and the
# final marker both follow status.tsv.
# SPDX-License-Identifier: BSD-2-Clause
set -u
OUT="${KARU_BOARD_REMOTE_DIR:-/root/debug-accept}"
EXPECT_KERNEL="${KARU_BOARD_EXPECT_KERNEL:?set KARU_BOARD_EXPECT_KERNEL to the expected uname -r}"
mkdir -p "$OUT"
cd "$OUT"
: > status.tsv
run() {
  local name="$1" limit="$2"; shift 2
  printf 'START %s %s\n' "$name" "$(date -Is)"
  timeout "$limit" "$@" >"$OUT/$name.log" 2>&1
  local rc=$?
  printf '%s\t%s\n' "$name" "$rc" >>status.tsv
  printf 'END %s rc=%s %s\n' "$name" "$rc" "$(date -Is)"
}
uname -a >uname.txt
cat /proc/cpuinfo >cpuinfo.txt
cat /proc/mounts >mounts.txt
dmesg >dmesg-before.txt
run board-accept 1200 board_accept.sh --mem 256 --expect-kernel "$EXPECT_KERNEL" --expect-isa h,svpbmt,svade,sstc,ssstateen,zvkned,zvksed --out "$OUT/board-accept"
run kvm-ebreak 180 "$OUT/ebreak_test"
run kvm-arch-timer 180 "$OUT/arch_timer" -n 1 -i 2 -p 1 -m 0 -e 1000
for binary in validate_v_ptrace vstate_ptrace vstate_prctl v_initval; do
  run "$binary" 180 "$OUT/$binary"
done
run openssl-zvk-kat 600 openssl_zvk_bench --kat-only --out "$OUT/openssl-zvk"
if [[ -x /root/xtest ]]; then run xtest 180 /root/xtest; fi
dmesg >dmesg-after.txt
sync
cat status.tsv
if awk '$2 != 0 {bad=1} END {exit bad}' status.tsv; then
  echo POST_LINUX_ACCEPT_PASS
else
  echo POST_LINUX_ACCEPT_FAIL
  exit 1
fi
