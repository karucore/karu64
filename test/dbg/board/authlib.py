# Host side of the debug authentication exchange (doc/debug-auth-contract.md):
# the mailbox on the Debug Module's authdata register, the CHALLENGE and
# RESPONSE frames of the window ROM (test/dbg/auth_rom/window.c), and the
# responses of its two algorithms. The response follows the algorithm that
# the challenge names.
#
# SHA3 (algorithm 0x04) is the shared-secret MAC of the FPGA image, chosen
# on 2026-11-18 for FPGA validation (contract 5.1; D3 is still open):
#   sig = SHA3-256(key[32] || "karudbg-auth-v1" || challenge words 0-19 as
#                  80 bytes little-endian || granted-mask byte)
# sent as 8 little-endian words. The key is read from the file named by
# KARU_BOARD_AUTH_KEY (64 hex digits; default _build/vcu118_auth_key.txt,
# which dbg/fpga.mk generates for the image). Anyone with that file, the ROM
# image or the bitstream can authenticate.
#
# TEST (algorithm 0x80) is the simulation-only algorithm of the contract. It
# protects nothing: the "signature" is a fold of the challenge with a key
# that is printed below and in the ROM source, so anyone can compute it. It
# exists to exercise the exchange.
#
# The first part is plain arithmetic on words and needs no board; the
# self-test checks it against the ROM source. Mailbox runs the protocol
# through OpenOCD's `riscv authdata_read` and `riscv authdata_write`, over
# the Tcl RPC connection of a boardlib.Board.
# SPDX-License-Identifier: BSD-2-Clause
import hashlib, os, re, struct, time
from pathlib import Path

# ---- contract constants ----
DMCONTROL, DMSTATUS, AUTHDATA = 0x10, 0x11, 0x30            # DMI addresses
AUTHENTICATED, AUTHBUSY = 1 << 7, 1 << 6                    # dmstatus; a locked DM shows these and version 3, nothing else
OP_STATUS, OP_REQUEST, OP_SEND, OP_RECV, OP_ABORT = 0x0, 0x1, 0x2, 0x3, 0xf     # section 4.1, bits [31:28]
REQUEST_KEY = 0xa5                                          # REQUEST argument [23:16]
STATUS_MAGIC, PROTOCOL_VERSION = 0x6, 1                     # section 4.2
LIFECYCLES = {0: 'OPEN', 1: 'AUTH', 2: 'DISABLED', 3: 'DISABLED'}
STATES = {0: 'IDLE', 1: 'HOLD', 2: 'REQUESTED', 3: 'CLOSED'}
ERRORS = {0: None, 1: 'OVERFLOW', 2: 'UNDERFLOW', 3: 'BAD_OP', 4: 'BAD_STATE'}
CHALLENGE, RESPONSE, RESULT, FRAME_VERSION = 0x01, 0x02, 0x03, 1               # section 5, header [31:24] and [23:16]
ALG_TEST, ALG_SHA3 = 0x80, 0x04
ALGORITHMS = {ALG_TEST: 'TEST', ALG_SHA3: 'SHA3'}
MAC_LABEL = b'karudbg-auth-v1'
KEY_FILE = Path(__file__).resolve().parents[3] / '_build/vcu118_auth_key.txt'
CHALLENGE_WORDS, CHALLENGE_BODY_BYTES, TEST_SIG_WORDS = 20, 72, 8
# The public test key and the device digest of the simulation ROM (window.c).
TEST_KEY = (0x6b617275, 0x64626761, 0x75746821, 0x54455354, 0x2d6f6e6c, 0x792d6e6f, 0x742d6372, 0x7970746f)
DEVICE_DIGEST = (0x11111111, 0x22222222, 0x33333333, 0x44444444, 0x55555555, 0x66666666, 0x77777777, 0x88888888)
# mdbgauth (CSR 0x7c0), section 3.1
CSR_MDBGAUTH = 0x7c0
AUTH_UNLOCK, BOOT_DONE, FW_LOCK, DEBUG_ENABLE, HOLD, AUTH_REQ, REVOKED = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 6, 1 << 7, 1 << 24

# ---- words and frames ----
def header(op, argument=0):
    """An authdata operation header: operation in [31:28], argument in [23:0]."""
    return (op << 28) | argument

def request_word(mask=1):
    """REQUEST for a permission mask; bit 0 is full debug, the only one defined."""
    return header(OP_REQUEST, (REQUEST_KEY << 16) | mask)

def frame_header(frame, algorithm):
    return (frame << 24) | (FRAME_VERSION << 16) | (algorithm << 8)

def parse_status(word):
    """Fields of a status word; 'mailbox' is False when the word is not one
    (authdata reads 0 outside lifecycle AUTH)."""
    return dict(word=word, mailbox=word >> 28 == STATUS_MAGIC and (word >> 26) & 3 == PROTOCOL_VERSION,
                lc=LIFECYCLES[(word >> 24) & 3], state=STATES.get((word >> 21) & 7, 'reserved'),
                error=ERRORS.get((word >> 18) & 7, 'reserved'), send_remaining=(word >> 11) & 0x1f,
                rx_free=(word >> 5) & 0x1f, tx_available=word & 0x1f)

def algorithm(words):
    """The algorithm a CHALLENGE names. Raises ValueError for a header that
    is not a CHALLENGE, or an algorithm this client cannot answer."""
    if words[0] & ~0xff00 != frame_header(CHALLENGE, 0):
        raise ValueError(f'challenge header {words[0]:#010x}: not a version-{FRAME_VERSION} CHALLENGE')
    alg = (words[0] >> 8) & 0xff
    if alg not in ALGORITHMS:
        raise ValueError(f'the ROM asks for algorithm {alg:#04x}, which this client does not know '
                         f'(it answers SHA3 {ALG_SHA3:#04x} and TEST {ALG_TEST:#04x})')
    return alg

def parse_challenge(words):
    """Fields of a CHALLENGE frame. Raises ValueError when it is not a
    challenge of the contract with an algorithm this client knows."""
    if len(words) != CHALLENGE_WORDS:
        raise ValueError(f'a challenge has {CHALLENGE_WORDS} words, not {len(words)}')
    algorithm(words)
    if words[1] & 0xffff != CHALLENGE_BODY_BYTES or words[1] >> 26:
        raise ValueError(f'challenge length word {words[1]:#010x}: the body is {CHALLENGE_BODY_BYTES} bytes')
    return dict(perm_req=(words[1] >> 16) & 0xff, lc=LIFECYCLES[(words[1] >> 24) & 3], digest=list(words[2:10]),
                nonce=list(words[10:18]), por_counter=words[18] | (words[19] << 32))

def rotl(x, r):
    return ((x << r) | (x >> (32 - r))) & 0xffffffff if r else x

def test_signature(challenge, granted=1):
    """The TEST "signature" of a challenge and a granted-mask byte:
    word i is key[i], the mask in every byte, and the challenge words
    i, i+8, i+16, each rotated left by i, all XORed (window.c)."""
    sig = []
    for i in range(TEST_SIG_WORDS):
        a = TEST_KEY[i] ^ (granted * 0x01010101)
        for j in range(i, CHALLENGE_WORDS, TEST_SIG_WORDS):
            a ^= rotl(challenge[j], i)
        sig.append(a & 0xffffffff)
    return sig

def load_key(path=None):
    """The 32-byte SHA3 key from a file of 64 hex digits: path, else
    KARU_BOARD_AUTH_KEY, else KEY_FILE. Never shows the file's content."""
    path = Path(path or os.environ.get('KARU_BOARD_AUTH_KEY') or KEY_FILE)
    if not path.is_file():
        raise ValueError(f'the ROM asks for SHA3 ({ALG_SHA3:#04x}) and there is no key file {path}: set KARU_BOARD_AUTH_KEY '
                         'to the key the image was built with (dbg/fpga.mk VCU118_AUTH_KEY)')
    text = path.read_text().strip()
    if not re.fullmatch(r'[0-9a-fA-F]{64}', text):
        raise ValueError(f'{path} is not a key of 64 hex digits (content not shown)')
    return bytes.fromhex(text)

def sha3_signature(challenge, granted=1, key=None):
    """The SHA3 (0x04) MAC of a challenge and a granted-mask byte, as 8 little-endian words."""
    key = load_key() if key is None else key
    digest = hashlib.sha3_256(key + MAC_LABEL + struct.pack('<20I', *challenge) + bytes([granted])).digest()
    return list(struct.unpack('<8I', digest))

def response(challenge, granted=1):
    """The RESPONSE frame for a challenge: header, length and mask, then
    the signature of the algorithm that the challenge's header names. A
    word 0 that is no CHALLENGE header gets TEST, as before SHA3 existed
    (the harness self-test sends random words); auth_phase.py has checked
    the challenge with parse_challenge before it asks for a response."""
    alg = algorithm(challenge) if challenge[0] & ~0xff00 == frame_header(CHALLENGE, 0) else ALG_TEST
    sig = sha3_signature(challenge, granted) if alg == ALG_SHA3 else test_signature(challenge, granted)
    return [frame_header(RESPONSE, alg), (granted << 16) | (4 * len(sig))] + sig

# ---- the mailbox, through OpenOCD ----
class Mailbox:
    def __init__(self, board, target='karu.cpu', poll=0.05):
        self.b, self.target, self.poll = board, target, poll

    def examine(self):
        """Ask OpenOCD to examine the target. True if it attached; False if
        it was refused. The first attempt also sets OpenOCD up for the DMI
        and authdata commands, which is why every case starts with it."""
        try:
            self.b.cmd(f'{self.target} arp_examine')
        except RuntimeError:
            pass
        return self.b.cmd(f'{self.target} was_examined') == '1'

    def activate(self, on=1):
        """Write dmactive and wait for it to read back. After a power-on
        reset the Debug Module is inactive and authdata does not answer;
        writing 0 and then 1 is what a reconnecting debugger does, and it
        resets the mailbox session."""
        self.b.dmi(DMCONTROL, on)
        end = time.monotonic() + 5
        while self.b.dmi(DMCONTROL) & 1 != on:
            if time.monotonic() > end:
                raise TimeoutError(f'dmcontrol.dmactive did not become {on}')

    def dmstatus(self):
        return self.b.dmi(DMSTATUS)

    def authenticated(self):
        return bool(self.dmstatus() & AUTHENTICATED)

    def read(self):
        return int(self.b.cmd('riscv authdata_read'), 0)

    def write(self, word):
        self.b.cmd(f'riscv authdata_write {word:#010x}')

    def status(self):
        """The status word. A STATUS header first cancels a RECV that an
        interrupted exchange may have left pending. Not to be used between a
        SEND header and its last payload word: the write would be payload."""
        self.write(header(OP_STATUS))
        return parse_status(self.read())

    def request(self, mask=1):
        self.write(request_word(mask))

    def abort(self):
        self.write(header(OP_ABORT))

    def receive(self, count, timeout):
        """Take count words from TX as the ROM pushes them. The FIFO holds
        sixteen, so a challenge comes in more than one RECV."""
        words, end = [], time.monotonic() + timeout
        while len(words) < count:
            s = self.status()
            n = min(s['tx_available'], count - len(words))
            if n:
                self.write(header(OP_RECV, n))
                words += [self.read() for _ in range(n)]
            elif not s['mailbox'] or s['state'] != 'REQUESTED' or time.monotonic() > end:
                raise TimeoutError(f"{len(words)} of {count} words received; mailbox state {s['state']}, error {s['error']}, "
                                   f"status {s['word']:#010x}")
            else:
                time.sleep(self.poll)
        return words

    def send_header(self, count):
        """A SEND header alone, and the status word after it: 'send_remaining'
        is count if the mailbox took it, and 'error' says why if it did not.
        A plain read is used, since a STATUS write would count as payload."""
        self.write(header(OP_SEND, count))
        return parse_status(self.read())

    def send(self, words):
        """One SEND with its payload words. Nothing is written after a
        refused header: the mailbox would parse the payload as headers."""
        s = self.send_header(len(words))
        if s['send_remaining'] != len(words):
            raise RuntimeError(f"SEND {len(words)} refused: mailbox state {s['state']}, error {s['error']}, status {s['word']:#010x}")
        for word in words:
            self.write(word)

    def wait_state(self, state, timeout):
        """Poll until the mailbox reports a state; returns (status, seconds), or raises TimeoutError."""
        start = time.monotonic()
        while True:
            s = self.status()
            if s['state'] == state:
                return s, time.monotonic() - start
            if time.monotonic() - start > timeout:
                raise TimeoutError(f"mailbox state is {s['state']}, not {state}, after {timeout:.0f} s (status {s['word']:#010x})")
            time.sleep(self.poll)

    def wait_decision(self, timeout):
        """After a complete response: True once dmstatus.authenticated is
        set, False once the window has closed without it. The ROM grants
        before it leaves, so a closed window with no grant is final. Raises
        TimeoutError if neither happens."""
        end = time.monotonic() + timeout
        while True:
            if self.authenticated():
                return True
            if self.status()['state'] == 'CLOSED':
                return self.authenticated()
            if time.monotonic() > end:
                raise TimeoutError(f'no decision within {timeout:.0f} s: not authenticated, and the window is still open')
            time.sleep(self.poll)
