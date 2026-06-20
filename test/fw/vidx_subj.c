//  vidx_subj.c
//  Minimal self-checking directed test for indexed vector load/store
//  (vluxei/vsuxei). Runs on BOTH spike (rv64gcv golden) and karu64. All ops
//  use tu,mu so tail/masked-off keep the old vd (a sentinel) -> bit-identical
//  between spike and karu64. main() returns 0 iff every case matches.

#include <stdint.h>
#include "sio_generic.h"

#define VL   8
#define SENT 0xEEEEEEEEu

static uint32_t src[VL];
static uint32_t dst[64];
static uint32_t gold[64];
static uint32_t mem32[64];          //  scatter/gather target (byte base = mem32)
static uint8_t  idxb[VL];           //  byte offsets (multiples of 4 here)

static void put_hex(uint32_t x){int i;sio_putc('0');sio_putc('x');for(i=28;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, caseno=0, ff=0;
static void check(const char*nm,uint32_t*a,uint32_t*b,int n){
    int i,bad=0; caseno++;
    for(i=0;i<n;i++) if(a[i]!=b[i]) bad++;
    sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts(nm);
    if(bad){ for(i=0;i<n;i++) if(a[i]!=b[i]){ sio_puts("\n  i="); put_dec(i);
        sio_puts(" got="); put_hex(a[i]); sio_puts(" exp="); put_hex(b[i]); }
        fails++; if(!ff) ff=caseno; }
    sio_putc('\n');
}

int main(void){
    int i;
    for(i=0;i<VL;i++){ src[i]=0xA0000000u+i; idxb[i]=(uint8_t)((VL-1-i)*4); }

    //  ==== indexed STORE: vsuxei8, data e32, index e8 ====
    for(i=0;i<64;i++) mem32[i]=0x11110000u+i;   //  prefill
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle32.v v8,(%[s])\n"
        "vle8.v  v4,(%[ix])\n"              //  8 index bytes into v4[0..7]
        "vsuxei8.v v8,(%[m]),v4\n"
        :: [vl]"r"(VL),[s]"r"(src),[ix]"r"(idxb),[m]"r"(mem32) : "t0","memory");
    for(i=0;i<64;i++) gold[i]=0x11110000u+i;    //  reference scatter over the prefill
    for(i=0;i<VL;i++) gold[idxb[i]/4]=src[i];
    check("vsuxei8 (e32 data, e8 idx)", mem32, gold, 16);

    //  ==== indexed LOAD: vluxei8, data e32, index e8 ====
    for(i=0;i<64;i++) dst[i]=SENT;
    asm volatile(
        "vsetvli t0,%[vl],e32,m1,tu,mu\n"
        "vle8.v  v4,(%[ix])\n"
        "vluxei8.v v12,(%[m]),v4\n"
        "vse32.v v12,(%[d])\n"
        :: [vl]"r"(VL),[ix]"r"(idxb),[m]"r"(mem32),[d]"r"(dst) : "t0","memory");
    for(i=0;i<64;i++) gold[i]=SENT;
    for(i=0;i<VL;i++) gold[i]=mem32[idxb[i]/4];
    check("vluxei8 (e32 data, e8 idx)", dst, gold, VL);

    //  ==== indexed LOAD with dest==index overlap: vluxei32 v4,(mem),v4 ====
    //  (load gathered data into the same reg that held the indices.)
    //  EQUAL data/index EEW, so the overlap is architecturally legal (RVV
    //  5.2). The original form here was vluxei8 at SEW=32 -- dest EEW >
    //  index EEW with index EMUL=1/4 < 1, a RESERVED encoding that newer
    //  spike (correctly) traps and karu64 now traps too (v_idxov_ill); the
    //  equal-EEW form keeps the buffered-index-overlap coverage.
    {
        static uint32_t ovix[VL];
        for(i=0;i<VL;i++) ovix[i]=(uint32_t)((VL-1-i)*4);
        for(i=0;i<64;i++) dst[i]=SENT;
        asm volatile(
            "vsetvli t0,%[vl],e32,m1,tu,mu\n"
            "vle32.v v4,(%[ix])\n"
            "vluxei32.v v4,(%[m]),v4\n"     //  overlap (legal: equal EEW)
            "vse32.v v4,(%[d])\n"
            :: [vl]"r"(VL),[ix]"r"(ovix),[m]"r"(mem32),[d]"r"(dst) : "t0","memory");
        for(i=0;i<64;i++) gold[i]=SENT;
        for(i=0;i<VL;i++) gold[i]=mem32[ovix[i]/4];
        check("vluxei32 overlap (vd==vs2)", dst, gold, VL);
    }

    //  ==== indexed LOAD, index EEW=32 (vluxei32) ====
    {
        static uint32_t idx32[VL];
        for(i=0;i<VL;i++) idx32[i]=(uint32_t)((VL-1-i)*4);
        for(i=0;i<64;i++) dst[i]=SENT;
        asm volatile(
            "vsetvli t0,%[vl],e32,m1,tu,mu\n"
            "vle32.v v4,(%[ix])\n"
            "vluxei32.v v12,(%[m]),v4\n"
            "vse32.v v12,(%[d])\n"
            :: [vl]"r"(VL),[ix]"r"(idx32),[m]"r"(mem32),[d]"r"(dst) : "t0","memory");
        for(i=0;i<64;i++) gold[i]=SENT;
        for(i=0;i<VL;i++) gold[i]=mem32[idx32[i]/4];
        check("vluxei32 (e32 data, e32 idx)", dst, gold, VL);
    }

    //  ==== masked + tail indexed LOAD (agnostic ta,ma) -> undisturbed ====
    //  Preload dest v12 with a sentinel, mask out odd elements, vl=5<VLMAX.
    //  Active in-vl -> gathered; masked-off in-vl and tail -> keep old (Sail
    //  golden realises agnostic as undisturbed).
    {
        uint8_t mb = 0x15;                  //  v0 = elements 0,2,4 active (bits 0,2,4)
        int vlm = 5;
        for(i=0;i<64;i++) dst[i]=SENT;
        //  preload v12 with SENT via a full-VLMAX move, set v0 mask
        asm volatile(
            "vsetvli t0,%[vmax],e32,m1,ta,ma\n"
            "vmv.v.x v12,%[sent]\n"         //  v12 = SENT everywhere (old dest)
            "vmv.s.x v0,%[mb]\n"                //  v0[0] = mask bits
            "vsetvli t0,%[vl],e32,m1,ta,ma\n"
            "vle8.v  v4,(%[ix])\n"
            "vluxei8.v v12,(%[m]),v4,v0.t\n"    //  masked indexed gather
            "vsetvli t0,%[vmax],e32,m1,ta,ma\n"
            "vse32.v v12,(%[d])\n"              //  dump full VLMAX
            :: [vmax]"r"(8),[vl]"r"(vlm),[sent]"r"(SENT),[mb]"r"((uint64_t)mb),
               [ix]"r"(idxb),[m]"r"(mem32),[d]"r"(dst) : "t0","memory");
        for(i=0;i<64;i++) gold[i]=SENT;
        for(i=0;i<vlm;i++) if((mb>>i)&1) gold[i]=mem32[idxb[i]/4];  //  active in-vl gathered; rest = SENT
        check("vluxei8 masked+tail (ta,ma -> undist)", dst, gold, 8);
    }

    //  ==== masked indexed STORE -> masked-off mem unchanged ====
    {
        uint8_t mb = 0x15;
        int vlm = 5;
        for(i=0;i<64;i++) mem32[i]=0x22220000u+i;
        for(i=0;i<VL;i++) src[i]=0xB0000000u+i;
        asm volatile(
            "vsetvli t0,%[vl],e32,m1,ta,ma\n"
            "vle32.v v8,(%[s])\n"
            "vmv.s.x v0,%[mb]\n"
            "vle8.v  v4,(%[ix])\n"
            "vsuxei8.v v8,(%[m]),v4,v0.t\n"
            :: [vl]"r"(vlm),[mb]"r"((uint64_t)mb),[s]"r"(src),
               [ix]"r"(idxb),[m]"r"(mem32) : "t0","memory");
        for(i=0;i<64;i++) gold[i]=0x22220000u+i;
        for(i=0;i<vlm;i++) if((mb>>i)&1) gold[idxb[i]/4]=src[i];
        check("vsuxei8 masked store (off=unchanged)", mem32, gold, 16);
    }

    //  ==== LMUL=8 indexed LOAD (e32,m8) + tail undisturbed ====
    //  VLMAX=64; vl=34; index EEW=32 (EMUL=8). dest v8..v15. tail (34..63) old.
    {
        static uint32_t idx32b[64];
        int vlm = 34, vmax = 64;
        for(i=0;i<vmax;i++) idx32b[i]=(uint32_t)((i*4) % 64);   //  indices into mem32
        for(i=0;i<vmax;i++) dst[i]=SENT;
        asm volatile(
            "vsetvli t0,%[vmax],e32,m8,ta,ma\n"
            "vmv.v.x v8,%[sent]\n"          //  old dest = SENT
            "vsetvli t0,%[vl],e32,m8,ta,ma\n"
            "vle32.v v16,(%[ix])\n"         //  indices into v16..v23 (EMUL=8)
            "vluxei32.v v8,(%[m]),v16\n"
            "vsetvli t0,%[vmax],e32,m8,ta,ma\n"
            "vse32.v v8,(%[d])\n"
            :: [vmax]"r"(vmax),[vl]"r"(vlm),[sent]"r"(SENT),
               [ix]"r"(idx32b),[m]"r"(mem32),[d]"r"(dst) : "t0","memory");
        for(i=0;i<vmax;i++) gold[i]=SENT;
        for(i=0;i<vlm;i++) gold[i]=mem32[idx32b[i]/4];
        check("vluxei32 e32/m8 vl=34 (tail undist)", dst, gold, vmax);
    }

    //  ==== LMUL=2 indexed STORE (e32,m2), index EEW=8 (EMUL=mf2) ====
    {
        int vlm = 12;
        static uint32_t src2[16]; static uint8_t idx2[16];
        for(i=0;i<64;i++) mem32[i]=0x33330000u+i;
        for(i=0;i<16;i++){ src2[i]=0xC0000000u+i; idx2[i]=(uint8_t)((15-i)*4); }
        asm volatile(
            "vsetvli t0,%[vl],e32,m2,ta,ma\n"
            "vle32.v v8,(%[s])\n"
            "vle8.v  v4,(%[ix])\n"          //  index EEW=8, EMUL=mf2 -> v4
            "vsuxei8.v v8,(%[m]),v4\n"
            :: [vl]"r"(vlm),[s]"r"(src2),[ix]"r"(idx2),[m]"r"(mem32) : "t0","memory");
        for(i=0;i<64;i++) gold[i]=0x33330000u+i;
        for(i=0;i<vlm;i++) gold[idx2[i]/4]=src2[i];
        check("vsuxei8 e32/m2 vl=12", mem32, gold, 16);
    }

    //  ==== LMUL=8 indexed LOAD with vd==vs2 OVERLAP + tail (the ACT4 case) ====
    //  v8 holds indices for 0..vl-1 and SENT for the tail; vluxei32 v8,(mem),v8.
    //  Active -> gathered; tail -> old v8 (= SENT, undisturbed).
    {
        static uint32_t idx32c[64];
        int vlm = 34, vmax = 64;
        for(i=0;i<vmax;i++) idx32c[i]=(uint32_t)((i*4) % 64);
        asm volatile(
            "vsetvli t0,%[vmax],e32,m8,ta,ma\n"
            "vmv.v.x v8,%[sent]\n"              //  v8 = SENT everywhere
            "vsetvli t0,%[vl],e32,m8,tu,ma\n"
            "vle32.v v8,(%[ix])\n"              //  v8[0..33] = indices, tail kept SENT (tu)
            "vsetvli t0,%[vl],e32,m8,ta,ma\n"
            "vluxei32.v v8,(%[m]),v8\n"         //  OVERLAP gather
            "vsetvli t0,%[vmax],e32,m8,ta,ma\n"
            "vse32.v v8,(%[d])\n"
            :: [vmax]"r"(vmax),[vl]"r"(vlm),[sent]"r"(SENT),
               [ix]"r"(idx32c),[m]"r"(mem32),[d]"r"(dst) : "t0","memory");
        for(i=0;i<vmax;i++) gold[i]=SENT;
        for(i=0;i<vlm;i++) gold[i]=mem32[idx32c[i]/4];
        check("vluxei32 e32/m8 OVERLAP vl=34 (tail undist)", dst, gold, vmax);
    }

    //  ==== indexed SEGMENT store/load: vsuxseg2ei8 / vluxseg2ei8 (nf=2, e32) ====
    //  segment i: field0 at mem[base+idx[i]], field1 at mem[base+idx[i]+4].
    //  source/dest: field0 = v8 group, field1 = v9 group (EMUL=1 at e32/m1).
    {
        static uint32_t f0[VL], f1[VL];
        int vlm = VL;
        for(i=0;i<VL;i++){ f0[i]=0xD0000000u+i; f1[i]=0xD1000000u+i; idxb[i]=(uint8_t)((VL-1-i)*8); }
        for(i=0;i<64;i++) mem32[i]=0;
        asm volatile(
            "vsetvli t0,%[vl],e32,m1,ta,ma\n"
            "vle32.v v8,(%[f0])\n"
            "vle32.v v9,(%[f1])\n"
            "vle8.v  v4,(%[ix])\n"
            "vsuxseg2ei8.v v8,(%[m]),v4\n"
            :: [vl]"r"(vlm),[f0]"r"(f0),[f1]"r"(f1),[ix]"r"(idxb),[m]"r"(mem32):"t0","memory");
        for(i=0;i<64;i++) gold[i]=0;
        for(i=0;i<vlm;i++){ gold[idxb[i]/4]=f0[i]; gold[idxb[i]/4+1]=f1[i]; }
        check("vsuxseg2ei8 (e32, nf=2)", mem32, gold, 32);
        //  reload via indexed segment load
        for(i=0;i<64;i++) dst[i]=SENT;
        asm volatile(
            "vsetvli t0,%[vl],e32,m1,ta,ma\n"
            "vle8.v  v4,(%[ix])\n"
            "vluxseg2ei8.v v12,(%[m]),v4\n"
            "vse32.v v12,(%[d0])\n"
            "vse32.v v13,(%[d1])\n"
            :: [vl]"r"(vlm),[ix]"r"(idxb),[m]"r"(mem32),
               [d0]"r"(dst),[d1]"r"(dst+32):"t0","memory");
        for(i=0;i<64;i++) gold[i]=SENT;
        for(i=0;i<vlm;i++){ gold[i]=mem32[idxb[i]/4]; gold[32+i]=mem32[idxb[i]/4+1]; }
        check("vluxseg2ei8 field0", dst, gold, VL);
        check("vluxseg2ei8 field1", dst+32, gold+32, VL);
    }

    //  ==== UNALIGNED indexed store/load (indices not multiples of 4) ====
    //  exercises the granule-straddle path: a 4-byte element at byte offset 13
    //  spans two 16-byte granules.
    {
        static uint8_t  membytes[256];
        static uint32_t srcu[VL], goldb_dummy;
        static uint8_t  idxu[VL];
        int vlm = VL;
        (void)goldb_dummy;
        for(i=0;i<VL;i++){ srcu[i]=0xE0000000u+i*0x01010101u; idxu[i]=(uint8_t)(3 + i*9); } //  3,12,21,30,... unaligned
        for(i=0;i<256;i++) membytes[i]=0x5a;
        asm volatile(
            "vsetvli t0,%[vl],e32,m1,ta,ma\n"
            "vle32.v v8,(%[s])\n"
            "vle8.v  v4,(%[ix])\n"
            "vsuxei8.v v8,(%[m]),v4\n"
            :: [vl]"r"(vlm),[s]"r"(srcu),[ix]"r"(idxu),[m]"r"(membytes):"t0","memory");
        //  reference scatter into membytes (byte-wise, little-endian 4-byte elem)
        { static uint8_t gb[256]; int j;
          for(j=0;j<256;j++) gb[j]=0x5a;
          for(i=0;i<vlm;i++) for(j=0;j<4;j++) gb[idxu[i]+j]=(uint8_t)(srcu[i]>>(j*8));
          { int bad=0; caseno++; for(j=0;j<256;j++) if(membytes[j]!=gb[j]) bad++;
            sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts("vsuxei8 UNALIGNED store");
            if(bad){ for(j=0;j<256;j++) if(membytes[j]!=gb[j]){ sio_puts("\n  b="); put_dec(j);
                sio_puts(" got="); put_hex(membytes[j]); sio_puts(" exp="); put_hex(gb[j]); }
              fails++; if(!ff) ff=caseno; }
            sio_putc('\n'); }
        }
        //  unaligned gather back
        for(i=0;i<64;i++) dst[i]=SENT;
        asm volatile(
            "vsetvli t0,%[vl],e32,m1,ta,ma\n"
            "vle8.v  v4,(%[ix])\n"
            "vluxei8.v v12,(%[m]),v4\n"
            "vse32.v v12,(%[d])\n"
            :: [vl]"r"(vlm),[ix]"r"(idxu),[m]"r"(membytes),[d]"r"(dst):"t0","memory");
        for(i=0;i<64;i++) gold[i]=SENT;
        for(i=0;i<vlm;i++){ uint32_t v=0; int j; for(j=0;j<4;j++) v|=((uint32_t)membytes[idxu[i]+j])<<(j*8); gold[i]=v; }
        check("vluxei8 UNALIGNED gather", dst, gold, VL);
    }

    //  ==== index EEW > data EEW: vsuxei32 with e8 data (index EMUL=4 regs) ====
    //  data EEW=8 (SEW=8), index EEW=32 -> index EMUL = 32/8 = 4 registers.
    {
        static uint8_t  s8[64], m8[256];
        static uint32_t i32[64];
        int vlm = 16;
        for(i=0;i<vlm;i++){ s8[i]=(uint8_t)(0x40+i); i32[i]=(uint32_t)((vlm-1-i)); }    //  byte indices 15..0
        for(i=0;i<256;i++) m8[i]=0x99;
        asm volatile(
            "vsetvli t0,%[vl],e8,m1,ta,ma\n"
            "vle8.v  v8,(%[s])\n"               //  data e8 -> v8 (EMUL=1)
            "vsetvli t0,%[vl],e32,m4,ta,ma\n"   //  load 32-bit indices, EMUL=4
            "vle32.v v16,(%[ix])\n"
            "vsetvli t0,%[vl],e8,m1,ta,ma\n"
            "vsuxei32.v v8,(%[m]),v16\n"        //  index group = v16..v19
            :: [vl]"r"(vlm),[s]"r"(s8),[ix]"r"(i32),[m]"r"(m8):"t0","memory");
        { static uint8_t gb[256]; int bad=0,j; caseno++;
          for(j=0;j<256;j++) gb[j]=0x99;
          for(i=0;i<vlm;i++) gb[i32[i]]=s8[i];      //  scatter bytes
          for(j=0;j<256;j++) if(m8[j]!=gb[j]) bad++;
          sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts("vsuxei32 e8 data (idx EMUL=4)");
          if(bad){ for(j=0;j<32;j++) if(m8[j]!=gb[j]){ sio_puts("\n  b="); put_dec(j);
              sio_puts(" got="); put_hex(m8[j]); sio_puts(" exp="); put_hex(gb[j]); }
            fails++; if(!ff) ff=caseno; }
          sio_putc('\n');
        }
        //  gather back: vluxei32 e8 data
        { static uint8_t d8[64]; int j;
          for(j=0;j<64;j++) d8[j]=0;
          asm volatile(
            "vsetvli t0,%[vl],e32,m4,ta,ma\n"
            "vle32.v v16,(%[ix])\n"
            "vsetvli t0,%[vl],e8,m1,ta,ma\n"
            "vluxei32.v v8,(%[m]),v16\n"
            "vse8.v v8,(%[d])\n"
            :: [vl]"r"(vlm),[ix]"r"(i32),[m]"r"(m8),[d]"r"(d8):"t0","memory");
          { uint32_t da[16],ga[16]; int bad=0; caseno++;
            for(i=0;i<vlm;i++){ da[i]=d8[i]; ga[i]=m8[i32[i]]; if(da[i]!=ga[i]) bad++; }
            sio_puts(bad?"[FAIL] ":"[ ok ] "); sio_puts("vluxei32 e8 data (idx EMUL=4)");
            if(bad){ for(i=0;i<vlm;i++) if(da[i]!=ga[i]){ sio_puts("\n  i="); put_dec(i);
                sio_puts(" got="); put_hex(da[i]); sio_puts(" exp="); put_hex(ga[i]); }
              fails++; if(!ff) ff=caseno; }
            sio_putc('\n');
          }
        }
    }

    if(fails){ sio_puts("[VIDX] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[VIDX] ALL PASS\n");
    sio_putc(4);
    return ff;
}
