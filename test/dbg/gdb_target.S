// Symbols/CFI for the simulated RAM fixture and the GDB-written step program.
// SPDX-License-Identifier: BSD-3-Clause
.option norvc
.option norelax
.text
.globl _start
.type _start,@function
_start:
    .cfi_startproc
    .cfi_undefined ra
    addi t0,t0,1
    j _start
    .cfi_endproc
.size _start,.-_start

.org 0x1000
.globl step_target
.type step_target,@function
step_target:
    .cfi_startproc
    .cfi_undefined ra
    addi a0,zero,42
    addi a0,a0,1
1:  j 1b
    .cfi_endproc
.size step_target,.-step_target

.org 0x7000
.globl trigger_target
.type trigger_target,@function
trigger_target:
    .cfi_startproc
    .cfi_undefined ra
    addi a2,zero,1
    sw a2,0(a1)
    lw a3,0(a1)
    addi a2,a2,1
    sw a2,0(a1)
    lw a3,0(a1)
1:  j 1b
    .cfi_endproc
.size trigger_target,.-trigger_target
