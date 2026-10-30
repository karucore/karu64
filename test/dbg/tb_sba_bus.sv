// Independent protocol/ordering tests for the core/SBA arbiter.
// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module tb_sba_bus;
`ifdef TEST_SBA_SECURE
    localparam NONSECURE=0;
`else
    localparam NONSECURE=1;
`endif
`ifdef TEST_SBA_LOCKED
    localparam ENABLE=0;
`else
    localparam ENABLE=1;
`endif
    localparam [2:0] SBA_PROT={1'b0,NONSECURE!=0,1'b1};
    reg  clk = 0;
    reg  rst = 0;
    reg  req_valid_i = 0;
    wire  req_ready_o;
    reg [63:0] req_addr_i = 0;
    reg [63:0] req_data_i = 0;
    reg [2:0] req_size_i = 0;
    reg  req_write_i = 0;
    wire  resp_valid_o;
    reg  resp_ready_i = 0;
    wire [63:0] resp_data_o;
    wire [2:0] resp_error_o;
    wire  pause_o;
    reg  quiet_i = 0;
    wire  flush_o;
    reg [3:0] c_arid = 0;
    reg [31:0] c_araddr = 0;
    reg [7:0] c_arlen = 0;
    reg [2:0] c_arsize = 0;
    reg [1:0] c_arburst = 0;
    reg [2:0] c_arprot = 0;
    reg  c_arvalid = 0;
    reg  c_rready = 0;
    reg [3:0] c_awid = 0;
    reg [31:0] c_awaddr = 0;
    reg [7:0] c_awlen = 0;
    reg [2:0] c_awsize = 0;
    reg [1:0] c_awburst = 0;
    reg [2:0] c_awprot = 0;
    reg  c_awvalid = 0;
    reg [63:0] c_wdata = 0;
    reg [7:0] c_wstrb = 0;
    reg  c_wlast = 0;
    reg  c_wvalid = 0;
    reg  c_bready = 0;
    wire  c_arready;
    wire [3:0] c_rid;
    wire [63:0] c_rdata;
    wire [1:0] c_rresp;
    wire  c_rlast;
    wire  c_rvalid;
    wire  c_awready;
    wire  c_wready;
    wire [3:0] c_bid;
    wire [1:0] c_bresp;
    wire  c_bvalid;
    wire [3:0] m_arid;
    wire [31:0] m_araddr;
    wire [7:0] m_arlen;
    wire [2:0] m_arsize;
    wire [1:0] m_arburst;
    wire [2:0] m_arprot;
    wire  m_arvalid;
    wire  m_rready;
    wire [3:0] m_awid;
    wire [31:0] m_awaddr;
    wire [7:0] m_awlen;
    wire [2:0] m_awsize;
    wire [1:0] m_awburst;
    wire [2:0] m_awprot;
    wire  m_awvalid;
    wire [63:0] m_wdata;
    wire [7:0] m_wstrb;
    wire  m_wlast;
    wire  m_wvalid;
    wire  m_bready;
    reg  m_arready = 0;
    reg [3:0] m_rid = 0;
    reg [63:0] m_rdata = 0;
    reg [1:0] m_rresp = 0;
    reg  m_rlast = 0;
    reg  m_rvalid = 0;
    reg  m_awready = 0;
    reg  m_wready = 0;
    reg [3:0] m_bid = 0;
    reg [1:0] m_bresp = 0;
    reg  m_bvalid = 0;
    integer checks=0, ars=0, aws=0, ws=0, flushes=0;
    always #5 clk=!clk;
    karudbg_bus #(.NONSECURE(NONSECURE),.ENABLE(ENABLE)) dut (
        .clk(clk),
        .rst(rst),
        .req_valid_i(req_valid_i),
        .req_ready_o(req_ready_o),
        .req_addr_i(req_addr_i),
        .req_data_i(req_data_i),
        .req_size_i(req_size_i),
        .req_write_i(req_write_i),
        .resp_valid_o(resp_valid_o),
        .resp_ready_i(resp_ready_i),
        .resp_data_o(resp_data_o),
        .resp_error_o(resp_error_o),
        .pause_o(pause_o),
        .quiet_i(quiet_i),
        .flush_o(flush_o),
        .c_arid(c_arid),
        .c_araddr(c_araddr),
        .c_arlen(c_arlen),
        .c_arsize(c_arsize),
        .c_arburst(c_arburst),
        .c_arprot(c_arprot),
        .c_arvalid(c_arvalid),
        .c_rready(c_rready),
        .c_awid(c_awid),
        .c_awaddr(c_awaddr),
        .c_awlen(c_awlen),
        .c_awsize(c_awsize),
        .c_awburst(c_awburst),
        .c_awprot(c_awprot),
        .c_awvalid(c_awvalid),
        .c_wdata(c_wdata),
        .c_wstrb(c_wstrb),
        .c_wlast(c_wlast),
        .c_wvalid(c_wvalid),
        .c_bready(c_bready),
        .c_arready(c_arready),
        .c_rid(c_rid),
        .c_rdata(c_rdata),
        .c_rresp(c_rresp),
        .c_rlast(c_rlast),
        .c_rvalid(c_rvalid),
        .c_awready(c_awready),
        .c_wready(c_wready),
        .c_bid(c_bid),
        .c_bresp(c_bresp),
        .c_bvalid(c_bvalid),
        .m_arid(m_arid),
        .m_araddr(m_araddr),
        .m_arlen(m_arlen),
        .m_arsize(m_arsize),
        .m_arburst(m_arburst),
        .m_arprot(m_arprot),
        .m_arvalid(m_arvalid),
        .m_rready(m_rready),
        .m_awid(m_awid),
        .m_awaddr(m_awaddr),
        .m_awlen(m_awlen),
        .m_awsize(m_awsize),
        .m_awburst(m_awburst),
        .m_awprot(m_awprot),
        .m_awvalid(m_awvalid),
        .m_wdata(m_wdata),
        .m_wstrb(m_wstrb),
        .m_wlast(m_wlast),
        .m_wvalid(m_wvalid),
        .m_bready(m_bready),
        .m_arready(m_arready),
        .m_rid(m_rid),
        .m_rdata(m_rdata),
        .m_rresp(m_rresp),
        .m_rlast(m_rlast),
        .m_rvalid(m_rvalid),
        .m_awready(m_awready),
        .m_wready(m_wready),
        .m_bid(m_bid),
        .m_bresp(m_bresp),
        .m_bvalid(m_bvalid));
    task check(input bit condition,input string text);
        begin checks++; if(!condition) $fatal(1,"SBA bus check %0d: %s",checks,text); end
    endtask
    task tick;
        begin @(posedge clk); #1; end
    endtask
    task low;
        begin @(negedge clk); end
    endtask
    always @(posedge clk) if(!rst) begin
        if(m_arvalid&&m_arready) ars++;
        if(m_awvalid&&m_awready) aws++;
        if(m_wvalid&&m_wready) ws++;
        if(flush_o) flushes++;
    end
    task reset_bus;
        begin
            low; rst=1; req_valid_i=0; resp_ready_i=0; quiet_i=0;
            c_arvalid=0;c_awvalid=0;c_wvalid=0;c_rready=0;c_bready=0;
            m_arready=0;m_awready=0;m_wready=0;m_rvalid=0;m_bvalid=0;
            repeat(2) tick;
            low; rst=0; tick;
            check(!pause_o&&!flush_o&&!resp_valid_o,"reset releases maintenance and reply");
        end
    endtask
    task request(input [63:0] addr,input [2:0] size,input bit write);
        integer wait_cycles;
        begin
            low; req_addr_i=addr;req_data_i=64'h0123456789abcdef;
            req_size_i=size;req_write_i=write;req_valid_i=1;
            // RAM writes first raise the registered hold, then wait for the
            // core's drained acknowledgement. Other requests remain immediate.
            #1;wait_cycles=0;
            while(!req_ready_o && wait_cycles<4)begin
                tick;low;wait_cycles++;
            end
            #1;check(req_ready_o,"SBA request ready");tick;low;req_valid_i=0;
        end
    endtask
    task reply(input [2:0] expected_error);
        reg [63:0] saved_data;
        begin
            #1;check(resp_valid_o&&resp_error_o==expected_error,"SBA response and error");
            saved_data=resp_data_o;
            repeat(3) begin tick;check(resp_valid_o&&resp_error_o==expected_error&&resp_data_o==saved_data,
                                     "SBA reply stable under backpressure");end
            low;resp_ready_i=1;tick;low;resp_ready_i=0;
            check(!resp_valid_o&&!pause_o&&!flush_o,"reply accepted releases pause");
        end
    endtask
    task invalid_request(input [63:0] addr,input [2:0] size,input bit write,input [2:0] error);
        integer a,w,r;
        begin a=aws;w=ws;r=ars;request(addr,size,write);
            check(!m_arvalid&&!m_awvalid&&!m_wvalid&&!pause_o,"rejected access has no bus effect");
            reply(error);check(a==aws&&w==ws&&r==ars,"rejected access count unchanged");
        end
    endtask
    task do_write(input [63:0] addr,input [2:0] size,input bit data_first,input bit ram,input [1:0] bus_error);
        reg [7:0] be;
        reg [63:0] data;
        integer a,w,f;
        begin
            a=aws;w=ws;f=flushes;quiet_i=1;
            request(addr,size,1);
            be=(size==0?8'h01:size==1?8'h03:size==2?8'h0f:8'hff)<<addr[2:0];
            data=64'h0123456789abcdef<<(8*addr[2:0]);
            check(m_awvalid&&m_wvalid&&m_awaddr==addr[31:0]&&m_awlen==0&&m_awsize==size&&
                  m_awburst==1&&m_awprot==SBA_PROT&&m_wstrb==be&&m_wdata==data&&m_wlast,
                  "native SBA write address, data, strobe and protection");
            repeat(3) begin tick;check(m_awvalid&&m_wvalid&&m_wdata==data&&m_wstrb==be,
                                      "write holds while AW/W stalled");end
            low;
            if(data_first)m_wready=1;else m_awready=1;
            tick;low;m_wready=0;m_awready=0;
            check(data_first?(!m_wvalid&&m_awvalid):(!m_awvalid&&m_wvalid),"independent AW/W acceptance");
            repeat(2) tick;
            low;if(data_first)m_awready=1;else m_wready=1;
            tick;low;m_awready=0;m_wready=0;
            check(m_bready&&!resp_valid_o,"write waits for B after both channels");
            repeat(3)tick;
            low;m_bvalid=1;m_bresp=bus_error;tick;low;m_bvalid=0;
            if(ram)begin
                check(flush_o&&pause_o&&!resp_valid_o,"RAM write flush precedes result");
                quiet_i=0;
                repeat(2)begin tick;check(flush_o&&pause_o&&!resp_valid_o,"maintenance waits quiet");end
                low;quiet_i=1;tick;low;
            end
            reply(bus_error[1]?3'd2:3'd0);
            check(aws==a+1&&ws==w+1,"exact one AW and W");
            check(ram?flushes>f:flushes==f,"RAM-only cache maintenance");
        end
    endtask
    task do_read(input [63:0] addr,input [2:0] size,input [1:0] bus_error,input bit last);
        integer a;
        begin
            a=ars;request(addr,size,0);
            check(m_arvalid&&m_araddr==addr[31:0]&&m_arlen==0&&m_arsize==size&&m_arburst==1&&m_arprot==SBA_PROT,
                  "native SBA read address and attributes");
            repeat(3)begin tick;check(m_arvalid&&m_araddr==addr[31:0],"AR held under backpressure");end
            low;m_arready=1;tick;low;m_arready=0;
            check(!m_arvalid&&!resp_valid_o,"read issues AR once then waits data");
            repeat(2)tick;
            low;m_rvalid=1;m_rdata=64'hfedcba9876543210;m_rresp=bus_error;m_rlast=last;
            check(m_rready,"SBA read accepts one response");tick;low;m_rvalid=0;
            check(resp_data_o==(64'hfedcba9876543210>>(8*addr[2:0])),"read lane extraction");
            reply(bus_error[1]||!last?3'd2:3'd0);
            check(ars==a+1,"exact one AR");
        end
    endtask
    task coincident_read;
        integer before_ar;
        begin
            before_ar=ars;request(64'h10000000,3,0);
            low;m_arready=1;m_rvalid=1;m_rlast=1;m_rresp=0;m_rdata=64'h1122334455667788;
            #1;check(m_arvalid&&m_rready,"coincident AR/R both accepted");
            tick;low;m_arready=0;m_rvalid=0;
            check(resp_data_o==64'h1122334455667788&&ars==before_ar+1,
                  "zero-latency read owns and returns exactly one response");
            reply(0);
        end
    endtask
    task core_read;
        integer beat;
        begin
            low;c_arvalid=1;c_araddr=32'h80001000;c_arid=4'hb;c_arlen=3;c_arsize=3;c_arburst=1;c_arprot=3'b101;
            req_valid_i=1;req_addr_i=64'h10000000;req_size_i=2;req_write_i=0;
            #1;check(!req_ready_o&&m_arvalid&&m_araddr==c_araddr&&m_arid==c_arid&&m_arlen==3&&m_arprot==c_arprot,
                     "core AR has priority and preserves burst fields");
            m_arready=1;tick;low;c_arvalid=0;m_arready=0;
            for(beat=0;beat<4;beat++)begin
                m_rvalid=1;m_rid=4'hb;m_rdata=64'hffff0000+64'(beat);m_rresp=beat==1?2:0;m_rlast=beat==3;
                c_rready=0;#1;
                repeat(2)begin tick;check(c_rvalid&&c_rid==4'hb&&c_rdata==m_rdata&&c_rresp==m_rresp&&c_rlast==m_rlast&&!m_rready&&!req_ready_o,
                                         "core R routing and held ownership");end
                low;c_rready=1;tick;low;m_rvalid=0;c_rready=0;
            end
            req_valid_i=0;
            check(!c_rvalid&&req_ready_o,"core read releases SBA arbitration");
        end
    endtask
    task core_write;
        integer beat;
        begin
            low;c_wvalid=1;c_wdata=64'h5555;c_wstrb=8'h55;c_wlast=0;
            c_awaddr=32'h80002000;c_awid=4'hc;c_awlen=1;c_awsize=3;c_awburst=1;c_awprot=3'b100;
            m_wready=1;#1;check(m_wvalid&&m_wdata==c_wdata&&m_wstrb==c_wstrb&&!m_wlast,"core W before AW forwarded");
            tick;low;c_wvalid=0;m_wready=0;
            c_awvalid=1;m_awready=1;#1;
            check(m_awid==4'hc&&m_awlen==1&&m_awprot==3'b100&&m_awaddr==c_awaddr,"core AW fields preserved");
            tick;low;c_awvalid=0;m_awready=0;
            c_wvalid=1;c_wdata=64'haaaa;c_wstrb=8'hff;c_wlast=1;
            repeat(2)begin tick;check(m_wvalid&&m_wlast&&m_wdata==64'haaaa,"core second beat stall");end
            low;m_wready=1;tick;low;c_wvalid=0;m_wready=0;
            m_bvalid=1;m_bid=4'hc;m_bresp=2;c_bready=0;
            repeat(3)begin tick;check(c_bvalid&&c_bid==4'hc&&c_bresp==2&&!m_bready,"core B backpressure and owner");end
            low;c_bready=1;tick;low;m_bvalid=0;c_bready=0;
            check(req_ready_o,"core B completion releases owner");
        end
    endtask
    integer size,offset,phase;
    task registered_pause;
        begin
            low;quiet_i=1;req_addr_i=64'h80001000;req_write_i=1;
            req_size_i=3;req_valid_i=1;
            #1;check(!pause_o,"pause has no combinational request/reset path");
            check(!req_ready_o&&!m_awvalid&&!m_wvalid,
                  "RAM acceptance waits for registered pause");
            tick;check(pause_o&&req_ready_o,"registered pause precedes quiet acceptance");
            // Model the instruction admitted on the hold's assertion edge:
            // quiet must fall before the following acceptance edge.
            low;quiet_i=0;
            repeat(3)begin tick;check(pause_o&&!req_ready_o&&!m_awvalid&&!m_wvalid,
                                    "registered pause drains newly admitted older work");end
            low;req_valid_i=0;
            #1;check(pause_o,"withdrawal changes pause only on a clock edge");
            tick;check(!pause_o,"withdrawal releases registered pause");
            low;req_valid_i=1;tick;check(pause_o,"reset probe has a pending pause");
            low;req_valid_i=0;rst=1;
            #1;check(pause_o,"pause has no combinational request/reset path");
            tick;check(!pause_o,"synchronous reset clears pause");
            low;rst=0;tick;quiet_i=1;
        end
    endtask
    initial begin
        reset_bus;
        if($test$plusargs("bad_bus_state"))begin
            force dut.state=7;repeat(2)tick;$fatal(1,"missing SBAB1");
        end
        if($test$plusargs("bad_bus_owner"))begin
            force dut.state=3;repeat(2)tick;$fatal(1,"missing SBAB2");
        end
        if($test$plusargs("bad_bus_pause"))begin
            force pause_o=1;repeat(2)tick;$fatal(1,"missing SBAB8");
        end
        if($test$plusargs("bad_bus_isolation"))begin
            request(64'h10000000,2,0);force c_rvalid=1;
            repeat(2)tick;$fatal(1,"missing SBAB3");
        end
        if($test$plusargs("bad_bus_drain"))begin
            low;req_valid_i=1;req_write_i=1;req_addr_i=64'h80001000;
            req_size_i=3;quiet_i=0;force req_ready_o=1;
            repeat(2)tick;$fatal(1,"missing SBAB4");
        end
        if($test$plusargs("bad_bus_duplicate"))begin
            request(64'h10000000,2,0);m_arready=1;tick;low;
            force dut.aw_done=0;repeat(2)tick;$fatal(1,"missing SBAB4");
        end
        if($test$plusargs("bad_bus_maintenance"))begin
            quiet_i=1;request(64'h80001000,3,1);force dut.state=5;
            repeat(2)tick;$fatal(1,"missing SBAB5");
        end
        if($test$plusargs("bad_bus_stability"))begin
            request(64'h10000000,2,0);tick;low;force dut.addr_q=32'h10000008;
            repeat(2)tick;$fatal(1,"missing SBAB6");
        end
        if($test$plusargs("bad_bus_reply"))begin
            request(64'h120380,2,0);tick;low;force resp_error_o=7;
            repeat(2)tick;$fatal(1,"missing SBAB7");
        end
`ifdef TEST_SBA_LOCKED
        invalid_request(64'h80000000,3,0,2);invalid_request(64'h80000000,3,1,2);
        invalid_request(64'h10000000,2,0,2);invalid_request(64'h10000000,2,1,2);
        invalid_request(64'h1000,3,0,2);
        // Locking the independent debugger master must leave core traffic usable.
        core_read;core_write;
        $display("karudbg SBA bus locked: PASS (%0d checks)",checks);$finish;
`endif
        registered_pause;
        // All native widths and legal lane offsets, alternating AW-first/W-first.
        for(size=0;size<4;size++)for(offset=0;offset<8;offset=offset+(1<<size))begin
            do_read(64'h10000000+64'(offset),3'(size),0,1);
            do_write(64'h10000000+64'(offset),3'(size),offset[0],0,0);
        end
        coincident_read;
        do_read(64'h80001000,3,2,1);do_read(64'h80001000,3,0,0);
        do_write(64'h10000000,2,1,0,2);
        do_write(64'h80001000,3,1,1,0);
        do_write(64'h80001000,3,0,1,2);
        do_write(64'h00101000,3,1,1,0);do_write(64'h00110ff8,3,0,1,0);
        invalid_request(64'h120380,2,0,2);invalid_request(64'h120380,2,1,2);
        invalid_request(64'h180000000,3,0,2);invalid_request(64'h0,3,0,2);
        invalid_request(64'h1000,3,1,2);invalid_request(64'h10000001,1,0,3);
        invalid_request(64'h10000000,4,0,4);
        core_read;core_write;
        // Pending maintenance keeps issue paused throughout the final older
        // core write, rather than dropping pause while the arbiter owns CW.
        low;quiet_i=0;req_valid_i=1;req_addr_i=64'h80001000;req_size_i=3;req_write_i=1;
        c_awvalid=1;c_wvalid=1;c_awlen=0;c_wlast=1;m_awready=1;m_wready=1;
        tick;low;c_awvalid=0;c_wvalid=0;m_awready=0;m_wready=0;
        repeat(3)begin tick;check(pause_o&&!req_ready_o&&!m_awvalid&&!m_wvalid,
                                  "pending RAM pause spans older core write drain");end
        low;m_bvalid=1;c_bready=1;tick;low;m_bvalid=0;c_bready=0;
        check(pause_o&&!req_ready_o,"drain precedes SBA AW and W (final quiet acknowledgement)");
        req_valid_i=0;tick;check(!pause_o,"cancel after older write releases pause");
        // A RAM write may request the pause before accepting a transfer, but
        // neither AXI write channel can launch until older accesses drain.
        low;quiet_i=0;req_valid_i=1;req_addr_i=64'h80001000;req_write_i=1;req_size_i=3;
        repeat(5)begin tick;check(pause_o&&!req_ready_o&&!m_awvalid&&!m_wvalid,"drain precedes SBA AW and W");end
        low;req_valid_i=0;tick;check(!pause_o&&!flush_o,"withdrawn unissued request releases pause");
        // Reset with requests stalled at each externally visible phase.
        for(phase=0;phase<6;phase++)begin
            reset_bus;quiet_i=1;
            if(phase==0)begin
                low;quiet_i=0;req_addr_i=64'h80001000;req_write_i=1;req_size_i=3;req_valid_i=1;tick;
            end else begin
                request(64'h80001000,3,phase!=1);
                if(phase>=3)begin low;m_wready=1;tick;low;m_wready=0;end
                if(phase>=4)begin low;m_awready=1;tick;low;m_awready=0;end
                if(phase>=5)begin low;m_bvalid=1;tick;low;m_bvalid=0;end
            end
            reset_bus;
        end
        $display("karudbg SBA bus: PASS (%0d checks; AR=%0d AW=%0d W=%0d)",checks,ars,aws,ws);
        $finish;
    end
    initial begin #1000000;$fatal(1,"SBA bus timeout");end
endmodule
