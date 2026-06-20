//  vest_subj.c
//  Self-checking directed test for the karu64 7-bit FP estimate ops
//  vfrec7.v / vfrsqrt7.v. The C reference is a verbatim port of spike's
//  softfloat fall_reciprocal.c (recip7 / rsqrte7) — the same golden the RVV
//  arch-tests bake — so a karu64 PASS means the estimate datapath is
//  bit-identical to spike. The same ELF also runs on spike (rv64gcv) as a
//  cross-check: `make vest-test` (karu) / `make vest-test-spike` (spike).
//
//  Each test loads a vector of inputs, runs the estimate over the whole
//  vector (tu,mu), stores the results, and compares every element bit-exactly
//  against the C reference; it also clears+reads fflags and compares the OR of
//  the per-element reference flags.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex32(uint32_t x){int i;sio_putc('0');sio_putc('x');for(i=28;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_hex64(uint64_t x){put_hex32((uint32_t)(x>>32));put_hex32((uint32_t)x);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}

static int fails=0, caseno=0, ff=0;

//  ---- spike fall_reciprocal.c port (bit-exact reference) ----
#define U64MAX  (~(uint64_t)0)
static uint64_t make_mask64(int pos,int len){ return (U64MAX>>(64-len))<<pos; }
static uint64_t extract64(uint64_t v,int pos,int len){ return (v>>pos)&(U64MAX>>(64-len)); }

static const uint8_t rsq_tab[128]={
    52,51,50,48,47,46,44,43, 42,41,40,39,38,36,35,34,
    33,32,31,30,30,29,28,27, 26,25,24,23,23,22,21,20,
    19,19,18,17,16,16,15,14, 14,13,12,12,11,10,10,9,
    9,8,7,7,6,6,5,4, 4,3,3,2,2,1,1,0,
    127,125,123,121,119,118,116,114, 113,111,109,108,106,105,103,102,
    100,99,97,96,95,93,92,91, 90,88,87,86,85,84,83,82,
    80,79,78,77,76,75,74,73, 72,71,70,70,69,68,67,66,
    65,64,63,63,62,61,60,59, 59,58,57,56,56,55,54,53};
static const uint8_t rcp_tab[128]={
    127,125,123,121,119,117,116,114, 112,110,109,107,105,104,102,100,
    99,97,96,94,93,91,90,88, 87,85,84,83,81,80,79,77,
    76,75,74,72,71,70,69,68, 66,65,64,63,62,61,60,59,
    58,57,56,55,54,53,52,51, 50,49,48,47,46,45,44,43,
    42,41,40,40,39,38,37,36, 35,35,34,33,32,31,31,30,
    29,28,28,27,26,25,25,24, 23,23,22,21,21,20,19,19,
    18,17,17,16,15,15,14,14, 13,12,12,11,11,10,9,9,
    8,8,7,7,6,5,5,4, 4,3,3,2,2,1,1,0};

static uint64_t rsqrte7(uint64_t val,int e,int s,int sub){
    uint64_t exp=extract64(val,s,e), sig=extract64(val,0,s), sign=extract64(val,s+e,1);
    const int p=7;
    if(sub){ while(extract64(sig,s-1,1)==0){exp--;sig<<=1;} sig=(sig<<1)&make_mask64(0,s); }
    int idx=((exp&1)<<(p-1))|(int)(sig>>(s-p+1));
    uint64_t out_sig=(uint64_t)rsq_tab[idx]<<(s-p);
    uint64_t out_exp=(3*make_mask64(0,e-1)+~exp)/2;
    return (sign<<(s+e))|(out_exp<<s)|out_sig;
}
static uint64_t recip7(uint64_t val,int e,int s,int rm,int sub,int* abn){
    uint64_t exp=extract64(val,s,e), sig=extract64(val,0,s), sign=extract64(val,s+e,1);
    const int p=7;
    if(sub){
        while(extract64(sig,s-1,1)==0){exp--;sig<<=1;}
        sig=(sig<<1)&make_mask64(0,s);
        if(exp!=0 && exp!=U64MAX){
            *abn=1;
            if(rm==1||(rm==2&&!sign)||(rm==3&&sign)) return ((sign<<(s+e))|make_mask64(s,e))-1;
            else return (sign<<(s+e))|make_mask64(s,e);
        }
    }
    int idx=(int)(sig>>(s-p));
    uint64_t out_sig=(uint64_t)rcp_tab[idx]<<(s-p);
    uint64_t out_exp=2*make_mask64(0,e-1)+~exp;
    if(out_exp==0||out_exp==U64MAX){
        out_sig=(out_sig>>1)|make_mask64(s-1,1);
        if(out_exp==U64MAX){out_sig>>=1;out_exp=0;}
    }
    return (sign<<(s+e))|(out_exp<<s)|out_sig;
}

//  wrappers (replicate the f32/f64 classification switch); *fl gets fflags bits
static uint32_t ref_rsqrt32(uint32_t ui,int* fl){
    uint32_t exp=(ui>>23)&0xFF,sig=ui&0x7FFFFF,sign=ui>>31;
    int nan=(exp==0xFF)&&sig, inf=(exp==0xFF)&&!sig, zero=!(ui&0x7FFFFFFF), sub=(exp==0)&&sig;
    int snan=nan&&!((sig>>22)&1);
    if(nan){ if(snan)*fl|=0x10; return 0x7FC00000u; }
    if(sign&&!zero){ *fl|=0x10; return 0x7FC00000u; }
    if(zero){ *fl|=0x08; return sign?0xFF800000u:0x7F800000u; }
    if(inf) return 0u;
    return (uint32_t)rsqrte7(ui,8,23,sub);
}
static uint64_t ref_rsqrt64(uint64_t ui,int* fl){
    uint64_t exp=(ui>>52)&0x7FF,sig=ui&0xFFFFFFFFFFFFFull,sign=ui>>63;
    int nan=(exp==0x7FF)&&sig, inf=(exp==0x7FF)&&!sig, zero=!(ui&0x7FFFFFFFFFFFFFFFull), sub=(exp==0)&&sig;
    int snan=nan&&!((sig>>51)&1);
    if(nan){ if(snan)*fl|=0x10; return 0x7FF8000000000000ull; }
    if(sign&&!zero){ *fl|=0x10; return 0x7FF8000000000000ull; }
    if(zero){ *fl|=0x08; return sign?0xFFF0000000000000ull:0x7FF0000000000000ull; }
    if(inf) return 0ull;
    return rsqrte7(ui,11,52,sub);
}
static uint32_t ref_recip32(uint32_t ui,int rm,int* fl){
    uint32_t exp=(ui>>23)&0xFF,sig=ui&0x7FFFFF,sign=ui>>31;
    int nan=(exp==0xFF)&&sig, inf=(exp==0xFF)&&!sig, zero=!(ui&0x7FFFFFFF), sub=(exp==0)&&sig;
    int snan=nan&&!((sig>>22)&1), abn=0;
    if(inf) return sign?0x80000000u:0u;
    if(zero){ *fl|=0x08; return sign?0xFF800000u:0x7F800000u; }
    if(snan){ *fl|=0x10; return 0x7FC00000u; }
    if(nan) return 0x7FC00000u;
    uint32_t r=(uint32_t)recip7(ui,8,23,rm,sub,&abn);
    if(abn)*fl|=0x05;
    return r;
}
static uint64_t ref_recip64(uint64_t ui,int rm,int* fl){
    uint64_t exp=(ui>>52)&0x7FF,sig=ui&0xFFFFFFFFFFFFFull,sign=ui>>63;
    int nan=(exp==0x7FF)&&sig, inf=(exp==0x7FF)&&!sig, zero=!(ui&0x7FFFFFFFFFFFFFFFull), sub=(exp==0)&&sig;
    int snan=nan&&!((sig>>51)&1), abn=0;
    if(inf) return sign?0x8000000000000000ull:0ull;
    if(zero){ *fl|=0x08; return sign?0xFFF0000000000000ull:0x7FF0000000000000ull; }
    if(snan){ *fl|=0x10; return 0x7FF8000000000000ull; }
    if(nan) return 0x7FF8000000000000ull;
    uint64_t r=recip7(ui,11,52,rm,sub,&abn);
    if(abn)*fl|=0x05;
    return r;
}

#define N 8
static uint32_t in32[N], out32[N];
static uint64_t in64[N], out64[N];

static uint32_t rd_fflags(void){uint32_t f;asm volatile("csrr %0,fflags":"=r"(f));return f;}
static void clr_fflags(void){asm volatile("csrw fflags,x0");}
static void set_frm(uint32_t m){asm volatile("csrw frm,%0"::"r"(m));}

//  e32 test: op=0 rsqrt7, op=1 rec7
static void test32(const char* nm,int op,uint32_t rm){
    int i; uint32_t hwff, refff=0; caseno++;
    set_frm(rm); clr_fflags();
    if(op) asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfrec7.v v10,v8\n vse32.v v10,(%[d])\n"
        ::[n]"r"(N),[a]"r"(in32),[d]"r"(out32):"t0","memory");
    else   asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfrsqrt7.v v10,v8\n vse32.v v10,(%[d])\n"
        ::[n]"r"(N),[a]"r"(in32),[d]"r"(out32):"t0","memory");
    hwff=rd_fflags();
    int bad=0;
    for(i=0;i<N;i++){ uint32_t r = op?ref_recip32(in32[i],rm,&refff):ref_rsqrt32(in32[i],&refff);
        if(r!=out32[i]){ if(!bad){sio_puts("[FAIL] ");sio_puts(nm);} bad++;
            sio_puts("\n  i=");put_dec(i);sio_puts(" in=");put_hex32(in32[i]);sio_puts(" got=");put_hex32(out32[i]);sio_puts(" exp=");put_hex32(r); } }
    if((hwff&0x1F)!=(refff&0x1F)){ if(!bad){sio_puts("[FAIL] ");sio_puts(nm);} bad++;
        sio_puts("\n  fflags got=");put_hex32(hwff);sio_puts(" exp=");put_hex32(refff); }
    if(bad){sio_putc('\n');fails++;if(!ff)ff=caseno;} else {sio_puts("[ ok ] ");sio_puts(nm);sio_putc('\n');}
}
static void test64(const char* nm,int op,uint32_t rm){
    int i; uint32_t hwff, refff=0; caseno++;
    set_frm(rm); clr_fflags();
    if(op) asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n vfrec7.v v12,v8\n vse64.v v12,(%[d])\n"
        ::[n]"r"(N),[a]"r"(in64),[d]"r"(out64):"t0","memory");
    else   asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n vfrsqrt7.v v12,v8\n vse64.v v12,(%[d])\n"
        ::[n]"r"(N),[a]"r"(in64),[d]"r"(out64):"t0","memory");
    hwff=rd_fflags();
    int bad=0;
    for(i=0;i<N;i++){ uint64_t r = op?ref_recip64(in64[i],rm,&refff):ref_rsqrt64(in64[i],&refff);
        if(r!=out64[i]){ if(!bad){sio_puts("[FAIL] ");sio_puts(nm);} bad++;
            sio_puts("\n  i=");put_dec(i);sio_puts(" in=");put_hex64(in64[i]);sio_puts(" got=");put_hex64(out64[i]);sio_puts(" exp=");put_hex64(r); } }
    if((hwff&0x1F)!=(refff&0x1F)){ if(!bad){sio_puts("[FAIL] ");sio_puts(nm);} bad++;
        sio_puts("\n  fflags got=");put_hex32(hwff);sio_puts(" exp=");put_hex32(refff); }
    if(bad){sio_putc('\n');fails++;if(!ff)ff=caseno;} else {sio_puts("[ ok ] ");sio_puts(nm);sio_putc('\n');}
}

int main(void){
    //  ---- e32 normals: spread of exponents + mantissas, both signs ----
    in32[0]=0x3F800000; in32[1]=0x40000000; in32[2]=0x3DCCCCCD; in32[3]=0x42F60000;
    in32[4]=0x4B7FFFFF; in32[5]=0x3A831234; in32[6]=0x7F7FFFFF; in32[7]=0x00800000;
    test32("vfrsqrt7.v e32 normals",0,0);
    test32("vfrec7.v   e32 normals",1,0);
    //  e32 negatives (rec7 keeps sign; rsqrt7 -> NV+NaN)
    in32[0]=0xBF800000; in32[1]=0xC0490FDB; in32[2]=0xC2F60000; in32[3]=0xBDCCCCCD;
    in32[4]=0xFF7FFFFF; in32[5]=0x80800000; in32[6]=0xC57A0000; in32[7]=0xBF000000;
    test32("vfrsqrt7.v e32 negatives",0,0);
    test32("vfrec7.v   e32 negatives",1,0);
    //  e32 specials: +0,-0,+inf,-inf,qNaN,sNaN, largest+smallest subnormal
    in32[0]=0x00000000; in32[1]=0x80000000; in32[2]=0x7F800000; in32[3]=0xFF800000;
    in32[4]=0x7FC00000; in32[5]=0x7F800001; in32[6]=0x007FFFFF; in32[7]=0x00000001;
    test32("vfrsqrt7.v e32 specials",0,0);
    test32("vfrec7.v   e32 specials",1,0);
    //  e32 tiny subnormals through rec7 with RNE then RTZ (overflow path: inf vs max-finite)
    in32[0]=0x00000001; in32[1]=0x00000002; in32[2]=0x00000003; in32[3]=0x0000000F;
    in32[4]=0x00000040; in32[5]=0x00001000; in32[6]=0x00040000; in32[7]=0x00400000;
    test32("vfrec7.v   e32 subnormal RNE",1,0);
    test32("vfrec7.v   e32 subnormal RTZ",1,1);
    test32("vfrec7.v   e32 subnormal RDN",1,2);
    test32("vfrec7.v   e32 subnormal RUP",1,3);

    //  ---- e64 normals ----
    in64[0]=0x3FF0000000000000ull; in64[1]=0x4000000000000000ull; in64[2]=0x3FB999999999999Aull;
    in64[3]=0x405EC00000000000ull; in64[4]=0x4690000000000000ull; in64[5]=0x3F50624DD2F1A9FCull;
    in64[6]=0x7FEFFFFFFFFFFFFFull; in64[7]=0x0010000000000000ull;
    test64("vfrsqrt7.v e64 normals",0,0);
    test64("vfrec7.v   e64 normals",1,0);
    //  e64 negatives
    in64[0]=0xBFF0000000000000ull; in64[1]=0xC00921FB54442D18ull; in64[2]=0xC05EC00000000000ull;
    in64[3]=0xBFB999999999999Aull; in64[4]=0xFFEFFFFFFFFFFFFFull; in64[5]=0x8010000000000000ull;
    in64[6]=0xC0AF400000000000ull; in64[7]=0xBFE0000000000000ull;
    test64("vfrsqrt7.v e64 negatives",0,0);
    test64("vfrec7.v   e64 negatives",1,0);
    //  e64 specials + subnormals
    in64[0]=0x0000000000000000ull; in64[1]=0x8000000000000000ull; in64[2]=0x7FF0000000000000ull;
    in64[3]=0xFFF0000000000000ull; in64[4]=0x7FF8000000000000ull; in64[5]=0x7FF0000000000001ull;
    in64[6]=0x000FFFFFFFFFFFFFull; in64[7]=0x0000000000000001ull;
    test64("vfrsqrt7.v e64 specials",0,0);
    test64("vfrec7.v   e64 specials",1,0);
    //  e64 tiny subnormals through rec7, RNE + RTZ
    in64[0]=0x0000000000000001ull; in64[1]=0x0000000000000002ull; in64[2]=0x0000000000000010ull;
    in64[3]=0x0000000000001000ull; in64[4]=0x0000000001000000ull; in64[5]=0x0000010000000000ull;
    in64[6]=0x0004000000000000ull; in64[7]=0x0008000000000000ull;
    test64("vfrec7.v   e64 subnormal RNE",1,0);
    test64("vfrec7.v   e64 subnormal RTZ",1,1);

    set_frm(0);
    if(fails){ sio_puts("[VEST] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[VEST] ALL PASS\n");
    sio_putc(4);
    return ff;
}
