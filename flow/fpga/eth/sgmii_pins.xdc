#	sgmii_pins.xdc
#	=== VCU118 SGMII data + reference-clock pin constraints for the SelectIO/LVDS
#	gig_ethernet_pcs_pma datapath (E3 slice D1). Pins from the VCU118 board file
#	(part0_pins.xml) + UG1224. These constrain the vcu118_ddr_top SGMII ports (named
#	eth_sgmii_*); they go live in the datapath build once those ports + the PCS/PMA IP
#	are wired (slice D2/D3) -- NOT read by any build yet.
#
#	CLOCK: the gig_ethernet_pcs_pma IP constrains this 625 MHz input itself -- its
#	create_clock on refclk625_p propagates to this top primary input (CONFIRMED by the
#	synth-only report_clocks: a 1.600 ns clock on eth_sgmii_clk_p, with the PCS-derived
#	125 MHz GMII / 312.5 / 156.25 MHz clocks below it). So we do NOT create_clock here:
#	a duplicate just "completely overrides" the IP's (CRITICAL WARNING). SGMIICLK is the
#	DP83867's 625 MHz SGMII clock output (UG1224: FPGA AT22 = U7 PHY1_SGMIICLK_P/AU22=_N).

#	--- SGMII reference clock + serial data (diff pairs) -- both halves, LVDS ---
#	Matches the known-good VCU118 SGMII reference (alexforencich/verilog-ethernet
#	example/VCU118/fpga_1g/fpga.xdc): SAME pins, IOSTANDARD LVDS on BOTH _P and _N of each
#	pair. The RX/TX bitslice nibble + diff-pair mapping is NOT set with pin LOCs -- it is a
#	PCS/PMA IP parameter (flow/fpga/eth/gen_pcspma.tcl: TxLane0_Placement=DIFF_PAIR_2,
#	RxLane0_Placement=DIFF_PAIR_0, Tx_In_Upper_Nibble=0, per AMD PG047 Lane Placement).
#	Those params are what the earlier 146-unroutable-RIU route was missing: the IP default
#	Tx_In_Upper_Nibble=1 placed TX in the wrong nibble for these board-fixed pins (our DCP
#	forensic showed TX actually in the LOWER nibble). create_clock stays with the IP.
#	DIFF_TERM_ADV TERM_100 = on-die 100-ohm differential termination on the INPUT pairs
#	(625 MHz SGMIICLK refclk + SGMII RX data; NOT the TX output pair, which is an output).
#	Matches fpganinja/taxi's VCU118 design. NOTE (2026-06-15): the on-wire bring-up proved
#	the SGMII link comes up + frames cross cleanly (host rx_crc_errors=0) WITHOUT this
#	termination -- the MDIO Taxi-init (SGMIICTL1=0x4000) was the actual fix. That no-term
#	isolation PROOF bit is banked at _build/imac_sgmii_taxi_LINKED.bit. TERM_100 is kept here
#	as signal-integrity MARGIN for the production build (cleaner eye on the 625 MHz refclk +
#	RX data); it is now the standard SGMII pin config.
set_property -dict { PACKAGE_PIN AT22  IOSTANDARD LVDS  DIFF_TERM_ADV TERM_100 } [get_ports { eth_sgmii_clk_p }]
set_property -dict { PACKAGE_PIN AU22  IOSTANDARD LVDS  DIFF_TERM_ADV TERM_100 } [get_ports { eth_sgmii_clk_n }]
set_property -dict { PACKAGE_PIN AU21  IOSTANDARD LVDS } [get_ports { eth_sgmii_txp }]
set_property -dict { PACKAGE_PIN AV21  IOSTANDARD LVDS } [get_ports { eth_sgmii_txn }]
set_property -dict { PACKAGE_PIN AU24  IOSTANDARD LVDS  DIFF_TERM_ADV TERM_100 } [get_ports { eth_sgmii_rxp }]
set_property -dict { PACKAGE_PIN AV24  IOSTANDARD LVDS  DIFF_TERM_ADV TERM_100 } [get_ports { eth_sgmii_rxn }]

#	--- async clock-domain crossing: PCS (SGMII) domain vs core/MIG domain ---
#	The DP83867 SGMII PCS domain -- all clocks generated from the 625 MHz eth_sgmii_clk_p
#	(the 125 MHz GMII + the PCS AN/RUDI/RX-disparity internal clocks) -- is ASYNCHRONOUS to
#	the core/MIG domain off c0_sys_clk_p (the MIG MMCM clocks, ui_clk, and the divided
#	cpu_clk). The only crossings are LiteEth's own sys<->GMII async FIFOs
#	(liteeth_gmii_cdc.xdc, scoped to liteeth_core) and the top-level 2-FF status_vector
#	synchronizer into ui_clk (eth_st_s0/s1, ASYNC_REG) -- both async-safe. Without this the
#	tool TIMES those crossings: the post-route IntTx_ClkOut1 -> mmcm_clkout0 -2.7 ns paths
#	were ALL the status sync's eth_st_s0_reg[*]/D first stage (PCS RUDI/AN flops -> ui_clk).
set_clock_groups -asynchronous \
	-group [get_clocks -include_generated_clocks eth_sgmii_clk_p] \
	-group [get_clocks -include_generated_clocks c0_sys_clk_p]
