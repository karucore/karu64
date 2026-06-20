#!/usr/bin/env python3
# uart_drive.py <port> <baud> [logfile]
# Robust fu-boot / U-Boot command driver that works around the intermittent karu NS16550
# RX doubled-character glitch. For each stdin line it types the command CHARACTER BY
# CHARACTER, reads the echo, and computes the VISIBLE line (applying backspace edits); if
# that does not exactly equal the command it CLEARS the line with backspaces (NEVER CR --
# a CR would execute a corrupted command, e.g. boot's address) and retries. CR is sent
# only once the visible line matches. fu-boot + U-Boot both honour 0x7f/0x08 backspace.
#
# Control lines (not sent): "@wait <s>" capture window after the next command (default 2);
#   "@tries <n>" echo-verify retries (default 6). RTS asserted (NS16550 TX is CTS-gated).
import sys, time, threading, serial

port = sys.argv[1]; baud = int(sys.argv[2])
logp = sys.argv[3] if len(sys.argv) > 3 else None
ser = serial.Serial(port, baud, timeout=0.05, rtscts=False)
ser.rts = True; ser.dtr = True
log = open(logp, "ab", buffering=0) if logp else None

buf = bytearray(); lock = threading.Lock(); stop = False
def emit(b):
    sys.stdout.buffer.write(b); sys.stdout.flush()
    if log: log.write(b)
def reader():
    while not stop:
        d = ser.read(256)
        if d:
            with lock: buf.extend(d)
            emit(d)
threading.Thread(target=reader, daemon=True).start()
def drain(sec):
    end = time.time() + sec
    while time.time() < end: time.sleep(0.02)

def visible(b):
    out = []
    for ch in b.decode("latin1"):
        if ch in "\x08\x7f":
            if out: out.pop()
        elif " " <= ch < "\x7f":
            out.append(ch)
    return "".join(out)

def clear_line(n):
    ser.write(b"\x7f" * n); ser.flush(); drain(0.2)

ERR_MARKERS = (b"Unknown command", b"Usage:", b"- try 'help'",
               b"Bad Linux RISCV Image magic", b"Bad Magic", b"Wrong Ramdisk",
               b"Bad FDT", b"ERROR: Did not")
def send_cmd(cmd, tries):
    for t in range(tries):
        clear_line(len(cmd) + 12)          # erase any partial/garbled line (no CR!)
        with lock: mark = len(buf)
        for ch in cmd.encode():
            ser.write(bytes([ch])); ser.flush(); time.sleep(0.012)
        drain(0.5)
        with lock: echo = bytes(buf[mark:])
        if visible(echo) != cmd:           # echo-level glitch -> clear + retype
            emit(("[uart_drive] echo-mismatch try %d: visible=%r\n" % (t + 1, visible(echo))).encode())
            continue
        #  echo is clean; execute, then verify the parse didn't glitch (echo/parse can
        #  diverge under the RX doubled-char fault -> "Unknown command 'xx..'"/"Usage:")
        with lock: pmark = len(buf)
        ser.write(b"\r"); ser.flush(); drain(0.7)
        with lock: post = bytes(buf[pmark:])
        if any(m in post for m in ERR_MARKERS):
            emit(("[uart_drive] parse-glitch try %d (retrying): %r\n" % (t + 1, post[:60])).encode())
            continue
        return True
    clear_line(len(cmd) + 12)              # give up WITHOUT executing a corrupted line
    emit(b"[uart_drive] GAVE UP\n")
    return False

cap = 2.0; tries = 6
ser.write(b"\r"); drain(1.5)
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("@wait"): cap = float(line.split()[1]); continue
    if line.startswith("@tries"): tries = int(line.split()[1]); continue
    if not line.strip(): continue
    emit(("\n>>> SEND: %s\n" % line).encode())
    send_cmd(line, tries)
    drain(cap); cap = 2.0
stop = True; time.sleep(0.3); ser.close()
