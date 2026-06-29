#!/usr/bin/env bash
#	build_uboot.sh -- build U-Boot for the karudeb/karu64 SoC (Ethernet bring-up
#	phase E2). U-Boot runs as the OpenSBI S-mode payload: NS16550 console + CLINT
#	timer + LiteEth, all from the karudeb device tree (OF_PRIOR_STAGE FDT via a1).
#
#	Output: $UBOOT_DIR/u-boot.bin  (load at 0x8020_0000 = OpenSBI fw_jump target).
#
#	Env:  UBOOT_DIR (default ../u-boot)   UBOOT_REF (default v2025.01)
#	      CROSS_COMPILE (default: first available RISC-V toolchain)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UBOOT_DIR="${UBOOT_DIR:-$HERE/../u-boot}"
UBOOT_REF="${UBOOT_REF:-v2025.01}"
if [ -z "${CROSS_COMPILE:-}" ]; then
	if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
		CROSS_COMPILE=riscv64-unknown-elf-
	elif command -v riscv64-unknown-linux-gnu-gcc >/dev/null 2>&1; then
		CROSS_COMPILE=riscv64-unknown-linux-gnu-
	elif command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
		CROSS_COMPILE=riscv64-linux-gnu-
	else
		echo "ERROR: missing RISC-V compiler (tried unknown-elf, unknown-linux-gnu, linux-gnu)" >&2
		exit 1
	fi
fi
export CROSS_COMPILE

if [ ! -d "$UBOOT_DIR" ]; then
	echo "== cloning U-Boot $UBOOT_REF =="
	git clone --depth 1 --branch "$UBOOT_REF" https://github.com/u-boot/u-boot.git "$UBOOT_DIR"
fi
cd "$UBOOT_DIR"

#	Base: the upstream RISC-V S-mode payload config (qemu-virt, but everything is
#	DT-driven so the karu64 SoC description comes from the prior-stage FDT).
make qemu-riscv64_smode_defconfig >/dev/null

#	Deltas for this SoC / build host:
#	- EFI off: the mkeficapsule host tool needs gnutls-dev (absent), and we don't
#	  need EFI for a netboot U-Boot.
#	- Fixed TEXT_BASE at the OpenSBI fw_jump target (no PIE-load needed).
#	- LiteEth NIC.
./scripts/config --disable EFI_LOADER --disable CMD_BOOTEFI --disable CMD_BOOTEFI_SELFTEST \
	--disable CMD_NVEDIT_EFI --disable TOOLS_MKEFICAPSULE --disable EFI_CAPSULE_ON_DISK \
	--disable EFI_CAPSULE_FIRMWARE --disable EFI_VARIABLE_FILE_STORE \
	--disable EFI_RT_VOLATILE_STORE --disable BOOTSTD_FULL --disable EFI
./scripts/config --disable POSITION_INDEPENDENT
./scripts/config --set-val TEXT_BASE 0x80200000
./scripts/config --enable LITEETH
#	Auto-netboot (HW): if UBOOT_NETBOOT_CMD is set, bake it into bootcmd + a short
#	bootdelay so U-Boot runs the whole TFTP netboot hands-off -- no glitch-prone
#	interactive typing on the real console. Default/sim keeps BOOTDELAY=-1 (prompt).
if [ -n "${UBOOT_NETBOOT_CMD:-}" ]; then
	./scripts/config --set-val BOOTDELAY 2
	./scripts/config --enable USE_BOOTCOMMAND
	./scripts/config --set-str BOOTCOMMAND "$UBOOT_NETBOOT_CMD"
	echo "== baked auto-netboot bootcmd =="
else
	./scripts/config --set-val BOOTDELAY -1
fi
make olddefconfig >/dev/null

#	RISC-V links -pie unconditionally; the bare-metal GNU ld.bfd can't, so use lld.
make -j"$(nproc)" LD=ld.lld u-boot.bin
echo "== built $(pwd)/u-boot.bin ($(stat -c%s u-boot.bin) bytes) =="
