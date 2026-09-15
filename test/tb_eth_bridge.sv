// Ethernet bridge unit test. A deliberately delayed, registered-ACK
// Wishbone responder counts each read as a side effect. Compile this bench
// without generated LiteEth IP; both MII and KARU_ETH_SGMII port variants
// use the same stub and exercise the real bridge and passive assertions.
`timescale 1ns/1ps
module tb_eth_bridge;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg rd_req=0, wr_req=0;
    reg [31:0] rd_addr=0, wr_addr=0;
    reg [2:0] rd_size=3;
    reg [7:0] wr_strb=0;
    reg [63:0] wr_data=0;
    wire rd_done, wr_done, busy, eth_irq;
    wire [63:0] rd_data;
`ifdef KARU_ETH_SGMII
    wire eth_clk125=clk;
    wire [7:0] gmii_tx_data;
    wire gmii_tx_en, gmii_tx_er;
    wire [7:0] gmii_rx_data=0;
    wire gmii_rx_dv=0, gmii_rx_er=0;
`endif
    karu_eth dut (.*);
    karu_eth_assert checker_u (
        .clk(clk), .rst(rst), .st(dut.st), .rd_req(rd_req), .rd_done(rd_done),
        .wr_req(wr_req), .wr_done(wr_done), .busy(busy),
        .wb_cyc(dut.wb_cyc), .wb_stb(dut.wb_stb), .wb_we(dut.wb_we), .wb_ack(dut.wb_ack),
        .wb_sel(dut.wb_sel), .sel_lo(dut.sel_lo), .sel_hi(dut.sel_hi)
    );
    integer checks=0, read_dones=0, write_dones=0;
    always @(posedge clk) if(!rst) begin
        if(rd_done) read_dones<=read_dones+1;
        if(wr_done) write_dones<=write_dones+1;
    end
    function automatic [31:0] word_data(input [29:0] word_addr);
        word_data=32'h5aa50000 ^ {2'b0,word_addr};
    endfunction
    task automatic read_check(input [31:0] addr, input [2:0] size);
        integer first, first_done, count;
        reg [29:0] low_word, high_word;
        reg [63:0] expected;
        reg [3:0] mask;
        begin
            @(negedge clk); while(busy) @(negedge clk);
            first=dut.u_core.read_count; first_done=read_dones;
            low_word={addr[31:3],1'b0}; high_word={addr[31:3],1'b1};
            count=size==3 ? 2 : 1;
            mask=size==0 ? (4'b0001<<addr[1:0]) :
                 size==1 ? (4'b0011<<addr[1:0]) : 4'b1111;
            expected=size==3 ? {word_data(high_word),word_data(low_word)} :
                     addr[2] ? {word_data(high_word),32'b0} : {32'b0,word_data(low_word)};
            rd_addr=addr; rd_size=size; rd_req=1;
            @(negedge clk); rd_req=0; rd_addr=32'h1100ffe0; rd_size=size==3 ? 0 : 3;
            while(!rd_done) @(negedge clk);
            if(busy || rd_data!==expected) $fatal(1,"bad read completion addr=%h got=%h expected=%h",addr,rd_data,expected);
            if(dut.u_core.read_count-first!=count) $fatal(1,"IO read touched adjacent word or repeated side effect");
            if(dut.u_core.read_addr_log[first] !== (size!=3 && addr[2] ? high_word : low_word)
               || dut.u_core.read_sel_log[first]!==mask)
                $fatal(1,"wrong first Wishbone read footprint addr=%h size=%0d",addr,size);
            if(size==3 && (dut.u_core.read_addr_log[first+1]!==high_word || dut.u_core.read_sel_log[first+1]!==4'hf))
                $fatal(1,"wrong second Wishbone read footprint");
            repeat(2) @(negedge clk);
            if(read_dones-first_done!=1 || rd_done) $fatal(1,"missing/repeated read done pulse");
            checks=checks+1;
        end
    endtask
    task automatic write_check(input [31:0] addr, input [7:0] mask);
        integer first, first_done, count;
        begin
            @(negedge clk); while(busy) @(negedge clk);
            first=dut.u_core.write_count; first_done=write_dones;
            count=(mask[3:0]!=0 ? 1 : 0)+(mask[7:4]!=0 ? 1 : 0);
            wr_addr=addr; wr_strb=mask; wr_data=64'hfedcba9876543210; wr_req=1;
            @(negedge clk); wr_req=0; wr_addr=32'h1100fff8; wr_strb=0; wr_data=0;
            while(!wr_done) @(negedge clk);
            if(busy || dut.u_core.write_count-first!=count) $fatal(1,"write beat count changed");
            if(mask[3:0]!=0 && (dut.u_core.write_addr_log[first]!=={addr[31:3],1'b0}
               || dut.u_core.write_sel_log[first]!==mask[3:0]
               || dut.u_core.write_data_log[first]!==32'h76543210)) $fatal(1,"wrong low write");
            if(mask[7:4]!=0 && (dut.u_core.write_addr_log[first+count-1]!=={addr[31:3],1'b1}
               || dut.u_core.write_sel_log[first+count-1]!==mask[7:4]
               || dut.u_core.write_data_log[first+count-1]!==32'hfedcba98)) $fatal(1,"wrong high write");
            repeat(2) @(negedge clk);
            if(write_dones-first_done!=1 || wr_done) $fatal(1,"missing/repeated write done pulse");
            checks=checks+1;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=0;
        for(integer size=0;size<4;size=size+1)
            for(integer lane=0;lane<16;lane=lane+(1<<size))
                read_check(32'h11000020+32'(lane),3'(size));
        // Legacy eight-byte requests may carry the original load's byte
        // offset; they still read the containing aligned pair of words.
        read_check(32'h11000024,3);
        read_check(32'h11010007,3);
        for(integer lane=0;lane<8;lane=lane+1)
            write_check(32'h11010000,8'(1<<lane));
        write_check(32'h11010000,8'hff);
        write_check(32'h11010000,8'h81);
        write_check(32'h11010000,8'h0f);
        write_check(32'h11010000,8'hf0);
        if(checker_u.fails!=0) $fatal(1,"Ethernet assertion failures");
        $display("[ETH-BRIDGE] ALL PASS: %0d cases, %0d read effects, %0d writes",checks,dut.u_core.read_count,dut.u_core.write_count);
        $finish;
    end
    initial begin #100000; $fatal(1,"Ethernet bridge timeout"); end
endmodule

// Minimal generated-IP substitute. Read acknowledgements are side effects:
// any extra halfword read is observable through read_count/address/SEL logs.
module liteeth_core (
    input wire sys_clock, sys_reset,
    output wire interrupt,
    input wire [29:0] wishbone_adr,
    input wire [31:0] wishbone_dat_w,
    output reg [31:0] wishbone_dat_r=0,
    input wire [3:0] wishbone_sel,
    input wire wishbone_cyc, wishbone_stb, wishbone_we,
    output reg wishbone_ack=0,
    output wire wishbone_err,
    input wire [2:0] wishbone_cti,
    input wire [1:0] wishbone_bte,
`ifdef KARU_ETH_SGMII
    output wire gmii_clocks_gtx,
    input wire gmii_clocks_rx, gmii_clocks_tx,
    input wire gmii_col, gmii_crs, gmii_int_n,
    output wire gmii_mdc, gmii_rst_n,
    inout wire gmii_mdio,
    input wire [7:0] gmii_rx_data,
    input wire gmii_rx_dv, gmii_rx_er,
    output wire [7:0] gmii_tx_data,
    output wire gmii_tx_en, gmii_tx_er
`else
    input wire mii_clocks_tx, mii_clocks_rx,
    output wire [3:0] mii_tx_data,
    output wire mii_tx_en,
    input wire [3:0] mii_rx_data,
    input wire mii_rx_dv, mii_rx_er, mii_col, mii_crs,
    output wire mii_mdc, mii_rst_n,
    inout wire mii_mdio
`endif
);
    assign interrupt=0, wishbone_err=0;
`ifdef KARU_ETH_SGMII
    assign gmii_clocks_gtx=sys_clock;
    assign gmii_mdc=0, gmii_rst_n=1, gmii_tx_data=0, gmii_tx_en=0, gmii_tx_er=0;
`else
    assign mii_tx_data=0, mii_tx_en=0, mii_mdc=0, mii_rst_n=1;
`endif
    integer read_count=0, write_count=0;
    reg [29:0] read_addr_log[0:127], write_addr_log[0:127];
    reg [3:0] read_sel_log[0:127], write_sel_log[0:127];
    reg [31:0] write_data_log[0:127];
    reg pending=0, we_q;
    reg [29:0] adr_q;
    reg [3:0] sel_q;
    reg [31:0] data_q;
    integer delay_count=0, ack_tail=0;
    always @(posedge sys_clock) begin
        if(sys_reset) begin wishbone_ack<=0; pending<=0; end
        else if(!wishbone_cyc) begin wishbone_ack<=0; pending<=0; end
        else if(wishbone_ack) begin
            // Registered stale ACK persists through two gap clocks while
            // CYC remains asserted. The bridge must wait before its next beat.
            if(!wishbone_stb) begin
                if(ack_tail==0) wishbone_ack<=0;
                else ack_tail<=ack_tail-1;
            end
        end else if(pending) begin
            if(wishbone_adr!==adr_q || wishbone_sel!==sel_q || wishbone_we!==we_q
               || !wishbone_stb || (we_q && wishbone_dat_w!==data_q))
                $fatal(1,"Wishbone request changed before ACK");
            if(delay_count!=0) delay_count<=delay_count-1;
            else begin
                wishbone_ack<=1; pending<=0; ack_tail<=2;
                wishbone_dat_r<=32'h5aa50000 ^ {2'b0,adr_q};
                if(we_q) begin
                    write_addr_log[write_count]<=adr_q; write_sel_log[write_count]<=sel_q;
                    write_data_log[write_count]<=data_q; write_count<=write_count+1;
                end else begin
                    read_addr_log[read_count]<=adr_q; read_sel_log[read_count]<=sel_q;
                    read_count<=read_count+1;
                end
            end
        end else if(wishbone_stb) begin
            pending<=1; adr_q<=wishbone_adr; sel_q<=wishbone_sel;
            we_q<=wishbone_we; data_q<=wishbone_dat_w; delay_count<=2+wishbone_adr[1:0];
            if(wishbone_sel==0) $fatal(1,"empty Wishbone transfer");
        end
    end
endmodule

`ifndef KARU_ETH_SGMII
module eth_mii_loopback (
    input wire eth_clk,
    output wire mii_clocks_tx, mii_clocks_rx,
    input wire [3:0] mii_tx_data,
    input wire mii_tx_en,
    output wire [3:0] mii_rx_data,
    output wire mii_rx_dv, mii_rx_er, mii_col, mii_crs
);
    assign mii_clocks_tx=eth_clk, mii_clocks_rx=eth_clk;
    assign mii_rx_data=0, mii_rx_dv=0, mii_rx_er=0, mii_col=0, mii_crs=0;
endmodule
`endif
