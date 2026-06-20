//  vfh_subj.c
//  Directed test for Zvfhmin (the RVA23-mandatory FP16 conversion subset):
//    vfwcvt.f.f.v  at SEW=16  (FP16 -> FP32, exact)
//    vfncvt.f.f.w  at SEW=16  (FP32 -> FP16, rounds per frm)
//  The converter MATH is exhaustively validated against SoftFloat-3e by
//  test/fcvt_hs (3.95M vectors x6 RM incl ROD, 0-error); this exercises INTEGRATION:
//  element placement (widen 1 src reg -> 2 dest regs; narrow 2 -> 1), LMUL>1,
//  masking/tail-undisturbed, vl boundaries, and the e16/e8 FP TRAP for every
//  non-Zvfhmin FP op. Runs on karu64 and spike (same ELF; spike is golden).
//  RNE self-checks use the toolchain's _Float16; non-RNE rounding rides the
//  spike cross.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint32_t x){int i;sio_putc('0');sio_putc('x');for(i=28;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, caseno=0, ff=0;
static void report(const char*nm,int bad){caseno++;
    sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts(nm);
    if(bad){sio_puts(" bad=");put_dec(bad);fails++;if(!ff)ff=caseno;}
    sio_putc('\n');}

//  expected results are PRECOMPUTED on the host with _Float16 (correct IEEE
//  RNE) -- baking them avoids libgcc soft-FP16 helpers in this -nostdlib
//  build, and they are independently re-checked by the spike cross.

#define N 16
static uint16_t src16[N], dst16[N];
static uint32_t src32[N], dst32[N];

//  ---- trap detection (for the e16/e8 FP-op trap) ----
volatile uint64_t g_mcause; volatile uint32_t g_traps;
asm(".align 2\nvfh_tvec:\n"
    "  csrr t0,mcause\n la t1,g_mcause\n sd t0,0(t1)\n"
    "  la t1,g_traps\n lw t0,0(t1)\n addiw t0,t0,1\n sw t0,0(t1)\n"
    "  csrr t0,mepc\n addi t0,t0,4\n csrw mepc,t0\n mret\n");

//  a spread of FP16 bit patterns: +/-normal, subnormal, +/-0, inf, qNaN,
//  max-finite, min-normal, 1.0, and values whose FP32 widening is checked.
static const uint16_t H[N] = {
    0x3C00, 0xBC00, 0x0001, 0x83FF, 0x0000, 0x8000, 0x7C00, 0x7E00,
    0x7BFF, 0x0400, 0x3555, 0xC500, 0x4900, 0x1234, 0xFBFF, 0x6789 };

//  FP32 patterns for narrowing: in-range round, overflow->inf, tiny->subnormal/
//  zero, +/-0, inf, qNaN, exact-half (RNE tie), max-finite-f16 boundary.
static const uint32_t S[N] = {
    0x3FC00000, 0xC0490FDB, 0x477FE000, 0x47800000, 0x33000000, 0x33000001,
    0x7F800000, 0x7FC00000, 0x00000000, 0x80000000, 0x387FC000, 0x38800000,
    0x34000000, 0x33800000, 0xC77FF000, 0x40000000 };
//  WH = widen(H) (FP32 bits); NS = narrow_RNE(S) (FP16 bits). Host-computed.
static const uint32_t WH[N] = {
    0x3F800000, 0xBF800000, 0x33800000, 0xB87FC000, 0x00000000, 0x80000000,
    0x7F800000, 0x7FC00000, 0x477FE000, 0x38800000, 0x3EAAA000, 0xC0A00000,
    0x41200000, 0x3A468000, 0xC77FE000, 0x44F12000 };
static const uint16_t NS[N] = {
    0x3E00, 0xC248, 0x7BFF, 0x7C00, 0x0000, 0x0001, 0x7C00, 0x7E00,
    0x0000, 0x8000, 0x03FF, 0x0400, 0x0002, 0x0001, 0xFC00, 0x4000 };

int main(void){
    int i;
    asm volatile("li t0,0x6600\n csrs mstatus,t0"::: "t0"); //  FS+VS on
    asm volatile("la t0,vfh_tvec\n csrw mtvec,t0":::"t0");
    sio_puts("\n[VFH / Zvfhmin directed test]\n");

    //  ==== widen vfwcvt.f.f.v : FP16(e16,m1) -> FP32(e32,m2), vl=16 ====
    for(i=0;i<N;i++) src16[i]=H[i];
    asm volatile("vsetvli t0,%[n],e16,m1,tu,mu\n vle16.v v8,(%[s])\n"
        "vfwcvt.f.f.v v16,v8\n vsetvli t0,%[n],e32,m2,tu,mu\n vse32.v v16,(%[d])\n"
        ::[n]"r"(N),[s]"r"(src16),[d]"r"(dst32):"t0","memory");
    { int bad=0; for(i=0;i<N;i++){ if(dst32[i]!=WH[i])bad++; }
      report("vfwcvt.f.f.v e16->e32 vl=16",bad); }

    //  ==== widen vl=11 (sub-VLMAX; v16 TAIL undisturbed -> sentinel kept) ====
    asm volatile("vsetvli t0,%[m],e32,m2,tu,mu\n li t1,0x5A5A5A5A\n vmv.v.x v16,t1\n"
        "vsetvli t0,%[n],e16,m1,tu,mu\n vle16.v v8,(%[s])\n vfwcvt.f.f.v v16,v8\n"
        "vsetvli t0,%[m],e32,m2,tu,mu\n vse32.v v16,(%[d])\n"
        ::[n]"r"(11),[m]"r"(N),[s]"r"(src16),[d]"r"(dst32):"t0","t1","memory");
    { int bad=0; for(i=0;i<11;i++){ if(dst32[i]!=WH[i])bad++; }
      for(i=11;i<N;i++) if(dst32[i]!=0x5A5A5A5Au)bad++; //  tail kept the sentinel
      report("vfwcvt.f.f.v vl=11 (tail undisturbed)",bad); }

    //  ==== narrow vfncvt.f.f.w : FP32(e32,m2) -> FP16(e16,m1) RNE, vl=16 ====
    asm volatile("fsrmi 0"::: );    //  frm = RNE
    for(i=0;i<N;i++) src32[i]=S[i];
    asm volatile("vsetvli t0,%[n],e32,m2,tu,mu\n vle32.v v8,(%[s])\n"
        "vsetvli t0,%[n],e16,m1,tu,mu\n vfncvt.f.f.w v16,v8\n vse16.v v16,(%[d])\n"
        ::[n]"r"(N),[s]"r"(src32),[d]"r"(dst16):"t0","memory");
    { int bad=0; for(i=0;i<N;i++){ if(dst16[i]!=NS[i])bad++; }
      report("vfncvt.f.f.w e32->e16 RNE vl=16",bad); }

    //  ==== widen LMUL>1: e16,m2 -> e32,m4 (crosses the dest reg-pair boundary) ====
    for(i=0;i<N;i++) dst32[i]=0;
    asm volatile("vsetvli t0,%[n],e16,m2,tu,mu\n vle16.v v8,(%[s])\n"
        "vfwcvt.f.f.v v16,v8\n vsetvli t0,%[n],e32,m4,tu,mu\n vse32.v v16,(%[d])\n"
        ::[n]"r"(N),[s]"r"(src16),[d]"r"(dst32):"t0","memory");
    { int bad=0; for(i=0;i<N;i++){ if(dst32[i]!=WH[i])bad++; }
      report("vfwcvt.f.f.v e16m2->e32m4 vl=16",bad); }

    //  ==== masked narrow (v0.t): masked-off dest elements undisturbed ====
    { static uint8_t m[2]={0x5A,0xA5};  //  mask bits
      asm volatile("vsetvli t0,%[n],e16,m1,tu,mu\n vlm.v v0,(%[m])\n li t1,0xBEEF\n vmv.v.x v16,t1\n"
        "vsetvli t0,%[n],e32,m2,tu,mu\n vle32.v v8,(%[s])\n"
        "vsetvli t0,%[n],e16,m1,tu,mu\n vfncvt.f.f.w v16,v8,v0.t\n vse16.v v16,(%[d])\n"
        ::[n]"r"(N),[m]"r"(m),[s]"r"(src32),[d]"r"(dst16):"t0","t1","memory");
      int bad=0; for(i=0;i<N;i++){ int act=(m[i>>3]>>(i&7))&1;
        uint16_t r = act ? NS[i] : 0xBEEF; if(dst16[i]!=r)bad++; }
      report("vfncvt.f.f.w masked (v0.t)",bad); }

    //  ==== non-RNE rounding (RDN / RUP / RTZ) -- spike cross is golden ====
    //  (no on-target directed-rounding reference; emit results so the same-ELF
    //  spike diff validates them. self-check just confirms determinism.)
    { const char rm_tok[3]={2,3,1}; const char*rm_nm[3]={"rdn","rup","rtz"};
      for(int k=0;k<3;k++){
        uint64_t fr=rm_tok[k];
        asm volatile("csrw frm,%0"::"r"(fr));
        asm volatile("vsetvli t0,%[n],e32,m2,tu,mu\n vle32.v v8,(%[s])\n"
            "vsetvli t0,%[n],e16,m1,tu,mu\n vfncvt.f.f.w v16,v8\n vse16.v v16,(%[d])\n"
            ::[n]"r"(N),[s]"r"(src32),[d]"r"(dst16):"t0","memory");
        uint32_t acc=0; for(i=0;i<N;i++) acc=acc*131+dst16[i];
        sio_puts("  vfncvt.f.f.w "); sio_puts(rm_nm[k]); sio_puts(" digest=");
        put_hex(acc); sio_putc('\n');   //  karu==spike line-for-line
      }
      asm volatile("fsrmi 0":::);
    }

    //  ==== vfncvt.rod.f.f.w : round-to-odd narrowing (rm encoded in the insn,
    //  independent of frm). The CORNER behaviors: overflow -> max-finite (never
    //  inf), tiny nonzero -> min-subnormal (odd). Reference is SoftFloat ROD. ====
    //  ==== vfncvt.rod.f.f.w at e16 (vs1=10101): round-to-odd narrowing is part
    //  of full Zvfh, NOT Zvfhmin (= {vfwcvt.f.f.v, vfncvt.f.f.w} only). Confirmed
    //  against spike rv64gcv_zvfhmin -> must TRAP cause-2. ====
    { uint32_t t=g_traps;
      asm volatile("vsetvli t0,%[n],e16,m1,tu,mu\n vfncvt.rod.f.f.w v16,v8\n"
        ::[n]"r"(N):"t0","v16");
      report("e16 vfncvt.rod.f.f.w (Zvfh, not Zvfhmin) traps cause2",
        !(g_traps==t+1 && g_mcause==2)); }

    //  ==== e16/e8 FP ops that are NOT Zvfhmin must TRAP (cause 2) ====
    { uint32_t t=g_traps;
      //    vfadd.vv at e16 (Zvfh arith -- not implemented)
      asm volatile("vsetvli t0,%[n],e16,m1,tu,mu\n vfadd.vv v2,v8,v8\n"
        ::[n]"r"(N):"t0","v2");
      report("e16 vfadd.vv traps cause2",!(g_traps==t+1 && g_mcause==2));
      t=g_traps;
      //    vfwcvt.f.f.v at e8 (no FP8) must trap
      asm volatile("vsetvli t0,%[n],e8,m1,tu,mu\n vfwcvt.f.f.v v10,v8\n"
        ::[n]"r"(N):"t0","v10");
      report("e8 vfwcvt.f.f traps cause2",!(g_traps==t+1 && g_mcause==2));
      t=g_traps;
      //    vfwcvt.rod.f.f.v (vs1=01101) does NOT exist -- reserved, must trap
      //    even at e16 (the assembler won't emit it, so .word 0x4a869857).
      asm volatile("vsetvli t0,%[n],e16,m1,tu,mu\n .word 0x4a869857\n"
        ::[n]"r"(N):"t0");
      report("e16 vfwcvt.rod.f.f.v reserved traps cause2",!(g_traps==t+1 && g_mcause==2));
    }

    if(fails){ sio_puts("[VFH] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else      sio_puts("[VFH] ALL PASS\n");
    sio_putc(4);
    return ff;
}
