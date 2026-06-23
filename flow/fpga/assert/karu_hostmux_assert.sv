//	karu_hostmux_assert.sv
//	Bindable checker for the vcu118_ddr_top host/CPU AXI mux. The mux select
//	(host_cpu_hold/use_host_axi) is safe to change only when no selected-side
//	transaction is visible or outstanding.

module karu_hostmux_assert #(
	parameter integer STOP_ON_FAIL = 1
) (
	input  wire		ui_clk,
	input  wire		ui_axi_rst,
	input  wire		use_host_axi,

	input  wire		s_arvalid,
	input  wire		s_arready,
	input  wire		s_awvalid,
	input  wire		s_awready,
	input  wire		s_wvalid,
	input  wire		s_wready,
	input  wire		s_rvalid,
	input  wire		s_rready,
	input  wire		s_rlast,
	input  wire		s_bvalid,
	input  wire		s_bready,

	input  wire		c_arvalid,
	input  wire		c_awvalid,
	input  wire		c_wvalid,
	input  wire		h_arvalid,
	input  wire		h_awvalid,
	input  wire		h_wvalid
);
	integer	fails   = 0;
	reg		enabled = 1'b1;
	reg		do_stop = 1'b1;
	reg [63:0] h_cyc = 64'b0;
	reg na, nss;

	initial begin
		nss = $test$plusargs("no_assert_stop");
		na  = $test$plusargs("no_assert");
		if (nss)        do_stop = 1'b0;
		if (na && !nss) enabled = 1'b0;
	end

	`define HCHK(cond, tag) \
		if (enabled && !ui_axi_rst && !(cond)) begin \
			fails = fails + 1; \
			$display("[HOSTMUX-ASSERT] FAIL cyc=%0d t=%0t: %s", h_cyc, $time, tag); \
			if (do_stop && (STOP_ON_FAIL != 0)) begin \
				$display("[HOSTMUX-ASSERT] %0d failure(s); stopping.", fails); \
				$finish; \
			end \
		end

	reg			use_host_axi_q;
	reg [3:0]	rd_out;
	reg [3:0]	wr_out;

	wire rd_inc = s_arvalid && s_arready;
	wire rd_dec = s_rvalid && s_rready && s_rlast;
	wire wr_inc = s_awvalid && s_awready;
	wire wr_dec = s_bvalid && s_bready;
	wire mux_idle = (rd_out == 4'd0) && (wr_out == 4'd0) &&
					!s_arvalid && !s_awvalid && !s_wvalid &&
					!s_rvalid && !s_bvalid &&
					!c_arvalid && !c_awvalid && !c_wvalid &&
					!h_arvalid && !h_awvalid && !h_wvalid;

	always @(posedge ui_clk) begin
		h_cyc <= h_cyc + 64'd1;
		if (ui_axi_rst) begin
			use_host_axi_q <= use_host_axi;
			rd_out <= 4'd0;
			wr_out <= 4'd0;
		end else begin
			`HCHK(!((use_host_axi != use_host_axi_q) && !mux_idle),
				  "host_cpu_hold/use_host_axi changed while AXI mux busy")
			`HCHK(!(rd_dec && rd_out == 4'd0), "read response with no tracked mux read")
			`HCHK(!(wr_dec && wr_out == 4'd0), "write response with no tracked mux write")
			`HCHK(!(rd_inc && !rd_dec && rd_out == 4'hf), "read outstanding counter overflow")
			`HCHK(!(wr_inc && !wr_dec && wr_out == 4'hf), "write outstanding counter overflow")

			use_host_axi_q <= use_host_axi;
			if (rd_inc && !rd_dec)
				rd_out <= rd_out + 4'd1;
			else if (!rd_inc && rd_dec)
				rd_out <= rd_out - 4'd1;
			if (wr_inc && !wr_dec)
				wr_out <= wr_out + 4'd1;
			else if (!wr_inc && wr_dec)
				wr_out <= wr_out - 4'd1;
		end
	end

	`undef HCHK
endmodule

`ifdef KARU_HOSTMUX_ASSERT_BIND
bind vcu118_ddr_top karu_hostmux_assert u_karu_hostmux_assert (
	.ui_clk(ui_clk),
	.ui_axi_rst(ui_axi_rst),
	.use_host_axi(use_host_axi),
	.s_arvalid(s_arvalid), .s_arready(s_arready),
	.s_awvalid(s_awvalid), .s_awready(s_awready),
	.s_wvalid(s_wvalid), .s_wready(s_wready),
	.s_rvalid(s_rvalid), .s_rready(s_rready), .s_rlast(s_rlast),
	.s_bvalid(s_bvalid), .s_bready(s_bready),
	.c_arvalid(c_arvalid), .c_awvalid(c_awvalid), .c_wvalid(c_wvalid),
	.h_arvalid(h_arvalid), .h_awvalid(h_awvalid), .h_wvalid(h_wvalid)
);
`endif
