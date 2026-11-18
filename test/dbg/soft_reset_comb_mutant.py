#!/usr/bin/env python3
"""Write a copy of karu_soft_reset.v whose reset_o is combinational.

Negative control for the single-flop check of the software reset output
(dbg-fpga-reset-test): the copy keeps the pulse in a flop but gates the
output with the board reset, so reset_o is no longer a flop's Q.
"""
# SPDX-License-Identifier: BSD-2-Clause
from pathlib import Path
import sys

source, target = Path(sys.argv[1]), Path(sys.argv[2])
text = source.read_text()
edits = [
    ("\toutput reg\treset_o\t\t", "\toutput wire\treset_o\t\t"),
    ("\treg [CW-1:0]\tcount;\n", "\treg [CW-1:0]\tcount;\n\treg\t\t\t\treset_q;\n\tassign\t\t\treset_o = reset_q && !por_i;\n"),
]
for before, after in edits:
    if text.count(before) != 1:
        raise SystemExit(f"{source}: mutant site not found exactly once: {before!r}")
    text = text.replace(before, after)
# every procedural use of the flop now refers to reset_q
body_start = text.index("\talways @(posedge clk) begin")
text = text[:body_start] + text[body_start:].replace("reset_o", "reset_q")
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(text)
