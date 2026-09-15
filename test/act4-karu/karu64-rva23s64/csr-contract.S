// SPDX-License-Identifier: BSD-3-Clause
// KARU_RVA23S64 composition: mandatory Sscofpmf; TEST_SMCNTRPMF selects
// the separate optional fixed-counter variant. Reuse the privilege linker.
// These fixed implementation masks are not a generic profile requirement.
    .file "csr-contract.S"        // stable ELF FILE symbol, not GCC's temporary object

    .macro CHECK csr, value
    addi s0,s0,1
    csrr t0,\csr
    li t1,\value
    bne t0,t1,fail
    .endm

    .macro ILLEGAL word
    addi s0,s0,1
    li s1,0
    li s2,\word
    la s3,.Lillegal\@
    li a0,0x555
.Lillegal\@:
    .word \word
    li t0,1
    bne s1,t0,fail
    li t0,0x555
    bne a0,t0,fail
    li s2,0
    .endm

    .macro ENTER target, status
    la t0,\target
    csrw mepc,t0
    li t0,(1 << 39) | (3 << 11)
    csrc mstatus,t0
    li t0,\status
    csrs mstatus,t0
    mret
    .endm

    .macro RETURN_M target, cause
    la s4,\target
    li s5,\cause
    ecall
    j fail
    .endm

    .section .text.boot,"ax"
    .globl _start
    .option norvc
_start:
    li s0,0
    li s2,0
    li s5,0
    la t0,trap
    csrw mtvec,t0
    csrw mie,zero
    csrw medeleg,zero
    csrw satp,zero
    csrw 0x280,zero                // vsatp
    csrw 0x680,zero                // hgatp
    li t0,-1
    csrw 0x30c,t0                 // mstateen0
    csrw 0x60c,t0                 // hstateen0
    csrw mcountinhibit,t0
    CHECK mcountinhibit,0xfffffffd

    li t0,-1
    csrw mie,t0
    CHECK mie,0x3eee              // LCOFIE and writable SGEIE; GEILEN remains 0
    csrw mie,zero
    li t0,-1
    csrw mideleg,t0
    CHECK mideleg,0x3666          // LCOFIP delegated; VS and SGEI bits RO-one
    csrw mideleg,zero
    CHECK mideleg,0x1444

    li t0,-1
    csrw mcounteren,t0
    csrw scounteren,t0
    csrw 0x606,t0                 // hcounteren
    CHECK mcounteren,0xffffffff
    CHECK scounteren,0xffffffff
    CHECK 0x606,0xffffffff
    // Set every OF without selecting a counting event. mcountinhibit also
    // prevents execution-time changes to these deterministic expectations.
    li t0,(1 << 63)
    .set event_csr,0x323
    .rept 29
    csrw event_csr,t0
    .set event_csr,event_csr+1
    .endr
    CHECK 0xda0,0xfffffff8
    csrw 0x33f,zero               // event31.OF clear affects only bit31
    CHECK 0xda0,0x7ffffff8
    li t0,(1 << 63)
    csrw 0x33f,t0
    CHECK 0xda0,0xfffffff8
    ILLEGAL 0xda001573            // scountovf is read-only, even in M
#ifdef TEST_SMCNTRPMF
    li t0,-1
    csrw 0x321,t0
    CHECK 0x321,0x7c00000000000000 // mode inhibit bits, never OF/event bits
    csrw 0x321,zero
    CHECK 0x321,0
    li t0,-1
    csrw 0x322,t0
    CHECK 0x322,0x7c00000000000000
    csrw 0x322,zero
    CHECK 0x322,0
#else
    ILLEGAL 0x32102573            // mcyclecfg requires optional Smcntrpmf
    ILLEGAL 0x32202573            // minstretcfg requires optional Smcntrpmf
#endif

    li t0,0x88
    csrw mcounteren,t0
    csrw scounteren,zero
    li t0,0x80
    csrw 0x606,t0
    CHECK 0xda0,0xfffffff8        // M is not filtered by counter-enable CSRs
    ENTER hs,(1 << 11)
hs:
    CHECK 0xda0,0x88              // HS masks with mcounteren only
    CHECK scounteren,0
    li t0,-1
    csrw scounteren,t0
    CHECK 0xda0,0x88              // scounteren does not filter HS
    ILLEGAL 0xda001573
    RETURN_M after_hs,9
after_hs:
    ENTER vs,(1 << 39) | (1 << 11)
vs:
    CHECK 0xda0,0x80              // VS masks with mcounteren AND hcounteren
    ILLEGAL 0xda001573
    RETURN_M after_vs,10
after_vs:
    ENTER user,0
user:
    ILLEGAL 0xda002573            // U cannot read the supervisor CSR
    RETURN_M after_user,8
after_user:
#ifdef TEST_SMCNTRPMF
    li t0,23
#else
    li t0,21                     // every expected check completed
#endif
    bne s0,t0,fail
    li t0,1
    j finish

    .align 2
trap:
    csrr t0,mcause
    li t1,2
    bne t0,t1,service
    beqz s2,fail
    csrr t0,mepc
    bne t0,s3,fail
    csrr t0,mtval
    bne t0,s2,fail
    li s1,1
    addi t0,s3,4
    csrw mepc,t0
    mret
service:
    beqz s5,fail
    bne t0,s5,fail
    li s5,0
    li t0,(1 << 39) | (3 << 11)
    csrc mstatus,t0
    li t0,(3 << 11)
    csrs mstatus,t0
    csrw mepc,s4
    mret
fail:
    addi t0,s0,1
    slli t0,t0,1
    ori t0,t0,1
finish:
    la t1,tohost
    sd t0,0(t1)
1:  j 1b

    .section .htif,"aw",@progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
