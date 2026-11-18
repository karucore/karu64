# Attach to running Linux: discovery, full GPR/CSR context round trip,
# halt/resume stress. Leaves Linux running.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import random
b=Board('linux')
saved={}
def discovery():
    b.halt(); b.cmd('poll off'); b.cmd('riscv exec_progbuf 0x00000013')
    status=b.dmi(0x11)
    b.equal(status&0xff,0x83,'DM version/authenticated')
    b.require(status&0x300==0x300,'halted flags')
    b.equal(b.dmi(0x16)&0xf,2,'datacount')
    b.equal((b.dmi(0x16)>>24)&0x1f,8,'progbuf size')
    b.equal(b.dmi(0x12),0x200000,'hartinfo')
    b.equal((b.dmi(0x38)>>5)&0x7f,32,'SBA address width')
    b.equal(b.dmi(0x38)&0x1f,15,'SBA widths')
    for a in [0x14,0x15,0x19,0x1a,0x1b,0x1c,0x1d,0x1f]: b.equal(b.dmi(a),0,f'absent DMI {a:#x}')
    b.equal(b.dmi(0x13),1,'haltsum1'); b.equal(b.dmi(0x40),1,'haltsum0')
    for i in range(32): saved[0x1000+i]=b.rawread(0x1000+i)
    for reg in [0x300,0x305,0x340,0x341,0x342,0x343,0x180,0x105,0x141,0x142,0x143,0x600,0x680,0x7b0,0x7b1]: saved[reg]=b.rawread(reg)
    (OUT/'linux-context-before.json').write_text(json.dumps({hex(k):hex(v) for k,v in saved.items()},indent=2))
    return {'dmstatus':hex(status),'dpc':hex(saved[0x7b1]),'dcsr':hex(saved[0x7b0])}
def gprs():
    rng=random.Random(0x20261116)
    try:
        for pattern in [0,0xffffffffffffffff,0xaaaaaaaaaaaaaaaa,0x5555555555555555]+[rng.getrandbits(64) for _ in range(12)]:
            for n in range(1,32): b.rawwrite(0x1000+n,(pattern+n)&0xffffffffffffffff)
            for n in range(1,32): b.equal(b.rawread(0x1000+n),(pattern+n)&0xffffffffffffffff,f'x{n} pattern {pattern:#x}')
            b.rawwrite(0x1000,0xffffffffffffffff); b.equal(b.rawread(0x1000),0,'x0 hardwired')
        b.rawwrite(0x340,0xa5a55a5a01234567)
        b.equal(b.rawread(0x340),0xa5a55a5a01234567,'mscratch write/read')
    finally:
        for r,v in saved.items():
            if 0x1000<=r<=0x101f or r==0x340: b.rawwrite(r,v)
    for r,v in saved.items(): b.equal(b.rawread(r),v,f'preserved {r:#x}')
def stress():
    b.cmd('poll on')
    b.resume()
    for i in range(100):
        b.halt(); b.require(b.rr('pc')!=0,'halt PC nonzero'); b.resume()
    b.halt(); b.cmd('poll off')
    b.require(b.rawread(0x7b1)!=0,'post-stress PC valid')
    b.cmd('poll on'); b.resume()
if b.case('Linux discovery and complete context snapshot',discovery): b.case('All 32 GPRs, mscratch, preservation across 16 patterns',gprs)
def cleanup():
    b.clear(); b.cmd('poll on')
    if b.cmd('karu.cpu curstate')=='halted': b.resume()
status=1
try:
    b.case('100 Linux halt/resume cycles',stress)
finally:
    status=b.finish(cleanup)
sys.exit(status)
