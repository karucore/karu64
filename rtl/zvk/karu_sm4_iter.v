// Iterative SM4 four-round leaf for Zvksed.

module karu_sm4_iter
(
    input  wire        clk,
    input  wire        rst,
    input  wire        req,
    input  wire        is_key,
    input  wire [ 2:0] rnd,
    input  wire [127:0] state_i,
    input  wire [127:0] key_i,
    output reg         busy,
    output reg         done,
    output reg  [127:0] result
);
    reg [31:0] w0, w1, w2, w3;
    reg [1:0]  step;
    reg [2:0]  rnd_q;
    reg        is_key_q;

    wire [4:0] ck_idx = {rnd_q, 2'b00} + {3'b000, step};
    wire [31:0] round_key = is_key_q ? sm_constant_key(ck_idx) :
        (step == 2'd0) ? key_i[ 31:  0] :
        (step == 2'd1) ? key_i[ 63: 32] :
        (step == 2'd2) ? key_i[ 95: 64] : key_i[127: 96];
    wire [31:0] b = w1 ^ w2 ^ w3 ^ round_key;
    wire [31:0] s;
    sm4_subword i_subword (.word_o(s), .word_i(b));
    wire [31:0] new_w = is_key_q ? sm_round_key(w0, s) : sm_round(w0, s);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            result <= 128'b0;
            w0 <= 32'b0; w1 <= 32'b0; w2 <= 32'b0; w3 <= 32'b0;
            step <= 2'b0;
            rnd_q <= 3'b0;
            is_key_q <= 1'b0;
        end else begin
            done <= 1'b0;
            if (req && !busy) begin
                busy <= 1'b1;
                step <= 2'b0;
                rnd_q <= rnd;
                is_key_q <= is_key;
                if (is_key) begin
                    w0 <= key_i[ 31:  0];
                    w1 <= key_i[ 63: 32];
                    w2 <= key_i[ 95: 64];
                    w3 <= key_i[127: 96];
                end else begin
                    w0 <= state_i[ 31:  0];
                    w1 <= state_i[ 63: 32];
                    w2 <= state_i[ 95: 64];
                    w3 <= state_i[127: 96];
                end
            end else if (busy) begin
                if (step == 2'd3) begin
                    result <= {new_w, w3, w2, w1};
                    done <= 1'b1;
                    busy <= 1'b0;
                end else begin
                    w0 <= w1;
                    w1 <= w2;
                    w2 <= w3;
                    w3 <= new_w;
                    step <= step + 2'd1;
                end
            end
        end
    end

    function [31:0] sm_constant_key;
        input [4:0] r;
        begin
            case (r)
                5'h00: sm_constant_key = 32'h00070E15;
                5'h01: sm_constant_key = 32'h1C232A31;
                5'h02: sm_constant_key = 32'h383F464D;
                5'h03: sm_constant_key = 32'h545B6269;
                5'h04: sm_constant_key = 32'h70777E85;
                5'h05: sm_constant_key = 32'h8C939AA1;
                5'h06: sm_constant_key = 32'hA8AFB6BD;
                5'h07: sm_constant_key = 32'hC4CBD2D9;
                5'h08: sm_constant_key = 32'hE0E7EEF5;
                5'h09: sm_constant_key = 32'hFC030A11;
                5'h0A: sm_constant_key = 32'h181F262D;
                5'h0B: sm_constant_key = 32'h343B4249;
                5'h0C: sm_constant_key = 32'h50575E65;
                5'h0D: sm_constant_key = 32'h6C737A81;
                5'h0E: sm_constant_key = 32'h888F969D;
                5'h0F: sm_constant_key = 32'hA4ABB2B9;
                5'h10: sm_constant_key = 32'hC0C7CED5;
                5'h11: sm_constant_key = 32'hDCE3EAF1;
                5'h12: sm_constant_key = 32'hF8FF060D;
                5'h13: sm_constant_key = 32'h141B2229;
                5'h14: sm_constant_key = 32'h30373E45;
                5'h15: sm_constant_key = 32'h4C535A61;
                5'h16: sm_constant_key = 32'h686F767D;
                5'h17: sm_constant_key = 32'h848B9299;
                5'h18: sm_constant_key = 32'hA0A7AEB5;
                5'h19: sm_constant_key = 32'hBCC3CAD1;
                5'h1A: sm_constant_key = 32'hD8DFE6ED;
                5'h1B: sm_constant_key = 32'hF4FB0209;
                5'h1C: sm_constant_key = 32'h10171E25;
                5'h1D: sm_constant_key = 32'h2C333A41;
                5'h1E: sm_constant_key = 32'h484F565D;
                5'h1F: sm_constant_key = 32'h646B7279;
                default: sm_constant_key = 32'h00000000;
            endcase
        end
    endfunction

    function [31:0] sm_rol32;
        input [31:0] x;
        input integer s;
        begin
            sm_rol32 = (x << s) | (x >> (32 - s));
        end
    endfunction

    function [31:0] sm_round;
        input [31:0] x;
        input [31:0] s;
        begin
            sm_round = x ^ (s ^ sm_rol32(s, 2) ^ sm_rol32(s, 10) ^
                sm_rol32(s, 18) ^ sm_rol32(s, 24));
        end
    endfunction

    function [31:0] sm_round_key;
        input [31:0] x;
        input [31:0] s;
        begin
            sm_round_key = x ^ (s ^ sm_rol32(s, 13) ^ sm_rol32(s, 23));
        end
    endfunction

endmodule
