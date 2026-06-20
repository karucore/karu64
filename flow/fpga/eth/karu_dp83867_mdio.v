//	karu_dp83867_mdio.v
//	=== MDIO (IEEE 802.3 Clause 22) master that brings the TI DP83867 up in
//	**SGMII** mode on the VCU118 (DP83867ISRGZ, MDIO addr 00011=3, UG1224). The
//	VCU118 is **SGMII-only** and straps the PHY into SGMII (UG1224) -- this block
//	does NOT switch modes; it **ensures** the SGMII control bits via read-modify-
//	write (belt-and-suspenders, and to line the PHY's SGMII options up with the
//	1G PCS/PMA) without clobbering the strapped defaults:
//	  1. assert RESET_N (power-on hold), deassert, wait for the PHY to wake;
//	  2. BMCR(0x00)=soft-reset, then POLL BMCR[15] until it self-clears;
//	  3. RMW PHYCR(0x10)  |= SGMII_EN     (bit 11, 0x0800)  -- ensure set;
//	  4. RMW CFG2 (0x14)  |= SGMII_AN_EN  (bit  7, 0x0080)  -- ensure set, never
//	                                       clear (TI default-on);
//	  5. BMCR(0x00) = restart auto-negotiation;
//	  6. read PHYIDR1(0x02); id_ok when it reads 0x2000 (the DP83867 OUI value).
//	`error` latches if the reset-poll times out.
//
//	Spec anchors (TI DP83867E/IS/CS datasheet + AMD UG1224): PHYCR[11]=SGMII_EN,
//	CFG2[7]=SGMII_AUTONEG_EN, PHYIDR1=0x2000, MDIO max clock 25 MHz, PHY addr 3.
//	NOTE: two SGMII extended registers (MMD/Clause-45, via the 0x0D/0x0E indirect)
//	are NOT driven here -- they are distinct: SGMIICTL 0x0037[1:0] is the SGMII
//	AN status/control-page (a status check), while the 4-wire-CDR vs 6-wire-refclk
//	*mode* bit is SGMIICTL1 0x00D3[14]. Add once the PCS/PMA mode + board clocking
//	are decided (which also settles the GTH-vs-SelectIO question -- see UG1224).
//	There is no board here: this is sim-validated framing/sequencing (make
//	mdio-test), not on-wire bring-up.
//
//	MDIO timing (Clause 22): MDC = clk/(2*MDC_DIV) (keep <= 25 MHz). MDIO is driven
//	on the MDC **falling** edge and sampled on the **rising** edge, both directions.
//	For a read the master drives ST/OP/PHYAD/REGAD, releases for TA (2 bits) + DATA
//	(16 bits), and samples the 16 DATA bits the PHY drives -- no TA bit captured.
//	Plain Verilog-2001 (no SV constructs), `default_nettype none`.

`timescale 1ns/1ps
`default_nettype none

module karu_dp83867_mdio #(
	parameter integer MDC_DIV     = 25,		//	MDC = clk/(2*MDC_DIV); 125MHz/50 = 2.5MHz
	parameter [4:0]   PHYAD       = 5'd3,	//	DP83867 MDIO address (UG1224: 00011)
	parameter integer RESET_HOLD  = 1000,	//	cycles to hold RESET_N low (>= PHY min,
											//	~8us @125MHz; TI min reset pulse ~1us)
	parameter integer RESET_WAIT  = 25000,	//	cycles after RESET_N high before MDIO.
											//	TI DP83867 needs ~195us post-reset before
											//	the first MDC preamble (25000 @125MHz =
											//	200us). MDC keeps toggling with MDIO held
											//	high (engine idle) during this wait.
	parameter integer POLL_MAX    = 64		//	max BMCR-reset poll reads before giving up
) (
	input  wire			clk,
	input  wire			rst,
	input  wire			start,			//	pulse: run reset + init sequence
	output reg			busy,
	output reg			done,			//	1-cyc pulse when the sequence completes
	output reg			error,			//	latched: reset poll timed out
	output reg  [15:0]	phy_id,			//	PHYIDR1 (reg 2) read back
	output reg			id_ok,			//	phy_id == 0x2000 (DP83867 answered)

	//	---- PHY control pads ----
	output reg			phy_reset_n,	//	active-low PHY hardware reset (RESET_N)

	//	---- MDIO pads (to a tri-state IOBUF at the top level) ----
	output reg			mdc,
	output reg			mdio_o,			//	master drive value
	output reg			mdio_oe,		//	1 = master drives mdio, 0 = release (read)
	input  wire			mdio_i			//	mdio as seen on the pad
);
	localparam [15:0] PHYCR_SGMII_EN = 16'h0800;	//	PHYCR[11]
	localparam [15:0] CFG2_SGMII_AN  = 16'h0080;	//	CFG2[7]
	localparam [15:0] DP83867_ID1    = 16'h2000;	//	PHYIDR1
	localparam [4:0]  R_BMCR=5'h00, R_PHYIDR1=5'h02, R_PHYCR=5'h10, R_CFG2=5'h14;
	//	MMD (Clause-45-over-Clause-22) indirect access to the DP83867 extended registers:
	//	REGCR (0x0D) selects function+devad, ADDAR (0x0E) carries the address then the data.
	localparam [4:0]  R_REGCR=5'h0D, R_ADDAR=5'h0E;

	//	======== MDC generation: clean combinational edge pulses ========
	//	`half_done` marks the clk cycle that ends an MDC half-period; mdc toggles on
	//	it. Because mdc holds its OLD value during that cycle (nonblocking update),
	//	the falling edge (1->0) is `half_done & mdc` and the rising edge (0->1) is
	//	`half_done & ~mdc` -- aligned to the actual transition, no registered-tick
	//	shift. Drive on falling, sample on rising.
	localparam integer DIVW = $clog2(MDC_DIV+1);
	reg [DIVW-1:0] divcnt;
	/* verilator lint_off WIDTHTRUNC */
	localparam [DIVW-1:0] DIV_LAST = MDC_DIV - 1;	//	sized terminal count (V2001-safe)
	/* verilator lint_on WIDTHTRUNC */
	wire half_done = (divcnt == DIV_LAST);
	always @(posedge clk) begin
		if (rst)            begin divcnt <= 0; mdc <= 1'b0; end
		else if (half_done) begin divcnt <= 0; mdc <= ~mdc; end
		else                divcnt <= divcnt + 1'b1;
	end
	wire mdc_falling = half_done &&  mdc;	//	mdc about to go 1 -> 0
	wire mdc_rising  = half_done && !mdc;	//	mdc about to go 0 -> 1

	//	======== Clause-22 transaction engine (one read OR write frame) ========
	//	Frame = 32 preamble(1) + ST(01) + OP + PHYAD(5) + REGAD(5) + TA + DATA(16).
	//	tbody[31:0] = {ST[31:30],OP[29:28],PHYAD[27:23],REGAD[22:18],TA[17:16],DATA[15:0]}.
	//	Each bit period: PRESENT on the falling edge, SAMPLE/ADVANCE on the rising
	//	edge -- so `tcnt` is stable across the whole period and the read samples land
	//	exactly on DATA[15..0] (no TA bit captured, DATA[0] not dropped). `seen_fall`
	//	guards the one rising edge that precedes the first falling edge of the body.
	localparam [1:0] OP_WR = 2'b01, OP_RD = 2'b10;
	reg        t_start, t_op;			//	t_op: 0=write 1=read
	reg [4:0]  t_regad;
	reg [15:0] t_wdata;
	reg        t_done;
	reg [15:0] t_rdata;

	localparam T_IDLE=0, T_PRE=1, T_BODY=2, T_FIN=3;
	reg [1:0]  tstate;
	reg [5:0]  tcnt;
	reg        seen_fall;
	reg [31:0] tbody;

	always @(posedge clk) begin
		t_done <= 1'b0;
		if (rst) begin
			tstate <= T_IDLE; tcnt <= 0; tbody <= 0; seen_fall <= 1'b0;
			mdio_o <= 1'b1; mdio_oe <= 1'b0; t_rdata <= 16'h0;
		end else case (tstate)
			T_IDLE: begin
				mdio_oe <= 1'b0; mdio_o <= 1'b1;
				if (t_start) begin
					tbody  <= {2'b01, (t_op ? OP_RD : OP_WR), PHYAD, t_regad,
							   2'b10, (t_op ? 16'h0 : t_wdata)};
					tcnt   <= 6'd31; tstate <= T_PRE;
				end
			end
			//	32-bit preamble of ones (present on falling edges).
			T_PRE: if (mdc_falling) begin
				mdio_oe <= 1'b1; mdio_o <= 1'b1;
				if (tcnt == 0) begin tcnt <= 6'd31; seen_fall <= 1'b0; tstate <= T_BODY; end
				else tcnt <= tcnt - 1'b1;
			end
			//	body: present bit on falling; sample (read) + advance on rising.
			T_BODY: begin
				if (mdc_falling) begin
					if (t_op && tcnt <= 6'd17) mdio_oe <= 1'b0;		//	read: release TA+DATA
					else begin mdio_oe <= 1'b1; mdio_o <= tbody[tcnt[4:0]]; end
					seen_fall <= 1'b1;
				end
				if (mdc_rising && seen_fall) begin
					if (t_op && tcnt <= 6'd15)						//	capture DATA[15..0] only
						t_rdata <= {t_rdata[14:0], mdio_i};
					if (tcnt == 0) tstate <= T_FIN;
					else tcnt <= tcnt - 1'b1;
				end
			end
			//	release after the last bit's sampling edge (hold a write's DATA[0]
			//	through it -- already past), then finish.
			T_FIN: if (mdc_falling) begin
				mdio_oe <= 1'b0; mdio_o <= 1'b1;
				t_done <= 1'b1; tstate <= T_IDLE;
			end
			default: tstate <= T_IDLE;
		endcase
	end

	//	======== sequencer: reset -> soft-reset+poll -> RMW SGMII -> AN -> ID ========
	localparam S_IDLE=0, S_RST_LO=1, S_RST_HI=2, S_POLL_RD=4,
			   S_POLL_CHK=5, S_PHYCR_WR=7, S_CFG2_RD=8, S_CFG2_WR=9,
			   S_AN=10, S_ID_RD=11, S_FIN=12, S_WAIT=13,
			   S_TAXI_MMD=14;				//	(3,6 reserved/folded)
	reg [3:0]  sstate, sret;			//	sret: state to enter after a transaction completes
	reg [15:0] rcnt;					//	reset-hold / wait counter
	reg [6:0]  polls;
	reg [15:0] sreg;					//	captured read data for RMW
`ifdef KARU_ETH_PHY_TAXI_INIT
	//	fpganinja/taxi VCU118 PHY init: after the hardware reset, write three DP83867
	//	extended (MMD, devad 0x1F) registers via REGCR/ADDAR and NOTHING else (no BMCR
	//	soft-reset, no PHYCR/CFG2 RMW, no AN restart). 12 Clause-22 writes total, indexed
	//	by mmd_idx: even index -> REGCR (function/devad), odd -> ADDAR (address then data).
	//	  CFG4(0x0031)<=0x0070  SGMII AN timer
	//	  SGMIICTL1(0x00D3)<=0x4000  SGMII clock output
	//	  10M_SGMII_CFG(0x016F)<=0x0015
	reg [3:0]  mmd_idx;
	function [4:0] mmd_ra(input [3:0] i);   mmd_ra = i[0] ? R_ADDAR : R_REGCR; endfunction
	function [15:0] mmd_wd(input [3:0] i);
		case (i)
			4'd0:  mmd_wd = 16'h001F;	//	REGCR: function=address, devad=0x1F
			4'd1:  mmd_wd = 16'h0031;	//	ADDAR: CFG4 address
			4'd2:  mmd_wd = 16'h401F;	//	REGCR: function=data (no post-incr), devad=0x1F
			4'd3:  mmd_wd = 16'h0070;	//	ADDAR: CFG4 value
			4'd4:  mmd_wd = 16'h001F;
			4'd5:  mmd_wd = 16'h00D3;	//	SGMIICTL1 address
			4'd6:  mmd_wd = 16'h401F;
			4'd7:  mmd_wd = 16'h4000;	//	SGMIICTL1 value (SGMII clock output)
			4'd8:  mmd_wd = 16'h001F;
			4'd9:  mmd_wd = 16'h016F;	//	10M_SGMII_CFG address
			4'd10: mmd_wd = 16'h401F;
			4'd11: mmd_wd = 16'h0015;	//	10M_SGMII_CFG value
			default: mmd_wd = 16'h0000;
		endcase
	endfunction
`endif

	//	helper: kick a transaction and park in S_WAIT until t_done -> sret
	task issue(input op, input [4:0] ra, input [15:0] wd, input [3:0] nxt);
		begin
			t_op <= op; t_regad <= ra; t_wdata <= wd; t_start <= 1'b1;
			sret <= nxt; sstate <= S_WAIT;
		end
	endtask

	always @(posedge clk) begin
		done <= 1'b0; t_start <= 1'b0;
		if (rst) begin
			sstate <= S_IDLE; busy <= 1'b0; error <= 1'b0; phy_reset_n <= 1'b0;
			id_ok <= 1'b0; phy_id <= 16'h0; rcnt <= 0; polls <= 0; sreg <= 0;
			t_op <= 0; t_regad <= 0; t_wdata <= 0; sret <= S_IDLE;
		end else case (sstate)
			S_IDLE: begin
				phy_reset_n <= 1'b1;
				if (start) begin
					busy <= 1'b1; error <= 1'b0; id_ok <= 1'b0;
					phy_reset_n <= 1'b0; rcnt <= RESET_HOLD[15:0]; sstate <= S_RST_LO;
				end
			end
			S_RST_LO: if (rcnt == 0) begin				//	hold RESET_N low
				phy_reset_n <= 1'b1; rcnt <= RESET_WAIT[15:0]; sstate <= S_RST_HI;
			end else rcnt <= rcnt - 1'b1;
			S_RST_HI: if (rcnt == 0) begin				//	wait after deassert
`ifdef KARU_ETH_PHY_TAXI_INIT
				mmd_idx <= 4'd0; sstate <= S_TAXI_MMD;	//	Taxi: straight to the MMD writes
`else
				polls <= 0; issue(1'b0, R_BMCR, 16'h8000, S_POLL_RD);	//	BMCR soft reset
`endif
			end else rcnt <= rcnt - 1'b1;
			S_POLL_RD: issue(1'b1, R_BMCR, 16'h0, S_POLL_CHK);		//	read BMCR
			S_POLL_CHK: begin
				if (!sreg[15]) begin					//	reset bit cleared -> proceed
					issue(1'b1, R_PHYCR, 16'h0, S_PHYCR_WR);
				end else if (polls >= POLL_MAX[6:0]) begin
					error <= 1'b1;						//	timeout: give up the poll, continue
					issue(1'b1, R_PHYCR, 16'h0, S_PHYCR_WR);
				end else begin
					polls <= polls + 1'b1; issue(1'b1, R_BMCR, 16'h0, S_POLL_CHK);
				end
			end
			//	RMW PHYCR: sreg holds the read; write back with SGMII_EN ensured.
			S_PHYCR_WR: issue(1'b0, R_PHYCR, sreg | PHYCR_SGMII_EN, S_CFG2_RD);
			S_CFG2_RD:  issue(1'b1, R_CFG2,  16'h0, S_CFG2_WR);
			//	RMW CFG2: ensure SGMII_AUTONEG_EN (never clear it).
			S_CFG2_WR:  issue(1'b0, R_CFG2,  sreg | CFG2_SGMII_AN, S_AN);
			S_AN:       issue(1'b0, R_BMCR,  16'h1340, S_ID_RD);	//	AN enable + restart
			S_ID_RD:    issue(1'b1, R_PHYIDR1, 16'h0, S_FIN);
`ifdef KARU_ETH_PHY_TAXI_INIT
			//	Taxi MMD init: 12 Clause-22 writes (idx 0..11), then read PHYIDR1 for the
			//	id_ok LED, then finish. Straps + these three extended-register writes are
			//	the entire SGMII setup -- no BMCR/PHYCR/CFG2/AN-restart.
			S_TAXI_MMD: if (mmd_idx >= 4'd12) begin
				issue(1'b1, R_PHYIDR1, 16'h0, S_FIN);
			end else begin
				issue(1'b0, mmd_ra(mmd_idx), mmd_wd(mmd_idx), S_TAXI_MMD);
				mmd_idx <= mmd_idx + 1'b1;
			end
`endif
			S_FIN: begin
				phy_id <= sreg; id_ok <= (sreg == DP83867_ID1);
				busy <= 1'b0; done <= 1'b1; sstate <= S_IDLE;
			end
			//	park here until the transaction engine finishes, then capture rdata.
			S_WAIT: if (t_done) begin sreg <= t_rdata; sstate <= sret; end
			default: sstate <= S_IDLE;
		endcase
	end
endmodule

`default_nettype wire
