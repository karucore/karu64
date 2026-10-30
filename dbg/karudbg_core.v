// SPDX-License-Identifier: BSD-3-Clause
// Single-hart core + execution-based DM integration. The debug aperture is
// private to these two core ports; external masters have no route to it.
// External reset and ndmreset reset the hart/AXI adapters, not the DM.
// Integrations must reset/quiesce the external bus responders too, so no
// pre-reset R/B response can be mistaken for a post-reset transaction.
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karudbg_defs.vh"
module karudbg_core #(
    parameter [63:0] RESET_PC=64'h8000_0000,
    parameter EXT_TIME=0, parameter NONSECURE=1,
    // Trusted integration lock: tied from the SoC lifecycle policy at reset.
    parameter SBA_ENABLE=1
) (
    input wire  clk,
    input wire  rst,
    output wire  debug_mode_o,
    output wire  debug_resume_ack_o,
    output wire  trap,
    input wire  irq,
    input wire  irq_software,
    input wire  irq_external_m,
    input wire  irq_external_s,
    input wire [63:0] time_in,
    input wire [31:0] uncache_page,
    input wire [31:0] hpm_events,
    output wire  cache_flush_req,
    output wire  cache_flush_invalidate,
    input wire  cache_flush_done,
    output wire [`AXI_ID_W-1:0] imem_arid,
    output wire [`AXI_ADDR_W-1:0] imem_araddr,
    output wire [`AXI_LEN_W-1:0] imem_arlen,
    output wire [`AXI_SIZE_W-1:0] imem_arsize,
    output wire [`AXI_BURST_W-1:0] imem_arburst,
    output wire [`AXI_PROT_W-1:0] imem_arprot,
    output wire  imem_arvalid,
    input wire  imem_arready,
    input wire [`AXI_ID_W-1:0] imem_rid,
    input wire [`AXI_DATA_W-1:0] imem_rdata,
    input wire [`AXI_RESP_W-1:0] imem_rresp,
    input wire  imem_rlast,
    input wire  imem_rvalid,
    output wire  imem_rready,
    output wire [`AXI_ID_W-1:0] dmem_arid,
    output wire [`AXI_ADDR_W-1:0] dmem_araddr,
    output wire [`AXI_LEN_W-1:0] dmem_arlen,
    output wire [`AXI_SIZE_W-1:0] dmem_arsize,
    output wire [`AXI_BURST_W-1:0] dmem_arburst,
    output wire [`AXI_PROT_W-1:0] dmem_arprot,
    output wire  dmem_arvalid,
    input wire  dmem_arready,
    input wire [`AXI_ID_W-1:0] dmem_rid,
    input wire [`AXI_DATA_W-1:0] dmem_rdata,
    input wire [`AXI_RESP_W-1:0] dmem_rresp,
    input wire  dmem_rlast,
    input wire  dmem_rvalid,
    output wire  dmem_rready,
    output wire [`AXI_ID_W-1:0] dmem_awid,
    output wire [`AXI_ADDR_W-1:0] dmem_awaddr,
    output wire [`AXI_LEN_W-1:0] dmem_awlen,
    output wire [`AXI_SIZE_W-1:0] dmem_awsize,
    output wire [`AXI_BURST_W-1:0] dmem_awburst,
    output wire [`AXI_PROT_W-1:0] dmem_awprot,
    output wire  dmem_awvalid,
    input wire  dmem_awready,
    output wire [`AXI_DATA_W-1:0] dmem_wdata,
    output wire [`AXI_STRB_W-1:0] dmem_wstrb,
    output wire  dmem_wlast,
    output wire  dmem_wvalid,
    input wire  dmem_wready,
    input wire [`AXI_ID_W-1:0] dmem_bid,
    input wire [`AXI_RESP_W-1:0] dmem_bresp,
    input wire  dmem_bvalid,
    output wire  dmem_bready,
    input wire  hart_reset_i,
    input wire  dmi_reset_i,
    input wire  dmi_req_valid_i,
    output wire  dmi_req_ready_o,
    input wire [6:0] dmi_req_addr_i,
    input wire [1:0] dmi_req_op_i,
    input wire [31:0] dmi_req_data_i,
    output wire  dmi_resp_valid_o,
    input wire  dmi_resp_ready_i,
    output wire [31:0] dmi_resp_data_o,
    output wire [1:0] dmi_resp_op_o,
    output wire  ndmreset_o
);
    wire core_rst, halt_req, resume_req, resume_authorized;
    assign core_rst = rst || hart_reset_i || ndmreset_o;
    wire [`AXI_ID_W-1:0] c_imem_arid;
    wire [`AXI_ADDR_W-1:0] c_imem_araddr;
    wire [`AXI_LEN_W-1:0] c_imem_arlen;
    wire [`AXI_SIZE_W-1:0] c_imem_arsize;
    wire [`AXI_BURST_W-1:0] c_imem_arburst;
    wire [`AXI_PROT_W-1:0] c_imem_arprot;
    wire  c_imem_arvalid;
    wire  c_imem_arready;
    wire [`AXI_ID_W-1:0] c_imem_rid;
    wire [`AXI_DATA_W-1:0] c_imem_rdata;
    wire [`AXI_RESP_W-1:0] c_imem_rresp;
    wire  c_imem_rlast;
    wire  c_imem_rvalid;
    wire  c_imem_rready;
    wire [`AXI_ID_W-1:0] c_dmem_arid;
    wire [`AXI_ADDR_W-1:0] c_dmem_araddr;
    wire [`AXI_LEN_W-1:0] c_dmem_arlen;
    wire [`AXI_SIZE_W-1:0] c_dmem_arsize;
    wire [`AXI_BURST_W-1:0] c_dmem_arburst;
    wire [`AXI_PROT_W-1:0] c_dmem_arprot;
    wire  c_dmem_arvalid;
    wire  c_dmem_arready;
    wire [`AXI_ID_W-1:0] c_dmem_rid;
    wire [`AXI_DATA_W-1:0] c_dmem_rdata;
    wire [`AXI_RESP_W-1:0] c_dmem_rresp;
    wire  c_dmem_rlast;
    wire  c_dmem_rvalid;
    wire  c_dmem_rready;
    wire [`AXI_ID_W-1:0] c_dmem_awid;
    wire [`AXI_ADDR_W-1:0] c_dmem_awaddr;
    wire [`AXI_LEN_W-1:0] c_dmem_awlen;
    wire [`AXI_SIZE_W-1:0] c_dmem_awsize;
    wire [`AXI_BURST_W-1:0] c_dmem_awburst;
    wire [`AXI_PROT_W-1:0] c_dmem_awprot;
    wire  c_dmem_awvalid;
    wire  c_dmem_awready;
    wire [`AXI_DATA_W-1:0] c_dmem_wdata;
    wire [`AXI_STRB_W-1:0] c_dmem_wstrb;
    wire  c_dmem_wlast;
    wire  c_dmem_wvalid;
    wire  c_dmem_wready;
    wire [`AXI_ID_W-1:0] c_dmem_bid;
    wire [`AXI_RESP_W-1:0] c_dmem_bresp;
    wire  c_dmem_bvalid;
    wire  c_dmem_bready;
    wire [3:0] x_dmem_arid;
    wire [31:0] x_dmem_araddr;
    wire [7:0] x_dmem_arlen;
    wire [2:0] x_dmem_arsize;
    wire [1:0] x_dmem_arburst;
    wire [2:0] x_dmem_arprot;
    wire x_dmem_arvalid;
    wire x_dmem_rready;
    wire [3:0] x_dmem_awid;
    wire [31:0] x_dmem_awaddr;
    wire [7:0] x_dmem_awlen;
    wire [2:0] x_dmem_awsize;
    wire [1:0] x_dmem_awburst;
    wire [2:0] x_dmem_awprot;
    wire x_dmem_awvalid;
    wire [63:0] x_dmem_wdata;
    wire [7:0] x_dmem_wstrb;
    wire x_dmem_wlast;
    wire x_dmem_wvalid;
    wire x_dmem_bready;
    wire x_dmem_arready;
    wire [3:0] x_dmem_rid;
    wire [63:0] x_dmem_rdata;
    wire [1:0] x_dmem_rresp;
    wire x_dmem_rlast;
    wire x_dmem_rvalid;
    wire x_dmem_awready;
    wire x_dmem_wready;
    wire [3:0] x_dmem_bid;
    wire [1:0] x_dmem_bresp;
    wire x_dmem_bvalid;
    wire sba_req_valid, sba_req_ready, sba_req_write;
    wire [63:0] sba_req_addr, sba_req_data;
    wire [2:0] sba_req_size;
    wire sba_resp_valid, sba_resp_ready;
    wire [63:0] sba_resp_data;
    wire [2:0] sba_resp_error;
`ifdef KARU_DBG_SBA
    wire sba_pause, sba_quiet, sba_flush;
    karudbg_bus #(.NONSECURE(NONSECURE),.ENABLE(SBA_ENABLE)) system_bus (
        .clk(clk),.rst(core_rst),
        .req_valid_i(sba_req_valid),.req_ready_o(sba_req_ready),
        .req_addr_i(sba_req_addr),.req_data_i(sba_req_data),
        .req_size_i(sba_req_size),.req_write_i(sba_req_write),
        .resp_valid_o(sba_resp_valid),.resp_ready_i(sba_resp_ready),
        .resp_data_o(sba_resp_data),.resp_error_o(sba_resp_error),
        .pause_o(sba_pause),.quiet_i(sba_quiet),.flush_o(sba_flush),
        .c_arid(x_dmem_arid),.m_arid(dmem_arid),
        .c_araddr(x_dmem_araddr),.m_araddr(dmem_araddr),
        .c_arlen(x_dmem_arlen),.m_arlen(dmem_arlen),
        .c_arsize(x_dmem_arsize),.m_arsize(dmem_arsize),
        .c_arburst(x_dmem_arburst),.m_arburst(dmem_arburst),
        .c_arprot(x_dmem_arprot),.m_arprot(dmem_arprot),
        .c_arvalid(x_dmem_arvalid),.m_arvalid(dmem_arvalid),
        .c_rready(x_dmem_rready),.m_rready(dmem_rready),
        .c_awid(x_dmem_awid),.m_awid(dmem_awid),
        .c_awaddr(x_dmem_awaddr),.m_awaddr(dmem_awaddr),
        .c_awlen(x_dmem_awlen),.m_awlen(dmem_awlen),
        .c_awsize(x_dmem_awsize),.m_awsize(dmem_awsize),
        .c_awburst(x_dmem_awburst),.m_awburst(dmem_awburst),
        .c_awprot(x_dmem_awprot),.m_awprot(dmem_awprot),
        .c_awvalid(x_dmem_awvalid),.m_awvalid(dmem_awvalid),
        .c_wdata(x_dmem_wdata),.m_wdata(dmem_wdata),
        .c_wstrb(x_dmem_wstrb),.m_wstrb(dmem_wstrb),
        .c_wlast(x_dmem_wlast),.m_wlast(dmem_wlast),
        .c_wvalid(x_dmem_wvalid),.m_wvalid(dmem_wvalid),
        .c_bready(x_dmem_bready),.m_bready(dmem_bready),
        .c_arready(x_dmem_arready),.m_arready(dmem_arready),
        .c_rid(x_dmem_rid),.m_rid(dmem_rid),
        .c_rdata(x_dmem_rdata),.m_rdata(dmem_rdata),
        .c_rresp(x_dmem_rresp),.m_rresp(dmem_rresp),
        .c_rlast(x_dmem_rlast),.m_rlast(dmem_rlast),
        .c_rvalid(x_dmem_rvalid),.m_rvalid(dmem_rvalid),
        .c_awready(x_dmem_awready),.m_awready(dmem_awready),
        .c_wready(x_dmem_wready),.m_wready(dmem_wready),
        .c_bid(x_dmem_bid),.m_bid(dmem_bid),
        .c_bresp(x_dmem_bresp),.m_bresp(dmem_bresp),
        .c_bvalid(x_dmem_bvalid),.m_bvalid(dmem_bvalid));
`else
    assign dmem_arid=x_dmem_arid;
    assign dmem_araddr=x_dmem_araddr;
    assign dmem_arlen=x_dmem_arlen;
    assign dmem_arsize=x_dmem_arsize;
    assign dmem_arburst=x_dmem_arburst;
    assign dmem_arprot=x_dmem_arprot;
    assign dmem_arvalid=x_dmem_arvalid;
    assign dmem_rready=x_dmem_rready;
    assign dmem_awid=x_dmem_awid;
    assign dmem_awaddr=x_dmem_awaddr;
    assign dmem_awlen=x_dmem_awlen;
    assign dmem_awsize=x_dmem_awsize;
    assign dmem_awburst=x_dmem_awburst;
    assign dmem_awprot=x_dmem_awprot;
    assign dmem_awvalid=x_dmem_awvalid;
    assign dmem_wdata=x_dmem_wdata;
    assign dmem_wstrb=x_dmem_wstrb;
    assign dmem_wlast=x_dmem_wlast;
    assign dmem_wvalid=x_dmem_wvalid;
    assign dmem_bready=x_dmem_bready;
    assign x_dmem_arready=dmem_arready;
    assign x_dmem_rid=dmem_rid;
    assign x_dmem_rdata=dmem_rdata;
    assign x_dmem_rresp=dmem_rresp;
    assign x_dmem_rlast=dmem_rlast;
    assign x_dmem_rvalid=dmem_rvalid;
    assign x_dmem_awready=dmem_awready;
    assign x_dmem_wready=dmem_wready;
    assign x_dmem_bid=dmem_bid;
    assign x_dmem_bresp=dmem_bresp;
    assign x_dmem_bvalid=dmem_bvalid;
    assign sba_req_ready=0;
    assign sba_resp_valid=0;
    assign sba_resp_data=0;
    assign sba_resp_error=0;
    wire unused_sba;
    assign unused_sba = &{sba_req_valid,sba_req_write,sba_req_addr,sba_req_data,
                        sba_req_size,sba_resp_ready,SBA_ENABLE!=0,1'b0};
`endif
    reg im_owner, dr_owner, dw_owner, dw_active;
    wire im_select, dr_select, dw_select, dw_route, dw_route_valid;
    assign im_select = (c_imem_araddr & 32'hffff_f000) == `KARUDBG_BASE;
    assign dr_select = (c_dmem_araddr & 32'hffff_f000) == `KARUDBG_BASE;
    assign dw_select = (c_dmem_awaddr & 32'hffff_f000) == `KARUDBG_BASE;
    // W may precede AW acceptance. Some legal local slaves assert AWREADY
    // only with WVALID, so waiting for AW here would deadlock MMIO writes.
    assign dw_route = dw_active ? dw_owner : dw_select;
    assign dw_route_valid = dw_active || c_dmem_awvalid;
    wire  i_arready;
    wire [`AXI_ID_W-1:0] i_rid;
    wire [`AXI_DATA_W-1:0] i_rdata;
    wire [`AXI_RESP_W-1:0] i_rresp;
    wire  i_rlast;
    wire  i_rvalid;
    wire  i_rready;
    assign imem_arid=c_imem_arid;
    assign imem_araddr=c_imem_araddr;
    assign imem_arlen=c_imem_arlen;
    assign imem_arsize=c_imem_arsize;
    assign imem_arburst=c_imem_arburst;
    assign imem_arprot=c_imem_arprot;
    assign imem_arvalid=c_imem_arvalid && !im_select;
    assign c_imem_arready=c_imem_arvalid && (im_select ? i_arready : imem_arready);
    assign c_imem_rid=im_owner ? i_rid : imem_rid;
    assign c_imem_rdata=im_owner ? i_rdata : imem_rdata;
    assign c_imem_rresp=im_owner ? i_rresp : imem_rresp;
    assign c_imem_rlast=im_owner ? i_rlast : imem_rlast;
    assign c_imem_rvalid=im_owner ? i_rvalid : imem_rvalid;
    assign imem_rready=c_imem_rready && !im_owner;
    assign i_rready=c_imem_rready && im_owner;
    wire  d_arready;
    wire [`AXI_ID_W-1:0] d_rid;
    wire [`AXI_DATA_W-1:0] d_rdata;
    wire [`AXI_RESP_W-1:0] d_rresp;
    wire  d_rlast;
    wire  d_rvalid;
    wire  d_rready;
    wire  d_awready;
    wire  d_wready;
    wire [`AXI_ID_W-1:0] d_bid;
    wire [`AXI_RESP_W-1:0] d_bresp;
    wire  d_bvalid;
    wire  d_bready;
    assign x_dmem_arid=c_dmem_arid;
    assign x_dmem_araddr=c_dmem_araddr;
    assign x_dmem_arlen=c_dmem_arlen;
    assign x_dmem_arsize=c_dmem_arsize;
    assign x_dmem_arburst=c_dmem_arburst;
    assign x_dmem_arprot=c_dmem_arprot;
    assign x_dmem_arvalid=c_dmem_arvalid && !dr_select;
    assign c_dmem_arready=c_dmem_arvalid && (dr_select ? d_arready : x_dmem_arready);
    assign c_dmem_rid=dr_owner ? d_rid : x_dmem_rid;
    assign c_dmem_rdata=dr_owner ? d_rdata : x_dmem_rdata;
    assign c_dmem_rresp=dr_owner ? d_rresp : x_dmem_rresp;
    assign c_dmem_rlast=dr_owner ? d_rlast : x_dmem_rlast;
    assign c_dmem_rvalid=dr_owner ? d_rvalid : x_dmem_rvalid;
    assign x_dmem_rready=c_dmem_rready && !dr_owner;
    assign d_rready=c_dmem_rready && dr_owner;
    assign x_dmem_awid=c_dmem_awid;
    assign x_dmem_awaddr=c_dmem_awaddr;
    assign x_dmem_awlen=c_dmem_awlen;
    assign x_dmem_awsize=c_dmem_awsize;
    assign x_dmem_awburst=c_dmem_awburst;
    assign x_dmem_awprot=c_dmem_awprot;
    assign x_dmem_wdata=c_dmem_wdata;
    assign x_dmem_wstrb=c_dmem_wstrb;
    assign x_dmem_wlast=c_dmem_wlast;
    assign x_dmem_awvalid=c_dmem_awvalid && !dw_active && !dw_select;
    assign c_dmem_awready=c_dmem_awvalid && !dw_active && (dw_select ? d_awready : x_dmem_awready);
    assign x_dmem_wvalid=c_dmem_wvalid && dw_route_valid && !dw_route;
    assign c_dmem_wready=dw_route_valid && (dw_route ? d_wready : x_dmem_wready);
    assign c_dmem_bid=dw_owner ? d_bid : x_dmem_bid;
    assign c_dmem_bresp=dw_owner ? d_bresp : x_dmem_bresp;
    assign c_dmem_bvalid=dw_owner ? d_bvalid : x_dmem_bvalid;
    assign x_dmem_bready=c_dmem_bready && !dw_owner;
    assign d_bready=c_dmem_bready && dw_owner;
    always @(posedge clk) begin
        if(core_rst) begin im_owner<=0; dr_owner<=0; dw_owner<=0; dw_active<=0; end
        else begin
            if(c_imem_arvalid && c_imem_arready) im_owner<=im_select;
            if(c_dmem_arvalid && c_dmem_arready) dr_owner<=dr_select;
            if(c_dmem_awvalid && c_dmem_awready) begin dw_owner<=dw_select; dw_active<=1; end
            if(c_dmem_bvalid && c_dmem_bready) dw_active<=0;
        end
    end
    karu64 #(.RESET_PC(RESET_PC),.EXT_TIME(EXT_TIME),.NONSECURE(NONSECURE)) core (
        .clk(clk),
        .rst(core_rst),
`ifdef KARU_DBG_SBA
        .debug_sba_pause_i(sba_pause),.debug_sba_quiet_o(sba_quiet),
        .debug_sba_flush_i(sba_flush),
`endif
        .debug_halt_req_i(halt_req),
        .debug_resume_req_i(resume_authorized),
        .debug_mode_o(debug_mode_o),
        .debug_resume_ack_o(debug_resume_ack_o),
        .trap(trap),
        .irq(irq),
        .irq_software(irq_software),
        .irq_external_m(irq_external_m),
        .irq_external_s(irq_external_s),
        .time_in(time_in),
        .uncache_page(uncache_page),
        .hpm_events(hpm_events),
        .cache_flush_req(cache_flush_req),
        .cache_flush_invalidate(cache_flush_invalidate),
        .cache_flush_done(cache_flush_done),
        .imem_arid(c_imem_arid),
        .imem_araddr(c_imem_araddr),
        .imem_arlen(c_imem_arlen),
        .imem_arsize(c_imem_arsize),
        .imem_arburst(c_imem_arburst),
        .imem_arprot(c_imem_arprot),
        .imem_arvalid(c_imem_arvalid),
        .imem_arready(c_imem_arready),
        .imem_rid(c_imem_rid),
        .imem_rdata(c_imem_rdata),
        .imem_rresp(c_imem_rresp),
        .imem_rlast(c_imem_rlast),
        .imem_rvalid(c_imem_rvalid),
        .imem_rready(c_imem_rready),
        .dmem_arid(c_dmem_arid),
        .dmem_araddr(c_dmem_araddr),
        .dmem_arlen(c_dmem_arlen),
        .dmem_arsize(c_dmem_arsize),
        .dmem_arburst(c_dmem_arburst),
        .dmem_arprot(c_dmem_arprot),
        .dmem_arvalid(c_dmem_arvalid),
        .dmem_arready(c_dmem_arready),
        .dmem_rid(c_dmem_rid),
        .dmem_rdata(c_dmem_rdata),
        .dmem_rresp(c_dmem_rresp),
        .dmem_rlast(c_dmem_rlast),
        .dmem_rvalid(c_dmem_rvalid),
        .dmem_rready(c_dmem_rready),
        .dmem_awid(c_dmem_awid),
        .dmem_awaddr(c_dmem_awaddr),
        .dmem_awlen(c_dmem_awlen),
        .dmem_awsize(c_dmem_awsize),
        .dmem_awburst(c_dmem_awburst),
        .dmem_awprot(c_dmem_awprot),
        .dmem_awvalid(c_dmem_awvalid),
        .dmem_awready(c_dmem_awready),
        .dmem_wdata(c_dmem_wdata),
        .dmem_wstrb(c_dmem_wstrb),
        .dmem_wlast(c_dmem_wlast),
        .dmem_wvalid(c_dmem_wvalid),
        .dmem_wready(c_dmem_wready),
        .dmem_bid(c_dmem_bid),
        .dmem_bresp(c_dmem_bresp),
        .dmem_bvalid(c_dmem_bvalid),
        .dmem_bready(c_dmem_bready)
    );
    wire i_req, i_write, i_ready;
    wire [11:0] i_addr;
    wire [63:0] i_wdata;
    wire [7:0] i_be;
    wire d_req, d_write, d_ready;
    wire [11:0] d_addr;
    wire [63:0] d_wdata;
    wire [7:0] d_be;
    wire [63:0] mem_rdata;
    wire mem_ready, mem_error;
    karudbg #(.SBA_ENABLE(SBA_ENABLE)) dm (.clk(clk),.rst(rst),.dmi_reset_i(dmi_reset_i),
        .req_valid_i(dmi_req_valid_i),.req_ready_o(dmi_req_ready_o),
        .req_addr_i(dmi_req_addr_i),.req_op_i(dmi_req_op_i),.req_data_i(dmi_req_data_i),
        .resp_valid_o(dmi_resp_valid_o),.resp_ready_i(dmi_resp_ready_i),
        .resp_data_o(dmi_resp_data_o),.resp_op_o(dmi_resp_op_o),
        .sba_req_valid_o(sba_req_valid),.sba_req_ready_i(sba_req_ready),
        .sba_req_addr_o(sba_req_addr),.sba_req_data_o(sba_req_data),
        .sba_req_size_o(sba_req_size),.sba_req_write_o(sba_req_write),
        .sba_resp_valid_i(sba_resp_valid),.sba_resp_ready_o(sba_resp_ready),
        .sba_resp_data_i(sba_resp_data),.sba_resp_error_i(sba_resp_error),
        .halt_req_o(halt_req),.resume_req_o(resume_req),
        .resume_authorized_o(resume_authorized),.ndmreset_o(ndmreset_o),
        .hart_halted_i(debug_mode_o),.hart_resume_ack_i(debug_resume_ack_o),
        .hart_unavailable_i(core_rst),.hart_reset_i(core_rst),
        .mem_req_i(i_req || d_req),.mem_write_i(d_req ? d_write : i_write),
        .mem_addr_i(d_req ? d_addr : i_addr),.mem_wdata_i(d_req ? d_wdata : i_wdata),
        .mem_be_i(d_req ? d_be : i_be),.mem_rdata_o(mem_rdata),
        .mem_ready_o(mem_ready),.mem_error_o(mem_error));
    assign d_ready=mem_ready; assign i_ready=mem_ready && !d_req;
    karudbg_axi i_bridge (
        .clk(clk),
        .rst(core_rst),
        .allow_i(1'b1),
        .s_arid(c_imem_arid),
        .s_araddr(c_imem_araddr),
        .s_arlen(c_imem_arlen),
        .s_arsize(c_imem_arsize),
        .s_arburst(c_imem_arburst),
        .s_arprot(c_imem_arprot),
        .s_arvalid(c_imem_arvalid && im_select),
        .s_arready(i_arready),
        .s_rid(i_rid),
        .s_rdata(i_rdata),
        .s_rresp(i_rresp),
        .s_rlast(i_rlast),
        .s_rvalid(i_rvalid),
        .s_rready(i_rready),
        .s_awid(4'b0),
        .s_awaddr(32'b0),
        .s_awlen(8'b0),
        .s_awsize(3'b0),
        .s_awburst(2'b0),
        .s_awprot(3'b0),
        .s_awvalid(1'b0),
        .s_awready(),
        .s_wdata(64'b0),
        .s_wstrb(8'b0),
        .s_wlast(1'b0),
        .s_wvalid(1'b0),
        .s_wready(),
        .s_bid(),
        .s_bresp(),
        .s_bvalid(),
        .s_bready(1'b0),
        .mem_req_o(i_req),
        .mem_write_o(i_write),
        .mem_addr_o(i_addr),
        .mem_wdata_o(i_wdata),
        .mem_be_o(i_be),
        .mem_rdata_i(mem_rdata),
        .mem_ready_i(i_ready),
        .mem_error_i(mem_error)
    );
    karudbg_axi d_bridge (
        .clk(clk),
        .rst(core_rst),
        .allow_i(1'b1),
        .s_arid(c_dmem_arid),
        .s_araddr(c_dmem_araddr),
        .s_arlen(c_dmem_arlen),
        .s_arsize(c_dmem_arsize),
        .s_arburst(c_dmem_arburst),
        .s_arprot(c_dmem_arprot),
        .s_arvalid(c_dmem_arvalid && dr_select),
        .s_arready(d_arready),
        .s_rid(d_rid),
        .s_rdata(d_rdata),
        .s_rresp(d_rresp),
        .s_rlast(d_rlast),
        .s_rvalid(d_rvalid),
        .s_rready(d_rready),
        .s_awid(c_dmem_awid),
        .s_awaddr(c_dmem_awaddr),
        .s_awlen(c_dmem_awlen),
        .s_awsize(c_dmem_awsize),
        .s_awburst(c_dmem_awburst),
        .s_awprot(c_dmem_awprot),
        .s_awvalid(c_dmem_awvalid && !dw_active && dw_select),
        .s_awready(d_awready),
        .s_wdata(c_dmem_wdata),
        .s_wstrb(c_dmem_wstrb),
        .s_wlast(c_dmem_wlast),
        .s_wvalid(c_dmem_wvalid && dw_route_valid && dw_route),
        .s_wready(d_wready),
        .s_bid(d_bid),
        .s_bresp(d_bresp),
        .s_bvalid(d_bvalid),
        .s_bready(d_bready),
        .mem_req_o(d_req),
        .mem_write_o(d_write),
        .mem_addr_o(d_addr),
        .mem_wdata_o(d_wdata),
        .mem_be_o(d_be),
        .mem_rdata_i(mem_rdata),
        .mem_ready_i(d_ready),
        .mem_error_i(mem_error)
    );
endmodule
