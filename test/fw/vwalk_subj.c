// Bounded element-local walk: all supported SEW/LMUL combinations, both
// sides of granule/register boundaries, masks, vstart, and destination alias.
// Compare every byte (including fractional-LMUL tails) to a scalar oracle.
// The identical ELF is run on Spike and default/FPGA-pipeline Karu.
// Nonzero arithmetic vstart may legally trap: verify preserved state if so.
#include <stdint.h>
#include "sio_generic.h"

static uint64_t a[32] __attribute__((aligned(32)));
static uint64_t b[32] __attribute__((aligned(32)));
static uint64_t seed[32] __attribute__((aligned(32)));
static uint64_t out[32] __attribute__((aligned(32)));
static uint8_t masks[4][32] __attribute__((aligned(32)));
volatile uint64_t walk_traps, walk_cause;
asm(".align 2\nwalk_tvec:\n"
    "addi sp,sp,-16\n sd t0,0(sp)\n sd t1,8(sp)\n"
    "csrr t0,mcause\n la t1,walk_cause\n sd t0,0(t1)\n"
    "la t1,walk_traps\n ld t0,0(t1)\n addi t0,t0,1\n sd t0,0(t1)\n"
    "csrr t0,mepc\n addi t0,t0,4\n csrw mepc,t0\n"
    "ld t0,0(sp)\n ld t1,8(sp)\n addi sp,sp,16\n mret\n");

static void dec(unsigned n)
{
    char buf[12]; unsigned k = 0;
    do { buf[k++] = '0' + n % 10; n /= 10; } while (n);
    while (k) sio_putc(buf[--k]);
}

#define CLOBBERS "memory", "vl", "vtype", "v0", \
    "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", \
    "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", \
    "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31"

static int run(unsigned sew, unsigned lm, unsigned vl, unsigned start,
               unsigned mode, unsigned alias)
{
    uint64_t actual, after_start, type = (sew << 3) | lm;
    uint64_t before = walk_traps;
    const uint64_t *initial = alias ? a : seed;
#define RUN(OP) asm volatile( \
    "vl8re8.v v8,(%[a])\n vl8re8.v v16,(%[b])\n" \
    "vl8re8.v v24,(%[seed])\n vl1re8.v v0,(%[mask])\n" \
    "vsetvl %[actual],%[vl],%[type]\n csrw vstart,%[start]\n" \
    OP "\n csrr %[after],vstart\n csrw vstart,zero\n vs8r.v v24,(%[out])\n" \
    : [actual] "=&r"(actual), [after] "=&r"(after_start) \
    : [a] "r"(a), [b] "r"(b), [seed] "r"(initial), [mask] "r"(masks[mode]), \
      [vl] "r"((uint64_t)vl), [type] "r"(type), [start] "r"((uint64_t)start), \
      [out] "r"(out) : CLOBBERS)
    if (alias) {
        if (mode) RUN("vxor.vv v24,v24,v16,v0.t");
        else RUN("vxor.vv v24,v24,v16");
    } else {
        if (mode) RUN("vxor.vv v24,v8,v16,v0.t");
        else RUN("vxor.vv v24,v8,v16");
    }
#undef RUN
    int trapped = walk_traps != before;
    if (actual != vl) return 1;
    if (trapped) {
        if (!start || walk_traps != before+1 || walk_cause != 2 || after_start != start)
            return 1;
    } else if (after_start != 0) return 1;
    // Compare every byte, eight at a time to keep the sweep inexpensive on
    // the simulated scalar core. The alternating element mask is expanded
    // independently of the RTL, then clipped to the active byte interval.
    static const uint64_t alternating[] = {
        0x00ff00ff00ff00ffUL, 0x0000ffff0000ffffUL,
        0x00000000ffffffffUL, UINT64_MAX
    };
    unsigned lo = start << sew, hi = vl << sew;
    for (unsigned w = 0; w < 32; ++w) {
        unsigned i = w * 8;
        uint64_t active = 0;
        if (!trapped && mode != 3 && i < hi && i+8 > lo) {
            active = mode != 2 ? UINT64_MAX :
                     (sew == 3 && (w & 1)) ? 0 : alternating[sew];
            if (lo > i) active &= UINT64_MAX << ((lo-i)*8);
            if (hi < i+8) active &= UINT64_MAX >> ((i+8-hi)*8);
        }
        uint64_t expected = ((a[w] ^ b[w]) & active) | (initial[w] & ~active);
        if (out[w] != expected) return 1;
    }
    return 0;
}

int main(void)
{
    unsigned cases = 0;
    asm volatile("la t0,walk_tvec\n csrw mtvec,t0" ::: "t0", "memory");
    for (unsigned i = 0; i < sizeof(a); ++i) {
        ((uint8_t *)a)[i] = (uint8_t)(i * 17 + 3);
        ((uint8_t *)b)[i] = (uint8_t)(i * 29 + 11);
        ((uint8_t *)seed)[i] = 0xa5;
    }
    for (unsigned mode = 0; mode < 4; ++mode)
        for (unsigned i = 0; i < 32; ++i)
            masks[mode][i] = mode == 2 ? 0x55 : mode == 3 ? 0 : 0xff;
    for (unsigned sew = 0; sew < 4; ++sew) {
        for (unsigned lm = 0; lm < 8; ++lm) {
            if (lm == 4 || (lm >= 5 && sew > lm - 5)) continue;
            unsigned epr = 32 >> sew, gran = 16 >> sew;
            unsigned max = lm < 4 ? epr << lm : epr >> (8 - lm);
            unsigned lengths[] = {0, 1, gran-1, gran, gran+1,
                                  epr-1, epr, epr+1, max-1, max};
            for (unsigned n = 0; n < sizeof(lengths)/sizeof(lengths[0]); ++n) {
                unsigned vl = lengths[n];
                if (vl > max) continue;
                int duplicate = 0;
                for (unsigned j = 0; j < n; ++j) if (lengths[j] == vl) duplicate = 1;
                if (duplicate) continue;
                for (unsigned s = 0; s < 3; ++s) {
                    unsigned start = s == 0 ? 0 : s == 1 ? vl/2 : vl;
                    // VLEN=256 needs only eight writable vstart bits; 256
                    // is outside Spike's WARL range, even at e8,m8 VLMAX.
                    if (start >= 256) continue;
                    if (s && (start == 0 || (s == 2 && start == vl/2))) continue;
                    for (unsigned mode = 0; mode < 4; ++mode) {
                        for (unsigned alias = 0; alias < 2; ++alias) {
                            ++cases;
                            if (run(sew, lm, vl, start, mode, alias)) {
                                sio_puts("[VWALK] FAIL sew="); dec(8 << sew);
                                sio_puts(" lmul-encoding="); dec(lm);
                                sio_puts(" vl="); dec(vl);
                                sio_puts(" vstart="); dec(start);
                                sio_puts(" mask-mode="); dec(mode);
                                sio_puts(" alias="); dec(alias); sio_putc('\n');
                                return 1;
                            }
                        }
                    }
                }
            }
            sio_puts("[ ok ] sew="); dec(8 << sew);
            sio_puts(" lmul-encoding="); dec(lm); sio_putc('\n');
        }
    }
    sio_puts("[VWALK] ALL PASS cases="); dec(cases);
    sio_puts(" permitted-vstart-traps="); dec((unsigned)walk_traps); sio_putc('\n');
    return 0;
}
