// SPDX-License-Identifier: BSD-3-Clause
// Trusted boot island (plan 1.1, lemma C9) for KARU_DBG_AUTH integrations.
//
// A filter between the core's imem/dmem AXI ports (up_*) and the rest of the
// core-side routing (dn_*). Requests whose address lies in the island window
// [0, 2^WIN_AW) and inside the island ROM or SRAM range are served by island
// memory and never reach dn_*. Each channel records, at AR/AW acceptance,
// that a transaction is outstanding and whether it is an island one. An
// external R or B beat reaches the core only for an outstanding external
// transaction accepted in an earlier cycle; one arriving before, at or after
// an island request's acceptance is never forwarded or consumed (cut K3). The island is reachable only
// from these hart ports: it sits before karudbg_bus joins SBA and before any
// external fabric. Requests below 0x8000_0000 are single-beat (I-cache and
// D-cache keep device/boot targets uncached); bursts are answered SLVERR by
// karudbg_axi without touching memory.
//
// imem may fetch only from the ROM; a fetch from SRAM is answered SLVERR.
// dmem may read ROM and SRAM and write SRAM; a ROM write is SLVERR.
`include "karu_axi_defs.vh"
module karudbg_island #(
    parameter integer WIN_AW = 18,                 // island window [0, 256 KB)
    parameter [31:0] ROM_BASE = 32'h0001_0000,
    parameter [31:0] ROM_END = 32'h0002_0000,
    parameter [31:0] SRAM_BASE = 32'h0002_0000,
    parameter [31:0] SRAM_END = 32'h0002_4000,
    parameter ROM_HEX = ""
) (
    input wire clk,
    input wire rst,
    // imem: up (core) side
    input wire [`AXI_ID_W-1:0] up_imem_arid, input wire [`AXI_ADDR_W-1:0] up_imem_araddr,
    input wire [`AXI_LEN_W-1:0] up_imem_arlen, input wire [`AXI_SIZE_W-1:0] up_imem_arsize,
    input wire [`AXI_BURST_W-1:0] up_imem_arburst, input wire [`AXI_PROT_W-1:0] up_imem_arprot,
    input wire up_imem_arvalid, output wire up_imem_arready,
    output wire [`AXI_ID_W-1:0] up_imem_rid, output wire [`AXI_DATA_W-1:0] up_imem_rdata,
    output wire [`AXI_RESP_W-1:0] up_imem_rresp, output wire up_imem_rlast,
    output wire up_imem_rvalid, input wire up_imem_rready,
    // imem: down side
    output wire [`AXI_ID_W-1:0] dn_imem_arid, output wire [`AXI_ADDR_W-1:0] dn_imem_araddr,
    output wire [`AXI_LEN_W-1:0] dn_imem_arlen, output wire [`AXI_SIZE_W-1:0] dn_imem_arsize,
    output wire [`AXI_BURST_W-1:0] dn_imem_arburst, output wire [`AXI_PROT_W-1:0] dn_imem_arprot,
    output wire dn_imem_arvalid, input wire dn_imem_arready,
    input wire [`AXI_ID_W-1:0] dn_imem_rid, input wire [`AXI_DATA_W-1:0] dn_imem_rdata,
    input wire [`AXI_RESP_W-1:0] dn_imem_rresp, input wire dn_imem_rlast,
    input wire dn_imem_rvalid, output wire dn_imem_rready,
    // dmem: up (core) side
    input wire [`AXI_ID_W-1:0] up_dmem_arid, input wire [`AXI_ADDR_W-1:0] up_dmem_araddr,
    input wire [`AXI_LEN_W-1:0] up_dmem_arlen, input wire [`AXI_SIZE_W-1:0] up_dmem_arsize,
    input wire [`AXI_BURST_W-1:0] up_dmem_arburst, input wire [`AXI_PROT_W-1:0] up_dmem_arprot,
    input wire up_dmem_arvalid, output wire up_dmem_arready,
    output wire [`AXI_ID_W-1:0] up_dmem_rid, output wire [`AXI_DATA_W-1:0] up_dmem_rdata,
    output wire [`AXI_RESP_W-1:0] up_dmem_rresp, output wire up_dmem_rlast,
    output wire up_dmem_rvalid, input wire up_dmem_rready,
    input wire [`AXI_ID_W-1:0] up_dmem_awid, input wire [`AXI_ADDR_W-1:0] up_dmem_awaddr,
    input wire [`AXI_LEN_W-1:0] up_dmem_awlen, input wire [`AXI_SIZE_W-1:0] up_dmem_awsize,
    input wire [`AXI_BURST_W-1:0] up_dmem_awburst, input wire [`AXI_PROT_W-1:0] up_dmem_awprot,
    input wire up_dmem_awvalid, output wire up_dmem_awready,
    input wire [`AXI_DATA_W-1:0] up_dmem_wdata, input wire [`AXI_STRB_W-1:0] up_dmem_wstrb,
    input wire up_dmem_wlast, input wire up_dmem_wvalid, output wire up_dmem_wready,
    output wire [`AXI_ID_W-1:0] up_dmem_bid, output wire [`AXI_RESP_W-1:0] up_dmem_bresp,
    output wire up_dmem_bvalid, input wire up_dmem_bready,
    // dmem: down side
    output wire [`AXI_ID_W-1:0] dn_dmem_arid, output wire [`AXI_ADDR_W-1:0] dn_dmem_araddr,
    output wire [`AXI_LEN_W-1:0] dn_dmem_arlen, output wire [`AXI_SIZE_W-1:0] dn_dmem_arsize,
    output wire [`AXI_BURST_W-1:0] dn_dmem_arburst, output wire [`AXI_PROT_W-1:0] dn_dmem_arprot,
    output wire dn_dmem_arvalid, input wire dn_dmem_arready,
    input wire [`AXI_ID_W-1:0] dn_dmem_rid, input wire [`AXI_DATA_W-1:0] dn_dmem_rdata,
    input wire [`AXI_RESP_W-1:0] dn_dmem_rresp, input wire dn_dmem_rlast,
    input wire dn_dmem_rvalid, output wire dn_dmem_rready,
    output wire [`AXI_ID_W-1:0] dn_dmem_awid, output wire [`AXI_ADDR_W-1:0] dn_dmem_awaddr,
    output wire [`AXI_LEN_W-1:0] dn_dmem_awlen, output wire [`AXI_SIZE_W-1:0] dn_dmem_awsize,
    output wire [`AXI_BURST_W-1:0] dn_dmem_awburst, output wire [`AXI_PROT_W-1:0] dn_dmem_awprot,
    output wire dn_dmem_awvalid, input wire dn_dmem_awready,
    output wire [`AXI_DATA_W-1:0] dn_dmem_wdata, output wire [`AXI_STRB_W-1:0] dn_dmem_wstrb,
    output wire dn_dmem_wlast, output wire dn_dmem_wvalid, input wire dn_dmem_wready,
    input wire [`AXI_ID_W-1:0] dn_dmem_bid, input wire [`AXI_RESP_W-1:0] dn_dmem_bresp,
    input wire dn_dmem_bvalid, output wire dn_dmem_bready
);
    localparam integer ROM_WORDS = (ROM_END - ROM_BASE) / 8;
    localparam integer SRAM_WORDS = (SRAM_END - SRAM_BASE) / 8;
    reg [63:0] rom [0:ROM_WORDS-1];
    reg [63:0] sram [0:SRAM_WORDS-1];
    reg im_owner, dr_owner, dw_owner, dw_active;
    reg im_out, dr_out;              // a read is outstanding on the channel
    wire im_sel, dr_sel, dw_sel, dw_route, dw_route_valid;
    // island bridges
    wire i_arready, i_rlast, i_rvalid;
    wire [`AXI_ID_W-1:0] i_rid;
    wire [63:0] i_rdata;
    wire [1:0] i_rresp;
    wire d_arready, d_rlast, d_rvalid, d_awready, d_wready, d_bvalid;
    wire [`AXI_ID_W-1:0] d_rid, d_bid;
    wire [63:0] d_rdata;
    wire [1:0] d_rresp, d_bresp;
    wire i_req, i_write, d_req, d_write;
    wire [WIN_AW-1:0] i_addr, d_addr;
    wire [63:0] i_wdata, d_wdata;
    wire [7:0] i_be, d_be;
    reg [63:0] i_rdata_mem, d_rdata_mem;
    reg i_err, d_err;
    wire i_in_rom, d_in_rom, d_in_sram;
    integer k;

    function in_island;
        input [`AXI_ADDR_W-1:0] a;
        begin
            in_island = ({32'b0, a} >= {32'b0, ROM_BASE} && {32'b0, a} < {32'b0, ROM_END}) ||
                        ({32'b0, a} >= {32'b0, SRAM_BASE} && {32'b0, a} < {32'b0, SRAM_END});
        end
    endfunction

    // ---- routing (same structure as karudbg_core's debug-page router) ----
    assign im_sel = in_island(up_imem_araddr);
    assign dr_sel = in_island(up_dmem_araddr);
    assign dw_sel = in_island(up_dmem_awaddr);
    // W may precede AW acceptance; route it by the pending AW's address.
    assign dw_route = dw_active ? dw_owner : dw_sel;
    assign dw_route_valid = dw_active || up_dmem_awvalid;

    assign dn_imem_arid = up_imem_arid;
    assign dn_imem_araddr = up_imem_araddr;
    assign dn_imem_arlen = up_imem_arlen;
    assign dn_imem_arsize = up_imem_arsize;
    assign dn_imem_arburst = up_imem_arburst;
    assign dn_imem_arprot = up_imem_arprot;
    assign dn_imem_arvalid = up_imem_arvalid && !im_sel;
    assign up_imem_arready = up_imem_arvalid && (im_sel ? i_arready : dn_imem_arready);
    assign up_imem_rid = im_owner ? i_rid : dn_imem_rid;
    assign up_imem_rdata = im_owner ? i_rdata : dn_imem_rdata;
    assign up_imem_rresp = im_owner ? i_rresp : dn_imem_rresp;
    assign up_imem_rlast = im_owner ? i_rlast : dn_imem_rlast;
    assign up_imem_rvalid = im_out && (im_owner ? i_rvalid : dn_imem_rvalid);
    assign dn_imem_rready = up_imem_rready && im_out && !im_owner;

    assign dn_dmem_arid = up_dmem_arid;
    assign dn_dmem_araddr = up_dmem_araddr;
    assign dn_dmem_arlen = up_dmem_arlen;
    assign dn_dmem_arsize = up_dmem_arsize;
    assign dn_dmem_arburst = up_dmem_arburst;
    assign dn_dmem_arprot = up_dmem_arprot;
    assign dn_dmem_arvalid = up_dmem_arvalid && !dr_sel;
    assign up_dmem_arready = up_dmem_arvalid && (dr_sel ? d_arready : dn_dmem_arready);
    assign up_dmem_rid = dr_owner ? d_rid : dn_dmem_rid;
    assign up_dmem_rdata = dr_owner ? d_rdata : dn_dmem_rdata;
    assign up_dmem_rresp = dr_owner ? d_rresp : dn_dmem_rresp;
    assign up_dmem_rlast = dr_owner ? d_rlast : dn_dmem_rlast;
    assign up_dmem_rvalid = dr_out && (dr_owner ? d_rvalid : dn_dmem_rvalid);
    assign dn_dmem_rready = up_dmem_rready && dr_out && !dr_owner;

    assign dn_dmem_awid = up_dmem_awid;
    assign dn_dmem_awaddr = up_dmem_awaddr;
    assign dn_dmem_awlen = up_dmem_awlen;
    assign dn_dmem_awsize = up_dmem_awsize;
    assign dn_dmem_awburst = up_dmem_awburst;
    assign dn_dmem_awprot = up_dmem_awprot;
    assign dn_dmem_wdata = up_dmem_wdata;
    assign dn_dmem_wstrb = up_dmem_wstrb;
    assign dn_dmem_wlast = up_dmem_wlast;
    assign dn_dmem_awvalid = up_dmem_awvalid && !dw_active && !dw_sel;
    assign up_dmem_awready = up_dmem_awvalid && !dw_active && (dw_sel ? d_awready : dn_dmem_awready);
    assign dn_dmem_wvalid = up_dmem_wvalid && dw_route_valid && !dw_route;
    assign up_dmem_wready = dw_route_valid && (dw_route ? d_wready : dn_dmem_wready);
    assign up_dmem_bid = dw_owner ? d_bid : dn_dmem_bid;
    assign up_dmem_bresp = dw_owner ? d_bresp : dn_dmem_bresp;
    assign up_dmem_bvalid = dw_active && (dw_owner ? d_bvalid : dn_dmem_bvalid);
    assign dn_dmem_bready = up_dmem_bready && dw_active && !dw_owner;

    always @(posedge clk) begin
        if (rst) begin
            im_owner <= 0; dr_owner <= 0; dw_owner <= 0; dw_active <= 0;
            im_out <= 0; dr_out <= 0;
        end else begin
            // The final beat of one read may coincide with the next AR.
            if (up_imem_rvalid && up_imem_rready && up_imem_rlast) im_out <= 0;
            if (up_dmem_rvalid && up_dmem_rready && up_dmem_rlast) dr_out <= 0;
            if (up_imem_arvalid && up_imem_arready) begin im_owner <= im_sel; im_out <= 1; end
            if (up_dmem_arvalid && up_dmem_arready) begin dr_owner <= dr_sel; dr_out <= 1; end
            if (up_dmem_awvalid && up_dmem_awready) begin dw_owner <= dw_sel; dw_active <= 1; end
            if (up_dmem_bvalid && up_dmem_bready) dw_active <= 0;
        end
    end

    // ---- island memory ----
    initial begin
        for (k = 0; k < ROM_WORDS; k = k + 1) rom[k] = 64'b0;
        if (ROM_HEX != "") $readmemh(ROM_HEX, rom);
    end
    assign i_in_rom = {{(32-WIN_AW){1'b0}}, i_addr} >= ROM_BASE &&
                      {{(32-WIN_AW){1'b0}}, i_addr} < ROM_END;
    assign d_in_rom = {{(32-WIN_AW){1'b0}}, d_addr} >= ROM_BASE &&
                      {{(32-WIN_AW){1'b0}}, d_addr} < ROM_END;
    assign d_in_sram = {{(32-WIN_AW){1'b0}}, d_addr} >= SRAM_BASE &&
                       {{(32-WIN_AW){1'b0}}, d_addr} < SRAM_END;
    always @* begin
        i_rdata_mem = 64'b0; i_err = 1'b1;
        if (i_in_rom && !i_write) begin
            i_rdata_mem = rom[({{(32-WIN_AW){1'b0}}, i_addr} - ROM_BASE) >> 3]; i_err = 1'b0;
        end
        d_rdata_mem = 64'b0; d_err = 1'b1;
        if (d_in_rom && !d_write) begin
            d_rdata_mem = rom[({{(32-WIN_AW){1'b0}}, d_addr} - ROM_BASE) >> 3]; d_err = 1'b0;
        end else if (d_in_sram) begin
            d_rdata_mem = sram[({{(32-WIN_AW){1'b0}}, d_addr} - SRAM_BASE) >> 3]; d_err = 1'b0;
        end
    end
    always @(posedge clk) begin
        if (d_req && d_write && d_in_sram)
            for (k = 0; k < 8; k = k + 1)
                if (d_be[k]) sram[({{(32-WIN_AW){1'b0}}, d_addr} - SRAM_BASE) >> 3][8*k +: 8] <= d_wdata[8*k +: 8];
    end
    wire unused_i;
    assign unused_i = &{1'b0, i_wdata, i_be};

    karudbg_axi #(.BASE_ADDR(32'h0), .WIN_AW(WIN_AW)) i_bridge (
        .clk(clk), .rst(rst), .allow_i(1'b1),
        .s_arid(up_imem_arid), .s_araddr(up_imem_araddr), .s_arlen(up_imem_arlen),
        .s_arsize(up_imem_arsize), .s_arburst(up_imem_arburst), .s_arprot(up_imem_arprot),
        .s_arvalid(up_imem_arvalid && im_sel), .s_arready(i_arready),
        .s_rid(i_rid), .s_rdata(i_rdata), .s_rresp(i_rresp), .s_rlast(i_rlast),
        .s_rvalid(i_rvalid), .s_rready(up_imem_rready && im_owner),
        .s_awid({`AXI_ID_W{1'b0}}), .s_awaddr(32'b0), .s_awlen(8'b0), .s_awsize(3'b0),
        .s_awburst(2'b0), .s_awprot(3'b0), .s_awvalid(1'b0), .s_awready(),
        .s_wdata(64'b0), .s_wstrb(8'b0), .s_wlast(1'b0), .s_wvalid(1'b0), .s_wready(),
        .s_bid(), .s_bresp(), .s_bvalid(), .s_bready(1'b0),
        .mem_req_o(i_req), .mem_write_o(i_write), .mem_addr_o(i_addr),
        .mem_wdata_o(i_wdata), .mem_be_o(i_be),
        .mem_rdata_i(i_rdata_mem), .mem_ready_i(1'b1), .mem_error_i(i_err));
    karudbg_axi #(.BASE_ADDR(32'h0), .WIN_AW(WIN_AW)) d_bridge (
        .clk(clk), .rst(rst), .allow_i(1'b1),
        .s_arid(up_dmem_arid), .s_araddr(up_dmem_araddr), .s_arlen(up_dmem_arlen),
        .s_arsize(up_dmem_arsize), .s_arburst(up_dmem_arburst), .s_arprot(up_dmem_arprot),
        .s_arvalid(up_dmem_arvalid && dr_sel), .s_arready(d_arready),
        .s_rid(d_rid), .s_rdata(d_rdata), .s_rresp(d_rresp), .s_rlast(d_rlast),
        .s_rvalid(d_rvalid), .s_rready(up_dmem_rready && dr_owner),
        .s_awid(up_dmem_awid), .s_awaddr(up_dmem_awaddr), .s_awlen(up_dmem_awlen),
        .s_awsize(up_dmem_awsize), .s_awburst(up_dmem_awburst), .s_awprot(up_dmem_awprot),
        .s_awvalid(up_dmem_awvalid && !dw_active && dw_sel), .s_awready(d_awready),
        .s_wdata(up_dmem_wdata), .s_wstrb(up_dmem_wstrb), .s_wlast(up_dmem_wlast),
        .s_wvalid(up_dmem_wvalid && dw_route_valid && dw_route), .s_wready(d_wready),
        .s_bid(d_bid), .s_bresp(d_bresp), .s_bvalid(d_bvalid),
        .s_bready(up_dmem_bready && dw_owner),
        .mem_req_o(d_req), .mem_write_o(d_write), .mem_addr_o(d_addr),
        .mem_wdata_o(d_wdata), .mem_be_o(d_be),
        .mem_rdata_i(d_rdata_mem), .mem_ready_i(1'b1), .mem_error_i(d_err));

    // synthesis translate_off
    // C9 shape: while a channel is owned by the island, nothing from the
    // external side reaches the core's response port, and island requests
    // never appear downstream.
    always @(posedge clk) begin
        if (!rst) begin
            if ((up_imem_arvalid && im_sel && dn_imem_arvalid) ||
                (up_dmem_arvalid && dr_sel && dn_dmem_arvalid) ||
                (up_dmem_awvalid && dw_sel && dn_dmem_awvalid))
                $fatal(1, "karudbg_island: island request leaked downstream");
            // External responses are consumed only for an outstanding
            // external transaction accepted in an earlier cycle.
            if ((dn_imem_rready && (!im_out || im_owner)) ||
                (dn_dmem_rready && (!dr_out || dr_owner)) ||
                (dn_dmem_bready && (!dw_active || dw_owner)))
                $fatal(1, "karudbg_island: external response accepted outside an external transaction");
            if ((up_imem_rvalid && im_owner && !i_rvalid) ||
                (up_dmem_rvalid && dr_owner && !d_rvalid) ||
                (up_dmem_bvalid && dw_owner && !d_bvalid))
                $fatal(1, "karudbg_island: island request completed by a non-island response");
        end
    end
    // synthesis translate_on
endmodule
