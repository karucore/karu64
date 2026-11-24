//  tb_rosc_meter.sv -- unit tests of the phase meter of the ring oscillators
//  and of the period counters of the noise source (make rosc-meter-test):
//  flow/fpga/karu_rosc_meter.v and flow/fpga/karu_rosc_rng.v. Two benches.
//
//  tb_rosc_meter: the noise source's behavioural model (SIM = 1) and the
//  meter, with a clocked register master and stubs for the two status
//  inputs of the entropy block (test mode, lock). The bench reads the
//  model's rings by hierarchical reference, each as a 64-bit number of
//  periods (whole periods above 32 bits of phase), and keeps what the
//  meter should hold from them: totals from differences that are not
//  reduced modulo 64, the records that fall due and which of them is held.
//  A record is then compared with the model at the clock edge its bits
//  were sampled at. Run with +rosc_turns, +rosc_jitter and +rosc_shared
//  for the rates of real rings; +dump=<prefix> writes every symbol and
//  count of two stretches after a reset, one in each counting mode, which
//  the make rule compares with the Python copy of the model
//  (test/dbg/board/noise_model.py). The meter's check of the counts is
//  compared in every clock with the bench's own statement of the rule;
//  +soak=<clocks> is the length of a run in each counting mode, and with
//  +healthy no count may be flagged in it (true of the model unless its
//  rate changes by a period or more from one clock to the next).
//
//  tb_rosc_cnt (with KARU_ROSC_BENCH defined): the noise source as it is
//  synthesised (SIM = 0), with the rings supplied by this file as clocks of
//  0.37 to 1.0 ns with jitter, the look-up tables of the counters' dividers
//  supplied with delays, and routing delays between the counters'
//  ring-domain flops and the flops that sample them. The bench counts the
//  true edges of each ring and of each counter's clock, and a count read in
//  the clock domain must be the true count of its clock edge or one less.
//  One counter by itself is taken through the decoder's margins, and,
//  built with KARU_ROSC_DIV as well, through the divider's races with the
//  routes to its tables: where it is right and where it fails, as
//  inequalities between delays.
//
//  test/rosc_meter_mutants.py runs both against one-mechanism mutants,
//  built without the modules' own assertions.
//
//  Stimulus changes on the falling clock edge. A value read just after it is
//  what an access in that cycle returns; the rising edge that follows acts.
//  The benches' own bookkeeping runs on the rising edge, on the values the
//  design samples there.
//  SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_rosc_meter;
    localparam int R = 6, L = 4, TW = 20;
    localparam [1:0] R_CTRL = 2'd0, R_DATA0 = 2'd1, R_DATA1 = 2'd2;

    logic clk = 0, rst = 1, en = 1, test = 0, lock = 0;
    logic [7:0]   div = 8'd7;                   //  the source's sampling period, less one
    logic [R-1:0] op_mask = 6'b001111;          //  the strap: references off outside test mode
    logic [R-1:0] inject = '0;                  //  counts reported as not readable
    logic [R-1:0] hold = '0;                    //  ... and repeating their previous value, as the source does it
    logic [5:0]   inj [0:R-1];                  //  an error added to a ring's count on its way to the meter
    logic         force_dir = 0;                //  direct counting without the meter asking
    always #5 clk = ~clk;

    //  register port, as a system-control block drives it
    logic        reg_re = 0, reg_we = 0;
    logic [1:0]  reg_raddr = 0, reg_waddr = 0;
    logic [63:0] reg_wdata = 0;
    wire  [63:0] reg_rdata;

    wire           val, respace;
    wire [L-1:0]   b;
    wire [6*R-1:0] cnt;
    wire [R-1:0]   bad, ring_en;
    wire [3:0]     sym;
    wire [R-L-1:0] ref_b;
    wire           dir_o;
    //  the counts as the meter gets them
    wire [6*R-1:0] cnt_m;
    logic [5:0]    cnt_last [0:R-1];
    for (genvar r = 0; r < R; r++) begin : g_inj
        assign cnt_m[6*r +: 6] = hold[r] ? cnt_last[r] : 6'(cnt[6*r +: 6] + inj[r]);
        always @(posedge clk) cnt_last[r] <= cnt_m[6*r +: 6];
    end

    karu_rosc_rng #(.STREAMS(L), .REFS(R - L), .SIM(1)) noise (
        .clk(clk), .rst(rst), .rng_en_i(en), .rng_fips_i(1'b0), .rng_div_i(div), .ring_en_i(ring_en),
        .cnt_direct_i(dir_o | force_dir),
        .rng_val_o(val), .rng_b_o(b), .ref_b_o(ref_b), .cnt_o(cnt), .cnt_bad_o(bad));
    karu_rosc_meter #(.RINGS(R), .LANES(L)) dut (
        .clk(clk), .rst(rst), .test_i(test), .lock_i(lock),
        .rng_val_i(val), .rng_b_i(b), .ref_b_i(ref_b), .cnt_i(cnt_m), .cnt_bad_i(bad | inject), .op_mask_i(op_mask),
        .ring_en_o(ring_en), .cnt_direct_o(dir_o), .burst_sym_o(sym), .respace_o(respace),
        .reg_re_i(reg_re), .reg_raddr_i(reg_raddr), .reg_rdata_o(reg_rdata),
        .reg_we_i(reg_we), .reg_waddr_i(reg_waddr), .reg_wdata_i(reg_wdata));

    //  ---- checking ----
    int checks = 0;
    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) begin
            $display("FAIL rosc meter check %0d: %s (time %0t)", checks, what, $time);
            $fatal(1);
        end
    endtask

    //  ---- the model's rings, and what the meter should hold ----
    //  w2[r] is ring r three clock edges ago, {count, phase}: the edge at
    //  which the symbol and the counts of this cycle were sampled. The count
    //  is the model's whole periods in the unit of the source's mode, not
    //  reduced modulo 64.
    logic [63:0]   w0 [0:R-1], w1 [0:R-1], w2 [0:R-1];
    wire  [31:0]   duty = noise.g_model.duty;
    int            since_rst = 0;
    bit            m_on = 0;                    //  the previous counts are known
    logic [31:0]   m_prev [0:R-1];
    logic [TW-1:0] m_tot [0:R-1];               //  totals, with the counts of this cycle
    longint        m_wide [0:R-1];              //  the same, not reduced
    int            m_div = 0, m_every = 0, m_bad = 0;
    logic [1:0]    m_seq = 0;
    logic [R-1:0]  m_mask = '0;
    bit            m_src = 0, m_ref = 0, m_hi = 0, m_dir = 0, m_loss = 0, m_late = 0;
    logic [R-1:0]  m_flag = '0;
    //  the consistency check: a ring's count and increment of the clock
    //  before; clocks since the ring restarted (it was switched on, the mode
    //  changed, test mode began) and since a start or an unreadable count
    logic [5:0]    sc_p [0:R-1], sc_d [0:R-1];
    int            age_r [0:R-1], age_s [0:R-1];
    int            odd_bad = 0, dir_bad = 0;
    longint        cov2 = 0, cov3 = 0, cov_steady = 0;
    logic [2:0]    m_sel = 0;
    int            m_held = -1;                 //  the record that is held: index into q_*
    //  every record that fell due: totals at its edge, one clock before and
    //  one after; the symbol, the bits of the model phase, sequence number
    logic [TW*R-1:0] q_tot [$], q_early [$], q_late [$];
    logic [L-1:0]  q_b [$], q_pb [$];
    logic [1:0]    q_seq [$];
    longint        q_strobe [$];
    longint        strobes = 0;
    int            cnt_bad = 0, bit_bad = 0, ref_bad = 0, tot_bad = 0, sym_bad = 0, out_bad = 0, mask_bad = 0, respaces = 0;
    int            flips [0:L-1];               //  changes of a lane between consecutive symbols
    int            rflips [0:R-L-1];            //  and of a reference bit
    logic [L-1:0]  b_last = '0;
    logic [R-L-1:0] rb_last = '0;
    int            dump_fd = 0;
    bit            dumping = 0;

    function automatic [TW*R-1:0] totals();
        for (int r = 0; r < R; r++) totals[TW*r +: TW] = m_tot[r];
    endfunction

    always @(posedge clk) begin : monitor
        logic [TW*R-1:0] t, te;
        logic [L-1:0]    pb;
        logic [R-L-1:0]  prb;
        logic [31:0]     cur, d;
        logic [3:0]      s;
        logic [5:0]      c6, d6, dd6;
        bit              due, take, unread, far;
        int              want;
        since_rst = rst ? 0 : since_rst + 1;
        for (int m = 0; m < L; m++) pb[m] = w2[m][31:0] < duty;
        for (int m = L; m < R; m++) prb[m - L] = w2[m][31:0] < duty;
        //  the noise source's contract: counts and bits of the same edge
        if (since_rst > 4) begin
            for (int r = 0; r < R; r++) if (cnt[6*r +: 6] !== w2[r][37:32]) cnt_bad++;
            if (val && b !== pb) bit_bad++;
            if (val && ref_b !== prb) ref_bad++;
        end
        if (val && !rst) begin
            strobes++;
            for (int m = 0; m < L; m++) if (b[m] !== b_last[m]) flips[m]++;
            for (int m = 0; m < R - L; m++) if (ref_b[m] !== rb_last[m]) rflips[m]++;
            b_last = b; rb_last = ref_b;
        end
        if (respace && !rst) respaces++;
        if (dumping) $fwrite(dump_fd, "%1x %1x %1x %09x\n", val, b, ref_b, cnt);

        if (rst || !test || lock) begin
            if (!rst && (ring_en !== op_mask || dir_o !== 1'b0 || sym !== b || reg_rdata !== 64'd0)) out_bad++;
            m_on = 0; m_div = 0; m_every = 0; m_seq = 0; m_mask = op_mask; m_src = 0; m_ref = 0; m_sel = 0;
            m_hi = 0; m_dir = 0; m_flag = '0;
            m_held = -1; m_loss = 0; m_bad = 0; m_late = 0;
            for (int r = 0; r < R; r++) begin m_tot[r] = '0; m_wide[r] = 0; age_r[r] = 0; age_s[r] = 1000; end
        end else begin
            if (ring_en !== m_mask) mask_bad++;
            if (dir_o !== m_dir) dir_bad++;
            s = m_src ? ((m_sel < 3'd6) ? (m_hi ? w2[m_sel][37:34] : w2[m_sel][35:32]) : 4'd0) : m_ref ? {ref_b[1:0], b[1:0]} : b;
            if (sym !== s) sym_bad++;
            //  The consistency check, on the counts the meter gets. A ring of
            //  the mask is flagged in a clock in which its count is not
            //  readable; never in the twelve clocks after a restart or the two
            //  after a start or an unreadable count; and from the seventeenth
            //  clock after a restart exactly when its increment differs from
            //  that of the clock before by more than 2. (Between, the meter's
            //  own count of clocks decides.)
            for (int r = 0; r < R; r++) begin
                if (age_r[r] < 1000) age_r[r]++;
                if (age_s[r] < 1000) age_s[r]++;
                c6 = cnt_m[6*r +: 6]; d6 = c6 - sc_p[r]; dd6 = d6 - sc_d[r];
                far = dd6 > 6'd2 && dd6 < 6'd62;
                unread = bad[r] | inject[r];
                want = !m_mask[r] ? 0 : unread ? 1 : (age_r[r] <= 12 || age_s[r] <= 2) ? 0 : (age_r[r] >= 17 && age_s[r] >= 3) ? int'(far) : -1;
                if (want >= 0 && dut.odd[r] !== 1'(want)) begin
                    if (odd_bad < 4) $display("consistency: ring %0d flagged %b, expected %0d (increment %0d after %0d, %0d clocks after a restart, %0d after a start; time %0t)",
                                              r, dut.odd[r], want, d6, sc_d[r], age_r[r], age_s[r], $time);
                    odd_bad++;
                end
                if (m_mask[r] && !unread && age_r[r] >= 17 && age_s[r] >= 3) begin
                    cov_steady++;
                    if (dd6 == 6'd2 || dd6 == 6'd62) cov2++;
                    if (dd6 == 6'd3 || dd6 == 6'd61) cov3++;
                end
                sc_d[r] = d6; sc_p[r] = c6;
                if (unread) age_s[r] = 0;
            end
            m_flag |= dut.odd;
            //  the totals: differences of the model's whole periods, as they
            //  are; only a ring that was switched off steps modulo 64
            te = totals();
            for (int r = 0; r < R; r++) begin
                cur = hold[r] ? m_prev[r] : w2[r][63:32] + {{26{inj[r][5]}}, inj[r]};      //  the error is signed
                if (m_on) begin
                    d = (cur >= m_prev[r]) ? cur - m_prev[r] : {26'd0, 6'(cur[5:0] - m_prev[r][5:0])};
                    m_tot[r] += d[TW-1:0];
                    m_wide[r] += longint'(d);
                end
                m_prev[r] = cur;
            end
            m_on = 1;
            t = totals();
            if (dut.tot_n !== t) tot_bad++;
            if (m_late) q_late[q_late.size() - 1] = t;
            m_late = 0;
            //  the record
            take = m_held >= 0 && reg_re && reg_raddr == R_DATA1;
            due  = val && m_div >= m_every;
            if (val) m_div = due ? 0 : m_div + 1;
            if (take) m_held = -1;
            if (due) begin
                q_tot.push_back(t); q_early.push_back(te); q_late.push_back(t);
                q_b.push_back(b); q_pb.push_back(pb); q_seq.push_back(m_seq); q_strobe.push_back(strobes);
                m_late = 1;
                if (m_held < 0) m_held = q_tot.size() - 1; else m_loss = 1;
                m_seq++;
            end
            if (|dut.odd && m_bad < 65535) m_bad++;
            if (reg_we && reg_waddr == R_CTRL) begin
                m_every = int'(reg_wdata[15:0]); m_src = reg_wdata[22]; m_sel = reg_wdata[25:23]; m_ref = reg_wdata[26];
                m_hi = reg_wdata[27];
                if (reg_wdata[31]) begin
                    m_div = 0; m_seq = 0; m_held = -1; m_loss = 0; m_bad = 0; m_flag = '0;
                    for (int r = 0; r < R; r++) age_s[r] = 0;
                end
                if (reg_wdata[21:16] != m_mask || reg_wdata[28] != m_dir) m_loss = 1;
                for (int r = 0; r < R; r++)
                    if ((reg_wdata[16 + r] && !m_mask[r]) || reg_wdata[28] != m_dir) age_r[r] = 0;
                m_mask = reg_wdata[21:16];
                m_dir = reg_wdata[28];
            end
        end
        for (int r = 0; r < R; r++) begin
            w2[r] <= w1[r]; w1[r] <= w0[r];
            w0[r] <= {noise.clr_q[r] ? 32'd0 : noise.dir_q ? noise.g_model.turn[r] : noise.g_model.turn[r] >> 1, noise.g_model.phase[r]};
        end
    end

    //  ---- accesses ----
    logic [63:0] got;
    task automatic regw(input [1:0] a, input [63:0] v);
        @(negedge clk); reg_we = 1; reg_waddr = a; reg_wdata = v;
        @(negedge clk); reg_we = 0;
    endtask
    task automatic regr(input [1:0] a);         //  a read that is taken
        @(negedge clk); reg_re = 1; reg_raddr = a;
        #1; got = reg_rdata;
        @(negedge clk); reg_re = 0;
    endtask
    task automatic look(input [1:0] a);         //  the value, without taking a read
        @(negedge clk); reg_raddr = a; #1; got = reg_rdata;
    endtask
    function automatic [63:0] cv(input int every, input [5:0] mask, input bit src, input [2:0] sel, input bit start,
                                 input bit refs = 0, input bit hi = 0, input bit direct = 0);
        return {32'd0, start, 2'd0, direct, hi, refs, sel, src, mask, 16'(every - 1)};
    endfunction
    //  CTRL as it reads after becoming active, and a read value without the
    //  two flags of the record (a record may fall due at once)
    function automatic [63:0] ctrl_reset();
        return {26'd0, op_mask, 10'd0, op_mask, 16'd0};
    endfunction
    function automatic [63:0] config_of(input [63:0] v);
        return v & ~64'h0000_0300_0000_0000;
    endfunction

    task automatic enter();
        @(negedge clk); test = 1;
    endtask
    task automatic leave();
        @(negedge clk); test = 0;
        @(negedge clk);
    endtask
    task automatic again();                     //  out of test mode and in: the totals start anew
        leave(); enter();
    endtask
    task automatic wait_valid(input int guard, input string what);
        int n = 0;
        look(R_DATA0);
        while (!got[63]) begin
            if (n++ > guard) check(0, {what, ": a record arrives"});
            look(R_DATA0);
        end
    endtask
    task automatic wait_due();                  //  to the cycle in which a record falls due
        @(negedge clk);
        while (!(val && m_div >= m_every)) @(negedge clk);
    endtask

    //  One record, read as the host does and compared with record `idx` of
    //  the bench's list. loss, seq: what the flags must be; -1 for what the
    //  bench's bookkeeping has.
    task automatic read_record(input string what, input int idx, input int loss, input int seq);
        logic [63:0]     d0, d1;
        logic [TW*R-1:0] t;
        bit              l;
        look(R_DATA0); d0 = got; l = (loss < 0) ? m_loss : (loss != 0);
        check(cnt_bad == 0, {what, ": in every clock cnt_o is the model's count of three clock edges before"});
        check(bit_bad == 0, {what, ": every symbol is the bits of the model phase at the edge its counts are from"});
        check(ref_bad == 0, {what, ": every reference bit is the bit of the model phase at the edge its counts are from"});
        check(tot_bad == 0, {what, ": the totals follow the reference in every clock"});
        check(d0[63] && idx >= 0 && idx < q_tot.size() && idx == m_held, {what, ": the expected record is held"});
        regr(R_DATA1); d1 = got;
        t = {d1[59:0], d0[59:0]};
        check(d0[61:60] == ((seq < 0) ? q_seq[idx] : 2'(seq)), {what, ": the record's sequence number"});
        check(d1[63:60] == q_b[idx], {what, ": the record's lane bits are the symbol of its strobe"});
        check(d1[63:60] == q_pb[idx], {what, ": a lane bit is 1 exactly when the model phase at the totals' edge is below the duty"});
        check(!(t == q_early[idx] && t != q_tot[idx]), {what, ": the totals are not those of one clock before the bits"});
        check(!(t == q_late[idx] && t != q_tot[idx]), {what, ": the totals are not those of one clock after the bits"});
        check(t == q_tot[idx], {what, ": the record's totals are the model's periods at the edge its bits were sampled"});
        check(d0[62] == l, {what, ": the loss flag"});
    endtask

    //  A run of records at a sampling period and a divider. When each can be
    //  read before the next falls due, none may be lost.
    task automatic run(input int period, input int every, input int count, input string what);
        int     first, idx;
        longint s0;
        bit     quick;
        div = 8'(period - 1);
        repeat (period + 4) @(negedge clk);
        regw(R_CTRL, cv(every, m_mask, 0, 0, 1));
        first = q_tot.size(); s0 = strobes;
        quick = period * every >= 4;            //  the bench reads a record in four clocks
        for (int i = 0; i < count; i++) begin
            wait_valid(period * every + 16, what);
            idx = m_held;
            if (quick) begin
                //  seen one clock after it was stored: at a period of one clock, one strobe later
                check(strobes - s0 >= longint'(every) * (i + 1) && strobes - s0 <= longint'(every) * (i + 1) + (period == 1 ? 1 : 0),
                      {what, ": a record at every n-th strobe, counted from the start"});
                check(idx == first + i && q_strobe[idx] - s0 == longint'(every) * (i + 1),
                      {what, ": no record is lost when each is read before the next falls due"});
            end
            read_record(what, idx, quick ? 0 : -1, quick ? i % 4 : -1);
        end
        if (!quick) begin
            look(R_CTRL);
            check(got[41] && m_loss, {what, ": records fall due faster than they are read, and loss says so"});
        end
    endtask

    int          first, idx0, idx1, n0, turns, r0, soak;
    bit          healthy;
    longint      dn, dd;
    logic [63:0] d0a, d1a;
    logic [TW*R-1:0] ta, tb;
    string       dump;
    initial begin
        if (!$value$plusargs("rosc_turns=%d", turns)) turns = 0;
        for (int m = 0; m < L; m++) flips[m] = 0;
        for (int r = 0; r < R; r++) inj[r] = 6'd0;
        healthy = $test$plusargs("healthy");
        if (!$value$plusargs("soak=%d", soak)) soak = 20000;
        repeat (4) @(negedge clk);
        rst = 0;
        repeat (8) @(negedge clk);

        //  ================= outside test mode: nothing to see, nothing to set =================
        look(R_CTRL);  check(got == 64'd0, "outside test mode CTRL reads zero");
        look(R_DATA0); check(got == 64'd0, "outside test mode DATA0 reads zero");
        look(R_DATA1); check(got == 64'd0, "outside test mode DATA1 reads zero");
        look(2'd3);    check(got == 64'd0, "address 3 reads zero");
        regw(R_CTRL, cv(5, 6'h3f, 1, 3'd2, 1));
        regr(R_DATA1); check(got == 64'd0, "a DATA1 read outside test mode returns zero");
        repeat (40) @(negedge clk);
        check(ring_en === op_mask, "outside test mode ring_en_o is op_mask_i, whatever was written");
        check(respaces == 0, "outside test mode: no respace pulse");
        op_mask = 6'b101011;                    //  another strap (a pulse here is the bench's doing: a strap is static)
        @(negedge clk); #1;
        check(ring_en === 6'b101011, "outside test mode ring_en_o follows the strap");
        op_mask = 6'b001111;
        repeat (20) @(negedge clk);
        check(out_bad == 0, "outside test mode: in every clock ring_en_o is op_mask_i, burst_sym_o is rng_b_i, the registers read zero");
        r0 = respaces;
        check(dut.tot_q == '0 && !dut.valid_q && !dut.seen_q, "outside test mode: the totals and the record stay at their reset values");

        //  ================= entering =================
        div = 8'd31;
        repeat (40) @(negedge clk);
        enter();
        n0 = int'(strobes);
        #1;
        check(ring_en === op_mask, "entering test mode leaves the rings as they are");
        look(R_CTRL);
        check(config_of(got) == ctrl_reset(), "on becoming active: every - 1 = 0, mask = op_mask_i, source 0; the write made outside test mode left nothing");
        wait_valid(80, "the first record");
        check(int'(strobes) - n0 == 1, "on becoming active a record is taken at every strobe: the first strobe is recorded");
        check(m_held == 0, "bench: the first record that fell due is held");
        read_record("the first record in test mode", 0, 0, 0);
        look(R_DATA0);
        check(!got[63], "a DATA1 read takes the record: valid is clear");
        ta = q_tot[0];
        check(got[59:0] == ta[59:0], "the contents of a taken record stay until the next one");
        wait_valid(80, "the second record");
        d0a = got;
        regr(R_DATA0);
        look(R_DATA1);
        look(R_DATA0);
        check(got == d0a, "a taken read of DATA0 and a look at DATA1 without a read take nothing");
        read_record("the second record in test mode", 1, 0, 1);
        check(respaces == r0, "entering test mode does not pulse respace_o");
        check(mask_bad == 0, "in test mode ring_en_o is the mask");
        //  the divider, by itself: a write without the start bit
        regw(R_CTRL, cv(3, m_mask, 0, 0, 0));
        wait_valid(120, "every 3");
        n0 = int'(strobes);
        regr(R_DATA1);
        wait_valid(120, "every 3");
        check(int'(strobes) - n0 == 3, "a record at every n-th strobe: with every = 3 the third strobe after the record before");
        read_record("every 3, no start", m_held, 0, -1);
        regw(R_CTRL, cv(1, m_mask, 0, 0, 0));
        wait_valid(120, "every 1 again");
        regr(R_DATA1);

        //  ================= the start bit; a held record is not overwritten; loss; the sequence number =================
        div = 8'd2;
        repeat (20) @(negedge clk);
        do wait_due(); while (m_seq == 2'd3);   //  the count of records is not at zero when the start comes
        check(m_held >= 0 && m_loss && q_seq[m_held] != 2'd0, "bench: before the start a record is held, records were lost, its sequence number is not zero");
        regw(R_CTRL, cv(2, m_mask, 0, 0, 1));
        first = q_tot.size(); n0 = int'(strobes);
        look(R_DATA0);
        check(got == 64'd0, "start: valid, loss, the sequence number and the held record are cleared");
        look(R_CTRL);
        check(got[41:40] == 2'b00 && got[15:0] == 16'd1, "start: CTRL shows no record and no loss");
        wait_valid(32, "start");
        check(int'(strobes) - n0 == 2, "a record at every n-th strobe, counted from the start: here the second");
        check(m_held == first && got[62:60] == 3'b000, "the first record after a start is held with sequence number 0, and nothing is lost yet");
        read_record("the first record after a start", first, 0, 0);
        wait_valid(32, "second");
        read_record("the second record after a start", first + 1, 0, 1);
        //  the host's two reads, with a record falling due between them
        wait_valid(32, "third");
        idx0 = m_held;
        regr(R_DATA0); d0a = got;
        wait_due();
        look(R_DATA0);
        check(got[62], "a record that falls due while one is held is dropped: loss is set in the next cycle");
        n0 = q_tot.size();
        regr(R_DATA1); d1a = got;
        check(idx0 == first + 2 && n0 == idx0 + 2, "bench: one record fell due between the two reads");
        check({d1a[59:0], d0a[59:0]} == q_tot[idx0] && d1a[63:60] == q_b[idx0] && d0a[61:60] == q_seq[idx0] && d0a[63],
              "DATA0 and DATA1 read in different cycles with a record falling due in between are the two halves of one record");
        look(R_DATA0);
        check(got[62], "loss stays set after the held record is taken");
        //  the next record: the fifth that fell due, the fourth that was stored
        wait_valid(32, "held");
        idx0 = m_held;
        d0a = got;
        check(idx0 == first + 4, "bench: the record after the dropped one is held");
        check(got[61:60] == 2'd0, "the sequence number counts dropped records too: the next stored record shows the gap");
        wait_due();
        look(R_DATA0);
        check(got[61:0] == d0a[61:0] && got[63], "a held record is not overwritten: DATA0 is unchanged after a later record fell due");
        repeat (5) @(negedge clk);
        regr(R_DATA1);
        ta = q_tot[idx0];
        check(got == {q_b[idx0], ta[TW*R-1:60]}, "nor is DATA1");
        wait_valid(32, "gap");
        idx1 = m_held;
        check(idx1 > idx0 + 2 && (idx1 - first) % 4 != 0, "bench: more than one record was dropped, and not a multiple of four fell due");
        check(got[61:60] == 2'(idx1 - first), "after several dropped records the sequence number is that of the records that fell due");
        read_record("the record after a gap", idx1, 1, -1);
        //  loss stays set through records that are read in time
        regw(R_CTRL, cv(4, m_mask, 0, 0, 0));
        repeat (3) begin
            wait_valid(32, "after a loss");
            read_record("read in time after a loss: loss stays set until a start", m_held, 1, -1);
        end
        //  the start restarts the divider: with a record every 5th strobe, a
        //  start two strobes after a record moves the next record
        wait_due();
        regw(R_CTRL, cv(5, m_mask, 0, 0, 1));
        wait_valid(40, "divider");
        read_record("every 5", m_held, 0, 0);
        n0 = int'(strobes);
        while (int'(strobes) < n0 + 2) @(negedge clk);
        regw(R_CTRL, cv(5, m_mask, 0, 0, 1));
        n0 = int'(strobes);
        wait_valid(40, "divider restart");
        check(int'(strobes) - n0 == 5, "the start restarts the divider: the next record is the fifth strobe after it");
        read_record("the first record after a restart", m_held, 0, 0);
        //  a record that falls due in the cycle of the read that takes the held one
        wait_due();
        regw(R_CTRL, cv(4, m_mask, 0, 0, 1));
        first = q_tot.size();
        wait_valid(40, "take");
        idx0 = m_held;
        wait_due();
        reg_re = 1; reg_raddr = R_DATA1;
        #1; d1a = reg_rdata;
        @(negedge clk); reg_re = 0;
        ta = q_tot[idx0];
        check(d1a == {q_b[idx0], ta[TW*R-1:60]}, "the read in the cycle of a new record returns the held record");
        look(R_DATA0);
        check(got[63], "a record that falls due in the cycle of the DATA1 read that takes the held one is stored");
        check(!got[62] && got[61:60] == 2'd1, "and nothing is lost: the stored record is the next in sequence");
        read_record("the record stored in the cycle of a take", idx0 + 1, 0, 1);
        regr(R_DATA1);
        look(R_DATA0);
        check(!got[63] && !got[62], "a DATA1 read without a held record takes nothing and loses nothing");
        wait_due();
        run(8, 3, 3, "period 8, every 3");

        //  ================= the burst capture's symbol =================
        div = 8'd0;
        regw(R_CTRL, cv(1000, 6'h3f, 0, 0, 1));
        repeat (8) @(negedge clk);
        check(ring_en === 6'h3f, "in test mode ring_en_o is the written mask: all rings run for what follows");
        check(sym_bad == 0, "source 0: burst_sym_o is rng_b_i");
        for (int s = 0; s < 8; s++) begin
            div = (s % 2 != 0) ? 8'd2 : 8'd0;
            regw(R_CTRL, cv(1000, 6'h3f, 1, 3'(s), 0));
            repeat (90) @(negedge clk);
            check(sym_bad == 0, $sformatf("source 1, ring %0d: burst_sym_o is the low four bits of that ring's count of the edge at which the symbol of the cycle was sampled%s",
                                          s, s < 6 ? "" : " (no such ring: zero)"));
            look(R_CTRL);
            check(got[25:22] == {3'(s), 1'b1}, "CTRL reads the source and the ring back");
        end
        //  the upper four bits of a count
        for (int s = 0; s < 6; s += 5) begin
            regw(R_CTRL, cv(1000, 6'h3f, 1, 3'(s), 0, 0, 1));
            repeat (90) @(negedge clk);
            check(sym_bad == 0, $sformatf("source 1 with CTRL[27], ring %0d: burst_sym_o is the upper four bits of the count", s));
            look(R_CTRL);
            check(got[27:22] == {1'b1, 1'b0, 3'(s), 1'b1}, "CTRL reads [27] back");
        end
        //  the reference bits, with lanes 0 and 1
        for (int s = 0; s < 2; s++) begin
            div = (s != 0) ? 8'd2 : 8'd0;
            regw(R_CTRL, cv(1000, 6'h3f, 0, 3'd5, 0, 1));
            for (int m = 0; m < R - L; m++) rflips[m] = 0;
            repeat (90) @(negedge clk);
            check(sym_bad == 0, "reference source: burst_sym_o is the two reference bits above the bits of lanes 0 and 1");
            check(rflips[0] > 3 && rflips[1] > 3, "bench: both reference bits moved meanwhile");
        end
        look(R_CTRL);
        check(got[26] && !got[22], "CTRL reads the reference source back");
        div = 8'd0;
        regw(R_CTRL, cv(1000, 6'h3f, 1, 3'd4, 0, 1));
        repeat (90) @(negedge clk);
        check(sym_bad == 0, "count and reference source both set: the count wins");
        look(R_CTRL);
        check(got[26:22] == {1'b1, 3'd4, 1'b1}, "CTRL reads both source bits back");
        regw(R_CTRL, cv(1000, 6'h3f, 0, 3'd5, 0));
        repeat (8) @(negedge clk);
        check(sym_bad == 0, "source 0 again: burst_sym_o is rng_b_i");


        //  ================= leaving: nothing is kept =================
        regw(R_CTRL, cv(3, op_mask, 1, 3'd2, 1, 1));
        wait_valid(40, "before leaving");
        wait_due();
        look(R_CTRL);
        check(got[41:40] == 2'b11 && got[26:0] == cv(3, op_mask, 1, 3'd2, 0, 1), "bench: a configuration, a held record and a loss to leave behind");
        r0 = respaces;
        @(negedge clk);
        while (cnt[6*2 +: 4] === b) @(negedge clk);     //  a cycle in which the chosen count is not the symbol
        test = 0;
        #1;
        check(sym === b && reg_rdata == 64'd0, "leaving test mode: the burst symbol is rng_b_i and the registers read zero in the same cycle");
        repeat (3) @(negedge clk);
        check(respaces == r0, "leaving test mode with the mask at op_mask_i does not pulse respace_o");
        regw(R_CTRL, cv(9, 6'h15, 1, 3'd1, 1));
        look(R_DATA0); check(got == 64'd0, "after leaving, DATA0 reads zero");
        @(negedge clk); en = 0;                 //  no symbols for a while: nothing new is recorded
        repeat (4) @(negedge clk);
        enter();
        look(R_CTRL);
        check(got == ctrl_reset(), "back in test mode: the configuration is at its reset values, no record, no loss");
        look(R_DATA0);
        check(got == 64'd0, "back in test mode: nothing of the earlier record is left in DATA0");
        look(R_DATA1);
        check(got == 64'd0, "back in test mode: nothing of the earlier record is left in DATA1");
        @(negedge clk); en = 1;
        wait_valid(40, "re-entered");
        read_record("the first record after re-entering: the totals start anew", m_held, -1, 0);
        //  with a mask of its own: the rings change in the cycle test mode ends
        regw(R_CTRL, cv(3, 6'h3d, 0, 0, 1));
        repeat (6) @(negedge clk);
        r0 = respaces;
        @(negedge clk); test = 0;
        #1;
        check(ring_en === op_mask, "leaving test mode: ring_en_o is op_mask_i in the same cycle");
        repeat (3) @(negedge clk);
        check(respaces == r0 + 1, "leaving test mode with a mask that is not op_mask_i pulses respace_o once");

        //  ================= the lock, a reset =================
        enter();
        regw(R_CTRL, cv(7, 6'h3f, 1, 3'd3, 1));
        wait_valid(80, "before the lock");
        r0 = respaces;
        @(negedge clk);
        while (cnt[6*3 +: 4] === b) @(negedge clk);
        lock = 1;
        #1;
        check(ring_en === op_mask && sym === b, "locked in test mode: the rings and the burst symbol are those of normal operation");
        look(R_CTRL);  check(got == 64'd0, "locked: CTRL reads zero");
        look(R_DATA0); check(got == 64'd0, "locked: DATA0 reads zero");
        look(R_DATA1); check(got == 64'd0, "locked: DATA1 reads zero");
        regw(R_CTRL, cv(3, 6'h3f, 1, 3'd1, 1));
        repeat (20) @(negedge clk);
        check(ring_en === op_mask, "locked: a write does not change the rings");
        check(respaces == r0 + 1, "the lock ends the mask: one respace pulse");
        @(negedge clk); lock = 0;
        look(R_CTRL);
        check(config_of(got) == ctrl_reset(), "unlocked again: the configuration is at its reset values, the locked write left nothing");
        wait_valid(40, "unlocked");
        read_record("the first record after a lock: the totals start anew", m_held, -1, 0);
        //  locked outside test mode, then test mode
        leave();
        @(negedge clk); lock = 1;
        enter();
        regw(R_CTRL, cv(3, 6'h3f, 1, 3'd1, 1));
        look(R_CTRL); check(got == 64'd0, "test mode entered while locked: nothing readable, nothing writable");
        repeat (20) @(negedge clk);
        @(negedge clk); lock = 0; test = 0;
        repeat (2) @(negedge clk);
        check(out_bad == 0, "outside test mode or locked: in every clock ring_en_o is op_mask_i, burst_sym_o is rng_b_i, the registers read zero");
        //  a reset in test mode
        enter();
        regw(R_CTRL, cv(7, 6'h3f, 1, 3'd3, 1));
        wait_valid(80, "before a reset");
        @(negedge clk); rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        look(R_CTRL);
        check(config_of(got) == ctrl_reset(), "a reset in test mode: the configuration is at its reset values");
        repeat (8) @(negedge clk);
        regw(R_CTRL, cv(8, m_mask, 0, 0, 1));
        wait_valid(80, "after a reset");
        read_record("after a reset", m_held, 0, 0);

        //  ================= records at sampling periods of 1, 3 and 256 clocks =================
        again(); run(1, 1, 8, "period 1, every 1");
        again(); run(1, 2, 8, "period 1, every 2");
        again(); run(1, 4, 8, "period 1, every 4");
        again(); run(1, 5, 8, "period 1, every 5");
        again(); run(1, 16, 6, "period 1, every 16");
        again(); run(1, 300, 4, "period 1, every 300");
        again(); run(3, 1, 8, "period 3, every 1");
        again(); run(3, 3, 6, "period 3, every 3");
        again(); run(3, 7, 6, "period 3, every 7");
        again(); run(256, 1, 3, "period 256, every 1");
        again(); run(256, 3, 3, "period 256, every 3");

        //  ================= the ring mask =================
        again();
        div = 8'd0;
        r0 = respaces;
        regw(R_CTRL, cv(1000, 6'h3f, 0, 0, 1));
        @(negedge clk); #1;
        check(respaces == r0 + 1, "a write that changes the ring mask pulses respace_o once");
        check(ring_en === 6'h3f, "in test mode ring_en_o is the written mask");
        look(R_CTRL);
        check(got[41], "a write that changes the ring mask sets loss, also with the start bit");
        check(got[28:0] == cv(1000, 6'h3f, 0, 0, 0) && got[37:32] == op_mask && got[31:29] == 3'd0, "CTRL reads back as written, with op_mask_i");
        regw(R_CTRL, cv(64, 6'h3f, 0, 0, 1));
        look(R_CTRL);
        check(respaces == r0 + 1 && !got[41], "a write of the same mask does not pulse respace_o, and its start clears loss");
        //  the references run: their totals advance
        for (int m = 0; m < R - L; m++) rflips[m] = 0;
        repeat (2) begin
            wait_valid(90, "references on");
            ta = tb; tb = q_tot[m_held];
            read_record("references on", m_held, 0, -1);
        end
        check(tb[TW*4 +: TW] != ta[TW*4 +: TW] && tb[TW*5 +: TW] != ta[TW*5 +: TW], "the reference rings run when the mask has them: their totals advance");
        check(rflips[0] > 0 && rflips[1] > 0, "and their bits move");
        //  the references off
        regw(R_CTRL, cv(64, 6'h0f, 0, 0, 0));
        repeat (10) @(negedge clk);
        regw(R_CTRL, cv(64, 6'h0f, 0, 0, 1));
        for (int m = 0; m < R - L; m++) rflips[m] = 0;
        repeat (3) begin
            wait_valid(90, "references off");
            ta = tb; tb = q_tot[m_held];
            read_record("references off", m_held, 0, -1);
        end
        check(tb[TW*4 +: 2*TW] == ta[TW*4 +: 2*TW], "a reference ring that is off: its total stands still");
        check(rflips[0] == 0 && rflips[1] == 0, "a reference ring that is off reads as a constant in its bit");
        check(tb[0 +: TW] != ta[0 +: TW] && tb[TW*3 +: TW] != ta[TW*3 +: TW], "and the lane rings run on");
        //  a lane ring off
        regw(R_CTRL, cv(64, 6'h3d, 0, 0, 0));
        repeat (10) @(negedge clk);
        regw(R_CTRL, cv(64, 6'h3d, 0, 0, 1));
        for (int m = 0; m < L; m++) flips[m] = 0;
        repeat (25) begin
            wait_valid(90, "lane ring off");
            ta = tb; tb = q_tot[m_held];
            read_record("a lane ring off", m_held, 0, -1);
        end
        check(tb[TW*1 +: TW] == ta[TW*1 +: TW], "a lane ring that is off: its total stands still");
        check(flips[1] == 0, "a lane ring that is off reads as a constant on its lane");
        check(flips[0] > 20 && flips[2] > 20 && flips[3] > 20, "and the other lanes move");
        check(tb[TW*4 +: TW] != ta[TW*4 +: TW] && tb[TW*5 +: TW] != ta[TW*5 +: TW] && tb[0 +: TW] != ta[0 +: TW],
              "and the rings that are on are counted");
        check(mask_bad == 0, "in test mode ring_en_o is the mask in every clock");

        //  ================= counts that are not readable =================
        again();
        div = 8'd0;
        regw(R_CTRL, cv(1000, 6'h1f, 0, 0, 1));
        repeat (4) @(negedge clk);
        regw(R_CTRL, cv(1000, 6'h1f, 0, 0, 1));
        check(odd_bad == 0, "up to here, in every clock a ring is flagged exactly when the bench's rule says so: never, with healthy rings");
        look(R_CTRL); check(got[63:48] == 16'd0 && m_bad == 0, "no count has been reported bad");
        @(negedge clk); inject = 6'b000100; repeat (5) @(negedge clk); inject = '0;
        look(R_CTRL); check(got[63:48] == 16'd5, "five clocks with a ring of the mask reporting bad are counted");
        check(got[47:42] == 6'b000100, "and its bit of CTRL[47:42] is set");
        @(negedge clk); inject = 6'b100000; repeat (4) @(negedge clk); inject = '0;
        look(R_CTRL); check(got[63:48] == 16'd5, "a ring that is not in the mask is not counted");
        check(got[47:42] == 6'b000100, "nor flagged");
        @(negedge clk); inject = 6'b101001; repeat (3) @(negedge clk); inject = '0;
        look(R_CTRL); check(got[63:48] == 16'd8, "clocks are counted, not rings");
        check(got[47:42] == 6'b001101, "the flags of the rings stay set, one bit per ring");
        check(tot_bad == 0, "the bad flag alone does not change a total");
        regw(R_CTRL, cv(1000, 6'h1f, 0, 0, 1));
        look(R_CTRL); check(got[63:42] == 22'd0, "start clears the count of bad clocks and the flags of the rings");
        @(negedge clk); inject = 6'b000010; repeat (65540) @(negedge clk); inject = '0;
        look(R_CTRL); check(got[63:48] == 16'hffff && m_bad == 65535, "the count of bad clocks stops at 65535");
        again();
        look(R_CTRL); check(got[63:42] == 22'd0, "the count of bad clocks and the flags do not outlive test mode");
        leave();

        //  ================= the consistency of the counts =================
        enter();
        div = 8'd0;
        regw(R_CTRL, cv(1000, 6'h1f, 0, 0, 1));
        repeat (24) @(negedge clk);
        regw(R_CTRL, cv(1000, 6'h1f, 0, 0, 1));
        repeat (8) @(negedge clk);
        look(R_CTRL);
        check(got[63:42] == 22'd0, "a ring switched on by the mask, then a start: no count is flagged");
        //  a count that is wrong by sixteen in one clock
        @(negedge clk); inj[2] = 6'd16;
        @(negedge clk); inj[2] = 6'd0;
        #1;
        check(reg_rdata[47:42] == 6'b000100, "a count wrong by sixteen is flagged in the clock it is read, on its ring only");
        repeat (6) @(negedge clk);
        look(R_CTRL);
        check(got[63:48] == 16'd3, "one wrong count: three clocks have an increment that does not fit the one before");
        repeat (60) @(negedge clk);
        look(R_CTRL);
        check(got[63:42] == {16'd3, 6'b000100}, "the flag of the ring and the count of clocks stay");
        regw(R_CTRL, cv(1000, 6'h1f, 0, 0, 1));
        look(R_CTRL);
        check(got[63:42] == 22'd0, "start clears them");
        repeat (4) @(negedge clk);
        //  a ring that is not in the mask
        @(negedge clk); inj[5] = 6'd16;
        @(negedge clk); inj[5] = 6'd0;
        repeat (4) @(negedge clk);
        look(R_CTRL);
        check(got[63:42] == 22'd0, "a ring that is not in the mask is not checked");
        //  a count that is not readable repeats: the two increments after it are not compared
        @(negedge clk); inject = 6'b000001; hold = 6'b000001;
        @(negedge clk); inject = '0; hold = '0;
        repeat (8) @(negedge clk);
        look(R_CTRL);
        check(got[63:42] == {16'd1, 6'b000001}, "a count that was not readable: that clock is counted, the increments on either side of it are not compared");
        //  small errors: the threshold
        regw(R_CTRL, cv(1000, 6'h1f, 0, 0, 1));
        for (int i = 0; i < 120; i++) begin
            repeat (6 + i % 9) @(negedge clk);
            inj[i % 5] = (i % 2 != 0) ? 6'(1 + i % 3) : 6'(63 - i % 3);
            @(negedge clk);
            for (int r = 0; r < R; r++) inj[r] = 6'd0;
        end
        repeat (8) @(negedge clk);
        check(odd_bad == 0, "with errors of 1 to 3 added: a ring is flagged exactly when its count is not readable or its increment differs from the last by more than 2");
        check(cov2 > 0 && cov3 > 0, "bench: increments that differ by exactly 2 and by exactly 3 both occurred");
        check(tot_bad == 0 && m_flag == dut.flag_q, "bench: the totals and the flags are as the bench has them");

        //  ================= direct counting =================
        regw(R_CTRL, cv(256, 6'h3f, 0, 0, 1));
        repeat (24) @(negedge clk);
        regw(R_CTRL, cv(256, 6'h3f, 0, 0, 1));
        repeat (2) begin
            wait_valid(300, "pairs of periods");
            ta = tb; tb = q_tot[m_held];
            read_record("counts in units of two periods", m_held, 0, -1);
        end
        dn = longint'(20'(tb[TW-1:0] - ta[TW-1:0]));
        check(dir_o === 1'b0 && noise.dir_q === 1'b0, "CTRL[28] clear: cnt_direct_o is 0");
        r0 = respaces;
        regw(R_CTRL, cv(256, 6'h3f, 0, 0, 0, 0, 0, 1));
        #1;
        check(dir_o === 1'b1, "CTRL[28] set: cnt_direct_o is 1");
        @(negedge clk); #1;
        check(respaces == r0 + 1, "a write that changes the counting mode pulses respace_o once");
        look(R_CTRL);
        check(got[41], "a write that changes the counting mode sets loss");
        check(got[28:0] == cv(256, 6'h3f, 0, 0, 0, 0, 0, 1), "CTRL reads the counting mode back");
        repeat (4) @(negedge clk);
        check(noise.dir_q === 1'b1, "the noise source has taken the mode");
        repeat (24) @(negedge clk);
        regw(R_CTRL, cv(256, 6'h3f, 0, 0, 1, 0, 0, 1));
        look(R_CTRL);
        check(respaces == r0 + 1 && !got[41], "a write of the same mode does not pulse respace_o, and its start clears loss");
        repeat (2) begin
            wait_valid(300, "periods");
            ta = tb; tb = q_tot[m_held];
            read_record("counts in units of one period", m_held, 0, -1);
        end
        dd = longint'(20'(tb[TW-1:0] - ta[TW-1:0]));
        check(dd >= 20 && dd - 2 * dn <= 64 && 2 * dn - dd <= 64,
              $sformatf("ring 0 in 256 clocks: %0d counts directly, %0d divided by two: the two modes are in the ratio 2", dd, dn));
        check(odd_bad == 0, "a change of the counting mode restarts every ring: nothing is flagged for it");
        //  leaving in direct mode
        regw(R_CTRL, cv(256, op_mask, 0, 0, 1, 0, 0, 1));
        repeat (4) @(negedge clk);
        r0 = respaces;
        @(negedge clk); test = 0;
        #1;
        check(dir_o === 1'b0, "leaving test mode: cnt_direct_o is 0 in the same cycle");
        repeat (3) @(negedge clk);
        check(respaces == r0 + 1, "leaving test mode in direct mode pulses respace_o once");
        enter();
        look(R_CTRL);
        check(config_of(got) == ctrl_reset() && dir_o === 1'b0, "back in test mode: the counting mode is 0 again");
        check(out_bad == 0, "outside test mode cnt_direct_o is 0 in every clock");

        //  ================= healthy rings, for a long time, in both modes =================
        leave(); enter();
        for (int mode = 0; mode < 2; mode++) begin
            regw(R_CTRL, cv(1000, 6'h3f, 0, 0, 1, 0, 0, mode != 0));
            repeat (30) @(negedge clk);
            regw(R_CTRL, cv(1000, 6'h3f, 0, 0, 1, 0, 0, mode != 0));
            cov_steady = 0;
            repeat (soak) @(negedge clk);
            look(R_CTRL);
            check(cov_steady >= longint'(R) * (soak - 4), "bench: every ring was compared with the bench's own rule in every clock");
            check(odd_bad == 0, $sformatf("%0d clocks, a count %0s: a ring is flagged exactly when the bench's rule says so",
                                          soak, mode != 0 ? "one period" : "two periods"));
            $display("soak, a count %0s: %0d clocks, %0d of them flagged (rings %b)", mode != 0 ? "one period" : "two periods", soak, got[63:48], got[47:42]);
            if (healthy)
                check(got[63:42] == 22'd0, $sformatf("%0d clocks, a count %0s: no count of a healthy ring is flagged",
                                                     soak, mode != 0 ? "one period" : "two periods"));
        end
        check(tot_bad == 0 && dir_bad == 0, "the totals followed the reference in both modes, and cnt_direct_o was CTRL[28] in every clock");
        leave();

        //  ================= a long run from reset: the totals wrap, and the dump =================
        op_mask = 6'h3f;
        div = 8'd0;
        if ($value$plusargs("dump=%s", dump)) dump_fd = $fopen({dump, ".a.txt"}, "w");
        @(negedge clk); rst = 1; test = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);
        dumping = dump_fd != 0;                 //  the first line: the cycle after the first clock edge out of reset
        regw(R_CTRL, cv(4096, 6'h3f, 0, 0, 1));
        first = q_tot.size();
        for (int i = 0; i < 31; i++) begin
            wait_valid(4200, "long run");
            check(m_held == first + i, "long run: no record is lost at one record per 4096 clocks");
            read_record("long run", m_held, 0, i % 4);
        end
        regw(R_CTRL, cv(65536, 6'h3f, 0, 0, 1));
        n0 = int'(strobes);
        look(R_CTRL); check(got[15:0] == 16'hffff, "every - 1 = 65535 reads back");
        wait_valid(65600, "every 65536");
        check(q_strobe[m_held] - longint'(n0) == 65536, "every = 65536: the record is the 65536th strobe after the start");
        read_record("long run, every 65536", m_held, 0, 0);
        if (turns >= 20)
            check(m_wide[0] >= 64'd1048576, "long run: ring 0 has counted more than 2^20, so its total has wrapped");
        check(tot_bad == 0, "long run: the totals follow the reference through their wrap");
        @(negedge clk); dumping = 0;
        if (dump_fd != 0) $fclose(dump_fd);
        //  a second stretch, with two rings off by the strap, counting directly
        @(negedge clk); test = 0; op_mask = 6'h2b; rst = 1; force_dir = 1;
        if (dump_fd != 0) dump_fd = $fopen({dump, ".b.txt"}, "w");
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);
        dumping = dump_fd != 0;
        repeat (20000) @(negedge clk);
        dumping = 0;
        if (dump_fd != 0) $fclose(dump_fd);

        check(cnt_bad == 0, "in every clock of the run cnt_o was the model's count of three clock edges before");
        check(bit_bad == 0, "every symbol of the run was the bits of the model phase at the edge its counts are from");
        check(ref_bad == 0, "every reference bit of the run was the bit of the model phase at the edge its counts are from");
        check(out_bad == 0 && mask_bad == 0 && sym_bad == 0 && tot_bad == 0, "the rings, the burst symbol, the registers outside test mode and the totals held in every clock");
        check(odd_bad == 0 && dir_bad == 0, "and so did the flags of the counts and the counting mode");
        $display("rosc meter test: PASS (%0d checks)", checks);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("FAIL rosc meter check: timeout");
        $fatal(1);
    end
endmodule

`ifdef KARU_ROSC_BENCH
`timescale 1ps/1fs
//  A ring as the bench makes it, in place of the inverter loop (the hook of
//  flow/fpga/karu_rosc_rng.v). Off, its output is high, as the closed gate
//  leaves the real ring. On, the output falls first, and every rising edge
//  after that is counted here: `edges` is the true count of the run.
module karu_rosc_bench_ring #(parameter int RING = 0, parameter int N = 3) (
    input  wire         en_i,
    output wire [N-1:0] inv_o
);
    logic    osc = 1'b1;
    longint  edges = 0;
    realtime t_osc = 0;                         //  when osc last changed
    function automatic real part(input real share);
        return tb_rosc_cnt.cfg_period[RING] * share
             + tb_rosc_cnt.cfg_jitter[RING] * (real'($urandom) / 2147483648.0 - 1.0);
    endfunction
    initial forever begin
        osc = 1'b1;
        wait (en_i === 1'b1);
        edges = 0;
        while (en_i === 1'b1) begin
            #(part(tb_rosc_cnt.cfg_duty[RING]));
            osc = 1'b0; t_osc = $realtime;
            #(part(1.0 - tb_rosc_cnt.cfg_duty[RING]));
            osc = 1'b1; t_osc = $realtime; edges++;
        end
    end
    assign inv_o = {N{osc}};
endmodule

//  The routing between a counter's ring-domain flops and what they drive
//  (the hook of karu_rosc_cnt). q_o is what the sampling flops see at the
//  coming clock edge: flop k as it was dq[k] ps before. It is worked out
//  once per clock, just before the edge, from the time of each flop's last
//  change, so that the delays cost no simulation events (a flop changes at
//  most once within its delay). clr_o is the clear as it arrives at the
//  Johnson flops, at counter a and at counter b, dclr[] ps late.
module karu_rosc_bench_route (
    input  wire  [11:0] q_i,
    output logic [11:0] q_o,
    input  wire         clr_i,
    output logic [2:0]  clr_o
);
    real         dq [0:11];
    real         dclr [0:2];
    realtime     tq [0:11];
    logic [11:0] last = '0, was = '0;
    initial begin
        for (int k = 0; k < 12; k++) begin dq[k] = 0.0; tq[k] = 0.0; end
        for (int k = 0; k < 3; k++) dclr[k] = 0.0;
        q_o = '0; clr_o = '1;
    end
    always @(q_i) begin
        for (int k = 0; k < 12; k++) if (q_i[k] !== last[k]) begin was[k] = last[k]; tq[k] = $realtime; end
        last = q_i;
    end
    always @(tb_rosc_cnt.pre)
        for (int k = 0; k < 12; k++) q_o[k] = ($realtime + 0.001 - tq[k] >= dq[k]) ? q_i[k] : was[k];
    for (genvar k = 0; k < 3; k++) begin : g_clr
        always @(clr_i) clr_o[k] <= #(dclr[k]) clr_i;
    end
endmodule

//  The look-up table of the counters' dividers (in the FPGA flow: the
//  vendor's LUT3). The output is INIT[{I2, I1, I0}], d_out ps after the
//  inputs. Two models. For the long runs: nothing else, one event per
//  change. With KARU_ROSC_DIV, for the divider's races: each input is also
//  d_in[] ps late at its pin, the route to it, and a pulse shorter than
//  d_out does not pass the table.
`ifdef KARU_ROSC_DIV
module LUT3 #(parameter [7:0] INIT = 8'h00) (
    output logic O,
    input  wire  I0, I1, I2
);
    real         d_in [0:2];
    real         d_out = 50.0;
    logic [2:0]  pin = '0;                      //  the inputs at the pins
    int unsigned change = 0;
    wire  [2:0]  in = {I2, I1, I0};
    wire         f  = INIT[pin];
    initial begin
        d_in[0] = 0.0; d_in[1] = 0.0; d_in[2] = 0.0;
        O = 1'b0;
    end
    for (genvar k = 0; k < 3; k++) begin : g_pin
        always @(in[k]) pin[k] <= #(d_in[k]) in[k];
    end
    always @(f) begin
        change++;
        fork
            begin
                automatic int unsigned mine = change;
                automatic logic        v    = f;
                #(d_out);
                if (mine == change) O = v;
            end
        join_none
    end
endmodule
`else
module LUT3 #(parameter [7:0] INIT = 8'h00) (
    output logic O,
    input  wire  I0, I1, I2
);
    real d_out = 50.0;
    wire f = INIT[{I2, I1, I0}];
    initial O = 1'b0;
    always @(f) if (f !== O) begin
        if (d_out > 0.0) #(d_out);
        O = INIT[{I2, I1, I0}];
    end
endmodule
`endif

module tb_rosc_cnt;
    localparam int  R = 6, L = 4, SETS = 10;
    localparam real HALF = 6666.667;            //  75 MHz
    logic clk = 1'b0, pre = 1'b0, rst = 1'b1, en = 1'b0, direct = 1'b0;
    logic [R-1:0] ring_en = '1;
    //  `pre` moves one femtosecond before the rising clock edge: the bench
    //  takes its own samples there
    initial forever begin
        #(HALF - 0.001) pre = ~pre;
        #0.001          clk = 1'b1;
        #(HALF)         clk = 1'b0;
    end

    //  per ring: period, jitter (each half period moves by up to this much
    //  either way) and duty cycle; the delays of the twelve ring-domain
    //  flops and of the clear, the smallest of the Johnson bits' delays, and
    //  the delays of the divider's three tables
    real  cfg_period [0:R-1], cfg_jitter [0:R-1], cfg_duty [0:R-1];
    real  cfg_dq [0:R-1][0:11], cfg_dclr [0:R-1][0:2], cfg_djmin [0:R-1], cfg_lut [0:R-1][0:2];
    logic cfg_load = 1'b0;

    wire           val;
    wire [L-1:0]   b;
    wire [6*R-1:0] cnt;
    wire [R-1:0]   bad;
    wire [R-L-1:0] rb;
    wire [R-1:0]   bits = {rb, b};              //  every ring's sampled bit
    karu_rosc_rng #(.STREAMS(L), .REFS(R - L), .SIM(0)) dut (
        .clk(clk), .rst(rst), .rng_en_i(en), .rng_fips_i(1'b0), .rng_div_i(8'd0), .ring_en_i(ring_en),
        .cnt_direct_i(direct),
        .rng_val_o(val), .rng_b_o(b), .ref_b_o(rb), .cnt_o(cnt), .cnt_bad_o(bad));

    int checks = 0;
    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) begin
            $display("FAIL rosc counter check %0d: %s (time %0t)", checks, what, $time);
            $fatal(1);
        end
    endtask

    int unsigned seed;
    function automatic real urand();            //  uniform in [0, 1)
        seed = seed * 32'd1664525 + 32'd1013904223;
        return real'(seed >> 8) / 16777216.0;
    endfunction

    //  ======================================================================
    //  One counter by itself, on a ring and a sampling clock that the tests
    //  drive: the divider's tables and their races, the decoder's windows.
    //  ======================================================================
    logic        dring = 1'b1, dclr = 1'b1, ddir = 1'b0, dclk = 1'b0, drun = 1'b0;
    wire  [5:0]  dcount;
    wire         dbad;
    real         dper = 500.0, dduty = 0.5, djit = 0.0, djmin = 0.0;
    longint      drises = 0, dfalls = 0;        //  edges of the ring
    longint      dstog = 0, dmtog = 0, djtog = 0, djn = 0;      //  changes of S, of M, of jclk; rising edges of jclk
    longint      s_low = 0, m_high = 0, j_low = 0;              //  changes in the wrong half of the ring's period
    realtime     djt [0:63];                    //  when jclk last rose
    karu_rosc_cnt dcnt (.ring_i(dring), .clr_i(dclr), .direct_i(ddir), .clk(dclk), .cnt_o(dcount), .bad_o(dbad));
    initial forever begin
        wait (drun);
        while (drun) begin
            #(dper * dduty + djit * (real'($urandom) / 2147483648.0 - 1.0));
            dring = 1'b0; dfalls++;
            #(dper * (1.0 - dduty) + djit * (real'($urandom) / 2147483648.0 - 1.0));
            dring = 1'b1; drises++;
        end
    end
    always @(dcnt.div_sq) begin dstog++; if (dring !== 1'b1) s_low++; end
    always @(dcnt.div_mq) begin dmtog++; if (dring !== 1'b0) m_high++; end
    always @(dcnt.jclk) begin
        djtog++;
        if (dring !== 1'b1) j_low++;
        if (dcnt.jclk === 1'b1) begin djt[djn[5:0]] = $realtime; djn++; end
    end
    //  the rising edges of jclk up to a time not long ago
    function automatic longint dcount_at(input realtime at);
        dcount_at = djn;
        for (int k = 0; k < 64 && dcount_at > 0 && djt[6'(dcount_at - 1)] > at; k++) dcount_at--;
    endfunction
    //  what a look-up table with this INIT gives
    function automatic bit lut(input [7:0] init, input bit i2, input bit i1, input bit i0);
        return init[{i2, i1, i0}];
    endfunction

`ifdef KARU_ROSC_DIV
    //  the delays of the divider's tables and of the routes to them (ps)
    task automatic ddetail(input real d_m, input real d_s, input real c_m, input real c_s,
                           input real r_sm, input real r_ms, input real r_mm, input real r_ss);
        dcnt.div_m.d_out = d_m; dcnt.div_m.d_in[0] = c_m; dcnt.div_m.d_in[1] = r_mm; dcnt.div_m.d_in[2] = r_sm;
        dcnt.div_s.d_out = d_s; dcnt.div_s.d_in[0] = c_s; dcnt.div_s.d_in[1] = r_ss; dcnt.div_s.d_in[2] = r_ms;
        dcnt.div_x.d_out = 50.0; dcnt.div_x.d_in[0] = c_s; dcnt.div_x.d_in[1] = 40.0; dcnt.div_x.d_in[2] = 0.0;
    endtask
`endif
    //  the delays of the twelve ring-domain flops to the sampling flops, in ps
    task automatic droute(input real j, input real a, input real b_);
        for (int k = 0; k < 8; k++) dcnt.route.dq[k] = j;
        dcnt.route.dq[8] = a; dcnt.route.dq[9] = a; dcnt.route.dq[10] = b_; dcnt.route.dq[11] = b_;
        djmin = j;
    endtask
    //  From clear, with the latches in a chosen state: `go` lets the ring run,
    //  otherwise the test makes the edges itself with dstep.
    task automatic dstart(input real period, input bit dir, input bit state, input bit go);
        drun = 1'b0;
        #(3.0 * dper + 3000.0);
        dclr = 1'b1; ddir = dir; dper = period;
        #1000;
        dcnt.div_m.O = state;                   //  the ring idles high: the slave follows
        #2000;
        drises = 0; dfalls = 0; dstog = 0; dmtog = 0; djtog = 0; djn = 0; s_low = 0; m_high = 0; j_low = 0;
        dclr = 1'b0;
        #1000;
        drun = go;
    endtask
    task automatic dstop();
        drun = 1'b0;
        #(3.0 * dper + 3000.0);
    endtask
    task automatic dstep();                     //  one period of the ring, by hand
        dring = 1'b0; dfalls++; #200;
        dring = 1'b1; drises++; #200;
    endtask
    //  One sample: three edges of the counter's sampling clock a few
    //  femtoseconds apart, so that cnt_o is the decode of what the first one
    //  took (and the other two took the same). n_ref is the count that the
    //  Johnson bits show at the sampling flops then.
    task automatic dsample(output logic [5:0] c, output logic bd, output longint n_ref);
        n_ref = dcount_at($realtime + 0.001 - djmin);
        repeat (3) begin
            pre = ~pre; #0.001;
            dclk = 1'b1; #0.001;
            dclk = 1'b0; #0.001;
        end
        #1;
        c = dcount; bd = dbad;
    endtask

    //  ---- the divider with routes: one point of the sweep ----
    //  Runs the ring for `n` periods and says what S did: 0 once per rising
    //  edge of the ring, 1 more often (double toggles), 2 less often.
    int  sw_ok = 0, sw_double = 0, sw_lost = 0;
    task automatic dpoint(input real period, input real duty, input int n, output int kind);
        dduty = duty; djit = 1.0;
        dstart(period, 1'b0, 1'b0, 1'b1);
        #(period * n);
        dstop();
        kind = (dstog == drises && dmtog == dfalls) ? 0 : (dstog > drises || dmtog > dfalls) ? 1 : 2;
        dduty = 0.5; djit = 0.0;
    endtask

    //  ======================================================================
    //  The noise source as synthesised, on six rings of the bench.
    //  ======================================================================
    longint       s_edges [0:R-1];              //  ring edges just before this clock edge
    longint       s_jn [0:R-1];                 //  rising edges of the counter's clock that the Johnson bits show then
    longint       s_stog [0:R-1];               //  changes of the divider's S
    logic [R-1:0] s_gate = '0;                  //  the ring's gate was open then
    longint       jn [0:R-1], stog [0:R-1];
    realtime      jt [0:R-1][0:63];
    longint       hn [0:3][0:R-1];              //  s_jn at the four edges before
    longint       he [0:3][0:R-1];              //  s_edges
    logic [R-1:0] hg [0:3];
    logic [3:0]   hm = '0;                      //  the counting mode
    int           since_rst = 0;
    longint       n_new [0:R-1], n_old [0:R-1], n_16 [0:R-1], n_other [0:R-1], n_unw [0:R-1], n_stage [0:R-1];
    longint       n_run [0:R-1], n_off [0:R-1], n_off_bad [0:R-1], n_bad [0:R-1], n_div [0:R-1], n_ratio [0:R-1];
    longint       cov_al [0:R-1], cov_ae [0:R-1], cov_bl [0:R-1], cov_be [0:R-1];
    longint       n_mode [0:1];                 //  counts read in each mode
    longint       seq_n = 0, seq_bad = 0, bit_n = 0, bit_bad = 0, rbit_n = 0, rbit_bad = 0, clocks = 0, dir_seq_bad = 0, dir_changes = 0;
    int           open_for [0:R-1];             //  samples since the gate opened
    logic [63:0]  seen [0:R-1];                 //  count values read
    bit           u_on [0:R-1];                 //  the bench's own unwrapping, as the meter does it
    longint       u_tot [0:R-1];
    logic [5:0]   u_prev [0:R-1];
    bit [R-1:0]   skip = '0, steady = '0;
    int           shown = 0;
    logic [R-1:0] p_clr = '1, p_en = '0;
    logic         p_dir = 1'b0, p_pin = 1'b0;

    function automatic longint count_at(input int r, input realtime at);
        count_at = jn[r];
        for (int k = 0; k < 64 && count_at > 0 && jt[r][6'(count_at - 1)] > at; k++) count_at--;
    endfunction

    for (genvar r = 0; r < R; r++) begin : g_tap
        //  the ring's level at the last three clock edges, and whether it
        //  changed in the instant of the edge
        logic [2:0] lv = '1, rc = '0;
        wire        gate;
        if (r < L) begin : g_lane
            assign gate = dut.g_rings.g_ring[r].ring.en_i;
            always @(pre) s_edges[r] = dut.g_rings.g_ring[r].ring.edges;
            always @(posedge clk) begin
                lv <= {lv[1:0], dut.g_rings.g_ring[r].ring.osc};
                rc <= {rc[1:0], dut.g_rings.g_ring[r].ring.t_osc == $realtime};
            end
        end else begin : g_refr
            assign gate = dut.g_rings.g_ref[r - L].ring.en_i;
            always @(pre) s_edges[r] = dut.g_rings.g_ref[r - L].ring.edges;
            always @(posedge clk) begin
                lv <= {lv[1:0], dut.g_rings.g_ref[r - L].ring.osc};
                rc <= {rc[1:0], dut.g_rings.g_ref[r - L].ring.t_osc == $realtime};
            end
        end
        //  the counter's clock and the divider's S, counted from the opening of the gate
        always @(posedge dut.g_rings.g_cnt[r].cnt.jclk) begin jt[r][jn[r][5:0]] = $realtime; jn[r]++; end
        always @(dut.g_rings.g_cnt[r].cnt.div_sq) stog[r]++;
        always @(posedge gate) begin jn[r] = 0; stog[r] = 0; end
        always @(pre) begin
            s_gate[r] = gate === 1'b1;
            s_jn[r]   = count_at(r, $realtime + 0.001 - cfg_djmin[r]);
            s_stog[r] = stog[r];
        end
        //  a lane's bit and a reference's: the level three edges back
        always @(posedge clk) if (val && since_rst > 4) begin
            if (r < L) begin
                bit_n++;
                if (!rc[2] && bits[r] !== lv[2]) bit_bad++;
            end else begin
                rbit_n++;
                if (!rc[2] && bits[r] !== lv[2]) rbit_bad++;
            end
        end
        always @(cfg_load) begin
            for (int k = 0; k < 12; k++) dut.g_rings.g_cnt[r].cnt.route.dq[k] = cfg_dq[r][k];
            for (int k = 0; k < 3; k++)  dut.g_rings.g_cnt[r].cnt.route.dclr[k] = cfg_dclr[r][k];
            dut.g_rings.g_cnt[r].cnt.div_m.d_out = cfg_lut[r][0];
            dut.g_rings.g_cnt[r].cnt.div_s.d_out = cfg_lut[r][1];
`ifndef KARU_ROSC_DIV
            dut.g_rings.g_cnt[r].cnt.div_x.d_out = cfg_lut[r][2];
`endif
        end
        //  Did the bench put the decoder where its windows matter? The
        //  sampled flops against the true count of their edge: a coarse
        //  counter one step ahead of the Johnson state, or one behind.
        always @(posedge clk) if (steady[r]) begin : covered
            logic [11:0] g;
            logic [1:0]  ca, cb, ta, tb;
            longint      n;
            int          ones, f;
            g = dut.g_rings.g_cnt[r].cnt.gs_q;
            ones = $countones(g[7:0]);
            f = g[0] ? ones : g[7] ? 16 - ones : 0;
            ca = {g[9], g[9] ^ g[8]}; cb = {g[11], g[11] ^ g[10]};
            n = (int'(hn[1][r][3:0]) == f) ? hn[1][r] : hn[1][r] - 1;      //  the count that the Johnson bits of the sample show
            ta = 2'((n + 15) >> 4); tb = 2'((n + 8) >> 4);
            if (ca == 2'(ta - 2'd1)) cov_al[r]++;
            if (ca == 2'(ta + 2'd1)) cov_ae[r]++;
            if (cb == 2'(tb - 2'd1)) cov_bl[r]++;
            if (cb == 2'(tb + 2'd1)) cov_be[r]++;
        end
    end

    always @(posedge clk) begin : monitor
        logic [5:0] c;
        int         d;
        longint     e, q;
        since_rst = rst ? 0 : since_rst + 1;
        clocks++;
        //  the counting mode, at the counters, changes only when, in the clock
        //  before, every counter was in clear and every gate closed, and no
        //  clear is released with it
        if (dut.dir_q !== p_dir) dir_changes++;
        if (dut.g_rings.g_cnt[0].cnt.direct_i !== p_pin && (p_clr !== '1 || p_en !== '0 || dut.clr_q !== '1)) dir_seq_bad++;
        p_dir = dut.dir_q; p_pin = dut.g_rings.g_cnt[0].cnt.direct_i; p_clr = dut.clr_q; p_en = dut.en_q;
        for (int r = 0; r < R; r++) if (since_rst > 4 && !skip[r]) begin
            c = cnt[6*r +: 6];
            if (bad[r] !== 1'b0) n_bad[r]++;
            //  the divider: S has changed once for every edge of the ring
            if (s_gate[r] && (s_edges[r] - s_stog[r] < 0 || s_edges[r] - s_stog[r] > 1)) n_div[r]++;
            if (hg[2][r]) begin
                //  the gate was open at the edge this count was sampled at
                d = (int'(c) - int'(hn[2][r][5:0]) + 64) % 64;
                n_run[r]++; n_mode[hm[2]]++;
                if (d == 0) n_new[r]++;
                else if (d == 63) n_old[r]++;
                else begin
                    if (d == 15 || d == 16 || d == 31 || d == 32 || d == 47 || d == 48) n_16[r]++; else n_other[r]++;
                    if (shown++ < 6) $display("ring %0d: count %0d read, true count %0d (period %0.3f ps, mode %0d, %0d clocks after its gate opened)",
                                              r, c, hn[2][r], cfg_period[r], hm[2], open_for[r]);
                end
                //  not the count of its own edge, but of the edge after or before: a stage too few or too many
                if (d != 0 && d != 63 && hg[1][r] && (6'(c - hn[1][r][5:0]) == 6'd0 || 6'(c - hn[1][r][5:0]) == 6'd63)) n_stage[r]++;
                else if (d != 0 && d != 63 && hg[3][r] && (6'(c - hn[3][r][5:0]) == 6'd0 || 6'(c - hn[3][r][5:0]) == 6'd63)) n_stage[r]++;
                if (open_for[r] < 64) begin
                    seq_n++;
                    if (d != 0 && d != 63) seq_bad++;
                end
                open_for[r]++;
                seen[r][c] = 1'b1;
                if (!u_on[r]) u_tot[r] = longint'(c); else u_tot[r] += longint'(6'(c - u_prev[r]));
                u_on[r] = 1; u_prev[r] = c;
                e = u_tot[r] - hn[2][r];
                if (e != 0 && e != -1) n_unw[r]++;
                //  the unwrapped count times its unit against the ring's own edges
                q = (hm[2] ? u_tot[r] : 2 * u_tot[r]) - he[2][r];
                if (q > 1 || q < -10) n_ratio[r]++;
            end else begin
                n_off[r]++;
                if (c !== 6'd0) n_off_bad[r]++;
                open_for[r] = 0; u_on[r] = 0;
            end
            steady[r] = open_for[r] > 4;
        end
        for (int r = 0; r < R; r++) begin
            hn[3][r] <= hn[2][r]; hn[2][r] <= hn[1][r]; hn[1][r] <= hn[0][r]; hn[0][r] <= s_jn[r];
            he[3][r] <= he[2][r]; he[2][r] <= he[1][r]; he[1][r] <= he[0][r]; he[0][r] <= s_edges[r];
        end
        hg[3] <= hg[2]; hg[2] <= hg[1]; hg[1] <= hg[0]; hg[0] <= s_gate;
        hm <= {hm[2:0], dut.dir_q};
    end

    function automatic longint sum(input longint v [0:R-1]);
        sum = 0;
        for (int r = 0; r < R; r++) sum += v[r];
    endfunction
    task automatic clear_counts();
        for (int r = 0; r < R; r++) begin
            n_new[r] = 0; n_old[r] = 0; n_16[r] = 0; n_other[r] = 0; n_unw[r] = 0; n_stage[r] = 0;
            n_run[r] = 0; n_off[r] = 0; n_off_bad[r] = 0; n_bad[r] = 0; n_div[r] = 0; n_ratio[r] = 0; seen[r] = '0;
            cov_al[r] = 0; cov_ae[r] = 0; cov_bl[r] = 0; cov_be[r] = 0;
        end
        seq_n = 0; seq_bad = 0; bit_n = 0; bit_bad = 0; rbit_n = 0; rbit_bad = 0; n_mode[0] = 0; n_mode[1] = 0;
    endtask

    //  what the divider and the decoder owe, over the counts read so far
    task automatic decoder(input string what);
        check(sum(n_run) > 100 * R, {what, ": bench: the rings were read while running"});
        check(sum(n_bad) == 0, {what, ": bad never fires"});
        check(sum(n_div) == 0, {what, ": the divider's S changes once for every edge of the ring"});
        check(2 * sum(n_stage) < sum(n_run), {what, ": the counts are those of their own clock edge, three stages back, not of the edge before or after"});
        check(sum(n_16) == 0, {what, ": the decoded count is never wrong by sixteen"});
        check(sum(n_other) == 0, {what, ": the decoded count is the true count of its clock edge or one less"});
        check(sum(n_unw) == 0, {what, ": unwrapped modulo 64, the count follows the true number of edges of the counter's clock"});
        check(sum(n_ratio) == 0, {what, ": the count times its unit, two periods or one, is the number of ring periods"});
    endtask

    //  ---- periods and delays ----
    int  set, samples, points, margin_n;
    real periods [0:5];
    //  Delay set s. The Johnson bits reach the sampling flops with up to
    //  150 ps of skew between them. `early` clear: a coarse counter comes up
    //  to 600 ps (and its two bits up to 40 ps apart) after the Johnson bit
    //  that clocks it. `early` set: the Johnson bits are 600 ps late and a
    //  coarse counter comes anywhere from 600 ps before to 600 ps after the
    //  Johnson bit that clocks it. corner: five rings at the edges of those
    //  ranges. late_clear: the clear arrives up to 1.5 ns late at parts of a
    //  counter.
    task automatic configure(input int s, input bit corner, input bit early, input bit late_clear);
        real base, xa, xb, m;
        for (int r = 0; r < R; r++) begin
            cfg_period[r] = periods[(r + s + set) % 6] + 1.37 * set + 0.211 * s;
            cfg_jitter[r] = 1.0 + r % 3;
            cfg_duty[r]   = 0.42 + 0.03 * ((r + s) % 6);
            base = early ? 600.0 : 0.0;
            for (int k = 0; k < 8; k++) cfg_dq[r][k] = base + 150.0 * urand();
            xa = (early ? -600.0 : 0.0) + (early ? 1200.0 : 600.0) * urand();
            xb = (early ? -600.0 : 0.0) + (early ? 1200.0 : 600.0) * urand();
            if (corner) case (r)
                0: begin for (int k = 0; k < 8; k++) cfg_dq[r][k] = 0.0; xa = 0.0; xb = 0.0; end
                1: begin for (int k = 0; k < 8; k++) cfg_dq[r][k] = (k % 2 != 0) ? 150.0 : 0.0; xa = 600.0; xb = 600.0; end
                2: begin for (int k = 0; k < 8; k++) cfg_dq[r][k] = 600.0; xa = -600.0; xb = -600.0; end
                3: begin for (int k = 0; k < 8; k++) cfg_dq[r][k] = 600.0 + ((k % 2 != 0) ? 0.0 : 150.0); xa = 600.0; xb = -600.0; end
                4: begin for (int k = 0; k < 8; k++) cfg_dq[r][k] = 600.0 + ((k == 0 || k == 7) ? 150.0 : 0.0); xa = -750.0; xb = 600.0; end
                default: ;
            endcase
            cfg_dq[r][8]  = cfg_dq[r][0] + xa; cfg_dq[r][9]  = cfg_dq[r][0] + xa + 40.0 * urand();
            cfg_dq[r][10] = cfg_dq[r][7] + xb; cfg_dq[r][11] = cfg_dq[r][7] + xb + 40.0 * urand();
            for (int k = 8; k < 12; k++) if (cfg_dq[r][k] < 0.0) cfg_dq[r][k] = 0.0;
            m = cfg_dq[r][0];
            for (int k = 1; k < 8; k++) if (cfg_dq[r][k] < m) m = cfg_dq[r][k];
            cfg_djmin[r] = m;
            cfg_dclr[r][0] = !late_clear ? 0.0 : (r % 2 == 0) ? 100.0 : 1200.0;
            cfg_dclr[r][1] = !late_clear ? 0.0 : (r % 2 == 0) ? 1500.0 : 0.0;
            cfg_dclr[r][2] = !late_clear ? 0.0 : (r % 2 == 0) ? 300.0 : 0.0;
            cfg_lut[r][0] = 30.0 + 50.0 * urand(); cfg_lut[r][1] = 30.0 + 50.0 * urand(); cfg_lut[r][2] = 0.0;
        end
        cfg_load = ~cfg_load;
    endtask

    //  ---- the decoder's margins, on the counter by itself ----
    //  The Johnson bits and the two coarse counters reach the sampling flops
    //  `j`, `a` and `b_` states (periods of the counter's clock) late; in both
    //  counting modes and at both ends of the range of ring periods, every
    //  count read at a random instant must be the true one.
    task automatic margin(input real j, input real a, input real b_, output int wrong);
        logic [5:0] c;
        logic       bd;
        longint     n_ref;
        real        tj;
        wrong = 0;
        for (int mode = 0; mode < 2; mode++) for (int fastring = 0; fastring < 2; fastring++) begin
            tj = (fastring != 0 ? 371.519 : 997.413) * (mode != 0 ? 1.0 : 2.0);
            droute(j * tj, a * tj, b_ * tj);
            djit = 1.0;
            dstart(fastring != 0 ? 371.519 : 997.413, mode != 0, 1'b0, 1'b1);
            #(40.0 * tj);
            repeat (margin_n) begin
                #(tj * (3.0 + 29.0 * urand()));
                dsample(c, bd, n_ref);
                if (bd !== 1'b0 || (c !== 6'(n_ref) && c !== 6'(n_ref - 1))) begin
                    if (wrong < 3) $display("margin (Johnson %0.1f, a %0.1f, b %0.1f states late; period %0.0f ps, mode %0d): count %0d read, true count %0d",
                                            j, a, b_, tj, mode, c, n_ref);
                    wrong++;
                end
            end
            dstop();
            djit = 0.0;
        end
    endtask

    logic [5:0] good, c6;
    logic       bd;
    longint     nref;
    int unsigned x;
    int         kind, wrong, n_safe, n_safe_bad, n_must, n_must_bad, n_grey, n_grey_bad, k_r, k_f, k_s, k_m;
    int         n_in, n_in_safe, n_in_double, n_in_lost;
    real        p_per, p_duty, d_m, d_s, sk, c_m, c_s, r_sm, r_ms, r_mm, r_ss, hi, lo, mg;
    bit         safe, must_r, must_f, must_s, must_m;
    initial begin
        if (!$value$plusargs("set=%d", set)) set = 0;
        if (!$value$plusargs("samples=%d", samples)) samples = 200000;
        if (!$value$plusargs("points=%d", points)) points = 3000;
        if (!$value$plusargs("margin=%d", margin_n)) margin_n = 600;
        seed = 32'h5eed_0000 + set;
        periods = '{371.519, 450.137, 523.711, 617.293, 733.519, 997.413};
        clear_counts();
        for (int r = 0; r < R; r++) begin open_for[r] = 0; u_on[r] = 0; jn[r] = 0; stog[r] = 0; end
        configure(0, 1, 0, 0);

`ifdef KARU_ROSC_DIV
        //  ================= the divider's tables against their equations =================
        wrong = 0;
        for (int v = 0; v < 8; v++) if (lut(dcnt.div_m.INIT, v[2], v[1], v[0]) != (v[0] ? v[1] : !v[2])) wrong++;
        check(wrong == 0, "div_m, with I2 = S, I1 = M, I0 = C, is M = C ? M : ~S: transparent while the ring is low");
        wrong = 0;
        for (int v = 0; v < 8; v++) if (lut(dcnt.div_s.INIT, v[2], v[1], v[0]) != (v[0] ? v[2] : v[1])) wrong++;
        check(wrong == 0, "div_s, with I2 = M, I1 = S, I0 = C, is S = C ? M : S: transparent while the ring is high");
        wrong = 0;
        for (int v = 0; v < 8; v++) if (lut(dcnt.div_x.INIT, v[2], v[1], v[0]) != (v[2] ? v[0] : v[1])) wrong++;
        check(wrong == 0, "div_x, with I2 = direct, I1 = S, I0 = C, is jclk = direct ? C : S");

        //  ================= the divider as wired, with routes, from either state =================
        for (int v = 0; v < 8; v++) begin
            ddetail(60.0, 60.0, 30.0, 30.0, 40.0, 40.0, 30.0, 30.0);
            dstart(v[2] ? 371.519 : 997.413, v[1], v[0], 1'b1);
            #(40.5 * dper);
            dstop();
            check(drises >= 40 && dstog == drises && s_low == 0,
                  "S toggles once at every rising edge of the ring, from either starting state");
            check(dmtog == dfalls && m_high == 0, "M follows once at every falling edge of the ring");
            if (!v[1]) check(djtog == dstog && j_low == 0 && (2 * djn - drises <= 1 && drises - 2 * djn <= 1),
                             "jclk is S: one period for two of the ring");
            else       check(djtog == drises + dfalls && djn == drises, "with direct_i, jclk is the ring");
        end

        //  ================= the divider's races: where it is right, where it fails =================
        //  d: through a table; c: the arrival of C; r_xy: the route from x's
        //  output to y's input; H, L: the high and low time of the ring.
        //  Right is promised where, with a margin for the jitter,
        //    c_m - c_s < d_s + r_sm    c_s - c_m < d_m + r_ms
        //    d_s + r_sm - (c_m - c_s) < H    d_m + r_ms + (c_m - c_s) < L
        //    d_s + r_ss < H    d_m + r_mm < L
        //  Failure is certain where one of the first two is missed by so much
        //  that the latch that should have been closed passes the new value
        //  on, and the way round both tables is short enough for the value to
        //  come back within the half period, the other four still holding:
        //  S then toggles twice per period of the ring,
        //    c_m - c_s > d_s + r_sm + d_m + r_mm  and  2 d_s + r_sm + d_m + r_ms < H
        //    c_s - c_m > d_m + r_ms + d_s + r_ss  and  2 d_m + r_ms + d_s + r_sm + r_mm < L
        //  and where a table is slower than its half period, d_s > H or
        //  d_m > L: toggles are lost. In between it depends on more than
        //  these. A skew of C that is a large part of the period acts as
        //  that skew less a period, and with the way round longer than the
        //  half period the pair can toggle once per period at the wrong edge.
        n_safe = 0; n_safe_bad = 0; n_must = 0; n_must_bad = 0; n_grey = 0; n_grey_bad = 0; k_r = 0; k_f = 0; k_s = 0; k_m = 0;
        n_in = 0; n_in_safe = 0; n_in_double = 0; n_in_lost = 0;
        mg = 8.0;
        for (int i = 0; i < points; i++) begin
            //  two thirds inside the ranges of the routed design, the rest far outside
            p_per  = 371.519 + (997.413 - 371.519) * urand();
            p_duty = 0.42 + 0.16 * urand();
            if (i % 3 != 2) begin
                d_m = 30.0 + 120.0 * urand(); d_s = 30.0 + 120.0 * urand(); sk = -60.0 + 120.0 * urand();
                r_sm = 20.0 + 180.0 * urand(); r_ms = 20.0 + 180.0 * urand(); r_mm = 10.0 + 60.0 * urand(); r_ss = 10.0 + 60.0 * urand();
            end else if (i % 2 != 0) begin      //  quick tables and the ring far apart in time at the two latches
                d_m = 30.0 + 50.0 * urand(); d_s = 30.0 + 50.0 * urand(); sk = (100.0 + 250.0 * urand()) * (urand() < 0.5 ? -1.0 : 1.0);
                r_sm = 20.0 + 40.0 * urand(); r_ms = 20.0 + 40.0 * urand(); r_mm = 10.0 + 30.0 * urand(); r_ss = 10.0 + 30.0 * urand();
            end else begin                      //  a slow table
                d_m = 30.0 + 120.0 * urand(); d_s = 30.0 + 120.0 * urand(); sk = -60.0 + 120.0 * urand();
                if (urand() < 0.5) d_m = 250.0 + 500.0 * urand(); else d_s = 250.0 + 500.0 * urand();
                r_sm = 20.0 + 80.0 * urand(); r_ms = 20.0 + 80.0 * urand(); r_mm = 10.0 + 60.0 * urand(); r_ss = 10.0 + 60.0 * urand();
            end
            c_m = sk > 0.0 ? sk : 0.0; c_s = sk > 0.0 ? 0.0 : -sk;
            hi = p_per * p_duty - 1.0; lo = p_per * (1.0 - p_duty) - 1.0;
            safe   = sk < d_s + r_sm - mg && -sk < d_m + r_ms - mg && d_s + r_sm - sk < hi - mg && d_m + r_ms + sk < lo - mg
                  && d_s + r_ss < hi - mg && d_m + r_mm < lo - mg;
            must_r = sk - (d_s + r_sm) > d_m + r_mm + mg && 2.0 * d_s + r_sm + d_m + r_ms < hi - mg
                  && d_m + r_ms + sk < lo - mg && d_s + r_ss < hi - mg && d_m + r_mm < lo - mg;
            must_f = -sk - (d_m + r_ms) > d_s + r_ss + mg && 2.0 * d_m + r_ms + d_s + r_sm + r_mm < lo - mg
                  && d_s + r_sm - sk < hi - mg && d_s + r_ss < hi - mg && d_m + r_mm < lo - mg;
            must_s = d_s > hi + 2.0 + mg;
            must_m = d_m > lo + 2.0 + mg;
            ddetail(d_m, d_s, c_m, c_s, r_sm, r_ms, r_mm, r_ss);
            dpoint(p_per, p_duty, 40, kind);
            if (kind == 0) sw_ok++; else if (kind == 1) sw_double++; else sw_lost++;
            if (i % 3 != 2) begin
                n_in++;
                if (safe) n_in_safe++;
                if (kind == 1) n_in_double++;
                if (kind == 2) n_in_lost++;
            end
            if (safe) begin
                n_safe++;
                if (kind != 0) begin
                    if (n_safe_bad < 3) $display("divider wrong inside its conditions: period %0.0f duty %0.2f d_m %0.0f d_s %0.0f skew %0.0f r_sm %0.0f r_ms %0.0f r_mm %0.0f r_ss %0.0f: kind %0d",
                                                 p_per, p_duty, d_m, d_s, sk, r_sm, r_ms, r_mm, r_ss, kind);
                    n_safe_bad++;
                end
            end else if (must_r || must_f || must_s || must_m) begin
                n_must++;
                if (kind == 0) begin
                    if (n_must_bad < 3) $display("divider right where it must fail: period %0.0f duty %0.2f d_m %0.0f d_s %0.0f skew %0.0f r_sm %0.0f r_ms %0.0f r_mm %0.0f r_ss %0.0f (%b%b%b%b)",
                                                 p_per, p_duty, d_m, d_s, sk, r_sm, r_ms, r_mm, r_ss, must_r, must_f, must_s, must_m);
                    n_must_bad++;
                end
                //  one cause alone: the kind of failure it makes
                if (must_r && !must_f && !must_s && !must_m && kind == 1) k_r++;
                if (must_f && !must_r && !must_s && !must_m && kind == 1) k_f++;
                if (must_s && !must_r && !must_f && !must_m && kind == 2) k_s++;
                if (must_m && !must_r && !must_f && !must_s && kind == 2) k_m++;
            end else begin
                n_grey++;
                if (kind != 0) n_grey_bad++;
            end
        end
        $display("divider sweep: %0d points; %0d inside the conditions, %0d of them wrong; %0d where it must fail, %0d of them right; %0d between, %0d of them wrong. S once per ring period at %0d points, more often at %0d, less often at %0d",
                 points, n_safe, n_safe_bad, n_must, n_must_bad, n_grey, n_grey_bad, sw_ok, sw_double, sw_lost);
        $display("divider sweep, the %0d points with tables of 30 to 150 ps, routes of 20 to 200 ps (a latch's own loop 10 to 70 ps), a skew of the ring within 60 ps and periods of 0.37 to 1.0 ns: %0d inside the conditions; S more often than once per period at %0d, less often at %0d",
                 n_in, n_in_safe, n_in_double, n_in_lost);
        check(n_safe > points / 8 && n_must > points / 16, "bench: the sweep has points inside the divider's conditions and points far outside them");
        check(n_safe_bad == 0, "inside its conditions the divider toggles exactly once per period of the ring");
        check(n_must_bad == 0, "far outside them it does not");
        check(k_r > 0 && k_f > 0 && k_s > 0 && k_m > 0,
              "the failures are as said: S toggles twice when a latch is still open as the other's new value comes round and back, a toggle is lost when a table is slower than a half period");

        $display("rosc divider test: PASS (%0d checks, %0d points)", checks, points);
        $finish;
`else
        //  ================= the decoder with nothing in flight =================
        droute(0.0, 0.0, 0.0);
        for (int mode = 0; mode < 2; mode++) begin
            dstart(400.0, mode != 0, mode != 0, 1'b0);
            wrong = 0; kind = 0;
            for (int k = 0; k <= 300; k++) begin
                dsample(c6, bd, nref);
                if (c6 !== 6'(djn) || bd !== 1'b0 || nref != djn) wrong++;
                if (mode != 0 ? (djn != drises) : (2 * djn - drises > 1 || drises - 2 * djn > 1)) kind++;
                dstep();
            end
            check(wrong == 0, "with nothing in flight every count is the number of edges of the counter's clock, through four rounds of 64");
            check(kind == 0, mode != 0 ? "counting directly, that is the number of ring periods" : "divided by two, that is half the number of ring periods");
        end

        //  ================= the reviewer's case =================
        //  Counting directly, at the eighth edge of the ring, with coarse
        //  counter b reaching the sampling flops 100 ps before the Johnson
        //  bits: a sample between the two has Johnson state 7 and the new b.
        //  It may read 7 or 8. (The earlier rule gave 23.)
        droute(100.0, 100.0, 0.0);
        dstart(400.0, 1'b1, 1'b0, 1'b0);
        repeat (7) dstep();
        dsample(c6, bd, nref);
        check(c6 === 6'd7 && bd === 1'b0, "bench: seven edges of the ring, at rest: the count is 7");
        dring = 1'b0; dfalls++; #200;
        dring = 1'b1; drises++;
        wait (dcnt.j_q[7] === 1'b1);
        #50;
        dsample(c6, bd, nref);
        check(nref == 7 && dcnt.gs_q[7:0] === 8'b0111_1111 && dcnt.gs_q[11:10] === 2'b01,
              "bench: the sample has the Johnson state of 7 and coarse counter b already stepped");
        check((c6 === 6'd7 || c6 === 6'd8) && bd === 1'b0,
              "a sample between the arrival of coarse counter b and of the Johnson bits at the eighth edge reads 7 or 8");
        #400;
        //  the same half a cycle on, for coarse counter a at the step from 16 to 17
        droute(100.0, 0.0, 100.0);
        dstart(400.0, 1'b1, 1'b0, 1'b0);
        repeat (16) dstep();
        dring = 1'b0; dfalls++; #200;
        dring = 1'b1; drises++;
        wait (dcnt.a_q !== 2'b01);
        #50;
        dsample(c6, bd, nref);
        check(nref == 16 && dcnt.gs_q[7:0] === 8'b0000_0000 && dcnt.gs_q[9:8] === 2'b11,
              "bench: the sample has the Johnson state of 16 and coarse counter a already stepped again");
        check((c6 === 6'd16 || c6 === 6'd17) && bd === 1'b0,
              "a sample between the arrival of coarse counter a and of the Johnson bits at the seventeenth edge reads 16 or 17");
        #400;

        //  ================= the decoder's margins =================
        margin(3.5, 3.5, 0.0, wrong);
        check(wrong == 0, "coarse counter b at the sampling flops 3.5 states before the Johnson bits (its margin is 4): every count is right");
        margin(0.0, 2.5, 0.0, wrong);
        check(wrong == 0, "coarse counter a 2.5 states after the Johnson bits (its margin is 3): every count is right");
        margin(4.5, 0.0, 4.5, wrong);
        check(wrong == 0, "coarse counter a 4.5 states before the Johnson bits (its margin is 5): every count is right");
        margin(0.0, 0.0, 3.5, wrong);
        check(wrong == 0, "coarse counter b 3.5 states after the Johnson bits (its margin is 4): every count is right");
        droute(0.0, 0.0, 0.0);
        dstart(500.0, 1'b0, 1'b0, 1'b0);
        dclr = 1'b1;

        //  ================= the six rings: off =================
        repeat (4) @(negedge clk);
        rst = 0;
        repeat (12) @(negedge clk);
        check(sum(n_off) >= 6 * 5 && sum(n_off_bad) == 0 && sum(n_bad) == 0, "source off: every count is zero and no bad flag");

        //  ================= the long run: periods of 0.37 to 1.0 ns, ten delay sets, both modes =================
        //  Odd sets have the coarse counters early as well as late. Half way
        //  through a set the counting mode changes, with the rings running.
        //  Two rings run in a set (a simulation with all six is three times
        //  as long), each ring in three or four of the ten; the first set,
        //  with the corners of the delay ranges, has all six.
        for (int s = 0; s < SETS; s++) begin
            @(negedge clk); en = 0;
            repeat (4) @(negedge clk);
            configure(s, s == 0, s % 2 != 0, 0);
            ring_en = (s == 0) ? '1 : (6'b000001 << (s % 6)) | (6'b000001 << ((s + 3) % 6));
            en = 1;
            repeat (samples / SETS / 2) @(negedge clk);
            direct = ~direct;
            repeat (samples / SETS / 2) @(negedge clk);
            if (s == 0) begin
                check(dir_changes == 1 && dir_seq_bad == 0, "the counting mode changes only with every ring off and every counter in clear");
                check(2 * sum(n_stage) < sum(n_run), "the counts are those of their own clock edge, three stages back, not of the edge before or after");
                check(seq_bad == 0 && seq_n == longint'(R) * 2 * 64, "after every enable and every change of mode the count starts from zero");
                decoder("the delays at the corners of their ranges");
            end
        end
        ring_en = '1;
        check(sum(n_off) > 3 * longint'(samples - samples / SETS), "the rings that ring_en_i has off do not run: four of six were read as off through nine sets of ten");
        check(sum(n_run) > 2 * longint'(samples - 400) && n_mode[0] > sum(n_run) / 3 && n_mode[1] > sum(n_run) / 3,
              "bench: two rings or more were read in nearly every clock of the run, in both counting modes");
        check(dir_changes == SETS && dir_seq_bad == 0, "in every set the counting mode changed only with every ring off and every counter in clear");
        check(seq_bad == 0 && seq_n == longint'(R + 2 * (SETS - 1)) * 2 * 64, "in every set, after every enable and every change of mode the count starts from zero");
        decoder("ten delay sets");
        check(sum(n_off_bad) == 0, "a ring that is off has a count of zero");
        check(bit_bad == 0 && bit_n > longint'(L) * (samples - 200), "a lane bit is the level of its ring at the clock edge of the count");
        check(rbit_bad == 0 && rbit_n > longint'(R - L) * (samples - 200), "a reference bit is the level of its ring at the clock edge of the count");
        for (int r = 0; r < R; r++) begin
            check(n_new[r] > 0 && n_old[r] > 0, $sformatf("ring %0d was read during a change of its Johnson counter: the old and the new count both occurred", r));
            check(seen[r] == '1, $sformatf("ring %0d: all 64 counts were read", r));
        end
        check(sum(cov_al) > 0 && sum(cov_bl) > 0 && sum(cov_ae) > 0 && sum(cov_be) > 0,
              "both coarse counters were sampled a step behind the Johnson state and a step ahead of it: the cases the decoder's windows are for");
        $display("long run, set %0d: %0d clock edges; counts read from running rings: %0d the true count, %0d one behind (%0d in units of two periods, %0d of one); coarse counter a behind %0d times, ahead %0d, b behind %0d, ahead %0d",
                 set, clocks, sum(n_new), sum(n_old), n_mode[0], n_mode[1], sum(cov_al), sum(cov_ae), sum(cov_bl), sum(cov_be));

        //  ================= switching, with the clear late at parts of a counter =================
        @(negedge clk); en = 0;
        repeat (4) @(negedge clk);
        configure(SETS, 0, 0, 1);
        clear_counts();
        dir_changes = 0;
        en = 1;
        for (int i = 0; i < 80; i++) begin
            repeat (30 + i % 40) @(negedge clk);
            x = $urandom;
            if (i % 7 == 3)                     //  the counting mode
                direct = ~direct;
            else if (i % 3 == 0) begin          //  the whole source, for one to four clocks
                en = 0; repeat (1 + i % 4) @(negedge clk); en = 1;
            end else begin                      //  some rings, for one to five clocks
                ring_en = 6'(x) | 6'(x >> 6); repeat (1 + i % 5) @(negedge clk); ring_en = '1;
            end
        end
        repeat (80) @(negedge clk);
        check(seq_n > 100 * 64 && sum(n_off) > 500 && dir_changes > 8, "bench: rings were switched off and on, and the mode changed");
        check(dir_seq_bad == 0, "the counting mode changed only with every ring off and every counter in clear");
        check(seq_bad == 0 && sum(n_16) == 0 && sum(n_other) == 0 && sum(n_unw) == 0,
              "rings switched off and on, the clear late at parts of a counter: every run is counted from zero, never wrong by sixteen");
        check(sum(n_ratio) == 0 && sum(n_div) == 0, "and in each mode the count times its unit is the number of ring periods");
        check(sum(n_off_bad) == 0 && sum(n_bad) == 0, "a ring that is off reads zero, and bad never fires while switching");
        check(bit_bad == 0, "the lane of a ring that is off reads 1, as the closed gate leaves it");
        check(rbit_bad == 0, "and so does the bit of a reference that is off");

        //  ================= how long a change of the counting mode takes =================
        @(negedge clk); direct = 1'b0;
        repeat (20) @(negedge clk);
        check(dut.en_q === '1 && dut.clr_q === '0 && dut.dir_q === 1'b0, "bench: every ring runs, counting pairs of periods");
        direct = 1'b1;
        n_safe = 0; n_must = 0; kind = 0;
        repeat (6) begin
            @(negedge clk);
            if (dut.en_q === '0) n_safe++;
            if (dut.clr_q === '1) n_must++;
            if (dut.en_q !== '0 && dut.en_q !== '1) kind++;
        end
        check(n_safe == 3 && n_must == 2 && kind == 0 && dut.en_q === '1 && dut.dir_q === 1'b1,
              "a change of the counting mode: every gate is closed for three clocks, every counter in clear for two, and the mode has changed");
        repeat (20) @(negedge clk);

        //  ================= a Johnson counter outside its sixteen codes =================
        //  (an upset of the flops of ring 0's counter: the state then goes
        //  round a cycle of sixteen states none of which is a code)
        skip[0] = 1;
        @(negedge clk);
        dut.g_rings.g_cnt[0].cnt.j_q <= 8'b0010_0100;
        good = cnt[5:0];
        for (int i = 0; i < 4 && bad[0] !== 1'b1; i++) begin
            good = cnt[5:0];
            @(negedge clk);
        end
        check(bad[0] === 1'b1, "a Johnson state that is not one of the sixteen codes sets bad");
        check(cnt[5:0] === good, "with bad set, the count repeats its previous value");
        wrong = 0; kind = 0; n_safe = 0;
        repeat (300) begin
            c6 = cnt[5:0];
            @(negedge clk);
            if (bad[0] === 1'b1) n_safe++;
            if (bad[0] === 1'b1 && cnt[5:0] !== c6) wrong++;
            if (bad[5:1] !== 5'b00000) kind++;
        end
        check(wrong == 0, "in every clock with bad set the count stays");
        check(kind == 0, "the other rings are not affected");
        //  several flops change per period in such a state, so a sample may now and then look like a code
        x = {24'd0, dut.g_rings.g_cnt[0].cnt.j_q};
        check(n_safe >= 270 && $countones(x[7:1] ^ x[6:0]) > 1,
              "a counter that has left the sixteen codes does not return to them by itself: bad is set in nine clocks of ten or more");
        ring_en = 6'b111110;
        repeat (5) @(negedge clk);
        check(bad[0] === 1'b0 && cnt[5:0] === 6'd0, "switching the ring off clears its counter and the flag");
        skip[0] = 0;
        clear_counts();
        ring_en = '1;
        repeat (200) @(negedge clk);
        check(n_new[0] + n_old[0] > 190 && sum(n_bad) == 0 && sum(n_16) == 0 && sum(n_other) == 0 && sum(n_unw) == 0 && seq_bad == 0,
              "and its next run is counted from zero");

        $display("rosc counter test: PASS (%0d checks, set %0d, %0d clock edges)", checks, set, clocks);
        $finish;
`endif
    end
endmodule
`endif

`ifdef KARU_ROSC_LINT
//  For a lint of the noise source as it is synthesised: the look-up table
//  that the FPGA flow has as a primitive.
module LUT3 #(parameter [7:0] INIT = 8'h00) (output wire O, input wire I0, I1, I2);
    assign O = INIT[{I2, I1, I0}];
endmodule
`endif
