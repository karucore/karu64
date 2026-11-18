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

M = [
 ("deliver_on_fail",   "!test_q && !fail && !hold;", "!test_q && !hold;", 1),
 ("no_burst_rule",     "            if (burst_n == 3'd0 && fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST})\n                burst_q <= BURST;\n            else\n                burst_q <= burst_n;\n",
                       "            burst_q <= {2'b0, fill_n != 0};\n", 1),
 ("drain_partial",     "            if (burst_n == 3'd0 && fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST})\n                burst_q <= BURST;\n            else\n                burst_q <= burst_n;\n",
                       "            if (fill_n >= {{(FIFO_LOG2-2){1'b0}}, BURST}) burst_q <= BURST;\n            else burst_q <= {2'b0, (burst_q != 3'd0) && (fill_n != 0)};\n", 1),
 ("no_wipe_on_read",   "                fifo[rd_q] <= 16'b0;\n", "", 1),
 ("no_wipe_on_restart", "            for (w = 0; w < FIFO_WORDS; w = w + 1) fifo[w] <= 16'b0;\n", "", 2),
 ("sym_lost_on_pop",   "            if (sym_v) begin                    //", "            if (sym_v && !raw_pop) begin        //", 1),
 ("loss_not_flagged",  "if (raw_v && !raw_pop) raw_lost <= 1'b1;", "if (1'b0) raw_lost <= 1'b1;", 1),
 ("false_loss_on_pop", "if (raw_v && !raw_pop) raw_lost <= 1'b1;", "if (raw_v) raw_lost <= 1'b1;", 1),
 ("no_new_run",        "            if (raw_new) raw_lost <= 1'b0;\n", "", 1),
 ("apt_no_limit",      "lim_apt = (v > APT_MAX) ? APT_MAX : v;", "lim_apt = v;", 1),
 ("rct_no_limit",      "lim_rct = (v > RCT_MAX) ? RCT_MAX : v;", "lim_rct = v;", 1),
 ("interval_no_floor", "lim_int = (v < INTERVAL_MIN) ? INTERVAL_MIN : v;", "lim_int = v;", 1),
 ("lock_ignored_cfg",  "wire cfg_write   = cfg_we && !lock_q;", "wire cfg_write   = cfg_we;", 1),
 ("lock_ignored_noise", "wire noise_write = noise_we && !lock_q;", "wire noise_write = noise_we;", 1),
 ("tests_run_in_test_mode", "wire test_run = sym_v && !test_q && (state_q != S_DEAD);", "wire test_run = sym_v && (state_q != S_DEAD);", 1),
 ("rct_off_by_one",    "rct_fail[l] = (rct_n[l] >= rct_q);", "rct_fail[l] = (rct_n[l] > rct_q);", 1),
 ("apt_off_by_one",    "apt_fail[l] = (apt_n[l] >= apt_q);", "apt_fail[l] = (apt_n[l] > apt_q);", 1),
 ("bist_failure_not_fatal", "state_q <= (state_q == S_BIST) ? S_DEAD : S_BIST;", "state_q <= S_BIST;", 1),
 ("no_decimation",     "wire sym_v  = sym_in && (int_cnt == int_q);", "wire sym_v  = sym_in;", 1),
 ("cfg_write_no_restart", "wire restart = cfg_write || (noise_write && (test_next != test_q));", "wire restart = (noise_write && (test_next != test_q));", 1),
 ("startup_one_short", "localparam [10:0] STARTUP = 11'd1024;", "localparam [10:0] STARTUP = 11'd1023;", 1),
 ("bits_combined",     "fifo[wr_q] <= {part_q, rng_b_i};", "fifo[wr_q] <= {part_q, rng_b_i} ^ {4'b0, part_q};", 1),
 ("dead_revived",      "            state_q <= S_DEAD;\n        end else if (restart || hold) begin", "            state_q <= restart ? S_BIST : S_DEAD;\n        end else if (restart || hold) begin", 1),
 ("pop_keeps_symbol",  "            if (raw_pop) begin raw_v <= 1'b0; raw_q <= 4'b0; end\n", "", 1),
 ("word_order",        "fifo[wr_q] <= {part_q, rng_b_i};", "fifo[wr_q] <= {rng_b_i, part_q};", 1),
 ("strap_ignored",     "wire hold    = !en_i;", "wire hold    = 1'b0;", 1),
 ("strap_keeps_source_on", "assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);", "assign rng_en_o   = (state_q != S_DEAD || test_q);", 1),
 ("dead_source_stays_off_in_test_mode", "assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);", "assign rng_en_o   = en_i && (state_q != S_DEAD);", 1),
 ("dead_source_left_on", "assign rng_en_o   = en_i && (state_q != S_DEAD || test_q);", "assign rng_en_o   = en_i;", 1),
 ("strap_symbols_kept", "wire sym_in = rng_val_i && en_i;", "wire sym_in = rng_val_i;", 1),
 ("trng_port_no_pop",  "wire ack      = (csr_wr && csr_sel_i == SEL_SEED) || trng_ack_i;", "wire ack      = (csr_wr && csr_sel_i == SEL_SEED);", 1),
 ("seed_custom_bits",  "wire [63:0] seed_rdata  = {32'b0, opst_o, 14'b0, data_o};", "wire [63:0] seed_rdata  = {32'b0, opst_o, 6'b0, 8'h01, data_o};", 1),
 ("seed_pop_without_write", "wire csr_wr   = csr_fire_i && csr_we_i;", "wire csr_wr   = csr_fire_i;", 1),
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
    print(f"{verdict:7s} {name:24s} {line[:150]}")
    missed += verdict != "caught"
print(f"entropy mutants: {len(results) - missed} of {len(results)} caught")
sys.exit(1 if missed else 0)
