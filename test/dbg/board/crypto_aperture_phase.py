# Keccak known answers in and out of Debug Mode; isolation of the debug
# CSRs, DRET and the private debug page from ordinary M-mode code.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import re
bm.b.close();b=bm.b=Board('crypto-aperture');S=bm.SYMS
BASE=area('code')
def init_state():
    bm.prep();b.rw('a0',32);bm.pb([0x01b57057])
    b.equal(b.rr('vl'),32,'Keccak VL');b.equal(b.rr('vtype'),0x1b,'Keccak e64,m8')
    state=list(range(25))+[0xa5a5a5a500000000|i for i in range(25,32)]
    for reg in range(8): b.rw('v'+str(8+reg),sum(state[4*reg+i]<<(64*i) for i in range(4)))
    return state
def read_state():
    result=[]
    for reg in range(8):
        value=b.rr('v'+str(8+reg));result.extend((value>>(64*i))&((1<<64)-1) for i in range(4))
    return result
def kat():
    text=Path('test/fw/keccak_subj.c').read_text()
    expected={}
    for name in ['exp_p24','exp_p12','exp_chain']:
        body=text.split(name+'[25] = {',1)[1].split('};',1)[0]
        expected[name]=[int(x,16) for x in re.findall(r'0x([0-9a-f]+)ull',body)]
    for path in ['Program Buffer','normal execution']:
        for name,selectors in [('exp_p24',[0]),('exp_p12',[1]),('exp_chain',[0,1])]:
            initial=init_state();words=[0xa6092077|(8<<7)|(s<<20) for s in selectors]
            if path=='Program Buffer': bm.pb(words)
            else:
                b.write(BASE,32,words+[0x00100073],'sysbus');b.cmd('riscv mem_access progbuf')
                b.cmd(f'resume {BASE:#x}');b.cmd('wait_halt 5000')
            result=read_state()
            for i,value in enumerate(expected[name]): b.equal(result[i],value,f'{path} {name} lane {i}')
            b.equal(result[25:],initial[25:],'Keccak leaves tail intact')
            b.equal(b.rr('vstart'),0,'Keccak clears vstart')
    initial=init_state();bm.pb([0xa6292477],3)
    b.equal(read_state(),initial,'reserved Keccak encoding preserves state in PB exception')
def aperture():
    bm.prep()
    def run(words,expected,epc=None):
        b.write(BASE,32,words+[0x00100073],'sysbus');b.cmd('riscv mem_access progbuf')
        b.resume(S['_start']);b.halt()
        b.cmd(f'resume {BASE:#x}');b.cmd('wait_halt 5000')
        b.equal(b.rr('mcause'),expected,'normal-execution debug isolation fault')
        if epc is not None: b.equal(b.rr('mepc'),epc,'fault EPC')
    for csr in [0x7b0,0x7b1,0x7b2,0x7b3]:
        run([(csr<<20)|(2<<12)|(10<<7)|0x73],2,BASE)
        run([(csr<<20)|(10<<15)|(1<<12)|0x73],2,BASE)
    run([0x7b200073],2,BASE)
    b.rw('a1',0x120380)
    run([0x0005b503],5,BASE)
    run([0x00a5b023],7,BASE)
    b.resume(S['_start']);b.halt()
    b.cmd('resume 0x120800');b.cmd('wait_halt 5000')
    b.equal(b.rr('mcause'),1,'normal M-mode cannot fetch private Debug ROM')
    b.equal(b.rr('mepc'),0x120800,'debug-page fetch fault EPC')
    bm.prep()
b.case('24/12-round/chained Keccak KATs in Debug Mode and ordinary execution',kat)
b.case('normal M-mode debug CSR/DRET/page read-write-fetch isolation',aperture)
sys.exit(b.finish())
