// SPDX-License-Identifier: BSD-3-Clause
// Outer TAP pauses/deselection/reset against the real tunnel/DTM/DM.
`timescale 1ns/1ps
module tb_bscan_protocol;
    reg clk=0, rst=1, tck=0, tms=1, tdi=0, trst_n=0;
    wire tdo;
    wire [31:0] request_count;
    integer checks=0;
    reg sampled;
    tb_bscan_remote dut(.*);
    always #3 clk=~clk;

    task tick(input reg mode,input reg data);
        begin
            tck=0;tms=mode;tdi=data;#5;sampled=tdo;#5;tck=1;#10;
        end
    endtask
    task idle(input integer cycles);
        integer n;
        begin for(n=0;n<cycles;n=n+1)tick(0,0);end
    endtask
    task reset_tap;
        integer n;
        begin
            for(n=0;n<6;n=n+1)tick(1,0);
            tick(0,0);
            // No extra idle clocks: the first USER4 Capture-DR must survive
            // reset release using only the physical TAP's required edges.
        end
    endtask
    task select_user(input reg [5:0] instruction);
        integer n;
        begin
            tick(1,0);tick(1,0);tick(0,0);tick(0,0);
            for(n=0;n<6;n=n+1)tick(n==5,instruction[n]);
            tick(1,0);tick(0,0);
        end
    endtask
    task raw_scan(input reg [63:0] value,input integer bits,
                  input integer pause_at, output reg [63:0] result);
        integer n;
        begin
            result=0;
            tick(1,0);tick(0,0);tick(0,0);
            for(n=0;n<bits;n=n+1)begin
                tick(n==bits-1 || n==pause_at,value[n]);result[n]=sampled;
                if(n==pause_at && n!=bits-1)begin
                    tick(0,0);idle(9);tick(1,0);tick(0,0);
                end
            end
            tick(1,0);tick(0,0);
        end
    endtask
    task tunnel_scan(input reg data_scan,input integer width,
                     input reg [40:0] value,input integer pause_at,
                     output reg [40:0] result);
        reg [63:0] scan_value, scan_result;
        integer bits;
        begin
            scan_value=(value<<8) | (width<<1) | data_scan;
            bits=8+width+3+(data_scan?1:0);
            raw_scan(scan_value,bits,pause_at,scan_result);
            result=scan_result>>9;
        end
    endtask
    task select_inner(input reg [4:0] instruction);
        reg [40:0] result;
        begin tunnel_scan(0,5,{36'b0,instruction},-1,result);end
    endtask
    task dmi(input reg [6:0] address,input reg [31:0] value,
             input reg [1:0] operation,input integer pause_at,
             output reg [31:0] result);
        reg [40:0] response;
        begin
            select_inner(5'h11);
            tunnel_scan(1,41,{address,value,operation},pause_at,response);
            idle(12);
            tunnel_scan(1,41,0,-1,response);
            if(response[1:0]!=0)$fatal(1,"DMI response error %h",response);
            result=response[33:2];
        end
    endtask
    task check_read(input reg [6:0] address,input reg [31:0] expected,
                    input integer pause_at);
        reg [31:0] actual;
        begin
            dmi(address,0,1,pause_at,actual);
            if(actual!==expected)$fatal(1,"BSCAN register %h got%h expected%h pause%0d",address,actual,expected,pause_at);
            checks=checks+1;
        end
    endtask
    reg [31:0] ignored;
    reg [40:0] response;
    reg [63:0] raw;
    integer n, before_count;
    initial begin
        // Exercise a real asynchronous assertion with no TCK edges, rather
        // than relying on simulator initialization ordering at time zero.
        #1;trst_n=1;#1;trst_n=0;#38;
        rst=0;trst_n=1;reset_tap;select_user(6'h23);
        dmi(7'h10,1,2,-1,ignored);
        dmi(7'h04,32'hdeaf1234,2,-1,ignored);
        // Pause in every header/payload/trailer position. DRCK must not
        // advance the inner TAP while the outer TAP is paused.
        for(n=0;n<52;n=n+1)check_read(7'h04,32'hdeaf1234,n);
        // USER4 deselection must preserve the DM and virtual instruction.
        before_count=request_count;
        select_user(6'h3f);raw_scan(64'h12345678,32,-1,raw);idle(10);
        if(request_count!=before_count)$fatal(1,"Deselected USER4 caused DMI request");
        select_user(6'h23);check_read(7'h04,32'hdeaf1234,-1);
        // Abort incomplete headers and payloads. Outer TAP reset is the
        // defined recovery; it clears transport state, never DM data.
        for(n=0;n<49;n=n+1)begin
            before_count=request_count;
            select_inner(5'h11);
            raw_scan(64'h0000000000000053,n+1,-1,raw);
            reset_tap;select_user(6'h23);
            check_read(7'h04,32'hdeaf1234,-1);
            if(request_count!=before_count+1)$fatal(1,"Aborted scan duplicated request at bit%0d",n);
        end
        select_inner(5'h10);tunnel_scan(1,32,0,-1,response);
        if(response[31:0]!==32'h1071)$fatal(1,"DTMCS recovery failed %h",response);
        checks=checks+1;
        $display("PASS BSCAN protocol checks=%0d accepted DMI=%0d",checks,request_count);
        $finish;
    end
    initial begin #2000000;$fatal(1,"BSCAN protocol timeout");end
endmodule
