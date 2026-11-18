# FP/vector state, privilege contexts, triggers, vector watchpoint restart,
# coherence, SBA with a running hart, reset recovery.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import random,struct
bm.b.close(); b=bm.b=Board('extended'); S=bm.SYMS; DATA=bm.DATA
prep=bm.prep
def run(label):
    b.cmd(f'resume {S[label]:#x}'); b.cmd('wait_halt 5000')
def vector_setup(width,vl):
    b.rw('a0',vl); run('setup_e'+str(width)); b.equal(b.rr('vl'),vl,'vector VL')
def vu(words): return sum((x&0xffffffff)<<(32*i) for i,x in enumerate(words))
def elems(reg):
    v=b.rr(reg); return [(v>>(32*i))&0xffffffff for i in range(8)]
def fp_vector_registers():
    prep(); rng=random.Random(0x4f50524f)
    names=['ft0','ft1','ft2','ft3','ft4','ft5','ft6','ft7','fs0','fs1','fa0','fa1','fa2','fa3','fa4','fa5','fa6','fa7','fs2','fs3','fs4','fs5','fs6','fs7','fs8','fs9','fs10','fs11','ft8','ft9','ft10','ft11']
    for pattern in [0,0xffffffffffffffff,0x7ff8000012345678,'random']:
        values=[rng.getrandbits(64) if pattern=='random' else pattern for _ in names]
        for name,val in zip(names,values): b.rw(name,val)
        for name,val in zip(names,values): b.equal(b.rr(name),val,'FP '+name)
    vector_setup(8,23)
    for pattern in [0,(1<<256)-1,int('a5'*32,16),'random']:
        values=[rng.getrandbits(256) if pattern=='random' else pattern for _ in range(32)]
        for i,val in enumerate(values): b.rw('v'+str(i),val)
        before={r:b.rr(r) for r in ['vl','vtype','vstart']}
        for i,val in enumerate(values): b.equal(b.rr('v'+str(i)),val,'vector v'+str(i))
        for r,v in before.items(): b.equal(b.rr(r),v,'debug vector access preserves '+r)
    b.rw('ft0',0x3ff0000000000000); b.rw('ft1',0x4000000000000000)
    run('fp_case')
    b.equal(b.rr('ft2'),0x4008000000000000,'fadd.d')
    b.equal(b.rr('ft3'),0x4014000000000000,'fmadd.d third operand')
def host_guest_context():
    prep()
    for dcsr in [0x3b403,0x3b401,0x3b400,0x3b421,0x3b420]:
        b.rw('dcsr',dcsr); b.rw('a0',0); run('ebreak_case')
        b.equal(b.rr('a0'),1,'context executed instruction')
        b.equal(b.rr('dcsr')&0x23,dcsr&0x23,'M/S/U/VS/VU round trip')
        b.equal((b.rr('dcsr')>>6)&7,1,'context EBREAK cause')
    prep()
    for prv,tw,vtw,expected in [(3,0,0,None),(1,0,0,None),(1,1,0,2),(0,0,0,2),(0x21,0,1,22),(0x20,0,0,22)]:
        b.rw('mstatus',0x6600|(tw<<21)); b.rw('hstatus',(2<<32)|(vtw<<21))
        b.rw('dcsr',0x3b400|prv); b.rw('pc',S['wfi_case']); b.cmd('step')
        if expected is None: b.equal(b.rr('pc'),S['wfi_case']+4,'legal stepped WFI completes')
        else:
            b.equal(b.rr('mcause'),expected,'stepped WFI legality')
            b.equal(b.rr('mepc'),S['wfi_case'],'WFI fault EPC')
        b.equal((b.rr('dcsr')>>6)&7,4,'WFI step cause')
    prep()
def trigger_allocation():
    prep()
    b.cmd('proc check_equal {actual expected label} {if {$actual != $expected} {error "$label: $actual != $expected"}}')
    b.cmd('proc read_reg_value {name} {return [dict get [get_reg -force $name] $name]}')
    b.cmd('source test/dbg/openocd_trigger_address.tcl')
    b.checks+=15
    b.cmd('bp 0x80007000 4 hw'); b.cmd('wp 0x80006000 4 w')
    rejected=False
    try: b.cmd('bp 0x80007018 4 hw')
    except RuntimeError: rejected=True
    b.require(rejected,'third trigger must be rejected')
    b.cmd('rbp 0x80007000'); b.cmd('rwp 0x80006000')
    b.cmd('bp 0x80007018 4 hw'); b.cmd('rbp 0x80007018')
    b.rw('tselect',0); b.equal(b.rr('tinfo'),0x01008040,'Sdtrig tinfo')
    b.rw('tselect',2); b.equal(b.rr('tselect'),0,'out-of-range tselect unchanged')
def vector_watch():
    prep()
    for label,store in [('vload_case',False),('vstore_case',True),('ff_case',False),('seg_load',False),('seg_store',True),('whole_load',False)]:
        seg=label.startswith('seg_'); whole=label=='whole_load'; vl=4 if seg else 8
        vector_setup(32,vl)
        src=[0x1000+i for i in range(16)]
        b.write(DATA,32,[0]*16 if store else src,'sysbus')
        b.cmd('riscv mem_access progbuf')
        b.rw('v8',vu([0x77777777]*8 if not store else [10+i for i in range(8)]))
        b.rw('v9',vu([0x88888888]*8 if not store else [20+i for i in range(8)]))
        b.rw('a1',DATA)
        b.resume(S['_start']); b.halt()  # leave EBREAK with no pending watchpoint
        idx=2 if seg else 3; addr=DATA+(idx*2+1)*4 if seg else DATA+idx*4
        b.cmd(f'wp {addr:#x} 4 '+('w' if store else 'r'))
        try:
            run(label)
            b.equal(b.rr('pc'),S[label],label+' watchpoint DPC')
            b.equal((b.rr('dcsr')>>6)&7,2,label+' trigger cause')
            b.equal(b.rr('vstart'),idx,label+' restart index')
            b.equal(b.rr('vl'),vl,label+' preserves VL')
            if store:
                prefix=[x for pair in zip(range(10,18),range(20,28)) for x in pair] if seg else list(range(10,18))
                done=idx*2 if seg else idx
                b.equal(b.read(DATA,32,done+1),prefix[:done]+[0],label+' completed prefix only')
            else:
                expected=src[:idx] if not seg else src[:idx*2:2]
                b.equal(elems('v8')[:idx],expected,label+' loaded prefix')
        finally: b.cmd(f'rwp {addr:#x}')
        b.cmd('resume'); b.cmd('wait_halt 5000')
        b.equal(b.rr('vstart'),0,label+' restart finishes')
        b.equal(b.rr('pc'),S[label]+4,label+' final EBREAK')
        if not store:
            b.equal(elems('v8')[:vl],src[:vl] if not seg else src[:vl*2:2],label+' final v8')
            if seg or whole: b.equal(elems('v9')[:vl],src[1:vl*2:2] if seg else src[8:16],label+' final v9')
        else:
            expected=[x for pair in zip(range(10,18),range(20,28)) for x in pair][:vl*2] if seg else list(range(10,18))
            b.equal(b.read(DATA,32,len(expected)),expected,label+' final stores')
    # Masked-off element cannot fire; active element resumes at its index.
    for idx,hit in [(2,False),(3,True)]:
        vector_setup(32,8); b.rw('v0',0xaa); b.rw('v8',vu([0x77777777]*8)); b.rw('a1',DATA)
        b.write(DATA,32,list(range(100,108)),'sysbus'); b.cmd('riscv mem_access progbuf')
        addr=DATA+4*idx; b.resume(S['_start']); b.halt(); b.cmd(f'wp {addr:#x} 4 r')
        try:
            run('masked_load')
            b.equal((b.rr('dcsr')>>6)&7,2 if hit else 1,'masked trigger qualification')
            b.equal(b.rr('vstart'),idx if hit else 0,'masked restart')
        finally: b.cmd(f'rwp {addr:#x}')
        if hit: b.cmd('resume'); b.cmd('wait_halt 5000')
        b.equal(elems('v8'),[100+i if i%2 else 0x77777777 for i in range(8)],'mask and completed tail')
def coherence():
    # Scope: the hart is halted while the code is patched and leaves Debug
    # Mode to run it. Debug entry and exit redirect the fetch unit by
    # themselves, so this shows that a stale I-cache line (DRAM case) and a
    # stale D-cache word are not used after an SBA write. It does not isolate
    # the invalidation of already prefetched instructions by SBA maintenance
    # on a running hart; that is covered in simulation only.
    prep()
    for base in [area('patch'),0x81004000]:
        b.write(base,32,[0x00150513,0x00150513,0x00100073],'sysbus')
        b.cmd('riscv mem_access progbuf'); b.rw('a0',0); b.rw('pc',base); b.cmd('step')
        b.equal(b.rr('a0'),1,'warm executable first instruction')
        # Flush the debugger register cache before the raw-only interval.
        b.cmd('riscv exec_progbuf 0x13'); b.cmd('poll off')
        b.dmi(0x38,(2<<17)|0x407000); b.dmi(0x39,base+4); b.dmi(0x3c,0x00750513)
        for _ in range(200):
            sb=b.dmi(0x38)
            if not sb&(1<<21): break
        b.equal((sb>>12)&7,0,'SBA code replacement success')
        dc=b.rawread(0x7b0); b.rawwrite(0x7b0,dc|4)
        # Resume through DM only: no debugger-injected FENCE.I or PB command.
        b.dmi(0x10,0x40000001)
        for _ in range(200):
            status=b.dmi(0x11)
            if status&0x300==0x300: break
        b.equal(b.rawread(0x100a),8,'raw step sees replacement instead of prefetched opcode')
        b.rawwrite(0x7b0,dc&~4); b.cmd('poll on'); b.cmd('poll')
        # Warm a cached data word, then write through SBA and read through core.
        b.write(0x81005000,64,[0x0123456789abcdef],'progbuf')
        b.equal(b.read(0x81005000,64)[0],0x0123456789abcdef,'warm D-cache')
        b.write(0x81005000,64,[0xfedcba9876543210],'sysbus')
        b.equal(b.read(0x81005000,64,method='progbuf')[0],0xfedcba9876543210,'SBA invalidates cached data')
def running_sba():
    prep(); b.rw('a0',0xfedcba9876543210); b.rw('a1',17)
    b.rw('ft0',0x3ff0000000000000); b.rw('ft1',0x4000000000000000)
    vector_setup(32,8); b.rw('a0',0xfedcba9876543210); b.rw('a1',17); b.rw('v8',vu(list(range(8)))); b.rw('v9',vu([10]*8))
    b.resume(S['long_case'])
    try:
        for i in range(250):
            vals=[0xabc0000000000000+i,0x7654000000000000+i]
            b.write(0x81006000,64,vals,'sysbus'); b.equal(b.read(0x81006000,64,2),vals,'SBA while DIV/FP/vector execute')
    finally: b.halt()
    b.equal(b.rr('a2'),0xfedcba9876543210//17,'long integer divide completed precisely')
    # Writes to unrelated RAM must not destroy the program or FP state.
    b.equal(b.rr('ft2'),0x3fe0000000000000,'FP divide while SBA active')
    b.equal(elems('v10'),list(range(10,18)),'vector arithmetic while SBA active')
def reset_recovery():
    prep(); b.cmd('riscv exec_progbuf 0x13'); b.cmd('poll off')
    b.dmi(0x20,0x0000006f); b.dmi(0x17,0x40000)
    time.sleep(.01); b.require(b.dmi(0x16)&0x1000,'hung PB remains busy')
    b.dmi(0x10,0); b.equal(b.dmi(0x10)&1,1,'deactivation pending until PB finishes')
    b.dmi(0x10,1); b.equal(b.dmi(0x10)&1,1,'reactivation cancels pending deactivation')
    b.reset_halt(); prep()
    b.equal((b.dmi(0x16)>>8)&7,0,'ndmreset recovers hung PB')
    # Prove normal debug works after recovery, then test sticky havereset.
    b.rawwrite(0x1005,0x13579bdf); b.equal(b.rawread(0x1005),0x13579bdf,'command after reset recovery')
    b.equal((b.dmi(0x11)>>18)&3,0,'ackhavereset clears sticky reset')
    b.cmd('poll on')

if __name__=='__main__':
    for name,fn in [('reload extended fixture',bm.load),('all FP/vector register patterns and FMA',fp_vector_registers),('M/S/U/VS/VU context and WFI trap stepping',host_guest_context),('native hardware trigger continuation and slot exhaustion',trigger_allocation),('vector/segmented/FF/whole/masked watchpoint restart',vector_watch),('SBA code replacement without debugger fences and D-cache coherence',coherence),('250 running-hart SBA batches during DIV/FP/vector loops',running_sba),('hung PB, pending deactivation, ndmreset and reset recovery',reset_recovery)]:
        b.case(name,fn)
    def cleanup():
        prep(); b.rw('pc',S['_start']); b.cmd('riscv exec_progbuf 0x13')
    sys.exit(b.finish(cleanup))
