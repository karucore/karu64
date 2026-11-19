#!/usr/bin/env python3
"""The debug-authentication record of a VCU118 bitstream.

    auth_record.py write  --bit BIT --flags FLAGS --rom ROMHEX [--key KEYFILE] --out RECORD
    auth_record.py verify --record RECORD --bit BIT [--rom ROMHEX] [--key KEYFILE]

`write` runs right after the bitstream is built (dbg/fpga.mk). It records, in
one JSON file, the bitstream's SHA-256, the island ROM's build flags and
algorithm, the SHA-256 of the island ROM image that went into it, and, for
the shared-secret algorithm (0x04), the fingerprint of the key: the first 16
hexadecimal digits of SHA-256 of the 32 key bytes. The key itself is never
written or printed. For 0x04 it also checks that the key is in the ROM.

`verify` runs when the programming bundle is packed (Makefile). It exits 0
and prints "key" when the bundle should carry this key file: the record
belongs to this bitstream, the image authenticates with 0x04, and the key
file and the ROM image are the ones recorded. It prints "no-key" and exits 0
when the image has no shared secret. Anything else is an error, exit 1: a
record for another bitstream, a key or ROM that does not match, no record.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, hashlib, json, re, sys
from pathlib import Path

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def key_bytes(path):
    text = Path(path).read_text().strip()
    if not re.fullmatch(r"[0-9a-fA-F]{64}", text):
        sys.exit(f"auth_record: {path} is not a key of 64 hexadecimal digits (content not shown)")
    return bytes.fromhex(text)

def rom_bytes(hexfile):
    import struct
    words = [int(line, 16) for line in Path(hexfile).read_text().split()]
    return struct.pack(f"<{len(words)}Q", *words)

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=("write", "verify"))
    p.add_argument("--bit", required=True)
    p.add_argument("--flags")
    p.add_argument("--rom")
    p.add_argument("--key")
    p.add_argument("--out")
    p.add_argument("--record")
    a = p.parse_args()
    if a.mode == "write":
        flags = Path(a.flags).read_text().strip()
        sha3 = "-DAUTH_ALG_SHA3" in flags
        rec = dict(format="karu64-auth-record-1", bitstream_sha256=sha(a.bit), rom_flags=flags,
                   algorithm="0x04 SHA3-256 shared secret" if sha3 else "0x80 TEST (simulation-only)",
                   island_rom_sha256=sha(a.rom))
        if sha3:
            key = key_bytes(a.key)
            if rom_bytes(a.rom).count(key) != 1:
                sys.exit(f"auth_record: {a.key} is not the key in {a.rom}")
            rec["key_fingerprint"] = hashlib.sha256(key).hexdigest()[:16]
        Path(a.out).write_text(json.dumps(rec, indent=1) + "\n")
        print(f"auth_record: wrote {a.out} ({rec['algorithm']}"
              + (f", key fingerprint {rec['key_fingerprint']})" if sha3 else ")"))
        return 0
    if not a.record or not Path(a.record).exists():
        sys.exit(f"auth_record: no record {a.record}: this bitstream was not built by the debug image target")
    rec = json.loads(Path(a.record).read_text())
    if rec.get("bitstream_sha256") != sha(a.bit):
        sys.exit(f"auth_record: {a.record} belongs to another bitstream than {a.bit}")
    if "key_fingerprint" not in rec:
        print("no-key")
        return 0
    if not a.key or not Path(a.key).exists():
        sys.exit(f"auth_record: the image authenticates with a shared secret, but there is no key file {a.key}")
    if hashlib.sha256(key_bytes(a.key)).hexdigest()[:16] != rec["key_fingerprint"]:
        sys.exit(f"auth_record: {a.key} is not the key this bitstream was built with")
    if a.rom and Path(a.rom).exists() and sha(a.rom) != rec["island_rom_sha256"]:
        sys.exit(f"auth_record: {a.rom} is not the island ROM this bitstream was built with")
    print("key")
    return 0

if __name__ == "__main__":
    sys.exit(main())
