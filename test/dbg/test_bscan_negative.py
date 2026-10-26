#!/usr/bin/env python3
"""Prove the BSCAN protocol bench rejects clocking and bit-skew defects."""
# SPDX-License-Identifier: BSD-3-Clause
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', default='_build/dbg/bscan-negative')
args = parser.parse_args()
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
sources = [
    'test/dbg/tb_bscan_protocol.sv', 'test/dbg/tb_bscan_remote.v',
    'test/dbg/xilinx_tap_model.v', 'test/dbg/tb_jtag_remote.v',
    'dbg/karudbg_bscan_tunnel.v', 'dbg/karudbg_reset.v', 'dbg/karudbg_jtag.v',
    'dbg/karudbg_jtag_tap.v', 'dbg/karudbg_cdc.v',
    'dbg/karudbg.v', 'dbg/karudbg_rom.v',
]
mutants = [
    ('ungated-inner-clock', 'test/dbg/tb_bscan_remote.v',
     '.tck(drck),.reset_i(!frame_trst_n)', '.tck(tck),.reset_i(!frame_trst_n)'),
    ('inverted-output-bit', 'dbg/karudbg_bscan_tunnel.v',
     'tdo_o <= inner_tdo_i;', 'tdo_o <= !inner_tdo_i;'),
]
for name, source, old, new in mutants:
    text = Path(source).read_text()
    if text.count(old) != 1:
        raise RuntimeError(f'{name}: expected unique mutation site')
    mutant = out / (name + Path(source).suffix)
    mutant.write_text(text.replace(old, new))
    model = out / (name + '.vvp')
    subprocess.run(['iverilog', '-g2012', '-Idbg', '-s', 'tb_bscan_protocol',
                    '-o', str(model)] + [str(mutant) if p == source else p for p in sources],
                   check=True, timeout=20, capture_output=True, text=True)
    result = subprocess.run(['vvp', str(model)], timeout=10,
                            capture_output=True, text=True)
    (out / (name + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode == 0 or 'FATAL' not in result.stdout or 'timeout' in result.stdout:
        raise RuntimeError(f'{name}: mutant escaped or timed out')
    print(f'PASS BSCAN negative control {name}')
