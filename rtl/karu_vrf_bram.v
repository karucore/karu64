//  karu_vrf_bram.v
//  Dual-port BRAM-backed vector register file (the macro-VRF -- the only
//  VRF since the 2026-06-12 collapse).
//  See doc/architecture.md for the architecture + access schedule.
//
//  32 x VLEN-bit registers stored as 32*VGRAN entries of VBUS_W bits in ONE
//  true-dual-port BRAM: registered reads (1-cycle latency), per-byte write
//  enables (so undisturbed tail/mask = "don't write those bytes"), NO_CHANGE
//  read behaviour (a port that writes does not update its read latch). v0
//  (the mask register) is additionally mirrored in a flip-flop shadow so the
//  per-element mask can be read combinationally with no BRAM latency.
//
//  Requires VGRAN = VLEN/VBUS_W >= 2 (i.e. VLEN > VBUS_W) -- the whole point
//  of this module (a VLEN==VBUS_W build would need a single-granule variant).
//
//  NOT reset: the BRAM array itself (power-up = 0 via INIT, as on real HW).
//  rst clears only the v0 flop shadow and the read latches.

`include "karu_vcfg.vh"

module karu_vrf_bram #(
    parameter integer VLEN   = `KARU_VLEN,
    parameter integer VBUS_W = `KARU_VBUS_W
) (
    input  wire                 clk,
    input  wire                 rst,

    //  ---- Port A (read-mostly; may also write a granule) ----
    //  (widths use inline exprs so they are visible in the port list; the
    //  body re-declares them as localparams AW/NBYTES.)
    input  wire                 a_en,
    input  wire                 a_we,
    input  wire [$clog2(32*(VLEN/VBUS_W))-1:0]  a_addr,
    input  wire [(VBUS_W/8)-1:0]                a_be,
    input  wire [VBUS_W-1:0]    a_wdata,
    output reg  [VBUS_W-1:0]    a_rdata,

    //  ---- Port B (primary writeback port) ----
    input  wire                 b_en,
    input  wire                 b_we,
    input  wire [$clog2(32*(VLEN/VBUS_W))-1:0]  b_addr,
    input  wire [(VBUS_W/8)-1:0]                b_be,
    input  wire [VBUS_W-1:0]    b_wdata,
    output reg  [VBUS_W-1:0]    b_rdata,

    //  ---- v0 mask shadow (combinational; flop-backed) ----
    output wire [VLEN-1:0]      v0
);
    //  ---- derived geometry ----
    localparam integer NBYTES = VBUS_W / 8;         //  byte lanes / write enables
    localparam integer VGRAN  = VLEN / VBUS_W;      //  granules (= entries) per v-reg
    localparam integer NENT   = 32 * VGRAN;         //  BRAM depth
    localparam integer AW     = $clog2(NENT);       //  address width = {vreg[4:0], gran}
    localparam integer GB     = $clog2(VGRAN);      //  granule-index bits (>=1, VGRAN>=2)

    //  Elaboration guard: this module requires VGRAN>=2 (i.e. VLEN>VBUS_W). An
    //  unsupported VLEN==VBUS_W build would make GB=0 and the addr[GB-1:0]
    //  granule slices illegal -- instantiate an undefined module so elaboration
    //  fails loudly (the name is the message) instead of mis-synthesising.
    generate
        if (VGRAN < 2) begin : g_guard
            ERROR_karu_vrf_bram_requires_VLEN_greater_than_VBUS_W bad_config();
        end
    endgenerate

    //  ---- the BRAM array (force block RAM; small for VLEN=256, but the
    //  whole point is to evacuate the flop array out of the CLB fabric) ----
    (* ram_style = "block" *)
    reg [VBUS_W-1:0] mem [0:NENT-1];

    integer m;
    initial begin
        for (m = 0; m < NENT; m = m + 1) mem[m] = {VBUS_W{1'b0}};
        a_rdata = {VBUS_W{1'b0}};
        b_rdata = {VBUS_W{1'b0}};
    end

    //  ---- Port A: byte-write + NO_CHANGE registered read ----
    integer ba;
    always @(posedge clk) begin
        if (a_en) begin
            if (a_we) begin
                for (ba = 0; ba < NBYTES; ba = ba + 1)
                    if (a_be[ba]) mem[a_addr][ba*8 +: 8] <= a_wdata[ba*8 +: 8];
            end else begin
                a_rdata <= mem[a_addr];
            end
        end
    end

    //  ---- Port B: byte-write + NO_CHANGE registered read ----
    integer bb;
    always @(posedge clk) begin
        if (b_en) begin
            if (b_we) begin
                for (bb = 0; bb < NBYTES; bb = bb + 1)
                    if (b_be[bb]) mem[b_addr][bb*8 +: 8] <= b_wdata[bb*8 +: 8];
            end else begin
                b_rdata <= mem[b_addr];
            end
        end
    end

    //  ---- v0 (mask) flip-flop shadow ----
    //  Mirror any write that targets register 0 (reg = addr[AW-1:GB], granule
    //  = addr[GB-1:0]); byte b of granule g maps to v0 bits [g*VBUS_W + b*8].
    //  Reads of v0 as a normal operand still go through the BRAM; this shadow
    //  exists only for the combinational per-element mask read.
    //
    //  NB: v0_q is deliberately NOT reset. The BRAM is not reset either (it
    //  powers up to 0 via INIT at configuration and RETAINS contents across a
    //  soft `rst`). Resetting only v0_q would break the invariant
    //  v0_shadow == BRAM[reg0] after a soft reset (mask reads -> 0 while normal
    //  operand reads of v0 return the retained BRAM data). So both start at
    //  `initial` 0 and only ever change on a write -> always coherent.
    reg  [VLEN-1:0] v0_q;
    initial         v0_q = {VLEN{1'b0}};
    wire            a_is0 = (a_addr[AW-1:GB] == 5'd0);
    wire            b_is0 = (b_addr[AW-1:GB] == 5'd0);
    wire [GB-1:0]   a_g   = a_addr[GB-1:0];
    wire [GB-1:0]   b_g   = b_addr[GB-1:0];
    integer         va, vb;
    always @(posedge clk) begin
        if (a_en && a_we && a_is0)
            for (va = 0; va < NBYTES; va = va + 1)
                if (a_be[va]) v0_q[a_g*VBUS_W + va*8 +: 8] <= a_wdata[va*8 +: 8];
        if (b_en && b_we && b_is0)
            for (vb = 0; vb < NBYTES; vb = vb + 1)
                if (b_be[vb]) v0_q[b_g*VBUS_W + vb*8 +: 8] <= b_wdata[vb*8 +: 8];
    end
    assign v0 = v0_q;

    //  (`rst` is intentionally unused: the BRAM array and the v0 shadow both
    //  retain across a soft reset -- re-initialisation happens only at FPGA
    //  configuration. The read latches a_rdata/b_rdata hold stale data only
    //  until the next read, which the consumer awaits; `initial` zeroes all
    //  sim state. Keeping reset off these also avoids a second driver and does
    //  not defeat block-RAM output-register inference. `rst` is kept in the
    //  port list for interface uniformity with the flop VRF + the checker.)
endmodule
