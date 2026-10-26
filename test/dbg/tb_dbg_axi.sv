// Debug aperture AXI adapter: protocol, authorization and side-effect checks.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_dbg_axi;
    reg clk=0, rst=1, allow=1;
    reg [3:0] arid=0, awid=0;
    reg [31:0] araddr=0, awaddr=0;
    reg [7:0] arlen=0, awlen=0;
    reg [2:0] arsize=3, awsize=3, arprot=0, awprot=0;
    reg [1:0] arburst=1, awburst=1;
    reg arvalid=0, awvalid=0, wvalid=0, wlast=1, rready=0, bready=0;
    wire arready, awready, wready, rvalid, rlast, bvalid;
    wire [3:0] rid, bid;
    wire [63:0] rdata;
    wire [1:0] rresp, bresp;
    reg [63:0] wdata=0;
    reg [7:0] wstrb=0;
    wire mem_req, mem_write;
    wire [11:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_be;
    reg mem_ready=1;
    wire [63:0] mem_rdata = 64'hfeedface00000000 | {52'b0,mem_addr};
    wire mem_error = mem_addr == 12'h3f0;
    integer reads=0, writes=0, checks=0, before_reads, before_writes, n;
    reg [63:0] last_write;
    reg [7:0] last_be;
    reg [11:0] last_addr;
    reg rstall=0, bstall=0, mstall=0;
    reg [70:0] rheld;
    reg [5:0] bheld;
    reg [84:0] mheld;
    karudbg_axi dut (
        .clk(clk),.rst(rst),.allow_i(allow),
        .s_arid(arid),.s_araddr(araddr),.s_arlen(arlen),.s_arsize(arsize),
        .s_arburst(arburst),.s_arprot(arprot),.s_arvalid(arvalid),.s_arready(arready),
        .s_rid(rid),.s_rdata(rdata),.s_rresp(rresp),.s_rlast(rlast),.s_rvalid(rvalid),.s_rready(rready),
        .s_awid(awid),.s_awaddr(awaddr),.s_awlen(awlen),.s_awsize(awsize),
        .s_awburst(awburst),.s_awprot(awprot),.s_awvalid(awvalid),.s_awready(awready),
        .s_wdata(wdata),.s_wstrb(wstrb),.s_wlast(wlast),.s_wvalid(wvalid),.s_wready(wready),
        .s_bid(bid),.s_bresp(bresp),.s_bvalid(bvalid),.s_bready(bready),
        .mem_req_o(mem_req),.mem_write_o(mem_write),.mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),.mem_be_o(mem_be),.mem_rdata_i(mem_rdata),
        .mem_ready_i(mem_ready),.mem_error_i(mem_error)
    );
    always #5 clk=~clk;
    always @(posedge clk) begin
        if (rst) begin rstall<=0; bstall<=0; mstall<=0; end
        else begin
            if (rstall && (!rvalid || {rid,rdata,rresp,rlast} !== rheld))
                $fatal(1,"R payload changed under backpressure");
            if (bstall && (!bvalid || {bid,bresp} !== bheld))
                $fatal(1,"B payload changed under backpressure");
            if (mstall && (!mem_req || {mem_write,mem_addr,mem_wdata,mem_be} !== mheld))
                $fatal(1,"DM memory request changed under backpressure");
            rstall<=rvalid && !rready; rheld<={rid,rdata,rresp,rlast};
            bstall<=bvalid && !bready; bheld<={bid,bresp};
            mstall<=mem_req && !mem_ready; mheld<={mem_write,mem_addr,mem_wdata,mem_be};
            if (mem_req && mem_ready) begin
                if (mem_write) begin
                    writes<=writes+1; last_write<=mem_wdata;
                    last_be<=mem_be; last_addr<=mem_addr;
                end else reads<=reads+1;
            end
        end
    end
    task check(input reg condition,input string text_label);
        begin checks=checks+1; if(condition !== 1'b1) $fatal(1,"%s",text_label); end
    endtask
    task clocks(input integer count);
        begin repeat(count) @(negedge clk); end
    endtask
    task send_ar(input reg[31:0] address,input reg[7:0] len);
        begin
            @(negedge clk); araddr=address; arlen=len; arid=4'h9; arvalid=1;
            do @(posedge clk); while(!arready);
            @(negedge clk); arvalid=0;
        end
    endtask
    task send_aw(input reg[31:0] address,input reg[7:0] len);
        begin
            @(negedge clk); awaddr=address; awlen=len; awid=4'h6; awvalid=1;
            do @(posedge clk); while(!awready);
            @(negedge clk); awvalid=0;
        end
    endtask
    task send_w(input reg[63:0] data,input reg[7:0] enables,input reg last);
        begin
            @(negedge clk); wdata=data; wstrb=enables; wlast=last; wvalid=1;
            do @(posedge clk); while(!wready);
            @(negedge clk); wvalid=0;
        end
    endtask
    task get_r(input reg[1:0] expected,input reg expected_last);
        begin
            while(!rvalid) @(negedge clk);
            clocks(3);
            check(rresp==expected,"read response");
            check(rid==9,"read ID"); check(rlast==expected_last,"read last");
            rready=1; @(posedge clk); @(negedge clk); rready=0;
        end
    endtask
    task get_b(input reg[1:0] expected);
        begin
            while(!bvalid) @(negedge clk);
            clocks(4);
            check(bresp==expected,"write response"); check(bid==6,"write ID");
            bready=1; @(posedge clk); @(negedge clk); bready=0;
        end
    endtask
    initial begin
        clocks(4); rst=0;
        // Read acceptance latches authorization, even with a stalled DM.
        mem_ready=0; send_ar(32'h00120100,0); allow=0; clocks(8);
        check(mem_req && !mem_write,"allowed read survives mode transition");
        mem_ready=1; get_r(0,1); check(reads==1,"one read side effect");
        check(rdata==64'hfeedface00000100,"read data");

        // A denied read cannot become allowed by a later mode transition.
        before_reads=reads; send_ar(32'h00120108,0); allow=1;
        get_r(3,1); check(reads==before_reads,"denied read has no side effect");
        send_ar(32'h00130108,0); get_r(3,1);
        check(reads==before_reads,"wrong page has no side effect");

        // W before AW; independent channels and byte enables survive stalls.
        mem_ready=0; send_w(64'h0123456789abcdef,8'h3c,1);
        clocks(4); send_aw(32'h00120208,0); allow=0; clocks(5);
        check(mem_req && mem_write,"allowed write survives mode transition");
        mem_ready=1; get_b(0);
        check(writes==1 && last_write==64'h0123456789abcdef && last_be==8'h3c && last_addr==12'h208,"write data and enables");

        // AW before W, rejected using AW-time identity despite later enable.
        before_writes=writes; send_aw(32'h00120210,0); allow=1;
        clocks(4); send_w(64'hbadbadbadbadbad,8'hff,1); get_b(3);
        check(writes==before_writes,"denied write has no side effect");

        // Simultaneous read/write queues use the single DM port once each.
        fork
            begin send_ar(32'h00120180,0); get_r(0,1); end
            begin send_aw(32'h00120280,0); send_w(64'h5555,8'h81,1); get_b(0); end
        join
        check(reads==before_reads+1 && writes==before_writes+1,"concurrent read/write exactly once");

        send_ar(32'h001203f0,0); get_r(2,1);
        send_aw(32'h001203f0,0); send_w(0,8'hff,1); get_b(2);

        // Unsupported bursts must complete their protocol without DM accesses.
        before_reads=reads; before_writes=writes;
        send_ar(32'h00120000,2); get_r(2,0); get_r(2,0); get_r(2,1);
        send_aw(32'h00120000,2);
        send_w(1,8'hff,0); send_w(2,8'hff,0); send_w(3,8'hff,1); get_b(2);
        check(reads==before_reads && writes==before_writes,"rejected bursts have no side effects");

        // All native byte-lane combinations, including an empty write mask.
        for(n=0;n<256;n=n+1) begin
            send_aw(32'h00120200,0); send_w(64'hff00aa5512345678,n[7:0],1); get_b(0);
            check(last_be==n[7:0],"byte-enable preservation");
        end
        // Reset drops an incomplete AW and response without touching DM.
        before_writes=writes; send_aw(32'h00120200,0); rst=1; clocks(2); rst=0; clocks(3);
        check(!mem_req && !rvalid && !bvalid && writes==before_writes,"reset clears partial request");
        $display("PASS debug AXI checks=%0d reads=%0d writes=%0d",checks,reads,writes);
        $finish;
    end
    initial begin #300000; $fatal(1,"debug AXI test timeout"); end
endmodule
