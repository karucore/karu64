# Isolated Spike Sstc reference correction

This directory maintains one narrowly scoped Sstc oracle correction for the
[Karu Spike fork](https://github.com/mjosaarinen/riscv-isa-sim) at commit
`f10808d48aec727b41757334ff18c416b0242516`. It changes neither karu64 RTL
nor the expected architectural result.

## Scope

The pinned reference can leave its hardware VSTIP contribution set after
effective `henvcfg.STCE` becomes zero. Its comparator-write helper can also
update both host and guest pending bits using the writer's virtual-time view.
`patches/sstc-pending.patch` centralizes recomputation from raw time and the
independent host/guest comparators after comparator and environment-control
writes. It preserves software STIP and the separately stored HVIP contribution.

This follows the
[Sstc comparator/STCE rules](https://docs.riscv.org/reference/isa/v20250508/priv/sstc.html)
and H's independent virtual pending sources.

## Isolated build

Prerequisites are Spike's normal C++20 build tools, device-tree compiler,
Boost, Git, patch and SHA-256 utilities. Start from a checkout at the exact
pinned commit:

```sh
SPIKE_SOURCE=../src/riscv-isa-sim JOBS=4 bash test/spike-karu/build.sh patched
SPIKE_SOURCE=../src/riscv-isa-sim JOBS=4 bash test/spike-karu/build.sh baseline
```

Each build exports committed source into a separate `_build/spike-sstc-*`
directory, rejects patch fuzz/source drift, and records a manifest plus build
logs. It does not modify the input checkout or install an executable. Select a
fresh output with `SPIKE_OUT` when needed.

## Regression

The same unmodified 187-case timer firmware must run on both references. The
patched reference must complete successfully; the baseline must fail at the
specific pending-source transition rather than time out or fail arbitrarily.
Do not use Spike's instruction-count limit as the completion criterion because
this pinned revision may exit zero at the limit.

```sh
make _build/karu_sstc_test.elf _build/karu_h_test.elf \
  _build/karu_hfence_test.elf _build/karu_hmem_hfence_test.elf \
  _build/karu_hvm_test.elf
bash test/spike-karu/run.sh
```

The maintained checkpoint passes the 187-case H timer test plus the non-H
Sstc, bare-H, HFENCE/HINVAL, H-memory/fence and paged-guest controls on the
patched reference. The baseline passes all controls and fails only the
expected timer transition. The runner uses external deadlines, verifies
target completion markers, and records commands, hashes and per-run logs under
`_build`. These focused checks are not an exhaustive Spike or hypervisor
conformance claim.
