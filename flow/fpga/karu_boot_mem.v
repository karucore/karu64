// karu_boot_mem.v -- low-address boot ROM plus scratch SRAM.
//
//   ROM_BASE  .. ROM_BASE+ROM_BYTES    read-only boot ROM (1 MiB default): fu-boot
//                                       plus the baked OpenSBI / U-Boot / control-DTB
//                                       payload images (fu-boot auto-copies them to DDR).
//   SRAM_BASE .. SRAM_BASE+SRAM_BYTES   boot scratch SRAM (64 KiB): fu-boot stack/data/bss.
//
// The ROM grew from 60 KiB to 1 MiB so the whole boot chain (OpenSBI + U-Boot + DTB)
// ships inside the bitstream -- no JTAG/host stage to bring up the board. The scratch
// SRAM used to sit at 0x0001_0000, which is now inside the 1 MiB ROM, so it moved up to
// 0x0010_1000 (directly above the ROM). Index widths are derived from the sizes.
//
// BRAM-mapping discipline (load-bearing at 1 MiB): each memory drives its OWN
// unconditionally-registered read output -- the canonical block-RAM template -- and the
// imem/dmem datum is a *post-register* select. Folding both memories into one muxed
// output reg (an `if (is_rom) rdata<=rom[..] else if (is_sram) rdata<=sram[..] else 0`
// style) makes Vivado declare ram_style="block" "infeasible" and fall back to distributed
// RAM. That silently fit when the ROM was 60 KiB but is catastrophic at 1 MiB (it would
// need ~580k LUTRAM + a 131072-deep address mux). The ROM is read-only with two read
// ports, so it maps to a true-dual-port block RAM; the SRAM is 2R/1W (3 ports), so it
// stays distributed RAM -- fine at 64 KiB.

module karu_boot_mem #(
	parameter		 ROM_HEX    = "vcu118_fuboot.hex",
	parameter [31:0] ROM_BASE   = 32'h0000_1000,
	parameter [31:0] ROM_BYTES  = 32'h0010_0000,	// 1 MiB
	parameter [31:0] SRAM_BASE  = 32'h0010_1000,	// directly above the ROM
	parameter [31:0] SRAM_BYTES = 32'h0001_0000		// 64 KiB
) (
	input  wire			clk,
	input  wire [31:0]	imem_raddr,
	output reg  [63:0]	imem_rdata,
	input  wire [31:0]	dmem_raddr,
	output reg  [63:0]	dmem_rdata,
	input  wire			dmem_we,
	input  wire [31:0]	dmem_waddr,
	input  wire [7:0]	dmem_wstrb,
	input  wire [63:0]	dmem_wdata
);
	localparam ROM_WORDS  = ROM_BYTES / 8;
	localparam SRAM_WORDS = SRAM_BYTES / 8;
	localparam RIW = $clog2(ROM_WORDS);		// ROM index width
	localparam SIW = $clog2(SRAM_WORDS);	// SRAM index width

	(* ram_style = "block" *) reg [63:0] rom [0:ROM_WORDS-1];	// read-only, 2R -> BRAM
	reg [63:0] sram [0:SRAM_WORDS-1];							// 2R/1W -> distributed RAM

	initial $readmemh(ROM_HEX, rom);

	function is_rom(input [31:0] a);
		is_rom = (a >= ROM_BASE) && (a < ROM_BASE + ROM_BYTES);
	endfunction

	function is_sram(input [31:0] a);
		is_sram = (a >= SRAM_BASE) && (a < SRAM_BASE + SRAM_BYTES);
	endfunction

	wire [RIW-1:0] imem_rom_idx  = (imem_raddr - ROM_BASE) >> 3;
	wire [SIW-1:0] imem_sram_idx = (imem_raddr - SRAM_BASE) >> 3;
	wire [RIW-1:0] dmem_rom_idx  = (dmem_raddr - ROM_BASE) >> 3;
	wire [SIW-1:0] dmem_sram_idx = (dmem_raddr - SRAM_BASE) >> 3;
	wire [SIW-1:0] dmem_widx     = (dmem_waddr - SRAM_BASE) >> 3;

	//	One dedicated, unconditional registered read per memory per port.
	reg [63:0] rom_iq, rom_dq, sram_iq, sram_dq;
	reg        sel_irom, sel_isram, sel_drom, sel_dsram;

	always @(posedge clk) begin
		rom_iq    <= rom[imem_rom_idx];
		rom_dq    <= rom[dmem_rom_idx];
		sram_iq   <= sram[imem_sram_idx];
		sram_dq   <= sram[dmem_sram_idx];
		sel_irom  <= is_rom(imem_raddr);
		sel_isram <= is_sram(imem_raddr);
		sel_drom  <= is_rom(dmem_raddr);
		sel_dsram <= is_sram(dmem_raddr);

		if (dmem_we && is_sram(dmem_waddr)) begin
			if (dmem_wstrb[0]) sram[dmem_widx][7:0]   <= dmem_wdata[7:0];
			if (dmem_wstrb[1]) sram[dmem_widx][15:8]  <= dmem_wdata[15:8];
			if (dmem_wstrb[2]) sram[dmem_widx][23:16] <= dmem_wdata[23:16];
			if (dmem_wstrb[3]) sram[dmem_widx][31:24] <= dmem_wdata[31:24];
			if (dmem_wstrb[4]) sram[dmem_widx][39:32] <= dmem_wdata[39:32];
			if (dmem_wstrb[5]) sram[dmem_widx][47:40] <= dmem_wdata[47:40];
			if (dmem_wstrb[6]) sram[dmem_widx][55:48] <= dmem_wdata[55:48];
			if (dmem_wstrb[7]) sram[dmem_widx][63:56] <= dmem_wdata[63:56];
		end
	end

	//	Post-register select (1-cycle read latency, unchanged): the BRAM/LUTRAM output
	//	registers are clean, the region mux is downstream.
	always @(*) imem_rdata = sel_irom ? rom_iq : (sel_isram ? sram_iq : 64'b0);
	always @(*) dmem_rdata = sel_drom ? rom_dq : (sel_dsram ? sram_dq : 64'b0);
endmodule
