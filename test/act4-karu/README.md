# ACT4 architectural tests

This directory drives the ACT4 framework in `../riscv-arch-test` against
Karu. Sail computes expected results while generating self-checking ELFs; the
Karu HTIF simulator executes those ELFs and `flow/run_act.sh` classifies their
exit status and `RVCP-SUMMARY` marker. Reference generation and DUT execution
are separate results.

## Configurations

| `CONFIG_NAME` | Purpose | Simulator |
| --- | --- | --- |
| `karu64-rv64gc` | M-mode RV64GCV baseline | `_build/Vhtif_fp/Vhtif_tb` |
| `karu64-sv39` | S/U privileged-1.13 and Sv39 development | `_build/Vhtif_fp/Vhtif_tb` |
| `karu64-h` | H/VS/G development | `_build/Vhtif_h/Vhtif_tb` |
| `karu64-rva23s64` | mandatory profile composition | `_build/Vhtif_rva23s64/Vhtif_tb` |
| `karu64-rva23s64-smcntrpmf` | profile plus optional Smcntrpmf; shipping reference | `_build/Vhtif_rva23s64_smcntrpmf/Vhtif_tb` |

Non-default configurations are assembled under `_build/act-config`. Generated
ELFs are isolated by configuration below
`test/riscv-arch-test/work/<CONFIG_NAME>/elfs`; run logs and verdicts go to
`_build/act-work-*`. Do not add a hand-written `rvtest_config.h`: ACT4 creates
the capability header from the selected UDB configuration.

The profile simulator includes real CLINT timer/software inputs and independent
machine/supervisor external inputs through `HTIF_TB_CLINT` and
`HTIF_TB_EXTIRQ`. The profile platform uses a 1000-cycle "soon" timer delay so
Zawrs S/U tests cannot consume their one-shot interrupt before entering the
wait. Do not replay profile ELFs on an older RAM-only simulator.

## Dependencies

The maintained setup uses:

- the `test/riscv-arch-test` submodule at the recorded branch tip;
- the `act` framework and its test/coverage generators in a Python virtualenv;
- Ruby 3.2 or newer and Bundler for UDB;
- GCC 15 or newer (or Clang 20 or newer) RISC-V ELF tools; and
- the configuration's pinned Sail model.

One working installation is:

```sh
python3 -m venv ~/act-venv
~/act-venv/bin/pip install -e test/riscv-arch-test/framework \
  -e test/riscv-arch-test/generators/testgen \
  -e test/riscv-arch-test/generators/coverage
ln -sfn /usr/bin/bundle3.3 ~/.local/bin/bundle
bundle config set --global path ~/.local/share/bundler-act
```

Expose `riscv64-unknown-elf-gcc`, `objdump`, `nm` and `objcopy` in `PATH`.
The vector sources are generated once per ACT4 checkout:

```sh
. ~/act-venv/bin/activate
export PATH=$HOME/.local/bin:$HOME/rv/riscv/bin:$PATH
make -C test/act4-karu apply-patches
make -C test/riscv-arch-test vector-tests
make -C test/riscv-arch-test testgen
```

`apply-patches` applies all eight parent-repository patches without fuzz and
rejects an unexpected submodule tree. They repair ACT4/UDB harness and
generator behavior; they do not change Sail instruction semantics:

- `h-capability.patch`
- `h-trap-harness.patch`
- `priv-epc-origin.patch`
- `priv-irq-wfi.patch`
- `priv-trap-lifecycle.patch`
- `ref-model-version.patch`
- `sm-counter-wrap.patch`
- `udb-geilen-zero.patch`

These patches are local dependency maintenance, not an upstream endorsement.
The WFI patch records Karu's permitted policy that host U-mode WFI is illegal.

The H/profile reference is an isolated Sail 0.14 source snapshot built with the
Sail 0.20.2 compiler and the four corrections documented in
[`test/sail-karu`](../sail-karu/README.md). Build it without modifying the
shared checkout:

```sh
JOBS=4 bash test/sail-karu/build.sh /path/to/sail-riscv _build/sail-karu \
  -DSAIL_BIN=/path/to/sail-0.20.2/bin/sail
```

Use the executable path printed by the helper as `REF_MODEL_EXE`.

## Generate and run

The release-profile sequence is:

```sh
. ~/act-venv/bin/activate
export PATH=$HOME/.local/bin:$HOME/rv/riscv/bin:$PATH

make -C test/act4-karu test-profile-config \
  CONFIG_NAME=karu64-rva23s64-smcntrpmf
make -C test/act4-karu tests \
  CONFIG_NAME=karu64-rva23s64-smcntrpmf \
  REF_MODEL_EXE=/path/to/corrected/sail_riscv_sim \
  JOBS=4 ACT_FLAGS='--debug --keep-going'

# Force a rebuild after every RTL change; the runner only checks that it exists.
make -B -j4 rva23-sim \
  VERI_RVA23_DIR=_build/Vhtif_rva23s64_smcntrpmf \
  VFLAGS='-Irtl -DKARU_ICACHE -DKARU_ZVK -DKARU_KECCAK -DKARU_M_MUL_CYCLES=4 -DKARU_M_DIV_CYCLES=64 -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_SMCNTRPMF -DKARU_SSCOFPMF'
make -C test/act4-karu run \
  CONFIG_NAME=karu64-rva23s64-smcntrpmf JOBS=4
```

Blank `EXT` selects every slice declared by the config. A comma-separated
`EXT`, such as `EXT=I,M,Zicsr`, limits generation for diagnosis. `--fast`
omits disassembly only; it does not skip Sail execution or ELF self-checking.
Use `--keep-going` to distinguish independent reference-generation problems.

`flow/run_act.sh` defaults to 20,000,000 simulated cycles and a 300-second
wall-clock limit per ELF. Override `MAX_CYCLES` or `PER_TEST_TIMEOUT` only when
the retained command and reason are recorded. A timeout, trap, missing marker,
or reference-generation error is never a pass.

The focused configuration checks remain available without a full suite:

```sh
make -C test/act4-karu test-h-capability test-priv-trap-lifecycle \
  test-priv-epc-origin test-priv-irq-wfi
make -C test/act4-karu test-h-trap-harness CONFIG_NAME=karu64-h
make -C test/act4-karu test-profile-config \
  CONFIG_NAME=karu64-rva23s64-smcntrpmf
```

The profile CSR checker independently compares Sail and RTL. Its generated
config, corrected reference, simulator and output directory must all name the
same composition; add `--smcntrpmf` for the shipping reference.

## Evidence and interpretation

The latest exact-shipping replay passed 2872/2872 unique configured ELFs. It
regenerated the Sail 0.14 reference set for the current composition and
verified the ELF hashes after execution. The matched mandatory composition
also passed 2872/2872. Exact hashes and retained evidence are recorded in
[`doc/release-diagnostics-2026-09-14.md`](../../doc/release-diagnostics-2026-09-14.md).
Preserve the generated config and its manifest, reference executable hash,
reference ELF hashes, simulator hash, `results.tsv`, and failing logs if any.

The ACT4 selection does not cover the optional Zvk crypto leaves or custom
`vkeccak.vi`; their KAT, decode, Spike and full-core tests are documented in
[`rtl/zvk/README.md`](../../rtl/zvk/README.md). The pinned Sail model also has
no Shlcofideleg support, so shared guest LCOFI delegation is covered by Karu's
CSR/full-core PMU tests. ACT4 coverage is architectural evidence, not an ISA
certification, physical platform guarantee, Linux/KVM result, or security
assessment.
