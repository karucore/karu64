//  zfhmin_subj.c
//  Directed test for scalar Zfhmin (RVA23-mandatory FP16 minimal): the half
//  conversions fcvt.{s,d}.h / fcvt.h.{s,d}, the moves fmv.x.h / fmv.h.x, and
//  the half load/store flh / fsh. The converter MATH is separately validated
//  bit-exact vs SoftFloat-3e (make fcvt-hs-test: hs/sh/dh, millions of vectors
//  x6 rounding modes, 0-error); this exercises the DECODE + datapath + NaN-box
//  + load/store wiring on the core, run on karu64 AND spike (same ELF, spike
//  golden). Hand-checked anchors give absolute correctness; a rolling digest
//  over a sweep is compared line-for-line against spike.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[12];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, ff=0, cn=0;
static void chk(const char*nm,uint64_t got,uint64_t exp){
    cn++;
    if(got!=exp){ sio_puts("[FAIL] ");sio_puts(nm);sio_puts(" got=");put_hex(got);sio_puts(" exp=");put_hex(exp);sio_putc('\n');fails++;if(!ff)ff=cn; }
}

//  ---- frm / fflags control ----
static inline void set_frm(uint32_t m){ asm volatile("fsrm x0,%0"::"r"((uint64_t)m)); }
//  (fsrm rd,rs writes frm=rs[2:0]; rd=x0 discards old value.)

//  ---- conversion primitives (the result-only and result+flags forms) ----
//  Each clears fflags first; the fmv glue raises no flags, so the read-back
//  fflags reflects exactly the conversion.
static uint32_t cvt_s_h(uint16_t h,uint32_t*fl){
    uint64_t s,f;
    asm volatile("csrw fflags,x0\n\t fmv.h.x fa0,%2\n\t fcvt.s.h fa1,fa0\n\t"
                 "fmv.x.w %0,fa1\n\t csrr %1,fflags\n\t"
                 :"=r"(s),"=r"(f):"r"((uint64_t)h):"fa0","fa1");
    *fl=(uint32_t)f; return (uint32_t)s;
}
static uint16_t cvt_h_s(uint32_t s,uint32_t*fl){
    uint64_t h,f;
    asm volatile("csrw fflags,x0\n\t fmv.w.x fa0,%2\n\t fcvt.h.s fa1,fa0\n\t"
                 "fmv.x.h %0,fa1\n\t csrr %1,fflags\n\t"
                 :"=r"(h),"=r"(f):"r"((uint64_t)s):"fa0","fa1");
    *fl=(uint32_t)f; return (uint16_t)h;
}
static uint64_t cvt_d_h(uint16_t h,uint32_t*fl){
    uint64_t d,f;
    asm volatile("csrw fflags,x0\n\t fmv.h.x fa0,%2\n\t fcvt.d.h fa1,fa0\n\t"
                 "fmv.x.d %0,fa1\n\t csrr %1,fflags\n\t"
                 :"=r"(d),"=r"(f):"r"((uint64_t)h):"fa0","fa1");
    *fl=(uint32_t)f; return d;
}
static uint16_t cvt_h_d(uint64_t d,uint32_t*fl){
    uint64_t h,f;
    asm volatile("csrw fflags,x0\n\t fmv.d.x fa0,%2\n\t fcvt.h.d fa1,fa0\n\t"
                 "fmv.x.h %0,fa1\n\t csrr %1,fflags\n\t"
                 :"=r"(h),"=r"(f):"r"(d):"fa0","fa1");
    *fl=(uint32_t)f; return (uint16_t)h;
}

static volatile uint16_t hbuf;  //  2-byte aligned half buffer for flh/fsh

int main(void){
    uint32_t fl; uint64_t r;
    set_frm(0);     //  RNE
    sio_puts("\n[ZFHMIN scalar FP16 directed test]\n");

    //  ================= fcvt.s.h (H -> S, exact widen) =================
    chk("s.h +0",   cvt_s_h(0x0000,&fl),0x00000000); chk("s.h +0 fl",fl,0);
    chk("s.h -0",   cvt_s_h(0x8000,&fl),0x80000000); chk("s.h -0 fl",fl,0);
    chk("s.h 1.0",  cvt_s_h(0x3C00,&fl),0x3F800000); chk("s.h 1.0 fl",fl,0);
    chk("s.h -1.0", cvt_s_h(0xBC00,&fl),0xBF800000);
    chk("s.h 2.0",  cvt_s_h(0x4000,&fl),0x40000000);
    chk("s.h +inf", cvt_s_h(0x7C00,&fl),0x7F800000); chk("s.h +inf fl",fl,0);
    chk("s.h -inf", cvt_s_h(0xFC00,&fl),0xFF800000);
    chk("s.h qNaN", cvt_s_h(0x7E00,&fl),0x7FC00000); chk("s.h qNaN fl",fl,0);
    chk("s.h sNaN", cvt_s_h(0x7C01,&fl),0x7FC00000); chk("s.h sNaN fl",fl,0x10); // NV
    chk("s.h sub1", cvt_s_h(0x0001,&fl),0x33800000); chk("s.h sub1 fl",fl,0);    // 2^-24 exact

    //  ================= fcvt.h.s (S -> H, rounds RNE) =================
    chk("h.s 1.0",  cvt_h_s(0x3F800000,&fl),0x3C00); chk("h.s 1.0 fl",fl,0);
    chk("h.s -1.0", cvt_h_s(0xBF800000,&fl),0xBC00);
    chk("h.s 2.0",  cvt_h_s(0x40000000,&fl),0x4000);
    chk("h.s +0",   cvt_h_s(0x00000000,&fl),0x0000);
    chk("h.s +inf", cvt_h_s(0x7F800000,&fl),0x7C00); chk("h.s +inf fl",fl,0);
    chk("h.s qNaN", cvt_h_s(0x7FC00000,&fl),0x7E00); chk("h.s qNaN fl",fl,0);
    chk("h.s sNaN", cvt_h_s(0x7F800001,&fl),0x7E00); chk("h.s sNaN fl",fl,0x10);
    chk("h.s max",  cvt_h_s(0x477FE000,&fl),0x7BFF); chk("h.s max fl",fl,0);     // 65504 exact
    chk("h.s ovf",  cvt_h_s(0x47800000,&fl),0x7C00); chk("h.s ovf fl",fl,0x05);  // 65536 -> inf, OF|NX
    chk("h.s sub",  cvt_h_s(0x33800000,&fl),0x0001); chk("h.s sub fl",fl,0);     // 2^-24 exact
    chk("h.s tie0", cvt_h_s(0x33000000,&fl),0x0000); chk("h.s tie0 fl",fl,0x03); // 2^-25 RNE->0, UF|NX

    //  ================= fcvt.d.h (H -> D, exact widen) =================
    chk("d.h 1.0",  cvt_d_h(0x3C00,&fl),0x3FF0000000000000ULL); chk("d.h 1.0 fl",fl,0);
    chk("d.h -2.0", cvt_d_h(0xC000,&fl),0xC000000000000000ULL);
    chk("d.h +inf", cvt_d_h(0x7C00,&fl),0x7FF0000000000000ULL);
    chk("d.h sub1", cvt_d_h(0x0001,&fl),0x3E70000000000000ULL); chk("d.h sub1 fl",fl,0); // 2^-24
    chk("d.h sNaN", cvt_d_h(0x7C01,&fl),0x7FF8000000000000ULL); chk("d.h sNaN fl",fl,0x10);

    //  ================= fcvt.h.d (D -> H, rounds RNE) =================
    chk("h.d 1.0",  cvt_h_d(0x3FF0000000000000ULL,&fl),0x3C00); chk("h.d 1.0 fl",fl,0);
    chk("h.d 2.0",  cvt_h_d(0x4000000000000000ULL,&fl),0x4000);
    chk("h.d ovf",  cvt_h_d(0x40F0000000000000ULL,&fl),0x7C00); chk("h.d ovf fl",fl,0x05); // 65536 -> inf
    chk("h.d qNaN", cvt_h_d(0x7FF8000000000000ULL,&fl),0x7E00); chk("h.d qNaN fl",fl,0);

    //  ================= fmv.x.h / fmv.h.x =================
    //  fmv.x.h sign-extends the 16-bit value; fmv.h.x NaN-boxes the low 16.
    asm volatile("fmv.h.x fa0,%1\n\t fmv.x.h %0,fa0":"=r"(r):"r"((uint64_t)0x1234):"fa0");
    chk("fmv h.x/x.h +",r,0x0000000000001234ULL);
    asm volatile("fmv.h.x fa0,%1\n\t fmv.x.h %0,fa0":"=r"(r):"r"((uint64_t)0xFEDC):"fa0");
    chk("fmv h.x/x.h -",r,0xFFFFFFFFFFFFFEDCULL);   //  bit15=1 -> sign-extended

    //  NaN-box check: a half whose upper 48 bits are NOT all-1s reads as the
    //  canonical FP16 qNaN. Build a mis-boxed f-reg via fmv.d.x, then fcvt.s.h.
    {   uint64_t s;
        asm volatile("fmv.d.x fa0,%1\n\t fcvt.s.h fa1,fa0\n\t fmv.x.w %0,fa1"
                     :"=r"(s):"r"((uint64_t)0x0000000000003C00ULL):"fa0","fa1");
        chk("unbox16 mis-box -> qNaN",s,0x7FC00000); // not 0x3F800000
    }

    //  ================= flh / fsh (half load/store + NaN-box) =================
    asm volatile("fmv.h.x fa0,%1\n\t fsh fa0,0(%2)\n\t flh fa1,0(%2)\n\t fmv.x.h %0,fa1"
                 :"=r"(r):"r"((uint64_t)0xABCD),"r"(&hbuf):"fa0","fa1","memory");
    chk("flh/fsh round-trip",(uint16_t)r,0xABCD);
    //  flh of a known pattern, then widen, to prove the load feeds the FP path.
    hbuf=0x4000;    //  2.0h
    asm volatile("flh fa0,0(%1)\n\t fcvt.s.h fa1,fa0\n\t fmv.x.w %0,fa1"
                 :"=r"(r):"r"(&hbuf):"fa0","fa1","memory");
    chk("flh -> s.h",(uint32_t)r,0x40000000);

    //  ================= rolling digest sweep (spike-cross golden) =================
    //  Walk every FP16 exponent x a spread of mantissas through H->S->H and
    //  H->D round trips and a few FP32 narrowings, across 3 rounding modes,
    //  hashing result bits + flags. The absolute values are spike's job; this
    //  proves the karu64 datapath matches spike bit-for-bit over a broad set.
    uint64_t dig=0xcbf29ce484222325ULL; //  FNV-1a basis
    static const uint8_t rms[3]={0,1,2};    //  RNE, RTZ, RDN
    for(int ri=0;ri<3;ri++){ set_frm(rms[ri]);
        for(uint32_t e=0;e<32;e++){
            for(uint32_t m=0;m<1024;m+=37){
                uint16_t h=(uint16_t)((e<<10)|m);
                uint16_t hn=(uint16_t)(h|0x8000);
                uint32_t f1,f2,f3;
                uint32_t s=cvt_s_h(h,&f1);
                uint16_t hb=cvt_h_s(s,&f2);     //  S->H (round trip via single)
                uint64_t d=cvt_d_h(hn,&f3);
                uint32_t f4; uint16_t hd=cvt_h_d(d,&f4);
                uint64_t acc=((uint64_t)s)^((uint64_t)hb<<32)^((uint64_t)hd<<48)
                             ^d^((uint64_t)(f1^(f2<<8)^(f3<<16)^(f4<<24))<<40);
                dig=(dig^acc)*0x100000001b3ULL;
            }
        }
    }
    set_frm(0);
    sio_puts("[ZFHMIN] digest="); put_hex(dig); sio_putc('\n');

    if(fails){ sio_puts("[ZFHMIN] FAILURES: ");put_dec(fails);sio_puts(" first@");put_dec(ff);sio_putc('\n'); }
    else       sio_puts("[ZFHMIN] ALL PASS\n");
    sio_putc(4);
    return ff;
}
