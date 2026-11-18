#!/usr/bin/env python3
"""Run the same precise address-trigger scenario on Spike via real OpenOCD."""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--spike',default='spike')
parser.add_argument('--openocd',default='openocd')
parser.add_argument('--elf',required=True)
parser.add_argument('--out',default='_build/dbg/spike-triggers')
parser.add_argument('--timeout',type=int,default=60)
args=parser.parse_args()
out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
spike=Path(shutil.which(args.spike) or args.spike).resolve()
# The ELF's read-only header segment precedes .text at0x80000000; the
# trigger scenario itself accesses the usual0x80000000 DRAM addresses.
command=[str(spike),'--halted','--rbb-port=0','--triggers=2','--isa=rv64gcv','-m0x7fff0000:0x08010000',args.elf]
started=time.monotonic()
with (out/'spike.log').open('w') as log:
    process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
    try:
        port=None
        while time.monotonic()-started<10:
            text=(out/'spike.log').read_text()
            match=re.search(r'Listening for remote bitbang connection on port (\d+)',text)
            if match:
                port=match.group(1);break
            if process.poll() is not None:raise RuntimeError('Spike exited before listening: '+text)
            time.sleep(.05)
        if port is None:raise RuntimeError('Spike remote_bitbang startup timeout')
        env=dict(os.environ,KARUDBG_RBB_PORT=port,KARUDBG_IDCODE='0xdeadbeef')
        with (out/'openocd.log').open('w') as openocd_log:
            result=subprocess.run([args.openocd,'-f','test/dbg/openocd_spike_triggers.cfg'],
                                  env=env,stdout=openocd_log,stderr=subprocess.STDOUT,
                                  timeout=args.timeout)
        text=(out/'openocd.log').read_text()
        if result.returncode or 'PASS Spike address-trigger oracle' not in text:
            raise RuntimeError('Spike trigger comparison failed; see '+str(out/'openocd.log'))
        (out/'reference.json').write_text(json.dumps({
            'command':command,'spike_sha256':hashlib.sha256(spike.read_bytes()).hexdigest(),
            'openocd_version':subprocess.check_output([args.openocd,'--version'],stderr=subprocess.STDOUT,text=True).strip(),
            'elapsed_seconds':round(time.monotonic()-started,3),'result':'pass'},indent=2)+'\n')
        print('PASS Spike address-trigger oracle; logs: '+str(out))
    finally:
        # Spike keeps serving remote_bitbang after OpenOCD disconnects. Stop
        # this isolated test process explicitly; it is not an ELF-exit verdict.
        if process.poll() is None:process.terminate()
        try:process.wait(timeout=3)
        except subprocess.TimeoutExpired:process.kill();process.wait()
