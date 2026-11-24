# Meter capture: the edge counts of the six ring oscillators against the
# clock and against each other, for the measurement of each ring's own
# jitter. Needs an image with the meter (flow/fpga/karu_rosc_meter.v, built
# after 2026-11-20), DIP switch 4 off, the reset-halted fixture of
# baremetal_phase.py (the one for the image kind, KARU_BOARD_IMAGE), and
# rosc_count.bin and rosc_count.symbols in the artifact directory
# (make dbg-rosc-count-fixture). The capture itself is in DRAM and does not
# depend on the image's map.
#
# For each ring mask and each setting the payload (rosc_count.S) is started
# in M-mode at its load address in DDR. It puts the entropy source in test
# mode, has the meter take a record at every `every`-th raw sample, copies
# the records to memory and stops at its ebreak. While it runs, seed is in
# BIST. Written to the artifact directory:
#
#   rosc-count-p<P>-e<E>-m<mask>.bin   the records as read, 16 bytes each, two
#       little-endian 64-bit words:
#         DATA0  [63] valid, [62] loss, [61:60] sequence number,
#                [59:40] total of ring 2, [39:20] ring 1, [19:0] ring 0
#         DATA1  [63:60] the lane bits at the record's clock edge (bit 60 is
#                lane 0), [59:40] total of ring 5, [39:20] ring 4, [19:0] ring 3
#       A total is a free-running count modulo 2^20; all six and the lane
#       bits are of one clock edge. THE UNIT OF A COUNT IS TWO RING PERIODS:
#       the meter's counters count each ring divided by two. Nothing in the
#       file is multiplied: the sidecar's count_unit says what a count is.
#   rosc-count-p<P>-e<E>-m<mask>.json  clock_hz, period (clocks per raw
#       sample), every, count_unit, ring_mask, stages, runs, the meter's
#       control register read back, mentropycfg and mentropystat before and
#       after, the temperature and supplies before and after, sha256 of the
#       .bin, the time of the capture, note
#
# Records are P * E clocks apart within a run. A run ends when the meter
# reports a loss: the payload was late for a record, the meter dropped it,
# and the next record starts a new run. "runs" lists them: the index of the
# first record, the number of records, and the clock-cycle count before the
# run was started and after it ended. Nothing is known about the time
# between two runs but those stamps: never join them.
# "strap_mask" has the rings that run outside test mode (CTRL[37:32]).
#
# The meter's flags. The meter checks every count against the one before: a
# ring's increment in a clock may not differ from its increment in the clock
# before by more than 2. A count that it could not read, or that does not
# fit, is flagged: "bad_counts" has, for each run, the clock cycles with a
# flagged count (CTRL[63:48] at the end of the run), "bad_rings" the rings
# that had one (CTRL[47:42]), and "run_ctrl" the whole register. A flagged
# count fails no capture here: the case says so in a warning, the analysis
# does not use such a run, and the last entry of the results and the last
# line of this script list every capture that has one.
#
# Direct counting, the cross-check of the divider. With CTRL[28] the counters
# are clocked by the rings themselves, and a count is one ring period. That
# is outside what the part guarantees for a flip-flop at the rate of the
# fastest rings, so it is no way to measure and never carries a bound; it is
# the cross-check that the divider divides by two (rosc_own.py --pair). For
# the first setting with a record every 1,024 clocks (the first
# setting, if there is none), and each ring mask, one capture is taken in
# direct mode just before the divided one:
#
#   rosc-direct-p<P>-e<E>-m<mask>.bin, .json   as above, with count_unit 1
#
# The name keeps it apart from the captures that a claim can rest on.
# rosc_own.py --pair compares the two. In direct mode the meter may flag
# counts with reason, for a counter that is clocked too fast miscounts.
#
# The ring masks. With the default image the two reference rings are off
# outside test mode, and what is measured with them on is not what seed
# sees: a bound can only be claimed from a capture taken with the rings of
# normal operation. So the default is that mask first (0x0f: the four
# lanes), then all six rings (0x3f) as the cross-check.
#
# Then, for each of the six rings, bursts of that ring's count, with all six
# rings on so that every ring's counter is checked: the burst capture block
# records four bits of the ring's count, a count modulo 64, at every clock
# (burst source CTRL[22] of the meter), 32,768 consecutive clocks per burst.
# Two views of each ring: the upper four bits (CTRL[27]), which show the
# step from clock to clock in units of four counts, for a 3-stage ring 2 to
# 4.5 of them; and the lower four, the position of the counter, in which a
# step of more than 16 counts is seen only modulo 16. With direct captures
# on, both views are taken in direct mode as well:
#
#   rosc-burst-r<R>-hi.bin, -lo.bin   the format of getnoise-burst-p<P>.bin:
#                          one byte per value, bits [3:0] bits [5:2] (hi) or
#                          [3:0] (lo) of the count, bit 7 on the first value
#                          of a burst
#   rosc-burst-r<R>-hi.json, -lo.json  as for a burst capture, with "source":
#                          "count", "ring", "view", "count_bits", "count_unit"
#                          and the meter's flags over the capture
#   rosc-direct-burst-r<R>-hi, -lo     the same in direct mode
#
# Last, bursts of the reference bits, in the subdirectory refbits of the
# artifact directory: the meter gives the burst capture block, per sample,
# {reference 1, reference 0, lane 1, lane 0} in bits [3:0] (burst source
# CTRL[26]), with all six rings on, at sampling periods of 1 to 64 clocks.
# Lane 0 and the two reference rings are three rings of one kind, sampled at
# one clock edge: a second measurement of lane 0's own jitter, which does
# not go through the counters (entropy_claim.py --own).
#
#   refbits/getnoise-burst-p<P>.bin    the format of getnoise-burst-p<P>.bin
#   refbits/getnoise-burst-p<P>.json   as for a burst capture, with "source":
#                          "refbits" and "lanes": what the four bits are
#
# These have the names of ordinary burst captures, so that the burst
# analysis reads the directory as it stands; the subdirectory is what keeps
# them apart from captures of the four lanes. Bits 2 and 3 are the reference
# rings, not the 7- and 9-stage lanes.
#
# A capture's files replace the previous ones only when they are complete.
# A capture fails on a payload status other than OK, if test mode was not
# left, and on bookkeeping that does not agree: the period and the control
# register read back, the run table against the record count, the stamps
# against the time the records take, a record without its valid flag or with
# the loss flag, sequence numbers that do not follow each other in a run.
#
#   KARU_BOARD_ROSC_SETTINGS    period x every, comma separated: clocks per raw
#                               sample (1..256) and raw samples per record
#                               (1..65536)            (256x1,256x4,256x16,256x64)
#   KARU_BOARD_ROSC_COUNT       records per setting: one number for all, or one
#                               per setting (1000000; 400000 for records 16384
#                               clocks or more apart). A capture that is to
#                               carry a bound needs 300,000 usable records
#                               (rosc_own.py, MIN_RECORDS); one planned with
#                               fewer is said to be for bring-up, on the
#                               console and in its sidecar (for_bound)
#   KARU_BOARD_ROSC_SCALE       a factor on every record count, the defaults or
#                               those of KARU_BOARD_ROSC_COUNT and of
#                               KARU_BOARD_ROSC_DIRECT_COUNT: 0.1 for a tenth
#                               of the records and of the time                (1)
#   KARU_BOARD_ROSC_DIRECT_COUNT records of each capture in direct mode, before
#                               the scale; 0 for none, which also leaves out
#                               the count bursts in direct mode          (100000)
#   KARU_BOARD_ROSC_MASKS       ring masks, comma separated: ring r in bit r,
#                               rings 0..3 the lanes, 4 and 5 the reference
#                               rings                                (0x0f,0x3f)
#   KARU_BOARD_ROSC_BURSTS      count bursts per ring, view and way of
#                               counting; 0 for none                          (4)
#   KARU_BOARD_ROSC_REF_BURSTS  bursts of the reference bits per sampling
#                               period; 0 for none. KARU_BOARD_ROSC_SCALE
#                               does not apply                              (32)
#   KARU_BOARD_ROSC_REF_PERIODS their sampling periods in clocks, comma
#                               separated                   (1,2,4,8,16,32,64)
#   KARU_BOARD_ROSC_MAX_LOSSES  losses after which a capture still goes on    (16)
#   KARU_BOARD_ROSC_ADDR        load address; the buffer starts 64 KiB above it (0x88000000)
#   KARU_BOARD_ROSC_CLOCK_HZ    the hart's clock, for the sidecar and the waits (75000000)
#   KARU_BOARD_ROSC_WAIT        seconds to wait for one capture      (from the sizes)
#   KARU_BOARD_ROSC_NOTE        free text for the sidecar: bitstream, board, straps, activity
#   KARU_BOARD_ROSC_SLOW        self-test only: the payload spins this many
#                               iterations after every 64th record, so that
#                               records are lost                              (0)
#
# The buffer is read back through the debugger at about 20 KiB/s, so a
# million records take 13 minutes to read, and the default set about an
# hour and 45 minutes, of which the captures in direct mode are three;
# rosc-count-commands.jsonl grows with every block read.
#
# This script captures and checks its bookkeeping. It takes no arguments and
# analyses nothing: the analysis is rosc_own.py, on the record files, and
# getnoise_analyze.py with entropy_claim.py --own on refbits.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import hashlib,struct
if sys.argv[1:]:
    refuse(f"rosc_count.py takes no arguments ({' '.join(sys.argv[1:])}) and analyses nothing. It captures with the settings "
           'in KARU_BOARD_ROSC_*; the analysis of its files is rosc_own.py')
def numbers(name,default,low,high):
    """A comma separated list of numbers from the environment, each in low..high."""
    text=setting(name,default)
    try: values=[int(v,0) for v in text.split(',')]
    except ValueError: refuse(f'{name}={text} is not a comma separated list of numbers')
    for v in values:
        if not low<=v<=high: refuse(f'{name}={text}: {v} is not in {low}..{high}')
    return values
def settings():
    text=setting('KARU_BOARD_ROSC_SETTINGS','256x1,256x4,256x16,256x64');found=[]
    for item in text.lower().split(','):
        try: period,every=(int(v) for v in item.split('x'))
        except ValueError: refuse(f'KARU_BOARD_ROSC_SETTINGS={text}: "{item}" is not <period>x<every>')
        if not (1<=period<=256 and 1<=every<=65536):
            refuse(f'KARU_BOARD_ROSC_SETTINGS={text}: "{item}" is not a period of 1..256 clocks times every 1..65536')
        found.append((period,every))
    return found
SETTINGS=settings()
COUNTS=numbers('KARU_BOARD_ROSC_COUNT',','.join('400000' if p*e>=16384 else '1000000' for p,e in SETTINGS),1,1<<32)
# The usable records a capture needs to carry a bound: those in the blocks of rosc_own.py's fit after flagged runs
# are set aside (its MIN_RECORDS, from its validation with counts of two periods). The default above leaves room
# for exclusions and for the ends of runs that do not fill a block.
MIN_BOUND_RECORDS=300000
if len(COUNTS)==1: COUNTS*=len(SETTINGS)
if len(COUNTS)!=len(SETTINGS):
    refuse(f'KARU_BOARD_ROSC_COUNT has {len(COUNTS)} numbers for {len(SETTINGS)} settings; give one, or one per setting')
try: SCALE=float(setting('KARU_BOARD_ROSC_SCALE',1))
except ValueError: SCALE=0
if not 0<SCALE<float('inf'): refuse(f"KARU_BOARD_ROSC_SCALE={setting('KARU_BOARD_ROSC_SCALE',1)} is not a factor above zero")
COUNTS=[max(1,round(count*SCALE)) for count in COUNTS]
DIRECT_COUNT,=numbers('KARU_BOARD_ROSC_DIRECT_COUNT',100000,0,1<<32)[:1]
DIRECT_COUNT=DIRECT_COUNT and max(1,round(DIRECT_COUNT*SCALE))
DIRECT_AT=next((i for i,(p,e) in enumerate(SETTINGS) if p*e==1024),0)   # the setting that is also captured in direct mode
MASKS=numbers('KARU_BOARD_ROSC_MASKS','0x0f,0x3f',0,0x3f)
BURSTS,=numbers('KARU_BOARD_ROSC_BURSTS',4,0,4096)[:1]
REF_BURSTS,=numbers('KARU_BOARD_ROSC_REF_BURSTS',32,0,4096)[:1]
REF_PERIODS=numbers('KARU_BOARD_ROSC_REF_PERIODS','1,2,4,8,16,32,64',1,256)
SLOW,=numbers('KARU_BOARD_ROSC_SLOW',0,0,1<<32)[:1]
LOAD=int(setting('KARU_BOARD_ROSC_ADDR','0x88000000'),0)
CLOCK_HZ=int(setting('KARU_BOARD_ROSC_CLOCK_HZ',75000000),0)
NOTE=os.environ.get('KARU_BOARD_ROSC_NOTE','')
BUF=LOAD+0x10000
STAGES=[3,5,7,9,3,3]                                # inverters in rings 0..5
BURST_PERIOD=1                                      # count bursts: one value per clock,
BURST_MASK=0x3f                                     # with all six rings on
REF_DIR=OUT/'refbits'                               # the bursts of the reference bits: named as burst captures, kept apart by the directory
REF_LANES=['lane 0','lane 1','reference 0','reference 1']   # bits 0..3 of a reference-bit sample
NBURST=0x10000840                                   # the capture block: status, period, index, data
MAGIC=0x4b4e4231
SYSMON=0x10000860                                   # temperature and supplies (flow/fpga/karu_sysmon.v)
try:
    SYMS={p[2]:int(p[0],16) for line in (OUT/'rosc_count.symbols').read_text().splitlines() if len(p:=line.split())==3}
    payload=(OUT/'rosc_count.bin').read_bytes()
except FileNotFoundError:
    refuse(f'no rosc_count.symbols and rosc_count.bin in {OUT}. Build them: make dbg-rosc-count-fixture DBG_BOARD_OUT={OUT}')
PARAMS,RESULT,RUNS,STOP=(LOAD+SYMS[s] for s in ('rosc_params','rosc_result','rosc_runs','rosc_stop'))
RUNS_MAX=(SYMS['rosc_runs_end']-SYMS['rosc_runs'])//40   # entries of the payload's run table
MAX_LOSSES,=numbers('KARU_BOARD_ROSC_MAX_LOSSES',16,0,RUNS_MAX-1)[:1]
FIELDS=['status','stored','runs','losses','polls','words','nbctrl','period_used','mctrl','cfg','stat','cfg_after','stat_after',
        'noise_after','nbctrl_after','mctrl_after','mcause','mepc','mctrl_end']
STATUS={0:'OK',1:'RUNNING: the payload did not reach its end',
        2:'LOCKED: mentropycfg has its lock bit set; only a reset clears it',
        3:'BUSY: mnoise did not read 1 at entry; the source is already in test mode',
        4:'PARAM: a parameter was rejected',
        5:'NOTEST: test mode was not entered, or the capture block did not allow capturing in it',
        6:'TIMEOUT: no record, or no complete burst; is DIP switch 4 on?',
        7:'TRAP: unexpected trap; at the first CSR access it means an image without KARU_ZKR',
        8:'NOBLOCK: the status register at 0x10000840 does not identify the capture block; the image was built without it',
        9:'PERIOD: the period register did not take the value',
        10:'ABORTED: the noise source was off during a burst (DIP switch 4, or a dead source); earlier bursts are valid but not saved',
        11:'NOMETER: the control register at 0x10000868 did not read back as written; the image has no meter, or one without the reference bits, '
           'the upper view of a count or direct counting',
        12:'LOSSES: more losses than KARU_BOARD_ROSC_MAX_LOSSES; the records come faster than the payload takes them, or the hart was held up',
        (1<<64)-1:'the payload never ran'}
HIGH=bytes(v>>4 for v in range(256))                # the top four bits of DATA0: valid, loss, sequence number
FLAGGED=[]                                          # the captures in which the meter flagged a count: for the summary
def meter_flags(ctrl):
    """From the meter's control register: the clock cycles in which a ring of the mask had a count that
    could not be read or did not fit the one before, and the rings that had one."""
    return ctrl>>48,[ring for ring in range(6) if ctrl>>(42+ring)&1]
def flagged(file,direct,clocks,rings):
    """What a case says of the meter's flags; a capture with flagged clocks goes on the list for the summary.
    It does not fail: the analysis decides what to do with it (rosc_own.py does not use such a run)."""
    if not clocks: return {'flagged_clocks':0}
    FLAGGED.append(dict(file=file,flagged_clocks=clocks,rings=rings,counting='direct' if direct else 'divided by two'))
    return {'flagged_clocks':clocks,'flagged_rings':rings,'warning':f'the meter flagged a count of ring(s) {rings} in {clocks} clock cycle(s)'
            +(': in direct mode the counters are clocked by the rings themselves, which is outside what the part guarantees' if direct else
              ': in the divided mode that is not expected; the analysis does not use such a run')}
import baremetal_phase as bm
bm.b.close();b=bm.b=Board('rosc-count')
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
words=0                                             # 64-bit words per burst, from the hardware
def load():
    global words
    bm.prep()
    ctrl=b.read(NBURST,64,1,'progbuf')[0]
    b.require(ctrl>>32==MAGIC,f'the status register at {NBURST:#x} reads {ctrl:#x}: no capture block in this image, so no meter either')
    b.equal(ctrl&0x2f,0,'capture block at rest: not capturing, nothing held, no test mode, not locked')
    b.require(ctrl&0x10,'the noise source is off: DIP switch 4 is on, or the source failed its start-up test')
    words=1<<(((ctrl>>8)&0xff)-4)
    data=payload+b'\0'*(-len(payload)%4);code=list(struct.unpack(f'<{len(data)//4}I',data))
    b.require(len(data)<=BUF-LOAD,'payload ends below the buffer')
    b.write(LOAD,32,code,'sysbus')
    b.equal(b.read(LOAD,32,len(code),'sysbus'),code,'payload readback')
    b.cmd('riscv mem_access progbuf')
    return {'load':hex(LOAD),'buffer':hex(BUF),'bytes':len(payload),'ctrl':hex(ctrl),'values_per_burst':16*words,'run_table':RUNS_MAX}
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
def execute(params,seconds,period,ctrl):
    """Run the payload once. Returns its result block, the temperature readout before and
    after, and the seconds it ran; fails unless it ended with status OK, at its ebreak, with
    the source as it was found and the period and the meter's control register as asked."""
    bm.prep()
    before=sysmon()
    b.write(PARAMS,64,params+[-1]+[0]*(len(FIELDS)-1),'sysbus')
    b.cmd('riscv mem_access progbuf')
    start=time.monotonic();b.cmd(f'resume {LOAD:#x}')
    wait_halt(float(setting('KARU_BOARD_ROSC_WAIT',seconds)))
    seconds=time.monotonic()-start;pc=b.rr('pc')
    when=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')     # of the capture, not of its files
    r=dict(zip(FIELDS,b.read(RESULT,64,len(FIELDS),'sysbus')))
    b.cmd('riscv mem_access progbuf')
    after=sysmon()
    hexed={f:hex(r[f]) for f in FIELDS[6:]}
    r['time']=when
    if r['status']:
        raise AssertionError(f"payload status {r['status']:#x}, {STATUS.get(r['status'],'unknown')}; pc={pc:#x} "
                             f"stored={r['stored']} runs={r['runs']} losses={r['losses']} {hexed}")
    b.checks+=1
    b.equal(pc,STOP,'stopped at the payload ebreak')
    b.equal(r['noise_after'],1,'test mode left')
    b.equal(r['nbctrl_after']&0x2f,0,'capture block at rest after test mode: nothing held')
    b.equal(r['mctrl_after'],0,'the meter reads zero after test mode')
    b.equal(r['cfg_after'],r['cfg'],'mentropycfg as it was')
    b.equal(r['period_used'],period,'the period the hardware used')
    b.equal(r['mctrl']&0x1fffffff,ctrl,'the control register of the meter, read back')
    return r,hexed,before,after,seconds
def common(r,hexed,before,after,seconds):
    """What every sidecar says about the source and the run of the payload."""
    return dict(clock_hz=CLOCK_HZ,stages=STAGES,ctrl=hexed['mctrl'],strap_mask=(r['mctrl']>>32)&0x3f,
        mentropycfg_before=hexed['cfg'],mentropycfg_after=hexed['cfg_after'],
        mentropystat_before=hexed['stat'],mentropystat_after=hexed['stat_after'],
        burst_ctrl=hexed['nbctrl'],burst_ctrl_after=hexed['nbctrl_after'],noise_after=r['noise_after'],polls=r['polls'],
        load=hex(LOAD),buffer=hex(BUF),seconds=round(seconds,3),payload_sha256=hashlib.sha256(payload).hexdigest(),
        sysmon_before=before,sysmon_after=after,time=r['time'],note=NOTE)
def capture(period,every,mask,count,direct=False):
    """Records of the meter: count records, period * every clocks apart. A count is two ring periods; in direct mode,
    the cross-check of the divider, it is one, and the files are named apart from those that a claim can rest on."""
    name=f"rosc-{'direct' if direct else 'count'}-p{period}-e{every}-m{mask:02x}"
    files=[OUT/(name+'.bin'),OUT/(name+'.json')]
    if direct:
        for_bound,for_bound_why=False,'direct mode: a cross-check of the divider, never a bound'
    elif count<MIN_BOUND_RECORDS:
        for_bound,for_bound_why=False,(f'{count} records, fewer than the {MIN_BOUND_RECORDS} usable records a bound needs: '
                                        'for bringing the instrument up')
        print(f'rosc-count: {name}: {count} records, fewer than {MIN_BOUND_RECORDS}: for bring-up, this capture cannot carry a bound',
              flush=True)
    else:
        for_bound,for_bound_why=True,(f'{count} records; the analysis needs {MIN_BOUND_RECORDS} of them in the blocks of its '
                                       'fit, after runs with a flagged count are set aside and without the ends of runs '
                                       'too short for another block')
    interval=period*every
    idle=interval//4+65536                          # polls for one record; one takes more than four clocks
    r,hexed,before,after,seconds=execute([period-1,every-1,mask,count,BUF,16*count,idle,MAX_LOSSES,0,0,SLOW,int(direct),0],
        30+3*count*interval/CLOCK_HZ,period,(every-1)|mask<<16|direct<<28)
    b.equal(r['stored'],count,'records stored')
    b.require(1<=r['runs']<=r['losses']+1<=MAX_LOSSES+1,f"runs and losses agree: {r['runs']} runs, {r['losses']} losses")
    table=b.read(RUNS,64,5*r['runs'],'sysbus');b.cmd('riscv mem_access progbuf')
    runs=[dict(start=table[i],records=table[i+1],cycle_start=table[i+2],cycle_end=table[i+3]) for i in range(0,len(table),5)]
    b.require(all(run['records']>0 for run in runs),'no run without records in the table')
    b.equal([run['start'] for run in runs]+[count],[0]+[run['start']+run['records'] for run in runs],
            'the runs cover the records: each starts where the one before ended')
    spin=lambda n:16*SLOW*(n//64+1)                 # what the self-test's slowing down may add to a run
    took=[(run['records'],run['cycle_end']-run['cycle_start']) for run in runs]
    b.require(all(t>=(n-1)*interval for n,t in took),'no run ended sooner than its records take')
    b.require(all(t<=(n+3)*interval+4096+spin(n) for n,t in took),'no run took longer than its records take: the source did not pause')
    b.require(all(n['cycle_start']>=d['cycle_end'] for d,n in zip(runs,runs[1:])),'runs follow each other in time')
    start=time.monotonic()
    raw=read_bytes(BUF,16*count);b.cmd('riscv mem_access progbuf')
    read_seconds=time.monotonic()-start
    flags=raw[7::16].translate(HIGH)
    b.require(not flags.translate(None,b'\x08\x09\x0a\x0b'),'every record has its valid flag and no loss flag')
    for i,run in enumerate(runs):
        first,n=run['start'],run['records']
        b.require(flags[first:first+n]==(b'\x08\x09\x0a\x0b'*(n//4+2))[flags[first]&3:][:n],
                  f'the sequence numbers of run {i} follow each other')
    digest=hashlib.sha256(raw).hexdigest()
    bad=[meter_flags(v) for v in table[4::5]]             # per run: the clocks with a flagged count, and the rings
    publish(files,raw,json.dumps(dict(format='karu64-rosc-count-1',kind='records',
        encoding='16 bytes per record, two little-endian 64-bit words as read. DATA0: [63] valid, [62] loss, [61:60] sequence '
                 'number, [59:40] ring 2, [39:20] ring 1, [19:0] ring 0. DATA1: [63:60] lane bits at the record\'s clock edge '
                 '(bit 60 lane 0), [59:40] ring 5, [39:20] ring 4, [19:0] ring 3. Totals: counts modulo 2^20, as read; '
                 'a count is count_unit ring periods',
        count_unit=1 if direct else 2,counting='direct: the counters clocked by the rings themselves, a diagnostic' if direct else
                 'divided: the counters count each ring divided by two',
        for_bound=for_bound,for_bound_why=for_bound_why,
        period=period,every=every,clocks_per_record=interval,ring_mask=mask,requested=count,records=count,
        runs=runs,run_ctrl=[hex(v) for v in table[4::5]],bad_counts=[n for n,_ in bad],bad_rings=[rings for _,rings in bad],
        losses=r['losses'],max_losses=MAX_LOSSES,scale=SCALE,slow=SLOW,
        read_seconds=round(read_seconds,3),sha256=digest,**common(r,hexed,before,after,seconds)),indent=1)+'\n')
    return {'period':period,'every':every,'clocks':interval,'ring_mask':hex(mask),'file':files[0].name,'count_unit':1 if direct else 2,
            'records':count,'for_bound':for_bound,'runs':len(runs),'losses':r['losses'],
            **flagged(files[0].name,direct,sum(n for n,_ in bad),sorted({ring for _,rings in bad for ring in rings})),
            'polls_per_record':round(r['polls']/count,2),'temp_c':[before.get('temp_c'),after.get('temp_c')],
            'seconds':round(seconds,2),'read_seconds':round(read_seconds,2),'sha256':digest}
def bursts(files,mode,ring,period,count,mask,ctrl,what,direct=False,upper=False):
    """Bursts of what the meter gives the capture block in place of the lane bits: `count` bursts, one value per
    `period` clocks. Writes them in the burst capture's format; `what` is what the sidecar says of the values."""
    b.require(words>0,'the payload load case found the capture block')
    values=16*words;record=16+8*words;size=count*record
    idle=values*period//4+65536                     # status polls; one takes more than four clocks
    r,hexed,before,after,seconds=execute([period-1,0,mask,count,BUF,size,idle,0,mode,ring,0,int(direct),int(upper)],
        30+3*count*(values*period+40*words+1000)/CLOCK_HZ,period,ctrl|direct<<28)
    b.equal(r['stored'],count,'bursts stored')
    b.equal(r['words'],words,'words per burst')
    raw=read_bytes(BUF,size);b.cmd('riscv mem_access progbuf')
    data=bytearray();started=[];done=[]
    for i in range(count):
        t0,t1,*w=struct.unpack_from(f'<{2+words}Q',raw,i*record)
        started.append(t0);done.append(t1)
        nibbles=bytearray((x>>(4*s))&15 for x in w for s in range(16))
        nibbles[0]|=0x80
        data+=nibbles
    b.require(all(d-s>=(values-1)*period for s,d in zip(started,done)),'no burst completed sooner than its values take')
    b.require(all(d-s<=(values+1)*period+4096 for s,d in zip(started,done)),'no burst took longer than its values take: the source did not pause')
    b.require(all(n>d for d,n in zip(done,started[1:])),'bursts follow each other in time')
    digest=hashlib.sha256(data).hexdigest()
    clocks,rings=meter_flags(r['mctrl_end'])              # since the control register was written
    files[0].parent.mkdir(exist_ok=True)
    publish(files,bytes(data),json.dumps(dict(format='karu64-getnoise-burst-1',kind='burst',**what,
        period=period,k=1,ring_mask=mask,bursts=count,symbols_per_burst=values,stored=len(data),runs=count,
        run_lengths=[values]*count,burst_cycles=started,burst_done_cycles=done,sha256=digest,
        raw_sha256=hashlib.sha256(raw).hexdigest(),ctrl_end=hexed['mctrl_end'],bad_count=clocks,bad_rings=rings,
        **common(r,hexed,before,after,seconds)),indent=1)+'\n')
    return {'ring_mask':hex(mask),'period':period,'file':str(files[0].relative_to(OUT)),'bursts':count,'values':len(data),
            **flagged(str(files[0].relative_to(OUT)),direct,clocks,rings),
            'temp_c':[before.get('temp_c'),after.get('temp_c')],'seconds':round(seconds,2),'sha256':digest}
def count_bursts(ring,upper,direct=False):
    """Bursts of four bits of one ring's count, one value per clock: of a count modulo 64 its lower four bits, or its
    upper four, which show the step of a count that advances by more than 16 a clock."""
    name=f"rosc-{'direct-' if direct else ''}burst-r{ring}-{'hi' if upper else 'lo'}"
    return bursts([OUT/(name+'.bin'),OUT/(name+'.json')],1,ring,BURST_PERIOD,BURSTS,BURST_MASK,
        BURST_MASK<<16|1<<22|ring<<23|upper<<27,dict(source='count',ring=ring,view='upper' if upper else 'lower',
        count_bits=[5,2] if upper else [3,0],count_unit=1 if direct else 2,
        encoding=f"one byte per value: bits [3:0] are bits {'[5:2]' if upper else '[3:0]'} of the count of ring {ring} at that sample, "
                 f"a count modulo 64 in units of {'one ring period (direct counting)' if direct else 'two ring periods'}"
                 +(': the count divided by four, modulo 16' if upper else ': the count modulo 16')+'; bit 7 first value of a burst'),
        direct,upper)
def ref_bursts(period):
    """Bursts of the reference bits: lanes 0 and 1 and the two reference rings, sampled at one clock edge."""
    return bursts([REF_DIR/f'getnoise-burst-p{period}.bin',REF_DIR/f'getnoise-burst-p{period}.json'],2,0,period,REF_BURSTS,BURST_MASK,
        BURST_MASK<<16|1<<26,dict(source='refbits',lanes=REF_LANES,
        encoding='one byte per sample: bit 0 lane 0, bit 1 lane 1, bit 2 reference ring 0 (ring 4), bit 3 reference ring 1 (ring 5), '
                 'all four of one clock edge; bit 7 first sample of a burst. Bits 2 and 3 are NOT lanes 2 and 3'))

if __name__=='__main__':
    if b.case('meter capture payload load',load):
        for mask in MASKS:
            for i,((period,every),count) in enumerate(zip(SETTINGS,COUNTS)):
                if DIRECT_COUNT and i==DIRECT_AT:   # just before the divided capture that it is compared with
                    b.case(f'meter records in direct mode, ring mask {mask:#04x}, {period} x {every} = {period*every} clocks, {DIRECT_COUNT} records',
                           lambda a=(period,every,mask,DIRECT_COUNT,True):capture(*a))
                b.case(f'meter records, ring mask {mask:#04x}, {period} x {every} = {period*every} clocks, {count} records',
                       lambda a=(period,every,mask,count):capture(*a))
        for direct in ([False,True] if DIRECT_COUNT else [False]) if BURSTS else []:
            for ring in range(6):
                for upper in (True,False):
                    b.case(f"count bursts{' in direct mode' if direct else ''}, ring {ring}, {'upper' if upper else 'lower'} four bits, "
                           f'ring mask {BURST_MASK:#04x}',lambda a=(ring,upper,direct):count_bursts(*a))
        for period in REF_PERIODS if REF_BURSTS else []:
            b.case(f'reference bits, period {period} clocks, ring mask {BURST_MASK:#04x}',lambda period=period:ref_bursts(period))
        # Flagged clocks fail no capture, so they are listed once more where nobody can overlook them.
        b.record(dict(name='captures with flagged clocks',status='PASS',checks=0,seconds=0,
                      detail=FLAGGED or 'none: in no capture did the meter flag a count'))
    def cleanup():
        bm.prep();b.rw('pc',bm.SYMS['_start']);b.cmd('riscv exec_progbuf 0x13')
    status=b.finish(cleanup)
    print(f'rosc-count: {len(FLAGGED)} capture(s) in which the meter flagged a count'
          +''.join(f"; {x['file']} ({x['counting']}): {x['flagged_clocks']} clock(s), ring(s) {x['rings']}" for x in FLAGGED),flush=True)
    sys.exit(status)
