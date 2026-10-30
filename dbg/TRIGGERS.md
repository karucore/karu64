# Hardware address triggers

`KARU_DBG_TRIGGERS` adds two debugger-owned Sdtrig 1.0 `mcontrol6`
slots. `KARU_DBG_TRIGGER_COUNT=4` selects four slots for integration and cost
comparison. `KARU_DBG_FULL` also selects this feature. A base `KARU_DBG`
build retains absent trigger CSRs. This is original Karu RTL, implementing the
ratified [Sdtrig specification](https://docs.riscv.org/reference/debug/v1.0/Sdtrig.html).

The implemented CSRs are `tselect`, `tdata1`, `tdata2` and `tinfo` at
`0x7a0`, `0x7a1`, `0x7a2`, `0x7a4`. Other trigger CSRs, including
`tdata3` and `tcontrol`, raise illegal instruction. `tinfo=0x01008040`
reports Sdtrig version 1 and types 6 and 15. An out-of-range `tselect` write
leaves its previous value; enumeration terminates at the failed readback.

Active slots require type 6, `dmode=1`, `action=1`. Only Debug Mode can
configure one. Ordinary M-mode writes cannot change a protected slot; a write
requesting an active trigger without those conditions disables the slot as
type 15, `dmode=0`. Debug Mode can disarm a slot by writing zero. Reset
leaves every slot disabled. Native action-0 breakpoint exceptions are deferred.

Supported fields are execute/load/store; separate M, S, U, VS and VU enables;
equality or NAPOT address matching; and the `hit0` before-retirement indication.
Unsupported S/H privilege fields read zero in configurations without those
extensions. The matching privilege is the executing instruction's privilege.
MPRV and HLV/HSV affect its address generation, not that privilege selection.
Size is WARL any-size, select is address, chaining is zero, and unsupported
active match modes, sizes, data selection, chaining or actions disable the slot.
Other reserved/unsupported fields read zero. A debugger must check readback.

`tdata2` preserves all 64 bits in equality/disabled slots. NAPOT supports
ranges of 2 through 2^63 bytes, using the standard trailing-ones encoding.
Writing all low 63 bits as ones while NAPOT is selected clears bit 62, exposing
`maskmax6=63`. Attempting to select NAPOT with a previously stored address
outside that range disables the slot; it does not rewrite `tdata2`. Masks are
computed on configuration writes with fixed reductions, then registered; the
running address comparators contain no variable division/modulo or extra memory
ports.

Execute probes use the architectural instruction-start PC at issue, including
a fetch fault at a later halfword. Data probes use the post-pointer-masking,
pre-translation effective address, including MPRV, MXR and guest addressing.
The address programmed into `tdata2` is never pointer-masked. The implemented
compare value is the **lowest address of each architectural access**, not every
byte of a wider access; this is Sdtrig's required address coverage. Cache-block
operations compare their original effective address (Sdtrig §5.1.5.3 option 3).
LR matches loads, SC matches stores even when it would fail, and AMOs match
both. Probes precede translation and cache lookup, so cache hits remain visible.
Implicit page-table reads, fills, Debug Mode execution and SBA do not match.

Vector checks use each memory transfer's data EEW, which can differ from
`vtype.SEW`; an indexed instruction's index EEW does not change its data
transfer width. This is a deliberate choice relative to the SEW-sized
comparison recommended by [Sdtrig §5.1.5.2](https://docs.riscv.org/reference/debug/v1.0/Sdtrig.html).
Whole-register checks use their encoded EEW as described below.

With no armed data trigger for the current instruction's direction, the normal
vector memory engine and cycle counts are unchanged. A load-only slot does not
serialize vector stores, and a store-only slot does not serialize vector loads.
An armed eligible data trigger selects the per-element engine.
It checks active elements only, including masks and `vstart`; each segmented
operation checks every field of the current segment before performing any of
that segment's side effects. Each field's 64-bit post-masking address is registered
before the query, separating indexed/strided address generation from the trigger
comparator and global debug-entry control. This adds one cycle per armed field
query; it does not change the disabled path or add a memory port. The address
payload is unreset and usable only after the capture state. Four-state tests
and an independent capture assertion check that qualification. The 16 ordinary
CPU subjects pass with identical base-debug and idle-full-extension cycle counts;
the post-stage ACT4 replay passes 2872/2872. These CPU tests supplement the
focused trigger tests and do not establish mapped timing closure.
Loads commit their completed prefix before debug
entry. Stores complete earlier elements before advancing. A hit enters Debug
Mode with DPC at the vector instruction, preserves `vl` and records its element
in `vstart`. After disarming and resuming, the remaining elements execute once.
This also applies to fault-only-first loads: a watchpoint never silently trims
`vl`; an actual fault after resume at an index above zero uses ordinary FF trim.
Whole-register accesses use the core's byte walk, but address matching is
qualified to the starts of the instruction's **encoded EEW** elements. Interior
byte probes are suppressed; stopping there would round `vstart` down and repeat
already completed device reads on resume. The restart index is converted back
to that encoded width. Counted-device tests cover EEW 8/16/32/64 and prove that
each byte is read once across a watchpoint, disarm and resume.

Run the maintained bounded tests with:

```sh
make dbg-trigger-unit-test dbg-trigger-vector-test dbg-trigger-four-state-test
make dbg-trigger-core-test dbg-trigger-profile-test dbg-trigger-negative-test
make dbg-trigger-spike-test
make dbg-trigger-haccess-test
make dbg-trigger-review-test dbg-trigger-invariant-test
make dbg-trigger-four-state-test \
  DBG_TRIGGER_IV_DIR=_build/dbg/trigger-profile-four-state \
  DBG_TRIGGER_IV_FLAGS='-DKARU_RVA23S64 -DKARU_ICACHE -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE'
```

The independent vector bench sweeps SEW 8/16/32/64, fractional/integer LMUL
geometry, contiguous/strided/indexed/segmented accesses, masks, prestart/tails,
load/store prefixes, PM lengths 7/16, FF hit positions and earlier real faults.
The actual-core probe covers GPR and FP accesses, LR/SC/AMOs/CBO, protected CSR
writes, host/guest modes, cached loads, precise MMIO stores, pointer masking and
MXR/MPRV, split-fetch fault priority, vector continuation and the FF
watchpoint-then-fault case. Direct changes to the responder's instruction RAM
are synchronized using an actual Program Buffer FENCE.I before execution.
The independent H-access focus passes 20 HLV/HSV/HLVX probes: HS SPVP=1
selecting henvcfg.PMM, HS SPVP=0 selecting senvcfg.PMM, and U/HU selecting
HUPMM, each at PMLEN 0/7/16, plus HLVX's unmasked address and MXR disabling
masking. Its VS/G-stage fixture is set up and restored through architectural
CSRs; the ordinary profile probe separately checks real translated aliases.

The review probe checks the opposite-direction cases against the normal walk,
identical hot-cache cycle counts and expected data. It also holds an actual
instruction-read response, starts an SBA RAM write, then releases the read as
a bus fault: the pending fetch-fault execute trigger stays blocked during the
SBA pause and fires precisely after maintenance releases execution. An older
already decoded instruction retains its normal trigger qualifications while
it drains before an SBA transaction.

`rtl/karu_assert.sv` contains the reusable INV40 debug checker, attached through
the main invariant checker, the bind path and the portable debug testbench.
It checks qualified slot privilege/action/direction, precise debug entry and
DPC/cause publication, suppressed issue/retirement, and fetch-fault admission
during SBA pause. Independently observed request/acknowledgement history checks
one maintenance flush, external completion ordering, local cache invalidation
and the fetch redirect, including higher-priority debug entry. The driven-state
fixture passes its legal sequences and rejects 15 corrupted observations.
These controls complement the six RTL-mutation controls below.

Negative controls corrupt a registered query address, remove a cached-load
match, skip later vector elements, match inactive elements, corrupt the restart
index and restore the invalid
whole-register interior-byte probes; each must be rejected. The independent
four-state bank tests pass 1,298 checks at two slots and 1,302 at four. The
independent VLSU sweep passes 1,066 cases and 47,752 checks. Six trigger negative
controls pass. The actual-core whole-register focus also passes the counted
MMIO trace at all four encoded widths. Generated logs live under `_build/dbg`.

`dbg-trigger-spike-test` runs the same OpenOCD address-trigger scenario on
reference Spike, with two slots and Program Buffer memory access. Its
`reference.json` records the exact simulator executable SHA-256, command and
OpenOCD version; `DBG_SPIKE` selects that executable when reproducing a result.
The shared scenario checks execute/read/write/access stops before side effects
and exact continuation. It does not compare unsupported CSR WARL choices or
claim all of Spike's trigger features.
The combined OpenOCD/GDB gates additionally allocate slots and exercise actual
hardware breakpoints, read/write/access watchpoints and continuation. Full
combined validation hashes and mapped/routed measurements belong in the
[main validation record](README.md#extension-implementation-and-testing-plan).
