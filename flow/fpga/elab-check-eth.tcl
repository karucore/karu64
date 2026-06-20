#	elab-check-eth.tcl
#	=== fast Vivado RTL-elaboration check for the Ethernet PHY front-end (E3 slice 1).
#	Elaborates karu_eth_phy_fe -- the DP83867 MDIO management front-end (the sim-
#	validated karu_dp83867_mdio init FSM + post-reset auto-start + MDIO IOBUF) as
#	instantiated in vcu118_ddr_top under `ifdef KARU_ETH_PHY. This is IP-free (no
#	generated MIG/VIO/converter black boxes), so it is a quick stricter-than-iverilog
#	check. Run through Makefile:
#	    make elab-eth
#
#	SCOPE: this is a FRONT-END-ONLY check -- it does NOT elaborate vcu118_ddr_top, so
#	it does not catch mistakes in the `ifdef KARU_ETH_PHY top ports / instance. That
#	top-level integration (and timing) is covered by the real synth build,
#	`make vcu118_ddr.bit KARU_DEFINES="... KARU_ETH_PHY"`. The LiteEth MAC datapath
#	(karu_eth + liteeth_core) is elaborated by `make elab-ddr`. The SGMII PCS/PMA
#	datapath is a later slice (not yet instantiated).

source [file join [file dirname [file normalize [info script]]] vivado_paths.tcl]

read_verilog [karu_repo_path flow fpga eth karu_dp83867_mdio.v]
read_verilog [karu_repo_path flow fpga eth karu_eth_phy_fe.v]

synth_design -rtl -part xcvu9p-flga2104-2L-e -top karu_eth_phy_fe

puts "ELAB-CHECK-ETH: karu_eth_phy_fe RTL elaboration completed"
