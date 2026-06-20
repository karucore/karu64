//	fpga_ddr_sim.cpp
//	===	Verilator harness for the DDR4/MIG-bridge testbench (flow/fpga/fpga_ddr_tb.v).
//	Toggles the clock until the testbench $finish-es.

#include <verilated.h>
#include "Vfpga_ddr_tb.h"

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);

	Vfpga_ddr_tb *dut = new Vfpga_ddr_tb;

	while (!Verilated::gotFinish()) {
		dut->clk = !dut->clk;
		dut->eval();
	}

	dut->final();
	delete dut;
	return 0;
}
