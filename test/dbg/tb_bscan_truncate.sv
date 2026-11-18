// SPDX-License-Identifier: BSD-3-Clause
// Truncated USER4 scans against the real tunnel/DTM/DM (review finding S9).
// A USER4 DMI-write frame is cut after n bits, n=1..52 (the full frame is 53
// bits), with NO outer Test-Logic-Reset. The tunnel must resynchronize the
// inner TAP on the next capture: later well-formed frames read DTMCS=0x1071,
// issue no DMI request nobody sent, and normal DMI traffic still works.
// The full sweep takes well under a second; it is deterministic (no seeds).
`timescale 1ns/1ps
module tb_bscan_truncate;
    reg clk=0, rst=1, tck=0, tms=1, tdi=0, trst_n=0;
    wire tdo;
    wire [31:0] request_count;
    reg sampled;
    integer checks=0, fails=0;
    tb_bscan_remote dut(.*);
    always #3 clk=~clk;

    task fail(input [8*96-1:0] what, input integer cut);
        begin
            fails=fails+1;
            $display("FAIL cut@%0d: %0s", cut, what);
        end
    endtask

    task tick(input reg mode,input reg data);
        begin tck=0;tms=mode;tdi=data;#5;sampled=tdo;#5;tck=1;#10; end
    endtask
    task idle(input integer cycles);
        integer n;
        begin for(n=0;n<cycles;n=n+1)tick(0,0);end
    endtask
    task reset_tap;
        integer n;
        begin for(n=0;n<6;n=n+1)tick(1,0); tick(0,0); end
    endtask
    task select_user(input reg [5:0] instruction);
        integer n;
        begin
            tick(1,0);tick(1,0);tick(0,0);tick(0,0);
            for(n=0;n<6;n=n+1)tick(n==5,instruction[n]);
            tick(1,0);tick(0,0);
        end
    endtask
    // Outer DR scan of `bits` bits from Run-Test/Idle back to Run-Test/Idle.
    // With bits shorter than the tunnel frame, this is the truncated scan.
    task raw_scan(input reg [63:0] value,input integer bits,output reg [63:0] result);
        integer n;
        begin
            result=0;
            tick(1,0);tick(0,0);tick(0,0);
            for(n=0;n<bits;n=n+1)begin
                tick(n==bits-1,value[n]);result[n]=sampled;
            end
            tick(1,0);tick(0,0);
        end
    endtask
    function [63:0] frame(input reg data_scan,input integer width,input reg [40:0] value);
        frame=(value<<8) | (width<<1) | data_scan;
    endfunction
    function integer frame_bits(input reg data_scan,input integer width);
        frame_bits=8+width+3+(data_scan?1:0);
    endfunction
    task tunnel_scan(input reg data_scan,input integer width,
                     input reg [40:0] value,output reg [40:0] result);
        reg [63:0] scan_result;
        begin
            raw_scan(frame(data_scan,width,value),frame_bits(data_scan,width),scan_result);
            result=scan_result>>9;
        end
    endtask
    task select_inner(input reg [4:0] instruction);
        reg [40:0] result;
        begin tunnel_scan(0,5,{36'b0,instruction},result);end
    endtask
    task dmi(input reg [6:0] address,input reg [31:0] value,input reg [1:0] operation,
             input integer cut,output reg [31:0] result);
        reg [40:0] response;
        begin
            select_inner(5'h11);
            tunnel_scan(1,41,{address,value,operation},response);
            idle(12);
            tunnel_scan(1,41,0,response);
            if(response[1:0]!=0)fail("DMI response error after recovery",cut);
            result=response[33:2];
        end
    endtask

    // Requests seen by the DM, for checking what a truncated frame committed.
    reg [6:0] last_addr; reg [1:0] last_op; reg [31:0] last_data;
    always @(posedge clk)
        if(dut.target_fixture.req_valid && dut.target_fixture.req_ready)begin
            last_addr<=dut.target_fixture.req_addr;
            last_op<=dut.target_fixture.req_op;
            last_data<=dut.target_fixture.req_data;
        end

    // After a resynchronizing reset the inner TAP must reach Run-Test/Idle
    // before the header's IR/DR preamble (header bit 4), as in normal frames.
    integer idle_violations=0;
    always @(negedge dut.itck)
        if(!rst && dut.dtm_trst_n && dut.tunnel.phase==1 &&
           dut.tunnel.header_bit==4 &&
           dut.target_fixture.transport.tap.state!==1)
            idle_violations=idle_violations+1;

    localparam [31:0] TRUNC_DATA=32'h5555aaaa, BASE_DATA=32'hdeaf1234;
    reg [31:0] value, expect_data0;
    reg [40:0] response;
    reg [63:0] raw;
    integer n, before_cut, after_cut, idle_before, committed=0;
    initial begin
        #1;trst_n=1;#1;trst_n=0;#38;
        rst=0;trst_n=1;reset_tap;select_user(6'h23);
        dmi(7'h10,1,2,0,value);                 // dmactive
        for(n=1;n<frame_bits(1,41);n=n+1)begin
            dmi(7'h04,BASE_DATA,2,n,value);     // data0 := known value
            select_inner(5'h11);
            idle(4);
            before_cut=request_count;
            idle_before=idle_violations;
            // DMI write data0 := TRUNC_DATA, cut after n bits, no outer TLR.
            raw_scan(frame(1,41,{7'h04,TRUNC_DATA,2'b10}),n,raw);
            idle(4);                            // let any request cross the CDC
            after_cut=request_count;
            // A cut past the inner Update-DR may commit the intended write,
            // never anything else and never more than once.
            expect_data0=BASE_DATA;
            if(after_cut-before_cut>1)fail("truncated frame issued multiple DMI requests",n);
            else if(after_cut-before_cut==1)begin
                if(last_addr!==7'h04 || last_op!==2'b10 || last_data!==TRUNC_DATA)
                    fail("truncated frame committed a corrupted DMI request",n);
                expect_data0=TRUNC_DATA;
                committed=committed+1;
            end
            checks=checks+1;
            // Next well-formed frames: select DTMCS and read it.
            select_inner(5'h10);tunnel_scan(1,32,0,response);
            idle(4);
            if(request_count!=after_cut)fail("phantom DMI request in next frames",n);
            checks=checks+1;
            if(response[31:0]!==32'h1071)fail("DTMCS read wrong after truncated frame",n);
            checks=checks+1;
            if(idle_violations!=idle_before)fail("inner TAP not Idle before header preamble",n);
            checks=checks+1;
            // Normal DMI traffic still works and the DM saw only intended writes.
            dmi(7'h04,0,1,n,value);
            if(value!==expect_data0)fail("data0 corrupted by truncated frame",n);
            checks=checks+1;
            dmi(7'h04,32'hc0de0000|n,2,n,value);
            dmi(7'h04,0,1,n,value);
            if(value!==(32'hc0de0000|n))fail("DMI write/read broken after truncated frame",n);
            checks=checks+1;
            if(request_count!=after_cut+3)fail("unexpected DMI request count after recovery",n);
            checks=checks+1;
            // Independent cases: start each cut from a clean outer TAP.
            reset_tap;select_user(6'h23);
        end
        if(fails!=0)
            $fatal(1,"FAIL bscan truncated USER4 scan recovery: %0d failing checks of %0d",fails,checks);
        if(committed==0 || committed==n-1)
            $fatal(1,"FAIL bscan truncated USER4 scan recovery: sweep lost coverage (committed=%0d)",committed);
        $display("PASS bscan truncated USER4 scan recovery cuts=1..%0d checks=%0d committed-at-cut=%0d DMI=%0d",
                 n-1,checks,committed,request_count);
        $finish;
    end
    initial begin #20000000;$fatal(1,"FAIL bscan truncated USER4 scan recovery: timeout");end
endmodule
