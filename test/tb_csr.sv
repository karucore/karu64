// SPDX-License-Identifier: BSD-3-Clause
// CSR WARL, interrupt, and effective-privilege checks through public ports.
// Complements instruction-level TVM/MMU tests; no hierarchical force/access.
`include "karu_ext.vh"
`include "karu_uop_defs.vh"
`include "karu_vcfg.vh"

module tb_csr;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg op_req = 0;
    reg [11:0] op_addr = 0;
    reg [63:0] op_src = 0;
    reg [4:0] op_sub = `CSR_RS, op_rs1 = 0;
    wire [63:0] op_rd_v;
    wire csr_illegal;
    reg trap_req = 0, mret_req = 0, sret_req = 0;
    reg [63:0] trap_epc = 0, trap_cause = 0, trap_tval = 0;
    reg irq_timer = 0, irq_software = 0, irq_external_m = 0, irq_external_s = 0;
    reg [63:0] time_in = 0;
    reg v_fault_start_we = 0;
    reg [63:0] v_fault_start = 0;
    wire [63:0] trap_vec, ret_pc, irq_cause, satp;
    wire [63:0] vstart;
    wire irq_pending;
    wire [1:0] priv, data_priv;
    wire [5:0] dpmlen;
    wire pbmte;
    integer checks = 0, mode, source_index, source_bit;
    reg [63:0] scratch, source_mask;

    localparam [63:0] S_MASK =
`ifdef KARU_EN_S
        64'h222 |
`endif
`ifdef KARU_EN_SSCOFPMF
        64'h2000 |
`endif
        64'b0;
    localparam [63:0] COUNTER_MASK =
`ifdef KARU_EN_HPM
        64'hffff_ffff;
`else
        64'h7;
`endif
    localparam [63:0] EPC_MASK =
`ifdef KARU_EN_C
        ~64'h1;
`else
        ~64'h3;
`endif
    localparam [63:0] VSTART_MASK = (64'b1 << $clog2(`KARU_VLEN)) - 1;

    karu_csr dut (
        .clk(clk), .rst(rst),
        .op_req(op_req), .op_addr(op_addr), .op_src(op_src),
        .op_sub(op_sub), .op_rs1(op_rs1), .op_rd_v(op_rd_v), .csr_illegal(csr_illegal),
        .trap_req(trap_req), .trap_epc(trap_epc), .trap_cause(trap_cause),
        .trap_tval(trap_tval), .trap_vec(trap_vec),
        .trap_gva(1'b0), .trap_gpa_valid(1'b0), .trap_gpa(64'b0), .trap_tinst(64'b0),
        .irq_timer(irq_timer), .irq_software(irq_software),
        .irq_external_m(irq_external_m), .irq_external_s(irq_external_s),
        .irq_pending(irq_pending), .irq_cause(irq_cause),
        .mret_req(mret_req), .sret_req(sret_req), .ret_pc(ret_pc), .priv_o(priv),
        .data_priv_o(data_priv), .satp_o(satp), .dpmlen_o(dpmlen), .pbmte_o(pbmte),
        .fflags_set(1'b0), .fflags_in(5'b0), .retire(1'b0), .cyc_in(64'b0),
        .time_in(time_in), .hpm_events(32'b0),
        .vset_req(1'b0), .vset_vtype(64'b0), .vset_vl(64'b0), .v_retire(1'b0),
        .v_fault_start_we(v_fault_start_we), .v_fault_start(v_fault_start),
        .vstart_o(vstart), .vl_trim_req(1'b0), .vl_trim_val(64'b0),
        .fp_dirty(1'b0), .v_dirty(1'b0), .vxsat_set(1'b0)
    );

    task automatic equal(input [63:0] got, expected, input string label_text);
        begin
            checks = checks + 1;
            if (got !== expected)
                $fatal(1, "%s: got=%016x expected=%016x", label_text, got, expected);
        end
    endtask

    task automatic reset_csr;
        begin
            @(negedge clk);
            rst = 1; op_req = 0; trap_req = 0; mret_req = 0; sret_req = 0;
            v_fault_start_we = 0; v_fault_start = 0;
            irq_timer = 0; irq_software = 0; irq_external_m = 0; irq_external_s = 0;
            time_in = 0;
            repeat (2) @(posedge clk);
            @(negedge clk); rst = 0;
            #1; equal(priv, 3, "reset privilege");
            equal(pbmte, 0, "PBMTE reset disabled");
        end
    endtask

    task automatic access_csr(input [11:0] addr, input [4:0] sub, rs1,
        input [63:0] value, input expected_illegal, output [63:0] old_value);
        begin
            @(negedge clk);
            op_req = 1; op_addr = addr; op_sub = sub; op_rs1 = rs1; op_src = value;
            #1;
            equal(csr_illegal, expected_illegal, $sformatf("CSR %03x legality", addr));
            old_value = op_rd_v;
            @(posedge clk); #1; op_req = 0;
        end
    endtask

    task automatic write_csr(input [11:0] addr, input [63:0] value);
        reg [63:0] old_value;
        begin access_csr(addr, `CSR_RW, 1, value, 0, old_value); end
    endtask

    task automatic read_check(input [11:0] addr, input [63:0] expected, mask,
        input string label_text);
        reg [63:0] old_value;
        begin
            access_csr(addr, `CSR_RS, 0, 0, 0, old_value);
            equal(old_value & mask, expected & mask, label_text);
        end
    endtask

    // Walk both polarities through every architectural bit, then exercise
    // read-modify-write paths. Every read checks reserved bits as well.
    task automatic warl_walk(input [11:0] addr, input [63:0] writable,
        input string label_text);
        integer bit_index;
        reg [63:0] pattern, old_value;
        begin
            write_csr(addr, ~64'b0);
            read_check(addr, writable, ~64'b0, {label_text, " write all ones"});
            for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin
                pattern = 64'b1 << bit_index;
                write_csr(addr, pattern);
                read_check(addr, pattern & writable, ~64'b0, {label_text, " walking one"});
                write_csr(addr, ~pattern);
                read_check(addr, ~pattern & writable, ~64'b0, {label_text, " walking zero"});
            end
            write_csr(addr, 0);
            read_check(addr, 0, ~64'b0, {label_text, " write zero"});
            access_csr(addr, `CSR_RS, 1, ~64'b0, 0, old_value);
            read_check(addr, writable, ~64'b0, {label_text, " CSRRS all bits"});
            access_csr(addr, `CSR_RC, 1, ~64'b0, 0, old_value);
            read_check(addr, 0, ~64'b0, {label_text, " CSRRC all bits"});
        end
    endtask

    task automatic fault_start_check(input [63:0] value);
        begin
            @(negedge clk); v_fault_start_we = 1; v_fault_start = value;
            @(posedge clk); #1; v_fault_start_we = 0;
            equal(vstart, value & VSTART_MASK, "fault-restart vstart width");
            read_check(12'h008, value & VSTART_MASK, ~64'b0, "fault-restart CSR readback");
        end
    endtask

    task automatic return_priv(input use_sret);
        begin
            @(negedge clk); sret_req = use_sret; mret_req = !use_sret;
            @(posedge clk); #1; sret_req = 0; mret_req = 0;
        end
    endtask

    task automatic enter_priv(input [1:0] target);
        begin
            write_csr(12'h300, {51'b0, target, 11'b0});
            return_priv(0);
            equal(priv, target, "MRET destination");
        end
    endtask

    task automatic take_trap(input [63:0] cause, epc, tval);
        begin
            @(negedge clk);
            trap_req = 1; trap_cause = cause; trap_epc = epc; trap_tval = tval;
            @(posedge clk); #1; trap_req = 0;
        end
    endtask

    task automatic irq_check(input pending, input [63:0] cause, input string label_text);
        begin
            #1; equal(irq_pending, pending, label_text);
            if (pending) equal(irq_cause, cause, {label_text, " cause"});
        end
    endtask

    // Pin the implementation's WARL choice, which is not fixed by the ISA:
    // every write accepts BASE; reserved MODE=2/3 normalizes to Direct.
    task automatic tvec_policy_check(input [11:0] addr);
        integer old_mode, requested_mode, operation;
        reg [4:0] sub;
        reg [63:0] before_value, operand, candidate, expected, old_value;
        string label_text;
        begin
            for (old_mode = 0; old_mode < 2; old_mode = old_mode + 1)
                for (requested_mode = 0; requested_mode < 4; requested_mode = requested_mode + 1)
                    for (operation = 0; operation < 3; operation = operation + 1) begin
                        before_value = 64'h1234_5678_8000_1000 | 64'(old_mode);
                        write_csr(addr, before_value);
                        case (operation)
                            0: begin
                                sub = `CSR_RW;
                                operand = 64'h0fed_cba0_8000_2000 | 64'(requested_mode);
                                candidate = operand;
                            end
                            1: begin
                                sub = `CSR_RS;
                                operand = 64'h4000 | 64'(requested_mode);
                                candidate = before_value | operand;
                            end
                            default: begin
                                sub = `CSR_RC;
                                operand = 64'h1000 | 64'(requested_mode);
                                candidate = before_value & ~operand;
                            end
                        endcase
                        expected = candidate & ~64'h3;
                        if ((candidate & 3) == 1) expected = expected | 1;
                        label_text = $sformatf("xtvec %03x op=%0d old-mode=%0d source-mode=%0d",
                                               addr, operation, old_mode, requested_mode);
                        access_csr(addr, sub, 1, operand, 0, old_value);
                        equal(old_value, before_value, {label_text, " old value"});
                        read_check(addr, expected, ~64'b0, {label_text, " WARL readback"});
                        trap_cause = 64'h8000_0000_0000_0001;
                        #1; equal(trap_vec, (expected & ~64'h3) + (expected[0] ? 4 : 0),
                                  {label_text, " interrupt target"});
                        trap_cause = 2;
                        #1; equal(trap_vec, expected & ~64'h3, {label_text, " exception target"});
                    end
            trap_cause = 0;
        end
    endtask

    function automatic [4:0] csr_form(input integer index);
        case (index)
            0: csr_form = `CSR_RW;
            1: csr_form = `CSR_RS;
            2: csr_form = `CSR_RC;
            3: csr_form = `CSR_RWI;
            4: csr_form = `CSR_RSI;
            default: csr_form = `CSR_RCI;
        endcase
    endfunction

    // Check the public read mux without inserting a clock: timer propagation
    // bounds must not be hidden by the clocked CSR transaction helper.
    task automatic timer_pending_check(input expected, input string label_text);
        begin
            op_addr = 12'h344; op_sub = `CSR_RS; op_rs1 = 0; op_src = 0;
            #1; equal(op_rd_v & 64'h20, expected ? 64'h20 : 0, label_text);
        end
    endtask

`ifdef KARU_EN_S
    localparam [63:0] STCE = 64'h8000_0000_0000_0000;

    // All six CSR forms, including zero-source no-write forms, under every
    // privilege/STCE/counter-enable combination. Illegal writes leave the
    // complete 64-bit comparator and both permission CSRs unchanged.
    task automatic sstc_permissions;
        integer target_index, stce, mtm, stm, operation, zero_source;
        reg [1:0] target;
        reg [4:0] sub, rs1;
        reg [63:0] expected, operand, old_value;
        reg illegal;
        begin
            for (target_index = 0; target_index < 3; target_index = target_index + 1)
                for (stce = 0; stce < 2; stce = stce + 1)
                    for (mtm = 0; mtm < 2; mtm = mtm + 1)
                        for (stm = 0; stm < 2; stm = stm + 1) begin
                            reset_csr;
                            target = target_index == 0 ? 3 : target_index == 1 ? 1 : 0;
                            expected = 64'hd3c4_8765_0123_5a96;
                            write_csr(12'h14d, expected);
                            write_csr(12'h30a, stce ? STCE : 0);
                            write_csr(12'h306, mtm ? 2 : 0);
                            write_csr(12'h106, stm ? 2 : 0);
                            if (target != 3) enter_priv(target);
                            illegal = target == 0 || (target == 1 && !(stce && mtm));
                            for (operation = 0; operation < 6; operation = operation + 1)
                                for (zero_source = 0; zero_source < 2; zero_source = zero_source + 1) begin
                                    sub = csr_form(operation);
                                    rs1 = zero_source ? 0 : 5;
                                    operand = zero_source ? 0 : operation < 3 ?
                                              64'h36a9_fedc_7654_123a : 5;
                                    access_csr(12'h14d, sub, rs1, operand, illegal, old_value);
                                    if (!illegal) begin
                                        equal(old_value, expected, "stimecmp CSR form old value");
                                        case (sub)
                                            `CSR_RW, `CSR_RWI: expected = operand;
                                            `CSR_RS, `CSR_RSI: if (rs1 != 0) expected = expected | operand;
                                            `CSR_RC, `CSR_RCI: if (rs1 != 0) expected = expected & ~operand;
                                        endcase
                                    end
                                    if (target != 3) begin
                                        access_csr(12'h30a, sub, rs1, operand, 1, old_value);
                                        take_trap(2, 64'h8000_1000, 0);
                                    end
                                    read_check(12'h14d, expected, ~64'b0, "stimecmp legal update / illegal no-write");
                                    read_check(12'h30a, stce ? STCE : 0, ~64'b0, "stimecmp access preserves STCE");
                                    read_check(12'h306, mtm ? 2 : 0, ~64'b0, "stimecmp access preserves mcounteren");
                                    read_check(12'h106, stm ? 2 : 0, ~64'b0, "stimecmp access preserves scounteren");
                                    if (target != 3) enter_priv(target);
                                end
                        end
        end
    endtask

    task automatic sstc_compare(input [63:0] now_value, compare_value);
        begin
            @(negedge clk); time_in = now_value;
            write_csr(12'h14d, compare_value);
            repeat (2) @(posedge clk);
            #1;
            timer_pending_check(now_value >= compare_value,
                                $sformatf("unsigned timer %016x >= %016x within two clocks", now_value, compare_value));
        end
    endtask

    task automatic sstc_timer;
        integer bit_index, sample, operation;
        reg [63:0] boundary, sequence_value, old_value;
        reg previous_pending;
        begin
            reset_csr;
            read_check(12'h14d, ~64'b0, ~64'b0, "stimecmp reset disables timer except at max time");
            read_check(12'h30a, 0, STCE, "STCE reset disabled");
            warl_walk(12'h14d, ~64'b0, "stimecmp full-width writable state");
            write_csr(12'h30a, ~64'b0);
            read_check(12'h30a, STCE | 64'h40000003000000f1, ~64'b0, "menvcfg implemented fields including STCE/PBMTE");
            equal(pbmte, 1, "PBMTE output enabled");
            access_csr(12'h30a, `CSR_RC, 1, 64'h4000000000000000, 0, old_value);
            equal(pbmte, 0, "PBMTE clears independently of STCE");
            read_check(12'h30a, STCE | 64'h3000000f1, ~64'b0, "PBMTE clear preserves other envcfg fields");
            access_csr(12'h30a, `CSR_RS, 1, 64'h4000000000000000, 0, old_value);
            equal(pbmte, 1, "PBMTE sets independently of STCE");
            write_csr(12'h30a, STCE);
            equal(pbmte, 0, "PBMTE cleared by CSRRW");
            sstc_compare(0, 0);
            sstc_compare(0, 1);
            sstc_compare(~64'b0, ~64'b0);
            sstc_compare(~64'b0 - 1, ~64'b0);
            sstc_compare(~64'b0, 0);
            // Every carry boundary, including all summary-chunk boundaries
            // and the unsigned high bit; equal high chunks expose lower ones.
            for (bit_index = 1; bit_index < 64; bit_index = bit_index + 1) begin
                boundary = 64'b1 << bit_index;
                sstc_compare(boundary - 1, boundary);
                sstc_compare(boundary, boundary);
                sstc_compare(boundary + 1, boundary);
                sstc_compare(boundary, boundary - 1);
            end
            sequence_value = 64'h87ab_0e92_6d3c_a145;
            for (sample = 0; sample < 128; sample = sample + 1) begin
                sequence_value = {sequence_value[62:0],
                                  sequence_value[63] ^ sequence_value[62] ^ sequence_value[60] ^ sequence_value[59]};
                sstc_compare(sequence_value, {sequence_value[31:0], sequence_value[63:32]});
            end
            // Time can change every cycle. The two-stage comparison must
            // never combine summaries belonging to different time samples.
            write_csr(12'h14d, 64'h89ab_cdef_0123_4567);
            repeat (2) @(posedge clk);
            #1; previous_pending = time_in >= 64'h89ab_cdef_0123_4567;
            for (sample = 0; sample < 128; sample = sample + 1) begin
                sequence_value = {sequence_value[62:0],
                                  sequence_value[63] ^ sequence_value[62] ^ sequence_value[60] ^ sequence_value[59]};
                @(negedge clk); time_in = sequence_value;
                @(posedge clk); #1;
                timer_pending_check(previous_pending, "pipelined time stream stays coherent");
                previous_pending = sequence_value >= 64'h89ab_cdef_0123_4567;
            end

            // STCE=0 selects the writable firmware-injected STIP. A same-value
            // write is not a field-modulation event and must preserve it.
            reset_csr;
            write_csr(12'h344, 64'h20);
            write_csr(12'h30a, 0);
            timer_pending_check(1, "same disabled STCE preserves software STIP");
            access_csr(12'h30a, `CSR_RSI, 1, 1, 0, old_value);
            timer_pending_check(1, "unrelated envcfg RMW preserves software STIP");
            access_csr(12'h30a, `CSR_RS, 0, 0, 0, old_value);
            timer_pending_check(1, "read-only envcfg access preserves software STIP");
            access_csr(12'h30a, `CSR_RS, 1, STCE, 0, old_value);
            read_check(12'h30a, STCE | 1, ~64'b0, "CSRRS enables STCE preserving FIOM");
            timer_pending_check(0, "hardware source ignores previous software STIP");

            // MIP.STIP is read-only with STCE=1 for every CSR form. Writes to
            // other mip bits must neither capture nor override the timer.
            for (operation = 0; operation < 6; operation = operation + 1) begin
                sstc_compare(0, 1);
                access_csr(12'h344, csr_form(operation), 1,
                           operation < 3 ? 64'h22 : 2, 0, old_value);
                timer_pending_check(0, "CSR form cannot set hardware STIP");
                sstc_compare(1, 0);
                access_csr(12'h344, csr_form(operation), 1,
                           operation < 3 ? 64'h20 : 2, 0, old_value);
                equal(old_value & 64'h20, 64'h20, "CSR form reads hardware STIP");
                timer_pending_check(1, "CSR form cannot clear hardware STIP");
                // Deterministic implementation policy, not an ISA-required
                // value: returning to writable STIP clears its software latch.
                access_csr(12'h30a, `CSR_RC, 1, STCE, 0, old_value);
                timer_pending_check(0, "STCE disable does not latch hardware pending");
                access_csr(12'h30a, `CSR_RS, 1, STCE, 0, old_value);
                timer_pending_check(1, "reenable selects running timer immediately");
            end
            access_csr(12'h30a, `CSR_RWI, 0, 0, 0, old_value);
            timer_pending_check(0, "CSRRWI zero disables STCE and clears software STIP");
            write_csr(12'h344, 64'h20);
            timer_pending_check(1, "disabled STCE restores software STIP writes");
            write_csr(12'h14d, ~64'b0);
            repeat (2) @(posedge clk);
            #1; timer_pending_check(1, "disabled hardware timer cannot clear software STIP");

            // Hardware STIP follows normal M/S interrupt enable, delegation,
            // privilege, and priority rules, including restoration by xRET.
            reset_csr;
            write_csr(12'h30a, STCE);
            write_csr(12'h304, 64'h20);
            sstc_compare(0, 0);
            irq_check(0, 0, "timer masked by MIE in M");
            write_csr(12'h300, 8);
            irq_check(1, 64'h8000_0000_0000_0005, "nondelegated hardware timer to M");
            take_trap(irq_cause, 64'h8000_6003, 0);
            equal(priv, 3, "hardware timer M trap destination");
            read_check(12'h342, 64'h8000_0000_0000_0005, ~64'b0, "hardware timer mcause");
            irq_check(0, 0, "M trap masks hardware timer");
            return_priv(0);
            irq_check(1, 64'h8000_0000_0000_0005, "MRET reenables still-pending timer");
            write_csr(12'h303, 64'h20);
            irq_check(0, 0, "delegated hardware timer cannot interrupt M");
            write_csr(12'h306, 2);
            enter_priv(1);
            irq_check(0, 0, "delegated hardware timer masked by SIE");
            write_csr(12'h100, 2);
            irq_check(1, 64'h8000_0000_0000_0005, "delegated hardware timer to S");
            read_check(12'h144, 64'h20, 64'h20, "sip reflects delegated hardware timer");
            write_csr(12'h144, 0);
            irq_check(1, 64'h8000_0000_0000_0005, "sip write cannot clear timer");
            take_trap(irq_cause, 64'h8000_7003, 0);
            equal(priv, 1, "hardware timer S trap destination");
            read_check(12'h142, 64'h8000_0000_0000_0005, ~64'b0, "hardware timer scause");
            read_check(12'h141, 64'h8000_7003 & EPC_MASK, ~64'b0, "hardware timer sepc");
            sstc_compare(0, 1);
            return_priv(1);
            irq_check(0, 0, "SRET after stimecmp advance sees cleared timer");
            sstc_compare(1, 1);
            irq_check(1, 64'h8000_0000_0000_0005, "time reaching comparator retriggers timer");
            write_csr(12'h104, 0);
            irq_check(0, 0, "sie.STIE masks pending hardware timer");
            write_csr(12'h104, 64'h20);
            take_trap(11, 0, 0);
            enter_priv(0);
            irq_check(1, 64'h8000_0000_0000_0005, "delegated hardware timer interrupts U regardless of SIE");
            take_trap(11, 0, 0);
            write_csr(12'h304, 64'h2aa);
            write_csr(12'h303, 64'h222);
            write_csr(12'h344, 64'h202);
            enter_priv(1);
            write_csr(12'h100, 2);
            irq_check(1, 64'h8000_0000_0000_0009, "supervisor external precedes hardware timer");
            take_trap(11, 0, 0);
            write_csr(12'h344, 2);
            enter_priv(1);
            write_csr(12'h100, 2);
            irq_check(1, 64'h8000_0000_0000_0001, "supervisor software precedes hardware timer");
            irq_timer = 1;
            irq_check(1, 64'h8000_0000_0000_0007, "machine timer precedes delegated supervisor sources");
            irq_timer = 0;
            take_trap(11, 0, 0);
            write_csr(12'h344, 0);
            enter_priv(1);
            write_csr(12'h100, 2);
            irq_check(1, 64'h8000_0000_0000_0005, "hardware timer remains pending after higher priorities clear");
        end
    endtask
`endif

    task automatic sstc_absent_csrs;
        integer address_index, operation, zero_source;
        reg [11:0] address;
        reg [63:0] old_value;
        begin
            reset_csr;
            for (address_index = 0; address_index < 4; address_index = address_index + 1) begin
                case (address_index)
                    0: address = 12'h15d; // RV32-only stimecmph
                    1: address = 12'h24d; // H vstimecmp
                    2: address = 12'h25d; // H/RV32 vstimecmph
`ifdef KARU_EN_S
                    default: address = 12'h60a; // henvcfg requires H
`else
                    default: address = 12'h14d; // Sstc absent without S
`endif
                endcase
                for (operation = 0; operation < 6; operation = operation + 1)
                    for (zero_source = 0; zero_source < 2; zero_source = zero_source + 1)
                        access_csr(address, csr_form(operation), zero_source ? 0 : 5,
                                   zero_source ? 0 : 5, 1, old_value);
            end
`ifdef KARU_EN_S
            read_check(12'h14d, ~64'b0, ~64'b0, "absent timer CSR accesses preserve stimecmp");
            read_check(12'h30a, 0, STCE, "absent timer CSR accesses preserve STCE");
`else
            access_csr(12'h30a, `CSR_RW, 1, ~64'b0, 1, old_value);
`endif
            timer_pending_check(0, "absent CSR accesses cannot assert STIP");
        end
    endtask

    initial begin
`ifdef KARU_EN_S
        sstc_permissions;
        sstc_timer;
`endif
        sstc_absent_csrs;
        reset_csr;
        tvec_policy_check(12'h305);
`ifdef KARU_EN_S
        write_csr(12'h302, 4); // Delegate the synchronous test cause to S.
        write_csr(12'h303, 2); // Delegate the interrupt test cause to S.
        enter_priv(1);
        tvec_policy_check(12'h105);
`endif
        reset_csr;
`ifdef KARU_EN_C
        read_check(12'h301, 4, 4, "misa.C enabled");
`else
        read_check(12'h301, 0, 4, "misa.C disabled");
`endif
        write_csr(12'h304, ~64'b0);
        read_check(12'h304, 64'h888 | S_MASK, ~64'b0, "mie implemented sources");
        write_csr(12'h344, ~64'b0);
        read_check(12'h344, S_MASK, ~64'b0, "mip writable sources");
        write_csr(12'h306, ~64'b0);
        read_check(12'h306, COUNTER_MASK, ~64'b0, "mcounteren width");
        write_csr(12'h306, 64'hffff_ffff_0000_0000);
        read_check(12'h306, 0, ~64'b0, "mcounteren upper bits zero");
        warl_walk(12'h320, COUNTER_MASK & ~64'h2, "mcountinhibit");
`ifdef KARU_EN_V
        write_csr(12'h300, 64'h6600); // FS/VS Dirty, native M
        warl_walk(12'h008, VSTART_MASK, "M-mode vstart");
        fault_start_check(~64'b0);
        for (source_bit = 0; source_bit < 64; source_bit = source_bit + 1)
            fault_start_check(64'b1 << source_bit);
        fault_start_check(0);
`ifdef KARU_EN_S
        write_csr(12'h300, 64'h6e00); // FS/VS Dirty, MPP=S
        return_priv(0);
        equal(priv, 1, "vstart supervisor test privilege");
        warl_walk(12'h008, VSTART_MASK, "S-mode vstart");
        access_csr(12'h320, `CSR_RW, 1, ~64'b0, 1, scratch);
        take_trap(64'h8000_0000_0000_000b, 0, 0);
        read_check(12'h320, 0, ~64'b0, "S-mode rejection preserves mcountinhibit");
`endif
`endif
        for (mode = 0; mode < 4; mode = mode + 1) begin
            write_csr(12'h300, (64'(mode) << 11) | 64'h20000);
`ifdef KARU_EN_S
            scratch = mode == 2 ? 0 : mode;
`else
            scratch = mode == 3 ? 3 : 0;
`endif
            read_check(12'h300, scratch << 11, 64'h1800, "MPP WARL");
            equal(data_priv, scratch, "MPRV effective privilege");
        end
        write_csr(12'h341, 64'h1234_5678_9abc_deff);
        read_check(12'h341, 64'h1234_5678_9abc_deff & EPC_MASK, ~64'b0, "mepc write alignment");
        take_trap(2, 64'h80000007, 64'h12345678);
        read_check(12'h341, 64'h80000007 & EPC_MASK, ~64'b0, "mepc trap alignment");
        read_check(12'h343, 64'h12345678, ~64'b0, "mtval trap payload");
        equal(ret_pc, 64'h80000007 & EPC_MASK, "MRET PC alignment");

`ifdef KARU_EN_S
        write_csr(12'h302, ~64'b0);
        read_check(12'h302, 64'hb3ff, ~64'b0, "medeleg legal causes");
        write_csr(12'h303, ~64'b0);
        read_check(12'h303, S_MASK, ~64'b0, "mideleg legal sources");
        write_csr(12'h106, ~64'b0);
        read_check(12'h106, COUNTER_MASK, ~64'b0, "scounteren width");
        write_csr(12'h106, 64'hffff_ffff_0000_0000);
        read_check(12'h106, 0, ~64'b0, "scounteren upper bits zero");
        write_csr(12'h30a, 64'h0000_0002_0000_0001);
        read_check(12'h30a, 64'h0000_0002_0000_0001, ~64'b0, "menvcfg FIOM and PMM");
        write_csr(12'h10a, 64'h0000_0003_0000_0001);
        read_check(12'h10a, 64'h0000_0003_0000_0001, ~64'b0, "senvcfg FIOM and PMM");
        access_csr(12'h30a, `CSR_RC, 1, 1, 0, scratch);
        read_check(12'h30a, 64'h0000_0002_0000_0000, ~64'b0, "menvcfg FIOM clears independently");
        access_csr(12'h10a, `CSR_RC, 1, 1, 0, scratch);
        read_check(12'h10a, 64'h0000_0003_0000_0000, ~64'b0, "senvcfg FIOM clears independently");
        write_csr(12'h300, 64'h20800);
        equal(priv, 3, "MPRV does not change execution privilege");
        equal(data_priv, 1, "MPRV selects S");
        equal(dpmlen, 7, "MPRV S pointer mask");
        write_csr(12'h300, 64'h20000);
        equal(data_priv, 0, "MPRV selects U");
        equal(dpmlen, 16, "MPRV U pointer mask");
        write_csr(12'h300, 64'h21800);
        equal(dpmlen, 0, "MPRV M pointer mask disabled");
        write_csr(12'h300, 64'ha0800);
        equal(data_priv, 1, "MXR retains MPRV S privilege");
        equal(dpmlen, 0, "MXR suppresses MPRV S pointer masking");
        write_csr(12'h300, 64'ha0000);
        equal(data_priv, 0, "MXR retains MPRV U privilege");
        equal(dpmlen, 0, "MXR suppresses MPRV U pointer masking");
        write_csr(12'h300, 64'ha1800);
        equal(dpmlen, 0, "MXR effective M pointer masking remains disabled");
        write_csr(12'h300, 64'h800);
        equal(data_priv, 3, "MPRV zero uses execution privilege");
        equal(dpmlen, 0, "M execution pointer mask disabled");

        write_csr(12'h180, 64'h8a5a_5000_0000_0123);
        equal(satp, 64'h8a5a_5000_0000_0123, "satp Sv39 ASID/PPN storage");
        scratch = satp;
        for (mode = 1; mode < 16; mode = mode + 1) begin
            if (mode != 8) begin
                write_csr(12'h180, (64'(mode) << 60) | 64'h0555_0000_0000_0bad);
                equal(satp, scratch, "unsupported satp MODE preserves ASID/PPN");
            end
        end
        access_csr(12'h180, `CSR_RS, 1, 64'h4000_0000_0000_0001, 0, scratch);
        equal(satp, scratch, "satp invalid MODE via CSRRS is atomic");
        write_csr(12'h180, 64'h0fff_ffff_ffff_ffff);
        equal(satp, 64'h0fff_ffff_ffff_ffff, "Bare MODE WARL storage");
        write_csr(12'h180, 64'h8000_0000_0000_0123);
        write_csr(12'h300, 64'h100800);
        return_priv(0);
        access_csr(12'h180, `CSR_RW, 1, 0, 1, scratch);
        take_trap(64'h8000_0000_0000_000b, 64'h80001001, 0);
        equal(satp, 64'h8000_0000_0000_0123, "TVM rejection has no satp effect");

        reset_csr;
        write_csr(12'h30a, 64'h0000_0002_0000_0000);
        write_csr(12'h10a, 64'h0000_0003_0000_0000);
        write_csr(12'h300, 64'h80800);
        return_priv(0);
        equal(dpmlen, 0, "MXR suppresses native S pointer masking");
        write_csr(12'h100, 0);
        equal(dpmlen, 7, "clearing MXR restores S pointer masking");
        take_trap(64'h8000_0000_0000_000b, 0, 0);
        write_csr(12'h300, 64'h80000);
        return_priv(0);
        equal(dpmlen, 0, "MXR suppresses native U pointer masking");
        take_trap(64'h8000_0000_0000_000b, 0, 0);
        write_csr(12'h300, 0);
        return_priv(0);
        equal(dpmlen, 16, "clearing MXR restores U pointer masking");
        take_trap(64'h8000_0000_0000_000b, 0, 0);
        write_csr(12'h341, 64'h80002003);
        write_csr(12'h300, 64'h20800);
        return_priv(0);
        equal(priv, 1, "MRET to S");
        equal(data_priv, 1, "MRET clears MPRV before S data access");
        take_trap(64'h8000_0000_0000_000b, 64'h80002003, 0);
        read_check(12'h300, 0, 64'h20000, "MRET below M clears MPRV");
        write_csr(12'h141, 64'h80003003);
        read_check(12'h141, 64'h80003003 & EPC_MASK, ~64'b0, "sepc write alignment");
        write_csr(12'h300, 64'h21900); // MPRV, MPP=M, SPP=S
        return_priv(1);
        equal(priv, 1, "SRET destination S");
        equal(data_priv, 1, "SRET clears MPRV");
        take_trap(64'h8000_0000_0000_000b, 64'h80003003, 0);
        read_check(12'h300, 0, 64'h20000, "SRET MPRV storage cleared");
        write_csr(12'h302, 4);
        enter_priv(0);
        take_trap(2, 64'h80004003, 64'hfeed);
        equal(priv, 1, "delegated synchronous trap enters S");
        read_check(12'h141, 64'h80004003 & EPC_MASK, ~64'b0, "sepc trap alignment");
        read_check(12'h143, 64'hfeed, ~64'b0, "stval delegated payload");

        // SEIP reads OR external state, but CSRRS/RC must update only its latch.
        reset_csr;
        irq_external_s = 1;
        access_csr(12'h344, `CSR_RS, 1, 2, 0, scratch);
        equal(scratch, 64'h200, "CSRRS mip sees external SEIP");
        irq_external_s = 0;
        read_check(12'h344, 2, ~64'b0, "CSRRS does not latch external SEIP");
        irq_external_s = 1;
        access_csr(12'h344, `CSR_RC, 1, 2, 0, scratch);
        irq_external_s = 0;
        read_check(12'h344, 0, ~64'b0, "CSRRC does not latch external SEIP");
        irq_external_s = 1;
        access_csr(12'h344, `CSR_RS, 1, 64'h200, 0, scratch);
        irq_external_s = 0;
        read_check(12'h344, 64'h200, ~64'b0, "software SEIP independently sets");
        irq_external_s = 1;
        access_csr(12'h344, `CSR_RC, 1, 64'h200, 0, scratch);
        read_check(12'h344, 64'h200, ~64'b0, "external SEIP survives software clear");
        irq_external_s = 0;
        read_check(12'h344, 0, ~64'b0, "software SEIP independently clears");

        write_csr(12'h344, S_MASK);
        write_csr(12'h303, S_MASK);
        enter_priv(1);
        write_csr(12'h144, 0);
        read_check(12'h144, 64'h220, ~64'b0, "sip clears only SSIP/LCOFIP");
        write_csr(12'h144, ~64'b0);
        read_check(12'h144, S_MASK, ~64'b0, "sip sets only SSIP/LCOFIP");
        take_trap(64'h8000_0000_0000_000b, 0, 0);
        write_csr(12'h344, 0);
        enter_priv(1);
        write_csr(12'h144, 64'h220);
        read_check(12'h144, 0, ~64'b0, "sip cannot manufacture STIP/SEIP");

        for (source_index = 0; source_index < 3; source_index = source_index + 1) begin
            source_bit = source_index == 0 ? 9 : source_index == 1 ? 1 : 5;
            source_mask = 64'b1 << source_bit;
            reset_csr;
            write_csr(12'h304, source_mask);
            write_csr(12'h344, source_mask);
            write_csr(12'h300, 0);
            irq_check(0, 0, "nondelegated source masked by MIE in M");
            write_csr(12'h300, 8);
            irq_check(1, 64'h8000_0000_0000_0000 | source_bit, "nondelegated S source delivered to M");
            enter_priv(1);
            irq_check(1, 64'h8000_0000_0000_0000 | source_bit, "M interrupt enabled below M");
            take_trap(irq_cause, 64'h80005000, 0);
            equal(priv, 3, "nondelegated interrupt trap destination");

            write_csr(12'h303, source_mask);
            write_csr(12'h300, 10);
            irq_check(0, 0, "delegated source masked in M");
            enter_priv(1);
            irq_check(0, 0, "delegated source masked by SIE in S");
            write_csr(12'h100, 2);
            irq_check(1, 64'h8000_0000_0000_0000 | source_bit, "delegated source enabled in S");
            take_trap(irq_cause, 64'h80005003, 0);
            equal(priv, 1, "delegated interrupt trap destination");
            read_check(12'h141, 64'h80005003 & EPC_MASK, ~64'b0, "delegated interrupt EPC");
            take_trap(64'h8000_0000_0000_000b, 0, 0);
            enter_priv(0);
            irq_check(1, 64'h8000_0000_0000_0000 | source_bit, "delegated source enabled in U");
        end

        reset_csr;
        write_csr(12'h303, 64'h200);
        write_csr(12'h304, 64'h202);
        write_csr(12'h344, 64'h202);
        enter_priv(1);
        write_csr(12'h100, 2);
        irq_check(1, 64'h8000_0000_0000_0001, "M-destined SSIP outranks S-destined SEIP");
`ifdef KARU_EN_SSCOFPMF
        take_trap(64'h8000_0000_0000_000b, 0, 0);
        write_csr(12'h304, 64'h2200);
        write_csr(12'h344, 64'h2200);
        enter_priv(1);
        write_csr(12'h100, 2);
        irq_check(1, 64'h8000_0000_0000_000d, "M-destined LCOFI outranks S-destined SEIP");
`endif
`else
        access_csr(12'h180, `CSR_RS, 0, 0, 1, scratch);
        access_csr(12'h100, `CSR_RS, 0, 0, 1, scratch);
        access_csr(12'h303, `CSR_RS, 0, 0, 1, scratch);
        equal(satp, 0, "no-S satp output");
        equal(dpmlen, 0, "no-S pointer masking disabled");
`endif

        reset_csr;
        write_csr(12'h304, 64'h888);
        write_csr(12'h300, 8);
        irq_timer = 1; irq_software = 1; irq_external_m = 1;
        irq_check(1, 64'h8000_0000_0000_000b, "machine external before timer");
        irq_external_m = 0;
        irq_check(1, 64'h8000_0000_0000_0003, "machine software before timer");
        irq_software = 0;
        irq_check(1, 64'h8000_0000_0000_0007, "machine timer after software");
        irq_software = 1; irq_external_m = 1;
        access_csr(12'h344, `CSR_RS, 1, 0, 0, scratch);
        irq_timer = 0; irq_software = 0; irq_external_m = 0;
        read_check(12'h344, 0, ~64'b0, "RMW never latches MTIP/MSIP/MEIP");
        write_csr(12'h300, 64'h20000);
        return_priv(0);
        equal(priv, 0, "MRET to U");
        equal(data_priv, 0, "MRET U effective privilege");
        take_trap(64'h8000_0000_0000_000b, 0, 0);
        read_check(12'h300, 0, 64'h20000, "MRET to U clears MPRV");
        write_csr(12'h300, 64'h21800);
        return_priv(0);
        equal(priv, 3, "MRET to M");
        read_check(12'h300, 64'h20000, 64'h20000, "MRET to M preserves MPRV");

        $display("CSR_PASS checks=%0d", checks);
        $finish;
    end

    initial begin #1000000; $fatal(1, "CSR test timeout"); end
endmodule
