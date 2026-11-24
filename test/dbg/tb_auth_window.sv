// A2 simulation island ROM (test/dbg/auth_rom) on the real karudbg_core:
// the contract's CHALLENGE/RESPONSE frames with the simulation-only TEST
// algorithm, every rejection rule, re-push after a session reset, and the
// bounded window, including responses that straddle the deadline and
// repeated ABORTs. Driven only through DMI and the platform inputs; the
// deadline monitor reads the ROM's own deadline variable and the core's
// mcycle. +rom=<hex> replaces the ROM image (used for the mutant ROM).
//
// The ROM polls seed for its nonce, at most TRNG_TRIES + 1 times per word
// without getting one (window.c). The bench measures what one poll costs in
// clock cycles and, with its own stand-in behind seed, runs a source that
// does not deliver:
//   +trng_tries=<n>   the TRNG_TRIES that the ROM was built with
//   +poll_clocks=<n> +poll_clocks_max=<n>  TRNG_POLL_CLOCKS and
//                     TRNG_POLL_CLOCKS_MAX of window.c: the range that the
//                     ROM's limit is sized for. The measured poll must be in it
//   +stall_only       only the cases of a source that does not deliver; for a
//                     ROM built with a small TRNG_TRIES, whose limit acts
//                     well inside the simulation window
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karudbg_defs.vh"
`include "rtl/karu_assert.sv"
module tb_auth_window #(parameter ROM_HEX = "rom.hex");
    reg clk = 0, rst = 1;
    always #5 clk = !clk;
    wire debug_mode_o, debug_resume_ack_o, trap;
    reg irq = 0, irq_software = 0, irq_external_m = 0, irq_external_s = 0;
    reg [63:0] time_in = 0;
    reg [31:0] uncache_page = 0, hpm_events = 0;
    wire cache_flush_req, cache_flush_invalidate;
    reg cache_flush_done = 0;
    wire [`AXI_ID_W-1:0] imem_arid, imem_rid, dmem_arid, dmem_rid, dmem_awid, dmem_bid;
    wire [`AXI_ADDR_W-1:0] imem_araddr, dmem_araddr, dmem_awaddr;
    wire [`AXI_LEN_W-1:0] imem_arlen, dmem_arlen, dmem_awlen;
    wire [`AXI_SIZE_W-1:0] imem_arsize, dmem_arsize, dmem_awsize;
    wire [`AXI_BURST_W-1:0] imem_arburst, dmem_arburst, dmem_awburst;
    wire [`AXI_PROT_W-1:0] imem_arprot, dmem_arprot, dmem_awprot;
    wire [`AXI_DATA_W-1:0] imem_rdata, dmem_rdata, dmem_wdata;
    wire [`AXI_RESP_W-1:0] imem_rresp, dmem_rresp, dmem_bresp;
    wire [`AXI_STRB_W-1:0] dmem_wstrb;
    wire imem_arvalid, imem_arready, imem_rlast, imem_rvalid, imem_rready;
    wire dmem_arvalid, dmem_arready, dmem_rlast, dmem_rvalid, dmem_rready;
    wire dmem_awvalid, dmem_awready, dmem_wlast, dmem_wvalid, dmem_wready;
    wire dmem_bvalid, dmem_bready;
    reg hart_reset_i = 0, dmi_reset_i = 0, dmi_req_valid_i = 0, dmi_resp_ready_i = 0;
    wire dmi_req_ready_o, dmi_resp_valid_o, ndmreset_o;
    reg [6:0] dmi_req_addr_i = 0;
    reg [1:0] dmi_req_op_i = 0;
    reg [31:0] dmi_req_data_i = 0;
    wire [31:0] dmi_resp_data_o;
    wire [1:0] dmi_resp_op_o;
    reg [1:0] lc_i = 2'd1;
    reg hold_strap_i = 1'b1, revoke_i = 1'b0;
    wire auth_reset_o;
    // The ROM draws its nonce from the seed CSR, so the core is built with
    // KARU_ZKR and the bench provides what is behind seed:
    //   by default      a stand-in whose words the bench chooses (an LFSR
    //                   that advances with every word taken)
    //   AUTH_WINDOW_ENTROPY_SRC  the entropy source of the FPGA image, with
    //                   its behavioural noise model, reset with the hart. The
    //                   model runs on through resets, so a window after
    //                   another power-on reset draws another nonce.
    //   AUTH_WINDOW_NO_SEED  nothing: the core is built without KARU_ZKR and
    //                   has no seed CSR. Its ROM is built with -DAUTH_NO_SEED.
    //                   Only the cases of noseed_case below run.
    integer seed_words = 0;
`ifndef AUTH_WINDOW_NO_SEED
    wire [63:0] zkr_rdata_i, zkr_wdata_o;
    wire zkr_fire_o, zkr_we_o;
    wire [1:0] zkr_sel_o;
`ifdef AUTH_WINDOW_ENTROPY_SRC
    karu_entropy_src #(.SIM(2), .SAMPLE_DIV(8), .INTERVAL_RESET(16'd0)) entropy (
        .clk(clk), .rst(dut.core_rst), .en_i(1'b1),
        .csr_fire_i(zkr_fire_o), .csr_sel_i(zkr_sel_o), .csr_we_i(zkr_we_o),
        .csr_wdata_i(zkr_wdata_o), .csr_rdata_o(zkr_rdata_i),
        .reg_re_i(1'b0), .reg_raddr_i(3'd0), .reg_rdata_o(), .reg_we_i(1'b0), .reg_waddr_i(3'd0), .reg_wdata_i(64'b0));
`else
    reg [1:0] seed_opst = 2'd2;
    reg [15:0] seed_data = 16'h5a5a;
    wire seed_taken;
    // A source that reports seed_opst, and from the poll after
    // `deliver_after` polls without a word (if not negative) ES16.
    integer deliver_after = -1;
    wire [1:0] seed_opst_now = (deliver_after >= 0 && idle_polls >= deliver_after) ? 2'd2 : seed_opst;
    karudbg_test_seed seed (
        .zkr_fire_i(zkr_fire_o), .zkr_sel_i(zkr_sel_o), .zkr_we_i(zkr_we_o), .zkr_rdata_o(zkr_rdata_i),
        .opst_i(seed_opst_now), .data_i(seed_data), .taken_o(seed_taken));
    // A 16-bit LFSR advanced by every word the ROM takes, so each window
    // gets a fresh nonce and a replayed response must fail.
    always @(posedge clk) if (seed_taken)
        seed_data <= {seed_data[14:0], seed_data[15] ^ seed_data[13] ^ seed_data[12] ^ seed_data[10]};
`endif
    // The nonce words the ROM took from seed.
    always @(posedge clk)
        if (zkr_fire_o && zkr_we_o && zkr_sel_o == 2'd0 && zkr_rdata_i[31:30] == 2'd2) seed_words = seed_words + 1;
    // The polls of seed that found no word, since the last power-on reset,
    // and the clock cycles from one such poll to the next: what one pass of
    // the loop in make_nonce() costs.
    integer idle_polls = 0, poll_gaps = 0, poll_min = 0, poll_max = 0, poll_total = 0;
    reg [63:0] poll_cycle = 0, idle_first = 0, idle_last = 0;
    reg poll_idle = 0;                             // the access before this one found no word either
    wire seed_access = zkr_fire_o && zkr_we_o && zkr_sel_o == 2'd0;
    always @(posedge clk)
        if (rst) begin
            idle_polls <= 0; poll_gaps <= 0; poll_idle <= 0;
        end else if (seed_access && zkr_rdata_i[31:30] == 2'd2) begin
            poll_idle <= 0;
        end else if (seed_access) begin
            idle_polls <= idle_polls + 1; poll_idle <= 1; poll_cycle <= dut.core.csr.csr_mcycle;
            if (idle_polls == 0) idle_first <= dut.core.csr.csr_mcycle;
            idle_last <= dut.core.csr.csr_mcycle;
            if (poll_idle) begin
                poll_gaps <= poll_gaps + 1; poll_total <= poll_total + 1;
                if (poll_total == 0 || dut.core.csr.csr_mcycle - poll_cycle < poll_min) poll_min <= dut.core.csr.csr_mcycle - poll_cycle;
                if (dut.core.csr.csr_mcycle - poll_cycle > poll_max) poll_max <= dut.core.csr.csr_mcycle - poll_cycle;
            end
        end
`endif
    karudbg_core #(.RESET_PC(64'h0001_0000), .ISLAND_ROM_HEX(ROM_HEX)) dut (.*);
    wire [31:0] mmio_reads, mmio_writes;
    wire [63:0] mmio_value;
    // Fabric-side R channels pass through a bench mux, so a forged beat
    // can be injected without disturbing the memory model's own state.
    wire ram_imem_rvalid, ram_imem_rlast, ram_dmem_rvalid, ram_dmem_rlast;
    wire [`AXI_DATA_W-1:0] ram_imem_rdata, ram_dmem_rdata;
    wire [`AXI_RESP_W-1:0] ram_imem_rresp, ram_dmem_rresp;
    reg inj_i = 0, inj_d = 0;
    reg [63:0] inj_data = 0;
    assign imem_rvalid = inj_i ? 1'b1 : ram_imem_rvalid;
    assign imem_rlast = inj_i ? 1'b1 : ram_imem_rlast;
    assign imem_rdata = inj_i ? inj_data : ram_imem_rdata;
    assign imem_rresp = inj_i ? 2'b00 : ram_imem_rresp;
    assign dmem_rvalid = inj_d ? 1'b1 : ram_dmem_rvalid;
    assign dmem_rlast = inj_d ? 1'b1 : ram_dmem_rlast;
    assign dmem_rdata = inj_d ? inj_data : ram_dmem_rdata;
    assign dmem_rresp = inj_d ? 2'b00 : ram_dmem_rresp;
    karudbg_test_ram memory (.*, .fifo_count(),
        .imem_rvalid(ram_imem_rvalid), .imem_rlast(ram_imem_rlast),
        .imem_rdata(ram_imem_rdata), .imem_rresp(ram_imem_rresp),
        .dmem_rvalid(ram_dmem_rvalid), .dmem_rlast(ram_dmem_rlast),
        .dmem_rdata(ram_dmem_rdata), .dmem_rresp(ram_dmem_rresp));


    localparam [63:0] RAM = 64'h8000_0000;
    integer checks = 0;
    reg saw_debug = 0, saw_breakpoint = 0;
    integer illegal_traps = 0;
    // Hostile fabric: inject the TEST response word as an external R beat
    // while the ROM's island SRAM load is presented (plan lemma C9).
    reg inject_armed = 0;
    integer injected = 0;
    always @(negedge clk) begin
        if (inject_armed && injected == 0 && dut.k_dmem_arvalid &&
            dut.k_dmem_araddr == 32'h0002_0000) begin
            injected = 1;
            inj_data = 64'h0000_0000_600d_f00d; inj_d = 1;
            repeat (3) @(negedge clk);
            inj_d = 0;
        end
    end
    reg [31:0] value;
    always @(posedge clk) cache_flush_done <= cache_flush_req && !rst;
    // Independent observation of the hart: Debug Mode entries and breakpoint
    // traps, sampled from the core's own state.
    always @(posedge clk) begin
        if (debug_mode_o) saw_debug <= 1;
        if (!rst && dut.core.trap_req && dut.core.trap_cause == 64'd3) saw_breakpoint <= 1;
        if (!rst && dut.core.trap_req && dut.core.trap_cause == 64'd2) illegal_traps <= illegal_traps + 1;
    end
    `include "test/dbg/trigger_checker.vh"

    // ---- deadline monitor ----
    // The ROM's `deadline` variable (island SRAM, address from the ELF) and
    // the core's mcycle give the exact window end. The grant must commit,
    // and every response word must be popped, before deadline + SLACK, where
    // SLACK covers the instructions between a deadline check and the CSR
    // access it guards. The island ROM is fetched uncached, one beat per
    // instruction, so one polling iteration takes about 230 cycles here.
    localparam integer SLACK = 256;
    reg [63:0] deadline_addr = 64'h2_0000;
    reg [1023:0] rom_file;
    wire [63:0] mcycle = dut.core.csr.csr_mcycle;
    wire [63:0] rom_deadline = dut.island.sram[(deadline_addr - 64'h2_0000) >> 3];
    reg window_live = 0;                           // deadline variable written this POR
    integer late_pops = 0, late_grants = 0, grants = 0;
    initial begin
`ifndef AUTH_WINDOW_NO_SEED                        // the no-seed ROM opens no window
        if (!$value$plusargs("deadline_addr=%h", deadline_addr)) $fatal(1, "+deadline_addr required");
`endif
        if ($value$plusargs("rom=%s", rom_file)) begin #1; $readmemh(rom_file, dut.island.rom); end
    end
    always @(posedge clk) if (!rst && window_live) begin
        if (dut.auth.rom_pop && mcycle >= rom_deadline + SLACK) late_pops <= late_pops + 1;
        if (dut.auth.unlock_commit) begin
            grants <= grants + 1;
            if (mcycle >= rom_deadline + SLACK) late_grants <= late_grants + 1;
        end
    end

    task check(input bit c, input string what);
        begin checks = checks + 1; if (!c) $fatal(1, "auth core check %0d: %s", checks, what); end
    endtask
    // Since the start of the run: words the ROM pushed towards the debugger,
    // and grants, whether or not a window was located.
    integer rom_pushes = 0, all_grants = 0;
    always @(posedge clk) if (!rst) begin
        if (dut.auth.rom_push) rom_pushes <= rom_pushes + 1;
        if (dut.auth.unlock_commit) all_grants <= all_grants + 1;
    end
    task dmi(input [1:0] op, input [6:0] addr, input [31:0] data, output [31:0] result);
        integer t;
        begin
            @(negedge clk);
            dmi_req_valid_i = 1; dmi_req_addr_i = addr; dmi_req_op_i = op; dmi_req_data_i = data;
            t = 0; while (!dmi_req_ready_o && t < 100) begin @(negedge clk); t = t + 1; end
            if (!dmi_req_ready_o) $fatal(1, "DMI request timeout");
            @(posedge clk); #1; @(negedge clk); dmi_req_valid_i = 0;
            t = 0; while (!dmi_resp_valid_o && t < 100) begin @(negedge clk); t = t + 1; end
            if (!dmi_resp_valid_o || dmi_resp_op_o != 0) $fatal(1, "DMI response timeout/error");
            result = dmi_resp_data_o;
            dmi_resp_ready_i = 1; @(posedge clk); #1; @(negedge clk); dmi_resp_ready_i = 0;
        end
    endtask
    task wr(input [6:0] a, input [31:0] d); reg [31:0] x; begin dmi(2, a, d, x); end endtask
    task rd(input [6:0] a, output [31:0] r); begin dmi(1, a, 0, r); end endtask
    task wait_parked;
        integer t;
        begin
            t = 0;
            while (!(debug_mode_o && dut.dm.parked_q) && t < 20000) begin @(negedge clk); t = t + 1; end
            check(t < 20000, "hart parked in Debug Mode");
        end
    endtask
    task command(input [31:0] word, input [2:0] err);
        integer t; reg [31:0] s;
        begin
            wr(7'h17, word);
            t = 0; s = 32'h1000;
            while (s[12] && t < 5000) begin rd(7'h16, s); t = t + 1; end
            check(!s[12] && s[10:8] == err, $sformatf("command %08x abstractcs=%08x", word, s));
        end
    endtask
    task poll_status_tx(input integer want);
        integer t;
        begin
            t = 0; rd(7'h30, value);
            while (value[4:0] < want && t < 5000) begin rd(7'h30, value); t = t + 1; end
            check(value[4:0] >= want, "challenge reached TX");
        end
    endtask
    task poll_authenticated(input bit want, input integer bound);
        integer t;
        begin
            t = 0; rd(7'h11, value);
            while (value[7] != want && t < bound) begin rd(7'h11, value); t = t + 1; end
        end
    endtask
    task por(input [1:0] lc, input bit strap);
        begin
            @(negedge clk); rst = 1; lc_i = lc; hold_strap_i = strap; revoke_i = 0;
            memory.clear_ram();
            memory.put_insn('h0, 32'h00128293);            // addi t0,t0,1
            memory.put_insn('h4, 32'hffdff06f);            // j -4
            memory.put_insn('h100, 32'h05500313);          // trap handler: li t1,0x55
            memory.put_insn('h104, 32'h0000006f);          // j .
            repeat (5) @(negedge clk); rst = 0;
            saw_debug = 0; saw_breakpoint = 0; window_live = 0;
        end
    endtask
    // REQUEST, then wait for the ROM to open its window (first TX word).
    task open_window;
        begin
            wr(7'h10, 1); wr(7'h30, 32'h10a50001);
            poll_status_tx(1);
            window_live = 1;
            check(rom_deadline > mcycle && rom_deadline - mcycle <= 64'd400000,
                  "ROM deadline variable located");
        end
    endtask
    task automatic wait_mcycle(input [63:0] target);
        integer t;
        begin
            t = 0;
            while (mcycle < target && t < 500000) begin @(negedge clk); t = t + 1; end
            if (mcycle < target) $fatal(1, "wait_mcycle: mcycle %0d never reached %0d (deadline %0d)", mcycle, target, rom_deadline);
        end
    endtask

    // ---- host side of the frame protocol (contract 5) ----
    reg [31:0] chal [0:19];
    reg [31:0] old_chal [0:19];
    reg [31:0] key [0:7];
    initial begin
        key[0] = 32'h6b617275; key[1] = 32'h64626761; key[2] = 32'h75746821; key[3] = 32'h54455354;
        key[4] = 32'h2d6f6e6c; key[5] = 32'h792d6e6f; key[6] = 32'h742d6372; key[7] = 32'h7970746f;
    end
    function [31:0] rotl(input [31:0] x, input integer r);
        rotl = r == 0 ? x : (x << r) | (x >> (32 - r));
    endfunction
    function [31:0] test_sig(input integer i, input [7:0] granted);
        integer j;
        begin
            test_sig = key[i] ^ ({4{granted}});
            for (j = i; j < 20; j = j + 8) test_sig = test_sig ^ rotl(chal[j], i);
        end
    endfunction
    task status(output [31:0] s); begin rd(7'h30, s); end endtask
    task recv_challenge;
        integer got, n, t;
        reg [31:0] s;
        begin
            got = 0; t = 0;
            while (got < 20 && t < 20000) begin
                status(s);
                n = s[4:0];
                if (n > 20 - got) n = 20 - got;
                if (n > 0) begin
                    wr(7'h30, 32'h30000000 | n);
                    repeat (n) begin rd(7'h30, chal[got]); got = got + 1; end
                end
                t = t + 1;
            end
            check(got == 20, "received the 20-word challenge");
            check(chal[0] == 32'h01018000 && chal[1][15:0] == 72, "challenge header and length");
        end
    endtask
    task send_response(input [31:0] hdr, input [31:0] lenw, input [7:0] granted, input bit corrupt);
        integer i;
        reg [31:0] w;
        begin
            wr(7'h30, 32'h2000000a);                   // SEND 10
            wr(7'h30, hdr);
            wr(7'h30, lenw);
            for (i = 0; i < 8; i = i + 1) begin
                w = test_sig(i, granted);
                if (corrupt && i == 3) w = w ^ 32'h1;
                wr(7'h30, w);
            end
        end
    endtask
    task expect_locked(input string what, input integer wait_cycles);
        reg [31:0] s;
        begin
            repeat (wait_cycles) @(negedge clk);
            rd(7'h11, s); check(s == 32'h00000003, what);
        end
    endtask

    // A core without Zkr has no seed CSR and so no nonce source. Its ROM is
    // built with -DAUTH_NO_SEED: it accepts a REQUEST, makes no challenge,
    // grants nothing, and leaves for the next stage like a ROM whose window
    // ran out. Reading seed there would be an illegal instruction with no
    // trap vector set, so the case also counts those.
    task noseed_case(input bit request);
        integer t, pushes0, traps0;
        reg [31:0] s;
        begin
            por(1, request);                           // held only for a debugger that will ask
            pushes0 = rom_pushes; traps0 = illegal_traps;
            if (request) begin wr(7'h10, 1); wr(7'h30, 32'h10a50001); end
            // until the first instruction is issued at the next stage, or
            // one of the two things this ROM must not do has happened
            t = 0;
            while (!(dut.k_imem_arvalid && dut.k_imem_araddr == RAM[`AXI_ADDR_W-1:0]) &&
                   rom_pushes == pushes0 && illegal_traps == traps0 && t < 400000) begin
                @(negedge clk); t = t + 1;
            end
            check(rom_pushes == pushes0, "no challenge word was pushed");
            check(illegal_traps == traps0, "the ROM did not read seed (no illegal instruction)");
            check(t < 400000, "the ROM hands over: first instruction issued at the next stage");
            $display("no seed, %s: next stage after %0d clocks", request ? "REQUEST" : "no request", t);
            if (request) check(dut.auth.auth_req_q, "the REQUEST was accepted");
            check(all_grants == 0 && !dut.auth.auth_unlock_q, "no grant");
            repeat (200) @(negedge clk);
            check(dut.auth.boot_done_q, "the window is closed in hardware");
            if (!request) wr(7'h10, 1);
            rd(7'h30, s);
            check(s[23:21] == 3 && s[4:0] == 0, "mailbox closed, nothing to receive");
            wr(7'h30, 32'h10a50001);                   // a REQUEST after the hand-over
            expect_locked("locked after the hand-over", 5000);
            check(rom_pushes == pushes0 && all_grants == 0, "a later REQUEST gets no challenge and no grant");
            check(!saw_debug && illegal_traps == traps0, "no Debug Mode, no illegal instruction afterwards");
        end
    endtask

`ifndef AUTH_WINDOW_NO_SEED
`ifndef AUTH_WINDOW_ENTROPY_SRC
    // ---- a source that does not deliver (the bench's stand-in behind seed) ----
    // What the ROM was built with, and what window.c assumes for one poll.
    integer trng_tries = 0, poll_clocks = 0, poll_clocks_max = 0;
    // Wait for the first instruction issued at the next stage: the ROM has left.
    task wait_handover(input integer bound, output integer clocks);
        begin
            clocks = 0;
            while (!(dut.k_imem_arvalid && dut.k_imem_araddr == RAM[`AXI_ADDR_W-1:0]) && clocks < bound) begin
                @(negedge clk); clocks = clocks + 1;
            end
            check(clocks < bound, "the ROM hands over: first instruction issued at the next stage");
        end
    endtask
    // The source reports `opst` (0 BIST, 1 WAIT) and never a word. The ROM
    // must make no challenge and leave: after TRNG_TRIES + 1 polls if those
    // fit into its window, else when the window ends. Either way it must not
    // poll past its own deadline.
    task stalled_source(input [1:0] opst);
        integer t, pushes0, grants0, limit_end;
        reg [63:0] window_end;
        begin
            seed_opst = opst; deliver_after = -1;
            por(1, 1);
            pushes0 = rom_pushes; grants0 = all_grants;
            wr(7'h10, 1); wr(7'h30, 32'h10a50001);     // REQUEST
            wait_handover(600000, t);
            window_end = rom_deadline;                 // written before the first poll, and not cleared by this ROM
            check(idle_polls > 1 && poll_gaps == idle_polls - 1, "the ROM polled seed, and nothing else between two polls");
            check(rom_pushes == pushes0 && all_grants == grants0 && !dut.auth.auth_unlock_q, "no challenge word and no grant without a nonce");
            check(window_end > idle_first && window_end - idle_first <= 64'd400000, "ROM deadline variable located");
            check(idle_last < window_end + SLACK, "no poll of seed after the deadline");
            limit_end = (trng_tries + 1) * poll_max;   // clocks that the polls of the per-word limit take, at most
            $display("seed %s forever: %0d polls of %0d to %0d clocks, the last %0d clocks before the deadline; TRNG_TRIES %0d",
                     opst == 0 ? "BIST" : "WAIT", idle_polls, poll_min, poll_max, window_end - idle_last, trng_tries);
            if (trng_tries != 0 && limit_end + 2000 < 400000) begin
                check(idle_polls == trng_tries + 1, $sformatf("the per-word limit ended the wait: %0d polls, TRNG_TRIES + 1 is %0d", idle_polls, trng_tries + 1));
                check(window_end - idle_last > 64'd2000, "and it ended well before the window did");
            end else begin
                check(trng_tries == 0 || idle_polls <= trng_tries, "the per-word limit is beyond this window: fewer polls than it allows");
                check(window_end - idle_last <= 2 * poll_max, "the deadline ended the wait: the ROM polled until its window was over");
            end
            repeat (200) @(negedge clk);
            check(dut.auth.boot_done_q, "the window is closed in hardware");
            expect_locked("locked after a window without a nonce", 2000);
            seed_opst = 2'd2;
        end
    endtask
    // The first nonce word comes after `idle` polls without one. Up to
    // TRNG_TRIES such polls are within the limit: the ROM makes its
    // challenge and a correct response unlocks. One more is given up on.
    task slow_source(input integer idle, input bit in_time);
        integer t, pushes0;
        begin
            seed_opst = 2'd1; deliver_after = idle;
            por(1, 1);
            pushes0 = rom_pushes;
            wr(7'h10, 1); wr(7'h30, 32'h10a50001);
            if (in_time) begin
                recv_challenge;
                check(idle_polls == idle, $sformatf("%0d polls without a word, then sixteen words: within the limit", idle));
                send_response(32'h02018000, 32'h00010020, 8'h01, 0);
                poll_authenticated(1, 20000);
                check(value[7], "a source that delivers on the last poll the limit allows: the response unlocks");
            end else begin
                wait_handover(600000, t);
                check(idle_polls == idle && rom_pushes == pushes0, $sformatf("%0d polls without a word: given up, no challenge", idle));
                expect_locked("locked after the ROM gave up on the source", 2000);
            end
            seed_opst = 2'd2; deliver_after = -1;
        end
    endtask
    task stall_cases;
        begin
            void'($value$plusargs("trng_tries=%d", trng_tries));
            void'($value$plusargs("poll_clocks=%d", poll_clocks));
            void'($value$plusargs("poll_clocks_max=%d", poll_clocks_max));
            stalled_source(2'd1);
            stalled_source(2'd0);
            // a dead source ends the wait at once
            seed_opst = 2'd3; por(1, 1);
            wr(7'h10, 1); wr(7'h30, 32'h10a50001);
            begin : dead
                integer t, pushes0;
                pushes0 = rom_pushes;
                wait_handover(40000, t);
                check(idle_polls == 1 && rom_pushes == pushes0, "a source that reports DEAD: one poll, no challenge");
            end
            seed_opst = 2'd2;
            if (poll_clocks != 0)
                check(poll_min >= poll_clocks && poll_max <= poll_clocks_max,
                      $sformatf("one poll takes %0d to %0d clocks here; window.c assumes %0d to %0d", poll_min, poll_max, poll_clocks, poll_clocks_max));
            if (trng_tries != 0 && (trng_tries + 2) * poll_max + 2000 < 400000) begin
                slow_source(trng_tries, 1);
                slow_source(trng_tries + 1, 0);
            end
            $display("seed polling: one poll of make_nonce() takes %0d to %0d clocks (%0d measured); TRNG_TRIES %0d",
                     poll_min, poll_max, poll_total, trng_tries);
        end
    endtask
`endif
`endif

    initial begin
`ifdef AUTH_WINDOW_NO_SEED
        noseed_case(1);
        noseed_case(0);
        $display("karudbg auth window ROM without seed: PASS (%0d checks)", checks);
        $finish;
`else
`ifndef AUTH_WINDOW_ENTROPY_SRC
        if ($test$plusargs("stall_only")) begin
            stall_cases;
            $display("karudbg auth window ROM, seed polling limit: PASS (%0d checks)", checks);
            $finish;
        end
`endif
`endif
        // ---- correct TEST response unlocks ----
        por(1, 1);
        wr(7'h10, 1);
        wr(7'h30, 32'h10a50001);                       // REQUEST, permission bit 0
        recv_challenge;
        send_response(32'h02018000, 32'h00010020, 8'h01, 0);
        poll_authenticated(1, 20000);
        check(value[7], "correct TEST response unlocks");
        wr(7'h10, 32'h80000001);
        wait_parked;
        for (integer k = 0; k < 20; k = k + 1) old_chal[k] = chal[k];

        // ---- replay: the previous session's response fails on a fresh nonce ----
        por(1, 1); wr(7'h10, 1); wr(7'h30, 32'h10a50001); recv_challenge;
        begin : replay
            reg differs;
            differs = 0;
            for (integer k = 10; k < 18; k = k + 1) if (chal[k] != old_chal[k]) differs = 1;
            check(differs, "each window draws a fresh nonce");
            for (integer k = 0; k < 20; k = k + 1) chal[k] = old_chal[k];
        end
        send_response(32'h02018000, 32'h00010020, 8'h01, 0);
        expect_locked("replayed response stays locked", 5000);

        // ---- rejections: each leaves the part locked and the window closed ----
        por(1, 1); wr(7'h10, 1); wr(7'h30, 32'h10a50001); recv_challenge;
        send_response(32'h02018000, 32'h00010020, 8'h01, 1);
        expect_locked("wrong signature stays locked", 5000);
        rd(7'h30, value); check(value[23:21] == 3, "window closed after a rejected response");
        por(1, 1); wr(7'h10, 1); wr(7'h30, 32'h10a50001); recv_challenge;
        send_response(32'h02010100, 32'h00010020, 8'h01, 0);   // algorithm 0x01
        expect_locked("unaccepted algorithm stays locked", 5000);
        por(1, 1); wr(7'h10, 1); wr(7'h30, 32'h10a50001); recv_challenge;
        send_response(32'h02018000, 32'h00010040, 8'h01, 0);   // length 64
        expect_locked("wrong signature length stays locked", 5000);
        por(1, 1); wr(7'h10, 1); wr(7'h30, 32'h10a50001); recv_challenge;
        send_response(32'h02018000, 32'h00020020, 8'h02, 0);   // granted outside request
        expect_locked("granted mask outside the request stays locked", 5000);

        // ---- session reset before the response: the ROM re-pushes ----
        por(1, 1); wr(7'h10, 1); wr(7'h30, 32'h10a50001);
        poll_status_tx(4);
        wr(7'h30, 32'h30000002); rd(7'h30, value); rd(7'h30, value);   // partial read
        wr(7'h30, 32'hf0000000);                       // ABORT
        recv_challenge;
        send_response(32'h02018000, 32'h00010020, 8'h01, 0);
        poll_authenticated(1, 20000);
        check(value[7], "re-pushed challenge after ABORT still authenticates");

        // ---- silence: the bounded window closes ----
        por(1, 1); wr(7'h10, 1); wr(7'h30, 32'h10a50001); recv_challenge;
        repeat (450000) @(negedge clk);
        rd(7'h30, value); check(value[23:21] == 3, "window closes after WINDOW_CYCLES");
        send_response(32'h02018000, 32'h00010020, 8'h01, 0);
        expect_locked("late response stays locked", 5000);

        // ---- responses that straddle the deadline (review 2026-11-16) ----
        // The response starts `lead` cycles before the deadline. The ROM
        // needs roughly 6000 cycles to pop ten words and decide, so the
        // middle leads end on either side of the deadline. In time it
        // unlocks; started after the deadline it must not; in between
        // either, but never late.
        begin : boundary
            integer lead [0:7];
            integer n, g0, unlocked_early, unlocked_any;
            lead[0] = 40000; lead[1] = 12000; lead[2] = 8000; lead[3] = 6500;
            lead[4] = 5000; lead[5] = 3000; lead[6] = 1000; lead[7] = -500;
            unlocked_early = 0; unlocked_any = 0;
            for (n = 0; n < 8; n = n + 1) begin
                por(1, 1); open_window; recv_challenge;
                g0 = grants;
                $display("boundary lead %0d: deadline in %0d cycles", lead[n], rom_deadline - mcycle);
                wait_mcycle(rom_deadline - {{32{lead[n][31]}}, lead[n]});
                send_response(32'h02018000, 32'h00010020, 8'h01, 0);
                repeat (20000) @(negedge clk);
                rd(7'h11, value);
                check(late_grants == 0, $sformatf("no grant after the deadline (lead %0d)", lead[n]));
                check(late_pops == 0, $sformatf("no response word popped after the deadline (lead %0d)", lead[n]));
                check(value[7] == (grants != g0), "authenticated matches the observed grant");
                if (n == 0) begin check(value[7], "response well before the deadline unlocks"); unlocked_early = 1; end
                if (lead[n] < 0) check(!value[7], "response started after the deadline stays locked");
                if (value[7]) unlocked_any = unlocked_any + 1;
                $display("boundary lead %0d: authenticated=%0d", lead[n], value[7]);
                rd(7'h30, value);
                check(value[23:21] == 3, $sformatf("window closed after the decision (lead %0d)", lead[n]));
            end
            check(unlocked_early == 1 && unlocked_any < 8, "boundary sweep saw both outcomes");
            $display("boundary sweep: %0d of 8 leads unlocked", unlocked_any);
        end

        // ---- a word split across the deadline: nine words early, one late ----
        por(1, 1); open_window; recv_challenge;
        wr(7'h30, 32'h2000000a); wr(7'h30, 32'h02018000); wr(7'h30, 32'h00010020);
        for (integer k = 0; k < 7; k = k + 1) wr(7'h30, test_sig(k, 8'h01));
        wait_mcycle(rom_deadline + 1);
        wr(7'h30, test_sig(7, 8'h01));
        expect_locked("last response word after the deadline stays locked", 20000);
        check(late_grants == 0 && late_pops == 0, "no late pop or grant for the split response");

        // ---- repeated ABORTs cannot hold the window open ----
        por(1, 1); open_window;
        while (mcycle < rom_deadline + 3000) wr(7'h30, 32'hf0000000);
        rd(7'h30, value);
        check(value[23:21] == 3, "window closed at the deadline under repeated ABORTs");
        expect_locked("repeated ABORTs leave the part locked", 2000);
        check(late_grants == 0 && late_pops == 0, "no late pop or grant under repeated ABORTs");

        check(seed_words >= 16 && seed_words % 16 == 0,
              "every nonce came from seed, sixteen words each");
`ifndef AUTH_WINDOW_ENTROPY_SRC
`ifndef AUTH_WINDOW_NO_SEED
        // ---- a source that does not deliver ----
        stall_cases;
`endif
`endif
`ifdef AUTH_WINDOW_ENTROPY_SRC
        $display("nonce source: seed, the entropy source, %0d words", seed_words);
`else
        $display("nonce source: seed, the bench's words, %0d words", seed_words);
`endif
        $display("karudbg auth window ROM: PASS (%0d checks)", checks);
        $finish;
    end
    initial begin #400000000; $fatal(1, "auth window: global timeout"); end
endmodule
