//  karu_plic_assert.sv
//  Signalling checker for the two-source karu_plic (UART = id 1, eth = id 2),
//  same passive model as rtl/karu_assert.sv / flow/fpga/eth/karu_eth_assert.sv. It
//  re-derives each context's claimable and interrupt-notifiable conditions
//  from pending/enable/priority/threshold state and cross-checks the outputs
//  -- so it catches a claim/irq/arbitration bug
//  rather than just re-stating the implementation.
//
//  Sim path: instantiated by flow/fpga/linux_tb.sv with hierarchical refs into the
//  karu_plic instance. Formal path: KARU_PLIC_ASSERT_BIND for `bind karu_plic`,
//  KARU_PLIC_ASSERT_SVA for the assert-property form. Disable with the shared
//  +no_assert / +no_assert_stop plusargs.

module karu_plic_assert #(
    parameter integer STOP_ON_FAIL = 1
) (
    input  wire         clk,
    input  wire         rst,

    //  context interrupt lines + claim values (karu_plic outputs/internals)
    input  wire         irq_m,
    input  wire         irq_s,
    input  wire [31:0]  claim_m,
    input  wire [31:0]  claim_s,

    //  raw source/context state
    input  wire         pending_1,  // latched UART gateway request
    input  wire         pending_2,  // latched Ethernet gateway request
    input  wire         in_service_1,
    input  wire         in_service_2,
    input  wire         uart_irq,
    input  wire         eth_irq,
    input  wire         re,
    input  wire [31:0]  raddr,
    input  wire         we,
    input  wire [31:0]  waddr,
    input  wire [7:0]   wstrb,
    input  wire [63:0]  wdata,
    input  wire [31:0]  enable_m,
    input  wire [31:0]  enable_s,
    input  wire [3:0]   prio_1,
    input  wire [3:0]   prio_2,
    input  wire [3:0]   thr_m,
    input  wire [3:0]   thr_s
);
    localparam integer NSRC = 2;    //  implemented source ids: 1, 2

    integer fails   = 0;
    reg     enabled = 1'b1;
    reg     do_stop = 1'b1;
    reg [63:0] p_cyc  = 64'b0;

    //  +no_assert disables; +no_assert_stop reports-but-continues. $test$plusargs
    //  matches by prefix, so detect the _stop form first (else "+no_assert_stop"
    //  would also satisfy "no_assert" and fully disable the checker).
    initial begin
        if      ($test$plusargs("no_assert_stop")) do_stop = 1'b0;
        else if ($test$plusargs("no_assert"))      enabled = 1'b0;
    end

    // Claims ignore threshold, permitting software polling with IRQ masked.
    // Priority zero disables a source for both claiming and notification.
    wire chk_m1 = pending_1 && enable_m[1] && (prio_1 != 0);
    wire chk_m2 = pending_2 && enable_m[2] && (prio_2 != 0);
    wire chk_s1 = pending_1 && enable_s[1] && (prio_1 != 0);
    wire chk_s2 = pending_2 && enable_s[2] && (prio_2 != 0);
    wire notify_m = (chk_m1 && prio_1 > thr_m) || (chk_m2 && prio_2 > thr_m);
    wire notify_s = (chk_s1 && prio_1 > thr_s) || (chk_s2 && prio_2 > thr_s);

    // Derive qualified completions from the bus, not DUT completion wires.
    wire cm = we && (&wstrb[7:4]) && {waddr[31:3],3'b0} == 32'h0c200000;
    wire cs = we && (&wstrb[7:4]) && {waddr[31:3],3'b0} == 32'h0c201000;
    wire [1:0] complete = {
        wdata[63:32] == 2 && ((cm && enable_m[2]) || (cs && enable_s[2])),
        wdata[63:32] == 1 && ((cm && enable_m[1]) || (cs && enable_s[1]))};
    wire rm = re && {raddr[31:2],2'b0} == 32'h0c200004;
    wire rs = re && {raddr[31:2],2'b0} == 32'h0c201004;
    wire [1:0] take = {(rm && claim_m == 2) || (rs && claim_s == 2),
                       (rm && claim_m == 1) || (rs && claim_s == 1)};
    wire [1:0] pending = {pending_2,pending_1};
    wire [1:0] service = {in_service_2,in_service_1};
    reg history_valid = 0;
    reg [1:0] prev_pending, prev_service, prev_level, prev_complete, prev_take;

    `define PCHK(cond, tag) \
        if (enabled && !rst && !(cond)) begin \
            fails = fails + 1; \
            $display("[PLIC-ASSERT] FAIL cyc=%0d t=%0t: %s", p_cyc, $time, tag); \
            if (do_stop && STOP_ON_FAIL) begin \
                $display("[PLIC-ASSERT] %0d failure(s); stopping.", fails); \
                $fatal(1, "PLIC assertion failed"); \
            end \
        end

    always @(posedge clk) begin
        p_cyc <= p_cyc + 64'b1;

        `PCHK((pending & service) == 0, "PLIC6 pending and in-service overlap")
        if (history_valid) begin
            `PCHK(((pending & ~prev_pending) & ~prev_level) == 0,
                  "PLIC7 pending rose without high source level")
            `PCHK(((prev_service & ~service) & ~prev_complete) == 0,
                  "PLIC8 service cleared without qualified completion")
            `PCHK(((service & ~prev_service) & ~prev_take) == 0,
                  "PLIC9 service rose without claim")
            `PCHK(((prev_pending & ~pending) & ~prev_take) == 0,
                  "PLIC10 pending cleared without claim")
        end
        history_valid <= !rst;
        prev_pending <= pending; prev_service <= service;
        prev_level <= {eth_irq,uart_irq}; prev_complete <= complete; prev_take <= take;

        //  claim is a valid implemented source id (0 = none, else 1..NSRC).
        `PCHK(claim_m <= NSRC, "PLIC1 claim_m out of range (>NSRC)")
        `PCHK(claim_s <= NSRC, "PLIC1 claim_s out of range (>NSRC)")

        //  the context irq line is asserted iff some source is presentable.
        `PCHK(irq_m == notify_m, "PLIC2 irq_m != (any M source above threshold)")
        `PCHK(irq_s == notify_s, "PLIC2 irq_s != (any S source above threshold)")

        // A source can be claimed even when the threshold suppresses IRQ.
        `PCHK((claim_m != 0) == (chk_m1 || chk_m2), "PLIC3 M claimability mismatch")
        `PCHK((claim_s != 0) == (chk_s1 || chk_s2), "PLIC3 S claimability mismatch")

        //  a claimed source must actually be presentable to that context
        //  (never claim a disabled or not-pending source).
        `PCHK(!(claim_m == 1) || chk_m1, "PLIC4 claimed M src 1 not presentable")
        `PCHK(!(claim_m == 2) || chk_m2, "PLIC4 claimed M src 2 not presentable")
        `PCHK(!(claim_s == 1) || chk_s1, "PLIC4 claimed S src 1 not presentable")
        `PCHK(!(claim_s == 2) || chk_s2, "PLIC4 claimed S src 2 not presentable")

        //  the winner is highest priority (ties -> lowest id, per the spec):
        //  if src1 is claimed while src2 is also presentable, prio_1 >= prio_2;
        //  if src2 is claimed while src1 is also presentable, prio_2 > prio_1.
        `PCHK(!(claim_m == 1 && chk_m2) || (prio_1 >= prio_2),
              "PLIC5 M claimed src1 but src2 has higher priority")
        `PCHK(!(claim_m == 2 && chk_m1) || (prio_2 >  prio_1),
              "PLIC5 M claimed src2 but src1 outranks/ties it")
        `PCHK(!(claim_s == 1 && chk_s2) || (prio_1 >= prio_2),
              "PLIC5 S claimed src1 but src2 has higher priority")
        `PCHK(!(claim_s == 2 && chk_s1) || (prio_2 >  prio_1),
              "PLIC5 S claimed src2 but src1 outranks/ties it")
    end

    `undef PCHK

`ifdef KARU_PLIC_ASSERT_SVA
    default clocking @(posedge clk); endclocking
    default disable iff (rst);
    a_plic1_m:  assert property (claim_m <= NSRC);
    a_plic1_s:  assert property (claim_s <= NSRC);
    a_plic2_m:  assert property (irq_m == notify_m);
    a_plic2_s:  assert property (irq_s == notify_s);
    a_plic3_m:  assert property ((claim_m != 0) == (chk_m1 || chk_m2));
    a_plic3_s:  assert property ((claim_s != 0) == (chk_s1 || chk_s2));
    a_plic4_m1: assert property (claim_m == 1 |-> chk_m1);
    a_plic4_m2: assert property (claim_m == 2 |-> chk_m2);
    a_plic4_s1: assert property (claim_s == 1 |-> chk_s1);
    a_plic4_s2: assert property (claim_s == 2 |-> chk_s2);
    a_plic5_m1: assert property ((claim_m == 1 && chk_m2) |-> (prio_1 >= prio_2));
    a_plic5_m2: assert property ((claim_m == 2 && chk_m1) |-> (prio_2 >  prio_1));
    a_plic5_s1: assert property ((claim_s == 1 && chk_s2) |-> (prio_1 >= prio_2));
    a_plic5_s2: assert property ((claim_s == 2 && chk_s1) |-> (prio_2 >  prio_1));
    a_plic6: assert property ((pending & service) == 0);
    a_plic7: assert property (history_valid |-> ((pending & ~prev_pending) & ~prev_level) == 0);
    a_plic8: assert property (history_valid |-> ((prev_service & ~service) & ~prev_complete) == 0);
    a_plic9: assert property (history_valid |-> ((service & ~prev_service) & ~prev_take) == 0);
    a_plic10: assert property (history_valid |-> ((prev_pending & ~pending) & ~prev_take) == 0);
`endif

endmodule

`ifdef KARU_PLIC_ASSERT_BIND
bind karu_plic karu_plic_assert u_karu_plic_assert (
    .clk(clk), .rst(rst),
    .irq_m(irq_m), .irq_s(irq_s), .claim_m(claim_m), .claim_s(claim_s),
    .pending_1(pending_1), .pending_2(pending_2),
    .in_service_1(in_service_1), .in_service_2(in_service_2),
    .uart_irq(uart_irq), .eth_irq(eth_irq), .re(re), .raddr(raddr),
    .we(we), .waddr(waddr), .wstrb(wstrb), .wdata(wdata),
    .enable_m(enable_m), .enable_s(enable_s),
    .prio_1(priority_1), .prio_2(priority_2), .thr_m(threshold_m), .thr_s(threshold_s)
);
`endif
