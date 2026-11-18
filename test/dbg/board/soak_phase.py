# Timed soak: mixed-width SBA traffic while the hart executes, with periodic
# halts. KARU_BOARD_SOAK_SECONDS sets the duration (default 600).
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import extended_phase as e
import random
e.b.close();b=e.b=e.bm.b=Board('soak');rng=random.Random(0x51ba2026)
SECONDS=int(setting('KARU_BOARD_SOAK_SECONDS',600))
def soak():
    e.prep();e.vector_setup(32,8)
    b.rw('a0',0xfedcba9876543210);b.rw('a1',17)
    b.rw('ft0',0x3ff0000000000000);b.rw('ft1',0x4000000000000000)
    b.rw('v8',e.vu(list(range(8))));b.rw('v9',e.vu([10]*8))
    b.cmd('wp 0x81200000 8 a');b.resume(e.S['long_case'])
    start=time.monotonic();last=start;batch=0;words=0;halts=0
    try:
        while time.monotonic()-start<SECONDS:
            width=rng.choice([8,16,32,64]);count=rng.choice([1,2,5,17,64,128]);stride=width//8
            base=rng.choice([area('matrix'),0x81200000,0x90002000,0xffffc000])
            addr=base+rng.randrange(0,256)*stride
            vals=[rng.getrandbits(width) for _ in range(count)]
            b.write(addr,width,vals,'sysbus');actual=b.read(addr,width,count)
            b.equal(len(actual),count,'soak transfer count')
            for i,(value,expected) in enumerate(zip(actual,vals)): b.equal(value,expected,f'soak batch {batch} word {i}')
            words+=count;batch+=1
            if batch%20==0:
                b.cmd('poll');b.equal(b.cmd('karu.cpu curstate'),'running','SBA never fires armed hart watchpoint')
                b.halt();halts+=1
                b.equal(b.rr('a0'),0xfedcba9876543210,'soak scalar operand preserved')
                b.equal(b.rr('a1'),17,'soak divisor preserved')
                b.equal(b.rr('a2'),0xfedcba9876543210//17,'soak DIVU result')
                b.equal(b.rr('ft2'),0x3fe0000000000000,'soak FDIV result')
                b.equal(e.elems('v10'),list(range(10,18)),'soak vector result')
                b.cmd('riscv mem_access progbuf')
                b.equal(b.read(addr,width,count),vals,'core reads coherent SBA data')
                b.resume(e.S['long_case'])
            if batch%100==0:
                b.cmd('adapter speed '+str(rng.choice([500,1000,5000,10000])))
            now=time.monotonic()
            if now-last>=20:
                progress=dict(seconds=round(now-start,1),batches=batch,verified_words=words,halt_resume_cycles=halts,checks=b.checks)
                (OUT/'soak-progress.json').write_text(json.dumps(progress,indent=2)+'\n')
                print(json.dumps(progress),flush=True);last=now
            time.sleep(.045)
    finally:
        b.cmd('adapter speed 1000');b.halt();b.cmd('rwp 0x81200000')
    return dict(seconds=round(time.monotonic()-start,2),batches=batch,verified_words=words,halt_resume_cycles=halts)
b.case(f'{SECONDS}-second physical mixed-width SBA/core/FP/vector/coherence soak',soak)
sys.exit(b.finish())
