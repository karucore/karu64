#	load_vcu118_ddr.tcl
#	=== Load a binary into VCU118 DDR4 through jtag_axi_0.
#	ONLY for KARU_DDR_HOST_DBG builds: jtag_axi_0 and the CPU-hold host-AXI mux
#	are compiled out by default (the CPU fills DRAM itself from the fu-boot ROM).
#
#	Environment:
#	  KARU_LOAD_BIN   required, binary file to load
#	  KARU_LOAD_ADDR  optional, default 0x80000000
#	  KARU_LOAD_MAX   optional, byte limit for smoke tests
#	  KARU_LOAD_BURST optional, 32-bit words per JTAG AXI transaction, default 16

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

if {![info exists ::env(KARU_LOAD_BIN)] || $::env(KARU_LOAD_BIN) eq ""} {
	puts "ERROR: set KARU_LOAD_BIN=/path/to/image"
	exit 1
}
set load_file [karu_env_path KARU_LOAD_BIN ""]
set load_addr 0x80000000
if {[info exists ::env(KARU_LOAD_ADDR)] && $::env(KARU_LOAD_ADDR) ne ""} {
	set load_addr $::env(KARU_LOAD_ADDR)
}
set max_bytes 0
if {[info exists ::env(KARU_LOAD_MAX)] && $::env(KARU_LOAD_MAX) ne ""} {
	set max_bytes [expr {$::env(KARU_LOAD_MAX) + 0}]
}
set burst_words 16
if {[info exists ::env(KARU_LOAD_BURST)] && $::env(KARU_LOAD_BURST) ne ""} {
	set burst_words [expr {$::env(KARU_LOAD_BURST) + 0}]
}
if {$burst_words < 1 || $burst_words > 256} {
	puts "ERROR: KARU_LOAD_BURST must be 1..256 words"
	exit 1
}

if {![file exists $load_file]} {
	puts "ERROR: missing load file $load_file"
	exit 1
}

set_msg_config -id {Labtoolstcl 44-481} -suppress
set_msg_config -id {Labtoolstcl 44-227} -suppress

proc get_vio_probe {vio name} {
	set p [get_hw_probes -of_objects $vio $name]
	if {[llength $p] == 0} { return "" }
	return [lindex $p 0]
}

proc vio_status {vio} {
	refresh_hw_vio $vio
	set hold [get_vio_probe $vio host_cpu_hold]
	set rst  [get_vio_probe $vio rst_ui_sync]
	set cal  [get_vio_probe $vio led_o_OBUF]
	set ctl  [get_vio_probe $vio host_ctl]
	puts "VIO_STATUS calib=[get_property INPUT_VALUE $cal] cpu_rst=[get_property INPUT_VALUE $rst] hold=[get_property INPUT_VALUE $hold] host_ctl=[get_property OUTPUT_VALUE $ctl]"
}

proc axi_write32 {axi addr word idx} {
	set name [format "wr_%08x_%06d" $addr $idx]
	catch {delete_hw_axi_txn [get_hw_axi_txns $name]}
	set txn [create_hw_axi_txn $name $axi -type write -address [format 0x%08x $addr] -data [format %08x $word]]
	run_hw_axi $txn
	catch {delete_hw_axi_txn $txn}
}

proc axi_write32_burst {axi addr data nwords idx} {
	set name [format "wr_%08x_%06d" $addr $idx]
	catch {delete_hw_axi_txn [get_hw_axi_txns $name]}
	set txn [create_hw_axi_txn $name $axi -type write -address [format 0x%08x $addr] -len $nwords -data $data]
	run_hw_axi $txn
	catch {delete_hw_axi_txn $txn}
}

proc axi_read32 {axi addr idx} {
	set name [format "rd_%08x_%06d" $addr $idx]
	catch {delete_hw_axi_txn [get_hw_axi_txns $name]}
	set txn [create_hw_axi_txn $name $axi -type read -address [format 0x%08x $addr] -len 1]
	run_hw_axi $txn
	set data [get_property DATA $txn]
	catch {delete_hw_axi_txn $txn}
	return [expr {"0x$data" + 0}]
}

proc hex_byte_at {hexbytes idx nbytes} {
	if {$idx >= $nbytes} {
		return 0
	}
	set o [expr {$idx * 2}]
	return [expr {"0x[string range $hexbytes $o [expr {$o + 1}]]" + 0}]
}

set fh [open $load_file rb]
fconfigure $fh -translation binary
set blob [read $fh]
close $fh
set nbytes [string length $blob]
if {$max_bytes > 0 && $max_bytes < $nbytes} {
	set nbytes $max_bytes
}
binary scan [string range $blob 0 [expr {$nbytes - 1}]] H* hexbytes

open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set ltxfile [karu_env_build_path KARU_LTXFILE vcu118_ddr.ltx]
if {[file exists $ltxfile]} {
	set_property PROBES.FILE $ltxfile [current_hw_device]
	set_property FULL_PROBES.FILE $ltxfile [current_hw_device]
}
refresh_hw_device [current_hw_device]

set vio [lindex [get_hw_vios] 0]
set ctl [get_vio_probe $vio host_ctl]
if {$ctl eq ""} {
	puts "ERROR: no VIO host_ctl probe found; is vcu118_ddr.ltx attached?"
	exit 1
}
set axi [lindex [get_hw_axis] 0]
if {$axi eq ""} {
	puts "ERROR: no JTAG AXI core found; program a bitstream with jtag_axi_0"
	exit 1
}

#	Hold the CPU while loading. The loader adapter is reset when hold is clear.
set_property OUTPUT_VALUE 1 $ctl
commit_hw_vio $vio
after 100
vio_status $vio

puts [format "LOAD file=%s addr=0x%08x bytes=%d axi=%s" $load_file $load_addr $nbytes $axi]
set addr [expr {$load_addr + 0}]
set words [expr {($nbytes + 3) / 4}]
for {set i 0} {$i < $words} {incr i $burst_words} {
	set n [expr {$words - $i}]
	if {$n > $burst_words} {
		set n $burst_words
	}
	set data ""
	for {set j 0} {$j < $n} {incr j} {
		set widx [expr {$i + $j}]
		set b0 [hex_byte_at $hexbytes [expr {$widx*4 + 0}] $nbytes]
		set b1 [hex_byte_at $hexbytes [expr {$widx*4 + 1}] $nbytes]
		set b2 [hex_byte_at $hexbytes [expr {$widx*4 + 2}] $nbytes]
		set b3 [hex_byte_at $hexbytes [expr {$widx*4 + 3}] $nbytes]
		if {$j != 0} {
			append data " "
		}
		append data [format "%08x" [expr {$b0 | ($b1 << 8) | ($b2 << 16) | ($b3 << 24)}]]
	}
	axi_write32_burst $axi [expr {$addr + $i*4}] $data $n $i
	if {($i % 65536) == 0} {
		puts [format "  wrote 0x%08x / %d words" [expr {$addr + $i*4}] $words]
	}
}

set v0 [axi_read32 $axi $addr 0]
set last_addr [expr {$addr + (($words - 1) * 4)}]
set v1 [axi_read32 $axi $last_addr 1]
puts [format "VERIFY first32=0x%08x last32@0x%08x=0x%08x" $v0 $last_addr $v1]
vio_status $vio
puts "CPU remains held. Set VIO host_ctl=0 to release."
