//  vperm_subj.c
//  Self-checking directed test for the karu64 VPERM ops (slides, gather,
//  compress, iota). Designed to be run on BOTH spike (rv64gcv, golden) and
//  karu64: each case computes the result with the vector instruction, stores
//  it back, and compares against a scalar C reference derived straight from
//  the RVV 1.0 spec. main() returns 0 iff every case matches (HTIF exit 0);
//  a nonzero return encodes the first failing case number.
//
//  Determinism: every op runs with tail-undisturbed / mask-undisturbed
//  (tu,mu) so tail and masked-off elements simply keep the old vd value
//  (a sentinel we preload). This avoids the agnostic (0xFF vs old)
//  implementation freedom and makes spike and karu64 bit-identical.

#include <stdint.h>
#include "sio_generic.h"

#define SENT  0xEEEEEEEEu           //  sentinel preloaded into the dest group

//  scratch arrays (static -> .bss, zeroed)
static uint32_t src[64];
static uint32_t dst[64];
static uint32_t ref[64];
static uint32_t idx32[64];
static uint16_t idx16[64];
static uint8_t  mbits[16];          //  v0 mask, one bit per element

//  wider/narrower-element scratch (separate typed views)
static uint8_t  src8[256], dst8[256], ref8[256], idx8[256];
static uint64_t src64[64], dst64[64], ref64[64], idx64[64];

//  ---- tiny hex printer (htif.c only gives putc/puts) ----
static void put_hex(uint32_t x)
{
    int i;
    sio_putc('0'); sio_putc('x');
    for (i = 28; i >= 0; i -= 4)
        sio_putc("0123456789abcdef"[(x >> i) & 0xf]);
}
static void put_dec(uint32_t x)
{
    char b[10]; int n = 0;
    if (x == 0) { sio_putc('0'); return; }
    while (x) { b[n++] = '0' + (x % 10); x /= 10; }
    while (n) sio_putc(b[--n]);
}

static int fails = 0;
static int caseno = 0;
static int first_fail = 0;

//  compare dst[0..n) against ref[0..n); report.
static void check(const char *name, int n)
{
    int i, bad = 0;
    caseno++;
    for (i = 0; i < n; i++)
        if (dst[i] != ref[i]) bad++;
    sio_puts(bad ? "[FAIL] " : "[ ok ] ");
    sio_puts(name);
    if (bad) {
        sio_puts("  mism="); put_dec(bad);
        for (i = 0; i < n; i++)
            if (dst[i] != ref[i]) {
                sio_puts("\n        i="); put_dec(i);
                sio_puts(" got="); put_hex(dst[i]);
                sio_puts(" exp="); put_hex(ref[i]);
            }
        fails++;
        if (!first_fail) first_fail = caseno;
    }
    sio_putc('\n');
}

//  mask helpers (v0 bit i)
static int mact(int i) { return (mbits[i >> 3] >> (i & 7)) & 1; }
static void set_mask_pattern(int vmax)
{
    int i;
    for (i = 0; i < 16; i++) mbits[i] = 0;
    //  keep ~ every other + a couple extra active
    for (i = 0; i < vmax; i++)
        if ((i & 1) == 0 || i == 3 || i == 7) mbits[i >> 3] |= (1u << (i & 7));
}

//  ======================================================================
//  The op runners. Each: preload v8(=src group), maybe v4(=index), maybe
//  v0(=mask), preload v16(=dest) with SENT at VLMAX; run op at vl_op; then
//  store v16 (VLMAX elements) into dst[].  e32, m2 unless noted.
//  ======================================================================

#define PRE_E32M2 \
    "vsetvli t0, %[vmax], e32, m2, tu, mu\n" \
    "vle32.v v8, (%[s])\n" \
    "vmv.v.x v16, %[sent]\n"

#define STORE_E32M2 \
    "vsetvli t0, %[vmax], e32, m2, tu, mu\n" \
    "vse32.v v16, (%[d])\n"

static void run_slideup_vx(uint32_t off, int vl_op, int vmax)
{
    asm volatile(PRE_E32M2
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vslideup.vx v16, v8, %[off]\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op), [off]"r"((long)off)
        : "t0","memory");
}
static void run_slidedown_vx(uint32_t off, int vl_op, int vmax)
{
    asm volatile(PRE_E32M2
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vslidedown.vx v16, v8, %[off]\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op), [off]"r"((long)off)
        : "t0","memory");
}
static void run_slide1up_vx(uint32_t x, int vl_op, int vmax)
{
    asm volatile(PRE_E32M2
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vslide1up.vx v16, v8, %[x]\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op), [x]"r"((long)x)
        : "t0","memory");
}
static void run_slide1down_vx(uint32_t x, int vl_op, int vmax)
{
    asm volatile(PRE_E32M2
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vslide1down.vx v16, v8, %[x]\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op), [x]"r"((long)x)
        : "t0","memory");
}
static void run_gather_vv(int vl_op, int vmax)
{
    asm volatile(
        "vsetvli t0, %[vmax], e32, m2, tu, mu\n"
        "vle32.v v8, (%[s])\n"
        "vle32.v v4, (%[ix])\n"
        "vmv.v.x v16, %[sent]\n"
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vrgather.vv v16, v8, v4\n"
        STORE_E32M2
        :: [s]"r"(src), [ix]"r"(idx32), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op)
        : "t0","memory");
}
static void run_gather_vx(uint32_t x, int vl_op, int vmax)
{
    asm volatile(PRE_E32M2
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vrgather.vx v16, v8, %[x]\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op), [x]"r"((long)x)
        : "t0","memory");
}
static void run_gather_vi5(int vl_op, int vmax) //  uimm = 5
{
    asm volatile(PRE_E32M2
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vrgather.vi v16, v8, 5\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op)
        : "t0","memory");
}
static void run_gatherei16(int vl_op, int vmax)
{
    //  index EEW=16, EMUL = 16/32 * 2 = 1 reg -> v4
    asm volatile(
        "vsetvli t0, %[vmax], e32, m2, tu, mu\n"
        "vle32.v v8, (%[s])\n"
        "vmv.v.x v16, %[sent]\n"
        "vsetvli t0, %[vmax], e16, m1, tu, mu\n"
        "vle16.v v4, (%[ix])\n"
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vrgatherei16.vv v16, v8, v4\n"
        STORE_E32M2
        :: [s]"r"(src), [ix]"r"(idx16), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op)
        : "t0","memory");
}
static void run_compress(int vl_op, int vmax)
{
    //  vs1 = mask register; build it in v1 via vlm.v from mbits.
    asm volatile(
        "vsetvli t0, %[vmax], e32, m2, tu, mu\n"
        "vle32.v v8, (%[s])\n"
        "vmv.v.x v16, %[sent]\n"
        "vlm.v v1, (%[m])\n"
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vcompress.vm v16, v8, v1\n"
        STORE_E32M2
        :: [s]"r"(src), [m]"r"(mbits), [d]"r"(dst), [sent]"r"(SENT),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op)
        : "t0","memory");
}
//  vcompress with vd == vs2 (RVV reserved encoding). karu does not trap
//  reserved encodings; the source group is buffered before any write, so the
//  old vd == source and the overlap is benign. Regression only; gated behind
//  -DVCOMPRESS_OVL since spike hangs on this encoding (can't be the golden).
#ifdef VCOMPRESS_OVL
static void run_compress_ovl(int vl_op, int vmax)
{
    asm volatile(
        "vsetvli t0, %[vmax], e32, m2, tu, mu\n"
        "vle32.v v8, (%[s])\n"          //  v8 = source AND dest (vd==vs2)
        "vlm.v v1, (%[m])\n"
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vcompress.vm v8, v8, v1\n"
        "vsetvli t0, %[vmax], e32, m2, tu, mu\n"
        "vse32.v v8, (%[d])\n"
        :: [s]"r"(src), [m]"r"(mbits), [d]"r"(dst),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op)
        : "t0","memory");
}
#endif  //  VCOMPRESS_OVL
static void run_viota(int vl_op, int vmax, int masked)
{
    //  source mask = vs2 (v1); v0 = predicate mask (only used if masked).
    if (masked)
        asm volatile(
            "vsetvli t0, %[vmax], e32, m2, tu, mu\n"
            "vmv.v.x v16, %[sent]\n"
            "vlm.v v1, (%[sm])\n"
            "vlm.v v0, (%[pm])\n"
            "vsetvli t0, %[vl], e32, m2, tu, mu\n"
            "viota.m v16, v1, v0.t\n"
            STORE_E32M2
            :: [sm]"r"(mbits), [pm]"r"(mbits), [d]"r"(dst), [sent]"r"(SENT),
               [vmax]"r"((long)vmax), [vl]"r"((long)vl_op)
            : "t0","memory");
    else
        asm volatile(
            "vsetvli t0, %[vmax], e32, m2, tu, mu\n"
            "vmv.v.x v16, %[sent]\n"
            "vlm.v v1, (%[sm])\n"
            "vsetvli t0, %[vl], e32, m2, tu, mu\n"
            "viota.m v16, v1\n"
            STORE_E32M2
            :: [sm]"r"(mbits), [d]"r"(dst), [sent]"r"(SENT),
               [vmax]"r"((long)vmax), [vl]"r"((long)vl_op)
            : "t0","memory");
}

//  masked slide/gather variants (load v0 first)
static void run_slideup_vx_m(uint32_t off, int vl_op, int vmax)
{
    asm volatile(PRE_E32M2
        "vlm.v v0, (%[m])\n"
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vslideup.vx v16, v8, %[off], v0.t\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT), [m]"r"(mbits),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op), [off]"r"((long)off)
        : "t0","memory");
}
static void run_gather_vx_m(uint32_t x, int vl_op, int vmax)
{
    asm volatile(PRE_E32M2
        "vlm.v v0, (%[m])\n"
        "vsetvli t0, %[vl], e32, m2, tu, mu\n"
        "vrgather.vx v16, v8, %[x], v0.t\n"
        STORE_E32M2
        :: [s]"r"(src), [d]"r"(dst), [sent]"r"(SENT), [m]"r"(mbits),
           [vmax]"r"((long)vmax), [vl]"r"((long)vl_op), [x]"r"((long)x)
        : "t0","memory");
}

//  ======================================================================
//  references (tu,mu: tail & masked-off keep SENT)
//  ======================================================================
static void ref_clear(int vmax) { for (int i = 0; i < vmax; i++) ref[i] = SENT; }

static void ref_slideup(uint32_t off, int vl_op, int vmax, int masked)
{
    ref_clear(vmax);
    for (int i = 0; i < vl_op; i++) {
        if ((uint32_t)i < off) continue;            //  prestart: undisturbed
        if (masked && !mact(i)) continue;           //  masked-off: undisturbed
        ref[i] = src[i - off];
    }
}
static void ref_slidedown(uint32_t off, int vl_op, int vmax)
{
    ref_clear(vmax);
    for (int i = 0; i < vl_op; i++) {
        uint32_t s = (uint32_t)i + off;
        ref[i] = (s < (uint32_t)vmax) ? src[s] : 0;
    }
}
static void ref_slide1up(uint32_t x, int vl_op, int vmax)
{
    ref_clear(vmax);
    for (int i = 0; i < vl_op; i++)
        ref[i] = (i == 0) ? x : src[i - 1];
}
static void ref_slide1down(uint32_t x, int vl_op, int vmax)
{
    ref_clear(vmax);
    for (int i = 0; i < vl_op; i++)
        ref[i] = (i == vl_op - 1) ? x : src[i + 1];
}
static void ref_gather(int vl_op, int vmax, int masked) //  idx in idx32[]
{
    ref_clear(vmax);
    for (int i = 0; i < vl_op; i++) {
        if (masked && !mact(i)) continue;
        uint32_t ix = idx32[i];
        ref[i] = (ix < (uint32_t)vmax) ? src[ix] : 0;
    }
}
static void ref_gather_const(uint32_t ix, int vl_op, int vmax, int masked)
{
    ref_clear(vmax);
    for (int i = 0; i < vl_op; i++) {
        if (masked && !mact(i)) continue;
        ref[i] = (ix < (uint32_t)vmax) ? src[ix] : 0;
    }
}
static void ref_gatherei16(int vl_op, int vmax)
{
    ref_clear(vmax);
    for (int i = 0; i < vl_op; i++) {
        uint32_t ix = idx16[i];
        ref[i] = (ix < (uint32_t)vmax) ? src[ix] : 0;
    }
}
static void ref_compress(int vl_op, int vmax)
{
    ref_clear(vmax);
    int d = 0;
    for (int j = 0; j < vl_op; j++)
        if (mact(j)) ref[d++] = src[j];
}
//  vd==vs2 overlap: "old vd" is the source itself, so the undisturbed tail
//  keeps src[] (not the SENT sentinel). Packed elements read the original src.
#ifdef VCOMPRESS_OVL
static void ref_compress_ovl(int vl_op, int vmax)
{
    int d = 0, i;
    for (i = 0; i < vmax; i++) ref[i] = src[i];     //  old vd == vs2 == src
    for (i = 0; i < vl_op; i++)
        if (mact(i)) ref[d++] = src[i];
}
#endif
static void ref_viota(int vl_op, int vmax, int masked)
{
    ref_clear(vmax);
    uint32_t cnt = 0;
    for (int i = 0; i < vl_op; i++) {
        int act = masked ? mact(i) : 1;
        int sbit = mact(i);             //  source mask uses the same bit pattern (mbits)
        if (act) ref[i] = cnt;
        if (sbit && act) cnt++;
    }
}

//  ======================================================================
//  wider/narrower-width coverage: e8/m4 (128 elems) and e64/m1 (4 elems),
//  plus a fractional-LMUL (mf2) gather to exercise the VLMAX formula.
//  ======================================================================
static void check8(const char *name, int n)
{
    int i, bad = 0; caseno++;
    for (i = 0; i < n; i++) if (dst8[i] != ref8[i]) bad++;
    sio_puts(bad ? "[FAIL] " : "[ ok ] "); sio_puts(name);
    if (bad) {
        sio_puts("  mism="); put_dec(bad);
        for (i = 0; i < n; i++) if (dst8[i] != ref8[i]) {
            sio_puts("\n        i="); put_dec(i);
            sio_puts(" got="); put_hex(dst8[i]); sio_puts(" exp="); put_hex(ref8[i]);
        }
        fails++; if (!first_fail) first_fail = caseno;
    }
    sio_putc('\n');
}
static void check64(const char *name, int n)
{
    int i, bad = 0; caseno++;
    for (i = 0; i < n; i++) if (dst64[i] != ref64[i]) bad++;
    sio_puts(bad ? "[FAIL] " : "[ ok ] "); sio_puts(name);
    if (bad) {
        sio_puts("  mism="); put_dec(bad);
        for (i = 0; i < n; i++) if (dst64[i] != ref64[i]) {
            sio_puts("\n        i="); put_dec(i);
            sio_puts(" got="); put_hex((uint32_t)dst64[i]);
            sio_puts(" exp="); put_hex((uint32_t)ref64[i]);
        }
        fails++; if (!first_fail) first_fail = caseno;
    }
    sio_putc('\n');
}

//  -- e8 / m4 runners (vmax=128) --
static void run8_gather_vv(int vl, int vmax) {
    asm volatile(
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n vle8.v v8,(%[s])\n vle8.v v4,(%[ix])\n"
        "li t1,0xEE\n vmv.v.x v16,t1\n"
        "vsetvli t0,%[vl],e8,m4,tu,mu\n vrgather.vv v16,v8,v4\n"
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n vse8.v v16,(%[d])\n"
        :: [s]"r"(src8),[ix]"r"(idx8),[d]"r"(dst8),
           [vmax]"r"((long)vmax),[vl]"r"((long)vl):"t0","t1","memory");
}
static void run8_slidedown_vx(uint32_t off,int vl,int vmax){
    asm volatile(
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n vle8.v v8,(%[s])\n li t1,0xEE\n vmv.v.x v16,t1\n"
        "vsetvli t0,%[vl],e8,m4,tu,mu\n vslidedown.vx v16,v8,%[off]\n"
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n vse8.v v16,(%[d])\n"
        :: [s]"r"(src8),[d]"r"(dst8),[vmax]"r"((long)vmax),[vl]"r"((long)vl),
           [off]"r"((long)off):"t0","t1","memory");
}
static void run8_compress(int vl,int vmax){
    asm volatile(
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n vle8.v v8,(%[s])\n li t1,0xEE\n vmv.v.x v16,t1\n"
        "vlm.v v1,(%[m])\n"
        "vsetvli t0,%[vl],e8,m4,tu,mu\n vcompress.vm v16,v8,v1\n"
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n vse8.v v16,(%[d])\n"
        :: [s]"r"(src8),[m]"r"(mbits),[d]"r"(dst8),[vmax]"r"((long)vmax),
           [vl]"r"((long)vl):"t0","t1","memory");
}
static void run8_viota(int vl,int vmax){
    asm volatile(
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n li t1,0xEE\n vmv.v.x v16,t1\n vlm.v v1,(%[m])\n"
        "vsetvli t0,%[vl],e8,m4,tu,mu\n viota.m v16,v1\n"
        "vsetvli t0,%[vmax],e8,m4,tu,mu\n vse8.v v16,(%[d])\n"
        :: [m]"r"(mbits),[d]"r"(dst8),[vmax]"r"((long)vmax),
           [vl]"r"((long)vl):"t0","t1","memory");
}

//  -- e64 / m1 runners (vmax=4) --
static void run64_gather_vv(int vl,int vmax){
    asm volatile(
        "vsetvli t0,%[vmax],e64,m1,tu,mu\n vle64.v v8,(%[s])\n vle64.v v4,(%[ix])\n"
        "li t1,-1\n vmv.v.x v16,t1\n"       //  sentinel 0xFFFF... (distinct)
        "vsetvli t0,%[vl],e64,m1,tu,mu\n vrgather.vv v16,v8,v4\n"
        "vsetvli t0,%[vmax],e64,m1,tu,mu\n vse64.v v16,(%[d])\n"
        :: [s]"r"(src64),[ix]"r"(idx64),[d]"r"(dst64),
           [vmax]"r"((long)vmax),[vl]"r"((long)vl):"t0","t1","memory");
}
static void run64_slideup_vx(uint32_t off,int vl,int vmax){
    asm volatile(
        "vsetvli t0,%[vmax],e64,m1,tu,mu\n vle64.v v8,(%[s])\n li t1,-1\n vmv.v.x v16,t1\n"
        "vsetvli t0,%[vl],e64,m1,tu,mu\n vslideup.vx v16,v8,%[off]\n"
        "vsetvli t0,%[vmax],e64,m1,tu,mu\n vse64.v v16,(%[d])\n"
        :: [s]"r"(src64),[d]"r"(dst64),[vmax]"r"((long)vmax),[vl]"r"((long)vl),
           [off]"r"((long)off):"t0","t1","memory");
}
//  -- fractional LMUL (mf2) e32 gather: VLMAX = VLEN/SEW/2 = 4 --
static void run_gather_vv_mf2(int vl,int vmax){
    asm volatile(
        "vsetvli t0,%[vmax],e32,mf2,tu,mu\n vle32.v v8,(%[s])\n vle32.v v4,(%[ix])\n"
        "vmv.v.x v16,%[sent]\n"
        "vsetvli t0,%[vl],e32,mf2,tu,mu\n vrgather.vv v16,v8,v4\n"
        "vsetvli t0,%[vmax],e32,mf2,tu,mu\n vse32.v v16,(%[d])\n"
        :: [s]"r"(src),[ix]"r"(idx32),[d]"r"(dst),[sent]"r"(SENT),
           [vmax]"r"((long)vmax),[vl]"r"((long)vl):"t0","memory");
}

int main(void)
{
    int i;
    const int vmax = 16;                //  e32, m2, VLEN=256 -> 16 elements

    //  enable FS + VS in mstatus (both start as Off; vector insns trap illegal otherwise)
    asm volatile("li t0, 0x6600\n csrs mstatus, t0" ::: "t0");

    sio_puts("\n[VPERM directed test]\n");

    for (i = 0; i < vmax; i++) {
        src[i]   = 0x1000 + i * 0x11;
        idx32[i] = (uint32_t)((vmax - 1 - i));      //  reversal
        idx16[i] = (uint16_t)((i * 3) % vmax);      //  stride-3 wrap
    }
    idx32[2]  = 99;                     //  out-of-range -> 0
    idx16[5]  = 50;                     //  out-of-range -> 0
    set_mask_pattern(vmax);

    //  slides (.vx)
    run_slideup_vx(3, vmax, vmax);   ref_slideup(3, vmax, vmax, 0);   check("vslideup.vx off=3 vl=16", vmax);
    run_slideup_vx(1, 12, vmax);     ref_slideup(1, 12, vmax, 0);     check("vslideup.vx off=1 vl=12", vmax);
    run_slideup_vx(20, vmax, vmax);  ref_slideup(20, vmax, vmax, 0);  check("vslideup.vx off=20 (all prestart)", vmax);
    run_slidedown_vx(3, vmax, vmax); ref_slidedown(3, vmax, vmax);    check("vslidedown.vx off=3 vl=16", vmax);
    run_slidedown_vx(5, 10, vmax);   ref_slidedown(5, 10, vmax);      check("vslidedown.vx off=5 vl=10", vmax);
    run_slidedown_vx(20, vmax, vmax);ref_slidedown(20, vmax, vmax);   check("vslidedown.vx off=20 (->0)", vmax);
    run_slide1up_vx(0xAA55, vmax, vmax);   ref_slide1up(0xAA55, vmax, vmax);   check("vslide1up.vx vl=16", vmax);
    run_slide1down_vx(0xBB66, vmax, vmax); ref_slide1down(0xBB66, vmax, vmax); check("vslide1down.vx vl=16", vmax);
    run_slide1down_vx(0xCC77, 9, vmax);    ref_slide1down(0xCC77, 9, vmax);    check("vslide1down.vx vl=9", vmax);

    //  gather
    run_gather_vv(vmax, vmax);       ref_gather(vmax, vmax, 0);       check("vrgather.vv reversal vl=16", vmax);
    run_gather_vv(10, vmax);         ref_gather(10, vmax, 0);         check("vrgather.vv reversal vl=10", vmax);
    run_gather_vx(4, vmax, vmax);    ref_gather_const(4, vmax, vmax, 0); check("vrgather.vx x=4", vmax);
    run_gather_vx(99, vmax, vmax);   ref_gather_const(99, vmax, vmax, 0);check("vrgather.vx x=99 (->0)", vmax);
    run_gather_vi5(vmax, vmax);      ref_gather_const(5, vmax, vmax, 0); check("vrgather.vi imm=5", vmax);
    run_gatherei16(vmax, vmax);      ref_gatherei16(vmax, vmax);      check("vrgatherei16.vv vl=16", vmax);

    //  compress
    run_compress(vmax, vmax);        ref_compress(vmax, vmax);        check("vcompress.vm vl=16", vmax);
    run_compress(11, vmax);          ref_compress(11, vmax);          check("vcompress.vm vl=11", vmax);
    //  -- vcompress corner cases --
    //  vl=0: nothing packed -> whole dest stays old vd (SENT)
    run_compress(0, vmax);           ref_compress(0, vmax);           check("vcompress.vm vl=0 (dest undisturbed)", vmax);
    //  all mask bits zero: nothing selected -> dest stays old vd (SENT)
    for (i = 0; i < 16; i++) mbits[i] = 0;
    run_compress(vmax, vmax);        ref_compress(vmax, vmax);        check("vcompress.vm all-mask-off", vmax);
    //  sparse mask straddling the m2 register boundary (elem 8): pick 6,7,8,9,15
    for (i = 0; i < 16; i++) mbits[i] = 0;
    mbits[0] = (1u<<6) | (1u<<7);               //  elems 6,7 (end of reg 0)
    mbits[1] = (1u<<0) | (1u<<1) | (1u<<7);     //  elems 8,9,15 (reg 1)
    run_compress(vmax, vmax);        ref_compress(vmax, vmax);        check("vcompress.vm sparse near reg boundary", vmax);
    set_mask_pattern(vmax);                     //  restore canonical mask for iota below

    //  iota
    run_viota(vmax, vmax, 0);        ref_viota(vmax, vmax, 0);        check("viota.m unmasked vl=16", vmax);
    run_viota(vmax, vmax, 1);        ref_viota(vmax, vmax, 1);        check("viota.m masked vl=16", vmax);

    //  masked slide / gather
    run_slideup_vx_m(2, vmax, vmax); ref_slideup(2, vmax, vmax, 1);   check("vslideup.vx off=2 masked", vmax);
    run_gather_vx_m(6, vmax, vmax);  ref_gather_const(6, vmax, vmax, 1);check("vrgather.vx x=6 masked", vmax);

    //  ==== e8 / m4 (128 elements, 4-register group) ====
    {
        const int v8m = 128;
        for (i = 0; i < v8m; i++) { src8[i] = (uint8_t)(0x40 + i); idx8[i] = (uint8_t)(v8m - 1 - i); }
        idx8[10] = 200;                 //  out-of-range -> 0
        for (i = 0; i < 16; i++) mbits[i] = 0;
        for (i = 0; i < v8m; i++) if ((i % 3) == 0) mbits[i >> 3] |= (1u << (i & 7));
        run8_gather_vv(v8m, v8m);
        { for (i=0;i<v8m;i++) ref8[i]=0xEE; for(i=0;i<v8m;i++){uint8_t ix=idx8[i]; ref8[i]=(ix<v8m)?src8[ix]:0;} }
        check8("e8/m4 vrgather.vv reversal vl=128", v8m);
        run8_slidedown_vx(5, v8m, v8m);
        { for(i=0;i<v8m;i++) ref8[i]=0xEE; for(i=0;i<v8m;i++){int s=i+5; ref8[i]=(s<v8m)?src8[s]:0;} }
        check8("e8/m4 vslidedown.vx off=5 vl=128", v8m);
        run8_compress(v8m, v8m);
        { int d=0; for(i=0;i<v8m;i++) ref8[i]=0xEE; for(i=0;i<v8m;i++) if(mact(i)) ref8[d++]=src8[i]; }
        check8("e8/m4 vcompress.vm vl=128", v8m);
        run8_viota(v8m, v8m);
        { uint32_t c=0; for(i=0;i<v8m;i++) ref8[i]=0xEE; for(i=0;i<v8m;i++){ ref8[i]=(uint8_t)c; if(mact(i)) c++; } }
        check8("e8/m4 viota.m vl=128", v8m);
        //  LMUL>1 packed output crosses the e8 register boundary (32 elems/reg):
        //  first 45 elements selected -> 45 packed -> reg0[0..31] + reg1[32..44].
        for (i = 0; i < 16; i++) mbits[i] = 0;
        for (i = 0; i < 45; i++) mbits[i >> 3] |= (1u << (i & 7));
        run8_compress(v8m, v8m);
        { int d=0; for(i=0;i<v8m;i++) ref8[i]=0xEE; for(i=0;i<v8m;i++) if(mact(i)) ref8[d++]=src8[i]; }
        check8("e8/m4 vcompress.vm packed crosses reg boundary", v8m);
        //  packed-count matrix (streaming dest pack):
        //  first-n masks put the packed count exactly on the granule (16 e8
        //  elements) and register (32) boundaries +/-1, plus the empty/full
        //  extremes. count<16 ends in granule 0 (the zero-BE granule-1 pad
        //  case); 32 = one mid-scan register drain; 128 = all-selected (the
        //  last register's fill IS the op-ending drain). Counts identical on
        //  non-streaming builds, so the same ELF crosses on spike.
        {
            static const int cnts[9] = {0, 1, 15, 16, 17, 31, 32, 33, 128};
            int c, n;
            for (c = 0; c < 9; c++) {
                n = cnts[c];
                for (i = 0; i < 16; i++) mbits[i] = 0;
                for (i = 0; i < n; i++) mbits[i >> 3] |= (1u << (i & 7));
                run8_compress(v8m, v8m);
                { int d=0; for(i=0;i<v8m;i++) ref8[i]=0xEE; for(i=0;i<v8m;i++) if(mact(i)) ref8[d++]=src8[i]; }
                sio_puts("  packed count "); put_dec((uint32_t)n); sio_puts(": ");
                check8("e8/m4 vcompress.vm count matrix", v8m);
            }
        }
    }

    //  ==== e64 / m1 (4 elements) ====
    {
        const int v64m = 4;
        for (i = 0; i < v64m; i++) { src64[i] = 0x1111000000000000ULL + i; idx64[i] = (uint64_t)(v64m - 1 - i); }
        idx64[1] = 77;                  //  out-of-range -> 0
        run64_gather_vv(v64m, v64m);
        { for(i=0;i<v64m;i++) ref64[i]=~0ULL; for(i=0;i<v64m;i++){uint64_t ix=idx64[i]; ref64[i]=(ix<(uint64_t)v64m)?src64[ix]:0;} }
        check64("e64/m1 vrgather.vv reversal vl=4", v64m);
        run64_slideup_vx(1, v64m, v64m);
        { for(i=0;i<v64m;i++) ref64[i]=~0ULL; for(i=1;i<v64m;i++) ref64[i]=src64[i-1]; }
        check64("e64/m1 vslideup.vx off=1 vl=4", v64m);
    }

    //  ==== fractional LMUL mf2 e32 (VLMAX = 4) gather ====
    {
        const int vfm = 4;              //  256/32/2
        for (i = 0; i < vfm; i++) { src[i] = 0x2000 + i; idx32[i] = (uint32_t)(vfm - 1 - i); }
        idx32[0] = 9;                   //  >= VLMAX(4) -> 0 (tests fractional VLMAX)
        run_gather_vv_mf2(vfm, vfm);
        { for(i=0;i<vfm;i++) ref[i]=SENT; for(i=0;i<vfm;i++){uint32_t ix=idx32[i]; ref[i]=(ix<(uint32_t)vfm)?src[ix]:0;} }
        check("mf2 e32 vrgather.vv (frac VLMAX) vl=4", vfm);
    }

    //  ==== vcompress.vm vd==vs2 overlap (RVV reserved encoding) ====
    //  karu does NOT trap reserved encodings, and because vcompress buffers its
    //  source group before any write the overlap is benign (old vd == source;
    //  tail keeps src). karu was confirmed to produce that benign result. But
    //  *spike* HANGS on this reserved encoding (verified 2026-05-28, exit 124 --
    //  the same way it hangs on vfrec7/vfrsqrt7), so it CANNOT be the golden:
    //  this case is gated out of the shared (karu + spike) ELF and only built
    //  under -DVCOMPRESS_OVL for a karu-only regression. Not ISA-required unless
    //  decode later traps reserved encodings.
#ifdef VCOMPRESS_OVL
    {
        for (i = 0; i < vmax; i++) src[i] = 0x1000 + i * 0x11;  //  restore clean source
        set_mask_pattern(vmax);
        run_compress_ovl(vmax, vmax);
        ref_compress_ovl(vmax, vmax);
        check("vcompress.vm vd==vs2 overlap (reserved, benign)", vmax);
    }
#endif

    if (fails) {
        sio_puts("[VPERM] FAILURES: "); put_dec(fails); sio_putc('\n');
    } else {
        sio_puts("[VPERM] ALL PASS\n");
    }
    sio_putc(4);
    return first_fail;          //  0 = pass; else first failing case number
}
