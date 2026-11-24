#!/usr/bin/env python3
"""Mutant controls for the phase meter of the ring oscillators and for the
period counters of the noise source (part of make rosc-meter-test).

Each mutant changes one mechanism of flow/fpga/karu_rosc_meter.v or of
flow/fpga/karu_rosc_rng.v (the noise source and its counter module
karu_rosc_cnt). It is built without the modules' own assertions
(KARU_NO_ASSERT), so test/tb_rosc_meter.sv alone has to notice, and it has
to notice with the check that was written for the mechanism: a mutant that
still passes is reported as MISSED, one that fails on another check as
OTHER, and either fails the run.

Three benches: "meter" is tb_rosc_meter (the meter on the behavioural model
of the source); "cnt" is tb_rosc_cnt (the source as synthesised, on rings
and routing delays made by the bench: the decoder, the switching of rings,
the counting mode); "div" is tb_rosc_cnt built with KARU_ROSC_DIV (one
counter's divider with the routes to its look-up tables).

    python3 test/rosc_meter_mutants.py --out _build/rosc-meter/mut [--rosc <karu_rosc_rng.v>]
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True)
parser.add_argument("--rosc", default=str(ROOT / "flow/fpga/karu_rosc_rng.v"), help="the noise source to mutate and to build with")
parser.add_argument("--jobs", type=int, default=12)
parser.add_argument("--only", help="run the mutants whose name contains this")
args = parser.parse_args()
OUT = Path(args.out).resolve()
TB = ROOT / "test/tb_rosc_meter.sv"
METER, ROSC = "meter", "rosc"
PATH = {METER: ROOT / "flow/fpga/karu_rosc_meter.v", ROSC: Path(args.rosc).resolve()}
RTL = {k: p.read_text() for k, p in PATH.items()}
BENCH = {   # top module, defines, the bench's plusargs, how a failed check begins
    "meter": ("tb_rosc_meter", [], ["+soak=20000"], "FAIL rosc meter check"),
    "cnt":   ("tb_rosc_cnt", ["-DKARU_ROSC_BENCH"], ["+samples=20000", "+margin=600"], "FAIL rosc counter check"),
    "div":   ("tb_rosc_cnt", ["-DKARU_ROSC_BENCH", "-DKARU_ROSC_DIV"], ["+points=900"], "FAIL rosc counter check"),
}

TOTALS = "the totals follow the reference in every clock"
RULE = "a ring is flagged exactly when"
DECODE = "wire [1:0] n = (f <= 4'd3) ? b : (f <= 4'd11) ? a - 2'd1 : b - 2'd1;"
REVIEW = "a sample between the arrival of coarse counter b and of the Johnson bits at the eighth edge reads 7 or 8"
REVIEW_A = "a sample between the arrival of coarse counter a and of the Johnson bits at the seventeenth edge reads 16 or 17"
REST = "with nothing in flight every count is the number of edges of the counter's clock"
B_EARLY = "coarse counter b at the sampling flops 3.5 states before the Johnson bits"
A_LATE = "coarse counter a 2.5 states after the Johnson bits"
A_EARLY = "coarse counter a 4.5 states before the Johnson bits"
B_LATE = "coarse counter b 3.5 states after the Johnson bits"
MODE = "the counting mode changes only with every ring off and every counter in clear"
DIV_M = "div_m, with I2 = S, I1 = M, I0 = C, is M = C ? M : ~S"
ODD = "assign odd[r] = mask_q[r] && (cnt_bad_i[r] || (ripe && far));"
RESPACE = "assign respace_o = remask || redir || (!active && (mask_q != op_mask_i || dir_q));"
START = "div_q <= 16'd0; seq_q <= 2'd0; valid_q <= 1'b0; loss_q <= 1'b0; bad_q <= 16'd0;"
BURST = "src_q ? cnt_sel : ref_q ? sym_ref : sym_pad[3:0];"
CTRL = "opm_pad[5:0], 3'b0, dir_q, hi_q, ref_q, sel_q, src_q,"
RUN = "wire [R-1:0] run = {R{rng_en_i && !rst && !dir_chg}} & ring_en_i;"

# (name, bench, file, [(old, new), ...], plusargs, the check that has to fail)
M = [
 # ---- karu_rosc_meter.v: unwrapping ----
 ("unwrap_modulo_32", "meter", METER, [("d    = cnt_i[6*r +: 6] - prev_q[6*r +: 6];", "d    = {1'b0, cnt_i[6*r +: 5] - prev_q[6*r +: 5]};")],
  ["+rosc_turns=40"], TOTALS),
 ("difference_not_modulo", "meter", METER, [("step = {{(TW-6){1'b0}}, d};", "step = {{(TW-6){1'b0}}, cnt_i[6*r +: 6]} - {{(TW-6){1'b0}}, prev_q[6*r +: 6]};")],
  ["+rosc_turns=9"], TOTALS),
 ("total_of_19_bits", "meter", METER, [("assign tot_n[TW*r +: TW] = tot_q[TW*r +: TW] + (seen_q ? step : {TW{1'b0}});",
                                         "assign tot_n[TW*r +: TW] = (tot_q[TW*r +: TW] + (seen_q ? step : {TW{1'b0}})) & 20'h7ffff;")],
  ["+rosc_turns=6"], "long run, every 65536: " + TOTALS),
 ("first_clock_adds_a_difference", "meter", METER, [("(seen_q ? step : {TW{1'b0}})", "step")],
  ["+rosc_turns=20"], "the first record in test mode: " + TOTALS),
 # ---- the record ----
 ("snapshot_one_clock_early", "meter", METER, [("rec_tot_q <= tot_n; rec_b_q <= rng_b_i;", "rec_tot_q <= tot_q; rec_b_q <= rng_b_i;")],
  ["+rosc_turns=20"], "the totals are not those of one clock before the bits"),
 ("snapshot_one_clock_late", "meter", METER, [("localparam integer TW = 20;", "localparam integer TW = 20;\n\treg late_q;"),
                                               ("rec_tot_q <= tot_n; rec_b_q <= rng_b_i;", "rec_b_q <= rng_b_i;"),
                                               ("\t\t\tif (rec && !store)", "\t\t\tlate_q <= store;\n\t\t\tif (late_q) rec_tot_q <= tot_n;\n\t\t\tif (rec && !store)")],
  ["+rosc_turns=20"], "the totals are not those of one clock after the bits"),
 ("overwrites_a_valid_record", "meter", METER, [("store   = rec && (!valid_q || take);", "store   = rec;"),
                                                 ("if (rec && !store)", "if (rec && valid_q && !take)")],
  [], "DATA0 and DATA1 read in different cycles with a record falling due in between are the two halves of one record"),
 ("overwrites_a_valid_record_silently", "meter", METER, [("store   = rec && (!valid_q || take);", "store   = rec;")],
  [], "a record that falls due while one is held is dropped: loss is set in the next cycle"),
 ("loss_not_sticky", "meter", METER, [("\t\t\tif (rec && !store)\t\t\t\t\t//\tone is held: this one is dropped\n\t\t\t\tloss_q <= 1'b1;\n", "\t\t\tloss_q <= rec && !store;\n")],
  [], "loss stays set after the held record is taken"),
 ("no_loss_for_a_dropped_record", "meter", METER, [("\t\t\tif (rec && !store)\t\t\t\t\t//\tone is held: this one is dropped\n\t\t\t\tloss_q <= 1'b1;\n", "")],
  [], "a record that falls due while one is held is dropped: loss is set in the next cycle"),
 ("take_drops_the_record_of_its_cycle", "meter", METER, [("store   = rec && (!valid_q || take);", "store   = rec && !valid_q;"),
                                                          ("if (rec && !store)", "if (rec && !store && !take)")],
  [], "a record that falls due in the cycle of the DATA1 read that takes the held one is stored"),
 ("take_loses_the_record_of_its_cycle", "meter", METER, [("store   = rec && (!valid_q || take);", "store   = rec && !valid_q;")],
  [], "a record that falls due in the cycle of the DATA1 read that takes the held one is stored"),
 ("data0_read_takes", "meter", METER, [("reg_re_i && reg_raddr_i == R_DATA1;", "reg_re_i && reg_raddr_i != R_CTRL;")],
  [], "a taken read of DATA0 and a look at DATA1 without a read take nothing"),
 ("look_at_data1_takes", "meter", METER, [("valid_q && reg_re_i && reg_raddr_i == R_DATA1;", "valid_q && reg_raddr_i == R_DATA1;")],
  [], "a taken read of DATA0 and a look at DATA1 without a read take nothing"),
 ("data1_read_does_not_take", "meter", METER, [("\t\t\tif (take)\n\t\t\t\tvalid_q <= 1'b0;\n", "")],
  [], "a DATA1 read takes the record: valid is clear"),
 ("record_cleared_by_the_take", "meter", METER, [("\t\t\tif (take)\n\t\t\t\tvalid_q <= 1'b0;\n", "\t\t\tif (take) begin\n\t\t\t\tvalid_q <= 1'b0; rec_tot_q <= {(TW*RINGS){1'b0}};\n\t\t\tend\n")],
  [], "the contents of a taken record stay until the next one"),
 ("sequence_number_stuck", "meter", METER, [("seq_q <= seq_q + 2'd1;", "seq_q <= seq_q;")],
  [], "the second record in test mode: the record's sequence number"),
 ("sequence_number_counts_stored_records_only", "meter", METER, [("\t\t\tif (rec)\n\t\t\t\tseq_q <= seq_q + 2'd1;", "\t\t\tif (store)\n\t\t\t\tseq_q <= seq_q + 2'd1;")],
  [], "the sequence number counts dropped records too: the next stored record shows the gap"),
 ("sequence_number_not_stored_with_the_record", "meter", METER, [("{valid_q, loss_q, rec_seq_q, tot_pad[59:0]}", "{valid_q, loss_q, seq_q, tot_pad[59:0]}")],
  [], "the record's sequence number"),
 ("record_at_every_strobe", "meter", METER, [("rec     = strobe && (div_q >= every_q);", "rec     = strobe;")],
  [], "a record at every n-th strobe: with every = 3 the third strobe after the record before"),
 ("divider_one_long", "meter", METER, [("rec     = strobe && (div_q >= every_q);", "rec     = strobe && (div_q > every_q);")],
  [], "on becoming active a record is taken at every strobe: the first strobe is recorded"),
 ("lane_bits_of_the_strobe_before", "meter", METER, [("localparam integer TW = 20;", "localparam integer TW = 20;\n\treg [LANES-1:0] b_q;\n\talways @(posedge clk) if (rng_val_i) b_q <= rng_b_i;"),
                                                      ("rec_tot_q <= tot_n; rec_b_q <= rng_b_i;", "rec_tot_q <= tot_n; rec_b_q <= b_q;")],
  [], "the record's lane bits are the symbol of its strobe"),
 # ---- the start bit ----
 ("start_keeps_the_record", "meter", METER, [(START, "div_q <= 16'd0; seq_q <= 2'd0; loss_q <= 1'b0; bad_q <= 16'd0;")],
  [], "start: valid, loss, the sequence number and the held record are cleared"),
 ("start_keeps_loss", "meter", METER, [(START, "div_q <= 16'd0; seq_q <= 2'd0; valid_q <= 1'b0; bad_q <= 16'd0;")],
  [], "start: valid, loss, the sequence number and the held record are cleared"),
 ("start_keeps_the_sequence_number", "meter", METER, [(START, "div_q <= 16'd0; valid_q <= 1'b0; loss_q <= 1'b0; bad_q <= 16'd0;")],
  [], "the first record after a start is held with sequence number 0, and nothing is lost yet"),
 ("start_does_not_restart_the_divider", "meter", METER, [(START, "seq_q <= 2'd0; valid_q <= 1'b0; loss_q <= 1'b0; bad_q <= 16'd0;")],
  [], "the start restarts the divider: the next record is the fifth strobe after it"),
 # ---- what test mode confines ----
 ("registers_readable_outside_test_mode", "meter", METER, [("assign reg_rdata_o = !active                ? 64'b0 :", "assign reg_rdata_o = lock_i                 ? 64'b0 :")],
  [], "outside test mode CTRL reads zero"),
 ("test_mode_ignored", "meter", METER, [("wire active = test_i && !lock_i;", "wire active = !lock_i;")],
  [], "outside test mode CTRL reads zero"),
 ("lock_ignored", "meter", METER, [("wire active = test_i && !lock_i;", "wire active = test_i;")],
  [], "locked in test mode: the rings and the burst symbol are those of normal operation"),
 ("state_kept_outside_test_mode", "meter", METER, [("\t\tif (rst || !active) begin\n", "\t\tif (rst) begin\n")],
  [], "outside test mode: the totals and the record stay at their reset values"),
 ("mask_applied_outside_test_mode", "meter", METER, [("assign ring_en_o = active ? mask_q : op_mask_i;", "assign ring_en_o = mask_q;")],
  [], "outside test mode: in every clock ring_en_o is op_mask_i, burst_sym_o is rng_b_i, the registers read zero"),
 ("burst_symbol_outside_test_mode", "meter", METER, [("assign burst_sym_o = !active ? sym_pad[3:0] : src_q", "assign burst_sym_o = src_q")],
  [], "leaving test mode: the burst symbol is rng_b_i and the registers read zero in the same cycle"),
 ("direct_counting_outside_test_mode", "meter", METER, [("assign cnt_direct_o = active && dir_q;", "assign cnt_direct_o = dir_q;")],
  [], "leaving test mode: cnt_direct_o is 0 in the same cycle"),
 ("reference_source_kept_outside_test_mode", "meter", METER, [("\t\t\tref_q <= 1'b0;\n", "")],
  [], "back in test mode: the configuration is at its reset values, no record, no loss"),
 # ---- the ring mask, the counting mode and respace ----
 ("mask_never_applied", "meter", METER, [("assign ring_en_o = active ? mask_q : op_mask_i;", "assign ring_en_o = op_mask_i;")],
  [], "in test mode ring_en_o is the written mask"),
 ("no_respace_on_a_mask_write", "meter", METER, [(RESPACE, "assign respace_o = redir || (!active && (mask_q != op_mask_i || dir_q));")],
  [], "a write that changes the ring mask pulses respace_o once"),
 ("respace_on_every_control_write", "meter", METER, [(RESPACE, "assign respace_o = ctrl_we || (!active && (mask_q != op_mask_i || dir_q));")],
  [], "a write of the same mask does not pulse respace_o, and its start clears loss"),
 ("no_respace_on_leaving", "meter", METER, [(RESPACE, "assign respace_o = remask || redir;")],
  [], "leaving test mode with a mask that is not op_mask_i pulses respace_o once"),
 ("no_respace_on_leaving_direct_counting", "meter", METER, [(RESPACE, "assign respace_o = remask || redir || (!active && mask_q != op_mask_i);")],
  [], "leaving test mode in direct mode pulses respace_o once"),
 ("no_respace_on_a_mode_write", "meter", METER, [(RESPACE, "assign respace_o = remask || (!active && (mask_q != op_mask_i || dir_q));")],
  [], "a write that changes the counting mode pulses respace_o once"),
 ("mask_write_does_not_set_loss", "meter", METER, [("\t\t\tif (remask || redir)", "\t\t\tif (redir)")],
  [], "a write that changes the ring mask sets loss, also with the start bit"),
 ("mode_write_does_not_set_loss", "meter", METER, [("\t\t\tif (remask || redir)", "\t\t\tif (remask)")],
  [], "a write that changes the counting mode sets loss"),
 ("counting_mode_not_read_back", "meter", METER, [(CTRL, "opm_pad[5:0], 3'b0, 1'b0, hi_q, ref_q, sel_q, src_q,")],
  [], "CTRL reads the counting mode back"),
 ("counting_mode_never_applied", "meter", METER, [("assign cnt_direct_o = active && dir_q;", "assign cnt_direct_o = 1'b0;")],
  [], "CTRL[28] set: cnt_direct_o is 1"),
 # ---- the burst capture's symbol ----
 ("burst_mux_one_clock_late", "meter", METER, [("assign burst_sym_o = !active ? sym_pad[3:0] : src_q ? cnt_sel :",
                                                "reg [3:0] cnt_sel_q;\n\talways @(posedge clk) cnt_sel_q <= cnt_sel;\n\tassign burst_sym_o = !active ? sym_pad[3:0] : src_q ? cnt_sel_q :")],
  ["+rosc_turns=20"], "source 1, ring 0: burst_sym_o is the low four bits of that ring's count of the edge at which the symbol of the cycle was sampled"),
 ("burst_mux_wrong_bits", "meter", METER, [("cnt_sel = hi_q ? cnt_ring[5:2] : cnt_ring[3:0];", "cnt_sel = hi_q ? cnt_ring[5:2] : cnt_ring[4:1];")],
  ["+rosc_turns=20"], "source 1, ring 0: burst_sym_o is the low four bits"),
 ("burst_mux_wrong_ring", "meter", METER, [("cnt_ring = cnt_pad[6*sel_q +: 6];", "cnt_ring = cnt_pad[6*(sel_q ^ 3'd1) +: 6];")],
  ["+rosc_turns=20"], "source 1, ring 0: burst_sym_o is the low four bits"),
 ("burst_source_bit_ignored", "meter", METER, [(BURST, "ref_q ? sym_ref : sym_pad[3:0];")],
  ["+rosc_turns=20"], "source 1, ring 0: burst_sym_o is the low four bits"),
 ("burst_upper_bits_ignored", "meter", METER, [("cnt_sel = hi_q ? cnt_ring[5:2] : cnt_ring[3:0];", "cnt_sel = cnt_ring[3:0];")],
  ["+rosc_turns=20"], "source 1 with CTRL[27], ring 0: burst_sym_o is the upper four bits of the count"),
 ("burst_upper_bits_one_too_low", "meter", METER, [("cnt_sel = hi_q ? cnt_ring[5:2] : cnt_ring[3:0];", "cnt_sel = hi_q ? cnt_ring[4:1] : cnt_ring[3:0];")],
  ["+rosc_turns=20"], "source 1 with CTRL[27], ring 0: burst_sym_o is the upper four bits of the count"),
 ("burst_upper_bits_not_read_back", "meter", METER, [(CTRL, "opm_pad[5:0], 3'b0, dir_q, 1'b0, ref_q, sel_q, src_q,")],
  [], "CTRL reads [27] back"),
 ("burst_reference_source_ignored", "meter", METER, [(BURST, "src_q ? cnt_sel : sym_pad[3:0];")],
  [], "reference source: burst_sym_o is the two reference bits above the bits of lanes 0 and 1"),
 ("burst_reference_bits_below_the_lanes", "meter", METER, [("sym_ref = {ref_pad[1:0], sym_pad[1:0]};", "sym_ref = {sym_pad[1:0], ref_pad[1:0]};")],
  [], "reference source: burst_sym_o is the two reference bits above the bits of lanes 0 and 1"),
 ("burst_reference_bits_swapped", "meter", METER, [("sym_ref = {ref_pad[1:0], sym_pad[1:0]};", "sym_ref = {ref_pad[0], ref_pad[1], sym_pad[1:0]};")],
  [], "reference source: burst_sym_o is the two reference bits above the bits of lanes 0 and 1"),
 ("burst_reference_with_lanes_2_and_3", "meter", METER, [("sym_ref = {ref_pad[1:0], sym_pad[1:0]};", "sym_ref = {ref_pad[1:0], sym_pad[3:2]};")],
  [], "reference source: burst_sym_o is the two reference bits above the bits of lanes 0 and 1"),
 ("burst_reference_bits_one_clock_late", "meter", METER, [("\twire [3:0]\tsym_ref = {ref_pad[1:0], sym_pad[1:0]};",
                                                           "\treg [1:0] ref_late_q;\n\talways @(posedge clk) ref_late_q <= ref_pad[1:0];\n\twire [3:0]\tsym_ref = {ref_late_q, sym_pad[1:0]};")],
  [], "reference source: burst_sym_o is the two reference bits above the bits of lanes 0 and 1"),
 ("burst_reference_bits_win_over_the_count", "meter", METER, [(BURST, "ref_q ? sym_ref : src_q ? cnt_sel : sym_pad[3:0];")],
  ["+rosc_turns=20"], "count and reference source both set: the count wins"),
 ("reference_source_not_read_back", "meter", METER, [(CTRL, "opm_pad[5:0], 3'b0, dir_q, hi_q, 1'b0, sel_q, src_q,")],
  [], "CTRL reads the reference source back"),
 # ---- counts that are not readable or not consistent ----
 ("flagged_clocks_of_rings_outside_the_mask", "meter", METER, [(ODD, "assign odd[r] = cnt_bad_i[r] || (mask_q[r] && ripe && far);")],
  [], "a ring that is not in the mask is not counted"),
 ("inconsistent_counts_of_rings_outside_the_mask", "meter", METER, [(ODD, "assign odd[r] = (mask_q[r] && cnt_bad_i[r]) || (ripe && far);"),
                                                                    ("if (!mask_q[k] || cnt_bad_i[k] || warm_q[4*k +: 4] != 4'd0)", "if (cnt_bad_i[k] || warm_q[4*k +: 4] != 4'd0)")],
  ["+rosc_turns=20"], RULE),
 ("flagged_clocks_counted_per_ring", "meter", METER, [("\t\t\tif (bad && bad_q != 16'hffff)\n\t\t\t\tbad_q <= bad_q + 16'd1;",
                                                       "\t\t\tif (bad && bad_q != 16'hffff)\n\t\t\t\tbad_q <= bad_q + {15'd0, odd[0]} + {15'd0, odd[3]} + {15'd0, |odd[2:1]} + {15'd0, |odd[5:4]};")],
  [], "clocks are counted, not rings"),
 ("flagged_clock_count_wraps", "meter", METER, [("if (bad && bad_q != 16'hffff)", "if (bad)")],
  [], "the count of bad clocks stops at 65535"),
 ("start_keeps_the_count_of_flagged_clocks", "meter", METER, [(START, "div_q <= 16'd0; seq_q <= 2'd0; valid_q <= 1'b0; loss_q <= 1'b0;")],
  [], "start clears the count of bad clocks and the flags of the rings"),
 ("start_keeps_the_flags_of_the_rings", "meter", METER, [("\t\t\t\tflag_q <= {RINGS{1'b0}}; run_q <= {(2*RINGS){1'b0}};", "\t\t\t\trun_q <= {(2*RINGS){1'b0}};")],
  [], "start clears the count of bad clocks and the flags of the rings"),
 ("flag_of_a_ring_not_sticky", "meter", METER, [("flag_q  <= flag_q | odd;", "flag_q  <= odd;")],
  [], "and its bit of CTRL[47:42] is set"),
 ("consistency_not_checked", "meter", METER, [(ODD, "assign odd[r] = mask_q[r] && cnt_bad_i[r];")],
  ["+rosc_turns=20"], "a count wrong by sixteen is flagged in the clock it is read, on its ring only"),
 ("consistency_threshold_1", "meter", METER, [("far  = (dd > 6'd2) && (dd < 6'd62);", "far  = (dd > 6'd1) && (dd < 6'd63);")],
  ["+rosc_turns=20"], RULE),
 ("consistency_threshold_3", "meter", METER, [("far  = (dd > 6'd2) && (dd < 6'd62);", "far  = (dd > 6'd3) && (dd < 6'd61);")],
  ["+rosc_turns=20"], RULE),
 ("consistency_after_two_samples", "meter", METER, [("ripe = (run_q[2*r +: 2] == 2'd2) && (warm_q[4*r +: 4] == 4'd0);", "ripe = (run_q[2*r +: 2] != 2'd0) && (warm_q[4*r +: 4] == 4'd0);")],
  ["+rosc_turns=20"], "a count that was not readable: that clock is counted, the increments on either side of it are not compared"),
 ("no_wait_after_a_restart", "meter", METER, [("ripe = (run_q[2*r +: 2] == 2'd2) && (warm_q[4*r +: 4] == 4'd0);", "ripe = (run_q[2*r +: 2] == 2'd2);"),
                                               ("if (!mask_q[k] || cnt_bad_i[k] || warm_q[4*k +: 4] != 4'd0)", "if (!mask_q[k] || cnt_bad_i[k])")],
  ["+rosc_turns=20"], RULE),
 ("wait_after_a_restart_too_short", "meter", METER, [("localparam [3:0] HOLD = 4'd12;", "localparam [3:0] HOLD = 4'd4;")],
  ["+rosc_turns=20"], RULE),
 ("no_wait_after_a_change_of_mode", "meter", METER, [("if ((mask_w[k] && !mask_q[k]) || redir)", "if (mask_w[k] && !mask_q[k])")],
  ["+rosc_turns=20"], "a change of the counting mode restarts every ring: nothing is flagged for it"),
 # ---- karu_rosc_rng.v, on the behavioural model: alignment and the ring enables ----
 ("model_count_one_stage_early", "meter", ROSC, [("gm_q <= now; gs_q <= gm_q; cnt_q <= gs_q;", "gm_q <= now; gs_q <= gm_q; cnt_q <= gm_q;")],
  ["+rosc_turns=20"], "in every clock cnt_o is the model's count of three clock edges before"),
 ("symbol_one_stage_early", "meter", ROSC, [("rng_b_o <= meta_q[STREAMS-1:0];", "rng_b_o <= samp_q[STREAMS-1:0];")],
  [], "every symbol is the bits of the model phase at the edge its counts are from"),
 ("reference_bit_one_stage_early", "meter", ROSC, [("ref_b_o <= meta_q[R-1:STREAMS];", "ref_b_o <= samp_q[R-1:STREAMS];")],
  [], "every reference bit is the bit of the model phase at the edge its counts are from"),
 ("reference_bits_swapped", "meter", ROSC, [("ref_b_o <= meta_q[R-1:STREAMS];", "ref_b_o <= {meta_q[STREAMS], meta_q[R-1:STREAMS+1]};")],
  [], "every reference bit is the bit of the model phase at the edge its counts are from"),
 ("reference_rings_not_sampled", "meter", ROSC, [("samp_q <= {ref_osc, osc};", "samp_q <= {{REFS{1'b0}}, osc};")],
  [], "every reference bit is the bit of the model phase at the edge its counts are from"),
 ("ring_enables_ignored", "meter", ROSC, [(RUN, "wire [R-1:0] run = {R{rng_en_i && !rst && !dir_chg}};")],
  [], "a reference ring that is off: its total stands still"),
 ("counting_mode_ignored_by_the_source", "meter", ROSC, [("wire dir_chg = (cnt_direct_i != dir_q);", "wire dir_chg = 1'b0;")],
  [], "the noise source has taken the mode"),
 # ---- karu_rosc_cnt: the divider, with the routes to its tables ----
 ("latch_polarities_swapped", "div", ROSC, [("LUT3 #(.INIT(8'h8D)) div_m", "LUT3 #(.INIT(8'h4E)) div_m"), ("LUT3 #(.INIT(8'hE4)) div_s", "LUT3 #(.INIT(8'hD8)) div_s")],
  [], DIV_M),
 ("master_takes_s_not_its_complement", "div", ROSC, [("LUT3 #(.INIT(8'h8D)) div_m", "LUT3 #(.INIT(8'hD8)) div_m")],
  [], DIV_M),
 ("slave_transparent_in_the_wrong_half", "div", ROSC, [("LUT3 #(.INIT(8'hE4)) div_s", "LUT3 #(.INIT(8'hD8)) div_s")],
  [], "div_s, with I2 = M, I1 = S, I0 = C, is S = C ? M : S"),
 ("selector_inputs_swapped", "div", ROSC, [("LUT3 #(.INIT(8'hAC)) div_x", "LUT3 #(.INIT(8'hCA)) div_x")],
  [], "div_x, with I2 = direct, I1 = S, I0 = C, is jclk = direct ? C : S"),
 ("master_wired_to_the_wrong_pins", "div", ROSC, [("div_m (.O(div_mq), .I0(ring_i), .I1(div_mq), .I2(div_sq));", "div_m (.O(div_mq), .I0(ring_i), .I1(div_sq), .I2(div_mq));")],
  [], "S toggles once at every rising edge of the ring, from either starting state"),
 ("slave_wired_to_the_wrong_pins", "div", ROSC, [("div_s (.O(div_sq), .I0(ring_i), .I1(div_sq), .I2(div_mq));", "div_s (.O(div_sq), .I0(ring_i), .I1(div_mq), .I2(div_sq));")],
  [], "S toggles once at every rising edge of the ring, from either starting state"),
 ("selector_on_the_master", "div", ROSC, [(".I0(ring_i), .I1(div_sq), .I2(direct_i));", ".I0(ring_i), .I1(div_mq), .I2(direct_i));")],
  [], "jclk is S: one period for two of the ring"),
 ("selector_ignores_direct", "div", ROSC, [(".I0(ring_i), .I1(div_sq), .I2(direct_i));", ".I0(ring_i), .I1(div_sq), .I2(1'b0));")],
  [], "with direct_i, jclk is the ring"),
 # ---- karu_rosc_cnt: the decoder ----
 ("decode_rule_before_the_review", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd7) ? b : (f <= 4'd11) ? a - 2'd1 : b - 2'd1;")],
  [], REVIEW),
 ("window_of_b_one_state_longer", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd4) ? b : (f <= 4'd11) ? a - 2'd1 : b - 2'd1;")],
  [], B_EARLY),
 ("window_of_a_one_state_earlier", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd2) ? b : (f <= 4'd11) ? a - 2'd1 : b - 2'd1;")],
  [], A_LATE),
 ("window_of_a_one_state_longer", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd3) ? b : (f <= 4'd12) ? a - 2'd1 : b - 2'd1;")],
  [], A_EARLY),
 ("window_of_b_one_state_earlier", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd3) ? b : (f <= 4'd10) ? a - 2'd1 : b - 2'd1;")],
  [], B_LATE),
 ("coarse_a_everywhere", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f == 4'd0) ? a : a - 2'd1;")],
  [], REVIEW_A),
 ("coarse_b_everywhere", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd7) ? b : b - 2'd1;")],
  [], REVIEW),
 ("a_minus_1_missing", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd3) ? b : (f <= 4'd11) ? a : b - 2'd1;")],
  [], REST),
 ("b_minus_1_missing", "cnt", ROSC, [(DECODE, "wire [1:0] n = (f <= 4'd3) ? b : (f <= 4'd11) ? a - 2'd1 : b;")],
  [], REST),
 ("johnson_decode_off_by_one", "cnt", ROSC, [("wire [3:0] f = j[0] ? ones : j[7] ? 4'd0 - ones : 4'd0;", "wire [3:0] f = j[0] ? ones : j[7] ? 4'd15 - ones : 4'd0;")],
  [], REST),
 ("coarse_b_on_the_wrong_johnson_bit", "cnt", ROSC, [("always @(posedge j_q[7] or posedge clr_b)", "always @(posedge j_q[3] or posedge clr_b)")],
  [], B_EARLY),
 ("coarse_a_on_the_wrong_johnson_bit", "cnt", ROSC, [("always @(posedge j_q[0] or posedge clr_a)", "always @(posedge j_q[7] or posedge clr_a)")],
  [], REST),
 # ---- the source as synthesised: alignment, switching, the counting mode, a counter outside its codes ----
 ("reference_bit_one_stage_early_on_the_rings", "cnt", ROSC, [("ref_b_o <= meta_q[R-1:STREAMS];", "ref_b_o <= samp_q[R-1:STREAMS];")],
  [], "a reference bit is the level of its ring at the clock edge of the count"),
 ("lane_bit_one_stage_early_on_the_rings", "cnt", ROSC, [("rng_b_o <= meta_q[STREAMS-1:0];", "rng_b_o <= samp_q[STREAMS-1:0];")],
  [], "a lane bit is the level of its ring at the clock edge of the count"),
 ("sampling_one_stage_short", "cnt", ROSC, [("\t\tgm_q <= ring_s;\n\t\tgs_q <= gm_q;", "\t\tgm_q <= ring_s;\n\t\tgs_q <= ring_s;")],
  [], "the counts are those of their own clock edge, three stages back, not of the edge before or after"),
 ("clear_released_with_the_enable", "cnt", ROSC, [("\t\ten_q  <= run & ~clr_q;", "\t\ten_q  <= run;")],
  [], "rings switched off and on, the clear late at parts of a counter: every run is counted from zero, never wrong by sixteen"),
 ("counter_not_cleared_when_off", "cnt", ROSC, [(".clr_i(clr_q[s])", ".clr_i(rst)")],
  [], "after every enable and every change of mode the count starts from zero"),
 ("ring_enables_ignored_in_the_rings", "cnt", ROSC, [(RUN, "wire [R-1:0] run = {R{rng_en_i && !rst && !dir_chg}};")],
  [], "the rings that ring_en_i has off do not run"),
 ("mode_changes_with_the_rings_running", "cnt", ROSC, [(RUN, "wire [R-1:0] run = {R{rng_en_i && !rst}} & ring_en_i;"),
                                                        ("if (dir_chg && (&clr_q) && !(|en_q))", "if (dir_chg)")],
  [], MODE),
 ("mode_changes_as_the_rings_are_switched_off", "cnt", ROSC, [("if (dir_chg && (&clr_q) && !(|en_q))", "if (dir_chg)")],
  [], MODE),
 ("mode_changes_a_clock_late", "cnt", ROSC, [("\treg  dir_q = 1'b0;\n", "\treg  dir_q = 1'b0;\n\treg  dir_w = 1'b0;\n"),
                                              ("\t\tif (dir_chg && (&clr_q) && !(|en_q))\n\t\t\tdir_q <= cnt_direct_i;", "\t\tdir_w <= dir_chg && (&clr_q) && !(|en_q);\n\t\tif (dir_chg && dir_w)\n\t\t\tdir_q <= cnt_direct_i;")],
  [], "a change of the counting mode: every gate is closed for three clocks, every counter in clear for two"),
 ("counters_see_the_mode_input_itself", "cnt", ROSC, [(".direct_i(dir_q)", ".direct_i(cnt_direct_i)")],
  [], MODE),
 ("counters_not_told_the_mode", "cnt", ROSC, [(".direct_i(dir_q)", ".direct_i(1'b0)")],
  [], "the count times its unit, two periods or one, is the number of ring periods"),
 ("bad_never_set", "cnt", ROSC, [("bad_o <= !code;", "bad_o <= 1'b0;")],
  [], "a Johnson state that is not one of the sixteen codes sets bad"),
 ("count_not_held_when_bad", "cnt", ROSC, [("\t\tif (code)\n\t\t\tcnt_o <= {n, f};", "\t\tcnt_o <= {n, f};")],
  [], "with bad set, the count repeats its previous value"),
 ("any_johnson_state_is_a_code", "cnt", ROSC, [("wire       code = (step & (step - 7'd1)) == 7'd0;", "wire       code = 1'b1;")],
  [], "a Johnson state that is not one of the sixteen codes sets bad"),
]

def run(m):
    name, bench, target, edits, plusargs, expect = m
    top, defines, bench_args, fail = BENCH[bench]
    text = RTL[target]
    for old, new in edits:
        if text.count(old) != 1:
            return name, "PATTERN", f"pattern found {text.count(old)} times in {PATH[target].name}: {old[:60]!r}"
        text = text.replace(old, new)
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / PATH[target].name).write_text(text)
    sources = [str(d / PATH[k].name) if k == target else str(PATH[k]) for k in ((ROSC, METER) if bench == "meter" else (ROSC,))]
    b = subprocess.run(["verilator", "--binary", "--timing", "-Wno-fatal", "-DKARU_NO_ASSERT", *defines, "--top-module", top,
                        "-Mdir", str(d / "obj"), "-o", "tb", str(TB), *sources], capture_output=True, text=True)
    if b.returncode:
        return name, "BUILD", (b.stdout[-300:] + b.stderr[-300:]).replace("\n", " ")
    try:
        r = subprocess.run([str(d / "obj" / "tb"), *bench_args, *plusargs], capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return name, "TIMEOUT", ""
    line = next((l for l in r.stdout.splitlines() if l.startswith(fail)), "")
    if r.returncode == 0 or not line:
        return name, "MISSED", (r.stdout.splitlines() or [""])[-1]
    return name, ("caught" if expect in line else "OTHER"), line

todo = [m for m in M if not args.only or args.only in m[0]]
with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    results = list(pool.map(run, todo))
wrong = 0
for (name, bench, *_), (_, verdict, line) in zip(todo, results):
    print(f"{verdict:7s} {bench:5s} {name:46s} {line[:230]}")
    wrong += verdict != "caught"
print(f"rosc meter mutants: {len(results) - wrong} of {len(results)} caught by the check written for them")
sys.exit(1 if wrong else 0)
