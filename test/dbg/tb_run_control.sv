// Run-control legality on the real karudbg_core (karu64 + DM + ROM), driven
// only through DMI with no forced state. Sdext's NOP conversions must not
// override ISA legality: a stepped WFI keeps its TW/VTW/U-mode traps in M, S,
// U, VS and VU (security review 2026-11-15 S11), and only SYSTEM-opcode WRS
// may skip the FENCE ordering handshake when stepped or in the Program
// Buffer (S12). Every case is checked; any mismatch is fatal.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karudbg_defs.vh"
`include "rtl/karu_assert.sv"
module tb_run_control;
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
    karudbg_core dut (.*);
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
    localparam [63:0] PB0 = {32'b0, `KARUDBG_BASE} + {52'b0, `KARUDBG_PROGBUF};
    integer resume_count = 0, cases = 0;
    // Registered platform completion, one cycle after each request.
    always @(posedge clk) cache_flush_done <= cache_flush_req && !rst;
    always @(posedge clk) if (debug_resume_ack_o) resume_count <= resume_count + 1;

    // S12 observation: did the instruction at probe_pc request the platform
    // FENCE handshake (cache_flush_req) in the cycle it issued?
    reg [63:0] probe_pc = 64'hffff_ffff_ffff_ffff;
    reg probe_issued = 0, probe_flush = 0;
    always @(posedge clk) if (!rst && dut.core.issuing && dut.core.ex_pc == probe_pc) begin
        probe_issued <= 1;
        if (cache_flush_req) probe_flush <= 1;
    end

    task fail(input string m); begin $fatal(1, "run-control: %s", m); end endtask
    task dmi(input [1:0] op, input [6:0] addr, input [31:0] data, output [31:0] result);
        integer t;
        begin
            @(negedge clk);
            dmi_req_valid_i = 1; dmi_req_addr_i = addr; dmi_req_op_i = op; dmi_req_data_i = data;
            t = 0; while (!dmi_req_ready_o && t < 100) begin @(negedge clk); t = t + 1; end
            if (!dmi_req_ready_o) fail("DMI request timeout");
            @(posedge clk); #1; @(negedge clk); dmi_req_valid_i = 0;
            t = 0; while (!dmi_resp_valid_o && t < 100) begin @(negedge clk); t = t + 1; end
            if (!dmi_resp_valid_o || dmi_resp_op_o != 0) fail("DMI response timeout/error");
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
            if (t == 20000) fail("hart did not park in Debug Mode");
        end
    endtask
    task command(input [31:0] word, input [2:0] err);
        integer t; reg [31:0] s;
        begin
            wr(7'h17, word);
            t = 0; s = 32'h1000;
            while (s[12] && t < 5000) begin rd(7'h16, s); t = t + 1; end
            if (s[12] || s[10:8] != err) fail($sformatf("command %08x abstractcs=%08x", word, s));
            if (err) wr(7'h16, 32'h700);
        end
    endtask
    task read_reg(input [15:0] regno, output [63:0] v);
        reg [31:0] lo, hi;
        begin command(32'h00320000 | {16'b0, regno}, 0); rd(7'h04, lo); rd(7'h05, hi); v = {hi, lo}; end
    endtask
    task write_reg(input [15:0] regno, input [63:0] v);
        begin wr(7'h04, v[31:0]); wr(7'h05, v[63:32]); command(32'h00330000 | {16'b0, regno}, 0); end
    endtask
    task resume_and_park;
        integer prev, t;
        begin
            prev = resume_count;
            wr(7'h10, 32'h40000001);
            t = 0; while (resume_count == prev && t < 20000) begin @(negedge clk); t = t + 1; end
            if (resume_count != prev + 1) fail("resume not acknowledged by the core");
            wait_parked;
        end
    endtask
    // Hostile fabric at the external-to-debug-page transition, where the
    // channel's previous transaction was external: inject an external R beat
    // while the hart presents a debug-page data load right after an external
    // load (mode 1), or the first debug-ROM fetch at Debug Mode entry from
    // running code (mode 2). The router must never let it complete the
    // debug-page request.
    integer inject_mode = 0, injected = 0;
    always @(negedge clk) begin
        if (injected == 0 &&
            ((inject_mode == 1 && dut.c_dmem_arvalid && dut.c_dmem_araddr == 32'h0012_0380) ||
             (inject_mode == 2 && dut.c_imem_arvalid &&
              dut.c_imem_araddr >= 32'h0012_0800 && dut.c_imem_araddr < 32'h0012_0900))) begin
            injected = 1;
            if (inject_mode == 1) begin inj_data = 64'hbad0_bad0_bad0_bad0; inj_d = 1; end
            else begin inj_data = {2{32'h66600293}}; inj_i = 1; end      // addi t0, zero, 0x666
            repeat (3) @(negedge clk);
            inj_i = 0; inj_d = 0;
        end
    end
    task forged_debug_load(input string name);
        reg [63:0] v;
        begin
            write_reg(16'h1007, RAM + 'h400);            // t2: external address
            write_reg(16'h1009, 64'h0012_0380);          // s1: debug-page data0
            wr(7'h20, 32'h0003b303);                     // ld t1, 0(t2)  (external)
            wr(7'h21, 32'h0004b283);                     // ld t0, 0(s1)  (debug page)
            wr(7'h22, 32'h00100073);                     // ebreak
            wr(7'h04, 32'h33334444); wr(7'h05, 32'h11112222);
            injected = 0; inject_mode = 1;
            command(32'h00040000, 0);                    // postexec only
            inject_mode = 0;
            if (injected != 1) fail($sformatf("%s: injection did not fire", name));
            read_reg(16'h1005, v);
            if (v != 64'h1111_2222_3333_4444)
                fail($sformatf("%s: forged debug-page response reached the hart (t0=%h)", name, v));
            ok(name, "injected external beat ignored after an external load");
        end
    endtask
    task forged_debug_fetch(input string name);
        reg [63:0] v;
        begin
            memory.put_insn('h300, 32'h0000006f);        // j .
            write_reg(16'h1005, 64'h1234);
            write_reg(16'h07b1, RAM + 'h300);
            write_reg(16'h07b0, 64'h3);                  // prv=M, no step
            wr(7'h10, 32'h40000001);                     // resume into RAM code
            repeat (200) @(negedge clk);
            injected = 0; inject_mode = 2;
            wr(7'h10, 32'h80000001);                     // halt: entry fetches debug ROM
            wait_parked;
            inject_mode = 0;
            wr(7'h10, 32'h00000001);
            if (injected != 1) fail($sformatf("%s: injection did not fire", name));
            read_reg(16'h1005, v);
            if (v != 64'h1234)
                fail($sformatf("%s: forged debug-page response reached the hart (t0=%h)", name, v));
            ok(name, "injected external beat ignored at Debug Mode entry");
        end
    endtask
    task ok(input string name, input string detail);
        begin cases = cases + 1; $display("CASE %s PASS %s", name, detail); end
    endtask

    localparam [63:0] WFI_PC = RAM + 'h30, MTVEC = RAM + 'h100;
    reg [63:0] mst;                           // mstatus after the case
    localparam [63:0] TW = 64'h200000, VTW = 64'h200000;
    // Prepare mstatus.TW, hstatus.VTW and the trap CSRs, then resume at the
    // WFI in mode {v, prv} with dcsr.step (or ebreakm, unstepped).
    task wfi_run(input [1:0] prv, input bit v, input bit tw, input bit vtw,
                 input bit step, output [63:0] dpc, output [63:0] mcause,
                 output [63:0] mepc, output [63:0] dcsr);
        reg [63:0] st, hst;
        begin
            read_reg(16'h0300, st);
            write_reg(16'h0300, tw ? (st | TW) : (st & ~TW));
`ifdef KARU_EN_H
            read_reg(16'h0600, hst);
            write_reg(16'h0600, vtw ? (hst | VTW) : (hst & ~VTW));
`else
            hst = 0;
            if (v || vtw) fail("virtual-mode case without KARU_EN_H");
`endif
            write_reg(16'h0341, 0); write_reg(16'h0342, 0);
            write_reg(16'h07b1, WFI_PC);
            write_reg(16'h07b0, step ? {58'b0, v, 3'b001, prv} :
                                       ({48'b0, 16'h8000} | {58'b0, v, 3'b0, prv}));
            resume_and_park;
            read_reg(16'h07b1, dpc); read_reg(16'h0342, mcause);
            read_reg(16'h0341, mepc); read_reg(16'h07b0, dcsr);
            read_reg(16'h0300, mst);
            write_reg(16'h0300, st);
`ifdef KARU_EN_H
            write_reg(16'h0600, hst);
`endif
        end
    endtask
    // A denied WFI traps with the given cause. Stepped, Debug Mode is
    // re-entered at mtvec with cause=step before any handler instruction;
    // unstepped, the handler's EBREAK re-enters through dcsr.ebreakm.
    task wfi_traps(input string name, input [1:0] prv, input bit v, input bit tw,
                   input bit vtw, input bit step, input [63:0] cause);
        reg [63:0] dpc, mcause, mepc, dcsr;
        begin
            wfi_run(prv, v, tw, vtw, step, dpc, mcause, mepc, dcsr);
            if (dcsr[8:6] != (step ? 3'd4 : 3'd1) || dpc != MTVEC || mcause != cause ||
                mepc != WFI_PC || dcsr[5] != 0 || dcsr[1:0] != 2'd3 ||
                mst[12:11] != prv || mst[39] != v)
                fail($sformatf("%s: dpc=%h mcause=%0d mepc=%h dcsr=%h mstatus=%h (expected dpc=%h mcause=%0d)",
                     name, dpc, mcause, mepc, dcsr, mst, MTVEC, cause));
            ok(name, $sformatf("WFI trapped, mcause=%0d", cause));
        end
    endtask
    // A permitted stepped WFI completes as a NOP: one step, no trap.
    task wfi_nop(input string name, input [1:0] prv, input bit v, input bit tw, input bit vtw);
        reg [63:0] dpc, mcause, mepc, dcsr;
        begin
            wfi_run(prv, v, tw, vtw, 1'b1, dpc, mcause, mepc, dcsr);
            if (dcsr[8:6] != 3'd4 || dpc != WFI_PC + 4 || mcause != 0 ||
                dcsr[5] != v || dcsr[1:0] != prv)
                fail($sformatf("%s: dpc=%h mcause=%0d dcsr=%h (expected step to %h)",
                     name, dpc, mcause, dcsr, WFI_PC + 4));
            ok(name, "permitted stepped WFI retired as a NOP");
        end
    endtask

    // Only SYSTEM-opcode WRS may bypass the FENCE handshake; a FENCE whose
    // imm12 equals a WRS encoding must still request it.
    task check_fence(input string name, input [31:0] insn, input bit ran, input string d);
        begin
            if (!ran) fail($sformatf("%s: %08x did not execute as expected (%s)", name, insn, d));
            if (!probe_flush) fail($sformatf("%s: %08x skipped the FENCE handshake (%s)", name, insn, d));
            ok(name, $sformatf("%08x requested the FENCE handshake (%s)", insn, d));
        end
    endtask
    task stepped_fence(input string name, input [31:0] insn, input integer off);
        reg [63:0] dpc, dcsr;
        begin
            memory.put_insn(off, insn); memory.put_insn(off + 4, 32'h00000013);
            write_reg(16'h07b1, RAM + off);
            write_reg(16'h07b0, 64'h7);                        // prv=M, step=1
            probe_pc = RAM + off; probe_issued = 0; probe_flush = 0;
            resume_and_park;
            probe_pc = '1;
            read_reg(16'h07b1, dpc); read_reg(16'h07b0, dcsr);
            check_fence(name, insn, probe_issued && dcsr[8:6] == 4 && dpc == RAM + off + 4,
                        $sformatf("stepped, dpc=%h", dpc));
        end
    endtask
    task progbuf_fence(input string name, input [31:0] insn);
        begin
            wr(7'h20, insn); wr(7'h21, 32'h00100073);          // fence; ebreak
            probe_pc = PB0; probe_issued = 0; probe_flush = 0;
            command(32'h00040000, 0);                          // postexec only
            probe_pc = '1;
            check_fence(name, insn, probe_issued, "Program Buffer");
        end
    endtask

    // INV40/INV41 observe the same core, so a legality bypass also fails
    // the independent invariant at the issuing edge.
    `include "test/dbg/trigger_checker.vh"

    initial begin
        #1; memory.clear_ram();
        memory.put_insn('h30, 32'h10500073);   // wfi
        memory.put_insn('h34, 32'h00000013);
        memory.put_insn('h100, 32'h00100073);  // M trap handler: ebreak
        hart_reset_i = 1;
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        wr(7'h10, 1); wr(7'h10, 32'h80000001); // haltreq held across hart reset
        @(negedge clk); hart_reset_i = 0;
        wait_parked;
        wr(7'h10, 32'h00000001);
        write_reg(16'h0305, MTVEC);            // mtvec, direct; no delegation
        //        name                        prv   v  tw vtw step cause
        wfi_traps("U_WFI_UNSTEPPED",          2'd0, 0, 0, 0, 0, 2);
        wfi_traps("U_WFI_STEPPED",            2'd0, 0, 0, 0, 1, 2);
        wfi_traps("U_TW_WFI_STEPPED",         2'd0, 0, 1, 0, 1, 2);
        wfi_nop  ("M_TW_WFI_STEPPED",         2'd3, 0, 1, 0);
`ifdef KARU_EN_S
        wfi_traps("S_TW_WFI_UNSTEPPED",       2'd1, 0, 1, 0, 0, 2);
        wfi_traps("S_TW_WFI_STEPPED",         2'd1, 0, 1, 0, 1, 2);
        wfi_nop  ("S_WFI_STEPPED",            2'd1, 0, 0, 0);
`endif
`ifdef KARU_EN_H
        wfi_traps("VS_VTW_WFI_UNSTEPPED",     2'd1, 1, 0, 1, 0, 22);
        wfi_traps("VS_VTW_WFI_STEPPED",       2'd1, 1, 0, 1, 1, 22);
        wfi_traps("VS_TW_WFI_STEPPED",        2'd1, 1, 1, 0, 1, 2);
        wfi_nop  ("VS_WFI_STEPPED",           2'd1, 1, 0, 0);
        wfi_traps("VU_WFI_UNSTEPPED",         2'd0, 1, 0, 0, 0, 22);
        wfi_traps("VU_WFI_STEPPED",           2'd0, 1, 0, 0, 1, 22);
        wfi_traps("VU_VTW_WFI_STEPPED",       2'd0, 1, 0, 1, 1, 22);
        wfi_traps("VU_TW_WFI_STEPPED",        2'd0, 1, 1, 0, 1, 2);
`endif
        forged_debug_load("DEBUG_PAGE_FORGED_LOAD");
        forged_debug_fetch("DEBUG_PAGE_FORGED_FETCH");
        stepped_fence("FENCE_RW_RW_STEPPED",  32'h0330000f, 'h200);
        stepped_fence("FENCE_W_IOW_STEPPED",  32'h01d0000f, 'h210);
        stepped_fence("FENCE_0_IOW_STEPPED",  32'h00d0000f, 'h220);
        progbuf_fence("FENCE_RW_RW_PROGBUF",  32'h0330000f);
        progbuf_fence("FENCE_W_IOW_PROGBUF",  32'h01d0000f);
        progbuf_fence("FENCE_0_IOW_PROGBUF",  32'h00d0000f);
        $display("karudbg run-control legality: PASS (%0d cases)", cases);
        $finish;
    end
    initial begin #20000000; $fatal(1, "run-control: global timeout"); end
endmodule
