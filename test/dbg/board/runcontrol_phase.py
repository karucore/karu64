# Counter freeze, stepped WFI legality, trigger WARL, raw SBA pipelines.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
bm.b.close();b=bm.b=Board('runcontrol');S=bm.SYMS;DATA=bm.DATA
def control():
    bm.prep()
    # mcycle/minstret stop throughout Debug Mode, platform time keeps advancing.
    c0=b.rawread(0xb00);i0=b.rawread(0xb02);t0=b.rawread(0xc01)
    time.sleep(.1)
    b.equal(b.rawread(0xb00),c0,'mcycle frozen in Debug Mode')
    b.equal(b.rawread(0xb02),i0,'minstret frozen in Debug Mode')
    b.require(b.rawread(0xc01)>t0,'platform time advances while halted')
    b.require(b.rr('dcsr')&(1<<10),'stopcount reads one')
    cases=[('M',3,0,0,None),('S',1,0,0,None),('S-TW',1,1<<21,0,2),('U',0,0,0,2),('VS-VTW',0x21,0,1<<21,22),('VU',0x20,0,0,22)]
    for name,mode,status,hs,cause in cases:
        bm.prep();b.rw('dcsr',0x3b400|mode);b.rw('mstatus',0x6600|status);b.rw('hstatus',hs)
        b.rw('pc',S['wfi_case']);b.cmd('step')
        b.equal(b.rr('pc'),S['wfi_case']+4 if cause is None else S['trap_handler'],name+' WFI step PC')
        if cause is not None:
            b.equal(b.rr('mcause'),cause,name+' WFI cause');b.equal(b.rr('mepc'),S['wfi_case'],name+' EPC')
        b.equal((b.rr('dcsr')>>6)&7,4,name+' step debug cause')
    # Debug disabled EBREAK in ordinary execution is an architectural trap.
    bm.prep();b.rw('dcsr',0x403);b.rw('pc',S['ebreak_case']+4);b.cmd('riscv exec_progbuf 0x13')
    b.cmd('poll off');dc=b.rawread(0x7b0);b.rawwrite(0x7b0,dc|4);b.dmi(0x10,0x40000001)
    for _ in range(200):
        if b.dmi(0x11)&0x300==0x300: break
    b.rawwrite(0x7b0,dc&~4);b.cmd('poll on');b.cmd('poll')
    b.equal(b.rr('mcause'),3,'EBREAK without ebreakm traps')
    b.equal(b.rr('mepc'),S['ebreak_case']+4,'architectural EBREAK EPC')
    bm.prep()
def tdata_warl():
    bm.prep();b.cmd('riscv exec_progbuf 0x13');b.cmd('poll off')
    for slot in [0,1]:
        b.rawwrite(0x7a0,slot);b.equal(b.rawread(0x7a0),slot,'trigger slot')
        b.rawwrite(0x7a2,FIXTURE+0x40)
        for bad in [0,0x2000000000000000,0x6000000000001044,0x6800000000000044,0x6800000000001844,0x6800000000201044]:
            b.rawwrite(0x7a1,bad);b.equal(b.rawread(0x7a1)>>60,15,'unsupported trigger configuration disabled')
        valid=0x6800000000001044
        b.rawwrite(0x7a1,valid);b.equal(b.rawread(0x7a1),valid,'mcontrol6 equal execute')
        for addr in [0,0x8000000000000000,0xffffffffffffffff]:
            b.rawwrite(0x7a2,addr);b.equal(b.rawread(0x7a2),addr,'equality address preserves XLEN')
        b.rawwrite(0x7a1,0);b.rawwrite(0x7a2,FIXTURE+1);b.rawwrite(0x7a1,valid|0x80)
        b.rawwrite(0x7a2,0x7fffffffffffffff)
        b.equal(b.rawread(0x7a2),0x3fffffffffffffff,'NAPOT maskmax WARL')
        b.rawwrite(0x7a1,0)
    b.cmd('poll on')
def sba_pipeline():
    bm.prep();b.write(DATA,32,list(range(64)),'sysbus');b.cmd('riscv exec_progbuf 0x13');b.cmd('poll off')
    def wait():
        for _ in range(200):
            s=b.dmi(0x38)
            if not s&(1<<21):
                b.equal(s&0x407000,0,'SBA operation has no sticky error');return
        raise TimeoutError('SBA pipeline busy')
    # Read-on-address plus autoincrement; DATA0 reads do not themselves start.
    for size in [0,1,2,3]:
        width=8<<size;mask=(1<<width)-1
        b.dmi(0x38,(size<<17)|(1<<20)|(1<<16)|0x407000)
        for i in range(10):
            address=DATA+i*(1<<size);b.dmi(0x39,address);wait()
            value=b.dmi(0x3c)|(b.dmi(0x3d)<<32)
            expected=int.from_bytes(bytes().join(struct.pack('<I',x) for x in range(64))[i*(1<<size):(i+1)*(1<<size)],'little')
            b.equal(value&mask,expected,'readonaddr result')
            b.equal(b.dmi(0x39),address+(1<<size),'increment on success')
    b.dmi(0x38,(2<<17)|(1<<20)|(1<<16)|0x407000);b.dmi(0x39,DATA);wait()
    b.dmi(0x38,(2<<17)|(1<<15)|(1<<16)|0x407000)
    for i in range(16): b.equal(b.dmi(0x3c),i,'readondata pipeline');wait()
    b.dmi(0x38,(2<<17)|0x407000)
    # Ignored high-address register on sbasize=32, no accidental truncation claim.
    b.dmi(0x3a,0xffffffff);b.equal(b.dmi(0x3a),0,'unimplemented SBADDRESS1')
    b.cmd('poll on')
import struct
for name,fn in [('counter freeze, WFI privilege traps and EBREAK trap stepping',control),('two trigger slots, address width and WARL rejection',tdata_warl),('raw SBA read-on-address/data pipelines and success-only increment',sba_pipeline)]: b.case(name,fn)
sys.exit(b.finish(bm.prep))
