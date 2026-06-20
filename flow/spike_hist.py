#!/usr/bin/env python3
"""Build a dynamic instruction histogram from a Spike --log-commits log."""

import argparse
import collections
import re
import subprocess
import sys


OBJDUMP_RE = re.compile(r"^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F]+)\s+(.+?)\s*$")
SYMBOL_RE = re.compile(r"^([0-9a-fA-F]+)\s+\w\s+(\S+)$")
SPIKE_RE = re.compile(r"\b0x([0-9a-fA-F]+)\s+\(0x[0-9a-fA-F]+\)")


def load_disasm(objdump, elf):
    proc = subprocess.run(
        [objdump, "-d", "-M", "no-aliases", elf],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    by_pc = {}
    for line in proc.stdout.splitlines():
        m = OBJDUMP_RE.match(line)
        if not m:
            continue
        pc = int(m.group(1), 16)
        asm = m.group(3).strip()
        if not asm or asm.startswith("."):
            continue
        mnemonic = asm.split()[0]
        by_pc[pc] = mnemonic
    return by_pc


def load_symbols(objdump, elf):
    proc = subprocess.run(
        [objdump, "-t", elf],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    symbols = {}
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 6 and re.fullmatch(r"[0-9a-fA-F]+", parts[0]):
            symbols[parts[-1]] = int(parts[0], 16)
            continue
        m = SYMBOL_RE.match(line)
        if m:
            symbols[m.group(2)] = int(m.group(1), 16)
    return symbols


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("log")
    ap.add_argument("--objdump", default="riscv64-unknown-elf-objdump")
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--from-symbol", help="start counting when this symbol is first entered")
    ap.add_argument("--to-symbol", help="stop counting when this symbol is first entered")
    args = ap.parse_args()

    by_pc = load_disasm(args.objdump, args.elf)
    symbols = load_symbols(args.objdump, args.elf)
    start_pc = symbols.get(args.from_symbol) if args.from_symbol else None
    stop_pc = symbols.get(args.to_symbol) if args.to_symbol else None
    if args.from_symbol and start_pc is None:
        print(f"symbol not found: {args.from_symbol}", file=sys.stderr)
        return 1
    if args.to_symbol and stop_pc is None:
        print(f"symbol not found: {args.to_symbol}", file=sys.stderr)
        return 1

    counts = collections.Counter()
    unknown = 0
    total = 0
    active = start_pc is None

    with open(args.log, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = SPIKE_RE.search(line)
            if not m:
                continue
            pc = int(m.group(1), 16)
            if not active:
                if pc == start_pc:
                    active = True
                continue
            if stop_pc is not None and pc == stop_pc:
                break
            total += 1
            mnemonic = by_pc.get(pc)
            if mnemonic is None:
                unknown += 1
                mnemonic = "<unknown>"
            counts[mnemonic] += 1

    if total == 0:
        print(f"no Spike commit lines found in {args.log}", file=sys.stderr)
        return 1

    print(f"dynamic instructions: {total}")
    if unknown:
        print(f"unknown PCs: {unknown}")
    print()
    print(f"{'count':>12} {'pct':>7}  mnemonic")
    for mnemonic, count in counts.most_common(args.top):
        pct = (100.0 * count) / total
        print(f"{count:12d} {pct:6.2f}%  {mnemonic}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
