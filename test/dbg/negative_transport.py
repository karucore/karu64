#!/usr/bin/env python3
"""Prove the DTM/AXI directed checks reject selected implementation faults."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from pathlib import Path
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out",default="_build/dbg/negative")
args=parser.parse_args()
out=Path(args.out)
out.mkdir(parents=True,exist_ok=True)
cases=[
    ("cdc-reset-payload","dbg/karudbg_cdc.v","request_level <= 0;\n            clear_level <= 1;",
     "request_level <= 0;\n            request_payload <= 0;\n            clear_level <= 1;","tb_dtm",
     ["test/dbg/tb_dtm.sv","dbg/karudbg_jtag.v","dbg/karudbg_jtag_tap.v","dbg/karudbg_cdc.v"],"TRST holds bundled request payload"),
    ("dtm-version","dbg/karudbg_jtag.v","6'd7, 4'd1","6'd7, 4'd2","tb_dtm",
     ["test/dbg/tb_dtm.sv","dbg/karudbg_jtag.v","dbg/karudbg_jtag_tap.v","dbg/karudbg_cdc.v"],"DTMCS version/abits/idle"),
    ("dmireset-flush","dbg/karudbg_jtag.v","assign clear = tap_reset || hard_reset;",
     "assign clear = tap_reset || hard_reset || (dtm_sel && update && dtm_shift[16]);","tb_dtm",
     ["test/dbg/tb_dtm.sv","dbg/karudbg_jtag.v","dbg/karudbg_jtag_tap.v","dbg/karudbg_cdc.v"],"dmireset never flushes a transaction"),
    ("axi-authorization","dbg/karudbg_axi.v","!allow_i ||","1'b0 ||","tb_dbg_axi",
     ["test/dbg/tb_dbg_axi.sv","dbg/karudbg_axi.v"],"read response"),
]
for name,source,old,new,top,sources,expected in cases:
    text=Path(source).read_text()
    if old not in text:
        raise RuntimeError(f"{name}: mutation location missing")
    mutated=out/f"{name}.v"
    mutated.write_text(text.replace(old,new))
    binary=out/f"{name}.vvp"
    selected=[str(mutated) if s==source else s for s in sources]
    subprocess.run(["iverilog","-g2012","-s",top,"-o",str(binary),*selected],check=True,timeout=20)
    result=subprocess.run(["vvp",str(binary)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
    (out/f"{name}.log").write_text(result.stdout)
    if result.returncode==0 or expected not in result.stdout:
        raise RuntimeError(f"{name}: negative control did not fail as expected: {result.stdout}")
    print(f"PASS negative control {name}: {expected}")
