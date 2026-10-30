#!/usr/bin/env python3
"""Prove the DM/DTM/AXI directed checks reject selected implementation faults."""
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
    ("autoexec-disabled","dbg/karudbg.v","|| autoexec_access;","|| 1'b0;","tb_dm",
     ["test/dbg/tb_dm.sv","dbg/karudbg.v","dbg/karudbg_rom.v","dbg/karudbg_sba.v"],"expected 08001002",
     ["-Idbg","-DTEST_AUTOEXEC","-DKARU_DBG_AUTOEXEC"]),
    ("autoexec-held-replay","dbg/karudbg.v","if (dmi_fire && req_op_i != 0 && req_op_i != 3)",
     "if (req_valid_i && req_op_i != 0 && req_op_i != 3)","tb_dm",
     ["test/dbg/tb_dm.sv","dbg/karudbg.v","dbg/karudbg_rom.v","dbg/karudbg_sba.v"],"expected 08000002",
     ["-Idbg","-DTEST_AUTOEXEC","-DKARU_DBG_AUTOEXEC"]),
    ("autoexec-write-order","dbg/karudbg.v","7'h04: data_q[31:0] <= req_data_i;",
     "7'h04: if (!autoexec_access) data_q[31:0] <= req_data_i;","tb_dm",
     ["test/dbg/tb_dm.sv","dbg/karudbg.v","dbg/karudbg_rom.v","dbg/karudbg_sba.v"],"autoexec write visible to the following command",
     ["-Idbg","-DTEST_AUTOEXEC","-DKARU_DBG_AUTOEXEC"]),
    ("autoexec-read-order","dbg/karudbg.v","if (resp_valid_o && resp_ready_i)",
     "if (resp_valid_o && !resp_ready_i && mem_fire && mem_write_i && mem_aligned_addr == `KARUDBG_DATA) resp_data_o <= mem_wdata_i[31:0];\n            if (resp_valid_o && resp_ready_i)","tb_dm",
     ["test/dbg/tb_dm.sv","dbg/karudbg.v","dbg/karudbg_rom.v","dbg/karudbg_sba.v"],"autoexec read response stable through execution",
     ["-Idbg","-DTEST_AUTOEXEC","-DKARU_DBG_AUTOEXEC"]),
    ("autoexec-stale-command","dbg/karudbg.v",
     "if (AUTOEXEC && req_op_i == 2 && req_addr_i == 7'h17)",
     "if (1'b0 && req_op_i == 2 && req_addr_i == 7'h17)","tb_dm",
     ["test/dbg/tb_dm.sv","dbg/karudbg.v","dbg/karudbg_rom.v","dbg/karudbg_sba.v"],"expected 08000202",
     ["-Idbg","-DTEST_AUTOEXEC","-DKARU_DBG_AUTOEXEC"]),
    ("sba-write-before-drain","dbg/karudbg_bus.v","(!wants_ram || (pause_q && quiet_i))","1'b1","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"RAM acceptance waits for registered pause",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
    ("sba-combinational-pause","dbg/karudbg_bus.v","assign pause_o = pause_q;",
     "assign pause_o = pause_next;","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"pause has no combinational request/reset path",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
    ("sba-early-ram-accept","dbg/karudbg_bus.v","(pause_q && quiet_i)","quiet_i","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"RAM acceptance waits for registered pause",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
    ("sba-pause-drain","dbg/karudbg_bus.v","(req_valid_i && wants_ram)",
     "(state==IDLE && req_valid_i && wants_ram)","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"pending RAM pause spans older core write drain",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
    ("sba-skip-maintenance","dbg/karudbg_bus.v","state<=ram_write_q ? MAINT : REPLY;","state<=REPLY;","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"RAM write flush precedes result",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
    ("sba-byte-strobes","dbg/karudbg_bus.v","assign m_wstrb = core_write ? c_wstrb : (byte_mask);",
     "assign m_wstrb = core_write ? c_wstrb : 8'hff;","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"native SBA write address, data, strobe and protection",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
    ("sba-core-burst","dbg/karudbg_bus.v","assign m_awlen = core_write ? c_awlen : (8'b0);",
     "assign m_awlen = 0;","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"core AW fields preserved",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
    ("sba-high-alias","dbg/karudbg_bus.v","(req_addr_i[63:32] != 0) || !karu_pma_ok(req_addr_i,","!karu_pma_ok({32'b0,req_addr_i[31:0]},","tb_sba_bus",
     ["test/dbg/tb_sba_bus.sv","dbg/karudbg_bus.v"],"rejected access has no bus effect",
     ["-Irtl","-Idbg","-DKARU_DBG"]),
]
for name,source,old,new,top,sources,expected,*options in cases:
    text=Path(source).read_text()
    if old not in text:
        raise RuntimeError(f"{name}: mutation location missing")
    mutated=out/f"{name}.v"
    mutated.write_text(text.replace(old,new))
    binary=out/f"{name}.vvp"
    selected=[str(mutated) if s==source else s for s in sources]
    subprocess.run(["iverilog","-g2012",*(options[0] if options else []),"-s",top,"-o",str(binary),*selected],check=True,timeout=20)
    result=subprocess.run(["vvp",str(binary)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
    (out/f"{name}.log").write_text(result.stdout)
    if result.returncode==0 or expected not in result.stdout:
        raise RuntimeError(f"{name}: negative control did not fail as expected: {result.stdout}")
    print(f"PASS negative control {name}: {expected}")
