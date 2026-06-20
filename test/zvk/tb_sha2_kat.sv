// tb_sha2_kat.sv -- end-to-end SHA-256("abc") KAT for the locally cleaned Marian
// `compression` leaf core (Zvknha vsha2c[hl] datapath).
//
// The core performs TWO SHA-256 rounds per call. We drive all 32 two-round
// steps over the real FIPS-180 message schedule for the block "abc", thread the
// RVV-packed working state through, add to H0, and compare the result to the
// published SHA-256("abc") digest. This validates the reused datapath against
// the standard (the TB reference math is the canonical rotr/ch/maj form,
// independent of the core's internal structure).
//
// compression I/O packing (SEW32, low 128b of the 256 ports), from the core:
//   c_state_1_i (vs2) = {a,b,e,f}  a=[127:96] b=[95:64] e=[63:32] f=[31:0]
//   c_state_0_i (vd)  = {c,d,g,h}  c=[127:96] d=[95:64] g=[63:32] h=[31:0]
//   vs1  = 4x32 lanes; HIGH (sha_op[1]=0): W1=lane3=[127:96], W0=lane2=[95:64]
//   W0,W1 are (W[i]+K[i]) already summed ("message schedule + constant").
//   sha_op = {LOW?, SEW64?}; SHA-256 HIGH = 2'b00.
//   n_state_o = {a',b',e',f'} after the two rounds.
//
// Build: verilator --binary --timing -Wno-UNOPTFLAT -Wno-WIDTH -Wno-UNUSEDSIGNAL
//   -Wno-DECLFILENAME -Wno-UNUSEDPARAM
//   rtl/zvk/sha2_compression.v test/zvk/tb_sha2_kat.sv
//   --top-module tb_sha2_kat

`timescale 1ns/1ps
module tb_sha2_kat;

    // ---- SHA-256 round constants K[0..63] ----
    reg [31:0] K [0:63];
    // ---- message schedule W[0..63] for "abc" ----
    reg [31:0] W [0:63];
    // ---- initial hash ----
    reg [31:0] H [0:7];
    // expected digest
    reg [31:0] EXP [0:7];

    function automatic [31:0] rotr(input [31:0] x, input integer n);
        rotr = (x >> n) | (x << (32 - n));
    endfunction
    function automatic [31:0] ssig0(input [31:0] x); // small sigma0
        ssig0 = rotr(x,7) ^ rotr(x,18) ^ (x >> 3);
    endfunction
    function automatic [31:0] ssig1(input [31:0] x); // small sigma1
        ssig1 = rotr(x,17) ^ rotr(x,19) ^ (x >> 10);
    endfunction

    // ---- DUT ----
    reg  [255:0] c_state_0, c_state_1, msg_pc;
    reg  [1:0]   sha_op;
    wire [255:0] n_state;

    compression dut (
        .c_state_0_i   (c_state_0),
        .c_state_1_i   (c_state_1),
        .msg_sched_pc_i(msg_pc),
        .sha_op_i      (sha_op),
        .n_state_o     (n_state)
    );

    integer i;
    reg [31:0] a,b,c,d,e,f,g,h;
    reg [31:0] na,nb,ne,nf;       // returned {a,b,e,f}
    integer errs;

    initial begin
        // K
        K[0]=32'h428a2f98; K[1]=32'h71374491; K[2]=32'hb5c0fbcf; K[3]=32'he9b5dba5;
        K[4]=32'h3956c25b; K[5]=32'h59f111f1; K[6]=32'h923f82a4; K[7]=32'hab1c5ed5;
        K[8]=32'hd807aa98; K[9]=32'h12835b01; K[10]=32'h243185be; K[11]=32'h550c7dc3;
        K[12]=32'h72be5d74; K[13]=32'h80deb1fe; K[14]=32'h9bdc06a7; K[15]=32'hc19bf174;
        K[16]=32'he49b69c1; K[17]=32'hefbe4786; K[18]=32'h0fc19dc6; K[19]=32'h240ca1cc;
        K[20]=32'h2de92c6f; K[21]=32'h4a7484aa; K[22]=32'h5cb0a9dc; K[23]=32'h76f988da;
        K[24]=32'h983e5152; K[25]=32'ha831c66d; K[26]=32'hb00327c8; K[27]=32'hbf597fc7;
        K[28]=32'hc6e00bf3; K[29]=32'hd5a79147; K[30]=32'h06ca6351; K[31]=32'h14292967;
        K[32]=32'h27b70a85; K[33]=32'h2e1b2138; K[34]=32'h4d2c6dfc; K[35]=32'h53380d13;
        K[36]=32'h650a7354; K[37]=32'h766a0abb; K[38]=32'h81c2c92e; K[39]=32'h92722c85;
        K[40]=32'ha2bfe8a1; K[41]=32'ha81a664b; K[42]=32'hc24b8b70; K[43]=32'hc76c51a3;
        K[44]=32'hd192e819; K[45]=32'hd6990624; K[46]=32'hf40e3585; K[47]=32'h106aa070;
        K[48]=32'h19a4c116; K[49]=32'h1e376c08; K[50]=32'h2748774c; K[51]=32'h34b0bcb5;
        K[52]=32'h391c0cb3; K[53]=32'h4ed8aa4a; K[54]=32'h5b9cca4f; K[55]=32'h682e6ff3;
        K[56]=32'h748f82ee; K[57]=32'h78a5636f; K[58]=32'h84c87814; K[59]=32'h8cc70208;
        K[60]=32'h90befffa; K[61]=32'ha4506ceb; K[62]=32'hbef9a3f7; K[63]=32'hc67178f2;

        // H0
        H[0]=32'h6a09e667; H[1]=32'hbb67ae85; H[2]=32'h3c6ef372; H[3]=32'ha54ff53a;
        H[4]=32'h510e527f; H[5]=32'h9b05688c; H[6]=32'h1f83d9ab; H[7]=32'h5be0cd19;

        // SHA-256("abc")
        EXP[0]=32'hba7816bf; EXP[1]=32'h8f01cfea; EXP[2]=32'h414140de; EXP[3]=32'h5dae2223;
        EXP[4]=32'hb00361a3; EXP[5]=32'h96177a9c; EXP[6]=32'hb410ff61; EXP[7]=32'hf20015ad;

        // padded "abc" block (big-endian words)
        W[0]=32'h61626380;
        for (i=1;i<15;i=i+1) W[i]=32'h0;
        W[15]=32'h00000018;
        for (i=16;i<64;i=i+1)
            W[i] = ssig1(W[i-2]) + W[i-7] + ssig0(W[i-15]) + W[i-16];

        // working state
        a=H[0]; b=H[1]; c=H[2]; d=H[3]; e=H[4]; f=H[5]; g=H[6]; h=H[7];

        errs = 0;
        // 32 two-round steps via the compression core
        for (i=0;i<64;i=i+2) begin
            c_state_1 = {128'b0, a, b, e, f};      // vs2 = {a,b,e,f}
            c_state_0 = {128'b0, c, d, g, h};      // vd  = {c,d,g,h}
            // HIGH packing: lane3=W1=(W[i+1]+K[i+1]), lane2=W0=(W[i]+K[i]); lanes1,0 unused
            msg_pc    = {128'b0,
                   (W[i+1]+K[i+1]),          // lane3 [127:96] = W1
                   (W[i]  +K[i]  ),          // lane2 [95:64]  = W0
                   32'b0, 32'b0};            // lane1, lane0
            sha_op    = 2'b00;                     // SHA-256 HIGH
            #1;
            {na,nb,ne,nf} = n_state[127:0];
            // after 2 rounds the canonical schedule advances {a,b,e,f} to {na,nb,ne,nf};
            // the carried-down vars become: new c=old a, d=old b, g=old e, h=old f.
            c = a; d = b; g = e; h = f;
            a = na; b = nb; e = ne; f = nf;
        end

        // final hash add
        a = a + H[0]; b = b + H[1]; c = c + H[2]; d = d + H[3];
        e = e + H[4]; f = f + H[5]; g = g + H[6]; h = h + H[7];

        $display("-- SHA-256(\"abc\") via compression core --");
        if (a!==EXP[0]) begin errs=errs+1; $display("  FAIL H0 got=%08h exp=%08h",a,EXP[0]); end
        if (b!==EXP[1]) begin errs=errs+1; $display("  FAIL H1 got=%08h exp=%08h",b,EXP[1]); end
        if (c!==EXP[2]) begin errs=errs+1; $display("  FAIL H2 got=%08h exp=%08h",c,EXP[2]); end
        if (d!==EXP[3]) begin errs=errs+1; $display("  FAIL H3 got=%08h exp=%08h",d,EXP[3]); end
        if (e!==EXP[4]) begin errs=errs+1; $display("  FAIL H4 got=%08h exp=%08h",e,EXP[4]); end
        if (f!==EXP[5]) begin errs=errs+1; $display("  FAIL H5 got=%08h exp=%08h",f,EXP[5]); end
        if (g!==EXP[6]) begin errs=errs+1; $display("  FAIL H6 got=%08h exp=%08h",g,EXP[6]); end
        if (h!==EXP[7]) begin errs=errs+1; $display("  FAIL H7 got=%08h exp=%08h",h,EXP[7]); end

        if (errs==0) $display("SHA256_COMPRESSION_KAT: PASS  digest=%08h%08h%08h%08h%08h%08h%08h%08h",
                          a,b,c,d,e,f,g,h);
        else         $display("SHA256_COMPRESSION_KAT: FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
