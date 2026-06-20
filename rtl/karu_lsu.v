//  karu_lsu.v
//  Load/store unit with an AXI4 master port. Single in-flight
//  transaction for Phase 2 (no pipelining). Misaligned accesses that
//  cross an 8-byte beat are split into two aligned 64-bit transactions.

`include "config.vh"
`include "karu_axi_defs.vh"
`include "karu_uop_defs.vh"

module karu_lsu (
    input  wire         clk,
    input  wire         rst,

    //  --- request port ---
    input  wire         req,            //  pulse to start
    output wire         busy,           //  can't accept a new req
    input  wire         is_store,       //  1 for plain integer/FP store
    input  wire [4:0]   sub_in,         //  the LSU sub-op (lets us decode LR/SC/AMO)
    input  wire [63:0]  addr,
    input  wire [63:0]  addr2,          //  beat-2 base PA for a misaligned 8-byte-
                                    //  crossing access (the core translates the
                                    //  second page separately; within one page it
                                    //  is just (addr & ~7) + 8)
    input  wire [63:0]  wdata,          //  rs2 (already in low bits of size)
    input  wire [1:0]   size,           //  LS_B / LS_H / LS_W / LS_D
    input  wire         sign_l,         //  1=lh/lw/...; 0=lhu/lwu/...

    //  --- completion ---
    output reg          done,
    output reg [63:0]   rd_v,           //  load / amo result (sc returns 0/1)

    //  --- AXI4 master ---
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
    output reg                      rready,

    output reg [`AXI_ID_W-1:0]      awid,
    output reg [`AXI_ADDR_W-1:0]    awaddr,
    output reg [`AXI_LEN_W-1:0]     awlen,
    output reg [`AXI_SIZE_W-1:0]    awsize,
    output reg [`AXI_BURST_W-1:0]   awburst,
    output reg [`AXI_PROT_W-1:0]    awprot,
    output reg                      awvalid,
    input  wire                     awready,
    output reg [`AXI_DATA_W-1:0]    wdata_o,
    output reg [`AXI_STRB_W-1:0]    wstrb,
    output reg                      wlast,
    output reg                      wvalid,
    input  wire                     wready,
    input  wire [`AXI_ID_W-1:0]     bid,
    input  wire [`AXI_RESP_W-1:0]   bresp,
    input  wire                     bvalid,
    output reg                      bready
);
    localparam S_IDLE   = 4'd0;
    localparam S_AR     = 4'd1;
    localparam S_R      = 4'd2;
    localparam S_AR2    = 4'd3;
    localparam S_R2     = 4'd4;
    localparam S_AWW    = 4'd5;
    localparam S_B      = 4'd6;
    localparam S_AWW2   = 4'd7;
    localparam S_B2     = 4'd8;
    localparam S_AMO_W  = 4'd9;     //  AMO write phase (after the read)
    localparam S_AMO_B  = 4'd10;    //  AMO write-resp wait
    localparam S_CBOZ_W = 4'd11;    //  cbo.zero: one 8-byte zero-beat AW+W
    localparam S_CBOZ_B = 4'd12;    //  cbo.zero: that beat's write-resp wait

    reg [3:0]   state;
    reg [3:0]   cbo_cnt;            //  cbo.zero beat counter (0..7 = 8x8B = 64B)

    //  Latched request fields
    reg [63:0]  addr_q;
    reg [63:0]  addr2_q;            //  latched beat-2 base PA (see addr2 port)
    reg [63:0]  wdata_q;
    reg [1:0]   size_q;
    reg         sign_q;
    reg         cross_q;
    reg [63:0]  rd_lo_q;
    reg [4:0]   sub_q;          //  the originating LSU sub-op (for AMO routing)
    reg [63:0]  amo_loaded;     //  stashed memory value for the AMO ALU op

    //  ---- LR/SC reservation tracking ----
    //  Single-core: any normal store, any AMO store, or any SC clears
    //  the reservation. LR establishes it.
    reg         reserve_valid;
    reg [63:0]  reserve_addr;

    //  ---- Sub-op decoding ----
    wire is_lr_in  = (sub_in == `LSU_LR);
    wire is_sc_in  = (sub_in == `LSU_SC);
    wire is_amo_in = (sub_in >= `LSU_AMOSWAP) && (sub_in <= `LSU_AMOMAXU);
    wire is_cboz_in = (sub_in == `LSU_CBOZERO);
    //  cbo.clean/flush/inval: the address was already translated (fault would
    //  have trapped before req); on a write-through L1 there is nothing to do,
    //  so they retire with no AXI transaction.
    wire is_cbonop_in = (sub_in == `LSU_CBOCF) || (sub_in == `LSU_CBOINVAL);
    wire is_lr_q   = (sub_q == `LSU_LR);
    wire is_sc_q   = (sub_q == `LSU_SC);
    wire is_amo_q  = (sub_q >= `LSU_AMOSWAP) && (sub_q <= `LSU_AMOMAXU);

    //  SC success at issue: reservation valid AND addr matches.
    wire sc_pass_i = is_sc_in && reserve_valid && (reserve_addr == addr);

    wire [2:0]  low3 = addr_q[2:0];

    wire [3:0]  size_bytes_q =
        (size_q == `LS_B) ? 4'd1 :
        (size_q == `LS_H) ? 4'd2 :
        (size_q == `LS_W) ? 4'd4 : 4'd8;
    wire [7:0]  full_mask_q =
        (size_q == `LS_B) ? 8'h01 :
        (size_q == `LS_H) ? 8'h03 :
        (size_q == `LS_W) ? 8'h0f : 8'hff;
    wire [3:0]  bytes_lo_q = 4'd8 - {1'b0, low3};
    wire [6:0]  shift_lo_q = {bytes_lo_q, 3'b000};
    wire [6:0]  addr_shift_q = {low3, 3'b000};
    wire [7:0]  strb_hi_q = full_mask_q >> bytes_lo_q;
    wire [63:0] wdata_hi_q = wdata_q >> shift_lo_q;

    wire [3:0]  size_bytes_i =
        (size == `LS_B) ? 4'd1 :
        (size == `LS_H) ? 4'd2 :
        (size == `LS_W) ? 4'd4 : 4'd8;
    wire        cross_i = ({1'b0, addr[2:0]} + size_bytes_i) > 4'd8;

    //  == load formatting ==
    wire [127:0] rd_pair = {rdata, rd_lo_q};
    wire [63:0] rd_sh  = cross_q ? (rd_pair >> addr_shift_q) :
                                   (rdata >> addr_shift_q);
    wire [63:0] ld_b   = sign_q ? {{56{rd_sh[ 7]}}, rd_sh[ 7:0]} : {56'b0, rd_sh[ 7:0]};
    wire [63:0] ld_h   = sign_q ? {{48{rd_sh[15]}}, rd_sh[15:0]} : {48'b0, rd_sh[15:0]};
    wire [63:0] ld_w   = sign_q ? {{32{rd_sh[31]}}, rd_sh[31:0]} : {32'b0, rd_sh[31:0]};
    wire [63:0] ld_d   = rd_sh;

    //  ==================================================================
    //  AMO ALU. amo_loaded is the 64-bit beat read from memory; for .W
    //  we extract the right word based on addr_q[2]. Result is written
    //  back into the same byte-lane of a new 64-bit beat.
    //  ==================================================================
    wire [31:0] amo_loaded_w_lane = addr_q[2] ? amo_loaded[63:32] : amo_loaded[31:0];
    wire [63:0] amo_op_a = (size_q == `LS_W)
        ? {{32{amo_loaded_w_lane[31]}}, amo_loaded_w_lane}  //  sign-ext for signed cmp
        : amo_loaded;
    wire [63:0] amo_op_b = (size_q == `LS_W)
        ? {{32{wdata_q[31]}}, wdata_q[31:0]}
        : wdata_q;
    wire signed [63:0] amo_a_s = amo_op_a;
    wire signed [63:0] amo_b_s = amo_op_b;

    wire [63:0] amo_result =
        (sub_q == `LSU_AMOSWAP) ? amo_op_b :
        (sub_q == `LSU_AMOADD)  ? (amo_op_a + amo_op_b) :
        (sub_q == `LSU_AMOXOR)  ? (amo_op_a ^ amo_op_b) :
        (sub_q == `LSU_AMOAND)  ? (amo_op_a & amo_op_b) :
        (sub_q == `LSU_AMOOR)   ? (amo_op_a | amo_op_b) :
        (sub_q == `LSU_AMOMIN)  ? (amo_a_s < amo_b_s ? amo_op_a : amo_op_b) :
        (sub_q == `LSU_AMOMAX)  ? (amo_a_s > amo_b_s ? amo_op_a : amo_op_b) :
        (sub_q == `LSU_AMOMINU) ? (amo_op_a < amo_op_b ? amo_op_a : amo_op_b) :
        (sub_q == `LSU_AMOMAXU) ? (amo_op_a > amo_op_b ? amo_op_a : amo_op_b) :
        64'b0;

    //  Pack the result back into a 64-bit beat at the right lane.
    wire [63:0] amo_write_beat = (size_q == `LS_W)
        ? (addr_q[2] ? {amo_result[31:0], 32'b0} : {32'b0, amo_result[31:0]})
        : amo_result;
    wire [7:0]  amo_wstrb = (size_q == `LS_W)
        ? (addr_q[2] ? 8'hF0 : 8'h0F)
        : 8'hFF;
    //  rd_v from AMO: sign-extended original value (the "old" memory contents).
    wire [63:0] amo_rd = (size_q == `LS_W) ? amo_op_a : amo_loaded;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            arvalid <= 0; rready    <= 0;
            awvalid <= 0; wvalid    <= 0; bready <= 0;
            done    <= 0;
            reserve_valid <= 0;
        end else begin
            done <= 0;  //  one-cycle pulse default

            case (state)
                S_IDLE: begin
                    if (req) begin
                        addr_q  <= addr;
                        addr2_q <= addr2;
                        wdata_q <= wdata;
                        size_q  <= size;
                        sign_q  <= sign_l;
                        cross_q <= cross_i;
                        sub_q   <= sub_in;
                        if (is_sc_in && !sc_pass_i) begin
                            //  SC failure: no AXI activity, rd=1.
                            rd_v    <= 64'b1;
                            done    <= 1'b1;
                            reserve_valid <= 1'b0;
                            //  stay in IDLE
                        end else if (is_cbonop_in) begin
                            //  cbo.clean/flush/inval: translation already done; retire.
                            done    <= 1'b1;    //  no memory transaction
                        end else if (is_store || (is_sc_in && sc_pass_i)) begin
                            //  prepare AW + W payload, drive both VALID
                            awaddr  <= { addr[`AXI_ADDR_W-1:3], 3'b000 };
                            awid    <= 0;
                            awlen   <= 0;
                            awsize  <= `AXI_SIZE_8B;
                            awburst <= `AXI_BURST_INCR;
                            awprot  <= 0;
                            awvalid <= 1;
                            case (size)
                                `LS_B:  wstrb <= 8'h01 << addr[2:0];
                                `LS_H:  wstrb <= 8'h03 << addr[2:0];
                                `LS_W:  wstrb <= 8'h0f << addr[2:0];
                                `LS_D:  wstrb <= 8'hff << addr[2:0];
                            endcase
                            wdata_o <= wdata << {addr[2:0], 3'b000};
                            wlast   <= 1;
                            wvalid  <= 1;
                            bready  <= 1;
                            state   <= S_AWW;
                            //  Only an SC (success) consumes its reservation. A
                            //  plain same-hart store must NOT invalidate it: the
                            //  reference model (and arch-test
                            //  cp_custom_sc_after_store_*) keep the reservation
                            //  valid through an intervening store. (The spec
                            //  permits spurious SC failure, but architectural
                            //  certification pins the reference's keep-it
                            //  behavior; a single-hart core has no other-hart
                            //  store to invalidate it.)
                            if (is_sc_in) reserve_valid <= 1'b0;
                        end else if (is_cboz_in) begin
                            //  cbo.zero: write 8 sequential 8-byte zero beats over
                            //  the 64-byte (Zic64b) block containing addr. First beat:
                            cbo_cnt <= 4'd0;
                            awaddr  <= { addr[`AXI_ADDR_W-1:6], 6'b0 }; //  64B-aligned
                            awid    <= 0; awlen <= 0; awsize <= `AXI_SIZE_8B;
                            awburst <= `AXI_BURST_INCR; awprot <= 0; awvalid <= 1;
                            wdata_o <= 64'b0; wstrb <= 8'hFF; wlast <= 1; wvalid <= 1;
                            bready  <= 1;
                            reserve_valid <= 1'b0;  //  a store to the block clears LR/SC
                            state   <= S_CBOZ_W;
                        end else begin
                            araddr  <= addr[`AXI_ADDR_W-1:0];
                            arid    <= 0;
                            arlen   <= 0;
                            arsize  <= `AXI_SIZE_8B;
                            arburst <= `AXI_BURST_INCR;
                            arprot  <= 0;
                            arvalid <= 1;
                            rready  <= 1;
                            state   <= S_AR;
                        end
                    end
                end
                S_AR: begin
                    if (arvalid && arready) begin
                        arvalid <= 0;
                        state   <= S_R;
                    end
                end
                S_R: begin
                    if (rvalid && rready) begin
                        if (cross_q) begin
                            rd_lo_q <= rdata;
                            araddr  <= addr2_q[`AXI_ADDR_W-1:0];    //  beat-2 base PA
                            arvalid <= 1;
                            state   <= S_AR2;
                        end else if (is_amo_q) begin
                            //  AMO: stash the loaded value, prep the write
                            amo_loaded  <= rdata;
                            rready      <= 0;
                            //  prepare AW + W payload, computed in the next
                            //  cycle when amo_loaded is registered. We use a
                            //  dedicated state so the AMO ALU sees the latched
                            //  amo_loaded.
                            state       <= S_AMO_W;
                        end else begin
                            case (size_q)
                                `LS_B: rd_v <= ld_b;
                                `LS_H: rd_v <= ld_h;
                                `LS_W: rd_v <= ld_w;
                                `LS_D: rd_v <= ld_d;
                            endcase
                            //  LR establishes the reservation on completion.
                            if (is_lr_q) begin
                                reserve_valid <= 1'b1;
                                reserve_addr  <= addr_q;
                            end
                            rready  <= 0;
                            done    <= 1;
                            state   <= S_IDLE;
                        end
                    end
                end
                S_AR2: begin
                    if (arvalid && arready) begin
                        arvalid <= 0;
                        state   <= S_R2;
                    end
                end
                S_R2: begin
                    if (rvalid && rready) begin
                        case (size_q)
                            `LS_B: rd_v <= ld_b;
                            `LS_H: rd_v <= ld_h;
                            `LS_W: rd_v <= ld_w;
                            `LS_D: rd_v <= ld_d;
                        endcase
                        rready  <= 0;
                        done    <= 1;
                        state   <= S_IDLE;
                    end
                end
                S_AWW: begin
                    //  Both AW and W must be accepted. The testbench
                    //  gates both on !b_pending, so they ack together.
                    if (awvalid && awready && wvalid && wready) begin
                        awvalid <= 0;
                        wvalid  <= 0;
                        state   <= S_B;
                    end
                end
                S_B: begin
                    if (bvalid && bready) begin
                        if (cross_q) begin
                            awaddr  <= addr2_q[`AXI_ADDR_W-1:0];    //  beat-2 base PA
                            wdata_o <= wdata_hi_q;
                            wstrb   <= strb_hi_q;
                            awvalid <= 1;
                            wvalid  <= 1;
                            state   <= S_AWW2;
                        end else begin
                            //  SC success: rd_v = 0. Plain store: rd_v unused.
                            if (is_sc_q) rd_v <= 64'b0;
                            bready  <= 0;
                            done    <= 1;
                            state   <= S_IDLE;
                        end
                    end
                end
                S_AWW2: begin
                    if (awvalid && awready && wvalid && wready) begin
                        awvalid <= 0;
                        wvalid  <= 0;
                        state   <= S_B2;
                    end
                end
                S_B2: begin
                    if (bvalid && bready) begin
                        bready  <= 0;
                        done    <= 1;
                        state   <= S_IDLE;
                    end
                end
                S_AMO_W: begin
                    //  Issue AW + W with the ALU result. amo_loaded was
                    //  registered on the previous clk edge so amo_result
                    //  is stable this cycle.
                    awaddr  <= {addr_q[`AXI_ADDR_W-1:3], 3'b000};
                    awid    <= 0;
                    awlen   <= 0;
                    awsize  <= `AXI_SIZE_8B;
                    awburst <= `AXI_BURST_INCR;
                    awprot  <= 0;
                    awvalid <= 1;
                    wdata_o <= amo_write_beat;
                    wstrb   <= amo_wstrb;
                    wlast   <= 1;
                    wvalid  <= 1;
                    bready  <= 1;
                    rd_v    <= amo_rd;
                    reserve_valid <= 1'b0;  //  AMO invalidates reservation
                    state   <= S_AMO_B;
                end
                S_AMO_B: begin
                    //  first half: wait for AW+W to be accepted, then for B
                    if (awvalid && awready && wvalid && wready) begin
                        awvalid <= 0;
                        wvalid  <= 0;
                    end
                    if (bvalid && bready) begin
                        bready  <= 0;
                        done    <= 1;
                        state   <= S_IDLE;
                    end
                end
                S_CBOZ_W: begin
                    if (awvalid && awready && wvalid && wready) begin
                        awvalid <= 0;
                        wvalid  <= 0;
                        state   <= S_CBOZ_B;
                    end
                end
                S_CBOZ_B: begin
                    if (bvalid && bready) begin
                        if (cbo_cnt == 4'd7) begin      //  all 8 beats (64 B) done
                            bready  <= 0;
                            done    <= 1;
                            state   <= S_IDLE;
                        end else begin                  //  issue the next 8-byte beat
                            cbo_cnt <= cbo_cnt + 4'd1;
                            awaddr  <= awaddr + 8;      //  bready stays high
                            wdata_o <= 64'b0; wstrb <= 8'hFF;
                            awvalid <= 1; wvalid <= 1;
                            state   <= S_CBOZ_W;
                        end
                    end
                end
            endcase
        end
    end

    assign busy = (state != S_IDLE);

    //  silence unused
    wire _unused = &{rid, rresp, rlast, bid, bresp, 1'b0};
endmodule
