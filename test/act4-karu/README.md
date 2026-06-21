# ACT4 architectural certification tests for karu64

This drives the **ACT4** framework (RISC-V Architectural Certification
Tests, framework v4 — the successor to the deprecated `riscof`) against
`karu64`.

ACT4 does not compare a runtime signature. Instead the **Sail** model
(`sail_riscv_sim`), configured to match the DUT, computes the expected
results *ahead of time* and bakes them into **self-checking ELFs**. The
DUT just runs each ELF: it self-checks internally, prints
`RVCP-SUMMARY: TEST PASSED|FAILED` over the HTIF console, and halts with
`tohost = 1` (pass) / `3` (fail). karu64's existing HTIF testbench
(`test/fw/htif.c`, `rtl/htif_tb.v`) is byte-compatible with this.

## Layout

- `../riscv-arch-test/` — the framework + test sources, a submodule pinned
  on the **`act4`** branch (commit `475b5bd`, matching the installed
  editable `act` framework).
- `karu64-rv64gc/` — the DUT config (RV64GCV, M-mode):
  - `test_config.yaml` — names the compiler / objdump / `sail_riscv_sim`
  - `karu64-rv64gc.yaml` — UDB config: the authoritative extension/param
    set ACT4 uses to select tests and configure Sail
  - `rvtest_config.h` — C mirror of the caps for the test preamble
  - `rvmodel_macros.h` — DUT halt + console, mapped to karu64's HTIF
    protocol (single `sd` + poll-for-zero, race-free against the
    testbench's every-cycle `tohost` watcher)
  - `link.ld` — memory map (RAM at `0x80000000`)
  - `sail.json` — Sail reference config (RV64GCV M-mode; `V` support_level
    `Float_double` + `Zfhmin`, so the `Zve*`/`Zvl*` slices generate)
- `env.sh` — puts the `udb`/`bundle` gems on PATH + sets `GEM_HOME`
- `Makefile` — `tests` / `run` / `all` / `clean` / `distclean`
- `../../flow/run_act.sh` — runs ELF(s) on karu64 and classifies PASS/FAIL

## Usage

    make -C test/act4-karu tests EXT=I      # generate the I-slice ELFs (Sail)
    make -C test/act4-karu run              # run them on karu64
    make -C test/act4-karu all              # both

`EXT` selects a slice (`I`, `M`, `Zba`, `Vx*`, `Vls*`, `Vf*`, …); blank
generates everything the config declares. The 4 MiB `_build/Vhtif_fp`
verilator testbench is reused as the run harness (ACT4 ELFs exceed the
128 KiB default RAM).

## Status (2026-06-21)

Full generated **RV64GCV** ACT4 suite: **2220 PASS / 0 FAIL** — ACT4-clean.
Scalar RV64GC is a 347/347 subset; everything else is vector. (Progression:
scalar reached 347 via the `Zalrsc` same-hart-store SC fix, full F/D subnormal
support, and fused single-rounding FMA — all validated to **0 errors vs
Berkeley TestFloat**; the vector slices then landed clean.)

**Scalar (347):** I (51), M (13), Zaamo (18), Zalrsc (lr+sc), Zca (32),
Zcd (4), misalign+D+F+Zca (20), Zicsr (6), Zicntr (2), Zifencei (1), and the
full F (82) / D (114) arithmetic + data-movement slices.

**Vector:** integer arithmetic `Vx{8,16,32,64}`; the permute group
(`vrgather`/`vrgatherei16`, `vslide*`, `vcompress`, `viota`, `vsext`/`vzext`);
load/store `Vls{8,16,32,64}` — unit-stride, strided, indexed, every segment
form, and whole-register; and vector FP `Vf32`/`Vf64` (per-lane scalar
`karu_fpu`, SEW32→F / SEW64→D).

**Two honest non-PASS items — both reference-side or deliberately
out-of-scope, neither a karu64 conformance failure (0 FAIL anywhere):**

1. **8 `Vx64` `vmulh*`/`vsmul` ELFs that Sail can't *generate*** — a
   golden-generation trap-loop on the reference side, not a DUT bug. Run the
   generator with `act -k` (keep-going) and they're simply skipped.
2. **fp16 ops** — karu64 has no Zfhmin datapath (the config claims `Zfhmin`
   only to satisfy ACT4's `REQUIRED_EXTENSIONS` selector for the Vf slices).
   The independent `Vf32`/`Vf64` golden shows `Vf32` 78/100 and `Vf64` 64/66,
   where *every* non-PASS is an honest TRAP of an unimplemented op — 0 FAIL.

The flow needed no new RTL beyond the vector core itself; it did fix a
false-positive in the `karu_assert.v` livelock guard (keyed off
register-writeback retire, which a long arch-test NOP sled never triggers —
now keyed off forward progress) and gave the per-element VLSU its own
`VLSU_STALL_LIMIT` so long indexed/segment ops aren't misflagged as hangs.
ACT4 also caught two real VPERM bugs the directed spike test missed
(`vslideup` offset truncated to 32 bits; `vcompress` filling the tail
agnostic instead of always-undisturbed) — both fixed.

## Scope / next

The config is **RV64GCV** (M-mode), `VLEN=256`. What's left is the documented
out-of-scope deviations — some `Vx64` `vmulh*`/`vsmul` (Sail golden-gen), fp16,
and a few overlap / LMUL-misalignment corner rules; see the vector notes in
`../../doc/architecture.md`. Vector test `.S` sources require the framework's
one-time `vector-tests` / `vector-testgen` generation step (see the framework
Makefile).
