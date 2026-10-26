// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright 2026 Markku-Juhani O. Saarinen.
// SPDX-License-Identifier: SHL-0.51
// Adapted from pulp-platform/riscv-dbg src/dm_csrs.sv, src/dm_mem.sv and
// src/dm_pkg.sv at 643607e19df3435cfd77cc56143e2637f5900a6e:
// https://github.com/pulp-platform/riscv-dbg/tree/643607e19df3435cfd77cc56143e2637f5900a6e/src
// Karu adaptation: Verilog-2001, synchronous active-high reset, one RV64 hart,
// Debug 1.0 register semantics, no SBA/autoexec, explicit resume confirmation.
// See LICENSE.Solderpad. Not a source-compatible PULP fork.
//
// Memory port: mem_req_i && mem_ready_o commits one request on a rising edge.
// Read data/error are combinational for that request; read data is the aligned
// 64-bit word containing mem_addr_i. Writes use aligned AXI-style byte lanes.
// The integration must enforce requester authorization before this interface.

`include "karudbg_defs.vh"

module karudbg (
    input wire clk,
    input wire rst,
    input wire dmi_reset_i,
    input wire req_valid_i,
    output wire req_ready_o,
    input wire [6:0] req_addr_i,
    input wire [1:0] req_op_i,
    input wire [31:0] req_data_i,
    output reg resp_valid_o,
    input wire resp_ready_i,
    output reg [31:0] resp_data_o,
    output reg [1:0] resp_op_o,
    output wire halt_req_o,
    output wire resume_req_o,
    output wire resume_authorized_o,
    output wire ndmreset_o,
    input wire hart_halted_i,
    input wire hart_resume_ack_i,
    input wire hart_unavailable_i,
    input wire hart_reset_i,
    input wire mem_req_i,
    input wire mem_write_i,
    input wire [11:0] mem_addr_i,
    input wire [63:0] mem_wdata_i,
    input wire [7:0] mem_be_i,
    output reg [63:0] mem_rdata_o,
    output wire mem_ready_o,
    output reg mem_error_o
);
    localparam [1:0] CMD_IDLE = 0, CMD_GO = 1, CMD_EXEC = 2;
    reg dmactive_q, halt_q, ndmreset_q;
    reg resume_pending_q, resume_ack_q, resuming_seen_q;
    reg havereset_q, parked_q;
    reg [1:0] cmd_state_q;
    reg [2:0] cmderr_q;
    reg [31:0] command_q;
    reg [63:0] data_q;
    reg [31:0] progbuf_q [0:7];
    reg [31:0] abstract_word [0:9];
    reg [31:0] dmi_read;
    reg [31:0] dmstatus;
    reg [31:0] abstractcs;
    wire [63:0] rom_data;
    wire dmi_fire, mem_fire, busy, available, acknowledged_halted;
    wire mem_halted, mem_going, mem_resuming, mem_exception;
    wire command_supported;
    wire [15:0] command_regno;
    wire command_is_gpr, command_is_csr;
    wire [3:0] mem_abstract_index;
    wire [2:0] mem_prog_index;
    wire [11:0] mem_aligned_addr;
    wire [11:0] mem_abstract_offset;
    wire unused_command;
    integer i;
    integer j;

    assign busy = cmd_state_q != CMD_IDLE;
    assign available = !hart_unavailable_i && !hart_reset_i && !ndmreset_q;
    // Debug entry precedes the ROM's scratch saves. Advertise halted only
    // after HALTED, then keep it asserted throughout commands and resume
    // preparation until the core actually leaves Debug Mode.
    assign acknowledged_halted = hart_halted_i &&
        (parked_q || busy || resume_pending_q);
    assign halt_req_o = dmactive_q && halt_q;
    assign resume_req_o = dmactive_q && resume_pending_q && available;
    assign resume_authorized_o = resume_req_o && resuming_seen_q;
    assign ndmreset_o = dmactive_q && ndmreset_q;
    assign req_ready_o = !rst && !dmi_reset_i && (!resp_valid_o || resp_ready_i);
    assign dmi_fire = req_valid_i && req_ready_o;
    assign mem_ready_o = !rst;
    assign mem_fire = mem_req_i && mem_ready_o && !mem_error_o;
    assign mem_aligned_addr = {mem_addr_i[11:3], 3'b0};
    assign mem_halted = mem_fire && mem_write_i &&
        mem_aligned_addr == `KARUDBG_HALTED && mem_be_i[0];
    assign mem_going = mem_fire && mem_write_i &&
        mem_aligned_addr == `KARUDBG_GOING && mem_be_i[0];
    assign mem_resuming = mem_fire && mem_write_i &&
        mem_aligned_addr == `KARUDBG_RESUMING && mem_be_i[0];
    assign mem_exception = mem_fire && mem_write_i &&
        mem_aligned_addr == `KARUDBG_EXCEPT && mem_be_i[0];
    assign mem_abstract_offset = mem_addr_i - `KARUDBG_ABSTRACT;
    assign mem_abstract_index = {mem_abstract_offset[5:3], 1'b0};
    assign mem_prog_index = {mem_addr_i[4:3], 1'b0};
    assign unused_command = &{1'b0, command_q[31:23], command_q[19],
        command_q[15:13], mem_abstract_offset[11:6], mem_abstract_offset[2:0]};
    assign command_regno = req_data_i[15:0];
    assign command_is_gpr = command_regno[15:5] == 11'h080;
    assign command_is_csr = command_regno[15:12] == 0 &&
        command_regno != 16'h07b2 && command_regno != 16'h07b3;
    // transfer=0 ignores transfer-only fields, including size/regno/write.
    // aarpostincrement is optional and deliberately unsupported.
    assign command_supported = req_data_i[31:24] == 0 &&
        !req_data_i[23] && !req_data_i[19] &&
        (!req_data_i[17] ||
         (((req_data_i[22:20] == 2 && !req_data_i[16]) || req_data_i[22:20] == 3) &&
          (command_is_gpr || command_is_csr)));

    function [31:0] insn_csr;
        input [11:0] csr;
        input [4:0] rd;
        input [4:0] rs;
        input [2:0] op;
        begin insn_csr = {csr, rs, op, rd, 7'h73}; end
    endfunction
    function [31:0] insn_load;
        input [4:0] rd;
        begin insn_load = {12'h380, 5'd10, 3'b011, rd, 7'h03}; end
    endfunction
    function [31:0] insn_store;
        input [4:0] rs;
        input [2:0] size;
        begin insn_store = {7'h1c, rs, 5'd10, size, 5'd0, 7'h23}; end
    endfunction
    function [31:0] insn_jump;
        input [20:1] offset;
        begin insn_jump = {offset[20], offset[10:1], offset[11],
                          offset[19:12], 5'b0, 7'h6f}; end
    endfunction

    karudbg_rom rom (.addr_i(mem_addr_i), .data_o(rom_data));

    // The fixed ten-word sequence falls into the Program Buffer on postexec.
    // x10/a0 addresses the debug page; x8/s0 is the CSR-transfer temporary.
    // Both are restored before EBREAK or any debugger-supplied instruction.
    always @* begin
        for (j = 0; j < 10; j = j + 1)
            abstract_word[j] = 32'h00000013;
        abstract_word[9] = command_q[18] ? 32'h00000013 : 32'h00100073;
        if (command_q[17]) begin
            abstract_word[0] = insn_csr(12'h7b3, 0, 10, 3'b001);
            abstract_word[1] = 32'h00000517; // auipc a0,0
            abstract_word[2] = 32'h00c55513; // srli a0,a0,12
            abstract_word[3] = 32'h00c51513; // slli a0,a0,12
            abstract_word[8] = insn_csr(12'h7b3, 10, 0, 3'b010);
            if (command_q[12] && command_q[4:0] != 10) begin
                abstract_word[4] = command_q[16] ?
                    insn_load(command_q[4:0]) :
                    insn_store(command_q[4:0], command_q[22:20]);
            end else begin
                abstract_word[4] = insn_csr(12'h7b2, 0, 8, 3'b001);
                if (command_q[16]) begin
                    abstract_word[5] = insn_load(8);
                    abstract_word[6] = insn_csr(command_q[12] ? 12'h7b3 :
                                               command_q[11:0], 0, 8, 3'b001);
                end else begin
                    abstract_word[5] = insn_csr(command_q[12] ? 12'h7b3 :
                                               command_q[11:0], 8, 0, 3'b010);
                    abstract_word[6] = insn_store(8, command_q[22:20]);
                end
                abstract_word[7] = insn_csr(12'h7b2, 8, 0, 3'b010);
            end
        end
    end

    // All fields not assigned here are tied off, including stickyunavail,
    // ndmresetpending, impebreak, SBA, hart arrays and authentication protocol.
    always @* begin
        dmstatus = 32'h00000083; // authenticated=1, version=3
        dmstatus[9:8] = {2{acknowledged_halted && available}};
        dmstatus[11:10] = {2{!acknowledged_halted && available}};
        dmstatus[13:12] = {2{!available}};
        dmstatus[17:16] = {2{resume_ack_q}};
        dmstatus[19:18] = {2{havereset_q}};
        abstractcs = 32'h08000002;
        abstractcs[12] = busy;
        abstractcs[10:8] = cmderr_q;
        dmi_read = 0;
        if (dmactive_q) begin
            case (req_addr_i)
                7'h04: dmi_read = busy ? 0 : data_q[31:0];
                7'h05: dmi_read = busy ? 0 : data_q[63:32];
                7'h10: dmi_read = {30'b0, ndmreset_q, dmactive_q};
                7'h11: dmi_read = dmstatus;
                7'h12: dmi_read = 32'h00212380;
                7'h13, 7'h40: dmi_read = {31'b0, acknowledged_halted && available};
                7'h16: dmi_read = abstractcs;
                7'h20, 7'h21, 7'h22, 7'h23,
                7'h24, 7'h25, 7'h26, 7'h27:
                    dmi_read = busy ? 0 : progbuf_q[req_addr_i[2:0]];
                default: ;
            endcase
        end else if (req_addr_i == 7'h10) begin
            dmi_read = {31'b0, dmactive_q};
        end
    end

    always @* begin
        mem_rdata_o = 0;
        mem_error_o = 0;
        if (mem_addr_i >= 12'h800 && mem_addr_i < 12'h900) begin
            mem_rdata_o = rom_data;
            mem_error_o = mem_write_i;
        end else if (mem_addr_i >= `KARUDBG_ABSTRACT && mem_addr_i < `KARUDBG_PROGBUF) begin
            mem_rdata_o = {abstract_word[mem_abstract_index + 1'b1],
                           abstract_word[mem_abstract_index]};
            mem_error_o = mem_write_i;
        end else if (mem_addr_i >= `KARUDBG_PROGBUF && mem_addr_i < `KARUDBG_DATA) begin
            mem_rdata_o = {progbuf_q[mem_prog_index + 1'b1], progbuf_q[mem_prog_index]};
        end else if (mem_aligned_addr == `KARUDBG_DATA) begin
            mem_rdata_o = data_q;
        end else if (mem_aligned_addr == `KARUDBG_FLAGS) begin
            mem_rdata_o = {62'b0, resume_req_o,
                           dmactive_q && cmd_state_q == CMD_GO};
            mem_error_o = mem_write_i;
        end else if (mem_aligned_addr == `KARUDBG_WHERETO) begin
            mem_rdata_o = {32'h00100073, insn_jump(20'h0001c)};
            mem_error_o = mem_write_i;
        end else begin
            case (mem_aligned_addr)
                `KARUDBG_HALTED, `KARUDBG_GOING,
                `KARUDBG_RESUMING, `KARUDBG_EXCEPT: ;
                default: mem_error_o = 1;
            endcase
        end
    end

    // The DMI channel reset used by dtmhardreset does not reset DM state or
    // cancel an already accepted abstract command.
    always @(posedge clk) begin
        if (rst || dmi_reset_i) begin
            resp_valid_o <= 0;
            resp_data_o <= 0;
            resp_op_o <= 0;
        end else begin
            if (resp_valid_o && resp_ready_i)
                resp_valid_o <= 0;
            if (dmi_fire) begin
                resp_valid_o <= 1;
                resp_data_o <= req_op_i == 1 ? dmi_read : 0;
                resp_op_o <= req_op_i == 3 ? 2'b10 : 2'b00;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            dmactive_q <= 0;
            halt_q <= 0;
            ndmreset_q <= 0;
            resume_pending_q <= 0;
            resume_ack_q <= 0;
            resuming_seen_q <= 0;
            havereset_q <= 0;
            parked_q <= 0;
            cmd_state_q <= CMD_IDLE;
            cmderr_q <= 0;
            command_q <= 0;
            data_q <= 0;
            for (i = 0; i < 8; i = i + 1) progbuf_q[i] <= 0;
        end else if (!dmactive_q) begin
            halt_q <= 0;
            ndmreset_q <= 0;
            resume_pending_q <= 0;
            resume_ack_q <= 0;
            resuming_seen_q <= 0;
            havereset_q <= 0;
            parked_q <= 0;
            cmd_state_q <= CMD_IDLE;
            cmderr_q <= 0;
            command_q <= 0;
            data_q <= 0;
            for (i = 0; i < 8; i = i + 1) progbuf_q[i] <= 0;
            if (dmi_fire && req_op_i == 2 && req_addr_i == 7'h10)
                dmactive_q <= req_data_i[0];
        end else begin
            if (!hart_halted_i) parked_q <= 0;
            if (mem_halted && hart_halted_i) begin
                parked_q <= 1;
                if (cmd_state_q == CMD_EXEC) cmd_state_q <= CMD_IDLE;
            end
            if (mem_going && cmd_state_q == CMD_GO) begin
                parked_q <= 0;
                cmd_state_q <= CMD_EXEC;
            end
            if (mem_exception && busy && cmderr_q == 0)
                cmderr_q <= 3;
            if (mem_resuming && resume_pending_q)
                resuming_seen_q <= 1;
            if (hart_resume_ack_i && resume_pending_q) begin
                resume_pending_q <= 0;
                resume_ack_q <= 1;
                resuming_seen_q <= 0;
                parked_q <= 0;
            end

            if (mem_fire && mem_write_i &&
                mem_aligned_addr == `KARUDBG_DATA) begin
                for (i = 0; i < 8; i = i + 1)
                    if (mem_be_i[i]) data_q[8*i +: 8] <= mem_wdata_i[8*i +: 8];
            end
            if (mem_fire && mem_write_i &&
                mem_addr_i >= `KARUDBG_PROGBUF && mem_addr_i < `KARUDBG_DATA) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (mem_be_i[i])
                        progbuf_q[mem_prog_index][8*i +: 8] <= mem_wdata_i[8*i +: 8];
                    if (mem_be_i[i+4])
                        progbuf_q[mem_prog_index + 1'b1][8*i +: 8] <= mem_wdata_i[8*i+32 +: 8];
                end
            end

            if (dmi_fire && req_op_i != 0 && req_op_i != 3) begin
                if (busy &&
                    ((req_addr_i >= 7'h04 && req_addr_i <= 7'h05) ||
                     (req_addr_i >= 7'h20 && req_addr_i <= 7'h27) ||
                     (req_op_i == 2 && (req_addr_i == 7'h16 ||
                      req_addr_i == 7'h17 || req_addr_i == 7'h18)))) begin
                    if (cmderr_q == 0) cmderr_q <= 1;
                end else if (req_op_i == 2) begin
                    case (req_addr_i)
                        7'h04: data_q[31:0] <= req_data_i;
                        7'h05: data_q[63:32] <= req_data_i;
                        7'h10: begin
                            dmactive_q <= req_data_i[0];
                            ndmreset_q <= req_data_i[1];
                            if (!busy) begin
                                halt_q <= req_data_i[31];
                                if (req_data_i[28]) havereset_q <= 0;
                                if (req_data_i[30] && !req_data_i[31]) begin
                                    resume_ack_q <= 0;
                                    if (hart_halted_i && parked_q && available)
                                        resume_pending_q <= 1;
                                    resuming_seen_q <= 0;
                                end
                            end
                        end
                        7'h16: cmderr_q <= cmderr_q & ~req_data_i[10:8];
                        7'h17: begin
                            if (cmderr_q == 0) begin
                                if (!command_supported) cmderr_q <= 2;
                                else if (!available || !hart_halted_i ||
                                         !parked_q || resume_pending_q)
                                    cmderr_q <= 4;
                                else begin
                                    command_q <= req_data_i;
                                    if (req_data_i[17] || req_data_i[18])
                                        cmd_state_q <= CMD_GO;
                                end
                            end
                        end
                        7'h20, 7'h21, 7'h22, 7'h23,
                        7'h24, 7'h25, 7'h26, 7'h27:
                            progbuf_q[req_addr_i[2:0]] <= req_data_i;
                        default: ;
                    endcase
                end
            end
            // Reset observation dominates ackhavereset. ndmreset resets the
            // hart/command state, never the DM or transport that issued it.
            if (hart_reset_i || ndmreset_q) begin
                havereset_q <= 1;
                parked_q <= 0;
                resume_ack_q <= 0;
                resume_pending_q <= 0;
                resuming_seen_q <= 0;
                if (busy) begin
                    cmd_state_q <= CMD_IDLE;
                    if (cmderr_q == 0) cmderr_q <= 4;
                end
            end else if (hart_unavailable_i && busy) begin
                cmd_state_q <= CMD_IDLE;
                if (cmderr_q == 0) cmderr_q <= 4;
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (!rst && dmactive_q) begin
            if (hart_resume_ack_i && resume_pending_q && !resuming_seen_q)
                $fatal(1, "karudbg: resume acknowledged before ROM RESUMING");
            if (cmd_state_q == CMD_EXEC && !hart_halted_i && available)
                $fatal(1, "karudbg: hart escaped Debug Mode during command");
        end
    end
    // synthesis translate_on
endmodule
