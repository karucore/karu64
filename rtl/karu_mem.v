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
//  Cacheable vector stores use one two-beat burst when both halves are active,
//  and may acknowledge into the active slot before B. One additional vector
//  request can wait in vq; it is serviced only after the current response.
//  The VLSU retains the instruction until store_pending drains, allowing a
//  late B error to trap with its saved VA. FENCE/AMO/MMIO and interrupts cannot
//  pass a buffered write. No multiple-outstanding AXI.
//  Svpbmt NC/IO requests bypass both cache hits and allocation. IO vector
//  accesses use exact active-element transfers, with no posting or bursts:
//  unlike idempotent NC, IO must not access masked/inactive bytes. Physical
//  memory attributes and access checks remain the requester's responsibility.
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
    input  wire         flush,          // invalidate write-through D-cache

    //  ==================== AXI4 slave (scalar/FP LSU) ====================
    input  wire [`AXI_ID_W-1:0]     s_arid,
    input  wire [`AXI_ADDR_W-1:0]   s_araddr,
    input  wire [`AXI_LEN_W-1:0]    s_arlen,
    input  wire [`AXI_SIZE_W-1:0]   s_arsize,
    input  wire [`AXI_BURST_W-1:0]  s_arburst,
    input  wire [`AXI_PROT_W-1:0]   s_arprot,
    input  wire [1:0]               s_ar_pbmt,
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
    input  wire [1:0]               s_aw_pbmt,
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
    input  wire                     v_allow_post,   // contiguous RAM stream
    input  wire [31:0]              v_addr,         //  16-byte aligned
    input  wire [63:0]              v_va,           // virtual granule for fault reporting
    input  wire [127:0]             v_wdata,
    input  wire [15:0]              v_wstrb,
    input  wire [1:0]               v_pbmt,        // 0=PMA, 1=NC, 2=IO
    input  wire [1:0]               v_size,        // log2(element bytes)
    input  wire [15:0]              v_rstrb,       // active load bytes
    output reg                      v_done,
    output reg  [127:0]             v_rdata,
    output reg                      v_fault,        // may follow a posted done
    output reg  [63:0]              v_fault_va,
    output wire                    store_pending,

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
    `include "karu_pma.vh"
    localparam SETS  = (1 << IDXW);
    localparam OFFW  = 6;
    localparam TAGW  = 32 - OFFW - IDXW;

    //  Cache data/tag arrays live in leaf RAM wrappers for ASIC macro
    //  substitution. Valid bits remain local control state.
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
    reg [15:0]      req_rstrb;
    reg [1:0]       req_pbmt;
    reg [2:0]       req_size;
    reg             req_posted;
    reg [63:0]      req_va, vq_va;
    // One waiting vector granule in addition to the active transaction.
    // Only cacheable stores acknowledge before B; all reads and device
    // accesses remain ordered behind the active write and its response.
    reg             vq_valid, vq_store, vq_allow_post;
    reg [31:0]      vq_addr;
    reg [127:0]     vq_data;
    reg [15:0]      vq_strb;
    reg [15:0]      vq_rstrb;
    reg [1:0]       vq_pbmt, vq_size;
    wire vq_io = vq_pbmt == 2 || (vq_pbmt == 0 && karu_pma_io({32'b0,vq_addr}));
    wire v_io = v_pbmt == 2 || (v_pbmt == 0 && karu_pma_io({32'b0,v_addr}));
    // Standard-map RAM spans the full upper 2 GiB, as in karu_pma.vh.
    wire vq_post = vq_allow_post && vq_store && vq_pbmt == 0 && vq_addr[31] &&
                   !vq_io && vq_addr[31:12] != uncache_page[31:12];
    wire v_post = v_allow_post && v_is_store && v_pbmt == 0 && v_addr[31] &&
                  !v_io && v_addr[31:12] != uncache_page[31:12];

    wire [IDXW-1:0] req_idx  = req_pa[OFFW+IDXW-1:OFFW];
    wire [TAGW-1:0] req_tag  = req_pa[31:OFFW+IDXW];
    wire [2:0]      req_word = req_pa[5:3];     //  64-bit word in line
    wire [1:0]      req_dw   = req_pa[5:4];     //  128-bit dword in line
    wire            req_uncacheable =
        (req_pbmt != 0) || karu_pma_io({32'b0,req_pa}) ||
        (req_pa[31:12] == uncache_page[31:12]) || !req_pa[31];
    // Only cacheable RAM may receive a two-beat INCR burst. Device and boot
    // targets keep single beats; suppress empty halves before issuing AW.
    wire req_burst = req_w128 && !req_uncacheable &&
                     (|req_wstrb[7:0]) && (|req_wstrb[15:8]);
    wire [511:0]    hit_line;
    wire [TAGW-1:0] hit_tag;
    wire            req_hit = line_valid[req_idx] && (hit_tag == req_tag);
    wire [63:0]     hit_word = hit_line[req_word*64 +: 64];
    wire [127:0]    hit_dw   = hit_line[req_dw*128 +: 128];

    localparam S_IDLE=4'd0, S_RD=4'd1, S_FILL_R=4'd2, S_FILL_DONE=4'd3,
               S_UC_AR=4'd4, S_UC_R=4'd5, S_RESP=4'd6, S_WR=4'd7, S_WR_B=4'd8,
               S_VERR=4'd9, S_IO_NEXT=4'd10, S_IO_R=4'd11, S_IO_W=4'd12;
    reg [3:0]   state;
    reg [2:0]   fill_cnt;
    reg [511:0] fill_buf;
    reg [1:0]   fill_resp;
    reg         fill_poison;
    reg         beat;           //  0/1 for 128-bit two-beat ops
    reg [63:0]  uc_lo;          //  low 64 of an uncacheable 128-bit load

    // Small serial IO sequencer, off the cache-hit path. Scan at most 16
    // bytes, combining only a complete, naturally aligned active element.
    // A partial/misaligned element is deliberately split into exact bytes;
    // no operand-dependent divide, modulo, or wide priority encoder is needed.
    reg [4:0]   io_off;
    reg [3:0]   io_step;
    reg [7:0]   io_strb;
    reg [127:0] io_data;
    integer ib;
    wire [15:0] io_mask = req_is_store ? req_wstrb : req_rstrb;
    wire [15:0] io_mask_tail = io_mask >> io_off[3:0];
    reg [2:0]   io_size;
    reg [3:0]   io_bytes;
    reg [7:0]   io_lane_mask;
    always @(*) begin
        io_size = 0; io_bytes = 1; io_lane_mask = 8'h01;
        case (req_size)
            3'd1: if (!io_off[0] && (&io_mask_tail[1:0])) begin
                io_size = 1; io_bytes = 2; io_lane_mask = 8'h03;
            end
            3'd2: if (io_off[1:0] == 0 && (&io_mask_tail[3:0])) begin
                io_size = 2; io_bytes = 4; io_lane_mask = 8'h0f;
            end
            3'd3: if (io_off[2:0] == 0 && (&io_mask_tail[7:0])) begin
                io_size = 3; io_bytes = 8; io_lane_mask = 8'hff;
            end
            default: begin end
        endcase
        io_lane_mask = io_lane_mask << io_off[2:0];
    end

    reg [511:0]     store_line;
    integer         line_bi;
    always @(*) begin
        store_line = hit_line;
        if (req_w128) begin
            for (line_bi = 0; line_bi < 16; line_bi = line_bi + 1)
                if (req_wstrb[line_bi])
                    store_line[(req_dw*128)+line_bi*8 +: 8] = req_wdata[line_bi*8 +: 8];
        end else begin
            for (line_bi = 0; line_bi < 8; line_bi = line_bi + 1)
                if (req_wstrb[line_bi])
                    store_line[(req_word*64)+line_bi*8 +: 8] = req_wdata[line_bi*8 +: 8];
        end
    end

    wire            store_hit_we = (state == S_WR) && !req_uncacheable &&
                                   line_valid[req_idx] && (hit_tag == req_tag);
    wire            fill_we = (state == S_FILL_DONE) && !fill_resp[1] && !fill_poison && !flush;
    wire            line_data_we = fill_we || store_hit_we;
    wire [511:0]    line_data_wdata = fill_we ? fill_buf : store_line;
    karu_1w1r_async_ram #(
        .DATA_W(512), .DEPTH(SETS), .ADDR_W(IDXW)
    ) line_data_u (
        .clk(clk),
        .we(line_data_we), .waddr(req_idx), .wdata(line_data_wdata),
        .raddr(req_idx), .rdata(hit_line)
    );
    karu_1w1r_async_ram #(
        .DATA_W(TAGW), .DEPTH(SETS), .ADDR_W(IDXW)
    ) line_tag_u (
        .clk(clk),
        .we(fill_we), .waddr(req_idx), .wdata(req_tag),
        .raddr(req_idx), .rdata(hit_tag)
    );

    assign v_busy = vq_valid || state == S_VERR;
    assign store_pending = vq_valid || ((state != S_IDLE) && req_src && req_is_store);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; line_valid <= {SETS{1'b0}};
            s_arready<=0; s_rvalid<=0; s_awready<=0; s_wready<=0; s_bvalid<=0;
            m_arvalid<=0; m_rready<=0; m_awvalid<=0; m_wvalid<=0; m_bready<=0;
            v_done<=0; v_fault<=0;
            vq_valid<=0; req_posted<=0;
            fill_poison<=0;
        end else begin
            s_arready<=0; s_awready<=0; s_wready<=0; v_done<=0; v_fault<=0;
            if (v_req && state != S_IDLE && state != S_VERR && !vq_valid) begin
                vq_valid<=1; vq_store<=v_is_store; vq_addr<=v_addr;
                vq_allow_post<=v_allow_post;
                vq_va<=v_va;
                vq_data<=v_wdata; vq_strb<=v_wstrb;
                vq_pbmt<=v_pbmt; vq_size<=v_size; vq_rstrb<=v_rstrb;
            end
            case (state)
                S_IDLE: begin
                    s_rvalid<=0; s_bvalid<=0;
                    //  priority: scalar AXI first (single-issue: no overlap)
                    if (vq_valid) begin
                        vq_valid<=0;
                        req_pa<=vq_addr; req_id<=0;
                        req_va<=vq_va;
                        req_src<=1; req_w128<=1; req_is_store<=vq_store;
                        req_wdata<=vq_data; req_wstrb<=vq_strb;
                        req_pbmt<=vq_pbmt; req_size<={1'b0,vq_size}; req_rstrb<=vq_rstrb;
                        io_off<=0; io_data<=0;
                        beat<=!(|vq_strb[7:0]) && (|vq_strb[15:8]);
                        req_posted<=vq_post; v_done<=vq_post;
                        state<=vq_io ? S_IO_NEXT : (vq_store ? S_WR : S_RD);
                    end else if (s_arvalid) begin
                        req_pa<=xlate(s_araddr); req_id<=s_arid;
                        req_src<=1'b0; req_w128<=1'b0; req_is_store<=1'b0;
                        req_posted<=0;
                        req_pbmt<=s_ar_pbmt; req_size<=s_arsize;
                        s_arready<=1'b1; state<=S_RD;
                    end else if (s_awvalid && s_wvalid) begin
                        req_pa<=xlate(s_awaddr); req_id<=s_awid;
                        req_src<=1'b0; req_w128<=1'b0; req_is_store<=1'b1;
                        req_posted<=0;
                        req_pbmt<=s_aw_pbmt; req_size<=s_awsize;
                        req_wdata<={64'b0,s_wdata}; req_wstrb<={8'b0,s_wstrb};
                        s_awready<=1'b1; s_wready<=1'b1; beat<=1'b0; state<=S_WR;
                    end else if (v_req) begin
                        req_pa<=xlate(v_addr); req_id<=0;
                        req_va<=v_va;
                        req_src<=1'b1; req_w128<=1'b1; req_is_store<=v_is_store;
                        req_posted<=v_post; v_done<=v_post;
                        req_wdata<=v_wdata; req_wstrb<=v_wstrb;
                        req_pbmt<=v_pbmt; req_size<={1'b0,v_size}; req_rstrb<=v_rstrb;
                        io_off<=0; io_data<=0;
                        beat<=!(|v_wstrb[7:0]) && (|v_wstrb[15:8]);
                        state <= v_io ? S_IO_NEXT : (v_is_store ? S_WR : S_RD);
                    end
                end
                // Give the client a cycle to observe the error. A request
                // already pulsed behind a posted failure is canceled, not sent.
                S_VERR: begin vq_valid<=0; state<=S_IDLE; end

                //  -------- read: hit / miss / uncacheable --------
                S_RD: begin
                    if (req_uncacheable) begin
                        m_arid<=req_id; m_araddr<=req_w128 ? {req_pa[31:3],3'b000} : req_pa;
                        m_arlen<=0; m_arsize<=req_w128 ? `AXI_SIZE_8B : req_size; m_arburst<=`AXI_BURST_INCR;
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
                        fill_resp<=`AXI_RESP_OKAY;
                        fill_poison<=flush;
                    end
                end
                S_FILL_R: begin
                    if (m_arvalid && m_arready) m_arvalid<=0;
                    if (m_rvalid && m_rready) begin
                        fill_buf[fill_cnt*64 +: 64] <= m_rdata;
                        if (m_rresp[1]) fill_resp<=m_rresp;
                        if (m_rlast) begin m_rready<=0; state<=S_FILL_DONE; end
                        fill_cnt <= fill_cnt + 3'd1;
                    end
                end
                S_FILL_DONE: begin
                    line_valid[req_idx]<=!fill_resp[1] && !fill_poison && !flush;
                    v_rdata <= fill_buf[req_dw*128 +: 128];
                    s_rid<=req_id; s_rdata<=fill_buf[req_word*64 +: 64];
                    s_rresp<=fill_resp; s_rlast<=1; s_rvalid<=!req_src; v_done<=req_src;
                    v_fault<=req_src && fill_resp[1]; v_fault_va<=req_va;
                    state <= req_src ? S_IDLE : S_RESP;
                end

                //  -------- uncacheable read (64, or 128 in two beats) --------
                S_UC_AR: begin
                    if (m_arvalid && m_arready) m_arvalid<=0;
                    if (m_rvalid && m_rready) begin
                        m_rready<=0;
                        if (req_w128 && beat==1'b0 && !m_rresp[1]) begin
                            uc_lo <= m_rdata; beat<=1'b1;
                            m_araddr<={req_pa[31:3],3'b000}+32'd8;
                            m_arvalid<=1; m_rready<=1;  //  issue second beat
                        end else begin
                            v_rdata <= req_w128 ? {m_rdata, uc_lo} : {64'b0, m_rdata};
                            s_rid<=req_id; s_rdata<=m_rdata; s_rresp<=m_rresp;
                            s_rlast<=1; s_rvalid<=!req_src; v_done<=req_src;
                            v_fault<=req_src && m_rresp[1]; v_fault_va<=req_va;
                            state <= req_src ? S_IDLE : S_RESP;
                        end
                    end
                end

                S_RESP: begin   //  scalar: hold R/B until taken
                    if (s_rvalid && s_rready) begin s_rvalid<=0; state<=S_IDLE; end
                    if (s_bvalid && s_bready) begin s_bvalid<=0; state<=S_IDLE; end
                end

                // IO is non-idempotent: every AXI operation below corresponds
                // to active architectural bytes, and completes before the next.
                S_IO_NEXT: begin
                    if (io_off[4]) begin
                        v_rdata<=io_data; v_done<=1; state<=S_IDLE;
                    end else if (!io_mask[io_off[3:0]]) begin
                        io_off<=io_off+5'd1;
                    end else begin
                        io_step<=io_bytes; io_strb<=io_lane_mask;
                        if (req_is_store) begin
                            m_awid<=req_id; m_awaddr<={req_pa[31:4],io_off[3:0]};
                            m_awlen<=0; m_awsize<=io_size; m_awburst<=`AXI_BURST_INCR; m_awprot<=0;
                            m_awvalid<=1; m_wvalid<=1; m_wlast<=1; m_bready<=1;
                            m_wdata<=io_off[3] ? req_wdata[127:64] : req_wdata[63:0];
                            m_wstrb<=io_lane_mask; state<=S_IO_W;
                        end else begin
                            m_arid<=req_id; m_araddr<={req_pa[31:4],io_off[3:0]};
                            m_arlen<=0; m_arsize<=io_size; m_arburst<=`AXI_BURST_INCR; m_arprot<=0;
                            m_arvalid<=1; m_rready<=1; state<=S_IO_R;
                        end
                    end
                end
                S_IO_R: begin
                    if (m_arvalid && m_arready) m_arvalid<=0;
                    if (m_rvalid && m_rready) begin
                        m_rready<=0;
                        if (m_rresp[1]) begin
                            v_fault<=1; v_done<=1; v_fault_va<={req_va[63:4],io_off[3:0]};
                            v_rdata<=io_data; // completed prefix for fault-only-first loads
                            vq_valid<=0; state<=S_VERR;
                        end else begin
                            for (ib=0; ib<8; ib=ib+1) begin
                                if (io_strb[ib]) begin
                                    if (io_off[3]) io_data[64+ib*8 +: 8]<=m_rdata[ib*8 +: 8];
                                    else io_data[ib*8 +: 8]<=m_rdata[ib*8 +: 8];
                                end
                            end
                            io_off<=io_off+{1'b0,io_step}; state<=S_IO_NEXT;
                        end
                    end
                end
                S_IO_W: begin
                    if (m_awvalid && m_awready) m_awvalid<=0;
                    if (m_wvalid && m_wready) m_wvalid<=0;
                    if (m_bvalid && m_bready) begin
                        m_bready<=0;
                        if (m_bresp[1]) begin
                            line_valid[req_idx]<=0;
                            v_fault<=1; v_done<=1; v_fault_va<={req_va[63:4],io_off[3:0]};
                            vq_valid<=0; state<=S_VERR;
                        end else begin
                            io_off<=io_off+{1'b0,io_step}; state<=S_IO_NEXT;
                        end
                    end
                end

                //  -------- store (write-through; 128 = two beats) --------
                S_WR: begin
                    //  update cached line in place (no-allocate) through line_data_u.
                    //  write the current 64-bit beat through to memory
                    m_awid<=req_id;
                    m_awaddr<= (req_w128 && beat) ? ({req_pa[31:4],4'b0}+32'd8)
                                                  : (!req_w128 && req_uncacheable ? req_pa : {req_pa[31:3],3'b000});
                    m_awlen<=req_burst ? 1 : 0;
                    m_awsize<=!req_w128 && req_uncacheable ? req_size : `AXI_SIZE_8B;
                    m_awburst<=`AXI_BURST_INCR; m_awprot<=0;
                    m_awvalid<=1;
                    m_wdata<= beat ? req_wdata[127:64] : req_wdata[63:0];
                    m_wstrb<= beat ? req_wstrb[15:8]   : req_wstrb[7:0];
                    m_wlast<=!req_burst; m_wvalid<=1; m_bready<=1; state<=S_WR_B;
                end
                S_WR_B: begin
                    if (m_awvalid && m_awready) m_awvalid<=0;
                    if (m_wvalid && m_wready) begin
                        if (req_burst && !beat) begin
                            beat<=1; m_wdata<=req_wdata[127:64];
                            m_wstrb<=req_wstrb[15:8]; m_wlast<=1;
                        end else m_wvalid<=0;
                    end
                    if (m_bvalid && m_bready) begin
                        m_bready<=0;
                        if (m_bresp[1]) begin
                            line_valid[req_idx]<=0;
                            if (req_src) begin
                                v_fault<=1; v_fault_va<=req_va;
                                v_done<=!req_posted; vq_valid<=0; state<=S_VERR;
                            end else begin
                                s_bid<=req_id; s_bresp<=m_bresp; s_bvalid<=1; state<=S_RESP;
                            end
                        end else if (req_w128 && beat==1'b0 && (|req_wstrb[15:8])) begin
                            beat<=1'b1; state<=S_WR;        //  second 64-bit beat
                        end else if (req_src) begin
                            v_done<=!req_posted; state<=S_IDLE;
                        end else begin
                            s_bid<=req_id; s_bresp<=`AXI_RESP_OKAY; s_bvalid<=1; state<=S_RESP;
                        end
                    end
                end
            endcase
            // CPU writes through an NC/IO or explicit-uncached-page alias
            // must not leave a stale cacheable alias. Invalidate before any
            // bypass write, including the separate vector IO sequencer.
            // No dirty writeback is needed in this write-through cache;
            // invalidation also covers partial success followed by a bus error.
            // Empty IO masks perform no access and keep a resident line.
            if (req_hit && (|req_wstrb) &&
                ((state == S_WR && req_uncacheable) ||
                 (state == S_IO_NEXT && req_is_store)))
                line_valid[req_idx] <= 0;
            // Zicbom flush/invalidate must work even through an uncached
            // alias. This cache is write-through, so no dirty writeback is
            // needed. Poison a concurrent refill rather than reviving it.
            if (flush) begin line_valid<={SETS{1'b0}}; fill_poison<=1; end
        end
    end

    // The pulse/done client permits only one unacknowledged vector request.
    // A posted active write can coexist with that one waiting request, but
    // a new pulse must never arrive while the waiting slot is full.
    // synthesis translate_off
    reg v_wait_done;
    always @(posedge clk) begin
        if (rst) v_wait_done <= 0;
        else begin
            if (v_req && (v_addr[3:0] != 0 || v_va[3:0] != 0))
                $fatal(1, "VMEM request is not granule aligned");
            if (v_req && vq_valid)
                $fatal(1, "VMEM request while waiting slot full");
            if (v_req && state == S_IDLE && (s_arvalid || (s_awvalid && s_wvalid)))
                $fatal(1, "VMEM request collides with scalar request in idle");
            if (v_req && v_wait_done && !v_done)
                $fatal(1, "VMEM second request before done");
            if (v_fault) v_wait_done <= 0;
            else if (v_req) v_wait_done <= 1;
            else if (v_done) v_wait_done <= 0;
        end
    end
    // synthesis translate_on

    wire _unused = &{s_arlen,s_arburst,s_arprot,s_awlen,
                     s_awburst,s_awprot,s_wlast,m_rid,m_bid,1'b0};
endmodule
