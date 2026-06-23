//  karu_plic_assert.sv
//  Signalling checker for the two-source karu_plic (UART = id 1, eth = id 2),
//  same passive model as rtl/karu_assert.sv / flow/fpga/eth/karu_eth_assert.sv. It
//  re-derives each context's "presentable" condition from the raw
//  pending/enable/priority/threshold state and cross-checks the PLIC's claim
//  and irq outputs against it -- so it catches a claim/irq/arbitration bug
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
    input  wire         pending_1,  //  = uart_irq
    input  wire         pending_2,  //  = eth_irq
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

    //  Independently-derived "source k presentable to context c" (mirrors the
    //  PLIC spec: pending & enabled & priority strictly above the threshold).
    wire chk_m1 = pending_1 && enable_m[1] && (prio_1 > thr_m);
    wire chk_m2 = pending_2 && enable_m[2] && (prio_2 > thr_m);
    wire chk_s1 = pending_1 && enable_s[1] && (prio_1 > thr_s);
    wire chk_s2 = pending_2 && enable_s[2] && (prio_2 > thr_s);

    `define PCHK(cond, tag) \
        if (enabled && !rst && !(cond)) begin \
            fails = fails + 1; \
            $display("[PLIC-ASSERT] FAIL cyc=%0d t=%0t: %s", p_cyc, $time, tag); \
            if (do_stop && STOP_ON_FAIL) begin \
                $display("[PLIC-ASSERT] %0d failure(s); stopping.", fails); \
                $finish; \
            end \
        end

    always @(posedge clk) begin
        p_cyc <= p_cyc + 64'b1;

        //  claim is a valid implemented source id (0 = none, else 1..NSRC).
        `PCHK(claim_m <= NSRC, "PLIC1 claim_m out of range (>NSRC)")
        `PCHK(claim_s <= NSRC, "PLIC1 claim_s out of range (>NSRC)")

        //  the context irq line is asserted iff some source is presentable.
        `PCHK(irq_m == (chk_m1 || chk_m2), "PLIC2 irq_m != (any M source presentable)")
        `PCHK(irq_s == (chk_s1 || chk_s2), "PLIC2 irq_s != (any S source presentable)")

        //  claim and irq agree: a claimable id exactly when the line is up.
        `PCHK((claim_m != 0) == irq_m, "PLIC3 claim_m/irq_m disagree")
        `PCHK((claim_s != 0) == irq_s, "PLIC3 claim_s/irq_s disagree")

        //  a claimed source must actually be presentable to that context
        //  (never claim a disabled / not-pending / below-threshold source).
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
    a_plic2_m:  assert property (irq_m == (chk_m1 || chk_m2));
    a_plic2_s:  assert property (irq_s == (chk_s1 || chk_s2));
    a_plic3_m:  assert property ((claim_m != 0) == irq_m);
    a_plic3_s:  assert property ((claim_s != 0) == irq_s);
    a_plic4_m1: assert property (claim_m == 1 |-> chk_m1);
    a_plic4_m2: assert property (claim_m == 2 |-> chk_m2);
    a_plic4_s1: assert property (claim_s == 1 |-> chk_s1);
    a_plic4_s2: assert property (claim_s == 2 |-> chk_s2);
    a_plic5_m1: assert property ((claim_m == 1 && chk_m2) |-> (prio_1 >= prio_2));
    a_plic5_m2: assert property ((claim_m == 2 && chk_m1) |-> (prio_2 >  prio_1));
    a_plic5_s1: assert property ((claim_s == 1 && chk_s2) |-> (prio_1 >= prio_2));
    a_plic5_s2: assert property ((claim_s == 2 && chk_s1) |-> (prio_2 >  prio_1));
`endif

endmodule

`ifdef KARU_PLIC_ASSERT_BIND
bind karu_plic karu_plic_assert u_karu_plic_assert (
    .clk(clk), .rst(rst),
    .irq_m(irq_m), .irq_s(irq_s), .claim_m(claim_m), .claim_s(claim_s),
    .pending_1(pending_1), .pending_2(pending_2),
    .enable_m(enable_m), .enable_s(enable_s),
    .prio_1(priority_1), .prio_2(priority_2), .thr_m(threshold_m), .thr_s(threshold_s)
);
`endif
