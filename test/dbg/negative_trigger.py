#!/usr/bin/env python3
"""Bounded controls for cache-hit, vector-element, mask and restart checking."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', default='_build/dbg/trigger-negative')
args = parser.parse_args()
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
cases = [
    ('registered-address', 'rtl/karu_vlsu.v',
     'watch_addr_q<=eaddr;', "watch_addr_q<=eaddr + 64'd1;",
     'registered watch address was not captured before query'),
    ('later-element', 'rtl/karu_vlsu.v',
     'else if (watch_q && !watch_checked) state <= S_WATCH_ADDR;',
     'else if (watch_q && !watch_checked && pe_i == 0) state <= S_WATCH_ADDR;',
     'hit outcome'),
    ('masked-element', 'rtl/karu_vlsu.v',
     'if (!pe_act) state <= S_PE_NEXT;',
     "if (1'b0) state <= S_PE_NEXT;", 'hit outcome'),
    ('restart-index', 'rtl/karu_vlsu.v',
     'assign debug_watch_index_o = pe_i;',
     "assign debug_watch_index_o = pe_i + 32'd1;", 'element restart index'),
    ('whole-element', 'rtl/karu64.v',
     '(trigger_v_valid && trigger_whole_start);',
     'trigger_v_valid;', 'whole-register interior stop'),
    ('cache-hit', 'rtl/karu64.v',
     'assign trigger_scalar_valid = ex_valid && !exec_busy && !debug_mode &&',
     'assign trigger_scalar_valid = ex_valid && !exec_busy && !debug_mode && !dmem_l1.line_valid[lsu_addr[11:6]] &&',
     'register 07b1='),
]
for name, source, before, after, expected in cases:
    original = Path(source).read_text()
    if original.count(before) != 1:
        raise RuntimeError(f'{name}: mutation site is not unique')
    target = out / name
    target.mkdir(exist_ok=True)
    mutant = target / Path(source).name
    mutant.write_text(original.replace(before, after, 1))
    flags = ['-g2012', '-Irtl', '-Idbg', '-DKARU_DBG', '-DKARU_DBG_TRIGGERS']
    if name in ('cache-hit', 'whole-element'):
        top = 'tb_dbg_core'
        sources = ['test/dbg/tb_dbg_core.sv', 'test/dbg/karudbg_test_ram.sv']
        sources += [p.strip() for p in Path('dbg/karudbg.f').read_text().splitlines()
                    if p.strip() and not p.lstrip().startswith('//')]
        flags += ['-DKARU_ASIC', '-DTEST_TRIGGER_PROBE']
        if name == 'cache-hit':
            flags += ['-DKARU_NO_F']
        else:
            flags += ['-DKARU_RVA23S64', '-DKARU_ICACHE', '-DKARU_V_LANE_PIPE', '-DKARU_V_CWB_STAGE', '-DTEST_WHOLE_PROBE']
            sources += ['rtl/karu_vrf_assert.sv']
    else:
        top = 'tb_vlsu_watch'
        sources = ['test/dbg/tb_vlsu_watch.sv', 'rtl/karu_vlsu.v', 'rtl/karu_vlsu_buf.v']
    sources = [str(mutant) if p == source else p for p in sources]
    binary = target / 'test.vvp'
    with (target / 'compile.log').open('w') as log:
        subprocess.run(['iverilog', *flags, '-s', top, '-o', str(binary), *sources],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=40)
    result = subprocess.run(['vvp', str(binary)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=40)
    (target / 'run.log').write_text(result.stdout)
    if result.returncode == 0 or expected not in result.stdout:
        raise RuntimeError(f'{name}: expected failure {expected!r} missing: {result.stdout}')
    print(f'PASS trigger negative control {name}: {expected}', flush=True)
