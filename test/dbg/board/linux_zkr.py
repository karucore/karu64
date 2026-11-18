# Zkr as Linux sees it (image built with KARU_ZKR, the rva23s64-zkr-ddr tree).
#
# Needs Linux reachable over SSH; no OpenOCD. It checks discovery, not
# entropy:
#
#   device tree   the tree Linux booted with lists "zkr"
#   kernel        /proc/cpuinfo lists zkr for the hart, so the kernel
#                 accepted it and arch_get_random_seed_longs() will use seed
#   no failure    the kernel log has no archrandom error (a DEAD source)
#
# With DIP switch 4 on (entropy source off) all three still hold: seed then
# reports BIST and the kernel falls back without a message. Whether seed
# delivered words cannot be seen from Linux; that is what the GetNoise
# capture and the boot simulation are for.
#
# KARU_BOARD_ZKR=0 is for a boot with the tree without zkr (the fallback):
# the script then requires that neither place lists it.
#
# New on 2026-11-17; passed on the board on 2026-11-18 with KARU_BOARD_ZKR=1.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import subprocess

EXPECT=setting('KARU_BOARD_ZKR','1')!='0'
results=[]

def isa_has(text,ext):
    """Whether an ISA description lists ext: a /proc/cpuinfo 'isa' string
    (rv64imafdc_zicsr_zkr_...) or a device-tree string list."""
    for line in text.replace('\0','\n').splitlines():
        line=line.split(':',1)[-1].strip().lower()
        if ext in [t for t in line.replace(',','_').split('_') if t]: return True
    return False

def ssh(command,timeout=60):
    return subprocess.run(SSH+[command],capture_output=True,text=True,timeout=timeout)

def record(name,ok,detail):
    results.append(dict(name=name,status='PASS' if ok else 'FAIL',detail=detail))
    print(json.dumps(results[-1]),flush=True)
    (OUT/'linux-zkr-results.json').write_text(json.dumps(results,indent=2)+'\n')
    return ok

def main():
    dt=ssh("tr '\\0' '\\n' < /proc/device-tree/cpus/cpu@0/riscv,isa-extensions")
    if dt.returncode: record('device tree',False,'cannot read the ISA list: '+dt.stderr.strip())
    else: record('device tree',isa_has(dt.stdout,'zkr')==EXPECT,
                 dict(zkr=isa_has(dt.stdout,'zkr'),expected=EXPECT))
    cpu=ssh("grep -m1 '^isa' /proc/cpuinfo")
    if cpu.returncode: record('kernel',False,'no isa line in /proc/cpuinfo')
    else: record('kernel',isa_has(cpu.stdout,'zkr')==EXPECT,
                 dict(zkr=isa_has(cpu.stdout,'zkr'),expected=EXPECT,isa=cpu.stdout.strip()[-160:]))
    log=ssh("dmesg | grep -i archrandom || true")
    record('no failure',log.returncode==0 and 'Unrecoverable' not in log.stdout,
           log.stdout.strip() or 'no archrandom message')
    failed=[r['name'] for r in results if r['status']!='PASS']
    print(json.dumps(dict(phase='linux-zkr',cases=len(results),failed=failed,zkr_expected=EXPECT)),flush=True)
    return 1 if failed else 0

if __name__=='__main__': sys.exit(main())
