//  htif_tb.v
//  HTIF testbench instantiating karu64 directly (no adapter). Same
//  AXI slave models as htif_tb_axi.v.

`include "karu_ext.vh"
`include "karu_axi_defs.vh"

`ifndef SIM_TB
`define SIM_TB
`endif

`ifndef HTIF_TB_XADR
`define HTIF_TB_XADR 17                  //  sim RAM = (1 << HTIF_TB_XADR) bytes
`endif

module clk_gen;
    /* verilator lint_off STMTDLY */
    reg clk = 1;
    always #5 clk = ~clk;
    /* verilator lint_on STMTDLY */
    htif_tb tb (clk);
endmodule

module htif_tb (input wire clk);

    localparam  RAM_BYTES   = 1 << `HTIF_TB_XADR;
    localparam  RAM_WORDS   = RAM_BYTES / 8;
    localparam  RAM_IDX_HI  = `HTIF_TB_XADR - 1;

    reg [63:0]  ram [0:RAM_WORDS-1];

    reg [8*128-1:0] hex_file;
    reg [8*128-1:0] vec_out_file;
    reg [31:0]      tohost_off    = 32'h0000_1000;
    reg [31:0]      max_cycles    = 32'd100_000;
    reg [31:0]      vec_out_start = 32'd0;  //  64-bit word index
    reg [31:0]      vec_out_words = 32'd0;
    reg             dump_vec_out  = 1'b0;
    wire [RAM_IDX_HI-3:0] tohost_idx = tohost_off[RAM_IDX_HI:3];

    integer pa_ok;
    initial begin
        if (!$value$plusargs("hex=%s", hex_file))
            hex_file = "_build/hello.hex";
        pa_ok = $value$plusargs("tohost=%h", tohost_off);
        pa_ok = $value$plusargs("max_cycles=%d", max_cycles);
        if ($value$plusargs("vec_out=%s", vec_out_file)) begin
            dump_vec_out = 1'b1;
            pa_ok = $value$plusargs("vec_out_start=%d", vec_out_start);
            pa_ok = $value$plusargs("vec_out_words=%d", vec_out_words);
        end
        $readmemh(hex_file, ram);
    end

    reg  [31:0] cyc = 0;
    wire        rst = (cyc < 4);
    reg  [31:0] hb_n = 0;
    reg         hb_ok;
    initial hb_ok = $value$plusargs("heartbeat=%d", hb_n);
    wire        trap;
    wire        irq = 0;

    //  == imem AXI4 slave ==
    wire [`AXI_ID_W-1:0]    imem_arid;
    wire [`AXI_ADDR_W-1:0]  imem_araddr;
    wire [`AXI_LEN_W-1:0]   imem_arlen;
    wire [`AXI_SIZE_W-1:0]  imem_arsize;
    wire [`AXI_BURST_W-1:0] imem_arburst;
    wire [`AXI_PROT_W-1:0]  imem_arprot;
    wire                    imem_arvalid;
    reg                     imem_arready;
    reg  [`AXI_ID_W-1:0]    imem_rid;
    reg  [`AXI_DATA_W-1:0]  imem_rdata;
    reg  [`AXI_RESP_W-1:0]  imem_rresp;
    reg                     imem_rlast;
    reg                     imem_rvalid;
    wire                    imem_rready;

    //  == dmem AXI4 slave ==
    wire [`AXI_ID_W-1:0]    dmem_arid;
    wire [`AXI_ADDR_W-1:0]  dmem_araddr;
    wire [`AXI_LEN_W-1:0]   dmem_arlen;
    wire [`AXI_SIZE_W-1:0]  dmem_arsize;
    wire [`AXI_BURST_W-1:0] dmem_arburst;
    wire [`AXI_PROT_W-1:0]  dmem_arprot;
    wire                    dmem_arvalid;
    reg                     dmem_arready;
    reg  [`AXI_ID_W-1:0]    dmem_rid;
    reg  [`AXI_DATA_W-1:0]  dmem_rdata;
    reg  [`AXI_RESP_W-1:0]  dmem_rresp;
    reg                     dmem_rlast;
    reg                     dmem_rvalid;
    wire                    dmem_rready;
    wire [`AXI_ID_W-1:0]    dmem_awid;
    wire [`AXI_ADDR_W-1:0]  dmem_awaddr;
    wire [`AXI_LEN_W-1:0]   dmem_awlen;
    wire [`AXI_SIZE_W-1:0]  dmem_awsize;
    wire [`AXI_BURST_W-1:0] dmem_awburst;
    wire [`AXI_PROT_W-1:0]  dmem_awprot;
    wire                    dmem_awvalid;
    reg                     dmem_awready;
    wire [`AXI_DATA_W-1:0]  dmem_wdata;
    wire [`AXI_STRB_W-1:0]  dmem_wstrb;
    wire                    dmem_wlast;
    wire                    dmem_wvalid;
    reg                     dmem_wready;
    reg  [`AXI_ID_W-1:0]    dmem_bid;
    reg  [`AXI_RESP_W-1:0]  dmem_bresp;
    reg                     dmem_bvalid;
    wire                    dmem_bready;
    wire                    aw_block;
    wire                    ar_block;

    //  imem read slave model -- supports INCR bursts (ARLEN>0). The Sv39 immu
    //  reads 64-byte page-table lines as 8-beat bursts on the imem master, so
    //  this must honour arlen/rlast (it previously single-beated, which fed the
    //  immu garbage PTEs and faulted every translated fetch). One transaction
    //  at a time; 8-byte (one ram word) increment per beat. arlen=0 fetches
    //  (the plain IFU path) still work (cnt=0 -> rlast on the first beat).
    reg                     imem_r_pending;
    reg [`AXI_ID_W-1:0]     imem_r_id;
    reg [RAM_IDX_HI-3:0]    imem_r_idx;
    reg [`AXI_LEN_W-1:0]    imem_r_cnt;     //  beats remaining after the current one
    //  Optional first-access read latency (DDR/FPGA model): +imem_lat=N stalls
    //  rvalid for N cycles after AR accept, before the first (burst) beat. This
    //  is the latency the I-cache exists to hide; default 0 = 1-cycle RAM.
    integer                 imem_lat = 0;
    integer                 imem_lat_ok;
    reg [31:0]              imem_lat_cnt;
    initial imem_lat_ok = $value$plusargs("imem_lat=%d", imem_lat);
    wire                    imem_lat_ready = (imem_lat_cnt == 0);
    //  Optional imem AR backpressure. This is separate from +imem_lat: latency
    //  delays R after AR accept; this holds ARREADY low and opens the AXI
    //  VALID && !READY stability window at the IFU/I-cache vs IMMU mux.
    reg [31:0]              imem_stall;
    reg [31:0]              imem_ar_cnt;
    reg                     imem_ar_armed;
    reg                     imem_stats;
    integer                 win_imem_ar_cyc;
    initial begin
        if (!$value$plusargs("imem_stall=%d", imem_stall)) imem_stall = 32'd0;
        imem_stats = (imem_stall != 0) || $test$plusargs("imem_stats");
        imem_ar_cnt = 32'd0;
        imem_ar_armed = 1'b0;
        win_imem_ar_cyc = 0;
    end
    wire imem_ar_arming = (imem_stall != 0) && !imem_ar_armed &&
                          imem_arvalid && !imem_r_pending;
    wire imem_ar_block = (imem_stall != 0) &&
                         ((imem_ar_armed && imem_ar_cnt != 0) || imem_ar_arming);

    always @(*) begin
        imem_arready = !imem_r_pending && !imem_ar_block;
        imem_rvalid  = imem_r_pending && imem_lat_ready;
        imem_rdata   = ram[imem_r_idx];
        imem_rid     = imem_r_id;
        imem_rresp   = `AXI_RESP_OKAY;
        imem_rlast   = imem_r_pending && imem_lat_ready && (imem_r_cnt == 0);
    end

    always @(posedge clk) begin
        if (rst) begin
            imem_r_pending <= 1'b0;
            imem_lat_cnt   <= 32'd0;
        end else begin
            if (!imem_r_pending) begin
                if (imem_arvalid && imem_arready) begin
                    imem_r_idx  <= imem_araddr[RAM_IDX_HI:3];
                    imem_r_id   <= imem_arid;
                    imem_r_cnt  <= imem_arlen;
                    imem_r_pending <= 1'b1;
                    imem_lat_cnt   <= imem_lat[31:0];   //  first-access stall
                end
            end else if (!imem_lat_ready) begin
                imem_lat_cnt <= imem_lat_cnt - 32'd1;   //  count down the access latency
            end else if (imem_rvalid && imem_rready) begin
                if (imem_r_cnt == 0) begin
                    imem_r_pending <= 1'b0;
                end else begin
                    imem_r_idx <= imem_r_idx + 1'b1;
                    imem_r_cnt <= imem_r_cnt - 1'b1;    //  burst beats: 1/cycle after the first
                end
                end
            end
    end

    always @(posedge clk) if (!rst && imem_stall != 0) begin
        if (!imem_ar_armed) begin
            if (imem_arvalid && !imem_r_pending) begin
                imem_ar_armed <= 1'b1;
                imem_ar_cnt <= imem_stall;
            end
        end else begin
            if (imem_ar_cnt != 0)
                imem_ar_cnt <= imem_ar_cnt - 1'b1;
            if (imem_arvalid && imem_arready)
                imem_ar_armed <= 1'b0;
            else if (!imem_arvalid)
                imem_ar_armed <= 1'b0;
        end
        if (imem_arvalid && !imem_arready)
            win_imem_ar_cyc <= win_imem_ar_cyc + 1;
    end

    //  dmem read slave model -- supports INCR bursts (ARLEN>0) for L1 line
    //  refill. One transaction at a time; ARLEN+1 beats, RLAST on the last,
    //  8-byte (one ram word) address increment per beat.
    reg                     dmem_r_pending;
    reg [`AXI_ID_W-1:0]     dmem_r_id;
    reg [RAM_IDX_HI-3:0]    dmem_r_idx;
    reg [`AXI_LEN_W-1:0]    dmem_r_cnt;     //  beats remaining after the current one

    always @(*) begin
        dmem_arready = !dmem_r_pending && !ar_block;
        dmem_rvalid  = dmem_r_pending;
        dmem_rdata   = ram[dmem_r_idx];
        dmem_rid     = dmem_r_id;
        dmem_rresp   = `AXI_RESP_OKAY;
        dmem_rlast   = dmem_r_pending && (dmem_r_cnt == 0);
    end

    always @(posedge clk) begin
        if (rst) begin
            dmem_r_pending <= 1'b0;
        end else begin
            if (!dmem_r_pending) begin
                if (dmem_arvalid && dmem_arready) begin
                    dmem_r_idx  <= dmem_araddr[RAM_IDX_HI:3];
                    dmem_r_id   <= dmem_arid;
                    dmem_r_cnt  <= dmem_arlen;
                    dmem_r_pending <= 1'b1;
                end
            end else if (dmem_rvalid && dmem_rready) begin
                if (dmem_r_cnt == 0) begin
                    dmem_r_pending <= 1'b0;
                end else begin
                    dmem_r_idx <= dmem_r_idx + 1'b1;
                    dmem_r_cnt <= dmem_r_cnt - 1'b1;
                end
            end
        end
    end

    //  dmem write slave model
    reg                     dmem_b_pending;
    reg [`AXI_ID_W-1:0]     dmem_b_id;

    always @(*) begin
        dmem_awready = !dmem_b_pending && !aw_block;
        dmem_wready  = !dmem_b_pending && !aw_block;
        dmem_bvalid  = dmem_b_pending;
        dmem_bid     = dmem_b_id;
        dmem_bresp   = `AXI_RESP_OKAY;
    end

    integer b;
    always @(posedge clk) begin
        if (rst) begin
            dmem_b_pending <= 1'b0;
        end else begin
            if (dmem_b_pending && dmem_bready)
                dmem_b_pending <= 1'b0;
            if (dmem_awvalid && dmem_awready &&
                dmem_wvalid  && dmem_wready) begin
                for (b = 0; b < 8; b = b + 1) begin
                    if (dmem_wstrb[b])
                        ram[dmem_awaddr[RAM_IDX_HI:3]][b*8 +: 8]
                            <= dmem_wdata[b*8 +: 8];
                end
                dmem_b_pending  <= 1'b1;
                dmem_b_id       <= dmem_awid;
            end
        end
    end

    //  ==== dmem AW/AR backpressure injection (repro; doc/fpga.md step 1) ====
    //  OFF by default (byte-identical to a normal run). +ddr_stall=N holds dmem awready/arready
    //  low for ~N cycles after a request first asserts, so the core's AW/AR is HELD against
    //  backpressure -- opening the "VALID && !READY" window in which a higher-priority PTW writeback
    //  can preempt the AXI payload. On the pre-fix arbiter the karu_assert dmem AW/AR-stability KCHK
    //  then fires; on the sticky-grant fix it stays green. win_*_cyc confirm the window opened.
    reg [31:0]  ddr_stall;
    reg [31:0]  aw_cnt, ar_cnt;
    reg     aw_armed, ar_armed;
    reg     ddr_stats;
    integer     win_aw_cyc, win_ar_cyc;
    initial begin
        if (!$value$plusargs("ddr_stall=%d", ddr_stall)) ddr_stall = 32'd0;
        ddr_stats = (ddr_stall != 0) || $test$plusargs("ddr_stats");
        aw_cnt = 0; ar_cnt = 0; aw_armed = 1'b0; ar_armed = 1'b0;
        win_aw_cyc = 0; win_ar_cyc = 0;
    end
    wire aw_arming = (ddr_stall != 0) && !aw_armed && dmem_awvalid && !dmem_b_pending;
    wire ar_arming = (ddr_stall != 0) && !ar_armed && dmem_arvalid && !dmem_r_pending;
    assign aw_block = (ddr_stall != 0) && ((aw_armed && aw_cnt != 0) || aw_arming);
    assign ar_block = (ddr_stall != 0) && ((ar_armed && ar_cnt != 0) || ar_arming);
    always @(posedge clk) if (!rst && ddr_stall != 0) begin
        if (!aw_armed) begin
            if (dmem_awvalid && !dmem_b_pending) begin aw_armed <= 1'b1; aw_cnt <= ddr_stall; end
        end else begin
            if (aw_cnt != 0) aw_cnt <= aw_cnt - 1'b1;
            if (dmem_awvalid && dmem_awready && dmem_wvalid && dmem_wready) aw_armed <= 1'b0;
            else if (!dmem_awvalid) aw_armed <= 1'b0;
        end
        if (!ar_armed) begin
            if (dmem_arvalid && !dmem_r_pending) begin ar_armed <= 1'b1; ar_cnt <= ddr_stall; end
        end else begin
            if (ar_cnt != 0) ar_cnt <= ar_cnt - 1'b1;
            if (dmem_arvalid && dmem_arready) ar_armed <= 1'b0;
            else if (!dmem_arvalid) ar_armed <= 1'b0;
        end
        if (dmem_awvalid && !dmem_awready) win_aw_cyc <= win_aw_cyc + 1;
        if (dmem_arvalid && !dmem_arready) win_ar_cyc <= win_ar_cyc + 1;
    end

    //  workload characterization: do >=2 write masters ever contend, and do the
    //  immu/dmmu PTE A/D writebacks (the bug's aggressor) actually fire?
    integer cont_aw_cyc, n_immu_aw, n_dmmu_aw, n_km_aw;
    integer cont_imem_ar, n_immu_ar, n_ifm_ar;
    initial begin cont_aw_cyc = 0; n_immu_aw = 0; n_dmmu_aw = 0; n_km_aw = 0;
        cont_imem_ar = 0; n_immu_ar = 0; n_ifm_ar = 0; end
    always @(posedge clk) if (!rst) begin
        if ((cpu.dmmu_awvalid + cpu.immu_awvalid + cpu.km_awvalid) > 1)
            cont_aw_cyc <= cont_aw_cyc + 1;
        if (cpu.immu_awvalid) n_immu_aw <= n_immu_aw + 1;
        if (cpu.dmmu_awvalid) n_dmmu_aw <= n_dmmu_aw + 1;
        if (cpu.km_awvalid)   n_km_aw   <= n_km_aw   + 1;
        //  imem-AR contention: IFU/I-cache refill vs IMMU PTE-walk read both wanting the channel
        if (cpu.immu_arvalid && cpu.ifm_arvalid) cont_imem_ar <= cont_imem_ar + 1;
        if (cpu.immu_arvalid) n_immu_ar <= n_immu_ar + 1;
        if (cpu.ifm_arvalid)  n_ifm_ar  <= n_ifm_ar  + 1;
    end

    //  HTIF watcher
    reg [63:0] tohost_v;
    always @(posedge clk) begin
        if (!rst) begin
            tohost_v = ram[tohost_idx];
            if (tohost_v != 64'b0) begin
                if (tohost_v[63:56] == 8'd1 && tohost_v[55:48] == 8'd1) begin
                    $write("%c", tohost_v[7:0]);
                    $fflush(1);
                end else if (tohost_v[63:56] == 8'd0 && tohost_v[0]) begin
                    $display("\n[HTIF] exit %0d @ cyc=%0d",
                        tohost_v >> 1, cyc);
                    if (ddr_stats) begin
                        $display("[ddr_stall] win_aw_cyc=%0d win_ar_cyc=%0d", win_aw_cyc, win_ar_cyc);
                        $display("[ddr_contention] cont_aw_cyc=%0d immu_aw=%0d dmmu_aw=%0d km_aw=%0d",
                            cont_aw_cyc, n_immu_aw, n_dmmu_aw, n_km_aw);
                    end
                    if (imem_stats) begin
                        $display("[imem_stall] win_ar_cyc=%0d", win_imem_ar_cyc);
                        $display("[imem_contention] cont_imem_ar=%0d immu_ar=%0d ifm_ar=%0d",
                            cont_imem_ar, n_immu_ar, n_ifm_ar);
                    end
                    if (dump_vec_out) begin
                        $writememh(vec_out_file, ram, vec_out_start,
                            vec_out_start + vec_out_words - 1);
                        $display("[HTIF] dumped %0d words to %0s",
                            vec_out_words, vec_out_file);
                    end
                    $finish;
                end else begin
                    $display("\n[HTIF] unknown command %h @ cyc=%0d",
                        tohost_v, cyc);
                end
                ram[tohost_idx] <= 64'b0;
            end
        end
    end

    //  cycle counter / watchdog
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (trap) begin
            $display("\n[**TRAP**] cyc=%0d", cyc);
            $finish;
        end
        if (cyc >= max_cycles) begin
            $display("\n[**TIMEOUT**] cyc=%0d", cyc);
            $finish;
        end
        //  heartbeat: +heartbeat=N prints cyc + current PC every N cycles so
        //  long runs show progress live (flushed). 0/absent = off.
        if (hb_n != 0 && !rst && (cyc % hb_n == 0)) begin
            $display("[HB] cyc=%0d pc=%08h", cyc, cpu.ifu_pc);
            $fflush;
        end

`ifdef PDEBUG
        if (!rst && cyc < 32) begin
            $display("[DBG cyc=%0d] ifu: pc=%08h v=%b w=%08h take=%b cf=%b redir=%b -> %08h",
                cyc, cpu.ifu_pc, cpu.ifu_valid, cpu.ifu_w,
                cpu.ifu_take, cpu.ifu_take_c,
                cpu.ifu_redir, cpu.ifu_redir_pc);
            $display("           ifu_int: buf0_v=%b a=%08h d=%016h buf1_v=%b a=%08h d=%016h arvalid=%b arready=%b rvalid=%b",
                cpu.ifu.buf0_v, cpu.ifu.buf0_a, cpu.ifu.buf0_d,
                cpu.ifu.buf1_v, cpu.ifu.buf1_a, cpu.ifu.buf1_d,
                cpu.ifu.arvalid, imem_arready, imem_rvalid);
            $display("           dec: unit=%h sub=%h rd=%d rs1=%d rs2=%d imm=%h is_c=%b",
                cpu.dec_unit, cpu.dec_sub, cpu.dec_rd, cpu.dec_rs1, cpu.dec_rs2,
                cpu.dec_imm, cpu.is_c);
        end
`endif
    end

`ifdef KARU_SSCOFPMF
    //  Sscofpmf overflow test needs a deterministic HPM event source. Drive event 1
    //  from the core's retire pulse, so mhpmevent3=1 counts retired instructions and a
    //  preloaded counter can be made to wrap. Gated on KARU_SSCOFPMF so every other
    //  build keeps hpm_events tied to 0 (byte-identical).
    wire [31:0] tb_hpm_events = {30'b0, cpu.perf_retire, 1'b0}; //  bit 1 = retire
`else
    wire [31:0] tb_hpm_events = 32'b0;
`endif

    //  The actual core under test.
    karu64 #(
        .RESET_PC (32'h8000_0000)
    ) cpu (
        .clk        (clk),
        .rst        (rst),
        .trap       (trap),
        //  HTIF tohost lives in this 4 KiB page -> uncacheable to the L1
        //  (device polled by the TB; a cached copy would deadlock HTIF).
        .uncache_page ((32'h8000_0000 + tohost_off) & 32'hFFFF_F000),
        .irq        (irq),
        //  Privilege/interrupt/cacheop ports added by the ecp5 rebase. The HTIF
        //  testbench has no PLIC, no HPM event sources, and no D-cache, so external
        //  interrupts and HPM events are tied off and FENCE/FENCE.I complete
        //  immediately (cache_flush_done held high; req/invalidate outputs unused).
        .irq_external_m (1'b0),
        .irq_external_s (1'b0),
        .time_in        (64'b0),        //  EXT_TIME=0: rdtime uses the cycle counter
        .hpm_events     (tb_hpm_events),
        .cache_flush_req        (),
        .cache_flush_invalidate (),
        .cache_flush_done       (1'b1),
        .imem_arid      (imem_arid),    .imem_araddr    (imem_araddr),
        .imem_arlen     (imem_arlen),   .imem_arsize    (imem_arsize),
        .imem_arburst   (imem_arburst), .imem_arprot    (imem_arprot),
        .imem_arvalid   (imem_arvalid), .imem_arready   (imem_arready),
        .imem_rid       (imem_rid),     .imem_rdata     (imem_rdata),
        .imem_rresp     (imem_rresp),   .imem_rlast     (imem_rlast),
        .imem_rvalid    (imem_rvalid),  .imem_rready    (imem_rready),
        .dmem_arid      (dmem_arid),    .dmem_araddr    (dmem_araddr),
        .dmem_arlen     (dmem_arlen),   .dmem_arsize    (dmem_arsize),
        .dmem_arburst   (dmem_arburst), .dmem_arprot    (dmem_arprot),
        .dmem_arvalid   (dmem_arvalid), .dmem_arready   (dmem_arready),
        .dmem_rid       (dmem_rid),     .dmem_rdata     (dmem_rdata),
        .dmem_rresp     (dmem_rresp),   .dmem_rlast     (dmem_rlast),
        .dmem_rvalid    (dmem_rvalid),  .dmem_rready    (dmem_rready),
        .dmem_awid      (dmem_awid),    .dmem_awaddr    (dmem_awaddr),
        .dmem_awlen     (dmem_awlen),   .dmem_awsize    (dmem_awsize),
        .dmem_awburst   (dmem_awburst), .dmem_awprot    (dmem_awprot),
        .dmem_awvalid   (dmem_awvalid), .dmem_awready   (dmem_awready),
        .dmem_wdata     (dmem_wdata),   .dmem_wstrb     (dmem_wstrb),
        .dmem_wlast     (dmem_wlast),   .dmem_wvalid    (dmem_wvalid),
        .dmem_wready    (dmem_wready),
        .dmem_bid       (dmem_bid),     .dmem_bresp     (dmem_bresp),
        .dmem_bvalid    (dmem_bvalid),  .dmem_bready    (dmem_bready)
    );

    //  Architectural-invariant + hang-guard checker. Passive observer of
    //  the core's internal state/signaling (no instruction semantics).
    //  Wired via hierarchical references into `cpu`; iverilog lacks
    //  `bind`, so this is the portable attachment for both sims. Disable
    //  at runtime with +no_assert; report-without-stopping with
    //  +no_assert_stop. See rtl/karu_assert.sv.
`ifndef KARU_NO_ASSERT
    karu_assert u_kassert (
        .clk            (clk),
        .rst            (rst),
        .trap           (trap),
        .issuing        (cpu.issuing),
        .lsu_active     (cpu.lsu_active),
        .m_active       (cpu.m_active),
        .fpu_active     (cpu.fpu_active),
        .vlsu_active    (cpu.vlsu_active),
        .varith_active  (cpu.varith_active),
        .vfpu_active    (1'b0), //  vector FP merged into karu_varith (tracked via varith_*)
        .vkeccak_active (1'b0), //  keccak folded into karu_varith (tracked via varith_*)
        .lsu_req        (cpu.lsu_req),
        .lsu_done       (cpu.lsu_done),
        .m_req          (cpu.m_req),
        .m_done         (cpu.m_done),
        .fpu_req        (cpu.fpu_req),
        .fpu_done       (cpu.fpu_done),
`ifdef KARU_EN_F
        .fpu_sub_req    (cpu.fpu.dbg_fpu_sub_req),
`else
        .fpu_sub_req    (10'b0),
`endif
        .vlsu_req       (cpu.vlsu_req),
        .vlsu_done      (cpu.vlsu_done),
        .varith_req     (cpu.varith_req),
        .varith_done    (cpu.varith_done),
        .vfpu_req       (1'b0), //  merged into karu_varith
        .vfpu_done      (1'b0),
        .vfp_lane_active(cpu.varith_fp_lane_active),    //  post-merge lane FP activity
`ifdef KARU_EN_V
        .vfp_req_busy   (cpu.varith_u.dbg_fp_req_busy), //  lane FP req to a busy lane (must be 0)
        .lane_warm_bad  (cpu.varith_u.dbg_lane_warm_bad),   //  KARU_V_LANE_PIPE warm-cycle leak (must be 0)
`else
        .vfp_req_busy   (1'b0),
        .lane_warm_bad  (1'b0),
`endif
        .vkeccak_req    (1'b0), //  folded into karu_varith
        .vkeccak_done   (1'b0),
        .wb_we          (cpu.wb_we),
        .wb_rd          (cpu.wb_rd),
        .fwb_we         (cpu.fwb_we),
        .vrf_we         (cpu.vrf_we),
        .vg_we          (cpu.vg_we),
        .vxsat_set      (cpu.varith_vxsat),
        .vmem_req       (cpu.vmem_req),
        .vmem_is_store  (cpu.vmem_is_store),
        .vmem_addr      (cpu.vmem_addr),
        .ifu_valid      (cpu.ifu_valid),
        .ifu_pc         (cpu.ifu_pc),
        .ifu_redir      (cpu.ifu_redir),
        .ifu_redir_pc   (cpu.ifu_redir_pc),
        .perf_retire    (cpu.perf_retire),
`ifdef KARU_EN_S
        .i_mmu_busy     (cpu.immu.busy),
        .i_mmu_req      (cpu.immu.req),
        .d_mmu_busy     (cpu.dmmu.busy),
        .d_mmu_req      (cpu.dmmu.req),
`else
        .i_mmu_busy     (1'b0), //  immu/dmmu compiled out (KARU_NO_S)
        .i_mmu_req      (1'b0),
        .d_mmu_busy     (1'b0),
        .d_mmu_req      (1'b0),
`endif
        .imem_arvalid   (imem_arvalid), .imem_arready   (imem_arready),
        .imem_araddr    (imem_araddr),
        .imem_arid      (imem_arid),    .imem_arlen     (imem_arlen),
        .imem_arsize    (imem_arsize),  .imem_arburst   (imem_arburst),
        .imem_arprot    (imem_arprot),
        .dmem_arvalid   (dmem_arvalid), .dmem_arready   (dmem_arready),
        .dmem_araddr    (dmem_araddr),
        .dmem_arid      (dmem_arid),    .dmem_arlen     (dmem_arlen),
        .dmem_arsize    (dmem_arsize),  .dmem_arburst   (dmem_arburst),
        .dmem_arprot    (dmem_arprot),
        .dmem_awvalid   (dmem_awvalid), .dmem_awready   (dmem_awready),
        .dmem_awaddr    (dmem_awaddr),
        .dmem_awid      (dmem_awid),    .dmem_awlen     (dmem_awlen),
        .dmem_awsize    (dmem_awsize),  .dmem_awburst   (dmem_awburst),
        .dmem_awprot    (dmem_awprot),
        .dmem_wvalid    (dmem_wvalid),  .dmem_wready    (dmem_wready),
        .dmem_wdata     (dmem_wdata),   .dmem_wstrb     (dmem_wstrb),
        .dmem_wlast     (dmem_wlast),
        //  RVA23 semantic contracts (Supm / CBO / TVM-TW-TSR / Zfa)
        .csr_dpmlen     (cpu.csr_dpmlen),
        .lsu_addr       (cpu.lsu_addr),
`ifdef KARU_EN_V
        .vlsu_base_pm   (cpu.vlsu_base_pm),
`else
        .vlsu_base_pm   (64'b0),
`endif
        .cbo_ill        (cpu.cbo_ill),
        .lsu_is_cbo     (cpu.lsu_is_cbo),
        .lsu_is_cboz    (cpu.lsu_is_cboz),
        .lsu_is_cbocf   (cpu.lsu_is_cbocf),
        .lsu_is_cboinval(cpu.lsu_is_cboinval),
        .lsu_awvalid    (cpu.lsu_awvalid),
        .lsu_wvalid     (cpu.lsu_wvalid),
        .lsu_wstrb      (cpu.lsu_wstrb),
        .lsu_wdata_o    (cpu.lsu_wdata_o),
        .lsu_awaddr     (cpu.lsu_awaddr),
        .sret_ill       (cpu.sret_ill),
        .sfence_ill     (cpu.sfence_ill),
        .mret_ill       (cpu.mret_ill),
        .sys_priv_ill   (cpu.sys_priv_ill),
        .sys_sret       (cpu.sys_sret),
        .sys_mret       (cpu.sys_mret),
        .sys_sfencevma  (cpu.sys_sfencevma),
        .trap_req       (cpu.trap_req),
        .trap_cause     (cpu.trap_cause),
        .ex_fp_zfa      (cpu.ex_fp_zfa),
        //  stronger RVA23 contracts (beat counter / positive Zfa / recompute)
        .ex_rd          (cpu.ex_rd),
        .lsu_xlate_active(cpu.lsu_xlate_active),
        .lsu_bare       (cpu.lsu_bare),
        .lsu_awready    (cpu.km_s_awready),
        .dmmu_req_lsu   (cpu.dmmu_req_lsu), //  forced 0 under KARU_NO_S (lsu_bare=1)
`ifdef KARU_EN_S
        .dmmu_va        (cpu.dmmu.va),
        .dmmu_va_exp    (cpu.lsu_dmmu_va_exp),
`else
        .dmmu_va        (64'b0),    //  INV29 vacuous: dmmu_req_lsu==0 when no S/Sv39
        .dmmu_va_exp    (64'b0),
`endif
`ifdef KARU_EN_V
        .vlsu_base_q    (cpu.vlsu.base_q),
`else
        .vlsu_base_q    (64'b0),
`endif
        .csr_priv       (cpu.csr_priv),
        .menvcfg_cbze   (cpu.csr.menvcfg_cbze), .menvcfg_cbcfe  (cpu.csr.menvcfg_cbcfe),
        .menvcfg_cbie   (cpu.csr.menvcfg_cbie),
        .senvcfg_cbze   (cpu.csr.senvcfg_cbze), .senvcfg_cbcfe  (cpu.csr.senvcfg_cbcfe),
        .senvcfg_cbie   (cpu.csr.senvcfg_cbie),
        .cbo_zero_en    (cpu.cbo_zero_en),  .cbo_cf_en  (cpu.cbo_cf_en),    .cbo_inval_en   (cpu.cbo_inval_en),
        .csr_tvm        (cpu.csr_tvm),  .csr_tw (cpu.csr_tw),   .csr_tsr    (cpu.csr_tsr),
        .sys_sret_raw   (cpu.sys_sret_raw), .sys_sfence_raw (cpu.sys_sfence_raw),   .sys_wfi_raw    (cpu.sys_wfi_raw),
        .csr_op_req     (cpu.csr_req),
        .csr_op_addr    (cpu.csr_addr),
        .csr_illegal    (cpu.csr_illegal),
        .csr_mcounteren (cpu.csr.csr_mcounteren[31:0]),
        .csr_scounteren (cpu.csr.csr_scounteren[31:0])
    );
`endif

endmodule
