//  karu_icache.v
//  Small read-only, physically-tagged instruction cache that sits between the
//  IFU's AXI4 read master and the imem read port. Direct-mapped, 64-byte lines.
//  A hit returns the requested 64-bit word with the same 1-cycle AR->R shape
//  the IFU already expects; a miss refills the whole line via an INCR burst,
//  then serves. Non-RAM addresses bypass (single-beat passthrough). The whole
//  cache is invalidated on FENCE.I (`flush`), so self-modifying code stays
//  coherent (a refill in flight when the flush arrives is poisoned, not
//  validated). Read-only: the IFU never writes, so there are no write channels.
//
//  Purpose: hide real imem latency (FPGA/DDR, Linux-on-HW). On a 1-cycle imem
//  (the htif_tb RAM) it is latency-transparent -- correctness-identical, no
//  cycle change. Gated behind KARU_ICACHE in karu64.v so the no-cache build is
//  byte-identical for A/B.

`include "config.vh"
`include "karu_axi_defs.vh"

module karu_icache #(
    parameter integer KB = 4        //  cache size in KiB (64-byte lines)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         flush,          //  FENCE.I: invalidate every line
    output wire         owns,           //  cache holds an imem transaction (arbiter lock)

    //  ---- AXI4 read SLAVE (from the IFU) ----
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

    //  ---- AXI4 read MASTER (to imem) ----
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
    output reg                      m_rready
);
    localparam integer LINES  = (KB * 1024) / 64;   //  64-byte lines
    localparam integer IDXW   = $clog2(LINES);
    localparam integer OFFW   = 6;                  //  64-byte line offset
    localparam integer TAGW   = `AXI_ADDR_W - IDXW - OFFW;

    //  storage: data[{index, word}] (8 64-bit words/line), tag, valid.
    reg [63:0]          cdata [0:LINES*8-1];
    reg [TAGW-1:0]      ctag  [0:LINES-1];
    reg [LINES-1:0]     cvalid;

    //  ---- request decode (latched on AR accept) ----
    reg [`AXI_ADDR_W-1:0]   addr_q;
    reg [`AXI_ID_W-1:0]     id_q;
    //  geometry of the in-flight (latched) request, used by the refill path.
    wire [IDXW-1:0] a_idx = addr_q[OFFW+IDXW-1:OFFW];
    wire [2:0]      a_qw  = addr_q[5:3];                //  word within the line
    wire [TAGW-1:0] a_tag = addr_q[`AXI_ADDR_W-1:OFFW+IDXW];
    //  (code lives in RAM 0x8xxx_xxxx; everything else bypasses -- decoded
    //  directly off the incoming s_araddr in S_IDLE below.)

    localparam S_IDLE=3'd0, S_SERVE=3'd1, S_MISS_AR=3'd2, S_MISS_R=3'd3,
               S_UC_AR=3'd4, S_UC_R=3'd5;
    reg [2:0]   state;
    reg [2:0]   beat;           //  refill beat counter
    reg [63:0]  serve_data;     //  the word to return (hit / refilled / uncached)
    reg         poison;         //  a flush hit during this refill -> don't validate

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; cvalid <= {LINES{1'b0}};
            s_arready <= 1'b1; s_rvalid <= 1'b0; s_rlast <= 1'b0; s_rresp <= `AXI_RESP_OKAY;
            m_arvalid <= 1'b0; m_rready <= 1'b0; beat <= 3'd0; poison <= 1'b0;
        end else begin
            //  FENCE.I: drop every line; poison an in-flight refill.
            if (flush) begin
                cvalid <= {LINES{1'b0}};
                if (state == S_MISS_AR || state == S_MISS_R) poison <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    s_arready <= 1'b1;
                    if (s_arvalid && s_arready) begin
                        addr_q <= s_araddr; id_q <= s_arid;
                        s_arready <= 1'b0;
                        //  (a_* below see the NEW addr next cycle; decode here off
                        //  the incoming s_araddr for the immediate branch.)
                        //  A FENCE.I flush this cycle DOMINATES acceptance: a
                        //  concurrent hit must not serve a line being invalidated,
                        //  so it is forced down the (fresh) refill path.
                        if (s_araddr[31:28] != 4'h8) begin
                            state <= S_UC_AR;
                        end else if (!flush
                              && cvalid[s_araddr[OFFW+IDXW-1:OFFW]]
                              && ctag[s_araddr[OFFW+IDXW-1:OFFW]] == s_araddr[`AXI_ADDR_W-1:OFFW+IDXW]) begin
                            serve_data <= cdata[{s_araddr[OFFW+IDXW-1:OFFW], s_araddr[5:3]}];
                            state <= S_SERVE;
                        end else begin
                            poison <= 1'b0;
                            state <= S_MISS_AR;
                        end
                    end
                end
                S_SERVE: begin
                    s_rvalid <= 1'b1; s_rid <= id_q; s_rdata <= serve_data;
                    s_rlast  <= 1'b1; s_rresp <= `AXI_RESP_OKAY;
                    if (s_rvalid && s_rready) begin
                        s_rvalid <= 1'b0; s_rlast <= 1'b0;
                        s_arready <= 1'b1;
                        state <= S_IDLE;
                    end
                end
                S_MISS_AR: begin
                    m_arid <= 4'd0; m_araddr <= {a_tag, a_idx, {OFFW{1'b0}}};
                    m_arlen <= 8'd7; m_arsize <= `AXI_SIZE_8B;
                    m_arburst <= `AXI_BURST_INCR; m_arprot <= 0;
                    m_arvalid <= 1'b1;
                    if (m_arvalid && m_arready) begin
                        m_arvalid <= 1'b0; m_rready <= 1'b1; beat <= 3'd0;
                        state <= S_MISS_R;
                    end
                end
                S_MISS_R: begin
                    if (m_rvalid && m_rready) begin
                        cdata[{a_idx, beat}] <= m_rdata;
                        if (beat == a_qw) serve_data <= m_rdata;    //  requested word
                        beat <= beat + 3'd1;
                        if (m_rlast) begin
                            m_rready <= 1'b0;
                            if (!poison && !flush) begin
                                cvalid[a_idx] <= 1'b1;
                                ctag[a_idx]   <= a_tag;
                            end
                            state <= S_SERVE;
                        end
                    end
                end
                S_UC_AR: begin
                    m_arid <= id_q; m_araddr <= addr_q;
                    m_arlen <= 8'd0; m_arsize <= `AXI_SIZE_8B;
                    m_arburst <= `AXI_BURST_INCR; m_arprot <= 0;
                    m_arvalid <= 1'b1;
                    if (m_arvalid && m_arready) begin
                        m_arvalid <= 1'b0; m_rready <= 1'b1;
                        state <= S_UC_R;
                    end
                end
                S_UC_R: begin
                    if (m_rvalid && m_rready) begin
                        serve_data <= m_rdata;
                        m_rready <= 1'b0;
                        state <= S_SERVE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    //  The cache holds the imem read port from AR-accept (entering S_MISS_R/
    //  S_UC_R) until its last beat, so an IMMU walk cannot preempt the burst.
    assign owns = (state == S_MISS_R) || (state == S_UC_R);

// synthesis translate_off
    //  Protocol invariants (sim-only). The refill must be exactly 8 beats (the
    //  imem slave must honour arlen=7) -- a single-beated refill would fill the
    //  line with stale/garbage words. A line is only served on a hit.
    always @(posedge clk) if (!rst) begin
        if (state == S_MISS_R && m_rvalid && m_rready && m_rlast && beat != 3'd7) begin
            $display("[ICACHE-ASSERT] refill ended after %0d beats (expected 8) @%0t", beat+1, $time);
            $finish;
        end
        if (state == S_SERVE && s_rvalid && s_arready) begin    //  must not re-accept AR mid-serve
            $display("[ICACHE-ASSERT] s_arready high during an in-flight response @%0t", $time);
            $finish;
        end
        //  owns must imply an imem master transaction is genuinely in flight.
        if (owns && !m_rready) begin
            $display("[ICACHE-ASSERT] owns asserted without m_rready @%0t", $time);
            $finish;
        end
    end
// synthesis translate_on

    //  silence unused AR attributes from the IFU (single-beat 8B INCR always).
    wire _unused = &{1'b0, s_arlen, s_arsize, s_arburst, s_arprot, m_rid, m_rresp, m_rlast};
endmodule
