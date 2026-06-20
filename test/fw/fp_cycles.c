//  fp_cycles.c
//  Cycles-per-FP-op microbench. Each test issues N back-to-back copies
//  of the op inside a single inline-asm block (no surrounding loop), so
//  the measured cycle delta is dominated by FPU latency rather than
//  branch/loop overhead. The per-op cycle count is (cycles / N) and
//  excludes the rdcycle CSR reads and the surrounding bookkeeping.

#include <stdint.h>
#include "sio_generic.h"

extern void htif_exit(int code);

static inline uint64_t rd_cycle(void)
{
    uint64_t c; __asm__ volatile ("rdcycle %0" : "=r"(c)); return c;
}
static inline uint64_t rd_instret(void)
{
    uint64_t c; __asm__ volatile ("rdinstret %0" : "=r"(c)); return c;
}

static void put_dec(uint64_t v)
{
    char buf[24]; int n = 0;
    if (v == 0) { sio_putc('0'); return; }
    while (v) { buf[n++] = '0' + (v % 10); v /= 10; }
    while (n--) sio_putc(buf[n]);
}
static void put_str(const char *s) { while (*s) sio_putc(*s++); }

static void report(const char *name, uint64_t cyc, uint64_t ret, uint32_t n)
{
    put_str(name);
    while (*name++) ; /* keep tidy alignment */
    put_str(" ");
    put_dec(cyc); put_str("c / ");
    put_dec(ret); put_str("i / N=");
    put_dec(n);
    put_str("  -> ");
    put_dec((cyc * 100) / n / 100); put_str(".");
    put_dec(((cyc * 100) / n) % 100); put_str(" cyc/op\n");
}

//  ---- unrolled groups: 16 back-to-back copies of one op ----
//  The body string is repeated 16 times by the C preprocessor. After
//  the asm block we have done 16 × OP. With N_REPS calls of the macro
//  we get 16 × N_REPS total ops.
#define X16(s) s s s s s s s s s s s s s s s s

#define ASM_BIN_S(op) \
    __asm__ volatile (X16(op " fa2, fa0, fa1\n") : : : "fa2")

#define ASM_UN_S(op) \
    __asm__ volatile (X16(op " fa1, fa0\n") : : : "fa1")

#define ASM_FMA_S(op) \
    __asm__ volatile (X16(op " fa3, fa0, fa1, fa2\n") : : : "fa3")

#define ASM_CMP_S(op) \
    __asm__ volatile (X16(op " a0, fa0, fa1\n") : : : "a0")

#define ASM_BIN_D(op) \
    __asm__ volatile (X16(op " fa2, fa0, fa1\n") : : : "fa2")

#define ASM_UN_D(op) \
    __asm__ volatile (X16(op " fa1, fa0\n") : : : "fa1")

#define ASM_FMA_D(op) \
    __asm__ volatile (X16(op " fa3, fa0, fa1, fa2\n") : : : "fa3")

#define ASM_CMP_D(op) \
    __asm__ volatile (X16(op " a0, fa0, fa1\n") : : : "a0")

//  Run REPS×16 issues of `op`, return cycles consumed.
#define BENCH(name, body, reps) do { \
    uint64_t c0 = rd_cycle(); \
    for (uint32_t _i = 0; _i < (reps); _i++) { body; } \
    uint64_t c1 = rd_cycle(); \
    report(name, c1 - c0, 0, (reps) * 16); \
} while (0)

//  Compute (cyc * 100 / total_ops) so the printed number has 2 decimals.
static void run(void)
{
    //  Set up baseline values in fa0/fa1/fa2 once (don't time these).
    __asm__ volatile (
        "li      t0, 0x3F800000\n"          //  1.0f
        "fmv.w.x fa0, t0\n"
        "li      t0, 0x40000000\n"          //  2.0f
        "fmv.w.x fa1, t0\n"
        "li      t0, 0x40400000\n"          //  3.0f
        "fmv.w.x fa2, t0\n"
        : : : "t0", "fa0", "fa1", "fa2"
    );

    BENCH("fadd.s  ", ASM_BIN_S("fadd.s"),  256);
    BENCH("fsub.s  ", ASM_BIN_S("fsub.s"),  256);
    BENCH("fmul.s  ", ASM_BIN_S("fmul.s"),  256);
    BENCH("fdiv.s  ", ASM_BIN_S("fdiv.s"),  256);
    BENCH("fsqrt.s ", ASM_UN_S("fsqrt.s"),  16);
    BENCH("fmadd.s ", ASM_FMA_S("fmadd.s"), 256);
    BENCH("feq.s   ", ASM_CMP_S("feq.s"),   256);
    BENCH("flt.s   ", ASM_CMP_S("flt.s"),   256);
    BENCH("fsgnj.s ",
          __asm__ volatile (X16("fsgnj.s fa3, fa0, fa1\n") : : : "fa3"), 256);
    BENCH("fmin.s  ",
          __asm__ volatile (X16("fmin.s fa3, fa0, fa1\n") : : : "fa3"), 256);
    BENCH("fclass.s",
          __asm__ volatile (X16("fclass.s a0, fa0\n") : : : "a0"), 256);
    BENCH("fcvt.w.s",
          __asm__ volatile (X16("fcvt.w.s a0, fa0, rne\n") : : : "a0"), 256);
    BENCH("fcvt.s.w",
          __asm__ volatile (X16("fcvt.s.w fa1, zero, rne\n") : : : "fa1"), 256);
    BENCH("fmv.x.w ",
          __asm__ volatile (X16("fmv.x.w a0, fa0\n") : : : "a0"), 256);

    //  -- D --
    __asm__ volatile (
        "li      t0, 1\n"
        "slli    t0, t0, 62\n"              //  2^62 (non-trivial double)
        "fmv.d.x fa0, t0\n"
        "li      t0, 1\n"
        "slli    t0, t0, 60\n"
        "fmv.d.x fa1, t0\n"
        "li      t0, 3\n"
        "slli    t0, t0, 60\n"
        "fmv.d.x fa2, t0\n"
        : : : "t0", "fa0", "fa1", "fa2"
    );

    BENCH("fadd.d  ", ASM_BIN_D("fadd.d"),  256);
    BENCH("fsub.d  ", ASM_BIN_D("fsub.d"),  256);
    BENCH("fmul.d  ", ASM_BIN_D("fmul.d"),  256);
    BENCH("fdiv.d  ", ASM_BIN_D("fdiv.d"),  256);
    BENCH("fsqrt.d ", ASM_UN_D("fsqrt.d"),  16);
    BENCH("fmadd.d ", ASM_FMA_D("fmadd.d"), 256);
    BENCH("feq.d   ", ASM_CMP_D("feq.d"),   256);
    BENCH("flt.d   ", ASM_CMP_D("flt.d"),   256);
    BENCH("fsgnj.d ",
          __asm__ volatile (X16("fsgnj.d fa3, fa0, fa1\n") : : : "fa3"), 256);
    BENCH("fmin.d  ",
          __asm__ volatile (X16("fmin.d fa3, fa0, fa1\n") : : : "fa3"), 256);
    BENCH("fclass.d",
          __asm__ volatile (X16("fclass.d a0, fa0\n") : : : "a0"), 256);
    BENCH("fcvt.w.d",
          __asm__ volatile (X16("fcvt.w.d a0, fa0, rne\n") : : : "a0"), 256);
    BENCH("fcvt.d.w",
          __asm__ volatile (X16("fcvt.d.w fa1, zero\n") : : : "fa1"), 256);
    BENCH("fcvt.l.d",
          __asm__ volatile (X16("fcvt.l.d a0, fa0, rne\n") : : : "a0"), 256);
    BENCH("fcvt.s.d",
          __asm__ volatile (X16("fcvt.s.d fa1, fa0, rne\n") : : : "fa1"), 256);
    BENCH("fcvt.d.s",
          __asm__ volatile (X16("fcvt.d.s fa1, fa0\n") : : : "fa1"), 256);
    BENCH("fmv.x.d ",
          __asm__ volatile (X16("fmv.x.d a0, fa0\n") : : : "a0"), 256);

    //  -- Integer baseline --
    BENCH("addi    ",
          __asm__ volatile (X16("addi a0, a0, 1\n") : : : "a0"), 256);
    BENCH("mul     ",
          __asm__ volatile (X16("mul a0, a0, a1\n") : : : "a0"), 256);
    BENCH("div     ",
          __asm__ volatile (X16("divu a0, a0, a1\n") : : : "a0"), 64);
}

int main(void)
{
    put_str("[fp_cycles] cycle counts per FP op (back-to-back, no loop)\n");
    run();
    put_str("[fp_cycles] done\n");
    htif_exit(0);
    return 0;
}
