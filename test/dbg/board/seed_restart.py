#!/usr/bin/env python3
# Operational restart data in the format of SP 800-90B section 3.1.4: R
# restarts of the entropy source, and after each the first C samples it
# delivers through seed, from the first ES16 on. Not an acceptance phase.
#
# Unlike getnoise_restart.py (the delayed warm-restart experiment), nothing
# here enters test mode or writes mentropycfg: the source runs in its reset
# configuration, and the samples are the words a first consumer of seed
# gets after the start-up test (seedcap.S).
#
# A restart is a debugger reset (ndmreset): the reset sequencer resets the
# hart, the SoC and the entropy source, and the rings are gated off while
# the reset lasts (flow/fpga/karu_rosc_rng.v, en_q). The DM, DDR calibration
# and the clocks are not reset. The hart is held by haltreq, so it halts
# before its first instruction (checked: DPC is the reset vector, so the
# boot ROM never ran and nothing read seed before the payload). Through raw
# DMI writes the phase then points DPC at seedcap.S, already in DRAM (DRAM
# survives the reset), and resumes, a few milliseconds after the reset was
# released; the first word is there after about 59 ms at k = 16. seedcap.S
# proves that it was in time (it polled BIST before the first ES16) and that
# it kept up (its longest gap between two polls is under one word). A restart that
# fails only one of these acquisition checks is recorded and repeated, so
# that every row holds the first C samples of one restart. A health-test
# failure (DEAD, an alarm, a failure counted in mentropystat), a changed
# mentropycfg, a payload trap or a source that delivers nothing ends the
# campaign as a failure: it is a result about the source, and a clean
# repeat must not replace it.
#
# A sample is one bit: the lane that mentropystat names as the noise source,
# in every kept symbol. seed delivers sixteen to a word, so a restart reads
# ceil(C / 16) words (63 for 1,000 samples) and its row is their first C bits.
#
# Output in the artifact directory:
#   seed-restart-rows.bin   R*C bytes: row dataset (restart 1 samples 1..C,
#                           then restart 2, ...), one sample per byte, 0 or 1,
#                           as NIST's ea_restart takes a binary source
#   seed-restart-words.bin  the words as seed delivered them: per restart
#                           ceil(C / 16) words of 16 bits, little-endian, the
#                           first sample of a word in its bit 15
#   seed-restart.json       parameters, the straps, per-restart timing,
#                           repeats and why, sysmon readings
#
# Settings: KARU_BOARD_SEEDRESTART_COUNT (1000), KARU_BOARD_SEEDRESTART_SAMPLES
# (1000), KARU_BOARD_SEEDRESTART_NOTE. Needs: server.cfg,
# lifecycle OPEN, DIP switch 4 off, the fixtures of make dbg-board-fixture and
# dbg-seedcap-fixture. Leaves the hart halted after a final reset.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import hashlib, struct
bm.b.close(); b = bm.b = Board('seed-restart')

R = int(setting('KARU_BOARD_SEEDRESTART_COUNT', 1000), 0)
C = int(setting('KARU_BOARD_SEEDRESTART_SAMPLES', 1000), 0)
NOTE = os.environ.get('KARU_BOARD_SEEDRESTART_NOTE', '')
WORDS = (C + 15) // 16                      # sixteen samples to a seed word
LOAD = 0x88000000
BUF = LOAD + 0x10000
SYMS = {p[2]: int(p[0], 16) for line in (OUT/'seedcap.symbols').read_text().splitlines() if len(p := line.split()) == 3}
PARAMS, RESULT = (LOAD + SYMS[s] for s in ('seedcap_params', 'seedcap_result'))
FIELDS = ['status', 'stored', 'bist', 'wait', 'cyc_entry', 'cyc_first', 'cyc_end', 'max_gap', 'stat_end', 'cfg_end', 'mcause', 'mepc']
STATUS = {0: 'OK', 1: 'RUNNING', 2: 'LATE', 3: 'DEAD', 4: 'ALARM', 5: 'TIMEOUT', 6: 'TRAP', 7: 'PARAM'}
CFG_CUTOFFS = 0x30c0000b3c370000            # mentropycfg reset value of the VCU118 image, without the interval
IDLE = 1 << 26                              # polls without a word; the start-up test needs about 2^18 at k = 16
STRAPS = {}                                 # lane and kshift of the first restart; they are constants of the image
def straps(stat): return dict(lane=(stat >> 20) & 3, kshift=(stat >> 22) & 3)
def reset_cfg(kshift): return CFG_CUTOFFS | ((16 << kshift) - 1)       # the interval after reset is the spacing floor
def word_clocks(kshift): return 16 * 256 * (16 << kshift)              # one seed word at the reset spacing
SYSMON = 0x10000860
payload = (OUT/'seedcap.bin').read_bytes()
pwords = list(struct.unpack(f'<{(len(payload)+3)//4}I', payload + b'\0'*(-len(payload) % 4)))

def sysmon():
    v = b.read(SYSMON, 64, 1, 'progbuf')[0]; b.cmd('riscv mem_access progbuf')
    return dict(temp_c=round((v & 0xffff)*509.3140064/65536-280.2308787, 2), vccint_v=round(((v >> 16) & 0xffff)*3/65536, 4))

def one_restart():
    """Reset, start seedcap.S before the start-up test ends, return its result and words."""
    b.write(RESULT, 64, [-1] + [0]*(len(FIELDS)-1), 'sysbus')
    t0 = time.monotonic()
    b.dmi(0x10, 0x80000003)                      # haltreq, ndmreset: the source stops
    b.dmi(0x10, 0x80000001)                      # release the reset; haltreq held
    t_rel = time.monotonic()
    for _ in range(50):
        if b.dmi(0x11) & 0x200: break            # allhalted
    else:
        raise AssertionError('hart did not halt after the reset')
    b.dmi(0x16, 0x700)                           # clear cmderr
    dpc = b.rawread(0x7b1)
    dcsr = b.rawread(0x7b0)
    b.rawwrite(0x7b0, dcsr | 0x8000)             # ebreakm: the payload's ebreak halts
    b.rawwrite(0x7b1, LOAD)
    b.dmi(0x10, 0x50000001)                      # resumereq, ackhavereset
    t_res = time.monotonic()
    time.sleep(0.1)
    end = time.monotonic() + 3 * (1 << STRAPS.get('kshift', 3))
    while not b.dmi(0x11) & 0x200:
        if time.monotonic() > end:
            b.dmi(0x10, 0x80000001)
            raise AssertionError('payload did not reach its ebreak')
        time.sleep(0.005)
    r = dict(zip(FIELDS, b.read(RESULT, 64, len(FIELDS), 'sysbus')))
    data = b.read(BUF, 16, WORDS, 'sysbus')
    return r, data, dict(dpc=dpc, release_s=round(t_rel - t0, 4), resume_after_release_s=round(t_res - t_rel, 4))

def problems(r, data, t):
    """(acquisition problems, which a repeat may clear; failures of the source or the setup, which end the campaign)."""
    retry, fatal = [], []
    if t['dpc'] != RESET_PC: retry.append(f"halted at {t['dpc']:#x}, not the reset vector")
    if r['status'] == 2 or (r['status'] == 0 and r['bist'] == 0): retry.append('LATE: no BIST poll before the first ES16')
    elif r['status'] not in (0, 2): fatal.append(STATUS.get(r['status'], r['status']))
    now = straps(r['stat_end'])
    if not STRAPS: STRAPS.update(now)
    if now != STRAPS: fatal.append(f"the straps changed: {now}, were {STRAPS}")
    if r['status'] in (0, 2) and r['stored'] != WORDS: retry.append(f"{r['stored']} words")
    if r['max_gap'] >= word_clocks(now['kshift']): retry.append(f"gap {r['max_gap']} clocks")
    if r['cfg_end'] != reset_cfg(now['kshift']): fatal.append(f"mentropycfg {r['cfg_end']:#x}")
    if r['stat_end'] & 3 != 1 or (r['stat_end'] >> 32) & 0xffff or r['stat_end'] & 4:
        fatal.append(f"mentropystat {r['stat_end']:#x}")
    return retry, fatal

def bits(data):
    """The samples of one restart's words, in the order taken (bit 15 of a word first), cut to C."""
    return bytes((w >> (15 - j)) & 1 for w in data for j in range(16))[:C]

def run():
    rows = bytearray(); words = bytearray(); meta = []; repeats = []
    b.reset_halt(); bm.prep()                        # halted: progbuf access for the readout
    first = sysmon()
    b.write(LOAD, 32, pwords, 'sysbus')
    b.equal(b.read(LOAD, 32, len(pwords), 'sysbus'), pwords, 'payload readback')
    b.write(PARAMS, 64, [WORDS, BUF, IDLE], 'sysbus')
    b.cmd('poll off')
    try:
        for i in range(R):
            for attempt in range(5):
                r, data, t = one_restart()
                retry, fatal = problems(r, data, t)
                if fatal:
                    failure = dict(i=i, attempt=attempt, failure=fatal, problems=retry, stat_end=hex(r['stat_end']),
                                   cfg_end=hex(r['cfg_end']), stored=r['stored'], status=STATUS.get(r['status'], r['status']))
                    (OUT/'seed-restart-rows.bin').write_bytes(rows); (OUT/'seed-restart-words.bin').write_bytes(words)
                    (OUT/'seed-restart-failure.json').write_text(json.dumps(dict(failure=failure, restarts_before=i,
                        repeats=repeats, note=NOTE), indent=1) + '\n')
                    raise AssertionError(f'restart {i}: the source or the setup failed: {failure}')
                if not retry: break
                repeats.append(dict(i=i, attempt=attempt, problems=retry, stat_end=hex(r['stat_end']), stored=r['stored']))
                print(json.dumps(repeats[-1]), flush=True)
            else:
                raise AssertionError(f'restart {i}: no clean capture in 5 attempts: {retry}')
            rows += bits(data); words += struct.pack(f'<{WORDS}H', *data)
            meta.append(dict(i=i, attempts=attempt+1, resume_after_release_s=t['resume_after_release_s'],
                             first_es16_after_entry_ms=round((r['cyc_first'] - r['cyc_entry'])/75e3, 3),
                             bist_polls=r['bist'], max_gap=r['max_gap']))
            if i % 100 == 99:
                (OUT/'seed-restart-rows.bin').write_bytes(rows); (OUT/'seed-restart-words.bin').write_bytes(words)
                print(json.dumps(dict(restarts=i+1, repeats=len(repeats), last=meta[-1])), flush=True)
    finally:
        b.cmd('poll on')
    b.reset_halt(); bm.prep()
    last = sysmon()
    (OUT/'seed-restart-rows.bin').write_bytes(rows); (OUT/'seed-restart-words.bin').write_bytes(words)
    b.equal(len(rows), R * C, 'rows written: R restarts of C samples')
    sha = hashlib.sha256(rows).hexdigest()
    lat = sorted(m['resume_after_release_s'] for m in meta)
    fes = sorted(m['first_es16_after_entry_ms'] for m in meta)
    summary = dict(restarts=R, samples=C, words_per_restart=WORDS, lane=STRAPS['lane'], kshift=STRAPS['kshift'],
                   k=16 << STRAPS['kshift'], repeats=len(repeats), sha256=sha,
                   resume_after_release_s=dict(min=lat[0], median=lat[len(lat)//2], max=lat[-1]),
                   first_es16_after_entry_ms=dict(min=fes[0], median=fes[len(fes)//2], max=fes[-1]),
                   max_gap_clocks=max(m['max_gap'] for m in meta))
    (OUT/'seed-restart.json').write_text(json.dumps(dict(format='karu64-seed-restart-2', restarts=R, samples=C,
        words_per_restart=WORDS, lane=STRAPS['lane'], kshift=STRAPS['kshift'], mentropycfg=hex(reset_cfg(STRAPS['kshift'])),
        restart='debugger reset (ndmreset, hart held by haltreq); resets hart, SoC and entropy source; rings gated off',
        path='seed CSR from the first ES16 on, reset configuration, no test mode (seedcap.S)',
        encoding='row dataset; one sample per byte, 0 or 1: the bit of the source lane; bit 15 of a seed word first, '
                 'the first C bits of each restart',
        words_file='seed-restart-words.bin: per restart the words as read, 16 bits little-endian',
        sha256=sha, words_sha256=hashlib.sha256(words).hexdigest(), summary=summary, repeats=repeats, sysmon_first=first, sysmon_last=last, note=NOTE,
        time=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'), per_restart=meta), indent=1) + '\n')
    return summary

if __name__ == '__main__':
    b.case(f'SP 800-90B operational restart data through seed, {R} x {C}', run)
    sys.exit(b.finish())
