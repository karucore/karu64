// Debug 1.0 SBA register/ownership tests; no core or AXI model required.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_sba;
`ifdef TEST_SBA64
    localparam ABITS = 64;
`else
    localparam ABITS = 32;
`endif
    localparam [31:0] BASE = 32'h2000000f | (ABITS << 5);
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1, active = 0, bus_reset = 0;
    reg dmi_valid = 0;
    reg [1:0] dmi_op = 0;
    reg [6:0] dmi_addr = 0;
    reg [31:0] dmi_data = 0;
    wire [31:0] dmi_read;
    wire req_valid, req_write, resp_ready;
    reg req_ready = 0, resp_valid = 0;
    wire [63:0] req_addr, req_data;
    wire [2:0] req_size;
    reg [63:0] resp_data = 0;
    reg [2:0] resp_error = 0;
    integer checks = 0, transactions = 0;
    integer width_index, n;
    reg [63:0] address, expected;

    karudbg_sba #(.SBASIZE(ABITS)) dut (
        .clk(clk), .rst(rst), .active_i(active), .bus_reset_i(bus_reset),
        .dmi_valid_i(dmi_valid), .dmi_op_i(dmi_op), .dmi_addr_i(dmi_addr),
        .dmi_data_i(dmi_data), .dmi_data_o(dmi_read),
        .req_valid_o(req_valid), .req_ready_i(req_ready), .req_addr_o(req_addr),
        .req_data_o(req_data), .req_size_o(req_size), .req_write_o(req_write),
        .resp_valid_i(resp_valid), .resp_ready_o(resp_ready),
        .resp_data_i(resp_data), .resp_error_i(resp_error)
    );
    always @(posedge clk) if (!rst && req_valid && req_ready)
        transactions = transactions + 1;

    task check(input bit condition, input string message);
        begin
            checks++;
            if (!condition) $fatal(1, "SBA check %0d: %s", checks, message);
        end
    endtask
    task wr(input [6:0] addr, input [31:0] data);
        begin
            @(negedge clk); dmi_valid = 1; dmi_op = 2;
            dmi_addr = addr; dmi_data = data;
            @(posedge clk); #1;
            @(negedge clk); dmi_valid = 0;
        end
    endtask
    task rd(input [6:0] addr, input [31:0] want);
        begin
            @(negedge clk); dmi_valid = 1; dmi_op = 1; dmi_addr = addr;
            #1;
            if (dmi_read !== want)
                $fatal(1, "SBA[%02x] = %08x expected %08x", addr, dmi_read, want);
            checks++;
            @(posedge clk); #1;
            @(negedge clk); dmi_valid = 0;
        end
    endtask
    task configuration(input [2:0] size, input bit inc,
                       input bit onaddr, input bit ondata);
        begin wr(7'h38, (size << 17) | (inc << 16) | (onaddr << 20) |
                             (ondata << 15) | 32'h407000); end
    endtask
    task accept(input bit write_access, input [63:0] addr,
                input [2:0] size, input [63:0] data);
        integer delay;
        begin
            for (delay = 0; delay < 4; delay++) begin
                @(negedge clk);
                check(req_valid && req_write == write_access && req_addr === addr &&
                    req_size == size && (!write_access || req_data === data),
                    "held request is stable and has exact width/address/data");
                check(!resp_ready, "no response ownership before acceptance");
            end
            req_ready = 1;
            @(posedge clk); #1;
            check(!req_valid && resp_ready, "one request accepted, response owned");
            @(negedge clk); req_ready = 0;
        end
    endtask
    task response(input [63:0] data, input [2:0] error);
        begin
            repeat (3) @(negedge clk);
            check(resp_ready && !req_valid, "response stall retains ownership");
            resp_valid = 1; resp_data = data; resp_error = error;
            @(posedge clk); #1;
            check(!resp_ready && !req_valid, "response completes exactly once");
            @(negedge clk); resp_valid = 0;
        end
    endtask
    task address_write(input [63:0] addr);
        begin
            if (ABITS > 32) wr(7'h3a, addr[63:32]);
            wr(7'h39, addr[31:0]);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk); rst = 0;
        if($test$plusargs("bad_engine_state"))begin
            force dut.state_q=2'b11;repeat(2)@(negedge clk);$fatal(1,"missing SBAR1");
        end
        if($test$plusargs("bad_engine_owner"))begin
            force dut.state_q=2;repeat(2)@(negedge clk);$fatal(1,"missing SBAR2");
        end
        if($test$plusargs("bad_engine_cancel"))begin
            force req_valid=1;repeat(2)@(negedge clk);$fatal(1,"missing SBAR4");
        end
        if($test$plusargs("bad_engine_stability"))begin
            active=1;
            configuration(2,0,0,0);address_write(64'h80000000);wr(7'h3c,1);
            repeat(2)@(negedge clk);force dut.address_q=64'h80000008;
            repeat(2)@(negedge clk);$fatal(1,"missing SBAR3");
        end
        rd(7'h38, 0);
        active = 1;
        rd(7'h38, BASE | 32'h40000);
        rd(7'h3b, 0); rd(7'h37, 0); rd(7'h3e, 0); rd(7'h3f, 0);
        for (width_index = 0; width_index < 4; width_index++) begin
            configuration(3'(width_index), 1, 0, 0);
            address = 64'h80000000 + (64'(width_index) << 4);
            address_write(address);
            wr(7'h3d, 32'hf0e1d2c3);
            wr(7'h3c, 32'hb4a59687);
            accept(1, address, 3'(width_index), 64'hf0e1d2c3b4a59687);
            response(0, 0);
            expected = address + (64'd1 << width_index);
            rd(7'h39, expected[31:0]);
            // Read-on-address launches with the newly written address.
            configuration(3'(width_index), 1, 1, 0);
            address_write(address);
            accept(0, address, 3'(width_index), 0);
            response(64'h0123456789abcdef, 0);
            rd(7'h3d, 32'h01234567); rd(7'h3c, 32'h89abcdef);
            rd(7'h39, expected[31:0]);
            // Read-on-data returns old data and launches the next access.
            configuration(3'(width_index), 1, 0, 1);
            rd(7'h3c, 32'h89abcdef);
            accept(0, expected, 3'(width_index), 0);
            response(64'hfedcba9876543210, 0);
            configuration(3'(width_index), 0, 0, 0);
            rd(7'h3c, 32'h76543210);
        end

        // Every unsupported sbaccess is stored, then rejected before bus use.
        for (width_index = 4; width_index < 8; width_index++) begin
            configuration(3'(width_index), 0, 0, 0);
            wr(7'h3c, 32'h12345678);
            check(!req_valid, "unsupported size never reaches bus");
            rd(7'h38, BASE | (width_index << 17) | 32'h4000);
        end
        // Sweep every low address pattern and native width for alignment.
        for (width_index = 1; width_index < 4; width_index++) begin
            for (n = 1; n < (1 << width_index); n++) begin
                configuration(3'(width_index), 0, 0, 0);
                address_write(64'h80000100 + 64'(n));
                wr(7'h3c, 0);
                check(!req_valid, "misalignment rejected before bus");
                rd(7'h38, BASE | (width_index << 17) | 32'h3000);
            end
        end

        // Busy accesses never mutate or duplicate the transaction.
        configuration(3, 1, 0, 0); address_write(64'h80001000);
        wr(7'h3d, 32'h11223344); wr(7'h3c, 32'h55667788);
        wr(7'h39, 32'h90000000); wr(7'h3d, 32'h99999999);
        wr(7'h38, 32'hffffffff);
        rd(7'h3c, 0);
        accept(1, 64'h80001000, 3, 64'h1122334455667788);
        response(0, 0);
        rd(7'h38, BASE | 32'h470000);
        rd(7'h39, 32'h80001008);
        wr(7'h3c, 0); check(!req_valid, "sticky busyerror inhibits access");
        configuration(3, 1, 0, 0);

        // Bus errors are sticky and never autoincrement. All reported codes.
        for (n = 1; n < 8; n++) begin
            configuration(3, 1, 0, 0); address_write(64'h80002000);
            wr(7'h3c, 32'h12345678);
            accept(1, 64'h80002000, 3, 64'h1122334412345678);
            response(0, 3'(n));
            rd(7'h38, BASE | 32'h70000 | (n << 12));
            rd(7'h39, 32'h80002000);
            wr(7'h3c, 0); check(!req_valid, "sticky bus error inhibits access");
        end
        // sberror is bitwise W1C, rather than clear-on-any-nonzero-write.
        wr(7'h38, 32'h71000); rd(7'h38, BASE | 32'h76000);
        wr(7'h38, 32'h72000); rd(7'h38, BASE | 32'h74000);
        wr(7'h38, 32'h74000); rd(7'h38, BASE | 32'h70000);

        // Address increments retain exactly the advertised address width.
        address = ABITS > 32 ? 64'hfffffffffffffff8 : 64'hfffffff8;
        configuration(3, 1, 0, 0); address_write(address);
        wr(7'h3c, 32'h12345678);
        accept(1, address, 3, 64'h1122334412345678);
        response(0, 0);
        rd(7'h39, 0); rd(7'h3a, 0);

        // A 32-bit instance does not expose high registers; a 64-bit one
        // passes every high bit to its backend, which must validate them.
        configuration(3, 0, 0, 0);
        wr(7'h3a, 32'h80000001);
        rd(7'h3a, ABITS > 32 ? 32'h80000001 : 0);
        wr(7'h39, 32'h80003000); wr(7'h3c, 32'habcdef00);
        accept(1, ABITS > 32 ? 64'h8000000180003000 : 64'h80003000,
               3, 64'h11223344abcdef00);
        response(0, ABITS > 32 ? 3'd2 : 3'd0);

        // Before acceptance, deactivation withdraws request and issue hold.
        configuration(3, 0, 0, 0); address_write(64'h80004000); wr(7'h3c, 0);
        check(req_valid, "request pending before cancellation");
        @(negedge clk); active = 0; #1;
        check(!req_valid, "inactive DM immediately withdraws unaccepted request");
        repeat (2) @(negedge clk); active = 1;
        rd(7'h38, BASE | 32'h40000);

        // After acceptance, deactivation cannot give up ownership, and a
        // reactivation must wait for the old cleanup before issuing anew.
        configuration(3, 1, 0, 0); address_write(64'h80005000); wr(7'h3c, 0);
        accept(1, 64'h80005000, 3, 0);
        @(negedge clk); active = 0;
        repeat (2) @(negedge clk); active = 1;
        rd(7'h38, BASE | 32'h240000);
        response(64'hffffffffffffffff, 2);
        rd(7'h38, BASE | 32'h40000); rd(7'h39, 0); rd(7'h3c, 0);

        // Platform/hart reset cancels all ownership, with an explicit error
        // for a live active-DM operation. Late pre-reset responses are ignored.
        configuration(3, 0, 0, 0); address_write(64'h80006000); wr(7'h3c, 0);
        accept(1, 64'h80006000, 3, 0);
        @(negedge clk); bus_reset = 1;
        @(negedge clk); bus_reset = 0;
        rd(7'h38, BASE | 32'h67000);
        @(negedge clk); resp_valid = 1; resp_error = 0;
        @(negedge clk); resp_valid = 0;
        check(!resp_ready && !req_valid, "late reset response has no owner");

        configuration(3, 0, 0, 0); address_write(64'h80007000); wr(7'h3c, 0);
        check(req_valid && !resp_ready, "reset while request still unaccepted");
        @(negedge clk); bus_reset = 1;
        @(negedge clk); bus_reset = 0;
        rd(7'h38, BASE | 32'h67000);
        check(!req_valid && !resp_ready, "reset releases unaccepted ownership");

        $display("karudbg SBA %0d-bit: PASS (%0d checks, %0d transfers)", ABITS, checks, transactions);
        $finish;
    end
    initial begin #1000000; $fatal(1, "SBA test timeout"); end
endmodule
