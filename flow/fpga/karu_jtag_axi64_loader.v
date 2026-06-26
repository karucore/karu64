//	karu_jtag_axi64_loader.v
//	=== 32-bit JTAG AXI master -> 64-bit AXI loader adapter.
//
//	This is a loader, not a general interconnect. It is clocked in the
//	MIG ui_clk domain and is used while the CPU is held in reset. Full 32-bit
//	addresses from Vivado/XSDB are mapped to the DDR offset window by dropping
//	bit 31, so writes to 0x8000_0000 reach MIG address 0.

`include "karu_axi_defs.vh"

module karu_jtag_axi64_loader (
	input  wire					clk,
	input  wire					rst,

	//	32-bit AXI from xilinx.com:ip:jtag_axi.
	input  wire [0:0]			s_awid,
	input  wire [31:0]			s_awaddr,
	input  wire [7:0]			s_awlen,
	input  wire [2:0]			s_awsize,
	input  wire [1:0]			s_awburst,
	input  wire					s_awvalid,
	output wire					s_awready,
	input  wire [31:0]			s_wdata,
	input  wire [3:0]			s_wstrb,
	input  wire					s_wlast,
	input  wire					s_wvalid,
	output wire					s_wready,
	output reg  [0:0]			s_bid,
	output reg  [1:0]			s_bresp,
	output reg					s_bvalid,
	input  wire					s_bready,

	input  wire [0:0]			s_arid,
	input  wire [31:0]			s_araddr,
	input  wire [7:0]			s_arlen,
	input  wire [2:0]			s_arsize,
	input  wire [1:0]			s_arburst,
	input  wire					s_arvalid,
	output wire					s_arready,
	output reg  [0:0]			s_rid,
	output reg  [31:0]			s_rdata,
	output reg  [1:0]			s_rresp,
	output reg					s_rlast,
	output reg					s_rvalid,
	input  wire					s_rready,

	//	64-bit AXI toward the DDR data-width converter.
	output reg  [`AXI_ID_W-1:0]	m_awid,
	output reg  [30:0]			m_awaddr,
	output reg  [`AXI_LEN_W-1:0]	m_awlen,
	output reg  [`AXI_SIZE_W-1:0]	m_awsize,
	output reg  [`AXI_BURST_W-1:0]	m_awburst,
	output wire					m_awlock,
	output wire [3:0]			m_awcache,
	output wire [`AXI_PROT_W-1:0]	m_awprot,
	output wire [3:0]			m_awregion,
	output wire [3:0]			m_awqos,
	output reg					m_awvalid,
	input  wire					m_awready,
	output reg  [`AXI_DATA_W-1:0]	m_wdata,
	output reg  [`AXI_STRB_W-1:0]	m_wstrb,
	output reg					m_wlast,
	output reg					m_wvalid,
	input  wire					m_wready,
	input  wire [`AXI_ID_W-1:0]	m_bid,
	input  wire [`AXI_RESP_W-1:0]	m_bresp,
	input  wire					m_bvalid,
	output wire					m_bready,

	output reg  [`AXI_ID_W-1:0]	m_arid,
	output reg  [30:0]			m_araddr,
	output reg  [`AXI_LEN_W-1:0]	m_arlen,
	output reg  [`AXI_SIZE_W-1:0]	m_arsize,
	output reg  [`AXI_BURST_W-1:0]	m_arburst,
	output wire					m_arlock,
	output wire [3:0]			m_arcache,
	output wire [`AXI_PROT_W-1:0]	m_arprot,
	output wire [3:0]			m_arregion,
	output wire [3:0]			m_arqos,
	output reg					m_arvalid,
	input  wire					m_arready,
	input  wire [`AXI_ID_W-1:0]	m_rid,
	input  wire [`AXI_DATA_W-1:0]	m_rdata,
	input  wire [`AXI_RESP_W-1:0]	m_rresp,
	input  wire					m_rlast,
	input  wire					m_rvalid,
	output wire					m_rready
);
	localparam [1:0] W_IDLE = 2'd0, W_BEAT = 2'd1, W_RESP = 2'd2;
	localparam [1:0] R_IDLE = 2'd0, R_REQ  = 2'd1, R_DATA = 2'd2;

	reg [1:0]	wstate, rstate;
	reg [31:0]	waddr, raddr;
	reg [7:0]	wleft, rleft;
	reg [2:0]	wstep, rstep;
	reg			wlast_seen;

	assign m_awlock = 1'b0;
	assign m_awcache = 4'b0011;
	assign m_awprot = 3'b000;
	assign m_awregion = 4'b0000;
	assign m_awqos = 4'b0000;
	assign m_arlock = 1'b0;
	assign m_arcache = 4'b0011;
	assign m_arprot = 3'b000;
	assign m_arregion = 4'b0000;
	assign m_arqos = 4'b0000;

	assign s_awready = (wstate == W_IDLE) && !s_bvalid;
	assign s_wready = (wstate == W_BEAT) && !m_awvalid && !m_wvalid;
	assign m_bready = (wstate == W_RESP);

	assign s_arready = (rstate == R_IDLE) && !s_rvalid;
	assign m_rready = (rstate == R_DATA) && !s_rvalid;

	function [2:0] beat_step(input [2:0] size);
		case (size)
		3'd0: beat_step = 3'd1;
		3'd1: beat_step = 3'd2;
		default: beat_step = 3'd4;
		endcase
	endfunction

	always @(posedge clk) begin
		if (rst) begin
			wstate <= W_IDLE;
			m_awvalid <= 1'b0;
			m_wvalid <= 1'b0;
			s_bvalid <= 1'b0;
			s_bresp <= `AXI_RESP_OKAY;
			s_bid <= 1'b0;
			wlast_seen <= 1'b0;
		end else begin
			if (m_awvalid && m_awready)
				m_awvalid <= 1'b0;
			if (m_wvalid && m_wready)
				m_wvalid <= 1'b0;
			if (s_bvalid && s_bready)
				s_bvalid <= 1'b0;

			case (wstate)
			W_IDLE: begin
				if (s_awvalid && s_awready) begin
					waddr <= s_awaddr;
					wleft <= s_awlen;
					wstep <= beat_step(s_awsize);
					s_bid <= s_awid;
					s_bresp <= `AXI_RESP_OKAY;
					wlast_seen <= 1'b0;
					wstate <= W_BEAT;
				end
			end
			W_BEAT: begin
				if (s_wvalid && s_wready) begin
					m_awid <= {3'b000, s_bid};
					m_awaddr <= {waddr[30:3], 3'b000};
					m_awlen <= 8'd0;
					m_awsize <= `AXI_SIZE_8B;
					m_awburst <= `AXI_BURST_INCR;
					m_awvalid <= 1'b1;
					m_wdata <= waddr[2] ? {s_wdata, 32'b0} : {32'b0, s_wdata};
					m_wstrb <= waddr[2] ? {s_wstrb, 4'b0000} : {4'b0000, s_wstrb};
					m_wlast <= 1'b1;
					m_wvalid <= 1'b1;
					wlast_seen <= s_wlast || (wleft == 8'd0);
					wstate <= W_RESP;
				end
			end
			W_RESP: begin
				if (m_bvalid && m_bready) begin
					s_bresp <= s_bresp | m_bresp;
					if (wlast_seen) begin
						s_bvalid <= 1'b1;
						wstate <= W_IDLE;
					end else begin
						waddr <= waddr + {29'b0, wstep};
						wleft <= wleft - 8'd1;
						wstate <= W_BEAT;
					end
				end
			end
			default: wstate <= W_IDLE;
			endcase
		end
	end

	always @(posedge clk) begin
		if (rst) begin
			rstate <= R_IDLE;
			m_arvalid <= 1'b0;
			s_rvalid <= 1'b0;
			s_rresp <= `AXI_RESP_OKAY;
			s_rlast <= 1'b0;
			s_rid <= 1'b0;
		end else begin
			if (m_arvalid && m_arready)
				m_arvalid <= 1'b0;
			if (s_rvalid && s_rready) begin
				s_rvalid <= 1'b0;
				if (s_rlast)
					rstate <= R_IDLE;
				else begin
					raddr <= raddr + {29'b0, rstep};
					rleft <= rleft - 8'd1;
					rstate <= R_REQ;
				end
			end

			case (rstate)
			R_IDLE: begin
				if (s_arvalid && s_arready) begin
					raddr <= s_araddr;
					rleft <= s_arlen;
					rstep <= beat_step(s_arsize);
					s_rid <= s_arid;
					rstate <= R_REQ;
				end
			end
			R_REQ: begin
				if (!m_arvalid) begin
					m_arid <= {3'b000, s_rid};
					m_araddr <= {raddr[30:3], 3'b000};
					m_arlen <= 8'd0;
					m_arsize <= `AXI_SIZE_8B;
					m_arburst <= `AXI_BURST_INCR;
					m_arvalid <= 1'b1;
					rstate <= R_DATA;
				end
			end
			R_DATA: begin
				if (m_rvalid && m_rready) begin
					s_rdata <= raddr[2] ? m_rdata[63:32] : m_rdata[31:0];
					s_rresp <= m_rresp;
					s_rlast <= (rleft == 8'd0);
					s_rvalid <= 1'b1;
				end
			end
			default: rstate <= R_IDLE;
			endcase
		end
	end

	wire _unused = &{s_awburst, s_arburst, m_bid, m_rid, m_rlast, 1'b0};
endmodule
