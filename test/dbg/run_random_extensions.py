#!/usr/bin/env python3
"""Reuse one ASIC debug-extension simulator across six bounded random resets.

The model must be built with KARU_ASIC, --x-initial unique, --x-assign unique
and TEST_EXTENSION_PROBE. This is randomized two-state startup coverage;
four-state checks remain a separate gate.
SPDX-License-Identifier: BSD-3-Clause
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
from run_validation import input_hashes


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model',required=True)
    parser.add_argument('--out',default='_build/dbg/asic-random')
    args=parser.parse_args();out=Path(args.out).resolve();out.mkdir(parents=True,exist_ok=True)
    model=Path(args.model).resolve();before=input_hashes();rows=[]
    for seed in [1,2,7,19,42,1234567]:
        command=[str(model),f'+verilator+seed+{seed}','+verilator+rand+reset+2']
        started=time.monotonic()
        result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
        (out/f'seed-{seed}.log').write_text(result.stdout)
        passed=result.returncode==0 and 'karudbg focused extension probe: PASS' in result.stdout
        rows.append(dict(seed=seed,command=command,seconds=round(time.monotonic()-started,3),passed=passed))
        (out/'results.json').write_text(json.dumps(dict(rows=rows,passed=False),indent=2)+'\n')
        if not passed:raise RuntimeError(f'random ASIC extensions failed seed {seed}; see {out}/seed-{seed}.log')
        print(f'PASS ASIC random extensions seed {seed} ({rows[-1]["seconds"]}s)',flush=True)
    after=input_hashes()
    record=dict(passed=before==after,source_integrity=before==after,rows=rows,
                model_sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
                inputs_before=before,inputs_after=after)
    (out/'results.json').write_text(json.dumps(record,indent=2)+'\n')
    if before!=after:raise RuntimeError('sources changed during random extension tests')
    print('karudbg ASIC random extensions: PASS (6 seeds)')
if __name__=='__main__':main()
