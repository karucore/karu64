// Instruction-fetch boundaries, informative VA/GPA fault metadata and
// stale-response draining. Translation and AXI are independently backpressured.
`include "karu_axi_defs.vh"
`timescale 1ns/1ps

module tb_ifu;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg redir = 0;
    reg [63:0] redir_pc = 0;
    wire ins_valid;
    wire [63:0] ins_pc;
    wire [31:0] ins_w;
    reg take = 0;
    reg fetch_safe = 1;
    reg [1:0] xlate_pbmt = 0;
    wire [1:0] ar_pbmt;
    wire xlate_req;
    wire [63:0] xlate_va;
    reg xlate_busy = 0, xlate_done = 0, xlate_fault = 0;
    reg [63:0] xlate_fault_va = 0, xlate_fault_cause = 0, xlate_pa = 0;
    reg xlate_fault_gva = 0, xlate_fault_gpa_valid = 0;
    reg [63:0] xlate_fault_gpa = 0, xlate_fault_tinst = 0;
    reg xlate_fault_gpa_is_pte = 0;
    wire fault_valid;
    wire [63:0] fault_va, fault_cause;
    wire fault_gva, fault_gpa_valid, fault_gpa_is_pte;
    wire [63:0] fault_gpa, fault_tinst;
    wire [`AXI_ID_W-1:0] arid;
    wire [`AXI_ADDR_W-1:0] araddr;
    wire [`AXI_LEN_W-1:0] arlen;
    wire [`AXI_SIZE_W-1:0] arsize;
    wire [`AXI_BURST_W-1:0] arburst;
    wire [`AXI_PROT_W-1:0] arprot;
    wire arvalid;
    reg arready = 0;
    reg [`AXI_ID_W-1:0] rid = 0;
    reg [`AXI_DATA_W-1:0] rdata = 0;
    reg [`AXI_RESP_W-1:0] rresp = 0;
    reg rlast = 1, rvalid = 0;
    wire rready;
    karu_ifu dut (.*);

    integer checks = 0;
    integer offset, error_kind, implicit_pte;
    localparam [63:0] PAGE = 64'hffff_ffc0_0000_4000;
    localparam [63:0] DEST = 64'hffff_ffc0_0000_8002;
    localparam [63:0] PA0 = 64'h8000_4000;
    localparam [63:0] GPA0 = 64'h0000_0002_5000_8000;
    localparam [63:0] PTE_GPA = 64'h0000_0003_7000_0518;

    task automatic set_xlate_metadata(input bit gva, input bit gpa_valid,
                                      input [63:0] gpa, input [63:0] tinst,
                                      input bit is_pte);
        xlate_fault_gva = gva;
        xlate_fault_gpa_valid = gpa_valid;
        xlate_fault_gpa = gpa;
        xlate_fault_tinst = tinst;
        xlate_fault_gpa_is_pte = is_pte;
    endtask

    task automatic expect_metadata(input bit gva, input bit gpa_valid,
                                   input [63:0] gpa, input [63:0] tinst,
                                   input bit is_pte);
        if (fault_gva !== gva || fault_gpa_valid !== gpa_valid || fault_gpa !== gpa
            || fault_tinst !== tinst || fault_gpa_is_pte !== is_pte)
            $fatal(1, "fault metadata gva=%b valid=%b gpa=%h tinst=%h pte=%b expected %b %b %h %h %b",
                   fault_gva, fault_gpa_valid, fault_gpa, fault_tinst,
                   fault_gpa_is_pte, gva, gpa_valid, gpa, tinst, is_pte);
        checks = checks + 1;
    endtask

    task automatic reset_at(input [63:0] address);
        @(negedge clk);
        rst = 1; redir = 0; take = 0;
        fetch_safe = 1; xlate_pbmt = 0;
        xlate_busy = 0; xlate_done = 0; xlate_fault = 0;
        set_xlate_metadata(0, 0, 0, 0, 0);
        arready = 0; rvalid = 0; rresp = 0;
        repeat (2) @(negedge clk);
        rst = 0; redir = 1; redir_pc = address;
        @(negedge clk); redir = 0;
        expect_metadata(0, 0, 0, 0, 0);
    endtask

    task automatic redirect_to(input [63:0] address);
        @(negedge clk); redir = 1; redir_pc = address;
        @(negedge clk); redir = 0;
        expect_metadata(0, 0, 0, 0, 0);
    endtask

    task automatic expect_request(input [63:0] address);
        while (!xlate_req) @(negedge clk);
        if (xlate_va !== address || fault_valid)
            $fatal(1, "translation request: got %h expected %h", xlate_va, address);
        xlate_busy = 1;
        checks = checks + 1;
    endtask

    task automatic translate_info(input [63:0] pa, input bit fault,
                                  input [63:0] cause, input bit gva,
                                  input bit gpa_valid, input [63:0] gpa,
                                  input [63:0] tinst, input bit is_pte);
        @(negedge clk);
        xlate_pa = pa; xlate_fault = fault;
        xlate_fault_va = xlate_va; xlate_fault_cause = cause;
        set_xlate_metadata(gva, gpa_valid, gpa, tinst, is_pte);
        xlate_done = 1;
        @(negedge clk); xlate_done = 0; xlate_busy = 0;
        // The result must remain registered after the walker returns to idle.
        set_xlate_metadata(0, 0, 0, 0, 0);
        xlate_fault_va = 0; xlate_fault_cause = 0;
    endtask

    task automatic translate(input [63:0] pa, input bit fault,
                             input [63:0] cause);
        translate_info(pa, fault, cause, 0, 0, 0, 0, 0);
    endtask

    task automatic expect_ar(input [31:0] address);
        while (!arvalid) @(negedge clk);
        if (araddr !== address || arid !== 0 || arprot !== 0 || arlen !== 0
            || arsize !== `AXI_SIZE_8B || arburst !== `AXI_BURST_INCR)
            $fatal(1, "AXI request: got %h expected %h", araddr, address);
        checks = checks + 1;
    endtask

    task automatic accept_ar;
        arready = 1;
        @(negedge clk); arready = 0;
    endtask

    task automatic reply(input [63:0] data, input [1:0] response);
        @(negedge clk);
        rdata = data; rresp = response; rvalid = 1;
        while (!rready) @(negedge clk);
        @(negedge clk); rvalid = 0;
    endtask

    task automatic fetch(input [63:0] va, input [63:0] pa, input [63:0] data);
        expect_request(va);
        translate(pa, 0, 0);
        expect_ar(pa[31:0]);
        accept_ar();
        reply(data, `AXI_RESP_OKAY);
    endtask

    task automatic expect_instruction(input [63:0] address,
                                      input [31:0] word_value,
                                      input bit compressed);
        while (!ins_valid && !fault_valid) begin
            if (xlate_req || arvalid)
                $fatal(1, "complete instruction at %h requested more bytes", address);
            @(negedge clk);
        end
        if (fault_valid || ins_pc !== address
            || (compressed ? ins_w[15:0] !== word_value[15:0] : ins_w !== word_value))
            $fatal(1, "instruction pc=%h word=%h fault=%b expected pc=%h word=%h",
                   ins_pc, ins_w, fault_valid, address, word_value);
        expect_metadata(0, 0, 0, 0, 0);
        checks = checks + 1;
    endtask

    task automatic consume;
        take = 1;
        @(negedge clk); take = 0;
    endtask

    task automatic expect_fault_info(input [63:0] instruction_pc,
                                     input [63:0] address, input [63:0] cause,
                                     input bit gva, input bit gpa_valid,
                                     input [63:0] gpa, input [63:0] tinst,
                                     input bit is_pte);
        while (!fault_valid) @(negedge clk);
        if (ins_pc !== instruction_pc || fault_va !== address || fault_cause !== cause)
            $fatal(1, "fault pc=%h va=%h cause=%0d expected pc=%h va=%h cause=%0d",
                   ins_pc, fault_va, fault_cause, instruction_pc, address, cause);
        expect_metadata(gva, gpa_valid, gpa, tinst, is_pte);
        repeat (3) begin
            @(negedge clk);
            if (!fault_valid || fault_va !== address || fault_cause !== cause
                || xlate_req || arvalid)
                $fatal(1, "fault not held until redirect");
            expect_metadata(gva, gpa_valid, gpa, tinst, is_pte);
        end
        checks = checks + 1;
    endtask

    task automatic expect_fault(input [63:0] instruction_pc,
                                input [63:0] address, input [63:0] cause);
        expect_fault_info(instruction_pc, address, cause, 0, 0, 0, 0, 0);
    endtask

    task automatic expect_quiet(input integer cycles);
        repeat (cycles) begin
            @(negedge clk);
            if (xlate_req || arvalid || fault_valid)
                $fatal(1, "unexpected fetch/fault while current instruction is complete");
            expect_metadata(0, 0, 0, 0, 0);
        end
        checks = checks + 1;
    endtask

    initial begin
        // A C.J at the end of a page is complete without touching the next
        // page. Hold decode, then take a redirect: no successor request.
        reset_at(PAGE + 64'hffe);
        fetch(PAGE + 64'hff8, PA0 + 64'hff8, 64'ha001_0001_0001_0001);
        expect_instruction(PAGE + 64'hffe, 32'ha001, 1);
        expect_quiet(5);
        redirect_to(DEST);
        fetch(DEST & ~64'd7, PA0, 64'h0001_0001_0013_0001);
        expect_instruction(DEST, 32'h0001_0013, 0);

        // Walking from the start of a quad reaches its compressed tail
        // without a spurious request. Decoded instruction length, not the
        // quad boundary, determines when another fetch is needed.
        reset_at(PAGE);
        fetch(PAGE, PA0, 64'h0001_0001_0001_0001);
        for (offset = 0; offset < 8; offset = offset + 2) begin
            expect_instruction(PAGE + 64'(offset), 32'h0001, 1);
            expect_quiet(2);
            consume();
        end
        fetch(PAGE + 64'd8, PA0 + 64'd8, 64'h0001_0001_1234_0013);
        expect_instruction(PAGE + 64'd8, 32'h1234_0013, 0);
        consume();
        expect_instruction(PAGE + 64'd12, 32'h0001, 1);

        // Sequential compressed-tail consumption starts the next request
        // only after the PC advances. A following fault belongs to that PC.
        reset_at(PAGE + 64'hffe);
        fetch(PAGE + 64'hff8, PA0 + 64'hff8, 64'h0001_0001_0001_0001);
        expect_instruction(PAGE + 64'hffe, 32'h0001, 1);
        expect_quiet(3);
        consume();
        expect_request(PAGE + 64'h1000);
        translate(0, 1, 12);
        expect_fault(PAGE + 64'h1000, PAGE + 64'h1000, 12);

        // A 32-bit instruction really does need the upper halfword. Verify
        // assembly, then reuse the filled next quad after consuming it.
        reset_at(PAGE + 64'hffe);
        fetch(PAGE + 64'hff8, PA0 + 64'hff8, 64'h0013_0001_0001_0001);
        if (ins_valid) $fatal(1, "incomplete 32-bit instruction was exposed");
        fetch(PAGE + 64'h1000, PA0 + 64'h2000, 64'h0001_0001_0001_1234);
        expect_instruction(PAGE + 64'hffe, 32'h1234_0013, 0);
        consume();
        expect_instruction(PAGE + 64'h1002, 32'h0001, 1);
        consume();
        expect_instruction(PAGE + 64'h1004, 32'h0001, 1);
        consume();
        expect_instruction(PAGE + 64'h1006, 32'h0001, 1);
        expect_quiet(3);

        // Every possible halfword offset in the first quad. Translation
        // page faults, PTW access faults, AXI SLVERR and DECERR retain the
        // full virtual address rather than the aligned VA or the mapped PA.
        for (error_kind = 0; error_kind < 4; error_kind = error_kind + 1) begin
            for (offset = 0; offset < 8; offset = offset + 2) begin
                reset_at(PAGE + 64'(offset));
                expect_request(PAGE);
                if (error_kind < 2) begin
                    translate(0, 1, error_kind == 0 ? 64'd12 : 64'd1);
                end else begin
                    translate(PA0, 0, 0);
                    expect_ar(PA0[31:0]); accept_ar();
                    reply(0, error_kind == 2 ? `AXI_RESP_SLVERR : `AXI_RESP_DECERR);
                end
                expect_fault(PAGE + 64'(offset), PAGE + 64'(offset),
                             error_kind == 0 ? 64'd12 : 64'd1);
            end
        end

        // The faulting second half starts at the next page, but the EPC
        // remains at the first half. Cover translation and both bus errors.
        for (error_kind = 0; error_kind < 4; error_kind = error_kind + 1) begin
            reset_at(PAGE + 64'hffe);
            fetch(PAGE + 64'hff8, PA0 + 64'hff8, 64'h0013_0001_0001_0001);
            expect_request(PAGE + 64'h1000);
            if (error_kind < 2) begin
                translate(0, 1, error_kind == 0 ? 64'd12 : 64'd1);
            end else begin
                translate(PA0 + 64'h2000, 0, 0);
                expect_ar(PA0[31:0] + 32'h2000); accept_ar();
                reply(0, error_kind == 2 ? `AXI_RESP_SLVERR : `AXI_RESP_DECERR);
            end
            expect_fault(PAGE + 64'hffe, PAGE + 64'h1000,
                         error_kind == 0 ? 64'd12 : 64'd1);
        end

        // H final-access faults must identify the same exact instruction byte
        // in VA and GPA. Implicit VS-PTE faults instead preserve the PTE GPA
        // and the RV64 read pseudoinstruction, even at a nonzero PC offset.
        // GPA and HPA deliberately differ, including GPA bits above AXI width.
        for (implicit_pte = 0; implicit_pte < 2; implicit_pte = implicit_pte + 1) begin
            for (offset = 0; offset < 8; offset = offset + 2) begin
                reset_at(PAGE + 64'(offset));
                expect_request(PAGE);
                translate_info(PA0, 1, 20, 1, 1,
                               implicit_pte != 0 ? PTE_GPA : GPA0,
                               implicit_pte != 0 ? 64'h3000 : 64'b0, implicit_pte != 0);
                expect_fault_info(PAGE + 64'(offset), PAGE + 64'(offset), 20,
                                  1, 1, implicit_pte != 0 ? PTE_GPA : GPA0 + 64'(offset),
                                  implicit_pte != 0 ? 64'h3000 : 64'b0, implicit_pte != 0);
            end

            // The second half of a split 32-bit instruction is on a distinct
            // guest-physical page; retain the first-half EPC and second-half VA.
            reset_at(PAGE + 64'hffe);
            fetch(PAGE + 64'hff8, PA0 + 64'hff8, 64'h0013_0001_0001_0001);
            expect_request(PAGE + 64'h1000);
            translate_info(0, 1, 20, 1, 1,
                           implicit_pte != 0 ? PTE_GPA : GPA0 + 64'h5000,
                           implicit_pte != 0 ? 64'h3000 : 64'b0, implicit_pte != 0);
            expect_fault_info(PAGE + 64'hffe, PAGE + 64'h1000, 20, 1, 1,
                              implicit_pte != 0 ? PTE_GPA : GPA0 + 64'h5000,
                              implicit_pte != 0 ? 64'h3000 : 64'b0, implicit_pte != 0);

            // A compressed tail has no second-half translation at all. Only
            // after consumption can the following instruction carry metadata.
            reset_at(PAGE + 64'hffe);
            fetch(PAGE + 64'hff8, PA0 + 64'hff8, 64'h0001_0001_0001_0001);
            expect_instruction(PAGE + 64'hffe, 32'h0001, 1);
            set_xlate_metadata(1, 1, PTE_GPA, 64'h3000, 1);
            expect_quiet(3);
            consume();
            expect_request(PAGE + 64'h1000);
            translate_info(0, 1, 20, 1, 1,
                           implicit_pte != 0 ? PTE_GPA : GPA0,
                           implicit_pte != 0 ? 64'h3000 : 64'b0, implicit_pte != 0);
            expect_fault_info(PAGE + 64'h1000, PAGE + 64'h1000, 20, 1, 1,
                              implicit_pte != 0 ? PTE_GPA : GPA0,
                              implicit_pte != 0 ? 64'h3000 : 64'b0, implicit_pte != 0);
        end

        // Cancel the second translation of a split instruction, both before
        // and coincident with its completion. A subsequent fault at the new
        // PC must use the new byte offset and new metadata, never the old GPA.
        for (implicit_pte = 0; implicit_pte < 2; implicit_pte = implicit_pte + 1) begin
            for (error_kind = 0; error_kind < 2; error_kind = error_kind + 1) begin
                reset_at(PAGE + 64'hffe);
                fetch(PAGE + 64'hff8, PA0 + 64'hff8, 64'h0013_0001_0001_0001);
                expect_request(PAGE + 64'h1000);
                if (error_kind == 0) begin
                    redirect_to(DEST);
                    expect_quiet(2);
                    translate_info(0, 1, 20, 1, 1,
                                   implicit_pte != 0 ? PTE_GPA : GPA0 + 64'h5000,
                                   implicit_pte != 0 ? 64'h3000 : 64'b0,
                                   implicit_pte != 0);
                end else begin
                    @(negedge clk);
                    redir = 1; redir_pc = DEST;
                    xlate_done = 1; xlate_fault = 1;
                    xlate_fault_va = PAGE + 64'h1000; xlate_fault_cause = 20;
                    set_xlate_metadata(1, 1,
                                       implicit_pte != 0 ? PTE_GPA : GPA0 + 64'h5000,
                                       implicit_pte != 0 ? 64'h3000 : 64'b0,
                                       implicit_pte != 0);
                    @(negedge clk);
                    redir = 0; xlate_done = 0; xlate_busy = 0;
                    set_xlate_metadata(0, 0, 0, 0, 0);
                end
                expect_metadata(0, 0, 0, 0, 0);
                expect_request(DEST & ~64'd7);
                translate_info(0, 1, 20, 1, 1, GPA0, 0, 0);
                expect_fault_info(DEST, DEST, 20, 1, 1, GPA0 + 64'd2, 0, 0);
            end
        end

        // A VS-stage page/access fault still has a guest VA but no reportable
        // GPA. Invalid GPA payload/discriminator must not leak into the trap.
        for (error_kind = 0; error_kind < 2; error_kind = error_kind + 1) begin
            reset_at(PAGE + 64'd6);
            expect_request(PAGE);
            translate_info(0, 1, error_kind == 0 ? 64'd12 : 64'd1,
                           1, 0, PTE_GPA, 0, 1);
            expect_fault_info(PAGE + 64'd6, PAGE + 64'd6,
                              error_kind == 0 ? 64'd12 : 64'd1,
                              1, 0, 0, 0, 0);
        end

        // Zero is a valid final GPA, not a sentinel that loses byte offset.
        reset_at(PAGE + 64'd2);
        expect_request(PAGE);
        translate_info(0, 1, 20, 1, 1, 0, 0, 0);
        expect_fault_info(PAGE + 64'd2, PAGE + 64'd2, 20, 1, 1, 2, 0, 0);

        // Retire a metadata-bearing fault via redirect, then take an unrelated
        // AXI fault. Neither old state nor a successful translator's irrelevant
        // metadata may contaminate that physical access fault.
        for (error_kind = 0; error_kind < 2; error_kind = error_kind + 1) begin
            reset_at(PAGE + 64'd6);
            expect_request(PAGE);
            translate_info(0, 1, 20, 1, 1, PTE_GPA, 64'h3000, 1);
            expect_fault_info(PAGE + 64'd6, PAGE + 64'd6, 20,
                              1, 1, PTE_GPA, 64'h3000, 1);
            redirect_to(DEST);
            expect_request(DEST & ~64'd7);
            translate_info(PA0, 0, 20, 1, 1, GPA0, 64'h3000, 1);
            expect_ar(PA0[31:0]);
            expect_metadata(0, 0, 0, 0, 0);
            repeat (3) @(negedge clk);
            accept_ar();
            reply(0, error_kind == 0 ? `AXI_RESP_SLVERR : `AXI_RESP_DECERR);
            expect_fault(DEST, DEST, 1);
        end

        // Redirect while an old walk is still pending. Its late fault may
        // neither become architectural nor overwrite the new request's offset.
        reset_at(PAGE + 64'd6);
        expect_request(PAGE);
        redirect_to(DEST);
        expect_quiet(3);
        translate_info(0, 1, 20, 1, 1, PTE_GPA, 64'h3000, 1);
        expect_metadata(0, 0, 0, 0, 0);
        fetch(DEST & ~64'd7, PA0, 64'h0001_0001_0001_0001);
        expect_instruction(DEST, 32'h0001, 1);

        // A redirect coincident with walk completion discards the old fault.
        reset_at(PAGE + 64'd6);
        expect_request(PAGE);
        @(negedge clk);
        redir = 1; redir_pc = DEST;
        xlate_done = 1; xlate_fault = 1;
        xlate_fault_va = PAGE; xlate_fault_cause = 20;
        set_xlate_metadata(1, 1, GPA0, 0, 0);
        @(negedge clk); redir = 0; xlate_done = 0; xlate_busy = 0;
        expect_metadata(0, 0, 0, 0, 0);
        fetch(DEST & ~64'd7, PA0, 64'h0001_0001_0001_0001);
        expect_instruction(DEST, 32'h0001, 1);

        // Redirect before AR acceptance: VALID/address must be held until
        // handshake, then a late error response is drained without a trap.
        reset_at(PAGE + 64'd6);
        expect_request(PAGE); translate(PA0, 0, 0);
        expect_ar(PA0[31:0]);
        redirect_to(DEST);
        repeat (3) begin
            @(negedge clk);
            if (!arvalid || araddr !== PA0[31:0] || xlate_req || fault_valid)
                $fatal(1, "redirect changed a backpressured AXI request");
        end
        accept_ar();
        reply(0, `AXI_RESP_SLVERR);
        expect_request(DEST & ~64'd7);
        translate(0, 1, 12);
        expect_fault(DEST, DEST, 12);

        // Redirect coincident with the old R error also suppresses the fault.
        reset_at(PAGE + 64'd6);
        expect_request(PAGE); translate(PA0, 0, 0);
        expect_ar(PA0[31:0]); accept_ar();
        @(negedge clk);
        redir = 1; redir_pc = DEST; rvalid = 1; rresp = `AXI_RESP_DECERR;
        @(negedge clk); redir = 0; rvalid = 0;
        fetch(DEST & ~64'd7, PA0, 64'h0001_0001_0001_0001);
        expect_instruction(DEST, 32'h0001, 1);

        // IO translations may complete while older execution is active, but
        // cannot cause a physical fetch until it is safe. Keep the latched
        // attribute stable even if the translator changes its idle output.
        reset_at(PAGE);
        fetch_safe = 0; xlate_pbmt = 2;
        expect_request(PAGE); translate(PA0, 0, 0);
        xlate_pbmt = 0;
        expect_quiet(5);
        fetch_safe = 1;
        expect_ar(PA0[31:0]);
        if (ar_pbmt !== 2) $fatal(1, "IO attribute was not retained");
        accept_ar(); reply(64'h0001_0001_0001_0001, 0);
        expect_instruction(PAGE, 32'h0001, 1);

        // A redirect cancels a waiting IO demand without touching that PA.
        reset_at(PAGE);
        fetch_safe = 0; xlate_pbmt = 2;
        expect_request(PAGE); translate(PA0, 0, 0);
        expect_quiet(3);
        redirect_to(DEST);
        xlate_pbmt = 1; // NC is idempotent and need not wait for fetch_safe.
        fetch(DEST & ~64'd7, PA0 + 64'd8, 64'h0001_0001_0001_0001);
        if (ar_pbmt !== 1) $fatal(1, "NC attribute was not retained");
        expect_instruction(DEST, 32'h0001, 1);

        // Once IO ARVALID is asserted, later execution/redirect inputs may
        // not withdraw or change it under AXI backpressure.
        reset_at(PAGE);
        xlate_pbmt = 2;
        expect_request(PAGE); translate(PA0, 0, 0);
        expect_ar(PA0[31:0]);
        fetch_safe = 0;
        redirect_to(DEST);
        repeat (3) begin
            @(negedge clk);
            if (!arvalid || araddr !== PA0[31:0] || ar_pbmt !== 2)
                $fatal(1, "IO AR changed under backpressure");
        end
        accept_ar(); reply(0, `AXI_RESP_SLVERR);
        fetch_safe = 1; xlate_pbmt = 0;
        fetch(DEST & ~64'd7, PA0 + 64'd8, 64'h0001_0001_0001_0001);
        expect_instruction(DEST, 32'h0001, 1);

        $display("IFU PASS: %0d checks", checks);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "IFU test timeout");
    end
endmodule
