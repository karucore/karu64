# Checked Keccak software comparison

Compare single-stream SHAKE128 (168-byte rate) and SHAKE256 (136-byte rate)
absorb/squeeze with plain RV64GC, RV64GC+Zbb, and vector-enabled
RV64GCV+Zbb+Zvbb C. [Recorded numbers and limitations](../../doc/keccak-software-comparison.md)
include the register-resident instruction-assisted hardware path.

## Reproduce

From the repository root, put the cross tools on PATH, then run:

```sh
make -j4 keccak-compare XCHAIN=riscv64-unknown-linux-gnu-
```

Prerequisites: Verilator and its C++ build tools, GNU Make, Bash, a host C
compiler, Python 3 (hashlib), `hexdump`, `sha256sum`, RISC-V GNU GCC/binutils,
Clang with a RISC-V backend, and Spike supporting Zvbb. Recorded versions:
GCC 16.1.0; Clang 22.1.8 (`ca7933e47d3a3451d81e72ac174dcb5aa28b59d1`).
The vector rows require support for `zvbb` and the vector-length compiler flags.
No karudeb checkout or C runtime/sysroot libraries are required.

Individual targets:

| Target | Purpose |
|---|---|
| `keccak-sw-build` | Check generated fixtures and build all six C variants |
| `keccak-sw-test` | Build and run all six on ideal-memory FPGA-geometry Verilator |
| `keccak-sw-test-spike` | Build and run identical ELFs on Spike for correctness only |
| `keccak-bench` | Register-resident instruction-assisted rate/component cycles |
| `keccak-sponge-test` | Multi-block resident-state SHAKE KAT, alignments and canaries |
| `keccak-compare` | All software checks plus both hardware targets |

`SW_GCC`, `SW_CLANG`, `SW_OBJCOPY`, `SW_OBJDUMP`, `SW_SYSROOT`, `SPIKE`,
`HOST_CC` and `PYTHON` are environment overrides. `SW_COMPILERS='gcc clang'`
and `SW_ROWS='gc zbb vec'` select the rows (defaults shown). For example:

```sh
SW_COMPILERS=clang SW_ROWS=vec make keccak-sw-test
```

The software cross compiler defaults independently of Make's `XCHAIN`;
`XCHAIN` selects the existing hardware firmware toolchain. `run.sh` accepts
`build`, `run` or `spike`; direct runs can override `OUT` and `SIMV`.
Artifacts go to `_build/keccak-sw/`: `manifest.txt`, simulator-hash and Spike
run manifests, six ELFs/binaries/hex files, compile commands/diagnostics,
disassembly, Verilator logs and Spike logs.
Build failures and functional failures fail the target. Compiler versions and
code layout can change cycles; inspect the generated code before interpreting
a vector-enabled row as a vectorized permutation.

## Measurement and functional contract

Each worker has one local 25-word state and a rolled 16-block loop with an
always-inlined portable permutation. No call boundary requires a state spill
between blocks. Absorb warms the input, then times load/XOR/permutation;
squeeze times store/permutation, including the last permutation for a
steady-state schedule. Initialization, padding, checks and printing are outside
the interval. Both rate loops check every final state word and every output
word through a separately compiled checker, without LTO. The extra permutation
probe observes only one final word and is not used in the rate comparison.

`keccak_sw_inline.h` pins the portable `VK_KECCAK=0` branch of karudeb's
Keccak implementation (source hash in the header); only instrumentation removal
and always-inlining were applied. `sw_expected_gen.c` regenerates full stream
fixtures using host C. `gen_kat.py` independently regenerates hashlib SHAKE
answers for three message blocks plus padding and three output blocks. The
SHAKE answers live in `test/fw/shake_kat.h`, shared with the hardware sponge
test. Every build compares both generated fixtures with the checked-in headers.

Normal-cost GCC/Clang autovectorization does **not** keep the permutation in
vector registers on this source: the permutation remains scalar with spills;
vectors chiefly help transfers/XOR/setup. This is a compiler-generated C
baseline, not optimized resident RVV software. The instruction-assisted
hardware benchmark and `test/fw/keccak_sponge.c` **do** retain state in v0–v7
between blocks, and functionally check multi-block absorb and squeeze.

Both run on the same ideal-memory core geometry. Verilator retains cache,
VRF and AXI protocol costs; it injects no DDR or instruction-fetch delay.
Vector arithmetic uses mul16/div64 with the FPGA lane/writeback stages;
scalar arithmetic retains `SIM_TB` mul1/div1 defaults, not the board's
mul4/div64 settings. Both software and instruction-assisted rows share these
settings.
Spike validates results only; its cycle counter is not a performance oracle.
