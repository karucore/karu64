//  karu_vest7.v
//  (Extracted from karu_vfpu.v 2026-06-11 when the dead karu_vfpu module
//  shell was removed -- the vector-FP FSM lives in karu_varith since the
//  merge; this combinational estimate helper is instantiated per-lane in
//  karu_vlane and was the only live module left in that file.)

`include "karu_fpkg.vh"
//  ---------------------------------------------------------------------------
//  karu_vest7 — combinational 7-bit reciprocal (vfrec7) / reciprocal-square-
//  root (vfrsqrt7) estimate. Bit-exact port of spike's softfloat
//  fall_reciprocal.c (recip7 / rsqrte7). SEW32 -> F (e=8,s=23), SEW64 -> D
//  (e=11,s=52); e16/e8 never reach here (same SEW dispatch as the rest of
//  the vector-FP path in karu_varith). The only "loop" in the reference
//  (subnormal normalisation) is a
//  leading-zero count + shift, so the whole thing is one combinational cone.
//  ---------------------------------------------------------------------------
module karu_vest7 (
    input  wire [63:0]  a,          //  source element (F in [31:0], D = full 64)
    input  wire         is_d,
    input  wire         is_rec,     //  1 = vfrec7, 0 = vfrsqrt7
    input  wire [2:0]   rm,         //  frm (== softfloat rounding-mode numbering)
    output reg  [63:0]  res,
    output reg  [4:0]   flags
);
    //  ---- the two 128-entry tables (verbatim from fall_reciprocal.c) ----
    reg [6:0] rsq [0:127];
    reg [6:0] rcp [0:127];
    initial begin
        rsq[  0]=52;rsq[  1]=51;rsq[  2]=50;rsq[  3]=48;rsq[  4]=47;rsq[  5]=46;rsq[  6]=44;rsq[  7]=43;
        rsq[  8]=42;rsq[  9]=41;rsq[ 10]=40;rsq[ 11]=39;rsq[ 12]=38;rsq[ 13]=36;rsq[ 14]=35;rsq[ 15]=34;
        rsq[ 16]=33;rsq[ 17]=32;rsq[ 18]=31;rsq[ 19]=30;rsq[ 20]=30;rsq[ 21]=29;rsq[ 22]=28;rsq[ 23]=27;
        rsq[ 24]=26;rsq[ 25]=25;rsq[ 26]=24;rsq[ 27]=23;rsq[ 28]=23;rsq[ 29]=22;rsq[ 30]=21;rsq[ 31]=20;
        rsq[ 32]=19;rsq[ 33]=19;rsq[ 34]=18;rsq[ 35]=17;rsq[ 36]=16;rsq[ 37]=16;rsq[ 38]=15;rsq[ 39]=14;
        rsq[ 40]=14;rsq[ 41]=13;rsq[ 42]=12;rsq[ 43]=12;rsq[ 44]=11;rsq[ 45]=10;rsq[ 46]=10;rsq[ 47]= 9;
        rsq[ 48]= 9;rsq[ 49]= 8;rsq[ 50]= 7;rsq[ 51]= 7;rsq[ 52]= 6;rsq[ 53]= 6;rsq[ 54]= 5;rsq[ 55]= 4;
        rsq[ 56]= 4;rsq[ 57]= 3;rsq[ 58]= 3;rsq[ 59]= 2;rsq[ 60]= 2;rsq[ 61]= 1;rsq[ 62]= 1;rsq[ 63]= 0;
        rsq[ 64]=127;rsq[ 65]=125;rsq[ 66]=123;rsq[ 67]=121;rsq[ 68]=119;rsq[ 69]=118;rsq[ 70]=116;rsq[ 71]=114;
        rsq[ 72]=113;rsq[ 73]=111;rsq[ 74]=109;rsq[ 75]=108;rsq[ 76]=106;rsq[ 77]=105;rsq[ 78]=103;rsq[ 79]=102;
        rsq[ 80]=100;rsq[ 81]= 99;rsq[ 82]= 97;rsq[ 83]= 96;rsq[ 84]= 95;rsq[ 85]= 93;rsq[ 86]= 92;rsq[ 87]= 91;
        rsq[ 88]= 90;rsq[ 89]= 88;rsq[ 90]= 87;rsq[ 91]= 86;rsq[ 92]= 85;rsq[ 93]= 84;rsq[ 94]= 83;rsq[ 95]= 82;
        rsq[ 96]= 80;rsq[ 97]= 79;rsq[ 98]= 78;rsq[ 99]= 77;rsq[100]= 76;rsq[101]= 75;rsq[102]= 74;rsq[103]= 73;
        rsq[104]= 72;rsq[105]= 71;rsq[106]= 70;rsq[107]= 70;rsq[108]= 69;rsq[109]= 68;rsq[110]= 67;rsq[111]= 66;
        rsq[112]= 65;rsq[113]= 64;rsq[114]= 63;rsq[115]= 63;rsq[116]= 62;rsq[117]= 61;rsq[118]= 60;rsq[119]= 59;
        rsq[120]= 59;rsq[121]= 58;rsq[122]= 57;rsq[123]= 56;rsq[124]= 56;rsq[125]= 55;rsq[126]= 54;rsq[127]= 53;

        rcp[  0]=127;rcp[  1]=125;rcp[  2]=123;rcp[  3]=121;rcp[  4]=119;rcp[  5]=117;rcp[  6]=116;rcp[  7]=114;
        rcp[  8]=112;rcp[  9]=110;rcp[ 10]=109;rcp[ 11]=107;rcp[ 12]=105;rcp[ 13]=104;rcp[ 14]=102;rcp[ 15]=100;
        rcp[ 16]= 99;rcp[ 17]= 97;rcp[ 18]= 96;rcp[ 19]= 94;rcp[ 20]= 93;rcp[ 21]= 91;rcp[ 22]= 90;rcp[ 23]= 88;
        rcp[ 24]= 87;rcp[ 25]= 85;rcp[ 26]= 84;rcp[ 27]= 83;rcp[ 28]= 81;rcp[ 29]= 80;rcp[ 30]= 79;rcp[ 31]= 77;
        rcp[ 32]= 76;rcp[ 33]= 75;rcp[ 34]= 74;rcp[ 35]= 72;rcp[ 36]= 71;rcp[ 37]= 70;rcp[ 38]= 69;rcp[ 39]= 68;
        rcp[ 40]= 66;rcp[ 41]= 65;rcp[ 42]= 64;rcp[ 43]= 63;rcp[ 44]= 62;rcp[ 45]= 61;rcp[ 46]= 60;rcp[ 47]= 59;
        rcp[ 48]= 58;rcp[ 49]= 57;rcp[ 50]= 56;rcp[ 51]= 55;rcp[ 52]= 54;rcp[ 53]= 53;rcp[ 54]= 52;rcp[ 55]= 51;
        rcp[ 56]= 50;rcp[ 57]= 49;rcp[ 58]= 48;rcp[ 59]= 47;rcp[ 60]= 46;rcp[ 61]= 45;rcp[ 62]= 44;rcp[ 63]= 43;
        rcp[ 64]= 42;rcp[ 65]= 41;rcp[ 66]= 40;rcp[ 67]= 40;rcp[ 68]= 39;rcp[ 69]= 38;rcp[ 70]= 37;rcp[ 71]= 36;
        rcp[ 72]= 35;rcp[ 73]= 35;rcp[ 74]= 34;rcp[ 75]= 33;rcp[ 76]= 32;rcp[ 77]= 31;rcp[ 78]= 31;rcp[ 79]= 30;
        rcp[ 80]= 29;rcp[ 81]= 28;rcp[ 82]= 28;rcp[ 83]= 27;rcp[ 84]= 26;rcp[ 85]= 25;rcp[ 86]= 25;rcp[ 87]= 24;
        rcp[ 88]= 23;rcp[ 89]= 23;rcp[ 90]= 22;rcp[ 91]= 21;rcp[ 92]= 21;rcp[ 93]= 20;rcp[ 94]= 19;rcp[ 95]= 19;
        rcp[ 96]= 18;rcp[ 97]= 17;rcp[ 98]= 17;rcp[ 99]= 16;rcp[100]= 15;rcp[101]= 15;rcp[102]= 14;rcp[103]= 14;
        rcp[104]= 13;rcp[105]= 12;rcp[106]= 12;rcp[107]= 11;rcp[108]= 11;rcp[109]= 10;rcp[110]=  9;rcp[111]=  9;
        rcp[112]=  8;rcp[113]=  8;rcp[114]=  7;rcp[115]=  7;rcp[116]=  6;rcp[117]=  5;rcp[118]=  5;rcp[119]=  4;
        rcp[120]=  4;rcp[121]=  3;rcp[122]=  3;rcp[123]=  2;rcp[124]=  2;rcp[125]=  1;rcp[126]=  1;rcp[127]=  0;
    end

    function [6:0] clz64; input [63:0] v; integer i; reg done;
        begin clz64 = 7'd64; done = 1'b0;
            for (i = 63; i >= 0; i = i - 1)
                if (!done && v[i]) begin clz64 = 7'd63 - i[6:0]; done = 1'b1; end
        end
    endfunction

    //  ---- field decode (F uses the low 32 bits of a) ----
    wire        sgn = is_d ? a[63]   : a[31];
    wire [10:0] exp = is_d ? a[62:52] : {3'b0, a[30:23]};
    wire [51:0] sig = is_d ? a[51:0]  : {29'b0, a[22:0]};
    wire        exp_max = is_d ? (exp == 11'h7FF) : (exp[7:0] == 8'hFF);
    wire        sig_zero = (sig == 52'b0);
    wire        snan_bit = is_d ? sig[51] : sig[22];
    wire        is_inf  = exp_max && sig_zero;
    wire        is_nan  = exp_max && !sig_zero;
    wire        is_snan = is_nan && !snan_bit;
    wire        is_zero = (exp == 11'b0) && sig_zero;
    wire        is_sub  = (exp == 11'b0) && !sig_zero;

    //  ---- subnormal normalisation (clz + shift), exactly per the reference ----
    wire [63:0] sig_align = is_d ? ({12'b0, sig} << 12) : ({12'b0, sig} << 41);
    wire [6:0]  lz   = clz64(sig_align);                    //  only meaningful when is_sub
    wire [63:0] exp_eff = is_sub ? ({53'b0, exp} - {57'b0, lz}) : {53'b0, exp};
    wire [63:0] sigmask = is_d ? 64'h000F_FFFF_FFFF_FFFF : 64'h0000_0000_007F_FFFF;
    wire [63:0] sig_eff = is_sub ? (({12'b0, sig} << (lz + 7'd1)) & sigmask) : {12'b0, sig};

    //  ---- table index + significand ----
    wire [63:0] srsq = sig_eff >> (is_d ? 7'd46 : 7'd17);   //  top 6 bits of the s-bit field
    wire [63:0] srcp = sig_eff >> (is_d ? 7'd45 : 7'd16);   //  top 7 bits
    wire [6:0]  idx_rsq = {exp_eff[0], srsq[5:0]};
    wire [6:0]  idx_rcp = srcp[6:0];
    wire [6:0]  tabval  = is_rec ? rcp[idx_rcp] : rsq[idx_rsq];
    wire [63:0] out_sig0 = {57'b0, tabval} << (is_d ? 7'd45 : 7'd16);   //  << (s-7)

    //  ---- output exponents (64-bit modular arithmetic, matching the C) ----
    wire [63:0] threebias = is_d ? 64'd3069 : 64'd381;      //  3*(2^(e-1)-1)
    wire [63:0] twobias   = is_d ? 64'd2046 : 64'd254;      //  2*(2^(e-1)-1)
    wire [63:0] oexp_rsq  = (threebias + ~exp_eff) >> 1;
    wire [63:0] oexp_rcp_raw = twobias + ~exp_eff;
    wire        rcp_e0 = (oexp_rcp_raw == 64'd0);
    wire        rcp_em1 = (oexp_rcp_raw == {64{1'b1}});     //  == -1
    wire [63:0] impl1  = 64'd1 << (is_d ? 7'd51 : 7'd22);   //  1 << (s-1)
    wire [63:0] out_sig_rcp = rcp_em1 ? (((out_sig0 >> 1) | impl1) >> 1)
                              : rcp_e0  ?  ((out_sig0 >> 1) | impl1)
                              :             out_sig0;
    wire [63:0] out_exp_rcp = (rcp_e0 || rcp_em1) ? 64'd0 : oexp_rcp_raw;

    //  ---- composition pieces ----
    wire [5:0]  SHs    = is_d ? 6'd52 : 6'd23;              //  s
    wire [63:0] signf  = sgn ? (64'd1 << (is_d ? 7'd63 : 7'd31)) : 64'd0;
    wire [63:0] expall = is_d ? 64'h7FF0_0000_0000_0000 : 64'h0000_0000_7F80_0000;
    wire [63:0] pinf   = expall;
    wire [63:0] ninf   = expall | (64'd1 << (is_d ? 7'd63 : 7'd31));
    wire [63:0] dnan   = is_d ? `FP_D_QNAN : {32'b0, `FP_S_QNAN};
    wire [63:0] rsq_body = signf | (oexp_rsq    << SHs) | out_sig0;
    wire [63:0] rcp_body = signf | (out_exp_rcp << SHs) | out_sig_rcp;
    //  subnormal-input reciprocal that overflows: rm-dependent inf vs max-finite
    wire        rmax = (rm == 3'd1) || (rm == 3'd2 && !sgn) || (rm == 3'd3 && sgn);
    wire [63:0] rcp_ovf  = rmax ? ((signf | expall) - 64'd1) : (signf | expall);
    wire        rcp_abn  = is_sub && (exp_eff != 64'd0) && (exp_eff != {64{1'b1}});

    always @(*) begin
        res = 64'b0; flags = 5'b0;
        if (is_rec) begin
            if      (is_inf)  res = sgn ? (64'd1 << (is_d?7'd63:7'd31)) : 64'd0;    //  -inf->-0, +inf->+0
            else if (is_zero) begin res = sgn ? ninf : pinf; flags = (5'b1 << `FF_DZ); end
            else if (is_snan) begin res = dnan; flags = (5'b1 << `FF_NV); end
            else if (is_nan)  res = dnan;                               //  qNaN
            else if (rcp_abn) begin res = rcp_ovf; flags = (5'b1 << `FF_OF) | (5'b1 << `FF_NX); end
            else              res = rcp_body;                           //  normal/subnormal (both signs)
        end else begin  //  vfrsqrt7
            if      (is_nan)           begin res = dnan; flags = is_snan ? (5'b1 << `FF_NV) : 5'b0; end
            else if (sgn && !is_zero)  begin res = dnan; flags = (5'b1 << `FF_NV); end  //  -inf/-normal/-sub
            else if (is_zero)          begin res = sgn ? ninf : pinf; flags = (5'b1 << `FF_DZ); end
            else if (is_inf)           res = 64'd0;                     //  +inf -> +0
            else                       res = rsq_body;                  //  +normal/+subnormal
        end
    end
endmodule
