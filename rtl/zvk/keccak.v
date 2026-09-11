//  keccak.v
//  Round-count FSM wrapper around the combinational keccak_round: ONE
//  Keccak-p[1600,nr] permutation (FIPS 202 Sec. 3.3), nr rounds back to back,
//  one round per cycle, for the Zvknhk `vkeccak.vi` instruction (riscv-pqc
//  zvknhk.adoc). Ported to plain Verilog-2001 + active-high reset from
//  Marian's keccak.sv (M-J. Saarinen).
//
//  Handshake (matches the karu multi-cycle convention):
//    req       pulse to start a run (state_i/rounds_i sampled this cycle)
//    busy      high while running
//    done      one-cycle pulse when state_o is valid
//    rounds_i  nr, the round count (1..24). The round constants are the LAST
//              nr of RC[0..23], i.e. RC[24-nr]..RC[23], exactly as FIPS 202
//              defines Keccak-p[b,nr]: vkeccak.vi runs nr=24 (imm5=0,
//              Keccak-f[1600] for SHA-3/SHAKE) or nr=12 (imm5=1, RC[12..23]
//              for TurboSHAKE/KangarooTwelve). nr=0 passes the state through.
//    state_i   1600-bit initial state (elements 0..24; A[x,y] = element x+5y,
//              element i at bits [64i+63:64i], bit z of it = A[x,y,z])
//    state_o   1600-bit final state (valid the cycle done is high)
//
//  The req-to-done latency depends only on nr, never on the state
//  (data-independent execution latency, as Zvkt / zvknhk.adoc require).

module keccak (
    input  wire         clk,
    input  wire         rst,
    input  wire         req,
    input  wire [4:0]   rounds_i,
    input  wire [1599:0] state_i,
    output wire         busy,
    output reg          done,
    output reg [1599:0] state_o
);
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;
    reg [1:0]   state;
    reg [1599:0] s_q;
    reg [7:0]   r_q;
    reg [5:0]   cnt;        //  6-bit: cnt up to 32 representable

    //  keccak_round derives each iota constant from an 8-bit LFSR (r_i -> r_o
    //  advances it 7 steps = one round). rc_seed(i) is the LFSR state that
    //  yields RC[i], so a run of nr rounds starts from rc_seed(24-nr). The
    //  table is the LFSR stepped from 0x01, checked against the FIPS 202
    //  RC[0..23] constants; test/zvk/tb_keccak_kat.sv covers nr=24 and nr=12.
    function [7:0] rc_seed;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  rc_seed = 8'h01;   5'd1:  rc_seed = 8'h1A;
                5'd2:  rc_seed = 8'h5E;   5'd3:  rc_seed = 8'hF0;
                5'd4:  rc_seed = 8'h9F;   5'd5:  rc_seed = 8'hA1;
                5'd6:  rc_seed = 8'hF9;   5'd7:  rc_seed = 8'h55;
                5'd8:  rc_seed = 8'h0E;   5'd9:  rc_seed = 8'h8C;
                5'd10: rc_seed = 8'h35;   5'd11: rc_seed = 8'hA6;
                5'd12: rc_seed = 8'hBF;   5'd13: rc_seed = 8'hCF;
                5'd14: rc_seed = 8'hDD;   5'd15: rc_seed = 8'h53;
                5'd16: rc_seed = 8'h52;   5'd17: rc_seed = 8'h48;
                5'd18: rc_seed = 8'h16;   5'd19: rc_seed = 8'hE6;
                5'd20: rc_seed = 8'h79;   5'd21: rc_seed = 8'hD8;
                5'd22: rc_seed = 8'h21;   5'd23: rc_seed = 8'h74;
                default: rc_seed = 8'h01;   //  nr == 0 (no round is applied)
            endcase
        end
    endfunction

    wire [1599:0] s_next;
    wire [7:0]    r_next;
    keccak_round i_round (.s_i(s_q), .r_i(r_q), .s_o(s_next), .r_o(r_next));

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; s_q <= 1600'b0; r_q <= 8'b0; cnt <= 6'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (req) begin
                    s_q   <= state_i;
                    r_q   <= rc_seed(5'd24 - rounds_i);     //  LFSR seed for RC[24-nr]
                    cnt   <= {1'b0, rounds_i};              //  literal round count
                    state <= S_RUN;
                end
                S_RUN: begin
                    if (cnt == 6'd0) begin
                        state_o <= s_q;         //  no round applied at cnt==0
                        done    <= 1'b1;
                        state   <= S_IDLE;
                    end else begin
                        s_q <= s_next; r_q <= r_next; cnt <= cnt - 6'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
