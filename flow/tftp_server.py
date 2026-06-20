#!/usr/bin/env python3
#	tftp_server.py -- minimal TFTP *read* server for the karu64 TAP netboot
#	demo (Ethernet phase E2c/E2d). Serves files to U-Boot's `tftpboot` from a
#	real host process over tap0, so the sim talks to an actual external server
#	instead of the in-process responder.
#
#	Run as root (port 69 is privileged); free the port first if tftpd-hpa holds
#	it (`sudo systemctl stop tftpd-hpa`):
#	    sudo python3 flow/tftp_server.py <root-dir> [bind-ip]
#	e.g.
#	    sudo python3 flow/tftp_server.py _build/tftp 172.30.0.1
#
#	Built for the Verilator sim, which runs ~1000x slower than real hardware:
#	  - very long per-ACK wait (WAIT_S) + retransmit (RETRIES) so the daemon
#	    never gives up mid-transfer the way a default tftpd's ~1s timer does;
#	  - RFC 2347/2348/2349 options (blksize/tsize/timeout) via OACK, so a
#	    13 MB kernel netboots in ~9k blocks (blksize 1468) instead of ~26k (512);
#	  - verbose: logs every block/ACK so progress is visible live.
#	Read-only; one transfer at a time (fine for U-Boot's lock-step client).
import os
import socket
import struct
import sys

root    = sys.argv[1] if len(sys.argv) > 1 else "."
bind_ip = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
port    = int(os.environ.get("TFTP_PORT", "69"))    # 69 needs root; high port for self-test

WAIT_S   = 120.0        # seconds to wait for each ACK before retransmitting
RETRIES  = 20           # retransmits per packet before aborting the transfer
MAX_BLK  = 1468         # cap blksize so a DATA frame stays within a 1500 MTU

RRQ, DATA, ACK, ERROR, OACK = 1, 3, 4, 5, 6


def parse_rrq(pkt):
    #	filename\0 mode\0 [opt\0 val\0]...   -> (filename, {opt: val})
    parts = pkt[2:].split(b"\0")
    fn = parts[0].decode(errors="replace")
    opts, i = {}, 2
    while i + 1 < len(parts) and parts[i] != b"":
        opts[parts[i].decode(errors="replace").lower()] = parts[i + 1].decode(errors="replace")
        i += 2
    return fn, opts


def recv_ack(sock, want_block):
    #	wait (long) for ACK of want_block; True on match, False on timeout.
    sock.settimeout(WAIT_S)
    try:
        pkt, _ = sock.recvfrom(2048)
    except socket.timeout:
        return None
    if len(pkt) >= 4 and struct.unpack(">H", pkt[:2])[0] == ACK:
        return struct.unpack(">H", pkt[2:4])[0] == want_block
    return False


def send_reliable(sock, cli, pkt, want_block, what):
    #	send pkt, retransmit until want_block is ACKed or we exhaust RETRIES.
    for attempt in range(RETRIES + 1):
        sock.sendto(pkt, cli)
        r = recv_ack(sock, want_block)
        if r is True:
            return True
        if r is None:
            print(f"[tftp]   {what}: no ACK (try {attempt + 1}/{RETRIES + 1}), resend",
                  flush=True)
        # r False (stale/dup ACK) -> just resend too
    print(f"[tftp]   {what}: gave up after {RETRIES + 1} tries", flush=True)
    return False


def handle(srv, data, cli):
    fn, opts = parse_rrq(data)
    path = os.path.join(root, os.path.basename(fn))     # chroot-ish, no escape

    ts = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)   # new transfer TID
    ts.bind(("0.0.0.0", 0))     # wildcard: kernel picks the right source per-route
    try:
        with open(path, "rb") as f:
            content = f.read()
    except OSError:
        ts.sendto(struct.pack(">HH", ERROR, 1) + b"file not found\0", cli)
        ts.close()
        print(f"[tftp] {fn}: NOT FOUND", flush=True)
        return

    blksize = 512
    if opts:
        acc = []
        if "blksize" in opts:
            blksize = max(8, min(MAX_BLK, int(opts["blksize"])))
            acc += [b"blksize", str(blksize).encode()]
        if "tsize" in opts:                              # RRQ tsize is "0"
            acc += [b"tsize", str(len(content)).encode()]
        if "timeout" in opts:
            acc += [b"timeout", opts["timeout"].encode()]
        print(f"[tftp] {fn}: {len(content)} B -> {cli}, opts={opts} -> OACK blksize={blksize}",
              flush=True)
        oack = struct.pack(">H", OACK) + b"\0".join(acc) + b"\0"
        if not send_reliable(ts, cli, oack, 0, "OACK"):  # client ACKs block 0
            ts.close()
            return
    else:
        print(f"[tftp] {fn}: {len(content)} B -> {cli}, no opts (512)", flush=True)

    nblocks = max(1, (len(content) + blksize - 1) // blksize)
    for block in range(1, nblocks + 1):
        chunk = content[(block - 1) * blksize : block * blksize]
        pkt = struct.pack(">HH", DATA, block & 0xFFFF) + chunk
        if not send_reliable(ts, cli, pkt, block & 0xFFFF, f"block {block}/{nblocks}"):
            ts.close()
            return
        if block % 200 == 0 or block == nblocks:
            print(f"[tftp]   sent block {block}/{nblocks}", flush=True)
    # exact-multiple files need a final empty DATA to signal EOF
    if len(content) % blksize == 0 and len(content) > 0:
        block = (nblocks + 1) & 0xFFFF
        send_reliable(ts, cli, struct.pack(">HH", DATA, block), block, "EOF")
    print(f"[tftp] {fn}: done ({nblocks} blocks, blksize {blksize})", flush=True)
    ts.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((bind_ip, port))
    print(f"[tftp] serving {os.path.abspath(root)} on {bind_ip}:{port} "
          f"(wait {WAIT_S}s x {RETRIES} retries, blksize<= {MAX_BLK})", flush=True)
    while True:
        data, cli = srv.recvfrom(2048)
        if len(data) >= 2 and struct.unpack(">H", data[:2])[0] == RRQ:
            handle(srv, data, cli)


if __name__ == "__main__":
    main()
