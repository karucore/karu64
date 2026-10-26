// karudbg direct-DMI/memory protocol tests. Independent register expectations.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karudbg_defs.vh"
module tb_dm;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1, dmi_reset = 0;
    reg req_valid = 0, resp_ready = 0;
    reg [6:0] req_addr = 0;
    reg [1:0] req_op = 0;
    reg [31:0] req_data = 0;
    wire req_ready, resp_valid;
    wire [31:0] resp_data;
    wire [1:0] resp_op;
    wire halt_req, resume_req, resume_authorized, ndmreset;
    reg halted = 0, resumed = 0, unavailable = 0, hart_reset = 0;
    reg mem_req = 0, mem_write = 0;
    reg [11:0] mem_addr = 0;
    reg [63:0] mem_wdata = 0;
    reg [7:0] mem_be = 0;
    wire [63:0] mem_rdata;
    wire mem_ready, mem_error;
    integer checks = 0;
    integer k;
    reg [31:0] value, saved, command;
    reg [63:0] memory;
    reg [31:0] state;

    karudbg dut (
        .clk(clk), .rst(rst), .dmi_reset_i(dmi_reset),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_addr_i(req_addr),
        .req_op_i(req_op), .req_data_i(req_data), .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready), .resp_data_o(resp_data), .resp_op_o(resp_op),
        .halt_req_o(halt_req), .resume_req_o(resume_req),
        .resume_authorized_o(resume_authorized), .ndmreset_o(ndmreset),
        .hart_halted_i(halted), .hart_resume_ack_i(resumed),
        .hart_unavailable_i(unavailable), .hart_reset_i(hart_reset),
        .mem_req_i(mem_req), .mem_write_i(mem_write), .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata), .mem_be_i(mem_be),
        .mem_rdata_o(mem_rdata), .mem_ready_o(mem_ready), .mem_error_o(mem_error)
    );

    task check(input bit condition, input string description);
        begin
            checks = checks + 1;
            if (!condition) $fatal(1, "check %0d: %s", checks, description);
        end
    endtask
    task dmi(input [1:0] op, input [6:0] addr, input [31:0] data,
             output [31:0] result);
        begin
            @(negedge clk);
            req_valid = 1; req_addr = addr; req_op = op; req_data = data;
            #1; check(req_ready, "DMI ready before request");
            @(posedge clk); #1;
            check(resp_valid && resp_op == 0, "DMI successful response");
            result = resp_data;
            @(negedge clk); req_valid = 0; resp_ready = 1;
            @(posedge clk); #1; check(!resp_valid, "DMI response consumed once");
            @(negedge clk); resp_ready = 0;
        end
    endtask
    task wr(input [6:0] addr, input [31:0] data);
        reg [31:0] ignored;
        begin dmi(2, addr, data, ignored); end
    endtask
    task rd(input [6:0] addr, input [31:0] expected);
        reg [31:0] actual;
        begin
            dmi(1, addr, 0, actual);
            if (actual !== expected)
                $fatal(1, "DMI[%02x] = %08x, expected %08x", addr, actual, expected);
            checks = checks + 1;
        end
    endtask
    task mw(input [11:0] addr, input [63:0] data, input [7:0] be);
        begin
            @(negedge clk); mem_req = 1; mem_write = 1;
            mem_addr = addr; mem_wdata = data; mem_be = be;
            #1; check(mem_ready && !mem_error, "memory write accepted");
            @(posedge clk); #1;
            @(negedge clk); mem_req = 0; mem_write = 0; mem_be = 0;
        end
    endtask
    task mr(input [11:0] addr, input [63:0] expected);
        begin
            @(negedge clk); mem_req = 1; mem_write = 0; mem_addr = addr;
            #1; check(mem_ready && !mem_error, "memory read accepted");
            if (mem_rdata !== expected)
                $fatal(1, "memory[%03x] = %016x, expected %016x", addr, mem_rdata, expected);
            checks = checks + 1;
            @(posedge clk); #1;
            @(negedge clk); mem_req = 0;
        end
    endtask
    task clear_error;
        begin wr(7'h16, 32'h700); rd(7'h16, 32'h08000002); end
    endtask
    task run_empty_command(input [31:0] word);
        begin
            wr(7'h17, word);
            rd(7'h16, 32'h08001002);
            mr(12'h400, 1);
            mw(12'h108, 0, 8'h0f);
            mr(12'h400, 0);
            mw(12'h100, 0, 8'h0f);
            rd(7'h16, 32'h08000002);
        end
    endtask

    initial begin
        if ($test$plusargs("negative_resume")) begin
            repeat (3) @(posedge clk);
            @(negedge clk); rst = 0;
            wr(7'h10, 1); halted = 1;
            mw(12'h100, 0, 8'h0f);
            wr(7'h10, 32'h40000001);
            check(!resume_authorized, "resume not authorized before RESUMING");
            @(negedge clk); resumed = 1;
            @(posedge clk); #1;
            $fatal(1, "negative control did not reject missing RESUMING");
        end
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        rd(7'h10, 0);
        wr(7'h04, 32'hffffffff);
        wr(7'h10, 1);
        rd(7'h04, 0);
        rd(7'h11, 32'h00000c83); // running, version1.0, authenticated
        rd(7'h12, 32'h00200000); // nscratch=2; no false low-address data shadow
        wr(7'h12, 32'hffffffff);
        rd(7'h12, 32'h00200000); // hartinfo is entirely read-only
        rd(7'h16, 32'h08000002);
        // Single-hart selection and all optional control fields are WARL zero.
        wr(7'h10, 32'h0fffffff);
        rd(7'h10, 3);
        check(ndmreset, "ndmreset independent of DM reset");
        rd(7'h11, 32'h000c3083); // unavailable and sticky reset observation
        wr(7'h10, 1);
        wr(7'h10, 32'h10000001);
        rd(7'h11, 32'h00000c83);

        // Absent autoexec, SBA and hart-array registers remain zero.
        for (k = 0; k < 12; k = k + 1) begin
            case (k)
                0: state = 7'h18; 1: state = 7'h38; 2: state = 7'h39;
                3: state = 7'h3a; 4: state = 7'h3b; 5: state = 7'h3c;
                6: state = 7'h3d; 7: state = 7'h3e; 8: state = 7'h3f;
                9: state = 7'h1d; 10: state = 7'h14; 11: state = 7'h15;
            endcase
            wr(state[6:0], 32'hffffffff); rd(state[6:0], 0);
        end
        wr(7'h04, 32'h01234567); wr(7'h05, 32'h89abcdef);
        mr(12'h380, 64'h89abcdef01234567);
        mw(12'h380, 64'h1122334455667788, 8'h0f);
        rd(7'h04, 32'h55667788); rd(7'h05, 32'h89abcdef);
        mw(12'h380, 64'h0123456789abcdef, 8'h50);
        rd(7'h05, 32'h8923cd67);
        mw(12'h380, 64'hffffffffffffffff, 0);
        rd(7'h05, 32'h8923cd67);
        for (k = 0; k < 8; k = k + 1) begin
            wr(7'h20 + 7'(k), 32'h01000013 + 32'(k));
            rd(7'h20 + 7'(k), 32'h01000013 + 32'(k));
        end
        mw(12'h368, 64'hfedcba9876543210, 8'h81);
        rd(7'h22, 32'h01000010); rd(7'h23, 32'hfe000016);
        // A bare Debug Mode flag is insufficient until ROM saves its scratch.
        halted = 1;
        rd(7'h11, 32'h00000c83);
        rd(7'h40, 0);
        wr(7'h17, 32'h00321001); rd(7'h16, 32'h08000402);
        clear_error;
        mw(12'h100, 0, 8'h0f);
        rd(7'h11, 32'h00000383);
        run_empty_command(32'h00321001);
        run_empty_command(32'h00221001);
        run_empty_command(32'h0075ffff); // transfer=0 ignores size/write/regno
        // A transport hard reset cannot cancel an already accepted command.
        wr(7'h17, 32'h00321001);
        @(negedge clk); dmi_reset = 1;
        repeat (2) @(posedge clk);
        @(negedge clk); dmi_reset = 0;
        rd(7'h16, 32'h08001002);
        rd(7'h11, 32'h00000383);
        mw(12'h108, 0, 8'h0f);
        rd(7'h11, 32'h00000383); // still halted during abstract execution
        mw(12'h100, 0, 8'h0f);
        rd(7'h16, 32'h08000002);
        for (k = 0; k < 8; k = k + 1) begin
            command = (32'(k) << 20) | 32'h0002101f;
            if (k == 2 || k == 3) run_empty_command(command);
            else begin wr(7'h17, command); rd(7'h16, 32'h08000202); clear_error; end
            command = command | 32'h00010000;
            if (k == 3) run_empty_command(command);
            else begin wr(7'h17, command); rd(7'h16, 32'h08000202); clear_error; end
        end
        // Abstract CSR views, including the two debugger-facing debug CSRs.
        run_empty_command(32'h003207b0);
        run_empty_command(32'h002207b1);
        wr(7'h17, 32'h003207b2); rd(7'h16, 32'h08000202); clear_error;
        wr(7'h17, 32'h003207b3); rd(7'h16, 32'h08000202); clear_error;
        wr(7'h17, 32'h00321020); rd(7'h16, 32'h08000202); clear_error;
        wr(7'h17, 32'h00322000); rd(7'h16, 32'h08000202); clear_error;
        wr(7'h17, 32'h01321001); rd(7'h16, 32'h08000202); clear_error;
        wr(7'h17, 32'h003a1001); rd(7'h16, 32'h08000202); clear_error;

        // Sticky error inhibits later commands until explicit W1C recovery.
        wr(7'h17, 32'h00322000);
        wr(7'h17, 32'h00321001);
        mr(12'h400, 0); rd(7'h16, 32'h08000202); clear_error;
        wr(7'h17, 32'h00321001);
        mw(12'h108, 0, 8'h0f);
        mw(12'h118, 0, 8'h0f);
        mw(12'h100, 0, 8'h0f);
        rd(7'h16, 32'h08000302); clear_error;

        // Forbidden data/progbuf access while busy cannot change their contents.
        rd(7'h04, 32'h55667788);
        wr(7'h17, 32'h00321001);
        wr(7'h04, 32'hbadbadba);
        wr(7'h20, 32'hdeadbeef);
        wr(7'h10, 32'hc0000001); // halt/resume writes ignored while busy
        check(!halt_req && !resume_req, "busy run-control writes ignored");
        mw(12'h108, 0, 8'h0f); mw(12'h100, 0, 8'h0f);
        rd(7'h16, 32'h08000102); clear_error;
        rd(7'h04, 32'h55667788); rd(7'h20, 32'h01000013);
        // Reads of abstractcs can poll busy; data reads instead set cmderr=busy.
        wr(7'h17, 32'h00321001); rd(7'h16, 32'h08001002);
        dmi(1, 7'h05, 0, value);
        mw(12'h108, 0, 8'h0f); mw(12'h100, 0, 8'h0f);
        rd(7'h16, 32'h08000102); clear_error;

        // Debug 1.0 forbids asserting these run-control requests while busy;
        // the DM follows its recommendation to ignore their writes while busy.
        // In particular, a zero haltreq is ignored too, rather than clearing
        // the latched request midway through an abstract operation.
        @(negedge clk); hart_reset = 1;
        @(posedge clk); #1;
        @(negedge clk); hart_reset = 0;
        mw(12'h100, 0, 8'h0f);
        wr(7'h10, 32'h80000001);
        check(halt_req, "idle halt request accepted before command");
        wr(7'h17, 32'h00321001);
        wr(7'h10, 32'h00000001);
        check(halt_req, "busy haltreq=0 is ignored per Debug 1.0");
        wr(7'h10, 32'h40000001);
        check(halt_req && !resume_req, "busy resumereq does not start resume");
        wr(7'h10, 32'h10000001);
        rd(7'h11, 32'h000c0383); // busy ack cannot erase sticky reset
        rd(7'h16, 32'h08001002);
        mw(12'h108, 0, 8'h0f); mw(12'h100, 0, 8'h0f);
        check(halt_req, "busy run-control writes retain halt through completion");
        wr(7'h10, 32'h10000001);
        check(!halt_req, "idle haltreq=0 clears the retained request");
        rd(7'h11, 32'h00000383); // idle ackhavereset clears it normally

        // Resume is not acknowledged merely by the ROM store.
        wr(7'h10, 32'h80000001); check(halt_req, "halt request latched");
        wr(7'h10, 32'h40000001); check(resume_req && !halt_req, "resume request latched");
        mr(12'h400, 2);
        check(!resume_authorized, "pending resume alone does not authorize DRET");
        mw(12'h110, 0, 8'h0f);
        check(resume_req, "RESUMING cannot prematurely clear resume request");
        check(resume_authorized, "RESUMING authorizes pending resume");
        rd(7'h11, 32'h00000383);
        @(negedge clk); resumed = 1; halted = 0;
        @(posedge clk); #1;
        @(negedge clk); resumed = 0;
        check(!resume_req, "core exit acknowledges resume");
        rd(7'h11, 32'h00030c83);
        unavailable = 1; rd(7'h11, 32'h00033083);
        unavailable = 0; rd(7'h11, 32'h00030c83);
        hart_reset = 1; rd(7'h11, 32'h000c3083);
        hart_reset = 0; rd(7'h11, 32'h000c0c83);
        wr(7'h10, 32'h10000001); rd(7'h11, 32'h00000c83);

        // Held DMI response is stable; a DMI hard reset flushes only the channel.
        @(negedge clk); req_valid = 1; req_addr = 7'h04; req_op = 1;
        @(posedge clk); #1; saved = resp_data;
        @(negedge clk); req_valid = 0;
        repeat (4) begin
            @(posedge clk); #1;
            check(resp_valid && resp_data == saved && !req_ready,
                  "response held under DMI backpressure");
        end
        @(negedge clk); dmi_reset = 1;
        @(posedge clk); #1; check(!resp_valid && !req_ready, "DMI reset flush");
        @(negedge clk); dmi_reset = 0;
        rd(7'h04, 32'h55667788);
        rd(7'h10, 1);
        // Non-debug reset aborts an abstract operation but preserves the DM.
        halted = 1; mw(12'h100, 0, 8'h0f);
        wr(7'h17, 32'h00321001);
        wr(7'h10, 3);
        rd(7'h10, 3);
        rd(7'h16, 32'h08000402);
        wr(7'h10, 1); clear_error;
        mw(12'h100, 0, 8'h0f);
        wr(7'h10, 32'h10000001);
        run_empty_command(32'h00321001);
        // DM deactivation resets registers without a hart resume side effect.
        wr(7'h10, 0); rd(7'h10, 0); wr(7'h10, 1);
        rd(7'h04, 0); rd(7'h05, 0); rd(7'h20, 0); rd(7'h16, 32'h08000002);
        $display("karudbg DM unit: PASS (%0d checks)", checks);
        $finish;
    end
    initial begin #1000000; $fatal(1, "DM unit timeout"); end
endmodule
