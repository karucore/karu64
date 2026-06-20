// tb_aes_kat.sv -- self-checking FIPS-197 Appendix C.1 AES-128 KAT for the
// Marian-derived `encdec` + `key_expansion` cores (locally cleaned into karu64).
//
// Drives the encrypt round sequence (ZERO_RND, ENC_M_RND x9, ENC_F_RND) and the
// decrypt round-trip (ZERO_RND, DEC_M_RND x9, DEC_F_RND) over the published
// FIPS-197 C.1 vectors, plus the early per-round checkpoints. Also verifies the
// AES-128 key_expansion core generates RK1..RK10 from RK0.
//
// All vectors below are in FIPS *display* byte order (MSB-first as written in
// the standard). brev128() converts to the RVV element-group register layout
// (element/byte 0 in the low bits) that the cores operate on.
//
// Needs --timing for the #1 settle delays. Pure-combinational DUTs.
// Build sources: sboxes, aes_encdec, aes_key_expansion,
// then this file as --top-module tb_aes_kat (see /tmp/aes_kat.sh).

`timescale 1ns/1ps
module tb_aes_kat;

    // ---- encdec op encodings (match aes_encdec.v) ----
    localparam [2:0] ZERO_RND  = 3'b000;
    localparam [2:0] ENC_M_RND = 3'b010;
    localparam [2:0] ENC_F_RND = 3'b011;
    localparam [2:0] DEC_M_RND = 3'b100;
    localparam [2:0] DEC_F_RND = 3'b101;

    // ---- byte-reverse a 128-bit value (FIPS display order <-> register order) ----
    function automatic [127:0] brev128(input [127:0] x);
        integer i;
        begin
            brev128 = 128'b0;
            for (i = 0; i < 16; i = i + 1)
                brev128[8*i +: 8] = x[8*(15-i) +: 8];
        end
    endfunction

    // ---- FIPS-197 C.1 AES-128 vectors (display byte order) ----
    localparam [127:0] PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] CT  = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // Cipher key + expanded round keys (RK0 = cipher key)
    localparam [127:0] RK0  = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] RK1  = 128'hd6aa74fdd2af72fadaa678f1d6ab76fe;
    localparam [127:0] RK2  = 128'hb692cf0b643dbdf1be9bc5006830b3fe;
    localparam [127:0] RK3  = 128'hb6ff744ed2c2c9bf6c590cbf0469bf41;
    localparam [127:0] RK4  = 128'h47f7f7bc95353e03f96c32bcfd058dfd;
    localparam [127:0] RK5  = 128'h3caaa3e8a99f9deb50f3af57adf622aa;
    localparam [127:0] RK6  = 128'h5e390f7df7a69296a7553dc10aa31f6b;
    localparam [127:0] RK7  = 128'h14f9701ae35fe28c440adf4d4ea9c026;
    localparam [127:0] RK8  = 128'h47438735a41c65b9e016baf4aebf7ad2;
    localparam [127:0] RK9  = 128'h549932d1f08557681093ed9cbe2c974e;
    localparam [127:0] RK10 = 128'h13111d7fe3944a17f307a78b4d2b30c5;

    // Early round-state checkpoints (display byte order)
    localparam [127:0] CHK_AFTER_Z  = 128'h00102030405060708090a0b0c0d0e0f0; // round[1].start
    localparam [127:0] CHK_AFTER_M1 = 128'h89d810e8855ace682d1843d8cb128fe4; // round[1].output

    // ---- encdec DUT ----
    logic [2:0]   op;
    logic [127:0] state_in, key_in;
    logic [127:0] state_out;

    encdec u_encdec (
        .aes_op_i    (op),
        .rnd_state_i (state_in),
        .rnd_key_i   (key_in),
        .rnd_state_o (state_out)
    );

    // ---- key_expansion DUT (AES-128) ----
    logic [3:0]   kx_rnd;
    logic [127:0] kx_curr, kx_prev;
    logic [127:0] kx_next;

    key_expansion u_keyexp (
        .aes_kop_i      (1'b0),     // VAESFK1 = AES-128
        .rnd_i          (kx_rnd),
        .curr_rnd_key_i (kx_curr),
        .prev_rnd_key_i (kx_prev),  // unused for AES-128
        .next_rnd_key_o (kx_next)
    );

    integer errs = 0;
    logic [127:0] rk [0:10];     // round keys in register order
    logic [127:0] s;
    integer i;

    task automatic chk(input [127:0] got_reg, input [127:0] exp_disp,
                     input [127:0] label);
        logic [127:0] exp_reg;
        begin
            exp_reg = brev128(exp_disp);
            if (got_reg !== exp_reg) begin
                errs = errs + 1;
                $display("  FAIL [%0d]: got=%032h exp=%032h", label, got_reg, exp_reg);
            end else begin
                $display("  ok   [%0d]", label);
            end
        end
    endtask

    // one encdec round: drive, settle, capture
    task automatic round(input [2:0] o, input [127:0] k);
        begin
            op = o; state_in = s; key_in = k;
            #1;
            s = state_out;
        end
    endtask

    initial begin
        rk[0]=brev128(RK0);  rk[1]=brev128(RK1);  rk[2]=brev128(RK2);
        rk[3]=brev128(RK3);  rk[4]=brev128(RK4);  rk[5]=brev128(RK5);
        rk[6]=brev128(RK6);  rk[7]=brev128(RK7);  rk[8]=brev128(RK8);
        rk[9]=brev128(RK9);  rk[10]=brev128(RK10);

        // ---- key_expansion: derive RK1..RK10 from RK0 ----
        $display("-- key_expansion (AES-128) --");
        kx_prev = 128'b0;
        for (i = 1; i <= 10; i = i + 1) begin
            kx_rnd  = i[3:0];
            kx_curr = rk[i-1];
            #1;
            chk(kx_next, // got (register order)
                    (i==1)?RK1:(i==2)?RK2:(i==3)?RK3:(i==4)?RK4:(i==5)?RK5:
                    (i==6)?RK6:(i==7)?RK7:(i==8)?RK8:(i==9)?RK9:RK10, 100+i);
        end

        // ---- encrypt ----
        $display("-- encrypt --");
        s = brev128(PT);
        round(ZERO_RND, rk[0]);             chk(s, CHK_AFTER_Z,  0);
        round(ENC_M_RND, rk[1]);            chk(s, CHK_AFTER_M1, 1);
        for (i = 2; i <= 9; i = i + 1) round(ENC_M_RND, rk[i]);
        round(ENC_F_RND, rk[10]);           chk(s, CT, 10);

        // ---- decrypt round-trip ----
        $display("-- decrypt round-trip --");
        s = brev128(CT);
        round(ZERO_RND, rk[10]);
        for (i = 9; i >= 1; i = i - 1) round(DEC_M_RND, rk[i]);
        round(DEC_F_RND, rk[0]);            chk(s, PT, 20);

        if (errs == 0) $display("ENCDEC_KAT: PASS");
        else           $display("ENCDEC_KAT: FAIL (%0d errors)", errs);
        $finish;
    end

endmodule
