// Directed Debug 1.0 TAP/DTM/CDC checks, independent of the DM/core.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_dtm;
    reg clk=0, rst=1, tck=0, tms=1, tdi=0, trst_n=0;
    wire tdo, tdo_oe, req_valid, resp_ready, dmi_reset;
    reg req_ready=1, resp_valid=0;
    wire [6:0] req_addr;
    wire [1:0] req_op;
    wire [31:0] req_data;
    reg [1:0] resp_op=0;
    reg [31:0] resp_data=0;
    reg [31:0] mem[0:127];
    integer delay_cycles=0, countdown=0, request_count=0, response_count=0, cancelled_count=0;
    reg pending=0;
    reg inject_error=0;
    reg [6:0] saved_addr;
    reg [1:0] saved_op;
    reg [31:0] saved_data;
    integer half_period=7, check_count=0, n, saved_count, saved_responses, saved_cancellations;
    reg sampled;
    reg [63:0] result;
    reg stall_prev=0;
    reg [40:0] stall_payload;
    reg [40:0] reset_payload;
    integer phase, reset_requests;
    karudbg_jtag dut (
        .clk(clk), .rst(rst), .tck(tck), .tms(tms), .tdi(tdi),
        .trst_n(trst_n), .tdo(tdo), .tdo_oe(tdo_oe),
        .dmi_reset_o(dmi_reset),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_addr_o(req_addr), .req_op_o(req_op), .req_data_o(req_data),
        .resp_valid_i(resp_valid), .resp_ready_o(resp_ready),
        .resp_data_i(resp_data), .resp_op_i(resp_op)
    );
    always #3 clk=~clk;
    always @(posedge clk) begin
        if (rst || dmi_reset) begin
            if (!rst && (pending || resp_valid)) cancelled_count<=cancelled_count+1;
            resp_valid<=0; pending<=0; stall_prev<=0;
        end else begin
            if (stall_prev && (!req_valid || {req_addr,req_data,req_op} !== stall_payload))
                $fatal(1,"DMI request changed under backpressure");
            stall_prev <= req_valid && !req_ready;
            stall_payload <= {req_addr,req_data,req_op};
            if (req_valid && req_ready) begin
                if (pending || resp_valid) $fatal(1,"multiple DMI operations in flight");
                if ((^{req_addr,req_data,req_op}) === 1'bx) $fatal(1,"unknown DMI payload %h %h %h", req_addr, req_data, req_op);
                if(req_op !== 1 && req_op !== 2) $fatal(1,"reserved DMI operation escaped reset isolation");
                pending<=1; saved_addr<=req_addr; saved_op<=req_op;
                saved_data<=req_data; countdown<=delay_cycles;
                request_count<=request_count+1;
                // A response-channel reset cannot undo an accepted write.
                if (req_op==2 && !inject_error) mem[req_addr]<=req_data;
            end
            if (pending) begin
                if (countdown>0) countdown<=countdown-1;
                else begin
                    pending<=0; resp_valid<=1;
                    resp_op<=inject_error ? 2'd2 : 2'd0;
                    resp_data<=mem[saved_addr];
                end
            end
            if (resp_valid && resp_ready) begin
                resp_valid<=0; response_count<=response_count+1;
            end
        end
    end

    task tick(input bit ms,input bit di, output bit outbit);
        begin
            tck=0; tms=ms; tdi=di; #(half_period);
            outbit=tdo;
            tck=1; #(half_period);
        end
    endtask
    task idle(input integer cycles);
        integer i;
        begin for(i=0;i<cycles;i=i+1) tick(0,0,sampled); end
    endtask
    task tap_reset;
        integer i;
        begin
            for(i=0;i<7;i=i+1) tick(1,0,sampled);
            idle(20);
        end
    endtask
    task ir(input reg[4:0] value);
        integer i;
        begin
            tick(1,0,sampled); tick(1,0,sampled);
            tick(0,0,sampled); tick(0,0,sampled);
            for(i=0;i<5;i=i+1) tick(i==4,value[i],sampled);
            tick(1,0,sampled); tick(0,0,sampled);
        end
    endtask
    task dr(input integer width,input reg[63:0] value, output reg[63:0] got);
        integer i;
        begin
            got=0;
            tick(1,0,sampled); tick(0,0,sampled); tick(0,0,sampled);
            for(i=0;i<width;i=i+1) begin
                tick(i==width-1,value[i],sampled); got[i]=sampled;
            end
            tick(1,0,sampled); tick(0,0,sampled);
        end
    endtask
    task expect_equal(input reg[63:0] got,input reg[63:0] wanted,input string label_text);
        begin
            check_count=check_count+1;
            if(got !== wanted) $fatal(1,"%s got=%h wanted=%h",label_text,got,wanted);
        end
    endtask
    task status_clear;
        begin ir(5'h10); dr(32,64'h10000,result); idle(5); ir(5'h11); end
    endtask
    task hard_clear;
        begin ir(5'h10); dr(32,64'h20000,result); idle(30); ir(5'h11); end
    endtask
    task dmi(input reg[6:0] address,input reg[31:0] data,input reg[1:0] op);
        begin dr(41,{23'b0,address,data,op},result); end
    endtask
    task read_ok(input reg[6:0] address,input reg[31:0] wanted);
        begin
            dmi(address,0,1); idle(20); dmi(0,0,0);
            expect_equal(result[1:0],0,"read status");
            expect_equal(result[33:2],wanted,"read data");
            expect_equal(result[40:34],address,"read address"); idle(10);
        end
    endtask

    initial begin
        for(n=0;n<128;n=n+1) mem[n]=32'h12340000+n;
        #40; rst=0; #20; trst_n=1; tap_reset;
        dr(32,0,result); expect_equal(result,32'h00000db3,"IDCODE");
        ir(5'h10); dr(32,0,result);
        expect_equal(result,32'h1071,"DTMCS version/abits/idle");
        ir(5'h1f); dr(1,1,result); expect_equal(result,0,"BYPASS capture");
        ir(5'h11);
        read_ok(7'h04,32'h12340004);
        dmi(7'h04,32'hcafebabe,2); idle(20); dmi(0,0,0);
        expect_equal(result[1:0],0,"write status"); idle(10);
        read_ok(7'h04,32'hcafebabe);

        // Arbitrarily stalled request must remain stable and execute once.
        req_ready=0; saved_count=request_count;
        dmi(7'h05,32'h01234567,2); idle(15);
        expect_equal(request_count,saved_count,"request backpressure");
        dmi(0,0,0); expect_equal(result[1:0],3,"busy capture");
        req_ready=1; idle(25);
        expect_equal(request_count,saved_count+1,"exactly one stalled request");
        dmi(7'h06,32'hdeadbeef,2); idle(10);
        expect_equal(request_count,saved_count+1,"sticky busy blocks writes");
        status_clear; read_ok(7'h05,32'h01234567);

        // dmireset clears status without aborting the pending operation.
        delay_cycles=1000; saved_count=request_count;
        dmi(7'h06,32'hf00dcafe,2); idle(10);
        saved_responses=response_count; saved_cancellations=cancelled_count;
        dmi(0,0,0); expect_equal(result[1:0],3,"delayed response busy");
        status_clear; idle(800); delay_cycles=0;
        expect_equal(request_count,saved_count+1,"dmireset preserves request");
        expect_equal(cancelled_count,saved_cancellations,"dmireset never flushes a transaction");
        expect_equal(response_count,saved_responses+1,"dmireset preserves pending response");
        read_ok(7'h06,32'hf00dcafe);

        inject_error=1; dmi(7'h07,0,1); idle(20); dmi(0,0,0);
        expect_equal(result[1:0],2,"failed response captured");
        saved_count=request_count; dmi(7'h08,0,1); idle(10);
        expect_equal(request_count,saved_count,"sticky failed blocks request");
        ir(5'h10); dr(32,0,result);
        expect_equal(result[11:10],2,"DTMCS sticky failed alias");
        inject_error=0; status_clear; read_ok(7'h07,32'h12340007);

        // Hard reset forgets a transaction whose response never arrives.
        delay_cycles=400; dmi(7'h09,32'h99887766,2); idle(10);
        hard_clear; idle(400); delay_cycles=0;
        read_ok(7'h0a,32'h1234000a);
        read_ok(7'h09,32'h99887766);
        delay_cycles=100000000; dmi(7'h0d,32'hba5eba11,2); idle(10);
        hard_clear; delay_cycles=0;
        read_ok(7'h0a,32'h1234000a);

        // TRST and TMS resets also flush pending response-channel state.
        delay_cycles=400; dmi(7'h0b,32'h55667788,2); idle(10);
        reset_payload=dut.cdc.request_payload;
        trst_n=0; #1;
        expect_equal(dut.cdc.request_payload,reset_payload,"TRST holds bundled request payload");
        #18; trst_n=1; tap_reset; idle(400); delay_cycles=0;
        ir(5'h11); read_ok(7'h0b,32'h55667788);
        delay_cycles=400; dmi(7'h0c,32'h13579bdf,2); idle(10);
        tap_reset; idle(400); delay_cycles=0;
        ir(5'h11); read_ok(7'h0c,32'h13579bdf);

        // Assert TRST while the request level is between synchronizer stages.
        // A pre-clear request may complete, but its address/data/op must remain
        // the original command, never reset zeroes or an unrelated operation.
        for(phase=0;phase<5;phase=phase+1) begin
            reset_requests=request_count;
            fork
                begin
                    wait(dut.cdc.req_sync1 && !dut.cdc.req_sync2);
                    reset_payload=dut.cdc.request_payload;
                    #(phase*3); trst_n=0; #1;
                    expect_equal(dut.cdc.request_payload,reset_payload,"reset-window bundled payload hold");
                    #19; trst_n=1;
                end
                begin dmi(7'h30+7'(phase),32'hcafe1000+32'(phase),2); end
            join
            tap_reset; ir(5'h11); idle(20);
            if(request_count != reset_requests)
                expect_equal(mem[7'h30+7'(phase)],32'hcafe1000+32'(phase),"pre-clear accepted write payload");
            read_ok(7'h0a,32'h1234000a);
        end

        // Clock-ratio/phase sweep, including TCK faster than the DM clock.
        for(n=1;n<=11;n=n+2) begin
            half_period=n; idle(40);
            dmi(7'h20+n,32'hfedc0000+n,2); idle(70);
            dmi(0,0,0); expect_equal(result[1:0],0,"ratio write"); idle(40);
            read_ok(7'h20+n,32'hfedc0000+n);
        end
        expect_equal(request_count,response_count+cancelled_count,"all requests responded or reset");
        $display("PASS DTM checks=%0d requests=%0d responses=%0d reset=%0d",check_count,request_count,response_count,cancelled_count);
        $finish;
    end
    initial begin #1000000; $fatal(1,"DTM test timeout"); end
endmodule
