.option norelax
.option norvc
.section .text
.globl _start, step_case, step_0, step_1, step_2, step_3, step_end
.globl branch_case, branch_taken, ebreak_case, wfi_case, wrs_case, fence_case
.globl lrsc_case, sc_case, amo_case, watch_case, watch_store, watch_load, watch_end
.globl trap_handler, illegal_case, fault_case, fret_case, vload_case, vstore_case
.globl ff_case, vector_done, fp_case, fp_done, long_case, return_case
_start:
    addi t0,t0,1
    j _start
.org 0x40
step_case:
step_0: addi a0,zero,42
step_1: addi a0,a0,1
.option rvc
step_2: c.addi a0,1
.option norvc
step_3: addi a0,a0,2
step_end: j step_end
.org 0x80
branch_case:
    addi a0,zero,1
    beq a0,a0,branch_taken
    addi a0,a0,64
branch_taken:
    addi a0,a0,2
    ebreak
.org 0xc0
ebreak_case:
    addi a0,a0,1
    ebreak
.org 0x100
wfi_case:
    wfi
    addi a0,a0,1
    ebreak
.org 0x120
wrs_case:
    .word 0x00d00073
    addi a0,a0,1
    ebreak
.org 0x140
fence_case:
    fence w,iow
    .word 0x00d0000f
    fence.i
    ebreak
.org 0x180
lrsc_case:
    lr.d t0,(a1)
sc_case:
    sc.d a2,a0,(a1)
    ebreak
.org 0x1a0
amo_case:
    amoadd.d t0,a0,(a1)
    ebreak
.org 0x200
watch_case:
    addi a2,zero,1
watch_store:
    sw a2,0(a1)
watch_load:
    lw a3,0(a1)
    addi a2,a2,1
    sw a2,0(a1)
    lw a3,0(a1)
watch_end:
    j watch_end
.org 0x280
vload_case:
    vle32.v v8,(a1)
    ebreak
.org 0x2a0
vstore_case:
    vse32.v v8,(a1)
    ebreak
.org 0x2c0
ff_case:
    vle32ff.v v8,(a1)
vector_done:
    ebreak
.org 0x300
fp_case:
    fadd.d f2,f0,f1
    fmadd.d f3,f0,f1,f2
fp_done:
    ebreak
.org 0x340
long_case:
    divu a2,a0,a1
    fdiv.d f2,f0,f1
    vadd.vv v10,v8,v9
    j long_case
.org 0x380
illegal_case:
    .word 0xffffffff
    ebreak
.org 0x390
fault_case:
    ld a0,0(a1)
    ebreak
.org 0x3a0
fret_case:
    mret
    ebreak
.org 0x400
trap_handler:
    csrr a1,mcause
    csrr a2,mepc
    csrr a3,mtval
    ebreak
.org 0x440
return_case:
    addi a0,a0,1
    ebreak
.org 0x500
.globl setup_e8, setup_e32, setup_e64, masked_load, seg_load, seg_store, whole_load
setup_e8:
    vsetvli zero,a0,e8,m1,tu,mu
    ebreak
.org 0x520
setup_e32:
    vsetvli zero,a0,e32,m1,tu,mu
    ebreak
.org 0x540
setup_e64:
    vsetvli zero,a0,e64,m1,tu,mu
    ebreak
.org 0x560
masked_load:
    vle32.v v8,(a1),v0.t
    ebreak
.org 0x580
seg_load:
    vlseg2e32.v v8,(a1)
    ebreak
.org 0x5a0
seg_store:
    vsseg2e32.v v8,(a1)
    ebreak
.org 0x5c0
whole_load:
    vl2re32.v v8,(a1)
    ebreak
