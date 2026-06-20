//	sim_tb.cpp
//	===	Verilator harness for the HTIF karu64 testbench.
//	Same shape as the other sim_tb_*.cpp; just instantiates Vhtif_tb.

#include <verilated.h>
#include "Vhtif_tb.h"

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);

	Vhtif_tb *dut = new Vhtif_tb;

	while (!Verilated::gotFinish()) {
		dut->clk = !dut->clk;
		dut->eval();
	}

	dut->final();
	delete dut;
	return 0;
}
