#   htif_start.S
#   === Minimal freestanding _start for spike/HTIF.
#   Sets sp, zeroes BSS, calls main, then htif_exit(main's return).

    .section .text.init, "ax"
    .globl _start
_start:
    #   Enable FPU + vector state in mstatus (FS=11, VS=11). Newer spike
    #   resets with FS/VS=Off and raises illegal-instruction on every FP and
    #   vector insn (incl. vsetvli) until M-mode software enables them; the
    #   spike this repo was originally validated against came up enabled.
    #   karu64 does not gate FP/V execution on these bits, so this is a
    #   no-op there -- it exists so one ELF keeps working on both sims.
    li      t0, (3 << 13) | (3 << 9)
    csrs    mstatus, t0

    la      sp, _stack_top

    #   zero bss (8-byte aligned by the linker script)
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b

2:  call    main
    call    htif_exit
3:  wfi
    j       3b
