#	vcu118_ddr.xdc
#	Board GPIO constraints for vcu118_ddr_top. The DDR4 IP supplies the DDR4
#	ref-clock and PHY constraints from its generated XDC.

#	reset signal -- asynchronous push-buttons (btn_rst_i, btn_i[4]=centre)
set_false_path -from [get_ports { btn_rst_i } ]
set_false_path -from [get_ports { btn_i[4] } ]
set_false_path -to [get_pins -quiet {u_rst/sync0_reg/D u_ui_axi_rst/sync0_reg/D}]
#	rst_ui_sync/trap_ui_sync are the VIO status-CDC flops -- only present under
#	KARU_DDR_HOST_DBG. -quiet makes this a harmless no-op in default builds.
set_false_path -to [get_pins -quiet {rst_ui_sync_reg[0]/D trap_ui_sync_reg[0]/D}]

## CPU reset pushbutton (active-High)
set_property -dict { PACKAGE_PIN L19 IOSTANDARD LVCMOS12 } [get_ports { btn_rst_i } ]

## Directional pushbuttons (Active-High)
set_property -dict { PACKAGE_PIN BB24 IOSTANDARD LVCMOS18 } [get_ports { btn_i[0] } ]
set_property -dict { PACKAGE_PIN BE23 IOSTANDARD LVCMOS18 } [get_ports { btn_i[1] } ]
set_property -dict { PACKAGE_PIN BF22 IOSTANDARD LVCMOS18 } [get_ports { btn_i[2] } ]
set_property -dict { PACKAGE_PIN BE22 IOSTANDARD LVCMOS18 } [get_ports { btn_i[3] } ]
set_property -dict { PACKAGE_PIN BD23 IOSTANDARD LVCMOS18 } [get_ports { btn_i[4] } ]

## CP2105GM USB UART
set_property -dict { PACKAGE_PIN AW25 IOSTANDARD LVCMOS18 } [get_ports { usb_uart_rxd_i } ]
set_property -dict { PACKAGE_PIN BB21 IOSTANDARD LVCMOS18 } [get_ports { usb_uart_txd_o } ]
set_property -dict { PACKAGE_PIN AY25 IOSTANDARD LVCMOS18 } [get_ports { usb_uart_cts_i } ]
set_property -dict { PACKAGE_PIN BB22 IOSTANDARD LVCMOS18 } [get_ports { usb_uart_rts_o } ]

## "GPIO" LEDs
set_property -dict { PACKAGE_PIN AT32 IOSTANDARD LVCMOS12 } [get_ports { led_o[0] } ]
set_property -dict { PACKAGE_PIN AV34 IOSTANDARD LVCMOS12 } [get_ports { led_o[1] } ]
set_property -dict { PACKAGE_PIN AY30 IOSTANDARD LVCMOS12 } [get_ports { led_o[2] } ]
set_property -dict { PACKAGE_PIN BB32 IOSTANDARD LVCMOS12 } [get_ports { led_o[3] } ]
set_property -dict { PACKAGE_PIN BF32 IOSTANDARD LVCMOS12 } [get_ports { led_o[4] } ]
set_property -dict { PACKAGE_PIN AU37 IOSTANDARD LVCMOS12 } [get_ports { led_o[5] } ]
set_property -dict { PACKAGE_PIN AV36 IOSTANDARD LVCMOS12 } [get_ports { led_o[6] } ]
set_property -dict { PACKAGE_PIN BA37 IOSTANDARD LVCMOS12 } [get_ports { led_o[7] } ]
