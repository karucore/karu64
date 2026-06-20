//  karu_ghash.v
//  Iterative GF(2^128) GHASH multiply for Zvkg (vgmul.vv / vghsh.vv).
//
//  WHY ITERATIVE: the upstream Marian add_mult_ghash/mult_ghash express the
//  128-bit carry-less multiply + reduction as a fully-unrolled combinational
//  genvar cone (clk/rst present but UNUSED, done==valid). That is ~128 serial
//  conditional-XOR levels deep -- a hard timing wall at 8 ns, far worse than the
//  varith writeback cone. So we serialise it the same way the core already
//  handles deep operations (keccak round FSM, KARU_V_DIV_CYCLES bit-serial
//  divide): a radix-2^GK engine that folds GK of the 128 GF steps per cycle.
//  GK is an area<->latency<->Fmax lever; the math is bit-identical to Marian's
//  published vector checked in tb_ghash_kat.sv and matches the RVV Zvkg spec
//  (Sail) form: out = brev8( GFMUL( brev8(A^X), brev8(H) ) ).
//
//  KARU_V_GHASH_CYCLES selects total GF cycles; must divide 128. 1 => 128
//  bits/cycle (fully unrolled inside one registered handshake);
//  128 => 1 bit/cycle (shallowest). Default 16 (8 bits/cycle).
//
//  Handshake matches the core's multi-cycle FU convention (req/busy/done).
//    mode=0 : vgmul.vv  (A=vd,  X=0)    -> brev8(GFMUL(brev8(vd),     brev8(vs2)))
//    mode=1 : vghsh.vv  (A=vd,  X=vs1)  -> brev8(GFMUL(brev8(vd^vs1), brev8(vs2)))
//  vs2 is the multiplicand / hash subkey H in both.

`ifndef KARU_V_GHASH_CYCLES
`define KARU_V_GHASH_CYCLES 16
`endif

module karu_ghash (
    input  wire         clk,
    input  wire         rst,
    input  wire         req,        //  pulse one cycle to start (when !busy)
    input  wire         mode,       //  0 = vgmul, 1 = vghsh
    input  wire [127:0] vd,         //  multiplier / partial hash Y
    input  wire [127:0] vs1,        //  cipher text X (vghsh only; ignored for vgmul)
    input  wire [127:0] vs2,        //  multiplicand / hash subkey H
    output reg          busy,
    output reg          done,
    output reg  [127:0] prod        //  valid the cycle done is high
);
    //  ---- resolve cycle count to a divisor of 128 (round UP to power of 2) ----
    localparam integer GC_REQ = `KARU_V_GHASH_CYCLES;
    localparam integer GC =
        (GC_REQ <= 1)   ? 1   :
        (GC_REQ <= 2)   ? 2   :
        (GC_REQ <= 4)   ? 4   :
        (GC_REQ <= 8)   ? 8   :
        (GC_REQ <= 16)  ? 16  :
        (GC_REQ <= 32)  ? 32  :
        (GC_REQ <= 64)  ? 64  : 128;
    localparam integer GK = 128 / GC;           //  GF steps folded per cycle
    localparam [127:0] POLY = 128'h87;          //  x^128 = x^7+x^2+x^1+1

    //  ---- byte-wise bit reversal (RVV GHASH operand convention) ----
    function [127:0] brev8;
        input [127:0] w;
        integer b, k;
        begin
            brev8 = 128'b0;
            for (b = 0; b < 16; b = b + 1)
                for (k = 0; k < 8; k = k + 1)
                    brev8[b*8 + (7-k)] = w[b*8 + k];
        end
    endfunction

    reg [127:0] Yq, Hq, Zq;
    reg [7:0]   sidx;           //  next GF bit index (0..128)

    //  ---- combinational GK-step fold over (Zq, Hq) using Yq[sidx +: GK] ----
    reg [127:0] Hc, Zc;
    integer t;
    always @(*) begin
        Hc = Hq;
        Zc = Zq;
        for (t = 0; t < GK; t = t + 1) begin
            if (Yq[sidx + t[7:0]]) Zc = Zc ^ Hc;    //  use H BEFORE advancing
            Hc = Hc[127] ? ((Hc << 1) ^ POLY) : (Hc << 1);
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            sidx <= 8'd0;
        end else begin
            done <= 1'b0;
            if (req && !busy) begin
                Yq   <= brev8(mode ? (vd ^ vs1) : vd);
                Hq   <= brev8(vs2);
                Zq   <= 128'b0;
                sidx <= 8'd0;
                busy <= 1'b1;
            end else if (busy) begin
                Zq   <= Zc;
                Hq   <= Hc;
                sidx <= sidx + GK[7:0];
                if (sidx + GK[7:0] >= 8'd128) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    prod <= brev8(Zc);
                end
            end
        end
    end

    //  build-time latency hint for a scheduler: 1 latch + GC compute cycles
    localparam integer LATENCY = 1 + GC;

endmodule
