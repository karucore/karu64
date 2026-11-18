#!/usr/bin/env python3
"""Require independent SBA invariant monitors to reject corrupted DUT state."""
# SPDX-License-Identifier: BSD-2-Clause
from pathlib import Path
import subprocess

out=Path('_build/dbg/sba-invariants')
out.mkdir(parents=True,exist_ok=True)
for bench, sources, cases in (
    ('tb_sba', ['test/dbg/tb_sba.sv','dbg/karudbg_sba.v'],
     [('engine_state','SBAR1 invalid ownership'),('engine_owner','SBAR2 response ownership'),('engine_stability','SBAR3 stalled request'),('engine_cancel','SBAR4 inactive request')]),
    ('tb_sba_bus', ['test/dbg/tb_sba_bus.sv','dbg/karudbg_bus.v'],
     [('bus_state','SBAB1 invalid bus'),('bus_owner','SBAB2 SBA ownership'),('bus_isolation','SBAB3 SBA response'),
      ('bus_duplicate','SBAB4 duplicate'),('bus_drain','SBAB4 ownership or pre-write drain'),('bus_maintenance','SBAB5 maintenance'),('bus_stability','SBAB6 stalled AR'),('bus_reply','SBAB7 stalled response'),
      ('bus_pause','SBAB8 pause differs')])):
    binary=out/(bench+'.vvp')
    subprocess.run(['iverilog','-g2012','-Irtl','-Idbg','-DKARU_DBG','-s',bench,'-o',str(binary),*sources],check=True,timeout=30)
    baseline=subprocess.run(['vvp',str(binary)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
    (out/(bench+'-baseline.log')).write_text(baseline.stdout)
    if baseline.returncode or 'PASS' not in baseline.stdout: raise RuntimeError(baseline.stdout)
    for name, diagnostic in cases:
        result=subprocess.run(['vvp',str(binary),'+bad_'+name],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
        (out/(name+'.log')).write_text(result.stdout)
        if not result.returncode or diagnostic not in result.stdout: raise RuntimeError(name+': '+result.stdout)
        print('PASS SBA invariant negative control',name,diagnostic)
