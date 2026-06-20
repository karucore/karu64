#	mig_vcu118.tcl
#	=== Generate the Xilinx DDR4 (MIG) IP for the VCU118 (xcvu9p) DDR4 SODIMM.
#
#	The DDR4 IP presents a 512-bit AXI4 slave (c0_ddr4_s_axi_*) on its ui_clk
#	domain; the SoC (karu_ddr_xbar's 64-bit AXI master) reaches it through an
#	AXI4 data-width converter -- see flow/fpga/vcu118_ddr_top.v.
#
#	Run on a host with the VCU118 board files installed (needs Vivado + the
#	board part; the VCU118 is NOT required to GENERATE the IP, only to run the
#	bitstream). Invoked by `make mig-vcu118`; the Makefile starts Vivado
#	from _build and points this script back at the repo root.
#
#	Experimental opt-in custom down-bin (not used by default configurations):
#	    KARU_DDR4_CUSTOM_2133=1 make mig-vcu118
#
#	No normal make target enables this path. It exists only as a retained
#	experiment because it drops the board DDR4 interface automation. The generated
#	IP still uses module name ddr4_0 and the same top-level ports, but top-level
#	synthesis must also define KARU_DDR4_CUSTOM_2133 so vcu118_ddr_top derives
#	UART/CLINT constants from the resolved 266.5 MHz DDR4-2133 UI clock.
#
#	Outputs the IP under _build/ip/{ddr4_0,axi_clock_converter_0,
#	axi_dwidth_converter_0,vio_0,jtag_axi_0}; the synth flow
#	(flow/fpga/xcvu9p-ddr-synth.tcl) reads those .xci files.
#
#	NOTE: the exact memory part / AXI width are board+IP-version specific. The
#	values below are the documented VCU118 DDR4 defaults (250 MHz ref ->
#	1200 MHz DDR4, board-file-selected SODIMM, 512-bit AXI). Prefer the board
#	automation block if the board files expose the DDR4 interface; reconcile
#	the generated .veo port lists with the wrapper before synth.

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

set part   xcvu9p-flga2104-2L-e
set ipdir  [karu_build_path ip]

proc env_truthy {env_name} {
	if {![info exists ::env($env_name)] || $::env($env_name) eq ""} {
		return 0
	}
	set v [string tolower $::env($env_name)]
	return [expr {$v ne "0" && $v ne "false" && $v ne "no"}]
}

proc set_config_checked {ip prop value {required 1}} {
	if {[catch {set_property $prop $value $ip} err]} {
		if {$required} {
			error "failed to set $prop=$value: $err"
		}
		puts "mig_vcu118: WARNING could not set $prop=$value: $err"
		return
	}
	set got [get_property $prop $ip]
	if {$got ne $value} {
		if {$required} {
			error "$prop requested $value but read back $got"
		}
		puts "mig_vcu118: WARNING $prop requested $value but read back $got"
	} else {
		puts "mig_vcu118: set $prop = $got"
	}
}

set custom_2133 [env_truthy KARU_DDR4_CUSTOM_2133]
if {$custom_2133} {
	puts "mig_vcu118: KARU_DDR4_CUSTOM_2133=1 -- generating experimental custom-mode DDR4-2133 MIG"
} else {
	puts "mig_vcu118: generating board-preset DDR4-2400 MIG"
}

#	DDR4-debug scaffold (VIO CPU-hold + JTAG-AXI host loader). Off by default: the
#	CPU auto-boots, so vio_0/jtag_axi_0 are neither generated here nor read by the
#	synth flow. Single source of truth = the KARU_DDR_HOST_DBG token, accepted via
#	EITHER a standalone env var (`KARU_DDR_HOST_DBG=1 make mig-vcu118`) OR its
#	presence in KARU_DEFINES -- so a one-shot
#	`make vcu118_ddr.bit KARU_DEFINES="... KARU_DDR_HOST_DBG"` generates the IPs here
#	AND reads them at synth consistently (command-line KARU_DEFINES is exported to
#	this prerequisite recipe). The synth (xcvu9p-ddr-synth.tcl) gates the IP read +
#	the RTL define on the same KARU_DEFINES membership.
set host_dbg [env_truthy KARU_DDR_HOST_DBG]
if {!$host_dbg && [info exists ::env(KARU_DEFINES)] && \
	[lsearch -exact $::env(KARU_DEFINES) KARU_DDR_HOST_DBG] >= 0} {
	set host_dbg 1
}
if {$host_dbg} {
	puts "mig_vcu118: KARU_DDR_HOST_DBG -- generating vio_0 + jtag_axi_0 debug IPs"
} else {
	puts "mig_vcu118: debug scaffold off -- skipping vio_0 + jtag_axi_0 (auto-boot default)"
}

file mkdir $ipdir
file delete -force $ipdir/ddr4_0 $ipdir/axi_clock_converter_0 \
	$ipdir/axi_dwidth_converter_0 $ipdir/vio_0 $ipdir/jtag_axi_0
create_project -in_memory -part $part

#	Board part (enables DDR4 pin/timing automation). Adjust the version suffix
#	to whatever `get_board_parts *vcu118*` reports on this install.
catch {
	set bp [lindex [get_board_parts -quiet *vcu118*] 0]
	if {$bp ne ""} {
		set_property board_part $bp [current_project]
		puts "mig_vcu118: board_part = $bp"
	} else {
		puts "mig_vcu118: WARNING no vcu118 board part found -- using explicit config"
	}
}

#	Diagnostics: is the ddr4 IP available in this install?
set ddr4def [get_ipdefs -quiet *:ip:ddr4:*]
puts "mig_vcu118: ddr4 ipdefs = $ddr4def"
if {$ddr4def eq ""} {
	puts "mig_vcu118: ERROR ddr4 IP not found in this Vivado install"
	return
}
set dwcdef [get_ipdefs -quiet *:ip:axi_dwidth_converter:*]
puts "mig_vcu118: axi_dwidth_converter ipdefs = $dwcdef"
if {$dwcdef eq ""} {
	puts "mig_vcu118: ERROR axi_dwidth_converter IP not found in this Vivado install"
	return
}
set cdcdef [get_ipdefs -quiet *:ip:axi_clock_converter:*]
puts "mig_vcu118: axi_clock_converter ipdefs = $cdcdef"
if {$cdcdef eq ""} {
	puts "mig_vcu118: ERROR axi_clock_converter IP not found in this Vivado install"
	return
}
if {$host_dbg} {
	set viodef [get_ipdefs -quiet *:ip:vio:*]
	puts "mig_vcu118: vio ipdefs = $viodef"
	if {$viodef eq ""} {
		puts "mig_vcu118: ERROR vio IP not found in this Vivado install"
		return
	}
	set jtagaxidef [get_ipdefs -quiet *:ip:jtag_axi:*]
	puts "mig_vcu118: jtag_axi ipdefs = $jtagaxidef"
	if {$jtagaxidef eq ""} {
		puts "mig_vcu118: ERROR jtag_axi IP not found in this Vivado install"
		return
	}
}

create_ip -name ddr4 -vendor xilinx.com -library ip \
	-module_name ddr4_0 -dir $ipdir
create_ip -name axi_clock_converter -vendor xilinx.com -library ip \
	-module_name axi_clock_converter_0 -dir $ipdir
create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
	-module_name axi_dwidth_converter_0 -dir $ipdir
if {$host_dbg} {
	create_ip -name vio -vendor xilinx.com -library ip \
		-module_name vio_0 -dir $ipdir
	create_ip -name jtag_axi -vendor xilinx.com -library ip \
		-module_name jtag_axi_0 -dir $ipdir
}

set ddr4_ip [get_ips ddr4_0]

#	Board-preset mode ties the IP to the VCU118 DDR4 C1 channel + ref clock +
#	board reset. Experimental DDR4-2133 mode deliberately skips
#	C0_DDR4_BOARD_INTERFACE: the board preset disables
#	C0.DDR4_isCustom/TimePeriod/MemoryPart, so 938 ps is only settable on a fresh
#	custom IP. The experimental flow uses
#	flow/fpga/ddr4_custom/vcu118_ddr4_c1_custom_2133.xdc for PACKAGE_PIN constraints.
if {$custom_2133} {
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_isCustom     true
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_TimePeriod   938
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_MemoryPart   MT40A256M16GE-083E
	set_config_checked $ddr4_ip CONFIG.System_Clock         Differential
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_MemoryType   Components
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_DataWidth    64
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_Ecc          false
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_AxiSelection true
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_AxiDataWidth 512
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_AxiAddressWidth 31
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_AxiIDWidth   4
	set_config_checked $ddr4_ip CONFIG.C0.DDR4_Mem_Add_Map  ROW_COLUMN_BANK
} else {
	if {[catch {
		set_property -dict [list \
			CONFIG.C0_CLOCK_BOARD_INTERFACE {default_250mhz_clk1} \
			CONFIG.C0_DDR4_BOARD_INTERFACE  {ddr4_sdram_c1} \
			CONFIG.RESET_BOARD_INTERFACE    {reset} \
		] [get_ips ddr4_0]
	} bierr]} {
		puts "mig_vcu118: WARNING board-interface config failed: $bierr"
	}
}

#	Partial stores reach DDR through AXI WSTRB, so the physical DDR4 interface
#	must expose data-mask pins. Keep this explicit even though the VCU118 board
#	preset currently resolves to DM_NO_DBI on its own.
set_config_checked $ddr4_ip CONFIG.C0.DDR4_DataMask DM_NO_DBI

#	Enable the AXI4 user interface. This VCU118 config resolves to 512-bit AXI
#	even if a 64-bit data width is requested, so the external data-width
#	converter below is required. Separate call so a miss here does not roll back
#	the board automation above.
if {!$custom_2133} {
	if {[catch {
		set_property -dict [list \
			CONFIG.C0.DDR4_AxiSelection {true} \
			CONFIG.C0.DDR4_AxiDataWidth {64} \
			CONFIG.C0.DDR4_AxiIDWidth   {4} \
		] [get_ips ddr4_0]
	} axierr]} {
		puts "mig_vcu118: WARNING AXI config failed: $axierr"
	}
}

#	The wrapper strips the 0x8000_0000 DRAM base before the converter, so both
#	AXI helper IPs use the MIG's 31-bit offset address width.
set_property -dict [list \
	CONFIG.PROTOCOL        {AXI4} \
	CONFIG.ADDR_WIDTH      {31} \
	CONFIG.ID_WIDTH        {4} \
	CONFIG.DATA_WIDTH      {64} \
] [get_ips axi_clock_converter_0]

set_property -dict [list \
	CONFIG.PROTOCOL        {AXI4} \
	CONFIG.READ_WRITE_MODE {READ_WRITE} \
	CONFIG.ACLK_ASYNC      {0} \
	CONFIG.ADDR_WIDTH      {31} \
	CONFIG.SI_ID_WIDTH     {4} \
	CONFIG.SI_DATA_WIDTH   {64} \
	CONFIG.MI_DATA_WIDTH   {512} \
] [get_ips axi_dwidth_converter_0]

#	vio_0/jtag_axi_0 are the DDR4-debug scaffold (CPU-hold + JTAG-AXI host loader),
#	generated ONLY under KARU_DDR_HOST_DBG (default builds boot automatically and
#	never create or read these IPs). probe_in0[7:0] = calib/reset/trap/hold status;
#	probe_in1[15:0] = the eth PCS status_vector (SGMII build; 0 otherwise).
#	C_PROBE_OUT0_INIT_VAL {0x1} = host_cpu_hold=1 at config.
if {$host_dbg} {
set_property -dict [list \
	CONFIG.C_NUM_PROBE_IN       {2} \
	CONFIG.C_PROBE_IN0_WIDTH    {8} \
	CONFIG.C_PROBE_IN1_WIDTH    {16} \
	CONFIG.C_NUM_PROBE_OUT      {1} \
	CONFIG.C_PROBE_OUT0_WIDTH   {2} \
	CONFIG.C_PROBE_OUT0_INIT_VAL {0x1} \
] [get_ips vio_0]

set_property -dict [list \
	CONFIG.M_AXI_ADDR_WIDTH {32} \
	CONFIG.M_AXI_DATA_WIDTH {32} \
	CONFIG.M_AXI_ID_WIDTH   {1} \
	CONFIG.M_HAS_BURST      {1} \
] [get_ips jtag_axi_0]
}

set gen_ips [list ddr4_0 axi_clock_converter_0 axi_dwidth_converter_0]
if {$host_dbg} { lappend gen_ips vio_0 jtag_axi_0 }
if {[catch {generate_target all [get_ips $gen_ips]} generr]} {
	puts "mig_vcu118: ERROR generate_target failed: $generr"
	return
}

#	Report the resolved config so we can confirm it is VCU118-correct.
foreach k {C0.DDR4_MemoryPart C0.DDR4_TimePeriod C0.DDR4_InputClockPeriod \
		   C0.DDR4_isCustom C0.DDR4_DataMask C0.DDR4_AxiSelection C0.DDR4_AxiDataWidth \
		   C0.DDR4_AxiAddressWidth C0.DDR4_UI_CLOCK} {
	puts "mig_vcu118: CONFIG.$k = [get_property CONFIG.$k [get_ips ddr4_0]]"
}
foreach k {C0.DDR4_DM_WIDTH C0.DDR4_USE_DM_PORT} {
	set got [get_property CONFIG.$k [get_ips ddr4_0]]
	puts "mig_vcu118: CONFIG.$k = $got"
	if {($k eq "C0.DDR4_DM_WIDTH" && $got ne "8") ||
		($k eq "C0.DDR4_USE_DM_PORT" && $got ne "1")} {
		puts "mig_vcu118: ERROR expected CONFIG.$k to confirm enabled 8-bit DM"
		exit 1
	}
}
foreach k {PROTOCOL READ_WRITE_MODE ACLK_ASYNC ADDR_WIDTH SI_ID_WIDTH \
		   SI_DATA_WIDTH MI_DATA_WIDTH} {
	puts "mig_vcu118: DWC CONFIG.$k = [get_property CONFIG.$k [get_ips axi_dwidth_converter_0]]"
}
foreach k {PROTOCOL ADDR_WIDTH ID_WIDTH DATA_WIDTH} {
	puts "mig_vcu118: CDC CONFIG.$k = [get_property CONFIG.$k [get_ips axi_clock_converter_0]]"
}
if {$host_dbg} {
	foreach k {C_PROBE_IN0_WIDTH C_PROBE_OUT0_WIDTH C_PROBE_OUT0_INIT_VAL} {
		puts "mig_vcu118: VIO CONFIG.$k = [get_property CONFIG.$k [get_ips vio_0]]"
	}
	foreach k {M_AXI_ADDR_WIDTH M_AXI_DATA_WIDTH M_AXI_ID_WIDTH M_HAS_BURST} {
		puts "mig_vcu118: JTAG_AXI CONFIG.$k = [get_property CONFIG.$k [get_ips jtag_axi_0]]"
	}
	puts "mig_vcu118: generated ddr4_0, axi_clock_converter_0, axi_dwidth_converter_0, vio_0 and jtag_axi_0 under $ipdir"
} else {
	puts "mig_vcu118: generated ddr4_0, axi_clock_converter_0, axi_dwidth_converter_0 under $ipdir (debug scaffold off)"
}
