//  keccak_subj.c -- full-core directed test for Zvknhk vkeccak.vi (riscv-pqc).
//
//  The assembler has no mnemonic for it yet, so the instruction is emitted as
//  a raw OP-VE word:
//      vkeccak.vi vd, imm5   ==   .insn r 0x77, 0x2, 0x53, vd, x18, imm5
//      MATCH 0xa6092077 / MASK 0xfe0ff07f   (the vs1 field 10010 is opcode bits)
//  imm5 = 0 -> Keccak-p[1600,24] (SHA-3/SHAKE); 1 -> Keccak-p[1600,12]
//  (TurboSHAKE/KangarooTwelve, round constants RC[12..23]).
//
//  Known answers are the KECCAK-P / KECCAK-P12 vectors of riscv-pqc
//  zvknhk/test (state element i = i), cross-checked against an independent
//  Keccak-p[1600] model. Then the element-group rules of zvknhk.adoc are
//  exercised. The instruction permutes element groups vstart/32 .. vl/32-1 of
//  the vd register group (EGS=32, EGW=2048, SEW=64); at VLEN=256 an LMUL=8
//  group holds exactly one element group, so:
//    - e64,m8, vl=32, vstart=0 permutes elements 0..24 of the group and leaves
//      the state tail (elements 25..31, also under vta=1) and the neighbouring
//      registers untouched;
//    - an empty range (vl=0, or vstart a multiple of 32 and >= vl) is a no-op
//      that completes and zeroes vstart;
//    - SEW != 64, LMUL*VLEN < 2048 (any LMUL but 8, even at vl=0), vd not
//      aligned to LMUL, vl or vstart not a multiple of 32, vm=0, imm5 > 1 and
//      vill all raise illegal-instruction (cause 2) with no side effects and
//      vstart preserved.
//
//  This is the karu64 counterpart of riscv-pqc zvknhk/test/keccak_insn.c,
//  test_groups.c and edge_probe.c; `make keccak-test-all` runs the same ELF on
//  the riscv-pqc reference Spike and compares every line.

#include <stdint.h>
#include "sio_generic.h"

#define VKECCAK_VI(vd, imm5) \
    (0xa6092077u | ((uint32_t)(vd) << 7) | ((uint32_t)(imm5) << 20))

//  riscv-pqc zvknhk/test/test_sha3.c "KECCAK-P": Keccak-p[1600,24] of A[i]=i
static const uint64_t exp_p24[25] = {
    0x8374b05252ed8115ull, 0x1df7a676b6569400ull, 0xf765194b8a51797dull, 0x20477b43d1760545ull,
    0xd15f8ba4f3f6606aull, 0xa1d7144f7c8dd493ull, 0x30d193965138fd3full, 0x487e9472951be3beull,
    0x0cf3a858cbda7a5aull, 0x2fe54e389bb17f88ull, 0x0b7338de0d9f268full, 0x55efdff58b256d7full,
    0xc8353e94eb2c3e6aull, 0x2e2af6948c901f11ull, 0xe873de0cca309da6ull, 0xf7afc26c944d31e2ull,
    0xa0f5ea808cc415d7ull, 0x53f531437e3ed8cfull, 0x777f1f3b43a4d221ull, 0xfd0ca63cb499e985ull,
    0xd4c055c0c5d12330ull, 0xa72fe58aa6e0a7dfull, 0x421af5937c9948a3ull, 0x5e16103071340888ull,
    0xd153f43a297e4a33ull,
};
//  riscv-pqc zvknhk/test/test_turbo.c "KECCAK-P12": Keccak-p[1600,12] of A[i]=i
static const uint64_t exp_p12[25] = {
    0x31ccb6fee8eeccfeull, 0x57bf3dcca8d742e7ull, 0x33c23c8e00d5fd2dull, 0x27408b85c213997dull,
    0x442b508505b591aeull, 0xe7f3957f8698d9d0ull, 0x24e9ce4cb83dbdf3ull, 0xc6ed14e10f4998baull,
    0xa445718c4dd30e41ull, 0xa618c4ddc4f4c14bull, 0x862dab386c0b9ed0ull, 0x0fdade9dec4f977cull,
    0x38aa031a06ff1231ull, 0xf4b748a9ffecfc5cull, 0xd0af5893c33a5f19ull, 0x4dc1ff1ef5fa9c46ull,
    0xb15d80df5456c26bull, 0x3a66709440a0c35bull, 0xebbdd410f2e7a223ull, 0x7020a73b189a733dull,
    0xa3ea1df2b9a8f601ull, 0xd15d52bc81a76225ull, 0xeaac3058e82f6ac1ull, 0x1de0c38ae5544e5eull,
    0x72fa1a9d2dc565ddull,
};
//  Keccak-p[1600,12](Keccak-p[1600,24](A[i]=i)): two dependent vkeccak.vi
static const uint64_t exp_chain[25] = {
    0x80b4dac4d70b343cull, 0xe14fc37e8a15842dull, 0x8e1cdf99cfbeab02ull, 0x7c27eeb4384901afull,
    0xca9182c92e35908cull, 0xb9bef1b3ea147c3aull, 0x4eb81bb3816a7a24ull, 0xd613bee01496a772ull,
    0xe545de321fcb5f6full, 0x395d2bcbf5698b8eull, 0xde94add7e45e1c47ull, 0x7be52c790c954988ull,
    0xabcd674581cdff3eull, 0x56ba75236461793eull, 0x9b7313f24ec4d996ull, 0xa415d984f122547cull,
    0xec9ddf3c17e3dc6bull, 0x349fb73bdde2713dull, 0x6673fc9eda55f234ull, 0x83ae7bfbd51defe8ull,
    0xde10fe926d226013ull, 0xe3847f1d52aecda3ull, 0x18b77b23dd945886ull, 0x41484600a1301e74ull,
    0x1f536079ba540e2cull,
};

#define TAIL(i)  (0xa5a5a5a500000000ull | (uint64_t)(i))   //  state-tail sentinel

static uint64_t st[32]  __attribute__((aligned(64)));
static uint64_t nlo[4]  __attribute__((aligned(64)));
static uint64_t nhi[4]  __attribute__((aligned(64)));
static const uint64_t sent[4] __attribute__((aligned(64))) = {
    0x5eed000000000001ull, 0x5eed000000000002ull, 0x5eed000000000003ull, 0x5eed000000000004ull,
};
static int fails;

//  Trap handler for the reserved-encoding cases: count cause-2 traps and skip
//  the faulting (4-byte) instruction. Uses t0 AND t1, and mret does NOT restore
//  GPRs, so any inline asm that can trap while kec_tvec is installed must
//  clobber both. It is installed ONLY around the reserved-encoding block -- the
//  positive tests run before it, so an unexpected trap there fails cleanly
//  instead of being silently skipped + resumed mid-asm.
volatile uint64_t g_mcause; volatile uint32_t g_traps;
asm(".align 2\nkec_tvec:\n"
    "  csrr t0,mcause\n  la t1,g_mcause\n  sd t0,0(t1)\n"
    "  la t1,g_traps\n  lw t0,0(t1)\n  addiw t0,t0,1\n  sw t0,0(t1)\n"
    "  csrr t0,mepc\n  addi t0,t0,4\n  csrw mepc,t0\n  mret\n");

static void put_hex64(uint64_t x)
{
    for (int i = 60; i >= 0; i -= 4)
        sio_putc("0123456789abcdef"[(x >> i) & 0xf]);
}

static void put_dec(uint32_t x)
{
    char b[12]; int n = 0;
    do { b[n++] = (char)('0' + x % 10); x /= 10; } while (x);
    while (n) sio_putc(b[--n]);
}

static void check_lanes(const char *name, const uint64_t *got, const uint64_t *exp, int n)
{
    int bad = 0;
    for (int i = 0; i < n; i++) {
        if (got[i] != exp[i]) {
            if (!bad) { sio_puts("[FAIL] "); sio_puts(name); sio_putc('\n'); }
            sio_puts("  elem "); put_dec((uint32_t)i);
            sio_puts(" got=0x"); put_hex64(got[i]);
            sio_puts(" exp=0x"); put_hex64(exp[i]); sio_putc('\n');
            bad++;
        }
    }
    if (!bad) { sio_puts("[PASS] "); sio_puts(name); sio_putc('\n'); }
    fails += bad;
}

static void init_state(void)
{
    for (int i = 0; i < 25; i++) st[i] = (uint64_t)i;
    for (int i = 25; i < 32; i++) st[i] = TAIL(i);
}

//  e64,m8 with vl=32 (one whole element group) / vl=25 (the live state words)
#define VL32  "li t0,32\n vsetvli x0,t0,e64,m8,tu,mu\n"
#define VL25  "vsetivli x0,25,e64,m8,tu,mu\n"

static uint64_t g16[32] __attribute__((aligned(64)));
static uint64_t g0[32]  __attribute__((aligned(64)));

static void check_case(const char *name, int traps, int exp_traps,
                       uint64_t vstart, uint64_t exp_vstart)
{
    //  Expected-trap cases must be cause-2 (illegal instruction); g_mcause holds
    //  the last trap's mcause, set synchronously by kec_tvec during the op.
    int bad = (traps != exp_traps) || (exp_traps > 0 && g_mcause != 2) ||
              (vstart != exp_vstart);
    if (!bad) { sio_puts("[PASS] "); sio_puts(name); sio_putc('\n'); }
    else {
        sio_puts("[FAIL] "); sio_puts(name);
        sio_puts(" traps="); put_dec((uint32_t)traps);
        sio_puts(" exp="); put_dec((uint32_t)exp_traps);
        sio_puts(" mcause=0x"); put_hex64(g_mcause);
        sio_puts(" vstart="); put_dec((uint32_t)vstart);
        sio_puts(" exp="); put_dec((uint32_t)exp_vstart); sio_putc('\n');
        fails++;
    }
}

int main(void)
{
    sio_puts("[Zvknhk vkeccak.vi]\n");

    //  ---- 1. 24 rounds, vd=v0: the spec test's own sequence -- load the 25
    //  live words, vl=32 for one element group, permute, vl=25 to store ----
    init_state();
    asm volatile(
        VL25 "vle64.v v0, (%[s])\n"
        VL32 ".word %[w]\n"
        VL25 "vse64.v v0, (%[s])\n"
        :: [s]"r"(st), [w]"i"(VKECCAK_VI(0, 0)) : "t0", "memory");
    check_lanes("KECCAK-P    vkeccak.vi v0,0  (24 rounds)", st, exp_p24, 25);

    //  ---- 2. 12 rounds, vd=v8 ----
    init_state();
    asm volatile(
        VL25 "vle64.v v8, (%[s])\n"
        VL32 ".word %[w]\n"
        VL25 "vse64.v v8, (%[s])\n"
        :: [s]"r"(st), [w]"i"(VKECCAK_VI(8, 1)) : "t0", "memory");
    check_lanes("KECCAK-P12  vkeccak.vi v8,1  (12 rounds)", st, exp_p12, 25);

    //  ---- 3. two dependent ops back to back: 24 then 12 rounds on v0 ----
    init_state();
    asm volatile(
        VL25 "vle64.v v0, (%[s])\n"
        VL32 ".word %[w24]\n"
        ".word %[w12]\n"
        VL25 "vse64.v v0, (%[s])\n"
        :: [s]"r"(st), [w24]"i"(VKECCAK_VI(0, 0)), [w12]"i"(VKECCAK_VI(0, 1)) : "t0", "memory");
    check_lanes("chained     vkeccak.vi v0,0 ; v0,1", st, exp_chain, 25);

    //  ---- 4. element group at vd=v16: the state tail (elements 25..31) is
    //  part of the body but must stay bit-for-bit unchanged, and the
    //  neighbouring registers v15 / v24 are untouched ----
    init_state();
    asm volatile(
        VL32 "vle64.v v16, (%[s])\n"            //  whole 2048-bit group v16..v23
        "vsetivli x0, 4, e64, m1, tu, mu\n"
        "vle64.v v15, (%[q])\n"                //  register just below the group
        "vle64.v v24, (%[q])\n"                //  register just above the group
        VL32 ".word %[w]\n"
        "vse64.v v16, (%[s])\n"
        "vsetivli x0, 4, e64, m1, tu, mu\n"
        "vse64.v v15, (%[lo])\n"
        "vse64.v v24, (%[hi])\n"
        :: [s]"r"(st), [q]"r"(sent), [lo]"r"(nlo), [hi]"r"(nhi),
           [w]"i"(VKECCAK_VI(16, 0)) : "t0", "memory");
    {
        uint64_t exp[32];
        for (int i = 0; i < 25; i++) exp[i] = exp_p24[i];
        for (int i = 25; i < 32; i++) exp[i] = TAIL(i);
        check_lanes("group v16 @vl=32,m8: state + state tail", st, exp, 32);
        check_lanes("neighbour v15 untouched", nlo, sent, 4);
        check_lanes("neighbour v24 untouched", nhi, sent, 4);
    }

    //  ---- 5. top group vd=v24, 12 rounds, tail-agnostic policy: the state
    //  tail is not the architectural tail, so vta=1 must not disturb it ----
    init_state();
    asm volatile(
        VL32 "vle64.v v24, (%[s])\n"
        "vsetvli x0, t0, e64, m8, ta, ma\n"     //  vl = 32, vta = vma = 1
        ".word %[w]\n"
        VL32 "vse64.v v24, (%[s])\n"
        :: [s]"r"(st), [w]"i"(VKECCAK_VI(24, 1)) : "t0", "memory");
    {
        uint64_t exp[32];
        for (int i = 0; i < 25; i++) exp[i] = exp_p12[i];
        for (int i = 25; i < 32; i++) exp[i] = TAIL(i);
        check_lanes("KECCAK-P12  vkeccak.vi v24,1 @ta,ma: state + state tail", st, exp, 32);
    }

    //  ==== element-group range and reserved encodings ====
    //  v0..v7 are preloaded with A[i]=i so the two legal control cases permute
    //  them (24 then 12 rounds), and v16..v23 hold the same state + tail
    //  pattern as the target of every empty-range and trapping case; both
    //  groups are checked afterwards. Each case also reads vstart right after
    //  the instruction: a completed vkeccak.vi (even an empty one) zeroes it,
    //  a trapped one leaves it as written.
    init_state();
    asm volatile(
        VL32 "vle64.v v0, (%[s])\n"
        "vle64.v v16, (%[s])\n"
        :: [s]"r"(st) : "t0", "memory");
    //  Install the skip-and-resume trap handler ONLY here. kec_tvec clobbers
    //  t0 AND t1 (mret does not restore GPRs), so every asm that can trap
    //  lists both; vstart is read into a register the compiler picks outside
    //  that set.
    asm volatile("la t0,kec_tvec\n csrw mtvec,t0" ::: "t0");
    #define CASE(nm, setup, word, exp_traps, exp_vstart) do {               \
        uint32_t _t = g_traps; uint64_t _vs;                                \
        asm volatile(setup "\n .word %[w]\n csrr %[vs],vstart\n csrwi vstart,0\n" \
            : [vs]"=&r"(_vs) : [w]"i"(word) : "t0", "t1", "memory");        \
        check_case(nm, (int)(g_traps - _t), exp_traps, _vs, exp_vstart); } while (0)
    #define VSTART(n) "li t0," #n "\n csrw vstart,t0"
    #define M8(vl)    "li t0," #vl "\n vsetvli x0,t0,e64,m8,tu,mu"

    sio_puts("[Zvknhk element-group range]\n");
    CASE("v0,0  @e64 m8 vl=32 -> ok",                M8(32), VKECCAK_VI(0, 0), 0, 0);
    CASE("vl=0 -> no-op",                            M8(0),  VKECCAK_VI(16, 0), 0, 0);
    CASE("vl=32 vstart=32 (>= vl) -> no-op",         M8(32) "\n" VSTART(32),  VKECCAK_VI(16, 0), 0, 0);
    CASE("vl=0  vstart=32 -> no-op",                 M8(0)  "\n" VSTART(32),  VKECCAK_VI(16, 0), 0, 0);
    CASE("vl=32 vstart=64 -> no-op",                 M8(32) "\n" VSTART(64),  VKECCAK_VI(16, 0), 0, 0);
    CASE("vl=32 vstart=224 -> no-op",                M8(32) "\n" VSTART(224), VKECCAK_VI(16, 1), 0, 0);

    sio_puts("[Zvknhk reserved encodings]\n");
    CASE("imm5=2 (reserved) -> trap",                M8(32), VKECCAK_VI(16, 2), 1, 0);
    CASE("imm5=31 (reserved) -> trap",               M8(32), VKECCAK_VI(16, 31), 1, 0);
    CASE("vm=0 -> trap",                             M8(32), VKECCAK_VI(16, 0) & ~(1u << 25), 1, 0);
    CASE("SEW=32 @m8 -> trap",                       "li t0,32\n vsetvli x0,t0,e32,m8,tu,mu", VKECCAK_VI(16, 0), 1, 0);
    CASE("SEW=16 @m8 -> trap",                       "li t0,32\n vsetvli x0,t0,e16,m8,tu,mu", VKECCAK_VI(16, 0), 1, 0);
    CASE("SEW=8  @m8 -> trap",                       "li t0,32\n vsetvli x0,t0,e8,m8,tu,mu",  VKECCAK_VI(16, 0), 1, 0);
    CASE("LMUL=1 vl=0 (LMUL*VLEN < 2048) -> trap",   "vsetivli x0,0,e64,m1,tu,mu", VKECCAK_VI(16, 0), 1, 0);
    CASE("LMUL=2 vl=0 -> trap",                      "vsetivli x0,0,e64,m2,tu,mu", VKECCAK_VI(16, 0), 1, 0);
    CASE("LMUL=4 vl=0 -> trap",                      "vsetivli x0,0,e64,m4,tu,mu", VKECCAK_VI(16, 0), 1, 0);
    CASE("LMUL=4 vl=16 (VLMAX) -> trap",             "vsetivli x0,16,e64,m4,tu,mu", VKECCAK_VI(16, 0), 1, 0);
    CASE("LMUL=1 vl=4 (old fixed-group use) -> trap","vsetivli x0,4,e64,m1,tu,mu", VKECCAK_VI(16, 0), 1, 0);
    CASE("vd=v4 (not LMUL-aligned) -> trap",         M8(32), VKECCAK_VI(4, 0), 1, 0);
    CASE("vd=v17 (not LMUL-aligned) -> trap",        M8(32), VKECCAK_VI(17, 0), 1, 0);
    CASE("vd=v28 (not LMUL-aligned) -> trap",        M8(32), VKECCAK_VI(28, 0), 1, 0);
    CASE("vl=25 (old idiom, not mult of 32) -> trap",M8(25), VKECCAK_VI(16, 0), 1, 0);
    CASE("vl=16 -> trap",                            M8(16), VKECCAK_VI(16, 0), 1, 0);
    CASE("vl=31 -> trap",                            M8(31), VKECCAK_VI(16, 0), 1, 0);
    CASE("vl=1 -> trap",                             M8(1),  VKECCAK_VI(16, 0), 1, 0);
    CASE("vstart=1 -> trap, vstart kept",            M8(32) "\n" VSTART(1),  VKECCAK_VI(16, 0), 1, 1);
    CASE("vstart=16 -> trap, vstart kept",           M8(32) "\n" VSTART(16), VKECCAK_VI(16, 0), 1, 16);
    CASE("vstart=33 -> trap, vstart kept",           M8(32) "\n" VSTART(33), VKECCAK_VI(16, 0), 1, 33);
    CASE("vill -> trap",                             "li t0,32\n li t1,4\n vsetvl x0,t0,t1", VKECCAK_VI(16, 0), 1, 0);
    CASE("old keccak-xrv word (x17,x24) -> trap",    M8(32), 0xa788a877u, 1, 0);
    CASE("v0,1  @e64 m8 vl=32 -> ok",                M8(32), VKECCAK_VI(0, 1), 0, 0);
    #undef CASE
    #undef VSTART
    #undef M8
    {
        uint64_t exp[32];
        asm volatile(
            VL32 "vse64.v v0, (%[a])\n"
            "vse64.v v16, (%[b])\n"
            :: [a]"r"(g0), [b]"r"(g16) : "t0", "memory");
        for (int i = 0; i < 25; i++) exp[i] = exp_chain[i];
        for (int i = 25; i < 32; i++) exp[i] = TAIL(i);
        check_lanes("legal cases permuted v0..v7 (24 then 12 rounds)", g0, exp, 32);
        check_lanes("empty-range and trapping cases left v16..v23 untouched", g16, st, 32);
    }

    if (fails) { sio_puts("[Zvknhk] FAIL "); put_dec((uint32_t)fails); sio_putc('\n'); }
    else sio_puts("[Zvknhk] ALL PASS\n");
    return fails ? 1 : 0;
}
