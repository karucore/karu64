# Watchpoints per privilege mode and under pointer masking, stepped MRET,
# vector restart widths, SBA address limit.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
bm.b.close();b=bm.b=Board('privilege');S=bm.SYMS;DATA=bm.DATA
PROBE=area('probe');VECTOR=area('vector')
def mark_halt():
    b.resume(S['_start']);b.halt()
def watch_modes():
    bm.prep();b.write(PROBE,32,[0x00c5a023,0x00100073],'sysbus')
    for mode in [3,1,0,0x21,0x20]:
        bm.prep();b.write(DATA,32,[0],'sysbus');b.rw('dcsr',0x3b400|mode)
        b.rw('a1',DATA);b.rw('a2',0x12345678);mark_halt()
        b.cmd(f'wp {DATA:#x} 4 w')
        try:
            b.cmd(f'resume {PROBE:#x}');b.cmd('wait_halt 5000')
            b.equal(b.rr('pc'),PROBE,'mode-specific watchpoint DPC')
            b.equal(b.rr('dcsr')&0x23,mode,'trigger saves privilege/virtualization')
            b.equal((b.rr('dcsr')>>6)&7,2,'data trigger cause')
            b.equal(b.read(DATA,32,method='sysbus')[0],0,'before-access store has no effect')
        finally: b.cmd(f'rwp {DATA:#x}')
        b.cmd('step');b.equal(b.read(DATA,32)[0],0x12345678,'store continuation once')
    bm.prep()
def pointer_mask():
    for pmm,bits,tag in [(2,7,0xfe00000000000000),(3,16,0xabcd000000000000)]:
        bm.prep();b.rw('menvcfg',pmm<<32)
        b.equal((b.rr('menvcfg')>>32)&3,pmm,'PMM supported')
        b.write(DATA,32,[0],'sysbus');b.rw('dcsr',0x3b401)
        b.rw('a1',tag|DATA);b.rw('a2',0x77665544);mark_halt()
        b.cmd(f'wp {DATA:#x} 4 w')
        try:
            b.cmd(f'resume {PROBE:#x}');b.cmd('wait_halt 5000')
            b.equal(b.rr('pc'),PROBE,'post-pointer-mask watchpoint DPC')
            b.equal((b.rr('dcsr')>>6)&7,2,'tagged access trigger cause')
            b.equal(b.read(DATA,32,method='sysbus')[0],0,'tagged store not performed yet')
        finally: b.cmd(f'rwp {DATA:#x}')
        b.cmd('step');b.equal(b.read(DATA,32)[0],0x77665544,'tagged store continuation')
    bm.prep();b.rw('menvcfg',0)
def mret_step():
    for prv,virt in [(1,0),(0,0),(1,1),(0,1)]:
        bm.prep();b.rw('mepc',S['return_case']);b.rw('mstatus',0x6600|(prv<<11)|(virt<<39))
        b.rw('a0',10);b.rw('pc',S['fret_case']);b.cmd('step')
        b.equal(b.rr('pc'),S['return_case'],'MRET step destination')
        b.equal(b.rr('dcsr')&0x23,prv|(virt<<5),'MRET step restores privilege/virtualization')
        b.equal((b.rr('dcsr')>>6)&7,4,'MRET step cause')
        b.cmd('step');b.equal(b.rr('a0'),11,'instruction after MRET executes once')
    bm.prep()
def vector_widths():
    for width in [8,16,32,64]:
        for store in [False,True]:
            bm.prep();n=256//width;idx=2;mask=(1<<width)-1
            b.rw('a0',n);bm.pb([0x00057057|({8:0,16:1,32:2,64:3}[width]<<23)])
            values=list(range(1,n+1));b.rw('v8',sum(v<<(width*i) for i,v in enumerate(values)) if store else (1<<256)-1)
            b.write(DATA,width,[0]*n if store else values,'sysbus')
            opcode=(0x0205e427 if store else 0x0205e407)&~(7<<12)
            opcode|={8:0,16:5,32:6,64:7}[width]<<12
            b.write(VECTOR,32,[opcode,0x00100073],'sysbus');b.rw('a1',DATA);b.cmd('riscv mem_access progbuf')
            b.resume(S['_start']);b.halt()
            address=DATA+idx*(width//8);b.cmd(f'wp {address:#x} {width//8} '+('w' if store else 'r'))
            try:
                b.cmd(f'resume {VECTOR:#x}');b.cmd('wait_halt 5000')
                b.equal(b.rr('pc'),VECTOR,'vector EEW watchpoint PC')
                b.equal(b.rr('vstart'),idx,'vector EEW restart index')
                b.equal((b.rr('dcsr')>>6)&7,2,'vector EEW debug cause')
                if store: b.equal(b.read(DATA,width,n),values[:idx]+[0]*(n-idx),'vector store prefix')
                else:
                    value=b.rr('v8');actual=[(value>>(width*i))&mask for i in range(n)]
                    b.equal(actual,values[:idx]+[mask]*(n-idx),'vector load prefix')
            finally: b.cmd(f'rwp {address:#x}')
            b.cmd('resume');b.cmd('wait_halt 5000')
            if store: b.equal(b.read(DATA,width,n),values,'vector store completion')
            else:
                value=b.rr('v8');b.equal([(value>>(width*i))&mask for i in range(n)],values,'vector load completion')
            b.equal(b.rr('vstart'),0,'vector EEW completion clears vstart')

def high_sba():
    bm.prep();base=0x81000000;sentinel=0x12345678;b.write(base,32,[sentinel],'sysbus')
    issues=[]
    for high in [0x100000000,0x8000000000000000]:
        address=high|base
        try:
            value=b.read(address,32,method='sysbus');issues.append({'op':'read','address':hex(address),'returned':value})
        except RuntimeError: pass
        try:
            b.write(address,32,[0xdeadbeef],'sysbus');issues.append({'op':'write','address':hex(address),'low_alias':b.read(base,32)[0]})
        except RuntimeError: pass
        b.equal(b.read(base,32)[0],sentinel,'out-of-range SBA does not alter low alias')
    (OUT/'high-sba-issues.json').write_text(json.dumps(issues,indent=2)+'\n')
    b.require(not issues,'OpenOCD accepted out-of-range physical SBA: '+str(issues))
for name,fn in [('before-store watchpoints in M/S/U/VS/VU',watch_modes),('watchpoints after 7-bit and 16-bit pointer masking',pointer_mask),('MRET single-step to S/U/VS/VU',mret_step),('vector EEW 8/16/32/64 load/store restart',vector_widths),('32-bit SBA address-limit enforcement by OpenOCD',high_sba)]: b.case(name,fn)
sys.exit(b.finish())
