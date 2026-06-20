//  tb_zvk_decode.sv -- decode check for standard OP-VE Zvk encodings.
//
//  Run with the usual simulator command line, top module tb_zvk_decode,
//  and either -DKARU_ZVK or one official Zvk leaf define.

module tb_zvk_decode;
    reg [31:0] ins;
    wire [3:0] unit;
    wire [4:0] sub, rd, rs1, rs2, rs3;
    wire [63:0] imm;
    wire [1:0] size;
    wire sign_l, use_imm, use_pc, is_w;
    wire [11:0] csr_addr;
    wire rs1_is_f, rs2_is_f, rs3_is_f, rd_is_f, fp_is_d, vm, is_h;
    wire [3:0] fp_zfa;
    wire [2:0] vfunct3;
    wire [5:0] vfunct6;

    karu_dec dut (
        .ins(ins), .unit(unit), .sub(sub),
        .rd(rd), .rs1(rs1), .rs2(rs2), .rs3(rs3),
        .imm(imm), .size(size), .sign_l(sign_l),
        .use_imm(use_imm), .use_pc(use_pc), .is_w(is_w),
        .csr_addr(csr_addr),
        .rs1_is_f(rs1_is_f), .rs2_is_f(rs2_is_f),
        .rs3_is_f(rs3_is_f), .rd_is_f(rd_is_f), .fp_is_d(fp_is_d),
        .is_h(is_h), .fp_zfa(fp_zfa),
        .vm(vm), .vfunct3(vfunct3), .vfunct6(vfunct6)
    );

    task automatic check(
        input [31:0] word,
        input [4:0] exp_sub,
        input [8*16-1:0] name
    );
        begin
            ins = word; #1;
            if (unit !== `UNIT_VCRYPTO || sub !== exp_sub ||
                rd !== 5'd1 || rs2 !== 5'd2) begin
                $display("FAIL %0s ins=%08x unit=%0d sub=%0d rd=%0d rs1=%0d rs2=%0d",
                    name, word, unit, sub, rd, rs1, rs2);
                $finish(1);
            end
        end
    endtask

    task automatic check_trap(
        input [31:0] word,
        input [8*16-1:0] name
    );
        begin
            ins = word; #1;
            if (unit !== `UNIT_SYS || sub !== `SYS_TRAP) begin
                $display("FAIL %0s should trap ins=%08x unit=%0d sub=%0d",
                    name, word, unit, sub);
                $finish(1);
            end
        end
    endtask

    //  Zvkb ops are plain OP-V (0x57) arith -> UNIT_VARITH, not UNIT_VCRYPTO.
    task automatic check_varith(
        input [31:0] word,
        input [8*16-1:0] name
    );
        begin
            ins = word; #1;
            if (unit !== `UNIT_VARITH || rd !== 5'd1 || rs2 !== 5'd2) begin
                $display("FAIL %0s ins=%08x unit=%0d rd=%0d rs2=%0d",
                    name, word, unit, rd, rs2);
                $finish(1);
            end
        end
    endtask

    //  General-vs1 check: on the three-operand .vv crypto ops (vsha2*/vghsh/
    //  vsm3me) the vs1 field is a REAL operand, not a subopcode. Regression for
    //  the decode bug that gated these on vs1==v3 (the encoding-doc EXAMPLE
    //  operand), which SIGILL'd OpenSSL's runtime-dispatched Zvk SHA-2 (real
    //  operands were v16/v18).
    task automatic check_vs1(
        input [31:0] word,
        input [4:0] exp_sub, exp_rd, exp_rs2, exp_rs1,
        input [8*16-1:0] name
    );
        begin
            ins = word; #1;
            if (unit !== `UNIT_VCRYPTO || sub !== exp_sub ||
                rd !== exp_rd || rs2 !== exp_rs2 || rs1 !== exp_rs1) begin
                $display("FAIL %0s ins=%08x unit=%0d sub=%0d rd=%0d rs2=%0d rs1=%0d (exp sub=%0d rd=%0d rs2=%0d rs1=%0d)",
                    name, word, unit, sub, rd, rs2, rs1, exp_sub, exp_rd, exp_rs2, exp_rs1);
                $finish(1);
            end
        end
    endtask

    initial begin
`ifdef KARU_EN_ZVKNED
        check(32'ha22120f7, `VCRYPTO_AESEM,  "vaesem.vv");
        check(32'ha62120f7, `VCRYPTO_AESEM,  "vaesem.vs");
        check(32'ha221a0f7, `VCRYPTO_AESEF,  "vaesef.vv");
        check(32'ha621a0f7, `VCRYPTO_AESEF,  "vaesef.vs");
        check(32'ha22020f7, `VCRYPTO_AESDM,  "vaesdm.vv");
        check(32'ha62020f7, `VCRYPTO_AESDM,  "vaesdm.vs");
        check(32'ha220a0f7, `VCRYPTO_AESDF,  "vaesdf.vv");
        check(32'ha620a0f7, `VCRYPTO_AESDF,  "vaesdf.vs");
        check(32'ha623a0f7, `VCRYPTO_AESZ,   "vaesz.vs");
        check(32'h8a20a0f7, `VCRYPTO_AESKF1, "vaeskf1.vi");
        check(32'haa2120f7, `VCRYPTO_AESKF2, "vaeskf2.vi");
`else
        check_trap(32'ha22120f7, "vaesem.vv");
        check_trap(32'ha62120f7, "vaesem.vs");
        check_trap(32'ha221a0f7, "vaesef.vv");
        check_trap(32'ha621a0f7, "vaesef.vs");
        check_trap(32'ha22020f7, "vaesdm.vv");
        check_trap(32'ha62020f7, "vaesdm.vs");
        check_trap(32'ha220a0f7, "vaesdf.vv");
        check_trap(32'ha620a0f7, "vaesdf.vs");
        check_trap(32'ha623a0f7, "vaesz.vs");
        check_trap(32'h8a20a0f7, "vaeskf1.vi");
        check_trap(32'haa2120f7, "vaeskf2.vi");
`endif

`ifdef KARU_EN_ZVKNHA
        check(32'hba21a0f7, `VCRYPTO_SHA2CH, "vsha2ch.vv");
        check(32'hbe21a0f7, `VCRYPTO_SHA2CL, "vsha2cl.vv");
        check(32'hb621a0f7, `VCRYPTO_SHA2MS, "vsha2ms.vv");
        //  general-vs1 regression: real OpenSSL libcrypto SHA-2 encodings (vs1=v16/v18)
        check_vs1(32'hbf692c77, `VCRYPTO_SHA2CL, 5'd24, 5'd22, 5'd18, "vsha2cl v24,v22,v18");
        check_vs1(32'hbb892b77, `VCRYPTO_SHA2CH, 5'd22, 5'd24, 5'd18, "vsha2ch v22,v24,v18");
        check_vs1(32'hb7282577, `VCRYPTO_SHA2MS, 5'd10, 5'd18, 5'd16, "vsha2ms v10,v18,v16");
`else
        check_trap(32'hba21a0f7, "vsha2ch.vv");
        check_trap(32'hbe21a0f7, "vsha2cl.vv");
        check_trap(32'hb621a0f7, "vsha2ms.vv");
`endif

`ifdef KARU_EN_ZVKSED
        check(32'ha22820f7, `VCRYPTO_SM4R,   "vsm4r.vv");
        check(32'ha62820f7, `VCRYPTO_SM4R,   "vsm4r.vs");
        check(32'h8620a0f7, `VCRYPTO_SM4K,   "vsm4k.vi");
`else
        check_trap(32'ha22820f7, "vsm4r.vv");
        check_trap(32'ha62820f7, "vsm4r.vs");
        check_trap(32'h8620a0f7, "vsm4k.vi");
`endif

`ifdef KARU_EN_ZVKSH
        check(32'hae2020f7, `VCRYPTO_SM3C,   "vsm3c.vi");
        check(32'h8221a0f7, `VCRYPTO_SM3ME,  "vsm3me.vv");
        check_vs1(32'h822920f7, `VCRYPTO_SM3ME,  5'd1, 5'd2, 5'd18, "vsm3me v1,v2,v18");
`else
        check_trap(32'hae2020f7, "vsm3c.vi");
        check_trap(32'h8221a0f7, "vsm3me.vv");
`endif

`ifdef KARU_EN_ZVKG
        check(32'hb221a0f7, `VCRYPTO_GHSH,   "vghsh.vv");
        check_vs1(32'hb22920f7, `VCRYPTO_GHSH,   5'd1, 5'd2, 5'd18, "vghsh v1,v2,v18");
        check(32'ha228a0f7, `VCRYPTO_GMUL,   "vgmul.vv");
`else
        check_trap(32'hb221a0f7, "vghsh.vv");
        check_trap(32'ha228a0f7, "vgmul.vv");
`endif

        //  Same OP-VE/funct6 family as VAES.vs, but not a standard selector
        //  and not the local Keccak custom word.
        ins = 32'ha629a0f7; #1;
        if (unit !== `UNIT_SYS || sub !== `SYS_TRAP) begin
            $display("FAIL reserved OP-VE alias unit=%0d sub=%0d", unit, sub);
            $finish(1);
        end

`ifdef KARU_EN_KECCAK
        ins = 32'ha788a0f7; #1; // local full-permutation Keccak custom word
        if (unit !== `UNIT_VKECCAK || rd !== 5'd1) begin
            $display("FAIL keccak custom unit=%0d sub=%0d rd=%0d", unit, sub, rd);
            $finish(1);
        end
`endif

        //  ---- Zvkb (plain OP-V 0x57 -> UNIT_VARITH, unlike the OP-VE leaves) ----
`ifdef KARU_EN_ZVKB
        check_varith(32'h062180d7, "vandn.vv");
        check_varith(32'h0622c0d7, "vandn.vx");
        check_varith(32'h042180d7, "vandn.vv vm");
        check_varith(32'h4a2420d7, "vbrev8.v");
        check_varith(32'h482420d7, "vbrev8.v vm");
        check_varith(32'h4a24a0d7, "vrev8.v");
        check_varith(32'h562180d7, "vrol.vv");
        check_varith(32'h5622c0d7, "vrol.vx");
        check_varith(32'h522180d7, "vror.vv");
        check_varith(32'h5222c0d7, "vror.vx");
        check_varith(32'h5220b0d7, "vror.vi 1");
        check_varith(32'h5620b0d7, "vror.vi 33");
        //  vbrev.v (VXUNARY0 vs1=01010) is Zvbb-only, NOT Zvkb -> still traps
        check_trap(32'h4a2520d7, "vbrev.v");
`else
        check_trap(32'h062180d7, "vandn.vv");
        check_trap(32'h4a2420d7, "vbrev8.v");
        check_trap(32'h4a24a0d7, "vrev8.v");
        check_trap(32'h562180d7, "vrol.vv");
        check_trap(32'h522180d7, "vror.vv");
        check_trap(32'h5620b0d7, "vror.vi 33");
`endif

        $display("PASS zvk decode");
        $finish;
    end
endmodule
