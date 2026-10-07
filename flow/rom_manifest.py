#!/usr/bin/env python3
"""Describe what a VCU118 boot ROM image contains.

The ROM bitstreams bake OpenSBI, U-Boot (with its boot command) and the
control DTB into a 1 MiB image. When the bitstream is built on one host and
the board is served by another, the second host has to provide exactly what
that image expects. This tool reads the packed ROM image back, so everything
it reports is what the bitstream really contains, not what the source files
say now:

  * a manifest with the SHA-256 of the ROM and of each blob, the U-Boot
    version and boot delay, the verbatim boot command, and the TFTP/NFS
    endpoints that command names;
  * the control DTB extracted from the ROM, byte for byte, so the board host
    can serve the identical file as board.dtb.

Usage:
    flow/rom_manifest.py --rom-hex _build/vcu118_fuboot.hex \\
        --blobs flow/boot/fuboot_blobs.h \\
        --manifest _build/vcu118_rom_manifest.txt --dtb _build/vcu118_rom_board.dtb \\
        [--bit _build/vcu118_ddr.bit] [--repo NAME=DIR ...]

The ROM hex is the output of flow/build_fuboot_rom.sh: one 64-bit
little-endian word per line. Exit status is nonzero if the image is not
self-consistent (wrong size, DTB without FDT magic, sizes that disagree with
the blob header, or no boot command in U-Boot).
"""
import argparse
import hashlib
import re
import struct
import subprocess
import sys
from pathlib import Path

ROM_BYTES = 0x100000
FDT_MAGIC = 0xD00DFEED


def die(msg):
    sys.exit('rom_manifest: ' + msg)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_rom(path):
    words = [line.strip() for line in Path(path).read_text().split('\n') if line.strip()]
    rom = b''.join(struct.pack('<Q', int(w, 16)) for w in words)
    if len(rom) != ROM_BYTES:
        die(f'{path}: {len(rom)} bytes, expected {ROM_BYTES}')
    return rom


def read_blobs(path):
    vals = {}
    for m in re.finditer(r'#define\s+FUBOOT_(\w+)\s+(0x[0-9a-fA-F]+|\d+)UL', Path(path).read_text()):
        vals[m.group(1)] = int(m.group(2), 0)
    need = ['OPENSBI_OFF', 'OPENSBI_SIZE', 'UBOOT_OFF', 'UBOOT_SIZE', 'DTB_OFF', 'DTB_SIZE']
    missing = [k for k in need if k not in vals]
    if missing:
        die(f'{path}: missing {", ".join(missing)}')
    return vals


def repo_line(name, path):
    def git(*args):
        return subprocess.run(['git', '-C', path, *args], capture_output=True, text=True).stdout
    head = git('rev-parse', 'HEAD').strip() or 'unknown'
    branch = git('branch', '--show-current').strip() or 'detached'
    dirty = [line[3:] for line in git('status', '--porcelain', '--untracked-files=no').splitlines()]
    note = ''
    if dirty:
        more = f' and {len(dirty) - 4} more' if len(dirty) > 4 else ''
        note = f'; uncommitted changes in {", ".join(dirty[:4])}{more}'
    return f'{name + ":":11s} {head} ({branch}{note})'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rom-hex', required=True)
    ap.add_argument('--blobs', required=True, help='generated flow/boot/fuboot_blobs.h of the same ROM build')
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--dtb', required=True, help='where to write the DTB extracted from the ROM')
    ap.add_argument('--bit', help='bitstream that contains this ROM')
    ap.add_argument('--repo', action='append', default=[], metavar='NAME=DIR')
    args = ap.parse_args()

    rom = read_rom(args.rom_hex)
    b = read_blobs(args.blobs)

    def blob(key, limit):
        off, size = b[key + '_OFF'], b[key + '_SIZE']
        if off + size > limit:
            die(f'{key} overruns its region')
        if any(rom[off + size:limit]):
            die(f'{key}: nonzero bytes after the recorded size; {args.blobs} is from a different ROM build')
        return off, rom[off:off + size]

    osbi_off, osbi = blob('OPENSBI', b['UBOOT_OFF'])
    ub_off, uboot = blob('UBOOT', b['DTB_OFF'])
    dtb_off, dtb = blob('DTB', ROM_BYTES)

    magic, totalsize = struct.unpack('>II', dtb[:8])
    if magic != FDT_MAGIC:
        die(f'no FDT magic at ROM offset 0x{dtb_off:x}')
    if totalsize != len(dtb):
        die(f'DTB header says {totalsize} bytes but the blob header says {len(dtb)}')

    start = uboot.find(b'setenv serverip')
    if start < 0:
        die('no baked boot command (setenv serverip ...) in the ROM U-Boot')
    bootcmd = uboot[start:uboot.index(b'\0', start)].decode('ascii')
    ver = re.search(rb'U-Boot (20\d\d\.\d\d[^\0 ]*)', uboot)
    delay = re.search(rb'bootdelay=(-?\d+)', uboot)

    def field(pattern):
        m = re.search(pattern, bootcmd)
        return m.group(1) if m else '?'
    serverip = field(r'setenv serverip (\S+?);')
    ipaddr = field(r'setenv ipaddr (\S+?);')
    nfsroot = field(r'nfsroot=(\S+?)[;\s]')
    ipcfg = field(r'\bip=(\S+)')
    console = field(r'console=(\S+)')
    files = sorted(set(re.findall(r'tftpboot (0x[0-9a-fA-F]+) (\S+?)[\s\']', bootcmd)))

    out = []
    out.append('karu64 VCU118 boot ROM manifest')
    out.append('Everything below is read back from the packed ROM image, not from the source files.')
    out.append('')
    for spec in args.repo:
        name, _, path = spec.partition('=')
        out.append(repo_line(name, path))
    if args.repo:
        out.append('(repository state when this manifest was written)')
        out.append('')
    if args.bit:
        bit = Path(args.bit).read_bytes()
        out.append(f'bitstream  {args.bit}  {len(bit)} bytes  sha256 {sha(bit)}')
    out.append(f'ROM image  {args.rom_hex}  {len(rom)} bytes  sha256 {sha(rom)}')
    out.append(f'  0x{osbi_off:05x}  OpenSBI fw_jump   {len(osbi):7d} bytes  sha256 {sha(osbi)}')
    out.append(f'  0x{ub_off:05x}  U-Boot {ver.group(1).decode() if ver else "?":10s} {len(uboot):7d} bytes  sha256 {sha(uboot)}'
               f'  (bootdelay {delay.group(1).decode() if delay else "?"})')
    out.append(f'  0x{dtb_off:05x}  control DTB       {len(dtb):7d} bytes  sha256 {sha(dtb)}')
    out.append('')
    out.append('Boot command baked into the ROM U-Boot (CONFIG_BOOTCOMMAND):')
    out.append(bootcmd)
    out.append('')
    out.append('The host that serves the board must therefore provide:')
    out.append(f'  TFTP server {serverip}; board address {ipaddr}')
    for addr, name in files:
        out.append(f"  TFTP file '{name}' at the TFTP root (loaded at {addr})")
    out.append(f'  kernel network setup ip={ipcfg}')
    out.append(f'  NFS root {nfsroot}')
    out.append(f'  serial console {console}')
    out.append(f"  a served board.dtb with sha256 {sha(dtb)}")
    out.append(f'    This file is {args.dtb}, the DTB extracted from the ROM. Serve this')
    out.append('    exact file. A DTB recompiled from the DTS on another host is only')
    out.append('    equivalent if its sha256 is the same.')
    text = '\n'.join(out) + '\n'

    Path(args.dtb).write_bytes(dtb)
    Path(args.manifest).write_text(text)
    sys.stdout.write(text)


if __name__ == '__main__':
    main()
