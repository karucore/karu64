//  vresv_subj.c
//  Directed reserved-encoding and legal-overlap regression: vill, indexed
//  loads, widening/narrowing, extension/permute geometry and mask destinations.
//  One ELF on Karu and Spike checks their common trapping policy and the
//  allowed overlap shapes. ACT4/Sail covers strict mixed-EEW source rejection,
//  for which Spike permits some reserved encodings to execute.

#include <stdint.h>
#include "sio_generic.h"

#define SENT 0xEE

static uint8_t  mem[256] __attribute__((aligned(16)));
static uint8_t  dst[256] __attribute__((aligned(16)));

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, caseno=0, ff=0;
static void verdict(const char*nm,int bad){
    caseno++;
    sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts(nm); sio_putc('\n');
    if(bad){ fails++; if(!ff) ff=caseno; }
}

volatile uint64_t g_mcause;
volatile uint32_t g_traps;
asm(".align 2\n"
    "vresv_tvec:\n"
    "  csrr  t0, mcause\n"
    "  la    t1, g_mcause\n"
    "  sd    t0, 0(t1)\n"
    "  la    t1, g_traps\n"
    "  lw    t0, 0(t1)\n"
    "  addiw t0, t0, 1\n"
    "  sw    t0, 0(t1)\n"
    "  csrr  t0, mepc\n"
    "  addi  t0, t0, 4\n"
    "  csrw  mepc, t0\n"
    "  mret\n");

static void width_legality(void)
{
#define RESERVED(TYPE, INSN) do { \
    uint32_t before = g_traps; \
    asm volatile("vsetvli t0,zero," TYPE ",tu,mu\n" INSN \
                 ::: "t0", "t1", "memory"); \
    verdict(INSN " @ " TYPE, g_traps != before+1 || g_mcause != 2); \
} while (0)
    RESERVED("e64,m1", "vwaddu.vv v16,v8,v4");
    RESERVED("e8,m8", "vwaddu.vv v16,v8,v0");
    RESERVED("e16,m2", "vwaddu.vv v18,v8,v4");
    RESERVED("e16,m2", "vwaddu.vv v16,v9,v4");
    RESERVED("e16,m2", "vwaddu.vv v16,v8,v5");
    RESERVED("e16,m1", "vwaddu.vv v16,v16,v4");
    RESERVED("e16,m1", "vwaddu.vv v16,v8,v16");
    RESERVED("e8,mf2", "vwaddu.vx v16,v16,zero");
    RESERVED("e16,m1", "vwaddu.vv v0,v8,v4,v0.t");
    RESERVED("e16,m1", "vwaddu.wv v16,v9,v4");
    RESERVED("e16,m2", "vwaddu.wv v16,v8,v5");
    RESERVED("e16,m1", "vwaddu.wv v16,v8,v16");
    RESERVED("e64,m1", "vwaddu.wx v16,v8,zero");
    RESERVED("e64,m1", "vwmulu.vv v16,v8,v4");
    RESERVED("e8,m8", "vwmul.vx v16,v8,zero");
    RESERVED("e16,m2", "vwmacc.vv v18,v8,v4");
    RESERVED("e8,mf2", "vwmaccu.vv v16,v16,v4");
    RESERVED("e64,m1", "vnsrl.wi v16,v8,1");
    RESERVED("e8,m8", "vnsra.wx v16,v8,zero");
    RESERVED("e16,m2", "vnsrl.wv v17,v8,v4");
    RESERVED("e16,m1", "vnsrl.wi v16,v9,1");
    RESERVED("e16,m2", "vnsrl.wv v16,v8,v5");
    RESERVED("e16,m1", "vnsrl.wi v17,v16,1");
    RESERVED("e16,m1", "vnclipu.wi v0,v8,1,v0.t");
    RESERVED("e64,m1", "vnclip.wi v16,v8,1");
    RESERVED("e8,m1", "vadd.vv v0,v8,v4,v0.t");
    RESERVED("e8,m1", "vmerge.vvm v0,v8,v4,v0");
    RESERVED("e32,m1", "vfadd.vv v0,v8,v4,v0.t");
    RESERVED("e8,m1", "vle8.v v0,(zero),v0.t");
    RESERVED("e8,m1", "vmsbf.m v0,v8,v0.t");
    RESERVED("e8,m1", "vmsif.m v0,v8,v0.t");
    RESERVED("e8,m1", "vmsof.m v0,v8,v0.t");
    RESERVED("e64,m1", "vmsbf.m v0,v8,v0.t");
    RESERVED("e64,m1", "vmsif.m v0,v8,v0.t");
    RESERVED("e64,m1", "vmsof.m v0,v8,v0.t");
    RESERVED("e8,m1", "vslideup.vi v8,v8,0");
    RESERVED("e8,m2", "vslideup.vx v8,v8,zero");
    RESERVED("e8,m1", "vslide1up.vx v8,v8,zero");
    RESERVED("e32,m1", "vfslide1up.vf v8,v8,f0");
    RESERVED("e8,m1", "vrgather.vv v8,v8,v4");
    RESERVED("e8,m2", "vrgather.vv v8,v4,v8");
    RESERVED("e32,m1", "vfwadd.vv v8,v8,v4");
    RESERVED("e64,m1", "vfwredusum.vs v16,v8,v4");
    RESERVED("e64,m1", "vwredsum.vs v16,v8,v4");
    RESERVED("e16,m2", "vzext.vf2 v8,v8");
    RESERVED("e32,m4", "vsext.vf4 v8,v9");
    RESERVED("e64,m8", "vzext.vf8 v8,v9");
    RESERVED("e8,m1", "vcompress.vm v8,v8,v0");
    RESERVED("e8,m1", "vcompress.vm v0,v8,v0");
#undef RESERVED
    uint32_t before = g_traps;
    asm volatile(
        "vsetvli t0,zero,e32,m2,tu,mu\n vmv.v.i v16,7\n"
        "vsetvli t0,zero,e16,m1,tu,mu\n vmv.v.i v8,3\n"
        "vwaddu.wv v16,v16,v8\n"
        "vsetvli t0,zero,e32,m2,tu,mu\n vse32.v v16,(%0)\n"
        :: "r"(dst) : "t0", "t1", "memory");
    int bad = g_traps != before;
    for (int i=0; i<16; ++i) if (((uint32_t *)dst)[i] != 10) ++bad;
    verdict("widen .w legal same-wide-source overlap", bad);
    before = g_traps;
    asm volatile(
        "vsetvli t0,zero,e16,m1,tu,mu\n"
        "vnsrl.wi v16,v16,1\n vse16.v v16,(%0)\n"
        :: "r"(dst) : "t0", "t1", "memory");
    bad = g_traps != before;
    for (int i=0; i<16; ++i) if (((uint16_t *)dst)[i] != 5) ++bad;
    verdict("narrow legal low overlap", bad);
    before = g_traps;
    asm volatile(
        "vsetvli t0,zero,e16,m1,tu,mu\n"
        "vmv.v.i v0,-1\n vmv.v.i v2,1\n"
        "vwaddu.vv v4,v0,v2\n"
        "vsetvli t0,zero,e32,m2,tu,mu\n vse32.v v4,(%0)\n"
        :: "r"(dst) : "t0", "t1", "memory");
    bad = g_traps != before;
    for (int i=0; i<16; ++i) if (((uint32_t *)dst)[i] != 65536) ++bad;
    verdict("widen legal unmasked source v0", bad);
    before = g_traps;
    asm volatile(
        "vsetvli t0,zero,e16,m1,tu,mu\n"
        "vmv.v.i v0,-1\n vmv.v.i v2,1\n"
        "vmseq.vv v0,v2,v2,v0.t\n"
        "vmv.v.i v0,-1\n vredsum.vs v0,v2,v2,v0.t\n"
        "vse16.v v0,(%0)\n"
        :: "r"(dst) : "t0", "t1", "memory");
    verdict("masked v0 mask/scalar-reduction exceptions", g_traps != before || ((uint16_t *)dst)[0] != 17);
    before = g_traps;
    asm volatile(
        "vsetvli t0,zero,e32,m1,tu,mu\n vmv.v.i v0,-1\n"
        "vmv.v.i v2,0\n vmfeq.vv v0,v2,v2,v0.t\n"
        "vmv.v.i v0,-1\n vfredosum.vs v0,v2,v2,v0.t\n"
        "vse32.v v0,(%0)\n"
        :: "r"(dst) : "t0", "t1", "memory");
    verdict("masked v0 FP mask/reduction exceptions", g_traps != before || ((uint32_t *)dst)[0] != 0);
}

static void mask_exceptions(void)
{
    // Both min/max reductions may write v0 while reading its original mask.
    // Nonzero inputs ensure that merely not trapping is insufficient to pass.
#define FP_REDUCE(SEW, OP, ONE, TWO, EXPECT, CTYPE) do { \
    uint32_t before = g_traps; \
    asm volatile( \
        "vsetvli t0,zero," SEW ",m1,tu,mu\n vmv.v.i v0,-1\n" \
        "vmv.v.x v8,%1\n vmv.v.x v9,%2\n" \
        OP " v0,v8,v9,v0.t\n vse" #CTYPE ".v v0,(%0)\n" \
        :: "r"(dst), "r"(TWO), "r"(ONE) \
        : "t0", "t1", "memory", "v0", "v8", "v9", "vl", "vtype"); \
    verdict(OP " masked vd=v0 @ " SEW, \
            g_traps != before || ((uint##CTYPE##_t *)dst)[0] != (EXPECT)); \
} while (0)
    FP_REDUCE("e32", "vfredmin.vs", 0x3f800000UL, 0x40000000UL, 0x3f800000U, 32);
    FP_REDUCE("e32", "vfredmax.vs", 0x3f800000UL, 0x40000000UL, 0x40000000U, 32);
    FP_REDUCE("e64", "vfredmin.vs", 0x3ff0000000000000UL, 0x4000000000000000UL, 0x3ff0000000000000UL, 64);
    FP_REDUCE("e64", "vfredmax.vs", 0x3ff0000000000000UL, 0x4000000000000000UL, 0x4000000000000000UL, 64);
#undef FP_REDUCE
    // Prefix masks may still write v0 when unmasked, or another destination
    // when masked. Check all three selectors, not just the rejected forms.
#define PREFIX(OP, VD, MASK, EXPECT) do { \
    uint32_t before = g_traps; \
    asm volatile( \
        "vsetivli t0,8,e8,m1,tu,mu\n vmv.v.i v8,0\n" \
        "li t0,16\n vmv.s.x v8,t0\n vmv.v.i v0,-1\n" \
        OP " " VD ",v8" MASK "\n vsm.v " VD ",(%0)\n" \
        :: "r"(dst) : "t0", "t1", "memory", "v0", "v4", "v8", "vl", "vtype"); \
    verdict(OP " " VD MASK " legal", g_traps != before || dst[0] != (EXPECT)); \
} while (0)
    PREFIX("vmsbf.m", "v0", "", 0x0f);
    PREFIX("vmsif.m", "v0", "", 0x1f);
    PREFIX("vmsof.m", "v0", "", 0x10);
    PREFIX("vmsbf.m", "v4", ",v0.t", 0x0f);
    PREFIX("vmsif.m", "v4", ",v0.t", 0x1f);
    PREFIX("vmsof.m", "v4", ",v0.t", 0x10);
#undef PREFIX
}

static void vtype_legality(void)
{
    const uint64_t vill = UINT64_C(1) << 63;
    uint64_t vt, vl, rd, start;
    uint32_t before;

    // All XLEN bits matter, even when the low fields describe legal e16,m2.
    // Seed nonzero vl/vstart so an invalid request must actively clear them.
    for (unsigned bit = 8; bit < 64; bit++) {
        uint64_t request = (UINT64_C(1) << bit) | 9;
        before = g_traps;
        asm volatile(
            "vsetvli t0,zero,e16,m2,tu,mu\n"
            "csrwi vstart,3\n"
            "vsetvl %[rd],zero,%[request]\n"
            "csrr %[vt],vtype\n"
            "csrr %[vl],vl\n"
            "csrr %[start],vstart\n"
            : [rd]"=&r"(rd), [vt]"=&r"(vt), [vl]"=&r"(vl),
              [start]"=&r"(start)
            : [request]"r"(request) : "t0", "t1", "memory");
        sio_puts("vtype bit "); put_dec(bit); sio_puts(": ");
        verdict("vsetvl rejects unsupported bit",
                g_traps != before || vt != vill || vl != 0 || rd != 0 || start != 0);
    }

    // Linux __riscv_v_vstate_discard requests only vill, with rs1=x0.
    before = g_traps;
    asm volatile(
        "vsetvli t0,zero,e8,m1,tu,mu\n"
        "vsetvl %[rd],zero,%[request]\n"
        "csrr %[vt],vtype\n"
        "csrr %[vl],vl\n"
        : [rd]"=&r"(rd), [vt]"=&r"(vt), [vl]"=&r"(vl)
        : [request]"r"(vill) : "t0", "t1", "memory");
    verdict("vill-only request clears vl and sets canonical vtype",
            g_traps != before || vt != vill || vl != 0 || rd != 0);
    before = g_traps;
    asm volatile("vadd.vv v1,v2,v3" ::: "t0", "t1", "memory");
    verdict("vill-only request makes vadd trap", g_traps != before+1 || g_mcause != 2);

    // Legal register and immediate forms recover from vill. Exercise the
    // normal AVL path as well as the rs1=x0 VLMAX path above.
    before = g_traps;
    asm volatile(
        "vsetvl %[rd],%[avl],%[request]\n"
        "csrr %[vt],vtype\n"
        "csrr %[vl],vl\n"
        : [rd]"=&r"(rd), [vt]"=&r"(vt), [vl]"=&r"(vl)
        : [avl]"r"(5UL), [request]"r"(9UL) : "t0", "t1", "memory");
    verdict("legal vsetvl recovers from vill",
            g_traps != before || vt != 9 || vl != 5 || rd != 5);
    before = g_traps;
    asm volatile(
        "vsetvl t0,zero,%[request]\n"
        "vsetivli %[rd],5,e8,m1,ta,ma\n"
        "csrr %[vt],vtype\n"
        "csrr %[vl],vl\n"
        "vadd.vv v1,v2,v3\n"
        : [rd]"=&r"(rd), [vt]"=&r"(vt), [vl]"=&r"(vl)
        : [request]"r"(vill) : "t0", "t1", "memory");
    verdict("vsetivli recovers from vill and vadd executes",
            g_traps != before || vt != 0xc0 || vl != 5 || rd != 5);
}

int main(void){
    int i; uint32_t t0n; uint64_t vtype_rd;
    for(i=0;i<256;i++) mem[i]=(uint8_t)(0x40+i);
    asm volatile("la t0, vresv_tvec\ncsrw mtvec, t0":::"t0");

    vtype_legality();

    //  ==== R1: vill set -> vadd traps illegal; vtype.vill readable ====
    t0n=g_traps;
    asm volatile(
        "li t0, -1\n"                   //  reserved vtype -> vill
        "vsetvl t1, x0, t0\n"
        "csrr %[vt], vtype\n"
        "vadd.vv v1,v2,v3\n"            //  depends on vtype -> must trap
        : [vt]"=&r"(vtype_rd) :: "t0","t1","memory");
    verdict("vill: vadd traps", !( g_traps==t0n+1 && g_mcause==2 &&
                                   (vtype_rd >> 63)==1 ));

    //  ==== R2: vill set -> whole-register LOAD still executes (the only
    //  vill exemptions are vset* and whole-register loads/stores; even
    //  vmv<nr>r.v traps -- spike agrees) ====
    t0n=g_traps;
    for(i=0;i<64;i++) dst[i]=SENT;
    asm volatile(
        "li t0, -1\n"
        "vsetvl t1, x0, t0\n"               //  vill set
        "vl1re8.v v1,(%[m])\n"              //  whole-reg load: must NOT trap
        "vs1r.v v1,(%[d])\n"                //  whole-reg store: must NOT trap
        :: [m]"r"(mem),[d]"r"(dst) : "t0","t1","memory");
    { int bad=(g_traps!=t0n);
      for(i=0;i<32;i++) if(dst[i]!=mem[i]) bad++;
      verdict("vill: vl1re8/vs1r execute", bad); }

    //  ==== R3: reserved indexed overlap traps (vluxei8 v4,(x),v4 @ e32) ====
    //  dest EEW(32) > index EEW(8) with index EMUL = 1/4 < 1 -> RVV 5.2
    //  reserved. (The encoding spike 1.1.1-dev traps; karu64's v_idxov_ill.)
    t0n=g_traps;
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle8.v  v4,(%[ix])\n"
        ".word 0x064c0207\n"            //  vluxei8.v v4,(s8),v4 -- reserved
        :: [vl]"r"(8),[ix]"r"(mem) : "t0","s8","memory");
    verdict("idx overlap reserved traps", !(g_traps==t0n+1 && g_mcause==2));

    //  ==== R4: LEGAL highest-part overlap executes ====
    //  SEW=e16 LMUL=2: data group {v4,v5}; index e8 EMUL=1 in v5 (highest).
    t0n=g_traps;
    for(i=0;i<64;i++) dst[i]=SENT;
    {
        static uint8_t ix8[16];
        for(i=0;i<16;i++) ix8[i]=(uint8_t)((15-i)*2);
        asm volatile(
            "vsetvli t0,%[vl],e16,m2,tu,mu\n"
            "vsetvli t0,%[vl8],e8,m1,tu,mu\n"
            "vle8.v v5,(%[ix])\n"
            "vsetvli t0,%[vl],e16,m2,tu,mu\n"
            "vluxei8.v v4,(%[m]),v5\n"      //  overlap at highest part: legal
            "vse16.v v4,(%[d])\n"
            :: [vl]"r"(16),[vl8]"r"(16),[ix]"r"(ix8),[m]"r"(mem),[d]"r"(dst)
            : "t0","memory");
        { int bad=(g_traps!=t0n);
          for(i=0;i<16;i++){
            uint16_t got=(uint16_t)dst[2*i] | ((uint16_t)dst[2*i+1]<<8);
            uint16_t exp=(uint16_t)mem[(15-i)*2] | ((uint16_t)mem[(15-i)*2+1]<<8);
            if(got!=exp) bad++;
          }
          verdict("idx overlap legal-high executes", bad); }
    }

    //  ==== R5: LEGAL lowest-part overlap executes ====
    //  SEW=e8 LMUL=1: data {v4}; index e16 EMUL=2 {v4,v5}; vd at lowest part.
    t0n=g_traps;
    for(i=0;i<64;i++) dst[i]=SENT;
    {
        static uint16_t ix16[16];
        for(i=0;i<16;i++) ix16[i]=(uint16_t)(31-2*i);
        asm volatile(
            "vsetvli t0,%[vl],e8,m1,tu,mu\n"
            "vsetvli t0,%[vl16],e16,m2,tu,mu\n"
            "vle16.v v4,(%[ix])\n"
            "vsetvli t0,%[vl],e8,m1,tu,mu\n"
            "vluxei16.v v4,(%[m]),v4\n"     //  vd at lowest part: legal
            "vse8.v v4,(%[d])\n"
            :: [vl]"r"(16),[vl16]"r"(16),[ix]"r"(ix16),[m]"r"(mem),[d]"r"(dst)
            : "t0","memory");
        { int bad=(g_traps!=t0n);
          for(i=0;i<16;i++) if(dst[i]!=mem[31-2*i]) bad++;
          verdict("idx overlap legal-low executes", bad); }
    }

    //  ==== R6: genuinely-illegal opcodes VECTOR as cause-2 (not core halt).
    //  0x0000 is the defined 16-bit illegal; 0xFFFFFFFF is an undefined
    //  32-bit major opcode. Both must reach the handler with mcause 2 and
    //  execution must continue (the handler's +4 skip covers both forms).
    t0n=g_traps;
    asm volatile(".word 0x00000000\n");
    verdict("16b illegal vectors cause 2", !(g_traps==t0n+1 && g_mcause==2));
    t0n=g_traps;
    asm volatile(".word 0xFFFFFFFF\n");
    verdict("32b illegal vectors cause 2", !(g_traps==t0n+1 && g_mcause==2));

    width_legality();
    mask_exceptions();
    if(fails){ sio_puts("[VRESV] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[VRESV] ALL PASS\n");
    sio_putc(4);
    return ff;
}
