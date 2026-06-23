//  karu_clint.v
//  === Minimal RISC-V CLINT (core-local interruptor) for one hart.
//
//  SiFive/QEMU-compatible register layout at base 0x0200_0000:
//    0x0000   msip      (1 bit used) machine software interrupt pending
//    0x4000   mtimecmp  (64-bit)     hart 0 timer compare
//    0xBFF8   mtime     (64-bit)     free-running monotonic counter
//
//  `mtime` is NOT clocked off the raw core clock: it advances by one every
//  TICK_DIV core cycles, so it is a *wall-clock-stable* tick whose rate is
//  independent of the (config-/board-dependent) core frequency. The DTB
//  `timebase-frequency` must be set to CPU_CLK_HZ / TICK_DIV.
//
//  Outputs:
//    mtip = (mtime >= mtimecmp)   -> core irq (MTIP, mcause 7)
//    msip = msip_reg[0]           -> machine software interrupt (no core
//                                    input wired today; exposed for SW that
//                                    reads/writes the register and for a
//                                    future MSIP core port).
//
//  Bus contract matches karu_plic: 8-byte-aligned MMIO access (karu64's LSU
//  forces awaddr/araddr[2:0]=0 and carries the byte position in wstrb), reads
//  are combinational on the latched address, writes are byte-granular.

`include "karu_ext.vh"

module karu_clint #(
    //  core clock in Hz (100 MHz default; DDR top overrides via MIG/div, e.g. 75 MHz
    //  at DIV=4). mtime tick = one increment per TICK_DIV = CPU_CLK_HZ/1e6 (~1 MHz).
    parameter   CPU_CLK_HZ = 100000000
) (
    input  wire         clk,
    input  wire         rst,

    input  wire [31:0]  raddr,
    output wire [63:0]  rdata,

    input  wire         we,
    input  wire [31:0]  waddr,
    input  wire [7:0]   wstrb,
    input  wire [63:0]  wdata,

    output wire         mtip,       //  machine timer interrupt pending
    output wire         msip,       //  machine software interrupt pending
    //  mtime exposed so the core's CSR `time` (rdtime, 0xC01) reads the SAME counter
    //  as mtimecmp -- required by the RISC-V spec + Linux (which programs timer
    //  deadlines as rdtime+delta). Without this the CSR time domain (raw cyc) and the
    //  CLINT mtime domain (TICK_DIV'd) diverge and timer interrupts never fire.
    output wire [63:0]  mtime_o
);
    //  mtime tick divider: one increment every TICK_DIV core clocks (~1 MHz)
    localparam  TICK_DIV = (CPU_CLK_HZ / 1000000);
    localparam [31:0] CLINT_BASE = 32'h0200_0000;
    localparam [15:0] OFF_MSIP     = 16'h0000;
    localparam [15:0] OFF_MTIMECMP = 16'h4000;
    localparam [15:0] OFF_MTIME    = 16'hBFF8;

    reg  [31:0] msip_r;
    reg  [63:0] mtimecmp;
    reg  [63:0] mtime;

    //  tick divider: pulse `tick` once per TICK_DIV cycles.
    localparam  DIVW = (TICK_DIV <= 1) ? 1 : $clog2(TICK_DIV);
    reg  [DIVW-1:0] div_cnt;
    wire        tick = (div_cnt == (TICK_DIV - 1));

    assign mtip = (mtime >= mtimecmp);
    assign msip = msip_r[0];
    assign mtime_o = mtime;

    //  -------- reads (8-byte aligned) --------
    wire [15:0] roff = raddr[15:0] - CLINT_BASE[15:0];
    assign rdata =
        (roff == OFF_MSIP)     ? {32'b0, msip_r} :
        (roff == OFF_MTIMECMP) ? mtimecmp        :
        (roff == OFF_MTIME)    ? mtime           :
        64'b0;

    //  -------- writes (byte-granular within the addressed 8-byte word) ------
    wire [15:0] woff = waddr[15:0] - CLINT_BASE[15:0];
    integer b;

    always @(posedge clk) begin
        if (rst) begin
            msip_r   <= 32'b0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;    //  mtip starts deasserted
            mtime    <= 64'b0;
            div_cnt  <= {DIVW{1'b0}};
        end else begin
            //  wall-clock tick
            if (tick)
                div_cnt <= {DIVW{1'b0}};
            else
                div_cnt <= div_cnt + 1'b1;

            //  mtime advances on tick unless software writes it this cycle
            if (we && (woff == OFF_MTIME)) begin
                for (b = 0; b < 8; b = b + 1)
                    if (wstrb[b]) mtime[b*8 +: 8] <= wdata[b*8 +: 8];
            end else if (tick) begin
                mtime <= mtime + 1'b1;
            end

            if (we && (woff == OFF_MTIMECMP)) begin
                for (b = 0; b < 8; b = b + 1)
                    if (wstrb[b]) mtimecmp[b*8 +: 8] <= wdata[b*8 +: 8];
            end

            if (we && (woff == OFF_MSIP)) begin
                for (b = 0; b < 4; b = b + 1)
                    if (wstrb[b]) msip_r[b*8 +: 8] <= wdata[b*8 +: 8];
            end
        end
    end
endmodule
