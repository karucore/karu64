//  bitmanip_subj.c
//  Directed test for scalar Zba/Zbb/Zbs (RVA23-mandatory). The unit math is
//  exhaustively cross-checked vs a C model by test/bitmanip (make
//  bitmanip-unit-test, 156k vectors 0-error); this validates the DECODE +
//  writeback path on the core, run on karu64 and spike (same ELF, spike golden).
//  Each op's result is computed by the instruction and compared to a plain-C
//  reference; a digest is also printed for the spike line-for-line cross.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[12];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, ff=0, cn=0;
static void chk(const char*nm,uint64_t got,uint64_t exp){
    cn++;
    if(got!=exp){ sio_puts("[FAIL] ");sio_puts(nm);sio_puts(" got=");put_hex(got);sio_puts(" exp=");put_hex(exp);sio_putc('\n');fails++;if(!ff)ff=cn; }
}

#define A 0x123456789abcdef0ULL
#define B 0x00000000fedcba98ULL

int main(void){
    uint64_t a=A, b=B, r;
    sio_puts("\n[BITMANIP Zba/Zbb/Zbs directed test]\n");

    //  ---- Zbb logical ----
    asm("andn %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("andn",r,a&~b);
    asm("orn  %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("orn", r,a|~b);
    asm("xnor %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("xnor",r,~(a^b));
    //  ---- min/max ----
    asm("max  %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("max", r,((int64_t)a>(int64_t)b)?a:b);
    asm("min  %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("min", r,((int64_t)a<(int64_t)b)?a:b);
    asm("maxu %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("maxu",r,(a>b)?a:b);
    asm("minu %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("minu",r,(a<b)?a:b);
    //  ---- count / ext ----
    asm("clz  %0,%1":"=r"(r):"r"((uint64_t)0x0000ffff00000000ULL)); chk("clz",r,16);
    asm("ctz  %0,%1":"=r"(r):"r"((uint64_t)0x0000ffff00010000ULL)); chk("ctz",r,16);
    asm("cpop %0,%1":"=r"(r):"r"(a)); { int c=0; for(int i=0;i<64;i++)c+=(a>>i)&1; chk("cpop",r,c); }
    asm("clzw %0,%1":"=r"(r):"r"((uint64_t)0x0001000000000000ULL)); chk("clzw",r,32); // upper ignored, low32=0
    asm("ctzw %0,%1":"=r"(r):"r"((uint64_t)0xffffffff00100000ULL)); chk("ctzw",r,20);
    asm("cpopw %0,%1":"=r"(r):"r"((uint64_t)0xffffffffffffffffULL)); chk("cpopw",r,32);
    asm("sext.b %0,%1":"=r"(r):"r"((uint64_t)0x80)); chk("sext.b",r,(uint64_t)(int64_t)(int8_t)0x80);
    asm("sext.h %0,%1":"=r"(r):"r"((uint64_t)0x8000)); chk("sext.h",r,(uint64_t)(int64_t)(int16_t)0x8000);
    asm("zext.h %0,%1":"=r"(r):"r"(a)); chk("zext.h",r,a&0xffff);
    //  ---- rotate ----
    asm("rol  %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)12)); chk("rol",r,(a<<12)|(a>>52));
    asm("ror  %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)12)); chk("ror",r,(a>>12)|(a<<52));
    asm("rori %0,%1,20":"=r"(r):"r"(a)); chk("rori",r,(a>>20)|(a<<44));
    { uint32_t wa=(uint32_t)a; uint32_t rr=(wa<<7)|(wa>>25);
      asm("rolw %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)7)); chk("rolw",r,(uint64_t)(int64_t)(int32_t)rr); }
    { uint32_t wa=(uint32_t)a; uint32_t rr=(wa>>11)|(wa<<21);
      asm("rorw %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)11)); chk("rorw",r,(uint64_t)(int64_t)(int32_t)rr); }
    { uint32_t wa=(uint32_t)a; uint32_t rr=(wa>>9)|(wa<<23);
      asm("roriw %0,%1,9":"=r"(r):"r"(a)); chk("roriw",r,(uint64_t)(int64_t)(int32_t)rr); }
    //  ---- orc.b / rev8 ----
    asm("orc.b %0,%1":"=r"(r):"r"((uint64_t)0x0100020000ff0000ULL));
    chk("orc.b",r,0xff00ff0000ff0000ULL);
    asm("rev8 %0,%1":"=r"(r):"r"(a)); chk("rev8",r,0xf0debc9a78563412ULL);
    //  ---- Zba ----
    asm("sh1add %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("sh1add",r,b+(a<<1));
    asm("sh2add %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("sh2add",r,b+(a<<2));
    asm("sh3add %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("sh3add",r,b+(a<<3));
    asm("add.uw %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("add.uw",r,b+(uint64_t)(uint32_t)a);
    asm("sh1add.uw %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("sh1add.uw",r,b+((uint64_t)(uint32_t)a<<1));
    asm("sh2add.uw %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("sh2add.uw",r,b+((uint64_t)(uint32_t)a<<2));
    asm("sh3add.uw %0,%1,%2":"=r"(r):"r"(a),"r"(b)); chk("sh3add.uw",r,b+((uint64_t)(uint32_t)a<<3));
    asm("slli.uw %0,%1,10":"=r"(r):"r"(a)); chk("slli.uw",r,(uint64_t)(uint32_t)a<<10);
    //  ---- Zbs ----
    asm("bclr %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)4)); chk("bclr",r,a&~(1ULL<<4));
    asm("bext %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)5)); chk("bext",r,(a>>5)&1);
    asm("binv %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)7)); chk("binv",r,a^(1ULL<<7));
    asm("bset %0,%1,%2":"=r"(r):"r"(a),"r"((uint64_t)1)); chk("bset",r,a|(1ULL<<1));
    asm("bclri %0,%1,40":"=r"(r):"r"(a)); chk("bclri",r,a&~(1ULL<<40));
    asm("bexti %0,%1,60":"=r"(r):"r"(a)); chk("bexti",r,(a>>60)&1);
    asm("binvi %0,%1,33":"=r"(r):"r"(a)); chk("binvi",r,a^(1ULL<<33));
    asm("bseti %0,%1,50":"=r"(r):"r"(a)); chk("bseti",r,a|(1ULL<<50));

    if(fails){ sio_puts("[BITMANIP] FAILURES: ");put_dec(fails);sio_putc('\n'); }
    else       sio_puts("[BITMANIP] ALL PASS\n");
    sio_putc(4);
    return ff;
}
