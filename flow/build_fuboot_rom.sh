#!/usr/bin/env bash
#	build_fuboot_rom.sh -- assemble the 1 MiB karu64 boot ROM image and emit it as a
#	$readmemh hex (one 64-bit little-endian word per line) for karu_boot_mem.
#
#	Layout (ROM offsets; core address = 0x1000 + offset):
#	    [ fu-boot @0 | OpenSBI @opensbi_off | U-Boot @uboot_off | DTB @dtb_off ]
#	fu-boot copies OpenSBI->0x80000000, U-Boot->0x80200000, DTB->0x81b00000 and boots.
#	The blob sizes are baked into fu-boot via flow/boot/fuboot_blobs.h (generated separately);
#	this script must use the SAME offsets, passed in as arguments.
set -euo pipefail

if [ "$#" -ne 8 ]; then
	echo "usage: $0 <fuboot.bin> <opensbi.bin> <opensbi_off> <uboot.bin> <uboot_off> <dtb> <dtb_off> <out.hex>" >&2
	exit 2
fi

fuboot="$1"
opensbi="$2"; opensbi_off="$3"
uboot="$4";   uboot_off="$5"
dtb="$6";     dtb_off="$7"
out="$8"

rom_bytes=$((0x100000))		# 1 MiB -- MUST match karu_boot_mem ROM_BYTES

oo=$((opensbi_off)); uo=$((uboot_off)); do_=$((dtb_off))

sz() { stat -c%s "$1"; }
for f in "$fuboot" "$opensbi" "$uboot" "$dtb"; do
	[ -r "$f" ] || { echo "build_fuboot_rom: cannot read $f" >&2; exit 1; }
done
fb=$(sz "$fuboot"); os=$(sz "$opensbi"); ub=$(sz "$uboot"); dt=$(sz "$dtb")

chk() {	# name end_offset limit
	if [ "$2" -gt "$3" ]; then
		printf 'build_fuboot_rom: %s overruns its region (end=0x%x > limit=0x%x)\n' \
			"$1" "$2" "$3" >&2
		exit 1
	fi
}
chk "fu-boot"  "$fb"          "$oo"
chk "OpenSBI"  "$((oo + os))" "$uo"
chk "U-Boot"   "$((uo + ub))" "$do_"
chk "DTB"      "$((do_ + dt))" "$rom_bytes"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
head -c "$rom_bytes" /dev/zero > "$tmp"
dd if="$fuboot"  of="$tmp" bs=64k seek=0     oflag=seek_bytes conv=notrunc status=none
dd if="$opensbi" of="$tmp" bs=64k seek="$oo" oflag=seek_bytes conv=notrunc status=none
dd if="$uboot"   of="$tmp" bs=64k seek="$uo" oflag=seek_bytes conv=notrunc status=none
dd if="$dtb"     of="$tmp" bs=64k seek="$do_" oflag=seek_bytes conv=notrunc status=none

hexdump -v -e '1/8 "%016x\n"' "$tmp" > "$out"
printf 'build_fuboot_rom: %s  (fu-boot %d, OpenSBI %d @0x%x, U-Boot %d @0x%x, DTB %d @0x%x; %s words)\n' \
	"$out" "$fb" "$os" "$oo" "$ub" "$uo" "$dt" "$do_" "$(wc -l < "$out")"
