// AXI RAM, BRAM SoC and DDR crossbar backends: separated AW/W, two-beat
// bursts, B/R holds, and MMIO snapshots despite changing request/device data.
`include "karu_axi_defs.vh"
`timescale 1ns/1ps
module tb_axi_mem_burst;
    reg clk = 0;
    reg rst = 0;
    reg [`AXI_ID_W-1:0]		imem_arid = 0;
    reg [`AXI_ADDR_W-1:0]	imem_araddr = 0;
    reg [`AXI_LEN_W-1:0]	imem_arlen = 0;
    reg [`AXI_SIZE_W-1:0]	imem_arsize = 0;
    reg [`AXI_BURST_W-1:0]	imem_arburst = 0;
    reg [`AXI_PROT_W-1:0]	imem_arprot = 0;
    reg imem_arvalid = 0;
    wire imem_arready;
    wire [`AXI_ID_W-1:0]		imem_rid;
    wire [`AXI_DATA_W-1:0]	imem_rdata;
    wire [`AXI_RESP_W-1:0]	imem_rresp;
    wire imem_rlast;
    wire imem_rvalid;
    reg imem_rready = 0;
    reg [`AXI_ID_W-1:0]		dmem_arid = 0;
    reg [`AXI_ADDR_W-1:0]	dmem_araddr = 0;
    reg [`AXI_LEN_W-1:0]	dmem_arlen = 0;
    reg [`AXI_SIZE_W-1:0]	dmem_arsize = 0;
    reg [`AXI_BURST_W-1:0]	dmem_arburst = 0;
    reg [`AXI_PROT_W-1:0]	dmem_arprot = 0;
    reg dmem_arvalid = 0;
    wire dmem_arready;
    wire [`AXI_ID_W-1:0]		dmem_rid;
    wire [`AXI_DATA_W-1:0]	dmem_rdata;
    wire [`AXI_RESP_W-1:0]	dmem_rresp;
    wire dmem_rlast;
    wire dmem_rvalid;
    reg dmem_rready = 0;
    reg [`AXI_ID_W-1:0]		dmem_awid = 0;
    reg [`AXI_ADDR_W-1:0]	dmem_awaddr = 0;
    reg [`AXI_LEN_W-1:0]	dmem_awlen = 0;
    reg [`AXI_SIZE_W-1:0]	dmem_awsize = 0;
    reg [`AXI_BURST_W-1:0]	dmem_awburst = 0;
    reg [`AXI_PROT_W-1:0]	dmem_awprot = 0;
    reg dmem_awvalid = 0;
    wire dmem_awready;
    reg [`AXI_DATA_W-1:0]	dmem_wdata = 0;
    reg [`AXI_STRB_W-1:0]	dmem_wstrb = 0;
    reg dmem_wlast = 0;
    reg dmem_wvalid = 0;
    wire dmem_wready;
    wire [`AXI_ID_W-1:0]		dmem_bid;
    wire [`AXI_RESP_W-1:0]	dmem_bresp;
    wire dmem_bvalid;
    reg dmem_bready = 0;
    wire uart_txd;
    reg uart_rxd = 0;
    wire uart_rts;
    reg uart_cts = 0;
    wire irq_timer;
    wire irq_software;
    wire irq_ext_m;
    wire irq_ext_s;
    always #5 clk=~clk;
`ifdef TEST_AXI4_RAM
    karu_axi4_ram #(.RAM_XADR(13), .HEXFILE("")) dut (
        .clk(clk), .rst(rst),
        .s_arid(dmem_arid), .s_araddr(dmem_araddr), .s_arlen(dmem_arlen),
        .s_arsize(dmem_arsize), .s_arburst(dmem_arburst),
        .s_arvalid(dmem_arvalid), .s_arready(dmem_arready),
        .s_rid(dmem_rid), .s_rdata(dmem_rdata), .s_rresp(dmem_rresp),
        .s_rlast(dmem_rlast), .s_rvalid(dmem_rvalid), .s_rready(dmem_rready),
        .s_awid(dmem_awid), .s_awaddr(dmem_awaddr), .s_awlen(dmem_awlen),
        .s_awsize(dmem_awsize), .s_awburst(dmem_awburst),
        .s_awvalid(dmem_awvalid), .s_awready(dmem_awready),
        .s_wdata(dmem_wdata), .s_wstrb(dmem_wstrb), .s_wlast(dmem_wlast),
        .s_wvalid(dmem_wvalid), .s_wready(dmem_wready),
        .s_bid(dmem_bid), .s_bresp(dmem_bresp), .s_bvalid(dmem_bvalid), .s_bready(dmem_bready)
    );
`elsif TEST_DDR_XBAR
    wire [`AXI_ID_W-1:0] m_arid, m_rid, m_awid, m_bid;
    wire [31:0] m_araddr, m_awaddr;
    wire [7:0] m_arlen, m_awlen, m_wstrb;
    wire [2:0] m_arsize, m_awsize;
    wire [1:0] m_arburst, m_awburst, m_rresp, m_bresp;
    wire [63:0] m_rdata, m_wdata, clint_mtime;
    wire m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;
    wire m_awvalid, m_awready, m_wvalid, m_wready, m_wlast, m_bvalid, m_bready;
    // This transport bench does not read the boot ROM. An empty image is
    // sufficient; the same RAM/MMIO cases run against the real crossbar.
    karu_ddr_xbar #(.ROM_HEX("/dev/null")) dut (.*);
    karu_axi4_ram #(.RAM_XADR(13), .HEXFILE("")) dram (
        .clk(clk), .rst(rst),
        .s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen),
        .s_arsize(m_arsize), .s_arburst(m_arburst),
        .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rid(m_rid), .s_rdata(m_rdata), .s_rresp(m_rresp),
        .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
        .s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen),
        .s_awsize(m_awsize), .s_awburst(m_awburst),
        .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
        .s_wvalid(m_wvalid), .s_wready(m_wready),
        .s_bid(m_bid), .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready)
    );
`elsif TEST_LINUX_AXI
    linux_tb #(.RAM_BYTES(8192)) dut (
        .clk(clk), .test_rst(rst), .sim_exit_code(), .sim_exit_valid(), .*
    );
`else
    karu_axi_mem #(.RAM_XADR(13), .HEXFILE("")) dut (.*);
`endif
    task automatic write_data(input [31:0] a, input [7:0] len, input [63:0] lo, input [63:0] hi,
                              input [1:0] resp=0, input [2:0] size=3, input [7:0] strb=8'hff);
        @(negedge clk);
        dmem_awaddr=a; dmem_awlen=len; dmem_awid=3;
        dmem_awsize=size; dmem_awburst=1; dmem_awvalid=1; dmem_bready=0;
`ifdef TEST_DDR_XBAR
        // Local DDR-crossbar MMIO accepts AW and W together. DRAM keeps
        // the separated channels below, including changed live AW pins.
        if(!a[31]) begin
            dmem_wdata=lo; dmem_wstrb=strb; dmem_wlast=1; dmem_wvalid=1;
            do @(posedge clk); while(!dmem_awready || !dmem_wready);
            @(negedge clk); dmem_awvalid=0; dmem_wvalid=0;
            dmem_awaddr=32'h10000000;
        end else begin
`endif
        do @(posedge clk); while(!dmem_awready);
        @(negedge clk); dmem_awvalid=0; dmem_awaddr=32'h10000000;
        repeat(3) @(negedge clk);
        dmem_wdata=lo; dmem_wstrb=strb; dmem_wlast=len==0; dmem_wvalid=1;
        do @(posedge clk); while(!dmem_wready);
        @(negedge clk); dmem_wvalid=0;
        if(len!=0) begin
            repeat(2) begin
                if(dmem_bvalid) $fatal(1,"B response before final W beat");
                @(negedge clk);
            end
            dmem_wdata=hi; dmem_wlast=1; dmem_wvalid=1;
            do @(posedge clk); while(!dmem_wready);
            @(negedge clk); dmem_wvalid=0;
        end
`ifdef TEST_DDR_XBAR
        end
`endif
        while(!dmem_bvalid) @(negedge clk);
        repeat(3) begin
            @(negedge clk);
            if(!dmem_bvalid || dmem_bid!=3 || dmem_bresp!=resp) $fatal(1,"B response not retained");
        end
        dmem_bready=1; @(negedge clk); dmem_bready=0;
    endtask
`ifdef TEST_LINUX_AXI
    task automatic write_w_before_aw;
        @(negedge clk);
        dmem_wdata=64'h13579bdf2468ace0; dmem_wstrb=8'hff;
        dmem_wlast=1; dmem_wvalid=1; dmem_bready=0;
        repeat(3) begin
            @(negedge clk);
            if(dmem_wready || dmem_bvalid) $fatal(1,"W accepted without AW");
        end
        dmem_awaddr=32'h80001020; dmem_awlen=0; dmem_awsize=3;
        dmem_awburst=1; dmem_awid=9; dmem_awvalid=1;
        do @(posedge clk); while(!dmem_awready || !dmem_wready);
        @(negedge clk); dmem_awvalid=0; dmem_wvalid=0;
        dmem_awaddr=32'h02004000; // live pins no longer name the transaction
        repeat(4) begin
            @(negedge clk);
            if(!dmem_bvalid || dmem_bid!=9 || dmem_bresp!=0)
                $fatal(1,"W-before-AW completion lost");
        end
        dmem_bready=1; @(negedge clk); dmem_bready=0;
    endtask

    task automatic read_rejected_burst(input [31:0] a);
        @(negedge clk);
        dmem_araddr=a; dmem_arlen=1; dmem_arsize=3; dmem_arburst=1;
        dmem_arid=10; dmem_arvalid=1; dmem_rready=0;
        do @(posedge clk); while(!dmem_arready);
        @(negedge clk); dmem_arvalid=0; dmem_araddr=32'hdeadbeef;
        for(integer beat=0;beat<2;beat=beat+1) begin
            while(!dmem_rvalid) @(negedge clk);
            repeat(3) begin
                @(negedge clk);
                if(!dmem_rvalid || dmem_rresp!=3 || dmem_rid!=10 || dmem_rlast!=(beat==1))
                    $fatal(1,"MMIO burst was not drained as an error");
            end
            dmem_rready=1; @(negedge clk); dmem_rready=0;
        end
    endtask

    task automatic malformed_write(input bit early_last);
        @(negedge clk);
        dmem_awaddr=32'h80001030; dmem_awlen=early_last ? 1 : 0;
        dmem_awsize=3; dmem_awburst=1; dmem_awid=11; dmem_awvalid=1;
        dmem_bready=0;
        do @(posedge clk); while(!dmem_awready);
        @(negedge clk); dmem_awvalid=0;
        dmem_wdata=64'hbad; dmem_wstrb=8'hff; dmem_wlast=early_last; dmem_wvalid=1;
        do @(posedge clk); while(!dmem_wready);
        @(negedge clk); dmem_wvalid=0;
        if(!early_last) begin
            repeat(3) begin
                if(dmem_bvalid) $fatal(1,"B asserted before malformed burst WLAST");
                @(negedge clk);
            end
            dmem_wlast=1; dmem_wvalid=1;
            do @(posedge clk); while(!dmem_wready);
            @(negedge clk); dmem_wvalid=0;
        end
        while(!dmem_bvalid) @(negedge clk);
        repeat(3) begin
            @(negedge clk);
            if(!dmem_bvalid || dmem_bresp!=2 || dmem_bid!=11)
                $fatal(1,"WLAST mismatch was silently accepted");
        end
        dmem_bready=1; @(negedge clk); dmem_bready=0;
    endtask
`endif
`ifdef TEST_DDR_XBAR
    task automatic read_flash_stalled;
        reg [63:0] held;
        begin
            write_data(32'h12000010,0,1,0); // two clocks per SPI half-period
            write_data(32'h12000000,0,0,0); // assert chip select
            write_data(32'h12000008,0,64'h5a,0);
            @(negedge clk);
            dmem_araddr=32'h12000000; dmem_arlen=0;
            dmem_arsize=3; dmem_arburst=1; dmem_arid=7;
            dmem_arvalid=1; dmem_rready=0;
            do @(posedge clk); while(!dmem_arready);
            @(negedge clk); dmem_arvalid=0; dmem_araddr=32'h12000008;
            while(!dmem_rvalid) @(negedge clk);
            held=dmem_rdata;
            if(held[1:0]!==2'b01) $fatal(1,"flash was not busy at snapshot");
            repeat(100) begin
                @(negedge clk);
                if(!dmem_rvalid || !dmem_rlast || dmem_rresp!=0 ||
                   dmem_rid!=7 || dmem_rdata!==held)
                    $fatal(1,"flash completion changed a stalled response");
            end
            if(dut.u_flash.active || !dut.u_flash.done)
                $fatal(1,"flash transfer did not complete during held response");
            dmem_rready=1; @(negedge clk); dmem_rready=0;
            read_data(32'h12000000,64'h6,0,3,64'h7);
            read_data(32'h12000008,64'hff,0,3,64'hff);
        end
    endtask
`endif
    task automatic read_data(input [31:0] a, input [63:0] expected, input [1:0] resp=0,
                             input [2:0] size=3, input [63:0] compare_mask=64'hffffffffffffffff);
        @(negedge clk);
        dmem_araddr=a; dmem_arlen=0; dmem_arsize=size; dmem_arburst=1;
        dmem_arvalid=1; dmem_rready=0;
        do @(posedge clk); while(!dmem_arready);
        @(negedge clk); dmem_arvalid=0; dmem_araddr=32'hdeadbeef;
        while(!dmem_rvalid) @(negedge clk);
        repeat(3) begin
            @(negedge clk);
            if(!dmem_rvalid || !dmem_rlast || dmem_rresp!=resp ||
               (resp==0 && (dmem_rdata & compare_mask)!==(expected & compare_mask)))
                $fatal(1,"read %h got %h expected %h",a,dmem_rdata,expected);
        end
        dmem_rready=1; @(negedge clk); dmem_rready=0;
    endtask
`ifndef TEST_AXI4_RAM
    task automatic read_timer_stalled;
        reg [63:0] held, first_mtime;
        begin
            @(negedge clk);
            dmem_araddr=32'h0200bff8; dmem_arlen=0;
            dmem_arsize=3; dmem_arburst=1; dmem_arid=5;
            dmem_arvalid=1; dmem_rready=0;
            do @(posedge clk); while(!dmem_arready);
            first_mtime=dut.u_clint.mtime;
            @(negedge clk); dmem_arvalid=0;
            dmem_araddr=32'h02004000; dmem_arsize=0;
            while(!dmem_rvalid) @(negedge clk);
            held=dmem_rdata;
            if(held<first_mtime || held>dut.u_clint.mtime)
                $fatal(1,"mtime response does not snapshot the accepted read");
            // Check all 64 bits, including the ticking low word. Holding
            // through four complete tick periods also proves this is not
            // merely a test that happened to run between timer increments.
            repeat(4*dut.u_clint.TICK_DIV+3) begin
                @(negedge clk);
                if(!dmem_rvalid || !dmem_rlast || dmem_rresp!=0 ||
                   dmem_rid!=5 || dmem_rdata!==held)
                    $fatal(1,"stalled mtime response changed: %h -> %h",held,dmem_rdata);
            end
            if(dut.u_clint.mtime-held<4)
                $fatal(1,"stalled mtime test did not span four ticks");
            dmem_rready=1; @(negedge clk); dmem_rready=0;
        end
    endtask
`ifndef TEST_LINUX_AXI
    task automatic uart_receive(input [7:0] value);
        @(negedge clk); uart_rxd=0;
        repeat(dut.u_uart.BITCLKS) @(negedge clk);
        for(integer bitnum=0;bitnum<8;bitnum=bitnum+1) begin
            uart_rxd=value[bitnum];
            repeat(dut.u_uart.BITCLKS) @(negedge clk);
        end
        uart_rxd=1;
        repeat(dut.u_uart.BITCLKS) @(negedge clk);
    endtask
    task automatic read_uart_stalled(input [2:0] offset, input [7:0] expected,
                                     input [7:0] arriving_byte);
        reg [63:0] held;
        begin
            @(negedge clk);
            dmem_araddr=32'h10000000+32'(offset); dmem_arlen=0;
            dmem_arsize=0; dmem_arburst=1; dmem_arid=6;
            dmem_arvalid=1; dmem_rready=0;
            do @(posedge clk); while(!dmem_arready);
            @(negedge clk); dmem_arvalid=0; dmem_araddr=32'h10000007;
            while(!dmem_rvalid) @(negedge clk);
            held=dmem_rdata;
            if(held[offset*8+:8]!==expected)
                $fatal(1,"UART snapshot has wrong register value at %0d",offset);
            // For RBR the sampled byte is consumed now, not at RREADY.
            // A new byte arrives while the response remains outstanding.
            fork
                uart_receive(arriving_byte);
                begin
                    repeat(12*dut.u_uart.BITCLKS) begin
                        @(negedge clk);
                        if(!dmem_rvalid || !dmem_rlast || dmem_rresp!=0 ||
                           dmem_rid!=6 || dmem_rdata!==held)
                            $fatal(1,"UART response changed during RX arrival");
                    end
                end
            join
            if(!dut.u_uart.rx_rdy || dut.u_uart.rx_data!==arriving_byte)
                $fatal(1,"UART arrival during stalled response was lost");
            dmem_rready=1; @(negedge clk); dmem_rready=0;
            repeat(4) @(negedge clk);
            if(!dut.u_uart.rx_rdy || dut.u_uart.rx_data!==arriving_byte)
                $fatal(1,"RREADY popped a byte newer than the captured response");
        end
    endtask
`endif
`endif
    reg [63:0] cmp_expected;
    initial begin
        rst=1; uart_rxd=1; uart_cts=1;
        repeat(4) @(negedge clk); rst=0;
        write_data(32'h80000ff0,1,64'h0123456789abcdef,64'hfedcba9876543210);
        read_data(32'h80000ff0,64'h0123456789abcdef);
        read_data(32'h80000ff8,64'hfedcba9876543210);
        write_data(32'h80001000,1,64'h1111222233334444,64'h5555666677778888);
        read_data(32'h80001000,64'h1111222233334444);
        read_data(32'h80001008,64'h5555666677778888);
`ifdef TEST_LINUX_AXI
        write_w_before_aw();
        read_data(32'h80001020,64'h13579bdf2468ace0);
        cmp_expected=64'h13579bdf2468ace0;
        for(integer size=0;size<4;size=size+1) begin
            for(integer lane=0;lane<8;lane=lane+(1<<size)) begin
                for(integer b=0;b<(1<<size);b=b+1)
                    cmp_expected[(lane+b)*8+:8]=8'h80+8'(lane+b);
                write_data(32'h80001020+32'(lane),0,64'h8786858483828180,0,0,
                           3'(size),8'(((1<<(1<<size))-1)<<lane));
                read_data(32'h80001020+32'(lane),cmp_expected,0,3'(size));
            end
        end
        write_data(32'h80001030,1,64'h123,64'h456);
        malformed_write(1);
        malformed_write(0);
        read_data(32'h80001030,64'h123);
        read_data(32'h80001038,64'h456);
        // Invalid MMIO bursts must not mutate registers or start the bridge.
        write_data(32'h02004000,1,0,0,3);
        read_data(32'h02004000,64'hffffffffffffffff);
        read_rejected_burst(32'h02004000);
        write_data(32'h02000000,1,1,0,3);
        if(irq_software) $fatal(1,"rejected CLINT burst asserted MSIP");
        write_data(32'h11011000,0,64'h0123456789abcdef,0);
        read_data(32'h11011000,64'h0123456789abcdef);
        write_data(32'h11011000,1,0,0,3);
        read_data(32'h11011000,64'h0123456789abcdef);
        read_rejected_burst(32'h11011000);
        // Disjoint read/write channels must still serialize one busy bridge.
        fork
            write_data(32'h11011008,0,64'hfedcba9876543210,0);
            read_data(32'h11011000,64'h0123456789abcdef);
        join
        read_data(32'h11011008,64'hfedcba9876543210);
`endif
`ifndef TEST_AXI4_RAM
        if (irq_software !== 1'b0) $fatal(1,"MSIP not clear after reset");
        write_data(32'h02000000,0,1,0);
        read_data(32'h02000000,1);
        if (irq_software !== 1'b1) $fatal(1,"CLINT write did not assert MSIP");
        write_data(32'h02000000,0,0,0);
        read_data(32'h02000000,0);
        if (irq_software !== 1'b0) $fatal(1,"CLINT write did not clear MSIP");
        write_data(32'h02004000,0,64'hffffffff12345678,0);
        read_data(32'h02004000,64'hffffffff12345678);
        // Svpbmt IO preserves exact narrow AR/AW addresses. Every byte lane
        // and naturally aligned transfer size must still address the same
        // CLINT register; inactive bytes must remain unchanged.
        cmp_expected=64'hffffffff12345678;
        for(integer size=0;size<4;size=size+1) begin
            for(integer lane=0;lane<8;lane=lane+(1<<size)) begin
                for(integer b=0;b<(1<<size);b=b+1)
                    cmp_expected[(lane+b)*8+:8]=8'h80+8'(lane+b);
                write_data(32'h02004000+32'(lane),0,64'h8786858483828180,0,0,
                           3'(size),8'(((1<<(1<<size))-1)<<lane));
                read_data(32'h02004000+32'(lane),cmp_expected,0,3'(size));
                if(irq_timer) $fatal(1,"partial timer write clobbered inactive high bytes");
            end
        end
        // MSIP upper bytes must not change bit0. A byte0 write still asserts,
        // clears and rearms the same hardware interrupt source.
        write_data(32'h02000000,0,1,0,0,0,8'h01);
        write_data(32'h02000001,0,64'h00000000aabbcc00,0,0,0,8'h02);
        read_data(32'h02000001,64'h1,0,0);
        if(!irq_software) $fatal(1,"MSIP byte1 write cleared bit0");
        for(integer lane=0;lane<8;lane=lane+1) begin
            write_data(32'h02000000+32'(lane),0,~64'b0,0,0,0,8'(1<<lane));
            read_data(32'h02000000+32'(lane),1,0,0);
        end
        write_data(32'h02000000,0,~64'b1,0);
        read_data(32'h02000000,0);
        if(irq_software) $fatal(1,"MSIP reserved bits raised interrupt");
        write_data(32'h02000000,0,0,0,0,0,8'h01);
        if(irq_software) $fatal(1,"MSIP narrow clear failed");
        write_data(32'h02000000,0,1,0,0,0,8'h01);
        if(!irq_software) $fatal(1,"MSIP narrow rearm failed");
        write_data(32'h02000000,0,0,0,0,0,8'h01);
        // A stable nonzero upper half distinguishes proper narrow mtime
        // selection from the former zero-valued unmapped-address decode.
        write_data(32'h0200bff8,0,64'h1234567800000000,0);
        read_data(32'h0200bffc,64'h1234567800000000,0,2,64'hffffffff00000000);
        write_data(32'h0200bffe,0,64'h9abc000000000000,0,0,1,8'hc0);
        read_data(32'h0200bffe,64'h9abc567800000000,0,1,64'hffffffff00000000);
        read_timer_stalled();
        // An LSR read must not consume a byte that arrives while stalled.
        // A held RBR response then keeps that byte, while another arrival
        // remains queued for the following architectural read.
`ifndef TEST_LINUX_AXI
        read_uart_stalled(5,8'h60,8'h5a);
        read_uart_stalled(0,8'h5a,8'ha6);
        read_data(32'h10000000,64'ha6,0,0,64'hff);
        repeat(4) @(negedge clk);
        if(dut.u_uart.rx_rdy) $fatal(1,"final UART RBR read did not consume its byte");
`endif
`ifdef TEST_DDR_XBAR
        read_flash_stalled();
`endif
        // Timer assertion/clear still uses the assembled 64-bit compare.
        write_data(32'h02004000,0,0,0);
        if(!irq_timer) $fatal(1,"MTIP did not assert after compare elapsed");
        write_data(32'h02004004,0,64'hffffffff00000000,0,0,2,8'hf0);
        if(irq_timer) $fatal(1,"narrow high-word compare write did not clear MTIP");
        // PLIC reads are side-effectful native 32-bit accesses. Use the
        // UART's real TX-empty interrupt as a held-high level source. Each
        // read_data stalls RREADY, checking the captured claim stays stable.
        write_data(32'h10000001,0,64'h200,0,0,0,8'h02);
        write_data(32'h0c000004,0,64'h100000000,0,0,2,8'hf0);
        write_data(32'h0c002000,0,2,0,0,2,8'h0f);
        write_data(32'h0c002080,0,2,0,0,2,8'h0f);
        if(!irq_ext_m || !irq_ext_s) $fatal(1,"PLIC did not latch UART request");
        // Reading only threshold must leave the adjacent claim untouched.
        read_data(32'h0c200000,0,0,2,64'hffffffff);
        read_data(32'h0c001000,2,0,2);
        write_data(32'h0c200000,0,15,0,0,2,8'h0f);
        if(irq_ext_m || !irq_ext_s) $fatal(1,"PLIC threshold notification mismatch");
        // M can still poll a claim below threshold; S must then see none.
        read_data(32'h0c200004,64'h10000000f,0,2);
        read_data(32'h0c201004,0,0,2);
        read_data(32'h0c001000,0,0,2);
        if(irq_ext_m || irq_ext_s) $fatal(1,"PLIC re-pended before completion");
        // Completion from another enabled context is valid. The held level
        // re-pends once, then clears after deassertion and second completion.
        write_data(32'h0c201004,0,64'h100000000,0,0,2,8'hf0);
        if(irq_ext_m || !irq_ext_s) $fatal(1,"PLIC completion did not re-pend UART");
        read_data(32'h0c201004,64'h100000000,0,2);
        write_data(32'h10000001,0,0,0,0,0,8'h02);
        write_data(32'h0c201004,0,64'h100000000,0,0,2,8'hf0);
        read_data(32'h0c001000,0,0,2);
        if(irq_ext_m || irq_ext_s) $fatal(1,"PLIC completion left stale IRQ");
`endif
        // Holes and addresses beyond the 8 KiB RAM must not alias valid data.
        read_data(32'h80002ff0,0,3);
        read_data(32'h00000ff0,0,3);
        write_data(32'h80002ff0,1,0,0,3);
        write_data(32'h00000ff0,0,0,0,3);
        read_data(32'h80000ff0,64'h0123456789abcdef);
        read_data(32'h80000ff8,64'hfedcba9876543210);
`ifdef TEST_LINUX_AXI
        $display("[AXI-LINUX] ALL PASS");
`elsif TEST_DDR_XBAR
        $display("[AXI-DDR] ALL PASS");
`else
        $display("[AXI-BRAM] ALL PASS");
`endif
        $finish;
    end
    initial begin #500000; $fatal(1,"timeout"); end
endmodule

`ifdef TEST_DDR_XBAR
// Configuration-flash pin primitive only. The real SPI state machine runs;
// MISO stays high so a completed transfer has the deterministic value 0xff.
module STARTUPE3 #(
    parameter PROG_USR="FALSE", parameter SIM_CCLK_FREQ=0.0
) (
    output wire CFGCLK, CFGMCLK, EOS, PREQ,
    output wire [3:0] DI,
    input wire [3:0] DO, DTS,
    input wire FCSBO, FCSBTS, GSR, GTS, KEYCLEARB, PACK,
    input wire USRCCLKO, USRCCLKTS, USRDONEO, USRDONETS
);
    assign CFGCLK=0; assign CFGMCLK=0; assign EOS=1; assign PREQ=0;
    assign DI=4'b0010;
endmodule
`endif
