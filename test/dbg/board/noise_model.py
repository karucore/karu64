"""The behavioural noise source of flow/fpga/karu_rosc_rng.v (SIM = 1), clock by
clock, for tests that compare a capture with what the simulated source
produced. A copy: if the Verilog model changes, this has to follow, and the
tests that use both notice when it does not.

    model = NoiseModel()                    # the default model
    model = NoiseModel(jitter=10)           # +rosc_jitter=10
    stream = model.upto(clocks)             # bytes: stream[t] = the four lanes after t phase steps

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

    python3 test/dbg/board/noise_model.py --jitter 10 --period 16

prints those parameters, for comparison with an analysis of a simulated
capture.
"""
# SPDX-License-Identifier: BSD-2-Clause
import math, sys

LANES = 4
M64 = (1 << 64) - 1
STEP = [(0x0a3d70a3 * (2 * m + 3)) & 0xffffffff for m in range(LANES)]
MUL = [0xd6e8feb86659fd93, 0xca5a826395121157, 0x9fb21c651e98df25, 0xc2b2ae3d27d4eb4f]
# standard deviation of the sum of four independent uniform 16-bit values, in cycles for a shift of 0
SIGMA_UNIT = math.sqrt(4 * (2 ** 32 - 1) / 12) / 2 ** 32

def parameters(jitter, duty=0x80000000, period=1):
    """(F, D, sigma^2) per lane of the characterisation model, per `period` clocks."""
    s2 = (SIGMA_UNIT * 2 ** jitter) ** 2
    return [((period * STEP[m] / 2 ** 32) % 1.0, duty / 2 ** 32, period * s2 * (m + 1) ** 2) for m in range(LANES)]

class NoiseModel:
    def __init__(self, jitter=None, duty=0x80000000):
        self.jitter, self.duty = jitter, duty
        self.prng = 0x9e3779b97f4a7c15
        self.phase = [(0x13579bdf * (m + 1)) & 0xffffffff for m in range(LANES)]
        self.osc = bytearray()

    def upto(self, clocks):
        prng, ph, osc, duty, jitter = self.prng, self.phase, self.osc, self.duty, self.jitter
        while len(osc) < clocks:
            osc.append(sum((ph[m] < duty) << m for m in range(LANES)))
            if jitter is None:
                s = ((prng & 0xffff) + ((prng >> 16) & 0xffff) + ((prng >> 32) & 0xffff) + (prng >> 48) - 131070) << 14
                for m in range(LANES):
                    ph[m] = (ph[m] + STEP[m] + s * (m + 1) + (((prng >> (8 * m)) & 0xff) << 24)) & 0xffffffff
            else:
                for m in range(LANES):
                    u = (prng * MUL[m]) & M64
                    g = (u & 0xffff) + ((u >> 16) & 0xffff) + ((u >> 32) & 0xffff) + (u >> 48) - 131070
                    ph[m] = (ph[m] + STEP[m] + ((g * (m + 1)) << jitter)) & 0xffffffff
            prng ^= (prng << 13) & M64; prng ^= prng >> 7; prng ^= (prng << 17) & M64
        self.prng = prng
        return bytes(osc[:clocks])

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Parameters of the characterisation model, per lane.")
    parser.add_argument("--jitter", type=int, required=True, help="the n of +rosc_jitter=<n>")
    parser.add_argument("--duty", type=lambda v: int(v, 16), default=0x80000000, help="the +rosc_duty value, hexadecimal (80000000)")
    parser.add_argument("--period", type=int, default=1, help="clocks per symbol (1)")
    args = parser.parse_args()
    for lane, (F, D, s2) in enumerate(parameters(args.jitter, args.duty, args.period)):
        print(f"lane {lane}: F {F:.6f} (seen as {min(F, 1 - F):.6f})  D {D:.6f}  sigma^2 {s2:.6e}")
    sys.exit(0)
