# Reset-halt fixture, abstract commands, Program Buffer, autoexec, memory,
# SBA errors, UART MMIO and scalar run control. Needs the reset-halted fixture.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import random,struct
SYMS=fixture_symbols()      # refuses a fixture that is not the selected image map's
b=Board('baremetal')
DATA=area('data')
def prep():
    if b.cmd('karu.cpu curstate')!='halted': b.halt()
    b.clear(); b.cmd('poll on'); b.cmd('riscv mem_access progbuf')
    for reg,val in [('dcsr',0x3b403),('mstatus',0x6600),('mie',0),('medeleg',0),('mideleg',0),('satp',0),('vsatp',0),('hgatp',0),('mtvec',SYMS['trap_handler'])]: b.rw(reg,val)
    b.cmd('riscv exec_progbuf 0x00000013')
def pb(words,err=0):
    b.cmd('riscv exec_progbuf 0x00000013'); b.cmd('poll off'); b.clear()
    for i,w in enumerate((words+[0x00100073]+[0x13]*8)[:8]): b.dmi(0x20+i,w)
    b.dmi(0x17,0x40000); b.idle(err)
    if err: b.dmi(0x16,0x700)
    b.cmd('poll on')
def load():
    b.reset_halt(); prep()
    data=(OUT/'payload.bin').read_bytes(); data+=b'\0'*(-len(data)%4)
    b.write(SYMS['_start'],32,list(struct.unpack('<'+'I'*(len(data)//4),data)),'sysbus')
    b.equal(bytes(sum(([x&255,(x>>8)&255,(x>>16)&255,(x>>24)&255] for x in b.read(SYMS['_start'],32,len(data)//4,'sysbus')),[])),data,'fixture readback')
    b.cmd('riscv mem_access progbuf')
    return {'symbols':SYMS,'bytes':len(data)}
def abstract_errors():
    prep(); b.cmd('poll off')
    original={r:b.rawread(r) for r in (0x1008,0x100a,0x341,0x342,0x343)}
    for cmd in [0x01000000,0x02000000,0xff000000,0x00800000,0x00080000,0x00421005,0x00321020,0x003207b2,0x003207b3,0x00231005]:
        b.dmi(0x17,cmd); b.idle(2)
        b.dmi(0x17,0x00321005); b.idle(2)
        b.dmi(0x16,0x700); b.equal((b.dmi(0x16)>>8)&7,0,'clear cmderr')
    b.dmi(0x17,0x0070ffff); b.idle()
    b.dmi(0x17,0x00320fff); b.idle(3); b.dmi(0x16,0x700)
    for r,v in original.items(): b.equal(b.rawread(r),v,f'abstract fault preserves {r:#x}')
    b.rawwrite(0x1005,0xfedcba9876543210)
    b.equal(b.rawread(0x1005,2),0x76543210,'32-bit GPR read')
    b.equal(b.rawread(0x1005),0xfedcba9876543210,'32-bit read leaves GPR intact')
    b.cmd('poll on')
def program_buffer():
    prep(); b.rw('a0',10); b.rw('s0',0x12345678)
    before={r:b.rr(r) for r in ['mepc','mcause','mtval','sepc','scause','stval']}
    pb([0x00550513]); b.equal(b.rr('a0'),15,'PB arithmetic')
    for insn in [0xffffffff,0x30200073,0x10200073,0x7b200073]:
        b.rw('a0',100); b.rw('s0',0x87654321)
        pb([0x00150513,0x00140413,insn],3)
        b.equal(b.rr('a0'),101,'completed a0 effect survives PB exception')
        b.equal(b.rr('s0'),0x87654322,'completed s0 effect survives PB exception')
        for r,v in before.items(): b.equal(b.rr(r),v,'PB exception preserves '+r)
    pb([0x10500073,0x00d00073,0x00350513])
    b.equal(b.rr('a0'),104,'WFI/WRS in Debug Mode are NOPs')
    pb([0x01d0000f,0x00d0000f,0x0000100f])
AUTOEXEC_TRIGGERS=[(0,4),(1,5)]+[(16+i,0x20+i) for i in range(8)]   # (autoexec bit, DMI address)
AUTOEXEC_READS=5
def autoexec():
    # Count executions. The Program Buffer adds one to a0 and the command is
    # "execute the Program Buffer" with no register transfer, so a0 advances
    # by exactly one per execution and nothing else changes. For each of the
    # ten autoexec bits: reads and one write of its own register must each
    # execute once; reads and writes of the nine other registers, and of its
    # own register once the bit is cleared, must not execute at all. Writes
    # put back the value the register already holds.
    # (The 2026-11-16 campaign re-read an unchanged GPR instead; that passes
    # on a target whose autoexec triggers do nothing.)
    prep(); b.cmd('riscv exec_progbuf 0x13'); b.cmd('poll off')
    b.dmi(0x18,0xffffffff); b.equal(b.dmi(0x18),0x00ff0003,'autoexec implemented mask'); b.dmi(0x18,0)
    saved=b.rawread(0x100a)
    words=[0x00150513,0x00100073]+[0x13]*6            # addi a0,a0,1; ebreak
    for i,w in enumerate(words): b.dmi(0x20+i,w)
    def rewrite(addr,bit):                              # a write access that changes nothing
        b.dmi(addr,words[addr-0x20] if addr>=0x20 else 0x5a5a0000|bit); b.idle()
    try:
        for bit,addr in AUTOEXEC_TRIGGERS:
            base=0x1000*(bit+1); b.rawwrite(0x100a,base)
            b.dmi(0x17,0x40000); b.idle()               # the command autoexec repeats; runs once
            b.equal(b.rawread(0x100a),base+1,f'explicit command executes once (bit {bit})')
            b.dmi(0x17,0x40000); b.idle()               # make it the last command again
            b.dmi(0x18,1<<bit); b.equal(b.dmi(0x18),1<<bit,f'autoexec bit {bit} set')
            for other_bit,other in AUTOEXEC_TRIGGERS:
                if other!=addr:
                    b.dmi(other); b.idle()              # unselected register, read: no execution
                    rewrite(other,bit)                  # unselected register, write: no execution
            for i in range(AUTOEXEC_READS):
                b.dmi(addr); b.idle()                   # one execution per read
            rewrite(addr,bit)                           # and one per write
            b.dmi(0x18,0)
            b.dmi(addr); b.idle()                       # bit cleared, read: no execution
            rewrite(addr,bit)                           # bit cleared, write: no execution
            b.equal(b.rawread(0x100a),base+2+AUTOEXEC_READS+1,
                    f'autoexec bit {bit}: exactly one execution per access of {addr:#x}, none otherwise')
    finally:
        b.dmi(0x18,0); b.dmi(0x16,0x700); b.rawwrite(0x100a,saved)
    b.dmi(0x17,0x01000000); b.idle(2); b.dmi(0x16,0x700)
    b.dmi(0x18,1); b.dmi(4); b.idle(2)
    b.dmi(0x18,0); b.dmi(0x16,0x700); b.cmd('poll on')
def memory_matrix():
    prep(); rng=random.Random(0x167526)
    for base in [area('matrix'),0x81000000,0x90001000,0xffffe000]:
        for method in ['sysbus','progbuf']:
            for width in [8,16,32,64]:
                for n in [1,2,5,17,65]:
                    vals=[rng.getrandbits(width) for _ in range(n)]
                    off=(n%8)*(width//8)
                    b.write(base+off,width,vals,method)
                    b.equal(b.read(base+off,width,n),vals,f'{base:#x} {method} width={width} n={n}')
    # Exhaust every byte lane with cross-method checks; adjacent bytes survive.
    for base in [DATA,0x81002000]:
        for width in [8,16,32,64]:
            for off in range(0,8,width//8):
                b.write(base,64,[0xa5a5a5a5a5a5a5a5],'sysbus')
                value=rng.getrandbits(width); b.write(base+off,width,[value],'progbuf')
                expected=(0xa5a5a5a5a5a5a5a5 & ~(((1<<width)-1)<<(8*off)))|(value<<(8*off))
                b.equal(b.read(base,64,method='sysbus')[0],expected,'byte lanes preserve adjacent bytes')
def raw_sba_errors():
    prep(); b.cmd('riscv exec_progbuf 0x13'); b.cmd('poll off')
    def wait():
        for _ in range(200):
            v=b.dmi(0x38)
            if not v&(1<<21): return v
        raise TimeoutError('SBA busy')
    for width in [4,5,6,7]:
        b.dmi(0x38,(width<<17)|0x407000); b.dmi(0x39,DATA); b.dmi(0x3c,0xdeadbeef)
        b.equal((wait()>>12)&7,4,'unsupported SBA width')
    for width in [1,2,3]:
        for off in range(1,1<<width):
            b.dmi(0x38,(width<<17)|0x407000); b.dmi(0x39,DATA+off); b.dmi(0x3c,0)
            b.equal((wait()>>12)&7,3,'SBA alignment error')
    for addr in [0x00120000,0x00120380,0x20000000]:
        b.dmi(0x38,(2<<17)|(1<<20)|0x407000); b.dmi(0x39,addr)
        b.equal((wait()>>12)&7,2,'SBA denied address')
    b.dmi(0x38,(2<<17)|0x407000)
    b.dmi(0x39,DATA); b.dmi(0x3c,0xabcdef01); b.equal((wait()>>12)&7,0,'SBA recovers')
    b.cmd('poll on'); b.equal(b.read(DATA,32,method='progbuf')[0],0xabcdef01,'error recovery data')
def mmio():
    prep()
    original=b.read(0x10000007,8,method='sysbus')[0]
    for method in ['sysbus','progbuf']:
        for value in [0,0xff,0xa5,0x5a,0x81,0x7e]:
            b.write(0x10000007,8,[value],method)
            b.equal(b.read(0x10000007,8)[0],value,'UART scratch '+method)
        b.require(b.read(0x10000005,8)[0]&0x60==0x60,'UART ready flags')
        for value in b'\r\nDEBUG_MMIO_'+method.encode()+b'_OK\r\n':
            b.write(0x10000000,8,[value]); time.sleep(.002)
    b.write(0x10000007,8,[original],'sysbus')
def stepping():
    prep(); b.rw('pc',SYMS['step_0'])
    for label,val in [('step_1',42),('step_2',43),('step_3',44),('step_end',46)]:
        b.cmd('step'); b.equal(b.rr('pc'),SYMS[label],'step PC '+label); b.equal(b.rr('a0'),val,'step value')
        b.equal((b.rr('dcsr')>>6)&7,4,'step cause')
    b.rw('pc',SYMS['branch_case']); b.cmd('step'); b.cmd('step')
    b.equal(b.rr('pc'),SYMS['branch_taken'],'taken branch step')
    b.cmd('step'); b.equal(b.rr('a0'),3,'branch skip side effect')
    for label in ['wfi_case','wrs_case','fence_case']:
        b.rw('pc',SYMS[label]); b.cmd('step'); b.equal(b.rr('pc'),SYMS[label]+4,label+' step completes')
    # Debug entry invalidates reservations: SC must fail after stepping LR.
    b.write(DATA,64,[0x1234],'sysbus'); b.rw('a1',DATA); b.rw('a0',0x5678); b.rw('pc',SYMS['lrsc_case'])
    b.cmd('step'); b.equal(b.rr('t0'),0x1234,'LR value')
    b.cmd('step'); b.require(b.rr('a2')!=0,'SC after debug entry fails')
    b.equal(b.read(DATA,64)[0],0x1234,'failed SC leaves memory')
    b.rw('pc',SYMS['amo_case']); b.cmd('step')
    b.equal(b.rr('t0'),0x1234,'AMO old value'); b.equal(b.read(DATA,64)[0],0x68ac,'AMO exactly once')
def traps():
    prep()
    for label,cause in [('illegal_case',2),('fault_case',5)]:
        b.rw('a1',0x20000000); b.rw('pc',SYMS[label]); b.cmd('step')
        b.equal(b.rr('pc'),SYMS['trap_handler'],'step stops before trap handler')
        b.equal(b.rr('mcause'),cause,'stepped trap cause')
        b.equal(b.rr('mepc'),SYMS[label],'stepped trap EPC')
        b.equal((b.rr('dcsr')>>6)&7,4,'stepped fault debug cause')
    # An EBREAK stops before executing a following instruction in each host mode.
    for prv in [3,1,0]:
        b.rw('dcsr',0x3b400|prv); b.rw('a0',0); b.cmd(f"resume {SYMS['ebreak_case']:#x}"); b.cmd('wait_halt 5000')
        b.equal(b.rr('pc'),SYMS['ebreak_case']+4,'EBREAK PC')
        b.equal(b.rr('a0'),1,'preceding instruction retires once')
        b.equal((b.rr('dcsr')>>6)&7,1,'EBREAK cause')
        b.equal(b.rr('dcsr')&3,prv,'saved privilege')
    prep()

if __name__=='__main__':
    for name,fn in [('reset-halt and fixture load',load),('abstract commands and sticky errors',abstract_errors),('Program Buffer execution, exceptions and instruction rules',program_buffer),('autoexec masks, ten triggers and command-cache errors',autoexec),('four physical regions, widths, lengths and byte lanes',memory_matrix),('SBA bad sizes, alignment, aperture denial and recovery',raw_sba_errors),('real UART scratch, status and TX on both access paths',mmio),('compressed/scalar/branch/fence/atomic single stepping',stepping),('fault stepping and M/S/U EBREAK entry',traps)]:
        b.case(name,fn)
    def cleanup():
        prep(); b.rw('pc',SYMS['_start']); b.cmd('riscv exec_progbuf 0x13')
    sys.exit(b.finish(cleanup))
