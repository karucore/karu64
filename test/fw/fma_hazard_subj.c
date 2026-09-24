//  fma_hazard_subj.c
//  Directed test for the time-shared FP regfile port B (1W2R fregfile): FMA's
//  rs3 is read on port B during the FMA's issue window instead of in decode.
//  Every producer of an f-register is exercised as the rs3 source of an
//  immediately following FMA, plus register-number aliasing corner cases:
//    - FLD / FLW / FLH-boxed  -> FMA rs3        (LSU writeback -> rs3)
//    - FADD / FMUL / FDIV / FSQRT / FCVT -> rs3  (FPU multi-cycle -> rs3)
//    - FMADD -> rs3 of next FMADD (chain), rs3 == rd, rs3 == rs1 == rs2 == rd
//    - fmv.d.x / fmv.w.x -> rs3                  (FPU immediate op -> rs3)
//    - vfmv.f.s -> rs3                           (vector unit f write -> rs3)
//    - FMA with an integer/branch/LSU op in between, FMA accepted in the cycle
//      a MUL/DIV/load drains (ID/EX never holds a packet while a unit is busy)
//    - malformed NaN box (upper bits not all-ones) as the f32 rs3 -> canonical NaN
//    - all four FMA variants, S and D, plus fs* of an FMA result
//  Results are printed as a hex digest and compared line-for-line with spike
//  (same ELF). Exit code 0 only if the self-consistency anchors also hold.

#include <stdint.h>
#include "sio_generic.h"

static void put_hex(uint64_t x){int i;sio_putc('0');sio_putc('x');for(i=60;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static int fails = 0, n = 0;
static void emit(const char *nm, uint64_t v){ n++; sio_puts(nm); sio_putc('='); put_hex(v); sio_putc('\n'); }
static void chk(const char *nm, uint64_t got, uint64_t exp){ emit(nm, got); if (got != exp) { sio_puts("[FAIL] "); sio_puts(nm); sio_puts(" exp="); put_hex(exp); sio_putc('\n'); fails++; } }

static double   dv[16] __attribute__((aligned(8)));
static float    fv[16] __attribute__((aligned(4)));
static uint16_t hv[4]  __attribute__((aligned(2)));
static uint64_t ubuf[4] __attribute__((aligned(8)));

static inline uint64_t dbits(double d){ uint64_t r; asm("fmv.x.d %0,%1":"=r"(r):"f"(d)); return r; }
static inline uint64_t sbits(float f){ uint64_t r; asm("fmv.x.w %0,%1":"=r"(r):"f"(f)); return r; }

int main(void)
{
    uint64_t r, r2;
    sio_puts("\n[FMA rs3 hazard test]\n");
    for (int i = 0; i < 16; i++) { dv[i] = 1.0 + i * 0.37109375; fv[i] = 0.5f + i * 0.1875f; }
    hv[0] = 0x3c00; hv[1] = 0x4200; hv[2] = 0xc400; hv[3] = 0x7c00;    /* 1.0, 3.0, -4.0, +inf */

    /* --- reference (no hazard): rs3 loaded long before the FMA --- */
    asm volatile("fld fa2,%1\n fld fa0,%2\n fld fa1,%3\n nop\nnop\nnop\nnop\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[2]),"m"(dv[0]),"m"(dv[1]):"fa0","fa1","fa2","fa3");
    uint64_t ref_d = r; emit("ref_d  fmadd.d", r);
    asm volatile("flw fa2,%1\n flw fa0,%2\n flw fa1,%3\n nop\nnop\nnop\nnop\n fmadd.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[2]),"m"(fv[0]),"m"(fv[1]):"fa0","fa1","fa2","fa3");
    uint64_t ref_s = r; emit("ref_s  fmadd.s", r);

    /* --- 1. load -> rs3 back to back (LSU done -> accept -> issue) --- */
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa2,%3\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]):"fa0","fa1","fa2","fa3");
    chk("fld->rs3", r, ref_d);
    asm volatile("flw fa0,%1\n flw fa1,%2\n flw fa2,%3\n fmadd.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"m"(fv[2]):"fa0","fa1","fa2","fa3");
    chk("flw->rs3", r, ref_s);
    /* rs3 loaded last, immediately before the FMA, from a second buffer */
    ubuf[0] = 0; ubuf[1] = dbits(dv[2]); ubuf[2] = 0; ubuf[3] = 0;
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa2,8(%3)\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"r"(ubuf):"fa0","fa1","fa2","fa3","memory");
    chk("fld(buf)->rs3", r, ref_d);
    /* flh as rs3 of an fmadd.s: the f16 box is a VALID f32 box whose low word
       (0xffff4200) is an f32 NaN, so the FMA must return the canonical NaN */
    asm volatile("flw fa0,%1\n flw fa1,%2\n flh fa2,%3\n fmadd.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"m"(hv[1]):"fa0","fa1","fa2","fa3");
    chk("flh->rs3 (boxed f16 = f32 NaN input)", r, 0x7fc00000ull);
    /* malformed box as rs3: upper 32 bits zero -> unbox substitutes canonical NaN */
    asm volatile("flw fa0,%1\n flw fa1,%2\n fmv.d.x fa2,%3\n fmadd.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"r"((uint64_t)sbits(fv[2])):"fa0","fa1","fa2","fa3");
    chk("malformed box->rs3 (canonical NaN)", r, 0x7fc00000ull);
    /* same value with a proper box must give the reference result */
    asm volatile("flw fa0,%1\n flw fa1,%2\n fmv.d.x fa2,%3\n fmadd.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"r"(0xffffffff00000000ull | sbits(fv[2])):"fa0","fa1","fa2","fa3");
    chk("well-formed box->rs3", r, ref_s);
    /* flh then fcvt.s.h -> rs3 */
    asm volatile("flw fa0,%1\n flw fa1,%2\n flh fa4,%3\n fcvt.s.h fa2,fa4\n fmadd.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"m"(hv[1]):"fa0","fa1","fa2","fa3","fa4");
    emit("fcvt.s.h->rs3", r);

    /* --- 2. FPU multi-cycle producers -> rs3 --- */
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa4,%3\n fld fa5,%4\n fadd.d fa2,fa4,fa5\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"m"(dv[3]),"m"(dv[4]):"fa0","fa1","fa2","fa3","fa4","fa5");
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa4,%3\n fld fa5,%4\n fadd.d fa2,fa4,fa5\n nop\nnop\nnop\nnop\nnop\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r2):"m"(dv[0]),"m"(dv[1]),"m"(dv[3]),"m"(dv[4]):"fa0","fa1","fa2","fa3","fa4","fa5");
    chk("fadd.d->rs3", r, r2);
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa4,%3\n fld fa5,%4\n fmul.d fa2,fa4,fa5\n fnmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"m"(dv[3]),"m"(dv[4]):"fa0","fa1","fa2","fa3","fa4","fa5");
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa4,%3\n fld fa5,%4\n fmul.d fa2,fa4,fa5\n nop\nnop\nnop\nnop\nnop\n fnmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r2):"m"(dv[0]),"m"(dv[1]),"m"(dv[3]),"m"(dv[4]):"fa0","fa1","fa2","fa3","fa4","fa5");
    chk("fmul.d->rs3", r, r2);
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa4,%3\n fld fa5,%4\n fdiv.d fa2,fa4,fa5\n fmsub.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"m"(dv[3]),"m"(dv[4]):"fa0","fa1","fa2","fa3","fa4","fa5");
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa4,%3\n fld fa5,%4\n fdiv.d fa2,fa4,fa5\n nop\nnop\nnop\nnop\nnop\n fmsub.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r2):"m"(dv[0]),"m"(dv[1]),"m"(dv[3]),"m"(dv[4]):"fa0","fa1","fa2","fa3","fa4","fa5");
    chk("fdiv.d->rs3", r, r2);
    asm volatile("flw fa0,%1\n flw fa1,%2\n flw fa4,%3\n fsqrt.s fa2,fa4\n fnmsub.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"m"(fv[5]):"fa0","fa1","fa2","fa3","fa4");
    asm volatile("flw fa0,%1\n flw fa1,%2\n flw fa4,%3\n fsqrt.s fa2,fa4\n nop\nnop\nnop\nnop\nnop\n fnmsub.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r2):"m"(fv[0]),"m"(fv[1]),"m"(fv[5]):"fa0","fa1","fa2","fa3","fa4");
    chk("fsqrt.s->rs3", r, r2);
    asm volatile("fld fa0,%1\n fld fa1,%2\n fcvt.d.l fa2,%3\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"r"((int64_t)-7):"fa0","fa1","fa2","fa3");
    asm volatile("fld fa0,%1\n fld fa1,%2\n fcvt.d.l fa2,%3\n nop\nnop\nnop\nnop\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r2):"m"(dv[0]),"m"(dv[1]),"r"((int64_t)-7):"fa0","fa1","fa2","fa3");
    chk("fcvt.d.l->rs3", r, r2);
    /* immediate FPU ops (single-cycle done) -> rs3 */
    asm volatile("fld fa0,%1\n fld fa1,%2\n fmv.d.x fa2,%3\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"r"(dbits(dv[2])):"fa0","fa1","fa2","fa3");
    chk("fmv.d.x->rs3", r, ref_d);
    asm volatile("flw fa0,%1\n flw fa1,%2\n fmv.w.x fa2,%3\n fmadd.s fa3,fa0,fa1,fa2\n fmv.x.w %0,fa3"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"r"(sbits(fv[2])):"fa0","fa1","fa2","fa3");
    chk("fmv.w.x->rs3", r, ref_s);
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa4,%3\n fsgnjn.d fa2,fa4,fa4\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]):"fa0","fa1","fa2","fa3","fa4");
    emit("fsgnjn.d->rs3", r);

    /* --- 3. FMA chains and register aliasing --- */
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa2,%3\n fmadd.d fa2,fa0,fa1,fa2\n fmadd.d fa2,fa0,fa1,fa2\n fmadd.d fa2,fa0,fa1,fa2\n fmv.x.d %0,fa2"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]):"fa0","fa1","fa2");
    asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa2,%3\n fmadd.d fa2,fa0,fa1,fa2\n nop\nnop\nnop\n fmadd.d fa2,fa0,fa1,fa2\n nop\nnop\nnop\n fmadd.d fa2,fa0,fa1,fa2\n fmv.x.d %0,fa2"
        :"=r"(r2):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]):"fa0","fa1","fa2");
    chk("fmadd chain rs3==rd", r, r2);
    asm volatile("fld fa0,%1\n fmadd.d fa0,fa0,fa0,fa0\n fmadd.d fa0,fa0,fa0,fa0\n fmv.x.d %0,fa0"
        :"=r"(r):"m"(dv[3]):"fa0");
    asm volatile("fld fa0,%1\n fmadd.d fa0,fa0,fa0,fa0\n nop\nnop\nnop\n fmadd.d fa0,fa0,fa0,fa0\n fmv.x.d %0,fa0"
        :"=r"(r2):"m"(dv[3]):"fa0");
    chk("fmadd all-same-reg", r, r2);
    asm volatile("flw fa0,%1\n flw fa1,%2\n flw fa2,%3\n fmadd.s fa3,fa0,fa1,fa2\n fmsub.s fa4,fa1,fa2,fa3\n fnmadd.s fa5,fa2,fa3,fa4\n fnmsub.s fa6,fa3,fa4,fa5\n fmv.x.w %0,fa6"
        :"=r"(r):"m"(fv[0]),"m"(fv[1]),"m"(fv[2]):"fa0","fa1","fa2","fa3","fa4","fa5","fa6");
    asm volatile("flw fa0,%1\n flw fa1,%2\n flw fa2,%3\n fmadd.s fa3,fa0,fa1,fa2\n nop\nnop\n fmsub.s fa4,fa1,fa2,fa3\n nop\nnop\n fnmadd.s fa5,fa2,fa3,fa4\n nop\nnop\n fnmsub.s fa6,fa3,fa4,fa5\n fmv.x.w %0,fa6"
        :"=r"(r2):"m"(fv[0]),"m"(fv[1]),"m"(fv[2]):"fa0","fa1","fa2","fa3","fa4","fa5","fa6");
    chk("fma.s 4-variant chain", r, r2);
    /* f0 as rs3 (f0 is an ordinary register) */
    asm volatile("fld ft0,%1\n fld fa0,%2\n fld fa1,%3\n fmadd.d fa3,fa0,fa1,ft0\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[2]),"m"(dv[0]),"m"(dv[1]):"ft0","fa0","fa1","fa3");
    chk("f0 as rs3", r, ref_d);
    /* rs3 == f31 (top address) */
    asm volatile("fld ft11,%1\n fld fa0,%2\n fld fa1,%3\n fmadd.d fa3,fa0,fa1,ft11\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[2]),"m"(dv[0]),"m"(dv[1]):"ft11","fa0","fa1","fa3");
    chk("f31 as rs3", r, ref_d);

    /* --- 4. FMA accepted in the cycle a busy unit (div/mul/load) drains.
       id_accept requires !exec_busy, so a packet never waits in ID/EX behind a
       busy unit; this covers the accept-on-drain edge, not a waiting packet. --- */
    { uint64_t q;
      asm volatile("fld fa0,%2\n fld fa1,%3\n fld fa2,%4\n div %1,%5,%6\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r),"=&r"(q):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]),"r"((uint64_t)1000003),"r"((uint64_t)17):"fa0","fa1","fa2","fa3");
      chk("fmadd after div drains", r, ref_d);
      asm volatile("fld fa0,%2\n fld fa1,%3\n fld fa2,%4\n mul %1,%5,%6\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r),"=&r"(q):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]),"r"((uint64_t)1000003),"r"((uint64_t)17):"fa0","fa1","fa2","fa3");
      chk("fmadd after mul drains", r, ref_d);
      asm volatile("fld fa0,%2\n fld fa1,%3\n fld fa2,%4\n ld %1,%5\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r),"=&r"(q):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]),"m"(ubuf[0]):"fa0","fa1","fa2","fa3");
      chk("fmadd after ld drains", r, ref_d);
      /* store of an FMA result immediately (rs2 read on port B in decode after the steer releases) */
      asm volatile("fld fa0,%0\n fld fa1,%1\n fld fa2,%2\n fmadd.d fa3,fa0,fa1,fa2\n fsd fa3,%3\n fmadd.d fa5,fa0,fa1,fa3\n fsd fa5,%4\n"
        ::"m"(dv[0]),"m"(dv[1]),"m"(dv[2]),"m"(ubuf[2]),"m"(ubuf[3]):"fa0","fa1","fa2","fa3","fa5","memory");
      chk("fsd after fmadd", ubuf[2], ref_d);
      emit("fmadd rs3=prev rd, fsd", ubuf[3]);
      /* branch between producer and FMA */
      asm volatile("fld fa0,%1\n fld fa1,%2\n fld fa2,%3\n beq %4,%4,1f\n nop\n1: fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"m"(dv[0]),"m"(dv[1]),"m"(dv[2]),"r"(q):"fa0","fa1","fa2","fa3");
      chk("fmadd after taken branch", r, ref_d);
    }

    /* --- 5. vector unit writes f (vfmv.f.s) -> rs3 --- */
    asm volatile("vsetivli x0,2,e64,m1,tu,mu\n vle64.v v1,(%1)\n fld fa0,%2\n fld fa1,%3\n vfmv.f.s fa2,v1\n fmadd.d fa3,fa0,fa1,fa2\n fmv.x.d %0,fa3"
        :"=r"(r):"r"(&dv[2]),"m"(dv[0]),"m"(dv[1]):"fa0","fa1","fa2","fa3","v1","memory");
    chk("vfmv.f.s->rs3", r, ref_d);
    /* vector op using frs1 (port A) right after an FMA, then FMA using the vector's f result */
    asm volatile("vsetivli x0,2,e64,m1,tu,mu\n vle64.v v1,(%1)\n fld fa0,%2\n fld fa1,%3\n fld fa2,%4\n fmadd.d fa3,fa0,fa1,fa2\n vfadd.vf v2,v1,fa3\n vfmv.f.s fa4,v2\n fmadd.d fa5,fa0,fa1,fa4\n fmv.x.d %0,fa5"
        :"=r"(r):"r"(&dv[2]),"m"(dv[0]),"m"(dv[1]),"m"(dv[2]):"fa0","fa1","fa2","fa3","fa4","fa5","v1","v2","memory");
    emit("fmadd->vfadd.vf->vfmv.f.s->fmadd", r);

    sio_puts("[FMA rs3 hazard] cases="); put_hex(n); sio_puts(" failures="); put_hex(fails); sio_putc('\n');
    sio_puts(fails ? "[FMA rs3 hazard] FAIL\n" : "[FMA rs3 hazard] ALL PASS\n");
    return fails;
}
