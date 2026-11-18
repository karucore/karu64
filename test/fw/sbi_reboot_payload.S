//  sbi_reboot_payload.S
//  === S-mode payload for `make sbi-reboot-test`: reboot through OpenSBI.
//
//  OpenSBI jumps here (0x8020_0000, where the boot ROM normally puts U-Boot)
//  in S-mode. The payload asks OpenSBI for a cold reboot with the SBI system
//  reset extension. OpenSBI's syscon-reboot driver, configured by the device
//  tree, writes the system-control register; the SoC resets, the boot ROM
//  runs again and loads the chain a second time. A marker in DRAM, which the
//  reset does not clear, tells the second boot from the first.
//
//    first boot   SRST must be advertised; set the marker; request the
//                 reboot. Returning from that call is a failure.
//    second boot  the marker is set: PASS.
//
//  The result goes to the simulation's tohost word (bit 0 = done, the rest
//  the exit code) and to the console through the SBI legacy putchar call.
//
//  -DSBI_PAYLOAD_SEED (make image-boot-test) adds, on both boots, the read
//  that Linux makes of the Zkr seed CSR: four ES16 words within 100 polls
//  (arch/riscv/include/asm/archrandom.h). S-mode may only do that if OpenSBI
//  found "zkr" in the device tree and set mseccfg.SSEED, so it also shows
//  that discovery works. With -DSBI_PAYLOAD_SEED_OFF the entropy source is
//  expected to be held off: every read must then report BIST, and the boot
//  must go on regardless. A seed access that traps is a failure.

#define STATE       0x80400000      /* marker, outside every loaded image */
#define TOHOST      0x80300000      /* fpga_ddr_tb +tohost=300000 */
#define MARKER      0x5342495245424f4f
#define SBI_EXT_BASE        0x10
#define SBI_BASE_PROBE_EXT  3
#define SBI_EXT_SRST        0x53525354
#define SBI_SRST_COLD_REBOOT 1

    .section .text
    .globl _start
_start:
    la      sp, stack_top
#ifdef SBI_PAYLOAD_SEED
    la      t0, seed_trap
    csrw    stvec, t0
    call    seed_longs              //  a0 = 1: four words in one read
#ifdef SBI_PAYLOAD_SEED_OFF
    bnez    a0, seed_unexpected
    la      a0, msg_seed_off
#else
    beqz    a0, seed_missing
    la      a0, msg_seed_ok
#endif
    call    puts
#endif
    li      s0, STATE
    li      s1, MARKER
    ld      t0, 0(s0)
    beq     t0, s1, second_boot

    la      a0, msg_first
    call    puts
    //  sbi_probe_extension(SRST): the value in a1 is non-zero if available
    li      a7, SBI_EXT_BASE
    li      a6, SBI_BASE_PROBE_EXT
    li      a0, SBI_EXT_SRST
    ecall
    beqz    a1, no_srst

    sd      s1, 0(s0)
    li      a7, SBI_EXT_SRST
    li      a6, 0
    li      a0, SBI_SRST_COLD_REBOOT
    li      a1, 0
    ecall
    //  A reset request must not return.
    sd      zero, 0(s0)
    la      a0, msg_returned
    call    puts
    li      t0, (2 << 1) | 1
    j       finish

no_srst:
    la      a0, msg_no_srst
    call    puts
    li      t0, (3 << 1) | 1
    j       finish

second_boot:
    sd      zero, 0(s0)
    la      a0, msg_pass
    call    puts
    li      t0, 1                   //  exit code 0

finish:
    li      t1, TOHOST
    sd      t0, 0(t1)
1:  j       1b

#ifdef SBI_PAYLOAD_SEED
//  Repeated reads of four words, each within 100 polls. a0 = 1 as soon as
//  one read succeeds, 0 if none did. A DEAD source ends the attempt at once.
//  With the source expected off, thirty reads are enough to see BIST.
seed_longs:
#ifdef SBI_PAYLOAD_SEED_OFF
    li      t5, 30
#else
    li      t5, 3000
#endif
1:  li      t3, 4
    li      t4, 100
2:  csrrw   t0, 0x015, zero
    srli    t1, t0, 30
    li      t2, 3
    beq     t1, t2, 4f              //  DEAD
    li      t2, 2
    bne     t1, t2, 3f
    addi    t3, t3, -1
    beqz    t3, 5f
3:  addi    t4, t4, -1
    bnez    t4, 2b
    addi    t5, t5, -1
    bnez    t5, 1b
4:  li      a0, 0
    ret
5:  li      a0, 1
    ret

seed_trap:
    la      a0, msg_seed_trap
    call    puts
    li      t0, (6 << 1) | 1
    j       finish
seed_missing:
    la      a0, msg_seed_missing
    call    puts
    li      t0, (4 << 1) | 1
    j       finish
#ifdef SBI_PAYLOAD_SEED_OFF
seed_unexpected:
    la      a0, msg_seed_unexpected
    call    puts
    li      t0, (5 << 1) | 1
    j       finish
#endif
#endif

//  puts(a0 = string): SBI legacy console putchar
puts:
    mv      t2, a0
2:  lbu     a0, 0(t2)
    beqz    a0, 3f
    li      a7, 1
    ecall
    addi    t2, t2, 1
    j       2b
3:  ret

    .section .rodata
msg_first:      .asciz "[sbi-reboot] boot 1: requesting cold reboot through SBI SRST\n"
msg_returned:   .asciz "[sbi-reboot] FAIL: the reset request returned\n"
msg_no_srst:    .asciz "[sbi-reboot] FAIL: OpenSBI does not offer system reset\n"
msg_pass:       .asciz "[sbi-reboot] PASS: rebooted through OpenSBI\n"
#ifdef SBI_PAYLOAD_SEED
msg_seed_ok:    .asciz "[sbi-seed] four seed words within 100 polls, as Linux reads them\n"
msg_seed_off:   .asciz "[sbi-seed] seed stays in BIST: the source is held off, the boot goes on\n"
msg_seed_missing: .asciz "[sbi-seed] FAIL: no read of four seed words succeeded\n"
msg_seed_unexpected: .asciz "[sbi-seed] FAIL: seed delivered words with the source held off\n"
msg_seed_trap:  .asciz "[sbi-seed] FAIL: the seed access trapped (OpenSBI did not set SSEED)\n"
#endif

    .section .bss
    .balign 16
    .space  1024
stack_top:
