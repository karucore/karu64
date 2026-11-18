// SPDX-License-Identifier: BSD-3-Clause
// SiFive-style nested-TAP framing used by mainline OpenOCD's
// riscv use_bscan_tunnel 5 0. Original Karu implementation; protocol reference:
// openocd-org/openocd cb0c224e936091156ecf3025ba05657408ed64c8,
// src/target/riscv/riscv.c (dtmcs_scan_via_bscan).
//
// BSCAN scan: IR/DR selector (0/1), seven-bit payload width, payload,
// one extra DR turnaround bit, then three zero padding bits. Both interfaces
// use TCK; only the existing DTM's mailbox crosses to the system clock.
module karudbg_bscan_tunnel (
    input wire tck,
    input wire reset_i,
    input wire select_i,
    input wire capture_i,
    input wire shift_i,
    input wire tdi_i,
    output reg tdo_o,
    output wire inner_tck_o,
    output reg inner_tms_o,
    output wire inner_tdi_o,
    output wire inner_trst_n_o,
    input wire inner_tdo_i
);
    localparam [2:0] WAIT=0, HEADER=1, PAYLOAD=2, EXIT=3, UPDATE=4, PAD=5;
    reg [2:0] phase;
    reg [2:0] header_bit;
    reg data_scan;
    reg [6:0] width;
    reg [6:0] payload_bit;
    // Inner TAP reset, one flop. A frame that is cut short can leave the
    // inner TAP in a Shift/Exit state. Five TMS=1 clocks would pass through
    // Update-DR and commit the partial DMI request, so the next frame's
    // capture instead pulses the inner TRST for one TCK. The inner TAP then
    // reaches Test-Logic-Reset without Update-DR, and the header's leading
    // TMS=0 bits take it to Run-Test/Idle before the header leaves Idle.
    reg inner_trst_n_q;

    assign inner_tck_o = tck;
    assign inner_tdi_o = tdi_i;
    assign inner_trst_n_o = inner_trst_n_q;

    always @* begin
        inner_tms_o = 1'b0;
        if (select_i && shift_i) begin
            if (phase == HEADER) begin
                // Leave Run-Test/Idle late enough that Capture-IR/DR occurs
                // on the final header edge, immediately before payload.
                if (header_bit == 4 && !data_scan) inner_tms_o = 1'b1;
                if (header_bit == 5) inner_tms_o = 1'b1;
            end else if (phase == PAYLOAD)
                inner_tms_o = payload_bit == width - 1'b1;
            else if (phase == EXIT)
                inner_tms_o = 1'b1;
        end
    end

    always @(posedge tck or posedge reset_i) begin
        if (reset_i) begin
            phase <= WAIT;
            header_bit <= 0;
            data_scan <= 0;
            width <= 0;
            payload_bit <= 0;
            tdo_o <= 0;
            inner_trst_n_q <= 0;
        end else begin
            // OpenOCD's nested tunnel accounts for this one-bit TDO skew.
            tdo_o <= inner_tdo_i;
            inner_trst_n_q <= 1'b1;
            if (select_i && capture_i) begin
                // WAIT: no frame since reset. PAD: the last frame completed.
                if (phase != WAIT && phase != PAD) inner_trst_n_q <= 1'b0;
                phase <= HEADER;
                header_bit <= 0;
                width <= 0;
                payload_bit <= 0;
            end else if (select_i && shift_i) begin
                case (phase)
                    HEADER: begin
                        if (header_bit == 0) data_scan <= tdi_i;
                        else width[header_bit - 1'b1] <= tdi_i;
                        if (header_bit == 7) phase <= PAYLOAD;
                        else header_bit <= header_bit + 1'b1;
                    end
                    PAYLOAD: begin
                        if (payload_bit == width - 1'b1) phase <= EXIT;
                        else payload_bit <= payload_bit + 1'b1;
                    end
                    EXIT: phase <= UPDATE;
                    UPDATE: phase <= PAD;
                    default: phase <= phase;
                endcase
            end
        end
    end

    // synthesis translate_off
    // The resynchronizing reset is a single-TCK pulse issued only at the
    // capture that starts a frame after an incomplete one.
    reg chk_trst_n_q;
    always @(posedge tck or posedge reset_i) begin
        if (reset_i) chk_trst_n_q <= 1'b1;
        else begin
            chk_trst_n_q <= inner_trst_n_q;
            if (!inner_trst_n_q && !chk_trst_n_q)
                $fatal(1, "karudbg_bscan_tunnel: inner TRST held longer than one TCK");
        end
    end
    // synthesis translate_on
endmodule
