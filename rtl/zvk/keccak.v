//  keccak.v
//  Round-count FSM wrapper around the combinational keccak_round (f1600).
//  Ported to plain Verilog-2001 + active-high reset from Marian's
//  keccak.sv (M-J. Saarinen). Runs `rounds` Keccak-f[1600] rounds back to
//  back, one round per cycle, for the experimental Zvknhk `vkeccak.vi`.
//
//  Handshake (matches the karu multi-cycle convention):
//    req     pulse to start a run (state_i/rounds_i sampled this cycle)
//    busy    high while running
//    done    one-cycle pulse when state_o is valid
//    state_i 1600-bit initial state (EGU64x32 lanes 0..24)
//    state_o 1600-bit final state (valid the cycle done is high)
//
//  rounds_i is the imm5 literal round count (the keccak-xrv test set uses
//  24 for SHA-3 K-f); cnt counts that many rounds then stops.

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
                    r_q   <= 8'h01;             //  LFSR seed for round 0
                    cnt   <= {1'b0, rounds_i};  //  literal round count
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
