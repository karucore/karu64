//  zicbo_subj.c
//  Directed test for Zicbom / Zicbop / Zicboz (CBO + prefetch).
//    Zicboz cbo.zero        -- zeroes the 64-byte (Zic64b) block of rs1
//    Zicbom cbo.clean/flush/inval -- NOPs on this write-through L1
//    Zicbop prefetch.i/r/w  -- NOPs (ori x0 hints)
//  The architecturally-visible op is cbo.zero; run on karu64 AND spike
//  (same ELF, spike golden). Assumes 64-byte cache blocks.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[12];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, ff=0, cn=0;
static void chk(const char*nm,uint64_t got,uint64_t exp){
    cn++;
    if(got!=exp){ sio_puts("[FAIL] ");sio_puts(nm);sio_puts(" got=");put_hex(got);sio_puts(" exp=");put_hex(exp);sio_putc('\n');fails++;if(!ff)ff=cn; }
}

//  192 bytes, 64-aligned: guard | target-block | guard
static volatile uint8_t cz[192] __attribute__((aligned(64)));

static int count_zero(int lo,int hi){int n=0;for(int i=lo;i<hi;i++)if(cz[i]==0)n++;return n;}
static int count_aa(int lo,int hi){int n=0;for(int i=lo;i<hi;i++)if(cz[i]==0xAA)n++;return n;}
static void fill_aa(void){for(int i=0;i<192;i++)cz[i]=0xAA;}

int main(void){
    sio_puts("\n[ZICBO cbo/prefetch directed test]\n");

    //  ---------- cbo.zero on an aligned base ----------
    fill_aa();
    asm volatile("cbo.zero (%0)"::"r"(&cz[64]):"memory");
    chk("zero: block all 0",   count_zero(64,128), 64);
    chk("zero: guard-lo kept", count_aa(0,64),     64);
    chk("zero: guard-hi kept", count_aa(128,192),  64);

    //  ---------- cbo.zero on an UNALIGNED address in the block ----------
    fill_aa();
    asm volatile("cbo.zero (%0)"::"r"(&cz[64+37]):"memory");    //  must still zero [64,128)
    chk("zero(unaligned): block 0",   count_zero(64,128), 64);
    chk("zero(unaligned): guard kept", count_aa(0,64)+count_aa(128,192), 128);

    //  ---------- Zicbom: clean/flush/inval are NOPs, must not corrupt ----------
    fill_aa();
    asm volatile("cbo.clean (%0)"::"r"(&cz[64]):"memory");
    asm volatile("cbo.flush (%0)"::"r"(&cz[64]):"memory");
    asm volatile("cbo.inval (%0)"::"r"(&cz[64]):"memory");
    chk("cbom: data intact", count_aa(0,192), 192);

    //  ---------- Zicbop: prefetch hints must not trap or corrupt ----------
    asm volatile("prefetch.r 0(%0)"::"r"(&cz[0]));
    asm volatile("prefetch.w 0(%0)"::"r"(&cz[0]));
    asm volatile("prefetch.i 0(%0)"::"r"(&cz[0]));
    chk("cbop: data intact", count_aa(0,192), 192);

    if(fails){ sio_puts("[ZICBO] FAILURES: ");put_dec(fails);sio_puts(" first@");put_dec(ff);sio_putc('\n'); }
    else       sio_puts("[ZICBO] ALL PASS\n");
    sio_putc(4);
    return ff;
}
