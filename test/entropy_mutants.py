#!/usr/bin/env python3
"""Mutant controls for rtl/karu_entropy.v (part of make entropy-test).

Each mutant changes one mechanism of the module. It is built without the
module's own assertions (KARU_NO_ASSERT), so test/tb_entropy.sv alone has to
notice, and it has to notice in the check that was written for the
mechanism: the table names it. A mutant that still passes is reported as
MISSED, one that fails in another check as OTHER; both fail the run.

    python3 test/entropy_mutants.py --out _build/entropy/mut [--only name,name]
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True)
parser.add_argument("--jobs", type=int, default=8)
parser.add_argument("--only", default=None, help="comma-separated mutant names")
args = parser.parse_args()
OUT = Path(args.out).resolve()
RTL = (ROOT / "rtl/karu_entropy.v").read_text()
TB = ROOT / "test/tb_entropy.sv"

BURST_RULE = "            if (burst_n == 3'd0 && fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST})\n                burst_q <= BURST;\n            else\n                burst_q <= burst_n;\n"
LAG_MATCH = "(seen_q > g[2:0] && b == hist[g])"
ALARM = "        else if (run_fail) alarm_q <= 1'b1;     //  a failure wins over an access in the same cycle\n        else if (seed_ack) alarm_q <= 1'b0;\n"
POP = "wire pop     = deliver && seed_ack && !alarm_q;"
SEED_OPST = "(state_q == S_DEAD)           ? OPST_DEAD :\n                            (test_q || hold || state_q == S_BIST || alarm_q) ? OPST_BIST :"
LANE = "wire b = rng_b_i[lane_i];"
WORD = "fifo[wr_q] <= {part_q, b};"
PART = "part_q  <= push ? 15'b0 : {part_q[13:0], b};"
PUSH = "wire push    = take && (bit_cnt == 4'd15);"
INT_USE = "wire [15:0] int_use = test_q ? int_q : (int_q < int_floor) ? int_floor : int_q;"
FLOOR = "wire [19:0] floor_k   = ({4'b0, INTERVAL_MIN} + 20'd1) << kshift_i;"
CFG_RDATA = "wire [63:0] cfg_rdata = {lock_q, 1'b0, calm_q, strike_q, 17'b0, apt_q, rct_q, int_q};"
CAUSE = "wire [3:0] cause = {apt_fail, |rct_fail, 2'b00};"
APT_N = "(b == win_ref) ? apt_cnt + 11'd1 : apt_cnt;"
WIN_REF = "            if (win_first) win_ref <= b;\n"
STAT_LOW = "1'b0, strike_cnt, 1'b0, alarm_q, state_q};"
STRAPS = "8'b0, kshift_i, lane_i, lags_q,"
RNG_EN = "assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);"
RAW_BREAK = "wire raw_break = hold || cfg_write || respace_i;"
# A test that the design does not have: the three lanes above lane 0 stuck for 63 symbols.
OTHER_LANES_TESTED = ("reg [3:0] sym_q; reg [5:0] run_q;\n"
    "    always @(posedge clk) if (rst || restart || hold) run_q <= 6'd0; else if (sym_v) begin sym_q <= rng_b_i;\n"
    "        run_q <= (rng_b_i[3:1] == sym_q[3:1] && run_q != 6'd63) ? run_q + 6'd1 : 6'd0; end\n"
    "    wire fail     = test_run && ((|cause) || run_q == 6'd63);")
# name, text in the RTL, replacement, which occurrence, and the check of
# test/tb_entropy.sv written for the mechanism: the mutant must fail there.
M = [
 # ---- the source: one lane ----
 ("lane_strap_ignored",     LANE, "wire b = rng_b_i[0];", 1, "four reads in consecutive cycles: word"),
 ("lane_strap_off_by_one",  LANE, "wire b = rng_b_i[lane_i + 2'd1];", 1, "four reads in consecutive cycles: word"),
 ("lane_strap_reversed",    LANE, "wire b = rng_b_i[~lane_i];", 1, "four reads in consecutive cycles: word"),
 ("lanes_combined",         LANE, "wire b = rng_b_i[lane_i] ^ rng_b_i[lane_i + 2'd1];", 1, "four reads in consecutive cycles: word"),
 ("another_lane_in_the_word", WORD, "fifo[wr_q] <= {part_q, rng_b_i[lane_i + 2'd1]};", 1, "four reads in consecutive cycles: word"),
 ("another_lane_in_the_part", PART, "part_q  <= push ? 15'b0 : {part_q[13:0], rng_b_i[lane_i + 2'd1]};", 1, "four reads in consecutive cycles: word"),
 ("another_lane_in_the_history", "hist <= {hist[2:0], b};", "hist <= {hist[2:0], rng_b_i[lane_i + 2'd1]};", 1, "a read in the cycle of a health failure gets no entropy"),
 ("another_lane_in_the_proportion", APT_N, "(rng_b_i[lane_i + 2'd1] == win_ref) ? apt_cnt + 11'd1 : apt_cnt;", 1, ("the others", ": no failure")),
 ("another_lane_as_window_reference", WIN_REF, "            if (win_first) win_ref <= rng_b_i[lane_i + 2'd1];\n", 1, "a frequent value that is not the window's first"),
 ("other_lanes_tested",     "wire fail     = test_run && (|cause);", OTHER_LANES_TESTED, 1, ("the others stuck", ": no failure")),
 ("symbol_cause_remains",   CAUSE, "wire [3:0] cause = {apt_fail, |rct_fail, 1'b0, rng_b_i == 4'b0};", 1, "each of the sixteen symbol values once"),
 # ---- packing and delivery ----
 ("word_of_15_samples",     PUSH, "wire push    = take && (bit_cnt == 4'd14);", 1, "the fourth word one sample short"),
 ("word_of_17_samples",     PUSH, "reg first_q;\n    always @(posedge clk) first_q <= (rst || clear || state_q != S_RUN) ? 1'b0 : (first_q | take);\n    wire push    = take && first_q && (bit_cnt == 4'd0);", 1, "the sixteenth sample completes the word"),
 ("word_boundary_slips",    "bit_cnt <= bit_cnt + 4'd1;      //  wraps at sixteen", "bit_cnt <= push ? 4'd1 : bit_cnt + 4'd1;", 1, "the fourth word one sample short"),
 ("bit_order_reversed",     WORD, "fifo[wr_q] <= {b, part_q[0], part_q[1], part_q[2], part_q[3], part_q[4], part_q[5], part_q[6], part_q[7], part_q[8], part_q[9], part_q[10], part_q[11], part_q[12], part_q[13], part_q[14]};", 1, "four reads in consecutive cycles: word"),
 ("last_sample_first",      WORD, "fifo[wr_q] <= {b, part_q};", 1, "four reads in consecutive cycles: word"),
 ("bits_combined",          WORD, "fifo[wr_q] <= {part_q, b} ^ {1'b0, part_q};", 1, "four reads in consecutive cycles: word"),
 ("part_kept_after_a_word", PART, "part_q  <= {part_q[13:0], b};", 1, "storage is wiped after the words were read"),
 ("deliver_on_fail",   "!test_q && !fail && !hold;", "!test_q && !hold;", 1, "a read in the cycle of a health failure gets no entropy"),
 ("no_burst_rule",     BURST_RULE, "            burst_q <= {2'b0, fill_n != 0};\n", 1, "three words held: no burst is opened"),
 ("drain_partial",     BURST_RULE, "            if (fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST}) burst_q <= BURST;\n            else burst_q <= {2'b0, (burst_q != 3'd0) && (fill_n != 0)};\n", 1, "one word left: no partial burst"),
 ("no_wipe_on_read",   "                fifo[rd_q] <= 16'b0;\n", "", 1, "the words are wiped as they are read"),
 ("no_wipe_on_restart", "            for (w = 0; w < FIFO_WORDS; w = w + 1) fifo[w] <= 16'b0;\n", "", 2, "a configuration write wipes the buffered words"),
 ("seed_custom_bits",  "wire [63:0] seed_rdata  = {32'b0, seed_opst, 14'b0, seed_data};", "wire [63:0] seed_rdata  = {32'b0, seed_opst, 6'b0, 8'h01, seed_data};", 1, "seed read value: OPST, entropy, all other bits zero"),
 ("seed_pop_without_write", "wire csr_wr   = csr_fire_i && csr_we_i;", "wire csr_wr   = csr_fire_i;", 1, "an access without a write takes nothing"),
 # ---- GetNoise ----
 ("getnoise_source_lane_only", "raw_q <= rng_b_i; raw_v <= 1'b1;", "raw_q <= {3'b0, b}; raw_v <= 1'b1;", 1, "GetNoise returns symbol"),
 ("sym_lost_on_pop",   "            if (sym_v) begin                    //", "            if (sym_v && !raw_pop) begin        //", 1, "the symbol that arrived in that cycle is kept, without loss"),
 ("loss_not_flagged",  "if (raw_v && !raw_pop) raw_lost <= 1'b1;", "if (1'b0) raw_lost <= 1'b1;", 1, "a symbol that was not taken is lost, and that is flagged"),
 ("false_loss_on_pop", "if (raw_v && !raw_pop) raw_lost <= 1'b1;", "if (raw_v) raw_lost <= 1'b1;", 1, "the symbol that arrived in that cycle is kept, without loss"),
 ("no_new_run",        "            if (raw_new) raw_lost <= 1'b0;\n", "", 1, "after it: nothing held, loss cleared"),
 ("run_continues_across_a_stopped_source", RAW_BREAK, "wire raw_break = cfg_write || respace_i;", 1, "the source was off for eight clocks"),
 ("run_continues_across_a_configuration_write", RAW_BREAK, "wire raw_break = hold || respace_i;", 1, "a configuration write in test mode sets the loss flag"),
 ("run_continues_across_a_change_of_spacing", RAW_BREAK, "wire raw_break = hold || cfg_write;", 1, "a change of the spacing sets the loss flag"),
 ("clearing_write_wins_over_a_break", "            if (raw_break) begin                //", "            if (raw_break && !raw_new) begin    //", 1, "a clearing write in the cycle the source stops does not hide the break"),
 ("break_keeps_the_held_symbol", "                raw_lost <= 1'b1; raw_v <= 1'b0; raw_q <= 4'b0;\n", "                raw_lost <= 1'b1;\n", 1, "source off with a symbol held: the symbol is dropped"),
 ("leaving_test_mode_keeps_the_symbol", "if (rst || !test_q || (noise_write && !test_next)) begin", "if (rst || (noise_write && !test_next)) begin", 1, "test mode entered: no symbol held from before, no loss"),
 ("pop_keeps_symbol",  "            if (raw_pop) begin raw_v <= 1'b0; raw_q <= 4'b0; end\n", "", 1, "has taken it"),
 ("tests_run_in_test_mode", "wire test_run = sym_v && !test_q && (state_q != S_DEAD);", "wire test_run = sym_v && (state_q != S_DEAD);", 1, "BIST throughout test mode"),
 # ---- configuration, limits, the spacing floor, lock ----
 ("apt_no_limit",      "lim_apt = (v > APT_MAX) ? APT_MAX : v;", "lim_apt = v;", 1, "values weaker than the build limits are replaced by the limits"),
 ("rct_no_limit",      "lim_rct = (v > RCT_MAX) ? RCT_MAX : v;", "lim_rct = v;", 1, "values weaker than the build limits are replaced by the limits"),
 ("strike_no_limit",   "lim_strike = (v > STRIKE_MAX) ? STRIKE_MAX : v;", "lim_strike = v;", 1, "values weaker than the build limits are replaced by the limits"),
 ("calm_no_limit",     "lim_calm = (v < CALM_MIN) ? CALM_MIN : v;", "lim_calm = v;", 1, "values weaker than the build limits are replaced by the limits"),
 ("reserved_field_writable", CFG_RDATA, "reg [16:0] rsv_q;\n    always @(posedge clk) if (rst) rsv_q <= 17'b0; else if (cfg_write) rsv_q <= csr_wdata_i[53:37];\n    wire [63:0] cfg_rdata = {lock_q, 1'b0, calm_q, strike_q, rsv_q, apt_q, rct_q, int_q};", 1, "read zero when ones are written"),
 ("reserved_bit_62_writable", CFG_RDATA, "reg rsv_q;\n    always @(posedge clk) if (rst) rsv_q <= 1'b0; else if (cfg_write) rsv_q <= csr_wdata_i[62];\n    wire [63:0] cfg_rdata = {lock_q, rsv_q, calm_q, strike_q, 17'b0, apt_q, rct_q, int_q};", 1, "read zero when ones are written"),
 ("interval_no_floor", INT_USE, "wire [15:0] int_use = int_q;", 1, "k = 1 written, the floor is used"),
 ("floor_in_test_mode", INT_USE, "wire [15:0] int_use = (int_q < int_floor) ? int_floor : int_q;", 1, "test mode with k = 1, every symbol is a sample"),
 ("floor_ignores_kshift", FLOOR, "wire [19:0] floor_k   = ({4'b0, INTERVAL_MIN} + 20'd1);", 1, "kshift 1: after reset the interval is the floor"),
 ("floor_scaled_not_shifted", FLOOR, "wire [19:0] floor_k   = ({4'b0, INTERVAL_MIN} + 20'd1) * ({18'b0, kshift_i} + 20'd1);", 1, "kshift 2: after reset the interval is the floor"),
 ("floor_wraps",       "wire [15:0] int_floor = (floor_km1[19:16] != 4'd0) ? 16'hffff : floor_km1[15:0];", "wire [15:0] int_floor = floor_km1[15:0];", 1, "a floor that the field cannot hold is the largest interval"),
 ("reset_interval_ignores_the_floor", "int_q    <= int_reset;", "int_q    <= INTERVAL_RESET;", 1, "kshift 0: after reset the interval is the floor"),
 ("reset_interval_is_the_floor", "wire [15:0] int_reset = (INTERVAL_RESET < int_floor) ? int_floor : INTERVAL_RESET;", "wire [15:0] int_reset = int_floor;", 1, "a reset value above the floor"),
 ("lock_ignored_cfg",  "wire cfg_write   = cfg_we && !lock_q;", "wire cfg_write   = cfg_we;", 1, "locked: configuration writes are ignored"),
 ("lock_ignored_noise", "wire noise_write = noise_we && !lock_q;", "wire noise_write = noise_we;", 1, "locked: test mode cannot be entered"),
 ("stat_write_is_cfg_write", "wire cfg_we   = csr_wr && csr_sel_i == SEL_CFG;", "wire cfg_we   = csr_wr && csr_sel_i[1];", 1, "a write to mentropystat changes nothing"),
 ("no_decimation",     "wire sym_v  = sym_in && (int_cnt == int_use);", "wire sym_v  = sym_in;", 1, "k = 3: 3071 source symbols are 1023 samples"),
 ("cfg_write_no_restart", "wire restart = cfg_write || (noise_write && (test_next != test_q));", "wire restart = (noise_write && (test_next != test_q));", 1, "a configuration write restarts the start-up test"),
 ("startup_one_short", "localparam [10:0] STARTUP = 11'd1024;", "localparam [10:0] STARTUP = 11'd1023;", 1, "1023 samples into the start-up test"),
 # ---- the two tests ----
 ("rct_off_by_one",    "rct_fail[g] = (rct_n[g] >= rct_q);", "rct_fail[g] = (rct_n[g] > rct_q);", 1, "a read in the cycle of a health failure gets no entropy"),
 ("apt_off_by_one",    "wire        apt_fail  = (apt_n >= apt_q);", "wire        apt_fail  = (apt_n > apt_q);", 1, "the 700th one of the window"),
 ("rct_not_a_failure", CAUSE, "wire [3:0] cause = {apt_fail, 1'b0, 2'b00};", 1, "a read in the cycle of a health failure gets no entropy"),
 ("apt_not_a_failure", CAUSE, "wire [3:0] cause = {1'b0, |rct_fail, 2'b00};", 1, "the 700th one of the window"),
 ("cause_bits_swapped", CAUSE, "wire [3:0] cause = {|rct_fail, apt_fail, 2'b00};", 1, "the source stuck: cause 1000"),
 ("apt_window_512",    "wire        win_first = (win_idx == 10'd0);", "wire        win_first = (win_idx[8:0] == 9'd0);", 1, "the 700th one of the window"),
 ("apt_counts_repeats", WIN_REF, "            win_ref <= b;\n", 1, "the 700th one of the window"),
 ("apt_reference_of_the_first_window", WIN_REF, "            if (win_first && seen_q == 3'd0) win_ref <= b;\n", 1, "a frequent value that is not the window's first"),
 ("apt_counts_ones",   APT_N, "b ? apt_cnt + 11'd1 : apt_cnt;", 1, "a frequent value that is not the window's first"),
 ("lag_1_only",        LAG_MATCH, "(g == 0 && seen_q > g[2:0] && b == hist[g])", 1, "period 2: cause"),
 ("lag_history_wrong", LAG_MATCH, "(seen_q > g[2:0] && b == hist[0])", 1, "the source stuck: cause 0100 lanes 0100 lags 1111"),
 ("lag_counts_before_restart", LAG_MATCH, "(b == hist[g])", 1, "and the failure on the next one"),
 ("history_shift_broken", "hist <= {hist[2:0], b};", "hist <= {hist[1], hist[1:0], b};", 1, "period 3: cause"),
 ("counts_survive_a_failure", "wire clear    = restart || fail || hold;", "wire clear    = restart || hold;", 1, "counted from one again, no second failure"),
 # ---- failures: start-up, strikes, dead ----
 ("bist_failure_not_fatal", "wire fatal    = fail && ((state_q == S_BIST) || (", "wire fatal    = fail && ((", 1, "a failure during the retest is fatal"),
 ("fatal_strike_not_counted", "if (run_fail) strike_cnt <= strike_cnt + 3'd1;", "if (run_fail && !fatal) strike_cnt <= strike_cnt + 3'd1;", 1, "the third strike is fatal, and counted"),
 ("strikes_never_fatal", " || ({1'b0, strike_cnt} + 4'd1 >= {1'b0, strike_q}));", ");", 1, "the third strike is fatal, and counted"),
 ("strikes_off_by_one", "({1'b0, strike_cnt} + 4'd1 >= {1'b0, strike_q})", "({1'b0, strike_cnt} + 4'd1 > {1'b0, strike_q})", 1, "the third strike is fatal, and counted"),
 ("strikes_not_forgiven", "if (calm_n[calm_q]) begin strike_cnt <= 3'd0; calm_cnt <= 32'd0; end", "if (1'b0) begin strike_cnt <= 3'd0; calm_cnt <= 32'd0; end", 1, "forgiven after"),
 ("forgiven_early",    "if (calm_n[calm_q]) begin", "if (calm_n[calm_q - 5'd1]) begin", 1, "second failure: two strikes"),
 ("clean_count_survives_a_failure", "        end else if (fail) begin\n            calm_cnt <= 32'd0;\n", "        end else if (fail) begin\n", 1, "the third strike is fatal, and counted"),
 ("restart_clears_strikes", "        end else if (restart) begin\n            calm_cnt <= 32'd0;\n", "        end else if (restart) begin\n            calm_cnt <= 32'd0; strike_cnt <= 3'd0;\n", 1, "a configuration write keeps the strikes and the alarm"),
 ("clean_count_survives_a_restart", "        end else if (restart) begin\n            calm_cnt <= 32'd0;\n", "        end else if (restart) begin\n", 1, "after the write: not forgiven"),
 ("fatal_loses_to_restart", "end else if (state_q == S_DEAD || fatal) begin", "end else if (state_q == S_DEAD || (fatal && !restart)) begin", 1, "the fatal failure wins over a restart in its cycle"),
 ("dead_revived",      "end else if (state_q == S_DEAD || fatal) begin\n            state_q <= S_DEAD;", "end else if (state_q == S_DEAD || fatal) begin\n            state_q <= (restart && !fatal) ? S_BIST : S_DEAD;", 1, "dead until reset: a configuration write does not revive it"),
 # ---- the alarm ----
 ("alarm_not_latched", "else if (run_fail) alarm_q <= 1'b1;", "else if (run_fail) alarm_q <= 1'b0;", 1, "status: start-up test again, alarm, one strike, one failure"),
 ("alarm_clears_itself", "else if (seed_ack) alarm_q <= 1'b0;", "else               alarm_q <= 1'b0;", 1, "status: start-up test again, alarm, one strike, one failure"),
 ("alarm_never_cleared", "else if (seed_ack) alarm_q <= 1'b0;", "else if (1'b0)     alarm_q <= 1'b0;", 1, "and that access clears the alarm"),
 ("alarm_loses_to_access", ALARM, "        else if (seed_ack) alarm_q <= 1'b0;\n        else if (run_fail) alarm_q <= 1'b1;\n", 1, "status: start-up test again, alarm, one strike, one failure"),
 ("alarm_hides_dead",  SEED_OPST, "alarm_q                       ? OPST_BIST :\n                            (state_q == S_DEAD)           ? OPST_DEAD :\n                            (test_q || hold || state_q == S_BIST) ? OPST_BIST :", 1, "seed reports DEAD"),
 ("alarm_with_entropy_bits", "wire [15:0] seed_data = (seed_opst == OPST_ES16) ? fifo[rd_q] : 16'b0;", "wire [15:0] seed_data = deliver ? fifo[rd_q] : 16'b0;", 1, "the alarm is still reported as BIST"),
 ("alarm_cleared_by_restart", "        if (rst)           alarm_q <= 1'b0;", "        if (rst || restart) alarm_q <= 1'b0;", 1, "a configuration write keeps the strikes and the alarm"),
 ("alarm_not_reported", SEED_OPST, "(state_q == S_DEAD)           ? OPST_DEAD :\n                            (test_q || hold || state_q == S_BIST) ? OPST_BIST :", 1, "the alarm is still reported as BIST"),
 ("alarm_access_takes_a_word", POP, "wire pop     = deliver && seed_ack;", 1, "after it only samples from after the retest are delivered"),
 # ---- the status register ----
 ("stat_no_cause",     "cause_q <= cause;", "cause_q <= 4'b0;", 1, "the source stuck: cause 0000"),
 ("stat_lane_not_reported", "lanes_q <= 4'b0001 << lane_i;", "lanes_q <= 4'b0;", 1, "the source stuck: cause 0100 lanes 0000"),
 ("stat_lane_always_0", "lanes_q <= 4'b0001 << lane_i;", "lanes_q <= 4'b0001;", 1, "the source stuck: cause 0100 lanes 0001"),
 ("stat_no_lags",      "lags_q <= rct_fail;", "lags_q <= 4'b0;", 1, "the source stuck: cause 0100 lanes 0100 lags 0000"),
 ("stat_lags_reversed", "lags_q <= rct_fail;", "lags_q <= {rct_fail[0], rct_fail[1], rct_fail[2], rct_fail[3]};", 1, "the source stuck: cause 0100 lanes 0100 lags 1000"),
 ("stat_failures_not_counted", "            if (fails_q != 16'hffff) fails_q <= fails_q + 16'd1;\n", "", 1, "status: start-up test again, alarm, one strike, one failure"),
 ("stat_no_alarm",     STAT_LOW, "1'b0, strike_cnt, 1'b0, 1'b0, state_q};", 1, "status: start-up test again, alarm, one strike, one failure"),
 ("stat_no_strikes",   STAT_LOW, "1'b0, 3'd0, 1'b0, alarm_q, state_q};", 1, "status: start-up test again, alarm, one strike, one failure"),
 ("stat_no_state",     STAT_LOW, "1'b0, strike_cnt, 1'b0, alarm_q, 2'd1};", 1, "status after reset"),
 ("stat_no_lane_strap", STRAPS, "8'b0, kshift_i, 2'b0, lags_q,", 1, "status after reset"),
 ("stat_no_kshift_strap", STRAPS, "8'b0, 2'b0, lane_i, lags_q,", 1, "mentropystat shows the floor's shift and the lane"),
 ("stat_straps_swapped", STRAPS, "8'b0, lane_i, kshift_i, lags_q,", 1, "status after reset"),
 # ---- the strap and the dead source ----
 ("strap_ignored",     "wire hold    = !en_i;", "wire hold    = 1'b0;", 1, "the source was off for eight clocks"),
 ("strap_keeps_source_on", RNG_EN, "assign rng_en_o   = (state_q != S_DEAD || test_q);", 1, "strap low: the noise source is disabled"),
 ("dead_source_stays_off_in_test_mode", RNG_EN, "assign rng_en_o   = en_i && (state_q != S_DEAD);", 1, "test mode switches a dead source back on"),
 ("dead_source_left_on", RNG_EN, "assign rng_en_o   = en_i;", 1, "the source is disabled when dead"),
 ("strap_symbols_kept", "wire sym_in = rng_val_i && en_i;", "wire sym_in = rng_val_i;", 1, "strap low: a symbol is not tested"),
]

def mutate(name, old, new, which):
    n = RTL.count(old)
    if n < which:
        raise SystemExit(f"mutant {name}: pattern found {n} times, need occurrence {which}")
    if which == 1 and n != 1:
        raise SystemExit(f"mutant {name}: pattern found {n} times")
    at = -1
    for _ in range(which):
        at = RTL.index(old, at + 1)
    return RTL[:at] + new + RTL[at + len(old):]

def run(m):
    name, old, new, which, want = m
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "karu_entropy.v").write_text(mutate(name, old, new, which))
    b = subprocess.run(["verilator", "--binary", "--timing", "-Wno-fatal", "-DKARU_NO_ASSERT", "--top-module", "tb_entropy",
                        "-Mdir", str(d / "obj"), "-o", "tb", str(TB), str(d / "karu_entropy.v")],
                       capture_output=True, text=True)
    if b.returncode:
        return name, "BUILD", b.stdout[-300:] + b.stderr[-300:]
    r = subprocess.run([str(d / "obj" / "tb")], capture_output=True, text=True, timeout=900)
    line = next((l for l in r.stdout.splitlines() if l.startswith("FAIL entropy")), "")
    if r.returncode == 0 or not line:
        return name, "MISSED", line
    wants = (want,) if isinstance(want, str) else want
    return name, ("caught" if all(w in line for w in wants) else "OTHER"), line

if args.only:
    M = [m for m in M if m[0] in args.only.split(",")]
with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    results = list(pool.map(run, M))
missed = 0
for name, verdict, line in results:
    print(f"{verdict:7s} {name:36s} {line[:200]}")
    missed += verdict != "caught"
print(f"entropy mutants: {len(results) - missed} of {len(results)} caught, each by the check written for it")
sys.exit(1 if missed else 0)
