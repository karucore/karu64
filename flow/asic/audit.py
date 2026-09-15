#!/usr/bin/env python3
"""Elaborate the fixed ASIC manifest, inventory arrays, reject power-up state.

Run from any directory. No technology mapping or memory latency conversion is
performed. Raw Yosys memory ports count access sites, not physical macro ports.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def entries(path):
    return [s for line in path.read_text().splitlines()
            if (s := line.strip()) and not s.startswith('#')]


def classify(module, name, writes):
    if writes == 0:
        return 'constant_logic', 'case/function lookup; not power-up state'
    if module == 'karu_tdp_be_ram':
        return 'macro_candidate', '2RW TDP; synchronous read; 16 byte write enables/port; NO_CHANGE'
    if module == 'karu_1w1r_async_ram':
        return 'macro_candidate', '1W1R; asynchronous read; full-word write; no bit enable'
    if module == 'karu_1w2r_async_ram':
        return 'macro_candidate', '1W2R; asynchronous reads; full-word write; no bit enable'
    if module in ('karu_regfile', 'karu_fregfile'):
        return 'register_file', ('1W2R' if module == 'karu_regfile' else '1W3R') + '; asynchronous reads; full-word write'
    if module == 'karu_vlsu_buf':
        return 'scratch_refactor', 'async multi-access scratch; retain flops or redesign banking; see README'
    return 'control_flops', 'parallel control/state array; retain flip-flops; see README'


def inventory(design):
    modules = design['modules']
    rows = []
    initialized = []
    constant_seen = {}

    def walk(module, path):
        mod = modules[module]
        original = mod.get('attributes', {}).get('hdlname', module)
        for name, net in mod.get('netnames', {}).items():
            if set(str(net.get('attributes', {}).get('init', ''))) & {'0', '1'}:
                initialized.append(path + '.' + name)
        for name, cell in sorted(mod.get('cells', {}).items()):
            kind = cell['type']
            full = path + '.' + name
            if kind in modules:
                walk(kind, full)
                continue
            if kind not in ('$mem', '$mem_v2'):
                continue
            p = cell['parameters']
            number = lambda key: int(p[key], 2)
            writes = number('WR_PORTS')
            defined_init = bool(set(p.get('INIT', '')) & {'0', '1'})
            if writes and defined_init:
                initialized.append(full)
            for key in ('RD_INIT_VALUE',):
                if set(p.get(key, '')) & {'0', '1'}:
                    initialized.append(full + '.' + key)
            category, contract = classify(original, name, writes)
            source = cell.get('attributes', {}).get('src', '')
            # Yosys assigns $auto$proc_rom sequence numbers globally, so an
            # unrelated RTL edit otherwise churns every constant-table row.
            # Instance path plus source span is unique here and stable across
            # elaborations. Include a content digest because one source span
            # may lower to multiple tables; these are not externally named
            # memories.
            if category == 'constant_logic':
                digest = hashlib.sha256(p.get('INIT', '').encode()).hexdigest()[:12]
                base = 'constant_lookup@' + source + '#' + digest
                key = path + '.' + base
                occurrence = constant_seen.get(key, 0)
                constant_seen[key] = occurrence + 1
                name = base + f'[{occurrence}]'
                full = path + '.' + name
            rows.append(dict(path=full, module=original, array=name,
                             width_bits=number('WIDTH'), depth=number('SIZE'),
                             total_bits=number('WIDTH') * number('SIZE'),
                             category=category, contract=contract,
                             raw_read_accesses=number('RD_PORTS'),
                             raw_write_accesses=writes,
                             raw_read_clock_mask=p['RD_CLK_ENABLE'],
                             init='constant lookup' if defined_init else 'unspecified',
                             source=source))

    walk('karu64', 'karu64')
    if initialized:
        raise SystemExit('FAIL: initialized state: ' + ', '.join(initialized))
    return sorted(rows, key=lambda row: row['path'])


def report(out):
    # Check BEFORE proc/optimization, so an initializer cannot disappear and
    # accidentally pass the post-process state check below.
    rtlil = (out / 'elaborated.il').read_text()
    if re.search(r'\bsync init\b|\bcell \$meminit|attribute \\init\s', rtlil):
        raise SystemExit('FAIL: initial state found in elaborated.il')
    rows = inventory(json.loads((out / 'memories.json').read_text()))
    with (out / 'memories.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)
    summary = ['# ASIC memory inventory', '',
               'Generated by `python3 flow/asic/audit.py`. Top: `karu64`.',
               'See `flow/asic/README.md` for port timing, masks and macro suitability.',
               'Paths use elaborated RTL instance names; mapping may rename them.', '']
    for category in ('macro_candidate', 'register_file', 'scratch_refactor',
                     'control_flops', 'constant_logic'):
        group = [r for r in rows if r['category'] == category]
        summary += [f'## {category} ({len(group)} arrays)', '',
                    '| Hierarchical path | Width × depth | Contract |',
                    '| --- | ---: | --- |']
        summary += [f"| `{r['path']}` | {r['width_bits']} × {r['depth']} | {r['contract']} |"
                    for r in group]
        summary += ['']
    summary += ['No initial processes, memory initialization cells or initialized nets',
                'remain in the elaborated ASIC design. Constant lookup tables generated',
                'from combinational case statements are listed separately.', '']
    (out / 'memories.md').write_text('\n'.join(summary))
    counts = {c: sum(r['category'] == c for r in rows)
              for c in sorted({r['category'] for r in rows})}
    result = dict(top='karu64', initialized_state=0, categories=counts,
                  data_array_bits=sum(r['total_bits'] for r in rows
                                      if r['category'] in ('macro_candidate', 'register_file', 'scratch_refactor')))
    (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / '_build/asic-audit')
    parser.add_argument('--report-only', action='store_true', help='reparse existing elaboration output')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    files = entries(HERE / 'karu64.f')
    defines = entries(HERE / 'rva23s64.defines')
    if not args.report_only:
        # File/define manifests contain only plain tokens, never shell commands.
        for token in files + defines:
            if not re.fullmatch(r'[A-Za-z0-9_./=+-]+', token):
                raise SystemExit('Invalid manifest token: ' + token)
        script = ('read_verilog -defer -Irtl ' + ' '.join('-D' + d for d in defines)
                  + ' ' + ' '.join(files) + '\nhierarchy -check -top karu64\n'
                  + f'write_rtlil "{out}/elaborated.il"\n'
                  + 'proc\nopt_clean\nmemory_collect\n'
                  + f'write_json "{out}/memories.json"\n')
        (out / 'audit.ys').write_text(script)
        sources = [ROOT / f for f in files] + sorted((ROOT / 'rtl').glob('*.vh'))
        sources += [HERE / 'karu64.f', HERE / 'rva23s64.defines', Path(__file__).resolve()]
        provenance = dict(defines=defines, sources=files,
                          yosys=subprocess.check_output(['yosys', '-V'], text=True).strip(),
                          sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sources})
        (out / 'manifest.json').write_text(json.dumps(provenance, indent=2) + '\n')
        with (out / 'yosys.log').open('w') as log:
            subprocess.run(['yosys', '-Q', '-T', '-s', str(out / 'audit.ys')], cwd=ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    report(out)


if __name__ == '__main__':
    main()
