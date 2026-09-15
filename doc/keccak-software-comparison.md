# Keccak software comparison — 2026-09-13

Maintained reproduction harness: [test/keccak-sw](../test/keccak-sw/README.md).
These are diagnostic microbenchmarks, not application throughput claims.
The later profile's [September 14 synthesis and bitstream results](release-diagnostics-2026-09-14.md)
do not update these earlier cycle measurements; profile and board throughput
must be measured separately.
All cycle numbers below come from the same FPGA-geometry ideal HTIF Verilator
binary, with data L1 enabled, instruction cache disabled and no injected delays.
They are not FPGA/DDR or Linux application measurements.
The vector pipeline and mul16/div64 settings match the FPGA structure;
scalar arithmetic retains the simulator's mul1/div1 defaults. Every row,
including the instruction-assisted row, uses that same configuration.

## Checked, inlined C results

Average core cycles per block, 16 consecutive single-stream blocks. Absorb is
load/XOR/permutation; squeeze is store/permutation, including the final
permutation for a steady-state schedule. Absorb input is warmed before timing.
State initialization, known-answer checks and result printing are outside timing.

| Build | Absorb 168 B | Absorb 136 B | Squeeze 168 B | Squeeze 136 B |
|---|---:|---:|---:|---:|
| GCC 16.1, RV64GC | 31902.75 | 29729.31 | 30366.81 | 29090.44 |
| GCC 16.1, RV64GC+Zbb | 18179.94 | 16604.00 | 17204.50 | 16447.50 |
| GCC 16.1, RV64GCV+Zbb+Zvbb | 17568.13 | 18025.75 | 16561.38 | 16675.69 |
| Clang 22.1.8, RV64GC | 25389.63 | 25413.50 | 24653.19 | 24969.94 |
| Clang 22.1.8, RV64GC+Zbb | 16571.63 | 16162.63 | 16058.75 | 16347.50 |
| Clang 22.1.8, RV64GCV+Zbb+Zvbb | 17496.88 | 16385.31 | 16458.88 | 16804.13 |
| Resident `vkeccak.vi` instruction-assisted path | 221.75 | 197.75 | 156.88 | 144.56 |

Against the Clang vector-enabled C row, the instruction-assisted path is
78.9x/82.9x faster for absorb and 104.9x/116.2x for squeeze (168/136 B).
Against Clang RV64GC it is 114.5x/128.5x and 157.1x/172.7x respectively.
Zbb supplies most of the compiler-generated C improvement; enabling vector
code does not give a consistent additional gain on this source and core.

All six software rows and the instruction-assisted path were rerun after the
mask-summary pipeline, integer lane-control capture, lane-FPU request stage,
balanced VLSU active-range trees and scalar arithmetic elaboration gating.
The measurements include final posted-store-response retirement.

## What "vector-enabled" means here

The software source is the portable permutation in
`../karudeb/tools/pqc/mlkem/keccak.c` (the `VK_KECCAK=0` branch), not the custom
instruction wrapper. The benchmark copy removes the instrumentation counter
and marks the permutation always-inline. Each absorb/squeeze worker has one
local state array and one block loop, so there is no function boundary forcing
a state round trip between permutations. Auto-vectorization is enabled at `-O3`.

Nevertheless, inspection shows the normal-cost GCC and Clang builds retain a
scalar permutation and materialize/spill state. Vector instructions primarily
serve transfer/XOR/setup code. These are **not register-resident RVV software
permutations**, nor bounds on optimized handwritten/intrinsic RVV or multi-state
batched throughput. A genuinely resident software-RVV implementation remains a
separate benchmark to construct; compiler flags/inlining alone did not produce it.

The instruction-assisted row does keep the state in v0-v7 across consecutive
absorb/squeeze blocks. Its maintained `keccak_sponge.c` test checks SHAKE128/256
known answers after multiple input/output blocks, at all byte alignments 0–15
and across page boundaries. There is no per-permutation state load/store wrapper
in that row. Internal VRF reload/writeback costs are included.

## Functional validation and reproducibility

All six tabled C builds pass:

- SHAKE128 and SHAKE256 known answers derived independently from Python hashlib;
- all 25 final state words after each 16-block absorb/squeeze run;
- every word of every squeezed output block, checked outside timing;
- the same ELF checks on Spike and Karu (Spike cycle outputs are not used here).

The full-output checker is separately compiled without LTO, preventing unused
output stores or state words from being optimized away. Expected complete states
and output streams are generated on the host from the portable C implementation;
the separate hashlib checks anchor the algorithm independently.

Build and check all six C rows, the hardware benchmark and resident-state KAT:

```sh
make -j4 keccak-compare XCHAIN=riscv64-unknown-linux-gnu-
```

See the [harness README](../test/keccak-sw/README.md) for prerequisites, individual
targets and compiler overrides. Logs, manifests, disassembly and compiler reports
are generated under `_build/keccak-sw/`. Results depend on compiler version,
code layout and RTL; the table records the versions below, not a promise that
another toolchain will produce identical cycles.

Compiler options: `-O3 -mabi=lp64d -mcmodel=medany -ffreestanding -fno-builtin`;
ISA `rv64gc`, `rv64gc_zbb`, or `rv64gcv_zbb_zvbb_zvl256b`.
Vector-length options: GCC `-mrvv-vector-bits=zvl`; Clang
`-mrvv-vector-bits=256`. The loop stays rolled across blocks to allow state
register allocation across permutations. Support/check code uses RV64GC and
is outside the measured interval.

GCC: 16.1.0 (`g6afcc4f6d`). Clang: 22.1.8, LLVM commit
`ca7933e47d3a3451d81e72ac174dcb5aa28b59d1`.
Karu RTL: `397a03b` plus the mask-summary, lane-boundary, VLSU-tree and scalar
arithmetic elaboration and throughput changes described in
[keccak-throughput.md](keccak-throughput.md).
Portable source SHA256:
`3dd74d379a3cb9cfe02a30d128e0baf35af070ef6da84ed5c8898f605a5983cd`.

The pinned permutation, harness, checker and stream fixtures are maintained in
`test/keccak-sw/`; hardware and software tests share `test/fw/shake_kat.h`.
No companion checkout is needed. Fixture generators verify the pinned expected
values during the build.
