//	karu_ddr_xbar_assert.v
//	Passive contract checker for flow/fpga/karu_ddr_xbar.v. This watches the real
//	xbar ownership latches, read-response muxes, Ethernet handoff, and 64-bit
//	AXI master/slave handshake stability. It is simulation-only: instantiated
//	from karu_ddr_xbar under SIM_TB, and disabled at runtime with the shared
//	+no_assert / +no_assert_stop plusargs.

`include "karu_axi_defs.vh"

module karu_ddr_xbar_assert #(
	parameter integer STOP_ON_FAIL = 1,
	parameter integer RD_STALL_LIMIT = 8192,
	parameter integer WR_STALL_LIMIT = 8192
) (
	input  wire						clk,
	input  wire						rst,

	//	---- imem slave side ----
	input  wire [`AXI_ID_W-1:0]		imem_arid,
	input  wire [`AXI_ADDR_W-1:0]	imem_araddr,
	input  wire [`AXI_LEN_W-1:0]	imem_arlen,
	input  wire [`AXI_SIZE_W-1:0]	imem_arsize,
	input  wire [`AXI_BURST_W-1:0]	imem_arburst,
	input  wire						imem_arvalid,
	input  wire						imem_arready,
	input  wire [`AXI_ID_W-1:0]		imem_rid,
	input  wire [`AXI_DATA_W-1:0]	imem_rdata,
	input  wire						imem_rlast,
	input  wire						imem_rvalid,
	input  wire						imem_rready,

	//	---- dmem slave side ----
	input  wire [`AXI_ID_W-1:0]		dmem_arid,
	input  wire [`AXI_ADDR_W-1:0]	dmem_araddr,
	input  wire [`AXI_LEN_W-1:0]	dmem_arlen,
	input  wire [`AXI_SIZE_W-1:0]	dmem_arsize,
	input  wire [`AXI_BURST_W-1:0]	dmem_arburst,
	input  wire						dmem_arvalid,
	input  wire						dmem_arready,
	input  wire [`AXI_ID_W-1:0]		dmem_rid,
	input  wire [`AXI_DATA_W-1:0]	dmem_rdata,
	input  wire						dmem_rlast,
	input  wire						dmem_rvalid,
	input  wire						dmem_rready,
	input  wire [`AXI_ID_W-1:0]		dmem_awid,
	input  wire [`AXI_ADDR_W-1:0]	dmem_awaddr,
	input  wire [`AXI_LEN_W-1:0]	dmem_awlen,
	input  wire [`AXI_SIZE_W-1:0]	dmem_awsize,
	input  wire [`AXI_BURST_W-1:0]	dmem_awburst,
	input  wire						dmem_awvalid,
	input  wire						dmem_awready,
	input  wire [`AXI_DATA_W-1:0]	dmem_wdata,
	input  wire [`AXI_STRB_W-1:0]	dmem_wstrb,
	input  wire						dmem_wlast,
	input  wire						dmem_wvalid,
	input  wire						dmem_wready,
	input  wire [`AXI_ID_W-1:0]		dmem_bid,
	input  wire						dmem_bvalid,
	input  wire						dmem_bready,

	//	---- DRAM master side ----
	input  wire [`AXI_ID_W-1:0]		m_arid,
	input  wire [`AXI_ADDR_W-1:0]	m_araddr,
	input  wire [`AXI_LEN_W-1:0]	m_arlen,
	input  wire [`AXI_SIZE_W-1:0]	m_arsize,
	input  wire [`AXI_BURST_W-1:0]	m_arburst,
	input  wire						m_arvalid,
	input  wire						m_arready,
	input  wire [`AXI_ID_W-1:0]		m_rid,
	input  wire [`AXI_DATA_W-1:0]	m_rdata,
	input  wire						m_rlast,
	input  wire						m_rvalid,
	input  wire						m_rready,
	input  wire [`AXI_ID_W-1:0]		m_awid,
	input  wire [`AXI_ADDR_W-1:0]	m_awaddr,
	input  wire [`AXI_LEN_W-1:0]	m_awlen,
	input  wire [`AXI_SIZE_W-1:0]	m_awsize,
	input  wire [`AXI_BURST_W-1:0]	m_awburst,
	input  wire						m_awvalid,
	input  wire						m_awready,
	input  wire [`AXI_DATA_W-1:0]	m_wdata,
	input  wire [`AXI_STRB_W-1:0]	m_wstrb,
	input  wire						m_wlast,
	input  wire						m_wvalid,
	input  wire						m_wready,
	input  wire [`AXI_ID_W-1:0]		m_bid,
	input  wire						m_bvalid,
	input  wire						m_bready,

	//	---- xbar internal state / route signals ----
	input  wire [1:0]				lr_st,
	input  wire [1:0]				lr_own,
	input  wire [`AXI_ID_W-1:0]		lr_id,
	input  wire						lr_to_imem,
	input  wire						lr_to_dmem,
	input  wire [1:0]				dr_st,
	input  wire [1:0]				dr_own,
	input  wire [`AXI_ID_W-1:0]		dr_arid,
	input  wire [`AXI_ADDR_W-1:0]	dr_araddr,
	input  wire [`AXI_LEN_W-1:0]	dr_arlen,
	input  wire [`AXI_SIZE_W-1:0]	dr_arsize,
	input  wire						dr_to_imem,
	input  wire						dr_to_dmem,
	input  wire						mr_st,
	input  wire [`AXI_ID_W-1:0]		mr_id,
	input  wire						mr_uart,
	input  wire						mr_clint,
	input  wire						mr_plic,
	input  wire						mr_flash,
	input  wire						mr_eth,
	input  wire						eth_rd_ready,
	input  wire						mmio_rvalid,
	input  wire [1:0]				w_st,
	input  wire [`AXI_ID_W-1:0]		w_bid,
	input  wire						eth_busy,
	input  wire						eth_rd_req,
	input  wire						eth_rd_done,
	input  wire						eth_wr_req,
	input  wire						eth_wr_done
);
	localparam OWN_NONE = 2'd0, OWN_IMEM = 2'd1, OWN_DMEM = 2'd2;
	localparam LR_IDLE = 2'd0, LR_WAIT = 2'd1, LR_VLD = 2'd2;
	localparam DR_IDLE = 2'd0, DR_AR = 2'd1, DR_DATA = 2'd2;
	localparam MR_IDLE = 1'b0, MR_VLD = 1'b1;
	localparam W_IDLE = 2'd0, W_DRAM = 2'd1, W_MMIO_B = 2'd2, W_ETH = 2'd3;

	integer	fails   = 0;
	reg		enabled = 1'b1;
	reg		do_stop = 1'b1;
	reg [63:0] x_cyc = 64'b0;
	reg na, nss;

	initial begin
		nss = $test$plusargs("no_assert_stop");
		na  = $test$plusargs("no_assert");
		if (nss)        do_stop = 1'b0;
		if (na && !nss) enabled = 1'b0;
	end

	function [2:0] sum3;
		input a, b, c;
		begin
			sum3 = {2'b0, a} + {2'b0, b} + {2'b0, c};
		end
	endfunction

	function [2:0] sum5;
		input a, b, c, d, e;
		begin
			sum5 = {2'b0, a} + {2'b0, b} + {2'b0, c} + {2'b0, d} + {2'b0, e};
		end
	endfunction

	`define XCHK(cond, tag) \
		if (enabled && !rst && !(cond)) begin \
			fails = fails + 1; \
			$display("[XBAR-ASSERT] FAIL cyc=%0d t=%0t: %s", x_cyc, $time, tag); \
			if (do_stop && (STOP_ON_FAIL != 0)) begin \
				$display("[XBAR-ASSERT] %0d failure(s); stopping.", fails); \
				$finish; \
			end \
		end

	task x_hang;
		input [8*80-1:0] tag;
		begin
			if (enabled && !rst) begin
				fails = fails + 1;
				$display("[XBAR-ASSERT] HANG cyc=%0d t=%0t: %0s", x_cyc, $time, tag);
				$display("[XBAR-ASSERT]   lr=%0d/%0d mr=%0d dr=%0d/%0d w=%0d",
					lr_st, lr_own, mr_st, dr_st, dr_own, w_st);
				if (do_stop && (STOP_ON_FAIL != 0)) begin
					$display("[XBAR-ASSERT] %0d failure(s); stopping.", fails);
					$finish;
				end
			end
		end
	endtask

	wire lr_busy_imem = (lr_st != LR_IDLE) && (lr_own == OWN_IMEM);
	wire lr_busy_dmem = (lr_st != LR_IDLE) && (lr_own == OWN_DMEM);
	wire dr_busy_imem = (dr_st != DR_IDLE) && (dr_own == OWN_IMEM);
	wire dr_busy_dmem = (dr_st != DR_IDLE) && (dr_own == OWN_DMEM);
	wire mr_busy_dmem = (mr_st != MR_IDLE);

	wire imem_lr_src = lr_to_imem;
	wire imem_dr_src = dr_to_imem && m_rvalid;
	wire dmem_lr_src = lr_to_dmem;
	wire dmem_mr_src = mmio_rvalid;
	wire dmem_dr_src = dr_to_dmem && m_rvalid;

	wire [2:0] imem_read_active = sum3(lr_busy_imem, dr_busy_imem, 1'b0);
	wire [2:0] dmem_read_active = sum3(lr_busy_dmem, mr_busy_dmem, dr_busy_dmem);
	wire [2:0] imem_r_srcs = sum3(imem_lr_src, imem_dr_src, 1'b0);
	wire [2:0] dmem_r_srcs = sum3(dmem_lr_src, dmem_mr_src, dmem_dr_src);
	wire [2:0] mr_decode_n = sum5(mr_uart, mr_clint, mr_plic, mr_flash, mr_eth);

	//	---- stability samples ----
	reg p_imem_arvalid, p_imem_arready;
	reg [`AXI_ID_W-1:0] p_imem_arid;
	reg [`AXI_ADDR_W-1:0] p_imem_araddr;
	reg [`AXI_LEN_W-1:0] p_imem_arlen;
	reg [`AXI_SIZE_W-1:0] p_imem_arsize;
	reg [`AXI_BURST_W-1:0] p_imem_arburst;
	reg p_dmem_arvalid, p_dmem_arready;
	reg [`AXI_ID_W-1:0] p_dmem_arid;
	reg [`AXI_ADDR_W-1:0] p_dmem_araddr;
	reg [`AXI_LEN_W-1:0] p_dmem_arlen;
	reg [`AXI_SIZE_W-1:0] p_dmem_arsize;
	reg [`AXI_BURST_W-1:0] p_dmem_arburst;
	reg p_dmem_awvalid, p_dmem_awready;
	reg [`AXI_ID_W-1:0] p_dmem_awid;
	reg [`AXI_ADDR_W-1:0] p_dmem_awaddr;
	reg [`AXI_LEN_W-1:0] p_dmem_awlen;
	reg [`AXI_SIZE_W-1:0] p_dmem_awsize;
	reg [`AXI_BURST_W-1:0] p_dmem_awburst;
	reg p_dmem_wvalid, p_dmem_wready, p_dmem_wlast;
	reg [`AXI_DATA_W-1:0] p_dmem_wdata;
	reg [`AXI_STRB_W-1:0] p_dmem_wstrb;
	reg p_imem_rvalid, p_imem_rready, p_imem_rlast;
	reg [`AXI_ID_W-1:0] p_imem_rid;
	reg [`AXI_DATA_W-1:0] p_imem_rdata;
	reg p_dmem_rvalid, p_dmem_rready, p_dmem_rlast;
	reg [`AXI_ID_W-1:0] p_dmem_rid;
	reg [`AXI_DATA_W-1:0] p_dmem_rdata;
	reg p_dmem_bvalid, p_dmem_bready;
	reg [`AXI_ID_W-1:0] p_dmem_bid;

	reg p_m_arvalid, p_m_arready;
	reg [`AXI_ID_W-1:0] p_m_arid;
	reg [`AXI_ADDR_W-1:0] p_m_araddr;
	reg [`AXI_LEN_W-1:0] p_m_arlen;
	reg [`AXI_SIZE_W-1:0] p_m_arsize;
	reg [`AXI_BURST_W-1:0] p_m_arburst;
	reg p_m_awvalid, p_m_awready;
	reg [`AXI_ID_W-1:0] p_m_awid;
	reg [`AXI_ADDR_W-1:0] p_m_awaddr;
	reg [`AXI_LEN_W-1:0] p_m_awlen;
	reg [`AXI_SIZE_W-1:0] p_m_awsize;
	reg [`AXI_BURST_W-1:0] p_m_awburst;
	reg p_m_wvalid, p_m_wready, p_m_wlast;
	reg [`AXI_DATA_W-1:0] p_m_wdata;
	reg [`AXI_STRB_W-1:0] p_m_wstrb;

	//	---- burst/transaction trackers for the downstream DRAM AXI ----
	reg			rd_track;
	reg [7:0]	rd_len;
	reg [7:0]	rd_beat;
	reg [31:0]	rd_cnt;
	reg			wr_track;
	reg			wr_seen_w;
	reg [31:0]	wr_cnt;

	always @(posedge clk) begin
		x_cyc <= x_cyc + 64'b1;

		if (rst) begin
			rd_track <= 1'b0;
			rd_len <= 8'b0;
			rd_beat <= 8'b0;
			rd_cnt <= 32'b0;
			wr_track <= 1'b0;
			wr_seen_w <= 1'b0;
			wr_cnt <= 32'b0;
		end else begin
			//	================= state / owner contracts =================
			`XCHK(lr_st <= LR_VLD, "X1 local-read FSM in undefined state")
			`XCHK(dr_st <= DR_DATA, "X2 DRAM-read FSM in undefined state")
			`XCHK((lr_st == LR_IDLE) == (lr_own == OWN_NONE),
				  "X4 local-read owner inconsistent with idle")
			`XCHK((dr_st == DR_IDLE) == (dr_own == OWN_NONE),
				  "X5 DRAM-read owner inconsistent with idle")
			`XCHK((lr_st == LR_IDLE) || (lr_own == OWN_IMEM) || (lr_own == OWN_DMEM),
				  "X6 local-read owner invalid")
			`XCHK((dr_st == DR_IDLE) || (dr_own == OWN_IMEM) || (dr_own == OWN_DMEM),
				  "X7 DRAM-read owner invalid")

			//	The xbar has no dmem read tag FIFO. At most one dmem read slot
			//	(boot, MMIO, and DRAM) may be live at once, and likewise for imem.
			`XCHK(dmem_read_active <= 3'd1,
				  "X8 multiple live dmem read sources (missing upstream single-outstanding)")
			`XCHK(imem_read_active <= 3'd1,
				  "X9 multiple live imem read sources")

			//	================= read-response mux contracts =================
			`XCHK(dmem_r_srcs <= 3'd1, "X10 dmem R mux has multiple valid sources")
			`XCHK(imem_r_srcs <= 3'd1, "X11 imem R mux has multiple valid sources")
			`XCHK((dmem_r_srcs != 0) == dmem_rvalid, "X12 dmem_rvalid != OR(valid sources)")
			`XCHK((imem_r_srcs != 0) == imem_rvalid, "X13 imem_rvalid != OR(valid sources)")
			`XCHK(!lr_to_imem || (imem_rid == lr_id && imem_rlast),
				  "X14 imem boot response id/last mismatch")
			`XCHK(!(dr_to_imem && m_rvalid) || (imem_rid == m_rid && imem_rlast == m_rlast),
				  "X15 imem DRAM response id/last mismatch")
			`XCHK(!lr_to_dmem || (dmem_rid == lr_id && dmem_rlast),
				  "X16 dmem boot response id/last mismatch")
			`XCHK(!mmio_rvalid || (dmem_rid == mr_id && dmem_rlast),
				  "X17 dmem MMIO response id/last mismatch")
			`XCHK(!(dr_to_dmem && m_rvalid) || (dmem_rid == m_rid && dmem_rlast == m_rlast),
				  "X18 dmem DRAM response id/last mismatch")
			//	MMIO rdata is live device output, not a response FIFO. The current
			//	core must take MMIO read data immediately once valid.
			`XCHK(!mmio_rvalid || dmem_rready,
				  "X19 MMIO read response backpressured (live rdata would need latching)")
			`XCHK(mr_decode_n <= 3'd1, "X20 MMIO read decoded to multiple devices")

			//	================= Ethernet bridge handoff contracts =================
			`XCHK(!(eth_rd_req && eth_busy), "X21 eth_rd_req while bridge busy")
			`XCHK(!(eth_wr_req && eth_busy), "X22 eth_wr_req while bridge busy")
			`XCHK(!(eth_rd_req && eth_wr_req), "X23 eth read/write req same cycle")
			`XCHK(!eth_rd_done || (mr_st == MR_VLD && mr_eth && !eth_rd_ready),
				  "X24 eth_rd_done without pending eth MMIO read")
			`XCHK(!eth_wr_done || (w_st == W_ETH),
				  "X25 eth_wr_done without pending eth MMIO write")

			//	================= AXI payload stability while stalled =================
			`XCHK(!(p_imem_arvalid && !p_imem_arready) ||
				  (imem_arvalid && imem_arid == p_imem_arid &&
				   imem_araddr == p_imem_araddr && imem_arlen == p_imem_arlen &&
				   imem_arsize == p_imem_arsize && imem_arburst == p_imem_arburst),
				  "X26 imem AR changed while stalled")
			`XCHK(!(p_dmem_arvalid && !p_dmem_arready) ||
				  (dmem_arvalid && dmem_arid == p_dmem_arid &&
				   dmem_araddr == p_dmem_araddr && dmem_arlen == p_dmem_arlen &&
				   dmem_arsize == p_dmem_arsize && dmem_arburst == p_dmem_arburst),
				  "X27 dmem AR changed while stalled")
			`XCHK(!(p_dmem_awvalid && !p_dmem_awready) ||
				  (dmem_awvalid && dmem_awid == p_dmem_awid &&
				   dmem_awaddr == p_dmem_awaddr && dmem_awlen == p_dmem_awlen &&
				   dmem_awsize == p_dmem_awsize && dmem_awburst == p_dmem_awburst),
				  "X28 dmem AW changed while stalled")
			`XCHK(!(p_dmem_wvalid && !p_dmem_wready) ||
				  (dmem_wvalid && dmem_wdata == p_dmem_wdata &&
				   dmem_wstrb == p_dmem_wstrb && dmem_wlast == p_dmem_wlast),
				  "X29 dmem W changed while stalled")
			`XCHK(!(p_imem_rvalid && !p_imem_rready) ||
				  (imem_rvalid && imem_rid == p_imem_rid &&
				   imem_rdata == p_imem_rdata && imem_rlast == p_imem_rlast),
				  "X30 imem R changed while stalled")
			`XCHK(!(p_dmem_rvalid && !p_dmem_rready) ||
				  (dmem_rvalid && dmem_rid == p_dmem_rid &&
				   dmem_rdata == p_dmem_rdata && dmem_rlast == p_dmem_rlast),
				  "X31 dmem R changed while stalled")
			`XCHK(!(p_dmem_bvalid && !p_dmem_bready) ||
				  (dmem_bvalid && dmem_bid == p_dmem_bid),
				  "X32 dmem B changed while stalled")
			`XCHK(!(p_m_arvalid && !p_m_arready) ||
				  (m_arvalid && m_arid == p_m_arid &&
				   m_araddr == p_m_araddr && m_arlen == p_m_arlen &&
				   m_arsize == p_m_arsize && m_arburst == p_m_arburst),
				  "X33 master AR changed while stalled")
			`XCHK(!(p_m_awvalid && !p_m_awready) ||
				  (m_awvalid && m_awid == p_m_awid &&
				   m_awaddr == p_m_awaddr && m_awlen == p_m_awlen &&
				   m_awsize == p_m_awsize && m_awburst == p_m_awburst),
				  "X34 master AW changed while stalled")
			`XCHK(!(p_m_wvalid && !p_m_wready) ||
				  (m_wvalid && m_wdata == p_m_wdata &&
				   m_wstrb == p_m_wstrb && m_wlast == p_m_wlast),
				  "X35 master W changed while stalled")

			//	================= 64-bit DRAM-side AXI contracts =================
			`XCHK(!m_arvalid || (dr_st == DR_AR), "X36 m_arvalid outside DR_AR")
			`XCHK(!m_arvalid || (m_arid == dr_arid && m_araddr == dr_araddr &&
				   m_arlen == dr_arlen && m_arsize == dr_arsize &&
				   m_arburst == `AXI_BURST_INCR),
				  "X37 m_ar* != latched DR request")
			`XCHK(!m_arvalid || (m_araddr[31] && m_araddr[2:0] == 3'b000),
				  "X38 m_araddr not aligned DRAM address")
			`XCHK(!m_arvalid || (m_arsize == `AXI_SIZE_8B), "X39 m_arsize not 8B")
			`XCHK(!m_arvalid || (m_arlen == 8'd0 || m_arlen == 8'd7),
				  "X40 m_arlen not single-beat or cache-line refill")
			`XCHK(!m_arvalid || (m_arlen != 8'd7) || (m_araddr[5:0] == 6'b0),
				  "X41 8-beat read not cache-line aligned")
			`XCHK(!m_rvalid || (dr_st == DR_DATA), "X42 m_rvalid without DR_DATA owner")
			`XCHK(!m_awvalid || (w_st == W_IDLE), "X43 m_awvalid outside W_IDLE")
			`XCHK(!m_awvalid || (m_awaddr[31] && m_awaddr[2:0] == 3'b000),
				  "X44 m_awaddr not aligned DRAM address")
			`XCHK(!m_awvalid || (m_awlen == 8'd0 && m_awsize == `AXI_SIZE_8B &&
				   m_awburst == `AXI_BURST_INCR),
				  "X45 write AW is not the current single-beat 64-bit contract")
			`XCHK(!m_wvalid || (w_st == W_DRAM), "X46 m_wvalid outside W_DRAM")
			`XCHK(!m_wvalid || m_wlast, "X47 current write contract requires WLAST on every beat")
			`XCHK(!m_bvalid || (w_st == W_DRAM), "X48 m_bvalid without W_DRAM owner")
			`XCHK((w_st != W_DRAM) || dmem_awready == 1'b0,
				  "X49 dmem_awready high while a DRAM write is outstanding")

			//	================= read burst accounting =================
			if (m_arvalid && m_arready) begin
				`XCHK(!rd_track, "X50 new read AR accepted while previous read outstanding")
				rd_track <= 1'b1;
				rd_len <= m_arlen;
				rd_beat <= 8'b0;
			end
			if (m_rvalid && m_rready) begin
				`XCHK(rd_track, "X51 read data accepted without read transaction")
				if (m_rlast) begin
					`XCHK(rd_beat == rd_len, "X52 RLAST on wrong read beat")
					rd_track <= 1'b0;
				end else begin
					`XCHK(rd_beat < rd_len, "X53 read burst exceeded ARLEN without RLAST")
					rd_beat <= rd_beat + 8'b1;
				end
			end
			rd_cnt <= rd_track ? rd_cnt + 32'b1 : 32'b0;
			if (rd_track && rd_cnt > RD_STALL_LIMIT)
				x_hang("read transaction exceeded RD_STALL_LIMIT");

			//	================= write transaction accounting =================
			if (m_awvalid && m_awready) begin
				`XCHK(!wr_track, "X54 new write AW accepted while previous write outstanding")
				wr_track <= 1'b1;
				wr_seen_w <= 1'b0;
			end
			if (m_wvalid && m_wready) begin
				`XCHK(wr_track, "X55 write data accepted before write AW")
				`XCHK(!wr_seen_w, "X56 more than one W beat in single-beat write")
				`XCHK(m_wlast, "X57 accepted write beat without WLAST")
				wr_seen_w <= 1'b1;
			end
			if (m_bvalid) begin
				`XCHK(wr_track, "X58 BVALID without outstanding write")
				`XCHK(wr_seen_w, "X59 BVALID before WLAST beat was accepted")
			end
			if (m_bvalid && m_bready) begin
				wr_track <= 1'b0;
				wr_seen_w <= 1'b0;
			end
			wr_cnt <= wr_track ? wr_cnt + 32'b1 : 32'b0;
			if (wr_track && wr_cnt > WR_STALL_LIMIT)
				x_hang("write transaction exceeded WR_STALL_LIMIT");
		end

		p_imem_arvalid <= imem_arvalid; p_imem_arready <= imem_arready;
		p_imem_arid <= imem_arid; p_imem_araddr <= imem_araddr;
		p_imem_arlen <= imem_arlen; p_imem_arsize <= imem_arsize;
		p_imem_arburst <= imem_arburst;
		p_dmem_arvalid <= dmem_arvalid; p_dmem_arready <= dmem_arready;
		p_dmem_arid <= dmem_arid; p_dmem_araddr <= dmem_araddr;
		p_dmem_arlen <= dmem_arlen; p_dmem_arsize <= dmem_arsize;
		p_dmem_arburst <= dmem_arburst;
		p_dmem_awvalid <= dmem_awvalid; p_dmem_awready <= dmem_awready;
		p_dmem_awid <= dmem_awid; p_dmem_awaddr <= dmem_awaddr;
		p_dmem_awlen <= dmem_awlen; p_dmem_awsize <= dmem_awsize;
		p_dmem_awburst <= dmem_awburst;
		p_dmem_wvalid <= dmem_wvalid; p_dmem_wready <= dmem_wready;
		p_dmem_wdata <= dmem_wdata; p_dmem_wstrb <= dmem_wstrb;
		p_dmem_wlast <= dmem_wlast;
		p_imem_rvalid <= imem_rvalid; p_imem_rready <= imem_rready;
		p_imem_rid <= imem_rid; p_imem_rdata <= imem_rdata;
		p_imem_rlast <= imem_rlast;
		p_dmem_rvalid <= dmem_rvalid; p_dmem_rready <= dmem_rready;
		p_dmem_rid <= dmem_rid; p_dmem_rdata <= dmem_rdata;
		p_dmem_rlast <= dmem_rlast;
		p_dmem_bvalid <= dmem_bvalid; p_dmem_bready <= dmem_bready;
		p_dmem_bid <= dmem_bid;
		p_m_arvalid <= m_arvalid; p_m_arready <= m_arready;
		p_m_arid <= m_arid; p_m_araddr <= m_araddr;
		p_m_arlen <= m_arlen; p_m_arsize <= m_arsize;
		p_m_arburst <= m_arburst;
		p_m_awvalid <= m_awvalid; p_m_awready <= m_awready;
		p_m_awid <= m_awid; p_m_awaddr <= m_awaddr;
		p_m_awlen <= m_awlen; p_m_awsize <= m_awsize;
		p_m_awburst <= m_awburst;
		p_m_wvalid <= m_wvalid; p_m_wready <= m_wready;
		p_m_wdata <= m_wdata; p_m_wstrb <= m_wstrb;
		p_m_wlast <= m_wlast;
	end

	`undef XCHK

	wire _unused = &{1'b0, m_awid, m_bid, w_bid, dmem_bready};
endmodule
