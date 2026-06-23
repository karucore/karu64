//  karu_m.v
//  RV64M functional unit. Multiplier and divider cycle counts are
//  independently configurable at compile time via the central
//  karu_cfg.vh header. See that file for the full flag/override
//  priority; the effective per-unit flags read here are:
//
//    KARU_M_MUL_CYCLES = 1   (default, combinational 64x64 mul, big)
//                      = 4   (radix-2^16, 16 bits/cycle, medium area)
//                      = 16  (radix-2^4,  4  bits/cycle, small area)
//                      = 64  (radix-2,    1  bit/cycle,  smallest)
//    KARU_M_DIV_CYCLES = 1   (default, combinational, big)
//                      = 64  (restoring bit-serial, smallest)
//
//  Both can be defaulted by the master KARU_MUL_CYCLES / KARU_DIV_CYCLES.
//
//  Multiplier algorithm (radix-2^K shift-and-add, K = 64/MUL_CYCLES):
//    acc starts at {64'b0, mag_b}; each cycle consumes K bits of
//    multiplier from acc[K-1:0], computes partial = mag_a * those K
//    bits, adds partial to acc[127:64] (in a 64+K-bit add that fits
//    by construction: max sum = 2^(64+K) - 2^K), and right-shifts
//    the 128-bit window by K. After MUL_CYCLES iterations, acc holds
//    the full 128-bit product.
//
//  Divider algorithm: restoring divide, 1 bit per cycle, unchanged.
//
//  sub encoding (mirrors RV64M funct3):
//    0 MUL   1 MULH   2 MULHSU   3 MULHU
//    4 DIV   5 DIVU   6 REM      7 REMU

`include "karu_uop_defs.vh"
`include "karu_cfg.vh"

module karu_m (
    input  wire         clk,
    input  wire         rst,

    //  -- request port (pulse req for one cycle when busy is low) --
    input  wire         req,
    output wire         busy,
    input  wire [4:0]   sub,
    input  wire         is_w,
    input  wire [63:0]  op1,
    input  wire [63:0]  op2,

    //  -- completion: one-cycle done pulse with rd_v held this cycle --
    output reg          done,
    output reg [63:0]   rd_v
);
    //  Clamp user-requested cycle count to a value that divides 64
    //  cleanly. Anything else rounds DOWN to the nearest valid value
    //  (except 1 which stays 1, meaning combinational).
    localparam MUL_REQ = `KARU_M_MUL_CYCLES;
    localparam DIV_REQ = `KARU_M_DIV_CYCLES;
    localparam MUL_C =
        (MUL_REQ == 1)  ? 1  :
        (MUL_REQ <= 2)  ? 2  :
        (MUL_REQ <= 4)  ? 4  :
        (MUL_REQ <= 8)  ? 8  :
        (MUL_REQ <= 16) ? 16 :
        (MUL_REQ <= 32) ? 32 : 64;
    localparam DIV_C = (DIV_REQ == 1) ? 1 : 64;
    localparam MUL_K = (MUL_C == 1) ? 64 : (64 / MUL_C);
    localparam ANY_ITER = (MUL_C != 1) || (DIV_C != 1);

    //  ==================================================================
    //  Common combinational setup (same as the single-cycle version)
    //  ==================================================================
    wire sub_is_div  = sub[2];
    wire sub_is_rem  = sub[2] & sub[1];
    wire sub_is_high = !sub[2] & (sub[1] | sub[0]);
    wire sub_a_signed = (sub == `M_MULH) || (sub == `M_MULHSU)
                     || (sub == `M_DIV)  || (sub == `M_REM);
    wire sub_b_signed = (sub == `M_MULH)
                     || (sub == `M_DIV)  || (sub == `M_REM);

    wire [63:0] op1_ext = is_w
        ? (sub_a_signed ? {{32{op1[31]}}, op1[31:0]} : {32'b0, op1[31:0]})
        : op1;
    wire [63:0] op2_ext = is_w
        ? (sub_b_signed ? {{32{op2[31]}}, op2[31:0]} : {32'b0, op2[31:0]})
        : op2;

    wire a_neg = sub_a_signed & op1_ext[63];
    wire b_neg = sub_b_signed & op2_ext[63];

    wire [63:0] mag_a_in = a_neg ? (~op1_ext + 64'b1) : op1_ext;
    wire [63:0] mag_b_in = b_neg ? (~op2_ext + 64'b1) : op2_ext;

    wire neg_in =
        sub_is_div
            ? (sub_is_rem ? a_neg : (a_neg ^ b_neg))
            : (sub == `M_MULH)   ? (a_neg ^ b_neg)
            : (sub == `M_MULHSU) ? a_neg
                                  : 1'b0;

    wire div_by_zero_in = sub_is_div && (op2_ext == 64'b0);

    //  ==================================================================
    //  Combinational results
    //  Used directly when the requested op is configured as 1-cycle.
    //  ==================================================================
    wire [127:0] mul_full_comb = mag_a_in * mag_b_in;
    wire [63:0]  quot_mag_comb = div_by_zero_in ? 64'b0 : (mag_a_in / mag_b_in);
    wire [63:0]  rem_mag_comb  = div_by_zero_in ? 64'b0 : (mag_a_in % mag_b_in);

    wire [127:0] mul_neg128_comb  = ~mul_full_comb + 128'b1;
    wire [127:0] mul_signed_comb  = neg_in ? mul_neg128_comb : mul_full_comb;
    wire [63:0]  quot_signed_comb = neg_in ? (~quot_mag_comb + 64'b1) : quot_mag_comb;
    wire [63:0]  rem_signed_comb  = neg_in ? (~rem_mag_comb  + 64'b1) : rem_mag_comb;

    wire [63:0] base_result_comb =
        sub_is_div ? (sub_is_rem ? rem_signed_comb : quot_signed_comb)
                   : (sub_is_high ? mul_signed_comb[127:64]
                                  : mul_full_comb[63:0]);

    wire [63:0] edge_result_comb =
        div_by_zero_in
            ? (sub_is_rem ? op1_ext : 64'hFFFF_FFFF_FFFF_FFFF)
            : base_result_comb;

    wire [63:0] final_result_comb =
        is_w ? {{32{edge_result_comb[31]}}, edge_result_comb[31:0]} : edge_result_comb;

    //  ==================================================================
    //  Iterative path + state machine
    //  ==================================================================
    //  FSM state encodings hoisted to module scope -- Genus rejects localparam
    //  declarations inside generate blocks; used by the g_iter always below.
    localparam S_IDLE = 1'b0, S_RUN = 1'b1;
    generate
    if (ANY_ITER) begin : g_iter
        reg          state;
        reg [6:0]    cnt;                   //  enough for 64
        reg          op_is_div_q, op_is_rem_q, op_is_high_q, op_is_w_q;
        reg          neg_result_q, edge_zero_q;
        reg [63:0]   dividend_q;
        reg [63:0]   mag_a, mag_b;
        reg [127:0]  acc;

        assign busy = (state != S_IDLE);

        //  ---- mul step (K bits/cycle) ----
        //  mul_partial fits in K+64 bits (K-bit times 64-bit = at most K+64).
        //  mul_sum width is K+64 too: max(acc[127:64]) + max(mul_partial) =
        //  (2^64 - 1) + (2^(64+K) - 2^64) = 2^(64+K) - 1, fits.
        wire [MUL_K+63:0] mul_partial = mag_a * acc[MUL_K-1:0];
        wire [MUL_K+63:0] mul_sum     = acc[127:64] + mul_partial;
        wire [127:0]      mul_next    = { mul_sum, acc[63:MUL_K] };

        //  ---- div step (1 bit/cycle, restoring) ----
        wire [64:0]  div_top  = { acc[127:64], acc[63] };
        wire [64:0]  div_sub  = div_top - { 1'b0, mag_b };
        wire         div_take = !div_sub[64];
        wire [127:0] div_next = div_take
            ? { div_sub[63:0], acc[62:0], 1'b1 }
            : { div_top[63:0], acc[62:0], 1'b0 };

        wire [127:0] acc_next = op_is_div_q ? div_next : mul_next;

        //  ---- result formation ----
        wire [127:0] acc_neg128 = ~acc_next + 128'b1;
        wire [127:0] acc_signed = neg_result_q ? acc_neg128 : acc_next;

        wire [63:0] mul_low      = acc_next[63:0];
        wire [63:0] mul_high     = acc_signed[127:64];
        wire [63:0] q_mag        = acc_next[63:0];
        wire [63:0] r_mag        = acc_next[127:64];
        wire [63:0] div_quot_out = neg_result_q ? (~q_mag + 64'b1) : q_mag;
        wire [63:0] div_rem_out  = neg_result_q ? (~r_mag + 64'b1) : r_mag;

        wire [63:0] base_result =
            op_is_div_q ? (op_is_rem_q ? div_rem_out : div_quot_out)
                       : (op_is_high_q ? mul_high : mul_low);

        wire [63:0] edge_result =
            edge_zero_q
                ? (op_is_rem_q ? dividend_q : 64'hFFFF_FFFF_FFFF_FFFF)
                : base_result;

        wire [63:0] iter_final_result =
            op_is_w_q ? {{32{edge_result[31]}}, edge_result[31:0]} : edge_result;

        //  Does the current request need the state machine?
        wire op_needs_iter = sub_is_div ? (DIV_C != 1) : (MUL_C != 1);

        always @(posedge clk) begin
            if (rst) begin
                state <= S_IDLE;
                done  <= 1'b0;
            end else begin
                done <= 1'b0;
                case (state)
                    S_IDLE: begin
                        if (req) begin
                            if (op_needs_iter) begin
                                op_is_div_q  <= sub_is_div;
                                op_is_rem_q  <= sub_is_rem;
                                op_is_high_q <= sub_is_high;
                                op_is_w_q    <= is_w;
                                neg_result_q <= neg_in;
                                edge_zero_q  <= div_by_zero_in;
                                dividend_q   <= op1_ext;

                                mag_a <= mag_a_in;
                                mag_b <= mag_b_in;
                                acc   <= sub_is_div
                                            ? { 64'b0, mag_a_in }
                                            : { 64'b0, mag_b_in };

                                cnt   <= sub_is_div ? 7'd64 : MUL_C[6:0];
                                state <= S_RUN;
                            end else begin
                                //  op is configured 1-cycle: just latch
                                rd_v <= final_result_comb;
                                done <= 1'b1;
                            end
                        end
                    end

                    S_RUN: begin
                        acc <= acc_next;
                        cnt <= cnt - 7'd1;
                        if (cnt == 7'd1) begin
                            rd_v  <= iter_final_result;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end
                    end
                endcase
            end
        end
    end else begin : g_comb
        //  Both ops are 1-cycle. Never blocks.
        assign busy = 1'b0;
        always @(posedge clk) begin
            if (rst) begin
                done <= 1'b0;
            end else begin
                done <= 1'b0;
                if (req) begin
                    rd_v <= final_result_comb;
                    done <= 1'b1;
                end
            end
        end
    end
    endgenerate

    wire _unused = &{1'b0};
endmodule
