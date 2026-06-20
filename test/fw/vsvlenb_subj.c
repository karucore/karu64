//  vsvlenb_subj.c -- directed repro for the Linux RVV bring-up failure on karu64.
//
//  Two hypotheses from the Debian-on-HW debug:
//  (B) sstatus.VS -> vector-CSR (vlenb) SEQUENCING. Linux enables VS (csrs sstatus,SR_VS)
//      and then immediately reads vlenb in riscv_v_setup_vsize / __riscv_v_vstate_save.
//      karu64.v's vs_off_ill gate traps ANY vector CSR (incl. vlenb 0xC22) when
//      status_vs==Off; if status_vs lags the just-committed csrs by a cycle relative to
//      the gate, a back-to-back csrs;csrr vlenb traps cause-2 spuriously.
//  (A) vector USERCOPY data path. enter_vector_usercopy() does vsetvli e8,m8 + vle8.v/
//      vse8.v for large copy_to/from_user; a VLSU bug there corrupts userspace buffers
//      while the kernel's scalar console output stays clean.
//
//  One ELF on karu64 (veri Vhtif_fp) + spike -- spike is golden, so any divergence is a
//  core bug. PASS (exit 0) = no spurious trap on VS-on vlenb, and the e8/m8 copy is exact.

#include <stdint.h>
#include "sio_generic.h"

static void ph(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static int fails=0,cn=0,ff=0;
static void chk(const char*nm,int bad,uint64_t a,uint64_t b){
    cn++; sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts(nm);
    if(bad){sio_puts("  a=");ph(a);sio_puts(" b=");ph(b);fails++;if(!ff)ff=cn;}
    sio_putc('\n');
}

volatile uint64_t g_mcause, g_mtval; volatile uint32_t g_traps;
asm(".align 2\nvtv:\n csrr t0,mcause\n la t1,g_mcause\n sd t0,0(t1)\n"
    " csrr t0,mtval\n la t1,g_mtval\n sd t0,0(t1)\n"
    " la t1,g_traps\n lw t0,0(t1)\n addiw t0,t0,1\n sw t0,0(t1)\n"
    " csrr t0,mepc\n addi t0,t0,4\n csrw mepc,t0\n mret\n");

#define VS (3ull<<9)

static uint8_t src[256], dst[256];

int main(void){
    uint64_t v=0,ss=0,vl=0; uint32_t t0; int i;
    asm volatile("la t0,vtv\n csrw mtvec,t0":::"t0");

    //  1: VS off -> vlenb traps cause 2 (gate sanity)
    asm volatile("csrc sstatus,%0"::"r"(VS));
    t0=g_traps; v=0xdead;
    asm volatile("csrr %0,0xc22":"=r"(v));
    chk("VSoff vlenb traps c2",!(g_traps==t0+1 && g_mcause==2),g_traps-t0,g_mcause);
    //  1b: tval on this VS-off illegal trap MUST carry the FAULTING INSTRUCTION
    //  WORD. Linux's lazy RVV first-use handler reads regs->badaddr (= stval) AS
    //  the instruction and calls insn_is_vector(stval); a ZERO (or garbage) stval
    //  makes it deliver SIGILL instead of enabling V and retrying. Before the
    //  trap_tval fix karu64 wrote 0 here -- EXACTLY the failure mode we found on HW
    //  (the first userspace vector op SIGILLs) -- so 0 is no longer accepted.
    //  Expect any `csrr rd,vlenb`: csr=0xC22, funct3=2, op=0x73 (rd/rs1 masked).
    //  Golden cross: spike writes the instruction here too.
    chk("VSoff vlenb tval == faulting insn",
        !((g_mtval & 0xfff0707full)==0xc2202073ull),g_mtval,0);

    //  2: VS on through sstatus, BACK-TO-BACK (0-gap) vlenb -> must NOT trap
    //  (hypothesis B, tightest Linux-shaped CSR path).
    t0=g_traps; v=0;
    asm volatile("csrs sstatus,%1\n csrr %0,0xc22\n":"=r"(v):"r"(VS));
    chk("VSon b2b vlenb no-trap",(g_traps!=t0),g_traps-t0,v);
    asm volatile("csrc sstatus,%0"::"r"(VS));

    //  3: VS on, 1-instr gap (csrr sstatus) then vlenb (the exact kernel shape)
    t0=g_traps; v=0;
    asm volatile("csrs sstatus,%2\n csrr %1,sstatus\n csrr %0,0xc22\n":"=r"(v),"=r"(ss):"r"(VS));
    chk("VSon gap1 vlenb no-trap",(g_traps!=t0),g_traps-t0,v);
    asm volatile("csrc sstatus,%0"::"r"(VS));

    //  4: VS on through sstatus, back-to-back vsetvli (enter_vector_usercopy shape)
    t0=g_traps; vl=0;
    asm volatile("csrs sstatus,%1\n vsetvli %0,x0,e8,m8,ta,ma\n":"=r"(vl):"r"(VS):);
    chk("VSon b2b vsetvli no-trap",(g_traps!=t0),g_traps-t0,vl);

    //  5: vector usercopy data path -- vle8.v/vse8.v e8,m8 over 256 bytes (VS still on)
    for(i=0;i<256;i++){src[i]=(uint8_t)(i^0xa5);dst[i]=0;}
    asm volatile("vsetvli t0,%0,e8,m8,ta,ma\n vle8.v v8,(%1)\n vse8.v v8,(%2)\n"
        ::"r"((uint64_t)256),"r"(src),"r"(dst):"t0","memory");
    {int bad=0,k=0;for(i=0;i<256;i++) if(dst[i]!=src[i]){bad=1;k=i;break;}
     chk("vle8/vse8 usercopy 256B",bad,(uint64_t)k,bad?dst[k]:0);}
    asm volatile("csrc sstatus,%0"::"r"(VS));

    //  6: strip-mined enter_vector_usercopy over >VLMAX (1000B, 4 strips, advance by vl)
    {
        static uint8_t s2[1000], d2[1000];
        uint64_t n=1000, l; uint8_t *sp=s2,*dp=d2;
        for(i=0;i<1000;i++){s2[i]=(uint8_t)(i*7+3);d2[i]=0;}
        asm volatile("csrs sstatus,%0"::"r"(VS));
        while(n){
            asm volatile("vsetvli %0,%1,e8,m8,ta,ma\n vle8.v v8,(%2)\n vse8.v v8,(%3)\n"
                :"=r"(l):"r"(n),"r"(sp),"r"(dp):"memory");
            n-=l; sp+=l; dp+=l;
        }
        {int bad=0,k=0;for(i=0;i<1000;i++) if(d2[i]!=s2[i]){bad=1;k=i;break;}
         chk("strip-mined usercopy 1000B",bad,(uint64_t)k,bad?d2[k]:0);}
            asm volatile("csrc sstatus,%0"::"r"(VS));
    }

    //  7: full vector context save/restore round-trip (preemptive kernel context-switch
    //  shape): load v0/v8/v16/v24 (m8 = 32 regs), vse8 them to a save area, clobber all,
    //  vle8 them back, vse8 to a check area, compare. One asm block so nothing reorders.
    {
        static uint8_t vpat[1024], vsv[1024], vck[1024];
        for(i=0;i<1024;i++){vpat[i]=(uint8_t)(i*13+7);vck[i]=0;vsv[i]=0;}
        asm volatile(
                "csrs   sstatus,%14\n"
            "vsetvli t0,%4,e8,m8,ta,ma\n"
            "vle8.v v0,(%0)\n  vle8.v v8,(%1)\n  vle8.v v16,(%2)\n  vle8.v v24,(%3)\n"
            "vse8.v v0,(%6)\n  vse8.v v8,(%7)\n  vse8.v v16,(%8)\n  vse8.v v24,(%9)\n"
            "vmv.v.x v0,x0\n   vmv.v.x v8,x0\n   vmv.v.x v16,x0\n   vmv.v.x v24,x0\n"
            "vle8.v v0,(%6)\n  vle8.v v8,(%7)\n  vle8.v v16,(%8)\n  vle8.v v24,(%9)\n"
            "vse8.v v0,(%10)\n vse8.v v8,(%11)\n vse8.v v16,(%12)\n vse8.v v24,(%13)\n"
            :: "r"(vpat),"r"(vpat+256),"r"(vpat+512),"r"(vpat+768),"r"((uint64_t)256),
               "r"(0ull),
               "r"(vsv),"r"(vsv+256),"r"(vsv+512),"r"(vsv+768),
               "r"(vck),"r"(vck+256),"r"(vck+512),"r"(vck+768),"r"(VS)
            : "t0","memory");
        {int bad=0,k=0;for(i=0;i<1024;i++) if(vck[i]!=vpat[i]){bad=1;k=i;break;}
         chk("vctx save/restore 32 regs",bad,(uint64_t)k,bad?vck[k]:0);}
            asm volatile("csrc sstatus,%0"::"r"(VS));
    }

    sio_puts(fails?"\n[VSVLENB] FAIL first=":"\n[VSVLENB] PASS\n");
    if(fails){ph(ff);sio_putc('\n');}
    return fails;
}
