// SPDX-License-Identifier: BSD-3-Clause
// Behavioral six-bit Xilinx outer TAP for testing BSCANE2 USER4 framing.
// Not synthesizable platform RTL and not a transistor-level primitive model.
module xilinx_tap_model (
    input wire tck, input wire tms, input wire tdi, input wire trst_n,
    output reg tdo,
    output wire capture_o, output wire shift_o, output wire select_o,
    output wire reset_o, output wire drck_o, input wire user_tdo_i
);
    localparam [3:0] TLR=0, IDLE=1, SELDR=2, CAPDR=3, SHDR=4,
        EX1DR=5, PAUDR=6, EX2DR=7, UPDR=8, SELIR=9, CAPIR=10,
        SHIR=11, EX1IR=12, PAUIR=13, EX2IR=14, UPIR=15;
    reg [3:0] state, next_state;
    reg [5:0] ir, ir_shift;
    reg [31:0] id_shift;
    reg bypass;
    reg drck_enable;
    reg [3:0] bscan_state;
    reg [5:0] bscan_ir;
    assign capture_o=bscan_state==CAPDR;
    assign shift_o=bscan_state==SHDR;
    assign select_o=bscan_ir==6'h23;
    assign reset_o=!trst_n || state==TLR;
    // The primitive's DRCK is glitch-free and stops in Pause-DR or when USER4
    // is not selected. Model its enable on the falling edge.
    assign drck_o=tck && drck_enable;
    always @(negedge tck or negedge trst_n)
        if(!trst_n) begin drck_enable<=0;bscan_state<=TLR;bscan_ir<=6'h09;end
        else begin
            bscan_state<=state;
            bscan_ir<=ir;
            drck_enable<=ir==6'h23 && (state==CAPDR || state==SHDR);
        end
    always @* begin
        case(state)
            TLR:next_state=tms?TLR:IDLE;
            IDLE:next_state=tms?SELDR:IDLE;
            SELDR:next_state=tms?SELIR:CAPDR;
            CAPDR:next_state=tms?EX1DR:SHDR;
            SHDR:next_state=tms?EX1DR:SHDR;
            EX1DR:next_state=tms?UPDR:PAUDR;
            PAUDR:next_state=tms?EX2DR:PAUDR;
            EX2DR:next_state=tms?UPDR:SHDR;
            UPDR:next_state=tms?SELDR:IDLE;
            SELIR:next_state=tms?TLR:CAPIR;
            CAPIR:next_state=tms?EX1IR:SHIR;
            SHIR:next_state=tms?EX1IR:SHIR;
            EX1IR:next_state=tms?UPIR:PAUIR;
            PAUIR:next_state=tms?EX2IR:PAUIR;
            EX2IR:next_state=tms?UPIR:SHIR;
            UPIR:next_state=tms?SELDR:IDLE;
            default:next_state=TLR;
        endcase
    end
    always @(posedge tck or negedge trst_n) begin
        if(!trst_n) begin
            state<=TLR;ir<=6'h09;ir_shift<=0;
            id_shift<=32'h04b31093;bypass<=0;
        end else begin
            state<=next_state;
            if(state==TLR) ir<=6'h09;
            if(state==CAPIR) ir_shift<=6'b000001;
            if(state==SHIR) ir_shift<={tdi,ir_shift[5:1]};
            if(state==UPIR) ir<=ir_shift;
            if(state==CAPDR) begin id_shift<=32'h04b31093;bypass<=0;end
            if(state==SHDR) begin id_shift<={tdi,id_shift[31:1]};bypass<=tdi;end
        end
    end
    always @(negedge tck or negedge trst_n) begin
        if(!trst_n) tdo<=0;
        else if(state==SHIR) tdo<=ir_shift[0];
        else if(ir==6'h09) tdo<=id_shift[0];
        else if(ir==6'h23) tdo<=user_tdo_i;
        else tdo<=bypass;
    end
endmodule
