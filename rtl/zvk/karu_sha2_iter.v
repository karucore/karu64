// Iterative SHA-2 leaf for Zvknha/Zvknhb.
// Compression is split into two stages: one complete SHA round per cycle.
// Message schedule emits W16..W19 over four cycles.

module karu_sha2_iter
(
    input  wire         clk,
    input  wire         rst,
    input  wire         req,
    input  wire         is_ms,
    input  wire [  1:0] sha_op,
    input  wire [255:0] state0_i,
    input  wire [255:0] state1_i,
    input  wire [255:0] msg_i,
    output reg          busy,
    output reg          done,
    output reg  [255:0] result
);
    reg        is_ms_q, sew64_q, low_q;
    reg [1:0]  step;

    reg [63:0] a64, b64, c64, d64, e64, f64, g64, h64;
    reg [31:0] a32, b32, c32, d32, e32, f32, g32, h32;
    reg [63:0] w0_64, w1_64;
    reg [31:0] w0_32, w1_32;

    reg [63:0] ms64_0, ms64_1, ms64_2, ms64_3, ms64_4;
    reg [63:0] ms64_9, ms64_10, ms64_11, ms64_12, ms64_13, ms64_14, ms64_15;
    reg [63:0] ms64_16, ms64_17, ms64_18;
    reg [31:0] ms32_0, ms32_1, ms32_2, ms32_3, ms32_4;
    reg [31:0] ms32_9, ms32_10, ms32_11, ms32_12, ms32_13, ms32_14, ms32_15;
    reg [31:0] ms32_16, ms32_17, ms32_18;

    wire [63:0] comp_w_64 = (step == 2'd0) ? w0_64 : w1_64;
    wire [31:0] comp_w_32 = (step == 2'd0) ? w0_32 : w1_32;
    wire [63:0] s0_64 = sum0_64(a64);
    wire [63:0] s1_64 = sum1_64(e64);
    wire [63:0] chv_64 = ch_64(e64, f64, g64);
    wire [63:0] majv_64 = maj_64(a64, b64, c64);
    wire [63:0] a_next_64 = add6_64(h64, s1_64, chv_64, comp_w_64, s0_64, majv_64);
    wire [63:0] e_next_64 = add5_64(d64, h64, s1_64, chv_64, comp_w_64);
    wire [31:0] s0_32 = sum0_32(a32);
    wire [31:0] s1_32 = sum1_32(e32);
    wire [31:0] chv_32 = ch_32(e32, f32, g32);
    wire [31:0] majv_32 = maj_32(a32, b32, c32);
    wire [31:0] a_next_32 = add6_32(h32, s1_32, chv_32, comp_w_32, s0_32, majv_32);
    wire [31:0] e_next_32 = add5_32(d32, h32, s1_32, chv_32, comp_w_32);
    wire [63:0] ms64_next =
        (step == 2'd0) ? add4_64(sig1_64(ms64_14), ms64_9,  sig0_64(ms64_1), ms64_0) :
        (step == 2'd1) ? add4_64(sig1_64(ms64_15), ms64_10, sig0_64(ms64_2), ms64_1) :
        (step == 2'd2) ? add4_64(sig1_64(ms64_16), ms64_11, sig0_64(ms64_3), ms64_2) :
                         add4_64(sig1_64(ms64_17), ms64_12, sig0_64(ms64_4), ms64_3);
    wire [31:0] ms32_next =
        (step == 2'd0) ? add4_32(sig1_32(ms32_14), ms32_9,  sig0_32(ms32_1), ms32_0) :
        (step == 2'd1) ? add4_32(sig1_32(ms32_15), ms32_10, sig0_32(ms32_2), ms32_1) :
        (step == 2'd2) ? add4_32(sig1_32(ms32_16), ms32_11, sig0_32(ms32_3), ms32_2) :
                         add4_32(sig1_32(ms32_17), ms32_12, sig0_32(ms32_4), ms32_3);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            result <= 256'b0;
            step <= 2'd0;
            is_ms_q <= 1'b0;
            sew64_q <= 1'b0;
            low_q <= 1'b0;
        end else begin
            done <= 1'b0;
            if (req && !busy) begin
                busy <= 1'b1;
                step <= 2'd0;
                is_ms_q <= is_ms;
                sew64_q <= sha_op[0];
                low_q <= sha_op[1];
                result <= 256'b0;
                if (is_ms) begin
                    {ms64_3,  ms64_2,  ms64_1,  ms64_0 } <= state0_i;
                    {ms64_11, ms64_10, ms64_9,  ms64_4 } <= state1_i;
                    {ms64_15, ms64_14, ms64_13, ms64_12} <= msg_i;
                    {ms32_3,  ms32_2,  ms32_1,  ms32_0 } <= state0_i[127:0];
                    {ms32_11, ms32_10, ms32_9,  ms32_4 } <= state1_i[127:0];
                    {ms32_15, ms32_14, ms32_13, ms32_12} <= msg_i[127:0];
                    ms64_16 <= 64'b0; ms64_17 <= 64'b0; ms64_18 <= 64'b0;
                    ms32_16 <= 32'b0; ms32_17 <= 32'b0; ms32_18 <= 32'b0;
                end else if (sha_op[0]) begin
                    {a64, b64, e64, f64} <= state1_i;
                    {c64, d64, g64, h64} <= state0_i;
                    if (sha_op[1]) begin
                        w0_64 <= msg_i[ 63:  0];
                        w1_64 <= msg_i[127: 64];
                    end else begin
                        w0_64 <= msg_i[191:128];
                        w1_64 <= msg_i[255:192];
                    end
                end else begin
                    {a32, b32, e32, f32} <= state1_i[127:0];
                    {c32, d32, g32, h32} <= state0_i[127:0];
                    if (sha_op[1]) begin
                        w0_32 <= msg_i[ 31:  0];
                        w1_32 <= msg_i[ 63: 32];
                    end else begin
                        w0_32 <= msg_i[ 95: 64];
                        w1_32 <= msg_i[127: 96];
                    end
                end
            end else if (busy) begin
                if (is_ms_q) begin
                    if (sew64_q) begin
                        if (step == 2'd0) ms64_16 <= ms64_next;
                        if (step == 2'd1) ms64_17 <= ms64_next;
                        if (step == 2'd2) ms64_18 <= ms64_next;
                        if (step == 2'd3) result <= {ms64_next, ms64_18, ms64_17, ms64_16};
                    end else begin
                        if (step == 2'd0) ms32_16 <= ms32_next;
                        if (step == 2'd1) ms32_17 <= ms32_next;
                        if (step == 2'd2) ms32_18 <= ms32_next;
                        if (step == 2'd3) result <= {128'b0, ms32_next, ms32_18, ms32_17, ms32_16};
                    end
                    if (step == 2'd3) begin
                        done <= 1'b1;
                        busy <= 1'b0;
                    end else begin
                        step <= step + 2'd1;
                    end
                end else if (sew64_q) begin
                    case (step)
                        2'd0: begin
                            h64 <= g64; g64 <= f64; f64 <= e64; e64 <= e_next_64;
                            d64 <= c64; c64 <= b64; b64 <= a64; a64 <= a_next_64;
                            step <= 2'd1;
                        end
                        default: begin
                            result <= {a_next_64, a64, e_next_64, e64};
                            done <= 1'b1;
                            busy <= 1'b0;
                        end
                    endcase
                end else begin
                    case (step)
                        2'd0: begin
                            h32 <= g32; g32 <= f32; f32 <= e32; e32 <= e_next_32;
                            d32 <= c32; c32 <= b32; b32 <= a32; a32 <= a_next_32;
                            step <= 2'd1;
                        end
                        default: begin
                            result <= {128'b0, a_next_32, a32, e_next_32, e32};
                            done <= 1'b1;
                            busy <= 1'b0;
                        end
                    endcase
                end
            end
        end
    end

    function [63:0] ROTR_64; input [63:0] x; input integer n; begin ROTR_64 = (x >> n) | (x << (64 - n)); end endfunction
    function [31:0] ROTR_32; input [31:0] x; input integer n; begin ROTR_32 = (x >> n) | (x << (32 - n)); end endfunction
    function [63:0] sum0_64; input [63:0] x; begin sum0_64 = ROTR_64(x, 28) ^ ROTR_64(x, 34) ^ ROTR_64(x, 39); end endfunction
    function [31:0] sum0_32; input [31:0] x; begin sum0_32 = ROTR_32(x, 2) ^ ROTR_32(x, 13) ^ ROTR_32(x, 22); end endfunction
    function [63:0] sum1_64; input [63:0] x; begin sum1_64 = ROTR_64(x, 14) ^ ROTR_64(x, 18) ^ ROTR_64(x, 41); end endfunction
    function [31:0] sum1_32; input [31:0] x; begin sum1_32 = ROTR_32(x, 6) ^ ROTR_32(x, 11) ^ ROTR_32(x, 25); end endfunction
    function [63:0] sig0_64; input [63:0] x; begin sig0_64 = ROTR_64(x, 1) ^ ROTR_64(x, 8) ^ (x >> 7); end endfunction
    function [31:0] sig0_32; input [31:0] x; begin sig0_32 = ROTR_32(x, 7) ^ ROTR_32(x, 18) ^ (x >> 3); end endfunction
    function [63:0] sig1_64; input [63:0] x; begin sig1_64 = ROTR_64(x, 19) ^ ROTR_64(x, 61) ^ (x >> 6); end endfunction
    function [31:0] sig1_32; input [31:0] x; begin sig1_32 = ROTR_32(x, 17) ^ ROTR_32(x, 19) ^ (x >> 10); end endfunction
    function [63:0] ch_64; input [63:0] x, y, z; begin ch_64 = z ^ (x & (y ^ z)); end endfunction
    function [31:0] ch_32; input [31:0] x, y, z; begin ch_32 = z ^ (x & (y ^ z)); end endfunction
    function [63:0] maj_64; input [63:0] x, y, z; begin maj_64 = (x & y) | (z & (x | y)); end endfunction
    function [31:0] maj_32; input [31:0] x, y, z; begin maj_32 = (x & y) | (z & (x | y)); end endfunction
    function [63:0] csa_s_64; input [63:0] x, y, z; begin csa_s_64 = x ^ y ^ z; end endfunction
    function [63:0] csa_c_64; input [63:0] x, y, z; begin csa_c_64 = ((x & y) | (x & z) | (y & z)) << 1; end endfunction
    function [31:0] csa_s_32; input [31:0] x, y, z; begin csa_s_32 = x ^ y ^ z; end endfunction
    function [31:0] csa_c_32; input [31:0] x, y, z; begin csa_c_32 = ((x & y) | (x & z) | (y & z)) << 1; end endfunction
    function [63:0] add4_64;
        input [63:0] a, b, c, d;
        reg [63:0] s0, c0, s1, c1;
        begin
            s0 = csa_s_64(a, b, c); c0 = csa_c_64(a, b, c);
            s1 = csa_s_64(d, s0, c0); c1 = csa_c_64(d, s0, c0);
            add4_64 = s1 + c1;
        end
    endfunction
    function [31:0] add4_32;
        input [31:0] a, b, c, d;
        reg [31:0] s0, c0, s1, c1;
        begin
            s0 = csa_s_32(a, b, c); c0 = csa_c_32(a, b, c);
            s1 = csa_s_32(d, s0, c0); c1 = csa_c_32(d, s0, c0);
            add4_32 = s1 + c1;
        end
    endfunction
    function [63:0] add5_64;
        input [63:0] a, b, c, d, e;
        reg [63:0] s0, c0, s1, c1, s2, c2;
        begin
            s0 = csa_s_64(a, b, c); c0 = csa_c_64(a, b, c);
            s1 = csa_s_64(d, e, s0); c1 = csa_c_64(d, e, s0);
            s2 = csa_s_64(c0, c1, s1); c2 = csa_c_64(c0, c1, s1);
            add5_64 = s2 + c2;
        end
    endfunction
    function [31:0] add5_32;
        input [31:0] a, b, c, d, e;
        reg [31:0] s0, c0, s1, c1, s2, c2;
        begin
            s0 = csa_s_32(a, b, c); c0 = csa_c_32(a, b, c);
            s1 = csa_s_32(d, e, s0); c1 = csa_c_32(d, e, s0);
            s2 = csa_s_32(c0, c1, s1); c2 = csa_c_32(c0, c1, s1);
            add5_32 = s2 + c2;
        end
    endfunction
    function [63:0] add6_64;
        input [63:0] a, b, c, d, e, f;
        reg [63:0] s0, c0, s1, c1, s2, c2, s3, c3;
        begin
            s0 = csa_s_64(a, b, c); c0 = csa_c_64(a, b, c);
            s1 = csa_s_64(d, e, f); c1 = csa_c_64(d, e, f);
            s2 = csa_s_64(s0, c0, s1); c2 = csa_c_64(s0, c0, s1);
            s3 = csa_s_64(c1, s2, c2); c3 = csa_c_64(c1, s2, c2);
            add6_64 = s3 + c3;
        end
    endfunction
    function [31:0] add6_32;
        input [31:0] a, b, c, d, e, f;
        reg [31:0] s0, c0, s1, c1, s2, c2, s3, c3;
        begin
            s0 = csa_s_32(a, b, c); c0 = csa_c_32(a, b, c);
            s1 = csa_s_32(d, e, f); c1 = csa_c_32(d, e, f);
            s2 = csa_s_32(s0, c0, s1); c2 = csa_c_32(s0, c0, s1);
            s3 = csa_s_32(c1, s2, c2); c3 = csa_c_32(c1, s2, c2);
            add6_32 = s3 + c3;
        end
    endfunction
endmodule
