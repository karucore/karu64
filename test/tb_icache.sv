// Instruction-cache transport and Svpbmt regression. The backing memory has
// independently stalled AR and R channels; the IFU response is backpressured.
// All PBMT tests change the live request after acceptance to check capture.
`include "karu_axi_defs.vh"
`timescale 1ns/1ps
module tb_icache;
    reg clk=0, rst=1, flush=0;
    always #5 clk=~clk;
    wire owns;
    reg [`AXI_ID_W-1:0] s_arid=0;
    reg [31:0] s_araddr=0;
    reg [7:0] s_arlen=0;
    reg [2:0] s_arsize=3;
    reg [1:0] s_arburst=1, s_ar_pbmt=0;
    reg [2:0] s_arprot=0;
    reg s_arvalid=0, s_rready=0;
    wire s_arready, s_rlast, s_rvalid;
    wire [`AXI_ID_W-1:0] s_rid;
    wire [63:0] s_rdata;
    wire [1:0] s_rresp;
    wire [`AXI_ID_W-1:0] m_arid;
    wire [31:0] m_araddr;
    wire [7:0] m_arlen;
    wire [2:0] m_arsize;
    wire [1:0] m_arburst;
    wire [2:0] m_arprot;
    wire m_arvalid, m_rready;
    wire m_arready;
    reg [`AXI_ID_W-1:0] m_rid=0;
    reg [63:0] m_rdata=0;
    reg [1:0] m_rresp=0;
    reg m_rlast=0, m_rvalid=0;
    karu_icache #(.KB(1)) dut (.*);

    reg [63:0] ram[0:1023];
    reg hold_ar=0, read_active=0;
    reg [31:0] read_addr;
    integer remaining, read_beat, gap=0, cycle=0;
    integer error_beat=-1, ars=0, beats=0, checks=0;
    reg [31:0] ar_log[0:255];
    reg [7:0] len_log[0:255];
    reg ar_stalled=0;
    reg [48:0] ar_saved;
    wire [48:0] ar_payload={m_arid,m_araddr,m_arlen,m_arsize,m_arburst};
    assign m_arready=!hold_ar && !read_active && !m_rvalid && cycle%5==2;
    always @(posedge clk) begin
        if(!rst) begin
            cycle<=cycle+1;
            if(ar_stalled && (!m_arvalid || ar_payload!==ar_saved))
                $fatal(1,"master AR changed under backpressure");
            ar_stalled<=m_arvalid && !m_arready;
            ar_saved<=ar_payload;
            if(m_arvalid && m_arready) begin
                if(m_arsize!=3 || m_arburst!=1 || (m_arlen!=0 && m_arlen!=7))
                    $fatal(1,"unexpected instruction-fetch geometry");
                ar_log[ars]<=m_araddr; len_log[ars]<=m_arlen; ars<=ars+1;
                read_addr<=m_araddr; remaining<=m_arlen+1; read_beat<=0;
                m_rid<=m_arid; read_active<=1; gap<=3;
            end
            if(read_active && !m_rvalid) begin
                if(gap!=0) gap<=gap-1;
                else begin
                    m_rdata<=ram[read_addr[12:3]];
                    m_rresp<=read_beat==error_beat ? 2 : 0;
                    m_rlast<=remaining==1; m_rvalid<=1;
                end
            end
            if(m_rvalid && m_rready) begin
                if(!owns) $fatal(1,"cache released arbiter during response");
                beats<=beats+1;
                m_rvalid<=0; read_addr<=read_addr+8;
                remaining<=remaining-1; read_beat<=read_beat+1; gap<=read_beat%3;
                if(remaining==1) read_active<=0;
            end
        end
    end

    reg [`AXI_ID_W-1:0] expected_id;
    task automatic start_read(input [31:0] addr, input [1:0] pbmt,
                              input bit flush_with_accept);
        @(negedge clk); while(!s_arready) @(negedge clk);
        expected_id=`AXI_ID_W'(checks+3);
        s_araddr=addr; s_arid=expected_id; s_ar_pbmt=pbmt;
        s_arvalid=1; flush=flush_with_accept;
        @(negedge clk);
        s_arvalid=0; s_araddr=32'hdeadbee8; s_arid=~expected_id;
        s_ar_pbmt=pbmt==0 ? 2 : 0; flush=0;
    endtask
    task automatic finish_read(input [63:0] expected, input [1:0] resp);
        while(!s_rvalid) @(negedge clk);
        repeat(5) begin
            if(s_rdata!==expected || s_rresp!==resp || s_rid!==expected_id || !s_rlast || !s_rvalid)
                $fatal(1,"response mismatch/stall instability: data=%h wanted=%h resp=%h",s_rdata,expected,s_rresp);
            if(s_arready) $fatal(1,"accepted another request before completing response");
            checks=checks+1;
            @(negedge clk);
        end
        s_rready=1;
        @(negedge clk); s_rready=0;
    endtask
    task automatic read_check(input [31:0] addr, input [1:0] pbmt,
                              input [63:0] expected, input [1:0] resp,
                              input integer expected_ars);
        integer first;
        begin
            first=ars;
            start_read(addr,pbmt,0);
            finish_read(expected,resp);
            if(ars-first!=expected_ars) $fatal(1,"unexpected cache hit/miss addr=%h PBMT=%0d",addr,pbmt);
            if(expected_ars!=0) begin
                if(pbmt!=0 || addr<32'h80000000) begin
                    if(ar_log[first]!==addr || len_log[first]!=0) $fatal(1,"uncached fetch refilled/wrong address");
                end else if(ar_log[first]!=={addr[31:6],6'b0} || len_log[first]!=7)
                    $fatal(1,"PMA refill geometry mismatch");
            end
            checks=checks+1;
        end
    endtask
    task automatic invalidate;
        @(negedge clk); flush=1;
        @(negedge clk); flush=0;
    endtask

    integer first;
    initial begin
        for(integer i=0;i<1024;i=i+1) ram[i]=64'h1234567800000000+64'(i);
        repeat(4) @(negedge clk); rst=0;
        read_check(32'h80000118,0,ram['h23],0,1);
        for(integer i=0;i<8;i=i+1)
            read_check(32'h80000100+32'(i*8),0,ram['h20+i],0,0);

        // A changed backing word distinguishes cache hits from NC/IO reads.
        ram['h23]=64'h1122334455667788;
        read_check(32'h80000118,1,ram['h23],0,1);
        read_check(32'h80000118,0,64'h1234567800000023,0,0);
        ram['h23]=64'h8877665544332211;
        read_check(32'h80000118,2,ram['h23],0,1);
        read_check(32'h80000118,0,64'h1234567800000023,0,0);

        // Uncached misses must not allocate. Metadata changes while AR is
        // independently blocked may not change an accepted request's path.
        for(integer pbmt=1;pbmt<3;pbmt=pbmt+1) begin
            invalidate(); hold_ar=1; first=ars;
            start_read(32'h80000238,2'(pbmt),0);
            repeat(7) @(negedge clk);
            if(!m_arvalid || m_araddr!=32'h80000238 || m_arlen!=0)
                $fatal(1,"latched PBMT/address lost during AR stall");
            hold_ar=0; finish_read(ram['h47],0);
            if(ars-first!=1) $fatal(1,"duplicate uncached fetch");
            ram['h47]=ram['h47]+1;
            read_check(32'h80000238,0,ram['h47],0,1);
        end
        read_check(32'h10000118,0,ram['h23],0,1);
        ram['h23]=64'habcdef0123456789;
        read_check(32'h10000118,0,ram['h23],0,1);

        // A flush simultaneous with hit acceptance forces a fresh refill.
        read_check(32'h80000300,0,ram['h60],0,1);
        ram['h60]=64'ha5a5a5a55a5a5a5a; first=ars;
        start_read(32'h80000300,0,1); finish_read(ram['h60],0);
        if(ars-first!=1) $fatal(1,"flush failed to dominate accepted hit");
        read_check(32'h80000300,0,ram['h60],0,0);

        // A flush cannot change a response already offered under R stall,
        // but it must remove the line for the following request.
        start_read(32'h80000300,0,0);
        while(!s_rvalid) @(negedge clk);
        invalidate(); finish_read(ram['h60],0);
        ram['h60]=64'h7654321001234567;
        read_check(32'h80000300,0,ram['h60],0,1);

        // Flush in both refill phases (AR blocked and mid-R) poisons fill.
        for(integer phase=0;phase<2;phase=phase+1) begin
            invalidate(); hold_ar=phase==0;
            start_read(32'h80000408,0,0);
            if(phase==0) begin while(!m_arvalid) @(negedge clk); end
            else begin while(read_beat<3) @(negedge clk); end
            invalidate(); hold_ar=0; finish_read(ram['h81],0);
            ram['h81]=ram['h81]+1;
            read_check(32'h80000408,0,ram['h81],0,1);
        end

        // Errors anywhere in a refill (including after the requested word,
        // and on RLAST) poison the whole line and reach the original request.
        for(integer failbeat=0;failbeat<8;failbeat=failbeat+1) begin
            invalidate(); error_beat=failbeat;
            read_check(32'h80000500,0,ram['ha0],2,1);
            error_beat=-1;
            read_check(32'h80000500,0,ram['ha0],0,1);
            read_check(32'h80000500,0,ram['ha0],0,0);
        end
        for(integer pbmt=1;pbmt<3;pbmt=pbmt+1) begin
            error_beat=0;
            read_check(32'h80000500,2'(pbmt),ram['ha0],2,1);
            error_beat=-1;
            read_check(32'h80000500,2'(pbmt),ram['ha0],0,1);
        end

        // Every 256 MiB bank of the board's 2 GiB DRAM must allocate and hit.
        // All addresses share an index: changing backing data also detects
        // omitted high tag bits. NC/IO must bypass even a resident high line.
        invalidate();
        for(integer bank=8;bank<16;bank=bank+1) begin
            ram['h23]=64'(bank);
            read_check((32'(bank)<<28)+32'h118,0,64'(bank),0,1);
            ram['h23]=64'(bank)+64'h100;
            read_check((32'(bank)<<28)+32'h118,0,64'(bank),0,0);
            for(integer pbmt=1;pbmt<3;pbmt=pbmt+1)
                read_check((32'(bank)<<28)+32'h118,2'(pbmt),ram['h23],0,1);
            read_check((32'(bank)<<28)+32'h118,0,64'(bank),0,0);
        end
        // Lower edge, old upper edge, first newly cached line, reported
        // 513 MiB text placement, and the final word of physical DRAM.
        read_check(32'h80000000,0,ram[0],0,1);
        read_check(32'h80000000,0,ram[0],0,0);
        read_check(32'h8ffffff8,0,ram['h3ff],0,1);
        read_check(32'h8ffffff8,0,ram['h3ff],0,0);
        read_check(32'h90000000,0,ram[0],0,1);
        read_check(32'h90000000,0,ram[0],0,0);
        read_check(32'ha0100000,0,ram[0],0,1);
        read_check(32'ha0100000,0,ram[0],0,0);
        read_check(32'hfffffff8,0,ram['h3ff],0,1);
        read_check(32'hfffffff8,0,ram['h3ff],0,0);
        // Adjacent non-RAM and boot ROM remain single-beat, nonallocating.
        repeat(2) read_check(32'h7ffffff8,0,ram['h3ff],0,1);
        repeat(2) read_check(32'h00001000,0,ram['h200],0,1);
        $display("[ICACHE] ALL PASS: %0d checks, %0d AR, %0d R beats",checks,ars,beats);
        $finish;
    end
    initial begin #200000; $fatal(1,"instruction-cache timeout"); end
endmodule
