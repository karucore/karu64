//  karu_vest7.v

`include "karu_fpkg.vh"
//  ---------------------------------------------------------------------------
//  karu_vest7 -- combinational 7-bit reciprocal (vfrec7) /
//  reciprocal-square-root (vfrsqrt7) estimate. Bit-exact with Spike's
//  softfloat fall_reciprocal.c for SEW32 and SEW64; e16/e8 never reach this
//  helper. Subnormal normalisation is a leading-zero count plus shift, so the
//  whole module is one combinational cone.
//  ---------------------------------------------------------------------------
module karu_vest7 (
    input  wire [63:0]  a,          //  source element (F in [31:0], D = full 64)
    input  wire         is_d,
    input  wire         is_rec,     //  1 = vfrec7, 0 = vfrsqrt7
    input  wire [2:0]   rm,         //  frm (== softfloat rounding-mode numbering)
    output reg  [63:0]  res,
    output reg  [4:0]   flags
);
    //  ---- the two 128-entry Spike tables ----
    //  Case-ROM functions keep this Verilog-2001 portable across ASIC and FPGA
    //  synthesis flows.
    function [6:0] rsq_lut; input [6:0] i;
        case (i)
              0: rsq_lut = 7'd52 ;    1: rsq_lut = 7'd51 ;    2: rsq_lut = 7'd50 ;    3: rsq_lut = 7'd48 ;
              4: rsq_lut = 7'd47 ;    5: rsq_lut = 7'd46 ;    6: rsq_lut = 7'd44 ;    7: rsq_lut = 7'd43 ;
              8: rsq_lut = 7'd42 ;    9: rsq_lut = 7'd41 ;   10: rsq_lut = 7'd40 ;   11: rsq_lut = 7'd39 ;
             12: rsq_lut = 7'd38 ;   13: rsq_lut = 7'd36 ;   14: rsq_lut = 7'd35 ;   15: rsq_lut = 7'd34 ;
             16: rsq_lut = 7'd33 ;   17: rsq_lut = 7'd32 ;   18: rsq_lut = 7'd31 ;   19: rsq_lut = 7'd30 ;
             20: rsq_lut = 7'd30 ;   21: rsq_lut = 7'd29 ;   22: rsq_lut = 7'd28 ;   23: rsq_lut = 7'd27 ;
             24: rsq_lut = 7'd26 ;   25: rsq_lut = 7'd25 ;   26: rsq_lut = 7'd24 ;   27: rsq_lut = 7'd23 ;
             28: rsq_lut = 7'd23 ;   29: rsq_lut = 7'd22 ;   30: rsq_lut = 7'd21 ;   31: rsq_lut = 7'd20 ;
             32: rsq_lut = 7'd19 ;   33: rsq_lut = 7'd19 ;   34: rsq_lut = 7'd18 ;   35: rsq_lut = 7'd17 ;
             36: rsq_lut = 7'd16 ;   37: rsq_lut = 7'd16 ;   38: rsq_lut = 7'd15 ;   39: rsq_lut = 7'd14 ;
             40: rsq_lut = 7'd14 ;   41: rsq_lut = 7'd13 ;   42: rsq_lut = 7'd12 ;   43: rsq_lut = 7'd12 ;
             44: rsq_lut = 7'd11 ;   45: rsq_lut = 7'd10 ;   46: rsq_lut = 7'd10 ;   47: rsq_lut = 7'd9  ;
             48: rsq_lut = 7'd9  ;   49: rsq_lut = 7'd8  ;   50: rsq_lut = 7'd7  ;   51: rsq_lut = 7'd7  ;
             52: rsq_lut = 7'd6  ;   53: rsq_lut = 7'd6  ;   54: rsq_lut = 7'd5  ;   55: rsq_lut = 7'd4  ;
             56: rsq_lut = 7'd4  ;   57: rsq_lut = 7'd3  ;   58: rsq_lut = 7'd3  ;   59: rsq_lut = 7'd2  ;
             60: rsq_lut = 7'd2  ;   61: rsq_lut = 7'd1  ;   62: rsq_lut = 7'd1  ;   63: rsq_lut = 7'd0  ;
             64: rsq_lut = 7'd127;   65: rsq_lut = 7'd125;   66: rsq_lut = 7'd123;   67: rsq_lut = 7'd121;
             68: rsq_lut = 7'd119;   69: rsq_lut = 7'd118;   70: rsq_lut = 7'd116;   71: rsq_lut = 7'd114;
             72: rsq_lut = 7'd113;   73: rsq_lut = 7'd111;   74: rsq_lut = 7'd109;   75: rsq_lut = 7'd108;
             76: rsq_lut = 7'd106;   77: rsq_lut = 7'd105;   78: rsq_lut = 7'd103;   79: rsq_lut = 7'd102;
             80: rsq_lut = 7'd100;   81: rsq_lut = 7'd99 ;   82: rsq_lut = 7'd97 ;   83: rsq_lut = 7'd96 ;
             84: rsq_lut = 7'd95 ;   85: rsq_lut = 7'd93 ;   86: rsq_lut = 7'd92 ;   87: rsq_lut = 7'd91 ;
             88: rsq_lut = 7'd90 ;   89: rsq_lut = 7'd88 ;   90: rsq_lut = 7'd87 ;   91: rsq_lut = 7'd86 ;
             92: rsq_lut = 7'd85 ;   93: rsq_lut = 7'd84 ;   94: rsq_lut = 7'd83 ;   95: rsq_lut = 7'd82 ;
             96: rsq_lut = 7'd80 ;   97: rsq_lut = 7'd79 ;   98: rsq_lut = 7'd78 ;   99: rsq_lut = 7'd77 ;
            100: rsq_lut = 7'd76 ;  101: rsq_lut = 7'd75 ;  102: rsq_lut = 7'd74 ;  103: rsq_lut = 7'd73 ;
            104: rsq_lut = 7'd72 ;  105: rsq_lut = 7'd71 ;  106: rsq_lut = 7'd70 ;  107: rsq_lut = 7'd70 ;
            108: rsq_lut = 7'd69 ;  109: rsq_lut = 7'd68 ;  110: rsq_lut = 7'd67 ;  111: rsq_lut = 7'd66 ;
            112: rsq_lut = 7'd65 ;  113: rsq_lut = 7'd64 ;  114: rsq_lut = 7'd63 ;  115: rsq_lut = 7'd63 ;
            116: rsq_lut = 7'd62 ;  117: rsq_lut = 7'd61 ;  118: rsq_lut = 7'd60 ;  119: rsq_lut = 7'd59 ;
            120: rsq_lut = 7'd59 ;  121: rsq_lut = 7'd58 ;  122: rsq_lut = 7'd57 ;  123: rsq_lut = 7'd56 ;
            124: rsq_lut = 7'd56 ;  125: rsq_lut = 7'd55 ;  126: rsq_lut = 7'd54 ;  127: rsq_lut = 7'd53 ;
            default: rsq_lut = 7'd0;
        endcase
    endfunction

    function [6:0] rcp_lut; input [6:0] i;
        case (i)
              0: rcp_lut = 7'd127;    1: rcp_lut = 7'd125;    2: rcp_lut = 7'd123;    3: rcp_lut = 7'd121;
              4: rcp_lut = 7'd119;    5: rcp_lut = 7'd117;    6: rcp_lut = 7'd116;    7: rcp_lut = 7'd114;
              8: rcp_lut = 7'd112;    9: rcp_lut = 7'd110;   10: rcp_lut = 7'd109;   11: rcp_lut = 7'd107;
             12: rcp_lut = 7'd105;   13: rcp_lut = 7'd104;   14: rcp_lut = 7'd102;   15: rcp_lut = 7'd100;
             16: rcp_lut = 7'd99 ;   17: rcp_lut = 7'd97 ;   18: rcp_lut = 7'd96 ;   19: rcp_lut = 7'd94 ;
             20: rcp_lut = 7'd93 ;   21: rcp_lut = 7'd91 ;   22: rcp_lut = 7'd90 ;   23: rcp_lut = 7'd88 ;
             24: rcp_lut = 7'd87 ;   25: rcp_lut = 7'd85 ;   26: rcp_lut = 7'd84 ;   27: rcp_lut = 7'd83 ;
             28: rcp_lut = 7'd81 ;   29: rcp_lut = 7'd80 ;   30: rcp_lut = 7'd79 ;   31: rcp_lut = 7'd77 ;
             32: rcp_lut = 7'd76 ;   33: rcp_lut = 7'd75 ;   34: rcp_lut = 7'd74 ;   35: rcp_lut = 7'd72 ;
             36: rcp_lut = 7'd71 ;   37: rcp_lut = 7'd70 ;   38: rcp_lut = 7'd69 ;   39: rcp_lut = 7'd68 ;
             40: rcp_lut = 7'd66 ;   41: rcp_lut = 7'd65 ;   42: rcp_lut = 7'd64 ;   43: rcp_lut = 7'd63 ;
             44: rcp_lut = 7'd62 ;   45: rcp_lut = 7'd61 ;   46: rcp_lut = 7'd60 ;   47: rcp_lut = 7'd59 ;
             48: rcp_lut = 7'd58 ;   49: rcp_lut = 7'd57 ;   50: rcp_lut = 7'd56 ;   51: rcp_lut = 7'd55 ;
             52: rcp_lut = 7'd54 ;   53: rcp_lut = 7'd53 ;   54: rcp_lut = 7'd52 ;   55: rcp_lut = 7'd51 ;
             56: rcp_lut = 7'd50 ;   57: rcp_lut = 7'd49 ;   58: rcp_lut = 7'd48 ;   59: rcp_lut = 7'd47 ;
             60: rcp_lut = 7'd46 ;   61: rcp_lut = 7'd45 ;   62: rcp_lut = 7'd44 ;   63: rcp_lut = 7'd43 ;
             64: rcp_lut = 7'd42 ;   65: rcp_lut = 7'd41 ;   66: rcp_lut = 7'd40 ;   67: rcp_lut = 7'd40 ;
             68: rcp_lut = 7'd39 ;   69: rcp_lut = 7'd38 ;   70: rcp_lut = 7'd37 ;   71: rcp_lut = 7'd36 ;
             72: rcp_lut = 7'd35 ;   73: rcp_lut = 7'd35 ;   74: rcp_lut = 7'd34 ;   75: rcp_lut = 7'd33 ;
             76: rcp_lut = 7'd32 ;   77: rcp_lut = 7'd31 ;   78: rcp_lut = 7'd31 ;   79: rcp_lut = 7'd30 ;
             80: rcp_lut = 7'd29 ;   81: rcp_lut = 7'd28 ;   82: rcp_lut = 7'd28 ;   83: rcp_lut = 7'd27 ;
             84: rcp_lut = 7'd26 ;   85: rcp_lut = 7'd25 ;   86: rcp_lut = 7'd25 ;   87: rcp_lut = 7'd24 ;
             88: rcp_lut = 7'd23 ;   89: rcp_lut = 7'd23 ;   90: rcp_lut = 7'd22 ;   91: rcp_lut = 7'd21 ;
             92: rcp_lut = 7'd21 ;   93: rcp_lut = 7'd20 ;   94: rcp_lut = 7'd19 ;   95: rcp_lut = 7'd19 ;
             96: rcp_lut = 7'd18 ;   97: rcp_lut = 7'd17 ;   98: rcp_lut = 7'd17 ;   99: rcp_lut = 7'd16 ;
            100: rcp_lut = 7'd15 ;  101: rcp_lut = 7'd15 ;  102: rcp_lut = 7'd14 ;  103: rcp_lut = 7'd14 ;
            104: rcp_lut = 7'd13 ;  105: rcp_lut = 7'd12 ;  106: rcp_lut = 7'd12 ;  107: rcp_lut = 7'd11 ;
            108: rcp_lut = 7'd11 ;  109: rcp_lut = 7'd10 ;  110: rcp_lut = 7'd9  ;  111: rcp_lut = 7'd9  ;
            112: rcp_lut = 7'd8  ;  113: rcp_lut = 7'd8  ;  114: rcp_lut = 7'd7  ;  115: rcp_lut = 7'd7  ;
            116: rcp_lut = 7'd6  ;  117: rcp_lut = 7'd5  ;  118: rcp_lut = 7'd5  ;  119: rcp_lut = 7'd4  ;
            120: rcp_lut = 7'd4  ;  121: rcp_lut = 7'd3  ;  122: rcp_lut = 7'd3  ;  123: rcp_lut = 7'd2  ;
            124: rcp_lut = 7'd2  ;  125: rcp_lut = 7'd1  ;  126: rcp_lut = 7'd1  ;  127: rcp_lut = 7'd0  ;
            default: rcp_lut = 7'd0;
        endcase
    endfunction

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
    //  Top 6 / top 7 significand bits used by the Spike table index.
    wire [5:0]  srsq = sig_eff[(is_d ? 6'd46 : 6'd17) +: 6];
    wire [6:0]  srcp = sig_eff[(is_d ? 6'd45 : 6'd16) +: 7];
    wire [6:0]  idx_rsq = {exp_eff[0], srsq};
    wire [6:0]  idx_rcp = srcp;
    wire [6:0]  tabval  = is_rec ? rcp_lut(idx_rcp) : rsq_lut(idx_rsq);
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
