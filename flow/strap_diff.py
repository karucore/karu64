#!/usr/bin/env python3
# Check and record a strap variant of a VCU118 image (flow/fpga/karu_softstrap.v,
# flow/fpga/strap_variant.tcl, make vcu118-strap-variant).
#
# A variant is written from the routed checkpoint of an image with nothing
# changed but the look-up tables of some straps. Three bitstreams are
# compared: the image as built, the image written again from the checkpoint
# in the session that wrote the variant (the "base"), and the variant.
#
#   image against base   the same part, and the same configuration payload,
#                        every byte of it: the checkpoint is the design of
#                        the image
#   base against variant the same commands; differences only in frame data,
#                        in the shape of whole or half strap tables and the
#                        check bits of their frames, and in the CRC words
#                        that cover those frames
#
# The files are read as what they are. A .bit file is a header of five
# fields (design name, part, date, time, payload length) and the payload.
# The payload is a stream of configuration packets behind a sync word:
# type 1 (register, operation, word count) and type 2 (a long word count for
# the register of the type 1 packet before it); the stream for the other
# dies of a stacked device is the data of a write to the BOUT register and is
# walked in the same way. Frame data is the data of writes to FDRI
# (register 2); a CRC word is the one data word of a write to the CRC
# register (register 0). Nothing here knows frame addresses, so the check
# shows the shape of the difference, not which cells it is in:
#   - the 64 bits of a look-up table are 16 bits in each of four consecutive
#     configuration frames, at the same place in every frame: four parts
#     exactly one frame (93 words, 372 bytes) apart within one FDRI write; a
#     strap is constant 0 or constant 1, so each part is 00 00 against ff ff.
#     A strap that the tool has put into one half of a table whose other
#     half serves another function owns 8 of the 16 bits: each part is then
#     one byte, 00 against ff (seen on a routed design, 2026-11-21);
#   - every frame carries 48 check bits over its own contents: word 45 and
#     the low half of word 46 (bytes 180 to 183, 186 and 187 of the frame;
#     bytes 184 and 185 are ordinary frame data). They may differ in a frame
#     in which a table part differs, and in no other frame; and in every
#     frame in which anything differs they are recomputed here, in both
#     files, and must be what the frame's contents give. The code is that of
#     Project X-Ray (tools/bits2rbt/ecc.cc, UltraScale+); it matched every
#     frame of five bitstreams that Vivado wrote (215,460 frames each,
#     2026-11-21). (Turning all 16 bits of a part leaves the check bits as
#     they were; turning 8 does not.)
#   - as many such tables as the conversion changed strap bits, and no other
#     difference in any frame data;
#   - a differing CRC word only in a stream whose frame data differs, behind
#     it, and at least one there;
#   - no difference anywhere else: not in a packet header, not in any other
#     register's data, not between packets.
# Which cells were changed is in the conversion's log (KARU_STRAP lines), and
# the record ties log, checkpoint and bitstreams together by their hashes.
#
# Usage:
#   strap_diff.py compare BASE.bit VARIANT.bit --straps N
#   strap_diff.py same IMAGE.bit BASE.bit
#   strap_diff.py record --image I.bit --base B.bit --variant V.bit --checkpoint C.dcp
#                        --log L.log --out V.strap.json [--rom-record R.json] [--remove-base]
#       both comparisons, then the record; --remove-base deletes BASE.bit
#       (a second copy of the image, which holds the image's key)
#   strap_diff.py verify --record V.strap.json --image I.bit --variant V.bit
#       the two files are the ones of the record
#   strap_diff.py packets FILE.bit
#       the packets of a file, without their data
# Prints STRAP_DIFF / STRAP_RECORD lines; exit status 1 on any failure.
# No frame data is printed.
# SPDX-License-Identifier: BSD-2-Clause
import argparse, bisect, hashlib, json, os, re, struct, sys, time

FRAME = 372                                     # bytes in a configuration frame, UltraScale+ (93 words)
WORDS = FRAME // 4
ECC_WORD = 45                                   # the check bits: this word, and the low half of the next
ECC = frozenset(range(4 * ECC_WORD, 4 * ECC_WORD + 4)) | {4 * ECC_WORD + 6, 4 * ECC_WORD + 7}
SYNC = 0xAA995566
NOP = 0x20000000
R_CRC, R_FDRI, R_CMD, R_BOUT = 0, 2, 4, 30
CMD_DESYNC = 0xD

class Refuse(Exception):
    pass

def _ecc_offset(word, bit):
    """What one frame bit adds to the check bits (Project X-Ray, tools/bits2rbt/ecc.cc, GetUSEccFrameOffset)."""
    nib, nibbit = bit // 4, bit % 4
    off = (word + (255 - (WORDS - 1))) << 3 | nib
    off ^= 1 << 11                              # odd parity over the twelve bits
    for i in range(11):
        if off & (1 << i):
            off ^= 1 << 11
    exp = 0
    for i in range(12):                         # one bit per nibble
        if off & (1 << i):
            exp |= 1 << (4 * i)
    return exp << nibbit

_ECC_OFF = [[_ecc_offset(w, i) for i in range(32)] for w in range(WORDS)]

def frame_check(d, at):
    """The check bits a frame holds and the ones its contents give."""
    words = struct.unpack(f">{WORDS}I", d[at:at + FRAME])
    ecc = 0
    for w, v in enumerate(words):
        if w == ECC_WORD:
            continue
        if w == ECC_WORD + 1:
            v &= 0xffff0000
        i = 0
        while v:
            if v & 1:
                ecc ^= _ECC_OFF[w][i]
            v >>= 1; i += 1
    return words[ECC_WORD] | (words[ECC_WORD + 1] & 0xffff) << 32, ecc

def read(path):
    with open(path, "rb") as f:
        return f.read()

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()

def bit_file(d, name):
    """The header fields and the payload's offset of a .bit file."""
    if d[:13] != bytes.fromhex("00090ff00ff00ff00ff0000001"):
        raise Refuse(f"{name}: not a .bit file (no preamble)")
    p, fields = 13, {}
    for key in b"abcd":
        if d[p] != key:
            raise Refuse(f"{name}: header field {chr(key)} missing at byte {p}")
        n = struct.unpack(">H", d[p + 1:p + 3])[0]
        fields[chr(key)] = d[p + 3:p + 3 + n].rstrip(b"\0").decode("ascii", "replace")
        p += 3 + n
    if d[p] != ord("e"):
        raise Refuse(f"{name}: header field e missing at byte {p}")
    n = struct.unpack(">I", d[p + 1:p + 5])[0]
    p += 5
    if p + n != len(d):
        raise Refuse(f"{name}: the header gives a payload of {n} bytes at {p}, the file has {len(d) - p}")
    return fields, p

def packets(d, start, end, depth=0, out=None):
    """The packets of a stream: (header offset, register, operation, words, data offset, depth)."""
    out = [] if out is None else out
    p, synced, reg = start, False, None
    while p + 4 <= end:
        w = struct.unpack(">I", d[p:p + 4])[0]
        if not synced:
            if w == SYNC:
                synced = True
                out.append((p, "sync", 0, 0, p + 4, depth))
            p += 4
            continue
        kind = w >> 29
        if w == NOP:
            p += 4
            continue
        if kind == 1:
            op, reg, wc = (w >> 27) & 3, (w >> 13) & 0x3fff, w & 0x7ff
        elif kind == 2 and reg is not None:
            op, wc = (w >> 27) & 3, w & 0x7ffffff
        else:
            raise Refuse(f"byte {p}: {w:08x} is not a packet header")
        data = p + 4
        if op != 2 and wc:
            raise Refuse(f"byte {p}: a packet with data that is not a write")
        if data + 4 * wc > end:
            raise Refuse(f"byte {p}: a packet of {wc} words runs past its stream")
        out.append((p, reg, op, wc, data, depth))
        if reg == R_BOUT and wc:
            packets(d, data, data + 4 * wc, depth + 1, out)
        if reg == R_CMD and op == 2 and wc == 1 and struct.unpack(">I", d[data:data + 4])[0] == CMD_DESYNC:
            synced = False
        p = data + 4 * wc
    return out

def differing(x, y, start):
    """The differing bytes from start on, as runs [first, last]."""
    runs, step = [], 1 << 16
    for off in range(start, len(x), step):
        a, b = x[off:off + step], y[off:off + step]
        if a == b:
            continue
        for i in range(len(a)):
            if a[i] != b[i]:
                p = off + i
                if runs and p - runs[-1][1] == 1:
                    runs[-1][1] = p
                else:
                    runs.append([p, p])
    return runs

def same(image, base):
    """The image and the base written again from the checkpoint: one design."""
    x, y = read(image), read(base)
    try:
        fx, px = bit_file(x, image); fy, py = bit_file(y, base)
        if fx["b"] != fy["b"]:
            raise Refuse(f"the parts differ: {fx['b']} and {fy['b']}")
        if len(x) - px != len(y) - py:
            raise Refuse(f"the payloads differ in length: {len(x) - px} and {len(y) - py} bytes")
        if x[px:] != y[py:]:
            runs = differing(x[px:], y[py:], 0)
            raise Refuse(f"the payloads differ in {sum(e - s + 1 for s, e in runs)} bytes, the first at payload byte {runs[0][0]}: "
                         "the checkpoint is not the design of the image")
        n = len([k for k in packets(x, px, len(x)) if k[1] != "sync"])
    except Refuse as e:
        print(f"STRAP_DIFF FAIL: image against the base written from the checkpoint: {e}")
        return False
    differ = [name for k, name in (("a", "design line"), ("c", "date"), ("d", "time")) if fx[k] != fy[k]]
    print(f"STRAP_DIFF ok: image against the base written from the checkpoint: part {fx['b']}, the payload of "
          f"{len(x) - px} bytes ({n} packets) is the same byte for byte; the file headers differ in "
          f"{', '.join(differ) or 'nothing'}")
    return True

def compare(base, variant, straps):
    """Base against variant: only whole or half strap tables in frame data, the check bits of their frames,
    and the CRC words behind them."""
    x, y = read(base), read(variant)
    tables, checked = [], 0
    try:
        fx, px = bit_file(x, base); fy, py = bit_file(y, variant)
        if fx["b"] != fy["b"] or px != py or len(x) != len(y):
            raise Refuse("the two files are not of one part, header length and payload length")
        pk = packets(x, px, len(x))
        if pk != packets(y, py, len(y)):
            raise Refuse("the two payloads do not have the same packets")
        runs = differing(x, y, px)
        if not runs:
            raise Refuse("the payloads are the same")
        # every difference lies in the data of one packet: of an FDRI write, or the word of a CRC write
        innermost = sorted((k for k in pk if k[1] != "sync" and k[3] and k[1] != R_BOUT), key=lambda k: k[4])
        starts = [k[4] for k in innermost]
        fdri, crc = {}, {}
        for s, e in runs:
            i = bisect.bisect_right(starts, s) - 1
            k = innermost[i] if i >= 0 else None
            if k is None or not (k[4] <= s and e < k[4] + 4 * k[3]):
                raise Refuse(f"a difference at byte {s} that is not in the data of a write: a packet header or padding differs")
            if k[1] == R_FDRI:
                fdri.setdefault(k, []).append((s, e))
            elif k[1] == R_CRC and k[3] == 1:
                crc[k] = True
            else:
                raise Refuse(f"a difference at byte {s} in the data of a write to register {k[1]}, neither frame data nor a CRC")
        if not fdri:
            raise Refuse("no frame data differs")
        for k, parts in fdri.items():
            # byte by byte: where in which frame; the frame's check bits apart from its data
            data, check_frames = {}, set()
            for s, e in parts:
                for q in range(s, e + 1):
                    frame, at = divmod(q - k[4], FRAME)
                    if at in ECC:
                        check_frames.add(frame)
                    elif {x[q], y[q]} != {0x00, 0xff}:
                        raise Refuse(f"frame data differs at byte {q} in something other than whole bytes turned")
                    else:
                        data[(frame, at)] = x[q] == 0
            done, touched = set(), set()
            for (frame, at) in sorted(data):
                if (frame, at) in done:
                    continue
                # a part: one byte, or two side by side, turned the same way; four of them in consecutive frames
                width = 2 if (frame, at + 1) in data and (frame, at + 1) not in done else 1
                cells = [(frame + i, at + j) for i in range(4) for j in range(width)]
                if not all(c in data and c not in done for c in cells) or len({data[c] for c in cells}) != 1:
                    raise Refuse(f"frame data at byte {k[4] + frame * FRAME + at}: not four parts of one table in consecutive frames, turned the same way")
                if (frame, at + width) in data and (frame, at + width) not in done and width == 2:
                    raise Refuse(f"frame data at byte {k[4] + frame * FRAME + at}: more than 16 bits side by side")
                done.update(cells)
                touched.update(frame + i for i in range(4))
                tables.append(dict(fdri_at=k[4], frame=frame, byte_in_frame=at, bits_per_frame=8 * width, depth=k[5],
                                   to_ones=data[cells[0]]))
            if check_frames - touched:
                raise Refuse(f"the check bits of frame {min(check_frames - touched)} differ, and nothing else in that frame does")
            for frame in sorted(touched):
                at = k[4] + frame * FRAME
                if at + FRAME > k[4] + 4 * k[3]:
                    raise Refuse(f"frame data at byte {at}: a part in a frame that the write does not hold whole")
                for d, name in ((x, "base"), (y, "variant")):
                    held, given = frame_check(d, at)
                    if held != given:
                        raise Refuse(f"the check bits of frame {frame} (byte {at}) in the {name} are {held:012x}, its contents give {given:012x}")
                checked += 1
        if len(tables) != straps:
            raise Refuse(f"{len(tables)} tables changed, the conversion changed {straps} strap bits")
        # a CRC word may differ only behind differing frame data of its own stream, and one must
        def stream_of(k):
            """The sync that opens the packet's stream."""
            return max((s for s in pk if s[1] == "sync" and s[5] == k[5] and s[0] < k[0]), key=lambda s: s[0])
        frames_in = {stream_of(k): k for k in fdri}
        for k in crc:
            st = stream_of(k)
            if st not in frames_in or k[0] < frames_in[st][4]:
                raise Refuse(f"the CRC word at byte {k[4]} differs, but no frame data before it in its stream does")
        for st in frames_in:
            if not any(stream_of(k) == st for k in crc):
                raise Refuse("frame data differs in a stream whose CRC words do not")
    except Refuse as e:
        print(f"STRAP_DIFF FAIL: base against variant: {e}")
        return False, []
    halves = sum(t["bits_per_frame"] == 8 for t in tables)
    print(f"STRAP_DIFF ok: base against variant: the same {len([k for k in pk if k[1] != 'sync'])} packets; frame data differs in "
          f"{len(tables)} look-up tables, each four parts in consecutive frames, all their bits turned "
          f"({len(tables) - halves} whole tables, {halves} half tables; {sum(t['to_ones'] for t in tables)} to ones, "
          f"{sum(not t['to_ones'] for t in tables)} to zeros) and in those frames' check bits, which are right for their "
          f"contents in both files ({checked} frames); "
          f"{len(crc)} CRC word{'s' if len(crc) != 1 else ''} behind them; nothing else in the payload")
    return True, tables

def straps_of(log):
    """From the conversion's log: the straps as built and as written, and the number changed."""
    text = open(log, errors="replace").read()
    lines = re.findall(r"^KARU_STRAP lane=(\d+) kshift=(\d+) \(k at least \d+\) rings=0x([0-9a-f]+)$", text, re.M)
    changed = re.findall(r"^KARU_STRAP_CHANGED (\d+)$", text, re.M)
    done = re.findall(r"^KARU_STRAP_VARIANT (\S+) lane=(\d+) kshift=(\d+) rings=0x([0-9a-f]+) from (\S+)$", text, re.M)
    if len(lines) != 2 or len(changed) != 1 or len(done) != 1:
        raise SystemExit(f"STRAP_RECORD FAIL: {log} is not the log of one complete conversion "
                         f"({len(lines)} KARU_STRAP lines, {len(changed)} KARU_STRAP_CHANGED, {len(done)} KARU_STRAP_VARIANT)")
    fmt = lambda t: dict(lane=int(t[0]), kshift=int(t[1]), rings=int(t[2], 16))
    built, written = fmt(lines[0]), fmt(lines[1])
    if fmt(done[0][1:4]) != written:
        raise SystemExit("STRAP_RECORD FAIL: the log's last line does not name the straps it wrote")
    bits = sum(bin(built[k] ^ written[k]).count("1") for k in built)
    if bits != int(changed[0]) or bits == 0:
        raise SystemExit(f"STRAP_RECORD FAIL: the log counts {changed[0]} changed strap bits, its values differ in {bits}")
    if not (written["rings"] >> written["lane"]) & 1:
        raise SystemExit("STRAP_RECORD FAIL: the lane of the variant is not among its running rings")
    return built, written, bits

def main():
    ap = argparse.ArgumentParser(description="Check and record a strap variant of a VCU118 image (see the head of this file).",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="mode", required=True)
    p = sub.add_parser("compare"); p.add_argument("base"); p.add_argument("variant"); p.add_argument("--straps", type=int, required=True)
    p = sub.add_parser("same"); p.add_argument("image"); p.add_argument("base")
    p = sub.add_parser("packets"); p.add_argument("file")
    p = sub.add_parser("record")
    for name in ("image", "base", "variant", "checkpoint", "log", "out"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--rom-record", help="the image's boot ROM record (flow/rom_record.py); named in the variant's record by its hash")
    p.add_argument("--remove-base", action="store_true")
    p = sub.add_parser("verify")
    for name in ("record", "image", "variant"):
        p.add_argument("--" + name, required=True)
    a = ap.parse_args()
    if a.mode == "compare":
        return 0 if compare(a.base, a.variant, a.straps)[0] else 1
    if a.mode == "same":
        return 0 if same(a.image, a.base) else 1
    if a.mode == "packets":
        d = read(a.file)
        try:
            fields, start = bit_file(d, a.file)
            print(f"{a.file}: design '{fields['a'].split(';')[0]}', part {fields['b']}, {fields['c']} {fields['d']}; payload at byte {start}, {len(d) - start} bytes")
            for at, reg, op, wc, data, depth in packets(d, start, len(d)):
                print(f"{'  ' * depth}{at:>9}  " + ("sync" if reg == "sync" else f"register {reg:<2} {'write' if op == 2 else 'read' if op == 1 else 'no-op'} {wc} word{'s' if wc != 1 else ''}"
                      + (f" = {struct.unpack('>I', d[data:data + 4])[0]:08x}" if wc == 1 else "")))
        except Refuse as e:
            print(f"STRAP_DIFF FAIL: {e}")
            return 1
        return 0
    if a.mode == "record":
        built, written, bits = straps_of(a.log)
        if not same(a.image, a.base):
            return 1
        ok, tables = compare(a.base, a.variant, bits)
        if not ok:
            return 1
        rec = dict(format="karu64-strap-variant-2", utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   image=dict(file=os.path.basename(a.image), sha256=sha(a.image)),
                   checkpoint=dict(file=os.path.basename(a.checkpoint), sha256=sha(a.checkpoint)),
                   variant=dict(file=os.path.basename(a.variant), sha256=sha(a.variant)),
                   log=dict(file=os.path.basename(a.log), sha256=sha(a.log)),
                   straps_as_built=built, straps_as_written=written, strap_bits_changed=bits,
                   tables=tables, bytes=os.path.getsize(a.variant),
                   checks=["image and base: the same part and the same payload, byte for byte",
                           "base and variant: the same packets; frame data differs in the changed straps' tables and the check bits of their frames only; CRC words behind them"])
        if a.rom_record:
            rec["rom_record"] = dict(file=os.path.basename(a.rom_record), sha256=sha(a.rom_record))
        tmp = a.out + ".tmp"
        with open(tmp, "w") as f:
            json.dump(rec, f, indent=1); f.write("\n")
        os.replace(tmp, a.out)
        if a.remove_base:
            os.remove(a.base)
        print(f"STRAP_RECORD ok: {a.out}: variant {rec['variant']['sha256'][:16]}… of image {rec['image']['sha256'][:16]}…, "
              f"lane={written['lane']} kshift={written['kshift']} rings={written['rings']:#04x}")
        return 0
    try:
        rec = json.load(open(a.record))
    except (OSError, ValueError) as e:
        print(f"STRAP_RECORD FAIL: no usable record {a.record}: {e}")
        return 1
    bad = [name for name, path in (("image", a.image), ("variant", a.variant)) if sha(path) != rec.get(name, {}).get("sha256")]
    if rec.get("format") != "karu64-strap-variant-2" or bad:
        print(f"STRAP_RECORD FAIL: {a.record} does not describe {' and '.join(bad) or 'a variant'}: "
              "the variant was not made from this image by the recorded conversion")
        return 1
    w = rec["straps_as_written"]
    print(f"STRAP_RECORD ok: {os.path.basename(a.variant)} is the recorded variant of {os.path.basename(a.image)}: "
          f"lane={w['lane']} kshift={w['kshift']} rings={w['rings']:#04x}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
