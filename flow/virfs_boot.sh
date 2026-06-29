#!/usr/bin/env bash
#	virfs_boot.sh -- assemble a self-contained V-enabled Linux *userspace* boot
#	(no NFS / no network) and optionally run it on the full-vector linux_tb.
#
#	What it produces (all under _build/):
#	  vectest                 freestanding static rv64gcv userspace RVV smoke
#	  combined.cpio           karudeb busybox initramfs + our /init + /vectest
#	  vklinux-irfs/.../Image   the karudeb karu64 V-kernel REBUILT with
#	                          CONFIG_BLK_DEV_INITRD=y (a copy of karudeb's build
#	                          dir -- non-destructive to the NFS-root kernel)
#	  karu64-irfs.dtb        karu64-sim DTB with clean bootargs + initrd nodes
#	  flat-v-irfs.img          OpenSBI fw_jump @0 + kernel @0x200000 + initrd @0x1200000
#
#	The boot path: OpenSBI (enables mstatus.VS from misa.V) -> S-mode V-kernel ->
#	unpack initrd -> /init -> /vectest in U-mode -> "[VECTEST] PASS".
#
#	Env overrides: KARUDEB, KARUDEB_INITRAMFS, OPENSBI_FW, RV_LINUX_TOOLCHAIN_BIN,
#	CROSS_COMPILE, RV_LINUX_CC, KERNEL_SRC, FORCE_KBUILD=1 (rebuild even if
#	Image exists), RUN=1 (launch boot).
set -euo pipefail
cd "$(dirname "$0")/.."

KARUDEB=${KARUDEB:-../karudeb}
KARUDEB_INITRAMFS=${KARUDEB_INITRAMFS:-$KARUDEB/build/karu64-rv64imac-image/initramfs.cpio.gz}
OPENSBI_FW=${OPENSBI_FW:-$KARUDEB/build/karu64/opensbi/fw_jump.bin}
RV_LINUX_TOOLCHAIN_BIN=${RV_LINUX_TOOLCHAIN_BIN:-}
CROSS_COMPILE=${CROSS_COMPILE:-riscv64-unknown-linux-gnu-}
RV_LINUX_CC=${RV_LINUX_CC:-${CROSS_COMPILE}gcc}
KERNEL_SRC=${KERNEL_SRC:-$KARUDEB/build/kernel-source/linux-7.1.2}
NFS_KERNEL_BUILD=${NFS_KERNEL_BUILD:-$KARUDEB/build/linux-riscv64-karu64}
SIM_DTB=${SIM_DTB:-$KARUDEB/build/karu64/karu64-sim.dtb}
B=_build
mkdir -p "$B"
if [ -n "$RV_LINUX_TOOLCHAIN_BIN" ]; then
	export PATH="$RV_LINUX_TOOLCHAIN_BIN:$PATH"
fi
if ! command -v "$RV_LINUX_CC" >/dev/null 2>&1; then
	echo "missing $RV_LINUX_CC; set RV_LINUX_TOOLCHAIN_BIN, CROSS_COMPILE, or RV_LINUX_CC" >&2
	exit 1
fi
KOUT=$(realpath -m "$B/vklinux-irfs")
IMAGE=$KOUT/arch/riscv/boot/Image

INITRD_ADDR=0x81200000		# RAM 0x80000000 + 0x1200000

echo "== 1. build freestanding userspace RVV smoke (test/fw/vectest.c) =="
"$RV_LINUX_CC" -march=rv64gcv -mabi=lp64d -static -no-pie -fno-pic \
	-nostdlib -ffreestanding -Os -Wall -o "$B/vectest" test/fw/vectest.c
file "$B/vectest" | sed 's/^/   /'

echo "== 2. rebuild the karu64 V-kernel with CONFIG_BLK_DEV_INITRD (non-destructive copy) =="
if [ ! -f "$IMAGE" ] || [ "${FORCE_KBUILD:-0}" = 1 ]; then
	rm -rf "$KOUT"; cp -a "$NFS_KERNEL_BUILD" "$KOUT"
	#	BINFMT_ELF/SCRIPT: the karudeb allnoconfig kernel ships with neither, so it
	#	cannot exec *any* userspace ELF (busybox or our /vectest) -- both ENOEXEC.
	#	BLK_DEV_INITRD: honour the DTB linux,initrd-start/end external initrd.
	"$KERNEL_SRC/scripts/config" --file "$KOUT/.config" \
		--enable BLK_DEV_INITRD --enable RD_GZIP \
		--enable BINFMT_ELF --enable BINFMT_SCRIPT
	make -s -C "$KERNEL_SRC" O="$KOUT" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
	make    -C "$KERNEL_SRC" O="$KOUT" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" Image
fi
ls -l "$IMAGE" | sed 's/^/   /'

echo "== 3. combined initrd: karudeb busybox cpio + our /init + /vectest (last wins) =="
rm -rf $B/irextra; mkdir -p $B/irextra
cp $B/vectest $B/irextra/vectest
cp flow/virfs_init.sh $B/irextra/init
chmod +x $B/irextra/init $B/irextra/vectest
( cd $B/irextra && find . | LANG=C cpio -o -H newc 2>/dev/null ) > $B/irextra.cpio
case "$KARUDEB_INITRAMFS" in
	*.gz) gzip -dc "$KARUDEB_INITRAMFS" > $B/karudeb-base.cpio ;;
	*) cp "$KARUDEB_INITRAMFS" $B/karudeb-base.cpio ;;
esac
cat $B/karudeb-base.cpio $B/irextra.cpio > $B/combined.cpio
CPIO_SZ=$(stat -c%s $B/combined.cpio)
INITRD_END=$(printf '0x%x' $((INITRD_ADDR + CPIO_SZ)))
echo "   combined.cpio = $CPIO_SZ bytes  initrd $INITRD_ADDR .. $INITRD_END"

echo "== 4. DTB: clean bootargs + initrd nodes =="
dtc -I dtb -O dts "$SIM_DTB" 2>/dev/null > $B/karu64-irfs.dts
python3 - "$B/karu64-irfs.dts" "$INITRD_ADDR" "$INITRD_END" <<'PY'
import sys,re
p,start,end=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
s=re.sub(r'bootargs = "[^"]*";',
         'bootargs = "console=ttyS0,115200 earlycon";\n\t\tlinux,initrd-start = <%s>;\n\t\tlinux,initrd-end = <%s>;'%(start,end), s, count=1)
open(p,'w').write(s)
PY
dtc -I dts -O dtb -o $B/karu64-irfs.dtb $B/karu64-irfs.dts 2>/dev/null
echo "   $(dtc -I dtb -O dts $B/karu64-irfs.dtb 2>/dev/null | grep -E 'bootargs|initrd' | tr -s ' \t')"

echo "== 5. flat image: fw_jump@0 + kernel@0x200000 + initrd@0x1200000 =="
cp "$OPENSBI_FW" $B/flat-v-irfs.img
dd if="$IMAGE"        of=$B/flat-v-irfs.img bs=4096 seek=512  conv=notrunc status=none
dd if=$B/combined.cpio of=$B/flat-v-irfs.img bs=4096 seek=4608 conv=notrunc status=none
ls -l $B/flat-v-irfs.img | sed 's/^/   /'

echo "== done. boot with:  make linux-v-irfs-sim   (or RUN=1) =="
if [ "${RUN:-0}" = 1 ]; then
	exec $B/Vlinux_v/Vlinux_tb +img=$B/flat-v-irfs.img +dtb=$B/karu64-irfs.dtb \
		+max_cycles=${MAX_CYCLES:-220000000} +heartbeat=${HEARTBEAT:-10000000}
fi
