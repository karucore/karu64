//	karu_axi4_ram.v
//	=== Behavioral single-port AXI4 slave memory (MIG user-AXI stand-in).
//
//	Models what the Xilinx MIG presents to the SoC: one AXI4 slave with INCR
//	bursts, a settable read latency, and a large backing array. Used only in
//	the verilator DDR sim (`make ddr-sim`); on hardware this module is replaced
//	by the MIG-generated user interface. The array is $readmemh-initialised from
//	the firmware hex -- the sim analogue of a JTAG-loaded DDR4 image.
//
//	  - reads:  INCR burst, registered BRAM read (RLAT extra wait beats/beat)
//	  - writes: INCR burst, byte-strobed, one B response per AW
//	  - single read AND single write outstanding (the xbar serialises reads)

`include "karu_axi_defs.vh"

module karu_axi4_ram #(
	parameter		RAM_XADR  = 20,					//	bytes = 1<<RAM_XADR
	parameter [31:0] MEM_BASE = 32'h8000_0000,		//	window base (DRAM)
	parameter		RLAT	  = 0,					//	extra read-latency beats
	parameter		HEXFILE	  = "firmware.hex"
) (
	input  wire			clk,
	input  wire			rst,

	//	AR / R
	input  wire [`AXI_ID_W-1:0]		s_arid,
	input  wire [`AXI_ADDR_W-1:0]	s_araddr,
	input  wire [`AXI_LEN_W-1:0]	s_arlen,
	input  wire [`AXI_SIZE_W-1:0]	s_arsize,
	input  wire [`AXI_BURST_W-1:0]	s_arburst,
	input  wire						s_arvalid,
	output reg						s_arready,
	output reg  [`AXI_ID_W-1:0]		s_rid,
	output reg  [`AXI_DATA_W-1:0]	s_rdata,
	output reg  [`AXI_RESP_W-1:0]	s_rresp,
	output reg						s_rlast,
	output reg						s_rvalid,
	input  wire						s_rready,

	//	AW / W / B
	input  wire [`AXI_ID_W-1:0]		s_awid,
	input  wire [`AXI_ADDR_W-1:0]	s_awaddr,
	input  wire [`AXI_LEN_W-1:0]	s_awlen,
	input  wire [`AXI_SIZE_W-1:0]	s_awsize,
	input  wire [`AXI_BURST_W-1:0]	s_awburst,
	input  wire						s_awvalid,
	output reg						s_awready,
	input  wire [`AXI_DATA_W-1:0]	s_wdata,
	input  wire [`AXI_STRB_W-1:0]	s_wstrb,
	input  wire						s_wlast,
	input  wire						s_wvalid,
	output reg						s_wready,
	output reg  [`AXI_ID_W-1:0]		s_bid,
	output reg  [`AXI_RESP_W-1:0]	s_bresp,
	output reg						s_bvalid,
	input  wire						s_bready
);
	localparam	RAM_WORDS  = (1 << RAM_XADR) / 8;
	localparam	RAM_IDX_HI = RAM_XADR - 1;

	(* ram_style = "block" *)
	reg [63:0]	ram [0:RAM_WORDS-1];
`ifdef SIM_TB
	reg [8*256-1:0] hexarg;
	initial begin
		if (!$value$plusargs("hex=%s", hexarg))
			hexarg = HEXFILE;
		$readmemh(hexarg, ram);
	end
`else
	initial $readmemh(HEXFILE, ram);
`endif

	function [RAM_IDX_HI-3:0] widx(input [`AXI_ADDR_W-1:0] a);
		widx = a[RAM_IDX_HI:3] - MEM_BASE[RAM_IDX_HI:3];
	endfunction

	//	================= read channel (INCR burst) =================
	localparam R_IDLE = 2'd0, R_RD = 2'd1, R_VLD = 2'd2;
	reg [1:0]			r_st;
	reg [`AXI_ID_W-1:0]	r_id;
	reg [RAM_IDX_HI-3:0] r_idx;
	reg [`AXI_LEN_W-1:0] r_cnt;
	reg [31:0]			r_wait;
	reg [63:0]			r_q;

	always @(posedge clk) r_q <= ram[r_idx];

	always @(*) begin
		s_arready = (r_st == R_IDLE);
		s_rvalid  = (r_st == R_VLD);
		s_rdata	  = r_q;
		s_rid	  = r_id;
		s_rresp	  = `AXI_RESP_OKAY;
		s_rlast	  = (r_st == R_VLD) && (r_cnt == 0);
	end

	always @(posedge clk) begin
		if (rst) begin
			r_st <= R_IDLE;
		end else case (r_st)
			R_IDLE: if (s_arvalid) begin
				r_idx  <= widx(s_araddr);
				r_id   <= s_arid;
				r_cnt  <= s_arlen;
				r_wait <= RLAT;
				r_st   <= R_RD;
			end
			R_RD: if (r_wait != 0) r_wait <= r_wait - 1'b1;	//	model MIG latency
				  else             r_st   <= R_VLD;			//	r_q holds ram[idx]
			R_VLD: if (s_rready) begin
				if (r_cnt == 0) begin
					r_st <= R_IDLE;
				end else begin
					r_idx  <= r_idx + 1'b1;
					r_cnt  <= r_cnt - 1'b1;
					r_wait <= RLAT;
					r_st   <= R_RD;
				end
			end
			default: r_st <= R_IDLE;
		endcase
	end

	//	================= write channel (INCR burst) =================
	localparam W_AW = 2'd0, W_DAT = 2'd1, W_RESP = 2'd2;
	reg [1:0]			w_st;
	reg [`AXI_ID_W-1:0]	w_id;
	reg [RAM_IDX_HI-3:0] w_idx;

	integer b;
	always @(*) begin
		s_awready = (w_st == W_AW);
		s_wready  = (w_st == W_DAT);
		s_bvalid  = (w_st == W_RESP);
		s_bid	  = w_id;
		s_bresp	  = `AXI_RESP_OKAY;
	end

	always @(posedge clk) begin
		if (rst) begin
			w_st <= W_AW;
		end else case (w_st)
			W_AW: if (s_awvalid) begin
				w_idx <= widx(s_awaddr);
				w_id  <= s_awid;
				w_st  <= W_DAT;
			end
			W_DAT: if (s_wvalid) begin
				for (b = 0; b < 8; b = b + 1)
					if (s_wstrb[b])
						ram[w_idx][b*8 +: 8] <= s_wdata[b*8 +: 8];
				w_idx <= w_idx + 1'b1;
				if (s_wlast) w_st <= W_RESP;
			end
			W_RESP: if (s_bready) w_st <= W_AW;
			default: w_st <= W_AW;
		endcase
	end

	wire _unused = &{ s_arsize, s_arburst, s_awsize, s_awburst, 1'b0 };
endmodule
