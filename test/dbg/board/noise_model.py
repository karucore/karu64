"""The behavioural noise source of flow/fpga/karu_rosc_rng.v (SIM = 1), clock by
clock, for tests that compare a capture with what the simulated source
produced. A copy: if the Verilog model changes, this has to follow, and the
tests that use both notice when it does not (make rosc-meter-test compares
the two bit for bit, symbols and counts).

    model = NoiseModel()                    # the default model
    model = NoiseModel(jitter=10)           # +rosc_jitter=10
    stream = model.upto(clocks)             # bytes: stream[t] = the four lanes after t phase steps
    model = NoiseModel(jitter=10, turns=20, counts=True)
    counts = model.counts(clocks)           # bytes: counts[6 * t + r] = the count of ring r (mod 64) after t steps,
                                            #        in units of two ring periods (of one with direct=True)
    refs = model.refs(clocks)               # bytes: refs[t] = the two reference rings' bits after t steps

Default model: every lane gets a full-cycle uniform kick each clock, so its
bits have no memory at any sampling period. It is what seed, the health
tests and the GetNoise capture are tested with.

Characterisation model (jitter = n): lane m advances by STEP[m] plus a
zero-mean, roughly Gaussian value of standard deviation
(m + 1) * SIGMA_UNIT * 2^n cycles per clock, drawn separately for each lane.
This is the process of arXiv:2102.02196 with known parameters:

    F       = STEP[m] / 2^32 cycles per clock       (0.12, 0.20, 0.28, 0.36)
    sigma^2 = ((m + 1) * SIGMA_UNIT * 2^n)^2 per clock
              (n = 10: 8.14e-5, 3.26e-4, 7.32e-4, 1.30e-3)
    D       = duty / 2^32                           (1/2 unless +rosc_duty)

and sampled every P clocks it is the same process with (P F mod 1, D,
P sigma^2).

Rings and counts. There are six rings: the four lanes and two reference
rings (4 and 5), which are like lane 0 with a mean step 0.3 % above and
0.2 % below it and noise of their own. A reference ring has a sampled bit
like a lane's, phase below the duty (ref_b_o of the source; reference t in
bit t of refs()). Every ring has a count of the whole periods it has
completed since it was switched on; what the source shows, and counts()
returns, is that count halved and rounded down, modulo 64: the unit of a
count is two ring periods, because the source's counters count the ring
divided by two. With direct=True (cnt_direct_i of the source) the unit is
one period. The reference rings and the counts are computed only with
counts=True: the lanes do not depend on them. Three more options, all off
by default, and the lanes' bits are the same sequence whether or not the
first and the last are used:

    turns=n     +rosc_turns=n: ring r advances floor(3 n / STAGES[r]) whole
                periods more per clock, so that the counts move at the rate
                of real rings (n = 20: 20, 12, 8, 6, 20, 20)
    shared=n    +rosc_shared=n (with jitter): a fractional frequency
                modulation common to all rings. In each clock every ring's
                advance changes by the fraction h * 2^n / 2^32 of its nominal
                advance (turns plus STEP), h a roughly Gaussian value of
                standard deviation 37837 drawn once per clock: a fraction of
                standard deviation SIGMA_UNIT * 2^n (n = 7: 0.113 %)
    ring_en=m   the rings that run (bit r: ring r). A ring that is off holds
                its phase, and its count is zero. It may be changed between
                calls of upto(); the change applies from the next step.

    python3 test/dbg/board/noise_model.py --jitter 10 --period 16

prints the parameters of the lanes, for comparison with an analysis of a
simulated capture.

    python3 test/dbg/board/noise_model.py --compare dump.txt [--jitter 10] [--turns 20] [--shared 7] [--ring-en 2b] [--direct]

compares this model with a dump of the simulated source, written from the
first clock after its reset at a sampling period of one clock: one line per
clock with rng_val_o, rng_b_o, ref_b_o and cnt_o in hexadecimal
(test/tb_rosc_meter.sv writes it). Line i, counted from 0, must be the model
after i - 3 phase steps: the bits and the counts pass three register stages.
"""
# SPDX-License-Identifier: BSD-2-Clause
import math, sys

LANES, REFS = 4, 2
RINGS = LANES + REFS
M32, M64 = (1 << 32) - 1, (1 << 64) - 1
STEP = [(0x0a3d70a3 * (2 * m + 3)) & 0xffffffff for m in range(LANES)]
STEP += [STEP[0] + 3 * (STEP[0] // 1000), STEP[0] - 2 * (STEP[0] // 1000)]      # the reference rings
SCALE = [1, 2, 3, 4, 1, 1]                  # of a ring's own noise
STAGES = [3, 5, 7, 9, 3, 3]                 # inverters
MUL = [0xd6e8feb86659fd93, 0xca5a826395121157, 0x9fb21c651e98df25, 0xc2b2ae3d27d4eb4f,
       0xbf58476d1ce4e5b9, 0x94d049bb133111eb]
MUL_SHARED = 0xff51afd7ed558ccd
# standard deviation of the sum of four independent uniform 16-bit values, in cycles for a shift of 0
SIGMA_UNIT = math.sqrt(4 * (2 ** 32 - 1) / 12) / 2 ** 32

def parameters(jitter, duty=0x80000000, period=1):
    """(F, D, sigma^2) per lane of the characterisation model, per `period` clocks."""
    s2 = (SIGMA_UNIT * 2 ** jitter) ** 2
    return [((period * STEP[m] / 2 ** 32) % 1.0, duty / 2 ** 32, period * s2 * (m + 1) ** 2) for m in range(LANES)]

def gauss(prng, mul):
    """Four 16-bit fields of prng * mul, summed and centred."""
    u = (prng * mul) & M64
    return (u & 0xffff) + ((u >> 16) & 0xffff) + ((u >> 32) & 0xffff) + (u >> 48) - 131070

class NoiseModel:
    def __init__(self, jitter=None, duty=0x80000000, turns=0, shared=None, ring_en=(1 << RINGS) - 1, counts=False, direct=False):
        self.jitter, self.duty, self.turns, self.shared, self.ring_en = jitter, duty, turns, shared, ring_en
        self.unit = 32 if direct else 33        # a count is the periods above this bit of the accumulator
        self.rings = RINGS if counts else LANES
        self.prng = 0x9e3779b97f4a7c15
        # per ring: whole periods since it was switched on, above 32 bits of phase
        self.acc = [(0x13579bdf * (r + 1)) & M32 for r in range(RINGS)]
        self.osc, self.cnt, self.ref = bytearray(), bytearray(), bytearray()

    def upto(self, clocks):
        prng, acc, osc, cnt, ref, duty, jitter, shared = self.prng, self.acc, self.osc, self.cnt, self.ref, self.duty, self.jitter, self.shared
        nominal = [((3 * self.turns // STAGES[r]) << 32) + STEP[r] for r in range(RINGS)]
        on, counted, unit = [r for r in range(self.rings) if (self.ring_en >> r) & 1], self.rings == RINGS, self.unit
        for r in range(RINGS):
            if r not in on: acc[r] &= M32
        while len(osc) < clocks:
            osc.append(sum(((acc[m] & M32) < duty) << m for m in range(LANES)))
            if counted:
                cnt.extend([(a >> unit) & 63 for a in acc])
                ref.append(sum(((acc[LANES + t] & M32) < duty) << t for t in range(REFS)))
            if jitter is None:
                s = ((prng & 0xffff) + ((prng >> 16) & 0xffff) + ((prng >> 32) & 0xffff) + (prng >> 48) - 131070) << 14
                for r in on:
                    step = (STEP[r] + s * SCALE[r] + (((prng >> (8 * r)) & 0xff) << 24)) & M32
                    acc[r] = (acc[r] + nominal[r] - STEP[r] + step) & M64
            else:
                h = gauss(prng, MUL_SHARED) if shared is not None else 0
                for r in on:
                    a = nominal[r] + ((gauss(prng, MUL[r]) * SCALE[r]) << jitter)
                    if shared is not None: a += (nominal[r] * h) >> (32 - shared)
                    if a < 0: a &= M32              # a ring does not run backwards
                    acc[r] = (acc[r] + a) & M64
            prng ^= (prng << 13) & M64; prng ^= prng >> 7; prng ^= (prng << 17) & M64
        self.prng = prng
        return bytes(osc[:clocks])

    def counts(self, clocks):
        """The counts of the six rings, modulo 64, six bytes per phase step: pairs of periods, or periods if direct."""
        assert self.rings == RINGS, "NoiseModel(counts=True) keeps the counts"
        self.upto(clocks)
        return bytes(self.cnt[:RINGS * clocks])

    def refs(self, clocks):
        """The sampled bits of the reference rings, one byte per phase step: reference t in bit t."""
        assert self.rings == RINGS, "NoiseModel(counts=True) keeps the reference rings"
        self.upto(clocks)
        return bytes(self.ref[:clocks])

def compare(path, model, minimum):
    """None if the dump is this model, bits and counts, and long enough. Else what is wrong."""
    lines = open(path).read().split("\n")[:-1]
    if len(lines) < minimum + 3:
        return f"{len(lines)} lines, fewer than {minimum + 3}"
    steps = len(lines) - 3
    stream, counts, refs = model.upto(steps), model.counts(steps), model.refs(steps)
    seen, seen_ref = [set() for _ in range(RINGS)], set()
    for i, line in enumerate(lines):
        val, b, rb, cnt = (int(x, 16) for x in line.split())
        if val != 1:
            return f"line {i}: no symbol in this clock"
        if i < 3:
            continue
        t = i - 3
        if b != stream[t]:
            return f"line {i}: symbol {b:x}, the model has {stream[t]:x} after {t} steps"
        if rb != refs[t]:
            return f"line {i}: reference bits {rb:x}, the model has {refs[t]:x} after {t} steps"
        seen_ref.add(rb)
        for r in range(RINGS):
            c = (cnt >> (6 * r)) & 63
            if c != counts[RINGS * t + r]:
                return f"line {i}: count of ring {r} is {c}, the model has {counts[RINGS * t + r]} after {t} steps"
            seen[r].add(c)
    for r in range(RINGS):
        if len(seen[r]) < (2 if (model.ring_en >> r) & 1 else 1):
            return f"ring {r}: its count never changed"
    for t in range(REFS):
        if (model.ring_en >> (LANES + t)) & 1 and len({(rb >> t) & 1 for rb in seen_ref}) < 2:
            return f"reference {t}: its bit never changed"
    return None

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Parameters of the characterisation model, per lane; or a dump of the simulated source against this model.")
    parser.add_argument("--jitter", type=int, help="the n of +rosc_jitter=<n>")
    parser.add_argument("--duty", type=lambda v: int(v, 16), default=0x80000000, help="the +rosc_duty value, hexadecimal (80000000)")
    parser.add_argument("--period", type=int, default=1, help="clocks per symbol (1)")
    parser.add_argument("--turns", type=int, default=0, help="the n of +rosc_turns=<n> (0)")
    parser.add_argument("--shared", type=int, help="the n of +rosc_shared=<n>")
    parser.add_argument("--ring-en", type=lambda v: int(v, 16), default=(1 << RINGS) - 1, help="the rings that run, hexadecimal (3f)")
    parser.add_argument("--direct", action="store_true", help="cnt_direct_i set: the counts are ring periods, not pairs")
    parser.add_argument("--compare", metavar="DUMP", help="compare a dump of the simulated source with the model")
    parser.add_argument("--min-clocks", type=int, default=100000, help="with --compare: the least number of clocks to accept (100000)")
    args = parser.parse_args()
    if args.compare:
        model = NoiseModel(jitter=args.jitter, duty=args.duty, turns=args.turns, shared=args.shared, ring_en=args.ring_en, counts=True,
                           direct=args.direct)
        error = compare(args.compare, model, args.min_clocks)
        clocks = len(model.osc)
        print(f"noise model against {args.compare}: " + (error or f"symbols, reference bits and counts agree in {clocks} clocks"))
        sys.exit(1 if error else 0)
    if args.jitter is None:
        parser.error("--jitter is needed for the parameters")
    for lane, (F, D, s2) in enumerate(parameters(args.jitter, args.duty, args.period)):
        print(f"lane {lane}: F {F:.6f} (seen as {min(F, 1 - F):.6f})  D {D:.6f}  sigma^2 {s2:.6e}")
    sys.exit(0)
