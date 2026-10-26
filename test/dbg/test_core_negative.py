#!/usr/bin/env python3
"""Prove that the actual-core debug checks reject selected RTL faults.

Each mutant is a scratch copy under _build/dbg/core-negative. The repository
sources are read only. Compilation and simulation are independently bounded;
a timeout is a failure of this runner, not a successful negative control.
SPDX-License-Identifier: BSD-2-Clause
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import subprocess


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise RuntimeError(f'mutation site is not unique: {before!r}')
    return text.replace(before, after, 1)


def mutate(name, text):
    if name == 'wrong-dpc':
        return replace_once(text, '.debug_pc_i(dbg_entry_pc)',
                            ".debug_pc_i(dbg_entry_pc + 64'd4)")
    if name == 'application-trap-leak':
        return replace_once(text, '        && !debug_mode && !dbg_enter\n',
                            '        && !dbg_enter\n')
    if name == 'wrs-cache-dependency':
        return replace_once(text,
                            'assign dbg_wrs_nop = (debug_mode || dbg_step_active) && issue_sys &&',
                            "assign dbg_wrs_nop = 1'b0 && (debug_mode || dbg_step_active) && issue_sys &&")
    if name == 'unauthorized-dret':
        result, count = re.subn(
            r'assign dbg_exit = dbg_dret_raw && debug_mode && debug_resume_req_i &&\s*ex_pc == [^;]+;',
            'assign dbg_exit = dbg_dret_raw && debug_mode;', text)
        if count != 1:
            raise RuntimeError('DRET mutation site is not unique')
        return result
    if name == 'scratch-corruption':
        if text.count('7b202473') < 1:
            raise RuntimeError('ROM restore instruction not found')
        return text.replace('7b202473', '00000413')  # restore s0 -> clear s0
    if name == 'extra-step-instruction':
        return replace_once(text, '          && (!dbg_step_active || !dbg_step_issued)\n', '')
    raise ValueError(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', default='_build/dbg/core-negative')
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    sources = [line.strip() for line in (root / 'dbg/karudbg.f').read_text().splitlines()
               if line.strip() and not line.lstrip().startswith('//')]
    cases = [
        ('wrong-dpc', 'rtl/karu64.v', 'register 07b1='),
        ('application-trap-leak', 'rtl/karu64.v', 'register 0341='),
        ('wrs-cache-dependency', 'rtl/karu64.v', 'debug/stepped WRS depends on cache handshake'),
        ('unauthorized-dret', 'rtl/karu64.v', 'hart escaped Debug Mode during command'),
        ('scratch-corruption', 'dbg/karudbg_rom.v', 'register 1008='),
        ('extra-step-instruction', 'rtl/karu64.v', 'register 07b1='),
    ]
    build = Path(args.build_dir).resolve()
    build.mkdir(parents=True, exist_ok=True)

    def run(case):
        name, source, expected = case
        case_dir = build / name
        case_dir.mkdir(exist_ok=True)
        original = root / source
        copy = case_dir / original.name
        copy.write_text(mutate(name, original.read_text()))
        selected = [str(copy) if path == source else str(root / path) for path in sources]
        binary = case_dir / 'test.vvp'
        compile_cmd = ['iverilog', '-g2012', '-Irtl', '-Idbg', '-DKARU_DBG',
                       '-DKARU_NO_F', '-DKARU_ASIC', '-s', 'tb_dbg_core',
                       '-o', str(binary), 'test/dbg/tb_dbg_core.sv',
                       'test/dbg/karudbg_test_ram.sv', *selected]
        with (case_dir / 'compile.log').open('w') as log:
            subprocess.run(compile_cmd, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                           timeout=120, check=True)
        result = subprocess.run(['vvp', str(binary)], cwd=root, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        (case_dir / 'run.log').write_text(result.stdout)
        if result.returncode == 0 or expected not in result.stdout:
            raise RuntimeError(f'{name}: missing expected failure {expected!r}; see {case_dir}/run.log')
        return f'{name}: PASS (rejected: {expected})'

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for result in pool.map(run, cases):
            print(result, flush=True)
    print(f'karudbg core negative controls: PASS ({len(cases)} mutants)')


if __name__ == '__main__':
    main()
