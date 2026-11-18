# USER4 tunnel framing recovery, DTM errors and resets, JTAG clock sweep,
# DM deactivation. The outer IR value is the XCVU9P's.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
bm.b.close(); b=bm.b=Board('transport')
def scan(data,width,value,cut=None):
    n=8+width+3+int(data)
    payload=int(data)|(width<<1)|(value<<8)
    if cut: n=cut;payload&=(1<<n)-1
    return int(b.cmd(f'drscan karu.fpga {n} {payload:#x}'),16)>>9
def ir(val): scan(False,5,val)
def raw_dmi(addr,val=0,op=1):
    ir(0x11);scan(True,41,(addr<<34)|(val<<2)|op)
    b.cmd('runtest 32')
    out=scan(True,41,0)
    b.equal(out&3,0,'raw DMI response status')
    return (out>>2)&0xffffffff
def dtm():
    ir(0x10); return scan(True,32,0)&0xffffffff
def framing():
    bm.prep();b.cmd('riscv exec_progbuf 0x13');b.cmd('poll off')
    b.cmd('irscan karu.fpga 0x23924')
    b.equal(dtm(),0x1071,'physical DTMCS')
    # Production recovery pulse, all partial frame positions, no outer reset
    # between the truncation and the next valid DTMCS frame.
    committed=0
    for cut in range(1,53):
        raw_dmi(4,0xdeaf1234,2);ir(0x11)
        scan(True,41,(4<<34)|(0x5555aaaa<<2)|2,cut=cut)
        b.cmd('runtest 32')
        b.equal(dtm(),0x1071,f'DTMCS after cut {cut}')
        value=raw_dmi(4)
        b.require(value in [0xdeaf1234,0x5555aaaa],f'partial frame {cut} never corrupts data0')
        committed+=value==0x5555aaaa
        raw_dmi(4,0xc0de0000|cut,2)
        b.equal(raw_dmi(4),0xc0de0000|cut,'DMI recovery round trip')
    b.require(0<committed<52,'both committed and uncommitted partial frames')
    ir(0x11);b.cmd('poll on')
    return {'cuts':52,'committed_intended_write':committed,'unobservable':'Cannot count internal DMI requests on this bitstream; checks are external register effects and recovery.'}
def sticky_errors():
    bm.prep();b.cmd('poll off');b.cmd('irscan karu.fpga 0x23924')
    ir(0x11);scan(True,41,3);b.cmd('runtest 32')
    b.equal((dtm()>>10)&3,2,'reserved DMI operation produces sticky failed')
    ir(0x10);scan(True,32,1<<16)
    b.equal((dtm()>>10)&3,0,'dmireset clears sticky error')
    raw_dmi(4,0xabcdef01,2);b.equal(raw_dmi(4),0xabcdef01,'DM survives dmireset')
    ir(0x10);scan(True,32,1<<17);b.cmd('runtest 64')
    b.equal(dtm(),0x1071,'dtmhardreset recovers channel')
    b.equal(raw_dmi(4),0xabcdef01,'channel reset preserves architectural DM state')
    ir(0x11);b.cmd('poll on')
def clock_sweep():
    bm.prep();b.cmd('poll off')
    for khz in [100,250,500,1000,2000,5000,10000]:
        b.cmd(f'adapter speed {khz}')
        for i in range(300):
            value=(0x01234567*i+khz)&0xffffffff
            b.dmi(4,value);b.equal(b.dmi(4),value,f'{khz} kHz DMI data0')
            b.equal(b.dmi(0x11)&0xff,0x83,f'{khz} kHz DMstatus')
    b.cmd('adapter speed 1000');b.cmd('poll on')
def deactivation():
    bm.prep();b.cmd('riscv exec_progbuf 0x13');b.resume(bm.SYMS['_start']);b.cmd('poll off')
    for n in range(100):
        b.dmi(4,0xabcdef01);b.dmi(5,0x12345678)
        b.dmi(0x10,0);b.equal(b.dmi(0x10),0,'deactivated DM acknowledged')
        b.equal(b.dmi(0x11),0,'inactive DMstatus zero')
        b.dmi(0x10,1)
        b.equal(b.dmi(4),0,'DATA0 reset after deactivation')
        b.equal(b.dmi(5),0,'DATA1 reset after deactivation')
        b.equal(b.dmi(0x18),0,'autoexec reset after deactivation')
        b.equal(b.dmi(0x16),0x08000002,'abstractcs reset after deactivation')
    b.cmd('poll on');b.halt()

CASES=[('all 52 physical USER4 partial-frame recovery positions',framing),('DTM sticky failure, dmireset, dtmhardreset',sticky_errors),('100 kHz through 10 MHz cable/DTM sweep, 300 data patterns per clock',clock_sweep),('100 DM deactivate/reactivate cycles with hart running',deactivation)]
def restore():
    b.cmd('adapter speed 1000');b.cmd('poll on')
def main(cases=CASES):
    # Every case changes the adapter speed or polling. The restore after each
    # one is recorded: a failure there fails the phase (it used to be
    # discarded, and the phase then exited 0).
    for name,fn in cases:
        b.case(name,fn)
        b.restore(name,restore)
    return b.finish()
if __name__=='__main__': sys.exit(main())
