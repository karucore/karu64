// SPDX-License-Identifier: BSD-3-Clause
// Independent platform-cache request/acknowledgement model and SBA checks.
`ifdef TEST_SBA_PROBE
    reg external_cache_watch = 0, external_cache_pending = 0;
    integer external_cache_requests = 0, external_cache_completions = 0;
    integer external_cache_wait_cycles = 0, external_cache_halt_collision = 0;
    always @(posedge clk) begin
        if (rst || hart_reset_i || ndmreset_o) external_cache_pending <= 0;
        else if (external_cache_watch) begin
            if (cache_flush_req && dut.sba_pause) begin
                check(!external_cache_pending, "SBA external cache request is a single pulse");
                check(cache_flush_invalidate, "SBA external cache request invalidates instructions");
                external_cache_pending <= 1;
                external_cache_requests <= external_cache_requests + 1;
                if (dut.core.dbg_enter)
                    external_cache_halt_collision <= external_cache_halt_collision + 1;
            end
            if (external_cache_pending && !cache_flush_done) begin
                external_cache_wait_cycles <= external_cache_wait_cycles + 1;
                check(!dut.system_bus.resp_valid_o,
                      "SBA response precedes external cache completion");
                check(dut.sba_pause, "SBA pause covers external cache completion");
                check(!dut.core.perf_retire, "SBA external cache wait stops retirement");
            end
            if (cache_flush_done && external_cache_pending) begin
                external_cache_pending <= 0;
                external_cache_completions <= external_cache_completions + 1;
            end
        end else external_cache_pending <= 0;
    end
    task sba_external_launch(input [31:0] address, input [31:0] data);
        begin
            wr(7'h38, 32'h00040000);
            wr(7'h39, address);
            wr(7'h3c, data);
        end
    endtask
    // Start this DMI transaction at an observed AXI write response boundary;
    // it makes the hart's halt entry coincide with the first maintenance edge.
    task sba_external_halt_at_response;
        integer timeout;
        begin
            timeout = 0;
            while (!(dmem_bvalid && dmem_bready) && timeout < 1000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 1000, "SBA halt collision observes write response");
            dmi_req_valid_i = 1; dmi_req_addr_i = 7'h10;
            dmi_req_op_i = 2; dmi_req_data_i = 32'h80000001;
            check(dmi_req_ready_o, "SBA halt collision DMI ready");
            @(posedge clk); #1;
            @(negedge clk); dmi_req_valid_i = 0;
            timeout = 0;
            while (!dmi_resp_valid_o && timeout < 100) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(dmi_resp_valid_o && dmi_resp_op_o == 0, "SBA halt collision DMI response");
            dmi_resp_ready_i = 1;
            @(posedge clk); #1;
            @(negedge clk); dmi_resp_ready_i = 0;
        end
    endtask
    task sba_external_cache_tests;
        integer mode, retired_before, timeout;
        reg [63:0] data;
        begin
`ifndef TEST_SBA_CORE_LOCKED
            // Exercise a delayed platform cache independently of the local
            // cache hit tests. The running case also checks eventual progress.
            for (mode = 0; mode < 2; mode = mode + 1) begin
                if (mode != 0) begin
                    sba_write(32'h80007000, 3, 64'hffdff06f00128293, 0);
                    write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80007000);
                    resume_hart;
                end
                retired_before = normal_retired;
                @(negedge clk);
                cache_flush_delay = 24;
                cache_flush_idle_done = mode == 0;
                external_cache_requests = 0; external_cache_completions = 0;
                external_cache_wait_cycles = 0; external_cache_watch = 1;
                sba_write(mode == 0 ? 32'h80006a00 : 32'h80007000,
                          2, 64'h00228293, 0);
                @(negedge clk);
                check(external_cache_requests == 1 && external_cache_completions == 1,
                      "SBA external cache handshake completes exactly once");
                check(external_cache_wait_cycles >= 24,
                      "SBA external cache delayed acknowledgement is exercised");
                external_cache_watch = 0; cache_flush_delay = 0; cache_flush_idle_done = 0;
                sba_read(mode == 0 ? 32'h80006a00 : 32'h80007000, 2, 0, data);
                check(data[31:0] == 32'h00228293, "SBA external cache write readback");
                if (mode != 0) begin
                    repeat (100) @(negedge clk);
                    check(normal_retired > retired_before,
                          "SBA external cache completion releases running hart");
                    wr(7'h10, 32'h80000001); wait_parked;
                end
            end
            // Transport reset preserves ownership. Deactivation abandons the
            // reply but finishes maintenance. Hart/fabric reset cancels both
            // the platform cache controller and the pending maintenance.
            for (mode = 0; mode < 3; mode = mode + 1) begin
                @(negedge clk);
                cache_flush_delay = 64;
                external_cache_requests = 0; external_cache_completions = 0;
                external_cache_wait_cycles = 0; external_cache_watch = 1;
                sba_external_launch(32'h80006a40, 32'h5aa50000 + 32'(mode));
                timeout = 0;
                while (!external_cache_pending && timeout < 1000) begin
                    @(negedge clk); timeout = timeout + 1;
                end
                check(timeout < 1000 && dut.sba_pause, "SBA external maintenance is active");
                if (mode == 0) begin
                    dmi_reset_i = 1;
                    repeat (4) @(negedge clk);
                    dmi_reset_i = 0;
                    sba_wait(0);
                end else if (mode == 1) begin
                    wr(7'h10, 0);
                    timeout = 0;
                    while (dut.sba_pause && timeout < 1000) begin
                        @(negedge clk); timeout = timeout + 1;
                    end
                    check(timeout < 1000, "SBA deactivation finishes external maintenance");
                end else begin
                    wr(7'h10, 32'h80000003);
                    repeat (5) @(negedge clk);
                    check(!dut.sba_pause && !external_cache_pending,
                          "SBA reset cancels external maintenance and hold");
                end
                @(negedge clk);
                check(external_cache_requests == 1 && external_cache_completions == (mode == 2 ? 0 : 1),
                      "SBA external maintenance reset/cancel completion counts");
                external_cache_watch = 0; cache_flush_delay = 0;
                if (mode != 0) begin
                    wr(7'h10, 32'h80000003);
                    repeat (5) @(negedge clk);
                    wr(7'h10, 32'h80000001); wait_parked;
                    wr(7'h38, 32'h00067000);
                end
                sba_read(32'h80006a40, 2, 0, data);
                check(data[31:0] == 32'h5aa50000 + 32'(mode),
                      "SBA accepted write survives external-maintenance cancellation");
            end
            // Capture an acknowledgement while a real post-flush instruction
            // read is held. Completion still waits for that read to drain.
            sba_write(32'h80007000, 3, 64'hffdff06f00128293, 0);
            write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80007000);
            resume_hart;
            repeat (100) @(negedge clk);
            cache_flush_wait_fetch = 1;
            external_cache_requests = 0; external_cache_completions = 0;
            external_cache_watch = 1;
            sba_external_launch(32'h80007000, 32'h00228293);
            timeout = 0;
            while (!cache_flush_req && timeout < 1000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 1000, "SBA post-flush fetch test observes maintenance request");
            memory.hold_i_r = 1;
            timeout = 0;
            while (!cache_flush_done && timeout < 1000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 1000 && dut.core.im_rd_lock && !dut.core.dbg_sba_idle,
                  "SBA cache acknowledgement overlaps outstanding instruction read");
            repeat (2) begin @(posedge clk); #1; end
            check(dut.core.dbg_sba_cache_done,
                  "SBA cache acknowledgement survives outstanding instruction read");
            repeat (8) begin
                @(negedge clk);
                check(dut.sba_pause && !dut.system_bus.resp_valid_o,
                      "SBA acknowledged maintenance still waits for instruction read");
            end
            memory.hold_i_r = 0; cache_flush_wait_fetch = 0;
            sba_wait(0);
            check(external_cache_requests == 1 && external_cache_completions == 1,
                  "SBA post-flush read overlap completes one handshake");
            external_cache_watch = 0;
            wr(7'h10, 32'h80000001); wait_parked;
            sba_write(32'h80007000, 3, 64'hffdff06f00128293, 0);
            write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80007000);
            resume_hart;
            @(negedge clk);
            cache_flush_delay = 24;
            external_cache_requests = 0; external_cache_completions = 0;
            external_cache_wait_cycles = 0; external_cache_halt_collision = 0;
            external_cache_watch = 1;
            sba_external_launch(32'h80007000, 32'h00228293);
            sba_external_halt_at_response;
            sba_wait(0); wait_parked;
            check(external_cache_halt_collision == 1,
                  "SBA external maintenance exercises coincident halt entry");
            check(external_cache_requests == 1 && external_cache_completions == 1,
                  "SBA coincident halt preserves external maintenance handshake");
            read_reg(16'h07b1, data);
            check(data == 64'h80007000 || data == 64'h80007004,
                  "SBA coincident halt keeps architectural DPC");
            external_cache_watch = 0; cache_flush_delay = 0;
            $display("karudbg SBA external cache handshake: PASS (%0d checks)", checks);
`endif
        end
    endtask
`endif
