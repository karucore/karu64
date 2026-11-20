# karudbg authentication and debug-lock plan

Status: **plan, revision 3. A0, A1, A5 and A6 are done; A2, A3, A4 and A7
are in progress.** A2 has the window ROM in a simulation build and an FPGA
build; the FPGA ROM verifies a SHA3-256 MAC (algorithm `0x04`) and is
board-tested, and the production verifier waits for decision D3. A3 and A4
are partial. The VCU118 debug image is built with `KARU_DBG_AUTH`, with the
lifecycle and the boot hold on DIP switches
([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)). Section 7 has the notes
per milestone.

This plan
addresses [review finding S6](security-review-2026-11-15.md#s6--high-for-deployment-no-debug-authentication-or-runtime-lock):
the DM reports `authenticated=1` unconditionally and has no runtime lock, so
JTAG access grants full machine-mode control and, with SBA, bus mastering.

Revision 2 responds to a review of revision 1. It makes these changes:

- defines the trusted boot island (ROM, verifier memory, key and entropy)
  that the adversary does not control;
- replaces the MMIO auth window with M-mode CSRs, so provenance is captured
  at instruction commit;
- gives a concrete POR → hold → request → window sequence and precise reset
  classes;
- separates the platform grant from the DM's `dmactive`-reset session state;
- adds a non-blocking mailbox protocol that keeps `authbusy` compliant;
- adds a relock contract for outstanding SBA and DMI work;
- adds a third, disabled, lifecycle state;
- restructures the proof around explicit structural cuts, with boot and
  revocation transition lemmas.

Revision 3 follows the S7–S13 fixes:

- It separates **ordinary DM deactivation** from **security revocation**.
  Since the S8 fix, deactivation is acknowledged only once the abstract
  command engine is idle, and with a hung Program Buffer that may never
  happen. Revocation must therefore never rely on deactivation. It blocks new
  work at once, stops serving debugger words to the hart, and enforces its
  own reset bound (§3.5).
- S8 and S10 are now fixed; they are no longer A1 work.
- D3 no longer blocks the RTL interfaces. The frame carries an explicit
  algorithm identifier and bounded lengths (§3.4). D3 must still be settled
  before the production ROM verifier is implemented and sized (A2).

The plan has two goals:

1. **Mechanism.** A lifecycle-ceiling, ROM-confined authentication and lock
   scheme for karudbg that interoperates with pinned mainline OpenOCD.
2. **Evidence.** A machine-checked argument that, in a locked lifecycle,
   Debug Mode cannot be entered and the DM cannot cause side effects or
   disclose hart state through the external interfaces without a successful
   authentication by the trusted ROM. The design is shaped so that this
   argument is small: every gate sits immediately before the state element it
   protects, and every untrusted input crosses a named cut.

## 1. Trust boundary and threat model

### 1.1 Trusted boot island

These components are trusted. Their contents and their **response paths** are
outside adversary control:

| Component | Content | Where it lives |
| --- | --- | --- |
| Authentication ROM | ROM window code and its constants | Island ROM `[AUTH_ROM_BASE, AUTH_ROM_END)`; `RESET_PC` and the reset `mtvec` lie inside it |
| Verifier memory | Stack and intermediate verification state | Island SRAM, reachable only from the hart's own instruction/data ports |
| Verification key | The public key, or its hash with the key itself in ROM | OTP or ROM, read through the island |
| Entropy | Challenge nonce | The Zkr `seed` CSR, read by the ROM in M-mode; the entropy source behind it is a platform block |
| Lifecycle | `OPEN`, `AUTH` or `DISABLED` | Platform OTP/lifecycle input, stable from POR |

The island is decoded inside `karudbg_core` on the core's own `imem` and
`dmem` ports, before `karudbg_bus` joins SBA and before any external fabric.
For any request to an island range, the response is selected only from the
island. A stray or injected R/B beat from the external fabric can never
complete an island request (cut K3, lemma C9). This protection covers I-cache
and D-cache fills of island addresses and the IFU prefetch buffer. The
existing executable scratch SRAM (`0x00201000…`; `0x00101000…` before the 2 MiB boot ROM) is reachable by SBA, and on
an ASIC possibly by other managers. It is **not** verifier memory.

On the VCU118 the island is `karudbg_island` with a ROM and SRAM of its
own, decoded in front of the boot memory; the boot ROM image leaves that
range empty. The FPGA is
functional validation only: its configuration JTAG can replace the bitstream,
so it is never the security target of the claim.

### 1.2 Adversary

The adversary controls every other input at every clock edge:

- the JTAG pins `tck`, `tms`, `tdi` and `trst_n`, and the USER4 BSCAN tunnel,
  including truncated or malformed scans;
- every response from the external fabric: data, IDs, `RESP`, `LAST` and
  timing, including unsolicited beats;
- all mutable memory outside the island;
- interrupts and `time_in`;
- the system reset (`hart_reset_i`);
- the boot-hold strap (§2.4);
- `cache_flush_done`.

The adversary does **not** control the island, POR, the clock, the lifecycle
value, or the physical integrity of the device. Fault injection, glitching,
probing and scan access are outside the claim (§9).

## 2. Lifecycle, reset classes and state

### 2.1 Lifecycle

| `lc` | Debug at reset | Authentication | Use |
| --- | --- | --- | --- |
| `OPEN` | Enabled | Not needed | Development |
| `AUTH` | Disabled | ROM window may grant | Production with authenticated debug |
| `DISABLED` | Disabled | Mailbox and unlock hard-disabled | Production without debug |

```
debug_enable = (lc == OPEN || (lc == AUTH && auth_unlock)) && !fw_lock && !revoke_q
```

`revoke_q` latches an optional trusted platform revocation input; see
[contract §3.4](debug-auth-contract.md#34-revocation-sources).

### 2.2 Reset classes

| Class | Source (ASIC / VCU118) | Resets |
| --- | --- | --- |
| **POR** | `karudbg_top.rst` / board reset (`rst`, which also resets the DM on the VCU118) | Everything: DM, DTM, `karudbg_auth` (`auth_unlock`, `boot_done`, `fw_lock`, `revoke_q`, hold), lifecycle and strap sampling |
| **System reset** | `hart_reset_i`; permitted `ndmreset`; relock reset; hold | Hart, caches, fabric adapters, SBA ownership. **Not** the DM or `karudbg_auth` |
| **DM deactivation** | `dmactive=0`, acknowledged only once the command engine is idle (S8 fix); this can take unbounded time | DM control state and the authentication *session*: mailbox FIFOs, operation state, errors, `authbusy` and a pending request. **Not** the platform grant, and not a security mechanism (§3.5) |

`auth_unlock`, `boot_done`, `fw_lock` and `revoke_q` change only monotonically between
PORs. Consequently:

- **One window per POR.** A system reset reruns the ROM with `boot_done=1`,
  so the window stays closed. Repeated system resets give the adversary no
  extra authentication attempts.
- **The grant survives system reset.** After a successful authentication, an
  authorized `ndmreset` or reset-halt keeps debug enabled for the rest of the
  power cycle.
- **`fw_lock` lasts for the power cycle.** Once firmware (or the debugger, from Debug Mode) sets it, debug stays
  off until POR, including for an already authenticated debugger.

### 2.3 Platform grant versus DM authentication state

Debug 1.0 says that `dmactive=0` returns the DM, including its
authentication mechanism, to reset values. Pinned OpenOCD pulses `dmactive`
in `reset_dm` at every examine. If the grant itself were reset that way,
every reconnect would lose authentication, and the window would already be
closed.

This plan therefore treats `auth_unlock` as a **platform grant** held in the
POR-domain `karudbg_auth`, in the same category as the lifecycle input.
`dmstatus.authenticated` reports `debug_enable`. The DM's *authentication
mechanism* is the mailbox session, and it does reset with `dmactive=0`.

Debug 1.0 also makes `dmactive` readback the acknowledgement that
deactivation has completed. Since the S8 fix, a `dmactive=0` write during a
busy command is held pending, and the DM stays fully active until the hart
parks, faults, is reset or becomes unavailable. The session resets when
deactivation completes, not when it is requested. Until then, the existing
session continues under the current grant.

While the DM is locked, no command can start. A command in flight at a
revocation is ended by the relock reset (§3.5), so a pending deactivation
then completes within that reset bound.

This interpretation is to be recorded in the contract (A0) and checked against
the specification text. The alternative, re-authentication per DM session, is
rejected because the window exists only once per POR.

### 2.4 Authentication sequence

The window can occur only between POR and the first `boot_done`. The request
must therefore be made while the hart is held after POR.

1. **POR**, with the boot-hold strap asserted. This is a pin: a DIP switch on
   the VCU118, a strap or test pin on an ASIC. `karudbg_auth` samples it at
   POR release and holds the system reset. The DM, DTM and mailbox are live,
   and the locked `dmstatus` discloses only `version`, `authenticated=0` and
   `authbusy` (contract §1.2).
2. The debugger activates the DM. It reads `dmstatus` and sees
   `authenticated=0`.
3. The debugger issues mailbox `REQUEST` (§3.4). In `AUTH`, this sets
   `auth_req` and releases the hold. In `OPEN` or `DISABLED` it is rejected
   with a status code.
4. The ROM runs. It sees `auth_req`, generates the challenge from a nonce
   read from `seed` and the device identity, and places it in the TX FIFO.
5. The debugger polls `STATUS`, reads the challenge with `RECV`, and writes
   the signed response with `SEND`.
6. The ROM verifies the response. On success it writes `auth_unlock`. In all
   cases it then writes `boot_done` and continues to boot. A bounded timeout
   also leads to `boot_done`, and the mailbox then reports `CLOSED`.
7. The debugger sees `authenticated=1` and re-examines.

Without the strap, POR proceeds straight into the ROM. With no `auth_req`
set, the ROM sets `boot_done` immediately and boots locked. Without a request,
the strap simply keeps the part in reset; releasing it boots normally.

The strap is treated as adversary-controlled: it can only open an
authentication attempt and grants nothing itself. A DM command that can
*cause* a system reset into the window is deliberately not offered. Offering
one would hand JTAG a reset capability while locked (decision D2).

The VCU118 has a POR-class board reset (the CPU reset button), which also
resets the DM, plus `ndmreset` and the software reboot, which is a
system-class reset. The boot-hold strap there is position 3 of
DIP switch SW12 (A5).

## 3. Architecture

### 3.1 `karudbg_auth` state and CSRs

`karudbg_auth.v` is a POR-domain block in `karudbg_core`. The hart reaches it
**only through M-mode custom CSRs**: `0x7C0–0x7C2` and read-only `0xFC0`,
as fixed in [contract §3](debug-auth-contract.md#3-csrs). CSRs are
not on any bus, so SBA, DMA and the JTAG loader have no path to them by
construction.

| CSR | Access | Content |
| --- | --- | --- |
| `mdbgauth` (`0x7C0`) | Read; write-1-to-set only | `auth_unlock`, `boot_done` and `fw_lock` (monotone; clears ignored); read-only `lc`, `auth_req`, `hold` and window state |
| `mdbgrx` (`0x7C1`) | Read-write access only (Zkr `seed` rule) | ROM side of the mailbox: pop RX |
| `mdbgtx` (`0x7C2`) | Write | ROM side of the mailbox: push TX |
| `mdbgmbst` (`0xFC0`) | Read-only | Mailbox counts, errors and session state |

**Commit predicate for `auth_unlock`.** A set takes effect only when **all**
of the following hold:

- the CSR write retires architecturally (no trap);
- the instruction at EX has its PC in `[AUTH_ROM_BASE, AUTH_ROM_END)`;
- privilege is M, `V=0` and `debug_mode=0`;
- `lc == AUTH`;
- `boot_done_q == 0`;
- `boot_exit_now == 0`.

The PC is the committing instruction's `ex_pc`, available in the same cycle
as the CSR write. No address translation, buffering or AW/W ordering is
involved. Any CSR instruction may set the bit (CSRRW, CSRRS or CSRRWI with
bit 0 set). Clearing writes are ignored, and reads are side-effect-free.

**`boot_exit_now`** is asserted by the core on any of:

- a trap taken;
- an ID→EX issue of an instruction whose PC is outside the ROM range;
- Debug Mode entry.

It sets `boot_done`, and in the same cycle it overrides any `auth_unlock`
write. Prefetch does not count; issue does.

### 3.2 DM gating

Two mechanisms share the DM and must stay distinct.

- **`dmactive_q`**: ordinary DM reset. It is acknowledged only when the
  command engine is idle, so that a hart's borrowed `a0`/`s0` are restored
  (S8).
- **`debug_enable_q`**: the registered security gate. It never waits for
  the engine.

Every use of `dmactive_q` as a qualifier of new work, of a DMI-visible
value, or of an output in [`karudbg.v`](../dbg/karudbg.v) becomes
`dm_enabled_q = dmactive_q && debug_enable_q`. From the cycle after
`debug_enable_q` falls, it blocks:

- command launch and autoexec;
- Program Buffer, data and `abstractauto` writes;
- halt, resume, `ndmreset` and `hartreset` requests (their flops clear);
- SBA register-engine launches;
- the hart-facing go/resume flags.

Revocation also stops serving debugger content to the hart. From t₀+1, the
debug-page port returns only ROM words and a fixed safe sequence for the
abstract, Program Buffer and data windows: every abstract or Program Buffer
word is EBREAK, and the data window returns zero. This sequence can lose
`a0`/`s0`, which deactivation exists to prevent. Revocation accepts that
loss, because the relock reset (§3.5) resets the hart anyway.

Once the engine is idle, the inactive branch, or the `debug_enable_q=0`
equivalent, holds these registers in reset:

- command, Program Buffer and data registers;
- `abstractauto`;
- `havereset`;
- the SBA register engine.

`dmactive` remains writable and readable, so OpenOCD's activation and
examine sequence still works. While locked:

- `dmstatus` reports only `version=3`, `authenticated=0` and `authbusy`; every
  other field reads 0, as the Debug 1.0 Security section requires (contract
  §1.2). It therefore discloses nothing about the hart.
- `hartinfo` reads zero. Pinned OpenOCD never reaches it while locked: hart
  enumeration in `examine_dm` already fails on `authenticated=0` (contract
  §2).
- `authdata` is served by the mailbox.
- All other registers read zero, and writes other than `dmactive` and
  `authdata` are ignored.

Every DM output that leaves the DM (`halt_req_o`, `resume_req_o`,
`resume_authorized_o`, `ndmreset_o` and `sba_req_valid_o`) is 0 whenever the
registered `debug_enable_q` is 0, whatever the other inputs. Synchronous
control outputs keep today's timing and are ANDed with `debug_enable_q`;
re-registering them would break `OPEN` equivalence (contract §7).

Only `ndmreset_o` must come directly from a flop, because it feeds
asynchronous reset synchronizers. S10 made it one flop; the gate is folded
into that flop, and `dbg-ndmreset-flop-test` checks it.

### 3.3 Core gate

The Debug Mode flop's set term in [`rtl/karu64.v`](../rtl/karu64.v) becomes
`dbg_enter && debug_enable_i`, applied at the flop. The entry sources are also
gated at their origin:

- effective `dcsr.ebreak*`, so EBREAK raises the ordinary breakpoint exception;
- trigger `action=1` matches (no match);
- `dbg_step_done` (the step is dropped).

`dcsr` and the trigger bank already reset with the hart.

### 3.4 Mailbox and `authbusy`

The mailbox is non-blocking. It has hardware-managed RX and TX FIFOs,
initially 16 words each.

On the DMI side, `authdata` is a 32-bit operation interface. A **write**
carries either an operation header or one payload word of a pending `SEND`:

| Header | Effect |
| --- | --- |
| `STATUS` | The next read returns the status word (this is also the default for any read with no pending `RECV`) |
| `REQUEST` | In `AUTH`, during hold: set `auth_req` and release the hold. Otherwise: error code |
| `SEND n` | The next `n` writes go to RX. If RX lacks space for all `n`, the header is rejected with `OVERFLOW` and the words are ignored |
| `RECV n` | The next `n` reads pop TX. If fewer than `n` words are available, the header is rejected with `UNDERFLOW` and reads return status |
| `ABORT` | Clear the session and FIFOs |

The status word contains: a magic value, the protocol version, `lc`, the
session state (`IDLE`, `HOLD`, `REQUESTED`, `WINDOW`, `CLOSED`), the RX free
count, the TX available count, and a sticky error code.

After `boot_done`, the mailbox reports `CLOSED` and rejects `REQUEST` and
`SEND`. `STATUS` still works.

`authbusy` resets to 0 and is set only for the cycles immediately following
an `authdata` access, while the hardware completes that FIFO operation. It
does not represent FIFO state, a pending challenge or ROM progress, so
OpenOCD's `wait_for_authbusy` cannot deadlock.

On the ROM side, `mdbgrx`, `mdbgtx` and `mdbgmbst` give the ROM non-blocking pop and push
with the same counts. The ROM implements its own bounded timeout.

The frame layout is a ROM protocol matter, defined in A0. It is
algorithm-agile so that the RTL does not depend on D3:

- **Header (both directions):** protocol version, an algorithm identifier, and
  explicit lengths for each variable field. Each length has a fixed maximum
  recorded in A0. The maxima bound the ROM's parsing loop and the island SRAM
  it needs.
- **Challenge:** device-identity digest, nonce, `lc` and requested
  permissions.
- **Response:** algorithm identifier, signature and granted-permission mask.

The ROM rejects, without unlocking:

- an unknown or disabled algorithm identifier;
- a length above its maximum;
- a length that disagrees with the identifier's fixed sizes;
- a frame larger than the mailbox can deliver within the bounded wait.

The mailbox hardware stays oblivious to the frame: `SEND n` is already
bounded by RX space.

### 3.5 Relock

`debug_enable` can fall only through `fw_lock`, set by firmware or by the
debugger from Debug Mode, or through the latched platform input `revoke_q`
([contract §3.4](debug-auth-contract.md#34-revocation-sources)). `lc` is
constant and `auth_unlock` is monotone. At the falling edge t₀:

1. **New work stops at t₀+1.** The DM accepts no abstract command, autoexec,
   Program Buffer write, haltreq, resumereq, `ndmreset`/`hartreset` or SBA
   launch. DMI requests accepted from t₀+1 receive locked semantics.
   Responses to requests accepted at or before t₀ may still be delivered,
   because they were authorized.
2. **Accepted SBA work keeps its existing ownership contract**
   ([karudbg_sba.v:109](../dbg/karudbg_sba.v#L109)). An accepted transaction
   or its maintenance runs to completion, and its response is absorbed
   without updating any DMI-visible register.
   - An adversarial responder can withhold that response forever. Bounded
     completion therefore cannot depend on draining; the only bounded cancel
     path is a system reset, which reports `sberror=7` to a DM that is now
     locked, so the report is invisible.
   - Relock guarantees **safety** (no new effects, no disclosure) without
     depending on responders. It cannot guarantee liveness under a
     withholding responder, and that responder could stall the core in any
     case.
3. **A hart in Debug Mode at t₀** receives a system reset within *k* cycles.
   This also cancels SBA ownership. A hart that is running has its pending
   halt or step dropped by the core gate.

**Revocation is not deactivation.** Items 1 and 3 are enforced by the
`debug_enable_q` gate and the relock reset counter in `karudbg_auth` alone.
They never wait on `dmactive`, on the command engine becoming idle, or on the
hart or a bus responder making progress. The guarantee therefore holds with
a pending deactivation, a hung Program Buffer or a withholding responder.

- An instruction already issued at t₀ may still complete. It was authorized.
  The pipeline bounds how many such instructions there can be.
- No debugger word is fetched after t₀+1 (§3.2).
- *k* is a fixed constant of `karudbg_auth`.
- The reset is a system reset (§2.2). It does not depend on `ndmreset`, which
  is blocked from t₀+1.

**T3 (relock) is deliberately narrow.** It prevents the debugger's halted
context from resuming under the lock, and it stops all further debugger
influence. It does **not** undo memory writes the debugger made while
authorized, or prevent later execution of that memory. Those writes were
authorized, and firmware that locks after a debug session must decide whether
to trust its memory.

## 4. Claims

In lifecycle `AUTH` or `DISABLED`, starting from POR, for every adversary
input sequence (§1.2):

- **T1 — No unauthenticated debug.** While `auth_unlock=0`:
  - The hart never enters Debug Mode.
  - The DM never launches halt, resume, `ndmreset`, `hartreset`, an abstract
    command or an SBA request.
  - The DMI response stream is identical for any two runs that differ only in
    hart, memory and fabric state but receive the same DMI inputs and the
    same authdata read data: the mailbox's TX words and its status words.
    The mailbox, its status included, is the only declassified channel.
    (The TX words alone are not: the status word holds the session state,
    the FIFO counts and the error code, which depend on what the hart does
    and when, and the composition has a witness of two runs with the same
    TX words and different status words. The status word carries no
    register or memory content, but it does tell a locked debugger how far
    the ROM has got.)
- **T2 — Unlock confinement.** `auth_unlock` rises only when a CSR
  instruction fetched from the island ROM commits the predicate of §3.1. That
  requires lifecycle `AUTH`, a window still open, M-mode outside Debug Mode,
  and the instruction retiring. No DMI sequence, fabric response, SBA or DMA
  transaction, interrupt or system reset can set it.
- **T3 — Relock.** Section 3.5, items 1–3, with the stated narrowing.
- **T4 — Disabled lifecycle.** With `lc=DISABLED`, `auth_unlock` stays 0
  forever, so T1 holds unconditionally.

**Corollary.** Assume the island ROM meets the obligations of §6, in
particular that it sets `auth_unlock` only after verifying a signature over a
fresh challenge. Then in `AUTH`, Debug Mode is reachable through the external
interfaces only by presenting a valid signature, and only during the
post-POR window.

## 5. Proof plan

### 5.1 Cuts

The full core is too large for unbounded checking. The proof therefore names
the points where untrusted data may legitimately influence protected state,
proves *authorization predicates at those cuts*, and separately proves that
no path bypasses them. It does not claim transitive exclusion of all
untrusted influence: the ROM intentionally consumes mailbox input before it
decides.

| Cut | Signals | Untrusted side |
| --- | --- | --- |
| **K1** DMI | DM `req_*`, `resp_ready_i`, `dmi_reset_i` | JTAG/DTM/BSCAN (arbitrary) |
| **K2** Auth CSR | `karudbg_auth` write port: `we`, `csr`, `data`, `pc_in_rom`, `priv`, `virt`, `debug_mode`, `retire`, `boot_exit_now` | Hart execution (which may itself be adversary-influenced) |
| **K3** Island response | The island/external response selector on the `imem` and `dmem` ports | External fabric responses |
| **K4** DM outputs | `halt_req_o`, `resume_req_o`, `resume_authorized_o`, `ndmreset_o`, the hart-facing debug-page port and the SBA request | (protected side) |
| **K5** Entry | D input of `debug_mode` | Core datapath |

### 5.2 Lemmas

| Lemma | Statement | Method |
| --- | --- | --- |
| **C1 Bypass freedom** | Every structural path from an adversary input (§1.2) to a protected element crosses one of K1–K5 at the listed signals. Protected elements are `debug_mode`, the `karudbg_auth` state, the DM control state, island SRAM contents, and island response data. In particular, nothing other than the hart's CSR file reaches K2, and nothing other than the hart's own ports reaches island SRAM writes. | Yosys cone-of-influence queries on the flattened `karudbg_top` with explicit stop sets at the cuts. The output is a checked inventory; any new path fails the check. |
| **C2 DM locked inertness** | `karudbg` with **all** inputs free and `debug_enable=0` since DM reset: no K4 side effect. The debug-page port returns only ROM and parked-loop words. | Unbounded (k-induction or PDR). |
| **C3 DM noninterference** | Self-composed `karudbg` with identical K1 and mailbox-TX inputs and differing hart, memory and SBA inputs, `debug_enable=0`: identical DMI response streams. | Unbounded miter. |
| **C4 Core entry** | `¬debug_mode ∧ debug_mode′ → debug_enable_i`, and `debug_mode=0` after reset. | One-step SAT on the K5 cone with all other flops free (a sound over-approximation), plus a reset-value check. |
| **C5 Auth block** | Monotonicity between PORs; the commit predicate of §3.1, including the priority of `boot_exit_now` over an unlock in the same cycle; `boot_exit_now` sets `boot_done`; `lc=DISABLED` ignores unlock and `REQUEST`; hold release only by `REQUEST` in `AUTH`. | Unbounded formal on `karudbg_auth`. |
| **C6 Reset completeness** | Every flop in the cones of C2–C9 resets to the value the lemmas assume. | Four-state Yosys simulation of one reset edge from an unknown state, per module, with an allowlist and negative controls; one-step proofs for input-dependent reset values and the hart-side reset composition (C6v, C6cone). |
| **C7 DM revocation** | From any state satisfying the DM's inductive invariants with `debug_enable=1`, after a fall at t₀: §3.5 items 1–2 hold. This covers commands in flight, a pending deactivation, SBA ownership, buffered DMI responses (only requests accepted at or before t₀ may carry unlocked data) and autoexec. From t₀+1 the debug-page port returns only ROM and safe-sequence words. Item 3: a hart in Debug Mode at t₀ ⇒ reset request within *k* cycles, with hart progress, `dmactive` and responders all free (no fairness assumption). | Unbounded on `karudbg` + `karudbg_sba` + `karudbg_auth`, with arbitrary pre-fall history. |
| **C8 Provenance** | At K2: `pc_in_rom` equals the range test of the committing instruction's `ex_pc`. `retire` excludes trapping instructions. `boot_exit_now` is asserted on every trap, every issue from outside the ROM range, and every Debug Mode entry. | One-step SAT over the core's EX/CSR cones with free state. The CSR path is single-cycle at EX, so no pipeline tracking is needed. |
| **C9 Island responses** | For any outstanding island-range request, the accepted response comes only from the island. External R/B beats, including unsolicited ones, cannot satisfy it. Island SRAM accepts writes only from the hart ports. | Unbounded on the island router with free masters and responders, under the core's single-outstanding-per-channel contract (C10). Burst lengths are free. |
| **C10 Core bus contract** | The core issues no new AR on imem or dmem, and no new AW, while one is outstanding on that channel. | Unbounded on the core's AXI arbiters with submodules as free cut points, assuming R and B beats arrive only for outstanding transactions, which C9 guarantees. |

### 5.3 Boot and revocation sequences

Composition over time, written as a short proof in the evidence report:

- **POR → hold.** C5 (hold semantics) and C2 (`debug_enable=0`) apply. K1 can
  affect only the mailbox. No hart execution takes place.
- **Window** (`boot_done=0`). `debug_enable=0`, so C2, C3 and C4 give no debug
  and no disclosure. The hart executes island code, by C9 and the ROM range.
  It consumes untrusted input only through `mdbgrx`, `mdbgmbst` and the
  nonce words it reads from `seed`. Any trap or attempt to leave the ROM
  closes the window (C8, C5).
  A system reset reruns the ROM with `boot_done=1`. `auth_unlock` can rise
  only through K2 under the C5/C8 predicate: a CSR instruction fetched from
  the trusted ROM. Whether that instruction executes is the ROM's decision
  (§6).
- **After the window.** `debug_enable` is constant except for a single fall
  through `fw_lock` or `revoke_q`. C7 covers that fall. C1 shows that nothing reaches the
  protected state except through these cuts.

T1, T2 and T4 follow from this composition, and T3 from C7.

### 5.4 Sanity runs and negative controls

**Whole-system bounded runs** (not part of the proof) use a reduced core
(`KARU_NO_V KARU_NO_F`), free JTAG pins, a free fabric and a stub island ROM
that never unlocks. They check two things:

- In `AUTH`, Debug Mode is never reached within the bound.
- In `OPEN`, a reaching trace is found. This guards against vacuity.

An optional research extension runs the same model with the real ROM window
code and symbolic mailbox input.

**Negative controls.** Each mutation must make the named lemma fail:

| Mutation | Lemma |
| --- | --- |
| Drop the core gate | C4 |
| Leave `halt_req_o` ungated | C2 |
| Leave the `data0` read ungated | C3 |
| Accept an unlock in the same cycle as `boot_exit_now` | C5 |
| Sample `pc_in_rom` from `ifu_pc` instead of `ex_pc` | C8 |
| Let an unsolicited external R beat complete an island fetch | C9 |
| Allow one extra cycle of SBA launch after the fall | C7 |
| Make the relock reset wait for an idle command engine (reuse deactivation) | C7 |
| Keep serving Program Buffer words to the hart after the fall | C7 |
| Route SBA to island SRAM | C1 |
| Reset `auth_unlock` to 1 | C6 |
| Set `authbusy` before the first access | Mailbox unit protocol check |

## 6. ROM software obligations

The hardware confines *where* an unlock can originate. The ROM decides
*whether* to unlock. The ROM must:

- Run with interrupts disabled, keep its trap vector in ROM, and use only
  registers and island SRAM; it must not touch the stack or data outside the
  island. Hardware closes the window on any trap or any issue outside the ROM
  range, so a violation fails safe.
- Use a fresh nonce from `seed` per attempt, taking only `ES16` words (the
  source's health tests gate them), bound to the device identity and
  lifecycle. Allow one attempt per POR, with a
  bounded wait.
- Parse fixed-size frames with no data-dependent lengths. Verify in constant
  time. Make the unlock decision fault-resistant: the unlock CSR write is
  guarded by redundant, independently computed checks of the verification
  result.
- Write `boot_done` before transferring control. Hardware also enforces this.

Prior finding S4 (immutable reset path) is a prerequisite: `RESET_PC` must
be in the island ROM on the ASIC.

A later variant (D3) moves verification into a hardware verifier next to
the DM. That removes ROM code from the trust path and permits authentication
at any time; this section is then replaced by the verifier's own proof.

## 7. Implementation milestones

Each RTL milestone ships with module-local assertions and `karu_assert` INV
checks for its invariants.

- [x] **A0 — contract.** Done 2026-11-15:
  [debug-auth-contract.md](debug-auth-contract.md). D3 is fixed only to the
  algorithm-identifier field and length maxima.
  - Record the Debug 1.0 `dmactive`, `authenticated`, `authbusy` and
    `authdata` text and the §2.3 interpretation.
  - Record the pinned OpenOCD examine, `reset_dm` and authentication flow.
  - Record the S8 deactivation acknowledgement semantics and the
    deactivation-versus-revocation contract (§2.3, §3.5).
  - Fix the CSR numbers, the mailbox header and status encodings, and the
    frame layout, including the algorithm identifiers and length maxima.
  - Settle D1, D2 and D4–D6. D3 needs only the algorithm-identifier field
    and the length maxima here.
  - `KARU_DBG_AUTH` with `lc=OPEN` must reproduce today's behaviour
    bit-for-bit.
- [x] **A1 — RTL.**
  - Add `karudbg_auth.v` (state, CSRs, mailbox, hold).
  - Add the island decoder in `karudbg_core`.
  - Add the core gate, `boot_exit_now` and the CSR sidebands.
  - Add the DM gating and registered outputs, the safe debug-page sequence,
    and relock with its own reset counter.
  - S8 and S10 were fixed on 2026-11-15. Keep `dbg-unit-test`, the
    `dbg-core-test` deactivation sweep and `dbg-ndmreset-flop-test` passing.
    Relock must not reuse the deactivation path.
  - Run Verilator `-Wall`, the strict Verilog-2001 parse and the ASIC
    declaration audit.

  *Status: RTL complete under `KARU_DBG_AUTH`; the combined non-board gate
  passed on the sources of 2026-11-19
  ([record](../dbg/README.md#current-combined-validation-record)).*

  - **RTL:**
    - `dbg/karudbg_auth.v`;
    - `dbg/karudbg_island.v` (island ROM `0x1_0000–0x1_FFFF`, island SRAM
      `0x2_0000–0x2_3FFF`, with a matching PMA entry);
    - the gates in `karudbg.v` and `karu64.v`, and the CSR decode in
      `karu_csr.v`;
    - integration in `karudbg_core.v` and `karudbg_top.v`.
  - **Relock:** a Debug-Mode hart is reset on the cycle after the gate
    falls, so *k* = 1. The bound has no counter to configure.
  - **Invariants:**
    - local checks in `karudbg_auth`, `karudbg` and `karudbg_island`;
    - INV42a/b in `karu_debug_assert`.
  - **`dbg-auth-test`** aggregates the following, each with mutant controls:
    - `dbg-auth-unit-test`;
    - `dbg-auth-dm-test`;
    - `dbg-auth-open-equiv-test`, a Yosys sequential-equivalence proof of the
      `OPEN` DM, base and SBA+autoexec;
    - `dbg-auth-core-test`, the real core with the simulation ROM stub;
    - `dbg-core-auth-open-test`, the full debug bench in `OPEN`. It gives the
      same check, cycle and retirement counts as without `KARU_DBG_AUTH`.
  - **Review fixes, 2026-11-15:**
    - island responses are accepted only for outstanding transactions
      (hostile-response tests: `dbg-auth-island-test`, and a forged island
      SRAM load on the real core);
    - a system reset after boot closes the window;
    - reset-cycle CSR accesses have no effect;
    - the debug-page router in `karudbg_core` accepts external responses only
      for outstanding external transactions (all debug builds);
    - the island bench now covers response backpressure, reset with
      transactions outstanding, and pipelined address acceptance.
  - The `OPEN` equivalence claim excludes the island address ranges
    (contract §7).
- [ ] **A2 — ROM.** Write the window routine for a simulation island ROM:
  request check, nonce from `seed`, challenge, bounded wait, verification
  with a test key, unlock and `boot_done`. Then write the FPGA boot-ROM
  variant.
  - Settle D3 before implementing and sizing the production verifier. The
    sizing covers ROM, island SRAM, the bounded wait and the length maxima.

  *Status: the simulation ROM and the FPGA ROM are done, and the FPGA ROM
  is board-tested; the production verifier awaits D3.* On the board, the
  VCU118 image `ddb168e1…` passed `locked`, `authenticate` (unlock 0.19 s
  after the REQUEST), `wrong-response`, `replay`, `expiry` (closed between
  14.29 and 14.35 s, by the ROM's deadline) and `entropy-off`, with
  algorithm `0x04`, each after a JTAG reconfiguration as its power-on
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)).

  **Interim D3 decision for the FPGA image.** The FPGA ROM verifies
  algorithm `0x04`, a SHA3-256 shared-secret MAC over the challenge and the
  granted mask (contract §5.1). D3 for production stays open. The key is 32
  random bytes generated once per build tree (`VCU118_AUTH_KEY` in
  `dbg/fpga.mk`, default `_build/vcu118_auth_key.txt`, never overwritten),
  compiled into the island ROM; `authlib.py` reads the same file. What it
  protects: a board whose bitstream, ROM image and key file are not shared;
  there, only a debugger with the key unlocks, a response is bound to its
  nonce (replay fails), and a one-bit change is rejected. What it does not
  protect: the key is in the ROM image and the bitstream, so anyone who has
  either can authenticate, and one key serves every board built from that
  tree. The island ROM also stays readable by software on the hart after
  the window, so code running in M-mode, or wherever PMP lets it reach
  `0x1_0000`, can read the key. The ROM clears island SRAM before it leaves
  (D1). The simulation builds use `TEST`; the SHA3 build is covered by
  `dbg-auth-rom-host-test` (known answers, cross-algorithm rejection, two
  mutants) and `dbg-board-auth-sha3-rehearsal-test` (with a public test key,
  `test/dbg/auth_rom/test_key.txt`).

  **The FPGA variant** is the same source built with other constants
  (`VCU118_AUTH_ROM_FLAGS` in `dbg/fpga.mk`):
  - the nonce comes from the Zkr `seed` CSR, as in every build of the ROM;
  - `TRNG_TRIES=200000` polls per nonce word, because the entropy source
    needs about 4.3 million clocks after reset for its start-up test;
  - the contract's window of 2^30 cycles;
  - control goes to the boot ROM at `0x1000`, and the ROM sets no trap
    vector of its own.
  `dbg-auth-window-seed-test` runs every case of the window bench again on
  a core built with `KARU_ZKR`, with the ROM reading `seed` and the entropy
  source's behavioural noise model behind it.
  It is part of `dbg-auth-test`. The ROM constants that differ only on the
  FPGA (the longer wait, the 2^30 window, the hand-over address) are
  exercised by `image-boot-test`, without a debugger.
  - The ROM is `test/dbg/auth_rom/`, written in C.
  - It implements:
    - the `REQUEST` check;
    - the nonce, from `ES16` words of `seed` only, with bounded retries;
    - the 20-word CHALLENGE, re-pushed from word 0 on any session reset
      before the response;
    - the bounded `mcycle` window;
    - every §5.3 rejection rule;
    - unlock and `boot_done`.
  - Its simulation builds use the simulation-only `TEST` algorithm
    (`0x80`), a keyed XOR fold that is not cryptographic; the FPGA build
    uses `0x04`.
  - `dbg-auth-window-test` covers, on the real core, a correct response, a
    wrong signature, algorithm, length or permission mask, re-push after
    `ABORT`, window expiry, and replay of an earlier session's response.
  - **The deadline.** The ROM checks expiry before every step that waits on
    or takes input from the host or `seed`, including each push restart,
    and once more immediately before the grant. (A first version could
    grant after `WINDOW_CYCLES`: an available RX word skipped the expiry
    check, nothing checked expiry before `AUTH_UNLOCK`, and a session reset
    restarted the challenge push before the time check. That defect is one
    of the mutants below.)
    - `dbg-auth-rom-host-test` runs the same `window.c` on a host mailbox
      model with one cycle per CSR access: responses at, before and after the
      exact deadline, queued and split responses, repeated ABORTs, a stalled
      `seed` and 400 random schedules. Four mutants must fail, one of them the
      original defect.
    - `dbg-auth-window-test` adds, on the real core, a sweep of responses
      that straddle the deadline, a response whose last word arrives after
      it, and continuous ABORTs across it. A monitor reads the ROM's deadline
      variable and `mcycle` and fails on any pop or grant later than the
      deadline plus one polling iteration (256 cycles; the uncached island
      ROM takes about 230 cycles per iteration). A ROM with the original
      defect must fail the sweep.
    - The software deadline therefore held to within one polling iteration
      in these runs. That is a measured tolerance for this ROM and core
      configuration, not a proven maximum.
    - **A hard cutoff in hardware.** `karudbg_auth` has the parameter
      `WINDOW_LOG2` (0, the default, is no limit): the window is open for
      exactly 2ⁿ clocks after the edge that accepts the `REQUEST`, then no
      unlock can commit and `boot_done` is set. The VCU118 top sets 31,
      behind the ROM's own 2³⁰, so on the board the ROM's deadline closes
      the window first and the hardware limit has simulation coverage
      only: unit cases with four mutants (`dbg-auth-unit-test`) and lemma
      C5w below. Whether a product sets it, and to what, is the
      integrator's choice (contract §5.3).
- [ ] **A3 — formal.**
  - Implement C1–C10, the composition report, the sanity runs and the negative
    controls.
  - Tooling: Yosys 0.69, `yosys-smtbmc`, `yosys-abc` and z3 are installed. Add
    SymbiYosys under `$RISCV`, or drive the existing tools directly.

  *Status: partial. Lemmas C1 to C10, C3n, C5w and C9own and the
  composition report are implemented: on the sources of 2026-11-19,
  `make dbg-auth-formal-test` passed (16 entries, 111 controls) and
  `make dbg-auth-compose-test` found no undischarged assumption
  ([current record](../dbg/README.md#current-combined-validation-record)).
  Two findings are open, so A3 is not complete: fetch-to-execute
  provenance, and the image's configuration for the core lemmas C4, C6cone,
  C8 and C10 (below). Some steps of the composition are argued, not
  machine-checked; the report lists them.*
  - `dbg-auth-formal-test` (`test/dbg/run_auth_formal.py`, property blocks in
    `test/dbg/formal/`) drives Yosys and `yosys-smtbmc`/z3 directly. For each
    lemma it runs BMC, k-induction where an unbounded result is claimed, and
    mutants that must fail. Each result holds for the stated properties under
    the stated assumptions, and for the module named:

    | Lemma | Kind of proof |
    | --- | --- |
    | C2 | Unbounded (k=8) |
    | C5 | Unbounded (k=3) |
    | C9 | Unbounded (k=6) for routing and ownership; BMC depth 12 for bridge consistency |
    | C10 | Unbounded (k=2), core arbiters with submodules as free cut points |
    | C4, C8 | One-step from an arbitrary state, with submodules as free cut points: a sound over-approximation |
    | C6v, C6cone | One-step from an arbitrary state |
    | C7 | Short BMC from an arbitrary state, which covers every reachable history for its one- or two-cycle properties |

  - **What C4, C5, C6, C9 and C10 state** (as revised after the first
    external review):
    - **C5** states, from ports and ghost state only, that `boot_done` is
      set on the edge after each closing event: a trap, Debug entry or issue
      outside the ROM; any reset once the hart has run; a session reset once
      a response word was popped; the ROM's own write. It also states the
      `REQUEST` and hold rules. Seven mutants, including one with every
      automatic closing term removed, must fail.
    - **C9** assumes no request length, so it covers the bursts the core
      issues to external memory. Its one assumption is the core's
      one-outstanding-transaction contract.
    - **C10** proves that contract on the core's AXI arbiters, given that R
      and B beats arrive only for outstanding transactions, which is what C9
      guarantees at the island. Each lemma's guarantee in a cycle follows
      from the other's in earlier cycles, through registered flags; the
      composition checks the two in one model (below).
    - **C6**: `check_auth_reset.py` simulates each module in four states for one reset edge from an unknown state with
      unknown inputs, and requires every flop bit to be 0, a listed non-zero
      constant, or an allowlisted unreset payload register. That catches a
      wrong constant, an inverted polarity, a missing reset and a wrong
      reset net. It also checks that each instance in `karudbg_core` takes
      the intended reset net. Five negative controls must fail
      (`--self-test`). **C6v** proves the input-dependent POR values of
      `karudbg_auth`; **C6cone** proves the composition of the hart-side
      reset. Five bridge registers (`rd_error`, `wr_error`) are unreset
      payload, qualified by reset valid flags, and allowlisted.
    - **C4** also proves `debug_mode=0` after any reset cycle.
  - The island SRAM is deliberately not reset and keeps its contents across
    hart and system resets. A production ROM must not leave secrets in it.
  - C8 led to a hardening: a CSR access in a trap or Debug-entry cycle has no
    authentication effect (`auth_fire_o` excludes `trap_req`).
  - **Limits:** C6 covers the three debug modules and the core's
    `debug_mode`, not every flop in the core cones of C4 and C8. The
    property and assumption blocks have had two external reviews.

  **C3 and C8.** Both are in `dbg-auth-formal-test`.
  - **C3**, unbounded (k = 6): `test/dbg/formal/c3_miter.v` instantiates
    `karudbg` twice with the same DMI inputs (K1), the same mailbox side of
    the authentication block and the gate closed since POR, and free,
    separate hart, debug-page and SBA inputs. In every cycle after reset,
    the first one included, the two give the debugger the same handshake
    (`req_ready`), the same responses and the same words to the mailbox.
    For the induction the proof uses a formal-only copy of `dbg/karudbg.v`
    with one extra output carrying `dmactive_q`, `deact_pending_q` and
    `cmd_state_q`; their equality across the copies, and an idle command
    engine, are asserted and proved too (the repository file is unchanged).
    Controls: the locked DMI view removed; hart state put into the locked
    `dmstatus`; and `data0` made a channel, which needs all three of the
    write gate, the locked-state clearing and the read gate removed — any
    one of them alone keeps it shut.
  - **C8** also proves, in every cycle and not only on a commit, that the
    issue signal reaching `karudbg_auth` is the core's and, on every issue,
    that the PC is the issuing instruction's: the window closes on any
    issue outside the ROM. Two more controls (issue reported only for CSR
    instructions; the PC taken from fetch).
  - The runner now refuses a model in which Yosys declared a name
    implicitly: a hierarchical reference into a submodule becomes a free
    wire, and an assertion over it would prove nothing.

  **The composition.** `make dbg-auth-compose-test`
  (`test/dbg/run_auth_compose.py`, about 15 minutes, not in the gate)
  builds a single model for C9 with C10 and the composition report, and
  reports what it could not close. It runs with T1 as worded below, the
  image's define list of lemma C1, and lemmas C3n and C9own. An external
  reviewer read the script and its lemmas and asked for those two lemmas
  and for the distinction between the image's runs.
  - **One model for C9 with C10.** A build copy of `karudbg_core` keeps the
    core's own logic and the island on the real nets and the real reset;
    the core's submodules, the other debug instances and the fabric's
    responses are free. The repository's C9 and C10 blocks are both in it,
    with each block's three assumptions about the other side turned into
    assertions, and a link between the island's flags and C10's ghost
    flags, and lemma C9own's block is in the island copy as well. BMC
    depth 12, and k = 2 induction for 76 of the 82 assertions; C9's six
    bridge-consistency assertions stay bounded at depth 12, as in C9.
    Proved with C1's defines, C10's and the VCU118 image's define list (see
    "three runs" below for what that last one is). Thirteen controls fail
    on the intended assertion. The only assumption is a hart
    reset in the first cycle: C9 and C10 alone assumed none later, although
    `hart_reset_i` is an adversary input. The core's bus contract of
    section 9 is therefore no longer an assumption.
  - **The report.** All 27 `assume()` statements and 19 model restrictions
    of the lemmas are matched to the assertion or the platform assumption
    that discharges them; a missing or stale entry fails the run. Thirteen
    implications are checked by the solver, and 82 wiring pairs are read
    from the netlist of `karudbg_core`.
  - **Gaps it found between the lemmas, and closed**: the first five by
    four glue lemmas (`gate`, `dm`, C2n, C3n; 16 controls), the last by
    running the core lemmas again:
    - C7 assumes that `debug_enable_o` is `debug_enable_next_o` one clock
      later; nothing proved it of `karudbg_auth`;
    - C2 and C3 assume `debug_enable_next_i = 0` always, so they did not
      cover the cycle in which the unlock commits (C2n, C3n);
    - no lemma covered the DM's outputs in the first cycle after POR;
    - nothing said that `dmstatus` hides hart state after a revocation;
    - C3's shared `authbusy` and "authdata implemented" inputs rested on
      properties of `karudbg_auth` that no lemma stated;
    - the lemmas shared no configuration: the core lemmas are now proved
      with C1's defines as well.
  - **T1's declassified channel.** C3 gives two runs the same authdata
    read data, which includes the status word, and the status word depends
    on hart activity and its timing: two runs with the same DM side and the
    same TX pushes can read different status words (the report has the
    witness). So T1 names the read data, status included, as the
    declassified channel. The script reads the bullet from this file: with
    a wording that names only the TX words, or with `--tx-words-only`, it
    fails on this item.
  - **Three runs touch the VCU118 image's configuration, and they are not
    one configuration.**
    - The single model's run named `image` uses the image's define list
      only (`IMAGE_DEFINES` in `check_auth_bypass.py`). It elaborates
      `karudbg_core` with its default top-level parameters and, like every
      run of that model, cuts out the authentication block. It is evidence
      for the bus ownership property of C9 with C10 under those defines,
      and for nothing else of the image.
    - Lemma C1's `--image` inventory is the run with the image's
      parameters as well (`IMAGE_PARAMS`: the island reset vector,
      external time, `AUTH_WINDOW_LOG2` = 31) and with the I-cache in the
      fetch path. The composition script does not make it; the gate does.
    - The window timer at width 31 is lemma C5w31.
    - C4, C6cone, C8 and C10 are not run with the image's defines.
  - **Open: fetch-to-execute provenance**, for the image as for every
    configuration. T2's "fetched from the island ROM" rests on the core's
    fetch path being correct: no lemma states that the word at EX is the
    word the imem port returned for that PC, and section 9 does not list
    it as an assumption. C8 checks the PC range of the committing
    instruction; C9, C9own and the single model check which side answers
    a bus request.
  - **Argued, not machine-checked:** the inductions over cycles from the
    per-cycle lemmas, the CSR decode of the authentication CSRs and the
    JTAG path. The report lists all eighteen steps; two findings are open
    (the fetch path, and the image's configuration for the four core
    lemmas).

  **Lemmas C3n and C9own**, from the second external review. Both are in
  `make dbg-auth-formal-test` or the composition.
  - **C3n with separate next-state inputs.** In the cycle before a grant
    takes effect both DMs of the C3 miter are locked and their next states
    can differ, because the grant depends on what the hart does. Under
    `C3_SPLIT_NEXT`, which C3n sets, the miter has a next-state input for
    each DM; lemma C3 holds the next state at 0. BMC depth 10 and induction
    pass. Three controls show the next state to a locked debugger (in
    `dmstatus`, in the DMI ready, in the response code): each fails with
    separate inputs and passes with a shared one, and the script checks
    both, so a shared input would hide them.
  - **C9own, response ownership for the whole transaction.** C9 checked
    the owner flag one cycle after an address was accepted and worded its
    later checks with the router's own flags. C9own
    (`test/dbg/formal/c9own_karudbg_island.vh`, spliced after C9's block,
    no assumption of its own) keeps ghost state that reads neither the
    owner flags nor the address decode: the destination of each accepted
    address, held through stalls and bursts.
    - On the imem read, dmem read and dmem write channels it asserts:
      with no transaction outstanding no beat is shown to the core and
      none is taken from downstream; during the island's transaction the
      core sees exactly the island bridge's beat (valid, ID, data,
      response code, LAST), the bridge sees the core's READY and
      downstream sees none; and the same with the sources swapped.
    - 44 assertions; BMC depth 12 and induction (k = 2) on the island
      with free inputs, every C9 assertion proved again in the same
      model. C9's six bridge-consistency assertions stay bounded.
    - 56 controls, each failing on an assertion of the new block, and
      each of the 44 assertions fails in a control written for it. Among
      them: the response selected by the address of the moment, the owner
      latched a cycle late or not at all, the outstanding flag cleared by
      any beat, the ID from the wrong side, LAST forced, a downstream
      error reported as OKAY, READY reaching the side that does not own
      the transaction, and part of the island's range routed downstream.
    - The block is also in the single model.
    - Not claimed: the island bridge does see the core's READY when no
      transaction is outstanding and the last one was the island's (the
      RTL gates that READY with the owner flag alone). It has no beat to
      give then, which only C9's bounded assertions say.
    - Not checked, because it is bridge and memory correctness and not
      ownership: that a response's ID is the accepted address's, the
      bridge's beat count, the routing of the W channel, and that island
      data is the word at the accepted address.
  - **Seen while doing this, not acted on:** the downstream address and
    write-data outputs are unconditional copies of the core's, so an
    island request's address and write data are on the downstream wires
    with VALID low. No lemma looks at payload when VALID is low.

  **Lemma C5w, the window timer.** Proved on
  `karudbg_auth` with `WINDOW_LOG2` 1, 3 and 31, unbounded (k = 3), from
  ports and ghost state (a count of the clocks since the accepted
  `REQUEST`), with every C5 property proved again in the same model:
  `boot_done` is set at the latest 2ⁿ + 1 edges after the accepting edge;
  the grant never rises on that edge or later; before it, the commit
  predicate still grants and `boot_done` still needs a closing event, so
  the window is not shorter either. Eleven controls at n = 3 each fail on
  one of these. A second entry, C5w0, shows that the limit is off at the
  default: the guard on the parameter deleted passes C5 alone and fails
  there. The reset check now has an entry for the block with the timer
  present, because at the default Yosys removes the counter. Not covered:
  values of n other than these, and the pass-through of the parameter in
  `karudbg_core` and `karudbg_top`.

  **C1, as a structural check only.**
  `dbg-auth-bypass-test` (`test/dbg/check_auth_bypass.py`, part of
  `dbg-functional-gates`, about 80 s).
  - **Model.** Yosys flattens `karudbg_top` from `dbg/karudbg.f` with
    `KARU_DBG KARU_DBG_AUTH KARU_DBG_FULL KARU_NO_V`. The script computes
    bit-level cones of influence over that netlist. Bitwise cells and
    flip-flops connect bit *i* to bit *i*, plus select, enable, clock and
    reset; every other cell, memories included, connects all inputs to all
    outputs. Yosys `select` cones work on whole wires and cells, which is too
    coarse here.
  - **Crossing a cut.** A cut signal is a port of a named instance. Going
    backward from a protected element, a path crosses an input-port cut when
    it leaves a cell inside the instance for a bit of that port, and an
    output-port cut when it leaves a cell outside the instance. The
    traversal stops there, at another protected element's state, or at a
    top-level input; what it reaches is the element's frontier.
  - **Cuts as implemented** refine §5.1:
    - K1 gains K1.mbox, the DM's outputs to the mailbox. The DM passes the
      `authdata` word through as a wire, so its K1 port alone does not
      separate the mailbox from JTAG.
    - K2 includes `core_in_reset_i`.
    - K3 has a hart side and an external (selector) side.
    - K4 adds the DM's hart-side inputs, all free in C2, C3 and C7.
    - K5 is the set and clear terms of the `debug_mode` flop.
  - **Checked.** Each protected element's frontier must equal an
    allowlist: 118 entries in all, each with its reason. The elements are
    `debug_mode`, the `karudbg_auth` state, the DM state, island SRAM, other
    island state, and the island's response outputs. A new entry fails, and
    so does a vanished one. An entry is a source (an input, a cut signal or
    another protected element) that reaches the element: a further path
    from a source already allowed changes no entry and is not reported.
    - Every K2 signal is the hart's own sideband signal, and every island
      request input is the hart's own port.
    - Only handshakes, never external data, reach island state.
    - Two adversary inputs reach protected state without crossing K1–K5,
      and both are allowlisted: `hold_strap_i` reaches the auth state (C5),
      and `hart_reset_i` reaches `debug_mode`, island state and
      `core_in_reset_i` through the hart reset (C4, C5, C6cone, C9). So
      "nothing other than the hart's CSR file reaches K2" is not true of
      `core_in_reset_i`, and §5.1 lists no reset cut.
  - **Controls.** Five mutants must each fail with their expected
    violation: SBA writes routed into the island (§5.4), the DMI word ORed
    into the K2 write data, a DMI request resetting the hart, the DM halt
    request setting `debug_mode` beside K5, and a stale-inventory control.
  - **Limits.** The check is structural only: a path counts whether or not
    it can carry a value, and the gate functions are C2–C9's. `virt_i` is
    constant without `KARU_H`, and the configuration above has neither H nor
    Zkr.
  - **The image's configuration:**
    `dbg-auth-bypass-image-test` (`--image`, also in the gate, about three
    minutes) elaborates the VCU118 debug image's defines, H, the vector unit
    and `KARU_ZKR` included. It passes with exactly two additions, both
    stated in the script: `K2.virt_i`, live with H, reaches the
    authentication and DM state through K2 and is driven only by the hart's
    `auth_virt_o`; and the new top-level input `zkr_rdata_i`, classified as
    adversary, reaches no protected element directly.
    The define list is the one Vivado's `synth_design` is given, less the Ethernet and
    DDR4 defines, which name nothing inside `karudbg_top`, and the
    parameters are those `vcu118_ddr_top` binds: `RESET_PC` in the island
    ROM, `EXT_TIME` = 1, `AUTH_WINDOW_LOG2` = 31, and an island ROM image
    (the simulation's SHA3 build with the public test key: the image's own
    holds the key). The inventory passes unchanged, with the same two
    additions: 6 protected elements, 133 cut signals, 120 allowlisted
    paths, 40 cut-signal drivers. The netlist has the 32-bit window
    counter and the instruction cache.
- [ ] **A4 — simulation.**
  - DM and mailbox unit tests, including the protocol's empty/full, error,
    `CLOSED` and `authbusy` rules.
  - Actual-core four-state tests:
    - the exact §2.4 sequence, with a correct signature, a wrong signature, a
      replayed signature, a late signature, and no request;
    - `haltreq` held across POR while locked (ignored);
    - a system reset during the window (closes it);
    - a trap during the window (closes it);
    - revocation with an SBA transaction in flight;
    - revocation with the hart halted: the debugger sets `fw_lock` by an
      abstract CSR write from Debug Mode, which is reachable on a single
      hart, and `revoke_i` is asserted at block level and on the core;
    - `lc=DISABLED`.
  - Pinned pristine OpenOCD:
    - examine fails with its authentication message;
    - then a Tcl `authdata` script performs the §2.4 sequence and
      re-examination succeeds;
    - a reconnect, with its `dmactive` pulse, keeps the grant.
  - Rerun the existing `dbg-*` gates with `lc=OPEN`.

  *Status: partial. General four-state runs, a trap during the window on
  the real core, and the items under "Still not covered" below remain, so
  A4 is not complete.*
  - **Done:**
    - mailbox and DM unit tests;
    - the real-core flows of `dbg-auth-core-test` and `dbg-auth-window-test`;
    - `haltreq` while held;
    - a system reset in the window;
    - revocation from Debug Mode and by `revoke_i`;
    - `DISABLED`, at unit and DM level;
    - pristine OpenOCD (`dbg-auth-openocd-test`: locked examine refused,
      authenticate, `arp_examine`, grant across a `dmactive` pulse, rejected
      response stays locked);
    - a replayed response failing on a fresh nonce, with a `seed` stand-in
      (`test/dbg/karudbg_test_seed.v`, an LFSR) in `dbg-auth-window-test`;
    - `OPEN` regression (`dbg-core-auth-open-test`).
  - **Open:**
    - four-state runs, beyond the revocation scenario below;
    - a trap during the window on the real core (covered at unit level).
  - **Pristine OpenOCD against the framed C ROM of A2.**
    `dbg-auth-openocd-test` uses a one-word ROM stub;
    `dbg-board-auth-rehearsal-test` drives the CHALLENGE and RESPONSE
    frames end to end through OpenOCD with the board's client
    (`test/dbg/board/authlib.py`): locked examine, a correct response, a
    wrong one, a replay, a fresh nonce after another power-on reset, expiry
    and the straps, with four client mutants.
  - **Revocation with an SBA transaction in flight**, on the real core (`dbg-auth-sba-revoke-test`, in
    `dbg-functional-gates`; Icarus four-state with `KARU_ASIC`, 24
    scenarios in about 6 s). The hart keeps using the data bus. The bench
    holds part of an authorized SBA access on the dmem port and revokes:
    - with the R beat of a read or the B beat of a RAM write held, released
      from one edge before the fall to 40 after (`revoke_i`), and once with
      the fall produced by the hart setting `fw_lock`;
    - with the AR or AW still stalled at the fabric;
    - with a request the bus has not yet accepted, which is withdrawn;
    - with the hart in Debug Mode and the R beat withheld for good: the
      relock reset, one cycle after the fall, cancels the transfer (§3.5
      item 3).

    The checks are on the dmem port and the DMI. The accepted transfer
    completes with exactly one address and one response, and the AXI
    handshakes hold. No sbcs, sbaddress0 or sbdata access after the fall
    reaches the bus. Every later DMI read returns the locked view and none
    carries the read data. The hart's own loads and stores complete
    afterwards. Three RTL mutants are each caught by the intended check:
    the SBA engine gated by `dmactive` alone, the drained data returned over
    DMI (four layers removed), and the response not absorbed after the fall,
    which leaves the hart without the bus.
  - **A liveness limit, not a test gap:** a responder that withholds its
    beat while the hart runs. No bounded cancel exists for it (§3.5 item 2).
  - **Other configurations, the crossbar and the JTAG transport:**
    `dbg-auth-revoke-ext-test` (`test/dbg/run_auth_revoke_ext.py`, the same
    bench in compile-time variants; in the gate, about four minutes). Twelve
    configurations, 334 scenario runs, 12,444 checks; each configuration
    must report the reference's scenarios and detect the three mutants (36
    mutant builds).
    - **Configurations of the bench:** two-state Verilator (also from random
      initial values), the instruction cache, the RVA23 build and a build
      with the vector unit, in which vector loads and stores share the data
      bus with the SBA; four-state for each of them as well.
    - **The DDR crossbar as responder:** `karu_ddr_xbar` with its assertions
      and `karu_axi4_ram` behind it, 36 scenarios: the 24 with the beat held
      on the DDR side, and twelve of its own (the beat held on the core
      side, the crossbar's local engines, a stalled read or write address).
      Three scenarios differ from the RAM-model bench for reasons in the
      crossbar: an outstanding SBA read of main memory occupies its one
      read engine, so the hart cannot fetch and cannot set `fw_lock` (the
      `fw_lock` scenarios read the scratch SRAM instead). That is the
      liveness limit of §3.5 item 2, and with the crossbar it also keeps
      firmware from revoking.
    - **The JTAG transport:** TAP, DTM and clock-domain crossing in front of
      the DMI, 29 scenarios: the 24, and five with an `sbdata0` read in the
      crossing when `debug_enable` falls. A read the DM accepts one clock
      after the fall returns zero on TDO; one accepted at or before it
      returns the data, which §3.5 item 1 allows.
    - **Still not covered:** OpenOCD on this path; the crossbar and JTAG
      together; the real Ethernet device in four-state (its model does not
      start in Icarus; an idle stand-in is used); a DDR read latency other
      than one; the DTM's busy path; acceptance on the falling edge itself
      (C7, at DM level). No RTL defect was found.
- [x] **A5 — FPGA.**
  - Map DIP switches to `lc` and the boot-hold strap.
  - Extend the existing `KARU_DDR_HOST_DBG` exclusion check
    ([xcvu9p-ddr-synth.tcl](../flow/fpga/xcvu9p-ddr-synth.tcl)) to
    `KARU_DBG_AUTH`.
  - This is functional validation only (§1.1).

  *Status: done.* The VCU118 debug image, bitstream `ddb168e1…`, contains
  it and meets timing at 75 MHz
  ([measurements](../dbg/MEASUREMENTS.md#fpga-image--2026-11-20)). On the
  board, `locked`, `authenticate`, `wrong-response`, `replay`, `expiry` and
  `entropy-off` pass with this image
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-20.md)); `open`, `fresh-nonce`,
  `no-hold`, `disabled` and the two software-reboot cases (a reboot keeps
  the grant, and keeps a locked boot locked) last ran with the `TEST` ROM
  of image `d7ff00dc…`
  ([record](../dbg/BOARD_ACCEPTANCE-2026-11-18.md)). The switches read back
  as set, and the CPU reset button is the straps' power-on reset. This is
  functional validation only (§1.1): the key is in the bitstream.

  `KARU_DBG_AUTH` is part of the default debug image
  (`VCU118_DBG_EXT_DEFINES`). Against the four points above:
  1. **Island placement.** The island keeps its default addresses, so the
     contract, `karudbg_island` and the PMA entry are unchanged. Instead the
     boot ROM is 2 MiB and its layout leaves core `0x1_0000..0x2_3fff`
     empty; the packer rejects an image that puts anything there. The
     larger ROM range also spans the Debug Module's private page at
     `0x12_0000`: that page is kept out of the ROM in the access
     permissions and in the layout.
     `RESET_PC` is `0x1_0000` and the window ROM jumps to fu-boot at
     `0x1000`.
  2. **Lifecycle and strap.** DIP switches 1 and 2 are `lc`, switch 3 the
     boot-hold strap. All off is `OPEN`, which is the fallback if anything
     in the authentication path misbehaves.
  3. **Entropy.** The ring-oscillator entropy source of the Zkr work
     (`flow/fpga/karu_rosc_rng.v`, `rtl/karu_entropy.v`), read through
     `seed`. No min-entropy is claimed for it
     ([SP 800-90B assessment](sp800-90b-assessment.md)).
  4. **Exclusion check.** `xcvu9p-ddr-synth.tcl` refuses `KARU_DBG_AUTH`
     without `KARU_DBG`, with `KARU_DDR_HOST_DBG`, or without the island ROM
     image.
  Also: `auth_reset_o` joins `ndmreset` at the reset sequencer; the software
  reboot is a system-class reset, so it closes the window like any reset
  after the first boot (section 2.2), and only power-on reopens it.
  `make image-boot-test` boots the composition in lifecycle `OPEN` and
  `AUTH` (no debugger). The authentication protocol itself is covered by
  `dbg-auth-test` on `karudbg_core`, not on this top. For the board there
  is a host client and a phase script (`test/dbg/board/authlib.py`,
  `auth_phase.py`), rehearsed with pristine OpenOCD against the simulated
  target running the real window ROM; [the board test plan](../dbg/BOARD_TEST_PLAN.md)
  has the runs.
- [x] **A6 — measurements.** Mapped area and timing in
  [dbg/MEASUREMENTS.md](../dbg/MEASUREMENTS.md), including the island SRAM.

  *Status: done for the RTL of 2026-11-18; not remeasured since the
  authentication block lost its TRNG port and gained the window timer.*
  Authentication logic is estimated at about 21.9 kGE (+0.50 % of full
  debug), partly from a reduced-memory probe and without ASIC memory macros;
  a 64 KB island ROM and a 16 KB island SRAM come on top as macros. Full
  debug costs +35.5 kGE (+0.81 %) over no debug. The mapped full-debug
  netlist misses 200 MHz by 1.08 ns on a vector-unit path. See
  [the measurements](../dbg/MEASUREMENTS.md#mapped-area-and-200-mhz-timing--2026-11-18).
- [ ] **A7 — documentation.**
  - The README's Authentication row.
  - The ASIC handoff obligations: island, lifecycle integrity, entropy
    source, strap and scan policy.
  - A dated S6 follow-up in the review.

  *Status: in progress, to be completed with A2 to A4.* The top-level
  README, the [FPGA guide](fpga.md) and the
  [ASIC handoff](../flow/asic/README.md#debug-authentication-obligations-karu_dbg_auth),
  with its entropy-source obligations, describe `KARU_DBG_AUTH` as it is:
  the VCU118 debug image verifies a SHA3-256 MAC under a key held in the
  bitstream, which validates the mechanism and protects nothing on the
  FPGA. S6 stays open for deployment.

## 8. Open decisions

| ID | Decision | Recommendation |
| --- | --- | --- |
| D1 | Whether the island SRAM must be scrubbed at `boot_done` | Not needed for confidentiality (verification uses public data). Scrub it if the ROM ever handles secrets. |
| D2 | Offer a locked-DM "reset into window" command | No. Use the physical strap (§2.4). If offered, make it an integration parameter and document the reset capability it grants. |
| D3 | Signature algorithm and verifier location | ROM verifier first. Choose ML-DSA-44, Ed25519 or a hybrid by device lifetime and ROM/SRAM budget. A hardware verifier is the second phase. This does not block A0/A1: the frame carries an algorithm identifier and bounded lengths (§3.4). It must be settled before A2's production verifier is implemented and sized. |
| D4 | Permission granularity | One bit first. Reserve a mask in the frame (run control/Program Buffer versus SBA) and in `mdbgauth`. |
| D5 | Hold timeout | None in hardware. The strap is physical presence, and releasing it boots normally. |
| D6 | DFT and scan | The scan controller must force `debug_enable=0` and reset `karudbg_auth` on scan entry and exit. This is a platform obligation outside the proof (§9). |

## 9. Relationship to findings and limits

**Findings.**

- **S6** is closed by A1–A4 together with the A7 platform obligations.
- **S8** was fixed on 2026-11-15: deactivation is acknowledged only once the
  engine is idle. Relock deliberately does not use deactivation (§3.5).
- **S10** was fixed on 2026-11-15: `ndmreset_o` is one flop. The gated outputs
  must keep that.
- **S9** does not weaken T1–T4, because C2, C3 and C7 quantify over arbitrary
  K1 traffic. It remains a robustness fix (see the review for the corrected
  recovery).
- Prior finding **S4** is a prerequisite.
- Prior finding **S2** (no PMP) is unaffected: this gate protects the debug
  path, not M-mode from S-mode.

**Limits.** The evidence covers the RTL at the recorded hashes, under 2-state
semantics, with these stated assumptions:

- the island contents and response paths (§1.1);
- the integrity of `lc`;
- a healthy entropy source behind `seed`;
- the core's single-outstanding-per-channel contract used by C9;
- the ROM obligations of §6.

It does not cover:

- gate-level equivalence (a later LEC step can extend it);
- clock or reset glitches;
- fault injection;
- side channels in the verifier;
- scan/DFT access;
- the cryptographic strength of the chosen algorithm;
- FPGA configuration access.
