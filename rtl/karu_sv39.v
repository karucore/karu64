//  karu_sv39.v
//  Minimal Sv39 translator with a tiny fully-associative TLB and a small
//  page-table-line cache. Page tables live in external memory; this block
//  only caches translations and 64-byte aligned PTE lines.

`include "karu_axi_defs.vh"

module karu_sv39 #(
    parameter TLB_ENTRIES = 4,
    parameter PWC_LINES = 4
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         req,
    input  wire [63:0]  va,
    input  wire [1:0]   access,     //  0=fetch, 1=load, 2=store/AMO
    input  wire [1:0]   priv,       //  0=U, 1=S, 3=M
    input  wire [63:0]  satp,
    input  wire         status_sum,
    input  wire         status_mxr,
    input  wire         flush,

    output reg          done,
    output reg          fault,
    output reg [63:0]   fault_va,
    output reg [63:0]   fault_cause,
    output reg [63:0]   pa,
    output wire         busy,

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
    output reg [`AXI_DATA_W-1:0]    wdata,
    output reg [`AXI_STRB_W-1:0]    wstrb,
    output reg                      wlast,
    output reg                      wvalid,
    input  wire                     wready,
    input  wire [`AXI_ID_W-1:0]     bid,
    input  wire [`AXI_RESP_W-1:0]   bresp,
    input  wire                     bvalid,
    output reg                      bready
);
    localparam [2:0] S_IDLE = 3'd0,
                     S_LOOK = 3'd1,
                     S_AR   = 3'd2,
                     S_R    = 3'd3,
                     S_AD   = 3'd4,
                     S_ADB  = 3'd5;

    localparam [1:0] ACC_FETCH = 2'd0,
                     ACC_LOAD  = 2'd1,
                     ACC_STORE = 2'd2,
                     ACC_CBOCF = 2'd3;  //  cbo.clean/flush: needs R OR W, store-class fault
    localparam [1:0] PRIV_U = 2'd0,
                     PRIV_S = 2'd1,
                     PRIV_M = 2'd3;

    reg [2:0]   state;
    reg [63:0]  va_q;
    reg [1:0]   access_q;
    reg [1:0]   priv_q;
    reg [63:0]  satp_q;
    reg         sum_q, mxr_q;
    reg [1:0]   level_q;        //  2, 1, 0 while walking
    reg [43:0]  pt_ppn_q;
    reg [63:0]  pte_addr_q;
    reg [63:0]  pte_q;
    reg [63:0]  pte_new_q;
    reg [2:0]   fill_beat_q;
    //  Set when a flush (sfence.vma) arrives while a walk is active. The walk
    //  may be based on page-table/cache state invalidated by the flush, so its
    //  result must not update TLB/PWC state or start a new A/D writeback.
    reg         walk_poison;

    //  Same-cycle flush+completion must suppress fills/writebacks immediately;
    //  waiting for the registered poison bit would be one cycle too late.
    wire        poison_eff = walk_poison || (flush && (state != S_IDLE));

    wire bare_mode = (priv == PRIV_M) || (satp[63:60] != 4'd8);
    wire va_canon = (va[63:39] == {25{va[38]}});
    wire [26:0] va_vpn = va[38:12];

    reg [TLB_ENTRIES-1:0]       tlb_v;
    reg [26:0]                  tlb_vpn [0:TLB_ENTRIES-1];
    reg [43:0]                  tlb_ppn [0:TLB_ENTRIES-1];
    reg [7:0]                   tlb_perm [0:TLB_ENTRIES-1];
    reg [1:0]                   tlb_level [0:TLB_ENTRIES-1];
    //  Address-space tag: a TLB entry only matches when the current satp ASID
    //  and root PPN match the ones the entry was filled under. Without this the
    //  VPN-only match aliases across address spaces, so a Linux ASID context
    //  switch (new satp, no sfence.vma) wrongly reuses the previous mapping.
    reg [15:0]                  tlb_asid [0:TLB_ENTRIES-1];
    reg [43:0]                  tlb_root [0:TLB_ENTRIES-1];
    reg [1:0]                   tlb_replace;

    reg [PWC_LINES-1:0]         pwc_v;
    reg [57:6]                  pwc_tag [0:PWC_LINES-1];
    reg [511:0]                 pwc_fill_line;
    reg [1:0]                   pwc_replace;
    reg [1:0]                   fill_way_q;

    integer i;

    function automatic [8:0] vpn_i(input [63:0] a, input [1:0] lvl);
        begin
            case (lvl)
                2'd2: vpn_i = a[38:30];
                2'd1: vpn_i = a[29:21];
                default: vpn_i = a[20:12];
            endcase
        end
    endfunction

    function automatic [63:0] line_pte(input [511:0] line, input [2:0] idx);
        begin
            case (idx)
                3'd0: line_pte = line[ 63:  0];
                3'd1: line_pte = line[127: 64];
                3'd2: line_pte = line[191:128];
                3'd3: line_pte = line[255:192];
                3'd4: line_pte = line[319:256];
                3'd5: line_pte = line[383:320];
                3'd6: line_pte = line[447:384];
                default: line_pte = line[511:448];
            endcase
        end
    endfunction

    function automatic [511:0] line_put(input [511:0] line, input [2:0] idx, input [63:0] beat);
        begin
            line_put = line;
            case (idx)
                3'd0: line_put[ 63:  0] = beat;
                3'd1: line_put[127: 64] = beat;
                3'd2: line_put[191:128] = beat;
                3'd3: line_put[255:192] = beat;
                3'd4: line_put[319:256] = beat;
                3'd5: line_put[383:320] = beat;
                3'd6: line_put[447:384] = beat;
                default: line_put[511:448] = beat;
            endcase
        end
    endfunction

    function automatic [63:0] leaf_pa(input [63:0] a, input [63:0] pte, input [1:0] lvl);
        begin
            case (lvl)
                2'd2: leaf_pa = {8'b0, pte[53:28], a[29:0]};
                2'd1: leaf_pa = {8'b0, pte[53:19], a[20:0]};
                default: leaf_pa = {8'b0, pte[53:10], a[11:0]};
            endcase
        end
    endfunction

    function automatic [63:0] fault_code(input [1:0] acc);
        begin
            fault_code = (acc == ACC_FETCH) ? 64'd12 :
                         (acc == ACC_LOAD)  ? 64'd13 : 64'd15;
        end
    endfunction

    function automatic pte_invalid(input [63:0] pte);
        begin
            //  V=0, or W without R (reserved), or any unsupported high bit set:
            //  bit63=N (Svnapot), 62:61=PBMT (Svpbmt), 60:54=reserved. This core
            //  advertises none of those, so a set bit there is a page fault
            //  (conservative -- prevents accepting mappings we don't implement).
            pte_invalid = !pte[0] || (!pte[1] && pte[2]) || (pte[63:54] != 10'b0);
        end
    endfunction

    function automatic pte_leaf(input [63:0] pte);
        begin
            pte_leaf = pte[1] || pte[3];
        end
    endfunction

    function automatic superpage_bad(input [63:0] pte, input [1:0] lvl);
        begin
            superpage_bad = (lvl == 2'd2 && pte[27:10] != 18'b0) ||
                            (lvl == 2'd1 && pte[18:10] != 9'b0);
        end
    endfunction

    function automatic perm_fault(
        input [7:0] perm,
        input [1:0] acc,
        input [1:0] prv,
        input sum,
        input mxr
    );
        reg ok;
        begin
            ok = (acc == ACC_FETCH) ? perm[3] :
                 (acc == ACC_LOAD)  ? (perm[1] || (mxr && perm[3])) :
                 (acc == ACC_CBOCF) ? (perm[1] || perm[2]) :    //  cbo.clean/flush: R or W
                                      perm[2];
            if (prv == PRIV_U)
                ok = ok && perm[4];
            else if (prv == PRIV_S && perm[4])
                ok = ok && (acc != ACC_FETCH) && sum;
            perm_fault = !ok;
        end
    endfunction

    reg tlb_hit;
    reg [1:0] tlb_hit_i;
    reg pwc_hit;
    reg [1:0] pwc_hit_i;
    reg [63:0] pte_from_cache;
    wire [511:0] pwc_hit_line;
    wire [511:0] pwc_fill_next = line_put(pwc_fill_line, fill_beat_q, rdata);
    wire         pwc_data_we = (state == S_R) && rvalid && rready;

    karu_1w1r_async_ram #(
        .DATA_W(512), .DEPTH(PWC_LINES), .ADDR_W(2)
    ) pwc_data_u (
        .clk(clk),
        .we(pwc_data_we), .waddr(fill_way_q), .wdata(pwc_fill_next),
        .raddr(pwc_hit_i), .rdata(pwc_hit_line)
    );

    always @(*) begin
        tlb_hit = 1'b0;
        tlb_hit_i = 2'd0;
        for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
            if (tlb_v[i] && !tlb_hit &&
                tlb_asid[i] == satp[59:44] && tlb_root[i] == satp[43:0]) begin
                if ((tlb_level[i] == 2'd0 && tlb_vpn[i] == va_vpn) ||
                    (tlb_level[i] == 2'd1 && tlb_vpn[i][26:9] == va_vpn[26:9]) ||
                    (tlb_level[i] == 2'd2 && tlb_vpn[i][26:18] == va_vpn[26:18])) begin
                    tlb_hit = 1'b1;
                    tlb_hit_i = i[1:0];
                end
            end
        end
    end

    always @(*) begin
        pwc_hit = 1'b0;
        pwc_hit_i = 2'd0;
        pte_from_cache = 64'b0;
        for (i = 0; i < PWC_LINES; i = i + 1) begin
            if (pwc_v[i] && pwc_tag[i] == pte_addr_q[57:6] && !pwc_hit) begin
                pwc_hit = 1'b1;
                pwc_hit_i = i[1:0];
                pte_from_cache = line_pte(pwc_hit_line, pte_addr_q[5:3]);
            end
        end
    end

    task automatic raise_fault;
        begin
            done <= 1'b1;
            fault <= 1'b1;
            fault_va <= va_q;
            fault_cause <= fault_code(access_q);
            if (poison_eff) begin
                pwc_v <= {PWC_LINES{1'b0}};
                walk_poison <= 1'b0;
            end
            state <= S_IDLE;
        end
    endtask

    task automatic finish_leaf(input [63:0] pte, input [1:0] lvl);
        reg [63:0] pa_w;
        begin
            if (poison_eff) begin
                done <= 1'b1;
                fault <= 1'b0;
                pwc_v <= {PWC_LINES{1'b0}};
                walk_poison <= 1'b0;
                state <= S_IDLE;
            end else if (perm_fault(pte[7:0], access_q, priv_q, sum_q, mxr_q) ||
                superpage_bad(pte, lvl)) begin
                raise_fault();
            end else if (!pte[6] || (access_q == ACC_STORE && !pte[7])) begin
                pte_new_q <= pte | 64'h0000_0000_0000_0040 |
                             (access_q == ACC_STORE ? 64'h0000_0000_0000_0080 : 64'b0);
                awaddr <= pte_addr_q[`AXI_ADDR_W-1:0];
                awid <= 0;
                awlen <= 0;
                awsize <= `AXI_SIZE_8B;
                awburst <= `AXI_BURST_INCR;
                awprot <= 0;
                awvalid <= 1'b1;
                wdata <= pte | 64'h0000_0000_0000_0040 |
                         (access_q == ACC_STORE ? 64'h0000_0000_0000_0080 : 64'b0);
                wstrb <= 8'hff;
                wlast <= 1'b1;
                wvalid <= 1'b1;
                bready <= 1'b1;
                pwc_v[pwc_hit_i] <= 1'b0;
                state <= S_AD;
            end else begin
                pa_w = leaf_pa(va_q, pte, lvl);
                pa <= pa_w;
                done <= 1'b1;
                fault <= 1'b0;
                tlb_v[tlb_replace] <= 1'b1;
                tlb_vpn[tlb_replace] <= va_q[38:12];
                tlb_ppn[tlb_replace] <= pa_w[55:12];
                tlb_perm[tlb_replace] <= pte[7:0];
                tlb_level[tlb_replace] <= lvl;
                tlb_asid[tlb_replace] <= satp_q[59:44];
                tlb_root[tlb_replace] <= satp_q[43:0];
                tlb_replace <= tlb_replace + 1'b1;
                state <= S_IDLE;
            end
        end
    endtask

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done <= 1'b0;
            fault <= 1'b0;
            arvalid <= 1'b0;
            rready <= 1'b0;
            awvalid <= 1'b0;
            wvalid <= 1'b0;
            bready <= 1'b0;
            tlb_v <= {TLB_ENTRIES{1'b0}};
            pwc_v <= {PWC_LINES{1'b0}};
            tlb_replace <= 0;
            pwc_replace <= 0;
            walk_poison <= 1'b0;
        end else begin
            done <= 1'b0;
            if (flush) begin
                tlb_v <= {TLB_ENTRIES{1'b0}};
                pwc_v <= {PWC_LINES{1'b0}};
                if (state != S_IDLE)
                    walk_poison <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (req) begin
                        va_q <= va;
                        access_q <= access;
                        priv_q <= priv;
                        satp_q <= satp;
                        sum_q <= status_sum;
                        mxr_q <= status_mxr;
                        if (bare_mode) begin
                            pa <= va;
                            done <= 1'b1;
                            fault <= 1'b0;
                        end else if (!va_canon) begin
                            done <= 1'b1;
                            fault <= 1'b1;
                            fault_va <= va;
                            fault_cause <= fault_code(access);
                        end else if (tlb_hit) begin
                            if (perm_fault(tlb_perm[tlb_hit_i], access, priv, status_sum, status_mxr)) begin
                                done <= 1'b1;
                                fault <= 1'b1;
                                fault_va <= va;
                                fault_cause <= fault_code(access);
                            end else begin
                                case (tlb_level[tlb_hit_i])
                                    2'd2: pa <= {8'b0, tlb_ppn[tlb_hit_i][43:18], va[29:0]};
                                    2'd1: pa <= {8'b0, tlb_ppn[tlb_hit_i][43:9], va[20:0]};
                                    default: pa <= {8'b0, tlb_ppn[tlb_hit_i], va[11:0]};
                                endcase
                                done <= 1'b1;
                                fault <= 1'b0;
                            end
                        end else begin
                            level_q <= 2'd2;
                            pt_ppn_q <= satp[43:0];
                            state <= S_LOOK;
                        end
                    end
                end
                S_LOOK: begin
                    pte_addr_q <= {8'b0, pt_ppn_q, 12'b0} + {52'b0, vpn_i(va_q, level_q), 3'b000};
                    state <= S_AR;
                end
                S_AR: begin
                    if (pwc_hit) begin
                        pte_q <= pte_from_cache;
                        if (pte_invalid(pte_from_cache)) begin
                            raise_fault();
                        end else if (pte_leaf(pte_from_cache)) begin
                            finish_leaf(pte_from_cache, level_q);
                        end else if (level_q == 2'd0) begin
                            raise_fault();
                        end else begin
                            pt_ppn_q <= pte_from_cache[53:10];
                            level_q <= level_q - 1'b1;
                            state <= S_LOOK;
                        end
                    end else begin
                        fill_way_q <= pwc_replace;
                        pwc_fill_line <= 512'b0;
                        araddr <= {pte_addr_q[`AXI_ADDR_W-1:6], 6'b0};
                        arid <= 0;
                        arlen <= 8'd7;
                        arsize <= `AXI_SIZE_8B;
                        arburst <= `AXI_BURST_INCR;
                        arprot <= 0;
                        arvalid <= 1'b1;
                        rready <= 1'b1;
                        fill_beat_q <= 3'd0;
                        state <= S_R;
                    end
                end
                S_R: begin
                    if (arvalid && arready)
                        arvalid <= 1'b0;
                    if (rvalid && rready) begin
                        pwc_fill_line <= pwc_fill_next;
                        if (rlast || fill_beat_q == 3'd7) begin
                            pwc_v[fill_way_q] <= 1'b1;
                            pwc_tag[fill_way_q] <= pte_addr_q[57:6];
                            pwc_replace <= pwc_replace + 1'b1;
                            rready <= 1'b0;
                            state <= S_AR;
                        end else begin
                            fill_beat_q <= fill_beat_q + 1'b1;
                        end
                    end
                end
                S_AD: begin
                    //  AXI: AW and W are accepted independently -- clear each on
                    //  its own handshake (a same-cycle-only clear can re-issue AW
                    //  to MIG/an interconnect). B arrives only after both land.
                    if (awvalid && awready) awvalid <= 1'b0;
                    if (wvalid  && wready)  wvalid  <= 1'b0;
                    if (bvalid && bready) begin
                        bready <= 1'b0;
                        finish_leaf(pte_new_q, level_q);
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    wire _unused = &{rid, rresp, bid, bresp, satp_q[0], 1'b0};
endmodule
