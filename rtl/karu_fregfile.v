//  karu_fregfile.v
//  32 x 64-bit floating-point register file: two asynchronous read ports
//  and one write port (1W2R), the same port shape as the integer register
//  file, so a standard two-read compiled register file can implement it.
//  f0 is NOT hard-wired to zero (unlike x0).
//
//  FMA needs three sources. The core reads rs1/rs2 in the decode cycle and
//  then steers port B to rs3 while the FMA occupies the ID/EX packet (see
//  frf_rb_addr in karu64.v): decode cannot accept a new instruction behind a
//  long-latency op, so the port is free at exactly that time. No cycle is
//  added for FMA.
//
//  NaN-boxing of single-precision values is the writer's responsibility:
//  the LSU's FLW path and the FPU's single-precision result path both
//  put `32'hFFFFFFFF` in the upper half. Readers that consume a single
//  check the upper half == all-ones and substitute canonical NaN
//  otherwise (see karu_fpu).

module karu_fregfile (
    input  wire         clk,

    input  wire [4:0]   rs1,
    output wire [63:0]  rs1_v,
    input  wire [4:0]   rs2,
    output wire [63:0]  rs2_v,

    input  wire         we,
    input  wire [4:0]   rd,
    input  wire [63:0]  rd_v
);
    reg [63:0] fx [0:31];

`ifndef KARU_ASIC
    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) fx[i] = 64'b0;
    end
`endif

    always @(posedge clk) begin
        if (we) fx[rd] <= rd_v;     //  f0 has no special semantics
    end

    assign rs1_v = fx[rs1];
    assign rs2_v = fx[rs2];

// synthesis translate_off
    //  Integration contract for a compiled register-file macro: an asserted
    //  write must carry a known address (an X address would corrupt an
    //  arbitrary entry). Read addresses are don't-care when the value is not
    //  consumed, and the time-shared port-B read/write sequencing is a core
    //  property, checked by karu_assert INV38. `we` itself is X only before the
    //  first reset edge, so it is not tested for X.
    always @(posedge clk) begin
        if (we === 1'b1 && (^rd === 1'bx))
            begin $display("[FRF-ASSERT] write with unknown address @%0t", $time); $finish; end
    end
// synthesis translate_on
endmodule
