#!/usr/bin/env python3
"""Discriminate locked discovery and executable-scratch maintenance fixes."""
# SPDX-License-Identifier: BSD-2-Clause
from pathlib import Path
import subprocess

out=Path('_build/dbg/sba-review-negative');out.mkdir(parents=True,exist_ok=True)
sources=[line.strip() for line in Path('dbg/karudbg.f').read_text().splitlines()
         if line.strip() and not line.lstrip().startswith('//')]
cases=[('locked-discovery','dbg/karudbg_core.v',
        'karudbg #(.SBA_ENABLE(SBA_ENABLE)) dm', 'karudbg #(.SBA_ENABLE(1)) dm',
        ['-DTEST_SBA_CORE_LOCKED'],'locked SBA discovery/registers read zero'),
       ('scratch-maintenance','dbg/karudbg_bus.v',
        "sba_ram = a[63:32]==0 && (a[31] ||\n                (a[31:12]>=20'h00101 && a[31:12]<20'h00111));",
        'sba_ram = a[63:32]==0 && a[31];',[],
        'SBA live code patch discards every stale increment opcode')]
for name,filename,before,after,defines,expected in cases:
    folder=out/name;folder.mkdir(exist_ok=True)
    text=Path(filename).read_text()
    if text.count(before)!=1:raise RuntimeError('mutation location missing '+name)
    mutated=folder/Path(filename).name;mutated.write_text(text.replace(before,after))
    selected=[str(mutated) if path==filename else path for path in sources]
    binary=folder/'test.vvp'
    with (folder/'compile.log').open('w') as stream:
        subprocess.run(['iverilog','-g2012','-Irtl','-Idbg','-DKARU_DBG','-DKARU_DBG_SBA',
                        '-DKARU_ICACHE','-DKARU_NO_F','-DKARU_NO_V','-DKARU_ASIC',
                        '-DTEST_SBA_PROBE',*defines,'-s','tb_dbg_core','-o',str(binary),
                        'test/dbg/tb_dbg_core.sv','test/dbg/karudbg_test_ram.sv',*selected],
                       stdout=stream,stderr=subprocess.STDOUT,timeout=120,check=True)
    result=subprocess.run(['vvp',str(binary)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=120)
    (folder/'run.log').write_text(result.stdout)
    if not result.returncode or expected not in result.stdout:raise RuntimeError(name+': '+result.stdout)
    print('PASS actual-core SBA review negative control',name)
