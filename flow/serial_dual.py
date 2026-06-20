#!/usr/bin/env python3
# serial_dual.py <seconds> [rts] -- capture both CP2105 ports to compare which
# carries the FPGA console. ttyUSB0 @ 2M (ECI/enhanced), ttyUSB1 @ 921600 (SCI).
# rts = "0" or "1" to set the RTS line state (FPGA TX is CTS-gated).
import serial, time, sys
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
rts = (len(sys.argv) > 2 and sys.argv[2] == "1")
ports = {}
for dev, baud in (('/dev/ttyUSB0', 2000000), ('/dev/ttyUSB1', 921600)):
    try:
        s = serial.Serial(dev, baud, timeout=0.1, rtscts=False)
        s.rts = rts; s.dtr = True
        ports[dev] = (s, baud)
    except Exception as e:
        print("OPENFAIL", dev, e)
print("RTS=%d" % rts)
t0 = time.time(); buf = {d: b'' for d in ports}
while time.time() - t0 < secs:
    for d, (s, _) in ports.items():
        n = s.in_waiting
        if n:
            buf[d] += s.read(n)
    time.sleep(0.03)
for d, (s, baud) in ports.items():
    data = buf[d]
    txt = bytes(b if 32 <= b < 127 else 46 for b in data[:120])
    print("%s@%d: %dB raw=%s txt=%r" % (d, baud, len(data), data[:48].hex(), txt))
    s.close()
