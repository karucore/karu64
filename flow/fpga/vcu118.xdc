#	vcu118.xdc
#	Markku-Juhani O. Saarinen <mjos@iki.fi>. See LICENSE.
#	extracted from various sources

#	Board input clock: 125 MHz user clock CLK_125MHZ (bank 64, LVDS,
#	pins AY24/AY23), period 8 ns. vcu118_top currently divides this by 2 for
#	the core clock. Verified against UG1224 + master XDC.
create_clock -period 8.000 -name clk_125mhz [get_ports { clk_125mhz_p } ]

# reset signal -- asynchronous push-buttons (btn_rst_i, btn_i[4]=centre)
set_false_path -from [get_ports { btn_rst_i } ]
set_false_path -from [get_ports { btn_i[4] } ]

##	clock sources

#	125 MHz user clock (CLK_125MHZ_P/N, bank 64) -- the one we use
set_property -dict { PACKAGE_PIN AY24 IOSTANDARD LVDS } [get_ports { clk_125mhz_p } ]
set_property -dict { PACKAGE_PIN AY23 IOSTANDARD LVDS } [get_ports { clk_125mhz_n } ]

#	Alternatives (NOT used here):
#	  250 MHz DDR4 ref clock  c0_sys_clk  E12/D12  IOSTANDARD DIFF_SSTL12
#	  300 MHz SYSCLK1         G31/F31              IOSTANDARD DIFF_SSTL12
#	Both are DIFF_SSTL12 (not LVDS) and would need a matching IBUFDS +
#	(for a lower core target) an MMCM to divide down.



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

## Switches
#set_property -dict { PACKAGE_PIN B17 IOSTANDARD LVCMOS12 } [get_ports { switch0_i } ]
#set_property -dict { PACKAGE_PIN G16 IOSTANDARD LVCMOS12 } [get_ports { switch1_i } ]
#set_property -dict { PACKAGE_PIN J16 IOSTANDARD LVCMOS12 } [get_ports { switch2_i } ]
#set_property -dict { PACKAGE_PIN D21 IOSTANDARD LVCMOS12 } [get_ports { switch3_i } ]

## I2C Bus
#set_property -dict { PACKAGE_PIN J10 IOSTANDARD LVCMOS33 } [get_ports { pad_i2c0_scl } ]
#set_property -dict { PACKAGE_PIN J11 IOSTANDARD LVCMOS33 } [get_ports { pad_i2c0_sda } ]

## HDMI CTL
#set_property -dict { PACKAGE_PIN F15 IOSTANDARD LVCMOS33 } [get_ports { pad_hdmi_scl } ]
#set_property -dict { PACKAGE_PIN F16 IOSTANDARD LVCMOS33 } [get_ports { pad_hdmi_sda } ]

#LED
#set_property PACKAGE_PIN AG14 [get_ports { LED } ]
#set_property IOSTANDARD LVCMOS33 [get_ports { LED } ]
