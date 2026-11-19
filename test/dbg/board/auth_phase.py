# Debug authentication (image built with KARU_DBG_AUTH): the lifecycle
# straps, the locked view of the Debug Module, and the challenge and
# response exchange with the window ROM. Run it against auth-server.cfg.
#
# The client answers the algorithm that the challenge names (authlib.py):
# SHA3 (0x04), the shared-secret MAC of the FPGA image since 2026-11-18,
# with the key in KARU_BOARD_AUTH_KEY; or TEST (0x80), the simulation-only
# algorithm, which protects nothing. SHA3 keeps out only those without the
# key, and the key is in the bitstream. These cases check that the
# mechanism works.
#
# One case per run, named by KARU_BOARD_AUTH_CASE, because the operator sets
# DIP switch SW12 and presses the CPU reset button between cases; the
# switches are read at that reset only. Each case states what it needs, and
# first compares that with what the Debug Module shows, so that a wrong
# switch gives a message and not a confusing failure. Start OpenOCD after
# the reset, and afresh for every case: an OpenOCD that has examined the
# target once keeps its view of it.
#
#   case            switches (1 2 3 4)   reset     what must be seen
#   open            off off -  on        button    debugger works; mdbgauth: OPEN, no hold; seed stays in BIST
#   locked          on  off on -         button    examine refused; every DM register hidden; window left unused
#   authenticate    on  off on off       button    challenge, response, authenticated; attach, halt, register, resume
#   fresh-nonce     on  off on off       button    as authenticate; its nonce differs from every earlier one on record
#   wrong-response  on  off on off       button    one signature bit wrong: stays locked, window closed
#   replay          on  off on off       button    the response of an earlier authenticate: stays locked
#   expiry          on  off on off       button    no response: window closes after 2^30 cycles, stays locked
#   no-hold         on  off off -        button    no window; REQUEST refused; stays locked; Linux boots
#   entropy-off     on  off on on        button    REQUEST accepted, no challenge; stays locked; Linux boots
#   disabled        -   on  -  -         button    no mailbox; stays locked; Linux boots
#   reboot          as for authenticate  none      after authenticate and Linux up: software reboot keeps the grant, window stays closed
#   reboot-locked   as for no-hold       none      after a locked boot: software reboot leaves it locked, window stays closed
#
# Challenges and responses are kept in auth-history.json in the artifact
# directory: replay takes its response from there, and every challenge is
# compared with the earlier nonces.
#
#   KARU_BOARD_AUTH_CASE          the case to run (one name; no default)
#   KARU_BOARD_AUTH_KEY           SHA3 key file, 64 hex digits                 (_build/vcu118_auth_key.txt)
#   KARU_BOARD_AUTH_ALG           SHA3 or TEST: stop if the ROM asks for the other one   (either)
#   KARU_BOARD_AUTH_TIMEOUT       seconds allowed for the ROM to answer        (30)
#   KARU_BOARD_AUTH_WINDOW_MIN, _MAX  seconds after REQUEST at which the window
#                                 must still be open, and must be closed       (12, 17; 2^30 cycles at 75 MHz are 14.3 s)
#   KARU_BOARD_AUTH_BOOT          0: do not ask Linux, over SSH, whether the hart booted   (1)
#   KARU_BOARD_AUTH_BOOT_TIMEOUT  seconds to wait for Linux                    (900)
#   KARU_BOARD_AUTH_RESET_AGE     seconds the reset may lie before the case    (300)
#   KARU_BOARD_AUTH_SEED          0: the open case does not read seed (image without KARU_ZKR)   (1)
#   KARU_BOARD_AUTH_HISTORY       history file                                 (auth-history.json in the artifact directory)
#   KARU_BOARD_AUTH_KEEP_SERVER   1: leave OpenOCD running at the end          (0)
#   KARU_BOARD_AUTH_STALE         1: accept an OpenOCD that examined the target before; for the rehearsal   (0)
#   KARU_BOARD_REBOOT_TIMEOUT, KARU_BOARD_UART_LOG, KARU_BOARD_REBOOT_UART   as for linux_reboot.py (reboot cases)
#   KARU_BOARD_SSH_TIMEOUT        as for linux_reboot.py: seconds per SSH command (180)
#
# New on 2026-11-17. Rehearsed on the simulated target (auth_rehearse.py);
# every case passed on the board on 2026-11-18 (dbg/BOARD_ACCEPTANCE.md).
# SPDX-License-Identifier: BSD-2-Clause
from boardlib import *
import subprocess
import authlib
import linux_reboot as lr

CASE = setting('KARU_BOARD_AUTH_CASE', '')
TIMEOUT = float(setting('KARU_BOARD_AUTH_TIMEOUT', 30))
WINDOW_MIN = float(setting('KARU_BOARD_AUTH_WINDOW_MIN', 12))
WINDOW_MAX = float(setting('KARU_BOARD_AUTH_WINDOW_MAX', 17))
BOOT = setting('KARU_BOARD_AUTH_BOOT', '1') != '0'
BOOT_TIMEOUT = float(setting('KARU_BOARD_AUTH_BOOT_TIMEOUT', 900))
RESET_AGE = float(setting('KARU_BOARD_AUTH_RESET_AGE', 300))
SEED = setting('KARU_BOARD_AUTH_SEED', '1') != '0'
HISTORY = Path(setting('KARU_BOARD_AUTH_HISTORY', OUT/'auth-history.json'))
KEEP = setting('KARU_BOARD_AUTH_KEEP_SERVER', '0') != '0'
STALE = setting('KARU_BOARD_AUTH_STALE', '0') != '0'
ALG = setting('KARU_BOARD_AUTH_ALG', '').upper()
SWITCHES = 'Lifecycle is switches 1 and 2 (both off OPEN, 1 on AUTH, 2 on DISABLED), switch 3 holds the hart for a REQUEST; all are read at the CPU reset button.'

b = Board('auth')
m = authlib.Mailbox(b)

# ---- what the Debug Module shows, before anything is asked of it ----
def look(fresh=True):
    """Lifecycle, grant and window state as far as the Debug Module shows them.

    The examine attempt comes first: it is the check that a locked target
    refuses OpenOCD, and OpenOCD needs it before its DMI commands work."""
    b.cmd('poll off')
    stale = b.cmd('karu.cpu was_examined') == '1'
    if stale and fresh and not STALE:
        raise AssertionError('this OpenOCD has examined the target before, so what it reports now may be its old view. '
                             'Restart it after the reset: openocd -f test/dbg/board/auth-server.cfg')
    attached = m.examine()
    m.activate()
    dmstatus, s = m.dmstatus(), m.status()
    authenticated = bool(dmstatus & authlib.AUTHENTICATED)
    if s['mailbox']: lc = s['lc']                       # the mailbox exists in AUTH only
    elif s['word'] == 0: lc = 'OPEN' if authenticated else 'DISABLED'
    else: raise AssertionError(f"authdata reads {s['word']:#010x}: neither a status word nor 0")
    return dict(lc=lc, authenticated=authenticated, state=s['state'] if s['mailbox'] else None,
                dmstatus=dmstatus, status=s, attached=attached, stale=stale)

def shown(view):
    return (f"lifecycle {view['lc']}, dmstatus.authenticated={int(view['authenticated'])}"
            + (f", window {view['state']}" if view['state'] else ', no mailbox'))

def need(view, what, lc, state=None, authenticated=False):
    """Stop with the reason when the board is not set up for the case."""
    hint = None
    if view['lc'] != lc:
        hint = SWITCHES
    elif view['authenticated'] != authenticated:
        hint = ('The debugger is already authenticated in this power cycle: press the CPU reset button.' if view['authenticated']
                else 'There is no grant: run the authenticate case first, in the same power cycle.')
    elif state is not None and view['state'] not in state:
        hint = {'CLOSED': 'The window is closed: switch 3 is off, or the board was not reset since the last attempt.',
                'REQUESTED': 'A window is already running: press the CPU reset button and start again.',
                'IDLE': 'The hart is not held: switch 3 is off.',
                'HOLD': 'The hart is held for a REQUEST: switch 3 is on.'}[view['state']]
    if hint:
        raise AssertionError(f'this case needs {what}, but the Debug Module shows {shown(view)}. {hint}')
    b.checks += 1

def refused(view):
    """The locked view of contract 1.2: examine refused, only version,
    authenticated and authbusy in dmstatus, dmactive in dmcontrol, every
    other register reads 0, and writes do nothing."""
    if view['stale']:
        note = 'not checked: this OpenOCD examined the target before the reset'
    else:
        b.require(not view['attached'], 'OpenOCD examined a target whose Debug Module is locked')
        note = 'refused'
    b.equal(m.dmstatus() & ~authlib.AUTHBUSY, 3, 'locked dmstatus: version 3 and nothing else')
    b.equal(b.dmi(authlib.DMCONTROL), 1, 'locked dmcontrol reads dmactive only')
    for address, name in ((0x04, 'data0'), (0x12, 'hartinfo'), (0x16, 'abstractcs'), (0x17, 'command'),
                          (0x20, 'progbuf0'), (0x38, 'sbcs'), (0x40, 'haltsum0')):
        b.equal(b.dmi(address), 0, f'locked {name} reads 0')
    b.dmi(0x04, 0x5a5a5a5a); b.equal(b.dmi(0x04), 0, 'locked data0 ignores a write')
    b.dmi(authlib.DMCONTROL, 0x80000001); b.equal(b.dmi(authlib.DMCONTROL), 1, 'locked dmcontrol ignores haltreq')
    return note

def still_locked(what):
    b.require(not m.authenticated(), what + ': dmstatus.authenticated must stay 0')
    if not STALE:
        b.require(not m.examine(), what + ': OpenOCD must still be refused')

# ---- history: challenges seen and responses sent, across runs ----
def history():
    return json.loads(HISTORY.read_text()) if HISTORY.is_file() else []

def remember(case, challenge, sent, authenticated):
    entries = history() + [dict(case=case, time=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
                                challenge=[f'{w:#010x}' for w in challenge], response=[f'{w:#010x}' for w in sent] if sent else None,
                                authenticated=authenticated)]
    HISTORY.write_text(json.dumps(entries, indent=1) + '\n')

# ---- the exchange ----
def held():
    """look(), for a case that starts with the hart held for a REQUEST."""
    view = look()
    need(view, 'lifecycle AUTH with the hart held and no REQUEST yet (switches 1 on, 2 off, 3 on, then the CPU reset button)', 'AUTH', ('HOLD',))
    return view

def open_window():
    """REQUEST, then the challenge. Returns (challenge words, time of the REQUEST, earlier nonces)."""
    start = time.monotonic()
    m.request()
    s = m.status()
    b.equal((s['state'], s['error']), ('REQUESTED', None), 'REQUEST accepted')
    try:
        words = m.receive(authlib.CHALLENGE_WORDS, TIMEOUT)
    except TimeoutError as e:
        raise AssertionError(f'no challenge: {e}. With the entropy source off (switch 4 on) the ROM cannot build one')
    try:
        c = authlib.parse_challenge(words)
    except ValueError as e:
        raise AssertionError(f'unusable challenge: {e}')
    name = authlib.ALGORITHMS[authlib.algorithm(words)]
    if ALG and ALG != name:
        raise AssertionError(f'the ROM asks for algorithm {name}, but KARU_BOARD_AUTH_ALG={ALG}: '
                             'is the board running the bitstream you meant?')
    b.checks += 1
    b.equal((c['lc'], c['perm_req'], c['por_counter']), ('AUTH', 1, 0), 'challenge: lifecycle, requested permission, counter')
    b.equal(c['digest'], list(authlib.DEVICE_DIGEST), 'challenge: device digest of the ROM')
    b.require(len(set(c['nonce'])) > 1, 'challenge: the nonce is one repeated word')
    earlier = [h['challenge'][10:18] for h in history()]
    b.require([f'{w:#010x}' for w in c['nonce']] not in earlier, f'the nonce repeats one of the {len(earlier)} earlier ones on record')
    return words, start, len(earlier)

def closed(what):
    """The window is closed and takes no response."""
    s, _ = m.wait_state('CLOSED', TIMEOUT)
    s = m.send_header(authlib.CHALLENGE_WORDS // 2)
    b.equal((s['state'], s['error'], s['send_remaining']), ('CLOSED', 'BAD_STATE', 0), what + ': a SEND is refused')
    m.abort()
    b.equal(m.status()['error'], None, 'ABORT clears the error')

def use_debugger():
    """Attach, halt, read and write registers, resume."""
    if b.cmd('karu.cpu was_examined') != '1' or STALE:
        b.require(m.examine(), 'OpenOCD examines the target once it is authenticated')
    b.halt()
    auth = b.rawread(authlib.CSR_MDBGAUTH)
    b.equal(auth & (authlib.AUTH_UNLOCK | authlib.DEBUG_ENABLE | authlib.FW_LOCK | authlib.REVOKED), authlib.AUTH_UNLOCK | authlib.DEBUG_ENABLE,
            'mdbgauth: unlocked, debug enabled, not revoked')
    b.equal(((auth >> 4) & 3, (auth >> 8) & 0xff, (auth >> 16) & 0xff, bool(auth & authlib.AUTH_REQ)), (1, 1, 1, True),
            'mdbgauth: lifecycle AUTH, permission granted as requested')
    pc, saved = b.rr('pc'), b.rr('a0')
    b.rw('a0', 0x0123456789abcdef); b.equal(b.rr('a0'), 0x0123456789abcdef, 'register round trip'); b.rw('a0', saved)
    b.resume()
    return dict(mdbgauth=hex(auth), pc=hex(pc))

def authenticate(case='authenticate', want_earlier=False):
    if want_earlier:
        b.require(history(), 'no earlier challenge on record in this artifact directory: run the authenticate case first')
    examine = refused(held())
    words, start, earlier = open_window()
    sent = authlib.response(words)
    m.send(sent)
    ok = m.wait_decision(TIMEOUT)
    remember(case, words, sent, ok)
    alg = authlib.ALGORITHMS[authlib.algorithm(words)]
    b.require(ok, f'dmstatus.authenticated did not rise after a correct {alg} response')
    seconds = round(time.monotonic() - start, 2)
    used = use_debugger()
    b.equal(m.status()['state'], 'CLOSED', 'window closed after the decision')
    # A reconnecting debugger pulses dmactive; the grant must outlast it.
    m.activate(0); m.activate()
    b.require(m.authenticated(), 'the grant survives a dmactive pulse')
    return dict(examine_while_locked=examine, algorithm=alg, nonce=[f'{w:#010x}' for w in words[10:18]], earlier_nonces=earlier,
                seconds_to_authenticated=seconds, **used)

def wrong_response():
    examine = refused(held())
    words, start, earlier = open_window()
    sent = authlib.response(words)
    sent[5] ^= 1                                        # one bit of signature word 3
    m.send(sent)
    closed('after a wrong response')
    remember('wrong-response', words, sent, False)
    still_locked('after a wrong response')
    return dict(examine_while_locked=examine, earlier_nonces=earlier)

def replay():
    old = [h for h in history() if h['authenticated']]
    b.require(old, 'no accepted response on record in this artifact directory: run the authenticate case first')
    examine = refused(held())
    words, start, earlier = open_window()
    sent = [int(w, 16) for w in old[-1]['response']]
    b.require(sent != authlib.response(words), 'the old response is not valid for the new challenge')
    m.send(sent)
    closed('after a replayed response')
    remember('replay', words, sent, False)
    still_locked('after a replayed response')
    return dict(examine_while_locked=examine, replayed_from=old[-1]['time'], earlier_nonces=earlier)

def expiry():
    examine = refused(held())
    words, start, earlier = open_window()
    remember('expiry', words, None, False)
    last_open = 0.0
    while True:
        s, now = m.status(), time.monotonic() - start
        if s['state'] != 'REQUESTED': break
        last_open = now
        b.require(now <= WINDOW_MAX, f'the window is still open {now:.1f} s after the REQUEST; it must close by {WINDOW_MAX:.0f} s')
        time.sleep(m.poll)
    b.equal(s['state'], 'CLOSED', 'window state after the wait')
    b.require(last_open >= WINDOW_MIN, f'the window closed {now:.1f} s after the REQUEST, before {WINDOW_MIN:.0f} s')
    closed('after expiry')
    still_locked('after expiry')
    return dict(examine_while_locked=examine, last_seen_open=round(last_open, 2), seen_closed=round(now, 2), earlier_nonces=earlier)

def boots(start):
    """Evidence that the hart booted after the reset: Linux answers over SSH
    and has not been up for longer than the reset can be old."""
    if not BOOT:
        return 'not checked (KARU_BOARD_AUTH_BOOT=0)'
    end = time.monotonic() + BOOT_TIMEOUT
    while not lr.ssh_up():
        if time.monotonic() > end:
            raise AssertionError(f'Linux did not answer over SSH within {BOOT_TIMEOUT:.0f} s: nothing shows that the hart booted')
        time.sleep(5)
    answer = lr.ssh('cut -d. -f1 /proc/uptime')
    b.require(answer.returncode == 0 and answer.stdout.strip().isdigit(), 'Linux did not report its uptime: ' + answer.stderr.strip())
    uptime = int(answer.stdout)
    limit = time.monotonic() - start + RESET_AGE
    b.require(uptime <= limit, f'Linux has been up for {uptime} s, longer than the {limit:.0f} s since the reset this case needs: was the button pressed?')
    return f'Linux answers, up for {uptime} s'

def no_hold():
    start = time.monotonic()
    view = look()
    need(view, 'lifecycle AUTH without the hold (switches 1 on, 2 off, 3 off, then the CPU reset button)', 'AUTH', ('IDLE', 'CLOSED'))
    examine = refused(view)
    m.wait_state('CLOSED', TIMEOUT)                     # the ROM leaves at once without a REQUEST
    m.request()
    s = m.status()
    b.equal((s['state'], s['error']), ('CLOSED', 'BAD_STATE'), 'REQUEST refused without the hold')
    m.abort()
    still_locked('without the hold')
    return dict(examine_while_locked=examine, boot=boots(start))

def entropy_off():
    start = time.monotonic()
    examine = refused(held())
    m.request()
    s, polls, requested = m.status(), 0, time.monotonic()
    b.require(s['state'] in ('REQUESTED', 'CLOSED') and s['error'] is None, f"REQUEST accepted (state {s['state']}, error {s['error']})")
    while s['state'] == 'REQUESTED':                    # a source that reports DEAD ends the window at once
        b.require(s['tx_available'] == 0, 'a challenge arrived: the entropy source is on (switch 4 is off)')
        b.require(time.monotonic() - requested <= WINDOW_MAX, f'the window is still open after {WINDOW_MAX:.0f} s')
        time.sleep(m.poll)
        s, polls = m.status(), polls + 1
    b.equal((s['state'], s['tx_available']), ('CLOSED', 0), 'window closed without a challenge')
    still_locked('without entropy')
    return dict(examine_while_locked=examine, seconds_to_closed=round(time.monotonic() - requested, 2), polls=polls, boot=boots(start))

def disabled():
    start = time.monotonic()
    view = look()
    need(view, 'lifecycle DISABLED (switch 2 on, then the CPU reset button)', 'DISABLED')
    examine = refused(view)
    m.request()
    b.equal(m.read(), 0, 'authdata still reads 0 after a REQUEST: no mailbox')
    time.sleep(min(2.0, TIMEOUT))
    b.equal(m.dmstatus() & ~authlib.AUTHBUSY, 3, 'dmstatus after the REQUEST')
    still_locked('in DISABLED')
    return dict(examine_while_locked=examine, boot=boots(start))

def progbuf(words):
    """Run instructions in the Program Buffer, with an ebreak after them."""
    b.clear()
    for i, w in enumerate((words + [0x00100073] + [0x13] * 8)[:8]): b.dmi(0x20 + i, w)
    b.dmi(0x17, 0x40000); b.idle()

def open_case():
    view = look()
    need(view, 'lifecycle OPEN (switches 1 and 2 off, then the CPU reset button)', 'OPEN', authenticated=True)
    b.require(view['attached'], 'OpenOCD examines an OPEN target')
    b.halt()
    try:
        auth = b.rawread(authlib.CSR_MDBGAUTH)
    except AssertionError as e:
        raise AssertionError(f'mdbgauth cannot be read ({e}): the image is built without KARU_DBG_AUTH')
    b.checks += 1
    b.equal(((auth >> 4) & 3, bool(auth & authlib.HOLD)), (0, False), 'mdbgauth: lifecycle OPEN, and no hold whatever switch 3 says')
    b.equal(auth & (authlib.DEBUG_ENABLE | authlib.AUTH_UNLOCK | authlib.FW_LOCK | authlib.REVOKED), authlib.DEBUG_ENABLE,
            'mdbgauth: debug enabled by the lifecycle alone')
    detail = dict(mdbgauth=hex(auth))
    if SEED:
        saved = b.rawread(0x1008)
        try:
            words = []
            for _ in range(20):                         # csrrw s0, seed, x0: the form that takes a word
                progbuf([0x01501473]); words.append(b.rawread(0x1008)); time.sleep(.02)
        except AssertionError as e:
            raise AssertionError(f'seed cannot be read ({e}): the image is built without KARU_ZKR; set KARU_BOARD_AUTH_SEED=0')
        finally:
            b.dmi(0x16, 0x700); b.rawwrite(0x1008, saved)
        b.require(all(w == 0 for w in words), 'seed must stay in BIST with no entropy bits while switch 4 is on; it read '
                  + ' '.join(sorted({f'{w:#x}' for w in words})[:4]) + ' (switch 4 off?)')
        detail['seed'] = 'BIST in 20 reads'
    else:
        detail['seed'] = 'not read (KARU_BOARD_AUTH_SEED=0)'
    b.resume()
    return detail

def reboot(authenticated):
    """A software reboot is a system reset: it must not reopen the window,
    and it must not change the grant either way."""
    view = look(fresh=False)
    need(view, 'the power cycle of ' + ('a passed authenticate case' if authenticated else 'a locked boot in lifecycle AUTH') + ', with Linux up',
         'AUTH', ('CLOSED',), authenticated)
    if lr.NEED_UART and not lr.UART_LOG.is_file():
        raise AssertionError(f'no UART capture at {lr.UART_LOG}: cannot show that the restart goes through the boot ROM (KARU_BOARD_REBOOT_UART=0 leaves that out)')
    console_from = lr.UART_LOG.stat().st_size if lr.UART_LOG.is_file() else 0
    before = lr.ssh('cat /proc/sys/kernel/random/boot_id')
    b.require(before.returncode == 0, 'Linux is not reachable over SSH before the reboot: ' + before.stderr.strip())
    start = time.monotonic()
    try: lr.ssh('reboot', timeout=30)
    except subprocess.TimeoutExpired: pass
    while lr.ssh_up():
        b.require(time.monotonic() - start < lr.TIMEOUT, f'SSH never went away within {lr.TIMEOUT} s')
        time.sleep(1)
    while not lr.ssh_up():
        b.require(time.monotonic() - start < lr.TIMEOUT, f'the board did not come back within {lr.TIMEOUT} s')
        time.sleep(5)
    after = lr.ssh('cat /proc/sys/kernel/random/boot_id')
    b.require(after.returncode == 0 and after.stdout.split()[:1] != before.stdout.split()[:1], 'Linux restarted (new boot ID)')
    detail = dict(seconds=round(time.monotonic() - start, 1))
    if lr.NEED_UART:
        with lr.UART_LOG.open('rb') as f:
            f.seek(console_from); banner = lr.rom_boot_evidence(f.read().decode(errors='replace'))
        b.require(banner is not None, 'no fu-boot and OpenSBI banners on the console since the request: the restart did not go through the boot ROM')
        detail['rom_boot'] = banner
    else:
        detail['rom_boot'] = 'not checked (KARU_BOARD_REBOOT_UART=0)'
    m.activate()
    s = m.status()
    b.equal(m.authenticated(), authenticated, 'dmstatus.authenticated is what it was before the reboot')
    b.equal((s['lc'], s['state']), ('AUTH', 'CLOSED'), 'window still closed after the reboot')
    m.request()
    b.equal(m.status()['error'], 'BAD_STATE', 'REQUEST refused after the reboot: the window did not reopen')
    m.abort()
    if authenticated: detail.update(use_debugger())
    else: still_locked('after the reboot')
    return detail

CASES = {'open': ('1 off, 2 off, 4 on', 'CPU reset button', open_case),
         'locked': ('1 on, 2 off, 3 on', 'CPU reset button', lambda: dict(examine_while_locked=refused(held()), window='left unused')),
         'authenticate': ('1 on, 2 off, 3 on, 4 off', 'CPU reset button', authenticate),
         'fresh-nonce': ('1 on, 2 off, 3 on, 4 off', 'CPU reset button', lambda: authenticate('fresh-nonce', True)),
         'wrong-response': ('1 on, 2 off, 3 on, 4 off', 'CPU reset button', wrong_response),
         'replay': ('1 on, 2 off, 3 on, 4 off', 'CPU reset button', replay),
         'expiry': ('1 on, 2 off, 3 on, 4 off', 'CPU reset button', expiry),
         'no-hold': ('1 on, 2 off, 3 off', 'CPU reset button', no_hold),
         'entropy-off': ('1 on, 2 off, 3 on, 4 on', 'CPU reset button', entropy_off),
         'disabled': ('2 on', 'CPU reset button', disabled),
         'reboot': ('as for authenticate', 'none: the power cycle of a passed authenticate, Linux up', lambda: reboot(True)),
         'reboot-locked': ('as for no-hold', 'none: after a locked boot, Linux up', lambda: reboot(False))}

def run(name):
    """One case, with what it needs in its result."""
    switches, reset, fn = CASES[name]
    def case():
        detail = fn()
        return dict(switches=switches, reset=reset, **detail)
    return b.case(f'authentication: {name}', case)

def main():
    if CASE in CASES:
        run(CASE)
    else:
        b.case('authentication: case selection', lambda: b.require(False, f"KARU_BOARD_AUTH_CASE={CASE or '(not set)'}: name one of " + ', '.join(CASES)))
    def leave():                                        # polling stays off: a locked target cannot be polled
        if not KEEP:
            try: b.cmd('shutdown')
            except (RuntimeError, OSError): pass
    return b.finish(leave)

if __name__ == '__main__': sys.exit(main())
