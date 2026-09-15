# Isolated Sail reference corrections

This directory builds an isolated RISC-V Sail 0.14 reference at commit
`22fad389cb0ca92ef8f3cfff91fe258f14ee8de8` with four narrowly scoped
corrections used by the H/profile tests. It does not install or modify a shared
Sail binary, change karu64 RTL, or patch the Sail instruction semantics outside
the listed issues. The non-H ACT4 configuration remains pinned separately.

## Maintained patches

- `h-sgeie-delegation.patch` retains writable MIE/HIE.SGEIE with H and makes
  MIDELEG[12] read-only one, including GEILEN=0. HGEIE/HGEIP and SGEIP remain
  zero when no guest external interrupt files exist.
- `h-mideleg-reset.patch` applies H delegation legalization at reset, before
  the first MIDELEG write.
- `hpmevent-selector-mask.patch` adds the platform-defined
  `extensions.Zihpm.event_selector_mask` WARL parameter. Karu uses `0x1f`;
  omitted configuration preserves Sail's all-ones default.
- `virtual-fault-address.patch` prevents implemented physical-address width
  from truncating a valid virtual address reconstructed for `mtval`/`stval`
  after translation.

These patches model reference/platform issues only. PMP is enabled in selected
reference probes solely to bootstrap S/HS execution or create a deliberate
subaccess fault; this does not claim that karu64 implements PMP.

## Build

Prerequisites are a checkout at the pinned commit, Sail 0.20.2, CMake, Ninja,
a C/C++ compiler and GMP development headers. The helper exports committed
source into `_build`, applies patches without fuzz, verifies a manifest and
builds only `sail_riscv_sim`:

```sh
JOBS=4 bash test/sail-karu/build.sh ../src/sail-riscv _build/sail-karu \
  -DSAIL_BIN=/path/to/sail-0.20.2/bin/sail
```

The command prints the executable path. `SAIL_SMT_CACHE` may name a cache from
the same Sail compiler. The input checkout and shared installations remain
read-only; manifests, hashes and logs stay in the selected `_build` directory.

## Regressions

Materialize the H configuration and compare pristine and corrected references:

```sh
make -C test/act4-karu prepare-config CONFIG_NAME=karu64-h
make _build/karu_htimer_test.elf
python3 test/sail-karu/check.py \
  --pristine /path/to/pristine-0.14/sail_riscv_sim \
  --patched /path/to/corrected/sail_riscv_sim \
  --config _build/act-config/karu64-h/sail.json \
  --output _build/sail-karu-check-paired \
  --timer-elf _build/karu_htimer_test.elf
```

The 13 focused probes cover MIE/HIE aliases, GEILEN 0/1/63, H-disabled
controls, reset masks and HS/VS interrupt routing. The corrected model passes
all 13; pristine Sail is expected to fail only the five reset/routing cases.
Shlcofideleg is not implemented by this pinned model, so its RTL evidence comes
from the CSR/full-core PMU tests instead.

Run the event-selector matrix with:

```sh
python3 test/sail-karu/check_hpmevent.py \
  --pristine /path/to/pristine-0.14/sail_riscv_sim \
  --patched /path/to/corrected/sail_riscv_sim \
  --config _build/act-config/karu64-h/sail.json \
  --output _build/sail-karu-hpmevent-check
```

It checks 29 selectors, six CSR forms, nine configurations and schema negative
controls. The selector parameter does not model platform event signals; RTL
counter-increment behavior has separate firmware tests.

Run the virtual-fault-address comparison with identical ELFs on both models:

```sh
python3 test/sail-karu/check_vmem_tval.py \
  --before /path/to/pristine/sail_riscv_sim \
  --after /path/to/corrected/sail_riscv_sim \
  --config _build/act-config/karu64-h/sail.json \
  --output _build/sail-karu-vmem-check
```

The probes cover canonical positive/negative Sv39 addresses, several physical
widths, M/S trap destinations, integer and atomic accesses, HLV/HLVX/HSV,
split-page faults and a within-page PMP denial. They distinguish address,
cause, EPC, register-canary and unexpected-trap failures.

All checkers require the expected exit status and firmware marker; an
instruction-limit exit or timeout is never accepted as success. Generated
results include commands, configurations, source/reference/ELF hashes and
logs. These focused reference checks are not a complete ACT4 or processor
conformance result.
