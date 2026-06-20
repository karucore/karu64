//  zfa_subj.c
//  Directed test for Zfa (additional scalar FP): fli, fminm/fmaxm, fleq/fltq,
//  fround/froundnx, fcvtmod.w.d. Hand-checked anchors give absolute correctness;
//  a broad result+flags digest over many inputs x rounding modes is compared
//  line-for-line against spike (same ELF, spike golden).

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[12];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, ff=0, cn=0;
static void chk(const char*nm,uint64_t got,uint64_t exp){
    cn++;
    if(got!=exp){ sio_puts("[FAIL] ");sio_puts(nm);sio_puts(" got=");put_hex(got);sio_puts(" exp=");put_hex(exp);sio_putc('\n');fails++;if(!ff)ff=cn; }
}
static inline void set_frm(uint32_t m){ asm volatile("fsrm x0,%0"::"r"((uint64_t)m)); }

//  ---- op wrappers (operands passed as raw bits via fmv) ----
static uint32_t froundd_s(uint32_t a,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.w.x fa0,%2\n fround.s fa1,fa0\n fmv.x.w %0,fa1\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"((uint64_t)a):"fa0","fa1");*fl=f;return r;}
static uint32_t froundnx_s(uint32_t a,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.w.x fa0,%2\n froundnx.s fa1,fa0\n fmv.x.w %0,fa1\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"((uint64_t)a):"fa0","fa1");*fl=f;return r;}
static uint64_t froundd_d(uint64_t a,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.d.x fa0,%2\n fround.d fa1,fa0\n fmv.x.d %0,fa1\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"(a):"fa0","fa1");*fl=f;return r;}
static uint64_t froundnx_d(uint64_t a,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.d.x fa0,%2\n froundnx.d fa1,fa0\n fmv.x.d %0,fa1\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"(a):"fa0","fa1");*fl=f;return r;}
static uint32_t fcvtmod(uint64_t a,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.d.x fa0,%2\n fcvtmod.w.d %0,fa0,rtz\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"(a):"fa0");*fl=f;return (uint32_t)r;}
static uint32_t fminm_s(uint32_t a,uint32_t b,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.w.x fa0,%2\n fmv.w.x fa1,%3\n fminm.s fa2,fa0,fa1\n fmv.x.w %0,fa2\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"((uint64_t)a),"r"((uint64_t)b):"fa0","fa1","fa2");*fl=f;return r;}
static uint32_t fmaxm_s(uint32_t a,uint32_t b,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.w.x fa0,%2\n fmv.w.x fa1,%3\n fmaxm.s fa2,fa0,fa1\n fmv.x.w %0,fa2\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"((uint64_t)a),"r"((uint64_t)b):"fa0","fa1","fa2");*fl=f;return r;}
static uint64_t fmaxm_d(uint64_t a,uint64_t b,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.d.x fa0,%2\n fmv.d.x fa1,%3\n fmaxm.d fa2,fa0,fa1\n fmv.x.d %0,fa2\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"(a),"r"(b):"fa0","fa1","fa2");*fl=f;return r;}
static uint32_t fleq_s(uint32_t a,uint32_t b,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.w.x fa0,%2\n fmv.w.x fa1,%3\n fleq.s %0,fa0,fa1\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"((uint64_t)a),"r"((uint64_t)b):"fa0","fa1");*fl=f;return r;}
static uint32_t fltq_s(uint32_t a,uint32_t b,uint32_t*fl){uint64_t f,r;
    asm volatile("csrw fflags,x0\n fmv.w.x fa0,%2\n fmv.w.x fa1,%3\n fltq.s %0,fa0,fa1\n csrr %1,fflags"
        :"=r"(r),"=r"(f):"r"((uint64_t)a),"r"((uint64_t)b):"fa0","fa1");*fl=f;return r;}
/* fli.{s,d} fa3(=f15), rs1=index, via raw .insn (the mnemonic wants a value).
 * .insn infers the 4-byte length from bits[1:0]=11; no length prefix (which
 * would reject the value as signed). */
#define FLIS(i) ({uint32_t v; asm volatile(".insn 4,%1\n fmv.x.w %0,fa5":"=r"(v):"i"(0xF01007D3UL|((unsigned long)(i)<<15)):"fa5"); v;})
#define FLID(i) ({uint64_t v; asm volatile(".insn 4,%1\n fmv.x.d %0,fa5":"=r"(v):"i"(0xF21007D3UL|((unsigned long)(i)<<15)):"fa5"); v;})

int main(void){
    uint32_t fl; uint32_t r32;
    sio_puts("\n[ZFA additional-FP directed test]\n");
    set_frm(0);

    //  ---- fli anchors ----
    chk("fli.s 1.0", FLIS(16), 0x3f800000);
    chk("fli.s min", FLIS(1),  0x00800000);
    chk("fli.s inf", FLIS(30), 0x7f800000);
    chk("fli.s nan", FLIS(31), 0x7fc00000);
    chk("fli.d 1.0", FLID(16), 0x3ff0000000000000ULL);
    chk("fli.d -1.0",FLID(0),  0xbff0000000000000ULL);

    //  ---- fminm/fmaxm: canonical NaN if either operand is NaN ----
    chk("fminm qNaN,1", fminm_s(0x7fc00000,0x3f800000,&fl), 0x7fc00000); chk("fminm fl",fl,0);
    chk("fmaxm 1,qNaN", fmaxm_s(0x3f800000,0x7fc00000,&fl), 0x7fc00000);
    chk("fmaxm 1,2",    fmaxm_s(0x3f800000,0x40000000,&fl), 0x40000000);
    chk("fminm sNaN,1", fminm_s(0x7fa00000,0x3f800000,&fl), 0x7fc00000); chk("fminm sNaN fl",fl,0x10);

    //  ---- fleq/fltq: quiet (no NV on qNaN) ----
    chk("fleq qNaN,1",  fleq_s(0x7fc00000,0x3f800000,&fl), 0); chk("fleq qNaN fl",fl,0);
    chk("fltq 1,2",     fltq_s(0x3f800000,0x40000000,&fl), 1); chk("fltq fl",fl,0);
    chk("fleq sNaN,1",  fleq_s(0x7fa00000,0x3f800000,&fl), 0); chk("fleq sNaN fl",fl,0x10);

    //  ---- fround / fcvtmod anchors ----
    r32=froundd_s(0x3fc00000,&fl); chk("fround.s 1.5",r32,0x40000000); chk("fround.s fl",fl,0);
    r32=froundnx_s(0x3fc00000,&fl);chk("froundnx 1.5",r32,0x40000000); chk("froundnx fl",fl,0x01);
    r32=fcvtmod(0x4034000000000000ULL,&fl); chk("fcvtmod 20",r32,20); chk("fcvtmod fl",fl,0);
    r32=fcvtmod(0x41f0000000000000ULL,&fl); chk("fcvtmod 2^32",r32,0); chk("fcvtmod ovf fl",fl,0x10);
    r32=fcvtmod(0x7ff8000000000000ULL,&fl); chk("fcvtmod NaN",r32,0); chk("fcvtmod NaN fl",fl,0x10);

    //  ================= digest sweep (spike-cross golden) =================
    static const uint32_t s_in[]={0x3fc00000,0x3f000000,0x3f400000,0x40490fdb,0xbf000000,
        0xc0490fdb,0x4b000000,0x7f800000,0xff800000,0x7fc00000,0x7fa00000,0x00400000,
        0x80400000,0x00000000,0x80000000,0x40000000,0x42f60000};
    static const uint64_t d_in[]={0x3ff8000000000000ULL,0x3fe0000000000000ULL,0x4009210fb0000000ULL,
        0xc004000000000000ULL,0x4034000000000000ULL,0x7ff0000000000000ULL,0x7ff8000000000000ULL,
        0x0000000000000001ULL,0x41f0000000000000ULL,0xc1e0000000000001ULL,0x43e0000000000000ULL,
        0x3fe0000000000000ULL,0x8000000000000000ULL};
    uint64_t dig=0xcbf29ce484222325ULL;
    #define MIX(v) do{ dig=(dig^(uint64_t)(v))*0x100000001b3ULL; }while(0)
    for(int rm=0;rm<5;rm++){ set_frm(rm);
        for(unsigned i=0;i<sizeof(s_in)/4;i++){
            MIX(froundd_s(s_in[i],&fl)); MIX(fl);
            MIX(froundnx_s(s_in[i],&fl)); MIX(fl);
        }
        for(unsigned i=0;i<sizeof(d_in)/8;i++){
            MIX(froundd_d(d_in[i],&fl)); MIX(fl);
            MIX(froundnx_d(d_in[i],&fl)); MIX(fl);
        }
    }
    set_frm(0);
    for(unsigned i=0;i<sizeof(d_in)/8;i++){ MIX(fcvtmod(d_in[i],&fl)); MIX(fl); }
    //  fminm/fmaxm/fleq/fltq over pairs
    for(unsigned i=0;i<sizeof(s_in)/4;i++)for(unsigned j=0;j<sizeof(s_in)/4;j+=3){
        MIX(fminm_s(s_in[i],s_in[j],&fl)); MIX(fl);
        MIX(fmaxm_s(s_in[i],s_in[j],&fl)); MIX(fl);
        MIX(fleq_s(s_in[i],s_in[j],&fl));  MIX(fl);
        MIX(fltq_s(s_in[i],s_in[j],&fl));  MIX(fl);
    }
    for(unsigned i=0;i<sizeof(d_in)/8;i++)for(unsigned j=0;j<sizeof(d_in)/8;j+=2){ MIX(fmaxm_d(d_in[i],d_in[j],&fl)); MIX(fl); }
    //  fli index is an instruction-immediate -> must be a constant; unroll.
    #define FROW(i) do{ MIX(FLIS(i)); MIX(FLID(i)); }while(0)
    FROW(0);FROW(1);FROW(2);FROW(3);FROW(4);FROW(5);FROW(6);FROW(7);
    FROW(8);FROW(9);FROW(10);FROW(11);FROW(12);FROW(13);FROW(14);FROW(15);
    FROW(16);FROW(17);FROW(18);FROW(19);FROW(20);FROW(21);FROW(22);FROW(23);
    FROW(24);FROW(25);FROW(26);FROW(27);FROW(28);FROW(29);FROW(30);FROW(31);
    sio_puts("[ZFA] digest="); put_hex(dig); sio_putc('\n');

    if(fails){ sio_puts("[ZFA] FAILURES: ");put_dec(fails);sio_puts(" first@");put_dec(ff);sio_putc('\n'); }
    else       sio_puts("[ZFA] ALL PASS\n");
    sio_putc(4);
    return ff;
}
