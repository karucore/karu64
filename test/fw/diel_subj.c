//  diel_subj.c -- empirical Zkt/Zvkt data-independent-latency probe for karu64.
//  For every instruction under test, a fixed block (rdcycle; N copies; rdcycle)
//  is timed for several operand-value classes.  All classes must take exactly
//  the same number of cycles.  Everything except the operand VALUES is held
//  constant (same registers, vl, vtype, mask polarity, immediates).
//  Runs in M-mode on the HTIF testbench.  Exit code = number of failing tests.

#include <stdint.h>
#include "sio_generic.h"

static void put_u64(uint64_t x){ char b[24]; unsigned n=0; do{ b[n++]=(char)('0'+x%10); x/=10; }while(x); while(n) sio_putc(b[--n]); }

static int n_tests = 0, n_fail = 0, raw_dump = 0;

/* ------------------------------------------------------------------ scalar */

typedef uint64_t (*sfn)(uint64_t a, uint64_t b);

static const uint64_t scls[][2] = {
    {0, 0}, {1, 1}, {~0ull, ~0ull}, {1ull<<63, 1ull<<63},
    {0x123456789abcdef0ull, 0xfedcba9876543210ull},
    {0, 0x9e3779b97f4a7c15ull}, {0x9e3779b97f4a7c15ull, 0},
    {1, 0xc2b2ae3d27d4eb4full}, {0xc2b2ae3d27d4eb4full, ~0ull},
    {0xdeadbeefcafef00dull, 63}, {0xdeadbeefcafef00dull, 1},
    {0x00000000ffffffffull, 0xffffffff00000000ull},
};
#define NSCLS (sizeof scls / sizeof scls[0])

static void run_scalar(const char *name, sfn f)
{
    uint64_t c[NSCLS]; int fail = 0; unsigned i, pass;
    uint64_t raw[3][NSCLS];
    for (pass = 0; pass < 3; pass++)
        for (i = 0; i < NSCLS; i++) raw[pass][i] = f(scls[i][0], scls[i][1]);
    /* per class: take the minimum of three consecutive calls (warm I-cache) */
    for (i = 0; i < NSCLS; i++) { uint64_t m = raw[0][i]; if (raw[1][i] < m) m = raw[1][i]; if (raw[2][i] < m) m = raw[2][i]; c[i] = m; }
    for (i = 1; i < NSCLS; i++) if (c[i] != c[0]) fail = 1;
    if (raw_dump) for (pass = 0; pass < 3; pass++) { sio_puts("   raw pass "); put_u64(pass); sio_putc(':'); for (i = 0; i < NSCLS; i++) { sio_putc(' '); put_u64(raw[pass][i]); } sio_putc('\n'); }
    n_tests++; if (fail) n_fail++;
    sio_puts(fail ? "[FAIL] " : "[ok]   "); sio_puts(name); sio_puts(":");
    for (i = 0; i < NSCLS; i++) { sio_putc(' '); put_u64(c[i]); }
    sio_putc('\n');
}

#define S2(nm, insn) \
static uint64_t s_##nm(uint64_t a, uint64_t b){ uint64_t c0,c1,r; \
    asm volatile("rdcycle %[c0]\n.rept 16\n" insn " %[r],%[a],%[b]\n.endr\nrdcycle %[c1]\n" \
        : [c0]"=&r"(c0),[c1]"=&r"(c1),[r]"=&r"(r) : [a]"r"(a),[b]"r"(b)); return c1-c0; }
#define S1(nm, insn) \
static uint64_t s_##nm(uint64_t a, uint64_t b){ uint64_t c0,c1,r; (void)b; \
    asm volatile("rdcycle %[c0]\n.rept 16\n" insn "\n.endr\nrdcycle %[c1]\n" \
        : [c0]"=&r"(c0),[c1]"=&r"(c1),[r]"=&r"(r) : [a]"r"(a)); return c1-c0; }

S2(add,"add") S2(sub,"sub") S2(sll,"sll") S2(srl,"srl") S2(sra,"sra")
S2(slt,"slt") S2(sltu,"sltu") S2(xor,"xor") S2(or,"or") S2(and,"and")
S2(addw,"addw") S2(subw,"subw") S2(sllw,"sllw") S2(srlw,"srlw") S2(sraw,"sraw")
S2(mul,"mul") S2(mulh,"mulh") S2(mulhsu,"mulhsu") S2(mulhu,"mulhu") S2(mulw,"mulw")
S2(andn,"andn") S2(orn,"orn") S2(xnor,"xnor")
S2(rol,"rol") S2(ror,"ror") S2(rolw,"rolw") S2(rorw,"rorw")
S2(czero_eqz,"czero.eqz") S2(czero_nez,"czero.nez")
S1(addi,"addi %[r],%[a],-123") S1(slti,"slti %[r],%[a],5") S1(sltiu,"sltiu %[r],%[a],5")
S1(xori,"xori %[r],%[a],0x5a5") S1(slli,"slli %[r],%[a],17") S1(srli,"srli %[r],%[a],3")
S1(srai,"srai %[r],%[a],40") S1(addiw,"addiw %[r],%[a],77") S1(slliw,"slliw %[r],%[a],9")
S1(srliw,"srliw %[r],%[a],9") S1(sraiw,"sraiw %[r],%[a],9")
S1(rori,"rori %[r],%[a],13") S1(roriw,"roriw %[r],%[a],13") S1(rev8,"rev8 %[r],%[a]")
S1(zext_h,"zext.h %[r],%[a]")

/* Zcb / RVC forms need x8..x15 operands; pin to a0..a2. */
static uint64_t s_c_mul(uint64_t a, uint64_t b){ uint64_t c0,c1;
    register uint64_t ra asm("a0") = a; register uint64_t rb asm("a1") = b; register uint64_t rc asm("a2") = a;
    asm volatile("rdcycle %[c0]\n.rept 16\nc.mv a0,a2\nc.mul a0,a1\n.endr\nrdcycle %[c1]\n"
        : [c0]"=&r"(c0),[c1]"=&r"(c1),"+r"(ra) : "r"(rb),"r"(rc)); return c1-c0; }
static uint64_t s_c_not(uint64_t a, uint64_t b){ uint64_t c0,c1; (void)b;
    register uint64_t ra asm("a0") = a;
    asm volatile("rdcycle %[c0]\n.rept 16\nc.not a0\n.endr\nrdcycle %[c1]\n"
        : [c0]"=&r"(c0),[c1]"=&r"(c1),"+r"(ra)); return c1-c0; }
static uint64_t s_c_zext_b(uint64_t a, uint64_t b){ uint64_t c0,c1; (void)b;
    register uint64_t ra asm("a0") = a; register uint64_t rc asm("a2") = a;
    asm volatile("rdcycle %[c0]\n.rept 16\nc.mv a0,a2\nc.zext.b a0\n.endr\nrdcycle %[c1]\n"
        : [c0]"=&r"(c0),[c1]"=&r"(c1),"+r"(ra) : "r"(rc)); return c1-c0; }
static uint64_t s_c_ops(uint64_t a, uint64_t b){ uint64_t c0,c1;
    register uint64_t ra asm("a0") = a; register uint64_t rb asm("a1") = b; register uint64_t rc asm("a2") = a;
    asm volatile("rdcycle %[c0]\n.rept 8\n"
        "c.mv a0,a2\nc.add a0,a1\nc.sub a0,a1\nc.xor a0,a1\nc.or a0,a1\nc.and a0,a1\n"
        "c.addw a0,a1\nc.subw a0,a1\nc.srli a0,7\nc.srai a0,3\nc.andi a0,-5\nc.slli a0,11\nc.addi a0,17\nc.addiw a0,-9\n"
        ".endr\nrdcycle %[c1]\n"
        : [c0]"=&r"(c0),[c1]"=&r"(c1),"+r"(ra) : "r"(rb),"r"(rc)); return c1-c0; }

/* ------------------------------------------------------------------ vector */

typedef struct { const char *nm; const uint64_t *w; } pat_t;
static uint64_t P_Z[32], P_O[32], P_F[32], P_M[32], P_R1[32], P_R2[32], P_A[32], P_N[32];
static void init_pats(void){
    uint64_t s = 0x9e3779b97f4a7c15ull;
    for (int i = 0; i < 32; i++) {
        P_Z[i]=0; P_O[i]=1; P_F[i]=~0ull; P_M[i]=1ull<<63; P_A[i]=(i&1)?0xaaaaaaaaaaaaaaaaull:0x5555555555555555ull;
        s ^= s<<13; s ^= s>>7; s ^= s<<17; P_R1[i]=s;
        s ^= s<<13; s ^= s>>7; s ^= s<<17; P_R2[i]=s;
    }
    /* FP special values (for vfslide1*.vf scalar and as generic bit soup) */
    static const uint64_t fpv[8] = {0x7ff8000000000000ull, 1ull, 0x7ff0000000000000ull, 0xfff0000000000000ull,
                                    0x3ff0000000000000ull, 0x8000000000000000ull, 0x0008000000000000ull, 0x7ff4000000000000ull};
    for (int i = 0; i < 32; i++) P_N[i] = fpv[i & 7];
}
/* (v0 group / mask / carry, vs A group, vs B / vd group, scalar x, fp scalar bits) */
typedef struct { const uint64_t *pm, *pa, *pb; } vcls_t;
static vcls_t vcls[10];
#define NVCLS 10
static void init_vcls(void){
    vcls_t t[NVCLS] = { {P_Z,P_Z,P_Z}, {P_F,P_F,P_F}, {P_M,P_M,P_M}, {P_O,P_O,P_O}, {P_R1,P_R1,P_R2},
                        {P_Z,P_R1,P_F}, {P_R2,P_Z,P_Z}, {P_A,P_R2,P_R1}, {P_N,P_N,P_N}, {P_R1,P_N,P_R2} };
    for (int i = 0; i < NVCLS; i++) vcls[i] = t[i];
}

typedef uint64_t (*vfn)(const uint64_t *pm, const uint64_t *pa, const uint64_t *pb, uint64_t x, uint64_t fxb, uint64_t vl);

#define VCLOB "memory","t0","v0","v1","v2","v3","v4","v5","v6","v7","v8","v9","v10","v11","v12","v13","v14","v15", \
    "v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31","fa0"
/* prologue: fill v0..v7 <- pm, v8..v15 <- pb, v16..v23 <- pa, v24..v31 <- pb (32 x 64-bit words each) */
#define VPRO \
    "li t0,32\nvsetvli t0,t0,e64,m8,tu,mu\n" \
    "vle64.v v0,(%[pm])\nvle64.v v8,(%[pb])\nvle64.v v16,(%[pa])\nvle64.v v24,(%[pb])\n" \
    "fmv.d.x fa0,%[fxb]\n"
#define VT(nm, vset, body) \
static uint64_t v_##nm(const uint64_t *pm,const uint64_t *pa,const uint64_t *pb,uint64_t x,uint64_t fxb,uint64_t vl){ \
    uint64_t c0,c1; \
    asm volatile(VPRO vset "\nrdcycle %[c0]\n.rept 4\n" body "\n.endr\nrdcycle %[c1]\n" \
        : [c0]"=&r"(c0),[c1]"=&r"(c1) : [pm]"r"(pm),[pa]"r"(pa),[pb]"r"(pb),[x]"r"(x),[fxb]"r"(fxb),[vl]"r"(vl) : VCLOB); \
    return c1-c0; }

#define E64M2 "vsetvli t0,%[vl],e64,m2,tu,mu"
#define E64M2A "vsetvli t0,%[vl],e64,m2,ta,ma"
#define E8M2  "vsetvli t0,%[vl],e8,m2,tu,mu"
#define E32M2 "vsetvli t0,%[vl],e32,m2,tu,mu"
#define E16M1 "vsetvli t0,%[vl],e16,m1,tu,mu"
#define E32M1 "vsetvli t0,%[vl],e32,m1,tu,mu"
#define E64M1 "vsetvli t0,%[vl],e64,m1,tu,mu"
#define E64M8 "vsetvli t0,%[vl],e64,m8,tu,mu"

/* add/sub/logic/shift */
VT(vadd_vv, E64M2, "vadd.vv v8,v16,v10")     VT(vadd_vv_e8, E8M2, "vadd.vv v8,v16,v10")
VT(vsub_vv, E64M2, "vsub.vv v8,v16,v10")     VT(vrsub_vx, E64M2, "vrsub.vx v8,v16,%[x]")
VT(vadd_vi, E64M2, "vadd.vi v8,v16,-7")      VT(vand_vv, E64M2, "vand.vv v8,v16,v10")
VT(vor_vx, E64M2, "vor.vx v8,v16,%[x]")      VT(vxor_vi, E64M2, "vxor.vi v8,v16,9")
VT(vsll_vv, E64M2, "vsll.vv v8,v16,v10")     VT(vsrl_vv, E64M2, "vsrl.vv v8,v16,v10")
VT(vsra_vv, E64M2, "vsra.vv v8,v16,v10")     VT(vsll_vx, E64M2, "vsll.vx v8,v16,%[x]")
VT(vsrl_vi, E64M2, "vsrl.vi v8,v16,5")       VT(vsra_vv_e8, E8M2, "vsra.vv v8,v16,v10")
/* widening add/sub */
VT(vwadd_vv, E32M2, "vwadd.vv v8,v16,v18")   VT(vwaddu_vx, E32M2, "vwaddu.vx v8,v16,%[x]")
VT(vwsub_wv, E32M2, "vwsub.wv v8,v24,v18")   VT(vwsubu_wx, E32M2, "vwsubu.wx v8,v24,%[x]")
/* carry */
VT(vadc_vvm, E64M2, "vadc.vvm v8,v16,v10,v0") VT(vadc_vxm, E64M2, "vadc.vxm v8,v16,%[x],v0")
VT(vadc_vim, E64M2, "vadc.vim v8,v16,3,v0")   VT(vsbc_vvm, E64M2, "vsbc.vvm v8,v16,v10,v0")
VT(vmadc_vvm, E64M2, "vmadc.vvm v8,v16,v10,v0") VT(vmadc_vv, E64M2, "vmadc.vv v8,v16,v10")
VT(vmadc_vxm, E64M2, "vmadc.vxm v8,v16,%[x],v0") VT(vmsbc_vvm, E64M2, "vmsbc.vvm v8,v16,v10,v0")
VT(vmsbc_vx, E64M2, "vmsbc.vx v8,v16,%[x]")
/* compare */
VT(vmseq_vv, E64M2, "vmseq.vv v8,v16,v10")   VT(vmsne_vx, E64M2, "vmsne.vx v8,v16,%[x]")
VT(vmslt_vv, E64M2, "vmslt.vv v8,v16,v10")   VT(vmsltu_vx, E64M2, "vmsltu.vx v8,v16,%[x]")
VT(vmsle_vi, E64M2, "vmsle.vi v8,v16,-3")    VT(vmsleu_vv, E64M2, "vmsleu.vv v8,v16,v10")
VT(vmsgt_vx, E64M2, "vmsgt.vx v8,v16,%[x]")  VT(vmsgtu_vi, E64M2, "vmsgtu.vi v8,v16,12")
VT(vmseq_vv_e8, E8M2, "vmseq.vv v8,v16,v10")
/* copy / merge */
VT(vmv_v_v, E64M2, "vmv.v.v v8,v16")         VT(vmv_v_x, E64M2, "vmv.v.x v8,%[x]")
VT(vmv_v_i, E64M2, "vmv.v.i v8,-5")          VT(vmv_s_x, E64M1, "vmv.s.x v8,%[x]")
VT(vmv_x_s, E64M1, "vmv.x.s t0,v16")         VT(vmv2r_v, E64M2, "vmv2r.v v8,v16")
VT(vmv1r_v, E64M2, "vmv1r.v v8,v16")         VT(vmv8r_v, E64M8, "vmv8r.v v8,v16")
VT(vmerge_vvm, E64M2, "vmerge.vvm v8,v16,v10,v0") VT(vmerge_vxm, E64M2, "vmerge.vxm v8,v16,%[x],v0")
VT(vmerge_vim, E64M2, "vmerge.vim v8,v16,4,v0")
/* extend */
VT(vsext_vf2, E64M2, "vsext.vf2 v8,v16")     VT(vzext_vf2, E64M2, "vzext.vf2 v8,v16")
VT(vsext_vf4, E64M2, "vsext.vf4 v8,v16")     VT(vzext_vf8, E64M2, "vzext.vf8 v8,v16")
/* mask logic */
VT(vmand_mm, E64M2, "vmand.mm v8,v16,v10")   VT(vmnand_mm, E64M2, "vmnand.mm v8,v16,v10")
VT(vmandn_mm, E64M2, "vmandn.mm v8,v16,v10") VT(vmxor_mm, E64M2, "vmxor.mm v8,v16,v10")
VT(vmor_mm, E64M2, "vmor.mm v8,v16,v10")     VT(vmnor_mm, E64M2, "vmnor.mm v8,v16,v10")
VT(vmorn_mm, E64M2, "vmorn.mm v8,v16,v10")   VT(vmxnor_mm, E64M2, "vmxnor.mm v8,v16,v10")
/* multiply / MAC */
VT(vmul_vv, E64M2, "vmul.vv v8,v16,v10")     VT(vmul_vv_e8, E8M2, "vmul.vv v8,v16,v10")
VT(vmul_vx, E64M2, "vmul.vx v8,v16,%[x]")    VT(vmulh_vv, E64M2, "vmulh.vv v8,v16,v10")
VT(vmulhu_vx, E64M2, "vmulhu.vx v8,v16,%[x]") VT(vmulhsu_vv, E64M2, "vmulhsu.vv v8,v16,v10")
VT(vmulh_vv_e32, E32M2, "vmulh.vv v8,v16,v10")
VT(vmacc_vv, E64M2, "vmacc.vv v8,v16,v10")   VT(vmacc_vx, E64M2, "vmacc.vx v8,%[x],v10")
VT(vmadd_vv, E64M2, "vmadd.vv v8,v16,v10")   VT(vnmsac_vv, E64M2, "vnmsac.vv v8,v16,v10")
VT(vnmsub_vx, E64M2, "vnmsub.vx v8,%[x],v10") VT(vmacc_vv_e8, E8M2, "vmacc.vv v8,v16,v10")
VT(vwmul_vv, E32M2, "vwmul.vv v8,v16,v18")   VT(vwmulu_vv, E32M2, "vwmulu.vv v8,v16,v18")
VT(vwmulsu_vx, E32M2, "vwmulsu.vx v8,v16,%[x]") VT(vwmulu_vx, E32M2, "vwmulu.vx v8,v16,%[x]")
VT(vwmacc_vv, E32M2, "vwmacc.vv v8,v16,v18") VT(vwmaccu_vx, E32M2, "vwmaccu.vx v8,%[x],v18")
VT(vwmaccsu_vv, E32M2, "vwmaccsu.vv v8,v16,v18") VT(vwmaccus_vx, E32M2, "vwmaccus.vx v8,%[x],v18")
VT(vwmul_vv_e8, E8M2, "vwmul.vv v8,v16,v18")
/* narrowing shift */
VT(vnsrl_wv, E32M2, "vnsrl.wv v8,v16,v20")   VT(vnsra_wx, E32M2, "vnsra.wx v8,v16,%[x]")
VT(vnsrl_wi, E32M2, "vnsrl.wi v8,v16,7")
/* permute: indices in v10/x are control (fixed per class? no: they vary with class, exempt) -- data vary */
VT(vrgather_vv, E64M2, "vrgather.vv v8,v16,v10")   VT(vrgather_vx, E64M2, "vrgather.vx v8,v16,%[x]")
VT(vrgather_vi, E64M2, "vrgather.vi v8,v16,3")     VT(vrgatherei16_vv, E64M2, "vrgatherei16.vv v8,v16,v10")
VT(vrgather_vv_e8, E8M2, "vrgather.vv v8,v16,v10")
VT(vslideup_vx, E64M2, "vslideup.vx v8,v16,%[x]")  VT(vslideup_vi, E64M2, "vslideup.vi v8,v16,2")
VT(vslidedown_vx, E64M2, "vslidedown.vx v8,v16,%[x]") VT(vslidedown_vi, E64M2, "vslidedown.vi v8,v16,3")
VT(vslide1up_vx, E64M2, "vslide1up.vx v8,v16,%[x]") VT(vslide1down_vx, E64M2, "vslide1down.vx v8,v16,%[x]")
VT(vslide1up_vx_e8, E8M2, "vslide1up.vx v8,v16,%[x]")
VT(vfslide1up_vf, E64M2, "vfslide1up.vf v8,v16,fa0") VT(vfslide1down_vf, E64M2, "vfslide1down.vf v8,v16,fa0")
VT(vfslide1up_vf_e32, E32M2, "vfslide1up.vf v8,v16,fa0")
/* Zvbb */
VT(vandn_vv, E64M2, "vandn.vv v8,v16,v10")   VT(vandn_vx, E64M2, "vandn.vx v8,v16,%[x]")
VT(vbrev_v, E64M2, "vbrev.v v8,v16")         VT(vbrev8_v, E64M2, "vbrev8.v v8,v16")
VT(vrev8_v, E64M2, "vrev8.v v8,v16")         VT(vclz_v, E64M2, "vclz.v v8,v16")
VT(vctz_v, E64M2, "vctz.v v8,v16")           VT(vcpop_v, E64M2, "vcpop.v v8,v16")
VT(vclz_v_e8, E8M2, "vclz.v v8,v16")
VT(vrol_vv, E64M2, "vrol.vv v8,v16,v10")     VT(vrol_vx, E64M2, "vrol.vx v8,v16,%[x]")
VT(vror_vv, E64M2, "vror.vv v8,v16,v10")     VT(vror_vx, E64M2, "vror.vx v8,v16,%[x]")
VT(vror_vi, E64M2, "vror.vi v8,v16,37")      VT(vwsll_vv, E32M2, "vwsll.vv v8,v16,v18")
VT(vwsll_vx, E32M2, "vwsll.vx v8,v16,%[x]")  VT(vwsll_vi, E32M2, "vwsll.vi v8,v16,9")
/* masked forms: mask register value is CONTROL here -> keep v0 fixed, vary everything else */
#define VTM(nm, vset, body) \
static uint64_t v_##nm(const uint64_t *pm,const uint64_t *pa,const uint64_t *pb,uint64_t x,uint64_t fxb,uint64_t vl){ \
    uint64_t c0,c1; (void)pm; \
    asm volatile(VPRO "li t0,32\nvsetvli t0,t0,e64,m8,tu,mu\nvle64.v v0,(%[pk])\n" vset "\nrdcycle %[c0]\n.rept 4\n" body "\n.endr\nrdcycle %[c1]\n" \
        : [c0]"=&r"(c0),[c1]"=&r"(c1) : [pm]"r"(pm),[pa]"r"(pa),[pb]"r"(pb),[x]"r"(x),[fxb]"r"(fxb),[vl]"r"(vl),[pk]"r"(P_A) : VCLOB); \
    return c1-c0; }
VTM(vmul_vv_m, E64M2, "vmul.vv v8,v16,v10,v0.t")      VTM(vmul_vv_m_ta, E64M2A, "vmul.vv v8,v16,v10,v0.t")
VTM(vmul_vv_e8_m, E8M2, "vmul.vv v8,v16,v10,v0.t")    VTM(vadd_vv_m, E64M2, "vadd.vv v8,v16,v10,v0.t")
VTM(vmacc_vv_m, E64M2, "vmacc.vv v8,v16,v10,v0.t")    VTM(vwmul_vv_m, E32M2, "vwmul.vv v8,v16,v18,v0.t")
VTM(vmseq_vv_m, E64M2, "vmseq.vv v8,v16,v10,v0.t")    VTM(vrgather_vv_m, E64M2, "vrgather.vv v8,v16,v10,v0.t")
VTM(vslide1up_vx_m, E64M2, "vslide1up.vx v8,v16,%[x],v0.t") VTM(vsext_vf2_m, E64M2, "vsext.vf2 v8,v16,v0.t")
VTM(vror_vv_m, E64M2, "vror.vv v8,v16,v10,v0.t")      VTM(vnsrl_wv_m, E32M2, "vnsrl.wv v8,v16,v20,v0.t")
VTM(vmerge_data_m, E64M2, "vmerge.vvm v8,v16,v10,v0")
/* crypto (opt-in leaves) */
#ifdef WITH_ZVK
VT(vaesem_vv, E32M1, "vaesem.vv v8,v16")     VT(vaesef_vs, E32M1, "vaesef.vs v8,v16")
VT(vaesdm_vv, E32M1, "vaesdm.vv v8,v16")     VT(vaesdf_vs, E32M1, "vaesdf.vs v8,v16")
VT(vaesz_vs, E32M1, "vaesz.vs v8,v16")       VT(vaeskf1_vi, E32M1, "vaeskf1.vi v8,v16,3")
VT(vaeskf2_vi, E32M1, "vaeskf2.vi v8,v16,4")
VT(vsha2ms_vv, E32M1, "vsha2ms.vv v8,v16,v24") VT(vsha2ch_vv, E32M1, "vsha2ch.vv v8,v16,v24")
VT(vsha2cl_vv, E32M1, "vsha2cl.vv v8,v16,v24") VT(vsha2ms_vv_e64, E64M1, "vsha2ms.vv v8,v16,v24")
VT(vsha2ch_vv_e64, E64M1, "vsha2ch.vv v8,v16,v24")
VT(vsm4r_vv, E32M1, "vsm4r.vv v8,v16")       VT(vsm4r_vs, E32M1, "vsm4r.vs v8,v16")
VT(vsm4k_vi, E32M1, "vsm4k.vi v8,v16,3")
VT(vsm3me_vv, E32M1, "vsm3me.vv v8,v16,v24") VT(vsm3c_vi, E32M1, "vsm3c.vi v8,v16,5")
VT(vghsh_vv, E32M1, "vghsh.vv v8,v16,v24")   VT(vgmul_vv, E32M1, "vgmul.vv v8,v16")
#endif
#ifdef WITH_KECCAK
VT(vkeccak_24, E64M8, ".word 0xa6092077")    /* vkeccak.vi v0,v0,24 */
VT(vkeccak_12, E64M8, ".word " KECCAK12)
#endif

static void run_vec(const char *name, vfn f, uint64_t vl)
{
    uint64_t c[NVCLS]; int fail = 0; unsigned i, pass;
    uint64_t raw[3][NVCLS];
    for (pass = 0; pass < 3; pass++)
        for (i = 0; i < NVCLS; i++) raw[pass][i] = f(vcls[i].pm, vcls[i].pa, vcls[i].pb, vcls[i].pa[1], vcls[i].pb[3], vl);
    for (i = 0; i < NVCLS; i++) { uint64_t m = raw[0][i]; if (raw[1][i] < m) m = raw[1][i]; if (raw[2][i] < m) m = raw[2][i]; c[i] = m; }
    for (i = 1; i < NVCLS; i++) if (c[i] != c[0]) fail = 1;
    if (raw_dump) for (pass = 0; pass < 3; pass++) { sio_puts("   raw pass "); put_u64(pass); sio_putc(':'); for (i = 0; i < NVCLS; i++) { sio_putc(' '); put_u64(raw[pass][i]); } sio_putc('\n'); }
    n_tests++; if (fail) n_fail++;
    sio_puts(fail ? "[FAIL] " : "[ok]   "); sio_puts(name); sio_puts(":");
    for (i = 0; i < NVCLS; i++) { sio_putc(' '); put_u64(c[i]); }
    sio_putc('\n');
}

#define RS(nm) run_scalar(#nm, s_##nm)
#define RV(nm, vl) run_vec(#nm " vl=" #vl, v_##nm, vl)

int main(void)
{
    init_pats(); init_vcls();
    sio_puts("\n[DIEL probe] cycle counts per operand class; all must match\n");
    sio_puts("-- scalar Zkt (16 copies per block) --\n");
    RS(add); RS(sub); RS(sll); RS(srl); RS(sra); RS(slt); RS(sltu); RS(xor); RS(or); RS(and);
    RS(addw); RS(subw); RS(sllw); RS(srlw); raw_dump = 1; RS(sraw); raw_dump = 0;
    RS(addi); RS(slti); RS(sltiu); RS(xori); RS(slli); RS(srli); RS(srai); RS(addiw); RS(slliw); RS(srliw); RS(sraiw);
    RS(mul); RS(mulh); RS(mulhsu); RS(mulhu); RS(mulw);
    RS(andn); RS(orn); RS(xnor); RS(rol); RS(ror); RS(rolw); RS(rorw); RS(rori); RS(roriw); RS(rev8); RS(zext_h);
    RS(czero_eqz); RS(czero_nez);
    RS(c_mul); RS(c_not); RS(c_zext_b); RS(c_ops);

    sio_puts("-- vector Zvkt (4 copies per block; VLEN=256) --\n");
    RV(vadd_vv,1000); RV(vadd_vv_e8,1000); RV(vsub_vv,1000); RV(vrsub_vx,1000); RV(vadd_vi,1000);
    RV(vand_vv,1000); RV(vor_vx,1000); RV(vxor_vi,1000);
    RV(vsll_vv,1000); RV(vsrl_vv,1000); RV(vsra_vv,1000); RV(vsll_vx,1000); RV(vsrl_vi,1000); RV(vsra_vv_e8,1000);
    RV(vwadd_vv,1000); RV(vwaddu_vx,1000); RV(vwsub_wv,1000); RV(vwsubu_wx,1000);
    RV(vadc_vvm,1000); RV(vadc_vxm,1000); RV(vadc_vim,1000); RV(vsbc_vvm,1000);
    RV(vmadc_vvm,1000); RV(vmadc_vv,1000); RV(vmadc_vxm,1000); RV(vmsbc_vvm,1000); RV(vmsbc_vx,1000);
    RV(vmseq_vv,1000); RV(vmsne_vx,1000); RV(vmslt_vv,1000); RV(vmsltu_vx,1000); RV(vmsle_vi,1000);
    RV(vmsleu_vv,1000); RV(vmsgt_vx,1000); RV(vmsgtu_vi,1000); RV(vmseq_vv_e8,1000);
    RV(vmv_v_v,1000); RV(vmv_v_x,1000); RV(vmv_v_i,1000); RV(vmv_s_x,1000); RV(vmv_x_s,1000);
    RV(vmv1r_v,1000); RV(vmv2r_v,1000); RV(vmv8r_v,1000);
    RV(vmerge_vvm,1000); RV(vmerge_vxm,1000); RV(vmerge_vim,1000);
    RV(vsext_vf2,1000); RV(vzext_vf2,1000); RV(vsext_vf4,1000); RV(vzext_vf8,1000);
    RV(vmand_mm,1000); RV(vmnand_mm,1000); RV(vmandn_mm,1000); RV(vmxor_mm,1000);
    RV(vmor_mm,1000); RV(vmnor_mm,1000); RV(vmorn_mm,1000); RV(vmxnor_mm,1000);
    RV(vmul_vv,1000); RV(vmul_vv_e8,1000); RV(vmul_vx,1000); RV(vmulh_vv,1000); RV(vmulhu_vx,1000);
    RV(vmulhsu_vv,1000); RV(vmulh_vv_e32,1000);
    RV(vmacc_vv,1000); RV(vmacc_vx,1000); RV(vmadd_vv,1000); RV(vnmsac_vv,1000); RV(vnmsub_vx,1000); RV(vmacc_vv_e8,1000);
    RV(vwmul_vv,1000); RV(vwmulu_vv,1000); RV(vwmulsu_vx,1000); RV(vwmulu_vx,1000);
    RV(vwmacc_vv,1000); RV(vwmaccu_vx,1000); RV(vwmaccsu_vv,1000); RV(vwmaccus_vx,1000); RV(vwmul_vv_e8,1000);
    RV(vnsrl_wv,1000); RV(vnsra_wx,1000); RV(vnsrl_wi,1000);
    RV(vrgather_vv,1000); RV(vrgather_vx,1000); RV(vrgather_vi,1000); RV(vrgatherei16_vv,1000); RV(vrgather_vv_e8,1000);
    RV(vslideup_vx,1000); RV(vslideup_vi,1000); RV(vslidedown_vx,1000); RV(vslidedown_vi,1000);
    RV(vslide1up_vx,1000); RV(vslide1down_vx,1000); RV(vslide1up_vx_e8,1000);
    RV(vfslide1up_vf,1000); RV(vfslide1down_vf,1000); RV(vfslide1up_vf_e32,1000);
    RV(vandn_vv,1000); RV(vandn_vx,1000); RV(vbrev_v,1000); RV(vbrev8_v,1000); RV(vrev8_v,1000);
    RV(vclz_v,1000); RV(vctz_v,1000); RV(vcpop_v,1000); RV(vclz_v_e8,1000);
    RV(vrol_vv,1000); RV(vrol_vx,1000); RV(vror_vv,1000); RV(vror_vx,1000); RV(vror_vi,1000);
    RV(vwsll_vv,1000); RV(vwsll_vx,1000); RV(vwsll_vi,1000);
    sio_puts("-- partial vl (tail elements vary) --\n");
    RV(vmul_vv,5); RV(vmul_vv_e8,37); RV(vmacc_vv,3); RV(vwmul_vv,5); RV(vrgather_vv,5); RV(vslide1up_vx,5);
    RV(vmadc_vvm,5); RV(vmseq_vv,5); RV(vmand_mm,5); RV(vsext_vf2,5); RV(vnsrl_wv,5); RV(vror_vv,5);
    sio_puts("-- masked (fixed mask, inactive elements vary) --\n");
    RV(vmul_vv_m,1000); RV(vmul_vv_m_ta,1000); RV(vmul_vv_e8_m,1000); RV(vadd_vv_m,1000); RV(vmacc_vv_m,1000);
    RV(vwmul_vv_m,1000); RV(vmseq_vv_m,1000); RV(vrgather_vv_m,1000); RV(vslide1up_vx_m,1000);
    RV(vsext_vf2_m,1000); RV(vror_vv_m,1000); RV(vnsrl_wv_m,1000); RV(vmerge_data_m,1000);
    RV(vmul_vv_m,6); RV(vmacc_vv_m,5);
#ifdef WITH_ZVK
    sio_puts("-- Zvk crypto leaves --\n");
    RV(vaesem_vv,1000); RV(vaesef_vs,1000); RV(vaesdm_vv,1000); RV(vaesdf_vs,1000); RV(vaesz_vs,1000);
    RV(vaeskf1_vi,1000); RV(vaeskf2_vi,1000);
    RV(vsha2ms_vv,1000); RV(vsha2ch_vv,1000); RV(vsha2cl_vv,1000); RV(vsha2ms_vv_e64,1000); RV(vsha2ch_vv_e64,1000);
    RV(vsm4r_vv,1000); RV(vsm4r_vs,1000); RV(vsm4k_vi,1000); RV(vsm3me_vv,1000); RV(vsm3c_vi,1000);
    RV(vghsh_vv,1000); RV(vgmul_vv,1000);
    RV(vaesem_vv,4); RV(vghsh_vv,4); RV(vsha2ms_vv,4);
#endif
#ifdef WITH_KECCAK
    sio_puts("-- Zvknhk draft --\n");
    RV(vkeccak_24,25); RV(vkeccak_12,25);
#endif
    sio_puts("[DIEL] tests="); put_u64(n_tests); sio_puts(" failures="); put_u64(n_fail); sio_putc('\n');
    sio_puts(n_fail ? "[DIEL] FAIL\n" : "[DIEL] ALL PASS\n");
    return n_fail;
}
