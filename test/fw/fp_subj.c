//  fp_subj.c
//  karu64-side "subject" program for Berkeley TestFloat. Covers F (f32)
//  and D (f64) ops plus the two cross-precision conversions.
//
//  Layout (all uint32_t, native LE):
//    IN_BASE + 0x00 : op_id   (matches FP_* below)
//    IN_BASE + 0x04 : n_vec
//    IN_BASE + 0x08 : frm     (only consulted by the KARU_DYN build)
//    IN_BASE + 0x0c : input_stride_u32 (4 for f32 ops; 8 for f64 ops)
//    IN_BASE + 0x10 : input records, stride = input_stride_u32 u32s
//                     per record.
//    OUT_BASE + i*16: output records, stride 4 u32 = 16 B per record
//                     [r_lo, r_hi, flags, 0]
//
//  The wrapper script reads back the per-vector (r_lo, r_hi, flags) and
//  joins them with the original operand lines from testfloat_gen to
//  build the text testfloat_ver expects.

#include <stdint.h>

#define IN_BASE     0x80010000UL
#define OUT_BASE    0x80100000UL

//  ---- F (f32) ops ----
#define FP_F32_ADD      1
#define FP_F32_SUB      2
#define FP_F32_MUL      3
#define FP_F32_DIV      4
#define FP_F32_SQRT     5
#define FP_F32_MULADD   6
#define FP_F32_EQ       7
#define FP_F32_LE       8
#define FP_F32_LT       9
#define FP_F32_TO_I32   10
#define FP_F32_TO_UI32  11
#define FP_F32_TO_I64   12
#define FP_F32_TO_UI64  13
#define FP_I32_TO_F32   14
#define FP_UI32_TO_F32  15
#define FP_I64_TO_F32   16
#define FP_UI64_TO_F32  17

//  ---- D (f64) ops ----
#define FP_F64_ADD      20
#define FP_F64_SUB      21
#define FP_F64_MUL      22
#define FP_F64_DIV      23
#define FP_F64_SQRT     24
#define FP_F64_MULADD   25
#define FP_F64_EQ       26
#define FP_F64_LE       27
#define FP_F64_LT       28
#define FP_F64_TO_I32   29
#define FP_F64_TO_UI32  30
#define FP_F64_TO_I64   31
#define FP_F64_TO_UI64  32
#define FP_I32_TO_F64   33
#define FP_UI32_TO_F64  34
#define FP_I64_TO_F64   35
#define FP_UI64_TO_F64  36
#define FP_F32_TO_F64   37  //  fcvt.d.s (exact)
#define FP_F64_TO_F32   38  //  fcvt.s.d (rounds)

extern void htif_exit(int code);
extern void sio_puts(const char *s);

#ifndef KARU_RM_TOK
#define KARU_RM_TOK rne
#endif

#define STRINGIFY_(x)   #x
#define STRINGIFY(x)    STRINGIFY_(x)
#define RM_TXT      STRINGIFY(KARU_RM_TOK)

//  ==========================================================================
//  F (single-precision) wrappers
//  ==========================================================================
#define BINOP_FF(op, A, B, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.w.x    fa0, %2\n\t" \
        "fmv.w.x    fa1, %3\n\t" \
        op "    fa2, fa0, fa1, " RM_TXT "\n\t" \
        "fmv.x.w    %0, fa2\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A), "r"(B) \
        : "fa0", "fa1", "fa2")

#define UNOP_FF(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.w.x    fa0, %2\n\t" \
        op "    fa1, fa0, " RM_TXT "\n\t" \
        "fmv.x.w    %0, fa1\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) \
        : "fa0", "fa1")

#define CMP_FF(op, A, B, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.w.x    fa0, %2\n\t" \
        "fmv.w.x    fa1, %3\n\t" \
        op "    %0, fa0, fa1\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A), "r"(B) \
        : "fa0", "fa1")

#define F2I32(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.w.x    fa0, %2\n\t" \
        op "    %0, fa0, " RM_TXT "\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0")

#define F2I64(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.w.x    fa0, %2\n\t" \
        op "    %0, fa0, " RM_TXT "\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0")

#define I2F(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        op "    fa0, %2, " RM_TXT "\n\t" \
        "fmv.x.w    %0, fa0\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0")

#define FMA(op, A, B, C, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.w.x    fa0, %2\n\t" \
        "fmv.w.x    fa1, %3\n\t" \
        "fmv.w.x    fa2, %4\n\t" \
        op "    fa3, fa0, fa1, fa2, " RM_TXT "\n\t" \
        "fmv.x.w    %0, fa3\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A), "r"(B), "r"(C) \
        : "fa0", "fa1", "fa2", "fa3")

//  ==========================================================================
//  D (double-precision) wrappers. A/B/C/R types are uint64_t.
//  fmv.d.x / fmv.x.d transfer the full 64 bits (no NaN-box).
//  ==========================================================================
#define BINOP_DD(op, A, B, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.d.x    fa0, %2\n\t" \
        "fmv.d.x    fa1, %3\n\t" \
        op "    fa2, fa0, fa1, " RM_TXT "\n\t" \
        "fmv.x.d    %0, fa2\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A), "r"(B) \
        : "fa0", "fa1", "fa2")

#define UNOP_DD(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.d.x    fa0, %2\n\t" \
        op "    fa1, fa0, " RM_TXT "\n\t" \
        "fmv.x.d    %0, fa1\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) \
        : "fa0", "fa1")

#define CMP_DD(op, A, B, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.d.x    fa0, %2\n\t" \
        "fmv.d.x    fa1, %3\n\t" \
        op "    %0, fa0, fa1\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A), "r"(B) \
        : "fa0", "fa1")

#define D2I32(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.d.x    fa0, %2\n\t" \
        op "    %0, fa0, " RM_TXT "\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0")

#define D2I64(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.d.x    fa0, %2\n\t" \
        op "    %0, fa0, " RM_TXT "\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0")

//  fcvt.d.l / fcvt.d.lu can round (int64 may exceed 53-bit mantissa).
#define I2D(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        op "    fa0, %2, " RM_TXT "\n\t" \
        "fmv.x.d    %0, fa0\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0")

//  fcvt.d.w / fcvt.d.wu are exact (int32 fits in 53-bit mantissa) and the
//  assembler rejects an explicit rm field.
#define I2D_EXACT(op, A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        op "    fa0, %2\n\t" \
        "fmv.x.d    %0, fa0\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0")

#define FMA_D(op, A, B, C, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.d.x    fa0, %2\n\t" \
        "fmv.d.x    fa1, %3\n\t" \
        "fmv.d.x    fa2, %4\n\t" \
        op "    fa3, fa0, fa1, fa2, " RM_TXT "\n\t" \
        "fmv.x.d    %0, fa3\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A), "r"(B), "r"(C) \
        : "fa0", "fa1", "fa2", "fa3")

//  Cross-precision: D->S (rounds) and S->D (exact).
#define DTOS(A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.d.x    fa0, %2\n\t" \
        "fcvt.s.d   fa1, fa0, " RM_TXT "\n\t" \
        "fmv.x.w    %0, fa1\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0", "fa1")

#define STOD(A, R, F) \
    __asm__ volatile ( \
        "csrwi  fflags, 0\n\t" \
        "fmv.w.x    fa0, %2\n\t" \
        "fcvt.d.s   fa1, fa0\n\t" \
        "fmv.x.d    %0, fa1\n\t" \
        "csrr   %1, fflags\n\t" \
        : "=&r"(R), "=&r"(F) : "r"(A) : "fa0", "fa1")

int main(void)
{
    volatile uint32_t *in  = (volatile uint32_t *)IN_BASE;
    volatile uint32_t *out = (volatile uint32_t *)OUT_BASE;

    uint32_t op         = in[0];
    uint32_t n_vec      = in[1];
    uint32_t stride_in  = in[3] ? in[3] : 4;    //  default 4 for f32 ops

#ifdef KARU_DYN
    uint32_t frm = in[2];
    __asm__ volatile ("csrw frm, %0" :: "r"(frm));
#endif

    const volatile uint32_t *rec = &in[4];  //  records start at IN_BASE+0x10

    for (uint32_t i = 0; i < n_vec; i++) {
        const volatile uint32_t *r = &rec[stride_in * i];
        uint32_t a = r[0];
        uint32_t b = r[1];
        uint32_t c = r[2];
        uint32_t r_lo = 0, r_hi = 0;
        uint32_t f = 0;

        switch (op) {
        //  -- F (32-bit) ops --
        case FP_F32_ADD:    BINOP_FF("fadd.s",  a, b, r_lo, f); break;
        case FP_F32_SUB:    BINOP_FF("fsub.s",  a, b, r_lo, f); break;
        case FP_F32_MUL:    BINOP_FF("fmul.s",  a, b, r_lo, f); break;
        case FP_F32_DIV:    BINOP_FF("fdiv.s",  a, b, r_lo, f); break;
        case FP_F32_SQRT:   UNOP_FF("fsqrt.s",  a, r_lo, f);    break;
        case FP_F32_MULADD: FMA("fmadd.s", a, b, c, r_lo, f);   break;
        case FP_F32_EQ:     CMP_FF("feq.s", a, b, r_lo, f);     break;
        case FP_F32_LE:     CMP_FF("fle.s", a, b, r_lo, f);     break;
        case FP_F32_LT:     CMP_FF("flt.s", a, b, r_lo, f);     break;
        case FP_F32_TO_I32: F2I32("fcvt.w.s",  a, r_lo, f);     break;
        case FP_F32_TO_UI32:    F2I32("fcvt.wu.s", a, r_lo, f);     break;
        case FP_F32_TO_I64: {
            uint64_t r64; F2I64("fcvt.l.s", a, r64, f);
            r_lo = (uint32_t)r64; r_hi = (uint32_t)(r64 >> 32); break;
        }
        case FP_F32_TO_UI64: {
            uint64_t r64; F2I64("fcvt.lu.s", a, r64, f);
            r_lo = (uint32_t)r64; r_hi = (uint32_t)(r64 >> 32); break;
        }
        case FP_I32_TO_F32: {
            int64_t s = (int64_t)(int32_t)a;
            I2F("fcvt.s.w", s, r_lo, f); break;
        }
        case FP_UI32_TO_F32:    I2F("fcvt.s.wu", (uint64_t)a, r_lo, f); break;
        case FP_I64_TO_F32: {
            uint64_t x = ((uint64_t)b << 32) | a;
            I2F("fcvt.s.l", x, r_lo, f); break;
        }
        case FP_UI64_TO_F32: {
            uint64_t x = ((uint64_t)b << 32) | a;
            I2F("fcvt.s.lu", x, r_lo, f); break;
        }

        //  -- D (64-bit) ops --
        //  Operands packed at stride_in=8 u32: a64 = r[1:0], b64 = r[3:2],
        //  c64 = r[5:4].
        case FP_F64_ADD: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            uint64_t res; BINOP_DD("fadd.d", a64, b64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_SUB: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            uint64_t res; BINOP_DD("fsub.d", a64, b64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_MUL: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            uint64_t res; BINOP_DD("fmul.d", a64, b64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_DIV: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            uint64_t res; BINOP_DD("fdiv.d", a64, b64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_SQRT: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t res; UNOP_DD("fsqrt.d", a64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_MULADD: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            uint64_t c64 = ((uint64_t)r[5] << 32) | r[4];
            uint64_t res; FMA_D("fmadd.d", a64, b64, c64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_EQ: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            CMP_DD("feq.d", a64, b64, r_lo, f); break;
        }
        case FP_F64_LE: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            CMP_DD("fle.d", a64, b64, r_lo, f); break;
        }
        case FP_F64_LT: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t b64 = ((uint64_t)r[3] << 32) | r[2];
            CMP_DD("flt.d", a64, b64, r_lo, f); break;
        }
        case FP_F64_TO_I32: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            D2I32("fcvt.w.d",  a64, r_lo, f); break;
        }
        case FP_F64_TO_UI32: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            D2I32("fcvt.wu.d", a64, r_lo, f); break;
        }
        case FP_F64_TO_I64: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t res; D2I64("fcvt.l.d", a64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_TO_UI64: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t res; D2I64("fcvt.lu.d", a64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_I32_TO_F64: {
            int64_t s = (int64_t)(int32_t)r[0];
            uint64_t res; I2D_EXACT("fcvt.d.w", s, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_UI32_TO_F64: {
            uint64_t res; I2D_EXACT("fcvt.d.wu", (uint64_t)r[0], res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_I64_TO_F64: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t res; I2D("fcvt.d.l", a64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_UI64_TO_F64: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            uint64_t res; I2D("fcvt.d.lu", a64, res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F32_TO_F64: {
            uint64_t res; STOD(r[0], res, f);
            r_lo = (uint32_t)res; r_hi = (uint32_t)(res >> 32); break;
        }
        case FP_F64_TO_F32: {
            uint64_t a64 = ((uint64_t)r[1] << 32) | r[0];
            DTOS(a64, r_lo, f); break;
        }

        default: break;
        }

        out[4*i + 0] = r_lo;
        out[4*i + 1] = r_hi;
        out[4*i + 2] = f & 0x1f;
        out[4*i + 3] = 0;
    }

    sio_puts("[fp_subj] done\n");
    htif_exit(0);
    return 0;
}
