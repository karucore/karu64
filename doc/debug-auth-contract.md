# karudbg authentication contract (milestone A0)

Status: **contract, 2026-11-15**. This document closes milestone A0 of the
[authentication plan](debug-auth-plan.md) (revision 3). It fixes the
interfaces that A1 (RTL) and A2 (ROM) implement and that A3/A4 verify. When
it was written nothing was implemented.

*Status, 2026-11-17.* The RTL (A1) and the window ROM with the simulation-only
`TEST` algorithm (A2) implement this contract; see the plan's milestone notes
for what is tested and how. The VCU118 debug image is built with it, reading
its nonce from the Zkr `seed` CSR in place of `mdbgrng` (section 3), which
has the same format and take-on-write rule. Two details that the
implementation fixes more tightly than the text below, found while writing
the board client: the RTL also requires `REQUEST` bits [15:8] to be zero,
and the ROM rejects a response whose length word has bits [31:24] set.

| A0 item | Section |
| --- | --- |
| Debug 1.0 `dmactive`, `authenticated`, `authbusy`, `authdata` and Security text, with the karudbg interpretation | §1 |
| Pinned OpenOCD examine, `reset_dm` and authentication flow | §2 |
| CSR numbers and semantics | §3 |
| Mailbox header and status encodings | §4 |
| Frame layout, algorithm identifiers and length maxima | §5 |
| Decisions D1–D6 | §6 |
| `lc=OPEN` equivalence requirement | §7 |

## 1. Debug 1.0 text and interpretation

### 1.1 Normative text

Quoted from the ratified specification,
[Debug Module chapter](https://docs.riscv.org/reference/debug/v1.0/debug_module.html).
These are short excerpts; the linked text is authoritative.

**`dmcontrol.dmactive`** (§3.1.14):

- "This bit serves as a reset signal for the Debug Module itself."
- "After changing the value of this bit, the debugger must poll dmcontrol until
  dmactive has taken the requested value" before relying on the new state.
- "Hardware may take an arbitrarily long time to complete activation or
  deactivation" and "will indicate completion by setting dmactive to the
  requested value." "During this time, the DM may ignore any register writes."
- 0 (inactive): "The module's state, including authentication mechanism,
  takes its reset values"; only `dmactive` can be written to a non-reset value,
  and "Any accesses to the module may fail."
- 1 (active): "The module functions normally."

**`dmstatus.authenticated`** (§3.1.14): 0 means "Authentication is required
before using the DM"; 1 means "The authentication check has passed." "On
components that don't implement authentication, this bit must be preset as 1."

**`dmstatus.authbusy`** (§3.1.14): 1 means "The authentication module is busy.
Accessing authdata results in unspecified behavior." "authbusy only becomes
set in immediate response to an access to authdata."

**`authdata`** (DMI 0x30, §3.1.14): a 32-bit serial port to and from the
authentication module, usable while `authbusy` is clear. The specification
defines no overflow or underflow signal. This summary was not checked against
the verbatim text and is not quoted.

**Security** (§3.1.12):

- "Between authenticated, authbusy, and authdata arbitrarily complex
  authentication mechanism can be supported."
- "When authenticated is clear, the DM must not interact with the rest of the
  hardware platform," "nor expose details about the harts connected to the DM."
- "All DM registers should read 0, while writes should be ignored", except
  that `authenticated`, `authbusy` and `version` in `dmstatus` are readable,
  `dmactive` is readable and writable, and `authdata` is readable and
  writable.

### 1.2 karudbg interpretation

| Topic | Contract |
| --- | --- |
| `authenticated` | Reads `debug_enable` from `karudbg_auth`. In `lc=OPEN` it is 1, as today and as required for components without authentication. |
| Locked register view | When `debug_enable=0`, every DM register reads 0 except `dmstatus` and `authdata`. `dmstatus` reads exactly `version=3`, `authenticated=0` and `authbusy`; every other `dmstatus` field reads 0. `dmcontrol` reads only `dmactive`. Writes other than `dmcontrol.dmactive` and `authdata` are ignored. This replaces the plan's earlier "hart fields read as unavailable", which the Security text rules out. |
| "Must not interact with the platform" | While locked, the DM issues no halt, resume, reset or SBA request, and serves the hart only ROM and safe-sequence words (plan §3.2). The authentication module, `karudbg_auth`, is not the DM. Its mailbox and the boot-hold release are the authentication mechanism that Security permits. The release needs the physical strap (plan §2.4). |
| `dmactive=0` resets the authentication mechanism | Deactivation resets the mailbox session: FIFOs, operation state, errors, `authbusy` and a pending `REQUEST`. It does not reset the platform grant (`auth_unlock`), which is a POR-domain lifecycle input (plan §2.3). Re-authentication per DM session is rejected because the window opens once per POR. |
| Deactivation timing | Acknowledged only once the abstract command engine is idle (S8 fix). This is allowed by "arbitrarily long time". While deactivation is pending, the DM functions normally and does not ignore writes. |
| Revocation | Revocation by any source in §3.4 never waits for deactivation. It blocks new work at t₀+1 and resets a Debug-Mode hart within *k* cycles (plan §3.5). |
| `authbusy` | Set only in the cycles that immediately follow an `authdata` access. It is never tied to FIFO state or ROM progress. |
| `hartinfo` | Reads 0 while locked; the optional-register rule allows all-zero. |

## 2. Pinned OpenOCD flow

The source is OpenOCD `cb0c224e9` with `dbg/openocd-no-autoexec.patch`, built
by [dbg/build_openocd.sh](../dbg/build_openocd.sh). The pristine binary in
`$RISCV` is the same revision. The relevant functions are in
`src/target/riscv/riscv-013.c`.

1. **`examine`** checks DTMCS and then calls `examine_dm`.
2. **`examine_dm`** calls `reset_dm` once per DM: `was_reset` is set on success
   and survives a failed examine.
3. **`reset_dm`** reads `dmcontrol`. If `dmactive=1`, it writes 0, keeping
   only `hartsel`, and polls until `dmactive` reads 0, with
   `riscv set_command_timeout_sec` as the timeout. It then calls
   **`activate_dm`**, which writes `dmactive=1` and polls until it reads 1.
4. **Hart enumeration** writes `hartsel` all-ones with `hasel` and reads it
   back. For each hart it calls `dmstatus_read(..., authenticated=true)`,
   which fails with "Debugger is not authenticated to target Debug Module
   ... Use `riscv authdata_read` and `riscv authdata_write` commands to
   authenticate." A locked DM therefore fails examine here, before `hartinfo`
   or `abstractcs` is read. The `version` field must read 3 even when locked.
5. **`riscv authdata_read` and `riscv authdata_write`** do not need an
   examined target. Each first polls `dmstatus.authbusy` low, without the
   authentication check, then makes one DMI access. A write polls `authbusy`
   again afterwards. If `authenticated` rose across that write, it
   re-examines every target on the DM; `was_reset` is set, so there is no
   second `dmactive` pulse.
6. **A new OpenOCD process** pulses `dmactive` again in `reset_dm`.

Consequences for the RTL and the host script:

- **R1.** Deactivation of an idle DM must complete well within OpenOCD's
  command timeout. It completes in one cycle today.
- **R2.** `authbusy` must clear within a few cycles of every access, so
  `wait_for_authbusy` cannot time out.
- **R3.** The ROM verifies asynchronously, so no timing relationship between
  the final `riscv authdata_write` and the rise of `authenticated` is
  guaranteed. With `TEST`, it may rise within that write's trailing `authbusy`
  poll. The host script handles both cases:
  - If OpenOCD reports "authdata_write resulted in successful authentication",
    it has already re-examined the targets.
  - Otherwise the script polls `dmstatus` directly with `riscv dmi_read 0x11`,
    a raw DMI access that needs no examined target, until bit 7
    (`authenticated`) is 1 or a host timeout expires. It then runs
    `$_TARGETNAME arp_examine`, which re-enters `examine_dm` without a
    `dmactive` pulse.

  The mailbox status word carries no `authenticated` bit; the script may read
  it only to see a RESULT frame or errors. A4 must confirm both paths with the
  pinned binary.
- **R4.** The grant must survive the `dmactive` pulse of a reconnect (§1.2).

## 3. CSRs

All five CSRs exist only with `KARU_DBG_AUTH`; without it, an access raises
illegal instruction, as today. They are M-mode only: from S, U, VS or VU an
access raises illegal instruction, with the usual priority. They are not
memory mapped.

| Number | Name | Access | Purpose |
| --- | --- | --- | --- |
| `0x7C0` | `mdbgauth` | Read; write-1-to-set | Grant and lifecycle state |
| `0x7C1` | `mdbgrx` | Read-write access only | Pop one RX word (host → ROM) |
| `0x7C2` | `mdbgtx` | Write; reads return 0 | Push one TX word (ROM → host) |
| `0x7C3` | `mdbgrng` | Read-write access only | Pop one TRNG word |
| `0xFC0` | `mdbgmbst` | Read-only | Mailbox counts, errors and session state |

`0x7C0–0x7C3` lie in the machine custom read/write range and `0xFC0` in the
machine custom read-only range. A write instruction to `mdbgmbst` raises
illegal instruction, per the CSR address convention.

**Instruction forms.** Zicsr defines which of the six CSR instructions read and
write:

- CSRRW and CSRRWI always write. They do not read when `rd=x0`, and must then
  cause no read side effect.
- CSRRS and CSRRC write only when `rs1≠x0`.
- CSRRSI and CSRRCI write only when `uimm≠0`.

For CSRRS/CSRRC and their immediate forms, the written value is
`old | src` or `old & ~src`. For each CSR:

| Form | `mdbgauth` | `mdbgrx`, `mdbgrng` | `mdbgtx` | `mdbgmbst` |
| --- | --- | --- | --- | --- |
| CSRRW / CSRRWI, `rd≠x0` | Read; written value applied as W1S | Pop; return the word | Push `rs1[31:0]` or zero-extended `uimm`; return 0 | Illegal |
| CSRRW / CSRRWI, `rd=x0` | W1S, no read | Pop and discard | Push | Illegal |
| CSRRS / CSRRC, `rs1≠x0` | Read; written value applied as W1S | Pop; return the word | Illegal | Illegal |
| CSRRSI / CSRRCI, `uimm≠0` | Read; written value applied as W1S | Pop; return the word | Illegal | Illegal |
| CSRRS / CSRRC, `rs1=x0` | Read | **Illegal** | Read 0, no effect | Read |
| CSRRSI / CSRRCI, `uimm=0` | Read | **Illegal** | Read 0, no effect | Read |

Further rules:

- **`mdbgrx` and `mdbgrng`** follow the Zkr `seed` rule. Consuming a word is a
  *write* side effect, a polling and flush action; the written value is
  ignored. Every read-only form is illegal, so a speculative or stray read
  cannot consume data. `rd=x0` discards the popped word.
- **`mdbgtx`** pushes only on CSRRW/CSRRWI, the forms whose written value is
  the source itself. The set and clear forms that would write are illegal,
  rather than pushing `0|src` or `0&~src`.
- **`mdbgauth` W1S:** each bit of the architecturally written value that is 1
  sets the corresponding W1S field, subject to that field's predicate; 0 bits
  are ignored. CSRRC therefore cannot clear anything. Reads have no side
  effects.
- **`mdbgmbst`** follows the read-only CSR address convention.

**Debug Mode.**

- `mdbgauth` and `mdbgmbst` are readable.
- In `mdbgauth`, only `fw_lock` can be set. `auth_unlock` is excluded by its
  commit predicate, and `boot_done` is already set by Debug Mode entry. A
  debugger may therefore revoke its own access, which only reduces privilege
  (§3.4).
- `mdbgrx`, `mdbgtx` and `mdbgrng` raise illegal instruction, which an
  abstract command reports as `cmderr=3`.

### 3.1 `mdbgauth` (`0x7C0`)

| Bits | Field | Access | Meaning |
| --- | --- | --- | --- |
| 0 | `auth_unlock` | W1S under the commit predicate (plan §3.1), which additionally requires `auth_req=1`: no grant without a `REQUEST` in this POR | Platform grant |
| 1 | `boot_done` | W1S; also set by `boot_exit_now` | Window closed for this POR |
| 2 | `fw_lock` | W1S, from M-mode or Debug Mode | Revoke debug until POR |
| 3 | `debug_enable` | RO | `(lc==OPEN ∨ (lc==AUTH ∧ auth_unlock)) ∧ ¬fw_lock ∧ ¬revoke_q` |
| 5:4 | `lc` | RO | 0 `OPEN`, 1 `AUTH`, 2 `DISABLED`, 3 reserved and treated as `DISABLED` |
| 6 | `hold` | RO | Hart held by the boot-hold strap. The strap is sampled at POR in `lc=AUTH` only; `OPEN` and `DISABLED` parts boot normally whatever the strap |
| 7 | `auth_req` | RO | A `REQUEST` was accepted in this POR |
| 15:8 | `perm` | RO | Granted permission mask; bit 8 is full debug (D4), and bits 9–15 read 0 |
| 23:16 | `perm_req` | RO | Permission mask from `REQUEST` |
| 24 | `revoked` | RO | `revoke_q`, the latched platform revocation input (§3.4) |
| 25 | `sess_ack` | W1, reads 0 | Writing 1 clears `mdbgmbst.sess_reset`; ignored in Debug Mode |
| 63:26 | — | RO 0 | Reserved |

Setting `auth_unlock` sets `perm[0]`. Writes to read-only fields, and writes of
0 to the W1S bits, are ignored. The write-1-to-set fields change only
monotonically between PORs.

### 3.2 `mdbgrx`, `mdbgtx`, `mdbgrng`

Pop and push behaviour, by instruction form, is defined in §3.

- **`mdbgrx`** returns `{31'b0, valid, data[31:0]}`. If RX is empty,
  `valid=0`, the data are 0 and nothing is popped. Use it only for frame bytes.
- **`mdbgtx`** pushes `rs1[31:0]` if TX has space. Otherwise it drops the word
  and sets the ROM-side sticky `TX_FULL` error in `mdbgmbst`. The ROM checks
  space first.
- **`mdbgrng`** returns `{OPST[1:0] at 31:30, 14'b0, entropy[15:0]}`, the Zkr
  `seed` format: `OPST` is 0 `BIST`, 1 `WAIT`, 2 `ES16` or 3 `DEAD`. Only
  `ES16` carries entropy. The source and its health tests are platform
  obligations (plan §1.1); simulation uses a deterministic stub.

### 3.3 `mdbgmbst` (`0xFC0`)

| Bits | Field |
| --- | --- |
| 4:0 | RX words available (0–16) |
| 9:5 | TX free (0–16) |
| 12:10 | Session state (§4.3) |
| 13 | ROM-side sticky `TX_FULL` (cleared by `ABORT` and by deactivation) |
| 15:14 | Reserved, 0 |
| 23:16 | `perm_req` (copy) |
| 24 | `sess_reset`: sticky; set by every session reset (deactivation or `ABORT`), cleared only by the ROM writing 1 to `mdbgauth[25]`. A set in the same cycle wins over the acknowledgement |
| 25 | `resp_started`: POR-sticky; set by the first ROM pop of an RX word |
| 63:26 | Reserved, 0 |

### 3.4 Revocation sources

`debug_enable` falls only through one of these sources. Each is monotone until
POR, and revocation (plan §3.5) treats them identically:

1. **`fw_lock`** set by M-mode firmware.
2. **`fw_lock`** set by the debugger from Debug Mode, for example by an
   abstract CSR write to `mdbgauth`. This makes revocation with a halted hart
   a reachable scenario on a single-hart system, where no firmware can run.
3. **`revoke_i`**, an optional trusted platform input, latched into
   `revoke_q`. Possible drivers are a tamper detector, a lifecycle controller
   or a secure-element pin. Integrations without one tie it to 0. It is a
   trust input, like `lc` (plan §1.1).

A4 runs the halted-hart revocation test through source 2 on the real core,
and through source 3 at block level and on the core.

## 4. Mailbox on `authdata`

The FIFOs are 16 words in each direction, 32 bits per word. `authdata` is a
word-serial operation port. A **write** carries either an operation header or
one payload word of a pending `SEND`. A **read** pops TX while a `RECV` is
pending, and otherwise returns the status word.

### 4.1 Header encoding (`authdata` write, no `SEND` pending)

| Bits | Field |
| --- | --- |
| 31:28 | Operation |
| 27:24 | Reserved; must be 0, otherwise `BAD_OP` |
| 23:0 | Argument |

| Operation | Code | Argument | Effect |
| --- | --- | --- | --- |
| `STATUS` | `0x0` | 0 | No effect except cancelling a pending `RECV`; the next read returns status |
| `REQUEST` | `0x1` | `[23:16]` `0xA5` key; `[7:0]` permission mask | Accepted only with `lc=AUTH`, `hold=1`, `auth_req=0` and a valid mask (bit 0 set, bits 1–7 clear under D4). It sets `auth_req`, latches `perm_req` and releases the hold. Otherwise `BAD_STATE` (or `BAD_OP` for a bad key or mask) |
| `SEND n` | `0x2` | `[4:0]` n, 1–16 | The next n writes are payload into RX. If RX free < n, or n is out of range, the header is rejected with `OVERFLOW` and the following writes are parsed as headers. In `CLOSED` it is rejected with `BAD_STATE`. The status word reports the payload words still owed |
| `RECV n` | `0x3` | `[4:0]` n, 1–16 | The next n reads pop TX. If TX has fewer than n words, or n is out of range, it is rejected with `UNDERFLOW` |
| `ABORT` | `0xF` | 0 | Clears both FIFOs, pending `SEND`/`RECV` and errors. Does not clear `auth_req`, `hold` or the grant |
| other | — | — | `BAD_OP` |

**Interrupted `SEND`.** Reads never consume payload, so a host that has lost
track of a `SEND` (after a DMI error or retry, say) can read the status word.
Its `SEND remaining` field (§4.2) gives the exact number of payload words still
owed. RX occupancy cannot substitute, because the ROM consumes concurrently.

- A host that still knows its position in the frame continues with the correct
  words. The frame is intact.
- A host that has lost its position cannot complete the frame correctly. Any
  filler words would corrupt the RESPONSE and cost the attempt. It should
  instead reset the session, either with a `dmactive` pulse or by finishing the
  owed words and then sending `ABORT`.

**Effect of a session reset on the window.** Deactivation and `ABORT` clear
both FIFOs. They never clear `auth_req`, `hold` or the grant. Hardware enforces
the one-attempt rule, so it does not depend on how often the ROM looks:

- **Before the ROM has popped any RX word** (`resp_started=0`), a session reset
  only sets the sticky `sess_reset` flag. However many resets happen between
  two ROM observations, the flag stays set until the ROM acknowledges it by
  writing 1 to `mdbgauth[25]`. The ROM then re-pushes the same CHALLENGE (same
  nonce) and acknowledges.
- **Once the ROM has popped an RX word**, or in the same cycle as that first
  pop, a session reset sets `boot_done` in hardware. The window closes on that
  edge and no unlock can follow. The unlock commit predicate also excludes a
  cycle with such a reset, just as it excludes `boot_exit_now`.

An earlier draft used a 4-bit epoch counter. A host could wrap it with 16
`ABORT`s between two ROM observations, so it was replaced.

### 4.2 Status word (`authdata` read, no `RECV` pending)

| Bits | Field |
| --- | --- |
| 31:28 | Magic `0x6` |
| 27:26 | Protocol version, 1 |
| 25:24 | `lc` |
| 23:21 | Session state (§4.3) |
| 20:18 | Sticky error: 0 none, 1 `OVERFLOW`, 2 `UNDERFLOW`, 3 `BAD_OP`, 4 `BAD_STATE` |
| 17:16 | Reserved, 0 |
| 15:11 | `SEND remaining`: payload words still owed (0–16; 0 means no `SEND` pending) |
| 10 | Reserved, 0. A status word is returned only when no `RECV` is pending: every read during a `RECV` returns TX data, and a `STATUS` header cancels the `RECV` |
| 9:5 | RX free (0–16) |
| 4:0 | TX available (0–16) |

The first error is retained until `ABORT` or deactivation. The status word
discloses only mailbox and lifecycle state, never hart state.

### 4.3 Session state

| Code | State | Condition |
| --- | --- | --- |
| 0 | `IDLE` | `lc=AUTH`, `boot_done=0`, no hold. The hart boots normally, and `REQUEST` is refused |
| 1 | `HOLD` | Hold asserted and no request |
| 2 | `REQUESTED` | `auth_req=1` and `boot_done=0`: the ROM's window is running |
| 3 | `CLOSED` | `boot_done=1`, or `lc≠AUTH`. `REQUEST` and `SEND` are refused; `STATUS`, `RECV` and `ABORT` still work |
| 4–7 | — | Reserved |

The plan's separate `WINDOW` state is folded into `REQUESTED`. Hardware cannot
observe the ROM's progress without the ROM telling it, and that progress is a
frame-level matter.

## 5. Frames (ROM protocol)

Frames are sequences of little-endian 32-bit words carried by the mailbox; the
hardware never parses them. Every frame starts with one header word:

| Bits | Field |
| --- | --- |
| 31:24 | Frame type: `0x01` CHALLENGE (TX), `0x02` RESPONSE (RX), `0x03` RESULT (TX) |
| 23:16 | Frame version, 1 |
| 15:8 | Algorithm identifier |
| 7:0 | Reserved, 0 |

### 5.1 Algorithm identifiers

| ID | Algorithm | Signature bytes |
| --- | --- | --- |
| `0x00` | Invalid | — |
| `0x01` | Ed25519 | 64 |
| `0x02` | ML-DSA-44 | 2420 |
| `0x03` | Hybrid: ML-DSA-44 followed by Ed25519; both must verify | 2484 |
| `0x04` | `SHA3`: SHA3-256 shared-secret MAC; FPGA validation only (below) | 32 |
| `0x80` | `TEST`: simulation-only; must not be accepted by a production ROM image | 32 |
| others | Reserved; rejected | — |

The production ROM accepts the one identifier chosen under D3 and rejects every
other identifier. This is the only part of D3 fixed here.

*`0x04`, added 2026-11-18.* A shared-secret scheme, chosen on 2026-11-18 to
validate the FPGA image with something better than `TEST`; it is not the D3
production algorithm, and D3 stays open. With a 32-byte key `K` shared by
the ROM and the debugger, the signature is

    SHA3-256( K || "karudbg-auth-v1" || CHALLENGE words 0–19 || granted )

where the label is 15 ASCII bytes, the challenge is its 80 bytes with each
word little-endian, and `granted` is the granted-mask byte; the 32 digest
bytes are sent as 8 little-endian words. In Python:
`hashlib.sha3_256(K + b"karudbg-auth-v1" + struct.pack("<20I", *challenge) + bytes([granted])).digest()`.
The ROM (`test/dbg/auth_rom/window.c` built with `-DAUTH_ALG_SHA3`) accepts
only `0x04`, and its `TEST` build only `0x80`. Since this ROM holds a
secret, it clears island SRAM before it leaves (D1). The key is in the ROM
image and so in the bitstream: anyone who has either can authenticate.

### 5.2 Layouts

Lengths are in bytes and padded to whole words with zero bytes. The ROM
rejects nonzero padding.

**CHALLENGE (ROM → host)**

| Word | Content |
| --- | --- |
| 0 | Header (algorithm = the ROM's accepted ID) |
| 1 | `[15:0]` body length in bytes (fixed: 72); `[23:16]` `perm_req`; `[25:24]` `lc` |
| 2–9 | Device-identity digest, 32 bytes |
| 10–17 | Nonce, 32 bytes, from `mdbgrng` `ES16` words only |
| 18–19 | Monotonic POR counter if the platform has one, else 0 (8 bytes) |

**RESPONSE (host → ROM)**

| Word | Content |
| --- | --- |
| 0 | Header (algorithm ID) |
| 1 | `[15:0]` signature length in bytes; `[23:16]` granted mask |
| 2… | Signature |

The signature covers the 80 bytes of CHALLENGE words 0–19, followed by the
granted-mask byte. **RESULT (ROM → host)** is a single header word carrying
algorithm `0x00`, followed by one status word: 0 accepted, 1 rejected, 2
timeout. Whether to send it is the ROM's choice, made after the decision, and
`dmstatus.authenticated` remains the authoritative result.

### 5.3 Maxima and rejection rules

| Constant | Value |
| --- | --- |
| `MAX_SIG_BYTES` | 2560 (≥ 2484) |
| `MAX_RESPONSE_WORDS` | 2 + 640 = 642 |
| `WINDOW_CYCLES` (ROM build constant) | 2³⁰ cycles from `REQUEST` observation to decision (about 10.7 s at 100 MHz; 14.3 s at the VCU118 image's 75 MHz) |

The ROM rejects without unlocking, and then sets `boot_done`, when any of these
holds:

- the frame type or version is wrong;
- the algorithm identifier is not the one accepted;
- the signature length is not that algorithm's fixed length, or exceeds
  `MAX_SIG_BYTES`;
- the granted mask is not a subset of `perm_req`, or is empty;
- the padding is nonzero;
- the window exceeds `WINDOW_CYCLES`. The ROM checks expiry before every step
  that waits on or takes input from the host or the TRNG, including each
  restart of the challenge push, and again immediately before the grant, so
  repeated session resets cannot extend the window. This is a software
  cutoff, not a hard one: a pop or the grant can commit after the deadline by
  up to the execution time between a check and the CSR access it guards. The
  simulation ROM's tests allow 256 cycles for this, a tolerance measured for
  that ROM and core configuration (about 230 cycles per polling iteration,
  with the island ROM fetched uncached). It is not a proven maximum and does
  not carry over to other implementations. If production needs a hard
  cutoff at `WINDOW_CYCLES`, the ROM must end its window early by a justified
  worst-case margin, or expiry must be enforced in hardware; D5 currently
  chooses neither;
- `sess_reset` is set while the ROM is parsing a RESPONSE (§4.1). Hardware has
  already closed the window in this case; the rule keeps the ROM from
  continuing;
- verification fails.

With `sess_reset` set before any RESPONSE word, the ROM re-pushes the
unchanged CHALLENGE and acknowledges.

## 6. Decisions D1–D6

The plan's recommended defaults are adopted.

| # | Decision |
| --- | --- |
| D1 | No scrub of island SRAM is required at `boot_done`. The reference ROM handles only public data: the verification key, challenge and signature. A ROM that ever holds secrets must scrub before `boot_done`. |
| D2 | No locked-DM "reset into window" command. Re-entry is by POR with the physical strap. |
| D3 | **Open, scoped.** Only the algorithm-identifier field and the length maxima (§5) are fixed. The algorithm (Ed25519, ML-DSA-44 or hybrid) and the verifier location must be chosen before A2 implements and sizes the production verifier. A1 and the simulation ROM use `TEST` (`0x80`). Interim, 2026-11-18: the FPGA image uses the shared-secret `SHA3` (`0x04`, §5.1) for validation; this does not settle D3. |
| D4 | One permission bit, `perm[0]`, granting full debug: run control, abstract commands, Program Buffer and SBA. Mask bits 1–7 are reserved, and `REQUEST` and the ROM reject them. |
| D5 | No hardware hold timeout; releasing the strap boots normally. The ROM's window is bounded in software by `WINDOW_CYCLES`, with the check-to-commit tolerance described in §5.3; a hard cutoff is not provided. |
| D6 | The scan controller must force `debug_enable=0` and reset `karudbg_auth` on scan entry and exit. This is a platform obligation, recorded for A7. |

## 7. `lc=OPEN` equivalence

With `KARU_DBG_AUTH` defined and `lc` tied to `OPEN`:

- The DM, its DMI responses, the hart-facing debug page and all DM outputs must
  match a build without `KARU_DBG_AUTH` cycle for cycle, from reset, for
  identical inputs. This holds because the gate is applied without changing
  output timing:
  - `debug_enable_q` is a flop whose reset value is
    `lc==OPEN ∧ ¬revoke_i`. With `lc` tied to `OPEN`, it is 1 from the first
    cycle out of reset.
  - Each synchronous control output keeps today's logic and is ANDed with
    `debug_enable_q`. Examples are `halt_req_o`, and `resume_req_o` and
    `resume_authorized_o`, which today depend combinationally on hart
    availability. These outputs are **not** re-registered, which would add a
    cycle and break equivalence.
  - The direct-flop requirement applies only to `ndmreset_o`, which feeds
    asynchronous reset synchronizers. It stays a single flop. Its next state
    uses the gate's *next* value (`debug_enable_next_o` of `karudbg_auth`), so
    it clears on the same edge on which `debug_enable_q` falls. An assertion
    in `karudbg` requires every DM output, `ndmreset_o` included, to be 0 in
    every locked cycle.
  - What the security lemmas need (C2, C7) is that every DM output is 0
    whenever `debug_enable_q=0`, whatever the other inputs. A combinational
    AND with a registered gate meets that.
  - A1 checks equivalence by a Yosys sequential-equivalence proof
    (`dbg-auth-open-equiv-test`, using `test/dbg/check_auth_open_equiv.py`)
    and by rerunning every `dbg-*` gate.
- The scope is `lc=OPEN`, `revoke_i=0`, any boot-hold strap value, no access
  to the new CSRs, and **no access to the island address ranges**. An
  authentication build decodes the island in every lifecycle, `OPEN`
  included: `[0x0001_0000, 0x0002_4000)` is served by island ROM and SRAM
  rather than the external fabric, and the island SRAM is writable in the
  PMA. A program touching those addresses therefore behaves differently from
  a build without `KARU_DBG_AUTH`.
  - The DM equivalence is a proof.
  - The core-level statement covers only programs and debugger sessions that
    stay out of these ranges and CSRs.
  - The identical real-core debug-bench summary is evidence for that
    benchmark, not a general proof. The strap is ignored outside `AUTH`, and an
  assertion in `karudbg_auth` checks that the hart is never held or reset
  outside `AUTH` without revocation.
- The core differs only in the five CSRs of §3, which exist with
  `KARU_DBG_AUTH` and are illegal without it. Equivalence is therefore
  required for every hart program, and every debugger session, that does not
  access `0x7C0–0x7C3` or `0xFC0`, with `revoke_i=0`. Today such an access
  traps, so no existing program depends on it.

The plan's formula stands, and `mdbgauth.debug_enable` (§3.1) reports it:

```
debug_enable = (lc == OPEN ∨ (lc == AUTH ∧ auth_unlock)) ∧ ¬fw_lock ∧ ¬revoke_q
```

Firmware can therefore revoke debug on an `OPEN` part too, until POR. A part
whose firmware never sets `fw_lock` behaves exactly as today.

## 8. A1 implementation notes

Details the RTL had to fix:

- **`authdata` is implemented only with `lc=AUTH` and an active DM.** In
  `OPEN` and `DISABLED` it reads 0 and ignores writes, as Debug 1.0 Security
  recommends where `authdata` cannot unlock the DM. `authbusy` can therefore
  rise only in `AUTH`.
- **Relock bound.** `sys_reset_o` is asserted on the cycle after
  `debug_enable_q` is 0 with the hart in Debug Mode, so *k* = 1. Within the
  first locked cycle the hart already sees only EBREAK words (plan §3.2).
- **Island map.** The island ROM is `[0x0001_0000, 0x0002_0000)` and the island
  SRAM `[0x0002_0000, 0x0002_4000)`, which is load/store only in the PMA. Both
  are decoded by `karudbg_island` in front of the debug-page router.
  - `RESET_PC` must be in the island ROM.
  - The simulation ROM stub (`test/dbg/auth_rom_stub.S`) sets the
    application's `mtvec` before leaving.
- **DM ports.** `dmactive_o` feeds the session reset. `debug_enable_next_i`
  is used only by `ndmreset_q`.
- **Unlock predicate.** It also requires `auth_req=1` and no same-cycle
  session close (§3.1, §4.1).
- **System reset closes the window.** Once the hart has left reset after POR
  (`hart_started`), any later hart or system reset sets `boot_done`, so a
  reset reruns the ROM with the window closed (plan §2.2). The POR boot hold
  is the only reset before `hart_started`. A CSR access in a reset cycle has
  no effect, unlock included: the core does not report it (`auth_fire_o`
  excludes `rst`), and `karudbg_auth` also ignores it. The same holds for a
  CSR access in a cycle that takes a trap or enters Debug Mode: `auth_fire_o`
  excludes `trap_req`, and `karudbg_auth` ignores the access (lemma C8).
- **Island responses.** Each island channel records, at AR/AW acceptance,
  whether a transaction is outstanding and whether it is an island one. An
  external R or B beat reaches the core only for an outstanding external
  transaction accepted in an earlier cycle. A beat arriving before, at or
  after an island request's acceptance is neither forwarded nor consumed.
  The first A1 version selected responses by an owner flag alone, so an
  injected beat in the AR acceptance cycle could forge an island load result.
  `dbg-auth-island-test` and `dbg-auth-core-test` keep that as a mutant.
- **Debug-page router.** `karudbg_core` routes the debug page with the same
  rule, in every debug build. It sits downstream of the island and also drops
  unsolicited external beats, so on the real core either fixed layer alone
  stops a forged island load. Each layer has its own discriminating test.
