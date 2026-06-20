//  karu_plic.v
//  Minimal RISC-V PLIC front-end. Two external sources:
//    ID 1 = UART interrupt   (uart_irq)
//    ID 2 = Ethernet (LiteEth) interrupt (eth_irq)   [tie low if absent]
//
//  Implemented register windows:
//    0x000004 / 0x000008   priority[1] / priority[2]
//    0x001000              pending bits
//    0x002000              context 0 (M-mode) enable bits
//    0x002080              context 1 (S-mode) enable bits
//    0x200000/200004       context 0 threshold / claim-complete
//    0x201000/201004       context 1 threshold / claim-complete
//
//  Both sources are level-triggered. A claim read returns the ID of the
//  highest-priority pending+enabled source above the context threshold
//  (ties broken by lowest ID, per the PLIC spec); it does not clear the
//  source (the line deasserts when the device condition is serviced).
//  Completion writes are accepted but ignored.

module karu_plic (
    input  wire         clk,
    input  wire         rst,

    input  wire [31:0]  raddr,
    output wire [63:0]  rdata,

    input  wire         we,
    input  wire [31:0]  waddr,
    input  wire [7:0]   wstrb,
    input  wire [63:0]  wdata,

    input  wire         uart_irq,
    input  wire         eth_irq,
    output wire         irq_m,
    output wire         irq_s
);
    localparam [31:0] PLIC_BASE      = 32'h0c00_0000;
    localparam [31:0] OFF_PRIORITY_1 = 32'h0000_0004;
    localparam [31:0] OFF_PRIORITY_2 = 32'h0000_0008;
    localparam [31:0] OFF_PENDING    = 32'h0000_1000;
    localparam [31:0] OFF_ENABLE_M   = 32'h0000_2000;
    localparam [31:0] OFF_ENABLE_S   = 32'h0000_2080;
    localparam [31:0] OFF_THRESH_M   = 32'h0020_0000;
    localparam [31:0] OFF_CLAIM_M    = 32'h0020_0004;
    localparam [31:0] OFF_THRESH_S   = 32'h0020_1000;
    localparam [31:0] OFF_CLAIM_S    = 32'h0020_1004;

    reg [3:0]   priority_1, priority_2;
    reg [31:0]  enable_m;
    reg [31:0]  enable_s;
    reg [3:0]   threshold_m;
    reg [3:0]   threshold_s;

    wire        pending_1 = uart_irq;
    wire        pending_2 = eth_irq;

    //  per-context, per-source "interrupt is presentable"
    wire m1 = pending_1 && enable_m[1] && (priority_1 > threshold_m);
    wire m2 = pending_2 && enable_m[2] && (priority_2 > threshold_m);
    wire s1 = pending_1 && enable_s[1] && (priority_1 > threshold_s);
    wire s2 = pending_2 && enable_s[2] && (priority_2 > threshold_s);

    //  claim winner: highest priority, ties -> lowest ID
    wire [31:0] claim_m = (m1 && (!m2 || (priority_1 >= priority_2))) ? 32'd1 :
                          m2 ? 32'd2 : 32'd0;
    wire [31:0] claim_s = (s1 && (!s2 || (priority_1 >= priority_2))) ? 32'd1 :
                          s2 ? 32'd2 : 32'd0;

    assign irq_m = m1 || m2;
    assign irq_s = s1 || s2;

    function [31:0] read32;
        input [31:0] off;
        begin
            case (off)
                OFF_PRIORITY_1: read32 = {28'b0, priority_1};
                OFF_PRIORITY_2: read32 = {28'b0, priority_2};
                OFF_PENDING:    read32 = {29'b0, pending_2, pending_1, 1'b0};
                OFF_ENABLE_M:   read32 = enable_m;
                OFF_ENABLE_S:   read32 = enable_s;
                OFF_THRESH_M:   read32 = {28'b0, threshold_m};
                OFF_CLAIM_M:    read32 = claim_m;
                OFF_THRESH_S:   read32 = {28'b0, threshold_s};
                OFF_CLAIM_S:    read32 = claim_s;
                default:        read32 = 32'b0;
            endcase
        end
    endfunction

    wire [31:0] roff = raddr - PLIC_BASE;
    wire [31:0] rbase = {roff[31:3], 3'b000};
    assign rdata = {read32(rbase + 32'd4), read32(rbase)};

    wire [31:0] woff = waddr - PLIC_BASE;
    wire [31:0] wbase = {woff[31:3], 3'b000};
    wire        we_lo = we && |wstrb[3:0];
    wire        we_hi = we && |wstrb[7:4];
    wire [31:0] waddr_lo = wbase;
    wire [31:0] waddr_hi = wbase + 32'd4;
    wire [31:0] wdata_lo = wdata[31:0];
    wire [31:0] wdata_hi = wdata[63:32];

    always @(posedge clk) begin
        if (rst) begin
            priority_1 <= 4'd0;
            priority_2 <= 4'd0;
            enable_m <= 32'b0;
            enable_s <= 32'b0;
            threshold_m <= 4'd0;
            threshold_s <= 4'd0;
        end else begin
            if (we_lo) begin
                case (waddr_lo)
                    OFF_PRIORITY_1: priority_1 <= wdata_lo[3:0];
                    OFF_PRIORITY_2: priority_2 <= wdata_lo[3:0];
                    OFF_ENABLE_M:   enable_m <= wdata_lo;
                    OFF_ENABLE_S:   enable_s <= wdata_lo;
                    OFF_THRESH_M:   threshold_m <= wdata_lo[3:0];
                    OFF_THRESH_S:   threshold_s <= wdata_lo[3:0];
                    default: ;
                endcase
            end
            if (we_hi) begin
                case (waddr_hi)
                    OFF_PRIORITY_1: priority_1 <= wdata_hi[3:0];
                    OFF_PRIORITY_2: priority_2 <= wdata_hi[3:0];
                    OFF_ENABLE_M:   enable_m <= wdata_hi;
                    OFF_ENABLE_S:   enable_s <= wdata_hi;
                    OFF_THRESH_M:   threshold_m <= wdata_hi[3:0];
                    OFF_THRESH_S:   threshold_s <= wdata_hi[3:0];
                    default: ;
                endcase
            end
        end
    end
endmodule
