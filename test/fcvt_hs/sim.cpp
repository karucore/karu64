#include "Vfcvt_hs_tb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
extern "C" {
  #include "softfloat.h"
}
// map RISC-V frm -> softfloat rounding mode
// index -> {RISC-V frm encoding passed to the DUT, SoftFloat rounding mode}.
// ROD (round-to-odd, frm=6) is the live mode for vfncvt.rod.f.f.w.
static const uint8_t RM_FRM[6] = {0,1,2,3,4,6};
static const uint8_t RM_SF[6]  = {
  softfloat_round_near_even, softfloat_round_minMag, softfloat_round_min,
  softfloat_round_max, softfloat_round_near_maxMag, softfloat_round_odd };
// RISC-V fflags bit layout: NX=0 UF=1 OF=2 DZ=3 NV=4
static uint8_t sf_to_rvfl(uint8_t f){
  uint8_t r=0;
  if(f&softfloat_flag_inexact)  r|=1<<0;
  if(f&softfloat_flag_underflow)r|=1<<1;
  if(f&softfloat_flag_overflow) r|=1<<2;
  if(f&softfloat_flag_invalid)  r|=1<<4;
  return r;
}
int main(int argc,char**argv){
  Verilated::commandArgs(argc,argv);
  Vfcvt_hs_tb*d=new Vfcvt_hs_tb;
  long werr=0,nerr=0,tot=0;
  // ---- WIDEN: exhaustive all 65536 FP16 (exact; flags only sNaN->NV) ----
  for(uint32_t h=0;h<0x10000;h++){
    d->h_in=h; d->rm=0; d->eval();
    softfloat_exceptionFlags=0;
    float16_t hf; hf.v=(uint16_t)h;
    float32_t sf=f16_to_f32(hf);
    uint8_t ef=sf_to_rvfl(softfloat_exceptionFlags);
    uint32_t got=d->s_out; uint8_t gfl=d->hs_fl;
    // NaN payload: both produce canonical; compare canonicalized
    bool nan_exp = ((sf.v&0x7F800000)==0x7F800000)&&(sf.v&0x7FFFFF);
    bool ok = nan_exp ? (got==0x7FC00000 && gfl==ef) : (got==sf.v && gfl==ef);
    if(!ok){ if(werr<8) printf("WIDEN h=%04x got=%08x/%x exp=%08x/%x\n",h,got,gfl,sf.v,ef); werr++; }
  }
  // ---- NARROW: all 5 RMs over a structured f32 sweep ----
  // every f16 value widened (exact midpoints), +/- a few ULP around each, the
  // overflow/underflow boundaries, specials, and a dense low-bit sweep.
  auto check_narrow=[&](uint32_t s,int rmi){
    d->s_in=s; d->rm=RM_FRM[rmi]; d->eval();
    softfloat_roundingMode=RM_SF[rmi]; softfloat_exceptionFlags=0;
    float32_t sf; sf.v=s; float16_t hf=f32_to_f16(sf);
    uint8_t ef=sf_to_rvfl(softfloat_exceptionFlags);
    uint16_t got=d->h_out; uint8_t gfl=d->sh_fl;
    bool nan_exp=((hf.v&0x7C00)==0x7C00)&&(hf.v&0x3FF);
    bool ok = nan_exp ? (got==0x7E00 && gfl==ef) : (got==hf.v && gfl==ef);
    if(!ok){ if(nerr<12) printf("NARROW rm=%d s=%08x got=%04x/%x exp=%04x/%x\n",rmi,s,got,gfl,hf.v,ef); nerr++; }
    tot++;
  };
  for(int rmi=0;rmi<6;rmi++){
    for(uint32_t h=0;h<0x10000;h++){
      float16_t hf; hf.v=(uint16_t)h; float32_t base=f16_to_f32(hf);
      for(int32_t d2=-3;d2<=3;d2++) check_narrow(base.v+d2,rmi);
    }
    // boundary + special f32 values
    uint32_t sp[]={0x00000000,0x80000000,0x7F800000,0xFF800000,0x7FC00000,0x7F800001,
                   0x38800000,0x387FE000,0x33000000,0x33000001,0x47800000,0x477FF000,
                   0x7FFFFFFF,0x00000001,0x80000001,0x33800000,0x34000000};
    for(uint32_t v:sp) check_narrow(v,rmi);
    // dense random-ish low/mid sweep
    for(uint32_t k=0;k<200000;k++){ uint32_t v=(k*2654435761u)^(k<<13); check_narrow(v,rmi); }
  }
  // ---- D->H narrow (fcvt.h.d): all 6 RMs over a structured f64 sweep ----
  long dherr=0,dtot=0;
  auto check_dh=[&](uint64_t v,int rmi){
    d->d_in=v; d->rm=RM_FRM[rmi]; d->eval();
    softfloat_roundingMode=RM_SF[rmi]; softfloat_exceptionFlags=0;
    float64_t df; df.v=v; float16_t hf=f64_to_f16(df);
    uint8_t ef=sf_to_rvfl(softfloat_exceptionFlags);
    uint16_t got=d->dh_out; uint8_t gfl=d->dh_fl;
    bool nan_exp=((hf.v&0x7C00)==0x7C00)&&(hf.v&0x3FF);
    bool ok = nan_exp ? (got==0x7E00 && gfl==ef) : (got==hf.v && gfl==ef);
    if(!ok){ if(dherr<12) printf("DH rm=%d v=%016lx got=%04x/%x exp=%04x/%x\n",rmi,v,got,gfl,hf.v,ef); dherr++; }
    dtot++;
  };
  for(int rmi=0;rmi<6;rmi++){
    // every f16 value widened to f64 (exact), +/- a few f64 ULP around it
    for(uint32_t h=0;h<0x10000;h++){
      float16_t hf; hf.v=(uint16_t)h; float64_t base=f16_to_f64(hf);
      for(int32_t dd=-3;dd<=3;dd++) check_dh(base.v+dd,rmi);
    }
    // boundary + special f64 values (overflow, tiny, specials)
    uint64_t sp[]={0,0x8000000000000000ULL,0x7FF0000000000000ULL,0xFFF0000000000000ULL,
      0x7FF8000000000000ULL,0x7FF0000000000001ULL,0x40F0000000000000ULL,// 65536 ovf
      0x40EFFC0000000000ULL,0x3F10000000000000ULL,// max-finite-ish, tiny
      0x3E70000000000000ULL,0x3E60000000000001ULL,0x3FF8000000000000ULL};
    for(uint64_t v:sp) check_dh(v,rmi);
    for(uint32_t k=0;k<150000;k++){ uint64_t v=((uint64_t)(k*2654435761u)<<32)^(k*40503u); check_dh(v,rmi); }
  }
  printf("DH(fcvt.h.d): %ld vectors x6RM, %ld err\n",dtot,dherr);
  printf("WIDEN: 65536 vectors, %ld err\nNARROW: %ld vectors x6RM (incl ROD), %ld err\n",werr,tot,nerr);
  printf("%s\n",(werr==0&&nerr==0&&dherr==0)?"FCVT_HS ALL PASS":"FCVT_HS FAIL");
  delete d; return (werr||nerr||dherr)?1:0;
}
