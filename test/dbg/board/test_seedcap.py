#!/usr/bin/env python3
# Offline self-test of seedcap.S on the Zkr simulation bench (make
# dbg-seedcap-test). The bench starts the hart at a small driver, which
# optionally writes mentropycfg and then enters the payload, as
# seed_restart.py does on the board after a reset. Checks:
#   - from reset, the payload polls through the start-up test and stores
#     consecutive kept samples of the bench's noise model, starting with the
#     first sample after the start-up test, nibble [15:12] first;
#   - it never leaves the source's buffer unread for as long as one word;
#   - a payload that starts after the first ES16 reports LATE;
#   - a source that fails its start-up test is reported DEAD;
#   - a running failure during the capture is reported ALARM, with the words
#     stored before it valid and the alarm in mentropystat.
# SPDX-License-Identifier: BSD-2-Clause
import argparse, re, struct, subprocess, sys
from pathlib import Path

SRC = Path(__file__).resolve().parent
ROOT = SRC.parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
parser.add_argument("--bench", default=str(ROOT / "_build/zkr/Vhtif_h/Vhtif_tb"))
parser.add_argument("--xchain", default="riscv64-unknown-elf-")
args = parser.parse_args()
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = 0

def check(cond, what):
    global checks
    checks += 1
    if not cond:
        raise SystemExit(f"FAIL seedcap self-test check {checks}: {what}")
    print(f"ok   {what}", flush=True)

CC = [args.xchain + "gcc", "-march=rv64gc_zicsr", "-mabi=lp64d", "-nostdlib", "-static"]

def build(name, source, defines=(), text=0, entry="seedcap"):
    elf = out / f"{name}.elf"
    subprocess.run(CC + [f"-D{d}" for d in defines] + [f"-Wl,-Ttext={text:#x},--no-relax,-e,{entry}", "-o", str(elf), str(source)],
                   check=True, capture_output=True, text=True)
    subprocess.run([args.xchain + "objcopy", "-O", "binary", "-j", ".text", str(elf), str(out / f"{name}.bin")], check=True)
    nm = subprocess.run([args.xchain + "nm", "-n", str(elf)], check=True, capture_output=True, text=True).stdout
    (out / f"{name}.symbols").write_text(nm)
    return (out / f"{name}.bin").read_bytes(), {p[2]: int(p[0], 16) for line in nm.splitlines() if len(p := line.split()) == 3}

# The driver of test_getnoise.py: optionally writes mentropycfg, enters the
# payload; its handler takes the payload's ebreak and ends the run.
DRIVER = r"""
	.option	norvc
	.section .text
	.globl	driver
driver:
	lla		t0, handler
	csrw	mtvec, t0
	lla		t2, d_entry
	ld		t0, 8(t2)
	beqz	t0, 1f
	csrw	0x7C9, t0
1:	ld		t0, 0(t2)
	jr		t0
	.balign	4
handler:
	lla		t2, d_entry
	csrr	t0, mcause
	sd		t0, 24(t2)
	csrr	t0, mepc
	sd		t0, 32(t2)
	li		t0, 1
	li		t1, 0x80001000
	sd		t0, 0(t1)
3:	j		3b
	.balign	8
	.globl	d_entry
d_entry:	.dword 0, 0, 0, 0, 0
"""
BASE, SIZE = 0x80000000, 0x20000
LOAD = BASE + 0x2000
BUF = LOAD + 0x10000
RAW_PERIOD = 8                              # the bench's clocks per raw symbol
FIELDS = ["status", "stored", "bist", "wait", "cyc_entry", "cyc_first", "cyc_end", "max_gap", "stat_end", "cfg_end", "mcause", "mepc"]
(out / "driver.S").write_text(DRIVER)
driver_bin, driver_sym = build("driver", out / "driver.S", text=BASE, entry="driver")
std_bin, SYM = build("seedcap", SRC / "seedcap.S")
late_bin, late_sym = build("seedcap_late", SRC / "seedcap.S", ["SEEDCAP_SPIN=100000"])
check(SYM["seedcap"] == 0 and SYM["seedcap_result"] == SYM["seedcap_params"] + 24, "payload layout: entry first, result block after three parameters")
check(len(std_bin) < 0x1000 and b"\x73\x00\x10\x00" in std_bin, "the payload is small and ends in an ebreak")

def simulate(tag, payload, sym, params, precfg=0, max_cycles=3000000):
    mem = bytearray(SIZE)
    mem[0:len(driver_bin)] = driver_bin
    mem[LOAD - BASE:LOAD - BASE + len(payload)] = payload
    struct.pack_into("<3Q", mem, LOAD - BASE + sym["seedcap_params"], *params)
    struct.pack_into("<2Q", mem, driver_sym["d_entry"] - BASE, LOAD, precfg)
    words = struct.unpack(f"<{SIZE // 8}Q", mem)
    (out / f"{tag}.hex").write_text("".join(f"{w:016x}\n" for w in words))
    dump = out / f"{tag}.dump"
    dump.unlink(missing_ok=True)
    r = subprocess.run([args.bench, f"+hex={out / tag}.hex", "+tohost=1000", f"+max_cycles={max_cycles}", f"+vec_out={dump}",
                        "+vec_out_start=0", f"+vec_out_words={SIZE // 8}"], capture_output=True, text=True, timeout=900)
    (out / f"{tag}.log").write_text(r.stdout + r.stderr)
    done = re.search(r"\[HTIF\] exit (\d+) @ cyc=(\d+)", r.stdout)
    check(done is not None and dump.exists(), f"{tag}: the bench run ends through the driver")
    after = struct.pack(f"<{SIZE // 8}Q", *[int(l, 16) for l in dump.read_text().split() if not l.startswith("/")])
    o = dict(zip(FIELDS, struct.unpack_from(f"<{len(FIELDS)}Q", after, LOAD - BASE + sym["seedcap_result"])))
    o["d_mcause"], o["d_mepc"] = struct.unpack_from("<2Q", after, driver_sym["d_entry"] - BASE + 24)
    o["words"] = struct.unpack_from(f"<{o['stored']}H", after, BUF - BASE) if o["stored"] < 0x8000 else ()
    o["clocks"] = int(done.group(2))
    return o

class NoiseModel:
    """The behavioural noise source of flow/fpga/karu_rosc_rng.v (SIM = 1),
    clock by clock; a copy of the one in test_getnoise.py."""
    def __init__(self):
        self.prng = 0x9e3779b97f4a7c15
        self.phase = [(0x13579bdf * (m + 1)) & 0xffffffff for m in range(4)]
        self.osc = bytearray()
    def upto(self, clocks):
        M, prng, ph, osc = (1 << 64) - 1, self.prng, self.phase, self.osc
        while len(osc) < clocks:
            osc.append(sum(((ph[m] >> 31) ^ 1) << m for m in range(4)))
            s = ((prng & 0xffff) + ((prng >> 16) & 0xffff) + ((prng >> 32) & 0xffff) + (prng >> 48) - 131070) << 14
            for m in range(4):
                ph[m] = (ph[m] + 0x0a3d70a3 * (2 * m + 3) + s * (m + 1) + (((prng >> (8 * m)) & 0xff) << 24)) & 0xffffffff
            prng ^= (prng << 13) & M; prng ^= prng >> 7; prng ^= (prng << 17) & M
        self.prng = prng
        return bytes(osc[:clocks])
model = NoiseModel()

def samples(words):
    return bytes(n for w in words for n in ((w >> 12) & 15, (w >> 8) & 15, (w >> 4) & 15, w & 15))

def place(seq, k, clocks):
    """(phase, index) of every place where seq is a stretch of every k-th raw symbol."""
    stream, period = model.upto(clocks + 64), RAW_PERIOD * k
    return [(r, p) for r in range(period) if (p := stream[r::period].find(seq)) >= 0]

STOP = LOAD + SYM["seedcap_stop"]
COUNT = 250
IDLE = 1 << 22
# The bench resets with k = 2 (a word every 64 clocks). The driver sets the
# board's k = 16 (512 clocks per word here), which restarts the start-up
# test a few clocks after reset; the limits accept a longer spacing.
BENCH_RESET_CFG = 0x30c7c1eb3c370001
K16 = (BENCH_RESET_CFG & ~0xffff) | 15

# 1. From reset, the board's spacing.
o = simulate("sim-reset", std_bin, SYM, [COUNT, BUF, IDLE], precfg=K16)
k = (o["cfg_end"] & 0xffff) + 1
check(o["cfg_end"] == K16 and k == 16, f"the bench runs at k = 16 ({o['cfg_end']:#x})")
print({f: (hex(v) if f in ("stat_end", "cfg_end") else v) for f, v in o.items() if f != "words"}, f"k={k}")
check((o["d_mcause"], o["d_mepc"]) == (3, STOP), "the payload stops at its ebreak")
check(o["status"] == 0 and o["stored"] == COUNT, f"status OK and {COUNT} words stored")
check(o["bist"] > 0 and o["cyc_first"] > o["cyc_entry"], "it polled BIST before the first ES16: no word came before it")
check(o["max_gap"] < 4 * RAW_PERIOD * k, f"longest time between polls ({o['max_gap']} clocks) is under one word ({4 * RAW_PERIOD * k})")
check(o["stat_end"] & 0xffff_0000_0000 == 0 and o["stat_end"] & 3 == 1, "mentropystat at the end: running, no failure")
seq = samples(o["words"])
where = place(seq, k, o["clocks"])
check(len(where) == 1, f"the {len(seq)} samples are one consecutive stretch of the source, nibble [15:12] first ({where})")
check(1024 <= where[0][1] <= 1026, f"and the stretch starts with the first sample after the 1,024 of the start-up test (index {where[0][1]})")
rev = bytes(n for w in o["words"] for n in (w & 15, (w >> 4) & 15, (w >> 8) & 15, (w >> 12) & 15))
check(place(rev, k, o["clocks"]) == [], "control: the other nibble order is not a stretch of the source")

# 2. A payload that starts after the first ES16.
o = simulate("sim-late", late_bin, late_sym, [COUNT, BUF, IDLE], precfg=K16)
print({f: (hex(v) if f in ("stat_end", "cfg_end") else v) for f, v in o.items() if f != "words"})
check(o["status"] == 2 and o["bist"] == 0, "a payload that starts after the first ES16 reports LATE, with no BIST poll")
check(place(samples(o["words"]), k, o["clocks"]) == [], "control: its words are not one consecutive stretch (the full buffer dropped samples)")

# 3. A start-up failure: a symbol repetition cutoff of zero fails on the first symbol.
RESET_CFG = K16
dead_cfg = RESET_CFG & ~(0x7f << 37)
o = simulate("sim-dead", std_bin, SYM, [COUNT, BUF, IDLE], precfg=dead_cfg)
check(o["status"] == 3 and o["stored"] == 0, "a source that fails its start-up test is reported DEAD, nothing stored")
check(o["stat_end"] & 3 == 2 and (o["stat_end"] >> 8) & 15 == 1 and not o["stat_end"] & 4,
      f"mentropystat: dead, cause symbol repetition, no alarm ({o['stat_end']:#x})")

# 4. A running failure during the capture: a stricter symbol repetition cutoff.
for srct in (4, 5, 6):
    o = simulate(f"sim-alarm-{srct}", std_bin, SYM, [4000, BUF, IDLE], precfg=(RESET_CFG & ~(0x7f << 37)) | (srct << 37), max_cycles=12000000)
    if o["status"] == 4:
        break
print({f: (hex(v) if f in ("stat_end", "cfg_end") else v) for f, v in o.items() if f != "words"}, f"srct={srct}")
check(o["status"] == 4 and o["stored"] > 0, f"a running failure ends the capture as ALARM (srct {srct}, after {o['stored']} words)")
check(not o["stat_end"] & 4 and (o["stat_end"] >> 8) & 15 == 1 and (o["stat_end"] >> 4) & 7 == 1 and o["stat_end"] >> 32 == 1,
      f"mentropystat: one failure, cause symbol repetition, one strike; the alarm already seen by the poll that returned BIST ({o['stat_end']:#x})")
where = place(samples(o["words"]), k, o["clocks"])
check(len(where) == 1 and 1024 <= where[0][1] <= 1026, "the words stored before the failure are consecutive samples from the first on")

print(f"seedcap self-test: PASS ({checks} checks)")
