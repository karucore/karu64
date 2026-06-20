#!/usr/bin/env python3
# mkmcs.py <payload> <offset_hex> <out.mcs> -- emit an Intel-HEX MCS that stores
# the payload file VERBATIM at the given flash byte offset.
#
# Vivado's write_cfgmem -loaddata silently gunzips .gz inputs (it stores the
# DECOMPRESSED bytes), which corrupts a gzip stream the monitor's `flashgz`
# expects to inflate itself. This builds the MCS by hand so the exact bytes
# (e.g. a real 1f 8b... gzip) land in flash. program_hw_cfgmem writes the MCS
# bytes as-is, so the verbatim payload reaches flash.
import sys

def ihex(rectype, addr, data):
    n = len(data)
    rec = [n, (addr >> 8) & 0xff, addr & 0xff, rectype] + list(data)
    chk = (-sum(rec)) & 0xff
    return ":" + bytes(rec + [chk]).hex().upper()

payload, offset, out = sys.argv[1], int(sys.argv[2], 0), sys.argv[3]
data = open(payload, "rb").read()
lines, upper = [], None
for i in range(0, len(data), 16):
    addr = offset + i
    hi = (addr >> 16) & 0xffff
    if hi != upper:                       # extended linear address record
        lines.append(ihex(0x04, 0, [hi >> 8, hi & 0xff]))
        upper = hi
    lines.append(ihex(0x00, addr & 0xffff, data[i:i + 16]))
lines.append(":00000001FF")
open(out, "w").write("\n".join(lines) + "\n")
print("wrote %s: %d bytes @ 0x%x" % (out, len(data), offset))
