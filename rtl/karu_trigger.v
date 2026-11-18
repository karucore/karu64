// SPDX-License-Identifier: BSD-2-Clause
// Sdtrig 1.0 debugger-owned mcontrol6 address triggers. Original Karu RTL.
// Configuration-time NAPOT masks keep the running address path to XOR/AND/OR.
`include "karu_ext.vh"
module karu_trigger #(
    parameter integer COUNT = 2,
    parameter integer IW = (COUNT > 1) ? $clog2(COUNT) : 1
) (
    input wire clk, rst, debug_mode_i,
    input wire csr_write_i,
    input wire [11:0] csr_addr_i,
    input wire [63:0] csr_data_i,
    output wire [63:0] csr_data_o,
    input wire [1:0] priv_i,
    input wire virt_i,
    input wire exec_valid_i,
    input wire [63:0] exec_addr_i,
    input wire data_valid_i, data_load_i, data_store_i,
    input wire [63:0] data_addr_i,
    output wire exec_hit_o, data_hit_o, data_armed_o
);
    reg [IW-1:0] selected;
    reg [63:0] control [0:COUNT-1];
    reg [63:0] address [0:COUNT-1];
    reg [63:0] napot_mask [0:COUNT-1];
    wire [COUNT-1:0] exec_hit, data_hit, data_armed;
    assign exec_hit_o = |exec_hit;
    assign data_hit_o = |data_hit;
    assign data_armed_o = |data_armed;
    assign csr_data_o = csr_addr_i == 12'h7a0 ? {{(64-IW){1'b0}}, selected} :
                        csr_addr_i == 12'h7a1 ? control[selected] :
                        csr_addr_i == 12'h7a2 ? address[selected] :
                        csr_addr_i == 12'h7a4 ? 64'h01008040 : 64'b0;
    // Only size=any, select=address, match=equal/NAPOT, no chains/action0.
    // Unsupported active configurations disable the slot. Privilege bits
    // describe the executing instruction (MPRV changes its address, not mode).
    function [63:0] legal_control;
        input [63:0] value;
        input [63:0] addr;
        reg [63:0] result;
        reg unused_fields;
        begin
            unused_fields = &{value,addr,1'b0};
            result = 64'hf000000000000000;
            if (value[63:60] == 4'd6 && value[59] && debug_mode_i &&
                value[15:12] == 4'd1 && !value[21] && !value[11] &&
                value[18:16] == 0 && value[10:7] <= 1 &&
                !(value[7] && (&addr[62:0]))) begin
                result = 64'h6800000000001000;
                result[7] = value[7];
                result[6] = value[6];
`ifdef KARU_EN_S
                result[4] = value[4];
`endif
                result[3:0] = {value[3],value[2:0]};
`ifdef KARU_EN_H
                result[24:23] = value[24:23];
`endif
                result[22] = value[22];
            end
            legal_control = result;
        end
    endfunction
    reg [63:0] legal_address;
    wire [63:0] legal_mask;
    genvar mask_bit;
    generate for (mask_bit=0; mask_bit<64; mask_bit=mask_bit+1) begin : masks
        if (mask_bit == 0) begin : low_bit
            assign legal_mask[mask_bit] = 1'b0;
        end else begin : upper_bit
            assign legal_mask[mask_bit] = !( &legal_address[mask_bit-1:0]);
        end
    end endgenerate
    genvar g;
    generate for (g=0; g<COUNT; g=g+1) begin : slots
        wire mode_enable;
        assign mode_enable = priv_i == 2'd3 ? control[g][6] :
                             virt_i ? (priv_i == 2'd1 ? control[g][24] : control[g][23]) :
                                      (priv_i == 2'd1 ? control[g][4] : control[g][3]);
        wire active;
        assign active = !debug_mode_i && control[g][63:60] == 6 && mode_enable;
        wire [63:0] mask;
        assign mask = control[g][7] ? napot_mask[g] : ~64'b0;
        assign exec_hit[g] = active && control[g][2] && exec_valid_i &&
                            !(((exec_addr_i ^ address[g]) & mask) != 0);
        // Direction is presented throughout the architectural instruction,
        // including before a vector issue. Opposite-direction slots need not
        // serialize its vector memory walk.
        assign data_armed[g] = active &&
                            ((data_load_i && control[g][0]) || (data_store_i && control[g][1]));
        assign data_hit[g] = data_armed[g] && data_valid_i &&
                            ((data_load_i && control[g][0]) || (data_store_i && control[g][1])) &&
                            !(((data_addr_i ^ address[g]) & mask) != 0);
    end endgenerate
    integer i;
    always @(*) begin
        legal_address = csr_data_i;
        // maskmax6=63: NAPOT leaves at least the top address bit compared.
        // Preserve every XLEN bit for disabled/equality slots.
        if (control[selected][63:60] == 6 && control[selected][7] && (&csr_data_i[62:0]))
            legal_address[62] = 1'b0;
    end
    always @(posedge clk) begin
        if (rst) begin
            selected <= 0;
            for (i=0; i<COUNT; i=i+1) begin
                control[i] <= 64'hf000000000000000;
                address[i] <= 0;
                napot_mask[i] <= ~64'd1;
            end
        end else begin
            for (i=0; i<COUNT; i=i+1)
                if (exec_hit[i] || data_hit[i]) control[i][22] <= 1'b1;
            if (csr_write_i) begin
                if (csr_addr_i == 12'h7a0) begin
                    // Leave out-of-range tselect writes unchanged. Enumeration
                    // terminates when the requested slot does not read back.
                    if (csr_data_i[63:IW] == 0) selected <= csr_data_i[IW-1:0];
                end else if (debug_mode_i || !control[selected][59]) begin
                    if (csr_addr_i == 12'h7a1)
                        control[selected] <= legal_control(csr_data_i, address[selected]);
                    if (csr_addr_i == 12'h7a2) begin
                        address[selected] <= legal_address;
                        napot_mask[selected] <= legal_mask;
                    end
                end
            end
        end
    end
// synthesis translate_off
    wire [64*COUNT-1:0] debug_controls;
    genvar observer;
    generate for(observer=0;observer<COUNT;observer=observer+1)begin : observe_control
        assign debug_controls[observer*64+:64]=control[observer];
    end endgenerate
    initial if (COUNT != 2 && COUNT != 4) $fatal(1,"karu_trigger COUNT must be 2 or 4");
    always @(posedge clk) if (!rst && debug_mode_i && (exec_hit_o || data_hit_o))
        $fatal(1,"trigger fired in Debug Mode");
// synthesis translate_on
endmodule
