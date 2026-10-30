#!/usr/bin/env python3
"""Bounded ASIC parser/lint matrix with exact sources, defines and tool records.

This checks elaboration and portable syntax; it performs no mapping or signoff.
SPDX-License-Identifier: BSD-3-Clause
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT=Path(__file__).resolve().parents[2]
PROFILE=['SYNTHESIS','KARU_ASIC','KARU_RVA23S64','KARU_ICACHE','KARU_ZVK','KARU_KECCAK',
         'KARU_M_MUL_CYCLES=4','KARU_M_DIV_CYCLES=64','KARU_V_MUL_CYCLES=16',
         'KARU_V_DIV_CYCLES=64','KARU_V_LANE_PIPE','KARU_V_CWB_STAGE','KARU_SMCNTRPMF','KARU_SSCOFPMF']
ROWS={'off':[], 'base':['KARU_DBG'], 'autoexec':['KARU_DBG','KARU_DBG_AUTOEXEC'],
      'triggers':['KARU_DBG','KARU_DBG_TRIGGERS'], 'sba':['KARU_DBG','KARU_DBG_SBA'],
      'full':['KARU_DBG','KARU_DBG_FULL'], 'full4':['KARU_DBG','KARU_DBG_FULL','KARU_DBG_TRIGGER_COUNT=4']}
# Existing core warning policy; all other -Wall diagnostics remain fatal.
WARNINGS=['WIDTH','UNUSED','UNOPTFLAT','CASEINCOMPLETE','BLKANDNBLK','INITIALDLY',
          'TIMESCALEMOD','COMBDLY','CMPCONST','WIDTHEXPAND','WIDTHTRUNC','DECLFILENAME',
          'PINCONNECTEMPTY','BLKSEQ','PROCASSINIT','VARHIDDEN']

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def entries(path):return [x for line in path.read_text().splitlines()
                          if (x:=line.split('//',1)[0].strip())]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',default='_build/dbg/config-matrix')
    parser.add_argument('--jobs',type=int,default=2)
    args=parser.parse_args();out=(ROOT/args.out).resolve();out.mkdir(parents=True,exist_ok=True)
    paths=[ROOT/'Makefile',ROOT/'flow/asic/karu64.f',Path(__file__).resolve()]
    for dirname in ('rtl','dbg'):
        paths.extend(p for p in (ROOT/dirname).rglob('*') if p.suffix in ('.v','.vh','.sv','.f','.mk') and p.is_file())
    before={str(p.relative_to(ROOT)):sha(p) for p in sorted(set(paths))}
    versions={tool:subprocess.check_output([tool,arg],text=True,stderr=subprocess.STDOUT).splitlines()[0]
              for tool,arg in [('iverilog','-V'),('verilator','--version')]}
    def run(row):
        name,extra=row;directory=out/name;directory.mkdir(exist_ok=True)
        top='karu64' if name=='off' else 'karudbg_top'
        manifest=ROOT/('flow/asic/karu64.f' if name=='off' else 'dbg/karudbg.f')
        sources=entries(manifest);defines=PROFILE+extra
        flags=['-Irtl','-Idbg',*('-D'+d for d in defines)]
        source_file=directory/'preprocessed.v'
        commands=[['iverilog','-g2001','-E',*flags,'-o',str(source_file),'-c',str(manifest)],
                  ['iverilog','-g2001',*flags,'-s',top,'-o',str(directory/'parse.vvp'),'-c',str(manifest),
                   'rtl/karu_vrf_assert.sv'],
                  ['verilator','--lint-only','-Wall','-Wno-fatal',*('-Wno-'+w for w in WARNINGS),
                   *flags,'--Mdir',str(directory/'lint'),'--top-module',top,'-f',str(manifest)]]
        started=time.monotonic()
        for i,command in enumerate(commands):
            with (directory/f'{i}-tool.log').open('w') as log:
                subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=120,check=True)
        # Two pre-existing varith scratch outputs are intentionally unused in
        # this lane configuration. Do not waive undriven debug/control signals.
        diagnostics=(directory/'2-tool.log').read_text()
        warning_lines=[line for line in diagnostics.splitlines() if line.startswith('%Warning-')]
        unexpected=[line for line in warning_lines if not
                    (line.startswith('%Warning-UNDRIVEN: rtl/karu_varith.v:') and
                     ("'grp_res'" in line or "'grp_acc'" in line))]
        if unexpected:raise RuntimeError(name+': unexpected lint warnings: '+repr(unexpected))
        text=source_file.read_text()
        top_source=re.search(r'\bmodule\s+'+top+r'\b.*?\bendmodule\b',text,re.S)
        if not top_source:raise RuntimeError(name+': missing preprocessed top')
        header=top_source.group().split(');',1)[0]+');\n'
        (directory/'top-ports.v').write_text(header)
        if name=='off' and re.search(r'\bdebug_\w+',header):
            raise RuntimeError('feature-off top leaked debug ports')
        if any(re.search(r'\b'+primitive+r'\b',text) for primitive in ['BSCANE2','IBUF','BUFG','IDELAYE3','RAMB36E2']):
            raise RuntimeError(name+': FPGA primitive in conventional ASIC source')
        result=dict(configuration=name,top=top,manifest=str(manifest.relative_to(ROOT)),
                    sources=sources,defines=defines,commands=commands,tools=versions,
                    seconds=round(time.monotonic()-started,2),preprocessed_sha256=sha(source_file),
                    top_ports_sha256=sha(directory/'top-ports.v'),accepted_lint_warnings=warning_lines,passed=True)
        (directory/'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
        print(f'PASS ASIC configuration {name}: strict Verilog-2001 + Verilator ({result["seconds"]}s)',flush=True)
        return result
    with ThreadPoolExecutor(max_workers=max(1,min(args.jobs,6))) as pool:results=list(pool.map(run,ROWS.items()))
    after={str(p.relative_to(ROOT)):sha(p) for p in sorted(set(paths))}
    record=dict(passed=before==after,source_integrity=before==after,inputs_before=before,inputs_after=after,rows=results)
    (out/'results.json').write_text(json.dumps(record,indent=2)+'\n')
    if before!=after:raise RuntimeError('RTL/flow sources changed during matrix')
    print('karudbg ASIC configuration matrix: PASS (7 configurations)')
if __name__=='__main__':main()
