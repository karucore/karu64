#	write_vcu118_flash_data.tcl
#	=== Build a VCU118 cfgmem image containing ONLY a raw payload at a flash
#	    offset (no bitstream). Used to test the monitor `flashgz` path: the
#	    firmware reads with 3-byte (24-bit) addressing, so the payload must sit
#	    in the low 16 MiB; a full bitstream would both overlap and exceed that
#	    range, so this variant omits -loadbit. The FPGA stays JTAG-configured.
#
#	Required environment:
#	  KARU_FLASH_PAYLOAD   raw payload file (e.g. a .gz)
#	  KARU_FLASH_OFFSET    byte offset in flash (< 0x1000000 for the 3-byte read)
#	  KARU_CFGMEM_SIZE_MB  cfgmem size in MiB, power of two (256 for VCU118)
#	Optional:
#	  KARU_FLASH_MCS       output file (default _build/vcu118_flash_data.mcs)
#	  KARU_CFGMEM_INTERFACE  write_cfgmem interface (default SPIx4)

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

proc need_env {name} {
	if {![info exists ::env($name)] || $::env($name) eq ""} {
		puts "ERROR: missing required environment variable $name"; exit 1
	}
	return $::env($name)
}

set payload [karu_env_path KARU_FLASH_PAYLOAD [need_env KARU_FLASH_PAYLOAD]]
set offset  [need_env KARU_FLASH_OFFSET]
set size_mb [need_env KARU_CFGMEM_SIZE_MB]

set outfile [karu_build_path vcu118_flash_data.mcs]
if {[info exists ::env(KARU_FLASH_MCS)] && $::env(KARU_FLASH_MCS) ne ""} {
	set outfile [karu_env_path KARU_FLASH_MCS $::env(KARU_FLASH_MCS)]
}
set interface "SPIx4"
if {[info exists ::env(KARU_CFGMEM_INTERFACE)] && $::env(KARU_CFGMEM_INTERFACE) ne ""} {
	set interface $::env(KARU_CFGMEM_INTERFACE)
}

if {![file exists $payload]} { puts "ERROR: missing payload $payload"; exit 1 }

puts "CFG payload:  $payload @ $offset (payload-only, no bitstream)"
puts "CFG output:   $outfile"
puts "CFG size MiB: $size_mb"
puts "CFG iface:    $interface"

write_cfgmem -force -format MCS -size $size_mb -interface $interface \
	-loaddata "up $offset $payload" \
	$outfile

puts "Wrote $outfile"
