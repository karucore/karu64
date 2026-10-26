#!/usr/bin/env python3
"""Elaborate an ASIC manifest, inventory arrays, reject power-up state.

Run from any directory. No technology mapping or memory latency conversion is
performed. Raw Yosys memory ports count access sites, not physical macro ports.
Defaults retain the core-only manifest. Reports are written only under --out;
an opt-in combined debug audit does not replace the tracked core inventory.
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
            if (s := line.split('//', 1)[0].split('#', 1)[0].strip())]


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
        return 'register_file', '1W2R; asynchronous reads; full-word write'
    if module == 'karu_vlsu_buf':
        return 'scratch_refactor', 'combinational multi-access scratch; flop logic or banked redesign; see README'
    return 'control_flops', 'parallel control/state array; retain flip-flops; see README'


def compiler_mapping(row):
    """Trial compiler: 1RW/2RW ports, registered reads, RAM depth >= 32.

    This is implementation guidance, not a claim that the RTL was retimed or
    that a particular macro (including byte enables) has been generated.
    """
    module = row['module']
    if module == 'karu_tdp_be_ram':
        return '2RW candidate; verify byte enables and read-output hold'
    if module == 'karu_1w1r_async_ram':
        note = '2RW for simultaneous read + write; registered-read RTL redesign'
        if row['depth'] < 32:
            note += '; pad RAM depth to 32 or keep flop logic'
        return note
    if module in ('karu_1w2r_async_ram', 'karu_regfile', 'karu_fregfile'):
        return ('No direct 1/2RW fit; use flop logic or two replicated 2RW '
                'macros with broadcast writes and registered-read RTL redesign')
    if module == 'karu_vlsu_buf':
        note = 'No direct fit; flop logic or banked/replicated 1/2RW scratchpad redesign'
        if row['depth'] < 32:
            note += '; pad RAM depth to 32'
        return note
    raise ValueError(f'No compiler mapping for {module}')


def inventory(design, top='karu64'):
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

    walk(top, top)
    if initialized:
        raise SystemExit('FAIL: initialized state: ' + ', '.join(initialized))
    return sorted(rows, key=lambda row: row['path'])


def report(out, top='karu64'):
    # Check BEFORE proc/optimization, so an initializer cannot disappear and
    # accidentally pass the post-process state check below.
    rtlil = (out / 'elaborated.il').read_text()
    if re.search(r'\bsync init\b|\bcell \$meminit|attribute \\init\s', rtlil):
        raise SystemExit('FAIL: initial state found in elaborated.il')
    rows = inventory(json.loads((out / 'memories.json').read_text()), top)
    with (out / 'memories.csv').open('w', newline='') as f:
        fields = list(rows[0]) if rows else [
            'path', 'module', 'array', 'width_bits', 'depth', 'total_bits',
            'category', 'contract', 'raw_read_accesses', 'raw_write_accesses',
            'raw_read_clock_mask', 'init', 'source']
        writer = csv.DictWriter(f, fieldnames=fields, lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)
    summary = ['# ASIC memory inventory', '',
               f'Generated by `python3 flow/asic/audit.py`. Top: `{top}`.',
               'See `flow/asic/README.md` for port timing, masks and macro suitability.',
               'Paths use elaborated RTL instance names; mapping may rename them.',
               'The contract column describes the **current RTL**. For this trial, the',
               'available compiler has synchronous reads and either 1 or 2 **RW** ports;',
               'RAM depth is at least 32 words. The mapping column is guidance for that',
               'compiler, not a drop-in replacement or a generated macro list.', '']
    for category in ('macro_candidate', 'register_file', 'scratch_refactor',
                     'control_flops', 'constant_logic'):
        group = [r for r in rows if r['category'] == category]
        summary += [f'## {category} ({len(group)} arrays)', '']
        if category in ('macro_candidate', 'register_file', 'scratch_refactor'):
            summary += ['| Hierarchical path | Width × depth | Current RTL contract | 1/2RW compiler mapping |',
                        '| --- | ---: | --- | --- |']
            summary += [f"| `{r['path']}` | {r['width_bits']} × {r['depth']} | "
                        f"{r['contract']} | {compiler_mapping(r)} |" for r in group]
        else:
            summary += ['| Hierarchical path | Width × depth | Current RTL contract |',
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
    result = dict(top=top, initialized_state=0, categories=counts,
                  data_array_bits=sum(r['total_bits'] for r in rows
                                      if r['category'] in ('macro_candidate', 'register_file', 'scratch_refactor')))
    (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / '_build/asic-audit')
    parser.add_argument('--report-only', action='store_true', help='reparse existing elaboration output')
    parser.add_argument('--manifest', type=Path, default=HERE / 'karu64.f',
                        help='plain source manifest; source paths are relative to the repository root')
    parser.add_argument('--top', help='elaboration top (default karu64; report-only uses the recorded top)')
    parser.add_argument('--define', action='append', default=[],
                        help='additional Verilog define, repeatable; standard ASIC profile defines remain enabled')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    manifest = args.manifest.resolve()
    files = entries(manifest)
    defines = entries(HERE / 'rva23s64.defines') + args.define
    top = args.top or 'karu64'
    if args.report_only and args.top is None and (out / 'manifest.json').is_file():
        top = json.loads((out / 'manifest.json').read_text()).get('top', 'karu64')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', top):
        raise SystemExit('Invalid top module: ' + top)
    if not args.report_only:
        # File/define manifests contain only plain tokens, never shell commands.
        for token in files + defines:
            if not re.fullmatch(r'[A-Za-z0-9_./=+-]+', token):
                raise SystemExit('Invalid manifest token: ' + token)
        script = ('read_verilog -defer -Irtl -Idbg ' + ' '.join('-D' + d for d in defines)
                  + ' ' + ' '.join(files) + f'\nhierarchy -check -top {top}\n'
                  + f'write_rtlil "{out}/elaborated.il"\n'
                  + 'proc\nopt_clean\nmemory_collect\n'
                  + f'write_json "{out}/memories.json"\n')
        (out / 'audit.ys').write_text(script)
        sources = [ROOT / f for f in files] + sorted((ROOT / 'rtl').glob('*.vh'))
        if 'KARU_DBG' in defines:
            sources += sorted((ROOT / 'dbg').glob('*.vh'))
        sources += [manifest, HERE / 'rva23s64.defines', Path(__file__).resolve()]
        def source_name(path):
            try:
                return str(path.relative_to(ROOT))
            except ValueError:
                return str(path)
        provenance = dict(top=top, defines=defines, sources=files,
                          yosys=subprocess.check_output(['yosys', '-V'], text=True).strip(),
                          sha256={source_name(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sources})
        (out / 'manifest.json').write_text(json.dumps(provenance, indent=2) + '\n')
        with (out / 'yosys.log').open('w') as log:
            subprocess.run(['yosys', '-Q', '-T', '-s', str(out / 'audit.ys')], cwd=ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        provenance['sha256_after'] = {
            source_name(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        (out / 'manifest.json').write_text(json.dumps(provenance, indent=2) + '\n')
        if provenance['sha256_after'] != provenance['sha256']:
            raise SystemExit('FAIL: audit inputs changed during elaboration')
    report(out, top)


if __name__ == '__main__':
    main()
