# GetNoise: raw noise capture from the entropy source through mnoise, at one
# or more decimations k. Needs an image built with KARU_ZKR, DIP switch 4
# off, the reset-halted fixture of baremetal_phase.py (the one for the image
# kind, KARU_BOARD_IMAGE), and getnoise.bin and getnoise.symbols in the
# artifact directory (make dbg-getnoise-fixture). The capture itself is in
# DRAM and does not depend on the image's map.
#
# For each k the payload (getnoise.S) is started in M-mode at its load
# address in DDR, stops at its ebreak, and leaves a result block and one byte
# per symbol. Written to the artifact directory:
#
#   getnoise-k<k>.bin    the buffer as captured: bits [3:0] the symbol (lane i
#                        in bit i), bit 7 on the first symbol of a run
#   getnoise-k<k>.json   parameters, counts, run lengths, mentropycfg before,
#                        during and after, sha256 of the .bin
#
# A capture fails on a payload status other than OK (a locked mentropycfg
# among them), on inconsistent run bookkeeping, if the configuration was not
# restored or test mode not left, and if no run reaches the minimum length.
#
#   KARU_BOARD_GETNOISE_K        decimations, comma separated   (1,2,4,8,16,32)
#   KARU_BOARD_GETNOISE_COUNT    symbols per capture            (1000000)
#   KARU_BOARD_GETNOISE_MIN_RUN  required longest run           (4096)
#   KARU_BOARD_GETNOISE_ADDR     load address; the buffer starts 64 KiB above it (0x88000000)
#   KARU_BOARD_GETNOISE_WAIT     seconds to wait for one capture (from count and k)
#   KARU_BOARD_GETNOISE_NOTE     free text for the sidecar: bitstream, board, temperature
#
# The sidecar also holds the FPGA's die temperature and supply voltages (the
# readout at 0x1000_0860, in images built after 2026-11-18; older images read
# 0 there) before and after the capture. A capture's files replace the
# previous ones only when they are complete.
#
# Analysis is offline: getnoise_analyze.py.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import hashlib,re,struct
bm.b.close();b=bm.b=Board('getnoise')
KS=[int(k,0) for k in setting('KARU_BOARD_GETNOISE_K','1,2,4,8,16,32').split(',')]
COUNT=int(setting('KARU_BOARD_GETNOISE_COUNT',1000000),0)
MIN_RUN=int(setting('KARU_BOARD_GETNOISE_MIN_RUN',4096),0)
LOAD=int(setting('KARU_BOARD_GETNOISE_ADDR','0x88000000'),0)
NOTE=os.environ.get('KARU_BOARD_GETNOISE_NOTE','')
BUF=LOAD+0x10000
RAW_SECONDS=256/75e6                                # one raw symbol: 256 clocks at 75 MHz
SYMS={p[2]:int(p[0],16) for line in (OUT/'getnoise.symbols').read_text().splitlines() if len(p:=line.split())==3}
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
PARAMS,RESULT,STOP=(LOAD+SYMS[s] for s in ('getnoise_params','getnoise_result','getnoise_stop'))
FIELDS=['status','stored','runs','losses','polls','cfg_before','cfg_used','cfg_after','noise_after','mcause','mepc']
STATUS={0:'OK',1:'RUNNING: the payload did not reach its end',
        2:'LOCKED: mentropycfg has its lock bit set; only a reset clears it',
        3:'BUSY: mnoise did not read 1 at entry; the source is already in test mode',
        4:'PARAM: count, buffer size or idle limit rejected',
        5:'NOTEST: the write to mnoise did not enter test mode',
        6:'TIMEOUT: no symbols; is DIP switch 4 on, or the decimation too small for the capture loop?',
        7:'TRAP: unexpected trap; at the first CSR access it means an image without KARU_ZKR',
        (1<<64)-1:'the payload never ran'}
payload=(OUT/'getnoise.bin').read_bytes()
def load():
    bm.prep()
    data=payload+b'\0'*(-len(payload)%4);words=list(struct.unpack(f'<{len(data)//4}I',data))
    b.require(len(data)<=BUF-LOAD,'payload ends below the buffer')
    b.write(LOAD,32,words,'sysbus')
    b.equal(b.read(LOAD,32,len(words),'sysbus'),words,'payload readback')
    b.cmd('riscv mem_access progbuf')
    return {'load':hex(LOAD),'buffer':hex(BUF),'bytes':len(payload)}
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
        words=b.read(addr+off,64,min(chunk,(n-off+7)//8),'sysbus')
        data+=struct.pack(f'<{len(words)}Q',*words)
    return bytes(data[:n])
def capture(k):
    b.require(1<=k<=65536,'k is 1..65536')
    files=[OUT/f'getnoise-k{k}.bin',OUT/f'getnoise-k{k}.json']
    bm.prep()
    before=sysmon()
    idle=64*k+4096                                  # polls; an idle poll takes more than 4 clocks, a symbol 256*k
    b.write(PARAMS,64,[k-1,COUNT,BUF,COUNT,idle,-1]+[0]*(len(FIELDS)-1),'sysbus')
    b.cmd('riscv mem_access progbuf')
    start=time.monotonic();b.cmd(f'resume {LOAD:#x}')
    wait_halt(float(setting('KARU_BOARD_GETNOISE_WAIT',30+3*COUNT*k*RAW_SECONDS)))
    seconds=time.monotonic()-start;pc=b.rr('pc')
    r=dict(zip(FIELDS,b.read(RESULT,64,len(FIELDS),'sysbus')))
    b.cmd('riscv mem_access progbuf')
    after=sysmon()
    hexed={f:hex(r[f]) for f in ('cfg_before','cfg_used','cfg_after','noise_after','mcause','mepc')}
    if r['status']: raise AssertionError(f"payload status {r['status']:#x}, {STATUS.get(r['status'],'unknown')}; pc={pc:#x} {hexed}")
    b.checks+=1
    b.equal(pc,STOP,'stopped at the payload ebreak')
    b.equal(r['cfg_after'],r['cfg_before'],'mentropycfg restored')
    b.equal(r['noise_after'],1,'test mode left')
    b.equal(r['cfg_used'],(r['cfg_before']&~0xffff)|(k-1),'the source took the interval and kept the cutoffs')
    b.equal(r['stored'],COUNT,'symbols stored')
    data=read_bytes(BUF,COUNT);b.cmd('riscv mem_access progbuf')
    runs=[len(run) for run in re.findall(rb'[\x80-\x8f][\x00-\x0f]*',data)]
    b.equal(sum(runs),COUNT,'buffer: first symbol flagged, bits [6:4] clear')
    b.equal(len(runs),r['runs'],'run flags in the buffer against the payload run count')
    b.require(r['runs']<=r['losses']+1,'no more runs than losses allow')
    digest=hashlib.sha256(data).hexdigest()
    publish(files,data,json.dumps(dict(format='karu64-getnoise-1',
        encoding='one byte per symbol: bits [3:0] symbol, lane i in bit i; bit 7 first symbol of a run',
        k=k,interval=k-1,requested=COUNT,stored=r['stored'],runs=len(runs),run_lengths=runs,longest_run=max(runs),min_run=MIN_RUN,
        losses=r['losses'],polls=r['polls'],cfg_before=hexed['cfg_before'],cfg_used=hexed['cfg_used'],cfg_after=hexed['cfg_after'],
        rct_cutoff=(r['cfg_before']>>16)&0x3ff,apt_cutoff=(r['cfg_before']>>26)&0x7ff,
        symbol_rct_cutoff=(r['cfg_before']>>37)&0x7f,symbol_apt_cutoff=(r['cfg_before']>>44)&0x3ff,
        strikes=(r['cfg_before']>>54)&7,calm_log2=(r['cfg_before']>>57)&31,noise_after=r['noise_after'],
        load=hex(LOAD),buffer=hex(BUF),seconds=round(seconds,3),sha256=digest,payload_sha256=hashlib.sha256(payload).hexdigest(),
        sysmon_before=before,sysmon_after=after,
        time=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),note=NOTE),indent=1)+'\n')
    b.require(max(runs)>=MIN_RUN,f'longest run {max(runs)} of {len(runs)} is shorter than {MIN_RUN}: the capture loop loses symbols at k={k}')
    return {'k':k,'file':files[0].name,'symbols':COUNT,'runs':len(runs),'longest_run':max(runs),'losses':r['losses'],'seconds':round(seconds,2),'sha256':digest}

if __name__=='__main__':
    if b.case('GetNoise payload load',load):
        for k in KS: b.case(f'GetNoise capture, decimation k={k}',lambda k=k:capture(k))
    def cleanup():
        bm.prep();b.rw('pc',bm.SYMS['_start']);b.cmd('riscv exec_progbuf 0x13')
    sys.exit(b.finish(cleanup))
