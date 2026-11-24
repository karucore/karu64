#!/usr/bin/env python3
"""Self-test of the strap-variant checks, without Vivado and without an image
(make strap-flow-test): flow/strap_diff.py and flow/rom_record.py on small
generated .bit files that have the structure of a VCU118 bitstream: the
five-field header, a sync word, type 1 and type 2 packets, frame data in an
FDRI write, CRC writes, and the stream of another die as the data of a write
to BOUT.

What must pass: a variant that differs from its base in whole strap tables
(one in each die's frame data) or a half table (one byte per frame), in the
check bits of those frames, recomputed and right in both files, and in the
CRC words behind them; a table in bytes 184 and 185, which are frame data; an
image and a base whose payloads are the same while their headers differ; the
record of a conversion and its verification; a ROM image tied to its
bitstream, and the island ROM's fresh check.

What must fail, each for its own reason: a stray bit in frame data; a table
of three parts; parts not in consecutive frames; a part with only some bits
of a byte turned; 24 bits side by side; check bits that differ where nothing
else does, or are wrong in the base or the variant; frame data changed and
its CRC not; a CRC changed in a stream whose
frames are the same; a changed command word in front of byte 512, where a
checker that skipped a fixed-size "header" would not look; a changed packet
header; changed padding in front of the sync word; another part name;
another payload length; a strap count that is not the conversion's; a base
that is not the image; a record for another image; a variant whose lane is
not among its rings; a ROM image packed again after the build; a bitstream
not newer than the ROM's hash.

Last, the record steps of every recipe that runs the image build, in the
Makefile's text and in dry runs (make -n) with stand-ins for the boot files
from beside the repository, with and without SYNTH_ONLY, with controls.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, json, os, struct, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--out", required=True)
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DIFF, ROM = str(ROOT / "flow/strap_diff.py"), str(ROOT / "flow/rom_record.py")
FRAME = 372

checks = 0
def check(ok, what, detail=""):
    global checks
    checks += 1
    if not ok:
        print(f"FAIL strap flow self-test check {checks}: {what} {detail}")
        sys.exit(1)
    print(f"ok   {what}")

def w(v): return struct.pack(">I", v)
def t1(reg, *data): return w((1 << 29) | (2 << 27) | (reg << 13) | len(data)) + b"".join(w(d) for d in data)
def t2(reg, data): return w((1 << 29) | (2 << 27) | (reg << 13)) + w((2 << 29) | (2 << 27) | (len(data) // 4)) + data
NOP = w(0x20000000)

# The check bits of an UltraScale+ frame, written out here from the description of Project X-Ray
# (tools/bits2rbt/ecc.cc) apart from the copy in flow/strap_diff.py: 48 bits in word 45 and the low half
# of word 46; each set bit of the other words adds a pattern made of its word, its nibble and an odd
# parity bit, one bit per nibble, shifted by the bit's place in its nibble.
def ecc_of(frame):
    code = 0
    for word in range(93):
        v = int.from_bytes(frame[4 * word:4 * word + 4], "big")
        v = 0 if word == 45 else v & 0xffff0000 if word == 46 else v
        for bit in range(32):
            if v >> bit & 1:
                o = (word + 163) << 3 | bit // 4
                o |= (1 - bin(o).count("1") % 2) << 11
                code ^= sum(1 << 4 * i for i in range(12) if o >> i & 1) << bit % 4
    return code

def sealed(fr, which=None):
    """The frames with their check bits made right (all of them, or the ones listed)."""
    f = bytearray(fr)
    for k in range(len(f) // FRAME) if which is None else which:
        c = ecc_of(f[k * FRAME:(k + 1) * FRAME])
        f[k * FRAME + 180:k * FRAME + 184] = (c & 0xffffffff).to_bytes(4, "big")
        f[k * FRAME + 186:k * FRAME + 188] = (c >> 32).to_bytes(2, "big")
    return f

def frames(n, seed):
    """n frames of data that is neither all zeros nor all ones, with one strap table of zeros at frame 5,
    and their check bits right."""
    d = bytearray((seed * 131 + i * 7) % 251 for i in range(n * FRAME))
    for i in range(4):
        d[(5 + i) * FRAME + 100:(5 + i) * FRAME + 102] = b"\x00\x00"
    return sealed(d)

def stream(fr, crc, inner=b""):
    s = b"\xff" * 64 + w(0x000000BB) + w(0x11220044) + b"\xff" * 8 + w(0xAA995566) + NOP
    s += t1(17, 0) + t1(9, 0x38003FE5) + t1(12, 0x04B31093) + t1(4, 1) + NOP + t2(2, bytes(fr)) + t1(0, crc) + NOP * 2
    s += t1(4, 5) + t1(0, 0x1234ABCD) + t1(4, 0xD) + NOP * 4
    if inner:
        s += b"\xff" * 32 + w(0xAA995566) + t1(4, 0xB) + t2(30, inner + b"\xff" * (-len(inner) % 4)) + t1(4, 0xD) + NOP * 2
    return s

def bit(name, payload, part="xcvu9p-flga2104-2L-e", date="2026/11/21", clock="10:00:00", design="vcu118_ddr_top;UserID=0XFFFFFFFF"):
    def field(key, text):
        t = text.encode() + b"\0"
        return key + struct.pack(">H", len(t)) + t
    d = bytes.fromhex("00090ff00ff00ff00ff0000001") + field(b"a", design) + field(b"b", part) + field(b"c", date) + field(b"d", clock)
    d += b"e" + struct.pack(">I", len(payload)) + payload
    (OUT / name).write_bytes(d)
    return bytearray(d)

def run(tool, *a):
    r = subprocess.run([sys.executable, tool, *a], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

def turned(fr, frame=5, at=100, parts=4, step=1, seal=True):
    f = bytearray(fr)
    for i in range(parts):
        o = (frame + i * step) * FRAME + at
        f[o:o + 2] = bytes(b ^ 0xff for b in f[o:o + 2])
    return sealed(f, [frame + i * step for i in range(parts)]) if seal else f

# ---- the files: an image, the base written again (another date), and variants ----
f0, f1 = frames(12, 1), frames(10, 2)
payload = stream(f0, 0x11111111, stream(f1, 0x22222222))
image = bit("image.bit", payload, date="2026/11/20", clock="00:09:47")
base = bit("base.bit", payload)
one = bit("one.bit", stream(turned(f0), 0x33333333, stream(f1, 0x22222222)))
two = bit("two.bit", stream(turned(f0), 0x33333333, stream(turned(f1), 0x44444444)))
p = str(OUT)
at_frames = base.index(bytes(f0))               # where the first die's frame data is in the file

rc, out = run(DIFF, "packets", f"{p}/base.bit")
check(rc == 0 and out.count("sync") == 3 and "register 30 write" in out and "register 2  write 1116 words" in out
      and "register 2  write 930 words" in out and out.count("register 0  write") == 4,
      "the packets of a generated file are found, the other die's stream inside the BOUT write too", out[-300:])
check(base.index(struct.pack(">I", 0x38003FE5)) < 512, "the generated file has command words in front of byte 512, as a real one has")

rc, out = run(DIFF, "same", f"{p}/image.bit", f"{p}/base.bit")
check(rc == 0 and "the same byte for byte" in out and "date, time" in out, "image and base: the same payload, other date and time", out)
rc, out = run(DIFF, "compare", f"{p}/base.bit", f"{p}/one.bit", "--straps", "1")
check(rc == 0 and "1 look-up tables" in out and "1 CRC word behind" in out, "a variant with one table turned in the first die", out)
rc, out = run(DIFF, "compare", f"{p}/base.bit", f"{p}/two.bit", "--straps", "2")
check(rc == 0 and "2 look-up tables" in out and "2 CRC words behind" in out, "a variant with a table turned in each die, a CRC word behind each", out)
check(turned(f0, seal=False) == turned(f0), "turning all 16 bits of a part leaves the frame's check bits as they were")
# a strap in one half of a table: one byte per frame, and the four frames' check bits with it
def half(fr, frame=5, at=100, check=True):
    f = bytearray(fr)
    for i in range(4):
        f[(frame + i) * FRAME + at] ^= 0xff
    return sealed(f, range(frame, frame + 4)) if check else f
hf = half(f0)
check(all(hf[k * FRAME + 180:k * FRAME + 188] != f0[k * FRAME + 180:k * FRAME + 188] for k in range(5, 9)),
      "turning 8 bits of a part changes the frame's check bits")
check(all(hf[k * FRAME + 184:k * FRAME + 186] == f0[k * FRAME + 184:k * FRAME + 186] for k in range(5, 9)),
      "the high half of word 46 is not check bits: it stays")
bit("half.bit", stream(hf, 0x33333333, stream(f1, 0x22222222)))
rc, out = run(DIFF, "compare", f"{p}/base.bit", f"{p}/half.bit", "--straps", "1")
check(rc == 0 and "1 half tables" in out and "right for their contents in both files (4 frames)" in out,
      "a variant with half a table turned, and the check bits of its four frames recomputed and right", out)
# bytes 184 and 185 of a frame (the high half of word 46) are frame data: a table may sit there
fh = bytearray(f0)
for k in range(1, 5):
    fh[k * FRAME + 184:k * FRAME + 186] = b"\x00\x00"
fh = sealed(fh)
bit("baseh.bit", stream(fh, 0x11111111, stream(f1, 0x22222222)))
bit("tab184.bit", stream(turned(fh, frame=1, at=184), 0x33333333, stream(f1, 0x22222222)))
rc, out = run(DIFF, "compare", f"{p}/baseh.bit", f"{p}/tab184.bit", "--straps", "1")
check(rc == 0 and "1 whole tables" in out, "a table in bytes 184 and 185 of four frames, the high half of word 46: frame data, not check bits", out)

# ---- what must fail, and why ----
def refused(name, data, why, straps="1", other="base.bit", mode="compare"):
    (OUT / "x.bit").write_bytes(bytes(data))
    a = [mode, f"{p}/{other}", f"{p}/x.bit"] + (["--straps", straps] if mode == "compare" else [])
    rc, out = run(DIFF, *a)
    check(rc == 1 and why in out, f"refused: {name}", out[-200:])

x = bytearray(one); x[at_frames + 9 * FRAME + 7] ^= 1
refused("a stray bit in frame data", x, "something other than whole bytes turned")
refused("a table of three parts", bit("x.bit", stream(turned(f0, parts=3), 0x33333333, stream(f1, 0x22222222))), "not four parts of one table")
fz = bytearray(f0)                                  # zeros at one place in frames 1, 3, 5 and 7
for k in (1, 3, 5, 7):
    fz[k * FRAME + 200:k * FRAME + 202] = b"\x00\x00"
bit("basez.bit", stream(fz, 0x11111111, stream(f1, 0x22222222)))
refused("four parts in every other frame", bit("x.bit", stream(turned(fz, frame=1, at=200, step=2), 0x33333333, stream(f1, 0x22222222))),
        "not four parts of one table", other="basez.bit")
x = bytearray(one); x[at_frames + 5 * FRAME + 100] ^= 0x10
refused("a part with only some bits of a byte turned", x, "something other than whole bytes turned")
refused("frame data changed and its CRC word not", bit("x.bit", stream(turned(f0), 0x11111111, stream(f1, 0x22222222))), "whose CRC words do not")
refused("a CRC word changed in a stream whose frames are the same", bit("x.bit", stream(turned(f0), 0x33333333, stream(f1, 0x55555555))), "no frame data before it in its stream")
x = bytearray(one); x[at_frames + 9 * FRAME + 183] ^= 0x0f
refused("the check bits of a frame in which nothing else differs", x, "the check bits of frame 9 differ")
fw = bytearray(f0)                                  # a third byte of zeros beside the table's two
for k in range(4):
    fw[(5 + k) * FRAME + 102] = 0
bit("basew.bit", stream(fw, 0x11111111, stream(f1, 0x22222222)))
wide = bytearray(turned(fw))
for k in range(4):
    wide[(5 + k) * FRAME + 102] ^= 0xff
refused("24 bits side by side in four frames", bit("x.bit", stream(wide, 0x33333333, stream(f1, 0x22222222))), "more than 16 bits side by side", other="basew.bit")
refused("half a table in three frames", bit("x.bit", stream(half(f0)[:8 * FRAME] + f0[8 * FRAME:], 0x33333333, stream(f1, 0x22222222))),
        "not four parts of one table")
refused("half a table turned and the check bits left as they were", bit("x.bit", stream(half(f0, check=False), 0x33333333, stream(f1, 0x22222222))),
        "the check bits of frame 5 (byte")
x = bytearray(hf); x[6 * FRAME + 187] ^= 0x01
refused("half a table turned and one check bit of a frame wrong", bit("x.bit", stream(x, 0x33333333, stream(f1, 0x22222222))),
        "the check bits of frame 6 (byte")
x = bytearray(f0); x[7 * FRAME + 182] ^= 0x40
bit("basebad.bit", stream(x, 0x11111111, stream(f1, 0x22222222)))
x = half(x)                                         # its variant: frames 5 to 8 sealed again, so frame 7's check bits right
refused("a base whose check bits are wrong in a frame the variant changes", bit("x.bit", stream(x, 0x33333333, stream(f1, 0x22222222))),
        "in the base are", other="basebad.bit")
x = bytearray(one); x[at_frames + 9 * FRAME + 184] ^= 0x01
refused("one bit of the high half of word 46: frame data, not check bits", x, "something other than whole bytes turned")
x = bytearray(one); i = x.index(struct.pack(">I", 0x38003FE5)); x[i + 3] ^= 4
refused("a changed command word in front of byte 512", x, "neither frame data nor a CRC")
x = bytearray(one); x[i - 2] ^= 0x20                     # the register field of that packet's header
refused("a changed packet header", x, "do not have the same packets")
j = one.index(struct.pack(">I", 0x000000BB)) - 20
x = bytearray(one); x[j] ^= 1
refused("changed padding in front of the sync word", x, "not in the data of a write")
refused("another part", bit("x.bit", stream(turned(f0), 0x33333333, stream(f1, 0x22222222)), part="xcvu13p-flga2104-2L-e"), "not of one part")
refused("another payload length", bit("x.bit", stream(turned(f0), 0x33333333, stream(f1, 0x22222222)) + b"\xff" * 4), "not of one part, header length and payload length")
refused("one table, where the conversion changed two straps", one, "the conversion changed 2 strap bits", straps="2")
refused("no difference at all", base, "the payloads are the same")
x = bytearray(base); x[i + 3] ^= 4
refused("a base that is not the image: a command word differs", x, "the checkpoint is not the design of the image", other="image.bit", mode="same")
refused("a base that is not the image: a table differs", one, "the checkpoint is not the design of the image", other="image.bit", mode="same")

# ---- the record of a conversion, and its verification ----
def log(built, written, changed, name="one.bit"):
    f = lambda v: f"KARU_STRAP lane={v[0]} kshift={v[1]} (k at least {16 << v[1]}) rings=0x{v[2]:02x}"
    (OUT / "conv.log").write_text(f"{f(built)}\n{f(written)}\nKARU_STRAP_CHANGED {changed}\n"
                                  f"KARU_STRAP_VARIANT {name} lane={written[0]} kshift={written[1]} rings=0x{written[2]:02x} from route.dcp\n")
(OUT / "route.dcp").write_bytes(b"a stand-in for the routed checkpoint\n")
def record(*extra):
    (OUT / "base2.bit").write_bytes((OUT / "base.bit").read_bytes())
    return run(DIFF, "record", "--image", f"{p}/image.bit", "--base", f"{p}/base2.bit", "--variant", f"{p}/one.bit",
               "--checkpoint", f"{p}/route.dcp", "--log", f"{p}/conv.log", "--out", f"{p}/one.strap.json", *extra)
log((0, 0, 0x0f), (0, 1, 0x0f), 1)
rc, out = record("--remove-base")
rec = json.loads((OUT / "one.strap.json").read_text()) if rc == 0 else {}
check(rc == 0 and rec.get("straps_as_written") == dict(lane=0, kshift=1, rings=15) and len(rec.get("tables", [])) == 1
      and not (OUT / "base2.bit").exists(), "a conversion is recorded: image, checkpoint, variant and log by hash, the straps, the table; the base is removed", out)
rc, out = run(DIFF, "verify", "--record", f"{p}/one.strap.json", "--image", f"{p}/image.bit", "--variant", f"{p}/one.bit")
check(rc == 0, "the record is verified against its image and variant", out)
rc, out = run(DIFF, "verify", "--record", f"{p}/one.strap.json", "--image", f"{p}/base.bit", "--variant", f"{p}/one.bit")
check(rc == 1 and "does not describe image" in out, "refused: a record offered for another image (the same design, written again)", out)
rc, out = run(DIFF, "verify", "--record", f"{p}/one.strap.json", "--image", f"{p}/image.bit", "--variant", f"{p}/two.bit")
check(rc == 1 and "does not describe variant" in out, "refused: a record offered for another variant", out)
log((0, 0, 0x0f), (0, 1, 0x0f), 2)
rc, out = record()
check(rc == 1 and "its values differ in 1" in out, "refused: a log whose count of changed straps is not that of its values", out)
log((0, 0, 0x0f), (0, 0, 0x0e), 1)
rc, out = record()
check(rc == 1 and "not among its running rings" in out, "refused: a variant whose lane is not among its rings", out)
log((0, 0, 0x0f), (0, 3, 0x0f), 2)
rc, out = record()
check(rc == 1 and "the conversion changed 2 strap bits" in out, "refused: a variant with one table where its log has two straps changed", out)

# ---- the boot ROM image tied to its bitstream ----
(OUT / "rom.hex").write_text("0000000000000001\n")
rc, out = run(ROM, "before", "--rom", f"{p}/rom.hex", "--out", f"{p}/rom.before")
(OUT / "built.bit").write_bytes(bytes(image))
rc2, out2 = run(ROM, "write", "--bit", f"{p}/built.bit", "--rom", f"{p}/rom.hex", "--before", f"{p}/rom.before", "--out", f"{p}/rom.json")
check(rc == 0 and rc2 == 0, "a ROM image is hashed before a build and tied to the bitstream after it", out + out2)
mark = os.stat(OUT / "rom.before").st_mtime_ns
os.utime(OUT / "built.bit", ns=(mark, mark))
(OUT / "rom3.json").unlink(missing_ok=True)         # left by an earlier run of this test
rc, out = run(ROM, "write", "--bit", f"{p}/built.bit", "--rom", f"{p}/rom.hex", "--before", f"{p}/rom.before", "--out", f"{p}/rom3.json")
check(rc == 1 and "not newer than this build's start" in out and not (OUT / "rom3.json").exists(),
      "refused: a bitstream with exactly the hash's time stamp is not newer than it", out)
os.utime(OUT / "built.bit", ns=(mark + 1, mark + 1))
rc, out = run(ROM, "write", "--bit", f"{p}/built.bit", "--rom", f"{p}/rom.hex", "--before", f"{p}/rom.before", "--out", f"{p}/rom3.json")
check(rc == 0, "a bitstream one nanosecond newer than the hash is", out)
rc, out = run(ROM, "verify", "--record", f"{p}/rom.json", "--bit", f"{p}/built.bit", "--rom", f"{p}/rom.hex")
check(rc == 0, "the ROM record is verified", out)
(OUT / "rom.hex").write_text("0000000000000002\n")
rc, out = run(ROM, "verify", "--record", f"{p}/rom.json", "--bit", f"{p}/built.bit", "--rom", f"{p}/rom.hex")
check(rc == 1 and "packed again" in out, "refused: a ROM image packed again after the build, whatever its time stamp", out)
rc, out = run(ROM, "write", "--bit", f"{p}/built.bit", "--rom", f"{p}/rom.hex", "--before", f"{p}/rom.before", "--out", f"{p}/rom2.json")
check(rc == 1 and "changed while the image was built" in out, "refused: a ROM image that changed while the image was built", out)
(OUT / "rom.hex").write_text("0000000000000001\n")
rc, out = run(ROM, "verify", "--record", f"{p}/rom.json", "--bit", f"{p}/one.bit", "--rom", f"{p}/rom.hex")
check(rc == 1 and "not the bitstream of the record" in out, "refused: the ROM record offered for another bitstream", out)

# ---- fresh: the island ROM of the debug image, the write's checks without a record ----
(OUT / "isl.hex").write_text("00000000000000aa\n")
rc, out = run(ROM, "before", "--rom", f"{p}/isl.hex", "--out", f"{p}/isl.before")
(OUT / "built2.bit").write_bytes(bytes(image))
rc2, out2 = run(ROM, "fresh", "--bit", f"{p}/built2.bit", "--rom", f"{p}/isl.hex", "--before", f"{p}/isl.before")
check(rc == 0 and rc2 == 0 and "unchanged since" in out2 and not (OUT / "isl.json").exists(),
      "fresh: a bitstream written after the island ROM was hashed, the ROM unchanged; no record written", out2)
os.utime(OUT / "built2.bit", (1, 1))
rc, out = run(ROM, "fresh", "--bit", f"{p}/built2.bit", "--rom", f"{p}/isl.hex", "--before", f"{p}/isl.before")
check(rc == 1 and "not newer than this build's start" in out, "fresh refuses a bitstream older than the hash: the build did not write it", out)
mark = os.stat(OUT / "isl.before").st_mtime_ns
os.utime(OUT / "built2.bit", ns=(mark, mark))
rc, out = run(ROM, "fresh", "--bit", f"{p}/built2.bit", "--rom", f"{p}/isl.hex", "--before", f"{p}/isl.before")
check(rc == 1 and "not newer than this build's start" in out, "fresh refuses a bitstream with exactly the hash's time stamp", out)
(OUT / "built2.bit").write_bytes(bytes(image))
(OUT / "isl.hex").write_text("00000000000000ab\n")
rc, out = run(ROM, "fresh", "--bit", f"{p}/built2.bit", "--rom", f"{p}/isl.hex", "--before", f"{p}/isl.before")
check(rc == 1 and "changed while the image was built" in out, "fresh refuses an island ROM that changed during the build", out)

# ---- the record steps of the recipes that build an image ----
# Every recipe that runs the image build hashes the boot ROM after packing it and before Vivado, and
# writes the record after Vivado, except in a synthesis-only run; the debug image also hashes its
# island ROM before the build and writes its authentication record only after the check that a new
# bitstream was written. Checked twice: in the Makefile's text, for every such recipe, and in what
# make would run (make -n) for the image targets whose inputs are here.
import re
MK = (ROOT / "Makefile").read_text()
def recipes_ok(text):
    """The recipes that run xcvu9p-ddr-synth.tcl, each with the hash before and the record after Vivado."""
    found, bad = [], []
    for m in re.finditer(r"^([A-Za-z0-9_.\-]+):[^\n=]*\n((?:\t[^\n]*\n|#[^\n]*\n)+)", text, re.M):
        body = m.group(2)
        if "xcvu9p-ddr-synth.tcl" not in body:
            continue
        found.append(m.group(1))
        v, h, r = body.find("vivado -mode batch"), body.find("$(VCU118_ROM_HASH_BEFORE)"), body.find("$(VCU118_ROM_RECORD_AFTER)")
        if not (0 <= h < v < r):
            bad.append(m.group(1))
    return found, bad
found, bad = recipes_ok(MK)
check(len(found) >= 4 and not bad and {"vcu118_ddr.bit", "vcu118-ddr-sgmii-rom", "vcu118-ddr-sgmii-rom-gc", "vcu118-ddr-sgmii-rom-vec"} <= set(found),
      "every recipe that runs the image build hashes the ROM before Vivado and records it after", f"{found}, without: {bad}")
mutant = MK.replace("\t$(VCU118_ROM_RECORD_AFTER)\n", "", 1)
check(recipes_ok(mutant)[1] != [], "control: a recipe without the record after Vivado is found", "")
mutant = MK.replace("\t$(VCU118_ROM_HASH_BEFORE)\n", "", 2)
check(len(recipes_ok(mutant)[1]) == 2, "control: two recipes without the hash before Vivado are found", "")

ENV = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "MAKEFILES")}
# The ROM images read boot files from beside the repository (karudeb's OpenSBI, device trees and netboot
# lines, U-Boot). A dry run needs them to exist, not to be real: stand-ins in this test's own output
# directory, named through the make variables, so that the dry runs are the same on a clean checkout.
import shutil
STAND = OUT / "standins"
shutil.rmtree(STAND, ignore_errors=True)
K = STAND / "karudeb/build/karu64"
for f in ("opensbi/fw_jump.bin", "karu64-rv64imac-ddr.dtb", "karu64-rv64gc-ddr.dtb", "karu64-zvk-ddr.dtb",
          "karu64-rva23s64-ddr.dtb", "karu64-rva23s64-zkr-ddr.dtb"):
    (K / f).parent.mkdir(parents=True, exist_ok=True)
    (K / f).write_text("stand-in\n")
for d in ("rv64gc-ddr", "zvk-ddr", "rva23s64-ddr", "rva23s64-zkr-ddr"):
    (K / "tftp" / d).mkdir(parents=True, exist_ok=True)
    (K / "tftp" / d / "uboot-netboot-one-line.txt").write_text("stand-in\n")
    (K / "tftp" / d / "board.dtb").write_text("stand-in\n")
for d in ("u-boot", "u-boot-x-netboot"):
    (STAND / d).mkdir(parents=True, exist_ok=True)
    (STAND / d / "u-boot.bin").write_text("stand-in\n")
OUTSIDE = [f"KARUDEB={STAND / 'karudeb'}", f"FUBOOT_UBOOT={STAND / 'u-boot/u-boot.bin'}", f"UBOOT_DIR={STAND / 'u-boot-x'}"]
def dry(target, *extra):
    r = subprocess.run(["make", "--no-print-directory", "-n", target, *OUTSIDE, *extra], cwd=ROOT, capture_output=True, text=True,
                       env=ENV, timeout=300)
    return r.returncode, r.stdout.splitlines()
rc, lines = dry("vcu118-ddr-sgmii-rom-rva23s64-dbg")
check(rc == 0 and not any("../karudeb" in l or "../u-boot" in l for l in lines),
      "the dry runs read the boot inputs from the stand-ins only, not from beside the repository", f"exit {rc}")
def steps(lines):
    """The record and Vivado steps of a dry run, in order, by kind."""
    out = []
    for l in lines:
        if "rom_record.py before" in l:
            out.append("hash-island" if "auth_rom" in l else "hash-rom")
        elif "vivado -mode batch -log vcu118_ddr_synth.log" in l:
            out.append("vivado")
        elif "rom_record.py write" in l:
            out.append("record-rom")
        elif "rom_record.py fresh" in l:
            out.append("fresh")
        elif "rom_record.py verify" in l:
            out.append("verify-rom")
        elif "auth_record.py write" in l:
            out.append("record-auth")
        elif "build_fuboot_rom.sh" in l:
            out.append("pack")
    return out
def order_ok(seen, debug, synth_only):
    want = (["hash-island"] if debug else []) + ["hash-rom", "vivado"]
    if not synth_only:
        want += ["record-rom"] + (["fresh", "verify-rom", "record-auth"] if debug else [])
    core = [x for x in seen if x != "pack"]
    if core != want:
        return False
    if "pack" in seen and seen.index("pack") > seen.index("hash-rom"):
        return False
    return True
for target, debug, packs in (("vcu118_ddr.bit", False, False), ("vcu118-ddr-sgmii-rom", False, True),
                             ("vcu118-ddr-sgmii-rom-gc", False, True), ("vcu118-ddr-sgmii-rom-vec", False, True),
                             ("vcu118-ddr-sgmii-rom-rva23s64", False, True), ("vcu118-ddr-sgmii-rom-rva23s64-dbg", True, True)):
    for synth_only in (False, True):
        rc, lines = dry(target, *(["SYNTH_ONLY=1"] if synth_only else []))
        seen = steps(lines)
        check(rc == 0 and order_ok(seen, debug, synth_only) and (("pack" in seen) == packs)
              and (not synth_only or sum("synthesis only" in l for l in lines) == (2 if debug else 1)),
              f"make -n {target}{' SYNTH_ONLY=1' if synth_only else ''}: " + " < ".join(seen), f"exit {rc}")
# controls of the order check, on the debug image's real steps
rc, lines = dry("vcu118-ddr-sgmii-rom-rva23s64-dbg")
seen = steps(lines)
for name, m in (("the authentication record before Vivado", [x for x in seen if x != "record-auth"][:3] + ["record-auth"] + [x for x in seen if x != "record-auth"][3:]),
                ("no check that the bitstream is new", [x for x in seen if x != "fresh"]),
                ("the ROM hashed after Vivado", [x for x in seen if x != "hash-rom"][:4] + ["hash-rom"] + [x for x in seen if x != "hash-rom"][4:]),
                ("records in a synthesis-only run", seen)):
    check(not order_ok(m, True, name == "records in a synthesis-only run"), f"control: {name} is refused", " < ".join(m))

print(f"strap flow self-test: PASS ({checks} checks)")
sys.exit(0)
