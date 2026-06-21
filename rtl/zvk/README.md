# rtl/zvk — standard RISC-V vector-crypto (Zvk\*)

Opt-in standard vector-crypto for `karu64`. The coarse
`-DKARU_ZVK` umbrella enables all implemented standard leaves; the leaf knobs
can also be enabled independently: `-DKARU_ZVKB` (vandn/vbrev8/vrev8/vrol/vror
lane bit-manip glue), `-DKARU_ZVKNED` (AES), `-DKARU_ZVKNHA` (SHA-256),
`-DKARU_ZVKNHB` (SHA-256/SHA-512, implies Zvknha), `-DKARU_ZVKSED` (SM4),
`-DKARU_ZVKSH` (SM3), and `-DKARU_ZVKG` (GHASH/GCM).
Distinct from the experimental `KARU_KECCAK` single-instruction Keccak-f1600
(`vkeccak`, custom opcode) — see doc/architecture.md.

Release-layout note: the custom Keccak RTL now lives in this directory as
`keccak.v` and `keccak_round.v`; the old root-level `rtl/keccak*.v` paths are
gone. The SystemVerilog KAT/decode benches live under `test/zvk/`, not under
`rtl/zvk/`. The old generated `rtl/zvk/doc/zvk_encodings.txt` was removed; the
encoding summary below is the maintained source.

`Zvknha` and `Zvknhb` share the same instruction encodings; the active SEW
selects SHA-256 vs SHA-512 behavior. Decode therefore enables the SHA-2 words
under `KARU_EN_ZVKNHA`, and `karu64` traps SHA-2 at `SEW=64` unless
`KARU_EN_ZVKNHB` is also present.

This is the "independent crypto unit outside the 64-bit lanes" from the long-term
plan: Zvk operates on 128-/256-bit *element groups* (EGW), which a 64-bit
`karu_vlane` can't present atomically, so the crypto datapath reads whole element
groups separately and runs one isolated unit (genvar-replicable to `VLEN/128`
later).

## What's here

### Leaf datapath cores (reused from Marian, locally cleaned)

Copied verbatim from `../mrn2test/Marian/src/ip/crypto/*/src/` (the **Marian**
vector-crypto subsystem), then locally cleaned: package imports were removed and
the element-group widths are written directly as 128/256-bit ports/signals. The
leaf reference cores are mostly combinational; the integrated build uses local
iterative wrappers for the paths that would otherwise dominate timing.

| File | Module(s) | Zvk instr | EGW |
|---|---|---|---|
| `sboxes.v` | shared combinational AES/AES^-1/SM4 S-boxes | AES/SM4 helper | — |
| `aes_encdec.v` | `encdec` | `vaesem/ef/dm/df/z` | 128 |
| `aes_key_expansion.v` | `key_expansion` | `vaeskf1/kf2` | 128 |
| `sha2_compression.v` | `compression` | `vsha2ch/cl` | 128/256 |
| `sha2_msg_schedule.v` | `msg_schedule` | `vsha2ms` | 128/256 |
| `karu_sha2_iter.v` | `karu_sha2_iter` | integrated `vsha2ch/cl/ms` | 128/256 |
| `sm4_encdec.v` | `sm4_encdec` | `vsm4r` | 128 |
| `sm4_key_expansion.v` | `sm4_key_expansion` | `vsm4k` | 128 |
| `karu_sm4_iter.v` | `karu_sm4_iter` | integrated `vsm4r/vsm4k` | 128 |
| `sm3_compression.v` | `sm3_compression` | `vsm3c` | 256 |
| `sm3_msg_expansion.v` | `sm3_msg_expansion` | `vsm3me` | 256 |
| `karu_sm3_iter.v` | `karu_sm3_iter` | integrated `vsm3c` | 256 |
| `karu_ghash.v` | `karu_ghash` | integrated `vgmul/vghsh` | 128 |
| `karu_vcrypto.v` | `karu_vcrypto` | aggregate Zvk unit | 128/256 |
| `keccak.v`, `keccak_round.v` | `keccak`, `keccak_round` | custom `vkeccak` | 1600-bit state |

Each `sm4_encdec` / `sm4_key_expansion` performs **all four** SM4 rounds of its
op in one combinational call (NOT one round) — instantiate **one**, not a chain.

### `karu_sm4_iter.v` — iterative SM4

SM4 is a generalized Feistel network, so `vsm4r` and `vsm4k` do not need four
dependent rounds in one timing path. `karu_sm4_iter.v` reuses the shared
combinational `sm4_sbox` through one `sm4_subword` instance and runs the four
rounds one per cycle, covering both data rounds and key expansion. The original
combinational SM4 leaf modules remain useful for standalone KAT/reference
coverage; `karu_vcrypto` drives the iterative wrapper in integrated builds.

### `karu_sha2_iter.v` — staged SHA-2

SHA-2 has separate 32-bit and 64-bit datapaths. `karu_sha2_iter.v` keeps those
paths separate and stages the integrated instructions without changing their
architectural result: SHA-256/SHA-512 compression (`vsha2ch/cl`) completes in
two cycles, and message schedule (`vsha2ms`) completes in four cycles. The round
and message-schedule add trees use carry-save-style local reducers so Vivado
sees short 2-input adder chains instead of one long chained sum.

The standalone Marian `compression` and `msg_schedule` modules remain in the
tree for KAT/reference coverage; `karu_vcrypto` uses `karu_sha2_iter` in
integrated builds.

### `karu_sm3_iter.v` — staged SM3

SM3 compression (`vsm3c`) is staged through `karu_sm3_iter` for the integrated
unit; SM3 message expansion (`vsm3me`) remains shallow enough to use the cleaned
reference combinational core with a registered result.

### `karu_ghash.v` — iterative GHASH (the one core we did NOT reuse as-is)

Marian's `add_mult_ghash` / `mult_ghash` express the 128-bit carry-less multiply
+ reduction as a **fully-combinational** 128-stage genvar cone (`clk`/`rst` are
present but unused; `done == valid`). That is ~128 serial conditional-XOR levels
deep — a hard timing wall at 8 ns, worse than the `karu_varith` writeback cone.
`karu_ghash.v` serialises it (like the keccak round FSM / the `KARU_V_DIV_CYCLES`
bit-serial divide): a **radix-2^GK** engine with a `KARU_V_GHASH_CYCLES` knob
(divisor of 128, default 16 = 8 GF steps/cycle), `req`/`busy`/`done` handshake,
computing `out = brev8(GFMUL(brev8(A^X), brev8(H)))` with reduction poly `0x87`.
Verified against Marian/NIST vectors at GK = 1,2,8,16,64,128.

### `karu_vcrypto.v` — the aggregated crypto unit (one isolated datapath)

The Zvk analogue of the single `keccak i_keccak` behind `vkeccak`. Wraps **all**
leaf cores behind **one uniform `req`/`busy`/`done` handshake** so the
`karu_varith` sequencer can drive any Zvk op the way it drives keccak:
load operand groups → pulse `req` → wait `done` → store the `vd` group.

- `cop[4:0]` op selector; `aux[4:0]` = round / `uimm` / SEW64 flag.
- `egw_vd/vs1/vs2` are 256-bit (EGW128 ops use the low 128).
- FSM: `S_IDLE → S_COMB` for shallow AES/AES-key/SM3-message-expansion results
  (registered 1-cycle latency, breaking the VRF-read→crypto→writeback cone at
  the unit boundary), `→ S_SHA2` for staged SHA-2, `→ S_SM3` for staged SM3
  compression, `→ S_SM4` for one SM4 round/cycle via `karu_sm4_iter`, or
  `→ S_GH` for GHASH multi-cycle via `karu_ghash`.

### Encoding Notes

21 mnemonics objdump'd from `riscv64-unknown-elf-as -march=...zvkned_zvknhb_
zvksed_zvksh_zvkg`. All are OP-VE (major opcode **`0x77`**, `inst[6:0]=1110111`) —
**not** OP-V (`0x57`), a long-standing misconception; vector *crypto* (vaes/vsha2/
vsm4/vsm3/vghsh) is `0x77`, only vector *bitmanip* (Zvbb/Zvbc) stays in OP-V `0x57`.
The custom `vkeccak` shares this same `0x77` major opcode (disambiguated by funct
fields). All **fn3 = 010 (OPMVV)** — even
the `.vi` forms (`vaeskf*`/`vsm4k`/`vsm3c`), which carry `uimm` in the `vs1` field.
`vaes*`/`vsm4r`/`vgmul` share funct6 `101000`(.vv)/`101001`(.vs) and select the
specific op via the **`vs1` field**. **Re-read this section before touching decode —
do not hand-derive funct6 from memory.**

## Tests (all PASS, verilator)

Self-checking KATs against the standard / Marian's validated vectors:

| TB | Checks |
|---|---|
| `tb_aes_kat.sv` | FIPS-197 App C.1 AES-128 encrypt + decrypt round-trip + key schedule (14 checkpoints) |
| `tb_sha2_kat.sv` | FIPS-180 SHA-256("abc") through the compression core (32 two-round steps) |
| `tb_sha2ms_kat.sv` | FIPS-180 SHA-256 and SHA-512 message schedule W16..W19 |
| `tb_sm4_kat.sv` | GB/T 32907 `vsm4r` + `vsm4k` |
| `tb_sm3_kat.sv` | `vsm3c` + `vsm3me` (Marian spike-cross-checked vectors) |
| `tb_ghash_kat.sv` | NIST/Marian GCM `vghsh`/`vgmul` published vectors (all GK) |
| `tb_vcrypto_kat.sv` | the aggregated handshake, including SHA2 SEW32 and SEW64 staged paths |
| `make zvk-kat` | all standalone KATs above, plus the aggregate handshake KAT |
| `make zvk-decode-test` | all standard OP-VE encodings under `-DKARU_ZVK` |
| `make zvk-decode-leaf-test` | each official leaf knob decodes its ops and traps the other leaves |
| `make zvk-test` | full-core `-DKARU_ZVK` instruction smoke across AES/SHA-2/SM4/SM3/GHASH |

Build pattern (one example):

    verilator --binary --timing -Wno-UNOPTFLAT -Wno-WIDTH -Wno-UNUSEDSIGNAL \
      -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
      rtl/zvk/sboxes.v rtl/zvk/aes_encdec.v \
      rtl/zvk/aes_key_expansion.v rtl/zvk/sha2_compression.v \
      rtl/zvk/sha2_msg_schedule.v rtl/zvk/sm4_encdec.v \
      rtl/zvk/sm4_key_expansion.v rtl/zvk/karu_sm4_iter.v \
      rtl/zvk/sm3_compression.v \
      rtl/zvk/sm3_msg_expansion.v rtl/zvk/karu_sm3_iter.v \
      rtl/zvk/karu_ghash.v rtl/zvk/karu_vcrypto.v \
      test/zvk/tb_vcrypto_kat.sv --top-module tb_vcrypto_kat && ./obj_dir/...

`-Wno-UNOPTFLAT` is required: the Canright S-box's GF decomposition trips a
verilator UNOPTFLAT false-positive (same suppression the repo Makefile uses).

## Synthesis notes

All active Zvk RTL is plain Verilog under `rtl/zvk/*.v`; only the testbenches are
SystemVerilog. The Vivado full-core and OOC scripts read `rtl/zvk/*.v` and add
`rtl/zvk` to the include path, so `-DKARU_ZVK` and the individual leaf knobs work
in the FPGA flow.

Recent 8 ns Vivado OOC checks with `SYNTH_DIRECTIVE=RuntimeOptimized`,
`VIVADO_THREADS=4`, and `KARU_DEFINES=KARU_ZVK`:

| Top | WNS | Datapath | Notes |
|---|---:|---:|---|
| `karu_sha2_iter` | +5.555 ns | 2.427 ns | 14 logic levels, CSA-shaped SHA-2 round/message-schedule adders |
| `karu_vcrypto` | +3.631 ns | 4.351 ns | aggregate AES/SHA-2/SM3/SM4/GHASH unit |

These are OOC diagnostics, not full-core closure numbers, but they confirm the
Zvk unit itself is not currently the obvious 8 ns timing wall.

## Integration status

- [x] Leaf cores ported + locally cleaned; each KAT-PASS standalone.
- [x] `karu_ghash` iterative GHASH; KAT-PASS at all cycle settings.
- [x] `karu_vcrypto` aggregator; KAT-PASS (all ops through the handshake).
- [x] `-DKARU_ZVK` umbrella and official leaf-knob resolution in
      `rtl/karu_ext.vh` (needs V).
- [x] `UNIT_VCRYPTO = 4'd13` in `rtl/karu_uop_defs.vh`.
- [x] `karu_dec.v`: decode the Zvk encodings → `UNIT_VCRYPTO` (gated by the
      matching leaf; smoke tests: `make zvk-decode-test`,
      `make zvk-decode-leaf-test`).
- [x] `karu64.v`: route `UNIT_VCRYPTO` to `karu_varith` (`is_vcrypto`, mirror `is_keccak`).
- [x] `karu_varith.v`: keccak-style `S_C*` FSM driving one `karu_vcrypto`,
      iterating EGW element groups (EGW128 low/high halves, EGW256 whole regs).
- [x] directed full-core test on the `-DKARU_ZVK` build (`make zvk-test`):
      raw standard instruction words across AES/SHA-2/SM4/SM3/GHASH,
      decode→issue→VRF→`karu_vcrypto`→VRF writeback.
- [ ] broaden directed full-core coverage to more operands, masks/tails, and
      cross-check standard encodings against spike/toolchain where supported.

Default builds (without `-DKARU_ZVK`) are unaffected: the decode block is compiled
out, the unit is not instantiated, and the opcodes trap as illegal — the validated
IMAFDCV core stays byte-identical.

When building a partial Zvk configuration, use the official leaf macros directly,
for example `make zvk-decode-test ZVK_FLAGS=-DKARU_ZVKNED`,
`make zvk-decode-test ZVK_FLAGS=-DKARU_ZVKB`, or
`make zvk-decode-test ZVK_FLAGS=-DKARU_ZVKG`. The full-core `make zvk-test`
firmware currently expects the umbrella build because it executes one instruction
from each implemented leaf.
