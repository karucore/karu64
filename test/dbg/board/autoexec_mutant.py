#!/usr/bin/env python3
"""Write a copy of dbg/karudbg.v with selectable autoexec defects.

Negative control for the board autoexec case (rehearse.py). One simulator
build serves every defect: the copy behaves like the original unless the
simulator is started with one of these plusargs.

  +autoexec_dead   only DATA0 still triggers; DATA1 and the eight Program
                   Buffer triggers do nothing
  +autoexec_any    any trigger register launches the command while any
                   autoexec bit is set (the bit index is ignored)
  +autoexec_wany   as autoexec_any, but only for writes: reads behave
                   correctly, so only a check of unselected writes sees it
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from pathlib import Path

ANCHOR = "    assign autoexec_access = AUTOEXEC &&\n"
MUTANT = """    // ---- board-case negative control (test/dbg/board/autoexec_mutant.py) ----
    reg [1:0] board_mut;
    initial begin
        board_mut = 2'd0;
        if ($test$plusargs("autoexec_dead")) board_mut = 2'd1;
        if ($test$plusargs("autoexec_any")) board_mut = 2'd2;
        if ($test$plusargs("autoexec_wany")) board_mut = 2'd3;
    end
    wire board_trigger_reg = req_addr_i == 7'h04 || req_addr_i == 7'h05 ||
                             (req_addr_i >= 7'h20 && req_addr_i <= 7'h27);
    wire autoexec_access_good;
    assign autoexec_access =
        board_mut == 2'd1 ? (AUTOEXEC && req_addr_i == 7'h04 && autoexec_q[0]) :
        board_mut == 2'd2 ? (AUTOEXEC && board_trigger_reg && (|autoexec_q)) :
        board_mut == 2'd3 ? (autoexec_access_good ||
                             (AUTOEXEC && board_trigger_reg && (|autoexec_q) && req_op_i == 2)) :
        autoexec_access_good;
    assign autoexec_access_good = AUTOEXEC &&
"""

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--src", default="dbg/karudbg.v")
parser.add_argument("--out", required=True)
args = parser.parse_args()
text = Path(args.src).read_text()
if text.count(ANCHOR) != 1:
    raise SystemExit(f"{args.src}: autoexec_access anchor not found exactly once")
out = Path(args.out)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(text.replace(ANCHOR, MUTANT))
