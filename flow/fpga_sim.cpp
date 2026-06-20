//	fpga_sim.cpp
//	===	Verilator harness for the fpga_top testbench (flow/fpga/fpga_tb.v).
//	Toggles the clock until the testbench $finish-es.

#include <verilated.h>
#include "Vfpga_tb.h"

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);

	Vfpga_tb *dut = new Vfpga_tb;

	while (!Verilated::gotFinish()) {
		dut->clk = !dut->clk;
		dut->eval();
	}

	dut->final();
	delete dut;
	return 0;
}
