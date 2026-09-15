//  karu_ifu.v
//  Instruction fetch unit with an AXI4 master (read-only) port.
//
//  Holds two 64-bit prefetch entries (buf0 covers [buf0_pc, buf0_pc+8);
//  buf1 covers the next quadword). The 32 bits at the current pc are
//  assembled from these, including the cross-boundary case for 32-bit
//  instructions. A compressed instruction in the last halfword needs only
//  buf0; fetching buf1 could fault beyond that instruction's bytes.
//
//  The decoder consumes one instruction per cycle by asserting `take`; the
//  IFU derives the consumed length locally from the assembled instruction.
//
//  `redir` flushes the buffers and restarts fetch at `redir_pc`.
//
//  One in-flight AR at a time. The karu_lsu / IFU pair share the dmem and
//  imem bus respectively, no arbitration needed.

`include "karu_axi_defs.vh"

module karu_ifu (
    input  wire         clk,
    input  wire         rst,

    //  -- redirect from BRU / trap / mret --
    input  wire         redir,
    input  wire [63:0]  redir_pc,

    //  -- to decode --
    output wire         ins_valid,
    output wire [63:0]  ins_pc,
    output wire [31:0]  ins_w,
    input  wire         take,
    input  wire         fetch_safe,    // no older instruction can fault/redirect

    //  -- virtual-to-physical translation for fetches --
    output reg          xlate_req,
    output reg [63:0]   xlate_va,
    input  wire         xlate_busy,     //  translator not in S_IDLE: a req now would be dropped
    input  wire         xlate_done,
    input  wire         xlate_fault,
    input  wire [63:0]  xlate_fault_va,
    input  wire [63:0]  xlate_fault_cause,
    input  wire         xlate_fault_gva,
    input  wire         xlate_fault_gpa_valid,
    input  wire [63:0]  xlate_fault_gpa,
    input  wire [63:0]  xlate_fault_tinst,
    input  wire         xlate_fault_gpa_is_pte,
    input  wire [63:0]  xlate_pa,
    input  wire [1:0]   xlate_pbmt,
    output reg          fault_valid,
    output reg [63:0]   fault_va,
    output reg [63:0]   fault_cause,
    output reg          fault_gva,
    output reg          fault_gpa_valid,
    output reg [63:0]   fault_gpa,
    output reg [63:0]   fault_tinst,
    output reg          fault_gpa_is_pte,

    //  -- AXI4 master (read-only) --
    output reg [1:0]                ar_pbmt,
    output reg [`AXI_ID_W-1:0]      arid,
    output reg [`AXI_ADDR_W-1:0]    araddr,
    output reg [`AXI_LEN_W-1:0]     arlen,
    output reg [`AXI_SIZE_W-1:0]    arsize,
    output reg [`AXI_BURST_W-1:0]   arburst,
    output reg [`AXI_PROT_W-1:0]    arprot,
    output reg                      arvalid,
    input  wire                     arready,
    input  wire [`AXI_ID_W-1:0]     rid,
    input  wire [`AXI_DATA_W-1:0]   rdata,
    input  wire [`AXI_RESP_W-1:0]   rresp,
    input  wire                     rlast,
    input  wire                     rvalid,
    output reg                      rready
);
    parameter [63:0] RESET_PC = 64'h0000_0000_8000_0000;

    reg [63:0]  pc;             //  next instruction byte address

    reg [63:0]  buf0_d, buf1_d;
    reg [63:0]  buf0_a, buf1_a;
    reg         buf0_v, buf1_v;

    reg         ar_pending;     //  AR has been issued, awaiting R
    reg [63:0]  ar_addr;        //  address of in-flight fetch
    reg [63:0]  ar_pa;          //  physical address of in-flight fetch
    reg [2:0]   fault_offset;   //  first instruction byte in this fetch quad
    reg         xlate_pending;
    reg         io_wait;       // translated IO demand waits for older execution
    reg         r_discard;      //  the next R is stale (post-redirect drain)
    reg         xlate_discard;  //  an in-flight sv39 walk predates a redirect; drop its result

    wire [3:0]  rel_pc = pc[3:0] - buf0_a[3:0]; //  0..15 byte offset within buf0

    //  Assemble the 32 instruction bits at pc.
    //  (rel_pc <= 4): all 32 bits in buf0
    //  (rel_pc == 6 && buf1_v): low 16 from buf0, high 16 from buf1
    wire same_q = buf0_v && (pc[63:3] == buf0_a[63:3]);
    wire next_q = buf1_v && (pc[63:3] == buf1_a[63:3]);
    wire tail_is_c = (buf0_d[49:48] != 2'b11);
    wire xline  = buf0_v && buf1_v && pc[2:0] == 3'b110 &&
                  buf1_a == (buf0_a + 64'd8);

    //  32-bit window into buf0/buf1 at pc[2:1]
    reg [31:0] in_buf0, in_buf1;
    always @(*) begin
        case (pc[2:1])
            2'b00: in_buf0 = buf0_d[31:0];
            2'b01: in_buf0 = buf0_d[47:16];
            2'b10: in_buf0 = buf0_d[63:32];
            default: in_buf0 = {16'b0, buf0_d[63:48]}; // compressed tail
        endcase
        case (pc[2:1])
            2'b00: in_buf1 = buf1_d[31:0];
            2'b01: in_buf1 = buf1_d[47:16];
            2'b10: in_buf1 = buf1_d[63:32];
            default: in_buf1 = {16'b0, buf1_d[63:48]};
        endcase
    end
    //  Cross boundary: low 16 from buf0[63:48], high 16 from buf1[15:0]
    wire [31:0] in_xline = {buf1_d[15:0], buf0_d[63:48]};

    assign ins_pc = pc;
    assign ins_w  = xline  ? in_xline :
                    same_q ? in_buf0 :
                    next_q ? in_buf1 :
                             32'h0000_0013; //  nop placeholder (ignored)
    assign ins_valid = xline
                    || (same_q && (pc[2:0] != 3'b110 || tail_is_c))
                    || (next_q && (pc[2:0] != 3'b110 || buf1_d[49:48] != 2'b11));

    //  -- pick next fetch address --
    //  Maintain invariant: if buf0_v, buf0 is "current" (contains pc).
    //  If pc moves out of buf0 (rel_pc >= 8), shift buf1 -> buf0.
    //  Then fetch into buf1 the next quadword.
    wire need_buf1 = same_q && !buf1_v && pc[2:0] == 3'b110 && !tail_is_c;
    wire need_buf0 = !buf0_v;

    wire [63:0] next_ar_addr =
        need_buf0 ? { pc[63:3], 3'b000 } :
        need_buf1 ? buf0_a + 64'd8     :
                    ar_addr;

    //  Consumed length is derived locally from the assembled instruction
    //  (compressed iff low 2 bits != 2'b11) -- no need to round-trip is_c out
    //  through karu64 and back as c_flag, which spread this cone across the die.
    wire consume_is_c = (ins_w[1:0] != 2'b11);

    //  Narrow PC advance: the consume step is +2/+4, so only pc[2:0] plus a
    //  single carry into pc[63:3] change. Precompute the high +1 path and mux
    //  it with pc_cross so the compressed-length decision does not drive a
    //  61-bit carry chain.
    wire [3:0]  pc_lo_inc = {1'b0, pc[2:0]} + (consume_is_c ? 4'd2 : 4'd4);
    wire        pc_cross  = pc_lo_inc[3];   //  1 = consume crosses the 8-byte quad
    wire [60:0] pc_hi_inc = pc[63:3] + 61'd1;
    wire [63:0] next_pc   = {pc_cross ? pc_hi_inc : pc[63:3], pc_lo_inc[2:0]};
    //  post_out_of_buf0 is only consulted under buf0_v, where the module
    //  invariant pc[63:3]==buf0_a[63:3] holds, so "left buf0's quad" == the
    //  low-bit carry -- no 64-bit post_pc / 61-bit compare needed.
    wire post_out_of_buf0 = pc_cross;

    always @(posedge clk) begin
        if (rst) begin
            pc         <= RESET_PC;
            buf0_v     <= 0;
            buf1_v     <= 0;
            ar_pending <= 0;
            xlate_pending <= 0;
            io_wait <= 0;
            ar_pbmt <= 0;
            xlate_req  <= 0;
            arvalid    <= 0;
            rready     <= 0;
            r_discard  <= 0;
            xlate_discard <= 0;
            fault_valid <= 0;
            fault_gva <= 0;
            fault_gpa_valid <= 0;
            fault_gpa <= 0;
            fault_tinst <= 0;
            fault_gpa_is_pte <= 0;
        end else begin
            xlate_req <= 1'b0;

            //  -- redirect: flush buffers, restart fetch --
            //  An AR that was in flight before the redirect will still
            //  produce an R; we must keep rready high to drain it but
            //  flag it as stale so we don't store it into the new buf0.
            if (redir) begin
                pc         <= redir_pc;
                buf0_v     <= 0;
                buf1_v     <= 0;
                //  A sv39 walk already in flight cannot be cancelled (karu_sv39
                //  only accepts a new req in S_IDLE). Clearing xlate_pending here
                //  and reissuing would silently drop the new request while the
                //  translator is busy, and the old walk's completion would then
                //  be misattributed to the redirected PC. Keep xlate_pending and
                //  drop that completion instead.
                if (xlate_pending && !xlate_done) begin
                    xlate_discard <= 1'b1;
                end else begin
                    xlate_pending <= 1'b0;
                    xlate_discard <= 1'b0;
                end
                //  Do not drop a still-pending AR: AXI requires VALID and its
                //  payload to stay stable until ARREADY. The stale read drains via
                //  r_discard below.
                if (!(arvalid && !arready))
                    arvalid <= 0;
                fault_valid <= 0;
                fault_gva <= 0;
                fault_gpa_valid <= 0;
                fault_gpa <= 0;
                fault_tinst <= 0;
                fault_gpa_is_pte <= 0;
                io_wait <= 0;
                if (ar_pending && !(rvalid && rready)) begin
                    //  stale R hasn't arrived yet -- drain when it does
                    r_discard <= 1'b1;
                    rready    <= 1'b1;
                end else begin
                    //  either no AR in flight or R just arrived: reset cleanly
                    ar_pending <= 0;
                    rready     <= 0;
                    r_discard  <= 0;
                end
            end else begin

                //  -- consume --
                if (take) begin
                    pc <= next_pc;
                end

                //  -- shift buffer when pc has moved past buf0 --
                //  If buf1_v was set: normal shift (buf1 -> buf0).
                //  If buf1_v was empty AND an R is arriving this cycle:
                //    let the R-acceptance below put the new data into buf0
                //    directly (handled there). Just clear buf0_v as a
                //    default; the R-acceptance overrides.
                if (take && buf0_v && post_out_of_buf0) begin
                    if (buf1_v) begin
                        buf0_d <= buf1_d;
                        buf0_a <= buf1_a;
                        buf0_v <= 1'b1;
                        buf1_v <= 1'b0;
                    end else begin
                        buf0_v <= 1'b0;
                    end
                end

                //  -- issue AR (only when no R is outstanding) --
                //  !xlate_busy is the req/accept handshake: karu_sv39 only
                //  samples req in S_IDLE, so never present a request (and never
                //  mark it pending) while a walk is active.
                if (!ar_pending && !io_wait && !xlate_pending && !xlate_discard && !r_discard
                    && !xlate_busy && !fault_valid && (need_buf0 || need_buf1)) begin
                    xlate_va <= next_ar_addr;
                    xlate_req <= 1'b1;
                    ar_addr <= next_ar_addr;
                    //  First fetch faults identify pc, not its aligned quad.
                    //  The second fetch of a straddled instruction identifies
                    //  its upper halfword, which starts at the next quad.
                    fault_offset <= need_buf0 ? pc[2:0] : 3'b000;
                    xlate_pending <= 1'b1;
                end
                if (xlate_pending && xlate_done) begin
                    xlate_pending <= 1'b0;
                    if (xlate_discard) begin
                        xlate_discard <= 1'b0;
                    end else if (xlate_fault) begin
                        fault_valid <= 1'b1;
                        fault_va <= {xlate_fault_va[63:3], fault_offset};
                        fault_cause <= xlate_fault_cause;
                        fault_gva <= xlate_fault_gva;
                        fault_gpa_valid <= xlate_fault_gpa_valid;
                        // H guest-page faults report the same instruction byte
                        // in VA and GPA. An implicit VS-PTE read instead reports
                        // that PTE's GPA, with its supplied pseudoinstruction;
                        // the instruction's halfword offset must not alter it.
                        // Keep the full GPA here; trap CSR entry applies >> 2.
                        fault_gpa <= !xlate_fault_gpa_valid ? 64'b0 :
                            xlate_fault_gpa_is_pte ? xlate_fault_gpa :
                            {xlate_fault_gpa[63:3], fault_offset};
                        fault_tinst <= xlate_fault_tinst;
                        fault_gpa_is_pte <= xlate_fault_gpa_valid &&
                                            xlate_fault_gpa_is_pte;
                    end else begin
                        ar_pa <= xlate_pa;
                        ar_pbmt <= xlate_pbmt;
                        arid    <= 0;
                        araddr  <= xlate_pa[`AXI_ADDR_W-1:0];
                        arlen   <= 0;
                        arsize  <= `AXI_SIZE_8B;
                        arburst <= `AXI_BURST_INCR;
                        arprot  <= 0;
                        // IO fetches are non-speculative. A naturally aligned
                        // 8-byte implicit-read region is permitted; bypass the
                        // I-cache and wait until older execution is irrevocable.
                        if (xlate_pbmt != 2'b10 || fetch_safe) begin
                            arvalid <= 1;
                            rready  <= 1;
                            ar_pending <= 1;
                        end else io_wait <= 1;
                    end
                end
                if (io_wait && fetch_safe) begin
                    io_wait <= 0;
                    arvalid <= 1;
                    rready <= 1;
                    ar_pending <= 1;
                end
                if (arvalid && arready) begin
                    arvalid <= 0;
                end

                //  -- accept R (discard if flagged stale) --
                //  Routing accounts for an in-progress shift this cycle:
                //  if the shift fired with buf1 empty, buf0 is "really"
                //  about to be empty -- route the new R into buf0 to
                //  avoid leaving buf0 empty and the data stranded in
                //  buf1 (which would then duplicate addresses on the
                //  next AR).
                if (rvalid && rready) begin
                    if (r_discard) begin
                        r_discard <= 1'b0;
                    end else if (rresp[1]) begin
                        fault_valid <= 1;
                        fault_va <= {ar_addr[63:3], fault_offset};
                        fault_cause <= 64'd1;
                        // A physical bus error is not a guest-page fault and
                        // must not reuse metadata from a translation response.
                        fault_gva <= 0;
                        fault_gpa_valid <= 0;
                        fault_gpa <= 0;
                        fault_tinst <= 0;
                        fault_gpa_is_pte <= 0;
                    end else begin
                        //  Re-derive the post-shift emptiness of buf0
                        if ((take && buf0_v && post_out_of_buf0 && !buf1_v)
                            || !buf0_v) begin
                            buf0_d <= rdata;
                            buf0_a <= ar_addr;
                            buf0_v <= 1'b1;
                        end else if (!buf1_v) begin
                            buf1_d <= rdata;
                            buf1_a <= ar_addr;
                            buf1_v <= 1'b1;
                        end
                    end
                    rready     <= 1'b0;
                    ar_pending <= 1'b0;
                end
            end
        end
    end

    //  silence unused
    wire _unused = &{rid, rlast, xlate_fault_va[2:0], 1'b0};
endmodule
