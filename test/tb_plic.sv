// Two-source PLIC gateway, arbitration and native register-lane regression.
// Claims clear pending independently of notification thresholds; completions
// are qualified by the completing context's enable, not last-claimer identity.
`timescale 1ns/1ps
module tb_plic;
    reg clk=0, rst=1, re=0, we=0, uart_irq=0, eth_irq=0;
    reg [31:0] raddr=0, waddr=0;
    reg [7:0] wstrb=0;
    reg [63:0] wdata=0;
    wire [63:0] rdata;
    wire irq_m, irq_s;
    always #5 clk=~clk;
    karu_plic dut (.*);
    karu_plic_assert checker_u (
        .clk(clk), .rst(rst), .irq_m(irq_m), .irq_s(irq_s),
        .claim_m(dut.claim_m), .claim_s(dut.claim_s),
        .pending_1(dut.pending_1), .pending_2(dut.pending_2),
        .in_service_1(dut.in_service_1), .in_service_2(dut.in_service_2),
        .uart_irq(uart_irq), .eth_irq(eth_irq), .re(re), .raddr(raddr),
        .we(we), .waddr(waddr), .wstrb(wstrb), .wdata(wdata),
        .enable_m(dut.enable_m), .enable_s(dut.enable_s),
        .prio_1(dut.priority_1), .prio_2(dut.priority_2),
        .thr_m(dut.threshold_m), .thr_s(dut.threshold_s));
    localparam [31:0] BASE=32'h0c000000, PRIO1=4, PRIO2=8, PENDING='h1000,
        ENABLE_M='h2000, ENABLE_S='h2080, THRESH_M='h200000, CLAIM_M='h200004,
        THRESH_S='h201000, CLAIM_S='h201004;
    integer checks=0;
    task automatic write32(input [31:0] off, input [31:0] value, input [3:0] strb=4'hf);
        @(negedge clk);
        waddr=BASE+off; wdata=off[2] ? {value,32'b0} : {32'b0,value};
        wstrb=off[2] ? {strb,4'b0} : {4'b0,strb}; we=1;
        @(negedge clk); we=0; wstrb=0; waddr=0; wdata=0;
    endtask
    task automatic read32(input [31:0] off, input [31:0] expected, input bit consume=1);
        reg [31:0] observed;
        @(negedge clk); raddr=BASE+off; re=consume;
        #1; observed=off[2] ? rdata[63:32] : rdata[31:0];
        if(observed!==expected) $fatal(1,"check %0d read %h got %h expected %h pending=%b%b service=%b%b",checks,off,observed,expected,dut.pending_2,dut.pending_1,dut.in_service_2,dut.in_service_1);
        checks=checks+1;
        @(negedge clk); re=0;
    endtask
    task automatic irqs(input bit m, input bit s);
        #1;
        if(irq_m!==m || irq_s!==s) $fatal(1,"IRQ mismatch M=%b S=%b expected %b %b",irq_m,irq_s,m,s);
        checks=checks+1;
    endtask
    task automatic levels(input bit u, input bit e);
        @(negedge clk); uart_irq=u; eth_irq=e;
        repeat(2) @(negedge clk);
    endtask
    task automatic reset;
        @(negedge clk); rst=1; re=0; we=0; uart_irq=0; eth_irq=0;
        repeat(3) @(negedge clk); rst=0;
    endtask
    function automatic [31:0] winner(input integer p1, input integer p2, input [1:0] en);
        // Reference chooses from an ordered list, without using DUT internals.
        integer best, best_priority;
        begin
            best=0; best_priority=0;
            for(integer id=1;id<=2;id=id+1) begin
                if(en[id-1] && (id==1 ? p1 : p2)>best_priority) begin
                    best=id; best_priority=id==1 ? p1 : p2;
                end
            end
            winner=best;
        end
    endfunction
    reg [31:0] expect_m, expect_s;
    integer p_m, p_s;
    integer gateway_negative = 0;
    initial begin
        repeat(3) @(negedge clk); rst=0;
        if ($value$plusargs("gateway_negative=%d", gateway_negative)) begin
            // Corrupt the DUT state deliberately: prove the passive checker
            // catches each gateway invariant, not merely the output decoder.
            repeat(2) @(negedge clk);
            if (gateway_negative == 1) begin
                force dut.pending_1=1;
                force dut.in_service_1=1;
            end else if (gateway_negative == 2) begin
                force dut.pending_1=1;
            end else if (gateway_negative == 3) begin
                write32(ENABLE_M,2); write32(PRIO1,1);
                levels(1,0); read32(CLAIM_M,1); levels(0,0);
                force dut.in_service_1=0;
            end else $fatal(1,"unknown gateway negative control");
            repeat(3) @(negedge clk);
            $fatal(1,"gateway corruption escaped checker");
        end
        read32(PRIO1,0); read32(PRIO2,0); read32(ENABLE_M,0); read32(ENABLE_S,0);
        read32(PENDING,0); read32(CLAIM_M,0); read32(CLAIM_S,0); irqs(0,0);
        // Source zero/absent enable bits are WARL zero; all priority/threshold
        // combinations of the four implemented bits are supported.
        write32(ENABLE_M,32'hffffffff); read32(ENABLE_M,6);
        write32(ENABLE_S,6); write32(PRIO1,17); read32(PRIO1,1);
        write32(PRIO2,1);
        write32(THRESH_M,32'hffffffff); read32(THRESH_M,15); write32(THRESH_M,0);
        // Nonimplemented byte lanes must not alter implemented register bits.
        write32(PRIO1,0,4'he); read32(PRIO1,1);
        write32(ENABLE_M,0,4'he); read32(ENABLE_M,6);
        write32(THRESH_M,8); write32(THRESH_M,0,4'he); read32(THRESH_M,8);
        write32(THRESH_M,0);

        levels(1,1); read32(PENDING,6); irqs(1,1);
        // Threshold reads expose claim in the other data-bus lane but cannot
        // claim it. Holding the address without re cannot repeat a claim.
        read32(THRESH_M,0); read32(THRESH_S,0); read32(PENDING,6);
        read32(CLAIM_M,1,0); read32(PENDING,6);
        read32(CLAIM_M,1); read32(PENDING,4);
        repeat(8) @(negedge clk); read32(PENDING,4);
        read32(CLAIM_S,2); read32(PENDING,0); irqs(0,0);
        repeat(8) @(negedge clk); read32(CLAIM_M,0); read32(CLAIM_S,0);

        // Invalid, partial and disabled-context completions do not reopen a
        // gateway. A different enabled context may legitimately complete it.
        write32(CLAIM_M,0); write32(CLAIM_M,3); write32(CLAIM_S,32'hffffffff);
        write32(CLAIM_M,1,4'h1); read32(PENDING,0);
        write32(ENABLE_S,4); write32(CLAIM_S,1); read32(PENDING,0);
        write32(CLAIM_M,1); read32(PENDING,2); irqs(1,0);
        read32(CLAIM_M,1); levels(0,1); write32(CLAIM_M,1); read32(PENDING,0);
        // ID2 was claimed by S but completed by M; no owner check is allowed.
        write32(CLAIM_M,2); read32(PENDING,4); irqs(1,1);
        write32(THRESH_M,15); irqs(0,1);
        read32(CLAIM_M,2); read32(PENDING,0); irqs(0,0);
        levels(0,0); write32(CLAIM_S,2); read32(PENDING,0);

        // A pending gateway request survives source deassertion, disabling
        // and zero priority. It becomes claimable once enabled with priority.
        write32(ENABLE_M,0); write32(ENABLE_S,0); write32(PRIO1,0);
        levels(1,0); levels(0,0); read32(PENDING,2); irqs(0,0);
        write32(ENABLE_M,2); read32(CLAIM_M,0);
        write32(PRIO1,2); irqs(0,0); read32(CLAIM_M,1); read32(PENDING,0);
        write32(CLAIM_M,1); levels(1,0); read32(PENDING,2);
        read32(CLAIM_M,1); levels(0,0); levels(1,0); levels(0,0);
        write32(CLAIM_M,1); read32(PENDING,0); // pulses while in service are not queued

        // Masking a claimed source makes completion ineffective. Re-enable
        // the context and complete again to recover without a reset.
        levels(1,0); read32(CLAIM_M,1); levels(0,0);
        write32(ENABLE_M,0); write32(CLAIM_M,1);
        if(!dut.in_service_1) $fatal(1,"disabled completion cleared gateway");
        write32(ENABLE_M,2); write32(CLAIM_M,1);
        if(dut.in_service_1) $fatal(1,"re-enabled completion failed to recover gateway");

        // Claim one source while completing another. Each gateway progresses
        // independently, with no lost clear, re-pend or context interaction.
        write32(ENABLE_M,6); write32(ENABLE_S,6); write32(THRESH_M,0);
        write32(PRIO1,2); write32(PRIO2,3);
        levels(0,1); read32(CLAIM_S,2); levels(1,1);
        @(negedge clk);
        re=1; raddr=BASE+CLAIM_M;
        we=1; waddr=BASE+CLAIM_S; wdata=64'h0000000200000000; wstrb=8'hf0;
        #1; if(rdata[63:32]!==1) $fatal(1,"concurrent claim returned wrong source");
        @(negedge clk); re=0; we=0;
        read32(PENDING,4); read32(CLAIM_M,2);
        levels(0,0); write32(CLAIM_S,1); write32(CLAIM_M,2); read32(PENDING,0);

        // Exhaustive four-bit priority, enable and threshold arbitration.
        // Peek (re=0) so the two pending requests persist throughout the sweep.
        reset(); levels(1,1); levels(0,0);
        for(integer p1=0;p1<16;p1=p1+1) begin
            write32(PRIO1,32'(p1));
            for(integer p2=0;p2<16;p2=p2+1) begin
                write32(PRIO2,32'(p2));
                for(integer en=0;en<4;en=en+1) begin
                    write32(ENABLE_M,32'(en<<1)); write32(ENABLE_S,32'((3-en)<<1));
                    expect_m=winner(p1,p2,2'(en)); expect_s=winner(p1,p2,2'(3-en));
                    for(integer threshold=0;threshold<16;threshold=threshold+1) begin
                        write32(THRESH_M,32'(threshold)); write32(THRESH_S,32'(15-threshold));
                        p_m=expect_m==1 ? p1 : expect_m==2 ? p2 : 0;
                        p_s=expect_s==1 ? p1 : expect_s==2 ? p2 : 0;
                        irqs(p_m>threshold,p_s>15-threshold);
                        read32(CLAIM_M,expect_m,0); read32(CLAIM_S,expect_s,0);
                    end
                end
            end
        end
        read32(PENDING,6);
        if (checker_u.fails != 0) $fatal(1,"PLIC checker reported failures");
        $display("[PLIC] ALL PASS: %0d checks",checks);
        $finish;
    end
    initial begin #4000000; $fatal(1,"PLIC timeout"); end
endmodule
