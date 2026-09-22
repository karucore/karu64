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
//  Both level-sensitive gateways latch one pending request, which survives
//  source deassertion. Claim clears pending and blocks that gateway until
//  completion; a still-high level then generates a new pending request.
//  Claim selects pending+enabled, nonzero-priority sources independently of
//  the notification threshold (ties go to the lowest ID). Completion is
//  checked against the writing context's enables, not a remembered owner.
//  See ratified PLIC 1.0, Interrupt Gateways / Claim Process / Completion:
//  https://github.com/riscv/riscv-plic-spec/blob/master/riscv-plic.adoc

module karu_plic (
    input  wire         clk,
    input  wire         rst,

    input  wire         re,           // one accepted native register read
    input  wire [31:0]  raddr,        // exact address, including 32-bit lane
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

    reg         pending_1, pending_2;
    reg         in_service_1, in_service_2;

    //  per-context, per-source "interrupt is presentable"
    wire m1;
    assign m1 = pending_1 && enable_m[1] && (priority_1 > threshold_m);
    wire m2;
    assign m2 = pending_2 && enable_m[2] && (priority_2 > threshold_m);
    wire s1;
    assign s1 = pending_1 && enable_s[1] && (priority_1 > threshold_s);
    wire s2;
    assign s2 = pending_2 && enable_s[2] && (priority_2 > threshold_s);

    // Threshold controls notifications only: polling a claim is legal even
    // with threshold=max and no IRQ. Priority zero still disables a source.
    wire c_m1;
    assign c_m1 = pending_1 && enable_m[1] && (priority_1 != 0);
    wire c_m2;
    assign c_m2 = pending_2 && enable_m[2] && (priority_2 != 0);
    wire c_s1;
    assign c_s1 = pending_1 && enable_s[1] && (priority_1 != 0);
    wire c_s2;
    assign c_s2 = pending_2 && enable_s[2] && (priority_2 != 0);
    wire [31:0] claim_m;
    assign claim_m = (c_m1 && (!c_m2 || (priority_1 >= priority_2))) ? 32'd1 :
                     c_m2 ? 32'd2 : 32'd0;
    wire [31:0] claim_s;
    assign claim_s = (c_s1 && (!c_s2 || (priority_1 >= priority_2))) ? 32'd1 :
                     c_s2 ? 32'd2 : 32'd0;

    assign irq_m = m1 || m2;
    assign irq_s = s1 || s2;

    function [31:0] read32;
        input [31:0] off;
        input [3:0] p1, p2, tm, ts;
        input [31:0] em, es, cm, cs;
        input [1:0] pending;
        begin
            case (off)
                OFF_PRIORITY_1: read32 = {28'b0, p1};
                OFF_PRIORITY_2: read32 = {28'b0, p2};
                OFF_PENDING:    read32 = {29'b0, pending, 1'b0};
                OFF_ENABLE_M:   read32 = em;
                OFF_ENABLE_S:   read32 = es;
                OFF_THRESH_M:   read32 = {28'b0, tm};
                OFF_CLAIM_M:    read32 = cm;
                OFF_THRESH_S:   read32 = {28'b0, ts};
                OFF_CLAIM_S:    read32 = cs;
                default:        read32 = 32'b0;
            endcase
        end
    endfunction

    wire [31:0] roff;
    assign roff = raddr - PLIC_BASE;
    wire [31:0] rbase;
    assign rbase = {roff[31:3], 3'b000};
    // Pass dynamic register state explicitly: repeated reads of a fixed
    // address must reflect source events even when the address never changes.
    assign rdata = {
        read32(rbase + 32'd4, priority_1, priority_2, threshold_m, threshold_s,
               enable_m, enable_s, claim_m, claim_s, {pending_2,pending_1}),
        read32(rbase, priority_1, priority_2, threshold_m, threshold_s,
               enable_m, enable_s, claim_m, claim_s, {pending_2,pending_1})};
    // Exposing the adjacent claim value on a 64-bit data bus is not itself
    // a read of that register. Threshold+0 must not consume claim+4.
    wire claim_read_m;
    assign claim_read_m = re && ({roff[31:2],2'b0} == OFF_CLAIM_M);
    wire claim_read_s;
    assign claim_read_s = re && ({roff[31:2],2'b0} == OFF_CLAIM_S);
    wire take_1;
    assign take_1 = (claim_read_m && claim_m == 1) || (claim_read_s && claim_s == 1);
    wire take_2;
    assign take_2 = (claim_read_m && claim_m == 2) || (claim_read_s && claim_s == 2);

    wire [31:0] woff;
    assign woff = waddr - PLIC_BASE;
    wire [31:0] wbase;
    assign wbase = {woff[31:3], 3'b000};
    wire        we_lo;
    assign we_lo = we && |wstrb[3:0];
    wire        we_hi;
    assign we_hi = we && |wstrb[7:4];
    wire [31:0] waddr_lo;
    assign waddr_lo = wbase;
    wire [31:0] waddr_hi;
    assign waddr_hi = wbase + 32'd4;
    wire [31:0] wdata_lo;
    assign wdata_lo = wdata[31:0];
    wire [31:0] wdata_hi;
    assign wdata_hi = wdata[63:32];
    // Claim/complete is a native 32-bit register. A complete word strobe is
    // required for the side effect; partial/unknown/disabled completions do
    // nothing. No ownership/last-claimed comparison is permitted by the spec.
    wire complete_m;
    assign complete_m = we && (&wstrb[7:4]) && waddr_hi == OFF_CLAIM_M;
    wire complete_s;
    assign complete_s = we && (&wstrb[7:4]) && waddr_hi == OFF_CLAIM_S;
    wire complete_1;
    assign complete_1 = wdata_hi == 1 &&
          ((complete_m && enable_m[1]) || (complete_s && enable_s[1]));
    wire complete_2;
    assign complete_2 = wdata_hi == 2 &&
          ((complete_m && enable_m[2]) || (complete_s && enable_s[2]));

    always @(posedge clk) begin
        if (rst) begin
            priority_1 <= 4'd0;
            priority_2 <= 4'd0;
            enable_m <= 32'b0;
            enable_s <= 32'b0;
            threshold_m <= 4'd0;
            threshold_s <= 4'd0;
            pending_1 <= 0; pending_2 <= 0;
            in_service_1 <= 0; in_service_2 <= 0;
        end else begin
            // Per-source idle/pending/in-service states need only two bits.
            // A claim wins a coincident completion of the same source; a
            // completion of another source proceeds independently.
            if (take_1) begin
                pending_1 <= 0; in_service_1 <= 1;
            end else if (complete_1) begin
                in_service_1 <= 0;
                pending_1 <= pending_1 || uart_irq;
            end else if (!in_service_1 && uart_irq) pending_1 <= 1;
            if (take_2) begin
                pending_2 <= 0; in_service_2 <= 1;
            end else if (complete_2) begin
                in_service_2 <= 0;
                pending_2 <= pending_2 || eth_irq;
            end else if (!in_service_2 && eth_irq) pending_2 <= 1;

            // Only the low byte of these 32-bit WARL registers contains
            // implemented bits. Other byte strobes must not clobber it.
            if (we_lo && wstrb[0]) begin
                case (waddr_lo)
                    OFF_PRIORITY_1: priority_1 <= wdata_lo[3:0];
                    OFF_PRIORITY_2: priority_2 <= wdata_lo[3:0];
                    OFF_ENABLE_M:   enable_m <= wdata_lo & 32'h6;
                    OFF_ENABLE_S:   enable_s <= wdata_lo & 32'h6;
                    OFF_THRESH_M:   threshold_m <= wdata_lo[3:0];
                    OFF_THRESH_S:   threshold_s <= wdata_lo[3:0];
                    default: ;
                endcase
            end
            if (we_hi && wstrb[4]) begin
                case (waddr_hi)
                    OFF_PRIORITY_1: priority_1 <= wdata_hi[3:0];
                    OFF_PRIORITY_2: priority_2 <= wdata_hi[3:0];
                    OFF_ENABLE_M:   enable_m <= wdata_hi & 32'h6;
                    OFF_ENABLE_S:   enable_s <= wdata_hi & 32'h6;
                    OFF_THRESH_M:   threshold_m <= wdata_hi[3:0];
                    OFF_THRESH_S:   threshold_s <= wdata_hi[3:0];
                    default: ;
                endcase
            end
        end
    end
endmodule
