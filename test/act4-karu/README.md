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
- `karu64-rv64gc/` — the DUT config (RV64GC, M-mode):
  - `test_config.yaml` — names the compiler / objdump / `sail_riscv_sim`
  - `karu64-rv64gc.yaml` — UDB config: the authoritative extension/param
    set ACT4 uses to select tests and configure Sail
  - `rvtest_config.h` — C mirror of the caps for the test preamble
  - `rvmodel_macros.h` — DUT halt + console, mapped to karu64's HTIF
    protocol (single `sd` + poll-for-zero, race-free against the
    testbench's every-cycle `tohost` watcher)
  - `link.ld` — memory map (RAM at `0x80000000`)
  - `sail.json` — Sail reference config (verbatim from the vetted
    `sail-RVI20U64`; RV64GC M-mode, V Disabled)
- `env.sh` — puts the `udb`/`bundle` gems on PATH + sets `GEM_HOME`
- `Makefile` — `tests` / `run` / `all` / `clean` / `distclean`
- `../../flow/run_act.sh` — runs ELF(s) on karu64 and classifies PASS/FAIL

## Usage

    make -C test/act4-karu tests EXT=I      # generate the I-slice ELFs (Sail)
    make -C test/act4-karu run              # run them on karu64
    make -C test/act4-karu all              # both

`EXT` selects a slice (`I`, `M`, `Zba`, … and later `Vls*` etc.); blank
generates everything the config declares. The 4 MiB `_build/Vhtif_fp`
verilator testbench is reused as the run harness (ACT4 ELFs exceed the
128 KiB default RAM).

## Status (2026-05-24)

Full scalar RV64GC sweep: **347/347 PASS** — fully conformant. (Progression:
213 → 215 with the `Zalrsc` SC fix → +F/D subnormals → +fused FMA = all
green. F slice 82/82, D slice 114/114.) The flow itself is validated
with no new RTL; it also fixed a false-positive in the `karu_assert.v`
livelock guard (keyed off register-writeback retire, which a long arch-test
NOP sled never triggers — now keyed off forward progress).

**PASS:** I (51), M (13), Zaamo (18), Zalrsc lr (2), Zca (32), Zcd (4),
Misalign+D+F+Zca (20), Zicsr (6), Zicntr (2), Zifencei (1), and all FP
data-movement ops (D 47, F 17: fld/fsd/flw/fsw, fsgnj*, fmin/fmax,
feq/flt/fle, fclass, fmv).

**FAIL — three families:**
> **Update:** full IEEE-754 subnormal support implemented for **both F and
> D** (`karu_f{add,mul,div,sqrt,cvt}` and the `_d` units): subnormal inputs
> (leading-bit + effective exponent), gradual-underflow subnormal outputs,
> and exact NX/UF flags (tininess-after-rounding, SoftFloat rule). Validated
> to **0 errors against Berkeley TestFloat** (46k vectors/op × all 5 rounding
> modes) on f32/f64 {add,sub,mul,div,sqrt} + every int↔float and S↔D
> conversion; riscv-tests 110/110; ACT4 **F 27→42/82, D 47→74/114**. The
> *only* remaining F/D-arith fails are the FMA ops (composed vs fused — a
> separate gap, see below).

1. **FP arithmetic:** add/sub/mul/div/sqrt/cvt **done (F+D, subnormals)**;
   FMA **done (F+D, fused single-rounding** — `karu_ffma`/`karu_ffma_d`,
   ported from SoftFloat mulAdd). **ACT4 F 82/82, D 114/114.**
   Confirmed (not assumed) via commit-log diff vs spike: the first F-fadd.s
   divergence is `fadd.s f28,f6,f7` with `f6=0x878bc661` (small normal) and
   `f7=0x006cdb29` (**subnormal**, exp=0). spike → `0x878bc4ae` + `fflags=NX`;
   karu64 flushes the subnormal `f7` to zero and returns `f6` unchanged
   (`0x878bc661`). This is karu64's documented FTZ-on-input behavior. ACT4
   also signature-checks `fflags` (`RVTEST_SIGUPD_F`), so subnormal-input
   cases mismatch on result and/or flag. (rv64uf/ud pass only because they
   don't exercise subnormals.) Closing this = real IEEE-754 work: subnormal
   inputs (karu_fmul already normalizes them; fadd/fdiv/fsqrt/fcvt/D-units
   don't), gradual-underflow subnormal outputs, exact NX/UF flags, and
   single-rounding fused FMA. Validate with Berkeley TestFloat, not just ACT4.
2. **Zalrsc sc.w / sc.d — FIXED (now PASS).** Root cause: the
   `cp_custom_sc_after_store_*` coverpoint does `lr; sb (same set); sc` and
   expects the SC to succeed (the reference keeps the reservation through a
   same-hart store). karu64's LSU cleared the reservation on *any* store, so
   the intervening `sb` killed it and the SC failed. Per spec a same-hart
   plain store must not invalidate the reservation (only an SC/AMO consumes
   it; a single-hart core has no other-hart store). Fixed in `karu_lsu.v`
   (clear `reserve_valid` only on the SC store, not plain stores). All 110
   riscv-tests (incl. rv64ua-p-lrsc) still pass.
3. **minstret undercount** (karu64's `perf_retire` only pulses on register
   writeback, so NOPs/stores/untaken-branches aren't counted) did NOT cause
   failures here — Zicntr passed. Stays a deferred cleanup.

## Scope / next

The config is RV64GC today. Vector (`V` / `Zve*` / `Zvl*`) extensions get
flipped on in the UDB + sail configs as the RVV RTL lands; see
`../../doc/architecture.md`. Vector test `.S` sources additionally require a
one-time `vector-sources` generation step (see the framework Makefile).
