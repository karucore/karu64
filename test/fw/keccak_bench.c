// Ideal-memory cycle decomposition of VLEN=256 Zvknhk and SHAKE rate blocks.
// Run with make keccak-bench; N=16, state resident, warmed absorb input.
// Includes core/cache/AXI protocol costs but no injected external wait states.
#include <stdint.h>
#include "sio_generic.h"

#define N 16u
#define VCLOBBERS "memory", "vl", "vtype", \
    "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", \
    "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15"

static uint64_t st[32] __attribute__((aligned(64)));
static uint64_t in_blocks[21 * N] __attribute__((aligned(64)));
static uint64_t out_blocks[21 * N] __attribute__((aligned(64)));
static volatile uint64_t call_count;
static volatile uint64_t warm_sink;

static void put_u64(uint64_t x)
{
    char b[24]; unsigned n = 0;
    do { b[n++] = (char)('0' + x % 10); x /= 10; } while (x);
    while (n) sio_putc(b[--n]);
}

static void result(const char *name, uint64_t cycles)
{
    sio_puts(name); sio_puts(": total="); put_u64(cycles);
    sio_puts(" cycles, per-op="); put_u64(cycles / N);
    sio_putc('.');
    unsigned fraction = ((cycles % N) * 100 + N / 2) / N;
    if (fraction < 10) sio_putc('0');
    put_u64(fraction);
    sio_putc('\n');
}

static uint64_t insn24_only(void)
{
    uint64_t c0, c1;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        "rdcycle %[c0]\n"
        ".rept 16\n .word 0xa6092077\n .endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

static uint64_t insn12_only(void)
{
    uint64_t c0, c1;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        "rdcycle %[c0]\n"
        ".rept 16\n .word 0xa6192077\n .endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

static uint64_t memory_pair(void)
{
    uint64_t c0, c1;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n vse64.v v0,(%[s])\n"
        "rdcycle %[c0]\n"
        ".rept 16\n"
        "vle64.v v0,(%[s])\n vse64.v v0,(%[s])\n"
        ".endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

static uint64_t load_only(void)
{
    uint64_t c0, c1;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        "rdcycle %[c0]\n"
        ".rept 16\n vle64.v v0,(%[s])\n .endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

static uint64_t store_only(void)
{
    uint64_t c0, c1;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n vse64.v v0,(%[s])\n"
        "rdcycle %[c0]\n"
        ".rept 16\n vse64.v v0,(%[s])\n .endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

static uint64_t wrapper_no_vset(void)
{
    uint64_t c0, c1;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n vse64.v v0,(%[s])\n"
        "rdcycle %[c0]\n"
        ".rept 16\n"
        "vle64.v v0,(%[s])\n"
        ".word 0xa6092077\n"
        "vse64.v v0,(%[s])\n"
        ".endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

static uint64_t wrapper_exact(void)
{
    uint64_t c0, c1;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n vse64.v v0,(%[s])\n"
        "rdcycle %[c0]\n"
        ".rept 16\n"
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        ".word 0xa6092077\n"
        "vse64.v v0,(%[s])\n"
        ".endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

/* Match the freestanding ML-KEM/ML-DSA wrapper used for the 942-cycle report:
 * an out-of-line call, vlenb probe/branch and permutation counter included. */
__attribute__((noinline))
static void measured_wrapper(uint64_t *s)
{
    unsigned long vlenb;
    ++call_count;
    __asm volatile("csrr %0,0xc22" : "=r" (vlenb));
    if (vlenb >= 32) {
        __asm volatile(
            "vsetivli x0,25,e64,m8,tu,mu\n"
            "vle64.v v0,(%[s])\n"
            ".word 0xa6092077\n"
            "vse64.v v0,(%[s])\n"
            : : [s] "r" (s) : VCLOBBERS);
    }
}

static uint64_t wrapper_function(void)
{
    uint64_t c0, c1;
    unsigned i;
    measured_wrapper(st);
    __asm volatile("rdcycle %0" : "=r" (c0));
    for (i = 0; i < N; ++i) measured_wrapper(st);
    __asm volatile("rdcycle %0" : "=r" (c1));
    return c1 - c0;
}

static void warm_input(unsigned words)
{
    unsigned i;
    uint64_t x = 0;
    for (i = 0; i < words; ++i) x ^= in_blocks[i];
    warm_sink = x;
}

/* Steady-state SHAKE128 absorb: state remains in v0-v7, each 168-byte
 * message block is loaded once into v8-v15 and XORed before permutation. */
static uint64_t absorb168(void)
{
    uint64_t c0, c1;
    uint64_t *p = in_blocks;
    warm_input(21 * N);
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        "vsetivli x0,21,e64,m8,tu,mu\n"
        "rdcycle %[c0]\n"
        ".rept 16\n"
        "vle64.v v8,(%[p])\n"
        "vxor.vv v0,v0,v8\n"
        ".word 0xa6092077\n"
        "addi %[p],%[p],168\n"
        ".endr\n"
        "rdcycle %[c1]\n"
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vse64.v v0,(%[s])\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1), [p] "+r" (p)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

/* SHA3-256 and SHAKE256 both use the 136-byte rate. */
static uint64_t absorb136(void)
{
    uint64_t c0, c1;
    uint64_t *p = in_blocks;
    warm_input(17 * N);
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        "vsetivli x0,17,e64,m8,tu,mu\n"
        "rdcycle %[c0]\n"
        ".rept 16\n"
        "vle64.v v8,(%[p])\n"
        "vxor.vv v0,v0,v8\n"
        ".word 0xa6092077\n"
        "addi %[p],%[p],136\n"
        ".endr\n"
        "rdcycle %[c1]\n"
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vse64.v v0,(%[s])\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1), [p] "+r" (p)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

/* Steady-state XOF output: one rate block is stored from the resident state,
 * then the state is advanced for the following block. The last permutation
 * is deliberately retained so every measured iteration is one steady-state
 * squeeze step; a finite N-block squeeze needs only N-1 permutations. */
static uint64_t squeeze168(void)
{
    uint64_t c0, c1;
    uint64_t *p = out_blocks;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        "vsetivli x0,21,e64,m8,tu,mu\n"
        "rdcycle %[c0]\n"
        ".rept 16\n"
        "vse64.v v0,(%[p])\n"
        ".word 0xa6092077\n"
        "addi %[p],%[p],168\n"
        ".endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1), [p] "+r" (p)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

static uint64_t squeeze136(void)
{
    uint64_t c0, c1;
    uint64_t *p = out_blocks;
    __asm volatile(
        "vsetivli x0,25,e64,m8,tu,mu\n"
        "vle64.v v0,(%[s])\n"
        "vsetivli x0,17,e64,m8,tu,mu\n"
        "rdcycle %[c0]\n"
        ".rept 16\n"
        "vse64.v v0,(%[p])\n"
        ".word 0xa6092077\n"
        "addi %[p],%[p],136\n"
        ".endr\n"
        "rdcycle %[c1]\n"
        : [c0] "=&r" (c0), [c1] "=&r" (c1), [p] "+r" (p)
        : [s] "r" (st) : VCLOBBERS);
    return c1 - c0;
}

#define DEFINE_RATE_PARTS(TAG, VL, BYTES, WORDS)                         \
static uint64_t load##TAG(void)                                         \
{                                                                        \
    uint64_t c0, c1; uint64_t *p = in_blocks;                            \
    warm_input((WORDS) * N);                                             \
    __asm volatile(                                                      \
        "vsetivli x0," #VL ",e64,m8,tu,mu\n rdcycle %[c0]\n"       \
        ".rept 16\n vle64.v v8,(%[p])\n addi %[p],%[p]," #BYTES "\n .endr\n" \
        "rdcycle %[c1]\n"                                               \
        : [c0] "=&r" (c0), [c1] "=&r" (c1), [p] "+r" (p)              \
        : : VCLOBBERS);                                                  \
    return c1 - c0;                                                      \
}                                                                        \
static uint64_t store##TAG(void)                                        \
{                                                                        \
    uint64_t c0, c1; uint64_t *p = out_blocks;                           \
    __asm volatile(                                                      \
        "vsetivli x0,25,e64,m8,tu,mu\n vle64.v v0,(%[s])\n"             \
        "vsetivli x0," #VL ",e64,m8,tu,mu\n rdcycle %[c0]\n"       \
        ".rept 16\n vse64.v v0,(%[p])\n addi %[p],%[p]," #BYTES "\n .endr\n" \
        "rdcycle %[c1]\n"                                               \
        : [c0] "=&r" (c0), [c1] "=&r" (c1), [p] "+r" (p)              \
        : [s] "r" (st) : VCLOBBERS);                                    \
    return c1 - c0;                                                      \
}                                                                        \
static uint64_t xor##TAG(void)                                          \
{                                                                        \
    uint64_t c0, c1;                                                     \
    __asm volatile(                                                      \
        "vsetivli x0,25,e64,m8,tu,mu\n"                                 \
        "vle64.v v0,(%[s])\n vle64.v v8,(%[i])\n"                     \
        "vsetivli x0," #VL ",e64,m8,tu,mu\n rdcycle %[c0]\n"       \
        ".rept 16\n vxor.vv v0,v0,v8\n .endr\n rdcycle %[c1]\n"        \
        : [c0] "=&r" (c0), [c1] "=&r" (c1)                             \
        : [s] "r" (st), [i] "r" (in_blocks) : VCLOBBERS);              \
    return c1 - c0;                                                      \
}

DEFINE_RATE_PARTS(168, 21, 168, 21)
DEFINE_RATE_PARTS(136, 17, 136, 17)

int main(void)
{
    unsigned i;
    for (i = 0; i < 32; ++i) st[i] = i;
    for (i = 0; i < 21 * N; ++i) in_blocks[i] = 0x0101010101010101ULL * i;
    sio_puts("[keccak cycle decomposition; N=16]\n");
    result("vkeccak.vi 24-round, VRF resident", insn24_only());
    result("vkeccak.vi 12-round, VRF resident", insn12_only());
    result("vle64 only, cache hot", load_only());
    result("vse64 only, cache hot", store_only());
    result("vle64+vse64 only, cache hot", memory_pair());
    result("vle64+vkeccak+vse64", wrapper_no_vset());
    result("vset+vle64+vkeccak+vse64", wrapper_exact());
    result("ML-KEM-style wrapper function", wrapper_function());
    result("SHAKE128 absorb, resident state, 168 B/block", absorb168());
    result("SHA3-256/SHAKE256 absorb, resident state, 136 B/block", absorb136());
    result("SHAKE128 squeeze, resident state, 168 B/block", squeeze168());
    result("SHAKE256 squeeze, resident state, 136 B/block", squeeze136());
    result("  168 B load component", load168());
    result("  168 B xor component", xor168());
    result("  168 B store component", store168());
    result("  136 B load component", load136());
    result("  136 B xor component", xor136());
    result("  136 B store component", store136());
    return 0;
}
