#!/usr/bin/env python3
# Induced health-test failures on the real rings: the failure handling of
# rtl/karu_entropy.v (SP 800-90B section 4.3 item 2) on the board, where
# simulation and replay showed it before. Not an acceptance phase.
#
# Software may make the tests stricter through mentropycfg, never weaker. A
# cutoff far below its reset value makes the real source fail that test
# within seconds, so the board shows, on real noise:
#   1. a failure during the start-up test is fatal at once and is no alarm;
#   2. each of the four tests fires, and mentropystat names it (and the
#      lanes and lags for the lane tests);
#   3. a running failure latches the alarm: seed reports BIST until one seed
#      access has seen it; a mentropycfg write clears neither the alarm nor
#      the strike; the third running failure without 2^24 clean samples in
#      between is fatal, and seed then reports DEAD;
#   4. 2^24 clean samples after a running failure clear the strike;
#   5. the build's limits: values weaker than the reset configuration are
#      replaced by the limit, the spacing outside test mode stays at the
#      build's (measured through seed with seedcap.S), and the lock freezes
#      the configuration until reset.
# Every case starts from a debugger reset (ndmreset), which clears
# mentropystat, the strikes and the lock. The hart stays halted while the
# source runs, so nothing but this phase reads seed.
#
# Output: entropy-fault-results.json (per case: the mentropystat readings
# with times), and the command trace. Case 4 takes about 16 minutes.
# Needs: server.cfg, lifecycle OPEN, DIP switch 4 off, the fixtures of make
# dbg-board-fixture and dbg-seedcap-fixture. Leaves the hart halted after a
# final reset.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import struct
bm.b.close(); b = bm.b = Board('entropy-fault')

CFG, STAT, SEED = 0x7C9, 0x7CA, 0x015
RESET_CFG = 0x30c7c1eb3c37000f
FIELD = dict(interval=(0, 16), rct=(16, 10), apt=(26, 11), srct=(37, 7), sapt=(44, 10), strikes=(54, 3), calm=(57, 5), lock=(63, 1))
CAUSE = dict(srct=1, sapt=2, rct=4, apt=8)
SAMPLE_S = 4096 / 75e6                       # one kept sample at the reset spacing
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
                lanes=(s >> 12) & 15, lags=(s >> 16) & 15, failures=(s >> 32) & 0xffff)

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
    """A debugger reset, then wait for the start-up test to pass."""
    b.reset_halt(); bm.prep(); T0[0] = time.monotonic(); log.clear()
    b.equal(b.rawread(CFG), RESET_CFG, 'mentropycfg after reset')
    until(lambda s: s['state'] == 1, 2, 'start-up test passed')
def until(pred, seconds, what, interval=0.02):
    end = time.monotonic() + seconds
    while True:
        s = stat()
        if pred(s): return s
        if time.monotonic() > end: raise AssertionError(f'{what}: not within {seconds} s; last {s}')
        time.sleep(interval)

def case_startup():
    fresh()
    b.rawwrite(CFG, put(RESET_CFG, 'srct', 2))      # any two equal samples in a row fail
    s = until(lambda s: s['state'] == 2, 2, 'dead')
    b.require(s['cause'] == CAUSE['srct'] and s['failures'] == 1 and s['alarm'] == 0 and s['strikes'] == 0,
              f'start-up failure: dead, symbol repetition, one failure, no alarm, no strike: {s}')
    b.equal(seed_access('after the start-up failure'), 3, 'seed reports DEAD')
    time.sleep(1)
    b.equal(stat('one second later')['state'], 2, 'still dead')
    return dict(log=list(log))

def case_each_test():
    out = {}
    for name, value in (('srct', 5), ('sapt', 46), ('rct', 21), ('apt', 550)):
        fresh()
        b.rawwrite(CFG, put(RESET_CFG, name, value))
        s = until(lambda s: s['failures'] >= 1, 120, f'{name} = {value}: a failure', interval=0.05)
        b.require(s['cause'] == CAUSE[name], f'{name} = {value}: cause names that test alone: {s}')
        if name in ('rct', 'apt'): b.require(s['lanes'] != 0, f'{name}: the failing lanes are reported: {s}')
        if name == 'rct': b.require(s['lags'] != 0, f'rct: the failing lags are reported: {s}')
        kind = 'running' if s['alarm'] else 'start-up'
        if kind == 'running':
            b.require(s['strikes'] >= 1, f'{name}: a running failure counts a strike: {s}')
        else:
            b.require(s['state'] == 2 and s['strikes'] == 0, f'{name}: a start-up failure is fatal, no strike: {s}')
        out[name] = dict(cutoff=value, kind=kind, first_failure_s=s['t'], stat=s)
    return out

def case_strikes():
    for attempt in range(3):
        fresh()
        strict = put(RESET_CFG, 'srct', 5)
        b.rawwrite(CFG, strict)
        s = until(lambda s: s['failures'] >= 1, 120, 'first failure', interval=0.05)
        if s['state'] == 2 and s['strikes'] == 0:
            continue                                  # failed its start-up test: that is case 1
        b.require(s['alarm'] == 1 and s['strikes'] >= 1 and s['cause'] == CAUSE['srct'], f'first running failure: {s}')
        before = s['strikes']
        b.rawwrite(CFG, strict)                       # a write restarts the start-up test...
        s = stat('after a mentropycfg write')
        b.require(s['alarm'] == 1 and s['strikes'] >= before, f'...and clears neither the alarm nor the strike: {s}')
        before = s['strikes']
        b.equal(seed_access('the access that sees the alarm'), 0, 'seed reports BIST while the alarm is latched')
        s = stat('after that access')
        b.require(s['alarm'] == 0 and s['strikes'] >= before, f'one seed access cleared the alarm, not the strike: {s}')
        s = until(lambda s: s['state'] == 2, 300, 'dead after strikes', interval=0.05)
        b.require(s['failures'] >= 2, f'dead after more than one failure: {s}')
        if not (s['strikes'] == 3 and s['failures'] == 3):
            continue                                  # a retest failed first: fatal too, but not the path under test
        b.equal(seed_access('dead'), 3, 'seed reports DEAD')
        return dict(path='third strike', attempt=attempt+1, log=list(log))
    raise AssertionError('no run reached DEAD by a third strike in three attempts')

def case_forgive():
    for attempt in range(3):
        fresh()
        b.rawwrite(CFG, put(RESET_CFG, 'srct', 5))
        s = until(lambda s: s['failures'] >= 1, 120, 'first failure', interval=0.05)
        if s['state'] != 2: break                     # a running failure, not a failed start-up test
    else:
        raise AssertionError(f'three start-up failures: {s}')
    t_fail = s['t']
    b.rawwrite(CFG, RESET_CFG)                        # back to the reset cutoffs
    s = stat('reset cutoffs written')
    b.require(s['strikes'] == 1, f'the strike survives the write: {s}')
    seed_access('clear the alarm')
    calm_s = (1 << get(RESET_CFG, 'calm')) * SAMPLE_S
    s = until(lambda s: s['strikes'] == 0 or s['failures'] > 1, calm_s * 1.2 + 60, 'strike cleared', interval=5)
    b.require(s['strikes'] == 0 and s['failures'] == 1 and s['state'] == 1, f'the strike cleared without another failure: {s}')
    took = s['t'] - t_fail
    b.require(calm_s * 0.97 < took < calm_s * 1.03 + 10, f'after 2^24 samples ({calm_s:.0f} s): took {took:.0f} s')
    return dict(expected_s=round(calm_s, 1), took_s=round(took, 1), log=list(log))

def case_limits():
    fresh()
    weak = RESET_CFG
    for name, x in (('interval', 0), ('rct', 1023), ('apt', 2047), ('srct', 127), ('sapt', 1023), ('strikes', 7), ('calm', 0)):
        weak = put(weak, name, x)
    b.rawwrite(CFG, weak)
    got = b.rawread(CFG)
    for name in ('rct', 'apt', 'srct', 'sapt', 'strikes', 'calm'):
        b.equal(get(got, name), get(RESET_CFG, name), f'{name}: a weaker value is replaced by the limit')
    b.equal(get(got, 'interval'), 0, 'the interval reads back as written')
    # the spacing actually used: time 250 seed words with seedcap.S
    data = (OUT/'seedcap.bin').read_bytes(); data += b'\0'*(-len(data) % 4)
    b.write(LOAD, 32, list(struct.unpack(f'<{len(data)//4}I', data)), 'sysbus')
    b.write(PARAMS, 64, [250, BUF, 1 << 26], 'sysbus')
    b.write(RESULT, 64, [-1] + [0]*(len(FIELDS)-1), 'sysbus')
    b.cmd('riscv mem_access progbuf')
    b.resume(LOAD)
    end = time.monotonic() + 5
    while b.cmd('karu.cpu curstate') != 'halted':
        if time.monotonic() > end: b.halt(); raise AssertionError('seedcap did not finish')
        time.sleep(0.02); b.cmd('poll')
    r = dict(zip(FIELDS, b.read(RESULT, 64, len(FIELDS), 'sysbus'))); b.cmd('riscv mem_access progbuf')
    b.equal(r['status'], 0, 'seedcap status')
    per_word = (r['cyc_end'] - r['cyc_first']) / 249
    b.require(16384 * 0.9 < per_word < 16384 * 1.25, f'outside test mode the source keeps k = 16: {per_word:.0f} clocks per word (k = 1 would be 1,024)')
    b.rawwrite(CFG, got | (1 << 63))
    locked = b.rawread(CFG)
    b.require(locked >> 63 == 1, 'the lock bit is set')
    b.rawwrite(CFG, put(locked, 'srct', 5))
    b.equal(b.rawread(CFG), locked, 'a write to the locked CSR changes nothing')
    b.reset_halt(); bm.prep()
    b.equal(b.rawread(CFG), RESET_CFG, 'a reset clears the lock and restores the reset value')
    return dict(written=hex(weak), read_back=hex(got), clocks_per_word=round(per_word), locked=hex(locked))

if __name__ == '__main__':
    only = os.environ.get('KARU_BOARD_FAULT_CASES', 'startup,each,strikes,forgive,limits').split(',')
    cases = dict(startup=('a start-up failure is fatal at once and is no alarm', case_startup),
                 each=('each test fires on the real rings and mentropystat names it', case_each_test),
                 strikes=('alarm latch, strikes, DEAD', case_strikes),
                 forgive=('2^24 clean samples clear a strike', case_forgive),
                 limits=('build limits, spacing and lock', case_limits))
    for key in only:
        b.case(cases[key][0], cases[key][1])
    b.restore('the cases', lambda: (b.reset_halt(), bm.prep()))
    sys.exit(b.finish())
