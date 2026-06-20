//  rva_hints_subj.c
//  Directed test for a batch of small RVA23-mandatory extensions:
//    Zicond     -- czero.eqz / czero.nez
//    Zimop      -- mop.r.N / mop.rr.N write 0 to rd
//    Zcmop      -- c.mop.N is a NOP that preserves all registers
//    Zawrs      -- wrs.nto / wrs.sto retire as a NOP (single-hart)
//    Zihintntl  -- ntl.* hints are NOPs that never trap
//  Run on karu64 AND spike (same ELF, spike golden).

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[12];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, ff=0, cn=0;
static void chk(const char*nm,uint64_t got,uint64_t exp){
    cn++;
    if(got!=exp){ sio_puts("[FAIL] ");sio_puts(nm);sio_puts(" got=");put_hex(got);sio_puts(" exp=");put_hex(exp);sio_putc('\n');fails++;if(!ff)ff=cn; }
}

int main(void){
    uint64_t r;
    sio_puts("\n[RVA hints/cond/mop directed test]\n");

    //  ================= Zicond =================
    //  czero.eqz rd,rs1,rs2 : rd = (rs2==0) ? 0 : rs1
    //  czero.nez rd,rs1,rs2 : rd = (rs2!=0) ? 0 : rs1
    asm volatile("czero.eqz %0,%1,%2":"=r"(r):"r"(0x1234ULL),"r"(0ULL));   chk("czeqz rs2=0", r,0);
    asm volatile("czero.eqz %0,%1,%2":"=r"(r):"r"(0x1234ULL),"r"(9ULL));   chk("czeqz rs2!=0",r,0x1234);
    asm volatile("czero.nez %0,%1,%2":"=r"(r):"r"(0x1234ULL),"r"(0ULL));   chk("cznez rs2=0", r,0x1234);
    asm volatile("czero.nez %0,%1,%2":"=r"(r):"r"(0x1234ULL),"r"(9ULL));   chk("cznez rs2!=0",r,0);
    //  rs1 negative / full-width
    asm volatile("czero.eqz %0,%1,%2":"=r"(r):"r"(0xffffffffffffffffULL),"r"(1ULL)); chk("czeqz neg",r,0xffffffffffffffffULL);
    asm volatile("czero.nez %0,%1,%2":"=r"(r):"r"(0xdeadbeefcafef00dULL),"r"(0ULL)); chk("cznez keep",r,0xdeadbeefcafef00dULL);

    //  ================= Zimop =================
    //  mop.r.N / mop.rr.N currently write 0 to rd (until repurposed).
    asm volatile("li %0,0xdeadbeef\n\t mop.r.0  %0,%0":"=r"(r)); chk("mop.r.0",  r,0);
    asm volatile("li %0,0x12345\n\t   mop.r.31 %0,%0":"=r"(r)); chk("mop.r.31", r,0);
    asm volatile("li %0,0xabcdef\n\t  mop.rr.0 %0,%0,%0":"=r"(r)); chk("mop.rr.0", r,0);
    asm volatile("li %0,0x777\n\t     mop.rr.7 %0,%0,%0":"=r"(r)); chk("mop.rr.7", r,0);

    //  ================= Zcmop =================
    //  c.mop.N preserves every register. A mis-expansion to the c.lui slot
    //  would clobber x_N (n odd); canary the exact targets c.mop.5 -> t0(x5)
    //  and c.mop.15 -> a5(x15).
    asm volatile("li t0,0x5a5a5a5a\n\t c.mop.5\n\t mv %0,t0":"=r"(r)::"t0");  chk("c.mop.5 keeps x5", r,0x5a5a5a5a);
    asm volatile("li a5,0x33aa55cc\n\t c.mop.15\n\t mv %0,a5":"=r"(r)::"a5"); chk("c.mop.15 keeps x15",r,0x33aa55cc);
    asm volatile("li t2,0x9e\n\t       c.mop.7\n\t  mv %0,t2":"=r"(r)::"t2");  chk("c.mop.7 keeps x7", r,0x9e);

    //  ================= Zawrs =================
    //  Must retire without trapping (and without waiting forever).
    asm volatile("wrs.nto");
    asm volatile("wrs.sto");
    chk("zawrs executed", 1, 1);

    //  ================= Zihintntl =================
    //  HINT NOPs (add x0,x0,rs / c.add x0 forms) -- must not trap or alter regs.
    asm volatile("li t0,0xc0ffee\n\t ntl.p1\n\t ntl.pall\n\t ntl.s1\n\t ntl.all\n\t mv %0,t0":"=r"(r)::"t0");
    chk("zihintntl keeps t0", r,0xc0ffee);

    if(fails){ sio_puts("[RVA-HINTS] FAILURES: ");put_dec(fails);sio_puts(" first@");put_dec(ff);sio_putc('\n'); }
    else       sio_puts("[RVA-HINTS] ALL PASS\n");
    sio_putc(4);
    return ff;
}
