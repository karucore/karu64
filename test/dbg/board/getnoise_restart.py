#!/usr/bin/env python3
# Delayed warm-restart data in the format of SP 800-90B section 3.1.4: R
# restarts of the entropy source, C consecutive raw symbols after each, at
# decimation K (the shipped k = 16 by default). Not an acceptance phase.
#
# This is NOT the operational restart data of section 3.1.4.1, which starts
# with the first outputs available for real-world use (about 57 ms after a
# reset here). Each row here starts at least about 150 ms after the reset
# (50 ms inside reset_halt(), then KARU_BOARD_RESTART_DELAY), after the
# payload has rewritten mentropycfg and entered test mode, both of which
# restart the entropy block's digital sequence. See
# doc/sp800-90b-assessment.md section 4.4.
#
# A restart is a debugger reset-halt (ndmreset with haltreq): the reset
# sequencer resets the hart, the SoC and the entropy source, whose rings stop
# and start again (rtl/karu_entropy.v, flow/fpga/karu_rosc_rng.v). It is the
# same reset path as the software reset at 0x1000_0800. The DM, DDR
# calibration and the clocks are not reset. After the reset the phase waits
# KARU_BOARD_RESTART_DELAY seconds, then runs the GetNoise payload
# (getnoise.S, already in DRAM) for C symbols. A restart whose capture lost a
# symbol is repeated, so that every row holds C consecutive symbols.
#
# Output in the artifact directory:
#   restart-rows.bin    R*C bytes: row dataset (restart 1 symbols 1..C, then
#                       restart 2, ...), one 4-bit symbol per byte, lane i in bit i
#   restart.json        parameters, per-restart timing, retries, sysmon readings
#
# Settings: KARU_BOARD_RESTART_COUNT (1000), KARU_BOARD_RESTART_SAMPLES (1000),
# KARU_BOARD_RESTART_K (16), KARU_BOARD_RESTART_DELAY (0.1 s),
# KARU_BOARD_RESTART_NOTE. Needs: server.cfg, lifecycle OPEN, DIP switch 4 off,
# the fixtures of make dbg-board-fixture and dbg-getnoise-fixture.
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import baremetal_phase as bm
import hashlib, struct
bm.b.close(); b = bm.b = Board('restart')

R = int(setting('KARU_BOARD_RESTART_COUNT', 1000), 0)
C = int(setting('KARU_BOARD_RESTART_SAMPLES', 1000), 0)
K = int(setting('KARU_BOARD_RESTART_K', 16), 0)
DELAY = float(setting('KARU_BOARD_RESTART_DELAY', 0.1))
NOTE = os.environ.get('KARU_BOARD_RESTART_NOTE', '')
LOAD = 0x88000000
BUF = LOAD + 0x10000
SYMS = {p[2]: int(p[0], 16) for line in (OUT/'getnoise.symbols').read_text().splitlines() if len(p := line.split()) == 3}
PARAMS, RESULT, STOP = (LOAD + SYMS[s] for s in ('getnoise_params', 'getnoise_result', 'getnoise_stop'))
FIELDS = ['status', 'stored', 'runs', 'losses', 'polls', 'cfg_before', 'cfg_used', 'cfg_after', 'noise_after', 'mcause', 'mepc']
SYSMON = 0x10000860
payload = (OUT/'getnoise.bin').read_bytes()
words = list(struct.unpack(f'<{(len(payload)+3)//4}I', payload + b'\0'*(-len(payload) % 4)))

def sysmon():
    v = b.read(SYSMON, 64, 1, 'progbuf')[0]; b.cmd('riscv mem_access progbuf')
    return dict(temp_c=round((v & 0xffff)*509.3140064/65536-280.2308787, 2), vccint_v=round(((v >> 16) & 0xffff)*3/65536, 4))

def wait_halt(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        b.cmd('poll')
        if b.cmd('karu.cpu curstate') == 'halted': return
        time.sleep(.02)
    b.halt(); raise TimeoutError('payload did not finish')

def one_restart():
    b.reset_halt()                                   # ndmreset: the entropy source restarts here
    t_reset = time.monotonic()
    bm.prep()
    if b.read(LOAD, 32, 4, 'sysbus') != words[:4]:   # DRAM survives the reset; reload if not
        b.write(LOAD, 32, words, 'sysbus')
    b.write(PARAMS, 64, [K-1, C, BUF, C, 64*K+4096, -1] + [0]*(len(FIELDS)-1), 'sysbus')
    b.cmd('riscv mem_access progbuf')
    time.sleep(max(0.0, DELAY - (time.monotonic() - t_reset)))
    t_start = time.monotonic() - t_reset
    b.cmd(f'resume {LOAD:#x}'); wait_halt(10)
    r = dict(zip(FIELDS, b.read(RESULT, 64, len(FIELDS), 'sysbus')))
    data = b.read(BUF, 64, (C+7)//8, 'sysbus'); b.cmd('riscv mem_access progbuf')
    raw = struct.pack(f'<{len(data)}Q', *data)[:C]
    return r, raw, round(t_start, 3)

def run():
    rows = bytearray(); meta = []; retries = 0
    b.reset_halt(); bm.prep()                        # halted: progbuf memory access needs it
    first = sysmon()
    b.write(LOAD, 32, words, 'sysbus'); b.cmd('riscv mem_access progbuf')
    for i in range(R):
        for attempt in range(5):
            r, raw, t_start = one_restart()
            ok = r['status'] == 0 and r['stored'] == C and r['runs'] == 1 and r['losses'] == 0 \
                 and raw[0] & 0x80 and all((x & 0x70) == 0 for x in raw) and not any(x & 0x80 for x in raw[1:])
            if ok: break
            retries += 1
        else:
            raise AssertionError(f'restart {i}: no clean capture in 5 attempts: {r}')
        rows += bytes(x & 0x0f for x in raw)
        meta.append(dict(i=i, start_after_reset_s=t_start, attempts=attempt+1))
        if i % 100 == 99:
            (OUT/'restart-rows.bin').write_bytes(rows)
            print(json.dumps(dict(restarts=i+1, retries=retries, sysmon=sysmon())), flush=True)
    last = sysmon()
    (OUT/'restart-rows.bin').write_bytes(rows)
    (OUT/'restart.json').write_text(json.dumps(dict(format='karu64-restart-1', restarts=R, samples=C, k=K,
        delay_s=DELAY, restart='debugger reset-halt (ndmreset); resets hart, SoC and entropy source',
        encoding='row dataset; one 4-bit symbol per byte, lane i in bit i', sha256=hashlib.sha256(rows).hexdigest(),
        retries=retries, sysmon_first=first, sysmon_last=last, note=NOTE,
        time=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'), per_restart=meta), indent=1) + '\n')
    return dict(restarts=R, samples=C, retries=retries, sha256=hashlib.sha256(rows).hexdigest()[:16])

if __name__ == '__main__':
    b.case(f'SP 800-90B restart data, {R} x {C} at k={K}', run)
    sys.exit(b.finish())
