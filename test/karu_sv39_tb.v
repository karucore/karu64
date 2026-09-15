// Sv39/Svade/Svnapot/Svpbmt walker regression. Firmware covers architectural traps;
// this bench additionally observes AXI write suppression, PTE read errors,
// TLB hits and flushes at individual outstanding-walk phases.
`timescale 1ns/1ps
`include "karu_axi_defs.vh"

module karu_sv39_tb #(
    parameter GUEST_TLB_ENABLE = 1,
    parameter STOP_ON_FINISH = 1
) (
    output reg finished = 0,
    output reg [63:0] result_signature = 0,
    output reg [31:0] result_count = 0
);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, req = 0, flush = 0, cancel = 0, flush_on_req = 0;
    reg [63:0] va = 64'h45678;
    reg [1:0] access = 1, priv = 1;
    reg [63:0] satp = 64'h8000000000080002;
    reg status_sum = 0, status_mxr = 0;
    reg pbmte = 0;
    reg hlvx = 0, virt = 0, vsstatus_sum = 0, vsstatus_mxr = 0;
    reg henvcfg_pbmte = 0, pte_read_safe = 1;
    reg [63:0] vsatp = 0, hgatp = 0;
    wire fault_gva, fault_gpa_valid, fault_gpa_is_pte, pte_io_pending;
    wire [63:0] fault_gpa, fault_tinst;
    wire done, fault, busy;
    wire [1:0] pbmt;
    wire [63:0] fault_va, fault_cause, pa;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire arvalid, arready, rready;
    wire awvalid, wvalid, bready;
    wire [63:0] rdata;
    wire [1:0] rresp;
    wire rvalid, rlast;

    karu_sv39 #(.GUEST_TLB_ENABLE(GUEST_TLB_ENABLE)) dut (
        .clk(clk), .rst(rst), .req(req), .va(va), .access(access),
        .priv(priv), .satp(satp), .status_sum(status_sum),
        .status_mxr(status_mxr), .pbmte(pbmte), .pbmt(pbmt), .flush(flush),
        .cancel(cancel), .done(done),
        .hlvx(hlvx), .virt(virt), .vsatp(vsatp), .hgatp(hgatp),
        .vsstatus_sum(vsstatus_sum), .vsstatus_mxr(vsstatus_mxr),
        .henvcfg_pbmte(henvcfg_pbmte), .pte_read_safe(pte_read_safe),
        .pte_io_pending(pte_io_pending), .fault_gva(fault_gva),
        .fault_gpa_valid(fault_gpa_valid), .fault_gpa(fault_gpa),
        .fault_tinst(fault_tinst), .fault_gpa_is_pte(fault_gpa_is_pte),
        .fault(fault), .fault_va(fault_va), .fault_cause(fault_cause),
        .pa(pa), .busy(busy), .arid(), .araddr(araddr), .arlen(arlen),
        .arsize(arsize), .arburst(), .arprot(), .arvalid(arvalid),
        .arready(arready), .rid(4'b0), .rdata(rdata), .rresp(rresp),
        .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .awid(), .awaddr(), .awlen(), .awsize(), .awburst(), .awprot(),
        .awvalid(awvalid), .awready(1'b1), .wdata(), .wstrb(), .wlast(),
        .wvalid(wvalid), .wready(1'b1), .bid(4'b0), .bresp(2'b0),
        .bvalid(1'b0), .bready(bready)
    );

    localparam [63:0] ROOT = 64'h80002000, L1 = 64'h80003000,
                      L0 = 64'h80004000, FRAME = 64'h80008000,
                      NAPOT_FRAME = 64'h80010000, PTE_N = 64'h8000000000000000;
    localparam integer ROOT_I = 'h2000 >> 3, L1_I = 'h3000 >> 3,
                       LEAF_I = ('h4000 >> 3) + 'h45;
    localparam [63:0] GROOT = 64'h8000c000, GL1 = 64'h80005000,
                      GL0 = 64'h80006000, GBASE = 64'h40000000;
    localparam integer GROOT_I = 'hc000 >> 3, GL1_I = 'h5000 >> 3,
                       GL0_I = 'h6000 >> 3;
    reg [63:0] mem [0:8191];
    reg read_active = 0;
    reg stall_ar = 0;
    reg [31:0] read_base;
    reg [2:0] read_beat;
    reg [2:0] read_len;
    reg [31:0] error_line = 32'hffffffff;
    reg [2:0] error_beat = 0;
    reg [31:0] early_last_line = 32'hffffffff;
    reg [2:0] early_last_beat = 0;
    reg [31:0] missing_last_line = 32'hffffffff;
    integer cycles = 0, reads = 0, checks = 0, single_reads = 0, io_reads = 0;
    integer last_translation_cycles = 0;
    reg signature_enable = 1;
    assign arready = !stall_ar && !read_active && cycles[1:0] != 1;
    assign rvalid = read_active && cycles[1:0] != 0;
    assign rlast = read_base != missing_last_line &&
                   (read_beat == read_len ||
                    (read_base == early_last_line && read_beat == early_last_beat));
    assign rdata = mem[read_base[15:3] + {10'b0, read_beat}];
    assign rresp = read_base == error_line && read_beat == error_beat ? 2'b10 : 2'b00;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (rst) begin
            read_active <= 0;
        end else begin
            if (awvalid || wvalid || bready)
                $fatal(1, "Svade emitted a page-table write at cycle %0d", cycles);
            if (done && fault && pbmt !== 0)
                $fatal(1, "fault completion retained PBMT=%b", pbmt);
            if (arvalid && arready) begin
                if ((arlen != 7 && arlen != 0) || arsize != 3 || araddr[2:0] != 0 ||
                    (arlen == 7 && araddr[5:0] != 0))
                    $fatal(1, "bad PTE line read");
                if (virt && arlen != 0) $fatal(1, "guest PTE read touched adjacent entries");
                if (pte_io_pending && arlen != 0) $fatal(1, "IO PTE read was not exact");
                if (!araddr[31] && arlen != 0)
                    $fatal(1, "local ROM/scratch PTE read was not single-beat");
                read_active <= 1;
                read_base <= araddr;
                read_beat <= 0;
                read_len <= arlen[2:0];
                reads <= reads + 1;
                if (arlen == 0) single_reads <= single_reads + 1;
                if (pte_io_pending) io_reads <= io_reads + 1;
            end
            if (rvalid && rready) begin
                if (rlast || read_beat == read_len) read_active <= 0;
                else read_beat <= read_beat + 1'b1;
            end
        end
        if (cycles > 2000000) $fatal(1, "global timeout");
    end

    function automatic [63:0] pte(input [63:0] addr, input [63:0] flags);
        pte = ((addr >> 12) << 10) | flags;
    endfunction

    task automatic invalidate;
        begin
            @(negedge clk); flush = 1;
            @(posedge clk); #1;
            @(negedge clk); flush = 0;
        end
    endtask

    task automatic guest_hot_translate(input [1:0] acc, input [1:0] prv,
                                        input sum, input mxr, input integer cause,
                                        input [63:0] want_pa, input [1:0] want_pbmt = 0,
                                        input [63:0] want_gpa = 0);
        integer start_reads;
        begin
            start_reads = reads;
            guest_translate(acc, prv, sum, mxr, cause, want_pa, want_pbmt, want_gpa);
            if (GUEST_TLB_ENABLE && (reads != start_reads || last_translation_cycles != 2))
                $fatal(1, "hot guest request walked or exceeded registered-hit budget check=%0d reads=%0d cycles=%0d",
                    checks-1, reads-start_reads, last_translation_cycles);
            if (!GUEST_TLB_ENABLE && reads == start_reads)
                $fatal(1, "uncached guest reference unexpectedly skipped page tables");
        end
    endtask

    // Target the registered lookup/hit independently of cold-walk latency.
    // The disabled reference uses its pre-read G-start phase for hit-stage
    // cancellation: cycle-exact cancellation cannot be compared across a hit
    // and a much longer walk, but both must honor their accepted cancellation.
    task automatic guest_cancel_hot(input integer phase, input fence_it = 0,
                                    input change_context = 0);
        integer n, start_reads, actual_phase;
        reg [3:0] saved_guest, saved_host, saved_pwc;
        reg [125:0] saved_context;
        reg [63:0] saved_vsatp;
        begin
            guest_with_host_cache();
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            saved_guest = dut.gtlb_v; saved_context = dut.gtlb_context;
            saved_host = dut.tlb_v; saved_pwc = dut.pwc_v; saved_vsatp = vsatp;
            if (change_context) vsatp = vsatp ^ (64'b1 << 44);
            start_reads = reads;
            actual_phase = phase == 6 && !GUEST_TLB_ENABLE ? 4 : phase;
            @(negedge clk); req = 1;
            if (phase == 0) cancel = 1;
            @(posedge clk); #1; req = 0;
            if (phase != 0) begin
                n = 0;
                while (dut.state != actual_phase && n < 128) begin @(negedge clk); n = n + 1; end
                if (n == 128) $fatal(1, "guest hot cancellation phase not reached");
                cancel = !fence_it; flush = fence_it;
                @(posedge clk); #1;
            end
            @(negedge clk); cancel = 0; flush = 0;
            if (!done || busy || fault || pbmt || fault_gva || fault_gpa_valid ||
                fault_gpa || fault_tinst || fault_gpa_is_pte || reads != start_reads ||
                dut.gtlb_v != (fence_it ? 4'b0 : saved_guest) ||
                (!fence_it && dut.gtlb_context != saved_context) ||
                dut.tlb_v != (fence_it ? 4'b0 : saved_host) ||
                dut.pwc_v != (fence_it ? 4'b0 : saved_pwc))
                $fatal(1, "guest hot cancellation/fence damaged cache state phase=%0d", phase);
            checks = checks + 1;
            vsatp = saved_vsatp;
            if (fence_it) guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            else guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        end
    endtask

    task automatic guest_cancel_context_fill(input fence_it);
        integer n, start_reads;
        reg [3:0] saved_guest;
        reg [125:0] saved_context;
        reg [63:0] saved_vsatp;
        begin
            guest_mapping(1, 1, 'hcf, 'hdf);
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            saved_guest = dut.gtlb_v; saved_context = dut.gtlb_context;
            saved_vsatp = vsatp; vsatp = vsatp ^ (64'b1 << 44);
            start_reads = reads;
            @(negedge clk); req = 1;
            @(posedge clk); #1; req = 0;
            n = 0;
            while (!(read_active && reads == start_reads + 15 && rvalid) && n < 512) begin
                @(negedge clk); n = n + 1;
            end
            if (n == 512) $fatal(1, "guest replacement fill phase not reached");
            flush = fence_it; cancel = !fence_it;
            @(posedge clk); #1;
            @(negedge clk); flush = 0; cancel = 0;
            if (busy || !done || fault || pbmt || fault_gva || fault_gpa_valid || fault_gpa ||
                fault_tinst || fault_gpa_is_pte || dut.gtlb_v != (fence_it ? 0 : saved_guest) ||
                (!fence_it && dut.gtlb_context != saved_context) || reads != start_reads + 15)
                $fatal(1, "canceled final fill published a new guest context");
            checks = checks + 1;
            vsatp = saved_vsatp;
            if (fence_it) guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            else guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        end
    endtask

    task automatic guest_flush_phase(input integer phase, input integer walk_stage,
                                     input cancel_only = 0);
        integer n, start_reads;
        reg [3:0] keep_tlb, keep_pwc;
        begin
            if (cancel_only) guest_with_host_cache();
            else guest_mapping(1, 1, 'hcf, 'hdf);
            keep_tlb = cancel_only ? dut.tlb_v : 4'b0;
            keep_pwc = cancel_only ? dut.pwc_v : 4'b0;
            @(negedge clk); req = 1; access = 1; priv = 1;
            @(posedge clk); #1; req = 0;
            n = 0;
            while (!(dut.state == phase && dut.stage_q == walk_stage) && n < 512) begin
                @(negedge clk); n = n + 1;
            end
            if (n == 512) $fatal(1, "guest phase %0d/%0d not reached", phase, walk_stage);
            start_reads = reads;
            flush = !cancel_only; cancel = cancel_only;
            @(posedge clk); #1;
            @(negedge clk); flush = 0; cancel = 0;
            n = 0;
            while (busy && n < 512) begin @(posedge clk); #1; n = n + 1; end
            if (busy || fault || pbmt || fault_gva || fault_gpa_valid || fault_gpa ||
                fault_tinst || fault_gpa_is_pte || dut.tlb_v != keep_tlb ||
                dut.pwc_v != keep_pwc || dut.gtlb_v != 0 || reads != start_reads)
                $fatal(1, "guest phase flush failed %0d/%0d", phase, walk_stage);
            checks = checks + 1;
        end
    endtask

    task automatic guest_with_host_cache;
        begin
            virt = 0; hlvx = 0; va = 'h45678; satp = 64'h8000000000080002;
            mapping(0, 'hcf);
            translate(1, 1, 0, 0, 0, FRAME + 'h678);
            guest_mapping(1, 1, 'hcf, 'hdf, 0);
        end
    endtask

    // Nonidentity guest map: GPA 0x4000xxxx -> HPA 0x8000xxxx, including
    // all three VS page-table pages. Distinct VS/G roots catch root reuse.
    task automatic guest_mapping(input vs_on, input g_on,
                                  input [63:0] vsflags, input [63:0] gflags,
                                  input flush_first = 1);
        integer j;
        begin
            if (flush_first) invalidate();
            virt = 1; hlvx = 0; vsstatus_sum = 0; vsstatus_mxr = 0;
            pbmte = 1; henvcfg_pbmte = 1;
            vsatp = vs_on ? 64'h8000000000000000 |
                ((g_on ? GBASE + 'h2000 : ROOT) >> 12) : 0;
            hgatp = g_on ? 64'h8000000000000000 | (GROOT >> 12) : 0;
            va = vs_on ? 'h45678 : g_on ? GBASE + 'h8678 : FRAME + 'h678;
            mem[ROOT_I] = pte(g_on ? GBASE + 'h3000 : L1, 1);
            mem[L1_I] = pte(g_on ? GBASE + 'h4000 : L0, 1);
            mem[LEAF_I] = pte(g_on ? GBASE + 'h8000 : FRAME, vsflags);
            for (j = 0; j < 2048; j = j + 1) mem[GROOT_I + j] = 0;
            mem[GROOT_I + 1] = pte(GL1, 1);
            mem[GL1_I] = pte(GL0, 1);
            for (j = 0; j < 32; j = j + 1)
                mem[GL0_I + j] = pte(64'h80000000 + (j << 12), 'hdf);
            mem[GL0_I + 8] = pte(FRAME, gflags);
        end
    endtask

    task automatic guest_translate(input [1:0] acc, input [1:0] prv,
                                    input sum, input mxr, input integer cause,
                                    input [63:0] want_pa, input [1:0] want_pbmt = 0,
                                    input [63:0] want_gpa = 0, input want_pte = 0);
        reg want_valid;
        begin
            translate(acc, prv, sum, mxr, cause, want_pa, want_pbmt);
            want_valid = cause == 20 || cause == 21 || cause == 23;
            if (fault_gpa_valid !== want_valid ||
                fault_gpa !== (want_valid ? want_gpa : 64'b0) ||
                fault_gpa_is_pte !== (want_valid && want_pte) ||
                fault_tinst !== (want_valid && want_pte ? 64'h3000 : 64'b0))
                $fatal(1, "check=%0d guest metadata valid=%b GPA=%h pte=%b tinst=%h expected valid=%b GPA=%h pte=%b",
                    checks-1, fault_gpa_valid, fault_gpa, fault_gpa_is_pte, fault_tinst,
                    want_valid, want_gpa, want_pte);
        end
    endtask

    // Cancel each single PTE read while backpressure can hold AR or R.
    // No further table access, completion metadata or cache entry may leak.
    task automatic guest_flush_read(input integer target_read, input cancel_only = 0);
        integer n, start_reads;
        reg [3:0] keep_tlb, keep_pwc;
        begin
            if (cancel_only) guest_with_host_cache();
            else guest_mapping(1, 1, 'hcf, 'hdf);
            keep_tlb = cancel_only ? dut.tlb_v : 4'b0;
            keep_pwc = cancel_only ? dut.pwc_v : 4'b0;
            start_reads = reads;
            @(negedge clk); req = 1; access = 1; priv = 1;
            @(posedge clk); #1; req = 0;
            n = 0;
            while (!(read_active && reads == start_reads + target_read) && n < 512) begin
                @(negedge clk); n = n + 1;
            end
            if (n == 512) $fatal(1, "guest flush read %0d not reached", target_read);
            flush = !cancel_only; cancel = cancel_only;
            @(posedge clk); #1;
            @(negedge clk); flush = 0; cancel = 0;
            n = 0;
            while (busy && n < 512) begin
                @(posedge clk); #1; n = n + 1;
            end
            if (busy || fault || pbmt || fault_gva || fault_gpa_valid || fault_gpa ||
                fault_tinst || fault_gpa_is_pte || dut.tlb_v != keep_tlb || dut.pwc_v != keep_pwc ||
                dut.gtlb_v != 0 || reads != start_reads + target_read)
                $fatal(1, "guest flush failed at PTE read %0d", target_read);
            checks = checks + 1;
            mem[GL0_I + 8] = pte(FRAME + 'h1000, 'hdf | (64'b1 << 61));
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h1678, 1);
        end
    endtask

    task automatic napot_mapping(input [63:0] base, input [63:0] flags);
        integer j;
        begin
            mapping(0, flags);
            for (j = 0; j < 16; j = j + 1)
                mem[('h4000 >> 3) + 'h40 + j] = pte(base + 'h8000, flags | PTE_N);
        end
    endtask

    task automatic mapping(input integer level, input [63:0] flags);
        begin
            invalidate();
            mem[ROOT_I] = pte(L1, 1);
            mem[L1_I] = pte(L0, 1);
            mem[LEAF_I] = pte(FRAME, flags);
            if (level == 2) mem[ROOT_I] = pte(64'h80000000, flags);
            if (level == 1) mem[L1_I] = pte(64'h80000000, flags);
        end
    endtask

    // The FPGA local-memory responder only accepts single-beat reads.
    // Exercise every PTE position in a line at every page-table level,
    // without flushing between neighbors (an incomplete PWC fill must not
    // turn the seven other entries into invalid PTEs).
    task automatic local_page_tables(input [63:0] base);
        integer level, j, first_read, first_single, index;
        reg [63:0] table_addr;
        begin
            satp = 64'h8000000000000000 | (base >> 12);
            for (level = 0; level < 3; level = level + 1) begin
                invalidate();
                mem[base[15:3]] = pte(base + 'h1000, 1);
                mem[base[15:3] + 'h200] = pte(base + 'h2000, 1);
                table_addr = base + ((2-level) * 'h1000);
                for (j = 0; j < 8; j = j + 1)
                    mem[table_addr[15:3] + j] = pte(64'h80000000, 'hcf);
                first_read = reads; first_single = single_reads;
                for (j = 0; j < 8; j = j + 1) begin
                    va = (64'(j) << (12 + 9*level)) | 'h678;
                    translate(1, 1, 0, 0, 0, 64'h80000678);
                    index = reads;
                    translate(1, 1, 0, 0, 0, 64'h80000678);
                    if (reads != index) $fatal(1, "local PTE translation missed TLB");
                end
                if (reads-first_read != 8*(3-level) ||
                    single_reads-first_single != reads-first_read || dut.pwc_v != 0)
                    $fatal(1, "local page tables used PWC/burst reads");
            end
            satp = 64'h8000000000080002; va = 'h45678;
            invalidate();
        end
    endtask

    // Level 3 selects the standard NAPOT fixture; 0/1/2 are Sv39 levels.
    task automatic pbmt_mapping(input integer level, input [63:0] flags, input [1:0] attr);
        begin
            if (level == 3) napot_mapping(NAPOT_FRAME, flags | {1'b0, attr, 61'b0});
            else mapping(level, flags | {1'b0, attr, 61'b0});
        end
    endtask

    task automatic translate(input [1:0] acc, input [1:0] prv,
                             input sum, input mxr,
                             input integer cause, input [63:0] want_pa,
                             input [1:0] want_pbmt = 0, input toggle_pbmte = 0);
        integer n, start_cycle;
        begin
            @(negedge clk);
            access = acc; priv = prv; status_sum = sum; status_mxr = mxr;
            req = 1; flush = flush_on_req;
            @(posedge clk); #1; req = 0; flush = 0;
            start_cycle = cycles;
            if (toggle_pbmte) pbmte = !pbmte;
            n = 0;
            while (!done && n < 512) begin
                @(posedge clk); #1; n = n + 1;
            end
            if (!done) $fatal(1, "translation timeout check=%0d", checks);
            last_translation_cycles = cycles - start_cycle;
            if (fault != (cause != 0) || (fault &&
                (fault_cause != cause || fault_va != va)) ||
                (!fault && pa != want_pa))
                $fatal(1, "check=%0d acc=%0d priv=%0d va=%h: fault=%0d cause=%0d tval=%h pa=%h wanted cause=%0d pa=%h",
                    checks, acc, prv, va, fault, fault_cause, fault_va, pa, cause, want_pa);
            if (pbmt !== (cause != 0 ? 2'b00 : want_pbmt))
                $fatal(1, "check=%0d PBMT=%b expected=%b", checks, pbmt, cause != 0 ? 2'b00 : want_pbmt);
            if (fault_gva !== (virt && cause != 0) ||
                (!virt && (fault_gpa_valid || fault_gpa || fault_tinst || fault_gpa_is_pte)) ||
                (!fault && (fault_gpa_valid || fault_gpa || fault_tinst || fault_gpa_is_pte)))
                $fatal(1, "check=%0d stale/incorrect guest fault metadata", checks);
            // Compare architectural outcomes across cached/uncached runs.
            // Stale-cache demonstrations explicitly opt out until a fence.
            if (signature_enable) begin
                result_signature = {result_signature[56:0], result_signature[63:57]} ^
                    va ^ (fault ? fault_cause : pa) ^ fault_gpa ^ fault_tinst ^
                    {60'b0, fault, fault_gva, pbmt};
                result_count = result_count + 1;
            end
            checks = checks + 1;
        end
    endtask

    task automatic flush_during(input integer phase, input integer beat,
                                input integer level, input integer napot = 0,
                                input [1:0] old_pbmt = 0, input [1:0] new_pbmt = 0);
        integer n, before_reads;
        begin
            if (napot) napot_mapping(NAPOT_FRAME, 'hcf | ({62'b0, old_pbmt} << 61));
            else mapping(0, 'hcf | ({62'b0, old_pbmt} << 61));
            @(negedge clk); req = 1; access = 1; priv = 1;
            @(posedge clk); #1; req = 0;
            n = 0;
            while (!(dut.state == phase && dut.level_q == level &&
                   (phase != 3 || (read_active && read_beat == beat && rvalid)) &&
                   (phase != 2 || beat == 0 || dut.pwc_hit)) && n < 150) begin
                @(negedge clk); n = n + 1;
            end
            if (n == 150) $fatal(1, "flush phase not reached");
            before_reads = reads;
            flush = 1;
            @(posedge clk); #1;
            @(negedge clk); flush = 0;
            if (napot) begin
                for (n = 0; n < 16; n = n + 1)
                    mem[('h4000 >> 3) + 'h40 + n] = pte(NAPOT_FRAME + 'h18000,
                        PTE_N | 'hcf | ({62'b0, new_pbmt} << 61));
            end else mem[LEAF_I] = pte(FRAME + 'h1000, 'hcf | ({62'b0, new_pbmt} << 61));
            n = 0;
            while (busy && n < 150) begin
                @(posedge clk); #1; n = n + 1;
            end
            if (busy || fault || pbmt !== 0 || dut.tlb_v != 0 || dut.pwc_v != 0 ||
                dut.gtlb_v != 0 || reads != before_reads)
                $fatal(1, "flush retained a translation or continued a canceled walk");
            checks = checks + 1;
            translate(1, 1, 0, 0, 0, napot ? NAPOT_FRAME + 'h15678 : FRAME + 'h1678, new_pbmt);
        end
    endtask

    integer i, lvl, flags, acc, user, cause, before_reads, page, attr, en, sum_bit, mxr_bit;
    integer other_attr, before_single, before_io, n, vsd, gd;
    reg legal;
    reg [63:0] expect_pa;
    reg [3:0] keep_tlb, keep_pwc;
    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = 0;
        repeat (4) @(posedge clk);
        #1; if (pbmt !== 0) $fatal(1, "reset did not clear PBMT");
        @(negedge clk); rst = 0;

        local_page_tables(64'h1000);   // boot ROM
        local_page_tables(64'h101000); // scratch SRAM

        // A malformed DRAM response must fault, not cache zero-filled PTEs.
        // Check all early termination positions and original access causes.
        for (i = 0; i < 7; i = i + 1)
            for (acc = 0; acc < 3; acc = acc + 1) begin
                mapping(0, 'hcf);
                early_last_line = 32'h80004200; early_last_beat = i[2:0];
                translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
                if (dut.pwc_v[dut.fill_way_q]) $fatal(1, "early RLAST published PWC line");
                early_last_line = 32'hffffffff;
                translate(acc[1:0], 1, 0, 0, 0, FRAME + 'h678);
            end
        for (acc = 0; acc < 3; acc = acc + 1) begin
            mapping(0, 'hcf);
            missing_last_line = 32'h80004200;
            translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            if (dut.pwc_v[dut.fill_way_q]) $fatal(1, "missing RLAST published PWC line");
            missing_last_line = 32'hffffffff;
            translate(acc[1:0], 1, 0, 0, 0, FRAME + 'h678);
        end

        // Independent truth table: V/R/W/X/U/G/A/D, all page sizes and
        // original access types, in both U and S modes (SUM=MXR=0).
        for (lvl = 0; lvl < 3; lvl = lvl + 1)
            for (flags = 0; flags < 256; flags = flags + 1)
                for (user = 0; user < 2; user = user + 1)
                    for (acc = 0; acc < 3; acc = acc + 1) begin
                        mapping(lvl, flags);
                        legal = (flags & 1) != 0 &&
                            !((flags & 2) == 0 && (flags & 4) != 0) &&
                            ((flags & 16) != 0) == (user == 1) &&
                            (flags & 64) != 0 &&
                            (acc == 0 ? (flags & 8) != 0 :
                             acc == 1 ? (flags & 2) != 0 :
                                        (flags & 132) == 132);
                        cause = legal ? 0 : acc == 0 ? 12 : acc == 1 ? 13 : 15;
                        expect_pa = lvl == 0 ? FRAME + 'h678 : 64'h80045678;
                        translate(acc[1:0], user == 1 ? 2'd0 : 2'd1, 0, 0, cause, expect_pa);
                    end

        // A load-filled A=1,D=0 TLB entry cannot authorize a later store.
        // Software repair plus flush must evict both the TLB and the PWC.
        for (lvl = 0; lvl < 3; lvl = lvl + 1) begin
            mapping(lvl, 'h4f);
            expect_pa = lvl == 0 ? FRAME + 'h678 : 64'h80045678;
            translate(1, 1, 0, 0, 0, expect_pa);
            before_reads = reads;
            translate(2, 1, 0, 0, 15, 0);
            translate(0, 1, 0, 0, 0, expect_pa);
            if (reads != before_reads) $fatal(1, "expected D=0 TLB hit");
            mapping(lvl, 'hcf);
            translate(2, 1, 0, 0, 0, expect_pa);
        end

        // Immediate permission changes must take effect even on TLB hits.
        mapping(0, 'hd9); // U execute-only, A/D set
        translate(1, 1, 1, 1, 0, FRAME + 'h678);
        translate(1, 1, 0, 1, 13, 0);
        translate(1, 1, 1, 0, 13, 0);
        translate(0, 1, 1, 1, 12, 0); // S cannot fetch U, even SUM=1
        translate(0, 0, 0, 0, 0, FRAME + 'h678);
        mapping(0, 'h47); // CBO clean/flush: A required, D not required
        translate(3, 1, 0, 0, 0, FRAME + 'h678);
        mapping(0, 'h07);
        translate(3, 1, 0, 0, 15, 0);

        // INVAL/CLEAN/FLUSH share management access class 3. Every page
        // size permits R,A=1,D=0 and MXR-readable X-only leaves; repeat
        // each successful request to exercise the cached permission path.
        for (lvl = 0; lvl < 3; lvl = lvl + 1) begin
            expect_pa = lvl == 0 ? FRAME + 'h678 : 64'h80045678;
            mapping(lvl, 'h43);
            translate(3, 1, 0, 0, 0, expect_pa);
            before_reads = reads;
            translate(3, 1, 0, 0, 0, expect_pa);
            if (reads != before_reads) $fatal(1, "management TLB hit missed");
            mapping(lvl, 'h49);
            translate(3, 1, 0, 1, 0, expect_pa);
            before_reads = reads;
            translate(3, 1, 0, 1, 0, expect_pa);
            if (reads != before_reads) $fatal(1, "MXR management TLB hit missed");
            mapping(lvl, 'h03);
            translate(3, 1, 0, 0, 15, 0);
        end

        // Every non-leaf level rejects U/A/D separately; G and RSW remain
        // legal on pointers and leaves. Unsupported high bits also fault.
        for (lvl = 1; lvl < 3; lvl = lvl + 1)
            for (i = 0; i < 3; i = i + 1) begin
                mapping(0, 'hcf);
                if (lvl == 2) mem[ROOT_I] = pte(L1, 1 | (i == 0 ? 16 : i == 1 ? 64 : 128));
                else mem[L1_I] = pte(L0, 1 | (i == 0 ? 16 : i == 1 ? 64 : 128));
                translate(1, 1, 0, 0, 13, 0);
            end
        mapping(0, 'h3ef);
        mem[ROOT_I] = pte(L1, 'h321);
        mem[L1_I] = pte(L0, 'h321);
        translate(1, 1, 0, 0, 0, FRAME + 'h678);
        for (i = 54; i < 63; i = i + 1) begin
            mapping(0, 'hcf | (64'b1 << i));
            translate(1, 1, 0, 0, 13, 0);
        end

        // Superpage alignment and canonical-address checks.
        for (lvl = 1; lvl < 3; lvl = lvl + 1) begin
            mapping(lvl, 'hcf);
            if (lvl == 1) mem[L1_I] = pte(64'h80001000, 'hcf);
            else mem[ROOT_I] = pte(64'h80200000, 'hcf);
            translate(1, 1, 0, 0, 13, 0);
        end
        mapping(0, 'hcf);
        va = 64'h0000008000045678;
        translate(1, 1, 0, 0, 13, 0);
        va = 64'h45678;

        // Read-only page-table memory does not require write permission under
        // Svade. A=1,D=0 succeeds on load, faults on store, with no PTE write.
        invalidate();
        satp = 64'h8000000000000001;
        mem['h1000 >> 3] = pte(64'h80000000, 'h4f);
        translate(1, 1, 0, 0, 0, 64'h80045678);
        translate(2, 1, 0, 0, 15, 0);
        satp = 64'h8000000000080002;

        // A cached superpage can cross PMA regions; a TLB hit must still
        // check the actual physical subpage and original access type.
        mapping(2, 'hcf);
        mem[ROOT_I] = pte(0, 'hcf);
        translate(1, 1, 0, 0, 0, va); // boot ROM
        translate(2, 1, 0, 0, 7, 0);
        va = 64'h101000; // writable scratch, same superpage
        translate(2, 1, 0, 0, 0, va);
        va = 64'h200000; // unmapped hole, same superpage
        translate(1, 1, 0, 0, 5, 0);
        va = 64'h45678;

        // PTE physical read faults outrank interpretation of the PTE. A/D
        // faults precede the final translated-address PMA check.
        for (acc = 0; acc < 3; acc = acc + 1) begin
            mapping(0, 0);
            mem[ROOT_I] = pte(0, 1);
            translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            mapping(0, 'hcf);
            mem[LEAF_I] = pte(0, 'hcf);
            translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            mapping(0, 'h0f);
            mem[LEAF_I] = pte(0, 'h0f);
            translate(acc[1:0], 1, 0, 0, acc == 0 ? 12 : acc == 1 ? 13 : 15, 0);
            mapping(0, 'hcf);
            mem[LEAF_I] = pte(64'h180008000, 'hcf);
            translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            for (i = 0; i < 8; i = i + 1) begin
                mapping(0, 0);
                error_line = ROOT[31:0]; error_beat = i[2:0];
                translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
                if (dut.pwc_v != 0) $fatal(1, "cached an AXI-error PTE line");
                error_line = 32'hffffffff;
            end
        end

        // Distinct ASIDs and roots, and a flush concurrent with a TLB hit.
        mapping(0, 'hcf);
        translate(1, 1, 0, 0, 0, FRAME + 'h678);
        satp[59:44] = 1;
        #1;
        if (dut.tlb_hit) $fatal(1, "ASID switch reused old TLB entry");
        translate(1, 1, 0, 0, 0, FRAME + 'h678);
        if (!dut.tlb_hit) $fatal(1, "new ASID translation not cached");
        mem[LEAF_I] = pte(FRAME + 'h1000, 'hcf);
        flush_on_req = 1;
        translate(1, 1, 0, 0, 0, FRAME + 'h1678);
        flush_on_req = 0;
        satp[59:44] = 0;

        // A flush never allows the old walk to repopulate TLB/PWC, whether
        // before AR, in any response beat, or on cached-leaf completion.
        flush_during(1, 0, 2);
        flush_during(2, 0, 2);
        for (i = 0; i < 8; i = i + 1) flush_during(3, i, 2);
        flush_during(2, 0, 0);
        flush_during(2, 1, 0); // same-cycle flush and cached-leaf completion

        // Svnapot v1.0: every 4 KiB subpage of a 64 KiB region gets the
        // VPN low nibble, not the PTE's size marker 1000. Access each page
        // repeatedly to prove the resolved TLB translation and D=0 checks.
        napot_mapping(NAPOT_FRAME, 'h4f);
        for (page = 0; page < 16; page = page + 1) begin
            va = 'h40000 + (page << 12) + 'h678;
            expect_pa = NAPOT_FRAME + (page << 12) + 'h678;
            translate(1, 1, 0, 0, 0, expect_pa);
            before_reads = reads;
            translate(1, 1, 0, 0, 0, expect_pa);
            translate(2, 1, 0, 0, 15, 0);
            translate(0, 1, 0, 0, 0, expect_pa);
            if (reads != before_reads) $fatal(1, "NAPOT subpage TLB hit missed");
        end
        napot_mapping(NAPOT_FRAME, 'hcf); // software A/D repair + flush
        for (page = 0; page < 16; page = page + 1) begin
            va = 'h40000 + (page << 12) + 'hff8;
            expect_pa = NAPOT_FRAME + (page << 12) + 'hff8;
            translate(2, 1, 0, 0, 0, expect_pa);
            translate(1, 1, 0, 0, 0, expect_pa);
        end
        va = 'h45678;

        // Exhaust all permission/A/D combinations independently for NAPOT.
        for (flags = 0; flags < 256; flags = flags + 1)
            for (user = 0; user < 2; user = user + 1)
                for (acc = 0; acc < 3; acc = acc + 1) begin
                    napot_mapping(NAPOT_FRAME, flags);
                    legal = (flags & 1) != 0 &&
                        !((flags & 2) == 0 && (flags & 4) != 0) &&
                        ((flags & 16) != 0) == (user == 1) &&
                        (flags & 64) != 0 &&
                        (acc == 0 ? (flags & 8) != 0 :
                         acc == 1 ? (flags & 2) != 0 : (flags & 132) == 132);
                    cause = legal ? 0 : acc == 0 ? 12 : acc == 1 ? 13 : 15;
                    translate(acc[1:0], user == 1 ? 2'd0 : 2'd1, 0, 0,
                              cause, NAPOT_FRAME + 'h5678);
                end
        napot_mapping(NAPOT_FRAME, 'h59); // U execute-only, A=1,D=0
        translate(1, 1, 1, 1, 0, NAPOT_FRAME + 'h5678);
        before_reads = reads;
        translate(1, 1, 0, 1, 13, 0);
        translate(1, 1, 1, 0, 13, 0);
        translate(0, 1, 1, 1, 12, 0);
        translate(0, 0, 0, 0, 0, NAPOT_FRAME + 'h5678);
        translate(3, 1, 1, 1, 0, NAPOT_FRAME + 'h5678);
        if (reads != before_reads) $fatal(1, "NAPOT permission check bypassed TLB");

        // Exhaust PPN[0] at every level. Only low nibble 1000 at level0
        // is legal; all other encodings (including N on superpages) fault.
        for (lvl = 0; lvl < 3; lvl = lvl + 1)
            for (i = 0; i < 512; i = i + 1)
                for (acc = 0; acc < 3; acc = acc + 1) begin
                    mapping(lvl, 'hcf);
                    if (lvl == 0) mem[LEAF_I] = pte(64'h80000000 + (i << 12), PTE_N | 'hcf);
                    else if (lvl == 1) mem[L1_I] = pte(64'h80000000 + (i << 12), PTE_N | 'hcf);
                    else mem[ROOT_I] = pte(64'h80000000 + (i << 12), PTE_N | 'hcf);
                    cause = lvl == 0 && (i & 15) == 8 ? 0 : acc == 0 ? 12 : acc == 1 ? 13 : 15;
                    translate(acc[1:0], 1, 0, 0, cause, 64'h80000000 + ((i & ~15) << 12) + 'h5678);
                end
        for (i = 54; i < 63; i = i + 1) begin
            napot_mapping(NAPOT_FRAME, 'hcf | (64'b1 << i));
            translate(1, 1, 0, 0, 13, 0);
        end
        for (lvl = 1; lvl < 3; lvl = lvl + 1) begin
            mapping(0, 'hcf);
            if (lvl == 1) mem[L1_I] = pte(L0, PTE_N | 1);
            else mem[ROOT_I] = pte(L1, PTE_N | 1);
            translate(1, 1, 0, 0, 13, 0);
        end

        // PMA applies to the resolved subpage, including cache hits; the
        // first subpage is an unmapped hole, the remaining ones are ROM.
        napot_mapping(0, 'hcf);
        for (page = 0; page < 16; page = page + 1) begin
            va = 'h40000 + (page << 12) + 'h678;
            expect_pa = (page << 12) + 'h678;
            translate(1, 1, 0, 0, page == 0 ? 5 : 0, expect_pa);
            translate(2, 1, 0, 0, 7, 0);
            translate(0, 1, 0, 0, page == 0 ? 1 : 0, expect_pa);
        end
        va = 'h45678;
        for (acc = 0; acc < 3; acc = acc + 1) begin
            // All retained PPN bits above the AXI width must fault, not alias.
            for (i = 32; i < 56; i = i + 1) begin
                napot_mapping(NAPOT_FRAME | (64'b1 << i), 'hcf);
                translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            end
            napot_mapping(0, 'h0f); // A/D fault precedes final PA access check
            translate(acc[1:0], 1, 0, 0, acc == 0 ? 12 : acc == 1 ? 13 : 15, 0);
            for (i = 0; i < 8; i = i + 1) begin
                napot_mapping(NAPOT_FRAME, 'hcf);
                error_line = L0[31:0] + 'h200; error_beat = i[2:0];
                translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
                error_line = 32'hffffffff;
            end
        end
        napot_mapping(NAPOT_FRAME, 'hcf);
        translate(1, 1, 0, 0, 0, NAPOT_FRAME + 'h5678);
        for (i = 0; i < 16; i = i + 1)
            mem[('h4000 >> 3) + 'h40 + i] = pte(NAPOT_FRAME + 'h18000, PTE_N | 'hcf);
        flush_on_req = 1;
        translate(1, 1, 0, 0, 0, NAPOT_FRAME + 'h15678);
        flush_on_req = 0;
        flush_during(1, 0, 2, 1);
        flush_during(2, 0, 2, 1);
        for (i = 0; i < 8; i = i + 1) begin
            flush_during(3, i, 2, 1);
            flush_during(3, i, 0, 1);
        end
        flush_during(2, 0, 0, 1);
        flush_during(2, 1, 0, 1);

        // Every PBMTE/PBMT encoding, access class and supported mapping
        // shape. Repeat requests to exercise cached attributes/legality.
        for (en = 0; en < 2; en = en + 1)
            for (attr = 0; attr < 4; attr = attr + 1)
                for (lvl = 0; lvl < 4; lvl = lvl + 1)
                    for (acc = 0; acc < 4; acc = acc + 1) begin
                        pbmte = en[0];
                        pbmt_mapping(lvl, 'hcf, attr[1:0]);
                        expect_pa = lvl == 3 ? NAPOT_FRAME + 'h5678 :
                                    lvl == 0 ? FRAME + 'h678 : 64'h80045678;
                        cause = attr == 3 || (!en && attr != 0) ?
                                (acc == 0 ? 12 : acc == 1 ? 13 : 15) : 0;
                        translate(acc[1:0], 1, 0, 0, cause, expect_pa, attr[1:0]);
                        before_reads = reads;
                        translate(acc[1:0], 1, 0, 0, cause, expect_pa, attr[1:0]);
                        if (cause == 0 && reads != before_reads)
                            $fatal(1, "PBMT repeated translation did not hit TLB");
                    end

        // Svpbmt changes attributes, never V/R/W/X/U/G/A/D permissions.
        // Exhaust all flag combinations, original accesses plus management,
        // both privilege modes, ordinary/superpages and NAPOT, for NC and IO.
        pbmte = 1;
        for (attr = 1; attr <= 2; attr = attr + 1)
            for (lvl = 0; lvl < 4; lvl = lvl + 1)
                for (flags = 0; flags < 256; flags = flags + 1)
                    for (user = 0; user < 2; user = user + 1)
                        for (acc = 0; acc < 4; acc = acc + 1) begin
                            pbmt_mapping(lvl, flags, attr[1:0]);
                            legal = (flags & 1) != 0 &&
                                !((flags & 2) == 0 && (flags & 4) != 0) &&
                                ((flags & 16) != 0) == (user == 1) &&
                                (flags & 64) != 0 &&
                                (acc == 0 ? (flags & 8) != 0 :
                                 acc == 1 ? (flags & 2) != 0 :
                                 acc == 2 ? (flags & 132) == 132 : (flags & 6) != 0);
                            cause = legal ? 0 : acc == 0 ? 12 : acc == 1 ? 13 : 15;
                            expect_pa = lvl == 3 ? NAPOT_FRAME + 'h5678 :
                                        lvl == 0 ? FRAME + 'h678 : 64'h80045678;
                            translate(acc[1:0], user == 1 ? 2'd0 : 2'd1, 0, 0,
                                      cause, expect_pa, attr[1:0]);
                        end

        for (attr = 1; attr <= 2; attr = attr + 1)
            for (lvl = 0; lvl < 4; lvl = lvl + 1) begin
                expect_pa = lvl == 3 ? NAPOT_FRAME + 'h5678 :
                            lvl == 0 ? FRAME + 'h678 : 64'h80045678;
                pbmt_mapping(lvl, 'h4f, attr[1:0]);
                translate(1, 1, 0, 0, 0, expect_pa, attr[1:0]);
                before_reads = reads;
                translate(2, 1, 0, 0, 15, 0); // Svade D=0 on a hit, PBMT cleared on fault
                translate(0, 1, 0, 0, 0, expect_pa, attr[1:0]);
                translate(3, 1, 0, 0, 0, expect_pa, attr[1:0]);
                if (reads != before_reads) $fatal(1, "PBMT D=0 check missed TLB");
                pbmt_mapping(lvl, 'hcf, attr[1:0]); // software D repair and invalidation
                translate(2, 1, 0, 0, 0, expect_pa, attr[1:0]);

                // U execute-only page: sweep SUM/MXR and all access classes
                // immediately on a shared TLB entry, including management.
                pbmt_mapping(lvl, 'hd9, attr[1:0]);
                translate(0, 0, 0, 0, 0, expect_pa, attr[1:0]);
                before_reads = reads;
                for (user = 0; user < 2; user = user + 1)
                    for (sum_bit = 0; sum_bit < 2; sum_bit = sum_bit + 1)
                        for (mxr_bit = 0; mxr_bit < 2; mxr_bit = mxr_bit + 1)
                            for (acc = 0; acc < 4; acc = acc + 1) begin
                                legal = (user == 1 || (sum_bit && acc != 0)) &&
                                        (acc == 0 || (acc != 2 && mxr_bit));
                                cause = legal ? 0 : acc == 0 ? 12 : acc == 1 ? 13 : 15;
                                translate(acc[1:0], user == 1 ? 2'd0 : 2'd1,
                                          sum_bit[0], mxr_bit[0], cause, expect_pa, attr[1:0]);
                            end
                if (reads != before_reads) $fatal(1, "PBMT SUM/MXR check missed TLB");
            end

        // Every nonzero non-leaf field is reserved, even with PBMTE=1.
        for (en = 0; en < 2; en = en + 1)
            for (attr = 1; attr < 4; attr = attr + 1)
                for (lvl = 1; lvl < 3; lvl = lvl + 1)
                    for (acc = 0; acc < 4; acc = acc + 1) begin
                        pbmte = en[0];
                        mapping(0, 'hcf);
                        if (lvl == 1) mem[L1_I] = pte(L0, 1 | {1'b0, attr[1:0], 61'b0});
                        else mem[ROOT_I] = pte(L1, 1 | {1'b0, attr[1:0], 61'b0});
                        translate(acc[1:0], 1, 0, 0, acc == 0 ? 12 : acc == 1 ? 13 : 15, 0);
                    end

        // Each resolved NAPOT subpage retains NC/IO across a TLB hit.
        pbmte = 1;
        for (attr = 1; attr <= 2; attr = attr + 1) begin
            pbmt_mapping(3, 'hcf, attr[1:0]);
            for (page = 0; page < 16; page = page + 1) begin
                va = 'h40000 + (page << 12) + 'h678;
                expect_pa = NAPOT_FRAME + (page << 12) + 'h678;
                translate(1, 1, 0, 0, 0, expect_pa, attr[1:0]);
                before_reads = reads;
                translate(2, 1, 0, 0, 0, expect_pa, attr[1:0]);
                if (reads != before_reads) $fatal(1, "NAPOT PBMT hit missed TLB");
            end
        end
        va = 'h45678;

        // PBMTE is sampled per walk; PWC lines contain raw PTE bits rather
        // than an interpretation frozen under a previous PBMTE value.
        pbmt_mapping(0, 'hcf, 1);
        pbmte = 1;
        translate(1, 1, 0, 0, 0, FRAME + 'h678, 1, 1); // PBMTE drops after acceptance
        before_reads = reads;
        translate(1, 1, 0, 0, 13, 0); // this implementation gates cached PBMT immediately
        if (reads != before_reads) $fatal(1, "disabled-PBMTE TLB check missed");
        invalidate();
        translate(1, 1, 0, 0, 13, 0); // cache raw PTE, but do not fill TLB
        before_reads = reads;
        pbmte = 1;
        translate(1, 1, 0, 0, 0, FRAME + 'h678, 1);
        if (reads != before_reads) $fatal(1, "PWC lost raw PBMT interpretation");
        pbmt_mapping(0, 'hcf, 2);
        pbmte = 0;
        translate(1, 1, 0, 0, 13, 0, 0, 1); // PBMTE rises after request, too late for this walk
        translate(1, 1, 0, 0, 0, FRAME + 'h678, 2);

        // Bare/M accesses ignore cached attributes. Reset, noncanonical,
        // page/PMA and AXI-error faults all return deterministic PBMT=00.
        va = 64'h80045678;
        for (acc = 0; acc < 4; acc = acc + 1)
            translate(acc[1:0], 3, 0, 0, 0, va);
        satp = 0;
        translate(1, 1, 0, 0, 0, va);
        satp = 64'h8000000000080002;
        va = 64'h0000008000045678;
        translate(1, 1, 0, 0, 13, 0);
        va = 'h45678;
        for (attr = 1; attr <= 2; attr = attr + 1) begin
            for (i = 54; i < 61; i = i + 1) begin
                pbmt_mapping(0, 'hcf | (64'b1 << i), attr[1:0]);
                translate(1, 1, 0, 0, 13, 0);
            end
            for (acc = 0; acc < 4; acc = acc + 1) begin
                pbmt_mapping(0, 'hcf, attr[1:0]);
                mem[LEAF_I] = pte(0, 'hcf | {1'b0, attr[1:0], 61'b0});
                translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
                mem[LEAF_I] = pte(64'h180008000, 'hcf | {1'b0, attr[1:0], 61'b0});
                invalidate();
                translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
                for (i = 0; i < 8; i = i + 1) begin
                    pbmt_mapping(0, 'hcf, attr[1:0]);
                    error_line = L0[31:0] + 'h200; error_beat = i[2:0];
                    translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
                    error_line = 32'hffffffff;
                end
            end
            pbmt_mapping(2, 'hcf, attr[1:0]);
            mem[ROOT_I] = pte(0, 'hcf | {1'b0, attr[1:0], 61'b0});
            translate(1, 1, 0, 0, 0, va, attr[1:0]); // ROM
            before_reads = reads;
            translate(2, 1, 0, 0, 7, 0); // PBMT cannot make ROM writable
            va = 'h200000;
            translate(1, 1, 0, 0, 5, 0); // nor make a vacant PMA accessible
            if (reads != before_reads) $fatal(1, "PBMT superpage PMA hit missed");
            va = 'h45678;
        end

        // Fences replace both PA and attributes; canceled walks publish
        // neither. Cover ordinary and NAPOT leaves, and both NC<->IO changes.
        for (attr = 1; attr <= 2; attr = attr + 1)
            for (page = 0; page < 2; page = page + 1) begin
                flush_during(1, 0, 2, page, attr[1:0], 3-attr);
                flush_during(2, 0, 2, page, attr[1:0], 3-attr);
                for (i = 0; i < 8; i = i + 1) begin
                    flush_during(3, i, 2, page, attr[1:0], 3-attr);
                    flush_during(3, i, 0, page, attr[1:0], 3-attr);
                end
                flush_during(2, 0, 0, page, attr[1:0], 3-attr);
                flush_during(2, 1, 0, page, attr[1:0], 3-attr);
            end
        pbmt_mapping(0, 'hcf, 2);
        translate(1, 1, 0, 0, 0, FRAME + 'h678, 2);
        @(negedge clk); rst = 1;
        @(posedge clk); #1;
        if (pbmt !== 0 || dut.tlb_v != 0 || dut.pwc_v != 0 || dut.gtlb_v != 0)
            $fatal(1, "reset retained a PBMT translation");
        @(negedge clk); rst = 0;
        translate(1, 1, 0, 0, 0, FRAME + 'h678, 2);
        // HLVX is a LOAD for faults and SUM/U checks, but requires X at
        // translation and both read/execute at the final physical address.
        hlvx = 1;
        mapping(0, 'h49); // S execute-only, A=1
        translate(1, 1, 0, 0, 0, FRAME + 'h678);
        translate(1, 1, 0, 0, 0, FRAME + 'h678); // hit
        hlvx = 0;
        translate(1, 1, 0, 0, 13, 0);
        hlvx = 1;
        mapping(0, 'h43); // readable but not executable
        translate(1, 1, 0, 1, 13, 0);
        mapping(0, 'h59); // U execute-only
        translate(1, 1, 0, 0, 13, 0);
        translate(1, 1, 1, 0, 0, FRAME + 'h678);
        translate(1, 0, 0, 0, 0, FRAME + 'h678);
        satp = 0; va = 'h10000000;
        translate(1, 1, 0, 0, 5, 0); // IO PMA is readable, not executable
        hlvx = 0;

        // A host page table in physical IO must issue only its selected
        // eight bytes, wait for older accesses, and never use the PWC.
        va = 'h45678; satp = 64'h8000000000002002;
        mapping(0, 'hcf);
        pte_read_safe = 0;
        before_reads = reads; before_single = single_reads; before_io = io_reads;
        @(negedge clk); req = 1; access = 1; priv = 1;
        @(posedge clk); #1; req = 0;
        n = 0;
        while (!pte_io_pending && n < 32) begin @(posedge clk); #1; n = n + 1; end
        if (!pte_io_pending) $fatal(1, "host IO PTE safety wait missing");
        repeat (8) begin
            @(posedge clk); #1;
            if (arvalid || reads != before_reads || done)
                $fatal(1, "host IO PTE read escaped safety gate");
        end
        @(negedge clk); pte_read_safe = 1;
        n = 0;
        while (!done && n < 150) begin @(posedge clk); #1; n = n + 1; end
        if (!done || fault || pa != FRAME + 'h678 ||
            single_reads != before_single + 1 || io_reads != before_io + 1)
            $fatal(1, "host IO PTE read did not complete exactly once");
        checks = checks + 1;
        satp = satp | (64'b1 << 44); // miss TLB; cached downstream lines remain
        translate(1, 1, 0, 0, 0, FRAME + 'h678);
        if (single_reads != before_single + 2 || io_reads != before_io + 2 ||
            reads != before_reads + 4)
            $fatal(1, "host IO PTE was cached or adjacent bytes were read");

        // All four VS/G mode combinations. A fully nested three-level
        // translation reads 3*(3+1)+3 PTEs, never a speculative line.
        for (i = 0; i < 4; i = i + 1) begin
            guest_mapping(i[0], i[1], 'hcf, 'hdf);
            before_reads = reads; before_single = single_reads;
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            n = i == 3 ? 15 : i == 0 ? 0 : 3;
            if (reads != before_reads + n || single_reads != before_single + n ||
                dut.tlb_v != 0 || dut.pwc_v != 0)
                $fatal(1, "guest mode combination %0d read/cache contract failed", i);
        end

        // Host cache contents may remain live across guest requests. Guest
        // roots/permissions must neither reuse nor replace those entries.
        virt = 0; satp = 64'h8000000000080002; va = 'h45678;
        mapping(0, 'hcf);
        translate(1, 1, 0, 0, 0, FRAME + 'h678);
        guest_mapping(1, 1, 'hcf, 'hdf, 0);
        mem[GL0_I + 8] = pte(FRAME + 'h1000, 'hdf);
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h1678);
        if (dut.tlb_v == 0 || dut.pwc_v == 0) $fatal(1, "guest evicted host caches");
        virt = 0; before_reads = reads;
        translate(1, 1, 0, 0, 0, FRAME + 'h678); // legal stale host TLB entry
        if (reads != before_reads) $fatal(1, "host cache lost across guest request");

        // A G PBMT=IO mapping controls the physical VS-PTE read itself,
        // not the eventual leaf's attributes. Native IO G tables use the
        // same exact-read safety gate before their first physical access.
        for (page = 0; page < 2; page = page + 1) begin
            guest_mapping(1, 1, 'hcf, 'hdf);
            if (page == 0) mem[GL0_I + 2] = pte(ROOT, 'hdf | (64'b1 << 62));
            else hgatp = 64'h800000000000200c;
            pte_read_safe = 0;
            before_reads = reads; before_io = io_reads;
            @(negedge clk); req = 1; access = 1; priv = 1;
            @(posedge clk); #1; req = 0;
            n = 0;
            while (!pte_io_pending && n < 128) begin @(posedge clk); #1; n = n + 1; end
            if (!pte_io_pending || reads != before_reads + (page == 0 ? 3 : 0))
                $fatal(1, "guest IO PTE safety wait missing");
            repeat (8) begin
                @(posedge clk); #1;
                if (arvalid || reads != before_reads + (page == 0 ? 3 : 0) || done)
                    $fatal(1, "guest IO PTE read escaped safety gate");
            end
            @(negedge clk); pte_read_safe = 1;
            n = 0;
            while (!done && n < 512) begin @(posedge clk); #1; n = n + 1; end
            if (!done || fault || pa != FRAME + 'h678 || pbmt ||
                io_reads != before_io + (page == 0 ? 1 : 4))
                $fatal(1, "guest IO PTE read count/attribute mismatch");
            checks = checks + 1;
        end
        guest_mapping(1, 1, 'hcf, 'hdf);
        mem[GL0_I + 2] = pte(64'h02002000, 'hdf | (64'b1 << 61));
        pte_read_safe = 0; before_io = io_reads;
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678); // NC overrides native IO attribute
        if (io_reads != before_io) $fatal(1, "G PBMT=NC failed to override native IO");
        pte_read_safe = 1;

        // G-stage permissions always require U, independently of original
        // VS/VU privilege. Exercise every PTE flag at all three page sizes.
        for (lvl = 0; lvl < 3; lvl = lvl + 1)
            for (flags = 0; flags < 256; flags = flags + 1)
                for (acc = 0; acc < 3; acc = acc + 1) begin
                    guest_mapping(0, 1, 'hcf, flags);
                    if (lvl == 1) mem[GL1_I] = pte(64'h80000000, flags);
                    if (lvl == 2) mem[GROOT_I + 1] = pte(64'h80000000, flags);
                    legal = (flags & 1) != 0 &&
                        !((flags & 2) == 0 && (flags & 4) != 0) &&
                        (flags & 16) != 0 && (flags & 64) != 0 &&
                        (acc == 0 ? (flags & 8) != 0 :
                         acc == 1 ? (flags & 2) != 0 : (flags & 132) == 132);
                    cause = legal ? 0 : acc == 0 ? 20 : acc == 1 ? 21 : 23;
                    guest_translate(acc[1:0], 1, 0, 0, cause, FRAME + 'h678, 0, va);
                end

        // VS permission faults retain ordinary page-fault codes even
        // though each VS PTE was fetched through three G-stage levels.
        for (flags = 0; flags < 256; flags = flags + 1)
            for (user = 0; user < 2; user = user + 1)
                for (acc = 0; acc < 3; acc = acc + 1) begin
                    guest_mapping(1, 1, flags, 'hdf);
                    legal = (flags & 1) != 0 &&
                        !((flags & 2) == 0 && (flags & 4) != 0) &&
                        ((flags & 16) != 0) == (user == 1) && (flags & 64) != 0 &&
                        (acc == 0 ? (flags & 8) != 0 :
                         acc == 1 ? (flags & 2) != 0 : (flags & 132) == 132);
                    cause = legal ? 0 : acc == 0 ? 12 : acc == 1 ? 13 : 15;
                    guest_translate(acc[1:0], user == 1 ? 0 : 1, 0, 0, cause, FRAME + 'h678);
                end

        // Sv39x4 has eleven root index bits, including both extra GPA bits.
        guest_mapping(0, 1, 'hcf, 'hdf);
        for (i = 0; i < 2048; i = i + 1)
            mem[GROOT_I + i] = pte(64'h80000000, 'hdf);
        for (i = 0; i < 2048; i = i + 1) begin
            va = ({32'b0, i[31:0]} << 30) | 'h8678;
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        end
        for (acc = 0; acc < 4; acc = acc + 1) begin
            guest_mapping(0, 1, 'hcf, 'hdf);
            va = 64'h20000008678; // bit 41: invalid Sv39x4 GPA, not a PA error
            guest_translate(acc[1:0], 1, 0, 0, acc == 0 ? 20 : acc == 1 ? 21 : 23, 0, 0, va);
            guest_mapping(1, 1, 'hcf, 'hdf);
            va = 64'h8000045678; // noncanonical VS VA wins before G walk
            before_reads = reads;
            guest_translate(acc[1:0], 1, 0, 0, acc == 0 ? 12 : acc == 1 ? 13 : 15, 0);
            if (reads != before_reads) $fatal(1, "noncanonical VS VA started G walk");
        end
        guest_mapping(1, 1, 'hcf, 'hdf);
        vsatp = 64'h8000000010040002; // valid GPA bit 40 in VS root PPN
        mem[GROOT_I + 'h401] = pte(GL1, 1);
        mem[LEAF_I] = pte(64'h10040008000, 'hcf);
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        vsatp = 64'h8000000020000002; // invalid GPA bit 41 in VS root PPN
        before_reads = reads;
        guest_translate(1, 1, 0, 0, 21, 0, 0, 64'h20000002000, 1);
        if (reads != before_reads) $fatal(1, "wide VS-PTE GPA was truncated");
        guest_mapping(1, 1, 'hcf, 'hdf);
        vsatp[63:60] = 9;
        guest_translate(1, 1, 0, 0, 13, 0); // unsupported mode cannot become Bare
        guest_mapping(0, 1, 'hcf, 'hdf);
        hgatp[63:60] = 9;
        guest_translate(1, 1, 0, 0, 21, 0, 0, va);

        // Reserved G-stage nonleaf bits, misaligned superpages and NAPOT
        // sizes use the same legality rules, but guest-page-fault classes.
        for (lvl = 1; lvl <= 2; lvl = lvl + 1)
            for (i = 0; i < 7; i = i + 1) begin
                guest_mapping(0, 1, 'hcf, 'hdf);
                expect_pa = i == 0 ? 'h10 : i == 1 ? 'h40 : i == 2 ? 'h80 :
                    i == 3 ? 64'b1 << 61 : i == 4 ? 64'b1 << 62 :
                    i == 5 ? PTE_N : 64'b1 << 54;
                if (lvl == 2) mem[GROOT_I + 1] = pte(GL1, 1 | expect_pa);
                else mem[GL1_I] = pte(GL0, 1 | expect_pa);
                guest_translate(1, 1, 0, 0, 21, 0, 0, va);
            end
        for (lvl = 1; lvl <= 2; lvl = lvl + 1) begin
            guest_mapping(0, 1, 'hcf, 'hdf);
            if (lvl == 2) mem[GROOT_I + 1] = pte(FRAME, 'hdf);
            else mem[GL1_I] = pte(FRAME, 'hdf);
            guest_translate(1, 1, 0, 0, 21, 0, 0, va);
            if (lvl == 2) mem[GROOT_I + 1] = pte(64'h80000000, PTE_N | 'hdf);
            else mem[GL1_I] = pte(64'h80000000, PTE_N | 'hdf);
            guest_translate(1, 1, 0, 0, 21, 0, 0, va);
        end
        for (i = 0; i < 16; i = i + 1) begin
            guest_mapping(0, 1, 'hcf, 'hdf);
            mem[GL0_I + 8] = pte(NAPOT_FRAME + (i << 12), PTE_N | 'hdf);
            guest_translate(1, 1, 0, 0, i == 8 ? 0 : 21, NAPOT_FRAME + 'h8678, 0, va);
        end

        // Original access classes survive an implicit VS-PTE G fault.
        // Both its GPA and RV64 read pseudoinstruction are exact.
        for (page = 2; page <= 4; page = page + 1)
            for (acc = 0; acc < 4; acc = acc + 1) begin
                guest_mapping(1, 1, 'hcf, 'hdf);
                mem[GL0_I + page] = 0;
                expect_pa = GBASE + (page << 12) + (page == 4 ? 'h228 : 0);
                guest_translate(acc[1:0], 1, 0, 1, acc == 0 ? 20 : acc == 1 ? 21 : 23,
                    0, 0, expect_pa, 1);
            end

        // HS MXR affects explicit accesses at both stages; VS MXR only VS.
        // Neither MXR nor HLVX may turn an execute-only G page into a VS-PTE read.
        guest_mapping(1, 1, 'h49, 'hd9);
        guest_translate(1, 1, 0, 0, 13, 0);
        vsstatus_mxr = 1;
        guest_translate(1, 1, 0, 0, 21, 0, 0, GBASE + 'h8678);
        guest_translate(1, 1, 0, 1, 0, FRAME + 'h678);
        vsstatus_mxr = 0; hlvx = 1;
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        mem[GL0_I + 2] = pte(ROOT, 'hd9);
        invalidate();
        guest_translate(1, 1, 0, 1, 21, 0, 0, GBASE + 'h2000, 1);
        mem[GL0_I + 2] = pte(ROOT, 'h53); // R,U,A,D=0 is sufficient for PTE read
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        mem[GL0_I + 2] = pte(ROOT, 'h13); // A=0 must fault without writing
        invalidate();
        guest_translate(1, 1, 0, 0, 21, 0, 0, GBASE + 'h2000, 1);
        guest_mapping(1, 1, 'h59, 'hd9); hlvx = 1;
        guest_translate(1, 1, 1, 0, 13, 0); // host SUM must not stand in for VS SUM
        vsstatus_sum = 1;
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        guest_translate(0, 1, 0, 0, 12, 0); // execute substitution does not authorize S fetch U
        guest_translate(1, 0, 0, 0, 0, FRAME + 'h678);

        // PBMT composition, including independent enable gates. VS nonzero
        // overrides G; disabling either gate rejects only that stage's bits.
        for (attr = 0; attr < 4; attr = attr + 1)
            for (other_attr = 0; other_attr < 4; other_attr = other_attr + 1)
                for (en = 0; en < 4; en = en + 1) begin
                    guest_mapping(1, 1, 'hcf | ({62'b0, attr[1:0]} << 61),
                        'hdf | ({62'b0, other_attr[1:0]} << 61));
                    henvcfg_pbmte = en[0]; pbmte = en[1];
                    cause = (attr == 3 || (attr != 0 && !en[0])) ? 13 :
                        (other_attr == 3 || (other_attr != 0 && !en[1])) ? 21 : 0;
                    guest_translate(1, 1, 0, 0, cause, FRAME + 'h678,
                        attr != 0 ? attr[1:0] : other_attr[1:0], GBASE + 'h8678);
                end

        // Every root, privilege/permission control and original VA/access
        // is captured on req; changing live context cannot redirect a walk.
        guest_mapping(1, 1, 'h49 | (64'b1 << 61), 'hd9 | (64'b1 << 62));
        before_single = single_reads;
        @(negedge clk); req = 1; access = 1; priv = 1; status_mxr = 1;
        @(posedge clk); #1;
        req = 0; va = 0; access = 2; priv = 0; virt = 0; hlvx = 1;
        vsatp = 0; hgatp = 0; satp = 0;
        pbmte = 0; henvcfg_pbmte = 0; status_mxr = 0;
        vsstatus_sum = 1; vsstatus_mxr = 1;
        n = 0;
        while (!done && n < 512) begin @(posedge clk); #1; n = n + 1; end
        if (!done || fault || pa != FRAME + 'h678 || pbmt != 1 ||
            fault_gva || fault_gpa_valid || fault_gpa || fault_tinst ||
            fault_gpa_is_pte || single_reads != before_single + 15)
            $fatal(1, "live guest context changed an accepted translation");
        checks = checks + 1;

        // Large pages at VS still receive a separate G translation. NAPOT
        // substitution is independently applied at either stage, all subpages.
        for (lvl = 0; lvl < 3; lvl = lvl + 1) begin
            guest_mapping(1, 1, 'hcf, 'hdf);
            mem[GROOT_I + 1] = pte(64'h80000000, 'hdf);
            if (lvl == 1) mem[L1_I] = pte(GBASE, 'hcf);
            if (lvl == 2) mem[ROOT_I] = pte(GBASE, 'hcf);
            guest_translate(1, 1, 0, 0, 0, lvl == 0 ? FRAME + 'h678 : 64'h80045678);
        end
        guest_mapping(0, 1, 'hcf, 'hdf);
        for (i = 0; i < 16; i = i + 1)
            mem[GL0_I + i] = pte(NAPOT_FRAME + 'h8000, PTE_N | 'hdf | (64'b1 << 61));
        for (page = 0; page < 16; page = page + 1) begin
            va = GBASE + (page << 12) + 'h678;
            guest_translate(1, 1, 0, 0, 0, NAPOT_FRAME + (page << 12) + 'h678, 1);
        end
        guest_mapping(1, 0, 'hcf, 'hdf);
        for (i = 0; i < 16; i = i + 1)
            mem[('h4000 >> 3) + 'h40 + i] = pte(NAPOT_FRAME + 'h8000,
                PTE_N | 'hcf | (64'b1 << 62));
        for (page = 0; page < 16; page = page + 1) begin
            va = 'h40000 + (page << 12) + 'h678;
            guest_translate(1, 1, 0, 0, 0, NAPOT_FRAME + (page << 12) + 'h678, 2);
        end

        // Invalid physical PTE/final addresses keep access-fault priority,
        // never alias their low 32 bits and never report a spurious GPA.
        for (acc = 0; acc < 4; acc = acc + 1) begin
            guest_mapping(1, 1, 'hcf, 'hdf);
            hgatp = 64'h800000000018000c; // inaccessible high physical G root
            before_reads = reads;
            guest_translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            if (reads != before_reads) $fatal(1, "high G root PA truncated onto AXI");
            guest_mapping(1, 1, 'hcf, 'hdf);
            mem[GL0_I + 8] = pte(64'h180008000, 'hdf);
            guest_translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            guest_mapping(1, 1, 'hcf, 'hdf);
            mem[GL0_I + 2] = pte(0, 'hdf); // physical VS-PTE location is vacant
            guest_translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
            for (page = 0; page < 4; page = page + 1) begin
                guest_mapping(1, 1, 'hcf, 'hdf);
                error_line = page == 0 ? GROOT[31:0] + 8 : page == 1 ? GL1[31:0] :
                    page == 2 ? GL0[31:0] + 16 : ROOT[31:0];
                error_beat = 0;
                guest_translate(acc[1:0], 1, 0, 0, acc == 0 ? 1 : acc == 1 ? 5 : 7, 0);
                error_line = 32'hffffffff;
            end
        end

        for (i = 1; i <= 15; i = i + 1) guest_flush_read(i);
        guest_flush_phase(5, 1); // VS start
        guest_flush_phase(4, 2); // G start
        guest_flush_phase(1, 1); // VS PTE-address formation
        guest_flush_phase(1, 2); // G PTE-address formation
        guest_flush_phase(2, 1); // translated physical VS-PTE address
        guest_flush_phase(2, 2); // physical G-PTE address
        for (i = 1; i <= 15; i = i + 1) guest_flush_read(i, 1);
        guest_flush_phase(5, 1, 1);
        guest_flush_phase(4, 2, 1);
        guest_flush_phase(1, 1, 1);
        guest_flush_phase(1, 2, 1);
        guest_flush_phase(2, 1, 1);
        guest_flush_phase(2, 2, 1);

        // A redirect can coincide with request acceptance, including a
        // host TLB hit. It still completes the handshake without a result.
        for (i = 0; i < 3; i = i + 1) begin
            guest_with_host_cache();
            if (i != 2) virt = 0;
            if (i == 1) begin satp = 0; va = FRAME; end
            keep_tlb = dut.tlb_v; keep_pwc = dut.pwc_v; before_reads = reads;
            @(negedge clk); req = 1; cancel = 1;
            @(posedge clk); #1; req = 0; cancel = 0;
            if (!done || busy || fault || pbmt || pa || fault_gva || fault_gpa_valid ||
                fault_gpa || fault_tinst || fault_gpa_is_pte ||
                reads != before_reads || dut.tlb_v != keep_tlb || dut.pwc_v != keep_pwc)
                $fatal(1, "cancel+req in IDLE failed mode=%0d", i);
            checks = checks + 1;
        end

        // Cancellation and a newly granted safety gate can coincide. The
        // redirect wins: neither host-IO nor G-PBMT-IO PTE reads may launch.
        for (page = 0; page < 2; page = page + 1) begin
            guest_with_host_cache();
            if (page == 0) begin virt = 0; satp = 64'h8000200000002002; end
            else mem[GL0_I + 2] = pte(ROOT, 'hdf | (64'b1 << 62));
            keep_tlb = dut.tlb_v; keep_pwc = dut.pwc_v;
            before_reads = reads; before_io = io_reads; pte_read_safe = 0;
            @(negedge clk); req = 1; access = 0; priv = 1;
            @(posedge clk); #1; req = 0;
            n = 0;
            while (!pte_io_pending && n < 128) begin @(posedge clk); #1; n = n + 1; end
            if (!pte_io_pending || reads != before_reads + (page == 0 ? 0 : 3))
                $fatal(1, "cancel-before-IO fixture missed safety wait");
            @(negedge clk); cancel = 1; pte_read_safe = 1;
            @(posedge clk); #1;
            @(negedge clk); cancel = 0;
            if (busy || !done || fault || pbmt || pte_io_pending || arvalid ||
                fault_gva || fault_gpa_valid || fault_gpa || fault_tinst || fault_gpa_is_pte ||
                reads != before_reads + (page == 0 ? 0 : 3) || io_reads != before_io ||
                dut.tlb_v != keep_tlb || dut.pwc_v != keep_pwc)
                $fatal(1, "redirect allowed an IO PTE side effect");
            checks = checks + 1;
        end

        // Neither fence nor redirect can withdraw an asserted AR under
        // backpressure; that transaction must complete and be discarded.
        for (en = 0; en < 2; en = en + 1) begin
            if (en) guest_with_host_cache();
            else guest_mapping(1, 1, 'hcf, 'hdf);
            keep_tlb = en ? dut.tlb_v : 4'b0; keep_pwc = en ? dut.pwc_v : 4'b0;
            before_reads = reads; stall_ar = 1;
            @(negedge clk); req = 1; access = 1; priv = 1;
            @(posedge clk); #1; req = 0;
            n = 0;
            while (!arvalid && n < 64) begin @(posedge clk); #1; n = n + 1; end
            if (!arvalid) $fatal(1, "held AR not reached");
            @(negedge clk); flush = !en; cancel = en != 0;
            @(posedge clk); #1;
            @(negedge clk); flush = 0; cancel = 0;
            repeat (5) begin
                @(posedge clk); #1;
                if (!arvalid || !busy || done || reads != before_reads)
                    $fatal(1, "flush withdrew AR or completed without draining it");
            end
            @(negedge clk); stall_ar = 0;
            n = 0;
            while (busy && n < 128) begin @(posedge clk); #1; n = n + 1; end
            if (busy || fault || pbmt || fault_gva || fault_gpa_valid ||
                fault_gpa || fault_tinst || fault_gpa_is_pte ||
                dut.tlb_v != keep_tlb || dut.pwc_v != keep_pwc || reads != before_reads + 1)
                $fatal(1, "poisoned AR did not drain exactly once");
            checks = checks + 1;
        end
        // Immediate hot hits, without xRET/fences between the requests.
        // Every translated mode combination retains 4 KiB offset bits.
        for (i = 1; i < 4; i = i + 1) begin
            guest_mapping(i[0], i[1], 'hcf, 'hdf);
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            for (acc = 0; acc < 4; acc = acc + 1)
                guest_hot_translate(acc[1:0], 1, 0, 0, 0, FRAME + 'h678);
            va = (va & ~64'hfff) | 'h9ab;
            guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h9ab);
            guest_hot_translate(1, 0, 0, 0, i[0] ? 13 : 0, FRAME + 'h9ab);
        end

        // Both retained D bits are independent: load -> store must report
        // VS before G, with the exact cached GPA on a G-stage fault.
        for (vsd = 0; vsd < 2; vsd = vsd + 1)
            for (gd = 0; gd < 2; gd = gd + 1) begin
                guest_mapping(1, 1, 'h4f | (vsd << 7), 'h5f | (gd << 7));
                guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
                cause = !vsd ? 15 : !gd ? 23 : 0;
                guest_hot_translate(2, 1, 0, 0, cause, FRAME + 'h678, 0, GBASE + 'h8678);
                if (vsd && !gd) begin
                    va = (va & ~64'hfff) | 'hbcd;
                    guest_hot_translate(2, 1, 0, 0, 23, 0, 0, GBASE + 'h8bcd);
                    va = (va & ~64'hfff) | 'h678;
                end
                guest_hot_translate(3, 1, 0, 0, 0, FRAME + 'h678); // management ignores D
                guest_hot_translate(0, 1, 0, 0, 0, FRAME + 'h678);
                mem[LEAF_I] = pte(GBASE + 'h8000, 'hcf);
                mem[GL0_I + 8] = pte(FRAME, 'hdf);
                signature_enable = 0; // stale hits are permitted until invalidation
                guest_translate(2, 1, 0, 0, GUEST_TLB_ENABLE ? cause : 0,
                    FRAME + 'h678, 0, GBASE + 'h8678);
                signature_enable = 1;
                invalidate();
                guest_translate(2, 1, 0, 0, 0, FRAME + 'h678);
                guest_hot_translate(2, 1, 0, 0, 0, FRAME + 'h678);
            end

        // Shared host/VS MXR and HLVX are re-evaluated, not access-tagged.
        guest_mapping(1, 1, 'h49, 'hd9);
        guest_translate(1, 1, 0, 1, 0, FRAME + 'h678);
        guest_hot_translate(1, 1, 0, 0, 13, 0);
        vsstatus_mxr = 1;
        guest_hot_translate(1, 1, 0, 0, 21, 0, 0, GBASE + 'h8678);
        vsstatus_mxr = 0; hlvx = 1;
        guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        guest_hot_translate(1, 1, 0, 1, 0, FRAME + 'h678);
        hlvx = 0;
        guest_hot_translate(2, 1, 0, 1, 15, 0);
        guest_hot_translate(3, 1, 0, 1, 0, FRAME + 'h678);
        guest_hot_translate(3, 1, 0, 0, 15, 0);
        guest_mapping(1, 1, 'hdf, 'hdf); // VS U page, cached by VU
        guest_translate(1, 0, 0, 0, 0, FRAME + 'h678);
        guest_hot_translate(1, 1, 0, 0, 13, 0);
        guest_hot_translate(1, 1, 1, 0, 13, 0); // host SUM does not authorize VS
        vsstatus_sum = 1;
        guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        guest_hot_translate(0, 1, 0, 0, 12, 0);
        guest_hot_translate(0, 0, 0, 0, 0, FRAME + 'h678);

        // Final PMA and HLVX execute permission are checked on cache hits.
        // Neither G nor VS PBMT can make a device executable or ROM writable.
        for (attr = 0; attr < 3; attr = attr + 1) begin
            guest_mapping(1, 1, 'hcf | ({62'b0, attr[1:0]} << 61), 'hdf);
            mem[GL0_I + 8] = pte(64'h10000000, 'hdf);
            guest_translate(1, 1, 0, 0, 0, 'h10000678, attr[1:0]);
            guest_hot_translate(0, 1, 0, 0, 1, 0);
            hlvx = 1;
            guest_hot_translate(1, 1, 0, 0, 5, 0);
            hlvx = 0;
            guest_hot_translate(2, 1, 0, 0, 0, 'h10000678, attr[1:0]);
            guest_mapping(1, 1, 'hcf, 'hdf | ({62'b0, attr[1:0]} << 61));
            mem[GL0_I + 8] = pte(64'h1000, 'hdf | ({62'b0, attr[1:0]} << 61));
            guest_translate(1, 1, 0, 0, 0, 'h1678, attr[1:0]);
            guest_hot_translate(2, 1, 0, 0, 7, 0);
        end

        // PBMTE changes must rewalk even when final leaf PBMTs are both
        // zero: a nonzero G PBMT on any implicit VS-PTE mapping can fail.
        for (page = 2; page <= 4; page = page + 1)
            for (attr = 1; attr <= 2; attr = attr + 1) begin
                guest_mapping(1, 1, 'hcf, 'hdf);
                mem[GL0_I + page] = pte(64'h80000000 + (page << 12),
                    'hdf | ({62'b0, attr[1:0]} << 61));
                guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
                guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
                pbmte = 0; henvcfg_pbmte = 0; before_reads = reads;
                expect_pa = GBASE + (page << 12) + (page == 4 ? 'h228 : 0);
                guest_translate(1, 1, 0, 0, 21, 0, 0, expect_pa, 1);
                if (reads == before_reads) $fatal(1, "implicit PBMTE dependency reused combined hit");
                pbmte = 1; henvcfg_pbmte = 1;
                // The failed context change must preserve the prior bank.
                guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            end
        for (page = 0; page < 2; page = page + 1) begin
            guest_mapping(1, 1, 'hcf | (page == 0 ? 64'b1 << 61 : 0),
                'hdf | (page == 1 ? 64'b1 << 62 : 0));
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678, page == 0 ? 1 : 2);
            if (page == 0) henvcfg_pbmte = 0;
            else pbmte = 0;
            before_reads = reads;
            guest_translate(1, 1, 0, 0, page == 0 ? 13 : 21, 0, 0, GBASE + 'h8678);
            if (reads == before_reads) $fatal(1, "leaf PBMTE key change did not rewalk");
            henvcfg_pbmte = 1; pbmte = 1;
            guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678, page == 0 ? 1 : 2);
        end

        // Every shared context field participates. Alternate roots use
        // distinct full addresses whose low bits alias this fixture's RAM.
        guest_mapping(1, 1, 'hcf, 'hdf);
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        for (i = 0; i < 6; i = i + 1) begin
            case (i)
                0: vsatp = vsatp ^ (64'b1 << 44);
                1: hgatp = hgatp ^ (64'b1 << 44);
                2: vsatp = vsatp + 16;
                3: hgatp = hgatp + 16;
                4: henvcfg_pbmte = 0;
                5: pbmte = 0;
            endcase
            before_reads = reads;
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            if (reads == before_reads) $fatal(1, "guest context field %0d did not miss", i);
            guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        end
        guest_mapping(1, 1, 'hcf, 'hdf);
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        for (i = 44; i <= 59; i = i + 1) begin
            vsatp = vsatp ^ (64'b1 << i); before_reads = reads;
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            if (reads == before_reads) $fatal(1, "guest ASID bit %0d was not tagged", i-44);
            guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        end
        for (i = 44; i <= 57; i = i + 1) begin
            hgatp = hgatp ^ (64'b1 << i); before_reads = reads;
            guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
            if (reads == before_reads) $fatal(1, "guest VMID bit %0d was not tagged", i-44);
            guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        end
        // The high address legality checks must precede a shortened-tag hit.
        guest_mapping(1, 1, 'hcf, 'hdf);
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        va = va | (64'b1 << 41); before_reads = reads;
        guest_translate(1, 1, 0, 0, 13, 0);
        if (reads != before_reads) $fatal(1, "noncanonical guest alias started a walk");
        guest_mapping(0, 1, 'hcf, 'hdf);
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        va = va | (64'b1 << 41); before_reads = reads;
        guest_translate(1, 1, 0, 0, 21, 0, 0, va);
        if (reads != before_reads) $fatal(1, "wide GPA alias started a walk");
        guest_mapping(1, 1, 'hcf, 'hdf);
        mem[ROOT_I + 1] = pte(GBASE + 'h3000, 1);
        mem[('h4000 >> 3) + 8] = pte(GBASE + 'h8000, 'hcf);
        va = GBASE + 'h8678;
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        vsatp = 0; before_reads = reads;
        guest_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        if (reads == before_reads) $fatal(1, "VS mode change reused guest hit");
        guest_hot_translate(1, 1, 0, 0, 0, FRAME + 'h678);
        hgatp = 0;
        guest_translate(1, 1, 0, 0, 5, 0); // both Bare: full GPA is physically vacant

        // Resolved subpage entries do not claim their entire superpage or
        // NAPOT extent; each newly touched 4 KiB subpage fills independently.
        for (lvl = 0; lvl < 3; lvl = lvl + 1) begin
            guest_mapping(0, 1, 'hcf, 'hdf);
            if (lvl == 1) mem[GL1_I] = pte(64'h80000000, 'hdf);
            if (lvl == 2) mem[GROOT_I + 1] = pte(64'h80000000, 'hdf);
            for (page = 8; page < 14; page = page + 1) begin
                va = GBASE + (page << 12) + 'h678; before_reads = reads;
                guest_translate(1, 1, 0, 0, 0, 64'h80000000 + (page << 12) + 'h678);
                if (reads == before_reads) $fatal(1, "guest cache reused a different superpage subpage");
                guest_hot_translate(1, 1, 0, 0, 0, 64'h80000000 + (page << 12) + 'h678);
            end
        end
        guest_mapping(0, 1, 'hcf, 'hdf);
        for (i = 0; i < 16; i = i + 1)
            mem[GL0_I + i] = pte(NAPOT_FRAME + 'h8000, PTE_N | 'hdf | (64'b1 << 61));
        for (page = 0; page < 16; page = page + 1) begin
            va = GBASE + (page << 12) + 'h678; before_reads = reads;
            guest_translate(1, 1, 0, 0, 0, NAPOT_FRAME + (page << 12) + 'h678, 1);
            if (reads == before_reads) $fatal(1, "NAPOT subpage was not independently filled");
            guest_hot_translate(1, 1, 0, 0, 0, NAPOT_FRAME + (page << 12) + 'h678, 1);
        end
        va = GBASE + 'h678; before_reads = reads;
        guest_translate(1, 1, 0, 0, 0, NAPOT_FRAME + 'h678, 1);
        if (reads == before_reads) $fatal(1, "four-entry guest replacement did not evict oldest subpage");

        if (GUEST_TLB_ENABLE && dut.gtlb_v !== 4'b1111)
            $fatal(1, "guest bank did not retain four resolved entries");
        hgatp = hgatp ^ (64'b1 << 44);
        guest_translate(1, 1, 0, 0, 0, NAPOT_FRAME + 'h678, 1);
        if (GUEST_TLB_ENABLE && dut.gtlb_v !== 4'b0001)
            $fatal(1, "successful context replacement retained old-context entries");

        guest_cancel_hot(0);
        guest_cancel_hot(5);
        guest_cancel_hot(6);
        guest_cancel_hot(5, 0, 1); // a different context canceled before walking
        guest_cancel_hot(5, 1);
        guest_cancel_hot(6, 1);
        guest_cancel_context_fill(0);
        guest_cancel_context_fill(1);

        $display("SV39-SVADE-SVNAPOT-SVPBMT-H PASS checks=%0d guest_cache=%0d signature=%h (host/two-stage, exact IO PTEs, no writes, flush/cancel)",
            checks, GUEST_TLB_ENABLE, result_signature);
        finished = 1;
        if (STOP_ON_FINISH) $finish;
    end
endmodule

// Same maintained scenarios and independent memory responders, with only
// the elaboration-time cache setting changed. Latency/read counts may differ;
// architectural completion sequences must agree outside explicit stale tests.
module karu_sv39_compare_tb;
    wire cached_done, uncached_done;
    wire [63:0] cached_signature, uncached_signature;
    wire [31:0] cached_count, uncached_count;
    karu_sv39_tb #(.GUEST_TLB_ENABLE(1), .STOP_ON_FINISH(0)) cached (
        .finished(cached_done), .result_signature(cached_signature), .result_count(cached_count));
    karu_sv39_tb #(.GUEST_TLB_ENABLE(0), .STOP_ON_FINISH(0)) uncached (
        .finished(uncached_done), .result_signature(uncached_signature), .result_count(uncached_count));
    initial begin
        wait (cached_done && uncached_done);
        if (cached_count !== uncached_count || cached_signature !== uncached_signature)
            $fatal(1, "cached/uncached differential mismatch count=%0d/%0d signature=%h/%h",
                cached_count, uncached_count, cached_signature, uncached_signature);
        $display("SV39-GUEST-CACHE-DIFF PASS translations=%0d signature=%h", cached_count, cached_signature);
        $finish;
    end
endmodule
