// SHAKE128/SHAKE256 end-to-end checks of absorb XOR, capacity preservation,
// padding and multi-block squeeze. Independent expected bytes: Python hashlib
// shake_{128,256}(bytes((17*i+3)%256 for i in range(3*rate))).digest(3*rate).
// Every byte alignment is tested, including 16-byte granule and 4-KiB crossings.
// TEST_PBMT=1/2 additionally checks NC/IO mappings using this same resident-
// state harness. Those modes are functional regressions, not cycle benchmarks.
#include <stdint.h>
#include "sio_generic.h"
#include "shake_kat.h"
static uint8_t input[8192] __attribute__((aligned(4096)));
static uint8_t output[8192] __attribute__((aligned(4096)));
#ifndef TEST_PBMT
#define TEST_PBMT 0
#endif
#if TEST_PBMT < 0 || TEST_PBMT > 2
#error "TEST_PBMT must be 0 (PMA), 1 (NC), or 2 (IO)"
#endif
#if TEST_PBMT
// Kept outside the normal image/BSS/stack by fp_subj.ld. Initialize explicitly:
// NOLOAD avoids growing the binary and does not imply simulator-zeroed memory.
static uint64_t pbmt_tables[3][512]
    __attribute__((section(".pbmt_tables"), aligned(4096)));
static uint64_t saved_mstatus, saved_satp, saved_menvcfg;

static void buffer_alias_fence(void)
{
    // Svpbmt's cacheability-switch sequence applies in both directions.
    // While MPRV is set these CBO addresses use the attributed mapping too.
    asm volatile("fence iorw,iorw" ::: "memory");
    for (uintptr_t p=(uintptr_t)input; p<(uintptr_t)input+sizeof(input); p+=64)
        asm volatile(".insn i 0x0f,2,x0,%0,2" :: "r"(p) : "memory"); // cbo.flush
    for (uintptr_t p=(uintptr_t)output; p<(uintptr_t)output+sizeof(output); p+=64)
        asm volatile(".insn i 0x0f,2,x0,%0,2" :: "r"(p) : "memory");
    asm volatile("fence iorw,iorw" ::: "memory");
}

static int pbmt_begin(void)
{
    asm volatile("csrr %0,mstatus" : "=r"(saved_mstatus));
    asm volatile("csrr %0,satp" : "=r"(saved_satp));
    asm volatile("csrr %0,0x30a" : "=r"(saved_menvcfg));
    for (unsigned table=0; table<3; ++table)
        for (unsigned entry=0; entry<512; ++entry) pbmt_tables[table][entry]=0;
    pbmt_tables[0][2]=((uintptr_t)pbmt_tables[1] >> 2) | 1;
    pbmt_tables[1][0]=((uintptr_t)pbmt_tables[2] >> 2) | 1;
    for (unsigned entry=0; entry<512; ++entry) {
        uintptr_t pa=0x80000000UL+((uintptr_t)entry<<12);
        uint64_t attr=((pa >= (uintptr_t)input && pa < (uintptr_t)input+sizeof(input)) ||
                       (pa >= (uintptr_t)output && pa < (uintptr_t)output+sizeof(output)))
                      ? (uint64_t)TEST_PBMT<<61 : 0;
        pbmt_tables[2][entry]=(pa>>2) | 0xcf | attr; // V/R/W/X/A/D, supervisor
    }
    buffer_alias_fence(); // BSS initialization used the original PMA mapping.
    uint64_t env=saved_menvcfg | (1UL<<62), observed;
    asm volatile("csrw 0x30a,%0\n csrr %1,0x30a" : "+r"(env), "=r"(observed) :: "memory");
    if (!(observed & (1UL<<62))) return 0;
    uint64_t satp=(8UL<<60) | ((uintptr_t)pbmt_tables[0]>>12);
    uint64_t status=(saved_mstatus & ~(3UL<<11)) | (1UL<<11) | (1UL<<17);
    asm volatile("csrw satp,%0\n sfence.vma x0,x0\n csrw mstatus,%1"
                 :: "r"(satp), "r"(status) : "memory");
    return 1;
}

static void pbmt_end(void)
{
    buffer_alias_fence(); // No input/output PMA access while MPRV is active.
    asm volatile("csrw mstatus,%0\n csrw satp,%1\n csrw 0x30a,%2\n sfence.vma x0,x0"
                 :: "r"(saved_mstatus), "r"(saved_satp), "r"(saved_menvcfg) : "memory");
}
#endif
static void run(unsigned rate, uint8_t *in, uint8_t *out)
{
    unsigned long lanes = rate / 8;
    asm volatile(
        "vsetvli t0,zero,e64,m8,tu,mu\n vmv.v.i v0,0\n"
        "vsetvli t0,%[vl],e64,m8,tu,mu\n li t1,4\n"
        "1:\n vle64.v v8,(%[in])\n vxor.vv v0,v0,v8\n"
        ".word 0xa6092077\n add %[in],%[in],%[rate]\n"
        "addi t1,t1,-1\n bnez t1,1b\n li t1,3\n"
        "2:\n vse64.v v0,(%[out])\n .word 0xa6092077\n"
        "add %[out],%[out],%[rate]\n addi t1,t1,-1\n bnez t1,2b\n"
        : [in] "+&r"(in), [out] "+&r"(out)
        : [vl] "r"(lanes), [rate] "r"((unsigned long)rate)
        : "t0", "t1", "memory", "vl", "vtype",
          "v0","v1","v2","v3","v4","v5","v6","v7",
          "v8","v9","v10","v11","v12","v13","v14","v15");
}
int main(void)
{
    unsigned fails = 0;
#if TEST_PBMT
    if (!pbmt_begin()) {
        sio_puts("[SPONGE] FAIL: PBMTE unavailable\n");
        return 1;
    }
    sio_puts(TEST_PBMT == 1 ? "[SPONGE] resident-state PBMT=NC\n" :
                             "[SPONGE] resident-state PBMT=IO\n");
#endif
    for (unsigned which=0; which<2; ++which) {
        unsigned rate = which ? 136 : 168;
        const uint8_t *expected = which ? expected136 : expected168;
        for (unsigned alignment=0; alignment<16; ++alignment) {
            // First block straddles a page; every other rate block also
            // alternates the half-granule alignment (rate % 16 == 8).
            unsigned offset = 4096-32+alignment;
            uint8_t *in = input+offset, *out = output+offset;
            for (unsigned i=offset-16; i<offset+3*rate+16; ++i) output[i]=0xa5;
            for (unsigned i=0; i<3*rate; ++i) in[i]=(uint8_t)(17*i+3);
            for (unsigned i=3*rate; i<4*rate; ++i) in[i]=0;
            in[3*rate]=0x1f; in[4*rate-1]=0x80;
            run(rate,in,out);
            unsigned bad=0;
            for (unsigned i=0; i<3*rate; ++i) if(out[i]!=expected[i]) ++bad;
            for (unsigned i=offset-16; i<offset; ++i) if(output[i]!=0xa5) ++bad;
            for (unsigned i=offset+3*rate; i<offset+3*rate+16; ++i)
                if(output[i]!=0xa5) ++bad;
            if(bad) {
                sio_puts("[FAIL] SHAKE"); sio_puts(which ? "256" : "128");
                sio_puts(" alignment "); sio_putc("0123456789abcdef"[alignment]);
                sio_putc('\n'); ++fails;
            }
        }
        sio_puts(which ? "[SHAKE256] 16 alignments checked\n" :
                         "[SHAKE128] 16 alignments checked\n");
    }
#if TEST_PBMT
    pbmt_end();
#endif
    sio_puts(fails ? "[SPONGE] FAIL\n" : "[SPONGE] ALL PASS\n");
    return fails ? 1 : 0;
}
