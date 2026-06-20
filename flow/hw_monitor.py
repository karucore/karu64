#!/usr/bin/env python3
# hw_monitor.py <port> <baud> [logfile]
# Drive the fu-boot monitor over the FPGA console. Reads commands from stdin,
# one per line; sends each + captures the response to stdout (and logfile).
# A line "@wait <secs>" sets the capture window for the NEXT command (default 1.5s).
# RTS is asserted because the karu NS16550 TX is CTS-gated.
import sys, time, threading, serial

port = sys.argv[1]; baud = int(sys.argv[2])
logpath = sys.argv[3] if len(sys.argv) > 3 else None
ser = serial.Serial(port, baud, timeout=0.1, rtscts=False)
ser.rts = True; ser.dtr = True
log = open(logpath, "ab", buffering=0) if logpath else None

def emit(b):
    sys.stdout.buffer.write(b); sys.stdout.flush()
    if log: log.write(b)

stop = False
def reader():
    while not stop:
        d = ser.read(4096)
        if d:
            emit(d)
t = threading.Thread(target=reader, daemon=True); t.start()

def drain(sec):
    end = time.time() + sec
    while time.time() < end:
        time.sleep(0.05)

# nudge for a fresh prompt (proves UART RX->FPGA and TX->host both work)
ser.write(b"\r"); drain(1.5)

cap = 1.5
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("@wait"):
        cap = float(line.split()[1]); continue
    if not line.strip():
        continue
    emit(("\n>>> SEND: %s\n" % line).encode())
    ser.write(line.encode() + b"\r")
    drain(cap)
    cap = 1.5

stop = True; time.sleep(0.3)
ser.close()
