//	karu_soft_reset.v
//	=== Software reset: a one-cycle request becomes a held reset pulse.
//
//	The request comes from the system-control register in the SoC
//	(karu_ddr_xbar.v, 0x1000_0800). That register sits in the logic the
//	pulse resets, so the request disappears as soon as the reset takes
//	effect. This block is reset only by the board (power-on) reset, so a
//	pulse it has started always runs to its full length.
//
//	reset_o is one flop. It feeds asynchronous reset inputs and must not be
//	a function of several signals that could glitch.

module karu_soft_reset #(
	parameter integer HOLD_CYCLES = 256		//	pulse length in clk cycles (>= 2)
) (
	input  wire	clk,
	input  wire	por_i,		//	board reset, synchronous to clk; NOT the SoC reset
	input  wire	req_i,		//	one-cycle reset request
	output reg	reset_o		//	high for HOLD_CYCLES cycles after a request
);
	localparam integer CW = $clog2(HOLD_CYCLES);
	reg [CW-1:0]	count;

	always @(posedge clk) begin
		if (por_i) begin
			reset_o <= 1'b0;
			count   <= {CW{1'b0}};
		end else if (reset_o) begin
			//	A request during the pulse is ignored: its source is in reset.
			if (count == {CW{1'b0}})
				reset_o <= 1'b0;
			else
				count <= count - 1'b1;
		end else if (req_i) begin
			reset_o <= 1'b1;
			count   <= HOLD_CYCLES[CW-1:0] - 1'b1;
		end
	end

	// synthesis translate_off
`ifndef KARU_NO_ASSERT
	//	Local invariants: the pulse starts only one cycle after a request,
	//	and once started lasts exactly HOLD_CYCLES cycles unless the board
	//	reset intervenes.
	integer	chk_len;
	reg		chk_req_q, chk_reset_q, chk_por_q;
	initial	chk_len = 0;
	always @(posedge clk) begin
		chk_req_q   <= req_i && !por_i;
		chk_reset_q <= reset_o;
		chk_por_q   <= por_i;
		if (por_i)			chk_len <= 0;
		else if (reset_o)	chk_len <= chk_len + 1;
		else				chk_len <= 0;
		if (!por_i && chk_por_q === 1'b0) begin
			if (reset_o && chk_reset_q === 1'b0 && chk_req_q !== 1'b1) begin
				$display("[ASSERT] karu_soft_reset: reset without a request");
				$finish;
			end
			if (!reset_o && chk_reset_q === 1'b1 && chk_len != HOLD_CYCLES) begin
				$display("[ASSERT] karu_soft_reset: pulse of %0d cycles, expected %0d", chk_len, HOLD_CYCLES);
				$finish;
			end
		end
	end
`endif
	// synthesis translate_on

endmodule
