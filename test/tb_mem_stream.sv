// Directed AXI transport test: independent AW/W stalls, delayed B, burst
// length/WLAST, partial halves, posted-store drain, ordered reads/MMIO,
// Svpbmt NC/IO cache bypass, exact IO footprints, and alias invalidation.
`include "karu_axi_defs.vh"
`timescale 1ns/1ps
module tb_mem_stream;
    reg clk = 0;
    reg rst = 0;
    reg [31:0]  uncache_page = 0;
    reg flush = 0;
    reg [1:0] s_ar_pbmt = 0, s_aw_pbmt = 0;
    reg [`AXI_ID_W-1:0]     s_arid = 0;
    reg [`AXI_ADDR_W-1:0]   s_araddr = 0;
    reg [`AXI_LEN_W-1:0]    s_arlen = 0;
    reg [`AXI_SIZE_W-1:0]   s_arsize = 3;
    reg [`AXI_BURST_W-1:0]  s_arburst = 0;
    reg [`AXI_PROT_W-1:0]   s_arprot = 0;
    reg s_arvalid = 0;
    wire s_arready;
    wire [`AXI_ID_W-1:0]     s_rid;
    wire [`AXI_DATA_W-1:0]   s_rdata;
    wire [`AXI_RESP_W-1:0]   s_rresp;
    wire s_rlast;
    wire s_rvalid;
    reg s_rready = 0;
    reg [`AXI_ID_W-1:0]     s_awid = 0;
    reg [`AXI_ADDR_W-1:0]   s_awaddr = 0;
    reg [`AXI_LEN_W-1:0]    s_awlen = 0;
    reg [`AXI_SIZE_W-1:0]   s_awsize = 3;
    reg [`AXI_BURST_W-1:0]  s_awburst = 0;
    reg [`AXI_PROT_W-1:0]   s_awprot = 0;
    reg s_awvalid = 0;
    wire s_awready;
    reg [`AXI_DATA_W-1:0]   s_wdata = 0;
    reg [`AXI_STRB_W-1:0]   s_wstrb = 0;
    reg s_wlast = 0;
    reg s_wvalid = 0;
    wire s_wready;
    wire [`AXI_ID_W-1:0]     s_bid;
    wire [`AXI_RESP_W-1:0]   s_bresp;
    wire s_bvalid;
    reg s_bready = 0;
    reg v_req = 0;
    wire v_busy;
    reg v_is_store = 0;
    reg v_allow_post = 1;
    wire v_fault;
    wire [63:0] v_fault_va;
    reg [31:0]              v_addr = 0;
    wire [63:0] v_va = {32'b0, v_addr};
    reg [127:0]             v_wdata = 0;
    reg [15:0]              v_wstrb = 0;
    reg [1:0] v_pbmt = 0, v_size = 3;
    reg [15:0] v_rstrb = 16'hffff;
    wire v_done;
    wire [127:0]             v_rdata;
    wire store_pending;
    wire [`AXI_ID_W-1:0]     m_arid;
    wire [`AXI_ADDR_W-1:0]   m_araddr;
    wire [`AXI_LEN_W-1:0]    m_arlen;
    wire [`AXI_SIZE_W-1:0]   m_arsize;
    wire [`AXI_BURST_W-1:0]  m_arburst;
    wire [`AXI_PROT_W-1:0]   m_arprot;
    wire m_arvalid;
    reg m_arready = 0;
    reg [`AXI_ID_W-1:0]     m_rid = 0;
    reg [`AXI_DATA_W-1:0]   m_rdata = 0;
    reg [`AXI_RESP_W-1:0]   m_rresp = 0;
    reg m_rlast = 0;
    reg m_rvalid = 0;
    wire m_rready;
    wire [`AXI_ID_W-1:0]     m_awid;
    wire [`AXI_ADDR_W-1:0]   m_awaddr;
    wire [`AXI_LEN_W-1:0]    m_awlen;
    wire [`AXI_SIZE_W-1:0]   m_awsize;
    wire [`AXI_BURST_W-1:0]  m_awburst;
    wire [`AXI_PROT_W-1:0]   m_awprot;
    wire m_awvalid;
    reg m_awready = 0;
    wire [`AXI_DATA_W-1:0]   m_wdata;
    wire [`AXI_STRB_W-1:0]   m_wstrb;
    wire m_wlast;
    wire m_wvalid;
    reg m_wready = 0;
    reg [`AXI_ID_W-1:0]     m_bid = 0;
    reg [`AXI_RESP_W-1:0]   m_bresp = 0;
    reg m_bvalid = 0;
    wire m_bready;
    always #5 clk=~clk;
    karu_mem dut (.*);
    reg [7:0] ram[0:8191];
    reg wa=0;
    reg [31:0] wp;
    integer wn, bdelay=0, cycle=0, aws=0, bs=0, beats=0, ars=0;
    reg [31:0] aw_log[0:511], ar_log[0:511];
    reg [7:0] ar_len_log[0:511];
    reg [2:0] aw_size_log[0:511], ar_size_log[0:511];
    reg [7:0] w_strb_log[0:511];
    reg [31:0] read_error_addr=32'hffffffff, write_error_addr=32'hffffffff;
    // No address is a safe sentinel: 0xffffffff is a legal byte store.
    reg read_error_enable=0, write_error_enable=0;
    reg strict_io=0;
    integer faults=0;
    reg [63:0] last_fault_va;
    always @(posedge clk) if (!rst && v_fault) begin
        faults<=faults+1; last_fault_va<=v_fault_va;
    end
    reg rr=0;
    reg [31:0] rp;
    integer rn;
    always @* begin
        m_awready = !wa && !m_bvalid && bdelay==0 && cycle%3==0;
        m_wready = wa && cycle%4==1;
        m_arready = !rr && !m_rvalid && cycle%3==1;
    end
    always @(posedge clk) if (!rst) begin
        cycle<=cycle+1;
        if (m_awvalid && m_awready) begin
            if (m_awlen>1 || m_awsize>3 || m_awburst!=1 || (m_awlen!=0 && m_awsize!=3))
                $fatal(1,"bad AW geometry");
            if (strict_io && (m_awlen!=0 || (m_awaddr & ((1<<m_awsize)-1))!=0))
                $fatal(1,"IO AW is not a naturally aligned single transfer");
            if (m_awaddr<32'h80000000 && m_awlen!=0) $fatal(1,"MMIO burst");
            if (({1'b0,m_awaddr[11:0]} & ~((1<<m_awsize)-1)) +
                ((m_awlen+1)<<m_awsize)>4096)
                $fatal(1,"burst crosses 4 KiB");
            aw_log[aws]<=m_awaddr; aw_size_log[aws]<=m_awsize;
            if(write_error_enable && m_awaddr==write_error_addr) m_bresp<=2;
            wa<=1; wp<={m_awaddr[31:3],3'b0}; wn<=m_awlen+1; m_bid<=m_awid; aws<=aws+1;
        end
        if (m_wvalid && m_wready) begin
            if (m_wlast != (wn==1)) $fatal(1,"WLAST disagrees with AWLEN");
            if (m_wstrb==0) $fatal(1,"zero-strobe half issued");
            w_strb_log[beats]<=m_wstrb;
            for(integer i=0;i<8;i=i+1)
                if(m_wstrb[i]) ram[(wp+i)&8191]<=m_wdata[i*8+:8];
            wp<=wp+8; wn<=wn-1; beats<=beats+1;
            if(wn==1) begin wa<=0; bdelay<=9; end
        end
        if(bdelay!=0) begin
            bdelay<=bdelay-1;
            if(bdelay==1) m_bvalid<=1;
        end
        if(m_bvalid && m_bready) begin m_bvalid<=0; bs<=bs+1; end
        if(m_arvalid && m_arready) begin
            if(aws!=bs || wa || bdelay!=0) $fatal(1,"read passed pending store");
            if(m_arsize>3 || (m_arlen!=0 && m_arsize!=3)) $fatal(1,"bad AR geometry");
            if(strict_io && (m_arlen!=0 || (m_araddr & ((1<<m_arsize)-1))!=0))
                $fatal(1,"IO AR is not a naturally aligned single transfer");
            ar_log[ars]<=m_araddr; ar_size_log[ars]<=m_arsize;
            ar_len_log[ars]<=m_arlen; ars<=ars+1;
            m_rresp<=read_error_enable && m_araddr==read_error_addr ? 2 : 0;
            rr<=1; rp<={m_araddr[31:3],3'b0}; rn<=m_arlen+1; m_rid<=m_arid;
        end
        if(rr && !m_rvalid) begin
            for(integer i=0;i<8;i=i+1) m_rdata[i*8+:8]<=ram[(rp+i)&8191];
            m_rlast<=rn==1; m_rvalid<=1;
        end
        if(m_rvalid && m_rready) begin
            m_rvalid<=0; rp<=rp+8; rn<=rn-1;
            if(rn==1) rr<=0;
        end
    end
    task automatic wr(input [31:0] a, input [127:0] d, input [15:0] be);
        @(negedge clk);
        while(v_busy) @(negedge clk);
        v_addr=a; v_wdata=d; v_wstrb=be; v_is_store=1; v_req=1;
        @(negedge clk); v_req=0;
        while(!v_done) @(negedge clk);
        if((a<32'h80000000 || v_pbmt!=0 || a[31:12]==uncache_page[31:12]) && aws!=bs)
            $fatal(1,"uncached store acknowledged before B");
    endtask
    task automatic invalidate;
        @(negedge clk); flush=1;
        @(negedge clk); flush=0;
    endtask
    task automatic scalar_rd(input [31:0] a, input [1:0] pbmt,
                             input [2:0] sz, input [63:0] expected);
        @(negedge clk);
        s_araddr=a; s_ar_pbmt=pbmt; s_arsize=sz; s_arvalid=1; s_rready=1;
        while(!s_arready) @(negedge clk);
        s_arvalid=0; s_ar_pbmt=0; s_arsize=3;
        while(!s_rvalid) @(negedge clk);
        if(s_rresp!=0 || s_rdata!==expected) $fatal(1,"scalar read %h mismatch %h",a,s_rdata);
        @(negedge clk); s_rready=0;
    endtask
    task automatic scalar_wr(input [31:0] a, input [1:0] pbmt,
                             input [2:0] sz, input [63:0] d, input [7:0] be);
        @(negedge clk);
        s_awaddr=a; s_aw_pbmt=pbmt; s_awsize=sz;
        s_wdata=d; s_wstrb=be; s_awvalid=1; s_wvalid=1; s_wlast=1; s_bready=1;
        while(!s_awready || !s_wready) @(negedge clk);
        s_awvalid=0; s_wvalid=0; s_aw_pbmt=0; s_awsize=3;
        while(!s_bvalid) @(negedge clk);
        if(s_bresp!=0) $fatal(1,"scalar write error");
        @(negedge clk); s_bready=0;
    endtask

    // Mutate all live metadata immediately after acceptance. Correct results
    // and bus footprints therefore also check active/waiting-slot capture.
    task automatic io_access(input bit store, input [31:0] a,
                             input [1:0] sz, input [15:0] mask,
                             input [127:0] data, input bit expect_fault,
                             input [1:0] attribute=2);
        integer n, start_ar, start_aw, start_w, start_fault, step, expected_size;
        reg [127:0] expected;
        reg [7:0] expected_strb;
        reg [31:0] error_addr;
        begin
            @(negedge clk); while(v_busy) @(negedge clk);
            start_ar=ars; start_aw=aws; start_w=beats; start_fault=faults;
            expected=0;
            for(integer j=0;j<16;j=j+1) begin
                if(store) expected[j*8+:8]=mask[j] ? data[j*8+:8] : ram[(a+j)&8191];
                else if(mask[j]) expected[j*8+:8]=ram[(a+j)&8191];
            end
            v_addr=a; v_is_store=store; v_size=sz; v_pbmt=attribute;
            v_rstrb=mask; v_wstrb=mask; v_wdata=data; v_req=1;
            @(negedge clk); v_req=0; v_pbmt=0; v_size=3; v_rstrb=0; v_wstrb=0; v_wdata=0;
            while(!v_done) @(negedge clk);
            if(v_fault!==expect_fault) $fatal(1,"IO fault flag mismatch");
            if(!store && !expect_fault && v_rdata!==expected)
                $fatal(1,"IO data mismatch mask=%h got=%h expected=%h",mask,v_rdata,expected);
            if(store && !expect_fault)
                for(integer j=0;j<16;j=j+1)
                    if(ram[(a+j)&8191]!==expected[j*8+:8]) $fatal(1,"IO store clobbered byte %0d",j);
            if(aws!=bs) $fatal(1,"IO acknowledged before B");
            n=0;
            for(integer j=0;j<16;) begin
                if(!mask[j]) j=j+1;
                else begin
                    step=1<<sz; expected_size=sz;
                    if((j & (step-1))!=0 || ((mask>>j) & ((1<<step)-1))!=((1<<step)-1)) begin
                        step=1; expected_size=0;
                    end
                    if(store) begin
                        expected_strb=((1<<step)-1)<<(j&7);
                        if(aw_log[start_aw+n]!==a+j || aw_size_log[start_aw+n]!==expected_size[2:0]
                           || w_strb_log[start_w+n]!==expected_strb)
                            $fatal(1,"IO write footprint mismatch index=%0d address=%h size=%0d mask=%h",j,aw_log[start_aw+n],aw_size_log[start_aw+n],w_strb_log[start_w+n]);
                    end else if(ar_log[start_ar+n]!==a+j || ar_size_log[start_ar+n]!==expected_size[2:0])
                        $fatal(1,"IO read footprint mismatch index=%0d address=%h size=%0d",j,ar_log[start_ar+n],ar_size_log[start_ar+n]);
                    n=n+1;
                    error_addr=store ? write_error_addr : read_error_addr;
                    if(expect_fault && a+j==error_addr) begin
                        if(v_fault_va!=={32'b0,error_addr}) $fatal(1,"IO fault lost exact byte address");
                        j=16;
                    end else j=j+step;
                end
            end
            if(store ? (aws-start_aw!=n) : (ars-start_ar!=n)) $fatal(1,"extra/missing IO accesses");
            @(negedge clk);
            if(faults!=start_fault+int'(expect_fault)) $fatal(1,"IO fault count mismatch");
            v_rstrb=16'hffff;
        end
    endtask
    integer ar_before, aw_before;
    reg [15:0] sweep_mask;
    reg [63:0] scalar_expected;
    task automatic rd(input [31:0] a, input [127:0] expected);
        @(negedge clk);
        while(v_busy) @(negedge clk);
        v_addr=a; v_is_store=0; v_req=1;
        @(negedge clk); v_req=0;
        while(!v_done) @(negedge clk);
        if(v_rdata!==expected) $fatal(1,"read mismatch %h got %h expected %h",a,v_rdata,expected);
    endtask
    task automatic dram_check(input [31:0] a);
        integer first_ar, first_aw;
        begin
            // The backing model aliases upper addresses; set a new value on
            // every call so cache tag aliasing cannot accidentally pass.
            for(integer i=0;i<16;i=i+1) ram[(a+i)&8191]=a[31:24];
            first_ar=ars;
            scalar_rd(a,0,3,{8{a[31:24]}});
            if(ars-first_ar!=1 || ar_len_log[first_ar]!=7 ||
               ar_log[first_ar]!={a[31:6],6'b0})
                $fatal(1,"DRAM failed to refill at %h",a);
            scalar_rd(a,0,3,{8{a[31:24]}});
            rd(a,{16{a[31:24]}});
            if(ars-first_ar!=1) $fatal(1,"DRAM failed to hit at %h",a);

            // Active and waiting vector stores must post, use two-beat
            // bursts, and update a resident line before the ordered read.
            first_aw=aws;
            wr(a,128'h1234,16'hffff);
            if(!store_pending) $fatal(1,"active DRAM store did not post at %h",a);
            wr(a,128'h5678,16'hffff);
            if(!store_pending) $fatal(1,"queued DRAM store did not post at %h",a);
            rd(a,128'h5678);
            if(aws-first_aw!=2 || ars-first_ar!=1)
                $fatal(1,"DRAM store burst/hit mismatch at %h",a);
            wr(a,128'hab,16'h0001);
            rd(a,128'h56ab);
            if(ars-first_ar!=1) $fatal(1,"partial DRAM store lost hit");

            for(integer pbmt=1;pbmt<3;pbmt=pbmt+1) begin
                first_ar=ars;
                ram[a&8191]=8'hcd;
                v_pbmt=2'(pbmt); rd(a,128'h56cd); v_pbmt=0;
                if(ars-first_ar!=2 || ar_len_log[first_ar]!=0 || ar_len_log[first_ar+1]!=0)
                    $fatal(1,"high DRAM PBMT bypass failed");
                rd(a,128'h56ab);
                if(ars-first_ar!=2) $fatal(1,"PBMT bypass evicted resident line");
            end
        end
    endtask

    task automatic cached_backing_check(input [31:0] a);
        reg [127:0] expected;
        integer first_ar;
        begin
            for(integer j=0;j<16;j=j+1) expected[j*8+:8]=ram[(a+j)&8191];
            rd(a,expected);
            first_ar=ars;
            rd(a,expected);
            if(ars!=first_ar) $fatal(1,"alias recovery did not retain cache hit");
        end
    endtask

    task automatic store_alias_check(input [31:0] a);
        reg [15:0] mask;
        integer first_ar;
        begin
            // Earlier bypass-read tests deliberately model external DMA and
            // leave stale data. Establish a clean baseline once, not between
            // the alias stores and their cacheable readbacks below.
            invalidate();
            cached_backing_check(a);
            for(integer attr=1;attr<3;attr=attr+1) begin
                // Scalar stores cover every native width and upper byte lanes.
                for(integer sz=0;sz<4;sz=sz+1) begin
                    scalar_wr(a+32'(8-(1<<sz)),2'(attr),3'(sz),
                              64'h123456789abcdef0 ^ (64'(sz) << 56) ^ (64'(attr) << 60),
                              8'(255 << (8-(1<<sz))));
                    cached_backing_check(a);
                end
                // Vector NC uses S_WR; IO uses the byte/element sequencer.
                // Both halves, sparse bytes, a full granule and an empty IO
                // operation must preserve the cacheable alias without FENCE.
                for(integer k=0;k<4;k=k+1) begin
                    case(k)
                        0: mask=16'h000f;
                        1: mask=16'hff00;
                        2: mask=16'h8421;
                        3: mask=16'hffff;
                    endcase
                    if(attr==1) begin
                        v_pbmt=1;
                        wr(a,128'hfedcba9876543210_0123456789abcdef ^ (128'(k)<<120),mask);
                        v_pbmt=0;
                    end else io_access(1,a,2,mask,
                        128'h1122334455667788_99aabbccddeeff00 ^ (128'(k)<<120),0);
                    cached_backing_check(a);
                end
            end
            first_ar=ars;
            io_access(1,a,3,0,0,0);
            cached_backing_check(a);
            if(ars!=first_ar) $fatal(1,"empty IO store evicted resident line");

            // Explicit uncached-page selection is another same-PA alias.
            uncache_page=a;
            wr(a,128'h9876543210abcdef_fedcba0123456789,16'hf00f);
            uncache_page=0;
            cached_backing_check(a);

            // The same aliases must work from the waiting request slot.
            wr(a,128'h1357,16'hffff);
            while(bdelay==0) @(negedge clk);
            v_pbmt=1; wr(a,128'h2468,16'h00ff); v_pbmt=0;
            cached_backing_check(a);
            wr(a,128'h369c,16'hffff);
            while(bdelay==0) @(negedge clk);
            io_access(1,a,2,16'h0f00,128'habcdef0123456789_0,0);
            cached_backing_check(a);

            // Even an error after earlier IO elements have reached memory
            // must not leave the old resident line available for a later hit.
            write_error_addr=a+8; write_error_enable=1;
            io_access(1,a,2,16'hffff,128'habcdef,1);
            write_error_enable=0; m_bresp=0;
            cached_backing_check(a);
        end
    endtask
    integer collision_negative = 0;
    initial begin
        for(integer i=0;i<8192;i=i+1) ram[i]=0;
        uncache_page=32'h80008000;
        rst=1; repeat(4) @(negedge clk); rst=0;
        if ($value$plusargs("collision_negative=%d", collision_negative)) begin
            @(negedge clk);
            v_req=1; v_addr=32'h80000000;
            if (collision_negative == 1) s_arvalid=1;
            else if (collision_negative == 2) begin s_awvalid=1; s_wvalid=1; end
            else $fatal(1,"unknown collision negative control");
            repeat(2) @(negedge clk);
            $fatal(1,"scalar/vector collision escaped checker");
        end
        wr(32'h80000ff0,128'hffeeddccbbaa9988_7766554433221100,16'hffff);
        wr(32'h80001000,128'h0123456789abcdef_fedcba9876543210,16'hff00);
        wr(32'h80001010,128'h1111111111111111_2222222222222222,16'h00ff);
        // A read queued behind a posted store must see the committed data.
        rd(32'h80000ff0,128'hffeeddccbbaa9988_7766554433221100);
        rd(32'h80001000,128'h0123456789abcdef_0000000000000000);
        rd(32'h80001010,128'h0000000000000000_2222222222222222);
        // Cached store-hit update, partial bytes, then the hit read.
        wr(32'h80000ff0,128'h1111111111111111_2222222222222222,16'h8001);
        rd(32'h80000ff0,128'h11eeddccbbaa9988_7766554433221122);
        wr(32'h10001020,128'haaaaaaaaaaaaaaaa_bbbbbbbbbbbbbbbb,16'hffff);
        rd(32'h10001020,128'haaaaaaaaaaaaaaaa_bbbbbbbbbbbbbbbb);
        // A posted error must be reported with the original virtual address,
        // even though the request was acknowledged before B.
        m_bresp=2;
        wr(32'h80001030,128'hcccccccccccccccc_dddddddddddddddd,16'hffff);
        @(negedge clk); while(store_pending) @(negedge clk);
        if(faults!=1 || last_fault_va!=64'h80001030) $fatal(1,"lost posted error");
        if(aws!=bs || aws!=7 || beats!=10) $fatal(1,"unexpected transactions aws=%0d bs=%0d beats=%0d",aws,bs,beats);
        m_bresp=0;

        // A resident cache line must be ignored through NC and IO aliases.
        // Externally changing backing RAM models DMA, not a coherent CPU store.
        rd(32'h80000100,128'b0);
        for(integer i=0;i<16;i=i+1) ram['h100+i]=8'h80+8'(i);
        ar_before=ars;
        v_pbmt=1; rd(32'h80000100,128'h8f8e8d8c8b8a8988_8786858483828180);
        if(ars-ar_before!=2) $fatal(1,"NC used a cache hit or line fill");
        v_pbmt=0; rd(32'h80000100,128'b0);
        invalidate();
        rd(32'h80000100,128'h8f8e8d8c8b8a8988_8786858483828180);
        // An NC write leaves no dirty cache state. Flush must make the old
        // cacheable alias observe it, even when flush used an NC address.
        v_pbmt=1; wr(32'h80000100,128'hf0e0d0c0b0a09080_7060504030201000,16'hffff);
        v_pbmt=0; invalidate(); rd(32'h80000100,128'hf0e0d0c0b0a09080_7060504030201000);

        // Scalar narrow bypass keeps the original AXI lane and transfer size.
        strict_io=1; ar_before=ars;
        scalar_rd(32'h80000103,2,0,64'h7060504030201000);
        if(ar_log[ar_before]!=32'h80000103 || ar_size_log[ar_before]!=0)
            $fatal(1,"scalar IO read widened or realigned");
        aw_before=aws;
        scalar_wr(32'h80000104,2,2,64'h0123456700000000,8'hf0);
        if(aw_log[aw_before]!=32'h80000104 || aw_size_log[aw_before]!=2)
            $fatal(1,"scalar IO write widened or realigned");
        scalar_rd(32'h80000104,1,2,64'h0123456730201000);
        for(integer sz=0;sz<4;sz=sz+1) begin
            for(integer j=0;j<8;j=j+(1<<sz)) begin
                for(integer b=0;b<8;b=b+1) scalar_expected[b*8+:8]=ram['h160+b];
                ar_before=ars;
                scalar_rd(32'h80000160+32'(j),2,3'(sz),scalar_expected);
                if(ar_log[ar_before]!=32'h80000160+32'(j) || ar_size_log[ar_before]!=3'(sz))
                    $fatal(1,"scalar IO load geometry size=%0d lane=%0d",sz,j);
                aw_before=aws;
                scalar_wr(32'h80000160+32'(j),2,3'(sz),64'h0123456789abcdef,
                          8'(((1<<(1<<sz))-1)<<j));
                if(aw_log[aw_before]!=32'h80000160+32'(j) || aw_size_log[aw_before]!=3'(sz))
                    $fatal(1,"scalar IO store geometry size=%0d lane=%0d",sz,j);
            end
        end

        // Every EEW and element lane, sparse masks, empty masks, and partial
        // groups (byte fallback) exercise precise IO read/write footprints.
        for(integer sz=0;sz<4;sz=sz+1) begin
            for(integer j=0;j<16;j=j+(1<<sz)) begin
                sweep_mask=16'(((1<<(1<<sz))-1)<<j);
                io_access(0,32'h80000100,2'(sz),sweep_mask,0,0);
                io_access(1,32'h80000120,2'(sz),sweep_mask,128'hfedcba9876543210_0123456789abcdef,0);
            end
            io_access(0,32'h80000100,2'(sz),16'hffff,0,0);
            io_access(1,32'h80000120,2'(sz),16'hffff,128'hffeeddccbbaa9988_7766554433221100,0);
            io_access(0,32'h80000100,2'(sz),16'h8421,0,0);
            io_access(1,32'h80000120,2'(sz),16'h8421,128'h1122334455667788_99aabbccddeeff00,0);
            io_access(0,32'h80000100,2'(sz),0,0,0);
            io_access(1,32'h80000120,2'(sz),0,0,0);
        end
        // Physical device windows must have the same exact footprint in
        // Bare mode (PBMT=0), including inactive vector element lanes.
        for(integer sz=0;sz<4;sz=sz+1) begin
            io_access(0,32'h0c201000,2'(sz),16'hf00f,0,0,0);
            io_access(1,32'h02004000,2'(sz),16'h8421,
                      128'h1122334455667788_99aabbccddeeff00,0,0);
        end
        // IO metadata must survive queuing behind a posted PMA store.
        strict_io=0; v_pbmt=0;
        wr(32'h80000140,128'h11,16'hffff);
        while(bdelay==0) @(negedge clk);
        io_access(0,32'h80000100,1,16'h0c03,0,0);
        wr(32'h80000140,128'h22,16'hffff);
        while(bdelay==0) @(negedge clk);
        io_access(1,32'h80000120,2,16'h0f00,128'h55,0);
        wr(32'h80000140,128'h33,16'hffff);
        while(bdelay==0) @(negedge clk);
        io_access(0,32'h0c201000,2,16'h00f0,0,0,0);
        strict_io=1;

        // An IO error terminates the remaining stream and reports the exact
        // failing element byte rather than the 16-byte granule's beginning.
        read_error_addr=32'h80000108; read_error_enable=1;
        io_access(0,32'h80000100,2,16'hffff,0,1);
        read_error_enable=0;
        write_error_addr=32'h80000128; write_error_enable=1;
        io_access(1,32'h80000120,2,16'hffff,128'h1234,1);
        write_error_enable=0; m_bresp=0;
        strict_io=0;

        // A flush during refill must not revalidate data fetched before it.
        invalidate();
        @(negedge clk); v_addr=32'h80000180; v_is_store=0; v_pbmt=0; v_req=1;
        @(negedge clk); v_req=0;
        while(!m_arvalid) @(negedge clk);
        invalidate();
        while(!v_done) @(negedge clk);
        for(integer i=0;i<16;i=i+1) ram['h180+i]=8'ha5;
        ar_before=ars;
        rd(32'h80000180,128'ha5a5a5a5a5a5a5a5_a5a5a5a5a5a5a5a5);
        if(ars-ar_before!=1) $fatal(1,"flush revived an in-flight refill");
        invalidate();
        for(integer bank=8;bank<16;bank=bank+1)
            dram_check((32'(bank)<<28)+32'h600);
        dram_check(32'h80000000);
        dram_check(32'h8ffffff0);
        dram_check(32'h90000000);
        dram_check(32'ha0100000);
        dram_check(32'hfffffff0);

        // The explicit uncached page still bypasses inside upper DRAM.
        uncache_page=32'hf0000000;
        ar_before=ars;
        rd(32'hf0000000,128'h56cd);
        rd(32'hf0000000,128'h56cd);
        if(ars-ar_before!=4) $fatal(1,"upper DRAM uncached page allocated");
        wr(32'hf0000000,128'h1122,16'hffff);
        // Non-RAM immediately below DRAM also stays nonallocating.
        ar_before=ars;
        scalar_rd(32'h7ffffff0,0,3,64'h56cd);
        scalar_rd(32'h7ffffff0,0,3,64'h56cd);
        if(ars-ar_before!=2 || ar_len_log[ar_before]!=0 || ar_len_log[ar_before+1]!=0)
            $fatal(1,"non-RAM boundary became cached");
        uncache_page=0;
        store_alias_check(32'h80000230);
        store_alias_check(32'hfffffff0);
        $display("[MEM-STREAM] ALL PASS: %0d AR, %0d AW, %0d W, %0d B; PBMT, masks, faults, aliases",ars,aws,beats,bs);
        $finish;
    end
    initial begin #500000; $fatal(1,"timeout"); end
endmodule
