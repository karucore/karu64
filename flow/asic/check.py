#!/usr/bin/env python3
"""Run ASIC memory startup checks and core tests with randomized unreset state."""
from pathlib import Path
import hashlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '_build/asic-check'
OUT.mkdir(parents=True, exist_ok=True)


def run(args, name):
    path = OUT / name
    with path.open('w') as log:
        subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    return path.read_text()


test = str(OUT / 'tb_asic_mem.vvp')
run(['iverilog', '-g2012', '-DKARU_ASIC', '-Irtl', '-s', 'tb_asic_mem', '-o', test,
     'rtl/karu_ram_prim.v', 'rtl/karu_vrf_bram.v', 'rtl/karu_vrf_assert.sv',
     'rtl/karu_regfile.v', 'rtl/karu_fregfile.v', 'test/tb_asic_mem.sv'], 'four-state-build.log')
text = run(['vvp', test], 'four-state.log')
assert 'ASIC_MEM PASS' in text
print('PASS four-state memory/checker test (two expected corruption detections)', flush=True)

defines = (ROOT / 'flow/asic/rva23s64.defines').read_text().split()
flags = ['-Irtl'] + ['-D' + d for d in defines if d != 'SYNTHESIS']
# The HTIF bench uses SIM_TB. Explicitly reproduce the non-SIM arithmetic
# defaults from karu_cfg.vh so this test matches the ASIC configuration.
flags += ['-DKARU_MUL_CYCLES=4', '-DKARU_DIV_CYCLES=64',
          '--x-initial', 'unique', '--x-assign', 'unique']
model_dir = '_build/Vhtif_asic_' + hashlib.sha256(' '.join(flags).encode()).hexdigest()[:12]
sim = model_dir + '/Vhtif_tb'
run(['make', '-j8', sim, '_build/vresv_subj.hex', '_build/vperm_subj.hex',
     '_build/vstart_subj.hex', 'VERI_FP_DIR=' + model_dir,
     'VFLAGS=' + ' '.join(flags)], 'build.log')
for seed in (1, 42):
    for suite in ('vresv', 'vperm', 'vstart'):
        text = run([sim, f'+hex=_build/{suite}_subj.hex', '+tohost=8000',
                    '+max_cycles=4000000', '+verilator+rand+reset+2',
                    f'+verilator+seed+{seed}'], f'{suite}-seed{seed}.log')
        assert f'[{suite.upper()}] ALL PASS' in text and '[HTIF] exit 0 ' in text, (suite, seed)
        assert '[FAIL]' not in text and '[KARU-VRF] FAIL' not in text, (suite, seed)
        print(f'PASS {suite} seed={seed}: {text.count("[ ok ]")} checks', flush=True)
