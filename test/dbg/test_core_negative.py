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
    if name == 'sba-cache-ack-during-read':
        return replace_once(text, 'end else begin\n            if (dbg_sba_flush)',
                            'end else if (dbg_sba_idle) begin\n            if (dbg_sba_flush)')
    if name == 'sba-idle-cache-ack':
        return replace_once(text, 'if (dbg_sba_cache_sent && cache_flush_done)',
                            'if ((dbg_sba_flush || dbg_sba_cache_sent) && cache_flush_done)')
    if name == 'sba-external-cache-wait':
        return replace_once(text, '(!debug_sba_flush_i || dbg_sba_cache_done)',
                            "(!debug_sba_flush_i || 1'b1)")
    if name == 'sba-interrupt-overtake':
        prefix, tail = text.split('    assign irq_take =', 1)
        gate, rest = tail.split(';', 1)
        gate = replace_once(gate, '&& !debug_sba_pause_i', "&& 1'b1")
        return prefix + '    assign irq_take =' + gate + ';' + rest
    if name == 'sba-baseline':
        return text
    if name == 'sba-no-reservation-clear':
        return replace_once(text, '\n            || debug_sba_pause_i\n',
                            "\n            || 1'b0\n")
    if name == 'sba-no-data-flush':
        return replace_once(text, '\n               || dbg_sba_flush\n',
                            "\n               || 1'b0\n")
    if name == 'sba-no-instruction-flush':
        return replace_once(text, '\n                        || dbg_sba_flush\n',
                            "\n                        || 1'b0\n")
    if name == 'sba-no-fetch-redirect':
        return replace_once(text, '\n                     dbg_sba_flush ||\n',
                            "\n                     1'b0 ||\n")
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
    parser.add_argument('--sba', action='store_true', help='run SBA coherence controls')
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
    if args.sba:
        cases = [
            ('sba-baseline', 'rtl/karu64.v', None),
            ('sba-no-reservation-clear', 'rtl/karu64.v', 'register 100d='),
            ('sba-no-data-flush', 'rtl/karu64.v', 'INV40s SBA maintenance must redirect fetch and flush both local caches'),
            ('sba-no-instruction-flush', 'rtl/karu64.v', 'INV40s SBA maintenance must redirect fetch and flush both local caches'),
            ('sba-no-fetch-redirect', 'rtl/karu64.v', 'INV40s SBA maintenance must redirect fetch and flush both local caches'),
            ('sba-interrupt-overtake', 'rtl/karu64.v', 'SBA issue hold defers pending interrupt entry'),
            ('sba-external-cache-wait', 'rtl/karu64.v', 'INV40q SBA response precedes external cache completion'),
            ('sba-idle-cache-ack', 'rtl/karu64.v', 'INV40o SBA done flag must follow independently observed acknowledgement'),
            ('sba-cache-ack-during-read', 'rtl/karu64.v', 'INV40o SBA done flag must follow independently observed acknowledgement'),
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
                       '-DKARU_NO_F', '-DKARU_ASIC',
                       *(['-DKARU_NO_V','-DKARU_DBG_SBA','-DKARU_ICACHE','-DTEST_SBA_PROBE'] if args.sba else []),
                       '-s', 'tb_dbg_core',
                       '-o', str(binary), 'test/dbg/tb_dbg_core.sv',
                       'test/dbg/karudbg_test_ram.sv', *selected]
        with (case_dir / 'compile.log').open('w') as log:
            subprocess.run(compile_cmd, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                           timeout=120, check=True)
        result = subprocess.run(['vvp', str(binary)], cwd=root, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        (case_dir / 'run.log').write_text(result.stdout)
        if expected is None:
            if result.returncode or 'karudbg focused SBA probe: PASS' not in result.stdout:
                raise RuntimeError(f'{name}: positive baseline failed; see {case_dir}/run.log')
            return f'{name}: PASS (unmodified four-state RTL)'
        if result.returncode == 0 or expected not in result.stdout:
            raise RuntimeError(f'{name}: missing expected failure {expected!r}; see {case_dir}/run.log')
        return f'{name}: PASS (rejected: {expected})'

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for result in pool.map(run, cases):
            print(result, flush=True)
    if args.sba:
        print(f'karudbg SBA core controls: PASS (1 positive baseline, {len(cases)-1} mutants)')
    else:
        print(f'karudbg core negative controls: PASS ({len(cases)} mutants)')


if __name__ == '__main__':
    main()
