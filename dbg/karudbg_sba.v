// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright 2026 Markku-Juhani O. Saarinen.
// SPDX-License-Identifier: SHL-0.51
// Adapted from pulp-platform/riscv-dbg src/dm_sba.sv and src/dm_csrs.sv at
// 643607e19df3435cfd77cc56143e2637f5900a6e. See LICENSE.Solderpad.
// Karu adaptation: synchronous reset, Debug 1.0 success-only increment,
// native-width single requests, and explicit ownership across DM deactivation.
//
// req_valid_o && req_ready_i transfers ownership to the platform adapter.
// The adapter must finish/drain accepted traffic even when active_i becomes
// zero, and return a response only after any RAM coherence maintenance.
// Withdrawal before acceptance cancels a request, including its issue hold.
// bus_reset_i resets the hart AND affected fabric: it cancels ownership.
// DMI/TAP channel reset deliberately has no connection to this engine.
// Request data and response data are right-justified, not AXI lane shifted.
module karudbg_sba #(
    parameter SBASIZE = 32
) (
    input wire clk,
    input wire rst,
    input wire active_i,
    input wire bus_reset_i,
    input wire dmi_valid_i,
    input wire [1:0] dmi_op_i,
    input wire [6:0] dmi_addr_i,
    input wire [31:0] dmi_data_i,
    output reg [31:0] dmi_data_o,
    output wire req_valid_o,
    input wire req_ready_i,
    output wire [63:0] req_addr_o,
    output wire [63:0] req_data_o,
    output wire [2:0] req_size_o,
    output wire req_write_o,
    input wire resp_valid_i,
    output wire resp_ready_o,
    input wire [63:0] resp_data_i,
    input wire [2:0] resp_error_i
);
    localparam [1:0] IDLE = 0, REQUEST = 1, RESPONSE = 2;
    localparam [6:0] ADDRESS_BITS = SBASIZE;
    localparam [63:0] ADDRESS_MASK = 64'hffffffffffffffff >> (64-SBASIZE);
    reg [1:0] state_q;
    reg abandoned_q;
    reg [63:0] address_q, data_q;
    reg readonaddr_q, readondata_q, increment_q;
    reg [2:0] access_q, error_q;
    reg busyerror_q;
    reg write_q;
    wire busy, address_low_write, data_low_write, data_low_read;
    wire start, start_write;
    wire [63:0] start_address, start_data;
    wire [63:0] increment;
    wire [2:0] align_mask;

    assign busy = state_q != IDLE;
    assign req_valid_o = state_q == REQUEST && active_i && !bus_reset_i && !rst;
    assign req_addr_o = address_q;
    assign req_data_o = data_q;
    assign req_size_o = access_q;
    assign req_write_o = write_q;
    assign resp_ready_o = state_q == RESPONSE && !bus_reset_i && !rst;
    assign address_low_write = dmi_valid_i && dmi_op_i == 2 && dmi_addr_i == 7'h39;
    assign data_low_write = dmi_valid_i && dmi_op_i == 2 && dmi_addr_i == 7'h3c;
    assign data_low_read = dmi_valid_i && dmi_op_i == 1 && dmi_addr_i == 7'h3c;
    assign start = active_i && !busy && error_q == 0 && !busyerror_q &&
        ((address_low_write && readonaddr_q) || data_low_write ||
         (data_low_read && readondata_q));
    assign start_write = data_low_write;
    assign start_address = address_low_write ?
        ((address_q & 64'hffffffff00000000) | {32'b0, dmi_data_i}) & ADDRESS_MASK : address_q;
    assign start_data = data_low_write ? {data_q[63:32], dmi_data_i} : data_q;
    // Bounded shifts only: no runtime division, modulo or unbounded decode.
    assign align_mask = access_q == 0 ? 3'b000 : access_q == 1 ? 3'b001 :
                        access_q == 2 ? 3'b011 : 3'b111;
    assign increment = access_q == 0 ? 64'd1 : access_q == 1 ? 64'd2 :
                       access_q == 2 ? 64'd4 : 64'd8;

    always @* begin
        dmi_data_o = 0;
        if (active_i) begin
            case (dmi_addr_i)
                7'h38: dmi_data_o = {3'd1, 6'b0, busyerror_q, busy,
                    readonaddr_q, access_q, increment_q, readondata_q,
                    error_q, ADDRESS_BITS, 5'b01111};
                7'h39: dmi_data_o = address_q[31:0];
                7'h3a: if (SBASIZE > 32) dmi_data_o = address_q[63:32];
                7'h3c: if (!busy && error_q == 0 && !busyerror_q)
                    dmi_data_o = data_q[31:0];
                7'h3d: if (!busy) dmi_data_o = data_q[63:32];
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            abandoned_q <= 0;
            address_q <= 0;
            data_q <= 0;
            readonaddr_q <= 0;
            readondata_q <= 0;
            increment_q <= 0;
            access_q <= 2;
            error_q <= 0;
            busyerror_q <= 0;
            write_q <= 0;
        end else begin
            // Deactivation resets architectural state, but cannot relinquish
            // ownership of an already accepted bus transaction/coherence job.
            if (!active_i) begin
                address_q <= 0;
                data_q <= 0;
                readonaddr_q <= 0;
                readondata_q <= 0;
                increment_q <= 0;
                access_q <= 2;
                error_q <= 0;
                busyerror_q <= 0;
                if (state_q == REQUEST) state_q <= IDLE;
                if (state_q == RESPONSE) abandoned_q <= 1;
            end

            if (active_i && dmi_valid_i && (dmi_op_i == 1 || dmi_op_i == 2)) begin
                case (dmi_addr_i)
                    // A busy SBCS write is ignored. Debug 1.0 leaves this
                    // case undefined; it never mutates a live transaction.
                    7'h38: if (dmi_op_i == 2 && !busy) begin
                        readonaddr_q <= dmi_data_i[20];
                        access_q <= dmi_data_i[19:17];
                        increment_q <= dmi_data_i[16];
                        readondata_q <= dmi_data_i[15];
                        busyerror_q <= busyerror_q && !dmi_data_i[22];
                        error_q <= error_q & ~dmi_data_i[14:12];
                    end
                    7'h39: if (dmi_op_i == 2) begin
                        if (busy) busyerror_q <= 1;
                        else address_q <= start_address;
                    end
                    7'h3a: if (SBASIZE > 32 && dmi_op_i == 2) begin
                        if (busy) busyerror_q <= 1;
                        else address_q <= {dmi_data_i, address_q[31:0]} & ADDRESS_MASK;
                    end
                    7'h3c: if (error_q == 0 && !busyerror_q) begin
                        if (busy) busyerror_q <= 1;
                        else if (dmi_op_i == 2) data_q <= start_data;
                    end
                    7'h3d: begin
                        if (busy) busyerror_q <= 1;
                        else if (dmi_op_i == 2) data_q[63:32] <= dmi_data_i;
                    end
                    default: ;
                endcase
            end

            if (start) begin
                if (access_q > 3) error_q <= 4;
                else if ((start_address[2:0] & align_mask) != 0) error_q <= 3;
                else begin
                    state_q <= REQUEST;
                    abandoned_q <= 0;
                    write_q <= start_write;
                end
            end
            if (req_valid_o && req_ready_i) state_q <= RESPONSE;
            if (resp_valid_i && resp_ready_o) begin
                state_q <= IDLE;
                if (active_i && !abandoned_q) begin
                    if (resp_error_i != 0) error_q <= resp_error_i;
                    else begin
                        if (!write_q) data_q <= resp_data_i;
                        if (increment_q) address_q <= (address_q + increment) & ADDRESS_MASK;
                    end
                end
                abandoned_q <= 0;
            end
            // This reset is valid only when the affected platform bus resets
            // too. Unlike DMI reset, it can abandon accepted ownership.
            if (bus_reset_i) begin
                state_q <= IDLE;
                abandoned_q <= 0;
                if (active_i && busy) error_q <= 7;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (SBASIZE < 32 || SBASIZE > 64)
            $fatal(1, "karudbg_sba: SBASIZE must be 32..64");
    end
    // SBAR1..4: independent handshake ownership, cancellation and stable
    // request payload. The monitor is not reconstructed from the FSM state.
    reg sbar_owned, sbar_wait;
    reg [131:0] sbar_request;
    always @(posedge clk) begin
        if (rst || bus_reset_i) begin
            sbar_owned <= 0;
            sbar_wait <= 0;
        end else begin
            if (state_q == 2'b11)
                $fatal(1, "SBAR1 invalid ownership state");
            if (resp_ready_o !== sbar_owned)
                $fatal(1, "SBAR2 response ownership differs from accepted request");
            if (req_valid_o && sbar_owned)
                $fatal(1, "SBAR2 second request with outstanding owner");
            if (sbar_wait && active_i &&
                (!req_valid_o || {req_addr_o,req_data_o,req_size_o,req_write_o} !== sbar_request))
                $fatal(1, "SBAR3 stalled request changed");
            if (!active_i && req_valid_o)
                $fatal(1, "SBAR4 inactive request was not withdrawn");
            sbar_wait <= req_valid_o && !req_ready_i;
            sbar_request <= {req_addr_o,req_data_o,req_size_o,req_write_o};
            if (req_valid_o && req_ready_i) sbar_owned <= 1;
            if (resp_valid_i && resp_ready_o) sbar_owned <= 0;
        end
    end
    // synthesis translate_on
endmodule
