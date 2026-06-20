//  zvkb_subj.c
//  Directed self-checking test for the Zvkb leaf: vandn / vrol / vror
//  (.vv/.vx/.vi) / vbrev8 / vrev8, across SEWs, with a masked case and
//  tail-undisturbed checks. C model below is the reference. One ELF runs on
//  karu64 (-DKARU_ZVKB / KARU_ZVK builds) and on spike
//  (--isa=rv64gcv_zvl256b_zicntr_zvkb) -- results must be identical.

#include <stdint.h>
#include "sio_generic.h"

#define VL8  16
#define VL16 8
#define VL32 6
#define VL64 3
#define SENT64 0xEEEEEEEEEEEEEEEEull

static uint64_t s2[8], s1[8], dst[8], gold[8];

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, caseno=0, ff=0;
static void check(const char*nm,int nw){
    int i,bad=0; caseno++;
    for(i=0;i<nw;i++) if(dst[i]!=gold[i]) bad++;
    sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts(nm);
    if(bad){ for(i=0;i<nw;i++) if(dst[i]!=gold[i]){ sio_puts("\n  w="); put_dec(i);
        sio_puts(" got="); put_hex(dst[i]); sio_puts(" exp="); put_hex(gold[i]); }
        fails++; if(!ff) ff=caseno; }
    sio_putc('\n');
}
static void fill(void){int i;for(i=0;i<8;i++){
    s2[i]=0x0123456789ABCDEFull*(i+1)+0x1111ull*i;
    s1[i]=0xFEDCBA9876543210ull^(0x0101010101010101ull*i);
    dst[i]=SENT64; gold[i]=SENT64; }}

//  ---- C reference helpers ----
static uint64_t rolw(uint64_t v,unsigned r,unsigned w){uint64_t m=(w==64)?~0ull:((1ull<<w)-1);v&=m;r&=(w-1);return r?(((v<<r)|(v>>(w-r)))&m):v;}
static uint64_t rorw(uint64_t v,unsigned r,unsigned w){uint64_t m=(w==64)?~0ull:((1ull<<w)-1);v&=m;r&=(w-1);return r?(((v>>r)|(v<<(w-r)))&m):v;}
static uint8_t brev8b(uint8_t b){b=(b&0xF0)>>4|(b&0x0F)<<4;b=(b&0xCC)>>2|(b&0x33)<<2;b=(b&0xAA)>>1|(b&0x55)<<1;return b;}
static uint64_t brev8w(uint64_t v,unsigned w){uint64_t r=0;unsigned i;for(i=0;i<w/8;i++)r|=(uint64_t)brev8b(v>>(8*i))<<(8*i);return r;}
static uint64_t rev8w(uint64_t v,unsigned w){uint64_t r=0;unsigned i;for(i=0;i<w/8;i++)r|=((v>>(8*i))&0xFF)<<(8*(w/8-1-i));return r;}

//  per-SEW element accessors over the flat u64 arrays
#define ELG(a,sew,i) (((a)[(i)*(sew)/64] >> (((i)*(sew))%64)) & ((sew)==64?~0ull:((1ull<<(sew))-1)))
static void elput(uint64_t*a,unsigned sew,unsigned i,uint64_t v){
    uint64_t m=(sew==64)?~0ull:((1ull<<sew)-1);
    a[i*sew/64] = (a[i*sew/64] & ~(m<<((i*sew)%64))) | ((v&m)<<((i*sew)%64));
}

int main(void){
    unsigned i;
    //  (htif_start.S already set mstatus FS+VS for spike)

    //  ==== vandn.vv e32 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v2,(%[a])\n vle32.v v3,(%[b])\n vmv.v.x v1,%[s]\n"
        "vandn.vv v1,v2,v3\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL32),[a]"r"(s2),[b]"r"(s1),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<8;i++) gold[i]=~0ull;                     //  canary splat (VLMAX e32 = 8)
    for(i=0;i<VL32;i++) elput(gold,32,i, ELG(s2,32,i) & ~ELG(s1,32,i));
    check("vandn.vv e32", 4);

    //  ==== vandn.vx e64 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e64,m1,tu,mu\n"
        "vle64.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vandn.vx v1,v2,%[x]\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL64),[a]"r"(s2),[x]"r"(0x00FF00FF0F0F0F0Full),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL64;i++) gold[i]= s2[i] & ~0x00FF00FF0F0F0F0Full;
    check("vandn.vx e64", 4);

    //  ==== vrol.vv e32 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v2,(%[a])\n vle32.v v3,(%[b])\n vmv.v.x v1,%[s]\n"
        "vrol.vv v1,v2,v3\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL32),[a]"r"(s2),[b]"r"(s1),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<8;i++) gold[i]=~0ull;
    for(i=0;i<VL32;i++) elput(gold,32,i, rolw(ELG(s2,32,i), ELG(s1,32,i), 32));
    check("vrol.vv e32", 4);

    //  ==== vrol.vx e8 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vle8.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vrol.vx v1,v2,%[x]\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL8),[a]"r"(s2),[x]"r"(11L),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL8;i++) elput(gold,8,i, rolw(ELG(s2,8,i), 11, 8));
    check("vrol.vx e8", 2);

    //  ==== vror.vv e16 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e16,m1,tu,mu\n"
        "vle16.v v2,(%[a])\n vle16.v v3,(%[b])\n vmv.v.x v1,%[s]\n"
        "vror.vv v1,v2,v3\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL16),[a]"r"(s2),[b]"r"(s1),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL16;i++) elput(gold,16,i, rorw(ELG(s2,16,i), ELG(s1,16,i), 16));
    check("vror.vv e16", 2);

    //  ==== vror.vx e64 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e64,m1,tu,mu\n"
        "vle64.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vror.vx v1,v2,%[x]\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL64),[a]"r"(s2),[x]"r"(45L),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL64;i++) gold[i]= rorw(s2[i], 45, 64);
    check("vror.vx e64", 4);

    //  ==== vror.vi e32, imm=7 (uimm[5]=0) ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vror.vi v1,v2,7\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL32),[a]"r"(s2),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<8;i++) gold[i]=~0ull;
    for(i=0;i<VL32;i++) elput(gold,32,i, rorw(ELG(s2,32,i), 7, 32));
    check("vror.vi e32 imm7", 4);

    //  ==== vror.vi e64, imm=33 (uimm[5]=1 -> funct6[0]) ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e64,m1,tu,mu\n"
        "vle64.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vror.vi v1,v2,33\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL64),[a]"r"(s2),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL64;i++) gold[i]= rorw(s2[i], 33, 64);
    check("vror.vi e64 imm33", 4);

    //  ==== vbrev8.v e8 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vle8.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vbrev8.v v1,v2\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL8),[a]"r"(s2),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL8;i++) elput(gold,8,i, brev8w(ELG(s2,8,i), 8));
    check("vbrev8.v e8", 2);

    //  ==== vbrev8.v e64 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e64,m1,tu,mu\n"
        "vle64.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vbrev8.v v1,v2\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL64),[a]"r"(s2),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL64;i++) gold[i]= brev8w(s2[i], 64);
    check("vbrev8.v e64", 4);

    //  ==== vrev8.v e16 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e16,m1,tu,mu\n"
        "vle16.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vrev8.v v1,v2\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL16),[a]"r"(s2),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL16;i++) elput(gold,16,i, rev8w(ELG(s2,16,i), 16));
    check("vrev8.v e16", 2);

    //  ==== vrev8.v e64 ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e64,m1,tu,mu\n"
        "vle64.v v2,(%[a])\n vmv.v.x v1,%[s]\n"
        "vrev8.v v1,v2\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL64),[a]"r"(s2),[s]"r"(-1L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<4;i++) gold[i]=~0ull;
    for(i=0;i<VL64;i++) gold[i]= rev8w(s2[i], 64);
    check("vrev8.v e64", 4);

    //  ==== masked vandn.vv e32 (vm=0; masked-off undisturbed) ====
    fill();
    asm volatile("vsetvli t0,zero,e8,m1,tu,mu\n vmv.v.x v1,%[s]\n"
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v2,(%[a])\n vle32.v v3,(%[b])\n vmv.v.x v1,%[s]\n"
        "vmv.v.x v0,%[mk]\n"
        "vandn.vv v1,v2,v3,v0.t\n vs1r.v v1,(%[d])\n"
        :: [vl]"r"(VL32),[a]"r"(s2),[b]"r"(s1),[s]"r"(-1L),[mk]"r"(0xA5L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<8;i++) gold[i]=~0ull;
    for(i=0;i<VL32;i++) if((0xA5u>>i)&1)
        elput(gold,32,i, ELG(s2,32,i) & ~ELG(s1,32,i));
    check("vandn.vv e32 masked", 4);

    if(fails){ sio_puts("[ZVKB] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[ZVKB] ALL PASS\n");
    sio_putc(4);
    return ff;
}
