// Copyright 2016-2017 SiFive, Inc.
// SPDX-License-Identifier: Apache-2.0
// Adapted from pulp-platform/riscv-dbg debug_rom/debug_rom.S at
// 643607e19df3435cfd77cc56143e2637f5900a6e:
// https://github.com/pulp-platform/riscv-dbg/blob/643607e19df3435cfd77cc56143e2637f5900a6e/debug_rom/debug_rom.S
// Karu adaptation: one hart, two scratch CSRs, page-relative accesses,
// synchronous memory handshake and core-confirmed resume acknowledgement.
// See ../LICENSE.SiFive for license details.

    .option norvc
    .option norelax
    .section .text
    .global entry, exception, resume_dret
    .equ DSCRATCH0, 0x7b2
    .equ DSCRATCH1, 0x7b3
    .equ HALTED,    0x100
    .equ GOING,     0x108
    .equ RESUMING,  0x110
    .equ EXCEPTION, 0x118
    .equ FLAGS,     0x400

entry:
    j entry_body
    nop
resume:
    j resume_body
    nop
exception:
    j exception_body
    nop

entry_body:
    fence
    csrw DSCRATCH0, s0
    csrw DSCRATCH1, a0
    auipc a0, 0
    srli a0, a0, 12
    slli a0, a0, 12
entry_loop:
    sw zero, HALTED(a0)
    lbu s0, FLAGS(a0)
    andi s0, s0, 1
    bnez s0, going
    lbu s0, FLAGS(a0)
    andi s0, s0, 2
    bnez s0, resume_body
    j entry_loop

exception_body:
    auipc a0, 0
    srli a0, a0, 12
    slli a0, a0, 12
    sw zero, EXCEPTION(a0)
    csrr a0, DSCRATCH1
    csrr s0, DSCRATCH0
    ebreak

going:
    sw zero, GOING(a0)
    csrr a0, DSCRATCH1
    csrr s0, DSCRATCH0
    j 0x300
resume_body:
    sw zero, RESUMING(a0)
    csrr a0, DSCRATCH1
    csrr s0, DSCRATCH0
resume_dret:
    .word 0x7b200073
