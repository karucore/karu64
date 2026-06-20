//  vstart_subj.c
//  Directed test for RVV 3.7 vstart semantics. Runs on BOTH spike (rv64gcv
//  golden) and karu64 -- with one tolerated behavioral fork: karu64 takes the
//  spec-permitted illegal-instruction exception on vector *arithmetic* with
//  nonzero vstart, while spike executes it (prestart-undisturbed). The arith
//  case accepts either, checking the full contract of whichever path fires.
//
//  Memory ops must HONOR vstart on both: elements below vstart are prestart
//  (loads leave the old vd bytes; stores write nothing), and every completed
//  vector instruction must leave vstart == 0.

#include <stdint.h>
#include "sio_generic.h"

#define SENT 0xEE

static uint8_t  mem[256] __attribute__((aligned(16)));
static uint8_t  dst[256] __attribute__((aligned(16)));
static uint8_t  gold[256];
static uint8_t  idxb[32];

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, caseno=0, ff=0;
static void check(const char*nm,const uint8_t*a,const uint8_t*b,int n,uint64_t vs_after){
    int i,bad=0; caseno++;
    for(i=0;i<n;i++) if(a[i]!=b[i]) bad++;
    if(vs_after) bad++;                 //  vstart must be 0 after every completed op
    sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts(nm);
    if(bad){ for(i=0;i<n;i++) if(a[i]!=b[i]){ sio_puts("\n  i="); put_dec(i);
        sio_puts(" got="); put_hex(a[i]); sio_puts(" exp="); put_hex(b[i]); }
        if(vs_after){ sio_puts("\n  vstart!=0 after op: "); put_hex(vs_after); }
        fails++; if(!ff) ff=caseno; }
    sio_putc('\n');
}

static uint64_t rd_vstart(void){uint64_t x;asm volatile("csrr %0,vstart":"=r"(x));return x;}
static void     wr_vstart(uint64_t x){asm volatile("csrw vstart,%0"::"r"(x));}

//  ---- trap handler: count illegal-instruction traps, skip the 4-byte insn ----
volatile uint64_t g_mcause;
volatile uint32_t g_traps;
void vstart_tvec(void) __attribute__((aligned(4)));
asm(".align 2\n"
    "vstart_tvec:\n"
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

int main(void){
    int i; uint64_t vs;
    for(i=0;i<256;i++) mem[i]=(uint8_t)(0x40+i);
    asm volatile("la t0, vstart_tvec\ncsrw mtvec, t0":::"t0");

    //  ==== T1: unit-stride load e8, vstart=5: bytes 0..4 prestart ====
    for(i=0;i<256;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vmv.v.x v8,%[c]\n"                 //  canary dest (vstart still 0 here)
        "csrw vstart,5\n"
        "vle8.v v8,(%[m])\n"
        "csrr %[vsa],vstart\n"
        "vse8.v v8,(%[d])\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(16),[c]"r"(SENT),[m]"r"(mem),[d]"r"(dst) : "t0","memory");
    for(i=0;i<16;i++) gold[i]=(i<5)?SENT:mem[i];
    check("vle8 vstart=5", dst, gold, 16, vs);

    //  ==== T2: unit-stride store e8, vstart=7: mem bytes 0..6 untouched ====
    for(i=0;i<64;i++) dst[i]=0x99;          //  dst is the store target here
    asm volatile(
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vle8.v v8,(%[m])\n"                //  source data (vstart 0)
        "csrw vstart,7\n"
        "vse8.v v8,(%[d])\n"
        "csrr %[vsa],vstart\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(16),[m]"r"(mem),[d]"r"(dst) : "t0","memory");
    for(i=0;i<16;i++) gold[i]=(i<7)?0x99:mem[i];
    check("vse8 vstart=7", dst, gold, 16, vs);

    //  ==== T3: unit-stride load e32, vstart=3 (vst_b scales by EEW) ====
    for(i=0;i<256;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vmv.v.x v8,%[c]\n"
        "csrw vstart,3\n"
        "vle32.v v8,(%[m])\n"
        "csrr %[vsa],vstart\n"
        "vse32.v v8,(%[d])\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(8),[c]"r"(0xEEEEEEEE),[m]"r"(mem),[d]"r"(dst) : "t0","memory");
    for(i=0;i<32;i++) gold[i]=(i<12)?SENT:mem[i];
    check("vle32 vstart=3", dst, gold, 32, vs);

    //  ==== T4: strided load e16 (pelem engine), vstart=3 ====
    for(i=0;i<256;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e16,m1,tu,mu\n"
        "vmv.v.x v8,%[c]\n"
        "csrw vstart,3\n"
        "vlse16.v v8,(%[m]),%[st]\n"
        "csrr %[vsa],vstart\n"
        "vse16.v v8,(%[d])\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(8),[c]"r"(0xEEEE),[m]"r"(mem),[st]"r"(4L),[d]"r"(dst) : "t0","memory");
    for(i=0;i<16;i++) gold[i]=SENT;
    for(i=3;i<8;i++){ gold[2*i]=mem[4*i]; gold[2*i+1]=mem[4*i+1]; }
    check("vlse16 vstart=3", dst, gold, 16, vs);

    //  ==== T5: indexed store e8 (pelem), vstart=4: idx 0..3 not stored ====
    for(i=0;i<32;i++) idxb[i]=(uint8_t)((15-i)*2);
    for(i=0;i<64;i++) dst[i]=0x77;
    asm volatile(
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vle8.v v8,(%[m])\n"                //  data
        "vle8.v v4,(%[ix])\n"               //  indices
        "csrw vstart,4\n"
        "vsuxei8.v v8,(%[d]),v4\n"
        "csrr %[vsa],vstart\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(8),[m]"r"(mem),[ix]"r"(idxb),[d]"r"(dst) : "t0","memory");
    for(i=0;i<32;i++) gold[i]=0x77;
    for(i=4;i<8;i++) gold[idxb[i]]=mem[i];
    check("vsuxei8 vstart=4", dst, gold, 32, vs);

    //  ==== T6: unit-seg load e8 nf=2 (pelem fields), vstart=2: segs 0,1 kept ====
    for(i=0;i<256;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vmv.v.x v8,%[c]\n"
        "vmv.v.x v9,%[c]\n"
        "csrw vstart,2\n"
        "vlseg2e8.v v8,(%[m])\n"
        "csrr %[vsa],vstart\n"
        "vse8.v v8,(%[d])\n"
        "vse8.v v9,(%[d2])\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(6),[c]"r"(SENT),[m]"r"(mem),[d]"r"(dst),[d2]"r"(dst+32) : "t0","memory");
    for(i=0;i<6;i++){ gold[i]   =(i<2)?SENT:mem[2*i];   //  field 0 (v8)
                      gold[32+i]=(i<2)?SENT:mem[2*i+1]; }   //  field 1 (v9)
    for(i=6;i<32;i++) gold[i]=SENT;                 //  vse8 vl=6: rest untouched
    check("vlseg2e8 vstart=2", dst, gold, 38, vs);

    //  ==== T7: vlm.v vstart=2 (EEW=8 element = mask byte) ====
    for(i=0;i<256;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vmv.v.x v8,%[c]\n"
        "vsetvli t0,%[vlm],e8,m1,tu,mu\n"   //  vl=32 mask bits -> evl=4 bytes
        "csrw vstart,2\n"
        "vlm.v v8,(%[m])\n"
        "csrr %[vsa],vstart\n"
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vse8.v v8,(%[d])\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(16),[vlm]"r"(32),[c]"r"(SENT),[m]"r"(mem),[d]"r"(dst) : "t0","memory");
    for(i=0;i<16;i++) gold[i]=SENT;
    gold[2]=mem[2]; gold[3]=mem[3];         //  bytes 0,1 prestart; 2,3 loaded
    check("vlm.v vstart=2", dst, gold, 16, vs);

    //  ==== T8: whole-register vl1re32 vstart=2 (counts in e32 -> skip 8 bytes) ====
    for(i=0;i<256;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vmv.v.x v8,%[c]\n"
        "csrw vstart,2\n"
        "vl1re32.v v8,(%[m])\n"
        "csrr %[vsa],vstart\n"
        "vs1r.v v8,(%[d])\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(32),[c]"r"(SENT),[m]"r"(mem),[d]"r"(dst) : "t0","memory");
    for(i=0;i<32;i++) gold[i]=(i<8)?SENT:mem[i];
    check("vl1re32 vstart=2", dst, gold, 32, vs);

    //  ==== T9: vstart >= vl: no elements, but vstart still cleared ====
    for(i=0;i<256;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e8,m1,tu,mu\n"
        "vmv.v.x v8,%[c]\n"
        "csrw vstart,11\n"
        "vle8.v v8,(%[m])\n"
        "csrr %[vsa],vstart\n"
        "vse8.v v8,(%[d])\n"
        : [vsa]"=&r"(vs)
        : [vl]"r"(8),[c]"r"(SENT),[m]"r"(mem),[d]"r"(dst) : "t0","memory");
    for(i=0;i<8;i++) gold[i]=SENT;
    check("vle8 vstart=11>vl=8", dst, gold, 8, vs);

    //  ==== T10: ARITH with nonzero vstart -- fork tolerated ====
    //  karu64: illegal-instruction trap (mcause 2), vstart preserved, vd
    //  untouched. spike: executes prestart-undisturbed, vstart cleared.
    {
        uint64_t vs_trap; uint32_t traps0=g_traps; int bad=0;
        for(i=0;i<256;i++) dst[i]=SENT;
        asm volatile(
            "vsetvli t0,%[vl],e8,m1,tu,mu\n"
            "vle8.v  v2,(%[m])\n"           //  vs2 = mem
            "vmv.v.x v3,%[b]\n"             //  vs1 = 0x10 splat
            "vmv.v.x v1,%[c]\n"             //  vd canary
            "csrw vstart,2\n"
            "vadd.vv v1,v2,v3\n"            //  traps on karu64 / executes on spike
            "csrr %[vst],vstart\n"          //  (post-trap or post-op)
            "csrw vstart,0\n"
            "vse8.v v1,(%[d])\n"
            : [vst]"=&r"(vs_trap)
            : [vl]"r"(8),[m]"r"(mem),[b]"r"(0x10),[c]"r"(SENT),[d]"r"(dst)
            : "t0","t1","memory");          //  t0/t1: handler scratch
        caseno++;
        if(g_traps != traps0){              //  ---- karu64 path: trapped ----
            if(g_traps != traps0+1) bad++;  //  exactly one trap
            if(g_mcause != 2) bad++;        //  illegal instruction
            if(vs_trap != 2) bad++;         //  vstart preserved across the trap
            for(i=0;i<8;i++) if(dst[i]!=SENT) bad++;    //  vd untouched
            sio_puts(bad?"[FAIL] ":"[ ok ] ");
            sio_puts("vadd.vv vstart=2 (trap path)");
            if(bad){ sio_puts("\n  traps="); put_dec(g_traps-traps0);
                sio_puts(" mcause="); put_hex(g_mcause);
                sio_puts(" vstart="); put_hex(vs_trap); }
        } else {                            //  ---- spike path: executed ----
            if(vs_trap != 0) bad++;         //  completed op cleared vstart
            for(i=0;i<8;i++){
                uint8_t exp=(i<2)?SENT:(uint8_t)(mem[i]+0x10);
                if(dst[i]!=exp) bad++;
            }
            sio_puts(bad?"[FAIL] ":"[ ok ] ");
            sio_puts("vadd.vv vstart=2 (execute path)");
        }
        if(bad){ fails++; if(!ff) ff=caseno; }
        sio_putc('\n');
    }

    if(fails){ sio_puts("[VSTART] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[VSTART] ALL PASS\n");
    sio_putc(4);
    return ff;
}
