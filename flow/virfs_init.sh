#!/bin/sh
#	virfs_init.sh -- PID 1 for the karu64 V-Linux initramfs userspace smoke.
#	Embedded as /init in the initrd (overrides the smoldeb busybox /init, last
#	wins in the concatenated cpio). Brings up the minimal mounts, then runs the
#	freestanding userspace RVV test /vectest (vsetvli + vle32 + vadd.vv + vse32
#	in U-mode). A printed "[VECTEST] PASS" proves Linux grants userspace the
#	vector unit. Not interactive: the sim has no stdin, so we run + report + halt.
/bin/busybox mount -t proc     proc /proc 2>/dev/null
/bin/busybox mount -t sysfs    sys  /sys  2>/dev/null
/bin/busybox mount -t devtmpfs dev  /dev  2>/dev/null
/bin/busybox --install -s 2>/dev/null
exec </dev/console >/dev/console 2>&1
echo
echo "[INIT] ============================================="
echo "[INIT]  RV64GCV Linux userspace reached (PID 1)"
echo "[INIT] ============================================="
/bin/busybox uname -srm
/vectest
echo "[INIT] vectest exit=$?"
/bin/busybox poweroff -f 2>/dev/null
/bin/busybox sleep 8
echo "[INIT] (still alive after poweroff attempt)"
