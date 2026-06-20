#	write_vcu118_flash_payload.tcl
#	=== Build a VCU118 configuration-memory image containing the bitstream plus
#	    a raw payload at a fixed flash offset.
#
#	Required environment:
#	  KARU_FLASH_PAYLOAD       raw payload file, e.g. ../smoldeb/build/bundle/flat.img.gz
#	  KARU_FLASH_OFFSET        byte offset in flash, e.g. 0x02000000
#	  KARU_CFGMEM_SIZE_MB      cfgmem size in MiB, power of two
#
#	Optional environment:
#	  KARU_BITFILE             bitstream file (default _build/vcu118_ddr.bit)
#	  KARU_FLASH_MCS           output file (default _build/vcu118_ddr_payload.mcs)
#	  KARU_CFGMEM_INTERFACE    write_cfgmem interface (default SPIx4)
#
#	This only creates the .mcs file. Programming the board's cfgmem still needs
#	a connected VCU118 and a hw_cfgmem part selected by Vivado/hardware.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

proc need_env {name} {
	if {![info exists ::env($name)] || $::env($name) eq ""} {
		puts "ERROR: missing required environment variable $name"
		exit 1
	}
	return $::env($name)
}

set payload	[karu_env_path KARU_FLASH_PAYLOAD [need_env KARU_FLASH_PAYLOAD]]
set offset	[need_env KARU_FLASH_OFFSET]
set size_mb	[need_env KARU_CFGMEM_SIZE_MB]

set bitfile [karu_build_path vcu118_ddr.bit]
if {[info exists ::env(KARU_BITFILE)] && $::env(KARU_BITFILE) ne ""} {
	set bitfile [karu_env_path KARU_BITFILE $::env(KARU_BITFILE)]
}

set outfile [karu_build_path vcu118_ddr_payload.mcs]
if {[info exists ::env(KARU_FLASH_MCS)] && $::env(KARU_FLASH_MCS) ne ""} {
	set outfile [karu_env_path KARU_FLASH_MCS $::env(KARU_FLASH_MCS)]
}

set interface "SPIx4"
if {[info exists ::env(KARU_CFGMEM_INTERFACE)] && $::env(KARU_CFGMEM_INTERFACE) ne ""} {
	set interface $::env(KARU_CFGMEM_INTERFACE)
}

if {![file exists $bitfile]} {
	puts "ERROR: missing bitfile $bitfile"
	exit 1
}
if {![file exists $payload]} {
	puts "ERROR: missing payload $payload"
	exit 1
}

puts "CFG bitfile:   $bitfile @ 0x0"
puts "CFG payload:  $payload @ $offset"
puts "CFG output:   $outfile"
puts "CFG size MiB: $size_mb"
puts "CFG iface:    $interface"

write_cfgmem -force -format MCS -size $size_mb -interface $interface \
	-loadbit "up 0x0 $bitfile" \
	-loaddata "up $offset $payload" \
	$outfile

puts "Wrote $outfile"
