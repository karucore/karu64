#!/usr/bin/env bash
#	build_uboot.sh -- build U-Boot for the karudeb/karu64 SoC (Ethernet bring-up
#	phase E2). U-Boot runs as the OpenSBI S-mode payload: NS16550 console + CLINT
#	timer + LiteEth, all from the karudeb device tree (OF_PRIOR_STAGE FDT via a1).
#
#	Output: $UBOOT_DIR/u-boot.bin  (load at 0x8020_0000 = OpenSBI fw_jump target).
#
#	Env:  UBOOT_REF (default v2026.10)   UBOOT_DIR (default ../u-boot-$UBOOT_REF)
#	      CROSS_COMPILE (default: the bare-metal toolchain of $RISCV, else the
#	      first RISC-V toolchain on PATH). The Makefile passes its XCHAIN.
#
#	$UBOOT_DIR/karu-toolchain.txt records the compiler that built u-boot.bin:
#	its path, what `gcc -dumpmachine` says it targets, and its version. A
#	name on PATH does not say which compiler it is.
#
#	The tree in UBOOT_DIR must be the release named by UBOOT_REF: a tree left
#	from an earlier release is refused, not built under the new name. One
#	local patch is applied, flow/boot/uboot-zkr-timeout.patch (see below).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UBOOT_REF="${UBOOT_REF:-v2026.10}"
UBOOT_DIR="${UBOOT_DIR:-$HERE/../u-boot-$UBOOT_REF}"
ZKR_PATCH="$HERE/flow/boot/uboot-zkr-timeout.patch"
ZKR_DRIVER=drivers/rng/riscv_zkr_rng.c
#	the driver of $UBOOT_REF as released, and with the patch applied
ZKR_DRIVER_SHA=af767fdb58632a4b8fcfb2ee19920b88fbf367ecd854ae277c602644283039d2
ZKR_PATCHED_SHA=94e649a111bcb219a734c15d0d9f69369dba6aa9f33acf03a57aa142204cc329
if [ -z "${CROSS_COMPILE:-}" ]; then
	if [ -n "${RISCV:-}" ] && [ -x "$RISCV/bin/riscv64-unknown-elf-gcc" ]; then
		CROSS_COMPILE="$RISCV/bin/riscv64-unknown-elf-"
	elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
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
cc_path=$(command -v "${CROSS_COMPILE}gcc") || { echo "ERROR: no compiler ${CROSS_COMPILE}gcc" >&2; exit 1; }
cc_machine=$("${CROSS_COMPILE}gcc" -dumpmachine)
cc_name=$(basename "${CROSS_COMPILE}gcc" -gcc)
if [ "$cc_machine" != "$cc_name" ]; then
	echo "ERROR: $cc_path is named for $cc_name but targets $cc_machine." >&2
	echo "       Set CROSS_COMPILE to the prefix of the compiler meant." >&2
	exit 1
fi
cc_record="$cc_path targets $cc_machine; $("${CROSS_COMPILE}gcc" --version | head -1)"
echo "== compiler: $cc_record =="

if [ ! -d "$UBOOT_DIR" ]; then
	echo "== cloning U-Boot $UBOOT_REF =="
	git clone --depth 1 --branch "$UBOOT_REF" https://github.com/u-boot/u-boot.git "$UBOOT_DIR"
fi
cd "$UBOOT_DIR"
have_ref=$(git describe --tags --exact-match 2>/dev/null || true)
if [ "$have_ref" != "$UBOOT_REF" ]; then
	echo "ERROR: $UBOOT_DIR holds U-Boot '${have_ref:-unknown}', not $UBOOT_REF." >&2
	echo "       Point UBOOT_DIR at another directory (it is cloned if missing)," >&2
	echo "       or set UBOOT_REF to the release that tree has." >&2
	exit 1
fi

#	The Zkr random-number driver as released polls the seed CSR until it gets
#	words and has no way out of BIST or WAIT, so with the entropy source held
#	off, or dead, U-Boot would hang at the first request for random numbers.
#	The patch bounds every wait (100 ms) and returns an error instead. Its
#	only user here is the kaslr-seed property that U-Boot adds to the device
#	tree before it starts Linux; without a word the property is left out and
#	"No RNG device" is printed, as with the driver off. The patch is tied to
#	one release: the driver's hash is checked before and after.
if [ "$UBOOT_REF" = v2026.10 ]; then
	driver_sha=$(sha256sum "$ZKR_DRIVER" | cut -d' ' -f1)
	if [ "$driver_sha" = "$ZKR_DRIVER_SHA" ]; then
		patch --batch --fuzz=0 -p1 < "$ZKR_PATCH"
		driver_sha=$(sha256sum "$ZKR_DRIVER" | cut -d' ' -f1)
	fi
	if [ "$driver_sha" != "$ZKR_PATCHED_SHA" ]; then
		echo "ERROR: $UBOOT_DIR/$ZKR_DRIVER is neither the released file nor the patched one" >&2
		exit 1
	fi
	zkr_rng=enable
else
	zkr_rng=disable			#	no bounded driver for this release
fi

#	Base: the upstream RISC-V S-mode payload config (qemu-virt, but everything is
#	DT-driven so the karu64 SoC description comes from the prior-stage FDT).
make qemu-riscv64_smode_defconfig >/dev/null

#	Deltas for this SoC:
#	- EFI and capsule tooling are disabled for the netboot-only image.
#	- Fixed TEXT_BASE at the OpenSBI fw_jump target (no PIE-load needed).
#	- LiteEth NIC.
./scripts/config --disable EFI_LOADER --disable CMD_BOOTEFI --disable CMD_BOOTEFI_SELFTEST \
	--disable CMD_NVEDIT_EFI --disable TOOLS_MKEFICAPSULE --disable EFI_CAPSULE_ON_DISK \
	--disable EFI_CAPSULE_FIRMWARE --disable EFI_VARIABLE_FILE_STORE \
	--disable EFI_RT_VOLATILE_STORE --disable BOOTSTD_FULL --disable EFI
#	- The Zkr random-number driver only with the patch above; and the rng
#	  command, to try it from the prompt. No rng-seed is passed to Linux
#	  (BOARD_RNG_SEED stays off): only kaslr-seed, which Linux does not count
#	  as entropy.
./scripts/config --$zkr_rng RNG_RISCV_ZKR --$zkr_rng CMD_RNG --disable BOARD_RNG_SEED
./scripts/config --disable POSITION_INDEPENDENT
./scripts/config --set-val TEXT_BASE 0x80200000
./scripts/config --enable LITEETH
#	Auto-netboot (HW): if UBOOT_NETBOOT_CMD is set, bake it into bootcmd + a short
#	bootdelay so U-Boot runs the whole TFTP netboot hands-off -- no glitch-prone
#	interactive typing on the real console. Default/sim keeps BOOTDELAY=-1 (prompt).
if [ -n "${UBOOT_NETBOOT_CMD:-}" ]; then
	./scripts/config --set-val BOOTDELAY 2
	./scripts/config --enable USE_BOOTCOMMAND
	# v2025.01 scripts/config substitutes string values through sed without
	# escaping '&', corrupting Hush's && operators. Write a fresh Kconfig
	# string instead; quote/backslash escaping belongs to Kconfig, not sed.
	case "$UBOOT_NETBOOT_CMD" in
		*$'\n'*|*$'\r'*) echo 'ERROR: UBOOT_NETBOOT_CMD must be one line' >&2; exit 1 ;;
	esac
	bootcmd_config=${UBOOT_NETBOOT_CMD//\\/\\\\}
	bootcmd_config=${bootcmd_config//\"/\\\"}
	./scripts/config --undefine BOOTCOMMAND
	printf 'CONFIG_BOOTCOMMAND="%s"\n' "$bootcmd_config" >> .config
	echo "== baked auto-netboot bootcmd =="
else
	./scripts/config --set-val BOOTDELAY -1
fi
make olddefconfig >/dev/null
if [ -n "${UBOOT_NETBOOT_CMD:-}" ]; then
	grep -Fxq "CONFIG_BOOTCOMMAND=\"$bootcmd_config\"" .config || {
		echo 'ERROR: Kconfig did not preserve the requested bootcommand' >&2
		exit 1
	}
fi

#	RISC-V links -pie unconditionally; the bare-metal GNU ld.bfd can't, so use lld.
#	Every object must come from the compiler that the record names. Kbuild
#	rebuilds when a command line changes, not when the same name starts to
#	mean another compiler, so a tree whose record is missing or differs is
#	cleaned first.
if [ "$(cat karu-toolchain.txt 2>/dev/null)" != "$cc_record" ]; then
	echo "== compiler record missing or changed: make clean =="
	make clean >/dev/null
fi
rm -f karu-toolchain.txt
make -j"$(nproc)" LD=ld.lld u-boot.bin
printf '%s\n' "$cc_record" > karu-toolchain.txt
echo "== built $(pwd)/u-boot.bin ($(stat -c%s u-boot.bin) bytes) =="
