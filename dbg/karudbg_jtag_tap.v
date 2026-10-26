// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright 2026 Markku-Juhani O. Saarinen.
// SPDX-License-Identifier: SHL-0.51
// Origin: pulp-platform/riscv-dbg, src/dmi_jtag_tap.sv, revision
// 643607e19df3435cfd77cc56143e2637f5900a6e.
// https://github.com/pulp-platform/riscv-dbg/blob/643607e19df3435cfd77cc56143e2637f5900a6e/src/dmi_jtag_tap.sv
// Adaptation: fixed five-bit IR, Verilog-2001, no external clock cells.
// Solderpad Hardware License 0.51; see LICENSE.Solderpad.

module karudbg_jtag_tap #(
    // Temporary integration ID, not a claim to an assigned JEDEC identity.
    parameter [31:0] IDCODE = 32'h0000_0db3
) (
    input wire tck, input wire tms, input wire tdi, input wire trst_n,
    output reg tdo, output reg tdo_oe,
    output wire capture_o, output wire shift_o, output wire update_o,
    output wire reset_o, output wire dtmcs_select_o, output wire dmi_select_o,
    input wire dtmcs_tdo_i, input wire dmi_tdo_i
);
    localparam [3:0] TLR=0, IDLE=1, SELDR=2, CAPDR=3, SHDR=4,
        EX1DR=5, PAUDR=6, EX2DR=7, UPDR=8, SELIR=9, CAPIR=10,
        SHIR=11, EX1IR=12, PAUIR=13, EX2IR=14, UPIR=15;
    reg [3:0] state, next_state;
    reg [4:0] ir, ir_shift;
    reg [31:0] id_shift;
    reg bypass;
    reg tdo_mux;

    assign capture_o = state == CAPDR;
    assign shift_o = state == SHDR;
    assign update_o = state == UPDR;
    assign reset_o = state == TLR;
    assign dtmcs_select_o = ir == 5'h10;
    assign dmi_select_o = ir == 5'h11;

    always @* begin
        case (state)
            TLR: next_state = tms ? TLR : IDLE;
            IDLE: next_state = tms ? SELDR : IDLE;
            SELDR: next_state = tms ? SELIR : CAPDR;
            CAPDR: next_state = tms ? EX1DR : SHDR;
            SHDR: next_state = tms ? EX1DR : SHDR;
            EX1DR: next_state = tms ? UPDR : PAUDR;
            PAUDR: next_state = tms ? EX2DR : PAUDR;
            EX2DR: next_state = tms ? UPDR : SHDR;
            UPDR: next_state = tms ? SELDR : IDLE;
            SELIR: next_state = tms ? TLR : CAPIR;
            CAPIR: next_state = tms ? EX1IR : SHIR;
            SHIR: next_state = tms ? EX1IR : SHIR;
            EX1IR: next_state = tms ? UPIR : PAUIR;
            PAUIR: next_state = tms ? EX2IR : PAUIR;
            EX2IR: next_state = tms ? UPIR : SHIR;
            UPIR: next_state = tms ? SELDR : IDLE;
            default: next_state = TLR;
        endcase
    end

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            state <= TLR;
            ir <= 5'h01;
            ir_shift <= 0;
            id_shift <= IDCODE;
            bypass <= 0;
        end else begin
            state <= next_state;
            if (state == TLR) ir <= 5'h01;
            if (state == CAPIR) ir_shift <= 5'b00001;
            if (state == SHIR) ir_shift <= {tdi, ir_shift[4:1]};
            if (state == UPIR) ir <= ir_shift;
            if (state == CAPDR) begin
                id_shift <= IDCODE;
                bypass <= 0;
            end
            if (state == SHDR) begin
                id_shift <= {tdi, id_shift[31:1]};
                bypass <= tdi;
            end
        end
    end

    always @* begin
        if (state == SHIR) tdo_mux = ir_shift[0];
        else case (ir)
            5'h01: tdo_mux = id_shift[0];
            5'h10: tdo_mux = dtmcs_tdo_i;
            5'h11: tdo_mux = dmi_tdo_i;
            default: tdo_mux = bypass;
        endcase
    end

    // JTAG data is sampled on rising edges; change it only on falling edges.
    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            tdo <= 0;
            tdo_oe <= 0;
        end else begin
            tdo <= tdo_mux;
            tdo_oe <= state == SHIR || state == SHDR;
        end
    end
endmodule
