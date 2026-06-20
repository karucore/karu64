// Verilog version of the Marian AES encrypt/decrypt round leaf.

module encdec
(
    input  wire [  2:0] aes_op_i,
    input  wire [127:0] rnd_state_i,
    input  wire [127:0] rnd_key_i,
    output wire [127:0] rnd_state_o
);

    localparam ZERO_RND  = 3'b000;
    localparam ENC_M_RND = 3'b010;
    localparam ENC_F_RND = 3'b011;
    localparam DEC_M_RND = 3'b100;
    localparam DEC_F_RND = 3'b101;

    reg  [127:0] words_s;
    reg  [127:0] sub_state_in_s;
    wire [127:0] sub_state_out_s;
    reg  [127:0] shift_state_s;
    reg  [127:0] ark_state_s;
    reg  [127:0] mix_state_s;
    wire         sbox_encdec_sel_s = aes_op_i[1];
    integer word;

    assign rnd_state_o = words_s;

    always @* begin
        words_s        = 128'b0;
        sub_state_in_s = 128'b0;
        shift_state_s  = 128'b0;
        ark_state_s    = 128'b0;
        mix_state_s    = 128'b0;

        case (aes_op_i)
            ZERO_RND: begin
                words_s = rnd_state_i ^ rnd_key_i;
            end

            ENC_M_RND: begin
                sub_state_in_s = rnd_state_i;
                shift_state_s  = shift_rows(sub_state_out_s, sbox_encdec_sel_s);
                mix_state_s    = mix_columns(shift_state_s, sbox_encdec_sel_s);
                words_s        = mix_state_s ^ rnd_key_i;
            end

            ENC_F_RND: begin
                sub_state_in_s = rnd_state_i;
                shift_state_s  = shift_rows(sub_state_out_s, sbox_encdec_sel_s);
                words_s        = shift_state_s ^ rnd_key_i;
            end

            DEC_M_RND: begin
                shift_state_s  = shift_rows(rnd_state_i, sbox_encdec_sel_s);
                sub_state_in_s = shift_state_s;
                ark_state_s    = sub_state_out_s ^ rnd_key_i;
                words_s        = mix_columns(ark_state_s, sbox_encdec_sel_s);
            end

            DEC_F_RND: begin
                shift_state_s  = shift_rows(rnd_state_i, sbox_encdec_sel_s);
                sub_state_in_s = shift_state_s;
                words_s        = sub_state_out_s ^ rnd_key_i;
            end

            default: begin
                words_s = 128'b0;
            end
        endcase
    end

    genvar state_word, state_byte;
    generate
        for (state_word = 0; state_word < 4; state_word = state_word + 1) begin : gen_sbox_word
            for (state_byte = 0; state_byte < 4; state_byte = state_byte + 1) begin : gen_sbox_byte
                wire [7:0] aes_fwd;
                wire [7:0] aes_inv;
                aes_sbox  i_sbox_fwd (.fx(aes_fwd), .in(sub_state_in_s[(state_word*32) + (state_byte*8) +: 8]));
                aesi_sbox i_sbox_inv (.fx(aes_inv), .in(sub_state_in_s[(state_word*32) + (state_byte*8) +: 8]));
                assign sub_state_out_s[(state_word*32) + (state_byte*8) +: 8] =
                    sbox_encdec_sel_s ? aes_fwd : aes_inv;
            end
        end
    endgenerate

    function [127:0] shift_rows;
        input [127:0] curr_state;
        input         enc_dec_sel;
        begin
            if (enc_dec_sel) begin
                shift_rows[ 31:  0] = {curr_state[120 +: 8], curr_state[ 80 +: 8],
                               curr_state[ 40 +: 8], curr_state[  0 +: 8]};
                shift_rows[ 63: 32] = {curr_state[ 24 +: 8], curr_state[112 +: 8],
                               curr_state[ 72 +: 8], curr_state[ 32 +: 8]};
                shift_rows[ 95: 64] = {curr_state[ 56 +: 8], curr_state[ 16 +: 8],
                               curr_state[104 +: 8], curr_state[ 64 +: 8]};
                shift_rows[127: 96] = {curr_state[ 88 +: 8], curr_state[ 48 +: 8],
                               curr_state[  8 +: 8], curr_state[ 96 +: 8]};
            end else begin
                shift_rows[ 31:  0] = {curr_state[ 56 +: 8], curr_state[ 80 +: 8],
                               curr_state[104 +: 8], curr_state[  0 +: 8]};
                shift_rows[ 63: 32] = {curr_state[ 88 +: 8], curr_state[112 +: 8],
                               curr_state[  8 +: 8], curr_state[ 32 +: 8]};
                shift_rows[ 95: 64] = {curr_state[120 +: 8], curr_state[ 16 +: 8],
                               curr_state[ 40 +: 8], curr_state[ 64 +: 8]};
                shift_rows[127: 96] = {curr_state[ 24 +: 8], curr_state[ 48 +: 8],
                               curr_state[ 72 +: 8], curr_state[ 96 +: 8]};
            end
        end
    endfunction

    function [127:0] mix_columns;
        input [127:0] curr_state;
        input         enc_dec_sel;
        integer      w;
        reg [7:0]    b0, b1, b2, b3;
        begin
            mix_columns = 128'b0;
            for (w = 0; w < 4; w = w + 1) begin
                b0 = curr_state[(w*32) +  0 +: 8];
                b1 = curr_state[(w*32) +  8 +: 8];
                b2 = curr_state[(w*32) + 16 +: 8];
                b3 = curr_state[(w*32) + 24 +: 8];

                if (enc_dec_sel) begin
                    mix_columns[(w*32) +  0 +: 8] = xt2(b0) ^ xt3(b1) ^ b2      ^ b3;
                    mix_columns[(w*32) +  8 +: 8] = b0      ^ xt2(b1) ^ xt3(b2) ^ b3;
                    mix_columns[(w*32) + 16 +: 8] = b0      ^ b1      ^ xt2(b2) ^ xt3(b3);
                    mix_columns[(w*32) + 24 +: 8] = xt3(b0) ^ b1      ^ b2      ^ xt2(b3);
                end else begin
                    mix_columns[(w*32) +  0 +: 8] = gfmul(b0, 4'hE) ^ gfmul(b1, 4'hB) ^
                                          gfmul(b2, 4'hD) ^ gfmul(b3, 4'h9);
                    mix_columns[(w*32) +  8 +: 8] = gfmul(b0, 4'h9) ^ gfmul(b1, 4'hE) ^
                                          gfmul(b2, 4'hB) ^ gfmul(b3, 4'hD);
                    mix_columns[(w*32) + 16 +: 8] = gfmul(b0, 4'hD) ^ gfmul(b1, 4'h9) ^
                                          gfmul(b2, 4'hE) ^ gfmul(b3, 4'hB);
                    mix_columns[(w*32) + 24 +: 8] = gfmul(b0, 4'hB) ^ gfmul(b1, 4'hD) ^
                                          gfmul(b2, 4'h9) ^ gfmul(b3, 4'hE);
                end
            end
        end
    endfunction

    function [7:0] xt2;
        input [7:0] x;
        begin
            xt2 = x[7] ? ((x << 1) ^ 8'h1B) : (x << 1);
        end
    endfunction

    function [7:0] xt3;
        input [7:0] x;
        begin
            xt3 = x ^ xt2(x);
        end
    endfunction

    function [7:0] gfmul;
        input [7:0] x;
        input [3:0] y;
        reg [7:0] x0, x1, x2, x3;
        begin
            x0 = y[0] ? x                : 8'h00;
            x1 = y[1] ? xt2(x)           : 8'h00;
            x2 = y[2] ? xt2(xt2(x))      : 8'h00;
            x3 = y[3] ? xt2(xt2(xt2(x))) : 8'h00;
            gfmul = x0 ^ x1 ^ x2 ^ x3;
        end
    endfunction

endmodule
