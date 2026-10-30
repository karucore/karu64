#!/usr/bin/env python3
"""Exercise INV40 with independently driven legal and corrupted observations."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import json
from pathlib import Path
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary',required=True)
parser.add_argument('--out',default='_build/dbg/inv40')
args=parser.parse_args()
out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
expected={1:'INV40a',2:'INV40b',3:'INV40c',4:'INV40g',5:'INV40l',
          6:'INV40q',7:'INV40m',8:'INV40s',9:'INV40h',10:'INV40k',
          11:'INV40i',12:'INV40u',13:'INV40e',14:'INV40d',15:'INV40s'}
results=[]
for fault in range(16):
    result=subprocess.run(['vvp',args.binary,f'+fault={fault}'],stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT,text=True,timeout=5)
    (out/f'case-{fault:02d}.log').write_text(result.stdout)
    if fault==0:
        if result.returncode or 'karudbg INV40 driven positive: PASS' not in result.stdout:
            raise RuntimeError('INV40 legal sequence failed: '+result.stdout)
        print('PASS INV40 independent legal sequences',flush=True)
    else:
        if not result.returncode or expected[fault] not in result.stdout:
            raise RuntimeError(f'INV40 fault{fault} missed{expected[fault]}: '+result.stdout)
        print(f'PASS INV40 negative{fault}: {expected[fault]}',flush=True)
    results.append({'case':fault,'expected':expected.get(fault,'positive'),'pass':True})
(out/'results.json').write_text(json.dumps({'positive':1,'negative':15,'results':results},indent=2)+'\n')
