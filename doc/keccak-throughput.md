# Keccak / SHAKE ideal-memory throughput

The maintained tables were reproduced after the Keccak transport,
access-fault, lane-pipeline and active-range changes. They measure the
ideal-memory simulator configuration described below; no board/DDR rate is
inferred from these results or from synthesis.
Reproduce the measurements with:

```sh
make -j4 keccak-bench XCHAIN=riscv64-unknown-linux-gnu-
make -j4 keccak-sponge-test XCHAIN=riscv64-unknown-linux-gnu-
make mem-stream-test axi-bram-burst-test vrf-bram-test
```

The benchmark uses Verilator's HTIF RAM with no injected AW/AR or instruction
fetch delay. It retains the core's cache, VRF and AXI protocol costs.
The data L1 is enabled; the optional instruction cache is disabled in this
simulation. Vector geometry matches the FPGA: VLEN=256, two 64-bit lanes,
`KARU_ZVK KARU_KECCAK KARU_V_LANE_PIPE KARU_V_CWB_STAGE`,
`KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64`. These are core-cycle
measurements, not board/DDR measurements or timing-closure evidence.
Scalar arithmetic retains the `SIM_TB` defaults (mul/div=1), unlike the
board target's mul4/div64; "FPGA geometry" refers to the vector structure.

## Rate-block results

For the six compiler-generated software baselines (RV64GC, +Zbb, +V/Zvbb),
see [the software comparison](keccak-software-comparison.md). `make keccak-compare`
reproduces those rows with full-output checks and both hardware targets.

| Operation | Rate | Before cycles/block | After cycles/block | Cycle reduction |
|---|---:|---:|---:|---:|
| SHAKE128 absorb | 168 B | 366.75 | 221.75 | 39.5% |
| SHAKE256 absorb (also SHA3-256 rate) | 136 B | 358.75 | 197.75 | 44.9% |
| SHAKE128 squeeze | 168 B | 291.88 | 156.88 | 46.3% |
| SHAKE256 squeeze | 136 B | 273.56 | 144.56 | 47.2% |

Squeeze costs two more cycles per block than the initial 154.88/142.56 result:
the store instruction now waits for the final B response before retiring, so
a late AXI error can trap against the correct instruction. Absorb and resident
permutation costs are unchanged.

The state stays in v0–v7. Absorb loads a rate block to v8–v15, XORs it into
the state, and permutes. Squeeze stores a rate block and permutes for the
next block. Each result averages 16 unrolled iterations; pointer updates
and amortized counter/fetch overhead are included. Absorb input is warmed
in the L1 before timing. State setup/spill, padding and printing are outside
the interval. A finite N-block squeeze needs N−1 permutations; this benchmark
retains the final permutation to measure a steady-state step.

Individual component measurements include their own counter/fetch overhead
and therefore should not be added as exact instruction costs:

| Component | Before | After |
|---|---:|---:|
| Resident 24-round permutation | 135.06 | 79.06 |
| Resident 12-round permutation | 123.38 | 67.38 |
| 168 B load | 115.25 | 62.25 |
| 136 B load | 112.56 | 57.56 |
| 168 B XOR | 114.06 | 78.06 |
| 136 B XOR | 114.38 | 64.38 |
| 168 B store | 159.38 | 80.38 |
| 136 B store | 141.38 | 68.38 |

The secondary 200-byte load–permute–store wrapper falls from 428.06 to
234.06 cycles (without a per-iteration vset).

## Implemented changes

- Keccak reload uses both VRF BRAM ports, fetching a whole 256-bit register
  per fill. It still reloads the fixed group and preserves the seven tail
  lanes; no coherent shadow state was introduced.
- Adapter demand fills launch their synchronous reads immediately when no
  write must first drain. Captured writes retain the existing replay
  suppression and read-before-write ordering.
- Element-local lane walks stop at the last live granule. Whole-register
  moves, fixed-group crypto and other engines retain their own bounds.
- Contiguous loads write exact byte enables, avoiding the old-vd snapshot.
  Contiguous stores snapshot only the active interval, at one granule per
  cycle after priming the synchronous read.
- Cacheable 128-bit stores use a two-beat INCR burst, with empty halves
  omitted. Device/boot/uncacheable accesses keep single-beat transactions.
  The HTIF RAM and synthesizable FPGA BRAM backend now accept write bursts.
- A waiting vector-granule slot overlaps VLSU preparation with the active
  write. Cacheable stores acknowledge into the active slot before B.
  Reads and device accesses wait behind B; the core drains all buffered
  writes before issuing the next instruction or taking an interrupt.
  Thus FENCE, AMO, cache maintenance and MMIO are conservatively ordered.

There is still one outstanding AXI write transaction. A crossbar change for
multiple outstanding writes, adapter prefetch and a coherent Keccak shadow
remain possible follow-ups; these results do not assume their benefits.

## Validation and limits

`keccak_sponge.c` checks complete SHAKE128 and SHAKE256 outputs against
independent Python `hashlib` known answers: three full message blocks plus
padding, and three full output blocks. Both rates pass at every byte alignment
0–15, across a 4-KiB boundary, with surrounding output canaries. The same
checks also pass with `+ddr_stall=19` as backpressure stress; the performance
table above uses only ideal memory.

`make keccak-sponge-pbmt-test` reuses this same resident-state KAT with NC and
IO mappings for its input/output buffers. Both rates pass all 16 alignments
and page crossings. The integrated observer checks translated attributes,
cache bypass, completion ordering and the exact active-byte IO footprint;
the IO run covers 34,048 vector bytes over 2,338 vector requests. Only the
data buffers receive the altered attributes: page tables, stack and HTIF
remain PMA, and attribute transitions use the required fence/`cbo.flush`/
fence sequence. Test page tables use a guarded, optional NOLOAD section;
the normal sponge binary and the timed benchmark are unchanged. These are
functional tests, not NC/IO cycles-per-block measurements.

The transport unit test checks independent AW/W stalls, delayed B, AWLEN/WLAST,
partial halves, queued-store/read ordering, cache-hit updates, uncacheable
single beats and reporting of delayed posted-write errors. `make access-test`
checks architectural causes/tval/vstart, fault-only-first trimming, errored
refills and cancellation of a queued store suffix, including an Sv39 alias.
The BRAM backend test
checks separated AW/W, retained addresses, burst data and B/R backpressure,
including a CLINT register write/read.

Spike and Karu pass the expanded 41-case Zvbb and 71-case reserved-encoding
suites. Directed integer/vector-memory/permute/vector-FP/Zvfhmin/Zvkb tests
pass in both default and FPGA pipeline configurations. Keccak and standard
Zvk tests, vector/scalar MMU, cross-page, cache operations, VRF assertions and
scalar/vector lint pass. Matched-profile ACT4 validation is recorded
separately in [the ACT4 instructions](../test/act4-karu/README.md); it does
not replace the measurement scope of the throughput numbers above.

Follow-up review corrected the FP min/max reduction and prefix-mask `v0`
legality exceptions. `make vwalk-test vwalk-test-ship vwalk-test-spike` now
checks all 22 supported SEW/LMUL combinations at and around granule/register
boundaries, including masks, aliasing and full undisturbed tails. All 3400
cases pass on Spike and both Karu configurations: 1312 arithmetic-result
checks and 2088 permitted nonzero-vstart trap checks. New assertions enforce
the one-unacknowledged-request VLSU contract and the two-granule lane geometry.
The ideal-memory benchmark was rerun after the access-fault fixes; the updated
rate-block results are above. Remaining permissive legality gaps are listed
explicitly in this document's optimization and validation sections.

The maintained [area matrix](../flow/syn/AREA_MATRIX.md) records complete
feature configurations. The VRF adapter also passes standalone Yosys
synthesis/check. No new
operand-data-dependent loop or state transition was introduced. Control
depends on vector shape, mask, addresses, port conflicts and handshakes.

Full-core area/timing and FPGA status are kept in the
[release diagnostics](release-diagnostics-2026-09-14.md). They do not
remeasure these throughput tables.
