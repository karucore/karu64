// Single-stream software comparison; see README.md for measurement scope.
// Compile the inlined portable permutation with the selected ISA/optimization.
#include <stdint.h>
#include "sio_generic.h"
#include "shake_kat.h"
#include "keccak_sw_inline.h"
#define N 16
int sw_check(unsigned kind,const uint64_t *state,const uint64_t *out);
static int bad;
static uint64_t s[32] __attribute__((aligned(64)));
static uint64_t input[21*N] __attribute__((aligned(64)));
static uint64_t output[21*N] __attribute__((aligned(64)));
static volatile uint64_t sink;
static void num(uint64_t x) {
    char b[24]; unsigned n=0;
    do {b[n++]='0'+x%10; x/=10;} while(x);
    while(n) sio_putc(b[--n]);
}
static uint64_t cycles(void) {
    uint64_t n; asm volatile("rdcycle %0" : "=r"(n) :: "memory"); return n;
}
static void reset(void) { for(unsigned i=0;i<32;++i) s[i]=0; }
static void warm(unsigned words) {
    uint64_t x=0; for(unsigned i=0;i<words;++i) x^=input[i]; sink=x;
}
static void report(const char *name, uint64_t n) {
    sio_puts(name); sio_puts(": total="); num(n); sio_puts(" per-block=");
    num(n/N); sio_putc('.'); unsigned f=((n%N)*100+N/2)/N;
    if(f<10) sio_putc('0'); num(f); sio_putc('\n');
}
static int kat(unsigned rate,const uint8_t *expected) {
    reset();
    for(unsigned block=0;block<3;++block) {
        for(unsigned i=0;i<rate;++i)
            s[i/8]^=(uint64_t)(uint8_t)(17*(block*rate+i)+3) << ((i%8)*8);
        KeccakF1600_StatePermute(s);
    }
    s[0]^=0x1f; s[rate/8-1]^=0x8000000000000000UL;
    KeccakF1600_StatePermute(s);
    for(unsigned block=0;block<3;++block) {
        for(unsigned i=0;i<rate;++i)
            if((uint8_t)(s[i/8] >> ((i%8)*8)) != expected[block*rate+i]) return 1;
        KeccakF1600_StatePermute(s);
    }
    return 0;
}
#define BENCH(RATE, WORDS) \
static void absorb##RATE(void) { \
    uint64_t s[25]={0}; warm(WORDS*N); uint64_t c=cycles(); \
    _Pragma("GCC unroll 1") \
    for(unsigned block=0;block<N;++block) { \
        for(unsigned i=0;i<WORDS;++i) s[i]^=input[block*WORDS+i]; \
        KeccakF1600_StatePermute(s); \
    } \
    uint64_t end=cycles(); bad|=sw_check(RATE==168?0:1,s,output); report("absorb " #RATE,end-c); \
} \
static void squeeze##RATE(void) { \
    uint64_t s[25]={0}; uint64_t c=cycles(); \
    _Pragma("GCC unroll 1") \
    for(unsigned block=0;block<N;++block) { \
        for(unsigned i=0;i<WORDS;++i) output[block*WORDS+i]=s[i]; \
        KeccakF1600_StatePermute(s); \
    } \
    uint64_t end=cycles(); bad|=sw_check(RATE==168?2:3,s,output); report("squeeze " #RATE,end-c); \
}
BENCH(168,21)
BENCH(136,17)
int main(void) {
    if(kat(168,expected168) || kat(136,expected136)) {
        sio_puts("[SW KAT] FAIL\n"); return 1;
    }
    sio_puts("[SW KAT] PASS both SHAKE rates\n");
    for(unsigned i=0;i<21*N;++i) input[i]=0x0101010101010101UL*i;
    absorb168(); absorb136(); squeeze168(); squeeze136();
    uint64_t s[25]={0}; uint64_t c=cycles();
    for(unsigned i=0;i<N;++i) KeccakF1600_StatePermute(s);
    uint64_t end=cycles(); sink=s[0]; report("permutation call",end-c);
    sio_puts(bad ? "[STREAM] FAIL\n" : "[STREAM] ALL PASS: full states and all output blocks\n");
    return bad;
}
