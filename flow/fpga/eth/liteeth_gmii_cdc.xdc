#	liteeth_gmii_cdc.xdc
#	=== Adapted LiteEth GMII clock-domain-crossing constraints for the SGMII datapath.
#	Copied from the generated liteeth_core_gmii.xdc but with the `create_clock` on
#	eth_rx_clk / eth_tx_clk REMOVED: those GMII clocks are driven by the PCS/PMA
#	clk125_out (already a clock derived from the 625 MHz refclk), so re-creating them
#	here would double-define the clock. We keep ONLY the LiteEth CDC the integrated
#	build still needs: the sys<->eth asynchronous clock groups and the multireg /
#	async-reset false-paths.
#
#	Read SCOPED to the eth MAC instance in flow/fpga/xcvu9p-ddr-synth.tcl:
#	    read_xdc -ref liteeth_core flow/fpga/eth/liteeth_gmii_cdc.xdc
#	so the get_nets (sys_clk / eth_rx_clk / eth_tx_clk) resolve inside liteeth_core; the
#	clocks-of those nets are cpu_clk (sys) and clk125 (eth, from the PCS), made async.

set_false_path -quiet -to [get_nets -filter {mr_ff == TRUE}]
set_false_path -quiet -to [get_pins -filter {REF_PIN_NAME == PRE} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE || ars_ff2 == TRUE}]]
set_max_delay 2 -quiet -from [get_pins -filter {REF_PIN_NAME == C} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE}]] -to [get_pins -filter {REF_PIN_NAME == D} -of_objects [get_cells -hierarchical -filter {ars_ff2 == TRUE}]]

#	sys (cpu_clk) <-> the PCS-driven GMII clk125 is a real async crossing (LiteEth's
#	own sys<->eth CDC FIFOs). NOTE: in this SGMII build eth_rx_clk and eth_tx_clk are the
#	SAME clock -- both LiteEthPHYGMII GMII clocks come from the single PCS clk125_out
#	(clock_pads.rx) -- so lines 19/20 are the same sys<->clk125 grouping (redundant but
#	harmless), and the generated rx<->tx async group is DROPPED: it would place
#	u_pcs/clk125_out in two groups of one constraint ("Clock specified in more than one
#	group: u_pcs/clk125_out"). Restore it only if rx/tx ever become distinct clocks.
set_clock_groups -group [get_clocks -of [get_nets sys_clk]] -group [get_clocks -of [get_nets eth_rx_clk]] -asynchronous
set_clock_groups -group [get_clocks -of [get_nets sys_clk]] -group [get_clocks -of [get_nets eth_tx_clk]] -asynchronous
