//  tb_keccak_kat.sv -- known-answer test for rtl/zvk/keccak.v (Keccak-p[1600,nr]).
//
//  Vectors: the riscv-pqc zvknhk/test KECCAK-P (nr=24, FIPS 202 Keccak-f[1600])
//  and KECCAK-P12 (nr=12, round constants RC[12..23]) results for the state
//  A[i] = i, cross-checked against an independent Keccak-p[1600] model. This
//  is what vkeccak.vi imm5=0 / imm5=1 must produce.
//
//  Build: see `make keccak-kat` (verilator --binary --timing).
`timescale 1ns/1ps
module tb_keccak_kat;
    reg           clk = 1'b0, rst = 1'b1, req = 1'b0;
    reg  [4:0]    rounds = 5'd0;
    reg  [1599:0] st_i = 1600'b0;
    wire          busy, done;
    wire [1599:0] st_o;

    keccak dut (
        .clk(clk), .rst(rst), .req(req), .rounds_i(rounds),
        .state_i(st_i), .busy(busy), .done(done), .state_o(st_o)
    );
    always #5 clk = ~clk;

    reg [63:0] exp24 [0:24];
    reg [63:0] exp12 [0:24];
    integer fails = 0;

    task automatic run(input [4:0] nr, input [8*16-1:0] name);
        integer k, cyc;
        reg [1599:0] e;
        begin
            for (k = 0; k < 25; k = k + 1) st_i[64*k +: 64] = k;
            for (k = 0; k < 25; k = k + 1) e[64*k +: 64] = (nr == 5'd24) ? exp24[k] : exp12[k];
            @(negedge clk); req = 1'b1; rounds = nr;
            @(negedge clk); req = 1'b0;
            cyc = 0;
            while (!done) begin
                @(negedge clk); cyc = cyc + 1;
                if (cyc > 100) begin $display("FAIL %0s: no done after %0d cycles", name, cyc); $fatal(1); end
            end
            if (st_o !== e) begin
                $display("FAIL %0s (nr=%0d)", name, nr);
                for (k = 0; k < 25; k = k + 1)
                    if (st_o[64*k +: 64] !== e[64*k +: 64])
                        $display("  lane %0d got=%016h exp=%016h", k, st_o[64*k +: 64], e[64*k +: 64]);
                fails = fails + 1;
            end else
                $display("PASS %0s (nr=%0d, %0d cycles req->done)", name, nr, cyc + 1);
            if (busy) begin $display("FAIL %0s: busy after done", name); fails = fails + 1; end
        end
    endtask

    initial begin
        //  riscv-pqc zvknhk/test/test_sha3.c "KECCAK-P" (little-endian lanes)
        exp24[0] = 64'h8374b05252ed8115;  exp24[1] = 64'h1df7a676b6569400;
        exp24[2] = 64'hf765194b8a51797d;  exp24[3] = 64'h20477b43d1760545;
        exp24[4] = 64'hd15f8ba4f3f6606a;  exp24[5] = 64'ha1d7144f7c8dd493;
        exp24[6] = 64'h30d193965138fd3f;  exp24[7] = 64'h487e9472951be3be;
        exp24[8] = 64'h0cf3a858cbda7a5a;  exp24[9] = 64'h2fe54e389bb17f88;
        exp24[10] = 64'h0b7338de0d9f268f; exp24[11] = 64'h55efdff58b256d7f;
        exp24[12] = 64'hc8353e94eb2c3e6a; exp24[13] = 64'h2e2af6948c901f11;
        exp24[14] = 64'he873de0cca309da6; exp24[15] = 64'hf7afc26c944d31e2;
        exp24[16] = 64'ha0f5ea808cc415d7; exp24[17] = 64'h53f531437e3ed8cf;
        exp24[18] = 64'h777f1f3b43a4d221; exp24[19] = 64'hfd0ca63cb499e985;
        exp24[20] = 64'hd4c055c0c5d12330; exp24[21] = 64'ha72fe58aa6e0a7df;
        exp24[22] = 64'h421af5937c9948a3; exp24[23] = 64'h5e16103071340888;
        exp24[24] = 64'hd153f43a297e4a33;
        //  riscv-pqc zvknhk/test/test_turbo.c "KECCAK-P12"
        exp12[0] = 64'h31ccb6fee8eeccfe;  exp12[1] = 64'h57bf3dcca8d742e7;
        exp12[2] = 64'h33c23c8e00d5fd2d;  exp12[3] = 64'h27408b85c213997d;
        exp12[4] = 64'h442b508505b591ae;  exp12[5] = 64'he7f3957f8698d9d0;
        exp12[6] = 64'h24e9ce4cb83dbdf3;  exp12[7] = 64'hc6ed14e10f4998ba;
        exp12[8] = 64'ha445718c4dd30e41;  exp12[9] = 64'ha618c4ddc4f4c14b;
        exp12[10] = 64'h862dab386c0b9ed0; exp12[11] = 64'h0fdade9dec4f977c;
        exp12[12] = 64'h38aa031a06ff1231; exp12[13] = 64'hf4b748a9ffecfc5c;
        exp12[14] = 64'hd0af5893c33a5f19; exp12[15] = 64'h4dc1ff1ef5fa9c46;
        exp12[16] = 64'hb15d80df5456c26b; exp12[17] = 64'h3a66709440a0c35b;
        exp12[18] = 64'hebbdd410f2e7a223; exp12[19] = 64'h7020a73b189a733d;
        exp12[20] = 64'ha3ea1df2b9a8f601; exp12[21] = 64'hd15d52bc81a76225;
        exp12[22] = 64'heaac3058e82f6ac1; exp12[23] = 64'h1de0c38ae5544e5e;
        exp12[24] = 64'h72fa1a9d2dc565dd;

        #22 rst = 1'b0; #20;
        run(5'd24, "KECCAK-P");
        run(5'd12, "KECCAK-P12");
        run(5'd24, "KECCAK-P again");       //  back-to-back reuse after a 12-round run
        if (fails != 0) begin $display("tb_keccak_kat: FAIL (%0d)", fails); $fatal(1); end
        $display("tb_keccak_kat: PASS");
        $finish;
    end
endmodule
