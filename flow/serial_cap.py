#!/usr/bin/env python3
# serial_cap.py -- capture a serial console to a logfile (and stdout).
#
# Usage: serial_cap.py <port> <baud> <logfile>
# Reads forever, writing raw bytes to stdout and an unbuffered, line-timestamped
# copy to <logfile>. Send commands from another process by writing to the port.
import sys, time, serial

port, baud, logpath = sys.argv[1], int(sys.argv[2]), sys.argv[3]
# karu NS16550 TX is CTS-gated (.uart_cts(~usb_uart_cts_i), active-low pin), so
# the host must ASSERT RTS (rts=True drives the FPGA CTS pin low -> TX enabled).
# rtscts=False so pyserial doesn't flow-control our own writes.
ser = serial.Serial(port, baud, timeout=0.2, rtscts=False)
ser.rts = True
ser.dtr = True
log = open(logpath, "ab", buffering=0)
stamp = ("# serial_cap %s @ %d  start %s\n" %
         (port, baud, time.strftime("%Y-%m-%d %H:%M:%S"))).encode()
log.write(stamp); sys.stdout.buffer.write(stamp); sys.stdout.flush()
at_bol = True
while True:
    data = ser.read(4096)
    if not data:
        continue
    sys.stdout.buffer.write(data); sys.stdout.flush()
    for b in data:
        if at_bol:
            log.write(time.strftime("[%H:%M:%S] ").encode()); at_bol = False
        log.write(bytes([b]))
        if b == 0x0a:
            at_bol = True
