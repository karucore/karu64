# Changelog

All notable changes to `karu64`. Format follows
[Keep a Changelog](https://keepachangelog.com/); the repository has no tags
yet, so the first section is the pending release from `dev-mjos`, and the
second describes the state of `main` it builds on.

## [Unreleased] — `dev-mjos` (2026-09-10 … 2026-09-11)

### Changed — `vkeccak` now implements the Zvknhk specification (breaking)

- The Keccak instruction follows the draft **Zvknhk** Vector Keccak extension
  of the RISC-V PQC TG, [riscv/riscv-pqc](https://github.com/riscv/riscv-pqc)
  `src/zvknhk.adoc` (commit `260e14b`), and is binary-compatible with that
  repository's Spike and QEMU reference models:
  `vkeccak.vi vd, imm5` = `.insn r 0x77, 0x2, 0x53, vd, x18, imm5`
  (MATCH `0xa6092077`, MASK `0xfe0ff07f`). `imm5=0` runs Keccak-p[1600,24]
  (SHA-3/SHAKE), `imm5=1` runs Keccak-p[1600,12] with round constants
  RC[12..23] (TurboSHAKE/KangarooTwelve); all other values are reserved.
- Operand semantics per the spec: one fixed 2048-bit element group at `vd`
  (`NREG = ceil(2048/VLEN)` registers, 8 at VLEN=256), independent of `vl`
  (including `vl=0`) and LMUL; elements 25..31 (the state tail) and all other
  registers are untouched.
- Reserved encodings raise an illegal-instruction trap at issue with no side
  effects: `SEW≠64`, `imm5>1`, `vm=0`, `vd` not NREG-aligned, `vstart≠0`.
- **Breaking:** the previous keccak-xrv form (`.insn r 0x77,0x2,0x53,vd,x17,x24`,
  fixed 24 rounds) is no longer decoded and traps. Software must use the new
  encoding; `../karudeb` was updated in step.
  (`rtl/karu_dec.v`, `rtl/zvk/keccak.v`, `rtl/karu_varith.v`, `rtl/karu64.v`)

### Added

- `make keccak-kat`: standalone `keccak.v` known-answer test with the spec's
  KECCAK-P (24-round) and KECCAK-P12 (12-round) vectors (`test/zvk/tb_keccak_kat.sv`).
- `make keccak-test` / `make keccak-test-zvk`: full-core `vkeccak.vi` test on
  the `KARU_KECCAK` and the shipping `KARU_ZVK KARU_KECCAK` builds — spec KATs,
  two dependent ops back to back, fixed-group / state-tail / `vl` / LMUL rules,
  and 11 reserved-encoding trap cases with a no-side-effect check
  (`test/fw/keccak_subj.c`). The decode bench covers the new encoding and the
  trapping of the old word.
- `CHANGELOG.md` (this file).

### Fixed

- `rtl/karu_varith.v`: the `vfslide1up/down` source index used `/ epr` and
  `% epr` with a runtime divisor, which synthesised a 32-bit divider; now a
  shift and mask (`epr` is a power of two). No functional change
  (`make vfp-test` 46/46; Vivado elaboration clean).
- Makefile: the `Vhtif_kec` / `Vhtif_zvk_kec` Verilator rules did not create
  their output directories and failed in a clean checkout.
- `flow/syn` (Yosys + OpenSTA estimate flow), previously unusable here:
  liberty lookup only searched inside the checkout; OpenSTA 2.4 rejected
  `-group_path_count` so every timing report was empty; `KARU_LTP=1` ran `ltp`
  on the mapped netlist and produced a multi-GB false-loop report; the fast
  ABC script skips buffering/sizing so STA slack was meaningless (thousands of
  ns on one unbuffered inverter). Timing runs now use the full ABC script, the
  depth report runs pre-map with the top/cache modules excluded, and the
  scripts adapt to the OpenSTA version. Re-measured RV64GC core-only numbers
  are in `flow/syn/README.md` (398 kGE, ~6.7 ns critical path through the Zfa
  `fround.d` compose in NanGate45 typical).

### Documentation

- `README.md`, `doc/architecture.md`, `doc/flows.md`, `rtl/zvk/README.md`:
  Zvknhk encoding/semantics, the spec location and commit, the new test
  targets; "custom/experimental Keccak" wording removed.
- `flow/syn/README.md`: flow status, corrected tunables, re-measured timing
  and the note that RV64GCV rows need a ≥64 GB host.

### Hardware status

- VCU118 vec ROM bitstream rebuilt from `48e4d86` with Vivado 2026.1
  (`ddr_vec_sgmii_75_rom`, WNS +0.045 ns at 75 MHz, DRC clean; ROM = fu-boot +
  OpenSBI v1.8.1 + U-Boot 2025.01 + zvk-ddr DTB), programmed and booted to a
  Debian NFS-root shell on the lab board (2026-09-11).
- Known: Linux `reboot` cannot restart the board (OpenSBI reports no reboot
  device); use the CPU_RESET / centre button or re-program. After a warm
  button reset, U-Boot's TFTP occasionally hits its retry limit and the baked
  bootcmd (`;`-chained) still runs `booti` on a partial image; a cold boot after
  programming has been clean every time.

## [main @ `8da799a`] — 2026-06-21 … 2026-06-29

Initial public tree (`73b4906 init`, 2026-06-21) and June follow-ups:

- RV64GCV core (RV64IMAFDCV + Zicsr/Zifencei, RVV 1.0, Zvl256b), M/S/U with
  Sv39, CLINT/PLIC/NS16550; `make test` 110/110; generated RV64GCV ACT4
  2220 PASS / 0 FAIL.
- Zvk vector crypto (Zvkned, Zvknha/b, Zvksed, Zvksh, Zvkg, Zvkb) behind
  `KARU_ZVK*`; Keccak-f[1600] permutation instruction behind `KARU_KECCAK`
  (pre-Zvknhk keccak-xrv encoding, replaced above).
- VCU118 SoC: BRAM and DDR4 (MIG) variants, LiteEth SGMII netboot, hands-off
  boot ROM (fu-boot + OpenSBI + U-Boot + DTB); Debian NFS-root Linux with
  kernel 7.1.2 boots from the bitstream built with Vivado 2026.1.
- Verilog-2001 audit for Genus/Vivado, explicit memory leaf modules, Yosys /
  OpenSTA NanGate45 estimate flow and area matrix, Marian-derived Zvk leaf
  cores with KATs.
