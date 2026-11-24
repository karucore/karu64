#!/usr/bin/env python3
# Tie a bitstream to the boot memory image it was built with, by hash.
#
# The boot ROM of a VCU118 image is read from a hex file when the design is
# synthesised (vcu118_fuboot.hex). The programming bundle later takes a
# manifest and the control DTB from that file, and a strap variant
# (flow/fpga/strap_variant.tcl) has the ROM of the image it comes from. A
# time stamp cannot tell whether the file is still the one in the
# bitstream: a ROM packed again after the image and before a variant is
# older than the variant. This record can.
#
#   rom_record.py before --rom HEX --out FILE
#       before the build: the hash of the ROM image, kept for the next step
#   rom_record.py write --bit BIT --rom HEX --before FILE --out RECORD
#       after the build: the ROM image must still be the one hashed before
#       it (nothing packed it again while the build ran), and the bitstream
#       must be newer than that hash; the record names both by SHA-256
#   rom_record.py fresh --bit BIT --rom HEX --before FILE
#       the same two checks as write, and no record: for the island ROM of
#       the debug image, whose own record is flow/auth_record.py's
#   rom_record.py verify --record RECORD --bit BIT --rom HEX
#       the bitstream and the ROM image are the two of the record
# Prints one ROM_RECORD line (before prints nothing); exit status 1 on a mismatch.
# SPDX-License-Identifier: BSD-2-Clause
import argparse, hashlib, json, os, sys, time

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()

def main():
    ap = argparse.ArgumentParser(description="Tie a bitstream to the boot memory image it was built with, by hash "
                                             "(see the head of this file).", formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("before", "write", "fresh", "verify"))
    ap.add_argument("--rom", required=True)
    ap.add_argument("--bit")
    ap.add_argument("--before")
    ap.add_argument("--out")
    ap.add_argument("--record")
    a = ap.parse_args()
    if a.mode == "before":
        with open(a.out, "w") as f:
            json.dump(dict(rom=os.path.basename(a.rom), sha256=sha(a.rom), utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())), f)
            f.write("\n")
        return 0
    if a.mode in ("write", "fresh"):
        before = json.load(open(a.before))
        now = sha(a.rom)
        if now != before["sha256"]:
            print(f"ROM_RECORD FAIL: {a.rom} changed while the image was built: {before['sha256'][:16]}… before, {now[:16]}… after; "
                  "which of them the bitstream holds is not known")
            return 1
        # strictly newer, to the nanosecond: a bitstream with the hash's own time stamp was not written after it
        if os.stat(a.bit).st_mtime_ns <= os.stat(a.before).st_mtime_ns:
            print(f"ROM_RECORD FAIL: {a.bit} is not newer than this build's start: the build did not write it")
            return 1
        if a.mode == "fresh":
            print(f"ROM_RECORD ok: {os.path.basename(a.bit)} was written after {os.path.basename(a.rom)} was hashed, and the ROM "
                  "is unchanged since")
            return 0
        rec = dict(format="karu64-rom-record-1", utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   bitstream=dict(file=os.path.basename(a.bit), sha256=sha(a.bit)),
                   rom=dict(file=os.path.basename(a.rom), sha256=now, hashed_before_the_build=before["utc"]))
        tmp = a.out + ".tmp"
        with open(tmp, "w") as f:
            json.dump(rec, f, indent=1); f.write("\n")
        os.replace(tmp, a.out)
        print(f"ROM_RECORD ok: {a.out}: bitstream {rec['bitstream']['sha256'][:16]}… was built with ROM image {now[:16]}…")
        return 0
    rec = json.load(open(a.record))
    bad = []
    if rec.get("format") != "karu64-rom-record-1":
        bad.append("the record's format")
    else:
        if sha(a.bit) != rec["bitstream"]["sha256"]:
            bad.append(f"{a.bit} is not the bitstream of the record")
        if sha(a.rom) != rec["rom"]["sha256"]:
            bad.append(f"{a.rom} is not the ROM image the bitstream was built with (it was packed again since)")
    if bad:
        print("ROM_RECORD FAIL: " + "; ".join(bad))
        return 1
    print(f"ROM_RECORD ok: {os.path.basename(a.rom)} is the ROM image of {os.path.basename(a.bit)} ({rec['rom']['sha256'][:16]}…)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
