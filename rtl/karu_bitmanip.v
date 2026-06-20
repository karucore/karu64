//  karu_bitmanip.v
//  Single-cycle combinational scalar bit-manipulation unit -- Zba + Zbb + Zbs
//  (RVA23U64-mandatory). Peer of karu_alu: op1=rs1, op2=rs2-or-shamt, sub picks
//  the op (BM_* in karu_uop_defs.vh), is_w selects the 32-bit W variants of
//  clz/ctz/cpop/rol/ror. The .uw forms (Zba) zero-extend rs1[31:0] and carry
//  their own sub codes (not is_w). Validated against a C reference by
//  test/bitmanip (make bitmanip-unit-test) and against spike at the core level.

`include "karu_uop_defs.vh"

module karu_bitmanip (
    input  wire [63:0]  op1,    //  rs1
    input  wire [63:0]  op2,    //  rs2, or {shamt} for immediate forms
    input  wire [4:0]   sub,    //  BM_*
    input  wire         is_w,   //  W (32-bit) variant: clz/ctz/cpop/rol/ror
    output wire [63:0]  out
);
    //  ---- shift amounts ----
    wire [5:0] sh6 = op2[5:0];  //  rotate/bit amount (64-bit)
    wire [4:0] sh5 = op2[4:0];  //  rotate amount (32-bit W)

    //  ---- Zbb logical-with-negate ----
    wire [63:0] r_andn = op1 & ~op2;
    wire [63:0] r_orn  = op1 | ~op2;
    wire [63:0] r_xnor = ~(op1 ^ op2);

    //  ---- Zbb min/max (signed + unsigned) ----
    wire signed [63:0] s1 = op1;
    wire signed [63:0] s2 = op2;
    wire [63:0] r_max  = (s1 > s2)   ? op1 : op2;
    wire [63:0] r_min  = (s1 < s2)   ? op1 : op2;
    wire [63:0] r_maxu = (op1 > op2) ? op1 : op2;
    wire [63:0] r_minu = (op1 < op2) ? op1 : op2;

    //  ---- Zbb sext/zext ----
    wire [63:0] r_sextb = {{56{op1[7]}},  op1[7:0]};
    wire [63:0] r_sexth = {{48{op1[15]}}, op1[15:0]};
    wire [63:0] r_zexth = {48'b0, op1[15:0]};

    //  ---- Zbb count leading/trailing zeros, popcount (64- and 32-bit) ----
    function [7:0] f_clz; input [63:0] v; input is32; integer i; reg done;
        begin
            f_clz = is32 ? 8'd32 : 8'd64; done = 1'b0;
            for (i = 63; i >= 0; i = i - 1)
                if (!done && (!is32 || i < 32) && v[i]) begin
                    f_clz = (is32 ? 8'd31 : 8'd63) - i[7:0]; done = 1'b1;
                end
        end
    endfunction
    function [7:0] f_ctz; input [63:0] v; input is32; integer i; reg done; integer lim;
        begin
            lim = is32 ? 32 : 64;
            f_ctz = is32 ? 8'd32 : 8'd64; done = 1'b0;
            for (i = 0; i < 64; i = i + 1)
                if (!done && i < lim && v[i]) begin f_ctz = i[7:0]; done = 1'b1; end
        end
    endfunction
    function [7:0] f_cpop; input [63:0] v; input is32; integer i; reg [7:0] c; integer lim;
        begin
            lim = is32 ? 32 : 64; c = 8'd0;
            for (i = 0; i < 64; i = i + 1) if (i < lim) c = c + {7'b0, v[i]};
            f_cpop = c;
        end
    endfunction
    wire [63:0] r_clz  = {56'b0, f_clz (op1, is_w)};
    wire [63:0] r_ctz  = {56'b0, f_ctz (op1, is_w)};
    wire [63:0] r_cpop = {56'b0, f_cpop(op1, is_w)};

    //  ---- Zbb rotate (64-bit; W rotates the low 32 then sign-extends) ----
    //  sh==0 is guarded (a 64-/32-wide right shift by the width is 0 in Verilog,
    //  so the OR'd halves would otherwise drop the value).
    wire [6:0] csh6 = 7'd64 - {1'b0, sh6};  //  complement amount (guarded sh6!=0)
    wire [5:0] csh5 = 6'd32 - {1'b0, sh5};
    wire [63:0] rol64 = sh6 == 6'd0 ? op1 : ((op1 << sh6) | (op1 >> csh6));
    wire [63:0] ror64 = sh6 == 6'd0 ? op1 : ((op1 >> sh6) | (op1 << csh6));
    wire [31:0] w32   = op1[31:0];
    wire [31:0] rolw  = sh5 == 5'd0 ? w32 : ((w32 << sh5) | (w32 >> csh5));
    wire [31:0] rorw  = sh5 == 5'd0 ? w32 : ((w32 >> sh5) | (w32 << csh5));
    wire [63:0] r_rol = is_w ? {{32{rolw[31]}}, rolw} : rol64;
    wire [63:0] r_ror = is_w ? {{32{rorw[31]}}, rorw} : ror64;

    //  ---- Zbb orc.b: each byte -> 0xFF if any bit set, else 0x00 ----
    wire [63:0] r_orcb;
    genvar gb;
    generate for (gb = 0; gb < 8; gb = gb + 1) begin : g_orcb
        assign r_orcb[gb*8 +: 8] = (|op1[gb*8 +: 8]) ? 8'hFF : 8'h00;
    end endgenerate

    //  ---- Zbb rev8: reverse byte order ----
    wire [63:0] r_rev8 = {op1[7:0],   op1[15:8],  op1[23:16], op1[31:24],
                          op1[39:32], op1[47:40], op1[55:48], op1[63:56]};

    //  ---- Zba shifted-add + unsigned-word forms ----
    wire [63:0] uw = {32'b0, op1[31:0]};    //  zext.w(rs1)
    wire [63:0] r_sh1add   = op2 + (op1 << 1);
    wire [63:0] r_sh2add   = op2 + (op1 << 2);
    wire [63:0] r_sh3add   = op2 + (op1 << 3);
    wire [63:0] r_adduw    = op2 + uw;
    wire [63:0] r_sh1adduw = op2 + (uw << 1);
    wire [63:0] r_sh2adduw = op2 + (uw << 2);
    wire [63:0] r_sh3adduw = op2 + (uw << 3);
    wire [63:0] r_slliuw   = uw << sh6;     //  slli.uw: shamt in op2 (6-bit)

    //  ---- Zbs single-bit (index = op2[5:0]) ----
    wire [63:0] onehot = 64'd1 << sh6;
    wire [63:0] r_bclr = op1 & ~onehot;
    wire [63:0] r_bext = {63'b0, op1[sh6]};
    wire [63:0] r_binv = op1 ^ onehot;
    wire [63:0] r_bset = op1 | onehot;

    assign out =
        (sub == `BM_ANDN)     ? r_andn :
        (sub == `BM_ORN)      ? r_orn  :
        (sub == `BM_XNOR)     ? r_xnor :
        (sub == `BM_CLZ)      ? r_clz  :
        (sub == `BM_CTZ)      ? r_ctz  :
        (sub == `BM_CPOP)     ? r_cpop :
        (sub == `BM_MAX)      ? r_max  :
        (sub == `BM_MAXU)     ? r_maxu :
        (sub == `BM_MIN)      ? r_min  :
        (sub == `BM_MINU)     ? r_minu :
        (sub == `BM_SEXTB)    ? r_sextb :
        (sub == `BM_SEXTH)    ? r_sexth :
        (sub == `BM_ZEXTH)    ? r_zexth :
        (sub == `BM_ROL)      ? r_rol  :
        (sub == `BM_ROR)      ? r_ror  :
        (sub == `BM_ORCB)     ? r_orcb :
        (sub == `BM_REV8)     ? r_rev8 :
        (sub == `BM_SH1ADD)   ? r_sh1add :
        (sub == `BM_SH2ADD)   ? r_sh2add :
        (sub == `BM_SH3ADD)   ? r_sh3add :
        (sub == `BM_ADDUW)    ? r_adduw :
        (sub == `BM_SH1ADDUW) ? r_sh1adduw :
        (sub == `BM_SH2ADDUW) ? r_sh2adduw :
        (sub == `BM_SH3ADDUW) ? r_sh3adduw :
        (sub == `BM_SLLIUW)   ? r_slliuw :
        (sub == `BM_BCLR)     ? r_bclr :
        (sub == `BM_BEXT)     ? r_bext :
        (sub == `BM_BINV)     ? r_binv :
        (sub == `BM_BSET)     ? r_bset :
                                64'b0;
endmodule
