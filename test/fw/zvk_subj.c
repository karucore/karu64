//  zvk_subj.c -- full-core standard Zvk instruction smoke test.
//
//  Uses embedded raw OP-VE words so the test does not depend on assembler
//  mnemonic support. Each case executes a real vector
//  crypto instruction through decode -> issue -> VRF EGW read -> karu_vcrypto
//  -> VRF writeback -> vector store.

#include <stdint.h>
#include "sio_generic.h"

static uint32_t vd[8]  __attribute__((aligned(32)));
static uint32_t vs1[8] __attribute__((aligned(32)));
static uint32_t vs2[8] __attribute__((aligned(32)));
static uint32_t out[8] __attribute__((aligned(32)));
static uint32_t ref[8] __attribute__((aligned(32)));

static int fails;

//  Trap handler for the SEW-legality cases: count cause-2 traps and skip the
//  faulting (4-byte) instruction. Uses t0 AND t1, and mret does NOT restore GPRs,
//  so any inline asm that can trap while zvk_tvec is installed must clobber both.
//  It is installed ONLY around the SEW matrix (below) -- the positive smoke tests
//  run before it, so an unexpected trap there fails cleanly instead of being
//  silently skipped + resumed mid-asm.
volatile uint64_t g_mcause; volatile uint32_t g_traps;
asm(".align 2\nzvk_tvec:\n"
    "  csrr t0,mcause\n  la t1,g_mcause\n  sd t0,0(t1)\n"
    "  la t1,g_traps\n  lw t0,0(t1)\n  addiw t0,t0,1\n  sw t0,0(t1)\n"
    "  csrr t0,mepc\n  addi t0,t0,4\n  csrw mepc,t0\n  mret\n");

static void put_hex32(uint32_t x)
{
    for (int i = 28; i >= 0; i -= 4)
        sio_putc("0123456789abcdef"[(x >> i) & 0xf]);
}

static void clear(void)
{
    for (int i = 0; i < 8; i++) vd[i] = vs1[i] = vs2[i] = 0, out[i] = 0xeeeeeeeeu;
}

static void check(const char *name, const uint32_t *exp, int n)
{
    int bad = 0;
    for (int i = 0; i < n; i++) {
        if (out[i] != exp[i]) {
            if (!bad) { sio_puts("[FAIL] "); sio_puts(name); }
            sio_puts("\n  i="); sio_putc('0' + i);
            sio_puts(" got=0x"); put_hex32(out[i]);
            sio_puts(" exp=0x"); put_hex32(exp[i]);
            bad++;
        }
    }
    if (!bad) { sio_puts("[PASS] "); sio_puts(name); sio_putc('\n'); }
    fails += bad;
}

static void check_trap(const char *name, int got, int exp)
{
    //  Expected-trap cases must be cause-2 (illegal instruction); g_mcause holds
    //  the last trap's mcause, set synchronously by zvk_tvec during the op above.
    int bad = (got != exp) || (exp > 0 && g_mcause != 2);
    if (!bad) { sio_puts("[PASS] "); sio_puts(name); sio_putc('\n'); }
    else {
        sio_puts("[FAIL] "); sio_puts(name);
        sio_puts(" traps="); sio_putc('0' + (got & 7));
        sio_puts(" exp="); sio_putc('0' + (exp & 7));
        sio_puts(" mcause=0x"); put_hex32((uint32_t)g_mcause); sio_putc('\n');
        fails++;
    }
}

static void run128(uint32_t word)
{
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v1,(%[vd])\n"
        "vle32.v v2,(%[vs2])\n"
        "vle32.v v3,(%[vs1])\n"
        ".word %[word]\n"
        "vse32.v v1,(%[out])\n"
        :
        : [vl]"r"((long)4), [vd]"r"(vd), [vs1]"r"(vs1), [vs2]"r"(vs2),
          [out]"r"(out), [word]"i"(word)
        : "t0", "memory");
}

static void run256(uint32_t word)
{
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v1,(%[vd])\n"
        "vle32.v v2,(%[vs2])\n"
        "vle32.v v3,(%[vs1])\n"
        ".word %[word]\n"
        "vse32.v v1,(%[out])\n"
        :
        : [vl]"r"((long)8), [vd]"r"(vd), [vs1]"r"(vs1), [vs2]"r"(vs2),
          [out]"r"(out), [word]"i"(word)
        : "t0", "memory");
}

//  General-vs1 (non-v3) end-to-end coverage with the REAL OpenSSL libcrypto
//  SHA-2 register shapes -- the exact encodings that SIGILL'd before the
//  rs1_w==3 decode fix. Same operand->array mapping as run128 (vd<-vd[],
//  vs2<-vs2[], vs1<-vs1[]), so the KAT goldens hold; this covers decode + VRF
//  operand routing for vs1=v16/v18.
static void run128_sha2ms_ossl(void)    //  vsha2ms.vv v10,v18,v16 (0xb7282577)
{
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v10,(%[vd])\n"
        "vle32.v v18,(%[vs2])\n"
        "vle32.v v16,(%[vs1])\n"
        ".word 0xb7282577\n"
        "vse32.v v10,(%[out])\n"
        :
        : [vl]"r"((long)4), [vd]"r"(vd), [vs1]"r"(vs1), [vs2]"r"(vs2),
          [out]"r"(out)
        : "t0", "memory");
}

static void run128_sha2cl_ossl(void)    //  vsha2cl.vv v24,v22,v18 (0xbf692c77)
{
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v24,(%[vd])\n"
        "vle32.v v22,(%[vs2])\n"
        "vle32.v v18,(%[vs1])\n"
        ".word 0xbf692c77\n"
        "vse32.v v24,(%[out])\n"
        :
        : [vl]"r"((long)4), [vd]"r"(vd), [vs1]"r"(vs1), [vs2]"r"(vs2),
          [out]"r"(out)
        : "t0", "memory");
}

int main(void)
{
    asm volatile("li t0,0x6600\n csrs mstatus,t0" ::: "t0");    //  FS+VS
    sio_puts("\n[ZVK instruction smoke]\n");

    //  Zvkned: FIPS-197 C.1 round[1] vaesem(state=round[1].start, key=rk1).
    static const uint32_t exp_aes[4] = {
        0xe810d889u, 0x68ce5a85u, 0xd843182du, 0xe48f12cbu
    };
    clear();
    vd[0]=0x30201000u; vd[1]=0x70605040u; vd[2]=0xb0a09080u; vd[3]=0xf0e0d0c0u;
    vs2[0]=0xfd74aad6u; vs2[1]=0xfa72afd2u; vs2[2]=0xf178a6dau; vs2[3]=0xfe76abd6u;
    run128(0xa22120f7u);        //  vaesem.vv v1,v2
    check("vaesem.vv", exp_aes, 4);

    //  Zvknha: SHA-256 message schedule W16..W19 for "abc".
    static const uint32_t exp_sha2ms[4] = {
        0x61626380u, 0x000f0000u, 0x7da86405u, 0x600003c6u
    };
    clear();
    vd[0]=0x61626380u;
    vs1[3]=0x00000018u;
    run128(0xb621a0f7u);        //  vsha2ms.vv v1,v2,v3
    check("vsha2ms.vv", exp_sha2ms, 4);

    //  General-vs1 end-to-end (decode fix + VRF operand routing), real OpenSSL
    //  libcrypto register shapes:
    //  (a) absolute KAT for vs1=v16: same inputs as the canonical vsha2ms above.
    clear();
    vd[0]=0x61626380u;
    vs1[3]=0x00000018u;
    run128_sha2ms_ossl();       //  0xb7282577 vsha2ms.vv v10,v18,v16
    check("vsha2ms general-vs1 (v10,v18,v16)", exp_sha2ms, 4);
    //  (b) self-consistency for vs1=v18 -- vsha2cl 0xbf692c77 is the exact
    //  instruction that SIGILL'd sshd/libcrypto; the v24,v22,v18 form must equal
    //  the canonical v1,v2,v3 form on identical inputs.
    clear();
    vd[0]=0x61626380u; vd[1]=0x11111111u; vd[2]=0x22222222u; vd[3]=0x33333333u;
    vs1[0]=0x44444444u; vs1[1]=0x55555555u; vs1[2]=0x66666666u; vs1[3]=0x00000018u;
    vs2[0]=0x77777777u; vs2[1]=0x88888888u; vs2[2]=0x99999999u; vs2[3]=0xaaaaaaaau;
    run128(0xbe21a0f7u);        //  vsha2cl.vv v1,v2,v3 (canonical)
    for (int i = 0; i < 4; i++) ref[i] = out[i];
    run128_sha2cl_ossl();       //  0xbf692c77 vsha2cl.vv v24,v22,v18 (same inputs)
    check("vsha2cl general-vs1 (v24,v22,v18) == v3-form", ref, 4);

    //  Zvksed: SM4 key expansion and round.
    static const uint32_t exp_sm4k[4] = {
        0x367360f4u, 0x776a0c61u, 0xb6bb89b3u, 0x24763151u
    };
    clear();
    vs2[0]=0xf12186f9u; vs2[1]=0x41662b61u; vs2[2]=0x5a6ab19au; vs2[3]=0x7ba92077u;
    run128(0x8620a0f7u);        //  vsm4k.vi v1,v2,1
    check("vsm4k.vi", exp_sm4k, 4);

    static const uint32_t exp_sm4r[4] = {
        0x27fad345u, 0xa18b4cb2u, 0x11c1e22au, 0xcc13e2eeu
    };
    clear();
    vd[0]=0x01234567u; vd[1]=0x89abcdefu; vd[2]=0xfedcba98u; vd[3]=0x76543210u;
    vs2[0]=0xf12186f9u; vs2[1]=0x41662b61u; vs2[2]=0x5a6ab19au; vs2[3]=0x7ba92077u;
    run128(0xa22820f7u);        //  vsm4r.vv v1,v2
    check("vsm4r.vv", exp_sm4r, 4);

    //  Zvksh: SM3 message expansion.
    static const uint32_t exp_sm3me[8] = {
        0x00e29290u, 0x00000000u, 0x06060c00u, 0xed709c71u,
        0x00000000u, 0x1f800180u, 0xa97d9f93u, 0x00000000u
    };
    clear();
    vs1[0]=0x80636261u;
    vs2[7]=0x18000000u;
    run256(0x8221a0f7u);        //  vsm3me.vv v1,v2,v3
    check("vsm3me.vv", exp_sm3me, 8);

    //  Zvkg: GHASH add-multiply and multiply.
    static const uint32_t exp_vghsh[4] = {
        0xbc148d6au, 0x9f71be42u, 0x2fa421e7u, 0x7a73aff1u
    };
    clear();
    vd[0]=0x55088014u; vd[1]=0x2a84400au; vd[2]=0x15422005u; vd[3]=0xa9a11002u;
    vs1[0]=0x0112d088u; vs1[1]=0x00896844u; vs1[2]=0x0044b422u; vs1[3]=0x00225a11u;
    vs2[0]=0x541a509cu; vs2[1]=0x2a0d284eu; vs2[2]=0x15069427u; vs2[3]=0xa9834a13u;
    run128(0xb221a0f7u);        //  vghsh.vv v1,v2,v3
    check("vghsh.vv", exp_vghsh, 4);

    static const uint32_t exp_vgmul[4] = {
        0xc1870055u, 0xd297a538u, 0xea1e1272u, 0x1d8d92b4u
    };
    clear();
    vd[0]=0x55088014u; vd[1]=0x2a84400au; vd[2]=0x15422005u; vd[3]=0xa9a11002u;
    vs2[0]=0x0112d088u; vs2[1]=0x00896844u; vs2[2]=0x0044b422u; vs2[3]=0x00225a11u;
    run128(0xa228a0f7u);        //  vgmul.vv v1,v2
    check("vgmul.vv", exp_vgmul, 4);

    //  ==== SEW (element-width) legality (vector-crypto.adoc SEW table). All
    //  crypto ops reserve SEW!=32, EXCEPT SHA-2 which also allows SEW=64 under
    //  Zvknhb. This is the KARU_ZVK umbrella build (Zvknhb present). Earlier RTL
    //  only trapped SHA-2 e64-without-Zvknhb; now every crypto op at an illegal
    //  SEW raises a cause-2 illegal-instruction trap.
    sio_puts("[ZVK SEW legality]\n");
    //  Install the skip-and-resume trap handler ONLY here -- the positive smoke
    //  tests above ran without it, so an unexpected trap there fails cleanly.
    asm volatile("la t0,zvk_tvec\n csrw mtvec,t0" ::: "t0");
    //  zvk_tvec clobbers t0 AND t1 (and mret does NOT restore GPRs), so any asm
    //  that can trap must list both -- else the compiler may keep a live value in
    //  t1 across the op and the test result depends on register allocation.
    #define SEW_CASE(nm, sew, word, exp) do { uint32_t _t = g_traps; \
        asm volatile("vsetvli t0,%0," sew ",m1,tu,mu\n .word " word "\n" \
            :: "r"((long)4) : "t0", "t1", "memory"); \
        check_trap(nm, (int)(g_traps - _t), exp); } while (0)
    SEW_CASE("vaesem.vv  @e16 -> trap",        "e16", "0xa22120f7", 1);
    SEW_CASE("vaesem.vv  @e64 -> trap",        "e64", "0xa22120f7", 1);
    SEW_CASE("vsm4r.vv   @e16 -> trap",        "e16", "0xa22820f7", 1);
    SEW_CASE("vsm3me.vv  @e16 -> trap",        "e16", "0x8221a0f7", 1);
    SEW_CASE("vghsh.vv   @e16 -> trap",        "e16", "0xb221a0f7", 1);
    SEW_CASE("vsha2ms.vv @e8  -> trap",        "e8",  "0xb621a0f7", 1);
    SEW_CASE("vsha2ms.vv @e16 -> trap",        "e16", "0xb621a0f7", 1);
    SEW_CASE("vsha2ms.vv @e32 -> ok",          "e32", "0xb621a0f7", 0);
    SEW_CASE("vsha2ms.vv @e64 -> ok (Zvknhb)", "e64", "0xb621a0f7", 0);
    #undef SEW_CASE

    return fails ? 1 : 0;
}
