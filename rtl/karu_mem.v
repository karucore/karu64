//  karu_mem.v
//  Shared data-memory subsystem: an AXI4 L1 data cache between the load/
//  store unit(s) and the dmem AXI master port. Two client front-ends share
//  one cache + one AXI master:
//    - AXI4 slave port (the scalar/FP karu_lsu connects unchanged), 64-bit.
//    - a 128-bit vector port (req/done) for karu_vlsu.
//  The core is single-issue/in-order (karu_assert INV1), so the two are
//  never active at once; arbitration is a priority mux (scalar first).
//
//    LSU (AXI) ─┐
//               ├─► [arb → translate → L1 → AXI] ─► dmem
//    vlsu (128) ┘
//
//  Design (see doc/architecture.md / memory-consistency notes): direct-mapped,
//  write-through, 64-byte line. Read miss refills the line via an AXI INCR
//  burst (8x64-bit); stores write through (write-no-allocate). A 128-bit
//  vector access reads straight out of the 512-bit line (one access); a
//  128-bit store / uncacheable 128-bit load uses two 64-bit AXI beats.
//  Uncacheable bypass for the HTIF/MMIO page (`uncache_page`) and non-RAM
//  addresses keeps the device-polled `tohost` coherent (RVWMO: I/O is
//  non-cacheable). `xlate()` is the identity Sv39/Sv48 hook, shared by all
//  clients.

`include "karu_ext.vh"
`include "karu_axi_defs.vh"

module karu_mem #(
    parameter integer IDXW = 6              //  log2(sets); 64 sets x 64B = 4 KiB
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [31:0]  uncache_page,

    //  ==================== AXI4 slave (scalar/FP LSU) ====================
    input  wire [`AXI_ID_W-1:0]     s_arid,
    input  wire [`AXI_ADDR_W-1:0]   s_araddr,
    input  wire [`AXI_LEN_W-1:0]    s_arlen,
    input  wire [`AXI_SIZE_W-1:0]   s_arsize,
    input  wire [`AXI_BURST_W-1:0]  s_arburst,
    input  wire [`AXI_PROT_W-1:0]   s_arprot,
    input  wire                     s_arvalid,
    output reg                      s_arready,
    output reg  [`AXI_ID_W-1:0]     s_rid,
    output reg  [`AXI_DATA_W-1:0]   s_rdata,
    output reg  [`AXI_RESP_W-1:0]   s_rresp,
    output reg                      s_rlast,
    output reg                      s_rvalid,
    input  wire                     s_rready,
    input  wire [`AXI_ID_W-1:0]     s_awid,
    input  wire [`AXI_ADDR_W-1:0]   s_awaddr,
    input  wire [`AXI_LEN_W-1:0]    s_awlen,
    input  wire [`AXI_SIZE_W-1:0]   s_awsize,
    input  wire [`AXI_BURST_W-1:0]  s_awburst,
    input  wire [`AXI_PROT_W-1:0]   s_awprot,
    input  wire                     s_awvalid,
    output reg                      s_awready,
    input  wire [`AXI_DATA_W-1:0]   s_wdata,
    input  wire [`AXI_STRB_W-1:0]   s_wstrb,
    input  wire                     s_wlast,
    input  wire                     s_wvalid,
    output reg                      s_wready,
    output reg  [`AXI_ID_W-1:0]     s_bid,
    output reg  [`AXI_RESP_W-1:0]   s_bresp,
    output reg                      s_bvalid,
    input  wire                     s_bready,

    //  ==================== vector port (128-bit) ====================
    input  wire                     v_req,          //  pulse to start
    output wire                     v_busy,         //  can't accept v_req
    input  wire                     v_is_store,
    input  wire [31:0]              v_addr,         //  16-byte aligned
    input  wire [127:0]             v_wdata,
    input  wire [15:0]              v_wstrb,
    output reg                      v_done,
    output reg  [127:0]             v_rdata,

    //  ==================== AXI4 master (to dmem) ====================
    output reg  [`AXI_ID_W-1:0]     m_arid,
    output reg  [`AXI_ADDR_W-1:0]   m_araddr,
    output reg  [`AXI_LEN_W-1:0]    m_arlen,
    output reg  [`AXI_SIZE_W-1:0]   m_arsize,
    output reg  [`AXI_BURST_W-1:0]  m_arburst,
    output reg  [`AXI_PROT_W-1:0]   m_arprot,
    output reg                      m_arvalid,
    input  wire                     m_arready,
    input  wire [`AXI_ID_W-1:0]     m_rid,
    input  wire [`AXI_DATA_W-1:0]   m_rdata,
    input  wire [`AXI_RESP_W-1:0]   m_rresp,
    input  wire                     m_rlast,
    input  wire                     m_rvalid,
    output reg                      m_rready,
    output reg  [`AXI_ID_W-1:0]     m_awid,
    output reg  [`AXI_ADDR_W-1:0]   m_awaddr,
    output reg  [`AXI_LEN_W-1:0]    m_awlen,
    output reg  [`AXI_SIZE_W-1:0]   m_awsize,
    output reg  [`AXI_BURST_W-1:0]  m_awburst,
    output reg  [`AXI_PROT_W-1:0]   m_awprot,
    output reg                      m_awvalid,
    input  wire                     m_awready,
    output reg  [`AXI_DATA_W-1:0]   m_wdata,
    output reg  [`AXI_STRB_W-1:0]   m_wstrb,
    output reg                      m_wlast,
    output reg                      m_wvalid,
    input  wire                     m_wready,
    input  wire [`AXI_ID_W-1:0]     m_bid,
    input  wire [`AXI_RESP_W-1:0]   m_bresp,
    input  wire                     m_bvalid,
    output reg                      m_bready
);
    localparam SETS  = (1 << IDXW);
    localparam OFFW  = 6;
    localparam TAGW  = 32 - OFFW - IDXW;

    reg [511:0]     line_data [0:SETS-1];
    reg [TAGW-1:0]  line_tag  [0:SETS-1];
    reg [SETS-1:0]  line_valid;

    function [31:0] xlate; input [31:0] va; begin xlate = va; end endfunction

    //  ---- request register ----
    reg [31:0]      req_pa;
    reg [`AXI_ID_W-1:0] req_id;
    reg             req_is_store;
    reg             req_src;        //  0 = scalar AXI, 1 = vector port
    reg             req_w128;       //  1 = 128-bit (vector) access
    reg [127:0]     req_wdata;
    reg [15:0]      req_wstrb;

    wire [IDXW-1:0] req_idx  = req_pa[OFFW+IDXW-1:OFFW];
    wire [TAGW-1:0] req_tag  = req_pa[31:OFFW+IDXW];
    wire [2:0]      req_word = req_pa[5:3];     //  64-bit word in line
    wire [1:0]      req_dw   = req_pa[5:4];     //  128-bit dword in line
    wire            req_uncacheable =
        (req_pa[31:12] == uncache_page[31:12]) || (req_pa[31:28] != 4'h8);
    wire            req_hit = line_valid[req_idx] && (line_tag[req_idx] == req_tag);
    wire [511:0]    hit_line = line_data[req_idx];
    wire [63:0]     hit_word = hit_line[req_word*64 +: 64];
    wire [127:0]    hit_dw   = hit_line[req_dw*128 +: 128];

    localparam S_IDLE=4'd0, S_RD=4'd1, S_FILL_R=4'd2, S_FILL_DONE=4'd3,
               S_UC_AR=4'd4, S_UC_R=4'd5, S_RESP=4'd6, S_WR=4'd7, S_WR_B=4'd8;
    reg [3:0]   state;
    reg [2:0]   fill_cnt;
    reg [511:0] fill_buf;
    reg         beat;           //  0/1 for 128-bit two-beat ops
    reg [63:0]  uc_lo;          //  low 64 of an uncacheable 128-bit load

    assign v_busy = (state != S_IDLE);

    integer bi;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; line_valid <= {SETS{1'b0}};
            s_arready<=0; s_rvalid<=0; s_awready<=0; s_wready<=0; s_bvalid<=0;
            m_arvalid<=0; m_rready<=0; m_awvalid<=0; m_wvalid<=0; m_bready<=0;
            v_done<=0;
        end else begin
            s_arready<=0; s_awready<=0; s_wready<=0; v_done<=0;
            case (state)
                S_IDLE: begin
                    s_rvalid<=0; s_bvalid<=0;
                    //  priority: scalar AXI first (single-issue: no overlap)
                    if (s_arvalid) begin
                        req_pa<=xlate(s_araddr); req_id<=s_arid;
                        req_src<=1'b0; req_w128<=1'b0; req_is_store<=1'b0;
                        s_arready<=1'b1; state<=S_RD;
                    end else if (s_awvalid && s_wvalid) begin
                        req_pa<=xlate(s_awaddr); req_id<=s_awid;
                        req_src<=1'b0; req_w128<=1'b0; req_is_store<=1'b1;
                        req_wdata<={64'b0,s_wdata}; req_wstrb<={8'b0,s_wstrb};
                        s_awready<=1'b1; s_wready<=1'b1; beat<=1'b0; state<=S_WR;
                    end else if (v_req) begin
                        req_pa<=xlate(v_addr); req_id<=0;
                        req_src<=1'b1; req_w128<=1'b1; req_is_store<=v_is_store;
                        req_wdata<=v_wdata; req_wstrb<=v_wstrb; beat<=1'b0;
                        state <= v_is_store ? S_WR : S_RD;
                    end
                end

                //  -------- read: hit / miss / uncacheable --------
                S_RD: begin
                    if (req_uncacheable) begin
                        m_arid<=req_id; m_araddr<=req_w128 ? {req_pa[31:3],3'b000} : req_pa;
                        m_arlen<=0; m_arsize<=`AXI_SIZE_8B; m_arburst<=`AXI_BURST_INCR;
                        m_arprot<=0; m_arvalid<=1; m_rready<=1; beat<=1'b0; state<=S_UC_AR;
                    end else if (req_hit) begin
                        v_rdata <= hit_dw;
                        s_rid<=req_id; s_rdata<=hit_word; s_rresp<=`AXI_RESP_OKAY;
                        s_rlast<=1; s_rvalid<=!req_src; v_done<=req_src;
                        state <= req_src ? S_IDLE : S_RESP;
                    end else begin
                        m_arid<=req_id; m_araddr<={req_pa[31:6],6'b0};
                        m_arlen<=8'd7; m_arsize<=`AXI_SIZE_8B; m_arburst<=`AXI_BURST_INCR;
                        m_arprot<=0; m_arvalid<=1; m_rready<=1; fill_cnt<=0; state<=S_FILL_R;
                    end
                end
                S_FILL_R: begin
                    if (m_arvalid && m_arready) m_arvalid<=0;
                    if (m_rvalid && m_rready) begin
                        fill_buf[fill_cnt*64 +: 64] <= m_rdata;
                        if (m_rlast) begin m_rready<=0; state<=S_FILL_DONE; end
                        fill_cnt <= fill_cnt + 3'd1;
                    end
                end
                S_FILL_DONE: begin
                    line_data[req_idx]<=fill_buf; line_tag[req_idx]<=req_tag;
                    line_valid[req_idx]<=1'b1;
                    v_rdata <= fill_buf[req_dw*128 +: 128];
                    s_rid<=req_id; s_rdata<=fill_buf[req_word*64 +: 64];
                    s_rresp<=`AXI_RESP_OKAY; s_rlast<=1; s_rvalid<=!req_src; v_done<=req_src;
                    state <= req_src ? S_IDLE : S_RESP;
                end

                //  -------- uncacheable read (64, or 128 in two beats) --------
                S_UC_AR: begin
                    if (m_arvalid && m_arready) m_arvalid<=0;
                    if (m_rvalid && m_rready) begin
                        m_rready<=0;
                        if (req_w128 && beat==1'b0) begin
                            uc_lo <= m_rdata; beat<=1'b1;
                            m_araddr<={req_pa[31:3],3'b000}+32'd8;
                            m_arvalid<=1; m_rready<=1;  //  issue second beat
                        end else begin
                            v_rdata <= req_w128 ? {m_rdata, uc_lo} : {64'b0, m_rdata};
                            s_rid<=req_id; s_rdata<=m_rdata; s_rresp<=`AXI_RESP_OKAY;
                            s_rlast<=1; s_rvalid<=!req_src; v_done<=req_src;
                            state <= req_src ? S_IDLE : S_RESP;
                        end
                    end
                end

                S_RESP: begin   //  scalar: hold R/B until taken
                    if (s_rvalid && s_rready) begin s_rvalid<=0; state<=S_IDLE; end
                    if (s_bvalid && s_bready) begin s_bvalid<=0; state<=S_IDLE; end
                end

                //  -------- store (write-through; 128 = two beats) --------
                S_WR: begin
                    //  update cached line in place (no-allocate)
                    if (!req_uncacheable && line_valid[req_idx]
                        && (line_tag[req_idx]==req_tag)) begin
                        if (req_w128) begin
                            for (bi=0; bi<16; bi=bi+1)
                                if (req_wstrb[bi])
                                    line_data[req_idx][(req_dw*128)+bi*8 +: 8] <= req_wdata[bi*8 +: 8];
                        end else begin
                            for (bi=0; bi<8; bi=bi+1)
                                if (req_wstrb[bi])
                                    line_data[req_idx][(req_word*64)+bi*8 +: 8] <= req_wdata[bi*8 +: 8];
                        end
                    end
                    //  write the current 64-bit beat through to memory
                    m_awid<=req_id;
                    m_awaddr<= (req_w128 && beat) ? ({req_pa[31:4],4'b0}+32'd8)
                                                  : {req_pa[31:3],3'b000};
                    m_awlen<=0; m_awsize<=`AXI_SIZE_8B; m_awburst<=`AXI_BURST_INCR; m_awprot<=0;
                    m_awvalid<=1;
                    m_wdata<= beat ? req_wdata[127:64] : req_wdata[63:0];
                    m_wstrb<= beat ? req_wstrb[15:8]   : req_wstrb[7:0];
                    m_wlast<=1; m_wvalid<=1; m_bready<=1; state<=S_WR_B;
                end
                S_WR_B: begin
                    if (m_awvalid && m_awready) m_awvalid<=0;
                    if (m_wvalid && m_wready)   m_wvalid<=0;
                    if (m_bvalid && m_bready) begin
                        m_bready<=0;
                        if (req_w128 && beat==1'b0) begin
                            beat<=1'b1; state<=S_WR;        //  second 64-bit beat
                        end else if (req_src) begin
                            v_done<=1'b1; state<=S_IDLE;
                        end else begin
                            s_bid<=req_id; s_bresp<=`AXI_RESP_OKAY; s_bvalid<=1; state<=S_RESP;
                        end
                    end
                end
            endcase
        end
    end

    wire _unused = &{s_arlen,s_arsize,s_arburst,s_arprot,s_awlen,s_awsize,
                     s_awburst,s_awprot,s_wlast,m_rid,m_rresp,m_bid,m_bresp,1'b0};
endmodule
