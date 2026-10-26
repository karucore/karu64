// AXI64 slave adapter for the karudbg memory window.
// SPDX-License-Identifier: BSD-2-Clause
// One read and one write may be buffered; the DM memory port is serialized.
// Native single-beat accesses are supported. Unsupported bursts are completed
// with error responses, without accessing DM. Authorization is sampled at
// AR/AW acceptance, before upstream arbitration can lose requester identity.
module karudbg_axi #(
    parameter integer ADDR_W=32,
    parameter integer ID_W=4,
    parameter [ADDR_W-1:0] BASE_ADDR=32'h0012_0000
) (
    input wire clk, input wire rst, input wire allow_i,
    input wire [ID_W-1:0] s_arid,
    input wire [ADDR_W-1:0] s_araddr,
    input wire [7:0] s_arlen, input wire [2:0] s_arsize,
    input wire [1:0] s_arburst, input wire [2:0] s_arprot,
    input wire s_arvalid, output wire s_arready,
    output reg [ID_W-1:0] s_rid, output reg [63:0] s_rdata,
    output reg [1:0] s_rresp, output reg s_rlast,
    output reg s_rvalid, input wire s_rready,
    input wire [ID_W-1:0] s_awid,
    input wire [ADDR_W-1:0] s_awaddr,
    input wire [7:0] s_awlen, input wire [2:0] s_awsize,
    input wire [1:0] s_awburst, input wire [2:0] s_awprot,
    input wire s_awvalid, output wire s_awready,
    input wire [63:0] s_wdata, input wire [7:0] s_wstrb,
    input wire s_wlast, input wire s_wvalid, output wire s_wready,
    output reg [ID_W-1:0] s_bid, output reg [1:0] s_bresp,
    output reg s_bvalid, input wire s_bready,
    output wire mem_req_o, output wire mem_write_o,
    output wire [11:0] mem_addr_o, output wire [63:0] mem_wdata_o,
    output wire [7:0] mem_be_o,
    input wire [63:0] mem_rdata_i, input wire mem_ready_i,
    input wire mem_error_i
);
    localparam [1:0] IDLE=0, READ=1, WRITE=2;
    reg [1:0] state;
    reg rd_pending, aw_pending, w_pending;
    reg [ADDR_W-1:0] rd_address, wr_address;
    reg [ID_W-1:0] rd_id, wr_id;
    reg [1:0] rd_error, wr_error;
    reg [7:0] rd_len, wr_len, rd_remaining, wr_count;
    reg [63:0] wr_data;
    reg [7:0] wr_be;
    reg wr_last;
    wire unused_prot;
    assign unused_prot = &{1'b0,s_arprot,s_awprot};
    assign s_arready = !rd_pending && !s_rvalid;
    assign s_awready = !aw_pending && !s_bvalid;
    assign s_wready = !w_pending && !s_bvalid;
    assign mem_req_o = state != IDLE;
    assign mem_write_o = state == WRITE;
    assign mem_addr_o = state == READ ? rd_address[11:0] : wr_address[11:0];
    assign mem_wdata_o = wr_data;
    assign mem_be_o = wr_be;

    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE;
            rd_pending<=0; aw_pending<=0; w_pending<=0;
            s_rvalid<=0; s_bvalid<=0;
            s_rid<=0; s_rdata<=0; s_rresp<=0; s_rlast<=1;
            s_bid<=0; s_bresp<=0;
            rd_remaining<=0; wr_count<=0;
        end else begin
            if (s_arvalid && s_arready) begin
                rd_pending<=1; rd_address<=s_araddr; rd_id<=s_arid;
                rd_len<=s_arlen;
                if (!allow_i || s_araddr[ADDR_W-1:12] != BASE_ADDR[ADDR_W-1:12])
                    rd_error<=2'b11;
                else if (s_arlen != 0 || s_arsize > 3 || s_arburst > 1)
                    rd_error<=2'b10;
                else rd_error<=0;
            end
            if (s_awvalid && s_awready) begin
                aw_pending<=1; wr_address<=s_awaddr; wr_id<=s_awid;
                wr_len<=s_awlen; wr_count<=0;
                if (!allow_i || s_awaddr[ADDR_W-1:12] != BASE_ADDR[ADDR_W-1:12])
                    wr_error<=2'b11;
                else if (s_awlen != 0 || s_awsize > 3 || s_awburst > 1)
                    wr_error<=2'b10;
                else wr_error<=0;
            end
            if (s_wvalid && s_wready) begin
                w_pending<=1; wr_data<=s_wdata; wr_be<=s_wstrb; wr_last<=s_wlast;
            end
            if (s_rvalid && s_rready) begin
                if (rd_remaining != 0) begin
                    rd_remaining<=rd_remaining-1'b1;
                    s_rlast<=rd_remaining == 1;
                end else s_rvalid<=0;
            end
            if (s_bvalid && s_bready) s_bvalid<=0;

            case (state)
                IDLE: begin
                    if (rd_pending && !s_rvalid) begin
                        if (rd_error != 0) begin
                            rd_pending<=0; s_rvalid<=1; s_rid<=rd_id;
                            s_rdata<=0; s_rresp<=rd_error;
                            rd_remaining<=rd_len; s_rlast<=rd_len == 0;
                        end else state<=READ;
                    end else if (aw_pending && w_pending && !s_bvalid) begin
                        if (wr_error != 0 || wr_len != 0 || !wr_last) begin
                            // Drain rejected bursts so they cannot contaminate
                            // a later write; WLAST/length mismatch is SLVERR.
                            w_pending<=0;
                            if (wr_last || wr_count == wr_len) begin
                                aw_pending<=0; s_bvalid<=1; s_bid<=wr_id;
                                s_bresp<=wr_error != 0 ? wr_error : 2'b10;
                            end else wr_count<=wr_count+1'b1;
                        end else state<=WRITE;
                    end
                end
                READ: if (mem_ready_i) begin
                    rd_pending<=0; s_rvalid<=1; s_rid<=rd_id;
                    s_rdata<=mem_rdata_i; s_rresp<=mem_error_i ? 2'b10 : 2'b00;
                    rd_remaining<=0; s_rlast<=1; state<=IDLE;
                end
                WRITE: if (mem_ready_i) begin
                    aw_pending<=0; w_pending<=0; s_bvalid<=1; s_bid<=wr_id;
                    s_bresp<=mem_error_i ? 2'b10 : 2'b00; state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
