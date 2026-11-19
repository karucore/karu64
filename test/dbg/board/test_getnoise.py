#!/usr/bin/env python3
"""Offline self-test of the GetNoise capture and analysis; needs no board.

    make dbg-getnoise-test

A. getnoise.S on the Zkr simulation bench (the HTIF bench of the core with
   the entropy source and its behavioural noise model). The payload under
   test is the file that goes to the board; a small driver in front of it
   sets up the source, and catches the payload's ebreak, since the bench has
   no debugger. The driver then reads mnoise and mentropycfg itself. Memory
   is read back through the bench's +vec_out dump. The noise model is
   deterministic, so a Python copy of it says which symbols the source
   produced: a captured run must be one stretch of every k-th model symbol.
   Checked: a capture of the requested length in one run; the cutoffs kept
   and the configuration and test mode restored; refusal of a locked source
   and of one already in test mode; a slow consumer (-DGETNOISE_SLOW) that
   loses symbols and ends up with several runs, each of them a stretch of
   the source with symbols missing in between; a source with no symbols and
   one that is faster than the loop; a store fault in the middle of a
   capture; the -DGETNOISE_SIM build that reports through tohost.
   Negative controls: three mutants of the payload (loss flag ignored, no
   restore, test mode not left) and two tampered captures must be caught.

B. getnoise_analyze.py on data generated from the model with known
   (F, D, sigma^2): the fit, sigma^2 growing with k, the lower bound when no
   autocorrelation is left, statistics confined to runs, independent lanes
   not flagged, a copied lane and a noisy copy flagged while their own
   ones fraction and per-bit figure look no worse, a parity lane that only the
   four-lane statistic sees, two strongly periodic independent lanes that a
   plain chi-square would flag, thresholds and exit status, rejected files.
   Negative controls: a wrong decimation label and a broken model constant.
   The per-bit estimate: never above the bias cap, the predictor cap or the
   true value of the generated lanes, its sigma^2 range holding the true
   value. Verdicts: eight million symbols with p1 = 0.75 on every lane fail
   a claim of 0.75 bits (the D = 1/2 bound, used alone before, would have
   passed it); a fair source that fits passes a threshold it meets; a Markov
   chain and a periodic pattern are refused as not being the model; a word
   threshold that the word distribution alone would pass fails on the
   predictor cap; a capture too small to show a dependence fails the
   independence verdict.

C. getnoise_capture.py as a process against a stand-in for OpenOCD's Tcl
   RPC. The stand-in keeps the memory the phase writes, and on "resume" runs
   that memory image on the bench of part A, so the files the phase writes
   come from the real payload and the simulated entropy source. Checked: the
   files and the exit status of a good capture; a payload error status; a
   locked source; short runs against the minimum; a hart that never halts.
   Negative controls: a result block and a buffer altered behind the
   phase's back.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse, contextlib, hashlib, io, json, math, os, random, re, selectors, socket, struct, subprocess, sys, threading, tkinter
from pathlib import Path

SRC = Path(__file__).resolve().parent
ROOT = SRC.parents[2]
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--out", required=True, help="output directory; getnoise.bin and getnoise.symbols are expected in it")
parser.add_argument("--bench", default=str(ROOT / "_build/zkr/Vhtif_h/Vhtif_tb"))
parser.add_argument("--xchain", default="riscv64-unknown-elf-")
args = parser.parse_args()
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(SRC))
import getnoise_analyze as ga
checks = 0

def check(cond, what):
    global checks
    checks += 1
    if not cond:
        raise SystemExit(f"FAIL getnoise self-test check {checks}: {what}")

# ---------------------------------------------------------------- builds ----
CC = [args.xchain + "gcc", "-march=rv64gc_zicsr", "-mabi=lp64d", "-nostdlib", "-static"]

def symbols(text):
    return {p[2]: int(p[0], 16) for line in text.splitlines() if len(p := line.split()) == 3}

def build(name, source, defines=(), text=0, entry="getnoise"):
    """Assemble and link one file; returns (binary, symbols)."""
    elf = out / f"{name}.elf"
    subprocess.run(CC + [f"-D{d}" for d in defines] + [f"-Wl,-Ttext={text:#x},--no-relax,-e,{entry}", "-o", str(elf), str(source)],
                   check=True, capture_output=True, text=True)
    subprocess.run([args.xchain + "objcopy", "-O", "binary", "-j", ".text", str(elf), str(out / f"{name}.bin")], check=True)
    nm = subprocess.run([args.xchain + "nm", "-n", str(elf)], check=True, capture_output=True, text=True).stdout
    (out / f"{name}.symbols").write_text(nm)
    return (out / f"{name}.bin").read_bytes(), symbols(nm)

def mutant(name, old, new):
    """A copy of getnoise.S with one line changed."""
    text = (SRC / "getnoise.S").read_text()
    if text.count(old) != 1:
        raise SystemExit(f"FAIL getnoise self-test: mutant {name}: {old!r} is not unique in getnoise.S")
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
	li		t0, 1
	li		t1, 0x80001000
	sd		t0, 0(t1)
3:	j		3b
	.balign	8
	.globl	d_entry
d_entry:	.dword 0, 0, 0, 0, 0, 0, 0
"""
BASE, SIZE = 0x80000000, 0x20000            # the part of the bench RAM that is loaded and dumped
LOAD = BASE + 0x2000                        # payload; the driver and the tohost page are below it
BUF = LOAD + 0x10000                        # where getnoise_capture.py puts the buffer
PRE = (700 << 26) | (37 << 16) | 9          # a configuration the bench does not have by itself
LOCK = 1 << 63
FIELDS = ["status", "stored", "runs", "losses", "polls", "cfg_before", "cfg_used", "cfg_after", "noise_after", "mcause", "mepc"]

(out / "driver.S").write_text(DRIVER)
driver_bin, driver_sym = build("driver", out / "driver.S", text=BASE, entry="driver")
if not (out / "getnoise.symbols").exists():
    raise SystemExit(f"FAIL getnoise self-test: no getnoise.symbols in {out}; run make dbg-getnoise-test")
std_bin, SYM = (out / "getnoise.bin").read_bytes(), symbols((out / "getnoise.symbols").read_text())
slow_bin, slow_sym = build("getnoise_slow", SRC / "getnoise.S", ["GETNOISE_SLOW=300"])
sim_bin, sim_sym = build("getnoise_sim", SRC / "getnoise.S", ["GETNOISE_SIM"])
check(SYM["getnoise"] == 0 and SYM["getnoise_result"] == SYM["getnoise_params"] + 40, "payload layout: entry first, result block after five parameters")
check(len(std_bin) < 0x1000 and b"\x73\x00\x10\x00" in std_bin, "the board payload is small and ends in an ebreak")
check(b"\x73\x00\x10\x00" not in sim_bin, "the GETNOISE_SIM build has no ebreak")

# ------------------------------------------------------------ simulation ----
bench_runs = 0
def simulate(tag, mem, plusargs=(), max_cycles=1500000):
    """Run a RAM image on the bench. Returns (HTIF exit code or None, final cycle, RAM after)."""
    global bench_runs
    bench_runs += 1
    words = struct.unpack(f"<{SIZE // 8}Q", mem)
    (out / f"{tag}.hex").write_text("".join(f"{w:016x}\n" for w in words))
    dump = out / f"{tag}.dump"
    dump.unlink(missing_ok=True)
    r = subprocess.run([args.bench, f"+hex={out / tag}.hex", "+tohost=1000", f"+max_cycles={max_cycles}", f"+vec_out={dump}",
                        "+vec_out_start=0", f"+vec_out_words={SIZE // 8}", *plusargs], capture_output=True, text=True, timeout=600)
    (out / f"{tag}.log").write_text(r.stdout + r.stderr)
    done = re.search(r"\[HTIF\] exit (\d+) @ cyc=(\d+)", r.stdout)
    if not done or not dump.exists():
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
        struct.pack_into("<5Q", mem, LOAD - BASE + SYM["getnoise_params"], *params)
    struct.pack_into("<3Q", mem, driver_sym["d_entry"] - BASE, entry, precfg, prenoise)
    return mem

def outcome(mem, sym=SYM, load=LOAD):
    """Result block, driver words and buffer of a finished run."""
    r = dict(zip(FIELDS, struct.unpack_from("<11Q", mem, load - BASE + sym["getnoise_result"])))
    d = dict(zip(["d_mcause", "d_mepc", "d_noise", "d_cfg"], struct.unpack_from("<4Q", mem, driver_sym["d_entry"] - BASE + 24)))
    return dict(r, **d, buffer=mem[BUF - BASE:])

class NoiseModel:
    """The behavioural noise source of flow/fpga/karu_rosc_rng.v (SIM = 1),
    clock by clock: osc[t] is the symbol after t phase steps. A copy; if the
    Verilog model changes, this has to follow."""
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
noise_model = NoiseModel()

def split_runs(data):
    """Runs of a capture buffer, flags stripped; None if the bytes are not a capture."""
    runs = re.findall(rb"[\x80-\x8f][\x00-\x0f]*", data)
    return [bytes(v & 15 for v in r) for r in runs] if sum(map(len, runs)) == len(data) else None

def source_error(runs, k, clocks, raw_period=8):
    """None if the runs are stretches of every k-th symbol of the noise model,
    in order, with at least two symbols missing between runs (the one that
    was overwritten and the one the loss poll returned). Else what is wrong.
    raw_period is the bench's SAMPLE_DIV: clocks per raw symbol."""
    stream, period = noise_model.upto(clocks + 64), raw_period * k
    if len(runs[0]) < 32:
        return "first run too short to place"
    places = [(r, p) for r in range(period) if (p := stream[r::period].find(runs[0])) >= 0]
    if len(places) != 1:
        return f"first run found at {len(places)} places in the source"
    kept, end = stream[places[0][0]::period], places[0][1] + len(runs[0])
    for i, run in enumerate(runs[1:], 1):
        place = kept.find(run, end + 2)
        if place < 0:
            return f"run {i} is not a stretch of the source after run {i - 1}"
        end = place + len(run)
    return None

def problems(o, k, count, clocks, pre=PRE, stop=None):
    """Everything that is wrong with a capture that should have succeeded."""
    bad = []
    stop = LOAD + SYM["getnoise_stop"] if stop is None else stop
    if (o["d_mcause"], o["d_mepc"]) != (3, stop): bad.append("did not stop at its ebreak")
    if o["status"] != 0: bad.append(f"status {o['status']}")
    if o["stored"] != count: bad.append("stored count")
    runs = split_runs(o["buffer"][:o["stored"]])
    if runs is None: bad.append("buffer is not flagged symbols"); runs = [b""]
    if len(runs) != o["runs"]: bad.append("run flags against run count")
    if o["runs"] > o["losses"] + 1: bad.append("more runs than losses allow")
    if o["polls"] < o["stored"] + o["losses"]: bad.append("fewer polls than symbols")
    if any(o["buffer"][o["stored"]:o["stored"] + 64]): bad.append("wrote past the last symbol")
    if o["cfg_before"] != pre: bad.append("cfg_before")
    if o["cfg_used"] != (pre & ~0xffff) | (k - 1): bad.append("interval not set or cutoffs not kept")
    if o["cfg_after"] != pre or o["d_cfg"] != pre: bad.append("mentropycfg not restored")
    if o["noise_after"] != 1 or o["d_noise"] != 1: bad.append("test mode not left")
    err = source_error(runs, k, clocks) if runs[0] else "no symbols"
    if err: bad.append("symbols are not consecutive samples of the source: " + err)
    return bad

def run(tag, payload, params, **kw):
    plusargs = kw.pop("plusargs", ())
    code, clocks, mem = simulate(tag, image(payload, params, **kw), plusargs)
    check(code == 0, f"{tag}: the bench run ends through the driver (see {tag}.log)")
    return outcome(mem), clocks

# In the bench a raw symbol takes 8 clocks, so k = 32 gives the 256 clocks
# per kept symbol that the board has at k = 1.
N = 1024
o, clocks = run("sim-capture", std_bin, [31, N, BUF, N, 4096])
check(problems(o, 32, N, clocks) == [], f"capture at 256 clocks per symbol: {problems(o, 32, N, clocks)}")
check(o["runs"] == 1 and o["losses"] == 0, "the loop keeps up at 256 clocks per symbol: one run, no loss")
good = o
o, clocks = run("sim-capture-128", std_bin, [15, 256, BUF, 256, 4096])
check(problems(o, 16, 256, clocks) == [] and o["losses"] == 0, "and at 128 clocks per symbol, half the board's period at k = 1")

# negative controls on the checks themselves: tampered captures
t = dict(good, buffer=good["buffer"][:500] + good["buffer"][501:])
check(any("not consecutive" in p for p in problems(t, 32, N, clocks)), "a capture with one symbol removed is caught")
t = dict(good, buffer=good["buffer"][:500] + bytes([good["buffer"][500] | 0x80]) + good["buffer"][501:])
check("run flags against run count" in problems(t, 32, N, clocks), "a run flag that the payload did not count is caught")

# slow consumer: losses, several runs, every run a stretch of the source
M = 448                                     # seven stalls: runs of 64
o, clocks = run("sim-slow", slow_bin, [31, M, BUF, M, 4096])
check(problems(o, 32, M, clocks, stop=LOAD + slow_sym["getnoise_stop"]) == [], f"slow consumer: {problems(o, 32, M, clocks, stop=LOAD + slow_sym['getnoise_stop'])}")
check(o["losses"] >= 2 and o["runs"] >= 3, f"slow consumer loses symbols and records several runs ({o['losses']} losses, {o['runs']} runs)")
slow_runs = [len(r) for r in split_runs(o["buffer"][:M])]
check(max(slow_runs) <= 64 and sum(slow_runs) == M, f"runs end where the consumer stalls: {slow_runs}")

# refusals: nothing may change
o, _ = run("sim-locked", std_bin, [31, N, BUF, N, 4096], precfg=PRE | LOCK)
check(o["status"] == 2 and o["stored"] == 0 and o["polls"] == 0, "a locked configuration is refused with status LOCKED")
check(o["d_cfg"] == PRE | LOCK and o["cfg_used"] == 0 and o["d_noise"] == 1 and not any(o["buffer"][:64]), "LOCKED: configuration, test mode and buffer untouched")
o, _ = run("sim-busy", std_bin, [31, N, BUF, N, 4096], prenoise=1 << 31)
check(o["status"] == 3 and o["stored"] == 0, "a source already in test mode is refused with status BUSY")
check(o["d_cfg"] == PRE and o["d_noise"] >> 31 == 1 and o["cfg_used"] == 0, "BUSY: configuration untouched, the other user's test mode still on")
for name, params in (("count 0", [31, 0, BUF, N, 4096]), ("count over size", [31, N + 1, BUF, N, 4096]), ("idle 0", [31, N, BUF, N, 0])):
    o, _ = run("sim-param", std_bin, params)
    check(o["status"] == 4 and o["stored"] == 0 and o["d_cfg"] == PRE and o["d_noise"] == 1 and o["cfg_before"] == 0, f"PARAM for {name}, source untouched")

# waits are bounded, and the source is put back on the way out
o, _ = run("sim-strap-low", std_bin, [31, N, BUF, N, 1500], plusargs=["+zkr_en=0"])
check(o["status"] == 6 and o["stored"] == 0 and o["polls"] == 1500, "no symbols (strap low): TIMEOUT after the idle limit")
check(o["cfg_after"] == PRE and o["d_cfg"] == PRE and o["d_noise"] == 1, "TIMEOUT: configuration restored, test mode left")
o, _ = run("sim-fast", std_bin, [0, N, BUF, N, 1500])
check(o["status"] == 6 and o["stored"] == 0 and o["losses"] > 700 and o["runs"] == 0, "a source faster than the loop (8 clocks per symbol): only losses, then TIMEOUT")
check(o["d_cfg"] == PRE and o["d_noise"] == 1, "after it: configuration restored, test mode left")
o, _ = run("sim-short-runs", std_bin, [3, 64, BUF, 64, 1500])
runs = split_runs(o["buffer"][:64])
check(o["status"] == 0 and runs is not None and len(runs) == o["runs"] and o["runs"] <= o["losses"] + 1 and o["losses"] >= 32,
      "32 clocks per symbol: most symbols are lost, and the bookkeeping still agrees")
check(o["d_cfg"] == PRE and o["d_noise"] == 1, "after it: configuration restored, test mode left")
o, _ = run("sim-fault", std_bin, [31, N, BASE + 0x40000000, N, 4096])
check(o["status"] == 7 and o["mcause"] == 7 and LOAD + SYM["getnoise"] < o["mepc"] < LOAD + SYM["getnoise_stop"],
      f"a faulting buffer address ends in status TRAP (mcause {o['mcause']})")
check(o["cfg_after"] == PRE and o["d_cfg"] == PRE and o["d_noise"] == 1 and (o["d_mcause"], o["d_mepc"]) == (3, LOAD + SYM["getnoise_stop"]),
      "TRAP in the middle of a capture: configuration restored, test mode left, normal stop")

# the GETNOISE_SIM build alone at the reset address, reporting through tohost
mem = bytearray(SIZE)
mem[:len(sim_bin)] = sim_bin
struct.pack_into("<5Q", mem, sim_sym["getnoise_params"], 63, 256, BUF, 256, 4096)
code, clocks, after = simulate("sim-tohost", mem)
o = outcome(after, sim_sym, BASE)
runs = split_runs(o["buffer"][:256])
check(code == 0 and o["status"] == 0 and o["stored"] == 256 and runs is not None and len(runs) == 1, "GETNOISE_SIM build: status 0 through tohost")
check(source_error(runs, 64, clocks) is None and o["cfg_after"] == o["cfg_before"] == (821 << 26) | (41 << 16) | 1 and o["noise_after"] == 1,
      "GETNOISE_SIM build: symbols from the source, the bench's reset configuration restored")
struct.pack_into("<5Q", mem, sim_sym["getnoise_params"], 63, 0, BUF, 256, 4096)
check(simulate("sim-tohost-param", mem)[0] == 4, "GETNOISE_SIM build: an error status is the exit code")

# negative controls: mutants of the payload
mut_bin, mut_sym = build("mutant_loss", mutant("mutant_loss", "\tbltz\tt0, lost\n", "\tnop\n"), ["GETNOISE_SLOW=300"])
o, clocks = run("sim-mutant-loss", mut_bin, [31, M, BUF, M, 4096])
found = problems(o, 32, M, clocks, stop=LOAD + mut_sym["getnoise_stop"])
check(o["status"] == 0 and o["runs"] == 1 and len(found) == 1 and "not consecutive" in found[0],
      f"mutant that ignores the loss flag joins runs silently; only the comparison with the source catches it: {found}")
mut_bin, mut_sym = build("mutant_cfg", mutant("mutant_cfg", "\tcsrw\tCSR_MENTROPYCFG, s3\n", "\tnop\n"))
o, clocks = run("sim-mutant-cfg", mut_bin, [31, 64, BUF, 64, 4096])
check("mentropycfg not restored" in problems(o, 32, 64, clocks, stop=LOAD + mut_sym["getnoise_stop"]) and o["d_cfg"] == (PRE & ~0xffff) | 31,
      "mutant without the restore of mentropycfg is caught")
mut_bin, mut_sym = build("mutant_test", mutant("mutant_test", "\tcsrw\tCSR_MNOISE, zero\n", "\tnop\n"))
o, clocks = run("sim-mutant-test", mut_bin, [31, 64, BUF, 64, 4096])
check("test mode not left" in problems(o, 32, 64, clocks, stop=LOAD + mut_sym["getnoise_stop"]) and o["d_noise"] >> 31 == 1,
      "mutant that stays in test mode is caught")
checks_sim = checks

# -------------------------------------------------------------- analysis ----
def lane(rng, F, D, s2, n):
    """n bits of the model: x += N(F, s2) mod 1, bit = x < D."""
    x, sd, bits, gauss = rng.random(), math.sqrt(s2), bytearray(n), rng.gauss
    for i in range(n):
        x = (x + gauss(F, sd)) % 1.0
        bits[i] = x < D
    return bits

def symbols_from_ints(lanes, n):
    """Symbols from four lanes given as integers, bit i of each being sample i."""
    columns = []
    for lane, value in enumerate(lanes):
        text = bin(value)[2:].zfill(n)[::-1].encode()                       # b"0101...", sample 0 first
        columns.append(int.from_bytes(text.translate(bytes(((v - 48) & 1) << lane for v in range(256))), "little"))
    return (columns[0] | columns[1] | columns[2] | columns[3]).to_bytes(n, "little")

def write_capture(name, lanes, k, runs=None, label=None):
    """Capture file and sidecar from four lanes of bits, or from symbols; runs = list of (start, length)."""
    symbols = lanes if isinstance(lanes, bytes) else bytes(a | (b << 1) | (c << 2) | (d << 3) for a, b, c, d in zip(*lanes))
    runs = runs or [(0, len(symbols))]
    data = b"".join(bytes([symbols[s] | 0x80]) + symbols[s + 1:s + n] for s, n in runs)
    path = out / f"{name}.bin"
    path.write_bytes(data)
    path.with_suffix(".json").write_text(json.dumps(dict(k=label or k, stored=len(data), run_lengths=[n for _, n in runs],
                                                         sha256=hashlib.sha256(data).hexdigest())))
    return str(path)

def analysis(tag, files, *options):
    """Run the analysis; returns (exit status, its JSON or None, its text)."""
    where = out / f"analysis-{tag}"
    for f in where.glob("getnoise-analysis.*"):
        f.unlink()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        code = ga.main([*files, "--out", str(where), *options])
    done = (where / "getnoise-analysis.json").exists()
    return code, json.loads((where / "getnoise-analysis.json").read_text()) if done else None, \
        (where / "getnoise-analysis.txt").read_text() if done else ""

TRUE = [(0.137, 0.50, 0.010), (0.291, 0.47, 0.020), (0.412, 0.55, 0.005), (0.068, 0.50, 0.015)]   # (F, D, sigma^2) per raw sample
KS = (1, 2, 4, 8)
rng = random.Random(210202196)
raw = [lane(rng, *p, 400000) for p in TRUE]
# the k = 1 capture in three runs with samples missing in between
files = [write_capture(f"syn-k{k}", [l[::k] for l in raw], k, [(0, 150000), (150007, 100000), (250020, 149980)] if k == 1 else None) for k in KS]
code, res, text = analysis("independent", files)
check(code == 0 and res["verdict"] is None and "No verdict: no thresholds were given." in text, "no thresholds: exit 0 and no verdict")
check([c["k"] for c in res["captures"]] == list(KS) and res["captures"][0]["runs"] == 3 and res["captures"][0]["symbols"] == 399980, "captures, runs and symbols read")

def fold(f):
    f %= 1.0
    return min(f, 1 - f)

def fit_errors(res):
    """Fitted against true parameters. Tolerances: D 0.005, F 0.004, sigma^2 12 %
    (15 % for the line through the origin), log-log slope 1 +- 0.1."""
    bad = []
    for cap in res["captures"]:
        for l, (F, D, s2) in zip(cap["lanes"], TRUE):
            f, k = l["fit"], cap["k"]
            if abs(l["ones_fraction"] - D) > 0.005: bad.append(f"k={k} lane {l['lane']} D")
            if k > 2 or not f["identifiable"]: continue                     # the fits with the most data
            if abs(f["F"] - fold(k * F)) > 0.004: bad.append(f"k={k} lane {l['lane']} F {f['F']:.4f}")
            if abs(f["sigma2"] / (k * s2) - 1) > 0.12: bad.append(f"k={k} lane {l['lane']} sigma^2 {f['sigma2']:.5f}")
    for row, (F, D, s2) in zip(res["decimation"], TRUE):
        if not row["linear"]: bad.append(f"lane {row['lane']} not linear in k")
        if abs((row["sigma2_per_raw_sample"] or 0) / s2 - 1) > 0.15: bad.append(f"lane {row['lane']} sigma^2 per raw sample")
        if abs((row["exponent"] or 0) - 1) > 0.1: bad.append(f"lane {row['lane']} exponent")
    return bad
check(fit_errors(res) == [], f"the fit recovers (F, D, sigma^2) and sigma^2 grows linearly with k: {fit_errors(res)}")
# The per-bit estimate. For generated lanes the true value is known: the
# chance of guessing a bit from the exact previous phase.
def truth_bits(D, s2):
    return ga.bits(ga.guess_probability(D, s2))
def estimate_errors(res):
    bad = []
    for cap in res["captures"]:
        for l, (F, D, s2) in zip(cap["lanes"], TRUE):
            e, f, where = l["estimate"], l["fit"], f"k={cap['k']} lane {l['lane']}"
            fair = -math.log2(1 - math.tanh(math.pi * math.sqrt(f["sigma2"])) / 2)
            if not e["fit"]["ok"]: bad.append(f"{where} refused: {e['fit']['reasons']}")
            if abs(e["fair_duty_bound"]["bits"] - fair) > 1e-12: bad.append(f"{where} D=1/2 bound")
            if abs(e["bits"] - min(e["bias"]["bits"], e["model"]["bits"], e["predictor"]["bits"])) > 1e-12: bad.append(f"{where} not the smallest")
            if e["model"]["bits"] > min(fair, e["bias"]["bits"]) + 1e-12: bad.append(f"{where} model above a cap")
            if not e["bits_low"] <= e["bits"]: bad.append(f"{where} lower end above the estimate")
            if e["bits_low"] > truth_bits(D, cap["k"] * s2): bad.append(f"{where} lower end {e['bits_low']:.4f} above the truth")
            if f["identifiable"] and not f["sigma2_low"] <= cap["k"] * s2 <= f["sigma2_high"]: bad.append(f"{where} sigma^2 range misses the truth")
            if "one bit of one lane" not in e["scope"]: bad.append(f"{where} scope")
    return bad
check(estimate_errors(res) == [], f"per-bit estimates: smallest of bias cap, predictor cap and model; lower end below the true value; "
      f"sigma^2 range holds the true value; all sixteen fits accepted: {estimate_errors(res)}")
weak = res["captures"][3]["lanes"][1]["fit"]                                # sigma^2 = 0.16 at k = 8: C_j below the noise
check(not weak["identifiable"] and weak["F"] is None and 0.05 < weak["sigma2"] < 0.16, "no visible autocorrelation: a lower bound on sigma^2 below the true value, no F")
check(len(res["decimation"][1]["points"]) == 3 and len(res["decimation"][1]["predicted"]) == 4, "a lower bound is not used for the line; the line is still given at that k")
check(all(not c["cross_lane"]["flagged_pairs"] and not c["cross_lane"]["total_flagged"] for c in res["captures"]), "independent lanes are not flagged")
check(abs(ga.model_c(0.1, 0.625, 0.04, 1) - (4 * (0.454492 - 0.625) + 1)) < 2e-6, "closed form against the paper's Fig. 3 (p11 = 0.454492)")
word = res["captures"][0]["word_distribution"]
check(word["samples"] == 37500 + 25000 + 37495 and word["min_entropy"] < word["uniform_reference"] < 16 < word["sample_limit"],
      "words are taken inside runs, and the word figure comes with what the sample size allows")
check("not to be added up" in text and not any("word" in key or "symbol" in key for l in res["captures"][0]["lanes"] for key in l),
      "per-lane results carry no word or symbol figure, and the report says not to add them up")

# negative controls: the k = 4 capture labelled k = 8, and a broken model constant
relabelled = write_capture("syn-relabel", [l[::4] for l in raw], 4, label=8)
code, bad, _ = analysis("relabel", [files[0], files[1], relabelled])
check(any("not linear" in e for e in fit_errors(bad)), "a capture with the wrong decimation label breaks the linear growth of sigma^2")
saved, ga.K8 = ga.K8, ga.K8 / 2
code, bad, _ = analysis("broken", files[:2])
ga.K8 = saved
check(sum("sigma^2" in e for e in fit_errors(bad)) >= 4, f"an analysis with a wrong model constant misses the true sigma^2: {fit_errors(bad)[:3]}")

# verdicts only on request, and on the lower end of what was measured
code, res2, text = analysis("verdict-high", files[:1], "--min-lane-bits", "0.9", "--min-word-bits", "4")
check(code == 1 and res2["verdict"]["met"] is False and "NOT met" in text, "a threshold that is not met: exit 1")
code, res2, text = analysis("verdict-low", files[:1], "--min-lane-bits", "0.1", "--require-independent")
check(code == 0 and res2["verdict"]["met"] is True, "thresholds that are met: exit 0")
code, res2, text = analysis("verdict-fair", [files[2]], "--min-lane-bits", "0.3")
check(code == 0 and len(res2["verdict"]["checks"]) == 4 and min(truth_bits(D, 4 * s2) for F, D, s2 in TRUE) > 0.3,
      "a source that is the model passes a per-lane threshold that every lane truly meets (k = 4, 0.3 bits)")
check(analysis("verdict-fair-high", [files[2]], "--min-lane-bits", "0.7")[0] == 1, "and fails one that a lane does not meet")

# The reviewed defect: p1 = 0.75 on every lane, no memory. A bit is worth at
# most -log2(0.75) = 0.415; the verdict used the D = 1/2 bound alone and
# passed a claim of 0.75.
n8 = 8000000
biased = symbols_from_ints([rng.getrandbits(n8) | rng.getrandbits(n8) for _ in range(4)], n8)
code, res2, text = analysis("biased", [write_capture("syn-biased", biased, 1)], "--min-lane-bits", "0.75")
estimates = [l["estimate"] for l in res2["captures"][0]["lanes"]]
check(code == 1 and len(res2["verdict"]["checks"]) == 4 and all(not c["ok"] and "bias cap 0.41" in c["what"] for c in res2["verdict"]["checks"]),
      f"p1 = 0.75 on every lane: a claim of 0.75 bits fails, and the reason names the bias cap: {res2['verdict']['checks'][0]['what']}")
check(all(abs(e["bias"]["bits"] - 0.4150) < 0.001 and e["bits_low"] < e["bias"]["bits"] and e["fit"]["ok"] for e in estimates),
      "its lower end is below the bias cap of 0.415, and the model (no memory, D = 0.75) is not refused")
check(all(e["fair_duty_bound"]["bits"] >= 0.75 for e in estimates),
      f"negative control: the D = 1/2 bound alone is {estimates[0]['fair_duty_bound']['bits']:.4f} and would have passed 0.75")

# Not the model at all: a two-state Markov chain (stay at 1 with 0.9, go to 1 with 0.5) and a fixed pattern.
def markov(n, stay=0.9, rise=0.5):
    out, bit, draw = bytearray(n), 1, rng.random
    for i in range(n):
        bit = draw() < (stay if bit else rise)
        out[i] = bit
    return out
code, res2, text = analysis("markov", [write_capture("syn-markov", [markov(200000) for _ in range(4)], 1)], "--min-lane-bits", "0.2")
estimates = [l["estimate"] for l in res2["captures"][0]["lanes"]]
check(code == 1 and all("refused, the model does not fit" in c["what"] and "standard errors from the model" in c["what"] for c in res2["verdict"]["checks"]),
      f"a Markov chain is refused, with the misfit in the reason: {res2['verdict']['checks'][0]['what']}")
check(all(e["bits_low"] >= 0.2 and not e["fit"]["ok"] for e in estimates),
      "negative control: its lower end alone would have passed 0.2, above the chain's worst case of -log2(0.9) = 0.152")
pattern = [bytearray(([1, 1, 0, 1, 0, 0] * 40000)[shift:shift + 200000]) for shift in range(4)]
code, res2, text = analysis("pattern", [write_capture("syn-pattern", pattern, 1)], "--min-lane-bits", "0.01", "--min-word-bits", "1")
x = res2["captures"][0]
check(code == 1 and not any(c["ok"] for c in res2["verdict"]["checks"]) and all(not l["estimate"]["fit"]["ok"] and l["estimate"]["bits_low"] < 0.001 for l in x["lanes"])
      and x["word_distribution"]["bits_low"] < 0.001 and x["word_distribution"]["limited_by"] == "predictor",
      "a fixed pattern: every lane refused, the predictor caps at zero, lanes and words fail any threshold")

# The word verdict had the same weakness: the distribution of single words says nothing about predicting them.
w = res["captures"][0]["word_distribution"]
check(analysis("verdict-word", files[:1], "--min-word-bits", "8")[0] == 1 and w["min_entropy_99"] >= 8 > w["bits_low"] and w["limited_by"] == "predictor",
      f"a word threshold of 8 fails on the predictor cap ({w['bits_low']:.2f}); the distribution alone ({w['min_entropy_99']:.2f}) would have passed")
check(analysis("verdict-word-low", files[:1], "--min-word-bits", "6")[0] == 0, "a word threshold below both figures is met")

# The independence verdict must not pass for want of data.
code, res2, text = analysis("verdict-small", [write_capture("syn-small", [l[:2000] for l in raw], 1)], "--require-independent")
x = res2["captures"][0]["cross_lane"]
check(code == 1 and not x["flagged_pairs"] and not x["total_flagged"] and x["detectable_phi"] > 0.05 and "would have been flagged" in text,
      f"2000 symbols: nothing is flagged, and the verdict fails because a correlation of 0.05 could not have been seen ({x['detectable_phi']:.3f})")

# statistics stay inside runs: four constant runs, 1 1 0 0, of six symbols
six = [[1] * 12 + [0] * 12] * 4
code, res2, _ = analysis("runs", [write_capture("syn-runs", six, 1, [(0, 6), (6, 6), (12, 6), (18, 6)])])
l = res2["captures"][0]["lanes"][0]
check(l["autocorrelation"] == [1.0] * 5 and l["pairs"] == [20, 16, 12, 8, 4] and l["repetitions"]["longest"] == 6, "autocorrelation and repetitions do not cross run boundaries")
check(res2["captures"][0]["word_distribution"]["samples"] == 4 and res2["captures"][0]["word_distribution"]["distinct"] == 2, "words do not cross run boundaries")

# dependent lanes: lane 1 a copy of lane 0, lane 2 a copy with 5 % of its bits flipped, lane 3 independent
n = 200000
a = raw[0][:n]
noisy = bytearray(v ^ (rng.random() < 0.05) for v in a)
code, dep, text = analysis("dependent", [write_capture("syn-dependent", [a, a, noisy, raw[3][:n]], 1)])
x = dep["captures"][0]
check(x["cross_lane"]["flagged_pairs"] == [[0, 1], [0, 2], [1, 2]] and "DEPENDENT LANES: 0,1, 0,2, 1,2" in text, "copied and noisy-copy lanes are flagged, the independent lane is not")
check(x["cross_lane"]["total_flagged"] and x["cross_lane"]["total_correlation_bits"] > 1.5, "the four-lane statistic shows the redundancy in bits")
check(all(abs(x["lanes"][i]["ones_fraction"] - 0.5) < 0.005 for i in range(3)) and x["lanes"][1]["fit"] == x["lanes"][0]["fit"]
      and x["lanes"][1]["estimate"] == x["lanes"][0]["estimate"] and x["lanes"][0]["estimate"]["fit"]["ok"]
      and abs(x["lanes"][0]["fit"]["sigma2"] / 0.010 - 1) < 0.12 and x["lanes"][2]["estimate"]["bias"]["bits"] > 0.99,
      "the copy's own statistics are the original's, and the noisy copy's ones fraction looks no worse")
check(not x["lanes"][2]["estimate"]["fit"]["ok"] and "standard errors from the model" in x["lanes"][2]["estimate"]["fit"]["reasons"][0],
      "the noisy copy is not the model, and its model figure is refused")
check(x["symbol_distribution"]["min_entropy"] < res["captures"][0]["symbol_distribution"]["min_entropy"] - 1, "the symbol distribution shows the loss; no per-lane figure does")
code, _, _ = analysis("dependent-verdict", [str(out / "syn-dependent.bin")], "--require-independent")
check(code == 1, "--require-independent fails on dependent lanes")

# a lane that is the parity of two others: every pair looks independent (test data only; nothing of the sort is done to captures)
p0, p1 = lane(rng, 0.137, 0.5, 0.02, n), lane(rng, 0.291, 0.5, 0.02, n)
code, par, _ = analysis("parity", [write_capture("syn-parity", [p0, p1, raw[2][:n], bytearray(u ^ v for u, v in zip(p0, p1))], 1)])
x = par["captures"][0]["cross_lane"]
check(not x["flagged_pairs"] and x["total_flagged"] and 0.9 < x["total_correlation_bits"] < 1.1, "a parity lane passes every pair statistic; the four-lane statistic shows one redundant bit")

# two independent lanes with the same strong periodicity: a plain chi-square would flag them
q = [lane(rng, 0.2, 0.5, 0.0003, 50000) for _ in range(2)] + [raw[2][:50000], raw[3][:50000]]
code, per, _ = analysis("periodic", [write_capture("syn-periodic", q, 1)], "--lags", "512")
pair = per["captures"][0]["cross_lane"]["pairs"][0]
check(max(r["chi2"] for r in pair["lags"]) > 4.5 ** 2 and not pair["flagged"] and pair["inflation"] > 10,
      f"serial correlation is allowed for: chi-square {max(r['chi2'] for r in pair['lags']):.0f} without it, |z| {pair['max_abs_z']:.2f} with it")

# files that are not what their sidecar says, or not captures, are refused
data = bytearray((out / "syn-k8.bin").read_bytes())
data[1000] ^= 1
(out / "syn-tamper.bin").write_bytes(data)
(out / "syn-tamper.json").write_text((out / "syn-k8.json").read_text())
check(analysis("tamper", [str(out / "syn-tamper.bin")])[0] == 2, "a capture that does not match its sha256 is refused")
(out / "syn-bare.bin").write_bytes(bytes([0x85, 0x03, 0x13, 0x02]))
check(analysis("bare", [str(out / "syn-bare.bin")], "--k", "1")[0] == 2, "a file with bits [6:4] set is refused")
(out / "syn-bare.bin").write_bytes(bytes([0x85, 0x03, 0x03, 0x02]))
check(analysis("bare", [str(out / "syn-bare.bin")])[0] == 2 and analysis("bare", [str(out / "syn-bare.bin")], "--k", "1")[0] == 0,
      "a bare file needs --k")
checks_analysis = checks - checks_sim

# --------------------------------------------------------- capture phase ----
class FakeOpenOCD(threading.Thread):
    """Stand-in for OpenOCD's Tcl RPC with a target behind it.

    The target is this file's memory image: the phase's write_memory and
    read_memory work on it, and resume runs it on the simulation bench with
    the driver in front (in a thread; the hart reads "running" meanwhile).
    Attributes steer one scenario: precfg and plusargs for the bench, tamper
    to alter memory after the run, hang for a hart that never halts.
    """
    def __init__(self):
        super().__init__(daemon=True)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(8)
        self.port = self.listener.getsockname()[1]
        self.mem, self.regs, self.state = bytearray(SIZE), {}, "halted"
        self.precfg, self.plusargs, self.tamper, self.hang, self.sims, self.clocks = PRE, [], None, False, 0, []
    def execute(self, addr):
        self.sims += 1
        code, clocks, mem = simulate(f"target-{self.sims}", image(None, None, self.precfg, mem=self.mem, entry=addr), self.plusargs)
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
        if name == "read_memory" and int(a[0], 0) == 0x10000860:     # the temperature readout
            return "0x0005999a4888a0f6"
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

def phase(tag, payload=std_bin, sym_text=None, image="rom2m-auth", **env):
    """Run getnoise_capture.py as a process in its own artifact directory."""
    where = out / f"phase-{tag}"
    where.mkdir(exist_ok=True)
    for f in where.glob("getnoise*"):
        f.unlink()
    (where / "payload.symbols").write_text(f"{fixture:016x} T _start\n{fixture + 0x400:016x} T trap_handler\n")
    (where / "payload.bin").write_bytes(bytes(64))
    (where / "getnoise.bin").write_bytes(payload)
    (where / "getnoise.symbols").write_text(sym_text or (out / "getnoise.symbols").read_text())
    settings = dict(os.environ, KARU_BOARD_OUT=str(where), KARU_BOARD_RPC=f"127.0.0.1:{fake.port}", KARU_BOARD_GETNOISE_ADDR=hex(LOAD),
                    KARU_BOARD_GETNOISE_COUNT="512", KARU_BOARD_GETNOISE_MIN_RUN="256", KARU_BOARD_GETNOISE_K="32",
                    KARU_BOARD_GETNOISE_NOTE="self-test", KARU_BOARD_GETNOISE_WAIT="300", **dict(MAP, KARU_BOARD_IMAGE=image))
    settings.update({"KARU_BOARD_GETNOISE_" + k.upper(): str(v) for k, v in env.items()})
    fake.mem[:], fake.clocks = bytes(SIZE), []
    r = subprocess.run([sys.executable, str(SRC / "getnoise_capture.py")], env=settings, capture_output=True, text=True, timeout=600)
    (where / "phase.log").write_text(r.stdout + r.stderr)
    results = json.loads((where / "getnoise-results.json").read_text()) if (where / "getnoise-results.json").exists() else []
    return r.returncode, where, results

def details(results):
    return " | ".join(str(r["detail"]) for r in results if r["status"] != "PASS")

# a good capture at two decimations
code, where, results = phase("good", k="32,64")
check(code == 0 and [r["status"] for r in results] == ["PASS"] * 3, f"capture phase exits 0 with its three cases passed: {details(results)}")
for k, clocks in zip((32, 64), fake.clocks):
    data, side = (where / f"getnoise-k{k}.bin").read_bytes(), json.loads((where / f"getnoise-k{k}.json").read_text())
    check(len(data) == 512 and side["sha256"] == hashlib.sha256(data).hexdigest() and side["k"] == k and side["run_lengths"] == [512]
          and side["stored"] == 512 and side["losses"] == 0 and side["note"] == "self-test", f"k={k}: capture file and sidecar agree")
    check(int(side["cfg_before"], 16) == PRE == int(side["cfg_after"], 16) and int(side["cfg_used"], 16) == (PRE & ~0xffff) | (k - 1)
          and side["rct_cutoff"] == 37 and side["apt_cutoff"] == 700 and side["noise_after"] == 1, f"k={k}: sidecar records the configuration before, during and after")
    check(source_error(split_runs(data), k, clocks) is None, f"k={k}: the file holds consecutive samples of the simulated source")
check(fake.regs["pc"] == fixture == 0x208000 and fake.state == "halted", "the phase leaves the hart halted at the fixture's entry, as the other phases do")
code, res, _ = analysis("phase", [str(where / "getnoise-k32.bin"), str(where / "getnoise-k64.bin")])
check(code == 0 and [(c["k"], c["symbols"], c["runs"]) for c in res["captures"]] == [(32, 512, 1), (64, 512, 1)]
      and res["captures"][0]["lanes"][0]["cutoffs"] == {"rct": 37, "apt": 700}, "the analysis reads the phase's files and their sidecars")

# the fixture of another image map: refused before anything is sent
sims = fake.sims
code, where, results = phase("wrong-map", image="rom1m")
check(code == 1 and "board harness: the fixture in" in (where / "phase.log").read_text() and not results and fake.sims == sims,
      "a fixture built for another image map stops the phase with the reason")

# payload error status: the entropy strap low, so no symbols
fake.plusargs = ["+zkr_en=0"]
code, where, results = phase("timeout")
fake.plusargs = []
check(code == 1 and "TIMEOUT" in details(results) and not list(where.glob("getnoise-k*")), f"a payload error status fails the phase and leaves no capture: {details(results)[:80]}")

# locked configuration
fake.precfg = PRE | LOCK
code, where, results = phase("locked")
fake.precfg = PRE
check(code == 1 and "LOCKED" in details(results) and not list(where.glob("getnoise-k*")), f"a locked configuration fails the phase: {details(results)[:80]}")

# short runs: the slow payload against two minimum run lengths
slow_text = out / "getnoise_slow.symbols"
code, where, results = phase("runs-ok", slow_bin, slow_text.read_text(), count=M, min_run=32)
side = json.loads((where / "getnoise-k32.json").read_text())
check(code == 0 and side["runs"] >= 3 and sum(side["run_lengths"]) == M and side["losses"] >= side["runs"] - 1,
      f"several runs are recorded as such: {side['run_lengths']}")
check(source_error(split_runs((where / "getnoise-k32.bin").read_bytes()), 32, fake.clocks[0]) is None, "and each is a stretch of the source")
code, where, results = phase("runs-short", slow_bin, slow_text.read_text(), count=M, min_run=256)
check(code == 1 and "is shorter than 256" in details(results), f"no run of the minimum length fails the phase: {details(results)[:80]}")

# a hart that never halts
fake.hang = True
code, where, results = phase("hang", wait=1)
fake.hang = False
check(code == 1 and "still running" in details(results) and fake.state == "halted", "a payload that does not stop is halted and fails the phase")

# negative controls: the target's memory altered after the run
def alter_cfg(mem):
    struct.pack_into("<Q", mem, LOAD - BASE + SYM["getnoise_result"] + 56, PRE ^ 1)
fake.tamper = alter_cfg
code, where, results = phase("tamper-cfg")
check(code == 1 and "mentropycfg restored" in details(results), "a configuration that was not restored fails the phase")
def alter_flag(mem):
    mem[BUF - BASE + 100] |= 0x80
fake.tamper = alter_flag
code, where, results = phase("tamper-flag")
check(code == 1 and "run flags in the buffer" in details(results), "a run flag the payload did not count fails the phase")
def alter_status(mem):
    struct.pack_into("<Q", mem, LOAD - BASE + SYM["getnoise_result"], 1)
fake.tamper = alter_status
code, where, results = phase("tamper-status")
fake.tamper = None
check(code == 1 and "RUNNING" in details(results), "a payload that did not finish fails the phase")

print(f"getnoise self-test: PASS ({checks} checks: {checks_sim} simulation, {checks_analysis} analysis, {checks - checks_sim - checks_analysis} capture phase; {bench_runs} bench runs)")
sys.exit(0)
