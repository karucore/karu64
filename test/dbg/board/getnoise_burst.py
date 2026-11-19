# Burst capture: raw noise with the rings sampled every 1 to 256 clock cycles,
# for the characterisation of the entropy source. Needs an image with the
# burst capture block (KARU_ZKR, built after 2026-11-18), DIP switch 4 off,
# the reset-halted fixture of baremetal_phase.py (the one for the image
# kind, KARU_BOARD_IMAGE), and getnoise_burst.bin and getnoise_burst.symbols
# in the artifact directory (make dbg-getnoise-burst-fixture). The capture
# itself is in DRAM and does not depend on the image's map.
#
# For each period the payload (getnoise_burst.S) is started in M-mode at its
# load address in DDR. It puts the entropy source in test mode, has the
# hardware record bursts of consecutive raw symbols, copies them to memory
# and stops at its ebreak. While it runs, seed is in BIST. Written to the
# artifact directory:
#
#   getnoise-burst-p<P>.bin   one byte per symbol: bits [3:0] the symbol (lane
#                             i in bit i), bit 7 on the first symbol of a
#                             burst. The format of getnoise_capture.py, with
#                             one run per burst.
#   getnoise-burst-p<P>.json  the period, counts, the clock-cycle stamps of
#                             every burst, mentropycfg, sha256 of the .bin
#
# Within a burst the symbols are consecutive samples P clock cycles apart.
# Nothing is known about the samples between two bursts. The sidecar also
# holds the FPGA's die temperature and supply voltages (the readout at
# 0x1000_0860, flow/fpga/karu_sysmon.v) read just before and just after the
# capture, raw and decoded. A capture's files replace the previous ones only
# when they are complete.
#
# A capture fails on a payload status other than OK, if test mode was not
# left, if the capture block still holds something afterwards, and on
# bookkeeping that does not agree (period, burst count, burst size, stamps).
#
#   KARU_BOARD_BURST_PERIODS   periods in clock cycles, comma separated (1,2,4,8,16,32,64,128,256)
#   KARU_BOARD_BURST_COUNT     bursts per period                         (32)
#   KARU_BOARD_BURST_ADDR      load address; the buffer starts 64 KiB above it (0x88000000)
#   KARU_BOARD_BURST_CLOCK_HZ  the hart's clock, for the sidecar and the waits (75000000)
#   KARU_BOARD_BURST_WAIT      seconds to wait for one period's capture  (from the sizes)
#   KARU_BOARD_BURST_NOTE      free text for the sidecar: bitstream, board, temperature, activity
#
# Analysis is offline: getnoise_analyze.py.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import hashlib,struct
bm.b.close();b=bm.b=Board('getnoise-burst')
PERIODS=[int(p,0) for p in setting('KARU_BOARD_BURST_PERIODS','1,2,4,8,16,32,64,128,256').split(',')]
BURSTS=int(setting('KARU_BOARD_BURST_COUNT',32),0)
LOAD=int(setting('KARU_BOARD_BURST_ADDR','0x88000000'),0)
CLOCK_HZ=int(setting('KARU_BOARD_BURST_CLOCK_HZ',75000000),0)
NOTE=os.environ.get('KARU_BOARD_BURST_NOTE','')
BUF=LOAD+0x10000
NBURST=0x10000840                                   # the capture block: status, period, index, data
MAGIC=0x4b4e4231
SYMS={p[2]:int(p[0],16) for line in (OUT/'getnoise_burst.symbols').read_text().splitlines() if len(p:=line.split())==3}
SYSMON=0x10000860                                   # temperature and supplies (flow/fpga/karu_sysmon.v)
def sysmon():
    """The readout word, raw and decoded; on an image without it the word reads 0."""
    v=b.read(SYSMON,64,1,'progbuf')[0];b.cmd('riscv mem_access progbuf')
    rec={'raw':hex(v),'updates':v>>48}
    if v&0xffffffffffff:
        rec.update(temp_c=round((v&0xffff)*509.3140064/65536-280.2308787,2),
                   vccint_v=round(((v>>16)&0xffff)*3/65536,4),vccaux_v=round(((v>>32)&0xffff)*3/65536,4))
    return rec
def publish(files,data,side):
    """Write a capture's files under temporary names and rename them only when both are
    complete, so that a failed or interrupted capture leaves the previous one in place."""
    tmp=[f.with_name(f.name+'.tmp') for f in files]
    tmp[0].write_bytes(data);tmp[1].write_text(side)
    tmp[0].replace(files[0]);tmp[1].replace(files[1])
PARAMS,RESULT,STOP=(LOAD+SYMS[s] for s in ('getburst_params','getburst_result','getburst_stop'))
FIELDS=['status','stored','words','polls','ctrl','period_used','cfg','noise_after','ctrl_after','mcause','mepc']
STATUS={0:'OK',1:'RUNNING: the payload did not reach its end',
        2:'LOCKED: mentropycfg has its lock bit set; only a reset clears it',
        3:'BUSY: mnoise did not read 1 at entry; the source is already in test mode',
        4:'PARAM: period, burst count, buffer size or idle limit rejected',
        5:'NOTEST: test mode was not entered, or the capture block did not allow capturing in it',
        6:'TIMEOUT: a burst did not complete; is DIP switch 4 on?',
        7:'TRAP: unexpected trap; at the first CSR access it means an image without KARU_ZKR',
        8:'NOBLOCK: the status register at 0x10000840 does not identify the capture block; the image was built without it',
        9:'PERIOD: the period register did not take the value',
        10:'ABORTED: the noise source was off during a burst (DIP switch 4, or a dead source); earlier bursts are valid but not saved',
        (1<<64)-1:'the payload never ran'}
payload=(OUT/'getnoise_burst.bin').read_bytes()
words=0                                             # 64-bit words per burst, from the hardware
def load():
    global words
    bm.prep()
    ctrl=b.read(NBURST,64,1,'progbuf')[0]
    b.require(ctrl>>32==MAGIC,f'the status register at {NBURST:#x} reads {ctrl:#x}: no capture block in this image')
    b.equal(ctrl&0x2f,0,'capture block at rest: not capturing, nothing held, no test mode, not locked')
    b.require(ctrl&0x10,'the noise source is off: DIP switch 4 is on, or the source failed its start-up test')
    words=1<<(((ctrl>>8)&0xff)-4)
    data=payload+b'\0'*(-len(payload)%4);code=list(struct.unpack(f'<{len(data)//4}I',data))
    b.require(len(data)<=BUF-LOAD,'payload ends below the buffer')
    b.write(LOAD,32,code,'sysbus')
    b.equal(b.read(LOAD,32,len(code),'sysbus'),code,'payload readback')
    b.cmd('riscv mem_access progbuf')
    return {'load':hex(LOAD),'buffer':hex(BUF),'bytes':len(payload),'ctrl':hex(ctrl),'symbols_per_burst':16*words}
def wait_halt(seconds):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        b.cmd('poll')
        if b.cmd('karu.cpu curstate')=='halted': return
        time.sleep(.1)
    b.halt()
    raise TimeoutError(f'payload still running after {seconds:.0f} s and was halted; the source may still be in test mode until the next reset')
def read_bytes(addr,n,chunk=4096):
    data=bytearray()
    for off in range(0,n,8*chunk):
        got=b.read(addr+off,64,min(chunk,(n-off+7)//8),'sysbus')
        data+=struct.pack(f'<{len(got)}Q',*got)
    return bytes(data[:n])
def capture(period):
    b.require(1<=period<=256,'the period is 1..256 clock cycles')
    b.require(words>0,'the payload load case found the capture block')
    files=[OUT/f'getnoise-burst-p{period}.bin',OUT/f'getnoise-burst-p{period}.json']
    bm.prep()
    before=sysmon()
    symbols=16*words;record=16+8*words;size=BURSTS*record
    idle=symbols*period//4+65536                    # status polls; one takes more than four clocks
    b.write(PARAMS,64,[period,BURSTS,BUF,size,idle,-1]+[0]*(len(FIELDS)-1),'sysbus')
    b.cmd('riscv mem_access progbuf')
    start=time.monotonic();b.cmd(f'resume {LOAD:#x}')
    wait_halt(float(setting('KARU_BOARD_BURST_WAIT',30+3*BURSTS*(symbols*period+40*words+1000)/CLOCK_HZ)))
    seconds=time.monotonic()-start;pc=b.rr('pc')
    r=dict(zip(FIELDS,b.read(RESULT,64,len(FIELDS),'sysbus')))
    b.cmd('riscv mem_access progbuf')
    after=sysmon()
    hexed={f:hex(r[f]) for f in ('ctrl','cfg','noise_after','ctrl_after','mcause','mepc')}
    if r['status']: raise AssertionError(f"payload status {r['status']:#x}, {STATUS.get(r['status'],'unknown')}; pc={pc:#x} stored={r['stored']} {hexed}")
    b.checks+=1
    b.equal(pc,STOP,'stopped at the payload ebreak')
    b.equal(r['noise_after'],1,'test mode left')
    b.equal(r['ctrl_after']&0x2f,0,'capture block at rest after test mode: nothing held')
    b.equal(r['period_used'],period,'the period the hardware used')
    b.equal(r['stored'],BURSTS,'bursts stored')
    b.equal(r['words'],words,'words per burst')
    raw=read_bytes(BUF,size);b.cmd('riscv mem_access progbuf')
    data=bytearray();started=[];done=[]
    for i in range(BURSTS):
        t0,t1,*w=struct.unpack_from(f'<{2+words}Q',raw,i*record)
        started.append(t0);done.append(t1)
        nibbles=bytearray((x>>(4*s))&15 for x in w for s in range(16))
        nibbles[0]|=0x80
        data+=nibbles
    b.require(all(d-s>=(symbols-1)*period for s,d in zip(started,done)),'no burst completed sooner than its symbols take')
    b.require(all(d-s<=(symbols+1)*period+4096 for s,d in zip(started,done)),'no burst took longer than its symbols take: the source did not pause')
    b.require(all(n>d for d,n in zip(done,started[1:])),'bursts follow each other in time')
    digest=hashlib.sha256(data).hexdigest()
    publish(files,bytes(data),json.dumps(dict(format='karu64-getnoise-burst-1',kind='burst',
        encoding='one byte per symbol: bits [3:0] symbol, lane i in bit i; bit 7 first symbol of a burst',
        period=period,k=1,clock_hz=CLOCK_HZ,bursts=BURSTS,symbols_per_burst=symbols,stored=len(data),runs=BURSTS,
        run_lengths=[symbols]*BURSTS,burst_cycles=started,burst_done_cycles=done,polls=r['polls'],
        ctrl=hexed['ctrl'],cfg_before=hexed['cfg'],noise_after=r['noise_after'],ctrl_after=hexed['ctrl_after'],
        load=hex(LOAD),buffer=hex(BUF),seconds=round(seconds,3),sha256=digest,raw_sha256=hashlib.sha256(raw).hexdigest(),
        payload_sha256=hashlib.sha256(payload).hexdigest(),sysmon_before=before,sysmon_after=after,
        time=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),note=NOTE),indent=1)+'\n')
    return {'period':period,'temp_c':[before.get('temp_c'),after.get('temp_c')],'file':files[0].name,'bursts':BURSTS,'symbols':len(data),'cycles':done[-1]-started[0],'seconds':round(seconds,2),'sha256':digest}

if __name__=='__main__':
    if b.case('burst capture payload load',load):
        for p in PERIODS: b.case(f'burst capture, period {p} clocks',lambda p=p:capture(p))
    def cleanup():
        bm.prep();b.rw('pc',bm.SYMS['_start']);b.cmd('riscv exec_progbuf 0x13')
    sys.exit(b.finish(cleanup))
