// SBA integration with accepted DMI requests, reply backpressure and DM reset.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_sba_dm;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1, dmi_reset = 0;
    reg valid = 0, ready = 0;
    reg [6:0] addr = 0;
    reg [1:0] op = 0;
    reg [31:0] data = 0;
    wire req_ready, resp_valid;
    wire [31:0] reply;
    wire [1:0] reply_op;
    wire sba_valid, sba_write, sba_rready, ndmreset;
    wire [63:0] sba_addr, sba_data;
    wire [2:0] sba_size;
    reg sba_ready = 0, sba_rvalid = 0;
    reg [63:0] sba_rdata = 0;
    reg [2:0] sba_error = 0;
    integer checks = 0, requests = 0;
    reg [31:0] result;

    karudbg #(.SBA(1), .AUTOEXEC(1)) dut (
        .clk(clk), .rst(rst), .dmi_reset_i(dmi_reset),
        .req_valid_i(valid), .req_ready_o(req_ready), .req_addr_i(addr),
        .req_op_i(op), .req_data_i(data), .resp_valid_o(resp_valid),
        .resp_ready_i(ready), .resp_data_o(reply), .resp_op_o(reply_op),
        .halt_req_o(), .resume_req_o(), .resume_authorized_o(),
        .ndmreset_o(ndmreset), .hart_halted_i(1'b0), .hart_resume_ack_i(1'b0),
        .hart_unavailable_i(1'b0), .hart_reset_i(1'b0),
        .mem_req_i(1'b0), .mem_write_i(1'b0), .mem_addr_i(12'b0),
        .mem_wdata_i(64'b0), .mem_be_i(8'b0), .mem_rdata_o(),
        .mem_ready_o(), .mem_error_o(),
        .sba_req_valid_o(sba_valid), .sba_req_ready_i(sba_ready),
        .sba_req_addr_o(sba_addr), .sba_req_data_o(sba_data),
        .sba_req_size_o(sba_size), .sba_req_write_o(sba_write),
        .sba_resp_valid_i(sba_rvalid), .sba_resp_ready_o(sba_rready),
        .sba_resp_data_i(sba_rdata), .sba_resp_error_i(sba_error)
    );
    always @(posedge clk) if (!rst && sba_valid && sba_ready) requests++;
    task check(input bit condition, input string message);
        begin checks++; if (!condition) $fatal(1, "%0d: %s", checks, message); end
    endtask
    task dmi(input [1:0] operation, input [6:0] address,
             input [31:0] value, output [31:0] response);
        begin
            @(negedge clk); valid = 1; op = operation; addr = address; data = value;
            #1; check(req_ready, "DMI ready");
            @(posedge clk); #1; check(resp_valid && reply_op == 0, "DMI success");
            response = reply;
            @(negedge clk); valid = 0; ready = 1;
            @(posedge clk); #1; check(!resp_valid, "reply consumed once");
            @(negedge clk); ready = 0;
        end
    endtask
    task wr(input [6:0] address, input [31:0] value);
        reg [31:0] unused_value;
        begin dmi(2, address, value, unused_value); end
    endtask
    task rd(input [6:0] address, input [31:0] value);
        begin dmi(1, address, 0, result); check(result === value, "DM SBA register value"); end
    endtask
    task accept;
        begin
            @(negedge clk); check(sba_valid && !sba_rready, "unaccepted request owned by DM");
            sba_ready = 1;
            @(posedge clk); #1; check(!sba_valid && sba_rready, "accepted request owned by adapter");
            @(negedge clk); sba_ready = 0;
        end
    endtask
    task respond(input [63:0] value, input [2:0] error);
        begin
            @(negedge clk); check(sba_rready, "response owner present");
            sba_rvalid = 1; sba_rdata = value; sba_error = error;
            @(posedge clk); #1; check(!sba_rready, "response accepted exactly once");
            @(negedge clk); sba_rvalid = 0;
        end
    endtask
    initial begin
        repeat (4) @(negedge clk); rst = 0;
        rd(7'h38, 0); wr(7'h10, 1);
        rd(7'h38, 32'h2004040f);
        wr(7'h18, 32'h00ff0003); // SBA accesses must not launch abstractauto.
        wr(7'h38, 32'h70000); // 64-bit, successful-transfer increment.
        wr(7'h39, 32'h80000000); wr(7'h3d, 32'h01234567);
        wr(7'h3c, 32'h89abcdef);
        check(sba_addr == 64'h80000000 && sba_data == 64'h0123456789abcdef &&
            sba_size == 3 && sba_write, "new low word visible in first write");
        rd(7'h16, 32'h08000002);
        accept;
        // Channel reset is not a system-bus abort.
        @(negedge clk); dmi_reset = 1;
        repeat (3) @(negedge clk);
        check(sba_rready, "DMI reset preserves bus ownership");
        dmi_reset = 0;
        rd(7'h38, 32'h2027040f);
        respond(0, 0); rd(7'h39, 32'h80000008);

        wr(7'h38, 32'h160000); // read-on-address, 64-bit.
        wr(7'h39, 32'h80000020); accept;
        respond(64'hfeedcafe11223344, 0);
        wr(7'h38, 32'h68000); // read-on-data, no increment.
        @(negedge clk); valid = 1; op = 1; addr = 7'h3c;
        @(posedge clk); #1;
        check(resp_valid && reply == 32'h11223344, "read returns pre-execution data");
        @(negedge clk); valid = 0;
        accept;
        respond(64'h0102030455667788, 0);
        repeat (5) begin
            @(negedge clk);
            check(resp_valid && reply == 32'h11223344, "held DMI reply stable across new bus data");
        end
        ready = 1;
        @(posedge clk); #1; check(!resp_valid, "held DMI reply consumed");
        @(negedge clk); ready = 0;
        wr(7'h38, 32'h60000); rd(7'h3c, 32'h55667788);

        // ndmreset preserves dmactive/configuration but cancels the bus.
        wr(7'h3c, 0); accept;
        wr(7'h10, 3);
        check(ndmreset && !sba_rready && !sba_valid, "ndmreset cancels platform ownership");
        wr(7'h10, 1); rd(7'h38, 32'h2006740f);
        wr(7'h38, 32'h67000);

        // Unaccepted maintenance request is canceled by deactivation.
        wr(7'h3c, 1); check(sba_valid, "pending request before dmactive clear");
        wr(7'h10, 0); check(!sba_valid, "deactivation withdraws pending request");
        wr(7'h10, 1); rd(7'h38, 32'h2004040f);

        // Accepted operation cannot be bypassed by reactivating the DM.
        wr(7'h39, 32'h80000040); wr(7'h3c, 1); accept;
        wr(7'h10, 0); check(sba_rready, "deactivation retains accepted ownership");
        wr(7'h10, 1); rd(7'h38, 32'h2024040f);
        respond(64'hffffffffffffffff, 2);
        rd(7'h38, 32'h2004040f); rd(7'h3c, 0);
        rd(7'h18, 0);

        // Acceptance and dmactive clear can occur on the same rising edge.
        // The old active value authorizes that transfer, so it must drain.
        wr(7'h39, 32'h80000080); wr(7'h3c, 2);
        @(negedge clk); valid = 1; op = 2; addr = 7'h10; data = 0;
        sba_ready = 1;
        @(posedge clk); #1;
        check(resp_valid && sba_rready && !sba_valid,
              "same-edge deactivation does not lose accepted ownership");
        @(negedge clk); valid = 0; ready = 1; sba_ready = 0;
        @(posedge clk); #1;
        @(negedge clk); ready = 0;
        wr(7'h10, 1); rd(7'h38, 32'h2024040f);
        respond(0, 0); rd(7'h38, 32'h2004040f); rd(7'h39, 0);
        $display("karudbg SBA DMI: PASS (%0d checks, %0d accepted requests)", checks, requests);
        $finish;
    end
    initial begin #1000000; $fatal(1, "SBA DMI timeout"); end
endmodule
