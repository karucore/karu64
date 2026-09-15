//  karu_sv39.v
//  Minimal Sv39 translator with a tiny fully-associative TLB and a small
//  page-table-line cache. Page tables live in external memory; this block
//  only caches translations and 64-byte aligned PTE lines. Svade is used:
//  software sets A/D, and the walker never writes page-table memory.
//  Svnapot 64 KiB leaves cache resolved 4 KiB subpages in the ordinary TLB.
//  Svpbmt leaf attributes accompany PA; physical access permissions still apply.
//  Guest requests use a registered VS/G-stage walk with exact PTE reads.
//  A separate four-entry combined guest TLB caches resolved 4 KiB subpages;
//  guest misses bypass the host TLB/PWC. HLVX retains load fault classes.

`include "karu_axi_defs.vh"

module karu_sv39 #(
    parameter TLB_ENTRIES = 4,
    parameter PWC_LINES = 4,
    parameter GUEST_TLB_ENABLE = 1 // elaboration-time uncached reference
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
    input  wire         pbmte,     // menvcfg.PBMTE enables Svpbmt interpretation
    input  wire         hlvx,      // load using execute permission at both stages
    input  wire         virt,      // effective V, including MPRV/MPV and HLV/HSV
    input  wire [63:0]  vsatp,
    input  wire [63:0]  hgatp,
    input  wire         vsstatus_sum,
    input  wire         vsstatus_mxr,
    input  wire         henvcfg_pbmte,
    input  wire         pte_read_safe, // older instructions/explicit memory drained
    input  wire         flush,
    input  wire         cancel,    // discard a redirect's request, preserve cached translations

    output reg          done,
    output reg          fault,
    output reg [63:0]   fault_va,
    output reg [63:0]   fault_cause,
    output reg          fault_gva,
    output reg          fault_gpa_valid,
    output reg [63:0]   fault_gpa,  // unshifted GPA; trap CSRs store GPA >> 2
    output reg [63:0]   fault_tinst,
    output reg          fault_gpa_is_pte,
    output reg [63:0]   pa,
    output reg [1:0]    pbmt,      // 00=PMA, 01=NC, 10=IO; zero on fault/Bare
    output wire         busy,
    output wire         pte_io_pending,

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

    output wire [`AXI_ID_W-1:0]     awid,
    output wire [`AXI_ADDR_W-1:0]   awaddr,
    output wire [`AXI_LEN_W-1:0]    awlen,
    output wire [`AXI_SIZE_W-1:0]   awsize,
    output wire [`AXI_BURST_W-1:0]  awburst,
    output wire [`AXI_PROT_W-1:0]   awprot,
    output wire                     awvalid,
    input  wire                     awready,
    output wire [`AXI_DATA_W-1:0]   wdata,
    output wire [`AXI_STRB_W-1:0]   wstrb,
    output wire                     wlast,
    output wire                     wvalid,
    input  wire                     wready,
    input  wire [`AXI_ID_W-1:0]     bid,
    input  wire [`AXI_RESP_W-1:0]   bresp,
    input  wire                     bvalid,
    output wire                     bready
);
    localparam [2:0] S_IDLE = 3'd0,
                     S_LOOK = 3'd1,
                     S_AR   = 3'd2,
                     S_R    = 3'd3,
                     S_GSTART = 3'd4,
                     S_VSTART = 3'd5,
                     S_GHIT = 3'd6;
    localparam [1:0] ST_HOST = 2'd0, ST_VS = 2'd1, ST_G = 2'd2;

    localparam [1:0] ACC_FETCH = 2'd0,
                     ACC_LOAD  = 2'd1,
                     ACC_STORE = 2'd2,
                     ACC_CBOCF = 2'd3;  //  Zicbom management: load OR store, store-class fault
    localparam [1:0] PRIV_U = 2'd0,
                     PRIV_S = 2'd1,
                     PRIV_M = 2'd3;

    reg [2:0]   state;
    reg [63:0]  va_q;
    reg [1:0]   access_q;
    reg [1:0]   priv_q;
    reg [63:0]  satp_q;
    reg         sum_q, mxr_q, pbmte_q;
    reg         virt_q, hlvx_q, vs_sum_q, vs_mxr_q, vs_pbmte_q;
    reg [63:0]  vsatp_q, hgatp_q;
    reg [1:0]   stage_q;
    reg [63:0]  gpa_q;
    reg         g_return_to_pte_q;
    reg [1:0]   vs_level_q, vs_leaf_pbmt_q, pte_pbmt_q;
    reg [7:0]   vs_leaf_perm_q;
    reg         exact_read_q;
    reg [1:0]   level_q;        //  2, 1, 0 while walking
    reg [43:0]  pt_ppn_q;
    reg [63:0]  pte_addr_q;
    reg [2:0]   fill_beat_q;
    //  A fence invalidates caches; a redirect only cancels this request.
    //  Both suppress subsequent PTE reads/fills and drain an asserted AR.
    reg         walk_poison;

    //  Same-cycle flush+completion must suppress fills immediately;
    //  waiting for the registered poison bit would be one cycle too late.
    wire        poison_eff = walk_poison || ((flush || cancel) && (state != S_IDLE));

    wire bare_mode = (priv == PRIV_M) || (satp[63:60] != 4'd8);
    wire va_canon = (va[63:39] == {25{va[38]}});
    wire [26:0] va_vpn = va[38:12];

    reg [TLB_ENTRIES-1:0]       tlb_v;
    reg [26:0]                  tlb_vpn [0:TLB_ENTRIES-1];
    reg [43:0]                  tlb_ppn [0:TLB_ENTRIES-1];
    reg [7:0]                   tlb_perm [0:TLB_ENTRIES-1];
    reg [1:0]                   tlb_level [0:TLB_ENTRIES-1];
    reg [1:0]                   tlb_pbmt [0:TLB_ENTRIES-1];
    //  Address-space tag: a TLB entry only matches when the current satp ASID
    //  and root PPN match the ones the entry was filled under. A VPN-only match
    //  would alias across address spaces when Linux switches ASIDs without
    //  sfence.vma.
    reg [15:0]                  tlb_asid [0:TLB_ENTRIES-1];
    reg [43:0]                  tlb_root [0:TLB_ENTRIES-1];
    reg [1:0]                   tlb_replace;

    // One guest context at a time avoids replicating wide root comparisons.
    // PBMTE is part of the key because it also affects G translations of
    // implicit VS-PTE reads: a change must rewalk to recover their exact
    // fault GPA/tinst, not merely recheck the final leaves' attributes.
    // HGATP[59:58] and PPN[1:0] are reserved/fixed zero, not context bits.
    wire [125:0] guest_context = {vsatp_q, hgatp_q[63:60], hgatp_q[57:2],
                                 pbmte_q, vs_pbmte_q};
    reg [125:0] gtlb_context;
    reg [3:0] gtlb_v;
    reg [28:0] gtlb_vpn [0:3];
    reg [43:0] gtlb_hppn [0:3], gtlb_gppn [0:3];
    reg [7:0] gtlb_vsperm [0:3], gtlb_gperm [0:3];
    reg [1:0] gtlb_vspbmt [0:3], gtlb_gpbmt [0:3];
    reg [1:0] gtlb_replace, gtlb_hit_i_q;
    wire gtlb_context_match = gtlb_context == guest_context;
    wire [1:0] gtlb_fill_i = gtlb_context_match ? gtlb_replace : 2'b00;
    // Shortened VPN tags are safe only after full address/mode validation.
    // Both Bare stages remain uncached and retain full-width PMA checks.
    wire guest_cache_addr_ok = (hgatp_q[63:60] == 0 || hgatp_q[63:60] == 8) &&
        ((vsatp_q[63:60] == 8 && va_q[63:39] == {25{va_q[38]}}) ||
         (vsatp_q[63:60] == 0 && hgatp_q[63:60] == 8 && va_q[63:41] == 0));
    reg gtlb_hit_raw;
    wire gtlb_hit = GUEST_TLB_ENABLE ? gtlb_hit_raw : 1'b0;
    reg [1:0] gtlb_hit_i;
    integer gi;
    always @(*) begin
        gtlb_hit_raw = 1'b0;
        gtlb_hit_i = 2'b00;
        for (gi = 0; gi < 4; gi = gi + 1) begin
            if (guest_cache_addr_ok && gtlb_context_match &&
                gtlb_v[gi] && gtlb_vpn[gi] == va_q[40:12] && !gtlb_hit_raw) begin
                gtlb_hit_raw = 1'b1;
                gtlb_hit_i = gi[1:0];
            end
        end
    end

    reg [PWC_LINES-1:0]         pwc_v;
    reg [57:6]                  pwc_tag [0:PWC_LINES-1];
    reg [511:0]                 pwc_fill_line;
    reg                         fill_error;
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
                // Svnapot's only ratified size replaces PPN[3:0] with
                // VPN[3:0]. Keep all physical bits until the PMA check.
                default: leaf_pa = pte[63] ? {8'b0, pte[53:14], a[15:0]} :
                                            {8'b0, pte[53:10], a[11:0]};
            endcase
        end
    endfunction

    function automatic [63:0] fault_code(input [1:0] acc);
        begin
            fault_code = (acc == ACC_FETCH) ? 64'd12 :
                         (acc == ACC_LOAD)  ? 64'd13 : 64'd15;
        end
    endfunction

    function automatic pbmt_invalid(input [1:0] attr, input enabled);
        pbmt_invalid = (attr == 2'b11) || (!enabled && attr != 2'b00);
    endfunction

    function automatic pte_invalid(input [63:0] pte, input [1:0] lvl, input enabled_pbmt);
        begin
            //  Svnapot v1.0 permits only level-0 N=1, PPN[3:0]=1000
            //  (64 KiB). Svpbmt permits 00/01/10 on leaves when enabled;
            //  reserved[60:54] and all non-leaf PBMT fields must be zero.
            //  Non-leaf U/A/D are reserved, unlike G and software-owned RSW.
            pte_invalid = !pte[0] || (!pte[1] && pte[2]) ||
                          (pte[60:54] != 7'b0) || pbmt_invalid(pte[62:61], enabled_pbmt) ||
                          (pte[63] && (lvl != 0 || pte[13:10] != 4'b1000)) ||
                          (!pte[1] && !pte[3] &&
                           (pte[63] || pte[62:61] != 0 || pte[7] || pte[6] || pte[4]));
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
        input mxr,
        input use_x
    );
        reg ok;
        begin
            ok = (acc == ACC_FETCH) ? perm[3] :
                 (acc == ACC_LOAD)  ? (use_x ? perm[3] : (perm[1] || (mxr && perm[3]))) :
                 // Zicbom permits management whenever a load or store is
                 // permitted, including an executable page made readable by MXR.
                 (acc == ACC_CBOCF) ? (perm[1] || perm[2] || (mxr && perm[3])) :
                                      perm[2];
            if (prv == PRIV_U)
                ok = ok && perm[4];
            else if (prv == PRIV_S && perm[4])
                ok = ok && (acc != ACC_FETCH) && sum;
            //  Svade applies on TLB hits too: a load may cache A=1,D=0,
            //  but a subsequent store must still fault until software sets D
            //  and executes the required translation invalidation. CBO
            //  management (including INVAL) requires A but never checks D.
            perm_fault = !ok || !perm[6] || (acc == ACC_STORE && !perm[7]);
        end
    endfunction

    reg tlb_hit;
    reg [1:0] tlb_hit_i;
    reg pwc_hit;
    reg [1:0] pwc_hit_i;
    reg [63:0] pte_from_cache;
    wire [511:0] pwc_hit_line;
    wire [511:0] pwc_fill_next = line_put(pwc_fill_line, fill_beat_q, rdata);
    wire         pwc_data_we = (state == S_R) && !exact_read_q &&
                               rvalid && rready && !poison_eff;

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

    task automatic clear_guest_fault;
        begin
            fault_gva <= 1'b0;
            fault_gpa_valid <= 1'b0;
            fault_gpa <= 64'b0;
            fault_tinst <= 64'b0;
            fault_gpa_is_pte <= 1'b0;
        end
    endtask

    task automatic raise_fault;
        begin
            done <= 1'b1;
            fault <= 1'b1;
            pbmt <= 2'b00;
            fault_va <= va_q;
            fault_cause <= fault_code(access_q) + (stage_q == ST_G ? 64'd8 : 64'd0);
            fault_gva <= virt_q;
            fault_gpa_valid <= stage_q == ST_G;
            fault_gpa <= stage_q == ST_G ? gpa_q : 64'b0;
            fault_gpa_is_pte <= stage_q == ST_G && g_return_to_pte_q;
            // RV64 implicit VS page-table read, not a transformed explicit
            // instruction. Final-address guest faults may report tinst=0.
            fault_tinst <= stage_q == ST_G && g_return_to_pte_q ? 64'h3000 : 64'b0;
            if (poison_eff) begin
                walk_poison <= 1'b0;
            end
            state <= S_IDLE;
        end
    endtask

    `include "karu_pma.vh"

    // TLB entries contain resolved PPNs, including 4 KiB NAPOT subpages.
    wire [63:0] tlb_hit_pa = leaf_pa(va, {10'b0, tlb_ppn[tlb_hit_i], 10'b0}, tlb_level[tlb_hit_i]);
    wire tlb_hit_pma_ok = karu_pma_ok(tlb_hit_pa, access) &&
                         (!hlvx || karu_pma_ok(tlb_hit_pa, ACC_FETCH));
    wire pte_is_io = pte_pbmt_q == 2'b10 ||
                    (pte_pbmt_q == 2'b00 && karu_pma_io(pte_addr_q));
    // Only standard-map DRAM supports a PWC line burst. Boot ROM and
    // scratch SRAM are readable PMA regions but have single-beat slaves.
    // PMA validation below still checks the full PA before AXI truncation.
    wire exact_pte_read = virt_q || pte_is_io || !pte_addr_q[31];
    assign pte_io_pending = (state == S_AR || state == S_R) && pte_is_io;

    wire [63:0] guest_hit_pa = {8'b0, gtlb_hppn[gtlb_hit_i_q], va_q[11:0]};
    wire [63:0] guest_hit_gpa = {8'b0, gtlb_gppn[gtlb_hit_i_q], va_q[11:0]};
    wire guest_hit_vs_fault = vsatp_q[63:60] != 0 &&
        (pbmt_invalid(gtlb_vspbmt[gtlb_hit_i_q], vs_pbmte_q) ||
         perm_fault(gtlb_vsperm[gtlb_hit_i_q], access_q, priv_q,
                    vs_sum_q, mxr_q || vs_mxr_q, hlvx_q));
    wire guest_hit_g_fault = hgatp_q[63:60] != 0 &&
        (pbmt_invalid(gtlb_gpbmt[gtlb_hit_i_q], pbmte_q) ||
         perm_fault(gtlb_gperm[gtlb_hit_i_q], access_q, PRIV_U, 1'b0, mxr_q, hlvx_q));
    wire guest_hit_pma_fault = !karu_pma_ok(guest_hit_pa, access_q) ||
                               (hlvx_q && !karu_pma_ok(guest_hit_pa, ACC_FETCH));
    wire guest_hit_fault = guest_hit_vs_fault || guest_hit_g_fault || guest_hit_pma_fault;

    task automatic raise_access_fault;
        begin
            raise_fault();
            fault_cause <= (access_q == ACC_FETCH) ? 64'd1 :
                           (access_q == ACC_LOAD) ? 64'd5 : 64'd7;
            // A physical failure (including a page-table read) is an access
            // fault, not a G-stage translation failure; no GPA is promised.
            fault_gpa_valid <= 1'b0;
            fault_gpa <= 64'b0;
            fault_tinst <= 64'b0;
            fault_gpa_is_pte <= 1'b0;
        end
    endtask

    //  The requester discards the canceled translation on its flush/redirect.
    //  Drain an already accepted AXI read first, then release busy without
    //  publishing a fault or any translation-cache entry from the old walk.
    task automatic cancel_walk;
        begin
            done <= 1'b1;
            fault <= 1'b0;
            pbmt <= 2'b00;
            pa <= 64'b0;
            fault_va <= 64'b0;
            fault_cause <= 64'b0;
            clear_guest_fault();
            walk_poison <= 1'b0;
            state <= S_IDLE;
        end
    endtask

    // Complete either a G-translated VS-PTE address or the final translation.
    // Intermediate GPAs must not be subjected to host physical-map checks.
    task automatic finish_g(input [63:0] result_pa, input [1:0] result_pbmt,
                            input [7:0] result_perm);
        begin
            if (g_return_to_pte_q) begin
                pte_addr_q <= result_pa;
                pte_pbmt_q <= result_pbmt;
                stage_q <= ST_VS;
                level_q <= vs_level_q;
                state <= S_AR;
            end else if (!karu_pma_ok(result_pa, access_q) ||
                         (hlvx_q && !karu_pma_ok(result_pa, ACC_FETCH))) begin
                raise_access_fault();
            end else begin
                pa <= result_pa;
                // The VS-stage attribute overrides the G-stage attribute
                // only when nonzero; a Bare stage contributes PBMT=PMA.
                pbmt <= vs_leaf_pbmt_q != 0 ? vs_leaf_pbmt_q : result_pbmt;
                done <= 1'b1;
                fault <= 1'b0;
                clear_guest_fault();
                if (GUEST_TLB_ENABLE && !poison_eff && guest_cache_addr_ok) begin
                    // Retarget only on successful final completion. A miss
                    // that faults or is canceled preserves the old context.
                    if (!gtlb_context_match) gtlb_v <= 4'b0001;
                    else gtlb_v[gtlb_fill_i] <= 1'b1;
                    gtlb_context <= guest_context;
                    gtlb_vpn[gtlb_fill_i] <= va_q[40:12];
                    gtlb_hppn[gtlb_fill_i] <= result_pa[55:12];
                    gtlb_gppn[gtlb_fill_i] <= gpa_q[55:12];
                    gtlb_vsperm[gtlb_fill_i] <= vs_leaf_perm_q;
                    gtlb_gperm[gtlb_fill_i] <= result_perm;
                    gtlb_vspbmt[gtlb_fill_i] <= vs_leaf_pbmt_q;
                    gtlb_gpbmt[gtlb_fill_i] <= result_pbmt;
                    gtlb_replace <= gtlb_fill_i + 1'b1;
                end
                state <= S_IDLE;
            end
        end
    endtask

    task automatic finish_leaf(input [63:0] pte, input [1:0] lvl);
        reg [63:0] pa_w;
        begin
            if (poison_eff) begin
                cancel_walk();
            end else if (superpage_bad(pte, lvl)) begin
                raise_fault();
            end else if (stage_q == ST_G) begin
                // G-stage accesses always require U. An implicit VS-PTE
                // read requires genuine R (neither MXR nor HLVX applies),
                // while its eventual fault class still describes access_q.
                if (perm_fault(pte[7:0], g_return_to_pte_q ? ACC_LOAD : access_q,
                               PRIV_U, 1'b0, g_return_to_pte_q ? 1'b0 : mxr_q,
                               !g_return_to_pte_q && hlvx_q))
                    raise_fault();
                else finish_g(leaf_pa(gpa_q, pte, lvl), pte[62:61], pte[7:0]);
            end else if (stage_q == ST_VS) begin
                if (perm_fault(pte[7:0], access_q, priv_q, vs_sum_q,
                               mxr_q || vs_mxr_q, hlvx_q)) begin
                    raise_fault();
                end else begin
                    gpa_q <= leaf_pa(va_q, pte, lvl);
                    vs_leaf_pbmt_q <= pte[62:61];
                    vs_leaf_perm_q <= pte[7:0];
                    g_return_to_pte_q <= 1'b0;
                    stage_q <= ST_G;
                    state <= S_GSTART;
                end
            end else if (perm_fault(pte[7:0], access_q, priv_q, sum_q, mxr_q, hlvx_q)) begin
                raise_fault();
            end else if (!karu_pma_ok(leaf_pa(va_q, pte, lvl), access_q) ||
                         (hlvx_q && !karu_pma_ok(leaf_pa(va_q, pte, lvl), ACC_FETCH))) begin
                raise_access_fault();
            end else begin
                pa_w = leaf_pa(va_q, pte, lvl);
                pa <= pa_w;
                pbmt <= pte[62:61];
                done <= 1'b1;
                fault <= 1'b0;
                clear_guest_fault();
                tlb_v[tlb_replace] <= 1'b1;
                tlb_vpn[tlb_replace] <= va_q[38:12];
                tlb_ppn[tlb_replace] <= pa_w[55:12];
                tlb_perm[tlb_replace] <= pte[7:0];
                tlb_level[tlb_replace] <= lvl;
                tlb_pbmt[tlb_replace] <= pte[62:61];
                tlb_asid[tlb_replace] <= satp_q[59:44];
                tlb_root[tlb_replace] <= satp_q[43:0];
                tlb_replace <= tlb_replace + 1'b1;
                state <= S_IDLE;
            end
        end
    endtask

    task automatic consume_pte(input [63:0] pte);
        begin
            if (pte_invalid(pte, level_q, stage_q == ST_VS ? vs_pbmte_q : pbmte_q)) begin
                raise_fault();
            end else if (pte_leaf(pte)) begin
                finish_leaf(pte, level_q);
            end else if (level_q == 2'd0) begin
                raise_fault();
            end else begin
                pt_ppn_q <= pte[53:10];
                level_q <= level_q - 1'b1;
                state <= S_LOOK;
            end
        end
    endtask

    assign busy = (state != S_IDLE);

    //  Preserve the shared walker interface; Svadu hardware PTE updates are
    //  not implemented, and no transaction may reach these write channels.
    assign awid = 0;
    assign awaddr = 0;
    assign awlen = 0;
    assign awsize = `AXI_SIZE_8B;
    assign awburst = `AXI_BURST_INCR;
    assign awprot = 0;
    assign awvalid = 1'b0;
    assign wdata = 0;
    assign wstrb = 0;
    assign wlast = 1'b0;
    assign wvalid = 1'b0;
    assign bready = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done <= 1'b0;
            fault <= 1'b0;
            pbmt <= 2'b00;
            pa <= 64'b0;
            fault_va <= 64'b0;
            fault_cause <= 64'b0;
            clear_guest_fault();
            virt_q <= 1'b0;
            hlvx_q <= 1'b0;
            stage_q <= ST_HOST;
            pte_pbmt_q <= 2'b00;
            exact_read_q <= 1'b0;
            arvalid <= 1'b0;
            rready <= 1'b0;
            tlb_v <= {TLB_ENTRIES{1'b0}};
            pwc_v <= {PWC_LINES{1'b0}};
            gtlb_v <= 4'b0;
            gtlb_context <= 126'b0;
            gtlb_replace <= 2'b0;
            gtlb_hit_i_q <= 2'b0;
            tlb_replace <= 0;
            pwc_replace <= 0;
            walk_poison <= 1'b0;
        end else begin
            done <= 1'b0;
            if (flush) begin
                tlb_v <= {TLB_ENTRIES{1'b0}};
                pwc_v <= {PWC_LINES{1'b0}};
                gtlb_v <= 4'b0;
            end
            if ((flush || cancel) && state != S_IDLE)
                walk_poison <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (req) begin
                        va_q <= va;
                        access_q <= access;
                        priv_q <= priv;
                        satp_q <= satp;
                        sum_q <= status_sum;
                        mxr_q <= status_mxr;
                        pbmte_q <= pbmte;
                        virt_q <= virt;
                        hlvx_q <= hlvx;
                        vsatp_q <= vsatp;
                        hgatp_q <= hgatp;
                        vs_sum_q <= vsstatus_sum;
                        vs_mxr_q <= vsstatus_mxr;
                        vs_pbmte_q <= henvcfg_pbmte;
                        vs_leaf_pbmt_q <= 2'b00;
                        vs_leaf_perm_q <= 8'b0;
                        pte_pbmt_q <= 2'b00;
                        stage_q <= virt ? ST_VS : ST_HOST;
                        pbmt <= 2'b00;
                        fault <= 1'b0;
                        clear_guest_fault();
                        if (cancel) begin
                            // The requester may have latched its outstanding
                            // flag on this edge; provide a completion to drain
                            // that handshake without launching a stale walk.
                            done <= 1'b1;
                            pa <= 64'b0;
                            fault_va <= 64'b0;
                            fault_cause <= 64'b0;
                            walk_poison <= 1'b0;
                        end else if (virt) begin
                            state <= S_VSTART;
                        end else if (bare_mode) begin
                            pa <= va;
                            done <= 1'b1;
                            fault <= !karu_pma_ok(va, access) ||
                                     (hlvx && !karu_pma_ok(va, ACC_FETCH));
                            fault_va <= va;
                            fault_cause <= (access == ACC_FETCH) ? 64'd1 :
                                           (access == ACC_LOAD) ? 64'd5 : 64'd7;
                        end else if (!va_canon) begin
                            done <= 1'b1;
                            fault <= 1'b1;
                            fault_va <= va;
                            fault_cause <= fault_code(access);
                        end else if (tlb_hit && !flush) begin
                            if (pbmt_invalid(tlb_pbmt[tlb_hit_i], pbmte) ||
                                perm_fault(tlb_perm[tlb_hit_i], access, priv, status_sum, status_mxr, hlvx)) begin
                                done <= 1'b1;
                                fault <= 1'b1;
                                fault_va <= va;
                                fault_cause <= fault_code(access);
                            end else begin
                                pa <= tlb_hit_pa;
                                pbmt <= tlb_hit_pma_ok ? tlb_pbmt[tlb_hit_i] : 2'b00;
                                done <= 1'b1;
                                fault <= !tlb_hit_pma_ok;
                                // Permission is physical, independent of TLB
                                // page size; a superpage may span PMA regions.
                                fault_va <= va;
                                fault_cause <= (access == ACC_FETCH) ? 64'd1 :
                                               (access == ACC_LOAD) ? 64'd5 : 64'd7;
                            end
                        end else begin
                            level_q <= 2'd2;
                            pt_ppn_q <= satp[43:0];
                            state <= S_LOOK;
                        end
                    end
                end
                S_VSTART: begin
                    if (poison_eff) begin
                        cancel_walk();
                    end else if (gtlb_hit) begin
                        // Root/VPN lookup and selected-entry permission/PMA
                        // evaluation occupy separate registered intervals.
                        gtlb_hit_i_q <= gtlb_hit_i;
                        state <= S_GHIT;
                    end else if (vsatp_q[63:60] == 0) begin
                        gpa_q <= va_q;
                        g_return_to_pte_q <= 1'b0;
                        stage_q <= ST_G;
                        state <= S_GSTART;
                    end else if (vsatp_q[63:60] != 8 ||
                                 va_q[63:39] != {25{va_q[38]}}) begin
                        raise_fault();
                    end else begin
                        level_q <= 2'd2;
                        pt_ppn_q <= vsatp_q[43:0];
                        state <= S_LOOK;
                    end
                end
                S_GHIT: begin
                    if (poison_eff) begin
                        cancel_walk();
                    end else begin
                        done <= 1'b1;
                        fault <= guest_hit_fault;
                        pa <= guest_hit_fault ? 64'b0 : guest_hit_pa;
                        pbmt <= guest_hit_fault ? 2'b0 :
                            gtlb_vspbmt[gtlb_hit_i_q] != 0 ? gtlb_vspbmt[gtlb_hit_i_q] :
                                                           gtlb_gpbmt[gtlb_hit_i_q];
                        fault_va <= va_q;
                        // Use explicit hit metadata, not stage_q/gpa_q from
                        // an earlier walk. VS faults take priority over G.
                        fault_cause <= guest_hit_vs_fault ? fault_code(access_q) :
                            guest_hit_g_fault ? fault_code(access_q) + 64'd8 :
                            guest_hit_pma_fault ? ((access_q == ACC_FETCH) ? 64'd1 :
                                (access_q == ACC_LOAD) ? 64'd5 : 64'd7) : 64'b0;
                        fault_gva <= guest_hit_fault;
                        fault_gpa_valid <= !guest_hit_vs_fault && guest_hit_g_fault;
                        fault_gpa <= !guest_hit_vs_fault && guest_hit_g_fault ? guest_hit_gpa : 64'b0;
                        fault_gpa_is_pte <= 1'b0;
                        fault_tinst <= 64'b0;
                        state <= S_IDLE;
                    end
                end
                S_GSTART: begin
                    if (poison_eff) begin
                        cancel_walk();
                    end else if (hgatp_q[63:60] == 0) begin
                        finish_g(gpa_q, 2'b00, 8'b0);
                    end else if (hgatp_q[63:60] != 8 || gpa_q[63:41] != 0) begin
                        raise_fault();
                    end else begin
                        level_q <= 2'd2;
                        pt_ppn_q <= {hgatp_q[43:2], 2'b0};
                        state <= S_LOOK;
                    end
                end
                S_LOOK: begin
                    if (poison_eff) begin
                        cancel_walk();
                    end else if (stage_q == ST_VS) begin
                        // Suspend only the VS level: after the translated
                        // PTE arrives it supplies either a new PPN or a leaf.
                        gpa_q <= {8'b0, pt_ppn_q, 12'b0} +
                                 {52'b0, vpn_i(va_q, level_q), 3'b0};
                        vs_level_q <= level_q;
                        g_return_to_pte_q <= 1'b1;
                        stage_q <= ST_G;
                        state <= S_GSTART;
                    end else begin
                        if (stage_q == ST_G && level_q == 2)
                            pte_addr_q <= {8'b0, pt_ppn_q[43:2], gpa_q[40:30], 3'b0};
                        else pte_addr_q <= {8'b0, pt_ppn_q, 12'b0} +
                            {52'b0, vpn_i(stage_q == ST_G ? gpa_q : va_q, level_q), 3'b0};
                        pte_pbmt_q <= 2'b00;
                        state <= S_AR;
                    end
                end
                S_AR: begin
                    if (poison_eff) begin
                        cancel_walk();
                    end else if (!karu_pma_ok(pte_addr_q, 2'd1)) begin
                        raise_access_fault();
                    end else if (pwc_hit && !exact_pte_read) begin
                        consume_pte(pte_from_cache);
                    end else if (!pte_is_io || pte_read_safe) begin
                        exact_read_q <= exact_pte_read;
                        fill_way_q <= pwc_replace;
                        pwc_fill_line <= 512'b0;
                        fill_error <= 0;
                        if (!exact_pte_read) pwc_v[pwc_replace] <= 0;
                        araddr <= exact_pte_read ? pte_addr_q[`AXI_ADDR_W-1:0] :
                                                 {pte_addr_q[`AXI_ADDR_W-1:6], 6'b0};
                        arid <= 0;
                        arlen <= exact_pte_read ? 8'd0 : 8'd7;
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
                        if (exact_read_q) begin
                            rready <= 1'b0;
                            if (poison_eff) cancel_walk();
                            else if (rresp[1]) raise_access_fault();
                            else consume_pte(rdata);
                        end else if (rlast || fill_beat_q == 3'd7) begin
                            // Never publish a partial line after early RLAST
                            // (or a final beat without RLAST).
                            pwc_v[fill_way_q] <= !(fill_error || rresp[1] || poison_eff ||
                                                  !rlast || fill_beat_q != 3'd7);
                            pwc_tag[fill_way_q] <= pte_addr_q[57:6];
                            pwc_replace <= pwc_replace + 1'b1;
                            rready <= 1'b0;
                            state <= S_AR;
                            if (poison_eff) cancel_walk();
                            else if (fill_error || rresp[1] || !rlast || fill_beat_q != 3'd7)
                                raise_access_fault();
                        end else begin
                            fill_beat_q <= fill_beat_q + 1'b1;
                        end
                        if (!exact_read_q) begin
                            pwc_fill_line <= pwc_fill_next;
                            fill_error <= fill_error || rresp[1];
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    wire _unused = &{rid, bid, awready, wready, bresp, bvalid, satp_q[0], 1'b0};
endmodule
