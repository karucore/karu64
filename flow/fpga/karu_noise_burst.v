//	karu_noise_burst.v
//	=== Burst capture of the raw noise source, for its characterisation.
//
//	The GetNoise interface of the entropy block (mnoise) hands raw symbols to
//	software one at a time, which is too slow to see the rings sampled close
//	together. This block sets the sampling period of the noise source, 1 to
//	256 clock cycles, and records a burst of consecutive raw symbols at that
//	period in a block RAM, to be read at leisure. It is an FPGA measurement
//	aid next to rtl/karu_entropy.v, not part of the entropy source: an ASIC
//	leaves it out and ties the noise source's period to its fixed value.
//
//	Everything here belongs to the test mode of the entropy block:
//
//	  * While noise_test (mnoise) is clear, or mentropycfg is locked, this
//	    block does nothing and holds nothing. The sampling period is the
//	    build's value, a capture cannot be started, the period register and
//	    the status are at their reset values, and the data register reads
//	    zero. So seed, the health tests and the authentication ROM see the
//	    noise source exactly as without this block.
//	  * In test mode seed is in BIST and delivers nothing, so no recorded
//	    symbol is ever also delivered as entropy. Leaving test mode restarts
//	    the entropy block's start-up test and ends access to the recording.
//	    The RAM is not wiped, but its contents are unreachable: reading needs
//	    a completed capture, which is forgotten when test mode ends, and a
//	    new capture overwrites every word before it completes.
//
//	Test mode can only be entered from M-mode (or Debug Mode), through
//	mnoise. The registers themselves have no such protection: on the VCU118
//	SoC they are in the system-control block, which S-mode can reach.
//
//	Registers (reg_*addr_i, 64 bits each):
//
//	  0  status / control
//	       write [0]   start a capture (ignored unless capturing is allowed
//	                   and none is running); forgets the previous recording
//	       read  [0]   capturing
//	             [1]   done: a complete burst is held and can be read
//	             [2]   capturing is allowed: test mode on, mentropycfg unlocked
//	             [3]   mentropycfg is locked
//	             [4]   the noise source is enabled (off: strap, or a dead source)
//	             [5]   test mode is on
//	             [6]   aborted: the last capture was stopped because the noise
//	                   source was off while it ran; nothing is held
//	             [15:8]  log2 of the symbols per burst
//	             [31:16] words of the running capture already written
//	             [63:32] 0x4b4e4231, "KNB1": this block is present
//	  1  period: [7:0] clock cycles per raw symbol, less one. Written only
//	     while capturing is allowed and no capture runs. It applies to the
//	     noise source for as long as capturing is allowed, to mnoise as well.
//	     An accepted write ends a run of mnoise symbols (respace_o): the
//	     symbols on either side of it are not the same distance apart.
//	  2  index: [LOG2_WORDS-1:0] the word that the data register returns next
//	  3  data: word `index` of the recording, then index + 1. Sixteen symbols
//	     per word in the order they were sampled, the first in bits [3:0];
//	     lane i of a symbol in its bit i, as everywhere. Zero unless done.
//
//	A capture starts with the first symbol after the start bit is written and
//	takes 2^(LOG2_WORDS+4) consecutive symbols: no symbol of the source
//	between the first and the last is left out, whatever the period. Done
//	appears one cycle after the last word went into the RAM, so that the
//	word at the index is the new one in the very cycle done is first seen.
//
//	A capture runs only while the noise source is enabled. If the source is
//	off in any cycle of a capture, including the cycle of the start and the
//	wait for the first symbol, the capture is aborted: it stops, holds
//	nothing, and the status says so. When the source is switched on again
//	its rings and divider restart, and symbols on either side of the gap are
//	not consecutive samples, so such a burst must never be reported done.
//
//	reg_re_i marks the cycle in which a read of reg_raddr_i is taken;
//	reg_rdata_o is combinational from reg_raddr_i and registers only.
//	SPDX-License-Identifier: BSD-2-Clause

module karu_noise_burst #(
	parameter integer LOG2_WORDS = 11,			//	2^11 words: 32768 symbols, four 36 Kb block RAMs
	parameter [7:0]   DIV_RESET  = 8'd255		//	the build's period, less one
) (
	input  wire			clk,
	input  wire			rst,

	//	entropy block and noise source
	input  wire			test_i,					//	noise_test is set: seed is in BIST
	input  wire			lock_i,					//	mentropycfg is locked
	input  wire			rng_en_i,
	input  wire			rng_val_i,
	input  wire [3:0]	rng_b_i,
	output wire [7:0]	div_o,					//	to the noise source: clk cycles per symbol, less one
	output wire			respace_o,				//	to the entropy block: the period is written in this cycle

	//	register port
	input  wire			reg_re_i,
	input  wire [2:0]	reg_raddr_i,
	output wire [63:0]	reg_rdata_o,
	input  wire			reg_we_i,
	input  wire [2:0]	reg_waddr_i,
	input  wire [63:0]	reg_wdata_i
);
	localparam [2:0] R_CTRL = 3'd0, R_PERIOD = 3'd1, R_INDEX = 3'd2, R_DATA = 3'd3;
	localparam [31:0] MAGIC = 32'h4b4e_4231;
	localparam integer AW = LOG2_WORDS;
	localparam integer LOG2_SYMBOLS = LOG2_WORDS + 4;

	wire allow = test_i && !lock_i;

	reg			busy_q, done_q, fin_q;			//	fin: the last word is being written
	reg			brk_q;							//	the last capture was aborted
	reg [7:0]	div_q;
	reg [AW+3:0] cnt_q;							//	symbols of the running capture taken so far
	reg [59:0]	part_q;							//	the first fifteen symbols of a word
	reg [AW-1:0] idx_q;

	wire start   = allow && reg_we_i && reg_waddr_i == R_CTRL && reg_wdata_i[0] && !busy_q;
	wire take    = allow && busy_q && !fin_q && rng_val_i;
	wire word_we = take && (&cnt_q[3:0]);
	wire last    = take && (&cnt_q);
	wire brk     = allow && busy_q && !fin_q && !rng_en_i;		//	source off during a capture
	wire period_we = allow && reg_we_i && reg_waddr_i == R_PERIOD && !busy_q;
	wire pop     = allow && done_q && reg_re_i && reg_raddr_i == R_DATA;
	wire idx_we  = allow && reg_we_i && reg_waddr_i == R_INDEX;
	wire [AW-1:0] idx_n = idx_we ? reg_wdata_i[AW-1:0] : pop ? idx_q + 1'b1 : idx_q;

	always @(posedge clk)
		if (rst || !allow) begin
			busy_q <= 1'b0; done_q <= 1'b0; fin_q <= 1'b0; brk_q <= 1'b0; div_q <= DIV_RESET;
			cnt_q <= {(AW+4){1'b0}}; part_q <= 60'b0; idx_q <= {AW{1'b0}};
		end else begin
			if (period_we)
				div_q <= reg_wdata_i[7:0];
			if (start) begin					//	a start with the source off is an abort at once
				busy_q <= rng_en_i; done_q <= 1'b0; brk_q <= !rng_en_i; cnt_q <= {(AW+4){1'b0}};
			end
			if (take) begin
				cnt_q  <= cnt_q + 1'b1;
				part_q <= {rng_b_i, part_q[59:4]};
			end
			fin_q <= last && !brk;
			if (fin_q) begin
				busy_q <= 1'b0; done_q <= 1'b1;
			end
			if (brk) begin						//	wins over a symbol taken in the same cycle
				busy_q <= 1'b0; brk_q <= 1'b1; cnt_q <= {(AW+4){1'b0}}; part_q <= 60'b0;
			end
			idx_q <= idx_n;
		end

	//	The recording. One write port, one registered read port: a block RAM.
	//	The read address is the next index, so the word is there in the cycle
	//	after an index write or a data read.
	(* ram_style = "block" *) reg [63:0] mem [0:(1 << AW) - 1];
	reg [63:0] rd_q;
	always @(posedge clk) begin
		if (word_we)
			mem[cnt_q[AW+3:4]] <= {rng_b_i, part_q};
		rd_q <= mem[idx_n];
	end

	//	Outside test mode the noise source runs at the build's period.
	assign div_o = allow ? div_q : DIV_RESET;
	assign respace_o = period_we;

	//	Only the low bits of a written value are used.
	wire unused = &{reg_wdata_i[63:8], 1'b0};

	wire [7:0]	log2_symbols = LOG2_SYMBOLS[7:0];
	wire [15:0]	words_done = {{(16-AW){1'b0}}, cnt_q[AW+3:4]};
	wire [63:0] status = {MAGIC, words_done, log2_symbols, 1'b0, brk_q, test_i, rng_en_i, lock_i, allow, done_q, busy_q};
	assign reg_rdata_o = (reg_raddr_i == R_CTRL)   ? status :
						 (reg_raddr_i == R_PERIOD) ? {56'b0, div_q} :
						 (reg_raddr_i == R_INDEX)  ? {{(64-AW){1'b0}}, idx_q} :
						 (reg_raddr_i == R_DATA && allow && done_q) ? rd_q : 64'b0;

`ifndef KARU_NO_ASSERT
	// synthesis translate_off
	reg allow_d, chk_q;
	always @(posedge clk) begin
		allow_d <= allow;
		chk_q   <= !rst;
		if (chk_q && !rst) begin
			if (busy_q && done_q) begin
				$display("ASSERT: karu_noise_burst: capturing and done together"); $fatal;
			end
			if (brk_q && (busy_q || done_q)) begin
				$display("ASSERT: karu_noise_burst: an aborted capture is running or held"); $fatal;
			end
			if (!allow_d && (busy_q || done_q || div_q != DIV_RESET || idx_q != 0)) begin
				$display("ASSERT: karu_noise_burst: state kept outside test mode"); $fatal;
			end
			if (!allow && div_o != DIV_RESET) begin
				$display("ASSERT: karu_noise_burst: the period differs from the build's outside test mode"); $fatal;
			end
			if (!(allow && done_q) && reg_raddr_i == R_DATA && reg_rdata_o != 64'b0) begin
				$display("ASSERT: karu_noise_burst: data readable without a completed capture in test mode"); $fatal;
			end
		end
	end
	// synthesis translate_on
`endif
endmodule
