#!/usr/bin/env python3
"""Offline self-test of the burst capture of raw noise; needs no board.

    make dbg-getnoise-burst-test

A. getnoise_burst.S on the DDR SoC simulation with the entropy source and
   its behavioural noise model (fpga_ddr_tb, KARU_ZKR), so that the payload
   reaches the capture block the way it does on the board: through the
   core's physical access rules and the system-control block of the bus. The
   payload under test is the file that goes to the board; a small driver in
   front of it sets up the source and catches the payload's ebreak, since
   the bench has no debugger, then reads mnoise, mentropycfg and the capture
   block itself. Memory is read back through the bench's +vec_out dump. The
   noise model is deterministic, and noise_model.py is its Python copy: a
   burst must be one stretch of every P-th symbol of the model, bursts must
   follow each other, and their distances must agree with the clock-cycle
   stamps the payload took. This is done for the default model and for the
   characterisation model (+rosc_jitter), which ties the Verilog of both to
   the Python copy.
   Checked besides: the source left as it was found on every path; refusal
   of a locked source, of one already in test mode, of bad parameters and of
   an image without the capture block; a source that gives no symbols; a
   store fault in the middle of a capture; the -DGETBURST_SIM build.
   Negative controls: three mutants of the payload (test mode not left, the
   copy not waiting for the burst, the stamps exchanged) and three tampered
   captures must be caught.

B. getnoise_burst.py as a process against a stand-in for OpenOCD's Tcl RPC.
   The stand-in keeps the memory the phase writes, and on "resume" runs that
   memory image on the bench of part A, so the files the phase writes come
   from the real payload and the simulated entropy source. Checked: the
   files, the sidecar and the exit status of a good capture; an image
   without the capture block; a source that is off; a payload error status;
   a hart that never halts. Negative controls: a result block and a buffer
   altered behind the phase's back.

C. getnoise_analyze.py on the files of part B, taken from the
   characterisation model at several periods: the analysis reads them as
   bursts at their period, and its fit recovers the model's frequency.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, contextlib, hashlib, io, json, os, re, selectors, socket, struct, subprocess, sys, threading, tkinter
from pathlib import Path

SRC = Path(__file__).resolve().parent
ROOT = SRC.parents[2]
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True, help="output directory; getnoise_burst.bin and getnoise_burst.symbols are expected in it")
parser.add_argument("--bench", default=str(ROOT / "_build/ddr-noise-burst/obj/Vfpga_ddr_tb"))
parser.add_argument("--xchain", default="riscv64-unknown-elf-")
args = parser.parse_args()
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(SRC))
import noise_model
import getnoise_analyze as ga
checks = 0

def check(cond, what):
    global checks
    checks += 1
    if not cond:
        raise SystemExit(f"FAIL burst capture self-test check {checks}: {what}")

# ---------------------------------------------------------------- builds ----
CC = [args.xchain + "gcc", "-march=rv64gc_zicsr", "-mabi=lp64d", "-nostdlib", "-static"]

def symbols(text):
    return {p[2]: int(p[0], 16) for line in text.splitlines() if len(p := line.split()) == 3}

def build(name, source, defines=(), text=0, entry="getburst"):
    """Assemble and link one file; returns (binary, symbols)."""
    elf = out / f"{name}.elf"
    subprocess.run(CC + [f"-D{d}" for d in defines] + [f"-Wl,-Ttext={text:#x},--no-relax,-e,{entry}", "-o", str(elf), str(source)],
                   check=True, capture_output=True, text=True)
    subprocess.run([args.xchain + "objcopy", "-O", "binary", "-j", ".text", str(elf), str(out / f"{name}.bin")], check=True)
    nm = subprocess.run([args.xchain + "nm", "-n", str(elf)], check=True, capture_output=True, text=True).stdout
    (out / f"{name}.symbols").write_text(nm)
    return (out / f"{name}.bin").read_bytes(), symbols(nm)

def mutant(name, old, new):
    """A copy of getnoise_burst.S with one place changed."""
    text = (SRC / "getnoise_burst.S").read_text()
    if text.count(old) != 1:
        raise SystemExit(f"FAIL burst capture self-test: mutant {name}: {old!r} is not unique in getnoise_burst.S")
    path = out / f"{name}.S"
    path.write_text(text.replace(old, new))
    return path

# The driver. It may preset mentropycfg and mnoise, then enters the payload.
# The payload has put mtvec back by the time it executes its ebreak, so the
# breakpoint exception arrives here.
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
1:	ld		t0, 16(t2)
	beqz	t0, 2f
	csrw	0x7C8, t0
2:	ld		t0, 0(t2)
	jr		t0
	.balign	4
handler:
	lla		t2, d_entry
	csrr	t0, mcause
	sd		t0, 24(t2)
	csrr	t0, mepc
	sd		t0, 32(t2)
	csrr	t0, 0x7C8
	sd		t0, 40(t2)
	csrr	t0, 0x7C9
	sd		t0, 48(t2)
	li		t1, 0x10000840
	ld		t0, 0(t1)
	sd		t0, 56(t2)
	ld		t0, 8(t1)
	sd		t0, 64(t2)
	ld		t0, 24(t1)
	sd		t0, 72(t2)
	li		t0, 1
	li		t1, 0x80001000
	sd		t0, 0(t1)
3:	j		3b
	.balign	8
	.globl	d_entry
d_entry:	.dword 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
"""
BASE, SIZE = 0x80000000, 0x40000            # the part of the bench RAM that is loaded and dumped
LOAD = BASE + 0x2000                        # payload; the driver and the tohost page are below it
BUF = LOAD + 0x10000                        # where getnoise_burst.py puts the buffer
DIV = 8                                     # the bench's own sampling period (ZKR_SAMPLE_DIV)
# A configuration the bench does not have by itself, and that its limits
# accept: every field stricter than the reset value (calm 25, 2 strikes,
# symbol cutoffs 100 and 12, lane cutoffs 700 and 37), k = 10.
PRE = (25 << 57) | (2 << 54) | (100 << 44) | (12 << 37) | (700 << 26) | (37 << 16) | 9
LOCK = 1 << 63
MAGIC = 0x4b4e4231
FIELDS = ["status", "stored", "words", "polls", "ctrl", "period_used", "cfg", "noise_after", "ctrl_after", "mcause", "mepc"]

(out / "driver.S").write_text(DRIVER)
driver_bin, driver_sym = build("driver", out / "driver.S", text=BASE, entry="driver")
if not (out / "getnoise_burst.symbols").exists():
    raise SystemExit(f"FAIL burst capture self-test: no getnoise_burst.symbols in {out}; run make dbg-getnoise-burst-test")
std_bin, SYM = (out / "getnoise_burst.bin").read_bytes(), symbols((out / "getnoise_burst.symbols").read_text())
sim_bin, sim_sym = build("getnoise_burst_sim", SRC / "getnoise_burst.S", ["GETBURST_SIM"])
check(SYM["getburst"] == 0 and SYM["getburst_result"] == SYM["getburst_params"] + 40, "payload layout: entry first, result block after five parameters")
check(len(std_bin) < 0x1000 and b"\x73\x00\x10\x00" in std_bin, "the board payload is small and ends in an ebreak")
check(b"\x73\x00\x10\x00" not in sim_bin, "the GETBURST_SIM build has no ebreak")
check(len(driver_bin) < 0x1000, "the driver ends below the tohost page")

# ------------------------------------------------------------ simulation ----
bench_runs = 0
def simulate(tag, mem, plusargs=(), max_cycles=4000000):
    """Run a RAM image on the bench. Returns (HTIF exit code or None, final cycle, RAM after)."""
    global bench_runs
    bench_runs += 1
    words = struct.unpack(f"<{SIZE // 8}Q", mem)
    (out / f"{tag}.hex").write_text("".join(f"{w:016x}\n" for w in words))
    dump = out / f"{tag}.dump"
    dump.unlink(missing_ok=True)
    r = subprocess.run([args.bench, f"+hex={out / tag}.hex", "+tohost=1000", f"+max_cycles={max_cycles}", f"+vec_out={dump}",
                        "+vec_out_start=0", f"+vec_out_words={SIZE // 8}", *plusargs], capture_output=True, text=True, timeout=1200)
    (out / f"{tag}.log").write_text(r.stdout + r.stderr)
    done = re.search(r"\[HTIF\] exit (\d+) @ cyc=(\d+)", r.stdout)
    if not done or not dump.exists() or re.search(r"ASSERT|FATAL", r.stdout + r.stderr):
        return None, 0, bytes(mem)
    after = [int(line, 16) for line in dump.read_text().split() if not line.startswith("/")]
    return int(done.group(1)), int(done.group(2)), struct.pack(f"<{len(after)}Q", *after)

def image(payload, params, precfg=PRE, prenoise=0, mem=None, entry=LOAD):
    """RAM image: driver, payload with its parameter block, driver words."""
    mem = bytearray(SIZE) if mem is None else bytearray(mem)
    mem[0:0x2000] = bytes(0x2000)
    mem[0:len(driver_bin)] = driver_bin
    if payload is not None:
        mem[LOAD - BASE:LOAD - BASE + len(payload)] = payload
    if params is not None:
        struct.pack_into("<5Q", mem, LOAD - BASE + SYM["getburst_params"], *params)
    struct.pack_into("<3Q", mem, driver_sym["d_entry"] - BASE, entry, precfg, prenoise)
    return mem

def outcome(mem, sym=SYM, load=LOAD):
    """Result block, driver words and buffer of a finished run."""
    r = dict(zip(FIELDS, struct.unpack_from("<11Q", mem, load - BASE + sym["getburst_result"])))
    d = dict(zip(["d_mcause", "d_mepc", "d_noise", "d_cfg", "d_ctrl", "d_period", "d_data"],
                 struct.unpack_from("<7Q", mem, driver_sym["d_entry"] - BASE + 24)))
    return dict(r, **d, buffer=mem[BUF - BASE:])

def records(buffer, bursts, words):
    """[(start stamp, done stamp, symbols)] of the first `bursts` records of a buffer."""
    size, result = 16 + 8 * words, []
    for i in range(bursts):
        t0, t1, *w = struct.unpack_from(f"<{2 + words}Q", buffer, i * size)
        result.append((t0, t1, bytes((x >> (4 * s)) & 15 for x in w for s in range(16))))
    return result

MODELS = {None: noise_model.NoiseModel(), 10: noise_model.NoiseModel(jitter=10)}

def place(burst, stream, period, after):
    """Clock index of the first place after `after` where the burst is every period-th symbol of the stream."""
    best = None
    for r in range(period):
        i = stream[r::period].find(burst, max(0, -(-(after - r) // period)))
        if i >= 0 and (best is None or r + i * period < best):
            best = r + i * period
    return best

def source_error(recs, period, clocks, jitter=None):
    """None if the bursts are stretches of every period-th symbol of the noise
    model, in order and without overlap, at distances that agree with the
    payload's clock-cycle stamps. Else what is wrong."""
    stream, at, last = MODELS[jitter].upto(clocks + 64), -1, None
    for i, (t0, t1, burst) in enumerate(recs):
        t = place(burst, stream, period, at + 1)
        if t is None:
            return f"burst {i} is not a stretch of the source after burst {i - 1}" if i else "burst 0 is not a stretch of the source"
        if last is not None and abs((t - last[0]) - (t0 - last[1])) > period + 64:
            return f"burst {i}: {t - last[0]} clocks after the one before in the source, {t0 - last[1]} by the payload's stamps"
        last, at = (t, t0), t + (len(burst) - 1) * period
    return None

def problems(o, period, bursts, clocks, pre=PRE, stop=None, jitter=None):
    """Everything that is wrong with a capture that should have succeeded."""
    bad = []
    stop = LOAD + SYM["getburst_stop"] if stop is None else stop
    if (o["d_mcause"], o["d_mepc"]) != (3, stop): bad.append("did not stop at its ebreak")
    if o["status"] != 0: bad.append(f"status {o['status']}")
    if o["stored"] != bursts: bad.append("stored count")
    if o["ctrl"] >> 32 != MAGIC: bad.append("status register at entry")
    words = o["words"]
    if words != 1 << (((o["ctrl"] >> 8) & 0xff) - 4): bad.append("words per burst against the status register")
    if o["period_used"] != period: bad.append("period read back")
    if o["polls"] < bursts: bad.append("fewer polls than bursts")
    if o["cfg"] != pre or o["d_cfg"] != pre: bad.append("mentropycfg changed")
    if o["noise_after"] != 1 or o["d_noise"] != 1: bad.append("test mode not left")
    if o["ctrl_after"] != (MAGIC << 32 | o["ctrl"] & 0xff00 | 0x10) or o["d_ctrl"] != o["ctrl_after"]: bad.append("capture block not at rest afterwards")
    if o["d_period"] != DIV - 1: bad.append("sampling period not back at the build's")
    if o["d_data"] != 0: bad.append("data readable after test mode")
    if not 0 < words <= 4096: return bad + ["no usable burst size"]
    size = 16 + 8 * words
    if any(o["buffer"][bursts * size:bursts * size + 64]): bad.append("wrote past the last record")
    recs = records(o["buffer"], bursts, words)
    symbols = 16 * words
    for i, (t0, t1, _) in enumerate(recs):
        if not (symbols - 1) * period <= t1 - t0 <= (symbols + 1) * period + 4096: bad.append(f"burst {i}: stamps {t1 - t0} clocks apart")
        if i and t0 <= recs[i - 1][1]: bad.append(f"burst {i} starts before the one before it was done")
    err = source_error(recs, period, clocks, jitter)
    if err: bad.append("symbols are not consecutive samples of the source: " + err)
    return bad

def run(tag, payload, params, **kw):
    plusargs = kw.pop("plusargs", ())
    code, clocks, mem = simulate(tag, image(payload, params, **kw), plusargs)
    check(code == 0, f"{tag}: the bench run ends through the driver (see {tag}.log)")
    return outcome(mem), clocks

IDLE = 100000
def params(period, bursts, words=256, idle=IDLE, buf=BUF):
    return [period, bursts, buf, bursts * (16 + 8 * words), idle]

# ---- good captures: the default noise model ----
good = None
for period, bursts in ((1, 6), (2, 4), (3, 4), (8, 3), (16, 3), (256, 1)):
    o, clocks = run(f"sim-p{period}", std_bin, params(period, bursts, idle=4 * IDLE if period == 256 else IDLE))
    found = problems(o, period, bursts, clocks)
    check(found == [], f"period {period}, {bursts} burst(s) of {16 * o['words']} symbols: {found}")
    if period == 2:
        good, good_clocks = o, clocks
WORDS = good["words"]
check(WORDS == 256, "the bench's capture block holds 4096 symbols per burst")

# ---- and the characterisation model, which the analysis is validated on ----
for period, bursts in ((1, 4), (4, 3)):
    o, clocks = run(f"sim-jitter-p{period}", std_bin, params(period, bursts), plusargs=["+rosc_jitter=10"])
    found = problems(o, period, bursts, clocks, jitter=10)
    check(found == [], f"characterisation model, period {period}: {found}")
    check(source_error(records(o["buffer"], bursts, WORDS), period, clocks) is not None,
          "negative control: a capture of the characterisation model is not a stretch of the default model")

# negative controls on the checks themselves: tampered captures
size = 16 + 8 * WORDS
t = bytearray(good["buffer"])
word, = struct.unpack_from("<Q", t, size + 16 + 8 * 100)
struct.pack_into("<Q", t, size + 16 + 8 * 100, word ^ 1 << 20)
check(any("not consecutive" in p for p in problems(dict(good, buffer=bytes(t)), 2, 4, good_clocks)), "a capture with one lane of one symbol flipped is caught")
t = bytearray(good["buffer"])
t[size + 16:2 * size], t[2 * size + 16:3 * size] = t[2 * size + 16:3 * size], t[size + 16:2 * size]
check(any("not consecutive" in p for p in problems(dict(good, buffer=bytes(t)), 2, 4, good_clocks)), "two bursts exchanged are caught")
t = bytearray(good["buffer"])
t[size + 16:2 * size - 8], t[2 * size - 8:2 * size] = t[size + 24:2 * size], bytes(8)
check(any("not consecutive" in p for p in problems(dict(good, buffer=bytes(t)), 2, 4, good_clocks)), "a burst with one word missing is caught")

# ---- refusals: nothing may change ----
def untouched(o, noise=1, cfg=PRE, ctrl=0x10):
    return (o["stored"] == 0 and o["d_cfg"] == cfg and o["d_noise"] == noise and o["d_ctrl"] & 0x3f == ctrl
            and o["d_period"] == (DIV - 1 if o["d_ctrl"] else 0) and not any(o["buffer"][:64]))
o, _ = run("sim-locked", std_bin, params(2, 2), precfg=PRE | LOCK)
check(o["status"] == 2 and untouched(o, cfg=PRE | LOCK, ctrl=0x18), "a locked configuration is refused with status LOCKED, the source untouched")
o, _ = run("sim-busy", std_bin, params(2, 2), prenoise=1 << 31)
check(o["status"] == 3 and o["stored"] == 0 and o["d_noise"] >> 31 == 1 and o["d_ctrl"] & 0x3f == 0x34 and not any(o["buffer"][:64]),
      "a source already in test mode is refused with status BUSY, the other user's test mode still on")
for name, p in (("period 0", params(0, 2)), ("period 257", params(257, 2)), ("no bursts", params(2, 0)),
                ("buffer too small", [2, 2, BUF, 2 * (16 + 8 * 256) - 1, IDLE]), ("idle 0", params(2, 2, idle=0))):
    o, _ = run("sim-param", std_bin, p)
    check(o["status"] == 4 and untouched(o), f"PARAM for {name}, source untouched")
o, _ = run("sim-noblock", std_bin, params(2, 2), plusargs=["+zkr_burst=0"])
check(o["status"] == 8 and o["ctrl"] == 0 and untouched(o, ctrl=0), "an image without the capture block: NOBLOCK, test mode never entered")

# ---- waits are bounded, and the source is put back on the way out ----
o, _ = run("sim-strap-low", std_bin, params(2, 2, idle=3000), plusargs=["+zkr_en=0"])
check(o["status"] == 10 and o["stored"] == 0 and 0 < o["polls"] < 3000, "source off (strap low): the capture block aborts the burst, status ABORTED")
check(o["noise_after"] == 1 and o["d_noise"] == 1 and o["d_ctrl"] & 0x3f == 0 and o["d_period"] == DIV - 1, "ABORTED: test mode left, capture block at rest")
o, _ = run("sim-fault", std_bin, [2, 2, 0x40000000, 2 * (16 + 8 * 256), IDLE])
check(o["status"] == 7 and o["mcause"] == 7 and LOAD + SYM["getburst"] < o["mepc"] < LOAD + SYM["getburst_stop"],
      f"a faulting buffer address ends in status TRAP (mcause {o['mcause']})")
check(o["noise_after"] == 1 and o["d_noise"] == 1 and o["d_ctrl"] & 0x3f == 0x10 and o["d_period"] == DIV - 1
      and (o["d_mcause"], o["d_mepc"]) == (3, LOAD + SYM["getburst_stop"]), "TRAP in the middle of a capture: test mode left, normal stop")

# ---- the GETBURST_SIM build alone at the reset address, reporting through tohost ----
mem = bytearray(SIZE)
mem[:len(sim_bin)] = sim_bin
struct.pack_into("<5Q", mem, sim_sym["getburst_params"], *params(4, 2))
code, clocks, after = simulate("sim-tohost", mem)
o = outcome(after, sim_sym, BASE)
check(code == 0 and o["status"] == 0 and o["stored"] == 2 and o["noise_after"] == 1, "GETBURST_SIM build: status 0 through tohost")
check(source_error(records(o["buffer"], 2, WORDS), 4, clocks) is None, "GETBURST_SIM build: symbols from the source")
struct.pack_into("<5Q", mem, sim_sym["getburst_params"], *params(0, 2))
check(simulate("sim-tohost-param", mem)[0] == 4, "GETBURST_SIM build: an error status is the exit code")

# ---- negative controls: mutants of the payload ----
mut_bin, mut_sym = build("mutant_test", mutant("mutant_test", "\tcsrw\tCSR_MNOISE, zero\n", "\tnop\n"))
o, clocks = run("sim-mutant-test", mut_bin, params(2, 2))
found = problems(o, 2, 2, clocks, stop=LOAD + mut_sym["getburst_stop"])
check("test mode not left" in found and "capture block not at rest afterwards" in found and o["d_noise"] >> 31 == 1,
      f"mutant that stays in test mode is caught: {found}")
mut_bin, mut_sym = build("mutant_wait", mutant("mutant_wait", "\tbnez\tt1, copy\n", "\tj\t\tcopy\n"))
o, clocks = run("sim-mutant-wait", mut_bin, params(2, 2))
found = problems(o, 2, 2, clocks, stop=LOAD + mut_sym["getburst_stop"])
check(o["status"] == 0 and any("not consecutive" in p for p in found), f"mutant that copies before the burst is complete is caught by the comparison with the source: {found}")
mut_bin, mut_sym = build("mutant_stamps", mutant("mutant_stamps", "\tsd\t\tt3, 0(s2)\n\tsd\t\tt0, 8(s2)\n", "\tsd\t\tt0, 0(s2)\n\tsd\t\tt3, 8(s2)\n"))
o, clocks = run("sim-mutant-stamps", mut_bin, params(2, 2))
found = problems(o, 2, 2, clocks, stop=LOAD + mut_sym["getburst_stop"])
check(any("stamps" in p for p in found), f"mutant with the two stamps exchanged is caught: {found}")
checks_sim = checks

# --------------------------------------------------------- capture phase ----
NBURST = 0x10000840
class FakeOpenOCD(threading.Thread):
    """Stand-in for OpenOCD's Tcl RPC with a target behind it.

    The target is this file's memory image: the phase's write_memory and
    read_memory work on it, and resume runs it on the simulation bench with
    the driver in front (in a thread; the hart reads "running" meanwhile).
    A read of the capture block's status register, which the phase makes
    before it loads anything, is answered with `ctrl`. Attributes steer one
    scenario: plusargs for the bench, tamper to alter memory after the run,
    hang for a hart that never halts.
    """
    def __init__(self):
        super().__init__(daemon=True)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(8)
        self.port = self.listener.getsockname()[1]
        self.mem, self.regs, self.state = bytearray(SIZE), {}, "halted"
        self.ctrl = MAGIC << 32 | 12 << 8 | 0x10
        self.precfg, self.plusargs, self.tamper, self.hang, self.sims, self.clocks = PRE, [], None, False, 0, []
    def execute(self, addr):
        self.sims += 1
        code, clocks, mem = simulate(f"target-{self.sims}", image(None, None, self.precfg, mem=self.mem, entry=addr), self.plusargs, 12000000)
        if code != 0:
            return                                              # stays "running"
        self.mem[0x2000:] = mem[0x2000:]
        self.clocks.append(clocks)
        if self.tamper:
            self.tamper(self.mem)
        self.regs["pc"] = struct.unpack_from("<Q", mem, driver_sym["d_entry"] - BASE + 32)[0]
        self.state = "halted"
    def command(self, name, *a):
        if name == "karu.cpu": return self.state
        if name == "halt": self.state = "halted"; return ""
        if name == "riscv": return "0x0" if a[0] == "dmi_read" else ""
        if name == "reg": self.regs[a[0]] = int(a[1], 0); return ""
        if name == "get_reg": return f"{a[-1]} {self.regs.get(a[-1], 0):#x}"
        if name == "read_memory" and int(a[0], 0) == NBURST + 0x20:   # the temperature readout
            return "0x0005999a4888a0f6"
        if name == "read_memory" and int(a[0], 0) == NBURST:
            if (a[1], a[2], a[3]) != ("64", "1", "phys"):
                raise ValueError("the capture block takes 64-bit accesses only")
            return hex(self.ctrl)
        if name in ("write_memory", "read_memory"):
            addr, size = int(a[0], 0) - BASE, int(a[1]) // 8
            count = len(a[2].split()) if name == "write_memory" else int(a[2])
            if not 0x2000 <= addr <= SIZE - size * count or a[3] != "phys":
                raise ValueError(f"{name}: outside the stand-in's memory")
            if name == "read_memory":
                return " ".join(hex(int.from_bytes(self.mem[addr + i * size:addr + (i + 1) * size], "little")) for i in range(count))
            for i, v in enumerate(a[2].split()):
                self.mem[addr + i * size:addr + (i + 1) * size] = int(v, 0).to_bytes(size, "little")
            return ""
        if name == "resume":
            self.state = "running"
            if not self.hang:
                threading.Thread(target=self.execute, args=(int(a[0], 0),), daemon=True).start()
            return ""
        return ""                                               # poll
    def run(self):
        tcl = tkinter.Tcl()
        def py(name, *a):                                       # 0 and a result, or 1 and an error message
            try:
                tcl.globalsetvar("py_result", self.command(name, *a)); return 0
            except Exception as e:
                tcl.globalsetvar("py_result", str(e)); return 1
        tcl.createcommand("py", py)
        for name in ("karu.cpu", "halt", "riscv", "reg", "get_reg", "write_memory", "read_memory", "resume", "poll"):
            tcl.eval("proc %s {args} {if {[py %s {*}$args]} {error $::py_result} ; return $::py_result}" % (name, name))
        selector = selectors.DefaultSelector()
        selector.register(self.listener, selectors.EVENT_READ)
        pending = {}
        while True:
            for key, _ in selector.select():
                sock = key.fileobj
                if sock is self.listener:
                    conn, _ = sock.accept()
                    selector.register(conn, selectors.EVENT_READ)
                    pending[conn] = b""
                    continue
                try:
                    chunk = sock.recv(1 << 20)
                except OSError:
                    chunk = b""
                if not chunk:
                    selector.unregister(sock); sock.close(); del pending[sock]
                    continue
                buf = pending[sock] + chunk
                while b"\x1a" in buf:
                    command, buf = buf.split(b"\x1a", 1)
                    sock.sendall(tcl.eval(command.decode()).encode() + b"\x1a")
                pending[sock] = buf

fake = FakeOpenOCD()
fake.start()

# The phase needs the bare-metal fixture of the selected image map for its
# trap handler and its final PC, and refuses any other. The capture itself is
# in DRAM and the same on every map. boardlib.py says where the fixture is.
MAP = dict(KARU_BOARD_IMAGE="rom2m-auth", KARU_BOARD_SCRATCH="", KARU_BOARD_SCRATCH_SIZE="", KARU_BOARD_RESET_PC="")
fixture = int(subprocess.run([sys.executable, str(SRC / "boardlib.py")], env=dict(os.environ, KARU_BOARD_OUT=str(out), **MAP),
                             check=True, capture_output=True, text=True).stdout, 16)

def phase(tag, payload=std_bin, **env):
    """Run getnoise_burst.py as a process in its own artifact directory."""
    where = out / f"phase-{tag}"
    where.mkdir(exist_ok=True)
    for f in where.glob("getnoise-burst*"):
        f.unlink()
    (where / "payload.symbols").write_text(f"{fixture:016x} T _start\n{fixture + 0x400:016x} T trap_handler\n")
    (where / "payload.bin").write_bytes(bytes(64))
    (where / "getnoise_burst.bin").write_bytes(payload)
    (where / "getnoise_burst.symbols").write_text((out / "getnoise_burst.symbols").read_text())
    settings = dict(os.environ, KARU_BOARD_OUT=str(where), KARU_BOARD_RPC=f"127.0.0.1:{fake.port}", KARU_BOARD_BURST_ADDR=hex(LOAD),
                    KARU_BOARD_BURST_COUNT="3", KARU_BOARD_BURST_PERIODS="1,4", KARU_BOARD_BURST_CLOCK_HZ="1000000",
                    KARU_BOARD_BURST_NOTE="self-test", KARU_BOARD_BURST_WAIT="300", **MAP)
    settings.update({"KARU_BOARD_BURST_" + k.upper(): str(v) for k, v in env.items()})
    fake.mem[:], fake.clocks = bytes(SIZE), []
    r = subprocess.run([sys.executable, str(SRC / "getnoise_burst.py")], env=settings, capture_output=True, text=True, timeout=1800)
    (where / "phase.log").write_text(r.stdout + r.stderr)
    results = json.loads((where / "getnoise-burst-results.json").read_text()) if (where / "getnoise-burst-results.json").exists() else []
    return r.returncode, where, results

def details(results):
    return " | ".join(str(r["detail"]) for r in results if r["status"] != "PASS")

def capture_runs(path):
    """The bursts of a capture file, flags stripped; None if the bytes are not a capture."""
    data = path.read_bytes()
    runs = re.findall(rb"[\x80-\x8f][\x00-\x0f]*", data)
    return [bytes(v & 15 for v in r) for r in runs] if sum(map(len, runs)) == len(data) else None

# a good capture at two periods, from the characterisation model
fake.plusargs = ["+rosc_jitter=10"]
code, where, results = phase("good")
check(code == 0 and [r["status"] for r in results] == ["PASS"] * 3, f"capture phase exits 0 with its three cases passed: {details(results)}")
good_phase = where
for period, clocks in zip((1, 4), fake.clocks):
    name = f"getnoise-burst-p{period}"
    data, side = (where / f"{name}.bin").read_bytes(), json.loads((where / f"{name}.json").read_text())
    runs = capture_runs(where / f"{name}.bin")
    check(runs is not None and [len(r) for r in runs] == [4096] * 3 == side["run_lengths"] and side["stored"] == len(data) == 3 * 4096,
          f"period {period}: three bursts of 4096 symbols, each flagged as a run")
    check(side["sha256"] == hashlib.sha256(data).hexdigest() and side["period"] == period and side["k"] == 1 and side["kind"] == "burst"
          and side["clock_hz"] == 1000000 and side["bursts"] == 3 and side["note"] == "self-test", f"period {period}: capture file and sidecar agree")
    check(int(side["cfg_before"], 16) == PRE and side["noise_after"] == 1 and int(side["ctrl_after"], 16) & 0x2f == 0
          and len(side["burst_cycles"]) == 3 == len(side["burst_done_cycles"]), f"period {period}: sidecar records the source before and after, and the stamps")
    recs = [(t0, t1, r) for t0, t1, r in zip(side["burst_cycles"], side["burst_done_cycles"], runs)]
    check(source_error(recs, period, clocks, jitter=10) is None, f"period {period}: the file holds consecutive samples of the simulated source, at the stamped distances")
    check(side["sysmon_before"] == side["sysmon_after"] == {"raw": hex(0x0005999a4888a0f6), "updates": 5, "temp_c": 40.0, "vccint_v": 0.85, "vccaux_v": 1.8},
          f"period {period}: the sidecar records the temperature readout, raw and decoded: {side['sysmon_before']}")
check(fake.regs["pc"] == fixture and fake.state == "halted", "the phase leaves the hart halted at the fixture's entry, as the other phases do")

# an image without the capture block: refused before anything is loaded
sims, fake.ctrl = fake.sims, 0
code, where, results = phase("no-block")
fake.ctrl = MAGIC << 32 | 12 << 8 | 0x10
check(code == 1 and "no capture block in this image" in details(results) and fake.sims == sims and not list(where.glob("getnoise-burst-p*")),
      f"an image without the capture block fails the phase before the payload is loaded: {details(results)[:90]}")
# the source off
fake.ctrl &= ~0x10
code, where, results = phase("source-off")
fake.ctrl |= 0x10
check(code == 1 and "the noise source is off" in details(results) and fake.sims == sims, "a noise source that is off fails the phase before the payload is loaded")
# the block there, the payload finding none (the stand-in's answer and the bench disagree): the payload's status decides
fake.plusargs = ["+zkr_burst=0"]
code, where, results = phase("payload-no-block", periods="2")
check(code == 1 and "NOBLOCK" in details(results) and not list(where.glob("getnoise-burst-p*")), f"a payload error status fails the phase and leaves no capture: {details(results)[:80]}")
fake.plusargs = ["+zkr_en=0"]
code, where, results = phase("timeout", periods="2")
fake.plusargs = []
check(code == 1 and "ABORTED" in details(results) and not list(where.glob("getnoise-burst-p*")), f"a source that is off: ABORTED fails the phase: {details(results)[:80]}")
# a locked configuration
fake.precfg = PRE | LOCK
code, where, results = phase("locked", periods="2")
fake.precfg = PRE
check(code == 1 and "LOCKED" in details(results), f"a locked configuration fails the phase: {details(results)[:80]}")
# a hart that never halts
fake.hang = True
code, where, results = phase("hang", periods="2", wait=1)
fake.hang = False
check(code == 1 and "still running" in details(results) and fake.state == "halted", "a payload that does not stop is halted and fails the phase")

# negative controls: the target's memory altered after the run
def alter_noise(mem):
    struct.pack_into("<Q", mem, LOAD - BASE + SYM["getburst_result"] + 56, 1 << 31 | 1)
fake.tamper = alter_noise
code, where, results = phase("tamper-noise", periods="2")
check(code == 1 and "test mode left" in details(results), "a source left in test mode fails the phase")
def alter_stamp(mem):
    struct.pack_into("<Q", mem, BUF - BASE + 8, struct.unpack_from("<Q", mem, BUF - BASE)[0] + 100)
fake.tamper = alter_stamp
code, where, results = phase("tamper-stamp", periods="2")
check(code == 1 and "sooner than its symbols take" in details(results), "a burst that cannot have been complete fails the phase")
def alter_period(mem):
    struct.pack_into("<Q", mem, LOAD - BASE + SYM["getburst_result"] + 40, 3)
fake.tamper = alter_period
code, where, results = phase("tamper-period", periods="2")
fake.tamper = None
check(code == 1 and "the period the hardware used" in details(results), "a period other than the requested one fails the phase")
checks_phase = checks - checks_sim

# -------------------------------------------------------------- analysis ----
def analysis(tag, files, *options):
    where = out / f"analysis-{tag}"
    for f in where.glob("getnoise-analysis.*"):
        f.unlink()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        code = ga.main([*files, "--out", str(where), *options])
    done = (where / "getnoise-analysis.json").exists()
    return code, json.loads((where / "getnoise-analysis.json").read_text()) if done else None, \
        (where / "getnoise-analysis.txt").read_text() if done else ""

def fold(f):
    f %= 1.0
    return min(f, 1 - f)

code, res, text = analysis("phase", [str(good_phase / "getnoise-burst-p1.bin"), str(good_phase / "getnoise-burst-p4.bin")])
check(code == 0 and res is not None and [(c["period"], c["clocks"], c["symbols"], c["runs"]) for c in res["captures"]] == [(1, 1, 12288, 3), (4, 4, 12288, 3)],
      "the analysis reads the phase's files as bursts at their period")
for cap in res["captures"]:
    truth = noise_model.parameters(10, period=cap["period"])
    for l, (F, D, s2) in zip(cap["lanes"], truth):
        f = l["fit"]
        check(abs(l["ones_fraction"] - D) < 0.03, f"period {cap['period']} lane {l['lane']}: ones fraction near the model's duty cycle")
        check(f["identifiable"] and abs(f["F"] - fold(F)) < 0.01,
              f"period {cap['period']} lane {l['lane']}: fitted F {f['F']} against the model's {fold(F):.4f}")

print(f"burst capture self-test: PASS ({checks} checks: {checks_sim} simulation, {checks_phase} capture phase, "
      f"{checks - checks_sim - checks_phase} analysis; {bench_runs} bench runs)")
sys.exit(0)
