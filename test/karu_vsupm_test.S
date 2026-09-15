// Vector pointer masking after final effective-address generation.
// Bare S-mode PMLEN16/7: contiguous, high positive/negative strides,
// indexed and segment loads/stores, vstart, inactive elements, MXR and tval.
// Sv39 adds negative virtual addresses and sign-extended fault addresses.
// Includes tagged misaligned/two-page accesses and memory/register canaries.
// Same ELF on HTIF and Spike: --isa=rv64gcv_zvl256b_smnpm_ssnpm_svade_zicclsm.
// Exit 0 = pass; other exits identify the failing case in s10.

	.equ TOHOST, 0x80001000
	.equ BUF,    0x80003000
	.equ OUT,    0x80003100
	.equ OUT2,   0x80003200
	.equ IDX,    0x80003300
	.equ ROOT,   0x80004000
	.equ MIS,    0x80005ff5
	.equ MOUT,   0x80007ff5

	.section .text.boot,"ax"
	.globl _start
	.option norvc
_start:
	la t0, m_handler
	csrw mtvec, t0
	li t0, -1
	csrw pmpaddr0, t0
	li t0, 15
	csrw pmpcfg0, t0
	li t0, (3 << 13) | (3 << 9)
	csrs mstatus, t0
	li t0, BUF
	li t1, 0x1111111100000001
	sd t1, 0(t0)
	li t1, 0x2222222200000002
	sd t1, 8(t0)
	li t1, 0x3333333300000003
	sd t1, 16(t0)
	li t1, 0x4444444400000004
	sd t1, 24(t0)
	li t0, MIS
	li t1, 1
	li t2, 33
1:	sb t1, 0(t0)
	addi t0, t0, 1
	addi t1, t1, 1
	bne t1, t2, 1b
	// One root page: identity DRAM and a negative Sv39 alias, both 1 GiB.
	li t0, ROOT
	li t1, 512
1:	sd zero, 0(t0)
	addi t0, t0, 8
	addi t1, t1, -1
	bnez t1, 1b
	li t0, ROOT
	li t1, 0x200000cf       // V/R/W/X/A/D; PPN=0x80000
	sd t1, 16(t0)           // VPN[2]=2
	li t0, ROOT + 258*8
	sd t1, 0(t0)            // VA 0xffffffc080000000
	li s0, 0                // row 0=PMLEN16, row 1=PMLEN7
	li s10, 0
	li s11, 0               // expected trap cause, zero outside a fault case

enter_bare:
	li t0, (3 << 32)
	li s1, (1 << 48)        // first masked bit
	beqz s0, 1f
	li t0, (2 << 32)
	li s1, (1 << 57)
1:	csrw 0x30a, t0
	la t0, s_test
enter_s:
	csrw mepc, t0
	li t0, (3 << 11)
	csrc mstatus, t0
	li t0, (1 << 11)
	csrs mstatus, t0
	mret

s_test:
	addi s10, s10, 1
	vsetivli t0, 4, e64, m1, tu, mu
	// Contiguous tagged load and store preserve the original smoke test.
	li a0, BUF
	add a1, a0, s1
	vle64.v v8, (a1)
	li a1, OUT
	vse64.v v8, (a1)
	jal ra, check4
	addi s10, s10, 1
	li a1, OUT2
	add a2, a1, s1
	vse64.v v8, (a2)
	jal ra, check4

	// High stride bits must be ignored AFTER addition, including XLEN wrap.
	addi s10, s10, 1
	addi a2, s1, 8
	sub a3, a0, s1          // first pointer tagged; next wraps to BUF+8
	vlse64.v v8, (a3), a2
	li a1, OUT
	vse64.v v8, (a1)
	jal ra, check4
	addi s10, s10, 1
	neg a2, s1
	addi a2, a2, 8
	vlse64.v v8, (a0), a2
	vse64.v v8, (a1)
	jal ra, check4
	addi s10, s10, 1
	addi a2, s1, 8
	li a1, OUT2
	vsse64.v v8, (a1), a2
	jal ra, check4

	// Four distinct index tags, with positive and negative XLEN arithmetic.
	addi s10, s10, 1
	li a3, IDX
	sd zero, 0(a3)
	addi t0, s1, 8
	sd t0, 8(a3)
	neg t0, s1
	addi t0, t0, 16
	sd t0, 16(a3)
	slli t0, s1, 1
	addi t0, t0, 24
	sd t0, 24(a3)
	vle64.v v16, (a3)
	vluxei64.v v8, (a0), v16
	li a1, OUT
	vse64.v v8, (a1)
	jal ra, check4
	addi s10, s10, 1
	li a1, OUT2
	vsoxei64.v v8, (a1), v16
	jal ra, check4

	// Segment field offsets participate in the same final-address transform.
	addi s10, s10, 1
	vsetivli t0, 2, e64, m1, tu, mu
	addi a2, s1, 16
	vlsseg2e64.v v8, (a0), a2
	li a1, OUT
	vsseg2e64.v v8, (a1)
	jal ra, check4
	addi s10, s10, 1
	li a1, OUT2
	vssseg2e64.v v8, (a1), a2
	jal ra, check4

	// A tagged, misaligned load crosses both 16-byte and 4 KiB boundaries.
	// The fourth element is tail; adjacent registers are independent canaries.
	addi s10, s10, 1
	vsetivli t0, 4, e64, m1, tu, mu
	vmv.v.i v7, 13
	vmv.v.i v9, 14
	vmv.v.i v8, -1
	vsetivli t0, 3, e64, m1, tu, mu
	li a0, MIS
	add a3, a0, s1
	vle64.v v8, (a3)
	csrr t0, vl
	li t1, 3
	bne t0, t1, fail
	csrr t0, vstart
	bnez t0, fail
	vsetivli t0, 4, e64, m1, tu, mu
	li a1, OUT
	vse64.v v8, (a1)
	li a4, 24
	jal ra, check_bytes
	ld t0, 24(a1)
	li t1, -1
	bne t0, t1, fail
	vmv.x.s t0, v7
	li t1, 13
	bne t0, t1, fail
	vmv.x.s t0, v9
	li t1, 14
	bne t0, t1, fail

	// The per-element split takes its second granule through g1va.
	addi s10, s10, 1
	addi a2, s1, 8
	vlse64.v v8, (a3), a2
	vse64.v v8, (a1)
	li a4, 32
	jal ra, check_bytes
	// Both store engines preserve the bytes on either side of the range.
	addi s10, s10, 1
	jal ra, clear_mout
	add a3, a1, s1
	vse64.v v8, (a3)
	jal ra, check_bytes
	jal ra, check_mout_canaries
	addi s10, s10, 1
	jal ra, clear_mout
	add a3, a1, s1
	vsse64.v v8, (a3), a2
	jal ra, check_bytes
	jal ra, check_mout_canaries
	li a0, BUF
	li a1, OUT

	// Prestart elements remain undisturbed, and retirement clears vstart.
	addi s10, s10, 1
	vsetivli t0, 4, e64, m1, tu, mu
	vmv.v.i v8, -1
	li t0, 2
	csrw vstart, t0
	addi a2, s1, 8
	vlse64.v v8, (a0), a2
	csrr t0, vstart
	bnez t0, fail
	li a1, OUT
	vse64.v v8, (a1)
	ld t0, 0(a1)
	li t1, -1
	bne t0, t1, fail
	ld t0, 8(a1)
	bne t0, t1, fail
	ld t0, 16(a1)
	ld t1, 16(a0)
	bne t0, t1, fail
	ld t0, 24(a1)
	ld t1, 24(a0)
	bne t0, t1, fail

	// Masked-off indexed addresses are invalid even after PM and never fault.
	addi s10, s10, 1
	li a3, IDX
	li t0, (1 << 32)
	sd t0, 8(a3)
	sd t0, 24(a3)
	vle64.v v16, (a3)
	vmv.v.i v0, 5
	vmv.v.i v8, -1
	vluxei64.v v8, (a0), v16, v0.t
	vse64.v v8, (a1)
	ld t0, 0(a1)
	ld t1, 0(a0)
	bne t0, t1, fail
	ld t0, 8(a1)
	li t1, -1
	bne t0, t1, fail
	ld t0, 16(a1)
	ld t1, 16(a0)
	bne t0, t1, fail
	ld t0, 24(a1)
	li t1, -1
	bne t0, t1, fail

	// Bare PM zero-extends, even when the first non-tag bit is one.
	// That still exceeds PA32, and the access fault must report the masked VA.
	addi s10, s10, 1
	vsetivli t0, 1, e64, m1, tu, mu
	srli s9, s1, 1
	add s9, s9, a0
	add a2, s9, s1
	li s11, 5
	la s4, 2f
	la s5, 1f
1:	vle64.v v8, (a2)
	j fail
2:	// MXR suppresses PM, including in Bare; the tag must survive into tval.
	addi s10, s10, 1
	li t0, (1 << 19)
	csrs sstatus, t0
	add s9, a0, s1
	li s11, 5
	la s4, 4f
	la s5, 3f
3:	vlse64.v v8, (s9), zero
	j fail
4:	li t0, (1 << 19)
	csrc sstatus, t0
	ecall
	j fail

s_virtual:
	addi s10, s10, 1
	vsetivli t0, 4, e64, m1, tu, mu
	li a0, BUF
	li a3, 0xa5a5ffc080003000
	vle64.v v8, (a3)
	li a1, OUT
	vse64.v v8, (a1)
	jal ra, check4
	addi s10, s10, 1
	li a2, (1 << 48) + 8
	vlse64.v v8, (a3), a2
	vse64.v v8, (a1)
	jal ra, check4
	// The same two-page geometry must work through a negative Sv39 alias.
	addi s10, s10, 1
	li a0, MIS
	li a3, 0xa5a5ffc080005ff5
	vle64.v v8, (a3)
	vse64.v v8, (a1)
	li a4, 32
	jal ra, check_bytes
	addi s10, s10, 1
	vlse64.v v8, (a3), a2
	vse64.v v8, (a1)
	jal ra, check_bytes
	// Unmapped negative alias: page-fault tval is sign-extended after PM.
	addi s10, s10, 1
	vsetivli t0, 1, e64, m1, tu, mu
	li a3, 0x5a5affc040003000
	li s9, 0xffffffc040003000
	li s11, 13
	la s4, 2f
	la s5, 1f
1:	vlse64.v v8, (a3), zero
	j fail
2:	ecall
	j fail

// Compare four doublewords, preserving the caller's address/stride operands.
check4:
	li t0, 0
1:	add t1, a0, t0
	ld t2, 0(t1)
	add t1, a1, t0
	ld t3, 0(t1)
	bne t2, t3, fail
	addi t0, t0, 8
	li t1, 32
	bne t0, t1, 1b
	ret

// Byte comparison deliberately does not depend on scalar misaligned loads.
check_bytes:
	li t0, 0
1:	add t1, a0, t0
	lbu t2, 0(t1)
	add t1, a1, t0
	lbu t3, 0(t1)
	bne t2, t3, fail
	addi t0, t0, 1
	bne t0, a4, 1b
	ret
clear_mout:
	li a1, MOUT
	li t0, 0
1:	add t1, a1, t0
	sb zero, 0(t1)
	addi t0, t0, 1
	li t1, 32
	bne t0, t1, 1b
	li t0, 0x5a
	sb t0, -1(a1)
	li t0, 0xa5
	sb t0, 32(a1)
	ret
check_mout_canaries:
	lbu t0, -1(a1)
	li t1, 0x5a
	bne t0, t1, fail
	lbu t0, 32(a1)
	li t1, 0xa5
	bne t0, t1, fail
	csrr t0, vstart
	bnez t0, fail
	ret

	.align 2
m_handler:
	csrr t0, mcause
	bnez s11, expected_fault
	li t1, 9
	bne t0, t1, fail
	addi s0, s0, 1
	li t0, 2
	bltu s0, t0, enter_bare
	bne s0, t0, pass
	li t0, (3 << 32)
	csrw 0x30a, t0
	li t0, (8 << 60) | (ROOT >> 12)
	csrw satp, t0
	sfence.vma
	la t0, s_virtual
	j enter_s
expected_fault:
	bne t0, s11, fail
	csrr t0, mtval
	bne t0, s9, fail
	csrr t0, mepc
	bne t0, s5, fail
	csrr t0, vstart
	bnez t0, fail
	li s11, 0
	csrw mepc, s4
	mret
fail:
	slli t0, s10, 1
	ori t0, t0, 1
	li t1, TOHOST
	sd t0, 0(t1)
1:	j 1b
pass:
	li t0, 1
	li t1, TOHOST
	sd t0, 0(t1)
1:	j 1b

	.section .htif,"aw",@progbits
	.globl tohost
	.align 3
tohost: .dword 0
	.globl fromhost
fromhost: .dword 0
