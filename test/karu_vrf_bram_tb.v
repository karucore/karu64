//	karu_vrf_bram_tb.v
//	Standalone self-checking testbench for the BRAM-backed VRF + its passive
//	checker. Exercises registered reads, byte-enabled writes (keep-old), the
//	v0 flop shadow, and concurrent dual-port access. The karu_vrf_assert
//	checker runs alongside: VRF5b cross-checks every read-back against the
//	BRAM, VRF1-4/7 police the stimulus, so a protocol or data bug $finishes
//	with a FAIL line. Clean run prints "VRF-BRAM TB PASS".
//
//	Run:  iverilog -g2012 -Irtl -o /tmp/vrftb test/karu_vrf_bram_tb.v \
//	          rtl/karu_vrf_bram.v rtl/karu_vrf_assert.sv && /tmp/vrftb

`include "karu_vcfg.vh"
`timescale 1ns/1ps

module karu_vrf_bram_tb;
	localparam VLEN   = `KARU_VLEN;
	localparam VBUS_W = `KARU_VBUS_W;
	localparam NBYTES = VBUS_W/8;
	localparam VGRAN  = VLEN/VBUS_W;
	localparam AW     = $clog2(32*VGRAN);

	reg clk = 0;
	always #5 clk = ~clk;

	reg					rst;
	reg					varith_active;
	reg					a_en, a_we, b_en, b_we;
	reg  [AW-1:0]		a_addr, b_addr;
	reg  [NBYTES-1:0]	a_be, b_be;
	reg  [VBUS_W-1:0]	a_wdata, b_wdata;
	wire [VBUS_W-1:0]	a_rdata, b_rdata;
	wire [VLEN-1:0]		v0;

	integer errors = 0;

	//	---- DUT ----
	karu_vrf_bram #(.VLEN(VLEN), .VBUS_W(VBUS_W)) dut (
		.clk(clk), .rst(rst),
		.a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_be(a_be), .a_wdata(a_wdata), .a_rdata(a_rdata),
		.b_en(b_en), .b_we(b_we), .b_addr(b_addr), .b_be(b_be), .b_wdata(b_wdata), .b_rdata(b_rdata),
		.v0(v0)
	);

	//	---- passive checker (cross-checks reads + polices the protocol) ----
	karu_vrf_assert #(.VLEN(VLEN), .VBUS_W(VBUS_W)) chk (
		.clk(clk), .rst(rst),
		.varith_active(varith_active), .vlsu_active(1'b0),
		.a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_be(a_be), .a_wdata(a_wdata), .a_rdata(a_rdata),
		.b_en(b_en), .b_we(b_we), .b_addr(b_addr), .b_be(b_be), .b_wdata(b_wdata), .b_rdata(b_rdata),
		.v0(v0),
		.wb_vl_governed(1'b0), .wb_mask_dest(1'b0),
		.wb_vl(16'd0), .wb_vsew(3'd0), .wb_group_reg(5'd0), .wb_epr(16'd0)
	);

	//	entry address for register r, granule g
	function [AW-1:0] ea; input [4:0] r; input integer g; ea = r*VGRAN + g; endfunction

	//	All stimulus is driven on the NEGEDGE so inputs are stable across the
	//	posedge the DUT (and the checker) sample on -- avoids the drive/sample
	//	race where deasserting an enable collides with the capturing edge.

	//	idle the ports (one cycle)
	task step; begin
		@(negedge clk);
		a_en=0; a_we=0; b_en=0; b_we=0; a_be=0; b_be=0;
		@(posedge clk);
	end endtask

	//	port-B write of one granule (held across exactly one posedge)
	task wr_b; input [4:0] r; input integer g; input [VBUS_W-1:0] d; input [NBYTES-1:0] be;
	begin
		@(negedge clk);
		b_en=1; b_we=1; b_addr=ea(r,g); b_wdata=d; b_be=be;
		a_en=0; a_we=0; a_be=0;
		@(posedge clk);				//	DUT captures the write here
		@(negedge clk);
		b_en=0; b_we=0; b_be=0;
	end endtask

	//	port-A read of one granule -> registered data valid the next cycle
	task rd_a; input [4:0] r; input integer g; output [VBUS_W-1:0] d;
	begin
		@(negedge clk);
		a_en=1; a_we=0; a_addr=ea(r,g); a_be=0;
		b_en=0; b_we=0; b_be=0;
		@(posedge clk);				//	DUT latches a_rdata <= mem[addr]
		@(negedge clk);
		a_en=0;
		d = a_rdata;				//	registered read data now valid
	end endtask

	task chk_eq; input [127:0] name; input [VBUS_W-1:0] got, exp;
	begin
		if (got !== exp) begin
			errors = errors + 1;
			$display("[TB] MISMATCH %0s: got=%h exp=%h", name, got, exp);
		end
	end endtask

	reg [VBUS_W-1:0] rdv;
	localparam [VBUS_W-1:0] P0 = {NBYTES/4{32'hA5A5_1234}};
	localparam [VBUS_W-1:0] P1 = {NBYTES/4{32'h5A5A_DEAD}};
	localparam [VBUS_W-1:0] PX = {NBYTES/4{32'h0BAD_F00D}};

	initial begin
		//	reset
		rst=1; varith_active=0;
		a_en=0; a_we=0; b_en=0; b_we=0; a_be=0; b_be=0;
		a_addr=0; b_addr=0; a_wdata=0; b_wdata=0;
		repeat (4) @(posedge clk);
		rst=0; varith_active=1; @(posedge clk);

		//	--- Test 1: write reg5 (both granules), read back ---
		wr_b(5,0,P0,{NBYTES{1'b1}});
		wr_b(5,1,P1,{NBYTES{1'b1}});
		rd_a(5,0,rdv); chk_eq("t1.g0", rdv, P0);
		rd_a(5,1,rdv); chk_eq("t1.g1", rdv, P1);

		//	--- Test 2: byte-enable keep-old (low 8 bytes written, high kept) ---
		wr_b(7,0,{VBUS_W{1'b0}},{NBYTES{1'b1}});			//	clear
		wr_b(7,0,{VBUS_W{1'b1}}, {{(NBYTES/2){1'b0}},{(NBYTES/2){1'b1}}});	//	low half = FF
		rd_a(7,0,rdv);
		chk_eq("t2.lo", rdv[VBUS_W/2-1:0],       {(VBUS_W/2){1'b1}});	//	written
		chk_eq("t2.hi", rdv[VBUS_W-1:VBUS_W/2],  {(VBUS_W/2){1'b0}});	//	kept old

		//	--- Test 3: v0 shadow tracks writes to register 0 ---
		wr_b(0,0,P0,{NBYTES{1'b1}});
		wr_b(0,1,P1,{NBYTES{1'b1}});
		chk_eq("t3.v0g0", v0[0      +: VBUS_W], P0);	//	granule-indexed (VGRAN-general)
		chk_eq("t3.v0g1", v0[VBUS_W +: VBUS_W], P1);
		//	partial v0 write: byte 0 only
		wr_b(0,0,{{(VBUS_W-8){1'b0}},8'h5A}, {{(NBYTES-1){1'b0}},1'b1});
		chk_eq("t3.v0b0", v0[7:0], 8'h5A);
		chk_eq("t3.v0b1", v0[15:8], P0[15:8]);	//	rest of granule 0 unchanged

		//	--- Test 4: concurrent dual port (A reads reg5g0 while B writes reg9g0) ---
		wr_b(9,0,{VBUS_W{1'b0}},{NBYTES{1'b1}});	//	seed reg9
		@(negedge clk);
		a_en=1; a_we=0; a_addr=ea(5,0); a_be=0;
		b_en=1; b_we=1; b_addr=ea(9,0); b_wdata=PX; b_be={NBYTES{1'b1}};
		@(posedge clk);								//	A latches reg5g0; B writes reg9g0 (diff addr)
		@(negedge clk);
		a_en=0; b_en=0; b_we=0; b_be=0;
		chk_eq("t4.Aread", a_rdata, P0);			//	reg5g0 still P0
		rd_a(9,0,rdv); chk_eq("t4.Bwrite", rdv, PX);	//	reg9g0 took PX

		//	--- Test 5: BRAM + v0 shadow RETAIN across a soft reset, stay
		//	coherent (would fail / fire VRF5a if v0_q were reset independently) ---
		wr_b(3,0,PX,{NBYTES{1'b1}}); wr_b(3,1,PX,{NBYTES{1'b1}});	//	reg3 = PX
		wr_b(0,0,P1,{NBYTES{1'b1}}); wr_b(0,1,P0,{NBYTES{1'b1}});	//	v0 = {P0,P1}
		@(negedge clk); rst=1; varith_active=0;
		repeat (2) @(posedge clk);
		@(negedge clk); rst=0; varith_active=1;
		@(posedge clk);
		chk_eq("t5.v0g0", v0[0      +: VBUS_W], P1);	//	v0 retained across reset (granule-indexed)
		chk_eq("t5.v0g1", v0[VBUS_W +: VBUS_W], P0);
		rd_a(3,0,rdv); chk_eq("t5.reg3", rdv, PX);	//	BRAM retained across reset

		step; step;
		if (errors == 0) $display("VRF-BRAM TB PASS");
		else             $display("VRF-BRAM TB FAIL (%0d mismatch[es])", errors);
		$finish;
	end

	//	global timeout
	initial begin #20000; $display("VRF-BRAM TB TIMEOUT"); $finish; end
endmodule
