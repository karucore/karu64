//  vresv_subj.c
//  Directed test for the targeted reserved-encoding checks:
//    (a) executing a vtype-dependent vector op with vtype.vill set -> illegal
//    (b) indexed-load dest/index register-group overlap outside the RVV 5.2
//        allowances -> illegal; the two LEGAL overlap shapes must execute.
//  One ELF on karu64 and spike (spike enforces both rules) -- behavior must
//  match: same cases trap, same cases execute with identical results.

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

int main(void){
    int i; uint32_t t0n; uint64_t vtype_rd;
    for(i=0;i<256;i++) mem[i]=(uint8_t)(0x40+i);
    asm volatile("la t0, vresv_tvec\ncsrw mtvec, t0":::"t0");

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

    if(fails){ sio_puts("[VRESV] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[VRESV] ALL PASS\n");
    sio_putc(4);
    return ff;
}
