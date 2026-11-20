#!/usr/bin/env python3
"""Mutant controls for the burst capture of the FPGA entropy source (part of
make noise-burst-test).

Each mutant changes one mechanism of flow/fpga/karu_noise_burst.v, of its
wiring in flow/fpga/karu_entropy_src.v, of the sampling divider in
flow/fpga/karu_rosc_rng.v, or of the two status outputs of
rtl/karu_entropy.v. It is built without the modules' own assertions
(KARU_NO_ASSERT), so test/tb_noise_burst.sv alone has to notice. A mutant
that still passes is reported as MISSED and fails the run.

    python3 test/noise_burst_mutants.py --out _build/noise-burst/mut
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
TB = ROOT / "test/tb_noise_burst.sv"
BURST, SRC, ROSC, ENT = "flow/fpga/karu_noise_burst.v", "flow/fpga/karu_entropy_src.v", "flow/fpga/karu_rosc_rng.v", "rtl/karu_entropy.v"
RTL = {name: (ROOT / name).read_text() for name in (BURST, SRC, ROSC, ENT)}

M = [
 # ---- karu_noise_burst.v: what is allowed, and when ----
 ("lock_ignored",        BURST, "wire allow = test_i && !lock_i;", "wire allow = test_i;"),
 ("test_mode_ignored",   BURST, "wire allow = test_i && !lock_i;", "wire allow = !lock_i;"),
 ("state_kept_outside_test_mode", BURST, "		if (rst || !allow) begin\n", "		if (rst) begin\n"),
 ("period_outside_test_mode", BURST, "	assign div_o = allow ? div_q : DIV_RESET;", "	assign div_o = lock_i ? DIV_RESET : div_q;\n	wire allow_unused_by_div = allow;"),
 ("period_never_applied", BURST, "	assign div_o = allow ? div_q : DIV_RESET;", "	assign div_o = DIV_RESET;"),
 ("data_without_done",   BURST, "(reg_raddr_i == R_DATA && allow && done_q) ? rd_q : 64'b0;", "(reg_raddr_i == R_DATA && allow) ? rd_q : 64'b0;"),
 ("data_outside_test_mode", BURST, "(reg_raddr_i == R_DATA && allow && done_q) ? rd_q : 64'b0;", "(reg_raddr_i == R_DATA) ? rd_q : 64'b0;"),
 ("done_with_the_last_write", BURST, "			fin_q <= last && !brk;\n			if (fin_q) begin\n", "			fin_q <= 1'b0;\n			if (last) begin\n"),
 ("start_ignores_source", BURST, "busy_q <= rng_en_i; done_q <= 1'b0; brk_q <= !rng_en_i;", "busy_q <= 1'b1; done_q <= 1'b0; brk_q <= 1'b0;"),
 ("no_abort", BURST, "	wire brk     = allow && busy_q && !fin_q && !rng_en_i;", "	wire brk     = 1'b0;"),
 ("done_survives_start", BURST, "busy_q <= rng_en_i; done_q <= 1'b0; brk_q <= !rng_en_i; cnt_q <= {(AW+4){1'b0}};", "busy_q <= rng_en_i; brk_q <= !rng_en_i; cnt_q <= {(AW+4){1'b0}};"),
 # ---- the capture ----
 ("start_restarts_a_capture", BURST, "reg_wdata_i[0] && !busy_q;", "reg_wdata_i[0];"),
 ("start_without_the_bit", BURST, "reg_waddr_i == R_CTRL && reg_wdata_i[0] && !busy_q;", "reg_waddr_i == R_CTRL && !busy_q;"),
 ("period_write_while_busy", BURST, "wire period_we = allow && reg_we_i && reg_waddr_i == R_PERIOD && !busy_q;", "wire period_we = allow && reg_we_i && reg_waddr_i == R_PERIOD;"),
 ("period_write_keeps_the_mnoise_run", BURST, "	assign respace_o = period_we;", "	assign respace_o = 1'b0;"),
 ("read_stalls_capture", BURST, "wire take    = allow && busy_q && !fin_q && rng_val_i;", "wire take    = allow && busy_q && !fin_q && rng_val_i && !reg_re_i;"),
 ("one_symbol_short",    BURST, "wire last    = take && (&cnt_q);", "wire last    = take && (&cnt_q[AW+3:1]);"),
 ("symbol_order",        BURST, "part_q <= {rng_b_i, part_q[59:4]};", "part_q <= {part_q[55:0], rng_b_i};"),
 ("word_order",          BURST, "mem[cnt_q[AW+3:4]] <= {rng_b_i, part_q};", "mem[cnt_q[AW+3:4]] <= {part_q, rng_b_i};"),
 ("bits_combined",       BURST, "mem[cnt_q[AW+3:4]] <= {rng_b_i, part_q};", "mem[cnt_q[AW+3:4]] <= {rng_b_i, part_q} ^ {4'b0, part_q};"),
 ("word_address",        BURST, "mem[cnt_q[AW+3:4]] <= {rng_b_i, part_q};", "mem[cnt_q[AW+2:3]] <= {rng_b_i, part_q};"),
 # ---- reading ----
 ("no_auto_increment",   BURST, "pop ? idx_q + 1'b1 : idx_q;", "pop ? idx_q : idx_q;"),
 ("any_read_moves_index", BURST, "wire pop     = allow && done_q && reg_re_i && reg_raddr_i == R_DATA;", "wire pop     = allow && done_q && reg_re_i;"),
 ("look_moves_index",    BURST, "wire pop     = allow && done_q && reg_re_i && reg_raddr_i == R_DATA;", "wire pop     = allow && done_q && reg_raddr_i == R_DATA;"),
 ("read_address_late",   BURST, "rd_q <= mem[idx_n];", "rd_q <= mem[idx_q];"),
 ("index_write_loses_to_read", BURST, "idx_we ? reg_wdata_i[AW-1:0] : pop ? idx_q + 1'b1 : idx_q;", "pop ? idx_q + 1'b1 : idx_we ? reg_wdata_i[AW-1:0] : idx_q;"),
 ("status_no_progress",  BURST, "wire [15:0]	words_done = {{(16-AW){1'b0}}, cnt_q[AW+3:4]};", "wire [15:0]	words_done = 16'd0;"),
 ("status_source_bit",   BURST, "1'b0, brk_q, test_i, rng_en_i, lock_i, allow, done_q, busy_q};", "1'b0, brk_q, test_i, 1'b1, lock_i, allow, done_q, busy_q};"),
 # ---- karu_entropy_src.v: wiring ----
 ("burst_always_in_test_mode", SRC, ".test_i(noise_test), .lock_i(cfg_lock),", ".test_i(1'b1), .lock_i(cfg_lock),"),
 ("burst_never_locked",  SRC, ".test_i(noise_test), .lock_i(cfg_lock),", ".test_i(noise_test), .lock_i(1'b0),"),
 ("period_not_wired",    SRC, ".rng_fips_i(rng_fips), .rng_div_i(rng_div),", ".rng_fips_i(rng_fips), .rng_div_i(DIV_RESET),"),
 ("burst_sees_no_enable", SRC, ".rng_en_i(rng_en), .rng_val_i(rng_val), .rng_b_i(rng_b), .div_o(rng_div),", ".rng_en_i(1'b1), .rng_val_i(rng_val), .rng_b_i(rng_b), .div_o(rng_div),"),
 # ---- karu_rosc_rng.v: the divider ----
 ("divider_equality",    ROSC, "assign sample = (div_q >= rng_div_i);", "assign sample = (div_q == rng_div_i);"),
 ("divider_one_long",    ROSC, "assign sample = (div_q >= rng_div_i);", "assign sample = (div_q > rng_div_i);"),
 ("symbol_not_synchronised", ROSC, "				rng_b_o <= meta_q;", "				rng_b_o <= samp_q;"),
 # ---- karu_entropy.v: the status outputs ----
 ("test_output_stuck",   ENT, "assign test_o     = test_q;", "assign test_o     = 1'b1;"),
 ("lock_output_stuck",   ENT, "assign lock_o     = lock_q;", "assign lock_o     = 1'b0;"),
]

def run(m):
    name, target, old, new = m
    text = RTL[target]
    if text.count(old) != 1:
        return name, "PATTERN", f"pattern found {text.count(old)} times in {target}"
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / Path(target).name).write_text(text.replace(old, new))
    sources = [str(d / Path(target).name) if f == target else str(ROOT / f) for f in (SRC, ROSC, ENT, BURST)]
    b = subprocess.run(["verilator", "--binary", "--timing", "-Wno-fatal", "-DKARU_NO_ASSERT", "--top-module", "tb_noise_burst",
                        "-Mdir", str(d / "obj"), "-o", "tb", str(TB), *sources], capture_output=True, text=True)
    if b.returncode:
        return name, "BUILD", (b.stdout[-300:] + b.stderr[-300:]).replace("\n", " ")
    r = subprocess.run([str(d / "obj" / "tb")], capture_output=True, text=True, timeout=900)
    line = next((l for l in r.stdout.splitlines() if l.startswith("FAIL noise burst")), "")
    return name, ("caught" if r.returncode != 0 and line else "MISSED"), line

with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    results = list(pool.map(run, M))
missed = 0
for name, verdict, line in results:
    print(f"{verdict:7s} {name:30s} {line[:160]}")
    missed += verdict != "caught"
print(f"noise burst mutants: {len(results) - missed} of {len(results)} caught")
sys.exit(1 if missed else 0)
