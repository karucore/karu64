//  zcb_subj.c
//  Directed test for Zcb: the compressed byte/half loads & stores
//  (c.lbu/c.lhu/c.lh/c.sb/c.sh) and the compressed bitmanip helpers
//  (c.zext.b/c.sext.b/c.zext.h/c.sext.h/c.zext.w/c.not/c.mul). Explicit c.*
//  asm forces the 16-bit encodings. Run on karu64 AND spike (same ELF).
//  Note Zcb byte/half ops require the regs to be x8..x15; we use s0/s1.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[12];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, ff=0, cn=0;
static void chk(const char*nm,uint64_t got,uint64_t exp){
    cn++;
    if(got!=exp){ sio_puts("[FAIL] ");sio_puts(nm);sio_puts(" got=");put_hex(got);sio_puts(" exp=");put_hex(exp);sio_putc('\n');fails++;if(!ff)ff=cn; }
}

static volatile uint8_t buf[8] __attribute__((aligned(8)));

int main(void){
    uint64_t r;
    sio_puts("\n[ZCB compressed byte/half + bitmanip directed test]\n");

    //  ---------- loads ----------
    //  (c.lbu/c.sb byte offset 0..3; c.lhu/c.lh/c.sh half offset 0 or 2.)
    buf[0]=0x11; buf[1]=0x22; buf[2]=0x80; buf[3]=0xff; //  half0=0x2211 (+), half2=0xff80 (-)
    asm volatile("mv s1,%1\n\t c.lbu s0,2(s1)\n\t mv %0,s0":"=r"(r):"r"(buf):"s0","s1");
    chk("c.lbu off2", r, 0x80);                 //  zero-extended byte
    asm volatile("mv s1,%1\n\t c.lbu s0,3(s1)\n\t mv %0,s0":"=r"(r):"r"(buf):"s0","s1");
    chk("c.lbu off3", r, 0xff);
    asm volatile("mv s1,%1\n\t c.lhu s0,0(s1)\n\t mv %0,s0":"=r"(r):"r"(buf):"s0","s1");
    chk("c.lhu off0", r, 0x2211);               //  zero-extended half
    asm volatile("mv s1,%1\n\t c.lhu s0,2(s1)\n\t mv %0,s0":"=r"(r):"r"(buf):"s0","s1");
    chk("c.lhu off2", r, 0xff80);
    asm volatile("mv s1,%1\n\t c.lh s0,0(s1)\n\t mv %0,s0":"=r"(r):"r"(buf):"s0","s1");
    chk("c.lh off0 (+)", r, 0x2211);            //  positive -> same
    asm volatile("mv s1,%1\n\t c.lh s0,2(s1)\n\t mv %0,s0":"=r"(r):"r"(buf):"s0","s1");
    chk("c.lh off2 (-)", r, (uint64_t)(int64_t)(int16_t)0xff80);    //  sign-extended

    //  ---------- stores ----------  (loads done; safe to overwrite buf)
    asm volatile("mv s1,%0\n\t li s0,0xa5\n\t c.sb s0,3(s1)"::"r"(buf):"s0","s1","memory");
    chk("c.sb off3", buf[3], 0xa5);
    asm volatile("mv s1,%0\n\t li s0,0xbeef\n\t c.sh s0,2(s1)"::"r"(buf):"s0","s1","memory");
    chk("c.sh off2 lo", buf[2], 0xef);
    chk("c.sh off2 hi", buf[3], 0xbe);

    //  ---------- bitmanip helpers (rd'=rs1') ----------
    asm volatile("li s0,0x123456789abcdef0\n\t c.zext.b s0\n\t mv %0,s0":"=r"(r)::"s0");
    chk("c.zext.b", r, 0xf0);
    asm volatile("li s0,0x80\n\t c.sext.b s0\n\t mv %0,s0":"=r"(r)::"s0");
    chk("c.sext.b", r, (uint64_t)(int64_t)(int8_t)0x80);
    asm volatile("li s0,0x123456789abcdef0\n\t c.zext.h s0\n\t mv %0,s0":"=r"(r)::"s0");
    chk("c.zext.h", r, 0xdef0);
    asm volatile("li s0,0x8000\n\t c.sext.h s0\n\t mv %0,s0":"=r"(r)::"s0");
    chk("c.sext.h", r, (uint64_t)(int64_t)(int16_t)0x8000);
    asm volatile("li s0,0xdeadbeef12345678\n\t c.zext.w s0\n\t mv %0,s0":"=r"(r)::"s0");
    chk("c.zext.w", r, 0x12345678);
    asm volatile("li s0,0x0f0f0f0f0f0f0f0f\n\t c.not s0\n\t mv %0,s0":"=r"(r)::"s0");
    chk("c.not", r, 0xf0f0f0f0f0f0f0f0ULL);
    asm volatile("li s0,7\n\t li s1,9\n\t c.mul s0,s1\n\t mv %0,s0":"=r"(r)::"s0","s1");
    chk("c.mul", r, 63);
    asm volatile("li s0,0xffffffffffffffff\n\t li s1,0x10\n\t c.mul s0,s1\n\t mv %0,s0":"=r"(r)::"s0","s1");
    chk("c.mul wrap", r, 0xfffffffffffffff0ULL);

    if(fails){ sio_puts("[ZCB] FAILURES: ");put_dec(fails);sio_puts(" first@");put_dec(ff);sio_putc('\n'); }
    else       sio_puts("[ZCB] ALL PASS\n");
    sio_putc(4);
    return ff;
}
