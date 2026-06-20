//  vfp_bench.c — confirm the 2d parallel FP dispatch is real (not seq fallback).
//  fdiv has a long, data-independent latency Ldiv. A scalar fdiv.s measures
//  Ldiv. A vfdiv.vv at e32/m1 (vl=8) computes 8 results. With NLANES=4 lanes
//  each doing 2 chunk-elements over 2 slot-rounds, the parallel path costs
//  ~2*Ldiv; a sequential (lane-0) path would cost ~8*Ldiv. So vec/scalar ~2
//  => parallel, ~8 => sequential.

#include <stdint.h>
#include "sio_generic.h"

static void put_dec(uint32_t x){char b[12];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static inline uint64_t rdcyc(void){uint64_t c;asm volatile("rdcycle %0":"=r"(c));return c;}

#define K 256
static float va[8], vb[8], vo[8];

int main(void){
    int i; uint64_t t0,t1;
    asm volatile("li t0,0x6600\n csrs mstatus,t0\n csrw fcsr,x0":::"t0");
    for(i=0;i<8;i++){ va[i]=(float)(i+3)*1.5f; vb[i]=(float)(i+1)*0.5f+0.25f; }

    //  scalar fdiv.s latency (chained so it can't overlap/optimize out)
    { float a=3.0f, b=1.0009765625f; t0=rdcyc();
      for(i=0;i<K;i++) asm volatile("fdiv.s %0,%0,%1":"+f"(a):"f"(b));
      t1=rdcyc(); volatile float sink=a; (void)sink;
      sio_puts("scalar fdiv.s  per-op cyc = "); put_dec((uint32_t)((t1-t0)/K)); sio_putc('\n'); }

    //  vector vfdiv.vv, e32 m1 (vl=8): 8 results / op
    { t0=rdcyc();
      for(i=0;i<K;i++)
        asm volatile("vsetivli t0,8,e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
                     "vfdiv.vv v10,v8,v9\n vse32.v v10,(%[o])\n"
                     ::[a]"r"(va),[b]"r"(vb),[o]"r"(vo):"t0","memory");
      t1=rdcyc();
      sio_puts("vfdiv.vv(8e)  per-op cyc = "); put_dec((uint32_t)((t1-t0)/K));
      sio_puts("  (parallel ~2x scalar, sequential ~8x)\n"); }

    //  vector vfdiv.vv, e64 m1 (vl=4): 4 results / op, 1 slot * 4 lanes
    { static double da[4],db[4],dox[4]; int j;
      for(j=0;j<4;j++){ da[j]=(double)(j+3)*1.5; db[j]=(double)(j+1)*0.5+0.25; }
      t0=rdcyc();
      for(i=0;i<K;i++)
        asm volatile("vsetivli t0,4,e64,m1,tu,mu\n vle64.v v8,(%[a])\n vle64.v v9,(%[b])\n"
                     "vfdiv.vv v10,v8,v9\n vse64.v v10,(%[o])\n"
                     ::[a]"r"(da),[b]"r"(db),[o]"r"(dox):"t0","memory");
      t1=rdcyc();
      sio_puts("vfdiv.vv(4e64) per-op cyc = "); put_dec((uint32_t)((t1-t0)/K));
      sio_puts("  (parallel: 4 lanes 1 slot ~1x fdiv.d)\n"); }

    sio_putc(4);
    return 0;
}
