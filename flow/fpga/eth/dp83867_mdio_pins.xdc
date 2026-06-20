#	dp83867_mdio_pins.xdc
#	=== VCU118 DP83867 (DP83867ISRGZ) management-interface pin constraints. ===
#	The MDIO/MDC management bus drives karu_dp83867_mdio (the SGMII-init FSM).
#	Pin/standard from AMD UG1224 (VCU118 board). PHY MDIO address is 00011 (=3),
#	already the default of karu_dp83867_mdio's PHYAD parameter.
#
#	SCOPE: this fragment covers ONLY the DP83867 MANAGEMENT pins (MDIO/MDC + the
#	RESET_N/INT control pins). The SGMII data + reference-clock pins moved to
#	flow/fpga/eth/sgmii_pins.xdc (slice D1).
#
#	STATUS (2026-06-15): LIVE. The DP83867 MDIO management front-end IS instantiated in
#	vcu118_ddr_top under `ifdef KARU_ETH_PHY (karu_eth_phy_fe = karu_dp83867_mdio FSM +
#	the MDIO IOBUF); this fragment IS read by flow/fpga/xcvu9p-ddr-synth.tcl when KARU_ETH_PHY
#	is set; and the MDIO path is HW-VALIDATED on the VCU118 (id_ok/LED0 -> PHYIDR1
#	0x2000; see doc/fpga.md).

#	--- MDIO management bus (UG1224: MDIO=AR23, MDC=AV23, LVCMOS18) ---
set_property -dict { PACKAGE_PIN AR23  IOSTANDARD LVCMOS18 } [get_ports { eth_mdio }]
set_property -dict { PACKAGE_PIN AV23  IOSTANDARD LVCMOS18 } [get_ports { eth_mdc  }]

#	--- PHY hardware reset (active-low RESET_N) -- UG1224 PHY1_RESET_B = BA21 ---
set_property -dict { PACKAGE_PIN BA21  IOSTANDARD LVCMOS18 } [get_ports { eth_phy_reset_n }]

#	--- PHY interrupt / power-down (UG1224 PHY1_PDWN_B_I/INT_B_O = AR24) ---
#	DOCUMENTED, NOT ACTIVE: left commented because there is no `eth_phy_int_n` port
#	yet. This pin is the DP83867's dual open-drain INT output / PDWN strap input.
#	When wired, drive it as an INPUT held high-Z (external pull-up) for interrupts,
#	unless the dual INT/PWDN power-down behaviour is intentionally used.
#	set_property -dict { PACKAGE_PIN AR24  IOSTANDARD LVCMOS18 } [get_ports { eth_phy_int_n }]

#	--- SGMII data lanes + reference clock ---
#	MOVED to flow/fpga/eth/sgmii_pins.xdc (E3 slice D1, 2026-06-15). SelectIO/LVDS confirmed;
#	SGMIICLK = the DP83867's 625 MHz output (UG1224 AT22 = U7 PHY1_SGMIICLK_P), so the
#	gig_ethernet_pcs_pma IP is generated at LvdsRefClk=625 and its port model exposes
#	refclk625_p/n (the IP's _clocks.xdc owns the 625 MHz create_clock). This fragment
#	now keeps ONLY the DP83867 management pins (MDIO/MDC/RESET_B, above).
