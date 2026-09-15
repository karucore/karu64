//  zvbb_subj.c
//  Self-checking full-Zvbb test. The same ELF runs on karu64 and Spike.
//  Coverage: exhaustive e8 inputs for vbrev/vclz/vctz/vcpop; all unary
//  operations at every SEW and fractional/maximum LMUL; mask/tail
//  undisturbed; vwsll vv/vx/vi at every width; masked data sources; and an
//  LMUL=2 -> LMUL=4 plus maximum LMUL=4 -> LMUL=8 traversal. Fractional LMUL
//  cases also check that inactive register bytes remain unchanged.

#include <stddef.h>
#include <stdint.h>
#include "sio_generic.h"

#define ALIGNED __attribute__((aligned(64)))

enum { OP_BREV, OP_CLZ, OP_CTZ, OP_CPOP };

static uint8_t  in8[256] ALIGNED;
static uint8_t  out8[4][256] ALIGNED;
static uint16_t in16[16] ALIGNED, out16[4][16] ALIGNED;
static uint32_t in32[8] ALIGNED,  out32[4][8] ALIGNED;
static uint64_t in64[4] ALIGNED,  out64[4][4] ALIGNED;
static uint32_t masked32[8] ALIGNED;

static uint16_t ws2_16m2[32] ALIGNED, wsh_16m2[32] ALIGNED;
static uint32_t wout_16m2[32] ALIGNED;
static uint8_t  ws2_8m4[128] ALIGNED, wsh_8m4[128] ALIGNED;
static uint16_t wout_8m4[128] ALIGNED;
static uint8_t  wmask8[4] ALIGNED;
static uint8_t  ws2_8mf2[16] ALIGNED;
static uint16_t wout_8mf2[32] ALIGNED;
static uint16_t ws2_16[16] ALIGNED;
static uint32_t wout_16[16] ALIGNED;
static uint16_t v0src_16[16] ALIGNED, v0sh_16[16] ALIGNED;
static uint32_t ws2_32[8] ALIGNED, wsh_32[8] ALIGNED;
static uint64_t wout_32[8] ALIGNED;
static uint8_t  unary_frac[32] ALIGNED;

static int fails, first_fail, caseno;
static volatile uint64_t trap_mcause;
static volatile uint32_t trap_count;

asm(".align 2\n"
    "zvbb_tvec:\n"
    "  addi  sp, sp, -16\n"
    "  sd    t0, 0(sp)\n"
    "  sd    t1, 8(sp)\n"
    "  csrr  t0, mcause\n"
    "  la    t1, trap_mcause\n"
    "  sd    t0, 0(t1)\n"
    "  la    t1, trap_count\n"
    "  lw    t0, 0(t1)\n"
    "  addiw t0, t0, 1\n"
    "  sw    t0, 0(t1)\n"
    "  csrr  t0, mepc\n"
    "  addi  t0, t0, 4\n"
    "  csrw  mepc, t0\n"
    "  ld    t0, 0(sp)\n"
    "  ld    t1, 8(sp)\n"
    "  addi  sp, sp, 16\n"
    "  mret\n");

static void put_hex(uint64_t x)
{
    int i;
    sio_puts("0x");
    for (i = 60; i >= 0; i -= 4)
        sio_putc("0123456789abcdef"[(x >> i) & 15]);
}

static void put_dec(unsigned x)
{
    char b[12]; int n = 0;
    if (!x) { sio_putc('0'); return; }
    while (x) { b[n++] = '0' + x % 10; x /= 10; }
    while (n) sio_putc(b[--n]);
}

static uint64_t maskw(unsigned w)
{
    return w == 64 ? ~(uint64_t)0 : (((uint64_t)1 << w) - 1);
}

static uint64_t brev_ref(uint64_t x, unsigned w)
{
    uint64_t y = 0; unsigned i;
    for (i = 0; i < w; ++i) y |= ((x >> i) & 1) << (w - 1 - i);
    return y;
}

static uint64_t clz_ref(uint64_t x, unsigned w)
{
    unsigned n = 0;
    x &= maskw(w);
    while (n < w && ((x >> (w - 1 - n)) & 1) == 0) ++n;
    return n;
}

static uint64_t ctz_ref(uint64_t x, unsigned w)
{
    unsigned n = 0;
    x &= maskw(w);
    while (n < w && ((x >> n) & 1) == 0) ++n;
    return n;
}

static uint64_t cpop_ref(uint64_t x, unsigned w)
{
    unsigned n = 0, i;
    x &= maskw(w);
    for (i = 0; i < w; ++i) n += (x >> i) & 1;
    return n;
}

static uint64_t unary_ref(uint64_t x, unsigned w, unsigned op)
{
    if (op == OP_BREV) return brev_ref(x, w);
    if (op == OP_CLZ)  return clz_ref(x, w);
    if (op == OP_CTZ)  return ctz_ref(x, w);
    return cpop_ref(x, w);
}

static uint64_t get_el(const void *p, unsigned w, unsigned i)
{
    if (w == 8)  return ((const uint8_t *)p)[i];
    if (w == 16) return ((const uint16_t *)p)[i];
    if (w == 32) return ((const uint32_t *)p)[i];
    return ((const uint64_t *)p)[i];
}

static void check_unary(const char *name, const void *src, const void *got,
                        unsigned n, unsigned w, unsigned op)
{
    unsigned i, bad = 0, bi = 0; uint64_t gv = 0, ev = 0;
    ++caseno;
    for (i = 0; i < n; ++i) {
        gv = get_el(got, w, i);
        ev = unary_ref(get_el(src, w, i), w, op);
        if (gv != ev) { if (!bad) bi = i; ++bad; }
    }
    sio_puts(bad ? "[FAIL] " : "[ ok ] "); sio_puts(name);
    if (bad) {
        gv = get_el(got, w, bi); ev = unary_ref(get_el(src, w, bi), w, op);
        sio_puts(" i="); put_dec(bi); sio_puts(" got="); put_hex(gv);
        sio_puts(" exp="); put_hex(ev);
        ++fails; if (!first_fail) first_fail = caseno;
    }
    sio_putc('\n');
}

static void check_wide(const char *name, const void *src, const void *shifts,
                       const void *got, unsigned n, unsigned active,
                       unsigned w, uint64_t scalar, int form)
{
    unsigned i, bad = 0, bi = 0; uint64_t gv = 0, ev = 0, sh;
    const uint64_t sentinel = w == 8 ? 0xbeefU
                            : w == 16 ? 0xdeadbeefU
                            : 0xdeadbeefdeadbeefULL;
    ++caseno;
    for (i = 0; i < n; ++i) {
        gv = get_el(got, 2*w, i);
        sh = form == 0 ? get_el(shifts, w, i) : scalar;
        ev = i < active ? ((get_el(src, w, i) << (sh & (2*w - 1))) & maskw(2*w))
                        : sentinel;
        if (gv != ev) { if (!bad) bi = i; ++bad; }
    }
    sio_puts(bad ? "[FAIL] " : "[ ok ] "); sio_puts(name);
    if (bad) {
        gv = get_el(got, 2*w, bi);
        sh = form == 0 ? get_el(shifts, w, bi) : scalar;
        ev = bi < active ? ((get_el(src, w, bi) << (sh & (2*w - 1))) & maskw(2*w))
                         : sentinel;
        sio_puts(" i="); put_dec(bi); sio_puts(" got="); put_hex(gv);
        sio_puts(" exp="); put_hex(ev);
        ++fails; if (!first_fail) first_fail = caseno;
    }
    sio_putc('\n');
}

static void check_wide_mask8(const char *name, const uint8_t *src,
                             const uint16_t *got, unsigned n,
                             unsigned start, unsigned vl, unsigned shamt)
{
    unsigned i, bad = 0, bi = 0; uint16_t ev = 0;
    ++caseno;
    for (i = 0; i < n; ++i) {
        ev = (i >= start && i < vl && ((wmask8[i >> 3] >> (i & 7)) & 1))
           ? (uint16_t)((uint16_t)src[i] << (shamt & 15)) : 0xbeefU;
        if (got[i] != ev) { if (!bad) bi = i; ++bad; }
    }
    sio_puts(bad ? "[FAIL] " : "[ ok ] "); sio_puts(name);
    if (bad) {
        ev = (bi >= start && bi < vl && ((wmask8[bi >> 3] >> (bi & 7)) & 1))
           ? (uint16_t)((uint16_t)src[bi] << (shamt & 15)) : 0xbeefU;
        sio_puts(" i="); put_dec(bi); sio_puts(" got="); put_hex(got[bi]);
        sio_puts(" exp="); put_hex(ev);
        if (trap_count) {
            sio_puts(" traps="); put_dec(trap_count);
            sio_puts(" mcause="); put_hex(trap_mcause);
        }
        ++fails; if (!first_fail) first_fail = caseno;
    }
    sio_putc('\n');
}

static void check_wide_mask16(const char *name, const uint16_t *src,
                              const uint16_t *shifts, const uint32_t *got)
{
    unsigned i, bad = 0, bi = 0; uint32_t ev = 0;
    const uint16_t mask = v0src_16[0];
    ++caseno;
    for (i = 0; i < 16; ++i) {
        ev = ((mask >> i) & 1)
           ? (uint32_t)((uint32_t)src[i] << (shifts[i] & 31)) : 0xdeadbeefU;
        if (got[i] != ev) { if (!bad) bi = i; ++bad; }
    }
    sio_puts(bad ? "[FAIL] " : "[ ok ] "); sio_puts(name);
    if (bad) {
        ev = ((mask >> bi) & 1)
           ? (uint32_t)((uint32_t)src[bi] << (shifts[bi] & 31)) : 0xdeadbeefU;
        sio_puts(" i="); put_dec(bi); sio_puts(" got="); put_hex(got[bi]);
        sio_puts(" exp="); put_hex(ev);
        if (trap_count) { sio_puts(" traps="); put_dec(trap_count); }
        ++fails; if (!first_fail) first_fail = caseno;
    }
    sio_putc('\n');
}

static void check_illegal(const char *name, uint32_t before)
{
    int bad = trap_count != before + 1 || trap_mcause != 2;
    ++caseno;
    sio_puts(bad ? "[FAIL] " : "[ ok ] "); sio_puts(name); sio_putc('\n');
    if (bad) { ++fails; if (!first_fail) first_fail = caseno; }
}

static void run_unary(void)
{
    unsigned i;
    for (i = 0; i < 256; ++i) in8[i] = i;
    for (i = 0; i < 256; i += 32) {
        asm volatile(
            "vsetvli t0,zero,e8,m1,tu,mu\n"
            "vle8.v v8,(%[s])\n"
            "vbrev.v v9,v8\n vse8.v v9,(%[b])\n"
            "vclz.v v9,v8\n  vse8.v v9,(%[l])\n"
            "vctz.v v9,v8\n  vse8.v v9,(%[t])\n"
            "vcpop.v v9,v8\n vse8.v v9,(%[p])\n"
            :: [s]"r"(in8+i), [b]"r"(out8[OP_BREV]+i),
               [l]"r"(out8[OP_CLZ]+i), [t]"r"(out8[OP_CTZ]+i),
               [p]"r"(out8[OP_CPOP]+i) : "t0", "memory");
    }

    for (i = 0; i < 16; ++i)
        in16[i] = (uint16_t)(0x9e37U*i ^ (i == 0 ? 0 : (1U << (i & 15))));
    in16[0]=0; in16[1]=1; in16[2]=0x8000; in16[3]=0xffff;
    asm volatile(
        "vsetvli t0,zero,e16,m1,tu,mu\n vle16.v v8,(%[s])\n"
        "vbrev.v v9,v8\n vse16.v v9,(%[b])\n"
        "vclz.v v9,v8\n  vse16.v v9,(%[l])\n"
        "vctz.v v9,v8\n  vse16.v v9,(%[t])\n"
        "vcpop.v v9,v8\n vse16.v v9,(%[p])\n"
        :: [s]"r"(in16), [b]"r"(out16[OP_BREV]), [l]"r"(out16[OP_CLZ]),
           [t]"r"(out16[OP_CTZ]), [p]"r"(out16[OP_CPOP]) : "t0", "memory");

    for (i = 0; i < 8; ++i) in32[i] = 0x9e3779b9U*i ^ (1U << (i*4));
    in32[0]=0; in32[1]=1; in32[2]=0x80000000U; in32[3]=0xffffffffU;
    asm volatile(
        "vsetvli t0,zero,e32,m1,tu,mu\n vle32.v v8,(%[s])\n"
        "vbrev.v v9,v8\n vse32.v v9,(%[b])\n"
        "vclz.v v9,v8\n  vse32.v v9,(%[l])\n"
        "vctz.v v9,v8\n  vse32.v v9,(%[t])\n"
        "vcpop.v v9,v8\n vse32.v v9,(%[p])\n"
        :: [s]"r"(in32), [b]"r"(out32[OP_BREV]), [l]"r"(out32[OP_CLZ]),
           [t]"r"(out32[OP_CTZ]), [p]"r"(out32[OP_CPOP]) : "t0", "memory");

    in64[0]=0; in64[1]=1; in64[2]=0x8000000000000000ULL;
    in64[3]=0x0123456789abcdefULL;
    asm volatile(
        "vsetvli t0,zero,e64,m1,tu,mu\n vle64.v v8,(%[s])\n"
        "vbrev.v v9,v8\n vse64.v v9,(%[b])\n"
        "vclz.v v9,v8\n  vse64.v v9,(%[l])\n"
        "vctz.v v9,v8\n  vse64.v v9,(%[t])\n"
        "vcpop.v v9,v8\n vse64.v v9,(%[p])\n"
        :: [s]"r"(in64), [b]"r"(out64[OP_BREV]), [l]"r"(out64[OP_CLZ]),
           [t]"r"(out64[OP_CTZ]), [p]"r"(out64[OP_CPOP]) : "t0", "memory");

    check_unary("vbrev.v e8 exhaustive", in8, out8[OP_BREV], 256, 8, OP_BREV);
    check_unary("vclz.v e8 exhaustive",  in8, out8[OP_CLZ],  256, 8, OP_CLZ);
    check_unary("vctz.v e8 exhaustive",  in8, out8[OP_CTZ],  256, 8, OP_CTZ);
    check_unary("vcpop.v e8 exhaustive", in8, out8[OP_CPOP], 256, 8, OP_CPOP);
    for (i = 0; i < 4; ++i) {
        static const char *n16[] = {"vbrev.v e16","vclz.v e16","vctz.v e16","vcpop.v e16"};
        static const char *n32[] = {"vbrev.v e32","vclz.v e32","vctz.v e32","vcpop.v e32"};
        static const char *n64[] = {"vbrev.v e64","vclz.v e64","vctz.v e64","vcpop.v e64"};
        check_unary(n16[i], in16, out16[i], 16, 16, i);
        check_unary(n32[i], in32, out32[i], 8, 32, i);
        check_unary(n64[i], in64, out64[i], 4, 64, i);
    }

    //  Cross a physical-register boundary in the normal group engine.
    asm volatile(
        "vsetvli t0,zero,e8,m2,tu,mu\n vle8.v v8,(%[s])\n"
        "vbrev.v v16,v8\n vse8.v v16,(%[d])\n"
        :: [s]"r"(in8), [d]"r"(out8[OP_BREV]) : "t0", "memory");
    check_unary("vbrev.v e8 m2 traversal", in8, out8[OP_BREV], 64, 8, OP_BREV);

    //  Fractional LMUL: only the low half of v16 is active; the upper half of
    //  the same physical register must retain its sentinel bytes.
    for (i = 0; i < 32; ++i) unary_frac[i] = 0xa5;
    asm volatile(
        "vl1re8.v v16,(%[d])\n"
        "vsetvli t0,zero,e8,mf2,tu,mu\n vle8.v v8,(%[s])\n"
        "vclz.v v16,v8\n vs1r.v v16,(%[d])\n"
        :: [s]"r"(in8), [d]"r"(unary_frac) : "t0", "memory");
    ++caseno;
    for (i = 0; i < 32; ++i) {
        uint8_t exp = i < 16 ? (uint8_t)clz_ref(in8[i], 8) : 0xa5;
        if (unary_frac[i] != exp) {
            sio_puts("[FAIL] vclz.v e8 mf2 keep-upper i="); put_dec(i);
            sio_puts(" got="); put_hex(unary_frac[i]); sio_puts(" exp="); put_hex(exp); sio_putc('\n');
            ++fails; if (!first_fail) first_fail = caseno; break;
        }
    }
    if (i == 32) sio_puts("[ ok ] vclz.v e8 mf2 keep-upper\n");

    //  Maximum LMUL traversal covers all eight source and destination regs.
    asm volatile(
        "vsetvli t0,zero,e8,m8,tu,mu\n vle8.v v8,(%[s])\n"
        "vcpop.v v16,v8\n vse8.v v16,(%[d])\n"
        :: [s]"r"(in8), [d]"r"(out8[OP_CPOP]) : "t0", "memory");
    check_unary("vcpop.v e8 m8 traversal", in8, out8[OP_CPOP], 256, 8, OP_CPOP);

    //  One masked, short-VL case checks both mask- and tail-undisturbed bytes.
    for (i = 0; i < 8; ++i) masked32[i] = 0xdeadbeefU;
    asm volatile(
        "vsetvli t0,zero,e32,m1,tu,mu\n"
        "vle32.v v8,(%[s])\n vle32.v v9,(%[d])\n vmv.v.x v0,%[mk]\n"
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vcpop.v v9,v8,v0.t\n vs1r.v v9,(%[d])\n"
        :: [s]"r"(in32), [d]"r"(masked32), [mk]"r"(0x2dL), [vl]"r"(6L)
        : "t0", "memory");
    ++caseno;
    for (i = 0; i < 8; ++i) {
        uint32_t exp = (i < 6 && ((0x2dU >> i) & 1))
                     ? (uint32_t)cpop_ref(in32[i], 32) : 0xdeadbeefU;
        if (masked32[i] != exp) {
            sio_puts("[FAIL] vcpop.v mask/tail i="); put_dec(i);
            sio_puts(" got="); put_hex(masked32[i]); sio_puts(" exp="); put_hex(exp); sio_putc('\n');
            ++fails; if (!first_fail) first_fail = caseno; break;
        }
    }
    if (i == 8) sio_puts("[ ok ] vcpop.v mask/tail\n");
}

static void run_vwsll(void)
{
    unsigned i;
    //  vv, SEW=16 LMUL=2 -> EEW=32 EMUL=4. Short VL checks wide tail bytes.
    for (i = 0; i < 32; ++i) {
        ws2_16m2[i] = (uint16_t)(0x1234U + 0x1111U*i);
        wsh_16m2[i] = (uint16_t)(i*7 + 3);
        wout_16m2[i] = 0xdeadbeefU;
    }
    asm volatile(
        "vsetvli t0,zero,e32,m4,tu,mu\n vle32.v v16,(%[d])\n"
        "vsetvli t0,%[vl],e16,m2,tu,mu\n"
        "vle16.v v8,(%[s])\n vle16.v v10,(%[h])\n"
        "vwsll.vv v16,v8,v10\n"
        "vsetvli t0,zero,e32,m4,tu,mu\n vse32.v v16,(%[d])\n"
        :: [s]"r"(ws2_16m2), [h]"r"(wsh_16m2), [d]"r"(wout_16m2), [vl]"r"(27L)
        : "t0", "memory");
    check_wide("vwsll.vv e16 m2 tail", ws2_16m2, wsh_16m2, wout_16m2,
               32, 27, 16, 0, 0);

    //  Maximum legal LMUL: four narrow source registers widen into all eight
    //  destination registers. Shift values cover and exceed the e8 mask.
    for (i = 0; i < 128; ++i) {
        ws2_8m4[i] = (uint8_t)(0x59U + 29U*i);
        wsh_8m4[i] = (uint8_t)(3U + 11U*i);
        wout_8m4[i] = 0xbeefU;
    }
    asm volatile(
        "vsetvli t0,zero,e16,m8,tu,mu\n vle16.v v16,(%[d])\n"
        "vsetvli t0,zero,e8,m4,tu,mu\n"
        "vle8.v v8,(%[s])\n vle8.v v12,(%[h])\n"
        "vwsll.vv v16,v8,v12\n"
        "vsetvli t0,zero,e16,m8,tu,mu\n vse16.v v16,(%[d])\n"
        :: [s]"r"(ws2_8m4), [h]"r"(wsh_8m4), [d]"r"(wout_8m4)
        : "t0", "memory");
    check_wide("vwsll.vv e8 m4-to-m8", ws2_8m4, wsh_8m4, wout_8m4,
               128, 128, 8, 0, 0);

    //  A single case combines a short VL, masking, and undisturbed destination
    //  bytes on the widening path.
    wmask8[0]=0xad; wmask8[1]=0x52; wmask8[2]=0xf0; wmask8[3]=0x3c;
    for (i = 0; i < 32; ++i) wout_8m4[i] = 0xbeefU;
    asm volatile(
        "vsetvli t0,zero,e16,m2,tu,mu\n vle16.v v16,(%[d])\n"
        "vsetvli t0,zero,e8,m1,tu,mu\n vle8.v v8,(%[s])\n"
        "vsetvli t0,%[vl],e8,m1,tu,mu\n vlm.v v0,(%[m])\n"
        "vwsll.vi v16,v8,3,v0.t\n"
        "vsetvli t0,zero,e16,m2,tu,mu\n vse16.v v16,(%[d])\n"
        :: [s]"r"(ws2_8m4), [d]"r"(wout_8m4), [m]"r"(wmask8),
           [vl]"r"(29L) : "t0", "memory");
    check_wide_mask8("vwsll.vi mask/tail", ws2_8m4, wout_8m4,
                     32, 0, 29, 3);

    //  Fractional source LMUL=1/2 widens to one destination register. Loading
    //  and storing two whole registers makes an unintended v17 write visible.
    for (i = 0; i < 16; ++i) ws2_8mf2[i] = (uint8_t)(0x81U + 17U*i);
    for (i = 0; i < 32; ++i) wout_8mf2[i] = 0xbeefU;
    asm volatile(
        "vl2re8.v v16,(%[d])\n"
        "vsetvli t0,zero,e8,mf2,tu,mu\n vle8.v v8,(%[s])\n"
        "vwsll.vi v16,v8,5\n"
        "vs2r.v v16,(%[d])\n"
        :: [s]"r"(ws2_8mf2), [d]"r"(wout_8mf2) : "t0", "memory");
    check_wide("vwsll.vi e8 mf2 adjacent", ws2_8mf2, 0, wout_8mf2,
               32, 16, 8, 5, 2);
    // Last physical register: an empty extra destination pass must not wrap
    // around and change v0. Store the two canaries separately (no group wrap).
    for (i = 0; i < 32; ++i) wout_8mf2[i] = 0xbeefU;
    asm volatile(
        "vl1re8.v v31,(%[d])\n vl1re8.v v0,(%[c])\n"
        "vsetvli t0,zero,e8,mf2,tu,mu\n vle8.v v8,(%[s])\n"
        "vwsll.vi v31,v8,5\n"
        "vs1r.v v31,(%[d])\n vs1r.v v0,(%[c])\n"
        :: [s]"r"(ws2_8mf2), [d]"r"(wout_8mf2), [c]"r"(wout_8mf2+16)
        : "t0", "memory");
    check_wide("vwsll.vi e8 mf2 v31/v0 canary", ws2_8mf2, 0, wout_8mf2,
               32, 16, 8, 5, 2);

    //  vx, SEW=16 LMUL=1 -> EEW=32 EMUL=2.
    for (i = 0; i < 16; ++i) { ws2_16[i] = (uint16_t)(i*0x1021U+1); wout_16[i]=0xdeadbeefU; }
    asm volatile(
        "vsetvli t0,zero,e16,m1,tu,mu\n vle16.v v8,(%[s])\n"
        "vwsll.vx v16,v8,%[x]\n"
        "vsetvli t0,zero,e32,m2,tu,mu\n vse32.v v16,(%[d])\n"
        :: [s]"r"(ws2_16), [d]"r"(wout_16), [x]"r"(53L) : "t0", "memory");
    check_wide("vwsll.vx e16", ws2_16, 0, wout_16, 16, 16, 16, 53, 1);

    //  All three forms at SEW=32 exercise the full 64-bit widening result.
    for (i = 0; i < 8; ++i) {
        ws2_32[i] = 0x1020304U*(i+1); wsh_32[i] = 7U+13U*i;
        wout_32[i]=0xdeadbeefdeadbeefULL;
    }
    asm volatile(
        "vsetvli t0,zero,e32,m1,tu,mu\n vle32.v v8,(%[s])\n vle32.v v10,(%[h])\n"
        "vwsll.vv v16,v8,v10\n"
        "vsetvli t0,zero,e64,m2,tu,mu\n vse64.v v16,(%[d])\n"
        :: [s]"r"(ws2_32), [h]"r"(wsh_32), [d]"r"(wout_32) : "t0", "memory");
    check_wide("vwsll.vv e32", ws2_32, wsh_32, wout_32, 8, 8, 32, 0, 0);

    for (i = 0; i < 8; ++i) wout_32[i]=0xdeadbeefdeadbeefULL;
    asm volatile(
        "vsetvli t0,zero,e32,m1,tu,mu\n vle32.v v8,(%[s])\n"
        "vwsll.vx v16,v8,%[x]\n"
        "vsetvli t0,zero,e64,m2,tu,mu\n vse64.v v16,(%[d])\n"
        :: [s]"r"(ws2_32), [d]"r"(wout_32), [x]"r"(95L) : "t0", "memory");
    check_wide("vwsll.vx e32", ws2_32, 0, wout_32, 8, 8, 32, 95, 1);

    for (i = 0; i < 8; ++i) wout_32[i]=0xdeadbeefdeadbeefULL;
    asm volatile(
        "vsetvli t0,zero,e32,m1,tu,mu\n vle32.v v8,(%[s])\n"
        "vwsll.vi v16,v8,31\n"
        "vsetvli t0,zero,e64,m2,tu,mu\n vse64.v v16,(%[d])\n"
        :: [s]"r"(ws2_32), [d]"r"(wout_32) : "t0", "memory");
    check_wide("vwsll.vi e32 imm31", ws2_32, 0, wout_32, 8, 8, 32, 31, 2);

    //  RVV permits a narrow source in the high half of its wide destination.
    for (i = 0; i < 16; ++i) { ws2_16[i] = (uint16_t)(0x111U*i+3); wout_16[i]=0xdeadbeefU; }
    asm volatile(
        "vsetvli t0,zero,e16,m1,tu,mu\n vle16.v v17,(%[s])\n"
        "vwsll.vi v16,v17,4\n"
        "vsetvli t0,zero,e32,m2,tu,mu\n vse32.v v16,(%[d])\n"
        :: [s]"r"(ws2_16), [d]"r"(wout_16) : "t0", "memory");
    check_wide("vwsll.vi legal high overlap", ws2_16, 0, wout_16, 16, 16, 16, 4, 2);

    // Mask and element-data sources occupy different registers: RVV reserves
    // reading v0 simultaneously as an EEW=1 mask and wider element data.
    for (i = 0; i < 16; ++i) {
        v0src_16[i] = (uint16_t)(0x4101U + 0x123U*i);
        v0sh_16[i] = (uint16_t)(3U + 5U*i);
        wout_16[i] = 0xdeadbeefU;
    }
    v0src_16[0] = 0xa55aU;
    asm volatile(
        "vsetvli t0,zero,e32,m2,tu,mu\n vle32.v v4,(%[d])\n"
        "vsetvli t0,zero,e16,m1,tu,mu\n"
        "vle16.v v0,(%[s])\n vle16.v v8,(%[s])\n vle16.v v2,(%[h])\n"
        "vwsll.vv v4,v8,v2,v0.t\n"
        "vsetvli t0,zero,e32,m2,tu,mu\n vse32.v v4,(%[d])\n"
        :: [s]"r"(v0src_16), [h]"r"(v0sh_16), [d]"r"(wout_16)
        : "t0", "memory");
    check_wide_mask16("vwsll.vv masked data vs2", v0src_16, v0sh_16, wout_16);

    for (i = 0; i < 16; ++i) wout_16[i] = 0xdeadbeefU;
    asm volatile(
        "vsetvli t0,zero,e32,m2,tu,mu\n vle32.v v4,(%[d])\n"
        "vsetvli t0,zero,e16,m1,tu,mu\n"
        "vle16.v v0,(%[h])\n vle16.v v8,(%[h])\n vle16.v v2,(%[s])\n"
        "vwsll.vv v4,v2,v8,v0.t\n"
        "vsetvli t0,zero,e32,m2,tu,mu\n vse32.v v4,(%[d])\n"
        :: [s]"r"(ws2_16), [h]"r"(v0src_16), [d]"r"(wout_16)
        : "t0", "memory");
    check_wide_mask16("vwsll.vv masked data vs1", ws2_16, v0src_16, wout_16);
}

static void run_reserved(void)
{
    uint32_t n;
    asm volatile("la t0,zvbb_tvec\n csrw mtvec,t0" ::: "t0", "memory");

    n = trap_count;
    asm volatile("vsetvli t0,zero,e64,m1,tu,mu\n vwsll.vi v16,v8,1"
                 ::: "t0", "memory");
    check_illegal("vwsll e64 reserved", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e8,m8,tu,mu\n vwsll.vi v16,v8,1"
                 ::: "t0", "memory");
    check_illegal("vwsll LMUL=8 reserved", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e16,m2,tu,mu\n vwsll.vi v18,v8,1"
                 ::: "t0", "memory");
    check_illegal("vwsll misaligned wide dest", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e16,m1,tu,mu\n vwsll.vi v16,v16,1"
                 ::: "t0", "memory");
    check_illegal("vwsll illegal low overlap", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e8,mf2,tu,mu\n vwsll.vi v8,v8,1"
                 ::: "t0", "memory");
    check_illegal("vwsll fractional overlap reserved", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vwsll.vi v0,v8,1,v0.t"
                 ::: "t0", "memory");
    check_illegal("vwsll masked vd overlaps v0", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e16,m2,tu,mu\n vwsll.vv v16,v8,v11"
                 ::: "t0", "memory");
    check_illegal("vwsll.vv misaligned vs1", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n .word 0x4a25a0d7"
                 ::: "t0", "memory");
    check_illegal("VXUNARY0 selector 01011 reserved", n);

    n = trap_count;
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n .word 0x4a27a0d7"
                 ::: "t0", "memory");
    check_illegal("VXUNARY0 selector 01111 reserved", n);
}

int main(void)
{
    //  Keep unexpected illegal instructions diagnosable in the functional
    //  cases too, instead of falling through the reset-vector trap state.
    asm volatile("la t0,zvbb_tvec\n csrw mtvec,t0" ::: "t0", "memory");
    run_unary();
    run_vwsll();
    run_reserved();
    if (fails) { sio_puts("[ZVBB] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else sio_puts("[ZVBB] ALL PASS\n");
    sio_putc(4);
    return first_fail;
}
