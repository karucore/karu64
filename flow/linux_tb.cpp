//	linux_tb.cpp -- Verilator main for flow/fpga/linux_tb.sv (karu64 Linux boot).
//
//	Two build flavours of the same file:
//	  - default (`make linux-sim`): plain clock-toggle loop, interactive UART.
//	  - `-DLINUX_TRACE` (`make linux-trace`, built `--savable --trace`): adds a
//	    checkpoint/restore + windowed-VCD harness so the expensive boot runs ONCE
//	    and the userspace transition can be re-analysed in seconds. Plusargs:
//	      +save_at=<cyc> +save_file=<f>     write a checkpoint at cycle <cyc>
//	      +restore=<f> +restore_at=<cyc>    restore and resume at <cyc>
//	      +trace_file=<f> +trace_from=<a> +trace_to=<b>   VCD over cycles [a,b]
//	    A checkpoint is bound to THIS binary; rebuilding invalidates it, so the
//	    full-VCD capture is comprehensive (look at any signal offline, no re-run).

#include <verilated.h>
#include "Vlinux_tb.h"

#include <poll.h>
#include <unistd.h>
#include <cstring>

extern "C" int linux_uart_getchar()
{
	struct pollfd pfd;
	pfd.fd = STDIN_FILENO;
	pfd.events = POLLIN;
	pfd.revents = 0;

	if (poll(&pfd, 1, 0) <= 0)
		return -1;

	unsigned char ch;
	if (read(STDIN_FILENO, &ch, 1) != 1)
		return -1;
	return ch;
}

#ifdef LINUX_TRACE
#include <verilated_save.h>
#include <verilated_vcd_c.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>

static const char *plusval(int argc, char **argv, const char *key)
{
	size_t kl = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, kl))
			return argv[i] + kl;
	return nullptr;
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	Vlinux_tb *tb = new Vlinux_tb;

	const char *p;
	uint64_t save_at = 0;               const char *save_file = nullptr;
	const char *restore_file = nullptr; uint64_t restore_at = 0;
	const char *trace_file = nullptr;
	uint64_t trace_from = 0, trace_to = ~0ULL;

	if ((p = plusval(argc, argv, "+save_at=")))    save_at = strtoull(p, 0, 0);
	if ((p = plusval(argc, argv, "+save_file=")))  save_file = p;
	if ((p = plusval(argc, argv, "+restore=")))    restore_file = p;
	if ((p = plusval(argc, argv, "+restore_at="))) restore_at = strtoull(p, 0, 0);
	if ((p = plusval(argc, argv, "+trace_file="))) trace_file = p;
	if ((p = plusval(argc, argv, "+trace_from="))) trace_from = strtoull(p, 0, 0);
	if ((p = plusval(argc, argv, "+trace_to=")))   trace_to = strtoull(p, 0, 0);

	uint64_t cyc = 0;
	VerilatedVcdC *tfp = nullptr;
	vluint64_t t = 0;

	if (restore_file) {
		VerilatedRestore is;
		is.open(restore_file);
		is >> *tb;
		is.close();
		cyc = restore_at;
		fprintf(stderr, "[linux_tb] restored %s, resume cyc=%llu\n",
			restore_file, (unsigned long long)cyc);
	}
	if (trace_file) {
		Verilated::traceEverOn(true);
		tfp = new VerilatedVcdC;
		tb->trace(tfp, 99);
		tfp->open(trace_file);
		fprintf(stderr, "[linux_tb] VCD %s over cyc [%llu,%llu]\n",
			trace_file, (unsigned long long)trace_from,
			(unsigned long long)trace_to);
	}

	bool saved = false;
	tb->clk = 0;
	while (!Verilated::gotFinish()) {
		tb->clk = !tb->clk;
		tb->eval();
		if (tfp && cyc >= trace_from && cyc <= trace_to)
			tfp->dump(t);
		t++;
		if (tb->clk) {				//	posedge => one cycle elapsed
			cyc++;
			if (save_file && !saved && cyc >= save_at) {
				VerilatedSave os;
				os.open(save_file);
				os << *tb;
				os.close();
				saved = true;
				fprintf(stderr, "[linux_tb] checkpoint saved to %s at cyc=%llu\n",
					save_file, (unsigned long long)cyc);
			}
		}
	}
	if (tfp) { tfp->close(); delete tfp; }
	tb->final();
	delete tb;
	return 0;
}

#else	/* plain (fast) build -- make linux-sim */

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);

	//	+require_exit: fail (return non-zero) if the run ends WITHOUT the firmware
	//	signalling a result via SIM_EXIT_ADDR (i.e. it trapped/timed out/hung).
	//	Tests (eth-sim) pass it; interactive sims (linux-sim) don't, so they keep
	//	returning 0 on a max-cycles end.
	bool require_exit = false;
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], "+require_exit", 12))
			require_exit = true;

	Vlinux_tb *tb = new Vlinux_tb;
	tb->clk = 0;

	while (!Verilated::gotFinish()) {
		tb->clk = !tb->clk;
		tb->eval();
	}

	int rc = tb->sim_exit_valid ? (int)tb->sim_exit_code
								: (require_exit ? 2 : 0);
	tb->final();
	delete tb;
	return rc;
}

#endif
