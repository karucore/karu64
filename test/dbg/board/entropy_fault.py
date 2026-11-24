#!/usr/bin/env python3
# Induced health-test failures on the real rings: the failure handling of
# rtl/karu_entropy.v (SP 800-90B section 4.3 item 2) on the board, where
# simulation and replay showed it before. Not an acceptance phase.
#
# Software may make the tests stricter through mentropycfg, never weaker. A
# cutoff far below its reset value makes the real source fail that test
# within seconds, so the board shows, on real noise:
#   1. a failure during the start-up test is fatal at once and is no alarm;
#   2. each of the two tests fires, the repetition count and the adaptive
#      proportion test, and mentropystat names it, with the lane that is
#      the source (and the lags, for the repetition count);
#   3. a running failure latches the alarm: seed reports BIST until one seed
#      access has seen it; a mentropycfg write clears neither the alarm nor
#      the strike; the third running failure without 2^24 clean samples in
#      between is fatal, and seed then reports DEAD;
#   4. 2^24 clean samples after a running failure clear the strike;
#   5. the build's limits: values weaker than the reset configuration are
#      replaced by the limit, the reserved fields stay zero, the spacing
#      outside test mode stays at the floor that mentropystat shows
#      (measured through seed with seedcap.S), and the lock freezes the
#      configuration until reset.
# Every case starts from a debugger reset (ndmreset), which clears
# mentropystat, the strikes and the lock, and reads the straps from
# mentropystat: the lane that is the source, and the shift of the spacing
# floor (k at least 16, 32, 64 or 128), which sets the reset value of
# mentropycfg and every time below. The hart stays halted while the source
# runs, so nothing but this phase reads seed.
#
# Output: entropy-fault-results.json (per case: the mentropystat readings
# with times), and the command trace. Case 4 takes about 16 minutes at
# k = 16, and in proportion to k.
# Needs: server.cfg, lifecycle OPEN, DIP switch 4 off, the fixtures of make
# dbg-board-fixture and dbg-seedcap-fixture. Leaves the hart halted after a
# final reset.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import struct
bm.b.close(); b = bm.b = Board('entropy-fault')

CFG, STAT, SEED = 0x7C9, 0x7CA, 0x015
CFG_CUTOFFS = 0x30c0000b3c370000             # mentropycfg after reset, without the interval
FIELD = dict(interval=(0, 16), rct=(16, 10), apt=(26, 11), reserved=(37, 17), strikes=(54, 3), calm=(57, 5), bit62=(62, 1), lock=(63, 1))
CAUSE = dict(rct=4, apt=8)
# Cutoffs far below the reset values (55 and 719), which the real ring fails
# within seconds and seldom within the 1,024 samples of a start-up test: for
# independent fair bits a repetition count of 18 is reached at one of the
# four lags about every 2^16 samples, and 550 of 1,024 in one window in a
# hundred.
STRICT = dict(rct=18, apt=550)
STRAP = dict(lane=0, kshift=0)               # read from mentropystat after every reset
def reset_cfg(): return CFG_CUTOFFS | ((16 << STRAP['kshift']) - 1)    # the interval after reset is the spacing floor
def sample_s(): return 256 * (16 << STRAP['kshift']) / 75e6             # one sample at the reset spacing
def slow(): return 1 << STRAP['kshift']                                  # how much longer everything takes than at k = 16
CSRRW_T0_SEED = 0x015012f3                   # csrrw t0, seed, zero
LOAD = 0x88000000
BUF = LOAD + 0x10000
SYMS = {p[2]: int(p[0], 16) for line in (OUT/'seedcap.symbols').read_text().splitlines() if len(p := line.split()) == 3}
PARAMS, RESULT = (LOAD + SYMS[s] for s in ('seedcap_params', 'seedcap_result'))
FIELDS = ['status', 'stored', 'bist', 'wait', 'cyc_entry', 'cyc_first', 'cyc_end', 'max_gap', 'stat_end', 'cfg_end', 'mcause', 'mepc']

def get(v, name):
    lo, n = FIELD[name]; return (v >> lo) & ((1 << n) - 1)
def put(v, name, x):
    lo, n = FIELD[name]; m = ((1 << n) - 1) << lo
    return (v & ~m) | ((x << lo) & m)
def decode(s):
    return dict(state=s & 3, alarm=(s >> 2) & 1, strikes=(s >> 4) & 7, cause=(s >> 8) & 15,
                lanes=(s >> 12) & 15, lags=(s >> 16) & 15, lane=(s >> 20) & 3, kshift=(s >> 22) & 3, failures=(s >> 32) & 0xffff)

T0 = [0.0]
log = []
def stat(note=''):
    s = decode(b.rawread(STAT)); s['t'] = round(time.monotonic() - T0[0], 3)
    if note: s['note'] = note
    if not log or {k: v for k, v in log[-1].items() if k not in ('t', 'note')} != {k: v for k, v in s.items() if k not in ('t', 'note')} or note:
        log.append(s)
    return s
def seed_access(note):
    bm.pb([CSRRW_T0_SEED])
    v = b.rawread(0x1005)
    log.append(dict(seed=hex(v), opst=(v >> 30) & 3, t=round(time.monotonic() - T0[0], 3), note=note))
    return (v >> 30) & 3
def fresh():
    """A debugger reset, the straps, then wait for the start-up test to pass."""
    b.reset_halt(); bm.prep(); T0[0] = time.monotonic(); log.clear()
    s = stat('after reset')
    STRAP.update(lane=s['lane'], kshift=s['kshift'])
    b.require(s['failures'] == 0 and s['strikes'] == 0 and s['alarm'] == 0 and s['cause'] == 0 and s['lanes'] == 0,
              f'mentropystat after reset: no failure on record: {s}')
    b.equal(b.rawread(CFG), reset_cfg(), f"mentropycfg after reset, for the spacing floor k = {16 << STRAP['kshift']}")
    until(lambda s: s['state'] == 1, 2 * slow(), 'start-up test passed')
def until(pred, seconds, what, interval=0.02):
    end = time.monotonic() + seconds
    while True:
        s = stat()
        if pred(s): return s
        if time.monotonic() > end: raise AssertionError(f'{what}: not within {seconds} s; last {s}')
        time.sleep(interval)

def source_lane(s):
    return s['lanes'] == 1 << STRAP['lane'] and s['lane'] == STRAP['lane'] and s['kshift'] == STRAP['kshift']

def case_startup():
    fresh()
    b.rawwrite(CFG, put(reset_cfg(), 'rct', 2))     # any sample equal to one of the four before it fails
    s = until(lambda s: s['state'] == 2, 2 * slow(), 'dead')
    b.require(s['cause'] == CAUSE['rct'] and s['failures'] == 1 and s['alarm'] == 0 and s['strikes'] == 0 and s['lags'] != 0 and source_lane(s),
              f'start-up failure: dead, repetition on the source lane, one failure, no alarm, no strike: {s}')
    b.equal(seed_access('after the start-up failure'), 3, 'seed reports DEAD')
    time.sleep(1)
    b.equal(stat('one second later')['state'], 2, 'still dead')
    return dict(log=list(log))

def case_each_test():
    out = {}
    for name, value in STRICT.items():
        fresh()
        b.rawwrite(CFG, put(reset_cfg(), name, value))
        s = until(lambda s: s['failures'] >= 1, 120 * slow(), f'{name} = {value}: a failure', interval=0.05)
        b.require(s['cause'] == CAUSE[name], f'{name} = {value}: cause names that test alone: {s}')
        b.require(source_lane(s), f"{name}: the lane reported is the source, lane {STRAP['lane']}, and no other: {s}")
        b.require((s['lags'] != 0) == (name == 'rct'), f'{name}: lags are reported for the repetition count only: {s}')
        kind = 'running' if s['alarm'] else 'start-up'
        if kind == 'running':
            b.require(s['strikes'] >= 1, f'{name}: a running failure counts a strike: {s}')
        else:
            b.require(s['state'] == 2 and s['strikes'] == 0, f'{name}: a start-up failure is fatal, no strike: {s}')
        out[name] = dict(cutoff=value, kind=kind, first_failure_s=s['t'], stat=s)
    out['lane'], out['kshift'] = STRAP['lane'], STRAP['kshift']
    return out

def case_strikes():
    for attempt in range(3):
        fresh()
        strict = put(reset_cfg(), 'rct', STRICT['rct'])
        b.rawwrite(CFG, strict)
        s = until(lambda s: s['failures'] >= 1, 120 * slow(), 'first failure', interval=0.05)
        if s['state'] == 2 and s['strikes'] == 0:
            continue                                  # failed its start-up test: that is case 1
        b.require(s['alarm'] == 1 and s['strikes'] >= 1 and s['cause'] == CAUSE['rct'] and source_lane(s), f'first running failure: {s}')
        before = s['strikes']
        b.rawwrite(CFG, strict)                       # a write restarts the start-up test...
        s = stat('after a mentropycfg write')
        b.require(s['alarm'] == 1 and s['strikes'] >= before, f'...and clears neither the alarm nor the strike: {s}')
        before = s['strikes']
        b.equal(seed_access('the access that sees the alarm'), 0, 'seed reports BIST while the alarm is latched')
        s = stat('after that access')
        b.require(s['alarm'] == 0 and s['strikes'] >= before, f'one seed access cleared the alarm, not the strike: {s}')
        s = until(lambda s: s['state'] == 2, 300 * slow(), 'dead after strikes', interval=0.05)
        b.require(s['failures'] >= 2, f'dead after more than one failure: {s}')
        if not (s['strikes'] == 3 and s['failures'] == 3):
            continue                                  # a retest failed first: fatal too, but not the path under test
        b.equal(seed_access('dead'), 3, 'seed reports DEAD')
        return dict(path='third strike', attempt=attempt+1, log=list(log))
    raise AssertionError('no run reached DEAD by a third strike in three attempts')

def case_forgive():
    for attempt in range(3):
        fresh()
        b.rawwrite(CFG, put(reset_cfg(), 'rct', STRICT['rct']))
        s = until(lambda s: s['failures'] >= 1, 120 * slow(), 'first failure', interval=0.05)
        if s['state'] != 2: break                     # a running failure, not a failed start-up test
    else:
        raise AssertionError(f'three start-up failures: {s}')
    t_fail = s['t']
    b.rawwrite(CFG, reset_cfg())                      # back to the reset cutoffs
    s = stat('reset cutoffs written')
    b.require(s['strikes'] == 1, f'the strike survives the write: {s}')
    seed_access('clear the alarm')
    calm_s = (1 << get(reset_cfg(), 'calm')) * sample_s()
    s = until(lambda s: s['strikes'] == 0 or s['failures'] > 1, calm_s * 1.2 + 60, 'strike cleared', interval=5)
    b.require(s['strikes'] == 0 and s['failures'] == 1 and s['state'] == 1, f'the strike cleared without another failure: {s}')
    took = s['t'] - t_fail
    b.require(calm_s * 0.97 < took < calm_s * 1.03 + 10, f'after 2^24 samples ({calm_s:.0f} s): took {took:.0f} s')
    return dict(expected_s=round(calm_s, 1), took_s=round(took, 1), log=list(log))

def case_limits():
    fresh()
    # the straps, and what follows from them: the floor is the reset value of the interval
    s = stat('the straps')
    lane, k_floor = s['lane'], 16 << s['kshift']
    b.equal(get(reset_cfg(), 'interval'), k_floor - 1, f'the interval after reset is the floor that mentropystat shows, k = {k_floor}')
    weak = reset_cfg()
    for name, x in (('interval', 0), ('rct', 1023), ('apt', 2047), ('reserved', 0x1ffff), ('bit62', 1), ('strikes', 7), ('calm', 0)):
        weak = put(weak, name, x)
    b.rawwrite(CFG, weak)
    got = b.rawread(CFG)
    for name in ('rct', 'apt', 'strikes', 'calm'):
        b.equal(get(got, name), get(reset_cfg(), name), f'{name}: a weaker value is replaced by the limit')
    b.equal((get(got, 'reserved'), get(got, 'bit62')), (0, 0), 'the reserved fields read zero after ones were written')
    b.equal(get(got, 'interval'), 0, 'the interval reads back as written')
    # the spacing actually used: time seed words with seedcap.S. Words come
    # four at a time, so from the first word to the 65th are sixteen bursts.
    WORDS = 65
    word = 16 * 256 * k_floor                         # clocks for the sixteen samples of a word at the floor
    data = (OUT/'seedcap.bin').read_bytes(); data += b'\0'*(-len(data) % 4)
    b.write(LOAD, 32, list(struct.unpack(f'<{len(data)//4}I', data)), 'sysbus')
    b.write(PARAMS, 64, [WORDS, BUF, 1 << 26], 'sysbus')
    b.write(RESULT, 64, [-1] + [0]*(len(FIELDS)-1), 'sysbus')
    b.cmd('riscv mem_access progbuf')
    b.rawwrite(CFG, got)                              # the same value again: the start-up test restarts, and the
    b.resume(LOAD)                                    # payload is polling before the first word is there
    end = time.monotonic() + 5 * slow()
    while b.cmd('karu.cpu curstate') != 'halted':
        if time.monotonic() > end: b.halt(); raise AssertionError('seedcap did not finish')
        time.sleep(0.02); b.cmd('poll')
    r = dict(zip(FIELDS, b.read(RESULT, 64, len(FIELDS), 'sysbus'))); b.cmd('riscv mem_access progbuf')
    b.equal(r['status'], 0, 'seedcap status')
    per_word = (r['cyc_end'] - r['cyc_first']) / (WORDS - 1)
    b.require(word * 0.9 < per_word < word * 1.25,
              f'outside test mode the source keeps the floor, k = {k_floor}: {per_word:.0f} clocks per word of sixteen samples (k = 1 would be 4,096)')
    s = decode(r['stat_end'])
    b.require(s['lane'] == lane and s['kshift'] == STRAP['kshift'] and s['failures'] == 0, f'the straps as before, no failure: {s}')
    b.rawwrite(CFG, got | (1 << 63))
    locked = b.rawread(CFG)
    b.require(locked >> 63 == 1, 'the lock bit is set')
    b.rawwrite(CFG, put(locked, 'rct', STRICT['rct']))
    b.equal(b.rawread(CFG), locked, 'a write to the locked CSR changes nothing')
    b.reset_halt(); bm.prep()
    b.equal(b.rawread(CFG), reset_cfg(), 'a reset clears the lock and restores the reset value')
    return dict(lane=lane, kshift=STRAP['kshift'], k_floor=k_floor, written=hex(weak), read_back=hex(got),
                clocks_per_word=round(per_word), locked=hex(locked))

if __name__ == '__main__':
    only = os.environ.get('KARU_BOARD_FAULT_CASES', 'startup,each,strikes,forgive,limits').split(',')
    cases = dict(startup=('a start-up failure is fatal at once and is no alarm', case_startup),
                 each=('each test fires on the real ring and mentropystat names it', case_each_test),
                 strikes=('alarm latch, strikes, DEAD', case_strikes),
                 forgive=('2^24 clean samples clear a strike', case_forgive),
                 limits=('build limits, the straps, spacing and lock', case_limits))
    for key in only:
        b.case(cases[key][0], cases[key][1])
    b.restore('the cases', lambda: (b.reset_halt(), bm.prep()))
    sys.exit(b.finish())
