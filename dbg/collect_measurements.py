#!/usr/bin/env python3
"""Collect completed, current karudbg NanGate45 area/OpenSTA measurements.

The collector never starts synthesis. Missing/in-progress rows remain pending;
stale or inconsistent evidence cannot supply metrics or incremental costs.
SPDX-License-Identifier: BSD-3-Clause
"""
import argparse
import csv
import datetime
import hashlib
import io
import importlib.util
import json
import math
from pathlib import Path
import re
import shlex
import sys

REPO=Path(__file__).resolve().parents[1]
ROWS=('base','autoexec','triggers','sba','full','full4')
FEATURES={'base':set(),'autoexec':{'KARU_DBG_AUTOEXEC'},'triggers':{'KARU_DBG_TRIGGERS'},
          'sba':{'KARU_DBG_SBA'},'full':{'KARU_DBG_FULL'},
          'full4':{'KARU_DBG_FULL','KARU_DBG_TRIGGER_COUNT=4'}}
GROUPS=('reg2reg','in2reg','reg2out','in2out')
# Only these captured synthesis sources may use the reviewed inactive-feature proof.
PROVABLE_SOURCES={str(REPO/'rtl/karu64.v'),str(REPO/'rtl/karu_vlsu.v')}
FEATURE_NAMES={'KARU_DBG_AUTOEXEC','KARU_DBG_TRIGGERS','KARU_DBG_SBA','KARU_DBG_FULL','KARU_DBG_TRIGGER_COUNT'}
HASH_LINE=re.compile(r'^([0-9a-f]{64})\s+\*?(.+)$')
NUMBER=r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?'


def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
    return digest.hexdigest()


def hashes(text,strict=False):
    result={}
    for line in text.splitlines():
        match=HASH_LINE.fullmatch(line)
        if not match:
            if strict and line.strip():raise ValueError('malformed SHA-256 input record')
            continue
        value,name=match.groups()
        if name in result and result[name]!=value:raise ValueError('conflicting input hashes: '+name)
        result[name]=value
    if strict and not result:raise ValueError('empty input fingerprint')
    return result


def area_um2(text,top):
    matches=re.findall(r"Chip area for top module '\\?"+re.escape(top)+r"':\s*("+NUMBER+r')',text)
    if len(matches)!=1:raise ValueError('expected one top Chip area for '+top)
    value=float(matches[0])
    if not math.isfinite(value) or value<=0:raise ValueError('non-positive/non-finite top area')
    if re.search(r'Area for cell type .+ is unknown',text):raise ValueError('unmapped/unknown cell area')
    return value


def timing_group(text):
    paths=[]
    for row in csv.reader(io.StringIO(text)):
        if not row:continue
        if len(row)!=3:raise ValueError('timing CSV requires startpoint,endpoint,slack')
        start,end,value=row
        slack=float(value)
        if not math.isfinite(slack):raise ValueError('non-finite timing slack')
        paths.append(dict(startpoint=start,endpoint=end,slack_ns=slack))
    paths.sort(key=lambda path:path['slack_ns'])
    return dict(minimum_slack_ns=paths[0]['slack_ns'] if paths else None,
                reported_paths=len(paths),worst_path=paths[0] if paths else None)


def timing_summary(text):
    result={}
    for key,label in [('worst_slack_ns',r'worst\s+slack'),('tns_ns','tns')]:
        matches=re.findall(r'^\s*'+label+r'(?:\s+max)?\s+('+NUMBER+r')\s*$',text,re.M|re.I)
        if len(matches)!=1:raise ValueError('missing/ambiguous OpenSTA '+label)
        result[key]=float(matches[0])
        if not math.isfinite(result[key]):raise ValueError('non-finite OpenSTA summary')
    return result


def verify_equivalence(directory,changed_paths):
    """Recheck token identity and, where needed, AUTOEXEC=0 sequential equivalence."""
    path=REPO/'dbg/source_equivalence.py'
    if not path.is_file():raise ValueError('source-equivalence verifier is unavailable')
    spec=importlib.util.spec_from_file_location('karudbg_source_equivalence',path)
    module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module
    spec.loader.exec_module(module)
    return module.verify_row_proof(directory,changed_paths)


def collect_row(root,name,kind):
    directory=root/(kind+'_'+name)
    result=dict(state='pending',directory=str(directory),reasons=[])
    before=directory/'log/inputs.before.sha256';after=directory/'log/inputs.after.sha256'
    manifest=directory/'log/manifest.txt';synlog=directory/'log/syn.log';area=directory/'reports/area.rpt'
    reports=[area]
    if kind=='timing':reports += [directory/'reports/timing/summary.rpt',
                                *(directory/f'reports/timing/{group}.csv.rpt' for group in GROUPS),directory/'log/sta.log']
    required=[before,after,manifest,synlog,*reports]
    missing=[str(path.relative_to(directory)) for path in required if not path.is_file()]
    if missing:result['reasons']=['missing completion/evidence: '+', '.join(missing)];return result
    if after.stat().st_mtime_ns<before.stat().st_mtime_ns:
        result['reasons']=['new run has no final input fingerprint'];return result
    if any(path.stat().st_mtime_ns<before.stat().st_mtime_ns for path in [manifest,synlog,*reports]):
        result['reasons']=['report/manifest predates this run'];return result
    if any(path.stat().st_mtime_ns>after.stat().st_mtime_ns for path in [manifest,synlog,*reports]):
        result['reasons']=['report/manifest is newer than final input fingerprint'];return result
    try:
        result['evidence_sha256']={str(path.relative_to(directory)):sha(path) for path in [before,after,manifest,*reports]}
        raw_equal=before.read_bytes()==after.read_bytes()
        inputs=hashes(before.read_text(),strict=True);final_inputs=hashes(after.read_text(),strict=True)
        if set(inputs)!=set(final_inputs):raise ValueError('before/after input set changed')
        run_changes={path for path in inputs if inputs[path]!=final_inputs[path]}
        metadata=manifest.read_text();recorded=hashes(metadata)
        if any(recorded.get(path)!=value for path,value in inputs.items()):
            raise ValueError('manifest and input fingerprint disagree')
        config=dict(re.findall(r'^(KARU_\w+)=([^\n]*)$',metadata,re.M))
        top=config.get('KARU_TOP')
        if top!='karudbg_top':raise ValueError('unexpected top: '+str(top))
        defines=set(shlex.split(config.get('KARU_DEFINES','')))
        extensions={word for word in defines if word.split('=',1)[0] in FEATURE_NAMES}
        if 'KARU_DBG' not in defines or extensions!=FEATURES[name]:raise ValueError('wrong feature defines for '+name)
        if config.get('KARU_CLK_PS')!='5000':raise ValueError('row is not the 200 MHz comparison')
        if kind=='timing' and config.get('KARU_NO_STA') not in ('0',''):raise ValueError('OpenSTA disabled in timing row')
        tools={}
        for tool in ['YOSYS','YOSYS_ABC']+(['OPENSTA'] if kind=='timing' else []):
            match=re.search(r'^'+tool+r'_EXECUTABLE=(.+)$',metadata,re.M)
            if not match or match[1] not in recorded:raise ValueError('missing recorded binary hash: '+tool)
            tools[tool]=dict(path=match[1],sha256=recorded[match[1]])
        liberty_match=re.search(r'Executing Liberty frontend:\s*([^\n]+)',synlog.read_text())
        if not liberty_match or liberty_match[1] not in inputs:raise ValueError('missing fingerprinted mapping Liberty')
        liberty=Path(liberty_match[1]);all_inputs=dict(inputs)
        all_inputs.update({item['path']:item['sha256'] for item in tools.values()})
        changed=[]
        for path,value in all_inputs.items():
            file=Path(path)
            if not file.is_file() or sha(file)!=value:changed.append(path)
        result['provenance']=dict(config=config,input_hashes=inputs,tools=tools,
                                  liberty=dict(path=str(liberty),sha256=inputs[str(liberty)]),
                                  manifest_sha256=sha(manifest),fingerprint_sha256=sha(before))
        needs_proof=set(changed)|run_changes
        if needs_proof:
            proof=directory/'log/source-equivalence.json'
            dm_source=str(REPO/'dbg/karudbg.v')
            # A trigger row may reuse only a DM-only AUTOEXEC=0 proof. Its
            # active VLSU must match the mapped sources exactly.
            allowed=({dm_source} if name=='triggers' else PROVABLE_SOURCES |
                     ({dm_source} if name in ('base','sba') else set()))
            eligible=name in ('base','autoexec','sba','triggers') and needs_proof<=allowed
            if eligible and proof.is_file():
                approved=verify_equivalence(directory,needs_proof)
                if set(approved)!=needs_proof:raise ValueError('equivalence proof does not cover exactly the changed sources')
                for path,value in approved.items():
                    if sha(Path(path))!=value:raise ValueError('equivalence result is not the current source: '+path)
                    if final_inputs[path] not in (inputs[path],value):raise ValueError('unproved intermediate source: '+path)
                result['provenance']['effective_input_hashes']={**inputs,**approved}
                result['source_equivalence']=dict(path=str(proof),sha256=sha(proof),
                    approved_sources=approved,raw_fingerprints_identical=raw_equal,
                    methods={path:('Yosys AUTOEXEC=0 sequential equivalence' if path==str(REPO/'dbg/karudbg.v')
                                   else 'exact preprocessed tokens') for path in approved})
                result['evidence_sha256']['log/source-equivalence.json']=sha(proof)
            elif changed:
                result.update(state='stale',reasons=['current input/tool/library differs: '+path for path in changed])
                return result
            else:raise ValueError('before/after fingerprints differ without an applicable source-equivalence proof')
        elif not raw_equal:raise ValueError('before/after fingerprint text differs')
        reference=re.search(r'\bcell\s*\(\s*"?NAND2_X1"?\s*\)\s*\{[^}]*?\barea\s*:\s*('+NUMBER+r')\s*;',liberty.read_text(),re.S)
        if not reference or not math.isclose(float(reference[1]),0.798,abs_tol=1e-9):
            raise ValueError('kGE normalization requires NAND2_X1 area 0.798 um2')
        metrics=dict(area_um2=area_um2(area.read_text(),top))
        metrics['area_kGE']=metrics['area_um2']/798.0
        if kind=='timing':
            stal=directory/'log/sta.log'
            if not stal.is_file():raise ValueError('missing OpenSTA log')
            if re.search(r'^\s*Error:|^\s*error:',stal.read_text(),re.M):raise ValueError('OpenSTA log contains errors')
            result['evidence_sha256']['log/sta.log']=sha(stal)
            metrics.update(timing_summary((directory/'reports/timing/summary.rpt').read_text()))
            metrics['groups']={group:timing_group((directory/f'reports/timing/{group}.csv.rpt').read_text()) for group in GROUPS}
        result.update(state='complete',reasons=[],metrics=metrics)
    except (ValueError,RuntimeError,OSError) as error:
        result.update(state='invalid',reasons=[str(error)])
    return result


def signature(row):
    provenance=row['provenance'];config=dict(provenance['config'])
    config['KARU_DEFINES']=' '.join(sorted(word for word in shlex.split(config['KARU_DEFINES'])
                                        if word.split('=',1)[0] not in FEATURE_NAMES))
    return dict(config=config,inputs=provenance.get('effective_input_hashes',provenance['input_hashes']),tools=provenance['tools'])


def deltas(rows):
    for kind in ('area','timing'):
        base=rows['base'][kind]
        for name in ROWS:
            row=rows[name][kind]
            row.pop('comparison_to_base',None)
            for key in ('delta_kGE','delta_percent'):row.get('metrics',{}).pop(key,None)
            if row['state']!='complete' or base['state']!='complete':continue
            if signature(row)!=signature(base):
                row['comparison_to_base']=dict(compatible=False,reason='different source/tool/library or mapping/constraint configuration')
                continue
            metrics=row['metrics'];base_metrics=base['metrics']
            metrics['delta_kGE']=metrics['area_kGE']-base_metrics['area_kGE']
            metrics['delta_percent']=100.0*metrics['delta_kGE']/base_metrics['area_kGE']
            row['comparison_to_base']=dict(compatible=True,configuration='base')


def markdown(record):
    lines=['# karudbg area and timing matrix','',
           'Completed rows require current tools, Liberty and flow inputs; captured inactive-feature RTL differences require a rechecked token-identity or AUTOEXEC=0 sequential-equivalence proof.',
           'NanGate45 normalization: NAND2_X1 = 0.798 um²; kGE = area / 798.',
           'Area and timing use separate mapping recipes. Timing is at 200 MHz; positive slack means margin.',
           'TNS comes from the complete OpenSTA summary, rather than the limited path CSVs.','',
           '| Configuration | Area kGE | Delta kGE | Delta % | Area status | Reg2reg slack ns | TNS ns | Timing status |',
           '| --- | ---: | ---: | ---: | --- | ---: | ---: | --- |']
    def value(metrics,key):return f'{metrics[key]:.4f}' if metrics.get(key) is not None else '—'
    for name,row in record['rows'].items():
        area=row['area'];timing=row['timing'];a=area.get('metrics',{});t=timing.get('metrics',{})
        slack=t.get('groups',{}).get('reg2reg',{}).get('minimum_slack_ns')
        lines.append(f'| {name} | {value(a,"area_kGE")} | {value(a,"delta_kGE")} | {value(a,"delta_percent")} | {area["state"]} | {"—" if slack is None else f"{slack:.4f}"} | {value(t,"tns_ns")} | {timing["state"]} |')
    lines+=['','| Configuration | Reg2reg | Input→register | Register→output | Input→output |','| --- | ---: | ---: | ---: | ---: |']
    for name,row in record['rows'].items():
        groups=row['timing'].get('metrics',{}).get('groups',{})
        lines.append('| '+name+' | '+' | '.join(value(groups.get(group,{}),'minimum_slack_ns') for group in GROUPS)+' |')
    for name,row in record['rows'].items():
        for kind,measurement in row.items():
            for reason in measurement.get('reasons',[]):lines+=['',f'- {name}/{kind}: {reason}']
            reuse=measurement.get('source_equivalence')
            if reuse:
                sources='; '.join(Path(path).name+': '+reuse.get('methods',{}).get(path,'exact preprocessed tokens') for path in sorted(reuse['approved_sources']))
                lines+=['',f'- {name}/{kind}: mapped artifacts retained using independently rechecked proofs ({sources}); raw fingerprints retained in provenance.']
            comparison=measurement.get('comparison_to_base',{})
            if comparison.get('compatible') is False:lines+=['',f'- {name}/{kind}: delta withheld: {comparison["reason"]}']
    lines+=['','Per-row report hashes, input fingerprints, tool/library identity and worst-path endpoints are in `measurements.json`.','']
    return '\n'.join(lines)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',default='_build/syn_out/karudbg')
    parser.add_argument('--out',help='output directory under this repository _build (default ROOT/measurements)')
    args=parser.parse_args();root=Path(args.root).resolve();out=Path(args.out).resolve() if args.out else root/'measurements'
    if not out.is_relative_to((REPO/'_build').resolve()):raise SystemExit('reports must remain under repository _build')
    rows={name:{kind:collect_row(root,name,kind) for kind in ('area','timing')} for name in ROWS}
    deltas(rows)
    record=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),root=str(root),
                collector_sha256=sha(Path(__file__).resolve()),normalization=dict(reference_cell='NAND2_X1',reference_um2=.798,um2_per_kGE=798),rows=rows)
    out.mkdir(parents=True,exist_ok=True)
    (out/'measurements.json').write_text(json.dumps(record,indent=2)+'\n')
    (out/'measurements.md').write_text(markdown(record))
    print('Measurement summary:',out/'measurements.md')
    for name,row in rows.items():print(name+': '+', '.join(kind+'='+data['state'] for kind,data in row.items()))
if __name__=='__main__':main()
