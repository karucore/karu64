#	prog_vcu118_cfgmem.tcl
#	=== Program a .mcs into the VCU118 SPI configuration flash over JTAG.
#	    The VCU118 cfgmem is a Micron MT25QU01G (SPIx4). This erases+programs
#	    only the regions present in the .mcs (a payload-only MCS is fast).
#
#	Required environment:
#	  KARU_FLASH_MCS       .mcs file to program
#	Optional:
#	  KARU_CFGMEM_PART     hw_cfgmem part (default mt25qu01g-spi-x1_x2_x4)

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

proc need_env {name} {
	if {![info exists ::env($name)] || $::env($name) eq ""} {
		puts "ERROR: missing required environment variable $name"; exit 1
	}
	return $::env($name)
}

set mcs  [karu_env_path KARU_FLASH_MCS [need_env KARU_FLASH_MCS]]
set part "mt25qu01g-spi-x1_x2_x4"
if {[info exists ::env(KARU_CFGMEM_PART)] && $::env(KARU_CFGMEM_PART) ne ""} {
	set part $::env(KARU_CFGMEM_PART)
}
if {![file exists $mcs]} { puts "ERROR: missing mcs $mcs"; exit 1 }

open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

#	Attach the cfgmem part to the device and point it at the MCS.
set cfgmem [create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts $part] 0]]
set_property PROGRAM.BLANK_CHECK  0 $cfgmem
set_property PROGRAM.ERASE        1 $cfgmem
set_property PROGRAM.CFG_PROGRAM  1 $cfgmem
set_property PROGRAM.VERIFY       1 $cfgmem
set_property PROGRAM.CHECKSUM     0 $cfgmem
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfgmem
set_property PROGRAM.FILES [list $mcs] $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem

puts "PROG_CFGMEM part=$part mcs=$mcs"
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $cfgmem
puts "CFGMEM_PROGRAMMED"
