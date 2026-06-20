//  fsvs_subj.c
//  Directed test for mstatus.FS/VS context-state gating (the Linux FP/vector
//  prerequisite): with the field Off, FP/vector instructions AND their CSRs
//  raise illegal-instruction (cause 2); once enabled, execution proceeds and
//  hardware sets the field Dirty (and the derived read-only SD bit).
//  One ELF on karu64 and spike -- spike implements the same gating/dirty
//  model, so results must match. (htif_start.S enables FS+VS at boot; the
//  test clears them first.) Dirty is only asserted after explicitly
//  state-writing ops, where every implementation must set it.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, caseno=0, ff=0;
static void verdict(const char*nm,int bad,uint64_t a,uint64_t b){
    caseno++;
    sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts(nm);
    if(bad){ sio_puts("\n  a="); put_hex(a); sio_puts(" b="); put_hex(b);
        fails++; if(!ff) ff=caseno; }
    sio_putc('\n');
}

volatile uint64_t g_mcause;
volatile uint64_t g_mtval;
volatile uint32_t g_traps;
asm(".align 2\n"
    "fsvs_tvec:\n"
    "  csrr  t0, mcause\n"
    "  la    t1, g_mcause\n"
    "  sd    t0, 0(t1)\n"
    "  csrr  t0, mtval\n"
    "  la    t1, g_mtval\n"
    "  sd    t0, 0(t1)\n"
    "  la    t1, g_traps\n"
    "  lw    t0, 0(t1)\n"
    "  addiw t0, t0, 1\n"
    "  sw    t0, 0(t1)\n"
    "  csrr  t0, mepc\n"
    "  addi  t0, t0, 4\n"
    "  csrw  mepc, t0\n"
    "  mret\n");

#define FS_MASK   (3ull << 13)
#define VS_MASK   (3ull << 9)
#define SD_MASK   (1ull << 63)

static uint64_t rd_mstatus(void){uint64_t x;asm volatile("csrr %0,mstatus":"=r"(x));return x;}
static uint64_t rd_sstatus(void){uint64_t x;asm volatile("csrr %0,sstatus":"=r"(x));return x;}

static uint64_t mem64[8];

int main(void){
    uint64_t ms; uint32_t t0n;
    asm volatile("la t0, fsvs_tvec\ncsrw mtvec, t0":::"t0");

    //  ==== 1: clear FS+VS -> fields and SD read 0 ====
    asm volatile("csrc mstatus, %0"::"r"(FS_MASK|VS_MASK));
    ms = rd_mstatus();
    verdict("FS/VS/SD clear", (ms & (FS_MASK|VS_MASK|SD_MASK)) != 0, ms, 0);

    //  ==== 2: VS Off -> each illegal vector op / vector CSR traps cause 2 AND
    //  mtval/stval carries the FAULTING INSTRUCTION WORD. The board failure trapped
    //  on the FIRST vsetvli; Linux's lazy RVV first-use handler reads regs->badaddr
    //  (= stval) AS the instruction and calls insn_is_vector(insn): a zero stval =>
    //  insn_is_vector(0)=false => SIGILL on the first userspace vector op instead of
    //  enabling VS + retrying. Spike writes the instruction, so fsvs-test-spike is
    //  the golden cross. Encodings are from the assembler (riscv64 -march=rv64gcv).
    //  vsetvli t0,x0,e8,m1,tu,mu = 0x000072d7 ; vadd.vv v2,v0,v1 = 0x02008157 ;
    //  csrr t0,vl = 0xc20022f3.
    t0n=g_traps;
    asm volatile("vsetvli t0, x0, e8, m1, tu, mu":::"t0");  //  the actual board shape
    verdict("VS off: vsetvli mtval==insn (0x000072d7)",
        !(g_traps==t0n+1 && g_mcause==2 && g_mtval==0x000072d7ull), g_mtval, g_mcause);
    t0n=g_traps;
    asm volatile(".word 0x02008157\n");                     //  vadd.vv v2,v0,v1
    verdict("VS off: vadd.vv mtval==insn (0x02008157)",
        !(g_traps==t0n+1 && g_mcause==2 && g_mtval==0x02008157ull), g_mtval, g_mcause);
    t0n=g_traps;
    asm volatile("csrr t0, vl":::"t0");                     //  vector CSR read
    verdict("VS off: csrr vl mtval==insn (0xc20022f3)",
        !(g_traps==t0n+1 && g_mcause==2 && g_mtval==0xc20022f3ull), g_mtval, g_mcause);

    //  ==== 2c: a genuinely-illegal 32-bit opcode (the sys_ill_trap arm, not a
    //  VS/FS gate) also carries its instruction word in mtval -- same ill_insn_tval
    //  path, non-vector cause-2. Confirms the fix is generic, not vector-only. ====
    t0n=g_traps;
    asm volatile(".word 0xffffffff\n");                     //  illegal 32-bit opcode
    verdict("illegal opcode mtval==insn (0xffffffff)",
        !(g_traps==t0n+1 && g_mcause==2 && g_mtval==0xffffffffull), g_mtval, g_mcause);

    //  ==== 2d: RVC branch of ill_insn_tval -- a NONZERO illegal COMPRESSED insn.
    //  c.addi4spn with nzuimm==0 is reserved; karu_rvc64 expands nzuimm==0 to an
    //  invalid 32-bit word -> cause-2. rd'=x9 makes it 0x0004 (nonzero), so mtval
    //  must be the RAW 16-bit halfword zero-extended -- this pins the
    //  ex_is_c ? {48'b0, ex_w[15:0]} branch (vector never hits it, but other illegal
    //  RVC does). The trailing c.nop (0x0001) is skipped padding: the trap is on the
    //  first halfword, and the handler's mepc+4 resumes past both. ====
    t0n=g_traps;
    asm volatile(".2byte 0x0004\n .2byte 0x0001\n");        //  illegal c.addi4spn(nzuimm0,rd'x9) + c.nop pad
    verdict("illegal RVC mtval==insn (0x0004)",
        !(g_traps==t0n+1 && g_mcause==2 && g_mtval==0x0004ull), g_mtval, g_mcause);

    //  ==== 3: FS Off -> FP op + FP-load + FP CSR trap (cause 2) ====
    t0n=g_traps;
    asm volatile(".word 0x02008153\n");                     //  fadd.d f2,f1,f0: trap 1
    asm volatile("fld f1, 0(%0)"::"r"(mem64));              //  trap 2 (LSU-FP gate)
    asm volatile("csrr t0, fflags":::"t0");                 //  trap 3
    verdict("FS off: 3 traps cause 2",
        !(g_traps==t0n+3 && g_mcause==2), g_traps-t0n, g_mcause);

    //  ==== 4: enable VS=Initial -> vector executes, VS -> Dirty, SD set ====
    t0n=g_traps;
    asm volatile("csrs mstatus, %0"::"r"(1ull << 9));       //  VS = 01 Initial
    asm volatile(
        "vsetvli t0, %1, e64, m1, tu, mu\n"
        "vmv.v.x v1, %2\n"
        "vse64.v v1, (%0)\n"
        :: "r"(mem64), "r"(2), "r"(0x1234567890ABCDEFull) : "t0","memory");
    ms = rd_mstatus();
    verdict("VS dirty after vector",
        (g_traps!=t0n) || ((ms & VS_MASK) != VS_MASK) || !(ms & SD_MASK)
        || (mem64[0] != 0x1234567890ABCDEFull), ms, mem64[0]);

    //  ==== 5: enable FS=Initial -> FP executes, FS -> Dirty, SD stays ====
    t0n=g_traps;
    asm volatile("csrs mstatus, %0"::"r"(1ull << 13));      //  FS = 01 Initial
    asm volatile(
        "fmv.d.x f1, %1\n"
        "fsd f1, 0(%0)\n"
        :: "r"(&mem64[1]), "r"(0x402E000000000000ull) : "memory");  //  15.0
    ms = rd_mstatus();
    verdict("FS dirty after FP",
        (g_traps!=t0n) || ((ms & FS_MASK) != FS_MASK) || !(ms & SD_MASK)
        || (mem64[1] != 0x402E000000000000ull), ms, mem64[1]);

    //  ==== 6: the sstatus view shows the same FS/VS/SD ====
    {
        uint64_t ss = rd_sstatus();
        verdict("sstatus mirrors FS/VS/SD",
            ((ss ^ ms) & (FS_MASK|VS_MASK|SD_MASK)) != 0, ss, ms);
    }

    //  ==== 7: mstatus writable-field census. Every bit the mask must keep
    //  writable (a review caught a transposed mask constant silently
    //  dropping MPRV+SUM): SIE MIE SPIE MPIE SPP MPP FS VS MPRV SUM MXR
    //  TVM TW TSR. XS (16:15) must be READ-ONLY 0 (no custom stateful
    //  extensions; matches spike, so this stays a same-ELF cross-check).
    //  Set, check, restore; SD must reflect FS=11.
    {
        uint64_t writable = (1ull<<1)|(1ull<<3)|(1ull<<5)|(1ull<<7)|(1ull<<8)
                          | (3ull<<11)|(3ull<<13)|(1ull<<17)
                          | (1ull<<18)|(1ull<<19)|(1ull<<20)|(1ull<<21)|(1ull<<22)
                          | (3ull<<9);              //  +VS (this build has V)
        uint64_t xs_mask = (3ull<<15);
        uint64_t before = rd_mstatus();
        asm volatile("csrs mstatus, %0"::"r"(writable | xs_mask));
        ms = rd_mstatus();
        verdict("mstatus writable bits stick",
            ((ms & writable) != writable) || !(ms & SD_MASK), ms, writable);
        verdict("mstatus XS read-only 0", (ms & xs_mask) != 0, ms, xs_mask);
        //  restore: clear what we set, then put the original values back
        asm volatile("csrc mstatus, %0"::"r"(writable));
        asm volatile("csrs mstatus, %0"::"r"(before & writable));
    }

    //  ==== 8: a vector op that TRAPS at issue must NOT dirty VS (review
    //  finding: the first dirty pulse keyed on raw unit matches, so even a
    //  SIGILL'd op hardened VS to Dirty). The trapping op must need NO
    //  vector-state setup after re-arming VS (a csrw vstart would itself
    //  legally dirty) -- use the RVV 5.2-reserved indexed-load overlap
    //  (vluxei8 v4,(x),v4 at e32; traps at issue on both sims, touches no
    //  memory). VS must still read Initial afterwards.
    {
        uint32_t t0n=g_traps; int bad=0;
        asm volatile(
            "vsetvli t0, %0, e32, m1, tu, mu\n" //  legal: dirties; sets SEW=32
            :: "r"(8) : "t0");
        asm volatile("csrc mstatus, %0"::"r"(VS_MASK));
        asm volatile("csrs mstatus, %0"::"r"(1ull << 9));   //  re-arm VS = 01 Initial
        asm volatile(".word 0x064c0207\n"::: "memory"); //  reserved overlap: traps
        ms = rd_mstatus();
        if (g_traps != t0n+1 || g_mcause != 2) bad++;   //  it did trap
        if ((ms & VS_MASK) != (1ull << 9)) bad++;       //  VS still Initial, NOT Dirty
        asm volatile("csrs mstatus, %0"::"r"(VS_MASK|FS_MASK)); //  restore for exit
        verdict("trapped vector op does not dirty VS", bad, ms, g_traps-t0n);
    }

    if(fails){ sio_puts("[FSVS] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[FSVS] ALL PASS\n");
    sio_putc(4);
    return ff;
}
