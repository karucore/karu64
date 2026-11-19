//	karu_sysmon.v
//	=== FPGA die temperature and supply voltages, for the noise measurements.
//
//	The ring oscillators' frequencies and jitter move with temperature and
//	supply voltage, so noise captures need them recorded beside them
//	(doc/zkr-followup-plan.md, Z4). This block runs the UltraScale+ system
//	monitor (SYSMONE4) in its default mode, in which it converts the on-chip
//	sensors continuously by itself, and copies three of its status registers
//	into one 64-bit word every 2^PERIOD_LOG2 clocks (about 14 ms at 75 MHz):
//
//	    [15:0]  temperature  code   T = code * 509.3140064 / 65536 - 280.2308787 deg C
//	    [31:16] VCCINT       code   V = code * 3 / 65536
//	    [47:32] VCCAUX       code   V = code * 3 / 65536
//	    [63:48] updates since reset (wraps); 0 until the first one
//
//	The codes are the monitor's 16-bit status values (UG580, "Temperature
//	Sensor", "Power Supply Sensors"); the temperature formula is the one for
//	the on-chip reference, and the one for an external reference differs by
//	about 0.3 deg C near 40 deg C. Nothing is written to the monitor and no
//	alarm or auxiliary input is used, so the Vivado hardware manager can
//	still read the same monitor over JTAG.
//
//	SIM = 1 has no monitor: fixed codes for 40.0 deg C, 0.850 V and 1.800 V,
//	with the same update counter, for the simulation benches.
//	SPDX-License-Identifier: BSD-2-Clause

module karu_sysmon #(
	parameter integer SIM         = 0,
	parameter integer CLKDIV      = 30,			//	DCLK / ADCCLK: 75 MHz / 30 = 2.5 MHz (at most 5.2 MHz)
	parameter integer PERIOD_LOG2 = 20			//	clocks between updates, log2
) (
	input  wire			clk,					//	also the monitor's DRP clock
	input  wire			rst,
	output reg  [63:0]	value_o
);
	localparam [7:0] A_TEMP = 8'h00, A_VCCINT = 8'h01, A_VCCAUX = 8'h02;

	wire [15:0]	drp_do;
	wire		drp_rdy;
	reg			drp_en;
	reg  [7:0]	drp_addr;

	generate if (SIM == 0) begin : g_mon
		localparam [7:0] DIV = CLKDIV;
		SYSMONE4 #(
			.INIT_40(16'h0000),					//	no averaging change, no external channel
			.INIT_41(16'h0000),					//	sequencer in default mode: the on-chip sensors
			.INIT_42({DIV, 8'h00})				//	ADC clock divider
		) u_sysmon (
			.DCLK(clk), .DEN(drp_en), .DWE(1'b0), .DADDR(drp_addr), .DI(16'h0000),
			.DO(drp_do), .DRDY(drp_rdy),
			.RESET(rst), .CONVST(1'b0), .CONVSTCLK(1'b0),
			.VP(1'b0), .VN(1'b0), .VAUXP(16'h0000), .VAUXN(16'h0000),
			.I2C_SCLK(1'b1), .I2C_SDA(1'b1),
			.ADC_DATA(), .ALM(), .BUSY(), .CHANNEL(), .EOC(), .EOS(), .I2C_SCLK_TS(), .I2C_SDA_TS(),
			.JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED(), .MUXADDR(), .OT(), .SMBALERT_TS()
		);
	end else begin : g_model
		reg [15:0] model_do;
		reg        model_rdy;
		always @(posedge clk) begin
			model_rdy <= drp_en;
			model_do  <= (drp_addr == A_TEMP)   ? 16'ha0f6 :	//	40.0 deg C
						 (drp_addr == A_VCCINT) ? 16'h4888 :	//	0.850 V
						 (drp_addr == A_VCCAUX) ? 16'h999a :	//	1.800 V
						 16'h0000;
		end
		assign drp_do  = model_do;
		assign drp_rdy = model_rdy;
	end endgenerate

	//	Every 2^PERIOD_LOG2 clocks: read the three status registers in turn,
	//	then publish them together, so that a reader never sees a mixture of
	//	two updates.
	reg [PERIOD_LOG2-1:0]	tick;
	reg [1:0]				step;					//	0 idle; 1, 2, 3: waiting for that read
	reg [31:0]				part;
	always @(posedge clk)
		if (rst) begin
			tick <= {PERIOD_LOG2{1'b0}}; step <= 2'd0; drp_en <= 1'b0; drp_addr <= A_TEMP;
			part <= 32'b0; value_o <= 64'b0;
		end else begin
			drp_en <= 1'b0;
			tick   <= tick + 1'b1;
			if (step == 2'd0) begin
				if (&tick) begin
					drp_en <= 1'b1; drp_addr <= A_TEMP; step <= 2'd1;
				end
			end else if (drp_rdy) begin
				case (step)
					2'd1: begin part[15:0]  <= drp_do; drp_en <= 1'b1; drp_addr <= A_VCCINT; step <= 2'd2; end
					2'd2: begin part[31:16] <= drp_do; drp_en <= 1'b1; drp_addr <= A_VCCAUX; step <= 2'd3; end
					default: begin
						value_o <= {value_o[63:48] + 16'd1, drp_do, part};
						step <= 2'd0;
					end
				endcase
			end
		end
endmodule
