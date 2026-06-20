//  vfp_subj.c
//  Directed self-check for the vector-FP unit (karu_vfpu, Stage 4a). Each
//  case runs a vector-FP op, stores the result, and compares bit-exact
//  against a scalar reference computed with the SAME karu FPU (so this
//  validates the vfpu element sequencing + operand mapping; the FP
//  arithmetic itself is already covered by TestFloat / the scalar ACT4).
//  tu,mu everywhere -> tail/masked-off keep old vd (deterministic).

#include <stdint.h>
#include "sio_generic.h"

#define N 8
static float  fa[N], fb[N], fd[N], fg[N];
static double da[N], db[N], dd[N], dg[N];
static uint32_t mres, mref;

static void put_hex(uint32_t x){int i;sio_putc('0');sio_putc('x');for(i=28;i>=0;i-=4)sio_putc("0123456789abcdef"[(x>>i)&0xf]);}
static void put_dec(uint32_t x){char b[10];int n=0;if(!x){sio_putc('0');return;}while(x){b[n++]='0'+x%10;x/=10;}while(n)sio_putc(b[--n]);}
static int fails=0, caseno=0, ff=0;
static void chkf(const char*nm){int i,bad=0;caseno++;
    for(i=0;i<N;i++){ uint32_t g=*(uint32_t*)&fd[i], r=*(uint32_t*)&fg[i]; if(g!=r)bad++; }
    sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts(nm);
    if(bad){for(i=0;i<N;i++){uint32_t g=*(uint32_t*)&fd[i],r=*(uint32_t*)&fg[i];if(g!=r){sio_puts("\n  i=");put_dec(i);sio_puts(" got=");put_hex(g);sio_puts(" exp=");put_hex(r);}}fails++;if(!ff)ff=caseno;}
    sio_putc('\n');}
static void chkd(const char*nm){int i,bad=0;caseno++;
    for(i=0;i<N;i++){ uint64_t g=*(uint64_t*)&dd[i], r=*(uint64_t*)&dg[i]; if(g!=r)bad++; }
    sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts(nm);
    if(bad){for(i=0;i<N;i++){uint64_t g=*(uint64_t*)&dd[i],r=*(uint64_t*)&dg[i];if(g!=r){sio_puts("\n  i=");put_dec(i);sio_puts(" got=");put_hex((uint32_t)(g>>32));put_hex((uint32_t)g);sio_puts(" exp=");put_hex((uint32_t)(r>>32));put_hex((uint32_t)r);}}fails++;if(!ff)ff=caseno;}
    sio_putc('\n');}

int main(void){
    int i;
    for(i=0;i<N;i++){ fa[i]=1.5f*(i+1); fb[i]=0.25f*(i+2)-1.0f; da[i]=1.5*(i+1); db[i]=0.25*(i+2)-1.0; }

    //  ---- e32 vfadd.vv ----
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
        "vfadd.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++) fg[i]=fa[i]+fb[i]; chkf("vfadd.vv e32");

    //  ---- e32 vfsub / vfmul / vfdiv .vv ----
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
        "vfsub.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++) fg[i]=fa[i]-fb[i]; chkf("vfsub.vv e32");
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
        "vfmul.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++) fg[i]=fa[i]*fb[i]; chkf("vfmul.vv e32");
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
        "vfdiv.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++) fg[i]=fa[i]/fb[i]; chkf("vfdiv.vv e32");

    //  ---- e32 vfsqrt.v ----
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n"
        "vfsqrt.v v10,v8\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++){ float x=fa[i]; asm volatile("fsqrt.s %0,%1":"=f"(fg[i]):"f"(x)); } chkf("vfsqrt.v e32");

    //  ---- e32 vfmin / vfmax / vfsgnj ----
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
        "vfmin.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++){ float a=fa[i],b=fb[i]; asm volatile("fmin.s %0,%1,%2":"=f"(fg[i]):"f"(a),"f"(b)); } chkf("vfmin.vv e32");
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
        "vfsgnj.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++){ float a=fa[i],b=fb[i]; asm volatile("fsgnj.s %0,%1,%2":"=f"(fg[i]):"f"(a),"f"(b)); } chkf("vfsgnj.vv e32");

    //  ---- e32 vfadd.vf / vfmul.vf (scalar) ----
    { float s=3.25f;
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfadd.vf v10,v8,%[s]\n vse32.v v10,(%[d])\n"
        ::[n]"r"(N),[a]"r"(fa),[s]"f"(s),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++) fg[i]=fa[i]+s; chkf("vfadd.vf e32");
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfrsub.vf v10,v8,%[s]\n vse32.v v10,(%[d])\n"
        ::[n]"r"(N),[a]"r"(fa),[s]"f"(s),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++) fg[i]=s-fa[i]; chkf("vfrsub.vf e32"); }

    //  ---- e32 FMA: vfmacc.vv (vd += vs1*vs2) ----
    for(i=0;i<N;i++) fd[i]=0.5f*i;
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n vle32.v v10,(%[d])\n"
        "vfmacc.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
    for(i=0;i<N;i++){ float a=fa[i],b=fb[i],c=0.5f*i; asm volatile("fmadd.s %0,%1,%2,%3":"=f"(fg[i]):"f"(a),"f"(b),"f"(c)); } chkf("vfmacc.vv e32");

    //  ---- e32 compare -> mask: vmflt.vv ----
    asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
        "vmflt.vv v0,v8,v9\n vsetvli t0,%[n],e8,m1,tu,mu\n vse8.v v0,(%[m])\n"
        ::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[m]"r"(&mres):"t0","memory");
    mref=0; for(i=0;i<N;i++) if(fa[i]<fb[i]) mref|=(1u<<i);
    { caseno++; uint32_t got=mres&0xff; if(got!=mref){sio_puts("[FAIL] vmflt.vv e32\n  got=");put_hex(got);sio_puts(" exp=");put_hex(mref);sio_putc('\n');fails++;if(!ff)ff=caseno;} else sio_puts("[ ok ] vmflt.vv e32\n"); }

    //  ==== e64 (double) sanity: m2 so VLMAX=8 covers all N elements ====
    asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n vle64.v v10,(%[b])\n"
        "vfadd.vv v12,v8,v10\n vse64.v v12,(%[d])\n"::[n]"r"(N),[a]"r"(da),[b]"r"(db),[d]"r"(dd):"t0","memory");
    for(i=0;i<N;i++) dg[i]=da[i]+db[i]; chkd("vfadd.vv e64/m2");
    asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n vle64.v v10,(%[b])\n"
        "vfmul.vv v12,v8,v10\n vse64.v v12,(%[d])\n"::[n]"r"(N),[a]"r"(da),[b]"r"(db),[d]"r"(dd):"t0","memory");
    for(i=0;i<N;i++) dg[i]=da[i]*db[i]; chkd("vfmul.vv e64/m2");
    asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n"
        "vfsqrt.v v12,v8\n vse64.v v12,(%[d])\n"::[n]"r"(N),[a]"r"(da),[d]"r"(dd):"t0","memory");
    for(i=0;i<N;i++){ double x=da[i]; asm volatile("fsqrt.d %0,%1":"=f"(dg[i]):"f"(x)); } chkd("vfsqrt.v e64/m2");
    for(i=0;i<N;i++) dd[i]=0.5*i;
    asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n vle64.v v10,(%[b])\n vle64.v v12,(%[d])\n"
        "vfmacc.vv v12,v8,v10\n vse64.v v12,(%[d])\n"::[n]"r"(N),[a]"r"(da),[b]"r"(db),[d]"r"(dd):"t0","memory");
    for(i=0;i<N;i++){ double a=da[i],b=db[i],c=0.5*i; asm volatile("fmadd.d %0,%1,%2,%3":"=f"(dg[i]):"f"(a),"f"(b),"f"(c)); } chkd("vfmacc.vv e64/m2");

    //  ==== conversions (same-width) ====
    {
        static float    cf[N]; static int32_t vi[N], ri[N]; static uint32_t vu[N], ru[N];
        for(i=0;i<N;i++) cf[i] = (float)i*1.5f - 3.25f; //  -3.25,-1.75,...,8.75
        //  vfcvt.x.f.v  (f32->i32, RNE)
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfcvt.x.f.v v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(cf),[d]"r"(vi):"t0","memory");
        for(i=0;i<N;i++){ float x=cf[i]; int32_t r; asm volatile("fcvt.w.s %0,%1":"=r"(r):"f"(x)); ri[i]=r; }
        { caseno++; int bad=0,j; for(j=0;j<N;j++) if(vi[j]!=ri[j])bad++; sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfcvt.x.f.v e32"); if(bad){for(j=0;j<N;j++)if(vi[j]!=ri[j]){sio_puts("\n  i=");put_dec(j);sio_puts(" got=");put_hex(vi[j]);sio_puts(" exp=");put_hex(ri[j]);}fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
        //  vfcvt.rtz.x.f.v (f32->i32, truncate)
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfcvt.rtz.x.f.v v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(cf),[d]"r"(vi):"t0","memory");
        for(i=0;i<N;i++) ri[i]=(int32_t)cf[i];  //  C cast = truncate
        { caseno++; int bad=0,j; for(j=0;j<N;j++) if(vi[j]!=ri[j])bad++; sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfcvt.rtz.x.f.v e32"); if(bad){fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
        //  vfcvt.f.x.v (i32->f32)
        for(i=0;i<N;i++) vi[i]=i*7 - 11;
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfcvt.f.x.v v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(vi),[d]"r"(fd):"t0","memory");
        for(i=0;i<N;i++){ int32_t x=vi[i]; asm volatile("fcvt.s.w %0,%1":"=f"(fg[i]):"r"(x)); } chkf("vfcvt.f.x.v e32");
        //  vfcvt.f.xu.v (u32->f32)
        for(i=0;i<N;i++) vu[i]=(uint32_t)(i*0x20000001u);
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfcvt.f.xu.v v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(vu),[d]"r"(fd):"t0","memory");
        for(i=0;i<N;i++){ uint32_t x=vu[i]; asm volatile("fcvt.s.wu %0,%1":"=f"(fg[i]):"r"(x)); } chkf("vfcvt.f.xu.v e32");
        (void)ru;
    }
    //  ==== vfmv.s.f: vd[0] = scalar, rest undisturbed ====
    {
        float s=42.5f; for(i=0;i<N;i++) fd[i]=(float)(100+i);
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v10,(%[d])\n vfmv.s.f v10,%[s]\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[s]"f"(s),[d]"r"(fd):"t0","memory");
        fg[0]=s; for(i=1;i<N;i++) fg[i]=(float)(100+i); chkf("vfmv.s.f e32");
    }

    //  ==== widening conversions (SEW=32 src -> 2*SEW dst) ====
    {
        static float    ws[N];   static double wd64[N], wg64[N];
        static int32_t  wi[N];   static int64_t wl[N], wlg[N];
        for(i=0;i<N;i++){ ws[i]=(float)i*2.5f-7.0f; wi[i]=i*123456-300000; }
        //  vfwcvt.f.f.v : f32 -> f64
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfwcvt.f.f.v v10,v8\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(ws),[d]"r"(wd64):"t0","memory");
        for(i=0;i<N;i++){ float x=ws[i]; asm volatile("fcvt.d.s %0,%1":"=f"(wg64[i]):"f"(x)); }
        { caseno++; int bad=0,j; for(j=0;j<N;j++){uint64_t g=*(uint64_t*)&wd64[j],r=*(uint64_t*)&wg64[j]; if(g!=r)bad++;} sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfwcvt.f.f.v"); if(bad){fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
        //  vfwcvt.x.f.v : f32 -> i64
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfwcvt.x.f.v v10,v8\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(ws),[d]"r"(wl):"t0","memory");
        for(i=0;i<N;i++){ float x=ws[i]; int64_t r; asm volatile("fcvt.l.s %0,%1":"=r"(r):"f"(x)); wlg[i]=r; }
        { caseno++; int bad=0,j; for(j=0;j<N;j++) if(wl[j]!=wlg[j])bad++; sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfwcvt.x.f.v"); if(bad){fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
        //  vfwcvt.f.x.v : i32 -> f64
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfwcvt.f.x.v v10,v8\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(wi),[d]"r"(wd64):"t0","memory");
        for(i=0;i<N;i++){ int32_t x=wi[i]; asm volatile("fcvt.d.w %0,%1":"=f"(wg64[i]):"r"(x)); }
        { caseno++; int bad=0,j; for(j=0;j<N;j++){uint64_t g=*(uint64_t*)&wd64[j],r=*(uint64_t*)&wg64[j]; if(g!=r)bad++;} sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfwcvt.f.x.v"); if(bad){fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
    }
    //  ==== narrowing conversions (2*SEW src -> SEW=32 dst) ====
    {
        static double ns[N]; static float nd[N], ng[N];
        static int64_t nl[N]; static int32_t ni[N], nig[N];
        for(i=0;i<N;i++){ ns[i]=(double)i*1.3-4.0; nl[i]=(int64_t)i*0x100000001LL-7; }
        //  vfncvt.f.f.w : f64 -> f32
        asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vfncvt.f.f.w v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(ns),[d]"r"(nd):"t0","memory");
        for(i=0;i<N;i++){ double x=ns[i]; asm volatile("fcvt.s.d %0,%1":"=f"(ng[i]):"f"(x)); }
        { caseno++; int bad=0,j; for(j=0;j<N;j++){uint32_t g=*(uint32_t*)&nd[j],r=*(uint32_t*)&ng[j]; if(g!=r)bad++;} sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfncvt.f.f.w"); if(bad){fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
        //  vfncvt.x.f.w : f64 -> i32
        asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vfncvt.x.f.w v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(ns),[d]"r"(ni):"t0","memory");
        for(i=0;i<N;i++){ double x=ns[i]; int32_t r; asm volatile("fcvt.w.d %0,%1":"=r"(r):"f"(x)); nig[i]=r; }
        { caseno++; int bad=0,j; for(j=0;j<N;j++) if(ni[j]!=nig[j])bad++; sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfncvt.x.f.w"); if(bad){fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
        //  vfncvt.f.x.w : i64 -> f32
        asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v8,(%[a])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vfncvt.f.x.w v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(nl),[d]"r"(nd):"t0","memory");
        for(i=0;i<N;i++){ int64_t x=nl[i]; asm volatile("fcvt.s.l %0,%1":"=f"(ng[i]):"r"(x)); }
        { caseno++; int bad=0,j; for(j=0;j<N;j++){uint32_t g=*(uint32_t*)&nd[j],r=*(uint32_t*)&ng[j]; if(g!=r)bad++;} sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfncvt.f.x.w"); if(bad){fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
    }

    //  ==== vfmv.f.s: f[rd] = vs2[0] ====
    {
        float got; for(i=0;i<N;i++) fa[i]=(float)(i+1)*3.0f;    //  v8[0] = 3.0
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfmv.f.s %[g],v8\n"
            :[g]"=f"(got):[n]"r"(N),[a]"r"(fa):"t0","memory");
        caseno++; { uint32_t gg=*(uint32_t*)&got, rr=*(uint32_t*)&fa[0];
          if(gg!=rr){sio_puts("[FAIL] vfmv.f.s e32\n  got=");put_hex(gg);sio_puts(" exp=");put_hex(rr);sio_putc('\n');fails++;if(!ff)ff=caseno;}
          else sio_puts("[ ok ] vfmv.f.s e32\n"); }
    }
    //  ==== vfcvt.xu.f.v (f32 -> u32, unsigned) ====
    {
        static float cf[N]; static uint32_t vu[N], ru[N];
        for(i=0;i<N;i++) cf[i]=(float)i*1.5f+0.7f;  //  non-negative
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfcvt.xu.f.v v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(cf),[d]"r"(vu):"t0","memory");
        for(i=0;i<N;i++){ float x=cf[i]; uint32_t r; asm volatile("fcvt.wu.s %0,%1":"=r"(r):"f"(x)); ru[i]=r; }
        caseno++; { int bad=0,j; for(j=0;j<N;j++) if(vu[j]!=ru[j])bad++;
          sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfcvt.xu.f.v e32\n"); if(bad){fails++;if(!ff)ff=caseno;} }
    }

    //  ==== FP reductions (vd[0] = vs1[0] OP vs2[*]) ====
    {
        static float seedv[N], rel[N];
        for(i=0;i<N;i++) rel[i]=(float)(i+1)*0.5f - 1.25f;
        //  vfredosum.vs (ordered sum): result = ((seed+a0)+a1)+...
        seedv[0]=2.5f;
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[s])\n vle32.v v9,(%[a])\n"
            "vfredosum.vs v10,v9,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[s]"r"(seedv),[a]"r"(rel),[d]"r"(fd):"t0","memory");
        { float acc=2.5f; for(i=0;i<N;i++){float t=rel[i],r; asm volatile("fadd.s %0,%1,%2":"=f"(r):"f"(acc),"f"(t)); acc=r;}
          caseno++; uint32_t g=*(uint32_t*)&fd[0],rr=*(uint32_t*)&acc;
          if(g!=rr){sio_puts("[FAIL] vfredosum.vs e32\n  got=");put_hex(g);sio_puts(" exp=");put_hex(rr);sio_putc('\n');fails++;if(!ff)ff=caseno;} else sio_puts("[ ok ] vfredosum.vs e32\n"); }
        //  vfredmax.vs / vfredmin.vs
        seedv[0]=0.0f;
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[s])\n vle32.v v9,(%[a])\n"
            "vfredmax.vs v10,v9,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[s]"r"(seedv),[a]"r"(rel),[d]"r"(fd):"t0","memory");
        { float acc=0.0f; for(i=0;i<N;i++){float t=rel[i],r; asm volatile("fmax.s %0,%1,%2":"=f"(r):"f"(acc),"f"(t)); acc=r;}
          caseno++; uint32_t g=*(uint32_t*)&fd[0],rr=*(uint32_t*)&acc;
          if(g!=rr){sio_puts("[FAIL] vfredmax.vs e32\n");fails++;if(!ff)ff=caseno;} else sio_puts("[ ok ] vfredmax.vs e32\n"); }
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[s])\n vle32.v v9,(%[a])\n"
            "vfredmin.vs v10,v9,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[s]"r"(seedv),[a]"r"(rel),[d]"r"(fd):"t0","memory");
        { float acc=0.0f; for(i=0;i<N;i++){float t=rel[i],r; asm volatile("fmin.s %0,%1,%2":"=f"(r):"f"(acc),"f"(t)); acc=r;}
          caseno++; uint32_t g=*(uint32_t*)&fd[0],rr=*(uint32_t*)&acc;
          if(g!=rr){sio_puts("[FAIL] vfredmin.vs e32\n");fails++;if(!ff)ff=caseno;} else sio_puts("[ ok ] vfredmin.vs e32\n"); }
    }

    //  ==== vfslide1up/down.vf ====
    {
        static float sv[N]; float s=99.5f;
        for(i=0;i<N;i++) sv[i]=(float)(i+1)*1.25f;
        //  vfslide1up: vd[0]=s, vd[i]=vs2[i-1]
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfslide1up.vf v10,v8,%[s]\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(sv),[s]"f"(s),[d]"r"(fd):"t0","memory");
        fg[0]=s; for(i=1;i<N;i++) fg[i]=sv[i-1];    chkf("vfslide1up.vf e32");
        //  vfslide1down: vd[i]=vs2[i+1], vd[vl-1]=s
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfslide1down.vf v10,v8,%[s]\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(sv),[s]"f"(s),[d]"r"(fd):"t0","memory");
        for(i=0;i<N-1;i++) fg[i]=sv[i+1]; fg[N-1]=s;    chkf("vfslide1down.vf e32");
    }

    //  ==== widening FP arithmetic (e32 src -> e64 dst) ====
    //  Golden = widen-to-double (exact) then the SAME scalar D op the vfpu
    //  dispatches to, so this validates the widen+sequence path bit-exactly.
    {
        for(i=0;i<N;i++){ fa[i]=1.5f*(i+1)+0.3f; fb[i]=0.75f*(i+2)-2.0f; }
        //  vfwadd.vv : f64 = (double)vs2 + (double)vs1
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
            "vfwadd.vv v10,v8,v9\n vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(dd):"t0","memory");
        for(i=0;i<N;i++){ double x=fa[i],y=fb[i]; asm volatile("fadd.d %0,%1,%2":"=f"(dg[i]):"f"(x),"f"(y)); } chkd("vfwadd.vv e32->e64");
        //  vfwsub.vv : vs2 - vs1
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
            "vfwsub.vv v10,v8,v9\n vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(dd):"t0","memory");
        for(i=0;i<N;i++){ double x=fa[i],y=fb[i]; asm volatile("fsub.d %0,%1,%2":"=f"(dg[i]):"f"(x),"f"(y)); } chkd("vfwsub.vv e32->e64");
        //  vfwmul.vv
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
            "vfwmul.vv v10,v8,v9\n vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(dd):"t0","memory");
        for(i=0;i<N;i++){ double x=fa[i],y=fb[i]; asm volatile("fmul.d %0,%1,%2":"=f"(dg[i]):"f"(x),"f"(y)); } chkd("vfwmul.vv e32->e64");
        //  vfwadd.vf : scalar widened
        { float s=2.5f;
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfwadd.vf v10,v8,%[s]\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(fa),[s]"f"(s),[d]"r"(dd):"t0","memory");
        for(i=0;i<N;i++){ double x=fa[i],y=s; asm volatile("fadd.d %0,%1,%2":"=f"(dg[i]):"f"(x),"f"(y)); } chkd("vfwadd.vf e32->e64"); }
        //  vfwadd.wv : vs2 is already f64 (wide), vs1 f32 widened
        asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v12,(%[w])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfwadd.wv v10,v12,v8\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[w]"r"(da),[a]"r"(fa),[d]"r"(dd):"t0","memory");
        for(i=0;i<N;i++){ double x=da[i],y=fa[i]; asm volatile("fadd.d %0,%1,%2":"=f"(dg[i]):"f"(x),"f"(y)); } chkd("vfwadd.wv e64+e32");
        //  vfwmacc.vv : acc(f64) += vs1(f32)*vs2(f32)
        for(i=0;i<N;i++) dd[i]=0.5*i-1.0;
        asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v10,(%[c])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n vfwmacc.vv v10,v8,v9\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[c]"r"(dd),[a]"r"(fa),[b]"r"(fb),[d]"r"(dd):"t0","memory");
        for(i=0;i<N;i++){ double x=fa[i],y=fb[i],c=0.5*i-1.0; asm volatile("fmadd.d %0,%1,%2,%3":"=f"(dg[i]):"f"(x),"f"(y),"f"(c)); } chkd("vfwmacc.vv e32->e64");
        //  vfwnmsac.vv : acc = -(vs1*vs2) + acc
        for(i=0;i<N;i++) dd[i]=0.5*i-1.0;
        asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v10,(%[c])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n vfwnmsac.vv v10,v8,v9\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[c]"r"(dd),[a]"r"(fa),[b]"r"(fb),[d]"r"(dd):"t0","memory");
        for(i=0;i<N;i++){ double x=fa[i],y=fb[i],c=0.5*i-1.0; asm volatile("fnmsub.d %0,%1,%2,%3":"=f"(dg[i]):"f"(x),"f"(y),"f"(c)); } chkd("vfwnmsac.vv e32->e64");
        //  vfwredosum.vs : vd[0] = vs1[0](f64 seed) + sum of widen(vs2[i] f32)
        { static double wseed[N]; wseed[0]=3.0;
        asm volatile("vsetvli t0,%[n],e64,m2,tu,mu\n vle64.v v12,(%[s])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v9,(%[a])\n vfwredosum.vs v10,v9,v12\n"
            "vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
            ::[n]"r"(N),[s]"r"(wseed),[a]"r"(fa),[d]"r"(dd):"t0","memory");
        { double acc=3.0; for(i=0;i<N;i++){double t=fa[i],r; asm volatile("fadd.d %0,%1,%2":"=f"(r):"f"(acc),"f"(t)); acc=r;}
          caseno++; uint64_t g=*(uint64_t*)&dd[0], rr=*(uint64_t*)&acc;
          if(g!=rr){sio_puts("[FAIL] vfwredosum.vs\n  got=");put_hex((uint32_t)(g>>32));put_hex((uint32_t)g);sio_puts(" exp=");put_hex((uint32_t)(rr>>32));put_hex((uint32_t)rr);sio_putc('\n');fails++;if(!ff)ff=caseno;}
          else sio_puts("[ ok ] vfwredosum.vs e32->e64\n"); } }

        //  ---- special values: sNaN must raise NV through the widen, result
        //  must match widen-then-fadd.d (qNaN/inf canonicalisation) ----
        {
            union { uint32_t u; float f; } sn = { 0x7F800001u };    //  signaling NaN
            union { uint32_t u; float f; } inf = { 0x7F800000u };   //  +inf
            static float  sa[N]; static double sr[N], sgld[N];
            uint32_t ff_v=0;
            for(i=0;i<N;i++) sa[i]=(float)(i+1);
            sa[0]=sn.f; sa[1]=inf.f; sa[2]=0.0f;
            asm volatile("csrw fflags, x0\n"
                "vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n"
                "vfwadd.vv v10,v8,v8\n vsetvli t0,%[n],e64,m2,tu,mu\n vse64.v v10,(%[d])\n"
                "csrr %[f], fflags\n"
                :[f]"=r"(ff_v):[n]"r"(N),[a]"r"(sa),[d]"r"(sr):"t0","memory");
            for(i=0;i<N;i++){ double x=sa[i]; asm volatile("fadd.d %0,%1,%1":"=f"(sgld[i]):"f"(x)); }
            { caseno++; int bad=0,j; for(j=0;j<N;j++){uint64_t g=*(uint64_t*)&sr[j],r=*(uint64_t*)&sgld[j]; if(g!=r)bad++;}
              if((ff_v & 0x10u)==0) bad++;      //  NV (sNaN input) must be set
              sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfwadd.vv specials+NV");
              if(bad){sio_puts("\n  fflags=");put_hex(ff_v);for(j=0;j<N;j++){uint64_t g=*(uint64_t*)&sr[j],r=*(uint64_t*)&sgld[j];if(g!=r){sio_puts("\n  i=");put_dec(j);sio_puts(" got=");put_hex((uint32_t)(g>>32));put_hex((uint32_t)g);sio_puts(" exp=");put_hex((uint32_t)(r>>32));put_hex((uint32_t)r);}}fails++;if(!ff)ff=caseno;}
              sio_putc('\n'); }
        }
    }

    //  ==== parallel-path coverage: max / class / merge / masked+tail ====
    {
        static uint8_t m1b[1] = {0x5A}; //  mask: elements 1,3,4,6 active
        static uint32_t clr[N], clg[N];
        float s=7.0f;
        for(i=0;i<N;i++){ fa[i]=1.5f*(i+1)-2.0f; fb[i]=0.25f*(i+2)-1.0f; }
        //  vfmax.vv
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v9,(%[b])\n"
            "vfmax.vv v10,v8,v9\n vse32.v v10,(%[d])\n"::[n]"r"(N),[a]"r"(fa),[b]"r"(fb),[d]"r"(fd):"t0","memory");
        for(i=0;i<N;i++){ float a=fa[i],b=fb[i]; asm volatile("fmax.s %0,%1,%2":"=f"(fg[i]):"f"(a),"f"(b)); } chkf("vfmax.vv e32");
        //  vfclass.v (result is the 10-bit class as an integer element)
        asm volatile("vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfclass.v v10,v8\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[a]"r"(fa),[d]"r"(clr):"t0","memory");
        for(i=0;i<N;i++){ float x=fa[i]; uint32_t r; asm volatile("fclass.s %0,%1":"=r"(r):"f"(x)); clg[i]=r; }
        { caseno++; int bad=0,j; for(j=0;j<N;j++) if(clr[j]!=clg[j])bad++;
          sio_puts(bad?"[FAIL] ":"[ ok ] ");sio_puts("vfclass.v e32");
          if(bad){for(j=0;j<N;j++)if(clr[j]!=clg[j]){sio_puts("\n  i=");put_dec(j);sio_puts(" got=");put_hex(clr[j]);sio_puts(" exp=");put_hex(clg[j]);}fails++;if(!ff)ff=caseno;} sio_putc('\n'); }
        //  vfmerge.vfm: vd[i] = v0[i] ? scalar : vs2[i]
        asm volatile("vsetivli t0,1,e8,m1,tu,mu\n vle8.v v0,(%[m])\n"
            "vsetvli t0,%[n],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vfmerge.vfm v10,v8,%[s],v0\n vse32.v v10,(%[d])\n"
            ::[n]"r"(N),[m]"r"(m1b),[a]"r"(fa),[s]"f"(s),[d]"r"(fd):"t0","memory");
        for(i=0;i<N;i++) fg[i] = ((m1b[0]>>i)&1) ? s : fa[i]; chkf("vfmerge.vfm e32");
        //  masked vfadd.vf (tu,mu): masked-off + tail (vl=6) keep old vd
        for(i=0;i<N;i++) fd[i]=(float)(200+i);  //  sentinel
        asm volatile("vsetivli t0,1,e8,m1,tu,mu\n vle8.v v0,(%[m])\n"
            "vsetvli t0,%[vl],e32,m1,tu,mu\n vle32.v v8,(%[a])\n vle32.v v10,(%[d])\n"
            "vfadd.vf v10,v8,%[s],v0.t\n vse32.v v10,(%[d])\n"
            ::[m]"r"(m1b),[vl]"r"(6),[a]"r"(fa),[s]"f"(s),[d]"r"(fd):"t0","memory");
        for(i=0;i<N;i++) fg[i] = (i<6 && ((m1b[0]>>i)&1)) ? (fa[i]+s) : (float)(200+i);
        chkf("vfadd.vf masked+tail e32");
    }

    if(fails){ sio_puts("[VFP] FAILURES: "); put_dec(fails); sio_putc('\n'); }
    else       sio_puts("[VFP] ALL PASS\n");
    sio_putc(4);
    return ff;
}
