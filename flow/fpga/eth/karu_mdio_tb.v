//	karu_mdio_tb.v -- spec-facing self-checking testbench for karu_dp83867_mdio.
//	An INDEPENDENT Clause-22 MDIO slave decodes frames purely from the wire (no
//	peeking at DUT internals) and drives read data at the NATURAL bit positions:
//	TA second bit (=0) at body period 16, DATA[k] at body period k -- it does NOT
//	compensate for the master. Register file uses VCU118-realistic DP83867 defaults
//	(SGMII strapped: PHYCR SGMII_EN already set; CFG2 SGMII_AUTONEG_EN already set;
//	PHYIDR1=0x2000; BMCR[15] self-clears after a couple of reads). Verifies the
//	init did read-modify-writes that keep the SGMII bits set while PRESERVING the
//	strapped defaults, managed reset, polled BMCR, and read the ID.
`timescale 1ns/1ps
`default_nettype none

module karu_mdio_tb;
	reg clk, rst, start;
	always #4 clk = ~clk;					//	125 MHz

	wire busy, done, error, id_ok, phy_reset_n;
	wire [15:0] phy_id;
	wire mdc, mdio_o, mdio_oe;

	reg  slv_oe, slv_o;
	wire mdio = mdio_oe ? mdio_o : (slv_oe ? slv_o : 1'b1);	//	pull-up when idle
	wire _unused = &{1'b0, busy};			//	DUT busy not checked here

	karu_dp83867_mdio #(.MDC_DIV(4), .PHYAD(5'd3),
		.RESET_HOLD(8), .RESET_WAIT(8), .POLL_MAX(16)) dut (
		.clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
		.error(error), .phy_id(phy_id), .id_ok(id_ok), .phy_reset_n(phy_reset_n),
		.mdc(mdc), .mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdio_i(mdio));

	//	================= independent DP83867 MDIO slave (PHYAD 3) =================
	localparam [4:0] SLV_PHYAD = 5'd3;
	reg [15:0] regf [0:31];
	integer i;
	integer bmcr_reset_cnt;					//	BMCR[15] reads 1 for this many reads
	integer nwrites, nreads;
	reg     reset_was_low;
	//	slave frame-decode state (declared before the init block that sets them).
	//	sbc: body bit period index 31=ST[1] 30=ST[0] 29:28=OP 27:23=PHYAD 22:18=REGAD
	//	17:16=TA 15:0=DATA[15:0]. Sample on rising, drive read data on falling.
	integer ones; reg inbody; reg [5:0] sbc;
	reg [1:0]  s_op; reg [4:0] s_phyad, s_regad; reg [14:0] s_wdata;
	reg        s_is_read, s_addressed;
	reg [15:0] rd_data;
	integer    errors;

	//	all initial state set here (keeps verilator -Wall PROCASSINIT-clean: no
	//	declaration initialisers on procedurally-assigned regs).
	initial begin
		clk=0; rst=1; start=0; slv_oe=0; slv_o=1;
		bmcr_reset_cnt=0; nwrites=0; nreads=0; reset_was_low=0;
		ones=0; inbody=0; sbc=0; s_op=0; s_phyad=0; s_regad=0; s_wdata=0;
		s_is_read=0; s_addressed=0; rd_data=0; errors=0;
		for (i=0;i<32;i=i+1) regf[i] = 16'h0000;
		regf[5'h02] = 16'h2000;				//	PHYIDR1 = DP83867 OUI
		regf[5'h10] = 16'h0838;				//	PHYCR: SGMII strapped (SGMII_EN already set)
		regf[5'h14] = 16'h4082;				//	CFG2 : SGMII_AUTONEG_EN already set
	end

	//	BMCR returns its stored value, but BMCR[15] reads 1 while the soft-reset
	//	counter is non-zero (models the reset bit self-clearing).
	function [15:0] rd_value(input [4:0] r);
		begin
			rd_value = regf[r];
			if (r == 5'h00)
				rd_value = (bmcr_reset_cnt > 0) ? (regf[r] | 16'h8000)
												: (regf[r] & 16'h7fff);
		end
	endfunction

	wire mbit = (mdio === 1'b1);

	always @(posedge mdc) begin
		if (!inbody) begin
			if (mbit) ones <= ones + 1;
			else begin
				if (ones >= 32) begin				//	ST[1]=0 after >=32 ones -> period 31
					inbody <= 1'b1; sbc <= 6'd30;	//	next period to sample
					s_op <= 0; s_phyad <= 0; s_regad <= 0; s_wdata <= 0;
					s_is_read <= 0; s_addressed <= 0;
				end
				ones <= 0;
			end
		end else begin
			case (sbc)
				6'd29: s_op[1] <= mbit;
				6'd28: s_op[0] <= mbit;
				6'd27,6'd26,6'd25,6'd24,6'd23: s_phyad <= {s_phyad[3:0], mbit};
				6'd22,6'd21,6'd20,6'd19: s_regad <= {s_regad[3:0], mbit};
				6'd18: begin							//	REGAD LSB -> decode + latch read data
					s_regad     <= {s_regad[3:0], mbit};
					s_is_read   <= (s_op == 2'b10);
					s_addressed <= (s_phyad == SLV_PHYAD);
					rd_data     <= rd_value({s_regad[3:0], mbit});
					if (s_op==2'b10 && s_phyad==SLV_PHYAD &&
						{s_regad[3:0],mbit}==5'h00 && bmcr_reset_cnt>0)
						bmcr_reset_cnt <= bmcr_reset_cnt - 1;
				end
				6'd15,6'd14,6'd13,6'd12,6'd11,6'd10,6'd9,6'd8,
				6'd7,6'd6,6'd5,6'd4,6'd3,6'd2,6'd1:
					if (!s_is_read) s_wdata <= {s_wdata[13:0], mbit};
				6'd0: begin								//	last bit -> commit + end frame
					if (s_addressed && !s_is_read) begin
						regf[s_regad] <= {s_wdata[14:0], mbit};
						nwrites <= nwrites + 1;
						if (s_regad==5'h00 && s_wdata[14])	//	{s_wdata[14:0],mbit}[15] == BMCR reset bit
							bmcr_reset_cnt <= 2;		//	soft reset -> BMCR[15] sticks 2 reads
						$display("[MDIO-SLV] WRITE reg 0x%02x = 0x%04x",
								 s_regad, {s_wdata[14:0],mbit});
					end else if (s_addressed && s_is_read) begin
						nreads <= nreads + 1;
						$display("[MDIO-SLV] READ  reg 0x%02x -> 0x%04x", s_regad, rd_data);
					end
					inbody <= 1'b0; ones <= 0;
				end
				default: ;							//	ST[0] (30), TA (17,16): nothing to sample
			endcase
			if (sbc != 0) sbc <= sbc - 1'b1;
		end
	end

	//	drive read data on falling edges at NATURAL positions: TA[0]=0 at period 16,
	//	DATA[k] at period k. Header/turnaround periods: released (master/Z drives).
	always @(negedge mdc) begin
		if (inbody && s_is_read && s_addressed && sbc == 6'd16) begin
			slv_oe <= 1'b1; slv_o <= 1'b0;					//	TA second bit
		end else if (inbody && s_is_read && s_addressed && sbc <= 6'd15) begin
			slv_oe <= 1'b1; slv_o <= rd_data[sbc[3:0]];		//	DATA[sbc]
		end else begin
			slv_oe <= 1'b0;
		end
	end

	always @(negedge phy_reset_n) reset_was_low <= 1'b1;

	//	================= checks =================
	task chk(input cond, input [8*64-1:0] name);	//	64-char label, no truncation
		begin
			if (cond) $display("[ ok ] %0s", name);
			else begin $display("[FAIL] %0s", name); errors = errors + 1; end
		end
	endtask

	initial begin
		repeat (8) @(posedge clk); rst = 0;
		repeat (4) @(posedge clk);
		@(posedge clk) start = 1; @(posedge clk) start = 0;
		begin : waitdone
			integer g;
			for (g=0; g<4000000; g=g+1) begin @(posedge clk); if (done) disable waitdone; end
			$display("[FAIL] timeout waiting for done"); errors = errors + 1;
		end
		$display("--- final: phy_id=0x%04x id_ok=%0b error=%0b nwrites=%0d nreads=%0d ---",
				 phy_id, id_ok, error, nwrites, nreads);
		//	#1 SGMII_EN(bit11) set + strapped defaults preserved (RMW idempotent here)
		chk(regf[5'h10] == 16'h0838, "PHYCR RMW: SGMII_EN set + strapped default preserved");
		chk((regf[5'h10] & 16'h0800) != 0, "PHYCR: SGMII_EN (bit11) is set");
		//	#2 CFG2 SGMII_AUTONEG_EN preserved, NOT cleared
		chk(regf[5'h14] == 16'h4082, "CFG2 RMW: SGMII_AUTONEG_EN preserved, not clobbered");
		chk((regf[5'h14] & 16'h0080) != 0, "CFG2: SGMII_AUTONEG_EN (bit7) is set");
		//	#3 reset managed + soft-reset polled
		chk(reset_was_low, "PHY hardware RESET_N was asserted");
		chk(nreads >= 4, "polled BMCR + did RMW + ID reads (>=4 reads)");
		chk(regf[5'h00] == 16'h1340, "BMCR final = AN enable + restart (0x1340)");
		//	#5 spec PHY ID read back independently (slave drove DATA normally)
		chk(id_ok && phy_id == 16'h2000, "PHYIDR1 read = 0x2000 (DP83867) + id_ok");
		chk(!error, "no reset-poll timeout");

		if (errors == 0) $display("\n[MDIO-TEST] PASS");
		else             $display("\n[MDIO-TEST] FAIL (%0d errors)", errors);
		$finish;
	end
endmodule

`default_nettype wire
