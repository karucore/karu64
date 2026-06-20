//	standalone DUT wrapper for the FP16<->FP32 converters
`include "karu_fpkg.vh"
module fcvt_hs_tb (
	input  wire [2:0]  rm,
	input  wire [15:0] h_in,	output wire [31:0] s_out, output wire [4:0] hs_fl,
	input  wire [31:0] s_in,	output wire [15:0] h_out, output wire [4:0] sh_fl,
	input  wire [63:0] d_in,	output wire [15:0] dh_out, output wire [4:0] dh_fl
);
	karu_fcvt_hs u_w (.a(h_in), .res(s_out), .flags(hs_fl));
	karu_fcvt_sh u_n (.rm(rm), .a(s_in), .res(h_out), .flags(sh_fl));
	karu_fcvt_dh u_dn (.rm(rm), .a(d_in), .res(dh_out), .flags(dh_fl));
endmodule
