#!/usr/bin/env python3
# uart_cl.py <port> <baud> <logfile> -- CLOSED-LOOP console driver for the karu64
# NS16550. The host->FPGA RX path intermittently DOUBLES/garbles characters, but
# the FPGA echo (TX->host) is clean and reflects its TRUE line-buffer state (it
# even parses the corrupted text). So we drive each command one byte at a time:
# send a byte, read the echo, recompute the visible buffer, and emit a single-byte
# edit -- DEL (0x7f) to drop an extra/garbled char, or the next needed char --
# until visible == command; only then CR. Per-byte correction converges on long
# lines where uart_drive.py's whole-line retype keeps losing the pass.
#
# stdin: one command per line; "@wait <s>" sets the capture window after the NEXT
# command (default 2s); blank lines ignored. Concise progress -> stdout; full raw
# console -> logfile (append, unbuffered). RTS asserted (NS16550 TX is CTS-gated).
import sys, time, threading, serial

port, baud, logp = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ser = serial.Serial(port, baud, timeout=0.05, rtscts=False)
ser.rts = True; ser.dtr = True
log = open(logp, "ab", buffering=0)

buf = bytearray(); lock = threading.Lock(); stop = False
def status(s): sys.stdout.write(s); sys.stdout.flush()
def reader():
    while not stop:
        d = ser.read(512)
        if d:
            with lock: buf.extend(d)
            log.write(d)                      # full raw console -> logfile only
threading.Thread(target=reader, daemon=True).start()

def drain(sec):
    end = time.time() + sec
    while time.time() < end: time.sleep(0.01)

def visible(b):
    out = []
    for ch in b.decode("latin1", "replace"):
        if ch in "\x08\x7f":
            if out: out.pop()
        elif " " <= ch < "\x7f":
            out.append(ch)
    return "".join(out)

def put(x):                                   # send one byte, wait for its echo
    with lock: m = len(buf)
    ser.write(x); ser.flush()
    t = time.time()
    while time.time() - t < 0.5:
        drain(0.03)
        with lock:
            if len(buf) > m: break
    drain(0.04)

def type_line(cmd):
    drain(0.25)
    with lock: mark = len(buf)                 # mark at the (quiescent) prompt
    cap = 20 * (len(cmd) + 4); steps = 0
    while steps < cap:
        with lock: cur = visible(bytes(buf[mark:]))
        if cur == cmd:
            ser.write(b"\r"); ser.flush(); drain(0.6)
            return True, steps
        n = 0
        while n < len(cur) and n < len(cmd) and cur[n] == cmd[n]: n += 1
        put(b"\x7f" if len(cur) > n else cmd[n:n+1].encode())
        steps += 1
    return False, steps

ser.write(b"\r"); drain(1.0)                   # fresh prompt
cap = 2.0
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if line.startswith("@wait"): cap = float(line.split()[1]); continue
    if not line.strip(): continue
    status(">>> %-32s " % line)
    ok, steps = type_line(line)
    status(("OK (%d edits)\n" % steps) if ok else ("FAILED (%d edits, gave up)\n" % steps))
    drain(cap); cap = 2.0
stop = True; time.sleep(0.3); ser.close()
