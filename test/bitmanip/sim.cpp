#include "Vbm_tb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
// BM_* codes (mirror karu_uop_defs.vh)
enum { ANDN,ORN,XNOR,CLZ,CTZ,CPOP,MAX,MAXU,MIN,MINU,SEXTB,SEXTH,ZEXTH,ROL,ROR,
       ORCB,REV8,SH1ADD,SH2ADD,SH3ADD,ADDUW,SH1ADDUW,SH2ADDUW,SH3ADDUW,SLLIUW,
       BCLR,BEXT,BINV,BSET };
typedef uint64_t u64; typedef uint32_t u32;
static u64 clz64(u64 v){ if(!v)return 64; int n=0; for(int i=63;i>=0;i--){ if(v>>i&1)break; n++; } return n; }
static u64 ctz64(u64 v){ if(!v)return 64; int n=0; for(int i=0;i<64;i++){ if(v>>i&1)break; n++; } return n; }
static u64 cpop64(u64 v){ int n=0; for(int i=0;i<64;i++) n+=(v>>i)&1; return n; }
static u64 clz32(u32 v){ if(!v)return 32; int n=0; for(int i=31;i>=0;i--){ if(v>>i&1)break; n++; } return n; }
static u64 ctz32(u32 v){ if(!v)return 32; int n=0; for(int i=0;i<32;i++){ if(v>>i&1)break; n++; } return n; }
static u64 cpop32(u32 v){ int n=0; for(int i=0;i<32;i++) n+=(v>>i)&1; return n; }
static u64 sext32(u32 v){ return (u64)(int64_t)(int32_t)v; }
static u64 ref(int sub,int is_w,u64 a,u64 b){
  u32 wa=(u32)a; int sh6=b&63, sh5=b&31;
  switch(sub){
    case ANDN: return a&~b; case ORN: return a|~b; case XNOR: return ~(a^b);
    case CLZ: return is_w?clz32(wa):clz64(a);
    case CTZ: return is_w?ctz32(wa):ctz64(a);
    case CPOP:return is_w?cpop32(wa):cpop64(a);
    case MAX: return ((int64_t)a>(int64_t)b)?a:b;
    case MIN: return ((int64_t)a<(int64_t)b)?a:b;
    case MAXU:return (a>b)?a:b; case MINU:return (a<b)?a:b;
    case SEXTB:return (u64)(int64_t)(int8_t)a;
    case SEXTH:return (u64)(int64_t)(int16_t)a;
    case ZEXTH:return a&0xffff;
    case ROL: if(is_w){u32 r=sh5?((wa<<sh5)|(wa>>(32-sh5))):wa; return sext32(r);}
              else return sh6?((a<<sh6)|(a>>(64-sh6))):a;
    case ROR: if(is_w){u32 r=sh5?((wa>>sh5)|(wa<<(32-sh5))):wa; return sext32(r);}
              else return sh6?((a>>sh6)|(a<<(64-sh6))):a;
    case ORCB:{u64 r=0; for(int i=0;i<8;i++){u64 byte=(a>>(i*8))&0xff; if(byte) r|=(u64)0xffULL<<(i*8);} return r;}
    case REV8:{u64 r=0; for(int i=0;i<8;i++) r|=((a>>(i*8))&0xff)<<((7-i)*8); return r;}
    case SH1ADD:return b+(a<<1); case SH2ADD:return b+(a<<2); case SH3ADD:return b+(a<<3);
    case ADDUW: return b+(u64)wa;
    case SH1ADDUW:return b+((u64)wa<<1); case SH2ADDUW:return b+((u64)wa<<2); case SH3ADDUW:return b+((u64)wa<<3);
    case SLLIUW: return (u64)wa<<sh6;
    case BCLR:return a&~((u64)1<<sh6); case BEXT:return (a>>sh6)&1;
    case BINV:return a^((u64)1<<sh6); case BSET:return a|((u64)1<<sh6);
  }
  return 0;
}
int main(int argc,char**argv){
  Verilated::commandArgs(argc,argv);
  Vbm_tb*d=new Vbm_tb;
  // structured operand set: corners + a pseudo-random sweep
  u64 vals[]={0,1,2,3,0xff,0x100,0x8000000000000000ULL,0x7fffffffffffffffULL,
    0xffffffffffffffffULL,0x123456789abcdef0ULL,0x80000000ULL,0x7fffffffULL,
    0xdeadbeefcafebabeULL,0xaaaaaaaaaaaaaaaaULL,0x5555555555555555ULL,0x1ULL<<40};
  int NV=sizeof(vals)/sizeof(vals[0]);
  long err=0,tot=0;
  for(int sub=0;sub<=BSET;sub++) for(int w=0;w<2;w++){
    // is_w only meaningful for clz/ctz/cpop/rol/ror; skip w=1 otherwise to avoid
    // testing undefined combos (the decoder never emits them)
    if(w && !(sub==CLZ||sub==CTZ||sub==CPOP||sub==ROL||sub==ROR)) continue;
    for(int ia=0;ia<NV;ia++) for(int ib=0;ib<NV;ib++){
      u64 a=vals[ia], b=vals[ib];
      // also sweep shift amounts 0..63 for shift/bit ops
      for(int s=-1;s<64;s++){
        u64 bb = (s<0)? b : (u64)s;
        d->op1=a; d->op2=bb; d->sub=sub; d->is_w=w; d->eval();
        u64 got=d->out, exp=ref(sub,w,a,bb);
        if(got!=exp){ if(err<12) printf("MISMATCH sub=%d w=%d a=%016lx b=%016lx got=%016lx exp=%016lx\n",sub,w,a,bb,got,exp); err++; }
        tot++;
        if(!(sub==ROL||sub==ROR||sub==SLLIUW||sub==BCLR||sub==BEXT||sub==BINV||sub==BSET)) break; // shamt sweep only for shift/bit
      }
    }
  }
  printf("BITMANIP: %ld vectors, %ld err\n%s\n",tot,err,err?"BITMANIP FAIL":"BITMANIP ALL PASS");
  delete d; return err?1:0;
}
