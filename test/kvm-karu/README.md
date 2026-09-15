# Linux KVM integration fixture

This fixture boots a real Linux KVM host on the H-enabled Karu SoC simulator
and runs two **upstream KVM selftest guests**, with the small pinned corrections
described below. It does not equate reaching a
Linux shell, finding `/dev/kvm`, or creating a VM with successful guest execution.
H remains an opt-in profile configuration; this simulation fixture does not
change legacy/default board device trees or claim complete RVA23S64
conformance.

## Inputs and build

Required tools are GNU make, a native C/C++ compiler, RISC-V-capable LLVM tools,
a RISC-V Linux GCC with static libc, `tar`, `patch`, `sha256sum`, and device-tree tools.
The kernel build also requires its normal host prerequisites (`flex`, `bison`,
and `bc`). No target `libelf` package is needed by these selftests.

Pinned inputs:

| Input | SHA-256 |
| --- | --- |
| Linux 7.1.2 source archive | `37198c93727be247c9fb5309bb86cd5e496c61e5322cd8c4eca9476bb0b5883f` |
| Karudeb OpenSBI v1.8.1 `fw_jump.bin` | `307ff4379bb146646a0825b510e5f16b664c669e7b24390b381350a5a914fc21` |

The default paths are respectively
`../karudeb/build/kernel-source/linux-7.1.2.tar.xz` and
`../karudeb/build/karu64/opensbi/fw_jump.bin`. The OpenSBI source commit is
`74434f255873d74e56cc50aa762d1caf24c099f8`; its generic configuration includes
SBI TIME and RFENCE and uses `FW_JUMP_FDT_OFFSET=0x1c00000`.
Different input contents are rejected rather than silently changing the oracle.

From the Karu repository root:

```sh
KVM_BUILD_JOBS=8 bash test/kvm-karu/build.sh
python3 test/kvm-karu/test_runner.py
```

The helper extracts a separate source snapshot under `_build/kvm-karu-debugfix`,
records pristine source hashes, applies the two exact patches below, checks
the resulting file hashes before and after building, and uses separate kernel and
selftest output directories. It never modifies the companion kernel source,
release kernel, installed tools, or release DTBs. Outputs and effective kernel
configuration are hashed in `_build/kvm-karu-debugfix/manifest.txt`, together
with build tools, fixture sources, runner, documentation and patch hashes.

Overrides: `KVM_OUT`, `KVM_LINUX_ARCHIVE`, `KVM_OPENSBI`, `KVM_BUILD_JOBS`,
`KVM_CC`, `KVM_HOST_CC`, `KVM_HOST_CXX`, `KVM_PATCHES`, and `KARUDEB`. Input path overrides
still require the pinned hashes. Build logs can be redirected to a new file
under `_build`; do not reuse a log name when preserving evidence. `KVM_PATCHES=0`
reconstructs the pristine negative-control fixture in `_build/kvm-karu-pristine`
by default. Changing patches or patch mode requires a fresh output directory.

## Pinned source corrections

These are local, explicit corrections to the pinned test fixture, not changes
to the shared kernel tree and not claims about other Linux versions:

- [guest-debug-config.patch](patches/guest-debug-config.patch) calls the existing
  RISC-V KVM configuration helper from `SET_GUEST_DEBUG`. The original callback
  changes `guest_debug` but does not update breakpoint delegation or mark cached
  guest CSRs dirty. After disabling debug, the unchanged `riscv/ebreak_test`
  consequently exits to the host a second time instead of running its guest
  breakpoint handler. The patch changes no selftest assertions or guest code.
- [timer-done.patch](patches/timer-done.patch) strengthens only the RISC-V host
  side of `arch_timer`: it requires `UCALL_DONE`, not `UCALL_SYNC`, and checks
  the copied-back interrupt count against the configured iteration count.
  The guest timer body and non-RISC-V behavior remain unchanged. This closes a
  test-proof gap; it is not a processor or timer-behavior workaround.

Exact file fingerprints are checked before applying either patch with zero
fuzz. The pristine `vcpu.c` SHA-256 is
`dea806f1db0f467e3403fe86546a0d9f96248421b7c0bdb2458d97d7e3c24e12`;
the shared `arch_timer.c` SHA-256 is
`7b639f8a9d8522aa8cf7fc376b981dd120f5fe2e933c36271745baa37adc0699`.
Full pristine and patched manifests preserve the remaining source provenance.

## Model and memory layout

The kernel enables KVM, FP, and vector support. Its initramfs contains a small
PID 1 plus statically linked upstream `riscv/ebreak_test` and `arch_timer`.
Networking, a distribution root filesystem, and a second Linux kernel are
unnecessary for this initial guest-execution gate.

Build a fresh model for the H-enabled shipping datapath:

```sh
make LINUX_V_DIR=_build/Vlinux_kvm_profile \
  LINUX_DEFS='-DKARU_RVA23S64 -DKARU_ICACHE -DKARU_ZVK -DKARU_KECCAK -DKARU_M_MUL_CYCLES=4 -DKARU_M_DIV_CYCLES=64 -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_SMCNTRPMF -DKARU_SSCOFPMF' \
  _build/Vlinux_kvm_profile/Vlinux_tb
```

| Region | Address |
| --- | --- |
| RAM (32 MiB) | `0x80000000`–`0x81ffffff` |
| OpenSBI | `0x80000000` |
| Linux Image | `0x80200000` |
| External initramfs | `0x81200000` |
| FDT | `0x81c00000` |

The builder rejects kernel/initramfs/FDT overlaps. The simulation-only DTB
advertises H, Sstc, Ssstateen, Svnapot and the selected vector/crypto profile;
it is never staged to TFTP. The simulation timebase is 25 MHz, matching the
existing Linux harness
convention (`mtime` advances once per simulated core cycle). PID 1 prints total
and available memory before creating guests so memory pressure remains visible.

## Run and pass criteria

This is an integration test: its verdict comes from the upstream guest tests
and the runner's required completion sequence. It does not compare each retired
instruction with Spike. ACT4 separately uses self-checking ELFs containing
Sail's precomputed expectations; directed ISA tests provide additional reference
comparisons.

```sh
python3 test/kvm-karu/run.py \
  --model _build/Vlinux_kvm_profile/Vlinux_tb \
  --log _build/kvm-karu-debugfix-rtl-run.log
```

Each run writes the exact command and simulator/image/DTB/runner hashes beside
the log, in a `.log.json` file. Existing logs are not overwritten. The default
limits are one billion simulated cycles and four wall-clock hours; override
with `--max-cycles` and `--wall-seconds`. Extra simulator arguments can be passed
with `--plusarg`.

PID 1 runs these commands sequentially, with a 30-second guest-host Linux alarm
for each process:

```text
/tests/ebreak_test
/tests/arch_timer -n 1 -i 2 -p 1 -m 0 -e 1000
```

`ebreak_test` enters a guest with page tables, checks a `KVM_EXIT_DEBUG` and its
guest PC, resumes with debugging disabled, checks the guest's own breakpoint
handler, and requires `UCALL_DONE`. `arch_timer` enters a one-vCPU guest and
checks two Sstc timer interrupts. Its 1,000 µs allowance is a functional-test
tolerance, not a timer-latency measurement. A selftest skip (exit 4), signal,
nonzero exit, kernel panic, or missing completion marker is a failure.

Only after both child processes exit zero does PID 1 emit:

```text
[KVM-KARU] COMPLETE tests=2 failed=0 skipped=0
```

The runner requires both preceding per-test start/pass records, then stops
only its own simulator process group. It does not use or relax the legacy
simulation exit MMIO address. A simulator's zero exit on its cycle limit is
not accepted as a test pass.

## Independent fixture controls

QEMU TCG can validate the Linux/initramfs/test integration independently of
the RTL. It uses its generated `virt` DTB, so it is not a test of Karu's platform
DTB or interconnect. The runner defaults to one RV64 H+V/Sstc CPU, VLEN 256 and
Sv39; `--qemu-cpu` permits an explicitly recorded alternative.

```sh
python3 test/kvm-karu/run.py \
  --qemu "$(command -v qemu-system-riscv64)" \
  --wall-seconds 120 --log _build/kvm-karu-debugfix-qemu.log
bash test/kvm-karu/test_timer_controls.sh
```

The second command builds separate intentionally failing timer guests under
`_build/kvm-karu-timer-controls`. One substitutes `UCALL_SYNC` for completion;
the other reports `UCALL_DONE` with an inconsistent interrupt count. Both must
be rejected by the strengthened host test, after the unchanged breakpoint
guest has passed. Neither control modifies the normal fixture or its guest
sources. Use `KVM_CONTROL_OUT` to select a fresh control output directory and
`KVM_QEMU` to select QEMU. The runner also accepts explicit `--kernel`,
`--initramfs`, `--opensbi`, `--image` and `--dtb` paths for frozen baselines.

The pristine Linux 7.1.2 baseline reproduces the debug-disable defect on QEMU
both with `max,vlen=256` and with the narrower default CPU. A diagnostic copy
confirmed the second exit is `KVM_EXIT_DEBUG` at the second EBREAK. The initial
unpatched RTL run was intentionally stopped after that independent diagnosis;
it has no DUT verdict. Corrected QEMU and RTL outcomes must be recorded with
their separate manifests and completion logs.

Control results measured on 2026-09-13:

| Control | Result |
| --- | --- |
| Corrected fixture, default Sv39 QEMU CPU | Both guests exit 0; strict completion PASS |
| Same fixture, `max,vlen=256` QEMU CPU | Both guests exit 0; strict completion PASS |
| Timer guest sends SYNC instead of DONE | Rejected: unexpected guest exit |
| Timer guest sends DONE with interrupt count 0 | Rejected: expected count 2 |
| UART runner controls | 15/15 PASS |

The QEMU binary identifies as 11.1.1 (`v11.1.1-dirty`) and has SHA-256
`c8a1a48742c049f7b8284fdb40e5019d177a14015b165088ffdda0ddc27d888e`.
Corrected fixture hashes are Linux Image
`3bb54fd2f16f37aa823f20466aa1fca57b6a89179a243551c2da160d3f962492`,
initramfs `de787fb8844bb8df8aa0772e16b201714bec4ab233c52bd4567caf70eb0c909b`,
and flat image `fe004118143ed4fe02ba3b36dc04caf05a8caf35823625922d1037e37043a626`.
The breakpoint selftest's executable `.text` is byte-identical to the pristine
baseline. Evidence is in `_build/kvm-karu-debugfix-qemu{,-max}.log` and
`_build/kvm-karu-timer-controls-v2/{1,2}/qemu.log`, each with run metadata.
These are fixture-control results, not an RTL KVM verdict.

## Checkpoint and waveform replay

The Linux harness in `flow/linux_tb.cpp` supports Verilator save/restore.
Build its vector variant with the same `LINUX_DEFS` as the model above:

```sh
make -j8 linux-trace LINUX_TRACE_VECTOR=1 \
  LINUX_TRACE_DIR=_build/Vlinux_kvm_trace \
  LINUX_DEFS='-DKARU_RVA23S64 -DKARU_ICACHE -DKARU_ZVK -DKARU_KECCAK -DKARU_M_MUL_CYCLES=4 -DKARU_M_DIV_CYCLES=64 -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_SMCNTRPMF'
python3 test/kvm-karu/test_checkpoint.py --model _build/Vlinux_kvm_trace/Vlinux_tb
```

`test_checkpoint.py` compares complete serialized state at cycle 1,200 from
uninterrupted execution and a replay restored at cycle 1,000. It also checks
the cycle and exit guards and a bounded VCD window. Its temporary snapshots
and waveforms are removed after the check.

For a long run, pass `--plusarg=+save_at=N` and
`--plusarg=+save_file=_build/kvm.save` to `run.py`. The trace-capable binary
can run without recording a waveform. It saves the model, harness cycle,
waveform time and clock phase, and continues running. Keep the checkpoint with
the exact model binary, input hashes and original run log: it cannot be moved
to rebuilt RTL or imported into Spike.
When `run.py` receives `--plusarg=+restore=...`, its input manifest also records
the checkpoint's SHA-256.

A short diagnostic replay uses that same binary:

```sh
_build/Vlinux_kvm_trace/Vlinux_tb +restore=_build/kvm.save \
  +trace_file=_build/kvm-window.vcd +trace_from=N +trace_to=M +stop_at=M
```

Replace `N` and `M` with absolute cycle numbers bracketing the interval of
interest. `+restore_at=N` is optional and checks the saved cycle. `+stop_at`
limits replay independently of the RTL's saved `+max_cycles` value. Snapshots
restore the testbench's image, memory and input settings; changing RTL
plusargs on replay does not reinitialize those settings. A replay used as a
KVM verdict must still show the runner's complete required guest-test sequence.
Waveform replay alone is a debugging result.

## Coverage boundary

The September 14 VCU118 run on Linux 7.2.4-zvk passes both
`riscv/ebreak_test` and `arch_timer -n 1 -i 2 -p 1 -m 0 -e 1000`, with the
strengthened timer completion/interrupt-count checks. This closes the initial
hardware guest-execution gates. The board kernel already includes the guest
debug correction needed by the pinned 7.1.2 simulation fixture. See the
[release diagnostics](../../doc/release-diagnostics-2026-09-14.md) for the
image identity and current evidence. The September 15 board acceptance log
covers the KVM API only; guest execution requires these separate selftests.

The fixture's fifteen runner tests include host-boot-only, missing-marker,
skip, duplicate-result/completion, trailing failure, timeout, EOF, and panic
negative controls. Kernel and guest
execution results must be recorded separately with their build/run manifests;
building this fixture alone is not an RTL KVM pass.

Next integration gates remain guest PMU and FP/vector preemption/context
isolation, two guests/time offsets, more page-fault and MMIO workloads, and
eventually a guest Linux boot. The two initial selftests do not cover those
contracts or establish complete H/Sha/RVA23S64 compliance.
