// Iterative SM3 compression leaf for Zvksh.
// Splits the two-round vsm3c operation into four partial/final stages.

module karu_sm3_iter
(
    input  wire         clk,
    input  wire         rst,
    input  wire         req,
    input  wire [  4:0] rnds,
    input  wire [255:0] crnt_state_i,
    input  wire [255:0] msg_words_i,
    output reg          busy,
    output reg          done,
    output reg  [255:0] result
);
    reg [1:0] step;
    reg [31:0] A, B, C, D, E, F, G, H;
    reg [31:0] w0, w1, w4, w5, x0, x1;
    reg [31:0] ss_pre, a12, ff_pre, gg_pre;
    reg [31:0] rnd0, rnd1;

    wire [31:0] ss1 = sm_ROL32(ss_pre, 7);
    wire [31:0] ss2 = ss1 ^ a12;
    wire [31:0] next_a = ff_pre + ss2;
    wire [31:0] next_e = sm_p_0(gg_pre + ss1);
    wire [31:0] next_c = sm_ROL32(B, 9);
    wire [31:0] next_g = sm_ROL32(F, 19);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            result <= 256'b0;
            step <= 2'd0;
        end else begin
            done <= 1'b0;
            if (req && !busy) begin
                busy <= 1'b1;
                step <= 2'd0;
                rnd0 <= {26'b0, rnds, 1'b0};
                rnd1 <= {26'b0, rnds, 1'b0} + 32'd1;
                {H, G, F, E, D, C, B, A} <= {sm_rev8(crnt_state_i[255:224]),
                    sm_rev8(crnt_state_i[223:192]), sm_rev8(crnt_state_i[191:160]),
                    sm_rev8(crnt_state_i[159:128]), sm_rev8(crnt_state_i[127: 96]),
                    sm_rev8(crnt_state_i[ 95: 64]), sm_rev8(crnt_state_i[ 63: 32]),
                    sm_rev8(crnt_state_i[ 31:  0])};
                w5 <= sm_rev8(msg_words_i[191:160]);
                w4 <= sm_rev8(msg_words_i[159:128]);
                w1 <= sm_rev8(msg_words_i[ 63: 32]);
                w0 <= sm_rev8(msg_words_i[ 31:  0]);
                x0 <= sm_rev8(msg_words_i[ 31:  0]) ^ sm_rev8(msg_words_i[159:128]);
                x1 <= sm_rev8(msg_words_i[ 63: 32]) ^ sm_rev8(msg_words_i[191:160]);
            end else if (busy) begin
                case (step)
                    2'd0: begin
                        a12 <= sm_ROL32(A, 12);
                        ss_pre <= sm_ROL32(A, 12) + E + sm_ROL32(sm_t_j(rnd0), rnd0[4:0]);
                        ff_pre <= sm_ff_j(A, B, C, rnd0) + D + x0;
                        gg_pre <= sm_gg_j(E, F, G, rnd0) + H + w0;
                        step <= 2'd1;
                    end
                    2'd1: begin
                        D <= C; C <= next_c; B <= A; A <= next_a;
                        H <= G; G <= next_g; F <= E; E <= next_e;
                        step <= 2'd2;
                    end
                    2'd2: begin
                        a12 <= sm_ROL32(A, 12);
                        ss_pre <= sm_ROL32(A, 12) + E + sm_ROL32(sm_t_j(rnd1), rnd1[4:0]);
                        ff_pre <= sm_ff_j(A, B, C, rnd1) + D + x1;
                        gg_pre <= sm_gg_j(E, F, G, rnd1) + H + w1;
                        step <= 2'd3;
                    end
                    default: begin
                        result <= {sm_rev8(G), sm_rev8(next_g), sm_rev8(E), sm_rev8(next_e),
                            sm_rev8(C), sm_rev8(next_c), sm_rev8(A), sm_rev8(next_a)};
                        done <= 1'b1;
                        busy <= 1'b0;
                    end
                endcase
            end
        end
    end

    function [31:0] sm_ROL32; input [31:0] X; input integer S; begin sm_ROL32 = (X << S) | (X >> (32 - S)); end endfunction
    function [31:0] sm_rev8; input [31:0] word_i; begin sm_rev8 = (word_i >> 24 & 8'hff) | (word_i << 8 & 24'hff0000) | (word_i >> 8 & 16'hff00) | (word_i << 24 & 32'hff000000); end endfunction
    function [31:0] sm_ff1; input [31:0] X, Y, Z; begin sm_ff1 = X ^ Y ^ Z; end endfunction
    function [31:0] sm_ff2; input [31:0] X, Y, Z; begin sm_ff2 = (X & Y) | (X & Z) | (Y & Z); end endfunction
    function [31:0] sm_ff_j; input [31:0] X, Y, Z, J; begin sm_ff_j = (J <= 15) ? sm_ff1(X, Y, Z) : sm_ff2(X, Y, Z); end endfunction
    function [31:0] sm_gg1; input [31:0] X, Y, Z; begin sm_gg1 = X ^ Y ^ Z; end endfunction
    function [31:0] sm_gg2; input [31:0] X, Y, Z; begin sm_gg2 = (X & Y) | ((~X) & Z); end endfunction
    function [31:0] sm_gg_j; input [31:0] X, Y, Z, J; begin sm_gg_j = (J <= 15) ? sm_gg1(X, Y, Z) : sm_gg2(X, Y, Z); end endfunction
    function [31:0] sm_t_j; input [31:0] J; begin sm_t_j = (J <= 15) ? 32'h79CC4519 : 32'h7A879D8A; end endfunction
    function [31:0] sm_p_0; input [31:0] X; begin sm_p_0 = X ^ sm_ROL32(X, 9) ^ sm_ROL32(X, 17); end endfunction
endmodule
