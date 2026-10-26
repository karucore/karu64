// Actual Karu core + execution-based DM integration tests; no forced state.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karudbg_defs.vh"
module tb_dbg_core;
`ifdef TEST_AW_WAIT_WVALID
    localparam AW_WAIT_WVALID = 1;
`else
    localparam AW_WAIT_WVALID = 0;
`endif
    reg  clk = 0;
    reg  rst = 1;
    wire  debug_mode_o;
    wire  debug_resume_ack_o;
    wire  trap;
    reg  irq = 0;
    reg  irq_software = 0;
    reg  irq_external_m = 0;
    reg  irq_external_s = 0;
    reg [63:0] time_in = 0;
    reg [31:0] uncache_page = 0;
    reg [31:0] hpm_events = 0;
    wire  cache_flush_req;
    wire  cache_flush_invalidate;
    reg  cache_flush_done = 0;
    wire [`AXI_ID_W-1:0] imem_arid;
    wire [`AXI_ADDR_W-1:0] imem_araddr;
    wire [`AXI_LEN_W-1:0] imem_arlen;
    wire [`AXI_SIZE_W-1:0] imem_arsize;
    wire [`AXI_BURST_W-1:0] imem_arburst;
    wire [`AXI_PROT_W-1:0] imem_arprot;
    wire  imem_arvalid;
    wire  imem_arready;
    wire [`AXI_ID_W-1:0] imem_rid;
    wire [`AXI_DATA_W-1:0] imem_rdata;
    wire [`AXI_RESP_W-1:0] imem_rresp;
    wire  imem_rlast;
    wire  imem_rvalid;
    wire  imem_rready;
    wire [`AXI_ID_W-1:0] dmem_arid;
    wire [`AXI_ADDR_W-1:0] dmem_araddr;
    wire [`AXI_LEN_W-1:0] dmem_arlen;
    wire [`AXI_SIZE_W-1:0] dmem_arsize;
    wire [`AXI_BURST_W-1:0] dmem_arburst;
    wire [`AXI_PROT_W-1:0] dmem_arprot;
    wire  dmem_arvalid;
    wire  dmem_arready;
    wire [`AXI_ID_W-1:0] dmem_rid;
    wire [`AXI_DATA_W-1:0] dmem_rdata;
    wire [`AXI_RESP_W-1:0] dmem_rresp;
    wire  dmem_rlast;
    wire  dmem_rvalid;
    wire  dmem_rready;
    wire [`AXI_ID_W-1:0] dmem_awid;
    wire [`AXI_ADDR_W-1:0] dmem_awaddr;
    wire [`AXI_LEN_W-1:0] dmem_awlen;
    wire [`AXI_SIZE_W-1:0] dmem_awsize;
    wire [`AXI_BURST_W-1:0] dmem_awburst;
    wire [`AXI_PROT_W-1:0] dmem_awprot;
    wire  dmem_awvalid;
    wire  dmem_awready;
    wire [`AXI_DATA_W-1:0] dmem_wdata;
    wire [`AXI_STRB_W-1:0] dmem_wstrb;
    wire  dmem_wlast;
    wire  dmem_wvalid;
    wire  dmem_wready;
    wire [`AXI_ID_W-1:0] dmem_bid;
    wire [`AXI_RESP_W-1:0] dmem_bresp;
    wire  dmem_bvalid;
    wire  dmem_bready;
    reg  hart_reset_i = 0;
    reg  dmi_reset_i = 0;
    reg  dmi_req_valid_i = 0;
    wire  dmi_req_ready_o;
    reg [6:0] dmi_req_addr_i = 0;
    reg [1:0] dmi_req_op_i = 0;
    reg [31:0] dmi_req_data_i = 0;
    wire  dmi_resp_valid_o;
    reg  dmi_resp_ready_i = 0;
    wire [31:0] dmi_resp_data_o;
    wire [1:0] dmi_resp_op_o;
    wire  ndmreset_o;
    always #5 clk = !clk;
    karudbg_core dut (.*);
    integer cycle = 0;
    integer checks = 0, normal_retired = 0, resume_count = 0;
    wire [31:0] mmio_reads, mmio_writes;
    wire [63:0] mmio_value;
    karudbg_test_ram #(.AW_WAIT_WVALID(AW_WAIT_WVALID)) memory (.*, .fifo_count());
    integer k;
    reg [63:0] got, old_cycle, old_hpm;
    reg [63:0] expected_gpr [0:31];
    reg [63:0] canary_s0, canary_a0, saved_mepc, saved_mcause, saved_mtval;
    reg [31:0] value;
    integer before_count;
    integer wrs_nop_count = 0;
    string phase = "startup";
    reg [63:0] keccak_expected [0:24];

    task put_insn(input integer offset, input [31:0] insn);
        begin memory.put_insn(offset, insn); end
    endtask

    task pointer_mask_debug;
        reg [63:0] menv, senv;
`ifdef KARU_EN_H
        reg [63:0] henv, hstatus;
`endif
        integer reads_before;
        begin
`ifdef KARU_EN_S
            read_reg(16'h030a, menv); read_reg(16'h010a, senv);
            write_reg(16'h030a, menv | 64'h0000000300000000);
            write_reg(16'h010a, senv | 64'h0000000300000000);
`ifdef KARU_EN_H
            read_reg(16'h060a, henv); read_reg(16'h0600, hstatus);
            write_reg(16'h060a, henv | 64'h0000000300000000);
            write_reg(16'h0600, hstatus | 64'h0003000000000000);
`endif
            context_step(1, 0);
`ifdef KARU_EN_H
            context_step(1, 1); context_step(0, 1);
`endif
            // Correct physical debug access does not strip a tag even though
            // the interrupted S/VS/VU pointer-masking controls are nonzero.
            write_reg(16'h100b, 64'habcd000010000000);
            reads_before = mmio_reads;
            pb(0, 32'h0005a603); pb(1, 32'h00100073); execute_pb(3);
            check(mmio_reads == reads_before, "debug physical access ignores PMM tag stripping");
            write_reg(16'h100b, 64'h10000000); execute_pb(0);
            check(mmio_reads == reads_before + 1, "untagged physical MMIO still works with PMM set");
            check_hmetadata;
            write_reg(16'h030a, menv); write_reg(16'h010a, senv);
`ifdef KARU_EN_H
            write_reg(16'h060a, henv); write_reg(16'h0600, hstatus);
`endif
            write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80000000);
            check_saved;
`endif
        end
    endtask

    task check_hmetadata;
        begin
`ifdef KARU_EN_H
            expect_reg(16'h0643, 64'h123456789abcd);
            expect_reg(16'h064a, 64'h3000);
            expect_reg(16'h034a, 64'h5000);
            expect_reg(16'h034b, 64'hdeadbeef);
`endif
        end
    endtask

    task compressed_debug;
        reg [63:0] dcsr;
        begin
`ifdef KARU_EN_C
            write_reg(16'h07b1, 64'h80000090);
            write_reg(16'h07b0, 64'h8003);
            resume_hart; wait_parked;
            read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 1, "normal C.EBREAK debug cause");
            expect_reg(16'h07b1, 64'h80000090);
            step_at(64'h80000092, 64'h80000094); // C.NOP advances two bytes
            write_reg(16'h07b1, 64'h80000000);
            pb(0, 32'h00019002); execute_pb(0); // C.EBREAK; C.NOP
            check_saved;
`endif
        end
    endtask

    task halt_long(input integer operation, input [63:0] pc);
        integer timeout, retired_before;
        reg [63:0] dcsr, status;
        begin
            write_reg(16'h100f, 64'h55aa);
            write_reg(16'h07b0, 3); write_reg(16'h07b1, pc);
            retired_before = normal_retired;
            resume_hart;
            timeout = 0;
            while ((debug_mode_o ||
                    !((operation == 0 && dut.core.fpu_active) ||
                      (operation == 1 && dut.core.varith_active) ||
                      (operation == 2 && dut.core.lsu_active) ||
                      (operation == 3 && dut.core.vlsu_active))) && timeout < 2000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 2000, "observed active normal long instruction");
            irq = 1; // enabled MTIP and halt both pending when the FU drains
            wr(7'h10, 32'h80000001);
            if (operation == 0) begin
                // Clearing haltreq may cancel an unobserved request. Karu
                // retains one it has already latched, even after withdrawal.
                check(dut.core.dbg_halt_pending && dut.core.fpu_active && !debug_mode_o,
                      "halt request latched before long FP operation completes");
                wr(7'h10, 1);
                check(!dut.halt_req && dut.core.dbg_halt_pending,
                      "observed halt request survives debugger withdrawal");
            end
            wait_parked;
            expect_reg(16'h07b1, pc + 4);
            expect_reg(16'h100f, 64'h55aa); // following ADDI did not execute
            check(normal_retired == retired_before + 1,
                  "halt drains exactly the older long instruction");
            check(!memory.w_active && !dmem_bvalid && !dut.core.mem_store_pending,
                  "debug entry drains outstanding posted writes and responses");
            read_reg(16'h07b0, dcsr); check(dcsr[8:6] == 3, "long-operation halt cause");
            read_reg(16'h0344, status); check(status[7], "pending MTIP survives debug entry");
            expect_reg(16'h0341, saved_mepc); expect_reg(16'h0342, saved_mcause);
            expect_reg(16'h0343, saved_mtval); check_hmetadata;
            irq = 0;
        end
    endtask

    task long_instruction_halts;
        integer n, byte_index;
        reg [63:0] original_status, original_ie, actual;
        begin
            read_reg(16'h0300, original_status); read_reg(16'h0304, original_ie);
            write_reg(16'h0300, original_status | 64'h6608); // FS/VS dirty, MIE
            write_reg(16'h0304, original_ie | 64'h80);
`ifdef KARU_EN_D
            write_reg(16'h100c, 64'h3ff8000000000000); // 1.5
            write_reg(16'h100d, 64'h3ff4000000000000); // 1.25
            pb(0, 32'hf2060053); pb(1, 32'hf20680d3); pb(2, 32'h00100073);
            execute_pb(0); // fmv.d.x f0,a2; fmv.d.x f1,a3
            halt_long(0, 64'h800000a0);
            pb(0, 32'he20106d3); pb(1, 32'h00100073); execute_pb(0);
            expect_reg(16'h100d, 64'h3ff3333333333333);
`endif
`ifdef KARU_KECCAK
            for (n = 0; n < 32; n = n + 1)
                for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                    memory.ram['h5000+n*8+byte_index] = 8'(64'(n) >> (byte_index*8));
            write_reg(16'h100b, 64'h80005000); write_reg(16'h100c, 32);
            pb(0, 32'he2858007); pb(1, 32'h01b67057); pb(2, 32'h00100073);
            execute_pb(0); // prepare e64,m8 group, then permute in normal mode
            halt_long(1, 64'h800000b0);
            write_reg(16'h100d, 64'h80005100);
            pb(0, 32'he2868027); pb(1, 32'h00100073); execute_pb(0);
            for (n = 0; n < 32; n = n + 1) begin
                actual = memory.ram_word(32'h80005100 + 32'(8*n));
                check(actual == (n < 25 ? keccak_expected[n] : 64'(n)),
                      "halted Keccak instruction completes exactly once");
            end
`endif
            write_reg(16'h100b, 64'h80000900);
            for (n = 0; n < 64; n = n + 1) memory.ram['h900+n] = 8'ha5;
            halt_long(2, 64'h800000c0);
            for (n = 0; n < 64; n = n + 1)
                check(memory.ram['h900+n] == 0, "CBO.ZERO fully completes before halt");
`ifdef KARU_EN_V
            for (n = 0; n < 256; n = n + 1)
                memory.ram['h5200+n] = 8'(n ^ (n >> 5) ^ 'h3c);
            write_reg(16'h100b, 64'h80005200);
            pb(0, 32'he2858007); pb(1, 32'h00100073); execute_pb(0);
            write_reg(16'h100d, 64'h80005400);
            halt_long(3, 64'h800000d0);
            for (n = 0; n < 256; n = n + 1)
                check(memory.ram['h5400+n] == 8'(n ^ (n >> 5) ^ 'h3c),
                      "whole-register posted store drains before halt");
`endif
            write_reg(16'h0304, original_ie); write_reg(16'h0300, original_status);
            write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80000000);
            check_saved;
        end
    endtask

    task exception_register_effects;
        reg [63:0] saved_a1, saved_a2, saved_a3;
        begin
            phase = "completed register effects before PB exception";
            read_reg(16'h100b, saved_a1); read_reg(16'h100c, saved_a2);
            read_reg(16'h100d, saved_a3);
            write_reg(16'h100b, 64'h13000000); // unmapped physical address
            pb(0, 32'h00940413); // addi s0,s0,9
            pb(1, 32'h00d50513); // addi a0,a0,13
            pb(2, 32'h0005a603); // faulting lw a2,0(a1)
            pb(3, 32'h00100073);
            execute_pb(3);
            expect_reg(16'h1008, canary_s0 + 9);
            expect_reg(16'h100a, canary_a0 + 13);
            expect_reg(16'h100c, saved_a2);
            write_reg(16'h1008, canary_s0); write_reg(16'h100a, canary_a0);
            check_saved;

            // The same rule applies to instructions outside the buffer.
            memory.put_insn('h2c0, 32'h01140413); // addi s0,s0,17
            memory.put_insn('h2c4, 32'h01350513); // addi a0,a0,19
            memory.put_insn('h2c8, 32'h0005a603);
            write_reg(16'h100d, 64'h800002c0);
            pb(0, 32'h00068067); // jalr zero,0(a3)
            execute_pb(3);
            expect_reg(16'h1008, canary_s0 + 17);
            expect_reg(16'h100a, canary_a0 + 19);
            write_reg(16'h1008, canary_s0); write_reg(16'h100a, canary_a0);
            check_saved;

            // A completed transfer must survive a later postexec fault.
            pb(0, 32'h0005a603); pb(1, 32'h00100073);
            wr(7'h04, 32'h89abcdef); wr(7'h05, 32'h01234567);
            command(32'h00371008, 3); // write s0, then execute PB
            expect_reg(16'h1008, 64'h0123456789abcdef);
            expect_reg(16'h100a, canary_a0);
            write_reg(16'h1008, canary_s0);
            wr(7'h04, 32'h87654321); wr(7'h05, 32'hfacebeef);
            command(32'h0037100a, 3); // write a0, then execute PB
            expect_reg(16'h100a, 64'hfacebeef87654321);
            expect_reg(16'h1008, canary_s0);
            write_reg(16'h100a, canary_a0);
            check_saved;

            // Faults in generated transfer code must hide its borrowed GPRs.
            command(32'h003207a0, 3); check_saved; // absent trigger CSR read
            wr(7'h04, 32'h76543210); wr(7'h05, 32'hfedcba98);
            command(32'h00330f11, 3); check_saved; // read-only mvendorid write
            write_reg(16'h100b, saved_a1); write_reg(16'h100c, saved_a2);
            write_reg(16'h100d, saved_a3);
            $display("karudbg exception register effects: PASS");
            phase = "context";
        end
    endtask

    task vector_fault_context;
        integer n;
        reg [63:0] status, old_vl, old_vtype, old_vstart;
        reg [63:0] saved_a1, saved_a2, saved_a3, actual;
        begin
`ifdef KARU_EN_V
            phase = "vector bus fault preserves permitted prefix effects";
            read_reg(16'h0300, status); write_reg(16'h0300, status | 64'h600);
            read_reg(16'h0c20, old_vl); read_reg(16'h0c21, old_vtype);
            read_reg(16'h0008, old_vstart);
            read_reg(16'h100b, saved_a1); read_reg(16'h100c, saved_a2);
            read_reg(16'h100d, saved_a3);
            for (n = 0; n < 4; n = n + 1)
                for (integer b = 0; b < 8; b = b + 1)
                    memory.ram['h6000 + n*8 + b] =
                        8'((64'hd00d000000000000 + 64'(n)) >> (8*b));
            for (n = 0; n < 8; n = n + 1)
                memory.ram['hfff8+n] = 8'(64'h0123456789abcdef >> (8*n));
            write_reg(16'h0008, 0); write_reg(16'h100b, 64'h80006000);
            pb(0, 32'h02858207); pb(1, 32'h00100073); execute_pb(0); // vl1re8 v4
            write_reg(16'h100c, 4);
            pb(0, 32'h01867057); pb(1, 32'h00100073); execute_pb(0); // e64,m1,vl=4
            // RAM slave rejects 0x80010000, after the first element succeeds.
            write_reg(16'h100b, 64'h8000fff8);
            pb(0, 32'h0205f207); pb(1, 32'h00100073); execute_pb(3); // vle64 v4
            // Sdext 4.1(4) explicitly permits partial vector/vstart updates.
            expect_reg(16'h0008, 1);
            expect_reg(16'h0c20, 4); expect_reg(16'h0c21, 24);
            check_saved;
            write_reg(16'h0008, 0); write_reg(16'h100d, 64'h80006040);
            pb(0, 32'h02868227); pb(1, 32'h00100073); execute_pb(0); // vs1r v4
            for (n = 0; n < 4; n = n + 1) begin
                actual = memory.ram_word(32'h80006040 + 32'(8*n));
                check(actual == (n == 0 ? 64'h0123456789abcdef :
                                          64'hd00d000000000000 + 64'(n)),
                      "fault preserves successful vector prefix and untouched suffix");
            end
            write_reg(16'h100c, old_vl); write_reg(16'h100d, old_vtype);
            pb(0, 32'h80d67057); pb(1, 32'h00100073); execute_pb(0); // restore vtype/vl
            write_reg(16'h0008, old_vstart);
            write_reg(16'h100b, saved_a1); write_reg(16'h100c, saved_a2);
            write_reg(16'h100d, saved_a3); write_reg(16'h0300, status);
            $display("karudbg vector fault prefix: PASS");
            phase = "context";
`endif
        end
    endtask

    task masked_vector_context;
        integer n;
        reg [31:0] word, expected;
        reg [63:0] pair;
        begin
`ifdef KARU_EN_V
            for (n = 0; n < 8; n = n + 1) begin
                memory.put_insn('h4000+4*n, 32'hdead0000 + 32'(n));
                memory.put_insn('h4020+4*n, 32'h10000000 + 32'(n));
                memory.put_insn('h4040+4*n, 32'h20000000 + 32'(n));
                memory.put_insn('h4060+4*n, n == 0 ? 5 : 0);
            end
            write_reg(16'h0008, 0);
            phase = "masked vector: load v4";
            write_reg(16'h100b, 64'h80004000);
            pb(0, 32'h02858207); pb(1, 32'h00100073); execute_pb(0); // load v4
            write_reg(16'h100b, 64'h80004020);
            phase = "masked vector: load v8";
            pb(0, 32'h02858407); execute_pb(0); // load v8
            write_reg(16'h100b, 64'h80004040);
            phase = "masked vector: load v12";
            pb(0, 32'h02858607); execute_pb(0); // load v12
            write_reg(16'h100b, 64'h80004060);
            phase = "masked vector: load mask";
            pb(0, 32'h02858007); execute_pb(0); // mask bits0,2
            write_reg(16'h100c, 3); write_reg(16'h100d, 64'h80004100);
            phase = "masked vector: vset/vadd/store";
            pb(0, 32'h01067057); pb(1, 32'h00860257); // e32,m1,tu,mu; vadd.vv masked
            pb(2, 32'h02868227); pb(3, 32'h00100073); execute_pb(0);
            for (n = 0; n < 8; n = n + 1) begin
                pair = memory.ram_word(32'h80004100 + 32'(4*n));
                word = n[0] ? pair[63:32] : pair[31:0];
                expected = n == 0 || n == 2 ? 32'h30000000+32'(2*n) : 32'hdead0000+32'(n);
                check(word == expected, "debug vector mask and tail undisturbed");
            end
            write_reg(16'h0008, 1); write_reg(16'h100d, 64'h80004140);
            phase = "masked vector: vstart=1 add/store";
            pb(0, 32'h0040b257); pb(1, 32'h02868227); pb(2, 32'h00100073);
            // Karu deliberately traps nonzero arithmetic vstart. Debug Mode
            // retains that ordinary instruction-state check (relaxedpriv=0).
            execute_pb(3);
            expect_reg(16'h0008, 1);
            write_reg(16'h0008, 0);
            pb(0, 32'h02868227); pb(1, 32'h00100073); execute_pb(0);
            for (n = 0; n < 8; n = n + 1) begin
                pair = memory.ram_word(32'h80004140 + 32'(4*n));
                word = n[0] ? pair[63:32] : pair[31:0];
                expected = n == 0 || n == 2 ? 32'h30000000+32'(2*n) : 32'hdead0000+32'(n);
                check(word == expected, "rejected vector restart preserves destination");
            end
            expect_reg(16'h0008, 0);
            expect_reg(16'h0c20, 3); expect_reg(16'h0c21, 16);
            phase = "context";
`endif
        end
    endtask
    task check(input bit condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) $fatal(1, "core check %0d cycle %0d: %s", checks, cycle, message);
        end
    endtask

    always @(posedge clk) begin
        cycle <= cycle + 1;
        // Completion is registered, as on the real cache-maintenance path.
        // A debug/stepped WRS must retire even while completion stays low.
        cache_flush_done <= cache_flush_req;
        if (!(rst || hart_reset_i || ndmreset_o)) begin
            if (dut.core.dbg_exception)
                $display("debug exception phase=%s pc=%016x insn=%08x vtype=%016x vl=%0d vstart=%0d cause=%0d",
                    phase,dut.core.ex_pc,dut.core.ex_ins,dut.core.v_vtype,
                    dut.core.v_vl,dut.core.v_vstart,dut.core.trap_cause);
            if ((debug_mode_o || dut.core.dbg_step_active) && dut.core.issuing &&
                (dut.core.ex_ins == 32'h00d00073 || dut.core.ex_ins == 32'h01d00073)) begin
                if (cache_flush_req || cache_flush_done || !dut.core.perf_retire)
                    $fatal(1,"debug/stepped WRS depends on cache handshake");
                wrs_nop_count <= wrs_nop_count + 1;
            end
            if ((^{imem_arvalid,imem_rready,dmem_arvalid,dmem_awvalid,
                dmem_wvalid,dmem_rready,dmem_bready,debug_mode_o,debug_resume_ack_o}) === 1'bx)
                $fatal(1,"unknown core/AXI control after reset ar_i/r_i/ar_d/aw_d/w_d/r_d/b_d/dbg/ack=%b%b%b%b%b%b%b%b%b",
                    imem_arvalid,imem_rready,dmem_arvalid,dmem_awvalid,dmem_wvalid,
                    dmem_rready,dmem_bready,debug_mode_o,debug_resume_ack_o);
            if (imem_arvalid && ((^{imem_araddr,imem_arlen,imem_arsize,imem_arprot}) === 1'bx))
                $fatal(1,"unknown valid instruction address/attributes");
            if (dmem_arvalid && ((^{dmem_araddr,dmem_arlen,dmem_arsize,dmem_arprot}) === 1'bx))
                $fatal(1,"unknown valid data read address/attributes");
            if (dmem_awvalid && ((^{dmem_awaddr,dmem_awlen,dmem_awsize,dmem_awprot}) === 1'bx))
                $fatal(1,"unknown valid data write address/attributes");
            if (dmem_wvalid) begin
                if ((^{dmem_wstrb,dmem_wlast}) === 1'bx) $fatal(1,"unknown write control");
                for (integer lane = 0; lane < 8; lane = lane + 1)
                    if (dmem_wstrb[lane] && ((^dmem_wdata[8*lane +: 8]) === 1'bx))
                        $fatal(1,"unknown enabled write data lane");
            end
            if (!debug_mode_o &&
                ((dut.c_imem_arvalid && dut.c_imem_arready &&
                  dut.c_imem_araddr[31:12] == (`KARUDBG_BASE >> 12)) ||
                 (dut.c_dmem_arvalid && dut.c_dmem_arready &&
                  dut.c_dmem_araddr[31:12] == (`KARUDBG_BASE >> 12)) ||
                 (dut.c_dmem_awvalid && dut.c_dmem_awready &&
                  dut.c_dmem_awaddr[31:12] == (`KARUDBG_BASE >> 12))))
                $fatal(1,"normal-mode access reached private debug aperture");
            if (dut.core.perf_retire && !debug_mode_o) normal_retired <= normal_retired + 1;
            if (debug_resume_ack_o) resume_count <= resume_count + 1;
        end
    end

    task dmi(input [1:0] op, input [6:0] addr, input [31:0] data,
             output [31:0] result);
        integer timeout;
        begin
            @(negedge clk);
            dmi_req_valid_i = 1; dmi_req_addr_i = addr;
            dmi_req_op_i = op; dmi_req_data_i = data;
            timeout = 0;
            while (!dmi_req_ready_o && timeout < 100) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(dmi_req_ready_o, "DMI request timeout");
            @(posedge clk); #1;
            @(negedge clk); dmi_req_valid_i = 0;
            timeout = 0;
            while (!dmi_resp_valid_o && timeout < 100) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(dmi_resp_valid_o && dmi_resp_op_o == 0, "DMI response timeout/error");
            result = dmi_resp_data_o;
            dmi_resp_ready_i = 1;
            @(posedge clk); #1;
            @(negedge clk); dmi_resp_ready_i = 0;
        end
    endtask

    task deny_debug_page(input [1:0] prv, input bit virt);
        integer access;
        reg [63:0] pc;
        begin
            write_reg(16'h100b, {32'b0,`KARUDBG_BASE} + 64'h380);
            for (access = 0; access < 3; access = access + 1) begin
                pc = access == 0 ? {32'b0,`KARUDBG_BASE} + 64'h800 :
                     access == 1 ? 64'h80000070 : 64'h80000074;
                write_reg(16'h07b1, pc);
                write_reg(16'h07b0, {58'b0,virt,3'b001,prv});
                resume_hart; wait_parked;
                expect_reg(16'h07b1, 64'h80000100);
                expect_reg(16'h0341, pc);
                expect_reg(16'h0342, access == 0 ? 1 : access == 1 ? 5 : 7);
            end
        end
    endtask

    task code_update;
        begin
            write_reg(16'h07b1, 64'h80000080);
            write_reg(16'h07b0, 64'h8003);
            resume_hart; wait_parked;
            expect_reg(16'h1014, 1); // warm the normal instruction cache line
            write_reg(16'h100b, 64'h80000080);
            write_reg(16'h100c, 64'h00200a13); // addi x20,x0,2
            pb(0, 32'h00c5a023); pb(1, 32'h0000100f); pb(2, 32'h00100073);
            execute_pb(0); // sw; fence.i; ebreak
            write_reg(16'h07b1, 64'h80000080);
            resume_hart; wait_parked;
            expect_reg(16'h1014, 2);
        end
    endtask

    task ebreak_context(input [1:0] prv, input bit virt);
        reg [63:0] dcsr;
        begin
            write_reg(16'h07b1, 64'h80000040);
            write_reg(16'h07b0, 64'h3b000 | {58'b0,virt,3'b000,prv});
            resume_hart; wait_parked;
            read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 1 && dcsr[1:0] == prv && dcsr[5] == virt,
                  "EBREAK debug entry for configured privilege");
            expect_reg(16'h07b1, 64'h80000040);
            expect_reg(16'h0341, saved_mepc); expect_reg(16'h0342, saved_mcause);
            expect_reg(16'h0343, saved_mtval);
            check_hmetadata;
        end
    endtask

    task ebreak_halt_priority;
        integer timeout;
        reg [63:0] dcsr;
        begin
            write_reg(16'h07b1, 64'h80000040);
            write_reg(16'h07b0, 64'h8003);
            resume_hart;
            timeout = 0;
            // Deliver the DMI halt write at the same edge that admits EBREAK.
            // The resulting halt signal and EBREAK issue overlap next cycle.
            while (!(dut.core.id_accept && dut.core.ifu_pc == 64'h80000040)
                   && timeout < 1000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 1000, "observed EBREAK admission for priority test");
            dmi_req_valid_i = 1; dmi_req_addr_i = 7'h10;
            dmi_req_op_i = 2; dmi_req_data_i = 32'h80000001;
            @(posedge clk); #1;
            check(dmi_resp_valid_o, "coincident halt request accepted");
            check(dut.core.dbg_ebreak_entry && dut.core.debug_halt_req_i,
                  "halt request coincides with enabled EBREAK");
            @(negedge clk); dmi_req_valid_i = 0; dmi_resp_ready_i = 1;
            @(posedge clk); #1;
            @(negedge clk); dmi_resp_ready_i = 0;
            wait_parked;
            read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 3, "halt request outranks EBREAK cause");
            expect_reg(16'h07b1, 64'h80000040);
            expect_reg(16'h0341, saved_mepc); expect_reg(16'h0342, saved_mcause);
            expect_reg(16'h0343, saved_mtval);
            check_hmetadata;
        end
    endtask

    task reservation_context;
        integer n;
        reg [63:0] result;
        begin
            write_reg(16'h100b, 64'h80000800);
            write_reg(16'h100e, 64'h1234567811223344);
            for (n = 0; n < 2; n = n + 1) begin
                step_at(n == 0 ? 64'h80000050 : 64'h80000060,
                        n == 0 ? 64'h80000054 : 64'h80000064);
                step_at(n == 0 ? 64'h80000054 : 64'h80000064,
                        n == 0 ? 64'h80000058 : 64'h80000068);
                expect_reg(16'h100d, 1); // entry after LR loses reservation
                // Repeat without halting between LR and SC: a fresh pair works.
                write_reg(16'h07b1, n == 0 ? 64'h80000050 : 64'h80000060);
                write_reg(16'h07b0, 64'h8003);
                resume_hart; wait_parked;
                expect_reg(16'h100d, 0);
                result = memory.ram_word(32'h80000800);
                check(result == 64'h1234567811223344, "fresh LR/SC stores after resume");
            end
        end
    endtask

    // Privilege context is set only through architectural debug CSR transfers.
    // Normal execution performs a NOP, then the single-step boundary captures
    // the same privilege/V pair; application trap state must remain untouched.
    task context_step(input [1:0] prv, input bit virt);
        reg [63:0] context_dcsr;
        begin
            write_reg(16'h07b1, 64'h8000003c);
            write_reg(16'h07b0, {58'b0,virt,3'b001,prv});
            resume_hart; wait_parked;
            read_reg(16'h07b0, context_dcsr);
            check(context_dcsr[1:0] == prv && context_dcsr[5] == virt &&
                  context_dcsr[8:6] == 4, "privilege/virtualization debug round trip");
            expect_reg(16'h07b1, 64'h80000040);
            expect_reg(16'h0341, saved_mepc); expect_reg(16'h0342, saved_mcause);
            expect_reg(16'h0343, saved_mtval);
            check_hmetadata;
        end
    endtask

    task progbuf_control_transfers;
        reg [63:0] saved_ra, saved_a1, saved_a2, saved_a3, saved_a4;
        begin
            phase = "Program Buffer control transfers";
            read_reg(16'h1001, saved_ra); read_reg(16'h100b, saved_a1);
            read_reg(16'h100c, saved_a2); read_reg(16'h100d, saved_a3);
            read_reg(16'h100e, saved_a4);
            write_reg(16'h100c, 0);
            pb(0, 32'h00300693); // addi a3,zero,3
            pb(1, 32'h00160613); // loop: addi a2,a2,1
            pb(2, 32'hfff68693); // addi a3,a3,-1
            pb(3, 32'hfe069ce3); // bne a3,zero,loop (-8)
            pb(4, 32'h00000463); // beq zero,zero,+8
            pb(5, 32'h06300613); // skipped: addi a2,zero,99
            pb(6, 32'h00000717); // auipc a4,0
            pb(7, 32'h00100073); execute_pb(0);
            expect_reg(16'h100c, 3); expect_reg(16'h100d, 0);
            expect_reg(16'h100e, {32'b0,`KARUDBG_BASE} +
                                    {52'b0,`KARUDBG_PROGBUF} + 64'd24);
            check_saved;

            write_reg(16'h100b, 64'h80000280); write_reg(16'h100c, 0);
            pb(0, 32'h000580e7); // jalr ra,0(a1): mapped RAM outside the buffer
            pb(1, 32'h0080006f); // returned here: jal zero,+8
            pb(2, 32'h06300613); // skipped: addi a2,zero,99
            pb(3, 32'h00100073); execute_pb(0);
            expect_reg(16'h100c, 7);
            expect_reg(16'h1001, {32'b0,`KARUDBG_BASE} +
                                    {52'b0,`KARUDBG_PROGBUF} + 64'd4);
            check_saved;
            write_reg(16'h1001, saved_ra); write_reg(16'h100b, saved_a1);
            write_reg(16'h100c, saved_a2); write_reg(16'h100d, saved_a3);
            write_reg(16'h100e, saved_a4);
            phase = "context";
            $display("karudbg Program Buffer control transfers: PASS");
        end
    endtask

    // Execute xRET as the one normal instruction in a step, rather than only
    // testing its deliberately exceptional Program Buffer behavior. Every
    // setup/observation uses the architectural debug CSR interface.
    task stepped_returns;
        reg [63:0] status, mie, mepc, sepc, dcsr;
`ifdef KARU_EN_H
        reg [63:0] hstatus, vsstatus, vsepc;
`endif
        integer retired_before;
        begin
            phase = "stepped architectural returns";
            read_reg(16'h0300, status); read_reg(16'h0304, mie);
            read_reg(16'h0341, mepc);
`ifdef KARU_EN_S
            read_reg(16'h0141, sepc);
`endif
`ifdef KARU_EN_H
            read_reg(16'h0600, hstatus); read_reg(16'h0200, vsstatus);
            read_reg(16'h0241, vsepc);
`endif
            write_reg(16'h0304, 0); // no unrelated interrupt changes the step
            write_reg(16'h0341, 64'h80000180);
            write_reg(16'h0300, (status & ~64'h0000008000021888) | 64'h80);
            retired_before = normal_retired;
            step_at(64'h80000140, 64'h80000180); // MRET: M -> U
            read_reg(16'h07b0, dcsr);
            check(dcsr[1:0] == 0 && !dcsr[5], "stepped MRET restores host U context");
            check(normal_retired == retired_before + 1, "MRET is exactly one stepped retirement");
`ifdef KARU_EN_S
            write_reg(16'h0141, 64'h80000180);
            write_reg(16'h0300, (status & ~64'h000000800042190a) | 64'h20);
            write_reg(16'h07b1, 64'h80000144);
            write_reg(16'h07b0, 64'h5); // S, V=0, step
            retired_before = normal_retired;
            resume_hart; wait_parked;
            expect_reg(16'h07b1, 64'h80000180);
            read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 4 && dcsr[1:0] == 0 && !dcsr[5],
                  "stepped HS SRET restores host U context");
            check(normal_retired == retired_before + 1, "SRET is exactly one stepped retirement");
`endif
`ifdef KARU_EN_H
            write_reg(16'h0341, 64'h80000180);
            write_reg(16'h0300, (status & ~64'h0000008000021888) |
                                   64'h0000008000000880); // MPV, MPP=S, MPIE
            retired_before = normal_retired;
            step_at(64'h80000140, 64'h80000180);
            read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 4 && dcsr[1:0] == 1 && dcsr[5],
                  "stepped MRET enters VS and records V in DCSR");
            check(normal_retired == retired_before + 1, "guest MRET steps no guest instruction");

            write_reg(16'h0141, 64'h80000180);
            write_reg(16'h0600, (hstatus & ~64'h180) | 64'h180); // SPV, SPVP=S
            write_reg(16'h0300, (status & ~64'h000000800042180a) | 64'h120);
            write_reg(16'h07b1, 64'h80000144); write_reg(16'h07b0, 64'h5);
            retired_before = normal_retired;
            resume_hart; wait_parked;
            expect_reg(16'h07b1, 64'h80000180); read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 4 && dcsr[1:0] == 1 && dcsr[5],
                  "stepped HS SRET enters VS");
            check(normal_retired == retired_before + 1, "HS SRET steps no guest instruction");

            write_reg(16'h0241, 64'h80000180);
            write_reg(16'h0200, (vsstatus & ~64'h102) | 64'h20);
            write_reg(16'h07b1, 64'h80000144); write_reg(16'h07b0, 64'h25);
            retired_before = normal_retired;
            resume_hart; wait_parked;
            expect_reg(16'h07b1, 64'h80000180); read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 4 && dcsr[1:0] == 0 && dcsr[5],
                  "stepped VS SRET enters VU");
            check(normal_retired == retired_before + 1, "VS SRET steps no VU instruction");
            write_reg(16'h0600, hstatus); write_reg(16'h0200, vsstatus);
            write_reg(16'h0241, vsepc);
`endif
            write_reg(16'h0300, status); write_reg(16'h0304, mie);
            write_reg(16'h0341, mepc);
`ifdef KARU_EN_S
            write_reg(16'h0141, sepc);
`endif
            write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80000000);
            check_saved;
            $display("karudbg stepped architectural returns: PASS");
        end
    endtask

    function [15:0] irq_trap_csr(input integer index);
        begin
            case (index / 3)
                0: irq_trap_csr = 16'h0341 + 16'(index % 3);
                1: irq_trap_csr = 16'h0141 + 16'(index % 3);
                default: irq_trap_csr = 16'h0241 + 16'(index % 3);
            endcase
        end
    endfunction

    // A single pending source is enabled at its destination throughout debug,
    // one normal NOP step, and the final unstepped resume. The first two must
    // preserve trap/pending state; the last must deliver to the exact bank and
    // cause before the next NOP. Source bits retain their MIP numbering here.
    task interrupt_case(input integer source, input integer destination,
                        input bit timer_compare);
        reg [63:0] trap_before [0:8];
        reg [63:0] mask, value, dcsr, start_dcsr;
        reg [63:0] status, menv;
`ifdef KARU_EN_H
        reg [63:0] hstatus, henv;
`endif
        integer n, banks, retired_before, expected_cause;
        begin
            phase = $sformatf("interrupt source=%0d destination=%0d timer=%0d",
                              source, destination, timer_compare);
            $display("karudbg %s", phase);
            mask = 64'b1 << source;
            banks = 3;
`ifndef KARU_EN_H
            banks = 2;
`endif
`ifndef KARU_EN_S
            banks = 1;
`endif
            for (n = 0; n < banks*3; n = n + 1)
                read_reg(irq_trap_csr(n), trap_before[n]);
            read_reg(16'h0300, status);
`ifdef KARU_EN_S
            read_reg(16'h030a, menv);
            write_reg(16'h030a, menv & ~64'h8000000000000000);
            write_reg(16'h014d, ~64'b0);
`endif
`ifdef KARU_EN_H
            read_reg(16'h0600, hstatus); read_reg(16'h060a, henv);
            write_reg(16'h060a, henv & ~64'h8000000000000000);
            write_reg(16'h024d, ~64'b0);
            write_reg(16'h0645, 0); write_reg(16'h0603, 0);
            write_reg(16'h0200, 2); // VS.SIE
`endif
            write_reg(16'h0304, 0); write_reg(16'h0344, 0);
            write_reg(16'h0303, destination == 0 ? 0 : mask);
`ifdef KARU_EN_H
            if (destination == 2) write_reg(16'h0603, mask);
`endif
            // Leave every interrupt globally enabled at the chosen level.
            write_reg(16'h0300, (status & ~64'h000000800042180a) | 64'ha);
            start_dcsr = 64'h3b000 | (destination == 0 ? 3 : 1);
`ifdef KARU_EN_H
            if (destination == 2 || source == 2 || source == 6 || source == 10)
                start_dcsr = (start_dcsr & ~64'h3) | 64'h21;
`endif
            write_reg(16'h0304, mask);
            case (source)
                3: irq_software = 1;
                7: irq = 1;
                11: irq_external_m = 1;
                9: irq_external_s = 1;
`ifdef KARU_EN_H
                2, 6, 10: begin
                    if (timer_compare) begin
                        write_reg(16'h030a, menv | 64'h8000000000000000);
                        write_reg(16'h060a, henv | 64'h8000000000000000);
                        write_reg(16'h024d, 0);
                    end else write_reg(16'h0645, mask);
                end
`endif
                default: begin
`ifdef KARU_EN_S
                    if (timer_compare) begin
                        write_reg(16'h030a, menv | 64'h8000000000000000);
                        write_reg(16'h014d, 0);
                    end else
`endif
                        write_reg(16'h0344, mask);
                end
            endcase
`ifdef KARU_EN_SSCOFPMF
            if (source == 13) begin
                write_reg(16'h0323, 64'h8000000000000001);
                hpm_events = 2;
            end
`endif
            repeat (20) @(negedge clk);
            read_reg(16'h0344, value);
            check((value & mask) == mask, "enabled interrupt is pending during Debug Mode");
            for (n = 0; n < banks*3; n = n + 1)
                expect_reg(irq_trap_csr(n), trap_before[n]);
            check_hmetadata;
            write_reg(16'h07b1, 64'h80000180);
            write_reg(16'h07b0, start_dcsr | 4);
            retired_before = normal_retired;
            resume_hart; wait_parked;
            expect_reg(16'h07b1, 64'h80000184); read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 4 && dcsr[5:0] == (start_dcsr[5:0] | 6'd4),
                  "stepie zero masks the source and retains source context");
            check(normal_retired == retired_before + 1,
                  "pending interrupt permits exactly one normal stepped NOP");
            read_reg(16'h0344, value);
            check((value & mask) == mask, "single-step preserves interrupt pending state");
            for (n = 0; n < banks*3; n = n + 1)
                expect_reg(irq_trap_csr(n), trap_before[n]);
            check_hmetadata;
`ifdef KARU_EN_SSCOFPMF
            if (source == 13) begin
                read_reg(16'h0323, value);
                check(value[63], "preexisting OF survives debug and stepping");
                hpm_events = 0;
            end
`endif
            write_reg(16'h07b0, start_dcsr);
            resume_hart; wait_parked;
            expect_reg(16'h07b1, 64'h80000200 + 64'(destination*32));
            expected_cause = source;
            if (destination == 2 && source != 13) expected_cause = source - 1;
            expect_reg(irq_trap_csr(destination*3 + 1),
                       64'h8000000000000000 | 64'(expected_cause));
            expect_reg(irq_trap_csr(destination*3), 64'h80000184);
            read_reg(16'h07b0, dcsr);
            check(dcsr[8:6] == 1 && dcsr[1:0] == (destination == 0 ? 3 : 1) &&
                  dcsr[5] == (destination == 2), "interrupt handler EBREAK records exact destination");
            read_reg(16'h0344, value);
            check((value & mask) == mask, "trap entry does not clear pending interrupt");
            irq = 0; irq_software = 0; irq_external_m = 0; irq_external_s = 0;
            write_reg(16'h0304, 0); write_reg(16'h0344, 0);
`ifdef KARU_EN_S
            write_reg(16'h030a, menv); write_reg(16'h014d, ~64'b0);
`endif
`ifdef KARU_EN_H
            write_reg(16'h060a, henv); write_reg(16'h024d, ~64'b0);
            write_reg(16'h0645, 0); write_reg(16'h0603, 0);
            write_reg(16'h0600, hstatus);
            // Interrupt trap entry writes metadata; restore the application
            // canaries only after proving the architectural delivery above.
            write_reg(16'h0643, 64'h123456789abcd);
            write_reg(16'h064a, 64'h3000);
            write_reg(16'h034a, 64'h5000); write_reg(16'h034b, 64'hdeadbeef);
`endif
            for (n = 0; n < banks*3; n = n + 1)
                write_reg(irq_trap_csr(n), trap_before[n]);
            write_reg(16'h0300, status);
            write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80000000);
        end
    endtask

    task interrupt_context;
        reg [63:0] mie, mideleg, mtvec;
        reg [7:0] cases [0:19]; // {timer comparator, destination[1:0], MIP bit[4:0]}
        integer count, n;
`ifdef KARU_EN_S
        reg [63:0] stvec, stimecmp;
`endif
`ifdef KARU_EN_H
        reg [63:0] vstvec, vsstatus, hideleg, vstimecmp;
`endif
`ifdef KARU_EN_SSCOFPMF
        reg [63:0] hpmevent;
`endif
        begin
            read_reg(16'h0304, mie); read_reg(16'h0303, mideleg);
            read_reg(16'h0305, mtvec); write_reg(16'h0305, 64'h80000200);
`ifdef KARU_EN_S
            read_reg(16'h0105, stvec); write_reg(16'h0105, 64'h80000220);
            read_reg(16'h014d, stimecmp);
`endif
`ifdef KARU_EN_H
            read_reg(16'h0205, vstvec); write_reg(16'h0205, 64'h80000240);
            read_reg(16'h0200, vsstatus); read_reg(16'h0603, hideleg);
            read_reg(16'h024d, vstimecmp);
`endif
`ifdef KARU_EN_SSCOFPMF
            read_reg(16'h0323, hpmevent);
`endif
            count = 0;
            cases[count] = 8'h03; count = count + 1;
            cases[count] = 8'h07; count = count + 1;
            cases[count] = 8'h0b; count = count + 1;
`ifdef KARU_EN_S
            cases[count] = 8'h01; count = count + 1;
            cases[count] = 8'h05; count = count + 1;
            cases[count] = 8'h09; count = count + 1;
            cases[count] = 8'h21; count = count + 1;
            cases[count] = 8'h25; count = count + 1;
            cases[count] = 8'h29; count = count + 1;
            cases[count] = 8'ha5; count = count + 1; // Sstc comparator
`endif
`ifdef KARU_EN_H
            cases[count] = 8'h22; count = count + 1;
            cases[count] = 8'h26; count = count + 1;
            cases[count] = 8'h2a; count = count + 1;
            cases[count] = 8'h42; count = count + 1;
            cases[count] = 8'h46; count = count + 1;
            cases[count] = 8'h4a; count = count + 1;
            cases[count] = 8'hc6; count = count + 1; // virtual Sstc comparator
`endif
`ifdef KARU_EN_SSCOFPMF
            cases[count] = 8'h0d; count = count + 1;
`ifdef KARU_EN_S
            cases[count] = 8'h2d; count = count + 1;
`endif
`ifdef KARU_EN_H
            cases[count] = 8'h4d; count = count + 1;
`endif
`endif
            // One timing-task call avoids cloning its DMI transaction state
            // machine for every row during Verilator elaboration.
            for (n = 0; n < count; n = n + 1)
                interrupt_case(int'(cases[n][4:0]), int'(cases[n][6:5]), cases[n][7]);
`ifdef KARU_EN_SSCOFPMF
            write_reg(16'h0323, hpmevent);
`endif
            write_reg(16'h0303, mideleg); write_reg(16'h0304, mie);
            write_reg(16'h0305, mtvec);
`ifdef KARU_EN_S
            write_reg(16'h0105, stvec); write_reg(16'h014d, stimecmp);
`endif
`ifdef KARU_EN_H
            write_reg(16'h0205, vstvec); write_reg(16'h0200, vsstatus);
            write_reg(16'h0603, hideleg); write_reg(16'h024d, vstimecmp);
`endif
            check_saved;
            phase = "context";
            $display("karudbg all implemented interrupt sources: PASS");
        end
    endtask

    task extended_context;
        integer n, byte_index;
        reg [63:0] original_status, fp_pattern, context_value, event_value;
        begin
            read_reg(16'h0300, original_status);
            // Select event1 and start one increment away from overflow.
            write_reg(16'h0323, 1);
            write_reg(16'h0b03, 64'hffffffffffffffff);
            hpm_events = 2;
            repeat (100) @(negedge clk);
            expect_reg(16'h0b03, 64'hffffffffffffffff);
            read_reg(16'h0323, event_value);
            check(!event_value[63], "Debug Mode cannot create HPM overflow");
            read_reg(16'h0344, context_value);
            check(!context_value[13], "Debug Mode cannot generate LCOFI");
            hpm_events = 0;
            write_reg(16'h0323, 0); write_reg(16'h0b03, 0);
            read_reg(16'h0b02, context_value);
            repeat (100) @(negedge clk);
            expect_reg(16'h0b02, context_value);
            irq = 1; irq_software = 1; irq_external_m = 1; irq_external_s = 1;
            repeat (10) @(negedge clk);
            read_reg(16'h0344, context_value);
            check((context_value & 64'h00000a88) == 64'h00000a88,
                  "interrupt pending inputs survive debug masking");
            check_saved;
            irq = 0; irq_software = 0; irq_external_m = 0; irq_external_s = 0;

`ifdef KARU_EN_D
            write_reg(16'h0300, original_status | 64'h6600);
            for (n = 0; n < 32; n = n + 1) begin
                fp_pattern = 64'hfff8000001020304 ^ (64'(n) << 36) ^ 64'(n);
                write_reg(16'h100c, fp_pattern);
                pb(0, 32'hf2060053 | (32'(n) << 7)); // fmv.d.x fN,a2
                pb(1, 32'he20006d3 | (32'(n) << 15)); // fmv.x.d a3,fN
                pb(2, 32'h00100073); execute_pb(0);
                expect_reg(16'h100d, fp_pattern);
            end
            // Later operations must leave every previously written FPR intact.
            for (n = 0; n < 32; n = n + 1) begin
                fp_pattern = 64'hfff8000001020304 ^ (64'(n) << 36) ^ 64'(n);
                pb(0, 32'he20006d3 | (32'(n) << 15));
                pb(1, 32'h00100073); execute_pb(0);
                expect_reg(16'h100d, fp_pattern);
            end
`endif
`ifdef KARU_EN_V
            write_reg(16'h0300, original_status | 64'h6600);
            masked_vector_context;
            write_reg(16'h0008, 0);
            // Load all 32 registers first, then store all: later loads cannot
            // silently clobber earlier state. Test data resides on the AXI RAM.
            for (n = 0; n < 1024; n = n + 1)
                memory.ram['h1000+n] = 8'(n ^ (n >> 5) ^ 'h5a);
            for (n = 0; n < 32; n = n + 1) begin
                write_reg(16'h100b, 64'h80001000 + 64'(n*32));
                pb(0, 32'h02858007 | (32'(n) << 7)); // vl1re8.v vN,(a1)
                pb(1, 32'h00100073); execute_pb(0);
            end
            for (n = 0; n < 32; n = n + 1) begin
                write_reg(16'h100d, 64'h80002000 + 64'(n*32));
                pb(0, 32'h02868027 | (32'(n) << 7)); // vs1r.v vN,(a3)
                pb(1, 32'h00100073); execute_pb(0);
            end
            for (n = 0; n < 1024; n = n + 1)
                check(memory.ram['h2000+n] == 8'(n ^ (n >> 5) ^ 'h5a),
                      "all-vector-register context round trip");
`ifdef KARU_KECCAK
            // riscv-pqc KECCAK-P known answer, input lane i = i.
            for (n = 0; n < 32; n = n + 1)
                for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                    memory.ram['h3000+n*8+byte_index] = 8'(64'(n) >> (byte_index*8));
            write_reg(16'h100b, 64'h80003000);
            write_reg(16'h100d, 64'h80003400);
            write_reg(16'h100c, 32);
            pb(0, 32'he2858007); // vl8re8.v v0,(a1)
            pb(1, 32'h01b67057); // vsetvli zero,a2,e64,m8,tu,mu
            pb(2, 32'ha6092077); // vkeccak.vi v0,0
            pb(3, 32'he2868027); // vs8r.v v0,(a3)
            pb(4, 32'h00100073); execute_pb(0);
            for (n = 0; n < 32; n = n + 1) begin
                context_value = memory.ram_word(32'h80003400 + 32'(n*8));
                if (n < 25) check(context_value == keccak_expected[n], "debug Keccak known answer");
                else check(context_value == 64'(n), "debug Keccak preserves state tail");
            end
`endif
`endif
            context_step(3, 0);
            ebreak_context(3, 0);
`ifdef KARU_EN_S
            context_step(1, 0);
            ebreak_context(1, 0);
`endif
            context_step(0, 0);
            ebreak_context(0, 0);
`ifdef KARU_EN_H
            context_step(1, 1); context_step(0, 1);
            ebreak_context(1, 1); ebreak_context(0, 1);
            // A malicious interrupted MPRV/MPV context points VS translation
            // at invalid entries. Debug load/store must stay physical M-mode.
            write_reg(16'h0280, 64'h800000000008000f); // vsatp Sv39 invalid root
            write_reg(16'h0300, (original_status & ~64'h1800) |
                                   64'h0000008000020800); // MPRV, MPV, MPP=S
            expect_reg(16'h0340, 64'hfedcba9876543210);
            write_reg(16'h100b, 64'h10000000);
            pb(0, 32'h0005a603); pb(1, 32'h00100073); execute_pb(0);
            check(debug_mode_o, "MPRV/MPV debug physical access");
            write_reg(16'h0280, 0);
`endif
            write_reg(16'h0300, original_status);
            ebreak_halt_priority;
            reservation_context;
            write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80000000);
            check_saved;
            $display("karudbg extended context: PASS");
        end
    endtask
    task wr(input [6:0] addr, input [31:0] data);
        reg [31:0] ignored;
        begin dmi(2, addr, data, ignored); end
    endtask
    task rd(input [6:0] addr, output [31:0] result);
        begin dmi(1, addr, 0, result); end
    endtask
    task wait_parked;
        integer timeout;
        begin
            timeout = 0;
            while (!(debug_mode_o && dut.dm.parked_q) && timeout < 20000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            if (timeout == 20000)
                $fatal(1,"park timeout mode=%b pc=%x state=%x",debug_mode_o,dut.core.ifu_pc,dut.dm.cmd_state_q);
            check(debug_mode_o && dut.dm.parked_q, "hart reached ROM parking handshake");
        end
    endtask
    task command(input [31:0] word, input [2:0] error);
        integer timeout;
        reg [31:0] status;
        begin
            wr(7'h17, word);
            timeout = 0; status = 32'h1000;
            while (status[12] && timeout < 5000) begin
                rd(7'h16, status); timeout = timeout + 1;
            end
            if (status[12] || status[10:8] != error)
                $fatal(1,"command %08x status=%08x expected error=%0d pc=%x ex=%x",word,status,error,dut.core.ifu_pc,dut.core.ex_w);
            checks = checks + 1;
            if (error) wr(7'h16, 32'h700);
        end
    endtask
    task read_reg(input [15:0] regno, output [63:0] result);
        reg [31:0] lo, hi;
        begin
            command(32'h00320000 | {16'b0, regno}, 0);
            rd(7'h04, lo); rd(7'h05, hi); result = {hi, lo};
        end
    endtask
    task write_reg(input [15:0] regno, input [63:0] data);
        begin
            wr(7'h04, data[31:0]); wr(7'h05, data[63:32]);
            command(32'h00330000 | {16'b0, regno}, 0);
        end
    endtask
    task expect_reg(input [15:0] regno, input [63:0] data);
        reg [63:0] actual;
        begin
            read_reg(regno, actual);
            if (actual !== data)
                $fatal(1,"register %04x=%016x expected %016x",regno,actual,data);
            checks = checks + 1;
        end
    endtask
    task pb(input integer slot, input [31:0] insn);
        begin wr(7'h20 + 7'(slot), insn); end
    endtask
    task execute_pb(input [2:0] error);
        begin command(32'h00040000, error); end
    endtask
    task check_saved;
        begin
            expect_reg(16'h1008, canary_s0); expect_reg(16'h100a, canary_a0);
            expect_reg(16'h0341, saved_mepc); expect_reg(16'h0342, saved_mcause);
            expect_reg(16'h0343, saved_mtval);
            check_hmetadata;
            expect_reg(16'h07b1, 64'h80000000);
        end
    endtask
    task resume_hart;
        integer previous, timeout;
        begin
            previous = resume_count;
            wr(7'h10, 32'h40000001);
            timeout = 0;
            while (resume_count == previous && timeout < 20000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(resume_count == previous + 1, "exactly one core-confirmed resume");
        end
    endtask
    task step_at(input [63:0] pc, input [63:0] expected_pc);
        begin
            write_reg(16'h07b1, pc);
            write_reg(16'h07b0, 64'h7); // prv=M, step=1; readonly bits retained
            before_count = normal_retired;
            resume_hart;
            wait_parked;
            expect_reg(16'h07b1, expected_pc);
            read_reg(16'h07b0, got);
            check(got[8:6] == 4, "single-step cause");
            check(normal_retired - before_count <= 1, "at most one normal retirement on step");
        end
    endtask

    initial begin
        #1; memory.clear_ram();
        keccak_expected[0]=64'h8374b05252ed8115; keccak_expected[1]=64'h1df7a676b6569400;
        keccak_expected[2]=64'hf765194b8a51797d; keccak_expected[3]=64'h20477b43d1760545;
        keccak_expected[4]=64'hd15f8ba4f3f6606a; keccak_expected[5]=64'ha1d7144f7c8dd493;
        keccak_expected[6]=64'h30d193965138fd3f; keccak_expected[7]=64'h487e9472951be3be;
        keccak_expected[8]=64'h0cf3a858cbda7a5a; keccak_expected[9]=64'h2fe54e389bb17f88;
        keccak_expected[10]=64'h0b7338de0d9f268f; keccak_expected[11]=64'h55efdff58b256d7f;
        keccak_expected[12]=64'hc8353e94eb2c3e6a; keccak_expected[13]=64'h2e2af6948c901f11;
        keccak_expected[14]=64'he873de0cca309da6; keccak_expected[15]=64'hf7afc26c944d31e2;
        keccak_expected[16]=64'ha0f5ea808cc415d7; keccak_expected[17]=64'h53f531437e3ed8cf;
        keccak_expected[18]=64'h777f1f3b43a4d221; keccak_expected[19]=64'hfd0ca63cb499e985;
        keccak_expected[20]=64'hd4c055c0c5d12330; keccak_expected[21]=64'ha72fe58aa6e0a7df;
        keccak_expected[22]=64'h421af5937c9948a3; keccak_expected[23]=64'h5e16103071340888;
        keccak_expected[24]=64'hd153f43a297e4a33;
        put_insn(0, 32'h00100293); // addi x5,x0,1
        put_insn(4, 32'h00200313); // addi x6,x0,2
        put_insn(8, 32'h0000006f); // j .
        put_insn('h10, 32'h008000ef); // jal x1,+8
        put_insn('h18, 32'h00000463); // beq x0,x0,+8
        put_insn('h20, 32'h00138393); // addi x7,x7,1
        put_insn('h24, 32'h00000073); // ecall
        put_insn('h28, 0);           // illegal
        put_insn('h2c, 32'h00058067); // jalr x0,0(x11)
        put_insn('h30, 32'h10500073); // wfi
        put_insn('h34, 32'h00d00073); // wrs.nto
        put_insn('h38, 32'h01d00073); // wrs.sto
        put_insn('h3c, 32'h00000013); // nop
        put_insn('h40, 32'h00100073); // ebreak
        put_insn('h44, 32'h00000013);
        put_insn('h50, 32'h1005b62f); // lr.d a2,(a1)
        put_insn('h54, 32'h18e5b6af); // sc.d a3,a4,(a1)
        put_insn('h58, 32'h00100073);
        put_insn('h60, 32'h1005a62f); // lr.w a2,(a1)
        put_insn('h64, 32'h18e5a6af); // sc.w a3,a4,(a1)
        put_insn('h68, 32'h00100073);
        put_insn('h70, 32'h0005a603); // lw a2,0(a1)
        put_insn('h74, 32'h00e5a023); // sw a4,0(a1)
        put_insn('h80, 32'h00100a13); // addi x20,x0,1
        put_insn('h84, 32'h00100073);
        put_insn('h90, 32'h00019002); // C.EBREAK; C.NOP
        put_insn('ha0, 32'h1a100153); // fdiv.d f2,f0,f1,rne
        put_insn('ha4, 32'h06300793); put_insn('ha8, 32'h00100073);
        put_insn('hb0, 32'ha6092077); // vkeccak.vi v0,0
        put_insn('hb4, 32'h06300793); put_insn('hb8, 32'h00100073);
        put_insn('hc0, 32'h0045a00f); // cbo.zero (a1)
        put_insn('hc4, 32'h06300793); put_insn('hc8, 32'h00100073);
        put_insn('hd0, 32'he2868027); // vs8r.v v0,(a3)
        put_insn('hd4, 32'h06300793); put_insn('hd8, 32'h00100073);
        put_insn('h100, 32'h001f0f13); // addi x30,x30,1 (must not execute after stepped trap)
        put_insn('h104, 32'h0000006f);
        put_insn('h140, 32'h30200073); // normal MRET for single-step coverage
        put_insn('h144, 32'h10200073); // normal SRET, both HS and VS
        put_insn('h148, 32'h00001463); // bne zero,zero,+8: deliberately not taken
        put_insn('h180, 32'h00000013); // step with an enabled pending interrupt
        put_insn('h184, 32'h00000013);
        put_insn('h188, 32'h00100073);
        put_insn('h200, 32'h00100073); // M, HS and VS interrupt handlers
        put_insn('h220, 32'h00100073);
        put_insn('h240, 32'h00100073);
        put_insn('h280, 32'h00760613); // debug external code: addi a2,a2,7
        put_insn('h284, 32'h00008067); // jalr zero,0(ra), returning into Program Buffer
        hart_reset_i = 1;
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        wr(7'h10, 1);
        wr(7'h10, 32'h80000001);
        @(negedge clk); hart_reset_i = 0;
        wait_parked;
        check(normal_retired == 0, "reset halt before first normal instruction");
        expect_reg(16'h07b1, 64'h80000000);
        read_reg(16'h07b0, got);
        check(got[31:28] == 4 && got[8:6] == 3 && got[10], "DCSR debugver/cause/stopcount");

`ifdef TEST_VECTOR_PROBE
        write_reg(16'h0300, 64'h6600);
        masked_vector_context;
        $display("karudbg focused vector probe: PASS");
        $finish;
`else
        for (k = 0; k < 32; k = k + 1) begin
            expected_gpr[k] = k == 0 ? 0 : 64'hf00dcafe01020304 ^ (64'(k) * 64'h0101010101010101);
            write_reg(16'h1000 + 16'(k), expected_gpr[k]);
        end
        for (k = 0; k < 32; k = k + 1) begin
            expect_reg(16'h1000 + 16'(k), expected_gpr[k]);
            wr(7'h05, 32'h12345678);
            command(32'h00221000 | 32'(k), 0);
            rd(7'h04, value); check(value == expected_gpr[k][31:0], "32-bit GPR read");
            rd(7'h05, value); check(value == 32'h12345678, "32-bit read preserves data1");
        end
        canary_s0 = expected_gpr[8]; canary_a0 = expected_gpr[10];
        write_reg(16'h0340, 64'hfedcba9876543210);
        expect_reg(16'h0340, 64'hfedcba9876543210);
        wr(7'h05, 32'h89abcdef); command(32'h00220340, 0);
        rd(7'h04, value); check(value == 32'h76543210, "32-bit CSR read");
        rd(7'h05, value); check(value == 32'h89abcdef, "32-bit CSR preserves data1");
        write_reg(16'h0341, 64'h80000200); saved_mepc = 64'h80000200;
        write_reg(16'h0342, 64'h1234); saved_mcause = 64'h1234;
        write_reg(16'h0343, 64'h5678); saved_mtval = 64'h5678;
`ifdef KARU_EN_H
        write_reg(16'h0643, 64'h123456789abcd); write_reg(16'h064a, 64'h3000);
        write_reg(16'h034a, 64'h5000); write_reg(16'h034b, 64'hdeadbeef);
`endif
        read_reg(16'h0b00, old_cycle);
        repeat (100) @(negedge clk);
        expect_reg(16'h0b00, old_cycle);
        read_reg(16'h0b03, old_hpm);
        hpm_events = 32'hffffffff;
        repeat (100) @(negedge clk);
        expect_reg(16'h0b03, old_hpm); hpm_events = 0;
        pb(0, 32'h00760613); pb(1, 32'h00100073); // addi x12,x12,7; ebreak
        execute_pb(0); expect_reg(16'h100c, expected_gpr[12] + 7); check_saved;

        write_reg(16'h100b, 64'h10000000);
        before_count = mmio_reads;
        pb(0, 32'h0005a603); pb(1, 32'h00100073); // lw x12,0(x11)
        execute_pb(0); expect_reg(16'h100c, 64'hffffffff87654321);
        check(mmio_reads == before_count + 1, "exactly one read-to-clear MMIO read");
        execute_pb(0); expect_reg(16'h100c, 0);
        check(mmio_reads == before_count + 2, "no trailing MMIO read");
        write_reg(16'h100c, 64'h76543210);
        pb(0, 32'h00c5a023); pb(1, 32'h00100073); // sw x12,0(x11)
        before_count = mmio_writes; execute_pb(0);
        check(mmio_writes == before_count + 1 && mmio_value[31:0] == 32'h76543210,
              "one native-width MMIO store");
        check_saved;
        // Slave errors and PMA denial are contained in the command path.
        write_reg(16'h100b, 64'h10000010);
        pb(0, 32'h0005a603); execute_pb(3); check_saved;
        write_reg(16'h100b, 64'h13000000);
        execute_pb(3); check_saved;
        command(32'h003207a0, 3); check_saved; // absent trigger CSR
        pb(0, 32'h00000073); execute_pb(3); check_saved; // ecall
        pb(0, 32'h30200073); execute_pb(3); check_saved; // mret
        pb(0, 32'h10200073); execute_pb(3); check_saved; // sret
        pb(0, 32'h7b200073); execute_pb(3); check_saved; // Program Buffer DRET
        write_reg(16'h100b, 64'h00120888);
        pb(0, 32'h00058067); execute_pb(3); check_saved; // jump to ROM DRET bypass
        pb(0, 32'h10500073); pb(1, 32'h00d00073); pb(2, 32'h01d00073);
        pb(3, 32'h00160613); pb(4, 32'h00100073);
        write_reg(16'h100c, 99); execute_pb(0); expect_reg(16'h100c, 100); check_saved;

        exception_register_effects;
        vector_fault_context;
        extended_context;
        compressed_debug;
        pointer_mask_debug;
        long_instruction_halts;
        progbuf_control_transfers;
        stepped_returns;
        interrupt_context;

        step_at(64'h80000000, 64'h80000004); expect_reg(16'h1005, 1);
        step_at(64'h80000004, 64'h80000008); expect_reg(16'h1006, 2);
        step_at(64'h80000010, 64'h80000018); expect_reg(16'h1001, 64'h80000014);
        step_at(64'h80000018, 64'h80000020);
        step_at(64'h80000148, 64'h8000014c);
        step_at(64'h80000030, 64'h80000034);
        step_at(64'h80000034, 64'h80000038);
        step_at(64'h80000038, 64'h8000003c);
        write_reg(16'h0305, 64'h80000100);
        write_reg(16'h101e, 64'h55aa);
        step_at(64'h80000024, 64'h80000100);
        expect_reg(16'h0341, 64'h80000024); expect_reg(16'h0342, 11);
        expect_reg(16'h101e, 64'h55aa);
        step_at(64'h80000028, 64'h80000100);
        expect_reg(16'h0341, 64'h80000028); expect_reg(16'h0342, 2);
        expect_reg(16'h101e, 64'h55aa);
        write_reg(16'h100b, 64'h13000000);
        step_at(64'h8000002c, 64'h13000000);
        step_at(64'h13000000, 64'h80000100);
        expect_reg(16'h0341, 64'h13000000); expect_reg(16'h0342, 1);
        expect_reg(16'h101e, 64'h55aa);
        deny_debug_page(3, 0);
`ifdef KARU_EN_S
        deny_debug_page(1, 0);
`endif
        deny_debug_page(0, 0);
`ifdef KARU_EN_H
        deny_debug_page(1, 1); deny_debug_page(0, 1);
`endif
        code_update;
        // Detach with step clear, run normal code, then halt again.
        write_reg(16'h07b0, 3); write_reg(16'h07b1, 64'h80000000);
        before_count = normal_retired;
        resume_hart;
        repeat (100) @(negedge clk);
        wr(7'h10, 32'h80000001); wait_parked;
        check(normal_retired > before_count + 1, "normal execution after debugger resume");
        expect_reg(16'h1005, 1); expect_reg(16'h1006, 2);
        check(!trap, "no terminal core trap");
        check(wrs_nop_count >= 4, "debug and stepped WRS NOP coverage");
        $display("karudbg actual core: PASS (%0d checks, %0d cycles, %0d normal retirements)",checks,cycle,normal_retired);
        $finish;
`endif
    end
    initial begin #30000000; $fatal(1,"debug core global timeout"); end
endmodule
