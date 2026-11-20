#!/usr/bin/env python3
"""Mutant controls for rtl/karu_entropy.v (part of make entropy-test).

Each mutant changes one mechanism of the module. It is built without the
module's own assertions (KARU_NO_ASSERT), so test/tb_entropy.sv alone has to
notice. A mutant that still passes is reported as MISSED and fails the run.

    python3 test/entropy_mutants.py --out _build/entropy/mut
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True)
parser.add_argument("--jobs", type=int, default=8)
args = parser.parse_args()
OUT = Path(args.out).resolve()
RTL = (ROOT / "rtl/karu_entropy.v").read_text()
TB = ROOT / "test/tb_entropy.sv"

BURST_RULE = "            if (burst_n == 3'd0 && fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST})\n                burst_q <= BURST;\n            else\n                burst_q <= burst_n;\n"
LAG_MATCH = "(seen_q > g[2:0] && rng_b_i[l] == hist[g][l])"
ALARM = "        else if (run_fail) alarm_q <= 1'b1;     //  a failure wins over an access in the same cycle\n        else if (seed_ack) alarm_q <= 1'b0;\n"
POP = "wire pop     = deliver && seed_ack && !alarm_q;"
SEED_OPST = "(state_q == S_DEAD)           ? OPST_DEAD :\n                            (test_q || hold || state_q == S_BIST || alarm_q) ? OPST_BIST :"
M = [
 # ---- delivery ----
 ("deliver_on_fail",   "!test_q && !fail && !hold;", "!test_q && !hold;", 1),
 ("no_burst_rule",     BURST_RULE, "            burst_q <= {2'b0, fill_n != 0};\n", 1),
 ("drain_partial",     BURST_RULE, "            if (fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST}) burst_q <= BURST;\n            else burst_q <= {2'b0, (burst_q != 3'd0) && (fill_n != 0)};\n", 1),
 ("no_wipe_on_read",   "                fifo[rd_q] <= 16'b0;\n", "", 1),
 ("no_wipe_on_restart", "            for (w = 0; w < FIFO_WORDS; w = w + 1) fifo[w] <= 16'b0;\n", "", 2),
 ("bits_combined",     "fifo[wr_q] <= {part_q, rng_b_i};", "fifo[wr_q] <= {part_q, rng_b_i} ^ {4'b0, part_q};", 1),
 ("word_order",        "fifo[wr_q] <= {part_q, rng_b_i};", "fifo[wr_q] <= {rng_b_i, part_q};", 1),
 ("seed_custom_bits",  "wire [63:0] seed_rdata  = {32'b0, seed_opst, 14'b0, seed_data};", "wire [63:0] seed_rdata  = {32'b0, seed_opst, 6'b0, 8'h01, seed_data};", 1),
 ("seed_pop_without_write", "wire csr_wr   = csr_fire_i && csr_we_i;", "wire csr_wr   = csr_fire_i;", 1),
 # ---- GetNoise ----
 ("sym_lost_on_pop",   "            if (sym_v) begin                    //", "            if (sym_v && !raw_pop) begin        //", 1),
 ("loss_not_flagged",  "if (raw_v && !raw_pop) raw_lost <= 1'b1;", "if (1'b0) raw_lost <= 1'b1;", 1),
 ("false_loss_on_pop", "if (raw_v && !raw_pop) raw_lost <= 1'b1;", "if (raw_v) raw_lost <= 1'b1;", 1),
 ("no_new_run",        "            if (raw_new) raw_lost <= 1'b0;\n", "", 1),
 ("run_continues_across_a_stopped_source", "wire raw_break = hold || cfg_write || respace_i;", "wire raw_break = cfg_write || respace_i;", 1),
 ("run_continues_across_a_configuration_write", "wire raw_break = hold || cfg_write || respace_i;", "wire raw_break = hold || respace_i;", 1),
 ("run_continues_across_a_change_of_spacing", "wire raw_break = hold || cfg_write || respace_i;", "wire raw_break = hold || cfg_write;", 1),
 ("clearing_write_wins_over_a_break", "            if (raw_break) begin                //", "            if (raw_break && !raw_new) begin    //", 1),
 ("break_keeps_the_held_symbol", "                raw_lost <= 1'b1; raw_v <= 1'b0; raw_q <= 4'b0;\n", "                raw_lost <= 1'b1;\n", 1),
 ("leaving_test_mode_keeps_the_symbol", "if (rst || !test_q || (noise_write && !test_next)) begin", "if (rst || (noise_write && !test_next)) begin", 1),
 ("pop_keeps_symbol",  "            if (raw_pop) begin raw_v <= 1'b0; raw_q <= 4'b0; end\n", "", 1),
 ("tests_run_in_test_mode", "wire test_run = sym_v && !test_q && (state_q != S_DEAD);", "wire test_run = sym_v && (state_q != S_DEAD);", 1),
 # ---- configuration, limits, lock ----
 ("apt_no_limit",      "lim_apt = (v > APT_MAX) ? APT_MAX : v;", "lim_apt = v;", 1),
 ("rct_no_limit",      "lim_rct = (v > RCT_MAX) ? RCT_MAX : v;", "lim_rct = v;", 1),
 ("srct_no_limit",     "lim_srct = (v > SRCT_MAX) ? SRCT_MAX : v;", "lim_srct = v;", 1),
 ("sapt_no_limit",     "lim_sapt = (v > SAPT_MAX) ? SAPT_MAX : v;", "lim_sapt = v;", 1),
 ("strike_no_limit",   "lim_strike = (v > STRIKE_MAX) ? STRIKE_MAX : v;", "lim_strike = v;", 1),
 ("calm_no_limit",     "lim_calm = (v < CALM_MIN) ? CALM_MIN : v;", "lim_calm = v;", 1),
 ("interval_no_floor", "lim_int = (v < INTERVAL_MIN) ? INTERVAL_MIN : v;", "lim_int = v;", 1),
 ("floor_in_test_mode", "wire [15:0] int_use = test_q ? int_q : lim_int(int_q);", "wire [15:0] int_use = lim_int(int_q);", 1),
 ("lock_ignored_cfg",  "wire cfg_write   = cfg_we && !lock_q;", "wire cfg_write   = cfg_we;", 1),
 ("lock_ignored_noise", "wire noise_write = noise_we && !lock_q;", "wire noise_write = noise_we;", 1),
 ("stat_write_is_cfg_write", "wire cfg_we   = csr_wr && csr_sel_i == SEL_CFG;", "wire cfg_we   = csr_wr && csr_sel_i[1];", 1),
 ("no_decimation",     "wire sym_v  = sym_in && (int_cnt == int_use);", "wire sym_v  = sym_in;", 1),
 ("cfg_write_no_restart", "wire restart = cfg_write || (noise_write && (test_next != test_q));", "wire restart = (noise_write && (test_next != test_q));", 1),
 ("startup_one_short", "localparam [10:0] STARTUP = 11'd1024;", "localparam [10:0] STARTUP = 11'd1023;", 1),
 # ---- the four tests ----
 ("srct_off_by_one",   "wire       srct_fail = (srct_n >= srct_q);", "wire       srct_fail = (srct_n > srct_q);", 1),
 ("sapt_off_by_one",   "wire       sapt_fail = (sapt_n >= sapt_q);", "wire       sapt_fail = (sapt_n > sapt_q);", 1),
 ("rct_off_by_one",    "rct_fail[4*l+g] = (rct_n[4*l+g] >= rct_q);", "rct_fail[4*l+g] = (rct_n[4*l+g] > rct_q);", 1),
 ("apt_off_by_one",    "apt_fail[l] = (apt_n[l] >= apt_q);", "apt_fail[l] = (apt_n[l] > apt_q);", 1),
 ("srct_not_a_failure", "wire [3:0] cause     = {|apt_fail, |rct_fail, sapt_fail, srct_fail};", "wire [3:0] cause     = {|apt_fail, |rct_fail, sapt_fail, 1'b0};", 1),
 ("sapt_not_a_failure", "wire [3:0] cause     = {|apt_fail, |rct_fail, sapt_fail, srct_fail};", "wire [3:0] cause     = {|apt_fail, |rct_fail, 1'b0, srct_fail};", 1),
 ("srct_per_lane",     "wire [6:0] srct_n = (seen_q != 3'd0 && rng_b_i == hist[0]) ?", "wire [6:0] srct_n = (seen_q != 3'd0 && rng_b_i[0] == hist[0][0]) ?", 1),
 ("sapt_window_1024",  "wire       swin_first = (win_idx[8:0] == 9'd0);", "wire       swin_first = (win_idx == 10'd0);", 1),
 ("sapt_counts_repeats", "            if (swin_first) sapt_ref <= rng_b_i;\n", "            sapt_ref <= rng_b_i;\n", 1),
 ("apt_window_512",    "wire       win_first  = (win_idx == 10'd0);", "wire       win_first  = (win_idx[8:0] == 9'd0);", 1),
 ("lag_1_only",        LAG_MATCH, "(g == 0 && seen_q > g[2:0] && rng_b_i[l] == hist[g][l])", 1),
 ("lag_history_wrong", LAG_MATCH, "(seen_q > g[2:0] && rng_b_i[l] == hist[0][l])", 1),
 ("lag_counts_before_restart", LAG_MATCH, "(rng_b_i[l] == hist[g][l])", 1),
 ("history_shift_broken", "hist[3] <= hist[2];", "hist[3] <= hist[1];", 1),
 ("counts_survive_a_failure", "wire clear    = restart || fail || hold;", "wire clear    = restart || hold;", 1),
 # ---- failures: start-up, strikes, dead ----
 ("bist_failure_not_fatal", "wire fatal    = fail && ((state_q == S_BIST) || (", "wire fatal    = fail && ((", 1),
 ("fatal_strike_not_counted", "if (run_fail) strike_cnt <= strike_cnt + 3'd1;", "if (run_fail && !fatal) strike_cnt <= strike_cnt + 3'd1;", 1),
 ("strikes_never_fatal", " || ({1'b0, strike_cnt} + 4'd1 >= {1'b0, strike_q}));", ");", 1),
 ("strikes_off_by_one", "({1'b0, strike_cnt} + 4'd1 >= {1'b0, strike_q})", "({1'b0, strike_cnt} + 4'd1 > {1'b0, strike_q})", 1),
 ("strikes_not_forgiven", "if (calm_n[calm_q]) begin strike_cnt <= 3'd0; calm_cnt <= 32'd0; end", "if (1'b0) begin strike_cnt <= 3'd0; calm_cnt <= 32'd0; end", 1),
 ("forgiven_early",    "if (calm_n[calm_q]) begin", "if (calm_n[calm_q - 5'd1]) begin", 1),
 ("clean_count_survives_a_failure", "        end else if (fail) begin\n            calm_cnt <= 32'd0;\n", "        end else if (fail) begin\n", 1),
 ("restart_clears_strikes", "        end else if (restart) begin\n            calm_cnt <= 32'd0;\n", "        end else if (restart) begin\n            calm_cnt <= 32'd0; strike_cnt <= 3'd0;\n", 1),
 ("clean_count_survives_a_restart", "        end else if (restart) begin\n            calm_cnt <= 32'd0;\n", "        end else if (restart) begin\n", 1),
 ("fatal_loses_to_restart", "end else if (state_q == S_DEAD || fatal) begin", "end else if (state_q == S_DEAD || (fatal && !restart)) begin", 1),
 ("dead_revived",      "end else if (state_q == S_DEAD || fatal) begin\n            state_q <= S_DEAD;", "end else if (state_q == S_DEAD || fatal) begin\n            state_q <= (restart && !fatal) ? S_BIST : S_DEAD;", 1),
 # ---- the alarm ----
 ("alarm_not_latched", "else if (run_fail) alarm_q <= 1'b1;", "else if (run_fail) alarm_q <= 1'b0;", 1),
 ("alarm_clears_itself", "else if (seed_ack) alarm_q <= 1'b0;", "else               alarm_q <= 1'b0;", 1),
 ("alarm_never_cleared", "else if (seed_ack) alarm_q <= 1'b0;", "else if (1'b0)     alarm_q <= 1'b0;", 1),
 ("alarm_loses_to_access", ALARM, "        else if (seed_ack) alarm_q <= 1'b0;\n        else if (run_fail) alarm_q <= 1'b1;\n", 1),
 ("alarm_hides_dead",  SEED_OPST, "alarm_q                       ? OPST_BIST :\n                            (state_q == S_DEAD)           ? OPST_DEAD :\n                            (test_q || hold || state_q == S_BIST) ? OPST_BIST :", 1),
 ("alarm_with_entropy_bits", "wire [15:0] seed_data = (seed_opst == OPST_ES16) ? fifo[rd_q] : 16'b0;", "wire [15:0] seed_data = deliver ? fifo[rd_q] : 16'b0;", 1),
 ("alarm_cleared_by_restart", "        if (rst)           alarm_q <= 1'b0;", "        if (rst || restart) alarm_q <= 1'b0;", 1),
 ("alarm_not_reported", SEED_OPST, "(state_q == S_DEAD)           ? OPST_DEAD :\n                            (test_q || hold || state_q == S_BIST) ? OPST_BIST :", 1),
 ("alarm_access_takes_a_word", POP, "wire pop     = deliver && seed_ack;", 1),
 # ---- the status register ----
 ("stat_no_cause",     "cause_q <= cause;", "cause_q <= 4'b0;", 1),
 ("stat_lanes_without_proportion", "lanes_q <= lane_rct | apt_fail;", "lanes_q <= lane_rct;", 1),
 ("stat_lanes_reversed", "{|rct_fail[15:12], |rct_fail[11:8], |rct_fail[7:4], |rct_fail[3:0]};", "{|rct_fail[3:0], |rct_fail[7:4], |rct_fail[11:8], |rct_fail[15:12]};", 1),
 ("stat_no_lags",      "lags_q <= lag_rct;", "lags_q <= 4'b0;", 1),
 ("stat_failures_not_counted", "            if (fails_q != 16'hffff) fails_q <= fails_q + 16'd1;\n", "", 1),
 ("stat_no_alarm",     "1'b0, strike_cnt, 1'b0, alarm_q, state_q};", "1'b0, strike_cnt, 1'b0, 1'b0, state_q};", 1),
 ("stat_no_strikes",   "1'b0, strike_cnt, 1'b0, alarm_q, state_q};", "1'b0, 3'd0, 1'b0, alarm_q, state_q};", 1),
 ("stat_no_state",     "1'b0, strike_cnt, 1'b0, alarm_q, state_q};", "1'b0, strike_cnt, 1'b0, alarm_q, 2'd1};", 1),
 # ---- the strap and the dead source ----
 ("strap_ignored",     "wire hold    = !en_i;", "wire hold    = 1'b0;", 1),
 ("strap_keeps_source_on", "assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);", "assign rng_en_o   = (state_q != S_DEAD || test_q);", 1),
 ("dead_source_stays_off_in_test_mode", "assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);", "assign rng_en_o   = en_i && (state_q != S_DEAD);", 1),
 ("dead_source_left_on", "assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);", "assign rng_en_o   = en_i;", 1),
 ("strap_symbols_kept", "wire sym_in = rng_val_i && en_i;", "wire sym_in = rng_val_i;", 1),
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
    name, old, new, which = m
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
    return name, ("caught" if r.returncode != 0 and line else "MISSED"), line

with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    results = list(pool.map(run, M))
missed = 0
for name, verdict, line in results:
    print(f"{verdict:7s} {name:34s} {line[:150]}")
    missed += verdict != "caught"
print(f"entropy mutants: {len(results) - missed} of {len(results)} caught")
sys.exit(1 if missed else 0)
