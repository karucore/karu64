// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright 2026 Markku-Juhani O. Saarinen.
// SPDX-License-Identifier: SHL-0.51
// Origin: pulp-platform/riscv-dbg, src/dmi_cdc.sv, revision
// 643607e19df3435cfd77cc56143e2637f5900a6e.
// https://github.com/pulp-platform/riscv-dbg/blob/643607e19df3435cfd77cc56143e2637f5900a6e/src/dmi_cdc.sv
// Adaptation: bounded single-outstanding four-phase bundled-data mailbox,
// Verilog-2001; transport resets flush the DMI channel without resetting DM.
// Solderpad Hardware License 0.51; see LICENSE.Solderpad.

module karudbg_cdc (
    input wire clk, input wire rst,
    input wire tck, input wire trst_n, input wire clear_i,
    input wire t_req_valid_i, output wire t_req_ready_o,
    input wire [40:0] t_req_i,
    output wire t_resp_valid_o, input wire t_resp_ready_i,
    output wire [33:0] t_resp_o,
    output wire req_valid_o, input wire req_ready_i,
    output wire [40:0] req_o,
    input wire resp_valid_i, output wire resp_ready_o, output wire dmi_reset_o,
    input wire [33:0] resp_i
);
    wire reset_n;
    assign reset_n = trst_n && !rst;
    reg request_level, clear_level;
    reg [40:0] request_payload;
    reg response_level, clear_ack;
    reg [33:0] response_payload;
    (* ASYNC_REG = "TRUE" *) reg resp_sync1, resp_sync2;
    (* ASYNC_REG = "TRUE" *) reg ack_sync1, ack_sync2;
    (* ASYNC_REG = "TRUE" *) reg req_sync1, req_sync2;
    (* ASYNC_REG = "TRUE" *) reg clear_sync1, clear_sync2;
    localparam [1:0] IDLE=0, ISSUE=1, WAIT_RESP=2, WAIT_DROP=3;
    reg [1:0] state;
    reg [40:0] core_payload;

    assign t_req_ready_o = !request_level && !resp_sync2 &&
        !clear_level && !ack_sync2 && !clear_i;
    assign t_resp_valid_o = request_level && resp_sync2 &&
        !clear_level && !clear_i;
    assign t_resp_o = response_payload;
    assign req_valid_o = state == ISSUE && !clear_sync2;
    assign req_o = core_payload;
    assign resp_ready_o = state == WAIT_RESP;
    assign dmi_reset_o = clear_sync2;

    // Only handshake levels cross through synchronizers. Bundled payloads
    // remain fixed from before assertion until the return handshake completes.
    always @(posedge tck or negedge reset_n) begin
        if (!reset_n) begin
            resp_sync1 <= 0; resp_sync2 <= 0;
            ack_sync1 <= 0; ack_sync2 <= 0;
            request_level <= 0;
            clear_level <= 1;
        end else begin
            resp_sync1 <= response_level; resp_sync2 <= resp_sync1;
            ack_sync1 <= clear_ack; ack_sync2 <= ack_sync1;
            if (clear_i) begin
                clear_level <= 1;
                request_level <= 0;
            end else if (clear_level) begin
                if (ack_sync2) clear_level <= 0;
            end else begin
                if (t_req_valid_i && t_req_ready_o) begin
                    request_level <= 1;
                end
                if (t_resp_valid_o && t_resp_ready_i)
                    request_level <= 0;
            end
        end
    end

    // Do not reset the bundled payload on TRST. Its request level can remain
    // visible in the destination synchronizer while a clear is propagating;
    // changing the data then could turn an old request into a different DMI
    // write. Valid/clear handshakes make uninitialized idle payload harmless.
    always @(posedge tck) begin
        if (t_req_valid_i && t_req_ready_o)
            request_payload <= t_req_i;
    end

    // Core-side reset is synchronous. Resetting the transport flushes only
    // the DM's DMI response channel, not DM registers or an accepted abstract
    // command. This lets dtmhardreset recover even if an old request never
    // responds, and prevents a stale response being mistaken for a new one.
    always @(posedge clk) begin
        if (rst) begin
            req_sync1 <= 0; req_sync2 <= 0;
            clear_sync1 <= 1; clear_sync2 <= 1;
            response_level <= 0; response_payload <= 0;
            clear_ack <= 0;
            core_payload <= 0;
            state <= IDLE;
        end else begin
            req_sync1 <= request_level; req_sync2 <= req_sync1;
            clear_sync1 <= clear_level; clear_sync2 <= clear_sync1;
            if (clear_sync2) begin
                state <= IDLE;
                response_level <= 0;
                if (!req_sync2) clear_ack <= 1;
            end else if (clear_ack) begin
                state <= IDLE;
                clear_ack <= 0;
            end else case (state)
                IDLE: begin
                    response_level <= 0;
                    if (req_sync2) begin
                        core_payload <= request_payload;
                        state <= ISSUE;
                    end
                end
                ISSUE: if (req_ready_i) state <= WAIT_RESP;
                WAIT_RESP: if (resp_valid_i) begin
                    response_payload <= resp_i;
                    response_level <= 1;
                    state <= WAIT_DROP;
                end
                WAIT_DROP: if (!req_sync2) begin
                    response_level <= 0;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
